import SwiftUI
struct AgentConsoleView: View {
    @ObservedObject var engine: AgentEngine
    @State private var expandedSteps = false
    @ObservedObject private var sessionStore = SessionStore.shared
    @ObservedObject var settings: SettingsStore
    private var isQuestionWaiting: Bool { if case .some(.question(_, _)) = engine.waitingInput { return true }; return false }
    private var confirming: Binding<Bool> {
        Binding(get: { if case .waitingConfirm = engine.status { return true }; return false }, set: { _ in })
    }
    private var statusColor: Color {
        switch engine.status {
        case .running: return .blue
        case .done: return .green
        case .failed: return .red
        case .paused, .waitingConfirm, .waitingManual: return .orange
        case .idle, .ended: return .secondary
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("输入网页任务", text: $engine.taskText, axis: .vertical).lineLimit(1...3).textFieldStyle(.roundedBorder)
            HStack(spacing: 12) {
                Button("开始") { engine.start() }.disabled(!engine.active || engine.interruptInFlight || engine.pendingInterrupt != nil)
                Button("停止") { engine.stop() }.disabled(!engine.busy || engine.interruptInFlight || engine.pendingInterrupt != nil)
                switch engine.status {
                case .paused, .failed: Button("继续") { engine.resume() }.disabled(!engine.active || isQuestionWaiting || engine.interruptInFlight || engine.pendingInterrupt != nil)
                case .waitingManual: Button("继续") { engine.resume() }.disabled(!engine.active || isQuestionWaiting || engine.interruptInFlight || engine.pendingInterrupt != nil)
                default: EmptyView()
                }
                Spacer()
                Text("步骤 \(engine.steps.count) / \(settings.maxSteps)").font(.caption).foregroundStyle(.secondary)
            }
            Text(engine.status.label).font(.callout).foregroundStyle(statusColor).textSelection(.enabled)
            if !settings.hasKey {
                NavigationLink {
                    SettingsView(settings: settings)
                } label: {
                    Label("还没有 API Key：点这里去设置页 — 选服务商 → 粘贴 Key → 点「保存并测试连接」", systemImage: "key.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !engine.steps.isEmpty {
                let entries = engine.steps.map { ChatEntry(taskID: engine.conversationTaskID, kind: .process, text: $0.reason, stepID: $0.id, action: $0.action, reason: $0.reason, source: .engineStep) }
                let groups = ProcessFold.nodes(entries)
                let phase: ProcessFold.Phase = { switch engine.status { case .done: return .completed; case .failed, .ended: return .stopped; default: return .executing } }()
                if let group = groups.last {
                    let latest = group.entries.last
                    let tail = phase == .executing ? " · 共 \(group.entries.count) 步" : " · 最新：" + ProcessFold.summary(action: latest?.action, reason: latest?.reason, text: latest?.text ?? "")
                    Button { expandedSteps.toggle() } label: {
                        Text(ProcessFold.header(group.entries, phase: phase) + tail + (expandedSteps ? " · 收起" : " · 展开"))
                            .font(.caption).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    }.accessibilityLabel(ProcessFold.accessibility(group.entries, phase: phase))
                }
                if expandedSteps {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(engine.steps) { step in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("\(step.id).").font(.caption).foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                                    Text(step.action).font(.caption).fontWeight(.semibold)
                                    Text(step.reason).font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.frame(maxHeight: 120)
                }
            }
        }.padding()
        .onChange(of: engine.conversationTaskID) { _, _ in expandedSteps = false }
        .onChange(of: sessionStore.currentSessionID) { _, _ in expandedSteps = false }
        .onChange(of: engine.status.isTerminalForFold) { _, terminal in if terminal { expandedSteps = false } }
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
