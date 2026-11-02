import SwiftUI
import WebKit

// 触摸网页闪退最小化阶梯（CRASH-LADDER-2026-11-02）。本文件只存在于 crash-ladder 分支，主线无此文件。
// 阶梯定义：H0 裸 WKWebView → H1 加 1652 形态浏览器 chrome → H2 换现行 BrowserView/WebSurface/WebController 地基。
// 三个构建之间唯一的源码差异是 Harness.step 的取值（0/1/2），其余代码逐字相同。
// 三阶共同点：
// 1. 起始页与生产 App 完全一致——startPageHTML 是 WebController.init 里 loadHTMLString 的原文，
//    WKWebView 配置（WKWebViewConfiguration + websiteDataStore=.default()）与 customUserAgent 亦与 WebController 原文一致。
// 2. 均带 DiagnosticStore + MetricKit 崩溃报告导出（右下角按钮打开 CrashReportsView），该包装三阶恒定。
enum Harness {
    static let step = 2
    static var stepName: String { "H\(step)" }
    static let startPageHTML = "<!doctype html><html lang='zh-CN'><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Mika Web</title><body><h1>Mika Web</h1><p>在地址栏打开网页，或输入包含网址的任务。</p></body></html>"
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
}

// 裸 WKWebView 持有者：无 ObservableObject、无 @Published、无 navigationDelegate、无 KVO 观察。
// 创建与加载口径与 WebController.init 一致（配置、UA、起始页），差别仅在「不装配观察与代理」。
final class HarnessWebBox {
    let webView: WKWebView
    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Harness.userAgent
        webView.loadHTMLString(Harness.startPageHTML, baseURL: nil)
    }
    // 地址校验口径与 WebController.load 一致（补 https、仅 http/https、须有 host）；无效输入静默不加载（本层无 pageError 呈现）。
    func loadAddress(_ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value.contains("://") ? value : "https://" + value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return }
        webView.load(URLRequest(url: url))
    }
}

// 裸 representable：makeUIView 直接返回持有者创建的 WKWebView，updateUIView 空操作，无 Coordinator。
struct HarnessBareSurface: UIViewRepresentable {
    let box: HarnessWebBox
    func makeUIView(context: Context) -> WKWebView { box.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct HarnessRootView: View {
    @ObservedObject var diagnostics: DiagnosticStore
    @State private var showReports = false
    var body: some View {
        Group {
            if Harness.step == 0 {
                HarnessH0View()
            } else if Harness.step == 1 {
                HarnessH1View()
            } else {
                HarnessH2View()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(spacing: 2) {
                Button { showReports = true } label: {
                    Image(systemName: "waveform.path.ecg")
                        .padding(10)
                        .background(.regularMaterial, in: Circle())
                }
                .accessibilityLabel("崩溃报告")
                Text(Harness.stepName).font(.caption2).foregroundStyle(.secondary)
            }
            .padding()
        }
        .sheet(isPresented: $showReports) {
            NavigationStack { CrashReportsView(store: diagnostics) }
        }
    }
}

// H0：单屏只有裸 WKWebView 一层（外加三阶恒定的诊断导出包装）。
struct HarnessH0View: View {
    @State private var box = HarnessWebBox()
    var body: some View {
        HarnessBareSurface(box: box)
    }
}

// H1：H0 + 1652 形态浏览器 chrome（NavigationStack + toolbar + 地址栏行），WebView 仍用裸 representable。
// 与 1652 BrowserView 的已知差别（均为观察/代理装配，属 H2 层）：前进/后退无 canGoBack/canGoForward 门控；
// 无进度条行与 pageError 行；地址栏不与 webView.url 同步（仅 onSubmit 直连加载）；
// toolbar 不含自检/设置导航项（依赖地基之上的 App 装配），仅放阶梯标记，toolbar 层本身在场。
struct HarnessH1View: View {
    @State private var box = HarnessWebBox()
    @State private var address = ""
    var body: some View {
        NavigationStack {
            VStack(spacing: 4) {
                HStack {
                    Button { box.webView.goBack() } label: { Image(systemName: "chevron.left") }.accessibilityLabel("后退")
                    Button { box.webView.goForward() } label: { Image(systemName: "chevron.right") }.accessibilityLabel("前进")
                    TextField("网址", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit { box.loadAddress(address) }
                    Button { box.webView.reload() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("刷新")
                }.padding(.horizontal)
                HarnessBareSurface(box: box)
            }
            .navigationTitle("Mika Web").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text(Harness.stepName).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// H2：H1 的 chrome 骨架内换现行地基原文——BrowserView/WebSurface/WebController 均为仓库现行文件逐字使用；
// 底部为静态占位视图，不接 AgentConsole/AgentChat，不带 conversation store 与 AgentEngine。
// 注：WebController 由本视图以 @StateObject 持有（生产 App 由 MikaWebApp 持有），构造时机不同，BrowserView 挂载语境为原文。
struct HarnessH2View: View {
    @StateObject private var web = WebController()
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                BrowserView(controller: web).frame(maxHeight: .infinity)
                Divider()
                Text("阶梯占位：底部区域（无控制台 / 无对话）")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                    .background(Color(uiColor: .secondarySystemBackground))
            }
            .navigationTitle("Mika Web").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text(Harness.stepName).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
