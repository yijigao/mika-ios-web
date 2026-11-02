# Mika Web 介入呈现定版（摘净自动展开＋介入 UI 进对话，2026-11-02）

需求（Joey 2026-11-02 16:01 拍板）：**任何自动展开都不要了**——agent 需要用户介入（确认敏感操作／手动输入）时，只在对话里提示，用户自己决定点不点开浏览器。CHAT-KEYBOARD-FIX 案卷里登记的「介入时自动展开保留、待 Joey 后续口径」就此销案：口径＝去掉，改对话内提示。

**交付构建：202611020808**（0.1.0，build id `cdc2426b-41d0-488c-8996-63b035b8c70c`）
- 分支 `fix/intervention-chat-prompt`（自 `fix/chat-keyboard-dismiss` 新开，未合 main、未合任何其他分支），代码提交 `84ba57f`。
- CI Run 41410531099 success（Debug 模拟器真编译：日志双核对——SwiftCompile 编译行实查，三个改动文件 AgentChatView／BrowserDockView／ContentView 均在编译行内出现，另有 `** BUILD SUCCEEDED **`，不只认 conclusion；注：本机 Xcode 日志的编译步骤名是 SwiftCompile，与 0708 案卷所记 CompileSwiftSources 是同一步骤的不同日志措辞）。
- Release Run 41410761360 success。
- ASC 回读：processingState=**VALID**、expired=false、usesNonExemptEncryption 已 PATCH=false（HTTP 200 后回读确认 false）；Internal 组（6a722377-d7f3-4c76-876f-4c35e193e0e4）挂载 POST **204**，组内回读 0808 居首 [202611020808, 202611020708, 202611020645, 202611020636]（注：组 builds 端点不接受 sort 参数，按 uploadedDate 字段客户端排序核对）。
- validate_project.py 全 PASS（19 个 Swift 源文件）。

## 改动点

### 1. 摘净介入自动展开（BrowserDockView.swift）

