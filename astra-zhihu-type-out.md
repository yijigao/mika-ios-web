**结论：第四轮首选验证“纯文本粘贴→框架接收→状态提交”的完整链路；备选是页面编辑器自身的事务 API。当前不能把根因定为 `isTrusted=false`。出包门槛必须落到同一 WKWebView 中的真实框架状态，保留现有 fail-closed。**

先补正咨询包里的两个关键事实：

- 代码已经包含粘贴路径，Draft 分支实际顺序是 `paste → events → chunks → exec → range`。按这份源码，“5 种失败”包含粘贴失败。现有粘贴同时发送 `text/plain` 和 `text/html`。[输入实现](/home/hatch/workspace/mika-ios-web/MikaWeb/WebController.swift:1974)
- 真 Draft.js 测试页也已存在，使用 React 17.0.2＋Draft.js 0.11.7；旧案卷记录的通过环境是 **Playwright Chromium**，WKWebView 的事件构造和知乎包装层仍列为未证项。因此，“新增粘贴”“换真 Draft demo”都不足以构成第四轮修复。[旧验收记录](/home/hatch/workspace/mika-ios-web/ZHUANLAN-FIX2-IMPL-2026-11-03.md:64)

**第一问：根因排序。**

先区分两个问题：四条增量/DOM 路线为什么容易失败，已有较强机制解释；**paste 为什么也失败，仍未定位。**

