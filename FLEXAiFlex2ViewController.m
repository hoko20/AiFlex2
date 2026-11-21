#import "FLEXAiFlex2ViewController.h"
#import "FLEXAiFlexMCPServer.h"
#import "FLEXAiFlexRuntime.h"
#import "FLEXAiFlexSettingsViewController.h"
#import "FLEXManager.h"
#import "FLEXManager+Private.h"
#import "FLEXUtility.h"

typedef NS_ENUM(NSInteger, AXSection) {
    AXSectionContext = 0,
    AXSectionActions,
    AXSectionPermissions,
    AXSectionTools,
    AXSectionUsage,
    AXSectionCount
};

static __weak FLEXAiFlex2ViewController *AXCurrentPanel;

static NSString *AXShortText(NSString *text, NSUInteger limit) {
    if (![text isKindOfClass:NSString.class] || !text.length) return @"";
    if (text.length <= limit) return text;
    return [[text substringToIndex:limit] stringByAppendingString:@"…"];
}

@interface FLEXAiFlex2ViewController ()
@property (nonatomic, copy) NSString *report;
@property (nonatomic, copy) NSString *className;
@property (nonatomic) BOOL minimized;
@property (nonatomic) BOOL uiTransitioning;

@property (nonatomic) UILabel *statusPill;
@property (nonatomic) UILabel *endpointLabel;
@property (nonatomic) UILabel *tokenLabel;
@property (nonatomic) UILabel *heroSubtitle;
@end

@implementation FLEXAiFlex2ViewController

+ (instancetype)aiFlex2CurrentPanel { return AXCurrentPanel; }

- (instancetype)initWithReport:(NSString *)report className:(NSString *)className {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
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

    self.tableView.rowHeight = 48;
    self.tableView.tableHeaderView = [self buildHeader];
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(refresh) forControlEvents:UIControlEventValueChanged];

    [self syncRuntimeContext];
    [self refresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self sizeHeader];
}

#pragma mark - Header

- (UIView *)buildHeader {
    UIView *hero = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 210)];
    hero.backgroundColor = UIColor.clearColor;

    UIView *card = [UIView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    card.layer.cornerRadius = 16;
    [hero addSubview:card];

    UIView *badge = [UIView new];
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    badge.backgroundColor = [UIColor.systemBlueColor colorWithAlphaComponent:0.14];
    badge.layer.cornerRadius = 12;

    UIImageView *icon = [UIImageView new];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.image = [UIImage systemImageNamed:@"sparkles"];
    icon.tintColor = UIColor.systemBlueColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [badge addSubview:icon];

    UILabel *title = [UILabel new];
    title.text = @"AiFlex2";
    title.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];

    UILabel *subtitle = [UILabel new];
    subtitle.text = @"FLEX++ 运行时 · MCP 直连";
    subtitle.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    subtitle.textColor = UIColor.secondaryLabelColor;
    self.heroSubtitle = subtitle;

    UIStackView *titles = [[UIStackView alloc] initWithArrangedSubviews:@[title, subtitle]];
    titles.axis = UILayoutConstraintAxisVertical;
    titles.spacing = 2;

    UILabel *pill = [UILabel new];
    pill.textAlignment = NSTextAlignmentCenter;
    pill.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    pill.layer.cornerRadius = 11;
    pill.layer.masksToBounds = YES;
    self.statusPill = pill;

    UIStackView *topRow = [[UIStackView alloc] initWithArrangedSubviews:@[badge, titles, pill]];
    topRow.axis = UILayoutConstraintAxisHorizontal;
    topRow.spacing = 10;
    topRow.alignment = UIStackViewAlignmentCenter;
    [titles setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    UILabel *addressCaption = [self captionLabel:@"访问地址"];
    UILabel *addressValue = [UILabel new];
    addressValue.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    addressValue.textColor = UIColor.secondaryLabelColor;
    addressValue.lineBreakMode = NSLineBreakByTruncatingMiddle;
    addressValue.userInteractionEnabled = YES;
    [addressValue addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(editEndpoint)]];
    self.endpointLabel = addressValue;

    UILabel *tokenCaption = [self captionLabel:@"访问令牌"];
    UILabel *tokenValue = [UILabel new];
    tokenValue.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    tokenValue.textColor = UIColor.secondaryLabelColor;
    tokenValue.lineBreakMode = NSLineBreakByTruncatingMiddle;
    tokenValue.userInteractionEnabled = YES;
    [tokenValue addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(copyToken)]];
    self.tokenLabel = tokenValue;

    UILabel *hint = [UILabel new];
    hint.text = @"轻点地址可修改 · 轻点令牌可复制 · 服务随宿主 App 生命周期运行";
    hint.font = [UIFont systemFontOfSize:11];
    hint.textColor = UIColor.tertiaryLabelColor;
    hint.numberOfLines = 0;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        topRow, addressCaption, addressValue, tokenCaption, tokenValue, hint
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 6;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:hero.topAnchor constant:8],
        [card.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor constant:20],
        [card.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor constant:-20],
        [card.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor constant:-6],
        [badge.widthAnchor constraintEqualToConstant:46],
        [badge.heightAnchor constraintEqualToConstant:46],
        [icon.centerXAnchor constraintEqualToAnchor:badge.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:24],
        [icon.heightAnchor constraintEqualToConstant:24],
        [pill.widthAnchor constraintEqualToConstant:70],
        [pill.heightAnchor constraintEqualToConstant:22],
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14]
    ]];
    return hero;
}

