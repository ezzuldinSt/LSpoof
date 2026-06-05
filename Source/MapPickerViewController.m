#import "MapPickerViewController.h"
#import "MapPickerViewController+Private.h"
#import "LocationSpoofer.h"
#import "OverlayWindow.h"
#import "PersistenceManager.h"
#import "RouteSimulator.h"

#import <CoreLocation/CoreLocation.h>
#import <MapKit/MapKit.h>

static const CGFloat kLSCornerRadius = 16.0;
static const CGFloat kLSHorizontalInset = 20.0;
static const CGFloat kLSControlPanelCornerRadius = 16.0;
static const CGFloat kLSSuggestionRowHeight = 48.0;
static const CGFloat kLSSuggestionMaxHeight = 240.0;
static const NSInteger kLSSuggestionMaxVisibleRows = 5;
static const CGFloat kLSMapHeightMultiplier = 0.30;

@interface MapPickerViewController () <MKMapViewDelegate, UISearchBarDelegate, UITextFieldDelegate, MKLocalSearchCompleterDelegate, UITableViewDataSource, UITableViewDelegate>
@end

@implementation MapPickerViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.selectedCoordinate = CLLocationCoordinate2DMake(37.7749, -122.4194);
    self.hasSelectedCoordinate = NO;

    PersistenceManager *store = [PersistenceManager shared];
    if ([store isSpoofingEnabled] || [store hasStoredCoordinate]) {
        self.selectedCoordinate = [store spoofCoordinate];
        self.hasSelectedCoordinate = YES;
    }
    self.panelTab = LSMapPickerPanelTabMap;
    self.coordinateMode = LSMapPickerCoordinateModeStatic;

    [self buildInterface];
    [self buildRouteControls];
    [self buildBookmarksPanel];
    [self installConstraints];
    [self configureKeyboardToolbar];
    [self configureSearchCompleter];
    [self restoreSimulationUIIfNeeded];
    [self refreshStatusPill];
    [self syncFieldsFromCoordinate];
    self.altitudeField.text = [NSString stringWithFormat:@"%.0f", store.altitude];
    self.headingSlider.value = (float)store.heading;
    [self updateHeadingLabel];
    [self updatePanelTabVisibility];

    [self syncFluctuationUI];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(ls_keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(ls_keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    LSSetHooksBypassed(YES);
    [LSOverlayManager setMapPickerVisible:YES];
    [self refreshStatusPill];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    LSSetHooksBypassed(YES);
    [self configureMapIfNeeded];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [LSOverlayManager restoreMapPickerSessionState];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [LSOverlayManager restoreMapPickerSessionState];
}

#pragma mark - Interface

- (void)buildInterface {
    self.contentScrollView = [[UIScrollView alloc] init];
    self.contentScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentScrollView.alwaysBounceVertical = YES;
    self.contentScrollView.showsVerticalScrollIndicator = YES;
    self.contentScrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.contentScrollView.clipsToBounds = NO;
    [self.view addSubview:self.contentScrollView];

    self.scrollContentView = [[UIView alloc] init];
    self.scrollContentView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentScrollView addSubview:self.scrollContentView];

    [self buildHeader];
    [self buildSearchBar];
    [self buildMapSection];
    [self buildControlPanel];
}

- (void)buildHeader {
    self.headerView = [[UIView alloc] init];
    self.headerView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollContentView addSubview:self.headerView];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.text = @"Location Spoofer";
    self.titleLabel.font = [UIFont systemFontOfSize:28.0 weight:UIFontWeightBold];
    self.titleLabel.textColor = UIColor.labelColor;
    self.titleLabel.accessibilityTraits = UIAccessibilityTraitHeader;
    [self.headerView addSubview:self.titleLabel];

    self.subtitleLabel = [[UILabel alloc] init];
    self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.subtitleLabel.text = @"Choose where apps think you are";
    self.subtitleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular];
    self.subtitleLabel.textColor = UIColor.secondaryLabelColor;
    self.subtitleLabel.numberOfLines = 2;
    [self.headerView addSubview:self.subtitleLabel];

    self.statusPill = [[UIView alloc] init];
    self.statusPill.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusPill.backgroundColor = [UIColor.tertiarySystemFillColor colorWithAlphaComponent:0.9];
    self.statusPill.layer.cornerRadius = 14.0;
    self.statusPill.layer.cornerCurve = kCACornerCurveContinuous;
    self.statusPill.userInteractionEnabled = YES;
    [self.headerView addSubview:self.statusPill];

    self.statusDot = [[UIView alloc] init];
    self.statusDot.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusDot.layer.cornerRadius = 5.0;
    [self.statusPill addSubview:self.statusDot];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    [self.statusPill addSubview:self.statusLabel];

    self.pillStopLabel = [[UILabel alloc] init];
    self.pillStopLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.pillStopLabel.text = @"Stop";
    self.pillStopLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    self.pillStopLabel.textColor = UIColor.systemRedColor;
    self.pillStopLabel.hidden = YES;
    [self.statusPill addSubview:self.pillStopLabel];

    UITapGestureRecognizer *pillTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleStatusPillTapped)];
    [self.statusPill addGestureRecognizer:pillTap];

    self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    UIImage *closeImage = [UIImage systemImageNamed:@"xmark.circle.fill"];
    [self.closeButton setImage:closeImage forState:UIControlStateNormal];
    self.closeButton.tintColor = UIColor.tertiaryLabelColor;
    self.closeButton.accessibilityLabel = @"Close";
    [self.closeButton addTarget:self action:@selector(handleCancel) forControlEvents:UIControlEventTouchUpInside];
    [self.headerView addSubview:self.closeButton];
}

- (void)buildSearchBar {
    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchBar.placeholder = @"Search city, address, or landmark";
    self.searchBar.delegate = self;
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.backgroundImage = [[UIImage alloc] init];
    self.searchBar.backgroundColor = UIColor.clearColor;
    self.searchBar.tintColor = UIColor.systemBlueColor;
    if (@available(iOS 13.0, *)) {
        UITextField *tf = self.searchBar.searchTextField;
        tf.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightMedium];
        tf.backgroundColor = [UIColor.systemGray6Color colorWithAlphaComponent:0.6];
        tf.layer.cornerRadius = 12.0;
        tf.clipsToBounds = YES;
    }
    [self.scrollContentView addSubview:self.searchBar];

    self.searchSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.searchSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchSpinner.hidesWhenStopped = YES;
    [self.scrollContentView addSubview:self.searchSpinner];

    [self buildSearchSuggestions];
}

- (void)buildSearchSuggestions {
    self.suggestionsPanel = [[UIView alloc] init];
    self.suggestionsPanel.translatesAutoresizingMaskIntoConstraints = NO;
    self.suggestionsPanel.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    self.suggestionsPanel.layer.cornerRadius = kLSCornerRadius;
    self.suggestionsPanel.layer.cornerCurve = kCACornerCurveContinuous;
    self.suggestionsPanel.clipsToBounds = YES;
    self.suggestionsPanel.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    self.suggestionsPanel.layer.borderColor = UIColor.separatorColor.CGColor;
    self.suggestionsPanel.layer.shadowColor = UIColor.blackColor.CGColor;
    self.suggestionsPanel.layer.shadowOpacity = 0.12;
    self.suggestionsPanel.layer.shadowRadius = 12.0;
    self.suggestionsPanel.layer.shadowOffset = CGSizeMake(0.0, 6.0);
    self.suggestionsPanel.layer.masksToBounds = NO;
    self.suggestionsPanel.hidden = YES;
    self.suggestionsPanel.alpha = 0.0;
    [self.scrollContentView addSubview:self.suggestionsPanel];

    self.suggestionsTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.suggestionsTableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.suggestionsTableView.dataSource = self;
    self.suggestionsTableView.delegate = self;
    self.suggestionsTableView.separatorInset = UIEdgeInsetsMake(0.0, 16.0, 0.0, 16.0);
    self.suggestionsTableView.rowHeight = kLSSuggestionRowHeight;
    self.suggestionsTableView.backgroundColor = UIColor.clearColor;
    self.suggestionsTableView.sectionHeaderHeight = 0.0;
    self.suggestionsTableView.sectionFooterHeight = 0.0;
    [self.suggestionsTableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"LSSearchSuggestionCell"];
    [self.suggestionsPanel addSubview:self.suggestionsTableView];
}

