import Foundation
import UIKit
import UniformTypeIdentifiers
import PDFKit

// 附件中心（F1，2026-11-02，PROGRAM-H1F1M1 第三单）：用户材料与浏览器截图
// 统一落进 App 管理目录，按会话分开存放——
//
//   Application Support/MikaWeb/Sessions/<sessionID>/
//   ├── attachments.json          本会话附件索引（AttachmentRecord 数组）
//   ├── attachments/              用户导入的文件（原样存入＋图片缩放副本）
//   └── browser/                  浏览器截图（失败快照截图与手动保存截图）
//
// 身份口径：文件靠稳定附件 ID 引用，不让文件名承担身份——落盘名是
// 「<附件ID>-<清洗后的原名>」，同名再导入必然是另一个 ID、另一个文件，
// 永不覆盖。三态分开记（学 Astra 案口径）：已存入 ≠ 模型已读 ≠ 网页已
// 上传成功——readState 只记「模型可读形态」：文本类抽取正文摘录、图片存
// 一份缩放副本、其余格式 storedOnly（只存不假报已读，摘录恒为 nil）。
// origin 记来源：userPrivate（用户导入/现选的私有文件，上传走 SP-01
// 确认门）与 taskGenerated（本任务生成的截图等，豁免 SP-01 新卡，但不
// 免除既有对外发送与敏感信息边界）。
//
// SP-01 一次性确认登记表也在本文件：确认凭据绑定（附件 id＋目标页面），
// 消费即作废（无论消费成功、错配、还是被显式作废），取消/失败/重试后
// 旧确认不得复用于另一个动作——引擎在用户点确认时消费、在取消时作废。

enum AttachmentOrigin: String, Codable { case userPrivate, taskGenerated }

enum AttachmentReadState: String, Codable {
    case textExtracted   // 文本已抽取，摘录可供模型引用
    case imageScaled     // 图片已存缩放副本（模型通道为文本，副本是其可读形态的准备）
    case storedOnly      // 仅存储，模型未读取内容
}

struct AttachmentRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let sessionID: UUID
    var displayName: String
    /// 落盘文件名（相对所属目录：附件在 attachments/、截图在 browser/）
    var storedName: String
    /// 图片缩放副本的文件名（与原文件同目录）；非图片为 nil
    var scaledName: String?
    var isScreenshot: Bool
    var origin: AttachmentOrigin
    /// UTI 字符串（如 public.plain-text / public.png）
    var contentType: String
    var byteCount: Int
    var readState: AttachmentReadState
    /// 文本摘录（上限 20000 字）；非文本格式恒 nil——不假报已读
    var extractedText: String?
    /// 缩放副本的像素宽/高（图片才有）
    var imageWidth: Int?
    var imageHeight: Int?
    var createdAt: Date
    /// 是否已同步存入系统相册（COVER-UPLOAD-FIX A，本任务生成的图片
    /// 生成后写入相册时置 true）：附件中心与选文件指引据此告诉用户
    /// 「去相册最近项目找它」。可选字段——旧索引 JSON 无此键时解码为
    /// nil（按未存入处理），不另做迁移。
    var savedToPhotos: Bool?
}

final class AttachmentStore: ObservableObject {
    static let shared = AttachmentStore()

    /// UI 刷新信号：任何附件变更后 +1（附件列表按会话现查，不缓存视图态）
    @Published private(set) var revision = 0
    private var cache: [UUID: [AttachmentRecord]] = [:]

    /// 图片缩放副本的长边上限（像素）：与失败快照 JPEG 的既有取图口径
    /// 同属「够辨认、不囤原图」的量级；原图另存不动，缩放只产副本。
    static let scaledLongEdge = 1200
    /// 文本摘录落盘上限（字）：摘录是给模型引用的工作副本，不是全文仓库
    static let extractedTextCap = 20000

    // MARK: - 路径

