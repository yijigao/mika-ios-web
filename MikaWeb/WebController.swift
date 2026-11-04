import SwiftUI
import WebKit
import Combine
import UIKit
import PhotosUI
import UniformTypeIdentifiers

extension Notification.Name {
    /// 页面发起通行密钥（WebAuthn）请求且被平台拒绝时，由 BrowserTab 发出、
    /// AgentConversationStore 订阅并在对话区给人话降级提示（DOCK-NAV-PASSKEY-FIX）。
    static let mikaWebAuthnBlocked = Notification.Name("MikaWeb.WebAuthnBlocked")
}

struct ClickGuardCacheKey: Equatable {
    let tabID: UUID
    let epoch: Int
    let index: Int
    static func hits(_ cached: Self?, tabID: UUID, epoch: Int, index: Int) -> Bool {
        cached == Self(tabID: tabID, epoch: epoch, index: index)
    }
}

enum SettleDecisionPolicy {
    enum Decision: Equatable { case `continue`, settled, timedOut }
    struct State { var signature: String? = nil; var epoch: Int? = nil; var consecutive = 0 }
    static func step(_ state: inout State, signature: String?, epoch: Int, networkQuiet: Bool, remaining: TimeInterval) -> Decision {
        if remaining <= 0 { return .timedOut }
        guard let signature else { state = State(); return .continue }
        if state.signature == signature && state.epoch == epoch { state.consecutive += 1 }
        else { state.consecutive = 1 }
        state.signature = signature; state.epoch = epoch
        return state.consecutive >= 3 && networkQuiet ? .settled : .continue
    }
    static func shouldCaptureState(remaining: TimeInterval) -> Bool { remaining >= 1.5 }
}

enum SettleLoopPolicy {
    enum Step: Equatable { case `continue`, cancelled, settled, timedOut }
    static func next(cancelled: Bool, settled: Bool, remaining: TimeInterval) -> Step {
        if cancelled { return .cancelled }
        if settled { return .settled }
        if remaining <= 0 { return .timedOut }
        return .continue
    }
}

@MainActor private final class CaptureDeadlineGate {
    private var finished = false
    private let continuation: CheckedContinuation<PageState?, Never>
    init(_ continuation: CheckedContinuation<PageState?, Never>) { self.continuation = continuation }
    func finish(_ page: PageState?) {
        guard !finished else { return }
        finished = true
        continuation.resume(returning: page)
    }
}

/// 弹窗 frame 探针的消息中枢（WECHAT-COVER-FIX）：探针脚本注入在每个
/// frame 里，各 frame 的回報（probe-report／click-report）经消息处理器
/// 到达这里；按（webView 身份＋本次探查 token）匹配正在等待的收集者，
/// 不匹配的一律丢弃——页面自己 postMessage 伪造同名消息也进不来
/// （token 每次探查随机生成、只在 App 内存里）。收集者由 WebController
/// 的 probeFrames／dispatchFrameClick 注册、超时后注销。
@MainActor final class FrameProbeHub {
    static let shared = FrameProbeHub()
    private struct Pending {
        let webViewID: ObjectIdentifier
        let handler: ([String: Any]) -> Void
    }
    private var pendings: [String: Pending] = [:]

    func register(webView: WKWebView, token: String, handler: @escaping ([String: Any]) -> Void) {
        pendings[token] = Pending(webViewID: ObjectIdentifier(webView), handler: handler)
    }

    func unregister(token: String) { pendings[token] = nil }

