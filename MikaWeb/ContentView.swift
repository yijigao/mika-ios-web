import SwiftUI
struct ContentView: View {
    @ObservedObject var web: WebController
    @ObservedObject var settings: SettingsStore
    @ObservedObject var engine: AgentEngine
    @ObservedObject var conversation: AgentConversationStore
    @ObservedObject var diagnostics: DiagnosticStore
    @ObservedObject private var pending = PendingTaskStore.shared
    /// 对话输入框焦点（键盘修复，案卷 CHAT-KEYBOARD-FIX-2026-11-02.md）：在此持有，
    /// 绑定下传输入栏的 TextField，FocusState Binding 再下传浏览器坞——坞展开盖住
    /// 对话层时由坞代为收起，避免键盘悬浮在全屏浏览器上且用户无从收起。
    @FocusState private var chatInputFocused: Bool
    /// 跟随最新消息（发送成功后输入栏置真，消息层据此滚动到底部）。
    @State private var followLatest = true
    /// 输入栏实测高度：草稿从一行长到三行时随之变高；测得后下传消息层做底部
    /// 避让、下传坞做小窗钳制与展开态介入 UI 避让。初值是单行栏的估算，首帧实测即覆盖。
    @State private var inputBarHeight: CGFloat = 60
    /// 坞坐标系里的底部保留高度：输入栏实测高＋底部安全区上限（约 34pt，坞的几何
    /// 区是全出血坐标，含 Home 指示条区）＋8pt 余量。对应关系与旧写死常量 148 的
    /// 区别见案卷问题 3 一节（旧常量护的是输入行＋按钮行两行区，新层级只护输入栏）。
    private var dockBottomReserve: CGFloat { inputBarHeight + 42 }
    var body: some View {
        NavigationStack {
            // 布局层（悬浮窗改造，2026-11-02，案卷 FLOATING-UI-IMPL-2026-11-02.md；
            // 层级调整 2026-11-02，案卷 CHAT-KEYBOARD-FIX-2026-11-02.md 问题 3）：
            // ZStack 自下而上三层——对话消息层（全屏常驻根层）＜ 浏览器坞（expanded
            // 全屏／mini 悬浮小窗，WKWebView 实例常驻保活，见 BrowserDockView.swift）
            // ＜ 聊天输入栏（输入框＋发送键，永远在最上层，坞怎么拖/展开都盖不住；
            // 键盘升起时随根层安全区上浮、仍在最上层）。
            // App 级对象图与持有形态（MikaWebApp.swift）不变，五件仍经原参数通道下传。
            ZStack(alignment: .bottom) {
                AgentChatView(engine: engine, settings: settings, conversation: conversation,
                              inputFocus: $chatInputFocused, followLatest: $followLatest,
                              bottomInset: inputBarHeight)
                BrowserDockView(web: web, engine: engine, chatInputFocus: $chatInputFocused,
                                bottomReserve: dockBottomReserve)
                ChatInputBar(engine: engine, conversation: conversation,
                             inputFocus: $chatInputFocused, followLatest: $followLatest)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { newHeight in
                        inputBarHeight = newHeight
                    }
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
