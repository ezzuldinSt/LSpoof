#import "MapPickerViewController+Private.h"
#import "LocationSpoofer.h"
#import "BookmarksManager.h"
#import "PersistenceManager.h"

static NSString * const kLSBookmarksCell = @"LSBookmarksCell";

typedef NS_ENUM(NSInteger, LSBookmarksSection) {
    LSBookmarksSectionRecents = 0,
    LSBookmarksSectionSaved = 1
};

@implementation MapPickerViewController (LSBookmarksUI)

- (void)buildBookmarksPanel {
    self.bookmarksContainer = [[UIView alloc] init];
    self.bookmarksContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.bookmarksContainer.hidden = YES;
    [self.controlPanel.contentView addSubview:self.bookmarksContainer];

    self.bookmarksTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.bookmarksTableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.bookmarksTableView.dataSource = (id<UITableViewDataSource>)self;
    self.bookmarksTableView.delegate = (id<UITableViewDelegate>)self;
    self.bookmarksTableView.backgroundColor = UIColor.clearColor;
    self.bookmarksTableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.bookmarksTableView registerClass:[UITableViewCell class] forCellReuseIdentifier:kLSBookmarksCell];
    [self.bookmarksContainer addSubview:self.bookmarksTableView];

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(ls_handleBookmarksLongPress:)];
    [self.bookmarksTableView addGestureRecognizer:longPress];

    [NSLayoutConstraint activateConstraints:@[
        [self.bookmarksTableView.topAnchor constraintEqualToAnchor:self.bookmarksContainer.topAnchor],
        [self.bookmarksTableView.leadingAnchor constraintEqualToAnchor:self.bookmarksContainer.leadingAnchor],
        [self.bookmarksTableView.trailingAnchor constraintEqualToAnchor:self.bookmarksContainer.trailingAnchor],
        [self.bookmarksTableView.bottomAnchor constraintEqualToAnchor:self.bookmarksContainer.bottomAnchor]
    ]];
}

- (void)updatePanelTabVisibility {
    BOOL mapTab = self.panelTab == LSMapPickerPanelTabMap;

    CGFloat duration = 0.2;
    self.mapControlsContainer.hidden = NO;
    self.bookmarksContainer.hidden = NO;

    [UIView animateWithDuration:duration animations:^{
        self.mapControlsContainer.alpha = mapTab ? 1.0 : 0.0;
        self.bookmarksContainer.alpha = mapTab ? 0.0 : 1.0;
        self.coordinateModeSegment.alpha = mapTab ? 1.0 : 0.0;
        self.searchBar.alpha = mapTab ? 1.0 : 0.0;
    } completion:^(BOOL finished) {
        (void)finished;
        self.mapControlsContainer.hidden = !mapTab;
        self.bookmarksContainer.hidden = mapTab;
        self.coordinateModeSegment.hidden = !mapTab;
        self.searchBar.hidden = !mapTab;
    }];

    if (!mapTab) {
        [self.bookmarksTableView reloadData];
    } else {
        [self updateCoordinateModeVisibility];
    }
}

- (void)handlePanelTabChanged:(UISegmentedControl *)sender {
    self.panelTab = (LSMapPickerPanelTab)sender.selectedSegmentIndex;
    [self updatePanelTabVisibility];
}

- (void)handleCoordinateModeChanged:(UISegmentedControl *)sender {
    self.coordinateMode = (LSMapPickerCoordinateMode)sender.selectedSegmentIndex;
    [self updateCoordinateModeVisibility];
}

- (void)handleBookmarkSaveTapped {
    [self presentSaveBookmarkAlertWithSuggestedName:nil coordinate:self.selectedCoordinate];
}

- (void)presentSaveBookmarkAlertWithSuggestedName:(NSString *)name coordinate:(CLLocationCoordinate2D)coordinate {
    NSString *suggested = name.length > 0 ? name : @"Location";

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Save Bookmark"
                                                                    message:nil
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = suggested;
        textField.placeholder = @"Name";
    }];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        NSString *bookmarkName = alert.textFields.firstObject.text;
        if (bookmarkName.length == 0) {
            bookmarkName = @"Location";
        }
        [[BookmarksManager shared] addBookmarkWithName:bookmarkName coordinate:coordinate];
        [strongSelf playBookmarkSavedHaptic];
        [strongSelf.bookmarksTableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];

    if (name.length == 0) {
        CLLocation *location = [[CLLocation alloc] initWithLatitude:coordinate.latitude
                                                           longitude:coordinate.longitude];
        CLGeocoder *geocoder = [[CLGeocoder alloc] init];
        [geocoder reverseGeocodeLocation:location completionHandler:^(NSArray<CLPlacemark *> *placemarks, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!error && placemarks.firstObject.name.length > 0) {
                    UITextField *field = alert.textFields.firstObject;
                    if ([field.text isEqualToString:@"Location"]) {
                        field.text = placemarks.firstObject.name;
                    }
                }
            });
        }];
    }
}

