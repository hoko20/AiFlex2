#import "FLEXAiFlex2ViewController.h"
#import "FLEXAiFlexMCPServer.h"
#import "FLEXAiFlexRuntime.h"
#import "FLEXAiFlexSettingsViewController.h"
#import "FLEXManager.h"
#import "FLEXManager+Private.h"
#import "FLEXUtility.h"

static __weak FLEXAiFlex2ViewController *AXCurrentPanel;

static NSString *AXShortText(NSString *text, NSUInteger limit) {
    if (![text isKindOfClass:NSString.class] || !text.length) return @"";
    if (text.length <= limit) return text;
    return [[text substringToIndex:limit] stringByAppendingString:@"…"];
}

#pragma mark - Liquid Glass primitives

// iOS 26 起系统提供 UIGlassEffect。本 dylib 用较低 SDK 编译，所以只在运行时探测，
// 找不到（iOS 15–18）就退回系统毛玻璃材质，保证外观与可读性都不塌。
static UIVisualEffect *AXGlassEffect(void) {
    static UIVisualEffect *effect;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"UIGlassEffect");
        if (!cls) return;
        @try {
            SEL selector = @selector(effect);
            if ([cls respondsToSelector:selector]) {
                id (*function)(id, SEL) = (id (*)(id, SEL))[cls methodForSelector:selector];
                id value = function ? function(cls, selector) : nil;
                if ([value isKindOfClass:UIVisualEffect.class]) effect = value;
            }
        } @catch (__unused NSException *exception) {}
        if (!effect) {
            @try {
                id value = [[cls alloc] init];
                if ([value isKindOfClass:UIVisualEffect.class]) effect = value;
            } @catch (__unused NSException *exception) {}
        }
    });
    return effect;
}

@interface AXGradientView : UIView
@property (nonatomic, copy) NSArray *colors;
@property (nonatomic, assign) CGPoint gradientStart;
@property (nonatomic, assign) CGPoint gradientEnd;
@end

@implementation AXGradientView

+ (Class)layerClass { return CAGradientLayer.class; }

- (CAGradientLayer *)gradientLayer { return (CAGradientLayer *)self.layer; }

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.userInteractionEnabled = NO;
        self.gradientLayer.startPoint = CGPointMake(0, 0);
        self.gradientLayer.endPoint = CGPointMake(1, 1);
    }
    return self;
}

- (void)setColors:(NSArray *)colors {
    _colors = [colors copy];
    self.gradientLayer.colors = colors;
}

- (void)setGradientStart:(CGPoint)point {
    _gradientStart = point;
    self.gradientLayer.startPoint = point;
}

- (void)setGradientEnd:(CGPoint)point {
    _gradientEnd = point;
    self.gradientLayer.endPoint = point;
}

@end

// 玻璃卡片：有 UIGlassEffect 时就是系统液态玻璃，没有时是毛玻璃 + 极淡底色，
// 两种情况都保持圆角、描边和可读性一致。
@interface AXGlassCard : UIView
- (instancetype)initWithRadius:(CGFloat)radius;
@end

@implementation AXGlassCard {
    CGFloat _radius;
}

- (instancetype)initWithRadius:(CGFloat)radius {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _radius = radius;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.layer.cornerRadius = radius;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.clipsToBounds = YES;
    // 底色保证在玻璃不可用时也不会变成全透明卡片。
    self.backgroundColor = [UIColor.secondarySystemBackgroundColor colorWithAlphaComponent:0.78];

    UIVisualEffect *effect = AXGlassEffect();
    if (!effect) effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
    UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:effect];
    glass.translatesAutoresizingMaskIntoConstraints = NO;
    glass.userInteractionEnabled = NO;
    // 玻璃只做背景：始终压在最底层，后续添加的内容自然在它上面。
    [self insertSubview:glass atIndex:0];
    [NSLayoutConstraint activateConstraints:@[
        [glass.topAnchor constraintEqualToAnchor:self.topAnchor],
        [glass.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [glass.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [glass.bottomAnchor constraintEqualToAnchor:self.bottomAnchor]
    ]];
    [self updateStroke];
    return self;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (!previous) return;
    if (previous.userInterfaceStyle == self.traitCollection.userInterfaceStyle) return;
    [self updateStroke];
}

- (void)updateStroke {
    self.layer.borderWidth = 0.5;
    self.layer.borderColor = [UIColor.separatorColor
        resolvedColorWithTraitCollection:self.traitCollection].CGColor;
}

@end

// 单行条目：图标磁贴 + 标题/副标题 + 右侧值/开关/箭头。
@interface AXRowView : UIControl
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) UISwitch *toggle;
@property (nonatomic, copy) void (^onTap)(void);
@property (nonatomic, copy) void (^onToggle)(BOOL on);
- (void)setSymbol:(NSString *)symbol tint:(UIColor *)tint;
- (void)setValueText:(NSString *)text;
- (void)setShowsChevron:(BOOL)shows;
- (void)setShowsSwitch:(BOOL)shows;
@end

