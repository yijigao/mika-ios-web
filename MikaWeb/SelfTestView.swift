import SwiftUI
import Combine
struct SelfTestView: View {
    @ObservedObject var engine: AgentEngine
    @ObservedObject var settings: SettingsStore
    @ObservedObject var conversation: AgentConversationStore
    @Environment(\.dismiss) private var dismiss
    @State private var resumeTestRunning = false
    @State private var outcomeTestRunning = false
    @State private var multiSessionTestRunning = false
    @State private var coverModalTestRunning = false
    @State private var verifyContractTestRunning = false
    @State private var frameProbeTestRunning = false
    @State private var stepBudgetTestRunning = false
    @State private var editorNavTestRunning = false
    @State private var legibilityTestRunning = false
    @State private var autonomyTestRunning = false
    @State private var zOrderTestRunning = false
    @State private var trustedClickTestRunning = false
    @State private var ladderFixTestRunning = false
    @State private var coverUploadFixTestRunning = false
    @State private var taskFinishTestRunning = false
    @State private var editorEntryBindTestRunning = false
    @State private var finalClaimAuditTestRunning = false
    @State private var clickEffectTestRunning = false
    @State private var writtenContentTestRunning = false
    @State private var extractionBudgetTestRunning = false
    @State private var floatingVisibilityTestRunning = false
    @State private var sessionUXTestRunning = false
    @State private var recoveryBudgetTestRunning = false
    @State private var thermalGateTestRunning = false
    @State private var readbackRegistryTestRunning = false
    @State private var typeVerifyTestRunning = false
    @State private var drawerDismissTestRunning = false
    @State private var browserChromeTestRunning = false
    var body: some View {
        List {
            Text("加载本地页面，仍使用真实模型调用；任务在 App 前台内执行。")
            if !settings.hasKey { Text("未配置 API Key：请先到设置页选服务商、粘贴 Key，并点「保存并测试连接」。").foregroundStyle(.orange) }
            Button("自检一：查找资讯日期") {
                guard settings.hasKey else { return }
                engine.start(local: "test-news", task: "找出 AI 公开课的开课日期并汇报")
                dismiss()
            }.disabled(!settings.hasKey || !engine.active)
            Button("自检二：填写并提交表单") {
                guard settings.hasKey else { return }
                engine.start(local: "test-form", task: "在表单中填写姓名张三、邮箱 zhangsan@example.com 并提交，然后汇报结果文本")
                dismiss()
            }.disabled(!settings.hasKey || !engine.active)
            Button("自检三：循环熔断验证") {
                guard settings.hasKey else { return }
                engine.start(local: "test-form", task: "只点击表单的『提交』按钮，不要填写任何内容。每次点击后检查是否提交成功；没有成功就再点击一次同一个『提交』按钮，直到提交成功为止，不要改做别的事。")
                dismiss()
            }.disabled(!settings.hasKey || !engine.active)
            Text("自检三预期：表单为空点提交不会成功，模型按指令反复点同一个按钮——步流中应先后出现「循环提醒」「循环严重提醒」，最终任务因循环熔断停驻（已暂停，可点继续）。").font(.caption).foregroundStyle(.secondary)
            Button("自检四：中断恢复") {
                guard settings.hasKey, !resumeTestRunning else { return }
                resumeTestRunning = true
                runResumeTest()
                dismiss()
            }.disabled(!settings.hasKey || !engine.active || resumeTestRunning)
            Text("自检四预期：本地表单任务跑出至少 2 步后，模拟进程级中断（引擎内存态全丢、标签页打回起始页），仅凭落盘快照恢复出原目标与步骤；随后你点「继续」（或在输入框打「继续」），agent 应先回到表单页、带着原目标把剩下的填写／提交做完并汇报结果，全程不得反问网址或进度。中断与恢复报告、最终结论都会以「自检四」条目写进对话。").font(.caption).foregroundStyle(.secondary)
            Button("自检五：非语义入口与站点模式") {
                guard settings.hasKey || settings.chatGPTAuth.isLoggedIn else { return }
                engine.start(local: "test-entries", task: "这是本地活动页。先汇报页面标注的当前浏览模式；然后把页面切换到手机版格式，再汇报切换后的浏览模式；再点击『发微头条』入口，汇报页面出现的结果文字。")
                dismiss()
            }.disabled(!(settings.hasKey || settings.chatGPTAuth.isLoggedIn) || !engine.active)
            Text("自检五预期（RESOURCEFULNESS）：活动页的『发微头条』是 div＋JS 绑定的非语义入口——旧抽取看不见它；新版应能在元素清单里以 type=clickable 找到并点击，页面出现『已打开：发微头条编辑页』。切换站点模式走 set_site_mode：切换后页面重载、标注的浏览模式应由『电脑版（desktop）』变『手机版（mobile）』。页面上的长文本指针卡片、不可点说明文字、8px 小元素不应进清单（防噪声门槛）。").font(.caption).foregroundStyle(.secondary)
            Button("自检六：成果定力与重复提交软门") {
                guard settings.hasKey || settings.chatGPTAuth.isLoggedIn, !outcomeTestRunning else { return }
                outcomeTestRunning = true
                runOutcomeTest()
                dismiss()
            }.disabled(!(settings.hasKey || settings.chatGPTAuth.isLoggedIn) || !engine.active || outcomeTestRunning)
            Text("自检六预期（OUTCOME-LEDGER）：两阶段自动编排，全程看对话条目。第一阶段在本地发稿页发布固定稿件并核对列表状态（页面模拟真实平台：发布后编辑器保留原文、列表里状态为审核中），完成后成果台账应有记录。第二阶段不重载页面、直接让它把编辑器里现有的同一篇稿件再发布一次：它应依据台账注入拒绝重复提交、或在点击时被引擎软门拦下（步流出现『重复提交提醒』），转去核查列表并复述『已提交、审核中』，不得把同一内容当首次发布再交一遍、不得改口『无法确认』。页面已发布列表最终仍应只有 1 条。").font(.caption).foregroundStyle(.secondary)
            Button("自检七：计数器驱动编辑器输入") {
                guard settings.hasKey || settings.chatGPTAuth.isLoggedIn else { return }
                engine.start(local: "test-editor", task: "在正文编辑器中输入两段短文『自检七稿件：编辑器状态校验。第一段文字，用来验证字数随输入增长。』和『第二段文字，保存落定后才可以更新。』（两段之间分段），然后汇报页面显示的字数与保存状态；最后点击『更新』按钮，汇报更新结果文本。")
                dismiss()
            }.disabled(!(settings.hasKey || settings.chatGPTAuth.isLoggedIn) || !engine.active)
            Text("自检七预期（ZHIHU-COLUMN-SYNC）：本页是计数器驱动的模拟框架编辑器——只有合规输入事件能让字数增长、保存落定，直接改 DOM 的文字会被重渲染冲掉、字数不动。新版 type 应能把两段文字真正写进编辑器内部状态：字数涨到与全文量级一致（约 49 字）、保存状态由『草稿保存中』落定为『草稿已保存』，点『更新』回报『更新成功』。若步流里出现先失败再换策略重试，属预期的自动升级；最终字数仍为 0 或更新失败则不通过。").font(.caption).foregroundStyle(.secondary)
            Button("自检八：历史分库与上下文地基") {
                runHistoryContextTest()
                dismiss()
            }.disabled(!engine.active)
            Text("自检八预期（H1）：不调用模型、不动现役任务。①会话分库：临时建两个会话各写入 1500 条（超旧全局上限 1000），回读应各 1500 条、互不挤占，当前会话落盘条数不变，临时会话随后连目录删除干净；首次运行新版还应有一条旧对话迁移说明。②确定性折叠：45 步合成历史随折叠级别递减、最紧级别体量有界、首步成单行流水账、最近一步保留全量、旧步长文本被截断出局。③状态卡：pinnedFacts 原文在注入段逐字在场，且不靠历史携带（折叠文本里没有它）。④快照往返：带状态卡的快照编解码后卡片不丢。结论逐条写进对话。").font(.caption).foregroundStyle(.secondary)
            Button("自检九：多会话外壳") {
                guard !multiSessionTestRunning else { return }
                multiSessionTestRunning = true
                runMultiSessionTest()
                dismiss()
            }.disabled(!engine.active || multiSessionTestRunning)
            Text("自检九预期（M1）：两层。Tier A 不调用模型：临时建 3 个会话各开标签——置顶排最前、置顶标签关不掉、切到别的会话时标签对象／地址／导航计数全不变（未销毁未重载）、切回置顶保留；队列入队后内存与落盘都在位、取消后消失；旧代次的迟到回复被 checkpoint 拒。Tier B 用真实模型：会话甲跑本地表单任务时切到乙入队乙的任务，切回甲等它完成，队列应自动推进、在乙里把乙的任务跑完，两个会话的对话文件互不串（甲只有张三、乙只有李四）。要求引擎空闲；scratch 会话结束时删除干净。").font(.caption).foregroundStyle(.secondary)
            Button("自检十：附件闭环与上传确认门") {
                runAttachmentsTest()
                dismiss()
            }.disabled(!engine.active)
            Text("自检十预期（F1）：两层。Tier A 不调用模型（本按钮）：临时会话里导入文本／图片／未知格式样本——文本抽取到摘录、图片生成缩放副本且尺寸受限、未知格式只存不假报已读；同名再导入不覆盖（两个稳定 ID 并存、第一份逐字节未变）；截图进 browser/；落盘索引回读与内存逐 ID 一致；注入段三态口径在场；SP-01 判定（本任务生成＝放行、其余＝须确认）与一次性确认绑定四连（错附件消费失败、正消费成功、同凭据二次消费失败、作废后消费失败）逐项核对，结论写进对话、临时会话删净。Tier B 真机人工（步骤见案卷 F1-IMPL 的复测清单）：先把一个文本文件导入附件中心，再开本地自检的上传页（浏览器打开 test-upload），发任务让它把该附件上传到页面——应先出 SP-01 确认卡（文件名与页面在卡上）、确认后进选文件卡、在系统选择器选定该文件、回读核验步显示页面已持有文件名；中途取消一次应能继续任务。").font(.caption).foregroundStyle(.secondary)
            Button("自检十一：封面自产与弹窗点按升级") {
                guard !coverModalTestRunning else { return }
                coverModalTestRunning = true
                runCoverModalTest()
                dismiss()
            }.disabled(!engine.active || coverModalTestRunning)
            Text("自检十一预期（COVER-CONSENT）：两层。Tier A 不调用模型（本按钮，要求引擎空闲，弹窗核查会占用当前标签页打开本地合成页 test-modal）：①封面自产——三款版式渲染均为 900×383、像素非空白（多色）、空标题被拒；scratch 会话里生成并登记：落盘 attachments/、来源＝本任务生成、注入段带文件名与「本任务生成」字样、SP-01 判定对该附件放行，scratch 删净。②弹窗点按——合成页上方弹窗只认完整点按序列：裸 click 关不掉、引擎 click 经升级序列关掉并显示确认结果；下方无响应弹窗经升级连败 2 次后抛「弹窗点按无响应」，且转介入判定命中该错误、普通错误不误触发。结论逐条写进对话。Tier B 真机人工（步骤见案卷 COVER-CONSENT-IMPL 的复测清单）：公众号编辑器复刻 1655 现场——AI 配图条款弹窗点同意、generate_cover 自产封面并 upload_file 设上、存草稿后回读核对；顽固弹窗全链转对话内介入卡由用户亲手点按。").font(.caption).foregroundStyle(.secondary)
            Button("自检十二：真 Draft.js 编辑器粘贴写入") {
                guard settings.hasKey || settings.chatGPTAuth.isLoggedIn else { return }
                engine.start(local: "test-draft", task: "在正文编辑器中输入两段短文『自检十二稿件：粘贴路线验证。第一段文字，用来验证字数随输入进入编辑器状态。』和『第二段文字，保存落定后才可以更新。』（两段之间分段），然后汇报页面显示的字数与保存状态；最后点击『更新』按钮，汇报更新结果文本。")
                dismiss()
            }.disabled(!(settings.hasKey || settings.chatGPTAuth.isLoggedIn) || !engine.active)
            Text("自检十二预期（ZHUANLAN-FIX2）：本页内嵌真正的 Draft.js（0.11.7），初始正文 102 字（模拟知乎专栏待改的已发布文章），字数与保存状态全由 EditorState 驱动。type 应走粘贴事务整段替换：字数由 102 变为与目标全文一致的 54（不是 102＋54 的追加）、保存状态落定为『草稿已保存』，点『更新』回报『更新成功：正文共 54 字』。若字数仍为 102（冻结）或变成 156（只追加没替换）则不通过；步流里出现换策略重试属预期自动升级，最终以字数与更新结果为准。").font(.caption).foregroundStyle(.secondary)
            Button("自检十三：动作后核验合约") {
                guard !verifyContractTestRunning else { return }
                verifyContractTestRunning = true
                runVerifyContractTest()
                dismiss()
            }.disabled(!engine.active || verifyContractTestRunning)
            Text("自检十三预期（VERIFY-1）：两层。Tier A 不调用模型（本按钮，要求引擎空闲，会占用当前标签页打开本地合成页 test-verify）：四场景真实驱动「点击→settle 采样→独立判定」——甲发布后条目进列表应凭回读证据判 verified；乙只有短暂提示（toast）应判 unknown（toast 只记弱证据）；丙被页面明确拒绝应判 contradicted 且记录与自报分歧（diverged）；丁页面持续变化、settle 有界超时应记「证据未稳」判 unknown（超时不算成功）。四条记录写临时日志做落盘往返与分歧统计核对后删净，不污染正式 shadow 账。Tier B 真机人工（步骤见案卷 VERIFY-1-IMPL 的复测清单）：知乎专栏改长文原场景与公众号存草稿场景各跑一遍，看步流出现「动作后核验（影子记录）」步、正式日志新增对应记录、判定与页面实况一致。").font(.caption).foregroundStyle(.secondary)
            Button("自检十四：弹窗 frame 探针与框内关闭") {
                guard !frameProbeTestRunning else { return }
                frameProbeTestRunning = true
                runFrameProbeTest()
                dismiss()
            }.disabled(!engine.active || frameProbeTestRunning)
            Text("自检十四预期（WECHAT-COVER-FIX Part A）：两层。Tier A 不调用模型（本按钮，要求引擎空闲，会占用当前标签页打开本地合成页 test-frames）：合成页两个 iframe 各放一个同型弹窗——甲为同源 srcdoc frame（顶层可直读 DOM，按钮只认完整点按序列），乙为沙箱 srcdoc frame（不透明源、顶层读不到 DOM，按钮对点按不响应、只认 Escape）。预期：主 frame 可达性事实与预期一致；frame 普查枚举到至少 3 个 frame 且甲乙弹窗与按钮特征齐全；框内点按以 pointer 序列关闭甲、以 Escape 阶段关闭乙，两者的消失都要经复查普查与页面状态双证；终局普查无弹窗。若探针未注入沙箱 frame，乙会如实失败——不放水。Tier B 真机人工（步骤见案卷 WECHAT-COVER-FIX-IMPL 的复测清单）：公众号编辑器原场景复测——封面只走本地上传、双回读确认；误入条款弹窗时先关再继续、关不掉转人工。").font(.caption).foregroundStyle(.secondary)
            Button("自检十五：步数账与检查点恢复") {
                guard !stepBudgetTestRunning else { return }
                stepBudgetTestRunning = true
                runStepBudgetTest()
                dismiss()
            }.disabled(!engine.active || stepBudgetTestRunning)
            Text("自检十五预期（WECHAT-COVER-FIX Part C）：纯程序化模拟，不调用模型、不占用标签页：①步数预算只随模型决策 consume 增长，段限（每段上限）到后 canDecide 转假；②引擎注记/内部子步类事件不计数（计数点唯一）；③段限暂停后开新段可续跑、累计不清零（不重跑已完成部分的账面保证）；④全任务硬顶（段数上限 4×每段上限）封顶后开段被拒；⑤同指纹失败被循环熔断 3/5/7 分级封顶（指纹不含说辞，换说法不重置）；⑥快照预算四字段编解码往返不变、旧格式快照解码走迁移口径。Tier B 真机人工：长任务跑到段限暂停，点「继续」应开新段续跑同一任务（台账/页面/历史都在），反复继续到硬顶后应停在硬顶文案。").font(.caption).foregroundStyle(.secondary)
            Button("自检十六：入口感知补盲") {
                guard !editorNavTestRunning else { return }
                editorNavTestRunning = true
                runEditorNavTest()
                dismiss()
            }.disabled(!engine.active || editorNavTestRunning)
            Text("自检十六预期（WECHAT-EDITOR-NAV）：两层。Tier A 不调用模型（本按钮，要求引擎空闲，会占用当前标签页打开本地合成页 test-nav）：合成页复刻三类盲区——只有 aria-label 的 icon 按钮、只有 alt 的图标图、只有背景图的无文本封面入口、只有内联事件属性的无名入口（旧抽取整类滤掉），以及藏在内层滚动容器下方＋整页折下的编辑入口。预期：四类无文本入口都进元素清单且名源标注正确（aria-label／alt／bg／none）；编辑入口初始 inView=false、经揭示复判（逐个滚动内层容器＋窗口跟随）后在视口且中心可命中；补盲入口与编辑入口经引擎 click 都真点得动；序号标记失效后重扫能经文本锚点回退点中整卡。Tier B 真机人工（步骤见案卷 WECHAT-EDITOR-NAV-IMPL 的复测清单）：公众号编辑器原场景复测——草稿编辑入口与封面设置入口按 playbook 写死顺序找，未保存前不重载。").font(.caption).foregroundStyle(.secondary)
            Button("自检十七：浮层可读性") {
                guard !legibilityTestRunning else { return }
                legibilityTestRunning = true
                runLegibilityTest()
                dismiss()
            }.disabled(!engine.active || legibilityTestRunning)
            Text("自检十七预期（UI-LEGIBILITY）：两层。Tier A 不调用模型（本按钮）：结构断言——介入层三卡共用背景规格 OverlayStyle 的基底为最厚材质 ultraThickMaterial（强模糊）、系统底色覆盖 ≥0.5、未模糊直透比例 ≤0.25；变暗遮罩不透明度 ≥0.40 且不拦截触摸（网页弹窗照常可亲手点）；卡片种类真值表（上传＞确认＞手输互斥）保证同一时刻至多一张卡、介入文字只绘制一层。Tier B 真机人工（步骤见案卷 UI-LEGIBILITY-IMPL 的复测清单）：公众号场再遇介入卡（手动处理／确认／上传任一）时读一遍——卡内文字应清晰可读、卡后整屏变暗、无背景文字透叠；点网页弹窗按钮与「打开浏览器」照常可用。").font(.caption).foregroundStyle(.secondary)
            Button("自检十八：自主完成分类门与绕行梯") {
                guard !autonomyTestRunning else { return }
                autonomyTestRunning = true
                runAutonomyTest()
                dismiss()
            }.disabled(!engine.active || autonomyTestRunning)
            Text("自检十八预期（AUTONOMY-FIX）：两层。Tier A 不调用模型（本按钮，要求引擎空闲，会占用当前标签页打开本地合成页 test-autonomy）：①分类门——「请用户亲手点弹窗」「请用户手动打开编辑页」两条现场原例与 askKind=manual 声明均判 capability（拒绝停车），声明 clarify 但文本是请用户操作网页同样判 capability（防绕门），任务歧义问答判 clarify（照旧等待、不收紧）；②安全类回归——SafetyPolicy 对「确认付款」判 .confirm、type 进 password 字段判 .manual、SP-01 非任务生成文件判 .confirm（停车依据只读引用、安全策略零改动）；③绕行梯状态机逐级推进、三级试完梯尽、梯账快照往返不变；④失败结案文案含卡点＋已试路径＋页面证据且无请用户代劳措辞；⑤直达提取三路（带 ID 编辑链接直用、无 ID 模板＋实证 ID 拼装、无候选返回 nil）与合成页链接农场 harvest 实测；⑥合成页条款弹窗（按钮无行为、点按不关）经弹窗导航绕行（非编辑页重载分支）消失，且全程引擎未进入等待确认/等待手输停车态。Tier B 真机人工（步骤见案卷 AUTONOMY-FIX-IMPL 的复测清单）：公众号编辑器弹窗场走保存→离开→直达返回往返不丢稿、草稿入口全败时直达 URL 打开编辑页、安全类（发表确认）仍停车。").font(.caption).foregroundStyle(.secondary)
            Button("自检十九：介入态浏览器置顶层级") {
                guard !zOrderTestRunning else { return }
                zOrderTestRunning = true
                runZOrderTest()
                dismiss()
            }.disabled(!engine.active || zOrderTestRunning)
            Text("自检十九预期（ZORDER-FIX）：两层。Tier A 不调用模型（本按钮）：结构断言——直接核对根层级表纯函数 InterventionZOrder（ContentView 实际使用的同一份数值）：常态下遮罩＞坞、卡＞遮罩、输入栏最上（与 UI-LEGIBILITY 定版一致，非介入态层级零回归）；介入态点「打开浏览器」进入置顶态后坞＞遮罩（变暗遮罩不覆盖浏览器窗口、网页可看可亲手点）、卡（小条）＞坞（「已处理，继续」等解决按钮在浏览器置顶时可达）、遮罩仍＞对话层、输入栏仍最上；置顶切换只交换坞与遮罩名次、卡与输入栏名次不变；小条形态与置顶态同进退（置顶即收条、复位即全卡）。Tier B 真机人工（步骤见案卷 ZORDER-FIX-IMPL 的复测清单）：公众号场遇介入→点「打开浏览器」→浏览器浮到顶层能亲手点网页弹窗→点小条「已处理，继续」→层级恢复、任务按 AUTONOMY 口径续跑；安全类停车（发表确认）在小条上点「已处理」后的回读口径不变。").font(.caption).foregroundStyle(.secondary)
            Button("自检二十：可信点按实验（E1 插桩对照＋E2 AX 探针）") {
                guard !trustedClickTestRunning else { return }
                trustedClickTestRunning = true
                runTrustedClickTest()
                dismiss()
            }.disabled(!engine.active || trustedClickTestRunning)
            Text("自检二十预期（TRUSTED-CLICK-EXP）：不调用模型（本按钮，要求引擎空闲，会占用当前标签页打开本地合成页 test-trusted）。E1——武装只读插桩后：普通按钮经引擎 click 计数应为 1（阴性对照）；触摸状态机复刻弹窗在现行 pointer 序列＋合成 TouchEvent 序列后应仍打开（现象复现），页面账与插桩账双证 touchend 的 changedTouches 恒为 0、全部事件 isTrusted=false，两账逐类型计数应一致（插桩工作正常）。E2——宿主枚举本页无障碍树、按 aria-label 命中探针按钮并调 accessibilityActivate()，页面收到 click 且 isTrusted=true、或控件动作确实生效（计数增长）记「通」并留字段证据；够不到元素或激活无事件记「不通」并写明卡点层。实验合成一份结构化 JSON 落盘，本页下方可导出最近一份。E1 的真机金标准（真实条款弹窗上真人点一次再重放 diff）不在本按钮内，步骤见案卷 TRUSTED-CLICK-EXP-IMPL。").font(.caption).foregroundStyle(.secondary)
            Button("自检二十一：绕行梯引擎驱动回路（LADDER-FIX）") {
                guard !ladderFixTestRunning else { return }
                ladderFixTestRunning = true
                runLadderFixTest()
                dismiss()
            }.disabled(!engine.active || ladderFixTestRunning)
            Text("自检二十一预期（LADDER-FIX）：不调用模型（本按钮，要求引擎空闲，会占用执行页打开本地合成页 test-ladder 与 test-ladder-zero）。纯逻辑——第 1 级逐项验收状态机（下达不记已试、真实 click 的多项实证口径、frameClose 判不适用后才完成）；harvest 扩展来源（data 属性裸 ID＋onclick 模板拼装、内嵌数据直用、跨页模板记忆、预览链接排除计数、零候选实况行）；梯尽结案文案强制含 harvest 实况节；词表外动作判定；预览/编辑链接的感知区分。回路（真实调用主循环同款生产函数在合成页上驱动）——场景A：单次能力类信号只下达第 1 级（不记 attempted），生产记账喂齐手段后，动作后推进钩子不等第二次信号即结级并驱动直达 URL 一级（test-ladder 的编辑 ID 只在 data 属性、模板只在 onclick 里）成功关卡点；场景B：卡点在开且梯未尽时 done 被梯门拦下、引擎驱动成功后才放行；场景C：零候选页推进第 2 级落空、第 3 级重载后弹窗仍在→梯尽抛失败结案且文案含 harvest 实况（含预览排除数）；场景D：澄清问题不吞卡点（步流明示保持在开）、词表外动作「teleport」经生产处理后记账留痕并计入卡点证据、引擎不置失败不清进度。测试前后引擎现场完整恢复。").font(.caption).foregroundStyle(.secondary)
            Button("自检二十二：封面上传修复（COVER-UPLOAD-FIX）") {
                guard !coverUploadFixTestRunning else { return }
                coverUploadFixTestRunning = true
                runCoverUploadFixTest()
                dismiss()
            }.disabled(!engine.active || coverUploadFixTestRunning)
            Text("自检二十二预期（COVER-UPLOAD-FIX）：不调用模型（本按钮，要求引擎空闲，会占用执行页打开本地合成页 test-upload）。纯逻辑——生成文件名规整（混合标题小写 slug、全角标点剔除且全 ASCII、纯中文标题回退时间戳名、slug 长度上限）；相册写入三态文案（成功才说已存入相册，未授权/失败如实说没存入并带原因与文件名）；附件展示排序（本任务生成置顶、其余新在前）；选文件指引文案（已存相册给「最近项目」路线，未存不给相册路线、只指附件中心置顶项，待供武装时加「点上传按钮自动带上」）；环境门（不支持文件面板回调时武装恒失败不留武装态）。回路（iOS 18.4+）——在 test-upload 上武装一份临时文件、合成触发文件控件：回调被拉起且页面回读持有该文件记回路成立；合成触发未拉起面板记「未触发」（属环境结论，真机生产路径为用户真点上传按钮时供文件，Tier B 复测为准）；系统低于 iOS 18.4 时回路记环境结论（只能手动选文件）。相册真实写入（权限弹窗与落盘）不在本按钮内，属 Tier B 真机人工。").font(.caption).foregroundStyle(.secondary)
            Button("自检二十三：结束任务解锁（SELFCHECK-UNBLOCK-FIX）") {
                guard !taskFinishTestRunning else { return }
                taskFinishTestRunning = true
                runTaskFinishTest()
                dismiss()
            }.disabled(!engine.active || taskFinishTestRunning)
            Text("自检二十三预期（SELFCHECK-UNBLOCK-FIX）：不调用模型、不占用标签页（本按钮，要求引擎空闲）。程序化合成一个已暂停任务（目标与等待输入在位、快照落盘、busy 为真——同 0625 真机「停止后仍被自检挡下」的现场）：断言未结束时引擎保持锁定；调引擎 finishTask（即「结束任务」按钮的动作）后——busy 转假、状态落终结态、会话快照文件已删（重启 App 不会再恢复）、等待输入与目标已清、resume() 调之不复活、执行页绑定解除且待供文件未武装；演练毕引擎现场完整还原。真机人工部分（暂停态出现「结束任务（不可续跑）」按钮、点后自检二十二能跑、结束后重启不恢复、暂停后点继续仍能续跑、跑动中点停止仍是暂停）见案卷 Tier B 清单。").font(.caption).foregroundStyle(.secondary)
            Button("自检二十四：标题配对与翻页（EDITOR-ENTRY-BIND）") {
                guard !editorEntryBindTestRunning else { return }
                editorEntryBindTestRunning = true
                runEditorEntryBindTest()
                dismiss()
            }.disabled(!engine.active || editorEntryBindTestRunning)
            Text("自检二十四预期（EDITOR-ENTRY-BIND）：不调用模型、不占用标签页、不要求引擎空闲（全部纯函数）。合成公众号列表页数据对象（六条目交错：两条同名不同 ID、一条标题以 unicode 转义写入、一条只有 ID 没有标题＋一段无标题噪声 ID）：断言配对只从同对象共现出（恰 5 组）、噪声与无标题条目不误配、同名歧义如实拒绝不猜、目标标题唯一命中时按配对拼编辑直达、别篇的带 ID 编辑链接不冒充目标（ID 与配对一致才直用）、卡片 DOM 同卡配对可直交、无目标时旧口径行为不变、列表翻页纯函数按 begin/count 递进且到上限停、无参数地址不误翻、目标标题提取口径正确。真实公众号列表页的配对命中属 Tier B 真机（见案卷清单）。").font(.caption).foregroundStyle(.secondary)
            Button("自检二十五：浏览器浮窗显隐（FLOATING-VISIBILITY）") {
                guard !floatingVisibilityTestRunning else { return }
                floatingVisibilityTestRunning = true
                runFloatingVisibilityTest()
                dismiss()
            }.disabled(!engine.active || floatingVisibilityTestRunning)
            Text("自检二十五预期：不调用模型。既有显隐状态机、介入覆盖、隐藏执行与视口不变；新增生产布局断言：按钮在键盘收起/升起两态相对输入栏左上角偏移恒定，输入栏隐藏或浏览器全屏时不可见，且不与文字输入区相交。").font(.caption).foregroundStyle(.secondary)
            Button("自检二十六：会话抽屉与滚动（SESSION-UX）") {
                guard !sessionUXTestRunning else { return }
                sessionUXTestRunning = true
                runSessionUXTest()
                dismiss()
            }.disabled(!engine.active || sessionUXTestRunning)
            Text("自检二十六预期（Tier A，不调用模型）：冷启动进入与切换会话都发出回底请求；用户上滑超过一屏后流式追加不强拉且出现回底按钮，点击恢复跟随；新对话首条用户消息生成标题并约定聚焦输入框；删除先二次确认、确认后即时更新列表。").font(.caption).foregroundStyle(.secondary)
            Button("自检二十七：结案自证门（FINAL-CLAIM-AUDIT）") {
                guard !finalClaimAuditTestRunning else { return }
                finalClaimAuditTestRunning = true
                runFinalClaimAuditTest()
                dismiss()
            }.disabled(!engine.active || finalClaimAuditTestRunning)
            Text("自检二十七预期（FINISH-GATE 刀1，不调用模型、不占用标签页）：完成断言真值表 19 条（纯断言命中、否定断言不命中、「已完成但未核实」仍算断言、只读汇总不命中）、运行起点筛选（旧任务待核查与已离开待核查的条目不入门）、旧「已核实（完成总结）」只在展示时降级不迁移。结案门的真实回读行为属 Tier B 真机。").font(.caption).foregroundStyle(.secondary)
            Button("自检二十八：点击效果分类（CLICK-EFFECT）") {
                guard !clickEffectTestRunning else { return }
                clickEffectTestRunning = true
                runClickEffectTest()
                dismiss()
            }.disabled(!engine.active || clickEffectTestRunning)
            Text("自检二十八预期（刀2，不调用模型、不占用标签页）：纯函数真值表覆盖 URL 变化、文本变化、元素数变化、都不变与点前签名缺失。真实点击回读的时序与页面效果需在真机复测。").font(.caption).foregroundStyle(.secondary)
            Button("自检二十九：页面写入入账（KNIFE3-WRITES）") {
                guard !writtenContentTestRunning else { return }
                writtenContentTestRunning = true
                runWrittenContentTest()
                dismiss()
            }.disabled(!engine.active || writtenContentTestRunning)
            Text("自检二十九预期（刀3，不调用模型、不占用标签页）：写入条目含目标、正文前24字与字数；无名目标回退；十次写入只留最近八条；状态卡随快照往返且旧快照缺 writes 键仍可解码；level 3 折叠时写入段及八条原文仍全文在 prompt 中。真实页面 type 成功路径需真机复测。").font(.caption).foregroundStyle(.secondary)
            Button("自检三十：抽取预算（EXTRACTION-BUDGET）") {
                guard !extractionBudgetTestRunning else { return }
                extractionBudgetTestRunning = true
                runExtractionBudgetTest()
                dismiss()
            }.disabled(!engine.active || extractionBudgetTestRunning)
            Text("自检三十预期：不调用模型、不占用标签页；核对预算常量、coverage 新旧 JSON 兼容和唯一候选真值表。JS 常量需人工核对同值。").font(.caption).foregroundStyle(.secondary)
            Button("自检三十一：目标复核（TARGET-REVALIDATION）") { runKnife3Test(31) }.disabled(!engine.active)
            Text("自检三十一预期：纯逻辑核对目标失效文案与 guard 缓存的 tab、epoch、index 键。").font(.caption).foregroundStyle(.secondary)
            Button("自检三十二：稳定决策（SETTLE-DECISION）") { runKnife3Test(32) }.disabled(!engine.active)
            Text("自检三十二预期：纯逻辑核对三帧连续、资源静默、失败帧、文档代次变化和最终取证预算。").font(.caption).foregroundStyle(.secondary)
            Button("自检三十三：恢复预算（RECOVERY-BUDGET）") {
                guard !recoveryBudgetTestRunning else { return }
                recoveryBudgetTestRunning = true
                runRecoveryBudgetTest()
                dismiss()
            }.disabled(!engine.active || recoveryBudgetTestRunning)
            Text("自检三十三预期：不调用模型、不占用标签页；验证整任务恢复尝试与加载上限、2/5/10 秒退避、两类计数独立、Codable 往返和默认值相等。真实页面恢复与进程终止需真机复测。").font(.caption).foregroundStyle(.secondary)
            Button("自检三十四：取消决策（CANCELLATION）") { runKnife3Test(34) }.disabled(!engine.active)
            Text("自检三十四预期：纯状态机核对取消优先于稳定与超时，置位后下一步必退出。").font(.caption).foregroundStyle(.secondary)
            Button("自检三十五：热态门（THERMAL-GATE）") {
                guard !thermalGateTestRunning else { return }
                thermalGateTestRunning = true
                runThermalGateTest()
                dismiss()
            }.disabled(!engine.active || thermalGateTestRunning)
            Text("自检三十五预期：不调用模型、不占用标签页；验证四态准入 12 格、30 秒冷却与再升温、从未锁过可恢复、状态相等。真机热态通知与亮屏行为需复测。").font(.caption).foregroundStyle(.secondary)
            Button("自检三十六：回读页登记（READBACK-TAB-REGISTRY）") {
                guard !readbackRegistryTestRunning else { return }
                readbackRegistryTestRunning = true
                runReadbackRegistryTest()
                dismiss()
            }.disabled(!engine.active || readbackRegistryTestRunning)
            Text("自检三十六预期：纯状态机核对同任务单回读页、跨任务隔离、popup 不回收、终局清理与单页注销；真实页面保护和绑定恢复需真机复测。").font(.caption).foregroundStyle(.secondary)
            Button("自检三十七：富文本 type 校验（TYPE-VERIFY）") {
                guard !typeVerifyTestRunning else { return }
                typeVerifyTestRunning = true
                runTypeVerifyTest()
                dismiss()
            }.disabled(!engine.active || typeVerifyTestRunning)
            Text("自检三十七预期：字数信号丢失、无信号宽容、冻结、目标量级、基线增长兜底、DOM 缺失及旧探针 JSON 解码兼容均通过；真实编辑器需真机复测。").font(.caption).foregroundStyle(.secondary)
            Button("自检三十八：抽屉关闭手势（DRAWER-DISMISS）") {
                guard !drawerDismissTestRunning else { return }
                drawerDismissTestRunning = true
                runDrawerDismissTest()
                dismiss()
            }.disabled(!engine.active || drawerDismissTestRunning)
            Text("自检三十八预期：遮罩左滑超过 60 点才关闭抽屉；边界、零位和右滑均不关闭。行左滑与遮罩命中范围需真机复测。").font(.caption).foregroundStyle(.secondary)
            Button("自检三十九：全屏切换与浏览器 chrome") {
                guard !browserChromeTestRunning else { return }
                browserChromeTestRunning = true
                runBrowserChromeTest()
                dismiss()
            }.disabled(!engine.active || browserChromeTestRunning)
            Text("自检三十九预期：临时 DockStateStore 的 fullScreen 发布 false→true→false；背景与 header 材质在小窗为 false、全屏为 true。实际界面仍需真机复测。").font(.caption).foregroundStyle(.secondary)
            if let tcLogURL = TCProbeLogStore.latestURL() {
                ShareLink(item: tcLogURL) { Text("导出最近一份可信点按实验日志（JSON）") }
            }
        }.navigationTitle("本地自检")
    }

