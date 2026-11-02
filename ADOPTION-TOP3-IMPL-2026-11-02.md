# 借鉴清单 Top-3 落地（ADOPTION-TOP3，2026-11-02）

依据：`~/workspace/mika-ios-eval/ADOPTION-STUDY-2026-11-02.md` 第 1/2/3 条（Joey 2026-11-02 17:33 批准排入本轮）。三条全部落地，无一条因架构冲突缺席。

## 交付事实

- 构建 **202611020942**（0.1.0），build id `37e5fc77-401e-4084-872b-b269a00a6a81`：分支 `feat/adoption-top3`（自 `fix/background-resilience` 新开，即 0838 的交付分支；未合 main/其他分支），代码提交 `70e7dab`。
- CI Run **41422462098** success：日志实查 52 条 SwiftCompile（含 CookieBackup／LoopDetector／SkillStore 三个新文件的独立编译行，双架构）＋`** BUILD SUCCEEDED **` 1 处，结论双核对。Release Run **41422717224** success：日志含 agvtool 置构建号 202611020942、`Successfully uploaded the new binary to App Store Connect`（09:44:38Z）。
- ASC 回读：processingState=**VALID**、expired=**false**、usesNonExemptEncryption 由 null PATCH（HTTP 200）→**false** 回读确认；Internal 组（6a722377-d7f3-4c76-876f-4c35e193e0e4）挂载 POST **204**，组内回读居首 [202611020942, 202611020838, 202611020808]。
- validate_project.py 全 PASS（22 个 Swift 源恰好编译一次）。
- **过程注记 1（CI 重复派发）**：首次派发 ci.yml 时 gh 客户端报 HTTP 500，但服务端实际已建 run；重试后形成两个同提交 run（41422462098 与 41422491385），**双双 success**，以先建者为验收依据。
- **过程注记 2（ASC 索引延迟，与 0838 同型）**：Release 完成后首次回读新构建未进 ASC 索引（列表最新仍是 0838），等约 90 秒后按 Release 日志锁定的构建号 202611020942 重查才出现并完成全部回读——口径不变：先以构建号定目标再核状态。

## 第 1 条：登录 Cookie 备份／回注（新文件 `CookieBackup.swift`）

### 问题与设计（参数出处与自研边界）
WebKit ITP 把高流量域名标为 prevalent、无真实用户手势满 30 天清其全部站点数据（含 HttpOnly 登录 Cookie）；agent 浏览不算手势，登录态会静默集体消失、无任何报错。设计参数（同步节流、按域分存全量元数据、实时优先回注、30 天访问老化、只存本地）取自 ADOPTION-STUDY 第 1 条对 OpenMinis `CookieBackupStore.swift` 的事故复盘研究——**GPL 只学问题与参数，代码全部自研**：存储格式用自研 JSON 记录（非其 Netscape 文本），域名归一为自研简化版（末两段＋常见两级公共后缀取三段）。

### 实现
- `@MainActor CookieBackup.shared`。存储：Application Support `MikaWeb/CookieBackup/`，按可注册域一个 `<域>.json`（Cookie 全量元数据：name/value/domain/path/expires/secure/httpOnly）＋`visits.json`（域→最后访问时刻）；目录排除 iCloud 备份，文件写带 `.completeFileProtectionUntilFirstUserAuthentication`。
- 同步（`sync`）：①老化清理——最后访问超 30 天的域名删备份、不再回注（无访问记录的以文件修改时间兜底计龄）；②回注——备份有、实时 store 无、未过期的条目逐个 `setCookie` 写回（**实时条目优先，备份绝不覆盖实时值**）；③快照——以「实时＋刚回注」并集为最新备份落盘，过期剪枝，实时已空且未回注的域名删文件；④域名数超 1000 按最久未访问淘汰。
- 触发点（节流 60 秒，进程内首次必同步）：BrowserTab `didFinish`（真实导航：记访问＋同步——用户手动建立的登录态及时入备份、回注也借导航时机发生）与 WebController.state() 取快照前（任务开始先恢复登录态再让 agent 看页面；`agentWorkSuspended` 驻停期不做，守 0838 的后台收敛口径）。
- 留证与隐私：回注发生时往既有诊断通道写一条「Cookie 回注」（只含域名＋恢复条数）；**任何路径不记录 Cookie 名／值**，备份不进 Keychain、不同步、不进仓库。

