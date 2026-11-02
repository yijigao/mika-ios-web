import SwiftUI
struct ContentView: View {
    @ObservedObject var web: WebController
    @ObservedObject var settings: SettingsStore
    @ObservedObject var engine: AgentEngine
    @ObservedObject var conversation: AgentConversationStore
    @ObservedObject var diagnostics: DiagnosticStore
    @ObservedObject private var pending = PendingTaskStore.shared
    var body: some View {
        NavigationStack {
            // 布局层（悬浮窗改造，2026-11-02，案卷 FLOATING-UI-IMPL-2026-11-02.md）：
            // 对话层全屏常驻为根层；浏览器坞盖在其上（expanded 全屏／mini 悬浮小窗，
            // 坞内 BrowserView 与 WKWebView 实例常驻保活，见 BrowserDockView.swift）。
            // App 级对象图与持有形态（MikaWebApp.swift）不变，五件仍经原参数通道下传。
            ZStack {
                AgentChatView(engine: engine, settings: settings, conversation: conversation)
                BrowserDockView(web: web, engine: engine)
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