@implementation AXRowView {
    UIView *_tile;
    UIImageView *_icon;
    UIImageView *_chevron;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.backgroundColor = UIColor.clearColor;

    _tile = [UIView new];
    _tile.translatesAutoresizingMaskIntoConstraints = NO;
    _tile.layer.cornerRadius = 9;
    _tile.layer.cornerCurve = kCACornerCurveContinuous;
    [self addSubview:_tile];

    _icon = [UIImageView new];
    _icon.translatesAutoresizingMaskIntoConstraints = NO;
    _icon.contentMode = UIViewContentModeScaleAspectFit;
    [_tile addSubview:_icon];

    _titleLabel = [UILabel new];
    _titleLabel.font = [UIFont systemFontOfSize:16];
    _titleLabel.textColor = UIColor.labelColor;

    _subtitleLabel = [UILabel new];
    _subtitleLabel.font = [UIFont systemFontOfSize:12];
    _subtitleLabel.textColor = UIColor.secondaryLabelColor;
    _subtitleLabel.numberOfLines = 2;
    _subtitleLabel.hidden = YES;

    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _subtitleLabel]];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 2;
    texts.alignment = UIStackViewAlignmentFill;
    texts.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:texts];

    _valueLabel = [UILabel new];
    _valueLabel.font = [UIFont monospacedSystemFontOfSize:12.5 weight:UIFontWeightRegular];
    _valueLabel.textColor = UIColor.secondaryLabelColor;
    _valueLabel.textAlignment = NSTextAlignmentRight;
    _valueLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _valueLabel.hidden = YES;
    [_valueLabel setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];
    [_valueLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    _chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold]]];
    _chevron.tintColor = UIColor.tertiaryLabelColor;
    _chevron.contentMode = UIViewContentModeScaleAspectFit;
    _chevron.hidden = YES;
    [_chevron.widthAnchor constraintEqualToConstant:9].active = YES;

    _toggle = [UISwitch new];
    _toggle.hidden = YES;
    [_toggle addTarget:self action:@selector(toggleFired) forControlEvents:UIControlEventValueChanged];

    UIStackView *trailing = [[UIStackView alloc] initWithArrangedSubviews:@[_valueLabel, _toggle, _chevron]];
    trailing.axis = UILayoutConstraintAxisHorizontal;
    trailing.spacing = 8;
    trailing.alignment = UIStackViewAlignmentCenter;
    trailing.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:trailing];

    [NSLayoutConstraint activateConstraints:@[
        [_tile.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [_tile.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_tile.widthAnchor constraintEqualToConstant:30],
        [_tile.heightAnchor constraintEqualToConstant:30],
        [_icon.centerXAnchor constraintEqualToAnchor:_tile.centerXAnchor],
        [_icon.centerYAnchor constraintEqualToAnchor:_tile.centerYAnchor],
        [_icon.widthAnchor constraintEqualToConstant:17],
        [_icon.heightAnchor constraintEqualToConstant:17],
        [texts.leadingAnchor constraintEqualToAnchor:_tile.trailingAnchor constant:12],
        [texts.trailingAnchor constraintLessThanOrEqualToAnchor:trailing.leadingAnchor constant:-8],
        [texts.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [texts.topAnchor constraintGreaterThanOrEqualToAnchor:self.topAnchor constant:11],
        [texts.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor constant:-11],
        [trailing.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [trailing.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.heightAnchor constraintGreaterThanOrEqualToConstant:54]
    ]];

    // 让行高跟着文字长，而不是把两行副标题压扁截断。
    [_titleLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    [_subtitleLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];

    [self addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    return self;
}

- (void)setSymbol:(NSString *)symbol tint:(UIColor *)tint {
    _icon.image = [UIImage systemImageNamed:symbol
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold]];
    _icon.tintColor = tint;
    _tile.backgroundColor = [tint colorWithAlphaComponent:0.15];
}

- (void)setValueText:(NSString *)text {
    _valueLabel.text = text;
    _valueLabel.hidden = text.length == 0;
}

- (void)setShowsChevron:(BOOL)shows {
    _chevron.hidden = !shows;
    if (shows) self.userInteractionEnabled = YES;
}

- (void)setShowsSwitch:(BOOL)shows {
    _toggle.hidden = !shows;
    if (shows) self.userInteractionEnabled = YES;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.backgroundColor = highlighted
        ? [UIColor.labelColor colorWithAlphaComponent:0.06]
        : UIColor.clearColor;
}

- (void)tapped {
    if (self.onTap) self.onTap();
}

- (void)toggleFired {
    if (self.onToggle) self.onToggle(self.toggle.isOn);
}

@end

#pragma mark - Panel

@interface FLEXAiFlex2ViewController ()
@property (nonatomic, copy) NSString *report;
@property (nonatomic, copy) NSString *className;
@property (nonatomic) BOOL minimized;
@property (nonatomic) BOOL uiTransitioning;

@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIRefreshControl *axRefreshControl;

@property (nonatomic, strong) UIView *statusChip;
@property (nonatomic, strong) UIView *statusDot;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *endpointLabel;
@property (nonatomic, strong) UILabel *tokenLabel;
@property (nonatomic, strong) UILabel *heroSubtitle;

@property (nonatomic, strong) AXRowView *contextObjectRow;
@property (nonatomic, strong) AXRowView *contextReportRow;
@property (nonatomic, strong) AXRowView *restartRow;
@property (nonatomic, copy) NSArray<UISwitch *> *permissionSwitches;
@property (nonatomic, copy) NSArray<AXRowView *> *toolRowViews;
@property (nonatomic, strong) UILabel *permissionFootnote;
- (void)showBuildFailure:(NSString *)reason;
@end

@implementation FLEXAiFlex2ViewController

+ (instancetype)aiFlex2CurrentPanel { return AXCurrentPanel; }

- (instancetype)initWithReport:(NSString *)report className:(NSString *)className {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _report = [report copy] ?: @"";
        _className = [className copy] ?: @"未知对象";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    AXCurrentPanel = self;
    self.title = @"AiFlex2";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"chevron.down"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(collapseTapped)];
    self.navigationItem.leftBarButtonItem.accessibilityLabel = @"收起面板，MCP 继续运行";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self
                             action:@selector(doneTapped)];

    // 顶部一抹柔光，给玻璃卡片提供可折射的底色；不依赖任何 iOS 26 专属 API。
    AXGradientView *bloom = [AXGradientView new];
    bloom.colors = @[
        (__bridge id)[[UIColor systemBlueColor] colorWithAlphaComponent:0.22].CGColor,
        (__bridge id)[[UIColor systemIndigoColor] colorWithAlphaComponent:0.10].CGColor,
        (__bridge id)[UIColor clearColor].CGColor
    ];
    bloom.gradientStart = CGPointMake(0.15, 0);
    bloom.gradientEnd = CGPointMake(0.85, 0.55);
    [self.view insertSubview:bloom atIndex:0];
    [NSLayoutConstraint activateConstraints:@[
        [bloom.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [bloom.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [bloom.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [bloom.heightAnchor constraintEqualToAnchor:self.view.heightAnchor multiplier:0.55]
    ]];

    self.scrollView = [UIScrollView new];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.showsVerticalScrollIndicator = YES;
    self.scrollView.backgroundColor = UIColor.clearColor;
    // 关掉自动 inset 调整，直接把滚动视图钉在安全区里：内容起点由约束决定，
    // 不会再受导航栏/外层容器时序影响。
    self.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self.view addSubview:self.scrollView];
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];

    self.axRefreshControl = [UIRefreshControl new];
    [self.axRefreshControl addTarget:self action:@selector(refresh) forControlEvents:UIControlEventValueChanged];
    [self.scrollView addSubview:self.axRefreshControl];

    // 建页失败时给出可见提示，而不是留下一片空白让人猜。
    @try {
        [self buildContent];
    } @catch (NSException *exception) {
        [self showBuildFailure:exception.reason ?: exception.name];
        return;
    }
    [self refresh];
}

- (void)showBuildFailure:(NSString *)reason {
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont systemFontOfSize:13];
    label.textColor = UIColor.secondaryLabelColor;
    label.text = [NSString stringWithFormat:@"面板渲染失败\n%@", reason ?: @"未知原因"];
    [self.view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [label.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [label.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:24],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-24]
    ]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh];
}

