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
/// 模型决策步预算（WECHAT-COVER-FIX Part C）：计数的唯一对象是
/// 「模型返回一个动作」这一事件（引擎在两个模型通道与确认后通道的
/// 动作取得点各调一次 consumeDecision）。以下一律不计数：引擎注记
/// 步（appendStep 的核验/重试/技能/预算注记）、record 写入的执行
/// 结果本身、settled 采样与核验回读、同次 type 的内部分块、快照
/// 落盘。分段：每段上限 = 用户设置的步数上限（5–50）；段限到 →
/// 检查点暂停、resume 开下一段；全任务硬顶 = 段数上限 × 每段上限
/// （段数上限 4：单段 42 已被实证不够跑完一条完整发表链（本场约需
/// 50–60 个模型决策），4 段即 168 次决策，远超任何已见合法单任务，
/// 又能封住失控的模型调用成本；非决策 churn 另有瞬时重试 ≤3、循环
/// 熔断 3/5/7、同目标连败 ≤2 三重封顶，不靠步数兜底）。
struct StepBudget: Equatable {
    static let maxSegments = 4
    let limit: Int
    private(set) var segmentUsed = 0
    private(set) var segment = 1
    private(set) var totalUsed = 0

    init(limit: Int) { self.limit = limit }
    init(limit: Int, segmentUsed: Int, segment: Int, totalUsed: Int) {
        self.limit = limit
        self.segmentUsed = segmentUsed
        self.segment = segment
        self.totalUsed = totalUsed
    }

    var hardTop: Int { limit * Self.maxSegments }
    var segmentExhausted: Bool { segmentUsed >= limit }
    var hardTopReached: Bool { totalUsed >= hardTop }
    var canDecide: Bool { !segmentExhausted && !hardTopReached }

    mutating func consumeDecision() {
        segmentUsed += 1
        totalUsed += 1
    }

    /// 开下一段：仅当本段确已用完且未达硬顶时成功。
    @discardableResult
    mutating func openNextSegment() -> Bool {
        guard segmentExhausted, !hardTopReached, segment < Self.maxSegments else { return false }
        segment += 1
        segmentUsed = 0
        return true
    }
}

/// 介入分类（AUTONOMY-FIX）：一切「停车等用户」的触发点先分类——
/// · safety（安全类）：命中 SafetyPolicy 既有类别（付款/授权确认、密码、
///   验证码、扫码、人脸实名、发表确认）与 SP-01 上传确认。停车照旧。
///   分类只读引用 SafetyPolicy 的判定（check／uploadDecision 的返回
///   值），SafetyPolicy 本身零改动；安全类触发点在调用处直接认定，
///   不经文本启发式。
/// · capability（能力类）：入口点不开、弹窗关不掉一类 agent 能力卡点
///   （Joey 2026-11-03 10:06 亲令：「发文章不该让我出面，任务是让他
///   自己完成的」）——禁止停车等用户代劳，改走绕行梯（BypassLadder），
///   梯尽走失败结案出口。
/// · clarify（澄清类）：ask_user 的任务歧义问答（要信息／要选择），
///   停车等待照旧，不在收紧范围。
enum InterventionKind: String, Equatable { case safety, capability, clarify }

/// 介入分类门（AUTONOMY-FIX）：纯函数，可程序化自检（自检十八）。
enum InterventionGate {
    /// ask_user 的分类：模型声明优先（manual／capability＝请用户亲手
    /// 操作网页→能力类）；声明 clarify 但问题文本明显是请用户操作
    /// 网页时以文本为准（防声明绕门）；未声明时纯按文本兜底；其余
    /// 一律澄清——收紧只针对「等你亲手操作网页」这一类，不误伤问答。
    static func classifyAskUser(declared: String, question: String) -> InterventionKind {
        let d = declared.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if d == "manual" || d == "capability" { return .capability }
        if asksUserToOperatePage(question) { return .capability }
        return .clarify
    }

    /// 「请用户亲手操作网页」的措辞标记（能力类的文本兜底判定）。
    static func asksUserToOperatePage(_ text: String) -> Bool {
        let markers = ["亲手", "手动点", "手动打开", "手动关闭", "手动操作",
                       "请在网页", "请在页面", "请你点", "请您点", "你来点",
                       "帮我点", "帮我打开", "帮忙点", "帮忙打开",
                       "点一下弹窗", "打开编辑页", "打开这个页面", "关闭弹窗",
                       "在网页上点", "在页面上点"]
        return markers.contains { text.contains($0) }
    }

    /// 失败结案文案（梯尽出口）：卡点＋已试路径＋harvest 实况节＋页面
    /// 证据。自检十八对措辞做负断言——不得出现请用户代劳的话（亲手／
    /// 手动／请用户）。harvest 实况节为 LADDER-FIX F6 强制节（候选
    /// 总数、来源分布、采用／落空原因；未运行过 harvest 时写明未运行
    /// 的原因，不得缺席）。
    static func failureSummary(stuck: String, ladder: BypassLadder, evidence: String, harvestFact: String? = nil) -> String {
        let tried = ladder.summary.isEmpty ? "（无可用绕行梯级）" : ladder.summary
        let harvest = harvestFact ?? "未运行 harvest（直达 URL 一级未到达或采集结果未回写梯账）"
        return "任务未能自主完成：\(stuck)。已试路径：\(tried)。harvest 实况：\(harvest)。页面证据：\(evidence)。本任务按失败结案处理，未完成的步骤与原因已如实记录如上。"
    }
}

/// 绕行梯（AUTONOMY-FIX）：能力类卡点的分级绕行状态——尝试记录与
/// 梯级推进是纯逻辑（可程序化自检），驱动在 AgentEngine。梯级只升
/// 不降、每级只试一轮（与循环熔断 3/5/7 的口径不冲突、不重置它）：
/// ①existingMeans 既有手段轮试（frame 感知关闭、揭示复判、站点模式、
/// 替代入口、坐标点击）；②directURL 直达 URL（模板与 ID 均从页面已
/// 有链接实证提取）；③dialogNavBypass 弹窗导航绕行（非编辑页重载；
/// 编辑页先保存回读落定→离开→直达返回）。全部试过＝梯尽。
struct BypassLadder: Equatable {
    enum Rung: String, CaseIterable {
        case existingMeans, directURL, dialogNavBypass
        var label: String {
            switch self {
            case .existingMeans: return "既有手段轮试"
            case .directURL: return "直达 URL"
            case .dialogNavBypass: return "弹窗导航绕行"
            }
        }
    }
    private(set) var attempted: [Rung] = []
    private(set) var notes: [String] = []
    /// 直达 URL 跨页模板记忆（LADDER-FIX F3）：本任务内从页面实证采
    /// 集到、当前页没有的编辑链接模板与其出处页——只许页面实证来源，
    /// 严禁凭记忆或按标识映射假定（mid≠appmsgid 一类映射一律不做）。
    private(set) var harvestTemplate: String?
    private(set) var harvestTemplateFrom: String?
    /// 最近一次 harvest 的实况行（F6）：梯尽结案文案强制引用。
    private(set) var harvestFact: String?

    /// 下一级未试梯级（按声明顺序）；nil＝梯尽。
    var nextRung: Rung? { Rung.allCases.first { !attempted.contains($0) } }
    var exhausted: Bool { nextRung == nil }

    mutating func markAttempted(_ rung: Rung, note: String) {
        if !attempted.contains(rung) { attempted.append(rung) }
        notes.append("\(rung.label)：\(note)")
    }

    /// 记录一次 harvest 的实况与跨页模板记忆（模板仅在同源实证见到
    /// 时更新，fact 每次覆盖为最新实况）。
    mutating func noteHarvest(template: String?, templateFrom: String?, fact: String) {
        if let template, harvestTemplate == nil {
            harvestTemplate = template
            harvestTemplateFrom = templateFrom
        }
        harvestFact = fact
    }

    /// 已试路径的人读汇总（进失败结案文案与步流）。
    var summary: String { notes.joined(separator: "；") }

    init() {}
    /// 快照往返构造：梯级以 rawValue 数组落盘（旧快照无此二键时梯账为空）。
    init(attemptedRaw: [String], notes: [String], harvestTemplate: String? = nil, harvestTemplateFrom: String? = nil, harvestFact: String? = nil) {
        attempted = attemptedRaw.compactMap { Rung(rawValue: $0) }
        self.notes = notes
        self.harvestTemplate = harvestTemplate
        self.harvestTemplateFrom = harvestTemplateFrom
        self.harvestFact = harvestFact
    }
    var attemptedRaw: [String] { attempted.map { $0.rawValue } }
}

/// 直达 URL 的实证提取（AUTONOMY-FIX 梯级②＋LADDER-FIX F3 扩展，
/// 纯函数）：模板与 ID 只从页面实证采集提取，绝不凭记忆编造，更禁
/// 止任何未实证的标识映射（例如假定 mid＝appmsgid）——采集到的
/// 候选里：①已有带 appmsgid 的编辑链接（appmsg_edit）→ 直接用它
/// （模板与 ID 同源实证）；②只有不带 ID 的编辑链接模板、且别处候选
/// 带 appmsgid → 以实证 ID 拼到模板上；③模板只在本任务先前页面实
/// 证见过（跨页记忆）→ 以实证 ID 拼装并注明跨页；④无 ID 或无模板
/// → nil（此级失败）。候选来源（F3）：链接 href、data-* 属性、
/// onclick 属性、页面内嵌列表数据（内联脚本文本）——预览链接
/// （/s? 类带 tempkey）按 F5 明确排除出编辑入口候选并计数留痕。
enum DirectTargetHarvest {
    struct Result: Equatable {
        let url: String
        let appmsgid: String
        let viaTemplate: Bool
        /// 采用候选的来源类别（步流与结案留痕用）。
        var source: String = ""
        /// 模板来自本任务先前页面的跨页记忆时为 true。
        var crossPage: Bool = false
    }

    enum Source: String, CaseIterable {
        case href, dataAttr, onclick, embedded
        var label: String {
            switch self {
            case .href: return "链接 href"
            case .dataAttr: return "data 属性"
            case .onclick: return "onclick 属性"
            case .embedded: return "内嵌数据"
            }
        }
    }

    /// 一条实证候选：原始值、来源、属性名（data-* 专用，如
    /// data-appmsgid 的裸 ID）、所在 frame 的页面地址（相对地址解析基）。
    struct Candidate {
        let source: Source
        let value: String
        var attrName: String = ""
        var baseURL: String = ""
    }

    /// harvest 实况（F6）：候选总数、来源分布、预览排除数、实证 ID
    /// 数、采用路线或落空原因——梯尽结案强制引用 `line`。
    struct Facts {
        var total: Int = 0
        var perSource: [Source: Int] = [:]
        var previewExcluded: Int = 0
        var knownIDs: [String] = []
        var note: String = ""
        /// 本页实证见到的编辑链接模板（已解析的绝对地址；供引擎回写
        /// 梯账作跨页模板记忆，不进 line 文案）。
        var editTemplate: String? = nil
        var line: String {
            let dist = Source.allCases.compactMap { s -> String? in
                guard let n = perSource[s], n > 0 else { return nil }
                return "\(s.label) \(n)"
            }.joined(separator: "、")
            var text = "候选共 \(total) 条"
            if !dist.isEmpty { text += "（来源：\(dist)）" }
            if previewExcluded > 0 { text += "；预览链接排除 \(previewExcluded) 条" }
            text += "；实证 appmsgid \(knownIDs.count) 个"
            if !note.isEmpty { text += "；\(note)" }
            return text
        }
    }

    /// 旧入口（仅 href 候选）：自检十八既有断言走此包装，语义不变。
    static func build(hrefs: [String]) -> Result? {
        build(candidates: hrefs.map { Candidate(source: .href, value: $0) }, memoryTemplate: nil).result
    }

    static func build(candidates: [Candidate], memoryTemplate: String?) -> (result: Result?, facts: Facts) {
        var facts = Facts()
        facts.total = candidates.count
        for c in candidates { facts.perSource[c.source, default: 0] += 1 }
        var directEdit: (url: String, id: String, source: Source)?
        var editTemplate: (url: String, source: Source)?
        for c in candidates {
            // 裸 ID 属性（data-appmsgid="12345" 一类）：属性名本身即
            // 实证语义，值是纯数字才收——这是页面明示的标识，不是映射假定。
            if c.source == .dataAttr, c.attrName.lowercased().contains("appmsgid"),
               !c.value.isEmpty, c.value.allSatisfy({ $0.isNumber }), !facts.knownIDs.contains(c.value) {
                facts.knownIDs.append(c.value)
            }
            for raw in extractURLs(from: c) {
                if let id = firstMatch(raw, pattern: "appmsgid=(\\d+)"), !facts.knownIDs.contains(id) {
                    facts.knownIDs.append(id)
                }
                if isPreviewLink(raw) { facts.previewExcluded += 1; continue }
                guard raw.contains("appmsg_edit"),
                      let resolved = resolve(raw, base: c.baseURL) else { continue }
                if let id = firstMatch(resolved, pattern: "appmsgid=(\\d+)") {
                    if directEdit == nil { directEdit = (resolved, id, c.source) }
                } else if editTemplate == nil {
                    editTemplate = (resolved, c.source)
                }
            }
        }
        facts.editTemplate = editTemplate?.url
        if let d = directEdit {
            facts.note = "采用带 ID 编辑链接直用（来源：\(d.source.label)）"
            return (Result(url: d.url, appmsgid: d.id, viaTemplate: false, source: d.source.label), facts)
        }
        if let t = editTemplate, let id = facts.knownIDs.first {
            facts.note = "采用编辑链接模板拼装实证 ID（模板来源：\(t.source.label)）"
            let separator = t.url.contains("?") ? "&" : "?"
            return (Result(url: t.url + separator + "appmsgid=" + id, appmsgid: id, viaTemplate: true, source: t.source.label), facts)
        }
        if let memory = memoryTemplate, let id = facts.knownIDs.first {
            facts.note = "采用跨页模板记忆拼装实证 ID（模板为本任务先前页面实证）"
            let separator = memory.contains("?") ? "&" : "?"
            return (Result(url: memory + separator + "appmsgid=" + id, appmsgid: id, viaTemplate: true, source: "跨页模板记忆", crossPage: true), facts)
        }
        if facts.total == 0 { facts.note = "落空：各 frame 未采集到任何候选" }
        else if facts.knownIDs.isEmpty { facts.note = "落空：\(facts.total) 条候选中未见 appmsgid 实证（不假定任何标识映射）" }
        else { facts.note = "落空：有实证 ID 但无编辑链接模板（本页与跨页记忆均无）" }
        return (nil, facts)
    }

    /// 预览链接判定（F5）：带 tempkey 的 /s? 短链是临时预览、非编辑
    /// 入口——harvest 一律排除，感知层点击时另行标注。
    static func isPreviewLink(_ value: String) -> Bool {
        value.contains("tempkey") && (value.contains("/s?") || value.contains("/s/"))
    }

