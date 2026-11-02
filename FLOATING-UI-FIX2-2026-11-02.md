# Mika Web 悬浮窗构建 202611020540 两项真机缺陷修复记录（2026-11-02）

需求：Joey 13:55 真机反馈（构建 202611020540）：「实现了悬浮，没有闪退bug。需改进 1. 内容没有随手机/悬浮窗口适配 2. 操作好像出了问题，我让他在知乎回答评论，它找不到发表按钮」。补充一手证据（13:55 截图＋Joey 本人判断）定性缺陷 2 主攻输入注入环节，详见下文。

**交付构建：202611020602**（0.1.0，build id `65d0f392-91b7-4aab-9898-aa5b3d09baed`）
- 分支：续用 `feat/floating-browser-dock`（未新开分支；基线即 0540 的交付分支，两缺陷均属该改造的收尾），代码提交 `736170e`。未合 main、未合 fix 分支。
- CI Run 41397273588 success（Debug 模拟器真编译）；Release Run 41397400728 success。
- ASC 回读：processingState=**VALID**、expired=false、usesNonExemptEncryption 已 PATCH=false（HTTP 200 后回读确认 false）；Internal 组（6a722377-d7f3-4c76-876f-4c35e193e0e4）挂载 POST **204**，组内回读新构建居首 [202611020602, 202611020540, 202611020450, 202611020437]。
- validate_project.py 全 PASS。

## 红线核对（git diff 实查，736170e 相对 619feaa 共 4 文件）

- `MikaWebApp.swift` 持有形态（AppObjectGraph 单持有者）**零改动**；`BrowserView.swift`（WebSurface）**零改动**；`AgentEngine.swift` **零改动**；`SafetyPolicy.swift` **零改动**——付款／同意确认、密码框 agent 不填的判定与拦截全部保留（新 click/type 脚本沿用同一套安全词＋敏感字段校验，rescan 路径对命中节点复用同一安全词检查）。
- `WebController.swift` 的改动只限 execute 的注入层（缺陷 2 的 b–e 增量）＋失败快照写盘；`BrowserDockView.swift` 只限布局层（缺陷 1）；`PageState.swift` 只加元素 disabled 字段；`ModelClient.swift` 只在系统提示词加一句 disabled 口径。

---

## 缺陷 1：内容不随窗口适配（真 resize）

### 根因判断
- **证据（代码事实）**：0540 的保活策略是 BrowserView 恒以展开尺寸布局＋`scaleEffect` 渲染缩放，WKWebView 的布局视口永远是全屏尺寸，页面只会被整体缩小渲染、永不按小窗宽度重排——与 Joey「内容没有随手机/悬浮窗口适配」的描述逐字对应。
- **证据（真机）**：Joey 13:55 反馈确认悬浮形态本身成功、无闪退，仅内容不适配。

### 修复（BrowserDockView.swift）
- 新增已落定布局缩放比 `layoutScale`：BrowserView 按 `area × layoutScale` 布局；收放弹簧动画期间视觉缩放比与 layoutScale 之商走 `scaleEffect` 过渡（画面连续），状态落定（约 480ms、弹簧结束后）由 `scheduleSettle()` 在禁用动画的事务里把 layoutScale 切到当前态真实值——展开＝1、小窗＝miniScale——WKWebView 随 frame 变更按新视口**响应式重排**，渲染缩放同时归 1。**同一个 WKWebView 实例、同一会话，不重载、不重建**（WebSurface 的 representable 身份与 controller 持有关系未动）。
- resize 只在落定时点发生：点按收起/展开、程序自动展开、容器尺寸变化（旋转）才调度 settle；**拖动只改 offset、绝不触发 resize**，避免布局抖动与 agent 操作中途版面突变。
- 滚动位置：resize 前读取页面滚动比例（scrollY／可滚高度），切换后约 150ms 恢复同比例并由浏览器自然钳制；等待期间若页面发生导航（`web.revision` 变化）则放弃恢复，避免跳错页面位置。
- 小窗默认尺寸适度调大（`DockGeometry` 常量）：宽度比例 0.44→0.50、钳制 150–184→170–210pt、高度上限 46%→50%。以 393×759 为例小窗约 196×380pt——真 resize 后这就是页面真实视口宽度，旧尺寸（约 173pt）对常见站点过窄；整页等比形态不变。
- 已知形态说明：小窗态下 BrowserView 的地址栏行也按小窗宽度布局（会被护盾覆盖、不影响使用），展开即恢复全宽，与 0540 的整坞缩放口径一致。

## 缺陷 2：知乎评论「找不到发表按钮」（输入注入主攻）

### 根因判断（证据与推断分开）
**证据：**
1. 截图（13:55，展开态）：知乎回答页评论区里目标评论（「晚风吹过」）下方的回复编辑器已被打开，编辑器右下蓝色「发布」按钮存在且位置常规；任务在展开态跑，排除小窗坐标/缩放问题，缺陷 2 与浮窗形态无关。截图中编辑器文字是 Joey 手动演示输入，非 agent 成果；Joey 本人判断「估计是压根没打进去」。
2. 代码事实（旧实现）：contenteditable 的写入是 `e.textContent = a.text` 后派发**无 inputType/data 的普通** `input`/`change` Event。框架富文本编辑器（Draft/Slate/ProseMirror 一类）的内部状态不由 DOM textContent 同步：这样写完，编辑器状态仍是空——发布按钮保持禁用或不进入可提交状态，模型在下一轮快照里自然「找不到」可点的发表按钮。
3. 代码事实（旧实现）：元素抽取不含 disabled 信息，模型与执行层都分不清「按钮不存在」与「按钮是灰的」；且旧 click 对禁用按钮执行 `e.click()` 是静默无操作、不报错，失败只能以「下一轮页面没变化」的形态浮现，最终被笼统转述成「找不到发表按钮」。

