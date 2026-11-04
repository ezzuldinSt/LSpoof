#import "MapPickerViewController+Private.h"
#import "PersistenceManager.h"
#import "LSMapLinks.h"
#import "LSTrackIO.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static const NSUInteger kLSMaximumStops = 10;

static NSString *LSDistance(double meters) {
    MKDistanceFormatter *formatter = [[MKDistanceFormatter alloc] init];
    formatter.unitStyle = MKDistanceFormatterUnitStyleAbbreviated;
    return [formatter stringFromDistance:MAX(0, meters)];
}
static NSString *LSDuration(double seconds) {
    if (!isfinite(seconds)) return @"—";
    NSDateComponentsFormatter *formatter = [[NSDateComponentsFormatter alloc] init];
    formatter.allowedUnits = NSCalendarUnitHour | NSCalendarUnitMinute;
    formatter.unitsStyle = NSDateComponentsFormatterUnitsStyleAbbreviated;
    return seconds < 60 ? @"under 1 min" : ([formatter stringFromTimeInterval:seconds] ?: @"—");
}
static NSString *LSWaitText(double seconds) {
    if (!isfinite(seconds) || seconds <= 0) return @"No wait";
    if (seconds < 60) return [NSString stringWithFormat:@"%.0f s", seconds];
    NSInteger minutes = (NSInteger)(seconds / 60), rest = (NSInteger)fmod(seconds, 60);
    return rest ? [NSString stringWithFormat:@"%ld min %ld s", (long)minutes, (long)rest] : [NSString stringWithFormat:@"%ld min", (long)minutes];
}
static NSString *LSClock(double seconds) {
    NSInteger total = (NSInteger)ceil(MAX(0, seconds));
    return total >= 3600 ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)(total / 3600), (long)(total / 60 % 60), (long)(total % 60)]
                         : [NSString stringWithFormat:@"%ld:%02ld", (long)(total / 60), (long)(total % 60)];
}

// Preset speeds match the engine's walking, cycling and driving modes, so those routes
// report each mode's realistic accuracy instead of always using the custom profile.
static const double kLSPresetSpeeds[] = {5, 15, 50};
static LSTransportMode LSModeForSpeed(double kmh) {
    if (fabs(kmh - kLSPresetSpeeds[0]) < 0.01) return LSTransportModeWalking;
    if (fabs(kmh - kLSPresetSpeeds[1]) < 0.01) return LSTransportModeCycling;
    if (fabs(kmh - kLSPresetSpeeds[2]) < 0.01) return LSTransportModeDriving;
    return LSTransportModeCustom;
}
static NSString *LSActivityForKmh(double kmh) {
    return kmh < 8 ? @"walking" : (kmh < 30 ? @"cycling" : @"driving");
}

static UIButton *LSEndpointButton(NSString *title, NSString *symbol, UIColor *color) {
    UIButtonConfiguration *config = UIButtonConfiguration.plainButtonConfiguration;
    config.title = title;
    config.image = [[UIImage systemImageNamed:symbol] imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
    config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold];
    config.imagePadding = 12;
    config.titlePadding = 2;
    config.baseForegroundColor = UIColor.labelColor;
    config.titleAlignment = UIButtonConfigurationTitleAlignmentLeading;
    config.contentInsets = NSDirectionalEdgeInsetsMake(8, 0, 8, 4);
    config.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *result = [attributes mutableCopy];
        result[NSFontAttributeName] = LSFont(UIFontTextStyleFootnote, UIFontWeightSemibold, 22);
        result[NSForegroundColorAttributeName] = UIColor.secondaryLabelColor;
        return result;
    };
    config.subtitleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *result = [attributes mutableCopy];
        result[NSFontAttributeName] = LSFont(UIFontTextStyleBody, UIFontWeightMedium, 30);
        result[NSForegroundColorAttributeName] = UIColor.labelColor;
        return result;
    };
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.configuration = config;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.titleLabel.numberOfLines = 0;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:52].active = YES;
    return button;
}

static UIButton *LSMenuChip(NSString *title, NSString *symbol) {
    UIButton *chip = LSChipButton(title, symbol);
    chip.showsMenuAsPrimaryAction = YES;
    return chip;
}

static void LSSetChipTitle(UIButton *chip, NSString *title) {
    UIButtonConfiguration *config = chip.configuration;
    config.title = title;
    chip.configuration = config;
    chip.accessibilityLabel = title;
}

@implementation MapPickerViewController (LSRouteUI)

#pragma mark - Building the panels