// 不覆盖导航栏 appearance：交给系统默认样式，iOS 26 下自动是液态玻璃导航栏。
- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleDarkContent;
}

#pragma mark - Layout

- (void)buildContent {
    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self buildHero],
        [self sectionWithTitle:@"当前现场" card:[self buildContextCard] footnote:nil],
        [self sectionWithTitle:@"快捷操作" card:[self buildActionsCard] footnote:nil],
        [self sectionWithTitle:@"授权" card:[self buildPermissionCard] footnote:nil],
        [self sectionWithTitle:@"可用工具" card:[self buildToolsCard]
                      footnote:@"工具组关闭后，对应工具不会出现在 MCP tools/list 中。"],
        [self sectionWithTitle:@"使用方式" card:[self buildUsageCard] footnote:nil]
    ]];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 24;
    content.alignment = UIStackViewAlignmentFill;
    content.translatesAutoresizingMaskIntoConstraints = NO;

    // 用一层朴素容器托住栈：滚动视图只负责尺寸，内容高度完全由容器与栈决定，
    // 避免栈直接挂在 contentLayoutGuide 上时被外层滚动容器压缩成零高。
    UIView *container = [UIView new];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:content];
    [self.scrollView addSubview:container];

    [NSLayoutConstraint activateConstraints:@[
        [container.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor],
        [container.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor],
        [container.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor],
        [container.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor],
        [container.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor],
        [content.topAnchor constraintEqualToAnchor:container.topAnchor constant:12],
        [content.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [content.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [content.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-36]
    ]];
}

- (UIView *)sectionWithTitle:(NSString *)title card:(UIView *)card footnote:(NSString *)footnote {
    NSMutableArray *views = [NSMutableArray arrayWithObjects:[self sectionLabel:title], card, nil];
    if (footnote.length) [views addObject:[self footnoteLabel:footnote]];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:views];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    stack.alignment = UIStackViewAlignmentFill;
    if (footnote.length) [stack setCustomSpacing:7 afterView:card];
    return stack;
}

- (UILabel *)sectionLabel:(NSString *)text {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    label.textColor = UIColor.secondaryLabelColor;
    return label;
}

- (UILabel *)footnoteLabel:(NSString *)text {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont systemFontOfSize:11.5];
    label.textColor = UIColor.tertiaryLabelColor;
    label.numberOfLines = 0;
    return label;
}

- (UIView *)separatorView {
    UIView *wrap = [UIView new];
    wrap.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *line = [UIView new];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    line.backgroundColor = [UIColor.labelColor colorWithAlphaComponent:0.08];
    [wrap addSubview:line];
    [NSLayoutConstraint activateConstraints:@[
        [line.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor constant:58],
        [line.trailingAnchor constraintEqualToAnchor:wrap.trailingAnchor],
        [line.topAnchor constraintEqualToAnchor:wrap.topAnchor],
        [line.bottomAnchor constraintEqualToAnchor:wrap.bottomAnchor],
        [line.heightAnchor constraintEqualToConstant:0.5]
    ]];
    return wrap;
}

- (AXGlassCard *)cardWithRows:(NSArray<UIView *> *)rows radius:(CGFloat)radius {
    AXGlassCard *card = [[AXGlassCard alloc] initWithRadius:radius];
    NSMutableArray *views = [NSMutableArray new];
    for (NSUInteger index = 0; index < rows.count; index++) {
        if (index) [views addObject:[self separatorView]];
        [views addObject:rows[index]];
    }
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:views];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];
    [card bringSubviewToFront:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:4],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-4]
    ]];
    return card;
}

#pragma mark - Hero

