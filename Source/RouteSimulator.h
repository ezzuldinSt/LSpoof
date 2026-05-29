#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <MapKit/MapKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, LSTransportMode) {
    LSTransportModeWalking,
    LSTransportModeCycling,
    LSTransportModeDriving,
    LSTransportModeCustom
};

@class LSRouteSimulator;

@protocol LSRouteSimulatorDelegate <NSObject>
- (void)routeSimulator:(LSRouteSimulator *)simulator
   didUpdateCoordinate:(CLLocationCoordinate2D)coordinate
               heading:(CLLocationDirection)heading;
- (void)routeSimulatorDidFinish:(LSRouteSimulator *)simulator;
@end

@interface LSRouteSimulator : NSObject

@property (class, nonatomic, readonly) LSRouteSimulator *shared;

@property (nonatomic, weak, nullable) id<LSRouteSimulatorDelegate> delegate;
@property (nonatomic, assign) LSTransportMode transportMode;
@property (nonatomic, assign) double customSpeedKmh;
@property (nonatomic, readonly) BOOL isSimulating;
@property (nonatomic, readonly) BOOL isPaused;
@property (nonatomic, readonly) CLLocationCoordinate2D currentCoordinate;
@property (nonatomic, readonly) CLLocationDirection currentHeading;

- (void)startWithRoute:(MKRoute *)route;
- (void)pause;
- (void)resume;
- (void)stop;

+ (double)speedMetersPerSecondForMode:(LSTransportMode)mode customSpeedKmh:(double)customSpeedKmh;
+ (double)horizontalAccuracyForMode:(LSTransportMode)mode;

@end

NS_ASSUME_NONNULL_END
