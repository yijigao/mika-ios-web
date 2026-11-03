# AUTONOMY-FIX 案卷（2026-11-03）：自主完成逻辑——介入分类门＋绕行梯

立项：Joey 2026-11-03 10:06 亲令「发文章不该让我出面，任务是让他自己完成的」。现场两例（构建 0042，09:58–10:00）：草稿编辑入口点不开→agent 请用户手动打开编辑页；条款弹窗合成点按无效→agent 请用户手点「取消」。两处都不是安全类，却都停了车等用户代劳。本单把「停车等用户」收紧为只许安全类，能力类卡点一律走绕行梯、梯尽失败结案。

基线：`feat/ui-legibility` tip `8a518e3`（构建 202611030209）。分支：`feat/autonomy-fix`（未合 main）。功能提交 `34f954a`＋行合并修复 `2f7265d`。

## 1. 分类门实现位置与口径

- `InterventionKind {safety, capability, clarify}` 与纯函数 `InterventionGate`（AgentEngine.swift，StepBudget 之后）：分类只发生在介入触发点，安全类在调用处直接认定、只读引用 SafetyPolicy 的判定结果——`SafetyPolicy.check` 的 `.confirm/.manual`（付款/授权确认、密码/验证码、发表确认走确认通道）与 `SafetyPolicy.uploadDecision` 的 `.confirm`（SP-01）照常停车，本单未改 SafetyPolicy 一字（红线自查见 §5）。
- `ask_user` 分流（主循环 ask_user 分支）：`InterventionGate.classifyAskUser(declared:question:)`——模型新声明字段 `AgentAction.askKind`（ModelClient.swift，Decodable 容忍缺省；系统提示 JSON 模板与说明同步）：`manual/capability` → capability；声明 clarify 但问题文本命中「请用户操作网页」措辞标记（亲手/手动点/手动打开/请在网页/帮我点/打开编辑页等 20 个标记）→ capability（防声明绕门）；其余 → clarify，照旧 `.question` 停车等待（任务歧义澄清不在收紧范围）。
- capability 命中 → `handleCapabilityStall` 驱动绕行梯：成功则主循环在本轮继续（不 return、不停车）；梯尽抛 `InterventionGate.failureSummary` 结案错误，由 launch 外层 catch 置 `.failed` 并推进队列。
- 弹窗点按无响应（`modalInterventionText` 改定位为「能力类卡点信号判定」，返回值不再作介入文案）：runTargeted 与 runConfirmed 两处命中点均不再置 `.waitingManual`——改走 `driveDialogBypass`（梯级③）；runTargeted 成功→`.strategySwitch` 交模型按新快照重判；runConfirmed 成功→已确认动作原样放回 `.waitingConfirm`（页面已干净，用户在干净页面重新确认——确认属安全类，引擎不代行）；失败→失败结案。
- 失败结案文案模板：`任务未能自主完成：<卡点>。已试路径：<梯账逐级留痕>。页面证据：<当前页 URL/标题/可见文本摘要>。…`——自检十八对措辞做负断言（不含亲手/请用户/手动点/手动打开/请你点）。
- 循环熔断口径不变（3/5/7 分级与 tripped 停驻是失控保护、不是请用户代劳）；两处 pendingLoopHint 与系统提示（ModelClient）的 ask_user/受阻换路/弹窗段已同步新口径（删除「需要用户做的那一步」「等用户亲手点按」类指引）。

## 2. 绕行梯各级与 URL 模板实证来源

`BypassLadder`（纯状态：attempted＋notes，Equatable，随任务存活）：