- (BOOL)ls_isBookmarksTableView:(UITableView *)tableView {
    return tableView == self.bookmarksTableView;
}

- (NSInteger)ls_bookmarksNumberOfSections {
    return 2;
}

- (NSInteger)ls_bookmarksNumberOfRowsInSection:(NSInteger)section {
    if (section == LSBookmarksSectionRecents) {
        return (NSInteger)[PersistenceManager shared].recentLocations.count;
    }
    return (NSInteger)[BookmarksManager shared].allBookmarks.count;
}

- (NSString *)ls_bookmarksTitleForHeaderInSection:(NSInteger)section {
    if (section == LSBookmarksSectionRecents) {
        return @"Recents";
    }
    return @"Bookmarks";
}

- (UITableViewCell *)ls_bookmarksCellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self.bookmarksTableView dequeueReusableCellWithIdentifier:kLSBookmarksCell forIndexPath:indexPath];

    CLLocationCoordinate2D coordinate = kCLLocationCoordinate2DInvalid;
    NSString *title = @"Location";

    if (indexPath.section == LSBookmarksSectionRecents) {
        NSArray<NSDictionary *> *recents = [PersistenceManager shared].recentLocations;
        if (indexPath.row < (NSInteger)recents.count) {
            NSDictionary *entry = recents[indexPath.row];
            coordinate = CLLocationCoordinate2DMake([entry[@"LSRecentLat"] doubleValue], [entry[@"LSRecentLon"] doubleValue]);
            title = entry[@"LSRecentName"] ?: @"Location";
        }
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        NSArray<LSBookmark *> *bookmarks = [BookmarksManager shared].allBookmarks;
        if (indexPath.row < (NSInteger)bookmarks.count) {
            LSBookmark *bookmark = bookmarks[indexPath.row];
            coordinate = bookmark.coordinate;
            title = bookmark.name;
        }

        UIButton *applyButton = [UIButton buttonWithType:UIButtonTypeSystem];
        applyButton.frame = CGRectMake(0, 0, 64, 32);
        [applyButton setTitle:@"Apply" forState:UIControlStateNormal];
        applyButton.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        applyButton.tag = indexPath.row;
        [applyButton addTarget:self action:@selector(ls_applyBookmarkFromButton:) forControlEvents:UIControlEventTouchUpInside];
        cell.accessoryView = applyButton;
        cell.accessoryType = UITableViewCellAccessoryNone;
    }

    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = title;
    content.textProperties.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    if (CLLocationCoordinate2DIsValid(coordinate)) {
        content.secondaryText = [NSString stringWithFormat:@"%.5f, %.5f", coordinate.latitude, coordinate.longitude];
    }
    content.secondaryTextProperties.font = [UIFont monospacedDigitSystemFontOfSize:12.0 weight:UIFontWeightRegular];
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    cell.contentConfiguration = content;
    return cell;
}

- (void)ls_bookmarksDidSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    CLLocationCoordinate2D coordinate = kCLLocationCoordinate2DInvalid;

    if (indexPath.section == LSBookmarksSectionRecents) {
        NSArray<NSDictionary *> *recents = [PersistenceManager shared].recentLocations;
        if (indexPath.row < (NSInteger)recents.count) {
            NSDictionary *entry = recents[indexPath.row];
            coordinate = CLLocationCoordinate2DMake([entry[@"LSRecentLat"] doubleValue], [entry[@"LSRecentLon"] doubleValue]);
        }
    } else {
        NSArray<LSBookmark *> *bookmarks = [BookmarksManager shared].allBookmarks;
        if (indexPath.row < (NSInteger)bookmarks.count) {
            coordinate = bookmarks[indexPath.row].coordinate;
        }
    }

    if (!CLLocationCoordinate2DIsValid(coordinate)) {
        return;
    }

    [self movePinToCoordinate:coordinate animated:YES];
}

