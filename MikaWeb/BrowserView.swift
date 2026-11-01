import SwiftUI
import WebKit
struct WebSurface: UIViewRepresentable {
    @ObservedObject var controller: WebController
    func makeUIView(context: Context) -> WKWebView { controller.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
struct BrowserView: View {
    @ObservedObject var controller: WebController
    @State private var address = ""
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Button { controller.goBack() } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.disabled(!controller.canGoBack).accessibilityLabel("后退")
                Button { controller.goForward() } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.disabled(!controller.canGoForward).accessibilityLabel("前进")
                TextField("网址", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit { do { try controller.load(address) } catch { controller.pageError = error.localizedDescription } }
                Button { controller.reload() } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }.accessibilityLabel("刷新")
            }.padding(.horizontal, 4)
            if controller.progress < 1 { ProgressView(value: controller.progress) }
            if let error = controller.pageError { Text(error).font(.caption).foregroundStyle(.red) }
            WebSurface(controller: controller)
        }.onChange(of: controller.address) { _, value in address = value }
    }
}
