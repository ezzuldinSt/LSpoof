#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

@interface LSBackupSummary : NSObject
@property (nonatomic) NSUInteger placeCount;
@property (nonatomic) NSUInteger routeCount;
@property (nonatomic) NSUInteger recentCount;
// The backup has a routes list (made by a version with saved routes).
@property (nonatomic) BOOL hasRoutes;
@property (nonatomic) BOOL hasSettings;
@property (nonatomic, strong, nullable) NSDate *exportedAt;
@end

// Settings, saved places (with their radius), saved routes, recents and playback preferences
// as a JSON file, so a reinstall or a second device can pick up where you left off (#21).
// Saved routes (#20) are an extra "routes" list of route archives in the same version 1 file;
// older versions ignore it, and a backup without it leaves the saved routes alone.
@interface LSBackup : NSObject
// Recorded tracks make backups with saved routes larger than place lists.
@property (class, nonatomic, readonly) NSUInteger maximumBytes;
+ (NSData *)exportData;
+ (NSString *)suggestedFileName;
// Checks a backup without changing anything. On failure, error holds a readable reason.
+ (nullable LSBackupSummary *)inspectData:(NSData *)data error:(NSString * _Nullable * _Nullable)error;
// Applies a backup. Replace swaps saved places, saved routes and recents; merge adds the missing ones.
// The returned counts are what was added.
+ (nullable LSBackupSummary *)restoreData:(NSData *)data replace:(BOOL)replace error:(NSString * _Nullable * _Nullable)error;
// True when the text looks like an LSpoof backup, e.g. on the clipboard.
+ (BOOL)textLooksLikeBackup:(nullable NSString *)text;
@end

NS_ASSUME_NONNULL_END