- (void)configureSearchCompleter {
    self.searchCompletions = @[];
    self.searchCompleter = [[MKLocalSearchCompleter alloc] init];
    self.searchCompleter.delegate = self;
    if (@available(iOS 13.0, *)) {
        self.searchCompleter.resultTypes = MKLocalSearchCompleterResultTypeAddress | MKLocalSearchCompleterResultTypeQuery;
    }
}

- (void)buildMapSection {
    self.mapContainer = [[UIView alloc] init];
    self.mapContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.mapContainer.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    self.mapContainer.layer.cornerRadius = kLSCornerRadius;
    self.mapContainer.layer.cornerCurve = kCACornerCurveContinuous;
    self.mapContainer.clipsToBounds = YES;
    self.mapContainer.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    self.mapContainer.layer.borderColor = UIColor.separatorColor.CGColor;
    [self.scrollContentView addSubview:self.mapContainer];

    self.mapView = [[MKMapView alloc] initWithFrame:CGRectZero];
    self.mapView.translatesAutoresizingMaskIntoConstraints = NO;
    self.mapView.delegate = self;
    self.mapView.showsUserLocation = ![[PersistenceManager shared] isSpoofingEnabled];
    self.mapView.showsCompass = YES;
    self.mapView.showsScale = YES;
    self.mapView.layoutMargins = UIEdgeInsetsMake(12.0, 12.0, 12.0, 12.0);
    [self.mapContainer addSubview:self.mapView];

    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleMapTap:)];
    UILongPressGestureRecognizer *longPressGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleMapLongPress:)];
    longPressGesture.minimumPressDuration = 0.25;
    [tapGesture requireGestureRecognizerToFail:longPressGesture];
    [self.mapView addGestureRecognizer:tapGesture];
    [self.mapView addGestureRecognizer:longPressGesture];

    self.mapHintLabel = [[UILabel alloc] init];
    self.mapHintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.mapHintLabel.text = @"  Tap map or drag pin  ";
    self.mapHintLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
    self.mapHintLabel.textColor = UIColor.labelColor;
    self.mapHintLabel.backgroundColor = [UIColor.secondarySystemBackgroundColor colorWithAlphaComponent:0.92];
    self.mapHintLabel.layer.cornerRadius = 12.0;
    self.mapHintLabel.layer.cornerCurve = kCACornerCurveContinuous;
    self.mapHintLabel.clipsToBounds = YES;
    self.mapHintLabel.textAlignment = NSTextAlignmentCenter;
    [self.mapContainer addSubview:self.mapHintLabel];

    self.mapSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.mapSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.mapSpinner.hidesWhenStopped = YES;
    self.mapSpinner.color = UIColor.systemGrayColor;
    [self.mapContainer addSubview:self.mapSpinner];
}

- (void)buildControlPanel {
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
    self.controlPanel = [[UIVisualEffectView alloc] initWithEffect:blur];
    self.controlPanel.translatesAutoresizingMaskIntoConstraints = NO;
    self.controlPanel.layer.cornerRadius = kLSControlPanelCornerRadius;
    self.controlPanel.layer.cornerCurve = kCACornerCurveContinuous;
    self.controlPanel.clipsToBounds = YES;
    self.controlPanel.layer.shadowColor = UIColor.blackColor.CGColor;
    self.controlPanel.layer.shadowOpacity = 0.12;
    self.controlPanel.layer.shadowRadius = 16.0;
    self.controlPanel.layer.shadowOffset = CGSizeMake(0.0, -2.0);
    self.controlPanel.layer.masksToBounds = NO;
    [self.scrollContentView addSubview:self.controlPanel];

    UIView *content = self.controlPanel.contentView;

    self.panelTabSegment = [[UISegmentedControl alloc] initWithItems:@[@"Map", @"Bookmarks"]];
    self.panelTabSegment.translatesAutoresizingMaskIntoConstraints = NO;
    self.panelTabSegment.selectedSegmentIndex = LSMapPickerPanelTabMap;
    [self.panelTabSegment addTarget:self action:@selector(handlePanelTabChanged:) forControlEvents:UIControlEventValueChanged];
    [content addSubview:self.panelTabSegment];

    self.mapControlsContainer = [[UIView alloc] init];
    self.mapControlsContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:self.mapControlsContainer];

    self.staticControlsContainer = [[UIView alloc] init];
    self.staticControlsContainer.translatesAutoresizingMaskIntoConstraints = NO;

    self.routeControlsContainer = [[UIView alloc] init];
    self.routeControlsContainer.translatesAutoresizingMaskIntoConstraints = NO;

    self.mapControlsStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.staticControlsContainer, self.routeControlsContainer]];
    self.mapControlsStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.mapControlsStack.axis = UILayoutConstraintAxisVertical;
    self.mapControlsStack.spacing = 12.0;

    self.coordinateModeSegment = [[UISegmentedControl alloc] initWithItems:@[@"Static", @"Route"]];
    self.coordinateModeSegment.translatesAutoresizingMaskIntoConstraints = NO;
    self.coordinateModeSegment.selectedSegmentIndex = LSMapPickerCoordinateModeStatic;
    [self.coordinateModeSegment addTarget:self action:@selector(handleCoordinateModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.mapControlsContainer addSubview:self.coordinateModeSegment];
    [self.mapControlsContainer addSubview:self.mapControlsStack];

    UIView *staticPanel = self.staticControlsContainer;

    self.coordinateTitleLabel = [[UILabel alloc] init];
    self.coordinateTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.coordinateTitleLabel.text = @"Selected coordinates";
    self.coordinateTitleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    self.coordinateTitleLabel.textColor = UIColor.secondaryLabelColor;
    [staticPanel addSubview:self.coordinateTitleLabel];

    self.coordinateValueLabel = [[UILabel alloc] init];
    self.coordinateValueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.coordinateValueLabel.font = [UIFont monospacedDigitSystemFontOfSize:15.0 weight:UIFontWeightMedium];
    self.coordinateValueLabel.textColor = UIColor.labelColor;
    self.coordinateValueLabel.numberOfLines = 2;
    self.coordinateValueLabel.adjustsFontSizeToFitWidth = YES;
    self.coordinateValueLabel.minimumScaleFactor = 0.85;
    [staticPanel addSubview:self.coordinateValueLabel];

    self.bookmarkSaveButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.bookmarkSaveButton.translatesAutoresizingMaskIntoConstraints = NO;
    UIImage *bookmarkImage = [UIImage systemImageNamed:@"bookmark"];
    if (!bookmarkImage) {
        [self.bookmarkSaveButton setTitle:@"★" forState:UIControlStateNormal];
    } else {
        [self.bookmarkSaveButton setImage:bookmarkImage forState:UIControlStateNormal];
    }
    self.bookmarkSaveButton.accessibilityLabel = @"Save bookmark";
    [self.bookmarkSaveButton addTarget:self action:@selector(handleBookmarkSaveTapped) forControlEvents:UIControlEventTouchUpInside];
    [staticPanel addSubview:self.bookmarkSaveButton];

    self.separatorCoordFields = [self ls_separatorView];
    [staticPanel addSubview:self.separatorCoordFields];

    UITextField *latitudeInput = nil;
    UITextField *longitudeInput = nil;
    UIView *latitudeContainer = [self coordinateFieldWithTitle:@"Latitude"
                                                   placeholder:@"37.774900"
                                                     textField:&latitudeInput];
    UIView *longitudeContainer = [self coordinateFieldWithTitle:@"Longitude"
                                                    placeholder:@"-122.419400"
                                                      textField:&longitudeInput];
    self.latitudeField = latitudeInput;
    self.longitudeField = longitudeInput;

    UITextField *altitudeInput = nil;
    UIView *altitudeContainer = [self coordinateFieldWithTitle:@"Alt (m)" placeholder:@"0" textField:&altitudeInput];
    self.altitudeField = altitudeInput;

    self.fieldStack = [[UIStackView alloc] initWithArrangedSubviews:@[latitudeContainer, longitudeContainer, altitudeContainer]];
    self.fieldStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.fieldStack.axis = UILayoutConstraintAxisHorizontal;
    self.fieldStack.spacing = 8.0;
    self.fieldStack.distribution = UIStackViewDistributionFillEqually;
    [staticPanel addSubview:self.fieldStack];

    self.separatorFieldsHeading = [self ls_separatorView];
    [staticPanel addSubview:self.separatorFieldsHeading];

    self.headingValueLabel = [[UILabel alloc] init];
    self.headingValueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.headingValueLabel.font = [UIFont monospacedDigitSystemFontOfSize:14.0 weight:UIFontWeightMedium];
    self.headingValueLabel.textColor = UIColor.secondaryLabelColor;
    [staticPanel addSubview:self.headingValueLabel];

    self.headingSlider = [[UISlider alloc] init];
    self.headingSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.headingSlider.minimumValue = 0.0f;
    self.headingSlider.maximumValue = 359.0f;
    self.headingSlider.tintColor = UIColor.systemBlueColor;
    [self.headingSlider addTarget:self action:@selector(handleHeadingSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [staticPanel addSubview:self.headingSlider];

    self.headingDirectionLabel = [[UILabel alloc] init];
    self.headingDirectionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.headingDirectionLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightRegular];
    self.headingDirectionLabel.textColor = UIColor.tertiaryLabelColor;
    self.headingDirectionLabel.textAlignment = NSTextAlignmentCenter;
    [staticPanel addSubview:self.headingDirectionLabel];

    self.separatorHeadingActions = [self ls_separatorView];
    [staticPanel addSubview:self.separatorHeadingActions];

    self.separatorFluctuation = [self ls_separatorView];
    [staticPanel addSubview:self.separatorFluctuation];

    self.fluctuationRow = [[UIView alloc] init];
    self.fluctuationRow.translatesAutoresizingMaskIntoConstraints = NO;
    [staticPanel addSubview:self.fluctuationRow];

    self.fluctuationLabel = [[UILabel alloc] init];
    self.fluctuationLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.fluctuationLabel.text = @"Fluctuation";
    self.fluctuationLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    self.fluctuationLabel.textColor = UIColor.labelColor;
    [self.fluctuationRow addSubview:self.fluctuationLabel];

    self.fluctuationSwitch = [[UISwitch alloc] init];
    self.fluctuationSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    [self.fluctuationSwitch addTarget:self action:@selector(handleFluctuationToggle) forControlEvents:UIControlEventValueChanged];
    [self.fluctuationRow addSubview:self.fluctuationSwitch];

    self.fluctuationRadiusField = [[UITextField alloc] init];
    self.fluctuationRadiusField.translatesAutoresizingMaskIntoConstraints = NO;
    self.fluctuationRadiusField.placeholder = @"Radius (m)";
    self.fluctuationRadiusField.keyboardType = UIKeyboardTypeNumberPad;
    self.fluctuationRadiusField.font = [UIFont monospacedDigitSystemFontOfSize:14.0 weight:UIFontWeightMedium];
    self.fluctuationRadiusField.textColor = UIColor.labelColor;
    self.fluctuationRadiusField.textAlignment = NSTextAlignmentCenter;
    self.fluctuationRadiusField.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    self.fluctuationRadiusField.layer.cornerRadius = 10.0;
    self.fluctuationRadiusField.layer.cornerCurve = kCACornerCurveContinuous;
    self.fluctuationRadiusField.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    self.fluctuationRadiusField.layer.borderColor = UIColor.separatorColor.CGColor;
    self.fluctuationRadiusField.delegate = self;
    [self.fluctuationRadiusField addTarget:self action:@selector(handleFluctuationRadiusChanged) forControlEvents:UIControlEventEditingDidEnd];
    [staticPanel addSubview:self.fluctuationRadiusField];

    UIToolbar *fluctuationToolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 0, 44)];
    UIBarButtonItem *flexItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *doneItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(dismissKeyboard)];
    fluctuationToolbar.items = @[flexItem, doneItem];
    self.fluctuationRadiusField.inputAccessoryView = fluctuationToolbar;

    self.applyButton = [self primaryButtonWithTitle:@"Apply Location" action:@selector(handleApply)];
    self.cancelButton = [self secondaryButtonWithTitle:@"Cancel" action:@selector(handleCancel)];
    self.stopButton = [self destructiveOutlineButtonWithTitle:@"Stop Spoofing" action:@selector(handleStopSpoofing)];

    UIStackView *actionRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.cancelButton, self.applyButton]];
    actionRow.translatesAutoresizingMaskIntoConstraints = NO;
    actionRow.axis = UILayoutConstraintAxisHorizontal;
    actionRow.spacing = 12.0;
    actionRow.distribution = UIStackViewDistributionFillEqually;
    [staticPanel addSubview:actionRow];

    self.actionRow = actionRow;
    [staticPanel addSubview:self.stopButton];
}

