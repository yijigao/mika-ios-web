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
enum WaitingInput {
    case question(id: UUID, text: String)
    case manual(id: UUID, text: String)
}
enum AnswerSubmissionResult { case accepted, rejected(String) }
private struct QuestionAnswer: Encodable {
    let questionID: UUID
    let question: String
    let answer: String
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
    @Published private(set) var conversationTaskID: UUID?
    @Published private(set) var waitingInput: WaitingInput?
    @Published private(set) var executionSerial = 0
    /// 任务会话是否活跃（未终结）：launch 置真，完成／失败／停止置假；等待确认／手输／
    /// 步数暂停期间保持真。BrowserDockView 以此决定浏览器布局尺寸的所有权
    /// （活跃期锁定展开工作尺寸，见 AGENT-VIEWPORT-FIX 的视口状态迁移表）。
    @Published private(set) var sessionActive = false
    private let web: WebController
    private let settings: SettingsStore
    private var worker: Task<Void, Never>?
    private var generation = UUID()
    private var goal = ""
    private var limit = 25
    private var stepSeq = 0
    private var pending: (AgentAction, PageElement, String, Int)?
    private var answerContext: [QuestionAnswer] = []
    /// 同一目标「整轮重找失败」的连续计数（按稳定描述键）：连败 2 轮即以具体口径终止，
    /// 不把步数耗在原地重试上；任一目标动作执行成功即清零（AGENT-VIEWPORT-FIX）。
    private var lastStaleKey: String?
    private var staleStreak = 0
    init(web: WebController, settings: SettingsStore) { self.web = web; self.settings = settings }
    var taskLimit: Int { limit }
    var busy: Bool {
        switch status { case .running, .waitingConfirm, .waitingManual, .paused: return true; default: return false }
    }
    func start(local: String? = nil, task: String? = nil) {
        stop()
        guard active else { status = .paused("任务只能在前台执行"); return }
        guard settings.hasKey else { status = .failed("未配置 API Key：点控制台下方的橙色提示进入设置页，选服务商、粘贴 Key、测试连接后再开始"); return }
        if let issue = SettingsStore.validateModelName(settings.model, provider: settings.provider) { status = .failed(issue.message); return }
        if let task { taskText = task }
        guard !taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status = .failed("请输入任务"); return }
        goal = taskText; limit = min(50, max(5, settings.maxSteps)); steps = []; stepSeq = 0; answerContext = []; waitingInput = nil; lastStaleKey = nil; staleStreak = 0
        conversationTaskID = UUID()
        do { if let local { try web.loadLocal(local) } } catch { status = .failed(error.localizedDescription); return }
        // 任务绑定到开始时的当前标签页：全程作用于它，用户中途手动切页不影响任务（TABS-IMPL）
        web.beginExecution()
        launch()
    }
    func stop() { generation = UUID(); worker?.cancel(); worker = nil; pending = nil; sessionActive = false; web.endExecution(); if busy { status = .paused("用户已停止，可继续或重新开始") } }
    func setForeground(_ foreground: Bool) {
        active = foreground
        if !foreground && busy { stop(); status = .paused("App 已离开前台；返回后点继续") }
    }
    func resume() {
        guard active, !goal.isEmpty else { return }
        guard settings.hasKey else { status = .failed("未配置 API Key：请先在设置页配置并测试连接"); return }
        // 绑定还在（确认／手输等待后继续）则沿用原执行页；已解除（如切后台被 stop）则绑定到当前页
        if web.executionTabID == nil { web.beginExecution() }
        pending = nil; launch()
    }
    func submitAnswer(_ text: String, requestID: UUID) -> AnswerSubmissionResult {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return .rejected("请输入回答") }
        guard active, !goal.isEmpty, conversationTaskID != nil else { return .rejected("当前任务已失效") }
        guard settings.hasKey else { return .rejected("请先在设置页配置 API Key") }
        guard case .some(.question(let id, let question)) = waitingInput, id == requestID else { return .rejected("这条问题已失效") }
        switch status { case .waitingManual, .paused: break; default: return .rejected("当前不能提交回答") }
        answerContext.append(QuestionAnswer(questionID: id, question: question, answer: answer))
        waitingInput = nil
        resume()
        return .accepted
    }
    func confirm(execute: Bool) {
        guard active, let saved = pending else { return }
        pending = nil
        if !execute { appendStep("skip", "用户跳过：\(saved.0.reason)"); launch(); return }
        launch(confirmed: saved)
    }
    private func launch(confirmed: (AgentAction, PageElement, String, Int)? = nil) {
        generation = UUID(); let token = generation
        worker?.cancel(); status = .running; sessionActive = true
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                if let saved = confirmed {
                    let page = try await web.state()
                    try check(token)
                    // 确认等待期间页面可能已重排：先认原 index 处逐字段相等的元素，认不到
                    // 再按稳定描述重找；网址已变（导航离开）或描述也认不到，才按「目标已
                    // 变化」安全失败——不会误执行到别的元素上（AGENT-VIEWPORT-FIX）。
                    guard page.url == saved.2 else { throw MikaError("确认期间页面目标已变化，请重新开始或继续") }
                    var confirmedTarget = page.elements.first(where: { $0.index == saved.1.index && $0 == saved.1 })
                    if confirmedTarget == nil {
                        confirmedTarget = resolveTarget(descriptor: ElementDescriptor(saved.1), original: saved.1, in: page.elements)
                    }
                    guard let target = confirmedTarget else { throw MikaError("确认期间页面目标已变化，请重新开始或继续") }
                    if SafetyPolicy.check(saved.0, target) == .manual { waitingInput = .manual(id: UUID(), text: "请手动填写密码或验证码后继续"); status = .waitingManual("请手动填写密码或验证码后继续"); return }
                    executionSerial += 1
                    try await web.execute(saved.0, expected: target, approved: true)
                    try check(token)
                    record(saved.0)
                    try await Task.sleep(for: .milliseconds(500))
                }
                while steps.count < limit {
                    try check(token)
                    let page = try await web.state()
                    try check(token)
                    let json = String(decoding: try JSONEncoder().encode(page), as: UTF8.self)
                    let history = steps.map { "\($0.id). \($0.action): \($0.reason)" }.joined(separator: "\n")
                    let answers = String(decoding: try JSONEncoder().encode(answerContext), as: UTF8.self)
                    let action = try await ModelClient().next(baseURL: settings.baseURL, model: settings.model, key: Keychain.read(), prompt: "任务：\(goal)\n历史：\(history)\n用户补充问答：\(answers)\n当前页面 JSON：\(json)")
                    try check(token)
                    if action.action == "done" { record(action); status = .done(action.summary); sessionActive = false; web.endExecution(); return }
                    if action.action == "ask_user" { record(action); waitingInput = .question(id: UUID(), text: action.question); status = .waitingManual(action.question); return }
                    if action.action == "open_new_tab" {
                        // 在新标签页打开指定网址：新页成为当前页且执行绑定随之移过去，后续动作作用于新页
                        executionSerial += 1
                        _ = try web.openTabForExecution(urlString: action.url)
                        try check(token)
                        record(action)
                        try await Task.sleep(for: .milliseconds(500))
                        continue
                    }
                    if ["click", "type"].contains(action.action) {
                        // 目标获取走失效恢复（runTargeted）：页面在模型思考／执行期间重排时
                        // 按稳定描述重找重绑，不再把「目标已失效／已变化」直接判为任务失败。
                        switch try await runTargeted(action, modelPage: page, token: token) {
                        case .executed:
                            record(action)
                            try await Task.sleep(for: .milliseconds(500))
                        case .strategySwitch:
                            break // 策略切换已记入轨迹，下一轮带着新快照让模型重新判断
                        case .waiting:
                            return // waitingConfirm／waitingManual 已置位，等用户介入后另行 launch
                        }
                        continue
                    }
                    try check(token)
                    executionSerial += 1
                    try await web.execute(action, expected: nil)
                    try check(token)
                    record(action)
                    try await Task.sleep(for: .milliseconds(500))
                }
                status = .paused("已达最大 \(limit) 步，请检查结果或重新开始")
            } catch {
                guard token == generation else { return }
                sessionActive = false
                web.endExecution()
                if error is CancellationError { status = .paused("已取消") }
                else { status = .failed(error.localizedDescription) }
            }
        }
    }
    /// click／type 的执行结果：executed＝已执行；strategySwitch＝目标整轮重找仍无法定位，
    /// 已记策略切换步、交模型按新快照重新判断；waiting＝已进入确认／手输等待（状态已置位）。
    private enum TargetedOutcome { case executed, strategySwitch, waiting }

    /// click／type 的目标获取＋执行，带失效恢复（AGENT-VIEWPORT-FIX）：
    /// 模型给的 index 只对它所见的那份快照有效——先从该元素提取稳定描述，再在最新快照里
    /// 按描述重找（resolveTarget）；找不到、或执行层报失效类错误（快照到执行之间的竞态），
    /// 就换一份新快照（state() 内含动作后稳定性等待）重找，定位失败与执行失效共用同一份
    /// 预算：单步最多重找 2 次。重找成功照常走安全检查与执行，任务不因一次重排而失败。
    /// 预算耗尽仍定位不到 → 记策略切换步并把主动权交回模型，不直接判失败；同一目标若
    /// 连续第二轮整轮重找失败，则以「页面结构已变」的具体口径终止（见 registerStrategySwitch）。
    private func runTargeted(_ action: AgentAction, modelPage: PageState, token: UUID) async throws -> TargetedOutcome {
        guard action.index >= 0, action.index < modelPage.elements.count else {
            return try registerStrategySwitch(key: "index:\(action.index)", label: "目标元素")
        }
        let original = modelPage.elements[action.index]
        let descriptor = ElementDescriptor(original)
        let label = !original.text.isEmpty ? original.text : (!original.ariaLabel.isEmpty ? original.ariaLabel : "目标元素")
        var refinds = 0
        var snapshot = modelPage
        while true {
            try check(token)
            // 已导航离开模型所见页面：不在新页上按描述认人（同名按钮会认错），判本轮定位失败
            let target = snapshot.url == modelPage.url
                ? resolveTarget(descriptor: descriptor, original: original, in: snapshot.elements)
                : nil
            guard let target else {
                if refinds < 2 {
                    refinds += 1
                    snapshot = try await web.state()
                    continue
                }
                return try registerStrategySwitch(key: descriptor.key, label: label)
            }
            switch SafetyPolicy.check(action, target) {
            case .manual:
                record(action, suffix: "（未执行，请手动输入）")
                waitingInput = .manual(id: UUID(), text: "密码或疑似验证码字段，请在网页手动填写后点继续")
                status = .waitingManual("密码或疑似验证码字段，请在网页手动填写后点继续")
                return .waiting
            case .confirm:
                pending = (action, target, snapshot.url, web.executionRevision)
                status = .waitingConfirm(action)
                return .waiting
            case .allow:
                break
            }
            do {
                try check(token)
                executionSerial += 1
                try await web.execute(action, expected: target)
                try check(token)
                lastStaleKey = nil
                staleStreak = 0
                return .executed
            } catch {
                guard Self.isStaleTargetError(error), refinds < 2 else { throw error }
                refinds += 1
                snapshot = try await web.state()
            }
        }
    }

    /// 策略切换登记：把「目标在页面变化后无法按原描述重定位」记入轨迹（模型下一轮的历史
    /// 里看得到），并累计同一目标的连续整轮失败次数；同一目标连续第 2 轮仍整轮失败 →
    /// 抛「页面结构已变」的具体失败终止，不让步数预算耗在原地重试上。
    private func registerStrategySwitch(key: String, label: String) throws -> TargetedOutcome {
        if lastStaleKey == key {
            staleStreak += 1
        } else {
            lastStaleKey = key
            staleStreak = 1
        }
        if staleStreak >= 2 {
            throw MikaError("页面结构已变：目标「\(label)」在页面重排后反复无法定位，已换新快照重试仍失败")
        }
        appendStep("strategy", "策略切换：目标「\(label)」在页面变化后无法按原描述重定位，已刷新快照，请按最新页面重新判断")
        return .strategySwitch
    }

    /// 失效类错误判定：元素被重渲染换掉／目标已变化这一类（区别于「按钮是灰的／没输入
    /// 进去／敏感操作未经确认」等有具体口径的失败，那些不走重找、照原样上抛）。两路命中：
    /// ① 错误文案含「已失效／已变化」（Swift 侧抛出的同名错误、以及被 WebKit 带回原文的
    /// JS 错误）；② WKErrorDomain 的 JavaScript 异常（code 4）——注入脚本的 guard 校验
    /// 抛出的同名错误若未被带回原文，就以这个形态出现。把 ② 也算失效类的安全性：每次
    /// 重找重试前都会对新目标重跑 Swift 侧 SafetyPolicy.check，JS 侧的安全类抛错（敏感
    /// 操作／敏感字段）即使被误判为失效，重试也只会落到确认／手输流程，绝不绕过安全边界。
    private static func isStaleTargetError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == "WKErrorDomain", ns.code == 4 { return true }
        let text = error.localizedDescription + "|" + String(describing: ns.userInfo)
        return text.contains("已失效") || text.contains("已变化")
    }

    private func check(_ token: UUID) throws { try Task.checkCancellation(); guard active, token == generation else { throw CancellationError() } }
    private func appendStep(_ action: String, _ reason: String) {
        stepSeq += 1
        steps.append(AgentStep(id: stepSeq, action: action, reason: reason))
    }
    private func record(_ action: AgentAction, suffix: String = "") { appendStep(action.action, action.reason + suffix) }
}
