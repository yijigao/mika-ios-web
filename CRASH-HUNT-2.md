# Mika Web 触摸网页闪退再定位案卷 — CRASH-HUNT-2

- 日期：2026-11-02（只分析，未改代码、未发版）
- 触发：开关版（构建 202611011920）单因素定位被真机结果整体证伪——10 个开关逐个单关全部仍崩（Joey 2026-11-02 03:47），随后 **10 个全部同时关仍崩**（03:49）。全开基线崩（03:40，栈报告 5）、F_FOCUS 单关崩（03:43，栈报告 6）有 MetricKit 佐证，异常签名始终一致（NSInvalidArgumentException，`-[__NSArrayM insertObject:atIndex:]` 插 nil，抛出路径无 App 业务帧、由 UIKitCore 在触摸后的 SwiftUI UpdateCycle 内抛出，见 STACK-EVIDENCE-2026-11-02.md）。
- 方法：DebugSwitches.swift 与全部消费点源码逐行审计；`git diff 3165943..HEAD` 全量复查＋红线文件 1652→1747 逐字核对（不采信交付报告转述）；Astra（effort medium）复核排序与方案，其修正已并入本卷（见 §5）。
- 基线锚点：1652＝`3165943`（不崩）→ 1747＝`d6b873d`（崩）→ 1811＝`aa3a3bb`（崩）→ 1920＝`03daf50`（崩）。

## 0. 结论先行

开关实现没有整树级别的假关：快照机制健全，10 个开关逐项基本为真摘除。但单因素＋全关双重证伪说明：**触发点不在任一开关构造、也不在它们的并集之内**（逻辑边界见 §1.4）。剩余嫌疑面收敛到开关无权摘除的结构残件——WKWebView 与浮层的共存容器结构、根视图图内常驻的 FocusState 存储、以及新父树下 WKWebView 的挂载语境。**下一版定为结构修复版：ContentView 回 1652 流内骨架、浮层与 FocusState 一并彻底摘除、v0.2 数据层功能全保留**（具体改法 §3.3）。不再做任何开关实验，不再让 Joey 逐项试错。

## 1. 开关实现审计

### 1.1 机制层：健全，无整树假关

- `DebugSwitches.launchConfig` 是 `static let` 闭包快照（DebugSwitches.swift:34-64），开关缺省为开（key 不存在→true，:36-38）。首次触碰在 `MikaWebApp.init()` 第一行（MikaWebApp.swift:12），早于任何视图构建；ContentView / AgentChatView 的 `private let debugConfig` 读的是同一快照。全仓不存在「先按全开建树、再按开关重建」的路径。
- 设置页开关用 `@AppStorage` 写同一批 `dbg.*` key，与快照读取同源；每步「本进程实际生效」摘要（`dbg.activeSummary`）由快照写回，Joey 规程要求每步核对。**唯一未独立复核的前提**：全关一跑的摘要行是否确为 10 项全关，系按规程推定（Joey 按规程执行并报回「都崩」）；若日后发现该跑摘要不符，本卷 §3.1 判读需重做。

### 1.2 逐开关裁定

