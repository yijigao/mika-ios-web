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
        do { return try JSONDecoder().decode(PageState.self, from: Data(json.utf8)) }
        catch { throw MikaError("页面状态解析失败，请刷新页面后重试") }
    }
    func execute(_ action: AgentAction, expected: PageElement? = nil, approved: Bool = false) async throws {
        switch action.action {
        case "navigate": try load(action.url)
        case "scroll":
            guard ["up", "down"].contains(action.direction) else { throw MikaError("未知滚动方向") }
            _ = try await evaluate("window.scrollBy(0, \(action.direction == "up" ? "-" : "")window.innerHeight*0.85)")
        case "wait": try await Task.sleep(for: .seconds(min(15, max(0.1, action.seconds))))
        case "click": try await performClick(action, expected: expected, approved: approved)
        case "type": try await performType(action, expected: expected, approved: approved)
        default: throw MikaError("不可执行动作")
        }
    }

    // MARK: - FIX2 硬化：输入注入（缺陷 2 主攻）与点击等待重扫

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
    private func runTypeScript(action: AgentAction, expected: PageElement, approved: Bool, path: String) async throws -> String {
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
        """)
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
    private func verifyType(action: AgentAction) async throws -> TypeVerification {
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
        """) as? String, let decoded = try? JSONDecoder().decode(TypeVerification.self, from: Data(raw.utf8)) else {
            throw MikaError("输入后回读校验失败（页面无响应）")
        }
        return decoded
    }

    /// type 总流程：写入→回读；不过关换备用路径重试一次；仍不过关如实报「没输入进去」，
    /// 不再误报成「找不到发表按钮」。文字已进但提交按钮全员禁用时单独报「按钮是灰的」。
    private func performType(_ action: AgentAction, expected: PageElement?, approved: Bool) async throws {
        guard let expected else { throw MikaError("缺少已检查的目标元素") }
        for path in ["exec", "range"] {
            let status = try await runTypeScript(action: action, expected: expected, approved: approved, path: path)
            if status == "exec-failed" { continue }
            try await Task.sleep(for: .milliseconds(400))
            let v = try await verifyType(action: action)
            guard v.found else { throw MikaError("输入后目标元素已失效，请重新开始或继续") }
            if v.textOK {
                if v.editorLike, !v.submits.isEmpty, v.submits.allSatisfy({ $0.disabled }) {
                    await captureFailureSnapshot(context: "type 后提交按钮仍禁用：\(action.reason)")
                    throw MikaError("文字已输入，但「\(v.submits[0].text)」按钮仍是灰的（禁用状态），没能发布")
                }
                return
            }
        }
        await captureFailureSnapshot(context: "type 回读校验失败：\(action.reason)")
        throw MikaError("文字没能输入到编辑器：两种写入方式都已尝试、回读仍为空或对不上，请在网页手动输入后点继续")
    }

    /// click 单次尝试脚本，返回 'clicked'／'disabled'／'missing'（校验不过仍走 JS throw，与旧口径一致）。
    /// rescan=true 时不做快照一致性校验（页面可能已重渲染），按原 data-mika-idx 节点或同文案候选重新定位，
    /// 并对命中节点复用同一套安全词检查。
    private func runClickScript(action: AgentAction, expected: PageElement, approved: Bool, rescan: Bool) async throws -> String {
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
        let result = try await evaluate(script)
        return (result as? String) ?? "missing"
    }

    /// click 总流程：先按已校验元素点；禁用/缺失时「等待＋重扫」轮询约 3.6 秒（编辑器状态更新后
    /// 按钮常延迟启用或被重渲染替换）；最终按「是灰的／找不到」两种口径分别报错并留诊断快照。
    private func performClick(_ action: AgentAction, expected: PageElement?, approved: Bool) async throws {
        guard let expected else { throw MikaError("缺少已检查的目标元素") }
        var status = try await runClickScript(action: action, expected: expected, approved: approved, rescan: false)
        if status == "clicked" { return }
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(300))
            status = try await runClickScript(action: action, expected: expected, approved: approved, rescan: true)
            if status == "clicked" { return }
        }
        let label = expected.text.isEmpty ? expected.ariaLabel : expected.text
        if status == "disabled" {
            await captureFailureSnapshot(context: "click 目标禁用：\(action.reason)")
            throw MikaError("「\(label)」按钮是灰的（存在但被禁用），无法点击")
        }
        await captureFailureSnapshot(context: "click 目标缺失：\(action.reason)")
        throw MikaError("页面上找不到要点的按钮「\(label)」（可能还没渲染出来或已经关闭）")
    }

    // MARK: - 失败留证（写入既有 DiagnosticStore 通道：同目录、同信封格式，诊断页可见）

    /// agent 操作失败时存一份快照：页面截图（JPEG base64）＋精简 DOM 摘要（候选按钮与禁用状态）。
    /// 全程尽力而为：抓取失败不掩盖原始错误。
    private func captureFailureSnapshot(context: String) async {
        let domSummary = (try? await evaluate("""
        (()=>{const vis=x=>{const r=x.getBoundingClientRect(),s=getComputedStyle(x);return r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none';};
        const lab=x=>(x.innerText||x.value||x.getAttribute('aria-label')||'').trim().slice(0,40);
        const dis=x=>x.disabled===true||x.getAttribute('aria-disabled')==='true';
        const buttons=[...document.querySelectorAll('button,[role="button"],input[type="submit"],a')].filter(vis).slice(0,12).map(x=>({text:lab(x),tag:x.tagName.toLowerCase(),disabled:dis(x)}));
        const editors=[...document.querySelectorAll('[contenteditable="true"],textarea')].filter(vis).map(x=>({tag:x.tagName.toLowerCase(),textLength:(x.innerText||x.value||'').length}));
        return JSON.stringify({url:location.href,title:document.title,buttons,editors});})()
        """)) as? String ?? ""
        var payload: [String: Any] = ["kind": "agent-action-failure", "context": context, "url": webView.url?.absoluteString ?? "", "domSummary": domSummary]
        if let shot = await snapshotBase64() { payload["screenshotJPEGBase64"] = shot }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MikaWeb/Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID(), now = Date(), formatter = ISO8601DateFormatter()
        let envelope: [String: Any] = ["schemaVersion": 1, "id": id.uuidString, "receivedAt": formatter.string(from: now), "types": ["操作失败快照"], "payload": payload]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]) else { return }
        let name = formatter.string(from: now).replacingOccurrences(of: ":", with: "-") + "-" + id.uuidString + ".json"
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private func snapshotBase64() async -> String? {
        await withCheckedContinuation { continuation in
            let config = WKSnapshotConfiguration()
            config.afterScreenUpdates = false
            webView.takeSnapshot(with: config) { image, _ in
                if let image, let data = image.jpegData(compressionQuality: 0.5) {
                    continuation.resume(returning: data.base64EncodedString())
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
