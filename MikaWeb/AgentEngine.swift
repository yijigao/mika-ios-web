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
    /// 成果台账（OUTCOME-LEDGER，结构与分类见 OutcomeLedger.swift）：已真实
    /// 执行并留痕的提交类关键动作。App 会话级——start() 不清（用户追问在
    /// App 里就是一条新任务，台账必须跨得过任务界），自有持久化＋随会话
    /// 快照双写，进程被杀重开仍在；24 小时过期、最多 20 条（见 prunedOutcomes）。
    private(set) var outcomeLedger: [OutcomeRecord] = []
    /// 软门已提醒过的台账条目 id（本进程内）：同一条目只拦第一次重复提交；
    /// 模型收到提醒后仍坚持、或用户在新任务里明确要求重发时放行，由落记
    /// 路径回记为再次提交。进程重启后集合清空，会再提醒一次（软门口径）。
    private var outcomeGateFired: Set<UUID> = []
    /// 重复提交被拦下时给模型的提醒：随下一次模型调用注入后清除（步流里
    /// 另有一条 outcome 步，用户可见）。
    private var pendingOutcomeHint: String?
    /// 本轮刚落记／更新的台账说明：由 launch 在记完本步动作后补一条 outcome
    /// 步进轨迹，保证步序是「动作 → 台账」而不是反过来。
    private var pendingOutcomeStep: String?
    /// 本任务最近的打字内容（提交指纹的来源）：只留内存、最近 5 条；优先取
    /// 编辑器／textarea 的输入，回退任意字段的最近输入。start() 清空——新
    /// 任务的提交若无打字记录，软门按页面＋按钮标识匹配（追问场景正是此路）。
    private var recentTyped: [(text: String, isEditor: Bool)] = []
    /// 结构化任务状态卡（H1，结构与口径见 TaskStateCard.swift）：程序维护
    /// 的事实账，随快照持久化、每轮 prompt 注入。关键状态由程序在确定事件
    /// 点更新（开始/record 记账/用户答复/用户跳过/等待状态派生），不依赖
    /// 模型散文摘要；历史折叠再紧，卡片也不参与折叠。
    private(set) var stateCard = TaskStateCard()
    /// 确定性折叠（H1）：步数超过 foldStepThreshold 后，旧步骤在 prompt 里
    /// 折叠为单行流水账（最近若干步保留全量）；原始 steps 记录 append-only
    /// 不动，折叠只发生在组装。级别：1＝留最近 6 步全量、2＝留 3 步、
    /// 3＝留 1 步且行更短。forcedFoldLevel 由预算升级/上下文超限重试抬升，
    /// 会话内只升不降（保守侧）。
    private var forcedFoldLevel = 0
    static let foldStepThreshold = 12
    /// 组装 prompt 的字符预算（H1）：保守默认值——组装后超此值先逐级加大
    /// 折叠再发送；它管的是「我们发出去的体量有界」，不是某个模型的窗口
    /// 断言（各通道窗口不同，真超限由受控重试兜底，见 isContextOverflowError）。
    static let promptCharBudget = 16000
    /// 上下文超限受控重试是否已用（H1）：每轮任务运行只许一次——命中超限
    /// 错误时把折叠升到最紧再发，绝不原样重发全量；再超限则照常判失败，
    /// 不循环（防 Issue #181 式「全量重发＋重试」死循环）。进程恢复后随
    /// 内存态重置（恢复出的步数已多、自动折叠级别本就更高，不构成循环）。
    private var contextRetryUsed = false
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
        loadOutcomeLedger()
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
        // 状态卡与折叠/重试状态随新任务重置（台账不清，见下方既有口径）
        stateCard = TaskStateCard(goal: goal); forcedFoldLevel = 0; contextRetryUsed = false
        // 成果台账不清（跨任务存活，见 outcomeLedger 声明处）；只清本任务的
        // 打字记录与未消费的软门提醒——新任务的提交指纹从本任务的输入重算
        recentTyped = []; pendingOutcomeHint = nil; pendingOutcomeStep = nil
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
        // 用户答复是程序可确定的关键事实：钉进状态卡 pinnedFacts，折叠与
        // 摘要都动不了它（H1）——长任务后段模型仍能看到用户早先的明确口径
        stateCard.pinFact("用户对「\(question)」的答复：\(answer)")
        waitingInput = nil
        resume()
        return .accepted
    }
    func confirm(execute: Bool) {
        guard active, let saved = pending else { return }
        pending = nil
        if !execute {
            appendStep("skip", "用户跳过：\(saved.0.reason)")
            // 用户明确跳过是关键事实：钉进状态卡，后续轮次不得再提议同一步
            stateCard.pinFact("用户决定跳过：\(saved.0.reason)")
            launch(); return
        }
        launch(confirmed: saved)
    }
    private func launch(confirmed: (AgentAction, PageElement, String, Int)? = nil) {
        // 恢复会话的现场重建在此兜底：resume() 已先行调用过则守卫使其为空操作；
        // 等待确认恢复后直接走 confirm() 的路径不经 resume()，也要先把标签带回
        // 中断页面，runConfirmed 的网址／目标复核才有机会在原页面上通过（复核
        // 本身一字不改，页面对不上仍安全失败，绝不误执行）。
        applyPendingTabRestore()
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
                        let answers = String(decoding: try JSONEncoder().encode(answerContext), as: UTF8.self)
                        // 一次性提示在本轮组装前消费（组装可能因预算多遍重建，
                        // 消费动作不能放进组装函数里重复执行）
                        let loopHint = pendingLoopHint; pendingLoopHint = nil
                        let outcomeHint = pendingOutcomeHint; pendingOutcomeHint = nil
                        // prompt 组装（H1）：任务→状态卡→恢复说明→成果台账→
                        // 历史（确定性折叠）→问答→playbook→提示→当前页面；
                        // 体量由 promptCharBudget 约束，超预算逐级加大折叠
                        // （见 assemblePrompt）。各注入段的口径注释见组装函数。
                        let prompt = assemblePrompt(pageJSON: json, answersJSON: answers, loopHint: loopHint, outcomeHint: outcomeHint)
                        let action: AgentAction
                        if settings.modelSource == .chatGPT {
                            action = try await ModelClient().nextViaChatGPT(auth: settings.chatGPTAuth, model: settings.chatGPTModel, prompt: prompt, skillCatalog: SkillStore.shared.catalogFragment())
                        } else {
                            action = try await ModelClient().next(baseURL: settings.baseURL, model: settings.model, key: Keychain.read(), prompt: prompt, skillCatalog: SkillStore.shared.catalogFragment())
                        }
                        try await checkpoint(token)
                        if action.action == "done" {
                            // 完成总结是模型回读页面后写下的核实结论：钉进台账
                            // 里仍待核查的条目，后续追问轮次据此守定力口径
                            markOutcomesVerified(summary: action.summary)
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
                                flushPendingOutcomeStep()
                                loopFingerprint = LoopDetector.fingerprint(action: action.action, target: targetKey, outcome: "executed")
                                try await Task.sleep(for: .milliseconds(500))
                            case .duplicateBlocked:
                                // 重复提交被软门拦下：提醒步已在 pendingOutcomeStep
                                // 里、模型提醒已置位待下一轮注入；本轮按已消费处理，
                                // 循环指纹单列 outcome，不与原动作混记
                                flushPendingOutcomeStep()
                                loopFingerprint = LoopDetector.fingerprint(action: action.action, target: targetKey, outcome: "duplicate-blocked")
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
                            let target = action.action == "navigate" ? action.url : (action.action == "scroll" ? action.direction : (action.action == "set_site_mode" ? action.mode : "\(Int(action.seconds))"))
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
                                appendStep("loop", "循环严重提醒：同一动作已重复 \(verdict.count) 次，下一步提示已下达最后换路指令（无路可换时须按求助口径交代已试路径），再重复将自动停下")
                                pendingLoopHint = "严重警告（最后一次换路机会）：你已对同一目标重复执行同一动作 \(verdict.count) 次，页面结果始终没有变化。若下一步仍原样重复，任务将自动停下交用户决定。必须换路：换入口／换目标，或用 set_site_mode 换站点模式，或按页面规则／说明里写明的官方路径 navigate 到同功能的电脑版站点／官方后台。若确实已无替代路径，才可以 ask_user 求助——并且必须先交代已试过的每条路径与各自的卡点，再提出需要用户做的那一步。求助是最后手段，不是默认出口。"
                            case .warning:
                                appendStep("loop", "循环提醒：同一动作已重复 \(verdict.count) 次且结果未变，下一步提示已升级为必须换路指令（禁止原样重试）")
                                pendingLoopHint = "警告（必须换路）：你已对同一目标重复执行同一动作 \(verdict.count) 次，页面结果没有变化。下一步禁止原样重试，必须换一种做法：换入口／换目标，或用 set_site_mode 换站点模式，或先读页面规则／说明、按其中写明的官方路径 navigate 到同功能的电脑版站点／官方后台。还没试过至少两条替代路径之前，不要 ask_user 求助。"
                            case .none:
                                break
                            }
                        }
                        // 一整轮迭代走通：瞬时连败清零
                        transientStreak = 0
                    } catch {
                        guard token == generation else { return }
                        if error is CancellationError { throw error }
                        if Self.isContextOverflowError(error), !contextRetryUsed {
                            // 上下文超限受控重试（H1）：只许一次，且重试必须
                            // 是「缩小后」的——折叠升到最紧（forcedFoldLevel
                            // =3），下一轮组装自动带上；绝不原样重发全量历史
                            // （Issue #181 式死循环正是全量重发＋无限重试）。
                            // 本次重试步照常经 appendStep 计入步数预算，退避
                            // 与瞬时错误同档（600ms），不新造循环。
                            contextRetryUsed = true
                            forcedFoldLevel = 3
                            writeDiagnostic(types: ["上下文超限"], payload: ["kind": "context-overflow-retry", "message": error.localizedDescription, "goal": goal, "stepsRecorded": steps.count])
                            appendStep("retry", "模型报告上下文超限：已把旧步骤折叠到最紧（状态卡与最近步骤保留）后重试一次，不会重发全量历史")
                            if !active { try await checkpoint(token) }
                            try await Task.sleep(for: .milliseconds(600))
                        } else if let kind = Self.transientKind(of: error) {
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
                        } else {
                            throw error
                        }
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
            // 经用户确认执行的提交类动作同样落台账（确认本身即用户的明确
            // 指示，此路不设软门；台账记下后防的是后续轮次的无意识重复）
            if let note = noteSubmissionIfNeeded(action: saved.0, element: target, pageURL: saved.2) {
                appendStep("outcome", note)
            }
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
    /// 已记策略切换步、交模型按新快照重新判断；waiting＝已进入确认／手输等待（状态已置位）；
    /// duplicateBlocked＝重复提交被成果台账软门拦下未执行，提醒步与模型提醒均已置位。
    private enum TargetedOutcome { case executed, strategySwitch, waiting, duplicateBlocked }

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
            // 重复提交软门（OUTCOME-LEDGER）：只拦自主路径的 click——确认路径
            // （runConfirmed）是用户亲手确认，不经此门；拦下后本轮不执行，
            // 提醒步与下一轮注入提醒都已置位，模型应改走列表核查路径
            if action.action == "click", let block = duplicateSubmissionBlock(element: target, pageURL: snapshot.url) {
                pendingOutcomeStep = block.step
                pendingOutcomeHint = block.hint
                return .duplicateBlocked
            }
            do {
                try await checkpoint(token)
                executionSerial += 1
                try await web.execute(action, expected: target)
                try await checkpoint(token)
                lastStaleKey = nil
                staleStreak = 0
                // 台账记账点：打字成功先记内容（提交指纹来源），提交类点击
                // 成功再落台账条目（说明经 pendingOutcomeStep 由调用方补步）
                if action.action == "type" { noteTypedContent(action: action, element: target) }
                if action.action == "click" {
                    pendingOutcomeStep = noteSubmissionIfNeeded(action: action, element: target, pageURL: snapshot.url)
                }
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
    private func record(_ action: AgentAction, suffix: String = "") {
        appendStep(action.action, action.reason + suffix)
        // 状态卡的已完成里程碑在记账点同步（程序事实，不经模型转述，H1）
        stateCard.addCompleted("\(action.action)：\(action.reason)")
    }

    // MARK: - 成果台账（OUTCOME-LEDGER-2026-11-02.md）

    private static let outcomeLedgerKey = "outcomeLedger.v1"
    private static let outcomeTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    private static func outcomeTime(_ date: Date) -> String { outcomeTimeFormatter.string(from: date) }

    /// 台账封顶口径：只留 24 小时内的最近 20 条——定力要守的是「刚提交过
    /// 的别再交一遍」，过期与溢出的老条目留着只会污染注入。
    private static func prunedOutcomes(_ records: [OutcomeRecord]) -> [OutcomeRecord] {
        let fresh = records.filter { Date().timeIntervalSince($0.recordedAt) < 24 * 3600 }
        return Array(fresh.suffix(20))
    }
    private func loadOutcomeLedger() {
        guard let data = UserDefaults.standard.data(forKey: Self.outcomeLedgerKey),
              let records = try? JSONDecoder().decode([OutcomeRecord].self, from: data) else { return }
        outcomeLedger = Self.prunedOutcomes(records)
    }
    private func saveOutcomeLedger() {
        outcomeLedger = Self.prunedOutcomes(outcomeLedger)
        if let data = try? JSONEncoder().encode(outcomeLedger) {
            UserDefaults.standard.set(data, forKey: Self.outcomeLedgerKey)
        }
    }

    /// 条目同一性：双方都有正文指纹时按指纹＋主机比（同内容同站点才算同一
    /// 提交，换个站点发同文案不拦）；任一侧无指纹时退到页面地址＋按钮文案
    /// （追问场景：新任务里没重打正文，指纹为空，靠这一路认出「还是这个
    /// 编辑器页的发布按钮」）。
    private static func outcomeMatches(_ record: OutcomeRecord, fingerprint: String, host: String, pageURL: String, label: String) -> Bool {
        if !fingerprint.isEmpty, !record.contentFingerprint.isEmpty {
            return record.contentFingerprint == fingerprint && record.host == host
        }
        return record.pageURL == pageURL && record.elementLabel == label
    }
    private static func elementLabel(of element: PageElement) -> String {
        if !element.text.isEmpty { return element.text }
        if !element.ariaLabel.isEmpty { return element.ariaLabel }
        return "提交按钮"
    }
    /// 当前待提交内容的指纹来源：本任务最近一次编辑器／textarea 输入；
    /// 没有编辑器输入时回退到最近一次任意打字；都没有则空指纹。
    private func currentContentFingerprint() -> (hash: String, prefix: String) {
        let source = recentTyped.last(where: { $0.isEditor })?.text ?? recentTyped.last?.text ?? ""
        return SubmissionClassifier.contentFingerprint(of: source)
    }
    private func noteTypedContent(action: AgentAction, element: PageElement) {
        guard !action.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let isEditor = element.editable || element.tag == "textarea"
        recentTyped.append((text: action.text, isEditor: isEditor))
        if recentTyped.count > 5 { recentTyped.removeFirst(recentTyped.count - 5) }
    }

    /// 提交类点击真正执行成功后的落记（runTargeted 自主路径与 runConfirmed
    /// 确认路径共用）：返回要补进轨迹的 outcome 步文案，非提交类返回 nil。
    /// 同一性命中已有条目时不重复建条——更新其时间与状态并注明再次提交
    /// （软门已提醒后坚持执行、或经用户确认执行的重发走的正是这条）。
    private func noteSubmissionIfNeeded(action: AgentAction, element: PageElement, pageURL: String) -> String? {
        guard action.action == "click", SubmissionClassifier.isSubmissionElement(element) else { return nil }
        let (hash, prefix) = currentContentFingerprint()
        let host = URL(string: pageURL)?.host ?? ""
        let label = Self.elementLabel(of: element)
        if let index = outcomeLedger.firstIndex(where: { Self.outcomeMatches($0, fingerprint: hash, host: host, pageURL: pageURL, label: label) }) {
            outcomeLedger[index].recordedAt = Date()
            outcomeLedger[index].resubmittedAt = Date()
            outcomeLedger[index].statusNote = "再次提交（经提醒或用户确认后执行），待核查"
            saveOutcomeLedger()
            return "成果台账更新：同一内容已再次提交（「\(label)」），条目时间与状态已更新——后续仍按已提交内容对待，不得无意识再发"
        }
        let record = OutcomeRecord(id: UUID(), pageURL: pageURL, host: host, elementLabel: label,
                                    contentFingerprint: hash, contentPrefix: prefix,
                                    statusNote: "已提交（待核查）", recordedAt: Date(), resubmittedAt: nil)
        outcomeLedger.append(record)
        saveOutcomeLedger()
        let contentDesc = prefix.isEmpty ? "（正文未留指纹，按页面与按钮记账）" : "内容「\(prefix)…」"
        return "成果台账已记录：\(Self.outcomeTime(record.recordedAt)) 在 \(host.isEmpty ? "本地页面" : host) 提交了\(contentDesc)（按钮「\(label)」），状态：已提交（待核查）"
    }

    /// 重复提交软门：本次自主点击若命中台账里同一条目、且该条目本进程内
    /// 还没提醒过——拦下本次点击，返回步流文案与当轮注入提醒；已提醒过的
    /// 条目放行（模型已收到提醒仍坚持、或用户明确要求重发），执行后由
    /// noteSubmissionIfNeeded 回记为再次提交。这就是「软」：只拦第一次
    /// 无意识重复，不做硬阻断；确认路径（用户亲手点的确认）不经此门。
    private func duplicateSubmissionBlock(element: PageElement, pageURL: String) -> (step: String, hint: String)? {
        guard SubmissionClassifier.isSubmissionElement(element) else { return nil }
        let (hash, _) = currentContentFingerprint()
        let host = URL(string: pageURL)?.host ?? ""
        let label = Self.elementLabel(of: element)
        guard let record = outcomeLedger.first(where: { Self.outcomeMatches($0, fingerprint: hash, host: host, pageURL: pageURL, label: label) }),
              !outcomeGateFired.contains(record.id) else { return nil }
        outcomeGateFired.insert(record.id)
        let when = Self.outcomeTime(record.recordedAt)
        let contentDesc = record.contentPrefix.isEmpty ? "该内容" : "内容「\(record.contentPrefix)…」"
        let step = "重复提交提醒：\(contentDesc)已于 \(when) 在 \(record.host.isEmpty ? "本地页面" : record.host) 提交过（状态：\(record.statusNote)），本次重复提交已拦下未执行——先去内容列表/记录页核查现状再决定"
        let hint = "【重复提交提醒】你刚才试图再次提交的\(contentDesc)已于 \(when) 提交过，台账状态：\(record.statusNote)。本次点击已被拦下、没有执行。现在先去该站的内容列表/记录页核查这条内容的当前状态（如审核中/已发布），再决定下一步：状态正常就向用户复述核实结果，不要回编辑器凭残稿重发；只有用户明确要求重新提交时，才再次点击提交（再次点击会放行，reason 里注明系用户要求）。"
        return (step, hint)
    }

    /// 任务以 done 收口时，把台账里仍「待核查」的条目钉上模型的完成总结
    /// 作为已核实结论：总结是模型回读页面（列表核查等）后写下的，钉进
    /// 台账后每轮注入——后续追问轮次再想改口「无法确认」，先要面对自己
    /// 写进台账的这句总结（定力口径，配合系统提示「成果定力」段）。
    private func markOutcomesVerified(summary: String) {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var changed = false
        for index in outcomeLedger.indices where outcomeLedger[index].statusNote.contains("待核查") {
            outcomeLedger[index].statusNote = "已核实（完成总结）：\(String(trimmed.prefix(80)))"
            changed = true
        }
        if changed { saveOutcomeLedger() }
    }

    /// 台账注入段：逐条列出已留痕的提交，附定力硬口径。返回空串＝台账为空。
    private func outcomePromptBlock() -> String {
        let records = Self.prunedOutcomes(outcomeLedger)
        guard !records.isEmpty else { return "" }
        let lines = records.map { record in
            let content = record.contentPrefix.isEmpty ? "（正文未留指纹）" : "内容「\(record.contentPrefix)…」"
            return "· \(Self.outcomeTime(record.recordedAt)) 在 \(record.host.isEmpty ? "本地页面" : record.host) 点了「\(record.elementLabel)」提交：\(content)，状态：\(record.statusNote)"
        }
        return "【本任务已完成的关键动作】\n" + lines.joined(separator: "\n") + "\n硬性口径：以上都是已真实执行并留痕的提交，不得对同一内容重复提交/发布。需要确认现状时，先去内容列表/记录页核查该条目的状态再下结论；编辑器里残留的同文草稿不是未提交的证据（提交后保留原文是常见形态）。已核实的结论无新证据不得改口为「无法确认」；用户追问时复述台账里的状态与证据来源。"
    }

    private func flushPendingOutcomeStep() {
        if let note = pendingOutcomeStep { appendStep("outcome", note); pendingOutcomeStep = nil }
    }

    /// 自检六只读口径：台账条数与最近一条的人读摘要。
    var outcomeLedgerCount: Int { outcomeLedger.count }
    var latestOutcomeDescription: String? {
        outcomeLedger.last.map { "\($0.host.isEmpty ? "本地页面" : $0.host) · \($0.contentPrefix.isEmpty ? "（无正文指纹）" : $0.contentPrefix) · \($0.statusNote)" }
    }

    // MARK: - prompt 组装：状态卡、确定性折叠与预算（H1）

    /// 状态卡的派生字段刷新：待办/未决问题/台账引用都由当前引擎状态直接
    /// 派生（等待谁、等什么、台账里有什么），不经模型转述；已完成与关键
    /// 事实在各自事件点增量维护（见 record/submitAnswer/confirm）。在每次
    /// 组装 prompt 与每次快照落盘前调用，保证卡片与现场一致。
    private func refreshStateCard() {
        if goal.isEmpty { return }
        if stateCard.goal != goal { stateCard.goal = goal }
        switch waitingInput {
        case .question(_, let text): stateCard.openQuestions = [text]
        default: stateCard.openQuestions = []
        }
        if let pending {
            stateCard.todos = ["等待用户确认：\(pending.0.reason)"]
        } else if let waitingInput {
            switch waitingInput {
            case .question(_, _): stateCard.todos = ["等待用户回答未决问题"]
            case .manual(_, let text): stateCard.todos = ["等待用户处理：\(text)"]
            }
        } else if case .waitingManual(let text) = status {
            stateCard.todos = ["等待用户处理：\(text)"]
        } else if sessionActive {
            stateCard.todos = ["继续执行任务（已进行 \(steps.count) 步）"]
        } else {
            stateCard.todos = []
        }
        stateCard.outcomeRefs = outcomeLedger.map {
            "\(Self.outcomeTime($0.recordedAt)) \($0.host.isEmpty ? "本地页面" : $0.host)「\($0.elementLabel)」：\($0.statusNote)"
        }
        stateCard.updatedAt = Date()
    }

    /// 组装一轮 prompt：从自动级别（步数超阈值→1）或受控重试抬升的级别
    /// 起，超字符预算就逐级加大折叠，直到有界或到最紧级别 3 为止。
    private func assemblePrompt(pageJSON: String, answersJSON: String, loopHint: String?, outcomeHint: String?) -> String {
        refreshStateCard()
        var level = max(forcedFoldLevel, steps.count > Self.foldStepThreshold ? 1 : 0)
        while true {
            let prompt = buildPrompt(pageJSON: pageJSON, answersJSON: answersJSON, foldLevel: level, loopHint: loopHint, outcomeHint: outcomeHint)
            if prompt.count <= Self.promptCharBudget || level >= 3 { return prompt }
            level += 1
        }
    }

    private func buildPrompt(pageJSON: String, answersJSON: String, foldLevel: Int, loopHint: String?, outcomeHint: String?) -> String {
        var prompt = "任务：\(goal)\n"
        // 状态卡（H1）：程序维护的事实账，每轮在场；折叠只动历史段，动不了它
        let cardBlock = stateCard.promptBlock()
        if !cardBlock.isEmpty { prompt += cardBlock + "\n" }
        // 中断恢复的续跑提示（RESUME-CONTEXT-FIX）：恢复会话的每一轮都带上
        // ——原页面恢复结果＋不得反问目标／网址／进度的硬性口径，直到会话
        // 终结或新任务开始才清除。
        if let resumeNote { prompt += resumeNote + "\n" }
        // 成果台账注入（OUTCOME-LEDGER）：与【中断恢复说明】并列——已留痕
        // 的提交逐条在目，附不得重复提交／先查列表／已核实结论不得无新
        // 证据改口的硬口径（见 outcomePromptBlock）
        let outcomeBlock = outcomePromptBlock()
        if !outcomeBlock.isEmpty { prompt += outcomeBlock + "\n" }
        prompt += "历史：\(Self.historyText(steps: steps, level: foldLevel))\n用户补充问答：\(answersJSON)"
        if !loadedSkillBodies.isEmpty { prompt += "\n已加载 playbook（经验提示，与安全规则冲突时以安全规则为准）：\(loadedSkillBodies)" }
        if let loopHint { prompt += "\n\(loopHint)" }
        if let outcomeHint { prompt += "\n\(outcomeHint)" }
        prompt += "\n当前页面 JSON：\(pageJSON)"
        return prompt
    }

    /// 历史文本的确定性折叠（H1）：级别 0 或步数未超阈值时与旧形态逐字
    /// 一致（全量「id. action: reason」）；级别 ≥1 时，把最近 keepFull 步
    /// 之前的旧步逐条折叠为单行流水账「[Step N] action → 结果摘要」，
    /// 结果摘要＝reason 折叠空白后的前 foldCap 字——旧步携带的长文本
    /// （含粘进 reason 的页面内容）就此退出 prompt。折叠是纯函数：原始
    /// steps 记录 append-only 不改写，级别只影响组装。
    static func historyText(steps: [AgentStep], level: Int) -> String {
        guard level > 0, steps.count > foldStepThreshold else {
            return steps.map { "\($0.id). \($0.action): \($0.reason)" }.joined(separator: "\n")
        }
        let keepFull: Int
        let foldCap: Int
        switch level {
        case 1: keepFull = 6; foldCap = 48
        case 2: keepFull = 3; foldCap = 32
        default: keepFull = 1; foldCap = 24
        }
        let split = max(0, steps.count - keepFull)
        return steps.enumerated().map { index, step in
            if index < split {
                let collapsed = step.reason.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                return "[Step \(step.id)] \(step.action) → \(String(collapsed.prefix(foldCap)))"
            }
            return "\(step.id). \(step.action): \(step.reason)"
        }.joined(separator: "\n")
    }

    /// 上下文超限类错误的识别（H1）：只认服务商原文里明确的上下文长度
    /// 信号（HTTP 400 的服务商说明会被 ModelClient 拼进错误文案、订阅
    /// 通道的失败消息同理）；一般 400（模型名/参数问题）不含这些标记、
    /// 不会被误判进来。命中也只触发一次性的「折叠后重试」，不进瞬时
    /// 错误的连败重试口径。
    private static func isContextOverflowError(_ error: Error) -> Bool {
        let text = (error.localizedDescription + "|" + String(describing: (error as NSError).userInfo)).lowercased()
        if text.contains("context_length_exceeded") || text.contains("context length") || text.contains("maximum context") { return true }
        if text.contains("too many tokens") || text.contains("input is too long") || text.contains("prompt is too long") || text.contains("reduce the length") { return true }
        if text.contains("上下文") && (text.contains("超") || text.contains("过长") || text.contains("上限") || text.contains("长度")) { return true }
        return false
    }

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
        // OUTCOME-LEDGER 起：成果台账随快照双写——台账本体另有自有持久化，
        // 快照里的这份保证「随会话恢复的正是本会话的条目」，恢复时按 id
        // 合并去重。可选字段，此前快照无此键照常解码。
        var outcomes: [OutcomeRecord]?
        // H1 起：结构化任务状态卡与所属会话 id。可选字段，此前快照无此
        // 两键照常解码（无卡时恢复路径按步流派生一张，见 restoreSnapshotIfNeeded）。
        var stateCard: TaskStateCard?
        var sessionID: UUID?
    }
    /// 旧版快照的 UserDefaults 键（H1 前）。H1 起快照落当前会话的
    /// snapshot.json（见 persistSnapshot）；本键只作一次性迁移来源，
    /// 迁移/新落盘成功后即清除，防止旧快照被反复当作新状态恢复。
    private static let snapshotKey = "agentSessionSnapshot.v1"

    /// 读取当前会话的快照数据：优先会话文件；文件不存在时走一次性迁移
    /// ——把旧 UserDefaults 快照复制进会话文件（写成功后才清旧键，写失败
    /// 则原样返回旧数据、下次启动重试迁移，数据不丢）。
    private func loadSnapshotData() -> Data? {
        let url = SessionStore.shared.snapshotURL(for: SessionStore.shared.currentSessionID)
        if let data = try? Data(contentsOf: url) { return data }
        guard let legacy = UserDefaults.standard.data(forKey: Self.snapshotKey) else { return nil }
        do {
            try legacy.write(to: url, options: [.atomic])
            UserDefaults.standard.removeObject(forKey: Self.snapshotKey)
        } catch {
            // 迁移写入失败：不删旧键，恢复仍用旧数据，下次启动再迁
        }
        return legacy
    }

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
        refreshStateCard()
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
                                       tabURLs: scene.urls, activeTabIndex: scene.activeIndex, executionTabIndex: scene.executionIndex,
                                       outcomes: outcomeLedger,
                                       stateCard: stateCard,
                                       sessionID: SessionStore.shared.currentSessionID)
        if let data = try? JSONEncoder().encode(snapshot) {
            // H1：快照落当前会话的 snapshot.json（按会话分库）；旧键若还在
            // （迁移未发生的边角）一并清除，防止旧快照复活盖掉新状态
            let url = SessionStore.shared.snapshotURL(for: SessionStore.shared.currentSessionID)
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            if UserDefaults.standard.object(forKey: Self.snapshotKey) != nil {
                UserDefaults.standard.removeObject(forKey: Self.snapshotKey)
            }
        }
    }

    private func clearSnapshot() {
        let url = SessionStore.shared.snapshotURL(for: SessionStore.shared.currentSessionID)
        try? FileManager.default.removeItem(at: url)
        UserDefaults.standard.removeObject(forKey: Self.snapshotKey)
    }

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
        guard let data = loadSnapshotData(),
              let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data),
              Date().timeIntervalSince(snapshot.savedAt) < 24 * 3600, !snapshot.goal.isEmpty else { return }
        goal = snapshot.goal
        taskText = snapshot.goal
        limit = snapshot.limit
        stepSeq = snapshot.stepSeq
        steps = snapshot.steps.map { AgentStep(id: $0.id, action: $0.action, reason: $0.reason) }
        // 状态卡恢复（H1）：快照带卡则原样恢复（关键事实跨进程不丢）；旧
        // 快照无卡时按已恢复的步流派生一张（目标＋步流里程碑），关键事实
        // 无从派生则留空——不编造
        if let card = snapshot.stateCard {
            stateCard = card
        } else {
            var derived = TaskStateCard(goal: snapshot.goal)
            for step in snapshot.steps { derived.addCompleted("\(step.action)：\(step.reason)") }
            stateCard = derived
        }
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
        // 成果台账合并（OUTCOME-LEDGER）：快照里的条目按 id 补进台账（自有
        // 持久化已载入的那份为主，快照补其所缺），保证恢复出的会话带着
        // 中断前的已提交记录续跑，注入时与【中断恢复说明】并列出现
        if let saved = snapshot.outcomes {
            var merged = false
            for record in saved where !outcomeLedger.contains(where: { $0.id == record.id }) {
                outcomeLedger.append(record)
                merged = true
            }
            if merged { saveOutcomeLedger() }
        }
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
        // 成果台账的内存态同样清掉（打字记录／软门已提醒集合／未消费提醒），
        // 恢复后只剩快照里双写的那份台账——与真机强退重开同一口径
        recentTyped = []; outcomeGateFired = []; pendingOutcomeHint = nil; pendingOutcomeStep = nil; outcomeLedger = []
        // 状态卡与折叠/重试内存态同样清零：恢复出的卡片只能来自快照（H1）
        stateCard = TaskStateCard(); forcedFoldLevel = 0; contextRetryUsed = false
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

    // MARK: - 自检八：历史与上下文地基验证（H1）

    /// 纯函数验证（不调模型、不动现役任务状态）：①45 步合成历史在各级
    /// 折叠下的体量——全量 vs 折叠递减、最紧级别有界、首步成单行流水账、
    /// 最近一步保留全量；②状态卡——pinnedFacts 原文在卡片注入段里在场，
    /// 且它不靠历史携带（折叠文本里没有它、卡片独立注入）；③快照往返
    /// ——带状态卡的快照编解码后卡片字段不丢。返回逐项人读结论（✓/✗ 开头）。
    func verifyHistoryContextH1() -> [String] {
        var lines: [String] = []
        // 合成步流：每步 reason 带一段长文本（模拟粘进 reason 的页面内容）
        let synthetic: [AgentStep] = (1...45).map { i in
            AgentStep(id: i, action: "click", reason: "在页面定位并点击目标按钮，页面返回结果 DOMSNIPPET-\(i) " + String(repeating: "长", count: 40))
        }
        let full = Self.historyText(steps: synthetic, level: 0)
        let folded1 = Self.historyText(steps: synthetic, level: 1)
        let folded2 = Self.historyText(steps: synthetic, level: 2)
        let folded3 = Self.historyText(steps: synthetic, level: 3)
        if folded1.count < full.count && folded2.count < folded1.count && folded3.count < folded2.count {
            lines.append("✓ 确定性折叠递减：45 步历史全量 \(full.count) 字 → 级别1 \(folded1.count) → 级别2 \(folded2.count) → 级别3 \(folded3.count)")
        } else {
            lines.append("✗ 确定性折叠未递减：全量 \(full.count)、级别1 \(folded1.count)、级别2 \(folded2.count)、级别3 \(folded3.count)")
        }
        if folded3.count < 4000 {
            lines.append("✓ prompt 有界：最紧折叠下 45 步历史仅 \(folded3.count) 字（界 4000），步数再涨也只按每步一行增长")
        } else {
            lines.append("✗ prompt 未有界：最紧折叠下 45 步历史仍有 \(folded3.count) 字")
        }
        if folded1.contains("[Step 1] click →") {
            lines.append("✓ 旧步形态：首步已折叠为单行流水账「[Step 1] click → …」")
        } else {
            lines.append("✗ 旧步形态：首步未折叠为单行流水账")
        }
        if folded1.contains("45. click:") && folded1.contains("DOMSNIPPET-45") {
            lines.append("✓ 最近步全量：最后一步（45）在折叠级别 1 下仍保留全量文本")
        } else {
            lines.append("✗ 最近步全量：最后一步未保留全量")
        }
        if !folded3.contains("DOMSNIPPET-1") && !folded3.contains("DOMSNIPPET-20") {
            lines.append("✓ 原始长文本退出 prompt：最紧折叠下旧步携带的长文本片段（DOMSNIPPET-1/20）已被截断出局")
        } else {
            lines.append("✗ 原始长文本仍在最紧折叠的旧步里")
        }
        // 状态卡：关键事实钉入后，注入段原文在场；且折叠文本不携带它
        var card = TaskStateCard(goal: "自检八合成目标")
        card.pinFact("用户确认：只用主账号发布")
        card.addCompleted("navigate：示例页")
        let block = card.promptBlock()
        if block.contains("用户确认：只用主账号发布") && block.contains("关键事实（不可丢弃）") {
            lines.append("✓ 状态卡在场：pinnedFacts 原文在注入段里逐字在场，并带不可丢弃声明")
        } else {
            lines.append("✗ 状态卡注入段缺关键事实原文")
        }
        if !folded3.contains("只用主账号发布") {
            lines.append("✓ pinnedFacts 不依赖历史：折叠文本里没有它，它靠状态卡独立注入——历史折叠再紧也不丢")
        } else {
            lines.append("✗ pinnedFacts 出现在折叠文本里（口径串位）")
        }
        // 快照往返：带卡快照编解码后卡片不丢（按字段比对，避开日期浮点精度）
        let probe = SessionSnapshot(savedAt: Date(), goal: "自检八合成目标", limit: 25, stepSeq: 0, steps: [],
                                    statusKind: "paused", statusText: "", pendingActionJSON: nil, pendingElement: nil,
                                    pendingURL: nil, waiting: nil, answersJSON: "[]", skillNames: nil,
                                    taskID: nil, tabURLs: nil, activeTabIndex: nil, executionTabIndex: nil,
                                    outcomes: nil, stateCard: card, sessionID: nil)
        if let data = try? JSONEncoder().encode(probe),
           let decoded = try? JSONDecoder().decode(SessionSnapshot.self, from: data),
           let restoredCard = decoded.stateCard,
           restoredCard.goal == card.goal && restoredCard.pinnedFacts == card.pinnedFacts && restoredCard.completed == card.completed {
            lines.append("✓ 快照往返：状态卡随快照编解码不丢（目标/关键事实/已完成逐字一致）")
        } else {
            lines.append("✗ 快照往返：状态卡编解码后丢失或变形")
        }
        return lines
    }
}
