#import "MapPickerViewController+Private.h"
#import "PersistenceManager.h"
#import "RouteSimulator.h"

@implementation LSStartAnnotation
@end

@implementation LSDestinationAnnotation
@end

@implementation MapPickerViewController (LSRouteUI)

- (void)buildRouteControls {
    UIView *container = self.routeControlsContainer;

    self.getRouteButton = [self ls_primaryButtonWithTitle:@"Get Route" action:@selector(handleGetRouteTapped)];
    self.getRouteButton.hidden = YES;
    [container addSubview:self.getRouteButton];

    self.routeSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.routeSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.routeSpinner.hidesWhenStopped = YES;
    [container addSubview:self.routeSpinner];

    self.transportModeSegment = [[UISegmentedControl alloc] initWithItems:@[@"Walk", @"Cycle", @"Drive", @"Custom"]];
    self.transportModeSegment.translatesAutoresizingMaskIntoConstraints = NO;
    self.transportModeSegment.selectedSegmentIndex = 0;
    self.transportModeSegment.hidden = YES;
    [self.transportModeSegment addTarget:self action:@selector(handleTransportModeChanged:) forControlEvents:UIControlEventValueChanged];
    [container addSubview:self.transportModeSegment];

    self.customSpeedField = [[UITextField alloc] init];
    self.customSpeedField.translatesAutoresizingMaskIntoConstraints = NO;
    self.customSpeedField.placeholder = @"Custom km/h";
    self.customSpeedField.keyboardType = UIKeyboardTypeDecimalPad;
    self.customSpeedField.borderStyle = UITextBorderStyleRoundedRect;
    self.customSpeedField.text = @"30";
    self.customSpeedField.hidden = YES;
    [self.customSpeedField addTarget:self action:@selector(textFieldDidChange:) forControlEvents:UIControlEventEditingChanged];
    [container addSubview:self.customSpeedField];

    self.playRouteButton = [self ls_primaryButtonWithTitle:@"Play" action:@selector(handlePlayRouteTapped)];
    self.playRouteButton.hidden = YES;
    [container addSubview:self.playRouteButton];

    self.pauseRouteButton = [self ls_secondaryButtonWithTitle:@"Pause" action:@selector(handlePauseRouteTapped)];
    self.pauseRouteButton.hidden = YES;

    self.stopRouteButton = [self ls_secondaryButtonWithTitle:@"Stop" action:@selector(handleStopRouteTapped)];
    self.stopRouteButton.hidden = YES;

    self.routeActionRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.pauseRouteButton, self.stopRouteButton]];
    self.routeActionRow.translatesAutoresizingMaskIntoConstraints = NO;
    self.routeActionRow.axis = UILayoutConstraintAxisHorizontal;
    self.routeActionRow.spacing = 12.0;
    self.routeActionRow.distribution = UIStackViewDistributionFillEqually;
    self.routeActionRow.hidden = YES;
    [container addSubview:self.routeActionRow];

    [NSLayoutConstraint activateConstraints:@[
        [self.getRouteButton.heightAnchor constraintEqualToConstant:44.0],
        [self.playRouteButton.heightAnchor constraintEqualToConstant:44.0],
        [self.pauseRouteButton.heightAnchor constraintEqualToConstant:44.0],
        [self.stopRouteButton.heightAnchor constraintEqualToConstant:44.0],
        [self.customSpeedField.heightAnchor constraintEqualToConstant:40.0]
    ]];

    self.customSpeedHeightConstraint = [self.customSpeedField.heightAnchor constraintEqualToConstant:0.0];
    self.customSpeedHeightConstraint.active = YES;
}

