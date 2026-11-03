# WECHAT-EDITOR-NAV 实施案卷（2026-11-03）

规格：WECHAT-EDITOR-NAV-SPEC-2026-11-03.md（父级单据）。基线：feat/wechat-cover-fix tip `9995b46`（构建 202611030042）。分支：`feat/wechat-editor-nav`，未合 main。提交：功能 `2479fb7`、Part C 纠正 `9977984`、轮子适配 `e6ea9ca`（证据提交另计）。

现场事实（Joey 2026-11-03 09:20 真机截图＋09:36/09:37 两次口径纠正，本单不推翻）：成果台账拦下一次重复提交（《把待办清单变短》08:14 已提交·待核查、本次重复提交已拦下）；循环熔断与 blocked-reroute 换路手册正常触发；新文章场先保存再找封面入口；generate_cover 正常；中途一次模型过载为外部瞬时错误。主卡点＝微信编辑器入口感知盲区：草稿编辑入口、封面设置入口在元素感知中找不到/被判不可操作（草稿箱标题、首页近期草稿、「选择已有内容」、切换站点模式四路皆败），发表记录页对不上目标文章；set_site_mode 重载被当逃生手段（本场重载前已保存未丢稿）。**构建归属（09:37 纠正定版）**：截图上半截的「已达最大 42 步」死路是更新前构建 1932 的旧账；更新到 0042 后任务继续往前走，**0042 上并未撞段限**；入口感知盲区发生在 0042 场（已确认）。Part C 因此按规格原口径办（回读存证、是终局口径才改），见 Part C 节。

## 交付一览

- 构建 **202611030144**（0.1.0），ASC 状态：**待阿仁亲验**（本单不代记 VALID/挂组）。
- CI Run 41561457667 success；日志原文双核对：70 条 SwiftCompile，PageState/WebController/AgentEngine/SkillStore/SelfTestView/ModelClient 均在编译列，test-nav.html 资源打包在位（日志 2 处），BUILD SUCCEEDED ×1、BUILD FAILED ×0，唯一 `error:` 为既有 AppIntents 训练噪声（SSU artifacts）。
- Release Run 41561654443 success（job beta success）；agvtool 置号 202611030144；fastlane 日志 `Successfully uploaded package` ×1；dSYM artifact `dsym-41561654443` 实存 **4,748,912 字节**、未过期。
- validate_project.py 全 PASS（31 个 Swift 源、资源集 12 项含新增 test-nav.html）。
- 本机预检：抽取脚本、重扫脚本、揭示脚本三段 JS 经抽取后 `node --check` 语法全过；nameOf 名源解析以替身对象在 node 里行为级冒烟 7 例全过（文本/aria/alt/value/背景图词干/data-URI 无名/none，其中 data-URI 一例冒烟先失败、修后通过，见 Part A）。
- 过程注记（构建迭代）：本分支曾先行 Release 出构建 **202611030133**（Run 41560472592、dSYM 4,745,239 字节），其内容含一处依当时 steer 所作的段限兜底文案对齐；Joey 09:37 纠正口径后该改动已撤回（提交 9977984）、Part A 又增轮子适配（e6ea9ca），故 0133 **被 0144 取代、不作复测目标**。中间 CI 41561039292（撤回点）同为 success。

## Part A：感知补盲（引擎侧，通用改进，未写死微信 DOM）

### A1 元素抽取补入无文本控件＋名源标注（PageState.swift）

- 新增名源解析 `nameOf`：优先级 可见文本（innerText）→ aria-label → title → alt → 关联 label → placeholder → value（INPUT/BUTTON 的值，如提交钮文案）→ 背景图文件名词干（`url(.../cover-entry.png)`→「cover entry」）；全无则名为空、来源 `none`。data:/blob: 背景图没有文件名可读，只记来源 `bg`、名留空，不编假名（本机冒烟先抓到 data-URI 被误当名的问题，已修）。
- 快照元素新增两字段：`nameSource`（名源标注，模型据此判断无文字条目是什么入口）与 `inView`（与视口是否相交，见 A2）。PageElement 全仓只有 extract 一条解码路径，字段由抽取恒定产出；guardScript 的逐字段身份校验**豁免 inView**（位置字段，滚动前后 legitimately 不同，纳入全等会把正当目标误判「已变化」），其余字段照旧。
- 语义元素：text 改走 nameOf——图标按钮（只有 aria-label）、只有 alt 的图、只有 value 的提交钮从此在快照里有名字（旧口径 text 只认 innerText/label/aria/title，alt 与 value 整类缺失）。
- 非语义补入（extras）门槛修订：旧判据「有文本或 aria/title」改为「任一名源（文本/aria/title/alt/背景图）或带背景图或带内联事件属性」；交互证据改为「cursor:pointer 或内联事件属性」（轮子适配，见轮子节）。原有防噪声门槛不动：不在语义元素内/不包裹语义元素、纯文本粗筛 ≤120 字、可见、尺寸 ≥12×12、同类嵌套只留最内层、上限 200 条。

