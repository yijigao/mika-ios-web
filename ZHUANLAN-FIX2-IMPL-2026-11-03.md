# ZHUANLAN-FIX2 知乎专栏编辑器同步 · 第二轮修复案卷（2026-11-03）

## 1. 立项与基线

- 依据：Joey 2026-11-03 02:19 真机复测（构建 1655，含第一轮 1351）明确 FAIL——约 1000 字显示在 zhuanlan 编辑器中，编辑器自报字数仍 102，exec/events/chunks/range 四策略全败。规格见 ZHUANLAN-FIX2-SPEC-2026-11-03.md。
- 基线：feat/cover-gen-consent-click tip（b389bf7）。分支：feat/zhuanlan-fix2。未合 main。
- 工作区说明：基线工作区有父级未跟踪文件（VERIFY-1-SPEC、ZHUANLAN-FIX2-SPEC、next-directions-2026-11-02/），本单未动、未提交；TESTFLIGHT-LOG.md 在开工时已有一行未提交的追加（阿仁 02:41 对构建 1830 的 ASC 亲验记录），本单提交时随日志一并入库。

## 2. 根因（先根因、后动手）

方法：通读 Draft.js 0.11.7 源码（editOnBeforeInput / editOnInput / editOnSelect / editOnPaste / getDraftEditorSelectionWithNodes / fbjs DataTransfer）＋在真 Draft.js 仿真页上逐策略实测复现（见第 5 节）＋Astra max 独立咨询并逐条回源码复核（2.3），再对照真机失败签名。知乎专栏编辑器为 Draft.js 的外部佐证：2026-10 公开技术文章对八个平台编辑器逐一标注，知乎＝Draft.js（掘金《一篇稿全自动发到 8 个平台》）；第一轮案卷的页面结构口径（Draft.js 类）与此一致。本单未发现知乎已换编辑器的证据，按 Draft.js 机制设计。知乎实际 bundle 的 React 版本与包装层实现不可见，凡涉及这两层的结论都标注为推断。

### 2.1 Draft.js 的状态机事实（源码级，均已回 0.11.7 源码核对）

- EditorState 是事实源，但存在一条**窄的 DOM→状态回收通道**：editOnInput 会读当前选区锚点所在 leaf 的 DOM 文本，与模型中该 leaf 的文本比较，不同则 replaceText 并 push——条件苛刻：锚点必须能经 findAncestorOffsetKey 找到带 `data-offset-key` 的祖先（找不到是 nullthrows 直接抛错），且只回收锚点那一个 leaf。整段改写 DOM、重建 block 结构、或锚点落在自建节点上，这条通道都用不了。
- 一切文本事务都只认**内部 SelectionState**：editOnBeforeInput 读 `_latestEditorState` 的内部选区与 `e.data`（data 为空直接 return；选区折叠时先存 pending、等 editOnInput 开头提交）；editOnPaste 用内部选区做 `replaceWithFragment`。内部选区由 editOnSelect 从 DOM 选区同步（getDraftEditorSelectionWithNodes 含 getPointForNonTextNode，容器锚点也能映射——「锚点必须落在文本节点」不是必要条件，**已完成的同步**才是）；editOnSelect 的提前返回条件是 `_blockSelectEvents` 或内部状态与 props 不一致，没有「映射失败被静默吞掉」的 try/catch（本节初稿曾如此写，经 Astra 指出后回源码核对，已更正）。
- **React 事件转换层是增量路径的隐形门**：React（≤17，本机实验的 17.0.2 亦然）的 BeforeInputEventPlugin 并不消费原生 `beforeinput`——它从 keypress/textInput/compositionend 等事件合成 onBeforeInput。脚本派发的原生 InputEvent('beforeinput') 即使 data 完整，也可能根本进不了 Draft 的 handler（Astra 在 jsdom＋真 Draft 上实测：派发带完整 data 的原生 beforeinput，Draft onBeforeInput 调用 0 次、dispatch 返回 true——「没被 preventDefault」不等于「handler 被调用过」）。相对地，React 对原生 paste 是直接提取 SyntheticClipboardEvent，标准 Draft 的 paste 处理没有 isTrusted 门。
- 段落断开不是 beforeinput 事务：Draft 里回车是 key command；editOnBeforeInput 对 inputType=insertParagraph（data=null）直接 return。把原生 insertParagraph 混进增量输入流会改写 block 的 DOM 结构，使后续事件的 leaf 映射脱钩。