- (void)ls_installRouteConstraintsInRoutePanel {
    UIView *content = self.routeControlsContainer;
    [NSLayoutConstraint activateConstraints:@[
        [self.getRouteButton.topAnchor constraintEqualToAnchor:content.topAnchor],
        [self.getRouteButton.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [self.getRouteButton.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],

        [self.routeSpinner.centerXAnchor constraintEqualToAnchor:self.getRouteButton.centerXAnchor],
        [self.routeSpinner.centerYAnchor constraintEqualToAnchor:self.getRouteButton.centerYAnchor],

        [self.transportModeSegment.topAnchor constraintEqualToAnchor:self.getRouteButton.bottomAnchor constant:10.0],
        [self.transportModeSegment.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [self.transportModeSegment.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],

        [self.customSpeedField.topAnchor constraintEqualToAnchor:self.transportModeSegment.bottomAnchor constant:8.0],
        [self.customSpeedField.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [self.customSpeedField.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],

        [self.playRouteButton.topAnchor constraintEqualToAnchor:self.customSpeedField.bottomAnchor constant:10.0],
        [self.playRouteButton.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [self.playRouteButton.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],

        [self.routeActionRow.topAnchor constraintEqualToAnchor:self.playRouteButton.bottomAnchor constant:8.0],
        [self.routeActionRow.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [self.routeActionRow.trailingAnchor constraintEqualToAnchor:content.trailingAnchor]
    ]];
}

- (void)updateCoordinateModeVisibility {
    BOOL routeMode = self.coordinateMode == LSMapPickerCoordinateModeRoute;
    BOOL staticMode = !routeMode;

    self.getRouteButton.hidden = !routeMode;
    BOOL hasRoute = self.fetchedRoute != nil;
    self.transportModeSegment.hidden = !routeMode || !hasRoute;
    self.playRouteButton.hidden = !routeMode || !hasRoute;
    self.routeActionRow.hidden = !routeMode || !hasRoute;

    if (routeMode) {
        if (self.pinAnnotation) {
            [self.mapView removeAnnotation:self.pinAnnotation];
        }
        if (!self.startAnnotation) {
            self.routePlacementPhase = LSRoutePlacementPhaseStart;
            self.mapHintLabel.text = @"  Tap map for route start  ";
        }
    } else {
        [self ls_clearRouteAnnotationsAndOverlay];
        if (self.pinAnnotation && self.mapConfigured) {
            [self.mapView addAnnotation:self.pinAnnotation];
        }
        self.mapHintLabel.text = @"  Tap map or drag pin  ";
    }

    [UIView animateWithDuration:0.2 animations:^{
        self.staticControlsContainer.alpha = staticMode ? 1.0 : 0.0;
        self.routeControlsContainer.alpha = routeMode ? 1.0 : 0.0;
    } completion:^(BOOL finished) {
        (void)finished;
        self.staticControlsContainer.hidden = !staticMode;
        self.routeControlsContainer.hidden = !routeMode;
    }];
    self.staticControlsContainer.hidden = NO;
    self.routeControlsContainer.hidden = NO;
    [self refreshStatusPill];

    [self ls_updateCustomSpeedVisibility];
    [self ls_updateRoutePlaybackButtons];
    [self ls_updateMapControlsBottomConstraint];
}

- (void)ls_updateMapControlsBottomConstraint {
    self.mapControlsBottomStaticConstraint.active = NO;
    self.mapControlsBottomStaticNoStopConstraint.active = NO;
    self.mapControlsBottomRouteConstraint.active = NO;
    self.mapControlsBottomRouteEarlyConstraint.active = NO;

    BOOL routeMode = self.coordinateMode == LSMapPickerCoordinateModeRoute;
    if (!routeMode) {
        if (self.stopButton.hidden) {
            self.mapControlsBottomStaticNoStopConstraint.active = YES;
        } else {
            self.mapControlsBottomStaticConstraint.active = YES;
        }
        return;
    }

    if (self.fetchedRoute != nil) {
        self.mapControlsBottomRouteConstraint.active = YES;
    } else {
        self.mapControlsBottomRouteEarlyConstraint.active = YES;
    }
}

- (void)ls_clearRouteAnnotationsAndOverlay {
    if (self.startAnnotation) {
        [self.mapView removeAnnotation:self.startAnnotation];
        self.startAnnotation = nil;
    }
    if (self.destinationAnnotation) {
        [self.mapView removeAnnotation:self.destinationAnnotation];
        self.destinationAnnotation = nil;
    }
    if (self.routePolyline) {
        [self.mapView removeOverlay:self.routePolyline];
        self.routePolyline = nil;
    }
    self.fetchedRoute = nil;
}

- (void)ls_handleRouteMapTap:(CLLocationCoordinate2D)coordinate {
    if (self.routePlacementPhase == LSRoutePlacementPhaseStart || !self.startAnnotation) {
        if (!self.startAnnotation) {
            self.startAnnotation = [[LSStartAnnotation alloc] init];
            self.startAnnotation.title = @"Start";
            [self.mapView addAnnotation:self.startAnnotation];
        }
        self.startAnnotation.coordinate = coordinate;
        self.routePlacementPhase = LSRoutePlacementPhaseDestination;
        self.mapHintLabel.text = @"  Tap map for destination  ";
    } else {
        if (!self.destinationAnnotation) {
            self.destinationAnnotation = [[LSDestinationAnnotation alloc] init];
            self.destinationAnnotation.title = @"Destination";
            [self.mapView addAnnotation:self.destinationAnnotation];
        }
        self.destinationAnnotation.coordinate = coordinate;
        self.routePlacementPhase = LSRoutePlacementPhaseStart;
        self.mapHintLabel.text = @"  Tap map to move start  ";
    }

    self.fetchedRoute = nil;
    if (self.routePolyline) {
        [self.mapView removeOverlay:self.routePolyline];
        self.routePolyline = nil;
    }
    self.getRouteButton.hidden = NO;
    [self updateCoordinateModeVisibility];
}

- (MKDirectionsTransportType)ls_directionsTransportType {
    switch (self.transportModeSegment.selectedSegmentIndex) {
        case 1:
        case 0:
            return MKDirectionsTransportTypeWalking;
        case 2:
            return MKDirectionsTransportTypeAutomobile;
        default:
            return MKDirectionsTransportTypeAny;
    }
}

- (LSTransportMode)ls_selectedTransportMode {
    switch (self.transportModeSegment.selectedSegmentIndex) {
        case 0:
            return LSTransportModeWalking;
        case 1:
            return LSTransportModeCycling;
        case 2:
            return LSTransportModeDriving;
        default:
            return LSTransportModeCustom;
    }
}

- (void)handleGetRouteTapped {
    if (!self.startAnnotation || !self.destinationAnnotation) {
        [self playRouteFailureHaptic];
        return;
    }

    self.getRouteButton.hidden = YES;
    [self.routeSpinner startAnimating];

    MKDirectionsRequest *request = [[MKDirectionsRequest alloc] init];
    request.source = [[MKMapItem alloc] initWithPlacemark:[[MKPlacemark alloc] initWithCoordinate:self.startAnnotation.coordinate]];
    request.destination = [[MKMapItem alloc] initWithPlacemark:[[MKPlacemark alloc] initWithCoordinate:self.destinationAnnotation.coordinate]];
    request.transportType = [self ls_directionsTransportType];

    MKDirections *directions = [[MKDirections alloc] initWithRequest:request];
    [directions calculateDirectionsWithCompletionHandler:^(MKDirectionsResponse * _Nullable response, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.routeSpinner stopAnimating];

            if (error || response.routes.count == 0) {
                [self playRouteFailureHaptic];
                self.getRouteButton.hidden = NO;
                self.statusLabel.text = @"Route fetch failed";
                __weak typeof(self) weakSelf = self;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [weakSelf refreshStatusPill];
                });
                return;
            }

            [self playRouteSuccessHaptic];
            self.fetchedRoute = response.routes.firstObject;
            if (self.routePolyline) {
                [self.mapView removeOverlay:self.routePolyline];
            }
            self.routePolyline = self.fetchedRoute.polyline;
            [self.mapView addOverlay:self.routePolyline];
            [self.mapView setVisibleMapRect:self.routePolyline.boundingMapRect edgePadding:UIEdgeInsetsMake(48, 48, 48, 48) animated:YES];
            [self updateCoordinateModeVisibility];
        });
    }];
}

