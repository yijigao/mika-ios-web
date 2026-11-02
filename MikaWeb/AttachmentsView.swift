import SwiftUI
import PhotosUI
import QuickLook
import UniformTypeIdentifiers

// 附件中心（F1，2026-11-02）：当前查看会话的附件与浏览器截图的管理面——
// 系统选择器导入（文件走 fileImporter、图片走 PhotosPicker）→ 复制进
// App 管理目录（AttachmentStore）；列表按「附件／浏览器截图」分节，
// 每行展示文件名、大小、来源与可读状态（三态分开：已存入 ≠ 模型已读
// ≠ 已上传）；点行 QuickLook 预览，行内分享导出，左滑删除。另有「保存
// 当前页截图」把当前标签页截图登记进 browser/（本任务生成物）。
// 本视图只管当前查看会话（SessionStore 的当前会话指针）：切会话后
// 列表随指针换源，与对话/标签的会话口径一致。
struct AttachmentsView: View {
    @ObservedObject var web: WebController
    @ObservedObject private var store = AttachmentStore.shared
    @ObservedObject private var sessionStore = SessionStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showFileImporter = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var previewItem: PreviewItem?
    @State private var notice: String?

    private struct PreviewItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    private var sessionID: UUID { sessionStore.currentSessionID }
    private var records: [AttachmentRecord] { store.attachments(for: sessionID) }
    private var fileRecords: [AttachmentRecord] { records.filter { !$0.isScreenshot } }
    private var shotRecords: [AttachmentRecord] { records.filter { $0.isScreenshot } }

    var body: some View {
        NavigationStack {
            List {
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(.orange)
                }
                Section {
                    Button { showFileImporter = true } label: { Label("从文件导入", systemImage: "folder.badge.plus") }
                    PhotosPicker(selection: $photoItems, maxSelectionCount: 5, matching: .images) {
                        Label("从相册导入图片", systemImage: "photo.on.rectangle.angled")
                    }
                    Button { saveCurrentPageScreenshot() } label: { Label("保存当前页截图", systemImage: "camera.viewfinder") }
                } footer: {
                    Text("导入的文件会复制进 App 管理目录（按会话分开存放），重启后仍在。发任务时可在对话里按文件名引用附件；把附件上传到网页时，非本任务生成的文件会先出确认卡（SP-01）。")
                }
                Section("附件") {
                    if fileRecords.isEmpty {
                        Text("暂无附件").foregroundStyle(.secondary)
                    }
                    ForEach(fileRecords) { record in row(record) }
                }
                Section("浏览器截图") {
                    if shotRecords.isEmpty {
                        Text("暂无截图（操作失败快照与手动保存的截图会出现在这里）").foregroundStyle(.secondary)
                    }
                    ForEach(shotRecords) { record in row(record) }
                }
            }
            .navigationTitle("附件 · \(sessionTitle)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("完成") { dismiss() }
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                var imported = 0
                for url in urls {
                    if (try? store.importFile(at: url, sessionID: sessionID)) != nil { imported += 1 }
                }
                notice = imported > 0 ? "已导入 \(imported) 个文件" : "导入失败：文件不可读"
            case .failure(let error):
                notice = "导入失败：\(error.localizedDescription)"
            }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { @MainActor in
                var imported = 0
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("相册导入-\(UUID().uuidString).\(ext)")
                        if (try? data.write(to: temp)) != nil, (try? store.importFile(at: temp, sessionID: sessionID)) != nil { imported += 1 }
                        try? FileManager.default.removeItem(at: temp)
                    }
                }
                photoItems = []
                notice = imported > 0 ? "已导入 \(imported) 张图片" : "导入失败：图片不可读"
            }
        }
        .sheet(item: $previewItem) { item in
            QuickLookPreview(url: item.url)
        }
    }

    private var sessionTitle: String {
        sessionStore.sessions.first(where: { $0.id == sessionID })?.title ?? "会话"
    }

    private func row(_ record: AttachmentRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(record.displayName).font(.callout).lineLimit(2)
            Text(detailLine(record)).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Button("预览") { previewItem = PreviewItem(url: store.fileURL(for: record)) }
                ShareLink(item: store.fileURL(for: record)) { Text("分享导出") }
            }
            .font(.caption)
        }
        .swipeActions(edge: .trailing) {
            Button("删除", role: .destructive) { store.deleteAttachment(id: record.id, sessionID: sessionID) }
        }
    }

    private func detailLine(_ record: AttachmentRecord) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(record.byteCount), countStyle: .file)
        let origin = record.origin == .taskGenerated ? "本任务生成" : "用户文件"
        let state: String
        switch record.readState {
        case .textExtracted: state = "文本已抽取，模型可引用"
        case .imageScaled: state = "图片，已存缩放副本\(record.imageWidth.map { "（\($0)×\(record.imageHeight ?? 0)）" } ?? "")"
        case .storedOnly: state = "仅存储，模型未读内容"
        }
        return "\(size) · \(origin) · \(state)"
    }

    private func saveCurrentPageScreenshot() {
        let tab = web.activeTab
        let targetSession = sessionID
        Task { @MainActor in
            if let data = await web.captureTabJPEG(tab) {
                _ = store.registerScreenshot(data: data, sessionID: targetSession)
                notice = "当前页截图已保存到浏览器截图"
            } else {
                notice = "截图失败：当前页暂不可截"
            }
        }
    }
}

/// QuickLook 预览的 UIViewControllerRepresentable 包装（系统框架，无新依赖）。
private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
