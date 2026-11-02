# Mika Web 对话键盘不收回＋同批两项追加修复记录（问题 1/2/3，2026-11-02）

需求（Joey 在构建 202611020645 上连续报的三项，同一构建并批交付）：
- 问题 1（14:57）：「我的消息发出后，输入框没有自动收回，占据半屏，无法收下去」——发完消息键盘（连同输入区）一直占半屏，既不自动收、手动也收不下去。
- 问题 2（15:02）：「我消息发出后，自动地放大了全屏，没有必要，很突兀」——AGENT-VIEWPORT-FIX 的「任务开始坞自动展开」被否。
- 问题 3（15:03）：「聊天口应该始终位于最上层，不能被浮窗盖住」——对话输入口（输入框＋发送键所在的那条栏）在小窗态和展开态都必须渲染在浏览器坞之上。

**交付构建：202611020708**（0.1.0，build id `47c67ce2-5eae-48c9-a4a2-9ec536f4d28b`）
- 分支 `fix/chat-keyboard-dismiss`（自 `fix/agent-viewport-lock` 新开，未合 main、未合 fix、未合 feat），代码提交 `24033de`（问题 1 主体）＋`1bea7b3`（类型修复＋问题 2）＋`88c44c5`（问题 3）。
- CI：首轮 41403389898（当时回读 success，但随后 Release 编译失败，见过程注记）；二次 41403751627 success（日志含真实 CompileSwiftSources 步骤）；三轮 41404192796 success（Debug 模拟器真编译，最终代码）。
- Release：首轮 41403473732 **failure**（Release 编译错误，见过程注记，已修）；最终轮 41404357991 success。
- ASC 回读：processingState=**VALID**、expired=false、usesNonExemptEncryption 已 PATCH=false（HTTP 200 后回读确认 false）；Internal 组（6a722377-d7f3-4c76-876f-4c35e193e0e4）挂载 POST **204**，组内回读 0708 居首 [202611020708, 202611020645, 202611020636]。
- validate_project.py 全 PASS（19 个 Swift 源文件）。

## 问题 1：键盘不收回——现状根因（逐条对应三个现象）

在 `AgentChatView.swift`（0645 基线）实查，三个现象同源于**对话层根本没有任何键盘/焦点管理**：

1. **发送后不自动收**：全文没有 `@FocusState`、没有任何 resign 动作。`send()` 的两条路径（submitAnswer 被接受／新任务启动成功）只清 `conversation.draft`，从不断开 TextField 的焦点——TextField 始终是 first responder，键盘自然保持。
2. **手动也收不下去**：① 消息 `ScrollView` 没有 `.scrollDismissesKeyboard`，拖动列表不收；② 没有任何点按空白收键盘的手势；③ 点「停止／继续」等按钮也不会 resign（SwiftUI 按钮点击默认不清焦点）。用户能想到的手势逐条落空，遂「无法收下去」。
3. **小窗护盾／坞层实查结论（任务单要求实查）**：**护盾不是成因**。MiniShieldView 只在 mini 态存在、只覆盖小窗面积，其手势语义是点按展开／拖动移动；它不覆盖小窗以外的对话区，也不覆盖输入区（小窗钳制本就在底部保留线之上）。BrowserDockView 的 `.ignoresSafeArea(.keyboard)` 只作用于坞层自身（让小窗坐标不随键盘跳动），不改变对话层的命中与键盘行为。对话层在任何形态下都没有收键盘机制，才是全因。但实查发现一条真实的**遮挡路径**需一并处理：坞 expanded 时全屏盖住对话层，若对话 TextField 此前持有焦点，键盘是系统级浮层、会继续悬浮在全屏浏览器上方，而对话层不可达、坞的收起按钮也只收坞不清焦点，用户够不到任何收起手段（14:27 与 15:xx 的真机截图里键盘浮在浏览器画面之上的形态与此一致）。

### 修复（问题 1）

- **焦点状态集中持有**：ContentView 新增 `@FocusState chatInputFocused`，绑定下传输入栏 TextField（`.focused(...)`），FocusState Binding 再下传浏览器坞。此前散落无主的焦点自此有唯一所有者。
- **发送成功自动收**：`send()` 只在两条真成功路径（作答被 accepted／新任务真启动＝conversationTaskID 已变）末尾置焦点为 false 收键盘；被拒／启动失败保留焦点与草稿，方便改完重发（不把「发送即收」做成无条件，避免失败后还要重新点输入框）。draft 在收键盘前已清空，多行输入框（axis .vertical，lineLimit 1...3）的高度由内容驱动，随之**自动复位到单行收起态**。
- **手势收键盘**：消息 ScrollView 加 `.scrollDismissesKeyboard(.interactively)`（下滑拖动键盘交互式跟随收起）；再加 `simultaneousGesture(TapGesture())`，点按消息区顺带收键盘——simultaneous 只做收键盘一件事，不拦截 ConfirmCard 按钮等内容本身的点击。
- **展开遮挡路径**：BrowserDockView 加 `onChange(of: mode)`，切到 `.expanded` 的瞬间（来源不限：护盾点按展开／任务介入自动展开）把对话焦点置 false。mini 态不写入（边看小窗边在对话打字是常态路径，发送时自会收）。网页内的手输焦点是 WKWebView 自己的 first responder，与本状态无关、不受影响。