- (void)handleTransportModeChanged:(UISegmentedControl *)sender {
    (void)sender;
    [self ls_updateCustomSpeedVisibility];
    LSRouteSimulator *simulator = [LSRouteSimulator shared];
    if (simulator.isSimulating) {
        simulator.transportMode = [self ls_selectedTransportMode];
        if (simulator.transportMode == LSTransportModeCustom) {
            NSNumber *parsed = [self ls_parsedCoordinateComponentFromText:self.customSpeedField.text];
            simulator.customSpeedKmh = parsed ? parsed.doubleValue : 30.0;
        }
    }
}

- (void)ls_updateCustomSpeedVisibility {
    self.customSpeedField.hidden = self.transportModeSegment.hidden || self.transportModeSegment.selectedSegmentIndex != 3;
    self.customSpeedHeightConstraint.constant = self.customSpeedField.hidden ? 0.0 : 40.0;
}

- (void)handlePlayRouteTapped {
    if (!self.fetchedRoute) {
        return;
    }

    LSRouteSimulator *simulator = [LSRouteSimulator shared];
    simulator.delegate = self;
    simulator.transportMode = [self ls_selectedTransportMode];
    if (simulator.transportMode == LSTransportModeCustom) {
        NSNumber *parsed = [self ls_parsedCoordinateComponentFromText:self.customSpeedField.text];
        simulator.customSpeedKmh = MAX(parsed ? parsed.doubleValue : 30.0, 1.0);
    }

    CLLocationCoordinate2D start = self.startAnnotation.coordinate;
    [[PersistenceManager shared] setSpoofCoordinate:start enabled:YES];
    [PersistenceManager shared].simulationWasActive = YES;

    [simulator startWithRoute:self.fetchedRoute];
    [self ls_updateRoutePlaybackButtons];
    [self refreshStatusPill];
}

- (void)handlePauseRouteTapped {
    LSRouteSimulator *simulator = [LSRouteSimulator shared];
    if (simulator.isPaused) {
        [simulator resume];
        [self.pauseRouteButton setTitle:@"Pause" forState:UIControlStateNormal];
    } else {
        [simulator pause];
        [self.pauseRouteButton setTitle:@"Resume" forState:UIControlStateNormal];
    }
}

