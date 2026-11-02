# Mika Web 触摸网页闪退最小化阶梯·第二轮 — CRASH-LADDER-2

- 日期：2026-11-02（设计＋构建交付，待主聊转交 Joey 按阶真机测）
- 触发：第一轮阶梯（CRASH-LADDER-2026-11-02.md）真机结果——H0（202611020036，裸 WKWebView）不崩、H2（202611020054，现行 BrowserView/WebSurface/WebController 地基＋底部静态占位）不崩（Joey 2026-11-02 上午实测；H1 阶 Joey 未单独回报，按其「空的不闪退」与续测 H2 的进程，H1 层未被指为首崩层，本卷以 H0/H2 两端实测为准）。结论：裸挂载、起始页、iOS 层、BrowserView 地基本体全部脱罪；病因在 H2 之上的**生产 App 装配组合**。本轮自 H2 向上逐件加回 1652 生产装配，分两阶：装配骨架（H3）→ 动态接线（H4）。
- 代码：分支 `crash-ladder-2`（自 `crash-ladder` 尖端 2e9a33d 另建；main 生产分支未动）。延续第一轮工程纪律：同一起始页、同 WebController 配置、DiagnosticStore＋MetricKit 导出与右下角圆钮包装两阶恒定；阶梯变量只经 `Harness.step` 常量切换（3→4），H4 提交与 H3 的源码 diff 恰为 step 一行（H3/H4 视图代码同批入 H3 提交，与第一轮口径一致）。
- 红线遵守：未改起始页、未改 WebSurface/WebController/BrowserView 本体（均为仓库现行文件逐字使用）；本轮只动装配层（分支专用 MikaWebApp 入口与 Harness.swift）。

## 1. 差异清单：「1652 生产装配有、H2 没有」

对比锚点：`3165943`（1652 基线树，其逐字构建 202611020016 真机一点网页即崩）与现行生产 main（v0.2.3，构建 202611012002 同样真机崩）。H2＝第一轮阶梯 H2 视图（根视图 @StateObject 自持 WebController＋BrowserView＋底部静态占位；App 入口仅装配 DiagnosticStore）。

### 1.1 1652（3165943）装配与 H2 的差异（本轮 H3/H4 覆盖）

| # | 差异项 | 1652 形态（出处） | H2 形态 |
|---|---|---|---|
| D1 | WebController 持有者与构造时机 | App struct 以 @StateObject 持有，App init 构造（MikaWebApp.swift） | 根视图以 @StateObject 自持构造 |
| D2 | SettingsStore 对象创建 | App init 构造、@StateObject 持有 | 不存在 |
| D3 | AgentEngine 对象创建 | App init 构造 `AgentEngine(web:settings:)`、@StateObject 持有（其 init 仅存引用，无定时器/订阅/网络副作用，源码实查） | 不存在 |
| D4 | 根视图观察扇出 | ContentView 以 @ObservedObject 同时观察 web/settings/engine，任一 store 发布即重算根 body（含 WebController 的 progress/address/canGoBack 等高频发布） | 根视图仅经 BrowserView/WebSurface 观察 controller（与地基同捆，已随 H2 脱罪）；无 settings/engine 观察 |
| D5 | PendingTaskStore 观察与消费 | ContentView @ObservedObject 观察 `PendingTaskStore.shared`，onAppear＋onChange(of: pending.task) → consumePending（engine.stop()＋写 engine.taskText＋清 pending.task） | 无 |
| D6 | scenePhase 接线 | App @Environment(\.scenePhase)＋onChange(initial:true) → engine.setForeground（MikaWebApp body） | 无（engine 不存在） |
| D7 | toolbar 真实导航项 | NavigationLink → SelfTestView(engine:settings:)、SettingsView(settings:) | 仅阶梯标记 Text 占位 |
| D8 | 控制台子树（流内） | AgentConsoleView(engine:settings:)：@ObservedObject 观察 engine/settings；输入 TextField 与 $engine.taskText 双向绑定（纵向轴）；开始/停止/继续按钮直连 engine；状态文案与步骤计数观察 engine/settings 发布；hasKey 条件 NavigationLink；steps 非空时 ScrollView+LazyVStack（空闲时不挂载）；waitingConfirm 的 .alert 绑定 | 底部 120pt 静态占位条，无任何子树 |
| D9 | 对象图生命周期归属 | 对象图由 App 持有、向下传递给根视图 | WebController 由根视图自持 |

### 1.2 现行生产 main 相对 1652 的追加装配（本轮不覆盖，留作 H5 增量）

