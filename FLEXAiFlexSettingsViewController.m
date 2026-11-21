#import "FLEXAiFlexSettingsViewController.h"
#import "FLEXAiFlexMCPServer.h"
#import "FLEXAiFlex2UI.h"

@interface FLEXAiFlexSettingsViewController ()
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) AXRowView *serviceRow;
@property (nonatomic, strong) AXRowView *portRow;
@property (nonatomic, strong) AXRowView *endpointRow;
@property (nonatomic, strong) AXRowView *statusRow;
@property (nonatomic, strong) AXRowView *authRow;
@property (nonatomic, strong) AXRowView *tokenRow;
@property (nonatomic, strong) AXRowView *customTokenRow;
@property (nonatomic, strong) AXRowView *rotateRow;
@property (nonatomic, copy) NSArray<AXRowView *> *groupRows;
@end

@implementation FLEXAiFlexSettingsViewController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) self.title = @"MCP 服务";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.rightBarButtonItem = AXCheckmarkItem(self, @selector(done));
    AXInstallBackdrop(self.view);
    [self buildContent];
    [self refresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    AXApplyOpaqueNavigationBar(self.navigationController.navigationBar);
    [self refresh];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIEdgeInsets insets = UIEdgeInsetsMake(self.view.safeAreaInsets.top, 0,
                                           self.view.safeAreaInsets.bottom, 0);
    if (UIEdgeInsetsEqualToEdgeInsets(self.scrollView.contentInset, insets)) return;
    self.scrollView.contentInset = insets;
    self.scrollView.verticalScrollIndicatorInsets = insets;
}

