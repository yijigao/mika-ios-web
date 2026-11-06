import Foundation
import UIKit
import WebKit

/// 所有离屏 WK 自检共用的宿主屏障。它固定非零视口、等待“本次”导航代次
/// didFinish，并把超时现场（视口、导航、DOM、脚本错误）写入 trace 后再失败。
@MainActor final class WKSelfTestHost {
    let tab: BrowserTab
    let suite: String
    private(set) var observations: [[String: Any]] = []

    init(tab: BrowserTab, suite: String) {
        self.tab = tab
        self.suite = suite
        tab.webView.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        tab.webView.layoutIfNeeded()
    }

    @discardableResult
    func loadLocalAndWait(_ name: String, readinessJavaScript: String,
                          timeout: TimeInterval = 12) async throws -> [String: Any] {
        let previousEpoch = tab.documentEpoch
        try tab.loadLocal(name)
        return try await wait(afterEpoch: previousEpoch, expectedPath: "\(name).html",
                              readinessJavaScript: readinessJavaScript, timeout: timeout)
    }

    @discardableResult
    func wait(afterEpoch: Int? = nil, expectedPath: String? = nil,
              readinessJavaScript: String, timeout: TimeInterval = 12) async throws -> [String: Any] {
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + timeout
        var attempts = 0
        var last: [String: Any] = [:]
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            attempts += 1
            let nativeReady = !tab.webView.isLoading && tab.finishedDocumentEpoch == tab.documentEpoch &&
                (afterEpoch.map { tab.documentEpoch > $0 } ?? true) &&
                (expectedPath.map { tab.webView.url?.lastPathComponent == $0 } ?? true)
            last = await capture(readinessJavaScript: readinessJavaScript)
            last["suite"] = suite
            last["attempts"] = attempts
            last["isLoading"] = tab.webView.isLoading
            last["documentEpoch"] = tab.documentEpoch
            last["finishedDocumentEpoch"] = tab.finishedDocumentEpoch ?? -1
            last["nativeReady"] = nativeReady
            last["pageError"] = tab.pageError ?? ""
            observations.append(last.filter { $0.key != "dom" })
            if nativeReady, last["ready"] as? Bool == true { return last }
            try await Task.sleep(for: .milliseconds(100))
        }
        last = await capture(readinessJavaScript: readinessJavaScript)
        let dom = last["dom"] as? String ?? ""
        let attachment = AgentTraceStore.shared.storeAttachment(dom)
        let evidence: [String: Any] = [
            "suite": suite, "attempts": attempts,
            "viewport": last["viewport"] ?? [String: Any](), "navigation": [
                "isLoading": tab.webView.isLoading, "documentEpoch": tab.documentEpoch,
                "finishedDocumentEpoch": tab.finishedDocumentEpoch ?? -1,
                "url": tab.webView.url?.absoluteString ?? ""
            ],
            "host": last.filter { $0.key != "dom" }, "domAttachment": attachment,
            "scriptErrors": last["scriptErrors"] ?? [Any]()
        ]
        AgentTraceStore.shared.appendEngineAction(action: "wk-selftest-host-ready",
            targetFingerprint: suite, method: "viewport+navigation-epoch+dom-ready",
            result: "timeout", pageURL: tab.webView.url?.absoluteString ?? "", evidence: evidence)
        let encoded = (try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        throw MikaError("WK self-test host timeout: \(encoded)")
    }

    /// 宿主就绪后的断言/异常出口也走同一现场交付路径，而不只覆盖等待超时。
    func captureFailure(_ context: String) async {
        let snapshot = await capture(readinessJavaScript: "false")
        let dom = snapshot["dom"] as? String ?? ""
        let attachment = AgentTraceStore.shared.storeAttachment(dom)
        AgentTraceStore.shared.appendEngineAction(action: "wk-selftest-failure",
            targetFingerprint: suite, method: "unified-failure-snapshot", result: "failed",
            pageURL: tab.webView.url?.absoluteString ?? "", evidence: [
                "suite": suite, "context": context, "domAttachment": attachment,
                "host": snapshot.filter { $0.key != "dom" },
                "navigation": ["isLoading": tab.webView.isLoading,
                    "documentEpoch": tab.documentEpoch,
                    "finishedDocumentEpoch": tab.finishedDocumentEpoch ?? -1,
                    "url": tab.webView.url?.absoluteString ?? ""]
            ])
    }

    private func capture(readinessJavaScript: String) async -> [String: Any] {
        let script = """
        (()=>{let ready=false,probeError=null;try{ready=!!(\(readinessJavaScript));}catch(e){probeError=String(e?.stack||e);}
          return JSON.stringify({ready,probeError,href:location.href,documentReady:document.readyState,
            viewport:{width:innerWidth,height:innerHeight},bodyText:(document.body?.innerText||'').slice(0,4000),
            dom:document.documentElement?.outerHTML||'',scriptErrors:window.__type4Errors||[]});})()
        """
        do {
            let raw = try await tab.webView.evaluateJavaScript(script)
            guard let text = raw as? String,
                  let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                return ["ready": false, "probeError": "probe returned invalid JSON"]
            }
            return object
        } catch {
            return ["ready": false, "probeError": error.localizedDescription,
                    "viewport": ["width": Double(tab.webView.bounds.width), "height": Double(tab.webView.bounds.height)],
                    "dom": "", "scriptErrors": []]
        }
    }
}