### 2.2 第一轮四策略逐项根因

1. **exec**（置信：高）：execCommand('insertText') 在 WebKit 不产生可取消的原生 beforeinput，Draft 没有字符级入口；唯一可能的回收是随后 input 事件触发的 editOnInput 叶级对账，而多段原生插入（换行被引擎拆成 block/br 结构）使锚点 leaf 的谱系与模型脱钩，回收无从覆盖整段。结果是原生 DOM 插入留在表面、计数不动。Chromium 仿真中 exec 同为坏账（状态只剩末段 17 字、DOM 与状态互不一致），说明即使引擎更配合，这条路对多段全文替换也不成立。
2. **events**（置信：高）：主因在事件层——合成原生 beforeinput 不被 React 的 BeforeInputEventPlugin 消费，Draft handler 大概率从未被调用（dispatch 返回 true 只说明没被取消）；第一轮唯一的 selectionchange 还派在全部段落之后，内部选区也没在派发前完成同步。次因是结构错误：段间的 beforeinput(insertParagraph) 在 Draft 里是 no-op、退回的原生 insertParagraph 又拆坏 leaf 映射。仿真页上即使先把内部选区正确同步成全选（0→102 实测在场），events 依旧失败（状态剩末段、DOM 被清），与上述两因自洽。（曾假设的「WKWebView 的 InputEvent 构造器丢 data」经 Astra 裁决为证据最弱的一项：现行 WebKit 源码会填充 data/inputType，本单不采它作根因。）
3. **chunks**（置信：高）：与 exec 同族——逐段 execCommand 原生插入＋合成 input 事件；input 事件只能触发叶级对账，覆盖不了被原生段落操作拆坏的整段结构。仿真结果与 exec 一致（状态剩末段 17 字）。
4. **range**（置信：确定）：纯 DOM 直写（insertNode 自建文本/ br 节点），新节点没有 data-offset-key 谱系，editOnInput 的 findAncestorOffsetKey 无从成立，回收通道不存在；事后补派的事件追认不了既成 DOM 事实。仿真页精确复现真机签名：DOM 已是目标全文 54 字、状态计数冻结 102。

共同签名「计数精确冻结在 102」的读法（经 Astra 修正后收窄）：它证明的是**没有任何内容事务在计数上落地**，不能严格证明「四条路连一次 handler 都没进过」（选区/焦点类更新本来就不改字数，上层受控组件也可能丢弃更新）。但结合 DOM 有字、保存永不落定、且仿真页能逐条复现四种坏账形态，「增量输入管线整体未被该编辑器接受」是证据最强的结论。

### 2.3 Astra max 咨询裁决（2026-11-03，646 秒，结论入卷）

Astra 的独立结论：**paste 路线成立**；但对本单初稿根因 A–D 提出四点修正，本单回源码逐条复核后**全部采纳**并已改写 2.1/2.2：①editOnInput 存在叶级 DOM 回收通道，「Draft 从不回收 DOM」不成立（回收条件苛刻、整段改写用不了，实践结论不变）；②容器锚点可经 getPointForNonTextNode 映射，「锚在容器必败」错误，决定因素是同步是否完成（其 jsdom 实测：容器全选＋同步后内部选区成为 0→102）；③InputEvent 丢 data 的归因证据最弱，不采；④计数冻结不等于零事务，读法收窄（见 2.2 末段）。Astra 补出的首要候选根因——React 事件转换层不消费原生 beforeinput——本单采纳为 events 策略主因。

