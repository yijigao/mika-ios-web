import SwiftUI

/// 会话列表（M1，2026-11-02）：多会话外壳的管理入口（ContentView 工具栏
/// 汉堡按钮打开为左抽屉）。职责：会话的新建／切换／改名／删除、排队任务
/// 的查看与取消、执行异常标记的展示。
///
/// 切换与删除都是跨对象编排，顺序是本页的核心契约：
/// - 切换：①SessionStore 当前会话指针先行 → ②对话存储换源（旧条目落盘
///   收尾、新条目整表载入）→ ③引擎 adopt（空闲才换运行时与快照；执行中
///   只换标签显示，运行现场留原会话）。标签换组在 adopt 内部完成。
/// - 删除：执行中的会话经二次确认后先 stop＋finish；删的若是
///   当前查看会话，先切到另一个会话再删；排队任务与标签随会话一并
///   回收，最后才删索引与目录（SessionStore.deleteSession）。
/// 本页文案口径：只说多会话／排队，不承诺「并行执行」——同一时刻只有
/// 一个任务在执行，这是串行队列的语义（见引擎 advanceQueue）。
struct SessionListView: View {
    @ObservedObject var engine: AgentEngine
    @ObservedObject var conversation: AgentConversationStore
    @ObservedObject var web: WebController
    @ObservedObject private var store = SessionStore.shared
    var onClose: () -> Void
    var onSessionEntered: () -> Void
    var onNewSessionFocus: () -> Void
    @State private var renameTarget: UUID?
    @State private var renameText = ""
    @State private var deleteTarget: SessionMeta?
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { createSession() } label: {
                        Label("新对话", systemImage: "square.and.pencil")
                    }
                    TextField("搜索会话", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                        .accessibilityHint("搜索结构已预留，稍后开放")
                }
                if let anomaly = engine.executionAnomaly {
                    Section {
                        Text(anomaly).font(.caption).foregroundStyle(.orange)
                    }
                }
                let ordered = DrawerSessionOrdering.split(visibleSessions)
                if !ordered.pinned.isEmpty {
                    Section("置顶") {
                        ForEach(ordered.pinned) { meta in row(meta) }
                    }
                }
                ForEach(SessionTimeGroup.allCases, id: \.self) { group in
                    let items = ordered.rest.filter { group.contains($0.lastActiveAt) }
                    if !items.isEmpty {
                        Section(group.title) {
                            ForEach(items) { meta in row(meta) }
                        }
                    }
                }
                if !engine.queuedTasks.isEmpty {
                    Section("排队中的任务（按顺序启动）") {
                        ForEach(engine.queuedTasks) { item in
                            queueRow(item)
                        }
                    }
                }
                Section { EmptyView() } footer: {
                    Text("同一时刻只有一个任务在执行：在其他会话里写下的任务会排队，轮到时在它自己的会话里启动。对话记录、标签页与未完成的任务都按会话分开保存。")
                        .font(.caption)
                }
            }
            .navigationTitle("会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { onClose() }
                }
            }
            .alert("重命名会话", isPresented: renamePresented) {
                TextField("会话名称", text: $renameText)
                Button("取消", role: .cancel) { renameTarget = nil }
                Button("保存") {
                    if let id = renameTarget { store.renameSession(id: id, title: renameText) }
                    renameTarget = nil
                }
            }
            .alert("删除会话", isPresented: deletePresented) {
                Button("取消", role: .cancel) { deleteTarget = nil }
                Button("删除", role: .destructive) {
                    if let target = deleteTarget { deleteSession(target) }
                    deleteTarget = nil
                }
            } message: {
                Text("会话「\(deleteTarget?.title ?? "")」的对话记录、标签与未完成任务将一并删除，不可恢复。")
            }
        }
    }

    private var visibleSessions: [SessionMeta] {
        store.sessions
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }
    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    // MARK: - 行

    private func row(_ meta: SessionMeta) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(meta.title).font(.body)
                    if meta.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                HStack(spacing: 6) {
                    if meta.id == store.currentSessionID {
                        badge("当前", .blue)
                    }
                    if meta.id == engine.runSessionID, engine.busy {
                        badge(runBadgeText, .orange)
                    }
                    let queued = engine.queuedTasks.filter { $0.sessionID == meta.id }.count
                    if queued > 0 {
                        badge("排队 \(queued)", .purple)
                    }
                    Text(Self.relativeFormatter.localizedString(for: meta.lastActiveAt, relativeTo: Date()))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if meta.id == store.currentSessionID {
                Image(systemName: "checkmark").foregroundStyle(.blue)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if meta.id != store.currentSessionID { switchTo(meta.id) }
            onSessionEntered()
            onClose()
        }
        .swipeActions(edge: .trailing) {
            if canDelete(meta) {
                Button("删除", role: .destructive) { deleteTarget = meta }
            }
            Button("改名") {
                renameTarget = meta.id
                renameText = meta.title
            }
            .tint(.blue)
            Button(meta.pinned ? "取消置顶" : "置顶") { store.togglePin(id: meta.id) }
                .tint(.orange)
        }
        .swipeActions(edge: .leading) {
            Button(meta.pinned ? "取消置顶" : "置顶") { store.togglePin(id: meta.id) }
                .tint(.orange)
        }
        .contextMenu {
            Button(meta.pinned ? "取消置顶" : "置顶") { store.togglePin(id: meta.id) }
            Button("重命名") { renameTarget = meta.id; renameText = meta.title }
            if canDelete(meta) { Button("删除", role: .destructive) { deleteTarget = meta } }
        }
    }

    private func queueRow(_ item: AgentEngine.QueuedTask) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text).font(.callout).lineLimit(2)
                Text("会话「\(sessionTitle(item.sessionID))」")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("取消") { engine.cancelQueuedTask(id: item.id) }
                .buttonStyle(.bordered)
                .font(.caption)
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var runBadgeText: String {
        switch engine.status {
        case .waitingConfirm: return "等你确认"
        case .waitingManual: return "等你处理"
        case .paused: return "已暂停"
        default: return "执行中"
        }
    }

    private static let relativeFormatter = RelativeDateTimeFormatter()

    private func sessionTitle(_ id: UUID) -> String {
        store.sessions.first(where: { $0.id == id })?.title ?? "已删除的会话"
    }

    // MARK: - 编排动作（顺序契约见文件头）

    private func switchTo(_ id: UUID) {
        guard id != store.currentSessionID else { return }
        store.setCurrentSession(id: id)
        conversation.switchDisplayedSession(to: id)
        engine.adoptDisplayedSession(id)
    }

    private func createSession() {
        // 新建后按与普通切换相同的 ①②③ 顺序编排。
        let meta = store.createSession(title: "新对话")
        store.setCurrentSession(id: meta.id)
        conversation.switchDisplayedSession(to: meta.id)
        engine.adoptDisplayedSession(meta.id)
        onSessionEntered()
        onClose()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onNewSessionFocus() }
    }

    private func canDelete(_ meta: SessionMeta) -> Bool {
        guard store.sessions.count > 1 else { return false }
        return true
    }

    private func deleteSession(_ meta: SessionMeta) {
        let id = meta.id
        guard canDelete(meta) else { return }
        // 规格要求：删正在执行的会话，确认后先停并彻底结束该任务，再回收会话。
        if id == engine.runSessionID, engine.busy {
            engine.stop()
            engine.finishTaskFromUser()
        }
        // 删当前查看会话：先切到另一个会话（切换编排会把对话与标签带走）
        if id == store.currentSessionID {
            guard let fallback = store.sessions.first(where: { $0.id != id }) else { return }
            switchTo(fallback.id)
            onSessionEntered()
        }
        engine.cancelQueuedTasks(forSession: id)
        web.discardTabs(for: id)
        _ = store.deleteSession(id: id)
        // 删的若是已终结任务的所属会话，引擎运行时还指着它：把运行时
        // 对齐到当前会话（空闲 adopt：清零＋按当前会话快照恢复）
        if engine.runSessionID == id {
            engine.adoptDisplayedSession(store.currentSessionID)
        }
    }
}

private enum SessionTimeGroup: CaseIterable {
    case today, yesterday, lastSevenDays, earlier
    var title: String {
        switch self { case .today: return "今天"; case .yesterday: return "昨天"; case .lastSevenDays: return "前 7 天"; case .earlier: return "更早" }
    }
    func contains(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        if calendar.isDateInToday(date) { return self == .today }
        if calendar.isDateInYesterday(date) { return self == .yesterday }
        let startToday = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -7, to: startToday) ?? .distantPast
        return self == (date >= cutoff ? .lastSevenDays : .earlier)
    }
}
