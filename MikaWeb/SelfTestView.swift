import SwiftUI
struct SelfTestView: View {
    @ObservedObject var engine: AgentEngine
    @ObservedObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Text("加载本地页面，仍使用真实模型调用；任务在 App 前台内执行。")
            if !settings.hasKey { Text("未配置 API Key，请先到设置页填写。").foregroundStyle(.orange) }
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
        }.navigationTitle("本地自检")
    }
}
