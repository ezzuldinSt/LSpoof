#import "MapPickerViewController.h"
#import "SessionController.h"
#import "BookmarksManager.h"
#import "LSUI.h"
#import "LSRoute.h"
#import <MapKit/MapKit.h>
NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, LSPickerTab) { LSPickerTabLocation, LSPickerTabRoute, LSPickerTabSaved };
// Matches the order of the "Map taps" segments.
typedef NS_ENUM(NSInteger, LSEndpoint) { LSEndpointFrom, LSEndpointStop, LSEndpointTo };
@interface LSStartAnnotation : MKPointAnnotation @end
@interface LSDestinationAnnotation : MKPointAnnotation @end
@interface LSStopAnnotation : MKPointAnnotation @end
@interface LSMovingAnnotation : MKPointAnnotation @end
@interface LSRealAnnotation : MKPointAnnotation @end

@interface MapPickerViewController () <UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate>
@property (nonatomic) LSPickerTab tab;
@property (nonatomic) LSEndpoint endpoint;
@property (nonatomic) BOOL closed;
@property (nonatomic) NSUInteger selectionRevision;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIStackView *contentStack;
@property (nonatomic, strong) UISegmentedControl *tabs;
@property (nonatomic, strong) LSStatusChip *statusChip;
@property (nonatomic, strong) UILabel *brandLabel;
@property (nonatomic, strong) UILabel *appliedLabel;
@property (nonatomic, strong) UIView *mapContainer;
@property (nonatomic, strong) NSLayoutConstraint *mapHeight;
@property (nonatomic, strong) UIButton *mapStyleButton;
@property (nonatomic, strong) UIButton *coordinateCopyButton;
@property (nonatomic, strong) UIButton *useRealButton;
@property (nonatomic, strong) UIStackView *locationActions;
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
@property (nonatomic, strong) UIButton *radiusChip;
@property (nonatomic, strong) UIButton *scheduleButton;
@property (nonatomic, strong) UIView *scheduleBanner;
@property (nonatomic, strong) UILabel *scheduleLabel;
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
@property (nonatomic, strong) NSArray<UIButton *> *speedChips;
@property (nonatomic, strong) UIStackView *speedRow;
@property (nonatomic, strong) UILabel *progressPercentLabel;
@property (nonatomic, strong) UIView *progressPanel;
@property (nonatomic, strong) UIButton *buildRouteButton;
@property (nonatomic, strong) UIButton *swapButton;
@property (nonatomic, strong) UILabel *routeFeedback;
@property (nonatomic, strong) UILabel *routeSummary;
@property (nonatomic, strong) UILabel *progressLabel;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UIActivityIndicatorView *routeSpinner;
@property (nonatomic, strong, nullable) LSStartAnnotation *startPin;
@property (nonatomic, strong, nullable) LSDestinationAnnotation *endPin;
// Planned stops between From and To, in order (up to 10).
@property (nonatomic, strong) NSMutableArray<LSStopAnnotation *> *routeStops;
@property (nonatomic, strong) UIStackView *stopsStack;
@property (nonatomic, strong) UIButton *addStopButton;
@property (nonatomic, strong, nullable) LSRoute *fetchedRoute;
@property (nonatomic, strong, nullable) MKPolyline *routePolyline;
@property (nonatomic, strong, nullable) MKDirections *directions;
@property (nonatomic, strong, nullable) MKLocalSearch *linkSearch;
@property (nonatomic) NSUInteger routeRevision;
@property (nonatomic) double draftSpeedKmh;
@property (nonatomic) BOOL draftRecordedPace;
@property (nonatomic) double draftPaceMultiplier;
@property (nonatomic) BOOL routeDraftChanged;
@property (nonatomic, strong) UIButton *recordedChip;
@property (nonatomic, strong) UIButton *motionButton;
@property (nonatomic, strong) UIButton *waitButton;
@property (nonatomic, strong) UIButton *finishButton;
@property (nonatomic, strong) UIButton *shareButton;
@property (nonatomic, strong) UIButton *importButton;
@property (nonatomic, strong) UIStackView *liveSpeedRow;
@property (nonatomic, strong) UILabel *liveSpeedLabel;
@property (nonatomic, strong) UIButton *slowerButton;
@property (nonatomic, strong) UIButton *fasterButton;

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
- (void)renderSelectedLocation;
- (void)openPlaceChooser:(NSString *)title coordinate:(CLLocationCoordinate2D)coordinate completion:(void (^)(CLLocationCoordinate2D, NSString *))completion;
- (void)showMessage:(NSString *)message;
- (void)showMessage:(NSString *)message symbol:(nullable NSString *)symbol;
- (void)updateRadiusPreview;
- (void)updateRealLocation;
- (void)confirmAction:(NSString *)title message:(NSString *)message button:(NSString *)button action:(dispatch_block_t)action;
- (void)confirmAction:(NSString *)title message:(NSString *)message button:(NSString *)button destructive:(BOOL)destructive action:(dispatch_block_t)action;
- (void)applyCoordinate:(CLLocationCoordinate2D)coordinate name:(NSString *)name;
- (void)dismissPicker;
- (void)presentEditor:(UIViewController *)editor;
- (void)presentShareItems:(NSArray *)items from:(UIView *)source;
- (void)updateScheduleBanner;
- (void)openSchedule;
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
- (void)importMapLinkText:(NSString *)text;
- (void)endpointChanged;
- (void)moveStop:(LSStopAnnotation *)stop to:(CLLocationCoordinate2D)coordinate name:(NSString *)name;
- (UIMenu *)importMenu;
- (void)openTrackFile;
- (void)importTrackAtURL:(NSURL *)url;
- (nullable LSPlaybackOptions *)draftOptions;
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
- (nullable UISwipeActionsConfiguration *)savedSwipeActions:(NSIndexPath *)path leading:(BOOL)leading;
// Wander radius choices for a saved place, as a submenu.
- (UIMenu *)radiusMenuForBookmark:(LSBookmark *)place;
@end
// Per-area additions. Each screen owner adds its own properties and declarations in its
// own block so concurrent work on the picker does not collide.
@interface MapPickerViewController () // Shell, header, Location tab and footer (MapPickerViewController.m)
// The map runs edge to edge under a floating glass header, place card, control cluster and
// footer. This guide (owned by mapContainer, kept across map retries) is the part of the map
// nothing covers; pin map overlays inside it.
@property (nonatomic, strong) UILayoutGuide *mapVisibleGuide;
// How far the floating surfaces reach into mapView's bounds on each edge.
- (UIEdgeInsets)mapObscuredInsets;
// Fit a rect or a spot into the uncovered part of the map (setVisibleMapRect and setRegion fit
// the whole view, part of which is under the header). Respects Reduce Motion.
- (void)focusMapOnRect:(MKMapRect)rect animated:(BOOL)animated;
- (void)focusMapOnCoordinate:(CLLocationCoordinate2D)coordinate meters:(double)meters animated:(BOOL)animated;
@end
@class LSRouteRailView, LSRouteInstrumentView, LSRouteStatView;
@interface MapPickerViewController () // Route planner and playback (MapPickerViewController+Route.m)
// Planner card: From, stops and To on one connected rail, and the chips for what a map tap sets
// (endpointSegment stays the model the shell writes; it is not on screen).
@property (nonatomic, strong) LSRouteRailView *routeFromRail;
@property (nonatomic, strong) LSRouteRailView *routeToRail;
@property (nonatomic, strong) LSRouteRailView *routeAddRail;
@property (nonatomic, copy) NSArray<UIButton *> *routeTargetChips;
@property (nonatomic) BOOL routeHighlightQueued;
// Status card: empty, busy, error and ready states.
@property (nonatomic, strong) UIView *routeEmptyState;
@property (nonatomic, strong) UIView *routeFeedbackWrap;
@property (nonatomic, strong) UIImageView *routeFeedbackIcon;
@property (nonatomic) NSInteger routeFeedbackTone;
@property (nonatomic) BOOL routeFeedbackIsHint;
@property (nonatomic) BOOL routeSuggestsOtherPath;
@property (nonatomic, strong) UIButton *routeRecoveryButton;
@property (nonatomic, strong) UIView *routeStatsWrap;
@property (nonatomic, copy) NSArray<LSRouteStatView *> *routeStats;
@property (nonatomic, strong) UIView *routeToolsWrap;
@property (nonatomic, strong, nullable) UIView *routeTip;
@property (nonatomic) NSUInteger routeExportRevision;
// Map: an outline under the route, the travelled part dimmed, and the draw-in once built.
@property (nonatomic, strong, nullable) MKPolyline *routeCasing;
@property (nonatomic, weak, nullable) MKPolylineRenderer *routeLineRenderer;
@property (nonatomic, weak, nullable) MKPolylineRenderer *routeCasingRenderer;
@property (nonatomic) double routeTraveledShown;
@property (nonatomic) NSTimeInterval routeTraveledAt;
@property (nonatomic) NSUInteger routeDrawRevision;
@property (nonatomic) BOOL routeDrawInPending;
@property (nonatomic, weak, nullable) UIView *routeTraceView;
// Playback instrument and the spoken milestones (halfway, each stop, arrival).
@property (nonatomic, strong) LSRouteInstrumentView *routeInstrument;
@property (nonatomic, weak, nullable) LSRoute *milestoneRoute;
@property (nonatomic) double milestoneCovered;
@property (nonatomic) NSUInteger milestoneStops;
@property (nonatomic) BOOL milestoneHalfway;
@property (nonatomic) BOOL milestoneArrived;
@end
@interface MapPickerViewController (LSRouteMapStyle)
// Called by the map delegate in MapPickerViewController.m. Return nil to use the default renderer.
- (nullable MKOverlayRenderer *)routeRendererForOverlay:(id<MKOverlay>)overlay;
// Called after the default styling of a From, stop or To marker.
- (void)styleRouteAnnotationView:(MKMarkerAnnotationView *)view;
@end
@interface MapPickerViewController () // Saved places (MapPickerViewController+Bookmarks.m)
// Every saved place; savedPlaces and recents hold only the rows the filter lets through.
@property (nonatomic, strong, nullable) NSArray<LSBookmark *> *allSavedPlaces;
@property (nonatomic) NSUInteger allRecentCount;
// Identity of each visible row per section, so changes animate instead of reloading.
@property (nonatomic, copy, nullable) NSArray<NSArray<NSString *> *> *savedRowKeys;
@property (nonatomic, strong, nullable) NSArray<UITableViewHeaderFooterView *> *savedSectionHeaders;
@property (nonatomic, strong, nullable) UIButton *savedClearButton;
@property (nonatomic, strong, nullable) UISearchTextField *savedFilterField;
@property (nonatomic, strong, nullable) UIView *savedEmptyHolder;
@property (nonatomic, copy, nullable) NSString *savedEmptyVariant;
@property (nonatomic, strong, nullable) UIView *savedTip;
@property (nonatomic, strong, nullable) UIView *savedToastAnchor;
@property (nonatomic, copy, nullable) NSString *savedPulseKey;
// What the session holds: the Applied badge and the distances shown on rows.
@property (nonatomic) NSInteger savedSessionMode;
@property (nonatomic) CLLocationCoordinate2D savedHeldCoordinate;
@property (nonatomic) CLLocationCoordinate2D savedReferenceCoordinate;
@end
NS_ASSUME_NONNULL_END
