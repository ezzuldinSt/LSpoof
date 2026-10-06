#import "LSPlaceSearchController.h"
#import "LSCoordinateEntryController.h"
#import "LSUI.h"
#import "BookmarksManager.h"
#import "PersistenceManager.h"

@interface LSPlaceSearchController () <UISearchBarDelegate, UITableViewDataSource, UITableViewDelegate, MKLocalSearchCompleterDelegate>
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UILabel *message;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIView *feedback;
@property (nonatomic, strong, nullable) MKLocalSearchCompleter *completer;
@property (nonatomic, strong, nullable) MKLocalSearch *search;
@property (nonatomic, strong) NSArray<MKLocalSearchCompletion *> *completions;
@property (nonatomic, strong) NSArray<MKMapItem *> *places;
// Saved places and recents shown before typing, so route endpoints can reuse them.
@property (nonatomic, strong) NSArray<NSDictionary *> *shortcuts;
@property (nonatomic, readonly) BOOL showingShortcuts;
@property (nonatomic) NSUInteger revision;
@property (nonatomic) BOOL closed;
@end
@implementation LSPlaceSearchController
- (instancetype)init {
    self = [super init];
    if (self) { _initialCoordinate = kCLLocationCoordinate2DInvalid; _completions = @[]; _places = @[]; _shortcuts = @[]; }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
    UIBarButtonItem *coordinates = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"number"] style:UIBarButtonItemStylePlain target:self action:@selector(enterCoordinates)];
    coordinates.accessibilityLabel = @"Enter coordinates";
    self.navigationItem.rightBarButtonItem = coordinates;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(backgrounded:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(backgrounded:) name:UISceneWillDeactivateNotification object:nil];
    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.delegate = self;
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.placeholder = @"City, address, or place";
    self.searchBar.searchTextField.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.searchBar.searchTextField.adjustsFontForContentSizeCategory = YES;
    self.searchBar.accessibilityLabel = @"Search places";
    self.message = LSLabel(@"Search for a place, pick a saved one below, or tap # to enter coordinates.", UIFontTextStyleSubheadline);
    self.message.textColor = UIColor.secondaryLabelColor;
    [self.message setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;
    [self.spinner setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *feedback = [[UIStackView alloc] initWithArrangedSubviews:@[self.spinner, self.message]];
    feedback.spacing = 12;
    feedback.alignment = UIStackViewAlignmentCenter;
    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.backgroundColor = UIColor.clearColor;
    self.table.rowHeight = UITableViewAutomaticDimension;
    self.table.estimatedRowHeight = 72;
    self.table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    feedback.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *holder = [[UIView alloc] init];
    holder.preservesSuperviewLayoutMargins = YES;
    [holder addSubview:feedback];
    [NSLayoutConstraint activateConstraints:@[
        [feedback.topAnchor constraintEqualToAnchor:holder.topAnchor constant:6],
        [feedback.bottomAnchor constraintEqualToAnchor:holder.bottomAnchor constant:-2],
        [feedback.leadingAnchor constraintEqualToAnchor:holder.layoutMarginsGuide.leadingAnchor constant:4],
        [feedback.trailingAnchor constraintEqualToAnchor:holder.layoutMarginsGuide.trailingAnchor constant:-4]
    ]];
    self.feedback = holder;
    self.table.tableHeaderView = self.feedback;
    UIView *searchHolder = [[UIView alloc] init];
    searchHolder.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    [searchHolder addSubview:self.searchBar];
    [NSLayoutConstraint activateConstraints:@[
        [self.searchBar.topAnchor constraintEqualToAnchor:searchHolder.topAnchor],
        [self.searchBar.bottomAnchor constraintEqualToAnchor:searchHolder.bottomAnchor],
        [self.searchBar.leadingAnchor constraintEqualToAnchor:searchHolder.leadingAnchor constant:8],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:searchHolder.trailingAnchor constant:-8]
    ]];
    UIStackView *stack = LSStack(@[searchHolder, self.table], 0);
    [self.view addSubview:stack];
    [self loadShortcuts];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:4],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [self.table.heightAnchor constraintGreaterThanOrEqualToConstant:0]
    ]];
    LSAnchorAboveKeyboard(stack, self.view);
}
- (void)loadShortcuts {
    NSMutableArray *shortcuts = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (LSBookmark *place in BookmarksManager.shared.allBookmarks) {
        [shortcuts addObject:@{@"name":place.name, @"lat":@(place.coordinate.latitude), @"lon":@(place.coordinate.longitude), @"saved":@YES}];
        [seen addObject:LSCoordinateText(place.coordinate)];
    }
    for (NSDictionary *entry in PersistenceManager.shared.recentLocations) {
        CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake([entry[@"LSRecentLat"] doubleValue], [entry[@"LSRecentLon"] doubleValue]);
        if ([seen containsObject:LSCoordinateText(coordinate)]) continue;
        [shortcuts addObject:@{@"name":entry[@"LSRecentName"] ?: @"Recent location", @"lat":entry[@"LSRecentLat"], @"lon":entry[@"LSRecentLon"], @"saved":@NO}];
    }
    self.shortcuts = shortcuts;
}
- (BOOL)showingShortcuts { return !self.places.count && !self.completions.count && self.searchBar.text.length == 0 && self.shortcuts.count > 0; }
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    self.closed = NO;
    if (self.searchBar.text.length >= 2 && !self.places.count) [self searchBar:self.searchBar textDidChange:self.searchBar.text];
    [self.searchBar becomeFirstResponder];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // Pushing coordinates, dismissing, or backgrounding invalidates all outstanding work.
    [self invalidateRequests];
}
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; [self layoutFeedback]; }
- (void)layoutFeedback {
    LSSizeTableHeader(self.table, self.feedback);
}
- (void)showSearchMessage:(NSString *)message { self.message.text = message; [self layoutFeedback]; }
- (void)backgrounded:(NSNotification *)note {
    if ([note.object isKindOfClass:UIScene.class] && note.object != self.view.window.windowScene) return;
    [self invalidateRequests];
    [self showSearchMessage:@"Search paused. Edit the search or press Search to try again."];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; [_completer cancel]; [_search cancel]; }