- (void)done {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Layout

- (AXRowView *)row:(NSString *)title
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

- (void)buildContent {
    __weak typeof(self) weakSelf = self;

    self.serviceRow = [self row:@"MCP 服务" subtitle:nil symbol:@"antenna.radiowaves.left.and.right"
                          tint:UIColor.systemGreenColor];
    [self.serviceRow setShowsSwitch:YES];
    self.serviceRow.onToggle = ^(BOOL on) { [weakSelf toggleService:on]; };

    self.portRow = [self row:@"监听端口" subtitle:nil symbol:@"number" tint:UIColor.systemBlueColor];
    [self.portRow setShowsChevron:YES];
    self.portRow.valueLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightMedium];
    self.portRow.onTap = ^{ [weakSelf editPort]; };

    self.endpointRow = [self row:@"访问地址" subtitle:nil symbol:@"link" tint:UIColor.systemIndigoColor];
    [self.endpointRow setShowsChevron:YES];
    self.endpointRow.onTap = ^{ [weakSelf editEndpoint]; };

    self.statusRow = [self row:@"运行状态" subtitle:nil symbol:@"bolt.horizontal.circle"
                         tint:UIColor.systemGrayColor];
    self.statusRow.userInteractionEnabled = NO;
    self.statusRow.valueLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];

    AXGlassCard *serviceCard = AXCardWithRows(@[self.serviceRow, self.portRow, self.endpointRow, self.statusRow], 22);

    self.authRow = [self row:@"授权保护" subtitle:@"要求客户端携带 Bearer 令牌；关闭后同局域网可直接连接"
                      symbol:@"lock.shield.fill" tint:UIColor.systemGreenColor];
    [self.authRow setShowsSwitch:YES];
    self.authRow.onToggle = ^(BOOL on) { [weakSelf setGroup:0 on:on]; };

    self.tokenRow = [self row:@"访问令牌" subtitle:nil symbol:@"key.horizontal.fill" tint:UIColor.systemBlueColor];
    [self.tokenRow setShowsChevron:YES];
    self.tokenRow.valueLabel.font = [UIFont systemFontOfSize:13];
    self.tokenRow.onTap = ^{ [weakSelf copyToken]; };

    self.customTokenRow = [self row:@"自定义授权码" subtitle:@"6–64 位字母、数字、点、下划线或短横线"
                             symbol:@"square.and.pencil" tint:UIColor.systemBlueColor];
    [self.customTokenRow setShowsChevron:YES];
    self.customTokenRow.onTap = ^{ [weakSelf editCustomToken]; };

    self.rotateRow = [self row:@"重新生成令牌" subtitle:@"旧令牌立即失效，需同步修改电脑端配置"
                        symbol:@"arrow.triangle.2.circlepath" tint:UIColor.systemRedColor];
    [self.rotateRow setShowsChevron:YES];
    self.rotateRow.titleLabel.textColor = UIColor.systemRedColor;
    self.rotateRow.onTap = ^{ [weakSelf rotateToken]; };

    AXRowView *sensitive = [self row:@"敏感读取"
                            subtitle:@"头文件、日志/网络正文、文件搜索、截图与 Keychain 元数据"
                              symbol:@"eye.fill" tint:UIColor.systemBlueColor];
    AXRowView *control = [self row:@"界面控制"
                          subtitle:@"点击、输入、滚动、手势、高亮与方法调用，会改变 App 状态"
                            symbol:@"hand.tap.fill" tint:UIColor.systemIndigoColor];
    AXRowView *script = [self row:@"脚本执行"
                         subtitle:@"在 WKWebView 执行 JavaScript，可能改变网页状态"
                           symbol:@"curlybraces" tint:UIColor.systemOrangeColor];
    AXRowView *tracing = [self row:@"方法追踪"
                          subtitle:@"替换方法实现并记录调用，高风险，10 分钟自动停止"
                            symbol:@"waveform.path.ecg" tint:UIColor.systemRedColor];
    self.groupRows = @[sensitive, control, script, tracing];
    NSInteger index = 1;
    for (AXRowView *row in self.groupRows) {
        [row setShowsSwitch:YES];
        NSInteger group = index;
        row.onToggle = ^(BOOL on) { [weakSelf setGroup:group on:on]; };
        index++;
    }

    AXGlassCard *authCard = AXCardWithRows(@[self.authRow, self.tokenRow, self.customTokenRow,
                                             self.rotateRow, sensitive, control, script, tracing], 22);

    AXRowView *copyConfig = [self row:@"复制 MCP 客户端配置" subtitle:nil
                                symbol:@"square.on.square" tint:UIColor.systemBlueColor];
    [copyConfig setShowsChevron:YES];
    copyConfig.onTap = ^{ [weakSelf copyClientConfiguration]; };

    AXGlassCard *usageCard = AXCardWithRows(@[copyConfig], 22);

    NSString *authNote = @"敏感读取：头文件、日志/网络正文、文件搜索、截图与 Keychain 元数据。\n"
        "界面控制：点击、输入、滚动、手势、高亮与方法调用，会真实改变 App 状态。\n"
        "脚本执行：在 WKWebView 运行 JavaScript，可能改变网页状态。\n"
        "方法追踪：运行期替换方法实现并记录调用，可能崩溃或卡顿，10 分钟自动停止。\n"
        "授权保护开启时必须携带 Bearer 令牌；关闭后同一局域网内无需令牌即可连接，请仅在可信网络使用。";
    NSString *usageNote = @"在电脑端 MCP 客户端（Claude Desktop、Cursor、Cherry Studio 等）添加 Streamable HTTP 服务，"
        "URL 填上方访问地址；开启授权保护时请求头加 Authorization: Bearer <访问令牌>。\n"
        "服务只在宿主 App 进程内运行，App 被挂起或杀死时连接会中断，重新打开 App 后自动恢复。"
        "HTTP 为明文，仅用于可信局域网。\n"
        "工具：status / read / sensitive / control / script / trace";

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[
        AXSectionView(@"服务", serviceCard, nil),
        AXSectionView(@"授权", authCard, authNote),
        AXSectionView(@"使用方式", usageCard, usageNote)
    ]];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 24;
    content.alignment = UIStackViewAlignmentFill;
    content.translatesAutoresizingMaskIntoConstraints = NO;

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