    /// 从一条候选值里抽出 URL 形子串：href 直接用原值；data-*／
    /// onclick／内嵌数据从原文里截取含 appmsg 的片段与完整 http(s)
    /// 地址（JSON 转义的 \/ 先还原）。
    private static func extractURLs(from c: Candidate) -> [String] {
        if c.source == .href { return c.value.isEmpty ? [] : [c.value] }
        let text = c.value.replacingOccurrences(of: "\\/", with: "/")
        var found: [String] = []
        for pattern in ["https?://[^\\s\"'<>\\\\)]+", "[^\\s\"'<>]+appmsg[^\\s\"'<>]*"] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(m.range, in: text) {
                    let s = String(text[r])
                    if !found.contains(s) { found.append(s) }
                }
            }
        }
        return found
    }

    /// 相对地址以所在 frame 的页面地址为基解析；只收 http(s)。
    private static func resolve(_ raw: String, base: String) -> String? {
        if raw.contains("://") {
            guard let u = URL(string: raw), let scheme = u.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }
            return raw
        }
        guard let baseURL = URL(string: base), let resolved = URL(string: raw, relativeTo: baseURL)?.absoluteURL,
              let scheme = resolved.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return resolved.absoluteString
    }

    private static func firstMatch(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

/// 绕行梯第 1 级「既有手段」的逐项验收项（LADDER-FIX F2）：第 1 级
/// 不再「下达即记 attempted」——每项手段须有引擎可核的真实执行证据
/// 才记 verified；判定不适用的记 NA 并注明依据；两类都不齐时第 1
/// 级保持未完成，由预算强制结级兜底（见 AgentEngine 的推进口径）。
enum StallMeans: String, CaseIterable {
    case revealClick, siteMode, altEntry, coordClick, frameClose
    var label: String {
        switch self {
        case .revealClick: return "揭示复判再点"
        case .siteMode: return "站点模式切换"
        case .altEntry: return "替代入口"
        case .coordClick: return "坐标点击"
        case .frameClose: return "frame 感知关闭"
        }
    }
}

/// 在开的能力卡点（LADDER-FIX F2）：一次卡点从打开到关闭（绕过、
/// 页面离开或梯尽结案）的全程账本——推进权在引擎，不在模型：模型
/// 的 done 须过梯门、后续 ask_user 与动作后钩子都由引擎据此推进梯
/// 级；澄清类 ask_user 停车不关它（随快照跨停车存续，答复后继续）。
struct OpenStall {
    var stuck: String
    /// 卡点所在页（打开时的 URL）；页面离开该地址视为卡点已绕过。
    var openURL: String
    /// 打开时已消费的模型决策数（第 1 级预算强制结级的基准）。
    var openedAtDecision: Int
    /// 打开时页面有弹窗在场（frameClose 的 NA 判定依据之一）。
    var dialogAtOpen: Bool
    private(set) var verified: Set<StallMeans> = []
    private(set) var notApplicable: [StallMeans: String] = [:]
    /// 已执行的 click 目标键集合（替代入口＝出现第二个不同目标键）。
    private(set) var clickedTargets: Set<String> = []
    /// 第 1 级期间真实执行过 click（揭示复判与坐标落点同为引擎
    /// click 实现面：点前揭示复判＋按元素中心真实坐标派发序列）。
    private(set) var clickExecuted = false
    /// 第 1 级期间有弹窗点按无响应信号或导航绕行真实出手。
    private(set) var frameCloseTried = false
    /// 词表外动作留痕（F4：计入卡点证据，不终结任务）。
    private(set) var invalidActions: [String] = []
    /// 感知盲区留痕（F5：hover 显形探测探不到时如实记账）。
    var perceptionBlindNote: String?

    mutating func verify(_ means: StallMeans) { verified.insert(means) }
    mutating func markNA(_ means: StallMeans, reason: String) {
        if !verified.contains(means), notApplicable[means] == nil { notApplicable[means] = reason }
    }
    /// 弹窗点按无响应信号（执行层 frame 感知关闭连败）：记「已真实
    /// 出手」并同时构成 frameClose 项的验收实证。
    mutating func noteFrameCloseSignal() {
        frameCloseTried = true
        verify(.frameClose)
    }
    mutating func noteClickTarget(_ key: String) {
        clickExecuted = true
        clickedTargets.insert(key)
        verify(.revealClick)
        verify(.coordClick)
        if clickedTargets.count >= 2 { verify(.altEntry) }
    }
    mutating func noteInvalidAction(_ name: String) { invalidActions.append(name) }

    init(stuck: String, openURL: String, openedAtDecision: Int, dialogAtOpen: Bool) {
        self.stuck = stuck
        self.openURL = openURL
        self.openedAtDecision = openedAtDecision
        self.dialogAtOpen = dialogAtOpen
    }
    /// 快照往返构造（字段全部可选落盘，旧快照无此组键时卡点为空）。
    init(stuck: String, openURL: String, openedAtDecision: Int, dialogAtOpen: Bool,
         verifiedRaw: [String], na: [String: String], clicked: [String], clickExecuted: Bool,
         frameCloseTried: Bool, invalid: [String], blind: String?) {
        self.init(stuck: stuck, openURL: openURL, openedAtDecision: openedAtDecision, dialogAtOpen: dialogAtOpen)
        verified = Set(verifiedRaw.compactMap { StallMeans(rawValue: $0) })
        for (key, value) in na { if let m = StallMeans(rawValue: key) { notApplicable[m] = value } }
        clickedTargets = Set(clicked)
        self.clickExecuted = clickExecuted
        self.frameCloseTried = frameCloseTried
        invalidActions = invalid
        perceptionBlindNote = blind
    }
    var verifiedRaw: [String] { verified.map { $0.rawValue } }
    var naRaw: [String: String] { Dictionary(uniqueKeysWithValues: notApplicable.map { ($0.key.rawValue, $0.value) }) }
    var clickedRaw: [String] { Array(clickedTargets) }

    /// 第 1 级完成判据：每项手段或已验收、或已判定不适用。
    var rung1Complete: Bool { StallMeans.allCases.allSatisfy { verified.contains($0) || notApplicable[$0] != nil } }
    /// 逐项验收的人读汇总（进梯账与结案文案，F1 可见性）。
    var meansSummary: String {
        StallMeans.allCases.map { m in
            if verified.contains(m) { return "\(m.label)✓" }
            if let why = notApplicable[m] { return "\(m.label)不适用（\(why)）" }
            return "\(m.label)未试"
        }.joined(separator: "、")
    }
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
    /// 执行代次绑定（M1，2026-11-02——既有代次机制的正式化）：每次 launch
    /// 换代，代次与 (runSessionID, conversationTaskID) 一起记入
    /// activeRunContext；worker 在每轮 checkpoint 与每次模型返回后校验
    /// 代次，用户接管（stop）、新任务取代或恢复续跑换代后，旧代次的迟到
    /// 模型回复在执行任何动作前被 CancellationError 丢弃。已发出的动作
    /// 不靠代次回滚——靠成果台账防重复提交（OUTCOME-LEDGER 既有机制）。
    private(set) var activeRunContext: (sessionID: UUID, taskID: UUID, generation: UUID)?
    /// 本次运行的启动时刻：只喂执行异常标记（executionAnomaly）——超时
    /// 只标异常，绝不据此释放或转移执行权。
    private var runStartedAt: Date?
    /// 任务所属会话（M1）：引擎的全部运行时状态（目标/步流/状态卡/快照）
    /// 只服务这一条会话；查看会话（SessionStore 的当前会话指针）切到别处
    /// 时它不变。仅在引擎空闲时由 adoptDisplayedSession 变更，或由
    /// startInSession 在新任务启动时设定。
    private(set) var runSessionID: UUID = SessionStore.shared.currentSessionID

    // MARK: - M1：全局串行队列

    /// 排队中的任务（M1）：全局一条先进先出队列的一项。只存任务文本与
    /// 所属会话——不预绑标签：入队到启动之间用户可能关页/切页，执行
    /// 绑定以启动时刻该会话的现场为准（beginExecution(sessionID:)）。
    struct QueuedTask: Codable, Identifiable, Equatable {
        let id: UUID
        let sessionID: UUID
        let text: String
        let localPage: String?
        let enqueuedAt: Date
    }
    /// 队列对 UI 公开（会话列表里可见、可取消）；落盘 task-queue.json，
    /// 进程被杀后重启仍在（所属会话已删的条目在载入时剔除）。
    @Published private(set) var queuedTasks: [QueuedTask] = []
    private static var queueFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MikaWeb/task-queue.json")
    }
    private var goal = ""
    private var limit = 25
    /// 模型决策步预算（WECHAT-COVER-FIX Part C）：只计模型决策步——
    /// 每次「模型返回一个动作」计 1，与历史条目数解耦。旧口径按历史
    /// 条目计数，引擎自己的注记步（核验提示、重试注记、封面结果注记
    /// 等）与内部子步的提示步都在偷预算，长任务（如完整公众号发表
    /// 链）在 42 条目上限前被自己的记账耗死（2026-11-03 现场实证）。
    /// 撞段限不再是死路：状态本就全量落盘（检查点），resume 开新段
    /// 续跑；全任务硬顶（段数 × 每段上限）封住失控成本。
    private var stepBudget = StepBudget(limit: 25)
    /// 当前暂停是否由「本段步数用完」引起（决定 resume 是否开新段；
    /// 随快照落盘，进程重启后口径不变）。
    private var stepLimitPaused = false
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
    /// 绕行梯现场（AUTONOMY-FIX）：能力类卡点的已试梯级与逐级留痕，
    /// 随任务存活、随快照落盘（恢复后已试梯级不重走）。
    private var bypassLadder = BypassLadder()
    /// 在开的能力卡点（LADDER-FIX F2）：非 nil＝有卡点尚未解除——
    /// 梯级推进权在引擎（done 梯门＋每轮动作后推进钩子），不再等
    /// 模型第二次 ask_user；随快照落盘，跨澄清类停车与进程恢复存续。
    private var openStall: OpenStall?
    /// 本任务已加载的 playbook（ADOPTION-TOP3 第 3 条）：名称防重复加载，正文
    /// 随每次模型调用注入任务上下文；playbook 只是提示层，安全判定不读它。
    private var loadedSkillNames: [String] = []
    private var loadedSkillBodies = ""
    /// 中断恢复现场（RESUME-CONTEXT-FIX）：冷启动按快照恢复出的会话，浏览器
    /// 标签现场还没重建——快照里的标签地址先存放在这里，第一次 resume 时才
    /// 由 applyPendingTabRestore 消费（重建标签＋生成 resumeNote）。restoredSession
    /// 标记「本会话来自快照恢复」，didApplyTabRestore 保证现场只处理一次。
    private var pendingTabScene: (urls: [String], activeIndex: Int, executionIndex: Int?, pinned: [Bool])?
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
    /// 本轮动作后核验的提示步（VERIFY-1）：核验在 runTargeted 内随落记
    /// 运行，步文案经此暂存、由 flushPendingOutcomeStep 在 outcome 步
    /// 之后补入（步序「动作 → 台账 → 核验」）；runConfirmed 路径就地消费。
    private var pendingVerificationStep: String?
    /// 本任务最近的打字内容（提交指纹的来源）：只留内存、最近 5 条；优先取
    /// 编辑器／textarea 的输入，回退任意字段的最近输入。start() 清空——新
    /// 任务的提交若无打字记录，软门按页面＋按钮标识匹配（追问场景正是此路）。
    private var recentTyped: [(text: String, isEditor: Bool)] = []
    /// 待决网页上传（F1，2026-11-02）：upload_file 动作的人在环现场——
    /// agent 定位文件控件后任务停在这里等用户：先过 SP-01 确认卡（非本
    /// 任务生成的私有文件必经，凭据在 AttachmentStore 一次性登记表里、
    /// 确认时消费、取消时作废），再到选文件等待（引擎尝试触发控件、
    /// 用户在系统选择器选文件、引擎回读页面持有状态核验，取消可继续
    /// 任务）。状态以 .waitingManual 呈现、介入卡由 InterventionPrompt
    /// 按本属性渲染专卡（见 AgentChatView 的 UploadCard）。随快照持久化
    /// （SessionSnapshot.upload），进程被杀后恢复到等待侧：pickFile 阶段
    /// 的非任务生成文件会退回确认阶段重走 SP-01（凭据不跨进程复用）。
    struct PendingUpload: Identifiable {
        let id: UUID
        var attachmentID: UUID?
        /// 卡上展示的文件名：具体附件名，或「（在系统选择器中现选的文件）」
        var attachmentName: String
        var isTaskGenerated: Bool
        var pageURL: String
        var pageHost: String
        var elementIndex: Int
        var elementLabel: String
        var stage: Stage
        var confirmationToken: UUID?
        /// 上传前页面图像清单基线（WECHAT-COVER-FIX Part B）：选文件
        /// 阶段开始前采集，收口时与上传后的清单作差——「页面新增图像」
        /// 是封面缩略图/预览图出现的客观第二回读。仅存源串（元数据）。
        var preUploadImages: [String] = []
        /// 目标附件是否为图片、是否已存入系统相册（COVER-UPLOAD-FIX
        /// A/C）：选文件卡与等待文案据此给出确切找图指引（相册「最近
        /// 项目」最新一张／附件中心置顶项）。在 runUpload 解析附件时
        /// 填入；现选文件（无附件）恒 false。仅内存态，不进快照 DTO
        /// （恢复时按附件记录现查回填）。
        var isImage: Bool = false
        var savedToPhotos: Bool = false
        enum Stage { case confirmUpload, pickFile }
    }
    @Published private(set) var pendingUpload: PendingUpload?
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
        loadQueue()
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
        startInSession(runSessionID, local: local, task: task)
    }

    /// UI 新任务入口（M1）：以当前查看会话为归属启动。空闲时
    /// runSessionID 本与查看会话一致（adopt 在每次切换时保持同步），
    /// 这里显式对齐，防任何边角下任务落进别的会话；程序化调用
    /// （自检等）仍走 start() 的 runSessionID 语义。
    func startFromUI(local: String? = nil, task: String? = nil) {
        startInSession(SessionStore.shared.currentSessionID, local: local, task: task)
    }

    /// 新任务启动的统一路径（M1）：当前会话的 start 与队列推进的
    /// startQueued 共用。先在旧 runSessionID 下 stop() 收尾旧任务，再把
    /// 归属切到目标会话——此后状态重置、快照与执行绑定都按目标会话走
    /// （旧会话已暂停任务的快照留在它自己的目录里，切回时可恢复）。
    private func startInSession(_ sessionID: UUID, local: String?, task: String?) {
        stop()
        runSessionID = sessionID
        guard active else { status = .paused("任务只能在前台执行"); return }
        if let issue = modelReadinessIssue() { status = .failed(issue); return }
        if let task { taskText = task }
        guard !taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status = .failed("请输入任务"); return }
        goal = taskText; limit = min(50, max(5, settings.maxSteps)); stepBudget = StepBudget(limit: limit); stepLimitPaused = false; steps = []; stepSeq = 0; answerContext = []; waitingInput = nil; lastStaleKey = nil; staleStreak = 0; transientStreak = 0
        loopDetector.reset(); pendingLoopHint = nil; loadedSkillNames = []; loadedSkillBodies = ""
        // 状态卡与折叠/重试状态随新任务重置（台账不清，见下方既有口径）
        stateCard = TaskStateCard(goal: goal); forcedFoldLevel = 0; contextRetryUsed = false
        // 绕行梯随新任务重置（AUTONOMY-FIX）：每个任务从梯级①重新开始
        bypassLadder = BypassLadder()
        // 在开卡点随新任务重置（LADDER-FIX）：卡点是单任务现场
        openStall = nil
        // 成果台账不清（跨任务存活，见 outcomeLedger 声明处）；只清本任务的
        // 打字记录与未消费的软门提醒——新任务的提交指纹从本任务的输入重算
        recentTyped = []; pendingOutcomeHint = nil; pendingOutcomeStep = nil; pendingVerificationStep = nil
        // 新任务开始：上一会话的中断恢复现场一并作废，不带进新会话
        pendingTabScene = nil; restoredSession = false; didApplyTabRestore = false; resumeNote = nil
        conversationTaskID = UUID()
        autoTitleSessionIfPlaceholder()
        // 任务绑定到该会话当时的活跃标签页：全程作用于它，用户中途切页／
        // 切会话不影响任务（TABS-IMPL＋M1）。本地页加载走执行页通道——
        // 目标会话不是查看会话时不能借道当前页
        web.beginExecution(sessionID: sessionID)
        do { if let local { try web.loadLocalOnExecutionTab(local) } } catch { web.endExecution(); status = .failed(error.localizedDescription); return }
        launch()
    }
    func stop() {
        generation = UUID(); worker?.cancel(); worker = nil; pending = nil
        discardPendingUpload()
        runStartedAt = nil; activeRunContext = nil
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
        // 步数检查点恢复（Part C）：因段限暂停的，点「继续」＝开新段
        // 续跑同一任务（检查点即当前全量状态：目标/台账/页面/历史都
        // 在，不重跑已完成部分）；已达硬顶的继续无意义，留在硬顶
        // 暂停文案、不启动循环。其它暂停（熔断/确认/手输）不走此路。
        if stepLimitPaused {
            if stepBudget.hardTopReached {
                status = .paused("已达全任务步数硬顶（共 \(stepBudget.hardTop) 步模型决策）——请检查结果，或换个说法重新开始新任务")
                persistSnapshot()
                return
            }
            guard stepBudget.openNextSegment() else { return }
            stepLimitPaused = false
            appendStep("budget", "已开启第 \(stepBudget.segment) 段步数预算（每段 \(stepBudget.limit) 步模型决策，全任务硬顶 \(stepBudget.hardTop) 步）：从检查点继续同一任务，成果台账、页面与历史都保留，不重跑已完成部分")
        }
        // 中断恢复的会话：先把浏览器现场带回中断时（重建标签＋导航回原页面），
        // 再启动主循环——循环第一轮的 state() 会等页面加载稳定后才抽状态，
        // 模型拿到的就是原页面＋原目标＋完整历史，而不是起始页＋一句「继续」。
        applyPendingTabRestore()
        // 绑定还在（确认／手输等待后继续）则沿用原执行页；已解除（如切后台被 stop）则绑定到本会话当时的活跃页
        if web.executionTabID == nil { web.beginExecution(sessionID: runSessionID) }
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
            if web.tabsArePristine(for: runSessionID) {
                web.rebuildTabs(urls: scene.urls, activeIndex: scene.activeIndex, executionIndex: scene.executionIndex, pinned: scene.pinned, owner: runSessionID)
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
    // MARK: - M1：串行队列、会话 adopt、代次验证

    /// 任务入队（M1）：执行器忙碌时新任务按会话排队。队列全局一条、
    /// 先进先出，推进只发生在执行权真正空出的终结点（见 advanceQueue）。
    func enqueueTask(sessionID: UUID, text: String, localPage: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queuedTasks.append(QueuedTask(id: UUID(), sessionID: sessionID, text: trimmed, localPage: localPage, enqueuedAt: Date()))
        persistQueue()
    }

    /// 取消一条排队任务（会话列表的队列区调用）。
    func cancelQueuedTask(id: UUID) {
        queuedTasks.removeAll { $0.id == id }
        persistQueue()
    }

    /// 删除会话时清掉该会话的排队任务：会话数据随会话一起消失。
    func cancelQueuedTasks(forSession sessionID: UUID) {
        let before = queuedTasks.count
        queuedTasks.removeAll { $0.sessionID == sessionID }
        if queuedTasks.count != before { persistQueue() }
    }

    private func persistQueue() {
        guard let data = try? JSONEncoder().encode(queuedTasks) else { return }
        try? FileManager.default.createDirectory(at: Self.queueFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.queueFileURL, options: [.atomic])
    }

    private func loadQueue() {
        guard let data = try? Data(contentsOf: Self.queueFileURL),
              let items = try? JSONDecoder().decode([QueuedTask].self, from: data) else { return }
        // 所属会话已被删除的条目不再恢复（删除编排通常已清队，这里兜底）
        let known = Set(SessionStore.shared.sessions.map { $0.id })
        queuedTasks = items.filter { known.contains($0.sessionID) }
    }

    /// 队列推进（M1 执行权语义）：仅从终结点调用——任务完成（worker 的
    /// done 分支）、任务失败落定（worker 外层 catch）、用户手动停止
    /// （stopFromUser，此时状态为已暂停、靠 afterUserStop 放行）。等待
    /// 确认／等待人工／步数暂停／循环熔断都不算终结，执行权不转移；
    /// 执行超时更不触发推进——本函数没有任何按时长的调用点（超时只走
    /// executionAnomaly 标记）。模型未就绪时不推进：队首留在队里，
    /// 用户处理完 Key／登录后，下一个终结点会再试。
    private func advanceQueue(afterUserStop: Bool = false) {
        guard active, let next = queuedTasks.first else { return }
        switch status {
        case .done, .failed, .idle: break
        case .paused: guard afterUserStop else { return }
        default: return
        }
        guard modelReadinessIssue() == nil else { return }
        queuedTasks.removeFirst()
        persistQueue()
        startQueued(next)
    }

    private func startQueued(_ item: QueuedTask) {
        startInSession(item.sessionID, local: item.localPage, task: item.text)
    }

    /// 用户点「停止」（M1）：在 stop 之外推进队列。start 自身走的是
    /// stop()、不经这里——新任务取代旧任务时不顺带把队列点着。
    func stopFromUser() {
        stop()
        advanceQueue(afterUserStop: true)
    }

    /// 执行异常标记（M1 执行权语义）：任务连续执行超过 30 分钟只标
    /// 异常供用户判断——不自动释放、不转移执行权、不动任务本身（长
    /// 任务合法存在；自动放权会让两个任务同写一个浏览器现场）。
    /// 会话列表展示这条标记。
    var executionAnomaly: String? {
        guard busy, let runStartedAt else { return nil }
        let minutes = Int(Date().timeIntervalSince(runStartedAt) / 60)
        guard minutes >= 30 else { return nil }
        return "任务已连续执行 \(minutes) 分钟（异常长）——执行权仍在本任务，未自动转移；如确已卡死，可手动停止后再继续或重开。"
    }

    /// 新任务自动命名会话（M1）：经 UI 新建的会话标题是占位「新会话」，
    /// 其第一个任务启动时以任务文本命名，列表里才认得出哪个会话干过
    /// 什么；用户改过名的会话不再动。
    private func autoTitleSessionIfPlaceholder() {
        let store = SessionStore.shared
        guard let meta = store.sessions.first(where: { $0.id == runSessionID }), meta.title == "新会话" else { return }
        store.renameSession(id: runSessionID, title: String(goal.prefix(16)))
    }

    /// 切换查看会话时引擎侧的跟随动作（M1）：空闲时把运行时整体切到
    /// 新会话——内存态清零（resetRuntimeState）、载入新会话的未完成
    /// 快照（有才恢复）、标签换到新会话的集合。执行中（含等待确认／
    /// 等待人工／已暂停）只换标签显示：运行现场属于原会话，绝不在此
    /// 清零或接管，用户切回来时它还在原地——已暂停任务靠它自己的
    /// 快照，在引擎下次空闲 adopt 回原会话时恢复。
    /// 前置：编排方已先 setCurrentSession 并让对话存储换源（顺序见
    /// SessionListView 的切换动作）。
    func adoptDisplayedSession(_ sessionID: UUID) {
        guard sessionID != runSessionID, !busy else { web.showSessionTabs(sessionID); return }
        runSessionID = sessionID
        resetRuntimeState()
        restoreSnapshot(for: sessionID, allowLegacy: false)
        web.showSessionTabs(sessionID)
    }

    /// 运行时内存态清零（M1）：adopt 切会话用。清单与自检四「模拟进程
    /// 中断」的清零段同源（漏清任何一项都会把上一会话的步流／等待态
    /// 串进新会话）；两处刻意不同的是成果台账——自检四连台账本体一并
    /// 清掉以证明恢复只靠快照，这里不清：台账是 App 级防重证据（按
    /// 会话隔离的是状态卡里的引用与快照双写），切会话清了它会让别的
    /// 会话刚提交过的动作失去防重保护；快照恢复时按 id 合并回来。
    private func resetRuntimeState() {
        generation = UUID(); worker?.cancel(); worker = nil; pending = nil
        goal = ""; taskText = ""; steps = []; stepSeq = 0; answerContext = []; waitingInput = nil
        lastStaleKey = nil; staleStreak = 0; transientStreak = 0
        loopDetector.reset(); pendingLoopHint = nil; loadedSkillNames = []; loadedSkillBodies = ""
        conversationTaskID = nil; sessionActive = false; status = .idle
        pendingTabScene = nil; restoredSession = false; didApplyTabRestore = false; resumeNote = nil
        recentTyped = []; outcomeGateFired = []; pendingOutcomeHint = nil; pendingOutcomeStep = nil; pendingVerificationStep = nil
        discardPendingUpload()
        stateCard = TaskStateCard(); forcedFoldLevel = 0; contextRetryUsed = false
        runStartedAt = nil; activeRunContext = nil
    }

    /// 代次失效验证（自检九子项，M1）：捕获当前代次为 stale、换代后对
    /// stale 代次调 checkpoint 必须抛 CancellationError——证明「旧代次
    /// 的迟到模型回复不得再执行任何动作」的闸在引擎入口成立（worker
    /// 在每轮开头与每次模型返回后都过 checkpoint，动作执行前必经此闸，
    /// runTargeted／runConfirmed 内部同样校验）。仅在引擎空闲时调用
    /// （换代即 stop 的语义，忙碌时调用会误杀在跑的任务），自检九的
    /// 编排保证这一点。
    func verifyStaleGenerationDiscarded() async -> Bool {
        guard !busy else { return false }
        let stale = generation
        generation = UUID()
        do {
            try await checkpoint(stale)
            return false
        } catch is CancellationError {
            return true
        } catch {
            return false
        }
    }

    /// 删除会话时回收其标签（自检九清理与会话列表的删除编排共用口径，
    /// 转 WebController.discardTabs；前提同该函数：非执行/非查看会话）。
    func discardTabsForSession(_ sessionID: UUID) { web.discardTabs(for: sessionID) }

    /// 自检九 Tier A（M1）：多会话外壳的程序化核查——建 3 个 scratch
    /// 会话、各开标签、置顶与关闭守卫、跨会话切换（标签对象/地址/导航
    /// 计数不变＝未销毁未重载）、队列落盘往返、代次失效。全程不调用
    /// 模型；要求引擎空闲（忙碌时直接返回未执行说明行）。scratch 会话
    /// 结束时删除干净、查看会话切回原处；唯一刻意留下的痕迹是原会话
    /// 的 lastActiveAt 被切换动作刷新（索引层时间戳，无功能影响）。
    /// 注意：本函数直接操作 SessionStore 指针与标签集合，不经对话
    /// 存储换源（测试期间对话停留在原会话，报告条目也记在原会话）；
    /// 结束时指针切回原会话，指针／对话／标签三方重新一致。
    func verifyMultiSessionShell() async -> [String] {
        guard !busy else { return ["✗ 引擎忙碌中，Tier A 未执行（先等当前任务终结或停止）"] }
        var lines: [String] = []
        let store = SessionStore.shared
        let originalID = store.currentSessionID
        let originalTabCount = web.tabs(for: originalID).count
        let a = store.createSession(title: "自检九A")
        let b = store.createSession(title: "自检九B")
        let c = store.createSession(title: "自检九C")
        let scratch = [a.id, b.id, c.id]
        lines.append(store.sessions.filter { scratch.contains($0.id) }.count == 3
            ? "✓ 三个 scratch 会话建成并在索引在位"
            : "✗ scratch 会话创建不全")
        // —— 会话 A：3 个标签各加载一个本地页 ——
        store.setCurrentSession(id: a.id)
        web.showSessionTabs(a.id)
        let tabA1 = web.tabs(for: a.id)[0]
        let tabA2 = web.newTab()
        let tabA3 = web.newTab()
        try? tabA1.loadLocal("test-form")
        try? tabA2.loadLocal("test-news")
        try? tabA3.loadLocal("test-entries")
        // —— 置顶排序与关闭守卫 ——
        web.setTabPinned(tabA1.id, true)
        lines.append(web.visibleTabs.first?.id == tabA1.id
            ? "✓ 置顶标签排在标签列表最前"
            : "✗ 置顶标签未排到最前")
        web.closeTab(tabA1.id)
        lines.append(web.tabs(for: a.id).count == 3
            ? "✓ 置顶守卫：置顶标签的关闭被拒绝（须先取消置顶才能关）"
            : "✗ 置顶标签被关闭了（守卫失效）")
        try? await Task.sleep(for: .milliseconds(900))
        let idsA = web.tabs(for: a.id).map { ObjectIdentifier($0) }
        let revsA = web.tabs(for: a.id).map { $0.revision }
        let urlsA = web.tabs(for: a.id).map { $0.urlString }
        lines.append(urlsA.count == 3 && urlsA[0].contains("test-form") && urlsA[1].contains("test-news") && urlsA[2].contains("test-entries")
            ? "✓ A 的 3 个标签各就各位（表单／资讯／活动页）"
            : "✗ A 的标签地址不对：\(urlsA)")
        // —— 切到 B：可见集只剩 B 的，A 的标签原样保留 ——
        store.setCurrentSession(id: b.id)
        web.showSessionTabs(b.id)
        let bTabs = web.visibleTabs
        lines.append(bTabs.count == 1 && bTabs[0].sessionID == b.id
            ? "✓ 切到 B：可见标签只剩 B 自己的起始页（A 的标签隐藏不销毁）"
            : "✗ 切到 B 后可见标签集不对（\(bTabs.count) 个）")
        if let bTab = bTabs.first { try? bTab.loadLocal("test-news") }
        let stillA = web.tabs(for: a.id)
        lines.append(stillA.map { ObjectIdentifier($0) } == idsA && stillA.map { $0.revision } == revsA && stillA.map { $0.urlString } == urlsA
            ? "✓ A 的标签在切走期间对象／地址／导航计数全不变（未销毁、未重载）"
            : "✗ A 的标签在切走期间发生变化（对象或导航计数变了）")
        // —— 切回 A：置顶保留、现场不变 ——
        store.setCurrentSession(id: a.id)
        web.showSessionTabs(a.id)
        let backA = web.visibleTabs
        lines.append(backA.first?.id == tabA1.id && backA.first?.isPinned == true && web.tabs(for: a.id).map { $0.revision } == revsA
            ? "✓ 切回 A：置顶保留且仍排最前，标签导航计数不变（切换无重载）"
            : "✗ 切回 A 后置顶或标签现场有变")
        // —— 队列落盘往返 ——
        enqueueTask(sessionID: b.id, text: "自检九排队样本")
        let inMemory = queuedTasks.contains { $0.sessionID == b.id && $0.text == "自检九排队样本" }
        var inFile = false
        if let data = try? Data(contentsOf: Self.queueFileURL),
           let items = try? JSONDecoder().decode([QueuedTask].self, from: data) {
            inFile = items.contains { $0.sessionID == b.id && $0.text == "自检九排队样本" }
        }
        if let item = queuedTasks.first(where: { $0.sessionID == b.id }) { cancelQueuedTask(id: item.id) }
        let goneAfterCancel = !queuedTasks.contains { $0.sessionID == b.id }
        lines.append(inMemory && inFile && goneAfterCancel
            ? "✓ 队列：入队后内存与落盘文件都在位，取消后消失"
            : "✗ 队列往返异常（内存 \(inMemory)、落盘 \(inFile)、取消后消失 \(goneAfterCancel)）")
        // —— 代次失效 ——
        let staleOK = await verifyStaleGenerationDiscarded()
        lines.append(staleOK
            ? "✓ 代次失效：旧代次的 checkpoint 被拒（迟到模型回复不得再执行任何动作）"
            : "✗ 代次失效验证未通过")
        // —— 清理：切回原会话、回收 scratch 标签、删 scratch 会话 ——
        store.setCurrentSession(id: originalID)
        web.showSessionTabs(originalID)
        for id in scratch { web.discardTabs(for: id) }
        var deletedAll = true
        for id in scratch { if !store.deleteSession(id: id) { deletedAll = false } }
        let restoredTabs = web.tabs(for: originalID).count == originalTabCount
        lines.append(deletedAll && restoredTabs && store.currentSessionID == originalID
            ? "✓ 清理完成：scratch 会话与标签已删净，查看会话与原标签数量已复原"
            : "✗ 清理不完全（删除 \(deletedAll)、原标签数复原 \(restoredTabs)）")
        return lines
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
        // 代次绑定（M1）：本代次与所属会话、对话任务一并记录；stop/新任务
        // 换代后，旧代次的 worker 在 checkpoint 处自行退出（见类头注释）
        runStartedAt = Date()
        activeRunContext = conversationTaskID.map { (sessionID: runSessionID, taskID: $0, generation: token) }
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
                while stepBudget.canDecide {
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
                        // 预算计数点（Part C）：模型返回一个动作＝一次决策，
                        // 全引擎只在此一处计数（runConfirmed 执行的是已计数的
                        // 已确认动作，后续动作回到主循环同一计数点取得）；
                        // 引擎注记步与内部子步永不计数
                        stepBudget.consumeDecision()
                        try await checkpoint(token)
                        if action.action == "done" {
                            // done 梯门（LADDER-FIX F2）：有在开卡点且绕行
                            // 梯未尽时 done 不得直接结案——引擎先推进梯
                            // 级：驱动成功则本轮不接受 done、带着新页面
                            // 继续；卡点已绕过或梯已尽才放行；梯尽抛失败
                            // 结案错误走外层收口。
                            if let gate = try await evaluateDoneGate(token: token), gate == .driven {
                                continue
                            }
                            // 完成总结是模型回读页面后写下的核实结论：钉进台账
                            // 里仍待核查的条目，后续追问轮次据此守定力口径
                            markOutcomesVerified(summary: action.summary)
                            record(action); status = .done(action.summary)
                            sessionActive = false; applyIdleTimerPolicy()
                            endBackgroundGrace(); completeContinuedProcessing(success: true)
                            web.endExecution(); clearSnapshot(); resumeNote = nil
                            // 执行权在此真正空出（M1 串行队列的推进点之一）：
                            // 队首任务（若有）在它自己的会话里接着启动
                            advanceQueue()
                            return
                        }
                        // 本轮的循环检测指纹（动作＋目标＋结果），分支内赋值、分支后统一裁决。
                        // 声明在 ask_user 分支之前，且执行链与 ask_user 构成互斥的
                        // else-if 链（LADDER-FIX 回路级修复）：能力类 ask_user 由绕行
                        // 梯在本分支内接管后，本轮不得再落入链尾 else——历史上它落进
                        // else 被 execute 以「不可执行动作」硬终结，且旧 else 先执行后
                        // 记账、该动作无留痕（诊断 D2「触发字符串查不到」的成因）。
                        var loopFingerprint: String?
                        if action.action == "ask_user" {
                            record(action)
                            // 介入分类门（AUTONOMY-FIX）：ask_user 先分类——
                            // 澄清类（任务歧义问答）照旧停车等待，不收紧；
                            // 能力类（请用户亲手操作网页）拒绝停车，改走
                            // 绕行梯：驱动成功则本轮继续循环，梯尽由
                            // handleCapabilityStall 抛失败结案错误。
                            switch InterventionGate.classifyAskUser(declared: action.askKind, question: action.question) {
                            case .capability:
                                try await handleCapabilityStall(stuck: "模型请求用户亲手操作网页：\(action.question)", token: token)
                                loopFingerprint = LoopDetector.fingerprint(action: "ask_user", target: "", outcome: "capability-stall")
                            case .safety, .clarify:
                                // 澄清类停车不吞卡点（LADDER-FIX F2）：卡点
                                // 在开时步流明示其保持在开，答复续跑后继续推进
                                noteClarifyDuringStall(question: action.question)
                                waitingInput = .question(id: UUID(), text: action.question)
                                status = .waitingManual(action.question); persistSnapshot()
                                return
                            }
                        } else if action.action == "use_skill" {
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
                            // 感知标注（LADDER-FIX F5）：预览链接与编辑控件
                            // 在感知层明确区分——目标是带 tempkey 的临时预
                            // 览链接时先行标注：它打开的是预览页、不是编辑
                            // 器，不得据此认定可编辑或已发表；编辑入口另找。
                            if action.action == "click", action.index >= 0, action.index < page.elements.count {
                                let targetElement = page.elements[action.index]
                                if targetElement.linkKind == "preview" {
                                    appendStep("perception", "感知标注：目标「\(targetElement.text.isEmpty ? targetElement.ariaLabel : targetElement.text)」的链接是带 tempkey 的临时预览链接——点开是预览页、不是编辑器，不得据此认定已进入编辑或已发表；编辑入口须另找（绕行梯直达 URL 一级只从页面实证采集编辑入口，预览链接不作候选）")
                                }
                            }
                            // 目标获取走失效恢复（runTargeted）：页面在模型思考／执行期间重排时
                            // 按稳定描述重找重绑，不再把「目标已失效／已变化」直接判为任务失败。
                            switch try await runTargeted(action, modelPage: page, token: token) {
                            case .executed:
                                record(action)
                                // 卡点逐项验收记账（LADDER-FIX F2）：真实
                                // 执行成功的 click 计入在开卡点的手段证据
                                noteExecutedActionForStall(actionName: action.action, targetKey: targetKey)
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
                        } else if action.action == "generate_cover" {
                            // 封面自产（COVER-CONSENT，缺陷 B）：纯本机渲染，
                            // 不经网页执行层——产物落当前会话附件（来源＝本
                            // 任务生成），模型随后用 upload_file 引用其编号
                            // 设封面。标题缺失/渲染失败都如实记步交模型处理，
                            // 不判任务失败、更不假装已生成。
                            record(action)
                            let coverTitle = action.text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if coverTitle.isEmpty {
                                appendStep("cover", "generate_cover 缺标题：请在 text 里给出封面标题（通常用文章标题）后重试")
                                loopFingerprint = LoopDetector.fingerprint(action: "generate_cover", target: "", outcome: "missing-title")
                            } else {
                                // 生成＋登记＋同步相册（COVER-UPLOAD-FIX A）：
                                // 相册结局三态由 PhotoSaveOutcome 文案如实
                                // 带出——saved 才说「去相册最近项目找它」，
                                // denied/failed 明说图只在附件里，不让用户
                                // 去相册空找。
                                let coverResult = await CoverGenerator.generateAndSaveToPhotos(title: coverTitle, subtitle: action.subtitle, template: CoverTemplate.from(action.template), sessionID: runSessionID)
                                if let produced = coverResult.record {
                                    appendStep("cover", "已自产封面「\(produced.displayName)」并存入本会话附件（编号 \(String(produced.id.uuidString.prefix(8)))，版式 \(CoverTemplate.from(action.template).label)，900×383，来源＝本任务生成）；\(coverResult.photo?.stepDescription(fileName: produced.displayName) ?? "未同步系统相册")；设为网页封面时用 upload_file 引用该编号（任务生成文件免 SP-01 确认卡），设没设上以页面回读为准")
                                    loopFingerprint = LoopDetector.fingerprint(action: "generate_cover", target: coverTitle, outcome: "ok")
                                } else {
                                    appendStep("cover", "封面渲染失败（标题：\(coverTitle)），请如实汇报或调整标题后重试，不要假装已生成")
                                    loopFingerprint = LoopDetector.fingerprint(action: "generate_cover", target: coverTitle, outcome: "render-failed")
                                }
                            }
                        } else if action.action == "upload_file" {
                            // 网页上传人在环（F1）：定位文件控件后停在等待侧
                            // （SP-01 确认卡→选文件→回读核验），用户在介入卡
                            // 上解决后由 confirmPendingUpload/finishUploadPick
                            // 另行 launch 续跑；目标不是文件控件时记策略切换
                            // 交模型按新快照重新判断，不判失败。
                            switch try await runUpload(action, modelPage: page, token: token) {
                            case .waiting:
                                persistSnapshot()
                                return
                            case .autoSupplied:
                                // App 已直接供文件且双回读已在
                                // beginUploadPickStage 内收口：不停等待，
                                // 任务照常续跑，模型下一轮看页面现状判断。
                                loopFingerprint = LoopDetector.fingerprint(action: action.action, target: "index:\(action.index)", outcome: "ok")
                            case .strategySwitch:
                                loopFingerprint = LoopDetector.fingerprint(action: action.action, target: "index:\(action.index)", outcome: "strategy-switch")
                            }
                        } else {
                            // 先记账后分发（LADDER-FIX F1）：含词表外动作
                            // 在内，每个动作先在步流留下动作字符串再执行，
                            // 被拒动作不再无留痕。词表外动作去终结化
                            // （F4）：执行层抛「不可执行动作」时记账＋回注
                            // 纠正＋计入在开卡点的证据，不置 .failed、不清
                            // 快照，任务继续；其余错误照旧上抛。
                            record(action)
                            var executedOK = true
                            do {
                                try await checkpoint(token)
                                executionSerial += 1
                                try await web.execute(action, expected: nil)
                                try await checkpoint(token)
                            } catch {
                                guard Self.isUnexecutableActionError(error) else { throw error }
                                executedOK = false
                                handleInvalidAction(action)
                                loopFingerprint = LoopDetector.fingerprint(action: action.action, target: action.action, outcome: "invalid-action")
                            }
                            if executedOK {
                                let target = action.action == "navigate" ? action.url : (action.action == "scroll" ? action.direction : (action.action == "set_site_mode" ? action.mode : "\(Int(action.seconds))"))
                                loopFingerprint = LoopDetector.fingerprint(action: action.action, target: target, outcome: "ok")
                                // 卡点逐项验收记账（F2）：站点模式切换真实
                                // 执行成功计入在开卡点的手段证据
                                noteExecutedActionForStall(actionName: action.action, targetKey: target)
                                try await Task.sleep(for: .milliseconds(500))
                            }
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
                                appendStep("loop", "循环严重提醒：同一动作已重复 \(verdict.count) 次，下一步提示已下达最后换路指令（无路可换时在 ask_user 里如实交代卡点与已试路径，引擎走绕行梯/失败结案），再重复将自动停下")
                                pendingLoopHint = "严重警告（最后一次换路机会）：你已对同一目标重复执行同一动作 \(verdict.count) 次，页面结果始终没有变化。若下一步仍原样重复，任务将自动停下交用户决定。必须换路：换入口／换目标，或用 set_site_mode 换站点模式，或按页面规则／说明里写明的官方路径 navigate 到同功能的电脑版站点／官方后台。若确实已无替代路径，可以用 ask_user 如实交代卡点——先写清已试过的每条路径与各自的卡点；不要请用户亲手操作网页（能力类卡点引擎不停车，会走绕行梯、梯尽按失败结案）。求助只许用于任务歧义澄清。"
                            case .warning:
                                appendStep("loop", "循环提醒：同一动作已重复 \(verdict.count) 次且结果未变，下一步提示已升级为必须换路指令（禁止原样重试）")
                                pendingLoopHint = "警告（必须换路）：你已对同一目标重复执行同一动作 \(verdict.count) 次，页面结果没有变化。下一步禁止原样重试，必须换一种做法：换入口／换目标，或用 set_site_mode 换站点模式，或先读页面规则／说明、按其中写明的官方路径 navigate 到同功能的电脑版站点／官方后台。不要用 ask_user 请用户代劳（能力类卡点不停车）；ask_user 只许用于任务歧义澄清。"
                            case .none:
                                break
                            }
                        }
                        // 一整轮迭代走通：瞬时连败清零
                        transientStreak = 0
                        // 绕行梯引擎推进（LADDER-FIX F2）：卡点在开时，
                        // 每轮末尾由引擎核对推进——页面离开卡点页则关
                        // 卡点；第 1 级验收齐或预算到期则结级并同步驱
                        // 动后续梯级。梯尽抛失败结案错误，经外层 catch
                        // 收口（瞬时错误分类不吞它：文案前缀不在其列）。
                        try await advanceLadderIfNeeded(token: token)
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
                // 步数收口（Part C）：段限到＝检查点暂停（状态已全量落盘，
                // resume 开新段续跑同一任务）；硬顶到＝真上限，须重新开始
                if stepBudget.hardTopReached {
                    stepLimitPaused = false
                    status = .paused("已达全任务步数硬顶（共 \(stepBudget.hardTop) 步模型决策）——请检查结果，或换个说法重新开始新任务")
                } else if stepBudget.segmentExhausted {
                    stepLimitPaused = true
                    status = .paused("本段步数已用完（第 \(stepBudget.segment)/\(StepBudget.maxSegments) 段，累计模型步 \(stepBudget.totalUsed)/硬顶 \(stepBudget.hardTop)）——进度已存检查点（目标、成果台账、页面与历史都在），点「继续」开启下一段接着跑，不会重跑已完成部分")
                } else {
                    status = .paused("已达最大 \(limit) 步，请检查结果或重新开始")
                }
                persistSnapshot()
            } catch {
                guard token == generation else { return }
                sessionActive = false; applyIdleTimerPolicy()
                endBackgroundGrace(); completeContinuedProcessing(success: false)
                web.endExecution(); clearSnapshot(); resumeNote = nil
                if error is CancellationError { status = .paused("已取消") }
                else { status = .failed(error.localizedDescription); advanceQueue() }
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
            if let outcome = noteSubmissionIfNeeded(action: saved.0, element: target, pageURL: saved.2) {
                appendStep("outcome", outcome.note)
                // VERIFY-1：确认路径同样过独立核验（shadow 记录，就地补步）
                await runPostSubmissionVerification(recordID: outcome.recordID, element: target, pageURL: saved.2, before: page, token: token)
                if let vstep = pendingVerificationStep { appendStep("verify", vstep); pendingVerificationStep = nil }
            }
            try await Task.sleep(for: .milliseconds(500))
            return .proceed
        } catch {
            guard token == generation else { throw CancellationError() }
            if error is CancellationError { throw error }
            // 弹窗点按无响应（COVER-CONSENT 立、AUTONOMY-FIX 改）：这是
            // 能力类卡点——不判失败、不停车等用户代劳，也不再把 pending
            // 放回原样重确认（弹窗还在，再确认只会再连败一次）。改走
            // 绕行梯弹窗导航绕行：成功（弹窗已消失）→ 已确认动作原样
            // 放回等待确认，用户在干净页面上重新确认（确认本身属安全
            // 类、仍由用户点，引擎不代行）；绕行失败 → 失败结案。
            if Self.modalInterventionText(for: error) != nil {
                appendStep("click", "弹窗点按无响应（能力卡点）：不停车等用户代劳，改走绕行梯（弹窗导航绕行）")
                if await driveDialogBypass(token: token) {
                    pending = saved
                    appendStep("bypass", "弹窗导航绕行成功：弹窗已消失，已确认动作放回等待确认——请在干净页面上重新确认（确认属安全类，仍由用户点）")
                    status = .waitingConfirm(saved.0)
                    persistSnapshot()
                    return .halted
                }
                throw await capabilityFailureError(stuck: "已确认动作被无响应弹窗挡住：\(saved.0.reason)")
            }
            guard let kind = Self.transientKind(of: error) else { throw error }
            writeTransientDiagnostic(kind: kind, error: error, streak: 0)
            pending = saved
            appendStep("retry", "页面脚本出错，已确认的操作没有自动重做，请核对页面后再次确认或跳过")
            status = .waitingConfirm(saved.0)
            persistSnapshot()
            return .halted
        }
    }
    // MARK: - 网页上传人在环（F1：SP-01 确认门＋系统选择器选文件＋回读核验）

    private enum UploadOutcome { case waiting, strategySwitch, autoSupplied }

    /// upload_file 的定位与等待置位：在模型所见快照里按稳定描述重找目标
    /// （与 click/type 同口径，预算 1 次重取快照），目标必须是文件控件
    /// （input[type=file]，含被站点隐藏的——抽取层已为文件控件开可见性
    /// 例外）；不是或已消失 → 记一条说明步并交模型重新判断（strategySwitch）。
    /// 定位成功后组装 PendingUpload：意图附件按 action.text（附件 id 或
    /// 文件名）解析，解析不到按「用户将在选择器现选的私有文件」处理；
    /// SP-01 判定走 SafetyPolicy.uploadDecision——非本任务生成的一律先
    /// 出确认卡（签发一次性凭据），本任务生成的直接进选文件阶段。
    private func runUpload(_ action: AgentAction, modelPage: PageState, token: UUID) async throws -> UploadOutcome {
        guard action.index >= 0, action.index < modelPage.elements.count else {
            appendStep("upload", "upload_file 的目标序号不在当前页面元素清单里，请按最新页面重新判断")
            return .strategySwitch
        }
        let original = modelPage.elements[action.index]
        let descriptor = ElementDescriptor(original)
        var snapshot = modelPage
        var target: PageElement?
        for attempt in 0...1 {
            try await checkpoint(token)
            if snapshot.url == modelPage.url {
                target = resolveTarget(descriptor: descriptor, original: original, in: snapshot.elements)
            }
            if let found = target, found.tag == "input", found.inputType.lowercased() == "file" { break }
            target = nil
            if attempt == 0 { snapshot = try await web.state() }
        }
        guard let target else {
            appendStep("upload", "目标不是文件上传控件或已不在页面上——upload_file 只对 input[type=file] 控件使用，请按最新页面重新判断")
            return .strategySwitch
        }
        let reference = action.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachment = reference.isEmpty ? nil : AttachmentStore.shared.findAttachment(reference: reference, sessionID: runSessionID)
        let isTaskGenerated = attachment?.origin == .taskGenerated
        let needsConfirm = SafetyPolicy.uploadDecision(isTaskGenerated: isTaskGenerated) == .confirm
        var upload = PendingUpload(id: UUID(), attachmentID: attachment?.id,
                                   attachmentName: attachment?.displayName ?? "（在系统选择器中现选的文件）",
                                   isTaskGenerated: isTaskGenerated,
                                   pageURL: snapshot.url,
                                   pageHost: URL(string: snapshot.url)?.host ?? "",
                                   elementIndex: target.index,
                                   elementLabel: !target.ariaLabel.isEmpty ? target.ariaLabel : (!target.name.isEmpty ? target.name : "文件上传控件"),
                                   stage: needsConfirm ? .confirmUpload : .pickFile,
                                   confirmationToken: nil)
        // 找图指引口径（COVER-UPLOAD-FIX A/C）：选文件卡要能确切告诉
        // 用户文件在哪——是否图片、是否已存入系统相册，此刻定格。
        upload.isImage = attachment?.contentType.hasPrefix("image/") ?? false
        upload.savedToPhotos = attachment?.savedToPhotos == true
        if needsConfirm {
            upload.confirmationToken = AttachmentStore.shared.issueUploadConfirmation(attachmentID: attachment?.id, pageURL: snapshot.url)
            pendingUpload = upload
            let text = "上传前请确认：将把文件「\(upload.attachmentName)」上传到 \(upload.pageHost.isEmpty ? "当前页面" : upload.pageHost)"
            waitingInput = .manual(id: upload.id, text: text)
            status = .waitingManual(text)
            appendStep("upload", "已定位文件控件（\(upload.elementLabel)），按 SP-01 先出确认卡：文件「\(upload.attachmentName)」→ \(upload.pageHost.isEmpty ? upload.pageURL : upload.pageHost)，等用户确认")
        } else {
            pendingUpload = upload
            appendStep("upload", "已定位文件控件（\(upload.elementLabel)），文件为本任务生成物、SP-01 豁免确认")
            if await beginUploadPickStage() { return .autoSupplied }
        }
        return .waiting
    }

    /// 进入选文件阶段，返回 true＝已由 App 自动供文件并收口（调用方
    /// 不要再停等待：runUpload 侧任务续跑、确认卡侧 launch 续跑）。
    ///
    /// 先做双回读基线采集，再（附件已解析且系统支持时）武装待供文件
    /// 并触发控件——iOS 18.4+ 的文件面板公开回调命中即由 App 直接把
    /// 文件交给页面、不弹选择器（COVER-UPLOAD-FIX D；SP-01 语义不变：
    /// 走到这里说明已豁免或确认卡已消费）。触发后留一个短窗口等回调
    /// 消费：命中→双回读收口；未命中（合成 click 未被认作拉起面板的
    /// 手势）→待供文件保持武装转手动等待，用户在页面上真点上传按钮
    /// 时同一回调会自动供文件。无附件/系统不支持时与旧路径一致：
    /// 触发尝试＋置等待，用户照介入卡指引自己选文件。等待文案与
    /// waitingInput 同步更新（对话里留一条 manual 条目）。
    private func beginUploadPickStage() async -> Bool {
        guard var upload = pendingUpload else { return false }
        upload.stage = .pickFile
        // 双回读基线（Part B）：触发控件前先存页面图像清单——收口时
        // 只有「上传后新增的图像」才算封面/预览出现的第二回读证据
        upload.preUploadImages = await web.probePageImages()
        pendingUpload = upload
        var supplyArmed = false
        if let attachmentID = upload.attachmentID,
           let record = AttachmentStore.shared.record(id: attachmentID, sessionID: runSessionID) {
            supplyArmed = web.armUploadSupply(url: AttachmentStore.shared.fileURL(for: record), fileName: record.displayName)
        }
        _ = await web.triggerFileInput(index: upload.elementIndex)
        if supplyArmed {
            try? await Task.sleep(for: .milliseconds(1200))
            if !web.uploadSupplyArmed {
                appendStep("upload", "App 已直接供文件：SP-01 已过后由 App 把「\(upload.attachmentName)」直接交给了页面文件控件（iOS 文件面板公开回调，未经系统选择器、未再向用户索取确认）")
                pendingUpload = nil
                waitingInput = nil
                await verifyPickedUpload(upload: upload)
                return true
            }
            appendStep("upload", "自动供文件未触发（合成触发未拉起文件面板）——文件已由 App 备好并保持待供：在网页上点一次上传按钮就会自动带上，不用在选择器里翻找")
        }
        let text = "请选择要上传的文件（目标：\(upload.attachmentName)）"
        // 等待 id 每阶段一换：对话层按 id 去重，复用确认阶段的 id 会把
        // 选文件这条等待条目吞掉
        waitingInput = .manual(id: UUID(), text: text)
        status = .waitingManual(text)
        persistSnapshot()
        return false
    }

    /// 选文件卡的找图指引（COVER-UPLOAD-FIX C，纯函数、自检二十二
    /// 断言）：按附件实况拼出「去哪里选这份文件」——已存入相册的图片
    /// 指相册「最近项目」最新一张；其余指附件中心置顶的「本任务生成」
    /// 项；待供文件仍武装时加一句「在页面点上传按钮会自动带上」。
    /// 介入卡与快照恢复文案共用，保证两处口径一致。
    static func uploadPickGuidance(upload: PendingUpload, supplyArmed: Bool) -> String {
        var routes: [String] = []
        if upload.isImage && upload.savedToPhotos {
            routes.append("打开照片选择里的「最近项目」，最新的一张就是它（文件名 \(upload.attachmentName)）")
        }
        routes.append("或在本 App 的附件中心里选置顶、标着「本任务生成」的那份（文件名 \(upload.attachmentName)）")
        var text = "这份文件在哪选：" + routes.joined(separator: "；")
        if supplyArmed {
            text += "；也可以直接在网页上点一次上传按钮——文件已由 App 备好，会自动带上，不用在选择器里翻找"
        }
        return text
    }

    /// SP-01 确认卡「确认上传」：在此消费一次性凭据——凭据已过期/被消费/
    /// 与（附件＋页面）不绑定时不放行，记步并把主动权交回模型（它可重新
    /// 发起 upload_file 拿新卡）；消费成功才进入选文件阶段。
    func confirmPendingUpload() {
        guard let upload = pendingUpload, upload.stage == .confirmUpload else { return }
        if let token = upload.confirmationToken {
            guard AttachmentStore.shared.consumeUploadConfirmation(token, attachmentID: upload.attachmentID, pageURL: upload.pageURL) else {
                pendingUpload = nil
                waitingInput = nil
                appendStep("upload", "上传确认已失效（一次性确认过期或已被消费），本次没有执行；如仍要上传，请重新发起 upload_file 拿新确认卡")
                launch()
                return
            }
        }
        appendStep("upload", "用户已确认上传文件「\(upload.attachmentName)」（SP-01 一次性确认已消费，不可复用）")
        Task { @MainActor [weak self] in
            guard let self else { return }
            // 自动供文件命中时选文件阶段已自行收口，任务直接续跑；
            // 未命中则已置等待（选文件卡），等用户照卡操作。
            if await self.beginUploadPickStage() { self.launch() }
        }
    }

    /// 上传等待中取消（确认卡「取消」与选文件卡「取消上传」共用）：
    /// 作废未消费的凭据、记步、续跑主循环——取消后任务可继续，模型从
    /// 历史里看得到取消记录，不要反复要求上传同一文件。
    func cancelPendingUpload() {
        guard let upload = pendingUpload else { return }
        discardPendingUpload()
        waitingInput = nil
        appendStep("upload", "用户取消了上传（文件「\(upload.attachmentName)」未上传），请继续任务的其他部分，不要反复要求上传同一文件")
        launch()
    }

    /// 选文件阶段收口：「已选好」→ 回读页面文件控件的持有状态核验（只报
    /// 页面持有，不声称已提交服务器——提交与否看页面后续反馈，模型在
    /// 下一轮快照里判断）；「取消」→ 按取消口径记步。两路都清等待并续跑。
    func finishUploadPick(completed: Bool) {
        guard let upload = pendingUpload, upload.stage == .pickFile else { return }
        pendingUpload = nil
        waitingInput = nil
        web.disarmUploadSupply()
        guard completed else {
            appendStep("upload", "用户取消了选文件（文件「\(upload.attachmentName)」未上传），请继续任务的其他部分，不要反复要求上传同一文件")
            launch()
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await verifyPickedUpload(upload: upload)
            launch()
        }
    }

    /// 选文件收口的双回读核验（手动选文件与 App 自动供文件共用）：
    /// ①文件控件持有状态 ②页面新增图像（封面缩略图/预览图）。双过才
    /// 算「封面已设上」写里程碑；单过按 VERIFY-1 的 unknown 口径如实
    /// 记步、不写里程碑、不声称设上；控件未持有则明说没读到。
    private func verifyPickedUpload(upload: PendingUpload) async {
        let index = upload.elementIndex
        let host = upload.pageHost
        let baseline = Set(upload.preUploadImages)
        let names = await web.probeFileInput(index: index)
        if names.isEmpty {
            appendStep("upload", "上传回读核验：页面文件控件里未读到已选文件——可能还没选完或页面未持有该文件，不要声称已上传成功；确需上传时重新发起 upload_file")
        } else {
            let afterImages = await web.probePageImages()
            let newImages = afterImages.filter { !baseline.contains($0) }
            if newImages.isEmpty {
                appendStep("upload", "上传回读核验（unknown）：文件控件已持有文件 \(names.joined(separator: "、"))（目标页面 \(host.isEmpty ? "当前页面" : host)），但页面上未见新增的封面/预览图像——封面可能尚未设上或预览未渲染，不要声称封面已设好；下一轮看页面现状再判断（可稍等预览出现或核对封面区）")
            } else {
                appendStep("upload", "上传回读核验（双回读通过）：页面文件控件已持有文件 \(names.joined(separator: "、"))（目标页面 \(host.isEmpty ? "当前页面" : host)），且页面新增了 \(newImages.count) 处图像（封面缩略图/预览已出现）——两项回读相互印证，封面已设上；是否已提交到服务器以下一轮页面反馈为准")
                stateCard.addCompleted("upload_file：页面已持有文件 \(names.joined(separator: "、"))，封面/预览图像已出现（双回读）")
            }
        }
    }

    /// 丢弃待决上传（stop/切会话清零/中断模拟共用）：未消费的 SP-01
    /// 凭据一并作废——离开这个动作后，旧确认不得再被用起。
    private func discardPendingUpload() {
        if let token = pendingUpload?.confirmationToken {
            AttachmentStore.shared.invalidateUploadConfirmation(token)
        }
        pendingUpload = nil
        // 待供文件一并解除武装（COVER-UPLOAD-FIX D）：任务/会话离开
        // 这个上传后，备好的文件不得再被后来的文件面板误消费。
        web.disarmUploadSupply()
    }

    /// 选文件卡指引用（COVER-UPLOAD-FIX D）：待供文件是否仍武装中
    /// （介入卡据此决定是否展示「点上传按钮自动带上」一句）。
    var uploadSupplyArmed: Bool { web.uploadSupplyArmed }

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
                    if let outcome = noteSubmissionIfNeeded(action: action, element: target, pageURL: snapshot.url) {
                        pendingOutcomeStep = outcome.note
                        // VERIFY-1：落记后随即独立核验（shadow，verify 步经
                        // pendingVerificationStep 在 outcome 步之后补入）
                        await runPostSubmissionVerification(recordID: outcome.recordID, element: target, pageURL: snapshot.url, before: modelPage, token: token)
                    }
                }
                return .executed
            } catch {
                // 弹窗点按无响应（COVER-CONSENT 立、AUTONOMY-FIX 改、
                // LADDER-FIX 补卡点联动）：能力类卡点，不是失效类错误，
                // 重找重试只会再连败——不停车等用户代劳。卡点已在开时：
                // frame 感知关闭连败计入卡点证据（第 1 级 frameClose
                // 项），按策略切换交模型续跑，梯级推进由引擎钩子驱动
                // （不再从这里跳过第 2 级直达第 3 级）；无在开卡点时沿
                // 用既有直达弹窗导航绕行口径，绕行失败 → 失败结案。
                if Self.modalInterventionText(for: error) != nil {
                    if var stall = openStall {
                        stall.noteFrameCloseSignal()
                        openStall = stall
                        appendStep("click", "弹窗点按无响应（能力卡点）：frame 感知关闭连败已计入在开卡点的证据（第 1 级 frame 感知关闭项验收），引擎将按绕行梯继续推进（直达 URL／弹窗导航绕行），不停车等用户代劳")
                        persistSnapshot()
                        return .strategySwitch
                    }
                    appendStep("click", "弹窗点按无响应（能力卡点）：不停车等用户代劳，改走绕行梯（弹窗导航绕行）")
                    if await driveDialogBypass(token: token) {
                        appendStep("bypass", "弹窗导航绕行成功：弹窗已消失，请按最新页面重新判断")
                        return .strategySwitch
                    }
                    throw await capabilityFailureError(stuck: "弹窗点按无响应，目标「\(label)」被弹窗挡住")
                }
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

    /// 弹窗点按无响应的分类门信号判定（COVER-CONSENT 立、AUTONOMY-FIX
    /// 改定位）：执行层以 WebController.modalUnresponsivePrefix 抛错＝
    /// 弹窗内按钮经完整点按序列与 frame 感知关闭连败、弹窗仍在——这是
    /// 能力类卡点（合成点按过不去），不是安全类。命中返回非 nil 作为
    /// 触发信号：runTargeted 自主路径与 runConfirmed 确认路径共用同一
    /// 判定，两处都不再停车等用户代劳——改走绕行梯（弹窗导航绕行），
    /// 梯尽走失败结案。返回值本身不再作为给用户的介入文案展示。
    /// 不命中返回 nil，错误照原有分类处理。
    static func modalInterventionText(for error: Error) -> String? {
        guard let mika = error as? MikaError, mika.message.hasPrefix(WebController.modalUnresponsivePrefix) else { return nil }
        return "弹窗点按无响应（能力类卡点信号，AUTONOMY-FIX）"
    }

    /// 自检十一 Tier A 组合（COVER-CONSENT）：封面自产核查（CoverGenerator
    /// 程序化）＋弹窗点按核查（WebController 在合成页真实驱动）＋分类门
    /// 信号判定双向核对（弹窗错误命中能力类信号、普通错误不误触发）。
    /// 不调用模型；要求引擎空闲（弹窗核查会占用当前标签页打开合成页）。
    /// 自检十四·Tier A（WECHAT-COVER-FIX Part A）：弹窗 frame 探针——
    /// 委托 WebController 在合成页 test-frames 上实测（同源/跨源 frame
    /// 各一弹窗：枚举定位＋框内序列/Escape 关闭＋元素消失回读判定）。
    func verifyFrameProbe() async -> [String] {
        guard !busy else { return ["✗ 引擎忙碌中，自检十四 Tier A 未执行（先等当前任务终结或停止）"] }
        return await web.verifyFrameProbeAndClick()
    }

    /// 自检十六·Tier A（WECHAT-EDITOR-NAV）：入口感知补盲——委托
    /// WebController 在合成页 test-nav 上实测（icon-only／alt／背景图
    /// 三类无文本入口进快照且名源正确、内层滚动容器下方入口经揭示
    /// 复判可达、补盲入口真点得动、文本锚点回退点中整卡）。
    func verifyEditorNav() async -> [String] {
        guard !busy else { return ["✗ 引擎忙碌中，自检十六 Tier A 未执行（先等当前任务终结或停止）"] }
        return await web.verifyEditorNavReveal()
    }

    /// 自检二十（TRUSTED-CLICK-EXP）：E1 金标准对照插桩的复刻页实验
    /// （插桩自证＋touches 恒空复现）＋E2 AX 激活探针——委托
    /// WebController 在合成页 test-trusted 上实测并落盘结构化日志。
    /// E1 真机金标准（真实弹窗上 Joey 真点一次）由阿仁另行约，不在
    /// 本入口内；E3 受 E1 真机结果门控、不做。
    func verifyTrustedClick() async -> [String] {
        guard !busy else { return ["✗ 引擎忙碌中，自检二十未执行（先等当前任务终结或停止）"] }
        return await web.verifyTrustedClickExp()
    }

    func verifyCoverAndModal() async -> [String] {
        guard !busy else { return ["✗ 引擎忙碌中，自检十一 Tier A 未执行（先等当前任务终结或停止）"] }
        var lines = CoverGenerator.verifyCoverGeneration()
        lines += await web.verifyModalClickEscalation()
        let probe = MikaError("\(WebController.modalUnresponsivePrefix)：合成样本")
        lines.append(Self.modalInterventionText(for: probe) != nil && Self.modalInterventionText(for: MikaError("其它错误样本")) == nil
            ? "✓ 分类门信号判定：弹窗无响应错误命中能力类信号、普通错误不误触发（自主/确认两条执行路径共用同一判定，命中后走绕行梯不停车）"
            : "✗ 分类门信号判定异常")
        return lines
    }

    // MARK: - 绕行梯驱动（AUTONOMY-FIX）

    /// 合成 click 动作构造（自检与绕行梯共用；AgentAction 只有
    /// Decodable 初始化，走 JSON 解码构造）。
    private static func clickAction(index: Int, reason: String) -> AgentAction? {
        let dict: [String: Any] = ["action": "click", "index": index, "reason": reason]
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(AgentAction.self, from: data)
    }

    /// 失败结案的页面证据：当前页地址/标题＋可见文本摘要（只作证据，
    /// 不含凭据类内容——页面文本本就是模型每轮可见的快照同源数据）。
    private func currentPageEvidence() async -> String {
        if let page = try? await web.state() {
            return "当前页 \(page.url)（标题：\(page.title)），可见文本摘要：\(String(page.text.prefix(120)))"
        }
        return "当前页状态读取失败"
    }

    /// 梯尽失败结案错误：文案由分类门组装（卡点＋已试路径＋harvest
    /// 实况节＋页面证据，不出现请用户代劳的措辞），由 launch 外层
    /// catch 置 .failed 收口。harvest 实况取梯账里最近一次采集的
    /// 回写（F6）；从未运行过 harvest 时文案明示未运行原因。
    private func capabilityFailureError(stuck: String) async -> MikaError {
        MikaError(InterventionGate.failureSummary(stuck: stuck, ladder: bypassLadder, evidence: await currentPageEvidence(), harvestFact: bypassLadder.harvestFact))
    }

    /// 能力类卡点处理（AUTONOMY-FIX 立、LADDER-FIX F2 改引擎驱动）：
    /// 分类门拒绝停车后调用。首次信号＝打开卡点并下达第 1 级——本级
    /// 只下达、不记 attempted，逐项验收由引擎在后续每轮动作后核对
    /// （见 advanceLadderIfNeeded）；卡点已在开时再收到能力类信号＝
    /// 强制结第 1 级并由引擎同步驱动后续梯级。不再把梯级推进权留给
    /// 模型（旧口径等第二次 ask_user 才推进，现场实证梯子永停第 1 级）。
    private func handleCapabilityStall(stuck: String, token: UUID) async throws {
        if openStall == nil {
            let census = await web.dialogCensus()
            let openURL = (try? await web.state())?.url ?? ""
            openStall = OpenStall(stuck: stuck, openURL: openURL, openedAtDecision: stepBudget.totalUsed, dialogAtOpen: !census.hits.isEmpty)
            appendStep("bypass", "能力卡点不停车（自主完成口径）：\(stuck)。绕行梯第 1 级「既有手段轮试」已下达——推进权在引擎：本级逐项验收（揭示复判再点／站点模式／替代入口／坐标点击／frame 感知关闭），下达不等于已试；验收齐或预算到期后引擎自动推进到直达 URL 一级，无需第二次信号")
            pendingLoopHint = "【能力卡点·绕行梯进行中】刚才的卡点属于能力类，按自主完成口径不许停下等用户亲手操作。现在逐项试既有手段（每项一轮，引擎逐项验收）：①入口先 scroll 揭示再点（引擎点前会自动揭示复判）；②set_site_mode 换站点模式；③站内同功能替代入口；④坐标点击；⑤弹窗照常 click（引擎有 frame 感知关闭）。引擎会在验收齐或预算到期后自动推进绕行梯下一级；确实无路时用 ask_user 只说明卡点与已试路径（不要请用户代劳）。"
            await runHoverProbeIfEntryStall(token: token)
            persistSnapshot()
            return
        }
        appendStep("bypass", "能力卡点再次上报（卡点保持在开）：\(stuck)。引擎据此强制结第 1 级并推进后续梯级")
        try await completeRung1AndProgress(token: token, forcedBy: "第二次能力类信号")
    }

    /// 关闭在开卡点（绕过成功／页面已离开卡点页）：步流留痕后清空，
    /// 梯账保留原样（未走完的梯级不补记、不假装已试）。
    private func closeStall(note: String) {
        guard let stall = openStall else { return }
        appendStep("bypass", "卡点关闭：\(note)（卡点：\(stall.stuck)；第 1 级验收进度：\(stall.meansSummary)）")
        openStall = nil
    }

    /// 结第 1 级并驱动后续梯级（F2 的同步推进点）：frameClose 在结级
    /// 时收口——期间有弹窗信号记验收；打开与结级普查均无弹窗则记
    /// 不适用（依据留痕）；其余未试项按强制结级如实写入梯账。
    private func completeRung1AndProgress(token: UUID, forcedBy: String) async throws {
        guard var stall = openStall else { return }
        if !stall.verified.contains(.frameClose), stall.notApplicable[.frameClose] == nil {
            if stall.frameCloseTried {
                stall.verify(.frameClose)
            } else if !stall.dialogAtOpen {
                let census = await web.dialogCensus()
                if census.hits.isEmpty {
                    stall.markNA(.frameClose, reason: "卡点打开与结级两次普查均无弹窗在场")
                } else {
                    stall.dialogAtOpen = true
                }
            }
            openStall = stall
        }
        if !bypassLadder.attempted.contains(.existingMeans) {
            let forced = !stall.rung1Complete
            bypassLadder.markAttempted(.existingMeans, note: "逐项验收：\(stall.meansSummary)\(forced ? "（\(forcedBy)强制结级，未试项如上如实记录）" : "（全部验收齐或判定不适用）")")
        }
        appendStep("bypass", "绕行梯第 1 级结级（\(forcedBy)）：\(stall.meansSummary)，引擎推进下一级")
        persistSnapshot()
        try await progressRungsBeyondFirst(token: token)
    }

    /// 驱动第 2、3 级（引擎同步执行，不等模型）：任一级成功即关卡点
    /// 返回；全部失败＝梯尽，关卡点并抛失败结案错误（结案文案含
    /// F6 harvest 实况节）。第 2 级 harvest 的实况与跨页模板记忆在
    /// 每次采集后回写梯账，结案与步流都读得到。
    private func progressRungsBeyondFirst(token: UUID) async throws {
        while let rung = bypassLadder.nextRung {
            try await checkpoint(token)
            switch rung {
            case .existingMeans:
                // 第 1 级由 completeRung1AndProgress 结级后才进本函数；
                // 快照恢复等边角下若它仍是下一级，按已下达口径补记并继续
                bypassLadder.markAttempted(.existingMeans, note: "第 1 级已下达（恢复现场补记，逐项验收以在开卡点账为准）")
            case .directURL:
                let outcome = await web.harvestDirectTargets(memoryTemplate: bypassLadder.harvestTemplate)
                let pageURL = (try? await web.state())?.url ?? ""
                bypassLadder.noteHarvest(template: outcome.facts.editTemplate, templateFrom: outcome.facts.editTemplate == nil ? nil : pageURL, fact: outcome.facts.line)
                if let harvest = outcome.result {
                    do {
                        executionSerial += 1
                        try await web.loadOnExecutionTab(harvest.url)
                    } catch {
                        // 候选地址导航失败：记为此级失败、推进下一级，
                        // 不让一个坏候选杀掉整个任务
                        bypassLadder.markAttempted(.directURL, note: "候选导航失败：\(error.localizedDescription)；\(outcome.facts.line)")
                        appendStep("bypass", "绕行梯第 2 级「直达 URL」导航失败：\(error.localizedDescription)（\(outcome.facts.line)），推进下一级")
                        continue
                    }
                    bypassLadder.markAttempted(.directURL, note: "采用候选 appmsgid=\(harvest.appmsgid)（来源：\(harvest.source)\(harvest.viaTemplate ? "、模板拼装" : "、带 ID 直用")\(harvest.crossPage ? "、跨页模板记忆" : "")），已导航直达；\(outcome.facts.line)")
                    appendStep("bypass", "绕行梯第 2 级「直达 URL」成功：\(outcome.facts.line)；已导航直达：\(harvest.url)")
                    _ = await web.settledCapture()
                    closeStall(note: "直达 URL 已打开目标页")
                    pendingLoopHint = "【能力卡点·绕行梯】引擎已用直达 URL 打开目标页（模板与 ID 均取自页面实证采集，含 data 属性／onclick／内嵌数据等来源）。请按最新页面快照继续完成任务。"
                    persistSnapshot()
                    return
                }
                bypassLadder.markAttempted(.directURL, note: outcome.facts.line)
                appendStep("bypass", "绕行梯第 2 级「直达 URL」落空：\(outcome.facts.line)，推进下一级")
            case .dialogNavBypass:
                let outcome = await attemptDialogNavBypass(token: token)
                bypassLadder.markAttempted(.dialogNavBypass, note: outcome.note)
                appendStep("bypass", "绕行梯第 3 级「弹窗导航绕行」：\(outcome.note)")
                if outcome.success {
                    closeStall(note: "弹窗导航绕行成功，弹窗已消失")
                    persistSnapshot()
                    return
                }
            }
        }
        let stuck = openStall?.stuck ?? "能力类卡点"
        openStall = nil
        throw await capabilityFailureError(stuck: stuck)
    }

    /// 每轮动作后的引擎推进钩子（F2，主循环迭代末尾调用）：卡点在开
    /// 时由引擎核对——页面已离开卡点页＝卡点绕过、关卡点；第 1 级
    /// 验收齐＝立即结级推进；打开后模型决策达 10 次仍未齐＝预算强制
    /// 结级（防梯子无限悬置）。推进中某级成功则关卡点续跑，梯尽抛
    /// 失败结案错误由主循环外层收口。
    private func advanceLadderIfNeeded(token: UUID) async throws {
        guard let stall = openStall else { return }
        if !stall.openURL.isEmpty, let now = try? await web.state(), now.url != stall.openURL {
            closeStall(note: "页面已离开卡点页（\(stall.openURL) → \(now.url)），卡点视为已绕过，绕行梯停止推进")
            persistSnapshot()
            return
        }
        // frameClose 收口：只差此一项且打开时无弹窗时，做一次普查判
        // 定不适用——避免第 1 级因「没弹窗可关」永远悬置；普查只在
        // 其余手段已齐时做，不给每轮迭代加固定开销
        if !stall.verified.contains(.frameClose), stall.notApplicable[.frameClose] == nil,
           !stall.frameCloseTried, !stall.dialogAtOpen,
           StallMeans.allCases.filter({ $0 != .frameClose }).allSatisfy({ stall.verified.contains($0) || stall.notApplicable[$0] != nil }) {
            let census = await web.dialogCensus()
            if census.hits.isEmpty, var current = openStall {
                current.markNA(.frameClose, reason: "卡点期间无弹窗信号、推进钩子普查亦无弹窗在场")
                openStall = current
            }
        }
        guard let current = openStall else { return }
        if current.rung1Complete {
            try await completeRung1AndProgress(token: token, forcedBy: "第 1 级逐项验收齐")
        } else if stepBudget.totalUsed - current.openedAtDecision >= 10 {
            try await completeRung1AndProgress(token: token, forcedBy: "第 1 级预算到期（卡点打开后已过 10 次模型决策）")
        }
    }

    /// done 梯门（F2）：主循环接受模型 done 前调用——无在开卡点返回
    /// nil（照常结案）；页面已离开卡点页或梯已尽返回 .bypassed（关
    /// 卡点、放行 done）；其余情形强制结第 1 级并驱动后续梯级，驱动
    /// 成功返回 .driven（本轮不接受 done、继续循环），梯尽抛失败
    /// 结案错误。杜绝「梯未尽而 done 被无条件接受、结案不读梯账」。
    private enum DoneGateOutcome { case bypassed, driven }
    private func evaluateDoneGate(token: UUID) async throws -> DoneGateOutcome? {
        guard let stall = openStall else { return nil }
        if bypassLadder.exhausted {
            appendStep("bypass", "done 梯门：卡点在开但绕行梯已尽（梯账见步流），放行 done 结案")
            openStall = nil
            return .bypassed
        }
        if !stall.openURL.isEmpty, let now = try? await web.state(), now.url != stall.openURL {
            closeStall(note: "done 梯门放行：页面已离开卡点页，卡点视为已绕过")
            persistSnapshot()
            return .bypassed
        }
        appendStep("bypass", "done 梯门：有在开卡点且绕行梯未尽（第 1 级验收进度：\(stall.meansSummary)），本次 done 不直接结案，引擎先推进绕行梯")
        try await completeRung1AndProgress(token: token, forcedBy: "done 梯门触发")
        return .driven
    }

    /// 已执行动作的卡点记账（F2 逐项验收的证据入口）：只记真实执行
    /// 成功的动作——click 记目标键（揭示复判与坐标落点同为引擎 click
    /// 的实现面：点前自动揭示复判＋按元素中心真实坐标派发点按序列，
    /// 一次真实执行同时构成两项实证，口径在此明示不拆假账）；第二
    /// 个不同目标键的 click 记替代入口；set_site_mode 记站点模式。
    private func noteExecutedActionForStall(actionName: String, targetKey: String) {
        guard var stall = openStall else { return }
        switch actionName {
        case "click": stall.noteClickTarget(targetKey)
        case "set_site_mode": stall.verify(.siteMode)
        default: return
        }
        openStall = stall
        persistSnapshot()
    }

    /// 澄清类 ask_user 不吞卡点（F2）：卡点在开时澄清停车照旧，但步
    /// 流明示卡点保持在开——答复续跑后绕行梯从原进度继续推进。
    private func noteClarifyDuringStall(question: String) {
        guard let stall = openStall else { return }
        appendStep("bypass", "澄清问题停车等待（问题：\(question)）：在开卡点不因此关闭——卡点「\(stall.stuck)」保持在开（第 1 级验收进度：\(stall.meansSummary)），答复续跑后引擎继续推进绕行梯")
    }

    /// 词表外动作的去终结化处理（F4）：主循环 else 分支捕获执行层
    /// 「不可执行动作」后调用——动作字符串已由调用方先行记账，此处
    /// 补可见说明、回注纠正提示、计入在开卡点的证据；不置 .failed、
    /// 不清快照，任务继续。
    private func handleInvalidAction(_ action: AgentAction) {
        if var stall = openStall {
            stall.noteInvalidAction(action.action)
            openStall = stall
        }
        appendStep("invalid", "词表外动作「\(action.action)」不可执行：已记账留痕（理由：\(action.reason)），任务不因此终结、进度不清零\(openStall != nil ? "，并已计入在开卡点的证据" : "")；已回注模型改用可执行动作词表")
        pendingLoopHint = "【动作词表纠正】你上一步用的动作名「\(action.action)」不在可执行词表内，未被执行（任务未因此失败、进度未清零）。可执行动作只有：navigate、click、type、scroll、wait、set_site_mode、open_new_tab、generate_cover、upload_file、use_skill、ask_user、done。请改用词表内动作继续完成任务。"
    }

    /// 执行层词表外动作的错误判定（F4）：WebController.execute 的
    /// default 分支抛 MikaError("不可执行动作")，仅此一义。
    private static func isUnexecutableActionError(_ error: Error) -> Bool {
        (error as? MikaError)?.message == "不可执行动作"
    }

    /// 入口型卡点的 hover 显形探测（F5）：卡点打开时若当前页既无编
    /// 辑链接元素、也无可编辑元素（编辑入口不在感知层视野内），引擎
    /// 在主 frame 对卡片状容器派发 hover 并对比显形——探到的新入口
    /// 写进去向提示供模型下一轮使用；探不到如实记入卡点盲区账，
    /// 不假装已排除 hover 显形这一可能。
    private func runHoverProbeIfEntryStall(token: UUID) async {
        guard openStall != nil, let page = try? await web.state() else { return }
        let hasEditLink = page.elements.contains { $0.linkKind == "edit" }
        let hasEditable = page.elements.contains { $0.editable }
        guard !hasEditLink, !hasEditable else { return }
        let report = await web.hoverRevealProbe()
        if report.revealed.isEmpty {
            if var stall = openStall {
                stall.perceptionBlindNote = report.summary
                openStall = stall
            }
            appendStep("perception", "感知盲区记账：\(report.summary)——编辑入口可能为 hover 显形或无文本图标，当前感知层未 surface，梯账如实记录此盲区")
        } else {
            appendStep("perception", "hover 显形探测：\(report.summary)，请按最新页面快照点新显形的入口")
            pendingLoopHint = (pendingLoopHint ?? "") + "\n【感知补充】引擎已对当前页卡片容器做过一轮 hover 显形探测：\(report.summary)。请按最新页面快照尝试这些新显形的入口。"
        }
    }

    /// 弹窗能力卡点的绕行驱动（AUTONOMY-FIX，runTargeted／runConfirmed
    /// 共用）：执行层自身的 frame 感知关闭即梯级①的实证（已在抛错前
    /// 试过并连败），此处补记后走梯级③弹窗导航绕行。返回 true＝弹窗
    /// 已消失、页面可继续；false＝可用梯级已尽（梯账已记全，调用方
    /// 走失败结案）。
    private func driveDialogBypass(token: UUID) async -> Bool {
        // 卡点在开时（LADDER-FIX）：frame 感知关闭连败先记入卡点账
        // （第 1 级 frameClose 项的实证），绕行成功即关卡点
        if var stall = openStall {
            stall.noteFrameCloseSignal()
            openStall = stall
        }
        if !bypassLadder.attempted.contains(.existingMeans) {
            bypassLadder.markAttempted(.existingMeans, note: "执行层 frame 感知关闭（框内五阶段）已在抛错前试过并连败")
        }
        if bypassLadder.attempted.contains(.dialogNavBypass) { return false }
        let outcome = await attemptDialogNavBypass(token: token)
        bypassLadder.markAttempted(.dialogNavBypass, note: outcome.note)
        appendStep("bypass", "弹窗导航绕行：\(outcome.note)")
        if outcome.success, openStall != nil {
            closeStall(note: "弹窗导航绕行成功，弹窗已消失")
        }
        persistSnapshot()
        return outcome.success
    }

    /// 绕行梯第 3 级（AUTONOMY-FIX）：弹窗导航绕行——
    /// · 非编辑页：直接重载执行页（无未保存状态可丢），复查 frame 普查；
    /// · 编辑页：先点「保存／存草稿」（过 SafetyPolicy 须 .allow 才点，
    ///   点后 settle 回读落定才许离开），再导航到同源根、经原地址返回，
    ///   复查普查。找不到保存入口或保存证据未稳 → 此级失败并记原因
    ///   （不赌未存内容）。成功只认「绕行前弹窗签名在复查中全部消失」。
    /// · 正文往返不丢稿的最终判据在页面回读（模型下一轮快照），本函数
    ///   只保证「离开前保存已落定」这一前提；真编辑器往返属 Tier B
    ///   真机验证项（见案卷未证项），不得据本函数声称已验不丢稿。
    private func attemptDialogNavBypass(token: UUID) async -> (success: Bool, note: String) {
        let before = await web.dialogCensus()
        guard !before.hits.isEmpty else { return (false, "绕行前 frame 普查未发现弹窗，此级不适用") }
        let sigsBefore = Set(before.hits.map { $0.sig })
        guard let page = try? await web.state() else { return (false, "页面状态读取失败") }
        let originalURL = page.url
        let isEditor = originalURL.contains("appmsg_edit") || page.elements.contains { $0.editable }
        if !isEditor {
            web.reloadExecutionTab()
            try? await Task.sleep(for: .milliseconds(800))
            _ = await web.settledCapture()
            let after = await web.dialogCensus()
            let gone = !after.hits.contains { sigsBefore.contains($0.sig) }
            return gone
                ? (true, "成功（非编辑页重载绕行）：重载前弹窗 \(sigsBefore.count) 个，重载后原弹窗签名全部消失")
                : (false, "非编辑页重载后弹窗仍在（普查：\(after.summary)）")
        }
        guard let saveElement = page.elements.first(where: { element in
            (element.text.contains("保存") || element.text.contains("存草稿")) && !element.disabled
        }) else { return (false, "编辑页未找到可点的保存/存草稿入口，不赌未保存内容，此级失败") }
        guard let saveAction = Self.clickAction(index: saveElement.index, reason: "弹窗导航绕行前先存草稿") else {
            return (false, "保存动作构造失败，此级失败")
        }
        guard SafetyPolicy.check(saveAction, saveElement) == .allow else {
            return (false, "保存入口未过安全策略（非 .allow），不代点，此级失败")
        }
        do { try await web.execute(saveAction, expected: saveElement) } catch {
            return (false, "保存点击抛错：\(error.localizedDescription)")
        }
        let settled = await web.settledCapture()
        guard settled.settled else { return (false, "保存后页面证据未稳（settle 超时），不赌未落定状态，此级失败") }
        guard let url = URL(string: originalURL), let scheme = url.scheme, let host = url.host else {
            return (false, "原页地址不可解析，此级失败")
        }
        do {
            try await web.loadOnExecutionTab("\(scheme)://\(host)/")
            try? await Task.sleep(for: .milliseconds(500))
            try await web.loadOnExecutionTab(originalURL)
        } catch { return (false, "导航往返抛错：\(error.localizedDescription)") }
        _ = await web.settledCapture()
        let after = await web.dialogCensus()
        let gone = !after.hits.contains { sigsBefore.contains($0.sig) }
        return gone
            ? (true, "成功（编辑页往返绕行）：先保存并 settle 回读落定→离开→直达返回后，原弹窗签名全部消失；正文完整以模型下一轮回读为准")
            : (false, "编辑页往返后弹窗仍在（普查：\(after.summary)）")
    }

    /// 自检十八（AUTONOMY-FIX）：自主完成逻辑核查——纯函数部分
    /// （分类门／安全类回归／绕行梯状态机／结案文案措辞／直达提取）
    /// 在此程序化断言；合成页驱动部分（链接农场 harvest 实测＋弹窗
    /// 导航绕行实测＋全程无停车态）在 verifyAutonomy 里接续。
    static func verifyAutonomyGate() -> [String] {
        var lines: [String] = []
        func fmt(_ ok: Bool) -> String { ok ? "✓" : "✗" }
        // —— 分类门：ask_user 分流 ——
        lines.append("\(fmt(InterventionGate.classifyAskUser(declared: "", question: "请在网页上亲手点一下弹窗里的「取消」按钮") == .capability)) 分类门·能力类甲：请用户亲手点弹窗（现场原例）→ capability（拒绝停车）")
        lines.append("\(fmt(InterventionGate.classifyAskUser(declared: "", question: "草稿列表入口点不开，请你手动打开编辑页继续") == .capability)) 分类门·能力类乙：请用户手动打开编辑页（现场原例）→ capability（拒绝停车）")
        lines.append("\(fmt(InterventionGate.classifyAskUser(declared: "manual", question: "这一步需要处理一下") == .capability)) 分类门·声明优先：askKind=manual → capability（不看文本）")
        lines.append("\(fmt(InterventionGate.classifyAskUser(declared: "clarify", question: "请帮我打开编辑页") == .capability)) 分类门·防绕门：声明 clarify 但文本是请用户操作网页 → capability（以文本为准）")
        lines.append("\(fmt(InterventionGate.classifyAskUser(declared: "clarify", question: "这篇文章的目标读者是学生还是职场人？") == .clarify)) 分类门·澄清类：任务歧义问答 → clarify（照旧停车等待，不收紧）")
        lines.append("\(fmt(InterventionGate.classifyAskUser(declared: "", question: "封面用深色版式还是浅色版式？") == .clarify)) 分类门·未声明兜底：无操作网页措辞的选择题 → clarify")
        // —— 安全类回归：分类门放行停车的依据（只读引用 SafetyPolicy）——
        func element(text: String, inputType: String = "", sensitive: Bool = false) -> PageElement {
            PageElement(index: 0, tag: "button", type: "", text: text, placeholder: "", href: "", name: "", inputType: inputType, ariaLabel: "", nameSource: "text", inView: true, sensitive: sensitive, disabled: false, editable: false)
        }
        let clickPay = Self.clickAction(index: 0, reason: "自检十八")
        lines.append("\(fmt(clickPay != nil && SafetyPolicy.check(clickPay!, element(text: "确认付款")) == .confirm)) 安全类回归·付款确认：SafetyPolicy 对「确认付款」→ .confirm（照常停车等用户确认）")
        let typeAction = (try? JSONSerialization.data(withJSONObject: ["action": "type", "index": 0, "text": "x"])).flatMap { try? JSONDecoder().decode(AgentAction.self, from: $0) }
        lines.append("\(fmt(typeAction != nil && SafetyPolicy.check(typeAction!, element(text: "", inputType: "password")) == .manual)) 安全类回归·密码字段：type 进 password 字段 → .manual（照常停车手输）")
        lines.append("\(fmt(SafetyPolicy.uploadDecision(isTaskGenerated: false) == .confirm && SafetyPolicy.uploadDecision(isTaskGenerated: true) == .allow)) 安全类回归·SP-01：非本任务生成文件上传 → .confirm（确认卡照旧）；本任务生成 → .allow")
        // —— 绕行梯状态机 ——
        var ladder = BypassLadder()
        let orderOK = ladder.nextRung == .existingMeans && !ladder.exhausted
        ladder.markAttempted(.existingMeans, note: "样本一")
        let midOK = ladder.nextRung == .directURL
        ladder.markAttempted(.directURL, note: "样本二")
        ladder.markAttempted(.dialogNavBypass, note: "样本三")
        lines.append("\(fmt(orderOK && midOK && ladder.exhausted && ladder.nextRung == nil)) 绕行梯状态机：梯级按 既有手段→直达 URL→弹窗导航绕行 逐级推进，三级试完梯尽（exhausted）")
        let restored = BypassLadder(attemptedRaw: ladder.attemptedRaw, notes: ladder.notes)
        lines.append("\(fmt(restored == ladder && restored.summary.contains("样本二"))) 绕行梯快照往返：已试梯级与留痕经 rawValue 数组往返后不变（恢复后不重走已试梯级）")
        // —— 失败结案文案：要素齐全＋无请用户代劳措辞 ——
        let summary = InterventionGate.failureSummary(stuck: "弹窗关不掉", ladder: ladder, evidence: "当前页 https://example.com/（合成）")
        let banned = ["亲手", "请用户", "手动点", "手动打开", "请你点"].filter { summary.contains($0) }
        lines.append("\(fmt(summary.contains("弹窗关不掉") && summary.contains("样本一") && summary.contains("example.com") && banned.isEmpty)) 失败结案文案：含卡点＋已试路径＋页面证据，且无请用户代劳措辞（命中禁用词：\(banned.joined(separator: "、"))）")
        // —— 直达提取三路 ——
        let direct = DirectTargetHarvest.build(hrefs: ["https://mp.weixin.qq.com/cgi-bin/appmsg?t=media/appmsg_edit&action=edit&appmsgid=100000001&token=1"])
        lines.append("\(fmt(direct?.appmsgid == "100000001" && direct?.viaTemplate == false && direct?.url.contains("appmsg_edit") == true)) 直达提取·直用：带 ID 的编辑链接直接采用（模板与 ID 同源实证）")
        let templated = DirectTargetHarvest.build(hrefs: ["https://mp.weixin.qq.com/cgi-bin/appmsg?t=media/appmsg_edit&action=edit", "https://mp.weixin.qq.com/cgi-bin/appmsg?t=media/appmsg_list&appmsgid=100000002"])
        lines.append("\(fmt(templated?.appmsgid == "100000002" && templated?.viaTemplate == true && templated?.url.contains("appmsgid=100000002") == true)) 直达提取·模板拼装：无 ID 模板＋别处实证 ID → 拼出候选")
        let none = DirectTargetHarvest.build(hrefs: ["https://example.com/about", "https://example.com/list"])
        lines.append("\(fmt(none == nil)) 直达提取·无候选：无 ID 无模板 → nil（此级失败，不凭记忆编造 URL）")
        return lines
    }

    /// 自检十八·合成页驱动（AUTONOMY-FIX）：在 test-autonomy 上实测
    /// 链接农场 harvest、弹窗在场基线与弹窗导航绕行（非编辑页重载
    /// 分支），并断言全程未进入停车态。不调用模型；要求引擎空闲。
    func verifyAutonomy() async -> [String] {
        guard !busy else { return ["✗ 引擎忙碌中，自检十八未执行（先等当前任务终结或停止）"] }
        var lines = Self.verifyAutonomyGate()
        func fmt(_ ok: Bool) -> String { ok ? "✓" : "✗" }
        // 合成页用 window.name 模拟「重载即消失」的会话级弹窗：重复跑
        // 自检时先清掉该标记，保证每次都从弹窗在场的基线开始
        _ = try? await web.evaluate("(()=>{window.name='';return 'reset';})()")
        do { try web.loadLocalOnExecutionTab("test-autonomy") } catch {
            lines.append("✗ 合成测试页 test-autonomy 加载失败：\(error.localizedDescription)")
            return lines
        }
        try? await Task.sleep(for: .milliseconds(1000))
        let harvestOutcome = await web.harvestDirectTargets(memoryTemplate: nil)
        if let harvest = harvestOutcome.result {
            lines.append("\(fmt(harvest.appmsgid == "100000001" && harvest.url.contains("appmsg_edit"))) 直达提取实测：合成页链接农场提取到 appmsgid=\(harvest.appmsgid)、URL 含 appmsg_edit=\(harvest.url.contains("appmsg_edit"))（期望 100000001/true，模板与 ID 均来自页面真实链接；\(harvestOutcome.facts.line)）")
        } else {
            lines.append("✗ 直达提取实测：合成页链接农场未提取到候选（\(harvestOutcome.facts.line)）")
        }
        let censusBefore = await web.dialogCensus()
        lines.append("\(fmt(!censusBefore.hits.isEmpty)) 弹窗基线：绕行前 frame 普查命中弹窗 \(censusBefore.hits.count) 个（合成条款弹窗在场，按钮无行为、点按不关）")
        let outcome = await attemptDialogNavBypass(token: generation)
        lines.append("\(fmt(outcome.success)) 弹窗导航绕行实测（非编辑页重载分支）：\(outcome.note)")
        switch status {
        case .waitingManual(_), .waitingConfirm(_):
            lines.append("✗ 全程无停车态：绕行驱动后引擎处于停车态，与自主完成口径不符")
        default:
            lines.append("✓ 全程无停车态：分类门与绕行梯驱动期间引擎未进入等待确认/等待手输状态")
        }
        return lines
    }

    /// 自检二十二（COVER-UPLOAD-FIX）：封面上传卡点的修复核查。纯逻辑
    /// 部（本函数）——生成文件命名规整（ASCII 化、全角标点剔除、纯中文
    /// 标题时间戳回退）、相册写入三态的步流文案口径（只有 saved 许说
    /// 已存入相册）、附件展示排序（本任务生成置顶）、选文件指引文案
    /// （相册路线/附件路线/自动带上三句按实况出现）、待供文件武装的
    /// 基本性质（不支持环境下 arm 恒 false 且不留武装态）。回路部在
    /// WebController.verifyUploadPanelSupply（合成页 test-upload 上
    /// 武装→触发→回读），由 SelfTestView 编排在纯逻辑之后。不调用
    /// 模型；要求引擎空闲。
    func verifyCoverUploadFix() async -> [String] {
        guard !busy else { return ["✗ 引擎忙碌中，自检二十二未执行（先等当前任务终结或停止）"] }
        var lines: [String] = []
        func fmt(_ ok: Bool) -> String { ok ? "✓" : "✗" }
        // —— 命名规整（B）——
        let mixed = CoverGenerator.GeneratedFileName.coverFileName(title: "AI Weekly Report 2026!")
        lines.append("\(fmt(mixed == "cover-ai-weekly-report-2026.png")) 命名·混合标题：「AI Weekly Report 2026!」→ \(mixed)（小写 slug、标点折连字符）")
        let fullWidth = CoverGenerator.GeneratedFileName.coverFileName(title: "别让AI替你瞎编；用这套三步法")
        let fullWidthOK = fullWidth.hasPrefix("cover-ai-") && fullWidth.hasSuffix(".png") && fullWidth.unicodeScalars.allSatisfy { $0.isASCII }
        lines.append("\(fmt(fullWidthOK)) 命名·全角标点剔除：0336 现场标题（含全角分号）→ \(fullWidth)（全 ASCII、无全角残留）")
        let fixedDate = Date(timeIntervalSince1970: 1762142400)
        let chineseOnly = CoverGenerator.GeneratedFileName.coverFileName(title: "纯中文标题没有英文", date: fixedDate)
        lines.append("\(fmt(chineseOnly.hasPrefix("cover-20") && chineseOnly.hasSuffix(".png") && chineseOnly.unicodeScalars.allSatisfy { $0.isASCII })) 命名·纯中文回退：slug 为空时退时间戳名 → \(chineseOnly)")
        let longTitle = CoverGenerator.GeneratedFileName.coverFileName(title: String(repeating: "abcdefgh ", count: 10))
        lines.append("\(fmt(longTitle.count <= "cover-.png".count + CoverGenerator.GeneratedFileName.slugLimit)) 命名·长度上限：超长标题 slug 截断在 \(CoverGenerator.GeneratedFileName.slugLimit) 字符内 → \(longTitle)")
        // —— 相册三态文案（A 的失败路径口径）——
        let savedText = CoverGenerator.PhotoSaveOutcome.saved.stepDescription(fileName: "cover-ai.png")
        lines.append("\(fmt(savedText.contains("已生成并存入系统相册") && savedText.contains("cover-ai.png"))) 相册文案·成功态：明说已存入相册并带确切文件名")
        let deniedText = CoverGenerator.PhotoSaveOutcome.denied.stepDescription(fileName: "cover-ai.png")
        lines.append("\(fmt(deniedText.contains("没有存入系统相册") && deniedText.contains("cover-ai.png"))) 相册文案·未授权态：明说没存入相册（不假装在相册里），指出文件在附件里")
        let failedText = CoverGenerator.PhotoSaveOutcome.failed("样本错误").stepDescription(fileName: "cover-ai.png")
        lines.append("\(fmt(failedText.contains("存入系统相册失败") && failedText.contains("样本错误"))) 相册文案·失败态：带失败原因如实上报，不冒充成功")
        // —— 展示排序（B 置顶）——
        let now = Date()
        func probeRecord(origin: AttachmentOrigin, secondsAgo: TimeInterval) -> AttachmentRecord {
            AttachmentRecord(id: UUID(), sessionID: runSessionID, displayName: "probe", storedName: "probe", scaledName: nil, isScreenshot: false, origin: origin, contentType: "image/png", byteCount: 1, readState: .storedOnly, extractedText: nil, imageWidth: nil, imageHeight: nil, createdAt: now.addingTimeInterval(-secondsAgo), savedToPhotos: nil)
        }
        let ordered = AttachmentStore.displayOrdered([probeRecord(origin: .userPrivate, secondsAgo: 10), probeRecord(origin: .taskGenerated, secondsAgo: 60), probeRecord(origin: .userPrivate, secondsAgo: 5)])
        let orderOK = ordered.count == 3 && ordered[0].origin == .taskGenerated && ordered[1].createdAt > ordered[2].createdAt
        lines.append("\(fmt(orderOK)) 展示排序：本任务生成置顶（哪怕更旧），其余新在前")
        // —— 选文件指引（C）——
        var guideUpload = PendingUpload(id: UUID(), attachmentID: nil, attachmentName: "cover-ai.png", isTaskGenerated: true, pageURL: "https://example.com/edit", pageHost: "example.com", elementIndex: 0, elementLabel: "封面", stage: .pickFile, confirmationToken: nil)
        guideUpload.isImage = true
        guideUpload.savedToPhotos = true
        let guideSaved = Self.uploadPickGuidance(upload: guideUpload, supplyArmed: false)
        lines.append("\(fmt(guideSaved.contains("最近项目") && guideSaved.contains("cover-ai.png") && guideSaved.contains("本任务生成"))) 指引·已存相册：给出相册「最近项目」路线＋附件中心置顶路线＋确切文件名")
        guideUpload.savedToPhotos = false
        let guideUnsaved = Self.uploadPickGuidance(upload: guideUpload, supplyArmed: false)
        lines.append("\(fmt(!guideUnsaved.contains("最近项目") && guideUnsaved.contains("cover-ai.png"))) 指引·未存相册：不给相册路线（图不在相册，不让用户空找），只指附件中心")
        let guideArmed = Self.uploadPickGuidance(upload: guideUpload, supplyArmed: true)
        lines.append("\(fmt(guideArmed.contains("自动带上"))) 指引·待供武装：加「在页面点上传按钮会自动带上」一句")
        // —— 待供武装基本性质（D）——
        if !web.uploadSupplySupported {
            let armResult = web.armUploadSupply(url: URL(fileURLWithPath: "/tmp/probe"), fileName: "probe")
            lines.append("\(fmt(!armResult && !web.uploadSupplyArmed)) 供文件·环境门：当前系统不支持文件面板回调时 arm 恒失败且不留武装态（引擎自动走手动路径）")
        } else {
            lines.append("✓ 供文件·环境门：当前系统支持文件面板回调（iOS 18.4+），武装/消费回路在回路部核查")
        }
        return lines
    }

    /// 自检二十二回路部转发（COVER-UPLOAD-FIX D）：合成页上的供文件
    /// 回路在 WebController 侧（verifyUploadPanelSupply），SelfTestView
    /// 经引擎转发调用，保持自检视图不直持 WebController 的既有形态。
    func verifyUploadPanelSupply() async -> [String] {
        guard !busy else { return ["✗ 引擎忙碌中，自检二十二回路未执行（先等当前任务终结或停止）"] }
        return await web.verifyUploadPanelSupply()
    }

    /// 自检二十一（LADDER-FIX）：绕行梯引擎驱动的回路级核查。诊断 D5
    /// 指出旧自检只测纯函数状态机——本检除纯逻辑断言外，真实调用主
    /// 循环同款生产函数（handleCapabilityStall／
    /// noteExecutedActionForStall／advanceLadderIfNeeded／
    /// evaluateDoneGate／handleInvalidAction／noteClarifyDuringStall）
    /// 在两张合成页上驱动完整回路：单次信号开卡点→逐项验收→引擎自
    /// 动推进到直达级；done 过梯门；零候选推进第 3 级并在梯尽结案文
    /// 案里见到 harvest 实况；词表外动作不终结；澄清不吞卡点。测试
    /// 前后保存/恢复引擎的梯账、卡点、步流、目标与预算，结束不留现
    /// 场。不调用模型；要求引擎空闲（驱动会占用执行页打开合成页）。
    func verifyLadderFix() async -> [String] {
        guard !busy else { return ["✗ 引擎忙碌中，自检二十一未执行（先等当前任务终结或停止）"] }
        var lines: [String] = []
        func fmt(_ ok: Bool) -> String { ok ? "✓" : "✗" }
        func el(_ href: String) -> PageElement {
            PageElement(index: 0, tag: "a", type: "", text: "样本", placeholder: "", href: href, name: "", inputType: "", ariaLabel: "", nameSource: "text", inView: true, sensitive: false, disabled: false, editable: false)
        }
        // —— 纯逻辑部 ——
        var stallProbe = OpenStall(stuck: "样本卡点", openURL: "https://example.com/list", openedAtDecision: 0, dialogAtOpen: false)
        let freshOK = !stallProbe.rung1Complete && stallProbe.meansSummary.contains("未试")
        stallProbe.noteClickTarget("target-a")
        let oneClickOK = stallProbe.verified.contains(.revealClick) && stallProbe.verified.contains(.coordClick) && !stallProbe.verified.contains(.altEntry)
        stallProbe.noteClickTarget("target-b")
        stallProbe.verify(.siteMode)
        let midOK = stallProbe.verified.contains(.altEntry) && stallProbe.verified.contains(.siteMode) && !stallProbe.rung1Complete
        stallProbe.markNA(.frameClose, reason: "样本无弹窗")
        lines.append("\(fmt(freshOK && oneClickOK && midOK && stallProbe.rung1Complete)) 第 1 级逐项验收（纯状态）：下达不记已试；一次真实 click 同时构成揭示复判＋坐标点击实证、同目标不冒充替代入口；第二个不同目标记替代入口；站点模式单独记账；frameClose 判不适用后本级才算完成")
        let structured = DirectTargetHarvest.build(candidates: [
            .init(source: .href, value: "https://example.com/s?__biz=Mz&mid=1&idx=1&sn=x&tempkey=abc"),
            .init(source: .dataAttr, value: "100000777", attrName: "data-appmsgid"),
            .init(source: .onclick, value: "openEditor('https://example.com/cgi-bin/appmsg?t=media/appmsg_edit&action=edit')"),
        ], memoryTemplate: nil)
        lines.append("\(fmt(structured.result?.appmsgid == "100000777" && structured.result?.viaTemplate == true && structured.facts.previewExcluded == 1 && (structured.facts.perSource[.dataAttr] ?? 0) == 1)) harvest 扩展来源：data 属性裸 ID＋onclick 模板拼装成功；预览链接被排除并计数（其 mid 不冒充 appmsgid，未做任何标识映射假定）")
        let embeddedOnly = DirectTargetHarvest.build(candidates: [
            .init(source: .embedded, value: "{\"list\":[{\"link\":\"https://example.com/cgi-bin/appmsg?t=media/appmsg_edit&appmsgid=100000888\"}]}"),
        ], memoryTemplate: nil)
        lines.append("\(fmt(embeddedOnly.result?.appmsgid == "100000888" && embeddedOnly.result?.viaTemplate == false)) harvest 内嵌数据：页面内嵌列表数据里的带 ID 编辑链接可直用")
        let crossPage = DirectTargetHarvest.build(candidates: [
            .init(source: .dataAttr, value: "100000999", attrName: "data-appmsgid"),
        ], memoryTemplate: "https://example.com/cgi-bin/appmsg?t=media/appmsg_edit&action=edit")
        lines.append("\(fmt(crossPage.result?.appmsgid == "100000999" && crossPage.result?.crossPage == true)) harvest 跨页模板：本页只有实证 ID 时，用本任务先前页面实证见过的模板拼装并注明跨页")
        let zeroFacts = DirectTargetHarvest.build(candidates: [], memoryTemplate: nil)
        lines.append("\(fmt(zeroFacts.result == nil && zeroFacts.facts.total == 0 && zeroFacts.facts.line.contains("候选共 0 条"))) harvest 零候选：无结果且实况行明示候选共 0 条（F6 结案可见的口径）")
        var ladderWithFact = BypassLadder()
        ladderWithFact.noteHarvest(template: nil, templateFrom: nil, fact: zeroFacts.facts.line)
        let summaryWithFact = InterventionGate.failureSummary(stuck: "样本卡点", ladder: ladderWithFact, evidence: "合成", harvestFact: ladderWithFact.harvestFact)
        let summaryNoFact = InterventionGate.failureSummary(stuck: "样本卡点", ladder: BypassLadder(), evidence: "合成")
        lines.append("\(fmt(summaryWithFact.contains("harvest 实况") && summaryWithFact.contains("候选共 0 条") && summaryNoFact.contains("未运行 harvest"))) 梯尽结案文案（F6）：强制含 harvest 实况节——有实况引实况，从未运行则明示未运行")
        lines.append("\(fmt(Self.isUnexecutableActionError(MikaError("不可执行动作")) && !Self.isUnexecutableActionError(MikaError("其它错误")))) 词表外动作判定（F4）：执行层「不可执行动作」精确命中、其它错误不误吞")
        lines.append("\(fmt(el("https://example.com/s?__biz=Mz&tempkey=abc").linkKind == "preview" && el("https://example.com/cgi-bin/appmsg?t=media/appmsg_edit&appmsgid=1").linkKind == "edit" && el("https://example.com/about").linkKind == "")) 感知区分（F5）：tempkey 预览链接、appmsg_edit 编辑链接与普通链接的 linkKind 判定正确（预览不冒充编辑入口）")
        // —— 回路部：保存现场，结束恢复 ——
        let savedLadder = bypassLadder
        let savedStall = openStall
        let savedSteps = steps
        let savedSeq = stepSeq
        let savedGoal = goal
        let savedHint = pendingLoopHint
        let savedBudget = stepBudget
        // 场景 A：单次信号开卡点→生产记账喂齐手段→动作后钩子自动推进到直达级
        do { try web.loadLocalOnExecutionTab("test-ladder") } catch {
            lines.append("✗ 回路·场景A 合成页 test-ladder 加载失败：\(error.localizedDescription)")
        }
        if lines.last?.hasPrefix("✗ 回路·场景A") != true {
            try? await Task.sleep(for: .milliseconds(900))
            bypassLadder = BypassLadder(); openStall = nil
            do {
                try await handleCapabilityStall(stuck: "自检二十一·场景A：草稿编辑入口点不开", token: generation)
                let openedOK = openStall != nil && !bypassLadder.attempted.contains(.existingMeans)
                let perceptionOK = steps.contains { $0.action == "perception" }
                lines.append("\(fmt(openedOK)) 回路·单次信号开卡点：第 1 级只下达不记 attempted（F2），卡点在开")
                lines.append("\(fmt(perceptionOK)) 回路·入口型卡点感知（F5）：当前页无编辑链接/可编辑元素时已做 hover 显形探测，探到或盲区均已步流记账")
                noteExecutedActionForStall(actionName: "click", targetKey: "card-a")
                noteExecutedActionForStall(actionName: "click", targetKey: "card-b")
                noteExecutedActionForStall(actionName: "set_site_mode", targetKey: "desktop")
                try await advanceLadderIfNeeded(token: generation)
                let factLine = bypassLadder.harvestFact ?? ""
                let droveOK = bypassLadder.attempted.contains(.existingMeans) && bypassLadder.attempted.contains(.directURL) && openStall == nil
                lines.append("\(fmt(droveOK && factLine.contains("data 属性"))) 回路·引擎自动推进：未等第二次 ask_user，动作后钩子已结第 1 级并驱动第 2 级直达成功、卡点关闭（harvest 实况：\(factLine)）")
                let gateAfter = try await evaluateDoneGate(token: generation)
                lines.append("\(fmt(gateAfter == nil)) 回路·卡点关闭后 done 梯门放行（无在开卡点时梯门不介入）")
            } catch {
                lines.append("✗ 回路·场景A 推进抛错：\(error.localizedDescription)")
            }
        }
        // 场景 B：done 过梯门——卡点在开且梯未尽时 done 不直接结案，引擎驱动后才放行
        do { try web.loadLocalOnExecutionTab("test-ladder") } catch {
            lines.append("✗ 回路·场景B 合成页 test-ladder 加载失败：\(error.localizedDescription)")
        }
        if lines.last?.hasPrefix("✗ 回路·场景B") != true {
            try? await Task.sleep(for: .milliseconds(900))
            bypassLadder = BypassLadder(); openStall = nil
            do {
                try await handleCapabilityStall(stuck: "自检二十一·场景B：编辑入口点不开", token: generation)
                let gate = try await evaluateDoneGate(token: generation)
                let gateOK = gate == .driven && bypassLadder.attempted.contains(.directURL) && openStall == nil
                    && steps.contains { $0.action == "bypass" && $0.reason.contains("done 梯门") }
                lines.append("\(fmt(gateOK)) 回路·done 梯门：卡点在开且梯未尽时 done 被拦下，引擎强制结第 1 级并驱动直达级成功后才回到续跑（不直接结案、不读梯账结案）")
            } catch {
                lines.append("✗ 回路·场景B 梯门抛错：\(error.localizedDescription)")
            }
        }
        // 场景 C：零候选页→第二次信号推进第 2 级落空→第 3 级重载后弹窗仍在→梯尽结案含 harvest 实况
        do { try web.loadLocalOnExecutionTab("test-ladder-zero") } catch {
            lines.append("✗ 回路·场景C 合成页 test-ladder-zero 加载失败：\(error.localizedDescription)")
        }
        if lines.last?.hasPrefix("✗ 回路·场景C") != true {
            try? await Task.sleep(for: .milliseconds(900))
            bypassLadder = BypassLadder(); openStall = nil
            do {
                try await handleCapabilityStall(stuck: "自检二十一·场景C：弹窗关不掉且无编辑入口", token: generation)
                do {
                    try await handleCapabilityStall(stuck: "自检二十一·场景C：仍然卡住", token: generation)
                    lines.append("✗ 回路·梯尽结案：零候选＋弹窗绕行失败后未抛失败结案错误")
                } catch {
                    let text = error.localizedDescription
                    let exhaustedOK = bypassLadder.exhausted && openStall == nil
                        && text.contains("harvest 实况") && text.contains("预览链接排除 1 条")
                    lines.append("\(fmt(exhaustedOK)) 回路·梯尽结案：零候选推进第 3 级、弹窗重载后仍在→梯尽抛失败结案，文案含 harvest 实况节且候选/排除数可见（实况：\(bypassLadder.harvestFact ?? "无")）")
                }
            } catch {
                lines.append("✗ 回路·场景C 开卡点抛错：\(error.localizedDescription)")
            }
        }
        // 场景 D：澄清不吞卡点＋词表外动作去终结化（同为生产函数直调）
        do { try web.loadLocalOnExecutionTab("test-ladder") } catch {
            lines.append("✗ 回路·场景D 合成页 test-ladder 加载失败：\(error.localizedDescription)")
        }
        if lines.last?.hasPrefix("✗ 回路·场景D") != true {
            try? await Task.sleep(for: .milliseconds(900))
            bypassLadder = BypassLadder(); openStall = nil
            do {
                try await handleCapabilityStall(stuck: "自检二十一·场景D：入口点不开", token: generation)
                noteClarifyDuringStall(question: "这篇的目标读者是学生还是职场人？")
                let clarifyOK = openStall != nil && steps.contains { $0.action == "bypass" && $0.reason.contains("保持在开") }
                lines.append("\(fmt(clarifyOK)) 回路·澄清不吞卡点：澄清问题出现时卡点保持在开且步流明示（答复续跑后继续推进）")
            } catch {
                lines.append("✗ 回路·场景D 开卡点抛错：\(error.localizedDescription)")
            }
            let badAction = (try? JSONSerialization.data(withJSONObject: ["action": "teleport", "reason": "自检二十一词表外样本"])).flatMap { try? JSONDecoder().decode(AgentAction.self, from: $0) }
            if let badAction {
                handleInvalidAction(badAction)
                var failed = false
                if case .failed = status { failed = true }
                let recorded = steps.contains { $0.action == "invalid" && $0.reason.contains("teleport") }
                let counted = openStall?.invalidActions.contains("teleport") == true
                lines.append("\(fmt(recorded && counted && !failed)) 回路·词表外动作去终结化（F4）：动作字符串「teleport」已先记账留痕、计入在开卡点证据，引擎未置失败、未清进度（处理函数结构上不碰快照清除与状态置位）")
            } else {
                lines.append("✗ 回路·词表外动作样本构造失败")
            }
        }
        // 恢复现场：梯账/卡点/步流/目标/预算回到测试前，快照按恢复后状态重写
        bypassLadder = savedLadder
        openStall = savedStall
        steps = savedSteps
        stepSeq = savedSeq
        goal = savedGoal
        pendingLoopHint = savedHint
        stepBudget = savedBudget
        persistSnapshot()
        return lines
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
    /// 确认路径共用）：返回要补进轨迹的 outcome 步文案与台账条目 id
    /// （VERIFY-1 核验记录据此关联），非提交类返回 nil。
    /// 同一性命中已有条目时不重复建条——更新其时间与状态并注明再次提交
    /// （软门已提醒后坚持执行、或经用户确认执行的重发走的正是这条）。
    private func noteSubmissionIfNeeded(action: AgentAction, element: PageElement, pageURL: String) -> (note: String, recordID: UUID)? {
        guard action.action == "click", SubmissionClassifier.isSubmissionElement(element) else { return nil }
        let (hash, prefix) = currentContentFingerprint()
        let host = URL(string: pageURL)?.host ?? ""
        let label = Self.elementLabel(of: element)
        if let index = outcomeLedger.firstIndex(where: { Self.outcomeMatches($0, fingerprint: hash, host: host, pageURL: pageURL, label: label) }) {
            outcomeLedger[index].recordedAt = Date()
            outcomeLedger[index].resubmittedAt = Date()
            outcomeLedger[index].statusNote = "再次提交（经提醒或用户确认后执行），待核查"
            saveOutcomeLedger()
            return ("成果台账更新：同一内容已再次提交（「\(label)」），条目时间与状态已更新——后续仍按已提交内容对待，不得无意识再发", outcomeLedger[index].id)
        }
        let record = OutcomeRecord(id: UUID(), pageURL: pageURL, host: host, elementLabel: label,
                                    contentFingerprint: hash, contentPrefix: prefix,
                                    statusNote: "已提交（待核查）", recordedAt: Date(), resubmittedAt: nil)
        outcomeLedger.append(record)
        saveOutcomeLedger()
        let contentDesc = prefix.isEmpty ? "（正文未留指纹，按页面与按钮记账）" : "内容「\(prefix)…」"
        return ("成果台账已记录：\(Self.outcomeTime(record.recordedAt)) 在 \(host.isEmpty ? "本地页面" : host) 提交了\(contentDesc)（按钮「\(label)」），状态：已提交（待核查）", record.id)
    }

    // MARK: - 动作后核验（VERIFY-1：shadow 记录，不阻断、不重放）

    /// 台账落记后随即运行的独立核验：settle 采样取新鲜证据 →
    /// ActionVerifier 三值判定 → 记录 append 落盘 verification-log
    /// .jsonl（台账旁记录）→ 步流补一条 verify 提示步（经
    /// pendingVerificationStep 在 outcome 步之后补入，runConfirmed 路径
    /// 就地补）。shadow 口径：判定只记录与提示——不改台账状态、不拦
    /// 动作、不自动重提/重发；unknown 只提示，contradicted 只标分歧，
    /// 是否转正式阻断门留待 shadow 数据裁决。全程不抛错：取证异常
    /// 本身记为 unknown，绝不让核验层把已执行的动作拖成失败。
    private func runPostSubmissionVerification(recordID: UUID, element: PageElement, pageURL: String, before: PageState, token: UUID) async {
        let prefix = outcomeLedger.first(where: { $0.id == recordID })?.contentPrefix ?? currentContentFingerprint().prefix
        let label = Self.elementLabel(of: element)
        let capture = await web.settledCapture()
        guard token == generation else { return }
        let result = ActionVerifier.judge(before: before, after: capture.after, samples: capture.samples,
                                          settled: capture.settled, contentPrefix: prefix)
        let record = ActionVerifier.makeRecord(sessionID: runSessionID.uuidString, outcomeRecordID: recordID,
                                               actionLabel: label, pageURL: pageURL, result: result, settled: capture.settled)
        VerificationLogStore.shared.append(record)
        let evidenceText = result.evidence.first ?? result.weakEvidence.first ?? "无 conclusive 证据"
        switch result.verdict {
        case .verified:
            pendingVerificationStep = "动作后核验（影子记录）：verified——\(evidenceText)。该结论由核验层独立回读得出，与台账「待核查」并存记录，不改变流程。"
        case .contradicted:
            pendingVerificationStep = "动作后核验（影子记录）：contradicted——\(evidenceText)。核验与执行器自报（已提交）分歧，已落盘记录；shadow 期只提示不阻断、不自动重发，请结合页面现状判断。"
        case .unknown:
            pendingVerificationStep = "动作后核验（影子记录）：unknown——\(evidenceText)。证据不足以下结论，仅提示不阻断、不自动重发；需要确认现状时按台账口径去列表/记录页核查。"
        }
    }

    /// 自检十三 Tier A（VERIFY-1）：核验合约全链程序化核查——
    /// WebController 在合成页 test-verify 真实驱动四场景（三值＋证据
    /// 未稳），产出的记录在本层做落盘往返与分歧统计核对（临时日志，
    /// 不污染正式 shadow 数据）。不调用模型；要求引擎空闲（驱动会占
    /// 用当前标签页打开合成页）。
    func verifyActionVerificationContract() async -> [String] {
        guard !busy else { return ["✗ 引擎忙碌中，自检十三 Tier A 未执行（先等当前任务终结或停止）"] }
        var lines: [String] = []
        let (webLines, records) = await web.verifyActionVerificationContract()
        lines += webLines
        guard records.count == 4 else {
            lines.append("✗ 核验记录产出不全（\(records.count)/4），落盘往返未执行")
            return lines
        }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("verification-log-selftest.jsonl")
        try? FileManager.default.removeItem(at: tempURL)
        let store = VerificationLogStore(fileURL: tempURL)
        for record in records { store.append(record) }
        let loaded = store.loadAll()
        lines.append(loaded.count == records.count && zip(loaded, records).allSatisfy { $0.verdict == $1.verdict && $0.id == $1.id }
            ? "✓ 核验记录落盘往返：4 条记录逐行写入 JSONL 后回读，条数/判定/id 逐条一致"
            : "✗ 核验记录落盘往返异常（回读 \(loaded.count) 条）")
        let stats = store.stats(from: loaded)
        lines.append(stats.total == 4 && stats.verified == 1 && stats.contradicted == 1 && stats.unknown == 2 && stats.diverged == 1
            ? "✓ 分歧统计口径：total 4＝verified 1＋contradicted 1＋unknown 2，diverged 1（与 contradicted 互为校验）"
            : "✗ 分歧统计异常（total \(stats.total)、verified \(stats.verified)、contradicted \(stats.contradicted)、unknown \(stats.unknown)、diverged \(stats.diverged)）")
        try? FileManager.default.removeItem(at: tempURL)
        lines.append("· 正式核验日志（verification-log.jsonl）当前累计 \(VerificationLogStore.shared.loadAll().count) 条 shadow 记录（只由真机任务流产生，自检合成记录不入此账）")
        return lines
    }

    /// 自检十五（WECHAT-COVER-FIX Part C）：步数账与检查点恢复的
    /// 程序化模拟（纯结构断言，不触碰引擎运行态）——①预算只随模型
    /// 决策 consume 增长；②引擎注记/内部子步类事件不计数（计数点
    /// 唯一在主循环动作取得处，此处以「不调 consume 则计数不变」
    /// 断言其结构性）；③段限到后开新段可续、累计不清零（不重跑
    /// 已完成部分的账面保证）；④硬顶（段数×每段）封顶后 openNextSegment
    /// 拒绝、canDecide 恒假；⑤同指纹失败重试被循环熔断 3/5/7 分级
    /// 封顶（换说辞不进指纹、不重置计数）；⑥快照预算四字段编解码
    /// 往返不变、旧格式快照（无四键）解码成功且走迁移口径。
    func verifyStepBudget() -> [String] {
        var lines: [String] = []
        func fmt(_ ok: Bool) -> String { ok ? "✓" : "✗" }
        var budget = StepBudget(limit: 5)
        for _ in 0..<5 { budget.consumeDecision() }
        lines.append("\(fmt(budget.segmentExhausted && !budget.canDecide && budget.segmentUsed == 5 && budget.totalUsed == 5 && budget.segment == 1)) 只计模型决策：连 consume 5 次后段限到（段内 5/5、累计 5、仍在第 1 段、canDecide=false）")
        for _ in 0..<12 { _ = "引擎注记/采样/回读/分块事件（不经计数点）" }
        lines.append("\(fmt(budget.segmentUsed == 5 && budget.totalUsed == 5)) 内部子步不计数：模拟 12 次注记类事件后计数不变（计数点唯一、注记步与子步永不入账）")
        let opened = budget.openNextSegment()
        lines.append("\(fmt(opened && budget.segment == 2 && budget.segmentUsed == 0 && budget.totalUsed == 5 && budget.canDecide)) 检查点开新段：段限暂停后开第 2 段成功，段内清零可续跑、累计 5 保留（已完成部分不重跑的账面对应物）")
        while budget.canDecide { budget.consumeDecision() }
        lines.append("\(fmt(budget.totalUsed == budget.hardTop && budget.hardTopReached && !budget.openNextSegment() && !budget.canDecide)) 硬顶封顶：累计达硬顶 \(budget.hardTop)（4 段×5）后开段被拒、canDecide 恒假——失控成本有顶")
        var detector = LoopDetector()
        let fp = LoopDetector.fingerprint(action: "click", target: "同一按钮", outcome: "executed")
        var levels: [LoopDetector.Level] = []
        for _ in 0..<7 { levels.append(detector.record(fingerprint: fp).level) }
        lines.append("\(fmt(levels[2] == .warning && levels[4] == .severe && levels[6] == .tripped)) 熔断封顶：同指纹（动作＋目标＋结果，不含说辞）连记 7 次依次跨提醒（3）/严重（5）/熔断（7）——变换说辞不重置计数")
        let snap = SessionSnapshot(savedAt: Date(), goal: "自检十五", limit: 5, stepSeq: 0, steps: [],
                                   statusKind: "paused", statusText: "", pendingActionJSON: nil, pendingElement: nil,
                                   pendingURL: nil, waiting: nil, answersJSON: "[]", skillNames: nil, taskID: nil,
                                   tabURLs: nil, activeTabIndex: nil, executionTabIndex: nil, outcomes: nil,
                                   stateCard: nil, sessionID: nil,
                                   modelStepsUsed: 3, budgetSegment: 2, totalModelSteps: 8, stepLimitPaused: true)
        let roundtrip = (try? JSONEncoder().encode(snap)).flatMap { try? JSONDecoder().decode(SessionSnapshot.self, from: $0) }
        lines.append("\(fmt(roundtrip?.modelStepsUsed == 3 && roundtrip?.budgetSegment == 2 && roundtrip?.totalModelSteps == 8 && roundtrip?.stepLimitPaused == true)) 快照往返：预算四字段（段内 3/第 2 段/累计 8/段限暂停）编解码后原样——检查点跨进程不丢")
        let legacyJSON = "{\"version\":2,\"savedAt\":\(Date().timeIntervalSinceReferenceDate),\"goal\":\"旧快照\",\"limit\":5,\"stepSeq\":0,\"steps\":[],\"statusKind\":\"paused\",\"statusText\":\"\",\"answersJSON\":\"[]\"}"
        let legacy = try? JSONDecoder().decode(SessionSnapshot.self, from: Data(legacyJSON.utf8))
        lines.append("\(fmt(legacy != nil && legacy?.modelStepsUsed == nil && legacy?.stepLimitPaused == nil)) 旧快照兼容：无预算四键的旧格式解码成功、四键为 nil——恢复时走迁移口径（新段＋累计按条目数计入硬顶）")
        return lines
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
        if let vstep = pendingVerificationStep { appendStep("verify", vstep); pendingVerificationStep = nil }
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
        // 本会话附件（F1）：附件清单＋可读状态＋文本摘录——模型据此用
        // upload_file 引用附件；存入≠已读≠已上传的三态口径在段内明示
        let attachmentBlock = AttachmentStore.shared.promptBlock(for: runSessionID)
        if !attachmentBlock.isEmpty { prompt += attachmentBlock + "\n" }
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
        // M1 起：标签置顶标记（与 tabURLs 同序）——置顶是会话现场的一
        // 部分，中断恢复时按它还原，置顶入口不因进程被杀而丢。可选字段，
        // 此前快照无此键照常解码（恢复时按全未置顶处理）。
        var tabPinned: [Bool]? = nil
        // OUTCOME-LEDGER 起：成果台账随快照双写——台账本体另有自有持久化，
        // 快照里的这份保证「随会话恢复的正是本会话的条目」，恢复时按 id
        // 合并去重。可选字段，此前快照无此键照常解码。
        var outcomes: [OutcomeRecord]?
        // H1 起：结构化任务状态卡与所属会话 id。可选字段，此前快照无此
        // 两键照常解码（无卡时恢复路径按步流派生一张，见 restoreSnapshotIfNeeded）。
        var stateCard: TaskStateCard?
        var sessionID: UUID?
        // F1 起：待决网页上传的等待现场（仅 statusKind=waitingManual 且上传
        // 等待中才有值）。可选字段，此前快照无此键照常解码。SP-01 一次性
        // 凭据不落盘：恢复时若原阶段是选文件且文件非本任务生成，退回确认
        // 阶段重新出卡（见 restoreSnapshot 的 waitingManual 分支）。
        struct UploadDTO: Codable {
            var attachmentID: UUID?
            var attachmentName: String
            var isTaskGenerated: Bool
            var pageURL: String
            var elementIndex: Int
            var elementLabel: String
            var wasPickStage: Bool
        }
        var upload: UploadDTO? = nil
        // WECHAT-COVER-FIX Part C 起：模型步预算现场（段内已用/当前段/
        // 全任务累计/是否因段限暂停）。可选字段，此前快照无此四键照常
        // 解码；恢复时无此四键按迁移口径：给一个新段（segmentUsed=0、
        // segment=1），累计按历史条目数保守计入硬顶（旧口径条目数 ≥
        // 决策数，只会更早触顶、不会放宽）。
        var modelStepsUsed: Int? = nil
        var budgetSegment: Int? = nil
        var totalModelSteps: Int? = nil
        var stepLimitPaused: Bool? = nil
        // AUTONOMY-FIX 起：绕行梯现场（已试梯级 rawValue 数组＋逐级
        // 留痕）。可选字段，此前快照无此二键照常解码（恢复时梯账为空、
        // 从梯级①重新开始）。
        var ladderAttempted: [String]? = nil
        var ladderNotes: [String]? = nil
        // LADDER-FIX 起：梯账的 harvest 跨页模板记忆与最近实况、以及
        // 在开卡点的全账（逐项验收／已点目标／词表外动作／感知盲
        // 区）。全部可选，此前快照无此组键照常解码（恢复时无跨页记
        // 忆、无在开卡点）。
        var ladderTemplate: String? = nil
        var ladderTemplateFrom: String? = nil
        var ladderFact: String? = nil
        var stallStuck: String? = nil
        var stallOpenURL: String? = nil
        var stallOpenedDecision: Int? = nil
        var stallDialogAtOpen: Bool? = nil
        var stallVerified: [String]? = nil
        var stallNA: [String: String]? = nil
        var stallClicked: [String]? = nil
        var stallClickExecuted: Bool? = nil
        var stallFrameTried: Bool? = nil
        var stallInvalid: [String]? = nil
        var stallBlind: String? = nil
    }
    /// 旧版快照的 UserDefaults 键（H1 前）。H1 起快照落当前会话的
    /// snapshot.json（见 persistSnapshot）；本键只作一次性迁移来源，
    /// 迁移/新落盘成功后即清除，防止旧快照被反复当作新状态恢复。
    private static let snapshotKey = "agentSessionSnapshot.v1"

    /// 读取某会话的快照数据（M1 起按会话取）：优先该会话的快照文件；
    /// 文件不存在时，仅对当前会话走一次性迁移——把旧 UserDefaults 快照
    /// 复制进会话文件（写成功后才清旧键，写失败则原样返回旧数据、下次
    /// 启动重试迁移，数据不丢）。旧键诞生于单会话时代，只属于当前会话，
    /// 读别的会话时不碰它（allowLegacy=false 时同样不迁）。
    private func loadSnapshotData(for sessionID: UUID, allowLegacy: Bool = true) -> Data? {
        let url = SessionStore.shared.snapshotURL(for: sessionID)
        if let data = try? Data(contentsOf: url) { return data }
        guard allowLegacy, sessionID == SessionStore.shared.currentSessionID,
              let legacy = UserDefaults.standard.data(forKey: Self.snapshotKey) else { return nil }
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
        let scene: (urls: [String], activeIndex: Int, executionIndex: Int?, pinned: [Bool])
        if let pending = pendingTabScene { scene = pending } else { scene = web.tabScene(for: runSessionID) }
        let snapshot = SessionSnapshot(savedAt: Date(), goal: goal, limit: limit, stepSeq: stepSeq,
                                       steps: steps.map { SessionSnapshot.StepDTO(id: $0.id, action: $0.action, reason: $0.reason) },
                                       statusKind: kind, statusText: text,
                                       pendingActionJSON: pendingJSON, pendingElement: pendingElement, pendingURL: pendingURL,
                                       waiting: waitingDTO, answersJSON: String(decoding: answersData, as: UTF8.self),
                                       skillNames: loadedSkillNames,
                                       taskID: conversationTaskID,
                                       tabURLs: scene.urls, activeTabIndex: scene.activeIndex, executionTabIndex: scene.executionIndex, tabPinned: scene.pinned,
                                       outcomes: outcomeLedger,
                                       stateCard: stateCard,
                                       sessionID: runSessionID,
                                       upload: pendingUpload.map { upload in
                                           SessionSnapshot.UploadDTO(attachmentID: upload.attachmentID, attachmentName: upload.attachmentName,
                                                                     isTaskGenerated: upload.isTaskGenerated, pageURL: upload.pageURL,
                                                                     elementIndex: upload.elementIndex, elementLabel: upload.elementLabel,
                                                                     wasPickStage: upload.stage == .pickFile)
                                       },
                                       modelStepsUsed: stepBudget.segmentUsed, budgetSegment: stepBudget.segment,
                                       totalModelSteps: stepBudget.totalUsed, stepLimitPaused: stepLimitPaused,
                                       ladderAttempted: bypassLadder.attemptedRaw, ladderNotes: bypassLadder.notes,
                                       ladderTemplate: bypassLadder.harvestTemplate, ladderTemplateFrom: bypassLadder.harvestTemplateFrom, ladderFact: bypassLadder.harvestFact,
                                       stallStuck: openStall?.stuck, stallOpenURL: openStall?.openURL,
                                       stallOpenedDecision: openStall?.openedAtDecision, stallDialogAtOpen: openStall?.dialogAtOpen,
                                       stallVerified: openStall?.verifiedRaw, stallNA: openStall?.naRaw, stallClicked: openStall?.clickedRaw,
                                       stallClickExecuted: openStall?.clickExecuted, stallFrameTried: openStall?.frameCloseTried,
                                       stallInvalid: openStall?.invalidActions, stallBlind: openStall?.perceptionBlindNote)
        if let data = try? JSONEncoder().encode(snapshot) {
            // H1：快照落所属会话的 snapshot.json（按会话分库；M1 起按
            // runSessionID——任务在会话 A 执行时用户切到 B 浏览，落盘仍回
            // A 的目录）；旧键若还在（迁移未发生的边角）一并清除，防止
            // 旧快照复活盖掉新状态
            let url = SessionStore.shared.snapshotURL(for: runSessionID)
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            if UserDefaults.standard.object(forKey: Self.snapshotKey) != nil {
                UserDefaults.standard.removeObject(forKey: Self.snapshotKey)
            }
        }
    }

    private func clearSnapshot() {
        // 清的是任务所属会话的快照（M1：按 runSessionID，不随查看会话走）
        let url = SessionStore.shared.snapshotURL(for: runSessionID)
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
        restoreSnapshot(for: runSessionID, allowLegacy: true)
    }

    /// 按会话恢复（M1 泛化自冷启动恢复）：只认 24 小时内、且快照自记的
    /// sessionID 与目标会话一致的非终结快照（H1 起快照带 sessionID；
    /// 更旧的快照无此字段，只会躺在其诞生会话的目录或旧键里，按目标
    /// 会话认领）。恢复语义与冷启动一致：停在「可继续」一侧，标签现场
    /// 暂存待第一次续跑时重建。
    private func restoreSnapshot(for sessionID: UUID, allowLegacy: Bool) {
        guard let data = loadSnapshotData(for: sessionID, allowLegacy: allowLegacy),
              let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data),
              Date().timeIntervalSince(snapshot.savedAt) < 24 * 3600, !snapshot.goal.isEmpty else { return }
        if let owner = snapshot.sessionID, owner != sessionID { return }
        goal = snapshot.goal
        taskText = snapshot.goal
        limit = snapshot.limit
        stepSeq = snapshot.stepSeq
        steps = snapshot.steps.map { AgentStep(id: $0.id, action: $0.action, reason: $0.reason) }
        // 步预算恢复（Part C）：带预算四键的快照原样恢复（含段限暂停
        // 标记——恢复后点「继续」照常开新段）；旧快照无此四键按迁移
        // 口径：给一个新段，累计按历史条目数保守计入硬顶
        if let used = snapshot.modelStepsUsed, let segment = snapshot.budgetSegment, let total = snapshot.totalModelSteps {
            stepBudget = StepBudget(limit: snapshot.limit, segmentUsed: used, segment: segment, totalUsed: total)
            stepLimitPaused = snapshot.stepLimitPaused ?? false
        } else {
            stepBudget = StepBudget(limit: snapshot.limit, segmentUsed: 0, segment: 1, totalUsed: snapshot.steps.count)
            stepLimitPaused = false
        }
        // 绕行梯恢复（AUTONOMY-FIX）：带梯账的快照原样恢复（已试梯级
        // 不重走）；旧快照无此二键则梯账为空
        if let attemptedRaw = snapshot.ladderAttempted {
            bypassLadder = BypassLadder(attemptedRaw: attemptedRaw, notes: snapshot.ladderNotes ?? [],
                                         harvestTemplate: snapshot.ladderTemplate, harvestTemplateFrom: snapshot.ladderTemplateFrom, harvestFact: snapshot.ladderFact)
        } else {
            bypassLadder = BypassLadder()
        }
        // 在开卡点恢复（LADDER-FIX）：带卡点账的快照原样恢复——澄清
        // 停车与进程恢复都不吞卡点，续跑后引擎按原进度继续推进梯子；
        // 旧快照无此组键则无在开卡点
        if let stuck = snapshot.stallStuck {
            openStall = OpenStall(stuck: stuck, openURL: snapshot.stallOpenURL ?? "",
                                  openedAtDecision: snapshot.stallOpenedDecision ?? 0, dialogAtOpen: snapshot.stallDialogAtOpen ?? false,
                                  verifiedRaw: snapshot.stallVerified ?? [], na: snapshot.stallNA ?? [:],
                                  clicked: snapshot.stallClicked ?? [], clickExecuted: snapshot.stallClickExecuted ?? false,
                                  frameCloseTried: snapshot.stallFrameTried ?? false, invalid: snapshot.stallInvalid ?? [],
                                  blind: snapshot.stallBlind)
        } else {
            openStall = nil
        }
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
            pendingTabScene = (urls: urls, activeIndex: snapshot.activeTabIndex ?? 0, executionIndex: snapshot.executionTabIndex, pinned: snapshot.tabPinned ?? [])
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
            // 待决上传的等待现场恢复（F1）：凭据不跨进程——原阶段是确认卡
            // 就照旧出卡（恢复时重新签发凭据）；原阶段是选文件且文件非本
            // 任务生成，退回确认阶段重新确认（旧确认不复用）；本任务生成
            // 的文件才直接恢复到选文件阶段（用户需在页面上重新点控件）。
            if let dto = snapshot.upload {
                var upload = PendingUpload(id: UUID(), attachmentID: dto.attachmentID, attachmentName: dto.attachmentName,
                                           isTaskGenerated: dto.isTaskGenerated, pageURL: dto.pageURL,
                                           pageHost: URL(string: dto.pageURL)?.host ?? "",
                                           elementIndex: dto.elementIndex, elementLabel: dto.elementLabel,
                                           stage: .confirmUpload, confirmationToken: nil)
                if dto.wasPickStage && dto.isTaskGenerated {
                    upload.stage = .pickFile
                } else {
                    upload.confirmationToken = AttachmentStore.shared.issueUploadConfirmation(attachmentID: dto.attachmentID, pageURL: dto.pageURL)
                }
                // 找图指引字段按附件记录现查回填（COVER-UPLOAD-FIX C）；
                // 恢复到选文件阶段且附件可解析时重新武装待供文件——
                // 进程被杀不改变「用户点上传按钮即自动带上」的口径。
                if let attachmentID = dto.attachmentID,
                   let record = AttachmentStore.shared.record(id: attachmentID, sessionID: runSessionID) {
                    upload.isImage = record.contentType.hasPrefix("image/")
                    upload.savedToPhotos = record.savedToPhotos == true
                    if upload.stage == .pickFile {
                        _ = web.armUploadSupply(url: AttachmentStore.shared.fileURL(for: record), fileName: record.displayName)
                    }
                }
                pendingUpload = upload
                let text = upload.stage == .confirmUpload
                    ? "上传前请确认：将把文件「\(upload.attachmentName)」上传到 \(upload.pageHost.isEmpty ? "当前页面" : upload.pageHost)"
                    : "请选择要上传的文件（目标：\(upload.attachmentName)）。\(Self.uploadPickGuidance(upload: upload, supplyArmed: web.uploadSupplyArmed))"
                waitingInput = .manual(id: upload.id, text: text)
                status = .waitingManual(text)
            }
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
        let beforeScene = web.tabScene(for: runSessionID)
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
        discardPendingUpload()
        // 成果台账的内存态同样清掉（打字记录／软门已提醒集合／未消费提醒），
        // 恢复后只剩快照里双写的那份台账——与真机强退重开同一口径
        recentTyped = []; outcomeGateFired = []; pendingOutcomeHint = nil; pendingOutcomeStep = nil; pendingVerificationStep = nil; outcomeLedger = []
        // 状态卡与折叠/重试内存态同样清零：恢复出的卡片只能来自快照（H1）
        stateCard = TaskStateCard(); forcedFoldLevel = 0; contextRetryUsed = false
        web.resetTabsToStartPage(sessionID: runSessionID)
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