- (UIView *)buildHero {
    AXGlassCard *card = [[AXGlassCard alloc] initWithRadius:26];

    AXGradientView *badge = [AXGradientView new];
    badge.colors = @[
        (__bridge id)[UIColor systemBlueColor].CGColor,
        (__bridge id)[UIColor systemIndigoColor].CGColor
    ];
    badge.layer.cornerRadius = 15;
    badge.layer.cornerCurve = kCACornerCurveContinuous;
    badge.clipsToBounds = YES;
    UIImageView *spark = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"sparkles"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightSemibold]]];
    spark.tintColor = UIColor.whiteColor;
    spark.translatesAutoresizingMaskIntoConstraints = NO;
    [badge addSubview:spark];
    [NSLayoutConstraint activateConstraints:@[
        [badge.widthAnchor constraintEqualToConstant:52],
        [badge.heightAnchor constraintEqualToConstant:52],
        [spark.centerXAnchor constraintEqualToAnchor:badge.centerXAnchor],
        [spark.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor]
    ]];

    UILabel *title = [UILabel new];
    title.text = @"AiFlex2";
    title.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    title.textColor = UIColor.labelColor;

    UILabel *subtitle = [UILabel new];
    subtitle.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
    subtitle.textColor = UIColor.secondaryLabelColor;
    subtitle.lineBreakMode = NSLineBreakByTruncatingTail;
    self.heroSubtitle = subtitle;

    UIStackView *titles = [[UIStackView alloc] initWithArrangedSubviews:@[title, subtitle, [self buildStatusChip]]];
    titles.axis = UILayoutConstraintAxisVertical;
    titles.spacing = 3;
    titles.alignment = UIStackViewAlignmentFill;
    [titles setCustomSpacing:9 afterView:subtitle];

    UIStackView *head = [[UIStackView alloc] initWithArrangedSubviews:@[badge, titles]];
    head.axis = UILayoutConstraintAxisHorizontal;
    head.spacing = 13;
    head.alignment = UIStackViewAlignmentTop;

    UILabel *hint = [self footnoteLabel:@"轻点地址可修改 · 轻点令牌可复制 · 服务随宿主 App 生命周期运行"];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[head, [self buildFields], hint]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    stack.alignment = UIStackViewAlignmentFill;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];
    [card bringSubviewToFront:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16]
    ]];
    return card;
}

- (UIView *)buildStatusChip {
    UIView *chip = [UIView new];
    chip.translatesAutoresizingMaskIntoConstraints = NO;
    chip.layer.cornerRadius = 13;
    chip.clipsToBounds = YES;
    self.statusChip = chip;

    UIView *dot = [UIView new];
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    dot.layer.cornerRadius = 3;
    dot.layer.cornerCurve = kCACornerCurveContinuous;
    self.statusDot = dot;

    UILabel *label = [UILabel new];
    label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    self.statusLabel = label;

    UIStackView *inner = [[UIStackView alloc] initWithArrangedSubviews:@[dot, label]];
    inner.axis = UILayoutConstraintAxisHorizontal;
    inner.spacing = 6;
    inner.alignment = UIStackViewAlignmentCenter;
    inner.translatesAutoresizingMaskIntoConstraints = NO;
    [chip addSubview:inner];

    [NSLayoutConstraint activateConstraints:@[
        [dot.widthAnchor constraintEqualToConstant:6],
        [dot.heightAnchor constraintEqualToConstant:6],
        [inner.topAnchor constraintEqualToAnchor:chip.topAnchor constant:4.5],
        [inner.bottomAnchor constraintEqualToAnchor:chip.bottomAnchor constant:-4.5],
        [inner.leadingAnchor constraintEqualToAnchor:chip.leadingAnchor constant:9],
        [inner.trailingAnchor constraintEqualToAnchor:chip.trailingAnchor constant:-11]
    ]];

    UIView *row = [UIView new];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:chip];
    [NSLayoutConstraint activateConstraints:@[
        [chip.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [chip.topAnchor constraintEqualToAnchor:row.topAnchor],
        [chip.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        [chip.trailingAnchor constraintLessThanOrEqualToAnchor:row.trailingAnchor]
    ]];
    return row;
}

- (UILabel *)fieldValueLabel {
    UILabel *label = [UILabel new];
    label.font = [UIFont monospacedSystemFontOfSize:12.5 weight:UIFontWeightRegular];
    label.textColor = UIColor.labelColor;
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    label.userInteractionEnabled = YES;
    return label;
}

- (UIView *)buildFields {
    UIView *box = [UIView new];
    box.translatesAutoresizingMaskIntoConstraints = NO;
    box.backgroundColor = [UIColor.labelColor colorWithAlphaComponent:0.06];
    box.layer.cornerRadius = 15;
    box.layer.cornerCurve = kCACornerCurveContinuous;
    box.clipsToBounds = YES;

    self.endpointLabel = [self fieldValueLabel];
    self.tokenLabel = [self fieldValueLabel];

    UIView *endpoint = [self fieldRowSymbol:@"link"
                                    caption:@"访问地址"
                                      value:self.endpointLabel
                                     button:@"pencil"
                                     action:@selector(editEndpoint)];
    UIView *token = [self fieldRowSymbol:@"key.horizontal.fill"
                                 caption:@"访问令牌"
                                   value:self.tokenLabel
                                  button:@"square.on.square"
                                  action:@selector(copyToken)];

    UIStackView *rows = [[UIStackView alloc] initWithArrangedSubviews:@[endpoint, [self separatorView], token]];
    rows.axis = UILayoutConstraintAxisVertical;
    rows.spacing = 0;
    rows.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:rows];
    [NSLayoutConstraint activateConstraints:@[
        [rows.topAnchor constraintEqualToAnchor:box.topAnchor constant:2],
        [rows.leadingAnchor constraintEqualToAnchor:box.leadingAnchor],
        [rows.trailingAnchor constraintEqualToAnchor:box.trailingAnchor],
        [rows.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-2]
    ]];
    return box;
}

