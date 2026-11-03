# WECHAT-COVER-FIX 实施案卷（2026-11-03）

规格：WECHAT-COVER-FIX-SPEC-2026-11-03.md（父级单据）。基线：feat/verify-1 tip `264c1d8`（构建 202611021932）。分支：`feat/wechat-cover-fix`，功能提交 `be14cce`，未合 main。

现场事实（Joey 2026-11-03 08:25/08:28，构建 1932 真机复测，本单不推翻）：generate_cover 正常（900×383、SP-01 豁免正确）；upload_file 能定位 file 控件并拉起系统选择器；「AI 配图功能使用条款」弹窗在场时 1830 的模态升级（完整 pointer 序列，主 frame）在真机无响应，连败转人工处置诚实但问题未解，文章卡在弹窗遮挡下未发表；同场任务另撞「最大 42 步」上限无法继续（Part C）。

## 交付一览

- 构建 **202611030042**（0.1.0），ASC 状态：**待阿仁亲验**（本单不代记 VALID/挂组）。
- CI Run 41554331643 success；日志原文双核对：70 条 SwiftCompile，WebController/AgentEngine/SkillStore/SelfTestView 均在编译列，test-frames 资源打包在位（日志 2 处），BUILD SUCCEEDED ×1、BUILD FAILED ×0，唯一 `error:` 为既有 AppIntents 训练噪声（SSU artifacts）。
- Release Run 41554635915 success（job beta success）；agvtool 置号 202611030042；fastlane 日志 `Successfully uploaded package`；dSYM artifact `dsym-41554635915` 实存 **4,685,536 字节**、未过期。
- validate_project.py 全 PASS（31 个 Swift 源、资源集 11 项含新增 test-frames.html）；本机预检：探针脚本与合成页三段 JS（探针本体、两 iframe 内脚本、顶层状态脚本）经抽取后 `node --check` 语法全过（本机无 Swift 工具链、无 jsdom，行为级验证靠 CI 编译＋真机 Tier A）。

## Part A：弹窗 frame 探针与框内感知关闭

### 先证据：1830 路径的结构盲区（代码实查）

- WebController 的 `evaluate` 走 `tab.webView.evaluateJavaScript`，**只能进主 frame**；`PageScript.extract`（PageState.swift）只查主 frame document，**不进任何 iframe**——住在 iframe 里的弹窗按钮根本拿不到 `data-mika-idx`、不出现在模型快照里。
- 1830 的 `dialogPersists` 同样只查主 frame：弹窗若住 iframe，它会误报「已消失」——旧路径的关闭判定在 frame 情形下不可信。
- 现场悖论：agent 的 click 却在主 frame 探针下被判「在弹窗内」并走完了升级序列仍无响应。两种可能并存：弹窗在主 frame 但事件路径/isTrusted 过不去；或 agent 点到的并非弹窗真按钮（快照里的同名元素在别处）。1830 的工装无法区分——这正是本单先加探针的原因。

### 三假设逐项结论

| 假设 | 结论 | 依据与处置 |
|---|---|---|
| ① 弹窗住跨域 iframe，现行逻辑只在主 frame 找元素/派发事件 | **结构上成立、现场未证**（代码层面前半句已证：主 frame 之外全盲；微信弹窗是否真住 iframe 只能真机探针实测） | 已建全 frame 探针（见下），Tier B 第一条即在公众号现场跑普查看命中 frame——命中 iframe 则假设坐实且修法已就位；命中主 frame 则假设排除、转看 ②③ |
| ② 事件类型/目标路径不对（页面监听的不是 click/pointer 序列，或要点在特定子元素） | **不能排除，已扩面覆盖** | 框内关闭新增 1830 没有的阶段：触摸序列（touchstart/touchend/click）、Escape 三处派发（document/焦点元素/弹窗本体）、关闭叉号 affordance、遮罩点击。若现场是事件类型问题，新阶段序列应能命中其一，阶段名会随回報落进结果 |
| ③ 弹窗查 isTrusted（合成事件一律不认） | **未证、无法用合成事件证伪** | 若真机探针定位到弹窗、新阶段全走完仍不关，则 ③ 事实上成立：本单诚实定界——合成点按过不去这类网页，**规避路线（Part B：不触发弹窗）为正解**，框内关闭只作尽力而为，失败沿用转人工（用户点「取消」），错误原文附探针实测事实，不假装已关闭 |

### 修法（frame 感知版）

- **探针装配**：`BrowserTab.frameProbeScript`（WKUserScript，atDocumentStart、forMainFrameOnly: false、page world）与消息 handler `mikaFrameProbe` 挂进既有 `WebAuthnProbeMultiplexer.equip()` 的同一次装配（每 WKUserContentController 只装一次的弱引用表守卫之下，不另起逐标签注册——CRASH-1031 教训：共享 controller 重复注册同名 handler 会抛异常 abort）；回报经 `FrameProbeHub` 按 token＋webView 身份路由回等待者。
- **普查（probe）**：主 frame `evaluate` 发起 `window.postMessage` 洪泛，每 frame 的监听先向自己的子 frame 转发再处理本 frame，保证整棵 frame 树（含跨源子树）都被问到；各 frame 自查弹窗（判定口径与 1830 的 dialogProbeJS 一致：dialog[open]／role／aria-modal／fixed|absolute＋dialog 类名正则），回报 frame 路径（frames 下标链，如 `0.1`，主 frame 为 `top`）、href、子 frame 数、每个弹窗的签名（id/tag＋class 前 60＋文案前 30）、文案与按钮特征（label/tag/class）。Swift 侧收 900ms 窗口聚成 `FrameCensus`；每次交战的普查写一条 Diagnostics 信封（types `["弹窗Frame探针"]`，诊断页可见）。
- **框内关闭（click）**：只有持有「带目标文案可见按钮的弹窗」的 frame 出手；出手前在该 frame 内按 SafetyPolicy 同口径复查按钮文案敏感词（未批准命中即回報 `refused-sensitive` 不点）。阶段依次：pointer-sequence（完整 pointer/mouse 序列，70ms 步间）→ touch-sequence → escape（三处 keydown Escape＋keyup）→ close-affordance（×/✕/关闭/aria-label/class 含 close|dismiss，排除主按钮）→ mask-click（找覆盖 ≥90% 视口的祖先遮罩，elementFromPoint 后定点派发）。每阶段后轮询（150ms、约 700–900ms）以元素 disconnected 或不可见为消失判据。
- **编排与关闭判定（performModalClose）**：performClick 原三处 performModalClick 调用点改走本编排（就绪弹窗直入、普通点击后存续命中、重扫点击后存续命中）。最多 2 轮：普查→定位目标弹窗（优先按钮文案匹配者）→框内关闭→**再普查复扫，同签名弹窗在所有 frame 中消失才算关闭**（不认 frame 自报的 gone 单独作数）。探针在任何 frame 都没找到弹窗 → 回落 1830 的 performModalClick 原样（探针未覆盖页面时行为不回退）。两轮仍不关 → captureFailureSnapshot＋抛带 `modalUnresponsivePrefix` 的错误，原文附探针摘要（frame 数、命中位置、按钮清单），引擎既有转人工链不变（runTargeted/runConfirmed 两处共用 modalInterventionText）。
- **安全注记**：click 指令
...[truncated 8432 chars]