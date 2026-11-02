# Mika Web 触摸网页闪退最小化阶梯·第三轮 — CRASH-LADDER-3

- 日期：2026-11-02（设计＋构建交付，待主聊转交 Joey 按阶真机测）
- 触发：第二轮拆半结果——H3a（202611020217，仅 A 组）与 H3b（202611020221，A+B）经 Joey 2026-11-02 10:45 真机实测**均点击网页闪退**（案卷 CRASH-LADDER-2 §5/§6）。判读：**A 组（App 级对象图）单独即可触发，B 组（1652 布局＋控制台静态形态）与触发无关**（H3b 崩不构成对 B 的指控，A 已足以解释）。本轮自 H2 基线把 A 组拆为单件阶，逐件点名。
- 基线：H2＝构建 202611020054 的源码状态（提交 `2e9a33d`，crash-ladder 分支尖端）——App 入口只装配 DiagnosticStore，WebController 由根视图（HarnessH2View）@StateObject 自持，无 SettingsStore、无 AgentEngine 对象存在。
- 代码：分支 `crash-ladder-2`（续第二轮；main 生产分支未动）。实现方式：三阶共用同一套源码，构建间唯一差异是 `Harness.step` 取值（7→8→9）；各阶的 App 装配差异由 `HarnessObjectGraph`（Harness.swift）的 step 分阶构造表承载（该 switch 本身三阶恒定，对象在 App init 内构造）。起始页、WebSurface/WebController/BrowserView 本体、DiagnosticStore＋MetricKit 导出包装（右下角圆钮）三阶恒定，未改。
- 实现注记（存储形态，判读时须知）：对象图由 App init 同步构造的持有者 `HarnessObjectGraph` 保活（App 以 @StateObject 持有该持有者），而非 H3a 当时的「App 直接以 @StateObject 逐个持有对象」。缘由：Optional 形态的 @StateObject 赋值在本工程 Release（archive）编译下报错（`cannot convert value of type 'AgentEngine?' to expected argument type 'AgentEngine'`；同一提交 CI 的 Debug 模拟器构建却通过——A-1 首个 Release Run 41379839097 实证，未上传构建，拟用构建号 202611020250 未被占用）。持有者形态与直接持有在**创建时机（App init 内）与生命周期（App 级）上等价**，差异仅在存储一层间接；若第三轮某阶结果与 H3a 预期矛盾，先考虑这一层差别再谈定位。
- 红线遵守：未改起始页、未改 WebSurface/WebController 本体、未动 main；AgentEngine 在涉及其的阶中只创建、不执行、不发网络（其 init 仅存引用，无副作用，第二轮已源码实查）。

## 1. A 组单件可分性核查（源码实查，先于出阶）

A 组清单（CRASH-LADDER-2 §5.1）：A1 App 级 @StateObject 持有 WebController；A2 SettingsStore 对象创建；A3 AgentEngine 对象创建；A4 对象图向下传递、BrowserView 改消费 App 的 web。

| 件 | 能否独立成阶 | 依据 |
|---|---|---|
| A1 | **能** | WebController `init()` 无参数、自包含（含起始页加载）；A4 是 A1 的必然下传接线（App 持有的 controller 必须经根视图传给 BrowserView 才构成「持有上移」的完整形态），按派工口径并入 A-1 阶，不单独成阶。 |
| A2 | **能** | SettingsStore `init()` 无参数、自包含（只读 UserDefaults/Keychain 现值，第二轮已实查）；可 App 级创建并持有而不被任何视图消费。 |
| A3 | **不能独立** | `AgentEngine.init(web: WebController, settings: SettingsStore)`（AgentEngine.swift:47）构造签名强制要求一个 SettingsStore 实例**和**一个 WebController 实例。A3 的对象不存在无 A2 的形态；且其 web 参数也必须有实例来源。按派工口径改出**最小耦合阶「A2+A3」**（§2 阶 A-3），耦合关系在此登记，不静默扩大：该阶中 settings 按 A2 原样建（App 级 @StateObject 持有）；web 依赖实例**仅**为满足 init 签名而构造——不进 App @StateObject、不下传任何视图、仅由 engine 的 `private let web` strong 引用保活；BrowserView 实际消费的 WebController 仍由根视图自持（同 H2），即 A1/A4 在该阶**缺席**（「App 级持有并下传消费的那个 controller」不存在；存在的只是一个被 engine 私有引用的依赖实例）。判读时注意这一残余差别：A-3 阶若崩而 A-2 稳，触发点在 {A3 本体、engine 对 web 依赖实例的持有、或二者组合}，不能直接写成 A3 单件定罪，下一轮再就此细分。 |

