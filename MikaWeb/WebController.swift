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

// 标签页会话（2026-11-02，案卷 TABS-IMPL-2026-11-02.md）：一个标签页＝一个独立 WKWebView
// ＋独立历史／标题／加载状态。切换标签只是把当前页的 WKWebView 换入视图层级，离屏标签的
// 实例与页面状态由本对象强持有保留、不重载；网页进程被系统内存压力杀掉时，按最后已知
// 地址重载恢复该页（系统行为，见 webViewWebContentProcessDidTerminate）。
@MainActor final class BrowserTab: NSObject, ObservableObject, WKNavigationDelegate, Identifiable {
    let id = UUID()
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
    init(configuration: WKWebViewConfiguration? = nil, loadStartPage: Bool = true) {
        let config = configuration ?? Self.makeConfiguration()
        // 探针装配走复用器：window.open 所给的配置与发起页共享同一
        // WKUserContentController，逐标签重复注册同名 handler 会抛
        // NSInvalidArgumentException 致 abort（CRASH-1031），复用器保证
        // 每个 controller 只装一次、消息按 webView 路由回所属标签页。
        WebAuthnProbeMultiplexer.shared.equip(config.userContentController)
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        WebAuthnProbeMultiplexer.shared.associate(tab: self)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
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
    func reload() { webView.reload() }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

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
    /// 任务绑定的标签页；nil＝没有任务绑定（state／execute 回落到当前页）
    @Published private(set) var executionTabID: UUID?
    /// agent 工作驻停标记（BACKGROUND-RESILIENCE，由 AgentEngine 在切后台时置位）：
    /// 置位期间 agent 通道的加载等待与 DOM 静默轮询立即收敛停手——不再向正在被
    /// 系统挂起的网页进程发探针（0808 的 scene-update 看门狗终止教训：进后台的
    /// 场景事务窗口里，主线与网页侧的工作都要第一时间安静下来）。用户手动浏览
    /// 不走 ready／state 通道，不受此标记影响。
    var agentWorkSuspended = false
    private var tabCancellables: [UUID: AnyCancellable] = [:]

    override init() {
        let first = BrowserTab()
        tabs = [first]
        activeTabID = first.id
        executionTabID = nil
        super.init()
        adopt(first)
    }

    private func adopt(_ tab: BrowserTab) {
        tab.webView.uiDelegate = self
        tabCancellables[tab.id] = tab.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
    }

    var activeTab: BrowserTab { tabs.first(where: { $0.id == activeTabID }) ?? tabs[0] }
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

    /// 新建标签并切换过去；urlString 非空时在新页打开该地址。
    @discardableResult
    func newTab(urlString: String? = nil) -> BrowserTab {
        let tab = BrowserTab()
        tabs.append(tab)
        adopt(tab)
        activeTabID = tab.id
        if let urlString, !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? tab.load(urlString)
        }
        return tab
    }

