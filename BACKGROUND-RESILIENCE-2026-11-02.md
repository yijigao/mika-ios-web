# 后台韧性＋瞬时错误恢复（BACKGROUND-RESILIENCE，2026-11-02）

## 交付事实

- 构建 **202611020838**（0.1.0），build id `b398f2e9-0878-42bf-a65a-3c4a51a0e933`：分支 `fix/background-resilience`（自 `fix/intervention-chat-prompt` 新开，未合 main/其他分支），代码提交 `532fca6`。
- CI Run **41414297597** success：日志实查 46 条 SwiftCompile（分组编译行含 AgentEngine／WebController／AgentConversationStore／SettingsStore 等改动文件）＋`** BUILD SUCCEEDED **` 1 处，结论双核对。validate_project.py 全 PASS。
- Release Run **41414532212** success：fastlane 构建号 202611020838（UTC 08:38），08:41:50 UTC 日志 `Successfully uploaded the new binary to App Store Connect`。
- ASC 回读：processingState=**VALID**、expired=**false**、usesNonExemptEncryption 由 null PATCH→**false** 回读确认；Internal 组（6a722377-d7f3-4c76-876f-4c35e193e0e4）挂载 POST **204**，组内回读居首 [202611020838, 202611020808, 202611020708]。
- **过程注记（回读口径）**：Release 完成后第一次 ASC 回读时新构建尚未进 ASC 索引（上传后约 1 分钟），脚本误命中旧构建 0808 并对其完成了挂组/居首核对（无害的重复挂载）；随即由 Release 日志锁定真构建号 0838、待其索引出现后（00:42:57-08:00）重新完成全部回读，即上列结果。教训：Release 后回读必须先以构建号定目标再核状态，列表「最新」在索引延迟期不可信。

## 背景

Joey 在 0808 真机上报两问题（2026-11-02 16:25）：
1. 「1离开前台就不工作了（切后台/锁屏后任务停/死）。这不行」
2. 一步 JS 异常就整单停下等点「继续」：截图实证，知乎任务第 1 步 navigate 后裸报「A JavaScript exception occurred」，会话直接失败停驻。

0808 的现状（代码实查，与推断一致并补正一处）：`ContentView` 以 scenePhase 驱动 `engine.setForeground(phase == .active)`；`setForeground(false)` **无条件 stop()**——代际作废 worker、清执行绑定、防锁屏释放、status 回 idle。JS 评估的等待用「100ms × 300 次」计数轮询（跨挂起必废），引擎主循环与模型调用路径**没有任何错误分类**，任一步抛错即 catch 终局「失败：<原文>」。另 16:31 Joey 贴出系统终止报告，机制实锤见下文专节。

## 问题 1：四层修复与各自保证边界

### 层 1（根基，必做）：挂起不死、回前台自动续跑
实现（AgentEngine）：
- 核心原语 `checkpoint(_:)` 取代原 `check(_:)`：代际不符→任务取消（语义不变）；不在前台→以 300ms 间隔**驻停等待**（不判失败、不烧步数），回前台自动醒来续跑，后台等待期间的连续失败计数清零。
- `setForeground(false)` 不再 stop()：仅置驻停标记＋落盘＋宽限＋持续处理提交（见专节的收敛口径）；`setForeground(true)` 只收宽限与复位标记，**不点火**——驻停中的循环自行醒来，用户不需要点「继续」。
- wait 等待改**绝对截止时刻**（`waitDeadline`）：execute 的等待改为「算出截止时刻→分片睡到点」，分片以便代际取消及时生效；进程被挂起期间墙钟照走，解冻后已过点直接返回，等待既不被拉长也不被重算。换算放在 WebController.execute（一处收口，wait 之外的动作结构不变）。
- 会话快照持续落盘（`SessionSnapshot`，UserDefaults `agentSessionSnapshot.v1`）：goal／步数上限／steps／问答记录随步落盘，等待确认连同待执行动作、等待手输、暂停等状态一并记；终结/停止时清除。App 被系统杀掉或强退后重开：24 小时内的非终结快照恢复为**暂停态**（对话里追加「上次任务在 App 退出时中断，点继续可接着跑」），进度不丢。
- 保证：切后台再回来（进程未死）→ **零点击自动续跑**，步数、问答历史、等待状态不丢；等待按墙钟到期。
- 不保证：进程已被系统杀掉（内存压力/jetsam 等）后重开**不会自动开跑**（无用户在场自动驱动浏览器不合适），恢复为暂停态、需点一次「继续」——这是刻意的边界，不是缺陷。

