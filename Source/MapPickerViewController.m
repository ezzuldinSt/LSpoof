#import "MapPickerViewController+Private.h"
#import "LocationSpoofer.h"
#import "PersistenceManager.h"
#import "LSPlaceSearchController.h"
#import "LSSettingsViewController.h"
#import "LSCoordinateEntryController.h"

@implementation LSStartAnnotation @end
@implementation LSDestinationAnnotation @end
@implementation LSMovingAnnotation @end
@implementation LSRealAnnotation @end

// Map style survives reopening the picker for the life of the host process.
static MKMapType ls_mapType = MKMapTypeStandard;

@interface MapPickerViewController () <MKMapViewDelegate, CLLocationManagerDelegate, UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate>
@end

@implementation MapPickerViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.view.tintColor = LSAccentColor();
    self.selectedCoordinate = kCLLocationCoordinate2DInvalid;
    self.selectedName = @"Selected location";
    self.tab = LSPickerTabLocation;
    self.previousMode = LSSessionController.shared.snapshot.mode;
    PersistenceManager *store = PersistenceManager.shared;
    if (store.hasStoredCoordinate) {
        self.selectedCoordinate = store.spoofCoordinate;
        self.hasSelection = YES;
        self.selectedName = store.isSpoofingEnabled ? @"Applied location" : @"Last selection";
    }
    [self buildInterface];
    [self restoreRoute];
    [self updateWorkspace];
    [self refreshSession];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(sessionChanged:) name:LSSessionDidChangeNotification object:LSSessionController.shared];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(backgrounded:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(activated:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(contentSizeChanged:) name:UIContentSizeCategoryDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(sceneDeactivated:) name:UISceneWillDeactivateNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(sceneActivated:) name:UISceneDidActivateNotification object:nil];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self refreshSession];
    [self updateRealLocation];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isBeingDismissed || self.navigationController.isBeingDismissed || !self.presentingViewController) {
        [self endPickerLifetime];
        if (self.didDismiss) { self.didDismiss(); self.didDismiss = nil; }
    }
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutSavedHeader];
    BOOL large = UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    BOOL vertical = self.view.bounds.size.height >= 600 && large;
    self.playbackRow.axis = vertical ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    self.locationActions.axis = large ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    self.speedRow.axis = large ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    // The map scales with the sheet: generous on tall phones, still usable in landscape.
    CGFloat height = MIN(440, MAX(220, self.view.bounds.size.height * 0.4));
    if (fabs(self.mapHeight.constant - height) > 0.5) self.mapHeight.constant = height;
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_directions cancel];
    [_realManager stopUpdatingLocation];
    _mapView.delegate = nil;
}
- (void)endPickerLifetime {
    if (self.closed) return;
    self.closed = YES;
    self.selectionRevision++;
    [self cancelDirections];
    self.realRevision++;
    [self.realManager stopUpdatingLocation];
}
- (void)backgrounded:(NSNotification *)note {
    (void)note;
    // The selection revision is deliberately left alone: a brief interruption such as
    // Control Center used to make the next search or coordinate choice silently vanish.
    BOOL fetching = self.directions != nil;
    [self cancelDirections];
    if (fetching) { self.routeFeedback.text = @"Route lookup paused. Tap Build route to try again."; [self updateRouteUI]; }
    self.realRevision++;
    [self.realManager stopUpdatingLocation];
}
- (void)activated:(NSNotification *)note { (void)note; if (!self.closed && self.view.window) { [self refreshSession]; [self updateRealLocation]; } }
- (void)sceneDeactivated:(NSNotification *)note { if (note.object == self.view.window.windowScene) [self backgrounded:note]; }
- (void)sceneActivated:(NSNotification *)note { if (note.object == self.view.window.windowScene) [self activated:note]; }
- (void)contentSizeChanged:(NSNotification *)note {
    (void)note;
    UIFont *font = LSFont(UIFontTextStyleSubheadline, UIFontWeightSemibold, 20);
    for (UISegmentedControl *segment in @[self.tabs, self.profileSegment, self.endpointSegment]) {
        [segment setTitleTextAttributes:@{NSFontAttributeName:font} forState:UIControlStateNormal];
    }
    [self.savedTable reloadData];
    [self refreshButtonFonts:self.view];
    [self.view setNeedsLayout];
}
- (void)refreshButtonFonts:(UIView *)view {
    if ([view isKindOfClass:UIButton.class]) [(UIButton *)view setNeedsUpdateConfiguration];
    for (UIView *child in view.subviews) [self refreshButtonFonts:child];
}

#pragma mark - Layout

