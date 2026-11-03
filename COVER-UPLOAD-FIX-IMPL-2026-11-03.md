# COVER-UPLOAD-FIX 实施案卷（2026-11-03）

## 0. 结论

构建 **202611030625**（0.1.0），分支 `feat/cover-upload-fix`（基线＝feat/ladder-fix tip `47ead2d`，含构建 202611030336，未合 main）。功能提交 `fe89cd9`＋回调 Swift 名修正 `1194766`＋嵌套类型限定修正 `5d24e8f`。

0336 真机现场的两条卡点全部对治：

- **找不到图**：generate_cover 生成后同步写入系统相册（A），文件名改为 ASCII 安全短名（B），附件中心与选文件卡都把本任务生成的文件置顶并给出确切找图路径（B/C）。
- **传不上**：调研证明 iOS 18.4+ 有公开合规路径（见 §1），已实现 D——upload 经 SP-01 判定（任务生成豁免／确认卡消费）后，由 App 通过 `WKUIDelegate` 文件面板公开回调直接向页面供文件，全程步流可见、以页面双回读（控件持有＋新增图像）为成功标准；iOS 18.4 以下或回调未触发时自动退回既有手动路径，且待供文件保持武装，用户在页面上真点上传按钮时同一回调自动带上。

ASC 状态：**待阿仁亲验**（本文不记 VALID、未挂组）。

## 1. 调研结论（先找轮子口径，单列）

问题：iOS 公开 API 下，WKWebView 的 `<input type=file>` 是否存在 UIDelegate 拦截点，能由 App 在用户确认后直接向页面提供指定文件（免手选）？

**结论：有，iOS 18.4 起公开。** 本仓旧注释「iOS 上 WKWebView 没有 runOpenPanel 回调」是 18.4 之前的旧事实，本单已在代码注释中修正。

证据链：

1. **WebKit 官方源码主线** `Source/WebKit/UIProcess/API/Cocoa/WKUIDelegate.h`：方法 `webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:` 标注 `WK_API_AVAILABLE(macos(10.12), ios(18.4), visionos(2.4))`；同文件头注释原文大意：iOS 上若不实现该方法，「行为与 Safari 处理文件上传相同（呈现模态文件选择器）」，实现后由宿主调用 completionHandler 交回所选文件 URL（交 nil＝取消）。`WKOpenPanelParameters` 在 iOS 上只暴露 `allowsMultipleSelection`／`allowsDirectories` 两个属性（无 accept 文件类型过滤）。
2. **Chromium iOS 源码**（第三方独立实现佐证）`ios/chrome/browser/web/model/web_state/ui/crw_wk_ui_handler.mm`：同一回调以 `@available(iOS 18.4, *)` 门控、注释「only exists on 18.4+」，其实现自弹 PHPicker/UIPicker 供用户选——与本单回退选择器的形态一致。
3. 本仓部署目标 iOS 17.0、CI/Release 为 Xcode 26 SDK（macos-26）：该回调编译可见（CI 实证：首次误写 ObjC 名 `runOpenPanelWithParameters` 被编译器纠正为 Swift 导入名 `runOpenPanelWith`，修正后编译通过——侧面证明 API 在当前 SDK 中真实存在）。

已考虑并否决的路线：

- **JS 构造 File/DataTransfer 塞进 input.files**：脚本伪造文件、事件不可信，正是「可信点按」定案（公开 API 下造不出可信事件）否决的同一类把戏；且页面若校验文件来源会翻车。不做。
- **私有 API**：红线，不碰。
- 18.4 以下无公开回调：保持系统选择器手动路径（A–C 保证找得到图），不假装能自动供文件。

## 2. 实现

### A. 生成文件同步存入系统相册（CoverGenerator／AttachmentStore／Info.plist）

- `CoverGenerator.generateAndSaveToPhotos`（引擎 generate_cover 新落点）：渲染＋附件登记与旧路径一致，其后把 PNG 数据写入系统相册。
- `PhotoLibrarySaver`：只申请 `addOnly` 权限（只添加、不读用户相册），`PHAssetCreationRequest` 直接挂数据写入；`Info.plist` 新增 `NSPhotoLibraryAddUsageDescription`（明说只添加不读取）。
- 结局三态 `PhotoSaveOutcome`（saved／denied／failed(原因)），步流文案由其纯函数 `stepDescription(fileName:)` 生成：saved 才说「封面已生成并存入系统相册（相册『最近项目』里最新的一张就是它，文件名 X）」；denied/failed 明说没存进去＋原因＋「它在本会话附件里」，不让用户去相册空找。
- 写入成功给附件记录打 `savedToPhotos` 标记（`AttachmentRecord` 新增可选字段，旧索引 JSON 解码兼容；`AttachmentStore.markSavedToPhotos` 落盘），附件中心详情行与注入段据此显示「已存入系统相册」。
- 相册写入是追加动作：失败不影响附件本身可用，upload_file 照常可引用。

