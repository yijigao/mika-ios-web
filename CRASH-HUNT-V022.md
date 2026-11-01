# Mika Web 触摸网页闪退定位案卷 — CRASH-HUNT-V022

- 日期：2026-11-02（定位分析，未改代码、未发版）
- 基线对照：1652＝提交 `3165943`（真机触摸网页不崩）→ v0.2/1747＝`d6b873d`（崩）→ v0.2.1/1811＝`aa3a3bb`（仍崩）；HEAD `2c3d952` 仅文档。
- 症状（Joey 2026-11-02 02:02 与 02:44 两次报告）：面板展开态下，点击聊天窗上方露出的网页区域立即闪退，必现；1811 与 1747 症状一致。
- 证据状态：无崩溃栈（ASC 无 1747/1811 崩溃提交；MetricKit 报告待 Joey 导出）。本案卷是栈缺席情况下的定位准备。
- 一条方法论限定（Astra 复核提出、本案卷采纳）：**1747 与 1811 症状相同，不等于已证明是同一种崩溃。** 下文的不变量推理以「同源」为工作假设；若后续实验出现与该假设矛盾的结果（如球态也崩但形态不同），应按两条故障路径分别处理。

## 0. 已被 v0.2.1 复测排除的构造（不必再查）

v0.2.1 已删除/修改且闪退不变，以下不再作为必要条件候选：

- 全屏 GeometryReader + ZStack + `.position` 覆盖层（1747 形态）——已整体删除。
- 聊天 ScrollView 上的 `simultaneousGesture` 写 `@State`——已删除。
- `scrollTo` 的 `withAnimation`——已去掉。
- 球体 Button＋DragGesture 手势竞争——展开态根本没有球体分支，且两次复现都在展开态，与本症状无关（上一轮定界已确认）。

推论：触发点不在「覆盖层几何形态」，而在 v0.2 与 v0.2.1 **共同保留**、1652 **没有**的构造集合内（下节枚举）。

## 1. 不变量枚举：1652 → HEAD 的全部相关 diff

`git diff 3165943..HEAD` 共 12 个文件、+575/−21。网页层红线文件（WebController / PageState / SafetyPolicy / ModelClient / Keychain / SelfTestView / MikaWebIntents）在 diff 中**零出现**；`WebSurface`（UIViewRepresentable，updateUIView 为空操作）一字未动——网页层代码与 1652 完全相同。差异只在以下构造（按文件）：

### 1.1 ContentView.swift（结构层）
- 观察对象从 3 个（web/settings/engine）+ pending 增至 **6 个 + pending**（新增 conversation / panel / diagnostics 三个 @ObservedObject）。
- 布局从 `VStack { BrowserView; Divider; AgentConsoleView }`（浏览器与控制台上下分区、永不重叠）改为浏览器与聊天面板**同层重叠**：1747 为 ZStack 叠加，1811 为 `.overlay(alignment:.bottom)` 把 AgentChatView 挂在 BrowserView 之上。两种挂载都崩——**重叠共存**是不变量，挂载方式不是。
- 1811 新增根 GeometryReader 并把 `geometry.size` 回写为 `BrowserView.frame(width:height:)`（1747 无此回写也崩，故回写至多与 1811 局部路径相关，不可能解释两版共同症状）。
- 新增 `@FocusState inputFocused`（1747 声明在悬浮层结构内，1811 声明在 ContentView），以绑定形式传入 AgentChatView；新增 `.onChange(of: panel.expanded)` 在收起时写 `inputFocused = false`。
- `consumePending()` 改为写 `conversation.draft`（原写 engine.taskText 并先 stop）。

### 1.2 AgentChatView.swift（v0.2 新增文件；展开态才挂载，冷启动默认展开）
- `ScrollViewReader { ScrollView { LazyVStack(ForEach(conversation.entries)) } }` + `.onChange(of: entries.count)` 程序化 `scrollTo`。
- 输入框 `TextField(axis: .vertical)`（UITextView 底座）+ `.focused(inputFocused)`——全 App 唯一的 @FocusState 连接点。
- 同时观察 engine / settings / conversation / panel 四个对象；正文读取多个发布值（status、steps.count、conversationTaskID、maxSteps、hasKey）。
- 1652 的对应物 AgentConsoleView 在 v0.2 起已无任何引用（孤儿文件，参与编译但从未挂载）：「控制台与网页同屏」不是新增，新增的是**控制台以浮层形态与网页重叠**、且换成了带 ScrollViewReader＋FocusState 输入框的聊天子树。

### 1.3 AgentConversationStore.swift（v0.2 新增）
- App init 期 `bind(to:)` 订阅 engine 三个发布者（`$conversationTaskID` / `$steps` / `$status`），sink 回调内**同步**修改自身 @Published `entries`。1811 未改此调度。