- **梯级① 既有手段轮试（existingMeans）**：引擎下达轮试指令并注入强提示（揭示复判→站点模式→替代入口→坐标点击→frame 感知关闭，每项一轮），模型试完仍卡住再发 ask_user 推进梯级。弹窗路径里，执行层自身的 frame 感知关闭（框内五阶段）即本级的实证，在抛错前已试过——`driveDialogBypass` 据此补记本级，不重复空转。
- **梯级② 直达 URL（directURL）**：`WebController.harvestDirectTargets()` 收集执行页全部 `a[href]` 原始属性（上限 400），纯函数 `DirectTargetHarvest.build(hrefs:)` 提取：带 `appmsgid` 的 `appmsg_edit` 绝对链接直接采用（**模板与 ID 同源实证**）；只有无 ID 的编辑模板时，用其它链接里实证到的 appmsgid 拼装；无 ID 或无模板 → nil，此级失败。**URL 模板只从页面已有链接提取，不凭记忆编造**（build 只接受含 `://` 的绝对链接）。候选导航失败记为此级失败并推进下一级，不杀任务。
- **梯级③ 弹窗导航绕行（dialogNavBypass）**：`attemptDialogNavBypass`——先 frame 普查（`WebController.dialogCensus()`＝probeFrames 的执行页包装）记弹窗签名集；非编辑页→`reloadExecutionTab` 重载后复查；编辑页（URL 含 appmsg_edit 或快照含 editable 元素）→找「保存/存草稿」元素、过 `SafetyPolicy.check` 须 `.allow` 才点、点后 `settledCapture` 回读落定（未稳即此级失败、不赌未存内容）→导航同源根→原地址返回→复查。成功只认「绕行前弹窗签名在复查中全部消失」。
- 梯账持久化：SessionSnapshot 新增可选二键 `ladderAttempted/ladderNotes`（旧快照无键照常解码、梯账为空），persistSnapshot/restoreSnapshot/startInSession 三处同步——进程被杀恢复后已试梯级不重走。

## 3. playbook 同步（哈希迁移）

SkillStore 两份内置 playbook 改字符串（落盘未改副本由既有哈希迁移自动同步）：

- `blocked-reroute`：「求助口径（最后手段）」节改为「求助口径（只许澄清，不许代劳）」——删「提出需要用户做的那一步」，改为能力卡点如实交代卡点后由引擎推进绕行梯、安全类才由用户出面；换路顺序标题注明与引擎绕行梯同向。
- `wechat-oa-editor`：弹窗处理第②项删除「停下等用户亲手点按『取消』」，改为引擎走弹窗导航绕行（离开前先保存回读落定）；第③项「用户点完后」改为「绕行回来后，先回读页面现状（正文与封面是否都在）」。

## 4. 自检十八（AUTONOMY-FIX）

SelfTestView 新增「自检十八：自主完成分类门与绕行梯」＋新合成页 `test-autonomy.html`（已注册 pbxproj，validate_project 资源集同步为 13 项）：

- 纯函数断言（`AgentEngine.verifyAutonomyGate`）：分类门 6 条（两条现场原例→capability、声明 manual 覆盖、声明 clarify 但文本能力类→capability 防绕门、两条澄清问句→clarify）；安全类回归 3 条（SafetyPolicy「确认付款」→.confirm、type 进 password→.manual、SP-01 非任务生成→.confirm/任务生成→.allow）；绕行梯状态机逐级推进＋梯尽＋快照往返；结案文案要素与禁用词负断言；直达提取三路（直用/模板拼装/无候选 nil）。纯逻辑另以 JS 等价镜像在本机冒烟，六个分类样本与三个 harvest 样本输出与断言逐项一致。
- 合成页驱动（`verifyAutonomy`）：链接农场 harvest 实测提取到 appmsgid=100000001（页面真实链接）；条款弹窗（role=dialog、按钮无行为、window.name 模拟重载即消失）在场基线经 frame 普查命中；`attemptDialogNavBypass` 非编辑页重载分支实测弹窗签名消失；全程断言引擎未进入 `.waitingConfirm/.waitingManual` 停车态。**Tier A 未在本机预跑**（无本地 Swift 运行时，与既往各单同口径），待真机点按自检十八回读。
- WebController 新增接缝仅三处只读/导航包装：`harvestDirectTargets`、`loadOnExecutionTab`、`dialogCensus`；弹窗节注释的「转人工」旧口径同步改为绕行梯口径（错误前缀与行为未动）。