候选表漏了一项最关键机制：**原生事件与框架输入协议不匹配。** React 官方文档明确说明，`onBeforeInput` 并不直接使用原生 `beforeinput`，而是通过其他事件模拟。因此，构造完整的 `InputEvent('beforeinput')`，也可能完全没有进入 Draft 的字符处理器；这与传播路径正确、`composed:true` 并不矛盾。[React 官方说明](https://react.dev/reference/react-dom/components/common#common-props)

另外，Draft 的 `onInput` 确实存在 DOM→状态回收，但它围绕当前选区锚点对应的 **leaf** 做对账，需要有效的 `data-offset-key` 映射。它不是“重新读取整个 contentEditable”的接口。整文替换、原生分段、Range 重建节点，都可能破坏这些前提，事后补 `input/change` 无法保证恢复。[Draft 输入处理源码](https://github.com/facebookarchive/draft-js/blob/v0.11.7/src/component/handlers/edit/editOnInput.js)

针对“包含 paste 的五路全败”，调查优先级如下；这是排查顺序，不是假装已算出概率。

| 顺序 | 候选 | 判断与判别依据 |
|---|---|---|
| 1 | **b 扩展：事件接入链不匹配** | 首查实际编辑宿主、事件目标、框架处理器是否执行，以及处理器收到的 `clipboardData`。仅记录 DOM 捕获到事件不够。 |
| 2 | **d 的包装层版本：知乎接管粘贴或丢弃状态更新** | 标准 Draft 允许 `handlePastedText` 接管。现有 HTML 数据可能引入额外处理分支；也可能生成了新状态，但上层受控组件没有接纳。不能据此断言知乎已完全换掉 Draft。 |
| 3 | **e：DOM 选区与内部 SelectionState 不一致** | 必查，但选区不同步通常更容易造成追加或错位；对空编辑器“0→0”，它单独的解释力有限。 |
| 4 | **c：WKWebView 焦点／第一响应者条件** | 可影响原生编辑路径，但不能直接推出 JS 粘贴处理器也必须依赖软键盘。需要真实点击聚焦与脚本聚焦的对照。 |
| 5 | **a：显式拒绝不可信事件** | 标准 Draft 粘贴处理器没有这一通用门槛。只有找到知乎包装层的具体拒绝分支，才能上升为主因。[粘贴处理源码](https://github.com/facebookarchive/draft-js/blob/v0.11.7/src/component/handlers/edit/editOnPaste.js) |

**最强反例：**标准 Draft 可以消费合成 paste，由处理器直接更新 EditorState；旧 Chromium 实验也记录过精确替换成功。这反驳“只要 `isTrusted=false` 就一定失败”，但不能证明知乎当前包装层也接受。

**还缺的关键证据：**同一干净编辑器中，系统粘贴、现有双格式粘贴、纯文本粘贴三组的完整记录：

`事件到达 → 处理器收到正文 → 生成新状态 → 应用接纳状态 → 计数更新`

同时记录焦点、DOM／内部选区、事件数据及异常。系统粘贴成功本身不足以单独证明 `isTrusted` 是原因，因为它还改变了焦点、事件顺序和数据格式。

**第二问：首选、备选与切换判据。**

**首选：在现有 paste 上做纯文本对照，并验证状态提交。**

具体要求：

- 每组从干净、由框架正常渲染的编辑器开始；失败后的 DOM 被改坏，就先恢复基线。
- 首组只提供 `text/plain`，暂不提供 HTML。它减少一个处理分支，**不保证绕过知乎的自定义粘贴处理器**。
- 确认真正的编辑宿主、所属 document，以及内部选区同步。空编辑器可能只有 `<br>`，不能把“必须找到文本节点”当作必要条件。
- 在接收端核验 `clipboardData.getData('text/plain')` 与全文一致，包括构造失败后的兼容分支。
- `dispatchEvent` 返回值、`defaultPrevented`、处理器执行次数都只是诊断信号；成功必须由已提交状态证明。

合成 paste 本身不会触发浏览器默认粘贴。它能奏效，是因为页面处理器主动读取数据并更新模型。[Clipboard 规范](https://www.w3.org/TR/clipboard-apis/#clipboard-event-paste)

**切换判据：**

- 事件没进处理器：修目标、事件接入或编辑器识别。
- 处理器收到的数据不完整：修事件构造。
- 双格式失败、纯文本成功：才有证据将生产路径改为纯文本。
- 处理器收到完整正文，却没有提交：继续查包装层和状态接纳链，停止堆叠事件变体。

**备选：编辑器自身的整文事务 API。**前提是能稳定取得当前实例、版本及实际提交入口。通过框架事务生成新内容，再进入应用真实的 `onChange/store` 链，最后回读已提交状态；多段文字应使用保留段落结构的事务。若这些条件成立，它可以优先于事件注入。仅找到 React Fiber 或私有字段，不等于已经具备可靠接口。[Draft Modifier API](https://draftjs.org/docs/api-reference-modifier/)

其他候选的裁决：

| 机制 | 裁决 |
|---|---|
| 带 `getTargetRanges()` 的 InputEvent | 仅在确认处理器消费原生 `beforeinput`、且缺失范围导致拒绝时采用。补范围不能修复事件根本没进入处理器的问题。[Input Events 规范](https://www.w3.org/TR/input-events-2/#interface-InputEvent) |
| 真实点击后逐字 `KeyboardEvent` | 不作为主线。真实点击不会把随后构造的键盘事件变成真实输入，也不保证触发浏览器插字默认行为。[UI Events 规范](https://www.w3.org/TR/uievents/#trusted-events) |
| 原生输入／系统粘贴通道 | 可作开发测试对照；当前 JS-only 约束下，不能把它当作已经可交付的能力。 |

**第三问：先于实现固定验收。**

复用现有真 Draft 测试页，增加空编辑器和故障场景；执行必须经过 **Mika 的实际 `performType/runTypeScript`，运行于目标 iOS 的 WKWebView**。Chromium 或 Playwright WebKit 的通过，只作辅助证据。

成功断言固定为：

```text
已提交 EditorState 的完整正文 === 预期正文
字数控件 === 按既定口径计算的状态字数，且非空输入字数 > 0
失焦、重渲染后正文仍一致
从保存结果重建编辑器后正文仍一致
```

正文比较只做事先声明的换行规范化，保留空格、空行和段落。**禁止以“包含目标文本”“字数增长”“量级接近”替代全文相等。**读取已提交给受控组件的状态，不能只读取 `onChange` 曾经收到的候选状态。

最低用例集：

| 用例 | 必须证明 |
|---|---|
| 空编辑器 0 字→中文短文 | 覆盖本次现场起点 |
| 旧文→新文，包括等长不同内容 | 完整替换，旧文不残留 |
| 多段长文、空行、emoji、标点 | 全文与段落一致，无截断、重复 |
| 未聚焦／已聚焦、节点重渲染 | 正确定位并提交状态 |
| 同页多个编辑器、多个计数器 | 写入与验收绑定同一对象 |
| 处理器忽略事件、数据丢失、上层拒绝状态 | 必须失败，更新动作调用次数为 0 |
| 仅改 DOM 的负对照 | DOM 有字、模型未变时绝不通过 |

各策略先独立复位测试，再测真实回退流程；不能在同一份已损坏 DOM 上连续试五次，就把结果视为五份独立证据。

**出包硬门槛：至少有一条能复现此次失效机制的用例，旧实现失败、新实现通过，并通过上述 WKWebView 验收。**如果裸 Draft 页上旧实现已经通过，就必须补上现场查明的包装层或事件差异；重复跑绿 demo 不能宣称知乎已修复。真站点最终确认还须回读保存后的完整正文。

本轮结论来自源码与规范核对，没有新增 iOS 真机实测；目前缺口已收敛为：**现有 paste 究竟在哪一跳失去正文或状态提交。**