import SwiftUI
import UIKit
struct ContentView: View {
    @ObservedObject var web: WebController
    @ObservedObject var settings: SettingsStore
    @ObservedObject var engine: AgentEngine
    @ObservedObject var conversation: AgentConversationStore
    @ObservedObject var diagnostics: DiagnosticStore
    @ObservedObject private var sessionStore = SessionStore.shared
    @ObservedObject private var pending = PendingTaskStore.shared
    /// 对话输入框焦点（键盘修复，案卷 CHAT-KEYBOARD-FIX-2026-11-02.md）：在此持有，
    /// 绑定下传输入栏的 TextField，FocusState Binding 再下传浏览器坞——坞展开盖住
    /// 对话层时由坞代为收起，避免键盘悬浮在全屏浏览器上且用户无从收起。
    @FocusState private var chatInputFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    /// 跟随最新消息（发送成功后输入栏置真，消息层据此滚动到底部）。
    @State private var followLatest = true
    @State private var scrollToBottomRequest = 0
    /// 用户主动展开坞的请求令牌（INTERVENTION-PROMPT 定版）：对话区介入卡上的
    /// 「打开浏览器查看／打开浏览器」点击时 +1，下传浏览器坞全屏展开。
    /// 普通显隐由任务状态、固定开关与安全介入共同驱动。
    @State private var dockExpandRequest = 0
    /// 介入态「浏览器置顶」呈现状态（ZORDER-FIX）：用户在介入卡上点
    /// 「打开浏览器*」时与 expandRequest 同一次点击置真——根层级换位
    /// （层级表见 InterventionZOrder）：浏览器坞升至变暗遮罩之上（遮罩
    /// 不再覆盖浏览器窗口，网页可看可亲手点），介入卡收成坞之上的小条
    /// （解决按钮仍在条上可达、「说明」可回全卡）。介入解除
    /// （showsInterventionPrompt 转假）时自动复位。纯呈现状态，不参与
    /// 任何引擎／安全判定；与 AUTONOMY-FIX 的介入分类门只做呈现配合。
    @State private var interventionBrowserRaised = false
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
            // 介入层 2026-11-02，案卷 INTERVENTION-PROMPT-IMPL-2026-11-02.md；
            // 介入态浏览器置顶 2026-11-03，案卷 ZORDER-FIX-IMPL-2026-11-03.md）：
            // ZStack 自下而上（名次以 InterventionZOrder 层级表为准，视图与
            // 自检十九共用一份数值）——常态：对话消息层（全屏常驻根层）＜ 浏览器
            // 坞（expanded 全屏／mini 悬浮小窗，WKWebView 实例常驻保活，见
            // BrowserDockView.swift）＜ 变暗遮罩＋介入提示卡（仅等待确认／手输时
            // 出现，固定在输入栏上方，小窗与展开态都可见）＜ 聊天输入栏（输入框
            // ＋发送键，浮窗态在最上层，键盘升起时随根层安全区上浮；浏览器进入
            // 全屏时输入栏与夹挂开关作为整组收起）。介入态用户点卡上「打开浏览器*」后进入
            // 置顶态：只交换坞与遮罩的名次（遮罩退到坞之下、不再覆盖浏览器
            // 窗口），介入卡收成坞之上的小条，处理完点小条上的解决按钮即随
            // 介入解除自动复位。
            // App 级对象图与持有形态（MikaWebApp.swift）不变，五件仍经原参数通道下传。
            ZStack(alignment: .bottom) {
                AgentChatView(engine: engine, settings: settings, conversation: conversation,
                              inputFocus: $chatInputFocused, followLatest: $followLatest,
                              scrollToBottomRequest: scrollToBottomRequest,
                              bottomInset: inputBarHeight)
                    .zIndex(InterventionZOrder.chat(browserRaised: interventionBrowserRaised))
                BrowserDockView(web: web, engine: engine, chatInputFocus: $chatInputFocused,
                                bottomReserve: dockBottomReserve, expandRequest: dockExpandRequest, dock: web.dockState,
                                onReturnToExecution: { returnToExecution() })
                    .zIndex(InterventionZOrder.dock(browserRaised: interventionBrowserRaised))
                if showsInterventionPrompt {
                    // 变暗遮罩（UI-LEGIBILITY，2026-11-03）：介入卡出现时整屏
                    // 压暗对话层与浏览器坞，卡面成为唯一可读层，背景文字不再
                    // 透叠。遮罩不拦截触摸（参数 OverlayStyle.scrimAllowsHitTesting
                    // ＝false），用户照常亲手点网页弹窗与坞控件，触摸路径不变。
                    // 置顶态下本遮罩的名次退到坞之下（InterventionZOrder），
                    // 不再覆盖浏览器窗口——只剩对话层被压暗。
                    Color.black.opacity(OverlayStyle.scrimOpacity)
                        .ignoresSafeArea()
                        .allowsHitTesting(OverlayStyle.scrimAllowsHitTesting)
                        .zIndex(InterventionZOrder.scrim(browserRaised: interventionBrowserRaised))
                    InterventionPrompt(engine: engine, web: web,
                                       onOpenBrowser: { dockExpandRequest += 1; interventionBrowserRaised = true },
                                       compact: InterventionZOrder.cardCompact(browserRaised: interventionBrowserRaised),
                                       onShowFull: { interventionBrowserRaised = false })
                        .padding(.horizontal, 12)
                        .padding(.bottom, inputBarHeight + 6)
                        .zIndex(InterventionZOrder.card(browserRaised: interventionBrowserRaised))
                }
                if !web.dockState.fullScreen {
                    ChatInputBar(engine: engine, conversation: conversation, dock: web.dockState,
                                 inputFocus: $chatInputFocused, followLatest: $followLatest,
                                 onSendJumpToBottom: { requestBottom() })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(InterventionZOrder.inputBar(browserRaised: interventionBrowserRaised))
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { newHeight in
                        inputBarHeight = newHeight
                    }
                }
            }
            .overlay {
                if showSessions {
                    ZStack(alignment: .leading) {
                        Color.black.opacity(0.32).ignoresSafeArea()
                            .onTapGesture { withAnimation { showSessions = false } }
                            .gesture(DragGesture().onEnded { value in
                                if DrawerDismissPolicy.shouldDismiss(translationWidth: value.translation.width) {
                                    withAnimation { showSessions = false }
                                }
                            })
                        SessionListView(engine: engine, conversation: conversation, web: web,
                                        onClose: { withAnimation { showSessions = false } },
                                        onSessionEntered: { requestBottom() },
                                        onNewSessionFocus: { chatInputFocused = true })
                            .frame(width: min(UIScreen.main.bounds.width * 0.86, 360))
                            .background(.regularMaterial)
                            .transition(.move(edge: .leading))
                    }
                    .zIndex(10)
                }
            }
            .navigationTitle(currentSessionTitle).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { withAnimation { showSessions = true } } label: { Image(systemName: "line.3.horizontal") }.accessibilityLabel("打开会话列表")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showAttachments = true } label: { Text("附件") }
                    NavigationLink { SelfTestView(engine: engine, settings: settings, conversation: conversation) } label: { Text("自检") }
                    NavigationLink { SettingsView(settings: settings, diagnostics: diagnostics) } label: { Image(systemName: "gearshape") }.accessibilityLabel("设置")
                }
            }
            .sheet(isPresented: $showAttachments) {
                AttachmentsView(web: web)
            }
        }
        .onAppear { consumePending() }
        .onAppear { requestBottom() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { requestBottom() } }
        .onChange(of: pending.task) { _, _ in consumePending() }
        .onChange(of: showsInterventionPrompt) { _, shown in
            // 介入解除（已处理／已确认／已解决，含切走会话时卡片隐去）→
            // 浏览器置顶呈现自动复位，层级回到常态（ZORDER-FIX 规格 2）。
            if !shown { interventionBrowserRaised = false }
        }
    }
    private var currentSessionTitle: String {
        sessionStore.meta(for: conversation.displayedSessionID)?.title ?? "新对话"
    }
    private func requestBottom() {
        followLatest = true
        scrollToBottomRequest += 1
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
        requestBottom()
        web.revealExecutionTab()
        dockExpandRequest += 1
    }
}

