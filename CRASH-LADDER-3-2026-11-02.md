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

（随构建交付逐阶补入：提交、CI/Release Run、build id、processingState、Internal 组回读。）