- (UIScrollView *)scrollView {
    if (!_scrollView) {
        _scrollView = [UIScrollView new];
        _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
        _scrollView.alwaysBounceVertical = YES;
        _scrollView.showsVerticalScrollIndicator = YES;
        _scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        [self.view addSubview:_scrollView];
        [NSLayoutConstraint activateConstraints:@[
            [_scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
            [_scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [_scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
            [_scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
        ]];
    }
    return _scrollView;
}

#pragma mark - Refresh

- (void)refresh {
    BOOL enabled = [FLEXAiFlexMCPServer isEnabled];
    self.serviceRow.toggle.on = enabled;

    [self.portRow setValueText:[NSString stringWithFormat:@"%lu", (unsigned long)[FLEXAiFlexMCPServer port]]];
    [self.endpointRow setValueText:[FLEXAiFlexMCPServer endpoint]];

    NSString *status = [FLEXAiFlexMCPServer status];
    [self.statusRow setValueText:status];
    self.statusRow.valueLabel.textColor = [status isEqualToString:@"运行中"]
        ? UIColor.systemGreenColor
        : UIColor.secondaryLabelColor;

    BOOL auth = [FLEXAiFlexMCPServer authRequired];
    self.authRow.toggle.on = auth;
    [self.tokenRow setValueText:auth ? @"轻点复制" : @"未启用"];
    self.tokenRow.userInteractionEnabled = auth;
    self.customTokenRow.userInteractionEnabled = auth;
    self.rotateRow.userInteractionEnabled = auth;
    UIColor *dim = auth ? UIColor.labelColor : UIColor.secondaryLabelColor;
    self.tokenRow.titleLabel.textColor = dim;
    self.customTokenRow.titleLabel.textColor = dim;
    self.rotateRow.titleLabel.textColor = auth ? UIColor.systemRedColor : UIColor.secondaryLabelColor;

    NSArray<NSNumber *> *states = @[
        @([FLEXAiFlexMCPServer sensitiveEnabled]),
        @([FLEXAiFlexMCPServer controlEnabled]),
        @([FLEXAiFlexMCPServer scriptEnabled]),
        @([FLEXAiFlexMCPServer tracingEnabled])
    ];
    for (NSUInteger index = 0; index < self.groupRows.count && index < states.count; index++) {
        self.groupRows[index].toggle.on = states[index].boolValue;
    }
}

- (void)reloadSoon {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refresh];
    });
}

#pragma mark - Actions

- (void)toggleService:(BOOL)on {
    [FLEXAiFlexMCPServer setEnabled:on];
    if (on) [[FLEXAiFlexMCPServer shared] start];
    else [[FLEXAiFlexMCPServer shared] stop];
    [self reloadSoon];
}

- (void)setGroup:(NSInteger)group on:(BOOL)on {
    switch (group) {
        case 0: [FLEXAiFlexMCPServer setAuthRequired:on]; break;
        case 1: [FLEXAiFlexMCPServer setSensitiveEnabled:on]; break;
        case 2: [FLEXAiFlexMCPServer setControlEnabled:on]; break;
        case 3: [FLEXAiFlexMCPServer setScriptEnabled:on]; break;
        default: [FLEXAiFlexMCPServer setTracingEnabled:on]; break;
    }
    [self reloadSoon];
}

- (void)editPort {
    __weak typeof(self) weakSelf = self;
    AXPresentAlert(self, @"监听端口", @"1024–65535，修改后自动重启服务。", AXAlertMessageStyleText,
        ^(UITextField *field) {
            field.keyboardType = UIKeyboardTypeNumberPad;
            field.text = [NSString stringWithFormat:@"%lu", (unsigned long)[FLEXAiFlexMCPServer port]];
        }, @[
        [AXAlertButton buttonWithTitle:@"保存" style:AXAlertButtonStylePrimary handler:^(AXGlassAlert *alert) {
            NSUInteger port = [alert.text integerValue];
            if (port < 1024 || port > 65535) {
                [weakSelf toast:@"端口需在 1024–65535 之间"];
                return;
            }
            [FLEXAiFlexMCPServer setPort:port];
            if ([FLEXAiFlexMCPServer isEnabled]) {
                [[FLEXAiFlexMCPServer shared] stop];
                [[FLEXAiFlexMCPServer shared] start];
            }
            [weakSelf reloadSoon];
        }],
        [AXAlertButton buttonWithTitle:@"取消" style:AXAlertButtonStyleCancel handler:nil]
    ]);
}

- (void)editEndpoint {
    __weak typeof(self) weakSelf = self;
    AXPresentAlert(self, @"自定义访问地址",
        @"填写手机可达的 IP 或域名（可粘贴完整 URL），端口沿用当前配置。\n同机连接用 127.0.0.1；电脑端连接用手机局域网地址。",
        AXAlertMessageStyleText, ^(UITextField *field) {
            field.text = [FLEXAiFlexMCPServer endpointHost];
            field.placeholder = @"IP 或域名，如 127.0.0.1";
            field.keyboardType = UIKeyboardTypeURL;
            field.autocapitalizationType = UITextAutocapitalizationTypeNone;
            field.autocorrectionType = UITextAutocorrectionTypeNo;
        }, @[
        [AXAlertButton buttonWithTitle:@"保存" style:AXAlertButtonStylePrimary handler:^(AXGlassAlert *alert) {
            if (![FLEXAiFlexMCPServer setEndpointHost:alert.text]) {
                [weakSelf toast:@"地址格式不正确"];
                return;
            }
            [weakSelf reloadSoon];
        }],
        [AXAlertButton buttonWithTitle:@"本地地址" style:AXAlertButtonStyleInline handler:^(AXGlassAlert *alert) {
            [FLEXAiFlexMCPServer setEndpointHost:@"127.0.0.1"];
            [weakSelf reloadSoon];
        }],
        [AXAlertButton buttonWithTitle:@"局域网地址" style:AXAlertButtonStyleInline handler:^(AXGlassAlert *alert) {
            [FLEXAiFlexMCPServer setEndpointHost:[FLEXAiFlexMCPServer localAddress]];
            [weakSelf reloadSoon];
        }],
        [AXAlertButton buttonWithTitle:@"取消" style:AXAlertButtonStyleCancel handler:nil]
    ]);
}

- (void)copyToken {
    if (![FLEXAiFlexMCPServer authRequired]) {
        [self toast:@"当前已关闭授权保护"];
        return;
    }
    NSString *token = [FLEXAiFlexMCPServer token];
    __weak typeof(self) weakSelf = self;
    AXPresentAlert(self, @"访问令牌", token ?: @"", AXAlertMessageStyleCode, nil, @[
        [AXAlertButton buttonWithTitle:@"复制" style:AXAlertButtonStylePrimary handler:^(AXGlassAlert *alert) {
            UIPasteboard.generalPasteboard.string = token ?: @"";
            [weakSelf toast:@"已复制访问令牌"];
        }],
        [AXAlertButton buttonWithTitle:@"关闭" style:AXAlertButtonStyleCancel handler:nil]
    ]);
}

- (void)editCustomToken {
    if (![FLEXAiFlexMCPServer authRequired]) {
        [self toast:@"当前已关闭授权保护"];
        return;
    }
    __weak typeof(self) weakSelf = self;
    AXPresentAlert(self, @"自定义授权码", @"6–64 位字母、数字、点、下划线或短横线。", AXAlertMessageStyleText,
        ^(UITextField *field) {
            field.placeholder = @"输入授权码";
            field.autocapitalizationType = UITextAutocapitalizationTypeNone;
            field.autocorrectionType = UITextAutocorrectionTypeNo;
        }, @[
        [AXAlertButton buttonWithTitle:@"保存" style:AXAlertButtonStylePrimary handler:^(AXGlassAlert *alert) {
            if (![FLEXAiFlexMCPServer setToken:alert.text]) {
                [weakSelf toast:@"授权码格式不正确"];
                return;
            }
            if ([FLEXAiFlexMCPServer isEnabled]) {
                [[FLEXAiFlexMCPServer shared] stop];
                [[FLEXAiFlexMCPServer shared] start];
            }
            [weakSelf toast:@"已更新授权码"];
        }],
        [AXAlertButton buttonWithTitle:@"取消" style:AXAlertButtonStyleCancel handler:nil]
    ]);
}

- (void)rotateToken {
    if (![FLEXAiFlexMCPServer authRequired]) {
        [self toast:@"当前已关闭授权保护"];
        return;
    }
    __weak typeof(self) weakSelf = self;
    AXPresentAlert(self, @"重新生成令牌", @"旧令牌立即失效，需要同步修改电脑端 MCP 配置。", AXAlertMessageStyleText,
        nil, @[
        [AXAlertButton buttonWithTitle:@"重新生成" style:AXAlertButtonStyleDestructive handler:^(AXGlassAlert *alert) {
            [FLEXAiFlexMCPServer rotateToken];
            if ([FLEXAiFlexMCPServer isEnabled]) {
                [[FLEXAiFlexMCPServer shared] stop];
                [[FLEXAiFlexMCPServer shared] start];
            }
            [weakSelf toast:@"已生成新令牌"];
        }],
        [AXAlertButton buttonWithTitle:@"取消" style:AXAlertButtonStyleCancel handler:nil]
    ]);
}

- (void)copyClientConfiguration {
    NSString *url = [FLEXAiFlexMCPServer endpoint], *json;
    if ([FLEXAiFlexMCPServer authRequired]) {
        json = [NSString stringWithFormat:
            @"{\"mcpServers\":{\"aiflex2\":{\"type\":\"http\",\"url\":\"%@\",\"headers\":{\"Authorization\":\"Bearer %@\"}}}}",
            url, [FLEXAiFlexMCPServer token]];
    } else {
        json = [NSString stringWithFormat:@"{\"mcpServers\":{\"aiflex2\":{\"type\":\"http\",\"url\":\"%@\"}}}", url];
    }
    UIPasteboard.generalPasteboard.string = json;
    [self toast:@"已复制 MCP 客户端配置"];
}

- (void)toast:(NSString *)text {
    UIWindow *window = self.view.window ?: UIApplication.sharedApplication.keyWindow;
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
                                     attributes:@{NSFontAttributeName: label.font}
                                        context:nil];
    label.frame = CGRectMake(0, 0, MIN(maxWidth, CGRectGetWidth(textBox) + 28),
                             MAX(36, CGRectGetHeight(textBox) + 20));
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

@end