    private func runExtractionBudgetTest() {
        defer { extractionBudgetTestRunning = false }
        conversation.localFeedback("自检三十：开始——抽取预算与覆盖兼容（不调用模型）")
        var lines: [String] = []
        func check(_ passed: Bool, _ note: String) {
            lines.append("\(passed ? "✓" : "✗") \(note)")
        }
        check(ExtractionBudget.maxVisited == 2000 && ExtractionBudget.maxCandidates == 256,
              "Swift 预算：访问 2000、候选 256（JS 常量人工核对）")
        let coverage = Coverage(visited: 123, truncated: true)
        let decodedCoverage = (try? JSONEncoder().encode(coverage)).flatMap { try? JSONDecoder().decode(Coverage.self, from: $0) }
        check(decodedCoverage == coverage, "Coverage Codable 往返")
        let oldJSON = #"{"url":"https://example.test","title":"旧快照","text":"","elements":[]}"#.data(using: .utf8)!
        let old = try? JSONDecoder().decode(PageState.self, from: oldJSON)
        check(old?.coverage == nil && old?.coverageComplete == true, "旧 JSON 缺 coverage 仍可解码，按完整覆盖")
        let truncated = PageState(url: "https://example.test", title: "", text: "", elements: [], coverage: coverage)
        check(!truncated.coverageComplete, "truncated=true 时 coverageComplete=false")
        for complete in [true, false] {
            for strong in [true, false] {
                let expected = complete || strong
                check(TargetResolutionPolicy.acceptsLoneCandidate(coverageComplete: complete, strongMatch: strong) == expected,
                      "唯一候选：complete=\(complete)、strong=\(strong) → \(expected)")
            }
        }
        for line in lines { conversation.localFeedback("自检三十：\(line)") }
        let failed = lines.filter { $0.hasPrefix("✗") }.count
        conversation.localFeedback(failed == 0 ? "自检三十结论：全部通过（\(lines.count) 项）" : "自检三十结论：\(failed)/\(lines.count) 项未通过，见逐条记录")
    }

