# COVER-CONSENT 案卷：封面自产＋弹窗点按升级（构建 202611021830）

- 分支 `feat/cover-gen-consent-click`（基线＝`feat/attachments-f1` tip 7b711af，含 H1/M1/F1，未合 main）；提交 aa717d7（功能）＋9716bf0（编译修复）＋02ac979（playbook 补口径）。
- 背景：Joey 2026-11-03 01:46 真机实测 1655 截图——agent 在 Mika Web 内登录公众号「知行向上工具集」，文章《用豆包整理会议纪要：一套能直接复制的提示词与核对清单》已存草稿未发表，卡在封面：缺陷 A＝AI 配图条款弹窗点「同意」无响应（多次点击/等待/取消重进不消失，绕行素材库）；缺陷 B＝agent 无自产封面能力（Joey 令「你是 GPT 你自己生产一张弄上去」，agent 如实答无工具，定力与诚实合格）。02:15 续测补口径：agent 提议的素材封面主题（「日常习惯与个人成长」）与文章主题对不上——封面主题须从文章来（见 §3）。

## 1. 缺陷 A：点击策略升级（WebController.swift）

- `probeClickContext`：点击前探针（guard 一致性/安全词校验与旧口径一致），JS 侧 `dialogOf` 沿祖先链判定对话框样容器：dialog[open]／role=dialog|alertdialog／aria-modal=true／固定或绝对定位且类名/id 含 dialog|modal|popup|pop-|layer|mask|overlay|alert|confirm 关键词。**刻意不设「覆盖视口面积」规则**（全屏 SPA 根容器会造成全站误判）；漏检由存续探针兜底，误判方向取保守。
- `performClick` 分流：目标在弹窗内→直接升级；普通目标先走旧 runClickScript，点后睡 500ms 过 `dialogPersists` 存续探针（节点仍在弹窗内，或任一可见弹窗容器内有同文案可见按钮），仍在→升级；禁用/缺失的 12×300ms 重扫循环与最终报错口径与旧版平价。
- `performModalClick`／`performPointerSequence`／`runPointerStep`：完整序列 scroll→pointerover→pointerdown→mousedown→focus→pointerup→mouseup→click（scroll 后 150ms、步间 70ms）；每步独立 evaluate、每步重定位节点并重跑 SafetyPolicy 安全词检查；坐标取当下包围盒中心；PointerEvent 构造失败回退 MouseEvent；click 步用 e.click()。序列后睡 600ms 过存续探针，连败 2 次先留失败快照再抛 `MikaError("弹窗点按无响应：…isTrusted=false…")`。
- 转人工（AgentEngine）：`modalInterventionText(for:)` 以错误前缀 `WebController.modalUnresponsivePrefix` 为唯一判定——runTargeted 自主路径命中即转.manual 等待（return.waiting）；runConfirmed 确认路径命中转等待并 persistSnapshot（return.halted，**不恢复 pending**，避免再确认再连败）。介入文案明示：请用户亲手点弹窗按钮、点完点「继续」、在此之前不要声称已取得同意。
- 诚实边界：合成事件 isTrusted=false 无法伪造，系统提示新增「弹窗点按」段（照常 click、引擎自动升级；转等待后不要原样反复 click、不要绕开弹窗、不要声称已同意）。
- 已知取舍：弹窗内同一按钮的合法多次点按（如向导内计数按钮）会被存续探针误判为无响应、多点一次后转人工——按派工口径执行，属窄边缘，如实记录。

## 2. 缺陷 B：generate_cover 本机渲染自产封面（CoverGenerator.swift，新文件）

