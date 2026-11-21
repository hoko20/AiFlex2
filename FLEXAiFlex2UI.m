#import "FLEXAiFlex2UI.h"

#pragma mark - Liquid Glass primitives

// iOS 26 起系统提供 UIGlassEffect。本 dylib 用较低 SDK 编译，所以只在运行时探测，
// 找不到（iOS 15–18）就退回系统毛玻璃材质，保证外观与可读性都不塌。
UIVisualEffect *AXGlassEffect(void) {
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

#pragma mark - Helpers

AXGradientView *AXInstallBackdrop(UIView *host) {
    if (!host) return nil;
    AXGradientView *bloom = [AXGradientView new];
    bloom.colors = @[
        (__bridge id)[[UIColor systemBlueColor] colorWithAlphaComponent:0.20].CGColor,
        (__bridge id)[[UIColor systemIndigoColor] colorWithAlphaComponent:0.11].CGColor,
        (__bridge id)([UIColor clearColor].CGColor)
    ];
    bloom.gradientStart = CGPointMake(0.1, 0);
    bloom.gradientEnd = CGPointMake(0.9, 0.92);
    [host insertSubview:bloom atIndex:0];
    [NSLayoutConstraint activateConstraints:@[
        [bloom.topAnchor constraintEqualToAnchor:host.topAnchor],
        [bloom.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [bloom.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [bloom.bottomAnchor constraintEqualToAnchor:host.bottomAnchor]
    ]];
    return bloom;
}

UILabel *AXSectionLabel(NSString *text) {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    label.textColor = UIColor.secondaryLabelColor;
    return label;
}

UILabel *AXFootnoteLabel(NSString *text) {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont systemFontOfSize:11.5];
    label.textColor = UIColor.tertiaryLabelColor;
    label.numberOfLines = 0;
    return label;
}

UIView *AXSeparatorView(void) {
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

UIStackView *AXSectionView(NSString *title, UIView *card, NSString *footnote) {
    NSMutableArray *views = [NSMutableArray new];
    if (title.length) [views addObject:AXSectionLabel(title)];
    if (card) [views addObject:card];
    if (footnote.length) [views addObject:AXFootnoteLabel(footnote)];
    if (!views.count) return nil;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:views];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    stack.alignment = UIStackViewAlignmentFill;
    if (footnote.length && card) [stack setCustomSpacing:7 afterView:card];
    return stack;
}

AXGlassCard *AXCardWithRows(NSArray<UIView *> *rows, CGFloat radius) {
    AXGlassCard *card = [[AXGlassCard alloc] initWithRadius:radius];
    NSMutableArray *views = [NSMutableArray new];
    for (NSUInteger index = 0; index < rows.count; index++) {
        if (index) [views addObject:AXSeparatorView()];
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

UIBarButtonItem *AXCheckmarkItem(id target, SEL action) {
    UIImage *image = [UIImage systemImageNamed:@"checkmark"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:16
                                                                          weight:UIImageSymbolWeightSemibold]];
    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithImage:image
                                                             style:UIBarButtonItemStylePlain
                                                            target:target
                                                            action:action];
    item.accessibilityLabel = @"完成";
    return item;
}

#pragma mark - 顶部栏

// 实底系统背景：不做模糊、不画 hairline。
// 半透明玻璃在滚动时内容持续从栏下穿过，视觉噪音大，长时间看容易疲劳。
void AXApplyOpaqueNavigationBar(UINavigationBar *bar) {
    if (!bar) return;
    UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = UIColor.systemBackgroundColor;
    appearance.shadowColor = UIColor.clearColor;
    appearance.backgroundEffect = nil;
    appearance.titleTextAttributes = @{NSForegroundColorAttributeName: UIColor.labelColor};
    appearance.largeTitleTextAttributes = @{NSForegroundColorAttributeName: UIColor.labelColor};

    bar.standardAppearance = appearance;
    bar.compactAppearance = appearance;
    bar.scrollEdgeAppearance = appearance;
    if (@available(iOS 15.0, *)) bar.compactScrollEdgeAppearance = appearance;
    bar.translucent = NO;
    bar.shadowImage = [UIImage new];
}

#pragma mark - 玻璃弹窗

static NSMutableArray<AXGlassAlert *> *AXVisibleAlerts(void) {
    static NSMutableArray *alerts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ alerts = [NSMutableArray new]; });
    return alerts;
}

