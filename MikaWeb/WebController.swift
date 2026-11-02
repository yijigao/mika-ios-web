import SwiftUI
import WebKit
import Combine

extension Notification.Name {
    /// 页面发起通行密钥（WebAuthn）请求且被平台拒绝时，由 BrowserTab 发出、
    /// AgentConversationStore 订阅并在对话区给人话降级提示（DOCK-NAV-PASSKEY-FIX）。
    static let mikaWebAuthnBlocked = Notification.Name("MikaWeb.WebAuthnBlocked")
}

/// 通行密钥探针的多路复用器（CRASH-1031-FIX）：全局唯一的消息处理器，按
/// WKScriptMessage.webView 把消息路由回所属标签页处理。
///
/// 为什么必须复用（1031 崩溃机制）：WKUIDelegate createWebViewWith 收到的
/// 配置是发起页配置的副本、与发起页**共享同一个 WKUserContentController**
/// （脚本消息处理器在新窗口里继续工作正是靠这一点）。旧实现对每个标签页都
/// 向其配置的 controller 注册同名 handler——在共享 controller 上重复
/// `add(_:contentWorld:name:)` 同一名字会抛 NSInvalidArgumentException，
/// 且该调用发生在 WebKit 的 UI 委托回调里，ObjC 异常无处可捕获、直接
/// abort（1031 真机：知乎点「写文章」以新窗口打开编辑器时崩溃，SIGABRT）。
/// 故：每个 controller 只装配一次（装配表弱持有、含 remove 同名旧注册的
/// 双保险），处理器恒为本复用器单例；标签页与 webView 的对应关系在标签页
/// 创建后登记（弱引用，条目在每次路由时顺手清理已释放者）。
@MainActor private final class WebAuthnProbeMultiplexer: NSObject, WKScriptMessageHandler {
    static let shared = WebAuthnProbeMultiplexer()
    private var equippedControllers = NSHashTable<WKUserContentController>.weakObjects()
    private var tabsByWebView: [ObjectIdentifier: WeakTabBox] = [:]
    private final class WeakTabBox {
        weak var tab: BrowserTab?
        init(_ tab: BrowserTab) { self.tab = tab }
    }