**推断：** 知乎评论编辑器属 Draft.js 系框架编辑器（未在本轮抓包验证，不作为修复前提）——修复按「框架编辑器通用类」做，不针对知乎写死任何规则。

### 修复落点（WebController.swift 为主，逐条对原 brief）
- **a（第一优先级）＋写后硬校验**：`performType` 总流程＝写入→回读校验→不过关换备用路径重试一次→仍不过关如实报错。
  - 主路径（contenteditable）：聚焦→全选编辑器内容→`document.execCommand('insertText', false, text)`，走 WebKit 原生编辑管线，框架编辑器按真实键入处理并更新内部状态。
  - 备用路径：Selection/Range 删选区后插入文本节点（多行以 `<br>` 分隔），再补派 `beforeinput`＋带 `inputType='insertText'` 与 `data` 的 `InputEvent('input')` 及 `change`。
  - 表单字段（INPUT/TEXTAREA/SELECT）：原生 value setter（绕开框架拦截）＋带 inputType/data 的 InputEvent＋change（React 受控组件口径），两路径同法。
  - **回读校验**（`verifyType`，写入后 400ms）：① 编辑器当前文本归一化（去空白/零宽字符）后非空且包含目标文本；② 编辑器邻域（优先共享近层祖先的候选，退全文档）内「发布/发表/提交/发送…」类按钮存在性与禁用状态。文字不过关→备用路径重试；仍不过关→抛「文字没能输入到编辑器：两种写入方式都已尝试、回读仍为空或对不上，请在网页手动输入后点继续」，**不再报成找不到按钮**。
- **b 提交按钮等待＋重扫**：`performClick` 先按已校验元素点（含点击前 `scrollIntoView`）；遇禁用/缺失进入轮询重扫：12 次 × 300ms（约 3.6 秒）——编辑器状态更新后按钮常延迟启用或被重渲染替换，重扫先认原 `data-mika-idx` 节点，再按同文案在全文档（含 fixed/sticky 底部栏、滚动容器内元素，抽取与重扫均为文档级查询、天然覆盖）找候选，每次点击前先 scrollIntoView。
- **c 失败口径分开**：抽取脚本与 `PageElement` 新增 `disabled`（原生 disabled 或 aria-disabled）；报错分四种人话：「文字没能输入到编辑器…」「文字已输入，但『发布』按钮仍是灰的（禁用状态），没能发布」「『X』按钮是灰的（存在但被禁用），无法点击」「页面上找不到要点的按钮『X』…」；`ModelClient` 系统提示词同步加一句 disabled 口径，避免模型反复点灰按钮或谎称已发布。
- **d 失败留证**：上述四种失败在抛出前调 `captureFailureSnapshot`——页面截图（JPEG 0.5 质量，base64）＋精简 DOM 摘要（可见候选按钮文案/标签/禁用状态前 12 个、可见编辑器及各自文本长度）写入**既有 DiagnosticStore 通道**（同目录 `MikaWeb/Diagnostics`、同信封格式 schemaVersion 1、types=「操作失败快照」），诊断页列表可读。注：列表刷新点是 DiagnosticStore 既有发布时机（启动／下一次 MetricKit 保存），快照文件落盘即已留证、至迟下次启动可见。抓取全程尽力而为，失败不掩盖原始错误。
- **e 双态定位一致性（代码实查结论）**：agent 定位全程为 DOM 索引式（extract 快照→`data-mika-idx`→JS `click()/type`），全仓不存在截图定位或坐标换算路径（grep 实查：`getBoundingClientRect` 仅作可见性判定、且恒按**当前真实布局**计算；`takeSnapshot` 仅用于 d 的失败留证）。0540 的 scaleEffect 从未进入任何定位换算；缺陷 1 改真 resize 后，双态下抽取/执行面对的都是当前态真实布局，一致性成立，无残留 scale 路径可修。

### 自验记录
- validate_project.py 全 PASS；CI（Debug 模拟器编译）success——Swift 语法与工程完整性已过编译器；JS 为运行时注入脚本，无本地 JS 运行时可验，靠上述回读校验在真机运行时兜底（校验不过会如实报错并留快照，不再静默）。
- Release run success＋ASC 回读 VALID＋组挂载回读（见文首）。

## Joey 复测清单（装 TestFlight 最新 202611020602）

1. **闪退红线回归**：展开态点网页多次＋滚动，不崩。
2. **适配（缺陷 1）**：展开一个排版丰富的页面→收起小窗，等约半秒：页面应按小窗宽度**重排**（文字变大、版式变窄版），不再是整页缩小的样子；再展开：恢复全宽排版；收放前后页面不重载、滚动位置大致保持（允许小幅偏差，不应跳回顶部）。小窗里上下拖动小窗本身时页面不应抖动重排。
3. **知乎评论·展开态（缺陷 2 主验）**：让 agent 回复任意一条评论——盯着编辑器看：文字应**真正出现在编辑器里**、「发布」变可点、评论发出。
4. **知乎评论·小窗态**：收起小窗后同样发一条评论任务，应能完成；需要介入时小窗自动展开（既有行为回归）。
5. **失败口径（可选，故意验）**：给一个注定失败的输入任务（如让它在一个还没点开的编辑器里写字），回告应是「没输入进去／按钮是灰的」这类具体说法，而不是笼统的「找不到发表按钮」；失败后到「自检→诊断」一带应能多看到一条「操作失败快照」（至迟重开 App 后出现）。
