#import "MapPickerViewController.h"
#import "SessionController.h"
#import "BookmarksManager.h"
#import "LSUI.h"
#import <MapKit/MapKit.h>
NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, LSPickerTab) { LSPickerTabLocation, LSPickerTabRoute, LSPickerTabSaved };
typedef NS_ENUM(NSInteger, LSEndpoint) { LSEndpointFrom, LSEndpointTo };
@interface LSStartAnnotation : MKPointAnnotation @end
@interface LSDestinationAnnotation : MKPointAnnotation @end
@interface LSMovingAnnotation : MKPointAnnotation @end
@interface LSRealAnnotation : MKPointAnnotation @end

@interface MapPickerViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic) LSPickerTab tab;
@property (nonatomic) LSEndpoint endpoint;
@property (nonatomic) BOOL closed;
@property (nonatomic) NSUInteger selectionRevision;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIStackView *contentStack;
@property (nonatomic, strong) UISegmentedControl *tabs;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *brandLabel;
@property (nonatomic, strong) UILabel *appliedLabel;
@property (nonatomic, strong) UIView *mapContainer;
@property (nonatomic, strong) MKMapView *mapView;
@property (nonatomic, strong) UIButton *mapRetryButton;
@property (nonatomic, strong) UIButton *realCenterButton;
@property (nonatomic, strong) UILabel *mapHintLabel;
@property (nonatomic, strong) UILabel *mapErrorLabel;
@property (nonatomic) BOOL mapFailed;
@property (nonatomic, strong) UILabel *realNoticeLabel;
@property (nonatomic, strong) UIView *locationIntro;
@property (nonatomic, strong) UIView *locationDetails;
@property (nonatomic, strong) UILabel *placeLabel;
@property (nonatomic, strong) UILabel *coordinateLabel;
@property (nonatomic, strong) UIButton *savePlaceButton;
@property (nonatomic) CLLocationCoordinate2D selectedCoordinate;
@property (nonatomic) BOOL hasSelection;
@property (nonatomic, copy) NSString *selectedName;
@property (nonatomic, strong) MKPointAnnotation *pin;
@property (nonatomic, strong, nullable) MKCircle *radiusCircle;
@property (nonatomic, strong, nullable) LSMovingAnnotation *appliedPin;
@property (nonatomic, strong, nullable) LSRealAnnotation *realPin;
@property (nonatomic, strong, nullable) CLLocationManager *realManager;
@property (nonatomic) NSUInteger realRevision;
@property (nonatomic, strong) UIButton *primaryButton;
@property (nonatomic, strong) UIButton *holdButton;
@property (nonatomic, strong) UIButton *offButton;
@property (nonatomic, strong) UIStackView *playbackRow;
@property (nonatomic) LSSessionMode previousMode;
@property (nonatomic) NSTimeInterval lastUIUpdate;

@property (nonatomic, strong) UIView *routeEndpointsPanel;
@property (nonatomic, strong) UIView *routeDetailsPanel;
@property (nonatomic, strong) UIButton *fromButton;
@property (nonatomic, strong) UIButton *toButton;
@property (nonatomic, strong) UISegmentedControl *endpointSegment;
@property (nonatomic, strong) UISegmentedControl *profileSegment;
@property (nonatomic, strong) UIButton *speedButton;
@property (nonatomic, strong) UIButton *buildRouteButton;
@property (nonatomic, strong) UIButton *swapButton;
@property (nonatomic, strong) UILabel *routeFeedback;
@property (nonatomic, strong) UILabel *routeSummary;
@property (nonatomic, strong) UILabel *progressLabel;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UIActivityIndicatorView *routeSpinner;
@property (nonatomic, strong, nullable) LSStartAnnotation *startPin;
@property (nonatomic, strong, nullable) LSDestinationAnnotation *endPin;
@property (nonatomic, strong, nullable) MKRoute *fetchedRoute;
@property (nonatomic, strong, nullable) MKPolyline *routePolyline;
@property (nonatomic, strong, nullable) MKDirections *directions;
@property (nonatomic) NSUInteger routeRevision;
@property (nonatomic) double draftSpeedKmh;
@property (nonatomic) BOOL routeDraftChanged;

@property (nonatomic, strong) UITableView *savedTable;
@property (nonatomic, strong) UIView *savedToolbar;
@property (nonatomic, strong) UIButton *editSavedButton;
@property (nonatomic, strong) UILabel *savedHint;
@property (nonatomic, strong) NSArray<LSBookmark *> *savedPlaces;
@property (nonatomic, strong) NSArray<NSDictionary *> *recents;

- (void)updateWorkspace;
- (void)updateFooter;
- (void)refreshSession;
- (void)setSelection:(CLLocationCoordinate2D)coordinate name:(NSString *)name;
- (void)openPlaceChooser:(NSString *)title coordinate:(CLLocationCoordinate2D)coordinate completion:(void (^)(CLLocationCoordinate2D, NSString *))completion;
- (void)showMessage:(NSString *)message;
- (void)updateRadiusPreview;
- (void)updateRealLocation;
- (void)confirmAction:(NSString *)title message:(NSString *)message button:(NSString *)button action:(dispatch_block_t)action;
- (void)dismissPicker;
@end

@interface MapPickerViewController (LSRouteUI)
- (void)buildRouteUI;
- (void)restoreRoute;
- (void)updateRouteUI;
- (void)assignEndpoint:(LSEndpoint)endpoint coordinate:(CLLocationCoordinate2D)coordinate name:(NSString *)name;
- (void)cancelDirections;
- (void)invalidateRouteDraft;
- (void)fetchRoute;
- (MKDirections *)directionsForRequest:(MKDirectionsRequest *)request;
- (void)startDraftRoute;
- (void)chooseEndpoint:(UIButton *)sender;
- (void)updatePlayback;
@end

@interface MapPickerViewController (LSBookmarksUI)
- (void)buildSavedUI;
- (void)reloadSavedPlaces;
- (void)layoutSavedHeader;
- (void)saveSelectedPlace;
- (NSInteger)savedRowsInSection:(NSInteger)section;
- (UITableViewCell *)savedCell:(NSIndexPath *)path;
- (void)previewSavedPlace:(NSIndexPath *)path;
- (nullable UIContextMenuConfiguration *)savedMenu:(NSIndexPath *)path;
- (void)moveSavedPlace:(NSIndexPath *)source to:(NSIndexPath *)destination;
@end
NS_ASSUME_NONNULL_END