| 开关 | 代码实际动作（出处） | 裁定 |
|---|---|---|
| F_FOCUS | AgentChatView 输入行三路渲染中去掉 `.focused(inputFocused)` 一项（AgentChatView.swift:61-68） | **真摘除连接，留残件**：ContentView 的 `@FocusState` 声明（ContentView.swift:10）与 `.onChange(of: panel.expanded) { inputFocused = false }`（:47）在所有配置下常驻，开关无权摘除 → 残件单列为嫌疑 S-B |
| F_INPUT | 输入行换静态 Text 占位，原生 TextField 不在场（AgentChatView.swift:69-75） | **真摘除**（仅限聊天输入框；BrowserView 地址栏 TextField 仍在，但 1652 已有，非增量） |
| F_SCROLL | 消息区换静态 Text，ScrollViewReader/ScrollView/LazyVStack 整体不在场（AgentChatView.swift:38-59） | **真摘除** |
| F_CHAT | 展开分支换 DebugChatPlaceholder（无按钮无手势的惰性占位）（ContentView.swift:20-21） | **真摘除 AgentChatView，留外壳**：overlay 的 Group＋frame＋`.regularMaterial` 背景＋`.shadow` 仍在（设计上「外壳几何不变」）→ 外壳归入 S-A 讨论 |
| F_PANELSTATE | App init 以 `initiallyExpanded: panelState` 构造 panel（MikaWebApp.swift:19，经 F_PANELSINK 耦合，见下）；冷启动球态时展开分支不挂载、球挂载 | **真摘除（单关时）**：面板子树确不在树；但该配置并非「网页上方无物」——FloatingBallView（Button＋DragGesture，FloatingAgentOverlay.swift:21）在树。且**在组合配置下被 F_PANELSINK 耦合覆盖**（见 1.3） |
| F_OBSERVE | 展开分支换 StaticChatView：零 @ObservedObject、不引用任何 Store、无 FocusState，按钮全 disabled（DebugSwitches.swift:67-104），且在三路分支中优先级最高（ContentView.swift:19） | **真摘除**（外壳残件同 F_CHAT） |
| F_CONVSINK | App init 跳过 `conversation.bind(to:)`（MikaWebApp.swift:21）；AgentConversationStore 内除 bind() 外无任何订阅点、无 init 自订阅（源码全查） | **真摘除** |
| F_PANELSINK | App init 跳过 `panel.bind(to:)`（MikaWebApp.swift:22），且 collapse() 被 lockExpanded 短路（FloatingPanelStore.swift:24） | **真摘除 sink，带两项设计耦合**：expanded 锁定为展开；并覆盖 F_PANELSTATE 的初值（见 1.3） |
| F_DIAG | App init 跳过 `diagnostics.start()`（MikaWebApp.swift:23）；`MXMetricManager.shared.add` 全仓唯一调用点在 DiagnosticStore.start() 内（DiagnosticStore.swift:27），确未执行 | **真摘除**（DiagnosticStore 实例仍被构造并被 ContentView 观察，但注册行为确不存在） |
| F_GEO | BrowserView 的 frame 传 nil 走自然布局（ContentView.swift:16） | **真摘除回写，留残件**：GeometryReader 本体仍是 BrowserView 的父级（1920 形态），开关无权摘除 → 归入 S-A 讨论 |

### 1.3 「全关」一跑到底关了什么（必须披露的口径修正）

MikaWebApp.swift:19 的构造是 `FloatingPanelStore(initiallyExpanded: debugConfig.panelSink ? debugConfig.panelState : true, lockExpanded: !debugConfig.panelSink)`。全关时 panelSink=false，于是 **initiallyExpanded 被强制为 true、lockExpanded=true——全关一跑实际是「锁定展开态＋StaticChatView＋无 sinks＋无 MetricKit＋无 frame 回写」**，不是球态全关。球态＋其余全开的组合由 F_PANELSTATE 单关一跑覆盖（亦崩）；「球态＋其余全关」组合从未测过。本卷 §1.4 的交集论证不依赖该未测组合（每个构造的缺席证据分别来自各自的单关跑次），但任何引用「全关」二字处都应带此限定。

### 1.4 交集论证与其逻辑边界

逐项核对缺席跑次：.focused 连接（F_FOCUS 单关）、聊天 TextField（F_INPUT 单关；F_PANELSTATE 球态跑次中亦不在场）、聊天 ScrollView（F_SCROLL 单关）、AgentChatView 整体（F_CHAT 单关、球态跑次、全关跑次三重缺席）、聊天数据订阅（F_OBSERVE 单关）、展开面板内容与材质外壳（球态跑次缺席）、球与 DragGesture（一切展开态跑次缺席）、conversation sink、panel sink、MetricKit 注册、frame 回写（各自单关＋全关跑次缺席）。**故 10 个开关构造无一是全部崩溃跑次的必要条件。**

逻辑边界（Astra 复核收紧，本卷采纳）：此论证只证明「每个被摘构造各自不是必要条件」，**不证明**病因必为某个新增交集构造——旧代码在新布局条件下被触发、或同一签名多条触发路径，均与现有证据相容。「全关仍崩」严格措辞是「全关不足以止崩」，不是「开关覆盖集的一切参与作用均被证伪」（冗余多路径未被排除，但无任何正证据）。

## 2. 未覆盖面全量复查

### 2.1 已实证排除（逐字核对，非转述）