## 5. 红线自查

- MikaWebApp.swift 单持有者零改动：`git diff 8a518e3 -- MikaWeb/MikaWebApp.swift` ＝ 0 行。
- SafetyPolicy 零改动：`git diff 8a518e3 -- MikaWeb/SafetyPolicy.swift` ＝ 0 行（本单只在引擎层读它的 check/uploadDecision 返回值做分类）。
- 无新依赖（Package/第三方零新增；pbxproj 仅新增 test-autonomy.html 资源条目）；凭据不落盘（梯账与结案证据只含页面 URL/标题/文本摘要，与模型每轮可见快照同源）；用户可见文案无「并行执行」（全仓仅 SessionListView 既有注释一处「不承诺『并行执行』」，非本单新增）；未合 main；父级 SPEC 文件与 next-directions 目录未动、未提交。
- validate_project.py 全 PASS（31 源、资源集 13 项含 test-autonomy.html）。

## 6. 发版证据链

- CI 首跑 **41565837632 为 tee 假绿**：run 结论 success，但日志原文双核对发现 BUILD FAILED ×1、SwiftCompile 0 条——AgentEngine.swift:1680 一处编辑把两行并成一行（sleep 与 harvest if 同行）致编译错误。修复提交 `2f7265d` 后重跑。
- CI **41565955352** success，日志原文双核对：70 条 SwiftCompile、BUILD SUCCEEDED ×1、BUILD FAILED ×0，唯一 `error:` 为既有 AppIntents 训练噪声；test-autonomy 资源打包在位。
- Release **41566175241** success：agvtool 置号 **202611030227**、Archive Succeeded、Successfully uploaded package；dSYM artifact `dsym-41566175241` **4,930,038 字节**实存未过期。
- ASC 状态：**待阿仁亲验**（本单未记 VALID、未挂组）。

## 7. 未证项（不得声称已验）

1. **自检十八 Tier A 未真机运行**：分类门/梯状态机为纯函数（已 JS 镜像冒烟），harvest 与重载绕行分支为合成页驱动代码，真机点按结果待回读。
2. **真公众号编辑器往返不丢稿未验**：梯级③编辑页分支只保证「离开前保存 settle 落定」这一前提；微信编辑器真实 DOM（editable 判定、保存入口形态、直达返回后正文完整）未经真机证实——Tier B 第一条须在公众号编辑器弹窗场实测：先存草稿并回读→绕行往返→回读正文与封面都在。
3. **直达 URL 在真草稿列表页的实证形态未验**：mp.weixin.qq.com 列表页链接的真实 href 形态（是否绝对、是否带 appmsgid）未经真机 harvest 回读；若真页面用相对/脚本跳转链接，梯级②会如实记无候选并推进梯级③，不编造。
4. **askKind 声明依赖模型配合**：模型不声明时靠文本标记兜底，措辞表未覆盖的请用户代劳说法可能漏判为 clarify（停车问答形态，后果是多停一次而非误执行）；标记表可按真机样本增补。
5. playbook 哈希迁移在 Joey 设备上的落盘同步未证（与既往各单同口径）。

## 8. Tier B 真机复测清单（交 Joey）

1. 自检十八 Tier A 全过（分类门、harvest 实测、弹窗重载绕行、全程无停车态）。
2. 公众号场复刻 0042 两例：①草稿编辑入口点不开时，agent 不再请用户打开页面——应见绕行梯步流（既有手段轮试→直达 URL 打开编辑页，或梯尽失败结案）；②条款弹窗点按无响应时，应走弹窗导航绕行（编辑页先保存落定→离开→返回），回读正文不丢、弹窗消失，全程不出现请用户手点的介入卡。
3. 安全类回归：发表确认仍出确认卡停车、密码/验证码仍停手输——分类门未误伤安全类。
4. 澄清类回归：任务信息不足时 agent 仍可用 ask_user 提问并停车等待（不被绕行梯吞掉）。
