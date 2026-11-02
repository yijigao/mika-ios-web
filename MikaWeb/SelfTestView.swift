import SwiftUI
struct SelfTestView: View {
    @ObservedObject var engine: AgentEngine
    @ObservedObject var settings: SettingsStore
    @ObservedObject var conversation: AgentConversationStore
    @Environment(\.dismiss) private var dismiss
    @State private var resumeTestRunning = false
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
}