- (UIView *)buildHeader {
    UIView *badge = LSIconBadge(@"location.fill", LSAccentColor(), 40);
    UILabel *title = LSLabel(@"LSpoof", UIFontTextStyleTitle2);
    self.brandLabel = title;
    title.font = LSFont(UIFontTextStyleTitle2, UIFontWeightBold, 32);
    title.accessibilityTraits = UIAccessibilityTraitHeader;
    self.statusChip = [[LSStatusChip alloc] init];
    self.appliedLabel = LSLabel(@"", UIFontTextStyleCaption1);
    self.appliedLabel.font = LSMonospacedFont(UIFontTextStyleCaption1);
    self.appliedLabel.textColor = UIColor.secondaryLabelColor;
    self.appliedLabel.numberOfLines = 1;
    self.appliedLabel.adjustsFontSizeToFitWidth = YES;
    self.appliedLabel.minimumScaleFactor = 0.75;
    UIStackView *titleRow = LSRow(@[title, self.statusChip], 10);
    titleRow.alignment = UIStackViewAlignmentCenter;
    UIStackView *identity = LSStack(@[titleRow, self.appliedLabel], 2);
    identity.alignment = UIStackViewAlignmentLeading;
    UIButton *settings = LSIconButton(@"gearshape.fill", @"Settings");
    [settings addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
    UIButton *close = LSIconButton(@"xmark", @"Close picker");
    close.accessibilityHint = @"Discards unapplied location or route edits. An applied session continues.";
    [close addTarget:self action:@selector(dismissPicker) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *header = LSRow(@[badge, identity, settings, close], 12);
    [identity setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [identity setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [header setCustomSpacing:8 afterView:settings];
    return header;
}
- (void)buildInterface {
    UIView *header = [self buildHeader];
    self.tabs = [[UISegmentedControl alloc] initWithItems:@[@"Location", @"Route", @"Saved"]];
    self.tabs.translatesAutoresizingMaskIntoConstraints = NO;
    self.tabs.selectedSegmentIndex = 0;
    self.tabs.accessibilityLabel = @"Workspace";
    [self.tabs.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [self.tabs addTarget:self action:@selector(tabChanged) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:header];
    [self.view addSubview:self.tabs];
    self.scroll = [[UIScrollView alloc] init];
    self.scroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.scroll.alwaysBounceVertical = YES;
    self.scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:self.scroll];
    self.contentStack = LSStack(@[], 14);
    [self.scroll addSubview:self.contentStack];
    UIButtonConfiguration *searchStyle = UIButtonConfiguration.grayButtonConfiguration;
    searchStyle.title = @"Search places or addresses";
    searchStyle.image = [UIImage systemImageNamed:@"magnifyingglass"];
    searchStyle.imagePadding = 10;
    searchStyle.baseForegroundColor = UIColor.secondaryLabelColor;
    searchStyle.baseBackgroundColor = UIColor.tertiarySystemFillColor;
    searchStyle.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    searchStyle.contentInsets = NSDirectionalEdgeInsetsMake(14, 14, 14, 14);
    searchStyle.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *result = [attributes mutableCopy];
        result[NSFontAttributeName] = LSFont(UIFontTextStyleBody, UIFontWeightRegular, 28);
        return result;
    };
    UIButton *search = [UIButton buttonWithType:UIButtonTypeSystem];
    search.configuration = searchStyle;
    search.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    search.translatesAutoresizingMaskIntoConstraints = NO;
    search.accessibilityLabel = @"Search places";
    search.accessibilityHint = @"Search for a place, pick a saved place, or enter coordinates.";
    [search.heightAnchor constraintGreaterThanOrEqualToConstant:50].active = YES;
    [search addTarget:self action:@selector(searchLocation) forControlEvents:UIControlEventTouchUpInside];
    self.locationIntro = search;
    [self.contentStack addArrangedSubview:search];
    [self buildRouteUI];
    [self.contentStack addArrangedSubview:self.routeEndpointsPanel];
    [self buildMap];
    [self.contentStack addArrangedSubview:self.mapContainer];
    self.mapErrorLabel = LSLabel(@"", UIFontTextStyleSubheadline);
    self.mapErrorLabel.textColor = LSErrorColor();
    self.mapErrorLabel.hidden = YES;
    self.realNoticeLabel = LSLabel(@"", UIFontTextStyleFootnote);
    self.realNoticeLabel.textColor = UIColor.secondaryLabelColor;
    self.realNoticeLabel.hidden = YES;
    self.mapHintLabel = LSLabel(@"Tap the map to drop a pin. Touch and hold to save the spot.", UIFontTextStyleFootnote);
    self.mapHintLabel.textColor = UIColor.secondaryLabelColor;
    UIStackView *notes = LSStack(@[self.mapHintLabel, self.mapErrorLabel, self.realNoticeLabel], 4);
    [self.contentStack addArrangedSubview:notes];
    [self.contentStack setCustomSpacing:8 afterView:self.mapContainer];
    [self buildLocationDetails];
    [self.contentStack addArrangedSubview:self.locationDetails];
    [self.contentStack addArrangedSubview:self.routeDetailsPanel];
    [self buildSavedUI];
    self.savedTable.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.savedTable];
    UIView *footer = [self buildFooter];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:safe.topAnchor constant:14],
        [header.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [header.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.tabs.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:14],
        [self.tabs.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [self.tabs.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [self.scroll.topAnchor constraintEqualToAnchor:self.tabs.bottomAnchor constant:10],
        [self.scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.scroll.bottomAnchor constraintEqualToAnchor:footer.topAnchor],
        [self.contentStack.topAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.topAnchor constant:6],
        [self.contentStack.leadingAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.leadingAnchor constant:20],
        [self.contentStack.trailingAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [self.contentStack.bottomAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.bottomAnchor constant:-20],
        [self.contentStack.widthAnchor constraintEqualToAnchor:self.scroll.frameLayoutGuide.widthAnchor constant:-40],
        [self.savedTable.topAnchor constraintEqualToAnchor:self.tabs.bottomAnchor constant:10],
        [self.savedTable.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.savedTable.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.savedTable.bottomAnchor constraintEqualToAnchor:footer.topAnchor],
        [footer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [footer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [footer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    [self contentSizeChanged:nil];
}
- (UIView *)buildFooter {
    self.primaryButton = LSButton(@"Apply location", @"checkmark.circle.fill", YES);
    [self.primaryButton addTarget:self action:@selector(primaryAction) forControlEvents:UIControlEventTouchUpInside];
    self.holdButton = LSButton(@"Hold here", @"stop.fill", NO);
    self.holdButton.accessibilityHint = @"Stops route movement and holds its current point.";
    [self.holdButton addTarget:self action:@selector(routeControlTapped) forControlEvents:UIControlEventTouchUpInside];
    self.offButton = LSButton(@"Turn off", @"power", NO);
    self.offButton.accessibilityLabel = @"Turn off spoofing";
    self.offButton.accessibilityHint = @"The app gets its real location again.";
    UIButtonConfiguration *off = self.offButton.configuration;
    off.baseForegroundColor = LSErrorColor();
    off.baseBackgroundColor = LSErrorColor();
    self.offButton.configuration = off;
    [self.offButton addTarget:self action:@selector(turnOff) forControlEvents:UIControlEventTouchUpInside];
    self.playbackRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.holdButton, self.offButton]];
    self.playbackRow.distribution = UIStackViewDistributionFillEqually;
    self.playbackRow.spacing = 10;
    UIStackView *stack = LSStack(@[self.primaryButton, self.playbackRow], 10);
    UIVisualEffectView *footer = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *line = LSSeparator();
    [footer.contentView addSubview:line];
    [footer.contentView addSubview:stack];
    // The buttons are pinned to the view's safe area, so the footer must be in the view first.
    [self.view addSubview:footer];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [line.topAnchor constraintEqualToAnchor:footer.contentView.topAnchor],
        [line.leadingAnchor constraintEqualToAnchor:footer.contentView.leadingAnchor],
        [line.trailingAnchor constraintEqualToAnchor:footer.contentView.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:footer.contentView.topAnchor constant:12],
        [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [stack.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-10]
    ]];
    return footer;
}
- (void)buildLocationDetails {
    UIView *badge = LSIconBadge(@"mappin", LSErrorColor(), 40);
    self.placeLabel = LSLabel(@"Choose a location", UIFontTextStyleHeadline);
    self.placeLabel.font = LSFont(UIFontTextStyleTitle3, UIFontWeightSemibold, 34);
    self.placeLabel.accessibilityTraits = UIAccessibilityTraitHeader;
    self.coordinateLabel = LSLabel(@"Search, tap the map, or enter coordinates.", UIFontTextStyleSubheadline);
    self.coordinateLabel.font = LSMonospacedFont(UIFontTextStyleSubheadline);
    self.coordinateLabel.textColor = UIColor.secondaryLabelColor;
    UIStackView *text = LSStack(@[self.placeLabel, self.coordinateLabel], 3);
    UIButtonConfiguration *copyStyle = UIButtonConfiguration.plainButtonConfiguration;
    copyStyle.image = [UIImage systemImageNamed:@"doc.on.doc"];
    copyStyle.baseForegroundColor = UIColor.secondaryLabelColor;
    self.coordinateCopyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.coordinateCopyButton.configuration = copyStyle;
    self.coordinateCopyButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.coordinateCopyButton.accessibilityLabel = @"Copy coordinates";
    [NSLayoutConstraint activateConstraints:@[[self.coordinateCopyButton.widthAnchor constraintEqualToConstant:44],
                                              [self.coordinateCopyButton.heightAnchor constraintEqualToConstant:44]]];
    [self.coordinateCopyButton addTarget:self action:@selector(copyCoordinates) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *top = LSRow(@[badge, text, self.coordinateCopyButton], 12);
    top.alignment = UIStackViewAlignmentCenter;
    UIButton *coordinates = LSChipButton(@"Coordinates", @"number");
    coordinates.accessibilityLabel = @"Edit coordinates";
    [coordinates addTarget:self action:@selector(editCoordinates) forControlEvents:UIControlEventTouchUpInside];
    self.savePlaceButton = LSChipButton(@"Save", @"bookmark");
    self.savePlaceButton.accessibilityLabel = @"Save place";
    [self.savePlaceButton addTarget:self action:@selector(saveSelectedPlace) forControlEvents:UIControlEventTouchUpInside];
    self.useRealButton = LSChipButton(@"My location", @"location.fill");
    self.useRealButton.accessibilityLabel = @"Use my real location";
    self.useRealButton.hidden = YES;
    [self.useRealButton addTarget:self action:@selector(useRealLocation) forControlEvents:UIControlEventTouchUpInside];
    self.locationActions = LSRow(@[coordinates, self.savePlaceButton, self.useRealButton], 8);
    self.locationActions.alignment = UIStackViewAlignmentFill;
    self.locationActions.distribution = UIStackViewDistributionFillProportionally;
    UIStackView *actions = LSStack(@[self.locationActions], 0);
    actions.alignment = UIStackViewAlignmentLeading;
    self.locationDetails = LSInsetPanel(LSStack(@[top, LSSeparator(), actions], 14));
}
- (void)buildMap {
    self.mapContainer = [[UIView alloc] init];
    self.mapContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.mapContainer.layer.cornerRadius = 22;
    self.mapContainer.layer.cornerCurve = kCACornerCurveContinuous;
    self.mapContainer.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    self.mapContainer.layer.borderColor = UIColor.separatorColor.CGColor;
    self.mapContainer.clipsToBounds = YES;
    self.mapHeight = [self.mapContainer.heightAnchor constraintEqualToConstant:300];
    self.mapHeight.priority = 999;
    self.mapHeight.active = YES;
    [self replaceMap:nil];
    UIButton *center = LSIconButton(@"scope", @"Center on applied location or selection");
    [center addTarget:self action:@selector(centerMap) forControlEvents:UIControlEventTouchUpInside];
    self.realCenterButton = LSIconButton(@"location.fill", @"Center on real location");
    self.realCenterButton.hidden = YES;
    [self.realCenterButton addTarget:self action:@selector(centerReal) forControlEvents:UIControlEventTouchUpInside];
    self.mapStyleButton = LSIconButton(@"map", @"Map style");
    [self.mapStyleButton addTarget:self action:@selector(cycleMapStyle) forControlEvents:UIControlEventTouchUpInside];
    self.mapRetryButton = LSIconButton(@"arrow.clockwise", @"Retry map");
    self.mapRetryButton.hidden = YES;
    [self.mapRetryButton addTarget:self action:@selector(retryMap) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *buttons = LSStack(@[self.mapStyleButton, center, self.realCenterButton, self.mapRetryButton], 10);
    [self.mapContainer addSubview:buttons];
    [NSLayoutConstraint activateConstraints:@[
        [buttons.topAnchor constraintEqualToAnchor:self.mapContainer.topAnchor constant:12],
        [buttons.trailingAnchor constraintEqualToAnchor:self.mapContainer.trailingAnchor constant:-12]
    ]];
    [self updateMapStyleButton];
}
- (void)replaceMap:(MKCoordinateRegion *)savedRegion {
    self.mapView.delegate = nil;
    [self.mapView removeFromSuperview];
    self.mapView = [[MKMapView alloc] init];
    self.mapView.translatesAutoresizingMaskIntoConstraints = NO;
    self.mapView.delegate = self;
    self.mapView.mapType = ls_mapType;
    self.mapView.showsUserLocation = NO;
    self.mapView.showsCompass = NO;
    self.mapView.showsScale = YES;
    self.mapView.pointOfInterestFilter = [MKPointOfInterestFilter filterIncludingAllCategories];
    self.mapView.accessibilityLabel = @"Location preview map";
    [self.mapContainer insertSubview:self.mapView atIndex:0];
    [NSLayoutConstraint activateConstraints:@[
        [self.mapView.topAnchor constraintEqualToAnchor:self.mapContainer.topAnchor],
        [self.mapView.leadingAnchor constraintEqualToAnchor:self.mapContainer.leadingAnchor],
        [self.mapView.trailingAnchor constraintEqualToAnchor:self.mapContainer.trailingAnchor],
        [self.mapView.bottomAnchor constraintEqualToAnchor:self.mapContainer.bottomAnchor]
    ]];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(mapTapped:)];
    tap.delegate = self;
    tap.cancelsTouchesInView = NO;
    [self.mapView addGestureRecognizer:tap];
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(mapHeld:)];
    hold.delegate = self;
    [tap requireGestureRecognizerToFail:hold];
    [self.mapView addGestureRecognizer:hold];
    for (MKPointAnnotation *pin in @[self.pin ?: NSNull.null, self.startPin ?: NSNull.null, self.endPin ?: NSNull.null, self.appliedPin ?: NSNull.null, self.realPin ?: NSNull.null]) {
        if ([pin isKindOfClass:MKPointAnnotation.class]) [self.mapView addAnnotation:pin];
    }
    if (self.routePolyline) [self.mapView addOverlay:self.routePolyline];
    if (self.radiusCircle) [self.mapView addOverlay:self.radiusCircle];
    if (savedRegion) [self.mapView setRegion:*savedRegion animated:NO];
    else if (self.hasSelection) [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(self.selectedCoordinate, 2000, 2000) animated:NO];
}
- (void)updateMapStyleButton {
    NSString *symbol = ls_mapType == MKMapTypeStandard ? @"map" : (ls_mapType == MKMapTypeHybrid ? @"square.2.layers.3d" : @"globe.americas.fill");
    NSString *name = ls_mapType == MKMapTypeStandard ? @"Standard" : (ls_mapType == MKMapTypeHybrid ? @"Hybrid" : @"Satellite");
    UIButtonConfiguration *config = self.mapStyleButton.configuration;
    config.image = [UIImage systemImageNamed:symbol];
    self.mapStyleButton.configuration = config;
    self.mapStyleButton.accessibilityValue = name;
    self.mapStyleButton.accessibilityHint = @"Switches between standard, hybrid, and satellite maps.";
}
- (void)cycleMapStyle {
    ls_mapType = ls_mapType == MKMapTypeStandard ? MKMapTypeHybrid : (ls_mapType == MKMapTypeHybrid ? MKMapTypeSatellite : MKMapTypeStandard);
    self.mapView.mapType = ls_mapType;
    [self updateMapStyleButton];
    LSHapticSelection();
    LSAnnounce([NSString stringWithFormat:@"%@ map", self.mapStyleButton.accessibilityValue]);
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    (void)gesture;
    UIView *view = touch.view;
    while (view && view != self.mapView) {
        if ([view isKindOfClass:UIControl.class] || [view isKindOfClass:MKAnnotationView.class]) return NO;
        view = view.superview;
    }
    return YES;
}
- (void)mapTapped:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    CLLocationCoordinate2D coordinate = [self.mapView convertPoint:[gesture locationInView:self.mapView] toCoordinateFromView:self.mapView];
    if (!CLLocationCoordinate2DIsValid(coordinate)) return;
    LSHapticSelection();
    if (self.tab == LSPickerTabRoute) [self assignMapEndpoint:coordinate];
    else [self setSelection:coordinate name:@"Dropped pin"];
}
- (void)mapHeld:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    CLLocationCoordinate2D coordinate = [self.mapView convertPoint:[gesture locationInView:self.mapView] toCoordinateFromView:self.mapView];
    if (!CLLocationCoordinate2DIsValid(coordinate)) return;
    LSHapticSelection();
    if (self.tab == LSPickerTabRoute) { [self assignMapEndpoint:coordinate]; return; }
    [self setSelection:coordinate name:@"Dropped pin"];
    [self saveSelectedPlace];
}
- (void)assignMapEndpoint:(CLLocationCoordinate2D)coordinate {
    LSEndpoint endpoint = self.endpoint;
    [self assignEndpoint:endpoint coordinate:coordinate name:@"Map point"];
    // Tapping From and then To is the common flow; without this every tap kept moving From.
    if (endpoint == LSEndpointFrom && !self.endPin) {
        self.endpointSegment.selectedSegmentIndex = LSEndpointTo;
        self.endpoint = LSEndpointTo;
        self.mapHintLabel.text = @"From is set. Tap the map again to set To.";
        LSAnnounce(self.mapHintLabel.text);
    }
}
- (void)setSelection:(CLLocationCoordinate2D)coordinate name:(NSString *)name {
    if (!CLLocationCoordinate2DIsValid(coordinate)) return;
    self.selectionRevision++;
    self.selectedCoordinate = coordinate;
    self.hasSelection = YES;
    self.selectedName = name.length ? name : @"Selected location";
    [self renderSelectedLocation];
}
- (void)renderSelectedLocation {
    CLLocationCoordinate2D coordinate = self.selectedCoordinate;
    if (!self.pin) { self.pin = [[MKPointAnnotation alloc] init]; [self.mapView addAnnotation:self.pin]; }
    self.pin.coordinate = coordinate;
    self.pin.title = @"Selected location";
    [self syncMapWorkspace];
    self.pin.subtitle = self.selectedName;
    self.placeLabel.text = self.selectedName;
    self.coordinateLabel.text = LSCoordinateText(coordinate);
    self.coordinateCopyButton.enabled = YES;
    LSBookmark *saved = [BookmarksManager.shared bookmarkNearCoordinate:coordinate];
    UIButtonConfiguration *save = self.savePlaceButton.configuration;
    save.title = saved ? @"Saved" : @"Save";
    save.image = [UIImage systemImageNamed:saved ? @"bookmark.fill" : @"bookmark"];
    self.savePlaceButton.configuration = save;
    self.savePlaceButton.accessibilityLabel = saved ? [NSString stringWithFormat:@"Saved as %@", saved.name] : @"Save place";
    self.mapHintLabel.text = @"Preview only. Apply location when you’re ready.";
    [self updateRadiusPreview];
    [self updateFooter];
}
- (void)syncMapWorkspace {
    BOOL location = self.tab == LSPickerTabLocation, route = self.tab == LSPickerTabRoute;
    for (MKPointAnnotation *pin in @[self.pin ?: NSNull.null, self.startPin ?: NSNull.null, self.endPin ?: NSNull.null]) {
        if (![pin isKindOfClass:MKPointAnnotation.class]) continue;
        BOOL visible = pin == self.pin ? location : route;
        if (visible && ![self.mapView.annotations containsObject:pin]) [self.mapView addAnnotation:pin];
        else if (!visible) [self.mapView removeAnnotation:pin];
    }
    if (self.routePolyline) {
        if (route && ![self.mapView.overlays containsObject:self.routePolyline]) [self.mapView addOverlay:self.routePolyline];
        else if (!route) [self.mapView removeOverlay:self.routePolyline];
    }
}
- (void)updateWorkspace {
    BOOL location = self.tab == LSPickerTabLocation, route = self.tab == LSPickerTabRoute, saved = self.tab == LSPickerTabSaved;
    self.tabs.selectedSegmentIndex = self.tab;
    self.locationIntro.hidden = !location;
    self.locationDetails.hidden = !location;
    self.routeEndpointsPanel.hidden = !route;
    self.routeDetailsPanel.hidden = !route;
    self.mapContainer.hidden = saved;
    self.mapHintLabel.hidden = saved;
    self.savedTable.hidden = !saved;
    self.scroll.hidden = saved;
    [self syncMapWorkspace];
    self.pin.title = @"Selected location";
    self.mapHintLabel.text = route ? (self.endpoint == LSEndpointFrom ? @"Tap the map to set From, or tap From to search." : @"Tap the map to set To, or tap To to search.") : @"Tap the map to drop a pin. Touch and hold to save the spot.";
    if (location && self.hasSelection) [self renderSelectedLocation];
    else if (location) self.coordinateCopyButton.enabled = NO;
    [self updateRouteUI];
    [self reloadSavedPlaces];
    [self updateRadiusPreview];
    [self updateFooter];
}
- (void)tabChanged {
    self.selectionRevision++;
    [self cancelDirections];
    self.tab = self.tabs.selectedSegmentIndex;
    LSHapticSelection();
    [self updateWorkspace];
    [self updateRealLocation];
    [self.scroll setContentOffset:CGPointZero animated:NO];
}
- (void)showMessage:(NSString *)message { [self showMessage:message symbol:nil]; }
- (void)showMessage:(NSString *)message symbol:(NSString *)symbol { LSShowToast(self.view, message, symbol); }

#pragma mark - Session

- (void)refreshSession {
    LSSessionSnapshot *snapshot = LSSessionController.shared.snapshot;
    LSSessionMode mode = snapshot.mode;
    [self.statusChip setTitle:LSSessionTitle(mode) color:LSSessionColor(mode) active:mode == LSSessionModeMoving];
    self.appliedLabel.text = snapshot.location ? LSCoordinateText(snapshot.location.coordinate) : @"Your app sees its real location";
    self.appliedLabel.accessibilityLabel = snapshot.location ? [NSString stringWithFormat:@"Applied coordinates %@", self.appliedLabel.text] : self.appliedLabel.text;
    if (snapshot.location) {
        if (!self.appliedPin) { self.appliedPin = [[LSMovingAnnotation alloc] init]; [self.mapView addAnnotation:self.appliedPin]; }
        self.appliedPin.title = mode == LSSessionModeMoving ? @"Moving location" : @"Applied location";
        self.appliedPin.coordinate = snapshot.location.coordinate;
        MKMarkerAnnotationView *view = (id)[self.mapView viewForAnnotation:self.appliedPin];
        if ([view isKindOfClass:MKMarkerAnnotationView.class]) {
            view.markerTintColor = LSSessionColor(mode);
            view.glyphImage = [UIImage systemImageNamed:LSSessionSymbol(mode)];
        }
        view.accessibilityLabel = [NSString stringWithFormat:@"%@. %@", self.appliedPin.title, LSCoordinateText(snapshot.location.coordinate)];
        // Keep the moving point on screen while watching a route play.
        if (mode == LSSessionModeMoving && self.tab == LSPickerTabRoute && !self.mapView.isHidden) {
            MKMapPoint point = MKMapPointForCoordinate(snapshot.location.coordinate);
            MKMapRect visible = MKMapRectInset(self.mapView.visibleMapRect, self.mapView.visibleMapRect.size.width * 0.1, self.mapView.visibleMapRect.size.height * 0.1);
            if (!MKMapRectContainsPoint(visible, point)) [self.mapView setCenterCoordinate:snapshot.location.coordinate animated:LSMapAnimationsEnabled()];
        }
    } else if (self.appliedPin) {
        [self.mapView removeAnnotation:self.appliedPin]; self.appliedPin = nil;
    }
    if (self.previousMode != mode) {
        LSAnnounce(LSSessionTitle(mode));
        self.previousMode = mode;
    }
    [self updatePlayback];
    [self updateFooter];
}
- (void)sessionChanged:(NSNotification *)note {
    (void)note;
    if (self.closed) return;
    // Host samples continue at 10 Hz; human-readable map/progress refreshes at at most 4 Hz.
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    LSSessionMode mode = LSSessionController.shared.snapshot.mode;
    if (mode == self.previousMode && now - self.lastUIUpdate < 0.25) return;
    self.lastUIUpdate = now;
    [self refreshSession];
}
- (void)updateFooter {
    LSSessionMode mode = LSSessionController.shared.snapshot.mode;
    BOOL moving = mode == LSSessionModeMoving || mode == LSSessionModePaused;
    BOOL controlsCurrentRoute = self.tab == LSPickerTabRoute && moving && self.fetchedRoute == LSSessionController.shared.retainedRoute && !self.routeDraftChanged;
    BOOL replay = self.tab == LSPickerTabRoute && mode == LSSessionModeStatic && self.fetchedRoute && self.fetchedRoute == LSSessionController.shared.retainedRoute && !self.routeDraftChanged;
    NSString *title, *symbol;
    if (controlsCurrentRoute) {
        title = mode == LSSessionModePaused ? @"Resume route" : @"Pause route";
        symbol = mode == LSSessionModePaused ? @"play.fill" : @"pause.fill";
    } else if (self.tab == LSPickerTabRoute) {
        title = replay ? @"Replay route" : (mode == LSSessionModeOff ? @"Start route" : @"Replace with this route");
        symbol = replay ? @"arrow.counterclockwise" : (mode == LSSessionModeOff ? @"play.fill" : @"arrow.triangle.2.circlepath");
    } else {
        title = mode == LSSessionModeOff ? @"Apply location" : @"Replace location";
        symbol = mode == LSSessionModeOff ? @"checkmark.circle.fill" : @"arrow.triangle.2.circlepath";
    }
    UIButtonConfiguration *primary = self.primaryButton.configuration;
    primary.title = title;
    primary.image = [UIImage systemImageNamed:symbol];
    self.primaryButton.configuration = primary;
    self.primaryButton.accessibilityLabel = title;
    self.primaryButton.hidden = self.tab == LSPickerTabSaved;
    self.primaryButton.enabled = self.tab == LSPickerTabRoute ? (controlsCurrentRoute || (self.fetchedRoute && !self.directions)) : self.hasSelection;
    self.primaryButton.layer.shadowOpacity = self.primaryButton.enabled ? 0.25 : 0;
    UIButtonConfiguration *hold = self.holdButton.configuration;
    hold.title = controlsCurrentRoute ? @"Hold here" : @"Route controls";
    hold.image = [UIImage systemImageNamed:controlsCurrentRoute ? @"stop.fill" : @"playpause.fill"];
    self.holdButton.configuration = hold;
    self.holdButton.accessibilityLabel = hold.title;
    self.holdButton.accessibilityHint = controlsCurrentRoute ? @"Stops movement and holds the current point." : @"Pause, resume, or stop movement and hold here.";
    self.holdButton.hidden = !moving;
    self.holdButton.showsMenuAsPrimaryAction = !controlsCurrentRoute;
    __weak typeof(self) weakSelf = self;
    UIAction *pause = [UIAction actionWithTitle:mode == LSSessionModePaused ? @"Resume route" : @"Pause route" image:[UIImage systemImageNamed:mode == LSSessionModePaused ? @"play.fill" : @"pause.fill"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf togglePause]; }];
    UIAction *stop = [UIAction actionWithTitle:@"Stop route and hold here" image:[UIImage systemImageNamed:@"stop.fill"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf holdHere]; }];
    self.holdButton.menu = controlsCurrentRoute ? nil : [UIMenu menuWithTitle:@"Applied route" children:@[pause, stop]];
    self.playbackRow.hidden = mode == LSSessionModeOff;
    self.offButton.hidden = mode == LSSessionModeOff;
    self.savePlaceButton.enabled = self.hasSelection;
}
- (void)primaryAction {
    if (self.tab == LSPickerTabRoute) {
        LSSessionMode mode = LSSessionController.shared.snapshot.mode;
        if ((mode == LSSessionModeMoving || mode == LSSessionModePaused) && self.fetchedRoute == LSSessionController.shared.retainedRoute && !self.routeDraftChanged) [self togglePause];
        else [self startDraftRoute];
        return;
    }
    if (!self.hasSelection) return;
    // The visible Replace location action explicitly commits this reversible change.
    [self applyCoordinate:self.selectedCoordinate name:self.selectedName];
}
- (void)applyCoordinate:(CLLocationCoordinate2D)coordinate name:(NSString *)name {
    if ([LSSessionController.shared applyStaticCoordinate:coordinate]) {
        [PersistenceManager.shared recordRecentCoordinate:coordinate name:name];
        [self showMessage:@"Location applied. Close the picker to return to your app." symbol:@"checkmark.circle.fill"];
        LSHapticSuccess();
        [self refreshSession];
    } else {
        [self showMessage:@"This location could not be applied." symbol:@"exclamationmark.triangle.fill"];
        LSHapticWarning();
    }
}
- (void)togglePause {
    if (LSSessionController.shared.snapshot.mode == LSSessionModePaused) [LSSessionController.shared resume];
    else [LSSessionController.shared pause];
    LSHapticSelection();
    [self refreshSession];
}
- (void)routeControlTapped { if (!self.holdButton.showsMenuAsPrimaryAction) [self holdHere]; }
- (void)holdHere {
    [LSSessionController.shared stopAndHold];
    [self refreshSession];
    [self showMessage:@"Route stopped. Holding its current location." symbol:@"stop.circle.fill"];
}
- (void)turnOff {
    [self cancelDirections];
    self.selectionRevision++;
    [LSSessionController.shared disable];
    LSHapticSuccess();
    [self refreshSession];
    [self showMessage:@"Spoofing is off. Your app sees its real location." symbol:@"location.slash.fill"];
}
- (void)confirmAction:(NSString *)title message:(NSString *)message button:(NSString *)button action:(dispatch_block_t)action {
    [self confirmAction:title message:message button:button destructive:NO action:action];
}
- (void)confirmAction:(NSString *)title message:(NSString *)message button:(NSString *)button destructive:(BOOL)destructive action:(dispatch_block_t)action {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIAlertAction *confirm = [UIAlertAction actionWithTitle:button style:destructive ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault handler:^(__unused UIAlertAction *item) { action(); }];
    [alert addAction:confirm];
    if (!destructive) alert.preferredAction = confirm;
    [self presentViewController:alert animated:LSMapAnimationsEnabled() completion:nil];
}

#pragma mark - Editors

- (void)searchLocation {
    __weak typeof(self) weakSelf = self;
    [self openPlaceChooser:@"Choose a location" coordinate:self.selectedCoordinate completion:^(CLLocationCoordinate2D coordinate, NSString *name) {
        [weakSelf setSelection:coordinate name:name];
        [weakSelf.mapView setRegion:MKCoordinateRegionMakeWithDistance(coordinate, 2000, 2000) animated:LSMapAnimationsEnabled()];
    }];
}
- (void)openPlaceChooser:(NSString *)title coordinate:(CLLocationCoordinate2D)coordinate completion:(void (^)(CLLocationCoordinate2D, NSString *))completion {
    LSPlaceSearchController *search = [[LSPlaceSearchController alloc] init];
    search.title = title;
    search.initialCoordinate = coordinate;
    search.searchRegion = self.mapView.region;
    NSUInteger revision = ++self.selectionRevision;
    __weak typeof(self) weakSelf = self;
    search.didChoose = ^(CLLocationCoordinate2D result, NSString *name) {
        typeof(self) self = weakSelf;
        if (!self || self.closed || self.selectionRevision != revision) return;
        completion(result, name);
    };
    [self presentEditor:search];
}
- (void)editCoordinates {
    LSCoordinateEntryController *entry = [[LSCoordinateEntryController alloc] init];
    entry.initialCoordinate = self.selectedCoordinate;
    entry.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(closeEditor)];
    NSUInteger revision = ++self.selectionRevision;
    __weak typeof(self) weakSelf = self;
    entry.didChoose = ^(CLLocationCoordinate2D coordinate) {
        typeof(self) self = weakSelf;
        if (!self || self.closed || revision != self.selectionRevision) return;
        [self setSelection:coordinate name:@"Entered coordinates"];
        [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(coordinate, 2000, 2000) animated:LSMapAnimationsEnabled()];
        [self closeEditor];
    };
    [self presentEditor:entry];
}
- (void)closeEditor { self.selectionRevision++; [self.presentedViewController dismissViewControllerAnimated:LSMapAnimationsEnabled() completion:nil]; }
- (void)presentEditor:(UIViewController *)editor {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:editor];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    nav.view.tintColor = LSAccentColor();
    nav.navigationBar.prefersLargeTitles = NO;
    nav.sheetPresentationController.detents = @[[UISheetPresentationControllerDetent largeDetent]];
    nav.sheetPresentationController.prefersGrabberVisible = YES;
    nav.sheetPresentationController.preferredCornerRadius = 24;
    [self presentViewController:nav animated:LSMapAnimationsEnabled() completion:nil];
}
- (void)openSettings {
    LSSettingsViewController *settings = [[LSSettingsViewController alloc] init];
    __weak typeof(self) weakSelf = self;
    settings.didSave = ^{
        typeof(self) self = weakSelf;
        [self updateRadiusPreview]; [self updateRealLocation]; [self refreshSession];
        [self showMessage:@"Settings saved." symbol:@"checkmark.circle.fill"];
    };
    [self presentEditor:settings];
}
- (void)dismissPicker {
    [self endPickerLifetime];
    [self dismissViewControllerAnimated:LSMapAnimationsEnabled() completion:^{
        if (self.didDismiss) { self.didDismiss(); self.didDismiss = nil; }
    }];
}
- (BOOL)accessibilityPerformEscape { [self dismissPicker]; return YES; }
- (NSArray<UIKeyCommand *> *)keyCommands {
    UIKeyCommand *close = [UIKeyCommand keyCommandWithInput:UIKeyInputEscape modifierFlags:0 action:@selector(dismissPicker)];
    close.discoverabilityTitle = @"Close location picker";
    return @[close];
}
- (void)copyCoordinates {
    if (!self.hasSelection) return;
    UIPasteboard.generalPasteboard.string = LSCoordinateText(self.selectedCoordinate);
    LSHapticSelection();
    [self showMessage:@"Coordinates copied." symbol:@"doc.on.doc.fill"];
}
- (void)useRealLocation {
    if (!self.realPin) return;
    [self setSelection:self.realPin.coordinate name:@"My real location"];
    [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(self.realPin.coordinate, 2000, 2000) animated:LSMapAnimationsEnabled()];
}