    /// 给配置装探针：同一 controller 只装一次（脚本同理只注入一次；
    /// 探针脚本自身另有页面级防重入标记，属第三重保险）。
    func equip(_ controller: WKUserContentController) {
        guard !equippedControllers.contains(controller) else { return }
        controller.removeScriptMessageHandler(forName: BrowserTab.webAuthnHandlerName, contentWorld: .page)
        controller.add(self, contentWorld: .page, name: BrowserTab.webAuthnHandlerName)
        controller.addUserScript(WKUserScript(source: BrowserTab.webAuthnProbeScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        equippedControllers.add(controller)
    }

    func associate(tab: BrowserTab) {
        tabsByWebView[ObjectIdentifier(tab.webView)] = WeakTabBox(tab)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        tabsByWebView = tabsByWebView.filter { $0.value.tab != nil }
        if let webView = message.webView, let tab = tabsByWebView[ObjectIdentifier(webView)]?.tab {
            tab.userContentController(userContentController, didReceive: message)
        } else {
            BrowserTab.handleUnroutedWebAuthnMessage(message)
        }
    }
}

/// 站点模式（RESOURCEFULNESS）：标签页的 UA 形态。desktop＝iPhone 上一直
/// 沿用的桌面 UA（立项口径，默认不变）；mobile＝iPhone Safari UA。agent 的
/// set_site_mode 动作与用户手动需求都经它切换——不少站点按 UA 分发完全不同
/// 的页面（活动页只给移动版、后台只给电脑版），换模式是「受阻换路」的一条路。
enum SiteMode: String {
    case desktop, mobile
    var userAgent: String {
        switch self {
        case .desktop: return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        case .mobile: return "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        }
    }
    var label: String { self == .desktop ? "电脑版（desktop）" : "手机版（mobile）" }
}

// 标签页会话（2026-11-02，案卷 TABS-IMPL-2026-11-02.md）：一个标签页＝一个独立 WKWebView
// ＋独立历史／标题／加载状态。切换标签只是把当前页的 WKWebView 换入视图层级，离屏标签的
// 实例与页面状态由本对象强持有保留、不重载；网页进程被系统内存压力杀掉时，按最后已知
// 地址重载恢复该页（系统行为，见 webViewWebContentProcessDidTerminate）。
@MainActor final class BrowserTab: NSObject, ObservableObject, WKNavigationDelegate, Identifiable {
    let id = UUID()
    /// 所属会话（M1，2026-11-02）：标签归属会话——切会话只换可见标签集合，
    /// 其余会话的标签保留在管理器里隐藏、不销毁、不重载。创建时由
    /// WebController 按语境指定（查看会话／执行会话／opener 所在会话）。
    var sessionID: UUID
    /// 置顶（M1）：纯元数据——在标签列表里排前、关闭被守卫拒绝（见
    /// WebController.closeTab，含任何批量关闭路径，须先取消置顶才能关）。
    /// 不承诺网页进程永驻：进程被系统回收时按最后已知地址重载恢复
    /// （webViewWebContentProcessDidTerminate 既有路径）。
    @Published var isPinned = false
    let webView: WKWebView
    @Published private(set) var urlString = ""
    @Published private(set) var title = ""
    @Published private(set) var estimatedProgress = 0.0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published var pageError: String?
    private(set) var revision = 0
    private var observations: [NSKeyValueObservation] = []
    /// 网页进程终止时 webView.url 可能已被清空，重载恢复以此为准
    private var lastKnownURL: URL?

    /// configuration 非空时用于承接 window.open／target=_blank 的新窗口（须用 WebKit 给的
    /// 配置原样建 WKWebView，opener 关系由 WebKit 经该配置维系）；此时不加载起始页，
    /// 弹窗请求由 WebKit 自行载入。
    init(configuration: WKWebViewConfiguration? = nil, loadStartPage: Bool = true, sessionID: UUID = SessionStore.shared.currentSessionID) {
        self.sessionID = sessionID
        let config = configuration ?? Self.makeConfiguration()
        // 探针装配走复用器：window.open 所给的配置与发起页共享同一
        // WKUserContentController，逐标签重复注册同名 handler 会抛
        // NSInvalidArgumentException 致 abort（CRASH-1031），复用器保证
        // 每个 controller 只装一次、消息按 webView 路由回所属标签页。
        WebAuthnProbeMultiplexer.shared.equip(config.userContentController)
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        WebAuthnProbeMultiplexer.shared.associate(tab: self)
        webView.customUserAgent = SiteMode.desktop.userAgent
        webView.navigationDelegate = self
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.update() } },
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.update() } },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.update() } },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.update() } },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.update() } },
        ]
        if loadStartPage {
            webView.loadHTMLString("<!doctype html><html lang='zh-CN'><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Mika Web</title><body><h1>Mika Web</h1><p>在地址栏打开网页，或输入包含网址的任务。</p></body></html>", baseURL: nil)
        }
    }

    private static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        return config
    }

    // MARK: - 通行密钥（WebAuthn）探针与降级（DOCK-NAV-PASSKEY-FIX-2026-11-02）
    //
    // 平台事实（Apple entitlement 文档＋WebKit 行为，多源互证，详见案卷）：WebKit 会
    // 自动处理 WKWebView 里的 WebAuthn，但宿主 App 只有持有受管 entitlement
    // com.apple.developer.web-browser.public-key-credential（须组织账号 Account
    // Holder 向 Apple 申请、审核后以 managed capability 下发并写进描述文件）时，
    // 才能为**任意** relying party 弹出系统通行密钥确认框；没有它，内嵌 WKWebView
    // 只能用 App 自己关联域名的通行密钥，第三方站点（如 x.com）的请求会被平台
    // 直接拒绝（NotAllowedError、不呈现任何 UI）——与 Joey 在 X 登录页点通行密钥
    // 「没有弹窗」的真机症状一致。本 App 不持有该 entitlement（申请是账号层动作，
    // 不在本轮范围，路径与门槛记在案卷），故本轮落优雅降级：注入脚本只观察
    // navigator.credentials 的 get／create 调用（原样透传调用与返回值、不改页面
    // 语义、不碰任何凭据材料），被拒且非 conditional（自动填充）时通知对话区给
    // 人话提示；全部尝试（含成功与 conditional）记 DiagnosticStore 同格式信封。

    static let webAuthnHandlerName = "mikaWebAuthn"

    static let webAuthnProbeScript = """
    (function(){
      if (window.__mikaWebAuthnProbe) return;
      window.__mikaWebAuthnProbe = true;
      var post = function(payload){ try { window.webkit.messageHandlers.mikaWebAuthn.postMessage(payload); } catch (e) {} };
      var creds = null;
      try { creds = navigator.credentials; } catch (e) { creds = null; }
      if (!creds) return;
      var wrap = function(kind){
        var orig = creds[kind];
        if (typeof orig !== 'function') return;
        creds[kind] = function(options){
          var conditional = false; var rp = '';
          try {
            conditional = !!(options && options.mediation === 'conditional');
            var pk = options && options.publicKey;
            if (pk) { rp = pk.rpId || (pk.rp && pk.rp.id) || ''; }
          } catch (e) {}
          var base = { kind: kind, rp: rp, conditional: conditional, href: '' };
          try { base.href = location.href; } catch (e) {}
          var p;
          try { p = orig.call(creds, options); }
          catch (err) {
            var t = { kind: base.kind, rp: base.rp, conditional: base.conditional, href: base.href, event: 'throw', error: (err && err.name) || 'Error' };
            post(t); throw err;
          }
          if (p && typeof p.then === 'function') {
            p.then(function(){ post({ kind: base.kind, rp: base.rp, conditional: base.conditional, href: base.href, event: 'resolved' }); },
                   function(err){ post({ kind: base.kind, rp: base.rp, conditional: base.conditional, href: base.href, event: 'rejected', error: (err && err.name) || 'Error' }); });
          }
          return p;
        };
      };
      wrap('get'); wrap('create');
    })();
    """

    /// 探针消息处理（由 WebAuthnProbeMultiplexer 按 webView 路由调用）：
    /// 全量记诊断；仅「模态调用被拒／同步抛错」才通知对话区提示
    /// （conditional 自动填充调用失败是常态静默路径，不打扰用户）。
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.webAuthnHandlerName, let body = message.body as? [String: Any] else { return }
        Self.processWebAuthnBody(body, fallbackHost: webView.url?.host)
    }

    /// 路由不到所属标签页的探针消息（标签页已关闭等极少数情形）：仍按
    /// 消息自带的 href 记诊断并发通知，不因路由缺失丢掉降级提示。
    static func handleUnroutedWebAuthnMessage(_ message: WKScriptMessage) {
        guard message.name == webAuthnHandlerName, let body = message.body as? [String: Any] else { return }
        processWebAuthnBody(body, fallbackHost: nil)
    }

    private static func processWebAuthnBody(_ body: [String: Any], fallbackHost: String?) {
        let event = body["event"] as? String ?? ""
        let kind = body["kind"] as? String ?? ""
        let rp = body["rp"] as? String ?? ""
        let conditional = body["conditional"] as? Bool ?? false
        let errorName = body["error"] as? String ?? ""
        let href = body["href"] as? String ?? ""
        let host = URL(string: href)?.host ?? fallbackHost ?? rp
        recordWebAuthnDiagnostic(event: event, kind: kind, rp: rp, host: host, conditional: conditional, errorName: errorName, href: href)
        guard event == "rejected" || event == "throw", !conditional else { return }
        NotificationCenter.default.post(name: .mikaWebAuthnBlocked, object: nil, userInfo: ["host": host, "kind": kind])
    }

    /// 诊断留痕：与 captureFailureSnapshot 同目录、同信封格式（诊断页可见）；
    /// 只记事件／站点／错误名等元数据——凭据材料既拿不到也不记录。
    private static func recordWebAuthnDiagnostic(event: String, kind: String, rp: String, host: String, conditional: Bool, errorName: String, href: String) {
        let payload: [String: Any] = ["kind": "webauthn-attempt", "event": event, "api": kind, "rp": rp, "host": host, "conditional": conditional, "error": errorName, "url": href]
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MikaWeb/Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID(), now = Date(), formatter = ISO8601DateFormatter()
        let envelope: [String: Any] = ["schemaVersion": 1, "id": id.uuidString, "receivedAt": formatter.string(from: now), "types": ["通行密钥尝试"], "payload": payload]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]) else { return }
        let name = formatter.string(from: now).replacingOccurrences(of: ":", with: "-") + "-" + id.uuidString + ".json"
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private func update() {
        urlString = webView.url?.absoluteString ?? ""
        title = webView.title ?? ""
        estimatedProgress = webView.estimatedProgress
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        if let url = webView.url { lastKnownURL = url }
    }

    static func validatedURL(_ value: String) throws -> URL {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value.contains("://") ? value : "https://" + value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw MikaError("请输入有效 http/https 地址") }
        return url
    }

    func load(_ value: String) throws {
        let url = try Self.validatedURL(value)
        pageError = nil; webView.load(URLRequest(url: url))
    }
    func loadLocal(_ name: String) throws {
        guard let url = Bundle.main.url(forResource: name, withExtension: "html") else { throw MikaError("缺少测试页 \(name)") }
        pageError = nil; webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
    /// 会话恢复待载入地址（RESUME-CONTEXT-FIX）：重建非当前标签时先只记下地址，
    /// 用户切到该标签时才真正载入（由 WebController.activateTab 消费），避免恢复
    /// 一次把所有标签页全量加载一遍。
    var pendingRestoreURL: URL?
    /// 按快照里存下的地址重新载入本页（中断恢复专用，地址来自 App 自己写下的
    /// 会话快照、不是用户输入，不走 validatedURL 的 http/https 输入校验）：
    /// file URL 须走 loadFileURL 并给同目录读权限（本地自检页同此路径），
    /// http/https 走普通请求。页面自身的 JS／表单状态不跨进程保留，只有地址。
    func restoreLoad(_ url: URL) {
        pageError = nil
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }
    func reload() { webView.reload() }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    /// 本标签页当前站点模式（默认 desktop，逐标签独立——一个标签切了手机版
    /// 不影响其他标签）。
    private(set) var siteMode: SiteMode = .desktop
    /// 切换站点模式：UA 只在发出请求时生效，必须重载当前页才换版式；已在
    /// 目标模式时不重载、返回 false（引擎步流据实记「已是该模式」）。
    /// 起始页（本地 HTML、无 URL）只改 UA 不重载——没有可重载的请求，
    /// 后续第一次真实导航自然带上新 UA。
    @discardableResult
    func setSiteMode(_ mode: SiteMode) -> Bool {
        guard mode != siteMode else { return false }
        siteMode = mode
        webView.customUserAgent = mode.userAgent
        if webView.url != nil { webView.reload() }
        return true
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { revision += 1; pageError = nil; update() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        update()
        // Cookie 备份／回注（ADOPTION-TOP3 第 1 条）：真实导航完成即记访问（老化
        // 时钟）并节流同步一次——用户手动建立的登录态及时入备份，ITP 静默清除
        // 后的回注也借导航时机发生，不必等 agent 任务才恢复。
        CookieBackup.shared.noteVisit(url: webView.url)
        Task { @MainActor in await CookieBackup.shared.syncIfNeeded(store: WKWebsiteDataStore.default().httpCookieStore) }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { pageError = error.localizedDescription; update() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { pageError = error.localizedDescription; update() }
    /// 系统在内存压力下杀掉网页进程时，该标签页内容已丢失——按最后已知地址重载恢复
    ///（该页的 JS／表单状态无法保留，属系统行为；其余标签不受影响）。
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let url = webView.url ?? lastKnownURL { webView.load(URLRequest(url: url)) }
    }
}

// 浏览器标签管理器＋当前页门面（标签页改造前的 WebController API 逐个保留、语义改为
// 「作用于当前标签页」，既有调用点 BrowserView／BrowserDockView／AgentEngine 不需改签名）：
// address／progress／canGoBack／canGoForward／pageError／revision／webView／load／reload／
// goBack／goForward／evaluate 均为当前页门面；state／execute 则路由到「执行页」——任务开始
// 时由 AgentEngine 捕获的标签页（executionTabID），用户中途手动切页不影响正在跑的任务。
@MainActor final class WebController: NSObject, ObservableObject, WKUIDelegate {
    @Published private(set) var tabs: [BrowserTab]
    @Published private(set) var activeTabID: UUID
    /// 浏览器坞的几何／形态状态（CRASH-1031 追加项）：坞的 mode／小窗位置／
    /// 布局缩放／布局所有权放在本对象（App 级、随 WebController 同寿命）持有，
    /// 不放 BrowserDockView 的 @State——设置页等导航往返会重建视图层级、
    /// @State 随之清零，onAppear 的冷启动恢复路径再按默认值重导布局，真机
    /// 实证为从设置返回后坞被还原成贴右侧的大面板。定义见 BrowserDockView.swift。
    let dockState = DockStateStore()
    /// 任务绑定的标签页；nil＝没有任务绑定（state／execute 回落到当前页）
    @Published private(set) var executionTabID: UUID?
    /// 正在查看的会话（M1）：当前页与标签列表只呈现本会话的标签集合。
    /// 与引擎的 runSessionID（任务所属会话）相互独立——任务可在别的会话的
    /// 标签上继续执行（执行页本就不必在视图层级里，既有「执行页≠当前页」
    /// 形态的自然延伸）；切换查看会话不打断执行（见 showSessionTabs）。
    @Published private(set) var displayedSessionID: UUID
    /// 执行任务所属会话（M1）：由 AgentEngine 经 beginExecution(sessionID:)
    /// 同步；open_new_tab 等执行通道新建的标签归属它而非查看会话。
    private(set) var executionSessionID: UUID?
    /// 每会话离开时的活跃标签（内存态）：切回该会话时恢复到那一页。
    /// 标签现场本身不跨进程持久（跨进程靠引擎快照的地址现场重建），
    /// 本表同寿命即可。
    private var lastActiveTabBySession: [UUID: UUID] = [:]
    /// agent 工作驻停标记（BACKGROUND-RESILIENCE，由 AgentEngine 在切后台时置位）：
    /// 置位期间 agent 通道的加载等待与 DOM 静默轮询立即收敛停手——不再向正在被
    /// 系统挂起的网页进程发探针（0808 的 scene-update 看门狗终止教训：进后台的
    /// 场景事务窗口里，主线与网页侧的工作都要第一时间安静下来）。用户手动浏览
    /// 不走 ready／state 通道，不受此标记影响。
    var agentWorkSuspended = false
    private var tabCancellables: [UUID: AnyCancellable] = [:]

    override init() {
        let initialSession = SessionStore.shared.currentSessionID
        let first = BrowserTab(sessionID: initialSession)
        tabs = [first]
        activeTabID = first.id
        executionTabID = nil
        displayedSessionID = initialSession
        super.init()
        adopt(first)
    }

    private func adopt(_ tab: BrowserTab) {
        tab.webView.uiDelegate = self
        tabCancellables[tab.id] = tab.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
    }

    var activeTab: BrowserTab { tabs.first(where: { $0.id == activeTabID }) ?? visibleTabs.first ?? tabs[0] }

    /// 查看会话的标签集合（M1）：置顶在前、其余按创建顺序——标签列表、
    /// 标签计数与总览都以它为准；其余会话的标签只存在于 tabs 全集里。
    var visibleTabs: [BrowserTab] {
        let mine = tabs.filter { $0.sessionID == displayedSessionID }
        return mine.filter { $0.isPinned } + mine.filter { !$0.isPinned }
    }
    /// 某会话的全部标签（创建顺序，含置顶）。
    func tabs(for sessionID: UUID) -> [BrowserTab] { tabs.filter { $0.sessionID == sessionID } }
    var executionTab: BrowserTab { executionTabID.flatMap { id in tabs.first(where: { $0.id == id }) } ?? activeTab }
    func tabTitle(for id: UUID) -> String {
        guard let tab = tabs.first(where: { $0.id == id }) else { return "新标签页" }
        if !tab.title.isEmpty { return tab.title }
        return tab.urlString.isEmpty ? "新标签页" : tab.urlString
    }

    // MARK: - 当前页门面（语义与标签页改造前的单页 WebController 一致）

    var webView: WKWebView { activeTab.webView }
    var address: String { activeTab.urlString }
    var progress: Double { activeTab.estimatedProgress }
    var canGoBack: Bool { activeTab.canGoBack }
    var canGoForward: Bool { activeTab.canGoForward }
    var pageError: String? {
        get { activeTab.pageError }
        set { activeTab.pageError = newValue }
    }
    /// 当前页的导航修订号（BrowserDockView 的滚动恢复判定用）
    var revision: Int { activeTab.revision }
    /// 执行页的导航修订号（AgentEngine 的目标一致性判定用；用户切页不影响）
    var executionRevision: Int { executionTab.revision }

    func load(_ value: String) throws { try activeTab.load(value) }
    func loadLocal(_ name: String) throws { try activeTab.loadLocal(name) }
    func reload() { activeTab.reload() }
    func goBack() { activeTab.goBack() }
    func goForward() { activeTab.goForward() }

    // MARK: - 标签管理

    /// 新建标签并切换过去（归属查看会话）；urlString 非空时在新页打开该地址。
    @discardableResult
    func newTab(urlString: String? = nil) -> BrowserTab {
        let tab = BrowserTab(sessionID: displayedSessionID)
        tabs.append(tab)
        adopt(tab)
        activeTabID = tab.id
        lastActiveTabBySession[displayedSessionID] = tab.id
        if let urlString, !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? tab.load(urlString)
        }
        return tab
    }

    func activateTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id && $0.sessionID == displayedSessionID }) else { return }
        activeTabID = id
        lastActiveTabBySession[displayedSessionID] = id
        // 会话恢复时延迟载入的标签：用户第一次切到它时才真正打开原地址
        if let pending = tab.pendingRestoreURL {
            tab.pendingRestoreURL = nil
            tab.restoreLoad(pending)
        }
    }

    /// 切换查看会话（M1）：只换可见标签集合——目标会话一张标签都没有时
    /// （新建会话）补一张该会话的起始页；活动页恢复到该会话离开时的那张。
    /// 其余会话的标签对象、页面状态与执行绑定一概不动：不销毁、不重载、
    /// 不改执行页（任务在自己会话的标签上继续跑）。
    func showSessionTabs(_ sessionID: UUID) {
        if sessionID != displayedSessionID {
            lastActiveTabBySession[displayedSessionID] = activeTabID
            displayedSessionID = sessionID
        }
        var mine = tabs.filter { $0.sessionID == sessionID }
        if mine.isEmpty {
            let fresh = BrowserTab(sessionID: sessionID)
            tabs.append(fresh)
            adopt(fresh)
            mine = [fresh]
        }
        let target = lastActiveTabBySession[sessionID].flatMap { id in mine.first(where: { $0.id == id }) } ?? mine[0]
        activeTabID = target.id
        lastActiveTabBySession[sessionID] = target.id
        if let pending = target.pendingRestoreURL {
            target.pendingRestoreURL = nil
            target.restoreLoad(pending)
        }
    }

    /// 标签置顶开关（M1）：置顶即时生效于列表排序（置顶在前）与关闭守卫；
    /// 它只是元数据，不改变标签的加载与保活行为。
    func setTabPinned(_ id: UUID, _ pinned: Bool) {
        tabs.first(where: { $0.id == id })?.isPinned = pinned
    }

    /// 「返回执行页」（M1，坞上入口）：把可见标签集合切到执行会话、并让
    /// 执行标签成为当前页。只动查看侧——执行绑定与任务本身不受影响；
    /// 会话指针与对话换源由调用方（ContentView）在此之前完成。
    func revealExecutionTab() {
        guard let execID = executionTabID,
              let owner = tabs.first(where: { $0.id == execID })?.sessionID else { return }
        showSessionTabs(owner)
        activeTabID = execID
        lastActiveTabBySession[owner] = execID
        if let pending = executionTab.pendingRestoreURL {
            executionTab.pendingRestoreURL = nil
            executionTab.restoreLoad(pending)
        }
    }

    /// 删除会话时回收其全部标签（M1）：标签对象逐个销毁。调用前提由
    /// 编排方保证：该会话不是执行会话（运行中会话禁删，其标签是任务
    /// 现场）、也不是查看会话（删查看会话先切换，见 SessionListView）。
    func discardTabs(for sessionID: UUID) {
        for tab in tabs where tab.sessionID == sessionID { teardown(tab) }
        tabs.removeAll { $0.sessionID == sessionID }
        lastActiveTabBySession[sessionID] = nil
        if let bound = executionTabID, tabs.first(where: { $0.id == bound }) == nil { executionTabID = nil }
        if executionSessionID == sessionID { executionSessionID = nil }
    }

    // MARK: - 会话现场快照与恢复（RESUME-CONTEXT-FIX）

    /// 某会话的标签页地址现场（供 AgentEngine 的会话快照落盘，M1 起按会话
    /// 取）：该会话每页的当前地址（起始页为空串）、该会话活跃页下标、执行
    /// 页下标（执行页不在该会话时为 nil）、置顶标记（与地址同序）。其余
    /// 会话的标签不进现场、也不被恢复波及。
    func tabScene(for sessionID: UUID) -> (urls: [String], activeIndex: Int, executionIndex: Int?, pinned: [Bool]) {
        let mine = tabs.filter { $0.sessionID == sessionID }
        guard !mine.isEmpty else { return ([], 0, nil, []) }
        let lastActive = lastActiveTabBySession[sessionID] ?? (sessionID == displayedSessionID ? activeTabID : mine[0].id)
        return (mine.map { $0.urlString },
                mine.firstIndex(where: { $0.id == lastActive }) ?? 0,
                executionTabID.flatMap { id in mine.firstIndex(where: { $0.id == id }) },
                mine.map { $0.isPinned })
    }

    /// 某会话的标签现场是否「全新未动过」：冷启动后该会话还没打开过任何
    /// 网页（只有起始页）。恢复该会话时只有现场全新才整组重建——用户重启
    /// 后已在该会话里手动浏览过的话，不拿快照覆盖他的手动现场（引擎改走
    /// 「提示模型原地址、自行导航」口径）。
    func tabsArePristine(for sessionID: UUID) -> Bool {
        tabs.filter { $0.sessionID == sessionID }.allSatisfy { $0.urlString.isEmpty && $0.pendingRestoreURL == nil }
    }

    private func teardown(_ tab: BrowserTab) {
        tabCancellables[tab.id]?.cancel()
        tabCancellables[tab.id] = nil
        tab.webView.stopLoading()
        tab.webView.navigationDelegate = nil
        tab.webView.uiDelegate = nil
    }

    /// 按快照重建某会话的标签现场：只拆建该会话的标签（调用方须先以
    /// tabsArePristine(for:) 把关；其余会话的标签原样保留），逐页按原地址
    /// 建回——该会话的活跃页与执行页立即载入，其余页只记地址、切到时再
    /// 载入；空地址页就是起始页；置顶按现场的元数据还原。执行绑定按
    /// executionIndex 恢复（指向已拆除标签的旧绑定一并清掉）。
    func rebuildTabs(urls: [String], activeIndex: Int, executionIndex: Int?, pinned: [Bool] = [], owner sessionID: UUID) {
        for tab in tabs where tab.sessionID == sessionID { teardown(tab) }
        tabs.removeAll { $0.sessionID == sessionID }
        let source = urls.isEmpty ? [""] : urls
        var created: [BrowserTab] = []
        for (offset, raw) in source.enumerated() {
            let url = raw.isEmpty ? nil : URL(string: raw)
            let tab = BrowserTab(loadStartPage: url == nil, sessionID: sessionID)
            if pinned.indices.contains(offset), pinned[offset] { tab.isPinned = true }
            created.append(tab)
            adopt(tab)
            if let url {
                if offset == activeIndex || offset == executionIndex {
                    tab.restoreLoad(url)
                } else {
                    tab.pendingRestoreURL = url
                }
            }
        }
        tabs.append(contentsOf: created)
        let clampedActive = min(max(activeIndex, 0), created.count - 1)
        lastActiveTabBySession[sessionID] = created[clampedActive].id
        if sessionID == displayedSessionID { activeTabID = created[clampedActive].id }
        if let executionIndex, created.indices.contains(executionIndex) {
            executionTabID = created[executionIndex].id
        } else if let bound = executionTabID, tabs.first(where: { $0.id == bound }) == nil {
            executionTabID = nil
        }
    }

    /// 某会话回到单页起始页（仅自检四模拟进程中断时用：把该会话的标签
    /// 现场打回冷启动原样，证明恢复只靠落盘快照、不靠内存里残留的标签对象）。
    func resetTabsToStartPage(sessionID: UUID) {
        for tab in tabs where tab.sessionID == sessionID { teardown(tab) }
        tabs.removeAll { $0.sessionID == sessionID }
        if let bound = executionTabID, tabs.first(where: { $0.id == bound }) == nil { executionTabID = nil }
        let fresh = BrowserTab(sessionID: sessionID)
        tabs.append(fresh)
        adopt(fresh)
        lastActiveTabBySession[sessionID] = fresh.id
        if sessionID == displayedSessionID { activeTabID = fresh.id }
    }

    /// 关闭标签：关当前页切到同会话的相邻页（优先右侧、其次左侧）；关掉某会话
    /// 的最后一个标签时自动补一个该会话的空白标签（每会话永不归零）。关掉的
    /// 若是任务执行页，执行绑定随之解除，任务的后续 state／execute 回落到当前
    /// 页（其目标校验会拦下不一致的已确认动作，见案卷）。
    /// M1 守卫：置顶标签在此直接拒绝关闭——置顶是「保留入口」的承诺，任何
    /// 关闭路径（逐个关／批量关）都要先取消置顶；页面脚本的 window.close 走
    /// webViewDidClose 同一条路，同样受守卫。
    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = tabs[index]
        guard !closing.isPinned else { return }
        let owner = closing.sessionID
        let siblingsBefore = tabs.filter { $0.sessionID == owner }
        let siblingIndex = siblingsBefore.firstIndex(where: { $0.id == id }) ?? 0
        let wasActive = id == activeTabID
        tabs.remove(at: index)
        tabCancellables[id]?.cancel()
        tabCancellables[id] = nil
        closing.webView.stopLoading()
        closing.webView.navigationDelegate = nil
        closing.webView.uiDelegate = nil
        if executionTabID == id { executionTabID = nil }
        let siblings = tabs.filter { $0.sessionID == owner }
        if siblings.isEmpty {
            let fresh = BrowserTab(sessionID: owner)
            tabs.append(fresh)
            adopt(fresh)
            lastActiveTabBySession[owner] = fresh.id
            if owner == displayedSessionID { activeTabID = fresh.id }
        } else {
            if wasActive {
                let next = siblings[min(siblingIndex, siblings.count - 1)]
                activeTabID = next.id
                lastActiveTabBySession[owner] = next.id
            } else if lastActiveTabBySession[owner] == id {
                lastActiveTabBySession[owner] = siblings[0].id
            }
        }
    }

    // MARK: - 任务执行绑定（AgentEngine 调用）

    /// 任务开始（M1）：把执行页绑定到该会话离开时的活跃页（查看会话即其
    /// 当前页），任务全程作用于它，与用户切页/切会话解耦。该会话一张标签
    /// 都没有时先补一张起始页。查看会话的当前页不随执行绑定变化。
    func beginExecution(sessionID: UUID) {
        executionSessionID = sessionID
        var mine = tabs.filter { $0.sessionID == sessionID }
        if mine.isEmpty {
            let fresh = BrowserTab(sessionID: sessionID)
            tabs.append(fresh)
            adopt(fresh)
            mine = [fresh]
        }
        let target = lastActiveTabBySession[sessionID].flatMap { id in mine.first(where: { $0.id == id }) }
            ?? (sessionID == displayedSessionID ? activeTab : mine[0])
        executionTabID = target.id
    }
    /// 任务终结／停止：解除绑定（state／execute 回落当前页）。
    func endExecution() { executionTabID = nil; executionSessionID = nil }
    /// 执行页重载（引擎在页面瞬时失败连败时用）：作用于执行页而非当前页，用户切页不串。
    func reloadExecutionTab() { executionTab.reload() }

    // MARK: - 网页上传人在环（F1）：触发文件控件与回读已选文件
    //
    // iOS 平台事实：WKWebView 没有 macOS 的 runOpenPanel 回调；文件控件被
    // 真实点击时由 WebKit 拉起系统选择器，用户选完后文件挂在 input.files
    // 上、页面自己负责后续提交。合成 click 是否被当作可拉起选择器的手势
    // 由系统决定（部分场景不认）——所以触发只算「尝试打开」，引擎无论
    // 结果都进入等待卡：选择器没弹时用户可自己在页面上点上传按钮选文件。

    /// 触发执行页上的文件控件（按 data-mika-idx 定位，含被站点隐藏的
    /// file input）：滚入视口后点击。返回 false＝控件已不在页面上。
    func triggerFileInput(index: Int) async -> Bool {
        let tab = executionTab
        let result = try? await evaluate("""
        (()=>{const e=document.querySelector('[data-mika-idx="\(index)"]');
        if(!e||e.tagName!=='INPUT'||e.type!=='file')return 'missing';
        try{e.scrollIntoView({block:'center'});}catch(_){}
        try{e.click();}catch(_){return 'noclick';}
        return 'clicked';})()
        """, on: tab)
        return (result as? String) == "clicked"
    }

    /// 回读执行页上文件控件已持有的文件（上传核验）：只读文件名与大小
    /// 元数据，不读内容；控件不在或未选文件返回空数组。
    func probeFileInput(index: Int) async -> [String] {
        let tab = executionTab
        let result = try? await evaluate("""
        (()=>{const e=document.querySelector('[data-mika-idx="\(index)"]');
        if(!e||!e.files)return JSON.stringify([]);
        return JSON.stringify([...e.files].map(f=>f.name+'（'+f.size+' 字节）'));})()
        """, on: tab)
        guard let raw = result as? String, let data = raw.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return names
    }

    /// 某标签页的当前截图 JPEG（附件中心「保存当前页截图」用，与失败
    /// 快照同一取图口径：afterScreenUpdates=false、质量 0.5）。
    func captureTabJPEG(_ tab: BrowserTab) async -> Data? {
        await withCheckedContinuation { continuation in
            let config = WKSnapshotConfiguration()
            config.afterScreenUpdates = false
            tab.webView.takeSnapshot(with: config) { image, _ in
                continuation.resume(returning: image?.jpegData(compressionQuality: 0.5))
            }
        }
    }
    /// 在执行页加载本地测试页（M1）：loadLocal 门面作用于当前页，排队任务
    /// 在非查看会话启动时不能借道当前页，走这里按执行绑定加载。
    func loadLocalOnExecutionTab(_ name: String) throws { try executionTab.loadLocal(name) }

    /// agent 的 open_new_tab 动作：在执行会话里新开标签并把执行绑定移过去，
    /// 后续动作作用于新页；执行会话正是查看会话时同时切换过去（单会话时代
    /// 的既有行为），执行会话被隐藏时不抢用户的当前页。地址先校验后建页，
    /// 非法地址不留空标签。
    @discardableResult
    func openTabForExecution(urlString: String) throws -> BrowserTab {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = trimmed.isEmpty ? nil : try BrowserTab.validatedURL(trimmed)
        let owner = executionSessionID ?? displayedSessionID
        let tab = BrowserTab(sessionID: owner)
        tabs.append(tab)
        adopt(tab)
        if owner == displayedSessionID { activeTabID = tab.id }
        lastActiveTabBySession[owner] = tab.id
        executionTabID = tab.id
        if let url {
            tab.pageError = nil
            tab.webView.load(URLRequest(url: url))
        }
        return tab
    }

    // MARK: - WKUIDelegate：新窗口链接承接

    /// target=_blank／window.open：新开标签承接并切换过去，返回用 WebKit 所给配置建的
    /// WKWebView（opener 关系由该配置维系），不顶掉当前页、也不静默失效。
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // 新标签继承 opener 所在会话（M1）：opener 在隐藏的执行会话里时，
        // 新页同归该会话且不抢查看会话的当前页；opener 是当前页时与旧行为
        // 一致（切换过去）。
        let owner = tabs.first(where: { $0.webView === webView })?.sessionID ?? displayedSessionID
        let tab = BrowserTab(configuration: configuration, loadStartPage: false, sessionID: owner)
        tabs.append(tab)
        adopt(tab)
        lastActiveTabBySession[owner] = tab.id
        if owner == displayedSessionID { activeTabID = tab.id }
        return tab.webView
    }

    /// 网页脚本 window.close()：按同一套关闭规则关掉对应标签。
    func webViewDidClose(_ webView: WKWebView) {
        if let tab = tabs.first(where: { $0.webView === webView }) { closeTab(tab.id) }
    }

    // MARK: - agent 执行通道（路由到执行页）

    private func ready(in tab: BrowserTab) async throws {
        for _ in 0..<300 {
            try Task.checkCancellation()
            // 切后台驻停：不再陪等加载（最长 30 秒的轮询不得横跨场景切换），抛
            // 加载类瞬时错误，引擎会驻停并在回前台后整轮重试（BACKGROUND-RESILIENCE）
            if agentWorkSuspended { throw MikaError("网页加载失败：页面未就绪") }
            if let pageError = tab.pageError { throw MikaError("网页加载失败：\(pageError)") }
            if !tab.webView.isLoading { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw MikaError("网页加载超时")
    }
    /// 等页面短暂稳定再取快照（AGENT-VIEWPORT-FIX）：动作（输入／点击）常引发框架重渲染，
    /// 立刻抽取会拿到中间态快照、元素引用随即失效。短轮询页面签名（就绪态／正文文本量／
    /// 节点数／文档高度），连续两次相同即认为 DOM 已静默；上限约 1.6 秒，超时照常取快照
    /// （动画／轮播类页面永不完全静默，不为它无限等）。全程尽力而为，不抛错、不拦加载判定。
    private func waitForStability(in tab: BrowserTab) async {
        // 切后台驻停：DOM 静默轮询整体停手，不向正在被挂起的网页进程连发探针
        if agentWorkSuspended { return }
        let probe = "(()=>{const b=document.body;return [document.readyState,b?b.innerText.length:0,document.querySelectorAll('*').length,document.documentElement?document.documentElement.scrollHeight:0].join('|');})()"
        var last: String?
        for _ in 0..<8 {
            if agentWorkSuspended { return }
            let signature = (try? await evaluate(probe, on: tab)) as? String
            if let signature {
                if signature == last { return }
                last = signature
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
    /// 当前页求值（BrowserDockView 滚动比例读取／恢复用）
    func evaluate(_ script: String) async throws -> Any? { try await evaluate(script, on: activeTab) }
    private func evaluate(_ script: String, on tab: BrowserTab) async throws -> Any? { try await tab.webView.evaluateJavaScript(script) }
    func state() async throws -> PageState {
        let tab = executionTab
        if !agentWorkSuspended {
            // 取快照前先同步一次 Cookie（60 秒节流，BACKGROUND-RESILIENCE 的驻停
            // 期不做）：任务开始时若登录态已被 ITP 静默清除，先回注再让 agent 看
            // 页面，避免它对着登录墙误判（ADOPTION-TOP3 第 1 条）。
            CookieBackup.shared.noteVisit(url: tab.webView.url)
            await CookieBackup.shared.syncIfNeeded(store: WKWebsiteDataStore.default().httpCookieStore)
        }
        try await ready(in: tab)
        await waitForStability(in: tab)
        guard let json = try await evaluate(PageScript.extract, on: tab) as? String else { throw MikaError("无法抽取页面状态") }
        do { return try JSONDecoder().decode(PageState.self, from: Data(json.utf8)) }
        catch { throw MikaError("页面状态解析失败，请刷新页面后重试") }
    }
    func execute(_ action: AgentAction, expected: PageElement? = nil, approved: Bool = false) async throws {
        let tab = executionTab
        switch action.action {
        case "navigate": try tab.load(action.url)
        case "set_site_mode":
            // 站点模式切换（RESOURCEFULNESS）：换 UA＋重载执行页。模式串非法
            // 时如实抛错，不静默当作已切换。
            guard let mode = SiteMode(rawValue: action.mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
                throw MikaError("未知站点模式「\(action.mode)」，只能是 desktop 或 mobile")
            }
            tab.setSiteMode(mode)
        case "scroll":
            guard ["up", "down"].contains(action.direction) else { throw MikaError("未知滚动方向") }
            _ = try await evaluate("window.scrollBy(0, \(action.direction == "up" ? "-" : "")window.innerHeight*0.85)", on: tab)
        case "wait":
            // 按绝对截止时刻等待（BACKGROUND-RESILIENCE）：进程被系统挂起期间墙钟
            // 照走，分片睡、每片醒来按真实剩余时间重算；解冻时截止已过就直接返回，
            // 不把挂起时长再补睡一遍（不依赖进程内计时器连续运行）。
            let deadline = Date().addingTimeInterval(min(15, max(0.1, action.seconds)))
            while true {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { break }
                try await Task.sleep(for: .milliseconds(min(500, max(1, Int(remaining * 1000)))))
            }
        case "click": try await performClick(action, expected: expected, approved: approved, tab: tab)
        case "type": try await performType(action, expected: expected, approved: approved, tab: tab)
        default: throw MikaError("不可执行动作")
        }
    }

    // MARK: - FIX2 硬化：输入注入（缺陷 2 主攻）与点击等待重扫
    // 以下脚本与流程与单页时代逐字一致，仅执行目标由唯一 webView 改为传入的执行页 tab。

    /// 校验前导（与旧版单脚本同口径）：抽取快照比对 expected、安全词与敏感字段检查、取回 DOM 节点。
    /// 返回 JS 片段，执行后上下文里有 a／target／e 三个变量；校验不过直接 throw（与旧行为一致）。
    /// strict=false（编辑器多策略重试的后续策略专用）：编辑器自身的文本已被前一策略
    /// 改动，逐字段相等必然误判「元素已变化」——只核 tag／editable 身份，敏感与安全
    /// 词检查照旧不放松。
    private func guardScript(action: AgentAction, expected: PageElement, approved: Bool, strict: Bool = true) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["index": action.index, "text": action.text, "action": action.action])
        let json = String(decoding: data, as: UTF8.self)
        let expectedJSON = String(decoding: try JSONEncoder().encode(expected), as: UTF8.self)
        let keywords = String(decoding: try JSONSerialization.data(withJSONObject: SafetyPolicy.keywords), as: UTF8.self)
        let identityCheck = strict
            ? "if(!target||!Object.keys(expected).every(k=>target[k]===expected[k]))throw new Error('目标元素已变化');"
            : "if(!target||target.tag!==expected.tag||!!target.editable!==!!expected.editable)throw new Error('目标元素已变化');"
        return """
        const a=\(json),expected=\(expectedJSON);
        const page=JSON.parse(\(PageScript.extract)),target=page.elements.find(x=>x.index===a.index);
        \(identityCheck)
        if(a.action==='type'&&target.sensitive)throw new Error('敏感字段必须手动输入');
        const label=[target.text,target.placeholder,target.name,target.ariaLabel].join(' ').toLowerCase();
        if(!\(approved ? "true" : "false")&&\(keywords).some(k=>label.includes(k)))throw new Error('敏感操作未经确认');
        const e=document.querySelector('[data-mika-idx="'+a.index+'"]');
        if(!e||!e.isConnected)throw new Error('目标元素已失效');
        """
    }

    /// type 写入脚本。path=paste：粘贴事务（ZHUANLAN-FIX2）——选区锚进首/末 block
    /// 文本节点做真全选、派 selectionchange＋mouseup 促框架同步内部选区，再派
    /// ClipboardEvent('paste') 携带 DataTransfer(text/plain＋text/html)，框架的
    /// 粘贴管线以一次状态事务整段替换（Draft.js 的 replaceWithFragment）；增量
    /// 输入路径在专栏编辑器上已被真机实证全灭（字数冻结），粘贴是其唯一整段
    /// 事务入口。path=exec：聚焦＋全选后 execCommand('insertText')（走 WebKit 原生编辑管线，
    /// 框架编辑器 Draft/Slate/ProseMirror 都认这条）；path=events：按段派发完整的
    /// beforeinput→（框架未接管才）原生插入→input 事件序列（Draft.js 类编辑器靠
    /// beforeinput 的 data 把文字吃进内部状态，整段原生插入在 WKWebView 里可能只
    /// 改 DOM 不动状态——ZHIHU-COLUMN-SYNC 实证）；path=chunks：按段原生插入＋逐段
    /// input 事件；path=range：Selection/Range 直接写 DOM 再补 InputEvent（末位兜底）。
    /// 表单字段各路径同法：原生 value setter＋InputEvent（React 受控组件认 setter＋
    /// input 事件）。返回 'ok' 或 'exec-failed'。
    private func runTypeScript(action: AgentAction, expected: PageElement, approved: Bool, path: String, strict: Bool = true, tab: BrowserTab) async throws -> String {
        let prefix = try guardScript(action: action, expected: expected, approved: approved, strict: strict)
        let result = try await evaluate("""
        (()=>{\(prefix)
        e.scrollIntoView({block:'center'});e.focus();
        const text=a.text;
        const fireInput=(inputType,data)=>{let ev;try{ev=new InputEvent('input',{bubbles:true,cancelable:false,inputType:inputType,data:data});}catch(_){ev=new Event('input',{bubbles:true});}e.dispatchEvent(ev);};
        if(e.tagName==='INPUT'||e.tagName==='TEXTAREA'||e.tagName==='SELECT'){
          const p=e.tagName==='INPUT'?HTMLInputElement.prototype:e.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLSelectElement.prototype;
          const desc=Object.getOwnPropertyDescriptor(p,'value');
          if(!desc||typeof desc.set!=='function')throw new Error('该元素不支持自动填写');
          desc.set.call(e,text);
          fireInput('insertText',text);
          e.dispatchEvent(new Event('change',{bubbles:true}));
          return 'ok';
        }
        if(e.isContentEditable){
          const sel=window.getSelection();
          const selectAll=()=>{const r=document.createRange();r.selectNodeContents(e);sel.removeAllRanges();sel.addRange(r);};
          selectAll();
          if('\(path)'==='paste'){
            // 粘贴事务路径（ZHUANLAN-FIX2）：Draft 类编辑器的一切文本事务
            // 只认内部 SelectionState，而第一轮派发前内部选区从未完成同步
            // （selectionchange 派得太晚）、合成 beforeinput 又不被 React 的
            // 事件插件消费、段落断开更不是 beforeinput 事务——增量路径全灭
            // 的根因在案卷。这里先把 DOM 选区锚进首/末 block 的文本节点，
            // 派 selectionchange＋mouseup 促 editOnSelect 把内部选区同步为
            // 全选；粘贴本身走框架的 replaceWithFragment 整段替换内部选区，
            // 不经任何增量字符/段落操作。
            const host=(e.isContentEditable?e:(e.querySelector('[contenteditable="true"]')||e));
            host.focus();
            const blocks=[...host.querySelectorAll('[data-offset-key]')];
            const firstText=n=>{if(!n)return null;const w=document.createTreeWalker(n,NodeFilter.SHOW_TEXT);return w.nextNode();};
            const lastText=n=>{if(!n)return null;const w=document.createTreeWalker(n,NodeFilter.SHOW_TEXT);let c=null,l=null;while((c=w.nextNode()))l=c;return l;};
            let anchored=false;
            if(blocks.length){const ft=firstText(blocks[0]),lt=lastText(blocks[blocks.length-1]);if(ft&&lt){const r=document.createRange();r.setStart(ft,0);r.setEnd(lt,(lt.textContent||'').length);sel.removeAllRanges();sel.addRange(r);anchored=true;}}
            if(!anchored){const r=document.createRange();r.selectNodeContents(host);sel.removeAllRanges();sel.addRange(r);}
            try{document.dispatchEvent(new Event('selectionchange',{bubbles:true}));}catch(_){}
            try{host.dispatchEvent(new MouseEvent('mouseup',{bubbles:true}));}catch(_){}
            const escHtml=s=>s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
            const html=text.split('\\n').map(p=>'<p>'+escHtml(p)+'</p>').join('');
            let dt=null;try{dt=new DataTransfer();}catch(_){dt=null;}
            if(dt){try{dt.setData('text/plain',text);}catch(_){}try{dt.setData('text/html',html);}catch(_){}if(!dt.getData||!dt.getData('text/plain'))dt=null;}
            if(!dt){const store={'text/plain':text,'text/html':html};dt={types:['text/plain','text/html'],files:[],items:[],getData:t=>store[t]||'',setData:(t,v)=>{store[t]=v;}};}
            let ev=null;
            try{ev=new ClipboardEvent('paste',{bubbles:true,cancelable:true,composed:true,clipboardData:dt});if(!ev.clipboardData||!ev.clipboardData.getData||!ev.clipboardData.getData('text/plain'))ev=null;}catch(_){ev=null;}
            if(!ev){ev=new Event('paste',{bubbles:true,cancelable:true,composed:true});try{Object.defineProperty(ev,'clipboardData',{value:dt});}catch(_){try{ev.clipboardData=dt;}catch(__){}}}
            host.dispatchEvent(ev);
            return 'ok';
          }
          if('\(path)'==='exec'){
            let done=false;
            try{done=document.execCommand('insertText',false,text);}catch(_){done=false;}
            return done?'ok':'exec-failed';
          }
          if('\(path)'==='events'){
            // 事件序列路径：Draft.js 类编辑器在 beforeinput 里读 data 更新内部
            // 状态并 preventDefault——dispatchEvent 返回 false 即框架已接管，
            // 不再原生插入（防双写）；未被接管才退回原生 insertText 补这一段。
            // 框架重渲染可能换掉编辑器节点：host 失效时按 idx／首个可见编辑器
            // 重新锚定并把 caret 放回末尾。
            let host=e;
            const rehost=()=>{if(host.isConnected)return;const cand=document.querySelector('[data-mika-idx="'+a.index+'"]');if(cand&&cand.isContentEditable){host=cand;}else{const anyC=[...document.querySelectorAll('[contenteditable="true"]')].find(x=>{const r=x.getBoundingClientRect();return r.width>0&&r.height>0;});if(anyC)host=anyC;}try{const r=document.createRange();r.selectNodeContents(host);r.collapse(false);sel.removeAllRanges();sel.addRange(r);}catch(_){}}
            const fireBI=(inputType,data)=>{let ev;try{ev=new InputEvent('beforeinput',{bubbles:true,composed:true,cancelable:true,inputType:inputType,data:data});}catch(_){try{ev=new Event('beforeinput',{bubbles:true,cancelable:true});}catch(__){return true;}}return host.dispatchEvent(ev);};
            const fireIN=(inputType,data)=>{let ev;try{ev=new InputEvent('input',{bubbles:true,composed:true,cancelable:false,inputType:inputType,data:data});}catch(_){ev=new Event('input',{bubbles:true});}host.dispatchEvent(ev);};
            const paras=text.split('\\n');
            paras.forEach((p,i)=>{
              rehost();
              if(p){
                if(fireBI('insertText',p)){try{document.execCommand('insertText',false,p);}catch(_){}}
                fireIN('insertText',p);
              }
              if(i<paras.length-1){
                rehost();
                if(fireBI('insertParagraph',null)){let d=false;try{d=document.execCommand('insertParagraph');}catch(_){}if(!d){try{document.execCommand('insertText',false,'\\n');}catch(_){}}}
                fireIN('insertParagraph',null);
              }
            });
            try{document.dispatchEvent(new Event('selectionchange',{bubbles:true}));}catch(_){}
            return 'ok';
          }
          if('\(path)'==='chunks'){
            // 分段原生路径：整段一次插入对某些编辑器的状态同步太「整」，按段落
            // 逐段原生插入、每段后补带 data 的 input 事件，给框架留出逐段吃进
            // 状态的节奏；段间用 insertParagraph 分段（失败退回插入换行）。
            const paras2=text.split('\\n');
            paras2.forEach((p,i)=>{
              if(p){try{document.execCommand('insertText',false,p);}catch(_){}fireInput('insertText',p);}
              if(i<paras2.length-1){let d=false;try{d=document.execCommand('insertParagraph');}catch(_){}if(!d){try{document.execCommand('insertText',false,'\\n');}catch(_){}}fireInput('insertParagraph',null);}
            });
            return 'ok';
          }
          const range=sel.getRangeAt(0);
          range.deleteContents();
          const frag=document.createDocumentFragment();
          text.split('\\n').forEach((line,i)=>{if(i>0)frag.appendChild(document.createElement('br'));frag.appendChild(document.createTextNode(line));});
          range.insertNode(frag);
          sel.collapseToEnd();
          let bi=null;try{bi=new InputEvent('beforeinput',{bubbles:true,cancelable:true,inputType:'insertText',data:text});}catch(_){bi=null;}
          if(bi)e.dispatchEvent(bi);
          fireInput('insertText',text);
          e.dispatchEvent(new Event('change',{bubbles:true}));
          return 'ok';
        }
        throw new Error('目标不是可填写元素');})()
        """, on: tab)
        return (result as? String) ?? ""
    }

    private struct TypeVerification: Decodable {
        struct Submit: Decodable { let text: String; let disabled: Bool }
        let found: Bool
        let textOK: Bool
        let editorLike: Bool
        let submits: [Submit]
    }

    /// 写后回读校验：编辑器当前文本（归一化后须包含目标文本）、编辑器邻域内提交类按钮的存在/禁用状态。
    /// 按钮候选优先取与编辑器共享近层祖先的（回复编辑器自带的那颗），没有才退到全文档可见候选。
    private func verifyType(action: AgentAction, tab: BrowserTab) async throws -> TypeVerification {
        let data = try JSONSerialization.data(withJSONObject: ["index": action.index, "text": action.text])
        let json = String(decoding: data, as: UTF8.self)
        guard let raw = try await evaluate("""
        (()=>{const a=\(json);
        const e=document.querySelector('[data-mika-idx="'+a.index+'"]');
        if(!e||!e.isConnected)return JSON.stringify({found:false,textOK:false,editorLike:false,submits:[]});
        const norm=s=>(s||'').replace(/[\\s\\u200b\\ufeff]+/g,'');
        let cur='';
        if(e.tagName==='INPUT'||e.tagName==='TEXTAREA')cur=e.value||'';
        else cur=e.innerText||e.textContent||'';
        const textOK=norm(cur).length>0&&norm(cur).includes(norm(a.text));
        const editorLike=e.isContentEditable||e.tagName==='TEXTAREA';
        const labelRe=/发布|发表|提交|发送|评论|回复|publish|post|submit|send|comment|reply/i;
        const vis=x=>{const r=x.getBoundingClientRect(),s=getComputedStyle(x);return r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none';};
        const lab=x=>(x.innerText||x.value||x.getAttribute('aria-label')||'').trim();
        const dis=x=>x.disabled===true||x.getAttribute('aria-disabled')==='true';
        let cands=[...document.querySelectorAll('button,[role="button"],input[type="submit"],a')].filter(x=>vis(x)&&labelRe.test(lab(x)));
        const near=cands.filter(x=>{let n=e;for(let i=0;i<8&&n;i++){if(n.contains(x))return true;n=n.parentElement;}return false;});
        if(near.length)cands=near;
        return JSON.stringify({found:true,textOK,editorLike,submits:cands.slice(0,8).map(x=>({text:lab(x).slice(0,40),disabled:dis(x)}))});})()
        """, on: tab) as? String, let decoded = try? JSONDecoder().decode(TypeVerification.self, from: Data(raw.utf8)) else {
            throw MikaError("输入后回读校验失败（页面无响应）")
        }
        return decoded
    }

    /// 按内容兜底回读（verifyType 的节点被重渲染换掉时）：不认 data-mika-idx，直接在全页
    /// 可见编辑器里找正文（归一化后）包含目标文本的那个；提交按钮候选取与该编辑器共享
    /// 近层祖先的候选（同 verifyType 口径）。没有任何编辑器含目标文本时返回 found=false。
    private func verifyTypeByContent(action: AgentAction, tab: BrowserTab) async throws -> TypeVerification? {
        let data = try JSONSerialization.data(withJSONObject: ["text": action.text])
        let json = String(decoding: data, as: UTF8.self)
        guard let raw = try await evaluate("""
        (()=>{const a=\(json);
        const norm=s=>(s||'').replace(/[\\s\\u200b\\ufeff]+/g,'');
        const want=norm(a.text);
        if(!want)return JSON.stringify({found:false,textOK:false,editorLike:false,submits:[]});
        const vis=x=>{const r=x.getBoundingClientRect(),s=getComputedStyle(x);return r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none';};
        const editors=[...document.querySelectorAll('[contenteditable="true"],textarea')].filter(vis);
        const e=editors.find(x=>{const cur=x.tagName==='TEXTAREA'?(x.value||''):((x.innerText||x.textContent||''));return norm(cur).includes(want);});
        if(!e)return JSON.stringify({found:false,textOK:false,editorLike:false,submits:[]});
        const labelRe=/发布|发表|提交|发送|评论|回复|publish|post|submit|send|comment|reply/i;
        const lab=x=>(x.innerText||x.value||x.getAttribute('aria-label')||'').trim();
        const dis=x=>x.disabled===true||x.getAttribute('aria-disabled')==='true';
        let cands=[...document.querySelectorAll('button,[role="button"],input[type="submit"],a')].filter(x=>vis(x)&&labelRe.test(lab(x)));
        const near=cands.filter(x=>{let n=e;for(let i=0;i<8&&n;i++){if(n.contains(x))return true;n=n.parentElement;}return false;});
        if(near.length)cands=near;
        return JSON.stringify({found:true,textOK:true,editorLike:true,submits:cands.slice(0,8).map(x=>({text:lab(x).slice(0,40),disabled:dis(x)}))});})()
        """, on: tab) as? String, let decoded = try? JSONDecoder().decode(TypeVerification.self, from: Data(raw.utf8)) else {
            return nil
        }
        return decoded
    }

    // MARK: - 编辑器自报信号（ZHIHU-COLUMN-SYNC：写后校验升级为编辑器状态校验）

    /// 编辑器自报信号探针结果：页面可读的「字数：N」计数与保存状态文案，以及
    /// 编辑器 DOM 全文长度（次级信号）。count/saveState 为 nil 表示页面没有
    /// 这类信号（校验回落 DOM 口径，不硬判）。
    private struct EditorSignals: Decodable {
        let found: Bool
        let count: Int?
        let saveState: String?
        let textLength: Int
    }

    /// 探针：定位 contenteditable 编辑器（先按 data-mika-idx，再退首个可见编辑器），
    /// 在编辑器的祖先作用域内（由近及远）找短文案里的字数与保存状态；祖先里没有
    /// 才扫全页。编辑器自身内容不参与匹配；「保存中」优先于「已保存」（保存进行
    /// 时旧的已保存标签可能同时在场，活动状态说了算）。
    private func probeEditorSignals(action: AgentAction, tab: BrowserTab) async throws -> EditorSignals {
        let data = try JSONSerialization.data(withJSONObject: ["index": action.index])
        let json = String(decoding: data, as: UTF8.self)
        guard let raw = try await evaluate("""
        (()=>{const a=\(json);
        const vis=x=>{const r=x.getBoundingClientRect(),s=getComputedStyle(x);return r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none';};
        let ed=document.querySelector('[data-mika-idx="'+a.index+'"]');
        if(!ed||!ed.isContentEditable)ed=[...document.querySelectorAll('[contenteditable="true"]')].find(vis)||null;
        if(!ed||!ed.isContentEditable)return JSON.stringify({found:false,count:null,saveState:null,textLength:0});
        const textLength=(ed.innerText||'').length;
        const countRe=/(?:字数|words?|characters?)\\s*[:：]?\\s*(\\d{1,7})/i;
        const savingRe=/保存中|正在保存|saving/i, savedRe=/已保存|保存成功|草稿已保存|上次保存|最近保存|保存于|saved/i;
        const collect=root=>{const out=[];if(!root)return out;root.querySelectorAll('*').forEach(x=>{if(ed.contains(x)||!vis(x))return;const t=(x.innerText||'').trim();if(t&&t.length<=40)out.push(t);});return out;};
        let cands=[],scope=ed;
        for(let i=0;i<9;i++){scope=scope.parentElement;if(!scope)break;cands=cands.concat(collect(scope));if(cands.some(t=>countRe.test(t)))break;}
        if(!cands.length)cands=collect(document.body);
        let count=null;
        for(const t of cands){const m=t.match(countRe);if(m){count=parseInt(m[1],10);break;}}
        let saveState=null;
        if(cands.some(t=>savingRe.test(t)))saveState='saving';
        else if(cands.some(t=>savedRe.test(t)))saveState='saved';
        return JSON.stringify({found:true,count:count,saveState:saveState,textLength:textLength});})()
        """, on: tab) as? String, let decoded = try? JSONDecoder().decode(EditorSignals.self, from: Data(raw.utf8)) else {
            throw MikaError("编辑器状态探针失败（页面无响应）")
        }
        return decoded
    }

    /// 与 verifyType 同口径的归一化长度（去空白与零宽字符）。
    private static func normalizedLength(_ s: String) -> Int {
        s.filter { !$0.isWhitespace && $0 != "\u{200B}" && $0 != "\u{FEFF}" }.count
    }

    /// 字数一致性：写入是全选替换，落定字数应与目标文本量级一致（±15%＋余量）；
    /// 编辑器原有内容场景再给一条兜底：较基线增长了目标量级也算吃进去了。
    /// 计数与基线相同（冻结）必然不过——这正是专栏编辑器的实证形态。
    private static func countConsistent(_ count: Int, expected: Int, baseline: Int?) -> Bool {
        if expected == 0 { return true }
        let low = max(0, Int(Double(expected) * 0.85) - 5)
        let high = Int(Double(expected) * 1.15) + 10
        if count >= low && count <= high { return true }
        if let b = baseline, count > b {
            let growth = count - b
            if growth >= low && growth <= high { return true }
        }
        return false
    }

    /// 保存落定处理：状态停在「保存中」时，先让编辑器失焦促一次同步，再轮询
    /// 信号直到落定或窗口耗尽（约 5 秒），返回最后一次信号。落定与否由调用方
    /// 按口径判定，这里只负责「给它落定的机会＋如实回读」。
    private func waitForEditorSaveSettle(action: AgentAction, tab: BrowserTab) async -> EditorSignals? {
        _ = try? await evaluate("(()=>{const ae=document.activeElement;if(ae&&ae.blur)ae.blur();return 'blurred';})()", on: tab)
        var last: EditorSignals?
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(500))
            guard let s = try? await probeEditorSignals(action: action, tab: tab) else { return last }
            last = s
            if s.saveState != "saving" { return s }
        }
        return last
    }

    /// type 总流程分发：目标是 contenteditable 富文本编辑器且基线探针找得到它
    /// 时，走编辑器状态校验流程（performTypeInEditor）；其余目标（表单字段、
    /// 探针落空）走旧流程（performTypeLegacy，行为逐字不变）。
    private func performType(_ action: AgentAction, expected: PageElement?, approved: Bool, tab: BrowserTab) async throws {
        guard let expected else { throw MikaError("缺少已检查的目标元素") }
        if expected.editable, let baseline = try? await probeEditorSignals(action: action, tab: tab), baseline.found {
            try await performTypeInEditor(action: action, expected: expected, approved: approved, baseline: baseline, tab: tab)
            return
        }
        try await performTypeLegacy(action: action, expected: expected, approved: approved, tab: tab)
    }

    /// 编辑器写入失败的性质分类（阶梯耗尽后按最后一次失败区分口径汇报）。
    private enum EditorWriteFailure {
        case domMissing
        case stateRejected(count: Int, baseline: Int?)
        case saveUnsettled(count: Int?)
    }

    /// 富文本编辑器 type 流程（ZHIHU-COLUMN-SYNC）：DOM 文本在场不算写成功——
    /// 还须核对编辑器自报信号：字数计数与目标量级一致（计数不动＝文字没进入
    /// 编辑器内部状态，判该策略失败并自动升级下一策略）、保存状态落定（计数
    /// 已对上但一直「保存中」时先失焦促同步并等一个窗口复查，仍不落定按
    /// 「保存未落定」口径收尾，未落定前本动作绝不返回成功、更不会去点更新）。
    /// 策略阶梯：Draft 类＝paste→events→chunks→exec→range，其余＝exec→
    /// events→chunks→range（ZHUANLAN-FIX2 分流）。首策略用严格 guard，后续
    /// 策略用宽松 guard（编辑器文本已被前一策略改动，逐字段比对必然误判）。
    /// 全部不过关才汇报，逐策略读数进失败快照留痕。
    /// Draft 类编辑器探测（ZHUANLAN-FIX2）：编辑器子树里有 data-offset-key
    /// block（Draft 的渲染标记）或 Draft 标志类名即判 Draft 类——这类编辑器
    /// 的增量输入路径已被实证全灭，阶梯改走粘贴事务优先。
    private func probeDraftClass(action: AgentAction, tab: BrowserTab) async -> Bool {
        let data = (try? JSONSerialization.data(withJSONObject: ["index": action.index])) ?? Data()
        let json = String(decoding: data, as: UTF8.self)
        let raw = try? await evaluate("""
        (()=>{const a=\(json);
        const vis=x=>{const r=x.getBoundingClientRect(),s=getComputedStyle(x);return r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none';};
        let ed=document.querySelector('[data-mika-idx="'+a.index+'"]');
        if(!ed||!ed.isContentEditable)ed=[...document.querySelectorAll('[contenteditable="true"]')].find(vis)||null;
        if(!ed)return 'other';
        const draft=ed.querySelector('[data-offset-key]')||ed.closest('[data-offset-key]')||ed.classList.contains('public-DraftEditor-content')||ed.querySelector('.public-DraftEditor-content');
        return draft?'draft':'other';})()
        """, on: tab) as? String
        return raw == "draft"
    }

    private func performTypeInEditor(action: AgentAction, expected: PageElement, approved: Bool, baseline: EditorSignals, tab: BrowserTab) async throws {
        let expectedLen = Self.normalizedLength(action.text)
        // ZHUANLAN-FIX2：Draft 类编辑器走粘贴优先阶梯（paste→events→chunks→
        // exec→range）；其余编辑器保持第一轮阶梯不变，不扰动既有可用路径。
        let strategies: [String] = await probeDraftClass(action: action, tab: tab)
            ? ["paste", "events", "chunks", "exec", "range"]
            : ["exec", "events", "chunks", "range"]
        var trace: [String] = []
        var failure: EditorWriteFailure = .domMissing
        for (i, path) in strategies.enumerated() {
            let status = try await runTypeScript(action: action, expected: expected, approved: approved, path: path, strict: i == 0, tab: tab)
            if status == "exec-failed" { trace.append("\(path)=exec-failed"); continue }
            try await Task.sleep(for: .milliseconds(500))
            var v = try await verifyType(action: action, tab: tab)
            if !v.found {
                if let byContent = try await verifyTypeByContent(action: action, tab: tab), byContent.textOK {
                    v = byContent
                } else {
                    throw MikaError("输入后目标元素已失效，请重新开始或继续")
                }
            }
            let signals = try? await probeEditorSignals(action: action, tab: tab)
            guard v.textOK else {
                trace.append("\(path)=dom-missing")
                failure = .domMissing
                continue
            }
            if let count = signals?.count {
                guard Self.countConsistent(count, expected: expectedLen, baseline: baseline.count) else {
                    trace.append("\(path)=dom-ok,count-frozen:\(count)(基线\(baseline.count.map { "\($0)" } ?? "无"))")
                    failure = .stateRejected(count: count, baseline: baseline.count)
                    continue
                }
                if signals?.saveState == "saving" {
                    let settled = await waitForEditorSaveSettle(action: action, tab: tab)
                    if settled?.saveState == "saving" {
                        trace.append("\(path)=count-ok:\(count),save-unsettled")
                        failure = .saveUnsettled(count: count)
                        continue
                    }
                    trace.append("\(path)=count-ok:\(count),save-settled")
                } else {
                    trace.append("\(path)=count-ok:\(count)")
                }
            } else if signals?.saveState == "saving" {
                // 无字数信号可核对：仍给保存一个落定窗口（结果只记 trace）——
                // 这类编辑器旧流程只认 DOM，无信号时不单独判失败，避免误杀。
                _ = await waitForEditorSaveSettle(action: action, tab: tab)
                trace.append("\(path)=dom-ok,no-count-signal")
            } else {
                trace.append("\(path)=dom-ok,no-signals")
            }
            if v.editorLike, !v.submits.isEmpty, v.submits.allSatisfy({ $0.disabled }) {
                await captureFailureSnapshot(context: "type 后提交按钮仍禁用：\(action.reason)", tab: tab)
                throw MikaError("文字已输入，但「\(v.submits[0].text)」按钮仍是灰的（禁用状态），没能发布")
            }
            return
        }
        await captureFailureSnapshot(context: "type 编辑器状态校验失败：\(action.reason)｜\(trace.joined(separator: "；"))", tab: tab)
        switch failure {
        case .domMissing:
            throw MikaError("文字没能输入到编辑器：\(strategies.count) 种写入方式都已尝试、回读仍为空或对不上，请在网页手动输入后点继续")
        case .stateRejected(let count, let base):
            throw MikaError("文字已出现在编辑器里，但编辑器内部字数仍停在 \(count) 字（\(base.map { "写入前 \($0) 字" } ?? "写入前字数未知")），说明文字没有真正进入编辑器状态——已自动换了 \(strategies.count) 种输入方式仍不成功；这种状态下点更新只会提交旧内容，请在网页手动输入后点继续")
        case .saveUnsettled(let count):
            throw MikaError("文字已进入编辑器、字数已更新到 \(count.map { "\($0)" } ?? "目标") 字，但保存状态一直停在「草稿保存中」未落定——此时点更新/发布可能丢掉新内容，已停手。请等页面保存完成（或手动点一下编辑器外区域触发保存）后点继续")
        }
    }

    /// 旧流程（表单字段等非富文本目标，行为逐字不变）：写入→回读；不过关换备用
    /// 路径重试一次；仍不过关如实报「没输入进去」，不再误报成「找不到发表按钮」。
    /// 文字已进但提交按钮全员禁用时单独报「按钮是灰的」。
    private func performTypeLegacy(action: AgentAction, expected: PageElement, approved: Bool, tab: BrowserTab) async throws {
        for path in ["exec", "range"] {
            let status = try await runTypeScript(action: action, expected: expected, approved: approved, path: path, tab: tab)
            if status == "exec-failed" { continue }
            try await Task.sleep(for: .milliseconds(400))
            var v = try await verifyType(action: action, tab: tab)
            if !v.found {
                // 框架编辑器在输入后重渲染、把带 data-mika-idx 的旧节点换掉时，idx 回读会
                // 报「找不到节点」——但文字可能已经真正落在新节点里。先按内容兜底核对：
                // 全页找正文含目标文本的编辑器，找得到即视为写入成功（AGENT-VIEWPORT-FIX）。
                if let byContent = try await verifyTypeByContent(action: action, tab: tab), byContent.textOK {
                    v = byContent
                } else {
                    throw MikaError("输入后目标元素已失效，请重新开始或继续")
                }
            }
            if v.textOK {
                if v.editorLike, !v.submits.isEmpty, v.submits.allSatisfy({ $0.disabled }) {
                    await captureFailureSnapshot(context: "type 后提交按钮仍禁用：\(action.reason)", tab: tab)
                    throw MikaError("文字已输入，但「\(v.submits[0].text)」按钮仍是灰的（禁用状态），没能发布")
                }
                return
            }
        }
        await captureFailureSnapshot(context: "type 回读校验失败：\(action.reason)", tab: tab)
        throw MikaError("文字没能输入到编辑器：两种写入方式都已尝试、回读仍为空或对不上，请在网页手动输入后点继续")
    }

    /// click 单次尝试脚本，返回 'clicked'／'disabled'／'missing'（校验不过仍走 JS throw，与旧口径一致）。
    /// rescan=true 时不做快照一致性校验（页面可能已重渲染），按原 data-mika-idx 节点或同文案候选重新定位，
    /// 并对命中节点复用同一套安全词检查。
    private func runClickScript(action: AgentAction, expected: PageElement, approved: Bool, rescan: Bool, tab: BrowserTab) async throws -> String {
        let keywords = String(decoding: try JSONSerialization.data(withJSONObject: SafetyPolicy.keywords), as: UTF8.self)
        let script: String
        if rescan {
            let data = try JSONSerialization.data(withJSONObject: ["index": action.index, "text": expected.text.isEmpty ? expected.ariaLabel : expected.text])
            let json = String(decoding: data, as: UTF8.self)
            script = """
            (()=>{const a=\(json);
            const norm=s=>(s||'').replace(/\\s+/g,' ').trim().toLowerCase();
            const vis=x=>{const r=x.getBoundingClientRect(),s=getComputedStyle(x);return r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none';};
            const lab=x=>(x.innerText||x.value||x.getAttribute('aria-label')||'').trim();
            const dis=x=>x.disabled===true||x.getAttribute('aria-disabled')==='true';
            const safe=x=>{const l=[lab(x),x.getAttribute('aria-label')||''].join(' ').toLowerCase();if(!\(approved ? "true" : "false")&&\(keywords).some(k=>l.includes(k)))throw new Error('敏感操作未经确认');};
            const tryClick=x=>{safe(x);x.scrollIntoView({block:'center'});x.focus();x.click();return 'clicked';};
            let node=document.querySelector('[data-mika-idx="'+a.index+'"]');
            if(node&&node.isConnected&&vis(node)&&!dis(node))return tryClick(node);
            const want=norm(a.text);
            if(want){
              const cands=[...document.querySelectorAll('button,[role="button"],a,input[type="submit"],input[type="button"]')].filter(x=>vis(x)&&norm(lab(x))===want);
              const enabled=cands.find(x=>!dis(x));
              if(enabled)return tryClick(enabled);
              if(cands.length)return 'disabled';
            }
            if(node&&node.isConnected)return dis(node)?'disabled':'missing';
            return 'missing';})()
            """
        } else {
            let prefix = try guardScript(action: action, expected: expected, approved: approved)
            script = """
            (()=>{\(prefix)
            if(e.disabled===true||e.getAttribute('aria-disabled')==='true')return 'disabled';
            e.scrollIntoView({block:'center'});e.focus();e.click();return 'clicked';})()
            """
        }
        let result = try await evaluate(script, on: tab)
        return (result as? String) ?? "missing"
    }

    // MARK: - 弹窗点按升级（COVER-CONSENT-IMPL-2026-11-03，缺陷 A）
    //
    // 真机现场（Joey 2026-11-03 01:46，构建 1655）：微信公众号编辑器的
    // 「AI 配图」条款弹窗，agent 多次点「同意」弹窗始终不消失——这类网页
    // 按钮只认完整的 pointer/mouse 事件序列（或只认真实点按），旧 click
    // 只调 e.click() 派发一个简化 click 事件，网页不认账。升级路径：
    // 目标位于弹窗内、或普通点击后观察到同一弹窗仍在 → 改用完整事件
    // 序列（先滚动入视口，再按元素中心坐标带间隔依次派发 pointerover→
    // pointerdown→mousedown→focus→pointerup→mouseup→click）；升级后弹窗
    // 仍在、连败 2 次 → 抛 modalUnresponsivePrefix 错误，引擎据此转对话
    // 内介入请用户亲手点按（见 AgentEngine.modalInterventionText）。
    // 诚实边界：合成事件 isTrusted=false 无法伪造——过不去时如实转人工，
    // 绝不静默循环、绝不假装已同意。

    /// 弹窗点按无响应的错误前缀（引擎转介入判定的唯一依据，两处共用同一常量）。
    static let modalUnresponsivePrefix = "弹窗点按无响应"

    /// 弹窗判定 JS 片段（注入各探针脚本共用）：dialogOf(x) 沿祖先链找
    /// 「对话框样容器」——dialog[open]／role=dialog|alertdialog／
    /// aria-modal=true，或固定/绝对定位且类名/id 含 dialog|modal|popup|
    /// layer|mask|overlay|alert|confirm 关键词的浮层。普通固定顶栏（无
    /// 关键词）不算弹窗，避免把导航按钮误判成弹窗按钮；判定漏检的弹窗
    /// 由点击后的存续探针兜底，误判方向偏保守（漏检退回旧行为）。
    private static let dialogProbeJS = """
    const visDlg=x=>{const r=x.getBoundingClientRect(),s=getComputedStyle(x);return r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none';};
    const labDlg=x=>(x.innerText||x.value||x.getAttribute('aria-label')||'').trim();
    const normDlg=s=>(s||'').replace(/\\s+/g,' ').trim().toLowerCase();
    const dlgKey=/dialog|modal|popup|pop-|layer|mask|overlay|alert|confirm/;
    const dialogOf=x=>{let n=x;while(n&&n!==document.body){if(n.tagName==='DIALOG'&&n.open)return n;const role=n.getAttribute?n.getAttribute('role'):null;if(role==='dialog'||role==='alertdialog')return n;if(n.getAttribute&&n.getAttribute('aria-modal')==='true')return n;const s=getComputedStyle(n);if(s.position==='fixed'||s.position==='absolute'){const cls=((typeof n.className==='string'?n.className:'')+' '+(n.id||'')).toLowerCase();if(dlgKey.test(cls))return n;}n=n.parentElement;}return null;};
    """

    /// 点击前探针（guard 校验与旧口径一致：目标已变化/已失效照旧 throw）：
    /// 返回 'ready-dialog'（目标在弹窗内）／'ready-plain'／'disabled'。
    private func probeClickContext(action: AgentAction, expected: PageElement, approved: Bool, tab: BrowserTab) async throws -> String {
        let prefix = try guardScript(action: action, expected: expected, approved: approved)
        let script = """
        (()=>{\(prefix)
        \(Self.dialogProbeJS)
        if(e.disabled===true||e.getAttribute('aria-disabled')==='true')return 'disabled';
        return dialogOf(e)?'ready-dialog':'ready-plain';})()
        """
        let result = try await evaluate(script, on: tab)
        return (result as? String) ?? "ready-plain"
    }

    /// 弹窗存续探针：点击之后「同一弹窗仍在」是否成立——目标节点仍连接、
    /// 可见且身处弹窗内，或任一可见弹窗容器里还有同文案的可见按钮。
    private func dialogPersists(action: AgentAction, expected: PageElement, tab: BrowserTab) async -> Bool {
        let label = expected.text.isEmpty ? expected.ariaLabel : expected.text
        guard let data = try? JSONSerialization.data(withJSONObject: ["index": action.index, "label": label]),
              let json = String(data: data, encoding: .utf8) else { return false }
        let script = """
        (()=>{const a=\(json);
        \(Self.dialogProbeJS)
        const e=document.querySelector('[data-mika-idx="'+a.index+'"]');
        if(e&&e.isConnected&&visDlg(e)&&dialogOf(e))return 'still';
        const want=normDlg(a.label);
        if(want){
          const all=document.querySelectorAll('dialog,[role="dialog"],[role="alertdialog"],div,section');
          for(const d of all){if(!visDlg(d)||dialogOf(d)!==d)continue;
            const cands=d.querySelectorAll('button,[role="button"],a,input[type="button"],input[type="submit"]');
            for(const c of cands){if(visDlg(c)&&normDlg(labDlg(c))===want)return 'still';}}
        }
        return 'gone';})()
        """
        let result = try? await evaluate(script, on: tab)
        return (result as? String) == "still"
    }

    /// 完整点按序列的单步派发：每步独立求值（步间由 Swift 侧睡出小间隔），
    /// 每步都重定位节点并重跑安全词检查（与 click 同口径，未经确认的敏感
    /// 操作照样 throw）；节点中途消失返回 'gone'（多半弹窗已被前序事件
    /// 关掉，成败由随后的存续探针裁决）。坐标取当下包围盒中心（真实坐标）。
    private func runPointerStep(step: String, action: AgentAction, approved: Bool, tab: BrowserTab) async throws -> String {
        let keywords = String(decoding: try JSONSerialization.data(withJSONObject: SafetyPolicy.keywords), as: UTF8.self)
        let script = """
        (()=>{const e=document.querySelector('[data-mika-idx="\(action.index)"]');
        if(!e||!e.isConnected)return 'gone';
        const l=[(e.innerText||e.value||''),(e.getAttribute('aria-label')||'')].join(' ').toLowerCase();
        if(!\(approved ? "true" : "false")&&\(keywords).some(k=>l.includes(k)))throw new Error('敏感操作未经确认');
        const step='\(step)';
        if(step==='scroll'){e.scrollIntoView({block:'center'});return 'ok';}
        if(step==='focus'){try{e.focus();}catch(_){}return 'ok';}
        if(step==='click'){e.click();return 'ok';}
        const r=e.getBoundingClientRect();const x=r.left+r.width/2,y=r.top+r.height/2;
        const down=step==='pointerdown'||step==='mousedown';
        const opts={bubbles:true,composed:true,cancelable:true,clientX:x,clientY:y,button:0,buttons:down?1:0,view:window};
        if(step.indexOf('pointer')===0){
          let ev=null;
          try{ev=new PointerEvent(step,Object.assign({},opts,{pointerId:1,pointerType:'mouse',isPrimary:true}));}catch(_){ev=null;}
          if(!ev){try{ev=new MouseEvent(step,opts);}catch(__){ev=null;}}
          if(ev)e.dispatchEvent(ev);
          return 'ok';
        }
        e.dispatchEvent(new MouseEvent(step,opts));
        return 'ok';})()
        """
        let result = try await evaluate(script, on: tab)
        return (result as? String) ?? "gone"
    }

    /// 完整点按序列：scrollIntoView 后按 spec 顺序派发，步间小间隔
    /// （scroll 后 150ms 落位、其余步间 70ms——匀速即时派发整串时，部分
    /// 网页的状态机会跟不上或直接忽略，分步带间隔更接近真实点按节奏）。
    private func performPointerSequence(action: AgentAction, approved: Bool, tab: BrowserTab) async throws {
        let steps = ["scroll", "pointerover", "pointerdown", "mousedown", "focus", "pointerup", "mouseup", "click"]
        for (offset, step) in steps.enumerated() {
            let status = try await runPointerStep(step: step, action: action, approved: approved, tab: tab)
            if status == "gone" { return }
            try await Task.sleep(for: .milliseconds(offset == 0 ? 150 : 70))
        }
    }

    /// 弹窗升级点击：完整序列→等 600ms→存续探针；仍在则再来一轮；
    /// 连败 2 次抛「弹窗点按无响应」转人工（不静默循环、不假装已同意）。
    private func performModalClick(action: AgentAction, expected: PageElement, approved: Bool, tab: BrowserTab) async throws {
        for _ in 1...2 {
            try await performPointerSequence(action: action, approved: approved, tab: tab)
            try await Task.sleep(for: .milliseconds(600))
            if await dialogPersists(action: action, expected: expected, tab: tab) == false { return }
        }
        await captureFailureSnapshot(context: "弹窗点按无响应：\(action.reason)", tab: tab)
        throw MikaError("\(Self.modalUnresponsivePrefix)：弹窗内的按钮经完整点按序列（真实坐标的 pointer/mouse 事件）两次尝试后仍未关闭——合成点按不是真实点按（isTrusted=false），这类网页只认真实点按")
    }

    /// click 总流程：先探针分流——目标在弹窗内直接走升级序列；普通目标
    /// 先按已校验元素点（旧口径），点后若观察到同一弹窗仍在再升级；
    /// 禁用/缺失时「等待＋重扫」轮询约 3.6 秒（编辑器状态更新后按钮常
    /// 延迟启用或被重渲染替换，重扫点击成功后同样过一遍存续探针）；
    /// 最终按「是灰的／找不到」两种口径分别报错并留诊断快照。
    private func performClick(_ action: AgentAction, expected: PageElement?, approved: Bool, tab: BrowserTab) async throws {
        guard let expected else { throw MikaError("缺少已检查的目标元素") }
        let probe = try await probeClickContext(action: action, expected: expected, approved: approved, tab: tab)
        if probe == "ready-dialog" {
            try await performModalClick(action: action, expected: expected, approved: approved, tab: tab)
            return
        }
        var status = probe
        if probe == "ready-plain" {
            let first = try await runClickScript(action: action, expected: expected, approved: approved, rescan: false, tab: tab)
            status = first
            if first == "clicked" {
                try await Task.sleep(for: .milliseconds(500))
                if await dialogPersists(action: action, expected: expected, tab: tab) {
                    try await performModalClick(action: action, expected: expected, approved: approved, tab: tab)
                }
                return
            }
        }
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(300))
            status = try await runClickScript(action: action, expected: expected, approved: approved, rescan: true, tab: tab)
            if status == "clicked" {
                try await Task.sleep(for: .milliseconds(500))
                if await dialogPersists(action: action, expected: expected, tab: tab) {
                    try await performModalClick(action: action, expected: expected, approved: approved, tab: tab)
                }
                return
            }
        }
        let label = expected.text.isEmpty ? expected.ariaLabel : expected.text
        if status == "disabled" {
            await captureFailureSnapshot(context: "click 目标禁用：\(action.reason)", tab: tab)
            throw MikaError("「\(label)」按钮是灰的（存在但被禁用），无法点击")
        }
        await captureFailureSnapshot(context: "click 目标缺失：\(action.reason)", tab: tab)
        throw MikaError("页面上找不到要点的按钮「\(label)」（可能还没渲染出来或已经关闭）")
    }

    // MARK: - 自检十一 Tier A（COVER-CONSENT）：弹窗点按升级的程序化核查
    //
    // 在本地合成页 test-modal 上全程真实驱动（不调用模型）：严格弹窗的
    // 按钮只认完整 pointer 序列——先验裸 click() 关不掉（基线），再走
    // execute 的 click 应经升级序列关掉它；顽固弹窗的按钮对任何事件都
    // 不响应——execute 应在两次升级后抛「弹窗点按无响应」。核查在当前
    // 标签页上进行（自检的既定形态，与自检九的标签操作同级），结束时
    // 页面留在该测试页上。

    private static func selfTestClickAction(index: Int) -> AgentAction? {
        let json = "{\"action\":\"click\",\"index\":\(index),\"reason\":\"自检十一合成页验证\"}"
        return try? JSONDecoder().decode(AgentAction.self, from: Data(json.utf8))
    }

    private func modalStateProbe(on tab: BrowserTab) async -> String {
        let result = try? await evaluate("(()=>{return window.__modalState?window.__modalState():'{}';})()", on: tab)
        return (result as? String) ?? ""
    }

    func verifyModalClickEscalation() async -> [String] {
        var lines: [String] = []
        let tab = activeTab
        do { try tab.loadLocal("test-modal") } catch {
            return ["✗ 合成测试页 test-modal 加载失败：\(error.localizedDescription)"]
        }
        try? await Task.sleep(for: .milliseconds(1000))
        guard let page = try? await state() else { return ["✗ 合成测试页状态抽取失败"] }
        guard let strict = page.elements.first(where: { $0.text.contains("同意并继续") }) else {
            return ["✗ 合成测试页未找到严格弹窗的按钮（抽取异常）"]
        }
        // —— 基线：裸 click() 关不掉严格弹窗 ——
        _ = try? await evaluate("(()=>{const e=document.querySelector('[data-mika-idx=\"\(strict.index)\"]');if(e)e.click();return 'done';})()", on: tab)
        try? await Task.sleep(for: .milliseconds(400))
        let afterPlain = await modalStateProbe(on: tab)
        lines.append(afterPlain.contains("\"strictOpen\":true")
            ? "✓ 基线：只派发 click 的裸点按关不掉严格弹窗（页面只认完整 pointer 序列，与微信弹窗现场同型）"
            : "✗ 基线异常（裸点按后页面状态 \(afterPlain)）")
        // —— 引擎 click：探针判定在弹窗内 → 升级序列 → 弹窗关闭 ——
        // （点前重取状态：基线裸点按改过提示文案，序号以最新抽取为准）
        guard let pageFresh = try? await state(), let strictFresh = pageFresh.elements.first(where: { $0.text.contains("同意并继续") }) else {
            lines.append("✗ 合成测试页升级点击前状态重取失败")
            return lines
        }
        guard let clickStrict = Self.selfTestClickAction(index: strictFresh.index) else {
            lines.append("✗ 自检动作构造失败（严格弹窗）")
            return lines
        }
        do {
            try await execute(clickStrict, expected: strictFresh)
            try? await Task.sleep(for: .milliseconds(400))
            let after = await modalStateProbe(on: tab)
            lines.append(after.contains("\"strictOpen\":false") && after.contains("\"strictResult\":\"block\"")
                ? "✓ 升级点击：引擎 click 经完整 pointer 序列后严格弹窗已关闭、页面确认标记在场"
                : "✗ 升级点击未关掉严格弹窗（页面状态 \(after)）")
        } catch {
            lines.append("✗ 升级点击抛错：\(error.localizedDescription)")
        }
        // —— 顽固弹窗：两次升级仍无响应 → 抛「弹窗点按无响应」——
        guard let page2 = try? await state(), let stubborn = page2.elements.first(where: { $0.text.contains("同意（无响应）") }) else {
            lines.append("✗ 合成测试页未找到顽固弹窗的按钮（抽取异常）")
            return lines
        }
        guard let clickStubborn = Self.selfTestClickAction(index: stubborn.index) else {
            lines.append("✗ 自检动作构造失败（顽固弹窗）")
            return lines
        }
        do {
            try await execute(clickStubborn, expected: stubborn)
            lines.append("✗ 顽固弹窗：升级序列后没有抛错（无响应判定未触发）")
        } catch {
            lines.append((error as? MikaError)?.message.hasPrefix(Self.modalUnresponsivePrefix) == true
                ? "✓ 顽固弹窗：完整序列连败 2 次后按口径抛出「\(Self.modalUnresponsivePrefix)」——引擎据此转对话内介入，不静默循环"
                : "✗ 顽固弹窗抛错口径不对：\(error.localizedDescription)")
        }
        return lines
    }

    // MARK: - VERIFY-1：动作后取证采样器（settled-capture 的 DOM 版）

    /// settle 采样探针：与 PageState 同口径的可见正文（供采样帧与 toast
    /// 捕捉），外加页面签名（就绪态/正文长度/正文哈希/节点数/文档高度）
    /// 与网络空闲判据（performance 资源计时里最近一次响应结束时刻）。
    private static let settleProbe = #"""
    (()=>{const vis=e=>{const r=e.getBoundingClientRect(),s=getComputedStyle(e);return r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none'};
    let text='',n;const w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);
    while((n=w.nextNode())&&text.length<6000){if(n.parentElement&&!n.parentElement.closest('script,style,noscript')&&vis(n.parentElement))text+=n.textContent.trim()+' ';}
    let h=0;for(let i=0;i<text.length;i++){h=((h<<5)-h+text.charCodeAt(i))|0;}
    let lastEnd=0;try{const es=performance.getEntriesByType('resource');for(const e of es){if(e.responseEnd>lastEnd)lastEnd=e.responseEnd;}}catch(_){}
    return JSON.stringify({url:location.href,text:text,sig:[document.readyState,text.length,h,document.querySelectorAll('*').length,document.documentElement?document.documentElement.scrollHeight:0].join('|'),lastEnd:lastEnd,now:performance.now()});})()
    """#

    private struct SettleProbeResult: Decodable {
        let url: String
        let text: String
        let sig: String
        let lastEnd: Double
        let now: Double
    }

    /// settle 采样结果：采样帧序列＋是否在有界窗口内收口（页面签名连续
    /// 稳定且网络空闲）＋收口后的完整快照（导航/代次变化后重新抽取，
    /// 不用旧定位——state() 本身就是对当前执行页的重新抽取）。
    struct SettledCapture {
        let samples: [VerificationSample]
        let settled: Bool
        let after: PageState
    }

    /// 动作后取证：每 300ms 探一帧，签名连续 3 帧不变且最近网络响应
    /// 已结束 600ms 以上判 settled；有界超时（默认 5 秒）只记证据未稳，
    /// 不算成功、不抛错。全程尽力而为：探针失败帧直接跳过。
    func settledCapture(timeoutMs: Int = 5000) async -> SettledCapture {
        let tab = executionTab
        var samples: [VerificationSample] = []
        var lastSig: String?
        var stableRepeats = 0
        var settled = false
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if agentWorkSuspended { break }
            if let raw = (try? await evaluate(Self.settleProbe, on: tab)) as? String,
               let probe = try? JSONDecoder().decode(SettleProbeResult.self, from: Data(raw.utf8)) {
                samples.append(VerificationSample(url: probe.url, text: probe.text))
                let networkQuiet = probe.lastEnd == 0 || (probe.now - probe.lastEnd) > 600
                if probe.sig == lastSig, networkQuiet {
                    stableRepeats += 1
                } else {
                    stableRepeats = 0
                }
                lastSig = probe.sig
                if stableRepeats >= 2 { settled = true; break }
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        let after: PageState
        if let fresh = try? await state() {
            after = fresh
        } else if let last = samples.last {
            after = PageState(url: last.url, title: "", text: last.text, elements: [])
        } else {
            after = PageState(url: tab.webView.url?.absoluteString ?? "", title: "", text: "", elements: [])
        }
        return SettledCapture(samples: samples, settled: settled, after: after)
    }

    // MARK: - 自检十三 Tier A（VERIFY-1）：核验合约的合成页全链驱动
    //
    // 在本地合成页 test-verify 上真实驱动（不调用模型）：四场景逐个走
    // 「取动作前快照→引擎 click→settle 采样→ActionVerifier 判定」，断言
    // 三值与证据未稳口径：甲＝回读证据 verified、乙＝只有 toast 判
    /// unknown、丙＝明确拒绝 contradicted（且与自报分歧）、丁＝页面持续
    // 变化 settle 超时判 unknown。产出的记录回引擎做落盘往返核对（写
    // 临时日志，不污染正式 shadow 统计）。核查在当前标签页进行，结束
    // 时页面留在该测试页上（与自检十一同形态）。

    func verifyActionVerificationContract() async -> (lines: [String], records: [VerificationRecord]) {
        var lines: [String] = []
        var records: [VerificationRecord] = []
        let tab = activeTab
        do { try tab.loadLocal("test-verify") } catch {
            return (["✗ 合成测试页 test-verify 加载失败：\(error.localizedDescription)"], [])
        }
        try? await Task.sleep(for: .milliseconds(1000))

        // 单场景驱动：找到按钮→记动作前快照→click→采样判定→组装记录
        func drive(buttonText: String, content: String, timeoutMs: Int) async -> (ActionVerifier.Result, SettledCapture, PageState)? {
            guard let before = try? await state(),
                  let target = before.elements.first(where: { $0.text.contains(buttonText) }),
                  let click = Self.selfTestClickAction(index: target.index) else { return nil }
            do { try await execute(click, expected: target) } catch { return nil }
            let capture = await settledCapture(timeoutMs: timeoutMs)
            let prefix = SubmissionClassifier.contentFingerprint(of: content).prefix
            let result = ActionVerifier.judge(before: before, after: capture.after, samples: capture.samples,
                                              settled: capture.settled, contentPrefix: prefix)
            return (result, capture, before)
        }

        // —— 场景甲：发布后条目进列表（回读证据）→ verified ——
        if let (result, capture, before) = await drive(buttonText: "发布甲", content: "自检十三稿件甲：核验合约的回读场景正文。", timeoutMs: 5000) {
            let record = ActionVerifier.makeRecord(sessionID: tab.sessionID.uuidString, outcomeRecordID: nil,
                                                   actionLabel: "发布甲", pageURL: before.url, result: result, settled: capture.settled)
            records.append(record)
            lines.append(result.verdict == .verified && result.evidence.contains(where: { $0.contains("回读证据") })
                ? "✓ 场景甲：发布后条目进入列表——回读证据成立，判定 verified（证据：\(result.evidence.first ?? "")）"
                : "✗ 场景甲判定异常：\(result.verdict.rawValue)（证据 \(result.evidence)）")
        } else {
            lines.append("✗ 场景甲驱动失败（按钮定位或点击异常）")
        }

        // —— 场景乙：只有 toast → 弱证据，unknown ——
        if let (result, capture, before) = await drive(buttonText: "发送乙", content: "自检十三场景乙内容", timeoutMs: 5000) {
            let record = ActionVerifier.makeRecord(sessionID: tab.sessionID.uuidString, outcomeRecordID: nil,
                                                   actionLabel: "发送乙", pageURL: before.url, result: result, settled: capture.settled)
            records.append(record)
            lines.append(result.verdict == .unknown
                ? "✓ 场景乙：只有短暂提示、无回读证据——判定 unknown（toast 只记弱证据，不单独构成 verified）"
                : "✗ 场景乙判定异常：\(result.verdict.rawValue)（toast 被误判为 conclusive 证据）")
        } else {
            lines.append("✗ 场景乙驱动失败（按钮定位或点击异常）")
        }

        // —— 场景丙：明确拒绝 → contradicted 且与自报分歧 ——
        if let (result, capture, before) = await drive(buttonText: "提交丙", content: "自检十三场景丙正文样本。", timeoutMs: 5000) {
            let record = ActionVerifier.makeRecord(sessionID: tab.sessionID.uuidString, outcomeRecordID: nil,
                                                   actionLabel: "提交丙", pageURL: before.url, result: result, settled: capture.settled)
            records.append(record)
            lines.append(result.verdict == .contradicted && record.diverged
                ? "✓ 场景丙：页面明确拒绝——判定 contradicted，记录 diverged=true（与执行器自报分歧成立）"
                : "✗ 场景丙判定异常：\(result.verdict.rawValue)（diverged=\(record.diverged)）")
        } else {
            lines.append("✗ 场景丙驱动失败（按钮定位或点击异常）")
        }

        // —— 场景丁：页面持续变化 → settle 超时，证据未稳，unknown ——
        if let (result, capture, before) = await drive(buttonText: "发布丁", content: "", timeoutMs: 2600) {
            let record = ActionVerifier.makeRecord(sessionID: tab.sessionID.uuidString, outcomeRecordID: nil,
                                                   actionLabel: "发布丁", pageURL: before.url, result: result, settled: capture.settled)
            records.append(record)
            lines.append(!capture.settled && result.verdict == .unknown && result.evidence.contains(where: { $0.contains("证据未稳") })
                ? "✓ 场景丁：页面持续变化、settle 有界超时——记录「证据未稳」，判定 unknown（超时不算成功）"
                : "✗ 场景丁判定异常：settled=\(capture.settled)、verdict=\(result.verdict.rawValue)")
        } else {
            lines.append("✗ 场景丁驱动失败（按钮定位或点击异常）")
        }
        return (lines, records)
    }

    // MARK: - 失败留证（写入既有 DiagnosticStore 通道：同目录、同信封格式，诊断页可见）

    /// agent 操作失败时存一份快照：页面截图（JPEG base64）＋精简 DOM 摘要（候选按钮与禁用状态）。
    /// 全程尽力而为：抓取失败不掩盖原始错误。
    private func captureFailureSnapshot(context: String, tab: BrowserTab) async {
        let domSummary = (try? await evaluate("""
        (()=>{const vis=x=>{const r=x.getBoundingClientRect(),s=getComputedStyle(x);return r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none';};
        const lab=x=>(x.innerText||x.value||x.getAttribute('aria-label')||'').trim().slice(0,40);
        const dis=x=>x.disabled===true||x.getAttribute('aria-disabled')==='true';
        const buttons=[...document.querySelectorAll('button,[role="button"],input[type="submit"],a')].filter(vis).slice(0,12).map(x=>({text:lab(x),tag:x.tagName.toLowerCase(),disabled:dis(x)}));
        const editors=[...document.querySelectorAll('[contenteditable="true"],textarea')].filter(vis).map(x=>({tag:x.tagName.toLowerCase(),textLength:(x.innerText||x.value||'').length}));
        return JSON.stringify({url:location.href,title:document.title,buttons,editors});})()
        """, on: tab)) as? String ?? ""
        var payload: [String: Any] = ["kind": "agent-action-failure", "context": context, "url": tab.webView.url?.absoluteString ?? "", "domSummary": domSummary]
        if let shot = await snapshotBase64(tab: tab) {
            payload["screenshotJPEGBase64"] = shot
            // 附件中心（F1）：失败截图同时登记进所属会话的 browser/ 子目录，
            // 成为可预览/可导出的附件资产（本任务生成物）；诊断信封口径不变，
            // 登记失败不影响留证主流程。
            if let data = Data(base64Encoded: shot) {
                _ = AttachmentStore.shared.registerScreenshot(data: data, sessionID: tab.sessionID)
            }
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MikaWeb/Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID(), now = Date(), formatter = ISO8601DateFormatter()
        let envelope: [String: Any] = ["schemaVersion": 1, "id": id.uuidString, "receivedAt": formatter.string(from: now), "types": ["操作失败快照"], "payload": payload]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]) else { return }
        let name = formatter.string(from: now).replacingOccurrences(of: ":", with: "-") + "-" + id.uuidString + ".json"
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private func snapshotBase64(tab: BrowserTab) async -> String? {
        await withCheckedContinuation { continuation in
            let config = WKSnapshotConfiguration()
            config.afterScreenUpdates = false
            tab.webView.takeSnapshot(with: config) { image, _ in
                if let image, let data = image.jpegData(compressionQuality: 0.5) {
                    continuation.resume(returning: data.base64EncodedString())
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
