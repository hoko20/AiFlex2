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
