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

NS_ASSUME_NONNULL_END