- (void)installConstraints {
    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    UIView *panelContent = self.controlPanel.contentView;

    [NSLayoutConstraint activateConstraints:@[
        [self.contentScrollView.topAnchor constraintEqualToAnchor:safeArea.topAnchor],
        [self.contentScrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.contentScrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.contentScrollView.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor],

        [self.scrollContentView.topAnchor constraintEqualToAnchor:self.contentScrollView.contentLayoutGuide.topAnchor],
        [self.scrollContentView.leadingAnchor constraintEqualToAnchor:self.contentScrollView.contentLayoutGuide.leadingAnchor],
        [self.scrollContentView.trailingAnchor constraintEqualToAnchor:self.contentScrollView.contentLayoutGuide.trailingAnchor],
        [self.scrollContentView.bottomAnchor constraintEqualToAnchor:self.contentScrollView.contentLayoutGuide.bottomAnchor],
        [self.scrollContentView.widthAnchor constraintEqualToAnchor:self.contentScrollView.frameLayoutGuide.widthAnchor],

        [self.headerView.topAnchor constraintEqualToAnchor:self.scrollContentView.topAnchor constant:8.0],
        [self.headerView.leadingAnchor constraintEqualToAnchor:self.scrollContentView.leadingAnchor constant:kLSHorizontalInset],
        [self.headerView.trailingAnchor constraintEqualToAnchor:self.scrollContentView.trailingAnchor constant:-kLSHorizontalInset],

        [self.titleLabel.topAnchor constraintEqualToAnchor:self.headerView.topAnchor],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.headerView.leadingAnchor],
        [self.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.closeButton.leadingAnchor constant:-12.0],

        [self.closeButton.centerYAnchor constraintEqualToAnchor:self.titleLabel.centerYAnchor],
        [self.closeButton.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor],
        [self.closeButton.widthAnchor constraintEqualToConstant:32.0],
        [self.closeButton.heightAnchor constraintEqualToConstant:32.0],

        [self.subtitleLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:4.0],
        [self.subtitleLabel.leadingAnchor constraintEqualToAnchor:self.headerView.leadingAnchor],
        [self.subtitleLabel.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor],

        [self.statusPill.topAnchor constraintEqualToAnchor:self.subtitleLabel.bottomAnchor constant:12.0],
        [self.statusPill.leadingAnchor constraintEqualToAnchor:self.headerView.leadingAnchor],
        [self.statusPill.bottomAnchor constraintEqualToAnchor:self.headerView.bottomAnchor],

        [self.statusDot.leadingAnchor constraintEqualToAnchor:self.statusPill.leadingAnchor constant:10.0],
        [self.statusDot.centerYAnchor constraintEqualToAnchor:self.statusPill.centerYAnchor],
        [self.statusDot.widthAnchor constraintEqualToConstant:10.0],
        [self.statusDot.heightAnchor constraintEqualToConstant:10.0],

        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.statusDot.trailingAnchor constant:8.0],
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.statusPill.topAnchor constant:6.0],
        [self.statusLabel.bottomAnchor constraintEqualToAnchor:self.statusPill.bottomAnchor constant:-6.0],

        [self.pillStopLabel.leadingAnchor constraintEqualToAnchor:self.statusLabel.trailingAnchor constant:6.0],
        [self.pillStopLabel.centerYAnchor constraintEqualToAnchor:self.statusPill.centerYAnchor],
        [self.pillStopLabel.trailingAnchor constraintEqualToAnchor:self.statusPill.trailingAnchor constant:-12.0],

        [self.searchBar.topAnchor constraintEqualToAnchor:self.headerView.bottomAnchor constant:16.0],
        [self.searchBar.leadingAnchor constraintEqualToAnchor:self.scrollContentView.leadingAnchor constant:kLSHorizontalInset],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:self.searchSpinner.leadingAnchor constant:-4.0],
        [self.searchBar.heightAnchor constraintEqualToConstant:52.0],

        [self.searchSpinner.centerYAnchor constraintEqualToAnchor:self.searchBar.centerYAnchor],
        [self.searchSpinner.trailingAnchor constraintEqualToAnchor:self.scrollContentView.trailingAnchor constant:-kLSHorizontalInset],

        [self.suggestionsPanel.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:2.0],
        [self.suggestionsPanel.leadingAnchor constraintEqualToAnchor:self.searchBar.leadingAnchor],
        [self.suggestionsPanel.trailingAnchor constraintEqualToAnchor:self.searchBar.trailingAnchor],

        [self.suggestionsTableView.topAnchor constraintEqualToAnchor:self.suggestionsPanel.topAnchor],
        [self.suggestionsTableView.leadingAnchor constraintEqualToAnchor:self.suggestionsPanel.leadingAnchor],
        [self.suggestionsTableView.trailingAnchor constraintEqualToAnchor:self.suggestionsPanel.trailingAnchor],
        [self.suggestionsTableView.bottomAnchor constraintEqualToAnchor:self.suggestionsPanel.bottomAnchor],

        [self.mapContainer.topAnchor constraintEqualToAnchor:self.suggestionsPanel.bottomAnchor constant:10.0],
        [self.mapContainer.leadingAnchor constraintEqualToAnchor:self.scrollContentView.leadingAnchor constant:kLSHorizontalInset],
        [self.mapContainer.trailingAnchor constraintEqualToAnchor:self.scrollContentView.trailingAnchor constant:-kLSHorizontalInset],

        [self.mapView.topAnchor constraintEqualToAnchor:self.mapContainer.topAnchor],
        [self.mapView.leadingAnchor constraintEqualToAnchor:self.mapContainer.leadingAnchor],
        [self.mapView.trailingAnchor constraintEqualToAnchor:self.mapContainer.trailingAnchor],
        [self.mapView.bottomAnchor constraintEqualToAnchor:self.mapContainer.bottomAnchor],

        [self.mapHintLabel.bottomAnchor constraintEqualToAnchor:self.mapContainer.bottomAnchor constant:-12.0],
        [self.mapHintLabel.centerXAnchor constraintEqualToAnchor:self.mapContainer.centerXAnchor],

        [self.mapSpinner.centerXAnchor constraintEqualToAnchor:self.mapContainer.centerXAnchor],
        [self.mapSpinner.centerYAnchor constraintEqualToAnchor:self.mapContainer.centerYAnchor],

        [self.controlPanel.topAnchor constraintEqualToAnchor:self.mapContainer.bottomAnchor constant:16.0],
        [self.controlPanel.leadingAnchor constraintEqualToAnchor:self.scrollContentView.leadingAnchor constant:kLSHorizontalInset],
        [self.controlPanel.trailingAnchor constraintEqualToAnchor:self.scrollContentView.trailingAnchor constant:-kLSHorizontalInset],
        [self.controlPanel.bottomAnchor constraintEqualToAnchor:self.scrollContentView.bottomAnchor constant:-8.0],

        [self.panelTabSegment.topAnchor constraintEqualToAnchor:panelContent.topAnchor constant:14.0],
        [self.panelTabSegment.leadingAnchor constraintEqualToAnchor:panelContent.leadingAnchor constant:12.0],
        [self.panelTabSegment.trailingAnchor constraintEqualToAnchor:panelContent.trailingAnchor constant:-12.0],

        [self.mapControlsContainer.topAnchor constraintEqualToAnchor:self.panelTabSegment.bottomAnchor constant:10.0],
        [self.mapControlsContainer.leadingAnchor constraintEqualToAnchor:panelContent.leadingAnchor constant:12.0],
        [self.mapControlsContainer.trailingAnchor constraintEqualToAnchor:panelContent.trailingAnchor constant:-12.0],
        [self.mapControlsContainer.bottomAnchor constraintEqualToAnchor:panelContent.bottomAnchor constant:-12.0],

        [self.bookmarksContainer.topAnchor constraintEqualToAnchor:self.panelTabSegment.bottomAnchor constant:6.0],
        [self.bookmarksContainer.leadingAnchor constraintEqualToAnchor:panelContent.leadingAnchor],
        [self.bookmarksContainer.trailingAnchor constraintEqualToAnchor:panelContent.trailingAnchor],
        [self.bookmarksContainer.bottomAnchor constraintEqualToAnchor:panelContent.bottomAnchor constant:-8.0],

        [self.coordinateModeSegment.topAnchor constraintEqualToAnchor:self.mapControlsContainer.topAnchor],
        [self.coordinateModeSegment.leadingAnchor constraintEqualToAnchor:self.mapControlsContainer.leadingAnchor constant:12.0],
        [self.coordinateModeSegment.trailingAnchor constraintEqualToAnchor:self.mapControlsContainer.trailingAnchor constant:-12.0],

        [self.mapControlsStack.topAnchor constraintEqualToAnchor:self.coordinateModeSegment.bottomAnchor constant:12.0],
        [self.mapControlsStack.leadingAnchor constraintEqualToAnchor:self.mapControlsContainer.leadingAnchor constant:12.0],
        [self.mapControlsStack.trailingAnchor constraintEqualToAnchor:self.mapControlsContainer.trailingAnchor constant:-12.0],
        [self.mapControlsStack.bottomAnchor constraintEqualToAnchor:self.mapControlsContainer.bottomAnchor constant:-12.0],

        [self.coordinateTitleLabel.topAnchor constraintEqualToAnchor:self.staticControlsContainer.topAnchor],
        [self.coordinateTitleLabel.leadingAnchor constraintEqualToAnchor:self.staticControlsContainer.leadingAnchor],

        [self.bookmarkSaveButton.centerYAnchor constraintEqualToAnchor:self.coordinateTitleLabel.centerYAnchor],
        [self.bookmarkSaveButton.trailingAnchor constraintEqualToAnchor:self.staticControlsContainer.trailingAnchor],
        [self.bookmarkSaveButton.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.coordinateTitleLabel.trailingAnchor constant:8.0],

        [self.coordinateValueLabel.topAnchor constraintEqualToAnchor:self.coordinateTitleLabel.bottomAnchor constant:4.0],
        [self.coordinateValueLabel.leadingAnchor constraintEqualToAnchor:self.staticControlsContainer.leadingAnchor],
        [self.coordinateValueLabel.trailingAnchor constraintEqualToAnchor:self.staticControlsContainer.trailingAnchor],

        [self.separatorCoordFields.topAnchor constraintEqualToAnchor:self.coordinateValueLabel.bottomAnchor constant:8.0],
        [self.separatorCoordFields.leadingAnchor constraintEqualToAnchor:self.staticControlsContainer.leadingAnchor],
        [self.separatorCoordFields.trailingAnchor constraintEqualToAnchor:self.staticControlsContainer.trailingAnchor],

        [self.fieldStack.topAnchor constraintEqualToAnchor:self.separatorCoordFields.bottomAnchor constant:6.0],
        [self.fieldStack.leadingAnchor constraintEqualToAnchor:self.staticControlsContainer.leadingAnchor],
        [self.fieldStack.trailingAnchor constraintEqualToAnchor:self.staticControlsContainer.trailingAnchor],

        [self.separatorFieldsHeading.topAnchor constraintEqualToAnchor:self.fieldStack.bottomAnchor constant:8.0],
        [self.separatorFieldsHeading.leadingAnchor constraintEqualToAnchor:self.staticControlsContainer.leadingAnchor],
        [self.separatorFieldsHeading.trailingAnchor constraintEqualToAnchor:self.staticControlsContainer.trailingAnchor],

        [self.headingValueLabel.topAnchor constraintEqualToAnchor:self.separatorFieldsHeading.bottomAnchor constant:6.0],
        [self.headingValueLabel.leadingAnchor constraintEqualToAnchor:self.staticControlsContainer.leadingAnchor],

        [self.headingSlider.centerYAnchor constraintEqualToAnchor:self.headingValueLabel.centerYAnchor],
        [self.headingSlider.leadingAnchor constraintEqualToAnchor:self.headingValueLabel.trailingAnchor constant:12.0],
        [self.headingSlider.trailingAnchor constraintEqualToAnchor:self.staticControlsContainer.trailingAnchor],

        [self.headingDirectionLabel.topAnchor constraintEqualToAnchor:self.headingSlider.bottomAnchor constant:2.0],
        [self.headingDirectionLabel.centerXAnchor constraintEqualToAnchor:self.headingSlider.centerXAnchor],

        [self.separatorHeadingActions.topAnchor constraintEqualToAnchor:self.headingDirectionLabel.bottomAnchor constant:8.0],
        [self.separatorHeadingActions.leadingAnchor constraintEqualToAnchor:self.staticControlsContainer.leadingAnchor],
        [self.separatorHeadingActions.trailingAnchor constraintEqualToAnchor:self.staticControlsContainer.trailingAnchor],

        [self.separatorFluctuation.topAnchor constraintEqualToAnchor:self.separatorHeadingActions.bottomAnchor constant:8.0],
        [self.separatorFluctuation.leadingAnchor constraintEqualToAnchor:self.staticControlsContainer.leadingAnchor],
        [self.separatorFluctuation.trailingAnchor constraintEqualToAnchor:self.staticControlsContainer.trailingAnchor],

        [self.fluctuationRow.topAnchor constraintEqualToAnchor:self.separatorFluctuation.bottomAnchor constant:8.0],
        [self.fluctuationRow.leadingAnchor constraintEqualToAnchor:self.staticControlsContainer.leadingAnchor],
        [self.fluctuationRow.trailingAnchor constraintEqualToAnchor:self.staticControlsContainer.trailingAnchor],

        [self.fluctuationLabel.leadingAnchor constraintEqualToAnchor:self.fluctuationRow.leadingAnchor],
        [self.fluctuationLabel.centerYAnchor constraintEqualToAnchor:self.fluctuationRow.centerYAnchor],

        [self.fluctuationSwitch.trailingAnchor constraintEqualToAnchor:self.fluctuationRow.trailingAnchor],
        [self.fluctuationSwitch.centerYAnchor constraintEqualToAnchor:self.fluctuationRow.centerYAnchor],

        [self.fluctuationSwitch.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.fluctuationLabel.trailingAnchor constant:12.0],

        [self.fluctuationRow.heightAnchor constraintEqualToConstant:40.0],

        (self.fluctuationRadiusTopConstraint = [self.fluctuationRadiusField.topAnchor constraintEqualToAnchor:self.fluctuationRow.bottomAnchor constant:6.0]),
        [self.fluctuationRadiusField.leadingAnchor constraintEqualToAnchor:self.staticControlsContainer.leadingAnchor],
        [self.fluctuationRadiusField.trailingAnchor constraintEqualToAnchor:self.staticControlsContainer.trailingAnchor],
        (self.fluctuationRadiusHeightConstraint = [self.fluctuationRadiusField.heightAnchor constraintEqualToConstant:40.0]),

        [self.cancelButton.heightAnchor constraintEqualToConstant:50.0],
        [self.applyButton.heightAnchor constraintEqualToConstant:50.0],

        [self.actionRow.topAnchor constraintEqualToAnchor:self.fluctuationRadiusField.bottomAnchor constant:12.0],
        [self.actionRow.leadingAnchor constraintEqualToAnchor:self.staticControlsContainer.leadingAnchor],
        [self.actionRow.trailingAnchor constraintEqualToAnchor:self.staticControlsContainer.trailingAnchor],

        [self.stopButton.topAnchor constraintEqualToAnchor:self.actionRow.bottomAnchor constant:10.0],
        [self.stopButton.leadingAnchor constraintEqualToAnchor:self.staticControlsContainer.leadingAnchor],
        [self.stopButton.trailingAnchor constraintEqualToAnchor:self.staticControlsContainer.trailingAnchor]
    ]];

    [self ls_installRouteConstraintsInRoutePanel];

    self.mapControlsBottomStaticConstraint = [self.stopButton.bottomAnchor constraintEqualToAnchor:self.staticControlsContainer.bottomAnchor constant:-12.0];
    self.mapControlsBottomStaticNoStopConstraint = [self.actionRow.bottomAnchor constraintEqualToAnchor:self.staticControlsContainer.bottomAnchor constant:-12.0];
    self.mapControlsBottomRouteConstraint = [self.routeActionRow.bottomAnchor constraintEqualToAnchor:self.routeControlsContainer.bottomAnchor constant:-12.0];
    self.mapControlsBottomRouteEarlyConstraint = [self.getRouteButton.bottomAnchor constraintEqualToAnchor:self.routeControlsContainer.bottomAnchor constant:-12.0];
    self.mapControlsBottomStaticConstraint.active = YES;

    self.stopButtonHeightConstraint = [self.stopButton.heightAnchor constraintEqualToConstant:50.0];
    self.stopButtonHeightConstraint.active = YES;

    self.suggestionsHeightConstraint = [self.suggestionsPanel.heightAnchor constraintEqualToConstant:0.0];
    self.suggestionsHeightConstraint.active = YES;

    self.mapHeightConstraint = [self.mapContainer.heightAnchor constraintEqualToAnchor:self.view.heightAnchor multiplier:kLSMapHeightMultiplier];
    self.mapHeightConstraint.active = YES;

    [self.controlPanel.heightAnchor constraintGreaterThanOrEqualToConstant:180.0].active = YES;
}