### 1.4 FloatingPanelStore.swift（v0.2 新增）
- `bind(to:)` 订阅 `engine.$executionSerial.dropFirst()`，sink 内同步 `collapse()` 改自身 @Published `expanded`。1811 仅加 expand/collapse 同值保护，订阅链未动。`expanded` 初值 true（冷启动即展开态，与复现场景吻合）。

### 1.5 DiagnosticStore.swift + CrashReportsView.swift（v0.2 新增）
- App init 内 `diagnostics.start()` → `MXMetricManager.shared.add(self)`。DiagnosticStore 是全 App 唯一**非 @MainActor** 的 ObservableObject（NSObject 子类）；didReceive 在系统线程取 jsonRepresentation 后经串行队列落盘、主线程 async 发布。上一轮已审实现干净；Astra 提示：非 MainActor 本身不是错误证据，要接上触发链需实际回调/跨线程访问/生命周期问题。

### 1.6 MikaWebApp.swift
- 1652：三个 Store 以 StateObject(wrappedValue:) 直接构造，无交叉绑定。v0.2 起：init 内构造六个对象并当场执行 `conversation.bind`、`panel.bind`、`diagnostics.start()`——绑定与 MetricKit 注册都发生在首帧之前。

### 1.7 AgentEngine.swift（修改，非红线文件）
- 新增 @Published：`conversationTaskID`、`waitingInput`、`executionSerial`；新增 `submitAnswer` 与 answerContext；两处 `web.execute` 前 `executionSerial += 1`。仅任务执行期活动，引擎空闲时无发布、无触摸时执行路径。

### 1.8 其余（枚举完整性，机械上与触摸无关）
- SettingsStore：`validateModelName` 纯函数；maxSteps 的 didSet 自赋值改为带归一化保护；SettingsView 增加模型 chips 与可选 diagnostics 入口。仅设置页路径。
- BrowserView：按钮 44pt 命中框、HStack 间距——纯外观。
- AgentConsoleView：「继续」按钮 disabled 条件拆分——且该视图已不挂载。

### 1.9 代码零改动 ≠ 实例生命周期零变化（查漏项）
`WebSurface`/`WebController` 代码未动，但承载它们的父树变了：Representable 的创建/拆卸时机、WKWebView 实例是否被重新挂载，都由新父树决定，静态 diff 看不出来。开关版实验应顺带记录 WKWebView 实例标识在展开/收起/重渲染前后是否变化（见 §4 执行纪律）。

## 2. 候选清单（按置信度排序；经 Astra medium 复核，分歧已注明）

置信度指「该构造是本次闪退必要条件」的把握，不是机制已被证明的程度——**目前没有任何具体机制达到高置信**，有栈之前一切排序都是排查优先级。

### C1（最高优先）：展开态聊天子树参与窗口级手势/焦点系统
共同点：1747/1811 都在、1652 都不在，且与触摸在时间和空间上重合。两个子变体并列第一：

- **C1a 手势识别/仲裁依赖图**：链条假设——网页 touch-down → UIKit/SwiftUI 查询手势识别器关系 → 新增子树（聊天 ScrollView、面板外壳、共同祖先上的 modifier、原生文本交互任一）参与建立的依赖关系异常 → 框架内部断言/非法访问。轻触即进入识别与仲裁，不需要先发生滚动，也不需要 engine 发布或键盘变化——这是唯一能覆盖「静止本地页＋空闲＋从未聚焦＋任意轻触即崩」最严苛情形的候选类别。最强反例：聊天 ScrollView 不在触点祖先链上、与 WKWebView 只是兄弟，若无共享祖先手势或桥接异常，「两个滚动区共存」本身不构成冲突——所以要测的是**拿掉滚动容器**是否恢复，而非再改面板面积/位置。
- **C1b 焦点注册/原生输入控件**：链条假设——`.focused($inputFocused)` 把 @FocusState 绑定到条件挂载子树内的纵向 TextField（UITextView 底座）；焦点系统的注册/查询在首次网页触摸时被牵连。1811 把 @FocusState 声明位置从悬浮层挪到 ContentView，**并没有移除 `.focused` 连接与原生输入控件本身**，故该类未被 1811 排除。注意须把两件事分开测：(i) @FocusState 绑定；(ii) 原生 TextField 控件本身（去掉 `.focused` 后它仍有文本选择/内部滚动行为）。最强反例：冷启动从未聚焦、触摸时 expanded 不变、输入控件未卸载——「失焦/卸载悬空绑定」分支没有发生条件；但「静态焦点注册参与首次触摸查询」分支不受此反例影响。
- **C1c 子树观察扇出＋entries 渲染/scrollTo**（C1 内最低）：需要「发布→body 重算→副作用」的实际事件链；加载完成后静止页轻触没有 progress/url 发布，解释力弱。`updateUIView` 为空也排除了「重渲染→重新 load→再 KVO」的常见闭环。