### 层 2（必做）：后台宽限
进入后台时 `beginBackgroundTask`（名 `MikaWebAgentStep`）申请系统宽限，供在途一步把当前的模型调用/JS 执行走完并落盘；expiration handler 只做「落盘＋释放宽限」两件小事。宽限 ID 在回前台/会话终结时成对释放。
- 保证：在途一步获得系统给的宽限窗口（通常约 30 秒，系统决定）收尾，不会因切后台瞬间被拦腰打断而留下半执行状态。
- 不保证：宽限长度由系统决定，超长的一步仍可能在宽限耗尽时被挂起——此时层 1 的驻停/恢复接住，不判失败。

### 层 3（评估后接入）：iOS 26 BGContinuedProcessingTask
评估结论：**适用**。该 API 正为「用户发起、有限时长、需要用户可见进度」的任务设计（WWDC25 引入）：`BGContinuedProcessingTaskRequest(identifier:title:subtitle:)`，strategy `.queue`（默认）/`.fail`；identifier 须在 Info.plist `BGTaskSchedulerPermittedIdentifiers` 声明；**iOS 26 对此类型开了动态注册例外**——handler 不必在启动完成前注册，可在用户发起任务时注册，本 App 的 `@main` 在 MikaWebApp.swift（红线文件、零改动），既有启动路径无法也不需要动。参考：Apple 文档与 WWDC25 解读、社区 BGTaskScheduler 资料（含一例未签名侧载 App「提交后从未被唤起」的报告——口径：系统是否授予属系统裁量，本 App 为正规签名分发，层 3 只作尽力而为，**层 1+2+4 才是保证底线**）。
接入：Info.plist 声明通配 `com.jigaoyi.mikaweb.agent.*`；会话活跃期以唯一 identifier 提交（标题「Mika Web 正在执行任务」、subtitle 为目标前 40 字），进度按 已记步数/步数上限 上报；任务被系统收走只收口系统侧句柄、**不判会话失败**（层 1 接管）；会话终结时 setTaskCompleted 恰好一次。
- 保证：提交成功时，系统在灵动岛/锁屏显示任务进度，并**可能**在后台继续给执行时间，让任务有机会在后台直接跑完。
- 不保证：系统给不给、给多久是系统裁量（设备状态、电量、用户习惯都影响）；被拒绝/被回收都只记诊断，不影响其余三层。

### 层 4（必做）：任务期防锁屏
会话活跃期 `UIApplication.shared.isIdleTimerDisabled = true`（launch 时置位，终结/停止/恢复快照的非活跃态时复位）；设置页「任务」区新增开关「任务运行时保持屏幕常亮」（默认**开**，关掉则全程不干预自动锁屏）。
- 保证：开关开启且会话活跃时屏幕不自动锁，从源头减少「被动进后台」。
- 不保证：用户手动锁屏/切 App 照常进后台——由层 1–3 接住；会话一结束立即恢复系统自动锁屏，不长期占着。

**验收底线（如实口径）**：切后台长时间后系统仍可能暂停进程（层 3 顺利时甚至不暂停），但**回前台必自动续跑、不丢进度**这一条是本构建的验收线；进程被杀的极端情形降级为「重开 App 点一次继续」，进度同样不丢。

## 专节：0808 的 0x8BADF00D scene-update 看门狗终止（Joey 16:31 报告）

### 定性
- 构建 202611020808，2026-11-02 16:30:33，知乎任务运行中被切到后台（ProcessVisibility: Background）后，系统 scene-update 事务 10.00 秒墙钟 allowance 耗尽，进程被 SIGKILL（exceptionType 10，code 0x8BADF00D，terminationReason 原文 `scene-update watchdog transgression`）。
- 关键数字：Elapsed total CPU 49.5s 中 **App 本体仅 0.150s**——主线不是算力耗尽，是**在场景更新事务里等（堵）**，没能在时限内收尾。归因线程链：runloop → UIKitCore 场景更新 → FrontBoardServices → GraphicsServices → SwiftUI → 唯一 App 帧 MikaWeb offsetIntoBinaryTextSegment **131656**（binary UUID 345CC20D-646D-3CFE-A859-55DBD615B660）。
- 与问题 1 的关系：这是「离开前台就死」的最硬形态——不是挂起后不续跑，而是进程在切后台的瞬间被系统直接终止，状态全丢。