#pragma mark - Controls

- (UIView *)ls_separatorView {
    UIView *line = [[UIView alloc] init];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    line.backgroundColor = UIColor.separatorColor;
    [NSLayoutConstraint activateConstraints:@[
        [line.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale]
    ]];
    return line;
}

- (UIView *)coordinateFieldWithTitle:(NSString *)title placeholder:(NSString *)placeholder textField:(UITextField * __strong *)textFieldOut {
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    container.layer.cornerRadius = 10.0;
    container.layer.cornerCurve = kCACornerCurveContinuous;
    container.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    container.layer.borderColor = UIColor.separatorColor.CGColor;

    UILabel *caption = [[UILabel alloc] init];
    caption.translatesAutoresizingMaskIntoConstraints = NO;
    caption.text = title;
    caption.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
    caption.textColor = UIColor.secondaryLabelColor;
    [container addSubview:caption];

    UITextField *field = [[UITextField alloc] init];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.placeholder = placeholder;
    field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.font = [UIFont monospacedDigitSystemFontOfSize:14.0 weight:UIFontWeightMedium];
    field.textColor = UIColor.labelColor;
    field.delegate = self;
    [field addTarget:self action:@selector(textFieldDidChange:) forControlEvents:UIControlEventEditingChanged];
    [container addSubview:field];

    if (textFieldOut) {
        *textFieldOut = field;
    }

    [NSLayoutConstraint activateConstraints:@[
        [caption.topAnchor constraintEqualToAnchor:container.topAnchor constant:4.0],
        [caption.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:10.0],
        [caption.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-10.0],

        [field.topAnchor constraintEqualToAnchor:caption.bottomAnchor constant:1.0],
        [field.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:10.0],
        [field.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-10.0],
        [field.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-6.0],
        [container.heightAnchor constraintEqualToConstant:46.0]
    ]];

    return container;
}