- (UIView *)fieldRowSymbol:(NSString *)symbol
                   caption:(NSString *)caption
                     value:(UILabel *)value
                    button:(NSString *)buttonSymbol
                    action:(SEL)action {
    UIView *row = [UIView new];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold]]];
    icon.tintColor = UIColor.secondaryLabelColor;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [row addSubview:icon];

    UILabel *cap = [UILabel new];
    cap.text = caption;
    cap.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold];
    cap.textColor = UIColor.tertiaryLabelColor;

    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[cap, value]];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 2;
    texts.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:texts];
    [texts addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:action]];

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setImage:[UIImage systemImageNamed:buttonSymbol
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold]]
            forState:UIControlStateNormal];
    button.tintColor = UIColor.secondaryLabelColor;
    button.backgroundColor = [UIColor.labelColor colorWithAlphaComponent:0.07];
    button.layer.cornerRadius = 9;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [row addSubview:button];

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:12],
        [icon.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:16],
        [icon.heightAnchor constraintEqualToConstant:16],
        [texts.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:10],
        [texts.trailingAnchor constraintEqualToAnchor:button.leadingAnchor constant:-10],
        [texts.topAnchor constraintEqualToAnchor:row.topAnchor constant:9],
        [texts.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-9],
        [button.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-10],
        [button.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [button.widthAnchor constraintEqualToConstant:30],
        [button.heightAnchor constraintEqualToConstant:30]
    ]];
    return row;
}

#pragma mark - Cards

- (AXRowView *)rowTitle:(NSString *)title
               subtitle:(NSString *)subtitle
                 symbol:(NSString *)symbol
                   tint:(UIColor *)tint {
    AXRowView *row = [[AXRowView alloc] initWithFrame:CGRectZero];
    row.titleLabel.text = title;
    if (subtitle.length) {
        row.subtitleLabel.text = subtitle;
        row.subtitleLabel.hidden = NO;
    }
    [row setSymbol:symbol tint:tint];
    return row;
}

- (AXGlassCard *)buildContextCard {
    __weak typeof(self) weakSelf = self;
    AXRowView *object = [self rowTitle:@"当前对象" subtitle:nil symbol:@"scope" tint:UIColor.systemBlueColor];
    object.userInteractionEnabled = NO;
    self.contextObjectRow = object;

    AXRowView *report = [self rowTitle:@"现场报告" subtitle:@"暂无" symbol:@"doc.text.magnifyingglass"
                                  tint:UIColor.systemIndigoColor];
    report.userInteractionEnabled = NO;
    report.subtitleLabel.numberOfLines = 2;
    self.contextReportRow = report;

    AXRowView *copy = [self rowTitle:@"复制现场报告" subtitle:nil symbol:@"doc.on.doc" tint:UIColor.systemBlueColor];
    [copy setShowsChevron:YES];
    copy.onTap = ^{ [weakSelf copyText:weakSelf.report message:@"已复制现场报告"]; };

    return [self cardWithRows:@[object, report, copy] radius:22];
}

- (AXGlassCard *)buildActionsCard {
    __weak typeof(self) weakSelf = self;

    AXRowView *config = [self rowTitle:@"复制 MCP 客户端配置" subtitle:nil
                                symbol:@"square.on.square" tint:UIColor.systemBlueColor];
    [config setShowsChevron:YES];
    config.onTap = ^{ [weakSelf copyClientConfiguration]; };

    AXRowView *enable = [self rowTitle:@"一键开启常用工具组" subtitle:nil
                                symbol:@"bolt.fill" tint:UIColor.systemOrangeColor];
    [enable setShowsChevron:YES];
    enable.onTap = ^{ [weakSelf enableAllGroupsTapped]; };

    AXRowView *settings = [self rowTitle:@"服务设置" subtitle:nil
                                  symbol:@"slider.horizontal.3" tint:UIColor.systemGrayColor];
    [settings setShowsChevron:YES];
    settings.onTap = ^{ [weakSelf openSettings]; };

    AXRowView *restart = [self rowTitle:@"重启 MCP 服务" subtitle:nil
                                 symbol:@"arrow.triangle.2.circlepath" tint:UIColor.systemGreenColor];
    [restart setShowsChevron:YES];
    restart.onTap = ^{ [weakSelf restartService]; };
    self.restartRow = restart;

    AXRowView *collapse = [self rowTitle:@"收起面板（回到 App）" subtitle:nil
                                  symbol:@"chevron.down.circle" tint:UIColor.systemBlueColor];
    collapse.titleLabel.textColor = UIColor.systemBlueColor;
    [collapse setShowsChevron:YES];
    collapse.onTap = ^{ [weakSelf collapseTapped]; };

    return [self cardWithRows:@[config, enable, settings, restart, collapse] radius:22];
}

- (UIView *)buildPermissionCard {
    __weak typeof(self) weakSelf = self;
    NSArray *titles = @[@"授权保护", @"敏感读取", @"界面控制", @"脚本执行", @"方法追踪"];
    NSArray *details = @[
        @"要求客户端携带 Bearer 令牌；关闭后同局域网可直接连接",
        @"头文件、日志/网络正文、文件搜索、截图、Keychain 元数据",
        @"点击、输入、滚动、手势、方法调用与高亮，会改变 App 状态",
        @"在 WKWebView 执行 JavaScript，可能改变网页状态",
        @"替换方法实现并记录调用，高风险，10 分钟自动停止"
    ];
    NSArray *symbols = @[@"lock.shield.fill", @"eye.fill", @"hand.tap.fill", @"curlybraces", @"waveform.path.ecg"];
    NSArray *tints = @[UIColor.systemGreenColor, UIColor.systemBlueColor, UIColor.systemIndigoColor,
                       UIColor.systemOrangeColor, UIColor.systemRedColor];

    NSMutableArray *rows = [NSMutableArray new];
    NSMutableArray *switches = [NSMutableArray new];
    for (NSInteger index = 0; index < (NSInteger)titles.count; index++) {
        AXRowView *row = [self rowTitle:titles[index] subtitle:details[index]
                                 symbol:symbols[index] tint:tints[index]];
        [row setShowsSwitch:YES];
        row.onToggle = ^(BOOL on) { [weakSelf permissionChanged:index on:on]; };
        [rows addObject:row];
        [switches addObject:row.toggle];
    }
    self.permissionSwitches = switches;

    AXGlassCard *card = [self cardWithRows:rows radius:22];

    self.permissionFootnote = [self footnoteLabel:@""];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[card, self.permissionFootnote]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    stack.alignment = UIStackViewAlignmentFill;
    return stack;
}

