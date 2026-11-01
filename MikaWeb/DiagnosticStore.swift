import Foundation
import Combine
import MetricKit

struct StoredDiagnosticReport: Identifiable {
    let id: UUID
    let receivedAt: Date
    let types: [String]
    let url: URL
    let readable: Bool
}

final class DiagnosticStore: NSObject, ObservableObject, MXMetricManagerSubscriber {
    @Published private(set) var reports: [StoredDiagnosticReport] = []
    @Published private(set) var storageError: String?
    private let queue = DispatchQueue(label: "MikaWeb.Diagnostics")
    private let formatter = ISO8601DateFormatter()
    private var started = false
    private var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MikaWeb/Diagnostics", isDirectory: true)
    }
    private var shareDirectory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("MikaWebDiagnosticShares", isDirectory: true) }
    func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
        queue.async { [weak self] in
            guard let self else { return }
            self.prepareDirectory()
            try? FileManager.default.removeItem(at: self.shareDirectory)
            self.publishList()
        }
    }
    deinit { if started { MXMetricManager.shared.remove(self) } }
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let raw = payload.jsonRepresentation()
            let types = diagnosticTypes(payload)
            queue.async { [weak self] in self?.save(raw: raw, types: types) }
        }
    }
    private func diagnosticTypes(_ payload: MXDiagnosticPayload) -> [String] {
        var types: [String] = []
        if !(payload.crashDiagnostics ?? []).isEmpty { types.append("崩溃") }
        if !(payload.hangDiagnostics ?? []).isEmpty { types.append("卡顿") }
        if !(payload.cpuExceptionDiagnostics ?? []).isEmpty { types.append("CPU 异常") }
        if !(payload.diskWriteExceptionDiagnostics ?? []).isEmpty { types.append("磁盘写入异常") }
        if !(payload.appLaunchDiagnostics ?? []).isEmpty { types.append("启动异常") }
        return types.isEmpty ? ["系统诊断"] : types
    }
    private func prepareDirectory() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var url = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        } catch { reportError("诊断目录不可用：\(error.localizedDescription)") }
    }
    private func save(raw: Data, types: [String]) {
        do {
            let payload = try JSONSerialization.jsonObject(with: raw)
            let id = UUID(), now = Date()
            let envelope: [String: Any] = ["schemaVersion": 1, "id": id.uuidString, "receivedAt": formatter.string(from: now), "types": types, "payload": payload]
            let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
            let name = formatter.string(from: now).replacingOccurrences(of: ":", with: "-") + "-" + id.uuidString + ".json"
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            prune()
            publishList()
        } catch { reportError("保存诊断失败：\(error.localizedDescription)") }
    }
    private func scan() -> [StoredDiagnosticReport] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.map { url in
            guard let data = try? Data(contentsOf: url),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let idText = object["id"] as? String, let id = UUID(uuidString: idText),
                  let timeText = object["receivedAt"] as? String, let time = formatter.date(from: timeText),
                  let types = object["types"] as? [String], object["payload"] != nil else {
                return StoredDiagnosticReport(id: UUID(), receivedAt: .distantPast, types: ["不可读取"], url: url, readable: false)
            }
            return StoredDiagnosticReport(id: id, receivedAt: time, types: types, url: url, readable: true)
        }.sorted { $0.receivedAt > $1.receivedAt }
    }
    private func prune() {
        for report in scan().filter(\.readable).dropFirst(5) { try? FileManager.default.removeItem(at: report.url) }
    }
    private func publishList() {
        let list = scan()
        DispatchQueue.main.async { [weak self] in self?.reports = list }
    }
    private func reportError(_ message: String) { DispatchQueue.main.async { [weak self] in self?.storageError = message } }
    func prepareShare(for report: StoredDiagnosticReport) throws -> URL {
        try queue.sync {
            guard report.readable else { throw NSError(domain: "MikaWeb.Diagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: "报告不可读取"]) }
            try FileManager.default.createDirectory(at: shareDirectory, withIntermediateDirectories: true)
            let copy = shareDirectory.appendingPathComponent(UUID().uuidString + ".json")
            try FileManager.default.copyItem(at: report.url, to: copy)
            return copy
        }
    }
    func finishShare(_ url: URL) { queue.async { try? FileManager.default.removeItem(at: url) } }
}
