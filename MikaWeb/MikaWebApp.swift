import SwiftUI
// crash-ladder-2 分支专用入口：阶梯装配基座（案卷 CRASH-LADDER-2-2026-11-02.md、CRASH-LADDER-3-2026-11-02.md）。
// 本入口只装配两件 App 级对象：DiagnosticStore（init 构造并 start()，各阶恒定）与 HarnessObjectGraph
//（对象图持有者，init 内按 Harness.step 分阶构造 web/settings/engine，见 Harness.swift 的分阶表与耦合说明）。
// 不建 AgentConversationStore、无 bind；scenePhase 接线不在此处（由阶梯根包装按 step 生效，见 Harness.swift）。
// 主线文件未改，此覆盖仅存在于本分支。
@main
struct MikaWebApp: App {
    @StateObject private var diagnostics: DiagnosticStore
    @StateObject private var graph: HarnessObjectGraph
    init() {
        let diagnostics = DiagnosticStore()
        diagnostics.start()
        _diagnostics = StateObject(wrappedValue: diagnostics)
        _graph = StateObject(wrappedValue: HarnessObjectGraph(step: Harness.step))
    }
    var body: some Scene {
        WindowGroup {
            HarnessRootView(web: graph.web, settings: graph.settings, engine: graph.engine, diagnostics: diagnostics)
        }
    }
}
