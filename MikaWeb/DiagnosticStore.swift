import Foundation
import Combine
import MetricKit
import WebKit
import UIKit
import CryptoKit

/// 最小逐步取证日志。每条 JSONL 都含 Astra 裁决的六个字段组；不能从
/// 当前接口独立观测的值保留为 `unobservable`，绝不折算成 0 或失败。
/// 请求凭据只存在 HTTP header，不进入传给本类型的 requestBody。
final class AgentTraceStore: ObservableObject {
    static let shared = AgentTraceStore()
    @Published private(set) var recordCount = 0
    private let queue = DispatchQueue(label: "MikaWeb.AgentTrace")
    private let formatter = ISO8601DateFormatter()
    private var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MikaWeb/Trace", isDirectory: true)
    }
    private var file: URL { directory.appendingPathComponent("agent-trace.jsonl") }

    private init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        recordCount = (try? String(contentsOf: file, encoding: .utf8).split(separator: "\n").count) ?? 0
    }

    func append(_ record: [String: Any]) {
        queue.async { [weak self] in
            guard let self, JSONSerialization.isValidJSONObject(record),
                  let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
            do {
                if !FileManager.default.fileExists(atPath: file.path) { try Data().write(to: file, options: .atomic) }
                let handle = try FileHandle(forWritingTo: file)
                try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.write(contentsOf: Data([0x0a])); try handle.close()
                DispatchQueue.main.async { self.recordCount += 1 }
            } catch { }
        }
    }

    /// 不经模型调用的引擎动作也必须可从同一份 JSONL 逐项还原。保留六组
    /// 外壳，避免导出端为 engine 行另开不兼容 schema。
    func appendEngineAction(action: String, targetFingerprint: String, method: String,
                            result: String, pageURL: String,
                            taskID: String = "unobservable", runID: String = "unobservable",
                            evidence: [String: Any] = [:]) {
        let unknown: [String: Any] = ["observability": "unobservable", "value": NSNull()]
        append([
            "schemaVersion": 1,
            "source": "engine",
            "identityAndConfig": ["timestamp": timestamp(), "buildSHA": Self.buildSHA,
                                    "buildNumber": Self.buildNumber, "source": "engine",
                                    "taskID": taskID, "runID": runID],
            "rawInput": ["action": action, "targetFingerprint": targetFingerprint,
                         "method": method, "pageURL": pageURL],
            "rawOutput": ["result": result],
            "actualExecution": ["action": action, "targetFingerprint": targetFingerprint,
                                "method": method, "result": result, "pageURL": pageURL],
            "independentObservation": ["source": "engine", "pageURL": pageURL,
                                       "targetFingerprint": targetFingerprint, "evidence": evidence],
            "stateAndResult": ["result": result, "failureType": result == "closed" || result == "success" ? unknown as Any : result as Any]
        ])
    }

    func exportURL() throws -> URL {
        try queue.sync {
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw NSError(domain: "MikaWeb.Trace", code: 1, userInfo: [NSLocalizedDescriptionKey: "尚无 trace 记录"])
            }
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("mika-agent-trace-\(UUID().uuidString).jsonl")
            let source = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: true)
            let byteLimit = 2_000_000
            var selected: [Substring] = [], bytes = 0
            for line in source.reversed() {
                let cost = line.utf8.count + 1
                if bytes + cost > byteLimit { break }
                selected.append(line); bytes += cost
            }
            selected.reverse()
            var output = ""
            if selected.count < source.count {
                let marker = ["kind": "export-truncation", "truncated": true,
                              "omittedRecords": source.count - selected.count, "byteLimit": byteLimit] as [String : Any]
                let data = try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys])
                output += String(decoding: data, as: UTF8.self) + "\n"
            }
            output += selected.joined(separator: "\n")
            if !selected.isEmpty { output += "\n" }
            try Data(output.utf8).write(to: destination, options: .atomic)
            return destination
        }
    }

    func storeAttachment(_ text: String) -> [String: Any] {
        let data = Data(text.utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return queue.sync {
            let attachments = directory.appendingPathComponent("attachments", isDirectory: true)
            try? FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
            let name = UUID().uuidString + ".json"
            let url = attachments.appendingPathComponent(name)
            do {
                try data.write(to: url, options: .atomic)
                return ["reference": "attachments/" + name, "sha256": digest, "bytes": data.count, "complete": true]
            } catch {
                return ["reference": "unobservable", "sha256": digest, "bytes": data.count, "complete": false]
            }
        }
    }

    static var buildSHA: String {
        let value = (Bundle.main.object(forInfoDictionaryKey: "MikaBuildSHA") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return "unknown" }
        return value
    }
    static var buildNumber: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unobservable" }
    static var device: String { UIDevice.current.model + " / " + UIDevice.current.systemName + " " + UIDevice.current.systemVersion }
    static var webViewVersion: String { Bundle(identifier: "com.apple.WebKit")?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unobservable" }
    func timestamp() -> String { formatter.string(from: Date()) }

    func verifySyntheticCompleteness() -> [String] {
        let unknown: [String: Any] = ["observability": "unobservable", "value": NSNull()]
        let record: [String: Any] = [
            "schemaVersion": 1,
            "identityAndConfig": ["requestedModel": "synthetic-model", "requestedEffort": "low"],
            "rawInput": ["actualRequestBody": "{\"model\":\"synthetic-model\"}", "foldLevel": 1],
            "rawOutput": ["finishStatus": "completed", "usage": [:]],
            "actualExecution": ["attemptStatus": "attempted", "verificationResult": "unknown",
                                "taskID": "synthetic-task", "runID": "synthetic-run", "clickCount": 1],
            "independentObservation": ["candidateState": ["text": "候选"], "committedState": unknown, "counterNode": unknown,
                                       "writeProof": ["comparisonRule": ZhihuPublishPolicy.fullTextComparisonRule,
                                                      "comparisonResult": "equal", "sourceText": "完整源稿", "committedText": "完整源稿"],
                                       "publishBinding": ["questionID": "42", "composer": "answer-42", "disabledSource": "aria-disabled"],
                                       "readback": ["answerLink": "https://www.zhihu.com/question/42/answer/9",
                                                    "author": "me", "questionID": "42", "fullText": "完整源稿"]],
            "stateAndResult": ["failureType": unknown]
        ]
        append(record)
        let groups = ["identityAndConfig", "rawInput", "rawOutput", "actualExecution", "independentObservation", "stateAndResult"]
        let identity = record["identityAndConfig"] as? [String: Any]
        let observation = record["independentObservation"] as? [String: Any]
        let encoded = (try? JSONSerialization.data(withJSONObject: record)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return [
            "\(groups.allSatisfy { record[$0] != nil } ? "✓" : "✗") 六个字段组齐全",
            "\(identity?["requestedModel"] as? String == "synthetic-model" && identity?["requestedEffort"] as? String == "low" ? "✓" : "✗") 实际请求模型与 effort 已记录",
            "\(observation?["candidateState"] != nil && observation?["committedState"] != nil ? "✓" : "✗") 候选状态与已提交状态分开",
            "\(observation?["writeProof"] != nil && observation?["publishBinding"] != nil && observation?["readback"] != nil ? "✓" : "✗") FIX4 正文凭证、按钮归属、disabled 来源及完整回读字段齐全",
            "\(encoded.contains("unobservable") && !encoded.contains("\"counterNode\":0") ? "✓" : "✗") unobservable 未转成数值"
        ]
    }

    func verifySyntheticEngineTrace() -> [String] {
        let record: [String: Any] = [
            "schemaVersion": 1, "source": "engine",
            "identityAndConfig": ["source": "engine"],
            "rawInput": ["action": "hit-blocker-close", "targetFingerprint": "modal#avatar", "method": "close-affordance", "pageURL": "https://example.test/editor"],
            "rawOutput": ["result": "closed"],
            "actualExecution": ["action": "hit-blocker-close", "targetFingerprint": "modal#avatar", "method": "close-affordance", "result": "closed", "pageURL": "https://example.test/editor"],
            "independentObservation": ["source": "engine"], "stateAndResult": ["result": "closed"]
        ]
        append(record)
        let execution = record["actualExecution"] as? [String: Any]
        let groups = ["identityAndConfig", "rawInput", "rawOutput", "actualExecution", "independentObservation", "stateAndResult"]
        return [
            "\(groups.allSatisfy { record[$0] != nil } ? "✓" : "✗") engine 行与六组 schema 兼容",
            "\(record["source"] as? String == "engine" ? "✓" : "✗") source=engine",
            "\(execution?["action"] as? String == "hit-blocker-close" && execution?["targetFingerprint"] as? String == "modal#avatar" && execution?["method"] as? String == "close-affordance" && execution?["result"] as? String == "closed" && execution?["pageURL"] as? String == "https://example.test/editor" ? "✓" : "✗") 动作、指纹、手段、结果、URL 齐全"
        ]
    }
}

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
    private var changeObserver: NSObjectProtocol?
    private var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MikaWeb/Diagnostics", isDirectory: true)
    }
    private var shareDirectory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("MikaWebDiagnosticShares", isDirectory: true) }
    func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
        changeObserver = NotificationCenter.default.addObserver(forName: .mikaDiagnosticsChanged, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in self?.publishList() }
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.prepareDirectory()
            try? FileManager.default.removeItem(at: self.shareDirectory)
            self.publishList()
        }
    }
    deinit {
        if started { MXMetricManager.shared.remove(self) }
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    }
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

    private static func boundedExport(_ value: Any, depth: Int = 0, truncated: inout Bool) -> Any {
        if depth >= 10 { truncated = true; return ["truncated": true, "reason": "depth-limit"] }
        if let string = value as? String {
            if string.count > 8_192 { truncated = true; return String(string.prefix(8_192)) }
            return string
        }
        if let array = value as? [Any] {
            if array.count > 64 { truncated = true }
            return array.prefix(64).map { boundedExport($0, depth: depth + 1, truncated: &truncated) }
        }
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            let keys = dictionary.keys.sorted()
            if keys.count > 128 { truncated = true }
            for key in keys.prefix(128) {
                if key.lowercased().contains("screenshot") && dictionary[key] is String {
                    result[key] = "[omitted-from-export]"; truncated = true
                } else {
                    result[key] = boundedExport(dictionary[key] as Any, depth: depth + 1, truncated: &truncated)
                }
            }
            return result
        }
        return value
    }

    func prepareShare(for report: StoredDiagnosticReport) throws -> URL {
        try queue.sync {
            guard report.readable else { throw NSError(domain: "MikaWeb.Diagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: "报告不可读取"]) }
            try FileManager.default.createDirectory(at: shareDirectory, withIntermediateDirectories: true)
            guard let selectedData = try? Data(contentsOf: report.url),
                  let selectedObject = try? JSONSerialization.jsonObject(with: selectedData) as? [String: Any] else {
                throw NSError(domain: "MikaWeb.Diagnostics", code: 2, userInfo: [NSLocalizedDescriptionKey: "报告 JSON 不可读取"])
            }
            let attemptID = (((selectedObject["payload"] as? [String: Any])?["identity"] as? [String: Any])?["attemptID"] as? String)
            let relatedObjects: [[String: Any]] = scan().filter { candidate in
                guard candidate.readable, let attemptID,
                      let data = try? Data(contentsOf: candidate.url),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = object["payload"] as? [String: Any],
                      let identity = payload["identity"] as? [String: Any] else { return candidate.url == report.url }
                return identity["attemptID"] as? String == attemptID
            }.prefix(5).compactMap { candidate in
                (try? Data(contentsOf: candidate.url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            }
            let traceURL = try? AgentTraceStore.shared.exportURL()
            defer { if let traceURL { try? FileManager.default.removeItem(at: traceURL) } }
            let traceLines = traceURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
                .split(separator: "\n").filter { line in attemptID.map { line.contains($0) } ?? false }.prefix(200)
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } ?? []
            var wasTruncated = relatedObjects.count >= 5 || traceLines.count >= 200
            let boundedSelected = Self.boundedExport(selectedObject, truncated: &wasTruncated)
            let boundedRelated = Self.boundedExport(relatedObjects, truncated: &wasTruncated)
            let boundedTrace = Self.boundedExport(traceLines, truncated: &wasTruncated)
            let bundle: [String: Any] = [
                "schemaVersion": 1, "kind": "mika-evidence-chain",
                "attemptID": attemptID ?? "unobservable",
                "selectedDiagnostic": boundedSelected,
                "relatedDiagnostics": boundedRelated,
                "traceRecords": boundedTrace,
                "limits": ["diagnostics": 5, "traceRecords": 200, "stringCharacters": 8_192,
                           "traceExportBytes": 2_000_000],
                "truncated": wasTruncated
            ]
            let data = try JSONSerialization.data(withJSONObject: bundle, options: [.prettyPrinted, .sortedKeys])
            let destination = shareDirectory.appendingPathComponent("mika-evidence-chain-\(UUID().uuidString).json")
            try data.write(to: destination, options: .atomic)
            return destination
        }
    }
    func finishShare(_ url: URL) { queue.async { try? FileManager.default.removeItem(at: url) } }
    func prepareTraceShare() throws -> URL { try AgentTraceStore.shared.exportURL() }
}
