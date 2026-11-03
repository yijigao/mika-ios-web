# TRUSTED-CLICK-EXP 案卷：可信点按实验构建（E1 插桩＋E2 AX 探针）

- 构建：**202611030252**（0.1.0），分支 `feat/trusted-click-exp`（基线＝feat/zorder-fix tip `1581e63`，含构建 0239，未合 main），功能提交 `cd81e0e`；本案卷＋日志随证据提交入库。
- 规格：TRUSTED-CLICK-EXP-SPEC-2026-11-03.md（父级单据，未动未提交）；依据备忘：~/workspace/research_notes/trusted-click-2026-11-03/MEMO.md（§5 Touch 结构性缺口、§6 九类成因表）。
- 范围定版：本单交付实验构建与 agent 侧可自完的全部实验——E1 的插桩设施＋复刻页对照、E2 的探针页实验。**E1 的真机金标准（真实条款弹窗上 Joey 真点一次）不在本单内**，由阿仁另行约 Joey，本单已把插桩与导出通道做到「真机时装上即可采」（见 §4 采集步骤）。E3 受 E1 真机结果门控，本单未做、未解锁。

## 立项与现场

Joey 2026-11-03 10:23 亲定：微信条款弹窗的合成点按一直过不去，是「硬菜，要啃下来」；同时点名层级缺陷（已由 ZORDER-FIX 0239 修复）。调研备忘的结论分两半：①「JS 注入产不出可信事件」证据链已闭合（规范＋WebKit 源码＋同类项目三线），不应再在序列字段上盲试；②但无响应的真实成因尚未分清——MEMO §6 列了九类非信任成因，其中一类有源码级实锤：WebKit 的 `Touch` 无构造器，JS 派发的 touch 事件 `changedTouches` 恒空，读 touch 坐标的状态机对合成触摸序列天然无感。本单就是把分清成因的实验设施（E1）与唯一未证的公开 API 候选（E2 AX 激活）一次做齐。

## 实现

### 1. E1 只读插桩（MikaWeb/WebController.swift）

- 脚本 `BrowserTab.tcProbeScript`：经既有多路复用器的同一装配点（equip）注入每个 frame（含跨源 iframe），handler 名 `mikaTCProbe`，消息由复用器按名路由到 FrameProbeHub（与 frame 探针共用中枢，按 token＋webView 身份匹配——页面无法伪造 token）。装配沿用「每 controller 只装一次」守卫，不另起逐标签注册（1031 崩溃教训）。
- 默认未武装、零记录；宿主经主 frame `postMessage` 洪泛下达三令，各 frame 自行向子 frame 转发：`arm`（带随机 token，清空缓冲开始记录）→`dump`（token 匹配才回報）→`disarm`（停记并断开观察器）。
- 记录面（捕获阶段＋passive，只读，绝不 preventDefault/stopPropagation）：
  - 事件：pointerover/down/up/cancel、mousedown/up、click、touchstart/end/cancel、keydown/up；字段＝type、target 形态（tag／id／class／role；非表单元素附截断 24 字的 aria-label 或文本——按钮文案级信息，与 frame 探针的按钮特征同口径）、isTrusted、changedTouches.length、touches.length、pointerId、pointerType、pressure、isPrimary、timeStamp、wall 时钟。
  - DOM 变化：MutationObserver（childList＋subtree＋attributes），每条记 kind、target 形态、增删节点数、属性名。
  - 上限：事件 1000 条、变化 300 条，超出置 truncated 标记，不无限增长。
  - **凭据安全**：表单控件（input/textarea/select）只记 tag 与 type 属性，绝不记 value 与文本；全程不记 cookie/存储/请求内容。
- 宿主 API（WebController）：`armTCProbe`（返回 token）、`dumpTCProbe`（900ms 窗口收集各 frame 回報）、`disarmTCProbe`。
- 结构化落盘与导出：`TCProbeLogStore` 写 Application Support/MikaWeb/TrustedClick/tc-exp-<ISO 时间>.json（文件名冒号换连字符，字典序即时间序）；自检页提供最近一份的 ShareLink 导出入口。真机金标准同通道落盘，文件名即采集凭据。

### 2. E1 复刻页 test-trusted.html（新资源）

- 条款弹窗复刻：居中浮层＋「取消／同意并继续」双按钮，形态对齐微信 AI 配图条款弹窗；按钮由**触摸状态机**驱动——touchstart 须在按钮上记录到 changedTouches[0] 坐标、800ms 内同按钮 touchend 仍携带 changedTouches[0] 且落点在按钮内才关闭（closedBy=touch-state-machine）；合成 click 到达 handler 但无合法触摸前置时记 `ignored-click-without-valid-touch` 不动作；空 touches 的 touchstart/touchend 记 `ignored-empty-touches`。这正是 MEMO §6 成因 2 的复刻。
- 页面自有事件账（与宿主插桩相互独立的第二观察者）：document 捕获阶段记录同字段集，`__tcState()` 回读（dialogOpen／closedBy／normalClicks／touchCtor／decisions／log）；另有普通计数按钮作阴性对照、`__tcOpenDialog()` 供宿主打开弹窗、页面加载即实测 `new Touch(...)` 并记 touchCtor 结果。
- E2 探针区同页：`#axTarget`（aria-label=「AX探针目标按钮」）记录 pointerdown/mousedown/mouseup/click 的 isTrusted 与点击计数，`__axState()` 回读。