- (void)buildRouteUI {
    self.endpoint = LSEndpointFrom;
    self.draftSpeedKmh = 5;
    self.draftPaceMultiplier = 1;
    self.routeStops = [NSMutableArray array];
    self.fromButton = LSEndpointButton(@"FROM", @"circle.circle.fill", LSSuccessColor());
    self.toButton = LSEndpointButton(@"TO", @"mappin.circle.fill", LSErrorColor());
    [self.fromButton addTarget:self action:@selector(chooseEndpoint:) forControlEvents:UIControlEventTouchUpInside];
    [self.toButton addTarget:self action:@selector(chooseEndpoint:) forControlEvents:UIControlEventTouchUpInside];
    self.swapButton = LSIconButton(@"arrow.up.arrow.down", @"Reverse the route");
    [self.swapButton addTarget:self action:@selector(swapEndpoints) forControlEvents:UIControlEventTouchUpInside];
    self.stopsStack = LSStack(@[], 2);
    self.addStopButton = LSChipButton(@"Add stop", @"plus.circle.fill");
    self.addStopButton.accessibilityHint = @"Adds a place to pass through between From and To. Up to 10 stops.";
    [self.addStopButton addTarget:self action:@selector(addStopTapped) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *addRow = LSStack(@[self.addStopButton], 0);
    addRow.alignment = UIStackViewAlignmentLeading;
    UIStackView *endpoints = LSStack(@[self.fromButton, LSSeparator(), self.stopsStack, addRow, LSSeparator(), self.toButton], 4);
    UIStackView *endpointRow = LSRow(@[endpoints, self.swapButton], 10);
    self.endpointSegment = [[UISegmentedControl alloc] initWithItems:@[@"From", @"Stop", @"To"]];
    self.endpointSegment.selectedSegmentIndex = LSEndpointFrom;
    self.endpointSegment.accessibilityLabel = @"What a map tap sets";
    [self.endpointSegment.heightAnchor constraintGreaterThanOrEqualToConstant:40].active = YES;
    [self.endpointSegment addTarget:self action:@selector(endpointChanged) forControlEvents:UIControlEventValueChanged];
    UILabel *mapTarget = LSLabel(@"Map taps", UIFontTextStyleFootnote);
    mapTarget.font = LSFont(UIFontTextStyleFootnote, UIFontWeightSemibold, 22);
    mapTarget.textColor = UIColor.secondaryLabelColor;
    [mapTarget setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *targetRow = LSRow(@[mapTarget, self.endpointSegment], 10);
    self.importButton = LSMenuChip(@"Import", @"square.and.arrow.down");
    self.importButton.accessibilityLabel = @"Import a route";
    self.importButton.accessibilityHint = @"Paste an Apple Maps, Google Maps or Waze link, or open a GPX, TCX or FIT file.";
    UIStackView *importRow = LSStack(@[self.importButton], 0);
    importRow.alignment = UIStackViewAlignmentLeading;
    UIStackView *endpointContent = LSStack(@[endpointRow, targetRow, importRow], 12);
    self.routeEndpointsPanel = LSInsetPanel(endpointContent);

    self.profileSegment = [[UISegmentedControl alloc] initWithItems:@[@"Walking path", @"Driving path"]];
    self.profileSegment.selectedSegmentIndex = 0;
    self.profileSegment.accessibilityLabel = @"Route geometry";
    [self.profileSegment.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [self.profileSegment addTarget:self action:@selector(profileChanged) forControlEvents:UIControlEventValueChanged];
    NSArray *chipTitles = @[@"Walk", @"Bike", @"Drive", @"Custom", @"Recorded"];
    NSArray *chipSymbols = @[@"figure.walk", @"bicycle", @"car.fill", @"slider.horizontal.3", @"clock.arrow.circlepath"];
    NSMutableArray<UIButton *> *chips = [NSMutableArray array];
    for (NSUInteger index = 0; index < chipTitles.count; index++) {
        UIButton *chip = LSChipButton(chipTitles[index], chipSymbols[index]);
        UIButtonConfiguration *config = chip.configuration;
        config.imagePlacement = NSDirectionalRectEdgeTop;
        config.imagePadding = 4;
        config.cornerStyle = UIButtonConfigurationCornerStyleLarge;
        chip.configuration = config;
        chip.tag = (NSInteger)index;
        [chip addTarget:self action:@selector(speedChipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [chips addObject:chip];
    }
    self.speedChips = chips;
    self.speedButton = chips[3];
    self.recordedChip = chips[4];
    self.recordedChip.accessibilityHint = @"Plays the file at the pace it was recorded, including its pauses.";
    self.recordedChip.hidden = YES;
    self.speedRow = [[UIStackView alloc] initWithArrangedSubviews:chips];
    self.speedRow.distribution = UIStackViewDistributionFillEqually;
    self.speedRow.spacing = 8;
    self.motionButton = LSMenuChip(@"Steady speed", @"speedometer");
    self.motionButton.accessibilityHint = @"Choose whether the location speeds up, brakes and slows for turns like a real trip.";
    self.waitButton = LSMenuChip(@"No wait at stops", @"hourglass");
    self.waitButton.accessibilityHint = @"How long to stay at each stop before moving on.";
    UIStackView *motionRow = LSRow(@[self.motionButton, self.waitButton], 8);
    motionRow.distribution = UIStackViewDistributionFillProportionally;
    UIStackView *motionWrap = LSStack(@[motionRow], 0);
    motionWrap.alignment = UIStackViewAlignmentLeading;
    UILabel *explanation = LSLabel(@"Path decides the streets you follow. Speed and motion only change how the location moves along them.", UIFontTextStyleFootnote);
    explanation.textColor = UIColor.secondaryLabelColor;
    self.buildRouteButton = LSButton(@"Build route", @"point.topleft.down.to.point.bottomright.curvepath", NO);
    [self.buildRouteButton addTarget:self action:@selector(fetchRoute) forControlEvents:UIControlEventTouchUpInside];
    self.routeSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.routeSpinner.hidesWhenStopped = YES;
    [self.routeSpinner setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    self.routeFeedback = LSLabel(@"Choose From and To. The route builds automatically.", UIFontTextStyleSubheadline);
    self.routeFeedback.textColor = UIColor.secondaryLabelColor;
    UIStackView *feedbackRow = LSRow(@[self.routeSpinner, self.routeFeedback], 8);
    self.routeSummary = LSLabel(@"", UIFontTextStyleHeadline);
    self.routeSummary.font = LSFont(UIFontTextStyleHeadline, UIFontWeightSemibold, 28);
    self.finishButton = LSMenuChip(@"Finish in…", @"flag.checkered");
    self.finishButton.accessibilityHint = @"Sets the speed so the trip takes the time you choose, such as another app's arrival estimate.";
    self.shareButton = LSMenuChip(@"Share", @"square.and.arrow.up");
    self.shareButton.accessibilityLabel = @"Share or export the route";
    UIStackView *tools = LSRow(@[self.finishButton, self.shareButton], 8);
    UIStackView *toolsWrap = LSStack(@[tools], 0);
    toolsWrap.alignment = UIStackViewAlignmentLeading;

    self.progressPercentLabel = LSLabel(@"0%", UIFontTextStyleTitle1);
    self.progressPercentLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleTitle1] scaledFontForFont:[UIFont monospacedDigitSystemFontOfSize:28 weight:UIFontWeightBold] maximumPointSize:44];
    self.progressPercentLabel.textColor = LSRouteColor();
    [self.progressPercentLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    self.progressLabel = LSLabel(@"", UIFontTextStyleSubheadline);
    self.progressLabel.textColor = UIColor.secondaryLabelColor;
    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.progressTintColor = LSRouteColor();
    self.progressView.trackTintColor = UIColor.tertiarySystemFillColor;
    self.progressView.layer.cornerRadius = 3;
    self.progressView.clipsToBounds = YES;
    self.progressView.accessibilityLabel = @"Applied route progress";
    [self.progressView.heightAnchor constraintEqualToConstant:6].active = YES;
    UIStackView *progressTop = LSRow(@[self.progressPercentLabel, self.progressLabel], 12);
    self.slowerButton = LSIconButton(@"minus", @"Slower");
    [self.slowerButton addTarget:self action:@selector(slowerTapped) forControlEvents:UIControlEventTouchUpInside];
    self.fasterButton = LSIconButton(@"plus", @"Faster");
    [self.fasterButton addTarget:self action:@selector(fasterTapped) forControlEvents:UIControlEventTouchUpInside];
    self.liveSpeedLabel = LSLabel(@"", UIFontTextStyleSubheadline);
    self.liveSpeedLabel.font = LSFont(UIFontTextStyleSubheadline, UIFontWeightSemibold, 24);
    self.liveSpeedLabel.textAlignment = NSTextAlignmentCenter;
    self.liveSpeedRow = LSRow(@[self.slowerButton, self.liveSpeedLabel, self.fasterButton], 10);
    self.liveSpeedRow.alignment = UIStackViewAlignmentCenter;
    UIStackView *progressContent = LSStack(@[LSSectionLabel(@"Applied route"), progressTop, self.progressView, self.liveSpeedRow], 10);
    self.progressPanel = progressContent;

    UIStackView *content = LSStack(@[LSSectionLabel(@"Path"), self.profileSegment,
        LSSectionLabel(@"Playback speed"), self.speedRow, motionWrap, explanation,
        self.buildRouteButton, feedbackRow, self.routeSummary, toolsWrap, LSSeparator(), progressContent], 12);
    [content setCustomSpacing:6 afterView:content.arrangedSubviews[0]];
    [content setCustomSpacing:18 afterView:self.profileSegment];
    [content setCustomSpacing:6 afterView:content.arrangedSubviews[2]];
    [content setCustomSpacing:16 afterView:explanation];
    self.routeDetailsPanel = LSInsetPanel(content);
    [self rebuildStopRows];
}

- (void)restoreRoute {
    LSSessionController *session = LSSessionController.shared;
    LSRoute *route = session.retainedRoute;
    if (!route || route.pointCount < 2) return;
    self.fetchedRoute = route;
    self.routePolyline = route.polyline;
    NSArray<LSRouteWaypoint *> *waypoints = route.waypoints;
    LSRouteWaypoint *first = waypoints.firstObject, *last = waypoints.lastObject;
    self.startPin = [[LSStartAnnotation alloc] init];
    self.startPin.coordinate = first ? first.coordinate : route.coordinates[0];
    self.startPin.title = @"From";
    self.startPin.subtitle = first.name;
    self.endPin = [[LSDestinationAnnotation alloc] init];
    self.endPin.coordinate = last ? last.coordinate : route.coordinates[route.pointCount - 1];
    self.endPin.title = @"To";
    self.endPin.subtitle = last.name;
    [self.routeStops removeAllObjects];
    for (NSUInteger index = 1; index + 1 < waypoints.count; index++) {
        LSStopAnnotation *stop = [[LSStopAnnotation alloc] init];
        stop.coordinate = waypoints[index].coordinate;
        stop.subtitle = waypoints[index].name;
        [self.routeStops addObject:stop];
    }
    [self renumberStops];
    LSPlaybackOptions *options = LSRouteSimulator.shared.options;
    self.draftSpeedKmh = options.speedKmh;
    self.draftRecordedPace = options.recordedPace && route.hasTiming;
    self.draftPaceMultiplier = options.paceMultiplier;
    self.profileSegment.selectedSegmentIndex = route.transportType == MKDirectionsTransportTypeAutomobile ? 1 : 0;
    self.tab = LSPickerTabRoute;
    self.tabs.selectedSegmentIndex = self.tab;
    self.endpointSegment.selectedSegmentIndex = LSEndpointTo;
    self.endpoint = LSEndpointTo;
    [self.mapView addAnnotations:@[self.startPin, self.endPin]];
    [self.mapView addAnnotations:self.routeStops];
    [self.mapView addOverlay:self.routePolyline];
    [self.mapView setVisibleMapRect:self.routePolyline.boundingMapRect edgePadding:UIEdgeInsetsMake(48, 32, 48, 72) animated:NO];
    self.routeFeedback.text = LSRouteSimulator.shared.isSimulating ? @"The applied route keeps moving when you close the picker." : @"Route retained. Replay it when you’re ready.";
    [self rebuildStopRows];
    [self updateRouteUI];
}

#pragma mark - Endpoints and stops

- (NSArray<LSRouteWaypoint *> *)draftWaypoints {
    if (!self.startPin || !self.endPin) return @[];
    NSMutableArray *waypoints = [NSMutableArray arrayWithObject:[LSRouteWaypoint waypointWithName:self.startPin.subtitle coordinate:self.startPin.coordinate]];
    for (LSStopAnnotation *stop in self.routeStops) [waypoints addObject:[LSRouteWaypoint waypointWithName:stop.subtitle coordinate:stop.coordinate]];
    [waypoints addObject:[LSRouteWaypoint waypointWithName:self.endPin.subtitle coordinate:self.endPin.coordinate]];
    return waypoints;
}

- (void)renumberStops {
    for (NSUInteger index = 0; index < self.routeStops.count; index++) {
        self.routeStops[index].title = [NSString stringWithFormat:@"Stop %lu", (unsigned long)index + 1];
        MKMarkerAnnotationView *view = (id)[self.mapView viewForAnnotation:self.routeStops[index]];
        if ([view isKindOfClass:MKMarkerAnnotationView.class]) view.glyphText = [NSString stringWithFormat:@"%lu", (unsigned long)index + 1];
    }
}

- (void)rebuildStopRows {
    for (UIView *view in self.stopsStack.arrangedSubviews) { [self.stopsStack removeArrangedSubview:view]; [view removeFromSuperview]; }
    for (NSUInteger index = 0; index < self.routeStops.count; index++) {
        LSStopAnnotation *stop = self.routeStops[index];
        NSString *symbol = [NSString stringWithFormat:@"%lu.circle.fill", (unsigned long)index + 1];
        UIButton *button = LSEndpointButton([NSString stringWithFormat:@"STOP %lu", (unsigned long)index + 1], symbol, LSWarningColor());
        UIButtonConfiguration *config = button.configuration;
        config.subtitle = stop.subtitle.length ? stop.subtitle : LSCoordinateText(stop.coordinate);
        button.configuration = config;
        button.accessibilityLabel = [NSString stringWithFormat:@"Stop %lu: %@", (unsigned long)index + 1, config.subtitle];
        button.accessibilityHint = @"Change, move or remove this stop.";
        button.showsMenuAsPrimaryAction = YES;
        button.menu = [self menuForStopAtIndex:index];
        [self.stopsStack addArrangedSubview:button];
    }
    self.stopsStack.hidden = self.routeStops.count == 0;
    self.addStopButton.enabled = self.routeStops.count < kLSMaximumStops;
    LSSetChipTitle(self.addStopButton, self.routeStops.count ? [NSString stringWithFormat:@"Add stop (%lu of %lu)", (unsigned long)self.routeStops.count, (unsigned long)kLSMaximumStops] : @"Add stop");
}

- (UIMenu *)menuForStopAtIndex:(NSUInteger)index {
    __weak typeof(self) weakSelf = self;
    UIAction *change = [UIAction actionWithTitle:@"Change place…" image:[UIImage systemImageNamed:@"magnifyingglass"] identifier:nil handler:^(__unused UIAction *action) {
        typeof(self) self = weakSelf;
        if (!self || index >= self.routeStops.count) return;
        LSStopAnnotation *stop = self.routeStops[index];
        [self openPlaceChooser:[NSString stringWithFormat:@"Choose stop %lu", (unsigned long)index + 1] coordinate:stop.coordinate completion:^(CLLocationCoordinate2D coordinate, NSString *name) {
            typeof(self) self = weakSelf;
            if (!self || index >= self.routeStops.count) return;
            [self moveStop:self.routeStops[index] to:coordinate name:name];
        }];
    }];
    UIAction *up = [UIAction actionWithTitle:@"Move earlier" image:[UIImage systemImageNamed:@"arrow.up"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf moveStopAtIndex:index offset:-1]; }];
    UIAction *down = [UIAction actionWithTitle:@"Move later" image:[UIImage systemImageNamed:@"arrow.down"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf moveStopAtIndex:index offset:1]; }];
    if (index == 0) up.attributes = UIMenuElementAttributesDisabled;
    if (index + 1 >= self.routeStops.count) down.attributes = UIMenuElementAttributesDisabled;
    UIAction *remove = [UIAction actionWithTitle:@"Remove stop" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf removeStopAtIndex:index]; }];
    remove.attributes = UIMenuElementAttributesDestructive;
    UIMenu *order = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[up, down]];
    return [UIMenu menuWithTitle:[NSString stringWithFormat:@"Stop %lu", (unsigned long)index + 1] children:@[change, order, remove]];
}

