# LADDER-FIX 案卷（2026-11-03）：绕行梯引擎驱动修复（F1–F6）

立项：只读诊断 LADDER-STALL-DIAGNOSIS 对 2026-11-03 11:01–11:08 真机场的定案——绕行梯停在第 1 级、步流出现红色「不可执行动作」后任务未能走到直达 URL 一级。诊断四点定案（梯级推进权在模型手里／「不可执行动作」是 execute() default 分支硬终结且先执行后记账无留痕／预览链接对 harvest 贡献为零且 mid↔appmsgid 禁止假定／感知层混同预览锚点与编辑控件）不推翻，本单按 F1–F6 逐条修复。

**诊断文件缺口（如实记录）**：工作区内的 `LADDER-STALL-DIAGNOSIS-2026-11-03.md` 实际只有 96 行、16,655 字节，在 §3 的 D1 中途戛然而止，D2–D5 与 §4 不在文件中（已用 ls 核实全仓只有这一份副本）。本单的 F1–F6 规格以父任务消息正文所载全文为准实施；诊断文件按要求保持未跟踪原样、未动未提交。此缺口已同步写入本单回报。

基线：`feat/trusted-click-exp` tip `aee0241`（构建 202611030252）。分支：`feat/ladder-fix`（未合 main）。功能提交 `2e8686d`＋编译修复 `4889fa0`（见 §9）。

## 0. 回路级成因确认（本单代码实查，超出诊断原文的一步）

诊断 D2 只查到「不可执行动作由词表外动作名触发、具体字符串查不到」。本单读主循环时确认了完整机制：主循环里 ask_user 是独立 `if`、不是执行链的一环——能力类 ask_user 经 handleCapabilityStall 返回后，控制流继续落入 use_skill／open_new_tab／click／…／else 的执行链尾，被 `WebController.execute` 的 default 分支以 MikaError("不可执行动作") 抛出；旧 else 分支先执行后记账，所以该动作在步流无留痕（正是「查不到」的原因），且外层 catch 直接置 .failed——**梯子不是停在第 1 级慢慢等，而是在第 1 级下达的同一轮迭代里就被自己的回路杀死**。这与现场截图（绕行梯叙事步骤之后紧跟红色「不可执行动作」）逐项吻合。修复：执行链与 ask_user 改为互斥的 else-if 链，能力类 ask_user 在本分支内由绕行梯接管并落循环指纹，不再落入 else（见 F4）。

## 1. F1 可见性

- 梯级推进全程步流可见：卡点打开（第 1 级下达＋验收口径）、每次手段验收的汇总（`OpenStall.meansSummary` 逐项 ✓／未试／不适用及依据）、结级（触发原因：验收齐／预算到期／第二次信号／done 梯门）、第 2 级 harvest 实况行、第 3 级结果、卡点关闭（原因＋关闭时验收进度），均以 `bypass` 步进对话与梯账（`BypassLadder.notes`）。
- 被拒动作先记账后分发：主循环 else 分支改为 `record(action)` 先行再 execute，词表外动作的动作字符串与理由原文必然留痕（同 §0 的旧病灶一并修复）。

## 2. F2 引擎驱动梯子（核心）