- (UILabel *)captionLabel:(NSString *)text {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    label.textColor = UIColor.tertiaryLabelColor;
    return label;
}

- (void)sizeHeader {
    UIView *header = self.tableView.tableHeaderView;
    if (!header) return;
    CGFloat width = CGRectGetWidth(self.tableView.bounds);
    if (width <= 0 || fabs(CGRectGetWidth(header.frame) - width) < 0.5) return;
    header.frame = CGRectMake(0, 0, width, CGRectGetHeight(header.frame));
    [header setNeedsLayout];
    [header layoutIfNeeded];
    CGSize size = [header systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height)
                            withHorizontalFittingPriority:UILayoutPriorityRequired
                                  verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    header.frame = CGRectMake(0, 0, width, size.height);
    self.tableView.tableHeaderView = header;
}

- (void)refresh {
    BOOL enabled = [FLEXAiFlexMCPServer isEnabled];
    NSString *state = [FLEXAiFlexMCPServer status];
    self.statusPill.text = state;
    if ([state isEqualToString:@"运行中"]) {
        self.statusPill.textColor = UIColor.systemGreenColor;
        self.statusPill.backgroundColor = [UIColor.systemGreenColor colorWithAlphaComponent:0.14];
    } else if (!enabled) {
        self.statusPill.textColor = UIColor.secondaryLabelColor;
        self.statusPill.backgroundColor = [UIColor.systemGrayColor colorWithAlphaComponent:0.16];
    } else {
        self.statusPill.textColor = UIColor.systemOrangeColor;
        self.statusPill.backgroundColor = [UIColor.systemOrangeColor colorWithAlphaComponent:0.14];
    }
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
    [self.tableView reloadData];
    [self.refreshControl endRefreshing];
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

#pragma mark - Table data

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return AXSectionCount; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case AXSectionContext: return @"当前现场";
        case AXSectionActions: return @"快捷操作";
        case AXSectionPermissions: return @"授权";
        case AXSectionTools: return @"可用工具";
        default: return @"使用方式";
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == AXSectionPermissions) {
        NSString *(^state)(BOOL) = ^NSString *(BOOL on){ return on ? @"开" : @"关"; };
        NSString *summary = [NSString stringWithFormat:@"当前状态：授权保护 %@ · 敏感读取 %@ · 界面控制 %@ · 脚本执行 %@ · 方法追踪 %@",
            state([FLEXAiFlexMCPServer authRequired]), state([FLEXAiFlexMCPServer sensitiveEnabled]),
            state([FLEXAiFlexMCPServer controlEnabled]), state([FLEXAiFlexMCPServer scriptEnabled]),
            state([FLEXAiFlexMCPServer tracingEnabled])];
        return [NSString stringWithFormat:@"%@\n\n授权保护：开启后必须携带 Bearer 令牌；关闭后同局域网可直接连接，请仅在可信网络使用。\n敏感读取：允许头文件、日志/网络正文、文件搜索、截图与 Keychain 元数据。\n界面控制：允许点击、输入、滚动、手势和高亮；会真实改变 App 状态。\n脚本执行：允许在 WKWebView 中运行 JavaScript，只影响网页，但可能破坏页面状态。\n方法追踪：运行期替换指定方法并记录调用，可能导致崩溃或卡顿，默认关闭。", summary];
    }
    if (section == AXSectionTools) {
        return @"工具组关闭后，对应工具不会出现在 MCP tools/list 中。";
    }
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case AXSectionContext: return 3;
        case AXSectionActions: return 5;
        case AXSectionPermissions: return 5;
        case AXSectionTools: return [self toolRows].count;
        default: return 1;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == AXSectionTools || indexPath.section == AXSectionUsage) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"subtitle"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"subtitle"];
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
        cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        if (indexPath.section == AXSectionUsage) {
            cell.imageView.image = nil;
            cell.textLabel.text = @"MCP 客户端";
            cell.textLabel.font = [UIFont systemFontOfSize:15];
            cell.textLabel.textColor = UIColor.labelColor;
            cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
            cell.detailTextLabel.text = @"在 Claude Desktop、Cursor、Cherry Studio 等客户端添加 Streamable HTTP 服务，URL 填上方访问地址；需要授权时在请求头加 Authorization: Bearer <访问令牌>。";
            return cell;
        }
        NSArray *tools = [self toolRows];
        NSDictionary *tool = tools[indexPath.row];
        cell.textLabel.text = tool[@"name"];
        cell.textLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightSemibold];
        cell.detailTextLabel.text = tool[@"detail"];
        BOOL enabled = [tool[@"enabled"] boolValue];
        cell.textLabel.textColor = enabled ? UIColor.labelColor : UIColor.secondaryLabelColor;
        cell.detailTextLabel.textColor = enabled ? UIColor.secondaryLabelColor : UIColor.tertiaryLabelColor;
        cell.imageView.image = [UIImage systemImageNamed:enabled ? @"checkmark.circle.fill" : @"circle"];
        cell.imageView.tintColor = enabled ? UIColor.systemGreenColor : UIColor.tertiaryLabelColor;
        return cell;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"value"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"value"];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.textLabel.font = [UIFont systemFontOfSize:16];
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailTextLabel.numberOfLines = 1;

    if (indexPath.section == AXSectionContext) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"当前对象";
            cell.detailTextLabel.text = self.className;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"现场报告";
            NSString *summary = [self reportSummary];
            cell.detailTextLabel.text = summary.length ? AXShortText(summary, 80) : @"暂无";
            cell.detailTextLabel.numberOfLines = 2;
            cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            cell.textLabel.text = @"复制现场报告";
            cell.detailTextLabel.text = @"";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        return cell;
    }

    if (indexPath.section == AXSectionActions) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        NSArray *icons = @[@"doc.on.doc", @"bolt.fill", @"gearshape", @"arrow.triangle.2.circlepath", @"chevron.down"];
        NSArray *labels = @[@"复制 MCP 客户端配置", @"一键开启常用工具组", @"服务设置",
            [FLEXAiFlexMCPServer isEnabled] ? @"重启 MCP 服务" : @"开启 MCP 服务", @"收起面板（回到 App）"];
        cell.imageView.image = [UIImage systemImageNamed:icons[indexPath.row]];
        cell.imageView.tintColor = indexPath.row == 1 ? UIColor.systemOrangeColor : UIColor.systemBlueColor;
        cell.textLabel.text = labels[indexPath.row];
        cell.textLabel.textColor = indexPath.row == 4 ? UIColor.systemBlueColor : UIColor.labelColor;
        return cell;
    }

    // Permissions
    if (indexPath.section == AXSectionPermissions) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"permission"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"permission"];
        }
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.textColor = UIColor.labelColor;
        cell.textLabel.font = [UIFont systemFontOfSize:16];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:11];
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        cell.detailTextLabel.numberOfLines = 0;
        NSArray *titles = @[@"授权保护", @"敏感读取", @"界面控制", @"脚本执行", @"方法追踪"];
        NSArray *details = @[
            @"要求客户端携带 Bearer 令牌；关闭后同局域网可直接连接",
            @"头文件、日志/网络正文、文件搜索、截图、Keychain 元数据",
            @"点击、输入、滚动、手势、方法调用与高亮，会改变 App 状态",
            @"在 WKWebView 执行 JavaScript，可能改变网页状态",
            @"替换方法实现并记录调用，高风险，10 分钟自动停止"
        ];
        cell.textLabel.text = titles[indexPath.row];
        cell.detailTextLabel.text = details[indexPath.row];
        UISwitch *toggle = [UISwitch new];
        toggle.tag = 900 + indexPath.row;
        if (indexPath.row == 0) toggle.on = [FLEXAiFlexMCPServer authRequired];
        else if (indexPath.row == 1) toggle.on = [FLEXAiFlexMCPServer sensitiveEnabled];
        else if (indexPath.row == 2) toggle.on = [FLEXAiFlexMCPServer controlEnabled];
        else if (indexPath.row == 3) toggle.on = [FLEXAiFlexMCPServer scriptEnabled];
        else toggle.on = [FLEXAiFlexMCPServer tracingEnabled];
        if (indexPath.row == 0 && ![FLEXAiFlexMCPServer isEnabled]) {
            cell.textLabel.textColor = UIColor.secondaryLabelColor;
        } else if (indexPath.row >= 3 && toggle.on) {
            cell.textLabel.textColor = UIColor.systemOrangeColor;
        }
        [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        return cell;
    }

    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (NSArray<NSDictionary *> *)toolRows {
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

#pragma mark - Table delegate

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == AXSectionUsage) return 120;
    if (indexPath.section == AXSectionPermissions) return 70;
    if (indexPath.section == AXSectionTools) return 62;
    if (indexPath.section == AXSectionContext && indexPath.row == 1) return 76;
    return 48;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == AXSectionContext && indexPath.row == 2) {
        [self copyText:self.report message:@"已复制现场报告"];
        return;
    }
    if (indexPath.section == AXSectionActions) {
        if (indexPath.row == 0) [self copyClientConfiguration];
        else if (indexPath.row == 1) [self enableAllGroupsTapped];
        else if (indexPath.row == 2) [self openSettings];
        else if (indexPath.row == 3) [self restartService];
        else [self collapseTapped];
    }
}

- (void)toggleChanged:(UISwitch *)sender {
    NSInteger row = sender.tag - 900;
    if (row == 0) {
        [FLEXAiFlexMCPServer setAuthRequired:sender.on];
        if ([FLEXAiFlexMCPServer isEnabled]) {
            [[FLEXAiFlexMCPServer shared] stop];
            [[FLEXAiFlexMCPServer shared] start];
        }
    } else if (row == 1) {
        [FLEXAiFlexMCPServer setSensitiveEnabled:sender.on];
    } else if (row == 2) {
        [FLEXAiFlexMCPServer setControlEnabled:sender.on];
    } else if (row == 3) {
        [FLEXAiFlexMCPServer setScriptEnabled:sender.on];
    } else if (row == 4) {
        [FLEXAiFlexMCPServer setTracingEnabled:sender.on];
    }
    [self refresh];
}

#pragma mark - Actions

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
