# UI-LEGIBILITY 案卷：浮层弹窗可读性修复（强模糊＋近不透明＋变暗遮罩）

- 规格：UI-LEGIBILITY-SPEC-2026-11-03.md。立项依据：Joey 2026-11-03 10:02 亲令＋五张真机截图（09:58–10:00）——「需要你手动处理」介入卡等浮层半透明压在对话与网页之上，背景文字透过来与卡内文字叠印，根本看不清；一张截图里卡内同段文字呈多次叠印状。Joey 要求背景再模糊化。
- 分支：`feat/ui-legibility`（基线＝feat/wechat-editor-nav tip `a9523b6`，含构建 202611030144 全部内容，未合 main）。功能提交 `544b035`。
- 范围：纯呈现层。改动仅 3 个视图文件：`MikaWeb/AgentChatView.swift`、`MikaWeb/ContentView.swift`、`MikaWeb/SelfTestView.swift`。引擎/感知/安全逻辑文件对基线 diff 均为 0 行（见第 5 节红线自查）。

## 1. 浮层清单（盘点结果：视图名＋改前背景材质/透明度）

压在内容之上的浮层，按渲染层级（ContentView ZStack 自下而上：对话层＜浏览器坞＜介入层＜输入栏）：

| # | 浮层 | 视图 | 改前背景 | 本次处理 |
|---|------|------|----------|----------|
| 1 | 介入卡「需要你手动处理」（.waitingManual＋.manual） | `InterventionPrompt` 手输分支（AgentChatView.swift） | `.orange.opacity(0.12)` 单层，无材质、无遮罩 | 换共用背景（见 §3）＋整屏变暗遮罩 |
| 2 | 执行前确认卡（.waitingConfirm，SP 安全确认同路） | `ConfirmCard`（AgentChatView.swift） | `.orange.opacity(0.15)` 单层 | 同上 |
| 3 | 上传确认卡 SP-01（confirmUpload 阶段） | `UploadCard`（AgentChatView.swift） | `.orange.opacity(0.15)` 单层 | 同上 |
| 4 | 选文件等待卡（pickFile 阶段） | `UploadCard` 第二分支（同上） | `.orange.opacity(0.15)` 单层 | 同上 |
| 5 | 坞小窗「等你处理」状态胶囊 | BrowserDockView mini 顶部 overlay | `.ultraThinMaterial` 胶囊＋橙点 | 不动：单行短标签、本身即材质模糊层，非长文案压活页文字，与本次症状（段落级卡内文字透叠）不同源 |
| 6 | 坞展开态「任务在标签页…执行中」提示胶囊 | BrowserDockView expanded 顶部 overlay | `.orange.opacity(0.18)` 胶囊 | 不动：同 #5，单行短标签 |
| 7 | 坞收起按钮（圆形） | BrowserDockView overlay | `.ultraThinMaterial` 圆形 | 不动：纯图标按钮，无文字可读性问题 |
| 8 | 聊天输入栏 | `ChatInputBar`（AgentChatView.swift） | `.regularMaterial` | 不动：已是材质背景，可读性达标 |
| 9 | 会话/附件 sheet、附件预览、分享 sheet | 系统 `.sheet` 呈现（ContentView/AttachmentsView/CrashReportsView） | 系统不透明 sheet | 不动：系统呈现自带不透明背景与变暗，不透字 |
| 10 | 旧控制台确认 alert | `AgentConsoleView`（.alert） | 系统 alert | 不动：全仓无引用（死代码），且系统 alert 自带变暗与不透明 |

介入三卡（#1–#4）由 ContentView 的 `showsInterventionPrompt` 门控、在 ZStack 介入层渲染（坞之上、输入栏之下，`padding(.bottom, inputBarHeight + 6)`）——这正是截图里浮层压住对话与浏览器小窗的位置。

## 2. 症状定性（先定性再改：(a) 过透 vs (b) 重复绘制）

