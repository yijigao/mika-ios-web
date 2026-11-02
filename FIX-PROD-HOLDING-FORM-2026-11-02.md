# Mika Web 触摸网页闪退 — 生产版修复记录（持有形态）· FIX-PROD-HOLDING-FORM

- 日期：2026-11-02
- 分支：`fix/app-holding-form`（自 `main` 新开；未合 main）
- 代码提交：`4419fbd`（仅 `MikaWeb/MikaWebApp.swift` 一文件，+33/−15；validate_project.py 全 PASS）

## 1. 定案触发条件（阶梯结论，不重查）

四轮最小化阶梯真机实测（Joey 本人设备，案卷 CRASH-LADDER / -2 / -3 / -4）：

- H2（地基：BrowserView/WebSurface/WebController，根视图自持）稳；H3a（生产 App 级装配：App 直接 @StateObject 逐个持有对象图）崩；
- 第三轮单件阶（持有者形态逐件加回）：A-1＝202611020259、A-2＝202611020307、A-3＝202611020316，2026-11-02 12:28 实测全稳；
- 第四轮：X-1＝202611020431（**生产对象图原样**＋HarnessObjectGraph 持有者形态）实测**稳**；X-2＝202611020437（与 X-1 内容相同、唯一差别为持有形态换回 App 直接三个 @StateObject）实测**崩**（2026-11-02 12:45 崩溃报告在案，签名与历代一致：NSInvalidArgumentException，NSArrayM insert nil，offset 98532）。

**触发条件（定案口径）**：「App struct 里直接以多个 @StateObject 逐个持有对象图」这一形态。X-1 与 X-2 的对象图内容、构造顺序、构造时机逐字等价，唯一变量即持有形态。**具体机制未分离，本记录只写触发条件，不声称根因。**

## 2. 修复内容

把生产版 App 的对象持有形态由「五个 @StateObject 逐个持有」改为「单个持有者对象持有全部对象，App 只以一个 @StateObject 持有该持有者」，形态参照阶梯的 HarnessObjectGraph（@MainActor ObservableObject、App init 内同步构造、App 级保活）。

- 新增 `@MainActor final class AppObjectGraph: ObservableObject`（与 App 同文件 `MikaWeb/MikaWebApp.swift`，未新增源文件、未动工程文件）：以 `let` 持有 web/settings/engine/conversation/diagnostics 五件；其 init 内的构造顺序与 init 副作用与原 App init **逐字等价**：`web → settings → engine（以同一个 web 实例＋settings 构造）→ conversation → diagnostics`，随后 `conversation.bind(to: engine)`、`diagnostics.start()`。
- `MikaWebApp` 改为：`@StateObject private var graph: AppObjectGraph`（全 App 唯一 @StateObject），init 内 `_graph = StateObject(wrappedValue: AppObjectGraph())`；body 把五件以 `graph.web` 等经**原有参数通道**下传 `ContentView(web:settings:engine:conversation:diagnostics:)`，ContentView 的 @ObservedObject 消费方式、scenePhase→`engine.setForeground` 接线（改经 `graph.engine` 取同一实例）均不变。

### 红线核对（git diff 实查：全仓仅 MikaWebApp.swift 一文件）

- WebSurface/WebController 本体：零改动；
- AgentEngine 业务逻辑：零改动（仅其实例改由持有者构造，init 签名与入参实例关系不变）；
- UI 布局与功能（B 组布局、ContentView 及其子树）：零改动；
- 模型 / Keychain / 网络代码：零改动；
- diff 内无任何业务行为变化：构造时机仍在 App init 内、生命周期仍为 App 级、bind/start 副作用顺序与时机不变；变化仅在存储一层间接（对象由 App 直接存储改为经持有者存储）——该层正是 X-1/X-2 隔离出的唯一变量。

### 与 X-1 形态的对应关系

| 维度 | X-1（202611020431，真机稳） | 本修复（生产） |
|---|---|---|
| 持有形态 | App 以 @StateObject 持有 HarnessObjectGraph 持有者 | App 以 @StateObject 持有 AppObjectGraph 持有者（全 App 唯一 @StateObject） |
| 持有者类 | `@MainActor final class HarnessObjectGraph: ObservableObject`，App init 内同步构造 | `@MainActor final class AppObjectGraph: ObservableObject`，App init 内同步构造 |
| 对象图 | web＋settings＋engine（engine 与视图共用同一 web 实例） | web＋settings＋engine＋conversation＋diagnostics（生产全图；engine 与视图共用同一 web 实例） |
| 已知形态差别（登记） | 阶梯里 DiagnosticStore 由 App 直接 @StateObject 持有（各阶恒定、非隔离变量）；阶梯无 AgentConversationStore | 生产把 diagnostics 与 conversation 一并移入持有者——超出阶梯隔离范围的「同一方向」推广：App 内不再有任何逐个直接持有的对象图成员（定案触发条件针对的正是「多个 @StateObject 逐个持有」形态本身） |

## 附注：修复前生产版 App 全部 @StateObject 枚举

来源：`main` 分支 `MikaWeb/MikaWebApp.swift`（工程内唯一 @main App struct，git grep 实查）。修复前共 **5 个**，全部已移入持有者：

| # | 行 | 声明 | 移入持有者后 |
|---|---|---|---|
| 1 | L5 | `@StateObject private var web: WebController` | `AppObjectGraph.web`（let） |
| 2 | L6 | `@StateObject private var settings: SettingsStore` | `AppObjectGraph.settings`（let） |
| 3 | L7 | `@StateObject private var engine: AgentEngine` | `AppObjectGraph.engine`（let；仍以同一个 web 实例构造） |
| 4 | L8 | `@StateObject private var conversation: AgentConversationStore` | `AppObjectGraph.conversation`（let；bind(to: engine) 仍在构造后执行） |
| 5 | L9 | `@StateObject private var diagnostics: DiagnosticStore` | `AppObjectGraph.diagnostics`（let；start() 仍在构造后执行） |

无对象因生命周期与 Scene 阶段强绑定而无法移入：scenePhase 为 @Environment（保留在 App struct 上，未动），setForeground 接线保留在 body 的 onChange 内、改经 `graph.engine` 取同一实例。

## 3. 构建与 ASC 回读证据

- **生产修复构建＝202611020450**（0.1.0），build id `791d0160-70cd-4b90-a77e-e902ba27ce9b`，uploadedDate 2026-11-02T04:52:22Z；构建号由 fastlane 现场生成（时间戳 %Y%m%d%H%M），不落仓。
- CI Run **41390473187** success（Debug 模拟器构建，仅作预检）→ Release Run **41390586904** success（日志实查：increment_build_number 04:50:01Z、ipa 导出签名 04:50:36Z、"Successfully uploaded the new binary to App Store Connect" 04:51:40Z）。
- ASC API 逐项回读：processingState=**VALID**、expired=**false**、usesNonExemptEncryption 已 PATCH=false（PATCH HTTP 200 后回读确认 false）；Internal 组（6a722377-d7f3-4c76-876f-4c35e193e0e4）挂载 POST **204**，组内回读新构建居首。
- 待 Joey 真机验收：在 TestFlight 更新到 **202611020450** 后做产品级复测（起始页点网页多次＋滚动、跑一个低风险任务、对话内作答续跑、确认卡片、模型名防呆）。验收口径沿既往：「在已测试条件下恢复稳定」——触发条件已按阶梯定案移除（持有形态），具体机制未分离，不声称根因已确认。
- 本分支未合 main：合并与否待真机验收通过后由主聊/Joey 决定。