- (UIButton *)primaryButtonWithTitle:(NSString *)title action:(SEL)action {
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

- (UIButton *)secondaryButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    button.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    button.layer.cornerRadius = 12.0;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    button.layer.borderColor = UIColor.separatorColor.CGColor;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIButton *)destructiveOutlineButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.translatesAutoresizingMaskIntoConstraints = NO;

    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];

    [button setTitleColor:UIColor.systemRedColor forState:UIControlStateNormal];

    button.backgroundColor = [UIColor.systemRedColor colorWithAlphaComponent:0.12];
    button.layer.cornerRadius = 12.0;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    button.layer.borderColor = UIColor.systemRedColor.CGColor;
    button.clipsToBounds = YES;

    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)configureKeyboardToolbar {
    UIToolbar *toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 0, 44)];
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(dismissKeyboard)];
    toolbar.items = @[flex, done];
    self.latitudeField.inputAccessoryView = toolbar;
    self.longitudeField.inputAccessoryView = toolbar;
    self.altitudeField.inputAccessoryView = toolbar;
    self.customSpeedField.inputAccessoryView = toolbar;
}

- (void)refreshStatusPill {
    LSRouteSimulator *simulator = [LSRouteSimulator shared];
    if (simulator.isSimulating) {
        double kmh = [LSRouteSimulator speedMetersPerSecondForMode:simulator.transportMode customSpeedKmh:simulator.customSpeedKmh] * 3.6;
        self.statusLabel.text = [NSString stringWithFormat:@"Simulating · %.1f km/h", kmh];
        self.statusDot.backgroundColor = UIColor.systemGreenColor;
    } else {
        BOOL active = [[PersistenceManager shared] isSpoofingEnabled];
        self.statusLabel.text = active ? @"Spoofing active" : @"Spoofing inactive";
        self.statusDot.backgroundColor = active ? UIColor.systemGreenColor : UIColor.systemOrangeColor;
    }

    BOOL active = [[PersistenceManager shared] isSpoofingEnabled] || simulator.isSimulating;
    self.pillStopLabel.hidden = !active;
    self.statusPill.backgroundColor = active ? [UIColor.systemRedColor colorWithAlphaComponent:0.12] : [UIColor.tertiarySystemFillColor colorWithAlphaComponent:0.9];
    BOOL showStop = active && self.coordinateMode == LSMapPickerCoordinateModeStatic && self.panelTab == LSMapPickerPanelTabMap;
    self.stopButton.hidden = !showStop;
    self.stopButtonHeightConstraint.constant = showStop ? 50.0 : 0.0;
    [self ls_updateMapControlsBottomConstraint];

    self.mapView.showsUserLocation = ![[PersistenceManager shared] isSpoofingEnabled];
}

