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
    /// 用户主动展开坞的请求令牌（INTERVENTION-PROMPT 定版）：对话区介入卡上的
    /// 「打开浏览器查看／打开浏览器」点击时 +1，下传浏览器坞展开。坞的一切形态
    /// 变化只来自用户动作（护盾点按／收起按钮／本令牌），程序不再自动展开。
    @State private var dockExpandRequest = 0
    /// 会话列表 sheet（M1）：多会话外壳的管理入口（新建／切换／改名／删除
    /// 会话、队列查看与取消），编排顺序契约在 SessionListView 文件头。
    @State private var showSessions = false
    /// 附件中心 sheet（F1）：当前会话的附件与浏览器截图（导入／预览／
    /// 分享导出／删除＋保存当前页截图），见 AttachmentsView。
    @State private var showAttachments = false
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
            // 层级调整 2026-11-02，案卷 CHAT-KEYBOARD-FIX-2026-11-02.md 问题 3；
            // 介入层 2026-11-02，案卷 INTERVENTION-PROMPT-IMPL-2026-11-02.md）：
            // ZStack 自下而上——对话消息层（全屏常驻根层）＜ 浏览器坞（expanded
            // 全屏／mini 悬浮小窗，WKWebView 实例常驻保活，见 BrowserDockView.swift）
            // ＜ 介入提示卡（仅等待确认／手输时出现，固定在输入栏上方，小窗与展开态
            // 都可见）＜ 聊天输入栏（输入框＋发送键，永远在最上层，坞怎么拖/展开都
            // 盖不住；键盘升起时随根层安全区上浮、仍在最上层）。
            // App 级对象图与持有形态（MikaWebApp.swift）不变，五件仍经原参数通道下传。
            ZStack(alignment: .bottom) {
                AgentChatView(engine: engine, settings: settings, conversation: conversation,
                              inputFocus: $chatInputFocused, followLatest: $followLatest,
                              bottomInset: inputBarHeight)
                BrowserDockView(web: web, engine: engine, chatInputFocus: $chatInputFocused,
                                bottomReserve: dockBottomReserve, expandRequest: dockExpandRequest, dock: web.dockState,
                                onReturnToExecution: { returnToExecution() })
                if showsInterventionPrompt {
                    InterventionPrompt(engine: engine, web: web,
                                       onOpenBrowser: { dockExpandRequest += 1 })
                        .padding(.horizontal, 12)
                        .padding(.bottom, inputBarHeight + 6)
                }
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
                Button { showSessions = true } label: { Text("会话") }
                Button { showAttachments = true } label: { Text("附件") }
                NavigationLink { SelfTestView(engine: engine, settings: settings, conversation: conversation) } label: { Text("自检") }
                NavigationLink { SettingsView(settings: settings, diagnostics: diagnostics) } label: { Image(systemName: "gearshape") }.accessibilityLabel("设置")
            }
            .sheet(isPresented: $showSessions) {
                SessionListView(engine: engine, conversation: conversation, web: web)
            }
            .sheet(isPresented: $showAttachments) {
                AttachmentsView(web: web)
            }
        }
        .onAppear { consumePending() }
        .onChange(of: pending.task) { _, _ in consumePending() }
    }
    private func consumePending() {
        if let task = pending.task { conversation.draft = task; pending.task = nil }
    }
    /// 是否需要呈现置顶介入卡：执行前确认，或手输等待（waitingInput 为 .manual）。
    /// ask_user 提问（.question）在输入栏作答、不出卡。与 BrowserDockView 的
    /// needsIntervention 同口径（那边只驱动小窗状态提示）。
    /// M1 门控：介入卡属于任务所在会话——正看别的会话时不出卡（确认的是
    /// 另一个会话页面上的动作，在这里点确认会串会话），坞上的会话条与
    /// 「返回执行页」会把用户领回去；切回任务会话后卡片照常出现。
    private var showsInterventionPrompt: Bool {
        guard conversation.displayedSessionID == engine.runSessionID else { return false }
        if engine.pendingUpload != nil { return true }
        if case .waitingConfirm = engine.status { return true }
        if case .waitingManual = engine.status, case .some(.manual) = engine.waitingInput { return true }
        return false
    }
    /// 「返回执行页」（M1，坞上入口的落点）：把查看侧整体带回任务所在
    /// 会话——指针、对话、标签按切换编排切过去，并让执行标签成为当前
    /// 页。执行本身不受影响（切会话从不打断任务，见引擎 adopt 口径）。
    private func returnToExecution() {
        let target = engine.runSessionID
        if target != conversation.displayedSessionID {
            SessionStore.shared.setCurrentSession(id: target)
            conversation.switchDisplayedSession(to: target)
            engine.adoptDisplayedSession(target)
        }
        web.revealExecutionTab()
        dockExpandRequest += 1
    }
}