### 符号化：未对齐（按口径如实记录）
- 0808 的原始 dSYM **不可得**：Release 工作流不上传任何 artifact，GitHub Actions runner 为临时环境、产物已随之销毁；ASC 公开 API 不提供 dSYM 下载。
- 替代尝试：以 0808 的同一代码提交（84ba57f）在同型号 runner（macos-26）上重建设备 Release 版并符号化（符号化 run 41414052883，临时分支 tmp/symbolicate-0808，已删）。重建二进制 UUID = `2F56C9CF-18B6-3F82-8F48-8ED934181275`，与报告的 `345CC20D-…` **不一致**——重建非位级一致（构建方式/签名差异），按「未对齐」口径：以下结果**仅作参考、不作定论**。
- 参考结果：重建版中 offset 131656 经 atos（binary 与 dSYM 双路）落在 **`main`（MikaWebApp.swift，SwiftUI App 入口主函数）**。若两版布局在该处一致，则归因线程捕获时**没有停在任何 App 业务代码帧上**——与 App CPU 仅 0.15s 互相印证：主线是等待而非计算，卡点在 SwiftUI/图形场景更新事务内部（链含 GraphicsServices，疑与 WKWebView 层级在切后台时的渲染事务未收尾有关）。0808 在切后台瞬间还有两个 App 侧触发源会给场景更新事务加活：engine.stop() 改 status/sessionActive → 坞布局所有权迁移（settle→WKWebView resize）＋全树 SwiftUI 刷新。**以上为推断，非符号化定论。**
- 后续建议（未做，不在本单范围）：给 release.yml 加一步 dSYM artifact 上传，今后再遇终止报告可权威符号化。

### 处置：进后台立即收敛主线工作（本构建已落地，代码层自证）
新构建在场景更新窗口内的同步路径只剩极小收尾，逐项可查：
1. `setForeground(false)` 同步体＝置 `agentWorkSuspended` 标记＋一次小 JSON 快照落盘＋`beginBackgroundTask` 申请，四行级动作即返回；**不改 status/sessionActive**（不触发全树刷新、坞布局迁移与 WKWebView resize）；BGContinuedProcessingTask 的注册/提交涉及系统 XPC，改为异步 Task 补交、不占场景事务同步路径。
2. 网页侧轮询停手：`agentWorkSuspended` 置位后，DOM 静默轮询（waitForStability）入口与每轮探针前直接返回；ready() 的加载等待立即抛加载类瞬时错误退出（最长 30 秒的陪等不横跨场景切换）。
3. 引擎事件攒批：App 离开 active 后，对话条目在 AgentConversationStore 层先攒批（引擎在途一步的收尾记录先存 batchedEntries），回前台一次性刷入列表——逐条 append 的列表 diff 与滚动跟随不在后台期发生；引擎循环本体在 checkpoint 驻停，后台期不再产生新的状态发布。
4. beginBackgroundTask 的 expiration 收尾仅「落盘＋释放」，无其他动作。
- 验收口径追加：任务运行中切后台，App **不得再因 scene-update 看门狗被终止**——代码层自证如上（后台路径无同步等待、无大批量状态发布、无视图层级迁移）；真机复测若仍出现终止报告，以 0838 的新报告为准再定位（届时层 1 的快照恢复把损失兜底为「重开点一次继续」）。
- 残余风险如实记：WKWebView 自身的渲染/图层事务在切后台时的行为属系统侧，App 代码不能完全控制；本构建能做的是把 App 侧触发源清零。

## 问题 2：错误分类与恢复

截图实证的死法：第 1 步 navigate 后，状态抽取的 evaluateJavaScript 抛 WKErrorDomain code 4（JavaScriptExceptionOccurred），旧引擎无分类、直接终局。本构建在 AgentEngine 建分类表（`TransientKind`），主循环就地恢复：

| 类别 | 触发（代码判定） | 恢复动作 |
|---|---|---|
| 网页脚本异常 javaScript | WKErrorDomain code 4（JavaScriptExceptionOccurred）；MikaError「无法抽取页面状态／页面状态解析失败」 | 退避后整轮重试（先重新抽取页面状态，含既有 DOM 静默轮询）；目标动作类异常走 runTargeted 既有「按稳定描述重找＋单步 ≤2 次」预算 |
| 网页进程终止 webContentProcess | WKErrorDomain code 3（WebContentProcessTerminated） | 同上；且连败第 2 次起先重载执行页（内容进程已死时重载是唯一出路） |
| 网页加载问题 pageLoad | MikaError「网页加载超时／网页加载失败」前缀 | 同上；连败第 2 次起先重载执行页再重试 |
| 模型网络 modelNetwork | MikaError「无法连接模型服务」（含超时/无网络/5xx 的既有收口） | 退避后整轮重试（模型还没出动作，整轮重来最干净） |
| 其余一切 | 业务校验、安全策略、历史过长等 | 不是瞬时错误：照旧立即按原口径处理（拦截类文案原样） |