| 项 | 核对方法与结果 |
|---|---|
| Info.plist | `git diff 3165943..d6b873d` 与 `..HEAD` 均零出现 |
| entitlements | 1652 与 HEAD 树内均无 entitlements 文件 |
| 工程构建设置 | XCBuildConfiguration 段设置项三版本（1652/1747/HEAD）逐项比对，**完全一致**；pbxproj 其余 diff 仅文件引用增删 |
| WebController / PageState / SafetyPolicy / ModelClient / Keychain / SelfTestView / MikaWebIntents | 1652→1747、1652→HEAD 双段 diff 均为零 |
| WebSurface（makeUIView/updateUIView） | 与 1652 逐字一致：makeUIView 返回 `controller.webView`、updateUIView 空操作（BrowserView.swift:3-7） |
| BrowserView 本体 | diff 仅三处按钮 44pt frame＋HStack 间距（见 2.3 末项）；地址栏 TextField、WebSurface 调用点未动 |
| NavigationStack＋toolbar、scenePhase onChange | 1652 已存在且形态相同 |
| 纵向 TextField、ScrollView+LazyVStack 与 WKWebView 同窗共存 | 1652 的 AgentConsoleView 已同时具备且不崩——「存在」本身出局，差异只在挂载形态 |
| AgentEngine 新增项 | submitAnswer / conversationTaskID / waitingInput / executionSerial 仅任务执行路径触及，空闲触摸无执行路径（diff 全查） |
| SettingsStore 改动 | 模型名校验纯函数、maxSteps didSet 归一化、SettingsView chips 与诊断入口——仅设置页与数据层路径，冷启动主树不挂 SettingsView |

### 2.2 WKWebView 挂载父链逐层对比

| 层 | 1652（不崩） | 1747（崩） | 1920（崩） |
|---|---|---|---|
| Scene | WindowGroup → ContentView | 同左 | 同左 |
| 根容器 | NavigationStack | NavigationStack | NavigationStack |
| BrowserView 的父级 | **VStack**（流内，`frame(maxHeight:.infinity)`） | **ZStack**（与浮层兄弟） | **GeometryReader**（显式 frame 回写，全关时 nil 自然布局） |
| 同级/覆盖关系 | Divider＋AgentConsoleView 在流内下方，**永不重叠** | FloatingAgentOverlay 为兄弟层覆盖全屏（内含自己的 GeometryReader、ZStack、.position 定位） | BrowserView 身上挂两层 `.overlay`：底部面板（内容三路切换）、边缘球 |
| 聊天子树位置 | 流内（控制台） | 浮层内，`if expanded` 条件挂载；@FocusState 声明在常驻挂载的 FloatingAgentOverlay 内 | 底部 overlay 内，`if panel.expanded` 条件挂载；@FocusState 声明在 ContentView |
| WKWebView 本体 | WebSurface → controller.webView | 逐字相同 | 逐字相同 |

表述纪律（Astra 收紧）：跨版本成立的交集是「**浮层与 WKWebView 在同一 hosting 层共存的布局方式**」；GeometryReader 的存在是共同差异，但它作为 BrowserView 父级只是 1920 形态，不得外推到 1747；两个 `.overlay` 修饰符同理只是 1811/1920 的具体实现。

### 2.3 未覆盖嫌疑排序

**S-A（第一）：浮层共存容器结构与 WebView 挂载语境。** 全部崩溃配置共享、1652 没有、且从未被任何开关整体摘除：BrowserView 不再处于流内分区，而是与一层由 `FloatingPanelStore.expanded` 驱动的浮层（ZStack 兄弟／overlay）在同一 hosting 层共存；展开态时另有材质背景＋阴影的面板外壳压在网页上方。触发链（假说，未证实）：触摸 WKWebView → 窗口级焦点/手势处理与 SwiftUI UpdateCycle 叠加 → 新容器结构下某条系统装配路径拿到 nil。注意（Astra）：宜称「新容器结构与 WebView 的组合」，不能收窄为「重叠本身致崩」；「锁定展开仍崩」说明 expanded 的**切换动作**不是必要条件，嫌疑在结构而非状态转换。验证法：§3.3 结构修复版（整体摘除该结构后看崩否）。