#pragma mark - Map

- (void)centerMap {
    CLLocation *applied = LSSessionController.shared.snapshot.location;
    CLLocationCoordinate2D coordinate = applied ? applied.coordinate : self.selectedCoordinate;
    if (self.tab == LSPickerTabRoute && self.routePolyline && !applied) {
        [self.mapView setVisibleMapRect:self.routePolyline.boundingMapRect edgePadding:UIEdgeInsetsMake(48, 32, 48, 72) animated:LSMapAnimationsEnabled()];
        return;
    }
    if (!CLLocationCoordinate2DIsValid(coordinate) && self.startPin) coordinate = self.startPin.coordinate;
    if (CLLocationCoordinate2DIsValid(coordinate)) [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(coordinate, 2000, 2000) animated:LSMapAnimationsEnabled()];
    else [self showMessage:@"Choose a place or enter coordinates to center the map." symbol:@"scope"];
}
- (void)centerReal {
    if (self.realPin) [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(self.realPin.coordinate, 2000, 2000) animated:LSMapAnimationsEnabled()];
}
- (void)retryMap {
    self.mapFailed = NO;
    MKCoordinateRegion region = self.mapView.region;
    [self replaceMap:&region];
    [self syncMapWorkspace];
    self.mapRetryButton.hidden = YES;
    self.mapErrorLabel.text = @"Loading map… You can still search or enter coordinates.";
    self.mapErrorLabel.hidden = NO;
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previous]) {
        self.mapContainer.layer.borderColor = [UIColor.separatorColor resolvedColorWithTraitCollection:self.traitCollection].CGColor;
        for (id<MKOverlay> overlay in self.mapView.overlays) {
            MKOverlayPathRenderer *renderer = (id)[self.mapView rendererForOverlay:overlay];
            renderer.strokeColor = [overlay isKindOfClass:MKCircle.class] ? LSAccentColor() : LSRouteColor();
            if ([overlay isKindOfClass:MKCircle.class]) renderer.fillColor = [LSAccentColor() colorWithAlphaComponent:0.12];
            [renderer setNeedsDisplay];
        }
    }
}
- (void)mapViewDidFailLoadingMap:(MKMapView *)map withError:(NSError *)error {
    (void)error;
    if (map != self.mapView || self.closed) return;
    self.mapFailed = YES;
    self.mapRetryButton.hidden = NO;
    self.mapErrorLabel.text = @"Map unavailable. Retry the map, search for a place, or enter coordinates.";
    self.mapErrorLabel.hidden = NO;
    LSAnnounce(self.mapErrorLabel.text);
}
- (void)mapViewDidFinishLoadingMap:(MKMapView *)map {
    if (map == self.mapView && !self.mapFailed) { self.mapRetryButton.hidden = YES; self.mapErrorLabel.hidden = YES; }
}
- (void)mapViewDidFinishRenderingMap:(MKMapView *)map fullyRendered:(BOOL)fullyRendered {
    if (map == self.mapView && fullyRendered) {
        self.mapFailed = NO; self.mapRetryButton.hidden = YES; self.mapErrorLabel.hidden = YES;
    }
}
- (MKAnnotationView *)mapView:(MKMapView *)map viewForAnnotation:(id<MKAnnotation>)annotation {
    if ([annotation isKindOfClass:MKUserLocation.class]) return nil;
    MKMarkerAnnotationView *view = (id)[map dequeueReusableAnnotationViewWithIdentifier:@"LSMarker"];
    if (!view) view = [[MKMarkerAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:@"LSMarker"];
    view.annotation = annotation;
    view.canShowCallout = YES;
    view.animatesWhenAdded = LSMapAnimationsEnabled();
    view.displayPriority = MKFeatureDisplayPriorityRequired;
    view.draggable = annotation == self.pin || annotation == self.startPin || annotation == self.endPin;
    view.markerTintColor = LSErrorColor();
    view.glyphText = nil;
    view.glyphImage = [UIImage systemImageNamed:@"mappin"];
    if ([annotation isKindOfClass:LSStartAnnotation.class]) { view.markerTintColor = LSSuccessColor(); view.glyphImage = [UIImage systemImageNamed:@"figure.walk"]; }
    if ([annotation isKindOfClass:LSDestinationAnnotation.class]) { view.markerTintColor = LSErrorColor(); view.glyphImage = [UIImage systemImageNamed:@"flag.checkered"]; }
    if ([annotation isKindOfClass:LSMovingAnnotation.class]) {
        LSSessionMode mode = LSSessionController.shared.snapshot.mode;
        view.markerTintColor = LSSessionColor(mode);
        view.glyphImage = [UIImage systemImageNamed:LSSessionSymbol(mode)];
        view.draggable = NO;
    }
    if ([annotation isKindOfClass:LSRealAnnotation.class]) { view.markerTintColor = UIColor.systemGrayColor; view.glyphImage = [UIImage systemImageNamed:@"person.fill"]; view.draggable = NO; }
    view.accessibilityLabel = [NSString stringWithFormat:@"%@. %@", annotation.title ?: @"Location", LSCoordinateText(annotation.coordinate)];
    view.accessibilityHint = view.draggable ? @"Drag to edit, or use the search and coordinate buttons." : nil;
    return view;
}
- (void)mapView:(MKMapView *)map annotationView:(MKAnnotationView *)view didChangeDragState:(MKAnnotationViewDragState)newState fromOldState:(MKAnnotationViewDragState)oldState {
    (void)map; (void)oldState;
    if (newState != MKAnnotationViewDragStateEnding) return;
    if (view.annotation == self.startPin) [self assignEndpoint:LSEndpointFrom coordinate:view.annotation.coordinate name:@"Map point"];
    else if (view.annotation == self.endPin) [self assignEndpoint:LSEndpointTo coordinate:view.annotation.coordinate name:@"Map point"];
    else if (view.annotation == self.pin) [self setSelection:view.annotation.coordinate name:@"Dropped pin"];
    LSHapticSelection();
    [view setDragState:MKAnnotationViewDragStateNone animated:LSMapAnimationsEnabled()];
}
- (MKOverlayRenderer *)mapView:(MKMapView *)map rendererForOverlay:(id<MKOverlay>)overlay {
    (void)map;
    if ([overlay isKindOfClass:MKCircle.class]) {
        MKCircleRenderer *renderer = [[MKCircleRenderer alloc] initWithCircle:(MKCircle *)overlay];
        renderer.strokeColor = LSAccentColor(); renderer.fillColor = [LSAccentColor() colorWithAlphaComponent:0.12]; renderer.lineWidth = 1.5;
        renderer.lineDashPattern = @[@6, @4];
        return renderer;
    }
    MKPolylineRenderer *renderer = [[MKPolylineRenderer alloc] initWithPolyline:(MKPolyline *)overlay];
    renderer.strokeColor = LSRouteColor(); renderer.lineWidth = 6;
    renderer.lineCap = kCGLineCapRound; renderer.lineJoin = kCGLineJoinRound;
    return renderer;
}
- (void)updateRadiusPreview {
    if (self.radiusCircle) [self.mapView removeOverlay:self.radiusCircle];
    self.radiusCircle = nil;
    if (self.tab == LSPickerTabLocation && self.hasSelection && PersistenceManager.shared.fluctuationEnabled) {
        self.radiusCircle = [MKCircle circleWithCenterCoordinate:self.selectedCoordinate radius:PersistenceManager.shared.fluctuationRadius];
        [self.mapView addOverlay:self.radiusCircle];
    }
}
- (void)hideRealLocation {
    if (self.realPin) [self.mapView removeAnnotation:self.realPin];
    self.realPin = nil;
    self.realCenterButton.hidden = YES;
    self.useRealButton.hidden = YES;
}
- (void)updateRealLocation {
    NSUInteger revision = ++self.realRevision;
    [self.realManager stopUpdatingLocation];
    BOOL foreground = self.view.window && (self.view.window.windowScene ? self.view.window.windowScene.activationState == UISceneActivationStateForegroundActive : UIApplication.sharedApplication.applicationState == UIApplicationStateActive);
    BOOL enabled = PersistenceManager.shared.showRealLocation && !self.closed && foreground && self.tab != LSPickerTabSaved;
    self.realNoticeLabel.hidden = !enabled;
    if (!enabled) { [self hideRealLocation]; return; }
    if (!self.realManager) {
        self.realManager = [[CLLocationManager alloc] init];
        LSMarkLibraryLocationManager(self.realManager);
        self.realManager.delegate = self;
        self.realManager.desiredAccuracy = kCLLocationAccuracyHundredMeters;
        self.realManager.distanceFilter = 50;
    }
    CLAuthorizationStatus status = self.realManager.authorizationStatus;
    if (status != kCLAuthorizationStatusAuthorizedAlways && status != kCLAuthorizationStatusAuthorizedWhenInUse) {
        [self hideRealLocation];
        self.realNoticeLabel.text = @"Real location is unavailable with the app’s current permission. You can still select a location.";
        return;
    }
    __weak typeof(self) weakSelf = self;
    self.realNoticeLabel.text = @"Updating real location…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL available = CLLocationManager.locationServicesEnabled;
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self || self.closed || revision != self.realRevision || !self.view.window ||
                (self.view.window.windowScene && self.view.window.windowScene.activationState != UISceneActivationStateForegroundActive)) return;
            if (available) [self.realManager startUpdatingLocation];
            else self.realNoticeLabel.text = @"Location Services are off. You can still select a location manually.";
        });
    });
}
- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager { if (manager == self.realManager) [self updateRealLocation]; }
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    CLLocation *location = locations.lastObject;
    if (manager != self.realManager || !location || location.horizontalAccuracy < 0 || !CLLocationCoordinate2DIsValid(location.coordinate) || self.closed || !self.view.window || !PersistenceManager.shared.showRealLocation || UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
        (self.view.window.windowScene && self.view.window.windowScene.activationState != UISceneActivationStateForegroundActive)) return;
    if (!self.realPin) { self.realPin = [[LSRealAnnotation alloc] init]; self.realPin.title = @"Real location"; [self.mapView addAnnotation:self.realPin]; }
    self.realPin.coordinate = location.coordinate;
    self.realCenterButton.hidden = NO;
    self.useRealButton.hidden = self.tab != LSPickerTabLocation;
    self.realNoticeLabel.text = @"Your real location is shown in gray. It is never sent to the app while spoofing.";
}
- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    (void)error;
    if (manager == self.realManager && !self.closed) self.realNoticeLabel.text = @"Real location could not be updated. Your selected location still works.";
}