- (void)handleStopRouteTapped {
    [[LSRouteSimulator shared] stop];
    [PersistenceManager shared].simulationWasActive = NO;
    [self playSimulationStopHaptic];
    [self ls_updateRoutePlaybackButtons];
    [self refreshStatusPill];
}

- (void)ls_updateRoutePlaybackButtons {
    LSRouteSimulator *simulator = [LSRouteSimulator shared];
    if (!simulator.isSimulating) {
        [self.playRouteButton setTitle:@"Play" forState:UIControlStateNormal];
        self.playRouteButton.hidden = self.fetchedRoute == nil || self.coordinateMode != LSMapPickerCoordinateModeRoute;
        self.routeActionRow.hidden = YES;
        return;
    }

    self.playRouteButton.hidden = YES;
    self.routeActionRow.hidden = NO;
    [self.pauseRouteButton setTitle:simulator.isPaused ? @"Resume" : @"Pause" forState:UIControlStateNormal];
}

- (void)restoreSimulationUIIfNeeded {
    if (![PersistenceManager shared].simulationWasActive) {
        return;
    }

    [PersistenceManager shared].simulationWasActive = NO;
    self.statusLabel.text = @"Previous route session expired";
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf refreshStatusPill];
    });
}

#pragma mark - LSRouteSimulatorDelegate

- (void)routeSimulator:(LSRouteSimulator *)simulator didUpdateCoordinate:(CLLocationCoordinate2D)coordinate heading:(CLLocationDirection)heading {
    (void)heading;
    double kmh = [LSRouteSimulator speedMetersPerSecondForMode:simulator.transportMode customSpeedKmh:simulator.customSpeedKmh] * 3.6;
    self.statusLabel.text = [NSString stringWithFormat:@"Simulating · %.1f km/h", kmh];
    self.statusDot.backgroundColor = UIColor.systemGreenColor;
    (void)coordinate;
}

- (void)routeSimulatorDidFinish:(LSRouteSimulator *)simulator {
    (void)simulator;
    [PersistenceManager shared].simulationWasActive = NO;
    self.statusLabel.text = @"Route complete";
    [self ls_updateRoutePlaybackButtons];
    [self refreshStatusPill];
}

- (MKOverlayRenderer *)ls_rendererForMapOverlay:(id<MKOverlay>)overlay {
    if (overlay == self.routePolyline) {
        MKPolylineRenderer *renderer = [[MKPolylineRenderer alloc] initWithPolyline:(MKPolyline *)overlay];
        renderer.strokeColor = UIColor.systemBlueColor;
        renderer.lineWidth = 4.0;
        return renderer;
    }
    return nil;
}

- (nullable MKAnnotationView *)ls_viewForRouteAnnotation:(id<MKAnnotation>)annotation {
    if ([annotation isKindOfClass:[LSStartAnnotation class]]) {
        static NSString * const identifier = @"LSStartPin";
        MKMarkerAnnotationView *view = (MKMarkerAnnotationView *)[self.mapView dequeueReusableAnnotationViewWithIdentifier:identifier];
        if (!view) {
            view = [[MKMarkerAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:identifier];
            view.canShowCallout = YES;
            view.draggable = YES;
        } else {
            view.annotation = annotation;
        }
        view.markerTintColor = UIColor.systemGreenColor;
        return view;
    }

    if ([annotation isKindOfClass:[LSDestinationAnnotation class]]) {
        static NSString * const identifier = @"LSDestinationPin";
        MKMarkerAnnotationView *view = (MKMarkerAnnotationView *)[self.mapView dequeueReusableAnnotationViewWithIdentifier:identifier];
        if (!view) {
            view = [[MKMarkerAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:identifier];
            view.canShowCallout = YES;
            view.draggable = YES;
        } else {
            view.annotation = annotation;
        }
        view.markerTintColor = UIColor.systemRedColor;
        return view;
    }

    return nil;
}

- (void)ls_routeAnnotationDragEnded:(MKAnnotationView *)view {
    if (view.annotation == self.startAnnotation || view.annotation == self.destinationAnnotation) {
        self.fetchedRoute = nil;
        if (self.routePolyline) {
            [self.mapView removeOverlay:self.routePolyline];
            self.routePolyline = nil;
        }
        [self updateCoordinateModeVisibility];
    }
}

- (UIButton *)ls_primaryButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    button.backgroundColor = UIColor.systemBlueColor;
    button.layer.cornerRadius = 12.0;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIButton *)ls_secondaryButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    button.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    button.layer.cornerRadius = 12.0;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

@end
