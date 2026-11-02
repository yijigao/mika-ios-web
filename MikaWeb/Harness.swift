import SwiftUI
import WebKit

// 触摸网页闪退最小化阶梯（CRASH-LADDER-2026-11-02；第二轮 CRASH-LADDER-2-2026-11-02）。本文件只存在于阶梯分支，主线无此文件。
// 第一轮阶梯定义：H0 裸 WKWebView → H1 加 1652 形态浏览器 chrome → H2 换现行 BrowserView/WebSurface/WebController 地基。
// 第二轮阶梯定义（crash-ladder-2，step=3/4）：H3 = App 级装配骨架（1652 形态对象图＋流内静态控制台）→ H4 = 加 1652 动态接线（观察扇出/真控制台/pending/toolbar 目的地/scenePhase）。
// 第三轮阶梯定义（CRASH-LADDER-3-2026-11-02，step=7/8/9）：H3a/H3b 真机均崩、A 组单独可触发后，自 H2 基线（step=2 源码状态）把 A 组拆单件——
//   step=7「A-1」只加 A1（App 级持有 WebController＋下传消费）；step=8「A-2」只加 A2（App 级创建 SettingsStore）；
//   step=9「A-2+3」为 A3 的最小耦合阶（AgentEngine init 签名强制 web+settings 两实例，A3 不能独立，详见案卷 CRASH-LADDER-3 §1）。
// 同一轮内构建之间唯一的源码差异是 Harness.step 的取值，其余代码逐字相同（各阶 App 装配差异由 MikaWebApp.init 内的 step 分阶构造承载）。
// 三阶共同点：
// 1. 起始页与生产 App 完全一致——startPageHTML 是 WebController.init 里 loadHTMLString 的原文，
//    WKWebView 配置（WKWebViewConfiguration + websiteDataStore=.default()）与 customUserAgent 亦与 WebController 原文一致。
// 2. 均带 DiagnosticStore + MetricKit 崩溃报告导出（右下角按钮打开 CrashReportsView），该包装三阶恒定。
enum Harness {
    static let step = 7
    static var stepName: String {
        switch step {
        case 5: return "H3a"
        case 6: return "H3b"
        case 7: return "A-1"
        case 8: return "A-2"
        case 9: return "A-2+3"
        default: return "H\(step)"
        }
    }
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
    // 对象图引用由 App 入口按 step 分阶传入，未建的对象为 nil（各阶实际建了哪些对象见 MikaWebApp.init 的分阶构造）：
    // step 0/1/2 三者皆 nil；step 3/4/5/6 三者皆非 nil；step 7 仅 web；step 8 仅 settings；step 9 为 settings＋engine
    //（其 engine 的 web 依赖实例不经此下传）。需要全对象图的视图分支均以 if let 解包，解包失败不挂载（按 init 分阶构造不会发生）。
    let web: WebController?
    let settings: SettingsStore?
    let engine: AgentEngine?
    @ObservedObject var diagnostics: DiagnosticStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showReports = false
    var body: some View {
        Group {
            if Harness.step == 0 {
                HarnessH0View()
            } else if Harness.step == 1 {
                HarnessH1View()
            } else if Harness.step == 3 || Harness.step == 6 {
                if let web, let settings, let engine {
                    HarnessH3View(web: web, settings: settings, engine: engine)
                }
            } else if Harness.step == 5 || Harness.step == 7 {
                // step 5＝H3a（全对象图在场、根视图只消费 web）；step 7＝A-1（对象图只有 web，根视图形态与 H3a 逐字相同，
                // 差异只在 settings/engine 不存在）——两阶共用同一视图，变量纯度由 App 装配承载。
                if let web {
                    HarnessH3aView(web: web)
                }
            } else if Harness.step == 4 {
                if let web, let settings, let engine {
                    HarnessH4View(web: web, settings: settings, engine: engine)
                }
            } else {
                // step 2（H2 基线）与 step 8（A-2）/step 9（A-2+3）：根视图逐字同 H2——WebController 由本视图自持，
                // App 级新建的 settings/engine 不被任何视图消费。
                HarnessH2View()
            }
        }
        // 1652 的 scenePhase 接线（App body 的 onChange → engine.setForeground）：本阶梯挂在根包装、仅 H4（step==4）生效（案卷 CRASH-LADDER-2 §2 登记的挂载点差异）。step 5/6（H3a/H3b）与第三轮各阶必须不生效，否则破坏装配等价性。
        .onChange(of: scenePhase, initial: true) { _, phase in
            if Harness.step == 4, let engine { engine.setForeground(phase == .active) }
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

// H3：H2 ＋ 生产 App 级装配骨架（案卷 CRASH-LADDER-2 §2）。
// 对象图由 App 入口按 1652 形态持有并向下传递（web/settings/engine 均为普通引用 let——根视图不对 settings/engine 声明观察，观察扇出归 H4）；
// 根视图布局按 1652 ContentView 结构：NavigationStack { VStack(spacing: 0) { BrowserView + Divider + 控制台区 } }；
// 控制台区为静态形态（HarnessStaticConsole）；toolbar 仍为阶梯标记（真实导航项归 H4）；AgentEngine 只创建不执行。
struct HarnessH3View: View {
    let web: WebController
    let settings: SettingsStore
    let engine: AgentEngine
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                BrowserView(controller: web).frame(maxHeight: .infinity)
                Divider()
                HarnessStaticConsole()
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

// 控制台静态形态：与 AgentConsoleView 同版式（纵向 TextField＋按钮行＋状态文案），但输入只绑本地 @State、
// 不绑定 engine、无 .focused、不读任何 store 发布、不挂 ScrollView。按钮为禁用态（engine 不执行）。
struct HarnessStaticConsole: View {
    @State private var draft = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("输入网页任务", text: $draft, axis: .vertical).lineLimit(1...3).textFieldStyle(.roundedBorder)
            HStack(spacing: 12) {
                Button("开始") {}.disabled(true)
                Button("停止") {}.disabled(true)
                Spacer()
                Text("步骤 0").font(.caption).foregroundStyle(.secondary)
            }
            Text("待命").font(.callout).foregroundStyle(.secondary)
        }.padding()
    }
}

// H4：H3 ＋ 1652 剩余动态接线（案卷 CRASH-LADDER-2 §2 逐项清单）。
// 本视图逐字复刻 3165943 的 ContentView：@ObservedObject 观察扇出（web/settings/engine）＋ PendingTaskStore 观察与 consumePending、
// toolbar 真实导航项（自检/设置）、真实 AgentConsoleView 子树（$engine.taskText 双向绑定等随原文生效）。
// 与 3165943 的已知差别：scenePhase 接线挂在 HarnessRootView 包装（step>=4 生效）；AgentConsoleView/SettingsView 为仓库现行文件（差异登记见案卷 §1.3）。
struct HarnessH4View: View {
    @ObservedObject var web: WebController
    @ObservedObject var settings: SettingsStore
    @ObservedObject var engine: AgentEngine
    @ObservedObject private var pending = PendingTaskStore.shared
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                BrowserView(controller: web).frame(maxHeight: .infinity)
                Divider()
                AgentConsoleView(engine: engine, settings: settings)
            }
            .navigationTitle("Mika Web").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                NavigationLink { SelfTestView(engine: engine, settings: settings) } label: { Text("自检") }
                NavigationLink { SettingsView(settings: settings) } label: { Image(systemName: "gearshape") }.accessibilityLabel("设置")
            }
        }
        .onAppear { consumePending() }
        .onChange(of: pending.task) { _, _ in consumePending() }
    }
    private func consumePending() {
        if let task = pending.task { engine.stop(); engine.taskText = task; pending.task = nil }
    }
}

// H3a：H2 ＋ A 组装配（案卷 CRASH-LADDER-2 §6）——App 入口对象图与 H3 逐字相同（App 持有 web/settings/engine 并向下传递），
// 根视图保持 H2 形态：BrowserView 消费 App 传入的 web（普通 let 持有）、Divider、120pt 静态占位条；不加 1652 布局与静态控制台（B 组归 H3b）。
// 与 HarnessH2View 的唯一差异：WebController 来源由视图自持 @StateObject 改为 App 传入。
// 第三轮 step 7（A-1，案卷 CRASH-LADDER-3）共用本视图：彼时对象图只有 web（settings/engine 不存在），视图形态不变，变量差异只在 App 装配。
struct HarnessH3aView: View {
    let web: WebController
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
