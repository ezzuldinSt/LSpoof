#import "MapPickerViewController.h"
#import "RouteSimulator.h"

#import <MapKit/MapKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, LSMapPickerPanelTab) {
    LSMapPickerPanelTabMap = 0,
    LSMapPickerPanelTabBookmarks = 1
};

typedef NS_ENUM(NSInteger, LSMapPickerCoordinateMode) {
    LSMapPickerCoordinateModeStatic = 0,
    LSMapPickerCoordinateModeRoute = 1
};

typedef NS_ENUM(NSInteger, LSRoutePlacementPhase) {
    LSRoutePlacementPhaseStart = 0,
    LSRoutePlacementPhaseDestination = 1
};

@interface LSStartAnnotation : MKPointAnnotation
@end

@interface LSDestinationAnnotation : MKPointAnnotation
@end

@interface MapPickerViewController ()

@property (nonatomic, strong) UIView *headerView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIView *statusPill;
@property (nonatomic, strong) UIView *statusDot;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UILabel *pillStopLabel;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UIActivityIndicatorView *searchSpinner;
@property (nonatomic, strong) MKLocalSearchCompleter *searchCompleter;
@property (nonatomic, strong) NSArray<MKLocalSearchCompletion *> *searchCompletions;
@property (nonatomic, strong) UIView *suggestionsPanel;
@property (nonatomic, strong) UITableView *suggestionsTableView;
@property (nonatomic, strong) NSLayoutConstraint *suggestionsHeightConstraint;
@property (nonatomic, strong) NSLayoutConstraint *mapHeightConstraint;
@property (nonatomic, assign) BOOL searchSuggestionsVisible;
@property (nonatomic, strong) UIScrollView *contentScrollView;
@property (nonatomic, strong) UIView *scrollContentView;
@property (nonatomic, strong) UIView *mapContainer;
@property (nonatomic, strong) MKMapView *mapView;
@property (nonatomic, strong) UILabel *mapHintLabel;
@property (nonatomic, strong) UIActivityIndicatorView *mapSpinner;
@property (nonatomic, strong) UIVisualEffectView *controlPanel;
@property (nonatomic, strong) UISegmentedControl *panelTabSegment;
@property (nonatomic, strong) UISegmentedControl *coordinateModeSegment;
@property (nonatomic, strong) UIView *mapControlsContainer;
@property (nonatomic, strong) UIStackView *mapControlsStack;
@property (nonatomic, strong) UIView *staticControlsContainer;
@property (nonatomic, strong) UIView *routeControlsContainer;
@property (nonatomic, strong) UIView *bookmarksContainer;
@property (nonatomic, strong) UITableView *bookmarksTableView;
@property (nonatomic, strong) UILabel *coordinateTitleLabel;
@property (nonatomic, strong) UILabel *coordinateValueLabel;
@property (nonatomic, strong) UIButton *bookmarkSaveButton;
@property (nonatomic, strong) UIView *separatorCoordFields;
@property (nonatomic, strong) UIView *separatorFieldsHeading;
@property (nonatomic, strong) UIView *separatorHeadingActions;
@property (nonatomic, strong) UIView *separatorFluctuation;
@property (nonatomic, strong) UIView *fluctuationRow;
@property (nonatomic, strong) UILabel *fluctuationLabel;
@property (nonatomic, strong) UISwitch *fluctuationSwitch;
@property (nonatomic, strong) UITextField *fluctuationRadiusField;
@property (nonatomic, strong) NSLayoutConstraint *fluctuationRadiusHeightConstraint;
@property (nonatomic, strong) NSLayoutConstraint *fluctuationRadiusTopConstraint;
@property (nonatomic, strong) UIStackView *fieldStack;
@property (nonatomic, strong) UITextField *latitudeField;
@property (nonatomic, strong) UITextField *longitudeField;
@property (nonatomic, strong) UITextField *altitudeField;
@property (nonatomic, strong) UISlider *headingSlider;
@property (nonatomic, strong) UILabel *headingValueLabel;
@property (nonatomic, strong) UILabel *headingDirectionLabel;
@property (nonatomic, strong) UIButton *applyButton;
@property (nonatomic, strong) UIButton *cancelButton;
@property (nonatomic, strong) UIButton *stopButton;
@property (nonatomic, strong) UIStackView *actionRow;
@property (nonatomic, strong) NSLayoutConstraint *stopButtonHeightConstraint;
@property (nonatomic, strong) NSLayoutConstraint *mapControlsBottomStaticConstraint;
@property (nonatomic, strong) NSLayoutConstraint *mapControlsBottomStaticNoStopConstraint;
@property (nonatomic, strong) NSLayoutConstraint *mapControlsBottomRouteConstraint;
@property (nonatomic, strong) NSLayoutConstraint *mapControlsBottomRouteEarlyConstraint;
@property (nonatomic, strong) MKPointAnnotation *pinAnnotation;
@property (nonatomic, strong, nullable) LSStartAnnotation *startAnnotation;
@property (nonatomic, strong, nullable) LSDestinationAnnotation *destinationAnnotation;
@property (nonatomic, assign) LSRoutePlacementPhase routePlacementPhase;
@property (nonatomic, strong, nullable) MKRoute *fetchedRoute;
@property (nonatomic, strong, nullable) MKPolyline *routePolyline;
@property (nonatomic, strong) UIButton *getRouteButton;
@property (nonatomic, strong) UISegmentedControl *transportModeSegment;
@property (nonatomic, strong) UITextField *customSpeedField;
@property (nonatomic, strong) UIButton *playRouteButton;
@property (nonatomic, strong) UIActivityIndicatorView *routeSpinner;
@property (nonatomic, strong) UIButton *pauseRouteButton;
@property (nonatomic, strong) UIButton *stopRouteButton;
@property (nonatomic, strong) UIStackView *routeActionRow;
@property (nonatomic, strong) NSLayoutConstraint *customSpeedHeightConstraint;
@property (nonatomic, assign) CLLocationCoordinate2D selectedCoordinate;
@property (nonatomic, assign) BOOL hasSelectedCoordinate;
@property (nonatomic, assign) BOOL mapConfigured;
@property (nonatomic, assign) BOOL suppressFieldSync;
@property (nonatomic, assign) LSMapPickerPanelTab panelTab;
@property (nonatomic, assign) LSMapPickerCoordinateMode coordinateMode;
@property (nonatomic, assign) BOOL bookmarksEditMode;

