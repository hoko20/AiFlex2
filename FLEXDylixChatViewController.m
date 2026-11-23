#import "FLEXDylixChatViewController.h"
#import "FLEXAiFlexRuntime.h"
#import "FLEXDylixAddress.h"
#import "FLEXDylixConnection.h"
#import "FLEXDylixPreferences.h"
#import "FLEXAiFlex2UI.h"
#import "FLEXDylixMarkdown.h"
#import "FLEXDylixStatusWindow.h"
#import "FLEXManager+Private.h"
#import "FLEXUtility.h"
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <math.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <unistd.h>

typedef void (^DXChatReply)(NSDictionary *data, NSError *error);
static NSError *DXChatError(NSString *message) { return [NSError errorWithDomain:@"FLEX.AiFlex2" code:1 userInfo:@{NSLocalizedDescriptionKey:message?:@"连接失败"}]; }
// 与 AiFlex2 App 的默认值对齐：App 默认在 Wi-Fi 局域网模式监听 8787，插件与它同机时，
// 本机 Wi-Fi 地址就是 App 的监听地址，所以这里取宿主自己的 en0 IPv4 做默认地址。
static NSString *FLEXDylixLocalIPv4(void) {
    struct ifaddrs *interfaces = NULL;
    NSString *fallback = nil;
    if (getifaddrs(&interfaces) != 0) return @"127.0.0.1";
    for (struct ifaddrs *cursor = interfaces; cursor; cursor = cursor->ifa_next) {
        if (!cursor->ifa_addr || cursor->ifa_addr->sa_family != AF_INET) continue;
        if (cursor->ifa_flags & IFF_LOOPBACK) continue;
        NSString *name = cursor->ifa_name ? [NSString stringWithUTF8String:cursor->ifa_name] : @"";
        char buffer[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &((struct sockaddr_in *)cursor->ifa_addr)->sin_addr,
                  buffer, sizeof(buffer));
        NSString *address = [NSString stringWithUTF8String:buffer];
        if (!address.length || [address hasPrefix:@"169.254."]) continue;
        if ([name hasPrefix:@"en"]) { fallback = address; break; }
        if (!fallback) fallback = address;
    }
    freeifaddrs(interfaces);
    return fallback ?: @"127.0.0.1";
}
static NSDictionary *DXRememberedChat;
static __weak FLEXDylixChatViewController *DXCurrentChat;
// 同进程内最近一次确认连上 App 的时刻。会话页收起又点回来时，
// 状态行不必再回到“正在检查连接…”跳一下，直接沿用已连接。
static NSTimeInterval DXLastConnectedStamp;
// 用户消息在 App 侧会带上一大段 FLEX 现场上下文；插件里只显示用户真正问的那句。
static NSString *DXChatUserText(NSString *text) {
    if(!text.length)return @"";
    NSRange marker=[text rangeOfString:@"\n\n我的问题：" options:NSBackwardsSearch];
    if(marker.location!=NSNotFound&&[text hasPrefix:@"当前 FLEX 现场："])text=[text substringFromIndex:NSMaxRange(marker)];
    NSRange next=[text rangeOfString:@"\n\n当前 FLEX 现场："];
    if(next.location!=NSNotFound)text=[text substringToIndex:next.location];
    return text;
}

static NSString *DXChatContent(id content) {
 if([content isKindOfClass:NSString.class])return content;
 if(![content isKindOfClass:NSArray.class])return @"";
 NSMutableArray *parts=[NSMutableArray new];
 for(id item in content)if([item isKindOfClass:NSDictionary.class]&&[item[@"text"] isKindOfClass:NSString.class])[parts addObject:item[@"text"]];
 return [parts componentsJoinedByString:@"\n"];
}

@interface FLEXDylixChatViewController () <UITextViewDelegate>
@property NSString *report, *className, *host, *token, *csrf, *projectID, *projectName, *connectionID, *modelID, *modelName, *sessionID, *sessionTitle, *jobID;
@property NSUInteger port;
@property NSString *authorizationCode;
@property BOOL needsConnectionValidation, validatingConnection, restoringWorkspace, storageWarningShown;
// 打开这条会话时 FLEX 面板是不是已经在屏上。决定左上角「返回」退到哪里：
// 从面板进来的回面板，从悬浮球/通知进来的回到 App 并保留悬浮球。
@property BOOL explorerWasHidden;
// 上一次自动校验连接失败的时刻。只做 MCP 的用户不会去连 App 侧通道，
// 但每次点进这个页面都会重新校验一次、干等一个超时，这里用来抑制重复空等。
@property NSTimeInterval lastValidateFailure;
- (void)rememberConnectionNow;
- (NSMutableArray<NSMutableDictionary *> *)transcriptFrom:(NSArray *)raw;
- (BOOL)applyTranscript:(NSArray *)raw;
- (void)failPendingReply:(NSError *)error;
- (void)finishReplyWithResult:(NSDictionary *)result;
- (void)noteEmptyReply;
- (void)nextPollIn:(NSTimeInterval)interval;
- (void)buildNavigationItems;
- (void)syncFlexSelection;
- (void)updateContextLabel;
- (void)hideStatusBall;
- (BOOL)chatOnScreen;
- (UIView *)buildHeader;
- (void)buildMessageList;
- (UIView *)buildComposer;
- (UIButton *)iconButton:(NSString *)symbol action:(SEL)action label:(NSString *)label;
@property UILabel *statusLabel, *activityLabel, *contextLabel;
@property UITextView *input;
@property UIScrollView *messageScroll;
@property UIStackView *messageStack;
@property UILabel *inputPlaceholder, *liveLabel;
@property UIView *statusDot;
@property NSLayoutConstraint *inputHeight;
@property NSMutableArray<NSMutableDictionary *> *messages;
@property NSMutableDictionary *liveMessage;
@property UIButton *connectButton, *permissionButton, *projectButton, *modelButton, *sessionButton, *sendButton;
// 顶部状态行里的两个常驻开关：自动允许、屏幕常亮。默认都关，点亮表示已开启。
@property UIButton *autoApproveButton, *keepAwakeButton;
@property BOOL keepAwake;
@property NSMutableDictionary<NSString *,NSString *> *drafts;
@property NSUInteger sessionLoadGeneration, missedHeartbeats;
@property (nonatomic) BOOL busy;
@property BOOL liveHasContent;
@property FLEXAiFlexRuntime *runtime;
@property NSTimer *agentTimer;
@property NSMutableDictionary<NSString *,NSDictionary *> *agentReplies;
@property NSString *pendingCommandID;
@property BOOL agentPolling;
@property BOOL agentReplying;
@property BOOL chatMinimized;
@property BOOL agentStopped, uiTransitioning;
@property NSUInteger agentGeneration;
@property NSMutableDictionary<NSString *,NSNumber *> *commandGenerations;
@property FLEXDylixStatusWindow *statusWindow;
// 会话页所在的那套导航；页面被 FLEX 面板收起、甚至整块面板被关闭后，
// self.navigationController 可能已经变成 nil，这里留一份强引用以便原地恢复。
@property (nonatomic,strong) UINavigationController *chatNavigation;
// 悬浮球的出现时刻：等页面转场稳定后再显示，避免切换瞬间一闪而过。
@property (nonatomic) NSTimeInterval statusShowStamp;
@property (nonatomic) BOOL statusRefreshScheduled;
@property NSString *taskPhase, *localOperation;
@property NSString *idleStatus, *captureStatus, *captureID;
@property NSMutableDictionary<NSString *,NSString *> *activeToolOperations;
@property NSUInteger connectionState, lastEventSequence;
@property NSString *reasoningEffort;
@property NSArray<NSDictionary *> *reasoningOptions;
@property NSUInteger lastCaptureSequence;
@property NSTimeInterval lastTaskUpdate;
// AI 任务等待计时：用来在状态栏里说明“还在等模型”，并给卡死的任务一个上限。
@property NSTimeInterval jobStartedAt;
@property NSUInteger jobNoticeMinutes;
// 轮询每秒都会带一次全文和状态：节流掉重复的 Markdown 重排、滚动和写盘。
@property NSTimeInterval lastLiveRender;
@property NSTimeInterval lastRemember;
@property BOOL waitingApproval;
@property BOOL statusSuspended;
// 打开后本次会话不再弹确认框，AI 申请的操作直接放行；默认关闭，随会话持久化。
@property BOOL autoApprove;
@property NSError *lastConnectionError;
@end

@implementation FLEXDylixChatViewController
@synthesize busy=_busy;
- (void)setBusy:(BOOL)busy {
 _busy=busy;
 if(!busy){[self.activeToolOperations removeAllObjects];self.waitingApproval=NO;}
 [self.sendButton setTitle:busy?@"停止":@"发送" forState:UIControlStateNormal];
 [self refreshAgentStatus];
}
- (instancetype)initWithReport:(NSString *)report className:(NSString *)className {
 if ((self=[super init])) { // 新实例接管这个进程里的 AI 会话：旧实例的悬浮球必须马上撤掉，
  // 否则它会带着自己的 window 浮在新页面上（就是「进了会话还看得见球」）。
  FLEXDylixChatViewController *previous=DXCurrentChat;if(previous&&previous!=self)[previous hideStatusBall];
  DXCurrentChat=self; _report=[report copy]?:@""; _className=[className copy]?:@"未知对象"; _explorerWasHidden=FLEXManager.sharedManager.isHidden; [FLEXAiFlexRuntime sharedRuntime].contextReport=_report;[FLEXAiFlexRuntime sharedRuntime].contextClassName=_className; _messages=[NSMutableArray new]; _drafts=[NSMutableDictionary new];_activeToolOperations=[NSMutableDictionary new]; _autoApprove=[NSUserDefaults.standardUserDefaults boolForKey:@"FLEX.AiFlex2.AutoApprove.v1"]; _keepAwake=[NSUserDefaults.standardUserDefaults boolForKey:@"FLEX.AiFlex2.KeepAwake.v1"]; [self restoreConnection];[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationStateChanged:) name:UIApplicationDidBecomeActiveNotification object:nil];[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationStateChanged:) name:UIApplicationWillResignActiveNotification object:nil]; }
 return self;
}
- (void)restoreConnection {
 NSDictionary *state=DXRememberedChat?:[FLEXDylixPreferences loadState];
 self.host=state[@"host"];self.port=[state[@"port"] unsignedIntegerValue];self.token=state[@"token"];self.csrf=state[@"csrf"];self.authorizationCode=state[@"authorizationCode"];
 self.projectID=state[@"projectID"];self.projectName=state[@"projectName"];self.connectionID=state[@"connectionID"];self.modelID=state[@"modelID"];self.modelName=state[@"modelName"];self.sessionID=state[@"sessionID"];self.sessionTitle=state[@"sessionTitle"];
 self.needsConnectionValidation=self.host.length&&self.token.length;
 for(NSDictionary *item in state[@"messages"]){if([item isKindOfClass:NSDictionary.class]&&[item[@"role"] isKindOfClass:NSString.class]&&[item[@"text"] isKindOfClass:NSString.class])[self.messages addObject:[item mutableCopy]];}
}
- (void)rememberConnection { [self rememberConnection:NO]; }
// 强制写入：离开页面、最小化、配对成功这类"进程可能随时被挂起"的时刻才需要。
- (void)rememberConnectionNow { [self rememberConnection:YES]; }
- (void)rememberConnection:(BOOL)force {
 if(!self.host.length||!self.port)return;
 // 这里会复制整份会话并写 UserDefaults；流式期间每秒一次纯属浪费，节流到 3 秒。
 NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
 if(!force&&self.lastRemember>0&&now-self.lastRemember<3.0)return;
 self.lastRemember=now;
 NSMutableDictionary *state=[@{@"host":self.host,@"port":@(self.port)} mutableCopy];
 for(NSString *key in @[@"authorizationCode",@"token",@"csrf",@"projectID",@"projectName",@"connectionID",@"modelID",@"modelName",@"sessionID",@"sessionTitle"]){id value=[self valueForKey:key];if(value)state[key]=value;}
 NSError *error=nil;if(![FLEXDylixPreferences saveState:state error:&error]&&!self.storageWarningShown){self.storageWarningShown=YES;self.activityLabel.text=error.localizedDescription;}
 // Chat text stays in memory only; Dylix remains the source of durable history.
 NSMutableArray *saved=[NSMutableArray new];for(NSDictionary *item in self.messages)[saved addObject:item.copy];state[@"messages"]=saved;
 DXRememberedChat=state.copy;
}
- (void)resumeSavedConnection {
 if(self.validatingConnection||!self.host.length||!self.token.length)return;
 self.validatingConnection=YES;
 // 20 秒内刚确认过连接（收起会话又点回来的常见路径），状态行保持绿色，
 // 校验在后台静默进行；否则每次进页面都会看到“已连接 → 正在检查 → 已连接”的闪跳。
 BOOL recentlyConnected=DXLastConnectedStamp>0&&NSProcessInfo.processInfo.systemUptime-DXLastConnectedStamp<20;
 if(!recentlyConnected)[self showConnectionState:1];
 NSString *host=self.host,*token=self.token;NSUInteger generation=self.sessionLoadGeneration;
 [self request:@"/api/v1/status" body:@{} completion:^(NSDictionary *status,NSError *error){
  self.validatingConnection=NO;if(generation!=self.sessionLoadGeneration||![host isEqual:self.host]||![token isEqual:self.token])return;
  if(error){self.lastConnectionError=error;self.lastValidateFailure=NSProcessInfo.processInfo.systemUptime;[self showConnectionState:3];[self setStatus:[NSString stringWithFormat:@"%@ · 配置已保留，连接设置可查看诊断",[[error.localizedDescription componentsSeparatedByString:@"\n"] firstObject]]];return;}
  NSString *csrf=status[@"session"][@"csrf"];if(![csrf isKindOfClass:NSString.class]||!csrf.length){self.lastValidateFailure=NSProcessInfo.processInfo.systemUptime;[self showConnectionState:3];[self setStatus:@"保存的授权已失效，地址和选择已保留，请重新配对"];return;}
  self.csrf=csrf;self.needsConnectionValidation=NO;self.lastValidateFailure=0;self.missedHeartbeats=0;[self showConnectionState:2];[self rememberConnectionNow];[self startAgentPolling];[self restoreSavedWorkspace];
 }];
}
- (void)restoreSavedWorkspace {
 NSString *project=self.projectID,*session=self.sessionID;NSUInteger generation=self.sessionLoadGeneration;
 if(!project.length){[self setStatus:@"已恢复连接，请选择项目"];return;}
 self.restoringWorkspace=YES;
 [self workspace:@"projects" arguments:@{} completion:^(NSDictionary *data,NSError *error){
  if(generation!=self.sessionLoadGeneration||![project isEqual:self.projectID])return;if(error){self.restoringWorkspace=NO;[self showError:error];return;}
  NSDictionary *found=nil;for(NSDictionary *item in data[@"projects"])if([item[@"id"] isEqual:project]){found=item;break;}
  if(!found){self.restoringWorkspace=NO;self.projectID=nil;self.projectName=nil;self.sessionID=nil;self.sessionTitle=nil;[self.messages removeAllObjects];[self renderMessages];[self.projectButton setTitle:@"选择项目" forState:UIControlStateNormal];[self updateSessionButton];[self setStatus:@"上次项目已不存在，请重新选择"];return;}
  self.projectName=found[@"name"]?:self.projectName;[self.projectButton setTitle:self.projectName?:@"选择项目" forState:UIControlStateNormal];
  [self workspace:@"ai_connections" arguments:@{} completion:^(NSDictionary *connections,NSError *failure){
   if(generation!=self.sessionLoadGeneration||![project isEqual:self.projectID])return;if(failure){self.restoringWorkspace=NO;[self showError:failure];return;}
   BOOL exists=NO;for(NSDictionary *item in connections[@"connections"])if([item[@"id"] isEqual:self.connectionID]&&[item[@"model"] isEqual:self.modelID]){exists=YES;break;}
   if(!exists){self.connectionID=nil;self.modelID=nil;self.modelName=nil;}[self.modelButton setTitle:self.modelID?:@"选择模型" forState:UIControlStateNormal];
   if(!session.length){self.restoringWorkspace=NO;[self setStatus:exists?@"已恢复上次项目和模型":@"已恢复项目，请重新选择模型"];return;}
   [self workspace:@"ai_read" arguments:@{@"sessionID":session} completion:^(NSDictionary *record,NSError *readError){
    if(generation!=self.sessionLoadGeneration||![project isEqual:self.projectID]||![session isEqual:self.sessionID])return;
    self.restoringWorkspace=NO;
    if(readError){if(readError.code==404){self.sessionID=nil;self.sessionTitle=nil;[self.messages removeAllObjects];[self renderMessages];[self updateSessionButton];}[self setStatus:@"上次会话暂时无法读取，请在会话列表中检查；项目和模型未切换"];return;}
    if([record[@"title"] isKindOfClass:NSString.class])self.sessionTitle=record[@"title"];
    if(![self applyTranscript:record[@"messages"]]){[self.messages removeAllObjects];[self renderMessages];}
    [self updateSessionButton];[self setStatus:exists?@"已恢复上次项目、模型和会话":@"已恢复上次会话，请重新选择模型"];
   }];
  }];
 }];
}
- (void)updateReport:(NSString *)report className:(NSString *)className selectedObject:(id)object {
 self.report=[report copy]?:@"";self.className=[className copy]?:@"未知对象";self.selectedObject=object;
 self.runtime.selectedObject=object;
 [FLEXAiFlexRuntime sharedRuntime].selectedObject=object;
 [FLEXAiFlexRuntime sharedRuntime].contextReport=self.report;
 [FLEXAiFlexRuntime sharedRuntime].contextClassName=self.className;
 [self updateContextLabel];
}

