import SwiftUI
import WebKit
@MainActor final class WebController: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published var address = ""
    @Published var progress = 0.0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var pageError: String?
    private var observations: [NSKeyValueObservation] = []
    private(set) var revision = 0
    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        webView.navigationDelegate = self
        webView.loadHTMLString("<!doctype html><html lang='zh-CN'><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Mika Web</title><body><h1>Mika Web</h1><p>在地址栏打开网页，或输入包含网址的任务。</p></body></html>", baseURL: nil)
        observations = [webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.update() } }, webView.observe(\.url, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.update() } }]
    }
    private func update() { address = webView.url?.absoluteString ?? ""; progress = webView.estimatedProgress; canGoBack = webView.canGoBack; canGoForward = webView.canGoForward }
    func load(_ value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value.contains("://") ? value : "https://" + value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw MikaError("请输入有效 http/https 地址") }
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
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { update() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { pageError = error.localizedDescription; update() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { pageError = error.localizedDescription; update() }
    func ready() async throws {
        for _ in 0..<300 {
            try Task.checkCancellation()
            if let pageError { throw MikaError("网页加载失败：\(pageError)") }
            if !webView.isLoading { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw MikaError("网页加载超时")
    }
    func evaluate(_ script: String) async throws -> Any? { try await webView.evaluateJavaScript(script) }
    func state() async throws -> PageState {
        try await ready()
        guard let json = try await evaluate(PageScript.extract) as? String else { throw MikaError("无法抽取页面状态") }
        return try JSONDecoder().decode(PageState.self, from: Data(json.utf8))
    }
    func execute(_ action: AgentAction, expected: PageElement? = nil, approved: Bool = false) async throws {
        switch action.action {
        case "navigate": try load(action.url)
        case "scroll":
            guard ["up", "down"].contains(action.direction) else { throw MikaError("未知滚动方向") }
            _ = try await evaluate("window.scrollBy(0, \(action.direction == "up" ? "-" : "")window.innerHeight*0.85)")
        case "wait": try await Task.sleep(for: .seconds(min(15, max(0.1, action.seconds))))
        case "click", "type":
            let data = try JSONSerialization.data(withJSONObject: ["index": action.index, "text": action.text, "action": action.action])
            let json = String(decoding: data, as: UTF8.self)
            guard let expected else { throw MikaError("缺少已检查的目标元素") }
            let expectedJSON = String(decoding: try JSONEncoder().encode(expected), as: UTF8.self)
            let keywords = String(decoding: try JSONSerialization.data(withJSONObject: SafetyPolicy.keywords), as: UTF8.self)
            _ = try await evaluate("""
            (()=>{const a=\(json),expected=\(expectedJSON);
            const page=JSON.parse(\(PageScript.extract)),target=page.elements.find(x=>x.index===a.index);
            if(!target||!Object.keys(expected).every(k=>target[k]===expected[k]))throw new Error('目标元素已变化');
            if(a.action==='type'&&target.sensitive)throw new Error('敏感字段必须手动输入');
            const label=[target.text,target.placeholder,target.name,target.ariaLabel].join(' ').toLowerCase();
            if(!\(approved ? "true" : "false")&&\(keywords).some(k=>label.includes(k)))throw new Error('敏感操作未经确认');
            const e=document.querySelector('[data-mika-idx="'+a.index+'"]');
            if(!e||!e.isConnected)throw new Error('目标元素已失效');
            e.scrollIntoView({block:'center'});e.focus();
            if(a.action==='click'){e.click();return true;}
            if(e.tagName==='INPUT'||e.tagName==='TEXTAREA'||e.tagName==='SELECT'){
              const p=e.tagName==='INPUT'?HTMLInputElement.prototype:e.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLSelectElement.prototype;
              Object.getOwnPropertyDescriptor(p,'value').set.call(e,a.text);
            }else if(e.isContentEditable){e.textContent=a.text;}else{throw new Error('目标不是可填写元素');}
            e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));return true;})()
            """)
        default: throw MikaError("不可执行动作")
        }
    }
}