- (void)stopsChanged {
    [self renumberStops];
    [self rebuildStopRows];
    [self invalidateRouteDraft];
    [self updateRouteUI];
    if (self.startPin && self.endPin) [self fetchRoute];
}

- (void)addStopAt:(CLLocationCoordinate2D)coordinate name:(NSString *)name {
    if (!CLLocationCoordinate2DIsValid(coordinate)) return;
    if (self.routeStops.count >= kLSMaximumStops) {
        [self showMessage:@"A route can have up to 10 stops." symbol:@"exclamationmark.circle.fill"];
        LSHapticWarning();
        return;
    }
    self.selectionRevision++;
    LSStopAnnotation *stop = [[LSStopAnnotation alloc] init];
    stop.coordinate = coordinate;
    stop.subtitle = name.length ? name : @"Map point";
    [self.routeStops addObject:stop];
    [self.mapView addAnnotation:stop];
    LSAnnounce([NSString stringWithFormat:@"Stop %lu added", (unsigned long)self.routeStops.count]);
    [self stopsChanged];
}

- (void)moveStop:(LSStopAnnotation *)stop to:(CLLocationCoordinate2D)coordinate name:(NSString *)name {
    if (!CLLocationCoordinate2DIsValid(coordinate) || ![self.routeStops containsObject:stop]) return;
    stop.coordinate = coordinate;
    stop.subtitle = name.length ? name : @"Map point";
    [self stopsChanged];
}

- (void)moveStopAtIndex:(NSUInteger)index offset:(NSInteger)offset {
    NSInteger target = (NSInteger)index + offset;
    if (index >= self.routeStops.count || target < 0 || target >= (NSInteger)self.routeStops.count) return;
    LSStopAnnotation *stop = self.routeStops[index];
    [self.routeStops removeObjectAtIndex:index];
    [self.routeStops insertObject:stop atIndex:(NSUInteger)target];
    LSHapticSelection();
    [self stopsChanged];
}

- (void)removeStopAtIndex:(NSUInteger)index {
    if (index >= self.routeStops.count) return;
    [self.mapView removeAnnotation:self.routeStops[index]];
    [self.routeStops removeObjectAtIndex:index];
    LSHapticSelection();
    [self stopsChanged];
}

- (void)addStopTapped {
    __weak typeof(self) weakSelf = self;
    CLLocationCoordinate2D near = self.routeStops.lastObject ? self.routeStops.lastObject.coordinate : (self.startPin ? self.startPin.coordinate : kCLLocationCoordinate2DInvalid);
    [self openPlaceChooser:@"Add a stop" coordinate:near completion:^(CLLocationCoordinate2D coordinate, NSString *name) {
        [weakSelf addStopAt:coordinate name:name];
    }];
}

- (void)chooseEndpoint:(UIButton *)sender {
    LSEndpoint endpoint = sender == self.fromButton ? LSEndpointFrom : LSEndpointTo;
    self.endpoint = endpoint;
    self.endpointSegment.selectedSegmentIndex = endpoint;
    MKPointAnnotation *pin = endpoint == LSEndpointFrom ? self.startPin : self.endPin;
    __weak typeof(self) weakSelf = self;
    [self openPlaceChooser:endpoint == LSEndpointFrom ? @"Choose From" : @"Choose To" coordinate:pin ? pin.coordinate : kCLLocationCoordinate2DInvalid completion:^(CLLocationCoordinate2D coordinate, NSString *name) {
        typeof(self) self = weakSelf;
        if (!self) return;
        [self assignEndpoint:endpoint coordinate:coordinate name:name];
        if (!self.fetchedRoute && !self.directions) [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(coordinate, 2000, 2000) animated:LSMapAnimationsEnabled()];
    }];
    [self endpointChanged];
}

- (void)endpointChanged {
    self.endpoint = self.endpointSegment.selectedSegmentIndex;
    switch (self.endpoint) {
        case LSEndpointFrom: self.mapHintLabel.text = @"Tap the map to set From, or tap From to search."; break;
        case LSEndpointStop: self.mapHintLabel.text = @"Tap the map to add a stop. Tap a stop above to change or remove it."; break;
        case LSEndpointTo: self.mapHintLabel.text = @"Tap the map to set To, or tap To to search."; break;
    }
}

- (void)assignEndpoint:(LSEndpoint)endpoint coordinate:(CLLocationCoordinate2D)coordinate name:(NSString *)name {
    [self assignEndpoint:endpoint coordinate:coordinate name:name build:YES];
}

- (void)assignEndpoint:(LSEndpoint)endpoint coordinate:(CLLocationCoordinate2D)coordinate name:(NSString *)name build:(BOOL)build {
    if (!CLLocationCoordinate2DIsValid(coordinate)) return;
    if (endpoint == LSEndpointStop) { [self addStopAt:coordinate name:name]; return; }
    [self invalidateRouteDraft];
    self.selectionRevision++;
    if (endpoint == LSEndpointFrom) {
        if (!self.startPin) self.startPin = [[LSStartAnnotation alloc] init];
        self.startPin.coordinate = coordinate;
        self.startPin.title = @"From";
        self.startPin.subtitle = name;
        if (![self.mapView.annotations containsObject:self.startPin]) [self.mapView addAnnotation:self.startPin];
    } else {
        if (!self.endPin) self.endPin = [[LSDestinationAnnotation alloc] init];
        self.endPin.coordinate = coordinate;
        self.endPin.title = @"To";
        self.endPin.subtitle = name;
        if (![self.mapView.annotations containsObject:self.endPin]) [self.mapView addAnnotation:self.endPin];
    }
    [self updateRouteUI];
    if (build && self.startPin && self.endPin) [self fetchRoute];
}

// Reverses the whole trip: To becomes From and the stops run backwards.
- (void)swapEndpoints {
    if (!self.startPin || !self.endPin) return;
    CLLocationCoordinate2D from = self.startPin.coordinate, to = self.endPin.coordinate;
    NSString *fromName = self.startPin.subtitle ?: @"Map point", *toName = self.endPin.subtitle ?: @"Map point";
    LSHapticSelection();
    NSArray *reversed = self.routeStops.reverseObjectEnumerator.allObjects;
    [self.routeStops setArray:reversed];
    [self renumberStops];
    [self rebuildStopRows];
    [self assignEndpoint:LSEndpointFrom coordinate:to name:toName build:NO];
    [self assignEndpoint:LSEndpointTo coordinate:from name:fromName build:YES];
}

- (void)clearRouteDraft {
    [self invalidateRouteDraft];
    for (MKPointAnnotation *pin in self.routeStops) [self.mapView removeAnnotation:pin];
    [self.routeStops removeAllObjects];
    if (self.startPin) [self.mapView removeAnnotation:self.startPin];
    if (self.endPin) [self.mapView removeAnnotation:self.endPin];
    self.startPin = nil;
    self.endPin = nil;
    [self rebuildStopRows];
}

#pragma mark - Directions

- (void)cancelDirections {
    if (self.directions) self.routeFeedback.text = @"Route lookup canceled. Tap Build route to try again.";
    self.routeRevision++;
    [self.directions cancel];
    self.directions = nil;
    [self.linkSearch cancel];
    self.linkSearch = nil;
    [self.routeSpinner stopAnimating];
    self.buildRouteButton.enabled = self.startPin && self.endPin;
    [self updateFooter];
}

- (void)invalidateRouteDraft {
    [self cancelDirections];
    if (self.routePolyline) [self.mapView removeOverlay:self.routePolyline];
    self.routePolyline = nil;
    self.fetchedRoute = nil;
    self.draftRecordedPace = NO;
    self.routeDraftChanged = YES;
    self.routeFeedback.textColor = UIColor.secondaryLabelColor;
    self.routeFeedback.text = LSSessionController.shared.snapshot.mode != LSSessionModeOff
        ? @"Editing a new route. The applied session continues until you replace it."
        : @"Choose From and To. The route builds automatically.";
}

- (void)profileChanged {
    BOOL shouldRefetch = self.startPin && self.endPin;
    LSHapticSelection();
    [self invalidateRouteDraft];
    [self updateRouteUI];
    if (shouldRefetch) [self fetchRoute];
}

