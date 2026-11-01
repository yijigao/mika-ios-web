import SwiftUI
@main
struct MikaWebApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var web: WebController
    @StateObject private var settings: SettingsStore
    @StateObject private var engine: AgentEngine
    @StateObject private var conversation: AgentConversationStore
    @StateObject private var diagnostics: DiagnosticStore
    init() {
        let web = WebController()
        let settings = SettingsStore()
        let engine = AgentEngine(web: web, settings: settings)
        let conversation = AgentConversationStore()
        let diagnostics = DiagnosticStore()
        conversation.bind(to: engine)
        diagnostics.start()
        _web = StateObject(wrappedValue: web)
        _settings = StateObject(wrappedValue: settings)
        _engine = StateObject(wrappedValue: engine)
        _conversation = StateObject(wrappedValue: conversation)
        _diagnostics = StateObject(wrappedValue: diagnostics)
    }
    var body: some Scene {
        WindowGroup {
            ContentView(web: web, settings: settings, engine: engine, conversation: conversation, diagnostics: diagnostics)
                .onChange(of: scenePhase, initial: true) { _, phase in engine.setForeground(phase == .active) }
        }
    }
}