### A2 「不可操作」判定收紧：揭示复判（WebController.swift）

- 新增 `revealElement(index:on:)`：按序号定位元素 → 自下而上逐个滚动其可滚动祖先（overflow 为 auto/scroll/overlay 且内容溢出的容器，把元素送进各容器可见区并计数）→ `scrollIntoView` 让窗口跟上 → 复判（矩形与视口相交＋中心点 `elementFromPoint` 命中落在目标本身/其子/其祖先）。回報 `RevealReport{triedSummary}` 把试过的手段写成一句人话（如「内层滚动容器逐个滚动（1 个）＋窗口 scrollIntoView，复判在视口=true、中心点可命中=true」）。
- 接入点：performClick 在「重扫轮询仍缺失」的终局前先做一遍揭示复判并重点一次（点中按正常成功收口，含弹窗存续探针）；复判仍不可达才抛错，错误原文改为「页面上找不到可点的按钮「X」（揭示手段已试：……；可能还没渲染出来或已经关闭）」——步流里从此留得下「试过哪几类揭示手段」的证据。
- 系统提示（ModelClient.system）新增口径：nameSource=bg/none 的无文字条目是真实图标入口、可点；inView=false 只表示没进视口、直接 click 即可；只有历史里出现带「揭示手段已试」清单的失败回报时才许下「无可操作入口」结论且须复述手段。

### A3 文本锚点回退（WebController.swift 重扫脚本）

- 重扫找目标的候选序扩展为：序号节点 → 精确文案候选（原有）→ **文本锚点候选**（新增）→ disabled/missing 判定。文本锚点：用 TreeWalker 找含目标词的文本节点（跳过 script/style/noscript 子树），向上 ≤6 层取最近的可点击祖先（a/button/role/input/[onclick] 或 cursor:pointer 计算样式），可见且未禁用才点。
- 安全口径：锚点路径的安全词检查只按目标词＋祖先自身的 aria-label/title 查，不拿祖先整段 innerText 查（整卡文本范围太大、会误伤）；未经确认的敏感词命中照旧 throw。

### 轮子盘点（Joey 2026-11-03 09:38 指示：先找轮子再造轮子）

候选：browser-use/browser-use 的 `browser_use/dom/buildDomTree.js`。主分支现行版已重构（该文件被移除、DOM 抽取改走 CDP 快照＋Python serializer），故取仍含该文件的 **tag 0.2.7** 原文通读（1480 行）。许可：**MIT License，Copyright (c) 2024 Gregor Zunic**，与本仓 Apache-2.0 兼容（阿仁已核）。

逐项对照三类盲区：

| 盲区 | buildDomTree.js 的做法 | 结论 |
|---|---|---|
| icon-only/无文本控件 | 交互判定 isInteractiveElement：交互光标集（26 种）→语义标签集→role 集→contenteditable→事件监听检测（getEventListeners/getEventListenersForNode，含属性回退）；属性全量抄进 nodeData.attributes，但**没有可达名称合成**（命名在脚本外的 serializer 层） | **部分适配 1 项**：内联事件属性回退（onclick/onmousedown/onmouseup 的属性或 property）移植进 extras 交互证据（见 A1）。名称合成本身该脚本没有，无可移植；其事件监听检测依赖 Chrome DevTools/控制台专属 API，其源码注释亦承认在 page.evaluate 上下文不可用，WKWebView 页面世界同样没有——不移植。光标集的其余 25 种（text/cell/resize 等）多对应编辑/拖拽语义，进抽取会灌入噪声，不采 |
| 内层滚动容器 | **没有任何滚动揭示逻辑**：getEffectiveScroll 只累加祖先滚动量给高亮覆盖层定位；视口外的元素直接不给 highlight index（viewportExpansion=-1 为「全量索引」逃生口） | 无可移植。A2 的逐容器滚动＋复判为手写（该盲区轮子未覆盖） |
| 视口外元素复判 | 抽取时二值判定（isInExpandedViewport，任一 client rect 相交，采用 IntersectionObserver 缓存可见性）；视口外不索引 | **适配 1 项**：getClientRects 任一矩形相交的判定法移植进 inViewOf（多行内联元素只取包围盒会误判；无矩形时回落包围盒，与其 svg 回退同法）。其「视口外不给索引」的总策略与本单规格方向相反（本单要求在位标注、点击时揭示复判），不采；IntersectionObserver 持久观察者模式与我方一次性 evaluate 抽取不合、且多一份页面常驻钩子（CRASH-1031 教训），不采 |