- (void)fetchRoute {
    if (!self.startPin || !self.endPin || self.closed) return;
    [self cancelDirections];
    NSArray<LSRouteWaypoint *> *waypoints = [self draftWaypoints];
    for (NSUInteger index = 1; index < waypoints.count; index++) {
        CLLocation *a = [[CLLocation alloc] initWithLatitude:waypoints[index - 1].coordinate.latitude longitude:waypoints[index - 1].coordinate.longitude];
        CLLocation *b = [[CLLocation alloc] initWithLatitude:waypoints[index].coordinate.latitude longitude:waypoints[index].coordinate.longitude];
        if ([a distanceFromLocation:b] >= 10) continue;
        // MapKit answers identical endpoints with a generic failure.
        self.routeFeedback.textColor = LSErrorColor();
        self.routeFeedback.text = waypoints.count == 2
            ? @"From and To are the same place. Move one of them to build a route."
            : [NSString stringWithFormat:@"%@ and %@ are the same place. Move or remove one of them.", [self legName:index - 1 count:waypoints.count], [self legName:index count:waypoints.count]];
        LSAnnounce(self.routeFeedback.text);
        [self updateRouteUI];
        return;
    }
    self.routeFeedback.textColor = UIColor.secondaryLabelColor;
    self.routeFeedback.text = @"Building route… You can keep using the current session.";
    MKDirectionsTransportType transport = self.profileSegment.selectedSegmentIndex == 1 ? MKDirectionsTransportTypeAutomobile : MKDirectionsTransportTypeWalking;
    [self.routeSpinner startAnimating];
    [self fetchLegs:waypoints legs:[NSMutableArray array] transport:transport revision:self.routeRevision];
    [self updateRouteUI];
}

- (NSString *)legName:(NSUInteger)index count:(NSUInteger)count {
    if (index == 0) return @"From";
    if (index + 1 == count) return @"To";
    return [NSString stringWithFormat:@"Stop %lu", (unsigned long)index];
}

// One MapKit request per leg, in order, so each stop is actually visited.
- (void)fetchLegs:(NSArray<LSRouteWaypoint *> *)waypoints legs:(NSMutableArray<MKRoute *> *)legs transport:(MKDirectionsTransportType)transport revision:(NSUInteger)revision {
    NSUInteger index = legs.count;
    if (index + 1 >= waypoints.count) { [self finishLegs:legs waypoints:waypoints]; return; }
    if (waypoints.count > 2) {
        self.routeFeedback.text = [NSString stringWithFormat:@"Building route… part %lu of %lu.", (unsigned long)index + 1, (unsigned long)waypoints.count - 1];
    }
    MKDirectionsRequest *request = [[MKDirectionsRequest alloc] init];
    request.source = [[MKMapItem alloc] initWithPlacemark:[[MKPlacemark alloc] initWithCoordinate:waypoints[index].coordinate]];
    request.destination = [[MKMapItem alloc] initWithPlacemark:[[MKPlacemark alloc] initWithCoordinate:waypoints[index + 1].coordinate]];
    request.transportType = transport;
    request.requestsAlternateRoutes = NO;
    self.directions = [self directionsForRequest:request];
    __weak typeof(self) weakSelf = self;
    [self.directions calculateDirectionsWithCompletionHandler:^(MKDirectionsResponse *response, NSError *error) {
        typeof(self) self = weakSelf;
        if (!self || self.closed || revision != self.routeRevision || self.tab != LSPickerTabRoute) return;
        self.directions = nil;
        MKRoute *leg = response.routes.firstObject;
        if (error || !leg || leg.polyline.pointCount < 2 || !isfinite(leg.distance) || leg.distance <= 0) {
            [self.routeSpinner stopAnimating];
            self.routeFeedback.textColor = LSErrorColor();
            NSString *between = waypoints.count == 2 ? @"these points" : [NSString stringWithFormat:@"%@ and %@", [self legName:index count:waypoints.count], [self legName:index + 1 count:waypoints.count]];
            self.routeFeedback.text = error.code == MKErrorDirectionsNotFound || !error
                ? [NSString stringWithFormat:@"No route between %@. Try the other path type or move a point.", between]
                : (error.code == MKErrorLoadingThrottled ? @"Apple Maps is limiting requests. Wait a minute and tap Build route."
                                                         : @"Directions are unavailable right now. Check your connection and tap Build route.");
            LSAnnounce(self.routeFeedback.text);
            LSHapticWarning();
            [self updateRouteUI];
            return;
        }
        [legs addObject:leg];
        [self fetchLegs:waypoints legs:legs transport:transport revision:revision];
    }];
}

- (void)finishLegs:(NSArray<MKRoute *> *)legs waypoints:(NSArray<LSRouteWaypoint *> *)waypoints {
    [self.routeSpinner stopAnimating];
    LSRoute *route = [LSRoute routeWithLegs:legs waypoints:waypoints];
    if (!route) {
        self.routeFeedback.textColor = LSErrorColor();
        self.routeFeedback.text = @"This route could not be built. Move a point and try again.";
        [self updateRouteUI];
        return;
    }
    [self showDraftRoute:route];
    self.routeFeedback.text = LSSessionController.shared.snapshot.mode == LSSessionModeOff
        ? @"Route ready. Tap Start route when you’re ready."
        : @"Route ready. Replace the applied session to follow it.";
    [self updateRouteUI];
    LSAnnounce(@"Route ready");
}

- (void)showDraftRoute:(LSRoute *)route {
    if (self.routePolyline) [self.mapView removeOverlay:self.routePolyline];
    self.fetchedRoute = route;
    self.routePolyline = route.polyline;
    [self.mapView addOverlay:self.routePolyline];
    [self.mapView setVisibleMapRect:self.routePolyline.boundingMapRect edgePadding:UIEdgeInsetsMake(48, 32, 48, 72) animated:LSMapAnimationsEnabled()];
}

- (MKDirections *)directionsForRequest:(MKDirectionsRequest *)request {
    return [[MKDirections alloc] initWithRequest:request];
}

#pragma mark - Options

- (LSPlaybackOptions *)draftOptions {
    LSPlaybackOptions *options = [LSPlaybackOptions optionsWithSpeedKmh:self.draftSpeedKmh];
    PersistenceManager *store = PersistenceManager.shared;
    options.smooth = store.smoothMotion;
    options.accelerationProfile = (LSAccelerationProfile)store.accelerationProfile;
    options.stopDwell = store.stopDwell;
    options.recordedPace = self.draftRecordedPace && self.fetchedRoute.hasTiming;
    options.paceMultiplier = isfinite(self.draftPaceMultiplier) && self.draftPaceMultiplier >= 0.1 ? self.draftPaceMultiplier : 1;
    return options.isValid ? options : [LSPlaybackOptions optionsWithSpeedKmh:5];
}

- (BOOL)isPlayingDraft {
    return !self.routeDraftChanged && self.fetchedRoute && self.fetchedRoute == LSSessionController.shared.retainedRoute && LSRouteSimulator.shared.isSimulating;
}

- (void)optionsChanged:(NSString *)message {
    if ([self isPlayingDraft]) {
        [LSSessionController.shared updatePlaybackOptions:[self draftOptions]];
        if (message) self.routeFeedback.text = message;
    }
    [self updateRouteUI];
}

- (UIMenu *)motionMenu {
    PersistenceManager *store = PersistenceManager.shared;
    __weak typeof(self) weakSelf = self;
    UIAction *steady = [UIAction actionWithTitle:@"Steady speed" image:[UIImage systemImageNamed:@"equal"] identifier:nil handler:^(__unused UIAction *action) {
        PersistenceManager.shared.smoothMotion = NO;
        [weakSelf optionsChanged:@"Motion updated: steady speed."];
    }];
    steady.subtitle = @"Moves at the set speed the whole way";
    steady.state = store.smoothMotion ? UIMenuElementStateOff : UIMenuElementStateOn;
    NSMutableArray *styles = [NSMutableArray arrayWithObject:steady];
    NSArray *names = @[@"Smooth · Gentle", @"Smooth · Normal", @"Smooth · Sporty"];
    NSArray *details = @[@"Eases off early, like a careful driver", @"Speeds up, brakes and slows for turns", @"Quicker starts and later braking"];
    for (NSInteger profile = 0; profile < 3; profile++) {
        UIAction *action = [UIAction actionWithTitle:names[profile] image:nil identifier:nil handler:^(__unused UIAction *item) {
            PersistenceManager.shared.smoothMotion = YES;
            PersistenceManager.shared.accelerationProfile = profile;
            [weakSelf optionsChanged:@"Motion updated."];
        }];
        action.subtitle = details[profile];
        action.state = store.smoothMotion && store.accelerationProfile == profile ? UIMenuElementStateOn : UIMenuElementStateOff;
        [styles addObject:action];
    }
    return [UIMenu menuWithTitle:@"Motion" image:nil identifier:nil options:UIMenuOptionsSingleSelection children:styles];
}

- (UIMenu *)waitMenu {
    double current = PersistenceManager.shared.stopDwell;
    __weak typeof(self) weakSelf = self;
    NSMutableArray *items = [NSMutableArray array];
    BOOL matched = NO;
    for (NSNumber *value in @[@0, @15, @30, @60, @120, @300]) {
        double seconds = value.doubleValue;
        UIAction *action = [UIAction actionWithTitle:seconds > 0 ? LSWaitText(seconds) : @"Don't wait" image:nil identifier:nil handler:^(__unused UIAction *item) {
            [weakSelf setStopWait:seconds];
        }];
        if (fabs(current - seconds) < 0.5) { action.state = UIMenuElementStateOn; matched = YES; }
        [items addObject:action];
    }
    UIAction *custom = [UIAction actionWithTitle:matched ? @"Custom…" : [NSString stringWithFormat:@"Custom (%@)…", LSWaitText(current)] image:[UIImage systemImageNamed:@"slider.horizontal.3"] identifier:nil handler:^(__unused UIAction *item) {
        [weakSelf enterCustomWait];
    }];
    if (!matched) custom.state = UIMenuElementStateOn;
    [items addObject:custom];
    return [UIMenu menuWithTitle:@"Wait at each stop" image:nil identifier:nil options:UIMenuOptionsSingleSelection children:items];
}

