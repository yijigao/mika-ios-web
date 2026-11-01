# PLAN-V022-ASTRA — 按栈定界结论（Astra，effort high，2026-11-02）

- 输入：STACK-EVIDENCE-2026-11-02.md 全文＋CRASH-HUNT-V022.md＋关键源码（HEAD）。
- **VERDICT：NOT_LOCKED**——证据能锁定「触摸后 UIKitCore 在 UpdateCycle 内走到同一条插入 nil 的异常路径」，不能锁定是哪一个 App 构造触发，更不能确定 nil 是 responder、输入辅助对象还是手势对象。此时直接删 `.focused` 或换输入框仍属按嫌疑盲修。
- 按主聊派工的硬性分流纪律：**本轮不发盲修版，改发开关版**（CRASH-HUNT §4），执行序以 Astra 本结论为准：全开验崩 → 单关 F_FOCUS → 单关 F_INPUT → F_SCROLL → F_CHAT → F_PANELSTATE → F_OBSERVE → F_CONVSINK → F_PANELSINK → F_DIAG → F_GEO（每步各自从全开基线出发、不累计关闭；止崩后做恢复复现＋再单关验证）。
- 条件性最小修复（仅当 F_FOCUS 对照成立才启用）：删 AgentChatView.swift 第 53 行 `.focused(inputFocused)`——目前只是开关版的实验分支，不得声称已切断机制。
- Astra 的关键事实修正：1652 的 AgentConsoleView 已有同款纵向 TextField（无 `.focused` 连接、分区布局）——新增嫌疑是 `.focused` 连接＋条件挂载＋浮层共存环境，不是纵向 TextField 本身；App 内未发现自定义 inputAssistantItem/inputAccessoryView/键盘 toolbar。
- 红线检查：开关定界与条件性最小规避均不需要改动任何红线文件。

以下为 Astra 原文（完整保留）：

---

**VERDICT：NOT_LOCKED。**

现有证据能锁定“触摸后，UIKitCore 在 UpdateCycle 内走到同一条插入 nil 的异常路径”，**不能锁定是哪一个 App 构造触发，更不能确定 nil 是 responder、输入辅助对象还是手势对象**。现在直接推荐删除 `.focused` 或改成单行输入框，仍属于按嫌疑修复。

已只读核对源码和提交差异，未修改代码。

**1. 已成立的边界，以及一项关键修正**

- 接受四份报告所确认的 **1747、1811 同源**；不再安排旧案卷的 Z1/Z2。
- 全屏覆盖层、聊天 `simultaneousGesture`、滚动动画已被移除而同源崩溃仍在，因此它们不是这条故障的必要条件。1811 独有的尺寸回写也解释不了 1747。
- 红线代码没有变化；但父树变化是否导致 WKWebView 重新挂载，不能由代码未改推出。
- **1652 已有 `TextField(axis: .vertical).lineLimit(1...3).textFieldStyle(.roundedBorder)`**，见 [AgentConsoleView.swift:20](/home/hatch/workspace/mika-ios-web/MikaWeb/AgentConsoleView.swift:20)，历史提交 `3165943` 同样如此。新增嫌疑是它的 **`.focused` 连接、条件挂载及浮层共存环境**，不是纵向 TextField 本身。
- 1652 也有条件显示的 `ScrollView + LazyVStack`；v0.2 的差别包括消息滚动容器常驻、增加 `ScrollViewReader`、自动定位以及新的挂载环境。
- 未发现自定义 `inputAssistantItem`、`inputAccessoryView` 或键盘 toolbar。现有导航 toolbar 在基线中已有，不能据此指认输入辅助栏。

当前能写出的机制链只有：

> 手指触摸网页〔复现事实〕  
> → **未知：本次触摸牵动了哪个输入、手势或层级状态**  
> → UpdateCycle 3060  
> → UIKitCore 434956 → 435564 → 440156 → 932180 → 6162088  
> → 970768 → 963116 → 963760 → 963900 → 6172552  
> → 数组插入 nil，抛出 NSInvalidArgumentException  
> → 未捕获异常导致 abort。

