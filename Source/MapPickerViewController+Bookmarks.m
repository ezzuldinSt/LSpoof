#import "MapPickerViewController+Private.h"
#import "PersistenceManager.h"

@implementation MapPickerViewController (LSBookmarksUI)
- (void)buildSavedUI {
    self.savedTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.savedTable.dataSource = self;
    self.savedTable.delegate = self;
    self.savedTable.rowHeight = UITableViewAutomaticDimension;
    self.savedTable.estimatedRowHeight = 80;
    self.savedTable.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.savedHint = LSLabel(@"Tap a place to preview it, then Apply location. Use the menu to rename, delete, or move a saved place.", UIFontTextStyleSubheadline);
    self.savedHint.textColor = UIColor.secondaryLabelColor;
    self.editSavedButton = LSButton(@"Reorder saved places", @"arrow.up.arrow.down", NO);
    [self.editSavedButton addTarget:self action:@selector(toggleSavedEditing) forControlEvents:UIControlEventTouchUpInside];
    UIButton *clear = LSButton(@"Clear recent locations", @"clock.arrow.circlepath", NO);
    [clear addTarget:self action:@selector(clearRecents) forControlEvents:UIControlEventTouchUpInside];
    self.savedToolbar = LSInsetPanel(LSStack(@[self.savedHint, self.editSavedButton, clear], 12));
    self.savedTable.tableHeaderView = self.savedToolbar;
    [self reloadSavedPlaces];
}
- (void)layoutSavedHeader {
    LSSizeTableHeader(self.savedTable, self.savedToolbar);
}
- (void)reloadSavedPlaces {
    self.savedPlaces = BookmarksManager.shared.allBookmarks;
    self.recents = PersistenceManager.shared.recentLocations;
    self.editSavedButton.enabled = self.savedPlaces.count > 1;
    if (self.savedPlaces.count < 2) self.savedTable.editing = NO;
    UIButtonConfiguration *configuration = self.editSavedButton.configuration;
    configuration.title = self.savedTable.editing ? @"Done reordering" : @"Reorder saved places";
    self.editSavedButton.configuration = configuration;
    self.editSavedButton.accessibilityLabel = configuration.title;
    [self.savedTable reloadData];
    [self layoutSavedHeader];
}
- (void)toggleSavedEditing {
    [self.savedTable setEditing:!self.savedTable.editing animated:LSMapAnimationsEnabled()];
    UIButtonConfiguration *configuration = self.editSavedButton.configuration;
    configuration.title = self.savedTable.editing ? @"Done reordering" : @"Reorder saved places";
    self.editSavedButton.configuration = configuration;
    self.editSavedButton.accessibilityLabel = configuration.title;
}
- (NSInteger)savedRowsInSection:(NSInteger)section { return MAX(1, (NSInteger)(section == 0 ? self.savedPlaces.count : self.recents.count)); }
- (UITableViewCell *)savedCell:(NSIndexPath *)path {
    UITableViewCell *cell = [self.savedTable dequeueReusableCellWithIdentifier:@"SavedPlace"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"SavedPlace"];
    BOOL empty = path.section == 0 ? self.savedPlaces.count == 0 : self.recents.count == 0;
    UIListContentConfiguration *content = cell.defaultContentConfiguration;
    content.textProperties.numberOfLines = 0;
    content.secondaryTextProperties.numberOfLines = 0;
    if (empty) {
        content.text = path.section == 0 ? @"Your places, ready to use again" : @"No recent locations";
        content.secondaryText = path.section == 0 ? @"Choose a location on the map and tap Save place." : @"Applied locations will appear here.";
        content.image = [UIImage systemImageNamed:path.section == 0 ? @"bookmark" : @"clock"];
        cell.accessoryView = nil;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.accessibilityTraits = UIAccessibilityTraitStaticText;
    } else {
        NSString *name;
        CLLocationCoordinate2D coordinate;
        if (path.section == 0) { LSBookmark *place = self.savedPlaces[path.row]; name = place.name; coordinate = place.coordinate; }
        else { NSDictionary *entry = self.recents[path.row]; name = entry[@"LSRecentName"]; coordinate = CLLocationCoordinate2DMake([entry[@"LSRecentLat"] doubleValue], [entry[@"LSRecentLon"] doubleValue]); }
        content.text = name;
        content.secondaryText = [NSString stringWithFormat:@"%@\nTap to preview", LSCoordinateText(coordinate)];
        content.image = [UIImage systemImageNamed:path.section == 0 ? @"bookmark.fill" : @"clock"];
        UIButton *more = LSButton(@"", @"ellipsis", NO);
        more.accessibilityLabel = [NSString stringWithFormat:@"Actions for %@", name];
        more.showsMenuAsPrimaryAction = YES;
        more.menu = [self menuForPath:path];
        // A minimum 44 pt accessory supports touch, VoiceOver and Switch Control.
        more.frame = CGRectMake(0, 0, 48, 48);
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
    LSAnnounce(@"Place previewed. Apply location when you’re ready.");
}
- (void)previewSavedPlace:(NSIndexPath *)path {
    if (path.section == 0 && path.row < (NSInteger)self.savedPlaces.count) {
        LSBookmark *place = self.savedPlaces[path.row];
        [self previewCoordinate:place.coordinate name:place.name];
    } else if (path.section == 1 && path.row < (NSInteger)self.recents.count) {
        NSDictionary *entry = self.recents[path.row];
        [self previewCoordinate:CLLocationCoordinate2DMake([entry[@"LSRecentLat"] doubleValue], [entry[@"LSRecentLon"] doubleValue]) name:entry[@"LSRecentName"]];
    }
}
- (UIMenu *)menuForPath:(NSIndexPath *)path {
    if (path.section == 1 && path.row < (NSInteger)self.recents.count) {
        NSDictionary *entry = self.recents[path.row];
        NSString *name = entry[@"LSRecentName"];
        CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake([entry[@"LSRecentLat"] doubleValue], [entry[@"LSRecentLon"] doubleValue]);
        __weak typeof(self) weakSelf = self;
        UIAction *preview = [UIAction actionWithTitle:@"Preview location" image:[UIImage systemImageNamed:@"map"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf previewCoordinate:coordinate name:name]; }];
        UIAction *save = [UIAction actionWithTitle:@"Save place" image:[UIImage systemImageNamed:@"bookmark"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf namePlace:name coordinate:coordinate identifier:nil]; }];
        return [UIMenu menuWithTitle:name children:@[preview, save]];
    }
    if (path.section != 0 || path.row >= (NSInteger)self.savedPlaces.count) return [UIMenu menuWithTitle:@"" children:@[]];
    LSBookmark *place = self.savedPlaces[path.row];
    NSString *identifier = place.identifier;
    __weak typeof(self) weakSelf = self;
    UIAction *preview = [UIAction actionWithTitle:@"Preview location" image:[UIImage systemImageNamed:@"map"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf previewCoordinate:place.coordinate name:place.name]; }];
    UIAction *rename = [UIAction actionWithTitle:@"Rename" image:[UIImage systemImageNamed:@"pencil"] identifier:nil handler:^(__unused UIAction *action) {
        [weakSelf namePlace:place.name coordinate:place.coordinate identifier:identifier];
    }];
    UIAction *first = [UIAction actionWithTitle:@"Move to top" image:[UIImage systemImageNamed:@"arrow.up.to.line"] identifier:nil handler:^(__unused UIAction *action) {
        [BookmarksManager.shared moveBookmarkWithID:identifier toIndex:0]; [weakSelf reloadSavedPlaces];
    }];
    UIAction *up = [UIAction actionWithTitle:@"Move up" image:[UIImage systemImageNamed:@"arrow.up"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf moveID:identifier offset:-1]; }];
    UIAction *down = [UIAction actionWithTitle:@"Move down" image:[UIImage systemImageNamed:@"arrow.down"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf moveID:identifier offset:1]; }];
    UIAction *remove = [UIAction actionWithTitle:@"Delete saved place" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(__unused UIAction *action) {
        [weakSelf confirmAction:@"Delete saved place?" message:place.name button:@"Delete" action:^{ [BookmarksManager.shared removeBookmarkWithID:identifier]; [weakSelf reloadSavedPlaces]; }];
    }];
    remove.attributes = UIMenuElementAttributesDestructive;
    return [UIMenu menuWithTitle:place.name children:@[preview, rename, first, up, down, remove]];
}
- (UIContextMenuConfiguration *)savedMenu:(NSIndexPath *)path {
    if (path.section != 0 || path.row >= (NSInteger)self.savedPlaces.count) return nil;
    UIMenu *menu = [self menuForPath:path];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(__unused NSArray<UIMenuElement *> *suggested) { return menu; }];
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
    if (!identifier && BookmarksManager.shared.allBookmarks.count >= BookmarksManager.capacity) {
        UIAlertController *limit = [UIAlertController alertControllerWithTitle:@"50 saved places maximum" message:@"Delete a saved place before adding another." preferredStyle:UIAlertControllerStyleAlert];
        [limit addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:limit animated:LSMapAnimationsEnabled() completion:nil];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:identifier ? @"Rename place" : @"Save place" message:@"Choose a name from 1 to 120 characters." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.text = name; field.placeholder = @"Place name"; field.accessibilityLabel = @"Place name"; field.autocapitalizationType = UITextAutocapitalizationTypeWords; }];
    __weak UIAlertController *weakAlert = alert;
    __weak typeof(self) weakSelf = self;
    UIAlertAction *save = [UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *entered = [weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        BOOL saved = identifier ? [BookmarksManager.shared renameBookmarkWithID:identifier name:entered] : [BookmarksManager.shared addBookmarkWithName:entered coordinate:coordinate];
        NSString *message = saved ? @"Place saved." : @"Could not save. Check the name and the 50-place limit.";
        [weakSelf showMessage:message];
        weakSelf.savedHint.text = message;
        [weakSelf reloadSavedPlaces];
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
    [self presentViewController:alert animated:LSMapAnimationsEnabled() completion:nil];
}
- (void)clearRecents {
    __weak typeof(self) weakSelf = self;
    [self confirmAction:@"Clear recent locations?" message:@"Remove the recently applied locations from this list." button:@"Clear recents" action:^{ [PersistenceManager.shared clearRecentLocations]; [weakSelf reloadSavedPlaces]; }];
}
@end
