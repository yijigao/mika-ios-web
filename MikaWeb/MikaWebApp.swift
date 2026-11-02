import SwiftUI
// crash-ladder-2 分支专用入口：第四轮阶梯 X-2（step=11）的持有形态变体（案卷 CRASH-LADDER-4-2026-11-02.md）。
// 与 X-1（step=10）的唯一差异：对象图持有形态——本文件按第二轮 H3a（提交 0905d58）的原样，App 直接以
// @StateObject 逐个持有 WebController/SettingsStore/AgentEngine/DiagnosticStore，不用 HarnessObjectGraph
// 间接层；构造顺序（web→settings→engine）、构造时机（App init 内）与对象图内容与 X-1 逐字等价，
// engine 仍以视图消费的同一个 web 实例构造；diagnostics 在 init 内构造并 start()（各阶恒定）。
// 不建 AgentConversationStore、无 bind；scenePhase 接线不在此处（由阶梯根包装按 step 生效，见 Harness.swift）。
// 主线文件未改，此覆盖仅存在于本分支；本文件仅在 step=11 的提交内为此形态，step=10 用持有者形态版。
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