- (void)setStopWait:(double)seconds {
    if (!isfinite(seconds) || seconds < 0 || seconds > 3600) return;
    PersistenceManager.shared.stopDwell = seconds;
    [self optionsChanged:@"Wait at stops updated."];
}

- (void)enterCustomWait {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Wait at each stop" message:@"Enter minutes, from 0 to 60. Decimals are fine, like 1.5." preferredStyle:UIAlertControllerStyleAlert];
    double current = PersistenceManager.shared.stopDwell / 60.0;
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeDecimalPad;
        field.text = LSFormatDecimal(current, 1);
        field.placeholder = @"minutes";
        field.accessibilityLabel = @"Wait in minutes";
    }];
    __weak UIAlertController *weakAlert = alert;
    __weak typeof(self) weakSelf = self;
    UIAlertAction *save = [UIAlertAction actionWithTitle:@"Set wait" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSNumber *number = LSParseDecimal(weakAlert.textFields.firstObject.text, NSLocale.currentLocale);
        if (number && number.doubleValue >= 0 && number.doubleValue <= 60) [weakSelf setStopWait:round(number.doubleValue * 60)];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:save];
    alert.preferredAction = save;
    [self presentViewController:alert animated:LSMapAnimationsEnabled() completion:nil];
}

#pragma mark - Finish in

- (UIMenu *)finishMenu {
    LSRoute *route = self.fetchedRoute;
    __weak typeof(self) weakSelf = self;
    NSMutableArray *items = [NSMutableArray array];
    if (route.expectedTravelTime > 60 && !route.fromTrack) {
        NSTimeInterval eta = route.expectedTravelTime;
        UIAction *match = [UIAction actionWithTitle:[NSString stringWithFormat:@"Match Apple Maps (%@)", LSDuration(eta)] image:[UIImage systemImageNamed:@"applelogo"] identifier:nil handler:^(__unused UIAction *action) {
            [weakSelf finishIn:eta];
        }];
        match.subtitle = @"Apple's arrival estimate for this route";
        [items addObject:match];
    }
    if (route.hasTiming) {
        NSTimeInterval recorded = route.recordedDuration;
        UIAction *original = [UIAction actionWithTitle:[NSString stringWithFormat:@"As recorded (%@)", LSDuration(recorded)] image:[UIImage systemImageNamed:@"clock.arrow.circlepath"] identifier:nil handler:^(__unused UIAction *action) {
            typeof(self) self = weakSelf;
            self.draftRecordedPace = YES;
            self.draftPaceMultiplier = 1;
            [self optionsChanged:@"Playing at the recorded pace."];
        }];
        [items addObject:original];
    }
    UIAction *custom = [UIAction actionWithTitle:@"Finish in…" image:[UIImage systemImageNamed:@"timer"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf enterFinishTime]; }];
    custom.subtitle = @"Type the minutes another app shows, such as Google Maps or Waze";
    [items addObject:custom];
    return [UIMenu menuWithTitle:@"Arrive on time" children:items];
}

- (void)enterFinishTime {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Finish in" message:@"Enter the trip time in minutes. Waits at stops are included." preferredStyle:UIAlertControllerStyleAlert];
    LSPlaybackOptions *options = [self draftOptions];
    double current = self.fetchedRoute ? [LSRouteSimulator estimatedDurationForRoute:self.fetchedRoute options:options] / 60.0 : 15;
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeDecimalPad;
        field.text = LSFormatDecimal(round(current), 0);
        field.placeholder = @"minutes";
        field.accessibilityLabel = @"Trip time in minutes";
    }];
    __weak UIAlertController *weakAlert = alert;
    __weak typeof(self) weakSelf = self;
    UIAlertAction *save = [UIAlertAction actionWithTitle:@"Set speed" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSNumber *number = LSParseDecimal(weakAlert.textFields.firstObject.text, NSLocale.currentLocale);
        if (number && number.doubleValue > 0) [weakSelf finishIn:number.doubleValue * 60];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:save];
    alert.preferredAction = save;
    [self presentViewController:alert animated:LSMapAnimationsEnabled() completion:nil];
}

- (void)finishIn:(NSTimeInterval)seconds {
    LSRoute *route = self.fetchedRoute;
    if (!route || !isfinite(seconds) || seconds <= 0) return;
    LSPlaybackOptions *options = [self draftOptions];
    if (options.recordedPace) {
        // Recorded timing (pauses included) scales with the multiplier.
        options.paceMultiplier = 1;
        double base = [LSRouteSimulator estimatedDurationForRoute:route options:options];
        double multiplier = base / seconds;
        if (!isfinite(multiplier) || multiplier < 0.1 || multiplier > 20) {
            [self showMessage:@"That time is out of range for the recorded pace (0.1× to 20×)." symbol:@"exclamationmark.triangle.fill"];
            LSHapticWarning();
            return;
        }
        self.draftPaceMultiplier = multiplier;
        [self optionsChanged:[NSString stringWithFormat:@"Recorded pace ×%@ to finish in %@.", LSFormatDecimal(multiplier, 2), LSDuration(seconds)]];
        return;
    }
    double kmh = [LSRouteSimulator speedKmhForRoute:route options:options finishingIn:seconds];
    if (!isfinite(kmh)) {
        [self showMessage:@"No speed from 1 to 500 km/h finishes in that time. Shorten the waits or pick another time." symbol:@"exclamationmark.triangle.fill"];
        LSHapticWarning();
        return;
    }
    self.draftSpeedKmh = round(kmh * 10) / 10;
    self.draftRecordedPace = NO;
    LSHapticSelection();
    [self optionsChanged:[NSString stringWithFormat:@"Speed set to %@ km/h to finish in %@.", LSFormatDecimal(self.draftSpeedKmh, 1), LSDuration(seconds)]];
    LSAnnounce(self.routeFeedback.text);
}

#pragma mark - Share and export

- (NSString *)linkMode {
    if (LSModeForSpeed(self.draftSpeedKmh) == LSTransportModeCycling) return @"cycling";
    MKDirectionsTransportType type = self.fetchedRoute ? self.fetchedRoute.transportType
        : (self.profileSegment.selectedSegmentIndex == 1 ? MKDirectionsTransportTypeAutomobile : MKDirectionsTransportTypeWalking);
    return type == MKDirectionsTransportTypeWalking ? @"walking" : @"driving";
}

- (NSArray<LSMapLinkPlace *> *)linkPlaces {
    NSArray<LSRouteWaypoint *> *waypoints = self.fetchedRoute.waypoints.count >= 2 ? self.fetchedRoute.waypoints : [self draftWaypoints];
    NSMutableArray *places = [NSMutableArray array];
    for (LSRouteWaypoint *waypoint in waypoints) {
        NSString *name = [@[@"Map point", @"Track start", @"Track end", @"Start", @"End"] containsObject:waypoint.name] ? nil : waypoint.name;
        [places addObject:[LSMapLinkPlace placeWithLatitude:waypoint.coordinate.latitude longitude:waypoint.coordinate.longitude name:name]];
    }
    return places;
}

- (UIMenu *)shareMenu {
    __weak typeof(self) weakSelf = self;
    NSArray<LSMapLinkPlace *> *places = [self linkPlaces];
    // @available needs a compiler-rt helper the Linux toolchain doesn't ship.
    BOOL modernApple = [NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){18, 4, 0}];
    BOOL legacyApple = !modernApple && places.count <= 2;
    NSMutableArray *links = [NSMutableArray array];
    NSArray *apps = @[@(LSMapAppApple), @(LSMapAppGoogle), @(LSMapAppWaze)];
    NSArray *titles = @[@"Apple Maps link", @"Google Maps link", @"Waze link"];
    NSArray *symbols = @[@"map", @"globe", @"car"];
    for (NSUInteger index = 0; index < apps.count; index++) {
        LSMapApp app = (LSMapApp)[apps[index] integerValue];
        NSUInteger limit = [LSMapLinks maximumPlacesForApp:app legacyApple:legacyApple];
        UIAction *action = [UIAction actionWithTitle:titles[index] image:[UIImage systemImageNamed:symbols[index]] identifier:nil handler:^(__unused UIAction *item) {
            typeof(self) self = weakSelf;
            NSURL *url = [LSMapLinks URLForApp:app places:[self linkPlaces] mode:[self linkMode] legacyApple:legacyApple];
            if (url) [self presentShareItems:@[url] from:self.shareButton];
        }];
        if (app == LSMapAppWaze) action.subtitle = @"Destination only; Waze starts where you are";
        else if (places.count > limit) action.subtitle = [NSString stringWithFormat:@"Keeps the first %lu stops", (unsigned long)(limit - 2)];
        [links addObject:action];
    }
    UIMenu *linkMenu = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:links];
    NSMutableArray *files = [NSMutableArray array];
    for (NSString *format in @[@"GPX", @"TCX", @"FIT"]) {
        UIAction *action = [UIAction actionWithTitle:[NSString stringWithFormat:@"Export %@ file", format] image:[UIImage systemImageNamed:@"doc.badge.arrow.up"] identifier:nil handler:^(__unused UIAction *item) {
            [weakSelf exportRouteAs:format];
        }];
        [files addObject:action];
    }
    ((UIAction *)files[0]).subtitle = @"Works with most map and fitness apps";
    ((UIAction *)files[2]).subtitle = @"Garmin and Strava activity, timed at the playback speed";
    UIMenu *fileMenu = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:files];
    if (!self.fetchedRoute) for (UIAction *action in files) action.attributes = UIMenuElementAttributesDisabled;
    return [UIMenu menuWithTitle:@"Share route" children:@[linkMenu, fileMenu]];
}