@implementation AXAlertButton

+ (instancetype)buttonWithTitle:(NSString *)title
                          style:(AXAlertButtonStyle)style
                        handler:(void (^)(AXGlassAlert *))handler {
    AXAlertButton *button = [AXAlertButton new];
    button->_title = [title copy];
    button->_style = style;
    button->_handler = [handler copy];
    return button;
}

@end

@interface AXGlassAlert () <UITextFieldDelegate>
@property (nonatomic, strong) UIView *overlay;
@property (nonatomic, strong) AXGlassCard *card;
@property (nonatomic, strong, nullable) UITextField *textField;
@property (nonatomic, strong) NSLayoutConstraint *centerConstraint;
@property (nonatomic, copy) NSArray<AXAlertButton *> *buttons;
@property (nonatomic, assign) BOOL dismissing;
@end

@implementation AXGlassAlert

- (instancetype)initWithTitle:(NSString *)title
                      message:(NSString *)message
                 messageStyle:(AXAlertMessageStyle)messageStyle
           configureTextField:(void (^)(UITextField *field))configureTextField
                      buttons:(NSArray<AXAlertButton *> *)buttons {
    self = [super init];
    if (!self) return nil;
    _buttons = [buttons copy] ?: @[];

    _overlay = [UIView new];
    _overlay.translatesAutoresizingMaskIntoConstraints = NO;
    _overlay.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.34];

    AXGradientView *bloom = [AXGradientView new];
    bloom.colors = @[
        (__bridge id)[[UIColor systemBlueColor] colorWithAlphaComponent:0.18].CGColor,
        (__bridge id)([UIColor clearColor].CGColor)
    ];
    bloom.gradientStart = CGPointMake(0.15, 0.05);
    bloom.gradientEnd = CGPointMake(0.85, 0.95);
    [_overlay addSubview:bloom];
    [NSLayoutConstraint activateConstraints:@[
        [bloom.topAnchor constraintEqualToAnchor:_overlay.topAnchor],
        [bloom.leadingAnchor constraintEqualToAnchor:_overlay.leadingAnchor],
        [bloom.trailingAnchor constraintEqualToAnchor:_overlay.trailingAnchor],
        [bloom.bottomAnchor constraintEqualToAnchor:_overlay.bottomAnchor]
    ]];

    _card = [[AXGlassCard alloc] initWithRadius:26];
    [_overlay addSubview:_card];

    _centerConstraint = [_card.centerYAnchor constraintEqualToAnchor:_overlay.centerYAnchor];
    NSLayoutConstraint *fluidWidth = [_card.widthAnchor constraintEqualToAnchor:_overlay.widthAnchor
                                                                      constant:-52];
    fluidWidth.priority = 990;
    NSLayoutConstraint *topGuard = [_card.topAnchor constraintGreaterThanOrEqualToAnchor:_overlay.topAnchor
                                                                               constant:44];
    topGuard.priority = 999;
    [NSLayoutConstraint activateConstraints:@[
        [_card.centerXAnchor constraintEqualToAnchor:_overlay.centerXAnchor],
        _centerConstraint,
        [_card.widthAnchor constraintLessThanOrEqualToConstant:340],
        fluidWidth,
        topGuard
    ]];

    NSMutableArray<UIView *> *content = [NSMutableArray new];

    if (title.length) {
        UILabel *label = [UILabel new];
        label.text = title;
        label.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        label.textColor = UIColor.labelColor;
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 0;
        [content addObject:label];
    }

    if (message.length) {
        if (messageStyle == AXAlertMessageStyleCode) {
            UITextView *code = [UITextView new];
            code.translatesAutoresizingMaskIntoConstraints = NO;
            code.text = message;
            code.editable = NO;
            code.selectable = YES;
            code.scrollEnabled = NO;
            code.backgroundColor = [UIColor.labelColor colorWithAlphaComponent:0.06];
            code.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
            code.textContainer.lineFragmentPadding = 0;
            code.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
            code.textColor = UIColor.labelColor;
            code.layer.cornerRadius = 12;
            code.layer.cornerCurve = kCACornerCurveContinuous;
            code.layer.borderWidth = 0.5;
            code.layer.borderColor = [UIColor.separatorColor
                resolvedColorWithTraitCollection:code.traitCollection].CGColor;
            [code.heightAnchor constraintGreaterThanOrEqualToConstant:52].active = YES;
            [content addObject:code];
        } else {
            UILabel *label = [UILabel new];
            label.text = message;
            label.font = [UIFont systemFontOfSize:13];
            label.textColor = UIColor.secondaryLabelColor;
            label.textAlignment = NSTextAlignmentCenter;
            label.numberOfLines = 0;
            [content addObject:label];
        }
    }

    if (configureTextField) {
        UITextField *field = [UITextField new];
        field.translatesAutoresizingMaskIntoConstraints = NO;
        field.font = [UIFont systemFontOfSize:15];
        field.textColor = UIColor.labelColor;
        field.backgroundColor = [UIColor.labelColor colorWithAlphaComponent:0.07];
        field.layer.cornerRadius = 13;
        field.layer.cornerCurve = kCACornerCurveContinuous;
        field.layer.borderWidth = 0.5;
        field.layer.borderColor = [UIColor.separatorColor
            resolvedColorWithTraitCollection:field.traitCollection].CGColor;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.returnKeyType = UIReturnKeyDone;
        field.delegate = self;
        UIView *pad = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 13, 44)];
        field.leftView = pad;
        field.leftViewMode = UITextFieldViewModeAlways;
        [field.heightAnchor constraintEqualToConstant:46].active = YES;
        configureTextField(field);
        _textField = field;
        [content addObject:field];
    }

    if (_buttons.count) {
        UIStackView *column = [self columnForButtons:_buttons];
        [content addObject:column];
    }

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:content];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.alignment = UIStackViewAlignmentFill;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_card addSubview:stack];
    [_card bringSubviewToFront:stack];

    if (content.count > 1) {
        NSUInteger titleIndex = title.length ? 0 : NSNotFound;
        if (titleIndex != NSNotFound) [stack setCustomSpacing:8 afterView:content[titleIndex]];
        [stack setCustomSpacing:18 afterView:content[content.count - 2]];
    }

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:_card.topAnchor constant:22],
        [stack.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-20],
        [stack.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-20]
    ]];
    return self;
}

