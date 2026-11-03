import Foundation
import Combine

// 会话级存储地基（H1，2026-11-02）：对话条目与任务快照从「全局单文件」改为
// 「按会话分开存储＋一个轻量索引」。此前对话条目挤在一个 entries.json 里、
// 全局上限 1000 条——新任务不断追加，老会话的历史被静默挤掉（用户感知是
// 「我的历史莫名其妙没了」）；引擎快照也是全局单键。本文件只管存储拓扑：
//
//   Application Support/MikaWeb/Sessions/
//   ├── index.json                  会话索引（元数据＋当前会话指针）
//   └── <sessionID>/
//       ├── entries.json            该会话的对话条目（PersistedChatEntry 数组）
//       └── snapshot.json           该会话的引擎快照（AgentEngine 的 SessionSnapshot 数据）
//
// 上限口径：条数上限按会话计（见 AgentConversationStore.sessionEntryCap 的
// 防爆值），新会话不再挤掉旧会话。会话的 UI 管理（新建/切换/删除入口）是
// M1 的范围；本类只提供存储与索引 API，当前产品仍只有一个「当前会话」在
// 被读写，其余会话只是落盘存在、互不挤占。
//
// 迁移（一次性、可回滚、失败不丢数据）：首次运行新版时若索引不存在，
// 自动建「默认会话」；旧版单文件对话（MikaWeb/Conversation/entries.json）
// 以复制方式搬入默认会话（原文件保留在原地作回滚备份，不删不改），复制
// 后先解码校验条数再落索引——校验不过则不写索引，下次启动重试迁移，
// 旧数据始终完好。引擎快照的旧 UserDefaults 键迁移在 AgentEngine 内
// 同口径处理（先写文件、成功后才清旧键）。
//
// 调用方约定：本类只被 @MainActor 的引擎与对话存储调用（与既有落盘代码
// 同形态：小文件同步原子写）；索引的 lastActiveAt 更新在内存即时生效、
// 落盘节流（见 touch），避免每次条目追加都连带写索引。
//
// M1（多会话外壳，2026-11-02）起，本类的当前会话指针成为「正在查看的会话」
// （displayed session）：切换会话时由编排方（SessionListView 的切换动作）
// 依次调用 setCurrentSession＋对话存储换源＋引擎 adopt＋标签换组。注意它与
// 引擎的 runSessionID（任务所属会话）是两个概念：任务在会话 A 执行期间，
// 用户可以把当前会话切到 B 浏览——引擎快照仍按 runSessionID 落 A 的目录，
// 对话条目则按条目所属会话分别落盘（见 AgentConversationStore 的路由）。
struct SessionMeta: Codable, Identifiable {
    var id: UUID
    var title: String
    var createdAt: Date
    var lastActiveAt: Date
    /// 会话状态的人读标记（active＝当前会话；archived 等后续形态由 M1 定义）
    var status: String
}