**结论：主因是 (a) 背景过透；(b) 不是视图重复绘制 bug，而是「同一文案在消息流多处在场 × 半透明卡叠加」的视觉叠印。(a)+(b) 混合，(a) 为根、(b) 为放大器。**

实证（代码定位）：

- (a) 实锤：三卡改前背景均为单层 `.orange.opacity(0.12~0.15)`（AgentChatView.swift 改前 ConfirmCard/UploadCard 第 `.background(.orange.opacity(0.15)…)` 行、手输卡 0.12 行），无任何 Material 模糊、无 dim 遮罩。12–15% 不透明度意味着 85% 以上的背景像素直透——卡片正压在对话消息流（自动滚到底）与浏览器小窗（mp.weixin.qq.com 草稿列表页）之上，两边文字以近原强度透出，与卡内文字同屏争读，必然看不清。
- (b) 视图层无重复绘制：介入卡在整个视图层级只渲染一处——ContentView 的 `InterventionPrompt`（`showsInterventionPrompt` 为真时至多一张，渲染优先级由 §3 的 cardKind 互斥保证）；坞内旧介入 UI 已于 INTERVENTION-PROMPT 单摘除（BrowserDockView 文件头与第 176–177 行注释、mini 态只剩 #5 状态胶囊）；消息流内嵌卡已摘除（AgentChatView 第 49–51 行注释）。不存在同一 Text 被画两遍的层级 bug。
- (b) 叠印的真实来源＝同文多处在场：以截图中的弹窗介入为例，同一段介入文案同时出现在——①引擎步骤行 `appendStep("click", "弹窗点按转人工：\(intervention)")`（AgentEngine.swift 两处，改前第 999/1250 行）；②顶部标题状态行 `engine.status.label`＝「等待手动输入：…」（AgentChatView 标题行）；③模型最终回复条目（截图中与介入文案逐字相同的长回复气泡）；④介入卡本体。四处文案以 12% 不透明度的卡面为窗、彼此错开数个点位叠在一起，就是截图里「同段文字多次叠印」。这是 (a) 的直接后果：卡面一旦接近不透明，四处在场也只剩卡内一处可读。
- 处置边界：文案在消息流多处在场属引擎/对话层行为（步骤行是审计轨迹、回复是模型原话），按本单红线（引擎逻辑零改动）不在本单处理，记为观察项（§6）——呈现层修法（近不透明＋遮罩）已足以消除叠印观感，不需要也不允许借本单去动引擎去重。

## 3. 修法（只动背景呈现与遮罩，交互/布局/文案/安全流程零改动）

呈现规格单点定义于 `OverlayStyle`（AgentChatView.swift），三卡共用 `interventionCardBackground()` 修饰：

- 卡面背景（后→前三层，圆角 12 与旧版一致）：
1. `.ultraThickMaterial`（系统最厚材质，强模糊、自身接近不透明）——背景文字先被糊掉，不成字形；这是 Joey 要的「背景再模糊化」的正解层。
2. `Color(.systemBackground).opacity(0.72)` 系统底色覆盖——残余透字再压一轮，复合后接近不透明；深色模式随系统底色自适应。
3. `Color.orange.opacity(0.14)` 橙色调——只保留旧版的身份色，不再承担遮字。
- 未模糊直透比例＝(1−0.72)×(1−0.14)≈0.24，且这部分先经厚材质模糊（`OverlayStyle.unblurredShowThrough`，自检十七断言 ≤0.25）。
- 另加橙色描边（0.45，1pt）＋投影（black 0.30 / r16 / y6），帮卡面与被压暗的背景分离。
- 变暗遮罩（ContentView 介入层，卡之下）：`Color.black.opacity(0.42)` 整屏（ignoresSafeArea）压暗对话层与浏览器坞，卡面成为唯一可读层。遮罩 `allowsHitTesting(false)`——**不拦截触摸**：用户亲手点网页弹窗按钮、点坞控件的路径与旧版完全一致，介入流程不受影响。
- 文本只绘制一层：`InterventionPrompt` 的选卡逻辑抽为纯函数 `cardKind(hasPendingUpload:isWaitingConfirm:isWaitingManualWithInput:)`（上传＞确认＞手输互斥），body 按其结果 switch 渲染——任意状态组合至多一张卡，结构上杜绝双卡叠印。各卡内部文字、按钮、布局顺序、文案一字未动；ConfirmCard 的 `submit` 防重复守卫与 engine.confirm 路径、UploadCard 的一次性凭据消费路径、手输卡的 resume 路径均未触碰。

