#import <Foundation/Foundation.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

BOOL LSClassDefinesInstanceMethodLocally(Class cls, SEL selector);
Class LSClassDefiningInstanceMethod(Class cls, SEL selector);
BOOL LSInstallInstanceHook(Class cls, SEL originalSelector, SEL hookSelector, Class templateClass);
BOOL LSInstallInstanceHookWithIMP(Class cls, SEL originalSelector, SEL hookSelector, IMP hookIMP);

NS_ASSUME_NONNULL_END