- (UIStackView *)buttonRow:(NSArray<AXAlertButton *> *)buttons {
    NSMutableArray<UIButton *> *views = [NSMutableArray new];
    for (AXAlertButton *action in buttons) {
        UIButton *button = [self buttonForAction:action];
        if (button) [views addObject:button];
        if (button) [button.heightAnchor constraintEqualToConstant:46].active = YES;
    }
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:views];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 10;
    row.distribution = UIStackViewDistributionFillEqually;
    return row;
}

- (UIStackView *)columnForButtons:(NSArray<AXAlertButton *> *)buttons {
    NSMutableArray<UIView *> *rows = [NSMutableArray new];
    NSMutableArray<AXAlertButton *> *inlineActions = [NSMutableArray new];
    for (AXAlertButton *action in buttons) {
        if (action.style == AXAlertButtonStyleInline) {
            [inlineActions addObject:action];
            continue;
        }
        if (inlineActions.count) {
            [rows addObject:[self buttonRow:inlineActions]];
            [inlineActions removeAllObjects];
        }
        UIButton *button = [self buttonForAction:action];
        if (!button) continue;
        [button.heightAnchor constraintEqualToConstant:48].active = YES;
        [rows addObject:button];
    }
    if (inlineActions.count) [rows addObject:[self buttonRow:inlineActions]];

    UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:rows];
    column.axis = UILayoutConstraintAxisVertical;
    column.spacing = 9;
    column.alignment = UIStackViewAlignmentFill;
    return column;
}