### C2（低）：AgentConversationStore 三 sink 同步自发布
有明确的同步回调路径，但缺「网页触摸 → engine 发布」这一必要桥梁：触摸不改变 steps/status/conversationTaskID（导航/KVO 属于 WebController，不回流到 engine 发布者）。补一个 Astra 指出的边角情形：若 Store 实例因视图身份变化被反复创建，订阅建立时 `$property` 会立即投递当前值，空闲也可能反复触发初始化回调——目前无实例不稳定的证据，列为开关版的观测项即可。

### C3（低）：FloatingPanelStore 的 executionSerial sink
与 C2 同类但触发面更窄：executionSerial 只在引擎执行动作前递增，空闲触摸无事件。仅在开关版顺带关断验证，不单独排查。

### C4（低）：ContentView 观察扇出（7 对象）＋ 1811 的 GeometryReader 尺寸回写
- GeometryReader 回写是 1811 独有，**按定义不可能解释 1747**，至多是 1811 自己的局部敏感点（Astra 异议：连「放大器」都未证实，只能记为「C 版局部候选」）。
- 观察扇出：1652 时根视图同样观察 web 并在 KVO churn 下重算而不崩；扇出变宽（+3 个对象）单独致崩缺机制。两者都只保留在开关矩阵内，不作主线。

### C5（低）：DiagnosticStore / MetricKit 注册
投递时机与触摸无已知关联，实现已审干净；但它是唯一新增的非 UI 子系统，若 UI 簇被开关版整体出局，它与 C2 是下一顺位。排除法很干净：不创建、不注册、其余不变，仍崩即出局（注意：启动后再 remove 不等价，必须启动前决定）。

### C6（末位）：AgentEngine 新增 @Published 与 submitAnswer、SettingsStore 改动、BrowserView 外观改动
属性声明与未被调用的方法在触摸时没有执行路径；除非触摸间接调用到它们，否则不成立。枚举备查，不排查。

## 3. 零构建先行实验（现行 1811 构建即可做，每项 ≤1 分钟）

顺序经 Astra 复核确认（Z1 → Z2 → Z3），Z4 为补充。每项记录：崩/不崩、当时页面、键盘状态。

| # | 操作（条件要卡死） | 判别什么 |
|---|---|---|
| Z1 | 冷启动 → 等本地默认页加载完成 → **不碰任何控件、从未聚焦任何输入框** → 轻触上方网页空白区 | 剪枝最多的一项：若仍崩，导航发布、聊天数据更新、失焦/收键盘三类路径同批显著降级，保留 C1a（手势仲裁）、C1b 的静态注册分支、C5、§1.9 的实例生命周期；若不崩，说明触发需要前置交互，转 Z3/Z4 |
| Z2 | 保持同页与空闲，手动收起面板成球态 → 再点网页区 | 若不崩：展开子树/展开布局是强必要条件（C1 簇坐实）；若仍崩：C1 的「当前挂载子树」版本降级，范围转向 App 级构造（C2/C5/§1.9）。注意：手动收起可能残留焦点/手势状态，证据略脏于「冷启动即球态」——1811 无此能力，冷启动球态对照放到开关版（F_PANELSTATE，见 §4）补做 |
| Z3 | 冷启动展开态 → 先点聊天输入框聚焦（键盘升起）→ 再点同一网页空白区 | 与 Z1 对照判别焦点转移/键盘尺寸链：Z1 不崩而 Z3 崩 → C1b 大幅升权；两步都崩 → 本步区分力低；若 Z3 反而不崩，应查首次交互时的焦点注册/初始化状态，不要归因为普通收键盘 |
| Z4 | 展开态先跑一个任务让对话有条目，结束后点网页区 | 与 Z1 对照判别 entries 渲染与引擎状态相关性（C1c / C2） |

Z1+Z2 约两分钟即可把候选空间连续对半切两次，建议先于任何新构建完成。

## 4. 二分剥离方案：一个构建、多开关（推荐主线）

每个 TestFlight 构建约 25 分钟流水线，逐项回退需多个构建；改为**一个「开关版」构建**：开关存 UserDefaults，仅在 App 冷启动时读取、决定本次进程的构造形态，运行中不切换（避免把「现场拆卸输入控件/WebView」这种额外变量引入触摸实验）。开关默认全开＝与 1811 行为等价；**先验纪律：全开配置必须先复现闪退，否则开关版基线不成立、全部结论作废。**