    private func runKnife3Test(_ number: Int) {
        var lines: [String] = []
        func check(_ ok: Bool, _ note: String) { lines.append("\(ok ? "✓" : "✗") \(note)") }
        switch number {
        case 31:
            check(StaleTargetPolicy.isStaleTarget(errorDomain: "WKErrorDomain", code: 4, message: "目标元素已失效"), "code 4 且目标失效文案命中")
            check(!StaleTargetPolicy.isStaleTarget(errorDomain: "WKErrorDomain", code: 4, message: "普通脚本异常"), "普通 JS 异常不当 stale")
            check(!StaleTargetPolicy.isStaleTarget(errorDomain: "WKErrorDomain", code: 3, message: "目标元素已变化"), "code 非 4 不当 stale")
            check(!StaleTargetPolicy.isStaleTarget(errorDomain: "OtherDomain", code: 4, message: "目标元素已失效"), "其他域不当 stale")
            let id = UUID()
            let key = ClickGuardCacheKey(tabID: id, epoch: 2, index: 7)
            check(ClickGuardCacheKey.hits(key, tabID: id, epoch: 2, index: 7), "同 tab、epoch、index 缓存命中")
            check(!ClickGuardCacheKey.hits(key, tabID: id, epoch: 3, index: 7), "文档代次变则失效")
            check(!ClickGuardCacheKey.hits(key, tabID: id, epoch: 2, index: 8), "目标 index 变则失效")
            check(!ClickGuardCacheKey.hits(key, tabID: UUID(), epoch: 2, index: 7), "跨 tab 不命中")
        case 32:
            var state = SettleDecisionPolicy.State()
            check(SettleDecisionPolicy.step(&state, signature: "a", epoch: 1, networkQuiet: true, remaining: 3) == .continue, "首帧不稳定")
            check(SettleDecisionPolicy.step(&state, signature: "a", epoch: 1, networkQuiet: true, remaining: 3) == .continue, "两帧不稳定")
            check(SettleDecisionPolicy.step(&state, signature: "a", epoch: 1, networkQuiet: false, remaining: 3) == .continue, "三帧但资源未静默不稳定")
            check(SettleDecisionPolicy.step(&state, signature: "a", epoch: 1, networkQuiet: true, remaining: 3) == .settled, "连续三帧且静默才稳定")
            _ = SettleDecisionPolicy.step(&state, signature: nil, epoch: 1, networkQuiet: false, remaining: 3)
            check(SettleDecisionPolicy.step(&state, signature: "a", epoch: 1, networkQuiet: true, remaining: 3) == .continue, "失败帧重置连续性")
            _ = SettleDecisionPolicy.step(&state, signature: "a", epoch: 1, networkQuiet: true, remaining: 3)
            check(SettleDecisionPolicy.step(&state, signature: "a", epoch: 2, networkQuiet: true, remaining: 3) == .continue, "同 URL 重载但 epoch 变则重置")
            check(!SettleDecisionPolicy.shouldCaptureState(remaining: 1.49) && SettleDecisionPolicy.shouldCaptureState(remaining: 1.5), "不足 1.5 秒用样本收口")
            check(SettleDecisionPolicy.step(&state, signature: nil, epoch: 2, networkQuiet: true, remaining: 0) == .timedOut, "预算耗尽且证据不足不产 settled")
        case 34:
            check(SettleLoopPolicy.next(cancelled: false, settled: false, remaining: 1) == .continue, "正常继续")
            check(SettleLoopPolicy.next(cancelled: true, settled: false, remaining: 1) == .cancelled, "取消后下一步退出")
            check(SettleLoopPolicy.next(cancelled: true, settled: true, remaining: 0) == .cancelled, "取消优先于稳定和超时")
            check(SettleLoopPolicy.next(cancelled: false, settled: true, remaining: 1) == .settled, "稳定退出")
            check(SettleLoopPolicy.next(cancelled: false, settled: false, remaining: 0) == .timedOut, "超时退出")
        default: return
        }
        for line in lines { conversation.localFeedback("自检三\(number == 31 ? "十一" : number == 32 ? "十二" : "十四")：\(line)") }
        let failed = lines.filter { $0.hasPrefix("✗") }.count
        conversation.localFeedback("自检三\(number == 31 ? "十一" : number == 32 ? "十二" : "十四")结论：\(failed == 0 ? "全部通过" : "\(failed) 项未通过")（\(lines.count) 项）")
    }

