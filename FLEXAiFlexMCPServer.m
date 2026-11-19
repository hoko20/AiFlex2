#import "FLEXAiFlexMCPServer.h"
#import "FLEXAiFlexRuntime.h"
#import "FLEXAiFlex2ViewController.h"
#import "FLEXManager+Private.h"
#import <Network/Network.h>
#import <Security/Security.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <arpa/inet.h>
#import <stdlib.h>

static NSString *const DXMCPServiceKey=@"FLEXAiFlexMCP.enabled";
static NSString *const DXMCPPortKey=@"FLEXAiFlexMCP.port";
static NSString *const DXMCPTokenKey=@"FLEXAiFlexMCP.token";
static NSString *const DXMCPAuthKey=@"FLEXAiFlexMCP.requireToken";
static NSString *const DXMCPGroupPrefix=@"FLEXAiFlexMCP.group.";
static NSString *const DXMCPVersion=@"2025-06-18";

static NSDictionary *HTTPJSON(NSInteger status,NSDictionary *json,NSDictionary *headers){
 NSData *data=[NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
 NSMutableDictionary *response=[@{@"status":@(status),@"headers":headers?:@{},@"body":data?:NSData.data} mutableCopy];
 return response;
}
static NSDictionary *RPC(id identifier,NSDictionary *result){
 return @{@"jsonrpc":@"2.0",@"id":identifier?:NSNull.null,@"result":result?:@{}};
}
static NSDictionary *RPCError(id identifier,NSInteger code,NSString *message){
 return @{@"jsonrpc":@"2.0",@"id":identifier?:NSNull.null,@"error":@{@"code":@(code),@"message":message?:@"请求无效"}};
}
static NSString *JSONText(id object){
 NSData *data=[NSJSONSerialization dataWithJSONObject:object?:@{} options:0 error:nil];
 NSString *text=data?[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding]:nil;
 if(text.length>256000)text=[[text substringToIndex:256000] stringByAppendingString:@"\n…（结果过长已截断，请缩小查询范围）"];
 return text?:@"{}";
}
static NSDictionary *TextContent(id object,BOOL failed){
 NSMutableDictionary *result=[@{@"content":@[@{@"type":@"text",@"text":JSONText(object)}]} mutableCopy];
 if(failed)result[@"isError"]=@YES;
 return result;
}
static NSDictionary *ToolError(NSString *message){return TextContent(@{@"error":message?:@"工具执行失败"},YES);}
static NSDictionary *FlexContent(NSDictionary *result){
 NSMutableDictionary *text=[result mutableCopy];
 NSString *image=[text[@"imageBase64"] isKindOfClass:NSString.class]?text[@"imageBase64"]:nil;
 NSString *mime=[text[@"mime"] isKindOfClass:NSString.class]?text[@"mime"]:@"";
 [text removeObjectForKey:@"imageBase64"];
 NSMutableArray *content=[NSMutableArray arrayWithObject:@{@"type":@"text",@"text":JSONText(text)}];
 if([mime isEqual:@"image/jpeg"]&&image.length&&image.length<400000)[content addObject:@{@"type":@"image",@"data":image,@"mimeType":mime}];
 return @{@"content":content};
}
static NSDictionary *StringField(void){return @{@"type":@"string"};}
static NSDictionary *ArrayField(void){return @{@"type":@"array"};}
static NSDictionary *IntegerField(void){return @{@"type":@"integer"};}
static NSDictionary *NumberField(void){return @{@"type":@"number"};}
static NSDictionary *BooleanField(void){return @{@"type":@"boolean"};}
static NSDictionary *EnumField(NSArray *values){return @{@"type":@"string",@"enum":values};}
static NSDictionary *Tool(NSString *name,NSString *group,NSString *description,NSDictionary *properties,NSArray *required){
 return @{@"name":name,@"group":group,@"description":description,@"schema":@{@"type":@"object",@"properties":properties?:@{},@"required":required?:@[],@"additionalProperties":@NO}};
}
static NSArray<NSString *> *ReadOperations(void){return @[@"capabilities",@"current",@"report",@"screen_elements",@"screen_texts",@"find_text",@"hit_test",@"view_tree",@"object_info",@"object_properties",@"find_instances",@"class_search",@"class_info",@"runtime_images",@"network_list",@"network_search",@"cookies_list",@"sandbox_list",@"defaults_keys",@"select_object",@"gesture_capabilities",@"tool_catalog",@"chat_status",@"snapshot"];}
static NSArray<NSString *> *SensitiveOperations(void){return @[@"class_header",@"flex_ui_state",@"network_detail",@"network_export",@"sandbox_read",@"sandbox_grep",@"defaults_get",@"keychain_list",@"capture_screen"];}
static NSArray<NSString *> *ControlOperations(void){return @[@"minimize_chat",@"restore_chat",@"open_tool",@"navigate_back",@"dismiss_tool",@"select_row",@"set_search",@"flex_scroll",@"input_text",@"set_control_value",@"activate_control",@"tap_text",@"highlight_element",@"scroll_view",@"set_view",@"set_network_recording",@"undo",@"invoke_method",@"gesture"];}
static BOOL GroupEnabled(NSString *group){
 if([group isEqual:@"read"])return YES;
 if([group isEqual:@"sensitive"])return [FLEXAiFlexMCPServer sensitiveEnabled];
 if([group isEqual:@"control"])return [FLEXAiFlexMCPServer controlEnabled];
 if([group isEqual:@"script"])return [FLEXAiFlexMCPServer scriptEnabled];
 if([group isEqual:@"tracing"])return [FLEXAiFlexMCPServer tracingEnabled];
 return NO;
}
// Window operations belong to FLEXAiFlex2ViewController; everything else is
// executed by FLEXAiFlexRuntime.
static BOOL WindowOperation(NSString *operation){
 static NSSet *operations;static dispatch_once_t once;
 dispatch_once(&once,^{operations=[NSSet setWithArray:@[@"chat_status",@"minimize_chat",@"restore_chat",@"open_tool",@"navigate_back",@"dismiss_tool"]];});
 return [operations containsObject:operation];
}
static NSString *Instructions(void){
 return @"你通过 AiFlex2 直连当前注入的 App。先调用 aiflex_read(operation=capabilities)、current 和 report，核对 bundleID、当前页面、选中对象与可用操作；连接配置存在不代表目标在线。选中对象为空不妨碍用 screen_elements / view_tree 自主观察，不要只凭最后点选的控件猜界面。\n需要操作目标页面时，若 FLEX 或聊天覆盖层可见，先调用 aiflex_control(operation=minimize_chat, surface=target)，再读 screen_elements 和截图；状态悬浮球不是业务控件。截图用 aiflex_sensitive(operation=capture_screen)；返回截图不代表模型一定收到图像。\n只使用真实返回的 id/frame/窗口坐标，导航后重新读取，不连续重试过期 id。activate_control 的支持范围以返回为准，不支持时可在 gesture_capabilities 确认后端可用并获授权后使用 gesture。需要触发业务方法或已存在的 Hook 时，可用 aiflex_control(operation=invoke_method, selector=..., arguments=[...])；传 id 指定实时对象，或传 class 调用类方法，不传则用当前选中对象。返回对象时会给出 returnId，可继续用 aiflex_read(operation=object_info, id=returnId) 读取实例数据，或用 invoke_method(id=returnId) 调实例方法。需要查找当前界面里某个类的已有实例，用 aiflex_read(operation=find_instances, class=...)，返回的 id 同样可继续使用；非界面对象不做堆扫描。参数仅支持字符串、数字、布尔、null、数组和字典，最多 8 个；调用会执行真实副作用，是否触发 Hook 取决于目标实现，调用后重新读取现场。delivered、dispatched、scrolled 不是业务成功证明，操作后核对 controllerPath、控件文字/位置、contentOffset 和新截图；滚动 delta=0 要报告未滚动。切页前记录恢复路径，结束后 restore_chat。\n稳定 Hook 证据：object_info + view_tree + class_info；头文件用 aiflex_sensitive(operation=class_header) 的 name/start_line/line_count 分页。区分当前对象、交互父容器、业务祖先、最近 responder controller 和声明所属镜像；hookEvidence 的声明候选、executionObserved、stabilityVerified 分开解释，未观测执行不能称为已验证生命周期。\nset_view / undo 仅作临时现场验证，需授权并复查；持久修改要写进工程并构建，不能用临时隐藏冒充插件功能。\n定位文字用 aiflex_read(operation=find_text, query=...) 或 screen_texts；点击文字用 aiflex_control(operation=tap_text, query=...)；读实例字段值用 object_properties；日志搜索用 aiflex_sensitive(operation=sandbox_grep, path=..., query=...)；对比操作前后用 aiflex_read(operation=snapshot, action=save/diff)。脚本仅在手机端开启「脚本执行」后用 aiflex_script(operation=run_js, code=...)，只影响 WKWebView。方法追踪仅在开启「方法追踪」后用 aiflex_trace(operation=start/stop/read/clear, class=..., selector=...)，它替换方法实现并记录调用，可能崩溃或卡顿，10 分钟自动停止，不要对高频方法开启。\n日志：先 sandbox_list 取真实相对路径和大小，再 aiflex_sensitive(operation=sandbox_read, path=...)，默认 128 KiB、limit 最高 524288；优先 tail=true 读末尾，tail 不与 offset 同传；续读用 next_offset，检查 has_more、totalBytes、modifiedAt。网络详情、defaults、文件和钥匙串元数据只在授权范围内读取，不复述秘密。报告工具失败、空结果、未测项和真实截图状态，不凭配置声称功能正常。";
}
static NSArray<NSDictionary *> *Tools(void){ static NSArray *tools;static dispatch_once_t once;
 dispatch_once(&once,^{
  NSDictionary *read=@{@"operation":EnumField(ReadOperations()),@"id":StringField(),@"query":StringField(),@"name":StringField(),@"class":StringField(),@"limit":IntegerField(),@"path":StringField(),@"offset":IntegerField(),@"x":NumberField(),@"y":NumberField(),@"exact":BooleanField(),@"action":EnumField(@[@"save",@"diff",@"clear"])};
  NSDictionary *sensitive=@{@"operation":EnumField(SensitiveOperations()),@"surface":EnumField(@[@"target",@"flex"]),@"name":StringField(),@"start_line":IntegerField(),@"line_count":IntegerField(),@"id":StringField(),@"path":StringField(),@"query":StringField(),@"case_sensitive":BooleanField(),@"rect":StringField(),@"key":StringField(),@"offset":IntegerField(),@"limit":IntegerField(),@"tail":BooleanField()};
  NSDictionary *control=@{@"operation":EnumField(ControlOperations()),@"surface":EnumField(@[@"target",@"flex"]),@"tool_id":StringField(),@"query":StringField(),@"exact":BooleanField(),@"section":IntegerField(),@"row":IntegerField(),@"kind":EnumField(@[@"tap",@"double_tap",@"long_press",@"swipe",@"drag",@"pinch",@"rotate"]),@"x":NumberField(),@"y":NumberField(),@"end_x":NumberField(),@"end_y":NumberField(),@"duration":NumberField(),@"start_radius":NumberField(),@"end_radius":NumberField(),@"radius":NumberField(),@"angle":NumberField(),@"text":StringField(),@"replace":BooleanField(),@"value":NumberField(),@"index":IntegerField(),@"id":StringField(),@"direction":EnumField(@[@"up",@"down",@"left",@"right"]),@"pages":NumberField(),@"hidden":BooleanField(),@"alpha":NumberField(),@"enabled":BooleanField(),@"selector":StringField(),@"arguments":ArrayField(),@"class":StringField()};
  NSDictionary *script=@{@"operation":EnumField(@[@"run_js"]),@"code":StringField(),@"id":StringField()};
  NSDictionary *trace=@{@"operation":EnumField(@[@"start",@"stop",@"read",@"clear"]),@"class":StringField(),@"selector":StringField()};
  tools=@[
   Tool(@"aiflex_status",@"read",@"Report this injected app, the MCP endpoint, listening state and enabled tool groups.",@{},@[]),
   Tool(@"aiflex_read",@"read",@"Read runtime facts from this app through FLEX: capabilities, current object, report text, screen elements/texts, text search, hit test, view tree, object info/properties, instances, class search/info, loaded images, network metadata/search, cookies metadata, sandbox listing, defaults keys and screen snapshots. Live IDs expire after navigation or tree refresh; requery instead of reusing stale ids.",read,@[@"operation"]),
   Tool(@"aiflex_sensitive",@"sensitive",@"Read sensitive app content with the phone-side sensitive grant: class header, FLEX UI state, network detail/export, text grep in sandbox files, UTF-8 sandbox file, defaults value, Keychain metadata (never secret values) and an app JPEG screenshot (optional rect crop).",sensitive,@[@"operation"]),
   Tool(@"aiflex_control",@"control",@"Control this app with the phone-side control grant: minimize/restore panel, open tools, navigate, select rows, search, scroll, input text, set values, activate buttons, tap by text, highlight a view, change hidden/alpha, toggle network recording, undo, invoke a method and deliver real gestures. Delivered input is not proof the action succeeded; requery afterwards.",control,@[@"operation"]),
   Tool(@"aiflex_script",@"script",@"Run JavaScript inside the current page's WKWebView/UIWebView with the phone-side script grant. This changes web page state and is isolated from the native process; it is not a hooking tool.",script,@[@"operation",@"code"]),
   Tool(@"aiflex_trace",@"tracing",@"Experimental method tracing with the phone-side tracing grant: replace an instance method's implementation and record calls (up to 3 object arguments, void/object return) in a 500-event ring buffer. High risk: may change app behavior, crash, or slow high-frequency methods. Active hooks auto-stop after 10 minutes.",trace,@[@"operation"])
  ];
 });return tools;
}
static NSDictionary *ToolNamed(NSString *name){
 for(NSDictionary *tool in Tools())if([tool[@"name"] isEqual:name])return tool;
 return nil;
}
static BOOL TypeMatches(NSString *type,id value){
 if([type isEqual:@"string"])return [value isKindOfClass:NSString.class];
 if([type isEqual:@"boolean"])return [value isKindOfClass:NSNumber.class];
 if([type isEqual:@"array"])return [value isKindOfClass:NSArray.class];
 return [value isKindOfClass:NSNumber.class];
}
static BOOL Same(NSString *left,NSString *right){
 if(left.length!=right.length)return NO;
 const char *a=left.UTF8String,*b=right.UTF8String;unsigned char diff=0;
 for(NSUInteger i=0;i<left.length;i++)diff|=(unsigned char)(a[i]^b[i]);
 return diff==0;
}
static NSString *RandomToken(void){
 unsigned char bytes[32];if(SecRandomCopyBytes(kSecRandomDefault,sizeof(bytes),bytes)!=errSecSuccess)arc4random_buf(bytes,sizeof(bytes));
 NSMutableString *token=[NSMutableString stringWithCapacity:64];
 for(NSUInteger i=0;i<sizeof(bytes);i++)[token appendFormat:@"%02x",bytes[i]];
 return token;
}
static NSString *LocalIPv4(void){
 struct ifaddrs *interfaces=NULL;NSString *address=@"127.0.0.1";
 if(getifaddrs(&interfaces)!=0)return address;
 for(struct ifaddrs *cursor=interfaces;cursor;cursor=cursor->ifa_next){
  if(!cursor->ifa_addr||cursor->ifa_addr->sa_family!=AF_INET||(cursor->ifa_flags&IFF_LOOPBACK))continue;
  NSString *name=cursor->ifa_name?[NSString stringWithUTF8String:cursor->ifa_name]:@"";
  if(![name hasPrefix:@"en"])continue;
  char buffer[INET_ADDRSTRLEN];inet_ntop(AF_INET,&((struct sockaddr_in*)cursor->ifa_addr)->sin_addr,buffer,sizeof(buffer));
  address=[NSString stringWithUTF8String:buffer];break;
 }
 freeifaddrs(interfaces);return address;
}

@interface FLEXAiFlexMCPServer ()
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic) nw_listener_t listener;
@property(nonatomic) NSMutableSet *connections;
@property(atomic) BOOL running;
@property(atomic,copy) NSString *lastError;
@property(nonatomic) FLEXAiFlexRuntime *runtime;
- (void)accept:(nw_connection_t)connection;
- (void)read:(nw_connection_t)connection buffer:(NSMutableData *)buffer;
- (void)process:(nw_connection_t)connection buffer:(NSMutableData *)buffer;
- (void)handle:(NSDictionary *)request connection:(nw_connection_t)connection;
- (void)mcp:(NSDictionary *)body connection:(nw_connection_t)connection;
- (NSArray<NSDictionary *> *)schemas;
- (void)sendResponse:(NSDictionary *)response connection:(nw_connection_t)connection;
- (void)call:(NSString *)name arguments:(NSDictionary *)arguments completion:(void (^)(NSDictionary *result))completion;
- (void)respond:(nw_connection_t)connection status:(NSInteger)status headers:(NSDictionary *)headers body:(NSData *)body;
- (void)close:(nw_connection_t)connection;
@end
@implementation FLEXAiFlexMCPServer
+ (instancetype)shared{
 static FLEXAiFlexMCPServer *server;static dispatch_once_t once;
 dispatch_once(&once,^{server=[FLEXAiFlexMCPServer new];});
 return server;
}
+ (BOOL)isEnabled{return [NSUserDefaults.standardUserDefaults boolForKey:DXMCPServiceKey];}
+ (void)setEnabled:(BOOL)enabled{[NSUserDefaults.standardUserDefaults setBool:enabled forKey:DXMCPServiceKey];}
+ (NSUInteger)port{
 NSUInteger port=[NSUserDefaults.standardUserDefaults integerForKey:DXMCPPortKey];
 return port>=1024&&port<=65535?port:8790;
}
+ (void)setPort:(NSUInteger)port{if(port<1024||port>65535)return;[NSUserDefaults.standardUserDefaults setInteger:port forKey:DXMCPPortKey];}
+ (BOOL)authRequired{
 id stored=[NSUserDefaults.standardUserDefaults objectForKey:DXMCPAuthKey];
 return stored?[stored boolValue]:YES;
}
+ (void)setAuthRequired:(BOOL)required{[NSUserDefaults.standardUserDefaults setBool:required forKey:DXMCPAuthKey];}
+ (NSString *)token{
 NSString *token=[NSUserDefaults.standardUserDefaults stringForKey:DXMCPTokenKey];
 if(!token.length){token=RandomToken();[NSUserDefaults.standardUserDefaults setObject:token forKey:DXMCPTokenKey];}
 return token;
}
+ (BOOL)setToken:(NSString *)token{
 NSString *value=[token stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
 if(value.length<8||value.length>64)return NO;
 NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"];
 if([value rangeOfCharacterFromSet:allowed.invertedSet].location!=NSNotFound)return NO;
 [NSUserDefaults.standardUserDefaults setObject:value forKey:DXMCPTokenKey];
 return YES;
}
+ (NSString *)rotateToken{
 NSString *token=RandomToken();[NSUserDefaults.standardUserDefaults setObject:token forKey:DXMCPTokenKey];return token;
}
+ (BOOL)sensitiveEnabled{
 id stored=[NSUserDefaults.standardUserDefaults objectForKey:[DXMCPGroupPrefix stringByAppendingString:@"sensitive"]];
 return stored?[stored boolValue]:NO;
}
+ (void)setSensitiveEnabled:(BOOL)enabled{[NSUserDefaults.standardUserDefaults setBool:enabled forKey:[DXMCPGroupPrefix stringByAppendingString:@"sensitive"]];}
+ (BOOL)controlEnabled{
 id stored=[NSUserDefaults.standardUserDefaults objectForKey:[DXMCPGroupPrefix stringByAppendingString:@"control"]];
 return stored?[stored boolValue]:NO;
}
+ (void)setControlEnabled:(BOOL)enabled{[NSUserDefaults.standardUserDefaults setBool:enabled forKey:[DXMCPGroupPrefix stringByAppendingString:@"control"]];}
+ (BOOL)scriptEnabled{
+ id stored=[NSUserDefaults.standardUserDefaults objectForKey:[DXMCPGroupPrefix stringByAppendingString:@"script"]];
+ return stored?[stored boolValue]:NO;
+}
+ (void)setScriptEnabled:(BOOL)enabled{[NSUserDefaults.standardUserDefaults setBool:enabled forKey:[DXMCPGroupPrefix stringByAppendingString:@"script"]];}
+ (BOOL)tracingEnabled{
+ id stored=[NSUserDefaults.standardUserDefaults objectForKey:[DXMCPGroupPrefix stringByAppendingString:@"tracing"]];
+ return stored?[stored boolValue]:NO;
+}
+ (void)setTracingEnabled:(BOOL)enabled{[NSUserDefaults.standardUserDefaults setBool:enabled forKey:[DXMCPGroupPrefix stringByAppendingString:@"tracing"]];}
+ (NSString *)endpoint{return [NSString stringWithFormat:@"http://%@:%lu/mcp",LocalIPv4(),(unsigned long)[self port]];}
+ (NSString *)status{
 FLEXAiFlexMCPServer *server=[self shared];
 if(![self isEnabled])return @"未开启";
 if(server.lastError.length)return server.lastError;
 return server.running?@"运行中":@"正在启动";
}
- (instancetype)init{
 if((self=[super init])){_queue=dispatch_queue_create("flex.aiflex.mcp",DISPATCH_QUEUE_SERIAL);_connections=[NSMutableSet new];}
 return self;
}
- (void)start{
 dispatch_async(self.queue,^{
  if(self.running)return;
  self.lastError=@"";
  if(self.listener){nw_listener_cancel(self.listener);self.listener=nil;}
  nw_parameters_t parameters=nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL,NW_PARAMETERS_DEFAULT_CONFIGURATION);
  NSString *port=[NSString stringWithFormat:@"%lu",(unsigned long)[FLEXAiFlexMCPServer port]];
  nw_listener_t listener=nw_listener_create_with_port(port.UTF8String,parameters);
  if(!listener){self.lastError=@"无法创建 MCP 监听器";return;}
  nw_listener_set_queue(listener,self.queue);
  __weak typeof(self) weak=self;
  nw_listener_set_new_connection_handler(listener,^(nw_connection_t connection){[weak accept:connection];});
  nw_listener_set_state_changed_handler(listener,^(nw_listener_state_t state,nw_error_t error){
   FLEXAiFlexMCPServer *server=weak;if(!server)return;
   if(state==nw_listener_state_ready){server.running=YES;server.lastError=@"";}
   else if(state==nw_listener_state_failed){server.running=NO;server.lastError=[NSString stringWithFormat:@"端口 %lu 无法监听",(unsigned long)[FLEXAiFlexMCPServer port]];}
   else if(state==nw_listener_state_cancelled){server.running=NO;}
  });
  self.listener=listener;
  nw_listener_start(listener);
 });
}
- (void)stop{
 dispatch_async(self.queue,^{
  if(self.listener){nw_listener_cancel(self.listener);self.listener=nil;}
  for(nw_connection_t connection in self.connections.allObjects)nw_connection_cancel(connection);
  [self.connections removeAllObjects];self.running=NO;
 });
}
- (BOOL)privateConnection:(nw_connection_t)connection{
 nw_endpoint_t endpoint=nw_connection_copy_endpoint(connection);
 const struct sockaddr *address=nw_endpoint_get_address(endpoint);
 if(!address){
  nw_path_t path=nw_connection_copy_current_path(connection);
  nw_endpoint_t remote=path?nw_path_copy_effective_remote_endpoint(path):nil;
  address=remote?nw_endpoint_get_address(remote):NULL;
 }
 if(!address||address->sa_family!=AF_INET)return NO;
 uint32_t host=ntohl(((const struct sockaddr_in *)address)->sin_addr.s_addr);
 if((host>>24)==127||(host>>24)==10||(host&0xFFF00000)==0xAC100000||(host>>16)==0xC0A8||(host>>16)==0xA9FE)return YES;
 return NO;
}
- (void)accept:(nw_connection_t)connection{
 if(self.connections.count>=8||![self privateConnection:connection]){nw_connection_cancel(connection);return;}
 [self.connections addObject:connection];
 __weak typeof(self) weak=self;
 nw_connection_set_queue(connection,self.queue);
 nw_connection_set_state_changed_handler(connection,^(nw_connection_state_t state,nw_error_t error){
  if(state==nw_connection_state_failed||state==nw_connection_state_cancelled)[weak close:connection];
 });
 nw_connection_start(connection);
 [self read:connection buffer:[NSMutableData data]];
}
- (void)read:(nw_connection_t)connection buffer:(NSMutableData *)buffer{
 __weak typeof(self) weak=self;
 nw_connection_receive(connection,1,65536,^(dispatch_data_t content,nw_content_context_t context,bool complete,nw_error_t error){
  FLEXAiFlexMCPServer *server=weak;if(!server)return;
  if(error){[server close:connection];return;}
  if(content)[buffer appendData:(NSData *)content];
  [server process:connection buffer:buffer];
 });
}
- (void)process:(nw_connection_t)connection buffer:(NSMutableData *)buffer{
 NSData *marker=[@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
 NSRange range=[buffer rangeOfData:marker options:0 range:NSMakeRange(0,buffer.length)];
 if(range.location==NSNotFound){
  if(buffer.length>16384){[self respond:connection status:431 headers:@{} body:[@"请求头过大" dataUsingEncoding:NSUTF8StringEncoding]];return;}
  [self read:connection buffer:buffer];return;
 }
 NSData *head=[buffer subdataWithRange:NSMakeRange(0,range.location)];
 NSString *text=[[NSString alloc]initWithData:head encoding:NSUTF8StringEncoding];
 NSArray *lines=[text componentsSeparatedByString:@"\r\n"];
 NSArray *requestLine=lines.count?[lines[0] componentsSeparatedByString:@" "]:@[];
 if(requestLine.count<2){[self respond:connection status:400 headers:@{} body:[@"请求格式无效" dataUsingEncoding:NSUTF8StringEncoding]];return;}
 NSMutableDictionary *headers=[NSMutableDictionary new];
 for(NSUInteger i=1;i<lines.count;i++){
  NSRange colon=[lines[i] rangeOfString:@":"];
  if(colon.location==NSNotFound)continue;
  NSString *key=[[lines[i] substringToIndex:colon.location] lowercaseString];
  NSString *value=[[lines[i] substringFromIndex:colon.location+1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  if(key.length)headers[key]=value;
 }
 NSUInteger length=[headers[@"content-length"] integerValue];
 if(length>2*1024*1024){[self respond:connection status:413 headers:@{} body:[@"请求体过大" dataUsingEncoding:NSUTF8StringEncoding]];return;}
 NSUInteger start=NSMaxRange(range);
 if(buffer.length<start+length){[self read:connection buffer:buffer];return;}
 NSData *body=[buffer subdataWithRange:NSMakeRange(start,length)];
 NSString *peer=@"";
 nw_endpoint_t endpoint=nw_connection_copy_endpoint(connection);
 const struct sockaddr *address=nw_endpoint_get_address(endpoint);
 if(address&&address->sa_family==AF_INET){char text[INET_ADDRSTRLEN];inet_ntop(AF_INET,&((const struct sockaddr_in *)address)->sin_addr,text,sizeof(text));peer=[NSString stringWithUTF8String:text]?:@"";}
 [self handle:@{@"method":requestLine[0],@"path":requestLine[1],@"headers":headers,@"body":body,@"peer":peer} connection:connection];
}
- (void)handle:(NSDictionary *)request connection:(nw_connection_t)connection{
 NSString *method=request[@"method"];NSString *path=request[@"path"];
 if(![path isEqual:@"/mcp"]){[self respond:connection status:404 headers:@{} body:[@"Not Found" dataUsingEncoding:NSUTF8StringEncoding]];return;}
 if([method isEqual:@"DELETE"]){[self respond:connection status:204 headers:@{} body:NSData.data];return;}
 if(![method isEqual:@"POST"]){[self respond:connection status:405 headers:@{} body:[@"Method Not Allowed" dataUsingEncoding:NSUTF8StringEncoding]];return;}
 if([FLEXAiFlexMCPServer authRequired]){
  NSString *authorization=request[@"headers"][@"authorization"];
  NSString *token=[authorization.lowercaseString hasPrefix:@"bearer "]?[authorization substringFromIndex:7]:nil;
  if(!token.length||!Same(token,[FLEXAiFlexMCPServer token])){[self respond:connection status:401 headers:@{@"WWW-Authenticate":@"Bearer realm=\"AiFlex2 MCP\""} body:[@"Unauthorized" dataUsingEncoding:NSUTF8StringEncoding]];return;}
 }
 id body=[NSJSONSerialization JSONObjectWithData:request[@"body"]?:NSData.data options:0 error:nil];
 if(![body isKindOfClass:NSDictionary.class]){[self respond:connection status:400 headers:@{} body:[@"JSON 解析失败" dataUsingEncoding:NSUTF8StringEncoding]];return;}
 [self mcp:body connection:connection];
}
- (void)mcp:(NSDictionary *)body connection:(nw_connection_t)connection{
 id identifier=body[@"id"];NSString *method=body[@"method"];NSDictionary *params=[body[@"params"] isKindOfClass:NSDictionary.class]?body[@"params"]:@{};
 if(![method isKindOfClass:NSString.class]){[self respond:connection status:400 headers:@{} body:[@"JSON-RPC 请求无效" dataUsingEncoding:NSUTF8StringEncoding]];return;}
 if(!identifier){[self respond:connection status:202 headers:@{} body:NSData.data];return;}
 if([method isEqual:@"initialize"]){
  NSString *requested=params[@"protocolVersion"];
  NSString *version=[requested isKindOfClass:NSString.class]&&[@[@"2025-06-18",@"2025-03-26",@"2024-11-05"] containsObject:requested]?requested:DXMCPVersion;
  NSString *appVersion=[NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] isKindOfClass:NSString.class]?NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"]:@"dev";
  NSDictionary *response=HTTPJSON(200,RPC(identifier,@{@"protocolVersion":version,@"capabilities":@{@"tools":@{@"listChanged":@NO}},@"serverInfo":@{@"name":@"AiFlex2",@"version":appVersion},@"instructions":Instructions()}),@{@"Mcp-Session-Id":NSUUID.UUID.UUIDString});
  [self sendResponse:response connection:connection];return;
 }
 if([method isEqual:@"ping"]){[self sendResponse:HTTPJSON(200,RPC(identifier,@{}),nil) connection:connection];return;}
 if([method isEqual:@"tools/list"]){[self sendResponse:HTTPJSON(200,RPC(identifier,@{@"tools":[self schemas]}),nil) connection:connection];return;}
 if([method isEqual:@"tools/call"]){
  NSString *name=params[@"name"];id arguments=params[@"arguments"]?:@{};
  if(![name isKindOfClass:NSString.class]||![arguments isKindOfClass:NSDictionary.class]){[self sendResponse:HTTPJSON(200,RPCError(identifier,-32602,@"tools/call 缺少 name 或 arguments"),nil) connection:connection];return;}
  [self call:name arguments:arguments completion:^(NSDictionary *result){[self sendResponse:HTTPJSON(200,RPC(identifier,result),nil) connection:connection];}];return;
 }
 [self sendResponse:HTTPJSON(200,RPCError(identifier,-32601,[@"未实现的方法：" stringByAppendingString:method]),nil) connection:connection];
}
- (void)sendResponse:(NSDictionary *)response connection:(nw_connection_t)connection{
 [self respond:connection status:[response[@"status"] integerValue] headers:response[@"headers"] body:response[@"body"]];
}
- (NSArray<NSDictionary *> *)schemas{
 NSMutableArray *list=[NSMutableArray new];
 for(NSDictionary *tool in Tools()){
  NSString *group=tool[@"group"];BOOL enabled=GroupEnabled(group);
  if(!enabled)continue;
  NSMutableDictionary *entry=[@{@"name":tool[@"name"],@"description":tool[@"description"],@"inputSchema":tool[@"schema"]} mutableCopy];
  if([group isEqual:@"read"])entry[@"annotations"]=@{@"readOnlyHint":@YES,@"destructiveHint":@NO};
  [list addObject:entry];
 }
 return list;
}
- (void)call:(NSString *)name arguments:(NSDictionary *)arguments completion:(void (^)(NSDictionary *))completion{
 NSDictionary *tool=ToolNamed(name);
 NSString *group=tool[@"group"];
 BOOL enabled=tool&&GroupEnabled(group);
 if(!enabled){completion(ToolError(@"工具不存在或已在 FLEX 设置中关闭"));return;}
 if([name isEqual:@"aiflex_status"]){
  NSString *bundle=NSBundle.mainBundle.bundleIdentifier?:@"";
  NSDictionary *status=@{@"bundleID":bundle,@"endpoint":[FLEXAiFlexMCPServer endpoint],@"state":[FLEXAiFlexMCPServer status],@"groups":@{@"read":@YES,@"sensitive":@([FLEXAiFlexMCPServer sensitiveEnabled]),@"control":@([FLEXAiFlexMCPServer controlEnabled]),@"script":@([FLEXAiFlexMCPServer scriptEnabled]),@"tracing":@([FLEXAiFlexMCPServer tracingEnabled])},@"server":@"AiFlex2 in-app",@"build":@"2026-11-19-full",@"selectedObject":([FLEXAiFlexRuntime sharedRuntime].selectedObject?NSStringFromClass([[FLEXAiFlexRuntime sharedRuntime].selectedObject class]):@"未选中")};
  completion(TextContent(status,NO));return;
 }
 NSDictionary *properties=tool[@"schema"][@"properties"];
 for(id key in arguments){
  if(![key isKindOfClass:NSString.class]){completion(ToolError(@"参数名无效"));return;}
  NSDictionary *property=properties[key];
  if(!property){completion(ToolError([@"未注册参数：" stringByAppendingString:key]));return;}
  if(!TypeMatches(property[@"type"],arguments[key])){completion(ToolError([@"参数类型有误：" stringByAppendingString:key]));return;}
  if(property[@"enum"]&&![property[@"enum"] containsObject:arguments[key]]){completion(ToolError([@"参数取值无效：" stringByAppendingString:key]));return;}
 }
 for(NSString *key in tool[@"schema"][@"required"])if(![arguments objectForKey:key]){completion(ToolError([@"缺少参数：" stringByAppendingString:key]));return;}
 NSString *operation=arguments[@"operation"];
 if(![operation isKindOfClass:NSString.class]||!operation.length){completion(ToolError(@"缺少 operation"));return;}
 NSMutableDictionary *wire=[arguments mutableCopy];[wire removeObjectForKey:@"operation"];
 if([name isEqual:@"aiflex_script"]){
  dispatch_async(dispatch_get_main_queue(),^{
   [[FLEXAiFlexRuntime sharedRuntime] runJavaScript:wire completion:^(NSDictionary *result,NSString *error){
    dispatch_async(self.queue,^{completion(error.length?ToolError(error):FlexContent(result));});
   }];
  });
  return;
 }
 if([name isEqual:@"aiflex_trace"]){
  dispatch_async(dispatch_get_main_queue(),^{
   NSString *traceError=nil;NSDictionary *traceResult=nil;
   @try{traceResult=[[FLEXAiFlexRuntime sharedRuntime] traceOperation:operation arguments:wire error:&traceError];}
   @catch(NSException *exception){traceError=[NSString stringWithFormat:@"方法追踪异常（%@），请先 stop 再重试",exception.name];}
   dispatch_async(self.queue,^{completion(traceError.length?ToolError(traceError):FlexContent(traceResult));});
  });
  return;
 }
 if([operation isEqual:@"tap_text"]){
  dispatch_async(dispatch_get_main_queue(),^{
   [[FLEXAiFlexRuntime sharedRuntime] performTapText:wire completion:^(NSDictionary *result,NSString *error){
    dispatch_async(self.queue,^{completion(error.length?ToolError(error):FlexContent(result));});
   }];
  });
  return;
 }
 if(WindowOperation(operation)){
  dispatch_async(dispatch_get_main_queue(),^{
   FLEXAiFlex2ViewController *panel=[FLEXAiFlex2ViewController aiFlex2CurrentPanel];
   if(!panel){
    if([operation isEqual:@"chat_status"]){
     NSDictionary *state=@{@"chatVisible":@NO,@"minimized":@NO,@"connected":@NO,@"taskRunning":@NO,@"stopped":@NO,@"sessionID":@"",@"flexVisible":@(!FLEXManager.sharedManager.isHidden),@"targetReady":@(FLEXManager.sharedManager.isHidden),@"statusVisible":@NO,@"activity":@"",@"uiTransitioning":@NO};
     dispatch_async(self.queue,^{completion(TextContent(state,NO));});
     return;
    }
    dispatch_async(self.queue,^{completion(ToolError(@"请先打开 AiFlex2 面板（FLEX 工具栏 AiFlex2 按钮）后再使用窗口控制"));});
    return;
   }
   [panel performWindowOperation:operation arguments:wire completion:^(NSDictionary *result,NSString *error){
    dispatch_async(self.queue,^{completion(error.length?ToolError(error):FlexContent(result));});
   }];
  });
  return;
 }
 dispatch_async(dispatch_get_main_queue(),^{
  FLEXAiFlexRuntime *runtime=self.runtime;
  if(!runtime){runtime=[FLEXAiFlexRuntime sharedRuntime];self.runtime=runtime;}
  if([operation isEqual:@"gesture"]){
   [runtime performGesture:wire completion:^(NSDictionary *result,NSString *error){
    dispatch_async(self.queue,^{completion(error.length?ToolError(error):FlexContent(result));});
   }];return;
  }
  NSString *error=nil;
  NSDictionary *result=nil;
  @try{result=[runtime execute:operation arguments:wire error:&error];}
  @catch(NSException *exception){error=[NSString stringWithFormat:@"FLEX 操作异常（%@）；请重新查询页面",exception.name];}
  dispatch_async(self.queue,^{completion(error.length?ToolError(error):FlexContent(result));});
 });
}
- (void)respond:(nw_connection_t)connection status:(NSInteger)status headers:(NSDictionary *)headers body:(NSData *)body{
 NSMutableString *head=[NSMutableString stringWithFormat:@"HTTP/1.1 %ld %@\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: %lu\r\nConnection: close\r\n",(long)status,status==200?@"OK":status==202?@"Accepted":status==204?@"No Content":status==401?@"Unauthorized":@"Error",(unsigned long)body.length];
 for(NSString *key in headers)[head appendFormat:@"%@: %@\r\n",key,headers[key]];
 [head appendString:@"\r\n"];
 NSMutableData *message=[head dataUsingEncoding:NSUTF8StringEncoding].mutableCopy;
 [message appendData:body];
 // The destructor block keeps the backing NSData alive until dispatch_data is
 // released; DISPATCH_DATA_DESTRUCTOR_DEFAULT would not retain the buffer.
 NSData *payload=[message copy];
 dispatch_data_t data=dispatch_data_create(payload.bytes,payload.length,self.queue,^{ (void)payload; });
 __weak typeof(self) weak=self;
 nw_connection_send(connection,data,NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,true,^(nw_error_t error){[weak close:connection];});
}
- (void)close:(nw_connection_t)connection{
 [self.connections removeObject:connection];nw_connection_cancel(connection);
}
@end
__attribute__((constructor)) static void FLEXAiFlexMCPBoot(void){
 if(![FLEXAiFlexMCPServer isEnabled])return;
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[[FLEXAiFlexMCPServer shared] start];});
}