**S-B（第二，相关性强于机制证据）：根视图图内常驻的 @FocusState 存储＋onChange 写回。** F_FOCUS 未摘的残件；1652 全仓零 FocusState，两个崩溃版本中该存储始终位于根图（1747 在常驻 overlay 结构内、1920 在 ContentView 本体）。机制可信度限定（Astra，本卷采纳）：公开语义只保证 `.focused` 关联后的焦点同步，**没有证据表明裸声明必然向 UIKit 焦点系统注册并参与每次触摸查询**；从未执行的 onChange 闭包不能充当「写回触发」的执行证据。故 S-B 以「未覆盖的共同差异」身份列第二，不以机制成立身份。验证法：结构修复版中一并全摘（声明＋写回＋绑定），不在本轮单独分离。

**S-C（S-A 的候选机制，不独立成案）：新父树下 WKWebView 的 representable 生命周期。** WebSurface 代码未变，但其身份/挂载语境随父图改变；父图重算是否导致拆卸/重加，静态不可见，且「body 重算⇒UIView 拆卸」不成立（身份决定生命周期）。验证法：若结构修复版止崩，本项无需单独证；若日后要分离，需在诊断构建中记录 makeUIView/dismantleUIView 计数与实例标识随触摸的变化。本轮不单独行动。

**S-D（低）：ContentView 观察扇出 3→6 个 Store＋pending。** body 重算面变宽，但 1652 同样在 web 发布时重算（body 平凡），至多共因子/放大器，无独立触发链。结构修复版保留 6 个 Store 的观察（数据层不动），若止崩则 S-D 至多共因子自动降级。

**S-E（并入 S-A）：FloatingPanelStore 本体。** 其 sink 已被 F_PANELSINK 排除、状态切换已被锁定展开跑次排除；剩下的只是「由它决定的结构存在」，即 S-A 的组成解释，不单列。

**S-F（最低，不归零）：App init 构造层与数据层增量。** 6 个 Store 的构造、AgentEngine 新 @Published 初值、SettingsStore init 归一化——空闲触摸无执行路径，无正证据上调；仅在结构修复版仍崩时进入下一轮审计范围。

**未回退差异（登记，不列嫌疑）：BrowserView 按钮 44pt frame 与间距**（d6b873d 引入）。机械上与触摸崩溃难建立链条，但它是差异集合的正式成员；结构修复版按 1652 骨架回退时一并还原，日后作为受控改动单独重引入。

## 3. 预写判读与下一版方案

### 3.1 「全关仍崩」分支——**已成立（03:49 实测）**

判读：单因素矩阵与联合关断双重证伪 ⇒ 触发点位于开关覆盖之外，或为覆盖内构造的冗余多路径（无正证据）。结合 §1.4 交集论证与 §2.2 父链对比，嫌疑面收敛为 S-A／S-B／S-C 三项结构残件。行动：停止一切开关实验与单嫌疑盲修，执行 §3.3 结构修复版。

### 3.2 「全关不崩」分支（反事实存档，未发生）

若全关止崩，则说明触发需要覆盖内构造的组合（单因素不必要、联合必要），下一步应为组间二分开关 v2（全关为基线，逐组恢复）。该分支未发生，组间二分 v2 **正式否决**：对已被整体证伪的覆盖集再切分没有信息量（Astra 同意）。

### 3.3 下一版：结构修复版（具体改法）

一句话（Astra 结论，本卷采纳）：**只做一次完整的 UI 结构回退——恢复 1652 流内布局、彻底摘除浮层与 FocusState、保留 v0.2 数据功能，交付可用候选版。**

具体改法：
1. **ContentView 回 1652 骨架**：`NavigationStack { VStack(spacing: 0) { BrowserView(controller: web).frame(maxHeight: .infinity); Divider(); <聊天区> } }`，toolbar 两项保留（1652 已有；设置项保留 diagnostics 参数以便崩溃报告入口存续）。删 GeometryReader、删两层 `.overlay`、删 `@FocusState` 声明与 `.onChange(of: panel.expanded)` 写回、删 FloatingBallView 挂载。
2. **聊天区流内挂载**：复用 AgentChatView 的内容（消息流、输入行、确认卡片、ask_user 作答、模型防呆），去掉其对悬浮语义的依赖：收起/展开按钮与 panel 参数移除；输入行用 1652 控制台同款**无 `.focused` 绑定的纵向 TextField**（程序化焦点控制整体不要，1652 已验证该形态可用）。高度参考 1652 控制台的流内分配（聊天区在下方分区，步骤/消息区内部滚动——ScrollView 在流内已由 1652 验证不崩）。
3. **FloatingPanelStore 退出 UI**：App init 不再以其驱动任何挂载；文件可留仓不引用，或删除（实施时定，报告中注明）。
4. **BrowserView 按 1652 还原**：按钮 frame/间距回 1652 形态（44pt 命中帧作为已知未回退差异一并还原，日后受控重引入）。
5. **数据层全保留、逐字不动**：AgentConversationStore＋App init 的 binds、AgentEngine 全部 v0.2 增量、DiagnosticStore＋MetricKit 注册、SettingsStore 校验与 chips、DebugSwitches 文件（可留仓不挂载，App init 不再触碰 launchConfig 作为行为开关；设置页开关区随之移除或保留为无害展示——实施时以「主树不引用」为准并在报告中注明）。
6. **MikaWebApp**：回直接构造＋无条件 bind＋diagnostics.start() 的 1652 式 init（对象仍为 6 个，数据层需要）。