- (void)exportRouteAs:(NSString *)format {
    LSRoute *route = self.fetchedRoute;
    if (!route) return;
    LSPlaybackOptions *options = [self draftOptions];
    double duration = [LSRouteSimulator estimatedDurationForRoute:route options:options];
    NSTimeInterval interval = isfinite(duration) && duration > 20000 ? duration / 20000 : 1.0;
    NSDate *start = options.recordedPace && route.recordedStartDate ? route.recordedStartDate : NSDate.date;
    double begin = floor(start.timeIntervalSince1970);
    double altitude = PersistenceManager.shared.altitude;
    NSMutableData *points = [NSMutableData data];
    [LSRouteSimulator enumerateSamplesForRoute:route options:options interval:interval block:^(NSTimeInterval time, CLLocationCoordinate2D coordinate, double speed, double distance, __unused CLLocationDirection heading) {
        LSTrackPoint point = { begin + time, coordinate.latitude, coordinate.longitude, altitude, distance, speed };
        [points appendBytes:&point length:sizeof point];
    }];
    NSUInteger count = points.length / sizeof(LSTrackPoint);
    NSString *activity = options.recordedPace ? LSActivityForKmh(route.distance / MAX(1, duration) * 3.6) : LSActivityForKmh(options.speedKmh);
    NSData *data = nil;
    if ([format isEqualToString:@"GPX"]) data = [LSTrackIO GPXDataForPoints:points.bytes count:count name:route.name activity:activity];
    else if ([format isEqualToString:@"TCX"]) data = [LSTrackIO TCXDataForPoints:points.bytes count:count name:route.name activity:activity];
    else data = [LSTrackIO FITDataForPoints:points.bytes count:count activity:activity];
    NSURL *folder = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"LSpoof Export"] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:NULL];
    NSURL *file = [folder URLByAppendingPathComponent:[LSTrackIO safeFileName:route.name extension:format.lowercaseString]];
    if (count < 2 || !data || ![data writeToURL:file atomically:YES]) {
        [self showMessage:@"The route could not be exported." symbol:@"exclamationmark.triangle.fill"];
        LSHapticWarning();
        return;
    }
    [self presentShareItems:@[file] from:self.shareButton];
}

#pragma mark - Import

- (UIMenu *)importMenu {
    __weak typeof(self) weakSelf = self;
    UIAction *paste = [UIAction actionWithTitle:@"Paste map link" image:[UIImage systemImageNamed:@"doc.on.clipboard"] identifier:nil handler:^(__unused UIAction *action) {
        typeof(self) self = weakSelf;
        NSString *text = UIPasteboard.generalPasteboard.hasStrings ? UIPasteboard.generalPasteboard.string : nil;
        if (text.length && [LSMapLinks firstMapLinkInText:text]) [self importMapLinkText:text];
        else [self enterMapLink];
    }];
    paste.subtitle = @"Apple Maps, Google Maps or Waze, including short links";
    UIAction *type = [UIAction actionWithTitle:@"Type or paste a link…" image:[UIImage systemImageNamed:@"link"] identifier:nil handler:^(__unused UIAction *action) {
        [weakSelf enterMapLink];
    }];
    UIAction *file = [UIAction actionWithTitle:@"Open GPX, TCX or FIT file…" image:[UIImage systemImageNamed:@"folder"] identifier:nil handler:^(__unused UIAction *action) {
        [weakSelf openTrackFile];
    }];
    file.subtitle = @"Replay a recorded trip, at its own pace if it has times";
    return [UIMenu menuWithTitle:@"Import a route" children:@[paste, type, file]];
}

- (void)enterMapLink {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Map link" message:@"Paste a link shared from Apple Maps, Google Maps or Waze." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeURL;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.placeholder = @"https://maps.app.goo.gl/…";
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    __weak UIAlertController *weakAlert = alert;
    __weak typeof(self) weakSelf = self;
    UIAlertAction *open = [UIAlertAction actionWithTitle:@"Import" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [weakSelf importMapLinkText:weakAlert.textFields.firstObject.text ?: @""];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:open];
    alert.preferredAction = open;
    [self presentViewController:alert animated:LSMapAnimationsEnabled() completion:nil];
}

- (void)setImportStatus:(NSString *)text error:(BOOL)error busy:(BOOL)busy {
    if (busy) [self.routeSpinner startAnimating]; else [self.routeSpinner stopAnimating];
    self.routeFeedback.textColor = error ? LSErrorColor() : UIColor.secondaryLabelColor;
    self.routeFeedback.text = text;
    if (self.tab != LSPickerTabRoute || error) [self showMessage:text symbol:error ? @"exclamationmark.triangle.fill" : @"link"];
    if (!busy) LSAnnounce(text);
}

- (void)importMapLinkText:(NSString *)text {
    NSURL *url = [LSMapLinks firstMapLinkInText:text];
    if (!url) {
        [self setImportStatus:@"No Apple Maps, Google Maps or Waze link found." error:YES busy:NO];
        LSHapticWarning();
        return;
    }
    NSUInteger revision = ++self.selectionRevision;
    if (![LSMapLinks needsResolving:url]) { [self importMapLink:[LSMapLinks parseURL:url] revision:revision]; return; }
    [self setImportStatus:@"Opening the link…" error:NO busy:YES];
    __weak typeof(self) weakSelf = self;
    [LSMapLinks resolveURL:url completion:^(NSURL *resolved, NSString *html) {
        typeof(self) self = weakSelf;
        if (!self || self.closed || revision != self.selectionRevision) return;
        LSMapLink *link = resolved ? [LSMapLinks parseURL:resolved] : nil;
        if (!link && html) {
            // Apple place links with only a place id name their coordinate in the page.
            LSMapLinkPlace *place = [LSMapLinks placeFromHTML:html];
            if (place) {
                [self.routeSpinner stopAnimating];
                [self useLinkPlace:[LSRouteWaypoint waypointWithName:place.name coordinate:CLLocationCoordinate2DMake(place.latitude, place.longitude)]];
                return;
            }
        }
        if (!link) {
            [self setImportStatus:resolved ? @"That link doesn't name a place LSpoof can read." : @"The link could not be opened. Check your connection and try again." error:YES busy:NO];
            LSHapticWarning();
            return;
        }
        [self importMapLink:link revision:revision];
    }];
}

- (void)importMapLink:(LSMapLink *)link revision:(NSUInteger)revision {
    if (!link.places.count) {
        [self setImportStatus:@"That link doesn't name a place LSpoof can read." error:YES busy:NO];
        LSHapticWarning();
        return;
    }
    [self setImportStatus:@"Finding the places in the link…" error:NO busy:YES];
    __weak typeof(self) weakSelf = self;
    [self locateLinkPlaces:link.places index:0 found:[NSMutableArray array] revision:revision completion:^(NSArray<LSRouteWaypoint *> *waypoints, NSString *failure) {
        typeof(self) self = weakSelf;
        if (!self || self.closed || revision != self.selectionRevision) return;
        if (failure) { [self setImportStatus:failure error:YES busy:NO]; LSHapticWarning(); return; }
        [self.routeSpinner stopAnimating];
        if (!link.isDirections) [self useLinkPlace:waypoints.firstObject];
        else [self useLinkWaypoints:waypoints link:link];
    }];
}

// A link to one place: an endpoint on the Route tab, otherwise a location to preview.
- (void)useLinkPlace:(LSRouteWaypoint *)place {
    if (!place) return;
    if (self.tab == LSPickerTabRoute) {
        [self assignEndpoint:self.endpoint coordinate:place.coordinate name:place.name];
        [self setImportStatus:[NSString stringWithFormat:@"Imported “%@”.", place.name] error:NO busy:NO];
    } else {
        self.tab = LSPickerTabLocation;
        [self updateWorkspace];
        [self setSelection:place.coordinate name:place.name];
        [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(place.coordinate, 2000, 2000) animated:LSMapAnimationsEnabled()];
        [self showMessage:[NSString stringWithFormat:@"Imported “%@”. Apply it when you’re ready.", place.name] symbol:@"link"];
    }
    LSHapticSuccess();
}

// Looks up text places one at a time, near where the link's map was looking.
- (void)locateLinkPlaces:(NSArray<LSMapLinkPlace *> *)places index:(NSUInteger)index found:(NSMutableArray<LSRouteWaypoint *> *)found
                revision:(NSUInteger)revision completion:(void (^)(NSArray<LSRouteWaypoint *> *, NSString *))completion {
    if (index >= places.count) { completion(found, nil); return; }
    LSMapLinkPlace *place = places[index];
    if (place.hasCoordinate) {
        [found addObject:[LSRouteWaypoint waypointWithName:place.name coordinate:CLLocationCoordinate2DMake(place.latitude, place.longitude)]];
        [self locateLinkPlaces:places index:index + 1 found:found revision:revision completion:completion];
        return;
    }
    MKLocalSearchRequest *request = [[MKLocalSearchRequest alloc] init];
    request.naturalLanguageQuery = place.query;
    if (place.hasHint) request.region = MKCoordinateRegionMakeWithDistance(CLLocationCoordinate2DMake(place.hintLatitude, place.hintLongitude), 30000, 30000);
    else if (found.count) request.region = MKCoordinateRegionMakeWithDistance(found.lastObject.coordinate, 200000, 200000);
    else request.region = self.mapView.region;
    self.linkSearch = [[MKLocalSearch alloc] initWithRequest:request];
    __weak typeof(self) weakSelf = self;
    [self.linkSearch startWithCompletionHandler:^(MKLocalSearchResponse *response, NSError *error) {
        typeof(self) self = weakSelf;
        if (!self || self.closed || revision != self.selectionRevision) return;
        self.linkSearch = nil;
        MKMapItem *item = response.mapItems.firstObject;
        CLLocationCoordinate2D coordinate = item.placemark.coordinate;
        if (!item || !CLLocationCoordinate2DIsValid(coordinate)) {
            if (place.hasHint) {
                // The map view the link was made from is the best remaining guess.
                coordinate = CLLocationCoordinate2DMake(place.hintLatitude, place.hintLongitude);
            } else {
                completion(nil, error && error.code != MKErrorPlacemarkNotFound
                    ? @"Place lookup is unavailable right now. Check your connection and try again."
                    : [NSString stringWithFormat:@"Couldn't find “%@” from the link.", place.query]);
                return;
            }
        }
        [found addObject:[LSRouteWaypoint waypointWithName:item.name ?: place.name coordinate:coordinate]];
        [self locateLinkPlaces:places index:index + 1 found:found revision:revision completion:completion];
    }];
}