- (BOOL)ls_bookmarksCanEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == LSBookmarksSectionSaved;
}

- (void)ls_bookmarksCommitDeleteAtIndexPath:(NSIndexPath *)indexPath {
    NSArray<LSBookmark *> *bookmarks = [BookmarksManager shared].allBookmarks;
    NSString *name = (indexPath.row < (NSInteger)bookmarks.count) ? bookmarks[indexPath.row].name : @"this bookmark";

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Delete Bookmark"
                                                                   message:[NSString stringWithFormat:@"Delete \"%@\"?", name]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.bookmarksTableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [[BookmarksManager shared] removeBookmarkAtIndex:(NSUInteger)indexPath.row];
        [strongSelf.bookmarksTableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationLeft];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)ls_bookmarksCanMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == LSBookmarksSectionSaved && self.bookmarksEditMode;
}

- (void)ls_bookmarksMoveFromIndexPath:(NSIndexPath *)source toIndexPath:(NSIndexPath *)destination {
    [[BookmarksManager shared] moveBookmarkFromIndex:(NSUInteger)source.row toIndex:(NSUInteger)destination.row];
}

- (UIView *)ls_bookmarksHeaderForSection:(NSInteger)section {
    if (section != LSBookmarksSectionSaved) {
        return nil;
    }

    UIView *header = [[UIView alloc] init];
    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"Bookmarks";
    title.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    title.textColor = UIColor.secondaryLabelColor;
    [header addSubview:title];

    UIButton *editButton = [UIButton buttonWithType:UIButtonTypeSystem];
    editButton.translatesAutoresizingMaskIntoConstraints = NO;
    [editButton setTitle:self.bookmarksEditMode ? @"Done" : @"Edit" forState:UIControlStateNormal];
    editButton.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    [editButton addTarget:self action:@selector(ls_toggleBookmarksEditMode) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:editButton];

    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20.0],
        [title.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [editButton.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16.0],
        [editButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [header.heightAnchor constraintEqualToConstant:28.0]
    ]];
    return header;
}

- (void)ls_handleBookmarksLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) {
        return;
    }

    CGPoint point = [gesture locationInView:self.bookmarksTableView];
    NSIndexPath *indexPath = [self.bookmarksTableView indexPathForRowAtPoint:point];
    if (!indexPath || indexPath.section != LSBookmarksSectionSaved) {
        return;
    }

    NSArray<LSBookmark *> *bookmarks = [BookmarksManager shared].allBookmarks;
    if (indexPath.row >= (NSInteger)bookmarks.count) {
        return;
    }

    LSBookmark *bookmark = bookmarks[indexPath.row];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Rename Bookmark"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = bookmark.name;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    __weak typeof(alert) weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        UIAlertController *strongAlert = weakAlert;
        if (!strongAlert) return;
        NSString *name = strongAlert.textFields.firstObject.text;
        if (name.length == 0) {
            return;
        }
        [[BookmarksManager shared] renameBookmark:name atIndex:(NSUInteger)indexPath.row];
        [strongSelf.bookmarksTableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)ls_toggleBookmarksEditMode {
    self.bookmarksEditMode = !self.bookmarksEditMode;
    [self.bookmarksTableView setEditing:self.bookmarksEditMode animated:YES];
    [self.bookmarksTableView reloadData];
}

- (void)ls_applyBookmarkFromButton:(UIButton *)sender {
    NSArray<LSBookmark *> *bookmarks = [BookmarksManager shared].allBookmarks;
    NSUInteger index = sender.tag;
    if (index >= bookmarks.count) {
        return;
    }

    LSBookmark *bookmark = bookmarks[index];
    PersistenceManager *store = [PersistenceManager shared];
    if (![store setSpoofCoordinate:bookmark.coordinate enabled:YES]) {
        [self playRouteFailureHaptic];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Error"
                                                                       message:@"This bookmark has an invalid coordinate."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    [store recordRecentCoordinate:bookmark.coordinate name:bookmark.name];
    [self playApplyHaptic];
    LSSetHooksBypassed(NO);
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)ls_presentStaticMapActionSheetAtCoordinate:(CLLocationCoordinate2D)coordinate {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Place Pin Here" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf movePinToCoordinate:coordinate animated:YES];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Save as Bookmark" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf presentSaveBookmarkAlertWithSuggestedName:nil coordinate:coordinate];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

@end