// M1 起实现 ObservableObject：会话列表 UI 需要观察索引与当前会话指针
// 的变化（H1 建存储时还没有会话 UI）。发布面只有 sessions 与
// currentSessionID 两项，与索引落盘内容一一对应。
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    private struct IndexFile: Codable {
        var sessions: [SessionMeta]
        var currentSessionID: UUID
    }

    @Published private(set) var sessions: [SessionMeta] = []
    @Published private(set) var currentSessionID: UUID
    /// 本次启动若执行过旧对话迁移，这里留一句人读说明（自检八引用）；
    /// 索引此前已建好（迁移已完成或全新安装）时为 nil。
    private(set) var migrationNote: String?

    private var lastIndexPersistAt = Date.distantPast

    private static var rootDirectory: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MikaWeb/Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private static var indexURL: URL { rootDirectory.appendingPathComponent("index.json") }
    /// 旧版对话条目的单文件位置（迁移来源；迁移后保留作回滚备份）。
    private static var legacyEntriesURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MikaWeb/Conversation/entries.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.indexURL),
           let decoded = try? JSONDecoder().decode(IndexFile.self, from: data),
           !decoded.sessions.isEmpty {
            sessions = decoded.sessions
            currentSessionID = decoded.sessions.contains(where: { $0.id == decoded.currentSessionID })
                ? decoded.currentSessionID : decoded.sessions[0].id
            return
        }
        // 首次运行新版：建默认会话，并把旧版单文件对话迁入（复制＋校验）。
        let defaultID = UUID()
        var createdAt = Date()
        var lastActiveAt = Date()
        var legacyPending = false
        if let legacyData = try? Data(contentsOf: Self.legacyEntriesURL),
           let legacyEntries = try? JSONDecoder().decode([PersistedChatEntry].self, from: legacyData) {
            let target = Self.sessionDirectory(for: defaultID).appendingPathComponent("entries.json")
            if (try? legacyData.write(to: target, options: [.atomic])) != nil,
               let check = try? Data(contentsOf: target),
               let verified = try? JSONDecoder().decode([PersistedChatEntry].self, from: check),
               verified.count == legacyEntries.count {
                if let earliest = legacyEntries.map(\.createdAt).min() { createdAt = earliest }
                if let latest = legacyEntries.map(\.createdAt).max() { lastActiveAt = latest }
                migrationNote = "已把旧版单文件对话（\(legacyEntries.count) 条）迁入默认会话，原文件保留在原地作回滚备份"
            } else {
                // 复制/校验失败：旧数据不动，本次不落索引，下次启动重试迁移
                legacyPending = true
            }
        }
        let meta = SessionMeta(id: defaultID, title: "默认会话", createdAt: createdAt, lastActiveAt: lastActiveAt, status: "active")
        sessions = [meta]
        currentSessionID = defaultID
        if !legacyPending { persistIndex() }
    }

    // MARK: - 路径

    static func sessionDirectory(for id: UUID) -> URL {
        let directory = rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    func entriesURL(for id: UUID) -> URL { Self.sessionDirectory(for: id).appendingPathComponent("entries.json") }
    func snapshotURL(for id: UUID) -> URL { Self.sessionDirectory(for: id).appendingPathComponent("snapshot.json") }

    // MARK: - 索引维护

    private func persistIndex() {
        lastIndexPersistAt = Date()
        let index = IndexFile(sessions: sessions, currentSessionID: currentSessionID)
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: Self.indexURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// 刷新某会话的最近活跃时间（状态变化时附带更新状态）。内存即时生效，
    /// 索引落盘节流到 60 秒一次（条目追加频率高，索引不必逐次跟写）。
    func touch(id: UUID, status: String? = nil) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].lastActiveAt = Date()
        if let status { sessions[index].status = status }
        if Date().timeIntervalSince(lastIndexPersistAt) > 60 { persistIndex() }
    }

    /// 切换当前会话指针（M1）：只改指针与索引落盘，不动任何会话目录内容；
    /// 对话换源、引擎 adopt、标签换组由编排方在本调用前后按序完成。
    /// 切到的会话标记 active，原当前会话的状态标记回到 idle（其快照状态
    /// 由引擎在 adopt 时另行处理，这里只维护索引层的人读标记）。
    func setCurrentSession(id: UUID) {
        guard id != currentSessionID, sessions.contains(where: { $0.id == id }) else { return }
        if let old = sessions.firstIndex(where: { $0.id == currentSessionID }), sessions[old].status == "active" {
            sessions[old].status = "idle"
        }
        currentSessionID = id
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].status = "active"
            sessions[index].lastActiveAt = Date()
        }
        persistIndex()
    }

    /// 会话改名（M1）：标题是用户与各处标签（会话列表、坞上标明、队列）里
    /// 认会话的唯一人读标识，改名即时落盘索引。
    func renameSession(id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].title = trimmed
        persistIndex()
    }

    /// 新对话第一次真正发送后，以首条用户消息生成标题；用户已经改过名的
    /// 会话绝不覆盖。列表与顶栏共用这个索引标题，因此更新会即时反映。
    func adoptAutomaticTitleIfNeeded(id: UUID, firstUserMessage: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              Self.isUntitledSession(sessions[index].title) else { return }
        let title = Self.automaticTitle(from: firstUserMessage)
        guard !title.isEmpty else { return }
        sessions[index].title = title
        persistIndex()
    }

    static func automaticTitle(from message: String) -> String {
        let compact = message.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(compact.prefix(32))
    }

    static func isUntitledSession(_ title: String) -> Bool {
        title == "新对话" || title == "新会话"
    }

    @discardableResult
    func createSession(title: String) -> SessionMeta {
        let meta = SessionMeta(id: UUID(), title: title, createdAt: Date(), lastActiveAt: Date(), status: "idle")
        sessions.append(meta)
        _ = Self.sessionDirectory(for: meta.id)
        persistIndex()
        return meta
    }

    /// 删除会话（连同其目录）。当前会话不可删——它是现役读写对象，
    /// 删它等于当场丢掉正在用的历史；M1 的删除入口也要守这条。
    @discardableResult
    func deleteSession(id: UUID) -> Bool {
        guard id != currentSessionID, sessions.contains(where: { $0.id == id }) else { return false }
        sessions.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Self.rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true))
        persistIndex()
        return true
    }

    func meta(for id: UUID) -> SessionMeta? { sessions.first { $0.id == id } }

    /// 某会话落盘条数（解码其 entries.json 计数）；文件不存在视为 0，
    /// 存在但解码失败返回 nil（区分「空」与「坏」）。
    func entryCountOnDisk(for id: UUID) -> Int? {
        let url = entriesURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([PersistedChatEntry].self, from: data) else { return nil }
        return decoded.count
    }

    // MARK: - 自检八（H1）：分库隔离验证

    /// 临时建两个会话，各写 1500 条合成条目（超过旧全局上限 1000），
    /// 回读校验各 1500 条、互不挤占、且当前会话落盘条数不变；最后把
    /// 临时会话连目录删除干净。返回逐项人读结论（✓/✗ 开头）。
    func verifyScratchSessionsH1() -> [String] {
        var lines: [String] = []
        let currentBefore = entryCountOnDisk(for: currentSessionID)
        if let note = migrationNote { lines.append("✓ 迁移：\(note)") }
        lines.append("索引在位：共 \(sessions.count) 个会话，当前会话「\(meta(for: currentSessionID)?.title ?? "?")」，落盘条数 \(currentBefore.map(String.init) ?? "读取失败")")
        let a = createSession(title: "自检八临时会话A")
        let b = createSession(title: "自检八临时会话B")
        let synthetic: [PersistedChatEntry] = (0..<1500).map { i in
            PersistedChatEntry(ChatEntry(taskID: nil, kind: .local, text: "自检八合成条目 \(i)", source: .localValidation))
        }
        guard let data = try? JSONEncoder().encode(synthetic) else {
            lines.append("✗ 合成条目编码失败，隔离验证未完成")
            _ = deleteSession(id: a.id); _ = deleteSession(id: b.id)
            return lines
        }
        do {
            try data.write(to: entriesURL(for: a.id), options: [.atomic])
            try data.write(to: entriesURL(for: b.id), options: [.atomic])
        } catch {
            lines.append("✗ 临时会话条目写入失败：\(error.localizedDescription)")
            _ = deleteSession(id: a.id); _ = deleteSession(id: b.id)
            return lines
        }
        let countA = entryCountOnDisk(for: a.id)
        let countB = entryCountOnDisk(for: b.id)
        if countA == 1500 && countB == 1500 {
            lines.append("✓ 分库隔离：两个临时会话各写入 1500 条（已超旧全局上限 1000），回读各 1500 条，互不挤占")
        } else {
            lines.append("✗ 分库隔离：临时会话回读条数 A=\(countA.map(String.init) ?? "失败")、B=\(countB.map(String.init) ?? "失败")，预期各 1500")
        }
        let currentAfter = entryCountOnDisk(for: currentSessionID)
        if currentAfter == currentBefore {
            lines.append("✓ 当前会话不受影响：落盘条数仍为 \(currentAfter.map(String.init) ?? "?")")
        } else {
            lines.append("✗ 当前会话落盘条数发生变化：\(currentBefore.map(String.init) ?? "?") → \(currentAfter.map(String.init) ?? "?")")
        }
        let removedA = deleteSession(id: a.id)
        let removedB = deleteSession(id: b.id)
        if removedA && removedB && meta(for: a.id) == nil && meta(for: b.id) == nil {
            lines.append("✓ 临时会话已连同索引与目录删除干净")
        } else {
            lines.append("✗ 临时会话删除不完整，请人工检查 Sessions 目录")
        }
        return lines
    }
}
