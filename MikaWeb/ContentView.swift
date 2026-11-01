import SwiftUI
struct ContentView: View {
    @ObservedObject var web: WebController
    @ObservedObject var settings: SettingsStore
    @ObservedObject var engine: AgentEngine
    @ObservedObject var conversation: AgentConversationStore
    @ObservedObject var panel: FloatingPanelStore
    @ObservedObject var diagnostics: DiagnosticStore
    @ObservedObject private var pending = PendingTaskStore.shared
    @FocusState private var inputFocused: Bool
    private let debugConfig = DebugSwitches.launchConfig
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                BrowserView(controller: web)
                    .frame(width: debugConfig.geo ? geometry.size.width : nil, height: debugConfig.geo ? geometry.size.height : nil)
                    .overlay(alignment: .bottom) {
                        if panel.expanded {
                            Group {
                                if !debugConfig.observe {
                                    StaticChatView()
                                } else if !debugConfig.chat {
                                    DebugChatPlaceholder()
                                } else {
                                    AgentChatView(engine: engine, settings: settings, conversation: conversation, panel: panel, inputFocused: $inputFocused)
                                }
                            }
                                .frame(width: geometry.size.width, height: min(geometry.size.height * 0.55, max(240, geometry.size.height - 12)))
                                .background(.regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))
                                .shadow(radius: 12)
                        }
                    }
                    .overlay(alignment: panel.edge == .left ? .leading : .trailing) {
                        if !panel.expanded {
                            FloatingBallView(panel: panel, engine: engine, availableSize: geometry.size)
                                .padding(.horizontal, 20)
                                .offset(y: 50 + panel.verticalFraction * max(0, geometry.size.height - 100) - geometry.size.height / 2)
                        }
                    }
            }
            .navigationTitle("Mika Web").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                NavigationLink { SelfTestView(engine: engine, settings: settings) } label: { Text("自检") }
                NavigationLink { SettingsView(settings: settings, diagnostics: diagnostics) } label: { Image(systemName: "gearshape") }.accessibilityLabel("设置")
            }
        }
        .onChange(of: panel.expanded) { _, expanded in if !expanded { inputFocused = false } }
        .onAppear { consumePending() }
        .onChange(of: pending.task) { _, _ in consumePending() }
    }
    private func consumePending() {
        if let task = pending.task { conversation.draft = task; pending.task = nil }
    }
}
