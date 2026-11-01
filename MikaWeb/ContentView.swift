import SwiftUI
struct ContentView: View {
    @ObservedObject var web: WebController
    @ObservedObject var settings: SettingsStore
    @ObservedObject var engine: AgentEngine
    @ObservedObject private var pending = PendingTaskStore.shared
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                BrowserView(controller: web).frame(maxHeight: .infinity)
                Divider()
                AgentConsoleView(engine: engine, settings: settings)
            }
            .navigationTitle("Mika Web").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                NavigationLink { SelfTestView(engine: engine, settings: settings) } label: { Text("自检") }
                NavigationLink { SettingsView(settings: settings) } label: { Image(systemName: "gearshape") }.accessibilityLabel("设置")
            }
        }
        .onAppear { consumePending() }
        .onChange(of: pending.task) { _, _ in consumePending() }
    }
    private func consumePending() {
        if let task = pending.task { engine.stop(); engine.taskText = task; pending.task = nil }
    }
}
