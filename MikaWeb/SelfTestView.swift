import SwiftUI
struct SelfTestView: View {
    @ObservedObject var engine: AgentEngine
    @ObservedObject var settings: SettingsStore
    @ObservedObject var conversation: AgentConversationStore
    @Environment(\.dismiss) private var dismiss
    @State private var resumeTestRunning = false
    @State private var outcomeTestRunning = false
    @State private var multiSessionTestRunning = false
    @State private var coverModalTestRunning = false
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
        }.navigationTitle("本地自检")
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
