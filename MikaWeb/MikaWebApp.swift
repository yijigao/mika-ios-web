import SwiftUI
// crash-ladder 分支专用入口：只装配 DiagnosticStore（阶梯三阶恒定），根视图为 HarnessRootView。
// 主线的完整 App 装配（WebController/SettingsStore/AgentEngine/AgentConversationStore）不在本分支入口出现；
// H2 所需的 WebController 由 HarnessH2View 自行持有。主线文件未改，此覆盖仅存在于 crash-ladder 分支。
@main
struct MikaWebApp: App {
    @StateObject private var diagnostics: DiagnosticStore
    init() {
        let diagnostics = DiagnosticStore()
        diagnostics.start()
        _diagnostics = StateObject(wrappedValue: diagnostics)
    }
    var body: some Scene {
        WindowGroup {
            HarnessRootView(diagnostics: diagnostics)
        }
    }
}