## 问题 2：摘除「任务开始自动展开」

- **摘除点**：BrowserDockView 的 `onChange(of: engine.sessionActive)` 开始分支——原逻辑 `layoutMode = .workingSize` 后 `if mode != .expanded { expand() }`，现只保留所有权迁移与 `scheduleSettle()`，**发送动作不再改变坞的形态**。文件头注释与迁移注释已同步改口径。
- **不变的部分**：视口锁定逻辑原样——会话期布局仍锁定工作尺寸；用户停在小窗发任务，坞保持小窗，页面以工作尺寸布局＋缩放渲染在小窗里实时可见（AGENT-VIEWPORT-FIX 迁移表第 2 行形态自任务第一步起即成立，不再需要先展开）；停在展开态则保持展开。会话终结的所有权交还与补落定 resize 不变。
- **登记（保留待口径）**：**介入场景（status 进入 waitingConfirm／waitingManual 的 .manual）的自动展开本轮保留不动**（`needsIntervention` 的 onChange 未改）——那是需要用户亲手确认／手输的场景。此行为保留、待 Joey 后续口径，若后续同样被否，再单独摘除。

## 问题 3：聊天输入栏提为最上层

### 层级结构（ContentView 的 ZStack，自下而上）

1. **对话消息层**（AgentChatView 瘦身后）：标题＋消息列表＋停止／继续按钮行。全屏常驻根层不变。
2. **浏览器坞层**（BrowserDockView）：expanded 全屏／mini 小窗，位置与形态逻辑不变。
3. **聊天输入栏层**（新增 `ChatInputBar`，自 AgentChatView 拆出）：输入框＋发送键。ZStack(alignment: .bottom) 最上层——坞怎么拖、怎么展开都盖不住它；背景为材质填充＋顶部分隔线，向底部安全区延伸填满；键盘升起时随根层安全区上浮、仍在最上层。发送逻辑（questionID／isNewTask／canSend 判定与 send() 全体，含问题 1 的收键盘）随组件一并搬移，语义逐字不变；`followLatest` 提升为 ContentView 的 @State 经 Binding 共享（消息层滚动跟随用）。

### 避让处理（连带碰撞）

- **消息层底部避让**：输入栏高度由 ContentView 以 `onGeometryChange` **实测**（草稿 1→3 行变高时随之变），经 `bottomInset` 下传消息层做等高底部留白——最后一条消息与停止／继续按钮行不被输入栏压住。
- **坞的底部保留线改实测推导**：原 DockGeometry 写死常量 148 改为 ContentView 推导后下传——`dockBottomReserve ＝ 输入栏实测高 ＋ 42`（42 ＝ 底部安全区上限约 34pt（坞几何区为全出血坐标，含 Home 指示条区，与 148 时代的坐标口径一致）＋ 8pt 余量）。**与旧常量的对应关系**：148 护的是旧层级下「输入行＋按钮行」两行区（约 34 安全区＋约 100 内容＋余量）；新层级按钮行回到消息层、只需护输入栏一行，故数值变小（单行栏约 56 实测＋42 ≈ 98）属预期，不是钳制放松。DockGeometry 的三个纯函数（clampedCenter／snappedCenter／defaultCenter）加 `bottomReserve` 参数（缺省仍是兜底常量 148，未收到下传值时行为与旧版一致）；坞内全部调用点改传实测值；输入栏变高时经 `onChange(of: bottomReserve)` 把已越线的小窗重钳回线之上。
- **展开态坞底内容避让**：介入 UI（ConfirmCard／手输提示＋「已处理，继续」）的底部 overlay 加 `.padding(.bottom, bottomReserve)`，停在输入栏之上、与输入口不重叠；右下「缩小」按钮的底部 padding 改为 `bottomReserve + 12`，同样抬到输入栏之上（此前它在坞的右下角，正是输入栏要占的位置）。
- **已知边界**：展开态下用户在输入栏打字（键盘升起）时，输入栏随键盘上浮，而坞内介入 UI 的避让量只按输入栏高计算、不含键盘高——此时介入卡片可能被键盘／上浮的输入栏遮挡；先收键盘（下滑列表／点按消息区，问题 1 的手势在展开态盖住消息层时不可用，但发送即收、点坞内网页区不收对话键盘这一点与既有行为一致）即可见。此为低频组合，未在本轮做键盘高联动，登记备查。