    func deliver(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let token = body["token"] as? String,
              let pending = pendings[token],
              let webView = message.webView,
              ObjectIdentifier(webView) == pending.webViewID else { return }
        pending.handler(body)
    }
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
    /// WECHAT-COVER-FIX 起同一装配点一并装弹窗 frame 探针（handler 与
    /// 脚本），TRUSTED-CLICK-EXP 起再加可信点按只读插桩（同理）：三者
    /// 共用「每 controller 只装一次」的守卫——在共享 controller 上重复
    /// 注册同名 handler 同样会抛异常致 abort，绝不能另起一套逐标签
    /// 注册。
    func equip(_ controller: WKUserContentController) {
        guard !equippedControllers.contains(controller) else { return }
        controller.removeScriptMessageHandler(forName: BrowserTab.webAuthnHandlerName, contentWorld: .page)
        controller.add(self, contentWorld: .page, name: BrowserTab.webAuthnHandlerName)
        controller.addUserScript(WKUserScript(source: BrowserTab.webAuthnProbeScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        controller.removeScriptMessageHandler(forName: BrowserTab.frameProbeHandlerName, contentWorld: .page)
        controller.add(self, contentWorld: .page, name: BrowserTab.frameProbeHandlerName)
        controller.addUserScript(WKUserScript(source: BrowserTab.frameProbeScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        controller.removeScriptMessageHandler(forName: BrowserTab.tcProbeHandlerName, contentWorld: .page)
        controller.add(self, contentWorld: .page, name: BrowserTab.tcProbeHandlerName)
        controller.addUserScript(WKUserScript(source: BrowserTab.tcProbeScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        equippedControllers.add(controller)
    }

    func associate(tab: BrowserTab) {
        tabsByWebView[ObjectIdentifier(tab.webView)] = WeakTabBox(tab)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // frame 探针与可信点按插桩消息不归标签页处理：按 token 交给
        // 探针中枢的收集者（中枢按 token＋webView 身份匹配，两探针共用）
        if message.name == BrowserTab.frameProbeHandlerName || message.name == BrowserTab.tcProbeHandlerName {
            FrameProbeHub.shared.deliver(message)
            return
        }
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
// 实例与页面状态由本对象强持有保留、不重载；网页进程被系统内存压力杀掉时，
// 只通知引擎，由引擎统一预算调度恢复。
@MainActor final class BrowserTab: NSObject, ObservableObject, WKNavigationDelegate, Identifiable {
    let id = UUID()
    /// 所属会话（M1，2026-11-02）：标签归属会话——切会话只换可见标签集合，
    /// 其余会话的标签保留在管理器里隐藏、不销毁、不重载。创建时由
    /// WebController 按语境指定（查看会话／执行会话／opener 所在会话）。
    var sessionID: UUID
    /// 置顶（M1）：纯元数据——在标签列表里排前、关闭被守卫拒绝（见
    /// WebController.closeTab，含任何批量关闭路径，须先取消置顶才能关）。
    /// 不承诺网页进程永驻：进程被系统回收时由引擎调度恢复。
    @Published var isPinned = false
    let webView: WKWebView
    @Published private(set) var urlString = ""
    @Published private(set) var title = ""
    @Published private(set) var estimatedProgress = 0.0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published var pageError: String?
    private(set) var revision = 0
    private(set) var documentEpoch = 0
    private var observations: [NSKeyValueObservation] = []
    /// 网页进程终止时 webView.url 可能已被清空，保留最后已知地址供后续导航使用。
    private var lastKnownURL: URL?
    private(set) var terminatedAt: Date?
    var onContentProcessTerminated: ((BrowserTab) -> Void)?

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

    static let frameProbeHandlerName = "mikaFrameProbe"

    /// 弹窗 frame 探针脚本（WECHAT-COVER-FIX）：注入每个 frame（含跨源
    /// iframe——evaluateJavaScript 只能进主 frame，跨源 frame 的 DOM 从
    /// 主 frame 读不到，唯有预先注入各 frame 的脚本能自查自报）。职责：
    /// ①收到 probe 指令（主 frame 经 window.postMessage 洪泛、每层 frame
    /// 自行向下转发，保证整棵 frame 树都被问到）后，枚举本 frame 内的
    /// 弹窗容器与其按钮特征并回報（含本 frame 的路径、地址、子 frame 数）；
    /// ②收到 click 指令时，只有真正持有「带目标文案按钮的弹窗」的 frame
    /// 出手：在本 frame 内按阶段尝试关闭（完整 pointer 序列→触摸序列→
    /// Escape→关闭叉号→遮罩点击），每阶段后以弹窗元素消失为唯一成功
    /// 判据轮询回讀；出手前重跑与主 frame 同口径的安全词检查。探针只做
    /// 证据与受控点按，不改页面其他语义。
    static let frameProbeScript = #"""
    (function(){
      if (window.__mikaFrameProbe) return;
      window.__mikaFrameProbe = true;
      var post = function(payload){ try { window.webkit.messageHandlers.mikaFrameProbe.postMessage(payload); } catch (e) {} };
      var vis = function(x){ if(!x || !x.getBoundingClientRect) return false; var r=x.getBoundingClientRect(), s=getComputedStyle(x); return r.width>0 && r.height>0 && s.visibility!=='hidden' && s.display!=='none'; };
      var lab = function(x){ return ((x.innerText||x.value||x.getAttribute('aria-label')||'')+'').replace(/\s+/g,' ').trim(); };
      var norm = function(s){ return (s||'').replace(/\s+/g,' ').trim().toLowerCase(); };
      var clsOf = function(x){ return ((typeof x.className==='string') ? x.className : '') + ''; };
      var dlgKey = /dialog|modal|popup|pop-|layer|mask|overlay|alert|confirm/;
      var isDialog = function(n){
        if (!n || n===document.body || n===document.documentElement) return false;
        if (n.tagName==='DIALOG' && n.open) return true;
        var role = n.getAttribute ? n.getAttribute('role') : null;
        if (role==='dialog' || role==='alertdialog') return true;
        if (n.getAttribute && n.getAttribute('aria-modal')==='true') return true;
        var s; try { s = getComputedStyle(n); } catch (e) { return false; }
        if (s.position==='fixed' || s.position==='absolute'){
          if (dlgKey.test((clsOf(n)+' '+(n.id||'')).toLowerCase())) return true;
        }
        return false;
      };
      var dialogElements = function(){
        var out = [], seen = [];
        var all = document.querySelectorAll('dialog,[role="dialog"],[role="alertdialog"],[aria-modal="true"],div,section,aside');
        for (var i=0;i<all.length;i++){
          var d = all[i];
          if (!vis(d) || !isDialog(d) || seen.indexOf(d)>=0) continue;
          seen.push(d); out.push(d);
        }
        return out;
      };
      var dialogSig = function(d){ return (d.id ? '#'+d.id : d.tagName.toLowerCase()) + '|' + clsOf(d).slice(0,60) + '|' + lab(d).slice(0,30); };
      var describeDialog = function(d){
        var btns = [], cands = d.querySelectorAll('button,[role="button"],a,input[type="button"],input[type="submit"]');
        for (var j=0;j<cands.length && btns.length<8;j++){
          var c = cands[j]; if (!vis(c)) continue;
          btns.push({ label: lab(c).slice(0,40), tag: c.tagName.toLowerCase(), cls: clsOf(c).slice(0,60) });
        }
        var r = d.getBoundingClientRect();
        return { sig: dialogSig(d), tag: d.tagName.toLowerCase(), role: d.getAttribute('role') || '', cls: clsOf(d).slice(0,80), text: lab(d).slice(0,80), rect: [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)], buttons: btns };
      };
      var framePath = function(){
        var path = [], w = window;
        try {
          while (w !== w.parent){
            var p = w.parent, idx = -1;
            for (var i=0;i<p.frames.length;i++){ if (p.frames[i]===w){ idx = i; break; } }
            if (idx < 0) return 'partial';
            path.unshift(idx); w = p;
          }
        } catch (e) { return 'unknown'; }
        return path.length ? path.join('.') : 'top';
      };
      var hrefSafe = function(){ try { return location.href; } catch (e) { return ''; } };
      var dispatchAt = function(el, step, x, y){
        var down = step==='pointerdown' || step==='mousedown';
        var opts = { bubbles:true, composed:true, cancelable:true, clientX:x, clientY:y, button:0, buttons:down?1:0, view:window };
        var ev = null;
        if (step.indexOf('pointer')===0){
          try { ev = new PointerEvent(step, Object.assign({}, opts, { pointerId:1, pointerType:'mouse', isPrimary:true })); } catch (e) {}
          if (!ev){ try { ev = new MouseEvent(step, opts); } catch (e2) {} }
        } else {
          try { ev = new MouseEvent(step, opts); } catch (e) {}
        }
        if (ev) el.dispatchEvent(ev);
      };
      var seqOn = function(el, kind, done, point){
        var steps = kind==='touch' ? ['touchstart','touchend','click']
                                   : ['pointerover','pointerdown','mousedown','focus','pointerup','mouseup','click'];
        var i = 0;
        var next = function(){
          if (i >= steps.length){ done(); return; }
          var step = steps[i++];
          try {
            var r = el.getBoundingClientRect();
            var x = point ? point.x : r.left + r.width/2;
            var y = point ? point.y : r.top + r.height/2;
            if (!point){ try { el.scrollIntoView({ block:'center' }); } catch (e) {} }
            if (step==='focus'){ try { el.focus(); } catch (e) {} }
            else if (step==='click'){ el.click(); }
            else if (step.indexOf('touch')===0){
              var t = null;
              try { t = new Touch({ identifier:1, target:el, clientX:x, clientY:y }); } catch (e) {}
              var topts = { bubbles:true, composed:true, cancelable:true, touches: step==='touchend' ? [] : (t ? [t] : []), changedTouches: t ? [t] : [] };
              el.dispatchEvent(new TouchEvent(step, topts));
            }
            else { dispatchAt(el, step, x, y); }
          } catch (e) {}
          setTimeout(next, 70);
        };
        next();
      };
      var dialogGone = function(dlg){ return !dlg.isConnected || !vis(dlg); };
      var pollGone = function(dlg, ms, cb){
        var end = Date.now() + ms;
        var chk = function(){
          if (dialogGone(dlg)){ cb(true); return; }
          if (Date.now() > end){ cb(false); return; }
          setTimeout(chk, 150);
        };
        chk();
      };
      var findCloser = function(dlg, mainBtn){
        var cands = dlg.querySelectorAll('button,[role="button"],a,span,i');
        for (var i=0;i<cands.length;i++){
          var c = cands[i];
          if (c===mainBtn || !vis(c)) continue;
          var t = norm(lab(c)), a = norm(c.getAttribute('aria-label') || ''), cl = clsOf(c).toLowerCase();
          if (t==='×' || t==='✕' || t==='关闭' || a.indexOf('关闭')>=0 || a.indexOf('close')>=0 || /close|dismiss/.test(cl)) return c;
        }
        return null;
      };
      var maskClick = function(dlg, cb){
        var node = dlg, target = null;
        while (node && node !== document.body){
          var r = node.getBoundingClientRect();
          if (r.width >= window.innerWidth*0.9 && r.height >= window.innerHeight*0.9){ target = node; break; }
          node = node.parentElement;
        }
        if (!target){ cb(); return; }
        var el = target;
        try { el = document.elementFromPoint(10, 10) || target; } catch (e) {}
        seqOn(el, 'pointer', cb, { x: 10, y: 10 });
      };
      var handleClick = function(d){
        var want = norm(d.label);
        var dlg = null, btn = null, elements = dialogElements();
        for (var i=0;i<elements.length;i++){
          var cands = elements[i].querySelectorAll('button,[role="button"],a,input[type="button"],input[type="submit"]');
          for (var j=0;j<cands.length;j++){
            if (vis(cands[j]) && norm(lab(cands[j]))===want){ dlg = elements[i]; btn = cands[j]; break; }
          }
          if (dlg) break;
        }
        if (!dlg || !btn) return;
        var labelText = norm(lab(btn));
        var keywords = d.keywords || [];
        for (var k=0;k<keywords.length;k++){
          if (!d.approved && labelText.indexOf(keywords[k])>=0){
            post({ kind:'click-report', token:d.token, path:framePath(), href:hrefSafe(), clicked:false, gone:false, stage:'refused-sensitive', stages:[] });
            return;
          }
        }
        var stages = [];
        var finish = function(gone, stage){
          post({ kind:'click-report', token:d.token, path:framePath(), href:hrefSafe(), clicked:true, gone:gone, stage:stage, stages:stages, sig:dialogSig(dlg) });
        };
        var plan = [
          function(cb){ stages.push('pointer-sequence'); seqOn(btn, 'pointer', function(){ pollGone(dlg, 900, cb); }); },
          function(cb){ if (dialogGone(dlg)) return cb(true); stages.push('touch-sequence'); seqOn(btn, 'touch', function(){ pollGone(dlg, 900, cb); }); },
          function(cb){ if (dialogGone(dlg)) return cb(true); stages.push('escape');
            try {
              var opts = { bubbles:true, composed:true, cancelable:true, key:'Escape', code:'Escape', keyCode:27, which:27 };
              document.dispatchEvent(new KeyboardEvent('keydown', opts));
              if (document.activeElement) document.activeElement.dispatchEvent(new KeyboardEvent('keydown', opts));
              dlg.dispatchEvent(new KeyboardEvent('keydown', opts));
              document.dispatchEvent(new KeyboardEvent('keyup', opts));
            } catch (e) {}
            pollGone(dlg, 700, cb); },
          function(cb){ if (dialogGone(dlg)) return cb(true); var closer = findCloser(dlg, btn); if (!closer) return cb(false); stages.push('close-affordance'); seqOn(closer, 'pointer', function(){ pollGone(dlg, 900, cb); }); },
          function(cb){ if (dialogGone(dlg)) return cb(true); stages.push('mask-click'); maskClick(dlg, function(){ pollGone(dlg, 900, cb); }); }
        ];
        var run = function(i){
          if (i >= plan.length){ finish(false, 'none'); return; }
          plan[i](function(gone){
            if (gone){ finish(true, stages[stages.length-1]); }
            else { run(i+1); }
          });
        };
        run(0);
      };
      var collectHarvest = function(){
        var hrefs = [], dataAttrs = [], onclicks = [], embedded = [], embeddedObjs = [], domPairs = [];
        var links = document.querySelectorAll('a[href]');
        for (var i=0;i<links.length && hrefs.length<400;i++){ var h = links[i].getAttribute('href'); if (h) hrefs.push(h); }
        var all = document.querySelectorAll('*');
        for (var j=0;j<all.length && j<6000;j++){
          var e = all[j];
          if (e.attributes){
            for (var k=0;k<e.attributes.length;k++){
              var at = e.attributes[k], v = at.value || '';
              if (at.name.indexOf('data-')===0 && (v.indexOf('appmsg')>=0 || v.indexOf('://')>=0 || at.name.indexOf('msgid')>=0 || /^\d{5,}$/.test(v))){
                if (dataAttrs.length<120) dataAttrs.push({ name:at.name, value:v.slice(0,600) });
              }
              // 卡片 DOM 配对（EDITOR-ENTRY-BIND）：msgid 类属性是纯
              // 数字 ID 时，沿祖先链在同一卡片容器内找标题文本——
              // 标题与 ID 同卡共现才交回，宿主侧记为配对实证；找不
              // 到标题就不交（不按卡片顺序与任何列表对位猜测）。
              if (at.name.indexOf('msgid')>=0 && /^\d{5,}$/.test(v) && domPairs.length<40){
                var card = e, cardTitle = '';
                for (var up=0; up<6 && card && !cardTitle; up++){
                  if (card.querySelector){
                    var tel = card.querySelector('[class*="title"],[class*="Title"],h3,h4') || card.querySelector('a');
                    if (tel){ var tt = (tel.textContent||'').replace(/\s+/g,' ').trim(); if (tt) cardTitle = tt.slice(0,120); }
                  }
                  card = card.parentElement;
                }
                if (cardTitle) domPairs.push({ title:cardTitle, id:v });
              }
            }
          }
          var oc = e.getAttribute ? e.getAttribute('onclick') : null;
          if (oc && (oc.indexOf('appmsg')>=0 || oc.indexOf('http')>=0) && onclicks.length<120) onclicks.push(oc.slice(0,600));
        }
        var scripts = document.querySelectorAll('script:not([src])');
        for (var s=0;s<scripts.length && embedded.length<60;s++){
          var t = scripts[s].textContent || '';
          if (t.indexOf('appmsg')<0) continue;
          var m = t.match(/[^\s"'<>]*appmsg[^\s"'<>]*/g) || [];
          for (var q=0;q<m.length && embedded.length<60;q++) embedded.push(m[q].slice(0,600));
        }
        // 内嵌数据对象窗口（EDITOR-ENTRY-BIND）：旧 embedded 只截
        // 含 appmsg 的 URL 形片段，标题与 ID 的配对关系全丢——草稿
        // 列表页的数据对象里两者同对象共存，必须把对象原文带回
        // 宿主做同对象配对提取。以 appmsgid 类键出现点为锚截
        // 前后各 2400 字（单个条目对象远小于此窗），每 frame 至
        // 多 30 窗；宿主侧按括号配平找对象跨度、ID 唯一才成对。
        for (var s2=0;s2<scripts.length && embeddedObjs.length<30;s2++){
          var t2 = scripts[s2].textContent || '';
          if (t2.indexOf('appmsgid')<0 && t2.indexOf('appmsg_id')<0 && t2.indexOf('app_id')<0) continue;
          var re2 = /appmsgid|appmsg_id|app_id/g, mm2;
          while ((mm2 = re2.exec(t2)) !== null && embeddedObjs.length<30){
            var a2 = Math.max(0, mm2.index-2400), b2 = Math.min(t2.length, mm2.index+2400);
            embeddedObjs.push(t2.slice(a2, b2));
          }
        }
        return { hrefs:hrefs, dataAttrs:dataAttrs, onclicks:onclicks, embedded:embedded, embeddedObjs:embeddedObjs, domPairs:domPairs };
      };
      window.addEventListener('message', function(ev){
        var d = ev.data;
        if (!d || d.__mikaFrame !== 1) return;
        for (var i=0;i<window.frames.length;i++){ try { window.frames[i].postMessage(d, '*'); } catch (e) {} }
        if (d.kind === 'probe'){
          var dialogs = dialogElements().map(describeDialog);
          post({ kind:'probe-report', token:d.token, path:framePath(), href:hrefSafe(), isTop: window===window.top, children: window.frames.length, dialogs:dialogs });
        } else if (d.kind === 'click'){
          handleClick(d);
        } else if (d.kind === 'harvest'){
          var hv = collectHarvest();
          post({ kind:'harvest-report', token:d.token, path:framePath(), href:hrefSafe(), hrefs:hv.hrefs, dataAttrs:hv.dataAttrs, onclicks:hv.onclicks, embedded:hv.embedded, embeddedObjs:hv.embeddedObjs, domPairs:hv.domPairs });
        }
      });
    })();
    """#

    static let tcProbeHandlerName = "mikaTCProbe"

    /// 可信点按实验的只读插桩脚本（TRUSTED-CLICK-EXP，E1）：随 frame
    /// 探针同一装配点注入每个 frame（含跨源），默认未武装、零记录；
    /// 收到带 token 的 arm 洪泛后才开始记录，dump 时按 token 回報、
    /// disarm 后停记。只读性：监听全部走捕获阶段＋passive，从不
    /// preventDefault／stopPropagation；MutationObserver 只观察。
    /// 记录面刻意收窄：只记事件元数据（type／目标形态／isTrusted／
    /// touches 长度／pointerId／pressure／timeStamp）与 DOM 变化计数；
    /// 表单控件只记 tag 与 type，绝不记 value／文本（凭据安全）；
    /// 一般元素只记截断 24 字的 aria-label 或文本（按钮文案级信息，
    /// 与 frame 探针的按钮特征同口径）。用途：E1 金标准对照——真机
    /// 现场先装插桩，Joey 真点一次与合成序列重放逐字段 diff，把
    /// 「点按无响应」的成因收敛到 MEMO §6 九类表中的具体类别。
    static let tcProbeScript = #"""
    (function(){
      if (window.__mikaTCProbe) return;
      window.__mikaTCProbe = true;
      var post = function(payload){ try { window.webkit.messageHandlers.mikaTCProbe.postMessage(payload); } catch (e) {} };
      var armed = null;
      var events = [];
      var mutations = [];
      var truncated = false;
      var MAXE = 1000, MAXM = 300;
      var framePath = function(){
        var p = [], w = window;
        try {
          while (w !== w.parent){
            var par = w.parent, idx = -1;
            for (var i = 0; i < par.frames.length; i++){ if (par.frames[i] === w){ idx = i; break; } }
            if (idx < 0) return 'partial';
            p.unshift(idx); w = par;
          }
        } catch (e) { return 'unknown'; }
        return p.length ? p.join('.') : 'top';
      };
      var hrefSafe = function(){ try { return location.href; } catch (e) { return ''; } };
      var desc = function(el){
        if (!el || !el.tagName) return { tag: '?' };
        var d = { tag: el.tagName.toLowerCase() };
        if (el.id) d.id = ('' + el.id).slice(0, 40);
        var cls = (typeof el.className === 'string') ? el.className : '';
        if (cls) d.cls = cls.slice(0, 60);
        var role = el.getAttribute ? el.getAttribute('role') : null;
        if (role) d.role = role;
        if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT'){
          var t = el.getAttribute ? el.getAttribute('type') : null;
          if (t) d.inputType = t;
          return d;
        }
        var lab = '';
        try { lab = (el.getAttribute && el.getAttribute('aria-label')) || el.innerText || ''; } catch (e) {}
        lab = ('' + lab).replace(/\s+/g, ' ').trim();
        if (lab) d.label = lab.slice(0, 24);
        return d;
      };
      var TYPES = ['pointerover','pointerdown','pointerup','pointercancel','mousedown','mouseup','click','touchstart','touchend','touchcancel','keydown','keyup'];
      var record = function(e){
        if (!armed) return;
        if (events.length >= MAXE){ truncated = true; return; }
        var r = { type: e.type, target: desc(e.target), trusted: !!e.isTrusted, ts: e.timeStamp, wall: Date.now() };
        if (e.changedTouches) r.ct = e.changedTouches.length;
        if (e.touches) r.t = e.touches.length;
        if (typeof e.pointerId === 'number') r.pid = e.pointerId;
        if (e.pointerType) r.ptype = e.pointerType;
        if (typeof e.pressure === 'number') r.pressure = e.pressure;
        if (typeof e.isPrimary === 'boolean') r.primary = e.isPrimary;
        events.push(r);
      };
      for (var i = 0; i < TYPES.length; i++){
        document.addEventListener(TYPES[i], record, { capture: true, passive: true });
      }
      var observer = null;
      var startObserver = function(){
        if (observer) return;
        try {
          observer = new MutationObserver(function(list){
            if (!armed) return;
            for (var i = 0; i < list.length; i++){
              if (mutations.length >= MAXM){ truncated = true; break; }
              var m = list[i];
              mutations.push({ kind: m.type, target: desc(m.target), added: m.addedNodes ? m.addedNodes.length : 0, removed: m.removedNodes ? m.removedNodes.length : 0, attr: m.attributeName || null });
            }
          });
          observer.observe(document, { childList: true, subtree: true, attributes: true });
        } catch (e) { observer = null; }
      };
      var stopObserver = function(){ if (observer){ try { observer.disconnect(); } catch (e) {} observer = null; } };
      window.addEventListener('message', function(ev){
        var d = ev.data;
        if (!d || d.__mikaTC !== 1) return;
        for (var i = 0; i < window.frames.length; i++){ try { window.frames[i].postMessage(d, '*'); } catch (e) {} }
        if (d.kind === 'arm'){
          armed = d.token; events = []; mutations = []; truncated = false; startObserver();
        } else if (d.kind === 'dump'){
          if (armed && d.token === armed){
            post({ kind: 'tc-report', token: d.token, path: framePath(), href: hrefSafe(), isTop: window === window.top, events: events, mutations: mutations, truncated: truncated });
          }
        } else if (d.kind === 'disarm'){
          if (d.token === armed){ armed = null; stopObserver(); }
        }
      });
    })();
    """#

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
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { documentEpoch += 1 }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        update()
        // Cookie 备份／回注（ADOPTION-TOP3 第 1 条）：真实导航完成即记访问（老化
        // 时钟）并节流同步一次——用户手动建立的登录态及时入备份，ITP 静默清除
        // 后的回注也借导航时机发生，不必等 agent 任务才恢复。
        CookieBackup.shared.noteVisit(url: webView.url)
        Task { @MainActor in await CookieBackup.shared.syncIfNeeded(store: WKWebsiteDataStore.default().httpCookieStore) }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { documentEpoch += 1; pageError = error.localizedDescription; update() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { pageError = error.localizedDescription; update() }
    /// 系统杀掉网页进程时只记事件并通知引擎；恢复由引擎统一预算调度，
    /// 此处不自作主张重载（页面的 JS／表单状态已丢失）。
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let url = webView.url { lastKnownURL = url }
        terminatedAt = Date()
        documentEpoch += 1
        revision += 1
        pageError = "网页进程终止"
        onContentProcessTerminated?(self)
    }
}

/// 可信点按实验结构化日志的落盘与导出（TRUSTED-CLICK-EXP）：每次
/// 自检二十把 E1 插桩 dump 与 E2 探针结果合成一份 JSON 写到
/// Application Support/MikaWeb/TrustedClick/tc-exp-<时间>.json；
/// 真机 E1 金标准（真实弹窗现场）走同一通道落盘，文件名即采集凭据。
/// 自检页提供最近一份的分享导出入口。内容只含实验元数据（事件
/// 字段与判定），不含凭据类页面数据（插桩记录面本身已收窄）。
enum TCProbeLogStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MikaWeb/TrustedClick", isDirectory: true)
    }

    static func save(payload: [String: Any]) -> String? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = ISO8601DateFormatter()
            let name = "tc-exp-" + formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-") + ".json"
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            return name
        } catch { return nil }
    }

    static func latestURL() -> URL? {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }.first
    }
}

/// 文件面板回退选择器（COVER-UPLOAD-FIX D）：iOS 18.4+ 上宿主一旦
/// 实现 runOpenPanel 回调，WebKit 就不再自弹系统选择器——没有武装
/// 待供文件时（用户手动点页面上传按钮、或 upload_file 未解析到具体
/// 附件要现选），由本协调器弹标准选择面补回「用户自己选」：动作表
/// 二选一（照片图库 PhotosPicker／文件 UIDocumentPicker，两者都是
/// 系统公开选择器、无新依赖）。选出的文件先落进 App 临时目录再把
/// URL 交给 WebKit（选择器给的临时/安全域 URL 只在回调期内有效，
/// 直接转发会让 WebKit 读不到）。取消一律回 nil（＝面板取消语义）。
/// 相机入口未提供：WebKit 自带面板的「拍照」选项在此无法等价复刻，
/// agent 场景用不到，缺失如实记在案卷。
@available(iOS 18.4, *)
@MainActor final class OpenPanelFallback: NSObject, UIDocumentPickerDelegate, PHPickerViewControllerDelegate {
    private static var active: OpenPanelFallback?
    private var completion: (([URL]?) -> Void)?
    private var allowsMultiple = false

    static func present(parameters: WKOpenPanelParameters, from webView: WKWebView, completion: @escaping ([URL]?) -> Void) {
        guard let presenter = topPresenter() else { completion(nil); return }
        let session = OpenPanelFallback()
        session.completion = completion
        session.allowsMultiple = parameters.allowsMultipleSelection
        active = session
        let sheet = UIAlertController(title: "选择要上传的文件", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "从照片图库选择", style: .default) { _ in session.presentPhotoPicker(from: presenter) })
        sheet.addAction(UIAlertAction(title: "从文件选择", style: .default) { _ in session.presentDocumentPicker(from: presenter) })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in session.finish(nil) })
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = webView
            popover.sourceRect = CGRect(x: webView.bounds.midX, y: webView.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        presenter.present(sheet, animated: true)
    }

    private static func topPresenter() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        let window = windows.first { $0.isKeyWindow } ?? windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    private func presentPhotoPicker(from presenter: UIViewController) {
        var config = PHPickerConfiguration()
        config.filter = .any(of: [.images, .videos])
        config.selectionLimit = allowsMultiple ? 0 : 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        presenter.present(picker, animated: true)
    }

    private func presentDocumentPicker(from presenter: UIViewController) {
        // asCopy：系统先把文件拷进 App 容器再给 URL——普通安全域 URL
        // 在回调后即失效，WebKit 随后读取会落空，asCopy 的 URL 才稳。
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = allowsMultiple
        picker.delegate = self
        presenter.present(picker, animated: true)
    }

    // PHPickerViewControllerDelegate
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { finish(nil); return }
        Task { @MainActor in
            var urls: [URL] = []
            for result in results {
                if let url = await Self.loadPickedFile(result.itemProvider) { urls.append(url) }
            }
            finish(urls.isEmpty ? nil : urls)
        }
    }

    /// 图库条目 → App 临时目录里的真实文件 URL：loadFileRepresentation
    /// 给的临时 URL 只在回调期内有效，回调内同步拷走再交出去。
    private static func loadPickedFile(_ provider: NSItemProvider) async -> URL? {
        guard let typeID = provider.registeredTypeIdentifiers.first else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, _ in
                guard let url else { continuation.resume(returning: nil); return }
                let ext = url.pathExtension.isEmpty ? "dat" : url.pathExtension
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("panel-\(UUID().uuidString).\(ext)")
                continuation.resume(returning: (try? FileManager.default.copyItem(at: url, to: dest)) != nil ? dest : nil)
            }
        }
    }

    // UIDocumentPickerDelegate
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finish(allowsMultiple ? urls : Array(urls.prefix(1)))
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(nil) }

    private func finish(_ urls: [URL]?) {
        let completion = self.completion
        self.completion = nil
        if Self.active === self { Self.active = nil }
        completion?(urls)
    }
}

// 浏览器标签管理器＋当前页门面（标签页改造前的 WebController API 逐个保留、语义改为
// 「作用于当前标签页」，既有调用点 BrowserView／BrowserDockView／AgentEngine 不需改签名）：
// address／progress／canGoBack／canGoForward／pageError／revision／webView／load／reload／
// goBack／goForward／evaluate 均为当前页门面；state／execute 则路由到「执行页」——任务开始
// 时由 AgentEngine 捕获的标签页（executionTabID），用户中途手动切页不影响正在跑的任务。
@MainActor final class WebController: NSObject, ObservableObject, WKUIDelegate {
    private var clickGuardCache: ClickGuardCacheKey?
    struct ClickEffect: Equatable {
        let urlChanged: Bool
        let contentChanged: Bool
    }

    private struct ClickSignature: Equatable {
        let url: String
        let elementCount: Int
        let textHash: Int
    }

    /// 每次 click 执行前清空；只供串行引擎在成功后读取，不参与动作结果。
    private(set) var lastClickEffect: ClickEffect?
    private(set) var lastClickEffectMissingBefore = false
    private var lastClickDispatchedAt: Date?
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
    var contentProcessTerminationHandler: ((BrowserTab) -> Void)?
    var agentPopupCreated: ((UUID, UUID) -> Void)?
    var tabClosed: ((UUID) -> Void)?
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
        tab.onContentProcessTerminated = { [weak self] tab in
            self?.contentProcessTerminationHandler?(tab)
        }
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

    /// L1 display snapshot. Failure deliberately returns nil so the card falls
    /// back to its title/status gradient instead of exposing a blank surface.
    func floatingCardSnapshot() async -> UIImage? {
        await withCheckedContinuation { continuation in
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = false
            activeTab.webView.takeSnapshot(with: configuration) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

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
        tabClosed?(id)
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
    /// Rebind before recycling an execution tab. Never choose another registered temporary tab.
    func restoreExecutionBinding(preferred sourceID: UUID, excluding excluded: Set<UUID>) -> Bool {
        guard let owner = executionSessionID else { return false }
        let target = tabs.first { $0.id == sourceID && $0.sessionID == owner && !excluded.contains($0.id) }
            ?? tabs.first { $0.sessionID == owner && !excluded.contains($0.id) }
        guard let target else { return false }
        executionTabID = target.id
        return true
    }
    /// A failed or incomplete extraction means the page may contain unsaved edits.
    func readbackTabMayContainEdits(_ id: UUID) async -> Bool {
        guard let tab = tabs.first(where: { $0.id == id }), !tab.isPinned,
              tab.pendingRestoreURL == nil, tab.terminatedAt == nil,
              !tab.webView.isLoading else { return true }
        guard let page = try? await state(in: tab, forCapture: true), page.coverageComplete else { return true }
        return page.elements.contains { element in
            element.editable || element.tag == "textarea" || element.tag == "select" ||
            (element.tag == "input" && !["button", "submit", "reset", "checkbox", "radio", "hidden"].contains(element.inputType.lowercased()))
        }
    }
    /// 执行页重载（引擎在页面瞬时失败连败时用）：作用于执行页而非当前页，用户切页不串。
    func reloadExecutionTab() { executionTab.reload() }

    // MARK: - 网页上传人在环（F1）：触发文件控件与回读已选文件
    //
    // iOS 平台事实（COVER-UPLOAD-FIX 调研修正）：文件面板回调
    // WKUIDelegate.runOpenPanelWithParameters 长期只有 macOS 有
    // （10.12 起）；iOS 自 18.4 起公开同一回调（WebKit 源码头文件
    // WK_API_AVAILABLE(macos(10.12), ios(18.4), visionos(2.4)) 为据，
    // 详见案卷 COVER-UPLOAD-FIX-IMPL 调研节）。iOS 18.4+ 上宿主实现
    // 该回调即可在文件面板被请求时直接把文件 URL 交给页面（见下方
    // 「文件面板供文件」节），或自行弹选择器转发结果；不实现则与
    // Safari 行为一致（系统选择器）。18.4 以下无此回调：文件控件被
    // 真实点击时由 WebKit 拉起系统选择器，用户选完后文件挂在
    // input.files 上、页面自己负责后续提交。合成 click 是否被当作
    // 可拉起面板的手势由系统决定（部分场景不认）——所以触发只算
    // 「尝试打开」，引擎无论结果都进等待卡兜底。

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

    /// 文件控件形态诊断（EDITOR-ENTRY-BIND 第 4 项）：upload_file 步
    /// 流的结构化记录原料——目标控件在哪里、页面里还有多少个文件
    /// 控件。所在层口径：正文主 DOM／正文插入面板（工具栏区）／弹
    /// 窗内；定位不到时给出主文档与同源 frame 的控件计数——封面菜
    /// 单一类「根本不是 file input」的入口（公众号编辑器封面区二
    /// 级菜单只有从正文选择/从图片库选择/扫码上传/一键生成、无本
    /// 地上传，2026-11-03 真机实证）会落在这一支，步流据此可直接
    /// 判「无本地入口」而非笼统的「回读未确认」。只读元数据。
    func fileInputContext(index: Int) async -> String {
        let tab = executionTab
        let script = """
        (()=>{const out={found:false,idxTag:'',mainFileInputs:0,frames:0,frameFileInputs:0,crossOriginFrames:0,hidden:false,accept:'',layer:''};
        const countFI=(doc)=>{let n=0;try{doc.querySelectorAll('input[type="file"]').forEach(()=>n++);}catch(e){}return n;};
        out.mainFileInputs=countFI(document);
        document.querySelectorAll('iframe').forEach(f=>{out.frames++;try{const d=f.contentDocument;if(d)out.frameFileInputs+=countFI(d);else out.crossOriginFrames++;}catch(e){out.crossOriginFrames++;}});
        const e=document.querySelector('[data-mika-idx="\(index)"]');
        if(e){out.idxTag=e.tagName.toLowerCase()+'/'+(e.type||'');
          if(e.tagName==='INPUT'&&e.type==='file'){out.found=true;
            const cs=getComputedStyle(e);out.hidden=(cs.display==='none'||cs.visibility==='hidden');
            out.accept=e.getAttribute('accept')||'';
            const dlg=e.closest('[role="dialog"],dialog,[class*="dialog"],[class*="Dialog"],[class*="modal"],[class*="Modal"],[class*="popup"],[class*="Popup"]');
            if(dlg){out.layer='弹窗内（'+(((dlg.getAttribute('class')||dlg.tagName)+'').slice(0,40))+'）';}
            else{out.layer='正文主 DOM';let a=e;for(let i=0;i<6&&a;i++){a=a.parentElement;if(a&&/toolbar|insert|editor/i.test((a.className||'')+'')){out.layer='正文插入面板/工具栏区';break;}}}
          }}
        return JSON.stringify(out);})()
        """
        guard let raw = try? await evaluate(script, on: tab) as? String,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "控件形态读取失败（页面脚本未回報）"
        }
        let found = (obj["found"] as? Bool) ?? false
        let main = (obj["mainFileInputs"] as? Int) ?? 0
        let frameFI = (obj["frameFileInputs"] as? Int) ?? 0
        let frames = (obj["frames"] as? Int) ?? 0
        let cross = (obj["crossOriginFrames"] as? Int) ?? 0
        if found {
            let hidden = (obj["hidden"] as? Bool) ?? false
            let accept = (obj["accept"] as? String) ?? ""
            let layer = (obj["layer"] as? String) ?? "正文主 DOM"
            return "控件所在层＝\(layer)；呈现＝\(hidden ? "隐藏（站点惯例，label/按钮冒充入口）" : "可见")；accept＝\(accept.isEmpty ? "未限定" : accept)；页面 file input 分布：主文档 \(main) 个、同源 frame \(frameFI) 个（iframe \(frames) 个）"
        }
        let idxTag = (obj["idxTag"] as? String) ?? ""
        return "目标序号处\(idxTag.isEmpty ? "无元素" : "是 \(idxTag)、不是 file input")；页面 file input 分布：主文档 \(main) 个、同源 frame \(frameFI) 个（iframe \(frames) 个、跨源不可读 \(cross) 个）——控件可能在跨源 frame 内/未渲染，或该入口根本不是 file input（封面菜单无本地入口即属此类）"
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

    // MARK: - 文件面板供文件（COVER-UPLOAD-FIX D，iOS 18.4+ 公开回调）

    /// 一次性待供文件：引擎在 upload_file 选文件阶段开始前武装（附件
    /// 已解析＋SP-01 已过：任务生成豁免或用户已在确认卡点过确认），
    /// 文件面板回调命中执行页时消费并作废——供完一次即失效，不会给
    /// 后来无关的文件控件误供。绑定标签页：只有执行页的面板请求能
    /// 消费它。
    private struct ArmedUploadSupply { let tabID: UUID; let url: URL; let fileName: String }
    private var armedUploadSupply: ArmedUploadSupply?

    /// 当前系统是否有文件面板公开回调（iOS 18.4+）。引擎据此决定走
    /// 自动供文件还是纯手动选文件路径。
    var uploadSupplySupported: Bool {
        if #available(iOS 18.4, *) { return true }
        return false
    }

    /// 武装待供文件（绑定当前执行页）。系统不支持时返回 false，调用
    /// 方按手动路径继续。
    @discardableResult
    func armUploadSupply(url: URL, fileName: String) -> Bool {
        guard uploadSupplySupported else { return false }
        armedUploadSupply = ArmedUploadSupply(tabID: executionTab.id, url: url, fileName: fileName)
        return true
    }

    /// 解除武装（上传收口/取消/丢弃时调用）：未消费的待供文件作废。
    func disarmUploadSupply() { armedUploadSupply = nil }

    /// 待供文件是否仍在武装中（未被面板回调消费）。
    var uploadSupplyArmed: Bool { armedUploadSupply != nil }

    /// 自检二十二回路（COVER-UPLOAD-FIX D）：在本地上传页 test-upload
    /// 上走完整回路——备一份临时文件→武装供文件→用引擎同款合成触发
    /// 碰文件控件→回读页面持有状态。判定两段分开：回调被触发且页面
    /// 持有供的文件＝回路成立；武装成功但触发后面板回调没来（合成
    /// click 在本环境不被认作可拉起面板的手势）→ 如实记未触发，本单
    /// 的真机生产路径退到「用户在页面上真点上传按钮时供文件」（同一
    /// 回调、真实手势），Tier B 复测以真机为准。系统低于 iOS 18.4 时
    /// 回调不存在，直接记环境结论。结束时解除武装，不留待供文件。
    func verifyUploadPanelSupply() async -> [String] {
        var lines: [String] = []
        guard uploadSupplySupported else {
            lines.append("✗ 回路·自动供文件：当前系统低于 iOS 18.4，文件面板公开回调不存在——本机只能走手动选文件路径（环境结论，非代码失败）")
            return lines
        }
        do { try loadLocalOnExecutionTab("test-upload") } catch {
            lines.append("✗ 回路·自动供文件：合成页 test-upload 加载失败：\(error.localizedDescription)")
            return lines
        }
        try? await Task.sleep(for: .milliseconds(900))
        defer { disarmUploadSupply() }
        guard let page = try? await state(),
              let input = page.elements.first(where: { $0.tag == "input" && $0.inputType.lowercased() == "file" }) else {
            lines.append("✗ 回路·自动供文件：test-upload 页未抽到文件控件，回路未启动")
            return lines
        }
        // 临时样本文件：一句话文本充当任意文件（面板只认 URL 不认内容）
        let sampleName = "cover-panel-selftest.txt"
        let sampleURL = FileManager.default.temporaryDirectory.appendingPathComponent(sampleName)
        try? "COVER-UPLOAD-FIX selftest payload".write(to: sampleURL, atomically: true, encoding: .utf8)
        let armed = armUploadSupply(url: sampleURL, fileName: sampleName)
        guard armed else {
            lines.append("✗ 回路·自动供文件：武装失败（系统自称支持回调却未能武装）")
            return lines
        }
        _ = await triggerFileInput(index: input.index)
        try? await Task.sleep(for: .milliseconds(1500))
        let names = await probeFileInput(index: input.index)
        let consumed = !uploadSupplyArmed
        if consumed && names.contains(where: { $0.contains(sampleName) }) {
            lines.append("✓ 回路·自动供文件：合成触发拉起文件面板回调，宿主直接把武装文件交给页面——未弹选择器，页面文件控件已持有 \(sampleName)（回读实证），待供凭据消费即作废")
        } else if consumed {
            lines.append("✗ 回路·自动供文件异常：待供凭据已被消费，但页面回读未见 \(sampleName)（实见 \(names.isEmpty ? "无" : names.joined(separator: "、"))）")
        } else {
            lines.append("✗ 回路·自动供文件未触发：合成 click 未拉起文件面板（回调没来、凭据仍武装）——本环境下自动供文件不成立；真机生产路径为用户在页面上真点上传按钮时由同一回调供文件（Tier B 复测为准，不得视为已验）")
        }
        lines.append("自检临时文件位于系统临时目录，不进附件索引、不留任务状态")
        return lines
    }

    /// 页面图像清单回读（WECHAT-COVER-FIX Part B，上传双回读的第二项）：
    /// 收集执行页主 frame 内全部 <img> 的当前源（currentSrc 优先）与
    /// CSS 背景图 URL——上传前后各取一次，差集即「页面新增图像」的
    /// 客观证据（封面缩略图、预览图都以这两种形态出现）。只读元数据，
    /// 不读图像内容；上限 300 条防极端页面。
    func probePageImages() async -> [String] {
        let tab = executionTab
        let result = try? await evaluate("""
        (()=>{const out=new Set();
        for(const img of document.querySelectorAll('img')){const s=img.currentSrc||img.src;if(s)out.add(s);if(out.size>=300)break;}
        if(out.size<300){for(const e of document.querySelectorAll('*')){const bg=getComputedStyle(e).backgroundImage;if(bg&&bg!=='none'){const m=bg.match(/url\\(["']?(.*?)["']?\\)/);if(m&&m[1])out.add(m[1]);}if(out.size>=300)break;}}
        return JSON.stringify([...out]);})()
        """, on: tab)
        guard let raw = result as? String, let data = raw.data(using: .utf8),
              let srcs = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return srcs
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

    // MARK: - 绕行梯接缝（AUTONOMY-FIX）

    /// 在执行页导航到指定地址（绕行梯直达/往返用）：走 BrowserTab.load
    /// 的既有校验（http/https），作用于执行页而非当前页。
    func loadOnExecutionTab(_ urlString: String) throws { try executionTab.load(urlString) }

    /// 执行页的 frame 弹窗普查（绕行梯弹窗导航绕行的证据口）：对
    /// probeFrames 的执行页包装，签名/摘要口径与 frame 探针一致。
    func dialogCensus() async -> FrameCensus { await probeFrames(on: executionTab) }

    /// harvest 采集结果（LADDER-FIX F3）：采用候选（可空）＋实况
    /// （候选总数/来源分布/采用或落空原因，进梯账与梯尽结案文案）。
    struct HarvestOutcome {
        let result: DirectTargetHarvest.Result?
        let facts: DirectTargetHarvest.Facts
    }

    /// 直达目标 harvest（AUTONOMY-FIX 梯级②、LADDER-FIX F3 扩展、
    /// EDITOR-ENTRY-BIND 再扩展）：经 frame 探针向整棵 frame 树采集
    /// 候选——链接 href、data-* 属性、onclick 属性、页面内嵌列表数
    /// 据（URL 形片段＋以 appmsgid 为锚的对象窗口）、卡片 DOM 配对，
    /// 交 DirectTargetHarvest.build 做纯函数提取：模板与目标 ID 只
    /// 从实证候选出，禁止任何未实证的标识映射假定（如 mid＝
    /// appmsgid）；给出目标标题时只认标题配对（同对象/同卡共现）。
    /// 列表翻页：当前页地址带 begin/count 参数且本页未出结果时，
    /// 按 begin 递进自动翻页累积（至多 5 页），实况注明覆盖页数。
    /// 探针未覆盖（零 frame 回報）时回落主 frame 链接采集（旧口径
    /// 下限），回落事实记入实况不隐瞒。
    func harvestDirectTargets(memoryTemplate: String?, targetTitle: String? = nil) async -> HarvestOutcome {
        let maxPages = 5
        var allCandidates: [DirectTargetHarvest.Candidate] = []
        var allDomPairs: [DirectTargetHarvest.Pair] = []
        var pagesCovered = 0
        var currentURL = (try? await state())?.url ?? ""
        // 翻页上限：以首頁 begin/count 推 maxBegin（纯函数口径共用）
        var maxBegin = Int.max
        if let comps = URLComponents(string: currentURL), let items = comps.queryItems,
           let b = Int(items.first(where: { $0.name == "begin" })?.value ?? ""),
           let c = Int(items.first(where: { $0.name == "count" })?.value ?? ""), c > 0 {
            maxBegin = b + (maxPages - 1) * c
        }
        while pagesCovered < maxPages {
            let (pageCandidates, pagePairs, covered) = await collectHarvestOnce()
            if pagesCovered == 0, !covered {
                // 探针未覆盖：回落主 frame 链接采集（旧口径下限）
                let tab = executionTab
                let result = try? await evaluate("""
                (()=>{const out=[];for(const a of document.querySelectorAll('a[href]')){const h=a.getAttribute('href');if(h)out.push(h);if(out.length>=400)break;}return JSON.stringify(out);})()
                """, on: tab)
                var fallback = allCandidates
                if let raw = result as? String, let data = raw.data(using: .utf8),
                   let hrefs = try? JSONDecoder().decode([String].self, from: data) {
                    fallback = hrefs.map { .init(source: .href, value: $0) }
                }
                var built = DirectTargetHarvest.build(candidates: fallback, memoryTemplate: memoryTemplate, targetTitle: targetTitle, domPairs: allDomPairs)
                built.facts.note += (built.facts.note.isEmpty ? "" : "；") + "frame 探针未覆盖，已回落主 frame 链接采集"
                return HarvestOutcome(result: built.result, facts: built.facts)
            }
            allCandidates += pageCandidates
            for p in pagePairs where !allDomPairs.contains(p) { allDomPairs.append(p) }
            pagesCovered += 1
            let built = DirectTargetHarvest.build(candidates: allCandidates, memoryTemplate: memoryTemplate, targetTitle: targetTitle, domPairs: allDomPairs)
            if built.result != nil {
                var facts = built.facts
                if pagesCovered > 1 { facts.note += "；翻页累积覆盖 \(pagesCovered) 页" }
                return HarvestOutcome(result: built.result, facts: facts)
            }
            // 未出结果：有下一页才翻（begin/count 列表才有此形态）
            guard let next = DirectTargetHarvest.nextListPageURL(currentURL, maxBegin: maxBegin) else {
                var facts = built.facts
                if pagesCovered > 1 { facts.note += "；翻页累积覆盖 \(pagesCovered) 页" }
                return HarvestOutcome(result: nil, facts: facts)
            }
            do { try loadOnExecutionTab(next) } catch {
                var facts = built.facts
                facts.note += "；翻页导航失败（\(error.localizedDescription)），已覆盖 \(pagesCovered) 页"
                return HarvestOutcome(result: nil, facts: facts)
            }
            currentURL = next
            try? await Task.sleep(for: .milliseconds(900))
            _ = await settledCapture()
        }
        let built = DirectTargetHarvest.build(candidates: allCandidates, memoryTemplate: memoryTemplate, targetTitle: targetTitle, domPairs: allDomPairs)
        var facts = built.facts
        if pagesCovered > 1 { facts.note += "；翻页累积覆盖 \(pagesCovered) 页（已达翻页上限 \(maxPages) 页）" }
        return HarvestOutcome(result: built.result, facts: facts)
    }

    /// 单页 harvest 采集（frame 探针洪泛→收集一轮回報）：候选、卡
    /// 片 DOM 配对、探针是否覆盖（有 frame 回報）。harvestDirectTargets
    /// 的翻页循环逐页调用；消息盒按本轮 token 隔离，迟到的上一轮
    /// 回報不串入。
    private func collectHarvestOnce() async -> (candidates: [DirectTargetHarvest.Candidate], domPairs: [DirectTargetHarvest.Pair], covered: Bool) {
        let tab = executionTab
        let token = UUID().uuidString
        let box = FrameMessageBox()
        FrameProbeHub.shared.register(webView: tab.webView, token: token) { body in
            if (body["kind"] as? String) == "harvest-report" { box.messages.append(body) }
        }
        defer { FrameProbeHub.shared.unregister(token: token) }
        let flood = "(()=>{const d={__mikaFrame:1,kind:'harvest',token:'\(token)'};window.postMessage(d,'*');return 'flooded';})()"
        _ = try? await evaluate(flood, on: tab)
        try? await Task.sleep(for: .milliseconds(900))
        var candidates: [DirectTargetHarvest.Candidate] = []
        var domPairs: [DirectTargetHarvest.Pair] = []
        for message in box.messages {
            let base = (message["href"] as? String) ?? ""
            for href in (message["hrefs"] as? [String]) ?? [] {
                candidates.append(.init(source: .href, value: href, baseURL: base))
            }
            for attr in (message["dataAttrs"] as? [[String: Any]]) ?? [] {
                candidates.append(.init(source: .dataAttr, value: (attr["value"] as? String) ?? "", attrName: (attr["name"] as? String) ?? "", baseURL: base))
            }
            for oc in (message["onclicks"] as? [String]) ?? [] {
                candidates.append(.init(source: .onclick, value: oc, baseURL: base))
            }
            for em in (message["embedded"] as? [String]) ?? [] {
                candidates.append(.init(source: .embedded, value: em, baseURL: base))
            }
            for em in (message["embeddedObjs"] as? [String]) ?? [] {
                candidates.append(.init(source: .embedded, value: em, baseURL: base))
            }
            for dp in (message["domPairs"] as? [[String: Any]]) ?? [] {
                let title = (dp["title"] as? String) ?? ""
                let id = (dp["id"] as? String) ?? ""
                if !title.isEmpty, !id.isEmpty {
                    let pair = DirectTargetHarvest.Pair(title: title, appmsgid: id, evidence: "卡片 DOM 同卡共现")
                    if !domPairs.contains(pair) { domPairs.append(pair) }
                }
            }
        }
        return (candidates, domPairs, !box.messages.isEmpty)
    }

    /// hover 显形探测的回報（LADDER-FIX F5）。
    struct HoverProbeReport {
        let containersTried: Int
        let revealed: [String]
        var summary: String {
            if revealed.isEmpty { return "hover 显形探测已试 \(containersTried) 个卡片容器，未探到新显形的可操作元素" }
            return "hover 显形探测在 \(containersTried) 个卡片容器上探到 \(revealed.count) 个新显形元素：\(revealed.joined(separator: "；"))"
        }
    }

    /// hover 显形探测（LADDER-FIX F5）：编辑入口可能藏在 hover 才显
    /// 形的控件里、感知层快照中不可见。本探测在执行页主 frame 先记
    /// 「当前可见可操作元素签名集」，对卡片状容器（至多 8 个）逐个
    /// 派发 mouseover/mouseenter/mousemove，Swift 侧等约 450ms 后复
    /// 采签名集——新出现的签名即 hover 显形元素。只探测与留痕，绝
    /// 不点击；子 frame 内的 hover 显形不在本探测面（案卷未证项）。
    func hoverRevealProbe() async -> HoverProbeReport {
        let tab = executionTab
        let begin = """
        (()=>{const vis=x=>{if(!x||!x.getBoundingClientRect)return false;const r=x.getBoundingClientRect(),s=getComputedStyle(x);return r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none';};
        const lab=x=>((x.innerText||x.value||x.getAttribute('aria-label')||'')+'').replace(/\\s+/g,' ').trim().slice(0,24);
        const sig=x=>x.tagName.toLowerCase()+'|'+lab(x);
        const sel='a,button,[role="button"],input,select,textarea,[onclick],[contenteditable="true"]';
        const before=new Set();document.querySelectorAll(sel).forEach(e=>{if(vis(e))before.add(sig(e));});
        window.__mikaHoverBefore=Array.from(before);
        const containers=[];document.querySelectorAll('div,li,section,article,tr').forEach(c=>{if(containers.length>=8||!vis(c))return;const r=c.getBoundingClientRect();if(r.width<60||r.height<24)return;if(!c.querySelector('a,button,[onclick]')&&getComputedStyle(c).cursor!=='pointer')return;containers.push(c);});
        containers.forEach(c=>{const r=c.getBoundingClientRect();const x=Math.round(r.left+r.width/2),y=Math.round(r.top+r.height/2);let t=c;try{t=document.elementFromPoint(x,y)||c;}catch(e){}['mouseover','mouseenter','mousemove'].forEach(type=>{try{t.dispatchEvent(new MouseEvent(type,{bubbles:true,composed:true,cancelable:true,clientX:x,clientY:y,view:window}));}catch(e){}});});
        return JSON.stringify({tried:containers.length});})()
        """
        guard let rawBegin = try? await evaluate(begin, on: tab) as? String,
              let beginData = rawBegin.data(using: .utf8),
              let beginObj = try? JSONSerialization.jsonObject(with: beginData) as? [String: Any] else {
            return HoverProbeReport(containersTried: 0, revealed: [])
        }
        try? await Task.sleep(for: .milliseconds(450))
        let after = """
        (()=>{const vis=x=>{if(!x||!x.getBoundingClientRect)return false;const r=x.getBoundingClientRect(),s=getComputedStyle(x);return r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none';};
        const lab=x=>((x.innerText||x.value||x.getAttribute('aria-label')||'')+'').replace(/\\s+/g,' ').trim().slice(0,24);
        const sig=x=>x.tagName.toLowerCase()+'|'+lab(x);
        const sel='a,button,[role="button"],input,select,textarea,[onclick],[contenteditable="true"]';
        const before=new Set(window.__mikaHoverBefore||[]);const revealed=[];
        document.querySelectorAll(sel).forEach(e=>{if(!vis(e))return;const s=sig(e);if(!before.has(s)&&revealed.indexOf(s)<0)revealed.push(s);});
        window.__mikaHoverBefore=null;
        return JSON.stringify({revealed:revealed.slice(0,10)});})()
        """
        var revealed: [String] = []
        if let rawAfter = try? await evaluate(after, on: tab) as? String,
           let afterData = rawAfter.data(using: .utf8),
           let afterObj = try? JSONSerialization.jsonObject(with: afterData) as? [String: Any] {
            revealed = (afterObj["revealed"] as? [String]) ?? []
        }
        return HoverProbeReport(containersTried: (beginObj["tried"] as? Int) ?? 0, revealed: revealed)
    }

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
        let opener = tabs.first(where: { $0.webView === webView })
        let owner = opener?.sessionID ?? displayedSessionID
        let tab = BrowserTab(configuration: configuration, loadStartPage: false, sessionID: owner)
        tabs.append(tab)
        adopt(tab)
        lastActiveTabBySession[owner] = tab.id
        if owner == displayedSessionID { activeTabID = tab.id }
        if let opener { agentPopupCreated?(tab.id, opener.id) }
        return tab.webView
    }

    /// 网页脚本 window.close()：按同一套关闭规则关掉对应标签。
    func webViewDidClose(_ webView: WKWebView) {
        if let tab = tabs.first(where: { $0.webView === webView }) { closeTab(tab.id) }
    }

    /// 文件面板请求（COVER-UPLOAD-FIX D，iOS 18.4+ 公开回调）：页面
    /// 文件控件要打开文件面板时 WebKit 改问宿主。两条路：① 执行页有
    /// 武装好的待供文件（upload_file 已解析附件且 SP-01 已过）→ 直接
    /// 把该文件 URL 交给页面，不弹任何选择器，消费即作废；② 其余
    /// 情况（用户手动点页面上传按钮、或 upload_file 未解析到具体
    /// 附件要现选）→ 宿主弹标准选择器（照片图库／文件）转发用户选择，
    /// 保持「用户自己选」语义不变。iOS 18.4 以下系统不调用本方法，
    /// 行为与 Safari 一致（系统选择器）。
    @available(iOS 18.4, *)
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        if let supply = armedUploadSupply,
           let tab = tabs.first(where: { $0.webView === webView }), tab.id == supply.tabID {
            armedUploadSupply = nil
            openPanelEvents.append((at: Date(), consumedSupply: true))
            completionHandler([supply.url])
            return
        }
        openPanelEvents.append((at: Date(), consumedSupply: false))
        OpenPanelFallback.present(parameters: parameters, from: webView, completion: completionHandler)
    }

    /// 文件面板回调活动记录（EDITOR-ENTRY-BIND 上传诊断）：每次
    /// runOpenPanel 被拉起都记一笔（是否消费了武装待供文件）。只记
    /// 元数据（时刻＋布尔），不记文件名/路径。
    private(set) var openPanelEvents: [(at: Date, consumedSupply: Bool)] = []

    /// 某时刻以来的面板回调活动（上传步流结构化诊断用）：fired＝
    /// 回调被拉起次数，consumed＝其中消费待供文件的次数。据此可
    /// 区分「控件触发了但页面走宿主选择器」与「回调根本没来」。
    func openPanelActivity(since: Date) -> (fired: Int, consumed: Int) {
        let recent = openPanelEvents.filter { $0.at >= since }
        return (recent.count, recent.filter { $0.consumedSupply }.count)
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
    /// 立刻抽取会拿到中间态快照、元素引用随即失效。短轮询页面签名（就绪态／
    /// 节点数／文档高度／资源末端时间），连续两次相同即认为 DOM 已静默；上限约 1.6 秒，超时照常取快照
    /// （动画／轮播类页面永不完全静默，不为它无限等）。全程尽力而为，不抛错、不拦加载判定。
    private func waitForStability(in tab: BrowserTab) async {
        // 切后台驻停：DOM 静默轮询整体停手，不向正在被挂起的网页进程连发探针
        if agentWorkSuspended { return }
        let probe = "(()=>{let end=0;try{for(const e of performance.getEntriesByType('resource'))if(e.responseEnd>end)end=e.responseEnd;}catch(_){}return [document.readyState,document.querySelectorAll('*').length,document.documentElement?document.documentElement.scrollHeight:0,end].join('|');})()"
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

    /// 与静默探针不同：比较文本内容本身，等长文案替换也能被看见。
    /// 只取主文档首段可见文本，避免把整页内容带回原生侧。
    private func clickSignature(in tab: BrowserTab) async -> ClickSignature? {
        if agentWorkSuspended { return nil }
        let script = "(()=>{const b=document.body;if(!b)return null;let text='',n;const w=document.createTreeWalker(b,NodeFilter.SHOW_TEXT);while(text.length<2048&&(n=w.nextNode())){const p=n.parentElement;if(!p||p.closest('script,style,noscript'))continue;const r=p.getBoundingClientRect(),s=getComputedStyle(p);if(r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none')text+=n.textContent.trim()+' ';}return JSON.stringify({url:location.href,count:document.querySelectorAll('*').length,text:text.slice(0,2048)});})()"
        guard let raw = (try? await evaluate(script, on: tab)) as? String,
              let data = raw.data(using: .utf8),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = fields["url"] as? String,
              let count = fields["count"] as? Int,
              let visibleText = fields["text"] as? String else { return nil }
        return ClickSignature(url: url, elementCount: count, textHash: visibleText.hashValue)
    }

    private static func classifyClickEffect(before: ClickSignature?, after: ClickSignature?) -> ClickEffect? {
        guard let before, let after else { return nil }
        return ClickEffect(urlChanged: before.url != after.url,
                           contentChanged: before.elementCount != after.elementCount || before.textHash != after.textHash)
    }

    /// 自检二十八：纯分类真值表；不访问页面，也不改变执行现场。
    func verifyClickEffectClassification() -> [String] {
        let base = ClickSignature(url: "https://example.invalid/a", elementCount: 3, textHash: 11)
        let cases: [(String, ClickSignature?, ClickSignature?, ClickEffect?)] = [
            ("URL 变化", base, ClickSignature(url: "https://example.invalid/b", elementCount: 3, textHash: 11), ClickEffect(urlChanged: true, contentChanged: false)),
            ("内容变化", base, ClickSignature(url: base.url, elementCount: 3, textHash: 12), ClickEffect(urlChanged: false, contentChanged: true)),
            ("元素数变化", base, ClickSignature(url: base.url, elementCount: 4, textHash: 11), ClickEffect(urlChanged: false, contentChanged: true)),
            ("都不变", base, base, ClickEffect(urlChanged: false, contentChanged: false)),
            ("点前签名缺失", nil, base, nil)
        ]
        return cases.map { item in
            let (name, before, after, expected) = item
            let actual = Self.classifyClickEffect(before: before, after: after)
            return "\(actual == expected ? "✓" : "✗") \(name)：期望 \(String(describing: expected))，实际 \(String(describing: actual))"
        }
    }
    /// 当前页求值（BrowserDockView 滚动比例读取／恢复用）
    func evaluate(_ script: String) async throws -> Any? { try await evaluate(script, on: activeTab) }
    private func evaluate(_ script: String, on tab: BrowserTab) async throws -> Any? { try await tab.webView.evaluateJavaScript(script) }
    func state() async throws -> PageState { try await state(in: executionTab) }
    private func state(in tab: BrowserTab, forCapture: Bool = false) async throws -> PageState {
        if !agentWorkSuspended && !forCapture {
            // 取快照前先同步一次 Cookie（60 秒节流，BACKGROUND-RESILIENCE 的驻停
            // 期不做）：任务开始时若登录态已被 ITP 静默清除，先回注再让 agent 看
            // 页面，避免它对着登录墙误判（ADOPTION-TOP3 第 1 条）。
            CookieBackup.shared.noteVisit(url: tab.webView.url)
            await CookieBackup.shared.syncIfNeeded(store: WKWebsiteDataStore.default().httpCookieStore)
        }
        try await ready(in: tab)
        if !forCapture { await waitForStability(in: tab) }
        // 文档代次一致性（阿仁亲审补漏，刀3）：抽取期间撞上主 frame 导航／
        // 终止时整份重抽一次，两次都撞上才判失效——单次竞态不许把主循环
        // 的一次正常取快照判死（该错误不属瞬时类、也不走重找路径）。
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let epoch = tab.documentEpoch
            guard let json = try await evaluate(PageScript.extract, on: tab) as? String else { throw MikaError("无法抽取页面状态") }
            try Task.checkCancellation()
            if tab.documentEpoch != epoch {
                if attempt == 0 { continue }
                throw MikaError("目标元素已失效")
            }
            do {
                var page = try JSONDecoder().decode(PageState.self, from: Data(json.utf8))
                page.epoch = epoch
                return page
            }
            catch { throw MikaError("页面状态解析失败，请刷新页面后重试") }
        }
        throw MikaError("目标元素已失效")
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
        // inView 是位置字段（WECHAT-EDITOR-NAV A2）：同一元素在模型快照与
        // 执行时两次抽取之间只要页面滚过一格就会不同，纳入逐字段相等会把
        // 正当目标误判「已变化」——身份校验豁免它，其余字段照旧全等。
        let identityCheck = strict
            ? "if(!target||!Object.keys(expected).every(k=>k==='inView'||target[k]===expected[k]))throw new Error('目标元素已变化');"
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

    /// 派发时只复核目标及关联 label；不重跑 PageScript.extract。
    private func localClickGuard(action: AgentAction, expected: PageElement, approved: Bool) throws -> String {
        let json = String(decoding: try JSONEncoder().encode(expected), as: UTF8.self)
        let keywords = String(decoding: try JSONSerialization.data(withJSONObject: SafetyPolicy.keywords), as: UTF8.self)
        return """
        const expected=\(json),e=document.querySelector('[data-mika-idx="\(action.index)"]');
        if(!e||!e.isConnected)throw new Error('目标元素已失效');
        if(e.tagName.toLowerCase()!==expected.tag||!!e.isContentEditable!==!!expected.editable)throw new Error('目标元素已变化');
        const labels=[...(e.labels||[])].map(x=>(x.innerText||'').trim()).join(' ');
        const names=[(e.innerText||'').trim(),(e.getAttribute('aria-label')||'').trim(),(e.title||'').trim(),(e.getAttribute('alt')||'').trim(),labels,(e.placeholder||'').trim(),String(e.value||'').trim()];
        if(expected.text&&expected.nameSource!=='none'&&expected.nameSource!=='bg'&&expected.nameSource!=='icon'&&!names.some(x=>x.slice(0,300)===expected.text))throw new Error('目标元素已变化');
        const hint=[e.type,e.name,e.id,e.placeholder,e.getAttribute('aria-label'),e.getAttribute('alt'),e.autocomplete,labels].join(' ');
        if(/password|验证码|校验码|动态码|一次性|captcha|verification|verify|one.time|otp|security.code|(^|[ _-])(code|pin)($|[ _-])/i.test(hint))throw new Error('敏感字段必须手动输入');
        const label=[...names,e.name||''].join(' ').toLowerCase();
        if(!\(approved ? "true" : "false")&&\(keywords).some(k=>label.includes(k)))throw new Error('敏感操作未经确认');
        if(e.disabled===true||e.getAttribute('aria-disabled')==='true')return 'disabled';
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
        let data = try JSONSerialization.data(withJSONObject: ["index": action.index, "epoch": tab.documentEpoch])
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
        const root=ed.closest('[data-editor-root],form,main,[class*="editor-root"],[id*="editor-root"]')||document.body;
        const key='__mikaEditorSignals',old=window[key];
        let nodes=old&&old.epoch===a.epoch&&old.editor===ed&&old.root===root&&old.nodes.every(x=>x.isConnected&&root.contains(x))?old.nodes:null;
        if(!nodes){nodes=[...root.querySelectorAll('*')].filter(x=>{if(ed.contains(x)||x.contains(ed))return false;const t=(x.innerText||'').trim();return (t.length<=40&&(countRe.test(t)||savingRe.test(t)||savedRe.test(t)))||/save|status|count|word|character/i.test((x.id||'')+' '+(x.className||''));});window[key]={epoch:a.epoch,editor:ed,root:root,nodes:nodes};}
        const cands=nodes.filter(vis).map(x=>(x.innerText||'').trim()).filter(t=>t&&t.length<=40);
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
        guard ClickGuardCacheKey.hits(clickGuardCache, tabID: tab.id, epoch: tab.documentEpoch, index: action.index) else { throw MikaError("目标元素已失效") }
        let keywords = String(decoding: try JSONSerialization.data(withJSONObject: SafetyPolicy.keywords), as: UTF8.self)
        let script: String
        if rescan {
            let data = try JSONSerialization.data(withJSONObject: ["index": action.index, "text": expected.text.isEmpty ? expected.ariaLabel : expected.text, "tag": expected.tag])
            let json = String(decoding: data, as: UTF8.self)
            script = """
            (()=>{const a=\(json);
            const norm=s=>(s||'').replace(/\\s+/g,' ').trim().toLowerCase();
            const vis=x=>{const r=x.getBoundingClientRect(),s=getComputedStyle(x);return r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none';};
            const lab=x=>(x.innerText||x.value||x.getAttribute('aria-label')||'').trim();
            const dis=x=>x.disabled===true||x.getAttribute('aria-disabled')==='true';
            const safe=x=>{const hint=[x.type,x.name,x.id,x.placeholder,x.getAttribute('aria-label'),x.getAttribute('alt'),x.autocomplete,...[...(x.labels||[])].map(y=>y.innerText||'')].join(' ');if(/password|验证码|校验码|动态码|一次性|captcha|verification|verify|one.time|otp|security.code|(^|[ _-])(code|pin)($|[ _-])/i.test(hint))throw new Error('敏感字段必须手动输入');const l=[lab(x),x.getAttribute('aria-label')||''].join(' ').toLowerCase();if(!\(approved ? "true" : "false")&&\(keywords).some(k=>l.includes(k)))throw new Error('敏感操作未经确认');};
            const tryClick=x=>{safe(x);x.scrollIntoView({block:'center'});x.focus();x.click();return 'clicked';};
            let node=document.querySelector('[data-mika-idx="'+a.index+'"]');
            if(node&&node.isConnected&&vis(node)&&!dis(node)&&node.tagName.toLowerCase()===a.tag&&(!a.text||norm(lab(node))===norm(a.text)))return tryClick(node);
            const want=norm(a.text);
            if(want){
              const cands=[...document.querySelectorAll('button,[role="button"],a,input[type="submit"],input[type="button"]')].filter(x=>vis(x)&&norm(lab(x))===want);
              const enabled=cands.find(x=>!dis(x));
              if(enabled)return tryClick(enabled);
              if(cands.length)return 'disabled';
              // 文本锚点回退（WECHAT-EDITOR-NAV A3）：目标词只出现在文本
              // 节点里、没有以它为文案的可点元素时（入口是包着文字的整块
              // 卡片／图标区，公众号编辑器的封面区即此形态），取含该文本
              // 最近的可点击祖先作候选——排在精确文案候选之后、缺失判定
              // 之前。安全词只按目标词与祖先自身的无障碍名查（祖先的整段
              // innerText 范围太大，拿它查会误伤整卡敏感词）。
              const clickSel='a,button,[role="button"],[role="link"],input,[onclick]';
              const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);
              let tn;const anchors=[];
              while((tn=walker.nextNode())){
                if(tn.parentElement&&tn.parentElement.closest('script,style,noscript'))continue;
                if(!norm(tn.textContent).includes(want))continue;
                let anc=tn.parentElement,d=0;
                while(anc&&d<6){if(anc.matches(clickSel)||getComputedStyle(anc).cursor==='pointer'){anchors.push(anc);break;}anc=anc.parentElement;d++;}
              }
              const anchorOK=anchors.find(x=>vis(x)&&!dis(x));
              if(anchorOK){
                const l=[want,anchorOK.getAttribute('aria-label')||'',anchorOK.title||''].join(' ').toLowerCase();
                if(!\(approved ? "true" : "false")&&\(keywords).some(k=>l.includes(k)))throw new Error('敏感操作未经确认');
                anchorOK.scrollIntoView({block:'center'});anchorOK.focus();anchorOK.click();return 'clicked';
              }
            }
            if(node&&node.isConnected)return dis(node)?'disabled':'missing';
            return 'missing';})()
            """
        } else {
            guard ClickGuardCacheKey.hits(clickGuardCache, tabID: tab.id, epoch: tab.documentEpoch, index: action.index) else {
                throw MikaError("目标元素已失效")
            }
            let prefix = try localClickGuard(action: action, expected: expected, approved: approved)
            script = """
            (()=>{\(prefix)
            e.scrollIntoView({block:'center'});e.focus();e.click();return 'clicked';})()
            """
        }
        let result = try await evaluate(script, on: tab)
        let status = (result as? String) ?? "missing"
        if status == "clicked" { lastClickDispatchedAt = Date() }
        return status
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
    // 仍在、连败 2 次 → 抛 modalUnresponsivePrefix 错误，引擎据此判定
    // 为能力类卡点、走绕行梯（弹窗导航绕行），不停车等用户代劳
    // （AUTONOMY-FIX；信号判定见 AgentEngine.modalInterventionText）。
    // 诚实边界：合成事件 isTrusted=false 无法伪造——过不去时如实进
    // 绕行梯/失败结案，绝不静默循环、绝不假装已同意。

    /// 弹窗点按无响应的错误前缀（引擎分类门信号判定的唯一依据，两处共用同一常量）。
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
        clickGuardCache = nil
        let epoch = tab.documentEpoch
        let prefix = try guardScript(action: action, expected: expected, approved: approved)
        let script = """
        (()=>{\(prefix)
        \(Self.dialogProbeJS)
        if(e.disabled===true||e.getAttribute('aria-disabled')==='true')return 'disabled';
        return dialogOf(e)?'ready-dialog':'ready-plain';})()
        """
        let result = try await evaluate(script, on: tab)
        guard tab.documentEpoch == epoch else { throw MikaError("目标元素已失效") }
        clickGuardCache = ClickGuardCacheKey(tabID: tab.id, epoch: epoch, index: action.index)
        return (result as? String) ?? "ready-plain"
    }

    /// 弹窗存续探针：点击之后「同一弹窗仍在」是否成立——目标节点仍连接、
    /// 可见且身处弹窗内，或任一可见弹窗容器里还有同文案的可见按钮。
    private struct DialogPersistence {
        let persists: Bool
        let coverageComplete: Bool
        var confirmedGone: Bool { coverageComplete && !persists }
    }
    private func dialogPersists(action: AgentAction, expected: PageElement, tab: BrowserTab) async -> DialogPersistence {
        let epoch = tab.documentEpoch
        let label = expected.text.isEmpty ? expected.ariaLabel : expected.text
        guard let data = try? JSONSerialization.data(withJSONObject: ["index": action.index, "label": label]),
              let json = String(data: data, encoding: .utf8) else { return DialogPersistence(persists: false, coverageComplete: false) }
        let script = """
        (()=>{const a=\(json);
        \(Self.dialogProbeJS)
        const e=document.querySelector('[data-mika-idx="'+a.index+'"]');
        if(e&&e.isConnected&&visDlg(e)&&dialogOf(e))return 'still';
        const want=normDlg(a.label);
        if(!want)return 'unknown';
        const examine=d=>{if(!visDlg(d)||dialogOf(d)!==d)return false;const cands=d.querySelectorAll('button,[role="button"],a,input[type="button"],input[type="submit"]');for(const c of cands){if(visDlg(c)&&normDlg(labDlg(c))===want)return true;}return false;};
        if(want){
          const known=document.querySelectorAll('dialog[open],[role="dialog"],[role="alertdialog"],.modal,[class*="dialog"],[class*="modal"],[class*="popup"]');
          let seen=0;for(const d of known){if(++seen>64)return 'unknown';if(examine(d))return 'still';}
          const walk=document.createTreeWalker(document.body,NodeFilter.SHOW_ELEMENT);
          let d;seen=0;while((d=walk.nextNode())){if(++seen>2000)return 'unknown';if(d.matches('button,[role="button"],a,input[type="button"],input[type="submit"]')&&visDlg(d)&&normDlg(labDlg(d))===want&&dialogOf(d))return 'still';}
        }
        return 'gone';})()
        """
        let result = try? await evaluate(script, on: tab)
        guard tab.documentEpoch == epoch else { return DialogPersistence(persists: false, coverageComplete: false) }
        let status = result as? String
        return DialogPersistence(persists: status == "still", coverageComplete: status == "still" || status == "gone")
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
    /// 连败 2 次抛「弹窗点按无响应」（引擎判能力类卡点走绕行梯；不静默循环、不假装已同意）。
    private func performModalClick(action: AgentAction, expected: PageElement, approved: Bool, tab: BrowserTab) async throws {
        guard ClickGuardCacheKey.hits(clickGuardCache, tabID: tab.id, epoch: tab.documentEpoch, index: action.index) else { throw MikaError("目标元素已失效") }
        let local = try localClickGuard(action: action, expected: expected, approved: approved)
        let validity = try await evaluate("(()=>{\(local)return 'ready';})()", on: tab) as? String
        guard validity == "ready" else { throw MikaError("目标元素已失效") }
        for _ in 1...2 {
            try await performPointerSequence(action: action, approved: approved, tab: tab)
            try await Task.sleep(for: .milliseconds(600))
            if await dialogPersists(action: action, expected: expected, tab: tab).confirmedGone { return }
        }
        await captureFailureSnapshot(context: "弹窗点按无响应：\(action.reason)", tab: tab)
        throw MikaError("\(Self.modalUnresponsivePrefix)：弹窗内的按钮经完整点按序列（真实坐标的 pointer/mouse 事件）两次尝试后仍未关闭——合成点按不是真实点按（isTrusted=false），这类网页只认真实点按")
    }

    // MARK: - 弹窗 frame 探针与框内感知关闭（WECHAT-COVER-FIX，Part A）
    //
    // 现场（Joey 2026-11-03 08:25，构建 1932）：微信「AI 配图功能使用
    // 条款」弹窗在 1830 的主 frame 完整点按序列下仍无响应。1830 路径的
    // 结构盲区：evaluateJavaScript 与元素抽取都只作用于主 frame——弹窗
    // 若住在 iframe 里（尤其跨源），主 frame 既看不见它、也摸不到它，
    // dialogPersists 还会误报「已关闭」。本节先证据后修法：
    // ①probeFrames 洪泛询问整棵 frame 树（探针脚本预注入每个 frame），
    //   把「弹窗住在哪个 frame、按钮是什么元素」变成实测记录（诊断信封
    //   留档＋失败时随错误原文带出）；②关闭在弹窗所在 frame 内执行分
    //   阶段尝试（pointer 序列→触摸序列→Escape→关闭叉号→遮罩点击），
    //   关闭判定只认重新探查时该弹窗不再被任何 frame 报出（元素消失
    //   的回讀证据），不认任何一方的口头成功；③探针在所有 frame 都没
    //   找到弹窗时回落 1830 既有路径，不回退旧行为；④两轮仍不关 →
    //   沿用 modalUnresponsivePrefix（引擎判能力类卡点走绕行梯），错误原文附探针实测事实。

    /// 一次 frame 普查里命中的一个弹窗（探针回報的原始事实）。
    struct FrameDialogHit {
        let framePath: String
        let frameHref: String
        let isTop: Bool
        let sig: String
        let text: String
        let buttons: [(label: String, tag: String)]
    }

    struct FrameCensus {
        let frameCount: Int
        let hits: [FrameDialogHit]
        let framePaths: Set<String>
        let coverageComplete: Bool
        /// 人话摘要（进诊断与失败原文）：frame 总数＋每个命中弹窗的位置与按钮。
        var summary: String {
            guard !hits.isEmpty else { return "共 \(frameCount) 个 frame，未发现弹窗" }
            let parts = hits.map { hit in
                let whereabouts = hit.isTop ? "主 frame" : "frame \(hit.framePath)（\(hit.frameHref.prefix(60))）"
                let labels = hit.buttons.map { $0.label }.joined(separator: "／")
                return "\(whereabouts) 内弹窗「\(hit.text.prefix(30))」按钮 [\(labels)]"
            }
            return "共 \(frameCount) 个 frame；" + parts.joined(separator: "；")
        }
    }

    private final class FrameMessageBox {
        var messages: [[String: Any]] = []
    }

    /// frame 普查：向主 frame 发起洪泛询问，收集各 frame 的 probe-report
    /// （900ms 窗口）。探针未覆盖的页面（注入缺失）返回空普查，调用方
    /// 据此回落旧路径。
    func probeFrames(on tab: BrowserTab) async -> FrameCensus {
        let token = UUID().uuidString
        let box = FrameMessageBox()
        FrameProbeHub.shared.register(webView: tab.webView, token: token) { body in
            if (body["kind"] as? String) == "probe-report" { box.messages.append(body) }
        }
        defer { FrameProbeHub.shared.unregister(token: token) }
        let flood = "(()=>{const d={__mikaFrame:1,kind:'probe',token:'\(token)'};window.postMessage(d,'*');return 'flooded';})()"
        _ = try? await evaluate(flood, on: tab)
        try? await Task.sleep(for: .milliseconds(900))
        var hits: [FrameDialogHit] = []
        for message in box.messages {
            let isTop = (message["isTop"] as? Bool) ?? false
            let path = (message["path"] as? String) ?? "?"
            let href = (message["href"] as? String) ?? ""
            for case let dialog as [String: Any] in (message["dialogs"] as? [[String: Any]] ?? []) {
                let buttons = ((dialog["buttons"] as? [[String: Any]]) ?? []).map {
                    (label: ($0["label"] as? String) ?? "", tag: ($0["tag"] as? String) ?? "")
                }
                hits.append(FrameDialogHit(framePath: path, frameHref: href, isTop: isTop,
                                           sig: (dialog["sig"] as? String) ?? "",
                                           text: (dialog["text"] as? String) ?? "", buttons: buttons))
            }
        }
        return FrameCensus(frameCount: box.messages.count, hits: hits,
                           framePaths: Set(box.messages.compactMap { $0["path"] as? String }),
                           coverageComplete: box.messages.contains { ($0["isTop"] as? Bool) == true })
    }

    struct FrameClickReport {
        let path: String
        let clicked: Bool
        let gone: Bool
        let stage: String
        let stages: [String]
    }

    /// 向弹窗所在 frame 下达点按指令并等第一份 click-report（只有持有
    /// 目标按钮的 frame 会回報；其余 frame 静默）。阶段尝试在 frame 内
    /// 完成，最长约 8 秒，等待上限 10 秒；无回報（探针未覆盖／没有
    /// frame 持有该按钮）返回 nil。
    func dispatchFrameClick(on tab: BrowserTab, label: String, approved: Bool) async -> FrameClickReport? {
        let token = UUID().uuidString
        let box = FrameMessageBox()
        FrameProbeHub.shared.register(webView: tab.webView, token: token) { body in
            if (body["kind"] as? String) == "click-report", box.messages.isEmpty { box.messages.append(body) }
        }
        defer { FrameProbeHub.shared.unregister(token: token) }
        let payload: [String: Any] = ["__mikaFrame": 1, "kind": "click", "token": token, "label": label, "approved": approved, "keywords": SafetyPolicy.keywords]
        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        let flood = "(()=>{const d=\(String(decoding: payloadData, as: UTF8.self));window.postMessage(d,'*');return 'flooded';})()"
        _ = try? await evaluate(flood, on: tab)
        for _ in 0..<50 {
            if let first = box.messages.first {
                return FrameClickReport(path: (first["path"] as? String) ?? "?",
                                        clicked: (first["clicked"] as? Bool) ?? false,
                                        gone: (first["gone"] as? Bool) ?? false,
                                        stage: (first["stage"] as? String) ?? "",
                                        stages: (first["stages"] as? [String]) ?? [])
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    /// 探针实测留档：与失败快照同目录、同信封格式（诊断页可见）。
    private func recordFrameProbeDiagnostic(census: FrameCensus, tab: BrowserTab, label: String) {
        let payload: [String: Any] = [
            "kind": "frame-probe",
            "url": tab.webView.url?.absoluteString ?? "",
            "targetLabel": label,
            "frameCount": census.frameCount,
            "summary": census.summary,
            "hits": census.hits.map { hit in
                ["framePath": hit.framePath, "frameHref": hit.frameHref, "isTop": hit.isTop,
                 "sig": hit.sig, "text": hit.text,
                 "buttons": hit.buttons.map { ["label": $0.label, "tag": $0.tag] }] as [String: Any]
            },
        ]
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MikaWeb/Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID(), now = Date(), formatter = ISO8601DateFormatter()
        let envelope: [String: Any] = ["schemaVersion": 1, "id": id.uuidString, "receivedAt": formatter.string(from: now), "types": ["弹窗Frame探针"], "payload": payload]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]) else { return }
        let name = formatter.string(from: now).replacingOccurrences(of: ":", with: "-") + "-" + id.uuidString + ".json"
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private static func frameLabelMatch(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == b.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 弹窗关闭编排（frame 感知版）：探针定位→框内分阶段关闭→回讀
    /// 复核；两轮不关抛 modalUnresponsivePrefix（附探针实测），引擎判能力类卡点走绕行梯；
    /// 探针处处无获时回落 1830 的 performModalClick。
    private func performModalClose(action: AgentAction, expected: PageElement, approved: Bool, tab: BrowserTab) async throws {
        let label = expected.text.isEmpty ? expected.ariaLabel : expected.text
        var lastCensus: FrameCensus?
        var sawDialog = false
        for round in 1...2 {
            let census = await probeFrames(on: tab)
            lastCensus = census
            if round == 1 { recordFrameProbeDiagnostic(census: census, tab: tab, label: label) }
            let hit = census.hits.first(where: { hit in hit.buttons.contains { Self.frameLabelMatch($0.label, label) } })
                ?? census.hits.first(where: { !$0.isTop })
                ?? census.hits.first
            guard let hit else { break }
            sawDialog = true
            if let report = await dispatchFrameClick(on: tab, label: label, approved: approved), report.gone {
                let after = await probeFrames(on: tab)
                if !after.hits.contains(where: { $0.sig == hit.sig }) { return }
            }
            if round < 2 { try? await Task.sleep(for: .milliseconds(400)) }
        }
        if !sawDialog {
            try await performModalClick(action: action, expected: expected, approved: approved, tab: tab)
            return
        }
        await captureFailureSnapshot(context: "弹窗点按无响应（frame 感知）：\(action.reason)", tab: tab)
        throw MikaError("\(Self.modalUnresponsivePrefix)：frame 探针实测——\(lastCensus?.summary ?? "无探针数据")。已在弹窗所在 frame 内依次尝试完整点按序列、触摸序列、Escape、关闭按钮与遮罩点击，两轮后弹窗仍在——合成事件 isTrusted=false 的边界未变，这类网页只认真实点按")
    }

    // MARK: - 入口揭示复判（WECHAT-EDITOR-NAV A2）
    //
    // 真机现场（Joey 2026-11-03 09:20，公众号编辑器）：草稿编辑入口与
    // 封面设置入口在感知里找不到／被判不可操作——入口其实在页面内层
    // 滚动区下方或窗口折下，抽取在位但点击到不了。旧口径下模型据此在
    // 步流写「无可操作入口」，等于凭没滚到位下结论。本节立规：判不可
    // 达之前，引擎先做一遍确定性揭示（逐个滚动内层滚动容器＋窗口
    // scrollIntoView）再复判；复判仍不可达才许报错，且失败原文必须带
    // 揭示手段清单（见 RevealReport.triedSummary），步流里留得下证据。

    /// 揭示复判的回報：found＝目标还在页面上；containers＝实际滚动过
    /// 的内层滚动容器个数；inView／hit＝复判时元素矩形与视口相交、且
    /// 中心点命中落在目标本身（或其子／祖先，事件冒泡等效）上。
    struct RevealReport {
        let found: Bool
        let containers: Int
        let inView: Bool
        let hit: Bool
        /// 步流留痕口径：判「无可操作入口」时必须写明已试过的揭示手段。
        var triedSummary: String {
            guard found else { return "揭示手段已试：按序号找目标元素时它已不在页面上（无从滚动揭示）" }
            return "揭示手段已试：内层滚动容器逐个滚动（\(containers) 个）＋窗口 scrollIntoView，复判在视口=\(inView)、中心点可命中=\(hit)"
        }
    }

    /// 把快照序号对应的元素滚动揭示出来再复判可达性。纯页面内操作：
    /// 先自下而上逐个滚动可滚动祖先（把元素送进每个容器的可见区），
    /// 再 scrollIntoView 让窗口跟上，最后按矩形相交＋中心点命中复判。
    func revealElement(index: Int, on tab: BrowserTab) async -> RevealReport {
        let script = """
        (()=>{const e=document.querySelector('[data-mika-idx="\(index)"]');
        if(!e||!e.isConnected)return JSON.stringify({found:false,containers:0,inView:false,hit:false});
        const scrollable=x=>{const s=getComputedStyle(x);return /(auto|scroll|overlay)/.test(s.overflowY)||/(auto|scroll|overlay)/.test(s.overflowX);};
        let containers=0;let node=e.parentElement;
        while(node&&node!==document.documentElement){
          if(scrollable(node)&&(node.scrollHeight>node.clientHeight+1||node.scrollWidth>node.clientWidth+1)){
            const r=e.getBoundingClientRect(),cr=node.getBoundingClientRect();let adjusted=false;
            if(r.bottom>cr.bottom||r.top<cr.top){node.scrollTop+=Math.round((r.top-cr.top)-(cr.height-r.height)/2);adjusted=true;}
            if(r.right>cr.right||r.left<cr.left){node.scrollLeft+=Math.round((r.left-cr.left)-(cr.width-r.width)/2);adjusted=true;}
            if(adjusted)containers++;
          }
          node=node.parentElement;
        }
        e.scrollIntoView({block:'center',inline:'center'});
        const r=e.getBoundingClientRect();
        const inView=r.width>0&&r.height>0&&r.bottom>0&&r.right>0&&r.top<innerHeight&&r.left<innerWidth;
        let hit=false;
        if(inView){const cx=Math.min(Math.max(r.left+r.width/2,1),innerWidth-1),cy=Math.min(Math.max(r.top+r.height/2,1),innerHeight-1);const h=document.elementFromPoint(cx,cy);hit=!!h&&(h===e||e.contains(h)||h.contains(e));}
        return JSON.stringify({found:true,containers,inView,hit});})()
        """
        guard let raw = try? await evaluate(script, on: tab) as? String,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return RevealReport(found: false, containers: 0, inView: false, hit: false)
        }
        return RevealReport(found: (obj["found"] as? Bool) ?? false,
                            containers: (obj["containers"] as? Int) ?? 0,
                            inView: (obj["inView"] as? Bool) ?? false,
                            hit: (obj["hit"] as? Bool) ?? false)
    }

    /// click 总流程：先探针分流——目标在弹窗内直接走升级序列；普通目标
    /// 先按已校验元素点（旧口径），点后若观察到同一弹窗仍在再升级；
    /// 禁用/缺失时「等待＋重扫」轮询约 3.6 秒（编辑器状态更新后按钮常
    /// 延迟启用或被重渲染替换，重扫点击成功后同样过一遍存续探针）；
    /// 缺失终局前再做一遍揭示复判（A2：滚动揭示后重点一次，仍不可达
    /// 才报错且原文带揭示手段清单）；最终按「是灰的／找不到」两种
    /// 口径分别报错并留诊断快照。
    private func performClick(_ action: AgentAction, expected: PageElement?, approved: Bool, tab: BrowserTab) async throws {
        lastClickEffect = nil
        lastClickEffectMissingBefore = false
        lastClickDispatchedAt = nil
        let before = await clickSignature(in: tab)
        lastClickEffectMissingBefore = before == nil
        try await dispatchClick(action, expected: expected, approved: approved, tab: tab)
        guard before != nil else { return }
        // 派发流程可能先经历目标重扫或弹窗升级。成功收口后只观察
        // 1.2 秒，约每 300ms 一次；探针失败不改变 click 的成功语义。
        let deadline = (lastClickDispatchedAt ?? Date()).addingTimeInterval(1.2)
        repeat {
            let after = await clickSignature(in: tab)
            lastClickEffect = Self.classifyClickEffect(before: before, after: after)
            if lastClickEffect?.urlChanged == true || lastClickEffect?.contentChanged == true { break }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            try? await Task.sleep(for: .milliseconds(min(300, max(1, Int(remaining * 1000)))))
        } while !agentWorkSuspended
    }

    private func dispatchClick(_ action: AgentAction, expected: PageElement?, approved: Bool, tab: BrowserTab) async throws {
        guard let expected else { throw MikaError("缺少已检查的目标元素") }
        let probe = try await probeClickContext(action: action, expected: expected, approved: approved, tab: tab)
        if probe == "ready-dialog" {
            try await performModalClose(action: action, expected: expected, approved: approved, tab: tab)
            return
        }
        var status = probe
        if probe == "ready-plain" {
            let first = try await runClickScript(action: action, expected: expected, approved: approved, rescan: false, tab: tab)
            status = first
            if first == "clicked" {
                try await Task.sleep(for: .milliseconds(500))
                if !(await dialogPersists(action: action, expected: expected, tab: tab).confirmedGone) {
                    try await performModalClose(action: action, expected: expected, approved: approved, tab: tab)
                }
                return
            }
        }
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(300))
            status = try await runClickScript(action: action, expected: expected, approved: approved, rescan: true, tab: tab)
            if status == "clicked" {
                try await Task.sleep(for: .milliseconds(500))
                if !(await dialogPersists(action: action, expected: expected, tab: tab).confirmedGone) {
                    try await performModalClose(action: action, expected: expected, approved: approved, tab: tab)
                }
                return
            }
        }
        let label = expected.text.isEmpty ? expected.ariaLabel : expected.text
        if status == "disabled" {
            await captureFailureSnapshot(context: "click 目标禁用：\(action.reason)", tab: tab)
            throw MikaError("「\(label)」按钮是灰的（存在但被禁用），无法点击")
        }
        // 揭示复判（A2）：判「找不到」之前先把目标滚动揭示再重点一次——
        // 入口在内层滚动区下方／窗口折下时，首轮点不到不等于不存在。
        // 复判点中即按正常成功收口（含弹窗存续探针）；仍不可达才抛错，
        // 错误原文附揭示手段清单，步流据此才许下「无可操作入口」结论。
        let reveal = await revealElement(index: expected.index, on: tab)
        if reveal.found {
            let retry = try await runClickScript(action: action, expected: expected, approved: approved, rescan: true, tab: tab)
            if retry == "clicked" {
                try await Task.sleep(for: .milliseconds(500))
                if !(await dialogPersists(action: action, expected: expected, tab: tab).confirmedGone) {
                    try await performModalClose(action: action, expected: expected, approved: approved, tab: tab)
                }
                return
            }
            if retry == "disabled" {
                await captureFailureSnapshot(context: "click 目标禁用（揭示复判后）：\(action.reason)", tab: tab)
                throw MikaError("「\(label)」按钮是灰的（存在但被禁用），无法点击")
            }
        }
        await captureFailureSnapshot(context: "click 目标缺失：\(action.reason)", tab: tab)
        throw MikaError("页面上找不到可点的按钮「\(label)」（\(reveal.triedSummary)；可能还没渲染出来或已经关闭）")
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
                ? "✓ 顽固弹窗：完整序列连败 2 次后按口径抛出「\(Self.modalUnresponsivePrefix)」——引擎据此判能力类卡点走绕行梯，不静默循环、不停车等用户代劳"
                : "✗ 顽固弹窗抛错口径不对：\(error.localizedDescription)")
        }
        return lines
    }

    /// 自检十四·Tier A（WECHAT-COVER-FIX Part A）：合成页 test-frames
    /// 把同型弹窗放进两种 frame——甲＝同源 srcdoc frame（顶层可直接读
    /// DOM，弹窗只认完整 pointer 序列）；乙＝沙箱 srcdoc frame（不透
    /// 明源、顶层读不到 DOM，弹窗按钮对点按不响应、只认 Escape）。
    /// 断言：①主 frame 可达性事实与预期一致（甲可读、乙不可读）；
    /// ②frame 普查枚举到 ≥3 个 frame，且甲乙弹窗与按钮特征齐全；
    /// ③框内点按关闭甲（阶段应为 pointer-sequence）且消失经复查与
    /// 页面状态双证；④框内点按关闭乙（阶段应为 escape——点按阶段
    /// 无效后的兜底被真实走到）且消失双证；⑤终局普查无任何弹窗。
    /// 已知未证前提：WKUserScript 是否注入沙箱 iframe 需真机实证——
    /// 若乙 frame 无回報，本检查如实失败，不放水通过。
    func verifyFrameProbeAndClick() async -> [String] {
        var lines: [String] = []
        let tab = activeTab
        func fmt(_ ok: Bool) -> String { ok ? "✓" : "✗" }
        func framesState() async -> (aOpen: Bool?, aReadable: Bool, bOpen: Bool?, bReadable: Bool) {
            guard let raw = try? await evaluate("(() => window.__framesState())()", on: tab) as? String,
                  let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (nil, false, nil, false)
            }
            return (obj["aOpen"] as? Bool, (obj["aReadable"] as? Bool) ?? false,
                    obj["bOpen"] as? Bool, (obj["bReadable"] as? Bool) ?? false)
        }
        do {
            try tab.loadLocal("test-frames")
        } catch {
            return ["✗ 合成测试页 test-frames 加载失败：\(error.localizedDescription)"]
        }
        try? await Task.sleep(for: .milliseconds(1800))
        let before = await framesState()
        lines.append("\(fmt(before.aReadable && !before.bReadable && before.aOpen == true && before.bOpen == true)) 可达性事实：同源 frame 甲可直读其 DOM=\(before.aReadable)、沙箱 frame 乙不可直读=\(!before.bReadable)；甲乙弹窗初始在场=\(before.aOpen == true && before.bOpen == true)")
        let census = await probeFrames(on: tab)
        let hitA = census.hits.first(where: { hit in hit.buttons.contains { $0.label == "同意并继续" } })
        let hitB = census.hits.first(where: { hit in hit.buttons.contains { $0.label == "取消并退出" } })
        let fieldsOK = !census.hits.isEmpty && census.hits.allSatisfy { !$0.framePath.isEmpty && !$0.buttons.isEmpty && !$0.sig.isEmpty }
        lines.append("\(fmt(census.frameCount >= 3 && hitA != nil && hitB != nil && fieldsOK)) frame 普查：共回報 \(census.frameCount) 个 frame；甲弹窗命中=\(hitA != nil)（frame \(hitA?.framePath ?? "-")）、乙弹窗命中=\(hitB != nil)（frame \(hitB?.framePath ?? "-")、乙在主 frame=\(hitB?.isTop == true)）；探针字段完整（路径/按钮/签名齐全）=\(fieldsOK)")
        lines.append("· 普查摘要：\(census.summary)")
        if let hitA {
            let report = await dispatchFrameClick(on: tab, label: "同意并继续", approved: true)
            try? await Task.sleep(for: .milliseconds(400))
            let state = await framesState()
            let recheck = await probeFrames(on: tab)
            let goneOK = report?.gone == true && state.aOpen == false && !recheck.hits.contains(where: { $0.sig == hitA.sig })
            lines.append("\(fmt(goneOK && report?.stage == "pointer-sequence")) 关闭甲：回報阶段=\(report?.stage ?? "无回報")（应为 pointer-sequence）、回報称消失=\(report?.gone == true)、页面状态称已关=\(state.aOpen == false)、复查普查中该弹窗消失=\(!recheck.hits.contains(where: { $0.sig == hitA.sig }))")
        } else {
            lines.append("✗ 关闭甲：普查未命中甲弹窗，跳过")
        }
        if let hitB {
            let report = await dispatchFrameClick(on: tab, label: "取消并退出", approved: true)
            var state = await framesState()
            for _ in 0..<8 where state.bOpen != false {
                try? await Task.sleep(for: .milliseconds(300))
                state = await framesState()
            }
            let recheck = await probeFrames(on: tab)
            let goneOK = report?.gone == true && state.bOpen == false && !recheck.hits.contains(where: { $0.sig == hitB.sig })
            lines.append("\(fmt(goneOK && report?.stage == "escape")) 关闭乙：回報阶段=\(report?.stage ?? "无回報")（应为 escape）、回報称消失=\(report?.gone == true)、页面状态称已关=\(state.bOpen == false)、复查普查中该弹窗消失=\(!recheck.hits.contains(where: { $0.sig == hitB.sig }))")
        } else {
            lines.append("✗ 关闭乙：普查未命中乙弹窗（若探针未注入沙箱 frame 则此处无回報——真机如实记录，不放水）")
        }
        let finalCensus = await probeFrames(on: tab)
        lines.append("\(fmt(finalCensus.hits.isEmpty)) 终局普查：全部 frame 内弹窗数=\(finalCensus.hits.count)（应为 0）")
        return lines
    }

    // MARK: - 自检十六 Tier A（WECHAT-EDITOR-NAV）：入口感知补盲的程序化核查
    //
    // 合成页 test-nav 复刻三类现场盲区：①icon-only 按钮（只有 aria-label、
    // 无文本）＋只有 alt 的图标图＋背景图无文本入口——旧抽取整类滤掉；
    // ②无文本封面区入口（背景图名源）；③内层滚动容器下方、且整页折下
    // 的编辑入口——抽取在位但 inView=false，须经揭示复判（逐个滚动内层
    // 容器＋窗口跟随）后才可达。断言：三类入口都进快照且名源标注正确；
    // 揭示回報 found／容器数 ≥1／复判 inView 与中心命中成立；补盲入口
    // 经引擎 click 真点得动（页面结果标记在场）；文本锚点回退能点中
    // 「只有文字、没有可点元素」的入口（A3）。真编辑器 DOM 形态不在
    // 本页复刻范围——未证项留案卷，Tier B 真机第一条验。
    func verifyEditorNavReveal() async -> [String] {
        var lines: [String] = []
        let tab = activeTab
        func fmt(_ ok: Bool) -> String { ok ? "✓" : "✗" }
        func resultText() async -> String {
            (try? await evaluate("(()=>{const r=document.getElementById('result');return r?r.textContent:'';})()", on: tab) as? String) ?? ""
        }
        do { try tab.loadLocal("test-nav") } catch {
            return ["✗ 合成测试页 test-nav 加载失败：\(error.localizedDescription)"]
        }
        try? await Task.sleep(for: .milliseconds(1000))
        guard let page = try? await state() else { return ["✗ 合成测试页状态抽取失败"] }
        // —— 补盲在位与名源标注 ——
        let iconBtn = page.elements.first(where: { $0.nameSource == "aria-label" && $0.text == "打开设置抽屉" })
        lines.append("\(fmt(iconBtn != nil)) icon-only 按钮补盲：无文本按钮以 aria-label 为名进快照（名源=aria-label）=\(iconBtn != nil)")
        let altIcon = page.elements.first(where: { $0.nameSource == "alt" && $0.text == "封面设置入口" })
        lines.append("\(fmt(altIcon != nil)) alt 图标补盲：只有 alt 的图标图以 alt 为名进快照（名源=alt）=\(altIcon != nil)")
        let bgEntry = page.elements.first(where: { $0.nameSource == "bg" && $0.text == "cover entry" })
        lines.append("\(fmt(bgEntry != nil)) 背景图入口补盲：无文本封面区入口以背景图文件名为名进快照（名源=bg、名=cover entry）=\(bgEntry != nil)")
        // 事件属性入口（browser-use 回退分支的适配样本）：无 pointer 光标、
        // 无文本无背景图，只有内联 onclick——本页唯一的「无名」条目
        let evtMatches = page.elements.filter { $0.nameSource == "none" && $0.text.isEmpty && $0.tag == "div" }
        let evtEntry = evtMatches.count == 1 ? evtMatches.first : nil
        lines.append("\(fmt(evtEntry != nil)) 事件属性入口补盲：只有内联事件属性的无名入口凭事件证据进快照（名源=none，本页同型条目数=\(evtMatches.count)，应为 1）=\(evtEntry != nil)")
        // —— 内层滚动容器下方的编辑入口：抽取在位、初始不在视口 ——
        guard let editEntry = page.elements.first(where: { $0.text == "编辑草稿" }) else {
            lines.append("✗ 内层滚动容器下方的「编辑草稿」入口未进快照")
            return lines
        }
        lines.append("\(fmt(editEntry.inView == false)) 编辑入口初始状态：已进快照且 inView=false（在内层滚动区下方＋整页折下，与现场同型）=\(editEntry.inView == false)")
        // —— 揭示复判 ——
        let reveal = await revealElement(index: editEntry.index, on: tab)
        lines.append("\(fmt(reveal.found && reveal.containers >= 1 && reveal.inView && reveal.hit)) 揭示复判：found=\(reveal.found)、滚动内层容器=\(reveal.containers)（应 ≥1）、复判在视口=\(reveal.inView)、中心点可命中=\(reveal.hit)；手段清单「\(reveal.triedSummary)」")
        // —— 补盲入口经引擎 click 真点得动 ——
        if let iconBtn, let act = Self.selfTestClickAction(index: iconBtn.index) {
            do {
                try await execute(act, expected: iconBtn)
                try? await Task.sleep(for: .milliseconds(300))
                let r = await resultText()
                lines.append("\(fmt(r.contains("设置抽屉已打开"))) icon-only 按钮点击：引擎 click 点中、页面结果标记在场=\(r.contains("设置抽屉已打开"))")
            } catch { lines.append("✗ icon-only 按钮点击抛错：\(error.localizedDescription)") }
        } else { lines.append("✗ icon-only 按钮点击跳过（元素或动作构造失败）") }
        if let bgEntry, let act = Self.selfTestClickAction(index: bgEntry.index) {
            do {
                try await execute(act, expected: bgEntry)
                try? await Task.sleep(for: .milliseconds(300))
                let r = await resultText()
                lines.append("\(fmt(r.contains("封面入口已打开"))) 背景图封面入口点击：引擎 click 点中、页面结果标记在场=\(r.contains("封面入口已打开"))")
            } catch { lines.append("✗ 背景图封面入口点击抛错：\(error.localizedDescription)") }
        } else { lines.append("✗ 背景图封面入口点击跳过（元素或动作构造失败）") }
        if let evtEntry, let act = Self.selfTestClickAction(index: evtEntry.index) {
            do {
                try await execute(act, expected: evtEntry)
                try? await Task.sleep(for: .milliseconds(300))
                let r = await resultText()
                lines.append("\(fmt(r.contains("事件入口已打开"))) 事件属性入口点击：引擎 click 点中、页面结果标记在场=\(r.contains("事件入口已打开"))")
            } catch { lines.append("✗ 事件属性入口点击抛错：\(error.localizedDescription)") }
        } else { lines.append("✗ 事件属性入口点击跳过（元素或动作构造失败）") }
        // —— 揭示后编辑入口可点 ——
        guard let page2 = try? await state(), let editFresh = page2.elements.first(where: { $0.text == "编辑草稿" }) else {
            lines.append("✗ 揭示后状态重取失败")
            return lines
        }
        if let act = Self.selfTestClickAction(index: editFresh.index) {
            do {
                try await execute(act, expected: editFresh)
                try? await Task.sleep(for: .milliseconds(300))
                let r = await resultText()
                lines.append("\(fmt(r.contains("草稿编辑器已打开"))) 编辑入口点击：揭示后引擎 click 点中、页面结果标记在场=\(r.contains("草稿编辑器已打开"))")
            } catch { lines.append("✗ 编辑入口点击抛错：\(error.localizedDescription)") }
        } else { lines.append("✗ 编辑入口点击动作构造失败") }
        // —— 文本锚点回退（A3）：直接驱动重扫脚本验回退分支 ——
        // 「锚点目标词」只是一个文本节点的内容，可点的是包着它的整卡；
        // 先模拟页面重渲染（换新节点＋抹掉全部序号标记——重扫的真实触发
        // 场景），此时按序号找不到节点、精确文案候选也不存在（卡片是
        // div、文字在 span 里），重扫只能经文本锚点回退点中整卡。
        guard let page3 = try? await state(), let spanEl = page3.elements.first(where: { $0.text == "锚点目标词" }) else {
            lines.append("✗ 文本锚点样本元素（锚点目标词）未进快照")
            return lines
        }
        if let act = Self.selfTestClickAction(index: spanEl.index) {
            _ = try? await probeClickContext(action: act, expected: spanEl, approved: false, tab: tab)
        }
        _ = try? await evaluate("(()=>{const s=document.getElementById('anchorSpan');if(s){const c=s.cloneNode(true);s.replaceWith(c);}document.querySelectorAll('[data-mika-idx]').forEach(x=>x.removeAttribute('data-mika-idx'));return 'wiped';})()", on: tab)
        if let act = Self.selfTestClickAction(index: spanEl.index) {
            do {
                let status = try await runClickScript(action: act, expected: spanEl, approved: false, rescan: true, tab: tab)
                try? await Task.sleep(for: .milliseconds(300))
                let r = await resultText()
                lines.append("\(fmt(status == "clicked" && r.contains("锚点卡片已打开"))) 文本锚点回退：序号标记失效后重扫经文本节点→最近可点击祖先点中整卡（重扫回報=\(status)、页面结果在场=\(r.contains("锚点卡片已打开"))）")
            } catch { lines.append("✗ 文本锚点回退点击抛错：\(error.localizedDescription)") }
        } else { lines.append("✗ 文本锚点点击动作构造失败") }
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
        let finalCaptureSkipped: Bool
    }

    /// 动作后取证：每 300ms 探一帧，签名连续 3 帧不变且最近网络响应
    /// 已结束 600ms 以上判 settled；有界超时（默认 5 秒）只记证据未稳，
    /// 不算成功、不抛错。全程尽力而为：探针失败帧直接跳过。
    func settledCapture(timeoutMs: Int = 5000) async -> SettledCapture {
        let tab = executionTab
        var samples: [VerificationSample] = []
        var decisionState = SettleDecisionPolicy.State()
        var settled = false
        var cancelled = false
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while SettleLoopPolicy.next(cancelled: Task.isCancelled, settled: settled, remaining: deadline.timeIntervalSinceNow) == .continue {
            if agentWorkSuspended { break }
            let epoch = tab.documentEpoch
            if let raw = (try? await evaluate(Self.settleProbe, on: tab)) as? String,
               let probe = try? JSONDecoder().decode(SettleProbeResult.self, from: Data(raw.utf8)) {
                if Task.isCancelled { cancelled = true; break }
                if tab.documentEpoch != epoch { decisionState = .init(); samples.removeAll(); continue }
                if let previousURL = samples.last?.url, previousURL != probe.url { samples.removeAll() }
                samples.append(VerificationSample(url: probe.url, text: probe.text))
                let networkQuiet = probe.lastEnd == 0 || (probe.now - probe.lastEnd) > 600
                settled = SettleDecisionPolicy.step(&decisionState, signature: probe.url + "|" + probe.sig, epoch: epoch, networkQuiet: networkQuiet, remaining: deadline.timeIntervalSinceNow) == .settled
                if settled { break }
            } else {
                if Task.isCancelled { cancelled = true; break }
                _ = SettleDecisionPolicy.step(&decisionState, signature: nil, epoch: epoch, networkQuiet: false, remaining: deadline.timeIntervalSinceNow)
            }
            if Task.isCancelled { cancelled = true; break }
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { cancelled = true; break }
        }
        if Task.isCancelled { cancelled = true }
        if let sampledEpoch = decisionState.epoch, sampledEpoch != tab.documentEpoch { settled = false; samples.removeAll() }
        if cancelled { settled = false }
        let after: PageState
        var finalCaptureSkipped = true
        if !cancelled && SettleDecisionPolicy.shouldCaptureState(remaining: deadline.timeIntervalSinceNow),
           let fresh = await captureState(in: tab, before: deadline) {
            after = fresh
            if let sampledEpoch = decisionState.epoch, fresh.epoch != sampledEpoch { settled = false }
            finalCaptureSkipped = false
        } else {
            let last = samples.last
            after = PageState(url: last?.url ?? tab.webView.url?.absoluteString ?? "", title: "", text: last?.text ?? "", elements: [], epoch: tab.documentEpoch)
        }
        if Task.isCancelled { settled = false }
        return SettledCapture(samples: samples, settled: settled, after: after, finalCaptureSkipped: finalCaptureSkipped)
    }

    private func captureState(in tab: BrowserTab, before deadline: Date) async -> PageState? {
        await withCheckedContinuation { continuation in
            let gate = CaptureDeadlineGate(continuation)
            let work = Task { @MainActor in
                gate.finish(try? await self.state(in: tab, forCapture: true))
            }
            Task { @MainActor in
                let ms = max(1, Int(deadline.timeIntervalSinceNow * 1000))
                try? await Task.sleep(for: .milliseconds(ms))
                work.cancel()
                gate.finish(nil)
            }
        }
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

    // MARK: - 自检二十（TRUSTED-CLICK-EXP）：E1 金标准对照插桩＋E2 AX 激活探针
    //
    // 依据调研备忘（research_notes/trusted-click-2026-11-03/MEMO.md）：
    // JS 注入产不出 isTrusted=true 是规范＋源码级定论；未证的只剩
    // ①弹窗无响应的真实成因（九类表，须金标准对照分清）、②AX 无障碍
    // 激活这条 UA 内部路径宿主侧够不够得到。本节提供实验设施：
    // E1 只读插桩（BrowserTab.tcProbeScript，arm/dump/disarm 三令经
    // postMessage 洪泛＋FrameProbeHub 按 token 收集）与 E2 宿主侧
    // 无障碍树枚举＋accessibilityActivate()。E1 的真机金标准（真实
    // 条款弹窗上 Joey 真点一次再由 agent 重放 diff）不在自检页内，
    // 插桩装上即可采、步骤见案卷；E3 受 E1 真机结果门控，本节不做。

    /// 一帧的插桩回報（E1 dump）。
    struct TCProbeReport {
        let path: String
        let href: String
        let isTop: Bool
        let events: [[String: Any]]
        let mutations: [[String: Any]]
        let truncated: Bool
    }

    private final class TCMessageBox {
        var reports: [TCProbeReport] = []
    }

    private func floodTC(on tab: BrowserTab, kind: String, token: String) async {
        let script = "(()=>{const d={__mikaTC:1,kind:'\(kind)',token:'\(token)'};window.postMessage(d,'*');return 'flooded';})()"
        _ = try? await evaluate(script, on: tab)
    }

    /// 武装插桩：返回本次实验 token（dump/disarm 以同一 token 对话）。
    func armTCProbe(on tab: BrowserTab) async -> String {
        let token = UUID().uuidString
        await floodTC(on: tab, kind: "arm", token: token)
        return token
    }

    /// 收取各 frame 的插桩回報（900ms 窗口，与 frame 普查同口径）。
    func dumpTCProbe(on tab: BrowserTab, token: String) async -> [TCProbeReport] {
        let box = TCMessageBox()
        FrameProbeHub.shared.register(webView: tab.webView, token: token) { body in
            guard (body["kind"] as? String) == "tc-report" else { return }
            box.reports.append(TCProbeReport(
                path: (body["path"] as? String) ?? "?",
                href: (body["href"] as? String) ?? "",
                isTop: (body["isTop"] as? Bool) ?? false,
                events: (body["events"] as? [[String: Any]]) ?? [],
                mutations: (body["mutations"] as? [[String: Any]]) ?? [],
                truncated: (body["truncated"] as? Bool) ?? false))
        }
        defer { FrameProbeHub.shared.unregister(token: token) }
        await floodTC(on: tab, kind: "dump", token: token)
        try? await Task.sleep(for: .milliseconds(900))
        return box.reports
    }

    func disarmTCProbe(on tab: BrowserTab, token: String) async {
        await floodTC(on: tab, kind: "disarm", token: token)
    }

    /// E2 宿主侧无障碍树递归枚举：从给定根（WKWebView）出发，优先走
    /// accessibilityElements 数组、否则走 count/at 索引通道；以对象
    /// 身份去重、深度与总量双封顶，防止容器自引用把遍历拖死。
    private func collectAXElements(from root: NSObject) -> [NSObject] {
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ el: NSObject, _ depth: Int) {
            guard depth <= 14, out.count < 800 else { return }
            guard seen.insert(ObjectIdentifier(el)).inserted else { return }
            out.append(el)
            var children: [NSObject] = []
            if let arr = el.accessibilityElements as? [NSObject], !arr.isEmpty {
                children = arr
            } else {
                let n = el.accessibilityElementCount()
                if n > 0, n < 1000 {
                    for i in 0..<n {
                        if let c = el.accessibilityElement(at: i) as? NSObject { children.append(c) }
                    }
                }
            }
            for c in children { walk(c, depth + 1) }
        }
        walk(root, 0)
        return out
    }

    /// 自检二十·Tier A（TRUSTED-CLICK-EXP）：在合成页 test-trusted 上
    /// 完成 agent 侧可自完的全部实验——
    /// E1：武装只读插桩 → 普通按钮走引擎 click（阴性对照）→ 打开触摸
    /// 状态机复刻弹窗 → 派现行 pointer 序列＋合成 TouchEvent 序列 →
    /// dump 插桩与页面自有事件账逐字段对照（touches 恒空双证、
    /// isTrusted 全 false、弹窗保持打开＝现象复现）；
    /// E2：重载页面 → 宿主侧枚举本页无障碍树 → 按 aria-label 定位
    /// 探针按钮 → 公开 API accessibilityActivate() → 回读页面计数与
    /// isTrusted 证据，按规格判据给「通／不通＋卡点层」结论。
    /// 实验合成一份结构化 JSON 落盘（TCProbeLogStore）。
    func verifyTrustedClickExp() async -> [String] {
        var lines: [String] = []
        let tab = activeTab
        func fmt(_ ok: Bool) -> String { ok ? "✓" : "✗" }
        func pageJSON(_ expr: String) async -> [String: Any]? {
            guard let raw = try? await evaluate(expr, on: tab) as? String,
                  let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return obj
        }
        func tcState() async -> [String: Any]? { await pageJSON("(()=>{return window.__tcState?window.__tcState():'{}';})()") }
        func axState() async -> [String: Any]? { await pageJSON("(()=>{return window.__axState?window.__axState():'{}';})()") }
        var payload: [String: Any] = ["experiment": "TRUSTED-CLICK-EXP", "page": "test-trusted",
                                      "startedAt": ISO8601DateFormatter().string(from: Date())]

        do { try tab.loadLocal("test-trusted") } catch {
            return ["✗ 合成页 test-trusted 加载失败：\(error.localizedDescription)"]
        }
        try? await Task.sleep(for: .milliseconds(1100))

        // ---------- E1：插桩对照与 touches 恒空复现 ----------
        let token = await armTCProbe(on: tab)
        try? await Task.sleep(for: .milliseconds(250))

        var normalOK = false
        if let page = try? await state(), let btn = page.elements.first(where: { $0.text.contains("普通计数按钮") }),
           let action = Self.selfTestClickAction(index: btn.index) {
            do { try await execute(action, expected: btn) } catch {}
            try? await Task.sleep(for: .milliseconds(350))
            if let st = await tcState() { normalOK = (st["normalClicks"] as? Int) == 1 }
        }
        lines.append("\(fmt(normalOK)) E1 对照：普通按钮经引擎 click 后页面计数=1 期望成立=\(normalOK)（插桩与派发管线对普通控件有效，阴性对照成立）")

        _ = try? await evaluate("(()=>{if(window.__tcOpenDialog)window.__tcOpenDialog();return 'opened';})()", on: tab)
        try? await Task.sleep(for: .milliseconds(300))

        let seqResult = (try? await evaluate("""
        (()=>{const el=document.getElementById('tcAgree');if(!el)return 'missing';
        const steps=['pointerover','pointerdown','mousedown','focus','pointerup','mouseup','click'];
        return new Promise(res=>{let i=0;const next=()=>{if(i>=steps.length){res('done');return;}
          const step=steps[i++];try{const r=el.getBoundingClientRect();const x=r.left+r.width/2,y=r.top+r.height/2;
          if(step==='focus'){el.focus();}
          else if(step==='click'){el.click();}
          else{const down=step==='pointerdown'||step==='mousedown';
            const opts={bubbles:true,composed:true,cancelable:true,clientX:x,clientY:y,button:0,buttons:down?1:0,view:window};
            let ev=null;
            if(step.indexOf('pointer')===0){try{ev=new PointerEvent(step,Object.assign({},opts,{pointerId:1,pointerType:'mouse',isPrimary:true}));}catch(_){}}
            if(!ev){try{ev=new MouseEvent(step,opts);}catch(__){}}
            if(ev)el.dispatchEvent(ev);}
          }catch(_){}
          setTimeout(next,70);};next();});})()
        """, on: tab) as? String) ?? "evaluate-failed"
        let touchResult = (try? await evaluate("""
        (()=>{const el=document.getElementById('tcAgree');if(!el)return 'missing';
        try{el.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,composed:true,cancelable:true,touches:[],targetTouches:[],changedTouches:[]}));}catch(e){return 'touchstart-threw:'+((e&&e.name)||'Error');}
        try{el.dispatchEvent(new TouchEvent('touchend',{bubbles:true,composed:true,cancelable:true,touches:[],targetTouches:[],changedTouches:[]}));}catch(e){return 'touchend-threw:'+((e&&e.name)||'Error');}
        return 'dispatched';})()
        """, on: tab) as? String) ?? "evaluate-failed"
        try? await Task.sleep(for: .milliseconds(350))

        let pageAfter = await tcState()
        let decisions = (pageAfter?["decisions"] as? [[String: Any]]) ?? []
        let pageLog = (pageAfter?["log"] as? [[String: Any]]) ?? []
        let dialogStillOpen = (pageAfter?["dialogOpen"] as? Bool) == true
        let ignoredEmpty = decisions.contains { ($0["verdict"] as? String) == "ignored-empty-touches" }
        let pageTouchEnd = pageLog.filter { ($0["type"] as? String) == "touchend" }
        let pageTouchEndEmpty = !pageTouchEnd.isEmpty && pageTouchEnd.allSatisfy { ($0["ct"] as? Int) == 0 }
        lines.append("\(fmt(dialogStillOpen && ignoredEmpty)) E1 复刻弹窗：现行 pointer 序列（\(seqResult)）＋合成触摸序列（\(touchResult)）之后弹窗仍打开=\(dialogStillOpen)、状态机「空 touches 忽略」判读在场=\(ignoredEmpty)（现象复现：合成序列关不掉触摸状态机弹窗）")
        lines.append("\(fmt(pageTouchEndEmpty)) E1 现象双证·页面账：页面自有监听收到 touchend \(pageTouchEnd.count) 笔、changedTouches.length 全部为 0=\(pageTouchEndEmpty)；Touch 构造器实测＝\((pageAfter?["touchCtor"] as? String) ?? "未记录")（MEMO §5 结构性缺口）")

        let reports = await dumpTCProbe(on: tab, token: token)
        await disarmTCProbe(on: tab, token: token)
        let top = reports.first(where: { $0.isTop }) ?? reports.first
        let dumpEvents = top?.events ?? []
        func dumpCount(_ type: String) -> Int { dumpEvents.filter { ($0["type"] as? String) == type }.count }
        func pageCount(_ type: String) -> Int { pageLog.filter { ($0["type"] as? String) == type }.count }
        let sharedTypes = ["pointerdown", "pointerup", "mousedown", "mouseup", "click", "touchstart", "touchend"]
        let countsAgree = top != nil && sharedTypes.allSatisfy { dumpCount($0) == pageCount($0) }
        let dumpTouchEnd = dumpEvents.filter { ($0["type"] as? String) == "touchend" }
        let dumpTouchEndEmpty = !dumpTouchEnd.isEmpty && dumpTouchEnd.allSatisfy { ($0["ct"] as? Int) == 0 }
        let anyTrusted = dumpEvents.contains { ($0["trusted"] as? Bool) == true }
        lines.append("\(fmt(countsAgree)) E1 插桩对照：dump 回報 frame 数=\(reports.count)（主 frame 事件 \(dumpEvents.count) 笔、DOM 变化 \(top?.mutations.count ?? 0) 笔、截断=\(top?.truncated == true)）；逐类型计数与页面账一致=\(countsAgree)（click 插桩 \(dumpCount("click"))／页面 \(pageCount("click"))；touchend 插桩 \(dumpCount("touchend"))／页面 \(pageCount("touchend"))）——插桩工作正常")
        lines.append("\(fmt(dumpTouchEndEmpty && !anyTrusted)) E1 现象双证·插桩账：插桩侧 touchend 的 changedTouches.length 全部为 0=\(dumpTouchEndEmpty)；全部 \(dumpEvents.count) 笔事件 isTrusted 均为 false=\(!anyTrusted)（合成事件信任位恒假，与 MEMO §2 一致）")
        payload["e1"] = ["normalButtonOK": normalOK, "dialogStillOpen": dialogStillOpen,
                         "touchCtor": (pageAfter?["touchCtor"] as? String) ?? "",
                         "pointerSeq": seqResult, "touchSeq": touchResult,
                         "pageDecisions": decisions,
                         "dumpFrames": reports.map { ["path": $0.path, "href": $0.href, "isTop": $0.isTop,
                                                       "events": $0.events, "mutations": $0.mutations,
                                                       "truncated": $0.truncated] }] as [String: Any]

        // ---------- E2：AX 激活探针 ----------
        do { try tab.loadLocal("test-trusted") } catch {
            lines.append("✗ E2 未执行：合成页重载失败（\(error.localizedDescription)）")
            if let name = TCProbeLogStore.save(payload: payload) { lines.append("· 实验结构化日志已落盘：\(name)") }
            return lines
        }
        try? await Task.sleep(for: .milliseconds(1100))
        let tree = collectAXElements(from: tab.webView)
        let target = tree.first { ($0.accessibilityLabel ?? "").contains("AX探针目标按钮") }
        var e2Passed = false
        var e2Verdict = ""
        if let target {
            let activated = target.accessibilityActivate()
            try? await Task.sleep(for: .milliseconds(700))
            let ax = await axState()
            let clicks = (ax?["clicks"] as? Int) ?? 0
            let axEvents = (ax?["events"] as? [[String: Any]]) ?? []
            let trustedClick = axEvents.contains { ($0["type"] as? String) == "click" && ($0["isTrusted"] as? Bool) == true }
            if clicks > 0 {
                e2Passed = true
                e2Verdict = trustedClick
                    ? "通：页面收到 click 且 isTrusted=true——UA 内部激活路径成立（字段证据在实验日志）"
                    : "通（动作生效口径）：页面 click 计数=\(clicks)，控件动作确实生效；但收到的 click isTrusted=false（如实记录：激活有效、信任位未如假设翻真）"
            } else {
                e2Verdict = "不通：目标元素可达、accessibilityActivate() 已调用（返回 \(activated)），页面未收到任何 click——卡在 UA 内部激活转化层"
            }
            lines.append("\(fmt(e2Passed)) E2 AX 探针：无障碍树共 \(tree.count) 个元素、按 aria-label 命中目标（button trait=\(target.accessibilityTraits.contains(.button))）；activate 返回 \(activated)；页面 click 计数=\(clicks)、isTrusted=true 的 click 在场=\(trustedClick)。判定：\(e2Verdict)")
        } else {
            e2Verdict = "不通：宿主够不到网页目标元素（无障碍树元素 \(tree.count) 个，未命中 aria-label 目标）——卡在宿主可达层"
            lines.append("✗ E2 AX 探针：无障碍树共 \(tree.count) 个元素、未命中 aria-label 目标——不通，卡在「宿主够不到网页目标元素」层（树为 0＝WebKit 未建树；树非空未命中＝网页元素未以 label 暴露）")
        }
        payload["e2"] = ["treeCount": tree.count, "targetFound": target != nil,
                         "passed": e2Passed, "verdict": e2Verdict] as [String: Any]
        if let name = TCProbeLogStore.save(payload: payload) {
            lines.append("· 实验结构化日志已落盘：\(name)（自检页顶部可导出最近一份；真机 E1 金标准同通道落盘）")
        } else {
            lines.append("✗ 实验结构化日志落盘失败")
        }
        return lines
    }

    // MARK: - 失败留证（写入既有 DiagnosticStore 通道：同目录、同信封格式，诊断页可见）

    /// agent 操作失败时存一份快照：页面截图（JPEG base64）＋精简 DOM 摘要（候选按钮与禁用状态）。
    /// 全程尽力而为：抓取失败不掩盖原始错误。
    private func captureFailureSnapshot(context: String, tab: BrowserTab) async {
        var thermalGate = ThermalGate()
        thermalGate.update(level: ThermalLevel(ProcessInfo.processInfo.thermalState), now: Date())
        guard thermalGate.allowsNonEssential() else { return }
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