#pragma mark - Keyboard

- (void)ls_keyboardWillShow:(NSNotification *)note {
    CGRect kbFrame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat kbHeight = kbFrame.size.height;
    UIEdgeInsets insets = self.contentScrollView.contentInset;
    insets.bottom = kbHeight;
    self.contentScrollView.contentInset = insets;
    self.contentScrollView.scrollIndicatorInsets = insets;
}

- (void)ls_keyboardWillHide:(NSNotification *)note {
    (void)note;
    UIEdgeInsets insets = self.contentScrollView.contentInset;
    insets.bottom = 0.0;
    self.contentScrollView.contentInset = insets;
    self.contentScrollView.scrollIndicatorInsets = insets;
}

#pragma mark - Map

- (void)configureMapIfNeeded {
    if (self.mapConfigured) {
        return;
    }

    self.mapConfigured = YES;
    [self.mapSpinner startAnimating];

    self.pinAnnotation = [[MKPointAnnotation alloc] init];
    self.pinAnnotation.title = @"Spoofed location";
    self.pinAnnotation.subtitle = @"Drag to adjust";
    self.pinAnnotation.coordinate = self.selectedCoordinate;
    [self.mapView addAnnotation:self.pinAnnotation];

    MKCoordinateRegion region = MKCoordinateRegionMakeWithDistance(self.selectedCoordinate, 1500.0, 1500.0);
    [self.mapView setRegion:region animated:NO];
    [self updateSearchCompleterRegion];
}

- (void)syncFieldsFromCoordinate {
    self.suppressFieldSync = YES;
    self.latitudeField.text = [NSString stringWithFormat:@"%.6f", self.selectedCoordinate.latitude];
    self.longitudeField.text = [NSString stringWithFormat:@"%.6f", self.selectedCoordinate.longitude];
    self.suppressFieldSync = NO;
    [self updateCoordinateLabel];
    [self updatePinOnMapAnimated:NO];
}

- (void)updateCoordinateLabel {
    self.coordinateValueLabel.text = [NSString stringWithFormat:@"%@%.6f\n%@%.6f",
                                      self.selectedCoordinate.latitude >= 0.0 ? @"N " : @"S ",
                                      fabs(self.selectedCoordinate.latitude),
                                      self.selectedCoordinate.longitude >= 0.0 ? @"E " : @"W ",
                                      fabs(self.selectedCoordinate.longitude)];
}

- (void)movePinToCoordinate:(CLLocationCoordinate2D)coordinate animated:(BOOL)animated {
    self.selectedCoordinate = coordinate;
    self.hasSelectedCoordinate = YES;
    self.suppressFieldSync = YES;
    self.latitudeField.text = [NSString stringWithFormat:@"%.6f", coordinate.latitude];
    self.longitudeField.text = [NSString stringWithFormat:@"%.6f", coordinate.longitude];
    self.suppressFieldSync = NO;
    [self updateCoordinateLabel];
    [self updatePinOnMapAnimated:animated];
}

- (void)updatePinOnMapAnimated:(BOOL)animated {
    if (!self.pinAnnotation) {
        return;
    }

    self.pinAnnotation.coordinate = self.selectedCoordinate;

    if (!MKMapRectContainsPoint(self.mapView.visibleMapRect, MKMapPointForCoordinate(self.selectedCoordinate))) {
        MKCoordinateRegion region = MKCoordinateRegionMakeWithDistance(self.selectedCoordinate, 1500.0, 1500.0);
        [self.mapView setRegion:region animated:animated];
    }
}

#pragma mark - Validation & Feedback

- (nullable NSNumber *)ls_parsedCoordinateComponentFromText:(NSString *)text {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) {
        return nil;
    }

    static NSNumberFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSNumberFormatter alloc] init];
        formatter.numberStyle = NSNumberFormatterDecimalStyle;
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });

    NSString *normalized = [trimmed stringByReplacingOccurrencesOfString:@"," withString:@"."];
    return [formatter numberFromString:normalized];
}

- (BOOL)applyFieldsToCoordinate {
    if (self.suppressFieldSync) {
        return YES;
    }

    NSNumber *latitudeNumber = [self ls_parsedCoordinateComponentFromText:self.latitudeField.text];
    NSNumber *longitudeNumber = [self ls_parsedCoordinateComponentFromText:self.longitudeField.text];
    if (!latitudeNumber || !longitudeNumber) {
        [self showInvalidCoordinateFeedback];
        return NO;
    }

    double latitude = latitudeNumber.doubleValue;
    double longitude = longitudeNumber.doubleValue;
    if (latitude < -90.0 || latitude > 90.0 || longitude < -180.0 || longitude > 180.0) {
        [self showInvalidCoordinateFeedback];
        return NO;
    }

    [self movePinToCoordinate:CLLocationCoordinate2DMake(latitude, longitude) animated:YES];
    return YES;
}

- (void)showInvalidCoordinateFeedback {
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback impactOccurred];

    CAKeyframeAnimation *shake = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    shake.values = @[@0, @-8, @8, @-6, @6, @0];
    shake.duration = 0.35;
    [self.fieldStack.layer addAnimation:shake forKey:@"shake"];

    self.coordinateValueLabel.textColor = UIColor.systemRedColor;
    self.coordinateValueLabel.text = @"Enter valid latitude (-90 to 90) and longitude (-180 to 180)";

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf.coordinateValueLabel.textColor = UIColor.labelColor;
        [strongSelf updateCoordinateLabel];
    });
}

- (void)playApplyHaptic {
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback impactOccurred];
}

- (void)playSimulationStopHaptic {
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback impactOccurred];
}