    private func runRecoveryBudgetTest() {
        defer { recoveryBudgetTestRunning = false }
        conversation.localFeedback("自检三十三：开始——恢复预算状态机（不调用模型）")
        var lines: [String] = []
        func check(_ passed: Bool, _ note: String) {
            lines.append("\(passed ? "✓" : "✗") \(note)")
        }
        var budget = RecoveryBudget()
        check(budget.attemptsRemaining == 3 && budget.loadsRemaining == 2 && budget.nextBackoff() == 2,
              "初始预算：尝试剩余 3、加载剩余 2、下一次退避 2 秒")
        let backoffs = (0..<4).map { _ in budget.reserveAttempt() }
        check(backoffs[0] == 2 && backoffs[1] == 5 && backoffs[2] == 10 && backoffs[3] == nil && budget.attemptsUsed == 3 && budget.attemptsRemaining == 0,
              "尝试预留：依次 2/5/10 秒，第四次拒绝且已用 3")
        check(budget.reserveLoad() && budget.reserveLoad() && !budget.reserveLoad() && budget.loadsUsed == 2 && budget.loadsRemaining == 0,
              "加载预留：两次成功，第三次拒绝且已用 2")
        var independent = RecoveryBudget()
        let loadFirst = independent.reserveLoad()
        let attemptAfterLoad = independent.reserveAttempt()
        check(loadFirst && attemptAfterLoad == 2 && independent.loadsUsed == 1 && independent.attemptsUsed == 1,
              "计数独立：先预留加载再预留尝试，各计一次")
        var saved = RecoveryBudget()
        _ = saved.reserveAttempt(); _ = saved.reserveAttempt(); _ = saved.reserveLoad()
        let decoded = (try? JSONEncoder().encode(saved)).flatMap { try? JSONDecoder().decode(RecoveryBudget.self, from: $0) }
        check(decoded == saved && decoded?.attemptsUsed == 2 && decoded?.loadsUsed == 1 && decoded?.nextBackoff() == 10,
              "Codable 往返：已用 2 次尝试、1 次加载原样保留")
        check(RecoveryBudget() == RecoveryBudget(), "Equatable：两个默认新预算相等")
        for line in lines { conversation.localFeedback("自检三十三：\(line)") }
        let failed = lines.filter { $0.hasPrefix("✗") }.count
        conversation.localFeedback(failed == 0 ? "自检三十三结论：全部通过（\(lines.count) 项）" : "自检三十三结论：\(failed)/\(lines.count) 项未通过，见逐条记录")
    }

    private func runThermalGateTest() {
        defer { thermalGateTestRunning = false }
        conversation.localFeedback("自检三十五：开始——热态门纯策略（不调用模型）")
        var lines: [String] = []
        func check(_ passed: Bool, _ note: String) {
            lines.append("\(passed ? "✓" : "✗") \(note)")
        }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let expectations: [(ThermalLevel, Bool, Bool, Bool)] = [
            (.nominal, true, true, false),
            (.fair, true, false, false),
            (.serious, false, false, true),
            (.critical, false, false, true)
        ]
        for (level, heavy, nonEssential, locked) in expectations {
            var gate = ThermalGate()
            gate.update(level: level, now: base)
            check(gate.allowsHeavyWork() == heavy, "\(level) 允许重活 = \(heavy)")
            check(gate.allowsNonEssential() == nonEssential, "\(level) 允许非必要工作 = \(nonEssential)")
            check(gate.isLocked == locked, "\(level) 热锁 = \(locked)")
        }
        var cooling = ThermalGate()
        cooling.update(level: .serious, now: base)
        cooling.update(level: .fair, now: base.addingTimeInterval(10))
        check(cooling.coolingSince == base.addingTimeInterval(10), "锁定后降 fair：冷却从降温时刻起算")
        check(!cooling.canResume(now: base.addingTimeInterval(39)), "降温 29 秒仍不可恢复")
        check(cooling.canResume(now: base.addingTimeInterval(40)), "降温 30 秒可恢复")
        var reheated = ThermalGate()
        reheated.update(level: .serious, now: base)
        reheated.update(level: .fair, now: base.addingTimeInterval(10))
        reheated.update(level: .serious, now: base.addingTimeInterval(25))
        check(reheated.coolingSince == nil && !reheated.canResume(now: base.addingTimeInterval(100)), "冷却中再升 serious：计时清空且不可恢复")
        var neverLocked = ThermalGate()
        check(neverLocked.canResume(now: base), "从未锁过的 nominal 可恢复")
        neverLocked.update(level: .fair, now: base)
        check(neverLocked.canResume(now: base), "从未锁过的 fair 可恢复")
        var copy = neverLocked
        check(copy == neverLocked, "Equatable：状态拷贝相等")
        copy.update(level: .serious, now: base)
        check(copy != neverLocked, "Equatable：状态变化后不相等")
        for line in lines { conversation.localFeedback("自检三十五：\(line)") }
        let failed = lines.filter { $0.hasPrefix("✗") }.count
        conversation.localFeedback(failed == 0 ? "自检三十五结论：全部通过（\(lines.count) 项）" : "自检三十五结论：\(failed)/\(lines.count) 项未通过，见逐条记录")
    }