- (void)useLinkWaypoints:(NSArray<LSRouteWaypoint *> *)waypoints link:(LSMapLink *)link {
    NSMutableArray<LSRouteWaypoint *> *points = [waypoints mutableCopy];
    BOOL needsFrom = NO;
    if (link.startsAtCurrentLocation) {
        // "From your location": the applied location if there is one, else the real one.
        CLLocation *applied = LSSessionController.shared.snapshot.location;
        if (applied) [points insertObject:[LSRouteWaypoint waypointWithName:@"Applied location" coordinate:applied.coordinate] atIndex:0];
        else if (self.realPin) [points insertObject:[LSRouteWaypoint waypointWithName:@"My real location" coordinate:self.realPin.coordinate] atIndex:0];
        else needsFrom = YES;
    }
    NSUInteger dropped = 0;
    while (points.count > kLSMaximumStops + (needsFrom ? 1 : 2)) { [points removeObjectAtIndex:points.count - 2]; dropped++; }
    self.tab = LSPickerTabRoute;
    [self updateWorkspace];
    [self clearRouteDraft];
    NSString *mode = link.mode;
    self.profileSegment.selectedSegmentIndex = [mode isEqualToString:@"driving"] || [mode isEqualToString:@"transit"] ? 1 : 0;
    self.draftSpeedKmh = [mode isEqualToString:@"walking"] ? 5 : ([mode isEqualToString:@"cycling"] ? 15 : ([mode isEqualToString:@"driving"] || [mode isEqualToString:@"transit"] ? 50 : self.draftSpeedKmh));
    NSUInteger first = needsFrom ? 0 : 1;
    if (!needsFrom) [self assignEndpoint:LSEndpointFrom coordinate:points.firstObject.coordinate name:points.firstObject.name build:NO];
    for (NSUInteger index = first; index + 1 < points.count; index++) {
        LSStopAnnotation *stop = [[LSStopAnnotation alloc] init];
        stop.coordinate = points[index].coordinate;
        stop.subtitle = points[index].name;
        [self.routeStops addObject:stop];
        [self.mapView addAnnotation:stop];
    }
    [self renumberStops];
    [self rebuildStopRows];
    [self assignEndpoint:LSEndpointTo coordinate:points.lastObject.coordinate name:points.lastObject.name build:!needsFrom];
    if (needsFrom) {
        self.endpoint = LSEndpointFrom;
        self.endpointSegment.selectedSegmentIndex = LSEndpointFrom;
        [self setImportStatus:@"The link starts at your location. Choose From, or tap the map to set it." error:NO busy:NO];
        CLLocationCoordinate2D to = points.lastObject.coordinate;
        [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(to, 4000, 4000) animated:LSMapAnimationsEnabled()];
    } else if (dropped) {
        [self showMessage:[NSString stringWithFormat:@"Imported. %lu extra stops were left out (10 is the most).", (unsigned long)dropped] symbol:@"link"];
    } else {
        [self showMessage:@"Route imported from the link." symbol:@"link"];
    }
    LSHapticSuccess();
}

- (void)openTrackFile {
    NSMutableArray<UTType *> *types = [NSMutableArray array];
    for (NSString *extension in @[@"gpx", @"tcx", @"fit"]) {
        UTType *type = [UTType typeWithFilenameExtension:extension];
        if (type) [types addObject:type];
    }
    [types addObjectsFromArray:@[UTTypeXML, UTTypeData]];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:LSMapAnimationsEnabled() completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    if (urls.firstObject) [self importTrackAtURL:urls.firstObject];
}