### B. 命名规整＋置顶（CoverGenerator／AttachmentStore／AttachmentsView）

- `GeneratedFileName.coverFileName(title:)`：小写 ASCII 字母/数字保留，其余字符（空白/标点/全角/中文）整段折成单个连字符，slug 上限 24 字符；slug 为空（纯中文标题）退到 `cover-<yyyyMMdd-HHmmss>.png` 时间戳名。0336 现场那种「封面--别让AI替你瞎编缩报；用这套三步法.png」式文件名不再产生（标题语义只活在图面文字与步流里，附件身份靠稳定 ID）。
- `AttachmentStore.displayOrdered`：本任务生成置顶、组内新在前；附件中心列表与模型注入段共用同一排序。
- 附件中心给本任务生成的行加「本任务生成」徽标。

### C. upload_file 介入文案（AgentEngine／AgentChatView）

- `AgentEngine.uploadPickGuidance(upload:supplyArmed:)` 纯函数统一拼指引：图片已存相册→「打开照片选择里的『最近项目』，最新的一张就是它（文件名 X）」；通用→「在本 App 的附件中心里选置顶、标着『本任务生成』的那份（文件名 X）」；待供仍武装→加「直接在网页上点一次上传按钮——文件已由 App 备好，会自动带上」。
- 选文件卡正文改用该指引（不再只写「在系统选择器里选要上传的文件（目标：…）」）；确认卡文案同步修正（不再写死「由你在系统选择器里选定」，改为「系统支持自动供文件时由 App 直接交给页面」口径）。
- 快照恢复出的选文件等待同样带指引；恢复时按附件记录回填 isImage/savedToPhotos 并重新武装待供文件。

### D. 确认后自动供文件（WebController／AgentEngine，iOS 18.4+）

- `WebController` 实现 `WKUIDelegate.webView(_:runOpenPanelWith:initiatedByFrame:completionHandler:)`（`@available(iOS 18.4, *)`）：
  - 执行页有武装好的待供文件 → 直接把文件 URL 交给页面，不弹任何选择器，消费即作废（一次性）。
  - 其余情况 → `OpenPanelFallback` 弹标准选择面（动作表：照片图库 PHPicker／文件 UIDocumentPicker `asCopy`／取消），把「用户自己选」补回——宿主实现回调后 WebKit 不再自弹系统选择器，这条回退保证用户手动点页面上传按钮的既有路径不回退。图库条目先拷进 App 临时目录再交 URL（选择器临时 URL 只在回调期内有效）。已知缺失：WebKit 自带面板的「拍照」入口无法等价复刻（agent 场景用不到，如实记此）。
- 武装纪律：`armUploadSupply` 只在 `beginUploadPickStage` 内、附件已解析且 **SP-01 已过**（任务生成豁免，或确认卡已在 `confirmPendingUpload` 消费凭据后）才执行——SafetyPolicy 与 `uploadDecision` 零改动、零绕过；绑定执行页标签，非执行页的面板请求消费不到。
- 触发与收口：武装后照旧合成触发控件，留 1200ms 窗口等回调消费；命中→步流记「App 已直接供文件」并走与手动选文件共用的 `verifyPickedUpload` 双回读（控件持有＋页面新增图像，双过才写里程碑，单过记 unknown——VERIFY-1 口径不变），任务不停等待直接续跑（runUpload 新增 `.autoSupplied` 结局）；未命中（合成 click 未被认作可拉起面板的手势）→步流如实记「自动供文件未触发」，待供文件**保持武装**转手动等待，用户在页面真点上传按钮时同一回调供文件；finish/cancel/discard 时一律 `disarmUploadSupply` 防误供。
- iOS 18.4 以下：`uploadSupplySupported=false`，arm 恒失败，整条 D 路径自动不存在，走 A–C 手动路径。

## 3. 自检二十二