- (void)playRouteSuccessHaptic {
    UINotificationFeedbackGenerator *feedback = [[UINotificationFeedbackGenerator alloc] init];
    [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
}

- (void)playRouteFailureHaptic {
    UINotificationFeedbackGenerator *feedback = [[UINotificationFeedbackGenerator alloc] init];
    [feedback notificationOccurred:UINotificationFeedbackTypeError];
}

- (void)playBookmarkSavedHaptic {
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [feedback impactOccurred];
}

- (BOOL)applyAltitudeField {
    NSNumber *altitudeNumber = [self ls_parsedCoordinateComponentFromText:self.altitudeField.text];
    if (!altitudeNumber) {
        return NO;
    }
    double altitude = altitudeNumber.doubleValue;
    if (altitude < -500.0 || altitude > 10000.0) {
        return NO;
    }
    [PersistenceManager shared].altitude = altitude;
    return YES;
}

- (void)handleHeadingSliderChanged:(UISlider *)sender {
    (void)sender;
    NSInteger heading = (NSInteger)lroundf(self.headingSlider.value);
    [PersistenceManager shared].heading = (CLLocationDirection)heading;
    [self updateHeadingLabel];
}

- (void)syncFluctuationUI {
    PersistenceManager *store = [PersistenceManager shared];
    self.fluctuationSwitch.on = store.fluctuationEnabled;
    self.fluctuationRadiusField.text = [NSString stringWithFormat:@"%.0f", store.fluctuationRadius];
    self.fluctuationRadiusField.hidden = !store.fluctuationEnabled;
    self.fluctuationRadiusHeightConstraint.constant = store.fluctuationEnabled ? 40.0 : 0.0;
    self.fluctuationRadiusTopConstraint.constant = store.fluctuationEnabled ? 6.0 : 0.0;
}

- (void)handleFluctuationToggle {
    PersistenceManager *store = [PersistenceManager shared];
    store.fluctuationEnabled = self.fluctuationSwitch.isOn;
    self.fluctuationRadiusField.hidden = !self.fluctuationSwitch.isOn;
    self.fluctuationRadiusHeightConstraint.constant = self.fluctuationSwitch.isOn ? 40.0 : 0.0;
    self.fluctuationRadiusTopConstraint.constant = self.fluctuationSwitch.isOn ? 6.0 : 0.0;
    [UIView animateWithDuration:0.25 animations:^{
        [self.view layoutIfNeeded];
    }];
    if (self.fluctuationSwitch.isOn) {
        [self.fluctuationRadiusField becomeFirstResponder];
    }
}

- (void)handleFluctuationRadiusChanged {
    NSString *text = [self.fluctuationRadiusField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    double radius = 50.0;
    if (text.length > 0) {
        NSNumber *value = [self ls_parsedCoordinateComponentFromText:text];
        radius = value ? value.doubleValue : 50.0;
    } else {
        radius = [PersistenceManager shared].fluctuationRadius;
    }
    if (radius < 1.0) {
        radius = 1.0;
    } else if (radius > 1000.0) {
        radius = 1000.0;
    }
    [PersistenceManager shared].fluctuationRadius = radius;
    self.fluctuationRadiusField.text = [NSString stringWithFormat:@"%.0f", radius];
}

- (void)updateHeadingLabel {
    NSInteger heading = (NSInteger)lroundf(self.headingSlider.value);
    self.headingValueLabel.text = [NSString stringWithFormat:@"Heading: %03ld°", (long)heading];

    NSArray<NSString *> *directions = @[@"N", @"NE", @"E", @"SE", @"S", @"SW", @"W", @"NW"];
    NSInteger index = (NSInteger)(((double)heading + 22.5) / 45.0) % 8;
    self.headingDirectionLabel.text = directions[index];

    CGFloat hue = (CGFloat)heading / 360.0;
    UIColor *tint = [UIColor colorWithHue:hue saturation:0.6 brightness:0.8 alpha:1.0];
    self.headingSlider.tintColor = tint;
}

#pragma mark - Search Suggestions

- (void)updateSearchCompleterRegion {
    if (self.mapConfigured) {
        self.searchCompleter.region = self.mapView.region;
    }
}

- (void)updateSearchSuggestionsVisibility {
    NSInteger count = self.searchCompletions.count;
    BOOL shouldShow = count > 0 && self.searchBar.isFirstResponder;

    if (shouldShow) {
        NSInteger visibleRows = MIN(count, kLSSuggestionMaxVisibleRows);
        CGFloat targetHeight = MIN(visibleRows * kLSSuggestionRowHeight, kLSSuggestionMaxHeight);
        self.suggestionsHeightConstraint.constant = targetHeight;
        self.suggestionsPanel.hidden = NO;

        if (!self.searchSuggestionsVisible) {
            self.searchSuggestionsVisible = YES;
            self.suggestionsPanel.alpha = 0.0;
            [UIView animateWithDuration:0.18 animations:^{
                self.suggestionsPanel.alpha = 1.0;
                [self.view layoutIfNeeded];
            }];
        } else {
            [self.view layoutIfNeeded];
        }
    } else {
        [self hideSearchSuggestions];
    }
}

- (void)hideSearchSuggestions {
    self.searchSuggestionsVisible = NO;
    self.suggestionsHeightConstraint.constant = 0.0;

    if (!self.suggestionsPanel.hidden) {
        [UIView animateWithDuration:0.15 animations:^{
            self.suggestionsPanel.alpha = 0.0;
            [self.view layoutIfNeeded];
        } completion:^(__unused BOOL finished) {
            self.suggestionsPanel.hidden = YES;
        }];
    }
}

- (void)updateSearchQueryFragment:(NSString *)query {
    NSString *trimmed = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length > 256) {
        return;
    }
    if (trimmed.length == 0) {
        self.searchCompletions = @[];
        self.searchCompleter.queryFragment = @"";
        [self.suggestionsTableView reloadData];
        [self hideSearchSuggestions];
        [self.searchSpinner stopAnimating];
        return;
    }

    [self updateSearchCompleterRegion];
    self.searchCompleter.queryFragment = trimmed;
    [self.searchSpinner startAnimating];
}

- (void)resolveSearchCompletion:(MKLocalSearchCompletion *)completion {
    if (!completion) {
        return;
    }

    [self hideSearchSuggestions];
    [self.searchBar resignFirstResponder];
    self.searchBar.text = completion.title;
    [self.searchSpinner startAnimating];

    MKLocalSearchRequest *request = [[MKLocalSearchRequest alloc] initWithCompletion:completion];
    MKLocalSearch *search = [[MKLocalSearch alloc] initWithRequest:request];
    __weak typeof(self) weakSelf = self;
    [search startWithCompletionHandler:^(MKLocalSearchResponse * _Nullable response, NSError * _Nullable error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [strongSelf.searchSpinner stopAnimating];
            [strongSelf ls_updateApplyButtonEnabled];

            if (error || response.mapItems.count == 0) {
                [strongSelf showSearchFailureMessage];
                return;
            }

            MKMapItem *item = response.mapItems.firstObject;
            [strongSelf movePinToCoordinate:item.placemark.coordinate animated:YES];
        });
    }];
}

- (void)resolveSearchQuery:(NSString *)query {
    NSString *trimmed = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) {
        return;
    }

    [self hideSearchSuggestions];
    [self.searchBar resignFirstResponder];
    [self.searchSpinner startAnimating];

    MKLocalSearchRequest *request = [[MKLocalSearchRequest alloc] init];
    request.naturalLanguageQuery = trimmed;
    [self updateSearchCompleterRegion];
    request.region = self.searchCompleter.region;

    MKLocalSearch *search = [[MKLocalSearch alloc] initWithRequest:request];
    __weak typeof(self) weakSelf = self;
    [search startWithCompletionHandler:^(MKLocalSearchResponse * _Nullable response, NSError * _Nullable error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [strongSelf.searchSpinner stopAnimating];
            [strongSelf ls_updateApplyButtonEnabled];

            if (error || response.mapItems.count == 0) {
                [strongSelf showSearchFailureMessage];
                return;
            }

            MKMapItem *item = response.mapItems.firstObject;
            [strongSelf movePinToCoordinate:item.placemark.coordinate animated:YES];
        });
    }];
}

- (void)showSearchFailureMessage {
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [feedback impactOccurred];
    self.coordinateValueLabel.textColor = UIColor.systemOrangeColor;
    self.coordinateValueLabel.text = @"No results found. Try a different search.";
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf.coordinateValueLabel.textColor = UIColor.labelColor;
        [strongSelf updateCoordinateLabel];
    });
}

#pragma mark - MKLocalSearchCompleterDelegate

- (void)completerDidUpdateResults:(MKLocalSearchCompleter *)completer {
    (void)completer;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.searchCompletions = completer.results ?: @[];
        [self.searchSpinner stopAnimating];
        [self ls_updateApplyButtonEnabled];
        [self.suggestionsTableView reloadData];
        [self updateSearchSuggestionsVisibility];
    });
}

