import SwiftUI
struct SelfTestView: View {
    @ObservedObject var engine: AgentEngine
    @ObservedObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
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
        }.navigationTitle("本地自检")
    }
}