## 红线核对（git diff 实查，相对基线 fix/agent-viewport-lock 共 3 文件）

- 改动文件仅 `AgentChatView.swift`、`ContentView.swift`、`BrowserDockView.swift`；`MikaWebApp.swift`（AppObjectGraph 单持有者形态）**零改动**；`SafetyPolicy.swift`、`BrowserView.swift`（WebSurface）、`AgentEngine.swift`、`WebController.swift` **零改动**——付款／同意确认、密码框不填的判定与拦截全部保留。
- ConfirmCard 的防重复执行守卫字段逐字保留（含 summary／question 全字段比对，重写拆分时曾漏 summary 一行、已当场补回并经 diff 复核）。
- 浮窗双态、视口所有权（DockLayoutMode＋sessionActive）、落定真 resize、标签模型与执行页绑定、FIX2 输入注入与硬校验，全部未动；本轮唯一行为摘除是问题 2 的任务开始展开（Joey 亲否），介入自动展开保留并已登记。

## 过程注记（Release 首轮失败）

首版提交（24033de）Release Run 41403473732 编译失败：ContentView 把 `$chatInputFocused`（`FocusState<Bool>.Binding`）传给声明为 `Binding<Bool>` 的坞参数——FocusState 的 Binding 与普通 Binding 不互通，Release 编译器实证报错（ContentView.swift:21）。修法：坞参数类型改 `FocusState<Bool>.Binding`（与对话层一致，提交 1bea7b3）。同轮 CI（41403389898）曾回读 success 与 Release 结果矛盾，故二次 CI 起改以日志含真实编译步骤＋结论双核对为准，不只认 conclusion 字段。

## 自验记录

- validate_project.py 全 PASS；CI 两轮 success（Debug 模拟器真编译，最终代码 88c44c5 对应 41404192796）；Release success＋ASC 回读 VALID＋组挂载回读（见文首）。
- 静态走查：发送成功（两条路径）→ 焦点置 false、草稿已清、输入框高度随内容复位；被拒路径焦点保留。消息列表拖动＝.interactively 收键盘；点按 simultaneousGesture 与 ConfirmCard 按钮共存（只收键盘不拦截）。坞切 expanded → 对话焦点被收；mini 态不写入焦点。任务开始 → sessionActive 只迁所有权不改 mode（diff 实查 expand() 在该分支已无调用）。层级：ZStack 顺序消息层→坞→输入栏，输入栏带 onGeometryChange 实测；bottomInset／bottomReserve 两处下传均接在实测值上；坞内钳制函数全部调用点已换实测参数（grep 实查无遗漏的旧签名调用）。
- 键盘行为属系统级交互，无模拟器自动化可验，靠 Joey 真机清单兜底。

## Joey 真机复测清单（装 TestFlight 最新 202611020708）

问题 1（键盘）：
1. 对话里发一条任务消息：发送成功瞬间**键盘自动收起**，输入框回到单行，不再占半屏。
2. 再点输入框唤起键盘，**手指下滑拖动消息列表**：键盘应跟着手指交互式收起；重新唤起后**点按任意一条消息／空白处**：键盘收起。
3. 发送失败的情形（如未配密钥时发任务）：键盘与草稿应保留，能直接改完重发。

问题 2（不自动展开）：
4. 把浏览器停在**小窗**，发一条任务：坞**保持小窗不放大**，任务照常跑，小窗里能实时看到页面（整页缩小画面）；点一下小窗仍可手动展开。
5. 把浏览器停在**展开态**发任务：保持展开，不跳变。

问题 3（输入口最上层）：
6. 小窗态把小窗**往最底部拖**：拖不到输入口上（下界停在输入栏之上），输入框与发送键始终可见可点。
7. 展开态：输入口浮在全屏浏览器之上，直接在里面打字、发送，流程正常；右下「缩小」按钮在输入栏上方、不被压住。
8. 展开态触发介入（确认卡片或密码手输等待）：卡片／提示停在输入栏之上，与输入口不重叠，可正常点「执行／跳过」或「已处理，继续」。

回归（顺带）：
9. 介入时（确认／手输）的自动展开仍在（本轮保留）：小窗态任务跑到需要确认时坞应自动展开——若你觉得这个也突兀，回我一句，下一轮摘除（案卷已登记）。
10. 闪退红线：展开态点网页多次＋滚动不崩；标签页切换不重载；视口锁定（任务中收起只缩放渲染）与 0645 一致。