    func attachmentsDirectory(for sessionID: UUID) -> URL {
        let directory = SessionStore.sessionDirectory(for: sessionID).appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    func browserDirectory(for sessionID: UUID) -> URL {
        let directory = SessionStore.sessionDirectory(for: sessionID).appendingPathComponent("browser", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func indexURL(for sessionID: UUID) -> URL {
        SessionStore.sessionDirectory(for: sessionID).appendingPathComponent("attachments.json")
    }
    func fileURL(for record: AttachmentRecord) -> URL {
        let directory = record.isScreenshot ? browserDirectory(for: record.sessionID) : attachmentsDirectory(for: record.sessionID)
        return directory.appendingPathComponent(record.storedName)
    }
    func scaledURL(for record: AttachmentRecord) -> URL? {
        guard let scaledName = record.scaledName else { return nil }
        let directory = record.isScreenshot ? browserDirectory(for: record.sessionID) : attachmentsDirectory(for: record.sessionID)
        return directory.appendingPathComponent(scaledName)
    }

    // MARK: - 索引读写

    func attachments(for sessionID: UUID) -> [AttachmentRecord] {
        if let cached = cache[sessionID] { return cached }
        let loaded = loadFromDisk(sessionID: sessionID)
        cache[sessionID] = loaded
        return loaded
    }

    private func loadFromDisk(sessionID: UUID) -> [AttachmentRecord] {
        guard let data = try? Data(contentsOf: indexURL(for: sessionID)),
              let decoded = try? JSONDecoder().decode([AttachmentRecord].self, from: data) else { return [] }
        return decoded
    }

    private func persist(sessionID: UUID) {
        guard let records = cache[sessionID],
              let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: indexURL(for: sessionID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        revision += 1
    }

    // MARK: - 导入与登记

    /// 系统选择器导入：把 url 指向的文件复制进管理目录（选择器给的是
    /// 临时/安全域访问权，须在有效期内完成复制，重启后不依赖原路径）。
    @discardableResult
    func importFile(at url: URL, sessionID: UUID, origin: AttachmentOrigin = .userPrivate) throws -> AttachmentRecord {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return registerData(data, displayName: url.lastPathComponent, sessionID: sessionID, origin: origin, isScreenshot: false)
    }

    /// 以数据登记一份附件：分配稳定 ID、落盘（同名永不覆盖）、按格式
    /// 生成模型可读形态（文本抽取／图片缩放／只存）。全程同步小文件 IO，
    /// 与仓内既有落盘代码同形态。
    @discardableResult
    func registerData(_ data: Data, displayName: String, sessionID: UUID, origin: AttachmentOrigin, isScreenshot: Bool) -> AttachmentRecord {
        let id = UUID()
        let cleaned = Self.sanitizedFileName(displayName)
        let storedName = "\(id.uuidString)-\(cleaned)"
        let directory = isScreenshot ? browserDirectory(for: sessionID) : attachmentsDirectory(for: sessionID)
        try? data.write(to: directory.appendingPathComponent(storedName), options: [.atomic])
        let type = UTType(filenameExtension: (cleaned as NSString).pathExtension) ?? .data
        var record = AttachmentRecord(id: id, sessionID: sessionID, displayName: displayName,
                                      storedName: storedName, scaledName: nil,
                                      isScreenshot: isScreenshot, origin: origin,
                                      contentType: type.identifier, byteCount: data.count,
                                      readState: .storedOnly, extractedText: nil,
                                      imageWidth: nil, imageHeight: nil, createdAt: Date(),
                                      savedToPhotos: nil)
        if type.conforms(to: .image), let image = UIImage(data: data), let scaled = Self.scaledJPEG(image) {
            let scaledName = "\(id.uuidString)-scaled.jpg"
            try? scaled.data.write(to: directory.appendingPathComponent(scaledName), options: [.atomic])
            record.scaledName = scaledName
            record.imageWidth = scaled.width
            record.imageHeight = scaled.height
            record.readState = .imageScaled
        } else if type.conforms(to: .pdf), let document = PDFDocument(data: data), let text = document.string, !text.isEmpty {
            record.extractedText = String(text.prefix(Self.extractedTextCap))
            record.readState = .textExtracted
        } else if type.conforms(to: .text), let text = Self.decodeText(data) {
            record.extractedText = String(text.prefix(Self.extractedTextCap))
            record.readState = .textExtracted
        }
        var records = attachments(for: sessionID)
        records.append(record)
        cache[sessionID] = records
        persist(sessionID: sessionID)
        return record
    }

    /// 浏览器截图登记（browser/ 子目录，本任务生成物）：失败快照路径与
    /// 附件中心的「保存当前页截图」共用；截图原样存入并按图片管线备缩放
    /// 副本。尽力而为——登记失败不影响调用方主流程。
    @discardableResult
    func registerScreenshot(data: Data, sessionID: UUID) -> AttachmentRecord? {
        guard !data.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return registerData(data, displayName: "页面截图-\(formatter.string(from: Date())).jpg",
                            sessionID: sessionID, origin: .taskGenerated, isScreenshot: true)
    }

    /// 删除附件：原文件与缩放副本一并移除，索引同步删条。
    func deleteAttachment(id: UUID, sessionID: UUID) {
        var records = attachments(for: sessionID)
        guard let record = records.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: fileURL(for: record))
        if let scaled = scaledURL(for: record) { try? FileManager.default.removeItem(at: scaled) }
        records.removeAll { $0.id == id }
        cache[sessionID] = records
        persist(sessionID: sessionID)
    }

    /// 按稳定 ID 取记录（引擎供文件/指引用）。
    func record(id: UUID, sessionID: UUID) -> AttachmentRecord? {
        attachments(for: sessionID).first { $0.id == id }
    }

    /// 标记某附件已存入系统相册（COVER-UPLOAD-FIX A）：索引落盘同步，
    /// 附件中心与注入段下次读取即带「已存入相册」口径。
    func markSavedToPhotos(id: UUID, sessionID: UUID) {
        var records = attachments(for: sessionID)
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].savedToPhotos = true
        cache[sessionID] = records
        persist(sessionID: sessionID)
    }

    /// 展示排序（COVER-UPLOAD-FIX B）：本任务生成的文件置顶（上传时
    /// 最先要找的就是它），同组内新在前。附件中心与注入段共用同一
    /// 排序，用户与模型看到的顺序一致。
    static func displayOrdered(_ records: [AttachmentRecord]) -> [AttachmentRecord] {
        records.sorted { a, b in
            if (a.origin == .taskGenerated) != (b.origin == .taskGenerated) { return a.origin == .taskGenerated }
            return a.createdAt > b.createdAt
        }
    }

    /// 按引用找附件（模型在 upload_file 的 text 里给出附件 id 或文件名）：
    /// 先按完整/前缀 id 匹配，再按展示名精确匹配、最后大小写不敏感包含
    /// 匹配；多义或找不到返回 nil（调用方据此降级为「现选文件」口径）。
    func findAttachment(reference: String, sessionID: UUID) -> AttachmentRecord? {
        let ref = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty else { return nil }
        let records = attachments(for: sessionID)
        if let byID = records.first(where: { $0.id.uuidString.lowercased() == ref.lowercased() || $0.id.uuidString.lowercased().hasPrefix(ref.lowercased()) }) { return byID }
        if let byName = records.first(where: { $0.displayName == ref }) { return byName }
        let lowered = ref.lowercased()
        let contains = records.filter { $0.displayName.lowercased().contains(lowered) }
        return contains.count == 1 ? contains[0] : nil
    }

    // MARK: - 模型注入段

    /// 【本会话附件】注入段：逐条列 id 短码/文件名/大小/来源/可读状态；
    /// 文本附件附摘录（最多 3 条、每条 ≤300 字），图片注明缩放副本尺寸，
    /// storedOnly 明示「模型未读内容」。总额由条数与摘录上限天然有界。
    func promptBlock(for sessionID: UUID) -> String {
        let records = attachments(for: sessionID)
        guard !records.isEmpty else { return "" }
        var lines = ["【本会话附件】（已存入 App，按编号或文件名引用；存入≠已上传到任何网页）"]
        var excerptCount = 0
        for record in Self.displayOrdered(records) {
            let size = ByteCountFormatter.string(fromByteCount: Int64(record.byteCount), countStyle: .file)
            let originText = record.origin == .taskGenerated ? "本任务生成" : "用户文件"
            let location = record.isScreenshot ? "浏览器截图" : "附件"
            var line = "· [\(String(record.id.uuidString.prefix(8)))] \(record.displayName)（\(location)，\(size)，\(originText)）"
            if record.savedToPhotos == true { line += "（已存入系统相册）" }
            switch record.readState {
            case .textExtracted:
                line += "—文本已抽取，可引用"
                if excerptCount < 3, let text = record.extractedText, !text.isEmpty {
                    excerptCount += 1
                    line += "，摘录：「\(String(text.prefix(300)))」"
                }
            case .imageScaled:
                line += "—图片，已存缩放副本\(record.imageWidth.map { "（\($0)×\(record.imageHeight ?? 0)）" } ?? "")；当前模型通道只能按文件名与尺寸引用它，不能直接看图"
            case .storedOnly:
                line += "—仅存储，模型未读内容（不要声称知道里面是什么）"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - SP-01 一次性确认登记表

    private struct UploadConfirmation {
        let attachmentID: UUID?
        let pageURL: String
        let issuedAt: Date
    }
    private var uploadConfirmations: [UUID: UploadConfirmation] = [:]
    /// 确认有效期：超时未消费自动失效（消费时判定）。
    static let uploadConfirmationLifetime: TimeInterval = 30 * 60

    /// 签发一张一次性确认凭据（引擎在出 SP-01 确认卡时调用）。
    func issueUploadConfirmation(attachmentID: UUID?, pageURL: String) -> UUID {
        let token = UUID()
        uploadConfirmations[token] = UploadConfirmation(attachmentID: attachmentID, pageURL: pageURL, issuedAt: Date())
        return token
    }

    /// 消费确认凭据：无论命中、错配还是过期，凭据都随本次调用作废
    /// （一次性语义）；只有绑定（附件＋页面）与签发时逐项一致且未过期
    /// 才返回 true。
    @discardableResult
    func consumeUploadConfirmation(_ token: UUID, attachmentID: UUID?, pageURL: String) -> Bool {
        guard let confirmation = uploadConfirmations.removeValue(forKey: token) else { return false }
        guard Date().timeIntervalSince(confirmation.issuedAt) <= Self.uploadConfirmationLifetime else { return false }
        return confirmation.attachmentID == attachmentID && confirmation.pageURL == pageURL
    }

    /// 作废确认凭据（用户取消上传时调用）：之后再消费必然失败。
    func invalidateUploadConfirmation(_ token: UUID) {
        uploadConfirmations[token] = nil
    }

    // MARK: - 工具

    static func sanitizedFileName(_ name: String) -> String {
        var base = (name as NSString).lastPathComponent
        if base.isEmpty { base = "file" }
        let illegal = CharacterSet(charactersIn: "/\\?%*|\"<>").union(.controlCharacters)
        var cleaned = ""
        for scalar in base.unicodeScalars {
            cleaned += illegal.contains(scalar) ? "_" : String(Character(scalar))
        }
        return cleaned.isEmpty ? "file" : cleaned
    }

    private static func decodeText(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let utf16 = String(data: data, encoding: .utf16) { return utf16 }
        return nil
    }

    /// 图片缩放：长边压到 scaledLongEdge 内（小图不放大），输出 JPEG。
    static func scaledJPEG(_ image: UIImage) -> (data: Data, width: Int, height: Int)? {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longEdge = max(pixelWidth, pixelHeight)
        let factor = longEdge > CGFloat(scaledLongEdge) ? CGFloat(scaledLongEdge) / longEdge : 1
        let targetSize = CGSize(width: max(1, (image.size.width * factor).rounded()), height: max(1, (image.size.height * factor).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        guard let data = rendered.jpegData(compressionQuality: 0.72) else { return nil }
        return (data, Int(targetSize.width), Int(targetSize.height))
    }

    // MARK: - 自检十 Tier A（F1）：附件闭环程序化核查

    /// 临时会话里走完整闭环：文本导入与抽取、图片导入与缩放、同名不
    /// 覆盖（稳定 ID）、未知格式只存、截图进 browser/、索引回读一致、
    /// SP-01 判定与一次性确认绑定四连。结论逐条人读（✓/✗ 开头），临时
    /// 会话结束时连目录删除干净。不调用模型、不动现役会话与任务。
    func verifyAttachmentsF1() -> [String] {
        var lines: [String] = []
        let store = SessionStore.shared
        let scratch = store.createSession(title: "自检十临时会话")
        defer {
            cache[scratch.id] = nil
            _ = store.deleteSession(id: scratch.id)
        }
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
        // —— 文本导入＋抽取 ——
        let marker = "自检十样本文本 ATTACHMENT-F1-MARKER"
        let txtURL = tempDir.appendingPathComponent("自检十样本.txt")
        try? marker.write(to: txtURL, atomically: true, encoding: .utf8)
        guard let textRecord = try? importFile(at: txtURL, sessionID: scratch.id) else {
            lines.append("✗ 文本导入失败，闭环未完成")
            return lines
        }
        let textFileExists = fm.fileExists(atPath: fileURL(for: textRecord).path)
        lines.append(textFileExists && textRecord.readState == .textExtracted && (textRecord.extractedText?.contains("ATTACHMENT-F1-MARKER") ?? false)
            ? "✓ 文本导入：已复制进会话 attachments/ 目录，文本抽取到摘录且标记在场（稳定 ID \(String(textRecord.id.uuidString.prefix(8))))"
            : "✗ 文本导入异常（落盘 \(textFileExists)、状态 \(textRecord.readState.rawValue)）")
        // —— 同名再导入不覆盖 ——
        let second = try? importFile(at: txtURL, sessionID: scratch.id)
        let firstBytes = try? Data(contentsOf: fileURL(for: textRecord))
        lines.append(second != nil && second?.id != textRecord.id && firstBytes != nil
            && (try? Data(contentsOf: fileURL(for: textRecord))) == firstBytes
            && attachments(for: scratch.id).filter { $0.displayName == textRecord.displayName }.count == 2
            ? "✓ 同名不覆盖：同名文件再导入生成新 ID 并存，第一份内容逐字节未变"
            : "✗ 同名再导入处理异常（第二份 \(second == nil ? "缺失" : "在位")）")
        // —— 图片导入＋缩放副本 ——
        let bigImage = UIGraphicsImageRenderer(size: CGSize(width: 2000, height: 1000)).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2000, height: 1000))
        }
        let pngURL = tempDir.appendingPathComponent("自检十图片.png")
        if let png = bigImage.pngData() { try? png.write(to: pngURL) }
        let imageRecord = try? importFile(at: pngURL, sessionID: scratch.id)
        let scaledOK = imageRecord.flatMap { scaledURL(for: $0) }.map { fm.fileExists(atPath: $0.path) } ?? false
        let scaledBounded = (imageRecord?.imageWidth ?? Int.max) <= Self.scaledLongEdge && (imageRecord?.imageHeight ?? Int.max) <= Self.scaledLongEdge
        lines.append(imageRecord?.readState == .imageScaled && scaledOK && scaledBounded
            ? "✓ 图片导入：原图存入，缩放副本在位且长边 ≤\(Self.scaledLongEdge)（实际 \(imageRecord?.imageWidth ?? 0)×\(imageRecord?.imageHeight ?? 0)）"
            : "✗ 图片导入异常（状态 \(imageRecord?.readState.rawValue ?? "无记录")、副本 \(scaledOK)、尺寸受限 \(scaledBounded)）")
        // —— 未知格式只存不假报已读 ——
        let binURL = tempDir.appendingPathComponent("自检十未知.zzq")
        try? Data([0x01, 0x02, 0x03, 0x04]).write(to: binURL)
        let binRecord = try? importFile(at: binURL, sessionID: scratch.id)
        lines.append(binRecord?.readState == .storedOnly && binRecord?.extractedText == nil && binRecord.map { fm.fileExists(atPath: fileURL(for: $0).path) } == true
            ? "✓ 未知格式：只存入并标记 storedOnly，摘录为空——不假报已读"
            : "✗ 未知格式处理异常（状态 \(binRecord?.readState.rawValue ?? "无记录")）")
        // —— 截图进 browser/ ——
        let shotData = bigImage.jpegData(compressionQuality: 0.5) ?? Data()
        let shot = registerScreenshot(data: shotData, sessionID: scratch.id)
        let shotOK = shot.map { $0.isScreenshot && fm.fileExists(atPath: fileURL(for: $0).path) && fileURL(for: $0).path.contains("/browser/") } ?? false
        lines.append(shotOK
            ? "✓ 浏览器截图：登记进会话 browser/ 子目录、来源标记为本任务生成（SP-01 豁免侧）"
            : "✗ 浏览器截图登记异常")
        // —— 索引回读一致（绕过内存缓存直接读盘面） ——
        let onDisk = loadFromDisk(sessionID: scratch.id)
        let inMemory = attachments(for: scratch.id)
        lines.append(onDisk.count == inMemory.count && onDisk.count == 5 && Set(onDisk.map { $0.id }) == Set(inMemory.map { $0.id })
            ? "✓ 索引往返：落盘索引回读 \(onDisk.count) 条，与内存逐 ID 一致（进程重开后附件仍在位的前提成立）"
            : "✗ 索引往返异常（盘面 \(onDisk.count) 条、内存 \(inMemory.count) 条）")
        // —— 注入段口径 ——
        let block = promptBlock(for: scratch.id)
        lines.append(block.contains("自检十样本.txt") && block.contains("ATTACHMENT-F1-MARKER") && block.contains("仅存储，模型未读内容")
            ? "✓ 注入段：附件清单在场、文本摘录在场、未知格式明示「模型未读内容」"
            : "✗ 注入段口径异常（清单/摘录/未读声明至少一项缺失）")
        // —— SP-01 判定与一次性确认绑定 ——
        lines.append(SafetyPolicy.uploadDecision(isTaskGenerated: true) == .allow && SafetyPolicy.uploadDecision(isTaskGenerated: false) == .confirm
            ? "✓ SP-01 判定：本任务生成的文件放行、其余私有文件须确认（SafetyPolicy.uploadDecision）"
            : "✗ SP-01 判定异常")
        let page = "https://example.com/upload"
        let wrong = issueUploadConfirmation(attachmentID: textRecord.id, pageURL: page)
        let wrongResult = consumeUploadConfirmation(wrong, attachmentID: binRecord?.id, pageURL: page)
        let good = issueUploadConfirmation(attachmentID: textRecord.id, pageURL: page)
        let goodResult = consumeUploadConfirmation(good, attachmentID: textRecord.id, pageURL: page)
        let replayResult = consumeUploadConfirmation(good, attachmentID: textRecord.id, pageURL: page)
        let killed = issueUploadConfirmation(attachmentID: textRecord.id, pageURL: page)
        invalidateUploadConfirmation(killed)
        let killedResult = consumeUploadConfirmation(killed, attachmentID: textRecord.id, pageURL: page)
        lines.append(!wrongResult && goodResult && !replayResult && !killedResult
            ? "✓ 确认绑定：错附件消费失败、正绑定消费成功、同一凭据二次消费失败、作废后消费失败——旧确认不可复用"
            : "✗ 确认绑定异常（错配 \(wrongResult)、正消费 \(goodResult)、复用 \(replayResult)、作废后 \(killedResult)）")
        lines.append("临时会话及其附件目录将在本自检结束时随会话删除干净")
        return lines
    }
}