// 会话页是复用的：先开会话、再回 FLEX 里点选别的视图，页头如果一直停在
// 打开时的那个对象（常见就是兜底出来的 UIWindow），看起来就像「不显示当前选择的视图」。
// 这里每次进页面和每轮轮询都跟共享运行时对齐一次，选中对象变了就同步类名与现场报告。
- (void)syncFlexSelection {
 FLEXAiFlexRuntime *runtime=[FLEXAiFlexRuntime sharedRuntime];
 id selected=runtime.selectedObject;
 if(![selected isKindOfClass:UIView.class])return;
 NSString *name=NSStringFromClass([selected class]);if(!name.length)return;
 BOOL changed=![self.className isEqual:name];
 if(!changed&&self.selectedObject==selected)return;
 self.selectedObject=selected;self.className=name;
 // 报告首行写的是 Current FLEX selection；换目标时把它换掉，其余现场描述沿用运行时最新的一份。
 if(runtime.contextReport.length)self.report=runtime.contextReport;
 else if(!self.report.length||[self.report rangeOfString:@"Current FLEX selection:"].location!=NSNotFound)
  self.report=[NSString stringWithFormat:@"App: %@\nCurrent FLEX selection: %@\nUse this runtime evidence to locate the UI owner and implement the requested behavior in the AiFlex2 project. A temporary FLEX view change is not a plugin implementation.",NSBundle.mainBundle.bundleIdentifier?:@"unknown",name];
 [self updateContextLabel];
}
- (void)updateContextLabel {
 NSString *name=self.className.length?self.className:@"未选择视图";
 if([name isEqual:@"UIWindow"])name=@"未选择视图 · 当前窗口";
 self.contextLabel.text=[@"FLEX 现场  ·  " stringByAppendingString:name];
}
- (void)contextTapped {
 [self syncFlexSelection];
 if(self.className.length&&![self.className isEqual:@"UIWindow"]){
  [self setStatus:[@"已同步当前现场 · " stringByAppendingString:self.className]];return;
 }
 // 没选中视图时只说「UIWindow」等于什么也没说，直接把怎么选讲清楚。
 AXPresentAlert(self,@"FLEX 现场",@"现在还没有选中视图，AI 只能看到「当前窗口」。\n\n回到 FLEX，点工具条上的「选择」，再点一下目标视图（例如那条广告），这里就会自动同步成它的类名，发给 AI 的现场报告也会一起更新。",AXAlertMessageStyleText,nil,@[
  [AXAlertButton buttonWithTitle:@"知道了" style:AXAlertButtonStylePrimary handler:nil]
 ]);
}
- (UIButton *)button:(NSString *)title action:(SEL)action {
 UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem]; [button setTitle:title forState:UIControlStateNormal];
 button.titleLabel.font=[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
 button.contentEdgeInsets=UIEdgeInsetsMake(8,10,8,10); button.layer.cornerRadius=10;
 if (@available(iOS 13.0, *)) button.backgroundColor=UIColor.secondarySystemGroupedBackgroundColor;
 else button.backgroundColor=UIColor.whiteColor;
 [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside]; return button;
}
+ (instancetype)dylixCurrentChat { return DXCurrentChat; }
- (void)performWindowOperation:(NSString *)operation arguments:(NSDictionary *)arguments completion:(void (^)(NSDictionary *result, NSString *error))completion {
 if([operation isEqual:@"chat_status"]){completion([self chatWindowStatus],nil);return;}
 if(self.uiTransitioning){completion(nil,@"窗口正在切换，请稍后重新读取 chat_status");return;}
 self.uiTransitioning=YES;
 void (^done)(void)=^{self.uiTransitioning=NO;completion([self chatWindowStatus],nil);};
 if([operation isEqual:@"minimize_chat"]){[self minimizeChat:![arguments[@"surface"] isEqual:@"flex"] completion:done];return;}
 if([operation isEqual:@"restore_chat"]){[self restoreChatWithCompletion:done];return;}
 if([operation isEqual:@"open_tool"]){
  NSString *failure=nil;UIViewController *controller=nil;
  @try{controller=[self.runtime controllerForTool:arguments[@"tool_id"] error:&failure];}@catch(NSException *exception){failure=[NSString stringWithFormat:@"FLEX 入口暂不可用（%@）",exception.name];}
  if(!controller){self.uiTransitioning=NO;completion(nil,failure);return;}
  [self minimizeChat:NO completion:^{[FLEXManager.sharedManager dismissAnyPresentedTools:^{[FLEXManager.sharedManager presentEmbeddedTool:controller completion:^(UINavigationController *nav){done();}];}];}];return;
 }
 UIViewController *visible=[FLEXUtility topViewControllerInWindow:FLEXManager.sharedManager.explorerWindow];
 if([visible isKindOfClass:UIAlertController.class]||AXGlassAlertVisible()){self.uiTransitioning=NO;completion(nil,@"请先人工处理当前弹窗");return;}
 if([operation isEqual:@"navigate_back"]){
  UINavigationController *nav=visible.navigationController;
  if(nav.viewControllers.count<2){self.uiTransitioning=NO;completion(nil,@"当前 FLEX 页已经在导航根部");return;}
  [nav popViewControllerAnimated:NO];done();return;
 }
 [FLEXManager.sharedManager dismissAnyPresentedTools:^{done();}];
}
- (void)viewDidLoad {
 [super viewDidLoad]; self.title=@"AiFlex2 AI"; self.view.backgroundColor=UIColor.systemGroupedBackgroundColor;
 self.runtime=[FLEXAiFlexRuntime sharedRuntime];self.runtime.selectedObject=self.selectedObject;self.agentReplies=[NSMutableDictionary new];self.commandGenerations=[NSMutableDictionary new];
 [self buildNavigationItems];
 UIView *header=[self buildHeader];
 [self buildMessageList];
 UIView *composer=[self buildComposer];
 for(UIView *view in @[header,self.messageScroll,composer]){view.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:view];}
 // 最低支持 iOS 15，键盘引导线恒定可用，不再需要退回 safeArea 的遮挡分支。
 UILayoutGuide *bottom=self.view.keyboardLayoutGuide;
 [NSLayoutConstraint activateConstraints:@[
  [header.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],[header.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],[header.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
  [self.messageScroll.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:8],[self.messageScroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.messageScroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
  [composer.topAnchor constraintEqualToAnchor:self.messageScroll.bottomAnchor constant:8],[composer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],[composer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],[composer.bottomAnchor constraintEqualToAnchor:bottom.topAnchor constant:-8]
 ]];
 if(!self.messages.count)[self.messages addObject:[@{@"role":@"tip",@"text":@"选中 FLEX 对象后直接提问。AI 可读取现场报告，并按权限调用实时工具。"} mutableCopy]];
 [self updateSessionButton];[self showConnectionState:self.csrf.length?(self.connectionState?:1):0];
 [self updateToggleButtons];[self applyKeepAwake];
 [self renderMessages];
}

#pragma mark - Layout

// 顶栏只保留必要信息，改成图标按钮后窄屏不再挤掉状态文字。
- (void)buildNavigationItems {
 UIBarButtonItem *newSession=[[UIBarButtonItem alloc]initWithImage:[UIImage systemImageNamed:@"square.and.pencil"] style:UIBarButtonItemStylePlain target:self action:@selector(newSession)];
 newSession.accessibilityLabel=@"新会话";
 UIBarButtonItem *disconnect=[[UIBarButtonItem alloc]initWithImage:[UIImage systemImageNamed:@"wifi.slash"] style:UIBarButtonItemStylePlain target:self action:@selector(disconnectTapped)];
 disconnect.accessibilityLabel=@"断开连接";
 self.navigationItem.rightBarButtonItems=@[disconnect,newSession];
 // 会话页有两条到达路径：从 AiFlex2 面板 push（系统会给返回箭头），
 // 以及从悬浮球/通知以整页弹层恢复（自己就是栈根，系统不给任何返回按钮）。
 // 后者以前顶部只有标题，用户没有退路；这里自己补一个 "<"。
 UINavigationController *nav=self.navigationController?:self.chatNavigation;
 if(nav&&nav.viewControllers.firstObject!=self){self.navigationItem.leftBarButtonItem=nil;return;}
 UIBarButtonItem *back=[[UIBarButtonItem alloc]initWithImage:[UIImage systemImageNamed:@"chevron.left"] style:UIBarButtonItemStylePlain target:nil action:nil];
 back.accessibilityLabel=self.explorerWasHidden?@"返回到 App，会话收为悬浮球":@"返回 FLEX 面板";
 // 轻点是「返回」；长按展开两个明确动作——收起成悬浮球的能力不丢，但不再占一个图标位。
 __weak typeof(self) weakSelf=self;
 back.primaryAction=[UIAction actionWithTitle:@"返回" image:nil identifier:nil handler:^(UIAction *action){typeof(self) chat=weakSelf;if(chat)[chat backTapped];}];
 UIAction *toPanel=[UIAction actionWithTitle:@"返回 FLEX 面板" image:[UIImage systemImageNamed:@"square.grid.2x2"] identifier:nil handler:^(UIAction *action){typeof(self) chat=weakSelf;if(chat&&!chat.uiTransitioning)[chat minimizeChat:NO completion:^{}];}];
 UIAction *toBall=[UIAction actionWithTitle:@"收起为悬浮球" image:[UIImage systemImageNamed:@"minus.circle"] identifier:nil handler:^(UIAction *action){typeof(self) chat=weakSelf;if(chat&&!chat.uiTransitioning)[chat minimizeChat:YES completion:^{}];}];
 back.menu=[UIMenu menuWithTitle:@"" children:@[toPanel,toBall]];
 self.navigationItem.leftBarButtonItem=back;
}

// 「返回」按进入方式退：面板进来的回面板，悬浮球进来的回 App（会话继续以球的形式待命）。
- (void)backTapped {
 if(self.uiTransitioning)return;
 self.uiTransitioning=YES;
 [self minimizeChat:self.explorerWasHidden completion:^{self.uiTransitioning=NO;}];
}

// 三行信息（状态与入口 / 项目·模型·会话 / 现场与活动）外面套玻璃卡，
// 和面板其它页同一套视觉；纯白圆角块在深色模式下会和背景糊成一片。
- (UIView *)buildHeader {
 self.statusLabel=[UILabel new];
 self.statusLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
 self.statusLabel.textColor=UIColor.secondaryLabelColor;
 self.statusLabel.text=self.csrf.length?@"正在检查连接":@"未连接";
 self.statusLabel.lineBreakMode=NSLineBreakByTruncatingTail;
 [self.statusLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
 // 文案里一直写着“点击重连”，那就真的让它能点：中断后不用再去找齿轮。
 self.statusLabel.userInteractionEnabled=YES;
 self.statusLabel.accessibilityTraits=UIAccessibilityTraitButton;
 [self.statusLabel addGestureRecognizer:[[UITapGestureRecognizer alloc]initWithTarget:self action:@selector(statusTapped)]];

 self.statusDot=[UIView new];
 self.statusDot.backgroundColor=UIColor.systemGrayColor;
 self.statusDot.layer.cornerRadius=4;
 self.statusDot.translatesAutoresizingMaskIntoConstraints=NO;
 [NSLayoutConstraint activateConstraints:@[
  [self.statusDot.widthAnchor constraintEqualToConstant:8],[self.statusDot.heightAnchor constraintEqualToConstant:8]
 ]];

 self.connectButton=[self iconButton:@"gearshape" action:@selector(connectTapped) label:@"连接设置"];
 self.permissionButton=[self iconButton:@"lock.shield" action:@selector(permissionTapped) label:@"工具权限"];
 // 原来这里是 MCP（地球）图标，按需求换成「自动允许」：这个开关日常要随手开。
 // MCP 入口改到齿轮（连接设置）里的「MCP 服务」一行，不会丢。
 self.autoApproveButton=[self iconButton:@"hand.raised" action:@selector(autoApproveTapped) label:@"自动允许 AI 操作"];
 self.autoApproveButton.accessibilityHint=@"点亮后 AI 的写入、构建、现场操作不再逐次弹窗确认";
 self.keepAwakeButton=[self iconButton:@"sun.max" action:@selector(keepAwakeTapped) label:@"任务期间保持常亮"];
 self.keepAwakeButton.accessibilityHint=@"点亮后会话页打开或 AI 执行任务时不会自动锁屏，收起且空闲后自动交还系统";

 UIStackView *statusRow=[[UIStackView alloc]initWithArrangedSubviews:@[self.statusDot,self.statusLabel,self.autoApproveButton,self.keepAwakeButton,self.permissionButton,self.connectButton]];
 statusRow.axis=UILayoutConstraintAxisHorizontal;
 statusRow.spacing=6;
 statusRow.alignment=UIStackViewAlignmentCenter;

 self.projectButton=[self button:@"选择项目" action:@selector(projectTapped)];
 self.modelButton=[self button:@"选择模型" action:@selector(modelTapped)];
 self.sessionButton=[self button:@"会话 · 新会话  ▾" action:@selector(sessionTapped)];
 self.sessionButton.contentHorizontalAlignment=UIControlContentHorizontalAlignmentCenter;
 for(UIButton *button in @[self.projectButton,self.modelButton,self.sessionButton]){
  button.titleLabel.lineBreakMode=NSLineBreakByTruncatingTail;
  button.contentEdgeInsets=UIEdgeInsetsMake(6,7,6,7);
 }

 UIStackView *selectors=[[UIStackView alloc]initWithArrangedSubviews:@[self.projectButton,self.modelButton,self.sessionButton]];
 selectors.axis=UILayoutConstraintAxisHorizontal;
 selectors.spacing=6;
 selectors.distribution=UIStackViewDistributionFillEqually;

 self.contextLabel=[UILabel new];
 self.contextLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
 self.contextLabel.textColor=UIColor.secondaryLabelColor;
 self.contextLabel.lineBreakMode=NSLineBreakByTruncatingMiddle;
 // 现场是会变的：在 FLEX 里重新点选一个视图后再回到会话，这一行要跟着换。
 // 可点：点一下立刻重新对齐一次运行时，并把当前选中对象写回状态行。
 self.contextLabel.userInteractionEnabled=YES;
 self.contextLabel.accessibilityTraits=UIAccessibilityTraitButton;
 self.contextLabel.accessibilityHint=@"轻点同步当前 FLEX 选中对象";
 [self.contextLabel addGestureRecognizer:[[UITapGestureRecognizer alloc]initWithTarget:self action:@selector(contextTapped)]];
 [self updateContextLabel];

 self.activityLabel=[UILabel new];
 self.activityLabel.font=[UIFont systemFontOfSize:12];
 self.activityLabel.textColor=UIColor.secondaryLabelColor;
 self.activityLabel.text=@"就绪";
 self.activityLabel.lineBreakMode=NSLineBreakByTruncatingTail;
 self.activityLabel.textAlignment=NSTextAlignmentRight;
 self.activityLabel.numberOfLines=2;
 self.activityLabel.accessibilityIdentifier=@"aiflex2.agent.activity";

 UIStackView *metaRow=[[UIStackView alloc]initWithArrangedSubviews:@[self.contextLabel,self.activityLabel]];
 metaRow.axis=UILayoutConstraintAxisHorizontal;
 metaRow.spacing=8;
 metaRow.distribution=UIStackViewDistributionFillEqually;

 if(self.projectID.length)[self.projectButton setTitle:self.projectName?:@"选择项目" forState:UIControlStateNormal];
 if(self.modelID.length)[self.modelButton setTitle:self.modelID forState:UIControlStateNormal];

 AXGlassCard *header=[[AXGlassCard alloc]initWithRadius:20];
 for(UIView *view in @[statusRow,selectors,metaRow]){view.translatesAutoresizingMaskIntoConstraints=NO;[header addSubview:view];}
 [NSLayoutConstraint activateConstraints:@[
  [statusRow.topAnchor constraintEqualToAnchor:header.topAnchor constant:10],[statusRow.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:12],[statusRow.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-12],
  [self.connectButton.widthAnchor constraintEqualToConstant:32],[self.connectButton.heightAnchor constraintEqualToConstant:30],
  [self.permissionButton.widthAnchor constraintEqualToConstant:32],[self.permissionButton.heightAnchor constraintEqualToConstant:30],
  [self.autoApproveButton.widthAnchor constraintEqualToConstant:32],[self.autoApproveButton.heightAnchor constraintEqualToConstant:30],
  [self.keepAwakeButton.widthAnchor constraintEqualToConstant:32],[self.keepAwakeButton.heightAnchor constraintEqualToConstant:30],
  [selectors.topAnchor constraintEqualToAnchor:statusRow.bottomAnchor constant:4],[selectors.leadingAnchor constraintEqualToAnchor:statusRow.leadingAnchor],[selectors.trailingAnchor constraintEqualToAnchor:statusRow.trailingAnchor],[selectors.heightAnchor constraintEqualToConstant:32],
  [metaRow.topAnchor constraintEqualToAnchor:selectors.bottomAnchor constant:4],[metaRow.leadingAnchor constraintEqualToAnchor:statusRow.leadingAnchor],[metaRow.trailingAnchor constraintEqualToAnchor:statusRow.trailingAnchor],[metaRow.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-10]
 ]];
 return header;
}

- (void)buildMessageList {
 self.messageScroll=[UIScrollView new];
 self.messageScroll.alwaysBounceVertical=YES;
 self.messageScroll.keyboardDismissMode=UIScrollViewKeyboardDismissModeInteractive;
 self.messageStack=[UIStackView new];
 self.messageStack.axis=UILayoutConstraintAxisVertical;
 self.messageStack.spacing=14;
 self.messageStack.alignment=UIStackViewAlignmentFill;
 self.messageStack.translatesAutoresizingMaskIntoConstraints=NO;
 [self.messageScroll addSubview:self.messageStack];
 [NSLayoutConstraint activateConstraints:@[
  [self.messageStack.topAnchor constraintEqualToAnchor:self.messageScroll.contentLayoutGuide.topAnchor constant:14],
  [self.messageStack.bottomAnchor constraintEqualToAnchor:self.messageScroll.contentLayoutGuide.bottomAnchor constant:-14],
  [self.messageStack.leadingAnchor constraintEqualToAnchor:self.messageScroll.contentLayoutGuide.leadingAnchor constant:12],
  [self.messageStack.trailingAnchor constraintEqualToAnchor:self.messageScroll.contentLayoutGuide.trailingAnchor constant:-12],
  [self.messageStack.widthAnchor constraintEqualToAnchor:self.messageScroll.frameLayoutGuide.widthAnchor constant:-24]
 ]];
}

// 输入框跟着内容长，但最少一行、最多约五行；固定 76 起步会让单行输入也空掉一半。
- (UIView *)buildComposer {
 self.input=[UITextView new];
 self.input.font=[UIFont systemFontOfSize:15];
 self.input.backgroundColor=UIColor.secondarySystemGroupedBackgroundColor;
 self.input.layer.cornerRadius=14;
 self.input.layer.cornerCurve=kCACornerCurveContinuous;
 self.input.textContainerInset=UIEdgeInsetsMake(10,10,10,10);
 self.input.delegate=self;
 self.input.scrollEnabled=YES;

 self.inputPlaceholder=[UILabel new];
 self.inputPlaceholder.text=@"描述问题，询问当前 FLEX 现场…";
 self.inputPlaceholder.font=self.input.font;
 self.inputPlaceholder.textColor=UIColor.secondaryLabelColor;
 self.inputPlaceholder.translatesAutoresizingMaskIntoConstraints=NO;
 [self.input addSubview:self.inputPlaceholder];

 self.sendButton=[self button:@"发送" action:@selector(sendTapped)];
 [self.sendButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
 self.sendButton.backgroundColor=UIColor.systemBlueColor;
 self.sendButton.titleLabel.font=[UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];

 UIStackView *composer=[[UIStackView alloc]initWithArrangedSubviews:@[self.input,self.sendButton]];
 composer.axis=UILayoutConstraintAxisHorizontal;
 composer.spacing=8;
 composer.alignment=UIStackViewAlignmentBottom;

 [NSLayoutConstraint activateConstraints:@[
  [self.inputPlaceholder.leadingAnchor constraintEqualToAnchor:self.input.leadingAnchor constant:15],[self.inputPlaceholder.topAnchor constraintEqualToAnchor:self.input.topAnchor constant:12],
  [self.sendButton.widthAnchor constraintEqualToConstant:60],[self.sendButton.heightAnchor constraintEqualToConstant:44]
 ]];
 self.inputHeight=[self.input.heightAnchor constraintEqualToConstant:44];
 self.inputHeight.active=YES;
 return composer;
}

- (UIButton *)iconButton:(NSString *)symbol action:(SEL)action label:(NSString *)label {
 UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];
 [button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
 button.tintColor=UIColor.secondaryLabelColor;
 button.layer.cornerRadius=9;
 button.layer.cornerCurve=kCACornerCurveContinuous;
 button.accessibilityLabel=label;
 [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
 return button;
}
- (void)setStatus:(NSString *)text {self.idleStatus=text;[self rememberConnection];[self refreshAgentStatus];}
- (void)showConnectionState:(NSUInteger)state {
 self.connectionState=state;
 if(state==2)DXLastConnectedStamp=NSProcessInfo.processInfo.systemUptime;
 NSString *address=self.host.length?[NSString stringWithFormat:@"%@:%lu",self.host,(unsigned long)self.port]:@"AiFlex2";
 self.statusLabel.text=state==2?[NSString stringWithFormat:@"已连接 · %@",address]:state==1?@"正在检查连接…":state==3?@"连接中断 · 点击重连":@"未连接 AiFlex2";
 self.statusDot.backgroundColor=state==2?UIColor.systemGreenColor:state==1?UIColor.systemOrangeColor:state==3?UIColor.systemRedColor:UIColor.systemGrayColor;
 self.connectButton.accessibilityLabel=state==0?@"连接 AiFlex2":@"连接设置";
 if (@available(iOS 13.0, *)) {} else [self.connectButton setTitle:@"连" forState:UIControlStateNormal];
 [self refreshAgentStatus];
}
- (void)statusTapped {
 if(self.connectionState==2){
  NSString *autoTitle=self.autoApprove?@"关闭自动允许（当前已开）":@"开启自动允许（不再逐次确认）";
  AXPresentAlert(self,@"AI 会话",@"自动允许只作用于本机这个会话：打开后 AI 申请的写入、构建、FLEX 现场操作会直接执行，不再弹确认框；随时可以在这里关掉。",AXAlertMessageStyleText,nil,@[
   [AXAlertButton buttonWithTitle:autoTitle style:AXAlertButtonStylePrimary handler:^(AXGlassAlert *action){[self setAutoApproveEnabled:!self.autoApprove];}],
   [AXAlertButton buttonWithTitle:@"收起为悬浮球" style:AXAlertButtonStyleSecondary handler:^(AXGlassAlert *action){[self minimizeChat:NO completion:^{}];}],
   [AXAlertButton buttonWithTitle:@"关闭" style:AXAlertButtonStyleCancel handler:nil]
  ]);
  return;
 }
 if(self.token.length){self.needsConnectionValidation=YES;self.lastValidateFailure=0;[self resumeSavedConnection];return;}
 [self connectTapped];
}
- (void)updateSessionButton {NSString *name=self.sessionTitle.length?self.sessionTitle:@"新会话";[self.sessionButton setTitle:[NSString stringWithFormat:@"会话 · %@  ▾",name] forState:UIControlStateNormal];}
- (void)showConnectionDiagnostic {
 NSString *report=self.lastConnectionError.userInfo[FLEXDylixConnectionDiagnosticKey];if(!report.length)return;
 AXPresentAlert(self,@"连接诊断",report,AXAlertMessageStyleCode,nil,@[
  [AXAlertButton buttonWithTitle:@"复制诊断" style:AXAlertButtonStyleSecondary handler:^(AXGlassAlert *alert){UIPasteboard.generalPasteboard.string=report;[self setStatus:@"已复制连接诊断"];}],
  [AXAlertButton buttonWithTitle:@"关闭" style:AXAlertButtonStyleCancel handler:nil]
 ]);
}
- (void)showError:(NSError *)error {
 if(!error)return;
 if(error.userInfo[FLEXDylixConnectionDiagnosticKey])self.lastConnectionError=error;
 [self setStatus:[[error.localizedDescription componentsSeparatedByString:@"\n"] firstObject]];
 if(!self.view.window){[self append:[@"错误：" stringByAppendingString:error.localizedDescription?:@"请求失败"]];return;}
 NSString *report=error.userInfo[FLEXDylixConnectionDiagnosticKey];
 NSMutableArray<AXAlertButton *> *buttons=[NSMutableArray new];
 if(report.length)[buttons addObject:[AXAlertButton buttonWithTitle:@"复制诊断" style:AXAlertButtonStyleSecondary handler:^(AXGlassAlert *alert){UIPasteboard.generalPasteboard.string=report;[self setStatus:@"已复制连接诊断"];}]];
 [buttons addObject:[AXAlertButton buttonWithTitle:@"确定" style:AXAlertButtonStylePrimary handler:nil]];
 AXPresentAlert(self,@"AiFlex2 连接",error.localizedDescription,AXAlertMessageStyleText,nil,buttons);
}
- (void)scrollMessagesToBottom { [self.messageScroll layoutIfNeeded];CGFloat offset=MAX(0,self.messageScroll.contentSize.height-self.messageScroll.bounds.size.height);[self.messageScroll setContentOffset:CGPointMake(0,offset) animated:NO]; }
- (void)renderMessages {
 for(UIView *view in self.messageStack.arrangedSubviews){[self.messageStack removeArrangedSubview:view];[view removeFromSuperview];}
 self.liveLabel=nil;
 // 只渲染尾部窗口：整段历史都建成 UILabel + AttributedString 会长期占内存，
 // 完整记录在 App 侧，这里只是当前会话的显示窗口。
 NSUInteger total=self.messages.count;
 NSUInteger start=total>120?total-120:0;
 if(start){
  UILabel *folded=[UILabel new];folded.text=[NSString stringWithFormat:@"更早的 %lu 条消息已折叠，完整记录在 App 会话里",(unsigned long)start];
  folded.font=[UIFont systemFontOfSize:12];folded.textColor=UIColor.tertiaryLabelColor;folded.textAlignment=NSTextAlignmentCenter;folded.numberOfLines=0;
  folded.translatesAutoresizingMaskIntoConstraints=NO;
  [self.messageStack addArrangedSubview:folded];
 }
 for(NSUInteger index=start;index<self.messages.count;index++){
  NSDictionary *message=self.messages[index];NSString *role=message[@"role"],*value=message[@"text"]?:@"";BOOL mine=[role isEqualToString:@"user"],tip=[role isEqualToString:@"tip"];
  UIView *row=[UIView new];row.translatesAutoresizingMaskIntoConstraints=NO;
  if(tip){
   UILabel *label=[UILabel new];label.text=value;label.numberOfLines=0;label.textAlignment=NSTextAlignmentCenter;label.font=[UIFont systemFontOfSize:13];label.textColor=UIColor.secondaryLabelColor;label.translatesAutoresizingMaskIntoConstraints=NO;[row addSubview:label];
   [NSLayoutConstraint activateConstraints:@[[label.topAnchor constraintEqualToAnchor:row.topAnchor],[label.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],[label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:15],[label.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-15]]];
  } else {
   UIView *bubble=[UIView new];bubble.backgroundColor=mine?UIColor.systemBlueColor:UIColor.secondarySystemGroupedBackgroundColor;bubble.layer.cornerRadius=16;bubble.layer.cornerCurve=kCACornerCurveContinuous;
   bubble.translatesAutoresizingMaskIntoConstraints=NO;[row addSubview:bubble];
   UILabel *author=[UILabel new];author.text=mine?@"我":@"AiFlex2";author.font=[UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];author.textColor=UIColor.secondaryLabelColor;author.translatesAutoresizingMaskIntoConstraints=NO;[row addSubview:author];
   UIButton *copy=[UIButton buttonWithType:UIButtonTypeSystem];[copy setTitle:@"复制" forState:UIControlStateNormal];copy.titleLabel.font=[UIFont systemFontOfSize:11];copy.tag=index;copy.translatesAutoresizingMaskIntoConstraints=NO;[copy addTarget:self action:@selector(copyMessage:) forControlEvents:UIControlEventTouchUpInside];[row addSubview:copy];
   UILabel *label=[UILabel new];label.text=value.length?value:@"正在回复…";label.numberOfLines=0;label.lineBreakMode=NSLineBreakByWordWrapping;label.font=[UIFont systemFontOfSize:15];label.textColor=mine?UIColor.whiteColor:UIColor.labelColor;label.translatesAutoresizingMaskIntoConstraints=NO;[bubble addSubview:label];
   if(!mine)label.attributedText=FLEXDylixRenderMarkdown(value,label.textColor);
   [NSLayoutConstraint activateConstraints:@[[author.topAnchor constraintEqualToAnchor:row.topAnchor],[author.leadingAnchor constraintEqualToAnchor:bubble.leadingAnchor constant:2],[copy.centerYAnchor constraintEqualToAnchor:author.centerYAnchor],[copy.trailingAnchor constraintEqualToAnchor:bubble.trailingAnchor constant:-2],[author.trailingAnchor constraintLessThanOrEqualToAnchor:copy.leadingAnchor constant:-8],
    [bubble.topAnchor constraintEqualToAnchor:author.bottomAnchor constant:5],[bubble.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],[bubble.widthAnchor constraintLessThanOrEqualToAnchor:row.widthAnchor multiplier:0.88],[bubble.leadingAnchor constraintGreaterThanOrEqualToAnchor:row.leadingAnchor],[bubble.trailingAnchor constraintLessThanOrEqualToAnchor:row.trailingAnchor],mine?[bubble.trailingAnchor constraintEqualToAnchor:row.trailingAnchor]:[bubble.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
    [label.topAnchor constraintEqualToAnchor:bubble.topAnchor constant:11],[label.bottomAnchor constraintEqualToAnchor:bubble.bottomAnchor constant:-11],[label.leadingAnchor constraintEqualToAnchor:bubble.leadingAnchor constant:12],[label.trailingAnchor constraintEqualToAnchor:bubble.trailingAnchor constant:-12]]];
   if(message==self.liveMessage)self.liveLabel=label;
  }
  [self.messageStack addArrangedSubview:row];
 }
 dispatch_async(dispatch_get_main_queue(),^{[self scrollMessagesToBottom];});
 [self rememberConnection];
}
- (NSMutableDictionary *)addMessage:(NSString *)text role:(NSString *)role {NSMutableDictionary *item=[@{@"role":role?:@"tip",@"text":text?:@""} mutableCopy];[self.messages addObject:item];if([role isEqualToString:@"assistant"])self.liveMessage=item;[self renderMessages];return item;}
- (void)copyMessage:(UIButton *)button {if(button.tag>=self.messages.count)return;UIPasteboard.generalPasteboard.string=self.messages[button.tag][@"text"]?:@"";[button setTitle:@"已复制" forState:UIControlStateNormal];}
- (void)append:(NSString *)line { [self addMessage:line role:@"tip"]; }
- (NSString *)draftKey {return [NSString stringWithFormat:@"%@/%@",self.projectID?:@"",self.sessionID?:@"new"];}
- (void)saveDraft {self.drafts[self.draftKey]=self.input.text?:@"";}
- (void)restoreDraft {self.input.text=self.drafts[self.draftKey]?:@"";[self textViewDidChange:self.input];}
- (void)newSession {if(self.restoringWorkspace){[self setStatus:@"正在恢复上次项目和会话，请稍候"];return;}if(self.busy)return;[self saveDraft];self.sessionLoadGeneration++;self.sessionID=nil;self.sessionTitle=nil;self.jobID=nil;self.captureStatus=nil;self.captureID=nil;self.lastCaptureSequence=0;self.liveMessage=nil;[self.messages removeAllObjects];[self addMessage:@"新会话已建立。当前 FLEX 对象会在发送时重新同步。" role:@"tip"];[self restoreDraft];[self updateSessionButton];[self setStatus:@"新会话就绪"];
}
- (void)loadSessionID:(NSString *)identifier title:(NSString *)title {
 if(self.busy)return;
 NSString *project=self.projectID;NSUInteger generation=++self.sessionLoadGeneration;[self setStatus:@"正在读取会话…"];
 [self workspace:@"ai_read" arguments:@{@"sessionID":identifier} completion:^(NSDictionary *record,NSError *error){
  if(generation!=self.sessionLoadGeneration||![project isEqualToString:self.projectID])return;
  if(error){[self showError:error];return;}
  if(![record[@"id"] isEqualToString:identifier]){[self showError:DXChatError(@"会话读取结果不匹配")];return;}
  [self saveDraft];self.captureStatus=nil;self.captureID=nil;self.lastCaptureSequence=0;self.sessionID=identifier;self.sessionTitle=title.length?title:record[@"title"];self.liveMessage=nil;self.liveHasContent=NO;[self.messages removeAllObjects];
  if(![self applyTranscript:record[@"messages"]]){[self.messages addObject:[@{@"role":@"tip",@"text":@"这个会话还没有可显示的文字消息。"} mutableCopy]];[self renderMessages];}
  [self restoreDraft];[self updateSessionButton];
  BOOL running=[@[@"streaming",@"running",@"waitingApproval"] containsObject:record[@"state"]];
  [self setStatus:running?@"会话正在 AiFlex2 运行，点会话可刷新":[NSString stringWithFormat:@"已打开会话 · %lu 条消息",(unsigned long)self.messages.count]];
  NSString *savedConnection=record[@"connectionID"],*savedModel=record[@"modelID"];
  self.reasoningEffort=nil;self.reasoningOptions=nil;
  self.connectionID=nil;self.modelID=nil;self.modelName=nil;[self.modelButton setTitle:@"选择模型" forState:UIControlStateNormal];
  if(![savedConnection isKindOfClass:NSString.class]||!savedConnection.length){[self setStatus:@"会话已打开，请选择模型后继续"];return;}
  [self workspace:@"ai_connections" arguments:@{} completion:^(NSDictionary *data,NSError *lookupError){
   if(generation!=self.sessionLoadGeneration||![project isEqualToString:self.projectID]||![identifier isEqualToString:self.sessionID])return;
   if(lookupError){[self setStatus:@"会话已打开；模型列表暂不可用"] ;return;}
   for(NSDictionary *candidate in data[@"connections"])if([candidate[@"id"] isEqual:savedConnection]&&(![savedModel isKindOfClass:NSString.class]||[candidate[@"model"] isEqual:savedModel])){self.connectionID=savedConnection;self.modelID=candidate[@"model"];self.reasoningOptions=candidate[@"efforts"];self.modelName=[NSString stringWithFormat:@"%@ · %@",candidate[@"provider"]?:@"",candidate[@"model"]?:@""];[self.modelButton setTitle:candidate[@"model"]?:@"模型" forState:UIControlStateNormal];[self rememberConnection];return;}
   self.connectionID=nil;self.modelID=nil;self.modelName=nil;[self.modelButton setTitle:@"选择模型" forState:UIControlStateNormal];[self setStatus:@"原会话模型已移除，请重新选择模型"];
  }];
 }];
}
- (void)sessionTapped {if(self.restoringWorkspace){[self setStatus:@"正在恢复上次项目和会话，请稍候"];return;}
 if(!self.csrf.length){[self connectTapped];return;}if(!self.projectID.length){[self projectTapped];return;}if(self.busy){[self setStatus:@"AI 正在回复，结束后可切换会话"];return;}
 NSString *project=self.projectID;[self setStatus:@"正在加载会话列表…"];
 [self workspace:@"ai_sessions" arguments:@{} completion:^(NSDictionary *data,NSError *error){
  if(![project isEqualToString:self.projectID])return;if(error){[self showError:error];return;}
  NSArray *sessions=[data[@"sessions"] isKindOfClass:NSArray.class]?data[@"sessions"]:@[];NSDateFormatter *date=[NSDateFormatter new];date.dateFormat=@"M/d HH:mm";
  NSMutableArray<AXSheetItem *> *items=[NSMutableArray new];NSMutableArray<NSString *> *identifiers=[NSMutableArray new];NSMutableArray<NSString *> *titles=[NSMutableArray new];
  [items addObject:[AXSheetItem itemWithTitle:@"＋ 新会话" subtitle:nil]];
  for(id raw in sessions){if(![raw isKindOfClass:NSDictionary.class])continue;NSString *sid=raw[@"id"];if(![sid isKindOfClass:NSString.class]||!sid.length)continue;NSString *title=[raw[@"title"] isKindOfClass:NSString.class]?raw[@"title"]:@"会话";NSString *summary=[raw[@"summary"] isKindOfClass:NSString.class]?raw[@"summary"]:@"";
   if([title hasPrefix:@"当前 FLEX 现场："]&&summary.length)title=summary;
   if(title.length>30)title=[[title substringToIndex:30] stringByAppendingString:@"…"];
   NSString *updated=[raw[@"updatedAt"] isKindOfClass:NSNumber.class]?[date stringFromDate:[NSDate dateWithTimeIntervalSince1970:[raw[@"updatedAt"] doubleValue]]]:@"";
   AXSheetItem *item=[AXSheetItem itemWithTitle:title subtitle:updated.length?updated:nil];
   item.selected=[sid isEqualToString:self.sessionID];
   [items addObject:item];[identifiers addObject:sid];[titles addObject:title];
  }
  NSString *message=self.projectName?:nil;
  if(!sessions.count)message=@"当前项目暂无历史会话";
  AXPresentSheet(self,@"选择会话",message,items,^(NSInteger index){
   if(index<0)return;
   if(index==0){[self newSession];return;}
   NSUInteger position=(NSUInteger)(index-1);
   if(position>=identifiers.count)return;
   [self loadSessionID:identifiers[position] title:titles[position]];
  });
  [self setStatus:@"选择现有会话或新建会话"];
 }];
}
- (void)textViewDidChange:(UITextView *)textView {self.inputPlaceholder.hidden=textView.text.length>0;CGFloat height=MIN(150,MAX(44,[textView sizeThatFits:CGSizeMake(textView.bounds.size.width,CGFLOAT_MAX)].height));if(fabs(height-self.inputHeight.constant)>0.5)self.inputHeight.constant=height;}
- (void)applicationStateChanged:(NSNotification *)note {self.statusSuspended=[note.name isEqual:UIApplicationWillResignActiveNotification];if(!self.statusSuspended)[self applyKeepAwake];[self refreshAgentStatus];}
- (NSString *)phaseForOperation:(NSString *)operation {
 NSDictionary *names=@{@"gesture":@"正在操作页面",@"activate_control":@"正在点击控件",@"scroll_view":@"正在滚动页面",@"set_view":@"正在调整视图",@"undo":@"正在恢复视图",@"input_text":@"正在输入文字",@"set_control_value":@"正在调整控件",@"capture_screen":@"正在截图观察",@"screen_elements":@"正在读取控件",@"view_tree":@"正在读取视图树",@"object_info":@"正在核对对象",@"class_info":@"正在核对类信息",@"class_header":@"正在读取头文件",@"minimize_chat":@"正在收起会话",@"restore_chat":@"正在恢复会话",@"open_tool":@"正在打开 FLEX 工具",@"select_row":@"正在操作 FLEX 页面",@"flex_scroll":@"正在滚动 FLEX 页面",@"set_search":@"正在搜索 FLEX 页面",@"navigate_back":@"正在返回 FLEX 页面",@"dismiss_tool":@"正在关闭 FLEX 页面",@"build_project":@"正在本机构建",@"read_file":@"正在读取项目文件",@"list_artifacts":@"正在检查构建产物",@"list_session_files":@"正在读取会话文件"};
 return names[operation]?:[NSString stringWithFormat:@"正在执行工具 · %@",operation?:@"未知工具"];
}
- (BOOL)isScreenControl:(NSString *)operation {
 return [@[@"gesture",@"activate_control",@"scroll_view",@"set_view",@"undo",@"input_text",@"set_control_value",@"open_tool",@"navigate_back",@"dismiss_tool",@"select_row",@"flex_scroll",@"set_search"] containsObject:operation];
}
// 悬浮球是独立 UIWindow（windowLevel 高于宿主窗口），一旦没藏住就会盖在会话页上面，
// 而且它的显示判定依赖 view.window，转场那几帧很容易误判。会话页自己有明确的生命周期，
// 进页面时直接强制收起一次最稳。
- (void)hideStatusBall {
 self.statusShowStamp=0;
 if(self.statusWindow&&!self.statusWindow.hidden)self.statusWindow.hidden=YES;
}
// 会话页真正在屏上的判定：视图必须挂在一个可见窗口上。
// 之前只看 view.window 非空，而窗口还在、只是被系统藏起来时会误判成「在屏上」。
- (BOOL)chatOnScreen {
 UIView *view=self.viewIfLoaded;UIWindow *window=view.window;
 return view!=nil&&window!=nil&&!window.hidden&&!view.hidden&&view.alpha>.01&&!self.isBeingDismissed;
}
- (void)refreshAgentStatus {
 // 任务开始/结束、页面进出都会走到这里，顺带按“是否需要常亮”更新系统定时器。
 [self updateIdleTimer];
 // 同一进程里可能有不止一个会话实例（面板里点开一次、悬浮球又恢复一次）。
 // 只有最新的那个实例拥有悬浮球；旧实例一旦还留着球，就会浮在新会话页上面。
 BOOL superseded=DXCurrentChat!=nil&&DXCurrentChat!=self;
 UINavigationController *nav=self.navigationController?:self.chatNavigation;
 BOOL chatVisible=[self chatOnScreen];
 // 转场途中（push/present/dismiss 正在跑）既没有稳定窗口也没稳定状态，
 // 这时把悬浮球显出来就会在进入会话的一瞬间闪一下，必须排除掉。
 BOOL transitioning=self.uiTransitioning||self.isBeingPresented||self.isBeingDismissed||nav.isBeingPresented||nav.isBeingDismissed||nav.transitionCoordinator!=nil;
 BOOL wanted=!superseded&&!chatVisible&&self.csrf.length&&!transitioning&&!self.statusSuspended&&UIApplication.sharedApplication.applicationState==UIApplicationStateActive;
 if(!wanted)self.statusShowStamp=0;
 BOOL show=wanted;
 if(show&&!(self.statusWindow&&!self.statusWindow.hidden)){
  // 条件刚满足时先按住 0.3 秒：页面正在被顶掉的那一两帧里条件也会短暂成立。
  NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
  if(self.statusShowStamp<=0)self.statusShowStamp=now;
  if(now-self.statusShowStamp<0.3){show=NO;[self scheduleStatusRefresh];}
 }
 if(wanted&&!self.statusWindow){
  UIWindowScene *scene=[FLEXDylixStatusWindow activeScene];
  if(scene)self.statusWindow=[[FLEXDylixStatusWindow alloc]initWithWindowScene:scene];
  if(!self.statusWindow)self.statusWindow=[[FLEXDylixStatusWindow alloc]initWithFrame:UIScreen.mainScreen.bounds];
  __weak typeof(self) weak=self;self.statusWindow.openChat=^{typeof(self) chat=weak;if(!chat||chat.uiTransitioning)return;chat.uiTransitioning=YES;[chat restoreChatWithCompletion:^{chat.uiTransitioning=NO;}];};
 }
 if(wanted)[self.statusWindow attachToBestScene];
 BOOL control=[self isScreenControl:self.localOperation];for(NSString *op in self.activeToolOperations.allValues)if([self isScreenControl:op])control=YES;
 BOOL running=self.busy||self.localOperation.length||self.activeToolOperations.count;
 NSString *title=@"AiFlex2 AI · 已连接",*detail=@"轻点返回会话";UIColor *color=UIColor.systemGreenColor;
 if(self.connectionState!=2){title=self.connectionState==3?@"AiFlex2 AI · 连接中断":@"AiFlex2 AI · 检查连接";detail=self.connectionState==3?@"轻点检查连接与任务":@"等待 AiFlex2 心跳确认";color=self.connectionState==3?UIColor.systemRedColor:UIColor.systemOrangeColor;}
 else if(self.agentStopped){title=@"AiFlex2 AI · 已停止";detail=self.idleStatus?:@"轻点返回会话";color=UIColor.systemGrayColor;}
 else if(self.waitingApproval){title=@"AI 等待你的确认";detail=@"请查看当前确认弹窗";color=UIColor.systemOrangeColor;}
 else if(running){title=control?@"AI 操作中 · 请勿触屏":@"AiFlex2 AI · 处理中";color=control?UIColor.systemOrangeColor:UIColor.systemBlueColor;
  NSString *phase=self.localOperation.length?[self phaseForOperation:self.localOperation]:(self.taskPhase?:@"等待模型响应");
  NSTimeInterval elapsed=self.lastTaskUpdate>0?MAX(0,NSProcessInfo.processInfo.systemUptime-self.lastTaskUpdate):0;
   detail=elapsed>=15?[NSString stringWithFormat:@"%@ · 等待更新 %.0f 秒",phase,elapsed]:phase;
  if([phase isEqual:@"正在回复"]&&!control)title=@"AiFlex2 AI · 正在回复";
 }else if([self.idleStatus isEqual:@"请求未完成"]){title=@"AiFlex2 AI · 任务未完成";detail=@"请求未完成 · 查看错误详情";color=UIColor.systemOrangeColor;}
 else if([self.idleStatus isEqual:@"回复完成"]){title=@"AiFlex2 AI · 回复完成";detail=@"回复完成";}
 else detail=self.idleStatus?:@"就绪";
 if(control)detail=[@"请勿触屏 · " stringByAppendingString:detail];
 if(self.autoApprove)detail=[@"自动允许 · " stringByAppendingString:detail];
 if(self.captureStatus.length)detail=[detail stringByAppendingFormat:@"\n%@",self.captureStatus];
 self.activityLabel.text=detail;self.activityLabel.textColor=color;self.activityLabel.accessibilityLabel=detail;
 if(!show){self.statusWindow.hidden=YES;return;}
 [self.statusWindow updateTitle:title detail:detail color:color busy:running&&self.connectionState==2&&!self.agentStopped&&!self.waitingApproval];self.statusWindow.hidden=NO;
}
- (void)scheduleStatusRefresh {
 if(self.statusRefreshScheduled)return;
 self.statusRefreshScheduled=YES;
 __weak typeof(self) weak=self;
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.32*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
  typeof(self) chat=weak;if(!chat)return;chat.statusRefreshScheduled=NO;[chat refreshAgentStatus];
 });
}
- (void)updateCaptureStatus:(NSDictionary *)event {
 if(![event isKindOfClass:NSDictionary.class])return;
 NSUInteger sequence=[event[@"sequence"] unsignedIntegerValue];NSString *capture=event[@"captureID"],*stage=event[@"stage"];
 NSDictionary *labels=@{@"captured":@"截图已获取 · 待发送",@"sending":@"截图正在发送",@"sent":@"截图已随请求发送",@"failed":@"截图请求失败",@"cancelled":@"截图请求已取消"};
 if(sequence<=self.lastCaptureSequence||![capture isKindOfClass:NSString.class]||!capture.length||![stage isKindOfClass:NSString.class]||!labels[stage])return;
 self.lastCaptureSequence=sequence;self.captureID=capture;self.captureStatus=labels[stage];
}
- (void)updateTaskFromJob:(NSDictionary *)job {
 for(id raw in job[@"events"]){
  if(![raw isKindOfClass:NSDictionary.class])continue;NSDictionary *event=raw;NSUInteger sequence=[event[@"sequence"] unsignedIntegerValue];if(sequence<=self.lastEventSequence)continue;self.lastEventSequence=sequence;
  NSString *type=event[@"type"],*identifier=event[@"id"];
  if([type isEqual:@"waiting_approval"]){self.waitingApproval=YES;self.taskPhase=@"等待操作确认";}
  else if([type isEqual:@"tool_started"]){self.waitingApproval=NO;NSString *op=[event[@"arguments"] isKindOfClass:NSDictionary.class]?event[@"arguments"][@"operation"]:nil;op=op?:event[@"name"];if(identifier&&op)self.activeToolOperations[identifier]=op;self.taskPhase=[self phaseForOperation:op];}
  else if([type isEqual:@"tool_result"]){if(identifier)[self.activeToolOperations removeObjectForKey:identifier];self.waitingApproval=NO;self.taskPhase=self.activeToolOperations.count?[self phaseForOperation:self.activeToolOperations.allValues.firstObject]:@"工具已返回 · 等待模型";}
  else if([type isEqual:@"assistant_start"]){[self.activeToolOperations removeAllObjects];self.waitingApproval=NO;self.taskPhase=@"等待模型响应";}
  else if([type isEqual:@"reasoning"]||[type isEqual:@"analysis_summary"]){self.taskPhase=@"正在接收思考";}
  else if([type isEqual:@"text"]){self.taskPhase=@"正在回复";}
  else if([type isEqual:@"status"]){if(!self.activeToolOperations.count&&!self.localOperation.length&&[event[@"message"] isKindOfClass:NSString.class])self.taskPhase=[event[@"message"] substringToIndex:MIN((NSUInteger)120,[event[@"message"] length])];}
  else if([type isEqual:@"flex_capture_status"]){[self updateCaptureStatus:event];}
  else if([type isEqual:@"tool_progress"]){NSString *message=event[@"message"];if([message isKindOfClass:NSString.class]&&message.length)self.taskPhase=[message substringToIndex:MIN((NSUInteger)120,message.length)];}
  else if([type isEqual:@"done"]){[self.activeToolOperations removeAllObjects];self.waitingApproval=NO;}
  else if(![type isEqual:@"tool_progress"])continue;
  self.lastTaskUpdate=NSProcessInfo.processInfo.systemUptime;
 }
 [self updateCaptureStatus:job[@"flexCaptureStatus"]];[self refreshAgentStatus];
}
- (NSDictionary *)chatWindowStatus {
 BOOL visible=[self chatOnScreen]&&!self.navigationController.isBeingDismissed;
 return @{@"chatVisible":@(visible),@"minimized":@(self.chatMinimized),@"connected":@(self.connectionState==2&&!self.needsConnectionValidation&&self.missedHeartbeats<2),@"taskRunning":@(self.busy),@"stopped":@(self.agentStopped),@"sessionID":self.sessionID?:@"",@"flexVisible":@(!FLEXManager.sharedManager.isHidden),@"targetReady":@(!visible&&FLEXManager.sharedManager.isHidden&&!self.uiTransitioning),@"statusVisible":@(self.statusWindow&&!self.statusWindow.hidden),@"autoApprove":@(self.autoApprove),@"keepAwake":@(self.keepAwake),@"activity":self.taskPhase?:@"",@"uiTransitioning":@(self.uiTransitioning)};
}
- (void)minimizeChat:(BOOL)target completion:(dispatch_block_t)completion {
 [self.view endEditing:YES];[self rememberConnectionNow];
 dispatch_block_t done=^{self.chatMinimized=YES;if(target)[FLEXManager.sharedManager hideExplorer];[self refreshAgentStatus];if(completion)completion();};
 UINavigationController *nav=self.navigationController?:self.chatNavigation;
 if(nav.presentingViewController)[nav dismissViewControllerAnimated:YES completion:done];else done();
}
- (void)restoreChatWithCompletion:(dispatch_block_t)completion {
 [self hideStatusBall];
 if(self.viewIfLoaded.window){[FLEXManager.sharedManager showExplorer];self.chatMinimized=NO;[self refreshAgentStatus];if(completion)completion();return;}
 // 记录这次是从哪儿来的：此时 FLEX 面板还是收起状态，说明用户是点悬浮球/通知回来的，
 // 「返回」就应该退回 App 而不是弹出一个他从没打开过的面板。
 self.explorerWasHidden=FLEXManager.sharedManager.isHidden;
 // 会话页可能已经不在任何导航栈里（用户在面板里返回过、或面板被系统整体回收），
 // 这时 self.navigationController 是 nil。以前把这个 nil 直接交给 present，
 // 就会抛 "Application tried to present a nil modal view controller" 把宿主杀掉。
 UINavigationController *nav=self.navigationController?:self.chatNavigation;
 if(!nav){
  nav=[[UINavigationController alloc]initWithRootViewController:self];
  nav.modalPresentationStyle=UIModalPresentationFullScreen;
  nav.modalPresentationCapturesStatusBarAppearance=YES;
 }
 self.chatNavigation=nav;
 [FLEXManager.sharedManager dismissAnyPresentedTools:^{
  // 非动画：面板窗口刚被重新显示，再叠一段滑入动画会先露出下面的页面，看起来就是闪一下。
  [FLEXManager.sharedManager presentTool:^UINavigationController *{return nav;} animated:NO completion:^{self.chatMinimized=NO;[self hideStatusBall];
   // 恢复出来的导航栈里 self 就是栈根，系统不会给返回箭头，这里补上自己的 "<"。
   [self buildNavigationItems];[self syncFlexSelection];[self refreshAgentStatus];if(completion)completion();}];
 }];
}
- (void)stopAgentTapped {
 // Local latch closes immediately, even if the cancel request cannot reach Dylix.
 self.agentStopped=YES;NSUInteger generation=++self.agentGeneration;[self setStatus:@"正在停止任务…"];
 [self.runtime cancelPendingInput];
 if(self.jobID.length)[self request:@"/api/v1/jobs/cancel" body:@{@"id":self.jobID} completion:^(NSDictionary *result,NSError *error){if(generation!=self.agentGeneration)return;if(!error){self.busy=NO;self.jobID=nil;}[self setStatus:error?@"本地工具已停止；远端取消失败，请恢复会话检查":@"任务已停止"]; }];
 else [self setStatus:@"本地工具已停止"]; 
}
- (void)closeTapped {if(self.uiTransitioning)return;self.uiTransitioning=YES;[self minimizeChat:NO completion:^{self.uiTransitioning=NO;}];}
- (void)disconnectTapped {
 if(self.busy){[self showError:DXChatError(@"AI 正在回复，请等本次请求结束后断开")];return;}
 if(!self.token.length){[self setStatus:@"尚未连接 AiFlex2"];return;}
 AXPresentAlert(self,@"断开 AiFlex2",@"清除保存的授权码和连接令牌，保留地址、项目、模型及会话选择。再次连接需要授权码。",AXAlertMessageStyleText,nil,@[
  [AXAlertButton buttonWithTitle:@"断开连接" style:AXAlertButtonStyleDestructive handler:^(AXGlassAlert *alert){
   [self.agentTimer invalidate];self.agentTimer=nil;[self setStatus:@"正在断开 AiFlex2…"];
   self.agentStopped=YES;
   [self request:@"/api/v1/logout" body:@{} completion:^(NSDictionary *result,NSError *error){
    NSError *storageError=nil;[FLEXDylixPreferences clearAuthorization:&storageError];
    self.sessionLoadGeneration++;self.token=nil;self.csrf=nil;self.authorizationCode=nil;self.jobID=nil;self.needsConnectionValidation=NO;self.lastValidateFailure=0;
    // 断开后那个浮窗已经没有存在意义，置空让 UIWindow 连同它的视图一起释放。
    self.statusWindow.hidden=YES;self.statusWindow.windowScene=nil;self.statusWindow=nil;
    self.missedHeartbeats=0;[self showConnectionState:0];[self rememberConnectionNow];[self setStatus:storageError?storageError.localizedDescription:@"已断开 AiFlex2，已保留项目和模型选择"];
   }];
  }],
  [AXAlertButton buttonWithTitle:@"取消" style:AXAlertButtonStyleCancel handler:nil]
 ]);
}
- (void)viewWillAppear:(BOOL)animated {
 [super viewWillAppear:animated];
 // 在屏上的这一份接管会话（面板里可能先后 push 过好几个会话页）：
 // 归属跟着可见性走，被顶到下层的那份就不会再往屏幕上放球。
 DXCurrentChat=self;
 UINavigationController *nav=self.navigationController;
 if(nav)self.chatNavigation=nav;
 self.statusShowStamp=0;
 [self hideStatusBall];
 // 页面可能是被重新展示的（悬浮球恢复 / 从别的工具页回来），导航项按当前栈重新算一遍，
 // 否则栈根这种情形会停在「没有返回按钮」的旧状态。
 [self buildNavigationItems];
 [self syncFlexSelection];
 [self refreshAgentStatus];
}
- (void)viewDidAppear:(BOOL)animated {
 [super viewDidAppear:animated];self.chatMinimized=NO;[self hideStatusBall];[self syncFlexSelection];[self refreshAgentStatus];
 if(self.needsConnectionValidation){
  // 校验失败后 30 秒内不再自动重试。原先每次进页面都会打一次 /api/v1/status，
  // 没开 App 侧服务时一直卡在“正在检查连接…”，只用 MCP 的场景纯属空等。
  NSTimeInterval sinceFail=self.lastValidateFailure>0?NSProcessInfo.processInfo.systemUptime-self.lastValidateFailure:30.0;
  if(sinceFail<30.0){[self showConnectionState:0];[self setStatus:@"未连接 AiFlex2 · 仅用 MCP 时无需连接"];return;}
  [self resumeSavedConnection];return;
 }
 [self startAgentPolling];[self pollAgent];
}
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; [self rememberConnectionNow]; }
- (void)viewDidLayoutSubviews {
 [super viewDidLayoutSubviews];
 // 会话页在屏上时，任何一次布局都顺手确认球是收起的：
 // 它挂在独立 window 上、windowLevel 比宿主高，漏一次就会整块盖在页面上。
 if(self.viewIfLoaded.window&&self.statusWindow&&!self.statusWindow.hidden)[self hideStatusBall];
}
// 被返回上一级（pop）时结束轮询：定时器强持有 self，不 invalidate 会让控制器永远不释放，
// MCP 的 chat_status/minimize_chat 也会一直落到这个已经看不见的页面上。
// 收起（dismiss）不算 pop，导航栈里仍然包含 self，轮询要继续跑。
- (void)viewDidDisappear:(BOOL)animated {
 [super viewDidDisappear:animated];
 UINavigationController *nav=self.navigationController;
 if(!nav||![nav.viewControllers containsObject:self]){
  [self.agentTimer invalidate];self.agentTimer=nil;
  self.statusWindow.hidden=YES;
  // 已经被 pop 出栈，这层导航不再代表会话，留着会让悬浮球恢复出一个空面板。
  self.chatNavigation=nil;
 }
 // 页面已经离开，若手上也没有在跑的任务，就把常亮交还系统。
 [self updateIdleTimer];
}
- (void)startAgentPolling {
 if(self.agentTimer||!self.csrf.length||self.needsConnectionValidation)return;
 // 空闲时 2 秒一轮足够：原来固定 1 秒，即使没有任何任务也在持续打请求，是插件侧最大的耗电项。
 self.agentTimer=[NSTimer timerWithTimeInterval:2 target:self selector:@selector(pollAgent) userInfo:nil repeats:YES];
 self.agentTimer.tolerance=0.35;
 [NSRunLoop.mainRunLoop addTimer:self.agentTimer forMode:NSRunLoopCommonModes];[self pollAgent];
}
// 有活干就排紧一点，没活干就退到 2 秒，避免空转。
- (void)nextPollIn:(NSTimeInterval)interval {
 NSTimer *timer=self.agentTimer;
 if(timer)timer.fireDate=[NSDate dateWithTimeIntervalSinceNow:MAX(0.15,interval)];
}
- (void)pollAgent {
 // 每轮都对齐一次现场：轮询本来就在跑，顺手把选中对象的变化同步到页头，零额外开销。
 [self syncFlexSelection];
 [self refreshAgentStatus];
 if(self.agentPolling||!self.csrf.length||self.needsConnectionValidation)return;
 self.agentPolling=YES;NSUInteger generation=self.sessionLoadGeneration;
 [self request:@"/api/v1/flex/next" body:@{} completion:^(NSDictionary *command,NSError *error){
  self.agentPolling=NO;if(generation!=self.sessionLoadGeneration||!self.csrf.length||self.needsConnectionValidation)return;
  if(error){
   self.lastConnectionError=error;self.missedHeartbeats++;
   // 连续两次失败多半只是 App 刚切到后台、系统还没恢复监听，先别急着报中断。
   if(self.missedHeartbeats>=3){
    NSString *reason=[[error.localizedDescription componentsSeparatedByString:@"\n"] firstObject];
    [self showConnectionState:3];
    [self setStatus:reason.length?[NSString stringWithFormat:@"%@ · 正在重试",reason]:@"连接中断 · 正在重试"];
   }
   [self nextPollIn:self.missedHeartbeats>=3?3.0:1.5];return;
  }
  BOOL recovered=self.connectionState==3;
  self.missedHeartbeats=0;[self showConnectionState:2];
  // 恢复后必须把上一次的红色错误文案换掉，否则会一直挂着“连接中断”。
  if(recovered)[self setStatus:@"连接已恢复"];
  if(![command[@"id"] isKindOfClass:NSString.class]){if(self.pendingCommandID&&self.agentReplies[self.pendingCommandID]){[self.agentReplies removeObjectForKey:self.pendingCommandID];self.pendingCommandID=nil;}[self nextPollIn:(self.busy||self.activeToolOperations.count)?0.5:1.8];return;}
  NSString *identifier=command[@"id"];NSDictionary *reply=self.agentReplies[identifier];
  if(reply){[self sendAgentReply:reply];[self nextPollIn:0.4];return;}
  if(self.pendingCommandID){[self nextPollIn:0.5];return;}
  self.pendingCommandID=identifier;
  [self nextPollIn:0.4];
  [self executeAgentCommand:command];
 }];
}
- (void)sendAgentReply:(NSDictionary *)reply {
 if(self.agentReplying)return;self.agentReplying=YES;
 [self request:@"/api/v1/flex/reply" body:reply completion:^(NSDictionary *result,NSError *error){
  self.agentReplying=NO;
  if(!error||[error.localizedDescription containsString:@"过期"]||[error.localizedDescription containsString:@"不属于当前设备"]){[self.agentReplies removeObjectForKey:reply[@"id"]];if([self.pendingCommandID isEqual:reply[@"id"]])self.pendingCommandID=nil;}
 }];
}
- (void)finishAgentCommand:(NSDictionary *)command allowed:(BOOL)allowed {
 NSString *identifier=command[@"id"],*operation=command[@"operation"];
 NSDictionary *result=nil;NSString *failure=nil;
 NSTimeInterval expiry=[command[@"expiresAt"] isKindOfClass:NSNumber.class]?[command[@"expiresAt"] doubleValue]:0;
 if(allowed&&expiry>NSDate.date.timeIntervalSince1970&&!self.agentStopped){self.localOperation=operation;self.lastTaskUpdate=NSProcessInfo.processInfo.systemUptime;[self refreshAgentStatus];}
 if(allowed&&expiry<=NSDate.date.timeIntervalSince1970)failure=@"命令已过期；请让 AI 重新查询";
 else if(allowed&&(self.agentStopped||(self.commandGenerations[identifier]&&[self.commandGenerations[identifier] unsignedIntegerValue]!=self.agentGeneration)))failure=@"用户已停止 AI 工具操作，请等待用户发起新任务";
 else if(allowed&&[operation isEqual:@"chat_status"])result=[self chatWindowStatus];
 else if(allowed&&[operation isEqual:@"gesture"]){
  [self.runtime performGesture:command[@"arguments"] completion:^(NSDictionary *answer,NSString *error){[self deliverAgentCommand:command result:answer error:error];}];return;
 }
 else if(allowed&&[@[@"minimize_chat",@"restore_chat",@"open_tool",@"navigate_back",@"dismiss_tool"] containsObject:operation]){
  [self executeWindowCommand:command];return;
 }
 else if(allowed){@try{result=[self.runtime execute:operation arguments:command[@"arguments"] error:&failure];}@catch(NSException *exception){failure=[NSString stringWithFormat:@"FLEX 操作异常（%@）；请重新查询页面",exception.name];}}
 else failure=@"FLEX 用户拒绝此项操作";
 [self deliverAgentCommand:command result:result error:failure];
}
- (void)deliverAgentCommand:(NSDictionary *)command result:(NSDictionary *)result error:(NSString *)failure {
 self.localOperation=nil;[self refreshAgentStatus];
 NSString *identifier=command[@"id"];
 NSDictionary *reply=failure?@{@"id":identifier,@"error":failure}:@{@"id":identifier,@"result":result?:@{}};
 if([NSJSONSerialization dataWithJSONObject:reply options:0 error:nil].length>240*1024)reply=@{@"id":identifier,@"error":@"FLEX 结果超过传输上限；请缩小查询范围"};
 self.agentReplies[identifier]=reply;[self sendAgentReply:reply];
}
- (void)completeWindowCommand:(NSDictionary *)command error:(NSString *)failure {
 self.uiTransitioning=NO;self.localOperation=nil;[self refreshAgentStatus];
 NSDictionary *reply=failure?@{@"id":command[@"id"],@"error":failure}:@{@"id":command[@"id"],@"result":[self chatWindowStatus]};
 self.agentReplies[command[@"id"]]=reply;[self sendAgentReply:reply];
}
- (void)executeWindowCommand:(NSDictionary *)command {
 if(self.uiTransitioning){NSDictionary *reply=@{@"id":command[@"id"],@"error":@"窗口正在切换，请稍后重新读取 chat_status"};self.agentReplies[command[@"id"]]=reply;[self sendAgentReply:reply];return;}
 self.uiTransitioning=YES;NSString *operation=command[@"operation"];
 if([operation isEqual:@"minimize_chat"]){[self minimizeChat:![command[@"arguments"][@"surface"] isEqual:@"flex"] completion:^{[self completeWindowCommand:command error:nil];}];return;}
 if([operation isEqual:@"restore_chat"]){[self restoreChatWithCompletion:^{[self completeWindowCommand:command error:nil];}];return;}
 if([operation isEqual:@"open_tool"]){
  NSString *failure=nil;UIViewController *controller=nil;
  @try{controller=[self.runtime controllerForTool:command[@"arguments"][@"tool_id"] error:&failure];}@catch(NSException *exception){failure=[NSString stringWithFormat:@"FLEX 入口暂不可用（%@）",exception.name];}
  if(!controller){[self completeWindowCommand:command error:failure];return;}
  [self minimizeChat:NO completion:^{[FLEXManager.sharedManager dismissAnyPresentedTools:^{[FLEXManager.sharedManager presentEmbeddedTool:controller completion:^(UINavigationController *nav){[self completeWindowCommand:command error:nil];}];}];}];return;
 }
 UIViewController *visible=[FLEXUtility topViewControllerInWindow:FLEXManager.sharedManager.explorerWindow];
 if([visible isKindOfClass:UIAlertController.class]||AXGlassAlertVisible()){[self completeWindowCommand:command error:@"请先人工处理当前弹窗"];return;}
 if([operation isEqual:@"navigate_back"]){
  UINavigationController *nav=visible.navigationController;if(nav.viewControllers.count<2){[self completeWindowCommand:command error:@"当前 FLEX 页已经在导航根部"];return;}
  [nav popViewControllerAnimated:NO];[self completeWindowCommand:command error:nil];return;
 }
 [FLEXManager.sharedManager dismissAnyPresentedTools:^{[self completeWindowCommand:command error:nil];}];
}
- (void)executeAgentCommand:(NSDictionary *)command {
 NSString *operation=command[@"operation"];
 self.commandGenerations[command[@"id"]]=@(self.agentGeneration);
 if(self.commandGenerations.count>128){for(NSString *key in self.commandGenerations.allKeys)if(![key isEqual:self.pendingCommandID])[self.commandGenerations removeObjectForKey:key];}
 if(self.agentStopped){[self finishAgentCommand:command allowed:YES];return;}
 NSSet *confirm=[NSSet setWithArray:@[@"input_text",@"set_control_value",@"gesture",@"class_header",@"capture_screen",@"flex_ui_state",@"network_detail",@"sandbox_read",@"defaults_get",@"keychain_list",@"activate_control",@"scroll_view",@"set_view",@"set_network_recording",@"undo",@"minimize_chat",@"restore_chat",@"open_tool",@"navigate_back",@"dismiss_tool",@"select_row",@"set_search",@"flex_scroll"]];
 if(![confirm containsObject:operation]){[self finishAgentCommand:command allowed:YES];return;}
 if(self.projectID.length&&self.csrf.length&&self.sessionID.length){
  NSString *sid=command[@"sessionID"]?:self.sessionID;
  if(![sid isEqual:self.sessionID]){[self finishAgentCommand:command allowed:NO];return;}
  [self workspace:@"flex_tool_permission" arguments:@{@"sessionID":sid} completion:^(NSDictionary *state,NSError *error){
   if(![sid isEqual:self.sessionID]){[self finishAgentCommand:command allowed:NO];return;}
   if(!error&&[state[@"enabled"] boolValue]){[self finishAgentCommand:command allowed:YES];return;}
   // The server normally obtains the conversation grant before issuing a command.
   // Never add a second per-operation dialog after a grant has been accepted.
   [self finishAgentCommand:command allowed:NO];[self setStatus:@"请点击权限，授权当前会话的 FLEX 工具"];
  }];return;
 }
 [self finishAgentCommand:command allowed:NO];[self setStatus:@"请先授权当前会话的 FLEX 工具"];
}
- (void)showSessionPermission {
 NSString *sid=self.sessionID,*project=self.projectID;NSUInteger generation=self.sessionLoadGeneration;
 [self workspace:@"flex_tool_permission" arguments:@{@"sessionID":sid} completion:^(NSDictionary *state,NSError *error){
  if(generation!=self.sessionLoadGeneration||![sid isEqual:self.sessionID]||![project isEqual:self.projectID])return;
  if(error){[self showError:error];return;}BOOL active=[state[@"enabled"] boolValue];
  if(!active){[self setSessionPermission:YES session:sid project:project];return;}
  AXSheetItem *revoke=[AXSheetItem itemWithTitle:@"撤销本会话授权" subtitle:nil];
  revoke.destructive=YES;
  AXPresentSheet(self,@"本会话 FLEX 总权限",@"已授权，没有时间限制。新会话需重新授权；断开设备或停止远程服务后授权结束。",@[revoke],^(NSInteger index){
   if(index!=0)return;
   if([sid isEqual:self.sessionID]&&[project isEqual:self.projectID])[self setSessionPermission:NO session:sid project:project];
  });
 }];
}
- (void)setSessionPermission:(BOOL)enabled session:(NSString *)sid project:(NSString *)project {
 [self workspace:@"flex_tool_permission" arguments:@{@"sessionID":sid,@"enabled":@(enabled)} completion:^(NSDictionary *result,NSError *error){
  if(![sid isEqual:self.sessionID]||![project isEqual:self.projectID])return;
  if(error)[self showError:error];else [self setStatus:enabled?@"本会话 FLEX 已授权 · 无时间限制":@"本会话 FLEX 授权已撤销"];
 }];
}
- (void)mcpTapped {
 // 服务开关、端口、令牌与授权组已经合并进 AiFlex2 主页，聊天页不再维护第二份入口：
 // 直接退回面板，用户在「MCP 服务」卡里改，改完这里的状态跟着刷新。
 UINavigationController *navigation=self.navigationController;
 if(navigation.viewControllers.count>1){[navigation popToRootViewControllerAnimated:YES];return;}
 [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)permissionTapped {
 if(!self.csrf.length||!self.projectID.length){[self setStatus:@"请先连接 AiFlex2 并选择项目"];return;}
 if(self.sessionID.length){[self showSessionPermission];return;}
 if(self.busy){[self setStatus:@"正在建立会话，请稍后授权"];return;}
 NSString *project=self.projectID;NSUInteger generation=self.sessionLoadGeneration;self.busy=YES;
 [self workspace:@"ai_create" arguments:@{} completion:^(NSDictionary *result,NSError *error){
  self.busy=NO;if(generation!=self.sessionLoadGeneration||![project isEqual:self.projectID])return;
  if(error){[self showError:error];return;}NSString *sid=result[@"id"];
  if(![sid isKindOfClass:NSString.class]||!sid.length){[self showError:DXChatError(@"建立会话失败")];return;}
  self.sessionID=sid;self.sessionTitle=result[@"title"];[self updateSessionButton];[self rememberConnection];[self showSessionPermission];
 }];
}

// Plain HTTP is intentional for the user's LAN-only Remote service. This socket path is independent of host ATS and NSURLSession hooks.
- (NSDictionary *)requestSync:(NSString *)path body:(NSDictionary *)body error:(NSError **)error {
 NSString *newToken=nil;
 NSDictionary *result=FLEXDylixHTTPRequest(self.host,self.port,path,body,self.token,self.csrf,8,&newToken,error);
 if(newToken.length)self.token=newToken;
 return result;
}
- (void)request:(NSString *)path body:(NSDictionary *)body completion:(DXChatReply)completion {
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{NSError *error=nil;NSDictionary *result=[self requestSync:path body:body error:&error];dispatch_async(dispatch_get_main_queue(),^{completion(result,error);});});
}
- (void)workspace:(NSString *)action arguments:(NSDictionary *)arguments completion:(DXChatReply)completion {
 [self request:@"/api/v1/workspace" body:@{@"action":action,@"projectID":self.projectID?:@"",@"arguments":arguments?:@{}} completion:^(NSDictionary *data,NSError *error){if(error){completion(nil,error);return;}[self waitJob:data[@"id"] completion:completion];}];
}
- (void)waitJob:(NSString *)identifier completion:(DXChatReply)completion {
 if(![identifier isKindOfClass:NSString.class]){completion(nil,DXChatError(@"AiFlex2 没有返回任务 ID"));return;}
 [self request:@"/api/v1/jobs/get" body:@{@"id":identifier} completion:^(NSDictionary *job,NSError *error){
  if(error){completion(nil,error);return;}
  BOOL current=[identifier isEqual:self.jobID];
  if(current&&!self.jobStartedAt)self.jobStartedAt=NSProcessInfo.processInfo.systemUptime;
  if(current&&[job[@"sessionID"] isKindOfClass:NSString.class]){self.sessionID=job[@"sessionID"];[self rememberConnection];}
  if(current&&!self.agentStopped){[self updateTaskFromJob:job];if([job[@"text"] isKindOfClass:NSString.class])[self setLiveText:job[@"text"]];}
  NSString *state=job[@"state"];
  if([state isEqual:@"completed"]){if(current){self.jobStartedAt=0;self.jobNoticeMinutes=0;}completion(job[@"result"]?:@{},nil);return;}
  if([state isEqual:@"failed"]||[state isEqual:@"cancelled"]){if(current){self.jobStartedAt=0;self.jobNoticeMinutes=0;}completion(nil,DXChatError(job[@"error"]?:@"任务未完成"));return;}
  if([state isEqual:@"awaiting_confirmation"]){[self confirmJob:job completion:completion];return;}
  // 模型端长时间不给内容时，状态栏要逐步说明在等什么，不能一直只写“AI 正在回复…”。
  NSTimeInterval elapsed=current&&self.jobStartedAt>0?NSProcessInfo.processInfo.systemUptime-self.jobStartedAt:0;
  if(current&&!self.localOperation.length&&!self.activeToolOperations.count){
   NSUInteger minutes=(NSUInteger)(elapsed/60);
   if(minutes>=1&&minutes!=self.jobNoticeMinutes){self.jobNoticeMinutes=minutes;[self setStatus:[NSString stringWithFormat:@"仍在等待模型返回 · 已 %lu 分钟",(unsigned long)minutes]];}
  }
  // 十五分钟没有任何结论就收手：卡死的任务继续等下去只会让插件一直转圈。
  if(elapsed>900){
   [self request:@"/api/v1/jobs/cancel" body:@{@"id":identifier} completion:^(NSDictionary *r,NSError *e){}];
   self.jobStartedAt=0;self.jobNoticeMinutes=0;
   completion(nil,DXChatError(@"等待超过 15 分钟仍未完成，已停止等待。可以重新发送或换一个模型"));
   return;
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[self waitJob:identifier completion:completion];});
 }];
}
- (void)setAutoApproveEnabled:(BOOL)enabled {
 if(self.autoApprove==enabled){[self updateToggleButtons];return;}
 self.autoApprove=enabled;
 [NSUserDefaults.standardUserDefaults setBool:enabled forKey:@"FLEX.AiFlex2.AutoApprove.v1"];
 [NSUserDefaults.standardUserDefaults synchronize];
 [self setStatus:enabled?@"已开启自动允许：AI 的操作不再逐次确认":@"已关闭自动允许：AI 的操作会重新弹窗确认"];
 [self updateToggleButtons];
 [self refreshAgentStatus];
}
// 点亮的按钮用蓝色图标+淡蓝底；关闭时也留一层极淡的填充，保证在玻璃卡上看得见、点得到。
- (void)styleToggleButton:(UIButton *)button on:(BOOL)on {
 button.tintColor=on?UIColor.systemBlueColor:UIColor.secondaryLabelColor;
 button.backgroundColor=on?[UIColor.systemBlueColor colorWithAlphaComponent:0.18]:UIColor.tertiarySystemFillColor;
 button.layer.cornerRadius=9;
 button.layer.cornerCurve=kCACornerCurveContinuous;
 button.accessibilityValue=on?@"已开启":@"已关闭";
}
- (void)updateToggleButtons {
 UIImageSymbolConfiguration *symbol=[UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
 UIImage *autoImage=[UIImage systemImageNamed:(self.autoApprove?@"hand.raised.slash":@"hand.raised") withConfiguration:symbol];
 if(!autoImage)autoImage=[UIImage systemImageNamed:@"checkmark.circle" withConfiguration:symbol]; // 旧系统缺符号时留个可见的兜底
 [self.autoApproveButton setImage:autoImage forState:UIControlStateNormal];
 [self styleToggleButton:self.autoApproveButton on:self.autoApprove];
 UIImage *sunImage=[UIImage systemImageNamed:(self.keepAwake?@"sun.max.fill":@"sun.max") withConfiguration:symbol];
 [self.keepAwakeButton setImage:sunImage forState:UIControlStateNormal];
 [self styleToggleButton:self.keepAwakeButton on:self.keepAwake];
}
- (BOOL)keepAwakeWanted {
 if(!self.keepAwake)return NO;
 // 有活在跑就必须亮着：收起会话后 AI 还在继续，锁屏会被系统挂起。
 if(self.busy||self.jobID.length||self.localOperation.length||self.activeToolOperations.count)return YES;
 // 没有任务时就只在会话页真的在屏上时保持常亮；收起后立刻交还系统自动锁屏。
 return [self chatOnScreen];
}
- (void)updateIdleTimer {
 UIApplication.sharedApplication.idleTimerDisabled=[self keepAwakeWanted];
}
- (void)applyKeepAwake {
 [self updateIdleTimer];
 [self updateToggleButtons];
}
- (void)autoApproveTapped {
 UIImpactFeedbackGenerator *feedback=[[UIImpactFeedbackGenerator alloc]initWithStyle:UIImpactFeedbackStyleLight];[feedback impactOccurred];
 [self setAutoApproveEnabled:!self.autoApprove];
}
- (void)keepAwakeTapped {
 UIImpactFeedbackGenerator *feedback=[[UIImpactFeedbackGenerator alloc]initWithStyle:UIImpactFeedbackStyleLight];[feedback impactOccurred];
 self.keepAwake=!self.keepAwake;
 [NSUserDefaults.standardUserDefaults setBool:self.keepAwake forKey:@"FLEX.AiFlex2.KeepAwake.v1"];
 [NSUserDefaults.standardUserDefaults synchronize];
 [self applyKeepAwake];
 [self setStatus:self.keepAwake?@"已开启任务期间常亮：会话页打开或 AI 执行时不会锁屏":@"已关闭任务期间常亮：恢复系统自动锁屏"];
}
- (void)acceptJob:(NSString *)identifier nonce:(NSString *)nonce completion:(DXChatReply)completion {
 [self request:@"/api/v1/jobs/confirm" body:@{@"id":identifier,@"nonce":nonce,@"accepted":@YES} completion:^(NSDictionary *result,NSError *error){if(error)completion(nil,error);else [self waitJob:identifier completion:completion];}];
}
- (void)confirmJob:(NSDictionary *)job completion:(DXChatReply)completion {
 NSString *identifier=job[@"id"],*nonce=job[@"nonce"];if(!identifier.length||!nonce.length){completion(nil,DXChatError(@"确认请求无效"));return;}
 NSTimeInterval expiry=[job[@"expiresAt"] isKindOfClass:NSNumber.class]?[job[@"expiresAt"] doubleValue]:0;
 if(expiry<=0)expiry=NSDate.date.timeIntervalSince1970+120;
 if(!self.csrf.length||NSDate.date.timeIntervalSince1970>=expiry){completion(nil,DXChatError(@"AiFlex2 操作确认已过期"));return;}
 __block BOOL settled=NO;
 NSString *message=[@[job[@"confirmation"][@"summary"]?:@"AI 请求执行操作",job[@"confirmation"][@"details"]?:@""] componentsJoinedByString:@"\n\n"];
 // 自动允许：不再停在弹窗上，直接回执放行，状态栏留一句痕迹说明刚放行了什么。
 if(self.autoApprove){
  NSString *summary=job[@"confirmation"][@"summary"]?:@"AI 操作";
  self.waitingApproval=NO;
  [self setStatus:[NSString stringWithFormat:@"自动允许：%@",summary]];
  [self acceptJob:identifier nonce:nonce completion:completion];
  return;
 }
 AXGlassAlert *alert=AXPresentAlertWithToggle(self,@"确认 AiFlex2 操作",message,AXAlertMessageStyleText,@"本次会话内自动允许后续操作",self.autoApprove,@[
  [AXAlertButton buttonWithTitle:@"允许" style:AXAlertButtonStylePrimary handler:^(AXGlassAlert *action){
   if(settled)return;settled=YES;
   [self setAutoApproveEnabled:action.toggleOn];
   [self acceptJob:identifier nonce:nonce completion:completion];
  }],
  [AXAlertButton buttonWithTitle:@"拒绝" style:AXAlertButtonStyleDestructive handler:^(AXGlassAlert *action){
   if(settled)return;settled=YES;
   [self setAutoApproveEnabled:action.toggleOn];
   [self request:@"/api/v1/jobs/confirm" body:@{@"id":identifier,@"nonce":nonce,@"accepted":@NO} completion:^(NSDictionary *result,NSError *error){if(error)completion(nil,error);else [self waitJob:identifier completion:completion];}];
  }]
 ]);
 if(!alert){completion(nil,DXChatError(@"当前无法显示操作确认"));return;}
 // 原生弹窗不会自己消失，超过服务端有效期还挂着只会让人以为没反应；这里到点自动收起。
 NSTimeInterval delay=MAX(0,expiry-NSDate.date.timeIntervalSince1970);
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
  if(settled)return;settled=YES;
  [alert dismiss];
  completion(nil,DXChatError(@"AiFlex2 操作确认已过期"));
 });
}
- (void)connectTapped {
 NSString *address=self.host.length&&self.port
        ? [NSString stringWithFormat:@"http://%@:%lu",self.host,(unsigned long)self.port]
        : [NSString stringWithFormat:@"http://%@:%lu",FLEXDylixLocalIPv4(),(unsigned long)8787];
 NSMutableArray<AXAlertButton *> *actions=[NSMutableArray new];
 if(self.lastConnectionError.userInfo[FLEXDylixConnectionDiagnosticKey])[actions addObject:[AXAlertButton buttonWithTitle:@"上次连接诊断" style:AXAlertButtonStyleInline handler:^(AXGlassAlert *alert){[self showConnectionDiagnostic];}]];
 if(self.token.length)[actions addObject:[AXAlertButton buttonWithTitle:@"使用已保存连接" style:AXAlertButtonStyleInline handler:^(AXGlassAlert *alert){self.needsConnectionValidation=YES;self.lastValidateFailure=0;[self resumeSavedConnection];}]];
 // 顶部不再放地球图标，MCP 的设置入口挪到这里，功能不缺失。
 [actions addObject:[AXAlertButton buttonWithTitle:@"MCP 服务设置" style:AXAlertButtonStyleInline handler:^(AXGlassAlert *alert){[self mcpTapped];}]];
 [actions addObject:[AXAlertButton buttonWithTitle:@"取消" style:AXAlertButtonStyleCancel handler:nil]];
 [actions addObject:[AXAlertButton buttonWithTitle:@"连接" style:AXAlertButtonStylePrimary handler:^(AXGlassAlert *alert){
  NSArray<NSString *> *values=alert.values;
  NSString *host=nil,*message=nil;NSUInteger port=0;
  if(!FLEXDylixParseAddress(values.firstObject,&host,&port,&message)){[self showError:DXChatError(message)];return;}
  NSString *rawCode=values.count>1?values[1]:@"";
  NSString *code=[rawCode stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(!code.length){[self showError:DXChatError(@"请输入授权码")];return;}
  if(self.busy){[self setStatus:@"AI 正在执行，请结束任务后更换连接"];return;}
  BOOL changed=![self.host isEqual:host]||self.port!=port;self.sessionLoadGeneration++;self.host=host;self.port=port;self.authorizationCode=code;self.token=nil;self.csrf=nil;self.needsConnectionValidation=NO;self.restoringWorkspace=NO;self.missedHeartbeats=0;
  if(changed){self.projectID=nil;self.projectName=nil;self.connectionID=nil;self.modelID=nil;self.modelName=nil;self.sessionID=nil;self.sessionTitle=nil;[self.messages removeAllObjects];[self renderMessages];[self.projectButton setTitle:@"选择项目" forState:UIControlStateNormal];[self.modelButton setTitle:@"选择模型" forState:UIControlStateNormal];[self updateSessionButton];}
  [self rememberConnection];[self showConnectionState:1];
  NSString *name=[NSString stringWithFormat:@"FLEX · %@",NSBundle.mainBundle.bundleIdentifier?:@"目标 App"];if(name.length>64)name=[name substringToIndex:64];[self setStatus:@"正在配对…"];
  [self request:@"/api/v1/pair" body:@{@"code":code,@"name":name,@"workspace":@YES} completion:^(NSDictionary *data,NSError *error){if(error){[self showConnectionState:3];[self showError:error];return;}[self request:@"/api/v1/status" body:@{} completion:^(NSDictionary *status,NSError *failure){if(failure){[self showConnectionState:3];[self showError:failure];return;}self.csrf=status[@"session"][@"csrf"];if(!self.csrf.length){[self showConnectionState:3];[self showError:DXChatError(@"配对后未取得请求校验值")];return;}[self showConnectionState:2];[self setStatus:@"配对完成"];[self startAgentPolling];if(self.projectID.length)[self restoreSavedWorkspace];else [self projectTapped];}];}];
 }]];
 AXPresentForm(self,@"连接 AiFlex2",@"先在 AiFlex2 App 的「设置 → 插件开发 → 局域网连接」打开「HTTP 服务」。\n默认地址是本机 Wi-Fi 地址加 8787 端口，与 App 的默认设置一致，直接连接即可。若 App 里把连接方式切成了「仅本机」，把地址改成 http://127.0.0.1:8787。授权码在 App 页面的「访问与配对」里。\n要在插件里长时间用，请到 App 的「局域网连接 → 后台保持服务」打开开关，否则 App 切后台约 30 秒后服务会暂停。",@[
  [AXAlertField fieldWithPlaceholder:@"粘贴 AiFlex2 复制的访问地址" text:address kind:AXAlertFieldKindURL],
  [AXAlertField fieldWithPlaceholder:@"授权码" text:self.authorizationCode kind:AXAlertFieldKindSecure]
 ],actions);
}
- (void)projectTapped {if(self.restoringWorkspace){[self setStatus:@"正在恢复上次项目和会话，请稍候"];return;}
 if(self.busy){[self setStatus:@"AI 正在回复，结束后可切换项目"];return;}
 if(!self.csrf.length){[self connectTapped];return;}
 [self workspace:@"projects" arguments:@{} completion:^(NSDictionary *data,NSError *error){
  if(error){[self showError:error];return;}
  NSArray *projects=[data[@"projects"] isKindOfClass:NSArray.class]?data[@"projects"]:@[];
  if(!projects.count){[self showError:DXChatError(@"AiFlex2 里还没有项目。请先在 App 里新建项目，再回来选择")];return;}
  NSMutableArray<AXSheetItem *> *items=[NSMutableArray new];
  for(id raw in projects){if(![raw isKindOfClass:NSDictionary.class])continue;NSString *name=raw[@"name"]?:raw[@"id"];if(![name isKindOfClass:NSString.class]||!name.length)continue;AXSheetItem *item=[AXSheetItem itemWithTitle:name subtitle:nil];item.selected=[self.projectID isEqual:raw[@"id"]];[items addObject:item];}
  AXPresentSheet(self,@"选择 AiFlex2 项目",@"AI 的文件和构建权限限定在所选项目；选完会接着让你选模型",items,^(NSInteger index){
   if(index<0||index>=(NSInteger)items.count)return;
   NSDictionary *project=nil;NSUInteger position=0;
   for(id raw in projects){if(![raw isKindOfClass:NSDictionary.class])continue;NSString *name=raw[@"name"]?:raw[@"id"];if(![name isKindOfClass:NSString.class]||!name.length)continue;if(position==(NSUInteger)index){project=raw;break;}position++;}
   if(!project)return;
   NSString *name=project[@"name"]?:project[@"id"];
   if(![self.projectID isEqual:project[@"id"]]){[self saveDraft];self.sessionLoadGeneration++;self.projectID=project[@"id"];self.projectName=name;self.sessionID=nil;self.sessionTitle=nil;self.reasoningEffort=nil;self.reasoningOptions=nil;self.liveMessage=nil;[self.messages removeAllObjects];[self addMessage:@"已切换项目。选择历史会话，或直接发送以创建新会话。" role:@"tip"];[self restoreDraft];[self updateSessionButton];}else self.projectName=name;
   [self.projectButton setTitle:name forState:UIControlStateNormal];[self rememberConnection];[self modelTapped];
  });
 }];
}
- (void)applyModelSelection:(NSDictionary *)connection {
 BOOL changed=![self.connectionID isEqual:connection[@"id"]]||![self.modelID isEqual:connection[@"model"]];
 self.connectionID=connection[@"id"];self.modelID=connection[@"model"];self.reasoningOptions=connection[@"efforts"];
 if(changed)self.reasoningEffort=@"auto";
 self.modelName=[NSString stringWithFormat:@"%@ · %@",connection[@"provider"]?:@"",self.modelID?:@""];
 [self.modelButton setTitle:self.modelID?:@"选择模型" forState:UIControlStateNormal];[self rememberConnection];
 [self setStatus:[NSString stringWithFormat:@"模型已选择 · %@",self.modelName]];
}
- (void)chooseReasoningForConnection:(NSDictionary *)connection {
 NSArray *options=connection[@"efforts"];if(![options isKindOfClass:NSArray.class]||options.count<2){[self setStatus:@"此模型未提供可调思考档位，将使用模型默认设置"];return;}
 NSString *project=[self.projectID copy],*cid=[self.connectionID copy],*model=[self.modelID copy];NSUInteger generation=self.sessionLoadGeneration;
 NSMutableArray<AXSheetItem *> *items=[NSMutableArray new];NSMutableArray<NSDictionary *> *entries=[NSMutableArray new];
 for(id raw in options){if(![raw isKindOfClass:NSDictionary.class])continue;NSString *value=raw[@"id"];if(![value isKindOfClass:NSString.class]||!value.length)continue;NSString *name=raw[@"name"]?:value;AXSheetItem *item=[AXSheetItem itemWithTitle:name subtitle:nil];item.selected=[value isEqual:self.reasoningEffort];[items addObject:item];[entries addObject:raw];}
 if(!items.count){[self setStatus:@"此模型未提供可调思考档位，将使用模型默认设置"];return;}
 AXPresentSheet(self,@"深度思考",@"仅列出当前模型支持的档位。选择后下次发送生效；未在 FLEX 选择时沿用 AiFlex2 会话设置。",items,^(NSInteger index){
  if(index<0||index>=(NSInteger)entries.count)return;
  if(self.busy||generation!=self.sessionLoadGeneration||![project isEqual:self.projectID]||![cid isEqual:self.connectionID]||![model isEqual:self.modelID])return;
  NSDictionary *option=entries[(NSUInteger)index];NSString *value=option[@"id"];NSString *name=option[@"name"]?:value;
  self.reasoningEffort=value;[self setStatus:[NSString stringWithFormat:@"深度思考：%@ · 下次发送生效",name]];
 });
}
- (void)modelTapped {if(self.restoringWorkspace){[self setStatus:@"正在恢复上次项目和会话，请稍候"];return;}
 if(self.busy){[self setStatus:@"AI 正在回复，结束后可切换模型"];return;}
 if(!self.csrf.length){[self connectTapped];return;}
 if(!self.projectID.length){
  // 模型是按项目授权的，没有项目时列表必然是空的。先说明原因，再进项目列表，选完自动接模型列表。
  [self setStatus:@"模型按项目授权，请先选择项目"];
  [self projectTapped];return;}
 NSString *project=self.projectID;NSUInteger generation=++self.sessionLoadGeneration;
 [self workspace:@"ai_connections" arguments:@{} completion:^(NSDictionary *data,NSError *error){
  if(generation!=self.sessionLoadGeneration||![project isEqual:self.projectID]||self.busy)return;
  if(error){[self showError:error];return;}
  NSArray *connections=[data[@"connections"] isKindOfClass:NSArray.class]?data[@"connections"]:@[];
  if(!connections.count){[self showError:DXChatError(@"这个项目还没有可用模型。请先在 AiFlex2 里添加模型服务，再回来选择")];return;}
  NSMutableArray<AXSheetItem *> *items=[NSMutableArray new];NSMutableArray<NSDictionary *> *entries=[NSMutableArray new];
  for(id raw in connections){if(![raw isKindOfClass:NSDictionary.class])continue;NSString *name=[NSString stringWithFormat:@"%@ · %@",raw[@"provider"]?:@"",raw[@"model"]?:@""];AXSheetItem *item=[AXSheetItem itemWithTitle:name subtitle:nil];item.selected=[self.connectionID isEqual:raw[@"id"]]&&[self.modelID isEqual:raw[@"model"]];[items addObject:item];[entries addObject:raw];}
  AXPresentSheet(self,@"选择模型",nil,items,^(NSInteger index){
   if(index<0||index>=(NSInteger)entries.count)return;
   if(generation!=self.sessionLoadGeneration||![project isEqual:self.projectID]||self.busy)return;
   NSDictionary *connection=entries[(NSUInteger)index];
   [self applyModelSelection:connection];
   [self chooseReasoningForConnection:connection];
  });
 }];
}
// App 的会话记录是权威来源：插件只做过滤和上下文剥离，不再自己拼一份历史。
- (NSMutableArray<NSMutableDictionary *> *)transcriptFrom:(NSArray *)raw {
 NSMutableArray<NSMutableDictionary *> *list=[NSMutableArray new];
 if(![raw isKindOfClass:NSArray.class])return list;
 for(id item in raw){
  if(![item isKindOfClass:NSDictionary.class])continue;
  NSString *role=item[@"role"];if(![@[@"user",@"assistant"] containsObject:role])continue;
  NSString *text=DXChatContent(item[@"content"]);if(!text.length)continue;
  if([role isEqual:@"user"])text=DXChatUserText(text);
  if(!text.length)continue;
  [list addObject:[@{@"role":role,@"text":text} mutableCopy]];
 }
 return list;
}
- (BOOL)applyTranscript:(NSArray *)raw {
 NSMutableArray *list=[self transcriptFrom:raw];
 if(!list.count)return NO;
 self.liveMessage=nil;self.liveHasContent=NO;[self.messages setArray:list];[self renderMessages];
 return YES;
}
// 发送失败但 AI 一个字都没产出时，不要把错误塞进助手气泡——那看起来像 AI 的回答，
// 也正是“显示完成却没有回复数据”的来源。改成一行系统提示，并收回空气泡。
- (void)failPendingReply:(NSError *)error {
 NSString *reason=error.localizedDescription?:@"请求失败";
 NSMutableDictionary *live=self.liveMessage;
 if(live&&!self.liveHasContent&&![live[@"text"] length]){
  NSUInteger position=[self.messages indexOfObjectIdenticalTo:live];
  if(position!=NSNotFound)[self.messages removeObjectAtIndex:position];
  self.liveMessage=nil;[self renderMessages];
  [self append:[@"消息没有发出 · " stringByAppendingString:reason]];
  return;
 }
 [self setLiveText:reason];
}
// 任务结束但手上没有可显示的文字：先看任务结果，再回读 App 会话记录，最后给出明确结论。
- (void)finishReplyWithResult:(NSDictionary *)result {
 if(!self.liveHasContent){
  NSArray *messages=[result[@"messages"] isKindOfClass:NSArray.class]?result[@"messages"]:nil;
  for(NSDictionary *message in messages.reverseObjectEnumerator){
   if(![message isKindOfClass:NSDictionary.class]||![message[@"role"] isEqual:@"assistant"])continue;
   NSString *text=DXChatContent(message[@"content"]);if(text.length){[self setLiveText:text];break;}
  }
 }
 if(self.liveHasContent){[self setStatus:@"回复完成"];return;}
 NSString *sid=self.sessionID;NSUInteger generation=self.agentGeneration;
 if(!sid.length){[self noteEmptyReply];return;}
 [self setStatus:@"正在同步回复…"];
 [self workspace:@"ai_read" arguments:@{@"sessionID":sid} completion:^(NSDictionary *record,NSError *error){
  if(generation!=self.agentGeneration)return;
  if(!error&&[self applyTranscript:record[@"messages"]]){[self setStatus:@"回复完成"];return;}
  [self noteEmptyReply];
 }];
}
- (void)noteEmptyReply {
 NSString *text=@"模型这次没有返回可显示的文字，可能被上游中断了。可以发送「继续」重试，或在设置里换一个模型。";
 // 没有活动气泡时（例如记录回读把消息整批替换掉了）就补一行系统提示，别让界面停在“正在回复…”。
 if(self.liveMessage)[self setLiveText:text];else [self append:text];
 [self setStatus:@"模型未返回内容"];
}
- (void)setLiveText:(NSString *)text {
 if(!self.liveMessage)return;
 NSString *value=text?:@"";
 // 任务轮询每秒都会回传一次全文：内容没变就不要重排 Markdown、不要抢滚动、更不要写盘。
 if([self.liveMessage[@"text"] isEqualToString:value])return;
 self.liveMessage[@"text"]=value;self.liveHasContent=value.length>0;
 NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
 if(now-self.lastLiveRender>=0.2){self.lastLiveRender=now;self.liveLabel.attributedText=FLEXDylixRenderMarkdown(value,self.liveLabel.textColor);}
 else self.liveLabel.text=value;
 // 只有本来就贴着底部时才跟随；用户上翻阅读历史时不要抢走滚动位置。
 UIScrollView *scroll=self.messageScroll;
 if(scroll.bounds.size.height>0&&scroll.contentSize.height-scroll.bounds.size.height-scroll.contentOffset.y<160)[self scrollMessagesToBottom];
}
- (void)sendTapped {
 if(self.restoringWorkspace){[self setStatus:@"正在恢复上次项目和会话，请稍候"];return;}
 if(self.needsConnectionValidation){[self resumeSavedConnection];return;}
 if(self.busy){[self stopAgentTapped];return;}
 NSString *question=[self.input.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(!question.length)return;
 if(!self.projectID.length||!self.connectionID.length||!self.modelID.length){[self showError:DXChatError(@"请先连接 AiFlex2，选择项目和模型")];return;}
 if(!self.sessionID.length){
  NSString *project=self.projectID;NSUInteger loadGeneration=self.sessionLoadGeneration,requestGeneration=self.agentGeneration;self.busy=YES;
  [self workspace:@"ai_create" arguments:@{@"name":question.length>30?[question substringToIndex:30]:question} completion:^(NSDictionary *record,NSError *error){
   self.busy=NO;if(loadGeneration!=self.sessionLoadGeneration||requestGeneration!=self.agentGeneration||![project isEqual:self.projectID])return;
   if(error){[self showError:error];return;}NSString *sid=record[@"id"];
   if(![sid isKindOfClass:NSString.class]||!sid.length){[self showError:DXChatError(@"建立会话失败")];return;}
   self.sessionID=sid;self.sessionTitle=record[@"title"];[self rememberConnection];[self updateSessionButton];[self sendTapped];
  }];return;
 }
 self.agentStopped=NO;self.lastEventSequence=0;self.captureStatus=nil;self.captureID=nil;self.lastCaptureSequence=0;[self.activeToolOperations removeAllObjects];self.waitingApproval=NO;self.taskPhase=@"正在同步现场";self.lastTaskUpdate=NSProcessInfo.processInfo.systemUptime;
 NSUInteger generation=self.agentGeneration;
 self.busy=YES;self.input.text=@"";[self textViewDidChange:self.input];[self.input resignFirstResponder];[self addMessage:question role:@"user"];[self addMessage:@"" role:@"assistant"];self.liveHasContent=NO;[self setStatus:@"正在同步 FLEX 现场…"];
 NSString *bundle=NSBundle.mainBundle.bundleIdentifier?:@"unknown";NSString *current=self.reportProvider?self.reportProvider():self.report;
 NSDictionary *live=[self.runtime execute:@"current" arguments:@{} error:nil]?:@{};NSData *liveData=[NSJSONSerialization dataWithJSONObject:live options:0 error:nil];NSString *liveText=liveData?[[NSString alloc]initWithData:liveData encoding:NSUTF8StringEncoding]:@"";
 NSString *fullReport=[NSString stringWithFormat:@"%@\nCurrent FLEX runtime: %@",current?:@"",liveText?:@""];NSString *report=fullReport.length>16000?[fullReport substringToIndex:16000]:fullReport;
 NSString *liveClass=live[@"selectedObject"][@"class"]?:self.className;
 [self workspace:@"flex_publish" arguments:@{@"bundleID":bundle,@"className":liveClass?:@"未知对象",@"report":report,@"capabilities":@{@"protocolVersion":@2,@"touchGestures":@([[self.runtime execute:@"gesture_capabilities" arguments:@{} error:nil][@"available"] boolValue])}} completion:^(NSDictionary *published,NSError *error){if(generation!=self.agentGeneration){self.busy=NO;[self setStatus:@"任务已停止"];return;}if(error){self.busy=NO;self.sendButton.enabled=YES;[self failPendingReply:error];[self showError:error];return;}
  NSString *contextualQuestion=[NSString stringWithFormat:@"%@\n\n当前 FLEX 现场：目标 App %@，当前选中对象 %@。你可以自主用 flex_live_read(current)、screen_elements 和 view_tree 探索整个当前页面，不必等用户先选视图；可用 hit_test 从窗口坐标定位对象。若当前模型已验证图片能力，且用户授权 FLEX 敏感读取，可用 flex_sensitive_read(capture_screen) 获取目标窗口截图；截图会作为下一轮真正的图片输入，不是 base64 文本。需要进入页面时，可请求 flex_control(activate_control) 激活可见 UIButton，或 scroll_view 滚动，均受 FLEX 控制授权约束；操作后重新观察页面。默认目标是在 AiFlex2 当前项目中编写持久插件功能，视图实例 ID 不是 Logos Hook 的类名或 selector。按需用 class_info、项目文件及已授权头文件核查类与方法；object_info 的 hookEvidence 提供祖先视图、nearest_responder_controller、稳定特征候选和生命周期方法声明位置。先读取目标按钮与业务祖先的 object_info，再用 class_info/class_header 核查；导航离开重进、滚动复用后重新截图和查询，比较 signature 与 instanceID。lifecycleExecutionObserved=false 表示没有调用轨迹，不能把声明当成实际执行；stabilityVerified=false 表示尚需你交叉验证。证据不足时说明缺口，不要编造 Hook。set_view 仅临时改变当前实例，不能代替插件代码；项目写入和构建仍走 AiFlex2 原有审批。",question,bundle,liveClass];
  contextualQuestion=[contextualQuestion stringByAppendingString:@"\n自主操作时先读取 tool_catalog、chat_status，以及 read_app_state 返回的能力清单（capabilities）：can 是现在确实具备的，cannot 不要尝试并直接说明缺口，unknown 只有实际调用后才知道；不要凭记忆推断自己能做什么。需要操作目标 App 时调用 flex_control(minimize_chat, surface=target)，确认 chat_status.targetReady=true 后再触摸，会话与任务保持运行；需要操作 FLEX 功能页时用 open_tool 和返回目录中的 tool_id，随后用 flex_sensitive_read(flex_ui_state) 读取页面、用 set_search / flex_scroll / select_row 导航（仅 selectSupported=true 的行），最后可 restore_chat 恢复聊天。截图可指定 surface=flex 或 target。收起后有独立的 AI 状态悬浮球，显示连接、工具处理和回复状态，不暂停会话；用户可以点击悬浮球或 FLEX 菜单的 AiFlex2 AI 回到同一会话。状态球不是目标 App 控件，不要操作它。若工具报告停止，不可重试控制。目录标为不支持的入口不要声称已操作。需要自定义点击、双击、长按、滑动、拖动、双指缩放或旋转时，先读 gesture_capabilities；若可用，再在会话已收起到 target 后调用 flex_control(gesture)。这是投递真实触摸序列，返回 delivered 仅证明已投递，必须重新截图/读取现场确认业务效果。滚动返回 scrolled 表示实际位移；用 previousOffset、contentOffset、delta 与 reachedBoundary 区分移动和触及边界。xx.h 与反汇编入口为 extension.headers / extension.disassembly；class_header 可按行读取真实头文件。若候选 UIButton 无 controlActions，或 hit_test 命中其父容器，应继续检查交互父视图、手势及所属控制器，不能据此编写全局 UIButton Hook。用户要求的测试应逐项执行或明确阻塞原因，不得因为其他项目已通过就跳过可恢复的测试。独立测试构建前先确认 schema 能否选择隔离项目/配置；没有入口就先报告阻塞，不能只创建散落源码后当成构建准备完成，更不能改业务根配置。仅返回普通页面且实例相同，只能说明实例被保留，不能当作销毁重建或列表复用验证。截图像素尺寸可能经过压缩，触摸坐标以 screen_elements.windowBounds 为准。"];
  NSMutableDictionary *arguments=[@{@"text":contextualQuestion,@"connectionID":self.connectionID,@"model":self.modelID,@"mode":@"develop"} mutableCopy];if(self.sessionID.length)arguments[@"sessionID"]=self.sessionID;if(self.reasoningEffort.length)arguments[@"reasoningEffort"]=self.reasoningEffort;
  [self setStatus:@"AI 正在回复…"];[self request:@"/api/v1/workspace" body:@{@"action":@"ai_send",@"projectID":self.projectID,@"arguments":arguments} completion:^(NSDictionary *job,NSError *failure){if(generation!=self.agentGeneration){self.busy=NO;if([job[@"id"] length])[self request:@"/api/v1/jobs/cancel" body:@{@"id":job[@"id"]} completion:^(NSDictionary *r,NSError *e){}];return;}if(failure){self.busy=NO;self.sendButton.enabled=YES;[self failPendingReply:failure];[self showError:failure];return;}self.jobID=job[@"id"];self.jobStartedAt=NSProcessInfo.processInfo.systemUptime;self.jobNoticeMinutes=0;if([job[@"sessionID"] isKindOfClass:NSString.class])self.sessionID=job[@"sessionID"];[self waitJob:self.jobID completion:^(NSDictionary *result,NSError *endError){if(generation!=self.agentGeneration)return;self.busy=NO;self.sendButton.enabled=YES;self.jobID=nil;self.jobStartedAt=0;self.jobNoticeMinutes=0;if(endError){[self failPendingReply:endError];[self setStatus:[[endError.localizedDescription componentsSeparatedByString:@"\n"] firstObject]?:@"请求未完成"];return;}if([result[@"sessionID"] isKindOfClass:NSString.class]){self.sessionID=result[@"sessionID"];if(!self.sessionTitle.length){self.sessionTitle=question.length>30?[question substringToIndex:30]:question;[self updateSessionButton];}}[self finishReplyWithResult:result];[self rememberConnection];}];}];
 }];
}
- (void)dealloc {UIApplication.sharedApplication.idleTimerDisabled=NO;[NSNotificationCenter.defaultCenter removeObserver:self];[_agentTimer invalidate];_statusWindow.hidden=YES;}
@end