- **在开卡点账 `OpenStall`**（AgentEngine.swift）：卡点描述、打开页 URL、打开时模型决策数、打开时弹窗在场、`verified／notApplicable` 逐项验收、已点目标键集、frameClose 信号、词表外动作留痕（F4）、感知盲区留痕（F5）。随快照落盘（SessionSnapshot 新增可选组键：梯账 harvest 模板／实况＋卡点全账，旧快照无键照常解码），跨澄清停车与进程恢复存续；新任务重置。
- **第 1 级逐项验收**（`StallMeans` 五项）：验收只认真实执行证据——click 执行成功记目标键（揭示复判与坐标落点同为引擎 click 的实现面：点前自动揭示复判＋按元素中心真实坐标派发点按序列，一次真实执行同时构成两项实证，口径在 `noteExecutedActionForStall` 注释明示，不拆假账）；第二个不同目标键记替代入口；set_site_mode 执行成功记站点模式；frame 感知关闭连败信号（runTargeted／driveDialogBypass 的弹窗无响应路径）记 frameClose；无弹窗时由结级普查／推进钩子普查判定不适用并注明依据。`handleCapabilityStall` 首次信号只开卡点下达第 1 级、**不记 attempted**。
- **引擎自动推进**（三路，不等模型第二次 ask_user）：①每轮迭代末尾的推进钩子 `advanceLadderIfNeeded`——页面离开卡点页即关卡点（视为已绕过）；第 1 级验收齐立即结级；打开后 10 次模型决策未齐则预算强制结级；仅差 frameClose 一项时钩子才做一次普查（不给每轮加固定开销）。②第二次能力类信号→强制结级（`completeRung1AndProgress`）。③done 梯门（下条）。结级后 `progressRungsBeyondFirst` 同步驱动第 2、3 级：成功关卡点续跑，梯尽关卡点并抛失败结案。
- **done 梯门**（`evaluateDoneGate`，主循环接受 done 前）：无卡点不介入；页面已离开卡点页或梯已尽→关卡点放行；其余→强制结第 1 级并驱动后续梯级，驱动成功本轮不接受 done（`continue` 续跑），梯尽抛失败结案。杜绝「梯未尽 done 被无条件接受、结案不读梯账」。
- **澄清不吞卡点**：澄清类 ask_user 停车照旧（介入分类门语义不回退），但调用 `noteClarifyDuringStall` 在步流明示卡点保持在开与验收进度；卡点账随快照存续，答复续跑后继续推进。安全类路径（SafetyPolicy 引用、确认/手输流程）一字未动。
- **弹窗路径联动**：runTargeted 弹窗无响应且卡点在开时，不再从该处跳过第 2 级直达第 3 级——连败计入卡点 frameClose 证据后按策略切换续跑，推进交给引擎钩子。runConfirmed（已确认动作）路径沿用 AUTONOMY-FIX 的 driveDialogBypass 直达第 3 级口径（安全语义优先），但已与卡点账联动（信号记账、成功关卡点）。

## 3. F3 harvest 候选扩展

- 采集面：frame 探针脚本新增 `harvest` 消息类——整棵 frame 树逐 frame 采集并按 token 回報（与 probeFrames 同范式、同装配点）：a[href] 原始值（≤400）、data-* 属性（值含 appmsg／://、属性名含 appmsgid、或纯数字 ≥5 位者，≤120，值截 600 字）、onclick 属性（含 appmsg／http 者，≤120）、内联脚本文本中含 appmsg 的 URL 形子串（≤60）。Swift 侧 `WebController.harvestDirectTargets(memoryTemplate:)` 汇总为带来源与所在 frame 基址的候选；探针零回報时回落主 frame 链接采集（旧口径下限），回落事实写入实况不隐瞒。
- 提取纯函数 `DirectTargetHarvest.build(candidates:memoryTemplate:)`：旧 `build(hrefs:)` 保留为 href-only 包装（自检十八断言不破）。新增：data-appmsgid 类裸 ID 属性（属性名即页面明示语义、值须纯数字）；相对地址以所在 frame 的 href 为基解析、只收 http(s)；采用优先级＝带 ID 编辑链接直用＞本页模板拼装＞跨页模板记忆拼装（注明跨页）；每次采集把本页实证模板与实况行回写梯账（`BypassLadder.noteHarvest`，模板只记第一次实证见到的并注明出处页）。**严禁任何未实证标识映射**：预览链接里的 mid 不会被当作 appmsgid（自检二十一与 JS 镜像双证），代码与文案均明示。

## 4. F4 不可执行动作去终结化