- (void)invalidateRequests {
    self.revision++;
    self.completer.delegate = nil;
    [self.completer cancel];
    self.completer = nil;
    [self.search cancel];
    self.search = nil;
    [self.spinner stopAnimating];
}
- (void)searchBar:(UISearchBar *)bar textDidChange:(NSString *)text {
    (void)bar;
    [self invalidateRequests];
    self.completions = @[];
    self.places = @[];
    [self.table reloadData];
    NSString *query = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    CLLocationCoordinate2D pasted;
    if (LSParseCoordinatePair(query, &pasted)) {
        // A pasted "lat, lon" pair is offered directly instead of being searched as text.
        [self showSearchMessage:[NSString stringWithFormat:@"Use coordinates %@? Tap Search to use them.", LSCoordinateText(pasted)]];
        return;
    }
    if (query.length < 2 || query.length > 256) {
        [self showSearchMessage:query.length ? @"Type at least two characters, or tap # for coordinates." : @"Search for a place, pick a saved one below, or tap # to enter coordinates."];
        return;
    }
    [self showSearchMessage:@"Finding suggestions…"];
    [self.spinner startAnimating];
    NSUInteger revision = self.revision;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self || self.closed || revision != self.revision || !self.view.window) return;
        // One completer per query prevents late results from an older fragment being reused.
        self.completer = [[MKLocalSearchCompleter alloc] init];
        self.completer.delegate = self;
        self.completer.resultTypes = MKLocalSearchCompleterResultTypeAddress | MKLocalSearchCompleterResultTypePointOfInterest;
        self.completer.region = self.searchRegion;
        self.completer.queryFragment = query;
    });
}
- (void)completerDidUpdateResults:(MKLocalSearchCompleter *)completer {
    if (self.closed || completer != self.completer || !self.view.window) return;
    self.completions = completer.results ?: @[];
    [self.spinner stopAnimating];
    [self showSearchMessage:self.completions.count ? @"Choose a place below." : @"No suggestions. Press Search or enter coordinates."];
    [self.table reloadData];
}
- (void)completer:(MKLocalSearchCompleter *)completer didFailWithError:(NSError *)error {
    (void)error;
    if (completer != self.completer || self.closed) return;
    [self.spinner stopAnimating];
    [self showSearchMessage:@"Place search is unavailable. Try Search again, or enter coordinates."];
}
- (void)searchBarSearchButtonClicked:(UISearchBar *)bar {
    NSString *query = [bar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    CLLocationCoordinate2D pasted;
    if (LSParseCoordinatePair(query, &pasted)) { [self choose:pasted name:@"Entered coordinates"]; return; }
    if (!query.length || query.length > 256) return;
    MKLocalSearchRequest *request = [[MKLocalSearchRequest alloc] init];
    request.naturalLanguageQuery = query;
    request.region = self.searchRegion;
    [self resolveRequest:request];
}
- (void)resolveRequest:(MKLocalSearchRequest *)request {
    [self invalidateRequests];
    [self.view endEditing:YES];
    self.completions = @[];
    self.places = @[];
    [self.table reloadData];
    [self showSearchMessage:@"Looking up this place…"];
    [self.spinner startAnimating];
    self.search = [self searchForRequest:request];
    NSUInteger revision = self.revision;
    __weak typeof(self) weakSelf = self;
    [self.search startWithCompletionHandler:^(MKLocalSearchResponse *response, NSError *error) {
        typeof(self) self = weakSelf;
        if (!self || self.closed || revision != self.revision || !self.view.window) return;
        self.search = nil;
        [self.spinner stopAnimating];
        NSMutableArray *valid = [NSMutableArray array];
        for (MKMapItem *item in response.mapItems) if (CLLocationCoordinate2DIsValid(item.placemark.coordinate)) [valid addObject:item];
        self.places = valid;
        [self showSearchMessage:error || !valid.count ? @"No places found. Try another search, or enter coordinates." : @"Choose the location you want."];
        [self.table reloadData];
        LSAnnounce(self.message.text);
    }];
}
- (MKLocalSearch *)searchForRequest:(MKLocalSearchRequest *)request { return [[MKLocalSearch alloc] initWithRequest:request]; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    (void)table; (void)section;
    if (self.showingShortcuts) return self.shortcuts.count;
    return self.places.count ?: self.completions.count;
}
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    (void)table; (void)section;
    if (self.showingShortcuts) return @"Saved and recent";
    if (self.places.count) return @"Places";
    return self.completions.count ? @"Suggestions" : nil;
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:@"Place"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Place"];
    UIListContentConfiguration *content = UIListContentConfiguration.subtitleCellConfiguration;
    content.textProperties.font = LSFont(UIFontTextStyleBody, UIFontWeightSemibold, 30);
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    content.imageToTextPadding = 14;
    content.imageProperties.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightRegular];
    content.imageProperties.tintColor = LSErrorColor();
    content.image = [UIImage systemImageNamed:@"mappin.circle.fill"];
    if (self.showingShortcuts) {
        NSDictionary *shortcut = self.shortcuts[path.row];
        BOOL saved = [shortcut[@"saved"] boolValue];
        content.text = shortcut[@"name"];
        content.secondaryText = LSCoordinateText(CLLocationCoordinate2DMake([shortcut[@"lat"] doubleValue], [shortcut[@"lon"] doubleValue]));
        content.secondaryTextProperties.font = LSMonospacedFont(UIFontTextStyleFootnote);
        content.image = [UIImage systemImageNamed:saved ? @"bookmark.circle.fill" : @"clock.arrow.circlepath"];
        content.imageProperties.tintColor = saved ? LSAccentColor() : UIColor.systemGrayColor;
    } else if (self.places.count) {
        MKMapItem *item = self.places[path.row];
        content.text = item.name ?: @"Selected place";
        content.secondaryText = item.placemark.title ?: LSCoordinateText(item.placemark.coordinate);
    } else {
        MKLocalSearchCompletion *completion = self.completions[path.row];
        content.text = completion.title;
        content.secondaryText = completion.subtitle;
        content.image = [UIImage systemImageNamed:@"magnifyingglass.circle.fill"];
        content.imageProperties.tintColor = UIColor.systemGrayColor;
    }
    content.textProperties.numberOfLines = 0;
    content.secondaryTextProperties.numberOfLines = 0;
    cell.contentConfiguration = content;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:NO];
    if (self.showingShortcuts) {
        NSDictionary *shortcut = self.shortcuts[path.row];
        [self choose:CLLocationCoordinate2DMake([shortcut[@"lat"] doubleValue], [shortcut[@"lon"] doubleValue]) name:shortcut[@"name"]];
    } else if (self.places.count) {
        MKMapItem *item = self.places[path.row];
        [self choose:item.placemark.coordinate name:item.name ?: @"Selected place"];
    } else {
        [self resolveRequest:[[MKLocalSearchRequest alloc] initWithCompletion:self.completions[path.row]]];
    }
}
- (void)enterCoordinates {
    [self invalidateRequests];
    [self.view endEditing:YES];
    LSCoordinateEntryController *entry = [[LSCoordinateEntryController alloc] init];
    entry.initialCoordinate = self.initialCoordinate;
    __weak typeof(self) weakSelf = self;
    entry.didChoose = ^(CLLocationCoordinate2D coordinate) { [weakSelf choose:coordinate name:@"Selected coordinates"]; };
    [self.navigationController pushViewController:entry animated:LSMapAnimationsEnabled()];
}
- (void)choose:(CLLocationCoordinate2D)coordinate name:(NSString *)name {
    if (self.closed || !CLLocationCoordinate2DIsValid(coordinate)) return;
    self.closed = YES;
    [self invalidateRequests];
    if (self.didChoose) self.didChoose(coordinate, name);
    [self dismissViewControllerAnimated:LSMapAnimationsEnabled() completion:nil];
}
- (void)cancel {
    self.closed = YES;
    [self invalidateRequests];
    [self dismissViewControllerAnimated:LSMapAnimationsEnabled() completion:nil];
}
- (NSArray<UIKeyCommand *> *)keyCommands { return @[[UIKeyCommand keyCommandWithInput:UIKeyInputEscape modifierFlags:0 action:@selector(cancel)]]; }
- (BOOL)accessibilityPerformEscape { [self cancel]; return YES; }
@end