- 新动作 `generate_cover`（AgentAction 新增 subtitle/template 两字段，缺省空串向后兼容；两条模型通道白名单与系统提示动作串同步）：text=标题（必填）、subtitle 可选、template 三款——dark 深色科技／light 浅色简约／green 公众号绿系（`from(_:)` 认英文与中文别名，默认 dark）。
- 渲染：UIGraphicsImageRenderer（scale 1、opaque）产出 **900×383 PNG**；渐变底＋低透明装饰圆＋圆角强调条＋标题（60pt 起逐级 −2 自适应，≤3 行且不超文案区高）＋副标题（28pt ≤2 行），整块垂直居中；空标题返回 nil 不产出。无外部图像 API、无新依赖（仅 UIKit/Foundation）。
- 登记：`AttachmentStore.registerData`（displayName「封面-<标题前18字>.png」、origin=.taskGenerated、isScreenshot=false）落当前会话 attachments/，附件中心按来源徽标可见；引擎回报附件编号，模型随后以既有 upload_file 引用编号设封面——任务生成来源正好走 F1 已落地的 SP-01 豁免（SafetyPolicy.uploadDecision，本单零改动）。
- 系统提示新增「自产封面」段：需要封面先自产、产物只是备进附件、设没设上以页面回读为准、不合适先调标题/版式重生成。

## 3. 内置 playbook：wechat-oa-editor（SkillStore.swift，哈希迁移自动同步未改过的设备）

- AI 配图条款弹窗处理顺序：照常 click（引擎自动升级）→转等待则停下请用户亲手点（不得原样反复 click、不得绕开、不得声称已同意）→用户点完先回读现状。
- 封面专节（02:15 补口径已并入）：**封面主题与文案必须从文章标题与正文主题推导**（generate_cover 的 text 就用文章标题、副标题从正文主题提炼），不得按素材库文件名猜主题、不得拿主题对不上的图凑数（现场反例《用豆包整理会议纪要》 vs「日常习惯与个人成长」素材图明文写入 playbook）；顺序＝自产优先（标题即文案）→调标题/版式重生成→最后才选素材且按文章主题逐张核对；设完回读封面区核对。
- 草稿与发表判据：存草稿后重开/回读核对正文与封面；框架编辑器以自报字数/保存状态为准；发表按系统安全规则等用户确认。边界：登录/扫码/验证码/发表确认从安全规则，playbook 不覆盖。

## 4. 自检十一（SelfTestView＋引擎/Web/封面三处 verify，Tier A 程序化）

- 封面部分（CoverGenerator.verifyCoverGeneration）：三款渲染均 900×383、首款非空白像素抽样（约 2000 点、不同 RGB>24 种）、空标题被拒、scratch 会话生成登记（落盘 attachments/、origin=taskGenerated、readState=imageScaled、SP-01 判定=.allow、promptBlock 含文件名与「本任务生成」）；scratch 结束切回原会话并删除（已知残留：AttachmentStore 私有 cache 中该 scratch 的内存条目无法从外部清除，UUID 不复用、无害）。
- 弹窗部分（WebController.verifyModalClickEscalation＋新合成页 Resources/test-modal.html）：严格弹窗（role=dialog）按钮只在收到 pointerdown+mousedown+pointerup 完整序列后的 click 才关闭——①裸 e.click() 关不掉（基线）；②引擎 execute(click) 经升级关闭且页面确认标记在场；③顽固弹窗按钮（文案「同意（无响应）」）对任何事件不响应，execute 连败 2 次抛前缀错误。外加引擎侧转介入判定双向核对（前缀样本命中、普通错误不误触发）。点前重取状态防序号漂移。
- 合成页资源注册：project.pbxproj 新增 CoverGenerator.swift（5D/5E）与 Resources/test-modal.html（5F/60）；scripts/validate_project.py 期望集同步（8 个 HTML 资源），本机运行全 PASS（30 源、8 资源）。

## 5. 红线自查（git diff 对基线 7b711af 实查）

- MikaWebApp.swift 单持有者形态：diff **0 行**。SafetyPolicy.swift：diff **0 行**（SP-01 豁免判定为 F1 既有，本单只复用不改）。
- 无新依赖（仅系统框架）；变更文件 9 个＋案卷；「并行执行」文案本单 diff 新增 0 处（全仓唯一命中是 M1 既有注释、明文「不承诺并行执行」）；凭据不落盘（本单不涉凭据）。
- 未合 main、未动其他分支。