/// 根层级表（ZORDER-FIX，纯函数：ContentView 的 ZStack 实际使用、自检
/// 十九断言同一份数值）。自下而上的名次以 zIndex 表达：
/// - 常态（browserRaised=false，与 UI-LEGIBILITY 定版一致）：对话 0
///   ＜ 坞 1 ＜ 遮罩 2 ＜ 介入卡 3 ＜ 输入栏 4——介入卡出现时遮罩压暗
///   坞与对话、卡面唯一可读、输入栏永远最上层；
/// - 置顶态（用户在介入卡上点了「打开浏览器*」）：只交换坞与遮罩的
///   名次——对话 0 ＜ 遮罩 1 ＜ 坞 2 ＜ 介入卡（小条）3 ＜ 输入栏 4：
///   遮罩退到坞之下、不再覆盖浏览器窗口，网页完整可看可亲手点；卡
///   收成小条仍居坞之上，解决按钮（已处理，继续／确认执行／已选好，
///   继续核验等）与回全卡的「说明」都可达；卡与输入栏名次不变。
/// 介入解除后 ContentView 复位 browserRaised，名次自动回到常态。
enum InterventionZOrder {
    static func chat(browserRaised: Bool) -> Double { 0 }
    static func scrim(browserRaised: Bool) -> Double { browserRaised ? 1 : 2 }
    static func dock(browserRaised: Bool) -> Double { browserRaised ? 2 : 1 }
    static func card(browserRaised: Bool) -> Double { 3 }
    static func inputBar(browserRaised: Bool) -> Double { 4 }
    /// 介入卡是否收成小条：与置顶态同进退（置顶即收条让出网页操作
    /// 区、复位即回全卡），ContentView 据此下传 InterventionPrompt。
    static func cardCompact(browserRaised: Bool) -> Bool { browserRaised }
}