验收（Joey 只做产品级复测，不再做实验）：原必崩姿势点网页上方区域 5 次＋滚动网页；跑一个真实任务全程（自动收起的产品语义改为流内布局后自然消失，验收点改为任务执行与结果回显正常）；ask_user 对话内作答续跑；确认卡片出现与点按；设置页崩溃报告可打开。
止崩后的结论文案（定版，不得升级）：「回退该组 UI 结构变化后，在已测试条件下恢复稳定；具体触发机制未分离。」不得写「根因已确认」或「S-A 已被证明」。
若仍崩：不在本结构内继续猜。退路是**以 1652 的 App/ContentView/BrowserView/AgentConsoleView 逐字基线出确认构建**（先证基线在当前设备/系统上仍不崩），再逐个回加数据层增量定位；注意（Astra）：届时也不能仅凭排除法断言病因在 App init/Store 层，须以基线构建实测为锚。

### 3.4 明示不做

- 组间二分开关 v2：否决（§3.2）。
- 原「构建 A」（全关基线单摘 FocusState）单独成轮：否决——其基线是不可交付的静态配置，且占一整轮 Joey 真机验证；S-B 的全摘已并入结构修复版（Astra 意见，本卷采纳）。代价记录在案：S-A 与 S-B 在本轮不分离，止崩后按 §3.3 定版文案表述。

## 4. 证据索引

- 开关实现：DebugSwitches.swift:34-64（快照）、:67-104（StaticChatView）、:106-116（DebugChatPlaceholder）；消费点 MikaWebApp.swift:12,19,21-23；ContentView.swift:10,14-38,47；AgentChatView.swift:38-76；FloatingPanelStore.swift:19-24；DiagnosticStore.swift:24-35（add 唯一调用点 :27）。
- 红线逐字核对：WebController 等 7 文件 1652→1747、1652→HEAD 双段零 diff；BrowserView diff 全文仅按钮帧/间距；pbxproj XCBuildConfiguration 三版本比对无差异；Info.plist 零 diff；两树均无 entitlements。
- 父链材料：1652 ContentView / 1747 ContentView＋FloatingAgentOverlay / 现行 ContentView＋FloatingAgentOverlay（FloatingBallView）原文（git show 留档于本卷工作过程）。

## 5. Astra 复核纪要（effort medium，2026-11-02）

- 同意：S-A 第一、S-D 低位、S-E 并入 S-A、S-F 最低、否决组间二分。
- 修正并已采纳：① S-B 机制降级（相关性＞机制证据；裸声明注册焦点系统无公开保证；未执行 onChange 不作执行证据）；② S-C 定性为 S-A 的候选机制而非独立嫌疑；③ 查漏补入 BrowserView 44pt 差异；④ 父链表述收紧（GeometryReader 父位与 overlay 修饰符非跨版本交集，交集是共存布局方式）；⑤ 交集论证逻辑边界（只证非必要、不证病因必在交集内）；⑥ 方案改判：跳过构建 A、直接结构修复版且 FocusState 必须在版内全摘，否则失败后仍残留已知嫌疑；⑦ 止崩文案与仍崩退路的措辞收紧（不得凭排除法断言 App init 层）。
- 一句话结论（Astra 原文）：「下一版只做一次完整的 UI 结构回退：恢复 1652 流内布局、彻底摘除浮层与 FocusState，保留 v0.2 数据功能，交付可用候选版。」
