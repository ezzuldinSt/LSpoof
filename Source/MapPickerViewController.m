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
        self.selectedName = @"Last selection";
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
    BOOL vertical = self.view.bounds.size.height >= 600 && UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    self.playbackRow.axis = vertical ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
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
    self.selectionRevision++;
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
    BOOL large = UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    self.playbackRow.axis = large && self.view.bounds.size.height >= 600 ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    UIFont *font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:15 weight:UIFontWeightMedium] maximumPointSize:20];
    self.brandLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleTitle2] scaledFontForFont:[UIFont systemFontOfSize:22 weight:UIFontWeightBold] maximumPointSize:32];
    self.statusLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleFootnote] scaledFontForFont:[UIFont systemFontOfSize:13] maximumPointSize:20];
    for (UISegmentedControl *segment in @[self.tabs, self.profileSegment, self.endpointSegment]) [segment setTitleTextAttributes:@{NSFontAttributeName:font} forState:UIControlStateNormal];
    [self.savedTable reloadData];
    [self refreshButtonFonts:self.view];
}
- (void)refreshButtonFonts:(UIView *)view {
    if ([view isKindOfClass:UIButton.class]) [(UIButton *)view setNeedsUpdateConfiguration];
    for (UIView *child in view.subviews) [self refreshButtonFonts:child];
}