| # | 差异项 | 说明 |
|---|---|---|
| E1 | AgentConversationStore 创建＋`conversation.bind(to: engine)` | App init 构造并无条件 bind；bind 内含对 engine.$conversationTaskID/$steps 等的 Combine sink 订阅（AgentConversationStore.swift:30-） |
| E2 | AgentChatView 子树替换 AgentConsoleView | 观察 conversation＋engine＋settings；输入草稿绑定 conversation.draft；ScrollViewReader 消息列表；ask_user 作答与确认卡片流内呈现 |
| E3 | ContentView 观察面再扩 | 追加 @ObservedObject conversation、diagnostics；consumePending 改写 conversation.draft |
| E4 | SettingsView 传 diagnostics 参数 | 设置页崩溃报告入口接线（SettingsView 的 diagnostics 为可选参数，缺省 nil） |

**为何本轮不做 H5**：E1–E4 的整体形态即现行生产构建 202611012002，已在同一设备、同一手势下实测必崩，与 1652 逐字构建 202611020016 共同构成阶梯顶端的「崩」锚点；本轮 H3/H4 若全稳，下一轮再以 E 组为增量二分（先 E1 bind、后 E2 子树）。若 H4 已崩，则 E 组整体脱罪、无需再测。

### 1.3 两阶恒定项（不构成阶梯内变量）

- 起始页与 WebController 配置：与第一轮相同（WebController.init 的 loadHTMLString 本地页原文、`.default()` 数据存储、customUserAgent），H3/H4 均经现行 WebController 本体加载。
- 诊断包装：DiagnosticStore 于 App init 构造＋start()（与生产 main 口径一致；第一轮阶梯 App 亦如此）；根 Group＋右下角圆钮（旁标阶号）＋sheet 导出包装与第一轮逐字相同，位于视图树外层。
- BrowserView/WebSurface/WebController/SettingsStore/AgentEngine/AgentConsoleView/SelfTestView/SettingsView 均为仓库现行文件逐字使用（AgentConsoleView 与 3165943 的差异仅 4 行 v0.2 数据接线，骨架与绑定形态为 1652 原形；本轮按现行文件用，差异登记在此）。

## 2. 两阶构建定义

### H3 — H2 ＋ 生产 App 级装配骨架（step=3）

加回的装配（对应差异 D1、D2、D3、D9＋D8 的静态形态）：
- **App 入口（分支专用 MikaWebApp）按 1652 形态装配**：@StateObject 持有 web/settings/engine/diagnostics；init 依次构造 WebController、SettingsStore、AgentEngine(web:settings:)、DiagnosticStore 并 start()。不建 conversation store、无 bind、无 scenePhase 接线（归 H4）。
- **根视图（HarnessH3View）按 1652 ContentView 布局结构**：NavigationStack { VStack(spacing:0) { BrowserView.frame(maxHeight:.infinity); Divider(); 控制台区 } }，标题 inline。web/settings/engine 由 App 以**普通引用（let）向下传递**——根视图不对 settings/engine 声明 @ObservedObject（观察扇出归 H4），BrowserView 内部对 controller 的观察与 H2 逐字相同。
- **控制台区为静态形态（HarnessStaticConsole）**：与 AgentConsoleView 同版式——纵向 TextField（本地 @State 草稿、roundedBorder、lineLimit 1...3，**不绑定 engine、无 .focused**）、开始/停止按钮（禁用态）、静态「步骤 0」计数与「待命」状态文案；不读任何 store 发布、不挂 ScrollView。
- **AgentEngine 只创建不执行**：不调用 start/stop、不发网络请求（其 init 无副作用，源码实查；空闲态 steps 为空、status=.idle）。
- toolbar 仍为阶梯标记（D7 归 H4）。

与 H2 的净增量：WebController 持有者由根视图上移 App（D1/D9）；SettingsStore＋AgentEngine 对象进入对象图（D2/D3）；底部占位换控制台静态形态（含一个流内 TextField 的存在本身）。

### H4 — H3 ＋ 1652 剩余动态接线（step=4）