- (UIView *)buildUsageCard {
    AXRowView *row = [self rowTitle:@"MCP 客户端"
                           subtitle:@"在 Claude Desktop、Cursor、Cherry Studio 等客户端添加 Streamable HTTP 服务，URL 填上方访问地址；需要授权时在请求头加 Authorization: Bearer <访问令牌>。"
                             symbol:@"desktopcomputer" tint:UIColor.systemGrayColor];
    row.subtitleLabel.numberOfLines = 0;
    row.userInteractionEnabled = NO;
    return [self cardWithRows:@[row] radius:22];
}

- (AXGlassCard *)buildToolsCard {
    NSArray *items = [self toolItems];
    NSMutableArray *rows = [NSMutableArray new];
    NSMutableArray *views = [NSMutableArray new];
    for (NSDictionary *item in items) {
        AXRowView *row = [self rowTitle:item[@"name"] subtitle:item[@"detail"]
                                 symbol:@"checkmark.seal.fill" tint:UIColor.systemGreenColor];
        row.titleLabel.font = [UIFont monospacedSystemFontOfSize:13.5 weight:UIFontWeightSemibold];
        row.subtitleLabel.numberOfLines = 2;
        row.userInteractionEnabled = NO;
        [rows addObject:row];
        [views addObject:row];
    }
    self.toolRowViews = rows;
    return [self cardWithRows:views radius:22];
}

#pragma mark - Refresh

- (void)refresh {
    BOOL enabled = [FLEXAiFlexMCPServer isEnabled];
    NSString *state = [FLEXAiFlexMCPServer status];
    UIColor *tint = [state isEqualToString:@"运行中"]
        ? UIColor.systemGreenColor
        : (enabled ? UIColor.systemOrangeColor : UIColor.systemGrayColor);
    self.statusLabel.text = state;
    self.statusLabel.textColor = tint;
    self.statusDot.backgroundColor = tint;
    self.statusChip.backgroundColor = [tint colorWithAlphaComponent:0.16];

    self.endpointLabel.text = [FLEXAiFlexMCPServer endpoint];
    if ([FLEXAiFlexMCPServer authRequired]) {
        NSString *token = [FLEXAiFlexMCPServer token];
        self.tokenLabel.text = token.length > 4
            ? [NSString stringWithFormat:@"%@••••••••", [token substringToIndex:4]]
            : @"已生成";
    } else {
        self.tokenLabel.text = @"未启用（仅限可信局域网）";
    }
    self.heroSubtitle.text = [NSString stringWithFormat:@"FLEX++ 运行时 · %@", self.className];

    self.contextObjectRow.valueLabel.text = self.className;
    self.contextObjectRow.valueLabel.hidden = self.className.length == 0;
    NSString *summary = [self reportSummary];
    self.contextReportRow.subtitleLabel.text = summary.length ? summary : @"暂无";
    self.restartRow.titleLabel.text = enabled ? @"重启 MCP 服务" : @"开启 MCP 服务";

    NSArray<NSNumber *> *states = @[
        @([FLEXAiFlexMCPServer authRequired]),
        @([FLEXAiFlexMCPServer sensitiveEnabled]),
        @([FLEXAiFlexMCPServer controlEnabled]),
        @([FLEXAiFlexMCPServer scriptEnabled]),
        @([FLEXAiFlexMCPServer tracingEnabled])
    ];
    NSArray *names = @[@"授权保护", @"敏感读取", @"界面控制", @"脚本执行", @"方法追踪"];
    NSMutableArray *summaryParts = [NSMutableArray new];
    for (NSUInteger index = 0; index < self.permissionSwitches.count && index < states.count; index++) {
        self.permissionSwitches[index].on = states[index].boolValue;
        [summaryParts addObject:[NSString stringWithFormat:@"%@ %@", names[index],
            states[index].boolValue ? @"开" : @"关"]];
    }
    self.permissionFootnote.text = [NSString stringWithFormat:
        @"当前状态：%@\n\n关闭授权保护后同局域网可直接连接，请仅在可信网络使用；界面控制会真实改变 App 状态；方法追踪可能导致崩溃或卡顿，默认关闭。",
        [summaryParts componentsJoinedByString:@" · "]];

    NSArray *items = [self toolItems];
    for (NSUInteger index = 0; index < self.toolRowViews.count && index < items.count; index++) {
        BOOL on = [items[index][@"enabled"] boolValue];
        AXRowView *row = self.toolRowViews[index];
        row.titleLabel.textColor = on ? UIColor.labelColor : UIColor.secondaryLabelColor;
        [row setSymbol:on ? @"checkmark.seal.fill" : @"circle.dashed"
                 tint:on ? UIColor.systemGreenColor : UIColor.tertiaryLabelColor];
    }

    [self.axRefreshControl endRefreshing];
}

- (void)syncRuntimeContext {
    FLEXAiFlexRuntime *runtime = [FLEXAiFlexRuntime sharedRuntime];
    runtime.selectedObject = self.selectedObject;
    runtime.contextReport = self.report;
    runtime.contextClassName = self.className;
}

- (void)updateReport:(NSString *)report className:(NSString *)className selectedObject:(id)object {
    self.report = [report copy] ?: @"";
    self.className = [className copy] ?: @"未知对象";
    self.selectedObject = object;
    [self syncRuntimeContext];
    if (self.isViewLoaded) [self refresh];
}