## 6. CI／Release 证据链（含一次假绿实锤）

- CI 第一条 41496290231 结论 success，**日志双核对发现实为 BUILD FAILED**（CoverGenerator.swift 运算符紧贴写法 9 处编译错误，被 ci.yml 的 tee 吞退出码假绿掩盖）——已按纪律不采信 run 结论、以日志原文为准，修复提交 9716bf0 后重跑。
- CI 第二条 41498164623 success，日志双核对：68 条 SwiftCompile、CoverGenerator 在编译列、BUILD SUCCEEDED ×1、BUILD FAILED ×0（唯一 error: 为 AppIntents 训练处理器无关警告，历次成功构建同在）。
- Release 第一条 41498755381：02:15 playbook 补口径到达时主动取消（基于旧提交、不含补充；运行 3m46s 于构建中被取消、未上传），避免多出一个不完整构建。
- CI 第三条 41499222746（tip 02ac979）success，日志双核对同上（68 条 SwiftCompile、SUCCEEDED、FAILED 0）。
- Release 第二条 **41500380805** success：fastlane 日志 Archive Succeeded、agvtool 置号 **202611021830**、「Successfully uploaded the new binary to App Store Connect」；dSYM artifact **dsym-41500380805** 经 gh api 实查在位、**4,423,268 字节**、未过期。
- validate_project.py 全 PASS（30 Swift 源、8 HTML 资源）。
- **ASC VALID 与 Internal 组挂载：待阿仁亲验，本案卷不代记。**

## 7. 未证项

- 自检十一 Tier A 未在真机预跑（本机无 Swift 工具链，靠 CI 编译背书）；Tier B 全部未跑（见复测清单）。
- JS 层冒烟未做：本机有 node 无 jsdom，弹窗序列逻辑未在仓外复验（合成页验证随自检十一在真机执行）。
- 微信公众号真实编辑器的弹窗结构（类名/role 形态）未经真机回读确认：探针按通用形态设计，真实页若用无关键词的自定义浮层，靠存续探针兜底升级，但「点击后弹窗仍在」的判定依赖同文案按钮在场，极端改版可能漏检（漏检退回旧行为，不误伤）。
- 02:15 补口径的 playbook 哈希迁移到达性：未被用户改过的设备自动同步；若 Joey 设备上已有手改版 wechat-oa-editor（本 playbook 为新增、此前不存在，无手改版可能），此项实际无风险，仍列明。

## 8. Joey 复测清单（Tier B 真机，目标构建 202611021830）

1. 公众号编辑器复刻 1655 现场：打开《用豆包整理会议纪要》草稿，让 agent 走 AI 配图——条款弹窗出现时 agent 照常点「同意」，弹窗应经升级点按关闭（或转对话内介入卡请你亲手点）；随后让 agent 设封面：应先 generate_cover 以文章标题自产（主题对版、不得提议主题不符的素材图），再 upload_file 设上；存草稿后回读核对正文与封面都在。
2. 自检十一 Tier A：设置页打开本地自检点「自检十一」——封面渲染/登记/SP-01 豁免、弹窗升级点按、连败转介入判定应逐条 ✓（执行时会占用当前标签页打开合成页 test-modal）。
3. 顽固弹窗全链：在自检十一合成页之外，若真实页面遇升级两次仍不关的弹窗，应出现对话内介入提示（请你亲手点按），agent 不得原样反复点击、不得声称已同意；你点完点「继续」后任务按页面现状续跑。
4. 封面主题口径：换一篇不同主题的文章（如个人成长类）让 agent 设封面——自产封面文案应随新文章标题变化；若它转而选素材库图，须按文章主题核对并说明理由。
5. 回归抽查：自检十（附件闭环）与普通网页 click/type 任务各跑一次，确认点击路径分流未伤旧行为（普通按钮一次点中、不额外等待）。