    private func runTypeVerifyTest() {
        defer { typeVerifyTestRunning = false }
        conversation.localFeedback("自检三十七：开始——type 判定真值表（不调用模型）")
        var lines: [String] = []
        func check(_ passed: Bool, _ note: String) { lines.append("\(passed ? "✓" : "✗") \(note)") }
        typealias Verdict = TypeVerifyPolicy.Verdict
        func verdict(_ baseline: Int?, _ post: Int?, _ textOK: Bool) -> Verdict {
            TypeVerifyPolicy.verdict(baselineCount: baseline, postCount: post,
                                     textOK: textOK, expectedCount: 1236)
        }
        check(verdict(0, nil, true) == .failSignalLost, "基线 0、写后无信号：failSignalLost")
        check(verdict(nil, nil, true) == .pass, "前后都无信号：pass")
        check(verdict(0, 0, true) == .failFrozen(0), "字数冻结在 0：failFrozen")
        check(verdict(0, 1236, true) == .pass, "目标 1236 字：pass")
        check(verdict(100, 1300, true) == .pass, "基线 100、写后 1300：pass")
        check(verdict(1000, 2236, true) == .pass, "基线 1000、写后 2236：增长兜底 pass")
        check(verdict(0, 1236, false) == .failDomMissing &&
              verdict(nil, nil, false) == .failDomMissing, "DOM 未命中优先 failDomMissing")
        let oldJSON = Data(#"{"found":true,"count":0,"saveState":null,"textLength":0}"#.utf8)
        let decoded = try? JSONDecoder().decode(WebController.EditorSignals.self, from: oldJSON)
        check(decoded?.found == true && decoded?.locatedByIndex == false,
              "旧探针 JSON 缺 locatedByIndex 时解为 false")
        for line in lines { conversation.localFeedback("自检三十七：\(line)") }
        let failed = lines.filter { $0.hasPrefix("✗") }.count
        conversation.localFeedback(failed == 0 ? "自检三十七结论：全部通过（\(lines.count) 项）" : "自检三十七结论：\(failed)/\(lines.count) 项未通过，见逐条记录")
    }

    private func runBrowserChromeTest() {
        defer { browserChromeTestRunning = false }
        conversation.localFeedback("自检三十九：开始——状态发布与样式真值表（不调用模型）")
        let testDock = DockStateStore()
        var published: [Bool] = []
        let subscription = testDock.$fullScreen.sink { published.append($0) }
        testDock.showFullScreen()
        testDock.leaveFullScreen()
        subscription.cancel()
        let checks: [(String, Bool)] = [
            ("临时坞发布 false→true→false", published == [false, true, false]),
            ("小窗背景与 header 均关闭", !BrowserChromeStyle.opaqueBackground(fullScreen: false) && !BrowserChromeStyle.headerMaterial(fullScreen: false)),
            ("全屏背景与 header 均开启", BrowserChromeStyle.opaqueBackground(fullScreen: true) && BrowserChromeStyle.headerMaterial(fullScreen: true))
        ]
        for (note, passed) in checks {
            conversation.localFeedback("自检三十九：\(passed ? "✓" : "✗") \(note)")
        }
        let failed = checks.filter { !$0.1 }.count
        conversation.localFeedback(failed == 0 ? "自检三十九结论：全部通过（3 项）" : "自检三十九结论：\(failed)/3 项未通过，见逐条记录")
    }

    private func runDrawerDismissTest() {
        defer { drawerDismissTestRunning = false }
        conversation.localFeedback("自检三十八：开始——抽屉关闭手势真值表（不调用模型）")
        let cases: [(CGFloat, Bool)] = [(-61, true), (-60, false), (0, false), (80, false), (-200, true)]
        var failed = 0
        for (translation, expected) in cases {
            let actual = DrawerDismissPolicy.shouldDismiss(translationWidth: translation)
            if actual != expected { failed += 1 }
            conversation.localFeedback("自检三十八：\(actual == expected ? "✓" : "✗") \(translation) → \(expected)")
        }
        conversation.localFeedback(failed == 0 ? "自检三十八结论：全部通过（5 项）" : "自检三十八结论：\(failed)/5 项未通过，见逐条记录")
    }

    private func runReadbackRegistryTest() {
        defer { readbackRegistryTestRunning = false }
        conversation.localFeedback("自检三十六：开始——回读页登记纯状态机（不调用模型）")
        var lines: [String] = []
        func check(_ passed: Bool, _ note: String) { lines.append("\(passed ? "✓" : "✗") \(note)") }
        let taskA = UUID(), taskB = UUID(), source = UUID()
        let first = UUID(), second = UUID(), popup = UUID(), other = UUID()
        var registry = ReadbackTabRegistry()
        check(registry.register(tabID: first, ownerTaskID: taskA, sourceTabID: source, purpose: "readback") == nil,
              "首个回读页无待回收页")
        check(registry.register(tabID: popup, ownerTaskID: taskA, sourceTabID: source, purpose: "popup") == nil &&
              registry.readbackTab(forTask: taskA) == first && registry.tabsToRecycle(forTask: taskA) == [first],
              "被动 popup 记账但不占回读名额，也不自动回收")
        check(registry.register(tabID: other, ownerTaskID: taskB, sourceTabID: source, purpose: "readback") == nil &&
              registry.readbackTab(forTask: taskA) == first && registry.tabsToRecycle(forTask: taskB) == [other],
              "任务 B 登记不影响任务 A")
        check(registry.register(tabID: second, ownerTaskID: taskA, sourceTabID: source, purpose: "readback") == first &&
              registry.readbackTab(forTask: taskA) == second && registry.tabsToRecycle(forTask: taskA) == [second],
              "同任务第二页返回旧 ID，登记仅保留新回读页")
        registry.unregister(tabID: popup)
        check(registry.entries[popup] == nil && registry.readbackTab(forTask: taskA) == second,
              "unregister 只清指定页")
        registry.endTask(taskA)
        check(registry.readbackTab(forTask: taskA) == nil && registry.tabsToRecycle(forTask: taskA).isEmpty &&
              registry.readbackTab(forTask: taskB) == other,
              "endTask 清任务 A，任务 B 不受影响")
        for line in lines { conversation.localFeedback("自检三十六：\(line)") }
        let failed = lines.filter { $0.hasPrefix("✗") }.count
        conversation.localFeedback(failed == 0 ? "自检三十六结论：全部通过（\(lines.count) 项）" : "自检三十六结论：\(failed)/\(lines.count) 项未通过，见逐条记录")
    }

    private func runSessionUXTest() {
        defer { sessionUXTestRunning = false }
        conversation.localFeedback("自检二十六：开始——会话抽屉与滚动 Tier A（不调用模型）")
        let lines = SessionUXTierA.verify()
        for line in lines { conversation.localFeedback("自检二十六：\(line)") }
        let failed = lines.filter { $0.hasPrefix("✗") }.count
        conversation.localFeedback(failed == 0 ? "自检二十六结论：全部通过——初始/切换回底、上滑不强跟与回底按钮、新对话标题聚焦、删除确认契约均成立" : "自检二十六结论：\(failed) 项未通过，见逐条记录")
    }

    private func runFloatingVisibilityTest() {
        let engine = self.engine
        let conversation = self.conversation
        conversation.localFeedback("自检二十五：开始——浏览器浮窗显隐 Tier A（不调用模型）")
        Task { @MainActor in
            defer { floatingVisibilityTestRunning = false }
            let lines = await engine.verifyFloatingVisibility()
            for line in lines { conversation.localFeedback("自检二十五：\(line)") }
            let failed = lines.filter { $0.hasPrefix("✗") }.count
            conversation.localFeedback(failed == 0 ? "自检二十五结论：全部通过——显隐状态机、输入栏夹挂几何、随栏隐藏、文字避让、隐藏执行与视口不变均有实证" : "自检二十五结论：\(failed) 项未通过，见逐条记录")
        }
    }

    /// 自检二十编排（TRUSTED-CLICK-EXP）：E1 插桩复刻页对照＋E2 AX
    /// 激活探针，委托引擎侧 verifyTrustedClick（WebController 在合成
    /// 页 test-trusted 真实驱动并落盘结构化日志），结论以「自检二十」
    /// 条目写进对话。不调用模型、不起任务；要求引擎空闲（会占用
    /// 当前标签页打开合成页）。E1 真机金标准与 E3 不在本按钮内。
    private func runTrustedClickTest() {
        let engine = self.engine
        let conversation = self.conversation
        conversation.localFeedback("自检二十：开始——可信点按实验 E1 插桩对照＋E2 AX 探针（不调用模型）")
        Task { @MainActor in
            defer { trustedClickTestRunning = false }
            let lines = await engine.verifyTrustedClick()
            for line in lines { conversation.localFeedback("自检二十：\(line)") }
            let failed = lines.filter { $0.hasPrefix("✗") }.count
            conversation.localFeedback(failed == 0 ? "自检二十结论：全部通过——插桩自证与 touches 恒空复现成立、E2 探针判定见上（通／不通均以字段证据为准）；E1 真机金标准按案卷步骤另行采集" : "自检二十结论：\(failed) 项未通过，见上方逐条记录（E2 判「不通」属实验结论、同样计未通过以便醒目）")
        }
    }

    /// 自检二十一编排（LADDER-FIX）：绕行梯引擎驱动的回路级核查，
    /// 委托引擎侧 verifyLadderFix（纯逻辑断言＋在合成页 test-ladder／
    /// test-ladder-zero 上真实调用主循环同款生产函数驱动完整回路），
    /// 结论以「自检二十一」条目写进对话。不调用模型、不起任务；要求
    /// 引擎空闲（会占用执行页打开合成页，结束恢复引擎现场）。
    private func runLadderFixTest() {
        let engine = self.engine
        let conversation = self.conversation
        conversation.localFeedback("自检二十一：开始——绕行梯引擎驱动回路核查（不调用模型）")
        Task { @MainActor in
            defer { ladderFixTestRunning = false }
            let lines = await engine.verifyLadderFix()
            for line in lines { conversation.localFeedback("自检二十一：\(line)") }
            let failed = lines.filter { $0.hasPrefix("✗") }.count
            conversation.localFeedback(failed == 0 ? "自检二十一结论：全部通过——第 1 级逐项验收、引擎自动推进、done 梯门、harvest 扩展来源与梯尽实况、词表外动作去终结化、澄清不吞卡点均有回路级实证" : "自检二十一结论：\(failed) 项未通过，见上方逐条记录")
        }
    }

    /// 自检二十二编排（COVER-UPLOAD-FIX）：引擎纯逻辑断言（命名规整、
    /// 相册三态文案、展示排序、选文件指引、环境门）＋ WebController
    /// 回路（合成页 test-upload 上武装供文件→合成触发→回读页面持有），
    /// 结论以「自检二十二」条目写进对话。不调用模型、不起任务；要求
    /// 引擎空闲（回路会占用执行页打开合成页）。
    private func runCoverUploadFixTest() {
        let engine = self.engine
        let conversation = self.conversation
        conversation.localFeedback("自检二十二：开始——封面上传修复核查（不调用模型）")
        Task { @MainActor in
            defer { coverUploadFixTestRunning = false }
            let logicLines = await engine.verifyCoverUploadFix()
            for line in logicLines { conversation.localFeedback("自检二十二：\(line)") }
            let loopLines = await engine.verifyUploadPanelSupply()
            for line in loopLines { conversation.localFeedback("自检二十二：\(line)") }
            let failed = (logicLines + loopLines).filter { $0.hasPrefix("✗") }.count
            conversation.localFeedback(failed == 0 ? "自检二十二结论：全部通过——命名规整、相册三态文案、附件置顶排序、选文件指引与自动供文件回路均有实证" : "自检二十二结论：\(failed) 项未通过，见上方逐条记录（回路「未触发／环境结论」同样计未通过以便醒目，不代表代码失败）")
        }
    }

    /// 自检二十三编排（SELFCHECK-UNBLOCK-FIX）：引擎侧合成暂停任务→
    /// finishTask→逐项断言解锁/清快照/封续跑，结论以「自检二十三」
    /// 条目写进对话。不调用模型、不起任务、不占用标签页；要求引擎
    /// 空闲，演练毕引擎现场完整还原。
    private func runTaskFinishTest() {
        let engine = self.engine
        let conversation = self.conversation
        conversation.localFeedback("自检二十三：开始——结束任务解锁核查（不调用模型）")
        Task { @MainActor in
            defer { taskFinishTestRunning = false }
            let lines = await engine.verifyTaskFinishUnlock()
            for line in lines { conversation.localFeedback("自检二十三：\(line)") }
            let failed = lines.filter { $0.hasPrefix("✗") }.count
            conversation.localFeedback(failed == 0 ? "自检二十三结论：全部通过——暂停态锁定、结束任务后解锁/清快照/封续跑/释放绑定均有实证，引擎现场已还原" : "自检二十三结论：\(failed) 项未通过，见上方逐条记录")
        }
    }

    /// 自检二十四编排（EDITOR-ENTRY-BIND）：标题↔appmsgid 配对与翻
    /// 页纯函数断言，结论以「自检二十四」条目写进对话。不调用模
    /// 型、不占用标签页、不要求引擎空闲。
    private func runEditorEntryBindTest() {
        let engine = self.engine
        let conversation = self.conversation
        conversation.localFeedback("自检二十四：开始——标题配对与翻页核查（不调用模型）")
        defer { editorEntryBindTestRunning = false }
        let lines = engine.verifyEditorEntryBind()
        for line in lines { conversation.localFeedback("自检二十四：\(line)") }
        let failed = lines.filter { $0.hasPrefix("✗") }.count
        conversation.localFeedback(failed == 0 ? "自检二十四结论：全部通过——配对只认同对象共现、噪声不误配、歧义不猜、翻页边界正确" : "自检二十四结论：\(failed) 项未通过，见上方逐条记录")
    }

    /// 自检二十七编排（FINAL-CLAIM-AUDIT，FINISH-GATE 刀1）：完成断言
    /// 纯函数真值表、台账运行起点筛选与旧状态展示降级断言，结论以
    /// 「自检二十七」条目写进对话。不调用模型、不占用标签页。
    private func runFinalClaimAuditTest() {
        let engine = self.engine
        let conversation = self.conversation
        conversation.localFeedback("自检二十七：开始——结案自证门纯函数核查（不调用模型）")
        defer { finalClaimAuditTestRunning = false }
        let lines = engine.verifyFinalClaimAudit()
        for line in lines { conversation.localFeedback("自检二十七：\(line)") }
        let failed = lines.filter { $0.hasPrefix("✗") }.count
        conversation.localFeedback(failed == 0 ? "自检二十七结论：全部通过——完成断言识别、运行起点筛选与旧状态展示降级均成立" : "自检二十七结论：\(failed) 项未通过，见上方逐条记录")
    }

    private func runClickEffectTest() {
        defer { clickEffectTestRunning = false }
        conversation.localFeedback("自检二十八：开始——点击效果分类纯函数核查（不调用模型）")
        let lines = engine.verifyClickEffectClassification()
        for line in lines { conversation.localFeedback("自检二十八：\(line)") }
        let failed = lines.filter { $0.hasPrefix("✗") }.count
        conversation.localFeedback(failed == 0 ? "自检二十八结论：全部通过——五种签名分类成立" : "自检二十八结论：\(failed) 项未通过，见逐条记录")
    }

    private func runWrittenContentTest() {
        defer { writtenContentTestRunning = false }
        conversation.localFeedback("自检二十九：开始——页面写入入账核查（不调用模型）")
        let lines = engine.verifyWrittenContentCard()
        for line in lines { conversation.localFeedback("自检二十九：\(line)") }
        let failed = lines.filter { $0.hasPrefix("✗") }.count
        conversation.localFeedback(failed == 0 ? "自检二十九结论：全部通过——写入格式、FIFO、快照兼容与最紧折叠注入成立" : "自检二十九结论：\(failed) 项未通过，见逐条记录")
    }

    /// 自检十七 Tier A 编排（UI-LEGIBILITY）：浮层可读性的结构断言
    /// （OverlayStyle 呈现规格参数＋InterventionPrompt 卡片种类真值表），
    /// 结论以「自检十七」条目写进对话。不调用模型、不占用标签页；
    /// 像素级可读性结论属 Tier B 真机人工（见上方说明与案卷复测清单）。
    private func runLegibilityTest() {
        let conversation = self.conversation
        conversation.localFeedback("自检十七：开始——浮层可读性结构断言（不调用模型）")
        defer { legibilityTestRunning = false }
        var lines: [String] = []
        func check(_ ok: Bool, _ text: String) { lines.append((ok ? "✓ " : "✗ ") + text) }
        check(OverlayStyle.baseMaterialName == "ultraThickMaterial",
              "卡面基底为最厚材质 ultraThickMaterial（强模糊，背景文字不成字形）")
        check(OverlayStyle.coverTintOpacity >= 0.5,
              "卡面系统底色覆盖不透明度 \(OverlayStyle.coverTintOpacity) ≥ 0.5（与厚材质复合后接近不透明）")
        check(OverlayStyle.unblurredShowThrough <= 0.25,
              "未模糊直透比例 \(String(format: "%.2f", OverlayStyle.unblurredShowThrough)) ≤ 0.25（残余部分先经厚材质模糊）")
        check(OverlayStyle.scrimOpacity >= 0.40,
              "变暗遮罩不透明度 \(OverlayStyle.scrimOpacity) ≥ 0.40（卡外背景整体压暗）")
        check(OverlayStyle.scrimAllowsHitTesting == false,
              "变暗遮罩不拦截触摸（网页弹窗与坞控件照常可亲手点按）")
        let combos: [(Bool, Bool, Bool)] = [(true, true, true), (true, false, false), (false, true, true), (false, false, true), (false, false, false)]
        let kinds = combos.map { InterventionPrompt.cardKind(hasPendingUpload: $0.0, isWaitingConfirm: $0.1, isWaitingManualWithInput: $0.2) }
        check(kinds == [.upload, .upload, .confirm, .manual, .none],
              "卡片种类真值表成立：上传＞确认＞手输互斥，任意状态组合至多一张卡（文本层唯一）")
        for line in lines { conversation.localFeedback("自检十七：\(line)") }
        let failed = lines.filter { $0.hasPrefix("✗") }.count
        conversation.localFeedback(failed == 0 ? "自检十七结论（Tier A）：全部通过——厚材质＋高覆盖卡面、变暗遮罩在位且不拦截触摸、单卡互斥均成立；Tier B 真机可读性按案卷清单人工复测" : "自检十七结论（Tier A）：\(failed) 项未通过，见上方逐条记录")
    }

    /// 自检十八编排（AUTONOMY-FIX）：分类门/安全类回归/绕行梯/结案
    /// 文案/直达提取的纯函数断言＋合成页 test-autonomy 驱动（harvest
    /// 实测、弹窗导航绕行实测、全程无停车态断言），结论以「自检十八」
    /// 条目写进对话。不调用模型、不起任务；要求引擎空闲（会占用当前
    /// 标签页打开合成页）。Tier B（公众号真机往返不丢稿等）步骤与
    /// 预期见上方说明与案卷复测清单，不在本按钮内自动执行。
    private func runAutonomyTest() {
        let engine = self.engine
        let conversation = self.conversation
        conversation.localFeedback("自检十八：开始——自主完成分类门与绕行梯核查（不调用模型）")
        Task { @MainActor in
            defer { autonomyTestRunning = false }
            let lines = await engine.verifyAutonomy()
            for line in lines { conversation.localFeedback("自检十八：\(line)") }
            let failed = lines.filter { $0.hasPrefix("✗") }.count
            conversation.localFeedback(failed == 0 ? "自检十八结论（Tier A）：全部通过——分类门分流、安全类回归、绕行梯状态机、结案文案措辞、直达提取与弹窗导航绕行实测均成立，全程无停车态；Tier B 公众号真机场景按案卷清单人工复测" : "自检十八结论（Tier A）：\(failed) 项未通过，见上方逐条记录")
        }
    }

    /// 自检十九 Tier A 编排（ZORDER-FIX）：介入态浏览器置顶的层级结构
    /// 断言——直接断言 ContentView 实际使用的层级表纯函数
    /// InterventionZOrder（同一份数值供视图与本断言共用，非另抄一份
    /// 常量），结论以「自检十九」条目写进对话。不调用模型、不占用
    /// 标签页；真机层级观感（浏览器是否真浮到顶层、小条是否挡操作）
    /// 属 Tier B 真机人工（见上方说明与案卷复测清单），本按钮不冒充。
    private func runZOrderTest() {
        let conversation = self.conversation
        conversation.localFeedback("自检十九：开始——介入态浏览器置顶层级结构断言（不调用模型）")
        defer { zOrderTestRunning = false }
        var lines: [String] = []
        func check(_ ok: Bool, _ text: String) { lines.append((ok ? "✓ " : "✗ ") + text) }
        check(InterventionZOrder.scrim(browserRaised: false) > InterventionZOrder.dock(browserRaised: false),
              "常态：变暗遮罩在浏览器坞之上（介入卡出现时整屏压暗，UI-LEGIBILITY 口径不变）")
        check(InterventionZOrder.card(browserRaised: false) > InterventionZOrder.scrim(browserRaised: false)
              && InterventionZOrder.inputBar(browserRaised: false) > InterventionZOrder.card(browserRaised: false)
              && InterventionZOrder.dock(browserRaised: false) > InterventionZOrder.chat(browserRaised: false),
              "常态：介入卡在遮罩之上、坞在对话层之上、输入栏永远最上层（既有层级关系不回归）")
        check(InterventionZOrder.dock(browserRaised: true) > InterventionZOrder.scrim(browserRaised: true),
              "置顶态：浏览器坞 z 序高于变暗遮罩——遮罩不覆盖浏览器窗口，网页完整可看可亲手点")
        check(InterventionZOrder.card(browserRaised: true) > InterventionZOrder.dock(browserRaised: true),
              "置顶态：介入小条仍在坞之上——「已处理，继续」等解决按钮在浏览器置顶时可达")
        check(InterventionZOrder.scrim(browserRaised: true) > InterventionZOrder.chat(browserRaised: true)
              && InterventionZOrder.inputBar(browserRaised: true) > InterventionZOrder.card(browserRaised: true),
              "置顶态：遮罩仍压暗对话层、输入栏仍为最上层")
        check(InterventionZOrder.card(browserRaised: true) == InterventionZOrder.card(browserRaised: false)
              && InterventionZOrder.inputBar(browserRaised: true) == InterventionZOrder.inputBar(browserRaised: false),
              "置顶切换只交换坞与遮罩名次，卡与输入栏名次不变")
        check(InterventionZOrder.cardCompact(browserRaised: true) && !InterventionZOrder.cardCompact(browserRaised: false),
              "小条形态与置顶态同进退：置顶即收条让出网页操作区、复位即回全卡")
        for line in lines { conversation.localFeedback("自检十九：\(line)") }
        let failed = lines.filter { $0.hasPrefix("✗") }.count
        conversation.localFeedback(failed == 0 ? "自检十九结论（Tier A）：全部通过——常态层级与 0209 定版一致、置顶态坞高于遮罩且小条可达、只换坞与遮罩名次、收条与置顶同进退；Tier B 真机层级观感按案卷清单人工复测" : "自检十九结论（Tier A）：\(failed) 项未通过，见上方逐条记录")
    }

    /// 自检十四 Tier A 编排（WECHAT-COVER-FIX Part A）：frame 探针在
    /// 合成页 test-frames 上实测（枚举定位＋框内关闭＋消失回读），
    /// 结论以「自检十四」条目写进对话。不调用模型、不起任务；要求
    /// 引擎空闲（会占用当前标签页打开合成页）。
    private func runFrameProbeTest() {
        let engine = self.engine
        let conversation = self.conversation
        conversation.localFeedback("自检十四：开始——Tier A frame 探针与框内关闭程序化核查（不调用模型）")
        Task { @MainActor in
            defer { frameProbeTestRunning = false }
            let lines = await engine.verifyFrameProbe()
            for line in lines { conversation.localFeedback("自检十四：\(line)") }
            let failed = lines.filter { $0.hasPrefix("✗") }.count
            conversation.localFeedback(failed == 0 ? "自检十四结论（Tier A）：全部通过——frame 枚举定位、甲 pointer 序列关闭、乙 Escape 关闭、消失双证与终局零弹窗均成立；Tier B 真机场景按案卷清单人工复测" : "自检十四结论（Tier A）：\(failed) 项未通过，见上方逐条记录")
        }
    }

    /// 自检十五编排（WECHAT-COVER-FIX Part C）：步数账与检查点恢复
    /// 的纯程序化模拟（StepBudget 计数/开段/硬顶、熔断分级、快照
    /// 往返与旧格式迁移），结论以「自检十五」条目写进对话。不调用
    /// 模型、不占用标签页、不触碰引擎运行态。
    private func runStepBudgetTest() {
        let engine = self.engine
        let conversation = self.conversation
        conversation.localFeedback("自检十五：开始——步数账与检查点恢复程序化模拟（不调用模型）")
        Task { @MainActor in
            defer { stepBudgetTestRunning = false }
            let lines = engine.verifyStepBudget()
            for line in lines { conversation.localFeedback("自检十五：\(line)") }
            let failed = lines.filter { $0.hasPrefix("✗") }.count
            conversation.localFeedback(failed == 0 ? "自检十五结论：全部通过——只计模型决策、子步不计数、检查点开新段续跑不清零、硬顶封顶、熔断分级、快照往返与旧格式迁移均成立；Tier B 真机长任务按案卷清单人工复测" : "自检十五结论：\(failed) 项未通过，见上方逐条记录")
        }
    }

    /// 自检十六 Tier A 编排（WECHAT-EDITOR-NAV）：入口感知补盲的
    /// 程序化核查（WebController 在合成页 test-nav 真实驱动：无文本
    /// 入口补盲与名源、揭示复判、补盲入口点击、文本锚点回退），
    /// 结论以「自检十六」条目写进对话。不调用模型、不起任务；要求
    /// 引擎空闲（会占用当前标签页打开合成页）。Tier B（公众号编辑器
    /// 真机场景）步骤与预期见上方说明与案卷复测清单，不在本按钮内
    /// 自动执行。
    private func runEditorNavTest() {
        let engine = self.engine
        let conversation = self.conversation
        conversation.localFeedback("自检十六：开始——Tier A 入口感知补盲程序化核查（不调用模型）")
        Task { @MainActor in
            defer { editorNavTestRunning = false }
            let lines = await engine.verifyEditorNav()
            for line in lines { conversation.localFeedback("自检十六：\(line)") }
            let failed = lines.filter { $0.hasPrefix("✗") }.count
            conversation.localFeedback(failed == 0 ? "自检十六结论（Tier A）：全部通过——无文本入口补盲与名源标注、揭示复判、补盲入口点击、文本锚点回退均成立；Tier B 公众号真机场景按案卷清单人工复测" : "自检十六结论（Tier A）：\(failed) 项未通过，见上方逐条记录")
        }
    }

    /// 自检十三 Tier A 编排（VERIFY-1）：核验合约全链程序化核查
    /// （WebController 在合成页 test-verify 真实驱动四场景的三值判定，
    /// 引擎侧再做记录落盘往返与分歧统计核对），全部结论以「自检十三」
    /// 条目写进对话。不调用模型、不起任务；要求引擎空闲（驱动会占用
    /// 当前标签页打开合成页）。Tier B（知乎专栏/公众号真机场景）步骤
    /// 与预期见上方说明与案卷复测清单，不在本按钮内自动执行。
    private func runVerifyContractTest() {
        let engine = self.engine
        let conversation = self.conversation
        conversation.localFeedback("自检十三：开始——Tier A 核验合约四场景程序化核查（不调用模型）")
        Task { @MainActor in
            defer { verifyContractTestRunning = false }
            let lines = await engine.verifyActionVerificationContract()
            for line in lines { conversation.localFeedback("自检十三：\(line)") }
            let failed = lines.filter { $0.hasPrefix("✗") }.count
            conversation.localFeedback(failed == 0 ? "自检十三结论（Tier A）：全部通过——三值判定（回读 verified／toast-only unknown／明确拒绝 contradicted）、证据未稳口径、记录落盘往返与分歧统计均成立；Tier B 真机场景按案卷清单人工复测" : "自检十三结论（Tier A）：\(failed) 项未通过，见上方逐条记录")
        }
    }

    /// 自检十一 Tier A 编排（COVER-CONSENT）：封面自产程序化核查
    /// （CoverGenerator.verifyCoverGeneration：三款渲染尺寸/非空白/登记与
    /// 来源/SP-01 豁免判定）＋弹窗点按合成页真实驱动核查（WebController
    /// .verifyModalClickEscalation：裸 click 关不掉、升级序列关得掉、
    /// 无响应弹窗连败转判定）＋转介入判定双向核对，全部结论以「自检十一」
    /// 条目写进对话。不调用模型、不起任务；要求引擎空闲（弹窗核查会占用
    /// 当前标签页打开合成页）。Tier B（公众号真机全链）步骤与预期见上方
    /// 说明与案卷复测清单，不在本按钮内自动执行。
    private func runCoverModalTest() {
        let engine = self.engine
        let conversation = self.conversation
        conversation.localFeedback("自检十一：开始——Tier A 封面自产与弹窗点按升级程序化核查（不调用模型）")
        Task { @MainActor in
            defer { coverModalTestRunning = false }
            let lines = await engine.verifyCoverAndModal()
            for line in lines { conversation.localFeedback("自检十一：\(line)") }
            let failed = lines.filter { $0.hasPrefix("✗") }.count
            conversation.localFeedback(failed == 0 ? "自检十一结论（Tier A）：全部通过——封面渲染/登记/SP-01 豁免、弹窗升级点按、连败转介入判定均成立；Tier B 公众号真机全链按案卷清单人工复测" : "自检十一结论（Tier A）：\(failed) 项未通过，见上方逐条记录")
        }
    }

    /// 自检十 Tier A 编排（F1）：附件存储闭环的程序化核查（AttachmentStore
    /// .verifyAttachmentsF1：导入/抽取/缩放/同名不覆盖/只存/截图/索引往返/
    /// 注入段/SP-01 判定与确认绑定），全部结论以「自检十」条目写进对话。
    /// 不调用模型、不起任务；Tier B（真实上传全链）是真机人工流程，步骤
    /// 与预期见上方说明与案卷复测清单，不在本按钮内自动执行。
    private func runAttachmentsTest() {
        let conversation = self.conversation
        conversation.localFeedback("自检十：开始——Tier A 附件闭环程序化核查（不调用模型）")
        let lines = AttachmentStore.shared.verifyAttachmentsF1()
        for line in lines { conversation.localFeedback("自检十：\(line)") }
        let failed = lines.filter { $0.hasPrefix("✗") }.count
        conversation.localFeedback(failed == 0 ? "自检十结论（Tier A）：全部通过——导入落盘、抽取/缩放、只存口径、索引往返、SP-01 判定与确认绑定均成立；Tier B 真机上传全链按案卷清单人工复测" : "自检十结论（Tier A）：\(failed) 项未通过，见上方逐条记录")
    }

    /// 自检八编排（H1）：会话分库隔离（SessionStore 临时会话写入/回读/删除）
    /// ＋引擎侧纯函数验证（折叠/状态卡/快照往返），全部结论以「自检八」
    /// 条目写进对话（条目独立落盘，事后可查）。不调用模型、不起任务，
    /// 因此不要求 API Key；临时会话删除后不留痕。
    private func runHistoryContextTest() {
        let engine = self.engine
        let conversation = self.conversation
        conversation.localFeedback("自检八：开始——会话级分库、确定性折叠、状态卡与快照往返（不调用模型）")
        var lines: [String] = []
        lines += SessionStore.shared.verifyScratchSessionsH1()
        lines += engine.verifyHistoryContextH1()
        let disk = conversation.onDiskEntryCount()
        if let disk {
            lines.append("当前会话落盘条数 \(disk)，与内存条数 \(conversation.entries.count) 对照（攒批未刷的条目会让落盘暂多于内存，属正常）")
        } else {
            lines.append("✗ 当前会话落盘条数读取失败（文件解码异常）")
        }
        for line in lines { conversation.localFeedback("自检八：\(line)") }
        let failed = lines.filter { $0.hasPrefix("✗") }.count
        conversation.localFeedback(failed == 0 ? "自检八结论：全部通过——分库隔离、折叠有界、状态卡不丢、快照往返均成立" : "自检八结论：\(failed) 项未通过，见上方逐条记录")
    }

    /// 自检四编排（RESUME-CONTEXT-FIX）：起本地表单任务 → 等它跑出至少 2 步
    /// → 调引擎的进程级中断模拟（落盘→清内存→重置标签→仅凭快照恢复）→ 把
    /// 模拟报告写进对话 → 等用户点继续把任务续跑到终结 → 写最终结论条目。
    /// 全程以对话条目作自检报告（条目独立落盘，强退重开也还在）。
    private func runResumeTest() {
        let engine = self.engine
        let conversation = self.conversation
        Task { @MainActor in
            defer { resumeTestRunning = false }
            conversation.localFeedback("自检四：开始——先让本地表单任务跑出至少 2 步，随后模拟进程级中断")
            engine.start(local: "test-form", task: "在表单中填写姓名张三、邮箱 zhangsan@example.com 并提交，然后汇报结果文本")
            let taskID = engine.conversationTaskID
            // 阶段一：等步数攒够（或任务先行终结／超时）
            var waited = 0
            while waited < 120 {
                if engine.steps.count >= 2, case .running = engine.status { break }
                switch engine.status {
                case .done, .failed:
                    conversation.localFeedback("自检四：任务在中断模拟前已终结（\(engine.status.label)），本次未测到恢复路径，请重跑自检四")
                    return
                default: break
                }
                try? await Task.sleep(for: .seconds(1))
                waited += 1
            }
            guard engine.steps.count >= 2, engine.conversationTaskID == taskID else {
                conversation.localFeedback("自检四：等待步数超时或任务已被替换，本次未执行中断模拟，请重跑自检四")
                return
            }
            let report = engine.simulateInterruptionForResumeTest()
            conversation.localFeedback("自检四：\(report)")
            // 阶段二：等用户点「继续」把恢复的会话续跑到终结（换了新任务则终止本次自检）
            var resumedWait = 0
            while resumedWait < 300 {
                if engine.conversationTaskID != taskID {
                    conversation.localFeedback("自检四：恢复后改测了其他任务，本次结论终止（恢复本身已见上条报告）")
                    return
                }
                switch engine.status {
                case .done(let summary):
                    conversation.localFeedback("自检四结论：续跑已完成——最终汇报「\(summary)」。判读：若汇报是表单提交结果文本、且全程未向你索要网址或进度，则中断恢复通过；若它反问了任务内容／网址／进度，则不通过。")
                    return
                case .failed(let message):
                    conversation.localFeedback("自检四结论：续跑失败——\(message)。请对照上条恢复报告与步流定位（页面未带回／上下文缺失／模型连接问题分别处理）。")
                    return
                default: break
                }
                try? await Task.sleep(for: .seconds(2))
                resumedWait += 2
            }
            conversation.localFeedback("自检四：恢复后 5 分钟内未见续跑终结，结论未出——点「继续」后它会继续等待并补结论，或重跑自检四")
        }
    }

    /// 自检六编排（OUTCOME-LEDGER）：第一阶段在本地发稿页完成一次「输入→
    /// 发布→列表核对」，验收点是成果台账真的落了记录；第二阶段不重载页面
    /// （页面现场与第一阶段连续：编辑器保留原文、列表里已有审核中的同一
    /// 条），直接下「把现有稿件发布出去」的新任务——复刻 Joey 20:50 实证
    /// 里「追问开启新任务后回编辑器重发」的形态。验收点：第二阶段步流里
    /// 出现软门的「重复提交提醒」步，或其完成汇报引用了台账里的已提交
    /// 状态；最终判读再结合页面列表条数（人工目视，结论条目里写明口径）。
    private func runOutcomeTest() {
        let engine = self.engine
        let conversation = self.conversation
        Task { @MainActor in
            defer { outcomeTestRunning = false }
            conversation.localFeedback("自检六：开始——第一阶段在本地发稿页发布固定稿件并核对列表状态")
            engine.start(local: "test-publish", task: "在编辑器中输入短文『自检六稿件：定力测试』，点击『发布』，然后在页面下方的已发布列表里核对这条稿件的状态，最后汇报核对结果")
            let task1 = engine.conversationTaskID
            var waited = 0
            var phase1Summary: String?
            while waited < 240 {
                if engine.conversationTaskID != task1 {
                    conversation.localFeedback("自检六：第一阶段任务被替换，本次自检终止")
                    return
                }
                switch engine.status {
                case .done(let summary): phase1Summary = summary
                case .failed(let message):
                    conversation.localFeedback("自检六：第一阶段失败——\(message)，本次自检终止")
                    return
                default: break
                }
                if phase1Summary != nil { break }
                try? await Task.sleep(for: .seconds(2))
                waited += 2
            }
            guard phase1Summary != nil else {
                conversation.localFeedback("自检六：第一阶段超时未完成，本次自检终止（可重跑）")
                return
            }
            guard engine.outcomeLedgerCount >= 1, let latest = engine.latestOutcomeDescription else {
                conversation.localFeedback("自检六：第一阶段已完成，但成果台账没有记录——落记环节未生效，本次不通过")
                return
            }
            conversation.localFeedback("自检六：第一阶段完成，台账已记录（共 \(engine.outcomeLedgerCount) 条，最近一条：\(latest)）。第二阶段：不重载页面，直接让它把编辑器里现有的同一篇稿件再发布一次——编辑器保留着原文、已发布列表里已有状态为审核中的同一条")
            engine.start(task: "把编辑器里现有的这篇稿件发布出去，然后汇报发布结果")
            let task2 = engine.conversationTaskID
            waited = 0
            var phase2Summary: String?
            while waited < 240 {
                if engine.conversationTaskID != task2 {
                    conversation.localFeedback("自检六：第二阶段任务被替换，结论终止（第一阶段与台账记录见上）")
                    return
                }
                switch engine.status {
                case .done(let summary): phase2Summary = summary
                case .failed(let message):
                    conversation.localFeedback("自检六：第二阶段失败——\(message)。请对照步流看软门的『重复提交提醒』是否出现过")
                    return
                default: break
                }
                if phase2Summary != nil { break }
                try? await Task.sleep(for: .seconds(2))
                waited += 2
            }
            guard let summary2 = phase2Summary else {
                conversation.localFeedback("自检六：第二阶段超时未终结，结论未出（可重跑自检六）")
                return
            }
            let gateFired = engine.steps.contains { $0.action == "outcome" && $0.reason.contains("重复提交提醒") }
            let citedLedger = summary2.contains("台账") || summary2.contains("已提交") || summary2.contains("审核中") || summary2.contains("已发布")
            if gateFired || citedLedger {
                conversation.localFeedback("自检六结论：第二阶段没有把同一内容当作首次发布重复提交——\(gateFired ? "引擎软门已拦下重复点击并在步流留痕" : "模型依据台账注入直接复述了已提交状态")；第二阶段汇报「\(summary2)」。判读：页面已发布列表若仍只有 1 条、且汇报承认先前已提交，则成果定力通过；若列表变成 2 条或汇报谎称首次发布成功，则不通过。")
            } else {
                conversation.localFeedback("自检六结论：第二阶段未见软门提醒、汇报也未引用台账（汇报「\(summary2)」）——请核对页面已发布列表条数：若已变 2 条，本次不通过；若仍 1 条但路径不明，请把步流发回定位。")
            }
        }
    }

    /// 自检九编排（M1）：Tier A 程序化核查（引擎 verifyMultiSessionShell，
    /// 不调用模型——标签/置顶/切换无重载/队列往返/代次失效）＋ Tier B
    /// 真实任务编排（需模型）：scratch 会话甲跑本地表单任务 → 切到乙
    /// 入队乙的表单任务 → 切回甲等其完成 → 队列自动推进到乙并跑完 →
    /// 读两个会话的条目文件验互不串。超时/失败时不强删 scratch 会话
    /// （引擎可能还占着它），留给用户在会话列表里处理完再删。
    private func runMultiSessionTest() {
        let engine = self.engine
        let conversation = self.conversation
        let settings = self.settings
        Task { @MainActor in
            defer { multiSessionTestRunning = false }
            conversation.localFeedback("自检九：开始——Tier A 多会话外壳程序化核查（不调用模型）")
            let linesA = await engine.verifyMultiSessionShell()
            for line in linesA { conversation.localFeedback("自检九：\(line)") }
            let aFailed = linesA.filter { $0.hasPrefix("✗") }.count
            guard settings.hasKey || settings.chatGPTAuth.isLoggedIn else {
                conversation.localFeedback("自检九结论：Tier A \(aFailed == 0 ? "全部通过" : "\(aFailed) 项未通过（见上）")；Tier B（真实任务＋队列推进）因未配置模型未执行")
                return
            }
            guard !engine.busy else {
                conversation.localFeedback("自检九结论：Tier A 已出（见上）；Tier B 因引擎忙碌未执行，请等当前任务结束重跑")
                return
            }
            conversation.localFeedback("自检九：Tier B 开始——甲会话跑表单任务，切乙入队，切回等甲完成，看队列自动推进到乙")
            let store = SessionStore.shared
            let originalID = store.currentSessionID
            let aMeta = store.createSession(title: "自检九·甲")
            let bMeta = store.createSession(title: "自检九·乙")
            switchSessionForTest(bMeta.id) // createSession 后指针在乙，先落到乙占位，下面正式切甲
            switchSessionForTest(aMeta.id)
            engine.start(local: "test-form", task: "在表单中填写姓名张三、邮箱 zhangsan@example.com 并提交，然后汇报结果文本")
            // 等甲跑出至少 1 步（或先行终结）
            var waited = 0
            var aRunning = false
            while waited < 60 {
                if engine.steps.count >= 1, case .running = engine.status { aRunning = true; break }
                switch engine.status {
                case .done: aRunning = true
                case .failed(let message):
                    conversation.localFeedback("自检九：Tier B 甲任务提前失败——\(message)，本次终止（两个自检九会话保留，可在会话列表查看/删除）")
                    return
                default: break
                }
                if aRunning { break }
                try? await Task.sleep(for: .seconds(1))
                waited += 1
            }
            guard aRunning else {
                conversation.localFeedback("自检九：Tier B 甲任务未能启动，本次终止（两个自检九会话保留，可在会话列表查看/删除）")
                return
            }
            // 切到乙（引擎忙：只切查看侧），在乙入队乙的任务
            switchSessionForTest(bMeta.id)
            let viewOK = conversation.displayedSessionID == bMeta.id && engine.runSessionID == aMeta.id
            engine.enqueueTask(sessionID: bMeta.id, text: "在表单中填写姓名李四、邮箱 lisi@example.com 并提交，然后汇报结果文本", localPage: "test-form")
            conversation.queueReceipt("自检九：已在乙会话入队一条任务（甲任务执行中）")
            let queuedOK = engine.queuedTasks.contains { $0.sessionID == bMeta.id }
            conversation.localFeedback("自检九：切到乙查看——\(viewOK ? "引擎仍属甲会话（切会话不打断任务）" : "查看/执行归属异常")；入队——\(queuedOK ? "乙的任务已在队列在位" : "入队未在位")")
            // 切回甲，等甲完成
            switchSessionForTest(aMeta.id)
            waited = 0
            var aDone = false
            while waited < 240 {
                switch engine.status {
                case .done: aDone = true
                case .failed(let message):
                    conversation.localFeedback("自检九：Tier B 甲任务失败——\(message)，本次终止（乙的任务仍在队列，自检九会话保留）")
                    return
                default: break
                }
                if aDone { break }
                try? await Task.sleep(for: .seconds(2))
                waited += 2
            }
            guard aDone else {
                conversation.localFeedback("自检九：Tier B 甲任务超时未完成，本次终止（自检九会话保留，处理完后可在会话列表删除）")
                return
            }
            // 等队列自动推进到乙并跑完（推进发生在甲的完成点）
            waited = 0
            var bDone = false
            var bFailed: String?
            while waited < 240 {
                if engine.runSessionID == bMeta.id {
                    switch engine.status {
                    case .done: bDone = true
                    case .failed(let message): bFailed = message
                    default: break
                    }
                }
                if bDone || bFailed != nil { break }
                try? await Task.sleep(for: .seconds(2))
                waited += 2
            }
            // 条目隔离：甲文件只有张三、乙文件只有李四
            let aText = entriesFileText(aMeta.id)
            let bText = entriesFileText(bMeta.id)
            let isolationOK = aText.contains("张三") && !aText.contains("李四") && bText.contains("李四") && !bText.contains("张三")
            // 清理：两任务都已终结（引擎空闲）才删 scratch 会话
            var cleanupNote = "自检九会话保留（引擎未空闲），处理完后可在会话列表删除"
            if !engine.busy {
                switchSessionForTest(originalID)
                for id in [aMeta.id, bMeta.id] {
                    engine.cancelQueuedTasks(forSession: id)
                    engine.discardTabsForSession(id)
                    _ = store.deleteSession(id: id)
                }
                cleanupNote = "已切回原会话，自检九会话删除干净"
            }
            let verdict = viewOK && queuedOK && bDone && isolationOK
            conversation.localFeedback("自检九结论（Tier B）：\(verdict ? "通过" : "未完全通过")——甲任务完成 ✓；队列推进到乙并完成 \(bDone ? "✓" : "✗\(bFailed.map { "（失败：\($0)）" } ?? "（超时）")")；条目隔离 \(isolationOK ? "✓（甲只有张三、乙只有李四）" : "✗（两会话条目疑似串话，请人工核对）")；\(cleanupNote)。连同 Tier A：\(aFailed == 0 ? "全部通过" : "\(aFailed) 项未通过")。")
        }
    }

    /// 自检九用的会话切换编排（与 SessionListView 同一顺序契约：指针 →
    /// 对话换源 → 引擎 adopt）。
    private func switchSessionForTest(_ id: UUID) {
        SessionStore.shared.setCurrentSession(id: id)
        conversation.switchDisplayedSession(to: id)
        engine.adoptDisplayedSession(id)
    }

    /// 读某会话落盘条目的全文拼接（自检九条目隔离核对用）。
    private func entriesFileText(_ sessionID: UUID) -> String {
        guard let data = try? Data(contentsOf: SessionStore.shared.entriesURL(for: sessionID)),
              let entries = try? JSONDecoder().decode([PersistedChatEntry].self, from: data) else { return "" }
        return entries.map { $0.text }.joined(separator: "\n")
    }
}
