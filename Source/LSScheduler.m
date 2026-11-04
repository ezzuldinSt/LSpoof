#import "LSScheduler.h"
#import "SessionController.h"
#import "PersistenceManager.h"
#import "LSRoute.h"
#import <UIKit/UIKit.h>

NSNotificationName const LSSchedulerDidChangeNotification = @"LSSchedulerDidChange";

static NSString * const kLSScheduleKey = @"LSSchedule";
static const NSTimeInterval kLSRouteGrace = 15 * 60;

static NSString *LSTimeText(NSDate *date) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    BOOL today = [NSCalendar.currentCalendar isDateInToday:date];
    BOOL tomorrow = [NSCalendar.currentCalendar isDateInTomorrow:date];
    formatter.dateStyle = today || tomorrow ? NSDateFormatterNoStyle : NSDateFormatterMediumStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;
    NSString *time = [formatter stringFromDate:date];
    return tomorrow ? [NSString stringWithFormat:@"tomorrow %@", time] : time;
}

@interface LSSchedule ()
@property (nonatomic, readwrite) BOOL isRoute;
@property (nonatomic, readwrite, copy) NSString *name;
@property (nonatomic, readwrite) NSDate *startDate;
@property (nonatomic, readwrite, nullable) NSDate *endDate;
@property (nonatomic, readwrite) BOOL repeatsDaily;
@property (nonatomic, readwrite) BOOL isActive;
@end

@implementation LSSchedule
- (NSString *)summary {
    NSString *what = self.isRoute ? [NSString stringWithFormat:@"Route “%@”", self.name] : [NSString stringWithFormat:@"“%@”", self.name];
    NSMutableString *text = [NSMutableString stringWithString:what];
    if (self.isActive) [text appendString:@" is on"];
    else [text appendFormat:@" starts %@", LSTimeText(self.startDate)];
    if (self.endDate) [text appendFormat:@", turns off %@", LSTimeText(self.endDate)];
    if (self.repeatsDaily) [text appendString:@", every day"];
    return text;
}
@end

@interface LSScheduler ()
@property (nonatomic, strong) NSUserDefaults *defaults;
@property (nonatomic, strong, nullable) NSTimer *timer;
@property (nonatomic, copy, nullable) NSString *notice;
@property (nonatomic) BOOL activated;
@end

@implementation LSScheduler

+ (LSScheduler *)shared {
    static LSScheduler *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) _defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.locationspoofer.dylib"];
    return self;
}

- (void)activate {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self activate]; }); return; }
    if (self.activated) return;
    self.activated = YES;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[ UIApplicationDidBecomeActiveNotification, UIApplicationWillEnterForegroundNotification,
                                       UIApplicationSignificantTimeChangeNotification, NSSystemClockDidChangeNotification ]) {
        [center addObserver:self selector:@selector(clockChanged:) name:name object:nil];
    }
    [self evaluate];
}

- (void)clockChanged:(NSNotification *)note {
    (void)note;
    dispatch_async(dispatch_get_main_queue(), ^{ [self evaluate]; });
}

#pragma mark - Stored form

- (NSDictionary *)stored {
    id value = [self.defaults objectForKey:kLSScheduleKey];
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *stored = value;
    if (![stored[@"start"] isKindOfClass:NSDate.class] || ![stored[@"kind"] isKindOfClass:NSString.class]) return nil;
    if (stored[@"end"] && ![stored[@"end"] isKindOfClass:NSDate.class]) return nil;
    return stored;
}

- (void)store:(NSDictionary *)value {
    if (value) [self.defaults setObject:value forKey:kLSScheduleKey];
    else [self.defaults removeObjectForKey:kLSScheduleKey];
    [NSNotificationCenter.defaultCenter postNotificationName:LSSchedulerDidChangeNotification object:self];
}

- (LSSchedule *)schedule {
    NSDictionary *stored = [self stored];
    if (!stored) return nil;
    LSSchedule *schedule = [[LSSchedule alloc] init];
    schedule.isRoute = [stored[@"kind"] isEqualToString:@"route"];
    schedule.name = [stored[@"name"] isKindOfClass:NSString.class] ? stored[@"name"] : (schedule.isRoute ? @"Route" : @"Location");
    schedule.startDate = stored[@"start"];
    schedule.endDate = stored[@"end"];
    schedule.repeatsDaily = [stored[@"daily"] boolValue];
    schedule.isActive = [stored[@"active"] boolValue];
    return schedule;
}