- (NSArray<NSDictionary *> *)toolItems {
    return @[
        @{@"name": @"aiflex_status", @"detail": @"读取注入 App、端点与工具组状态", @"enabled": @YES},
        @{@"name": @"aiflex_read", @"detail": @"元素/文字查找、对象属性、实例、网络搜索与快照（免授权）", @"enabled": @YES},
        @{@"name": @"aiflex_sensitive", @"detail": @"头文件、日志搜索/网络正文、文件、截图（需敏感读取）", @"enabled": @([FLEXAiFlexMCPServer sensitiveEnabled])},
        @{@"name": @"aiflex_control", @"detail": @"按文字点击、高亮、输入、滚动、方法调用与手势（需界面控制）", @"enabled": @([FLEXAiFlexMCPServer controlEnabled])},
        @{@"name": @"aiflex_script", @"detail": @"在 WKWebView 执行 JavaScript（需脚本执行，单独授权）", @"enabled": @([FLEXAiFlexMCPServer scriptEnabled])},
        @{@"name": @"aiflex_trace", @"detail": @"方法调用追踪，高风险，10 分钟自动停止（需方法追踪）", @"enabled": @([FLEXAiFlexMCPServer tracingEnabled])}
    ];
}

- (NSString *)reportSummary {
    NSString *text = [self.report stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length) {
        return [NSString stringWithFormat:@"App: %@\n当前对象: %@",
            NSBundle.mainBundle.bundleIdentifier ?: @"unknown", self.className];
    }
    NSMutableArray<NSString *> *lines = [NSMutableArray new];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (line.length) [lines addObject:line];
        if (lines.count >= 4) break;
    }
    return [lines componentsJoinedByString:@"\n"];
}

#pragma mark - Actions

- (void)permissionChanged:(NSInteger)row on:(BOOL)on {
    if (row == 0) {
        [FLEXAiFlexMCPServer setAuthRequired:on];
        if ([FLEXAiFlexMCPServer isEnabled]) {
            [[FLEXAiFlexMCPServer shared] stop];
            [[FLEXAiFlexMCPServer shared] start];
        }
    } else if (row == 1) {
        [FLEXAiFlexMCPServer setSensitiveEnabled:on];
    } else if (row == 2) {
        [FLEXAiFlexMCPServer setControlEnabled:on];
    } else if (row == 3) {
        [FLEXAiFlexMCPServer setScriptEnabled:on];
    } else if (row == 4) {
        [FLEXAiFlexMCPServer setTracingEnabled:on];
    }
    [self refresh];
}

- (void)enableAllGroupsTapped {
    BOOL allOn = [FLEXAiFlexMCPServer sensitiveEnabled] && [FLEXAiFlexMCPServer controlEnabled];
    if (allOn) {
        [self toast:@"常用工具组已开启"];
        return;
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"一键开启常用工具组？"
        message:@"将同时开启「敏感读取」与「界面控制」两组工具，让连接上的 AI 能读取现场并操作界面。\n\n「脚本执行」与「方法追踪」风险较高，保持关闭，仍需在下方授权区单独开启。开启后请重新发现工具。"
        preferredStyle:UIAlertControllerStyleAlert];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"开启" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [FLEXAiFlexMCPServer setSensitiveEnabled:YES];
        [FLEXAiFlexMCPServer setControlEnabled:YES];
        [self refresh];
        [self toast:@"已开启敏感读取与界面控制，请在 AI 端重新发现工具"];
    }]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)copyClientConfiguration {
    NSString *url = [FLEXAiFlexMCPServer endpoint];
    NSString *json;
    if ([FLEXAiFlexMCPServer authRequired]) {
        json = [NSString stringWithFormat:@"{\"mcpServers\":{\"aiflex2\":{\"type\":\"http\",\"url\":\"%@\",\"headers\":{\"Authorization\":\"Bearer %@\"}}}}",
            url, [FLEXAiFlexMCPServer token]];
    } else {
        json = [NSString stringWithFormat:@"{\"mcpServers\":{\"aiflex2\":{\"type\":\"http\",\"url\":\"%@\"}}}", url];
    }
    [self copyText:json message:@"已复制 MCP 客户端配置"];
}

- (void)editEndpoint {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"自定义访问地址"
        message:@"填写手机可达的 IP 或域名（可粘贴完整 URL），端口沿用设置页配置。\n同机连接用 127.0.0.1；电脑端连接用手机局域网地址。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = [FLEXAiFlexMCPServer endpointHost];
        field.placeholder = @"IP 或域名，如 127.0.0.1";
        field.keyboardType = UIKeyboardTypeURL;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"使用本地地址" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [FLEXAiFlexMCPServer setEndpointHost:@"127.0.0.1"];
        [self refresh];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"使用局域网地址" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [FLEXAiFlexMCPServer setEndpointHost:[FLEXAiFlexMCPServer localAddress]];
        [self refresh];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *value = alert.textFields.firstObject.text;
        if (![FLEXAiFlexMCPServer setEndpointHost:value]) {
            [self toast:@"地址格式不正确"];
            return;
        }
        [self refresh];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)copyToken {
    if (![FLEXAiFlexMCPServer authRequired]) {
        [self toast:@"当前未启用授权保护"];
        return;
    }
    [self copyText:[FLEXAiFlexMCPServer token] message:@"已复制访问令牌"];
}

- (void)copyText:(NSString *)text message:(NSString *)message {
    UIPasteboard.generalPasteboard.string = text ?: @"";
    [self toast:message];
}

- (void)openSettings {
    [self.navigationController pushViewController:[FLEXAiFlexSettingsViewController new] animated:YES];
}

- (void)restartService {
    [FLEXAiFlexMCPServer setEnabled:YES];
    [[FLEXAiFlexMCPServer shared] stop];
    [[FLEXAiFlexMCPServer shared] start];
    [self toast:@"正在重启 MCP 服务"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refresh];
    });
}

- (void)collapseTapped {
    // 只收起 AiFlex2 面板，保留 FLEX 悬浮工具条，方便继续在 App 里操作。
    [self minimizeWithTarget:NO completion:nil];
}

- (void)doneTapped {
    [self minimizeWithTarget:NO completion:nil];
}