门槛数值（定版）：
- **连续 3 次**瞬时失败才判会话失败（失败文案为人话并带最后一次的人话原因，不再裸贴英文原文）；任一整轮走通即清零计数。
- 退避 600ms × 当前连败数；后台期间发生的瞬时失败先驻停、回前台再重试（不算进「恢复后又失败」的观感，计数不清零）。
- 页面重载时机：pageLoad/webContentProcess 类连败到第 2 次，该轮重试前先 `reload` 执行页一次。
- 对话呈现：每次自动恢复在步流里记一条人话「尝试」步（如「页面脚本出错，已自动重试（第 1 次）」）；裸英文/系统错误原文只写 DiagnosticStore（事件 `agent_transient_error`），标题与状态行只用 statusText 的人话口径。
- 「继续」按钮回归本分：只出现在真正的停驻——步数上限、连续失败终局、等待用户（确认/手输/暂停，含重开恢复的暂停态）；瞬时错误不再停在这里。

安全边界不被重试绕过（逐项自证）：
- SafetyPolicy.swift **零改动**；Swift 侧 safeAction 复检逻辑一字未动；拦截类错误不在瞬时分类内（fail-closed 不变）。
- 等待确认/等待手输的状态机语义一字未动（waitingInput 三路、confirm/reject 守卫、consumeConfirm 全保留）。
- **已确认动作执行期抛错绝不自动重做**：confirm 后走独立的 runConfirmed 路径——瞬时错误时恢复 pending 并把状态推回 waitingConfirm（对话记「刚才网络/页面出了点问题，动作没有重做——请核对页面后再次确认执行」），由用户重新确认；非瞬时错误照旧上抛终局（含「确认期间页面目标已变化」这类安全失败，永不重试）。

## 红线自查

- MikaWebApp.swift（AppObjectGraph 单持有者形态）：`git diff` 对基线 62646a5 **无该文件**，零改动；BGTaskScheduler 的 handler 注册走 iOS 26 动态注册（层 3 注记），不需要动 @main。
- SafetyPolicy.swift：零改动。Keychain：未碰。无新第三方依赖（BackgroundTasks/UIKit 为系统框架）。
- 0808 形态不回归：BrowserDockView.swift、ContentView.swift、AgentChatView.swift 本单**零改动**——expand() 仍只剩用户路径、输入栏最上层层级、键盘收起逻辑、介入只在对话提示，全部原样（git diff 文件清单自证：仅 AgentEngine／AgentConversationStore／WebController／SettingsStore／Info.plist 五个文件）。
- 变更文件：AgentEngine.swift（主体）、WebController.swift（wait 绝对截止、执行页重载、驻停标记与轮询收敛）、AgentConversationStore.swift（后台攒批）、SettingsStore.swift（防锁屏开关＋设置页说明更新）、Info.plist（BGTaskSchedulerPermittedIdentifiers）。
- 分支未合并；临时符号化分支 tmp/symbolicate-0808 已删除（run 41414052883 记录保留）。

## 给 Joey 的复测清单（0838）

1. **切后台续跑**：任务跑一半时切去别的 App，两分钟后回来——任务应已自动续跑（或经层 3 在后台继续推进），步数与进度不丢，不需要点「继续」。
2. **切后台不被杀**：同上场景反复几次，App 不应出现「闪退/重开后回到初始态」——即不得再被 scene-update 看门狗终止；若再被终止，请把新的终止报告贴回主聊。
3. **锁屏同理**：任务中途锁屏，等待一两分钟解锁回来，任务应自动续跑；且任务运行中屏幕应保持常亮（设置开关默认开时不应自动锁屏）；任务结束后自动锁屏恢复正常。
4. **弱网导航不死**：在弱网或页面还没加载完时发起一个导航类任务，单次「页面脚本出错」只会出现自动重试提示、任务继续；不应再出现一步 JS 异常整单失败停驻等点继续。
5. **确认门不被绕过**：触发一个需要确认的动作，在确认后网络抖动/页面异常时，动作**不会**被自动重做，应回到等待确认让你重新决定。
6. **强退恢复**：任务中途强退 App 再打开，应看到「上次任务在 App 退出时中断，点继续可接着跑」，点继续后从原进度接跑。
7. **开关回归**：设置里关掉「任务运行时保持屏幕常亮」后，任务期恢复系统自动锁屏；再打开恢复常亮行为。
8. 顺带回归：0808 的介入对话提示、小窗不自动展开、键盘收起、输入栏最上层均不应变化。
