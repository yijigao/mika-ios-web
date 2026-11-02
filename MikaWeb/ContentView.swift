import SwiftUI
struct ContentView: View {
    @ObservedObject var web: WebController
    @ObservedObject var settings: SettingsStore
    @ObservedObject var engine: AgentEngine
    @ObservedObject var conversation: AgentConversationStore
    @ObservedObject var diagnostics: DiagnosticStore
    @ObservedObject private var pending = PendingTaskStore.shared
    /// 对话输入框焦点（键盘修复，案卷 CHAT-KEYBOARD-FIX-2026-11-02.md）：在此持有，
    /// 绑定下传对话层 TextField，普通 Binding 再下传浏览器坞——坞展开盖住对话层时
    /// 由坞代为收起，避免键盘悬浮在全屏浏览器上且用户无从收起。
    @FocusState private var chatInputFocused: Bool
    var body: some View {
        NavigationStack {
            // 布局层（悬浮窗改造，2026-11-02，案卷 FLOATING-UI-IMPL-2026-11-02.md）：
            // 对话层全屏常驻为根层；浏览器坞盖在其上（expanded 全屏／mini 悬浮小窗，
            // 坞内 BrowserView 与 WKWebView 实例常驻保活，见 BrowserDockView.swift）。
            // App 级对象图与持有形态（MikaWebApp.swift）不变，五件仍经原参数通道下传。
            ZStack {
                AgentChatView(engine: engine, settings: settings, conversation: conversation, inputFocus: $chatInputFocused)
                BrowserDockView(web: web, engine: engine, chatInputFocus: $chatInputFocused)
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
