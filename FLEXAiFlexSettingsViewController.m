#import "FLEXAiFlexSettingsViewController.h"
#import "FLEXAiFlexMCPServer.h"

@implementation FLEXAiFlexSettingsViewController
- (instancetype)init{
 if((self=[super initWithStyle:UITableViewStyleInsetGrouped])){
  self.title=@"MCP 服务";
  self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc]initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
 }
 return self;
}
- (void)viewDidLoad{
 [super viewDidLoad];
 self.tableView.rowHeight=50;
 [self reloadSoon];
}
- (void)done{[self dismissViewControllerAnimated:YES completion:nil];}
- (void)reloadSoon{
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.6*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[self.tableView reloadData];});
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView{return 3;}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section{
 return section==0?@"服务":section==1?@"授权":@"使用方式";
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section{
 if(section==1)return @"敏感读取：头文件、日志/网络正文、文件搜索、截图与 Keychain 元数据。\n界面控制：点击、输入、滚动、手势、高亮与方法调用，会真实改变 App 状态。\n脚本执行：在 WKWebView 运行 JavaScript，可能改变网页状态。\n方法追踪：运行期替换方法实现并记录调用，可能崩溃或卡顿，10 分钟自动停止。\n授权保护开启时必须携带 Bearer 令牌；关闭后同一局域网内无需令牌即可连接，请仅在可信网络使用。";
 if(section==2)return @"在电脑端 MCP 客户端（Claude Desktop、Cursor、Cherry Studio 等）添加 Streamable HTTP 服务，URL 填上方访问地址；开启授权保护时请求头加 Authorization: Bearer <访问令牌>。服务只在宿主 App 进程内运行，App 被挂起或杀死时连接会中断，重新打开 App 后自动恢复。HTTP 为明文，仅用于可信局域网。";
 return nil;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{
 return section==0?4:section==1?8:2;
}
- (UITableViewCell *)cell:(UITableView *)tableView{
 UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"cell"];
 if(!cell)cell=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"cell"];
 return cell;
}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath{
 if(indexPath.section==1&&(indexPath.row==0||indexPath.row>=4))return 68;
 return 50;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath{
 if(indexPath.section==1&&(indexPath.row==0||indexPath.row>=4)){
  UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"permission"];
  if(!cell)cell=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"permission"];
  cell.accessoryView=nil;cell.accessoryType=UITableViewCellAccessoryNone;cell.selectionStyle=UITableViewCellSelectionStyleNone;
  cell.textLabel.font=[UIFont systemFontOfSize:16];cell.textLabel.textColor=UIColor.labelColor;
  cell.detailTextLabel.font=[UIFont systemFontOfSize:11];cell.detailTextLabel.textColor=UIColor.secondaryLabelColor;cell.detailTextLabel.numberOfLines=0;
  NSArray *titles=@[@"授权保护",@"敏感读取",@"界面控制",@"脚本执行",@"方法追踪"];
  NSArray *details=@[@"要求客户端携带 Bearer 令牌；关闭后同局域网可直接连接",
   @"头文件、日志/网络正文、文件搜索、截图与 Keychain 元数据",
   @"点击、输入、滚动、手势、高亮与方法调用，会改变 App 状态",
   @"在 WKWebView 执行 JavaScript，可能改变网页状态",
   @"替换方法实现并记录调用，高风险，10 分钟自动停止"];
  NSInteger index=indexPath.row==0?0:indexPath.row-3;
  cell.textLabel.text=titles[index];cell.detailTextLabel.text=details[index];
  UISwitch *toggle=[UISwitch new];toggle.tag=820+index;
  if(index==0)toggle.on=[FLEXAiFlexMCPServer authRequired];
  else if(index==1)toggle.on=[FLEXAiFlexMCPServer sensitiveEnabled];
  else if(index==2)toggle.on=[FLEXAiFlexMCPServer controlEnabled];
  else if(index==3)toggle.on=[FLEXAiFlexMCPServer scriptEnabled];
  else toggle.on=[FLEXAiFlexMCPServer tracingEnabled];
  if(index==0&&![FLEXAiFlexMCPServer isEnabled])cell.textLabel.textColor=UIColor.secondaryLabelColor;
  else if(index>=3&&toggle.on)cell.textLabel.textColor=UIColor.systemOrangeColor;
  [toggle addTarget:self action:@selector(toggleGroup:) forControlEvents:UIControlEventValueChanged];
  cell.accessoryView=toggle;return cell;
 }
 UITableViewCell *cell=[self cell:tableView];
 cell.accessoryView=nil;cell.accessoryType=UITableViewCellAccessoryNone;cell.selectionStyle=UITableViewCellSelectionStyleDefault;
 cell.detailTextLabel.text=nil;cell.textLabel.textColor=UIColor.labelColor;cell.textLabel.font=[UIFont systemFontOfSize:17];
 if(indexPath.section==0){
  cell.textLabel.text=@[@"MCP 服务",@"监听端口",@"访问地址",@"运行状态"][indexPath.row];
  if(indexPath.row==0){UISwitch *toggle=[UISwitch new];toggle.on=[FLEXAiFlexMCPServer isEnabled];[toggle addTarget:self action:@selector(toggleService:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=toggle;cell.selectionStyle=UITableViewCellSelectionStyleNone;}
  else if(indexPath.row==1){cell.detailTextLabel.text=[NSString stringWithFormat:@"%lu",(unsigned long)[FLEXAiFlexMCPServer port]];cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;}
  else if(indexPath.row==2){cell.detailTextLabel.text=[FLEXAiFlexMCPServer endpoint];cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;}
  else cell.detailTextLabel.text=[FLEXAiFlexMCPServer status];
 }
 else if(indexPath.section==1){
  cell.textLabel.text=@[@"授权保护",@"访问令牌",@"自定义授权码",@"重新生成令牌",@"敏感读取",@"界面控制",@"脚本执行",@"方法追踪"][indexPath.row];
  if(indexPath.row==0){UISwitch *toggle=[UISwitch new];toggle.on=[FLEXAiFlexMCPServer authRequired];toggle.tag=820;[toggle addTarget:self action:@selector(toggleGroup:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=toggle;cell.selectionStyle=UITableViewCellSelectionStyleNone;}
  else if(indexPath.row<=3){
   if(![FLEXAiFlexMCPServer authRequired])cell.textLabel.textColor=UIColor.secondaryLabelColor;
   if(indexPath.row==1){cell.detailTextLabel.text=@"轻点复制";cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;}
   else if(indexPath.row==2)cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
   else if([FLEXAiFlexMCPServer authRequired])cell.textLabel.textColor=UIColor.systemRedColor;
  }
  else{UISwitch *toggle=[UISwitch new];
   BOOL on=indexPath.row==4?[FLEXAiFlexMCPServer sensitiveEnabled]:indexPath.row==5?[FLEXAiFlexMCPServer controlEnabled]:indexPath.row==6?[FLEXAiFlexMCPServer scriptEnabled]:[FLEXAiFlexMCPServer tracingEnabled];
   toggle.on=on;toggle.tag=821+indexPath.row-4;[toggle addTarget:self action:@selector(toggleGroup:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=toggle;cell.selectionStyle=UITableViewCellSelectionStyleNone;}
 }
 else{
  if(indexPath.row==0){cell.textLabel.text=@"复制 MCP 客户端配置";cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;}
  else{
   cell.textLabel.text=@"工具：status / read / sensitive / control / script / trace";
   cell.textLabel.font=[UIFont systemFontOfSize:12];
   cell.textLabel.numberOfLines=0;cell.textLabel.textColor=UIColor.secondaryLabelColor;
   cell.selectionStyle=UITableViewCellSelectionStyleNone;
  }
 }
 return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath{
 [tableView deselectRowAtIndexPath:indexPath animated:YES];
 if(indexPath.section==0&&indexPath.row==1){
  UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"监听端口" message:@"1024–65535，修改后自动重启服务。" preferredStyle:UIAlertControllerStyleAlert];
  [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.keyboardType=UIKeyboardTypeNumberPad;field.text=[NSString stringWithFormat:@"%lu",(unsigned long)[FLEXAiFlexMCPServer port]];}];
  [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
  [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
   NSUInteger port=[alert.textFields.firstObject.text integerValue];
   if(port<1024||port>65535)return;
   [FLEXAiFlexMCPServer setPort:port];
   if([FLEXAiFlexMCPServer isEnabled]){[[FLEXAiFlexMCPServer shared] stop];[[FLEXAiFlexMCPServer shared] start];}
   [self reloadSoon];
  }]];
  [self presentViewController:alert animated:YES completion:nil];return;
 }
 if(indexPath.section==0&&indexPath.row==2){
  UIPasteboard.generalPasteboard.string=[FLEXAiFlexMCPServer endpoint];
  [self toast:@"已复制访问地址"];return;
 }
 if(indexPath.section==2&&indexPath.row==0){
  NSString *url=[FLEXAiFlexMCPServer endpoint],*json;
  if([FLEXAiFlexMCPServer authRequired])json=[NSString stringWithFormat:@"{\"mcpServers\":{\"aiflex2\":{\"type\":\"http\",\"url\":\"%@\",\"headers\":{\"Authorization\":\"Bearer %@\"}}}}",url,[FLEXAiFlexMCPServer token]];
  else json=[NSString stringWithFormat:@"{\"mcpServers\":{\"aiflex2\":{\"type\":\"http\",\"url\":\"%@\"}}}",url];
  UIPasteboard.generalPasteboard.string=json;
  [self toast:@"已复制 MCP 客户端配置"];return;
 }
 if(indexPath.section==1&&![FLEXAiFlexMCPServer authRequired]&&indexPath.row>=1&&indexPath.row<=3){[self toast:@"当前已关闭授权保护"];return;}
 if(indexPath.section==1&&indexPath.row==1){
  NSString *token=[FLEXAiFlexMCPServer token];UIPasteboard.generalPasteboard.string=token;
  UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"访问令牌" message:token preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];return;
 }
 if(indexPath.section==1&&indexPath.row==2){
  UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"自定义授权码" message:@"8–64 位字母、数字、点、下划线或短横线。" preferredStyle:UIAlertControllerStyleAlert];
  [alert addTextFieldWithConfigurationHandler:^(UITextField *field){
   field.placeholder=@"输入授权码";
   field.autocapitalizationType=UITextAutocapitalizationTypeNone;
   field.autocorrectionType=UITextAutocorrectionTypeNo;
  }];
  [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
  [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
   if(![FLEXAiFlexMCPServer setToken:alert.textFields.firstObject.text]){[self toast:@"授权码格式不正确"];return;}
   if([FLEXAiFlexMCPServer isEnabled]){[[FLEXAiFlexMCPServer shared] stop];[[FLEXAiFlexMCPServer shared] start];}
   [self toast:@"已更新授权码"];
  }]];
  [self presentViewController:alert animated:YES completion:nil];return;
 }
 if(indexPath.section==1&&indexPath.row==3){
  UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"重新生成令牌" message:@"旧令牌立即失效，需要同步修改电脑端 MCP 配置。" preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
  [alert addAction:[UIAlertAction actionWithTitle:@"重新生成" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){
   [FLEXAiFlexMCPServer rotateToken];
   if([FLEXAiFlexMCPServer isEnabled]){[[FLEXAiFlexMCPServer shared] stop];[[FLEXAiFlexMCPServer shared] start];}
   [self toast:@"已生成新令牌"];
  }]];
  [self presentViewController:alert animated:YES completion:nil];return;
 }
}
- (void)toggleService:(UISwitch *)sender{
 [FLEXAiFlexMCPServer setEnabled:sender.on];
 if(sender.on)[[FLEXAiFlexMCPServer shared] start];else [[FLEXAiFlexMCPServer shared] stop];
 [self reloadSoon];
}
- (void)toggleGroup:(UISwitch *)sender{
 if(sender.tag==820){[FLEXAiFlexMCPServer setAuthRequired:sender.on];[self reloadSoon];return;}
 if(sender.tag==821)[FLEXAiFlexMCPServer setSensitiveEnabled:sender.on];
 else if(sender.tag==822)[FLEXAiFlexMCPServer setControlEnabled:sender.on];
 else if(sender.tag==823)[FLEXAiFlexMCPServer setScriptEnabled:sender.on];
 else [FLEXAiFlexMCPServer setTracingEnabled:sender.on];
 [self reloadSoon];
}
- (void)toast:(NSString *)text{
 UIAlertController *alert=[UIAlertController alertControllerWithTitle:text message:nil preferredStyle:UIAlertControllerStyleAlert];
 [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
 [self presentViewController:alert animated:YES completion:nil];
}
@end
