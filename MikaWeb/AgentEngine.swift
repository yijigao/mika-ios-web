import SwiftUI
import UIKit
import BackgroundTasks
import Combine
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
private struct QuestionAnswer: Codable {
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
    /// 瞬时错误连败计数（BACKGROUND-RESILIENCE 问题 2）：单次页面脚本异常／网页进程
    /// 中断／加载不稳／模型网络抖动只记一条「自动重试」并续跑，连续
    /// maxTransientStreak 次才判失败。任一整轮迭代走通、或切后台回前台后清零。
    private var transientStreak = 0
    static let maxTransientStreak = 3
    /// 跨步循环检测（ADOPTION-TOP3 第 2 条）：与瞬时错误重试正交——那条治「单步
    /// 失败」，这条治「多步都成功但原地打转」。pendingLoopHint 是给模型的分级
    /// 提醒，跨入阈值时置位、随下一次模型调用注入提示后清除（提醒原文同时以
    /// 「loop」步留在历史里，模型与用户都看得见）。
    private var loopDetector = LoopDetector()
    private var pendingLoopHint: String?
    /// 本任务已加载的 playbook（ADOPTION-TOP3 第 3 条）：名称防重复加载，正文
    /// 随每次模型调用注入任务上下文；playbook 只是提示层，安全判定不读它。
    private var loadedSkillNames: [String] = []
    private var loadedSkillBodies = ""
    /// 中断恢复现场（RESUME-CONTEXT-FIX）：冷启动按快照恢复出的会话，浏览器
    /// 标签现场还没重建——快照里的标签地址先存放在这里，第一次 resume 时才
    /// 由 applyPendingTabRestore 消费（重建标签＋生成 resumeNote）。restoredSession
    /// 标记「本会话来自快照恢复」，didApplyTabRestore 保证现场只处理一次。
    private var pendingTabScene: (urls: [String], activeIndex: Int, executionIndex: Int?)?
    private var restoredSession = false
    private var didApplyTabRestore = false
    /// 续跑提示：恢复会话续跑期间随每次模型调用注入 prompt 的说明段（原页面
    /// 恢复结果＋「不得向用户索要目标／网址／进度」的硬性口径），会话终结
    /// （done／failed）或新任务开始时清除。
    private var resumeNote: String?
    /// 当前会话目标（对话层判定「有可续跑上下文」用，只读）。
    var activeGoal: String { goal }
    /// 后台宽限断言（层 2）：进后台时申请、回前台／会话终结／到期时释放。
    private var backgroundGraceID: UIBackgroundTaskIdentifier = .invalid
    /// iOS 26 持续处理（层 3）的类型擦除盒：BGContinuedProcessingTask 只在 #available
    /// 分支内出现，会话本体只记标识与完成标记，任务对象以 AnyObject 持有、在可用性
    /// 分支内转回。liveIdentifier 非空＝已向系统提交且未收口（处理器可能还没被唤起）。
    private final class ContinuedProcessingBox {
        var liveIdentifier: String?
        var taskObject: AnyObject?
        var completed = true
    }
    private let continuedBox = ContinuedProcessingBox()
    /// 任务期防锁屏开关（层 4）的订阅：开关变化时立即按当前会话状态重新应用。
    private var settingsCancellable: AnyCancellable?
    init(web: WebController, settings: SettingsStore) {
        self.web = web; self.settings = settings
        settingsCancellable = settings.$keepScreenAwakeDuringTask.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.applyIdleTimerPolicy() }
        }
        restoreSnapshotIfNeeded()
    }
    var taskLimit: Int { limit }
    var busy: Bool {
        switch status { case .running, .waitingConfirm, .waitingManual, .paused: return true; default: return false }
    }
    /// 模型就绪检查（start／resume／submitAnswer 共用同一口径）：按当前模型
    /// 来源分支——ChatGPT 订阅查登录态与模型名，API Key 查 Key 与模型名合法性。
    /// 旧 resume／submitAnswer 只查 hasKey：订阅来源的会话（无 API Key 时）
    /// 中断恢复后点继续会被误拦为「未配置 API Key」（RESUME-CONTEXT-FIX）。
    private func modelReadinessIssue() -> String? {
        if settings.modelSource == .chatGPT {
            if !settings.chatGPTAuth.isLoggedIn { return "尚未登录 ChatGPT 订阅：进入设置页，在「模型来源」选「ChatGPT 订阅」，点「用 ChatGPT 登录」后再开始" }
            if settings.chatGPTModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "订阅模型名不能为空：请在设置页填写模型名" }
            return nil
        }
        if !settings.hasKey { return "未配置 API Key：点控制台下方的橙色提示进入设置页，选服务商、粘贴 Key、测试连接后再开始" }
        if let issue = SettingsStore.validateModelName(settings.model, provider: settings.provider) { return issue.message }
        return nil
    }
    func start(local: String? = nil, task: String? = nil) {
        stop()
        guard active else { status = .paused("任务只能在前台执行"); return }
        if let issue = modelReadinessIssue() { status = .failed(issue); return }
        if let task { taskText = task }
        guard !taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status = .failed("请输入任务"); return }
        goal = taskText; limit = min(50, max(5, settings.maxSteps)); steps = []; stepSeq = 0; answerContext = []; waitingInput = nil; lastStaleKey = nil; staleStreak = 0; transientStreak = 0
        loopDetector.reset(); pendingLoopHint = nil; loadedSkillNames = []; loadedSkillBodies = ""
        // 新任务开始：上一会话的中断恢复现场一并作废，不带进新会话
        pendingTabScene = nil; restoredSession = false; didApplyTabRestore = false; resumeNote = nil
        conversationTaskID = UUID()
        do { if let local { try web.loadLocal(local) } } catch { status = .failed(error.localizedDescription); return }
        // 任务绑定到开始时的当前标签页：全程作用于它，用户中途手动切页不影响任务（TABS-IMPL）
        web.beginExecution()
        launch()
    }
    func stop() {
        generation = UUID(); worker?.cancel(); worker = nil; pending = nil
        sessionActive = false; applyIdleTimerPolicy()
        endBackgroundGrace()
        completeContinuedProcessing(success: false)
        web.endExecution()
        if busy {
            status = .paused("用户已停止，可继续或重新开始")
            persistSnapshot()
        } else {
            clearSnapshot()
        }
    }
    func setForeground(_ foreground: Bool) {
        active = foreground
        if foreground {
            web.agentWorkSuspended = false
            endBackgroundGrace()
            applyIdleTimerPolicy()
            // 驻停中的循环由 checkpoint 自行醒来续跑，不需要在这里再点火；
            // 持续处理若曾被系统回收，下一次进后台时会重新提交。
        } else if busy {
            // 进后台不再停任务（BACKGROUND-RESILIENCE，取代旧「离开前台即停」口径）。
            // 本函数跑在场景更新事务里（MikaWebApp 的 scenePhase onChange），0808
            // 曾在此窗口被 scene-update 看门狗终止（0x8BADF00D）——所以这里的
            // 同步工作必须极小：先置驻停标记让网页侧轮询立即收敛，再做一次小
            // JSON 落盘与宽限申请，就此返回；不改 status／sessionActive（不触发
            // 全树 SwiftUI 刷新与坞布局迁移），持续处理的注册/提交涉及系统 XPC，
            // 异步补交、不占场景事务的同步路径。循环本体随后在 checkpoint 处
            // 驻停等回前台自动续跑，进度与等待状态都不动。
            web.agentWorkSuspended = true
            persistSnapshot()
            beginBackgroundGrace()
            Task { @MainActor [weak self] in self?.submitContinuedProcessingIfPossible() }
        }
    }
    func resume() {
        guard active, !goal.isEmpty else { return }
        if let issue = modelReadinessIssue() { status = .failed(issue); return }
        // 中断恢复的会话：先把浏览器现场带回中断时（重建标签＋导航回原页面），
        // 再启动主循环——循环第一轮的 state() 会等页面加载稳定后才抽状态，
        // 模型拿到的就是原页面＋原目标＋完整历史，而不是起始页＋一句「继续」。
        applyPendingTabRestore()
        // 绑定还在（确认／手输等待后继续）则沿用原执行页；已解除（如切后台被 stop）则绑定到当前页
        if web.executionTabID == nil { web.beginExecution() }
        pending = nil; launch()
    }

    /// 消费冷启动恢复时暂存的标签现场（只处理一次）：现场全新（用户重启后
    /// 没动过浏览器）才整组按快照重建；已被手动浏览过则不覆盖，只把中断
    /// 时的执行页地址写进续跑提示、由模型自行导航回去。旧快照没有标签
    /// 记录时同样只写提示。无论哪条分支，resumeNote 都带上「目标／网址／
    /// 进度已在上下文里，不得反问用户」的硬性口径（RESUME-CONTEXT-FIX）。
    private func applyPendingTabRestore() {
        guard restoredSession, !didApplyTabRestore else { return }
        didApplyTabRestore = true
        let scene = pendingTabScene
        pendingTabScene = nil
        let executionURL: String = {
            guard let scene else { return "" }
            if let index = scene.executionIndex, scene.urls.indices.contains(index) { return scene.urls[index] }
            return scene.urls.indices.contains(scene.activeIndex) ? scene.urls[scene.activeIndex] : ""
        }()
        let outcome: String
        if let scene, scene.urls.contains(where: { !$0.isEmpty }) {
            if web.tabsArePristine {
                web.rebuildTabs(urls: scene.urls, activeIndex: scene.activeIndex, executionIndex: scene.executionIndex)
                outcome = executionURL.isEmpty
                    ? "浏览器已按中断时现场重建，中断时执行页是起始页。"
                    : "浏览器已按中断时现场重建，并已开始载入中断时的页面：\(executionURL)（续跑第一步看到的就是它，加载未稳时先用 wait 等待，不要换页）。"
            } else {
                outcome = "App 重启后浏览器里已有手动打开的页面，未自动覆盖。中断时你正在页面：\(executionURL)。如现页面不是它，请直接 navigate 到这个网址或经站内入口回去，不要向用户询问网址。"
            }
        } else if scene != nil {
            outcome = "中断时浏览器停在起始页，继续从起始页按目标行动即可。"
        } else {
            outcome = "这份恢复记录里没有浏览器页面信息（旧版快照），浏览器现在停在起始页。请根据任务目标与历史步骤自行判断要打开的站点并 navigate 过去，不要向用户询问网址。"
        }
        resumeNote = "【中断恢复说明】本会话曾因 App 退出而中断，现在续跑。任务目标见上文「任务」，已完成步骤见「历史」，用户此前的回答见「用户补充问答」。\(outcome)硬性规则：任务目标、网址、已完成进度都在上文里，不要用 ask_user 向用户索要任务内容、网址或进度——用户刚经历中断，正等你接着做；若当前页面与中断前不一致、或原页面已失效，先在你的说明里讲清你记得的目标和已做到哪一步，再自行通过站内导航、搜索或直接打开网址找回入口继续。只有当你需要用户做一个新的决策（而不是重复提供已知信息）时，才可以提问。"
    }
    func submitAnswer(_ text: String, requestID: UUID) -> AnswerSubmissionResult {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return .rejected("请输入回答") }
        guard active, !goal.isEmpty, conversationTaskID != nil else { return .rejected("当前任务已失效") }
        if let issue = modelReadinessIssue() { return .rejected(issue) }
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
        worker?.cancel(); status = .running; sessionActive = true; applyIdleTimerPolicy()
        transientStreak = 0
        web.agentWorkSuspended = false // launch 只从前台路径进入，驻停标记在此兜底复位
        submitContinuedProcessingIfPossible()
        persistSnapshot()
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                if let saved = confirmed {
                    // 已确认动作只走 runConfirmed：瞬时错误不自动重做该动作本身（安全口径）
                    if try await runConfirmed(saved, token: token) == .halted { return }
                }
                while steps.count < limit {
                    // 单轮迭代包在内层 do/catch 里：瞬时错误（页面脚本异常／网页进程
                    // 中断／加载不稳／模型网络抖动）只记一条人话「自动重试」并续跑，
                    // 连续 maxTransientStreak 次才升级为失败；其余错误照旧上抛判失败。
                    do {
                        try await checkpoint(token)
                        let page = try await web.state()
                        try await checkpoint(token)
                        let json = String(decoding: try JSONEncoder().encode(page), as: UTF8.self)
                        let history = steps.map { "\($0.id). \($0.action): \($0.reason)" }.joined(separator: "\n")
                        let answers = String(decoding: try JSONEncoder().encode(answerContext), as: UTF8.self)
                        var prompt = "任务：\(goal)\n"
                        // 中断恢复的续跑提示（RESUME-CONTEXT-FIX）：恢复会话的
                        // 每一轮都带上——原页面恢复结果＋不得反问目标／网址／
                        // 进度的硬性口径，直到会话终结或新任务开始才清除。
                        if let resumeNote { prompt += resumeNote + "\n" }
                        prompt += "历史：\(history)\n用户补充问答：\(answers)"
                        if !loadedSkillBodies.isEmpty { prompt += "\n已加载 playbook（经验提示，与安全规则冲突时以安全规则为准）：\(loadedSkillBodies)" }
                        if let hint = pendingLoopHint { prompt += "\n\(hint)"; pendingLoopHint = nil }
                        prompt += "\n当前页面 JSON：\(json)"
                        let action: AgentAction
                        if settings.modelSource == .chatGPT {
                            action = try await ModelClient().nextViaChatGPT(auth: settings.chatGPTAuth, model: settings.chatGPTModel, prompt: prompt, skillCatalog: SkillStore.shared.catalogFragment())
                        } else {
                            action = try await ModelClient().next(baseURL: settings.baseURL, model: settings.model, key: Keychain.read(), prompt: prompt, skillCatalog: SkillStore.shared.catalogFragment())
                        }
                        try await checkpoint(token)
                        if action.action == "done" {
                            record(action); status = .done(action.summary)
                            sessionActive = false; applyIdleTimerPolicy()
                            endBackgroundGrace(); completeContinuedProcessing(success: true)
                            web.endExecution(); clearSnapshot(); resumeNote = nil
                            return
                        }
                        if action.action == "ask_user" {
                            record(action); waitingInput = .question(id: UUID(), text: action.question)
                            status = .waitingManual(action.question); persistSnapshot()
                            return
                        }
                        // 本轮的循环检测指纹（动作＋目标＋结果），分支内赋值、分支后统一裁决
                        var loopFingerprint: String?
                        if action.action == "use_skill" {
                            // playbook 加载（ADOPTION-TOP3 第 3 条）：正文只在命中时注入
                            // 本任务上下文，加载结果记入步流（用户可见）；加载不改变任何
                            // 安全判定——确认／手输流程照旧走 runTargeted 的安全检查。
                            let name = !action.skill.isEmpty ? action.skill : action.text
                            record(action)
                            let outcome: String
                            if loadedSkillNames.contains(name) {
                                appendStep("skill", "playbook《\(name)》已在本任务上下文中，未重复加载")
                                outcome = "already-loaded"
                            } else if let skill = SkillStore.shared.skill(named: name) {
                                loadedSkillNames.append(skill.name)
                                loadedSkillBodies += "\n【playbook：\(skill.name)】\n\(skill.body)"
                                appendStep("skill", "已加载 playbook《\(skill.name)》：\(skill.description)")
                                outcome = "loaded"
                            } else {
                                appendStep("skill", "没有名为「\(name)」的 playbook，已忽略；请按清单选择或直接执行任务")
                                outcome = "missing"
                            }
                            loopFingerprint = LoopDetector.fingerprint(action: "use_skill", target: name, outcome: outcome)
                        } else if action.action == "open_new_tab" {
                            // 在新标签页打开指定网址：新页成为当前页且执行绑定随之移过去，后续动作作用于新页
                            executionSerial += 1
                            _ = try web.openTabForExecution(urlString: action.url)
                            try await checkpoint(token)
                            record(action)
                            loopFingerprint = LoopDetector.fingerprint(action: action.action, target: action.url, outcome: "ok")
                            try await Task.sleep(for: .milliseconds(500))
                        } else if ["click", "type"].contains(action.action) {
                            // 循环检测的目标键：模型所见快照里目标元素的稳定描述（type 再
                            // 掺输入文本指纹——同元素换内容不算同动作，同元素同内容才算）
                            var targetKey = "index:\(action.index)"
                            if action.index >= 0, action.index < page.elements.count {
                                targetKey = ElementDescriptor(page.elements[action.index]).key
                                if action.action == "type" { targetKey += "|\(LoopDetector.textFingerprint(action.text))" }
                            }
                            // 目标获取走失效恢复（runTargeted）：页面在模型思考／执行期间重排时
                            // 按稳定描述重找重绑，不再把「目标已失效／已变化」直接判为任务失败。
                            switch try await runTargeted(action, modelPage: page, token: token) {
                            case .executed:
                                record(action)
                                loopFingerprint = LoopDetector.fingerprint(action: action.action, target: targetKey, outcome: "executed")
                                try await Task.sleep(for: .milliseconds(500))
                            case .strategySwitch:
                                loopFingerprint = LoopDetector.fingerprint(action: action.action, target: targetKey, outcome: "strategy-switch")
                                break // 策略切换已记入轨迹，下一轮带着新快照让模型重新判断
                            case .waiting:
                                persistSnapshot()
                                return // waitingConfirm／waitingManual 已置位，等用户介入后另行 launch
                            }
                        } else {
                            try await checkpoint(token)
                            executionSerial += 1
                            try await web.execute(action, expected: nil)
                            try await checkpoint(token)
                            record(action)
                            let target = action.action == "navigate" ? action.url : (action.action == "scroll" ? action.direction : "\(Int(action.seconds))")
                            loopFingerprint = LoopDetector.fingerprint(action: action.action, target: target, outcome: "ok")
                            try await Task.sleep(for: .milliseconds(500))
                        }
                        // 循环裁决（ADOPTION-TOP3 第 2 条）：警告只置位提醒、随下一次
                        // 调用注入；熔断＝真正停驻（已暂停、可继续），与步数上限的
                        // 停驻同形态——执行绑定与进度都保留，用户点继续即接着跑，
                        // 该指纹的窗口记录已在检测器内清掉，不会一恢复就再熔断。
                        if let loopFingerprint {
                            let verdict = loopDetector.record(fingerprint: loopFingerprint)
                            switch verdict.level {
                            case .tripped:
                                appendStep("loop", "循环熔断：同一动作已重复 \(verdict.count) 次且页面结果没有变化，已停下等你决定")
                                status = .paused("检测到在同一处反复打转：同一动作重复了 \(verdict.count) 次、页面没有变化。点「继续」可让它再试，或换个说法重新开始")
                                persistSnapshot()
                                return
                            case .severe:
                                appendStep("loop", "循环严重提醒：同一动作已重复 \(verdict.count) 次，下一步提示已要求模型必须换做法，再重复将自动停下")
                                pendingLoopHint = "严重警告：你已对同一目标重复执行同一动作 \(verdict.count) 次，页面结果始终没有变化。若下一步仍原样重复，任务将自动停下交用户决定。必须换一种做法：换目标、换入口、先滚动或等待让页面变化，或用 ask_user 向用户说明卡点。"
                            case .warning:
                                appendStep("loop", "循环提醒：同一动作已重复 \(verdict.count) 次且结果未变，下一步提示已要求模型换做法")
                                pendingLoopHint = "注意：你已对同一目标重复执行同一动作 \(verdict.count) 次，页面结果没有变化。下一步不要原样重复：换目标、换入口、先滚动或等待让页面变化，或用 ask_user 向用户说明卡点。"
                            case .none:
                                break
                            }
                        }
                        // 一整轮迭代走通：瞬时连败清零
                        transientStreak = 0
                    } catch {
                        guard token == generation else { return }
                        if error is CancellationError { throw error }
                        guard let kind = Self.transientKind(of: error) else { throw error }
                        transientStreak += 1
                        writeTransientDiagnostic(kind: kind, error: error, streak: transientStreak)
                        if transientStreak >= Self.maxTransientStreak {
                            throw MikaError(Self.transientFailureMessage(kind: kind, error: error))
                        }
                        appendStep("retry", Self.transientRetryNote(kind: kind, streak: transientStreak))
                        if (kind == .pageLoad || kind == .webContentProcess) && transientStreak == 2 {
                            web.reloadExecutionTab() // 连败第 2 次：先重载执行页一次再试
                        }
                        if !active { try await checkpoint(token) } // 后台出的错先驻停、回前台再重试
                        try await Task.sleep(for: .milliseconds(600 * transientStreak))
                    }
                }
                status = .paused("已达最大 \(limit) 步，请检查结果或重新开始")
                persistSnapshot()
            } catch {
                guard token == generation else { return }
                sessionActive = false; applyIdleTimerPolicy()
                endBackgroundGrace(); completeContinuedProcessing(success: false)
                web.endExecution(); clearSnapshot(); resumeNote = nil
                if error is CancellationError { status = .paused("已取消") }
                else { status = .failed(error.localizedDescription) }
            }
        }
    }

    private enum ConfirmedOutcome { case proceed, halted }

    /// 已确认动作的执行段（launch 的前置段）：复核目标后只执行一次。确认等待期间
    /// 页面可能已重排：先认原 index 处逐字段相等的元素，认不到再按稳定描述重找；
    /// 网址已变（导航离开）或描述也认不到，才按「目标已变化」安全失败——不会误执行
    /// 到别的元素上（AGENT-VIEWPORT-FIX）。本段的**瞬时错误不自动重做该动作本身**
    /// （BACKGROUND-RESILIENCE 问题 2 第 3 条）：动作可能没执行、也可能已生效但回读
    /// 失败，不猜——把 pending 原样放回、状态回到等待确认，留给用户核对页面后再次
    /// 确认或跳过；再次确认时会重新走本段的复核，仍不会误执行。非瞬时错误照旧上抛
    /// 判失败（含上述安全失败与手输转等待）。
    private func runConfirmed(_ saved: (AgentAction, PageElement, String, Int), token: UUID) async throws -> ConfirmedOutcome {
        do {
            try await checkpoint(token)
            let page = try await web.state()
            try await checkpoint(token)
            guard page.url == saved.2 else { throw MikaError("确认期间页面目标已变化，请重新开始或继续") }
            var confirmedTarget = page.elements.first(where: { $0.index == saved.1.index && $0 == saved.1 })
            if confirmedTarget == nil {
                confirmedTarget = resolveTarget(descriptor: ElementDescriptor(saved.1), original: saved.1, in: page.elements)
            }
            guard let target = confirmedTarget else { throw MikaError("确认期间页面目标已变化，请重新开始或继续") }
            if SafetyPolicy.check(saved.0, target) == .manual {
                waitingInput = .manual(id: UUID(), text: "请手动填写密码或验证码后继续")
                status = .waitingManual("请手动填写密码或验证码后继续")
                persistSnapshot()
                return .halted
            }
            executionSerial += 1
            try await web.execute(saved.0, expected: target, approved: true)
            try await checkpoint(token)
            record(saved.0)
            try await Task.sleep(for: .milliseconds(500))
            return .proceed
        } catch {
            guard token == generation else { throw CancellationError() }
            if error is CancellationError { throw error }
            guard let kind = Self.transientKind(of: error) else { throw error }
            writeTransientDiagnostic(kind: kind, error: error, streak: 0)
            pending = saved
            appendStep("retry", "页面脚本出错，已确认的操作没有自动重做，请核对页面后再次确认或跳过")
            status = .waitingConfirm(saved.0)
            persistSnapshot()
            return .halted
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
            try await checkpoint(token)
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
                try await checkpoint(token)
                executionSerial += 1
                try await web.execute(action, expected: target)
                try await checkpoint(token)
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

    /// 前台检查点（取代旧 check，BACKGROUND-RESILIENCE 层 1）：代次不对／任务被取消
    /// 才抛错；App 不在前台时**原地驻停**等回前台（进程被系统冻结时本循环一并冻结、
    /// 解冻后继续判断），不再把任务判死。回前台后瞬时连败清零——挂起期间在途调用
    /// 冒出的失败多半是挂起伪影，不计账；在途步骤按「可重入」处理：醒来后的下一轮
    /// 迭代会重新取快照、重新决策，不接着跑挂起前那半步。
    private func checkpoint(_ token: UUID) async throws {
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
        guard !active else { return }
        while !active {
            try await Task.sleep(for: .milliseconds(300))
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
        }
        transientStreak = 0
    }

    /// 瞬时错误分类（问题 2）：只有这四类算「可以自动重试」；其余错误（有具体口径
    /// 的 MikaError、安全类拦截、模型动作无法识别、「页面结构已变」等）一律不在此列，
    /// 照旧判失败，绝不被重试逻辑吞掉或绕过安全门。
    private enum TransientKind { case javaScript, webContentProcess, pageLoad, modelNetwork }
    private static func transientKind(of error: Error) -> TransientKind? {
        let ns = error as NSError
        if ns.domain == "WKErrorDomain" {
            if ns.code == 4 { return .javaScript }        // JavaScriptExceptionOccurred
            if ns.code == 3 { return .webContentProcess } // WebContentProcessTerminated
            return nil
        }
        if let mika = error as? MikaError {
            let message = mika.message
            if message.hasPrefix("网页加载超时") || message.hasPrefix("网页加载失败") { return .pageLoad }
            if message.hasPrefix("无法抽取页面状态") || message.hasPrefix("页面状态解析失败") { return .javaScript }
            if message.hasPrefix("无法连接模型服务") { return .modelNetwork }
        }
        return nil
    }
    /// 对话里呈现的人话重试说明（裸英文错误原文不进对话，只进诊断，见下）。
    private static func transientRetryNote(kind: TransientKind, streak: Int) -> String {
        let base: String
        switch kind {
        case .javaScript: base = "页面脚本出错"
        case .webContentProcess: base = "网页进程被系统中断"
        case .pageLoad: base = "页面加载不稳定"
        case .modelNetwork: base = "模型连接不稳定"
        }
        return "\(base)，已自动重试（第 \(streak) 次）"
    }
    /// 连败到门槛时的失败文案：人话＋出路，原文另存诊断。
    private static func transientFailureMessage(kind: TransientKind, error: Error) -> String {
        switch kind {
        case .javaScript, .webContentProcess:
            return "页面反复出错：已自动重试 \(maxTransientStreak) 次仍不稳定，任务停下。错误原文已存入诊断（设置 → 崩溃报告），页面恢复后点「继续」可接着跑"
        case .pageLoad:
            return "页面加载反复失败：已自动重试 \(maxTransientStreak) 次（含重载页面）仍不稳定，任务停下。错误原文已存入诊断（设置 → 崩溃报告），网络恢复后点「继续」可接着跑"
        case .modelNetwork:
            return "模型连接反复失败：已自动重试 \(maxTransientStreak) 次。\((error as? MikaError)?.message ?? error.localizedDescription)"
        }
    }
    /// 瞬时错误留证：与 WebController 的操作失败快照同目录、同信封格式，诊断页
    /// （设置 → 崩溃报告）可见；裸错误原文只落在这里，不作对话标题展示。
    private func writeTransientDiagnostic(kind: TransientKind, error: Error, streak: Int) {
        let ns = error as NSError
        writeDiagnostic(types: ["引擎瞬时错误"], payload: ["kind": "agent-transient-error", "transientKind": String(describing: kind),
                                                           "streak": streak, "domain": ns.domain, "code": ns.code,
                                                           "message": error.localizedDescription,
                                                           "goal": goal, "stepsRecorded": steps.count])
    }
    private func writeDiagnostic(types: [String], payload: [String: Any]) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MikaWeb/Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID(), formatter = ISO8601DateFormatter(), now = Date()
        let envelope: [String: Any] = ["schemaVersion": 1, "id": id.uuidString, "receivedAt": formatter.string(from: now), "types": types, "payload": payload]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]) else { return }
        let name = formatter.string(from: now).replacingOccurrences(of: ":", with: "-") + "-" + id.uuidString + ".json"
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private func appendStep(_ action: String, _ reason: String) {
        stepSeq += 1
        steps.append(AgentStep(id: stepSeq, action: action, reason: reason))
        persistSnapshot()
        syncContinuedProgress()
    }
    private func record(_ action: AgentAction, suffix: String = "") { appendStep(action.action, action.reason + suffix) }

    // MARK: - 后台韧性（BACKGROUND-RESILIENCE-2026-11-02.md；层 1 驻停/续跑在 checkpoint）

    /// 任务期防锁屏（层 4）：会话活跃且设置开启时禁用自动锁屏，会话终结即恢复。
    private func applyIdleTimerPolicy() {
        UIApplication.shared.isIdleTimerDisabled = sessionActive && settings.keepScreenAwakeDuringTask
    }

    /// 后台宽限（层 2）：进后台时申请一段系统时间，让在途的那一步（模型请求／JS
    /// 评估）有机会收尾；到期回调里只落盘与释放——循环本体的驻停由 checkpoint
    /// 负责。回前台／会话终结时主动释放，避免断言泄漏。
    private func beginBackgroundGrace() {
        guard backgroundGraceID == .invalid else { return }
        backgroundGraceID = UIApplication.shared.beginBackgroundTask(withName: "MikaWebAgentStep") { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.persistSnapshot()
                self.endBackgroundGrace()
            }
        }
    }
    private func endBackgroundGrace() {
        guard backgroundGraceID != .invalid else { return }
        let id = backgroundGraceID
        backgroundGraceID = .invalid
        UIApplication.shared.endBackgroundTask(id)
    }

    /// iOS 26 持续处理（层 3，尽力而为）：会话运行期向系统提交一次 continued
    /// processing——iOS 26 对该任务类型开了**动态注册**的官方例外（不必在启动期
    /// 注册，用户表达意图时注册即可），系统据此在切后台后继续给执行时间，并在
    /// 灵动岛／锁屏显示标题与进度。是否授予、给多久由系统决定：提交失败或未被
    /// 唤起只记诊断，层 1＋2 的驻停/续跑不依赖它。
    private func submitContinuedProcessingIfPossible() {
        guard #available(iOS 26.0, *), sessionActive, !goal.isEmpty else { return }
        guard continuedBox.liveIdentifier == nil else { return }
        let identifier = "com.jigaoyi.mikaweb.agent.\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] bgTask in
            guard let task = bgTask as? BGContinuedProcessingTask else { bgTask.setTaskCompleted(success: false); return }
            Task { @MainActor [weak self] in self?.adoptContinuedTask(task, identifier: identifier) }
        }
        guard registered else { return }
        let subtitleText = String(goal.prefix(40))
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "Mika Web 正在执行任务", subtitle: subtitleText.isEmpty ? "网页任务" : subtitleText)
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
            continuedBox.liveIdentifier = identifier
            continuedBox.taskObject = nil
            continuedBox.completed = false
        } catch {
            writeDiagnostic(types: ["持续处理"], payload: ["kind": "continued-processing", "event": "submit-failed", "message": error.localizedDescription, "goal": goal])
        }
    }

    /// 系统唤起持续处理任务时的收编：仅当标识与当前活跃会话对得上才接管并开始
    /// 报进度；冷启动被拉起、或会话已结束时没有可续的活，如实结束（用户侧的恢复
    /// 走冷启动快照路径，不在这里硬造一个没有页面状态的会话）。
    @available(iOS 26.0, *)
    private func adoptContinuedTask(_ task: BGContinuedProcessingTask, identifier: String) {
        guard continuedBox.liveIdentifier == identifier, sessionActive else {
            task.setTaskCompleted(success: false)
            return
        }
        continuedBox.taskObject = task
        continuedBox.completed = false
        task.progress.totalUnitCount = Int64(max(limit, 1))
        task.progress.completedUnitCount = Int64(steps.count)
        task.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in self?.continuedTaskExpired(identifier: identifier) }
        }
    }

    /// 持续处理被系统回收：落盘并把系统任务如实收口（success=false 指「未随系统
    /// 任务完成」，不是会话失败）——引擎会话不判死，循环按层 1 驻停、回前台续跑；
    /// 下次进后台会重新提交。
    private func continuedTaskExpired(identifier: String) {
        guard continuedBox.liveIdentifier == identifier else { return }
        persistSnapshot()
        if #available(iOS 26.0, *), let task = continuedBox.taskObject as? BGContinuedProcessingTask, !continuedBox.completed {
            continuedBox.completed = true
            task.setTaskCompleted(success: false)
        }
        continuedBox.taskObject = nil
        continuedBox.liveIdentifier = nil
    }

    /// 会话终结时收口持续处理：系统任务已被唤起则按成败完成它；还没被唤起的，
    /// 清掉标识即可——它日后若被系统唤起，收编处会因会话已结束而如实结束。
    private func completeContinuedProcessing(success: Bool) {
        guard continuedBox.liveIdentifier != nil else { return }
        if #available(iOS 26.0, *), let task = continuedBox.taskObject as? BGContinuedProcessingTask, !continuedBox.completed {
            continuedBox.completed = true
            task.setTaskCompleted(success: success)
        }
        continuedBox.taskObject = nil
        continuedBox.liveIdentifier = nil
    }

    /// 持续处理的进度与主循环同源：步数即进度（total＝本任务步数上限）。
    private func syncContinuedProgress() {
        guard #available(iOS 26.0, *), let task = continuedBox.taskObject as? BGContinuedProcessingTask else { return }
        task.progress.totalUnitCount = Int64(max(limit, 1))
        task.progress.completedUnitCount = Int64(steps.count)
    }

    // MARK: - 会话落盘与冷启动恢复（层 1 的持久化一半）

    private struct SessionSnapshot: Codable {
        struct StepDTO: Codable { let id: Int; let action: String; let reason: String }
        struct WaitingDTO: Codable { let kind: String; let id: UUID; let text: String }
        var version = 2
        var savedAt: Date
        var goal: String
        var limit: Int
        var stepSeq: Int
        var steps: [StepDTO]
        var statusKind: String // running / paused / waitingConfirm / waitingManual
        var statusText: String // paused / waitingManual 的说明文案
        var pendingActionJSON: String? // AgentAction 的 JSON（其 Decodable 容忍缺省字段）
        var pendingElement: PageElement?
        var pendingURL: String?
        var waiting: WaitingDTO?
        var answersJSON: String // [QuestionAnswer] 的 JSON
        var skillNames: [String]? // 已加载 playbook 名（正文恢复时按名从 SkillStore 重读；可选字段，旧快照无此键照常解码）
        // v2 起（RESUME-CONTEXT-FIX）：工作现场——对话任务标识（恢复后沿用原
        // taskID，对话层的持久化去重才跨进程成立）与全部标签页地址＋当前页／
        // 执行页下标（页面本身不可序列化，只存地址，恢复时重新导航）。全部
        // 可选：v1 旧快照无此三键照常解码、恢复时降级为「无页面记录」口径。
        var taskID: UUID?
        var tabURLs: [String]?
        var activeTabIndex: Int?
        var executionTabIndex: Int?
    }
    private static let snapshotKey = "agentSessionSnapshot.v1"

    private func currentStatusKind() -> (kind: String, text: String)? {
        switch status {
        case .running: return ("running", "")
        case .paused(let text): return ("paused", text)
        case .waitingConfirm: return ("waitingConfirm", "")
        case .waitingManual(let text): return ("waitingManual", text)
        default: return nil
        }
    }

    /// 会话状态落盘：目标、步数上限、轨迹、待确认动作、等待输入、问答上下文。
    /// 只记非终结状态（终结与新任务开始时清除，见 stop／终结路径）。进程在后台
    /// 被系统回收时，下次冷启动靠它把会话恢复到「可继续」，而不是凭空消失。
    private func persistSnapshot() {
        guard let (kind, text) = currentStatusKind(), !goal.isEmpty else { return }
        var pendingJSON: String?
        var pendingElement: PageElement?
        var pendingURL: String?
        if let pending {
            let dict: [String: Any] = ["action": pending.0.action, "text": pending.0.text, "url": pending.0.url,
                                       "direction": pending.0.direction, "reason": pending.0.reason,
                                       "summary": pending.0.summary, "question": pending.0.question,
                                       "index": pending.0.index, "seconds": pending.0.seconds]
            if let data = try? JSONSerialization.data(withJSONObject: dict) { pendingJSON = String(decoding: data, as: UTF8.self) }
            pendingElement = pending.1
            pendingURL = pending.2
        }
        var waitingDTO: SessionSnapshot.WaitingDTO?
        if let waitingInput {
            switch waitingInput {
            case .question(let id, let text): waitingDTO = SessionSnapshot.WaitingDTO(kind: "question", id: id, text: text)
            case .manual(let id, let text): waitingDTO = SessionSnapshot.WaitingDTO(kind: "manual", id: id, text: text)
            }
        }
        let answersData = (try? JSONEncoder().encode(answerContext)) ?? Data("[]".utf8)
        // 工作现场（RESUME-CONTEXT-FIX）：标签地址跟会话一起落盘。若本会话是
        // 恢复来的、现场还没被续跑消费（标签仍是冷启动起始页），写下的应是
        // 暂存的中断现场而不是起始页——否则一次后台落盘（setForeground 的
        // persistSnapshot）就会把原地址冲掉，恢复便无从谈起。
        let scene: (urls: [String], activeIndex: Int, executionIndex: Int?)
        if let pending = pendingTabScene { scene = pending } else { scene = web.tabScene() }
        let snapshot = SessionSnapshot(savedAt: Date(), goal: goal, limit: limit, stepSeq: stepSeq,
                                       steps: steps.map { SessionSnapshot.StepDTO(id: $0.id, action: $0.action, reason: $0.reason) },
                                       statusKind: kind, statusText: text,
                                       pendingActionJSON: pendingJSON, pendingElement: pendingElement, pendingURL: pendingURL,
                                       waiting: waitingDTO, answersJSON: String(decoding: answersData, as: UTF8.self),
                                       skillNames: loadedSkillNames,
                                       taskID: conversationTaskID,
                                       tabURLs: scene.urls, activeTabIndex: scene.activeIndex, executionTabIndex: scene.executionIndex)
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.snapshotKey)
        }
    }

    private func clearSnapshot() { UserDefaults.standard.removeObject(forKey: Self.snapshotKey) }

    /// 冷启动恢复：只认 24 小时内的非终结快照。恢复后停在「可继续」一侧——运行中
    /// 变已暂停待继续；等待确认／手输原样恢复等待（确认时会重新复核目标，页面已
    /// 变则安全失败，不误执行）。目标、步骤、问答、playbook 在此全量恢复；
    /// 浏览器标签现场（v2 起有地址记录）先暂存，第一次续跑时由
    /// applyPendingTabRestore 重建标签并导航回中断页面（RESUME-CONTEXT-FIX；
    /// 此前不存地址，续跑只能落在起始页、模型无从知道原网址，是「上下文
    /// 记忆丢失」的断点之一）。对话任务标识沿用快照里的原 taskID（v2 起），
    /// 对话层据此识别「同一任务的恢复」，不重复回放任务与步流（CRASH-1031
    /// 的持久化去重跨进程成立的前提）。
    private func restoreSnapshotIfNeeded() {
        guard let data = UserDefaults.standard.data(forKey: Self.snapshotKey),
              let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data),
              Date().timeIntervalSince(snapshot.savedAt) < 24 * 3600, !snapshot.goal.isEmpty else { return }
        goal = snapshot.goal
        taskText = snapshot.goal
        limit = snapshot.limit
        stepSeq = snapshot.stepSeq
        steps = snapshot.steps.map { AgentStep(id: $0.id, action: $0.action, reason: $0.reason) }
        if let answers = try? JSONDecoder().decode([QuestionAnswer].self, from: Data(snapshot.answersJSON.utf8)) { answerContext = answers }
        if let names = snapshot.skillNames {
            for name in names {
                if let skill = SkillStore.shared.skill(named: name), !loadedSkillNames.contains(skill.name) {
                    loadedSkillNames.append(skill.name)
                    loadedSkillBodies += "\n【playbook：\(skill.name)】\n\(skill.body)"
                }
            }
        }
        if let waiting = snapshot.waiting {
            waitingInput = waiting.kind == "question" ? .question(id: waiting.id, text: waiting.text) : .manual(id: waiting.id, text: waiting.text)
        }
        conversationTaskID = snapshot.taskID ?? UUID()
        restoredSession = true
        didApplyTabRestore = false
        if let urls = snapshot.tabURLs {
            pendingTabScene = (urls: urls, activeIndex: snapshot.activeTabIndex ?? 0, executionIndex: snapshot.executionTabIndex)
        }
        switch snapshot.statusKind {
        case "waitingConfirm":
            if let json = snapshot.pendingActionJSON,
               let action = try? JSONDecoder().decode(AgentAction.self, from: Data(json.utf8)),
               let element = snapshot.pendingElement, let url = snapshot.pendingURL {
                pending = (action, element, url, 0)
                status = .waitingConfirm(action)
            } else {
                status = .paused("上次任务在 App 退出时中断，点继续可接着跑")
            }
        case "waitingManual":
            status = .waitingManual(snapshot.statusText)
        default:
            status = .paused("上次任务在 App 退出时中断，点继续可接着跑")
        }
    }

    // MARK: - 自检四：进程级中断模拟（RESUME-CONTEXT-FIX）

    /// 模拟「任务执行中进程被杀」：先按现状落盘快照，然后把引擎的全部内存
    /// 态与浏览器标签现场打回冷启动原样（工作任务代次作废、标签只剩起始页），
    /// 再只调用冷启动恢复路径——恢复出来的目标／步数／待重建现场全部来自
    /// 落盘数据，与真机强退重开走同一条路。整段同步执行：工作任务被代次
    /// 作废后只会在后续回合按代次守卫自行退出，不会与恢复交错写状态。
    /// 返回人类可读的模拟与恢复报告（自检页写进对话作自检记录）。
    func simulateInterruptionForResumeTest() -> String {
        let beforeGoal = goal
        let beforeSteps = steps.count
        let beforeScene = web.tabScene()
        let beforeExecutionURL: String = {
            if let index = beforeScene.executionIndex, beforeScene.urls.indices.contains(index) { return beforeScene.urls[index] }
            return beforeScene.urls.indices.contains(beforeScene.activeIndex) ? beforeScene.urls[beforeScene.activeIndex] : ""
        }()
        persistSnapshot()
        // —— 内存态清零（等同进程死亡后冷启动前的状态） ——
        generation = UUID(); worker?.cancel(); worker = nil; pending = nil
        goal = ""; taskText = ""; steps = []; stepSeq = 0; answerContext = []; waitingInput = nil
        lastStaleKey = nil; staleStreak = 0; transientStreak = 0
        loopDetector.reset(); pendingLoopHint = nil; loadedSkillNames = []; loadedSkillBodies = ""
        conversationTaskID = nil; sessionActive = false; status = .idle
        pendingTabScene = nil; restoredSession = false; didApplyTabRestore = false; resumeNote = nil
        web.resetTabsToStartPage()
        // —— 仅凭落盘恢复 ——
        restoreSnapshotIfNeeded()
        let restored = !goal.isEmpty
        let pendingTabs = pendingTabScene?.urls.filter { !$0.isEmpty }.count ?? 0
        return """
        中断模拟完成：中断前目标「\(beforeGoal)」，已记录 \(beforeSteps) 步，执行页 \(beforeExecutionURL.isEmpty ? "（起始页）" : beforeExecutionURL)。\
        内存态与标签现场已清零并仅凭落盘快照恢复：\(restored ? "目标已恢复为「\(goal)」，步数 \(steps.count) 步在位，待重建标签 \(pendingTabScene?.urls.count ?? 0) 个（其中带地址 \(pendingTabs) 个）" : "未恢复出会话（快照缺失或已过期）")。\
        现在点「继续」：应先回到中断前页面、带着原目标接着完成剩余步骤，不得向你索要网址或进度。
        """
    }
}