### 已知取舍（如实）
- 经 HTTPCookie 属性重建的 Cookie 无法保留 HttpOnly 标志（WebKit 无编程设置该标志的 API），回注的原 HttpOnly Cookie 变为同源脚本可读——「保住登录态」与系统限制之间的取舍，与所参考设计口径一致。
- 同一取舍的另一面：用户在某站「退出登录」后，30 天保留期内备份会把会话顶回（下次导航即恢复登录态）。这是防 ITP 误清与「退出即失效」之间的固有冲突，本轮按研究口径优先保登录；真机清单第 9 项即以此验证回注真实生效。

## 第 2 条：跨步循环检测与分级熔断（新文件 `LoopDetector.swift`＋AgentEngine 接入）

- 指纹＝（动作＋目标＋结果）FNV-1a 哈希，滑动窗口 30 条：click/type 的目标取模型所见元素稳定描述键（ElementDescriptor.key；type 再掺输入文本指纹，同元素换内容不算同动作），navigate 取网址、scroll 取方向、wait 取秒数、open_new_tab 取网址、use_skill 取名称；结果取 executed／strategy-switch／ok／loaded 等结局标签。
- 分级（阈值按我方步数上限 5–50 的量级适配——所参考设计的 10/20/30 面向其更长任务，原样搬来在我方步数耗尽前几乎不触发）：同一指纹 ≥3 一级提醒、≥5 二级严重提醒、≥7 熔断。提醒双通道：以「loop」步记入历史（模型与用户都可见）＋注入下一次模型提示（severe 附「再重复将自动停下」）；同一指纹同一级别只报一次（级别台账防刷屏）。
- 熔断＝**真正停驻**：状态置 .paused（人话原因＋出路），快照落盘，执行绑定与进度保留——与步数上限停驻同形态，点「继续」即接着跑；熔断时该指纹的窗口记录已在检测器内清掉，恢复后重新计数、不会一恢复就立刻再熔断。
- 与既有机制不冲突（逐项）：步数上限不变（熔断是更早更具体的停驻）；瞬时错误重试治单步失败、本检测治多步成功但无进展，正交；.waiting（确认／手输）轮次不记指纹，用户介入天然断链；runConfirmed 已确认动作不记指纹（用户在环内）；安全判定路径一字未动，检测只观察已执行结果、不参与放行。

## 第 3 条：Skill 体系（新文件 `SkillStore.swift`＋ModelClient／AgentEngine 接入）

- 格式与存储：一个 skill＝Application Support `MikaWeb/Skills/<name>/SKILL.md`（YAML frontmatter 只认 name＋description 子集，自研解析；description 即触发依据）。内置 playbook 首次运行时落盘为同格式文件（已存在不覆盖，留用户改的余地）。
- 渐进披露：系统提示尾部只放清单（name＋description，≤20 条、单条截断 160 字）；新增动作 `use_skill`（AgentAction 加 skill 字段，容缺解码），模型命中后点名加载，正文注入本任务后续每次调用的提示（「已加载 playbook」段）；加载结果以「skill」步记入步流——**命中加载在对话里可见**；重复加载、点名不存在都有明确步回执。已加载名单随会话快照落盘，恢复时按名重读正文。
- 首批内置 2 个（均为本项目自有经验沉淀，不搬运任何外部 skill 内容）：`zhihu-editor`（FIX2 沉淀：框架编辑器须走原生管线、type 失败最多再试一次、发布硬判据＝字数>0 且按钮非 disabled、发布后回读见内容才算数、回答与评论入口差异、重排与策略切换口径、登录验证码边界）与 `form-fill`（通用填表顺序、逐项核对、提交判据）。
- 设置页新增「Playbook（经验手册）」只读列表（名称＋用途＋内置标记）与口径说明。
- **安全口径**：playbook 是提示层经验，系统提示词明示安全规则永远优先、冲突以安全规则为准；SafetyPolicy 判定不读 playbook，加载不改变确认／手输任何流程。**只做指令型**：无任何可执行脚本机制（ADOPTION-STUDY「明确不抄的」第 6 条）。本轮未做导入通道（文件／GitHub／zip）——研究清单里属该条的扩展项，brief 本轮范围为存储＋披露＋内置，导入留待后续。

## 红线自查（git diff 对基线 3353e2f 实查）

