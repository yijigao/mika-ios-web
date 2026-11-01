import SwiftUI
struct AgentConsoleView: View {
    @ObservedObject var engine: AgentEngine
    @ObservedObject var settings: SettingsStore
    private var confirming: Binding<Bool> {
        Binding(get: { if case .waitingConfirm = engine.status { return true }; return false }, set: { _ in })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("输入网页任务", text: $engine.taskText, axis: .vertical).lineLimit(1...3).textFieldStyle(.roundedBorder)
            HStack {
                Button("开始") { engine.start() }.disabled(!engine.active)
                Button("停止") { engine.stop() }.disabled(!engine.busy)
                switch engine.status {
                case .paused, .waitingManual, .failed: Button("继续") { engine.resume() }.disabled(!engine.active)
                default: EmptyView()
                }
                Spacer()
                Text("步骤 \(engine.steps.count) / \(settings.maxSteps)").font(.caption)
            }
            Text(engine.status.label).font(.callout).textSelection(.enabled)
            if !settings.hasKey { Text("没有 API Key：请到设置页配置后开始（自检也需要）。").foregroundStyle(.orange).font(.caption) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(engine.steps) { step in
                        Text("\(step.id). \(step.action) — \(step.reason)").font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(maxHeight: 120)
        }.padding()
        .alert("执行敏感操作？", isPresented: confirming) {
            Button("执行", role: .destructive) { engine.confirm(execute: true) }
            Button("跳过", role: .cancel) { engine.confirm(execute: false) }
        } message: {
            if case .waitingConfirm(let action) = engine.status {
                Text("动作：\(action.action)，目标序号：\(action.index)\n\(action.reason)\n涉及付款、购买或授权，请核对网页。")
            }
        }
    }
}
