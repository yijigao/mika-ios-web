import SwiftUI
struct ContentView: View {
    @ObservedObject var web: WebController
    @ObservedObject var settings: SettingsStore
    @ObservedObject var engine: AgentEngine
    @ObservedObject var conversation: AgentConversationStore
    @ObservedObject var panel: FloatingPanelStore
    @ObservedObject var diagnostics: DiagnosticStore
    @ObservedObject private var pending = PendingTaskStore.shared
    var body: some View {
        NavigationStack {
            ZStack {
                BrowserView(controller: web)
                FloatingAgentOverlay(panel: panel, conversation: conversation, engine: engine, settings: settings)
            }
            .navigationTitle("Mika Web").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                NavigationLink { SelfTestView(engine: engine, settings: settings) } label: { Text("自检") }
                NavigationLink { SettingsView(settings: settings, diagnostics: diagnostics) } label: { Image(systemName: "gearshape") }.accessibilityLabel("设置")
            }
        }
        .onAppear { consumePending() }
        .onChange(of: pending.task) { _, _ in consumePending() }
    }
    private func consumePending() {
        if let task = pending.task { conversation.draft = task; pending.task = nil }
    }
}