Astra 对 paste 路线的四点审查意见与本单处置：
- 选区同步要有「内部已同步」的验收——真机上读不到知乎的内部状态，本单的验收沿用既有写后字数校验（计数对不上即判失败换策略），并在复测清单第 1 条要求回文章页核对全文；其建议的「DOM 先恢复为模型渲染态再同步」在 type 流程语义下即「不在已破坏的 DOM 上重试」，阶梯的失败快照与状态校验已部分覆盖，记为残余风险。
- mouseup 在 WebKit 分支无补偿作用、selectionchange 才是同步触发——采纳为机制表述（代码两个都派，无害；真机以 selectionchange 为准）。
- 事件构造要带 bubbles/cancelable/composed 并校验 clipboardData 真挂上、覆盖 DataTransfer 不可构造——本单实现已含（构造后回读 getData 校验、defineProperty 与 mock 双退路）。
- 数据面建议先只给 text/plain（HTML 会多过 zhihu 包装层的 handlePastedText/stripPastedStyles）——**记录分歧**：规格硬性要求 text/plain＋text/html 双份（fbjs isRichText 口径），本单按规格执行；若真机复测显示粘贴被过滤/降级，plain-only 是下一轮首选变体（已写入第 8 节）。
- 降级判据不能只看字数（追加成 1102 也可能达标）——与本单第 8 节残余风险同向，复测第 1 条已要求核对「替换而非追加」。

Astra 另提出「比 paste 更稳的是直接提交 EditorState」（拿到编辑器实例与应用提交接口时绕开事件层）——本单**不采**：知乎的实例与 onChange 提交链不可见、按 React fiber 私有结构取实例属版本强耦合的脆弱做法，且不在本单规格内；记录在此备查。keyCommand 路线经 Astra 与本单共同确认无「携带全文替换」的默认入口，不采。

## 3. 新策略设计：paste 粘贴事务（取舍）

Draft 的粘贴管线是其唯一「整段状态事务」入口：editOnPaste 读 clipboardData（fbjs DataTransfer：text/plain 与 text/html 两者齐备才走 rich text 的 HTML 管线），以内部选区为范围做 replaceWithFragment，一次推送完成整段替换，不经任何增量字符/段落操作——2.2 里全部失效机制都不在这条路上。设计要点：

1. **选区准备（成败关键，仿真对照实证）**：决定因素是粘贴派发前内部 SelectionState 已完成「全选」同步（2.1）。本单的做法：focus 后把 DOM 选区锚进首个 block 首个文本节点起点与末个 block 末个文本节点终点，派 selectionchange（WebKit 的实际触发）＋mouseup 促 editOnSelect 完成同步，再派粘贴；同步后内部选区有回读证据（anchor 0 → focus 102、hasFocus=true，见第 5 节）。对照实验：同样的粘贴、只做容器级 selectNodeContents 且**不派任何同步事件** → 内部选区没动，粘贴退化为在旧光标处追加（102→156，旧文保留）；带文本锚点＋同步派发 → 精确整段替换（102→54）。（Astra 的 jsdom 实测表明容器锚点＋同步同样能完成全选同步——文本锚点是本单选定的稳妥手段，不是必要条件；必要条件是同步本身。）
2. **DataTransfer 双份数据**：text/plain 放全文、text/html 按段落生成 `<p>`（转义后），满足 fbjs isRichText 口径走 HTML 管线，段落结构由框架自己建 block。
3. **事件构造双通道**：优先 `new ClipboardEvent('paste', {clipboardData})` 并回读校验 clipboardData 真的挂上（getData('text/plain') 非空）；引擎不接受时退回 `new Event('paste')`＋Object.defineProperty 挂 clipboardData，再退回直接赋值。两种构造在仿真页上均实测走通（React 合成事件从原生事件取 clipboardData，defineProperty 挂载可读）。
4. **宿主定位**：派发目标取 contenteditable 本体（e 本身即是时用 e，否则取其内首个 contenteditable），与 proveDraftClass 的定位口径一致。