## 2. 三阶构建定义（均以 H2 为 base）

### 阶 A-1（step=7）：只加 A1（＋A4 必然接线）

- App init 构造 WebController 并 @StateObject 持有（A1），经根包装以普通 let 下传（A4），根视图复用 HarnessH3aView——与 HarnessH2View 逐字同布局（BrowserView＋Divider＋120pt 静态占位），唯一差异是 BrowserView 消费的 controller 来源由视图自持改为 App 传入。
- 不建 SettingsStore、不建 AgentEngine（对象图里不存在这两个对象）。
- 与 H2 的语义 diff：恰为 A1＋A4。

### 阶 A-2（step=8）：只加 A2

- App init 构造 SettingsStore 并 @StateObject 持有；不下传任何视图消费、不接业务（无视图观察它，其 @Published 无订阅者）。
- 不建 App 级 WebController/AgentEngine；根视图为 HarnessH2View 逐字（controller 视图自持）。
- 与 H2 的语义 diff：恰为 A2（一个 App 级对象的创建与持有）。

### 阶 A-3（step=9，角标「A-2+3」）：最小耦合阶 A2+A3

- App init 构造 SettingsStore（同 A2）＋AgentEngine（`AgentEngine(web:settings:)`，web 为专供 init 的依赖实例，见 §1），engine @StateObject 持有、只建不执行、不发网络。
- 不做 A1/A4：BrowserView 的 controller 仍由根视图自持（HarnessH2View 逐字）。
- 与 H2 的语义 diff：A2＋A3＋（engine 的 web 依赖实例构造与私有持有，仅此一处签名强制夹带，§1 已登记）。

## 3. 判读预写（只定位到件，不写根因确认）

| 结果 | 定位 | 下一步 |
|---|---|---|
| A-1 崩 | 触发点在 A1（App 级持有 WebController＋下传消费） | 在 A1 内细分：持有/构造时机 vs 下传消费路径 |
| A-1 稳、A-2 崩 | 触发点在 A2（SettingsStore 的创建/持有本身） | 查 SettingsStore init 与其 @Published/生命周期 |
| A-1/A-2 稳、A-3 崩 | 触发点在 {A3、engine 的 web 依赖持有、或耦合组合}（§1 残余差别） | 出细分阶：如 engine 改持根视图 controller 的接线变体、或 web 依赖实例单独成阶 |
| 三阶全稳 | A 组单件均不触发 ⇒ 疑为**件间交互**（如多对象共存时的观察/发布叠加） | 下一轮出组合阶（如 A1+A2、A1+A3 向 H3a 逐件逼近） |
| 任一阶崩法/签名与既往不一致 | 先停，核对该阶崩溃报告再谈定位 | — |

- Joey 测试规程（主聊转交）：按 A-1 → A-2 → A-3 顺序装；每阶打开 App 停留在起始页（不要先输网址跳转），点上方网页 5 次＋滚动；首崩即停，重开 App 点右下角圆钮导出最新崩溃报告发回。右下角角标分别为 A-1 / A-2 / A-2+3，与构建号可互核。

## 4. 构建与 ASC 回读证据

分支 `crash-ladder-2`（续第二轮；main 未动）；validate_project.py 每阶全 PASS。以下三阶均经 ASC API 逐台回读：processingState=**VALID**、expired=false、usesNonExemptEncryption 已 PATCH=false（回读确认）、Internal 组（6a722377-d7f3-4c76-876f-4c35e193e0e4）挂载 POST 204 且组内回读居首。

### 阶 A-1（step=7）— 构建 202611020259