- (UIButton *)buttonForAction:(AXAlertButton *)action {
    if (!action.title.length) return nil;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.tag = [_buttons indexOfObjectIdenticalTo:action];
    button.layer.cornerRadius = 14;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.titleLabel.font = [UIFont systemFontOfSize:
        (action.style == AXAlertButtonStylePrimary ? 16 : 15)
        weight:(action.style == AXAlertButtonStylePrimary ? UIFontWeightSemibold : UIFontWeightMedium)];
    [button setTitle:action.title forState:UIControlStateNormal];
    [button addTarget:self action:@selector(actionTapped:) forControlEvents:UIControlEventTouchUpInside];

    switch (action.style) {
        case AXAlertButtonStylePrimary:
            button.backgroundColor = UIColor.systemBlueColor;
            [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
            break;
        case AXAlertButtonStyleDestructive:
            button.backgroundColor = [UIColor.systemRedColor colorWithAlphaComponent:0.14];
            [button setTitleColor:UIColor.systemRedColor forState:UIControlStateNormal];
            break;
        case AXAlertButtonStyleSecondary:
        case AXAlertButtonStyleInline:
            button.backgroundColor = [UIColor.labelColor colorWithAlphaComponent:0.07];
            [button setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
            break;
        case AXAlertButtonStyleCancel:
            button.backgroundColor = UIColor.clearColor;
            [button setTitleColor:UIColor.secondaryLabelColor forState:UIControlStateNormal];
            break;
    }
    // 按压反馈交给系统的自定义按钮高亮，这里不需要额外配色。
    button.alpha = 1;
    return button;
}

- (void)fireAction:(AXAlertButton *)action {
    if (self.dismissing || !action) return;
    void (^handler)(AXGlassAlert *) = action.handler;
    [self dismiss];
    if (handler) {
        dispatch_async(dispatch_get_main_queue(), ^{ handler(self); });
    }
}

- (void)actionTapped:(UIButton *)sender {
    NSInteger index = sender.tag;
    if (index < 0 || index >= (NSInteger)self.buttons.count) return;
    [self fireAction:self.buttons[(NSUInteger)index]];
}

- (NSString *)text {
    return self.textField.text ?: @"";
}

- (void)present {
    UIWindow *window = self.overlay.superview.window ?: self.card.window;
    if (!window) return;
    [AXVisibleAlerts() addObject:self];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillChange:)
                                                 name:UIKeyboardWillChangeFrameNotification
                                               object:nil];
    self.overlay.alpha = 0;
    self.card.transform = CGAffineTransformMakeScale(1.04, 1.04);
    [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.overlay.alpha = 1;
        self.card.transform = CGAffineTransformIdentity;
    } completion:nil];
    if (self.textField) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.22 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self.textField becomeFirstResponder];
        });
    }
}

- (void)dismiss {
    if (self.dismissing) return;
    self.dismissing = YES;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.textField resignFirstResponder];
    [AXVisibleAlerts() removeObjectIdenticalTo:self];
    UIView *overlay = self.overlay;
    [UIView animateWithDuration:0.16 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        overlay.alpha = 0;
        self.card.transform = CGAffineTransformMakeScale(0.97, 0.97);
    } completion:^(BOOL finished) {
        [overlay removeFromSuperview];
    }];
}

- (void)keyboardWillChange:(NSNotification *)note {
    CGRect frame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect keyboard = [self.overlay convertRect:frame fromView:nil];
    CGFloat overlap = CGRectGetMaxY(self.overlay.bounds) - CGRectGetMinY(keyboard);
    if (overlap < 0) overlap = 0;
    self.centerConstraint.constant = -overlap / 2.0;
    [UIView animateWithDuration:0.2 animations:^{
        [self.overlay layoutIfNeeded];
    }];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    // 回车等同主操作，少一次点击。
    for (AXAlertButton *action in self.buttons) {
        if (action.style != AXAlertButtonStylePrimary) continue;
        [self fireAction:action];
        break;
    }
    return YES;
}

@end

AXGlassAlert *AXPresentAlert(UIViewController *host,
                             NSString *title,
                             NSString *message,
                             AXAlertMessageStyle messageStyle,
                             void (^configureTextField)(UITextField *),
                             NSArray<AXAlertButton *> *buttons) {
    UIView *hostView = host.viewIfLoaded ?: host.view;
    UIWindow *window = hostView.window ?: UIApplication.sharedApplication.keyWindow;
    if (!window) return nil;
    AXGlassAlert *alert = [[AXGlassAlert alloc] initWithTitle:title
                                                      message:message
                                                 messageStyle:messageStyle
                                           configureTextField:configureTextField
                                                      buttons:buttons];
    [window addSubview:alert.overlay];
    [NSLayoutConstraint activateConstraints:@[
        [alert.overlay.topAnchor constraintEqualToAnchor:window.topAnchor],
        [alert.overlay.leadingAnchor constraintEqualToAnchor:window.leadingAnchor],
        [alert.overlay.trailingAnchor constraintEqualToAnchor:window.trailingAnchor],
        [alert.overlay.bottomAnchor constraintEqualToAnchor:window.bottomAnchor]
    ]];
    [alert present];
    return alert;
}

BOOL AXGlassAlertVisible(void) {
    return AXVisibleAlerts().count > 0;
}