阶梯分流（probeDraftClass）：编辑器子树有 `[data-offset-key]` block 或 Draft 标志类名（public-DraftEditor-content）→ Draft 类阶梯 **paste→events→chunks→exec→range**；其余编辑器保持第一轮阶梯 exec→events→chunks→range 原样，不扰动既有可用路径（如知乎回答的既有行为、普通富文本）。写后校验与三分口径（字数不动判失败、保存未落定不报成功、绝不回退）全部沿用第一轮实现，未改一字。

## 4. 改动清单

- `MikaWeb/WebController.swift`：runTypeScript 新增 path=paste 分支（选区准备＋DataTransfer＋双通道事件构造）；新增 probeDraftClass 探测；performTypeInEditor 按探测结果分流阶梯；相关注释同步。
- `MikaWeb/Resources/test-draft.html`（新增）：真 Draft.js 自检页（见第 5 节），370,357 字节（内嵌 React 17＋Draft.js 0.11.7 生产构建，仅测试资源本地落盘、不运行时拉 CDN；Draft.js 不作为 App 代码依赖引入，仅存在于该自检页资源内，与既有 test-*.html 同性质）。
- `MikaWeb.xcodeproj/project.pbxproj`：新增 test-draft.html 的 FileReference/BuildFile、组与 Resources 阶段条目（ID 0061/0062）。
- `scripts/validate_project.py`：资源断言 8→9 项（含 test-draft.html）。
- `MikaWeb/SelfTestView.swift`：新增「自检十二：真 Draft.js 编辑器粘贴写入」入口与预期说明（初始 102 字→替换为 54 字、保存落定、更新成功；冻结 102 或追加成 156 均判不通过）。
- `MikaWeb/SkillStore.swift`：zhihu-editor 专栏专节补「输入机制（ZHUANLAN-FIX2 定版）」两条（粘贴式整段写入的口径、type 给全文不要逐段喂、字数没动时不要自创输入法）。走既有哈希迁移投递。
- 既有 test-editor.html（自检七，计数器仿真页）**保留**：它验证的是通用「状态校验口径」（字数不动判失败）在非 Draft 模拟框架上的行为，与自检十二分工不同；第一轮的方法论错误在于拿它当 Draft 行为的验收证据，本轮起 Draft 类验收只认自检十二。
- 红线自查：SafetyPolicy.swift 与 MikaWebApp.swift 对基线 diff 均为 **0 行**；无新第三方依赖（App 代码零新增依赖；Draft/React 仅内嵌于自检页资源）；凭据不落盘；用户可见文案无「并行执行」字样（本单未新增含该词文案，仓库检索仅存量注释外无命中——见自检记录）。

## 5. Tier A 实测证据（真 Draft.js 仿真页）

环境：Playwright Chromium（headless shell 1243）加载与 App 资源**同一份** test-draft.html（React 17.0.2＋Draft.js 0.11.7，esbuild 生产构建内嵌）；页面初始正文恰好 102 个非空白字，计数与保存状态均由 EditorState 的 onChange 驱动（与知乎「字数」读法同源）。目标文本＝自检十二的两段短文（非空白 54 字）。每策略独立 fresh page：

| 策略 | 内部状态字数（EditorState 实测） | DOM 非空白字数 | 判定 |
|---|---|---|---|
| exec（第一轮原样） | 102 → **17**（只剩末段） | 34 | 坏账：状态/DOM 互不一致 |
| events（第一轮原样） | 102 → **17** | 34 | 坏账：同上（回退 execCommand 同路） |
| chunks（第一轮原样） | 102 → **17** | 34 | 坏账：同上 |
| range（第一轮原样） | 102 → **102（冻结）** | 54 | 精确复现真机签名 |
| paste（无选区同步，容器全选） | 102 → **156** | 156 | 事务成立但退化为追加（旧文保留） |
| **paste（文本锚点选区同步，本单实现）** | 102 → **54（精确替换）** | 54 | **通过**：保存落定「草稿已保存」，内部选区收束到新文末端 |
| paste（同上，defineProperty 构造） | 102 → **54（精确替换）** | 54 | **通过**：备用构造通道成立 |
| events（选区已正确同步后） | 102 → **17** | 0 | 仍失败：证伪「events 只缺选区同步」的假设 |