引擎纯逻辑（`verifyCoverUploadFix`）：命名四例（混合标题 slug、全角标点剔除且全 ASCII、纯中文时间戳回退、长度上限）、相册三态文案口径、展示排序置顶、选文件指引三态（已存相册给相册路线／未存不给／武装加自动带上一句）、环境门（不支持时 arm 恒 false 不留武装态）。

回路（`WebController.verifyUploadPanelSupply`，引擎转发）：本地合成页 `test-upload` 上备临时文件→武装→引擎同款合成触发→回读页面持有。判定分开记：命中记回路成立；武装成功但回调未被合成触发拉起记「未触发」（环境结论——真机生产路径以用户真点上传按钮为准）；系统 <18.4 记环境结论。相册真实写入（权限弹窗与落盘）不进自检，归 Tier B。

Tier A 未在本机运行（无 Swift 工具链）；自检二十二的实际结论以真机运行结果为准，不得视为已验。

## 4. 发版链证据

- validate_project.py：全 PASS（31 Swift 源恰好引用一次、Info.plist 与资源集通过）。
- CI：首跑 41589121305 为 tee 假绿（run 结论 success、日志实为回调名错误 `error:`、BUILD SUCCEEDED ×0），日志双核对识破；修正提交 `1194766` 后二跑 41589273725 又暴露嵌套类型未限定（`GeneratedFileName` 声明位于 `enum CoverGenerator` 内、引擎侧引用需限定），修正 `5d24e8f`；三跑 **41589504945** 双核对通过（70 条 SwiftCompile、BUILD SUCCEEDED ×1、唯一 error: 为既有 AppIntents 训练噪声）。
- Release Run **41589717416** success（agvtool 置号 202611030625、Archive Succeeded、Successfully uploaded、dSYM artifact dsym-41589717416 5,488,322 字节实存未过期）。ASC 状态：**待阿仁亲验**。

## 5. 红线复核

- SafetyPolicy 零改动：`git diff 47ead2d..HEAD -- MikaWeb/SafetyPolicy.swift` 实查 0 行；D 的供文件只发生在 SP-01 判定之后（豁免或确认消费），确认卡语义与一次性凭据规则不变。
- AppObjectGraph 持有形态零改动：`git diff 47ead2d..HEAD -- MikaWeb/MikaWebApp.swift` 实查 0 行。
- 无新依赖：Photos／PhotosUI／UniformTypeIdentifiers 均为系统框架。
- 文案不写「并行」：新增步流/卡片/自检文案已自查无此表述（供文件与任务续跑为先后关系）。
- 未合 main；父级 SPEC 文件未动未提交。

## 6. 未证项与 Tier B 真机复测清单（Joey）

未证（不得视为已验）：

1. 自检二十二 Tier A 未真机运行（纯逻辑＋test-upload 回路）。
2. 合成 click 在真机上是否拉起文件面板回调——自检回路以实况为准；未拉起时 D 的真机路径＝用户真点页面上传按钮供文件，同样待真机证。
3. 相册写入真机全程（首次权限弹窗、落盘、「最近项目」第一张命中、文件名对号）未验。
4. 回退选择器（OpenPanelFallback）在真机上的呈现与图库/文件两路可用性未验；公众号编辑器真实文件控件对回调供文件的接受度（change 事件是否触发其上传逻辑）未验——双回读就是为此设的验收门，回读不过即如实 unknown，不冒充成功。

Tier B 复测（按序）：

1. 关于页运行**自检二十二**，逐条留结论（回路行如实记成立/未触发/环境结论）。
2. 新任务让 agent 写短文并 generate_cover：步流应出现「已生成并存入系统相册」＋ ASCII 文件名；打开系统相册「最近项目」确认最新一张就是该封面、文件名一致。
3. upload_file 设封面（iOS 18.4+ 设备）：期望 App 直接供文件、步流出现「App 已直接供文件」＋双回读结论；若出现「自动供文件未触发」，在页面上真点一次上传/封面按钮，期望文件自动带上（不弹选择器或选择器里无需翻找）。
4. 手动兜底：在选文件卡点「打开浏览器查看」自己选图——相册路线选「最近项目」第一张，或附件中心置顶「本任务生成」项；回读核验照常。
5. 拒权路径（可选）：在系统设置里关掉本 App 的照片「添加」权限后重新生成封面，步流应如实报「没有存入系统相册」且附件路径仍可用。