- 删除 `.onChange(of: needsIntervention)` → `expand()` 的接线（0540 起的介入自动展开至此摘净）；文件头、结构体注释、sessionActive 迁移注释同步改口径。
- `needsIntervention` 计算属性保留，但只驱动小窗状态提示（见第 4 点），不再触发任何形态变化。
- 新增用户路径：坞加 `expandRequest: Int` 参数（ContentView 持有的令牌），`onChange(of: expandRequest)` 时展开——触发源是用户在对话介入卡上点「打开浏览器查看／打开浏览器」，与护盾点按同级。
- **expand( 调用点清单（grep 自证，`MikaWeb/` 全目录）**：实际调用仅两处，均为用户动作——
  - `BrowserDockView.swift` `shieldDragEnded`：护盾点按（位移 <8pt 判点按）→ `expand()`（存量用户路径）；
  - `BrowserDockView.swift` `onChange(of: expandRequest)`：介入卡打开按钮（本轮新增的用户路径）。
  - 其余命中只有函数定义本身与注释文本。`collapse()` 调用点不变（展开态右下收起按钮，用户动作）。engine 的任何状态信号（sessionActive／status／waitingInput）都不再有通往 expand() 的路径。

### 2. 介入 UI 进对话（核心，AgentChatView.swift＋ContentView.swift）

- 新增 `InterventionPrompt` 组件（AgentChatView.swift），由 ContentView 以独立层渲染：ZStack 自下而上为 消息层 ＜ 浏览器坞 ＜ **介入卡** ＜ 聊天输入栏；卡片固定在输入栏上方（底部 padding＝输入栏实测高＋6、左右 12），**小窗与展开态都可见可点**（展开态它浮在全屏浏览器之上、输入栏之下）。ContentView 用 `showsInterventionPrompt` 同口径判定（`.waitingConfirm`，或 `.waitingManual` 且 waitingInput 为 `.manual`）决定是否入层，无介入时该层不存在。
- **确认卡**（waitingConfirm）：复用 `ConfirmCard` 并扩展呈现——待确认动作**全字段不删减**：动作／目标序号、元素摘要 summary、拟输入内容 text、目标网址 url、理由 reason（非空逐项成行），再加**所在页面标题／域名**（按执行页取：`tabTitle(for: executionTabID ?? activeTabID)`＋`executionTab.urlString` 的 host，不用当前页冒充——任务绑在哪个标签页就显示哪个）。按钮三个：「确认执行」「拒绝」「打开浏览器查看」。确认／拒绝仍走 `ConfirmCard.submit` 的 locked＋taskID＋全字段比对守卫 → `engine.confirm(execute:)`，**防重复守卫与确认语义一字未改**；「打开浏览器查看」不走守卫，只递增 expandRequest 令牌展开坞（用户主动）。
- **手输卡**（waitingManual＋.manual）：标题「需要你手动处理」＋说明文字（沿用引擎既有文案来源：waitingInput.manual 的 text，如「请手动填写密码或验证码后继续」「密码或疑似验证码字段，请在网页手动填写后点继续」）＋「完成后点击『已处理，继续』」＋按钮「打开浏览器」「已处理，继续」（后者走 `engine.resume()` 既有路径）。
- ask_user 提问（waitingInput 为 .question）不出卡，仍在输入栏作答（既有口径不变）。

### 3. 坞底旧 UI 的处置：收起（删除）

- 选择：`BrowserDockView` 的 `interventionOverlay`（坞底确认卡／手输提示）**整体删除**，含其 `.overlay(alignment: .bottom)` 挂载点。
- 理由：原则是同一时刻只有一个可点的主入口。若保留坞底卡，展开态会出现「坞底卡＋对话置顶卡」双卡并存——两张 ConfirmCard 虽各有内部守卫、防双重执行，但双入口本身即状态打架与误点来源；且置顶卡在小窗／展开两态都可见，坞底卡没有不可替代的场景。故收起坞底、只留对话置顶卡。
- 连带处置（同原则，均为呈现层）：
  - AgentChatView 消息流里的内嵌 ConfirmCard 与手输提示 Text **摘除**（否则小窗态与置顶卡双卡并存；列表只剩消息本体）。
  - AgentChatView 按钮行的手输续跑**让位**：`canResume` 不再覆盖 `.waitingManual`、按钮文案恢复恒为「继续」（暂停／失败的续跑不变），「已处理，继续」由置顶手输卡独占。
  - 已知几何关系（登记备查）：介入期间展开态右下「缩小」按钮可能被置顶卡覆盖——与 0708 坞底卡时代的几何关系一致（当时坞底卡同样盖住该按钮），处理完介入即恢复，不在本轮另做联动。

### 4. 小窗状态提示（BrowserDockView.swift）

- mini 态且 `needsIntervention` 时，小窗顶部居中加胶囊：橙色圆点＋「等你处理」（.ultraThinMaterial 底）。**只提示、不展开、不可点出动作**：`allowsHitTesting(false)`，点按仍落在护盾上（＝用户点按展开，允许的用户路径）。展开态不显示（卡片本身就在眼前）。

## 红线自查（git diff 相对基线 fix/chat-keyboard-dismiss）

- 改动文件仅 3 个：`AgentChatView.swift`、`BrowserDockView.swift`、`ContentView.swift`（156 insertions／63 deletions）。
- `MikaWebApp.swift`（AppObjectGraph 单持有者形态，闪退定案）**零改动**；`SafetyPolicy.swift` **零改动**；`BrowserView.swift`（WebSurface）**零改动**；`AgentEngine.swift` **零改动**——等待状态机语义、confirm／resume 路径、ConfirmCard 防重复守卫全字段比对均原样（只改呈现层订阅与坞触发）；`WebController.swift` **零改动**（只读用其既有 tabTitle／executionTab 接口）。
- 凭据／Keychain 逻辑未碰；无新依赖（pbxproj 未动，validate 佐证 19 个源文件恰好登记一次）。
- 不回归项静态核对：sessionActive → DockLayoutMode 视口所有权迁移两点原样（任务期锁工作尺寸、终结交还，仅注释口径更新）；键盘收起三件套（ContentView 集中 @FocusState、发送真成功路径收键盘、列表 .scrollDismissesKeyboard(.interactively)＋点按收起、坞切 expanded 代收对话焦点）代码未动——且介入卡打开按钮展开坞时，mode 的 onChange 仍会顺带收对话键盘，与存量行为一致；ChatInputBar 最上层层级与 inputBarHeight 实测下传（消息层避让、坞 bottomReserve 推导）未动，介入卡插在坞与输入栏之间、不改变输入栏居首；标签页模型与执行页绑定、FIX2 输入注入与硬校验未动。

## 自验记录

- validate_project.py 全 PASS；CI success＋日志双核对；Release success；ASC 回读 VALID＋组挂载回读（见文首）。
- 静态走查：① 小窗态 status 进入 waitingConfirm → needsIntervention 只点亮小窗橙点提示，mode 无任何写入路径（grep expand( 清单见第 1 点）；ContentView 入层出置顶卡，三按钮齐备、守卫在位。② 点「打开浏览器查看」→ dockExpandRequest +1 → 坞 onChange 展开，展开后卡片仍在（层在坞之上），可继续点确认／拒绝。③ 手输等待同理：「已处理，继续」走 engine.resume()，status 变化后 showsInterventionPrompt 转假、卡片自动消失。④ 展开态介入：置顶卡浮于浏览器之上、输入栏之下，标题／域名按执行页显示（用户切页不串）。⑤ 任务开始：sessionActive 只迁视口所有权不改 mode（0708 行为保持）；介入全程坞形态只随用户动作变。
- 呈现属系统级 UI 交互，无模拟器自动化可验，靠 Joey 真机清单兜底。

## Joey 真机复测清单（装 TestFlight 最新 202611020808）

重点（本轮新行为）：
1. **小窗态触发确认、坞纹丝不动**：把浏览器收成小窗，发一个会触发付费／同意类确认的任务——跑到确认点时坞**保持小窗不自动展开**，对话里（输入栏上方）出现确认卡，小窗顶部出现橙点＋「等你处理」。
2. **确认卡内容与处置**：卡上动作、元素摘要、理由、页面标题（域名）齐全；点「确认执行」任务续跑、点「拒绝」跳过该步（各验一次）。
3. **点「打开浏览器查看」才展开**：在确认卡上点该按钮，坞才展开（你主动点的）；核对网页后收起回小窗，卡片仍在、可继续处理。
4. **手输提示同理**：任务遇到密码／验证码框暂停时，坞不自动展开，对话出「需要你手动处理」卡（写明要填什么）；点「打开浏览器」展开、手填，再点卡上「已处理，继续」续跑（展开态直接点卡上的按钮即可，不必切回对话找按钮）。
5. **展开态触发介入**：浏览器保持展开态发任务，确认／手输卡出现在输入栏上方、浮在浏览器之上可直接点；小窗状态点不出现（本就是展开态）。

0708 三项不回归（顺带）：
6. **键盘**：发送成功自动收起；下滑消息列表交互式收起；点按消息区收起；发送失败保留草稿与焦点。
7. **任务开始不改变坞形态＋视口锁定**：小窗发任务保持小窗、展开保持展开；任务中收起只缩放渲染、工作视口不被压窄，任务能办成（如小窗态知乎写回答）。
8. **输入口最上层**：小窗拖到最底部压不住输入口；展开态输入口浮在浏览器之上可打字发送。

回归（顺带）：
9. 标签页切换不重载、任务绑执行页（展开态切页有「任务在标签页…执行中」提示）；展开态点网页多次＋滚动不崩（闪退红线）。
