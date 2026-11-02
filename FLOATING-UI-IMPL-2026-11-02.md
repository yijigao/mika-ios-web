# Mika Web 悬浮窗 UI 改造实现记录（2026-11-02）

需求（Joey 13:27 亲令，13:33 批准开工）：现并屏／半屏对话体验差——对话全屏为主，操作端（浏览器）可缩小成悬浮窗、随时复原查看。选型依据 `~/workspace/mika-ios-eval/FLOATING-UI-RESEARCH-2026-11-02.md`（结论：不引现成库、自研手势浮窗）。

**交付构建：202611020540**（0.1.0，build id `3175f80c-b228-4384-b8ea-67d059a64382`）
- 分支 `feat/floating-browser-dock`（自 `fix/app-holding-form` 新开，未合 main、未合 fix 分支），代码提交 `619feaa`。
- CI Run 41395277316 success（Debug 模拟器编译）；Release Run 41395382176 success。
- ASC 回读：processingState=**VALID**、expired=false、usesNonExemptEncryption 已 PATCH=false（HTTP 200）；Internal 组（6a722377-d7f3-4c76-876f-4c35e193e0e4）挂载 POST **204**，组内回读新构建居首。
- validate_project.py 全 PASS（18 个 Swift 源文件恰好登记一次）。

## 红线核对（git diff 实查）

- `MikaWebApp.swift` 持有形态（AppObjectGraph 单持有者，构建 202611020450 真机验证）**零改动**；
- `WebController.swift`／`BrowserView.swift`（含 WebSurface）／`AgentEngine.swift` **零改动**，业务逻辑与安全边界不变（付款／同意仍须用户屏幕确认、密码框 agent 不填）；
- 改动只落在布局层＋新增浮窗组件（下表）。

## 新增／改动文件清单

| 文件 | 性质 | 内容 |
|---|---|---|
| `MikaWeb/BrowserDockView.swift` | 新增 | 坞本体：`DockMode`、`DockGeometry`（几何纯函数）、`BrowserDockView`（状态机＋自动展开接线）、`MiniShieldView`（小窗手势护盾） |
| `MikaWeb/ContentView.swift` | 改 | 根布局由 VStack 并屏改为 ZStack：`AgentChatView` 全屏常驻根层＋`BrowserDockView` 盖其上；导航栏／工具栏／PendingTask 消费逻辑不变 |
| `MikaWeb/AgentChatView.swift` | 改（布局层 2 处） | ① 消息列表 `.frame(maxHeight: 240)` 改 `.infinity`（并屏时代上限，对话全屏后去除）；② `ConfirmCard` 由 `private` 改内部可见，供坞内复用同一张卡片 |
| `MikaWeb.xcodeproj/project.pbxproj` | 改 | 登记 BrowserDockView.swift（fileRef 03D／buildFile 03E，组子项＋Sources 阶段各一处） |

## 状态机与手势实现要点

- **双态＋手势瞬时态**：`DockMode = {expanded, mini}`；拖动是 mini 上的瞬时手势状态（dragDelta），不单独成态；收放的动画中间过程由弹簧插值呈现。动画＝`.spring(response: 0.42, dampingFraction: 0.86)`，由 mode 变化驱动，触发瞬间 mode 即切换——展开动画中护盾已消失、页面可触；收起动画中护盾已生效、可再点按反向展开（新手势可打断重定向，不存在「动画没完点不动」）。
- **保活几何（核心）**：坞内 `BrowserView` 的布局尺寸恒为展开态全尺寸（`.frame(area)`），缩小只走 `.scaleEffect` 渲染变换＋外层 visual frame（＝布局尺寸×缩放比）承接裁剪／描边／阴影／覆盖层＋`.offset` 按中心点定位。WKWebView 自身 frame 在双态间永不变化：页面不重排、不重载、JS 不停、滚动位置与表单状态保留。
- **小窗尺寸**：等比缩放（整页可见）。缩放比＝min（目标宽度 屏宽×0.44 并钳制 150–184pt，高度上限 屏高×46%）。以 393×759 逻辑区为例：缩放比 0.44，小窗约 173×334pt。
- **拖动与吸附**：护盾 DragGesture（minimumDistance 0）跟手移动（无动画事务，无弹簧滞后）；松手以 `predictedEndTranslation`（含甩动速度的速度采样）投影落点，横向弹簧吸附到最近的左／右边缘，纵向钳制进合法区间。
- **位置钳制**：中心合法区间＝左右不越边缘（留白 10pt）、上不越顶边、下不越「底部保留线」（容器高−148pt，约对话输入区高度，避免长期遮住输入栏）。停靠位以占容器宽／高的比例记入 AppStorage，冷启动恢复后按当前容器尺寸钳制；容器尺寸变化（旋转）时同样再钳制。
- **键盘**：坞层 `.ignoresSafeArea(.keyboard)`——键盘弹起时坞坐标系不变，小窗保持屏幕坐标（允许被键盘短暂遮挡）；对话层不受影响，输入栏照常被键盘顶起。
- **护盾 MiniShieldView**：仅 mini 态存在，覆盖小窗全部面积并拦截一切触摸（近透明填充＋contentShape 保证命中），页面触摸绝不下传 WKWebView；位移 <8pt 判点按＝展开，≥8pt 判拖动。小窗底部有「展开」提示胶囊（纯视觉、禁命中）。expanded 态护盾不存在，浏览器正常交互；坞右下角有缩小按钮（pip.enter 图标）回 mini。
- **定位方式**：ZStack（topLeading 锚）＋offset，未用 `.position`（v0.2.1 前车之鉴：全屏 GeometryReader＋ZStack＋.position 覆盖层曾是嫌疑构造，已弃用该组合）；GeometryReader 在本实现中只读容器尺寸。

