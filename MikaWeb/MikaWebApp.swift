import SwiftUI
@main
struct MikaWebApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var web: WebController
    @StateObject private var settings: SettingsStore
    @StateObject private var engine: AgentEngine
    init() {
        let web = WebController()
        let settings = SettingsStore()
        _web = StateObject(wrappedValue: web)
        _settings = StateObject(wrappedValue: settings)
        _engine = StateObject(wrappedValue: AgentEngine(web: web, settings: settings))
    }
    var body: some Scene {
        WindowGroup {
            ContentView(web: web, settings: settings, engine: engine)
                .onChange(of: scenePhase, initial: true) { _, phase in engine.setForeground(phase == .active) }
        }
    }
}