在 H3 之上逐项加回（对应 D4、D5、D6、D7、D8 动态部分）：
1. **根视图观察扇出（D4）**：根视图（HarnessH4View）改以 @ObservedObject 观察 web/settings/engine——结构逐字复刻 3165943 的 ContentView（NavigationStack/VStack/BrowserView/Divider/控制台、toolbar、onAppear/onChange）。
2. **真实控制台子树（D8）**：静态控制台换仓库现行 AgentConsoleView(engine:settings:) 原文挂载——$engine.taskText 双向绑定、按钮直连 engine、状态/步骤观察发布、hasKey 条件链接、waitingConfirm alert 绑定、steps 非空时 ScrollView 挂载，全部随原文生效。测试规程为空闲触摸，engine 不被启动（与基线崩溃条件一致）。
3. **Pending 接线（D5）**：@ObservedObject 观察 PendingTaskStore.shared，onAppear＋onChange(of: pending.task) → consumePending 按 1652 语义逐字（engine.stop()＋engine.taskText=task＋pending.task=nil）。
4. **toolbar 真实导航项（D7）**：NavigationLink → SelfTestView(engine:settings:)、SettingsView(settings:)（1652 调用形态；现行 SettingsView 的 diagnostics 参数缺省 nil，崩溃报告入口在该目的地内不出现——与 1652 一致，登记为与生产 main 的已知差别，不影响本阶变量纯度）。
5. **scenePhase 接线（D6）**：onChange(of: scenePhase, initial:true) → engine.setForeground(phase==.active)。**挂载点与 1652 不同**：1652 在 App body，本阶在阶梯根包装（HarnessRootView）按 step≥4 生效——接线的存在与语义为变量，语法挂载点为包装差异，登记在此。

与 H3 的净增量：仅根视图接线层（观察扇出＋真控制台＋pending＋toolbar 目的地＋scenePhase）。App 构造口径、对象图、起始页、地基本体两阶恒定；源码 diff 恰为 `Harness.step` 3→4 一行。

## 3. 判读预写（只定位到层，不写根因确认）

- **H3 崩** → 病因在装配骨架层：App 级对象图创建/持有（D1/D2/D3/D9）或流内控制台静态形态（含 TextField 存在）这一组。下一轮在组内二分（对象创建 vs 静态控制台）。
- **H3 稳、H4 崩** → 病因在动态接线层：观察扇出（D4）、真控制台绑定/观察（D8）、pending 接线（D5）、toolbar 目的地（D7）、scenePhase 写回（D6）这一组。下一轮在组内逐项二分。
- **H3/H4 全稳** → 1652 装配整体脱罪，病因在现行生产追加装配（E 组：conversation store＋bind、AgentChatView 子树等）或阶梯与生产的未登记差别中；下一轮以 E 组为增量自 H4 向上加回。
- 以上均为层级定位，不是根因确认；具体触发机制仍未分离。崩溃报告（带本阶构建新偏移）回收后先核签名是否仍与既往一致，再决定层内下一步。
- Joey 测试规程（主聊转交）：按 H3→H4 顺序装；每阶打开 App 停留在起始页（不要先输网址跳转），点上方网页 5 次＋滚动；首崩即停，重开 App 点右下角圆钮导出最新崩溃报告发回。根视图右下角标 H3/H4 与构建号可互核。

## 4. 构建与 ASC 回读证据

分支 `crash-ladder-2`（自 crash-ladder 尖端 2e9a33d 建，已 push origin）。validate_project.py 全 PASS（18 源文件）。

### H3 — 构建 202611020205

- 提交 `5e81bf1`（App 入口按 1652 形态装配对象图＋Harness 扩 H3/H4 视图＋step=3；含本案卷）。
- CI Run **41375765685** success（macOS 真编译通过）；Release Run **41375769004** success。
- build id `9eb91a34-8b43-47c4-97d5-cacdcf2a28e1`；ASC 回读 processingState=**VALID**、expired=false、usesNonExemptEncryption 已 PATCH=false 并回读确认；Internal 组（6a722377-d7f3-4c76-876f-4c35e193e0e4）挂载 POST 204，组内回读居首：[202611020205, 202611020054, 202611020045, 202611020036, 202611020016, 202611012002]。

### H4 — 构建 202611020210

- 提交 `b46647e`（与 H3 的源码 diff 经 `git diff --stat` 核验恰为 `Harness.step` 3→4 一行）。
- CI Run **41376265046** success；Release Run **41376269351** success。
- build id `177fb3f5-a8b9-422c-a878-57be49cccfc9`；ASC 回读 processingState=**VALID**、expired=false、usesNonExemptEncryption 已 PATCH=false 并回读确认；Internal 组挂载 POST 204，组内回读居首：[202611020210, 202611020205, 202611020054, 202611020045, 202611020036, 202611020016]。

两阶均未改 main、未动起始页与 WebSurface/WebController/BrowserView 本体。待主聊转交 Joey 按 §3 规程逐阶真机测（H3 先、首崩即停）。