    func activateTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
    }

    /// 关闭标签：关当前页切到相邻页（优先右侧、其次左侧）；关掉最后一个标签时自动补一个
    /// 新的空白标签（永不归零）。关掉的若是任务执行页，执行绑定随之解除，任务的后续
    /// state／execute 回落到新的当前页（其目标校验会拦下不一致的已确认动作，见案卷）。
    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = tabs[index]
        let wasActive = id == activeTabID
        tabs.remove(at: index)
        tabCancellables[id]?.cancel()
        tabCancellables[id] = nil
        closing.webView.stopLoading()
        closing.webView.navigationDelegate = nil
        closing.webView.uiDelegate = nil
        if executionTabID == id { executionTabID = nil }
        if tabs.isEmpty {
            let fresh = BrowserTab()
            tabs = [fresh]
            adopt(fresh)
            activeTabID = fresh.id
        } else if wasActive {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    // MARK: - 任务执行绑定（AgentEngine 调用）

    /// 任务开始：把执行页绑定到当时的当前页，任务全程作用于它，与用户切页解耦。
    func beginExecution() { executionTabID = activeTabID }
    /// 任务终结／停止：解除绑定（state／execute 回落当前页）。
    func endExecution() { executionTabID = nil }
    /// 执行页重载（引擎在页面瞬时失败连败时用）：作用于执行页而非当前页，用户切页不串。
    func reloadExecutionTab() { executionTab.reload() }

    /// agent 的 open_new_tab 动作：新开标签、切换过去并把执行绑定一并移过去，
    /// 后续动作作用于新页。地址先校验后建页，非法地址不留空标签。
    @discardableResult
    func openTabForExecution(urlString: String) throws -> BrowserTab {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = trimmed.isEmpty ? nil : try BrowserTab.validatedURL(trimmed)
        let tab = BrowserTab()
        tabs.append(tab)
        adopt(tab)
        activeTabID = tab.id
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
        let tab = BrowserTab(configuration: configuration, loadStartPage: false)
        tabs.append(tab)
        adopt(tab)
        activeTabID = tab.id
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
    private func guardScript(action: AgentAction, expected: PageElement, approved: Bool) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["index": action.index, "text": action.text, "action": action.action])
        let json = String(decoding: data, as: UTF8.self)
        let expectedJSON = String(decoding: try JSONEncoder().encode(expected), as: UTF8.self)
        let keywords = String(decoding: try JSONSerialization.data(withJSONObject: SafetyPolicy.keywords), as: UTF8.self)
        return """
        const a=\(json),expected=\(expectedJSON);
        const page=JSON.parse(\(PageScript.extract)),target=page.elements.find(x=>x.index===a.index);
        if(!target||!Object.keys(expected).every(k=>target[k]===expected[k]))throw new Error('目标元素已变化');
        if(a.action==='type'&&target.sensitive)throw new Error('敏感字段必须手动输入');
        const label=[target.text,target.placeholder,target.name,target.ariaLabel].join(' ').toLowerCase();
        if(!\(approved ? "true" : "false")&&\(keywords).some(k=>label.includes(k)))throw new Error('敏感操作未经确认');
        const e=document.querySelector('[data-mika-idx="'+a.index+'"]');
        if(!e||!e.isConnected)throw new Error('目标元素已失效');
        """
    }

    /// type 写入脚本。path=exec：聚焦＋全选后 execCommand('insertText')（走 WebKit 原生编辑管线，
    /// 框架编辑器 Draft/Slate/ProseMirror 都认这条）；path=range：Selection/Range 直接写 DOM
    /// 再补带 inputType/data 的 InputEvent（备用路径）。表单字段两条路径同法：原生 value setter
    /// ＋InputEvent（React 受控组件认 setter＋input 事件）。返回 'ok' 或 'exec-failed'。
    private func runTypeScript(action: AgentAction, expected: PageElement, approved: Bool, path: String, tab: BrowserTab) async throws -> String {
        let prefix = try guardScript(action: action, expected: expected, approved: approved)
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
          if('\(path)'==='exec'){
            let done=false;
            try{done=document.execCommand('insertText',false,text);}catch(_){done=false;}
            return done?'ok':'exec-failed';
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

    /// type 总流程：写入→回读；不过关换备用路径重试一次；仍不过关如实报「没输入进去」，
    /// 不再误报成「找不到发表按钮」。文字已进但提交按钮全员禁用时单独报「按钮是灰的」。
    private func performType(_ action: AgentAction, expected: PageElement?, approved: Bool, tab: BrowserTab) async throws {
        guard let expected else { throw MikaError("缺少已检查的目标元素") }
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

    /// click 总流程：先按已校验元素点；禁用/缺失时「等待＋重扫」轮询约 3.6 秒（编辑器状态更新后
    /// 按钮常延迟启用或被重渲染替换）；最终按「是灰的／找不到」两种口径分别报错并留诊断快照。
    private func performClick(_ action: AgentAction, expected: PageElement?, approved: Bool, tab: BrowserTab) async throws {
        guard let expected else { throw MikaError("缺少已检查的目标元素") }
        var status = try await runClickScript(action: action, expected: expected, approved: approved, rescan: false, tab: tab)
        if status == "clicked" { return }
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(300))
            status = try await runClickScript(action: action, expected: expected, approved: approved, rescan: true, tab: tab)
            if status == "clicked" { return }
        }
        let label = expected.text.isEmpty ? expected.ariaLabel : expected.text
        if status == "disabled" {
            await captureFailureSnapshot(context: "click 目标禁用：\(action.reason)", tab: tab)
            throw MikaError("「\(label)」按钮是灰的（存在但被禁用），无法点击")
        }
        await captureFailureSnapshot(context: "click 目标缺失：\(action.reason)", tab: tab)
        throw MikaError("页面上找不到要点的按钮「\(label)」（可能还没渲染出来或已经关闭）")
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
        if let shot = await snapshotBase64(tab: tab) { payload["screenshotJPEGBase64"] = shot }
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
