#import <Foundation/Foundation.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

BOOL LSClassDefinesInstanceMethodLocally(Class cls, SEL selector);
Class LSClassDefiningInstanceMethod(Class cls, SEL selector);
typedef IMP _Nonnull (^LSHookFactory)(IMP originalImplementation);
BOOL LSInstallInstanceHook(Class cls, SEL originalSelector, LSHookFactory factory);

NS_ASSUME_NONNULL_END
