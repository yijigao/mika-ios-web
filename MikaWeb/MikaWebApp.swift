import SwiftUI
// crash-ladder-2 分支专用入口：第二轮阶梯（H3/H4）的装配基座（案卷 CRASH-LADDER-2-2026-11-02.md）。
// 与第一轮（crash-ladder，入口仅装配 DiagnosticStore）的差异：本入口按 1652 形态装配对象图——
// @StateObject 持有 WebController/SettingsStore/AgentEngine/DiagnosticStore，init 内构造并 diagnostics.start()。
// 两阶（H3/H4）之间本文件恒定：不建 AgentConversationStore、无 conversation.bind、
// scenePhase 接线不在此处（由阶梯根包装按 step 生效，见 Harness.swift）。主线文件未改，此覆盖仅存在于本分支。
@main
struct MikaWebApp: App {
    @StateObject private var web: WebController
    @StateObject private var settings: SettingsStore
    @StateObject private var engine: AgentEngine
    @StateObject private var diagnostics: DiagnosticStore
    init() {
        let web = WebController()
        let settings = SettingsStore()
        let diagnostics = DiagnosticStore()
        diagnostics.start()
        _web = StateObject(wrappedValue: web)
        _settings = StateObject(wrappedValue: settings)
        _engine = StateObject(wrappedValue: AgentEngine(web: web, settings: settings))
        _diagnostics = StateObject(wrappedValue: diagnostics)
    }
    var body: some Scene {
        WindowGroup {
            HarnessRootView(web: web, settings: settings, engine: engine, diagnostics: diagnostics)
        }
    }
}
