#import <UIKit/UIKit.h>

// AiFlex2 面板与 MCP 设置页共用的视觉组件：
// 整页渐变背景、玻璃卡片、图标+标题/副标题行、分区标题与脚注。
// 运行时探测 iOS 26 的 UIGlassEffect，低版本退回系统毛玻璃，行为一致。

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT UIVisualEffect * _Nullable AXGlassEffect(void);

@interface AXGradientView : UIView
@property (nonatomic, copy, nullable) NSArray *colors;
@property (nonatomic, assign) CGPoint gradientStart;
@property (nonatomic, assign) CGPoint gradientEnd;
@end

@interface AXGlassCard : UIView
- (instancetype)initWithRadius:(CGFloat)radius;
@end

@interface AXRowView : UIControl
@property (nonatomic, strong, readonly) UILabel *titleLabel;
@property (nonatomic, strong, readonly) UILabel *subtitleLabel;
@property (nonatomic, strong, readonly) UILabel *valueLabel;
@property (nonatomic, strong, readonly) UISwitch *toggle;
@property (nonatomic, copy, nullable) void (^onTap)(void);
@property (nonatomic, copy, nullable) void (^onToggle)(BOOL on);
- (void)setSymbol:(NSString *)symbol tint:(UIColor *)tint;
- (void)setValueText:(nullable NSString *)text;
- (void)setShowsChevron:(BOOL)shows;
- (void)setShowsSwitch:(BOOL)shows;
@end

// 整页背景：钉住宿主视图四边，渐变随页面高度铺满，不会在中途截断。
FOUNDATION_EXPORT AXGradientView * _Nullable AXInstallBackdrop(UIView *host);

FOUNDATION_EXPORT UILabel *AXSectionLabel(NSString *text);
FOUNDATION_EXPORT UILabel *AXFootnoteLabel(NSString *text);
FOUNDATION_EXPORT UIView *AXSeparatorView(void);
FOUNDATION_EXPORT UIStackView * _Nullable AXSectionView(NSString * _Nullable title,
                                             UIView *card,
                                             NSString * _Nullable footnote);
FOUNDATION_EXPORT AXGlassCard *AXCardWithRows(NSArray<UIView *> *rows, CGFloat radius);
FOUNDATION_EXPORT UIBarButtonItem *AXCheckmarkItem(id target, SEL action);

// 导航栏统一成液态玻璃：去掉 hairline 分割线，改成半透明 + 模糊，
// 滚动内容从栏下透上来，与页面玻璃卡片同一观感。
FOUNDATION_EXPORT void AXApplyGlassNavigationBar(UINavigationBar * _Nullable bar);

#pragma mark - 玻璃弹窗

// 系统 UIAlertController 的观感跟页面脱节，这里用同一套玻璃卡片自绘弹窗：
// 深色遮罩 + 居中玻璃卡 + 纵向按钮，输入框与代码块都按页面配色。
typedef NS_ENUM(NSInteger, AXAlertButtonStyle) {
    AXAlertButtonStylePrimary = 0,   // 蓝底白字，主操作
    AXAlertButtonStyleSecondary,     // 淡底，次级操作
    AXAlertButtonStyleInline,        // 与相邻 inline 按钮并排成一行
    AXAlertButtonStyleDestructive,   // 淡红底红字，破坏性操作
    AXAlertButtonStyleCancel         // 纯文字，取消
};

typedef NS_ENUM(NSInteger, AXAlertMessageStyle) {
    AXAlertMessageStyleText = 0,     // 普通说明文字
    AXAlertMessageStyleCode          // 等宽、可选中复制（令牌/地址等值）
};

@class AXGlassAlert;

@interface AXAlertButton : NSObject
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, assign, readonly) AXAlertButtonStyle style;
@property (nonatomic, copy, readonly, nullable) void (^handler)(AXGlassAlert *alert);
+ (instancetype)buttonWithTitle:(NSString *)title
                          style:(AXAlertButtonStyle)style
                        handler:(void (^ _Nullable)(AXGlassAlert *alert))handler;
@end

@interface AXGlassAlert : NSObject
@property (nonatomic, strong, readonly, nullable) UITextField *textField; // 无输入框时为 nil
@property (nonatomic, copy, readonly) NSString *text;                     // 输入框内容，无输入框为空串
- (void)dismiss;
@end

// 展示在宿主所在窗口上，不依赖 host 的 present 通道，因此不会和 FLEX 自己的弹层打架。
FOUNDATION_EXPORT AXGlassAlert * _Nullable AXPresentAlert(UIViewController *host,
                                                          NSString * _Nullable title,
                                                          NSString * _Nullable message,
                                                          AXAlertMessageStyle messageStyle,
                                                          void (^ _Nullable configureTextField)(UITextField *field),
                                                          NSArray<AXAlertButton *> *buttons);

// 当前是否有玻璃弹窗挡在最前面：AI 走界面自动化前要先让用户处理完。
FOUNDATION_EXPORT BOOL AXGlassAlertVisible(void);

NS_ASSUME_NONNULL_END
