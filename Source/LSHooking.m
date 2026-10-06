#import "LSHooking.h"

Class LSClassDefiningInstanceMethod(Class cls, SEL selector) {
    if (!cls || !selector) {
        return Nil;
    }

    for (Class candidate = cls; candidate && candidate != [NSObject class]; candidate = class_getSuperclass(candidate)) {
        if (LSClassDefinesInstanceMethodLocally(candidate, selector)) {
            return candidate;
        }
    }
    return Nil;
}

BOOL LSClassDefinesInstanceMethodLocally(Class cls, SEL selector) {
    if (!cls || !selector) {
        return NO;
    }

    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);
    if (!methods) {
        return NO;
    }

    BOOL found = NO;
    for (unsigned int index = 0; index < methodCount; index++) {
        if (method_getName(methods[index]) == selector) {
            found = YES;
            break;
        }
    }
    free(methods);
    return found;
}

static Method LSGetInstanceMethodDefinedOnClass(Class cls, SEL selector) {
    if (!cls || !selector) {
        return NULL;
    }

    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);
    if (!methods) {
        return NULL;
    }

    Method found = NULL;
    for (unsigned int index = 0; index < methodCount; index++) {
        if (method_getName(methods[index]) == selector) {
            found = methods[index];
            break;
        }
    }
    free(methods);
    return found;
}

BOOL LSInstallInstanceHook(Class cls, SEL originalSelector, LSHookFactory factory) {
    if (!cls || !originalSelector || !factory) return NO;
    static NSObject *registrationLock;
    static NSMutableSet<NSString *> *installed;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        registrationLock = [[NSObject alloc] init];
        installed = [NSMutableSet set];
    });
    @synchronized(registrationLock) {
        NSString *key = [NSString stringWithFormat:@"%p:%@", cls, NSStringFromSelector(originalSelector)];
        if ([installed containsObject:key]) return YES;
        Method method = LSGetInstanceMethodDefinedOnClass(cls, originalSelector);
        if (!method) return NO;
        IMP replacement = factory(method_getImplementation(method));
        if (!replacement) return NO;
        // Each wrapper captures this method's original IMP and original selector.
        // A super call enters the superclass wrapper without redispatching an alias.
        method_setImplementation(method, replacement);
        [installed addObject:key];
        return YES;
    }
}
