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

BOOL LSInstallInstanceHookWithIMP(Class cls, SEL originalSelector, SEL hookSelector, IMP hookIMP) {
    if (!cls || !originalSelector || !hookSelector || !hookIMP) {
        return NO;
    }

    Method originalMethod = LSGetInstanceMethodDefinedOnClass(cls, originalSelector);
    if (!originalMethod) {
        return NO;
    }

    if (!LSClassDefinesInstanceMethodLocally(cls, hookSelector)) {
        if (!class_addMethod(cls,
                             hookSelector,
                             hookIMP,
                             method_getTypeEncoding(originalMethod))) {
            return NO;
        }
    }

    Method hookMethod = LSGetInstanceMethodDefinedOnClass(cls, hookSelector);
    if (!hookMethod) {
        return NO;
    }

    method_exchangeImplementations(originalMethod, hookMethod);
    return YES;
}

BOOL LSInstallInstanceHook(Class cls, SEL originalSelector, SEL hookSelector, Class templateClass) {
    if (!templateClass) {
        return NO;
    }

    Method templateMethod = class_getInstanceMethod(templateClass, hookSelector);
    if (!templateMethod) {
        return NO;
    }

    return LSInstallInstanceHookWithIMP(cls,
                                      originalSelector,
                                      hookSelector,
                                      method_getImplementation(templateMethod));
}
