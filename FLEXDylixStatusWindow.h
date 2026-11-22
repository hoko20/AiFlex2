#import <UIKit/UIKit.h>

/// A non-key, pass-through window. Only the compact status capsule receives touches.
@interface FLEXDylixStatusWindow : UIWindow
@property (nonatomic,copy) dispatch_block_t openChat;
@property (nonatomic,readonly) UIButton *capsule;
/// 当前前台场景。iOS 13 之后窗口不绑定 windowScene 就不会显示，这里统一取一个可用场景。
+ (UIWindowScene *)activeScene;
/// 显示前补齐 scene：先按 keyWindow 取，取不到再遍历 connectedScenes。
- (void)attachToBestScene;
- (void)updateTitle:(NSString *)title detail:(NSString *)detail color:(UIColor *)color busy:(BOOL)busy;
- (void)clampToSafeArea;
@end