#pragma mark - Saved table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { (void)table; return 2; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { (void)table; return [self savedRowsInSection:section]; }
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path { (void)table; return [self savedCell:path]; }
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path { [table deselectRowAtIndexPath:path animated:NO]; [self previewSavedPlace:path]; }
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    (void)table;
    if (section == 0) return [NSString stringWithFormat:@"Saved places · %lu of %lu", (unsigned long)self.savedPlaces.count, (unsigned long)BookmarksManager.capacity];
    return @"Recently applied";
}
- (BOOL)tableView:(UITableView *)table canEditRowAtIndexPath:(NSIndexPath *)path {
    (void)table;
    return path.section == 0 ? self.savedPlaces.count > 0 : self.recents.count > 0;
}
- (BOOL)tableView:(UITableView *)table canMoveRowAtIndexPath:(NSIndexPath *)path { (void)table; return path.section == 0 && self.savedPlaces.count > 1; }
- (UITableViewCellEditingStyle)tableView:(UITableView *)table editingStyleForRowAtIndexPath:(NSIndexPath *)path { (void)table; (void)path; return UITableViewCellEditingStyleNone; }
- (BOOL)tableView:(UITableView *)table shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)path { (void)table; (void)path; return NO; }
- (NSIndexPath *)tableView:(UITableView *)table targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)source toProposedIndexPath:(NSIndexPath *)destination {
    (void)table; (void)source;
    NSInteger last = (NSInteger)self.savedPlaces.count - 1;
    // Dropping into the Recents section used to land the place at the top of the list.
    if (destination.section > 0) return [NSIndexPath indexPathForRow:last inSection:0];
    return [NSIndexPath indexPathForRow:MIN(MAX(destination.row, 0), last) inSection:0];
}
- (void)tableView:(UITableView *)table moveRowAtIndexPath:(NSIndexPath *)source toIndexPath:(NSIndexPath *)destination { (void)table; [self moveSavedPlace:source to:destination]; }
- (UIContextMenuConfiguration *)tableView:(UITableView *)table contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)path point:(CGPoint)point { (void)table; (void)point; return [self savedMenu:path]; }
- (UISwipeActionsConfiguration *)tableView:(UITableView *)table trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)path { (void)table; return [self savedSwipeActions:path leading:NO]; }
- (UISwipeActionsConfiguration *)tableView:(UITableView *)table leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)path { (void)table; return [self savedSwipeActions:path leading:YES]; }
@end
