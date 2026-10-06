#import "MapPickerViewController+Private.h"
#import "PersistenceManager.h"

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

// Preset speeds match the engine's walking, cycling and driving modes, so those routes
// report each mode's realistic accuracy instead of always using the custom profile.
static const double kLSPresetSpeeds[] = {5, 15, 50};
static LSTransportMode LSModeForSpeed(double kmh) {
    if (fabs(kmh - kLSPresetSpeeds[0]) < 0.01) return LSTransportModeWalking;
    if (fabs(kmh - kLSPresetSpeeds[1]) < 0.01) return LSTransportModeCycling;
    if (fabs(kmh - kLSPresetSpeeds[2]) < 0.01) return LSTransportModeDriving;
    return LSTransportModeCustom;
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

@implementation MapPickerViewController (LSRouteUI)
- (void)buildRouteUI {
    self.endpoint = LSEndpointFrom;
    self.draftSpeedKmh = 5;
    self.fromButton = LSEndpointButton(@"FROM", @"circle.circle.fill", LSSuccessColor());
    self.toButton = LSEndpointButton(@"TO", @"mappin.circle.fill", LSErrorColor());
    [self.fromButton addTarget:self action:@selector(chooseEndpoint:) forControlEvents:UIControlEventTouchUpInside];
    [self.toButton addTarget:self action:@selector(chooseEndpoint:) forControlEvents:UIControlEventTouchUpInside];
    self.swapButton = LSIconButton(@"arrow.up.arrow.down", @"Swap From and To");
    [self.swapButton addTarget:self action:@selector(swapEndpoints) forControlEvents:UIControlEventTouchUpInside];
    UIView *divider = LSSeparator();
    UIStackView *endpoints = LSStack(@[self.fromButton, divider, self.toButton], 2);
    UIStackView *endpointRow = LSRow(@[endpoints, self.swapButton], 10);
    self.endpointSegment = [[UISegmentedControl alloc] initWithItems:@[@"Set From", @"Set To"]];
    self.endpointSegment.selectedSegmentIndex = 0;
    self.endpointSegment.accessibilityLabel = @"Endpoint edited by map taps";
    [self.endpointSegment.heightAnchor constraintGreaterThanOrEqualToConstant:40].active = YES;
    [self.endpointSegment addTarget:self action:@selector(endpointChanged) forControlEvents:UIControlEventValueChanged];
    UILabel *mapTarget = LSLabel(@"Map taps", UIFontTextStyleFootnote);
    mapTarget.font = LSFont(UIFontTextStyleFootnote, UIFontWeightSemibold, 22);
    mapTarget.textColor = UIColor.secondaryLabelColor;
    [mapTarget setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *targetRow = LSRow(@[mapTarget, self.endpointSegment], 10);
    UIStackView *endpointContent = LSStack(@[endpointRow, targetRow], 12);
    self.routeEndpointsPanel = LSInsetPanel(endpointContent);

    self.profileSegment = [[UISegmentedControl alloc] initWithItems:@[@"Walking path", @"Driving path"]];
    self.profileSegment.selectedSegmentIndex = 0;
    self.profileSegment.accessibilityLabel = @"Route geometry";
    [self.profileSegment.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [self.profileSegment addTarget:self action:@selector(profileChanged) forControlEvents:UIControlEventValueChanged];
    NSArray *chipTitles = @[@"Walk", @"Bike", @"Drive", @"Custom"];
    NSArray *chipSymbols = @[@"figure.walk", @"bicycle", @"car.fill", @"slider.horizontal.3"];
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
    self.speedButton = chips.lastObject;
    self.speedRow = [[UIStackView alloc] initWithArrangedSubviews:chips];
    self.speedRow.distribution = UIStackViewDistributionFillEqually;
    self.speedRow.spacing = 8;
    UILabel *explanation = LSLabel(@"Path decides the streets you follow. Speed only changes how fast the location moves along them.", UIFontTextStyleFootnote);
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
    UIStackView *progressContent = LSStack(@[LSSectionLabel(@"Applied route"), progressTop, self.progressView], 10);
    self.progressPanel = progressContent;

    UIStackView *content = LSStack(@[LSSectionLabel(@"Path"), self.profileSegment,
        LSSectionLabel(@"Playback speed"), self.speedRow, explanation,
        self.buildRouteButton, feedbackRow, self.routeSummary, LSSeparator(), progressContent], 12);
    [content setCustomSpacing:6 afterView:content.arrangedSubviews[0]];
    [content setCustomSpacing:18 afterView:self.profileSegment];
    [content setCustomSpacing:6 afterView:content.arrangedSubviews[2]];
    [content setCustomSpacing:16 afterView:explanation];
    self.routeDetailsPanel = LSInsetPanel(content);
}
- (void)restoreRoute {
    LSSessionController *session = LSSessionController.shared;
    if (!session.retainedRoute) return;
    LSRouteSimulator *engine = LSRouteSimulator.shared;
    if (!CLLocationCoordinate2DIsValid(engine.startCoordinate) || !CLLocationCoordinate2DIsValid(engine.destinationCoordinate)) return;
    self.fetchedRoute = session.retainedRoute;
    self.routePolyline = session.retainedRoute.polyline;
    self.startPin = [[LSStartAnnotation alloc] init];
    self.startPin.coordinate = engine.startCoordinate;
    self.startPin.title = @"From";
    self.startPin.subtitle = @"Route start";
    self.endPin = [[LSDestinationAnnotation alloc] init];
    self.endPin.coordinate = engine.destinationCoordinate;
    self.endPin.title = @"To";
    self.endPin.subtitle = @"Route destination";
    switch (engine.transportMode) {
        case LSTransportModeWalking: self.draftSpeedKmh = kLSPresetSpeeds[0]; break;
        case LSTransportModeCycling: self.draftSpeedKmh = kLSPresetSpeeds[1]; break;
        case LSTransportModeDriving: self.draftSpeedKmh = kLSPresetSpeeds[2]; break;
        case LSTransportModeCustom: self.draftSpeedKmh = engine.customSpeedKmh; break;
    }
    self.profileSegment.selectedSegmentIndex = session.retainedRoute.transportType == MKDirectionsTransportTypeAutomobile ? 1 : 0;
    self.tab = LSPickerTabRoute;
    self.tabs.selectedSegmentIndex = self.tab;
    self.endpointSegment.selectedSegmentIndex = LSEndpointTo;
    self.endpoint = LSEndpointTo;
    [self.mapView addAnnotations:@[self.startPin, self.endPin]];
    [self.mapView addOverlay:self.routePolyline];
    [self.mapView setVisibleMapRect:self.routePolyline.boundingMapRect edgePadding:UIEdgeInsetsMake(48, 32, 48, 72) animated:NO];
    self.routeFeedback.text = engine.isSimulating ? @"The applied route keeps moving when you close the picker." : @"Route retained. Replay it when you’re ready.";
    [self updateRouteUI];
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
    self.mapHintLabel.text = self.endpoint == LSEndpointFrom ? @"Tap the map to set From, or tap From to search." : @"Tap the map to set To, or tap To to search.";
}
- (void)assignEndpoint:(LSEndpoint)endpoint coordinate:(CLLocationCoordinate2D)coordinate name:(NSString *)name {
    [self assignEndpoint:endpoint coordinate:coordinate name:name build:YES];
}
- (void)assignEndpoint:(LSEndpoint)endpoint coordinate:(CLLocationCoordinate2D)coordinate name:(NSString *)name build:(BOOL)build {
    if (!CLLocationCoordinate2DIsValid(coordinate)) return;
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
- (void)swapEndpoints {
    if (!self.startPin || !self.endPin) return;
    CLLocationCoordinate2D from = self.startPin.coordinate, to = self.endPin.coordinate;
    NSString *fromName = self.startPin.subtitle ?: @"Map point", *toName = self.endPin.subtitle ?: @"Map point";
    LSHapticSelection();
    [self assignEndpoint:LSEndpointFrom coordinate:to name:toName build:NO];
    [self assignEndpoint:LSEndpointTo coordinate:from name:fromName build:YES];
}
- (void)cancelDirections {
    if (self.directions) self.routeFeedback.text = @"Route lookup canceled. Tap Build route to try again.";
    self.routeRevision++;
    [self.directions cancel];
    self.directions = nil;
    [self.routeSpinner stopAnimating];
    self.buildRouteButton.enabled = self.startPin && self.endPin;
    [self updateFooter];
}
- (void)invalidateRouteDraft {
    [self cancelDirections];
    if (self.routePolyline) [self.mapView removeOverlay:self.routePolyline];
    self.routePolyline = nil;
    self.fetchedRoute = nil;
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
    CLLocation *from = [[CLLocation alloc] initWithLatitude:self.startPin.coordinate.latitude longitude:self.startPin.coordinate.longitude];
    CLLocation *to = [[CLLocation alloc] initWithLatitude:self.endPin.coordinate.latitude longitude:self.endPin.coordinate.longitude];
    if ([from distanceFromLocation:to] < 10) {
        // MapKit answers identical endpoints with a generic failure.
        self.routeFeedback.textColor = LSErrorColor();
        self.routeFeedback.text = @"From and To are the same place. Move one of them to build a route.";
        LSAnnounce(self.routeFeedback.text);
        [self updateRouteUI];
        return;
    }
    self.routeFeedback.textColor = UIColor.secondaryLabelColor;
    self.routeFeedback.text = @"Building route… You can keep using the current session.";
    MKDirectionsRequest *request = [[MKDirectionsRequest alloc] init];
    request.source = [[MKMapItem alloc] initWithPlacemark:[[MKPlacemark alloc] initWithCoordinate:self.startPin.coordinate]];
    request.destination = [[MKMapItem alloc] initWithPlacemark:[[MKPlacemark alloc] initWithCoordinate:self.endPin.coordinate]];
    request.transportType = self.profileSegment.selectedSegmentIndex == 1 ? MKDirectionsTransportTypeAutomobile : MKDirectionsTransportTypeWalking;
    request.requestsAlternateRoutes = NO;
    self.directions = [self directionsForRequest:request];
    NSUInteger revision = self.routeRevision;
    [self.routeSpinner startAnimating];
    [self updateRouteUI];
    __weak typeof(self) weakSelf = self;
    [self.directions calculateDirectionsWithCompletionHandler:^(MKDirectionsResponse *response, NSError *error) {
        typeof(self) self = weakSelf;
        if (!self || self.closed || revision != self.routeRevision || self.tab != LSPickerTabRoute) return;
        self.directions = nil;
        [self.routeSpinner stopAnimating];
        MKRoute *route = response.routes.firstObject;
        if (error || !route || route.polyline.pointCount < 2 || !isfinite(route.distance) || route.distance <= 0) {
            self.routeFeedback.textColor = LSErrorColor();
            self.routeFeedback.text = error.code == MKErrorDirectionsNotFound || !error
                ? @"No route between these points. Try the other path type or move an endpoint."
                : @"Directions are unavailable right now. Check your connection and tap Build route.";
            LSAnnounce(self.routeFeedback.text);
            LSHapticWarning();
            [self updateRouteUI];
            return;
        }
        if (self.routePolyline) [self.mapView removeOverlay:self.routePolyline];
        self.fetchedRoute = route;
        self.routePolyline = route.polyline;
        [self.mapView addOverlay:self.routePolyline];
        [self.mapView setVisibleMapRect:self.routePolyline.boundingMapRect edgePadding:UIEdgeInsetsMake(48, 32, 48, 72) animated:LSMapAnimationsEnabled()];
        self.routeFeedback.text = LSSessionController.shared.snapshot.mode == LSSessionModeOff
            ? @"Route ready. Tap Start route when you’re ready."
            : @"Route ready. Replace the applied session to follow it.";
        [self updateRouteUI];
        LSAnnounce(@"Route ready");
    }];
}
- (MKDirections *)directionsForRequest:(MKDirectionsRequest *)request {
    return [[MKDirections alloc] initWithRequest:request];
}
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
    self.swapButton.enabled = self.startPin && self.endPin;
    self.swapButton.alpha = self.swapButton.enabled ? 1 : 0.4;
    self.buildRouteButton.enabled = self.startPin && self.endPin && !self.directions;
    self.buildRouteButton.hidden = self.fetchedRoute != nil;
    LSTransportMode mode = LSModeForSpeed(self.draftSpeedKmh);
    for (UIButton *chip in self.speedChips) LSSetChipSelected(chip, chip.tag == (NSInteger)mode);
    UIButtonConfiguration *custom = self.speedButton.configuration;
    custom.title = mode == LSTransportModeCustom ? [NSString stringWithFormat:@"%@ km/h", LSFormatDecimal(self.draftSpeedKmh, 1)] : @"Custom";
    self.speedButton.configuration = custom;
    self.speedButton.accessibilityLabel = mode == LSTransportModeCustom ? [NSString stringWithFormat:@"Custom speed, %@ kilometers per hour", LSFormatDecimal(self.draftSpeedKmh, 1)] : @"Custom speed";
    for (NSUInteger index = 0; index < 3 && index < self.speedChips.count; index++) {
        self.speedChips[index].accessibilityLabel = [NSString stringWithFormat:@"%@, %@ kilometers per hour", @[@"Walk", @"Bike", @"Drive"][index], LSFormatDecimal(kLSPresetSpeeds[index], 0)];
    }
    self.routeSummary.hidden = !self.fetchedRoute;
    self.routeSummary.text = self.fetchedRoute ? [NSString stringWithFormat:@"%@ · %@ at %@ km/h", LSDistance(self.fetchedRoute.distance), LSDuration(self.fetchedRoute.distance / (self.draftSpeedKmh / 3.6)), LSFormatDecimal(self.draftSpeedKmh, 1)] : @"";
    [self updatePlayback];
    [self updateFooter];
}
- (void)startDraftRoute {
    MKRoute *route = self.fetchedRoute;
    if (!route || self.directions) return;
    double speed = self.draftSpeedKmh;
    __weak typeof(self) weakSelf = self;
    dispatch_block_t start = ^{
        typeof(self) self = weakSelf;
        if (!self || self.closed) return;
        if ([LSSessionController.shared startRoute:route transportMode:LSModeForSpeed(speed) customSpeedKmh:speed]) {
            self.routeDraftChanged = NO;
            self.routeFeedback.text = @"Route started. Close the picker to return to your app. Leaving the app pauses movement until you come back.";
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
    if (chip.tag >= 0 && chip.tag < 3) { LSHapticSelection(); [self setPlaybackSpeed:kLSPresetSpeeds[chip.tag]]; }
    else [self enterCustomSpeed];
}
- (void)chooseSpeed {
    [self enterCustomSpeed];
}
- (void)setPlaybackSpeed:(double)speed {
    if (!isfinite(speed) || speed < 1 || speed > 500) return;
    self.draftSpeedKmh = speed;
    if (!self.routeDraftChanged && self.fetchedRoute == LSSessionController.shared.retainedRoute && LSRouteSimulator.shared.isSimulating) {
        [LSSessionController.shared updateTransportMode:LSModeForSpeed(speed) customSpeedKmh:speed];
        self.routeFeedback.text = @"Playback speed updated. The route path is unchanged.";
    }
    [self updateRouteUI];
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
- (void)updatePlayback {
    LSRouteSimulator *engine = LSRouteSimulator.shared;
    BOOL active = engine.isSimulating;
    BOOL complete = LSSessionController.shared.retainedRoute && engine.totalDistance > 0 && engine.distanceCovered >= engine.totalDistance;
    self.progressPanel.hidden = !active && !complete;
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
    double speed = [LSRouteSimulator speedMetersPerSecondForMode:engine.transportMode customSpeedKmh:engine.customSpeedKmh];
    self.progressView.progress = (float)progress;
    self.progressView.accessibilityValue = [NSString stringWithFormat:@"%.0f percent", progress * 100];
    self.progressPercentLabel.text = [NSString stringWithFormat:@"%.0f%%", floor(progress * 100)];
    self.progressPercentLabel.textColor = engine.isPaused ? LSWarningColor() : LSRouteColor();
    self.progressView.progressTintColor = engine.isPaused ? LSWarningColor() : LSRouteColor();
    self.progressLabel.text = engine.isPaused
        ? [NSString stringWithFormat:@"Paused · %@ to go", LSDistance(remaining)]
        : [NSString stringWithFormat:@"%@ to go · about %@ left at %@ km/h", LSDistance(remaining), LSDuration(remaining / speed), LSFormatDecimal(speed * 3.6, 0)];
}
@end
