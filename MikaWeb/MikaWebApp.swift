import SwiftUI
@main
struct MikaWebApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var web: WebController
    @StateObject private var settings: SettingsStore
    @StateObject private var engine: AgentEngine
    @StateObject private var conversation: AgentConversationStore
    @StateObject private var panel: FloatingPanelStore
    @StateObject private var diagnostics: DiagnosticStore
    init() {
        let debugConfig = DebugSwitches.launchConfig
        let web = WebController()
        let settings = SettingsStore()
        _web = StateObject(wrappedValue: web)
        _settings = StateObject(wrappedValue: settings)
        let engine = AgentEngine(web: web, settings: settings)
        let conversation = AgentConversationStore()
        let panel = FloatingPanelStore(initiallyExpanded: debugConfig.panelSink ? debugConfig.panelState : true, lockExpanded: !debugConfig.panelSink)
        let diagnostics = DiagnosticStore()
        if debugConfig.convSink { conversation.bind(to: engine) }
        if debugConfig.panelSink { panel.bind(to: engine) }
        if debugConfig.diag { diagnostics.start() }
        _engine = StateObject(wrappedValue: engine)
        _conversation = StateObject(wrappedValue: conversation)
        _panel = StateObject(wrappedValue: panel)
        _diagnostics = StateObject(wrappedValue: diagnostics)
    }
    var body: some Scene {
        WindowGroup {
            ContentView(web: web, settings: settings, engine: engine, conversation: conversation, panel: panel, diagnostics: diagnostics)
                .onChange(of: scenePhase, initial: true) { _, phase in engine.setForeground(phase == .active) }
        }
    }
}
