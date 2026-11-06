import Foundation
import CryptoKit

struct PreservedDraftTarget: Codable, Equatable {
    var accountStableID: String
    var accountAliases: [String]
    var questionID: String
}

/// 稿件不是任务快照的一部分。这里只保存可重新写入的正文与业务目标，绝不
/// 保存 tab/document/editor 等页面凭证；页面变化或进程重启后必须重新生成
/// WriteProof。
struct PreservedDraft: Codable, Equatable, Identifiable {
    var id: UUID
    var fullText: String
    var version: Int
    var target: PreservedDraftTarget
    var sourceTaskID: UUID
    /// 稿件所属聊天会话。旧稿没有此字段时仍可按 sourceTaskID/draftID 恢复。
    var sourceSessionID: UUID? = nil
    var updatedAt: Date
    var textHash: String
}

final class PreservedDraftStore {
    static let shared = PreservedDraftStore()
    private let fileURL: URL
    private let queue = DispatchQueue(label: "MikaWeb.PreservedDraftStore")

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MikaWeb/Drafts/zhihu-drafts.json")
    }

    static func textHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func readUnlocked() throws -> [PreservedDraft] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([PreservedDraft].self, from: data)
    }

    private func writeUnlocked(_ drafts: [PreservedDraft]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(drafts)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    @discardableResult
    func save(fullText: String, target: PreservedDraftTarget, sourceTaskID: UUID,
              sourceSessionID: UUID? = nil) throws -> PreservedDraft {
        try queue.sync {
            // 文件存在但不可读/不可解码时必须把错误抛给调用方；绝不能把损坏
            // 或暂时不可读的正式库当成空库并覆盖。
            var drafts = try readUnlocked()
            let aliases = ZhihuAccountIdentity.normalizedAliases(target.accountAliases)
            let normalizedTarget = PreservedDraftTarget(accountStableID: target.accountStableID,
                                                         accountAliases: aliases,
                                                         questionID: target.questionID)
            let index = drafts.firstIndex {
                $0.target.questionID == normalizedTarget.questionID &&
                ($0.target.accountStableID == normalizedTarget.accountStableID ||
                 !Set($0.target.accountAliases).isDisjoint(with: Set(aliases)))
            }
            let nextVersion = index.map { drafts[$0].version + 1 } ?? 1
            let draft = PreservedDraft(id: index.map { drafts[$0].id } ?? UUID(), fullText: fullText,
                                       version: nextVersion, target: normalizedTarget,
                                       sourceTaskID: index.map { drafts[$0].sourceTaskID } ?? sourceTaskID,
                                       sourceSessionID: sourceSessionID ?? index.flatMap { drafts[$0].sourceSessionID },
                                       updatedAt: Date(),
                                       textHash: Self.textHash(fullText))
            if let index { drafts[index] = draft } else { drafts.append(draft) }
            drafts.sort { $0.updatedAt > $1.updatedAt }
            // 稿件是用户内容；未定义显式清理策略前不做静默淘汰。
            try writeUnlocked(drafts)
            return draft
        }
    }

    func latestZhihuDraft() -> PreservedDraft? {
        queue.sync { (try? readUnlocked())?.max { $0.updatedAt < $1.updatedAt } }
    }

    func draft(id: UUID) throws -> PreservedDraft? {
        try queue.sync { try readUnlocked().first { $0.id == id } }
    }

    func draft(sourceTaskID: UUID) throws -> PreservedDraft? {
        try queue.sync {
            try readUnlocked().filter { $0.sourceTaskID == sourceTaskID }
                .max { $0.updatedAt < $1.updatedAt }
        }
    }

    func draft(sourceSessionID: UUID) throws -> PreservedDraft? {
        try queue.sync {
            try readUnlocked().filter { $0.sourceSessionID == sourceSessionID }
                .max { $0.updatedAt < $1.updatedAt }
        }
    }

    func all() throws -> [PreservedDraft] { try queue.sync { try readUnlocked() } }
}