### 3. 自检二十（SelfTestView＋AgentEngine.verifyTrustedClick＋WebController.verifyTrustedClickExp）

Tier A 在合成页上全程真实驱动（不调用模型，要求引擎空闲）：
- E1：武装插桩 → 普通按钮走引擎 click（页面计数须为 1，阴性对照）→ 打开复刻弹窗 → 派现行 pointer 序列（与 performPointerSequence 同步序同字段：pointerover→pointerdown→mousedown→focus→pointerup→mouseup→click，pointerId=1/mouse/isPrimary）＋合成 TouchEvent 序列（空 touches 列表）→ 断言弹窗仍打开且状态机「空 touches 忽略」判读在场 → dump 插桩，与页面账逐类型计数比对（pointerdown/up、mousedown/up、click、touchstart、touchend 七类须一致＝插桩工作正常），且插桩侧 touchend 的 changedTouches 须全为 0、全部事件 isTrusted 须全为 false（现象双证）。
- E2：重载页面 → 宿主侧递归枚举当前标签 WKWebView 的无障碍树（accessibilityElements 数组优先、count/at 索引兜底；对象身份去重、深度 ≤14、总量 ≤800 双封顶）→ 按 aria-label 命中探针按钮 → 调公开 API `accessibilityActivate()` → 回读页面 click 计数与 isTrusted。判定按规格：收到 click 且 isTrusted=true 记「通（信任位口径）」；click 未翻真但计数增长记「通（动作生效口径）」并如实标注；命中元素但无事件到达记「不通：卡在 UA 内部激活转化层」；未命中记「不通：卡在宿主可达层」（附树规模）。
- 一次实验合成一份 JSON 落盘（E1 的 decisions 与全 frame dump 原文、E2 的树规模与判定），结论逐条以「自检二十」条目写进对话。
- Tier B（真机人工）＝§4 的 E1 金标准采集，不是本按钮内自动执行。

### 4. E2 判定（本单结论）

E2 的代码路径与判据已随本构建落地，**判定本身须真机跑自检二十才成立**——本机无 Swift 工具链、无真机，agent 侧到此为止（与历轮 Tier A 口径一致：断言代码已编译进构建，待真机点按回读）。三种结局的后续已在规格写死：通→另立单评估产品化（AX 树稳定性与审核口径）；不通（任一层）→案卷把「公开 API 全面无路」结论收紧落定，火力全转 AUTONOMY 绕行梯。**本单不预判结局、不做产品化。**

## 复刻页对照数据（agent 侧先行冒烟）

复刻页脚本逻辑先以 Node 最小 DOM 桩冒烟（只验页面状态机与页面账逻辑，**不冒充 WebKit 实测**；touches 恒空的 WebKit 侧实证在自检二十 Tier A 真机回读）：

| 步骤 | 输入 | 结果 |
|---|---|---|
| 普通按钮 | 合成 click | normalClicks 0→1（普通控件对合成 click 正常响应） |
| 打开弹窗后点「同意并继续」 | 合成 click | dialogOpen 保持 true；decision=ignored-click-without-valid-touch |
| 触摸序列 | touchstart/touchend，changedTouches=[] | dialogOpen 保持 true；decision=ignored-empty-touches；页面账 touchend 的 ct=0 |
| 合法触摸序列（金标准形状） | touchstart/touchend，changedTouches=[{clientX:160, clientY:220}] 落点在按钮内 | dialogOpen→false；closedBy=touch-state-machine |
| AX 探针按钮 | click | clicks=1；events 记录该 click 的 isTrusted（桩内为 false，属桩设定值、非实测） |
| Touch 构造器 | `new Touch({...})` | 桩环境无 Touch 全局 → threw:ReferenceError（仅说明页面有捕获记录；WebKit 真机结果以自检二十回读的 touchCtor 字段为准） |

冒烟结论：状态机判读与规格预期逐项一致——合成序列（click／空 touches）关不掉、带坐标的合法触摸能关。这同时给 E3 留了判读基线：若真机金标准 diff 指向状态机类成因，复刻页可直接用作补全序列的对照台。

## E1 真机金标准采集步骤（阿仁约 Joey 时照此执行）

前置：装本构建（202611030252）；目标＝微信公众号后台真实条款弹窗（复刻 0042/0144 现场：封面设置误入 AI 配图入口时出现）。插桩随 App 启动已注入每个 frame，但**武装要在弹窗所在页面加载完成后、点任何按钮之前**——当前自检二十只在合成页自动武装；真实页面武装入口是同批宿主 API（armTCProbe/dumpTCProbe/disarmTCProbe 已就绪），阿仁侧操作路径＝在弹窗出现的当场会话里执行武装→真点→重放→dump→落盘五步（若当场无武装入口可用，则以「弹窗出现前先在自检页确认插桩在位、再回任务页」的顺序近似，并在采集记录里如实注明武装时机与页面加载时序的差）。诚实边界：WKUserScript 在文档开始时注入，App 启动后新加载的页面都带插桩；arm 只是打开记录开关，页面加载后、弹窗出现前武装均有效，不需要弹窗出现前预知。