- (void)buildInterface {
    UILabel *title = LSLabel(@"LSpoof", UIFontTextStyleTitle2);
    self.brandLabel = title;
    title.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleTitle2] scaledFontForFont:[UIFont systemFontOfSize:22 weight:UIFontWeightBold] maximumPointSize:32];
    title.adjustsFontForContentSizeCategory = NO;
    title.accessibilityTraits = UIAccessibilityTraitHeader;
    self.statusLabel = LSLabel(@"Off", UIFontTextStyleFootnote);
    self.statusLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleFootnote] scaledFontForFont:[UIFont systemFontOfSize:13] maximumPointSize:20];
    self.statusLabel.adjustsFontForContentSizeCategory = NO;
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    UIStackView *identity = LSStack(@[title, self.statusLabel], 2);
    UIButton *settings = LSButton(@"", @"slider.horizontal.3", NO);
    settings.accessibilityLabel = @"Settings";
    [settings addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
    UIButton *close = LSButton(@"", @"xmark", NO);
    close.accessibilityLabel = @"Close picker";
    close.accessibilityHint = @"Discards unapplied location or route edits. An applied session continues.";
    [close addTarget:self action:@selector(dismissPicker) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[identity, settings, close]];
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 8;
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [identity setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [settings setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [close setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
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
    self.contentStack = LSStack(@[], 16);
    [self.scroll addSubview:self.contentStack];
    UIButton *search = LSButton(@"Search places", @"magnifyingglass", NO);
    search.accessibilityHint = @"Search for a place or enter coordinates.";
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
    [self.contentStack addArrangedSubview:self.mapErrorLabel];
    [self.contentStack addArrangedSubview:self.realNoticeLabel];
    self.mapHintLabel = LSLabel(@"Tap the map or search to choose a location.", UIFontTextStyleSubheadline);
    self.mapHintLabel.textColor = UIColor.secondaryLabelColor;
    [self.contentStack addArrangedSubview:self.mapHintLabel];
    [self buildLocationDetails];
    [self.contentStack addArrangedSubview:self.locationDetails];
    [self.contentStack addArrangedSubview:self.routeDetailsPanel];
    self.appliedLabel = LSLabel(@"", UIFontTextStyleFootnote);
    self.appliedLabel.textColor = UIColor.secondaryLabelColor;
    [self.contentStack addArrangedSubview:self.appliedLabel];
    [self buildSavedUI];
    self.savedTable.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.savedTable];
    UIView *footer = [self buildFooter];
    [self.view addSubview:footer];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [header.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [header.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [self.tabs.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:12],
        [self.tabs.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [self.tabs.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [self.scroll.topAnchor constraintEqualToAnchor:self.tabs.bottomAnchor constant:12],
        [self.scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.scroll.bottomAnchor constraintEqualToAnchor:footer.topAnchor],
        [self.contentStack.topAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.topAnchor constant:4],
        [self.contentStack.leadingAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.leadingAnchor constant:20],
        [self.contentStack.trailingAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [self.contentStack.bottomAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.bottomAnchor constant:-20],
        [self.contentStack.widthAnchor constraintEqualToAnchor:self.scroll.frameLayoutGuide.widthAnchor constant:-40],
        [self.savedTable.topAnchor constraintEqualToAnchor:self.tabs.bottomAnchor constant:12],
        [self.savedTable.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.savedTable.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.savedTable.bottomAnchor constraintEqualToAnchor:footer.topAnchor],
        [footer.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [footer.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [footer.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor]
    ]];
    [self contentSizeChanged:nil];
}
- (UIView *)buildFooter {
    self.primaryButton = LSButton(@"Apply location", @"checkmark", YES);
    [self.primaryButton addTarget:self action:@selector(primaryAction) forControlEvents:UIControlEventTouchUpInside];
    self.holdButton = LSButton(@"Hold here", @"stop.fill", NO);
    self.holdButton.accessibilityHint = @"Stops route movement and holds its current point.";
    [self.holdButton addTarget:self action:@selector(routeControlTapped) forControlEvents:UIControlEventTouchUpInside];
    self.offButton = LSButton(@"Turn off", @"power", NO);
    self.offButton.accessibilityLabel = @"Turn off spoofing";
    UIButtonConfiguration *off = self.offButton.configuration;
    off.baseForegroundColor = LSErrorColor();
    off.baseBackgroundColor = LSErrorColor();
    self.offButton.configuration = off;
    [self.offButton addTarget:self action:@selector(turnOff) forControlEvents:UIControlEventTouchUpInside];
    self.playbackRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.holdButton, self.offButton]];
    self.playbackRow.distribution = UIStackViewDistributionFillEqually;
    self.playbackRow.spacing = 8;
    UIStackView *stack = LSStack(@[self.primaryButton, self.playbackRow], 8);
    UIView *footer = [[UIView alloc] init];
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    footer.backgroundColor = UIColor.systemGroupedBackgroundColor;
    [footer addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:footer.topAnchor constant:8],
        [stack.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-20],
        [stack.bottomAnchor constraintEqualToAnchor:footer.bottomAnchor constant:-8]
    ]];
    return footer;
}
- (void)buildLocationDetails {
    self.placeLabel = LSLabel(@"Choose a location", UIFontTextStyleTitle3);
    self.placeLabel.accessibilityTraits = UIAccessibilityTraitHeader;
    self.coordinateLabel = LSLabel(@"Search, tap the map, or enter coordinates.", UIFontTextStyleBody);
    self.coordinateLabel.textColor = UIColor.secondaryLabelColor;
    UIButton *coordinates = LSButton(@"Edit coordinates", @"number", NO);
    [coordinates addTarget:self action:@selector(editCoordinates) forControlEvents:UIControlEventTouchUpInside];
    self.savePlaceButton = LSButton(@"Save place", @"bookmark", NO);
    [self.savePlaceButton addTarget:self action:@selector(saveSelectedPlace) forControlEvents:UIControlEventTouchUpInside];
    self.locationDetails = LSInsetPanel(LSStack(@[self.placeLabel, self.coordinateLabel, coordinates, self.savePlaceButton], 12));
}
- (void)buildMap {
    self.mapContainer = [[UIView alloc] init];
    self.mapContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.mapContainer.layer.cornerRadius = 20;
    self.mapContainer.clipsToBounds = YES;
    NSLayoutConstraint *mapHeight = [self.mapContainer.heightAnchor constraintEqualToConstant:280];
    mapHeight.priority = 999; mapHeight.active = YES;
    [self replaceMap:nil];
    UIButton *center = LSButton(@"", @"scope", NO);
    center.accessibilityLabel = @"Center on applied location or selection";
    [center addTarget:self action:@selector(centerMap) forControlEvents:UIControlEventTouchUpInside];
    self.realCenterButton = LSButton(@"", @"location", NO);
    self.realCenterButton.accessibilityLabel = @"Center on real location";
    self.realCenterButton.hidden = YES;
    [self.realCenterButton addTarget:self action:@selector(centerReal) forControlEvents:UIControlEventTouchUpInside];
    self.mapRetryButton = LSButton(@"Retry map", @"arrow.clockwise", NO);
    self.mapRetryButton.hidden = YES;
    [self.mapRetryButton addTarget:self action:@selector(retryMap) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *buttons = LSStack(@[center, self.realCenterButton, self.mapRetryButton], 8);
    [self.mapContainer addSubview:buttons];
    [NSLayoutConstraint activateConstraints:@[
        [buttons.topAnchor constraintEqualToAnchor:self.mapContainer.topAnchor constant:12],
        [buttons.trailingAnchor constraintEqualToAnchor:self.mapContainer.trailingAnchor constant:-12],
        [buttons.widthAnchor constraintGreaterThanOrEqualToConstant:44]
    ]];
}
- (void)replaceMap:(MKCoordinateRegion *)savedRegion {
    self.mapView.delegate = nil;
    [self.mapView removeFromSuperview];
    self.mapView = [[MKMapView alloc] init];
    self.mapView.translatesAutoresizingMaskIntoConstraints = NO;
    self.mapView.delegate = self;
    self.mapView.showsUserLocation = NO;
    self.mapView.showsCompass = NO;
    self.mapView.showsScale = YES;
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
    if (self.tab == LSPickerTabRoute) [self assignEndpoint:self.endpoint coordinate:coordinate name:@"Map point"];
    else [self setSelection:coordinate name:@"Map point"];
}
- (void)mapHeld:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    CLLocationCoordinate2D coordinate = [self.mapView convertPoint:[gesture locationInView:self.mapView] toCoordinateFromView:self.mapView];
    if (self.tab == LSPickerTabRoute) { [self assignEndpoint:self.endpoint coordinate:coordinate name:@"Map point"]; return; }
    [self setSelection:coordinate name:@"Map point"];
    [self saveSelectedPlace];
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
    self.mapHintLabel.text = route ? (self.endpoint == LSEndpointFrom ? @"Tap the map to set From, or tap From to search." : @"Tap the map to set To, or tap To to search.") : @"Tap the map or search to choose a location.";
    if (location && self.hasSelection) [self renderSelectedLocation];
    [self updateRouteUI];
    [self reloadSavedPlaces];
    [self updateRadiusPreview];
    [self updateFooter];
}
- (void)tabChanged {
    self.selectionRevision++;
    [self cancelDirections];
    self.tab = self.tabs.selectedSegmentIndex;
    [self updateWorkspace];
    [self updateRealLocation];
    [self.scroll setContentOffset:CGPointZero animated:NO];
}
- (void)showMessage:(NSString *)message { self.mapHintLabel.text = message; LSAnnounce(message); }
- (void)refreshSession {
    LSSessionSnapshot *snapshot = LSSessionController.shared.snapshot;
    NSArray *names = @[@"Off", @"Holding location", @"Moving", @"Paused"];
    self.statusLabel.text = names[snapshot.mode];
    self.statusLabel.accessibilityLabel = [NSString stringWithFormat:@"Applied session: %@", self.statusLabel.text];
    self.appliedLabel.hidden = snapshot.mode == LSSessionModeOff;
    self.appliedLabel.text = snapshot.location ? [NSString stringWithFormat:@"Applied location: %@", LSCoordinateText(snapshot.location.coordinate)] : @"";
    if (snapshot.location) {
        if (!self.appliedPin) { self.appliedPin = [[LSMovingAnnotation alloc] init]; [self.mapView addAnnotation:self.appliedPin]; }
        self.appliedPin.title = snapshot.mode == LSSessionModeMoving ? @"Moving location" : @"Applied location";
        self.appliedPin.coordinate = snapshot.location.coordinate;
        [self.mapView viewForAnnotation:self.appliedPin].accessibilityLabel = [NSString stringWithFormat:@"%@. %@", self.appliedPin.title, LSCoordinateText(snapshot.location.coordinate)];
    } else if (self.appliedPin) {
        [self.mapView removeAnnotation:self.appliedPin]; self.appliedPin = nil;
    }
    if (self.previousMode != snapshot.mode) {
        LSAnnounce([NSString stringWithFormat:@"Location %@", self.statusLabel.text.lowercaseString]);
        self.previousMode = snapshot.mode;
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
    NSString *title;
    if (controlsCurrentRoute) title = mode == LSSessionModePaused ? @"Resume route" : @"Pause route";
    else if (self.tab == LSPickerTabRoute) title = mode == LSSessionModeStatic && self.fetchedRoute && self.fetchedRoute == LSSessionController.shared.retainedRoute && !self.routeDraftChanged
        ? @"Replay route" : (mode == LSSessionModeOff ? @"Start route" : @"Replace route");
    else title = mode == LSSessionModeOff ? @"Apply location" : @"Replace location";
    UIButtonConfiguration *primary = self.primaryButton.configuration;
    primary.title = title;
    primary.image = [UIImage systemImageNamed:controlsCurrentRoute ? (mode == LSSessionModePaused ? @"play.fill" : @"pause.fill") : @"checkmark"];
    self.primaryButton.configuration = primary;
    self.primaryButton.accessibilityLabel = title;
    self.primaryButton.hidden = self.tab == LSPickerTabSaved;
    self.primaryButton.enabled = self.tab == LSPickerTabRoute ? (controlsCurrentRoute || (self.fetchedRoute && !self.directions)) : self.hasSelection;
    UIButtonConfiguration *hold = self.holdButton.configuration;
    hold.title = controlsCurrentRoute ? @"Hold here" : @"Route controls";
    hold.image = [UIImage systemImageNamed:controlsCurrentRoute ? @"stop.fill" : @"playpause"];
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
    CLLocationCoordinate2D coordinate = self.selectedCoordinate;
    NSString *name = self.selectedName;
    __weak typeof(self) weakSelf = self;
    dispatch_block_t apply = ^{
        if ([LSSessionController.shared applyStaticCoordinate:coordinate]) {
            [PersistenceManager.shared recordRecentCoordinate:coordinate name:name];
            [weakSelf showMessage:@"Location applied. Close the picker to return to your app."];
            [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
            [weakSelf refreshSession];
        }
    };
    // The visible Replace location action explicitly commits this reversible change.
    apply();
}
- (void)togglePause {
    if (LSSessionController.shared.snapshot.mode == LSSessionModePaused) [LSSessionController.shared resume];
    else [LSSessionController.shared pause];
    [self refreshSession];
}
- (void)routeControlTapped { if (!self.holdButton.showsMenuAsPrimaryAction) [self holdHere]; }
- (void)holdHere { [LSSessionController.shared stopAndHold]; [self refreshSession]; [self showMessage:@"Route stopped. Holding its current location."]; }
- (void)turnOff {
    [self cancelDirections];
    self.selectionRevision++;
    [LSSessionController.shared disable];
    [self refreshSession];
    [self showMessage:@"Spoofing is off. You can choose a location to apply again."];
}
- (void)confirmAction:(NSString *)title message:(NSString *)message button:(NSString *)button action:(dispatch_block_t)action {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:button style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *item) { action(); }]];
    [self presentViewController:alert animated:LSMapAnimationsEnabled() completion:nil];
}
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
        [self setSelection:coordinate name:@"Selected coordinates"];
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
    nav.sheetPresentationController.detents = @[[UISheetPresentationControllerDetent largeDetent]];
    nav.sheetPresentationController.prefersGrabberVisible = YES;
    [self presentViewController:nav animated:LSMapAnimationsEnabled() completion:nil];
}
- (void)openSettings {
    LSSettingsViewController *settings = [[LSSettingsViewController alloc] init];
    __weak typeof(self) weakSelf = self;
    settings.didSave = ^{ [weakSelf updateRadiusPreview]; [weakSelf updateRealLocation]; [weakSelf refreshSession]; };
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
- (void)centerMap {
    CLLocation *applied = LSSessionController.shared.snapshot.location;
    CLLocationCoordinate2D coordinate = applied ? applied.coordinate : self.selectedCoordinate;
    if (!CLLocationCoordinate2DIsValid(coordinate) && self.startPin) coordinate = self.startPin.coordinate;
    if (CLLocationCoordinate2DIsValid(coordinate)) [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(coordinate, 2000, 2000) animated:LSMapAnimationsEnabled()];
    else [self showMessage:@"Choose a place or enter coordinates to center the map."];
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
    view.draggable = annotation == self.pin || annotation == self.startPin || annotation == self.endPin;
    view.markerTintColor = LSAccentColor();
    view.glyphText = nil;
    view.glyphImage = [UIImage systemImageNamed:@"mappin"];
    if ([annotation isKindOfClass:LSStartAnnotation.class]) { view.markerTintColor = LSRouteColor(); view.glyphText = @"1"; view.glyphImage = nil; }
    if ([annotation isKindOfClass:LSDestinationAnnotation.class]) { view.markerTintColor = LSRouteColor(); view.glyphImage = [UIImage systemImageNamed:@"flag.fill"]; }
    if ([annotation isKindOfClass:LSMovingAnnotation.class]) { view.markerTintColor = UIColor.systemPurpleColor; view.glyphImage = [UIImage systemImageNamed:@"location.fill"]; view.draggable = NO; }
    if ([annotation isKindOfClass:LSRealAnnotation.class]) { view.glyphImage = [UIImage systemImageNamed:@"person.fill"]; view.draggable = NO; }
    view.accessibilityLabel = [NSString stringWithFormat:@"%@. %@", annotation.title ?: @"Location", LSCoordinateText(annotation.coordinate)];
    view.accessibilityHint = view.draggable ? @"Drag to edit, or use the search and coordinate buttons." : nil;
    return view;
}
- (void)mapView:(MKMapView *)map annotationView:(MKAnnotationView *)view didChangeDragState:(MKAnnotationViewDragState)newState fromOldState:(MKAnnotationViewDragState)oldState {
    (void)map; (void)oldState;
    if (newState != MKAnnotationViewDragStateEnding) return;
    if (view.annotation == self.startPin) [self assignEndpoint:LSEndpointFrom coordinate:view.annotation.coordinate name:@"Map point"];
    else if (view.annotation == self.endPin) [self assignEndpoint:LSEndpointTo coordinate:view.annotation.coordinate name:@"Map point"];
    else if (view.annotation == self.pin) [self setSelection:view.annotation.coordinate name:@"Map point"];
    [view setDragState:MKAnnotationViewDragStateNone animated:LSMapAnimationsEnabled()];
}
- (MKOverlayRenderer *)mapView:(MKMapView *)map rendererForOverlay:(id<MKOverlay>)overlay {
    (void)map;
    if ([overlay isKindOfClass:MKCircle.class]) {
        MKCircleRenderer *renderer = [[MKCircleRenderer alloc] initWithCircle:(MKCircle *)overlay];
        renderer.strokeColor = LSAccentColor(); renderer.fillColor = [LSAccentColor() colorWithAlphaComponent:0.12]; renderer.lineWidth = 1.5;
        return renderer;
    }
    MKPolylineRenderer *renderer = [[MKPolylineRenderer alloc] initWithPolyline:(MKPolyline *)overlay];
    renderer.strokeColor = LSRouteColor(); renderer.lineWidth = 5;
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
- (void)updateRealLocation {
    NSUInteger revision = ++self.realRevision;
    [self.realManager stopUpdatingLocation];
    BOOL foreground = self.view.window && (self.view.window.windowScene ? self.view.window.windowScene.activationState == UISceneActivationStateForegroundActive : UIApplication.sharedApplication.applicationState == UIApplicationStateActive);
    BOOL enabled = PersistenceManager.shared.showRealLocation && !self.closed && foreground && self.tab != LSPickerTabSaved;
    self.realNoticeLabel.hidden = !enabled;
    if (!enabled) {
        if (self.realPin) [self.mapView removeAnnotation:self.realPin];
        self.realPin = nil; self.realCenterButton.hidden = YES; return;
    }
    if (!self.realManager) {
        self.realManager = [[CLLocationManager alloc] init];
        LSMarkLibraryLocationManager(self.realManager);
        self.realManager.delegate = self;
        self.realManager.desiredAccuracy = kCLLocationAccuracyHundredMeters;
        self.realManager.distanceFilter = 50;
    }
    CLAuthorizationStatus status = self.realManager.authorizationStatus;
    if (status != kCLAuthorizationStatusAuthorizedAlways && status != kCLAuthorizationStatusAuthorizedWhenInUse) {
        if (self.realPin) [self.mapView removeAnnotation:self.realPin];
        self.realPin = nil; self.realCenterButton.hidden = YES;
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
    self.realNoticeLabel.text = @"Real location shown separately. Use the location button on the map to center it.";
}
- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    (void)error;
    if (manager == self.realManager && !self.closed) self.realNoticeLabel.text = @"Real location could not be updated. Your selected location still works.";
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { (void)table; return 2; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { (void)table; return [self savedRowsInSection:section]; }
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path { (void)table; return [self savedCell:path]; }
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path { [table deselectRowAtIndexPath:path animated:NO]; [self previewSavedPlace:path]; }
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section { (void)table; return section == 0 ? @"Saved places" : @"Recent locations"; }
- (BOOL)tableView:(UITableView *)table canEditRowAtIndexPath:(NSIndexPath *)path { (void)table; return path.section == 0 && self.savedPlaces.count > 0; }
- (BOOL)tableView:(UITableView *)table canMoveRowAtIndexPath:(NSIndexPath *)path { (void)table; return path.section == 0 && self.savedPlaces.count > 1; }
- (UITableViewCellEditingStyle)tableView:(UITableView *)table editingStyleForRowAtIndexPath:(NSIndexPath *)path { (void)table; (void)path; return UITableViewCellEditingStyleNone; }
- (NSIndexPath *)tableView:(UITableView *)table targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)source toProposedIndexPath:(NSIndexPath *)destination {
    (void)table; (void)source;
    return [NSIndexPath indexPathForRow:MIN(MAX(destination.row, 0), (NSInteger)self.savedPlaces.count - 1) inSection:0];
}
- (void)tableView:(UITableView *)table moveRowAtIndexPath:(NSIndexPath *)source toIndexPath:(NSIndexPath *)destination { (void)table; [self moveSavedPlace:source to:destination]; }
- (UIContextMenuConfiguration *)tableView:(UITableView *)table contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)path point:(CGPoint)point { (void)table; (void)point; return [self savedMenu:path]; }
@end
