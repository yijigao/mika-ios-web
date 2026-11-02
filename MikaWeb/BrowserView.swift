import SwiftUI
import WebKit
struct WebSurface: UIViewRepresentable {
    @ObservedObject var controller: WebController
    func makeUIView(context: Context) -> WKWebView { controller.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
struct BrowserView: View {
    @ObservedObject var controller: WebController
    /// 标签 UI 只在展开态出现（浮窗小窗态为 false，由 BrowserDockView 传入）
    var showsTabsUI: Bool = true
    /// 「返回执行页」（M1）：任务在别的会话的标签上执行时，会话条上给出
    /// 此入口（由 BrowserDockView 透传、ContentView 提供编排）。
    var onReturnToExecution: (() -> Void)? = nil
    @ObservedObject private var sessionStore = SessionStore.shared
    @State private var address = ""
    @State private var showTabs = false
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Button { controller.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!controller.canGoBack).accessibilityLabel("后退")
                Button { controller.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!controller.canGoForward).accessibilityLabel("前进")
                TextField("网址", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit { do { try controller.load(address) } catch { controller.pageError = error.localizedDescription } }
                Button { controller.reload() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("刷新")
                if showsTabsUI {
                    Button { showTabs = true } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "square.on.square")
                            Text("\(controller.visibleTabs.count)").font(.caption.weight(.semibold))
                        }
                    }
                    .accessibilityLabel("标签页，共 \(controller.visibleTabs.count) 个")
                }
            }.padding(.horizontal)
            if showsTabsUI {
                // 会话条（M1）：标明当前页面所属会话；任务在别的会话执行
                // 时明示并给「返回执行页」入口——切会话不自动导航执行
                // 标签，回去只能经这个用户动作（或会话列表切换）。
                HStack(spacing: 6) {
                    Text("会话「\(displayedSessionTitle)」")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text("· \(controller.visibleTabs.count) 个标签")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let execSession = controller.executionSessionID, execSession != controller.displayedSessionID {
                        Text("任务在会话「\(sessionTitle(execSession))」执行中")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                        if let onReturnToExecution {
                            Button("返回执行页") { onReturnToExecution() }
                                .font(.caption)
                                .buttonStyle(.bordered)
                        }
                    }
                }.padding(.horizontal)
            }
            if controller.progress < 1 { ProgressView(value: controller.progress) }
            if let error = controller.pageError { Text(error).font(.caption).foregroundStyle(.red) }
            // 按当前标签换入其 WKWebView：离屏标签的实例由 BrowserTab 强持有保活，
            // 换回时不重载（网页进程被系统杀掉的标签在恢复时按地址重载，见 BrowserTab）。
            WebSurface(controller: controller)
                .id(controller.activeTabID)
        }.onChange(of: controller.address) { _, value in address = value }
        .sheet(isPresented: $showTabs) {
            TabsOverviewView(controller: controller)
        }
    }
    private var displayedSessionTitle: String { sessionTitle(controller.displayedSessionID) }
    private func sessionTitle(_ id: UUID) -> String {
        sessionStore.sessions.first(where: { $0.id == id })?.title ?? "会话"
    }
}
