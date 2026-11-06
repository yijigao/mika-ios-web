import SwiftUI
import UIKit

struct CrashReportsView: View {
    @ObservedObject var store: DiagnosticStore
    @ObservedObject private var traces = AgentTraceStore.shared
    @State private var sharingURL: URL?
    @State private var shareError: String?
    var body: some View {
        List {
            Section("Agent trace") {
                Text("逐步 JSONL，仅保存在本机；实际请求体不含 Authorization 凭据。当前 \(traces.recordCount) 条。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("导出 trace JSONL") {
                    do { sharingURL = try store.prepareTraceShare() }
                    catch { shareError = error.localizedDescription }
                }
                .disabled(traces.recordCount == 0)
            }
            Section {
                Text("崩溃诊断由系统在后续运行期间送达，通常需要崩溃后重新打开 App，可能有延迟，也可能未收到。仅保存在本机，最多保留最近 5 份；分享后将交给你选择的接收方。")
                    .font(.callout)
                Text("报告也可能包含卡顿、CPU 等系统诊断；显示的是接收时间。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = store.storageError { Text(error).foregroundStyle(.red) }
            if let shareError { Text(shareError).foregroundStyle(.red) }
            if store.reports.isEmpty { ContentUnavailableView("暂无系统诊断报告", systemImage: "waveform.path.ecg") }
            ForEach(store.reports) { report in
                VStack(alignment: .leading, spacing: 6) {
                    Text(report.receivedAt == .distantPast ? "接收时间不可读取" : report.receivedAt.formatted(date: .abbreviated, time: .standard))
                    Text(report.types.joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                    if report.readable {
                        Button("分享 JSON") {
                            do { sharingURL = try store.prepareShare(for: report) }
                            catch { shareError = error.localizedDescription }
                        }
                    } else { Text("报告不可读取").foregroundStyle(.red) }
                }
            }
        }
        .navigationTitle("崩溃报告")
        .sheet(item: Binding(get: { sharingURL.map { ShareItem(url: $0) } }, set: { if $0 == nil { sharingURL = nil } }), onDismiss: {
            if let sharingURL { store.finishShare(sharingURL); self.sharingURL = nil }
        }) { item in
            ShareController(url: item.url) { store.finishShare(item.url); sharingURL = nil }
        }
    }
}
private struct ShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}
private struct ShareController: UIViewControllerRepresentable {
    let url: URL
    let completed: () -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.completionWithItemsHandler = { _, _, _, _ in completed() }
        if let popover = activity.popoverPresentationController {
            popover.sourceView = activity.view
            popover.sourceRect = CGRect(x: 1, y: 1, width: 1, height: 1)
        }
        return activity
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