- 结构修复（§0）：ask_user 与执行链改互斥 else-if 链——合法动作不再被误杀。
- else 分支（navigate／scroll／wait／set_site_mode 及一切词表外名）：先 `record` 记账，再 execute；抛 MikaError("不可执行动作") 时由 `handleInvalidAction` 处理：`invalid` 步留痕（动作字符串＋理由原文）、回注纠正提示（列明可执行词表）、卡点在开时计入其证据；**不置 .failed、不清快照**，本轮按已消费处理、循环指纹单列 `invalid-action` 后继续。其余错误照旧上抛。错误判定 `isUnexecutableActionError` 只认该文案精确匹配，不吞其它错误。

## 5. F5 感知层

- `PageElement.linkKind`（计算属性，不落盘不进快照编码，与 harvest 预览排除同判据）：含 appmsg_edit→`edit`；带 tempkey 的 /s? 短链→`preview`；其余 ""。harvest 侧预览链接明确排除出编辑入口候选并计数（`Facts.previewExcluded`，进实况行）；主循环点中预览元素时先行 `perception` 步标注「临时预览链接、点开是预览页不是编辑器、不得据此认定可编辑或已发表」（针对现场「草稿卡标题点开的是带 tempkey 临时预览页」一幕）。
- hover 显形探测 `WebController.hoverRevealProbe`：卡点打开时若当前页无 edit 链接元素且无可编辑元素（入口型卡点），主 frame 先记可见可操作元素签名集，对至多 8 个卡片状容器派发 mouseover/mouseenter/mousemove，Swift 侧等约 450ms 复采签名集，差集即新显形元素——探到写进去向提示与步流；探不到把探测实况记入卡点 `perceptionBlindNote` 并以 `perception` 步如实记账盲区，不假装已排除。只探测不点击；子 frame 的 hover 显形不在探测面（未证项）。

## 6. F6 梯尽结案 harvest 实况节

- `InterventionGate.failureSummary` 增加 harvest 实况节（参数带默认值，自检十八既有调用不破）：有实况引梯账最近一次回写（`Facts.line`：候选总数、来源分布、预览排除数、实证 appmsgid 数、采用路线或落空原因）；从未运行过 harvest 时明示「未运行 harvest（直达 URL 一级未到达或采集结果未回写梯账）」，不得缺席。`capabilityFailureError` 统一传梯账实况。

## 7. 自检二十一（回路级，诊断 D5 的针对性补强）

SelfTestView 新增「自检二十一：绕行梯引擎驱动回路」＋引擎 `verifyLadderFix`＋新合成页 `test-ladder.html`／`test-ladder-zero.html`（已注册 pbxproj，validate_project 资源集同步为 15 项 HTML）。测试前后保存/恢复引擎梯账、卡点、步流、目标与预算，结束不留现场。

- 纯逻辑断言 8 条：第 1 级逐项验收状态机；harvest 结构化来源（data 裸 ID＋onclick 模板拼装、预览排除计数）；内嵌数据直用；跨页模板；零候选实况行；F6 结案文案双路（有实况／未运行）；词表外判定精确命中；linkKind 三分。
- 回路断言（真实调用主循环同款生产函数在合成页驱动，非纯函数镜像）：场景A——单次信号开卡点只下达不记 attempted＋入口型卡点感知步在场；生产记账喂齐手段后，推进钩子不等第二次信号即结第 1 级并驱动第 2 级（test-ladder 的编辑 ID 只在 data 属性、模板只在 onclick，子 frame 另置带 ID 编辑链接）成功、卡点关闭；卡点关闭后 done 梯门放行。场景B——done 梯门拦下在开卡点的 done、引擎驱动直达级后才放行。场景C——零候选页（全页仅一条预览链接＋常驻弹窗）：第二次信号推进，第 2 级落空（实况含预览排除 1 条）、第 3 级重载后弹窗仍在→梯尽抛失败结案，文案含 harvest 实况节且梯账 exhausted、卡点已关。场景D——澄清注记后卡点保持在开；词表外动作「teleport」经生产处理函数后记账留痕、计入卡点证据、引擎未置失败（「不清快照」为处理函数的结构属性：其实现不含快照清除与状态置位调用）。
- 纯函数 `DirectTargetHarvest.build` 另以 JS 等价镜像在本机冒烟 6 例（结构化拼装／内嵌直用／跨页／零候选／自检十八旧模板拼装回归／零候选页预览排除），输出与断言逐项一致。**Tier A 未在本机预跑**（无本地 Swift 运行时，与既往各单同口径），待真机点按自检二十一回读。