整体移植为何不做：该脚本产出的是树形 map（xpath＋属性字典＋生成的 highlight index＋页面高亮覆盖层 DOM），与本仓快照契约（扁平 PageElement 列表、data-mika-idx 标记被 guardScript 身份校验/click/type/upload/resolveTarget 全线消费、sensitive/disabled/editable 字段、文件控件例外）完全不同；覆盖层高亮是给桌面截图看的，与 WKWebView 内模型读 JSON 的形态无关。整体替换会推翻多单已验行为，风险与收益不成比例。已适配的两处手法在源码注释逐处标注出处，NOTICE 已增第三方改编说明。GPL 项目（OpenMinis）仍只学思路未抄码（本单未用）。

### 自检十六与补盲手段对应（Tier A，合成页 test-nav.html）

| 自检断言 | 对应手段 |
|---|---|
| icon-only 按钮以 aria-label 为名进快照（名源=aria-label） | A1 nameOf（aria-label 名源） |
| 只有 alt 的图标图以 alt 为名进快照（名源=alt） | A1 nameOf（alt 名源，旧抽取缺失） |
| 无文本封面入口以背景图文件名为名进快照（名源=bg、名=cover entry） | A1 nameOf（bg 词干） |
| 只有内联事件属性的无名入口凭事件证据进快照（名源=none，同型条目恰 1） | A1 extras 事件属性回退（轮子适配） |
| 内层滚动容器下方编辑入口：已进快照且 inView=false（初始） | A1 在位标注（不因不在视口消失） |
| 揭示复判：found、滚动容器 ≥1、复判在视口、中心点可命中、手段清单成文 | A2 revealElement |
| icon 按钮／背景图入口／事件属性入口／揭示后编辑入口经引擎 click 真点得动（页面结果标记在场） | A1＋A2 全链 |
| 序号标记失效后重扫经文本锚点点中整卡（回報 clicked＋结果标记） | A3 文本锚点回退 |

自检十六已登记 SelfTestView（Tier A 按钮＋Tier B 说明）。**本机无 Swift 工具链，自检十六 Tier A 未在本机预跑**——其断言靠 CI 编译＋真机 Tier A 执行验证（见未证项）。

## Part B：playbook 收紧（SkillStore.swift，wechat-oa-editor，哈希迁移）

在 wechat-oa-editor 新增「编辑器入口寻找与未保存禁重载」节，三条：

1. **未保存禁重载逃生**：还在编辑器里、正文未存草稿并回读成功（回草稿箱核对标题与字数）前，禁止 set_site_mode 或重载/导航离开编辑器页当逃生；确需重载先存草稿→回读确认→说明里写明已保存。
2. **入口寻找顺序写死**：①草稿箱列表点条目标题 → ②同一条目其它落点（封面图、时间区）——标题与其它落点各只试一次（配合循环熔断，同落点不反复点）→ ③「选择已有内容」选中该草稿 → ④scroll 揭示（含页面内滚动区域滚到底）后再看新清单（inView=false 是没进视口不是不存在）；四级走完仍无才许说无入口且汇报写明试过哪几级与揭示手段。
3. **发表记录对账**：标题精确匹配＋记录时间在成果台账提交时刻 ±10 分钟内，双条件同中才算找到；全程只读（不点发表、不重发）；对不上如实记「待核查」，不回编辑器凭残稿下结论。

哈希迁移口径不变：Joey 设备上该 playbook 若从未被手改，新版自动同步；若被手改过则不覆盖（见未证项）。

## Part C：段限暂停文案复核（0042 已发版原文存证，未改）

按 Joey 09:37 纠正后的事实基础办理：0042 真机未撞段限，截图里的 42 步死路是 1932 旧账。回读基线 `9995b46`（即 0042 的源码）中段限暂停的三处用户可见文案原文：