- 代码提交：基座重构 `c3e2d11`（HarnessObjectGraph 持有者＋step=7；含本案卷初版）→ 修复 `b98ec03` → 修复 `20bf19b`（三阶共用基座，A-1 阶的源码差异只在 step 取值，见 §2）。
- **两次未遂 Release（c3e2d11 对应阶＝A-1，失败原因定性）**：
  1. 提交 `c3e2d11` 的 Release Run **41379839097** 失败（beta job 46 秒；GitHub 通知邮件 2026-11-02 10:51 所报即此 run，邮件的 3 条 annotations 均为噪音：Node.js 20 弃用警告＋macOS 容量提示，真正原因在 fastlane 日志）：Release archive 编译错误 `MikaWebApp.swift:52:45: error: cannot convert value of type 'AgentEngine?' to expected argument type 'AgentEngine'`——Optional 形态 @StateObject 的 `StateObject(wrappedValue:)` 赋值解析到非 Optional 期望。**同一提交的 CI Run 41379753052（Debug 模拟器构建）却 success**——CI 不构成 Release 门禁（见末尾流程教训）。
  2. 修复提交 `b98ec03`（改用 HarnessObjectGraph 持有者）的 Release Run **41380202611** 亦失败（beta job 1m4s）：新错 `Harness.swift:69:39: error: call to main actor-isolated initializer 'init()' in a synchronous nonisolated context`——WebController/SettingsStore/AgentEngine 均为 @MainActor 类，其 init 在非隔离的持有者 init 内被调用；Release 的严格并发检查（Complete）下为错误，Debug 的 Minimal 检查下只放行。修复 `20bf19b`：持有者标 `@MainActor`。
- 成功链：CI Run **41380421273** success → Release Run **41380533879** success（fastlane 上传 03:01:57Z 确认）。
- build id `0684782b-8814-4c18-bf9b-1c0720009497`；ASC 回读 VALID、expired=false、合规已 PATCH=false；Internal 组挂载 204，组内回读居首。

### 阶 A-2（step=8）— 构建 202611020307

- 代码提交 `9f90663`（与 A-1 的源码 diff 经 git diff 实查恰为 `Harness.step` 7→8 一行）。
- CI Run **41381189491** success → Release Run **41381285067** success（fastlane 上传 03:10:03Z 确认）。
- build id `63e62a96-bf49-4c33-a692-798921eca95a`；ASC 回读 VALID、expired=false、合规已 PATCH=false；Internal 组挂载 204，组内回读居首。

### 阶 A-3（step=9，角标 A-2+3）— 构建 202611020316

- 代码提交 `ea07eec`（与 A-2 的源码 diff 经 git diff 实查恰为 `Harness.step` 8→9 一行）。
- CI Run **41382027953** success → Release Run **41382133911** success（fastlane 上传 03:19:03Z 确认）。
- build id `53ddbb9d-8a73-4f4d-bf36-6ea749d6d009`；ASC 回读 VALID、expired=false、合规已 PATCH=false；Internal 组挂载 204，组内回读居首。

### 流程教训（记入本轮，避免后轮重蹈）

- **CI（Debug 模拟器构建）不等于 Release 门禁**：本轮两起 Release 编译失败的提交，其 CI 均 success。根因是 Xcode 按配置区分严格并发检查（Debug Minimal / Release Complete），且 archive 与 simulator 构建的检查强度不同。以后「CI 通过」只作编译参考，**交付只认 Release success＋ASC 回读**（本轮三阶均按此口径交付，不以 CI 代替）。
- 构建号由 fastlane 现场生成（UTC 时间戳 %Y%m%d%H%M），不落仓；三阶构建号分别为 202611020259 / 202611020307 / 202611020316（A-1 首版拟用号 202611020250、修复版拟用号 202611020255 均未上传，不占用）。

待主聊转交 Joey：按 §3 规程按 A-1 → A-2 → A-3 顺序装（TestFlight 内按构建号选装：A-1 为 202611020259、A-2 为 202611020307、A-3 为 202611020316；最新构建为 A-3，测 A-1/A-2 时须从「以前的构建」里手动选号），首崩即停并导出崩溃报告。
