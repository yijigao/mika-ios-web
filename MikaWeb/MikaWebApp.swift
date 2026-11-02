import SwiftUI
// crash-ladder-2 分支专用入口：阶梯装配基座（案卷 CRASH-LADDER-2-2026-11-02.md、CRASH-LADDER-3-2026-11-02.md）。
// 对象图按 Harness.step 在 init 内分阶构造（各阶差异只在「App 级建哪些对象」，视图与地基恒定）：
// - step 0/1/2（第一轮各阶＋H2 基线）：只装配 DiagnosticStore——与 H2 基线提交 2e9a33d 的入口逐字等价
//   （H2 所需的 WebController 由 HarnessH2View 自行 @StateObject 持有）；
// - step 3/4/5/6（第二轮 H3/H4/H3a/H3b）：1652 形态全对象图——App init 构造 WebController/SettingsStore/
//   AgentEngine 并 @StateObject 持有、下传根视图，与本分支此前提交行为一致；
// - step 7（第三轮 A-1）：只建 WebController 并 App 级 @StateObject 持有、下传根视图消费（A1＋其必然下传接线 A4），
//   不建 SettingsStore、不建 AgentEngine；
// - step 8（第三轮 A-2）：只建 SettingsStore 并 App 级 @StateObject 持有（不下传消费、不接业务），
//   不建 App 级 WebController/AgentEngine，根视图 WebController 仍自持（同 H2）；
// - step 9（第三轮 A-3 耦合阶「A2+A3」）：AgentEngine.init(web:settings:) 构造签名强制要求 SettingsStore 与
//   WebController 两个实例，A3 无法独立于 A2 及一个 web 实例存在（耦合关系详记 CRASH-LADDER-3 §1）——
//   本阶建 SettingsStore（同 A2，App 级持有）＋AgentEngine（App 级持有、只建不执行）；engine 的 web 参数
//   仅为满足 init 签名的依赖实例：不进 App @StateObject、不下传任何视图、仅由 engine 的 strong let 引用保活；
//   BrowserView 实际消费的 WebController 仍由根视图自持（同 H2）。
// 各阶共同：DiagnosticStore 于 init 构造并 start()；不建 AgentConversationStore、无 bind；
// scenePhase 接线不在此处（由阶梯根包装按 step 生效，见 Harness.swift）。主线文件未改，此覆盖仅存在于本分支。
@main
struct MikaWebApp: App {
    @StateObject private var diagnostics: DiagnosticStore
    @StateObject private var web: WebController?
    @StateObject private var settings: SettingsStore?
    @StateObject private var engine: AgentEngine?
    init() {
        let diagnostics = DiagnosticStore()
        diagnostics.start()
        _diagnostics = StateObject(wrappedValue: diagnostics)
        var web: WebController? = nil
        var settings: SettingsStore? = nil
        var engine: AgentEngine? = nil
        switch Harness.step {
        case 3, 4, 5, 6:
            let w = WebController()
            let s = SettingsStore()
            web = w
            settings = s
            engine = AgentEngine(web: w, settings: s)
        case 7:
            web = WebController()
        case 8:
            settings = SettingsStore()
        case 9:
            let s = SettingsStore()
            settings = s
            engine = AgentEngine(web: WebController(), settings: s)
        default:
            break
        }
        _web = StateObject(wrappedValue: web)
        _settings = StateObject(wrappedValue: settings)
        _engine = StateObject(wrappedValue: engine)
    }
    var body: some Scene {
        WindowGroup {
            HarnessRootView(web: web, settings: settings, engine: engine, diagnostics: diagnostics)
        }
    }
}