- `MikaWebApp.swift`（AppObjectGraph 单持有者形态）：**零改动**。`SafetyPolicy.swift`：**零改动**，安全确认门语义不变、无新绕行（use_skill／循环裁决／Cookie 同步都不经安全判定也不改其结果）。
- 0838 行为零回退：`BrowserDockView.swift`、`ContentView.swift`、`AgentChatView.swift`、`BrowserView.swift` **全部零改动**——无自动展开、输入栏最上层、键盘收起、介入对话提示原样；AgentEngine 的改动纯增量（新字段、新分支、提示拼接、快照可选字段——旧快照照常解码）；WebController 只加两处 Cookie 挂钩（state 挂钩带驻停守卫）。
- 凭据面：API Key 路径未碰；Cookie 备份只存本机 Application Support（文件保护＋排除备份）、不进日志／截图／仓库明文（诊断只记域名＋条数）。
- 无新第三方依赖（只用 Foundation/WebKit 系统框架）。许可：OpenMinis（GPL）仅学设计与参数、代码自研；Palvia（MIT）本轮三条未引用其代码（其 SkillTools 属导入实现参考，导入未在本轮范围），NOTICE 无需变更。

## 给 Joey 的合并复测清单（0838 原 8 项＋本轮 3 项，装 TestFlight 最新 202611020942）

### 0838 原 8 项（不回归验收）
1. **切后台续跑**：任务跑一半切去别的 App，两分钟后回来——任务应已自动续跑（或经持续处理在后台继续推进），步数与进度不丢，不需要点「继续」。
2. **切后台不被杀**：同上场景反复几次，App 不应出现闪退／重开回到初始态；若再被系统终止，请把新的终止报告贴回主聊。
3. **锁屏同理**：任务中途锁屏，一两分钟后解锁回来应自动续跑；任务运行中屏幕应保持常亮（设置开关默认开时），任务结束后自动锁屏恢复正常。
4. **弱网导航不死**：弱网或页面未加载完时发起导航类任务，单次「页面脚本出错」只出现自动重试提示、任务继续，不再一步 JS 异常整单失败。
5. **确认门不被绕过**：触发需确认的动作，在确认后网络抖动／页面异常时动作不会被自动重做，应回到等待确认由你重新决定。
6. **强退恢复**：任务中途强退 App 再打开，应看到「上次任务在 App 退出时中断，点继续可接着跑」，点继续后从原进度接跑。
7. **开关回归**：设置里关掉「任务运行时保持屏幕常亮」后任务期恢复系统自动锁屏；再打开恢复常亮。
8. **0808 形态回归**：介入只在对话里提示、小窗不自动展开、键盘收起、输入栏最上层均不应变化。

### 本轮新增 3 项
9. **Cookie 回注**：在 App 内浏览器登录知乎（或任一常用站），等 1 分钟以上（让备份落盘）；然后在网页里点「退出登录」，再刷新或重新打开该站——若又变回登录态，说明回注真实生效（这同时是已知取舍：30 天内退出登录会被备份顶回，属预期行为）。日常口径另验：登录后完全退出 App 再重开，登录态应保持。若期间发生过回注，「设置 → 崩溃报告」里应能看到「Cookie 回注」条目（只含域名与恢复条数）。ITP 的真实清除需 30 天无手势量级、无法即时复现，本项以前述可构造的回注验证＋代码自证为准。
10. **循环熔断**：打开「自检 → 自检三：循环熔断验证」（本地表单页，故意让模型空点提交按钮）：步流中应先后出现「循环提醒」「循环严重提醒」，最终任务以「检测到在同一处反复打转…」停驻并可点「继续」；点继续后不应立刻再熔断（重新计数）。若模型中途自行改填表单（不听指令），本项可能不触发——换个说法重跑或直接下达「反复点击页面上同一个按钮」类任务亦可。
11. **知乎 playbook 命中**：先到设置页确认「Playbook（经验手册）」列表里有 zhihu-editor 与 form-fill 两条；再给一个知乎写评论／回答任务——步流中应出现「已加载 playbook《zhihu-editor》」一步，之后 agent 的发布判读应按 playbook 口径（看字数统计与发布按钮是否 disabled、发布后回读页面确认内容出现），而不是点过按钮就报成功。

## 未做／遗留
- release.yml 加 dSYM artifact 上传（0838 案卷建议）仍未做，不在本轮范围。
- Skill 导入通道（文件／GitHub／zip）未做，见第 3 条说明。
- 分支未合 main；0838 与本轮的合并复测全过后再议合并。