static NSString *LSCleanName(NSString *name, NSString *fallback) {
    NSString *trimmed = [name isKindOfClass:NSString.class] ? [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
    if (trimmed.length > 120) trimmed = [trimmed substringToIndex:120];
    return trimmed.length ? trimmed : fallback;
}

- (BOOL)validStart:(NSDate *)start end:(NSDate *)end {
    if (![start isKindOfClass:NSDate.class] || !isfinite(start.timeIntervalSinceReferenceDate)) return NO;
    if (end && (![end isKindOfClass:NSDate.class] || [end timeIntervalSinceDate:start] < 60)) return NO;
    // A start in the past runs now; a year ahead is almost certainly a typo.
    return [start timeIntervalSinceNow] < 366 * 24 * 3600;
}

- (BOOL)scheduleLocation:(CLLocationCoordinate2D)coordinate name:(NSString *)name radiusOverride:(double)radius
                   start:(NSDate *)start end:(NSDate *)end repeatsDaily:(BOOL)daily {
    if (!NSThread.isMainThread || !CLLocationCoordinate2DIsValid(coordinate) || ![self validStart:start end:end]) return NO;
    NSMutableDictionary *value = [@{ @"v": @1, @"kind": @"location", @"start": start, @"daily": @(daily), @"active": @NO,
                                     @"name": LSCleanName(name, @"Scheduled location"),
                                     @"lat": @(coordinate.latitude), @"lon": @(coordinate.longitude) } mutableCopy];
    if (end) value[@"end"] = end;
    if (isfinite(radius) && radius >= 0 && radius <= 1000) value[@"radius"] = @(radius);
    [self store:value];
    [self evaluate];
    return YES;
}

- (BOOL)scheduleRoute:(LSRoute *)route options:(LSPlaybackOptions *)options name:(NSString *)name
                start:(NSDate *)start end:(NSDate *)end repeatsDaily:(BOOL)daily {
    if (!NSThread.isMainThread || !route || !options.isValid || ![self validStart:start end:end]) return NO;
    NSDictionary *routeValue = route.dictionaryRepresentation;
    if (![LSRoute routeFromDictionary:routeValue]) return NO;
    NSMutableDictionary *value = [@{ @"v": @1, @"kind": @"route", @"start": start, @"daily": @(daily), @"active": @NO,
                                     @"name": LSCleanName(name, route.name.length ? route.name : @"Route"),
                                     @"route": routeValue, @"options": options.dictionaryRepresentation } mutableCopy];
    if (end) value[@"end"] = end;
    [self store:value];
    [self evaluate];
    return YES;
}

- (void)cancel {
    [self.timer invalidate];
    self.timer = nil;
    [self store:nil];
}

- (NSString *)takeNotice {
    NSString *notice = self.notice;
    self.notice = nil;
    return notice;
}

#pragma mark - Clock

// Moves a daily schedule to its next start after now, or removes a one-off.
- (void)finishOccurrence:(NSDictionary *)stored {
    if (![stored[@"daily"] boolValue]) { [self store:nil]; return; }
    NSMutableDictionary *next = [stored mutableCopy];
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDate *start = stored[@"start"], *end = stored[@"end"];
    NSDate *now = NSDate.date;
    NSInteger days = 0;
    NSDate *candidate = start;
    while ([candidate compare:now] != NSOrderedDescending && days < 400) {
        days++;
        candidate = [calendar dateByAddingUnit:NSCalendarUnitDay value:days toDate:start options:0];
    }
    next[@"start"] = candidate;
    if (end) next[@"end"] = [calendar dateByAddingUnit:NSCalendarUnitDay value:days toDate:end options:0];
    next[@"active"] = @NO;
    [self store:next];
}

- (BOOL)performStart:(NSDictionary *)stored {
    LSSessionController *session = LSSessionController.shared;
    if ([stored[@"kind"] isEqualToString:@"route"]) {
        LSRoute *route = [LSRoute routeFromDictionary:stored[@"route"]];
        LSPlaybackOptions *options = [LSPlaybackOptions optionsFromDictionary:stored[@"options"]];
        return route && options && [session startRoute:route options:options];
    }
    CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake([stored[@"lat"] doubleValue], [stored[@"lon"] doubleValue]);
    double radius = [stored[@"radius"] isKindOfClass:NSNumber.class] ? [stored[@"radius"] doubleValue] : NAN;
    if (![session applyStaticCoordinate:coordinate radiusOverride:radius]) return NO;
    [PersistenceManager.shared recordRecentCoordinate:coordinate name:stored[@"name"]];
    return YES;
}

- (void)arm:(NSDate *)date {
    [self.timer invalidate];
    NSTimeInterval delay = MAX(0.5, [date timeIntervalSinceNow]);
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:delay repeats:NO block:^(__unused NSTimer *timer) { [weakSelf evaluate]; }];
    self.timer.tolerance = 1.0;
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}

- (void)evaluate {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self evaluate]; }); return; }
    // Each pass either acts or arms the timer; bounded in case the stored dates are odd.
    for (int pass = 0; pass < 4; pass++) {
        NSDictionary *stored = [self stored];
        if (!stored) { [self.timer invalidate]; self.timer = nil; return; }
        NSDate *now = NSDate.date, *start = stored[@"start"], *end = stored[@"end"];
        BOOL route = [stored[@"kind"] isEqualToString:@"route"];
        NSString *name = stored[@"name"] ?: @"the schedule";
        if ([stored[@"active"] boolValue]) {
            if (end && [now compare:end] != NSOrderedAscending) {
                [LSSessionController.shared disable];
                [self finishOccurrence:stored];
                continue;
            }
            if (end) [self arm:end];
            return;
        }
        if (end && [now compare:end] != NSOrderedAscending) {
            self.notice = [NSString stringWithFormat:@"The scheduled start for “%@” was missed because the app wasn’t running.", name];
            [self finishOccurrence:stored];
            continue;
        }
        if ([now compare:start] == NSOrderedAscending) { [self arm:start]; return; }
        NSTimeInterval late = [now timeIntervalSinceDate:start];
        if (route && late > kLSRouteGrace) {
            self.notice = [NSString stringWithFormat:@"Skipped the scheduled route “%@”: the app wasn’t running at %@.", name, LSTimeText(start)];
            [self finishOccurrence:stored];
            continue;
        }
        BOOL started = [self performStart:stored];
        if (!started) self.notice = [NSString stringWithFormat:@"The scheduled start for “%@” could not run.", name];
        else if (late > 120) self.notice = [NSString stringWithFormat:@"Started “%@” late: the app wasn’t running at %@.", name, LSTimeText(start)];
        if (started && end) {
            NSMutableDictionary *active = [stored mutableCopy];
            active[@"active"] = @YES;
            [self store:active];
            [self arm:end];
            return;
        }
        [self finishOccurrence:stored];
    }
}

@end
