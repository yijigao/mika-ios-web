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

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func readUnlocked() -> [PreservedDraft] {
        guard let data = try? Data(contentsOf: fileURL),
              let drafts = try? JSONDecoder().decode([PreservedDraft].self, from: data) else { return [] }
        return drafts
    }

    private func writeUnlocked(_ drafts: [PreservedDraft]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(drafts)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    @discardableResult
    func save(fullText: String, target: PreservedDraftTarget, sourceTaskID: UUID) throws -> PreservedDraft {
        try queue.sync {
            var drafts = readUnlocked()
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
                                       updatedAt: Date(),
                                       textHash: Self.hash(fullText))
            if let index { drafts[index] = draft } else { drafts.append(draft) }
            drafts.sort { $0.updatedAt > $1.updatedAt }
            try writeUnlocked(Array(drafts.prefix(20)))
            return draft
        }
    }

    func latestZhihuDraft() -> PreservedDraft? {
        queue.sync { readUnlocked().max { $0.updatedAt < $1.updatedAt } }
    }

    func all() -> [PreservedDraft] { queue.sync { readUnlocked() } }
}
