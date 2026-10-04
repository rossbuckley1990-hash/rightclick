#import "RCPrivateExtensionProbe.h"
#import <objc/message.h>
#import <objc/runtime.h>

NSArray<NSString *> *RCProbeCopyMethodNames(NSString *className) {
    Class cls = NSClassFromString(className);
    if (cls == Nil) {
        return @[];
    }

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    unsigned int classCount = 0;
    Method *classMethods = class_copyMethodList(object_getClass((id)cls), &classCount);
    for (unsigned int i = 0; i < classCount; i++) {
        [names addObject:[@"+" stringByAppendingString:NSStringFromSelector(method_getName(classMethods[i]))]];
    }
    free(classMethods);

    unsigned int instanceCount = 0;
    Method *instanceMethods = class_copyMethodList(cls, &instanceCount);
    for (unsigned int i = 0; i < instanceCount; i++) {
        [names addObject:[@"-" stringByAppendingString:NSStringFromSelector(method_getName(instanceMethods[i]))]];
    }
    free(instanceMethods);
    return names;
}

static NSDictionary *RCDescribeExtension(id extensionObject) {
    if (extensionObject == nil) {
        return @{};
    }
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"class"] = NSStringFromClass([extensionObject class]);
    info[@"description"] = [[extensionObject description] substringToIndex:MIN((NSUInteger)500, [[extensionObject description] length])];

    NSArray<NSString *> *selectors = @[
        @"identifier",
        @"version",
        @"infoDictionary",
        @"extensionPointIdentifier",
        @"_plugIn",
    ];
    for (NSString *name in selectors) {
        SEL sel = NSSelectorFromString(name);
        if (![extensionObject respondsToSelector:sel]) {
            continue;
        }
        id (*fn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id value = fn(extensionObject, sel);
        if (value == nil) {
            continue;
        }
        if ([value isKindOfClass:[NSDictionary class]] || [value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]]) {
            info[name] = value;
        } else {
            info[name] = [value description];
        }
    }
    return info;
}

void RCProbeMatchExtensions(NSDictionary *attributes, void (^completion)(NSArray * _Nullable items, NSError * _Nullable error)) {
    Class cls = NSClassFromString(@"NSExtension");
    SEL sel = NSSelectorFromString(@"beginMatchingExtensionsWithAttributes:completion:");
    if (cls == Nil || ![cls respondsToSelector:sel]) {
        NSString *reason = cls == Nil
            ? @"NSExtension class is not present in the public or loaded runtime"
            : @"beginMatchingExtensionsWithAttributes:completion: is not available";
        NSError *error = [NSError errorWithDomain:@"RightClickProbe" code:404 userInfo:@{NSLocalizedDescriptionKey: reason}];
        completion(nil, error);
        return;
    }

    void (^wrapped)(NSArray *, NSError *) = ^(NSArray *extensions, NSError *error) {
        if (error != nil || extensions == nil) {
            completion(nil, error);
            return;
        }
        NSMutableArray *described = [NSMutableArray arrayWithCapacity:extensions.count];
        for (id extensionObject in extensions) {
            [described addObject:RCDescribeExtension(extensionObject)];
        }
        completion(described, nil);
    };

    void (*fn)(id, SEL, NSDictionary *, id) = (void (*)(id, SEL, NSDictionary *, id))objc_msgSend;
    fn((id)cls, sel, attributes, wrapped);
}
