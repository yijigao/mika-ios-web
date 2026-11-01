import SwiftUI
enum AgentStatus {
    case idle, running, paused(String), waitingConfirm(AgentAction), waitingManual(String), done(String), failed(String)
    var label: String {
        switch self {
        case .idle: return "待命"
        case .running: return "运行中"
        case .paused(let s): return "已暂停：\(s)"
        case .waitingConfirm(let a): return "等待确认：\(a.reason)"
        case .waitingManual(let s): return "等待手动输入：\(s)"
        case .done(let s): return "完成：\(s)"
        case .failed(let s): return "失败：\(s)"
        }
    }
}
struct AgentStep: Identifiable {
    let id: Int
    let action, reason: String
}
@MainActor final class AgentEngine: ObservableObject {
    @Published var taskText = ""
    @Published private(set) var status: AgentStatus = .idle
    @Published private(set) var steps: [AgentStep] = []
    @Published private(set) var active = true
    private let web: WebController
    private let settings: SettingsStore
    private var worker: Task<Void, Never>?
    private var generation = UUID()
    private var goal = ""
    private var limit = 25
    private var stepSeq = 0
    private var pending: (AgentAction, PageElement, String, Int)?
    init(web: WebController, settings: SettingsStore) { self.web = web; self.settings = settings }
    var busy: Bool {
        switch status { case .running, .waitingConfirm, .waitingManual, .paused: return true; default: return false }
    }
    func start(local: String? = nil, task: String? = nil) {
        stop()
        guard active else { status = .paused("任务只能在前台执行"); return }
        guard settings.hasKey else { status = .failed("未配置 API Key：点控制台下方的橙色提示进入设置页，选服务商、粘贴 Key、测试连接后再开始"); return }
        if let task { taskText = task }
        guard !taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status = .failed("请输入任务"); return }
        goal = taskText; limit = min(50, max(5, settings.maxSteps)); steps = []; stepSeq = 0
        do { if let local { try web.loadLocal(local) } } catch { status = .failed(error.localizedDescription); return }
        launch()
    }
    func stop() { generation = UUID(); worker?.cancel(); worker = nil; pending = nil; if busy { status = .paused("用户已停止，可继续或重新开始") } }
    func setForeground(_ foreground: Bool) {
        active = foreground
        if !foreground && busy { stop(); status = .paused("App 已离开前台；返回后点继续") }
    }
    func resume() {
        guard active, !goal.isEmpty else { return }
        guard settings.hasKey else { status = .failed("未配置 API Key：请先在设置页配置并测试连接"); return }
        pending = nil; launch()
    }
    func confirm(execute: Bool) {
        guard active, let saved = pending else { return }
        pending = nil
        if !execute { appendStep("skip", "用户跳过：\(saved.0.reason)"); launch(); return }
        launch(confirmed: saved)
    }
    private func launch(confirmed: (AgentAction, PageElement, String, Int)? = nil) {
        generation = UUID(); let token = generation
        worker?.cancel(); status = .running
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                if let saved = confirmed {
                    let page = try await web.state()
                    try check(token)
                    guard page.url == saved.2, web.revision == saved.3, let target = page.elements.first(where: { $0.index == saved.1.index }), target == saved.1 else { throw MikaError("确认期间页面目标已变化，请重新开始或继续") }
                    if SafetyPolicy.check(saved.0, target) == .manual { status = .waitingManual("请手动填写密码或验证码后继续"); return }
                    try await web.execute(saved.0, expected: target, approved: true)
                    try check(token)
                    record(saved.0)
                    try await Task.sleep(for: .milliseconds(500))
                }
                while steps.count < limit {
                    try check(token)
                    let page = try await web.state()
                    try check(token)
                    let revision = web.revision
                    let json = String(decoding: try JSONEncoder().encode(page), as: UTF8.self)
                    let history = steps.map { "\($0.id). \($0.action): \($0.reason)" }.joined(separator: "\n")
                    let action = try await ModelClient().next(baseURL: settings.baseURL, model: settings.model, key: Keychain.read(), prompt: "任务：\(goal)\n历史：\(history)\n当前页面 JSON：\(json)")
                    try check(token)
                    if action.action == "done" { record(action); status = .done(action.summary); return }
                    if action.action == "ask_user" { record(action); status = .waitingManual(action.question); return }
                    var checkedTarget: PageElement?
                    if ["click", "type"].contains(action.action) {
                        let current = try await web.state()
                        try check(token)
                        guard current.url == page.url, revision == web.revision,
                              let old = page.elements.first(where: { $0.index == action.index }),
                              let target = current.elements.first(where: { $0.index == action.index }), old == target else { throw MikaError("模型思考期间页面目标已变化，请继续重试") }
                        checkedTarget = target
                        switch SafetyPolicy.check(action, target) {
                        case .manual: record(action, suffix: "（未执行，请手动输入）"); status = .waitingManual("密码或疑似验证码字段，请在网页手动填写后点继续"); return
                        case .confirm: pending = (action, target, current.url, revision); status = .waitingConfirm(action); return
                        case .allow: break
                        }
                    }
                    try check(token)
                    try await web.execute(action, expected: checkedTarget)
                    try check(token)
                    record(action)
                    try await Task.sleep(for: .milliseconds(500))
                }
                status = .paused("已达最大 \(limit) 步，请检查结果或重新开始")
            } catch {
                guard token == generation else { return }
                if error is CancellationError { status = .paused("已取消") }
                else { status = .failed(error.localizedDescription) }
            }
        }
    }
    private func check(_ token: UUID) throws { try Task.checkCancellation(); guard active, token == generation else { throw CancellationError() } }
    private func appendStep(_ action: String, _ reason: String) {
        stepSeq += 1
        steps.append(AgentStep(id: stepSeq, action: action, reason: reason))
    }
    private func record(_ action: AgentAction, suffix: String = "") { appendStep(action.action, action.reason + suffix) }
}