- (void)completer:(MKLocalSearchCompleter *)completer didFailWithError:(NSError *)error {
    (void)completer;
    (void)error;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.searchSpinner stopAnimating];
        [self ls_updateApplyButtonEnabled];
        [self hideSearchSuggestions];
    });
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    if ([self ls_isBookmarksTableView:tableView]) {
        return [self ls_bookmarksNumberOfSections];
    }
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    if ([self ls_isBookmarksTableView:tableView]) {
        return [self ls_bookmarksNumberOfRowsInSection:section];
    }
    return self.searchCompletions.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if ([self ls_isBookmarksTableView:tableView]) {
        return [self ls_bookmarksTitleForHeaderInSection:section];
    }
    return nil;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if ([self ls_isBookmarksTableView:tableView]) {
        return [self ls_bookmarksHeaderForSection:section];
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self ls_isBookmarksTableView:tableView]) {
        return [self ls_bookmarksCellForRowAtIndexPath:indexPath];
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"LSSearchSuggestionCell" forIndexPath:indexPath];
    MKLocalSearchCompletion *completion = self.searchCompletions[indexPath.row];

    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = completion.title;
    content.secondaryText = completion.subtitle;
    content.textProperties.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    content.secondaryTextProperties.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    content.image = [UIImage systemImageNamed:@"mappin.circle.fill"];
    content.imageProperties.tintColor = UIColor.systemBlueColor;
    cell.contentConfiguration = content;
    cell.backgroundColor = UIColor.clearColor;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self ls_isBookmarksTableView:tableView]) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        [self ls_bookmarksDidSelectRowAtIndexPath:indexPath];
        return;
    }

    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= (NSInteger)self.searchCompletions.count) {
        return;
    }

    MKLocalSearchCompletion *completion = self.searchCompletions[indexPath.row];
    [self resolveSearchCompletion:completion];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self ls_isBookmarksTableView:tableView]) {
        return [self ls_bookmarksCanEditRowAtIndexPath:indexPath];
    }
    return NO;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self ls_isBookmarksTableView:tableView] && editingStyle == UITableViewCellEditingStyleDelete) {
        [self ls_bookmarksCommitDeleteAtIndexPath:indexPath];
    }
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self ls_isBookmarksTableView:tableView]) {
        return [self ls_bookmarksCanMoveRowAtIndexPath:indexPath];
    }
    return NO;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath {
    if ([self ls_isBookmarksTableView:tableView]) {
        [self ls_bookmarksMoveFromIndexPath:sourceIndexPath toIndexPath:destinationIndexPath];
    }
}

#pragma mark - UISearchBarDelegate

- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar {
    searchBar.showsCancelButton = YES;
    [self.searchSpinner stopAnimating];
    [self ls_updateApplyButtonEnabled];
    [self updateSearchSuggestionsVisibility];
}

- (void)searchBarTextDidEndEditing:(UISearchBar *)searchBar {
    searchBar.showsCancelButton = NO;
    [self ls_updateApplyButtonEnabled];
    [self hideSearchSuggestions];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    searchBar.showsCancelButton = NO;
    [self hideSearchSuggestions];
    [self.searchSpinner stopAnimating];
    [self ls_updateApplyButtonEnabled];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    (void)searchBar;
    [self updateSearchQueryFragment:searchText];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    if (self.searchCompletions.count > 0) {
        [self resolveSearchCompletion:self.searchCompletions.firstObject];
        return;
    }

    [self resolveSearchQuery:searchBar.text];
}

#pragma mark - Actions

- (void)ls_updateApplyButtonEnabled {
    BOOL searching = [self.searchSpinner isAnimating] || self.searchBar.isFirstResponder;
    self.applyButton.enabled = !searching;
    self.applyButton.alpha = searching ? 0.5 : 1.0;
}

- (void)textFieldDidChange:(UITextField *)textField {
    if (textField == self.customSpeedField) {
        NSNumber *parsed = [self ls_parsedCoordinateComponentFromText:textField.text];
        BOOL valid = parsed && parsed.doubleValue >= 1.0 && parsed.doubleValue <= 500.0;
        textField.layer.borderColor = valid ? UIColor.clearColor.CGColor : UIColor.systemRedColor.CGColor;
        textField.layer.borderWidth = valid ? 0.0 : 1.5;
        textField.layer.cornerRadius = 8.0;
        return;
    }
    [self applyFieldsToCoordinate];
}

- (void)dismissKeyboard {
    [self.view endEditing:YES];
    [self hideSearchSuggestions];
}

- (void)handleMapTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) {
        return;
    }

    [self hideSearchSuggestions];
    [self.searchBar resignFirstResponder];

    CGPoint point = [gesture locationInView:self.mapView];
    CLLocationCoordinate2D coordinate = [self.mapView convertPoint:point toCoordinateFromView:self.mapView];

    if (self.coordinateMode == LSMapPickerCoordinateModeRoute) {
        [self ls_handleRouteMapTap:coordinate];
        return;
    }

    [self movePinToCoordinate:coordinate animated:YES];
}

- (void)handleMapLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) {
        return;
    }

    [self hideSearchSuggestions];
    [self.searchBar resignFirstResponder];

    CGPoint point = [gesture locationInView:self.mapView];
    CLLocationCoordinate2D coordinate = [self.mapView convertPoint:point toCoordinateFromView:self.mapView];

    if (self.coordinateMode == LSMapPickerCoordinateModeStatic) {
        [self ls_presentStaticMapActionSheetAtCoordinate:coordinate];
        return;
    }

    [self ls_handleRouteMapTap:coordinate];
}

- (MKOverlayRenderer *)mapView:(MKMapView *)mapView rendererForOverlay:(id<MKOverlay>)overlay {
    (void)mapView;
    return [self ls_rendererForMapOverlay:overlay];
}

- (void)mapViewDidFinishLoadingMap:(MKMapView *)mapView {
    (void)mapView;
    [self.mapSpinner stopAnimating];
}

- (MKAnnotationView *)mapView:(MKMapView *)mapView viewForAnnotation:(id<MKAnnotation>)annotation {
    MKAnnotationView *routeView = [self ls_viewForRouteAnnotation:annotation];
    if (routeView) {
        return routeView;
    }

    if (annotation != self.pinAnnotation) {
        return nil;
    }

    static NSString * const reuseIdentifier = @"LSSpoofPin";
    MKMarkerAnnotationView *view = (MKMarkerAnnotationView *)[mapView dequeueReusableAnnotationViewWithIdentifier:reuseIdentifier];
    if (!view) {
        view = [[MKMarkerAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:reuseIdentifier];
        view.canShowCallout = YES;
        view.draggable = YES;
        view.markerTintColor = UIColor.systemRedColor;
        view.glyphImage = [UIImage systemImageNamed:@"mappin.and.ellipse"];
        view.displayPriority = MKFeatureDisplayPriorityRequired;
    } else {
        view.annotation = annotation;
    }
    return view;
}

- (void)mapView:(MKMapView *)mapView annotationView:(MKAnnotationView *)view didChangeDragState:(MKAnnotationViewDragState)newState fromOldState:(MKAnnotationViewDragState)oldState {
    (void)mapView;
    (void)oldState;
    if (newState == MKAnnotationViewDragStateEnding || newState == MKAnnotationViewDragStateCanceling) {
        [view setDragState:MKAnnotationViewDragStateNone animated:YES];
        if (view.annotation == self.pinAnnotation) {
            [self movePinToCoordinate:view.annotation.coordinate animated:NO];
        } else {
            [self ls_routeAnnotationDragEnded:view];
        }
    }
}

- (void)handleApply {
    [self dismissKeyboard];
    if ([self.searchSpinner isAnimating]) {
        return;
    }
    if (![self applyFieldsToCoordinate] || ![self applyAltitudeField]) {
        [self showInvalidCoordinateFeedback];
        return;
    }

    PersistenceManager *store = [PersistenceManager shared];

    if (![store setSpoofCoordinate:self.selectedCoordinate enabled:YES]) {
        [self showInvalidCoordinateFeedback];
        return;
    }

    [store recordRecentCoordinate:self.selectedCoordinate name:nil];
    [self playApplyHaptic];
    LSSetHooksBypassed(NO);
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)handleCancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)handleStatusPillTapped {
    LSRouteSimulator *simulator = [LSRouteSimulator shared];
    if (simulator.isSimulating || [[PersistenceManager shared] isSpoofingEnabled]) {
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Stop Spoofing?"
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        __weak typeof(self) weakSelf = self;
        [sheet addAction:[UIAlertAction actionWithTitle:@"Stop" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf handleStopSpoofing];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:sheet animated:YES completion:nil];
    }
}

- (void)handleStopSpoofing {
    [[LSRouteSimulator shared] stop];
    [[PersistenceManager shared] clearSpoof];
    [PersistenceManager shared].simulationWasActive = NO;
    [self playSimulationStopHaptic];
    LSSetHooksBypassed(NO);
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
