//
//  FLEXWindow.m
//  Flipboard
//
//  由 Ryan Olson 创建于 4/13/14.
//  版权所有 (c) 2020 FLEX Team. 保留所有权利。
//

#import "FLEXWindow.h"
#import "FLEXUtility.h"
#import <objc/runtime.h>

@implementation FLEXWindow

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // 一些应用程序的窗口级别为 UIWindowLevelStatusBar + n。
        // 如果我们将窗口级别设置得太高，会遮挡 UIAlertViews。
        // 在保持在应用程序窗口之上和保持在提醒之下之间需要平衡。
        self.windowLevel = UIWindowLevelAlert - 1;
    }
    return self;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return [self.eventDelegate shouldHandleTouchAtPoint:point];
}

- (BOOL)shouldAffectStatusBarAppearance {
    // 面板顶部是不透明栏，状态栏若继续跟随宿主（宿主可能是浅色文字），
    // 白底配白字就看不清了。
    // 只在真正打开了 FLEX 页面（有 modal）时接管状态栏，
    // 悬浮工具栏状态下仍然交还宿主，避免误改宿主样式。
    if (self.isHidden) return NO;
    return self.rootViewController.presentedViewController != nil;
}

- (BOOL)canBecomeKeyWindow {
    return [self.eventDelegate canBecomeKeyWindow];
}

- (void)makeKeyWindow {
    _previousKeyWindow = FLEXUtility.appKeyWindow;
    [super makeKeyWindow];
}

- (void)resignKeyWindow {
    [super resignKeyWindow];
    _previousKeyWindow = nil;
}

+ (void)initialize {
    // 这在运行时添加了一个方法（覆盖父类），使我们获得了想要的状态栏行为。
    // FLEX 窗口旨在作为叠加层，通常不影响下方的应用程序。
    // 大多数情况下，我们希望应用程序的主窗口控制状态栏行为。
    // 在运行时使用混淆的选择器完成，因为这是私有 API。但是无论如何你不应该将此提交到 App Store...
    NSString *canAffectSelectorString = [@[@"_can", @"Affect", @"Status", @"Bar", @"Appearance"] componentsJoinedByString:@""];
    SEL canAffectSelector = NSSelectorFromString(canAffectSelectorString);
    Method shouldAffectMethod = class_getInstanceMethod(self, @selector(shouldAffectStatusBarAppearance));
    IMP canAffectImplementation = method_getImplementation(shouldAffectMethod);
    class_addMethod(self, canAffectSelector, canAffectImplementation, method_getTypeEncoding(shouldAffectMethod));

    // 再来一个...
    NSString *canBecomeKeySelectorString = [NSString stringWithFormat:@"_%@", NSStringFromSelector(@selector(canBecomeKeyWindow))];
    SEL canBecomeKeySelector = NSSelectorFromString(canBecomeKeySelectorString);
    Method canBecomeKeyMethod = class_getInstanceMethod(self, @selector(canBecomeKeyWindow));
    IMP canBecomeKeyImplementation = method_getImplementation(canBecomeKeyMethod);
    class_addMethod(self, canBecomeKeySelector, canBecomeKeyImplementation, method_getTypeEncoding(canBecomeKeyMethod));
}

@end
