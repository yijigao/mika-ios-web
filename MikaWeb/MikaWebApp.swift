import SwiftUI

// App 级对象图的单一持有者（生产版）：在 App init 内同步构造完整对象图并保活；App 只以一个
// @StateObject 持有本持有者，五个对象仍经原有参数通道下传 ContentView（其 @ObservedObject
// 消费方式不变）。
// 来由（案卷 CRASH-LADDER-4-2026-11-02、修复记录 FIX-PROD-HOLDING-FORM-2026-11-02.md）：四轮阶梯
// 真机实测的定案触发条件为「App struct 里直接以多个 @StateObject 逐个持有对象图」这一形态——
// 同一对象图改由持有者形态承载的 X-1（构建 202611020431）真机稳、直接逐个持有形态的 X-2
//（构建 202611020437）崩。本改动只改「对象在哪里被持有」，对象图内容、构造顺序与时机不变；
// 具体机制未分离，不在此声称根因。形态参照阶梯的 HarnessObjectGraph（crash-ladder-2 分支）。
// 构造与 init 副作用与原 App init 逐字等价：顺序 web→settings→engine→conversation→diagnostics，
// engine 以同一个 web 实例＋settings 构造；随后 conversation.bind(to: engine)、diagnostics.start()。
@MainActor final class AppObjectGraph: ObservableObject {
    let web: WebController
    let settings: SettingsStore
    let engine: AgentEngine
    let conversation: AgentConversationStore
    let diagnostics: DiagnosticStore
    init() {
        let web = WebController()
        let settings = SettingsStore()
        let engine = AgentEngine(web: web, settings: settings)
        let conversation = AgentConversationStore()
        let diagnostics = DiagnosticStore()
        conversation.bind(to: engine)
        diagnostics.start()
        self.web = web
        self.settings = settings
        self.engine = engine
        self.conversation = conversation
        self.diagnostics = diagnostics
    }
}

@main
struct MikaWebApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var graph: AppObjectGraph
    init() {
        _graph = StateObject(wrappedValue: AppObjectGraph())
    }
    var body: some Scene {
        WindowGroup {
            ContentView(web: graph.web, settings: graph.settings, engine: graph.engine, conversation: graph.conversation, diagnostics: graph.diagnostics)
                .task {
                    #if DEBUG && targetEnvironment(simulator)
                    if ProcessInfo.processInfo.arguments.contains("--mika-type4-restart-check") {
                        let lines = graph.engine.verifyZhihuProcessRestartCheckpoint()
                        let result: [String: Any] = [
                            "runtime":"WKWebView", "buildSHA":AgentTraceStore.buildSHA,
                            "passed":!lines.contains(where: { $0.hasPrefix("✗") }), "lines":lines
                        ]
                        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]),
                           let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                            try? data.write(to: directory.appendingPathComponent("type4-restart-result.json"), options: .atomic)
                        }
                    } else if ProcessInfo.processInfo.arguments.contains("--mika-type4-selftest") {
                        let type4 = await graph.web.verifyDraftType4()
                        let selfTest56 = await graph.web.verifyZhihuPublishControl()
                        let production = await graph.engine.verifyZhihuProductionOrchestration()
                        let localForm = await graph.web.verifyBasicLocalFormTask()
                        let lines = type4 + selfTest56 + production + localForm
                        let result: [String: Any] = [
                            "runtime":"WKWebView", "buildSHA":AgentTraceStore.buildSHA,
                            "passed":!lines.contains(where: { $0.hasPrefix("✗") }),
                            "lines":lines,
                            "suites":["type4":type4, "selfTest56":selfTest56,
                                      "productionOrchestration":production, "basicLocalForm":localForm]
                        ]
                        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]),
                           let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                            try? data.write(to: directory.appendingPathComponent("type4-result.json"), options: .atomic)
                        }
                    }
                    #endif
                }
                .onChange(of: scenePhase, initial: true) { _, phase in graph.engine.setForeground(phase == .active) }
        }
    }
}
