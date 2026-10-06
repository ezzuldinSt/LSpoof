#import "MapPickerViewController+Private.h"
#import "PersistenceManager.h"

@implementation MapPickerViewController (LSBookmarksUI)
- (void)buildSavedUI {
    self.savedTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.savedTable.dataSource = self;
    self.savedTable.delegate = self;
    self.savedTable.rowHeight = UITableViewAutomaticDimension;
    self.savedTable.estimatedRowHeight = 72;
    self.savedTable.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.savedHint = LSLabel(@"Tap a place to preview it. Swipe right to apply it right away, or left to rename or delete.", UIFontTextStyleFootnote);
    self.savedHint.textColor = UIColor.secondaryLabelColor;
    self.editSavedButton = LSChipButton(@"Reorder", @"arrow.up.arrow.down");
    [self.editSavedButton addTarget:self action:@selector(toggleSavedEditing) forControlEvents:UIControlEventTouchUpInside];
    UIButton *clear = LSChipButton(@"Clear recents", @"clock.arrow.circlepath");
    clear.accessibilityLabel = @"Clear recent locations";
    [clear addTarget:self action:@selector(clearRecents) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *chips = LSRow(@[self.editSavedButton, clear], 8);
    UIStackView *chipHolder = LSStack(@[chips], 0);
    chipHolder.alignment = UIStackViewAlignmentLeading;
    UIStackView *content = LSStack(@[self.savedHint, chipHolder], 10);
    // Inset to line up with the inset-grouped sections below.
    UIView *header = [[UIView alloc] init];
    [header addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:header.topAnchor constant:4],
        [content.leadingAnchor constraintEqualToAnchor:header.layoutMarginsGuide.leadingAnchor constant:4],
        [content.trailingAnchor constraintEqualToAnchor:header.layoutMarginsGuide.trailingAnchor constant:-4],
        [content.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-4]
    ]];
    header.preservesSuperviewLayoutMargins = YES;
    self.savedToolbar = header;
    self.savedTable.tableHeaderView = self.savedToolbar;
    [self reloadSavedPlaces];
}
- (void)layoutSavedHeader {
    LSSizeTableHeader(self.savedTable, self.savedToolbar);
}
- (void)updateEditButton {
    UIButtonConfiguration *configuration = self.editSavedButton.configuration;
    configuration.title = self.savedTable.editing ? @"Done" : @"Reorder";
    configuration.image = [UIImage systemImageNamed:self.savedTable.editing ? @"checkmark" : @"arrow.up.arrow.down"];
    self.editSavedButton.configuration = configuration;
    LSSetChipSelected(self.editSavedButton, self.savedTable.editing);
    self.editSavedButton.accessibilityLabel = self.savedTable.editing ? @"Done reordering" : @"Reorder saved places";
}
- (void)reloadSavedPlaces {
    self.savedPlaces = BookmarksManager.shared.allBookmarks;
    self.recents = PersistenceManager.shared.recentLocations;
    self.editSavedButton.enabled = self.savedPlaces.count > 1;
    if (self.savedPlaces.count < 2) self.savedTable.editing = NO;
    [self updateEditButton];
    [self.savedTable reloadData];
    [self layoutSavedHeader];
}
- (void)toggleSavedEditing {
    [self.savedTable setEditing:!self.savedTable.editing animated:LSMapAnimationsEnabled()];
    LSHapticSelection();
    [self updateEditButton];
}
- (NSInteger)savedRowsInSection:(NSInteger)section { return MAX(1, (NSInteger)(section == 0 ? self.savedPlaces.count : self.recents.count)); }
- (BOOL)entryAtPath:(NSIndexPath *)path name:(NSString **)name coordinate:(CLLocationCoordinate2D *)coordinate date:(NSDate **)date {
    if (path.section == 0 && path.row < (NSInteger)self.savedPlaces.count) {
        LSBookmark *place = self.savedPlaces[path.row];
        *name = place.name; *coordinate = place.coordinate; *date = place.createdAt;
        return YES;
    }
    if (path.section == 1 && path.row < (NSInteger)self.recents.count) {
        NSDictionary *entry = self.recents[path.row];
        *name = entry[@"LSRecentName"];
        *coordinate = CLLocationCoordinate2DMake([entry[@"LSRecentLat"] doubleValue], [entry[@"LSRecentLon"] doubleValue]);
        NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
        *date = [formatter dateFromString:entry[@"LSRecentDate"]];
        return YES;
    }
    return NO;
}
- (UITableViewCell *)savedCell:(NSIndexPath *)path {
    UITableViewCell *cell = [self.savedTable dequeueReusableCellWithIdentifier:@"SavedPlace"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"SavedPlace"];
    UIListContentConfiguration *content = UIListContentConfiguration.subtitleCellConfiguration;
    content.textProperties.numberOfLines = 0;
    content.textProperties.font = LSFont(UIFontTextStyleBody, UIFontWeightSemibold, 30);
    content.secondaryTextProperties.numberOfLines = 0;
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    content.textToSecondaryTextVerticalPadding = 3;
    content.imageToTextPadding = 14;
    content.imageProperties.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:28 weight:UIImageSymbolWeightRegular];
    content.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(12, 0, 12, 0);
    NSString *name = nil;
    CLLocationCoordinate2D coordinate = kCLLocationCoordinate2DInvalid;
    NSDate *date = nil;
    if (![self entryAtPath:path name:&name coordinate:&coordinate date:&date]) {
        content.text = path.section == 0 ? @"No saved places yet" : @"No recent locations";
        content.textProperties.color = UIColor.secondaryLabelColor;
        content.secondaryText = path.section == 0 ? @"Drop a pin and tap Save, or touch and hold the map." : @"Locations you apply appear here.";
        content.image = [UIImage systemImageNamed:path.section == 0 ? @"bookmark.circle" : @"clock"];
        content.imageProperties.tintColor = UIColor.tertiaryLabelColor;
        cell.accessoryView = nil;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.accessibilityTraits = UIAccessibilityTraitStaticText;
        cell.accessibilityHint = nil;
    } else {
        content.text = name;
        NSString *coordinates = LSCoordinateText(coordinate);
        content.secondaryText = date ? [NSString stringWithFormat:@"%@\n%@", coordinates, LSRelativeDate(date)] : coordinates;
        content.secondaryTextProperties.font = LSMonospacedFont(UIFontTextStyleFootnote);
        content.image = [UIImage systemImageNamed:path.section == 0 ? @"bookmark.circle.fill" : @"clock.arrow.circlepath"];
        content.imageProperties.tintColor = path.section == 0 ? LSAccentColor() : UIColor.systemGrayColor;
        UIButtonConfiguration *moreStyle = UIButtonConfiguration.plainButtonConfiguration;
        moreStyle.image = [UIImage systemImageNamed:@"ellipsis.circle"];
        moreStyle.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightRegular];
        moreStyle.baseForegroundColor = UIColor.secondaryLabelColor;
        UIButton *more = [UIButton buttonWithType:UIButtonTypeSystem];
        more.configuration = moreStyle;
        more.accessibilityLabel = [NSString stringWithFormat:@"Actions for %@", name];
        more.showsMenuAsPrimaryAction = YES;
        more.menu = [self menuForPath:path];
        // A minimum 44 pt accessory supports touch, VoiceOver and Switch Control.
        more.frame = CGRectMake(0, 0, 44, 44);
        cell.accessoryView = more;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessibilityTraits = UIAccessibilityTraitButton;
        cell.accessibilityHint = @"Preview on the map. Apply location to change the app’s location.";
    }
    cell.contentConfiguration = content;
    return cell;
}
- (void)previewCoordinate:(CLLocationCoordinate2D)coordinate name:(NSString *)name {
    self.tab = LSPickerTabLocation;
    [self setSelection:coordinate name:name];
    [self updateWorkspace];
    [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(coordinate, 2000, 2000) animated:LSMapAnimationsEnabled()];
    [self.scroll setContentOffset:CGPointZero animated:NO];
    LSHapticSelection();
    LSAnnounce(@"Place previewed. Apply location when you’re ready.");
}
- (void)previewSavedPlace:(NSIndexPath *)path {
    NSString *name = nil;
    CLLocationCoordinate2D coordinate;
    NSDate *date = nil;
    if ([self entryAtPath:path name:&name coordinate:&coordinate date:&date]) [self previewCoordinate:coordinate name:name];
}
- (void)deleteBookmark:(LSBookmark *)place {
    __weak typeof(self) weakSelf = self;
    [self confirmAction:@"Delete saved place?" message:[NSString stringWithFormat:@"“%@” will be removed from your saved places.", place.name] button:@"Delete" destructive:YES action:^{
        [BookmarksManager.shared removeBookmarkWithID:place.identifier];
        [weakSelf reloadSavedPlaces];
        [weakSelf showMessage:@"Saved place deleted." symbol:@"trash.fill"];
    }];
}
- (UIMenu *)menuForPath:(NSIndexPath *)path {
    __weak typeof(self) weakSelf = self;
    if (path.section == 1 && path.row < (NSInteger)self.recents.count) {
        NSDictionary *entry = self.recents[path.row];
        NSString *name = entry[@"LSRecentName"];
        CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake([entry[@"LSRecentLat"] doubleValue], [entry[@"LSRecentLon"] doubleValue]);
        UIAction *apply = [UIAction actionWithTitle:@"Apply now" image:[UIImage systemImageNamed:@"checkmark.circle"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf applyCoordinate:coordinate name:name]; }];
        UIAction *preview = [UIAction actionWithTitle:@"Preview location" image:[UIImage systemImageNamed:@"map"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf previewCoordinate:coordinate name:name]; }];
        UIAction *save = [UIAction actionWithTitle:@"Save place" image:[UIImage systemImageNamed:@"bookmark"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf namePlace:name coordinate:coordinate identifier:nil]; }];
        UIAction *copy = [UIAction actionWithTitle:@"Copy coordinates" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__unused UIAction *action) {
            UIPasteboard.generalPasteboard.string = LSCoordinateText(coordinate);
            [weakSelf showMessage:@"Coordinates copied." symbol:@"doc.on.doc.fill"];
        }];
        return [UIMenu menuWithTitle:name children:@[apply, preview, save, copy]];
    }
    if (path.section != 0 || path.row >= (NSInteger)self.savedPlaces.count) return [UIMenu menuWithTitle:@"" children:@[]];
    LSBookmark *place = self.savedPlaces[path.row];
    NSString *identifier = place.identifier;
    UIAction *apply = [UIAction actionWithTitle:@"Apply now" image:[UIImage systemImageNamed:@"checkmark.circle"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf applyCoordinate:place.coordinate name:place.name]; }];
    UIAction *preview = [UIAction actionWithTitle:@"Preview location" image:[UIImage systemImageNamed:@"map"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf previewCoordinate:place.coordinate name:place.name]; }];
    UIAction *rename = [UIAction actionWithTitle:@"Rename" image:[UIImage systemImageNamed:@"pencil"] identifier:nil handler:^(__unused UIAction *action) {
        [weakSelf namePlace:place.name coordinate:place.coordinate identifier:identifier];
    }];
    UIAction *copy = [UIAction actionWithTitle:@"Copy coordinates" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__unused UIAction *action) {
        UIPasteboard.generalPasteboard.string = LSCoordinateText(place.coordinate);
        [weakSelf showMessage:@"Coordinates copied." symbol:@"doc.on.doc.fill"];
    }];
    UIAction *first = [UIAction actionWithTitle:@"Move to top" image:[UIImage systemImageNamed:@"arrow.up.to.line"] identifier:nil handler:^(__unused UIAction *action) {
        [BookmarksManager.shared moveBookmarkWithID:identifier toIndex:0]; [weakSelf reloadSavedPlaces];
    }];
    UIAction *up = [UIAction actionWithTitle:@"Move up" image:[UIImage systemImageNamed:@"arrow.up"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf moveID:identifier offset:-1]; }];
    UIAction *down = [UIAction actionWithTitle:@"Move down" image:[UIImage systemImageNamed:@"arrow.down"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf moveID:identifier offset:1]; }];
    if (path.row == 0) { first.attributes = UIMenuElementAttributesDisabled; up.attributes = UIMenuElementAttributesDisabled; }
    if (path.row == (NSInteger)self.savedPlaces.count - 1) down.attributes = UIMenuElementAttributesDisabled;
    UIAction *remove = [UIAction actionWithTitle:@"Delete" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf deleteBookmark:place]; }];
    remove.attributes = UIMenuElementAttributesDestructive;
    UIMenu *primary = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[apply, preview]];
    UIMenu *edit = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[rename, copy]];
    UIMenu *order = [UIMenu menuWithTitle:@"Move" image:[UIImage systemImageNamed:@"arrow.up.arrow.down"] identifier:nil options:0 children:@[first, up, down]];
    UIMenu *danger = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[remove]];
    return [UIMenu menuWithTitle:place.name children:@[primary, edit, order, danger]];
}
- (UIContextMenuConfiguration *)savedMenu:(NSIndexPath *)path {
    BOOL saved = path.section == 0 && path.row < (NSInteger)self.savedPlaces.count;
    BOOL recent = path.section == 1 && path.row < (NSInteger)self.recents.count;
    if (!saved && !recent) return nil;
    UIMenu *menu = [self menuForPath:path];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(__unused NSArray<UIMenuElement *> *suggested) { return menu; }];
}
- (UISwipeActionsConfiguration *)savedSwipeActions:(NSIndexPath *)path leading:(BOOL)leading {
    NSString *name = nil;
    CLLocationCoordinate2D coordinate;
    NSDate *date = nil;
    if (self.savedTable.editing || ![self entryAtPath:path name:&name coordinate:&coordinate date:&date]) return nil;
    __weak typeof(self) weakSelf = self;
    if (leading) {
        UIContextualAction *apply = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Apply" handler:^(__unused UIContextualAction *action, __unused UIView *view, void (^done)(BOOL)) {
            [weakSelf applyCoordinate:coordinate name:name];
            done(YES);
        }];
        apply.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
        apply.backgroundColor = LSAccentColor();
        UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[apply]];
        configuration.performsFirstActionWithFullSwipe = YES;
        return configuration;
    }
    if (path.section == 1) {
        UIContextualAction *save = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Save" handler:^(__unused UIContextualAction *action, __unused UIView *view, void (^done)(BOOL)) {
            [weakSelf namePlace:name coordinate:coordinate identifier:nil];
            done(YES);
        }];
        save.image = [UIImage systemImageNamed:@"bookmark.fill"];
        save.backgroundColor = LSRouteColor();
        return [UISwipeActionsConfiguration configurationWithActions:@[save]];
    }
    LSBookmark *place = self.savedPlaces[path.row];
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete" handler:^(__unused UIContextualAction *action, __unused UIView *view, void (^done)(BOOL)) {
        [weakSelf deleteBookmark:place];
        done(NO);
    }];
    remove.image = [UIImage systemImageNamed:@"trash.fill"];
    UIContextualAction *rename = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Rename" handler:^(__unused UIContextualAction *action, __unused UIView *view, void (^done)(BOOL)) {
        [weakSelf namePlace:place.name coordinate:place.coordinate identifier:place.identifier];
        done(YES);
    }];
    rename.image = [UIImage systemImageNamed:@"pencil"];
    rename.backgroundColor = UIColor.systemGrayColor;
    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[remove, rename]];
    configuration.performsFirstActionWithFullSwipe = NO;
    return configuration;
}
- (void)moveID:(NSString *)identifier offset:(NSInteger)offset {
    NSArray<LSBookmark *> *current = BookmarksManager.shared.allBookmarks;
    NSUInteger index = [current indexOfObjectPassingTest:^BOOL(LSBookmark *place, __unused NSUInteger i, __unused BOOL *stop) { return [place.identifier isEqualToString:identifier]; }];
    NSInteger target = (NSInteger)index + offset;
    if (index != NSNotFound && target >= 0 && target < (NSInteger)current.count) [BookmarksManager.shared moveBookmarkWithID:identifier toIndex:(NSUInteger)target];
    [self reloadSavedPlaces];
}
- (void)moveSavedPlace:(NSIndexPath *)source to:(NSIndexPath *)destination {
    if (source.section != 0 || destination.section != 0 || source.row >= (NSInteger)self.savedPlaces.count || destination.row >= (NSInteger)self.savedPlaces.count) { [self reloadSavedPlaces]; return; }
    NSString *sourceID = self.savedPlaces[source.row].identifier;
    NSString *targetID = self.savedPlaces[destination.row].identifier;
    NSArray<LSBookmark *> *current = BookmarksManager.shared.allBookmarks;
    NSUInteger targetIndex = [current indexOfObjectPassingTest:^BOOL(LSBookmark *place, __unused NSUInteger i, __unused BOOL *stop) { return [place.identifier isEqualToString:targetID]; }];
    if (targetIndex != NSNotFound) [BookmarksManager.shared moveBookmarkWithID:sourceID toIndex:targetIndex];
    [self reloadSavedPlaces];
}
- (void)saveSelectedPlace { if (self.hasSelection) [self namePlace:self.selectedName coordinate:self.selectedCoordinate identifier:nil]; }
- (void)namePlace:(NSString *)name coordinate:(CLLocationCoordinate2D)coordinate identifier:(NSString *)identifier {
    [self namePlace:name coordinate:coordinate identifier:identifier allowDuplicate:NO];
}
- (void)namePlace:(NSString *)name coordinate:(CLLocationCoordinate2D)coordinate identifier:(NSString *)identifier allowDuplicate:(BOOL)allowDuplicate {
    if (!identifier && BookmarksManager.shared.allBookmarks.count >= BookmarksManager.capacity) {
        UIAlertController *limit = [UIAlertController alertControllerWithTitle:@"50 saved places maximum" message:@"Delete a saved place before adding another." preferredStyle:UIAlertControllerStyleAlert];
        [limit addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:limit animated:LSMapAnimationsEnabled() completion:nil];
        LSHapticWarning();
        return;
    }
    __weak typeof(self) weakSelf = self;
    LSBookmark *existing = identifier ? nil : [BookmarksManager.shared bookmarkNearCoordinate:coordinate];
    if (existing && !allowDuplicate) {
        // Touch-and-hold twice on the same spot used to create silent duplicates.
        [self confirmAction:@"Already saved" message:[NSString stringWithFormat:@"This spot is saved as “%@”.", existing.name] button:@"Save another copy" action:^{
            [weakSelf namePlace:name coordinate:coordinate identifier:nil allowDuplicate:YES];
        }];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:identifier ? @"Rename place" : @"Save place" message:@"Choose a name from 1 to 120 characters." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = name;
        field.placeholder = @"Place name";
        field.accessibilityLabel = @"Place name";
        field.autocapitalizationType = UITextAutocapitalizationTypeWords;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    __weak UIAlertController *weakAlert = alert;
    UIAlertAction *save = [UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        typeof(self) self = weakSelf;
        NSString *entered = [weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        BOOL saved = identifier ? [BookmarksManager.shared renameBookmarkWithID:identifier name:entered] : [BookmarksManager.shared addBookmarkWithName:entered coordinate:coordinate];
        if (saved) LSHapticSuccess(); else LSHapticWarning();
        [self showMessage:saved ? (identifier ? @"Place renamed." : @"Place saved.") : @"Could not save. Check the name and the 50-place limit."
                   symbol:saved ? @"bookmark.fill" : @"exclamationmark.triangle.fill"];
        [self reloadSavedPlaces];
        if (self.hasSelection && self.tab == LSPickerTabLocation) [self renderSelectedLocation];
    }];
    NSString *trimmed = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    save.enabled = trimmed.length > 0 && trimmed.length <= 120;
    __weak UIAlertAction *weakSave = save;
    [alert.textFields.firstObject addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
        NSString *entered = [weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        weakSave.enabled = entered.length > 0 && entered.length <= 120;
        weakAlert.message = weakSave.enabled ? @"This name identifies your saved place." : @"Enter a name from 1 to 120 characters.";
    }] forControlEvents:UIControlEventEditingChanged];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:save];
    alert.preferredAction = save;
    [self presentViewController:alert animated:LSMapAnimationsEnabled() completion:nil];
}
- (void)clearRecents {
    if (!self.recents.count) { [self showMessage:@"There are no recent locations to clear." symbol:@"clock"]; return; }
    __weak typeof(self) weakSelf = self;
    [self confirmAction:@"Clear recent locations?" message:@"Remove the recently applied locations from this list. Saved places stay." button:@"Clear recents" destructive:YES action:^{
        [PersistenceManager.shared clearRecentLocations];
        [weakSelf reloadSavedPlaces];
    }];
}
@end