中间的未知环节正是定界缺口。**栈里没有 App 业务帧，说明抛出时没有这些帧；不代表此前没有 App 状态变化，也不证明发生了 first responder 转移。** 同样，`UpdateCycle` 的出现不能单独证明发生了 SwiftUI `body` 重算或某一种对象集合的“重建”。

**2. 仍存活的候选，按优先概率排序**

以下是排查排序，不是已测得的概率。

| 顺位 | 具体构造 | 支持与限制 | 还缺什么才能锁定 |
|---|---|---|---|
| 1 | [AgentChatView.swift:52](/home/hatch/workspace/mika-ios-web/MikaWeb/AgentChatView.swift:52) 的纵向 TextField **连接 `.focused(inputFocused)`**；绑定来自 [ContentView.swift:10](/home/hatch/workspace/mika-ios-web/MikaWeb/ContentView.swift:10)，控件条件挂载 | 这是两版共同保留、1652 没有的连接点。可以影响焦点参与关系；但没有证据证明网页触摸实际进入了它，也没有“失焦后悬空”的证据 | 仅去掉 `.focused` 即稳定恢复、重新启用即复现；再取得匹配符号或异常断点，确认失败对象与该连接有关 |
| 2 | [AgentChatView.swift:30](/home/hatch/workspace/mika-ios-web/MikaWeb/AgentChatView.swift:30) 的常驻 `ScrollViewReader → ScrollView → LazyVStack` 与网页重叠共存 | 无需引擎发布就可能参与触摸处理；但两个兄弟滚动区域共存本身不证明有手势冲突 | 单关 F_SCROLL 消失、恢复复现；随后拆分 Reader、滚动容器和惰性布局，并确认系统帧是否属于手势处理 |
| 3 | 同一输入栏中的**原生文本输入控件，在无 `.focused` 时仍参与文本交互** | 去掉 FocusState 不会移除控件自身的文本交互。1652 同款输入框不崩，是“控件类型本身致崩”的强反例，因此只能保留“新挂载环境中的交互”版本 | F_FOCUS 关仍崩、F_INPUT 关不崩；随后在保持布局和绑定条件下对照输入控件类型，并取得真实底层控件及失败对象证据 |
| 4 | [ContentView.swift:13](/home/hatch/workspace/mika-ios-web/MikaWeb/ContentView.swift:13) 新父树下的层级更新／重挂载，可能被观察发布触发 | 红线代码未变不能排除它；但 BrowserView 不在展开分支内，也没有发现明确的身份切换语句，故低于前三项 | 触摸前后出现实际发布、挂载迁移或 Store 重建，并且与失败时序吻合；只记录 WKWebView 地址不变不足以排除同实例重新挂载 |

`conversation.bind`、`panel.bind` 暂不单列为高位候选：缺少“网页轻触 → 对应 engine 发布”的桥梁。MetricKit 同样缺少触摸关联事件，保留 F_DIAG 作低优先级排除即可。

此外，“纵向 TextField 在这台系统上具体由哪个 UIKit 类承载”也应以运行时为准，不能用未经验证的 `UITextView` 底座假设补全机制链。

**3. 开关版：最先单关 F_FOCUS，再单关 F_INPUT**

这两个实验**各自从全开基线出发，不累计关闭**。