过程证据：选区同步一步有内部选区回读为据——文本锚点全选＋selectionchange＋mouseup 后，EditorState 的 SelectionState 实测为 anchorOffset 0 → focusOffset 102、hasFocus=true（基线页探针）；paste 的 ctor 通道回读 dispatch 返回 notPrevented=false（框架已 preventDefault 接管）。paste-anchored 路径连续三跑结果一致。

一处观察（不影响判定）：paste-container（追加变体）一跑中出现 Draft 内部 pageerror（minified 异常/选区恢复竞争），但其最终状态仍自洽落地（156＝156）；本单实现的 anchored 路径三跑无此现象。真机若出现编辑器异常，写后状态校验仍会拦下误报。

## 6. 交付证据

（待 CI/Release 完成后填入：validate_project、CI run 号与日志双核对、构建号、Release run、dSYM 字节数。）

## 7. 复测清单（给 Joey）

1. **知乎专栏已发布文章改长文（本单主场景，唯一真机验证点）**：构建更新后，打开那篇 102 字文章（zhuanlan.zhihu.com/p/2100696940291821754）的编辑页，把正文改到约 1000 字——期望 type 一次成功（步流首策略应为粘贴路线）、编辑器字数涨到目标量级、保存落定后点「更新」成功，回文章页核对正文已变长且旧 102 字内容已被替换（不是追加在后面）。
2. **自检十二**：真 Draft.js 页——字数 102→54、保存落定、更新回报「更新成功：正文共 54 字」。
3. **自检七（保留项回归）**：计数器页仍应通过（非 Draft 编辑器阶梯未动）。
4. **playbook 迁移**：知乎专栏任务里加载 zhihu-editor，应能引用专栏专节的 ZHUANLAN-FIX2 输入机制口径（粘贴式整段写入、type 给全文）。
5. **回归**：知乎写回答一篇（输入与发布判据不回退）；公众号编辑器 type 一个普通富文本框（非 Draft 分流不误伤）。

## 8. 未证项

- **真 zhuanlan 未证**：粘贴路线在真知乎专栏编辑器上的接管语义只能由 Joey 真机复测第 1 条验证——这是本单的明确未证项，仿真页（真 Draft.js＋Chromium）与 WKWebView 仍有引擎差异：①WKWebView 的 ClipboardEvent/DataTransfer 构造器填充行为与 Chromium 不同（已备 defineProperty 退路，但两条通道在 WKWebView 里都未实测）；②知乎对 Draft 的封装（其编辑器包装层、保存逻辑、可能的 paste 拦截/过滤）不在仿真内，若知乎包装层过滤粘贴内容或重写粘贴行为，paste 可能被降级，届时阶梯后续策略与状态校验保证不误报、按 stateRejected 口径如实汇报，再按真机 trace 迭代；③若复测显示粘贴被包装层处理异常，下一轮首选变体是只给 text/plain 的粘贴（Astra 意见，绕开 HTML 管线的 handlePastedText/stripPastedStyles）。
- 残余风险：若真机选区同步失败（知乎 DOM 结构与仿真页的 block 形态不同），paste 会退化为追加（旧文＋新文），现有 countConsistent 的「增长兜底」分支可能把它判过——复测第 1 条要求回文章页核对「已替换而非追加」正是为此；若真机出现该形态，下一轮应收紧 Draft 类编辑器的字数判据（单独立项，不在本单范围）。
- Astra 咨询结论与本单分析的分歧点（如有）在第 2.3 节如实记录。