- 段限到（主循环收口，segmentExhausted 分支）：
  > 本段步数已用完（第 \(stepBudget.segment)/\(StepBudget.maxSegments) 段，累计模型步 \(stepBudget.totalUsed)/硬顶 \(stepBudget.hardTop)）——进度已存检查点（目标、成果台账、页面与历史都在），点「继续」开启下一段接着跑，不会重跑已完成部分
- 硬顶到（同处 hardTopReached 分支，resume() 里同文案再现一次）：
  > 已达全任务步数硬顶（共 \(stepBudget.hardTop) 步模型决策）——请检查结果，或换个说法重新开始新任务

判定：段限暂停文案已是明确口径（进度已存检查点＋点「继续」开新段），**按规格不动**；硬顶文案是真终局（硬顶后 resume 明确不开新段），其「重新开始」表述与行为一致，保留。本分支对 AgentEngine 的净改动只剩自检十六门面函数，Part C 呈现与 0042 逐字一致（git diff 对基线可证）。

一处观察（记录不改）：主循环收口的兜底 else 分支仍留有旧句「已达最大 \(limit) 步，请检查结果或重新开始」。该分支在预算状态自洽时不可达（主循环以 `while stepBudget.canDecide` 为界，退出必 segmentExhausted 或 hardTopReached），本单按纠正后的口径未动它；若后续要清理，按一处文案对齐小单处理。本单过程中曾依一度下达的 steer 改过该兜底句并出过构建 0133，纠正到达后已撤回（9977984），0133 被 0144 取代——来龙去脉留此备查，不把 0042 写成「已撞段限」。

## 红线自查（对基线 9995b46 实查）

- MikaWebApp.swift：git diff **0 行**（单持有者形态未动）。
- SafetyPolicy.swift：git diff **0 行**。
- 无新依赖（package/依赖文件未动）；凭据不落盘；用户可见文案无「并行执行」（diff 全文检索 0 处）。
- 父级 SPEC 文件与 next-directions 目录未动、未提交；未合 main。

## 未证项（不得视为已验）

1. **真编辑器 DOM 形态未证**：微信公众号编辑器的真实入口结构（图标名源构成、内层滚动容器层级、封面区锚点形态）不在合成页复刻范围内——本单**不声称已在真编辑器验证**。Tier B 第一条（见下）才是实证。
2. 自检十六 Tier A 未真机运行：本机无 Swift 工具链，断言逻辑靠 CI 编译通过＋代码走查；揭示复判的中心点命中在真微信容器（可能的 transform/缩放）上是否成立，未证。
3. nameOf 的行为验证只到替身对象级（7 例冒烟）；真实页面上多名源冲突时的优先级效果、bg 词干对微信 sprite 图（多图标拼图、文件名无语义）的命名质量，未证——sprite 时名可能为空或无意义，靠 nameSource=bg/none 在位＋上下文判断兜底。
4. 事件属性回退的噪声面未测：真实页面上带内联事件属性的元素数量分布未知，extras 上限 200 与最内层过滤是否足够压噪，未证。
5. inView 改走 clientRects 口径对既有流程（点击身份校验已豁免该字段）无契约影响，但模型据 inView 做判断的实际效果未真机观察。
6. playbook 哈希迁移在 Joey 设备上的实际同步取决于其是否手改过 wechat-oa-editor（改过则不覆盖、需人工处理），未证。
7. 文本锚点回退在真实封面区（祖先层级 >6 或祖先无任何可点信号时）的命中率未证；超 6 层即放弃、按缺失处理。

## Tier B 真机复测清单（交 Joey，第一条即实证项）

1. **公众号编辑器原场景**（复刻 09:20 场）：更新到构建 202611030144 后，先跑自检十六 Tier A（本地自检页按钮），再用真实任务进公众号后台找一篇已存草稿的编辑入口与封面设置入口——预期：入口按 playbook 写死顺序（标题→其它落点→选择已有内容→滚动揭示）找到；点击失败的步流里出现「揭示手段已试」清单；全程未保存前不出现 set_site_mode 重载逃生；发表记录对账按标题＋±10 分钟双条件只读核对。
2. 观察步耗：同一场任务的模型决策步消耗应较 0042 场明显下降（入口少走弯路）；段限若再撞，暂停文案应为「本段步数已用完……点「继续」开启下一段」的明确口径（0042 已如此，本构建不变）。