1. 弹窗出现、agent 尚未对它出手（或已连败转介入）时，先武装插桩（arm，记下 token 与时刻）。
2. 请 Joey 在弹窗上**真人点一次「取消」**（只点这一次，点完不要再碰页面）。
3. Joey 点完后，agent 用现行序列（引擎 click 同一按钮）重放一次。
4. dump 插桩 → 与 TCProbeLogStore 同通道落盘（文件名 tc-exp-<时间>.json 即本次采集凭据），disarm 收口。
5. 逐字段 diff（真人点 vs 合成重放）：事件类型序列、target 形态、isTrusted、changedTouches.length、pointerId、pressure、timeStamp 间隔、DOM 变化条目。对照 MEMO §6 九类表收敛成因：真人点在插桩 frame 内不可见→成因 8（frame 覆盖）优先修；真人 touchend 带 ct=1 而合成 ct=0 且 click 均到达→成因 2（触摸状态机）成立、序列路线关闭；真人 click isTrusted=true 而合成 handler 分支不走→成因 1。
6. 分流：指向状态机类（3/4/5/6/7）→向阿仁申请解锁 E3；指向 1/2→关闭序列路线，结论并入本案卷增补，火力转 E2 判定与绕行梯。
7. 采集纪律：Joey 只点一次；采集全程不点「同意」（不产生任何授权副作用）；落盘 JSON 不得含凭据类数据（插桩记录面已收窄，diff 时再人工扫一遍 target label 有无异常文本）。

## CI／Release 双核对（日志原文，不认 run 结论）

- validate_project.py：全 PASS（31 Swift 源、13 项 HTML 资源集——新增 test-trusted.html 已登记进 pbxproj 与校验集）。
- CI Run **41568542516** success：日志原文核对——70 条 SwiftCompile、WebController/SelfTestView/AgentEngine 三个改动文件均在编译列、test-trusted 资源打包在位、BUILD SUCCEEDED ×1、BUILD FAILED ×0，唯一 `error:` 为既有 AppIntents 训练噪声。
- Release Run **41568712854** success：agvtool 置号 202611030252、Successfully uploaded package ×1；dSYM artifact `dsym-41568712854` 实存 **5,087,420 字节**、未过期。
- ASC 状态：**待阿仁亲验**（本单未记 VALID、未挂组）。

## 红线自查（git diff 对基线 1581e63 实查）

- MikaWeb/SafetyPolicy.swift：**0 行**改动；MikaWeb/MikaWebApp.swift（单持有者）：**0 行**改动。
- 插桩只读：捕获阶段＋passive 监听、MutationObserver 只观察，不改页面行为；记录面不含凭据（表单控件只记 tag/type，见 §1）。
- 无新依赖；GPL（OpenMinis）只有备忘里的手法描述，本单未抄其代码（AX 路线为公开 UIKit API、插桩为自研）；未合 main；父级各 SPEC 文件未动、未提交（仍为未跟踪状态）。
- 改动面：WebController.swift（多路复用装配＋1 handler／脚本、BrowserTab 插桩脚本、TCProbeLogStore、宿主三 API、AX 树枚举、自检二十驱动）、AgentEngine.swift（verifyTrustedClick 入口）、SelfTestView.swift（自检二十按钮＋导出入口）、新资源 test-trusted.html、pbxproj 与 validate_project.py 的资源登记。

## 未证项（不得视为已验）

1. 自检二十 Tier A 未真机运行（本机无 Swift 工具链，与历轮同口径）——E1 复刻页对照（双账一致、touches 恒空、弹窗保持打开）与 E2 判定均待真机点按回读；复刻页逻辑只过了 Node 桩冒烟（见对照表注记）。
2. E2 三种结局都未证：宿主能否枚举到 WKWebView 网页无障碍树、能否按 label 命中、accessibilityActivate() 是否产生页面 click 及其 isTrusted 原值——全部以真机自检二十的字段证据为准，本案卷不预判。
3. E1 真机金标准未采：真实条款弹窗上「真人点 vs 合成重放」的逐字段 diff 尚不存在，九类成因未收敛；E3 未解锁、未实施（复刻页数据指向成因 2 的可能性最高，但那是复刻页的形状、不是真实弹窗的证据，不据此解锁）。
4. 插桩对真实公众号页面的覆盖未证：WKUserScript 对沙箱 iframe 的注入（frame 乙问题）同样适用于本插桩——若真实弹窗住在未被注入的 frame 里，金标准 diff 会先表现为「真人点在所有 dump 里不可见」（成因 8 的判读路径已写进 §4 步骤 5）。
5. AX 树枚举在自检 sheet 覆盖浏览器坞时的可达性未证：自检二十驱动时当前标签页的 webView 位于 sheet 之下，其无障碍树是否照常可枚举属 E2 实验本身的一部分，结果如实记。