## 4. 自检十七（编号续排，SelfTestView）

- Tier A（本按钮，不调用模型）：结构断言六项——①基底材质名＝ultraThickMaterial；②系统底色覆盖 ≥0.5（实值 0.72）；③未模糊直透比例 ≤0.25（实值 0.24）；④变暗遮罩不透明度 ≥0.40（实值 0.42）；⑤遮罩不拦截触摸（scrimAllowsHitTesting＝false）；⑥卡片种类真值表五组组合＝[.upload,.upload,.confirm,.manual,.none]（文本层唯一）。结论逐条写入对话。**本机无 Swift 工具链，Tier A 未在本机预跑，待真机执行**（与前各单同口径，不冒充已验）。
- Tier B 真机清单（Joey 复测）：
1. 公众号场再遇介入卡（手动处理/确认/上传任一）：读卡内文字——应清晰可读、卡后整屏变暗、无背景文字透叠。
2. 介入卡在场时亲手点网页弹窗按钮（如条款弹窗「取消」）：应照常可点（遮罩不拦截触摸）；点「打开浏览器」应照常展开坞。
3. 顺带跑自检十七 Tier A，六项全 ✓。

## 5. 流水线与红线自查

- CI Run 41563995582 success；日志原文双核对：70 条 SwiftCompile、三个改动文件（AgentChatView/ContentView/SelfTestView）均在编译列、BUILD SUCCEEDED ×1、BUILD FAILED ×0，唯一 `error:` 为既有 AppIntents 训练噪声。
- Release Run 41564236293 success（Archive Succeeded、ipa 已导出签名、Successfully uploaded package ×1）；构建 **202611030209**（0.1.0）；dSYM artifact dsym-41564236293 实存 4,790,339 字节、未过期。ASC 状态：**待阿仁亲验**（未记 VALID、未挂组）。
- validate_project.py 全 PASS（31 源、12 项资源集，与基线一致——本单未新增源文件，OverlayStyle 与修饰放在 AgentChatView.swift 内）。
- 红线：`git diff a9523b6 -- MikaWeb/SafetyPolicy.swift MikaWeb/MikaWebApp.swift` ＝ 0 行；引擎/感知逻辑文件（AgentEngine/WebController/PageState/LoopDetector/ActionVerification/OutcomeLedger）对基线 diff ＝ 0 行——本单只动 AgentChatView/ContentView/SelfTestView 三个呈现层文件；无新依赖；凭据不落盘；用户可见文案无新增（自检说明除外）、无「并行执行」表述；父级 SPEC 文件未动未提交；未合 main。

## 6. 未证项

1. 自检十七 Tier A 未真机运行（本机无 Swift 工具链），六项断言待 Joey 设备执行。
2. 真机可读性未证：厚材质＋0.72 覆盖在真实公众号页（高对比文字页）后的实际透字程度、0.42 遮罩下网页弹窗按钮的可辨认度，均待 Tier B 第一条实测；本单不声称已在真机验证。
3. 文案在消息流多处在场（步骤行/状态行/回复/卡片）未处理：呈现层修复后叠印观感消除，但若日后要连消息流里的重复文案一并去重，须另立引擎侧单，不在本单范围。
4. 深色模式下卡面观感（系统底色覆盖随模式自适应，理论成立）未真机看过，Tier B 时顺带确认。
