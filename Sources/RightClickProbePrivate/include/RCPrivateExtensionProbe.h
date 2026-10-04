#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Lists class and instance methods for a runtime class. Used only by the
/// feasibility probe to see whether NSExtension is present. Not a product API.
NSArray<NSString *> *RCProbeCopyMethodNames(NSString *className);

/// Attempts the undocumented NSExtension matching entry point, if it exists.
/// The completion receives JSON-ready dictionaries describing matched extensions,
/// or an error when the class or method is absent.
void RCProbeMatchExtensions(NSDictionary *attributes, void (^completion)(NSArray * _Nullable items, NSError * _Nullable error));

NS_ASSUME_NONNULL_END