- (void)toast:(NSString *)text {
    // 挂到 FLEX 的 explorerWindow（或 keyWindow）并居中，避免面板非全屏时提示偏离屏幕中央。
    UIWindow *window = FLEXManager.sharedManager.explorerWindow ?: UIApplication.sharedApplication.keyWindow ?: self.view.window;
    UIView *host = window ?: self.view;
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    label.textColor = UIColor.whiteColor;
    label.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.82];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.layer.cornerRadius = 16;
    label.layer.masksToBounds = YES;
    label.alpha = 0;
    CGFloat maxWidth = CGRectGetWidth(host.bounds) - 48;
    CGRect textBox = [text boundingRectWithSize:CGSizeMake(maxWidth - 28, CGFLOAT_MAX)
        options:NSStringDrawingUsesLineFragmentOrigin
        attributes:@{NSFontAttributeName:label.font} context:nil];
    CGRect frame = CGRectMake(0, 0, MIN(maxWidth, CGRectGetWidth(textBox) + 28), MAX(36, CGRectGetHeight(textBox) + 20));
    label.frame = frame;
    label.center = CGPointMake(CGRectGetMidX(host.bounds), CGRectGetMidY(host.bounds));
    label.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin
        | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [host addSubview:label];
    [UIView animateWithDuration:0.18 animations:^{ label.alpha = 1; } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.3 delay:1.1 options:0 animations:^{ label.alpha = 0; } completion:^(BOOL finished) {
            [label removeFromSuperview];
        }];
    }];
}

#pragma mark - Window operations for MCP

- (BOOL)panelVisible {
    UIWindow *window = self.viewIfLoaded.window;
    return window != nil && !window.hidden && !self.navigationController.isBeingDismissed;
}

- (NSDictionary *)panelStatus {
    BOOL running = [[FLEXAiFlexMCPServer status] isEqualToString:@"运行中"];
    return @{
        @"chatVisible": @([self panelVisible]),
        @"minimized": @(self.minimized),
        @"connected": @(running),
        @"taskRunning": @NO,
        @"stopped": @NO,
        @"sessionID": @"",
        @"flexVisible": @(!FLEXManager.sharedManager.isHidden),
        @"targetReady": @(![self panelVisible] && FLEXManager.sharedManager.isHidden && !self.uiTransitioning),
        @"statusVisible": @NO,
        @"activity": [FLEXAiFlexMCPServer status],
        @"uiTransitioning": @(self.uiTransitioning)
    };
}

- (void)performWindowOperation:(NSString *)operation
                     arguments:(NSDictionary *)arguments
                    completion:(void (^)(NSDictionary *, NSString *))completion {
    if ([operation isEqualToString:@"chat_status"]) {
        completion([self panelStatus], nil);
        return;
    }
    if (self.uiTransitioning) {
        completion(nil, @"窗口正在切换，请稍后重新读取 chat_status");
        return;
    }
    self.uiTransitioning = YES;
    void (^done)(void) = ^{
        self.uiTransitioning = NO;
        completion([self panelStatus], nil);
    };

    if ([operation isEqualToString:@"minimize_chat"]) {
        [self minimizeWithTarget:![arguments[@"surface"] isEqualToString:@"flex"] completion:done];
        return;
    }
    if ([operation isEqualToString:@"restore_chat"]) {
        [self restoreWithCompletion:done];
        return;
    }
    if ([operation isEqualToString:@"open_tool"]) {
        NSString *failure = nil;
        UIViewController *controller = nil;
        @try {
            controller = [[FLEXAiFlexRuntime sharedRuntime] controllerForTool:arguments[@"tool_id"] error:&failure];
        } @catch (NSException *exception) {
            failure = [NSString stringWithFormat:@"FLEX 入口暂不可用（%@）", exception.name];
        }
        if (!controller) {
            self.uiTransitioning = NO;
            completion(nil, failure ?: @"无法打开该工具");
            return;
        }
        [self minimizeWithTarget:NO completion:^{
            [FLEXManager.sharedManager dismissAnyPresentedTools:^{
                [FLEXManager.sharedManager presentEmbeddedTool:controller completion:^(UINavigationController *nav) { done(); }];
            }];
        }];
        return;
    }

    UIViewController *visible = [FLEXUtility topViewControllerInWindow:FLEXManager.sharedManager.explorerWindow];
    if ([visible isKindOfClass:UIAlertController.class]) {
        self.uiTransitioning = NO;
        completion(nil, @"请先人工处理当前弹窗");
        return;
    }
    if ([operation isEqualToString:@"navigate_back"]) {
        UINavigationController *nav = visible.navigationController;
        if (nav.viewControllers.count < 2) {
            self.uiTransitioning = NO;
            completion(nil, @"当前 FLEX 页已经在导航根部");
            return;
        }
        [nav popViewControllerAnimated:NO];
        done();
        return;
    }
    [FLEXManager.sharedManager dismissAnyPresentedTools:^{ done(); }];
}

- (void)minimizeWithTarget:(BOOL)target completion:(dispatch_block_t)completion {
    [self.view endEditing:YES];
    void (^done)(void) = ^{
        self.minimized = YES;
        if (target) [FLEXManager.sharedManager hideExplorer];
        if (completion) completion();
    };
    if (self.navigationController.presentingViewController) {
        [self.navigationController dismissViewControllerAnimated:YES completion:done];
    } else {
        done();
    }
}

- (void)restoreWithCompletion:(dispatch_block_t)completion {
    if (self.viewIfLoaded.window) {
        [FLEXManager.sharedManager showExplorer];
        self.minimized = NO;
        if (completion) completion();
        return;
    }
    UINavigationController *nav = self.navigationController;
    if (!nav) nav = [[UINavigationController alloc] initWithRootViewController:self];
    [FLEXManager.sharedManager dismissAnyPresentedTools:^{
        [FLEXManager.sharedManager presentTool:^UINavigationController *{ return nav; } completion:^{
            self.minimized = NO;
            if (completion) completion();
        }];
    }];
}

@end