先关 F_FOCUS，因为它只删除一个新增连接，保留原有多行输入能力，辨别力最细。然后恢复它、单关 F_INPUT，判断是否必须移除整个输入控件才能消失。Apple 文档确认 `.focused` 负责双向连接焦点状态；但这份 API 契约本身并不能证明当前崩溃由它造成。[Apple：focused(_:)](https://developer.apple.com/documentation/swiftui/view/focused%28_%3A%29)

| 仅关 F_FOCUS | 仅关 F_INPUT | 判读 |
|---|---|---|
| 不崩 | 不崩 | 优先收敛到焦点连接；仍需恢复复现与内部路径证据 |
| 仍崩 | 不崩 | 输入控件参与是强证据，显式 FocusState 连接不是必要条件 |
| 仍崩 | 仍崩 | 转向消息滚动容器及父树 |
| 不崩 | 仍崩 | 不符合简单包含关系；先查占位布局、分支身份、配置和崩溃签名，不能宣布锁定 |

**F_INPUT 关闭时 `.focused` 的目标也不存在，因此它不是与 F_FOCUS 完全独立的因素。** “两个开关都能止崩”不是两份独立机制证明。

建议执行顺序：

1. **全开验崩**，核对仍是原 UIKitCore 帧链。
2. **F_FOCUS → F_INPUT**，各自单关。
3. 若两者均失败：**F_SCROLL → F_CHAT → F_PANELSTATE**。
4. 若仍未收敛：**F_OBSERVE → F_CONVSINK → F_PANELSINK → F_DIAG → F_GEO**。

其中：

- F_CHAT 止崩而前三个局部开关均无效，提示剩余聊天结构或交互组合；不等于已证明整个聊天视图是“单一根因”。
- F_PANELSTATE 是新构建的冷启动结构对照，不是重做已作废的旧 Z2。
- F_OBSERVE 若只去掉聊天子树订阅，**不能排除 ContentView 自己的观察扇出**。
- F_GEO 即使止崩，也只能说明它影响 1811 的表现，不能解释两版共同起因。

每种配置冷启动读取；固定页面、加载完成状态和操作前置条件。无崩配置至少重复五次独立冷启动及触摸；崩溃配置记录首次触摸结果和签名。出现止崩配置后做“恢复全开复现 → 再单关止崩”。

观测除实例标识、发布计数、expanded/focus 外，还应记录 **WKWebView 的 superview/window 身份与挂载变化**。这些可从非红线的诊断观察点或调试器采集，不必修改 WebSurface。

**条件性最小修复方案：**若 F_FOCUS 的对照成立，首选仅删除 [AgentChatView.swift:53](/home/hatch/workspace/mika-ios-web/MikaWeb/AgentChatView.swift:53) 的 `.focused(inputFocused)`。它切断的是“聊天输入控件接入显式 SwiftUI 焦点绑定”这一环；多行输入保留，但现有 `inputFocused = false` 不再控制该输入框，收起时键盘行为需要回归验证。**目前只能把它作为开关版实验分支，不能声称已切断 nil 插入的完整机制。**

**4. UIKitCore 偏移簇归属**

| 偏移 | 当前可确认的范围 | 函数族归属把握 |
|---|---|---|
| 6172552 | 摘要中最靠近异常的 UIKitCore 帧 | 无法可靠归类 |
| 963900／963760／963116／970768 | 连续调用路径的一部分 | 无法可靠归类 |
| 6162088、932180 | 上述路径的上游调用帧 | 无法可靠归类 |
| 440156／435564／434956 | 靠近 UpdateCycle 的调用段 | 无法区分输入更新、手势处理或其他 UIKit 更新 |

精确偏移检索未找到可核验匹配。**不能把这些数字命名成 responder chain、input assistant 或 gesture dependency rebuild。** 地址接近也不是函数族证据。

下一步符号化应针对报告对应的 **UIKitCore 二进制 UUID、架构及系统构建**，优先取得 6172552 和 963900 簇的符号；MikaWeb 的 main 帧不是定位重点。Apple 明确要求系统符号匹配报告的系统版本与架构。[Apple：崩溃报告符号化](https://developer.apple.com/documentation/xcode/adding-identifiable-symbol-names-to-a-crash-report)

**红线检查：**上述开关定界与条件性 `.focused` 最小规避均不需要改动 SafetyPolicy、WebController、PageState、ModelClient、Keychain、WebSurface、SelfTestView 或 MikaWebIntents。当前不推荐修改其中任何一项。