## 自动展开接线（接既有信号，不新造逻辑）

接线点在 `BrowserDockView`：计算属性 `needsIntervention` 对 `AgentEngine` 已发布状态做模式匹配，`.onChange` 由 false→true 时 `expand()`：

1. **执行前确认**：`engine.status == .waitingConfirm(action)`（SafetyPolicy 判 .confirm 的既有路径）→ 展开；且坞底浮层直接渲染 `ConfirmCard`（与聊天区同一组件、同一 `engine.confirm` 提交路径，卡片内部有状态一致性守卫＋locked 防重复，两处实例并存不会双重执行）。
2. **密码／验证码手输**：`engine.status == .waitingManual` 且 `engine.waitingInput == .manual(id, text)`（SafetyPolicy 判 .manual 的既有路径）→ 展开；坞底浮层给出与聊天区同文案的提示＋「已处理，继续」按钮（`engine.resume()` 同一路径）。
3. ask_user 提问（`waitingInput == .question`）在对话层作答、mini 态对话完全可见，**不**触发展开。

## 与选型报告／本单的差异说明

1. **选型报告磁盘文件不完整**：`FLOATING-UI-RESEARCH-2026-11-02.md` 落盘内容在第 ③ 节中途截断（④ 风险与 ⑤ 组件清单／测试矩阵未落盘，文件终于「（默认停靠位可记」）。本实现按派工单正文（已内嵌报告的保活注记与组件命名）＋报告 ①–③ 已落盘部分执行，测试矩阵按派工单交付标准里列明的真机项重构成本文清单。
2. **小窗尺寸**：报告给 168×104pt「量级」示例，但同时要求整页等比缩小；手机竖屏页面纵横比与 168×104 冲突，二者取等比优先（见上「小窗尺寸」），数值均为 `DockGeometry` 内单行常量，真机手感不合可一行调整。
3. **AgentChatView 两处改动**超出「只动 ContentView」的字面范围：均为布局层（列表高度上限、组件可见性），业务逻辑零改动；理由分别是对全屏对话的必要条件与确认卡片复用的最小改动，已在文件清单中明示。

## 自验记录（模拟器／静态层）

- validate_project.py 全 PASS；CI（Debug，iOS Simulator）编译 success——Swift 语法与工程完整性已过编译器。
- 几何纯函数人工算例核对（393×759）：缩放比 0.44；默认停靠中心 (296.5, 440)，小窗纵向跨度 273–607，底边在输入保留线（611）之上；中心钳制区间 x∈[96.5, 296.5]、y∈[177, 444]；吸附取 predicted 落点近侧边缘，边界值行为符合预期。
- Release run success＋ASC 回读 VALID＋组挂载回读（见文首）。

## Joey 真机验收清单（以下只能真机验，本单未验）

装 TestFlight 最新 **202611020540** 后逐项：

1. **闪退红线回归**：展开态点网页多次＋上下滚动，不崩（持有形态修复不得回退）。
2. **拖动吸附**：把小窗拖到屏幕各处松手——吸附到最近的左／右边缘；不越过屏幕顶部；拖不到输入栏以下。
3. **连续收放 30 次**：点小窗展开 → 右下角按钮收起，循环 30 次——不崩；找一个已滚动到中段或已填字的页面，收放后页面不重载、位置／内容不丢。
4. **mini 态长任务**：收起小窗，在对话里发一个多步网页任务——小窗内页面实时变化（agent 在持续操作），任务在对话层跑完，全程不需展开。
5. **确认卡片自动展开**：任务触发付费／同意类确认时，坞自动展开且确认卡片出现在坞底部，「执行」「跳过」可点、生效。
6. **密码框自动展开**：任务遇到密码／验证码字段暂停时，坞自动展开；在网页手填后点坞底「已处理，继续」，任务续跑。
7. **键盘场景**：对话输入框打字时键盘弹起，小窗不跳位；展开浏览器后点地址栏输网址、回车加载正常。
8. **位置记忆**：把小窗拖到左侧，杀 App 重开——小窗回到左侧记忆位置附近。
9. **对话全屏**：消息列表可长滚动、输入发送正常；小窗挡住处可拖开，无其他遮挡问题。