- (void)refreshStatusPill;
- (void)syncFieldsFromCoordinate;
- (void)updateCoordinateLabel;
- (void)movePinToCoordinate:(CLLocationCoordinate2D)coordinate animated:(BOOL)animated;
- (void)updatePinOnMapAnimated:(BOOL)animated;
- (nullable NSNumber *)ls_parsedCoordinateComponentFromText:(NSString *)text;
- (BOOL)applyFieldsToCoordinate;
- (BOOL)applyAltitudeField;
- (void)updateHeadingLabel;
- (void)showInvalidCoordinateFeedback;
- (void)playApplyHaptic;
- (void)playRouteSuccessHaptic;
- (void)playRouteFailureHaptic;
- (void)playBookmarkSavedHaptic;
- (void)playSimulationStopHaptic;
- (void)dismissKeyboard;
- (void)handleMapTap:(UITapGestureRecognizer *)gesture;
- (void)handleMapLongPress:(UILongPressGestureRecognizer *)gesture;
- (void)handleHeadingSliderChanged:(UISlider *)sender;

@end

@interface MapPickerViewController (LSRouteUI) <LSRouteSimulatorDelegate>

- (void)buildRouteControls;
- (void)ls_handleRouteMapTap:(CLLocationCoordinate2D)coordinate;
- (void)updateCoordinateModeVisibility;
- (void)ls_updateMapControlsBottomConstraint;
- (void)restoreSimulationUIIfNeeded;
- (void)restoreRouteUIFromSimulator;
- (void)ls_installRouteConstraintsInRoutePanel;
- (MKOverlayRenderer *)ls_rendererForMapOverlay:(id<MKOverlay>)overlay;
- (nullable MKAnnotationView *)ls_viewForRouteAnnotation:(id<MKAnnotation>)annotation;
- (void)ls_routeAnnotationDragEnded:(MKAnnotationView *)view;

@end

@interface MapPickerViewController (LSBookmarksUI)

- (void)buildBookmarksPanel;
- (void)updatePanelTabVisibility;
- (void)handlePanelTabChanged:(UISegmentedControl *)sender;
- (void)handleCoordinateModeChanged:(UISegmentedControl *)sender;
- (void)handleBookmarkSaveTapped;
- (void)presentSaveBookmarkAlertWithSuggestedName:(nullable NSString *)name coordinate:(CLLocationCoordinate2D)coordinate;
- (BOOL)ls_isBookmarksTableView:(UITableView *)tableView;
- (NSInteger)ls_bookmarksNumberOfSections;
- (NSInteger)ls_bookmarksNumberOfRowsInSection:(NSInteger)section;
- (NSString *)ls_bookmarksTitleForHeaderInSection:(NSInteger)section;
- (UITableViewCell *)ls_bookmarksCellForRowAtIndexPath:(NSIndexPath *)indexPath;
- (void)ls_bookmarksDidSelectRowAtIndexPath:(NSIndexPath *)indexPath;
- (BOOL)ls_bookmarksCanEditRowAtIndexPath:(NSIndexPath *)indexPath;
- (void)ls_bookmarksCommitDeleteAtIndexPath:(NSIndexPath *)indexPath;
- (BOOL)ls_bookmarksCanMoveRowAtIndexPath:(NSIndexPath *)indexPath;
- (void)ls_bookmarksMoveFromIndexPath:(NSIndexPath *)source toIndexPath:(NSIndexPath *)destination;
- (UIView *)ls_bookmarksHeaderForSection:(NSInteger)section;
- (void)ls_presentStaticMapActionSheetAtCoordinate:(CLLocationCoordinate2D)coordinate;

@end

NS_ASSUME_NONNULL_END