| 开关 | 关掉时做什么（控制条件） | 对应候选 |
|---|---|---|
| F_CHAT | 展开态不挂 AgentChatView，换同尺寸同材质的惰性占位条（面板外壳/几何/位置不变，Store 照常绑定） | C1 整体（子树在场性） |
| F_SCROLL | 聊天保留输入栏与外壳，消息区不用 ScrollViewReader+ScrollView+LazyVStack，改静态等高占位 | C1a（滚动容器） |
| F_INPUT | 聊天输入框换同尺寸非输入占位（原生 TextField 整体不在场），其余不变 | C1b(ii)（原生输入控件） |
| F_FOCUS | 输入框保留，只移除 `.focused` 修饰符（@FocusState 声明保留；仅设 false 不算关） | C1b(i)（焦点绑定） |
| F_OBSERVE | 聊天子树保留视觉结构，但数据换固定假数据、不订阅任何 ObservableObject | C1c / C4 的观察侧 |
| F_CONVSINK | App init 跳过 `conversation.bind(to:)`（Store 实例照常创建，entries 保持初始空态） | C2 |
| F_PANELSINK | App init 跳过 `panel.bind(to:)`，且本配置下 expanded 固定为展开（保证与基线同态对照） | C3 |
| F_PANELSTATE | 冷启动默认收起（球态） | Z2 的干净版对照 |
| F_GEO | 保留 GeometryReader 测量，但 BrowserView 不回写 frame（自然布局），面板仍 overlay 挂载 | C4（仅对 1811 路径有意义，结论不得倒推 1747） |
| F_DIAG | App init 不创建、不注册 DiagnosticStore | C5 |

执行序：全开验崩 → 单因素逐个关（建议序：F_CHAT → F_SCROLL → F_INPUT → F_FOCUS → F_OBSERVE → F_CONVSINK → F_PANELSINK → F_DIAG → F_GEO），每种配置冷启动后按 Z1 规程点网页区至少 5 次。第一个让闪退消失的开关＝必要条件所在簇；随后**恢复验证**（单独只关它、其余全开，确认仍不崩）并做**两因素组合**抽查——交互缺陷可能需要两个条件共同存在，机械二分的结果不能直接当唯一根因。
执行纪律：每组记录配置、各 Store 与 WKWebView 的实例标识、触摸前后 engine/WebController 的发布计数、expanded/focus 是否变化——「空闲无发布」在有计数之前只是推测（同时覆盖 §1.9 的实例生命周期观测）。
开关版的副产品：它本身就是等待栈期间的可用兜底（关掉致崩簇的配置即可日常使用），不需要另发一版。

## 5. 结构安全版（兜底选项）

形态：聊天与浏览器分开两个面，永不同层共存——

- **S1（Tab/分页）**：TabView 两页「浏览器」「助手」；浏览器页结构与 1652 完全一致（只有 BrowserView 及其工具条，控制台形态回到已验证不崩的布局）；引擎开始执行时程序化切到浏览器页（等价于现在的自动收起）；助手页承载 AgentChatView 全量功能。
- **S2（Sheet 呈起）**：聊天改 `.sheet` ＋ detents 从底部呈起，聊天子树进入独立呈现层级，不与 WKWebView 同处一个 SwiftUI 覆盖层；收起即 dismiss。保留「浮在网页上」的观感。
- 利：S1 在构造上让 C1 全簇（子树同树共存、焦点与网页同树、手势仲裁同树）**不可能发生**，布局回到已证不崩的形态；S2 隔离程度接近 S1 且保住悬浮观感。
- 弊：S1 牺牲 Joey 明确要的「悬浮窗看着网页干活」（多一次切页）；S2 仍在同一窗口内，若真凶是窗口级/App 级构造（C5、C2、§1.9）则隔离不彻底；两者都不替代定界——若结构安全版仍崩，反而一锤定音把范围收至 App 级构造。
- 定位：不是首选修复，是「开关版一轮仍不定界」或「需要先交付一个能用的版本」时的兜底；且开关版的 F_CHAT 关态在交付形态上已接近它，可先行顶上。

## 6. 建议的下一步

1. **立即（零成本）**：Joey 在现行 1811 上按 §3 做 Z1、Z2（约 2 分钟），结果报回。此后无论等不等栈，候选空间都先砍掉一半以上。
2. **栈优先**：MetricKit 崩溃报告一到手，按栈定界，跳过二分直接修——栈与开关单变量结果互相印证后才可写「根因已确认」；只有真机通过而无栈时，口径沿用既定定版：「触摸回归已消除，根因机制未证实」。
3. **栈未到**：发 §4 开关版（一个构建）完成定界，不再逐版猜修——1747→1811 已证明盲修一轮的代价（症状零变化）。
4. **若 Z2 显示球态也崩**：先怀疑 1811 与 1747 并非同一种崩溃（见卷首限定），开关版优先跑 F_DIAG / F_CONVSINK / F_OBSERVE 三项 App 级开关，不要继续在 UI 几何上打转。
5. 结构安全版（§5）只在两种情况下启动：开关版一轮仍不定界，或 Joey 需要先拿到能用的版本。