## 8. 红线自查

- SafetyPolicy 零改动、MikaWebApp.swift 单持有者零改动：`git diff aee0241 -- MikaWeb/SafetyPolicy.swift MikaWeb/MikaWebApp.swift` ＝ 0 行（本单只读引用 SafetyPolicy 判定做分类，介入分类门语义不回退：安全类照常停车、澄清类不收紧）。
- 无新依赖（Package/第三方零新增；pbxproj 仅新增两张合成页资源条目，validate_project.py 期望资源集同步）；凭据不落盘（梯账/卡点账只含页面 URL、动作名与页面实证候选，与模型每轮可见快照同源）；用户可见文案无「并行执行」（新增文案已逐条核对）；未合 main；父级 SPEC 文件与诊断文件未动、未提交（诊断文件保持未跟踪原样）。
- validate_project.py 全 PASS（31 源、资源集 15 项 HTML）。

## 9. 发版证据链

- CI 首跑 **41572740446 为 tee 假绿**：run 结论 success，但日志原文双核对发现 `error:` 两处、BUILD SUCCEEDED ×0——`OpenStall.frameCloseTried` 是 private(set)，AgentEngine 两处直接赋值（driveDialogBypass 与 runTargeted 弹窗分支）不可编译。修复提交 `4889fa0`：新增 `OpenStall.noteFrameCloseSignal()`（记出手＋记验收收口一处），两处改走该方法。
- CI **41572944643** success，日志原文双核对：70 条 SwiftCompile、BUILD SUCCEEDED ×1、BUILD FAILED ×0，唯一 `error:` 为既有 AppIntents 训练噪声；test-ladder.html 与 test-ladder-zero.html 均在打包列。
- Release **41573124585** success：agvtool 置号 **202611030336**、Archive Succeeded、Successfully uploaded package；dSYM artifact `dsym-41573124585` **5,344,001 字节**实存未过期（dSYM 包已下载落盘核对内含 DWARF）。
- ASC 状态：**待阿仁亲验**（本单未记 VALID、未挂组）。

## 10. 未证项（不得声称已验）

1. **自检二十一 Tier A 未真机运行**：回路场景为合成页驱动代码（生产函数直调），真机点按结果待回读；尤其场景A 中子 frame（srcdoc）的 harvest 采集是否到达，取决于 WKUserScript 对 srcdoc frame 的注入——到不到都成立（主 frame 的 data＋onclick 拼装路径独立成立），但「全 frame 采集在真页面 iframe 上的实况」未证。
2. **真公众号草稿列表页的 harvest 实况未验**：真页面的候选形态（ID 藏在 data 属性/脚本数据的程度、模板可得性、相对地址基）未经真机采集回读；采不到时第 2 级如实落空推进第 3 级，不编造。
3. **hover 显形在真页面的有效性未验**：探测只覆盖主 frame、且只对 JS 监听型 hover（及 elementFromPoint 命中目标）有意义；纯 CSS :hover 由引擎悬停状态驱动、合成事件未必触发——探不到时盲区如实记账，编辑控件若为无文本图标仍可能不在感知面。
4. **第 1 级验收口径的边界**：揭示复判与坐标点击同源一次 click 实证（口径已明示）；「第二个不同目标键」是替代入口的近似判据（模型点开无关元素也可能凑齐），预算强制结级与 done 梯门是其兜底；真机样本可再校准。
5. **runConfirmed 弹窗路径**沿用直达第 3 级（未纳入「先第 2 级」的新推进序）：已确认动作属安全语义、样本罕见，本单只做卡点账联动，推进序差异如实记录在此。
6. playbook 哈希迁移在 Joey 设备上的落盘同步未证（与既往各单同口径）。
