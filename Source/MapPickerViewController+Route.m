#import "MapPickerViewController+Private.h"
#import "PersistenceManager.h"

static NSString *LSDistance(double meters) {
    MKDistanceFormatter *formatter = [[MKDistanceFormatter alloc] init];
    formatter.unitStyle = MKDistanceFormatterUnitStyleAbbreviated;
    return [formatter stringFromDistance:MAX(0, meters)];
}
static NSString *LSDuration(double seconds) {
    NSDateComponentsFormatter *formatter = [[NSDateComponentsFormatter alloc] init];
    formatter.allowedUnits = NSCalendarUnitHour | NSCalendarUnitMinute;
    formatter.unitsStyle = NSDateComponentsFormatterUnitsStyleAbbreviated;
    return seconds < 60 ? @"under 1 min" : ([formatter stringFromTimeInterval:seconds] ?: @"—");
}

@implementation MapPickerViewController (LSRouteUI)
- (void)buildRouteUI {
    self.endpoint = LSEndpointFrom;
    self.draftSpeedKmh = 5;
    self.fromButton = LSButton(@"From", @"1.circle", NO);
    self.toButton = LSButton(@"To", @"flag", NO);
    [self.fromButton addTarget:self action:@selector(chooseEndpoint:) forControlEvents:UIControlEventTouchUpInside];
    [self.toButton addTarget:self action:@selector(chooseEndpoint:) forControlEvents:UIControlEventTouchUpInside];
    self.swapButton = LSButton(@"Swap endpoints", @"arrow.up.arrow.down", NO);
    [self.swapButton addTarget:self action:@selector(swapEndpoints) forControlEvents:UIControlEventTouchUpInside];
    self.endpointSegment = [[UISegmentedControl alloc] initWithItems:@[@"From", @"To"]];
    self.endpointSegment.selectedSegmentIndex = 0;
    self.endpointSegment.accessibilityLabel = @"Endpoint edited by map taps";
    [self.endpointSegment.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [self.endpointSegment addTarget:self action:@selector(endpointChanged) forControlEvents:UIControlEventValueChanged];
    UILabel *mapTarget = LSLabel(@"Map taps edit", UIFontTextStyleSubheadline);
    UIStackView *endpointContent = LSStack(@[self.fromButton, self.toButton, self.swapButton, mapTarget, self.endpointSegment], 12);
    self.routeEndpointsPanel = LSInsetPanel(endpointContent);
    self.profileSegment = [[UISegmentedControl alloc] initWithItems:@[@"Walking path", @"Driving path"]];
    self.profileSegment.selectedSegmentIndex = 0;
    self.profileSegment.accessibilityLabel = @"Route geometry";
    [self.profileSegment.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [self.profileSegment addTarget:self action:@selector(profileChanged) forControlEvents:UIControlEventValueChanged];
    self.speedButton = LSButton(@"Speed: 5 km/h", @"speedometer", NO);
    [self.speedButton addTarget:self action:@selector(chooseSpeed) forControlEvents:UIControlEventTouchUpInside];
    self.buildRouteButton = LSButton(@"Build route", @"point.topleft.down.to.point.bottomright.curvepath", NO);
    [self.buildRouteButton addTarget:self action:@selector(fetchRoute) forControlEvents:UIControlEventTouchUpInside];
    self.routeSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.routeSpinner.hidesWhenStopped = YES;
    self.routeFeedback = LSLabel(@"Choose both endpoints to build a route.", UIFontTextStyleSubheadline);
    self.routeFeedback.textColor = UIColor.secondaryLabelColor;
    self.routeSummary = LSLabel(@"", UIFontTextStyleHeadline);
    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.progressTintColor = LSRouteColor();
    self.progressView.accessibilityLabel = @"Applied route progress";
    self.progressLabel = LSLabel(@"", UIFontTextStyleSubheadline);
    UILabel *explanation = LSLabel(@"Path type controls directions. Playback speed controls movement; cycling presets use the selected walking or driving path.", UIFontTextStyleFootnote);
    explanation.textColor = UIColor.secondaryLabelColor;
    UIStackView *content = LSStack(@[LSLabel(@"Route & speed", UIFontTextStyleHeadline), self.profileSegment,
        self.speedButton, explanation, self.buildRouteButton, self.routeSpinner, self.routeFeedback,
        self.routeSummary, self.progressView, self.progressLabel], 12);
    self.routeDetailsPanel = LSInsetPanel(content);
}
- (void)restoreRoute {
    LSSessionController *session = LSSessionController.shared;
    if (!session.retainedRoute) return;
    LSRouteSimulator *engine = LSRouteSimulator.shared;
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
    self.draftSpeedKmh = [LSRouteSimulator speedMetersPerSecondForMode:engine.transportMode customSpeedKmh:engine.customSpeedKmh] * 3.6;
    self.profileSegment.selectedSegmentIndex = session.retainedRoute.transportType == MKDirectionsTransportTypeAutomobile ? 1 : 0;
    self.tab = LSPickerTabRoute;
    self.tabs.selectedSegmentIndex = self.tab;
    [self.mapView addAnnotations:@[self.startPin, self.endPin]];
    [self.mapView addOverlay:self.routePolyline];
    [self.mapView setVisibleMapRect:self.routePolyline.boundingMapRect edgePadding:UIEdgeInsetsMake(44, 32, 44, 60) animated:NO];
    self.routeFeedback.text = engine.isSimulating ? @"The applied route continues when you close the picker." : @"Route retained. Start it again when you’re ready.";
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
        [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(coordinate, 2000, 2000) animated:LSMapAnimationsEnabled()];
    }];
    [self endpointChanged];
}
- (void)endpointChanged {
    self.endpoint = self.endpointSegment.selectedSegmentIndex;
    self.mapHintLabel.text = self.endpoint == LSEndpointFrom ? @"Tap the map to set From, or tap From to search." : @"Tap the map to set To, or tap To to search.";
}
- (void)assignEndpoint:(LSEndpoint)endpoint coordinate:(CLLocationCoordinate2D)coordinate name:(NSString *)name {
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
}
- (void)swapEndpoints {
    if (!self.startPin || !self.endPin) return;
    CLLocationCoordinate2D from = self.startPin.coordinate, to = self.endPin.coordinate;
    NSString *fromName = self.startPin.subtitle ?: @"Map point", *toName = self.endPin.subtitle ?: @"Map point";
    [self assignEndpoint:LSEndpointFrom coordinate:to name:toName];
    [self assignEndpoint:LSEndpointTo coordinate:from name:fromName];
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
        : @"Choose both endpoints, then build the route.";
}
- (void)profileChanged {
    BOOL shouldRefetch = self.fetchedRoute != nil || self.directions != nil;
    [self invalidateRouteDraft];
    [self updateRouteUI];
    if (shouldRefetch && self.startPin && self.endPin) [self fetchRoute];
}
- (void)fetchRoute {
    if (!self.startPin || !self.endPin || self.closed) return;
    [self cancelDirections];
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
            self.routeFeedback.text = @"No route found. Check the endpoints or path type, then try Build route again.";
            LSAnnounce(self.routeFeedback.text);
            [self updateRouteUI];
            return;
        }
        if (self.routePolyline) [self.mapView removeOverlay:self.routePolyline];
        self.fetchedRoute = route;
        self.routePolyline = route.polyline;
        [self.mapView addOverlay:self.routePolyline];
        [self.mapView setVisibleMapRect:self.routePolyline.boundingMapRect edgePadding:UIEdgeInsetsMake(44, 32, 44, 60) animated:LSMapAnimationsEnabled()];
        self.routeFeedback.text = @"Route preview ready. Start or replace the route when you’re ready.";
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
        config.title = name;
        config.subtitle = pin ? (pin.subtitle ?: LSCoordinateText(pin.coordinate)) : @"Search or enter coordinates";
        config.titleAlignment = UIButtonConfigurationTitleAlignmentLeading;
        button.configuration = config;
        button.accessibilityLabel = [NSString stringWithFormat:@"%@: %@", name, config.subtitle];
        button.accessibilityHint = @"Choose a place or enter coordinates for this endpoint.";
    }
    self.swapButton.enabled = self.startPin && self.endPin;
    self.buildRouteButton.enabled = self.startPin && self.endPin && !self.directions;
    UIButtonConfiguration *speed = self.speedButton.configuration;
    speed.title = [NSString stringWithFormat:@"Playback speed: %@ km/h", LSFormatDecimal(self.draftSpeedKmh, 1)];
    self.speedButton.configuration = speed;
    self.speedButton.accessibilityLabel = speed.title;
    self.routeSummary.hidden = !self.fetchedRoute;
    self.routeSummary.text = self.fetchedRoute ? [NSString stringWithFormat:@"Preview: %@ • %@ at %@ km/h", LSDistance(self.fetchedRoute.distance), LSDuration(self.fetchedRoute.distance / (self.draftSpeedKmh / 3.6)), LSFormatDecimal(self.draftSpeedKmh, 1)] : @"";
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
        if ([LSSessionController.shared startRoute:route transportMode:LSTransportModeCustom customSpeedKmh:speed]) {
            self.routeDraftChanged = NO;
            self.routeFeedback.text = @"Route started. Close the picker to return to your app. Backgrounding pauses movement.";
            self.routeFeedback.textColor = UIColor.secondaryLabelColor;
            [self refreshSession];
        } else {
            self.routeFeedback.text = @"This route could not be started. Rebuild it and try again.";
            self.routeFeedback.textColor = LSErrorColor();
        }
        LSAnnounce(self.routeFeedback.text);
    };
    if (LSSessionController.shared.snapshot.mode == LSSessionModeOff ||
        (LSSessionController.shared.snapshot.mode == LSSessionModeStatic && route == LSSessionController.shared.retainedRoute && !self.routeDraftChanged)) start();
    else [self confirmAction:@"Replace applied session?" message:@"The app will start at From and follow this route. The currently applied location or route will be replaced." button:@"Replace and start" action:start];
}
- (void)chooseSpeed {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Playback speed" message:@"Speed changes movement only. The walking or driving path stays the same." preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *names = @[@"Walking · 5 km/h", @"Cycling · 15 km/h", @"Driving · 50 km/h"];
    NSArray *speeds = @[@5, @15, @50];
    __weak typeof(self) weakSelf = self;
    for (NSUInteger i = 0; i < names.count; i++) {
        double speed = [speeds[i] doubleValue];
        [alert addAction:[UIAlertAction actionWithTitle:names[i] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [weakSelf setPlaybackSpeed:speed]; }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Custom speed…" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [weakSelf enterCustomSpeed]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    alert.popoverPresentationController.sourceView = self.speedButton;
    alert.popoverPresentationController.sourceRect = self.speedButton.bounds;
    [self presentViewController:alert animated:LSMapAnimationsEnabled() completion:nil];
}
- (void)setPlaybackSpeed:(double)speed {
    if (!isfinite(speed) || speed < 1 || speed > 500) return;
    self.draftSpeedKmh = speed;
    if (!self.routeDraftChanged && self.fetchedRoute == LSSessionController.shared.retainedRoute && LSRouteSimulator.shared.isSimulating) {
        [LSSessionController.shared updateTransportMode:LSTransportModeCustom customSpeedKmh:speed];
        self.routeFeedback.text = @"Playback speed updated. The route path is unchanged.";
    }
    [self updateRouteUI];
}
- (void)enterCustomSpeed {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Custom playback speed" message:@"Enter a speed from 1 to 500 km/h. Confirming updates the applied route if you are editing its speed." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeDecimalPad;
        field.text = LSFormatDecimal(self.draftSpeedKmh, 1);
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
    self.progressLabel.hidden = !active && !complete;
    self.progressView.hidden = !active;
    if (!active) {
        if (complete) self.progressLabel.text = @"Applied route complete. Holding the destination. Replay when you’re ready.";
        return;
    }
    double progress = engine.totalDistance > 0 ? MIN(1, engine.distanceCovered / engine.totalDistance) : 0;
    double remaining = MAX(0, engine.totalDistance - engine.distanceCovered);
    double speed = [LSRouteSimulator speedMetersPerSecondForMode:engine.transportMode customSpeedKmh:engine.customSpeedKmh];
    self.progressView.progress = (float)progress;
    self.progressView.accessibilityValue = [NSString stringWithFormat:@"%.0f percent", progress * 100];
    self.progressLabel.text = engine.isPaused
        ? [NSString stringWithFormat:@"Applied route paused · 0 km/h · %@ remaining", LSDistance(remaining)]
        : [NSString stringWithFormat:@"Applied route: %.0f%% complete · %@ remaining · %@", progress * 100, LSDistance(remaining), LSDuration(remaining / speed)];
}
@end
