#import <Foundation/Foundation.h>
#import "LSTrackCodec.h"

NS_ASSUME_NONNULL_BEGIN

// A track read from a GPX, TCX or FIT file. Foundation only, so it can be tested on Linux,
// which is also why the instance variables are declared here (GNUstep's runtime needs it).
@interface LSTrack : NSObject {
@private
    NSString *_name;
    NSData *_pointData;
    NSString *_activity;
    NSString *_format;
}
@property (nonatomic, copy) NSString *name;
// LSTrackPoint values in file order.
@property (nonatomic, copy) NSData *pointData;
@property (nonatomic, readonly) NSUInteger count;
@property (nonatomic, readonly) const LSTrackPoint *points;
// Every point has a time and the times never go backwards.
@property (nonatomic, readonly) BOOL hasTimes;
// "walking", "cycling", "driving" or nil when the file doesn't say.
@property (nonatomic, copy, nullable) NSString *activity;
@property (nonatomic, copy) NSString *format;
@end

@interface LSTrackIO : NSObject
// Detects GPX, TCX or FIT from the bytes. On failure, error holds a readable reason.
+ (nullable LSTrack *)trackFromData:(NSData *)data fileName:(nullable NSString *)fileName error:(NSString * _Nullable * _Nullable)error;
+ (NSData *)GPXDataForPoints:(const LSTrackPoint *)points count:(NSUInteger)count name:(NSString *)name activity:(nullable NSString *)activity;
+ (NSData *)TCXDataForPoints:(const LSTrackPoint *)points count:(NSUInteger)count name:(NSString *)name activity:(nullable NSString *)activity;
+ (nullable NSData *)FITDataForPoints:(const LSTrackPoint *)points count:(NSUInteger)count activity:(nullable NSString *)activity;
// A file name without characters that Files or AirDrop reject.
+ (NSString *)safeFileName:(NSString *)name extension:(NSString *)extension;
@end

NS_ASSUME_NONNULL_END