- (void)importTrackAtURL:(NSURL *)url {
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSNumber *size = nil;
    [url getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
    NSData *data = size.unsignedLongLongValue <= 64 * 1024 * 1024 ? [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:NULL] : nil;
    if (scoped) [url stopAccessingSecurityScopedResource];
    NSString *error = nil;
    LSTrack *track = data ? [LSTrackIO trackFromData:data fileName:url.lastPathComponent error:&error] : nil;
    if (!track) {
        [self setImportStatus:error ?: @"The file could not be read." error:YES busy:NO];
        LSHapticWarning();
        return;
    }
    NSUInteger count = track.count;
    const LSTrackPoint *points = track.points;
    NSMutableData *coordinates = [NSMutableData dataWithLength:count * sizeof(CLLocationCoordinate2D)];
    NSMutableData *times = track.hasTimes ? [NSMutableData dataWithLength:count * sizeof(double)] : nil;
    CLLocationCoordinate2D *coordinateBytes = coordinates.mutableBytes;
    double *timeBytes = times.mutableBytes;
    for (NSUInteger index = 0; index < count; index++) {
        coordinateBytes[index] = CLLocationCoordinate2DMake(points[index].latitude, points[index].longitude);
        if (timeBytes) timeBytes[index] = points[index].time - points[0].time;
    }
    MKDirectionsTransportType transport = [track.activity isEqualToString:@"driving"] ? MKDirectionsTransportTypeAutomobile : MKDirectionsTransportTypeWalking;
    NSDate *start = track.hasTimes ? [NSDate dateWithTimeIntervalSince1970:points[0].time] : nil;
    LSRoute *route = [LSRoute routeWithCoordinates:coordinateBytes times:timeBytes count:count name:track.name transportType:transport startDate:start];
    if (!route || route.distance < 5) {
        [self setImportStatus:@"The track is too short to play back." error:YES busy:NO];
        LSHapticWarning();
        return;
    }
    self.tab = LSPickerTabRoute;
    [self updateWorkspace];
    [self clearRouteDraft];
    self.startPin = [[LSStartAnnotation alloc] init];
    self.startPin.coordinate = route.coordinates[0];
    self.startPin.title = @"From";
    self.startPin.subtitle = @"Track start";
    self.endPin = [[LSDestinationAnnotation alloc] init];
    self.endPin.coordinate = route.coordinates[route.pointCount - 1];
    self.endPin.title = @"To";
    self.endPin.subtitle = @"Track end";
    [self.mapView addAnnotations:@[self.startPin, self.endPin]];
    self.profileSegment.selectedSegmentIndex = transport == MKDirectionsTransportTypeAutomobile ? 1 : 0;
    [self showDraftRoute:route];
    self.draftRecordedPace = route.hasTiming;
    self.draftPaceMultiplier = 1;
    if (!route.hasTiming) {
        self.draftSpeedKmh = [track.activity isEqualToString:@"driving"] ? 50 : ([track.activity isEqualToString:@"cycling"] ? 15 : self.draftSpeedKmh);
    }
    [self setImportStatus:route.hasTiming
        ? [NSString stringWithFormat:@"Imported “%@” (%@). It plays at its recorded pace; pick a speed to change that.", route.name, track.format]
        : [NSString stringWithFormat:@"Imported “%@” (%@). The file has no times, so it plays at the speed you pick.", route.name, track.format]
                   error:NO busy:NO];
    [self updateRouteUI];
    LSHapticSuccess();
}

#pragma mark - Panel state

- (void)updateRouteUI {
    for (UIButton *button in @[self.fromButton, self.toButton]) {
        MKPointAnnotation *pin = button == self.fromButton ? self.startPin : self.endPin;
        NSString *name = button == self.fromButton ? @"From" : @"To";
        UIButtonConfiguration *config = button.configuration;
        config.subtitle = pin ? (pin.subtitle.length ? pin.subtitle : LSCoordinateText(pin.coordinate)) : @"Search, pick a saved place, or tap the map";
        button.configuration = config;
        button.accessibilityLabel = [NSString stringWithFormat:@"%@: %@", name, config.subtitle];
        button.accessibilityHint = @"Choose a place or enter coordinates for this endpoint.";
    }
    LSRoute *route = self.fetchedRoute;
    BOOL fromTrack = route.fromTrack;
    self.swapButton.enabled = self.startPin && self.endPin && !fromTrack;
    self.swapButton.alpha = self.swapButton.enabled ? 1 : 0.4;
    self.buildRouteButton.enabled = self.startPin && self.endPin && !self.directions;
    self.buildRouteButton.hidden = route != nil;
    self.profileSegment.enabled = !fromTrack;
    self.recordedChip.hidden = !route.hasTiming;
    if (!route.hasTiming) self.draftRecordedPace = NO;
    LSTransportMode mode = LSModeForSpeed(self.draftSpeedKmh);
    for (UIButton *chip in self.speedChips) {
        BOOL selected = chip == self.recordedChip ? self.draftRecordedPace : (!self.draftRecordedPace && chip.tag == (NSInteger)mode);
        LSSetChipSelected(chip, selected);
    }
    UIButtonConfiguration *custom = self.speedButton.configuration;
    custom.title = mode == LSTransportModeCustom ? [NSString stringWithFormat:@"%@ km/h", LSFormatDecimal(self.draftSpeedKmh, 1)] : @"Custom";
    self.speedButton.configuration = custom;
    self.speedButton.accessibilityLabel = mode == LSTransportModeCustom ? [NSString stringWithFormat:@"Custom speed, %@ kilometers per hour", LSFormatDecimal(self.draftSpeedKmh, 1)] : @"Custom speed";
    for (NSUInteger index = 0; index < 3 && index < self.speedChips.count; index++) {
        self.speedChips[index].accessibilityLabel = [NSString stringWithFormat:@"%@, %@ kilometers per hour", @[@"Walk", @"Bike", @"Drive"][index], LSFormatDecimal(kLSPresetSpeeds[index], 0)];
    }
    UIButtonConfiguration *recorded = self.recordedChip.configuration;
    recorded.title = self.draftRecordedPace && fabs(self.draftPaceMultiplier - 1) > 0.01 ? [NSString stringWithFormat:@"×%@", LSFormatDecimal(self.draftPaceMultiplier, 2)] : @"Recorded";
    self.recordedChip.configuration = recorded;

    PersistenceManager *store = PersistenceManager.shared;
    NSArray *profiles = @[@"Gentle", @"Normal", @"Sporty"];
    LSSetChipTitle(self.motionButton, store.smoothMotion ? [NSString stringWithFormat:@"Smooth · %@", profiles[MAX(0, MIN(2, store.accelerationProfile))]] : @"Steady speed");
    self.motionButton.menu = [self motionMenu];
    NSUInteger stops = route ? route.plannedStopCount : self.routeStops.count;
    self.waitButton.hidden = stops == 0 || self.draftRecordedPace;
    LSSetChipTitle(self.waitButton, store.stopDwell > 0 ? [NSString stringWithFormat:@"Wait %@ at stops", LSWaitText(store.stopDwell)] : @"No wait at stops");
    self.waitButton.menu = [self waitMenu];
    self.finishButton.hidden = route == nil;
    self.finishButton.menu = [self finishMenu];
    self.shareButton.hidden = !self.startPin || !self.endPin;
    self.shareButton.menu = [self shareMenu];
    self.importButton.menu = [self importMenu];

    self.routeSummary.hidden = !route;
    if (route) {
        LSPlaybackOptions *options = [self draftOptions];
        NSTimeInterval duration = [LSRouteSimulator estimatedDurationForRoute:route options:options];
        NSString *pace = options.recordedPace
            ? (fabs(options.paceMultiplier - 1) > 0.01 ? [NSString stringWithFormat:@"at ×%@ recorded pace", LSFormatDecimal(options.paceMultiplier, 2)] : @"at the recorded pace")
            : [NSString stringWithFormat:@"at %@ km/h", LSFormatDecimal(self.draftSpeedKmh, 1)];
        NSMutableString *summary = [NSMutableString stringWithFormat:@"%@ · about %@ %@", LSDistance(route.distance), LSDuration(duration), pace];
        if (route.plannedStopCount) [summary appendFormat:@" · %lu %@", (unsigned long)route.plannedStopCount, route.plannedStopCount == 1 ? @"stop" : @"stops"];
        self.routeSummary.text = summary;
    } else {
        self.routeSummary.text = @"";
    }
    [self updatePlayback];
    [self updateFooter];
}

- (void)startDraftRoute {
    LSRoute *route = self.fetchedRoute;
    if (!route || self.directions) return;
    LSPlaybackOptions *options = [self draftOptions];
    __weak typeof(self) weakSelf = self;
    dispatch_block_t start = ^{
        typeof(self) self = weakSelf;
        if (!self || self.closed) return;
        if ([LSSessionController.shared startRoute:route options:options]) {
            self.routeDraftChanged = NO;
            self.routeFeedback.text = PersistenceManager.shared.continueInBackground
                ? @"Route started. It keeps moving in the background while iOS lets the app run."
                : @"Route started. Close the picker to return to your app. Leaving the app pauses movement until you come back.";
            self.routeFeedback.textColor = UIColor.secondaryLabelColor;
            LSHapticSuccess();
            [self showMessage:@"Route started." symbol:@"location.north.line.fill"];
            [self refreshSession];
        } else {
            self.routeFeedback.text = @"This route could not be started. Rebuild it and try again.";
            self.routeFeedback.textColor = LSErrorColor();
            LSHapticWarning();
        }
        LSAnnounce(self.routeFeedback.text);
    };
    if (LSSessionController.shared.snapshot.mode == LSSessionModeOff ||
        (LSSessionController.shared.snapshot.mode == LSSessionModeStatic && route == LSSessionController.shared.retainedRoute && !self.routeDraftChanged)) start();
    else [self confirmAction:@"Replace applied session?" message:@"The app will start at From and follow this route. The currently applied location or route will be replaced." button:@"Replace and start" action:start];
}

- (void)speedChipTapped:(UIButton *)chip {
    if (chip == self.recordedChip) {
        LSHapticSelection();
        self.draftRecordedPace = YES;
        [self optionsChanged:@"Playing at the recorded pace."];
        return;
    }
    if (chip.tag >= 0 && chip.tag < 3) { LSHapticSelection(); [self setPlaybackSpeed:kLSPresetSpeeds[chip.tag]]; }
    else [self enterCustomSpeed];
}

- (void)chooseSpeed {
    [self enterCustomSpeed];
}

- (void)setPlaybackSpeed:(double)speed {
    if (!isfinite(speed) || speed < 1 || speed > 500) return;
    self.draftSpeedKmh = speed;
    self.draftRecordedPace = NO;
    [self optionsChanged:@"Playback speed updated. The route path is unchanged."];
}

- (void)enterCustomSpeed {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Custom playback speed" message:@"Enter a speed from 1 to 500 km/h. The path stays the same." preferredStyle:UIAlertControllerStyleAlert];
    double current = self.draftSpeedKmh;
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeDecimalPad;
        field.text = LSFormatDecimal(current, 1);
        field.placeholder = @"km/h";
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.accessibilityLabel = @"Speed in kilometers per hour";
    }];
    __weak UIAlertController *weakAlert = alert;
    __weak typeof(self) weakSelf = self;
    UIAlertAction *save = [UIAlertAction actionWithTitle:@"Set speed" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSNumber *number = LSParseDecimal(weakAlert.textFields.firstObject.text, NSLocale.currentLocale);
        if (number) [weakSelf setPlaybackSpeed:number.doubleValue];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:save];
    alert.preferredAction = save;
    __weak UIAlertAction *weakSave = save;
    [alert.textFields.firstObject addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
        NSNumber *number = LSParseDecimal(weakAlert.textFields.firstObject.text, NSLocale.currentLocale);
        weakSave.enabled = number && number.doubleValue >= 1 && number.doubleValue <= 500;
        weakAlert.message = weakSave.enabled ? @"Confirming changes playback speed. The path stays the same." : @"Enter a number from 1 to 500 km/h.";
    }] forControlEvents:UIControlEventEditingChanged];
    [self presentViewController:alert animated:LSMapAnimationsEnabled() completion:nil];
}

- (void)nudge:(NSInteger)direction {
    if (![LSSessionController.shared nudgeSpeed:direction]) {
        LSHapticWarning();
        return;
    }
    LSHapticSelection();
    if ([self isPlayingDraft]) {
        LSPlaybackOptions *options = LSRouteSimulator.shared.options;
        self.draftRecordedPace = options.recordedPace;
        self.draftPaceMultiplier = options.paceMultiplier;
        if (!options.recordedPace) self.draftSpeedKmh = options.speedKmh;
    }
    [self updateRouteUI];
    LSAnnounce(self.liveSpeedLabel.text);
}
- (void)slowerTapped { [self nudge:-1]; }
- (void)fasterTapped { [self nudge:1]; }

- (void)updatePlayback {
    LSRouteSimulator *engine = LSRouteSimulator.shared;
    BOOL active = engine.isSimulating;
    BOOL complete = LSSessionController.shared.retainedRoute && engine.totalDistance > 0 && engine.distanceCovered >= engine.totalDistance;
    self.progressPanel.hidden = !active && !complete;
    self.liveSpeedRow.hidden = !active;
    if (!active) {
        if (complete) {
            self.progressPercentLabel.text = @"100%";
            self.progressView.progress = 1;
            self.progressLabel.text = @"Arrived. Holding the destination until you replay or replace it.";
        }
        return;
    }
    double progress = engine.totalDistance > 0 ? MIN(1, engine.distanceCovered / engine.totalDistance) : 0;
    double remaining = MAX(0, engine.totalDistance - engine.distanceCovered);
    NSTimeInterval timeLeft = [engine remainingTimeEstimate];
    self.progressView.progress = (float)progress;
    self.progressView.accessibilityValue = [NSString stringWithFormat:@"%.0f percent", progress * 100];
    self.progressPercentLabel.text = [NSString stringWithFormat:@"%.0f%%", floor(progress * 100)];
    UIColor *tint = engine.isPaused ? LSWarningColor() : LSRouteColor();
    self.progressPercentLabel.textColor = tint;
    self.progressView.progressTintColor = tint;
    if (engine.isPaused) self.progressLabel.text = [NSString stringWithFormat:@"Paused · %@ to go", LSDistance(remaining)];
    else if (engine.isWaitingAtStop) self.progressLabel.text = [NSString stringWithFormat:@"Waiting at a stop · moving on in %@ · %@ to go", LSClock(engine.waitRemaining), LSDistance(remaining)];
    else self.progressLabel.text = [NSString stringWithFormat:@"%@ to go · about %@ left", LSDistance(remaining), LSDuration(timeLeft)];
    LSPlaybackOptions *options = engine.options;
    NSString *now = [NSString stringWithFormat:@"now %@ km/h", LSFormatDecimal(engine.currentSpeed * 3.6, 0)];
    self.liveSpeedLabel.text = options.recordedPace && engine.route.hasTiming
        ? [NSString stringWithFormat:@"Recorded ×%@ · %@", LSFormatDecimal(options.paceMultiplier, 2), now]
        : [NSString stringWithFormat:@"%@ km/h · %@", LSFormatDecimal(options.speedKmh, 0), now];
    self.liveSpeedLabel.accessibilityLabel = [NSString stringWithFormat:@"Playback speed %@", self.liveSpeedLabel.text];
}
@end
