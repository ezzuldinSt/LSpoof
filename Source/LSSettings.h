#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Editable value object. Changing a copy has no persistence or session side effects.
@interface LSSettings : NSObject <NSCopying>
@property (nonatomic) double altitude;
@property (nonatomic) double course;
@property (nonatomic) BOOL fluctuationEnabled;
@property (nonatomic) double fluctuationRadius;
@property (nonatomic) BOOL rememberLocation;
@property (nonatomic) BOOL showRealLocation;
@property (nonatomic) BOOL showFloatingButton;
+ (instancetype)storedSettings;
- (BOOL)isValid;
- (void)writeToStore;
@end
NS_ASSUME_NONNULL_END
