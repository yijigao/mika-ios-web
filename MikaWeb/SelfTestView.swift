import SwiftUI
struct SelfTestView: View {
    @ObservedObject var engine: AgentEngine
    @ObservedObject var settings: SettingsStore
    @ObservedObject var conversation: AgentConversationStore
    @Environment(\.dismiss) private var dismiss
    @State private var resumeTestRunning = false
    @State private var outcomeTestRunning = false
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
        }.navigationTitle("本地自检")
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
}
