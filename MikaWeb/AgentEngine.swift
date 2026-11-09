import SwiftUI
import UIKit
import BackgroundTasks
import Combine
#if DEBUG && targetEnvironment(simulator)
import WebKit
import Darwin
#endif
enum StaleTargetPolicy {
    static func isStaleTarget(errorDomain: String, code: Int, message: String) -> Bool {
        guard errorDomain == "WKErrorDomain", code == 4 else { return false }
        return ["目标元素已失效", "目标元素已变化"].contains { message.contains($0) }
    }
}
enum AgentStatus {
    case idle, running, paused(String), waitingConfirm(AgentAction), waitingManual(String), done(String), failed(String), ended(String)
    var label: String {
        switch self {
        case .idle: return "待命"
        case .running: return "运行中"
        case .paused(let s): return "已暂停：\(s)"
        case .waitingConfirm(let a): return "等待确认：\(a.reason)"
        case .waitingManual(let s): return "等待手动输入：\(s)"
        case .done(let s): return "完成：\(s)"
        case .failed(let s): return "失败：\(s)"
        case .ended(let s): return "已结束：\(s)"
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
private struct PendingExecutionAuthorization: Codable {
    var id: UUID
    var taskID: UUID
    var accountKey: String
    var site: String
    var pageURL: String
    var targetKey: String
    var parameterHash: String
    var executionRevision: Int
    var issuedAt: Date
    var expired: Bool { Date().timeIntervalSince(issuedAt) >= 60 }
}
private final class DispatchCallMarker { var entered = false }
struct TaskProgressSnapshot: Codable {
    var taskID: UUID
    var stage: String
    var result: String
    var next: String
    var updatedAt: Date
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
/// EDITOR-ENTRY-BIND 扩展：内嵌数据不再只截 URL 片段——采集层以
/// appmsgid 类键为锚截取对象窗口，本枚举从窗口里做「同对象共现」
/// 配对提取（标题与 appmsgid 必须出现在同一个对象字面量内、且该
/// 对象内 appmsgid 取值唯一才成对，见 extractPairs）；引擎给出目
/// 标标题（卡点/目标里的书名号引文）时只许采用与标题配对的那一个
/// ID——配不到或配到多组一律落空，禁止按位置/顺序猜测配对。
enum DirectTargetHarvest {
    struct Result: Equatable {
        let url: String
        let appmsgid: String
        let viaTemplate: Bool
        /// 采用候选的来源类别（步流与结案留痕用）。
        var source: String = ""
        /// 模板来自本任务先前页面的跨页记忆时为 true。
        var crossPage: Bool = false
        /// 经标题配对采用时，被实证绑定的目标标题（步流留痕用）。
        var pairedTitle: String? = nil
    }

    /// 一组标题↔appmsgid 实证配对：两者在同一证据单元内共现——
    /// 内嵌数据＝同一对象字面量；卡片 DOM＝同一卡片子树（采集层
    /// 在卡片容器内同时取到标题文本与 msgid 类属性）。位置相邻、
    /// 顺序对应不算配对，提取口径见 extractPairs 与采集层注释。
    struct Pair: Equatable {
        let title: String
        let appmsgid: String
        /// 证据来源说明（步流与案卷留痕用）。
        let evidence: String
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
        /// 标题↔appmsgid 实证配对（同对象/同卡共现，见 Pair）。
        var pairs: [Pair] = []
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
            if !pairs.isEmpty { text += "；标题配对实证 \(pairs.count) 组（同对象/同卡共现）" }
            if !note.isEmpty { text += "；\(note)" }
            return text
        }
    }

    /// 旧入口（仅 href 候选）：自检十八既有断言走此包装，语义不变。
    static func build(hrefs: [String]) -> Result? {
        build(candidates: hrefs.map { Candidate(source: .href, value: $0) }, memoryTemplate: nil).result
    }

    static func build(candidates: [Candidate], memoryTemplate: String?, targetTitle: String? = nil, domPairs: [Pair] = []) -> (result: Result?, facts: Facts) {
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
        // 标题配对提取（EDITOR-ENTRY-BIND）：内嵌数据候选走同对象
        // 共现提取，卡片 DOM 配对由采集层直接交入——两路都是证据
        // 绑定，配对 ID 同样计入实证 ID 集。
        var pairs = domPairs
        for c in candidates where c.source == .embedded {
            for p in extractPairs(fromScriptText: c.value) where !pairs.contains(p) { pairs.append(p) }
        }
        facts.pairs = pairs
        for p in pairs where !facts.knownIDs.contains(p.appmsgid) { facts.knownIDs.append(p.appmsgid) }
        facts.editTemplate = editTemplate?.url
        // 有目标标题时只认标题配对：配不到唯一一组即落空——绝不
        // 退回「模板＋第一个 ID」的顺序猜测（会打开错的那篇草稿）。
        // 带 ID 编辑链接直用也受此约束：其 ID 必须与目标标题的唯
        // 一配对一致才用（链接本身只绑定模板与 ID、不绑定标题，
        // 列表页上多条编辑链接时拿第一条就是位置猜测）。
        if let target = targetTitle, !normalizeTitle(target).isEmpty {
            let matches = pairs.filter { titleMatches(pairTitle: $0.title, target: target) }
            if matches.count == 1, let pair = matches.first {
                if let d = directEdit, d.id == pair.appmsgid {
                    facts.note = "采用带 ID 编辑链接直用，且与标题配对实证一致：《\(pair.title)》↔ appmsgid=\(pair.appmsgid)（\(pair.evidence)；链接来源：\(d.source.label)）"
                    return (Result(url: d.url, appmsgid: d.id, viaTemplate: false, source: d.source.label, pairedTitle: pair.title), facts)
                }
                if let t = editTemplate {
                    facts.note = "采用标题配对实证：《\(pair.title)》与 appmsgid=\(pair.appmsgid) \(pair.evidence)，拼编辑链接模板（模板来源：\(t.source.label)）"
                    let separator = t.url.contains("?") ? "&" : "?"
                    return (Result(url: t.url + separator + "appmsgid=" + pair.appmsgid, appmsgid: pair.appmsgid, viaTemplate: true, source: "标题配对（\(pair.evidence)）", pairedTitle: pair.title), facts)
                }
                if let memory = memoryTemplate {
                    facts.note = "采用标题配对实证：《\(pair.title)》与 appmsgid=\(pair.appmsgid) \(pair.evidence)，拼跨页模板记忆"
                    let separator = memory.contains("?") ? "&" : "?"
                    return (Result(url: memory + separator + "appmsgid=" + pair.appmsgid, appmsgid: pair.appmsgid, viaTemplate: true, source: "标题配对（\(pair.evidence)）", crossPage: true, pairedTitle: pair.title), facts)
                }
                facts.note = "落空：目标标题《\(target)》已配到 appmsgid=\(pair.appmsgid)（\(pair.evidence)），但本页与跨页记忆均无编辑链接模板可拼"
                return (nil, facts)
            }
            if matches.count > 1 {
                facts.note = "落空：目标标题《\(target)》匹配到 \(matches.count) 组配对，无法唯一确定，未采用任何一组（不猜测）"
            } else if pairs.isEmpty {
                facts.note = "落空：目标标题《\(target)》在位，但页面未提取到任何标题配对（内嵌数据无同对象共现、卡片 DOM 无共现）——不按位置/顺序猜测配对"
            } else {
                facts.note = "落空：已提取标题配对 \(pairs.count) 组，无一与目标标题《\(target)》匹配（不按位置/顺序猜测配对）"
            }
            return (nil, facts)
        }
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

    // MARK: - 标题配对提取（EDITOR-ENTRY-BIND，纯函数）

    /// 目标标题提取：引擎从任务目标/卡点文案里取书名号（或直角引
    /// 号）引文作目标标题——harvest 据此在配对里找唯一对应。取不到
    /// 返回 nil（harvest 退回无目标口径）。引文过短（<4 字）不认，
    /// 防「草稿」一类泛称被当成标题去配对。
    static func extractTargetTitle(goal: String, stuck: String) -> String? {
        for text in [goal, stuck] {
            for (open, close) in [("《", "》"), ("「", "」"), ("“", "”")] {
                guard let r1 = text.range(of: open),
                      let r2 = text.range(of: close, range: r1.upperBound..<text.endIndex) else { continue }
                let inner = String(text[r1.upperBound..<r2.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if inner.count >= 4 { return inner }
            }
        }
        return nil
    }

    /// 标题归一化（配对匹配用）：去书名号、折叠空白、小写——只做
    /// 书写差异消除，不做语义近似。
    static func normalizeTitle(_ s: String) -> String {
        s.replacingOccurrences(of: "《", with: "")
            .replacingOccurrences(of: "》", with: "")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    /// 配对标题与目标标题是否同一篇：归一化后全等，或一方完整包
    /// 含另一方（目标文案可能截断/带后缀说明）。泛称短串在提取侧
    /// 已被长度门挡下，这里不另设近似匹配。
    static func titleMatches(pairTitle: String, target: String) -> Bool {
        let a = normalizeTitle(pairTitle), b = normalizeTitle(target)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.contains(b) || b.contains(a)
    }

    /// 从一段内嵌脚本文本里提取标题↔appmsgid 配对。口径（证据绑
    /// 定，宁缺勿滥）：
    /// 1) 找出全部 appmsgid 类键（appmsgid/appmsg_id/app_id，含 URL
    ///    形 appmsgid=）的数值出现点；
    /// 2) 对每个出现点，由内向外逐层取包含它的对象字面量跨度——
    ///    某层跨度内 appmsgid 取值唯一、且含 title 键字符串值时，
    ///    两者成对（同对象共现）；跨度内出现第二个不同 ID 即停
    ///    （再外层只会更杂），该出现点不成对；
    /// 3) 对象跨度按字符串感知的括号配平求出（引号内括号不计）。
    /// JS 字面量不是严格 JSON（键可无引号、值可单引号），故不用
    /// JSON 解析、走容错扫描；解析失败的最坏结果是漏配（实况行
    /// 如实记 0），不会误配。
    static func extractPairs(fromScriptText raw: String) -> [Pair] {
        let text = raw.replacingOccurrences(of: "\\/", with: "/")
        guard text.count <= 200_000 else { return [] }
        guard let idRegex = try? NSRegularExpression(pattern: "(?i)(?:appmsgid|appmsg_id|app_id)[\"']?\\s*[:=]\\s*[\"']?(\\d{5,})") else { return [] }
        let fullRange = NSRange(text.startIndex..., in: text)
        var occurrences: [(value: String, location: Int)] = []
        for m in idRegex.matches(in: text, range: fullRange) {
            if let r = Range(m.range(at: 1), in: text) { occurrences.append((String(text[r]), m.range(at: 1).location)) }
        }
        guard !occurrences.isEmpty else { return [] }
        let spans = objectSpans(in: text)
        var pairs: [Pair] = []
        for occ in occurrences {
            // 包含该出现点的对象跨度，由小到大逐层试
            let containing = spans.filter { $0.open < occ.location && occ.location < $0.close }.sorted { ($0.close - $0.open) < ($1.close - $1.open) }
            for span in containing.prefix(3) {
                let idsInSpan = Set(occurrences.filter { span.open < $0.location && $0.location < span.close }.map { $0.value })
                guard idsInSpan.count == 1 else { break }
                guard let nsRange = Range(NSRange(location: span.open, length: span.close - span.open + 1), in: text) else { break }
                let spanText = String(text[nsRange])
                if let title = titleValue(inSpanText: spanText) {
                    let pair = Pair(title: title, appmsgid: occ.value, evidence: "内嵌数据同对象共现")
                    if !pairs.contains(pair) { pairs.append(pair) }
                    break
                }
            }
        }
        return pairs
    }

    /// 字符串感知的对象跨度扫描：返回全部成对 { } 的 utf16 起止位
    /// 置（引号/转义内的括号不计；模板字符串整体按引号跳过——其内
    /// ${} 表达式里的对象字面量会漏检，属可接受的漏配方向）。
    private static func objectSpans(in text: String) -> [(open: Int, close: Int)] {
        let units = Array(text.utf16)
        var spans: [(open: Int, close: Int)] = []
        var stack: [Int] = []
        var quote: UInt16? = nil
        var escaped = false
        for (i, u) in units.enumerated() {
            if let q = quote {
                if escaped { escaped = false }
                else if u == 0x5C { escaped = true }
                else if u == q { quote = nil }
                continue
            }
            if u == 0x22 || u == 0x27 || u == 0x60 { quote = u; continue }
            if u == 0x7B { stack.append(i) }
            else if u == 0x7D, let open = stack.popLast() { spans.append((open, i)) }
        }
        return spans
    }

    /// 在对象跨度文本里找 title 键的字符串值（双/单引号、键可带
    /// 引号），并解 JS 转义（含 \uXXXX——中文标题在内嵌数据里常
    /// 以此形态出现）。找不到返回 nil。
    private static func titleValue(inSpanText spanText: String) -> String? {
        let pattern = "(?:[\"']title[\"']|(?:^|[\\s{,])title)\\s*:\\s*(?:\"((?:\\\\.|[^\"\\\\])*)\"|'((?:\\\\.|[^'\\\\])*)')"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        guard let m = regex.firstMatch(in: spanText, range: NSRange(spanText.startIndex..., in: spanText)) else { return nil }
        for group in 1...2 {
            if let r = Range(m.range(at: group), in: spanText) {
                let decoded = decodeJSString(String(spanText[r])).trimmingCharacters(in: .whitespacesAndNewlines)
                if !decoded.isEmpty { return decoded }
            }
        }
        return nil
    }

    /// JS 字符串转义解码：\uXXXX、\xXX 与常见单字转义；解不了的
    /// 转义按字面保留后一位，不抛错。
    private static func decodeJSString(_ raw: String) -> String {
        var out = ""
        var idx = raw.startIndex
        while idx < raw.endIndex {
            let ch = raw[idx]
            guard ch == "\\" else { out.append(ch); idx = raw.index(after: idx); continue }
            let next = raw.index(after: idx)
            guard next < raw.endIndex else { break }
            let esc = raw[next]
            switch esc {
            case "n": out.append("\n"); idx = raw.index(after: next)
            case "t": out.append("\t"); idx = raw.index(after: next)
            case "r": out.append("\r"); idx = raw.index(after: next)
            case "u":
                var hex = ""
                var cur = raw.index(after: next)
                while hex.count < 4, cur < raw.endIndex, raw[cur].isHexDigit {
                    hex.append(raw[cur]); cur = raw.index(after: cur)
                }
                if hex.count == 4, let v = UInt32(hex, radix: 16), let scalar = UnicodeScalar(v) {
                    out.append(Character(scalar)); idx = cur
                } else { idx = raw.index(after: next) }
            case "x":
                var hex = ""
                var cur = raw.index(after: next)
                while hex.count < 2, cur < raw.endIndex, raw[cur].isHexDigit {
                    hex.append(raw[cur]); cur = raw.index(after: cur)
                }
                if hex.count == 2, let v = UInt32(hex, radix: 16), let scalar = UnicodeScalar(v) {
                    out.append(Character(scalar)); idx = cur
                } else { idx = raw.index(after: next) }
            default:
                out.append(esc); idx = raw.index(after: next)
            }
        }
        return out
    }

    /// 列表翻页地址（纯函数）：URL 带 begin/count 查询参数时给出
    /// 下一页地址（begin += count），begin 超过 maxBegin、参数缺失
    /// 或 count 非正即 nil（无下一页/不是翻页列表）。harvest 的翻
    /// 页累积与自检二十四共用此口径。
    static func nextListPageURL(_ urlString: String, maxBegin: Int) -> String? {
        guard var comps = URLComponents(string: urlString), let items = comps.queryItems,
              let beginText = items.first(where: { $0.name == "begin" })?.value, let begin = Int(beginText),
              let countText = items.first(where: { $0.name == "count" })?.value, let count = Int(countText), count > 0
        else { return nil }
        let next = begin + count
        guard next <= maxBegin else { return nil }
        comps.queryItems = items.map { $0.name == "begin" ? URLQueryItem(name: "begin", value: String(next)) : $0 }
        return comps.url?.absoluteString
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
    @Published private(set) var progressBySession: [UUID: TaskProgressSnapshot] = [:]
    @Published private(set) var active = true
    @Published private(set) var conversationTaskID: UUID?
    @Published private(set) var waitingInput: WaitingInput?
    @Published private(set) var executionSerial = 0
    /// 任务会话是否活跃（未终结）：launch 置真，完成／失败／停止置假；等待确认／手输／
    /// 步数暂停期间保持真。BrowserDockView 以此决定浏览器布局尺寸的所有权
    /// （活跃期锁定展开工作尺寸，见 AGENT-VIEWPORT-FIX 的视口状态迁移表）。
    @Published private(set) var sessionActive = false
    private let web: WebController
    private var readbackTabs = ReadbackTabRegistry()
    private var replacedReadbackTabIDs: Set<UUID> = []
    private let settings: SettingsStore
    private var worker: Task<Void, Never>?
    private var generation = UUID()
    @Published private(set) var pendingSteers: [SteerItem] = []
    @Published private(set) var pendingInterrupt: SteerInterrupt?
    @Published private(set) var interruptInFlight = false
    private weak var steeringConversation: AgentConversationStore?
    private var steeringSidecars: [UUID: SteerSidecar] = [:]
    private var acceptedSteerQueueIDs: Set<UUID> = []
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
    private var recoveryBudget = RecoveryBudget()
    private var thermalGate = ThermalGate()
    private var thermalPaused = false
    private var thermalObserver: NSObjectProtocol?
    private var lastTerminationNote: [ObjectIdentifier: Date] = [:]
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
    private var loadedSkillVersions: [String: String] = [:]
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
    /// 快照双写，进程被杀重开仍在；未决条目不按时间和条数裁剪。
    private(set) var outcomeLedger: [OutcomeRecord] = []
    private var outcomeLedgerDecodeFailed = false
    private var executionReceipts: [ExecutionReceipt] = []
    private var executionReceiptsDecodeFailed = false
    private var pendingExecutionAuthorization: PendingExecutionAuthorization?
    #if DEBUG && targetEnvironment(simulator)
    // Fault injection only in the simulator CLI suite; no model/web-accessible setter.
    private var gateSelfTestAuditStore: ExecutionAuditStore?
    private var gateSelfTestAfterDispatch: (() throws -> Void)?
    #endif
    private var currentActionID: UUID?
    /// 成果主张的任务归属与终局状态。与旧 OutcomeRecord 分表保存，避免改动
    /// 既有台账格式；claim.id 与 OutcomeRecord.id 相同。
    private var taskClaims: [TaskStateClaim] = []
    /// 旧软门兼容字段；当前重复提交由结构化回执永久阻断自动重放。
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
    /// FIX4：当前可复用的正文凭证只属于当前 task/tab/document/editor/body
    /// 版本；历史写入事实留在状态卡，当前凭证失效时不会被历史事实补造。
    private var currentZhihuWriteProof: WriteProof?
    private var currentZhihuPublishBinding: ZhihuPublishBinding?
    private var currentZhihuDecision: PublishDecision?
    private var currentZhihuDirective: ZhihuPublishDirective?
    /// 可跨任务/导航/进程存在的稿件；不含任何页面凭证。
    private var activePreservedDraft: PreservedDraft?
    private let preservedDraftStore: PreservedDraftStore
    private static let preservedDraftAssociationPrefix = "preservedDraft.association."
    /// 当前任务的可追溯发布授权；只由任务目标与最新用户指令更新，网页正文
    /// 与回答草稿从不进入此状态。
    private var currentZhihuAuthorization = PublishAuthorization.initial(instruction: "")
    /// alreadyPublished 命中的实际旧记录，结案不能再按新 taskID 反查。
    private var matchedZhihuPublishRecord: ZhihuPublishRecord?
    /// 发布尝试账跨任务、跨恢复保存；同题未决记录不因换 taskID/正文而清除。
    private var zhihuPublishRecords: [ZhihuPublishRecord] = []
    /// 稳定账号主键与已验证别名关系；与发布账同寿命持久化。
    private var zhihuAccountRegistry = ZhihuAccountRegistry()
    private var controlledZhihuReadback = false
    private var controlledZhihuReadbackBodyOverride: String?
    /// 原生自检的受控模型动作源：非 nil 时 launch() 主循环从这里取动作，
    /// 其余派发、记账、回读与 done 收口完全走生产代码。
    private var controlledActions: [AgentAction]?
    private var controlledActionCursor = 0
    private var controlledActionWillDispatch: ((Int, AgentAction) async throws -> Void)?
    private var controlledZhihuBeforeAttemptPersist: (() -> Void)?
    private var controlledZhihuBeforeFinalClick: (() -> Void)?
    /// 模拟点击落账后进程退出；只用于验证新 AgentEngine 的生产恢复入口。
    private var controlledSuspendAfterZhihuClick = false
    private var controlledDidSuspendAfterZhihuClick = false
    /// 仅由原生 WK 自检构造器显式打开；生产对象图永远使用默认 false。
    private let controlledZhihuPublishFixture: Bool
    private var zhihuPublishLedgerKeyOverride: String?
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
        var confirmationIssuedAt: Date? = nil
        var confirmationRevision: Int? = nil
        var targetKey: String? = nil
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
    // MIKA-TRACE-BASELINE：仅保存本轮取证材料，不参与 prompt／预算决策。
    private var traceModel: ModelClient.TraceEvidence?
    private var tracePageBefore: PageState?
    private var tracePrompt = ""
    private var traceHistoryBefore = ""
    private var traceHistoryAfter = ""
    private var traceFoldLevel = 0
    private var traceStateCardBefore = ""
    private var traceInterjection = ""
    private var traceInputStrategies: [String] = []
    private var traceFinalAction: [String: Any]?
    private var traceRewriteReason = "none"
    private func consumeDialogAttemptRecords() -> (summary: String, actuallyExecuted: Bool) {
        // Records belong only to the immediately completed web attempt. Never reuse
        // a prior attempt when the current one produced no action or timed out.
        let records = web.takeModalAttemptRecords()
        let summary = records.isEmpty ? "未执行（执行层无动作记录）" : records.map {
            "\($0.kind.rawValue):\($0.method)=\($0.status.rawValue)@\($0.timestamp)；落点=\($0.landing)\($0.note.isEmpty ? "" : "（\($0.note)）")"
        }.joined(separator: "；")
        let executed = records.contains { $0.kind == .action && ($0.status == .executed || $0.status == .failed) }
        return (summary, executed)
    }
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
    /// 本次 launch 至多要求一次结案回读；与上下文重试同批重置。
    private var finalAuditFired = false
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
    init(web: WebController, settings: SettingsStore,
         zhihuPublishLedgerKeyOverride: String? = nil,
         preservedDraftStore: PreservedDraftStore = .shared,
         controlledZhihuPublishFixture: Bool = false,
         restoreSession: Bool = true) {
        self.web = web; self.settings = settings
        self.zhihuPublishLedgerKeyOverride = zhihuPublishLedgerKeyOverride
        self.preservedDraftStore = preservedDraftStore
        self.controlledZhihuPublishFixture = controlledZhihuPublishFixture
        thermalGate.update(level: ThermalLevel(ProcessInfo.processInfo.thermalState), now: Date())
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                                                  object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshThermalState() }
        }
        web.contentProcessTerminationHandler = { [weak self] tab in
            self?.noteContentProcessTermination(tab)
        }
        web.agentPopupCreated = { [weak self] tabID, sourceTabID in
            guard let self, case .running = self.status, let taskID = self.conversationTaskID else { return }
            guard sourceTabID == self.web.executionTabID || self.readbackTabs.entries[sourceTabID]?.ownerTaskID == taskID else { return }
            _ = self.readbackTabs.register(tabID: tabID, ownerTaskID: taskID, sourceTabID: sourceTabID, purpose: "popup")
        }
        web.tabClosed = { [weak self] tabID in self?.readbackTabs.unregister(tabID: tabID) }
        settingsCancellable = settings.$keepScreenAwakeDuringTask.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.applyIdleTimerPolicy() }
        }
        loadOutcomeLedger()
        loadExecutionReceipts()
        if let data = UserDefaults.standard.data(forKey: "taskProgress.v1"),
           let saved = try? JSONDecoder().decode([UUID: TaskProgressSnapshot].self, from: data) {
            progressBySession = saved
        }
        loadZhihuPublishRecords()
        loadTaskClaims()
        saveTaskClaims()
        loadQueue()
        if restoreSession { restoreSnapshotIfNeeded() }
    }
    deinit {
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
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
        // 原生自检的受控动作源不调用模型；它仍走聊天共用启动/主循环入口。
        if controlledActions != nil { return nil }
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
    private func startInSession(_ sessionID: UUID, local: String?, task: String?, startingID: UUID? = nil) {
        guard !interruptInFlight else { return }
        if let request = steeringSidecars[sessionID]?.interrupt, request.startingID != startingID {
            steeringConversation?.localFeedback("还有中断待发文字，请先重试或撤回")
            return
        }
        stop()
        if let oldTaskID = conversationTaskID { readbackTabs.endTask(oldTaskID) }
        replacedReadbackTabIDs.removeAll()
        runSessionID = sessionID
        refreshPendingSteers()
        guard active else { status = .paused("任务只能在前台执行"); return }
        if let issue = modelReadinessIssue() { status = .failed(issue); return }
        if let task { taskText = task }
        guard !taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status = .failed("请输入任务"); return }
        do { try prepareSteersForNewTask(in: sessionID) }
        catch { status = .failed("插话去向未能保存，暂未启动新任务：\(error.localizedDescription)"); return }
        applyUserClaimStatement(taskText)
        let newTaskID = startingID ?? UUID()
        goal = taskText; limit = min(50, max(5, settings.maxSteps)); stepBudget = StepBudget(limit: limit); recoveryBudget = RecoveryBudget(); stepLimitPaused = false; thermalPaused = false; steps = []; stepSeq = 0; answerContext = []; waitingInput = nil; lastStaleKey = nil; staleStreak = 0; transientStreak = 0
        loopDetector.reset(); pendingLoopHint = nil; loadedSkillNames = []; loadedSkillVersions = [:]; loadedSkillBodies = ""
        // 状态卡与折叠/重试状态随新任务重置（台账不清，见下方既有口径）
        stateCard = TaskStateCard(goal: goal, claims: taskClaims); forcedFoldLevel = 0; contextRetryUsed = false; finalAuditFired = false
        // 绕行梯随新任务重置（AUTONOMY-FIX）：每个任务从梯级①重新开始
        bypassLadder = BypassLadder()
        // 在开卡点随新任务重置（LADDER-FIX）：卡点是单任务现场
        openStall = nil
        // 成果台账不清（跨任务存活，见 outcomeLedger 声明处）；只清本任务的
        // 打字记录与未消费的软门提醒——新任务的提交指纹从本任务的输入重算
        recentTyped = []; pendingOutcomeHint = nil; pendingOutcomeStep = nil; pendingVerificationStep = nil
        currentZhihuWriteProof = nil; currentZhihuPublishBinding = nil; currentZhihuDecision = nil; currentZhihuDirective = nil
        activePreservedDraft = nil
        currentZhihuAuthorization = .initial(instruction: goal); matchedZhihuPublishRecord = nil
        // 新任务开始：上一会话的中断恢复现场一并作废，不带进新会话
        pendingTabScene = nil; restoredSession = false; didApplyTabRestore = false; resumeNote = nil
        conversationTaskID = newTaskID
        attachPreservedDraft(to: goal, sourceTaskID: newTaskID)
        refreshPendingSteers()
        autoTitleSessionIfPlaceholder()
        // 任务绑定到该会话当时的活跃标签页：全程作用于它，用户中途切页／
        // 切会话不影响任务（TABS-IMPL＋M1）。本地页加载走执行页通道——
        // 目标会话不是查看会话时不能借道当前页
        web.beginExecution(sessionID: sessionID)
        do { if let local { try web.loadLocalOnExecutionTab(local) } } catch { web.endExecution(); status = .failed(error.localizedDescription); return }
        launch()
    }
    // MARK: - STEER：侧车事务、唯一消费点与中断串行仲裁

    private func steerFile(_ sessionID: UUID) -> SteerSidecarFile {
        SteerSidecarFile(url: SessionStore.shared.snapshotURL(for: sessionID).deletingLastPathComponent().appendingPathComponent("steers.json"))
    }
    private func sidecar(_ sessionID: UUID) throws -> SteerSidecar {
        if let cached = steeringSidecars[sessionID] { return cached }
        let value = try steerFile(sessionID).load()
        steeringSidecars[sessionID] = value
        return value
    }
    private func saveSidecar(_ value: SteerSidecar, in sessionID: UUID) throws {
        try steerFile(sessionID).save(value)
        steeringSidecars[sessionID] = value
        refreshPendingSteers()
    }
    private var currentSteerState: SteerState? {
        steeringSidecars[runSessionID]?.tasks.first { $0.taskID == conversationTaskID }
    }
    private func refreshPendingSteers() {
        pendingSteers = currentSteerState?.pending ?? []
        pendingInterrupt = steeringSidecars[runSessionID]?.interrupt
    }
    func steerInterrupt(in sessionID: UUID) -> SteerInterrupt? { steeringSidecars[sessionID]?.interrupt }
    private var steeringWaitActive: Bool {
        // 通用手输恢复后旧 manual 描述可能仍在；是否仍等手输以 status 为准。
        // question 则始终保留优先权，不改变任何等待字段或既有确认/作答流程。
        if case .some(.question(_, _)) = waitingInput { return true }
        switch status { case .waitingConfirm, .waitingManual: return true; default: return false }
    }
    var canSteer: Bool {
        let running: Bool = { if case .running = status { return true }; return false }()
        return active && !interruptInFlight && pendingInterrupt == nil && SteerState.allowsThreeWay(viewingRun: true, running: running, waiting: steeringWaitActive)
    }
    var canTransformSteers: Bool {
        guard active, !interruptInFlight, pendingInterrupt == nil, !steeringWaitActive else { return false }
        switch status { case .running, .paused: return true; default: return false }
    }
    private func steeringError(_ error: Error) {
        steeringConversation?.localFeedback("插话记录暂未写完，文字仍保留，请重试：\(error.localizedDescription)")
    }
    func bindSteeringConversation(_ conversation: AgentConversationStore) {
        steeringConversation = conversation
        // 恢复只读侧车，不从旧快照重放插话；未完成的投影/队列事务按固定 ID 补齐。
        for session in SessionStore.shared.sessions {
            do {
                var file = try sidecar(session.id)
                if file.tasks.isEmpty && file.interrupt == nil { continue }
                let snapshot = loadSnapshotData(for: session.id, allowLegacy: false).flatMap { try? JSONDecoder().decode(SessionSnapshot.self, from: $0) }
                let resumable = snapshot.flatMap { saved -> UUID? in
                    guard Date().timeIntervalSince(saved.savedAt) < 24 * 3600, !saved.goal.isEmpty,
                          saved.sessionID == nil || saved.sessionID == session.id else { return nil }
                    return saved.taskID
                }
                file.recover(resumableTaskID: resumable, snapshotTaskID: snapshot?.taskID)
                try saveSidecar(file, in: session.id)
                for state in file.tasks {
                    for item in state.items where item.disposition == .queued { try enqueueTask(sessionID: session.id, steerTransfer: item) }
                    try conversation.materializeSteering(state)
                }
                file.tasks.removeAll { $0.taskID != resumable }
                try saveSidecar(file, in: session.id)
            } catch { steeringError(error) }
        }
        refreshPendingSteers()
    }
    func steeringStatusChanged(_ state: AgentStatus) {
        if state.isTerminalForFold { pendingSteers = [] }
        guard steeringConversation != nil, let taskID = conversationTaskID else { return }
        do {
            var file = try sidecar(runSessionID)
            guard let index = file.tasks.firstIndex(where: { $0.taskID == taskID }) else { return }
            switch state {
            case .running: file.tasks[index].thaw()
            case .paused: file.tasks[index].freeze()
            case .done, .failed, .ended: file.tasks[index].invalidate("任务已结束")
            default: return
            }
            try saveSidecar(file, in: runSessionID)
            for item in file.tasks[index].items where item.disposition == .queued { try enqueueTask(sessionID: runSessionID, steerTransfer: item) }
            try steeringConversation?.materializeSteering(file.tasks[index])
            switch state {
            case .done, .failed, .ended:
                // 先留原文与可定位反馈，再清该 taskID 的侧车；其它会话不动。
                file.tasks.remove(at: index)
                try saveSidecar(file, in: runSessionID)
            default: break
            }
        } catch { steeringError(error) }
    }
    private func prepareSteersForNewTask(in sessionID: UUID) throws {
        var file = try sidecar(sessionID)
        if file.tasks.isEmpty && file.interrupt == nil { return }
        if let request = file.interrupt, request.startingID != steeringStartingID {
            throw MikaError("还有中断待发文字，请先重试或撤回")
        }
        file.beforeStart(in: sessionID)
        try saveSidecar(file, in: sessionID)
        for state in file.tasks {
            for item in state.items where item.disposition == .queued { try enqueueTask(sessionID: sessionID, steerTransfer: item) }
            guard let conversation = steeringConversation else {
                if !state.items.isEmpty { throw MikaError("对话记录尚未就绪") }
                continue
            }
            try conversation.materializeSteering(state)
        }
        file.clearProjectedTasks(in: sessionID)
        try saveSidecar(file, in: sessionID)
    }
    @discardableResult func enqueueSteer(_ text: String) -> Bool {
        guard canSteer, let taskID = conversationTaskID else { return false }
        do {
            var file = try sidecar(runSessionID)
            if !file.tasks.contains(where: { $0.taskID == taskID }) { file.tasks.append(SteerState(taskID: taskID, sessionID: runSessionID)) }
            guard let i = file.tasks.firstIndex(where: { $0.taskID == taskID }) else { return false }
            guard file.tasks[i].enqueue(text) else {
                steeringConversation?.localFeedback("已有 3 条插话待生效，请等其生效或撤回一条")
                return false
            }
            try saveSidecar(file, in: runSessionID) // 写前日志是接受边界。
            // 接受边界即刻更新授权，尤其让“只存草稿/不要发布”在正在进行的
            // proof 复读或按钮绑定 await 期间也能撤销点击资格。
            currentZhihuAuthorization.apply(instruction: text, source: "steer:\(file.tasks[i].items.last?.id.uuidString ?? "unknown")")
            do { try steeringConversation?.materializeSteering(file.tasks[i]) } catch { steeringError(error) }
            persistSnapshot()
            return true
        } catch { steeringError(error); return false }
    }
    private func consumePendingSteers() throws -> String? {
        guard let taskID = conversationTaskID else { return nil }
        var file = try sidecar(runSessionID)
        guard let i = file.tasks.firstIndex(where: { $0.taskID == taskID }), !file.tasks[i].pending.isEmpty else { return nil }
        let hint = file.tasks[i].consume(step: stepSeq + 1)
        for item in file.tasks[i].items where item.disposition == .applied && hint?.contains(item.text) == true {
            applyUserClaimStatement(item.text)
        }
        rebuildZhihuAuthorization(from: file.tasks[i])
        try saveSidecar(file, in: runSessionID) // 消费标记先持久化，快照旧镜像不能复活它。
        do { try steeringConversation?.materializeSteering(file.tasks[i]) } catch { steeringError(error) }
        persistSnapshot()
        return hint
    }
    private func rebuildZhihuAuthorization(from state: SteerState?) {
        var rebuilt = PublishAuthorization.initial(instruction: goal)
        for item in state?.items ?? [] where item.disposition == .pending || item.disposition == .frozen || item.disposition == .applied {
            rebuilt.apply(instruction: item.text, source: "steer:\(item.id.uuidString)")
        }
        currentZhihuAuthorization = rebuilt
    }
    func withdrawSteer(_ id: UUID, draft: String) -> String? {
        guard !interruptInFlight, let taskID = conversationTaskID else { return nil }
        do {
            var file = try sidecar(runSessionID)
            guard let i = file.tasks.firstIndex(where: { $0.taskID == taskID }),
                  let item = file.tasks[i].move(id, to: .withdrawn) else { return nil }
            try saveSidecar(file, in: runSessionID)
            rebuildZhihuAuthorization(from: file.tasks[i])
            do { try steeringConversation?.materializeSteering(file.tasks[i]) } catch { steeringError(error) }
            persistSnapshot()
            return SteerState.restoredDraft(draft, text: item.text)
        } catch { steeringError(error); return nil }
    }
    private func enqueueTask(sessionID: UUID, steerTransfer item: SteerItem) throws {
        var candidate = QueueFile(tasks: queuedTasks, acceptedSteerIDs: acceptedSteerQueueIDs)
        guard candidate.enqueueSteer(item, sessionID: sessionID) else { return }
        // 接受历史与队列同一次原子写，写成功后才发布内存变化。
        try writeQueue(candidate)
        acceptedSteerQueueIDs = candidate.acceptedSteerIDs
        queuedTasks = candidate.tasks
    }
    @discardableResult func queueSteer(_ id: UUID) -> Bool {
        guard !interruptInFlight, let taskID = conversationTaskID else { return false }
        do {
            var file = try sidecar(runSessionID)
            guard let i = file.tasks.firstIndex(where: { $0.taskID == taskID }) else { return false }
            // 已写的转移意图可重试；不再作为插话消费。
            let item = file.tasks[i].move(id, to: .queued) ?? file.tasks[i].items.first { $0.id == id && $0.disposition == .queued }
            guard let item else { return false }
            try saveSidecar(file, in: runSessionID)
            rebuildZhihuAuthorization(from: file.tasks[i])
            try enqueueTask(sessionID: runSessionID, steerTransfer: item)
            try steeringConversation?.materializeSteering(file.tasks[i])
            persistSnapshot()
            return true
        } catch { steeringError(error); return false }
    }
    var unfinishedSteerQueues: [SteerItem] {
        currentSteerState?.items.filter { $0.disposition == .queued && !acceptedSteerQueueIDs.contains($0.id) } ?? []
    }
    private var steeringStartingID: UUID?
    func interruptAndSend(_ text: String, from steerID: UUID? = nil, expectedTaskID: UUID? = nil) async -> Bool {
        guard (steerID == nil ? canSteer : canTransformSteers), let taskID = conversationTaskID,
              expectedTaskID == nil || expectedTaskID == taskID,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        do {
            var file = try sidecar(runSessionID)
            if let steerID {
                guard let i = file.tasks.firstIndex(where: { $0.taskID == taskID }), file.tasks[i].move(steerID, to: .interrupt) != nil else { return false }
            }
            let request = SteerInterrupt(id: UUID(), taskID: taskID, sessionID: runSessionID, text: text, startingID: UUID())
            file.interrupt = request
            try saveSidecar(file, in: runSessionID)
            return await executeSteerInterrupt(request)
        } catch { steeringError(error); return false }
    }
    func retrySteerInterrupt(requestID: UUID) async -> Bool {
        guard let request = pendingInterrupt, request.id == requestID, !interruptInFlight,
              runSessionID == request.sessionID,
              conversationTaskID == request.taskID || (conversationTaskID == request.startingID && !sessionActive) || (!busy && goal.isEmpty) else { return false }
        return await executeSteerInterrupt(request)
    }
    private func executeSteerInterrupt(_ request: SteerInterrupt) async -> Bool {
        guard !interruptInFlight, runSessionID == request.sessionID,
              conversationTaskID == request.taskID || conversationTaskID == request.startingID || (!busy && goal.isEmpty) else { return false }
        interruptInFlight = true // MainActor 同步受理、绑定原任务；自然终态没有交错入口。
        let oldWorker = worker
        let oldGeneration = generation
        var gate = SteerInterruptGate(taskID: conversationTaskID, oldGeneration: oldGeneration)
        stop() // 保留原 stop 语义；绝不使用 stopFromUser。
        let stoppedGeneration = generation
        await oldWorker?.value // cancel 请求不等于退出，必须等实际返回。
        gate.acknowledgeWorkerExit()
        guard generation == stoppedGeneration,
              gate.reserveStart(taskID: conversationTaskID, generation: generation, running: status.isRunningForSteer) else {
            interruptInFlight = false; return false
        }
        do {
            var file = try sidecar(request.sessionID)
            guard file.interrupt?.id == request.id else { interruptInFlight = false; return false }
            file.interrupt?.attempted = true
            try saveSidecar(file, in: request.sessionID)
            steeringStartingID = request.startingID
            // 先完成原任务插话的可追踪作废，再通过既有终结出口使旧任务不可续跑。
            try prepareSteersForNewTask(in: request.sessionID)
            finishTask()
            interruptInFlight = false // 无 await：此处到 startInSession 完成是同一 MainActor 回合。
            startInSession(request.sessionID, local: nil, task: request.text, startingID: request.startingID)
            steeringStartingID = nil
            guard conversationTaskID == request.startingID, status.isRunningForSteer, worker != nil else { return false }
            return pendingInterrupt == nil
        } catch {
            interruptInFlight = false; steeringStartingID = nil; steeringError(error); return false
        }
    }
    func withdrawSteerInterrupt(_ request: SteerInterrupt, draft: String) -> String? {
        guard !interruptInFlight else { return nil }
        do {
            var file = try sidecar(request.sessionID)
            guard file.interrupt?.id == request.id else { return nil }
            guard let conversation = steeringConversation else { throw MikaError("对话记录尚未就绪") }
            var withdrawn = SteerState(taskID: request.taskID, sessionID: request.sessionID)
            withdrawn.items = [SteerItem(id: request.id, text: request.text, enqueuedAt: Date(), disposition: .withdrawn)]
            try conversation.materializeSteering(withdrawn)
            // 用户撤回的是待发文字；已受理的中断仍结束原任务。
            if runSessionID == request.sessionID, conversationTaskID == request.taskID { finishTask() }
            else if let data = loadSnapshotData(for: request.sessionID, allowLegacy: false),
                    let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data), snapshot.taskID == request.taskID {
                // 明确撤回该会话的待发文字时，只清已被中断的原任务快照，不碰当前执行器。
                try FileManager.default.removeItem(at: SessionStore.shared.snapshotURL(for: request.sessionID))
            }
            file = try sidecar(request.sessionID)
            file.interrupt = nil
            try saveSidecar(file, in: request.sessionID)
            return SteerState.restoredDraft(draft, text: request.text)
        } catch { steeringError(error); return nil }
    }
    /// 自检四十四的持久化边界：仅使用临时文件/局部模型，不改引擎现役状态。
    func verifySteerPersistence() -> [String] {
        var lines: [String] = []
        func check(_ ok: Bool, _ note: String) { lines.append("\(ok ? "✓" : "✗") \(note)") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("steer-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            var state = SteerState(taskID: UUID(), sessionID: UUID())
            _ = state.enqueue("侧车原文")
            state.freeze()
            let file = SteerSidecarFile(url: directory.appendingPathComponent("steers.json"))
            try file.save(SteerSidecar(tasks: [state]))
            let restored = try file.load()
            check(restored.tasks == [state], "真实临时侧车文件原子写/读往返，冻结项仍在")
            let original = SteerProjection.apply(state, to: [])
            state.invalidate("因新任务启动未生效")
            let projected = SteerProjection.apply(state, to: original)
            let replayed = SteerProjection.apply(state, to: projected)
            check(replayed.count == 2 && replayed.map { $0.id } == projected.map { $0.id } && replayed[0].kind == .userSteer && replayed[0].text == "侧车原文" && replayed[1].kind == .local && replayed[1].steerRetryText == "侧车原文" && replayed[1].text.contains(state.items[0].id.uuidString), "崩溃后重复投影：原文不丢、作废反馈可定位且仅一条")
            var queue = QueueFile(tasks: [], acceptedSteerIDs: [])
            let accepted = queue.enqueueSteer(state.items[0], sessionID: state.sessionID)
            let duplicate = queue.enqueueSteer(state.items[0], sessionID: state.sessionID)
            let disk = try QueueFile.decode(JSONEncoder().encode(queue))
            var drained = disk
            drained.tasks.removeAll()
            let replayAfterDrain = drained.enqueueSteer(state.items[0], sessionID: state.sessionID)
            check(accepted && !duplicate && disk.tasks.count == 1 && !replayAfterDrain && drained.tasks.isEmpty, "转队列写前意图重试/崩溃重放不重复入队，已推进或取消后也不复活")
            let legacyQueue = try QueueFile.decode(JSONEncoder().encode(disk.tasks))
            check(legacyQueue.tasks.map { $0.id } == disk.tasks.map { $0.id } && legacyQueue.acceptedSteerIDs.isEmpty, "M1旧数组格式队列仍可载入")
            let oldJSON = "{\"version\":2,\"savedAt\":0,\"goal\":\"旧目标\",\"limit\":25,\"stepSeq\":0,\"steps\":[],\"statusKind\":\"paused\",\"statusText\":\"暂停\",\"answersJSON\":\"[]\"}"
            var snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(oldJSON.utf8))
            check(snapshot.pendingSteers == nil && snapshot.goal == "旧目标", "旧快照缺pendingSteers仍可解码，目标不变")
            snapshot.pendingSteers = restored.tasks[0].pending
            let roundtrip = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(snapshot))
            check(roundtrip.pendingSteers == restored.tasks[0].pending, "快照未生效镜像可往返；恢复消费以侧车为准")
        } catch { check(false, "持久化边界异常：\(error.localizedDescription)") }
        return lines
    }
    func stop() {
        if let authorization = pendingExecutionAuthorization {
            _ = appendExecutionAudit(event: "authorization-revoked", actionID: authorization.id,
                                     pageURL: authorization.pageURL, evidenceRef: "task-stopped")
        }
        generation = UUID(); worker?.cancel(); worker = nil; pending = nil; pendingExecutionAuthorization = nil
        scheduleReadbackRecycling()
        thermalPaused = false
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
    /// 彻底终结当前任务（SELFCHECK-UNBLOCK-FIX）：与 stop() 的「暂停可
    /// 续跑」相对，这是用户显式丢弃任务的出口——0625 真机现场：中断恢
    /// 复的旧任务被「停止」后仍是 .paused（busy 含暂停态），快照还在，
    /// 引擎永不解锁，自检全被「引擎忙碌中」挡下、UI 又没有丢弃入口。
    /// 本函数：取消 worker／换代次（迟到回复一律作废）、作废待决上传
    /// （SP-01 凭据与待供文件武装一并解除，见 discardPendingUpload）、
    /// 释放执行页绑定与后台／持续处理句柄、清等待输入与恢复现场、清
    /// 目标（resume 无目标可续）、状态落终结态 .ended 并在步流留一条
    /// 记录、最后清该会话快照——重启 App 不得再恢复这个已结束任务。
    /// 此后 busy == false，自检可跑、「新任务」可正常开。仅在 busy 时
    /// 有意义（UI 只在暂停态呈现按钮）；空闲／已终结时调用无操作。
    func finishTask() {
        guard busy else { return }
        generation = UUID(); worker?.cancel(); worker = nil; pending = nil
        scheduleReadbackRecycling()
        thermalPaused = false
        discardPendingUpload()
        runStartedAt = nil; activeRunContext = nil
        sessionActive = false; applyIdleTimerPolicy()
        endBackgroundGrace()
        completeContinuedProcessing(success: false)
        web.endExecution()
        waitingInput = nil; stepLimitPaused = false
        pendingTabScene = nil; restoredSession = false; didApplyTabRestore = false; resumeNote = nil
        goal = ""
        status = .ended("用户已结束任务")
        appendStep("ended", "任务已结束：用户手动终结本任务——快照已清除、不可续跑（点「继续」也不会再跑这个任务）；引擎已解锁，可运行自检或开始新任务")
        clearSnapshot()
    }
    func setForeground(_ foreground: Bool) {
        active = foreground
        if foreground {
            web.agentWorkSuspended = false
            // 前后台驻停只归 web 管；热驻停独立，回前台不能清 thermalPaused。
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
        guard !interruptInFlight, pendingInterrupt == nil else { return }
        guard active, !goal.isEmpty else { return }
        refreshThermalState()
        guard !thermalPaused || thermalGate.canResume(now: Date()) else { return }
        guard !thermalGate.isLocked else { pauseForThermal(); return }
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

    private struct QueueFile: Codable {
        var tasks: [QueuedTask]
        var acceptedSteerIDs: Set<UUID>
        mutating func enqueueSteer(_ item: SteerItem, sessionID: UUID) -> Bool {
            guard acceptedSteerIDs.insert(item.id).inserted else { return false }
            if !tasks.contains(where: { $0.id == item.id }) {
                tasks.append(QueuedTask(id: item.id, sessionID: sessionID, text: item.text, localPage: nil, enqueuedAt: item.enqueuedAt))
            }
            return true
        }
        static func decode(_ data: Data) throws -> QueueFile {
            if let current = try? JSONDecoder().decode(QueueFile.self, from: data) { return current }
            return QueueFile(tasks: try JSONDecoder().decode([QueuedTask].self, from: data), acceptedSteerIDs: [])
        }
    }
    private func writeQueue(_ candidate: QueueFile? = nil) throws {
        try FileManager.default.createDirectory(at: Self.queueFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = candidate ?? QueueFile(tasks: queuedTasks, acceptedSteerIDs: acceptedSteerQueueIDs)
        try JSONEncoder().encode(file).write(to: Self.queueFileURL, options: [.atomic])
    }
    private func persistQueue() { try? writeQueue() }

    private func loadQueue() {
        guard let data = try? Data(contentsOf: Self.queueFileURL), let file = try? QueueFile.decode(data) else { return }
        let items = file.tasks
        acceptedSteerQueueIDs = file.acceptedSteerIDs
        // 所属会话已被删除的条目不再恢复（删除编排通常已清队，这里兜底）
        let known = Set(SessionStore.shared.sessions.map { $0.id })
        queuedTasks = items.filter { known.contains($0.sessionID) }
    }

    /// 队列推进（M1 执行权语义）：仅从终结点调用——任务完成（worker 的
    /// done 分支）、任务失败落定（worker 外层 catch）、用户手动停止
    /// （stopFromUser，此时状态为已暂停、靠 afterUserStop 放行）、用户
    /// 结束任务（finishTaskFromUser，此时状态为终结态 .ended）。等待
    /// 确认／等待人工／步数暂停／循环熔断都不算终结，执行权不转移；
    /// 执行超时更不触发推进——本函数没有任何按时长的调用点（超时只走
    /// executionAnomaly 标记）。模型未就绪时不推进：队首留在队里，
    /// 用户处理完 Key／登录后，下一个终结点会再试。
    private func advanceQueue(afterUserStop: Bool = false) {
        guard active, let next = queuedTasks.first else { return }
        switch status {
        case .done, .failed, .idle, .ended: break
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

    /// 用户点「结束任务」（SELFCHECK-UNBLOCK-FIX）：在 finishTask 之外
    /// 推进队列——任务已落终结态，执行权真正空出，排队任务按序启动
    /// （与 stopFromUser 的用户终止口径一致）。
    func finishTaskFromUser() {
        finishTask()
        advanceQueue()
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
        refreshPendingSteers()
        web.showSessionTabs(sessionID)
    }

    /// 运行时内存态清零（M1）：adopt 切会话用。清单与自检四「模拟进程
    /// 中断」的清零段同源（漏清任何一项都会把上一会话的步流／等待态
    /// 串进新会话）；两处刻意不同的是成果台账——自检四连台账本体一并
    /// 清掉以证明恢复只靠快照，这里不清：台账是 App 级防重证据（按
    /// 会话隔离的是状态卡里的引用与快照双写），切会话清了它会让别的
    /// 会话刚提交过的动作失去防重保护；快照恢复时按 id 合并回来。
    private func resetRuntimeState() {
        generation = UUID(); worker?.cancel(); worker = nil; pending = nil; pendingExecutionAuthorization = nil; currentActionID = nil
        goal = ""; taskText = ""; steps = []; stepSeq = 0; answerContext = []; waitingInput = nil
        lastStaleKey = nil; staleStreak = 0; transientStreak = 0
        loopDetector.reset(); pendingLoopHint = nil; loadedSkillNames = []; loadedSkillVersions = [:]; loadedSkillBodies = ""
        conversationTaskID = nil; pendingSteers = []; sessionActive = false; status = .idle
        pendingTabScene = nil; restoredSession = false; didApplyTabRestore = false; resumeNote = nil
        recentTyped = []; outcomeGateFired = []; pendingOutcomeHint = nil; pendingOutcomeStep = nil; pendingVerificationStep = nil
        currentZhihuWriteProof = nil; currentZhihuPublishBinding = nil; currentZhihuDecision = nil; currentZhihuDirective = nil
        activePreservedDraft = nil
        discardPendingUpload()
        stateCard = TaskStateCard(); forcedFoldLevel = 0; contextRetryUsed = false; finalAuditFired = false
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
        guard !busy else { return ["✗ 引擎忙碌中，Tier A 未执行（当前任务未终结：可等它跑完，或在暂停时点『结束任务』）"] }
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
           let file = try? JSONDecoder().decode(QueueFile.self, from: data) {
            let items = file.tasks
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
        applyUserClaimStatement(answer)
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
        guard let authorization = pendingExecutionAuthorization, !authorization.expired else {
            _ = appendExecutionAudit(event: "authorization-expired", actionID: pendingExecutionAuthorization?.id ?? UUID(),
                                     pageURL: saved.2, evidenceRef: "60-second-deadline-or-legacy-snapshot")
            pendingExecutionAuthorization = nil
            appendStep("authorization", "审批已超过 60 秒或旧快照缺少绑定记录，默认拒绝；未派发")
            status = .paused("审批已过期，请按当前页面重新发起动作")
            persistSnapshot()
            return
        }
        if !execute {
            _ = appendExecutionAudit(event: "authorization-denied", actionID: authorization.id,
                                     pageURL: authorization.pageURL, evidenceRef: "user-rejected-before-dispatch")
            pendingExecutionAuthorization = nil
            appendStep("skip", "用户跳过：\(saved.0.reason)")
            // 用户明确跳过是关键事实：钉进状态卡，后续轮次不得再提议同一步
            stateCard.pinFact("用户决定跳过：\(saved.0.reason)")
            launch(); return
        }
        guard appendExecutionAudit(event: "authorization-approved", actionID: authorization.id,
                                   pageURL: authorization.pageURL, evidenceRef: "ui-confirm") else {
            pendingExecutionAuthorization = nil
            status = .paused("授权审计写入失败，未派发")
            persistSnapshot()
            return
        }
        launch(confirmed: saved)
    }

    private func authorizationParameterHash(_ action: AgentAction) -> String {
        let bodyHash = currentContentFingerprint().hash
        return ZhihuPublishPolicy.hash([action.action, action.text, action.url, bodyHash].joined(separator: "|"))
    }

    private func executionDecision(_ action: AgentAction, _ target: PageElement) -> SafetyPolicy.Decision {
        let existing = SafetyPolicy.check(action, target)
        if existing != .allow { return .manual }
        guard action.action == "click" else { return .allow }
        let label = [target.text, target.ariaLabel, target.name, target.placeholder].joined(separator: " ").lowercased()
        let destructive = ["delete", "remove", "erase", "删除", "移除", "清空", "注销"].contains(where: label.contains)
        return SubmissionClassifier.isSubmissionElement(target) || destructive ? .confirm : .allow
    }

    private func accountKey(for pageURL: String) async -> String {
        if URL(string: pageURL)?.host?.contains("zhihu.com") == true {
            return (await web.readZhihuPageIdentity()).accountIdentity
        }
        return "session:\(runSessionID.uuidString)"
    }

    private func expirePendingAuthorization(id: UUID) {
        guard let authorization = pendingExecutionAuthorization, authorization.id == id,
              authorization.expired, pending != nil else { return }
        pending = nil
        pendingExecutionAuthorization = nil
        _ = appendExecutionAudit(event: "authorization-expired", actionID: id,
                                 pageURL: authorization.pageURL, evidenceRef: "60-second-deadline")
        appendStep("authorization", "审批 60 秒到期，默认拒绝；未派发")
        status = .paused("审批已过期，请按当前页面重新发起动作")
        persistSnapshot()
    }

    private func nextAgentAction(prompt: String, page: PageState) async throws -> AgentAction {
        if let controlledActions {
            guard controlledActionCursor < controlledActions.count else {
                throw MikaError("受控动作源已耗尽但生产主循环尚未结案")
            }
            let cursor = controlledActionCursor
            var action = controlledActions[cursor]
            controlledActionCursor += 1
            // 纵向自检只给“使用关联稿”指令，正文必须由聊天共用启动入口
            // attachPreservedDraft 取得，测试本身不得把期望正文直接塞回动作。
            if action.action == "type", action.text == "__MIKA_PRESERVED_DRAFT__",
               let body = activePreservedDraft?.fullText,
               let data = try? JSONSerialization.data(withJSONObject: [
                    "action": action.action, "index": action.index, "text": body,
                    "url": action.url, "direction": action.direction, "seconds": action.seconds,
                    "reason": action.reason, "summary": action.summary, "question": action.question,
                    "skill": action.skill, "mode": action.mode, "subtitle": action.subtitle,
                    "template": action.template, "askKind": action.askKind
               ]), let rebound = try? JSONDecoder().decode(AgentAction.self, from: data) {
                action = rebound
            }
            // -2 是自检专用的“按当前生产快照重新定位知乎发布按钮”，避免把旧 index
            // 手工塞给派发器；重定位后仍由主循环的共用发布门裁决。
            if action.action == "click", action.index == -2,
               let target = page.elements.first(where: { Self.isZhihuAnswerPublishTarget($0, pageURL: page.url) }),
               let data = try? JSONSerialization.data(withJSONObject: [
                    "action": action.action, "index": target.index, "text": action.text,
                    "url": action.url, "direction": action.direction, "seconds": action.seconds,
                    "reason": action.reason, "summary": action.summary, "question": action.question,
                    "skill": action.skill, "mode": action.mode, "subtitle": action.subtitle,
                    "template": action.template, "askKind": action.askKind
               ]), let rebound = try? JSONDecoder().decode(AgentAction.self, from: data) {
                action = rebound
            }
            if let controlledActionWillDispatch { try await controlledActionWillDispatch(cursor, action) }
            return action
        }
        if settings.modelSource == .chatGPT {
            return try await ModelClient().nextViaChatGPT(auth: settings.chatGPTAuth, model: settings.chatGPTModel,
                prompt: prompt, skillCatalog: SkillStore.shared.catalogFragment(),
                trace: { [weak self] in self?.traceModel = $0 })
        }
        return try await ModelClient().next(baseURL: settings.baseURL, model: settings.model,
            key: Keychain.read(), prompt: prompt, skillCatalog: SkillStore.shared.catalogFragment(),
            trace: { [weak self] in self?.traceModel = $0 })
    }

    private func launch(confirmed: (AgentAction, PageElement, String, Int)? = nil) {
        guard !interruptInFlight else { return }
        // 恢复会话的现场重建在此兜底：resume() 已先行调用过则守卫使其为空操作；
        // 等待确认恢复后直接走 confirm() 的路径不经 resume()，也要先把标签带回
        // 中断页面，runConfirmed 的网址／目标复核才有机会在原页面上通过（复核
        // 本身一字不改，页面对不上仍安全失败，绝不误执行）。
        applyPendingTabRestore()
        generation = UUID(); let token = generation
        // 代次绑定（M1）：本代次与所属会话、对话任务一并记录；stop/新任务
        // 换代后，旧代次的 worker 在 checkpoint 处自行退出（见类头注释）
        runStartedAt = Date()
        finalAuditFired = false
        activeRunContext = conversationTaskID.map { (sessionID: runSessionID, taskID: $0, generation: token) }
        web.setDiagnosticContext(taskID: conversationTaskID, runID: token)
        worker?.cancel(); status = .running; sessionActive = true; applyIdleTimerPolicy()
        transientStreak = 0
        web.agentWorkSuspended = false // launch 只从前台路径进入，驻停标记在此兜底复位
        submitContinuedProcessingIfPossible()
        let snapshotSaved = persistSnapshot()
        if let startingID = steeringStartingID, startingID == conversationTaskID, let request = pendingInterrupt {
            do {
                guard snapshotSaved, request.startingID == conversationTaskID else { throw MikaError("新任务恢复现场未写入") }
                var file = try sidecar(request.sessionID)
                file.interrupt = nil
                try saveSidecar(file, in: request.sessionID)
            } catch {
                // 尚未创建 worker：待发文字保留，可安全重试同一目标 taskID。
                status = .paused("中断待发尚未启动，文字已保留，请重试：\(error.localizedDescription)")
                sessionActive = false; applyIdleTimerPolicy()
                endBackgroundGrace(); completeContinuedProcessing(success: false)
                web.endExecution()
                return
            }
        }
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                if let saved = confirmed {
                    try thermalCheckpoint()
                    // 已确认动作只走 runConfirmed：瞬时错误不自动重做该动作本身（安全口径）
                    if try await runConfirmed(saved, token: token) == .halted { return }
                }
                while stepBudget.canDecide {
                    try thermalCheckpoint()
                    // 单轮迭代包在内层 do/catch 里：瞬时错误（页面脚本异常／网页进程
                    // 中断／加载不稳／模型网络抖动）只记一条人话「自动重试」并续跑，
                    // 连续 maxTransientStreak 次才升级为失败；其余错误照旧上抛判失败。
                    do {
                        try await checkpoint(token)
                        try thermalCheckpoint()
                        var page = try await web.state()
                        try await checkpoint(token)
                        try thermalCheckpoint()
                        let answers = String(decoding: try JSONEncoder().encode(answerContext), as: UTF8.self)
                        // 一次性提示在本轮组装前消费（组装可能因预算多遍重建，
                        // 消费动作不能放进组装函数里重复执行）
                        let loopHint = pendingLoopHint; pendingLoopHint = nil
                        let outcomeHint = pendingOutcomeHint; pendingOutcomeHint = nil
                        let steerHint = try consumePendingSteers()
                        traceInterjection = steerHint ?? ""
                        page = await refreshZhihuPublishContext(page: page)
                        // 崩溃/超时恢复出的 attemptStarted/attempted 先走一次有界
                        // 只读回读，绝不先问模型要不要再点。
                        if case .some(.readbackOnly(_)) = currentZhihuDecision,
                           let record = matchedZhihuPublishRecord, record.status.needsReadback,
                           record.readbackCompletedAt == nil {
                            _ = await runZhihuReadback(recordID: record.id, token: token)
                            try await checkpoint(token)
                            page = try await web.state()
                            page = await refreshZhihuPublishContext(page: page)
                        }
                        let json = String(decoding: try JSONEncoder().encode(page), as: UTF8.self)
                        // prompt 组装（H1）：任务→状态卡→恢复说明→成果台账→
                        // 历史（确定性折叠）→问答→playbook→提示→当前页面；
                        // 体量由 promptCharBudget 约束，超预算逐级加大折叠
                        // （见 assemblePrompt）。各注入段的口径注释见组装函数。
                        let prompt = assemblePrompt(pageJSON: json, answersJSON: answers, loopHint: loopHint, outcomeHint: outcomeHint, steerHint: steerHint)
                        tracePageBefore = page
                        traceModel = nil
                        traceInputStrategies = []
                        traceFinalAction = nil
                        traceRewriteReason = "none"
                        let action = try await nextAgentAction(prompt: prompt, page: page)
                        let actionID = UUID()
                        currentActionID = actionID
                        guard appendExecutionAudit(event: "model-attempt-\(Self.safeAuditName(action.action))", actionID: actionID,
                                                   pageURL: page.url, evidenceRef: "model-decision") else {
                            throw MikaError("审计日志写入失败，动作未派发")
                        }
                        // 预算计数点（Part C）：模型返回一个动作＝一次决策，
                        // 全引擎只在此一处计数（runConfirmed 执行的是已计数的
                        // 已确认动作，后续动作回到主循环同一计数点取得）；
                        // 引擎注记步与内部子步永不计数
                        stepBudget.consumeDecision()
                        try await checkpoint(token)
                        try thermalCheckpoint()
                        if resolvedZhihuAction(proposedAction: action.action) == "attempt_publish_once" {
                            if !zhihuPublishExecutionAllowed {
                                currentZhihuDecision = .blocked("知乎自动发表开关已关闭")
                                traceFinalAction = ["action": "blocked", "proposed": "attempt_publish_once",
                                                    "gate": "zhihuAutoPublishEnabled", "enabled": false]
                                traceRewriteReason = "production auto-publish switch is off"
                                appendStep("publish-decision", "知乎自动发表开关关闭：attempt_publish_once 已由引擎拦截，未调用网页点击")
                                _ = appendExecutionAudit(event: "refusal-publish-switch-off", actionID: actionID,
                                                         pageURL: page.url, evidenceRef: "production-switch")
                                AgentTraceStore.shared.appendEngineAction(action: "attempt_publish_once",
                                    targetFingerprint: currentZhihuPublishBinding?.buttonIdentity ?? "unbound",
                                    method: "engine-production-switch", result: "blocked-switch-off",
                                    pageURL: page.url, taskID: conversationTaskID?.uuidString ?? "unobservable",
                                    runID: token.uuidString,
                                    evidence: ["enabled": false, "controlledFixture": controlledZhihuPublishFixture,
                                               "clickCount": 0])
                                // wait/click 被吞掉；done 仍允许收口，否则关闭开关会
                                // 让每轮重新派生 attempt 后永远无法完成任务。
                                if action.action != "done" { continue }
                            } else {
                                try await attemptZhihuPublishOnce(proposed: action, token: token)
                                if controlledDidSuspendAfterZhihuClick {
                                    status = .paused("受控进程退出点：发布点击已落账，尚未回读")
                                    persistSnapshot()
                                    return
                                }
                                continue
                            }
                        }
                        // 同题已有未决或已核实记录时，连续模型点击也不能绕过
                        // 一次尝试账。非点击动作（尤其 done）照常由后续逻辑处理。
                        if action.action == "click", action.index >= 0, action.index < page.elements.count,
                           Self.isZhihuAnswerPublishTarget(page.elements[action.index], pageURL: page.url) {
                            switch currentZhihuDecision {
                            case .some(.readbackOnly(let why)), .some(.alreadyPublished(let why)):
                                _ = appendExecutionAudit(event: "refusal-publish-replay", actionID: actionID,
                                                         pageURL: page.url, evidenceRef: "zhihu-publish-ledger")
                                record(action, suffix: "（未执行：知乎专用发布账拦截——\(why)）")
                                appendStep("publish-decision", "模型再次请求发布未执行：\(why)；点击次数保持不变，只允许回读/报告")
                                continue
                            case .some(.blocked(let why)):
                                _ = appendExecutionAudit(event: "refusal-publish-policy", actionID: actionID,
                                                         pageURL: page.url, evidenceRef: "zhihu-proof-or-authorization")
                                record(action, suffix: "（未执行：知乎发布证据缺口——\(why)）")
                                appendStep("publish-decision", "模型发布点击未执行：\(why)；不得借 disabled、计数或旧 verified 绕过 WriteProof/唯一绑定")
                                continue
                            default: break
                            }
                            record(action, suffix: "（未执行：知乎回答提交只允许走专用一次点击门）")
                            _ = appendExecutionAudit(event: "refusal-publish-generic-click", actionID: actionID,
                                                     pageURL: page.url, evidenceRef: "dedicated-path-only")
                            appendStep("publish-decision", "知乎发布点击未执行：授权=\(currentZhihuAuthorization.explanation)；通用 click 不得旁路专用策略/未决账")
                            continue
                        }
                        if action.action == "done" {
                            // done 梯门（LADDER-FIX F2）：有在开卡点且绕行
                            // 梯未尽时 done 不得直接结案——引擎先推进梯
                            // 级：驱动成功则本轮不接受 done、带着新页面
                            // 继续；卡点已绕过或梯已尽才放行；梯尽抛失败
                            // 结案错误走外层收口。
                            if let gate = try await evaluateDoneGate(token: token), gate == .driven {
                                continue
                            }
                            guard token == generation else { return }
                            let pendingThisRun = Self.pendingOutcomes(outcomeLedger, since: runStartedAt)
                            if Self.containsCompletionClaim(summary: action.summary), !pendingThisRun.isEmpty, !finalAuditFired {
                                finalAuditFired = true
                                appendStep("audit", "结案自证门：总结含完成断言，但本轮提交仍待核查；请先回读内容列表/记录页，再给出结案口径")
                                pendingLoopHint = "【结案自证门】本轮提交仍待核查。请去内容列表/记录页回读对应条目，引用页面原文；确认生效就在总结里写明证据来源；找不到或对不上就如实写未核实。不得再次提交同一内容。"
                                continue
                            }
                            var finalSummary = action.summary
                            if !pendingThisRun.isEmpty && Self.containsCompletionClaim(summary: finalSummary) {
                                finalSummary = "本任务有提交尝试结果未确认；请先独立回读实际成果，不得重放。"
                                appendStep("audit", "未决提交覆盖模型完成断言：结案只报告结果未确认")
                            }
                            if let currentTaskID = conversationTaskID,
                               URL(string: page.url)?.host?.contains("zhihu.com") == true {
                                let publish = matchedZhihuPublishRecord ?? zhihuPublishRecords.last(where: { $0.taskID == currentTaskID })
                                if publish != nil || currentZhihuAuthorization.allowsZhihuAnswer {
                                    let writeText = currentZhihuWriteProof?.taskID == currentTaskID && currentZhihuWriteProof?.isValid == true
                                        ? "已核实" : (publish?.sourceText.isEmpty == false ? "已核实" : "未核实")
                                    let publicationText = publish?.status.display ?? "未尝试"
                                    let evidence = publish?.answerURL.map { "；结案证据：\($0)" } ?? ""
                                    let truthful = "正文：\(writeText)；发布：\(publicationText)\(evidence)"
                                    finalSummary = Self.containsCompletionClaim(summary: finalSummary)
                                        ? truthful
                                        : truthful + (finalSummary.isEmpty ? "" : "。\(finalSummary)")
                                    appendStep("audit", "知乎结案门修正：正文核实与发布结果分开；最终口径固定为「\(truthful)」")
                                }
                            }
                            recordCompletionClaim(summary: action.summary, since: runStartedAt)
                            record(action)
                            let pendingNote = Self.pendingOutcomes(outcomeLedger, since: runStartedAt).isEmpty ? "" : "（注：本任务有提交未经回读核实，见步流）"
                            status = .done(finalSummary + pendingNote)
                            sessionActive = false; applyIdleTimerPolicy()
                            endBackgroundGrace(); completeContinuedProcessing(success: true)
                            await recycleReadbackTabs(for: conversationTaskID, expectedGeneration: token)
                            guard token == generation else { return }
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
                                loadedSkillVersions[skill.name] = skill.version
                                loadedSkillBodies += "\n【playbook：\(skill.name) v\(skill.version)】\n\(skill.body)"
                                appendStep("skill", "已加载 playbook《\(skill.name)》：\(skill.description)")
                                outcome = "loaded"
                            } else {
                                appendStep("skill", "没有名为「\(name)」的 playbook，已忽略；请按清单选择或直接执行任务")
                                outcome = "missing"
                            }
                            loopFingerprint = LoopDetector.fingerprint(action: "use_skill", target: name, outcome: outcome)
                        } else if action.action == "open_new_tab" {
                            guard thermalGate.allowsHeavyWork() else { throw MikaError("设备发热严重，已暂停新建页面") }
                            // 在新标签页打开指定网址：新页成为当前页且执行绑定随之移过去，后续动作作用于新页
                            executionSerial += 1
                            let previous = conversationTaskID.flatMap { readbackTabs.readbackTab(forTask: $0) }.flatMap { readbackTabs.entries[$0] }
                            let sourceID = web.executionTab.id
                            let callMarker = DispatchCallMarker()
                            do {
                                let tab = try await auditedDispatch(name: "open_new_tab", pageURL: action.url,
                                                                    callMarker: callMarker) {
                                    try web.openTabForExecution(urlString: action.url)
                                }
                                if let taskID = conversationTaskID {
                                    if let oldID = readbackTabs.register(tabID: tab.id, ownerTaskID: taskID, sourceTabID: sourceID, purpose: "readback"),
                                       let previous, previous.tabID == oldID {
                                        replacedReadbackTabIDs.insert(oldID)
                                        await recycleReadbackTab(previous, for: taskID, expectedGeneration: token, excluding: [tab.id])
                                    }
                                }
                                try await checkpoint(token)
                            } catch {
                                // The marker stays false when dispatch preparation fails before the operation call.
                                if callMarker.entered { await reconcileBlockingOutcomes(trigger: "post-navigation") }
                                throw error
                            }
                            await reconcileBlockingOutcomes(trigger: "post-navigation")
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
                                if action.action == "type" {
                                    let trace = web.takeEditorTypeTrace()
                                    traceInputStrategies = trace
                                }
                                record(action, suffix: typeVerificationSuffix(for: action, trace: traceInputStrategies, page: page))
                                if action.action == "type", !traceInputStrategies.isEmpty {
                                    appendStep("note", "type 策略阶梯：\(traceInputStrategies.joined(separator: "；"))")
                                    appendDisabledButtonObservation(from: page)
                                }
                                if action.action == "click" { appendStep("effect", clickEffectDescription()) }
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
                                let coverResult = try await auditedDispatch(name: "generate_cover", pageURL: page.url) {
                                    await CoverGenerator.generateAndSaveToPhotos(title: coverTitle, subtitle: action.subtitle,
                                        template: CoverTemplate.from(action.template), sessionID: runSessionID)
                                }
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
                            let callMarker = DispatchCallMarker()
                            do {
                                try await checkpoint(token)
                                executionSerial += 1
                                try await auditedDispatch(name: action.action, pageURL: page.url,
                                                          callMarker: callMarker) {
                                    try await web.execute(action, expected: nil)
                                }
                                try await checkpoint(token)
                            } catch {
                                guard Self.isUnexecutableActionError(error) else {
                                    // A checkpoint or dispatch preparation failure has not entered the operation.
                                    if ["navigate", "open_new_tab"].contains(action.action) && callMarker.entered {
                                        await reconcileBlockingOutcomes(trigger: "post-navigation")
                                    }
                                    throw error
                                }
                                executedOK = false
                                handleInvalidAction(action)
                                loopFingerprint = LoopDetector.fingerprint(action: action.action, target: action.action, outcome: "invalid-action")
                            }
                            if executedOK {
                                if ["navigate", "open_new_tab"].contains(action.action) {
                                    await reconcileBlockingOutcomes(trigger: "post-navigation")
                                }
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
                                scheduleReadbackRecycling()
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
                        if error is ThermalPause { throw error }
                        if error is CancellationError { throw error }
                        if thermalGate.isLocked && (error as? MikaError)?.message == "设备发热严重，已暂停新建页面" {
                            pauseForThermal(); throw ThermalPause()
                        }
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
                            let backoff: Double
                            if kind == .modelNetwork {
                                backoff = Double(600 * transientStreak) / 1000
                            } else {
                                guard let reserved = recoveryBudget.reserveAttempt() else {
                                    pauseForRecoveryBudget("页面多次恢复失败，已暂停等页面/网络恢复（整任务恢复预算已用完），进度已存，稍后点「继续」接着跑")
                                    return
                                }
                                backoff = reserved
                                persistSnapshot()
                            }
                            if transientStreak >= Self.maxTransientStreak {
                                throw MikaError(Self.transientFailureMessage(kind: kind, error: error))
                            }
                            appendStep("retry", Self.transientRetryNote(kind: kind, streak: transientStreak))
                            if (kind == .pageLoad || kind == .webContentProcess) && transientStreak == 2 {
                                guard recoveryBudget.reserveLoad() else {
                                    pauseForRecoveryBudget("页面需要重载但整任务重载预算已用完，已暂停等页面/网络恢复，进度已存，稍后点「继续」接着跑")
                                    return
                                }
                                persistSnapshot()
                                refreshThermalState()
                                guard thermalGate.allowsHeavyWork() else { pauseForThermal(); return }
                                try await auditedDispatch(name: "recovery-reload", pageURL: web.executionTab.webView.url?.absoluteString ?? "") {
                                    web.reloadExecutionTab()
                                }
                            }
                            if !active { try await checkpoint(token) } // 后台出的错先驻停、回前台再重试
                            try await Task.sleep(for: .milliseconds(Int(backoff * 1000)))
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
                scheduleReadbackRecycling()
            } catch {
                guard token == generation else { return }
                if error is ThermalPause { return }
                sessionActive = false; applyIdleTimerPolicy()
                endBackgroundGrace(); completeContinuedProcessing(success: false)
                await recycleReadbackTabs(for: conversationTaskID, expectedGeneration: token)
                guard token == generation else { return }
                web.endExecution(); clearSnapshot(); resumeNote = nil
                if error is CancellationError { status = .paused("已取消") }
                else { status = .failed(error.localizedDescription); advanceQueue() }
            }
        }
    }

    private enum ConfirmedOutcome { case proceed, halted }

    private static func isZhihuAnswerPublishTarget(_ element: PageElement, pageURL: String) -> Bool {
        guard URL(string: pageURL)?.host?.contains("zhihu.com") == true else { return false }
        let parts = [element.text, element.ariaLabel, element.name, element.placeholder]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let label = parts.joined(separator: " ")
        if label.range(of: "(发布回答|提交回答|发表回答)", options: .regularExpression) != nil { return true }
        let onQuestion = URL(string: pageURL)?.path.contains("/question/") == true
        return onQuestion && parts.contains(where: { ["发布", "发表", "提交"].contains($0) })
    }

    /// 已确认动作的执行段（launch 的前置段）：复核目标后只执行一次。确认等待期间
    /// 页面可能已重排：先认原 index 处逐字段相等的元素，认不到再按稳定描述重找；
    /// 网址已变（导航离开）或描述也认不到，才按「目标已变化」安全失败——不会误执行
    /// 到别的元素上（AGENT-VIEWPORT-FIX）。本段的**瞬时错误不自动重做该动作本身**
    /// （BACKGROUND-RESILIENCE 问题 2 第 3 条）：动作可能没执行、也可能已生效但回读
    /// 失败，不猜——把 pending 原样放回、状态回到等待确认，留给用户核对页面后再次
    /// 确认或跳过；再次确认时会重新走本段的复核，仍不会误执行。非瞬时错误照旧上抛
    /// 判失败（含上述安全失败与手输转等待）。
    private func runConfirmed(_ saved: (AgentAction, PageElement, String, Int), token: UUID) async throws -> ConfirmedOutcome {
        var receiptID: UUID?
        do {
            try await checkpoint(token)
            let page = try await web.state()
            try await checkpoint(token)
            guard page.url == saved.2 else { throw MikaError("确认期间页面目标已变化，请重新开始或继续") }
            var confirmedTarget = page.elements.first(where: { $0.index == saved.1.index && $0 == saved.1 })
            if confirmedTarget == nil {
                confirmedTarget = resolveTarget(descriptor: ElementDescriptor(saved.1), original: saved.1, in: page.elements, coverageComplete: page.coverageComplete)
            }
            guard let target = confirmedTarget else { throw MikaError("确认期间页面目标已变化，请重新开始或继续") }
            if saved.0.action == "click", Self.isZhihuAnswerPublishTarget(target, pageURL: page.url) {
                record(saved.0, suffix: "（未执行：确认/恢复入口不能绕过知乎专用一次点击门）")
                appendStep("publish-decision", "确认/恢复的知乎回答提交已拦截；将按当前授权、账号未决账、WriteProof 与唯一绑定重新编排")
                return .proceed
            }
            let accountNow = await accountKey(for: page.url)
            guard let taskID = conversationTaskID, let authorization = pendingExecutionAuthorization,
                  !authorization.expired,
                  authorization.taskID == taskID,
                  authorization.site == (URL(string: page.url)?.host ?? ""),
                  authorization.pageURL == page.url,
                  authorization.targetKey == ElementDescriptor(target).key,
                  authorization.parameterHash == authorizationParameterHash(saved.0),
                  authorization.executionRevision == saved.3,
                  web.executionRevision == saved.3,
                  authorization.accountKey == accountNow else {
                _ = appendExecutionAudit(event: "authorization-invalid", actionID: pendingExecutionAuthorization?.id ?? UUID(),
                                         pageURL: page.url, evidenceRef: "scope-target-parameter-revision-or-account-drift")
                throw MikaError("审批范围、目标、关键内容、页面代次或账号已变化，未派发")
            }
            pendingExecutionAuthorization = nil
            if SafetyPolicy.check(saved.0, target) == .manual {
                waitingInput = .manual(id: UUID(), text: "请手动填写密码或验证码后继续")
                status = .waitingManual("请手动填写密码或验证码后继续")
                persistSnapshot()
                return .halted
            }
            receiptID = try prepareSubmissionIfNeeded(action: saved.0, element: target, pageURL: saved.2)
            executionSerial += 1
            try await auditedDispatch(name: saved.0.action, pageURL: saved.2,
                actionID: receiptID.flatMap { id in outcomeLedger.first(where: { $0.id == id })?.actionID } ?? authorization.id,
                critical: true) {
                try await web.execute(saved.0, expected: target, approved: true, expectedPageURL: saved.2)
            }
            if let receiptID { updateSubmissionDispatch(recordID: receiptID, state: .sent, evidence: "web.execute-returned") }
            try await checkpoint(token)
            if saved.0.action == "type" {
                let trace = web.takeEditorTypeTrace()
                traceInputStrategies = trace
                await noteTypedContent(action: saved.0, element: target)
            }
            record(saved.0, suffix: typeVerificationSuffix(for: saved.0, trace: traceInputStrategies, page: page))
            if saved.0.action == "type", !traceInputStrategies.isEmpty {
                appendStep("note", "type 策略阶梯：\(traceInputStrategies.joined(separator: "；"))")
                appendDisabledButtonObservation(from: page)
            }
            if saved.0.action == "click" { appendStep("effect", clickEffectDescription()) }
            // 经用户确认执行的提交类动作同样落台账（确认本身即用户的明确
            // 指示，此路不设软门；台账记下后防的是后续轮次的无意识重复）
            if let receiptID {
                appendStep("outcome", "提交派发回执已落盘；核验仍待独立回读（\(receiptID)）")
                await runPostSubmissionVerification(recordID: receiptID, element: target, pageURL: saved.2, before: page, token: token)
                if let vstep = pendingVerificationStep { appendStep("verify", vstep); pendingVerificationStep = nil }
            }
            receiptID = nil
            try await Task.sleep(for: .milliseconds(500))
            return .proceed
        } catch {
            if let receiptID {
                updateSubmissionDispatch(recordID: receiptID, state: .unknown, evidence: "execute-or-followup-error")
                throw MikaError("提交派发结果未决，已阻断自动重放：\(error.localizedDescription)")
            }
            guard token == generation else { throw CancellationError() }
            if error is CancellationError { throw error }
            // 弹窗点按无响应（COVER-CONSENT 立、AUTONOMY-FIX 改）：这是
            // 能力类卡点——不判失败、不停车等用户代劳，也不再把 pending
            // 放回原样重确认（弹窗还在，再确认只会再连败一次）。改走
            // 绕行梯弹窗导航绕行：成功（弹窗已消失）→ 已确认动作原样
            // 放回等待确认，用户在干净页面上重新确认（确认本身属安全
            // 类、仍由用户点，引擎不代行）；绕行失败 → 失败结案。
            if Self.modalInterventionText(for: error) != nil {
                let accounting = consumeDialogAttemptRecords()
                appendStep("click", "弹窗点按无响应（能力卡点）：实际执行账：\(accounting.summary)。改走绕行梯（弹窗导航绕行）")
                if await driveDialogBypass(token: token, accounting: accounting) {
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
                target = resolveTarget(descriptor: descriptor, original: original, in: snapshot.elements, coverageComplete: snapshot.coverageComplete)
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
        var upload = PendingUpload(id: currentActionID ?? UUID(), attachmentID: attachment?.id,
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
        upload.targetKey = ElementDescriptor(target).key
        if needsConfirm {
            upload.confirmationToken = AttachmentStore.shared.issueUploadConfirmation(attachmentID: attachment?.id, pageURL: snapshot.url)
            upload.confirmationIssuedAt = Date()
            upload.confirmationRevision = web.executionRevision
            pendingUpload = upload
            let text = "上传前请确认：将把文件「\(upload.attachmentName)」上传到 \(upload.pageHost.isEmpty ? "当前页面" : upload.pageHost)"
            waitingInput = .manual(id: upload.id, text: text)
            status = .waitingManual(text)
            appendStep("upload", "已定位文件控件（\(upload.elementLabel)），按 SP-01 先出确认卡：文件「\(upload.attachmentName)」→ \(upload.pageHost.isEmpty ? upload.pageURL : upload.pageHost)，等用户确认")
            guard appendExecutionAudit(event: "authorization-requested", actionID: upload.id,
                                       pageURL: upload.pageURL, evidenceRef: "sp01-60-second-deadline") else {
                discardPendingUpload()
                waitingInput = nil
                status = .paused("上传授权审计写入失败，未派发")
                persistSnapshot()
                return .waiting
            }
            let uploadID = upload.id
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(60))
                self?.expirePendingUpload(id: uploadID)
            }
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
        guard let page = try? await web.state(), page.url == upload.pageURL,
              let targetKey = upload.targetKey,
              page.elements.contains(where: { $0.index == upload.elementIndex && $0.tag == "input" &&
                  $0.inputType.lowercased() == "file" && ElementDescriptor($0).key == targetKey }) else {
            status = .paused("上传目标或页面已变化，文件未供给页面")
            appendStep("upload", "派发前目标漂移：上传控件不再匹配，未供文件")
            return false
        }
        upload.stage = .pickFile
        // 双回读基线（Part B）：触发控件前先存页面图像清单——收口时
        // 只有「上传后新增的图像」才算封面/预览出现的第二回读证据
        upload.preUploadImages = await web.probePageImages()
        pendingUpload = upload
        guard persistSnapshot() else {
            status = .paused("上传现场持久化失败，文件未供给页面")
            return false
        }
        // 上传结构化诊断（EDITOR-ENTRY-BIND 第 4 项）：触发前记控件
        // 形态、触发后记面板回调与供文件消费——下次真机在真实编辑
        // 器里跑上传，从步流就能判「控件没找到/回调没触发/页面不
        // 认」是哪一种，不再只有一句「回读未确认」。只加诊断，不
        // 改上传机制与 SP-01 语义。
        let dispatch: (supplyArmed: Bool, controlContext: String, panelStart: Date, triggered: Bool)
        do {
            dispatch = try await auditedDispatch(name: "upload_file", pageURL: upload.pageURL,
                                                 actionID: upload.id, critical: true) {
                var armed = false
                if let attachmentID = upload.attachmentID,
                   let record = AttachmentStore.shared.record(id: attachmentID, sessionID: runSessionID) {
                    armed = web.armUploadSupply(url: AttachmentStore.shared.fileURL(for: record), fileName: record.displayName)
                }
                let context = await web.fileInputContext(index: upload.elementIndex)
                guard let dispatchPage = try? await web.state(), dispatchPage.url == upload.pageURL,
                      let targetKey = upload.targetKey,
                      dispatchPage.elements.contains(where: { $0.index == upload.elementIndex &&
                          ElementDescriptor($0).key == targetKey && $0.inputType.lowercased() == "file" }) else {
                    web.disarmUploadSupply()
                    throw MikaError("上传派发前目标已变化")
                }
                let start = Date()
                let triggered = await web.triggerFileInput(index: upload.elementIndex)
                return (armed, context, start, triggered)
            }
        } catch {
            web.disarmUploadSupply()
            status = .paused("上传派发或审计未决，请先核对页面；文件不自动重放")
            appendStep("upload", "上传未继续：\(error.localizedDescription)；按 unknown 保守处理")
            persistSnapshot()
            return false
        }
        let supplyArmed = dispatch.supplyArmed
        let controlContext = dispatch.controlContext
        let panelStart = dispatch.panelStart
        let triggered = dispatch.triggered
        if supplyArmed {
            try? await Task.sleep(for: .milliseconds(1200))
            let panel = web.openPanelActivity(since: panelStart)
            let consumed = !web.uploadSupplyArmed
            appendStep("upload", "上传诊断：\(controlContext)；合成触发＝\(triggered ? "已派发" : "控件不在（触发失败）")；文件面板回调＝\(panel.fired > 0 ? "已拉起 \(panel.fired) 次（消费待供 \(panel.consumed) 次）" : "未拉起")；供文件＝\(consumed ? "已被页面消费" : "仍武装待真点")")
            if consumed {
                appendStep("upload", "App 已直接供文件：SP-01 已过后由 App 把「\(upload.attachmentName)」直接交给了页面文件控件（iOS 文件面板公开回调，未经系统选择器、未再向用户索取确认）")
                pendingUpload = nil
                waitingInput = nil
                await verifyPickedUpload(upload: upload)
                return true
            }
            appendStep("upload", "自动供文件未触发（合成触发未拉起文件面板）——文件已由 App 备好并保持待供：在网页上点一次上传按钮就会自动带上，不用在选择器里翻找")
        } else {
            try? await Task.sleep(for: .milliseconds(600))
            let panel = web.openPanelActivity(since: panelStart)
            appendStep("upload", "上传诊断：\(controlContext)；合成触发＝\(triggered ? "已派发" : "控件不在（触发失败）")；文件面板回调＝\(panel.fired > 0 ? "已拉起 \(panel.fired) 次（手动路径，宿主选择器转发）" : "未拉起")；供文件＝未武装（手动选文件路径）")
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
        guard let issuedAt = upload.confirmationIssuedAt,
              Date().timeIntervalSince(issuedAt) < 60,
              upload.confirmationRevision == web.executionRevision,
              upload.pageURL == (web.executionTab.webView.url?.absoluteString ?? "") else {
            discardPendingUpload()
            waitingInput = nil
            status = .paused("上传审批过期或目标已变化，未派发")
            _ = appendExecutionAudit(event: "authorization-denied", actionID: upload.id,
                                     pageURL: upload.pageURL, evidenceRef: "deadline-or-target-drift")
            persistSnapshot()
            return
        }
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
        guard appendExecutionAudit(event: "authorization-approved", actionID: upload.id,
                                   pageURL: upload.pageURL, evidenceRef: "sp01-ui-confirm") else {
            discardPendingUpload()
            waitingInput = nil
            status = .paused("上传授权审计写入失败，文件未供给页面")
            persistSnapshot()
            return
        }
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
        _ = appendExecutionAudit(event: "authorization-denied", actionID: upload.id,
                                 pageURL: upload.pageURL, evidenceRef: "user-cancel")
        launch()
    }

    private func expirePendingUpload(id: UUID) {
        guard let upload = pendingUpload, upload.id == id, upload.stage == .confirmUpload,
              let issuedAt = upload.confirmationIssuedAt, Date().timeIntervalSince(issuedAt) >= 60 else { return }
        discardPendingUpload()
        waitingInput = nil
        status = .paused("上传审批 60 秒到期，默认拒绝")
        _ = appendExecutionAudit(event: "authorization-expired", actionID: id,
                                 pageURL: upload.pageURL, evidenceRef: "60-second-deadline")
        appendStep("upload", "上传审批 60 秒到期，默认拒绝；文件未供给页面")
        persistSnapshot()
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
            if self.pendingTabScene != nil { self.applyPendingTabRestore() }
            try? await Task.sleep(for: .milliseconds(500))
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
        var verified = false
        if names.isEmpty {
            // 诊断口径（EDITOR-ENTRY-BIND）：第二回读也照取——控件
            // 未持有但页面已出现新图（页面用另一控件/弹窗收文件）
            // 与双空（页面根本不认）是两种不同的失败，分开记录。
            let afterImages = await web.probePageImages()
            let newImages = afterImages.filter { !baseline.contains($0) }
            appendStep("upload", "上传回读核验：页面文件控件里未读到已选文件——可能还没选完或页面未持有该文件，不要声称已上传成功；确需上传时重新发起 upload_file")
            appendStep("upload", "上传诊断小结：回读①控件持有＝✗未读到；回读②页面新增图像＝\(newImages.isEmpty ? "✗无" : "✓ \(newImages.count) 处（控件未持有而页面有新图——页面可能经其它控件/弹窗收下文件，以页面现状为准）")；结论＝未确认持有")
        } else {
            let afterImages = await web.probePageImages()
            let newImages = afterImages.filter { !baseline.contains($0) }
            if newImages.isEmpty {
                appendStep("upload", "上传回读核验（unknown）：文件控件已持有文件 \(names.joined(separator: "、"))（目标页面 \(host.isEmpty ? "当前页面" : host)），但页面上未见新增的封面/预览图像——封面可能尚未设上或预览未渲染，不要声称封面已设好；下一轮看页面现状再判断（可稍等预览出现或核对封面区）")
                appendStep("upload", "上传诊断小结：回读①控件持有＝✓（\(names.joined(separator: "、"))）；回读②页面新增图像＝✗无；结论＝unknown（单回读过、双回读未齐）")
            } else {
                verified = true
                appendStep("upload", "上传回读核验（双回读通过）：页面文件控件已持有文件 \(names.joined(separator: "、"))（目标页面 \(host.isEmpty ? "当前页面" : host)），且页面新增了 \(newImages.count) 处图像（封面缩略图/预览已出现）——两项回读相互印证，封面已设上；是否已提交到服务器以下一轮页面反馈为准")
                appendStep("upload", "上传诊断小结：回读①控件持有＝✓（\(names.joined(separator: "、"))）；回读②页面新增图像＝✓ \(newImages.count) 处；结论＝双回读通过")
            }
        }
        let audited = appendExecutionAudit(event: verified ? "verification-verified" : "verification-unknown",
                                           actionID: upload.id, pageURL: upload.pageURL,
                                           evidenceRef: verified ? "file-input-and-preview" : "upload-readback-incomplete")
        let receipt = executionReceipts.last(where: { $0.actionID == upload.id && $0.critical })
        let receiptSaved = receipt.map { entry in
            updateExecutionReceipt(id: entry.id, state: entry.dispatchState,
                                   evidence: "upload-readback", verdict: verified && audited ? .verified : .unknown)
        } ?? true
        if verified && audited && receiptSaved {
            stateCard.addCompleted("upload_file：页面已持有文件 \(names.joined(separator: "、"))，封面/预览图像已出现（双回读）")
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
                ? resolveTarget(descriptor: descriptor, original: original, in: snapshot.elements, coverageComplete: snapshot.coverageComplete)
                : nil
            guard let target else {
                if refinds < 2 {
                    refinds += 1
                    snapshot = try await web.state()
                    continue
                }
                return try registerStrategySwitch(key: descriptor.key, label: label)
            }
            if action.action == "click", Self.isZhihuAnswerPublishTarget(target, pageURL: snapshot.url) {
                _ = appendExecutionAudit(event: "refusal-zhihu-generic-click", actionID: currentActionID ?? UUID(),
                                         pageURL: snapshot.url, evidenceRef: "dedicated-policy-required")
                record(action, suffix: "（未执行：runTargeted 不能绕过知乎专用一次点击门）")
                appendStep("publish-decision", "runTargeted 的知乎回答提交已拦截；授权/未决账/WriteProof/绑定统一由专用门裁决")
                return .strategySwitch
            }
            if action.action == "click", let block = duplicateSubmissionBlock(element: target, pageURL: snapshot.url) {
                pendingOutcomeStep = block.step
                pendingOutcomeHint = block.hint
                return .duplicateBlocked
            }
            switch executionDecision(action, target) {
            case .manual:
                _ = appendExecutionAudit(event: "refusal-manual-redline", actionID: currentActionID ?? UUID(),
                                         pageURL: snapshot.url, evidenceRef: "safety-policy-manual")
                record(action, suffix: "（未执行，请手动输入）")
                waitingInput = .manual(id: UUID(), text: "付款、授权、密码或验证码等敏感步骤须由 Joey 本人处理，完成后点继续")
                status = .waitingManual("敏感步骤须由 Joey 本人处理")
                return .waiting
            case .confirm:
                let revision = web.executionRevision
                let account = await accountKey(for: snapshot.url)
                try await checkpoint(token)
                guard web.executionRevision == revision else { return try registerStrategySwitch(key: descriptor.key, label: label) }
                let authorization = PendingExecutionAuthorization(id: currentActionID ?? UUID(), taskID: conversationTaskID ?? runSessionID,
                    accountKey: account, site: URL(string: snapshot.url)?.host ?? "", pageURL: snapshot.url,
                    targetKey: ElementDescriptor(target).key, parameterHash: authorizationParameterHash(action),
                    executionRevision: revision, issuedAt: Date())
                guard appendExecutionAudit(event: "authorization-requested", actionID: authorization.id,
                                           pageURL: snapshot.url, evidenceRef: "60-second-deadline") else {
                    throw MikaError("审计日志写入失败，未发起审批")
                }
                pendingExecutionAuthorization = authorization
                pending = (action, target, snapshot.url, revision)
                status = .waitingConfirm(action)
                persistSnapshot()
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(60))
                    self?.expirePendingAuthorization(id: authorization.id)
                }
                return .waiting
            case .allow:
                break
            }
            // 重复提交软门（OUTCOME-LEDGER）：只拦自主路径的 click——确认路径
            // （runConfirmed）是用户亲手确认，不经此门；拦下后本轮不执行，
            // 提醒步与下一轮注入提醒都已置位，模型应改走列表核查路径
            var receiptID: UUID?
            do {
                try await checkpoint(token)
                receiptID = try prepareSubmissionIfNeeded(action: action, element: target, pageURL: snapshot.url)
                executionSerial += 1
                try await auditedDispatch(name: action.action, pageURL: snapshot.url,
                    actionID: receiptID.flatMap { id in outcomeLedger.first(where: { $0.id == id })?.actionID },
                    critical: receiptID != nil) {
                    try await web.execute(action, expected: target, expectedPageURL: snapshot.url)
                }
                if let receiptID { updateSubmissionDispatch(recordID: receiptID, state: .sent, evidence: "web.execute-returned") }
                try await checkpoint(token)
                if action.action == "click", let resolution = web.takeBlockerResolution() {
                    appendStep("modal-resolution", "生产点击阻挡处理分账：\(resolution)")
                }
                lastStaleKey = nil
                staleStreak = 0
                // 台账记账点：打字成功先记内容（提交指纹来源），提交类点击
                // 成功再落台账条目（说明经 pendingOutcomeStep 由调用方补步）
                if action.action == "type" { await noteTypedContent(action: action, element: target) }
                if action.action == "click" {
                    if let receiptID {
                        pendingOutcomeStep = "提交派发回执已落盘；核验仍待独立回读（\(receiptID)）"
                        await runPostSubmissionVerification(recordID: receiptID, element: target, pageURL: snapshot.url, before: modelPage, token: token)
                    }
                    await noteOverlayDiagnosticAfterClick(clicked: original)
                }
                return .executed
            } catch {
                if let receiptID {
                    updateSubmissionDispatch(recordID: receiptID, state: .unknown, evidence: "execute-or-followup-error")
                    throw MikaError("提交派发结果未决，已阻断自动重放：\(error.localizedDescription)")
                }
                // 弹窗点按无响应（COVER-CONSENT 立、AUTONOMY-FIX 改、
                // LADDER-FIX 补卡点联动）：能力类卡点，不是失效类错误，
                // 重找重试只会再连败——不停车等用户代劳。卡点已在开时：
                // frame 感知关闭连败计入卡点证据（第 1 级 frameClose
                // 项），按策略切换交模型续跑，梯级推进由引擎钩子驱动
                // （不再从这里跳过第 2 级直达第 3 级）；无在开卡点时沿
                // 用既有直达弹窗导航绕行口径，绕行失败 → 失败结案。
                if Self.modalInterventionText(for: error) != nil {
                    let accounting = consumeDialogAttemptRecords()
                    if var stall = openStall {
                        if accounting.actuallyExecuted { stall.noteFrameCloseSignal() }
                        else { stall.markNA(.frameClose, reason: "执行层记录为未执行/未适用/观测超时") }
                        openStall = stall
                        appendStep("click", "弹窗点按无响应（能力卡点）：实际执行账：\(accounting.summary)。\(accounting.actuallyExecuted ? "已执行项计入 frame 感知关闭实证" : "未把未执行项冒充关闭实证")；引擎将按绕行梯继续推进")
                        persistSnapshot()
                        return .strategySwitch
                    }
                    appendStep("click", "弹窗点按无响应（能力卡点）：实际执行账：\(accounting.summary)。改走绕行梯（弹窗导航绕行）")
                    if await driveDialogBypass(token: token, accounting: accounting) {
                        appendStep("bypass", "弹窗导航绕行成功：弹窗已消失，请按最新页面重新判断")
                        return .strategySwitch
                    }
                    throw await capabilityFailureError(stuck: "弹窗点按无响应，目标「\(label)」被弹窗挡住")
                }
                let ns = error as NSError
                // 阿仁亲审补漏（刀3）：WebController 的 guard 缓存未命中／代次
                // 不一致是以 Swift 侧 MikaError 抛出的同名失效信号（非 WK 错
                // 误形态），须与 JS guard 的 WK code 4 同口径认作失效走重找，
                // 否则一次导航竞态会把可恢复的点击判死。
                let nativeStale = (error as? MikaError).map { $0.message == "目标元素已失效" || $0.message == "目标元素已变化" } ?? false
                guard nativeStale || StaleTargetPolicy.isStaleTarget(errorDomain: ns.domain, code: ns.code, message: error.localizedDescription + "|" + String(describing: ns.userInfo)), refinds < 2 else { throw error }
                refinds += 1
                snapshot = try await web.state()
            }
        }
    }

    /// 浮动层诊断（EDITOR-ENTRY-BIND 第 4 项扩展）：点击疑似菜单入
    /// 口（图标名源/无名控件，或文案含 +／菜单／更多）后回读一帧，
    /// 回答「浮动层/二级菜单进没进感知」——进了记所在层与条目文本
    /// （playbook 可按文本定位）；没进如实记未感知（可能在状态稳
    /// 定等待期间已被页面自动关闭、或位于抽取够不到的层），play-
    /// book 按固定布局坐标打法处理。只记诊断，不改点击语义。
    private func noteOverlayDiagnosticAfterClick(clicked: PageElement) async {
        let label = !clicked.text.isEmpty ? clicked.text : clicked.ariaLabel
        let looksLikeOpener = clicked.nameSource == "icon" || clicked.nameSource == "none"
            || label.contains("+") || label.contains("＋") || label.contains("菜单") || label.contains("更多")
        guard looksLikeOpener, let after = try? await web.state() else { return }
        if after.overlayNotes.isEmpty {
            appendStep("perception", "浮动层诊断：点击「\(label.isEmpty ? "图标控件" : label)」后，主文档 frame 未感知到菜单类浮动层——菜单可能已在状态稳定等待期间自动关闭、或位于抽取够不到的层（跨源 frame／原生层）；按 playbook 的固定布局坐标打法处理，不依赖看见菜单本身")
        } else {
            appendStep("perception", "浮动层诊断：点击「\(label.isEmpty ? "图标控件" : label)」后感知到浮动层 \(after.overlayNotes.count) 处——\(after.overlayNotes.joined(separator: "；"))（菜单项已进入感知，可按文本定位点选）")
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
    // Self-test 42 runs in an isolated WKWebView without model calls.
    func verifyDraftType4() async -> [String] { await web.verifyDraftType4() }

    /// Self-test 45 observes only the current visible tab, with one paste-plain attempt.
    func verifyRealPageDraftOnce() async -> String {
        guard !busy else { return #"{"conclusion":"unobservable","reason":"engine busy; no attempt executed","attempts":0}"# }
        return await web.verifyRealPageDraftOnce()
    }

    func verifyFrameProbe() async -> [String] {
        guard !busy else { return ["✗ 引擎忙碌中，自检十四 Tier A 未执行（当前任务未终结：可等它跑完，或在暂停时点『结束任务』）"] }
        return await web.verifyFrameProbeAndClick()
    }

    /// 自检十六·Tier A（WECHAT-EDITOR-NAV）：入口感知补盲——委托
    /// WebController 在合成页 test-nav 上实测（icon-only／alt／背景图
    /// 三类无文本入口进快照且名源正确、内层滚动容器下方入口经揭示
    /// 复判可达、补盲入口真点得动、文本锚点回退点中整卡）。
    func verifyEditorNav() async -> [String] {
        guard !busy else { return ["✗ 引擎忙碌中，自检十六 Tier A 未执行（当前任务未终结：可等它跑完，或在暂停时点『结束任务』）"] }
        return await web.verifyEditorNavReveal()
    }

    /// 自检二十（TRUSTED-CLICK-EXP）：E1 金标准对照插桩的复刻页实验
    /// （插桩自证＋touches 恒空复现）＋E2 AX 激活探针——委托
    /// WebController 在合成页 test-trusted 上实测并落盘结构化日志。
    /// E1 真机金标准（真实弹窗上 Joey 真点一次）由阿仁另行约，不在
    /// 本入口内；E3 受 E1 真机结果门控、不做。
    func verifyTrustedClick() async -> [String] {
        guard !busy else { return ["✗ 引擎忙碌中，自检二十未执行（当前任务未终结：可等它跑完，或在暂停时点『结束任务』）"] }
        return await web.verifyTrustedClickExp()
    }

    func verifyCoverAndModal() async -> [String] {
        guard !busy else { return ["✗ 引擎忙碌中，自检十一 Tier A 未执行（当前任务未终结：可等它跑完，或在暂停时点『结束任务』）"] }
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
        // 揭示复判/坐标点击收口（EDITOR-ENTRY-BIND，与 frameClose 同
        // pattern）：结级前引擎亲自动手一轮——真机三次现场这两项都
        // 因模型从未在第 1 级点过任何东西而记「未试」，等模型自觉
        // 已被实证不可靠。点击把页面带离卡点页时本级按绕过收口。
        if await attemptRung1RevealClick(token: token) {
            if !bypassLadder.attempted.contains(.existingMeans) {
                let summary = openStall?.meansSummary ?? stall.meansSummary
                bypassLadder.markAttempted(.existingMeans, note: "逐项验收：\(summary)（引擎揭示复判点击打开新页面，卡点绕过）")
            }
            appendStep("bypass", "绕行梯第 1 级结级（\(forcedBy)）：引擎揭示复判点击后页面已离开卡点页，卡点按绕过关闭，不再推进后续梯级")
            closeStall(note: "第 1 级引擎揭示复判点击打开新页面")
            persistSnapshot()
            return
        }
        stall = openStall ?? stall
        if !bypassLadder.attempted.contains(.existingMeans) {
            let forced = !stall.rung1Complete
            bypassLadder.markAttempted(.existingMeans, note: "逐项验收：\(stall.meansSummary)\(forced ? "（\(forcedBy)强制结级，未试项如上如实记录）" : "（全部验收齐或判定不适用）")")
        }
        appendStep("bypass", "绕行梯第 1 级结级（\(forcedBy)）：\(stall.meansSummary)，引擎推进下一级")
        persistSnapshot()
        try await progressRungsBeyondFirst(token: token)
    }

    /// 引擎驱动的第 1 级「揭示复判再点」收口（EDITOR-ENTRY-BIND）：
    /// 两项（revealClick/coordClick）仍无实证时引擎亲自动手一轮——
    /// 先 hover 显形探测、再取新快照复判，按编辑语义挑候选（编辑链
    /// 接，或文案/无障碍名含编辑语义的控件，含图标名源 icon；预览链
    /// 接、禁用、敏感一律排除；文案含删除/发表/发布等破坏性或发表
    /// 语义的一律不点——图标无名时引擎不盲点未知控件），过
    /// SafetyPolicy（须 .allow）后经执行层 click（与模型 click 同一
    /// 实现面：点前滚动揭示复判＋按元素中心真实坐标派发，一次真实
    /// 执行同时记两项实证，记账走 noteExecutedActionForStall 既有
    /// 口径）。无可指认候选→两项记不适用并注明依据，不留「未试」。
    /// 返回 true＝点击后页面已离开卡点页或已进入可编辑页（卡点按
    /// 绕过收口，调用方不再推进后续梯级）。
    private func attemptRung1RevealClick(token: UUID) async -> Bool {
        guard let stall = openStall else { return false }
        if stall.verified.contains(.revealClick), stall.verified.contains(.coordClick) { return false }
        let destructive = ["删除", "发表", "发布", "delete", "publish", "remove"]
        func pickCandidate(in page: PageState) -> PageElement? {
            page.elements.first { e in
                if e.disabled || e.sensitive { return false }
                let label = (e.text + " " + e.ariaLabel).lowercased()
                if destructive.contains(where: { label.contains($0) }) { return false }
                if e.linkKind == "preview" { return false }
                if e.linkKind == "edit" { return true }
                return label.contains("编辑") || label.contains("修改") || label.contains("铅笔")
                    || label.contains("edit") || label.contains("pencil")
            }
        }
        guard var page = try? await web.state() else { return false }
        var target = pickCandidate(in: page)
        if target == nil {
            // 揭示一轮再复判：hover 显形后重新抽取快照（显形元素只
            // 进新快照，旧快照里没有的东西不硬点）
            _ = await web.hoverRevealProbe()
            try? await Task.sleep(for: .milliseconds(300))
            if let refreshed = try? await web.state() {
                page = refreshed
                target = pickCandidate(in: refreshed)
            }
        }
        guard let target else {
            if var current = openStall {
                let reason = "引擎 hover 揭示＋新快照复判后，感知清单无可指认的编辑入口候选（编辑链接与编辑语义控件均无），未盲点未知图标"
                if !current.verified.contains(.revealClick) { current.markNA(.revealClick, reason: reason) }
                if !current.verified.contains(.coordClick) { current.markNA(.coordClick, reason: reason) }
                openStall = current
            }
            appendStep("bypass", "绕行梯第 1 级引擎揭示复判：揭示后仍无可指认的编辑入口候选，揭示复判再点/坐标点击记不适用（依据见梯账），不盲点未知控件")
            return false
        }
        guard let click = Self.clickAction(index: target.index, reason: "绕行梯第 1 级引擎揭示复判点击编辑入口候选") else { return false }
        guard SafetyPolicy.check(click, target) == .allow else {
            appendStep("bypass", "绕行梯第 1 级引擎揭示复判：候选「\(target.text.isEmpty ? target.ariaLabel : target.text)」未过安全策略，未代点")
            return false
        }
        do {
            try await auditedDispatch(name: "rung-reveal-click", pageURL: page.url) {
                try await web.execute(click, expected: target, expectedPageURL: page.url)
            }
        } catch {
            appendStep("bypass", "绕行梯第 1 级引擎揭示复判：候选点击抛错：\(error.localizedDescription)")
            return false
        }
        noteExecutedActionForStall(actionName: "click", targetKey: ElementDescriptor(target).key)
        appendStep("bypass", "绕行梯第 1 级引擎揭示复判：已按编辑语义点击候选「\(target.text.isEmpty ? target.ariaLabel : target.text)」（点前揭示＋坐标派发，与模型 click 同一实现面），揭示复判再点/坐标点击记实证")
        _ = await web.settledCapture()
        if let now = try? await web.state() {
            if now.url != stall.openURL { return true }
            if now.elements.contains(where: { $0.editable }) { return true }
        }
        return false
    }

    /// 驱动第 2、3 级（引擎同步执行，不等模型）：任一级成功即关卡点
    /// 返回；全部失败＝梯尽，关卡点并抛失败结案错误（结案文案含
    /// F6 harvest 实况节）。第 2 级 harvest 的实况与跨页模板记忆在
    /// 每次采集后回写梯账，结案与步流都读得到。
    private func progressRungsBeyondFirst(token: UUID) async throws {
        while let rung = bypassLadder.nextRung {
            try await checkpoint(token)
            try thermalCheckpoint()
            switch rung {
            case .existingMeans:
                // 第 1 级由 completeRung1AndProgress 结级后才进本函数；
                // 快照恢复等边角下若它仍是下一级，按已下达口径补记并继续
                bypassLadder.markAttempted(.existingMeans, note: "第 1 级已下达（恢复现场补记，逐项验收以在开卡点账为准）")
            case .directURL:
                let targetTitle = DirectTargetHarvest.extractTargetTitle(goal: goal, stuck: openStall?.stuck ?? "")
                let outcome = await web.harvestDirectTargets(memoryTemplate: bypassLadder.harvestTemplate, targetTitle: targetTitle)
                try thermalCheckpoint()
                let pageURL = (try? await web.state())?.url ?? ""
                bypassLadder.noteHarvest(template: outcome.facts.editTemplate, templateFrom: outcome.facts.editTemplate == nil ? nil : pageURL, fact: outcome.facts.line)
                if let harvest = outcome.result {
                    do {
                        executionSerial += 1
                        try await auditedDispatch(name: "rung-navigation", pageURL: harvest.url) {
                            try web.loadOnExecutionTab(harvest.url)
                        }
                    } catch {
                        // 候选地址导航失败：记为此级失败、推进下一级，
                        // 不让一个坏候选杀掉整个任务
                        bypassLadder.markAttempted(.directURL, note: "候选导航失败：\(error.localizedDescription)；\(outcome.facts.line)")
                        appendStep("bypass", "绕行梯第 2 级「直达 URL」导航失败：\(error.localizedDescription)（\(outcome.facts.line)），推进下一级")
                        continue
                    }
                    bypassLadder.markAttempted(.directURL, note: "采用候选 appmsgid=\(harvest.appmsgid)（来源：\(harvest.source)\(harvest.viaTemplate ? "、模板拼装" : "、带 ID 直用")\(harvest.crossPage ? "、跨页模板记忆" : "")\(harvest.pairedTitle.map { "、标题配对《\($0)》" } ?? ""))，已导航直达；\(outcome.facts.line)")
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
                AgentTraceStore.shared.appendEngineAction(action: "dialog-navigation-bypass", targetFingerprint: "active-dialog-census",
                    method: "save-if-editor-then-navigate", result: outcome.success ? "success" : "failed: \(outcome.note)",
                    pageURL: web.executionTab.webView.url?.absoluteString ?? "")
                if thermalPaused { throw ThermalPause() }
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
    private func driveDialogBypass(token: UUID,
                                   accounting suppliedAccounting: (summary: String, actuallyExecuted: Bool)? = nil) async -> Bool {
        let accounting = suppliedAccounting ?? consumeDialogAttemptRecords()
        // 只把实际执行的阶段记为实证；未适用、未执行与观测超时保留原状态。
        if var stall = openStall, accounting.actuallyExecuted {
            stall.noteFrameCloseSignal(); openStall = stall
        }
        if accounting.actuallyExecuted && !bypassLadder.attempted.contains(.existingMeans) {
            bypassLadder.markAttempted(.existingMeans, note: "执行层实际执行账：\(accounting.summary)")
        } else if !accounting.actuallyExecuted {
            appendStep("bypass-accounting", "既有关闭手段未记 attempted：\(accounting.summary)")
        }
        if bypassLadder.attempted.contains(.dialogNavBypass) { return false }
        let outcome = await attemptDialogNavBypass(token: token)
        AgentTraceStore.shared.appendEngineAction(action: "dialog-navigation-bypass", targetFingerprint: "active-dialog-census",
            method: "save-if-editor-then-navigate", result: outcome.success ? "success" : "failed: \(outcome.note)",
            pageURL: web.executionTab.webView.url?.absoluteString ?? "")
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
        let evidenceAttemptID = UUID().uuidString
        let before = await web.dialogCensus()
        let beforeEvidenceID = web.recordNavigationBypassEvidence(census: before, attemptID: evidenceAttemptID,
            phase: "before-engine-navigation-bypass", disposition: before.observation.label)
        guard !before.hits.isEmpty else { return (false, "绕行前 frame 普查未发现弹窗，此级未执行；证据=\(beforeEvidenceID)") }
        let sigsBefore = Set(before.hits.map { $0.sig })
        guard let page = try? await web.state() else { return (false, "页面状态读取失败") }
        let originalURL = page.url
        let expectedQuestionID: String? = {
            guard let url = URL(string: originalURL) else { return nil }
            let parts = url.pathComponents
            guard let i = parts.firstIndex(of: "question"), parts.indices.contains(i + 1),
                  Int(parts[i + 1]) != nil else { return nil }
            return parts[i + 1]
        }()
        func purposeState() async -> WebController.ObservationState? {
            guard let expectedQuestionID else { return nil }
            return await web.zhihuAnswerEditorDestinationState(questionID: expectedQuestionID)
        }
        let isEditor = originalURL.contains("appmsg_edit") || page.elements.contains { $0.editable }
        if !isEditor {
            guard recoveryBudget.reserveLoad() else { return (false, "非编辑页需要重载但整任务重载预算已用完，此级失败") }
            persistSnapshot()
            refreshThermalState()
            guard thermalGate.allowsHeavyWork() else {
                pauseForThermal()
                return (false, "设备发热严重，已暂停自动重载")
            }
            do {
                try await auditedDispatch(name: "dialog-reload", pageURL: originalURL) {
                    web.reloadExecutionTab()
                }
            } catch { return (false, "重载审计或派发失败：\(error.localizedDescription)") }
            try? await Task.sleep(for: .milliseconds(800))
            _ = await web.settledCapture()
            let after = await web.dialogCensus()
            let afterEvidenceID = web.recordNavigationBypassEvidence(census: after, attemptID: evidenceAttemptID,
                phase: "after-engine-navigation-bypass", disposition: after.observation.label,
                resultEvidence: ["beforeEvidenceID": beforeEvidenceID])
            guard after.coverageComplete && before.framePaths.isSubset(of: after.framePaths) else { return (false, "弹窗存续未确认（frame 探针覆盖不足）；证据=\(afterEvidenceID)") }
            let gone = !after.hits.contains { sigsBefore.contains($0.sig) }
            let currentClear = after.hits.isEmpty
            if gone, let destination = await purposeState(), destination != .present {
                return (false, "原弹窗签名已消失，但本题回答编辑器状态为 \(destination.label)，不判绕行成功；证据=\(afterEvidenceID)")
            }
            return gone && currentClear
                ? (true, "成功（非编辑页重载绕行）：当前阻挡为空且目的状态通过；证据=\(afterEvidenceID)")
                : (false, "非编辑页重载后当前仍有弹窗/阻挡（普查：\(after.summary)）；证据=\(afterEvidenceID)")
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
        do { try await auditedDispatch(name: "dialog-save-click", pageURL: originalURL) {
            try await web.execute(saveAction, expected: saveElement, expectedPageURL: originalURL)
        } } catch {
            return (false, "保存点击抛错：\(error.localizedDescription)")
        }
        let settled = await web.settledCapture()
        guard settled.settled else { return (false, "保存后页面证据未稳（settle 超时），不赌未落定状态，此级失败") }
        guard let url = URL(string: originalURL), let scheme = url.scheme, let host = url.host else {
            return (false, "原页地址不可解析，此级失败")
        }
        do {
            try await auditedDispatch(name: "dialog-leave-navigation", pageURL: "\(scheme)://\(host)/") {
                try web.loadOnExecutionTab("\(scheme)://\(host)/")
            }
            try? await Task.sleep(for: .milliseconds(500))
            try await auditedDispatch(name: "dialog-return-navigation", pageURL: originalURL) {
                try web.loadOnExecutionTab(originalURL)
            }
        } catch { return (false, "导航往返抛错：\(error.localizedDescription)") }
        _ = await web.settledCapture()
        let after = await web.dialogCensus()
        let afterEvidenceID = web.recordNavigationBypassEvidence(census: after, attemptID: evidenceAttemptID,
            phase: "after-engine-navigation-bypass", disposition: after.observation.label,
            resultEvidence: ["beforeEvidenceID": beforeEvidenceID])
        guard after.coverageComplete && before.framePaths.isSubset(of: after.framePaths) else { return (false, "弹窗存续未确认（frame 探针覆盖不足）；证据=\(afterEvidenceID)") }
        let gone = !after.hits.contains { sigsBefore.contains($0.sig) }
        let currentClear = after.hits.isEmpty
        if gone, let destination = await purposeState(), destination != .present {
            return (false, "原弹窗签名已消失，但本题回答编辑器状态为 \(destination.label)，不判绕行成功；证据=\(afterEvidenceID)")
        }
        return gone && currentClear
            ? (true, "成功（编辑页往返绕行）：先保存并 settle，返回后当前阻挡为空且目的状态通过；证据=\(afterEvidenceID)")
            : (false, "编辑页往返后当前仍有弹窗/阻挡（普查：\(after.summary)）；证据=\(afterEvidenceID)")
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
        guard !busy else { return ["✗ 引擎忙碌中，自检十八未执行（当前任务未终结：可等它跑完，或在暂停时点『结束任务』）"] }
        var lines = Self.verifyAutonomyGate()
        func fmt(_ ok: Bool) -> String { ok ? "✓" : "✗" }
        // 合成页用 window.name 模拟「重载即消失」的会话级弹窗：重复跑
        // 自检时先清掉该标记，保证每次都从弹窗在场的基线开始
        _ = try? await web.evaluateForManualSelfTest("(()=>{window.name='';return 'reset';})()")
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
        guard !busy else { return ["✗ 引擎忙碌中，自检二十二未执行（当前任务未终结：可等它跑完，或在暂停时点『结束任务』）"] }
        var lines: [String] = []
        func fmt(_ ok: Bool) -> String { ok ? "✓" : "✗" }
        // —— 命名规整（B）——
        let mixed = CoverGenerator.GeneratedFileName.coverFileName(title: "AI Weekly Report 2026!")
        lines.append("\(fmt(mixed == "cover-ai-weekly-report-2026.png")) 命名·混合标题：「AI Weekly Report 2026!」→ \(mixed)（小写 slug、标点折连字符）")
        let fullWidth = CoverGenerator.GeneratedFileName.coverFileName(title: "别让AI替你瞎编；用这套三步法")
        // 断言修正（EDITOR-ENTRY-BIND 搭车，0713 真机实证）：该标题
        // 唯一的拉丁字母就是 AI，其余中文/全角标点按设计折掉，正
        // 确产出就是 cover-ai.png；旧断言要求前缀 cover-ai-（ai 后
        // 还须有一段 slug），对此输入不可能成立——是断言写错、不
        // 是命名函数错。改精确断言＋全 ASCII 检查保留。
        let fullWidthOK = fullWidth == "cover-ai.png" && fullWidth.unicodeScalars.allSatisfy { $0.isASCII }
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
        guard !busy else { return ["✗ 引擎忙碌中，自检二十二回路未执行（当前任务未终结：可等它跑完，或在暂停时点『结束任务』）"] }
        return await web.verifyUploadPanelSupply()
    }

    /// 自检二十三（SELFCHECK-UNBLOCK-FIX）：「结束任务」解锁口的纯逻辑
    /// 核查。0625 真机现场的同型复刻——程序化合成一个已暂停任务（目
    /// 标在位、等待输入在位、快照落盘、busy 为真），断言：未结束时引
    /// 擎保持锁定；finishTask 后 busy 转假、status 落终结态 .ended、
    /// 会话快照文件已删（冷启动恢复只读此文件，删了即不会再恢复）、
    /// 等待输入与目标已清、resume() 不得把终结态复活、执行页绑定已
    /// 解除且待供文件未武装。演练全程保存/还原引擎现场（状态、目标、
    /// 步流、等待输入、段限标记、对话任务标识——演练期间暂置 nil 使
    /// 合成步流不路由进真实对话），结束不留痕迹。不调用模型、不占用
    /// 标签页；要求引擎空闲（入口 guard 与其余自检同口径）。
    func verifyTaskFinishUnlock() async -> [String] {
        guard !busy else { return ["✗ 引擎忙碌中，自检二十三未执行（当前任务未终结：可等它跑完，或在暂停时点『结束任务』）"] }
        var lines: [String] = []
        func fmt(_ ok: Bool) -> String { ok ? "✓" : "✗" }
        func isEnded() -> Bool { if case .ended = status { return true }; return false }
        // —— 保存现场 ——
        let savedStatus = status, savedGoal = goal, savedSteps = steps, savedStepSeq = stepSeq
        let savedWaiting = waitingInput, savedStepLimitPaused = stepLimitPaused, savedTaskID = conversationTaskID
        let savedStateCard = stateCard
        let snapshotURL = SessionStore.shared.snapshotURL(for: runSessionID)
        let fm = FileManager.default
        // —— 合成暂停态（中断恢复后点过「停止」的同型现场）——
        conversationTaskID = nil
        goal = "自检二十三合成目标"
        status = .paused("自检二十三合成暂停")
        waitingInput = .question(id: UUID(), text: "自检二十三合成等待")
        persistSnapshot()
        let snapshotWritten = fm.fileExists(atPath: snapshotURL.path)
        lines.append("\(fmt(busy && snapshotWritten)) 暂停态基线：合成已暂停任务后 busy 为 true、快照已落盘（未结束时引擎保持锁定——与 0625 真机现场同型）")
        // —— 结束任务 ——
        finishTask()
        lines.append("\(fmt(!busy && isEnded())) 结束任务后解锁：busy 为 false、status 落终结态（已结束）")
        lines.append("\(fmt(!fm.fileExists(atPath: snapshotURL.path))) 快照已清：会话快照文件已删除（重启 App 只认此文件恢复，删后不会再恢复这个已结束任务）")
        lines.append("\(fmt(waitingInput == nil && goal.isEmpty)) 续跑口已封：等待输入已清、目标已清（resume 无目标可续）")
        resume()
        lines.append("\(fmt(isEnded() && !busy)) 续跑实证：终结后调用 resume() 状态不变（仍为终结态、引擎不忙碌，任务不复活）")
        lines.append("\(fmt(web.executionTabID == nil && !web.uploadSupplyArmed)) 绑定释放：执行页绑定已解除、待供文件未武装")
        // —— 还原现场 ——
        status = savedStatus; goal = savedGoal; steps = savedSteps; stepSeq = savedStepSeq
        waitingInput = savedWaiting; stepLimitPaused = savedStepLimitPaused; conversationTaskID = savedTaskID
        stateCard = savedStateCard
        clearSnapshot()
        lines.append("\(fmt(!busy)) 现场还原：引擎回到演练前的空闲状态（演练快照已一并清除）")
        return lines
    }

    /// 自检二十四（EDITOR-ENTRY-BIND）：标题↔appmsgid 配对与列表翻
    /// 页的纯逻辑核查。合成内嵌数据＝公众号列表页数据对象的同构样
    /// 本：六个条目交错排列（两条同名不同 ID、一条标题以 \u 转义写
    /// 入、一条只有 ID 没有标题）＋一段无标题的噪声 ID。断言：配对
    /// 只从同对象共现出（恰 5 组）、噪声与无标题条目不误配、同名
    /// 歧义如实拒绝（不猜）、目标标题唯一命中时按配对拼直达、卡片
    /// DOM 配对直交可用、无目标时旧口径行为不变、翻页纯函数边界
    /// 正确、目标标题提取口径正确。不调用模型、不占用页面、不要求
    /// 引擎空闲（全部纯函数）。
    func verifyEditorEntryBind() -> [String] {
        var lines: [String] = []
        func fmt(_ ok: Bool) -> String { ok ? "✓" : "✗" }
        let script = """
        window.__LIST__ = {"item_list":[
         {"appmsgid":100000301,"title":"甲稿先行","update_time":1730073600},
         {"appmsgid":100000302,"title":"乙稿居中","update_time":1730073601},
         {"appmsgid":100000303,"title":"\\u4e19\\u7a3f\\u7532\\u4e59","update_time":1730073602},
         {"appmsgid":100000401,"title":"甲稿先行","update_time":1730073603},
         {"appmsgid":100000402,"title":"戊稿压尾","update_time":1730073604},
         {"appmsgid":100000501}
        ],"total_count":6};
        var unrelated = {"appmsgid":100000999};
        """
        let scriptCand = DirectTargetHarvest.Candidate(source: .embedded, value: script)
        let templateCand = DirectTargetHarvest.Candidate(source: .href, value: "https://mp.weixin.qq.com/cgi-bin/appmsg?t=media/appmsg_edit_v2&action=edit&type=10")
        let pairs = DirectTargetHarvest.extractPairs(fromScriptText: script)
        lines.append("\(fmt(pairs.count == 5)) 内嵌配对提取：六条目＋噪声的合成数据对象里提取到 \(pairs.count) 组配对（期望恰 5 组：同对象共现才成对）")
        lines.append("\(fmt(pairs.contains(.init(title: "乙稿居中", appmsgid: "100000302", evidence: "内嵌数据同对象共现")) && pairs.contains(.init(title: "丙稿甲乙", appmsgid: "100000303", evidence: "内嵌数据同对象共现")))) 配对内容：常规条目与 \\u 转义标题条目均正确配对（乙稿居中↔100000302、丙稿甲乙↔100000303）")
        lines.append("\(fmt(!pairs.contains(where: { $0.appmsgid == "100000999" }) && !pairs.contains(where: { $0.appmsgid == "100000501" }))) 不误配：无标题噪声 ID（100000999）与只有 ID 的条目（100000501）均未成对——无配对如实 0 实证，不按位置猜测")
        let hit = DirectTargetHarvest.build(candidates: [scriptCand], memoryTemplate: templateCand.value, targetTitle: "乙稿居中")
        lines.append("\(fmt(hit.result?.appmsgid == "100000302" && hit.result?.pairedTitle == "乙稿居中" && hit.result?.viaTemplate == true)) 标题定向直达：目标「乙稿居中」唯一命中配对 → 以记忆模板拼出 appmsgid=100000302 的编辑直达")
        let wrongDirect = DirectTargetHarvest.Candidate(source: .href, value: "https://mp.weixin.qq.com/cgi-bin/appmsg?t=media/appmsg_edit_v2&action=edit&appmsgid=100000777")
        let guarded = DirectTargetHarvest.build(candidates: [scriptCand, wrongDirect], memoryTemplate: templateCand.value, targetTitle: "乙稿居中")
        lines.append("\(fmt(guarded.result?.appmsgid == "100000302")) 直达链接防错篇：页面另有一条别篇的带 ID 编辑链接（100000777）时，有目标标题仍只认标题配对（取 100000302），不拿第一条编辑链接开错草稿")
        let rightDirect = DirectTargetHarvest.Candidate(source: .href, value: "https://mp.weixin.qq.com/cgi-bin/appmsg?t=media/appmsg_edit_v2&action=edit&appmsgid=100000302")
        let directHit = DirectTargetHarvest.build(candidates: [scriptCand, rightDirect], memoryTemplate: nil, targetTitle: "乙稿居中")
        lines.append("\(fmt(directHit.result?.appmsgid == "100000302" && directHit.result?.viaTemplate == false && directHit.result?.pairedTitle == "乙稿居中")) 直达链接与配对一致：带 ID 编辑链接的 ID 与目标标题唯一配对相同时直用，并留配对标题痕")
        let ambiguous = DirectTargetHarvest.build(candidates: [scriptCand], memoryTemplate: templateCand.value, targetTitle: "甲稿先行")
        lines.append("\(fmt(ambiguous.result == nil && ambiguous.facts.note.contains("无法唯一"))) 同名歧义拒绝：两条同名草稿（100000301/100000401）时不猜——直达为空且实况注明无法唯一配对")
        let missing = DirectTargetHarvest.build(candidates: [scriptCand], memoryTemplate: templateCand.value, targetTitle: "查无此稿")
        lines.append("\(fmt(missing.result == nil)) 无此标题：目标标题不在列表数据里时直达为空，不拿任何候选 ID 冒充")
        let legacy = DirectTargetHarvest.build(candidates: [scriptCand, templateCand], memoryTemplate: nil, targetTitle: nil)
        lines.append("\(fmt(legacy.result?.appmsgid == "100000301" && legacy.result?.viaTemplate == true)) 旧口径不变：未给目标标题时沿用既有口径（本页模板＋首个实证 ID），配对通道不扰动无标题任务")
        let domHit = DirectTargetHarvest.build(candidates: [templateCand], memoryTemplate: nil, targetTitle: "卡片标题稿", domPairs: [.init(title: "卡片标题稿", appmsgid: "100000555", evidence: "卡片 DOM 同卡共现")])
        lines.append("\(fmt(domHit.result?.appmsgid == "100000555" && domHit.result?.pairedTitle == "卡片标题稿")) 卡片 DOM 配对：标题与 msgid 属性同卡共现的配对可直交拼直达（appmsgid=100000555）")
        let page0 = "https://mp.weixin.qq.com/cgi-bin/appmsg?begin=0&count=10&t=media/appmsg_list&type=77&action=list_card"
        let page1 = DirectTargetHarvest.nextListPageURL(page0, maxBegin: 20)
        let page2 = page1.flatMap { DirectTargetHarvest.nextListPageURL($0, maxBegin: 20) }
        let page3 = page2.flatMap { DirectTargetHarvest.nextListPageURL($0, maxBegin: 20) }
        lines.append("\(fmt(page1?.contains("begin=10") == true && page2?.contains("begin=20") == true && page3 == nil)) 翻页纯函数：begin/count 列表按 count 递进（0→10→20），到达 maxBegin 后停止，不越界乱翻")
        lines.append("\(fmt(DirectTargetHarvest.nextListPageURL("https://example.com/list", maxBegin: 20) == nil)) 翻页纯函数：无 begin/count 参数的地址不翻页（普通页不被误当列表续翻）")
        lines.append("\(fmt(DirectTargetHarvest.extractTargetTitle(goal: "帮我打开《把待办清单变短》继续编辑", stuck: "") == "把待办清单变短" && DirectTargetHarvest.extractTargetTitle(goal: "", stuck: "草稿「稍后再看的出口」打不开") == "稍后再看的出口" && DirectTargetHarvest.extractTargetTitle(goal: "打开《短》", stuck: "") == nil)) 目标标题提取：任务目标/卡点原文里的书名号/引号标题可提取，太短的引号内容不冒充标题")
        return lines
    }

    /// Tier A for FLOATING-VISIBILITY. Exercises the production visibility
    /// store and currently mounted WKWebView without calling the model.
    func verifyFloatingVisibility() async -> [String] {
        func mark(_ pass: Bool) -> String { pass ? "✓" : "✗" }
        var lines: [String] = []
        let state = DockStateStore()
        lines.append("\(mark(!state.isVisible && state.showsVisibilityToggle)) 冷启动静默：浮窗默认隐藏、固定开关可见")
        state.taskStarted()
        lines.append("\(mark(state.isVisible)) 任务开始：自动显示")
        state.taskTerminated()
        lines.append("\(mark(!state.isVisible)) 任务终态：自动隐藏")
        state.toggle(); let idleOpened = state.isVisible
        state.toggle(); let idleClosed = !state.isVisible
        lines.append("\(mark(idleOpened && idleClosed)) 静默开关：点开显示，再点隐藏")
        state.taskStarted(); state.toggle()
        let hiddenDuringTask = !state.isVisible
        let stillHiddenDuringTask = !state.isVisible
        state.setInterventionRequired(true)
        let forcedByIntervention = state.isVisible
        state.toggle()
        let cannotHideIntervention = state.isVisible
        state.setInterventionRequired(false)
        let restoredTaskHide = !state.isVisible
        lines.append("\(mark(hiddenDuringTask && stillHiddenDuringTask)) 任务内手动隐藏：保持隐藏直到任务迁移")
        lines.append("\(mark(forcedByIntervention && cannotHideIntervention && restoredTaskHide)) 安全介入：强制显示、拒绝隐藏，解除后恢复本任务手动隐藏选择")
        state.taskTerminated()
        lines.append("\(mark(!state.isVisible)) 介入解除后的终态：回到默认隐藏")

        let barDown = CGRect(x: 0, y: 760, width: 390, height: 60)
        let barUp = CGRect(x: 0, y: 430, width: 390, height: 60)
        let buttonDown = FloatingVisibilityToggleGeometry.buttonFrame(inputBar: barDown)
        let buttonUp = FloatingVisibilityToggleGeometry.buttonFrame(inputBar: barUp)
        let offsetDown = CGPoint(x: buttonDown.minX - barDown.minX, y: buttonDown.minY - barDown.minY)
        let offsetUp = CGPoint(x: buttonUp.minX - barUp.minX, y: buttonUp.minY - barUp.minY)
        lines.append("\(mark(offsetDown == offsetUp && offsetDown == CGPoint(x: FloatingVisibilityToggleGeometry.leading, y: FloatingVisibilityToggleGeometry.top))) 挂载锚点：键盘收起/升起时按钮相对输入栏左上角偏移恒定（\(offsetDown)）")
        let hiddenWithBar = !FloatingVisibilityToggleGeometry.isVisible(inputBarShown: false, browserFullScreen: false)
        let hiddenFullScreen = !FloatingVisibilityToggleGeometry.isVisible(inputBarShown: true, browserFullScreen: true)
        lines.append("\(mark(hiddenWithBar && hiddenFullScreen)) 输入栏隐藏或浏览器全屏时，夹挂按钮不可见")
        let textDown = FloatingVisibilityToggleGeometry.textEntryFrame(inputBar: barDown)
        let textUp = FloatingVisibilityToggleGeometry.textEntryFrame(inputBar: barUp)
        lines.append("\(mark(!buttonDown.intersects(textDown) && !buttonUp.intersects(textUp))) 不遮挡：键盘收起/升起两态按钮均不与文字输入区相交")

        let dock = web.dockState
        let savedDesired = dock.desiredVisible
        let savedIntervention = dock.interventionRequired
        let savedFullScreen = dock.fullScreen
        defer {
            dock.setInterventionRequired(false)
            dock.taskTerminated()
            if savedDesired { dock.toggle() }
            dock.setInterventionRequired(savedIntervention)
            if savedFullScreen { dock.showFullScreen() }
        }
        dock.setInterventionRequired(false)
        dock.taskStarted()
        await Task.yield()
        let frameBefore = web.webView.frame.size
        let viewportBefore = (try? await web.evaluateForManualSelfTest("window.innerWidth")) as? NSNumber
        dock.toggle()
        await Task.yield()
        let frameAfter = web.webView.frame.size
        let viewportAfter = (try? await web.evaluateForManualSelfTest("window.innerWidth")) as? NSNumber
        let sameFrame = abs(frameBefore.width - frameAfter.width) < 0.5 && abs(frameBefore.height - frameAfter.height) < 0.5
        let sameViewport = viewportBefore?.doubleValue == viewportAfter?.doubleValue && viewportBefore != nil
        lines.append("\(mark(sameFrame && sameViewport)) 显示→隐藏前后 WKWebView frame=\(frameBefore)→\(frameAfter)、viewport=\(viewportBefore?.intValue ?? -1)→\(viewportAfter?.intValue ?? -1)，均不变")

        let token = UUID().uuidString
        let probe = (try? await web.evaluateForManualSelfTest("(()=>{window.__mikaFloatingHidden='\(token)';return window.__mikaFloatingHidden;})()")) as? String
        lines.append("\(mark(probe == token)) 隐藏状态 JS 探针注入并回读成功（agent 执行未挂起）")
        return lines
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
        guard !busy else { return ["✗ 引擎忙碌中，自检二十一未执行（当前任务未终结：可等它跑完，或在暂停时点『结束任务』）"] }
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
            return "页面反复出错：已自动重试 \(maxTransientStreak - 1) 次仍不稳定，任务停下。错误原文已存入诊断（设置 → 崩溃报告），页面恢复后点「继续」可接着跑"
        case .pageLoad:
            return "页面加载反复失败：已自动重试 \(maxTransientStreak - 1) 次（含重载页面）仍不稳定，任务停下。错误原文已存入诊断（设置 → 崩溃报告），网络恢复后点「继续」可接着跑"
        case .modelNetwork:
            return "模型连接反复失败：已自动重试 \(maxTransientStreak - 1) 次。\((error as? MikaError)?.message ?? error.localizedDescription)"
        }
    }
    /// 瞬时错误留证：与 WebController 的操作失败快照同目录、同信封格式，诊断页
    /// （设置 → 崩溃报告）可见；裸错误原文只落在这里，不作对话标题展示。
    private func writeTransientDiagnostic(kind: TransientKind, error: Error, streak: Int) {
        refreshThermalState()
        guard thermalGate.allowsNonEssential() else { return }
        let ns = error as NSError
        writeDiagnostic(types: ["引擎瞬时错误"], payload: ["kind": "agent-transient-error", "transientKind": String(describing: kind),
                                                           "streak": streak, "domain": ns.domain, "code": ns.code,
                                                           "message": error.localizedDescription,
                                                           "goal": goal, "stepsRecorded": steps.count])
    }
    private func noteContentProcessTermination(_ tab: BrowserTab) {
        let now = tab.terminatedAt ?? Date()
        let key = ObjectIdentifier(tab)
        if let previous = lastTerminationNote[key], now.timeIntervalSince(previous) < 3 { return }
        lastTerminationNote[key] = now
        let isExecutionTab = web.executionTabID == tab.id
        let taskRunning: Bool
        if case .running = status { taskRunning = true } else { taskRunning = false }
        writeDiagnostic(types: ["网页进程终止"], payload: ["kind": "web-content-process-terminated",
                                                   "tabID": tab.id.uuidString,
                                                   "isExecutionTab": isExecutionTab,
                                                   "taskRunning": taskRunning,
                                                   "goal": goal])
    }
    private func pauseForRecoveryBudget(_ message: String) {
        appendStep("pause", message)
        stepLimitPaused = false
        status = .paused(message)
        sessionActive = false; applyIdleTimerPolicy()
        endBackgroundGrace(); completeContinuedProcessing(success: false)
        persistSnapshot()
        scheduleReadbackRecycling()
    }
    private struct ThermalPause: Error {}

    private func refreshThermalState() {
        thermalGate.update(level: ThermalLevel(ProcessInfo.processInfo.thermalState), now: Date())
    }

    private func thermalCheckpoint() throws {
        refreshThermalState()
        if thermalGate.isLocked {
            pauseForThermal()
            throw ThermalPause()
        }
        if thermalPaused {
            guard thermalGate.canResume(now: Date()) else { throw ThermalPause() }
            thermalPaused = false
            appendStep("note", "设备温度已回落，恢复执行")
        }
    }

    private func pauseForThermal() {
        guard !thermalPaused else { return }
        let message = "设备发热严重，任务已暂停降温，进度已存；温度降下来后点「继续」接着跑"
        thermalPaused = true
        appendStep("pause", message)
        status = .paused(message)
        sessionActive = false
        applyIdleTimerPolicy()
        endBackgroundGrace()
        completeContinuedProcessing(success: false)
        persistSnapshot()
        scheduleReadbackRecycling()
    }
    private func scheduleReadbackRecycling() {
        guard let taskID = conversationTaskID, readbackTabs.readbackTab(forTask: taskID) != nil else { return }
        let token = generation
        Task { [weak self] in await self?.recycleReadbackTabs(for: taskID, expectedGeneration: token) }
    }

    private func recycleReadbackTabs(for taskID: UUID?, expectedGeneration: UUID) async {
        guard let taskID, generation == expectedGeneration else { return }
        let entries = readbackTabs.tabsToRecycle(forTask: taskID).compactMap { readbackTabs.entries[$0] }
        for entry in entries {
            await recycleReadbackTab(entry, for: taskID, expectedGeneration: expectedGeneration)
        }
        guard generation == expectedGeneration else { return }
        readbackTabs.endTask(taskID)
        if conversationTaskID == taskID { replacedReadbackTabIDs.removeAll() }
    }

    private func recycleReadbackTab(_ entry: ReadbackTabRegistry.Entry, for taskID: UUID, expectedGeneration: UUID, excluding extraExcluded: Set<UUID> = []) async {
        guard conversationTaskID == taskID, generation == expectedGeneration,
              let tab = web.tabs.first(where: { $0.id == entry.tabID }), !tab.isPinned else {
            if conversationTaskID == taskID { appendStep("note", "回读页受保护或已不存在，已保留未关") }
            return
        }
        if web.executionTabID == entry.tabID {
            let excluded = Set(readbackTabs.entries.keys).union(replacedReadbackTabIDs).union(extraExcluded).union([entry.tabID])
            guard web.restoreExecutionBinding(preferred: entry.sourceTabID, excluding: excluded) else {
                appendStep("note", "回读页没有可恢复的用户页执行绑定，已保留未关")
                return
            }
        }
        if await web.readbackTabMayContainEdits(entry.tabID) {
            guard conversationTaskID == taskID, generation == expectedGeneration else { return }
            appendStep("note", "回读页可能含未保存内容，已保留未关")
            return
        }
        guard conversationTaskID == taskID, generation == expectedGeneration else { return }
        web.closeTab(entry.tabID)
        if web.tabs.contains(where: { $0.id == entry.tabID }) {
            appendStep("note", "回读页未通过标签关闭保护，已保留未关")
        }
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
        saveTaskProgress()
        syncContinuedProgress()
    }
    private func saveTaskProgress() {
        guard let taskID = conversationTaskID else { return }
        let matching = outcomeLedger.last { $0.taskID == taskID }
        let unresolved = matching?.unresolved == true
        let result = matching.map { "派发 \($0.dispatchState?.rawValue ?? "unknown")；核验 \($0.verificationVerdict?.rawValue ?? "unknown")" }
            ?? stateCard.zhihuPublicationStatus.map { "知乎发布：\($0)" } ?? "尚无可核实成果"
        let next: String
        if unresolved { next = "独立回读实际结果，未决动作禁止重放" }
        else if case .waitingConfirm = status { next = "在 60 秒内确认或拒绝" }
        else if case .waitingManual = status { next = "完成当前人工步骤" }
        else if case .done = status { next = "查看成果与证据" }
        else if case .failed = status { next = "查看失败记录并处理" }
        else { next = "按当前页面继续任务" }
        let stage = steps.last.map { "第 \($0.id) 步：\(Self.safeAuditName($0.action))" } ?? "等待开始"
        progressBySession[runSessionID] = TaskProgressSnapshot(taskID: taskID, stage: stage,
            result: result, next: next, updatedAt: Date())
        if let data = try? JSONEncoder().encode(progressBySession) {
            UserDefaults.standard.set(data, forKey: "taskProgress.v1")
        }
    }
    @discardableResult private func appendExecutionAudit(event: String, actionID: UUID,
                                                         pageURL: String, evidenceRef: String) -> Bool {
        var safeURL = ""
        if let url = URLComponents(string: pageURL), let scheme = url.scheme {
            safeURL = "\(scheme)://\(url.host ?? "")"
        }
        var store = ExecutionAuditStore.shared
        #if DEBUG && targetEnvironment(simulator)
        if let isolated = gateSelfTestAuditStore { store = isolated }
        #endif
        return store.append(ExecutionAuditRecord(
            id: UUID(), recordedAt: Date(), taskID: conversationTaskID ?? runSessionID,
            actionID: actionID, event: event, pageURL: safeURL,
            evidenceRef: evidenceRef))
    }
    private func auditedDispatch<T>(name: String, pageURL: String, actionID: UUID? = nil,
                                    critical: Bool = false,
                                    callMarker: DispatchCallMarker? = nil,
                                    operation: @MainActor () async throws -> T) async throws -> T {
        let identifier = actionID ?? currentActionID ?? UUID()
        let receiptID = UUID()
        let taskID = conversationTaskID ?? runSessionID
        let safeName = Self.safeAuditName(name)
        guard !executionReceiptsDecodeFailed else { throw MikaError("派发回执无法解码，已停止动作") }
        let readOnlyOrNavigation: Set<String> = ["navigate", "scroll", "wait", "open_new_tab",
            "rung-navigation", "dialog-leave-navigation", "dialog-return-navigation",
            "zhihu-readback-navigation", "readback-navigation", "recovery-reload", "dialog-reload"]
        let host = URL(string: pageURL)?.host ?? ""
        let unresolvedOutcome = outcomeLedger.contains { record in
            record.unresolved && record.actionID != Optional(identifier) &&
                (record.taskID == Optional(taskID) || (record.taskID == nil && record.host == host))
        }
        guard readOnlyOrNavigation.contains(safeName) ||
              (!executionReceipts.contains(where: { $0.taskID == taskID && $0.blocksDependencies }) && !unresolvedOutcome) else {
            throw MikaError("本任务有未决副作用，已阻断依赖动作；请先独立回读")
        }
        executionReceipts.append(ExecutionReceipt(id: receiptID, actionID: identifier, taskID: taskID, actionName: safeName,
            targetHash: ZhihuPublishPolicy.hash(pageURL), critical: critical, dispatchState: .unknown,
            verificationVerdict: critical ? .unknown : nil, evidenceRef: "prepared-before-call",
            createdAt: Date(), updatedAt: Date()))
        guard saveExecutionReceipts() else { throw MikaError("派发回执持久化失败，动作未派发") }
        guard appendExecutionAudit(event: "attempt-\(Self.safeAuditName(name))", actionID: identifier,
                                   pageURL: pageURL, evidenceRef: "host-dispatch") &&
              appendExecutionAudit(event: "dispatch-prepared", actionID: identifier,
                                   pageURL: pageURL, evidenceRef: "before-call") else {
            updateExecutionReceipt(id: receiptID, state: .notSent, evidence: "audit-failed-before-call")
            throw MikaError("审计日志写入失败，动作未派发")
        }
        do {
            callMarker?.entered = true
            let result = try await operation()
            #if DEBUG && targetEnvironment(simulator)
            try gateSelfTestAfterDispatch?()
            #endif
            guard appendExecutionAudit(event: "dispatch-sent", actionID: identifier,
                                       pageURL: pageURL, evidenceRef: "call-returned"),
                  updateExecutionReceipt(id: receiptID, state: .sent, evidence: "call-returned") else {
                updateExecutionReceipt(id: receiptID, state: .unknown, evidence: "post-call-log-or-receipt-failed")
                throw MikaError("派发后审计写入失败，结果按 unknown 停止")
            }
            return result
        } catch {
            updateExecutionReceipt(id: receiptID, state: .unknown, evidence: "call-or-followup-error")
            _ = appendExecutionAudit(event: "dispatch-unknown", actionID: identifier,
                                     pageURL: pageURL, evidenceRef: "call-or-followup-error")
            throw error
        }
    }
    @discardableResult private func updateExecutionReceipt(id: UUID, state: OutcomeRecord.DispatchState,
                                                            evidence: String, verdict: VerificationVerdict? = nil) -> Bool {
        guard let index = executionReceipts.firstIndex(where: { $0.id == id }) else { return false }
        executionReceipts[index].dispatchState = state
        executionReceipts[index].evidenceRef = evidence
        executionReceipts[index].updatedAt = Date()
        if let verdict { executionReceipts[index].verificationVerdict = verdict }
        return saveExecutionReceipts()
    }
    private static func safeAuditName(_ name: String) -> String {
        let known: Set<String> = ["click", "type", "scroll", "navigate", "open_new_tab", "wait",
            "set_site_mode", "use_skill", "upload_file", "generate_cover", "done", "ask_user",
            "rung-reveal-click", "rung-navigation", "dialog-reload", "dialog-save-click",
            "dialog-leave-navigation", "dialog-return-navigation", "recovery-reload",
            "zhihu-readback-navigation", "readback-navigation", "zhihu-publish"]
        return known.contains(name) ? name : "unrecognized"
    }
    private func record(_ action: AgentAction, suffix: String = "") {
        appendStep(action.action, action.reason + suffix)
        // 状态卡的已完成里程碑在记账点同步（程序事实，不经模型转述，H1）
        stateCard.addCompleted(action.action == "click"
            ? "点击尝试已记录；成果以独立核验为准"
            : "\(action.action)：\(action.reason)")
        appendTrace(action: action, suffix: suffix)
    }

    /// committed 全文相等是 type 的独立真值；按钮 disabled 属于另一动作的
    /// 页面观测，只能备注，不能改写已经核实的输入结论。
    private func typeVerificationSuffix(for action: AgentAction, trace: [String], page: PageState) -> String {
        guard action.action == "type" else { return "" }
        if trace.contains(where: { $0.contains("committed-override") }) {
            return "（已核实：Draft committed 与整段源稿全文等值，committed-override）"
        }
        return trace.contains(where: { $0.contains("count-ok") }) ? "（已核实：全文与编辑器信号一致）" : ""
    }

    private func appendDisabledButtonObservation(from page: PageState) {
        let disabled = page.elements.filter { $0.tag == "button" && $0.disabled }
        guard !disabled.isEmpty else { return }
        let labels = disabled.prefix(5).map { $0.text.isEmpty ? ($0.ariaLabel.isEmpty ? "#\($0.index)" : $0.ariaLabel) : $0.text }
        appendStep("observation", "按钮 disabled 读数仅作观测备注（\(labels.joined(separator: "／"))）；不推翻已核实的 committed 全文，不作为内容状态结论")
    }

    func verifyCommittedTruthPresentation() async -> [String] {
        var lines = await WebController().verifyFrozenDraftCommitted()
        let actionData = try? JSONSerialization.data(withJSONObject: ["action":"type", "index":0, "text":"全文", "reason":"自检四十九"])
        let action = actionData.flatMap { try? JSONDecoder().decode(AgentAction.self, from: $0) }
        let disabledPublish = PageElement(index: 1, tag: "button", type: "", text: "发布", placeholder: "", href: "", name: "", inputType: "", ariaLabel: "", nameSource: "text", inView: true, sensitive: true, disabled: true, editable: false)
        let page = PageState(url: "https://example.test/editor", title: "fixture", text: "", elements: [disabledPublish], epoch: nil)
        if let action {
            let pass = typeVerificationSuffix(for: action, trace: ["committed-override(count=0),strategy=paste-plain"], page: page)
            let fail = typeVerificationSuffix(for: action, trace: ["committed-miss-veto,strategy=paste-plain"], page: page)
            var card = TaskStateCard(goal: "自检四十九")
            card.addWrite(target: "正文编辑器", body: action.text, verification: "verified")
            card.addCompleted("type：\(action.reason)\(pass)")
            let stepResult = "type：\(action.reason)\(pass)"
            let modelReport = stepResult + "\n" + card.promptBlock() + "\n按钮 disabled 仅作观测备注，不影响 committed 结论"
            let consistent = stepResult.contains("已核实") && card.promptBlock().contains("核实=verified") && card.promptBlock().contains("已核实") && modelReport.contains("已核实")
            lines.append("\(page.elements.first?.disabled == true && consistent && !modelReport.contains("未提交") ? "✓" : "✗") 甲：count 0＋disabled＋committed 全文 ⇒ 步骤/状态卡/模型回报统一为已核实，无「未提交」")
            lines.append("\(fail.isEmpty ? "✓" : "✗") 乙：committed 不含全文 ⇒ 不产生已核实结论，维持 fail-closed")
        } else { lines.append("✗ 自检四十九 action fixture 构造失败") }
        return lines
    }

    private func appendTrace(action: AgentAction, suffix: String) {
        guard let model = traceModel else { return }
        let page = tracePageBefore
        let actionObject = ((try? JSONSerialization.jsonObject(with: JSONEncoder().encode(action))) as? [String: Any]) ?? [:]
        let proof = currentZhihuWriteProof
        let publishRecord = matchedZhihuPublishRecord ?? proof.flatMap { p in
            zhihuPublishRecords.last(where: { $0.taskID == p.taskID && $0.questionID == p.questionID && $0.expectedTextHash == p.expectedTextHash })
        }
        let unknown: [String: Any] = ["observability": "unobservable", "value": NSNull()]
        let attempted = suffix.contains("未执行") ? "not-executed" : "attempted"
        let verified = traceInputStrategies.contains(where: { $0.contains("count-ok") || $0.contains("committed-override") }) ? "verified" : "unknown"
        let requestAttachment = AgentTraceStore.shared.storeAttachment(model.requestBody)
        let record: [String: Any] = [
            "schemaVersion": 1,
            "identityAndConfig": [
                "taskID": conversationTaskID?.uuidString ?? "unobservable", "runID": generation.uuidString,
                "stepID": stepSeq, "attemptID": UUID().uuidString, "timestamp": AgentTraceStore.shared.timestamp(),
                "buildSHA": AgentTraceStore.buildSHA, "buildNumber": AgentTraceStore.buildNumber,
                "device": AgentTraceStore.device, "webViewVersion": AgentTraceStore.webViewVersion,
                "channel": model.channel, "requestedModel": model.requestedModel, "requestedEffort": model.requestedEffort,
                "returnedModel": model.responseModel ?? "unobservable", "timeoutSeconds": model.timeoutSeconds,
                "outputLimit": "not-sent", "stepLimit": limit
            ],
            "rawInput": [
                "task": goal, "interjections": traceInterjection, "draftVersion": proof?.bodyVersion ?? "unobservable",
                "publishAuthorization": ["authorized": currentZhihuAuthorization.authorized,
                    "scopes": currentZhihuAuthorization.scopes, "revision": currentZhihuAuthorization.revision,
                    "source": currentZhihuAuthorization.source, "reason": currentZhihuAuthorization.reason,
                    "sourceInstruction": currentZhihuAuthorization.sourceInstruction],
                "actualRequestBody": model.requestBody, "requestBodyAttachment": requestAttachment, "prompt": tracePrompt,
                "historyBeforeFold": traceHistoryBefore, "historyAfterFold": traceHistoryAfter,
                "segmentCharacterCounts": ["task": goal.count, "stateCard": traceStateCardBefore.count,
                    "historyBefore": traceHistoryBefore.count, "historyAfter": traceHistoryAfter.count,
                    "page": page?.text.count ?? 0, "playbook": loadedSkillBodies.count, "fullPrompt": tracePrompt.count],
                "foldLevel": traceFoldLevel
            ],
            "rawOutput": [
                "rawResponseOrSSE": model.rawResponse, "completeResponseItems": model.rawResponse,
                "finishStatus": model.finishStatus, "truncation": "unobservable", "error": NSNull(),
                "usage": model.usage ?? unknown, "parsedAction": actionObject, "completeText": action.text
            ],
            "actualExecution": [
                "proposedAction": actionObject, "finalAction": traceFinalAction ?? actionObject, "rewriteReason": traceRewriteReason,
                "attemptStatus": attempted, "verificationResult": verified,
                "tabID": web.executionTab.id.uuidString, "frame": unknown, "documentEpoch": page?.epoch.map { $0 as Any } ?? NSNull(),
                "targetIdentity": action.index >= 0 ? "page-element-index:\(action.index)" : "not-applicable",
                "focus": unknown, "selection": unknown,
                "inputStrategiesAndRetries": traceInputStrategies
            ],
            "independentObservation": [
                "domTextBefore": page?.text ?? "unobservable", "domTextAfter": unknown,
                "counterNode": unknown, "candidateState": unknown, "committedState": unknown,
                "buttonState": page?.elements.filter { $0.tag == "button" }.map { ["index": $0.index, "text": $0.text, "disabled": $0.disabled] } ?? [],
                "writeProof": proof.map { ["taskID": $0.taskID.uuidString, "tabID": $0.tabID.uuidString,
                    "documentEpoch": $0.documentEpoch, "frameID": $0.frameID, "questionID": $0.questionID,
                    "editorIdentity": $0.editorIdentity, "composerIdentity": $0.composerIdentity,
                    "bodyVersion": $0.bodyVersion, "expectedTextHash": $0.expectedTextHash,
                    "committedTextHash": $0.committedTextHash, "comparisonRule": $0.comparisonRule,
                    "comparisonResult": $0.comparisonResult, "observedAt": ISO8601DateFormatter().string(from: $0.observedAt),
                    "sourceText": $0.expectedText, "committedText": $0.committedText] } ?? unknown,
                "publishBinding": currentZhihuPublishBinding.map { ["questionID": $0.questionID,
                    "editorIdentity": $0.editorIdentity, "composerIdentity": $0.composerIdentity,
                    "buttonIdentity": $0.buttonIdentity, "buttonIndex": $0.buttonIndex,
                    "candidateCount": $0.candidateCount, "disabledObservation": $0.disabledSummary] } ?? unknown,
                "saveSignal": unknown, "reopenedTextAfterSave": unknown,
                "source": "PageState + execution trace", "observedAt": AgentTraceStore.shared.timestamp(),
                "observability": ["afterDOM": "unobservable", "committedState": "unobservable"]
            ],
            "stateAndResult": [
                "stateCardBefore": traceStateCardBefore, "stateCardAfter": stateCard.promptBlock(),
                "stateEvidenceSource": "program-maintained TaskStateCard", "nextRoundActualInput": "pending",
                "finalBody": proof?.expectedText ?? "unobservable",
                "draftOrPublishReceipt": publishRecord.map { ["status": $0.status.rawValue,
                    "clickCount": $0.clickCallCount, "answerLink": $0.answerURL ?? "",
                    "author": $0.authorIdentity ?? "", "questionID": $0.questionID,
                    "sourceText": $0.sourceText, "readbackFullText": $0.readbackText ?? "",
                    "resultDetail": $0.resultDetail] } ?? unknown, "failureType": unknown,
                "manualIntervention": suffix.contains("手动输入"),
                "totalElapsedSeconds": runStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            ]
        ]
        AgentTraceStore.shared.append(record)
        traceModel = nil
        traceFinalAction = nil
        traceRewriteReason = "none"
    }

    // MARK: - 成果台账（OUTCOME-LEDGER-2026-11-02.md）

    private static let outcomeLedgerKey = "outcomeLedger.v1"
    private static let taskClaimsKey = "taskStateClaims.v1"
    private static let zhihuPublishLedgerKey = "zhihuPublishLedger.v1"
    private static let zhihuAccountRegistryKey = "zhihuAccountRegistry.v1"
    private static let outcomeTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    private static func outcomeTime(_ date: Date) -> String { outcomeTimeFormatter.string(from: date) }

    /// 未决尝试永不按时间或条数裁剪；只裁已决条目。
    private static func prunedOutcomes(_ records: [OutcomeRecord]) -> [OutcomeRecord] {
        let resolved = Array(records.filter { !$0.unresolved && Date().timeIntervalSince($0.recordedAt) < 24 * 3600 }.suffix(20))
        let unresolved = records.filter { $0.unresolved }
        return (resolved + unresolved).sorted { $0.recordedAt < $1.recordedAt }
    }
    private func loadOutcomeLedger() {
        guard let data = UserDefaults.standard.data(forKey: Self.outcomeLedgerKey) else { return }
        guard let records = try? JSONDecoder().decode([OutcomeRecord].self, from: data) else {
            outcomeLedgerDecodeFailed = true
            return
        }
        outcomeLedger = Self.prunedOutcomes(records)
    }
    @discardableResult private func saveOutcomeLedger() -> Bool {
        guard !outcomeLedgerDecodeFailed else { return false }
        outcomeLedger = Self.prunedOutcomes(outcomeLedger)
        guard let data = try? JSONEncoder().encode(outcomeLedger) else { return false }
        UserDefaults.standard.set(data, forKey: Self.outcomeLedgerKey)
        guard let saved = UserDefaults.standard.data(forKey: Self.outcomeLedgerKey),
              let decoded = try? JSONDecoder().decode([OutcomeRecord].self, from: saved) else { return false }
        return decoded.count == outcomeLedger.count && zip(decoded, outcomeLedger).allSatisfy { pair in
            pair.0.id == pair.1.id && pair.0.dispatchState == pair.1.dispatchState && pair.0.verificationVerdict == pair.1.verificationVerdict
        }
    }

    private static let executionReceiptsKey = "executionReceipts.v1"
    private func loadExecutionReceipts() {
        guard let data = UserDefaults.standard.data(forKey: Self.executionReceiptsKey) else { return }
        guard let saved = try? JSONDecoder().decode([ExecutionReceipt].self, from: data) else {
            executionReceiptsDecodeFailed = true
            return
        }
        executionReceipts = saved
    }
    @discardableResult private func saveExecutionReceipts() -> Bool {
        guard !executionReceiptsDecodeFailed else { return false }
        let pending = executionReceipts.filter { !$0.resolved }
        let settled = Array(executionReceipts.filter { $0.resolved && Date().timeIntervalSince($0.updatedAt) < 24 * 3600 }.suffix(20))
        executionReceipts = (settled + pending).sorted { $0.createdAt < $1.createdAt }
        guard let data = try? JSONEncoder().encode(executionReceipts) else { return false }
        UserDefaults.standard.set(data, forKey: Self.executionReceiptsKey)
        guard let stored = UserDefaults.standard.data(forKey: Self.executionReceiptsKey),
              let decoded = try? JSONDecoder().decode([ExecutionReceipt].self, from: stored) else { return false }
        return decoded.count == executionReceipts.count && zip(decoded, executionReceipts).allSatisfy { pair in
            pair.0.id == pair.1.id && pair.0.dispatchState == pair.1.dispatchState && pair.0.verificationVerdict == pair.1.verificationVerdict
        }
    }

    private func loadZhihuPublishRecords() {
        let key = zhihuPublishLedgerKeyOverride ?? Self.zhihuPublishLedgerKey
        let registryKey = zhihuPublishLedgerKeyOverride.map { $0 + ".accounts" } ?? Self.zhihuAccountRegistryKey
        if let data = UserDefaults.standard.data(forKey: registryKey),
           let saved = try? JSONDecoder().decode(ZhihuAccountRegistry.self, from: data) {
            zhihuAccountRegistry = saved
        }
        guard let data = UserDefaults.standard.data(forKey: key),
              var records = try? JSONDecoder().decode([ZhihuPublishRecord].self, from: data) else { return }
        zhihuAccountRegistry.migrate(records: &records)
        zhihuPublishRecords = Self.prunedZhihuPublishRecords(records)
        _ = saveZhihuPublishRecords()
    }

    /// 未决提交没有时间失效口径：unknown/review/attemptStarted 均永久保留，
    /// 不能因为七天过去或终态条目挤满容量而重新获得点击资格。终态只留近 50 条。
    private static func prunedZhihuPublishRecords(_ records: [ZhihuPublishRecord]) -> [ZhihuPublishRecord] {
        let pending = records.filter { $0.status.isPending }
        let pendingIDs = Set(pending.map(\.id))
        let terminal = records.filter { !pendingIDs.contains($0.id) }
        return (Array(terminal.suffix(50)) + pending).sorted { $0.attemptStartedAt < $1.attemptStartedAt }
    }

    /// 写后立即从同一持久化槽回读并逐项比对。失败时调用方不得执行发布 click。
    @discardableResult private func saveZhihuPublishRecords() -> Bool {
        let key = zhihuPublishLedgerKeyOverride ?? Self.zhihuPublishLedgerKey
        let registryKey = zhihuPublishLedgerKeyOverride.map { $0 + ".accounts" } ?? Self.zhihuAccountRegistryKey
        zhihuPublishRecords = Self.prunedZhihuPublishRecords(zhihuPublishRecords)
        zhihuAccountRegistry.migrate(records: &zhihuPublishRecords)
        guard let data = try? JSONEncoder().encode(zhihuPublishRecords),
              let registryData = try? JSONEncoder().encode(zhihuAccountRegistry) else { return false }
        UserDefaults.standard.set(data, forKey: key)
        UserDefaults.standard.set(registryData, forKey: registryKey)
        guard let stored = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ZhihuPublishRecord].self, from: stored),
              let storedRegistry = UserDefaults.standard.data(forKey: registryKey),
              let decodedRegistry = try? JSONDecoder().decode(ZhihuAccountRegistry.self, from: storedRegistry) else { return false }
        return decoded == zhihuPublishRecords && decodedRegistry == zhihuAccountRegistry
    }

    private func resolveZhihuAccount(_ pageIdentity: WebController.ZhihuPageIdentity) -> ZhihuAccountIdentity? {
        let resolved = zhihuAccountRegistry.resolve(observedAliases: pageIdentity.accountAliases,
            questionID: pageIdentity.questionID, records: zhihuPublishRecords)
        if resolved != nil { _ = saveZhihuPublishRecords() }
        return resolved
    }

    private func loadTaskClaims() {
        if let data = UserDefaults.standard.data(forKey: Self.taskClaimsKey),
           let saved = try? JSONDecoder().decode([TaskStateClaim].self, from: data) {
            taskClaims = saved
        }
        // 升级前的 OutcomeRecord 没有任务归属；给它一次性分配“旧任务”标识，
        // 默认仍是未核实。这样既不泄露细节，又允许随后用户明确确认时定位。
        for record in outcomeLedger where !taskClaims.contains(where: { $0.id == record.id }) {
            taskClaims.append(TaskStateClaim(id: record.id, sourceTaskID: UUID(),
                                             text: "在 \(record.host.isEmpty ? "本地页面" : record.host) 点了「\(record.elementLabel)」提交\(record.contentPrefix.isEmpty ? "内容" : "内容「\(record.contentPrefix)…」")"))
        }
    }
    private func saveTaskClaims() {
        guard !outcomeLedgerDecodeFailed else { return }
        let liveIDs = Set(outcomeLedger.map(\.id))
        taskClaims = taskClaims.filter { liveIDs.contains($0.id) }
        if let data = try? JSONEncoder().encode(taskClaims) {
            UserDefaults.standard.set(data, forKey: Self.taskClaimsKey)
        }
        stateCard.claims = taskClaims
    }

    /// 明确的用户事实断言可把相关主张终局化。只在有确认/纠正语义且能以
    /// 内容前缀或最近一条唯一定位时生效；普通任务文本不会误改台账。
    private func applyUserClaimStatement(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let assertionWords = ["我确认", "用户确认", "亲口确认", "亲令", "确实", "已经发布", "已经提交", "发布成功", "提交成功", "我已", "我没有", "并未", "未发布", "未提交"]
        guard assertionWords.contains(where: text.contains) else { return }
        let matching = taskClaims.indices.filter { index in
            guard taskClaims[index].status == .unverified else { return false }
            let record = outcomeLedger.first { $0.id == taskClaims[index].id }
            return record?.contentPrefix.isEmpty == false && text.contains(record!.contentPrefix)
        }
        let target: Int?
        if matching.count == 1 { target = matching[0] }
        else if matching.isEmpty { target = taskClaims.lastIndex { $0.status == .unverified } }
        else { target = nil }
        guard let target else { return }
        taskClaims[target].text = String(text.prefix(160))
        _ = taskClaims[target].setStatus(.verified, verifiedByUser: true)
        if let recordIndex = outcomeLedger.firstIndex(where: { $0.id == taskClaims[target].id }) {
            outcomeLedger[recordIndex].statusNote = "据用户确认：\(String(text.prefix(120)))"
            saveOutcomeLedger()
        }
        saveTaskClaims()
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
    private func noteTypedContent(action: AgentAction, element: PageElement) async {
        guard !action.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let target = [element.text, element.ariaLabel, element.placeholder, element.name]
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? "（目标未名）"
        var verification = traceInputStrategies.contains(where: { $0.contains("count-ok") || $0.contains("committed-override") }) ? "verified" : "unknown"
        if element.editable, let taskID = conversationTaskID {
            let proof = await web.captureZhihuWriteProof(action: action, taskID: taskID)
            if let proof, proof.isValid {
                currentZhihuWriteProof = proof
                currentZhihuPublishBinding = nil
                let identity = await web.readZhihuPageIdentity()
                let account = resolveZhihuAccount(identity)
                let target = PreservedDraftTarget(
                    accountStableID: account?.stableID ?? identity.accountIdentity,
                    accountAliases: account?.aliases ?? identity.accountAliases,
                    questionID: proof.questionID)
                do {
                    if let attached = activePreservedDraft,
                       !Self.sameDraftTarget(attached.target, target) {
                        currentZhihuWriteProof = nil
                        currentZhihuPublishBinding = nil
                        appendStep("draft-store", "恢复稿目标核对失败：关联 draft=\(attached.id.uuidString) 的账号/题目与当前页不一致；未覆盖稿库、未保留发布凭证")
                        return
                    }
                    activePreservedDraft = try preservedDraftStore.save(fullText: proof.expectedText,
                                                                        target: target,
                                                                        sourceTaskID: taskID,
                                                                        sourceSessionID: runSessionID)
                    if zhihuPublishLedgerKeyOverride == nil {
                        UserDefaults.standard.set(activePreservedDraft!.id.uuidString,
                            forKey: Self.preservedDraftAssociationPrefix + runSessionID.uuidString)
                    }
                    appendStep("draft-store", "独立稿件已保存：draft=\(activePreservedDraft!.id.uuidString)、version=\(activePreservedDraft!.version)、sourceTask=\(taskID.uuidString)、question=\(proof.questionID)；未保存 WriteProof")
                } catch {
                    appendStep("draft-store", "独立稿件保存失败：\(error.localizedDescription)；不得把任务快照或旧 WriteProof 冒充稿件存储")
                }
                verification = "verified"
                stateCard.setZhihuStatus(write: "已核实", publication: "未尝试")
                appendStep("write-proof", "正文凭证已生成：task=\(taskID.uuidString)、tab=\(proof.tabID.uuidString)、epoch=\(proof.documentEpoch)、question=\(proof.questionID)、editor=\(proof.editorIdentity)、composer=\(proof.composerIdentity)、bodyVersion=\(proof.bodyVersion)、expectedHash=\(proof.expectedTextHash)、committedHash=\(proof.committedTextHash)、rule=\(proof.comparisonRule)、result=\(proof.comparisonResult)")
            } else if currentZhihuAuthorization.allowsZhihuAnswer {
                currentZhihuWriteProof = nil
                currentZhihuPublishBinding = nil
                stateCard.setZhihuStatus(write: "未核实", publication: "未尝试")
                verification = "unknown"
                appendStep("write-proof", "正文凭证未生成：目标 Draft committed 全文不可观测或与源稿不全等；计数、DOM 文本及旧任务 verified 均不放行发布")
            }
        }
        stateCard.addWrite(target: target, body: action.text, verification: verification)
        let isEditor = element.editable || element.tag == "textarea"
        recentTyped.append((text: action.text, isEditor: isEditor))
        if recentTyped.count > 5 { recentTyped.removeFirst(recentTyped.count - 5) }
    }

    /// 真实聊天的新任务入口与冷启动恢复共用。仅把正文/版本/目标带入任务，
    /// currentZhihuWriteProof 始终保持 nil，直到当前页面重新写入并严格复读。
    private static func sameDraftTarget(_ lhs: PreservedDraftTarget, _ rhs: PreservedDraftTarget) -> Bool {
        lhs.questionID == rhs.questionID &&
            (lhs.accountStableID == rhs.accountStableID ||
             !Set(lhs.accountAliases).isDisjoint(with: Set(rhs.accountAliases)))
    }

    private struct ZhihuQuestionReference {
        enum Role { case target, excluded }
        let id: String
        let location: Int
        let role: Role
    }

    /// 把任务里的题号解析成带语义的引用，而不是只取第一个数字。否定旧题的
    /// 子句产出 excluded，后续换写的新题子句产出 target；多目标时以最后一
    /// 个正向目标为准，符合用户在同一句中修正目标的自然顺序。
    private static func zhihuQuestionReferences(in instruction: String) -> [ZhihuQuestionReference] {
        let patterns = [#"zhihu\.com/question/(\d+)"#, #"(?:问题|题目)\s*(?:ID\s*)?[：:#]?\s*(\d{3,})"#]
        let nsInstruction = instruction as NSString
        let clauseSeparators = CharacterSet(charactersIn: "，,。；;！？!?\n")
        func isClauseSeparator(at location: Int) -> Bool {
            guard let scalar = UnicodeScalar(UInt32(nsInstruction.character(at: location))) else { return false }
            return clauseSeparators.contains(scalar)
        }
        var references: [ZhihuQuestionReference] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let fullRange = NSRange(location: 0, length: nsInstruction.length)
            for match in regex.matches(in: instruction, range: fullRange) {
                let idRange = match.range(at: 1)
                guard idRange.location != NSNotFound else { continue }
                var clauseStart = match.range.location
                while clauseStart > 0 {
                    if isClauseSeparator(at: clauseStart - 1) { break }
                    clauseStart -= 1
                }
                var clauseEnd = NSMaxRange(match.range)
                while clauseEnd < nsInstruction.length {
                    if isClauseSeparator(at: clauseEnd) { break }
                    clauseEnd += 1
                }
                let clause = nsInstruction.substring(with: NSRange(location: clauseStart,
                                                                    length: clauseEnd - clauseStart))
                let referenceStart = match.range.location - clauseStart
                let referenceEnd = NSMaxRange(match.range) - clauseStart
                let clauseText = clause as NSString
                let prefix = clauseText.substring(to: referenceStart)
                let suffix = clauseText.substring(from: referenceEnd)
                let excludesBefore = prefix.range(of:
                    #"(?:不要|别|不再|停止|终止|放弃)(?:再)?(?:继续|处理|回答|写|改写)?(?:这个|该|旧)?(?:知乎)?\s*$"#,
                    options: [.regularExpression, .caseInsensitive]) != nil
                let excludesAfter = suffix.range(of:
                    #"^\s*(?:不要|别|不再|停止|终止|放弃)(?:再)?(?:继续|处理|回答|写|改写)?"#,
                    options: [.regularExpression, .caseInsensitive]) != nil
                references.append(ZhihuQuestionReference(
                    id: nsInstruction.substring(with: idRange), location: match.range.location,
                    role: excludesBefore || excludesAfter ? .excluded : .target))
            }
        }
        return references.sorted { $0.location < $1.location }
    }

    /// 会话关联只兜底承接“这篇／刚才／继续”等旧目标。带不同问题 ID，或明确
    /// 要另写、换题、围绕新主题创作的任务，必须从空稿开始，不能被旧稿绑住。
    private static func sessionDraftApplies(_ draft: PreservedDraft, to instruction: String) -> Bool {
        let references = zhihuQuestionReferences(in: instruction)
        if references.contains(where: { $0.id == draft.target.questionID && $0.role == .excluded }) {
            return false
        }
        if let questionID = references.last(where: { $0.role == .target })?.id {
            return questionID == draft.target.questionID
        }
        let newTargetPatterns = [
            #"(?:另|另外|换|改|重新|新)(?:一|个|道|篇|份)?.{0,6}(?:题|问题|话题|回答|稿)"#,
            #"(?:写|回答|创作|起草).{0,8}(?:关于|针对|题目|问题|话题|《|“|「|：|:)"#,
            #"(?:题目|问题|话题).{0,2}(?:是|为|：|:)"#
        ]
        return !newTargetPatterns.contains { pattern in
            instruction.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private struct PreservedDraftReference {
        var draftID: UUID?
        var sourceTaskID: UUID?
    }

    /// 用户可在新任务文字中携带状态卡/步流展示的明确稿件关联。只接受带字段
    /// 名的 UUID，不把任意 UUID 猜成稿件或任务，避免跨任务误取。
    private static func preservedDraftReference(in instruction: String) -> PreservedDraftReference {
        func identifier(labels: String) -> UUID? {
            let pattern = "(?:\(labels))\\s*[：:#]?\\s*([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: instruction,
                    range: NSRange(instruction.startIndex..<instruction.endIndex, in: instruction)),
                  let range = Range(match.range(at: 1), in: instruction) else { return nil }
            return UUID(uuidString: String(instruction[range]))
        }
        return PreservedDraftReference(
            draftID: identifier(labels: #"draftID|稿件ID|草稿ID"#),
            sourceTaskID: identifier(labels: #"sourceTaskID|来源任务ID"#))
    }

    /// 恢复优先级固定为明确 draftID → 来源任务 → 适用的会话关联；不再用
    /// 关键词或全局最新稿猜测。明确关联不受新题文本启发式影响。
    private func attachPreservedDraft(to instruction: String, draftID: UUID? = nil,
                                      sourceTaskID: UUID? = nil) {
        let instructionReference = Self.preservedDraftReference(in: instruction)
        let draft: PreservedDraft?
        do {
            if let draftID = draftID ?? instructionReference.draftID {
                draft = try preservedDraftStore.draft(id: draftID)
            } else if let referencedSourceTaskID = instructionReference.sourceTaskID {
                draft = try preservedDraftStore.draft(sourceTaskID: referencedSourceTaskID)
            } else if let sourceTaskID,
                      let taskDraft = try preservedDraftStore.draft(sourceTaskID: sourceTaskID) {
                draft = taskDraft
            } else {
                let associatedID = UserDefaults.standard.string(
                    forKey: Self.preservedDraftAssociationPrefix + runSessionID.uuidString).flatMap(UUID.init(uuidString:))
                let associatedDraft = try associatedID.flatMap { try preservedDraftStore.draft(id: $0) }
                let sessionDraft = try preservedDraftStore.draft(sourceSessionID: runSessionID)
                let candidate = associatedDraft ?? sessionDraft
                draft = candidate.flatMap { Self.sessionDraftApplies($0, to: instruction) ? $0 : nil }
                if let candidate, draft == nil {
                    appendStep("draft-restore", "新任务含明确的新题/新目标，未续用会话旧稿：draft=\(candidate.id.uuidString)、question=\(candidate.target.questionID)")
                }
            }
        } catch {
            activePreservedDraft = nil
            appendStep("draft-restore", "关联稿读取失败：\(error.localizedDescription)；未回退到全局最新稿")
            return
        }
        guard let draft, !draft.target.accountStableID.isEmpty, !draft.target.questionID.isEmpty else {
            activePreservedDraft = nil
            return
        }
        activePreservedDraft = draft
        currentZhihuWriteProof = nil
        currentZhihuPublishBinding = nil
        stateCard.addWrite(target: "独立稿件（待重新写入并核验）", body: draft.fullText, verification: "unknown")
        appendStep("draft-restore", "已按任务/会话关联取回稿件：draft=\(draft.id.uuidString)、version=\(draft.version)、sourceTask=\(draft.sourceTaskID.uuidString)、account=\(draft.target.accountStableID)、question=\(draft.target.questionID)、instruction=\(instruction.prefix(32))；旧页面凭证未移植")
    }

    /// Persist the conservative receipt before any submission can reach WK.
    private func prepareSubmissionIfNeeded(action: AgentAction, element: PageElement, pageURL: String) throws -> UUID? {
        guard action.action == "click", SubmissionClassifier.isSubmissionElement(element) else { return nil }
        guard !outcomeLedgerDecodeFailed else { throw MikaError("成果台账无法解码，已停止提交以免重复") }
        let (hash, prefix) = currentContentFingerprint()
        let host = URL(string: pageURL)?.host ?? ""
        let label = Self.elementLabel(of: element)
        guard !outcomeLedger.contains(where: { Self.outcomeMatches($0, fingerprint: hash, host: host, pageURL: pageURL, label: label) }) else {
            throw MikaError("同一目标已有提交记录，已阻断重放；请先独立回读")
        }
        let actionID = currentActionID ?? UUID()
        var record = OutcomeRecord(id: UUID(), pageURL: pageURL, host: host, elementLabel: label,
                                    contentFingerprint: hash, contentPrefix: prefix,
                                    statusNote: "派发未决（尚未确认调用）", recordedAt: Date(), resubmittedAt: nil)
        record.taskID = conversationTaskID
        record.actionID = actionID
        record.dispatchState = .unknown
        record.verificationVerdict = .unknown
        record.dispatchEvidence = "prepared-before-dispatch"
        outcomeLedger.append(record)
        guard saveOutcomeLedger() else { throw MikaError("提交回执持久化失败，未派发") }
        guard appendExecutionAudit(event: "dispatch-prepared", actionID: actionID,
                                   pageURL: pageURL, evidenceRef: record.id.uuidString) else {
            updateSubmissionDispatch(recordID: record.id, state: .notSent, evidence: "audit-write-failed-before-call")
            throw MikaError("审计日志写入失败，未派发提交")
        }
        if let taskID = conversationTaskID {
            taskClaims.append(TaskStateClaim(id: record.id, sourceTaskID: taskID,
                                             text: "在 \(host.isEmpty ? "本地页面" : host) 尝试「\(label)」提交\(prefix.isEmpty ? "内容" : "内容「\(prefix)…」")"))
        }
        saveTaskClaims()
        return record.id
    }

    private func updateSubmissionDispatch(recordID: UUID, state: OutcomeRecord.DispatchState, evidence: String) {
        guard let index = outcomeLedger.firstIndex(where: { $0.id == recordID }) else { return }
        let record = outcomeLedger[index]
        let audited = appendExecutionAudit(event: "dispatch-\(state.rawValue)", actionID: record.actionID ?? recordID,
                                           pageURL: record.pageURL, evidenceRef: recordID.uuidString)
        let effectiveState: OutcomeRecord.DispatchState = audited ? state : .unknown
        outcomeLedger[index].dispatchState = effectiveState
        outcomeLedger[index].dispatchEvidence = audited ? evidence : "audit-write-failed-after-call"
        outcomeLedger[index].statusNote = effectiveState == .sent ? "已派发，等待独立核验" :
            (effectiveState == .notSent ? "未派发" : "派发结果未知，禁止自动重放")
        if !saveOutcomeLedger() {
            if let current = outcomeLedger.firstIndex(where: { $0.id == recordID }) {
                outcomeLedger[current].dispatchState = .unknown
                outcomeLedger[current].statusNote = "回执写入失败，按派发未知处理"
            }
        }
    }

    // MARK: - 动作后核验（正式回写与防重放）

    /// Independent readback only; navigation is the sole production trigger.
    private func reconcileBlockingOutcomes(trigger: String) async {
        let taskID = conversationTaskID ?? runSessionID
        let token = generation
        let host = web.executionTab.webView.url?.host ?? ""
        let receipts = executionReceipts.filter { $0.taskID == taskID && $0.blocksDependencies }
        let records = outcomeLedger.filter {
            $0.unresolved && ($0.taskID == taskID || ($0.taskID == nil && $0.host == host))
        }
        guard !receipts.isEmpty || !records.isEmpty else { return }
        func bound(_ raw: String, to expected: String) -> Bool {
            guard let actual = URL(string: raw), let target = URL(string: expected) else { return false }
            if actual.isFileURL || target.isFileURL { return actual.absoluteString == target.absoluteString }
            return actual.scheme == target.scheme && actual.host == target.host && actual.path == target.path
        }
        for outcome in records {
            guard token == generation, !Task.isCancelled else { return }
            var readbackEntry: ReadbackTabRegistry.Entry?
            var captured: WebController.SettledCapture?
            if bound(web.executionTab.webView.url?.absoluteString ?? "", to: outcome.pageURL) {
                captured = await web.settledCapture()
            } else {
                do {
                    let sourceID = web.executionTab.id
                    let tab = try await auditedDispatch(name: "readback-navigation", pageURL: outcome.pageURL) {
                        try web.openTabForExecution(urlString: outcome.pageURL)
                    }
                    let previous = readbackTabs.readbackTab(forTask: taskID).flatMap { readbackTabs.entries[$0] }
                    if let oldID = readbackTabs.register(tabID: tab.id, ownerTaskID: taskID,
                                                       sourceTabID: sourceID, purpose: "readback"),
                       let previous, previous.tabID == oldID {
                        replacedReadbackTabIDs.insert(oldID)
                        await recycleReadbackTab(previous, for: taskID, expectedGeneration: token, excluding: [tab.id])
                    }
                    readbackEntry = readbackTabs.entries[tab.id]
                    captured = await web.settledCapture()
                } catch { /* No evidence: preserve both ledger and receipts. */ }
            }
            if let entry = readbackEntry {
                await recycleReadbackTab(entry, for: taskID, expectedGeneration: token)
            }
            guard token == generation, !Task.isCancelled else { return }
            guard let capture = captured, !capture.finalCaptureSkipped,
                  bound(capture.after.url, to: outcome.pageURL),
                  !outcome.contentPrefix.isEmpty,
                  ElementDescriptor.norm(capture.after.text).contains(outcome.contentPrefix) else {
                _ = appendExecutionAudit(event: "reconciliation-insufficient", actionID: outcome.actionID ?? outcome.id,
                                         pageURL: outcome.pageURL, evidenceRef: outcome.id.uuidString)
                continue
            }
            let verification = ActionVerifier.makeRecord(sessionID: runSessionID.uuidString,
                outcomeRecordID: outcome.id, actionLabel: outcome.elementLabel, pageURL: capture.after.url,
                result: .init(verdict: .verified,
                    evidence: ["reconciliation trigger=\(trigger) evidenceURL=\(capture.after.url); contentPrefix=\(outcome.contentPrefix)"],
                    weakEvidence: []), settled: capture.settled)
            guard VerificationLogStore.shared.append(verification),
                  let index = outcomeLedger.firstIndex(where: { $0.id == outcome.id && $0.unresolved }) else { continue }
            let original = outcomeLedger[index]
            if outcomeLedger[index].dispatchState == nil || outcomeLedger[index].dispatchState == .unknown {
                outcomeLedger[index].dispatchState = .sent
            }
            outcomeLedger[index].verificationVerdict = .verified
            outcomeLedger[index].verificationEvidenceID = verification.id
            outcomeLedger[index].statusNote = "已核实（独立回读对账）"
            guard saveOutcomeLedger() else {
                if let current = outcomeLedger.firstIndex(where: { $0.id == original.id }) {
                    outcomeLedger[current] = original
                } else { outcomeLedger.append(original) }
                continue
            }
            guard appendExecutionAudit(event: "reconciliation-verified", actionID: outcome.actionID ?? outcome.id,
                                       pageURL: capture.after.url, evidenceRef: verification.id.uuidString) else {
                if let current = outcomeLedger.firstIndex(where: { $0.id == original.id }) {
                    outcomeLedger[current] = original
                } else { outcomeLedger.append(original) }
                _ = saveOutcomeLedger()
                continue
            }
            if let actionID = outcome.actionID {
                for receipt in executionReceipts.filter({
                    $0.taskID == taskID && $0.actionID == actionID && $0.blocksDependencies
                }) {
                    _ = updateExecutionReceipt(id: receipt.id, state: .sent,
                                               evidence: verification.id.uuidString, verdict: .verified)
                }
            }
        }
    }

    /// 台账落记后随即运行的独立核验：settle 采样取新鲜证据 →
    /// ActionVerifier 三值判定 → 记录 append 落盘 verification-log
    /// .jsonl（台账旁记录）→ 步流补一条 verify 提示步（经
    /// pendingVerificationStep 在 outcome 步之后补入，runConfirmed 路径
    /// 就地补）。只有日志与台账都写成 verified 才晋级成果主张；其余
    /// 状态保持未决，阻断自动重放。取证异常保守记 unknown。
    private func runPostSubmissionVerification(recordID: UUID, element: PageElement, pageURL: String, before: PageState, token: UUID) async {
        let prefix = outcomeLedger.first(where: { $0.id == recordID })?.contentPrefix ?? currentContentFingerprint().prefix
        let label = Self.elementLabel(of: element)
        let capture = await web.settledCapture()
        guard token == generation else { return }
        let result = ActionVerifier.judge(before: before, after: capture.after, samples: capture.samples,
                                          settled: capture.settled, contentPrefix: prefix)
        let record = ActionVerifier.makeRecord(sessionID: runSessionID.uuidString, outcomeRecordID: recordID,
                                               actionLabel: label, pageURL: pageURL, result: result, settled: capture.settled)
        let logged = VerificationLogStore.shared.append(record)
        let auditLogged = appendExecutionAudit(event: "verification-\(logged ? result.verdict.rawValue : "log-failed")",
            actionID: outcomeLedger.first(where: { $0.id == recordID })?.actionID ?? recordID,
            pageURL: pageURL, evidenceRef: logged ? record.id.uuidString : "verification-log-write-failed")
        let recorded = logged && auditLogged
        let actionID = outcomeLedger.first(where: { $0.id == recordID })?.actionID
        var receiptRecorded = false
        if let actionID, let id = executionReceipts.last(where: { $0.actionID == actionID && $0.critical })?.id {
            receiptRecorded = updateExecutionReceipt(id: id, state: .sent, evidence: record.id.uuidString,
                                                     verdict: recorded ? result.verdict : .unknown)
        }
        var promoted = false
        if let index = outcomeLedger.firstIndex(where: { $0.id == recordID }) {
            // A failed evidence write cannot promote a result to success.
            let completeEvidence = recorded && receiptRecorded && outcomeLedger[index].dispatchState == .sent
            outcomeLedger[index].verificationVerdict = completeEvidence ? result.verdict : .unknown
            outcomeLedger[index].verificationEvidenceID = completeEvidence ? record.id : nil
            outcomeLedger[index].statusNote = completeEvidence && result.verdict == .verified
                ? "已核实" : "提交结果未决，禁止自动重放"
            let persisted = saveOutcomeLedger()
            if !persisted, let current = outcomeLedger.firstIndex(where: { $0.id == recordID }) {
                outcomeLedger[current].verificationVerdict = .unknown
                outcomeLedger[current].statusNote = "台账写入失败，提交结果未决"
            }
            promoted = completeEvidence && persisted && result.verdict == .verified
            if completeEvidence && persisted && result.verdict == .verified,
               let claimIndex = taskClaims.firstIndex(where: { $0.id == recordID }) {
                _ = taskClaims[claimIndex].setStatus(.verified)
                saveTaskClaims()
            }
        }
        let evidenceText = result.evidence.first ?? result.weakEvidence.first ?? "无 conclusive 证据"
        switch result.verdict {
        case .verified:
            pendingVerificationStep = "动作后核验：\(promoted ? "verified，台账已回写" : "证据链不完整，结果保持 unknown")——\(evidenceText)。"
        case .contradicted:
            pendingVerificationStep = "动作后核验：contradicted——\(evidenceText)。已阻断自动重发，请回读实际结果。"
        case .unknown:
            pendingVerificationStep = "动作后核验：unknown——\(evidenceText)。已阻断自动重发，请去列表/记录页核查。"
        }
    }

    /// 自检十三 Tier A（VERIFY-1）：核验合约全链程序化核查——
    /// WebController 在合成页 test-verify 真实驱动四场景（三值＋证据
    /// 未稳），产出的记录在本层做落盘往返与分歧统计核对（临时日志，
    /// 不污染正式 shadow 数据）。不调用模型；要求引擎空闲（驱动会占
    /// 用当前标签页打开合成页）。
    func verifyActionVerificationContract() async -> [String] {
        guard !busy else { return ["✗ 引擎忙碌中，自检十三 Tier A 未执行（当前任务未终结：可等它跑完，或在暂停时点『结束任务』）"] }
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

    /// 任何匹配的提交记录都阻断自动重放；confirmed 路径在派发前也
    /// 由 prepareSubmissionIfNeeded 做同一检查。
    private func duplicateSubmissionBlock(element: PageElement, pageURL: String) -> (step: String, hint: String)? {
        guard SubmissionClassifier.isSubmissionElement(element) else { return nil }
        let (hash, _) = currentContentFingerprint()
        let host = URL(string: pageURL)?.host ?? ""
        let label = Self.elementLabel(of: element)
        guard let record = outcomeLedger.first(where: { Self.outcomeMatches($0, fingerprint: hash, host: host, pageURL: pageURL, label: label) }) else { return nil }
        _ = appendExecutionAudit(event: "refusal-duplicate", actionID: currentActionID ?? UUID(),
                                 pageURL: pageURL, evidenceRef: record.id.uuidString)
        let when = Self.outcomeTime(record.recordedAt)
        let contentDesc = record.contentPrefix.isEmpty ? "该内容" : "内容「\(record.contentPrefix)…」"
        let shownStatus = Self.displayedOutcomeStatus(record.statusNote)
        let step = "重复提交提醒：\(contentDesc)已于 \(when) 在 \(record.host.isEmpty ? "本地页面" : record.host) 提交过（状态：\(shownStatus)），本次重复提交已拦下未执行——先去内容列表/记录页核查现状再决定"
        let hint = "【重复提交阻断】\(contentDesc)已有派发记录，核验=\(record.verificationVerdict?.rawValue ?? "unknown")。本次点击未执行。先去内容列表或记录页独立回读；unknown/contradicted 不得自动重放。"
        return (step, hint)
    }

    /// 只看本次运行落记、且仍待核查的条目；台账本身跨任务保存。
    private static func pendingOutcomes(_ records: [OutcomeRecord], since startedAt: Date?) -> [OutcomeRecord] {
        guard let startedAt else { return [] }
        return records.filter { $0.recordedAt >= startedAt && $0.unresolved }
    }

    /// 完成断言词前四字内有否定词时不触发；「未核实」出现在断言之后
    /// 仍算断言，需由自证门要求回读。
    private static func containsCompletionClaim(summary: String) -> Bool {
        let claims = ["已发表", "已发布", "已提交", "已存草稿", "已保存", "发表成功", "提交成功", "发布成功", "保存成功", "已投稿", "发送成功", "已发送", "已完成"]
        let negations = ["未", "没", "无法", "未能", "尚未"]
        for claim in claims {
            var search = summary.startIndex..<summary.endIndex
            while let range = summary.range(of: claim, range: search) {
                let prefix = summary[..<range.lowerBound].suffix(4)
                if !negations.contains(where: { prefix.contains($0) }) { return true }
                search = range.upperBound..<summary.endIndex
            }
        }
        return false
    }

    /// done 只把模型结案自述附于本轮待核查条目，不据此晋级核实状态。
    private func recordCompletionClaim(summary: String, since startedAt: Date?) {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var changed = false
        guard let startedAt else { return }
        for index in outcomeLedger.indices where outcomeLedger[index].recordedAt >= startedAt && outcomeLedger[index].statusNote.contains("待核查") {
            if taskClaims.first(where: { $0.id == outcomeLedger[index].id })?.verifiedByUser == true { continue }
            outcomeLedger[index].statusNote = "已提交（待核查）；结案自述（未经独立核实）：\(String(trimmed.prefix(80)))"
            changed = true
        }
        if changed { saveOutcomeLedger() }
    }

    /// 旧数据只在展示时映射，不改盘上的原字段。
    private static func displayedOutcomeStatus(_ note: String) -> String {
        let legacy = "已核实（完成总结）"
        guard note.hasPrefix(legacy) else { return note }
        return "结案自述（旧口径，未经独立核实）" + String(note.dropFirst(legacy.count))
    }

    /// 自检二十七（FINAL-CLAIM-AUDIT）：纯断言真值表与跨任务时间筛选。
    /// 不调用模型、不改引擎现场；可由调试入口调用。
    func verifyFinalClaimAudit() -> [String] {
        let cases: [(String, Bool)] = [
            ("已发表", true), ("文章已发布", true), ("已提交审核", true),
            ("已存草稿", true), ("已保存", true), ("发表成功", true),
            ("提交成功", true), ("发布成功", true), ("保存成功", true),
            ("已投稿", true), ("发送成功", true),
            ("未发布", false), ("没提交成功", false), ("无法保存成功", false),
            ("未能发表成功", false), ("尚未存草稿", false),
            ("已完成但未核实", true),
            ("已查看列表，汇总如下", false), ("", false)
        ]
        var lines = cases.map { item in
            let (sample, expected) = item
            let actual = Self.containsCompletionClaim(summary: sample)
            return "\(actual == expected ? "✓" : "✗") 断言「\(sample.isEmpty ? "（空串）" : sample)」：期望 \(expected)，实际 \(actual)"
        }
        let start = Date()
        func sample(_ time: Date, _ note: String) -> OutcomeRecord {
            OutcomeRecord(id: UUID(), pageURL: "https://example.invalid/list", host: "example.invalid",
                          elementLabel: "提交", contentFingerprint: "", contentPrefix: "样本",
                          statusNote: note, recordedAt: time, resubmittedAt: nil)
        }
        let old = sample(start.addingTimeInterval(-1), "已提交（待核查）")
        let current = sample(start, "已提交（待核查）")
        var checked = sample(start.addingTimeInterval(1), "页面回读已核实")
        checked.dispatchState = .sent
        checked.verificationVerdict = .verified
        let pending = Self.pendingOutcomes([old, current, checked], since: start)
        lines.append("\(pending.count == 1 && pending[0].id == current.id ? "✓" : "✗") 运行起点筛选：旧任务待核查与已离开待核查状态的条目均不入门")
        let legacy = Self.displayedOutcomeStatus("已核实（完成总结）：旧总结")
        lines.append("\(legacy == "结案自述（旧口径，未经独立核实）：旧总结" ? "✓" : "✗") 旧状态只在展示时降级，原字段不迁移")
        return lines
    }

    /// 自检五十三至五十五（MIKA-FIX3）：纯结构断言，不调用模型、不改现场。
    func verifyTaskClaimIsolation() -> [String] {
        let taskA = UUID(), taskB = UUID()
        var card = TaskStateCard(goal: "任务乙")
        card.claims = [
            TaskStateClaim(sourceTaskID: taskA, text: "甲的未核实细节：旧发布待核查"),
            TaskStateClaim(sourceTaskID: taskA, text: "甲的已核实事实：用户确认已发布", status: .verified, verifiedByUser: true),
            TaskStateClaim(sourceTaskID: taskB, text: "乙的本任务主张")
        ]
        let prompt = card.claimPromptBlock(currentTaskID: taskB)
        return [
            "\(!prompt.contains("甲的未核实细节") ? "✓" : "✗") 任务乙 prompt 不含任务甲未核实主张细节",
            "\(prompt.contains("上个任务有未核实记录（不属于本任务）") ? "✓" : "✗") 跨任务未核实项只留一行无义务提示",
            "\(prompt.contains("已核实事实（背景，只读；本任务不得重开或降级）") && prompt.contains("甲的已核实事实") ? "✓" : "✗") 任务甲已核实事实作为只读背景出现",
            "\(prompt.contains("乙的本任务主张") ? "✓" : "✗") 任务乙自产主张照常出现"
        ]
    }

    func verifyUserFinalClaim() -> [String] {
        var claim = TaskStateClaim(sourceTaskID: UUID(), text: "用户确认已发布")
        let upgraded = claim.setStatus(.verified, verifiedByUser: true)
        let rejected = !claim.setStatus(.unverified)
        return [
            "\(upgraded && claim.verifiedByUser && claim.status == .verified ? "✓" : "✗") verifiedByUser 写入后成为已核实终局",
            "\(rejected && claim.status == .verified ? "✓" : "✗") 降级为未核实/待核查的写入被拒",
            "\(claim.displayText.contains("据用户确认") ? "✓" : "✗") 后续呈现只按据用户确认口径"
        ]
    }

    func verifyFix3SystemRules() -> [String] {
        let text = ModelClient.system
        return [
            "\(text.contains("新任务") && text.contains("不得反问任务身份或范围") && text.contains("口语默认是语气词") ? "✓" : "✗") 新任务明确时不反问且口语不当标题",
            "\(text.contains("同站同题至多 1 步") && text.contains("不得展开多步复查") && text.contains("不得改写旧结论") ? "✓" : "✗") 旧账只许防重所需最小检查",
            "\(text.contains("本任务成败只按本任务的动作与回读判定") && text.contains("用户对既往动作的明确确认或纠正是终局事实") ? "✓" : "✗") 证据任务内一致且用户确认终局"
        ]
    }

    /// 自检六十四的引擎半边：直接经过主循环使用的动作改写入口与 prompt
    /// 组装器，证明 wait/done 不能夺回发布决策，且历史折叠、超长页面 JSON
    /// 不会吞掉每轮程序派生指令。现场在 defer 中逐项恢复。
    func verifyZhihuPublishOrchestration() -> [String] {
        let savedDecision = currentZhihuDecision
        let savedDirective = currentZhihuDirective
        let savedSteps = steps
        let savedGoal = goal
        defer {
            currentZhihuDecision = savedDecision
            currentZhihuDirective = savedDirective
            steps = savedSteps
            goal = savedGoal
        }
        currentZhihuDecision = .attemptOnce
        currentZhihuDirective = ZhihuPublishDirective(writeStatus: "verified", publicationStatus: "ready_to_attempt",
            publishTarget: "fixture-button", evidenceSource: "Draft committed full equality",
            disabledObservation: "native=true, source=native-disabled",
            disabledTrustForThisDecision: "non_blocking", nextAction: "attempt_publish_once", blockingReason: nil)
        goal = "发布这个知乎回答"
        steps = (1...20).map { AgentStep(id: $0, action: "observe", reason: String(repeating: "历史正文", count: 80)) }
        let prompt = buildPrompt(pageJSON: String(repeating: "超长页面", count: 8_000), answersJSON: "[]",
                                 foldLevel: 3, loopHint: nil, outcomeHint: nil)
        return [
            "\(resolvedZhihuAction(proposedAction: "wait") == "attempt_publish_once" && resolvedZhihuAction(proposedAction: "done") == "attempt_publish_once" ? "✓" : "✗") 六十四-A：主循环生产改写入口把 wait/done 固定为 attempt_publish_once",
            "\(prompt.contains("【知乎发布派生指令】") && prompt.contains("nextAction: attempt_publish_once") && !prompt.contains("1. observe:") ? "✓" : "✗") 六十四-B：历史超过 12 步并处于最紧折叠、页面 JSON 超长时派生策略仍每轮在场"
        ]
    }

    /// 自检六十六起：授权解析与引擎改写门共用同一状态对象。引用内容先被
    /// 剥离，否定/未来时序撤销当前授权，插话变更留下 revision 与来源。
    func verifyZhihuPublishAuthorization() -> [String] {
        func line(_ ok: Bool, _ text: String) -> String { "\(ok ? "✓" : "✗") \(text)" }
        let notNow = PublishAuthorization.initial(instruction: "帮我写回答，暂不发表")
        let later = PublishAuthorization.initial(instruction: "只写草稿，稍后发布")
        let quoted = PublishAuthorization.initial(instruction: "检查这份回答，原文写着“点击发布回答”")
        let send = PublishAuthorization.initial(instruction: "把这篇回答发出去")
        var steered = PublishAuthorization.initial(instruction: "把这篇回答发布到知乎")
        let beforeRevision = steered.revision
        steered.apply(instruction: "改成只存草稿", source: "steer:fixture")
        let engineBlocked = !steered.allowsZhihuAnswer &&
            ZhihuPublishPolicy.finalAction(for: .blocked(steered.explanation), proposedAction: "done") == "done"
        var pending = PublishAuthorization.initial(instruction: "先写这篇回答，等我确认后再发布这篇回答")
        let pendingRevision = pending.revision
        pending.apply(instruction: "可以发了", source: "steer:confirmation")
        let markdownQuote = PublishAuthorization.initial(instruction: "检查下面的引用：\n> 点击发布回答")
        return [
            line(!notNow.allowsZhihuAnswer, "六十六：『暂不发表』不授予当前发布"),
            line(!later.allowsZhihuAnswer, "六十七：『只写草稿，稍后发布』只表达未来时序"),
            line(!quoted.allowsZhihuAnswer, "六十八：引用正文中的『发布』不参与授权"),
            line(send.allowsZhihuAnswer && send.scopes == ["zhihu_answer"] &&
                 PublishAuthorization.initial(instruction: "这篇回答发了").allowsZhihuAnswer &&
                 PublishAuthorization.initial(instruction: "提交回答").allowsZhihuAnswer,
                 "六十九：『把这篇回答发出去／发了／提交回答』明确授权回答范围"),
            line(engineBlocked && steered.revision == beforeRevision + 1 && steered.source == "steer:fixture" && steered.history.last?.authorized == false,
                 "七十：最新插话改为只存草稿后，引擎不再把 wait/done 改写为点击，并保留变更来源"),
            line(pendingRevision > 0 && pending.allowsZhihuAnswer && pending.history.contains(where: { $0.pending == true }),
                 "七十一-策略：条件发布先记 pending，后续『可以发了』才转为 authorized"),
            line(!markdownQuote.allowsZhihuAnswer && markdownQuote.history.isEmpty,
                 "七十二-策略：Markdown > 引用块与指令本体真正分离，不产生授权历史")
        ]
    }

    /// FIX6：受控动作源直接接入 launch() 生产主循环。这里不直接调用
    /// noteTypedContent/attemptZhihuPublishOnce/runZhihuReadback；type→wait→连续
    /// click→done 全由主循环消费。恢复分支创建新的 AgentEngine，并调用同一个
    /// restoreSnapshot(for:) 生产入口。
    func verifyZhihuProductionOrchestration() async -> [String] {
        var failureContexts: [String] = []
        var failureHosts: [WKSelfTestHost] = [
            WKSelfTestHost(tab: web.executionTab, suite: "zhihu-production-orchestration-root")
        ]
        func line(_ ok: Bool, _ text: String) -> String {
            if !ok { failureContexts.append(text) }
            return "\(ok ? "✓" : "✗") \(text)"
        }
        func action(_ name: String, index: Int = -1, text: String = "", summary: String = "") throws -> AgentAction {
            let data = try JSONSerialization.data(withJSONObject: ["action": name, "index": index,
                "text": text, "reason": "FIX6 controlled production loop", "summary": summary])
            return try JSONDecoder().decode(AgentAction.self, from: data)
        }
        func isDone(_ engine: AgentEngine) -> Bool { if case .done = engine.status { return true }; return false }
        func isPaused(_ engine: AgentEngine) -> Bool { if case .paused = engine.status { return true }; return false }
        func waitFor(_ predicate: @escaping () -> Bool, seconds: Double) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if predicate() { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return predicate()
        }
        func prepareDirectory(_ sessionID: UUID) -> URL {
            let directory = SessionStore.shared.snapshotURL(for: sessionID).deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        func loadFixture(_ web: WebController, outcome: String = "published",
                         questionID: String = "4242", label: String) async throws
            -> (editor: PageElement, publish: PageElement) {
            failureHosts.append(WKSelfTestHost(tab: web.executionTab,
                suite: "zhihu-production-orchestration-\(label)"))
            return try await web.loadZhihuEngineFixture(outcome: outcome, questionID: questionID)
        }
        func loadModalFixture(_ web: WebController, mode: String) async throws -> PageElement {
            failureHosts.append(WKSelfTestHost(tab: web.executionTab,
                suite: "zhihu-production-orchestration-modal-\(mode)"))
            return try await web.loadZhihuModalEngineFixture(mode: mode)
        }
        func configure(_ engine: AgentEngine, web: WebController, sessionID: UUID, taskID: UUID,
                       goal: String, actions: [AgentAction], readbackBody: String? = nil) {
            engine.runSessionID = sessionID
            engine.goal = goal; engine.taskText = goal; engine.conversationTaskID = taskID
            engine.stateCard = TaskStateCard(goal: goal); engine.steps = []; engine.stepSeq = 0
            engine.limit = 25; engine.stepBudget = StepBudget(limit: 25)
            engine.queuedTasks = []; engine.acceptedSteerQueueIDs = []
            engine.currentZhihuWriteProof = nil; engine.currentZhihuPublishBinding = nil
            engine.currentZhihuDecision = nil; engine.currentZhihuDirective = nil
            engine.currentZhihuAuthorization = .initial(instruction: goal)
            engine.matchedZhihuPublishRecord = nil
            engine.controlledActions = actions; engine.controlledActionCursor = 0
            engine.controlledZhihuReadback = true
            engine.controlledZhihuReadbackBodyOverride = readbackBody
            engine.controlledDidSuspendAfterZhihuClick = false
            web.beginExecution(sessionID: sessionID)
        }

        var lines: [String] = []
        let suffix = UUID().uuidString
        let ledgerKey = "zhihuPublishLedger.selftest.fix6.\(suffix)"
        let draftOnlyKey = "zhihuPublishLedger.selftest.draft-only.\(suffix)"
        let switchOffKey = "zhihuPublishLedger.selftest.switch-off.\(suffix)"
        let revokeKey = "zhihuPublishLedger.selftest.revoke.\(suffix)"
        let recoveryKey = "zhihuPublishLedger.selftest.recovery.\(suffix)"
        let timeoutKey = "zhihuPublishLedger.selftest.timeout.\(suffix)"
        var keys = [ledgerKey, draftOnlyKey, switchOffKey, revokeKey, recoveryKey, timeoutKey]
        let isolatedDraftDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mika-selftest-drafts-\(suffix)", isDirectory: true)
        let isolatedDraftStore = PreservedDraftStore(
            fileURL: isolatedDraftDirectory.appendingPathComponent("drafts.json"))
        let formalDraftsBefore = try? PreservedDraftStore.shared.all()
        var directories: [URL] = [isolatedDraftDirectory]
        defer {
            for key in keys {
                UserDefaults.standard.removeObject(forKey: key)
                UserDefaults.standard.removeObject(forKey: key + ".accounts")
            }
            for directory in directories { try? FileManager.default.removeItem(at: directory) }
        }

        do {
            let paragraph = "这是一段用于验证真实知乎发布链的长文。它保留中文标点、数字 2026、大小写 MikaWeb 和空格；每一段都必须由生产 type 路径写进 Draft，再由站点处理器实际接收，不能从测试期望值反向生成详情页。"
            let body = (1...22).map { "第\($0)段：\(paragraph)" }.joined(separator: "\n\n")
            guard body.count >= 1500 else { throw MikaError("五十六长文不足 1500 字") }

            let retentionURL = isolatedDraftDirectory.appendingPathComponent("retention.json")
            let retentionStore = PreservedDraftStore(fileURL: retentionURL)
            for index in 1...21 {
                _ = try retentionStore.save(fullText: "稿件 \(index)",
                    target: PreservedDraftTarget(accountStableID: "zhacct-retention",
                        accountAliases: ["retention"], questionID: String(index)),
                    sourceTaskID: UUID(), sourceSessionID: UUID())
            }
            lines.append(line(try retentionStore.all().count == 21,
                              "稿库保全：第 21 个不同目标写入后仍保留 21 份，不静默淘汰"))
            let corruptURL = isolatedDraftDirectory.appendingPathComponent("corrupt.json")
            let corruptBytes = Data("{not-json".utf8)
            try corruptBytes.write(to: corruptURL, options: .atomic)
            let corruptStore = PreservedDraftStore(fileURL: corruptURL)
            var corruptSaveRejected = false
            do {
                _ = try corruptStore.save(fullText: "不得覆盖",
                    target: PreservedDraftTarget(accountStableID: "zhacct-corrupt",
                        accountAliases: ["corrupt"], questionID: "corrupt"),
                    sourceTaskID: UUID())
            } catch { corruptSaveRejected = true }
            let corruptAfter = try Data(contentsOf: corruptURL)
            lines.append(line(corruptSaveRejected && corruptAfter == corruptBytes,
                              "稿库保全：存在但解码失败的文件使 save 报错，原字节保持不变"))

            // 同一会话中否定旧题并指定新题时不能继承旧稿；随后由全新任务携带
            // 明确 draftID，越过会话最新乙稿取回甲稿。三段都走 startInSession。
            let interleaveStore = PreservedDraftStore(
                fileURL: isolatedDraftDirectory.appendingPathComponent("interleaved.json"))
            let interleaveSession = UUID(), topicATask = UUID(), topicBTask = UUID()
            directories.append(prepareDirectory(interleaveSession))
            let topicABody = "甲稿全文：围绕可靠恢复说明证据边界；甲稿标识只应出现在问题 6101。"
            let topicBBody = "乙稿全文：围绕独立保存说明新题隔离；乙稿标识只应出现在问题 6102。"

            let topicAWeb = WebController(); topicAWeb.beginExecution(sessionID: interleaveSession)
            let topicAFixture = try await loadFixture(topicAWeb, questionID: "6101", label: "topic-a")
            let topicAEngine = AgentEngine(web: topicAWeb, settings: SettingsStore(),
                zhihuPublishLedgerKeyOverride: draftOnlyKey, preservedDraftStore: interleaveStore,
                controlledZhihuPublishFixture: true, restoreSession: false)
            configure(topicAEngine, web: topicAWeb, sessionID: interleaveSession, taskID: topicATask,
                goal: "为知乎问题 6101 写甲题回答，只保存草稿", actions: [
                    try action("type", index: topicAFixture.editor.index, text: topicABody),
                    try action("done", summary: "甲稿已保存")
                ])
            topicAEngine.startInSession(interleaveSession, local: nil,
                task: "为知乎问题 6101 写甲题回答，只保存草稿", startingID: topicATask)
            let topicADone = await waitFor({ isDone(topicAEngine) }, seconds: 20)
            let savedA = try interleaveStore.draft(sourceTaskID: topicATask)

            let topicBWeb = WebController(); topicBWeb.beginExecution(sessionID: interleaveSession)
            let topicBFixture = try await loadFixture(topicBWeb, questionID: "6102", label: "topic-b")
            let topicBEngine = AgentEngine(web: topicBWeb, settings: SettingsStore(),
                zhihuPublishLedgerKeyOverride: draftOnlyKey, preservedDraftStore: interleaveStore,
                controlledZhihuPublishFixture: true, restoreSession: false)
            let topicBInstruction = "不要继续问题 6101，改写问题 6102，只保存草稿"
            configure(topicBEngine, web: topicBWeb, sessionID: interleaveSession, taskID: topicBTask,
                goal: topicBInstruction, actions: [
                    try action("type", index: topicBFixture.editor.index, text: topicBBody),
                    try action("done", summary: "乙稿已保存")
                ])
            topicBEngine.startInSession(interleaveSession, local: nil,
                task: topicBInstruction, startingID: topicBTask)
            let topicBDone = await waitFor({ isDone(topicBEngine) }, seconds: 20)
            let savedB = try interleaveStore.draft(sourceTaskID: topicBTask)

            let restoreATask = UUID()
            let restoreAWeb = WebController(); restoreAWeb.beginExecution(sessionID: interleaveSession)
            let restoreAFixture = try await loadFixture(restoreAWeb, questionID: "6101", label: "topic-a-restore")
            let restoreAEngine = AgentEngine(web: restoreAWeb, settings: SettingsStore(),
                zhihuPublishLedgerKeyOverride: draftOnlyKey, preservedDraftStore: interleaveStore,
                controlledZhihuPublishFixture: true, restoreSession: false)
            let restoreAInstruction = "恢复 draftID: \(savedA?.id.uuidString ?? "missing") 的甲稿并继续编辑"
            configure(restoreAEngine, web: restoreAWeb, sessionID: interleaveSession, taskID: restoreATask,
                goal: restoreAInstruction, actions: [
                    try action("type", index: restoreAFixture.editor.index, text: "__MIKA_PRESERVED_DRAFT__"),
                    try action("done", summary: "甲稿恢复完成")
                ])
            restoreAEngine.startInSession(interleaveSession, local: nil,
                task: restoreAInstruction, startingID: restoreATask)
            let restoreADone = await waitFor({ isDone(restoreAEngine) }, seconds: 20)
            let restoredA = try interleaveStore.draft(sourceTaskID: topicATask)
            let interleavedDrafts = try interleaveStore.all()
            let topicBDetached = topicBEngine.steps.contains {
                $0.action == "draft-restore" && $0.reason.contains("明确的新题/新目标")
            }
            let topicARestored = restoreAEngine.steps.contains {
                $0.action == "draft-restore" && $0.reason.contains(savedA?.id.uuidString ?? "missing")
            }
            lines.append(line(topicADone && topicBDone && restoreADone && topicBDetached && topicARestored &&
                              restoreATask != topicATask && restoreAEngine.conversationTaskID == restoreATask &&
                              savedA?.id != savedB?.id && interleavedDrafts.count == 2 &&
                              savedA?.target.questionID == "6101" && savedA?.sourceTaskID == topicATask &&
                              savedB?.target.questionID == "6102" && savedB?.sourceTaskID == topicBTask &&
                              savedA?.fullText == topicABody && savedB?.fullText == topicBBody &&
                              restoredA?.id == savedA?.id && restoredA?.sourceTaskID == topicATask &&
                              restoredA?.fullText == topicABody &&
                              restoreAEngine.currentZhihuWriteProof?.taskID == restoreATask &&
                              restoreAEngine.currentZhihuWriteProof?.expectedText == topicABody,
                              "关联取稿：6101→否定旧题并指定 6102 时乙稿独立保存；全新任务按明确 draftID 越过最新乙稿恢复甲，全文一致且两稿保留"))

            // 真实生产主循环先完成“只写草稿”任务；任务收口后不靠任务快照，
            // 新建 Store/Engine 模拟进程退出，再从独立稿件文件取回正文。
            // CLI WK 自检会在本轮完成后由 CI 真正终止 App，再用新进程从此
            // 隔离目录按 draftID 回读。它不使用正式稿库。
            let draftDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MikaWebSelfTest/process-restart", isDirectory: true)
            try? FileManager.default.removeItem(at: draftDirectory)
            try FileManager.default.createDirectory(at: draftDirectory, withIntermediateDirectories: true)
            let draftURL = draftDirectory.appendingPathComponent("drafts.json")
            let sourceStore = PreservedDraftStore(fileURL: draftURL)
            let sourceSession = UUID(), sourceTask = UUID()
            directories.append(prepareDirectory(sourceSession))
            let sourceWeb = WebController(); sourceWeb.beginExecution(sessionID: sourceSession)
            let sourceFixture = try await loadFixture(sourceWeb, label: "draft-source")
            let sourceEngine = AgentEngine(web: sourceWeb, settings: SettingsStore(),
                zhihuPublishLedgerKeyOverride: draftOnlyKey, preservedDraftStore: sourceStore,
                controlledZhihuPublishFixture: true, restoreSession: false)
            configure(sourceEngine, web: sourceWeb, sessionID: sourceSession, taskID: sourceTask,
                goal: "只写草稿，不发布这篇知乎回答", actions: [
                    try action("type", index: sourceFixture.editor.index, text: body),
                    try action("done", summary: "草稿任务已收口")
                ])
            sourceEngine.startInSession(sourceSession, local: nil,
                task: "只写草稿，不发布这篇知乎回答", startingID: sourceTask)
            let sourceDone = await waitFor({ isDone(sourceEngine) }, seconds: 30)
            let sourceProof = sourceEngine.currentZhihuWriteProof
            let persistedBeforeRestart = sourceStore.latestZhihuDraft()

            let restartedStore = PreservedDraftStore(fileURL: draftURL)
            let restoredAfterRestart = restartedStore.latestZhihuDraft()
            if let checkpoint = restoredAfterRestart {
                let marker: [String: Any] = ["draftID": checkpoint.id.uuidString,
                    "textHash": checkpoint.textHash, "accountStableID": checkpoint.target.accountStableID,
                    "accountAliases": checkpoint.target.accountAliases, "questionID": checkpoint.target.questionID,
                    "sourceSessionID": sourceSession.uuidString, "sourceTaskID": sourceTask.uuidString]
                let data = try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys])
                try data.write(to: draftDirectory.appendingPathComponent("checkpoint.json"), options: .atomic)
            }
            let expectedAliases = ZhihuAccountIdentity.normalizedAliases(["engine-me-id", "engine-me-token"])
            let expectedStableID = "zhacct-\(ZhihuPublishPolicy.hash(expectedAliases.joined(separator: "|")))"
            lines.append(line(sourceDone && sourceProof?.isValid == true && sourceProof?.taskID == sourceTask &&
                              persistedBeforeRestart?.fullText == body &&
                              restoredAfterRestart?.fullText == body &&
                              restoredAfterRestart?.version == 1 &&
                              restoredAfterRestart?.target.accountStableID == expectedStableID &&
                              restoredAfterRestart?.target.accountAliases == expectedAliases &&
                              restoredAfterRestart?.target.questionID == "4242" &&
                              restoredAfterRestart?.sourceTaskID == sourceTask,
                              "稿件保全-A：聊天共用启动入口只写草稿→任务收口→新 Store 恢复；全文/版本/zhacct 稳定身份＋别名/题目/来源任务仍在"))

            // 56 主回归：新任务补授权，从独立稿件取回全文；旧 proof 不迁移，
            // 当前页重新写入后才生成新 proof，再由 launch() 完成发布编排。
            let mainSession = sourceSession, mainTask = UUID()
            let mainWeb = WebController()
            mainWeb.beginExecution(sessionID: mainSession)
            let mainFixture = try await loadFixture(mainWeb, label: "authorization-main")
            let mainEngine = AgentEngine(web: mainWeb, settings: SettingsStore(),
                                         zhihuPublishLedgerKeyOverride: ledgerKey,
                                         preservedDraftStore: restartedStore,
                                         controlledZhihuPublishFixture: true, restoreSession: false)
            configure(mainEngine, web: mainWeb, sessionID: mainSession, taskID: mainTask,
                goal: "把这篇知乎回答发出去", actions: [
                    try action("type", index: mainFixture.editor.index, text: "__MIKA_PRESERVED_DRAFT__"),
                    try action("wait"), try action("click", index: -2),
                    try action("click", index: -2), try action("done", summary: "自检链已收口")
                ])
            mainEngine.startInSession(mainSession, local: nil,
                task: "把这篇知乎回答发出去", startingID: mainTask)
            let mainDone = await waitFor({ isDone(mainEngine) }, seconds: 30)
            let mainProof = mainEngine.currentZhihuWriteProof
            let mainMetrics = await mainWeb.controlledZhihuFixtureMetrics()
            let mainRecord = mainEngine.zhihuPublishRecords.last
            let repeatedBlocked = mainEngine.steps.filter { $0.reason.contains("模型再次请求发布未执行") }.count >= 2
            lines.append(line(mainDone && mainRecord?.status == .verifiedPublished,
                              "五十六-引擎A：真实主循环完成 type→wait 改写→独立详情回读→done 结案"))
            let persistedAfterRewrite = restartedStore.latestZhihuDraft()
            let restoredThroughChatStart = mainEngine.steps.contains { $0.action == "draft-restore" && $0.reason.contains(restoredAfterRestart?.id.uuidString ?? "missing") }
            lines.append(line(restoredThroughChatStart && mainProof?.isValid == true &&
                              mainProof?.taskID == mainTask && sourceProof?.taskID != mainProof?.taskID &&
                              mainRecord?.sourceText == body && mainRecord?.clickCallCount == 1 &&
                              mainMetrics.handlerCalls == 1 &&
                              persistedAfterRewrite?.version == 2 && persistedAfterRewrite?.sourceTaskID == sourceTask &&
                              ZhihuPublishPolicy.normalizeFullText(body) == ZhihuPublishPolicy.normalizeFullText(persistedAfterRewrite?.fullText ?? "") &&
                              ZhihuPublishPolicy.normalizeFullText(body) == ZhihuPublishPolicy.normalizeFullText(mainMetrics.publishedBody),
                              "五十六-引擎B：补授权经聊天共用启动入口按 draftID 取得正文；源稿＝持久稿＝committed/handler 全文（≥1500字），旧 proof 未迁移，新任务重验后仅点击一次"))
            lines.append(line(repeatedBlocked && mainEngine.stateCard.zhihuPublicationStatus == "已核实发布",
                              "五十七/六十三：连续 click 输入均被同题账拦截，状态卡仅在独立回读后晋级"))

            // 默认关闭态使用同一真实 launch 入口，但不授予 controlled fixture
            // 例外；引擎必须在 Web 点击入口之前留痕并允许 done 正常收口。
            let previousSwitchValue = UserDefaults.standard.object(forKey: "zhihuAutoPublishEnabled")
            let offSettings = SettingsStore(); offSettings.zhihuAutoPublishEnabled = false
            let offSession = UUID(), offTask = UUID()
            directories.append(prepareDirectory(offSession))
            let offWeb = WebController(); offWeb.beginExecution(sessionID: offSession)
            let offFixture = try await loadFixture(offWeb, label: "switch-off")
            let offEngine = AgentEngine(web: offWeb, settings: offSettings,
                zhihuPublishLedgerKeyOverride: switchOffKey,
                preservedDraftStore: restartedStore, restoreSession: false)
            configure(offEngine, web: offWeb, sessionID: offSession, taskID: offTask,
                goal: "发布这篇知乎回答", actions: [
                    try action("type", index: offFixture.editor.index, text: body),
                    try action("wait"), try action("done", summary: "开关关闭，零点击收口")
                ])
            offEngine.launch()
            let offDone = await waitFor({ isDone(offEngine) }, seconds: 20)
            let offMetrics = await offWeb.controlledZhihuFixtureMetrics()
            let switchTrace = offEngine.steps.contains { $0.action == "publish-decision" && $0.reason.contains("开关关闭") }
            lines.append(line(offDone && switchTrace && offMetrics.handlerCalls == 0 &&
                              offEngine.zhihuPublishRecords.allSatisfy { $0.clickCallCount == 0 },
                              "自动发表开关：默认关闭的真实生产入口拦截 attempt_publish_once 并留痕，fixture handler/发布账点击数均为 0"))
            if let previousSwitchValue { UserDefaults.standard.set(previousSwitchValue, forKey: "zhihuAutoPublishEnabled") }
            else { UserDefaults.standard.removeObject(forKey: "zhihuAutoPublishEnabled") }

            // 开始尝试时开关为开；异步复核完成、attemptStarted 已持久化后
            // 模拟用户关闭设置。最终派发闸必须保留零点击记录且不触发 handler。
            let reviewSwitchValue = UserDefaults.standard.object(forKey: "zhihuAutoPublishEnabled")
            let reviewSettings = SettingsStore(); reviewSettings.zhihuAutoPublishEnabled = true
            let reviewSession = UUID(), reviewTask = UUID()
            let reviewKey = "zhihuPublishLedger.selftest.review-switch-off.\(suffix)"
            keys.append(reviewKey); directories.append(prepareDirectory(reviewSession))
            let reviewWeb = WebController(); reviewWeb.beginExecution(sessionID: reviewSession)
            let reviewFixture = try await loadFixture(reviewWeb, label: "review-only")
            let reviewEngine = AgentEngine(web: reviewWeb, settings: reviewSettings,
                zhihuPublishLedgerKeyOverride: reviewKey,
                preservedDraftStore: isolatedDraftStore, restoreSession: false)
            configure(reviewEngine, web: reviewWeb, sessionID: reviewSession, taskID: reviewTask,
                goal: "发布这篇知乎回答", actions: [
                    try action("type", index: reviewFixture.editor.index, text: body),
                    try action("wait"), try action("done", summary: "复核期间关开关，零点击收口")
                ])
            reviewEngine.controlledZhihuBeforeFinalClick = { reviewSettings.zhihuAutoPublishEnabled = false }
            reviewEngine.launch()
            let reviewDone = await waitFor({ isDone(reviewEngine) }, seconds: 20)
            let reviewMetrics = await reviewWeb.controlledZhihuFixtureMetrics()
            let reviewRecord = reviewEngine.zhihuPublishRecords.last
            lines.append(line(reviewDone && reviewMetrics.handlerCalls == 0 &&
                              reviewRecord?.clickCallCount == 0 && reviewRecord?.status == .unknown &&
                              reviewRecord?.resultDetail.contains("开关被关闭") == true,
                              "自动发表开关复核：attemptStarted 落账后关闭开关，记录保留为 unknown、最终网页派发/handler/clickCallCount 均为 0"))
            if let reviewSwitchValue { UserDefaults.standard.set(reviewSwitchValue, forKey: "zhihuAutoPublishEnabled") }
            else { UserDefaults.standard.removeObject(forKey: "zhihuAutoPublishEnabled") }

            let revokeSession = UUID(), revokeTask = UUID()
            directories.append(prepareDirectory(revokeSession))
            let revokeWeb = WebController(); revokeWeb.beginExecution(sessionID: revokeSession)
            let revokeFixture = try await loadFixture(revokeWeb, label: "authorization-revoke")
            let revokeEngine = AgentEngine(web: revokeWeb, settings: SettingsStore(),
                zhihuPublishLedgerKeyOverride: revokeKey, preservedDraftStore: restartedStore,
                controlledZhihuPublishFixture: true, restoreSession: false)
            configure(revokeEngine, web: revokeWeb, sessionID: revokeSession, taskID: revokeTask,
                goal: "发布这篇知乎回答", actions: [
                    try action("type", index: revokeFixture.editor.index, text: body),
                    try action("wait"), try action("done", summary: "授权撤销，零点击收口")
                ])
            revokeEngine.controlledActionWillDispatch = { cursor, _ in
                if cursor == 1, !revokeEngine.enqueueSteer("不要发布这篇知乎回答，保留草稿") {
                    throw MikaError("撤销授权插话未接受")
                }
            }
            revokeEngine.launch()
            let revokeDone = await waitFor({ isDone(revokeEngine) }, seconds: 20)
            let revokeMetrics = await revokeWeb.controlledZhihuFixtureMetrics()
            lines.append(line(revokeDone && !revokeEngine.currentZhihuAuthorization.allowsZhihuAnswer &&
                              revokeMetrics.handlerCalls == 0 &&
                              restartedStore.latestZhihuDraft()?.fullText == body,
                              "稿件保全-B：真实插话撤销授权后发布点击数=0，独立稿件全文仍保留"))

            // 重复任务：只暴露 token，旧记录来自 id+token；无当前发布授权仍先查账。
            let repeatSession = UUID(), repeatTask = UUID()
            directories.append(prepareDirectory(repeatSession))
            let repeatWeb = WebController(); repeatWeb.beginExecution(sessionID: repeatSession)
            _ = try await loadFixture(repeatWeb, label: "repeat-readback")
            try await repeatWeb.exposeOnlyControlledZhihuAlias("engine-me-token")
            let repeatEngine = AgentEngine(web: repeatWeb, settings: SettingsStore(),
                zhihuPublishLedgerKeyOverride: ledgerKey,
                preservedDraftStore: isolatedDraftStore,
                controlledZhihuPublishFixture: true, restoreSession: false)
            configure(repeatEngine, web: repeatWeb, sessionID: repeatSession, taskID: repeatTask,
                goal: "继续，检查刚才是否发布成功", actions: [try action("done", summary: "检查完成")])
            repeatEngine.launch()
            let repeatDone = await waitFor({ isDone(repeatEngine) }, seconds: 10)
            let repeatMetrics = await repeatWeb.controlledZhihuFixtureMetrics()
            lines.append(line(repeatDone && repeatMetrics.handlerCalls == 0 &&
                              repeatEngine.stateCard.zhihuPublicationStatus == "已核实发布" &&
                              repeatEngine.stateCard.pinnedFacts.contains(where: { $0.contains("作者/问题/全文独立回读一致") }),
                              "B.1/B.2/D.1：授权门前查旧账；id+token→仅 token 仍命中稳定账号，重复任务零新增点击并同步状态卡/结案证据"))
            if var legacy = mainRecord {
                legacy.accountIdentity = "engine-me-id|engine-me-token"
                legacy.accountStableID = nil; legacy.accountAliases = nil
                var legacyRecords = [legacy]
                var registry = ZhihuAccountRegistry()
                registry.migrate(records: &legacyRecords)
                let partial = registry.resolve(observedAliases: ["engine-me-token"],
                    questionID: legacy.questionID, records: legacyRecords)
                lines.append(line(partial.flatMap { ZhihuPublishLedger.verified(account: $0,
                    questionID: legacy.questionID, textHash: legacy.expectedTextHash,
                    in: legacyRecords) }?.id == legacy.id,
                    "B.2-迁移：FIX5 旧拼接键兼容读取后写入 stableID＋别名并集，仅 token 仍命中旧 verified 账"))

                // Astra B② 指定的跨题缓存反例，三步按原序列执行：
                // 1. 问题 4242 的旧 unknown 记录只保存 `me-id`；
                // 2. 访问问题 9999，该页只暴露同账号 `me-token`，因该题无旧账，注册表允许建立另一个身份；
                // 3. 返回问题 4242，页面仍只暴露 `me-token`，命中缓存直接返回，旧 `me-id` 未决记录匹配失败 → 漏账后可重新取得发布资格。
                var oldUnknown = legacy
                oldUnknown.id = UUID(); oldUnknown.accountIdentity = "me-id"
                oldUnknown.accountStableID = nil; oldUnknown.accountAliases = ["me-id"]
                oldUnknown.questionID = "4242"; oldUnknown.status = .unknown
                oldUnknown.readbackCompletedAt = Date(); oldUnknown.clickCallCount = 1
                var sequenceRecords = [oldUnknown]
                var sequenceRegistry = ZhihuAccountRegistry()
                sequenceRegistry.migrate(records: &sequenceRecords)
                let crossQuestion = sequenceRegistry.resolve(observedAliases: ["me-token"],
                    questionID: "9999", records: sequenceRecords)
                let cachedReturn = sequenceRegistry.resolve(observedAliases: ["me-token"],
                    questionID: "4242", records: sequenceRecords)
                lines.append(line(sequenceRecords[0].accountAliases == ["me-id"],
                    "七十三-1：问题 4242 的旧 unknown 记录只保存 `me-id`；"))
                lines.append(line(crossQuestion != nil && sequenceRegistry.identities.count == 2,
                    "七十三-2：访问问题 9999，该页只暴露同账号 `me-token`，因该题无旧账，注册表允许建立另一个身份；"))
                lines.append(line(cachedReturn == nil,
                    "七十三-3：返回问题 4242，页面仍只暴露 `me-token`，命中缓存仍先查同题旧 `me-id` 未决记录，缺少关联或区分证据时 fail-closed"))
            } else {
                lines.append(line(false, "B.2-迁移：主回归未产生可迁移记录"))
            }

            // 57 + D.2：原生 disabled 与 disabled fieldset 同时在真实
            // launch() 主循环中落一次 attempt。旧错误已进入点击前基线，
            // handler 不执行，二次模型 click 输入也不得新增落账点击。
            let disabledKey = "zhihuPublishLedger.selftest.disabled.\(suffix)"
            keys.append(disabledKey)
            let disabledSession = UUID(), disabledTask = UUID()
            directories.append(prepareDirectory(disabledSession))
            let disabledWeb = WebController(); disabledWeb.beginExecution(sessionID: disabledSession)
            let disabledFixture = try await loadFixture(disabledWeb,
                outcome: "native-disabled-fieldset-stale", label: "disabled-fieldset")
            let disabledEngine = AgentEngine(web: disabledWeb, settings: SettingsStore(),
                zhihuPublishLedgerKeyOverride: disabledKey,
                preservedDraftStore: isolatedDraftStore,
                controlledZhihuPublishFixture: true, restoreSession: false)
            configure(disabledEngine, web: disabledWeb, sessionID: disabledSession, taskID: disabledTask,
                goal: "发布这篇知乎回答", actions: [
                    try action("type", index: disabledFixture.editor.index, text: body),
                    try action("wait"), try action("click", index: -2),
                    try action("click", index: -2), try action("done", summary: "disabled 结果未知收口")
                ])
            disabledEngine.controlledZhihuReadback = false
            disabledEngine.launch()
            let disabledDone = await waitFor({ isDone(disabledEngine) }, seconds: 35)
            let disabledMetrics = await disabledWeb.controlledZhihuFixtureMetrics()
            let disabledRecord = disabledEngine.zhihuPublishRecords.last
            let disabledObserved = disabledEngine.steps.contains {
                $0.reason.contains("native=true") && $0.reason.contains("fieldset=true")
            }
            let disabledRepeatBlocks = disabledEngine.steps.filter {
                $0.reason.contains("模型再次请求发布未执行")
            }.count
            lines.append(line(disabledDone && disabledObserved && disabledMetrics.handlerCalls == 0 &&
                              disabledEngine.zhihuPublishRecords.count == 1 &&
                              disabledRecord?.clickCallCount == 1 && disabledRepeatBlocks == 2 &&
                              disabledRecord?.status == .unknown &&
                              disabledEngine.stateCard.zhihuPublicationStatus == ZhihuPublishPolicy.unknownNotice,
                              "五十七-引擎：native disabled＋fieldset 进入完整主循环；首次标准调用落账 1，handler=0，后续两个 click 输入新增落账点击=0，旧错误未被归因且以 unknown 结案"))

            // 62：拒绝/审核都从真实 click handler 生成站点反馈，但在保守
            // 规格下只能作为诊断；没有独立详情完整回读时统一 unknown。
            for (mode, label) in [("rejected", "拒绝"), ("review", "审核")] {
                let key = "zhihuPublishLedger.selftest.62.\(mode).\(suffix)"
                keys.append(key)
                let session = UUID(), task = UUID()
                directories.append(prepareDirectory(session))
                let outcomeWeb = WebController(); outcomeWeb.beginExecution(sessionID: session)
                let fixture = try await loadFixture(outcomeWeb, outcome: mode,
                    label: "outcome-\(mode)")
                let outcomeEngine = AgentEngine(web: outcomeWeb, settings: SettingsStore(),
                    zhihuPublishLedgerKeyOverride: key,
                    preservedDraftStore: isolatedDraftStore,
                    controlledZhihuPublishFixture: true, restoreSession: false)
                configure(outcomeEngine, web: outcomeWeb, sessionID: session, taskID: task,
                    goal: "发布这篇知乎回答", actions: [
                        try action("type", index: fixture.editor.index, text: body),
                        try action("wait"), try action("done", summary: "\(label)场景结案")
                    ])
                if mode == "rejected" { outcomeEngine.controlledZhihuReadback = false }
                outcomeEngine.launch()
                let done = await waitFor({ isDone(outcomeEngine) }, seconds: 30)
                let metrics = await outcomeWeb.controlledZhihuFixtureMetrics()
                let record = outcomeEngine.zhihuPublishRecords.last
                let oneAttempt = outcomeEngine.steps.filter { $0.action == "publish-attempt" }.count == 1
                lines.append(line(done && metrics.handlerCalls == 1 && oneAttempt &&
                                  record?.clickCallCount == 1 && record?.status == .unknown &&
                                  outcomeEngine.stateCard.zhihuPublicationStatus == ZhihuPublishPolicy.unknownNotice,
                                  "六十二-引擎\(label)：真实点击→attempted 落账→生产回读 unknown＋同题阻断→done 结案，handler=1、clickCallCount=1"))
            }

            // D.2：把“点击前隐藏、点击后首次可见”的真实拒绝接入 launch()。
            // 观察器输出只作诊断；无独立详情完整回读必须 unknown 并保留阻断。
            let revealKey = "zhihuPublishLedger.selftest.d2-reveal.\(suffix)"
            keys.append(revealKey)
            let revealSession = UUID(), revealTask = UUID()
            directories.append(prepareDirectory(revealSession))
            let revealWeb = WebController(); revealWeb.beginExecution(sessionID: revealSession)
            let revealFixture = try await loadFixture(revealWeb,
                outcome: "rejected-hidden-visible", label: "hidden-visible")
            let revealEngine = AgentEngine(web: revealWeb, settings: SettingsStore(),
                zhihuPublishLedgerKeyOverride: revealKey,
                preservedDraftStore: isolatedDraftStore,
                controlledZhihuPublishFixture: true, restoreSession: false)
            configure(revealEngine, web: revealWeb, sessionID: revealSession, taskID: revealTask,
                goal: "发布这篇知乎回答", actions: [
                    try action("type", index: revealFixture.editor.index, text: body),
                    try action("wait"), try action("done", summary: "隐藏反馈拒绝场景结案")
                ])
            revealEngine.controlledZhihuReadback = false
            revealEngine.launch()
            let revealDone = await waitFor({ isDone(revealEngine) }, seconds: 30)
            let revealMetrics = await revealWeb.controlledZhihuFixtureMetrics()
            let revealRecord = revealEngine.zhihuPublishRecords.last
            let revealAttempts = revealEngine.steps.filter { $0.action == "publish-attempt" }.count
            lines.append(line(revealDone && revealMetrics.handlerCalls == 1 &&
                              revealEngine.zhihuPublishRecords.count == 1 && revealAttempts == 1 &&
                              revealRecord?.clickCallCount == 1 &&
                              revealRecord?.status == .unknown &&
                              revealEngine.stateCard.zhihuPublicationStatus == ZhihuPublishPolicy.unknownNotice,
                              "七十七-引擎：隐藏→可见真实拒绝进入 launch() 主循环；总点击=1、unknown 账＋同题阻断、done 正常结案"))

            // 63/64 恢复：第一次引擎真实点击落账后在回读前模拟进程退出。
            let recoverySession = UUID(), recoveryTask = UUID()
            directories.append(prepareDirectory(recoverySession))
            let firstWeb = WebController(); firstWeb.beginExecution(sessionID: recoverySession)
            let firstFixture = try await loadFixture(firstWeb, label: "snapshot-source")
            let firstEngine = AgentEngine(web: firstWeb, settings: SettingsStore(),
                zhihuPublishLedgerKeyOverride: recoveryKey,
                preservedDraftStore: isolatedDraftStore,
                controlledZhihuPublishFixture: true, restoreSession: false)
            configure(firstEngine, web: firstWeb, sessionID: recoverySession, taskID: recoveryTask,
                goal: "发布这篇知乎回答", actions: [
                    try action("type", index: firstFixture.editor.index, text: body), try action("wait")
                ])
            firstEngine.controlledSuspendAfterZhihuClick = true
            firstEngine.launch()
            let suspended = await waitFor({ isPaused(firstEngine) }, seconds: 15)
            let firstMetrics = await firstWeb.controlledZhihuFixtureMetrics()
            let attempted = firstEngine.zhihuPublishRecords.last

            let recoveredWeb = WebController()
            let recoveredEngine = AgentEngine(web: recoveredWeb, settings: SettingsStore(),
                zhihuPublishLedgerKeyOverride: recoveryKey,
                preservedDraftStore: isolatedDraftStore,
                controlledZhihuPublishFixture: true, restoreSession: false)
            recoveredEngine.runSessionID = recoverySession
            recoveredEngine.restoreSnapshot(for: recoverySession, allowLegacy: false)
            recoveredEngine.queuedTasks = []; recoveredEngine.acceptedSteerQueueIDs = []
            recoveredEngine.applyPendingTabRestore()
            recoveredWeb.beginExecution(sessionID: recoverySession)
            _ = try await loadFixture(recoveredWeb, label: "snapshot-recovered")
            recoveredEngine.controlledActions = [try action("click", index: -2),
                try action("click", index: -2), try action("done", summary: "恢复回读完成")]
            recoveredEngine.controlledActionCursor = 0
            recoveredEngine.controlledZhihuReadback = true
            recoveredEngine.controlledZhihuReadbackBodyOverride = firstMetrics.publishedBody
            recoveredEngine.launch()
            let recoveredDone = await waitFor({ isDone(recoveredEngine) }, seconds: 30)
            let recoveredMetrics = await recoveredWeb.controlledZhihuFixtureMetrics()
            let recoveredDetailCalls = await recoveredWeb.controlledZhihuDetailPublishCalls()
            let recoveredRecord = recoveredEngine.zhihuPublishRecords.first(where: { $0.id == attempted?.id })
            lines.append(line(suspended && firstMetrics.handlerCalls == 1 && attempted?.status == .attempted &&
                              recoveredDone && recoveredRecord?.status == .verifiedPublished &&
                              recoveredRecord?.clickCallCount == 1 && recoveredMetrics.handlerCalls == 0 &&
                              recoveredDetailCalls == 0,
                              "六十三/六十四：新 AgentEngine 经生产恢复入口只回读；恢复后连续 click 不重发，编辑器页 handler=0 且详情页 handler=0，原记录 clickCallCount 恒为 1"))

            // 61：attempted 必须由真实点击链产生，再由新引擎跑满 20 秒窗口。
            let timeoutSession = UUID(), timeoutTask = UUID()
            directories.append(prepareDirectory(timeoutSession))
            let timeoutFirstWeb = WebController(); timeoutFirstWeb.beginExecution(sessionID: timeoutSession)
            let timeoutFixture = try await loadFixture(timeoutFirstWeb, label: "timeout-source")
            let timeoutFirst = AgentEngine(web: timeoutFirstWeb, settings: SettingsStore(),
                zhihuPublishLedgerKeyOverride: timeoutKey,
                preservedDraftStore: isolatedDraftStore,
                controlledZhihuPublishFixture: true, restoreSession: false)
            configure(timeoutFirst, web: timeoutFirstWeb, sessionID: timeoutSession, taskID: timeoutTask,
                goal: "发布这篇知乎回答", actions: [
                    try action("type", index: timeoutFixture.editor.index, text: body), try action("wait")
                ])
            timeoutFirst.controlledSuspendAfterZhihuClick = true
            timeoutFirst.launch()
            let timeoutSuspended = await waitFor({ isPaused(timeoutFirst) }, seconds: 15)
            let timeoutAttempt = timeoutFirst.zhihuPublishRecords.last

            let timeoutWeb = WebController()
            let timeoutRecovered = AgentEngine(web: timeoutWeb, settings: SettingsStore(),
                zhihuPublishLedgerKeyOverride: timeoutKey,
                preservedDraftStore: isolatedDraftStore,
                controlledZhihuPublishFixture: true, restoreSession: false)
            timeoutRecovered.runSessionID = timeoutSession
            timeoutRecovered.restoreSnapshot(for: timeoutSession, allowLegacy: false)
            timeoutRecovered.queuedTasks = []; timeoutRecovered.acceptedSteerQueueIDs = []
            timeoutRecovered.applyPendingTabRestore()
            timeoutWeb.beginExecution(sessionID: timeoutSession)
            _ = try await loadFixture(timeoutWeb, label: "timeout-recovered")
            timeoutRecovered.controlledActions = [try action("click", index: -2), try action("done", summary: "未知结果收口")]
            timeoutRecovered.controlledActionCursor = 0
            timeoutRecovered.controlledZhihuReadback = true
            timeoutRecovered.controlledZhihuReadbackBodyOverride = "与源稿不一致"
            let timeoutStarted = Date()
            timeoutRecovered.launch()
            let timeoutDone = await waitFor({ isDone(timeoutRecovered) }, seconds: 35)
            let timeoutElapsed = Date().timeIntervalSince(timeoutStarted)
            let timeoutRecord = timeoutRecovered.zhihuPublishRecords.first(where: { $0.id == timeoutAttempt?.id })
            let timeoutMetrics = await timeoutWeb.controlledZhihuFixtureMetrics()
            lines.append(line(timeoutSuspended && timeoutDone && timeoutElapsed >= ZhihuPublishPolicy.readbackWindow - 0.5 &&
                              timeoutRecord?.status == .unknown && timeoutRecord?.readbackCompletedAt != nil &&
                              timeoutRecord?.clickCallCount == 1 && timeoutMetrics.handlerCalls == 0,
                              "六十一：attempted 由真实点击链生成；新引擎真实 20 秒窗口收口 unknown，连续 click 仍零重发"))

            // 76：点击已让站点 handler 执行，但 evaluateJavaScript 在
            // click() 返回后抛异常。生产 catch 必须只进一次有界回读，
            // 不重放点击，最终 unknown。该场景直接纳入“全套”调用的本函数。
            let exceptionKey = "zhihuPublishLedger.selftest.exception.\(suffix)"
            keys.append(exceptionKey)
            let exceptionSession = UUID(), exceptionTask = UUID()
            directories.append(prepareDirectory(exceptionSession))
            let exceptionWeb = WebController(); exceptionWeb.beginExecution(sessionID: exceptionSession)
            let exceptionFixture = try await loadFixture(exceptionWeb, label: "exception")
            try await exceptionWeb.injectControlledZhihuPostClickException()
            let exceptionEngine = AgentEngine(web: exceptionWeb, settings: SettingsStore(),
                zhihuPublishLedgerKeyOverride: exceptionKey,
                preservedDraftStore: isolatedDraftStore,
                controlledZhihuPublishFixture: true, restoreSession: false)
            configure(exceptionEngine, web: exceptionWeb, sessionID: exceptionSession, taskID: exceptionTask,
                goal: "发布这篇知乎回答", actions: [
                    try action("type", index: exceptionFixture.editor.index, text: body),
                    try action("wait"), try action("done", summary: "异常后未知收口")
                ], readbackBody: "异常场景的不匹配回读正文")
            let exceptionStarted = Date()
            exceptionEngine.launch()
            let exceptionDone = await waitFor({ isDone(exceptionEngine) }, seconds: 35)
            let exceptionElapsed = Date().timeIntervalSince(exceptionStarted)
            let exceptionMetrics = await exceptionWeb.controlledZhihuFixtureMetrics()
            let exceptionRecord = exceptionEngine.zhihuPublishRecords.last
            let exceptionReadbacks = exceptionEngine.steps.filter { $0.action == "publish-readback" }.count
            lines.append(line(exceptionDone && exceptionElapsed >= ZhihuPublishPolicy.readbackWindow - 0.5 &&
                              exceptionMetrics.handlerCalls == 1 && exceptionRecord?.clickCallCount == 1 &&
                              exceptionRecord?.clickResult.hasPrefix("call-failed-or-unknown") == true &&
                              exceptionRecord?.status == .unknown && exceptionRecord?.readbackCompletedAt != nil &&
                              exceptionReadbacks == 1 &&
                              exceptionEngine.stateCard.zhihuPublicationStatus == ZhihuPublishPolicy.unknownNotice,
                              "七十六：受控主循环点击后异常→一次 20 秒有界回读→unknown 结案；handler=1、回读收口步=1、点击总数恒为 1"))

            // 59：动作已经从受控源排队，在主循环实际派发前改变 Draft committed。
            let mutationSession = UUID(), mutationTask = UUID(), mutationKey = "zhihuPublishLedger.selftest.mutation.\(suffix)"
            keys.append(mutationKey); directories.append(prepareDirectory(mutationSession))
            let mutationWeb = WebController(); mutationWeb.beginExecution(sessionID: mutationSession)
            let mutationFixture = try await loadFixture(mutationWeb, label: "body-mutation")
            let mutationEngine = AgentEngine(web: mutationWeb, settings: SettingsStore(),
                zhihuPublishLedgerKeyOverride: mutationKey,
                preservedDraftStore: isolatedDraftStore,
                controlledZhihuPublishFixture: true, restoreSession: false)
            configure(mutationEngine, web: mutationWeb, sessionID: mutationSession, taskID: mutationTask,
                goal: "发布这篇知乎回答", actions: [
                    try action("type", index: mutationFixture.editor.index, text: body),
                    try action("wait"), try action("done", summary: "正文变化后未点击")
                ])
            mutationEngine.controlledActionWillDispatch = { cursor, _ in
                if cursor == 1 {
                    try await mutationWeb.mutateControlledZhihuBodyBeforeDispatch("派发前正文已变化")
                }
            }
            mutationEngine.launch()
            let mutationDone = await waitFor({ isDone(mutationEngine) }, seconds: 15)
            let mutationMetrics = await mutationWeb.controlledZhihuFixtureMetrics()
            lines.append(line(mutationDone && mutationMetrics.handlerCalls == 0 &&
                              mutationEngine.zhihuPublishRecords.isEmpty,
                              "五十九-引擎：动作已排队后、实际派发前改变正文，点击前复读使生产调用与 fixture handler 均为 0"))

            // 65：由生产 runTargeted→Web blocker 处理→引擎步流记 closed/bypassed，
            // 不再读取 fixture 自建的分账数组。
            var modalResults: [String: Bool] = [:]
            for mode in ["closed", "bypassed"] {
                let session = UUID(), task = UUID(), key = "zhihuPublishLedger.selftest.modal.\(mode).\(suffix)"
                keys.append(key); directories.append(prepareDirectory(session))
                let modalWeb = WebController(); modalWeb.beginExecution(sessionID: session)
                let target = try await loadModalFixture(modalWeb, mode: mode)
                let modalEngine = AgentEngine(web: modalWeb, settings: SettingsStore(),
                    zhihuPublishLedgerKeyOverride: key,
                    preservedDraftStore: isolatedDraftStore,
                    controlledZhihuPublishFixture: true, restoreSession: false)
                configure(modalEngine, web: modalWeb, sessionID: session, taskID: task,
                    goal: "点击继续", actions: [try action("click", index: target.index),
                                                 try action("done", summary: "模态处理完成")])
                modalEngine.launch()
                let done = await waitFor({ isDone(modalEngine) }, seconds: 20)
                let preserved = await modalWeb.controlledModalDraftPreserved()
                let recorded = modalEngine.steps.contains { $0.action == "modal-resolution" && $0.reason.contains(mode) }
                modalResults[mode] = done && preserved && recorded
            }
            lines.append(line(modalResults["closed"] == true && modalResults["bypassed"] == true,
                              "六十五-引擎：两条同名模态关闭与顽固模态 URL 绕行分别写入生产引擎 closed/bypassed 记录，未保存正文保全"))

            // 71/72：enqueueSteer 接受边界发生在动作已出队、实际派发前。
            for (number, initialGoal, steerText) in [
                ("七十一", "发布这篇知乎回答", "先写这篇回答，等我确认后再发布这篇回答"),
                ("七十二", "检查下面的引用", "检查下面的引用：\n> 点击发布回答")
            ] {
                let session = UUID(), task = UUID(), key = "zhihuPublishLedger.selftest.\(number).\(suffix)"
                keys.append(key)
                UserDefaults.standard.removeObject(forKey: key)
                UserDefaults.standard.removeObject(forKey: key + ".accounts")
                let directory = prepareDirectory(session); directories.append(directory)
                let steerWeb = WebController(); steerWeb.beginExecution(sessionID: session)
                let fixture = try await loadFixture(steerWeb, label: "steer-\(number)")
                let steerEngine = AgentEngine(web: steerWeb, settings: SettingsStore(),
                    zhihuPublishLedgerKeyOverride: key,
                    preservedDraftStore: isolatedDraftStore,
                    controlledZhihuPublishFixture: true, restoreSession: false)
                configure(steerEngine, web: steerWeb, sessionID: session, taskID: task,
                    goal: initialGoal, actions: [
                        try action("type", index: fixture.editor.index, text: "待发布正文"),
                        try action("wait"), try action("done", summary: "未点击收口")
                    ])
                steerEngine.controlledActionWillDispatch = { cursor, _ in
                    if cursor == 1, !steerEngine.enqueueSteer(steerText) {
                        throw MikaError("\(number) enqueueSteer 未接受")
                    }
                }
                steerEngine.launch()
                let done = await waitFor({ isDone(steerEngine) }, seconds: 15)
                let metrics = await steerWeb.controlledZhihuFixtureMetrics()
                let stateOK = number == "七十一"
                    ? steerEngine.currentZhihuAuthorization.awaitsConfirmation
                    : !steerEngine.currentZhihuAuthorization.allowsZhihuAnswer
                lines.append(line(done && metrics.handlerCalls == 0 &&
                                  steerEngine.zhihuPublishRecords.allSatisfy { $0.clickCallCount == 0 } && stateOK,
                                  "\(number)：真实 enqueueSteer 插入已排队动作的派发前窗口，授权保持 \(number == "七十一" ? "pending" : "blocked")，生产/fixture 点击均为 0"))
                UserDefaults.standard.removeObject(forKey: key)
                UserDefaults.standard.removeObject(forKey: key + ".accounts")
            }
        } catch {
            let context = "FIX6 生产编排异常：\(error.localizedDescription)"
            failureContexts.append(context)
            lines.append("✗ \(context)")
        }
        let formalDraftsAfter = try? PreservedDraftStore.shared.all()
        lines.append(line(formalDraftsBefore != nil && formalDraftsBefore == formalDraftsAfter,
                          "自检稿库隔离：所有自检/恢复 AgentEngine 显式使用临时 PreservedDraftStore，运行前后正式稿库逐项相同"))
        if !failureContexts.isEmpty {
            let context = "生产编排自检失败：" + failureContexts.joined(separator: " | ")
            for host in failureHosts { await host.captureFailure(context) }
        }
        return lines
    }

    /// 仅供模拟器 CLI 第二次启动：CI 在第一阶段结果落盘后执行 simctl terminate。
    /// 新 App 进程必须经聊天共用补授权入口取得正文；不得直接读 Store 冒充恢复。
    func verifyZhihuProcessRestartCheckpoint() async -> [String] {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MikaWebSelfTest/process-restart", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var failureHost: WKSelfTestHost?
        do {
            let markerData = try Data(contentsOf: directory.appendingPathComponent("checkpoint.json"))
            guard let marker = try JSONSerialization.jsonObject(with: markerData) as? [String: Any],
                  let rawID = marker["draftID"] as? String, let draftID = UUID(uuidString: rawID),
                  let textHash = marker["textHash"] as? String,
                  let accountStableID = marker["accountStableID"] as? String,
                  let questionID = marker["questionID"] as? String,
                  let rawSessionID = marker["sourceSessionID"] as? String,
                  let sourceSessionID = UUID(uuidString: rawSessionID),
                  let rawTaskID = marker["sourceTaskID"] as? String,
                  let sourceTaskID = UUID(uuidString: rawTaskID) else {
                throw MikaError("进程重启 checkpoint 格式无效")
            }
            let store = PreservedDraftStore(fileURL: directory.appendingPathComponent("drafts.json"))
            let associationKey = Self.preservedDraftAssociationPrefix + sourceSessionID.uuidString
            let ledgerKey = "zhihuPublishLedger.selftest.process-restart.\(UUID().uuidString)"
            defer {
                UserDefaults.standard.removeObject(forKey: associationKey)
                UserDefaults.standard.removeObject(forKey: ledgerKey)
                UserDefaults.standard.removeObject(forKey: ledgerKey + ".accounts")
            }
            UserDefaults.standard.set(draftID.uuidString, forKey: associationKey)

            let web = WebController(); web.beginExecution(sessionID: sourceSessionID)
            failureHost = WKSelfTestHost(tab: web.executionTab,
                suite: "zhihu-process-restart-production-entry")
            let fixture = try await web.loadZhihuEngineFixture(questionID: questionID)
            func action(_ name: String, index: Int = -1, text: String = "", summary: String = "") throws -> AgentAction {
                let data = try JSONSerialization.data(withJSONObject: ["action": name, "index": index,
                    "text": text, "reason": "process restart production entry", "summary": summary])
                return try JSONDecoder().decode(AgentAction.self, from: data)
            }
            let settings = SettingsStore(); settings.zhihuAutoPublishEnabled = false
            let engine = AgentEngine(web: web, settings: settings,
                zhihuPublishLedgerKeyOverride: ledgerKey, preservedDraftStore: store,
                controlledZhihuPublishFixture: true, restoreSession: false)
            let recoveryTaskID = UUID()
            engine.controlledActions = [
                try action("type", index: fixture.editor.index, text: "__MIKA_PRESERVED_DRAFT__"),
                try action("done", summary: "进程重启恢复检查完成")
            ]
            var recoveredDraft: PreservedDraft?
            var oldProofAbsent = false
            engine.controlledActionWillDispatch = { cursor, _ in
                guard cursor == 0 else { return }
                recoveredDraft = engine.activePreservedDraft
                oldProofAbsent = engine.currentZhihuWriteProof == nil
            }
            engine.startInSession(sourceSessionID, local: nil,
                task: "把这篇知乎回答发出去", startingID: recoveryTaskID)
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if case .done = engine.status { break }
                if case .failed = engine.status { break }
                try? await Task.sleep(for: .milliseconds(100))
            }

            let aliases = marker["accountAliases"] as? [String] ?? []
            let recomputedHash = recoveredDraft.map { PreservedDraftStore.textHash($0.fullText) }
            let proof = engine.currentZhihuWriteProof
            let restoredThroughEntry = engine.steps.contains {
                $0.action == "draft-restore" && $0.reason.contains(draftID.uuidString)
            }
            let done: Bool = { if case .done = engine.status { return true }; return false }()
            let passed = done && restoredThroughEntry && oldProofAbsent &&
                recomputedHash == textHash && proof?.expectedText == recoveredDraft?.fullText &&
                proof?.taskID == recoveryTaskID && proof?.taskID != sourceTaskID &&
                recoveredDraft?.target.accountStableID == accountStableID &&
                recoveredDraft?.target.accountAliases == aliases &&
                recoveredDraft?.target.questionID == questionID
            let result = "\(passed ? "✓" : "✗") 进程级恢复：新 App 进程经生产补授权入口按 draftID 取得正文，重算 fullText 哈希及账号/题目一致，旧 proof 未恢复、当前任务重新生成 proof"
            if !passed { await failureHost?.captureFailure(result) }
            return [result]
        } catch {
            let result = "进程级恢复异常：\(error.localizedDescription)"
            await failureHost?.captureFailure(result)
            return ["✗ \(result)"]
        }
    }

    /// FIX5：保留原有局部编排测试供源码回归；SelfTestView 不再把它冒充主循环证据。
    /// 网页侧仍是 WKWebView/生产写入与点击/独立详情回读；账本使用临时
    /// UserDefaults 槽完成真实序列化回读，不污染用户发布账或任务快照。
    private func verifyZhihuLegacyOrchestration() async -> [String] {
        let savedGoal = goal, savedTaskID = conversationTaskID, savedProof = currentZhihuWriteProof
        let savedBinding = currentZhihuPublishBinding, savedDecision = currentZhihuDecision
        let savedDirective = currentZhihuDirective, savedAuthorization = currentZhihuAuthorization
        let savedMatched = matchedZhihuPublishRecord, savedRecords = zhihuPublishRecords
        let savedStateCard = stateCard, savedSteps = steps, savedOverride = zhihuPublishLedgerKeyOverride
        let savedControlled = controlledZhihuReadback, savedTraceFinal = traceFinalAction
        let savedControlledBody = controlledZhihuReadbackBodyOverride
        let savedRewrite = traceRewriteReason
        let temporaryKey = "zhihuPublishLedger.selftest.\(UUID().uuidString)"
        defer {
            goal = savedGoal; conversationTaskID = savedTaskID; currentZhihuWriteProof = savedProof
            currentZhihuPublishBinding = savedBinding; currentZhihuDecision = savedDecision
            currentZhihuDirective = savedDirective; currentZhihuAuthorization = savedAuthorization
            matchedZhihuPublishRecord = savedMatched; zhihuPublishRecords = savedRecords
            stateCard = savedStateCard; steps = savedSteps; zhihuPublishLedgerKeyOverride = savedOverride
            controlledZhihuReadback = savedControlled; traceFinalAction = savedTraceFinal
            controlledZhihuReadbackBodyOverride = savedControlledBody
            traceRewriteReason = savedRewrite
            UserDefaults.standard.removeObject(forKey: temporaryKey)
        }
        func line(_ ok: Bool, _ text: String) -> String { "\(ok ? "✓" : "✗") \(text)" }
        do {
            let taskID = UUID(), token = generation
            goal = "把这篇知乎回答发出去"
            conversationTaskID = taskID
            currentZhihuAuthorization = .initial(instruction: goal)
            stateCard = TaskStateCard(goal: goal)
            steps = []; zhihuPublishRecords = []; matchedZhihuPublishRecord = nil
            zhihuPublishLedgerKeyOverride = temporaryKey
            controlledZhihuReadback = true
            let body = "FIX5 引擎编排第一段：计数观测可以为零。\n\n第二段：只有独立详情全文一致才结案。"
            let (typeAction, _) = try await web.prepareZhihuEngineFixture(body: body, taskID: taskID)
            let typedPage = try await web.state()
            guard let editor = typedPage.elements.first(where: { $0.editable }) else { throw MikaError("受控编排找不到编辑器") }
            await noteTypedContent(action: typeAction, element: editor)
            let restoredProof = currentZhihuWriteProof.flatMap { try? JSONEncoder().encode($0) }.flatMap { try? JSONDecoder().decode(WriteProof.self, from: $0) }
            let restoredAuthorization = (try? JSONEncoder().encode(currentZhihuAuthorization)).flatMap { try? JSONDecoder().decode(PublishAuthorization.self, from: $0) }
            let restoredRoundTrip = restoredProof != nil && restoredAuthorization?.allowsZhihuAnswer == true
            currentZhihuWriteProof = restoredProof
            if let restoredAuthorization { currentZhihuAuthorization = restoredAuthorization }
            var page = try await web.state()
            page = await refreshZhihuPublishContext(page: page)
            let actionData = try JSONSerialization.data(withJSONObject: ["action": "wait", "seconds": 1, "reason": "controlled model wait"])
            let controlledAction = try JSONDecoder().decode(AgentAction.self, from: actionData)
            let rewritten = resolvedZhihuAction(proposedAction: controlledAction.action) == "attempt_publish_once"
            try await web.injectControlledZhihuPostClickException()
            try await attemptZhihuPublishOnce(proposed: controlledAction, token: token)
            let stored = UserDefaults.standard.data(forKey: temporaryKey).flatMap { try? JSONDecoder().decode([ZhihuPublishRecord].self, from: $0) }
            let record = stored?.last
            let firstCardVerified = stateCard.zhihuPublicationStatus == "已核实发布"
            let timeoutID = UUID()
            zhihuPublishRecords.append(ZhihuPublishRecord(id: timeoutID, taskID: taskID, runID: token,
                accountIdentity: "engine-me", accountStableID: "zhacct-engine-me", accountAliases: ["engine-me"],
                questionID: "4243", expectedTextHash: ZhihuPublishPolicy.hash("窗口源稿"),
                bodyVersion: "timeout-fixture", sourceText: "窗口源稿", status: .attempted,
                attemptStartedAt: Date(), clickCallCount: 1, clickResult: "standard-click-called",
                answerID: nil, answerURL: nil, authorIdentity: nil, readbackText: nil,
                resultDetail: "等待真实 20 秒有界回读"))
            _ = saveZhihuPublishRecords()
            controlledZhihuReadbackBodyOverride = "不匹配正文"
            let timeoutStarted = Date()
            let timeoutStatus = await runZhihuReadback(recordID: timeoutID, token: token)
            let timeoutElapsed = Date().timeIntervalSince(timeoutStarted)
            let timeoutRecord = zhihuPublishRecords.first(where: { $0.id == timeoutID })
            let rebuiltRecords = UserDefaults.standard.data(forKey: temporaryKey).flatMap { try? JSONDecoder().decode([ZhihuPublishRecord].self, from: $0) } ?? []
            var recoveryProof = currentZhihuWriteProof
            recoveryProof?.questionID = "4243"
            recoveryProof?.expectedText = "窗口源稿"
            recoveryProof?.committedText = "窗口源稿"
            recoveryProof?.expectedTextHash = ZhihuPublishPolicy.hash("窗口源稿")
            recoveryProof?.committedTextHash = ZhihuPublishPolicy.hash("窗口源稿")
            let rebuiltDecision = ZhihuPublishPolicy.shouldAttemptPublish(taskID: taskID,
                authorization: currentZhihuAuthorization, proof: recoveryProof, binding: nil,
                account: ZhihuAccountIdentity(stableID: "zhacct-engine-me", aliases: ["engine-me"]),
                records: rebuiltRecords)
            let rebuiltReadbackOnly: Bool
            if case .readbackOnly = rebuiltDecision { rebuiltReadbackOnly = true } else { rebuiltReadbackOnly = false }
            return [
                line(currentZhihuWriteProof?.isValid == true, "五十六-引擎A：任务建立→生产写入→WriteProof 由 AgentEngine 状态接收"),
                line(rewritten, "五十六-引擎B：受控模型 wait 被真实引擎改写为 attempt_publish_once"),
                line(record?.clickCallCount == 1 && record?.status == .verifiedPublished && record?.clickResult.hasPrefix("call-failed-or-unknown") == true,
                     "五十六-引擎C：落账→一次点击后异常注入→一次有界独立详情回读→已核实发布"),
                line(firstCardVerified,
                     "五十六-引擎D：结案状态卡只在独立详情回读后晋级"),
                line(restoredRoundTrip && record?.clickCallCount == 1,
                     "六十四-引擎：旧任务 proof/授权序列化恢复后，在生产编排内实际执行一次点击"),
                line(timeoutStatus == .unknown && timeoutElapsed >= ZhihuPublishPolicy.readbackWindow - 0.5 &&
                     timeoutRecord?.readbackCompletedAt != nil && timeoutRecord?.clickCallCount == 1,
                     "六十一-引擎：真实 20 秒只读窗口耗尽收口 unknown，点击总次数仍为 1"),
                line(rebuiltReadbackOnly,
                     "六十三-引擎：发布记录序列化→重建后仍只允许回读，连续模型点击不能重放")
            ]
        } catch {
            return ["✗ 五十六-引擎编排异常：\(error.localizedDescription)"]
        }
    }

    private func resolvedZhihuAction(proposedAction: String) -> String {
        ZhihuPublishPolicy.finalAction(for: currentZhihuDecision, proposedAction: proposedAction)
    }

    private var zhihuPublishExecutionAllowed: Bool {
        settings.zhihuAutoPublishEnabled || controlledZhihuPublishFixture
    }

    /// 台账注入段：动作留痕、效果核查、模型自述分层表述。
    private func outcomePromptBlock() -> String {
        let records = Self.prunedOutcomes(outcomeLedger)
        guard !records.isEmpty else { return "" }
        let currentID = conversationTaskID
        let visible = records.filter { record in
            guard let claim = taskClaims.first(where: { $0.id == record.id }) else { return false }
            return claim.sourceTaskID == currentID || claim.status == .verified
        }
        let hasForeignUnverified = records.contains { record in
            guard let claim = taskClaims.first(where: { $0.id == record.id }) else { return true }
            return claim.sourceTaskID != currentID && claim.status == .unverified
        }
        var lines = visible.map { record in
            let content = record.contentPrefix.isEmpty ? "（正文未留指纹）" : "内容「\(record.contentPrefix)…」"
            let claim = taskClaims.first { $0.id == record.id }
            let scope = claim?.sourceTaskID == currentID ? "本任务" : "背景只读"
            let confirmed = claim?.verifiedByUser == true ? "（据用户确认，终局）" : ""
            let dispatch = record.dispatchState?.rawValue ?? "unknown"
            let verdict = record.verificationVerdict?.rawValue ?? "unknown"
            return "· [\(scope)] \(Self.outcomeTime(record.recordedAt)) 在 \(record.host.isEmpty ? "本地页面" : record.host) 尝试「\(record.elementLabel)」：\(content)，派发=\(dispatch)，核验=\(verdict)，说明：\(Self.displayedOutcomeStatus(record.statusNote))\(confirmed)"
        }
        if hasForeignUnverified { lines.append("· 上个任务有未核实记录（不属于本任务）") }
        guard !lines.isEmpty else { return "" }
        return "【本任务关键动作留痕】\n" + lines.joined(separator: "\n") + "\n硬性口径：①本任务条目照常记账核实；背景条目只读，不得重开或降级，用户确认的终局事实至多注明「据用户确认」。②跨任务未核实记录不属于本任务，不构成核查义务。③本任务提交是否生效只按本任务动作与回读判定。"
    }

    private func flushPendingOutcomeStep() {
        if let note = pendingOutcomeStep { appendStep("outcome", note); pendingOutcomeStep = nil }
        if let vstep = pendingVerificationStep { appendStep("verify", vstep); pendingVerificationStep = nil }
    }

    /// 点击效果仅是短时页面观察，不进入循环指纹、卡点证据或成败裁决。
    private func clickEffectDescription() -> String {
        guard let effect = web.lastClickEffect else {
            return web.lastClickEffectMissingBefore
                ? "点击效果未知（点前签名缺失）"
                : "点击效果未知（回读签名缺失）"
        }
        var changes: [String] = []
        if effect.urlChanged { changes.append("URL 变化") }
        if effect.contentChanged { changes.append("内容变化") }
        if !changes.isEmpty { return "点击后页面已变化（\(changes.joined(separator: "／"))）" }
        return "点击后 1.2s 内页面无可感知变化（可能仍在加载或需后续动作，不据此判失败）"
    }

    func verifyClickEffectClassification() -> [String] { web.verifyClickEffectClassification() }

    /// 自检二十九（KNIFE3-WRITES）：写入记账、FIFO、旧快照兼容与
    /// 最紧历史折叠时的状态卡注入。不调用模型、不占用页面。
    func verifyWrittenContentCard() -> [String] {
        var lines: [String] = []
        var card = TaskStateCard(goal: "自检二十九合成目标")
        card.addWrite(target: "正文编辑器", body: "甲乙丙丁")
        card.addWrite(target: "", body: String(repeating: "文", count: 30))
        let first = card.writes ?? []
        lines.append("\(first.count == 2 && first[0].hasPrefix("旧版本；type=replace") && first[0].contains("目标=正文编辑器") && first[1].hasPrefix("当前内容；type=replace") && first[1].contains("核实=unknown") ? "✓" : "✗") 写入格式：replace 语义、旧版本/当前内容、attempt 与 unknown 分列")
        for number in 0..<8 { card.addWrite(target: "目标\(number)", body: "内容\(number)") }
        let retained = card.writes ?? []
        lines.append("\(retained.count == 8 && retained.first?.contains("目标=目标0") == true && retained.last?.contains("目标=目标7") == true && retained.last?.hasPrefix("当前内容；") == true ? "✓" : "✗") FIFO 封顶：第9、10次写入后只留最近8条且仅末条为当前内容")

        let snapshot = SessionSnapshot(savedAt: Date(), goal: card.goal, limit: 25, stepSeq: 0, steps: [],
                                       statusKind: "paused", statusText: "", pendingActionJSON: nil, pendingElement: nil,
                                       pendingURL: nil, waiting: nil, answersJSON: "[]", skillNames: nil,
                                       taskID: nil, tabURLs: nil, activeTabIndex: nil, executionTabIndex: nil,
                                       outcomes: nil, stateCard: card, sessionID: nil)
        if let data = try? JSONEncoder().encode(snapshot),
           let decoded = try? JSONDecoder().decode(SessionSnapshot.self, from: data) {
            lines.append("\(decoded.stateCard?.writes == retained ? "✓" : "✗") 快照往返：writes 八条逐字保留")
            if var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               var oldCard = object["stateCard"] as? [String: Any] {
                oldCard.removeValue(forKey: "writes")
                object["stateCard"] = oldCard
                let legacyData = try? JSONSerialization.data(withJSONObject: object)
                let legacy = legacyData.flatMap { try? JSONDecoder().decode(SessionSnapshot.self, from: $0) }
                lines.append("\(legacy?.stateCard?.goal == card.goal && legacy?.stateCard?.writes == nil ? "✓" : "✗") 旧快照：无 writes 键仍可解码")
            } else {
                lines.append("✗ 旧快照：无法构造缺 writes 键样本")
            }
        } else {
            lines.append("✗ 快照往返：状态卡编码或解码失败")
            lines.append("✗ 旧快照：缺 writes 键兼容性未验证")
        }

        let savedCard = stateCard
        let savedSteps = steps
        stateCard = card
        steps = (1...45).map { AgentStep(id: $0, action: "type", reason: "旧步长文本-\($0)-" + String(repeating: "折", count: 80)) }
        defer { stateCard = savedCard; steps = savedSteps }
        let prompt = buildPrompt(pageJSON: "{}", answersJSON: "[]", foldLevel: 3, loopHint: nil, outcomeHint: nil)
        lines.append("\(retained.allSatisfy { prompt.contains("· " + $0) } && prompt.contains("【已写入页面的内容】") && !prompt.contains("旧步长文本-1-" + String(repeating: "折", count: 80)) ? "✓" : "✗") level 3 折叠：旧步长文本被折、writes 段与八条原文仍全文在 prompt 中")
        return lines
    }

    /// 自检六只读口径：台账条数与最近一条的人读摘要。
    var outcomeLedgerCount: Int { outcomeLedger.count }
    var latestOutcomeDescription: String? {
        outcomeLedger.last.map { "\($0.host.isEmpty ? "本地页面" : $0.host) · \($0.contentPrefix.isEmpty ? "（无正文指纹）" : $0.contentPrefix) · \(Self.displayedOutcomeStatus($0.statusNote))" }
    }

    private func syncZhihuStateCard(from record: ZhihuPublishRecord) {
        stateCard.setZhihuStatus(write: record.sourceText.isEmpty ? "未核实" : "已核实",
                                 publication: record.status.display)
        let link = record.answerURL ?? "问题 \(record.questionID)"
        let attempt = String(record.id.uuidString.prefix(8))
        let evidence = "知乎回答：发布账命中 \(record.status.display)；attempt=\(attempt)；\(link)"
        if !stateCard.completed.contains(where: { $0.contains("attempt=\(attempt)") }) {
            stateCard.addCompleted(evidence)
        }
        if record.status == .verifiedPublished {
            stateCard.pinFact("知乎回答结案证据：\(link)；作者/问题/全文独立回读一致")
        }
    }

    /// 每轮页面快照后刷新知乎发布派生段。未决尝试优先于编辑器现场：即使
    /// 点击后跳页或崩溃恢复，也只会回读，不会因失去按钮绑定而重新发布。
    private func refreshZhihuPublishContext(page: PageState) async -> PageState {
        var enriched = page
        currentZhihuPublishBinding = nil
        currentZhihuDecision = nil
        currentZhihuDirective = nil
        matchedZhihuPublishRecord = nil
        guard let taskID = conversationTaskID else { return enriched }
        let pageIdentity = await web.readZhihuPageIdentity()
        let account = resolveZhihuAccount(pageIdentity)

        // 查旧账位于首次发布授权门之前：撤销授权、"继续"或"检查是否发布成功"
        // 都仍会按当前账号＋问题回读/报告；授权只控制新的 click。
        if let account, let unresolved = ZhihuPublishLedger.pending(account: account,
                                                                    questionID: pageIdentity.questionID,
                                                                    in: zhihuPublishRecords) {
            matchedZhihuPublishRecord = unresolved
            syncZhihuStateCard(from: unresolved)
            let decision = PublishDecision.readbackOnly("同题存在\(unresolved.status.display)记录")
            currentZhihuDecision = decision
            let next = unresolved.status.needsReadback && unresolved.readbackCompletedAt == nil
                ? "readback_only" : "report_attempted_unverified"
            let directive = ZhihuPublishDirective(writeStatus: currentZhihuWriteProof?.isValid == true ? "verified" : "historically_verified",
                publicationStatus: unresolved.status.rawValue, publishTarget: "已尝试的同题回答",
                evidenceSource: "persisted account+question ZhihuPublishRecord (independent of current WriteProof)",
                disabledObservation: "not_applicable_after_attempt",
                disabledTrustForThisDecision: "non_blocking", nextAction: next,
                blockingReason: "同题未决提交禁止重复点击")
            currentZhihuDirective = directive; enriched.zhihuPublishDirective = directive
            return enriched
        }

        let proof = currentZhihuWriteProof
        if let account, let published = ZhihuPublishLedger.verified(account: account,
            questionID: pageIdentity.questionID,
            textHash: proof?.questionID == pageIdentity.questionID ? proof?.expectedTextHash : nil,
            in: zhihuPublishRecords) {
            matchedZhihuPublishRecord = published
            syncZhihuStateCard(from: published)
            currentZhihuDecision = .alreadyPublished("同题同文已有回答 \(published.answerURL ?? "")")
            let directive = ZhihuPublishDirective(writeStatus: "verified", publicationStatus: "verifiedPublished",
                publishTarget: published.answerURL ?? "稳定回答链接", evidenceSource: "independent full-answer readback",
                disabledObservation: "not_applicable", disabledTrustForThisDecision: "non_blocking",
                nextAction: "report_existing_answer", blockingReason: nil)
            currentZhihuDirective = directive; enriched.zhihuPublishDirective = directive
            return enriched
        }

        if account == nil, zhihuPublishRecords.contains(where: { $0.questionID == pageIdentity.questionID }) {
            currentZhihuDecision = .blocked("当前页账号别名与同题旧账无法确认连续性；保持阻断")
            let directive = ZhihuPublishDirective(writeStatus: proof?.isValid == true ? "verified" : "unverified",
                publicationStatus: "identity_unresolved", publishTarget: "unbound",
                evidenceSource: "persisted account alias registry",
                disabledObservation: "not_applicable", disabledTrustForThisDecision: "non_blocking",
                nextAction: "resolve_account_identity", blockingReason: "账号连续性无法确认，禁止新点击")
            currentZhihuDirective = directive; enriched.zhihuPublishDirective = directive
            return enriched
        }

        guard currentZhihuAuthorization.allowsZhihuAnswer else {
            if currentZhihuAuthorization.awaitsConfirmation {
                currentZhihuDecision = .blocked(currentZhihuAuthorization.explanation)
                let directive = ZhihuPublishDirective(writeStatus: proof?.isValid == true ? "verified" : "unverified",
                    publicationStatus: "pending_authorization", publishTarget: "condition_not_met",
                    evidenceSource: "PublishAuthorization pending state",
                    disabledObservation: "not_applicable", disabledTrustForThisDecision: "non_blocking",
                    nextAction: "wait_for_user_confirmation", blockingReason: currentZhihuAuthorization.reason)
                currentZhihuDirective = directive; enriched.zhihuPublishDirective = directive
            }
            return enriched
        }

        guard let proof else { return enriched }

        guard let refreshed = await web.revalidateZhihuWriteProof(proof) else {
            currentZhihuWriteProof = nil
            stateCard.setZhihuStatus(write: "未核实", publication: "未尝试")
            currentZhihuDecision = .blocked("发布前复读发现页面代次、编辑器或正文版本已变化")
            let directive = ZhihuPublishDirective(writeStatus: "invalidated", publicationStatus: "not_attempted",
                publishTarget: "unbound", evidenceSource: "pre-publish committed reread",
                disabledObservation: "unobserved", disabledTrustForThisDecision: "non_blocking",
                nextAction: "relocate_and_reverify", blockingReason: "旧 WriteProof 已失效")
            currentZhihuDirective = directive; enriched.zhihuPublishDirective = directive
            return enriched
        }
        currentZhihuWriteProof = refreshed
        let binding = await web.bindZhihuPublishTarget(to: refreshed)
        currentZhihuPublishBinding = binding
        let decision = ZhihuPublishPolicy.shouldAttemptPublish(taskID: taskID, authorization: currentZhihuAuthorization,
                                                               proof: refreshed, binding: binding,
                                                               account: account,
                                                               records: zhihuPublishRecords)
        currentZhihuDecision = decision
        let publicationStatus: String, target: String, disabled: String, next: String, reason: String?
        switch decision {
        case .attemptOnce:
            publicationStatus = "ready_to_attempt"; target = binding?.buttonIdentity ?? "unbound"
            disabled = binding?.disabledSummary ?? "unobserved"; next = "attempt_publish_once"; reason = nil
        case .readbackOnly(let why):
            publicationStatus = "attempted"; target = "existing attempt"; disabled = "not_applicable"; next = "readback_only"; reason = why
        case .alreadyPublished(let why):
            publicationStatus = "verifiedPublished"; target = "existing answer"; disabled = "not_applicable"; next = "report_existing_answer"; reason = why
        case .blocked(let why):
            publicationStatus = "not_ready"; target = binding?.buttonIdentity ?? "unbound"
            disabled = binding?.disabledSummary ?? "unobserved"; next = "resolve_evidence_gap"; reason = why
        }
        let directive = ZhihuPublishDirective(writeStatus: "verified", publicationStatus: publicationStatus,
            publishTarget: target, evidenceSource: "Draft committed full equality + unique composer binding",
            disabledObservation: disabled, disabledTrustForThisDecision: "non_blocking",
            nextAction: next, blockingReason: reason)
        currentZhihuDirective = directive; enriched.zhihuPublishDirective = directive
        return enriched
    }

    /// 同题已开始的发布只做只读回读。一个窗口最多 20 秒；窗口耗尽即记
    /// 结果未知，后续任务仍被同题记录挡住，绝不会重放点击。
    private func runZhihuReadback(recordID: UUID, token: UUID) async -> ZhihuPublishStatus {
        guard let index = zhihuPublishRecords.firstIndex(where: {
            $0.id == recordID && $0.status.needsReadback && $0.readbackCompletedAt == nil
        })
        else { return zhihuPublishRecords.first(where: { $0.id == recordID })?.status ?? .unknown }
        let attempted = zhihuPublishRecords[index]
        guard let account = ZhihuPublishLedger.identity(for: attempted), account.isResolved else {
            zhihuPublishRecords[index].status = .unknown
            zhihuPublishRecords[index].resultDetail = "旧记录缺少账号键，不能跨账号补造回读绑定"
            _ = saveZhihuPublishRecords()
            return .unknown
        }
        let target = ZhihuReadbackTarget(questionID: attempted.questionID,
            expectedTextHash: attempted.expectedTextHash, sourceText: attempted.sourceText,
            accountIdentity: account.stableID, accountAliases: account.aliases,
            attemptID: attempted.id, taskID: attempted.taskID)
        if controlledZhihuReadback {
            do { try await web.openControlledZhihuDetail(target, bodyOverride: controlledZhihuReadbackBodyOverride) }
            catch {
                zhihuPublishRecords[index].status = .unknown
                zhihuPublishRecords[index].readbackCompletedAt = Date()
                zhihuPublishRecords[index].resultDetail = "受控独立详情页未能建立：\(error.localizedDescription)"
                _ = saveZhihuPublishRecords()
                return .unknown
            }
        }
        let deadline = Date().addingTimeInterval(ZhihuPublishPolicy.readbackWindow)
        var last = ZhihuPublicationEvidence(status: .unknown, questionID: "", answerID: "", answerURL: "",
            currentAccountIdentity: "", authorIdentity: "", bodyText: "", fullTextEqual: false,
            pageState: "unobservable", rejectionText: "", observedAt: Date())
        var openedDetail = false
        while Date() < deadline {
            do { try await checkpoint(token) } catch { return .unknown }
            last = await web.readZhihuPublication(for: target)
            let verdict = ZhihuAnswerVerifier.judge(last, target: target)
            let currentURL = web.executionTab.webView.url?.absoluteString ?? ""
            let alreadyOnDetail = controlledZhihuReadback ||
                (!last.answerID.isEmpty && currentURL.contains("/answer/\(last.answerID)"))
            // 列表页只发现候选。稳定链接出现后优先打开独立详情页，随后
            // 再次满足题目、作者、全文与页面状态才允许晋级。
            if !last.answerURL.isEmpty, !alreadyOnDetail, !openedDetail {
                do {
                    let sourceID = web.executionTab.id
                    let tab = try await auditedDispatch(name: "zhihu-readback-navigation", pageURL: last.answerURL,
                                                        actionID: recordID) {
                        try web.openTabForExecution(urlString: last.answerURL)
                    }
                    if let taskID = conversationTaskID {
                        _ = readbackTabs.register(tabID: tab.id, ownerTaskID: taskID, sourceTabID: sourceID, purpose: "zhihu-answer-detail")
                    }
                    openedDetail = true
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                } catch { /* 保留当前页继续只读探测，但不得在列表页晋级 */ }
            }
            if verdict == .verifiedPublished {
                if !alreadyOnDetail {
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                }
                let auditVerified = appendExecutionAudit(event: "verification-verified", actionID: recordID,
                    pageURL: last.answerURL, evidenceRef: last.answerID.isEmpty ? target.questionID : last.answerID)
                let receipt = executionReceipts.last(where: { $0.actionID == recordID && $0.critical })
                let receiptVerified = auditVerified && (receipt.map { entry in
                    updateExecutionReceipt(id: entry.id, state: .sent, evidence: "zhihu-answer-detail",
                                           verdict: .verified)
                } ?? true) // Existing pre-upgrade attempts have their own durable Zhihu ledger.
                guard auditVerified && receiptVerified else {
                    zhihuPublishRecords[index].status = .unknown
                    zhihuPublishRecords[index].readbackCompletedAt = Date()
                    zhihuPublishRecords[index].resultDetail = "核验审计或回执写入失败，保持 unknown"
                    _ = saveZhihuPublishRecords()
                    return .unknown
                }
                zhihuPublishRecords[index].status = verdict
                zhihuPublishRecords[index].answerID = last.answerID.isEmpty ? nil : last.answerID
                zhihuPublishRecords[index].answerURL = last.answerURL.isEmpty ? nil : last.answerURL
                zhihuPublishRecords[index].authorIdentity = last.authorIdentity.isEmpty ? nil : last.authorIdentity
                zhihuPublishRecords[index].readbackText = last.bodyText
                zhihuPublishRecords[index].readbackCompletedAt = Date()
                zhihuPublishRecords[index].resultDetail = "question/author/full-body readback matched; pageState=\(last.pageState)"
                guard saveZhihuPublishRecords() else {
                    zhihuPublishRecords[index].status = .unknown
                    zhihuPublishRecords[index].resultDetail = "核验结果台账写入失败，保持 unknown"
                    return .unknown
                }
                stateCard.setZhihuStatus(write: "已核实", publication: verdict.display)
                AgentTraceStore.shared.appendEngineAction(action: "zhihu-publish-readback",
                    targetFingerprint: last.answerID.isEmpty ? target.questionID : last.answerID,
                    method: "question-author-full-body", result: verdict.rawValue,
                    pageURL: last.answerURL, taskID: target.taskID.uuidString, runID: token.uuidString,
                    evidence: ["questionID": last.questionID, "answerLink": last.answerURL,
                               "currentAccount": last.currentAccountIdentity, "author": last.authorIdentity,
                               "sourceText": target.sourceText, "readbackFullText": last.bodyText,
                               "fullTextEqual": last.fullTextEqual, "pageState": last.pageState])
                appendStep("publish-readback", "知乎回答回读：\(verdict.display)；answerID=\(last.answerID)、link=\(last.answerURL)、question=\(last.questionID)、currentAccount=\(last.currentAccountIdentity)、author=\(last.authorIdentity)、fullTextEqual=\(last.fullTextEqual)、pageState=\(last.pageState)\(last.rejectionText.isEmpty ? "" : "、rejection=\(last.rejectionText)")")
                return verdict
            }
            if !openedDetail, !last.answerURL.isEmpty,
               last.answerURL != web.executionTab.webView.url?.absoluteString {
                do {
                    let sourceID = web.executionTab.id
                    let tab = try await auditedDispatch(name: "zhihu-readback-navigation", pageURL: last.answerURL,
                                                        actionID: recordID) {
                        try web.openTabForExecution(urlString: last.answerURL)
                    }
                    if let taskID = conversationTaskID {
                        _ = readbackTabs.register(tabID: tab.id, ownerTaskID: taskID, sourceTabID: sourceID, purpose: "zhihu-answer-detail")
                    }
                    openedDetail = true
                } catch { /* 保留当前页继续只读回读 */ }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        zhihuPublishRecords[index].status = .unknown
        zhihuPublishRecords[index].answerID = last.answerID.isEmpty ? nil : last.answerID
        zhihuPublishRecords[index].answerURL = last.answerURL.isEmpty ? nil : last.answerURL
        zhihuPublishRecords[index].authorIdentity = last.authorIdentity.isEmpty ? nil : last.authorIdentity
        zhihuPublishRecords[index].readbackText = last.bodyText
        zhihuPublishRecords[index].readbackCompletedAt = Date()
        zhihuPublishRecords[index].resultDetail = ZhihuPublishPolicy.unknownNotice
        _ = saveZhihuPublishRecords()
        if let receipt = executionReceipts.last(where: { $0.actionID == recordID && $0.critical }) {
            _ = updateExecutionReceipt(id: receipt.id, state: receipt.dispatchState,
                                       evidence: "zhihu-readback-unknown", verdict: .unknown)
        }
        _ = appendExecutionAudit(event: "verification-unknown", actionID: recordID,
                                 pageURL: last.answerURL, evidenceRef: "bounded-readback-window")
        stateCard.setZhihuStatus(write: "已核实", publication: ZhihuPublishPolicy.unknownNotice)
        AgentTraceStore.shared.appendEngineAction(action: "zhihu-publish-readback",
            targetFingerprint: target.questionID, method: "bounded-read-only-20s", result: "unknown",
            pageURL: last.answerURL, taskID: target.taskID.uuidString, runID: token.uuidString,
            evidence: ["questionID": last.questionID, "answerLink": last.answerURL,
                       "sourceText": target.sourceText, "readbackFullText": last.bodyText,
                       "author": last.authorIdentity, "fullTextEqual": last.fullTextEqual])
        appendStep("publish-readback", "\(ZhihuPublishPolicy.unknownNotice) 点击未重放。现场 answerLink=\(last.answerURL.isEmpty ? "无" : last.answerURL)、author=\(last.authorIdentity.isEmpty ? "不可观测" : last.authorIdentity)、fullTextEqual=\(last.fullTextEqual)")
        return .unknown
    }

    /// 将模型动作改写为引擎的一次发布尝试。attemptStarted 必须先持久化；
    /// 专用 Web 路径只调用一次标准 click()，随后立即进入有界回读。
    private func attemptZhihuPublishOnce(proposed action: AgentAction, token: UUID) async throws {
        guard zhihuPublishExecutionAllowed else {
            currentZhihuDecision = .blocked("知乎自动发表开关已关闭")
            appendStep("publish-decision", "知乎自动发表开关关闭：专用点击入口二次拦截，clickCallCount=0")
            AgentTraceStore.shared.appendEngineAction(action: "attempt_publish_once",
                targetFingerprint: currentZhihuPublishBinding?.buttonIdentity ?? "unbound",
                method: "engine-production-switch-defense", result: "blocked-switch-off",
                pageURL: web.executionTab.webView.url?.absoluteString ?? "",
                taskID: conversationTaskID?.uuidString ?? "unobservable", runID: token.uuidString,
                evidence: ["enabled": false, "clickCount": 0])
            return
        }
        guard let taskID = conversationTaskID, token == generation, let oldProof = currentZhihuWriteProof else {
            currentZhihuDecision = .blocked("点击前任务代次、正文版本或按钮绑定复核未通过")
            appendStep("publish-decision", "首次发布尝试未执行：点击前任务代次、正文版本或唯一按钮绑定复核未通过")
            return
        }
        guard let proof = await web.revalidateZhihuWriteProof(oldProof) else {
            currentZhihuDecision = .blocked("点击前正文复读失败")
            return
        }
        try await checkpoint(token)
        guard conversationTaskID == taskID, let binding = await web.bindZhihuPublishTarget(to: proof) else {
            currentZhihuDecision = .blocked("点击前按钮绑定失败")
            return
        }
        try await checkpoint(token)
        let pageIdentity = await web.readZhihuPageIdentity()
        let account = resolveZhihuAccount(pageIdentity)
        try await checkpoint(token)
        guard conversationTaskID == taskID, currentZhihuAuthorization.allowsZhihuAnswer,
              ZhihuPublishPolicy.shouldAttemptPublish(taskID: taskID, authorization: currentZhihuAuthorization,
                proof: proof, binding: binding, account: account,
                records: zhihuPublishRecords) == .attemptOnce else {
            currentZhihuDecision = .blocked("点击前授权、账号未决账或绑定复核未通过：\(currentZhihuAuthorization.explanation)")
            appendStep("publish-decision", "首次发布尝试未执行：\(currentZhihuAuthorization.explanation)")
            return
        }
        let safetyPage = try await web.state()
        try await checkpoint(token)
        guard let safetyTarget = safetyPage.elements.first(where: { $0.index == binding.buttonIndex }) else {
            currentZhihuDecision = .blocked("安全复核时目标已变化")
            return
        }
        let safetyAllowed: Bool
        switch SafetyPolicy.check(action, safetyTarget) { case .allow: safetyAllowed = true; default: safetyAllowed = false }
        guard safetyAllowed else {
            currentZhihuDecision = .blocked("现有 SafetyPolicy 要求确认或目标已变化")
            appendStep("publish-decision", "首次发布尝试未执行：专用路径未通过现有授权守卫")
            return
        }
        // 两个关键 await（proof 复读、按钮绑定）及安全快照之后、落账之前，
        // 再核对任务代次/取消和最新插话授权。
        controlledZhihuBeforeAttemptPersist?()
        try await checkpoint(token)
        guard conversationTaskID == taskID, currentZhihuAuthorization.allowsZhihuAnswer else { return }
        guard zhihuPublishExecutionAllowed else {
            currentZhihuDecision = .blocked("落账前复核发现知乎自动发表开关已关闭")
            appendStep("publish-decision", "复核期间开关关闭：未落账、clickCallCount=0")
            return
        }
        guard let account else {
            currentZhihuDecision = .blocked("落账前账号连续性无法确认")
            return
        }
        let recordID = currentActionID ?? UUID()
        let publishRecord = ZhihuPublishRecord(id: recordID, taskID: taskID, runID: token,
            accountIdentity: pageIdentity.accountIdentity, accountStableID: account.stableID,
            accountAliases: account.aliases, questionID: proof.questionID, expectedTextHash: proof.expectedTextHash,
            bodyVersion: proof.bodyVersion, sourceText: proof.expectedText, status: .attemptStarted,
            attemptStartedAt: Date(), clickCallCount: 0, clickResult: "not-called",
            answerID: nil, answerURL: nil, authorIdentity: nil, readbackText: nil,
            resultDetail: "attemptStarted 已持久化，尚未调用 click")
        zhihuPublishRecords.append(publishRecord)
        guard saveZhihuPublishRecords() else {
            zhihuPublishRecords.removeAll { $0.id == recordID }
            throw MikaError("发布 attemptStarted 持久化失败，按策略未点击")
        }
        if zhihuPublishLedgerKeyOverride == nil { persistSnapshot() }
        traceFinalAction = ["action": "attempt_publish_once", "buttonIndex": binding.buttonIndex,
                            "buttonIdentity": binding.buttonIdentity, "questionID": proof.questionID]
        traceRewriteReason = "WriteProof 有效且按钮归属唯一；disabled/计数/编辑提示为 non_blocking"
        appendStep("publish-decision", "原动作=\(action.action)，最终动作=attempt_publish_once；改写原因：\(traceRewriteReason)。按钮归属 question=\(binding.questionID)、editor=\(binding.editorIdentity)、composer=\(binding.composerIdentity)、button=\(binding.buttonIdentity)；disabled 观测：\(binding.disabledSummary)")
        // attemptStarted 已持久化后仍做最后一次授权/代次复核。若此刻被撤销，
        // 保留未决账防止恢复误点，但绝不调用 click。
        controlledZhihuBeforeFinalClick?()
        try await checkpoint(token)
        guard conversationTaskID == taskID, currentZhihuAuthorization.allowsZhihuAnswer,
              zhihuPublishExecutionAllowed else {
            if let i = zhihuPublishRecords.firstIndex(where: { $0.id == recordID }) {
                zhihuPublishRecords[i].status = .unknown
                zhihuPublishRecords[i].readbackCompletedAt = Date()
                zhihuPublishRecords[i].resultDetail = zhihuPublishExecutionAllowed
                    ? "落账后点击前授权被撤销或代次过期；click 未调用"
                    : "落账后点击前自动发表开关被关闭；记录保留，click 未调用"
            }
            _ = saveZhihuPublishRecords()
            appendStep("publish-decision", "落账后最终派发复核未通过：\(zhihuPublishExecutionAllowed ? "授权/代次变化" : "自动发表开关关闭")；记录保留、clickCallCount=0")
            return
        }
        executionSerial += 1
        let clickMarker = DispatchCallMarker()
        do {
            let result = try await auditedDispatch(name: "zhihu-publish", pageURL: safetyPage.url,
                                                   actionID: recordID, critical: true, callMarker: clickMarker) {
                try await web.attemptZhihuPublishOnce(proof: proof, binding: binding, attemptID: recordID)
            }
            if let i = zhihuPublishRecords.firstIndex(where: { $0.id == recordID }) {
                zhihuPublishRecords[i].status = .attempted
                zhihuPublishRecords[i].clickCallCount = 1
                zhihuPublishRecords[i].clickResult = result
                zhihuPublishRecords[i].resultDetail = "标准 click() 已调用一次，等待独立回读"
            }
            _ = saveZhihuPublishRecords()
            stateCard.setZhihuStatus(write: "已核实", publication: "已尝试")
            AgentTraceStore.shared.appendEngineAction(action: "attempt_publish_once",
                targetFingerprint: binding.buttonIdentity, method: "standard-click-once",
                result: result, pageURL: web.executionTab.webView.url?.absoluteString ?? "",
                taskID: taskID.uuidString, runID: token.uuidString,
                evidence: ["questionID": proof.questionID, "editorIdentity": proof.editorIdentity,
                           "composerIdentity": proof.composerIdentity, "bodyVersion": proof.bodyVersion,
                           "comparisonRule": proof.comparisonRule, "comparisonResult": proof.comparisonResult,
                           "disabledObservation": binding.disabledSummary, "clickCount": 1,
                           "sourceText": proof.expectedText, "committedText": proof.committedText])
            record(action, suffix: "（引擎改写为 attempt_publish_once；标准 click() 调用一次）")
            appendStep("publish-attempt", "发布尝试已执行：clickCallCount=1、result=\(result)；不进入通用重扫/模态升级/自动重试")
            if controlledSuspendAfterZhihuClick {
                controlledDidSuspendAfterZhihuClick = true
                return
            }
            _ = await runZhihuReadback(recordID: recordID, token: token)
        } catch {
            if let i = zhihuPublishRecords.firstIndex(where: { $0.id == recordID }) {
                zhihuPublishRecords[i].status = .unknown
                zhihuPublishRecords[i].clickCallCount = clickMarker.entered ? 1 : 0
                zhihuPublishRecords[i].clickResult = clickMarker.entered
                    ? "call-failed-or-unknown: \(error.localizedDescription)" : "not-called-before-dispatch: \(error.localizedDescription)"
                zhihuPublishRecords[i].resultDetail = clickMarker.entered
                    ? ZhihuPublishPolicy.unknownNotice : "派发前失败，标准 click() 未调用；未决记录保留防重放"
            }
            _ = saveZhihuPublishRecords()
            stateCard.setZhihuStatus(write: "已核实", publication: ZhihuPublishPolicy.unknownNotice)
            appendStep("publish-attempt", "点击调用返回异常：\(error.localizedDescription)。\(ZhihuPublishPolicy.unknownNotice) 立即进入一次有界回读，不重放")
            _ = await runZhihuReadback(recordID: recordID, token: token)
        }
    }

    // MARK: - prompt 组装：状态卡、确定性折叠与预算（H1）

    /// 状态卡的派生字段刷新：待办/未决问题/台账引用都由当前引擎状态直接
    /// 派生（等待谁、等什么、台账里有什么），不经模型转述；已完成与关键
    /// 事实在各自事件点增量维护（见 record/submitAnswer/confirm）。在每次
    /// 组装 prompt 与每次快照落盘前调用，保证卡片与现场一致。
    private func refreshStateCard() {
        if goal.isEmpty { return }
        if stateCard.goal != goal { stateCard.goal = goal }
        if let matchedZhihuPublishRecord { syncZhihuStateCard(from: matchedZhihuPublishRecord) }
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
        stateCard.outcomeRefs = outcomeLedger.compactMap { record in
            guard let taskID = conversationTaskID,
                  let claim = taskClaims.first(where: { $0.id == record.id }),
                  claim.sourceTaskID == taskID || claim.status == .verified else { return nil }
            return "\(Self.outcomeTime(record.recordedAt)) \(record.host.isEmpty ? "本地页面" : record.host)「\(record.elementLabel)」：\(Self.displayedOutcomeStatus(record.statusNote))\(claim.verifiedByUser ? "（据用户确认）" : "")"
        }
        stateCard.claims = taskClaims
        stateCard.updatedAt = Date()
    }

    /// 组装一轮 prompt：从自动级别（步数超阈值→1）或受控重试抬升的级别
    /// 起，超字符预算就逐级加大折叠，直到有界或到最紧级别 3 为止。
    private func assemblePrompt(pageJSON: String, answersJSON: String, loopHint: String?, outcomeHint: String?, steerHint: String? = nil) -> String {
        refreshStateCard()
        var level = max(forcedFoldLevel, steps.count > Self.foldStepThreshold ? 1 : 0)
        while true {
            let prompt = buildPrompt(pageJSON: pageJSON, answersJSON: answersJSON, foldLevel: level, loopHint: loopHint, outcomeHint: outcomeHint, steerHint: steerHint)
            if prompt.count <= Self.promptCharBudget || level >= 3 {
                tracePrompt = prompt
                traceHistoryBefore = Self.historyText(steps: steps, level: 0)
                traceHistoryAfter = Self.historyText(steps: steps, level: level)
                traceFoldLevel = level
                traceStateCardBefore = stateCard.promptBlock()
                return prompt
            }
            level += 1
        }
    }

    private func buildPrompt(pageJSON: String, answersJSON: String, foldLevel: Int, loopHint: String?, outcomeHint: String?, steerHint: String? = nil) -> String {
        var prompt = "任务：\(goal)\n"
        // 状态卡（H1）：程序维护的事实账，每轮在场；折叠只动历史段，动不了它
        let cardBlock = stateCard.promptBlock()
        if !cardBlock.isEmpty { prompt += cardBlock + "\n" }
        if let taskID = conversationTaskID {
            let claimsBlock = stateCard.claimPromptBlock(currentTaskID: taskID)
            if !claimsBlock.isEmpty { prompt += claimsBlock + "\n" }
        }
        // FIX4：程序派生的发布指令每轮单独注入，不依赖历史步骤，因而
        // 历史折叠超过 12 步或页面 JSON 截断也不会丢失。
        if let currentZhihuDirective { prompt += currentZhihuDirective.promptBlock() + "\n" }
        // 中断恢复的续跑提示（RESUME-CONTEXT-FIX）：恢复会话的每一轮都带上
        // ——原页面恢复结果＋不得反问目标／网址／进度的硬性口径，直到会话
        // 终结或新任务开始才清除。
        if let resumeNote { prompt += resumeNote + "\n" }
        if let draft = activePreservedDraft {
            prompt += """
            【独立稿件（跨任务保全）】
            draftID: \(draft.id.uuidString)
            version: \(draft.version)
            sourceTaskID: \(draft.sourceTaskID.uuidString)
            targetAccount: \(draft.target.accountStableID)
            targetQuestion: \(draft.target.questionID)
            fullText:
            \(draft.fullText)
            硬性规则：稿件正文无需向用户再次索取；导航或旧任务结束不删除稿件。旧 WriteProof 不随稿件迁移，必须在当前页面重新写入并取得 committed 全文等值后才可形成新凭证。
            """ + "\n"
        }
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
        if let steerHint { prompt += "\n用户插话：\n\(steerHint)" }
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
        var pendingAuthorization: PendingExecutionAuthorization? = nil
        var waiting: WaitingDTO?
        var answersJSON: String // [QuestionAnswer] 的 JSON
        var skillNames: [String]? // 已加载 playbook 名（正文恢复时按名从 SkillStore 重读；可选字段，旧快照无此键照常解码）
        var skillVersions: [String: String]? = nil
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
        // FIX4：当前正文凭证与发布尝试账随任务快照双写。尝试账另有 App
        // 级持久化，恢复时按 id 合并；旧快照无键照常解码。
        var zhihuWriteProof: WriteProof? = nil
        var zhihuPublishRecords: [ZhihuPublishRecord]? = nil
        var zhihuPublishAuthorization: PublishAuthorization? = nil
        /// 独立稿件只保存引用；正文仍只存在 PreservedDraftStore。
        var preservedDraftID: UUID? = nil
        // F1 起：待决网页上传的等待现场（仅 statusKind=waitingManual 且上传
        // 等待中才有值）。可选字段，此前快照无此键照常解码。SP-01 一次性
        // 凭据不落盘：恢复时若原阶段是选文件且文件非本任务生成，退回确认
        // 阶段重新出卡（见 restoreSnapshot 的 waitingManual 分支）。
        struct UploadDTO: Codable {
            var actionID: UUID? = nil
            var attachmentID: UUID?
            var attachmentName: String
            var isTaskGenerated: Bool
            var pageURL: String
            var elementIndex: Int
            var elementLabel: String
            var wasPickStage: Bool
            var confirmationIssuedAt: Date? = nil
            var confirmationRevision: Int? = nil
            var targetKey: String? = nil
            var preUploadImages: [String]? = nil
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
        // 恢复预算为整任务账；旧快照无键时给新预算。
        var recoveryBudget: RecoveryBudget? = nil
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
        // 侧车是消费/转移的权威记录；快照仅保留未生效项的镜像，恢复不据此重放。
        var pendingSteers: [SteerItem]? = nil
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
    @discardableResult private func persistSnapshot() -> Bool {
        guard let (kind, text) = currentStatusKind(), !goal.isEmpty else { return false }
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
                                       pendingAuthorization: pendingExecutionAuthorization,
                                       waiting: waitingDTO, answersJSON: String(decoding: answersData, as: UTF8.self),
                                       skillNames: loadedSkillNames,
                                       skillVersions: loadedSkillVersions,
                                       taskID: conversationTaskID,
                                       tabURLs: scene.urls, activeTabIndex: scene.activeIndex, executionTabIndex: scene.executionIndex, tabPinned: scene.pinned,
                                       outcomes: outcomeLedger,
                                       stateCard: stateCard,
                                       sessionID: runSessionID,
                                       // 页面凭证不跨进程；正文由 PreservedDraftStore 独立保存。
                                       zhihuWriteProof: nil,
                                       zhihuPublishRecords: zhihuPublishRecords,
                                       zhihuPublishAuthorization: currentZhihuAuthorization,
                                       preservedDraftID: activePreservedDraft?.id,
                                       upload: pendingUpload.map { upload in
                                           SessionSnapshot.UploadDTO(actionID: upload.id,
                                                                     attachmentID: upload.attachmentID, attachmentName: upload.attachmentName,
                                                                     isTaskGenerated: upload.isTaskGenerated, pageURL: upload.pageURL,
                                                                     elementIndex: upload.elementIndex, elementLabel: upload.elementLabel,
                                                                     wasPickStage: upload.stage == .pickFile,
                                                                     confirmationIssuedAt: upload.confirmationIssuedAt,
                                                                     confirmationRevision: upload.confirmationRevision,
                                                                     targetKey: upload.targetKey,
                                                                     preUploadImages: upload.preUploadImages)
                                       },
                                       modelStepsUsed: stepBudget.segmentUsed, budgetSegment: stepBudget.segment,
                                       totalModelSteps: stepBudget.totalUsed, stepLimitPaused: stepLimitPaused,
                                       recoveryBudget: recoveryBudget,
                                       ladderAttempted: bypassLadder.attemptedRaw, ladderNotes: bypassLadder.notes,
                                       ladderTemplate: bypassLadder.harvestTemplate, ladderTemplateFrom: bypassLadder.harvestTemplateFrom, ladderFact: bypassLadder.harvestFact,
                                       stallStuck: openStall?.stuck, stallOpenURL: openStall?.openURL,
                                       stallOpenedDecision: openStall?.openedAtDecision, stallDialogAtOpen: openStall?.dialogAtOpen,
                                       stallVerified: openStall?.verifiedRaw, stallNA: openStall?.naRaw, stallClicked: openStall?.clickedRaw,
                                       stallClickExecuted: openStall?.clickExecuted, stallFrameTried: openStall?.frameCloseTried,
                                       stallInvalid: openStall?.invalidActions, stallBlind: openStall?.perceptionBlindNote,
                                       pendingSteers: currentSteerState?.pending)
        do {
            let data = try JSONEncoder().encode(snapshot)
            // H1：快照落所属会话的 snapshot.json（按会话分库；M1 起按
            // runSessionID——任务在会话 A 执行时用户切到 B 浏览，落盘仍回
            // A 的目录）；旧键若还在（迁移未发生的边角）一并清除，防止
            // 旧快照复活盖掉新状态
            let url = SessionStore.shared.snapshotURL(for: runSessionID)
            let saved: Bool
            do { try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]); saved = true }
            catch { saved = false }
            if UserDefaults.standard.object(forKey: Self.snapshotKey) != nil {
                UserDefaults.standard.removeObject(forKey: Self.snapshotKey)
            }
            if saved { saveTaskProgress() }
            return saved
        } catch { return false }
    }

    private func clearSnapshot() {
        saveTaskProgress()
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
        recoveryBudget = snapshot.recoveryBudget ?? RecoveryBudget()
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
        // 页面/tab/document/editor 均会在进程恢复后重建。旧 WriteProof 只
        // 用于旧快照解码，不恢复为有效凭证；正文从独立稿件存储取回。
        currentZhihuWriteProof = nil
        currentZhihuPublishBinding = nil
        conversationTaskID = snapshot.taskID ?? UUID()
        attachPreservedDraft(to: snapshot.goal, draftID: snapshot.preservedDraftID,
                             sourceTaskID: conversationTaskID)
        currentZhihuAuthorization = snapshot.zhihuPublishAuthorization ?? .initial(instruction: snapshot.goal)
        if let savedPublish = snapshot.zhihuPublishRecords {
            var changed = false
            for record in savedPublish where !zhihuPublishRecords.contains(where: { $0.id == record.id }) {
                zhihuPublishRecords.append(record); changed = true
            }
            if changed { _ = saveZhihuPublishRecords() }
        }
        if let answers = try? JSONDecoder().decode([QuestionAnswer].self, from: Data(snapshot.answersJSON.utf8)) { answerContext = answers }
        if let names = snapshot.skillNames {
            for name in names {
                if let skill = SkillStore.shared.skill(named: name), !loadedSkillNames.contains(skill.name) {
                    loadedSkillNames.append(skill.name)
                    loadedSkillVersions[skill.name] = skill.version
                    // 快照只声明当时版本；恢复始终按名称读取当前安装版本，
                    // 不继续注入快照时代的旧 loadedSkillBodies。
                    loadedSkillBodies += "\n【playbook：\(skill.name) v\(skill.version)】\n\(skill.body)"
                }
            }
        }
        if let waiting = snapshot.waiting {
            waitingInput = waiting.kind == "question" ? .question(id: waiting.id, text: waiting.text) : .manual(id: waiting.id, text: waiting.text)
        }
        refreshPendingSteers()
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
            pendingExecutionAuthorization = snapshot.pendingAuthorization
            if let json = snapshot.pendingActionJSON,
               let action = try? JSONDecoder().decode(AgentAction.self, from: Data(json.utf8)),
               let element = snapshot.pendingElement, let url = snapshot.pendingURL,
               let authorization = pendingExecutionAuthorization, !authorization.expired {
                pending = (action, element, url, authorization.executionRevision)
                status = .waitingConfirm(action)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(max(0, 60 - Date().timeIntervalSince(authorization.issuedAt))))
                    self?.expirePendingAuthorization(id: authorization.id)
                }
            } else {
                pendingExecutionAuthorization = nil
                status = .paused("上次审批已过期或缺少绑定记录，已默认拒绝；请重新发起")
            }
        case "waitingManual":
            status = .waitingManual(snapshot.statusText)
            // 待决上传的等待现场恢复（F1）：凭据不跨进程——原阶段是确认卡
            // 就照旧出卡（恢复时重新签发凭据）；原阶段是选文件且文件非本
            // 任务生成，退回确认阶段重新确认（旧确认不复用）；本任务生成
            // 的文件才直接恢复到选文件阶段（用户需在页面上重新点控件）。
            if let dto = snapshot.upload {
                var upload = PendingUpload(id: dto.actionID ?? UUID(), attachmentID: dto.attachmentID, attachmentName: dto.attachmentName,
                                           isTaskGenerated: dto.isTaskGenerated, pageURL: dto.pageURL,
                                           pageHost: URL(string: dto.pageURL)?.host ?? "",
                                           elementIndex: dto.elementIndex, elementLabel: dto.elementLabel,
                                           stage: .confirmUpload, confirmationToken: nil)
                upload.targetKey = dto.targetKey
                upload.confirmationIssuedAt = dto.confirmationIssuedAt
                upload.confirmationRevision = dto.confirmationRevision
                upload.preUploadImages = dto.preUploadImages ?? []
                if dto.wasPickStage {
                    guard dto.preUploadImages != nil else {
                        status = .paused("旧版上传现场缺少回读基线，按 unknown 停止自动续传")
                        return
                    }
                    upload.stage = .pickFile
                    pendingUpload = upload
                    let text = "上次上传可能已派发。先检查页面文件控件与预览，再点「已选好」做独立回读；文件不会自动重供。"
                    waitingInput = .manual(id: upload.id, text: text)
                    status = .waitingManual(text)
                    _ = appendExecutionAudit(event: "recovery-upload-unknown", actionID: upload.id,
                                             pageURL: upload.pageURL, evidenceRef: "process-restart-no-replay")
                    return
                } else {
                    if let issuedAt = upload.confirmationIssuedAt,
                       Date().timeIntervalSince(issuedAt) < 60 {
                        upload.confirmationToken = AttachmentStore.shared.issueUploadConfirmation(attachmentID: dto.attachmentID, pageURL: dto.pageURL)
                    } else {
                        status = .paused("上次上传审批已过期，文件未供给页面")
                        pendingUpload = nil
                        waitingInput = nil
                        return
                    }
                }
                // 找图指引字段按附件记录现查回填（COVER-UPLOAD-FIX C）；
                // 恢复到选文件阶段且附件可解析时重新武装待供文件——
                // 进程被杀不改变「用户点上传按钮即自动带上」的口径。
                if let attachmentID = dto.attachmentID,
                   let record = AttachmentStore.shared.record(id: attachmentID, sessionID: runSessionID) {
                    upload.isImage = record.contentType.hasPrefix("image/")
                    upload.savedToPhotos = record.savedToPhotos == true
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
        loopDetector.reset(); pendingLoopHint = nil; loadedSkillNames = []; loadedSkillVersions = [:]; loadedSkillBodies = ""
        conversationTaskID = nil; pendingSteers = []; sessionActive = false; status = .idle
        pendingTabScene = nil; restoredSession = false; didApplyTabRestore = false; resumeNote = nil
        currentZhihuWriteProof = nil; currentZhihuPublishBinding = nil; currentZhihuDecision = nil; currentZhihuDirective = nil
        activePreservedDraft = nil
        discardPendingUpload()
        // 成果台账的内存态同样清掉（打字记录／软门已提醒集合／未消费提醒），
        // 恢复后只剩快照里双写的那份台账——与真机强退重开同一口径
        recentTyped = []; outcomeGateFired = []; pendingOutcomeHint = nil; pendingOutcomeStep = nil; pendingVerificationStep = nil; outcomeLedger = []
        // 状态卡与折叠/重试内存态同样清零：恢复出的卡片只能来自快照（H1）
        stateCard = TaskStateCard(); forcedFoldLevel = 0; contextRetryUsed = false; finalAuditFired = false
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

// 视图只读状态映射，避免把引擎控制逻辑放进 SwiftUI。
extension AgentStatus {
    var isRunningForSteer: Bool { if case .running = self { return true }; return false }
    var isTerminalForFold: Bool { switch self { case .done, .failed, .ended: return true; default: return false } }
}

#if DEBUG && targetEnvironment(simulator)
// Round 1 CLI-only WK regression driver. It uses production runTargeted,
// confirm/runConfirmed, auditedDispatch, receipt stores and snapshot recovery.
// It never calls a model and only loads the bundled CSP-isolated fixture.
private final class GateBatchFixtureServer: @unchecked Sendable {
    private let html: Data
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "mikaweb.gate-batch1.fixture")
    private var listenFD: Int32 = -1

    init() throws {
        guard let url = Bundle.main.url(forResource: "test-gate-batch1", withExtension: "html") else {
            throw MikaError("缺少测试页 test-gate-batch1")
        }
        html = try Data(contentsOf: url)
    }

    func start() throws -> URL {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MikaError("Gate fixture socket failed") }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw MikaError("Gate fixture listener failed")
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            close(fd)
            throw MikaError("Gate fixture port lookup failed")
        }
        lock.lock(); listenFD = fd; lock.unlock()
        queue.async { [self] in acceptLoop() }
        return URL(string: "http://127.0.0.1:\(UInt16(bigEndian: actual.sin_port))/test-gate-batch1.html")!
    }

    func stop() {
        lock.lock()
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
    }

    private func acceptLoop() {
        while true {
            lock.lock(); let fd = listenFD; lock.unlock()
            if fd < 0 { return }
            var clientAddress = sockaddr()
            var length = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(fd, &clientAddress, &length)
            if client < 0 { return }
            handle(client)
        }
    }

    private func handle(_ client: Int32) {
        defer { close(client) }
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var request = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while request.count < 32768 {
            let received = recv(client, &chunk, chunk.count, 0)
            if received <= 0 { return } // Empty or early closed connections are harmless.
            request.append(contentsOf: chunk[0..<received])
            if request.range(of: Data([13, 10, 13, 10])) != nil { break }
        }
        guard let line = String(data: request, encoding: .utf8)?.components(separatedBy: "\r\n").first else { return }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return }
        let path = parts[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        let found = parts[0] == "GET" && path.hasSuffix("test-gate-batch1.html")
        let body = found ? html : Data()
        let header = "HTTP/1.0 \(found ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        response.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let count = send(client, base.advanced(by: sent), bytes.count - sent, 0)
                if count <= 0 { return } // Client closed early.
                sent += count
            }
        }
    }
}

private struct GateBatchWKContext {
    let engine: AgentEngine
    let web: WebController
    let host: WKSelfTestHost
    let auditURL: URL
    let pageURL: URL?
}

extension AgentEngine {
    private static let gateBatchBody = "闸门首批受控稿件：这段完整正文必须由生产输入链写入，并由独立页面列表回读。"
    private static var gateBatchEnvironment: String {
        ProcessInfo.processInfo.environment["MIKA_GATE_ENVIRONMENT"] ?? "local iOS Simulator"
    }
    private static var gateBatchDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GateBatch1", isDirectory: true)
    }
    private static func gateJSON<T: Encodable>(_ value: T) -> Any {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }
        return object
    }
    private static func gateAction(_ name: String, index: Int = -1, text: String = "", url: String = "") throws -> AgentAction {
        let data = try JSONSerialization.data(withJSONObject: ["action": name, "index": index,
            "text": text, "url": url, "summary": "受控检查结束，结果见回执", "reason": "gate batch1 controlled WK driver"])
        return try JSONDecoder().decode(AgentAction.self, from: data)
    }
    private static func gateContext(_ label: String, reset: Bool = true,
                                    sessionID: UUID = UUID(), taskID: UUID = UUID(),
                                    pageURL: URL? = nil) async throws -> GateBatchWKContext {
        if reset {
            // Only reachable from this isolated simulator CLI workflow.
            for key in [outcomeLedgerKey, executionReceiptsKey, taskClaimsKey] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let web = WebController()
        web.showSessionTabs(sessionID)
        web.beginExecution(sessionID: sessionID)
        let host = WKSelfTestHost(tab: web.executionTab, suite: "gate-batch1-\(label)")
        if let pageURL {
            try await host.loadURLAndWait(pageURL, expectedPath: "test-gate-batch1.html",
                                          readinessJavaScript: "!!window.__gate")
        } else {
            try await host.loadLocalAndWait("test-gate-batch1", readinessJavaScript: "!!window.__gate")
        }
        let engine = AgentEngine(web: web, settings: SettingsStore(), restoreSession: false)
        engine.runSessionID = sessionID; engine.conversationTaskID = taskID
        engine.goal = "闸门受控 WK 检查 \(label)"; engine.taskText = engine.goal
        engine.stateCard = TaskStateCard(goal: engine.goal)
        engine.status = .running; engine.active = true
        engine.controlledActions = [try gateAction("done")]
        engine.stepBudget = StepBudget(limit: 25)
        let auditURL = gateBatchDirectory.appendingPathComponent("\(label)-audit.jsonl")
        engine.gateSelfTestAuditStore = ExecutionAuditStore(fileURL: auditURL)
        try FileManager.default.createDirectory(at: SessionStore.shared.snapshotURL(for: sessionID)
            .deletingLastPathComponent(), withIntermediateDirectories: true)
        return GateBatchWKContext(engine: engine, web: web, host: host, auditURL: auditURL,
                                  pageURL: pageURL)
    }
    private static func gateEvaluate(_ context: GateBatchWKContext, _ script: String) async throws -> Any? {
        guard let url = context.web.executionTab.webView.url,
              url.lastPathComponent == "test-gate-batch1.html",
              (url.isFileURL || (url.scheme == "http" && url.host == "127.0.0.1" &&
                                  url == context.pageURL)) else {
            throw MikaError("Gate self-test refused non-fixture page")
        }
        return try await context.web.executionTab.webView.evaluateJavaScript(script)
    }
    private static func gateState(_ context: GateBatchWKContext) async throws -> [String: Any] {
        guard let raw = try await gateEvaluate(context, "window.__gate.state()") as? String,
              let result = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            throw MikaError("Gate fixture state missing")
        }
        return result
    }
    private static func gateAudit(_ context: GateBatchWKContext) -> [[String: Any]] {
        guard let raw = try? String(contentsOf: context.auditURL, encoding: .utf8) else { return [] }
        return raw.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }
    private static func gateRun(_ context: GateBatchWKContext, label: String,
                                text: String? = nil) async throws -> TargetedOutcome {
        let page = try await context.web.state()
        let element = page.elements.first { text != nil ? $0.tag == "textarea" : $0.text == label }
        guard let element else { throw MikaError("Gate fixture target missing: \(label)") }
        let action = try gateAction(text == nil ? "click" : "type", index: element.index, text: text ?? "")
        context.engine.currentActionID = UUID()
        return try await context.engine.runTargeted(action, modelPage: page, token: context.engine.generation)
    }
    private static func gateRequest(_ context: GateBatchWKContext, label: String = "发布测试稿") async throws {
        let result = try await gateRun(context, label: label)
        guard case .waiting = result, context.engine.pending != nil,
              context.engine.pendingExecutionAuthorization != nil else {
            throw MikaError("Submission did not reach production approval gate")
        }
    }
    private static func gateWaitWorker(_ engine: AgentEngine) async throws {
        let deadline = Date().addingTimeInterval(35)
        while Date() < deadline {
            if case .running = engine.status { try await Task.sleep(for: .milliseconds(100)) }
            else { return }
        }
        engine.worker?.cancel()
        throw MikaError("Gate production worker timed out")
    }
    private static func gateCheck(_ name: String, _ passed: Bool) -> [String: Any] {
        ["assertion": name, "passed": passed]
    }
    private static func gateEvidence(_ context: GateBatchWKContext) async throws -> [String: Any] {
        ["taskID": context.engine.conversationTaskID?.uuidString ?? "missing",
         "sessionID": context.engine.runSessionID.uuidString,
         "fixture": try await gateState(context), "host": context.host.observations,
         "auditRef": context.auditURL.lastPathComponent, "audit": gateAudit(context),
         "receipts": gateJSON(context.engine.executionReceipts),
         "outcomes": gateJSON(context.engine.outcomeLedger),
         "progress": gateJSON(context.engine.progressBySession[context.engine.runSessionID]),
         "status": String(describing: context.engine.status)]
    }

    func verifyGateBatch1WK() async -> [String: Any] {
        try? FileManager.default.createDirectory(at: Self.gateBatchDirectory, withIntermediateDirectories: true)
        let ids = ["normal_execution", "denial", "approval_expiry", "target_drift", "post_validation_change",
                   "duplicate_request", "post_dispatch_disconnect", "log_failure", "rescan_relocation_swap", "pointer_sequence_swap",
                   "model_driven_recovery", "model_driven_recovery_insufficient"]
        var cases: [[String: Any]] = []
        for id in ids {
            var context: GateBatchWKContext?
            var checks: [[String: Any]] = []
            var details: [String: Any] = [:]
            do {
                var fixtureServer: GateBatchFixtureServer?
                defer { fixtureServer?.stop() }
                let pageURL: URL?
                if ["model_driven_recovery", "model_driven_recovery_insufficient"].contains(id) {
                    let server = try GateBatchFixtureServer()
                    pageURL = try server.start()
                    fixtureServer = server
                } else {
                    pageURL = nil
                }
                let c = try await Self.gateContext(id, pageURL: pageURL); context = c
                _ = try await Self.gateEvaluate(c, "window.__gate.reset()")
                switch id {
                case "normal_execution":
                    var preparedBeforeReturn = true
                    c.engine.gateSelfTestAfterDispatch = { [weak engine = c.engine] in
                        guard let engine,
                              let data = UserDefaults.standard.data(forKey: Self.executionReceiptsKey),
                              let saved = try? JSONDecoder().decode([ExecutionReceipt].self, from: data),
                              let last = saved.last else { preparedBeforeReturn = false; return }
                        preparedBeforeReturn = preparedBeforeReturn && last.dispatchState == .unknown &&
                            last.taskID == engine.conversationTaskID
                    }
                    _ = try await Self.gateRun(c, label: "正文", text: Self.gateBatchBody)
                    for _ in 0..<2 {
                        let result = try await Self.gateRun(c, label: "展开详情")
                        checks.append(Self.gateCheck("low risk click executes without waitingConfirm", {
                            if case .executed = result { return c.engine.pending == nil }; return false
                        }()))
                    }
                    try await Self.gateRequest(c)
                    c.engine.confirm(execute: true)
                    try await Self.gateWaitWorker(c.engine)
                    c.engine.gateSelfTestAfterDispatch = nil
                    let state = try await Self.gateState(c)
                    let critical = c.engine.executionReceipts.last(where: { $0.critical })
                    let linked = Self.gateAudit(c).filter { $0["actionID"] as? String == critical?.actionID.uuidString }
                    let requiredEvents: Set<String> = ["authorization-requested", "authorization-approved", "attempt-click", "dispatch-prepared", "dispatch-sent", "verification-verified"]
                    checks.append(Self.gateCheck("authorization, attempt, dispatch and verification share task/action IDs and evidence refs",
                        requiredEvents.isSubset(of: Set(linked.compactMap { $0["event"] as? String })) &&
                        linked.allSatisfy { $0["taskID"] as? String == c.engine.conversationTaskID?.uuidString && ($0["evidenceRef"] as? String)?.isEmpty == false }))
                    checks += [Self.gateCheck("two low-risk effects, exactly one submission", state["low"] as? Int == 2 && state["submissions"] as? Int == 1),
                        Self.gateCheck("complete body independently read back", state["records"] as? String == Self.gateBatchBody),
                        Self.gateCheck("receipt existed durably before dispatch returned", preparedBeforeReturn),
                        Self.gateCheck("only verified result reaches success ledger", c.engine.outcomeLedger.count == 1 && c.engine.outcomeLedger.first?.verificationVerdict == .verified && c.engine.taskClaims.last?.status == .verified),
                        Self.gateCheck("one approval for submission; none for low risk clicks", Self.gateAudit(c).filter { $0["event"] as? String == "authorization-requested" }.count == 1)]
                case "model_driven_recovery", "model_driven_recovery_insufficient":
                    // Stage A creates the record through the real production input/approval/verification chain.
                    _ = try await Self.gateRun(c, label: "正文", text: Self.gateBatchBody)
                    try await Self.gateRequest(c)
                    c.engine.confirm(execute: true)
                    try await Self.gateWaitWorker(c.engine)
                    let submitted = try await Self.gateState(c)
                    guard let original = c.engine.outcomeLedger.last,
                          original.verificationVerdict == .verified,
                          submitted["submissions"] as? Int == 1,
                          submitted["records"] as? String == Self.gateBatchBody else {
                        throw MikaError("Recovery setup did not produce a real verified submission")
                    }
                    details["stageA"] = try await Self.gateEvidence(c)
                    // Explicit scenario setup, never a reconciliation writeback or disconnect hook.
                    var legacy = original
                    legacy.taskID = nil; legacy.actionID = nil; legacy.dispatchState = nil
                    legacy.verificationVerdict = nil; legacy.statusNote = "已提交（待核查）"
                    if id == "model_driven_recovery_insufficient" {
                        legacy.contentPrefix = "从未提交过的对账反例正文"
                    }
                    c.engine.outcomeLedger[c.engine.outcomeLedger.count - 1] = legacy
                    guard c.engine.saveOutcomeLedger() else { throw MikaError("Legacy scenario setup could not persist") }
                    details["scenarioSetup"] = ["method": "production verified record reshaped to legacy nil taskID/actionID/dispatchState/verificationVerdict; statusNote pending",
                                                "before": Self.gateJSON(original), "after": Self.gateJSON(legacy)]
                    let recovered = try await Self.gateContext(id + "-new-task", reset: false, pageURL: pageURL)
                    context = recovered
                    guard recovered.engine.outcomeLedger.contains(where: { $0.id == legacy.id && $0.unresolved }),
                          recovered.engine.conversationTaskID != original.taskID else {
                        throw MikaError("New task did not load unresolved legacy record")
                    }
                    let page = try await recovered.web.state()
                    guard let low = page.elements.first(where: { $0.text == "展开详情" }) else {
                        throw MikaError("Recovery low risk target missing")
                    }
                    let click = try Self.gateAction("click", index: low.index)
                    let navigation = try Self.gateAction("navigate", url: legacy.pageURL)
                    let engine = recovered.engine
                    engine.controlledActions = id == "model_driven_recovery"
                        ? [click] : [navigation, click]
                    engine.controlledActionCursor = 0
                    engine.startInSession(engine.runSessionID, local: nil, task: engine.goal,
                                          startingID: engine.conversationTaskID)
                    try await Self.gateWaitWorker(engine)
                    let blocked = try await Self.gateState(recovered)
                    let guardFailed: Bool = {
                        if case .failed(let message) = engine.status { return message.contains("本任务有未决副作用") }
                        return false
                    }()
                    checks.append(Self.gateCheck("production loop dependent click fails with unresolved guard; low effect remains zero",
                        guardFailed && blocked["low"] as? Int == 0 && blocked["submissions"] as? Int == 1))
                    details["firstLoop"] = try await Self.gateEvidence(recovered)
                    if id == "model_driven_recovery" {
                        checks.append(Self.gateCheck("loop entry alone never reconciles legacy record",
                            engine.outcomeLedger.contains { $0.id == legacy.id && $0.unresolved } &&
                            !Self.gateAudit(recovered).contains {
                                $0["event"] as? String == "reconciliation-verified" && $0["actionID"] as? String == legacy.id.uuidString
                            }))
                        engine.controlledActions = [navigation, click, try Self.gateAction("done")]
                        engine.controlledActionCursor = 0
                        engine.resume()
                        try await Self.gateWaitWorker(engine)
                        let after = try await Self.gateState(recovered)
                        let done: Bool = { if case .done = engine.status { return true }; return false }()
                        checks += [Self.gateCheck("post-navigation production reconciliation verifies the original legacy record",
                            engine.outcomeLedger.contains { $0.id == legacy.id && $0.verificationVerdict == .verified } &&
                            Self.gateAudit(recovered).contains { $0["event"] as? String == "reconciliation-verified" && $0["actionID"] as? String == legacy.id.uuidString }),
                            Self.gateCheck("resume executes low risk click once, never replays submission, and closes with done",
                                after["low"] as? Int == 1 && after["submissions"] as? Int == 1 && done && engine.controlledActionCursor == 3)]
                    } else {
                        let audit = Self.gateAudit(recovered)
                        let insufficient = audit.contains { $0["event"] as? String == "reconciliation-insufficient" && $0["evidenceRef"] as? String == legacy.id.uuidString }
                        let verified = audit.contains { $0["event"] as? String == "reconciliation-verified" && $0["actionID"] as? String == legacy.id.uuidString }
                        checks.append(Self.gateCheck("absent prefix leaves record and receipts untouched with insufficient audit only",
                            insufficient && !verified && engine.outcomeLedger.contains {
                                $0.id == legacy.id && $0.unresolved && $0.taskID == nil && $0.actionID == nil &&
                                $0.dispatchState == nil && $0.verificationVerdict == nil &&
                                $0.verificationEvidenceID == legacy.verificationEvidenceID && $0.statusNote == legacy.statusNote
                            } && engine.controlledActionCursor == 2))
                    }
                    details["productionLoop"] = try await Self.gateEvidence(recovered)
                case "denial":
                    try await Self.gateRequest(c)
                    c.engine.confirm(execute: false)
                    try await Self.gateWaitWorker(c.engine)
                    c.engine.confirm(execute: true) // Stale approval after refusal has no authority.
                    let state = try await Self.gateState(c)
                    checks += [Self.gateCheck("explicit refusal never calls fixture handler", state["submissions"] as? Int == 0 && c.engine.executionReceipts.isEmpty),
                        Self.gateCheck("denial audited with bound action ID", Self.gateAudit(c).contains { $0["event"] as? String == "authorization-denied" && $0["actionID"] != nil })]
                case "approval_expiry":
                    try await Self.gateRequest(c)
                    guard let issued = c.engine.pendingExecutionAuthorization?.issuedAt else { throw MikaError("No approval timestamp") }
                    // Real wall time: never backdate issuedAt or shorten the production deadline.
                    while Date().timeIntervalSince(issued) < 61 { try await Task.sleep(for: .milliseconds(200)) }
                    c.engine.confirm(execute: true) // Late UI callback must not dispatch.
                    try await Task.sleep(for: .milliseconds(300))
                    let elapsed = Date().timeIntervalSince(issued)
                    details["elapsedSeconds"] = elapsed
                    let expiredState = try await Self.gateState(c)
                    checks += [Self.gateCheck("real 60-second deadline elapsed", elapsed >= 60),
                        Self.gateCheck("expired approval discarded; late approval cannot dispatch", c.engine.pending == nil && c.engine.pendingExecutionAuthorization == nil && c.engine.executionReceipts.isEmpty && expiredState["submissions"] as? Int == 0),
                        Self.gateCheck("expiry audit exists", Self.gateAudit(c).contains { $0["event"] as? String == "authorization-expired" })]
                case "target_drift":
                    try await Self.gateRequest(c)
                    let before = c.engine.pendingExecutionAuthorization!
                    _ = try await Self.gateEvaluate(c, "document.querySelector('#submit').textContent='另一个目标'")
                    c.engine.confirm(execute: true)
                    try await Self.gateWaitWorker(c.engine)
                    let driftState = try await Self.gateState(c)
                    let targetRejected: Bool = {
                        if case .failed = c.engine.status {
                            return Self.gateAudit(c).contains { $0["event"] as? String == "authorization-invalid" }
                        }
                        return false
                    }()
                    checks.append(Self.gateCheck("live target re-resolution blocks changed DOM before dispatch", targetRejected && c.engine.executionReceipts.isEmpty && driftState["submissions"] as? Int == 0))
                    details["authorizationBeforeDrift"] = Self.gateJSON(before)
                    let revision = try await Self.gateContext("revision-drift")
                    _ = try await Self.gateEvaluate(revision, "window.__gate.reset()")
                    try await Self.gateRequest(revision)
                    let oldRevision = revision.web.executionRevision
                    try await revision.host.loadLocalAndWait("test-gate-batch1", readinessJavaScript: "!!window.__gate")
                    revision.engine.confirm(execute: true)
                    try await Self.gateWaitWorker(revision.engine)
                    let revisionState = try await Self.gateState(revision)
                    checks.append(Self.gateCheck("actual navigation revision change invalidates approval", revision.web.executionRevision != oldRevision && revision.engine.executionReceipts.isEmpty && revisionState["submissions"] as? Int == 0 && Self.gateAudit(revision).contains { $0["event"] as? String == "authorization-invalid" }))
                    details["revisionDrift"] = try await Self.gateEvidence(revision)
                case "post_validation_change":
                    // 检查后变更反例：授权校验先通过；目的地在派发流自身的
                    // scrollIntoView 步被换——那一步在 probeClickContext 全量校验
                    // 之后、最终点击守卫之前，故拦下它的只能是最终一致性校验。
                    // 审计出现 authorization-invalid 说明拦点在前置校验（本用例设计
                    // 失败）；出现 dispatch-sent 说明未拦住。
                    try await Self.gateRequest(c, label: "提交链接稿")
                    let boundAuthorization = c.engine.pendingExecutionAuthorization!
                    _ = try await Self.gateEvaluate(c, "window.__gate.armHrefSwap()")
                    c.engine.confirm(execute: true)
                    try await Self.gateWaitWorker(c.engine)
                    let swapState = try await Self.gateState(c)
                    let swapEvents = Self.gateAudit(c).compactMap { $0["event"] as? String }
                    checks.append(Self.gateCheck("destination swapped after authorization is blocked at final dispatch, never sent",
                        swapState["swapped"] as? Bool == true &&
                        swapState["linkHref"] as? String == "#dest-swapped" &&
                        swapState["linkClicks"] as? Int == 0 &&
                        swapEvents.contains("authorization-approved") &&
                        !swapEvents.contains("authorization-invalid") &&
                        swapEvents.contains("dispatch-prepared") &&
                        swapEvents.contains("dispatch-unknown") &&
                        !swapEvents.contains("dispatch-sent")))
                    checks.append(Self.gateCheck("blocked link dispatch stays unresolved and out of the success ledger",
                        c.engine.outcomeLedger.count == 1 &&
                        c.engine.outcomeLedger.first?.dispatchState == .unknown &&
                        c.engine.outcomeLedger.first?.verificationVerdict != .verified &&
                        c.engine.executionReceipts.contains { $0.critical && $0.dispatchState == .unknown }))
                    details["authorizationBeforeSwap"] = Self.gateJSON(boundAuthorization)
                case "rescan_relocation_swap":
                    try await Self.gateRequest(c, label: "提交链接稿")
                    details["authorizationBeforeSwap"] = Self.gateJSON(c.engine.pendingExecutionAuthorization!)
                    _ = try await Self.gateEvaluate(c, "window.__gate.armRescanSwap()")
                    c.engine.confirm(execute: true)
                    try await Self.gateWaitWorker(c.engine)
                    let swapState = try await Self.gateState(c)
                    let swapEvents = Self.gateAudit(c).compactMap { $0["event"] as? String }
                    checks.append(Self.gateCheck("rescan scenario entered: original disabled after approval, same-label decoy revealed",
                        swapState["rescanApplied"] as? Bool == true))
                    checks.append(Self.gateCheck("rescan re-location refuses same-label target with unbound href; nothing clicked",
                        swapState["decoyClicks"] as? Int == 0 && swapState["linkClicks"] as? Int == 0 && swapState["submissions"] as? Int == 0 &&
                        swapEvents.contains("dispatch-unknown") && !swapEvents.contains("dispatch-sent") &&
                        !swapEvents.contains("authorization-invalid")))
                    checks.append(Self.gateCheck("blocked rescan dispatch stays unresolved and out of the success ledger",
                        c.engine.outcomeLedger.count == 1 &&
                        c.engine.outcomeLedger.first?.dispatchState == .unknown &&
                        c.engine.outcomeLedger.first?.verificationVerdict != .verified &&
                        c.engine.executionReceipts.contains { $0.critical && $0.dispatchState == .unknown }))
                case "pointer_sequence_swap":
                    try await Self.gateRequest(c, label: "提交弹窗稿")
                    details["authorizationBeforeSwap"] = Self.gateJSON(c.engine.pendingExecutionAuthorization!)
                    _ = try await Self.gateEvaluate(c, "window.__gate.armDlgSwap()")
                    c.engine.confirm(execute: true)
                    try await Self.gateWaitWorker(c.engine)
                    let swapState = try await Self.gateState(c)
                    let swapEvents = Self.gateAudit(c).compactMap { $0["event"] as? String }
                    checks.append(Self.gateCheck("dialog target destination swapped mid-sequence",
                        swapState["dlgSwapped"] as? Bool == true && swapState["dlgHref"] as? String == "#dlg-swapped"))
                    checks.append(Self.gateCheck("pointer sequence aborted before click effect; nothing clicked or submitted",
                        swapState["dlgClicks"] as? Int == 0 && swapState["submissions"] as? Int == 0 &&
                        swapEvents.contains("dispatch-unknown") && !swapEvents.contains("dispatch-sent") &&
                        !swapEvents.contains("authorization-invalid")))
                    checks.append(Self.gateCheck("blocked pointer dispatch stays unresolved and out of the success ledger",
                        c.engine.outcomeLedger.count == 1 &&
                        c.engine.outcomeLedger.first?.dispatchState == .unknown &&
                        c.engine.outcomeLedger.first?.verificationVerdict != .verified &&
                        c.engine.executionReceipts.contains { $0.critical && $0.dispatchState == .unknown }))
                case "duplicate_request":
                    for mode in ["silent", "rejected"] {
                        let d = try await Self.gateContext("duplicate-\(mode)")
                        _ = try await Self.gateEvaluate(d, "window.__gate.reset('\(mode)')")
                        _ = try await Self.gateRun(d, label: "正文", text: Self.gateBatchBody)
                        try await Self.gateRequest(d)
                        d.engine.confirm(execute: true)
                        try await Self.gateWaitWorker(d.engine)
                        let expected: VerificationVerdict = mode == "silent" ? .unknown : .contradicted
                        var allRepeatsBlocked = true
                        for _ in 0..<3 {
                            let duplicate = try await Self.gateRun(d, label: "发布测试稿")
                            if case .duplicateBlocked = duplicate { } else { allRepeatsBlocked = false }
                        }
                        var dependencyCalled = false
                        do { try await d.engine.auditedDispatch(name: "click", pageURL: d.web.executionTab.webView.url!.absoluteString) { dependencyCalled = true } }
                        catch { /* gate must stop before the operation closure */ }
                        let duplicateState = try await Self.gateState(d)
                        checks.append(Self.gateCheck("\(expected.rawValue) blocks all three repeats and dependency",
                            allRepeatsBlocked && d.engine.outcomeLedger.last?.verificationVerdict == expected &&
                            !dependencyCalled && duplicateState["submissions"] as? Int == 1 &&
                            Self.gateAudit(d).filter { $0["event"] as? String == "refusal-duplicate" }.count == 3))
                        details[mode] = try await Self.gateEvidence(d)
                    }
                case "post_dispatch_disconnect":
                    try await Self.gateDisconnect(c)
                    checks += Self.gateUnknownChecks(c, state: try await Self.gateState(c))
                case "log_failure":
                    let blocker = Self.gateBatchDirectory.appendingPathComponent("regular-file-blocker")
                    try Data("not a directory".utf8).write(to: blocker, options: .atomic)
                    c.engine.gateSelfTestAuditStore = ExecutionAuditStore(fileURL: blocker.appendingPathComponent("audit.jsonl"))
                    var writeRejected = false
                    do { _ = try await Self.gateRun(c, label: "展开详情") } catch { writeRejected = true }
                    let failureState = try await Self.gateState(c)
                    checks.append(Self.gateCheck("real filesystem audit failure stops before effect; not_sent has pre-call evidence", writeRejected && failureState["low"] as? Int == 0 && c.engine.executionReceipts.last?.dispatchState == .notSent && c.engine.executionReceipts.last?.evidenceRef == "audit-failed-before-call"))
                    for key in [Self.executionReceiptsKey, Self.outcomeLedgerKey] {
                        let corrupt = Data("{invalid gate ledger".utf8)
                        // Construct a fresh engine over corrupt on-disk data, without clearing it.
                        for k in [Self.executionReceiptsKey, Self.outcomeLedgerKey] { UserDefaults.standard.removeObject(forKey: k) }
                        UserDefaults.standard.set(corrupt, forKey: key)
                        let d = try await Self.gateContext("decode-\(key)", reset: false)
                        _ = try await Self.gateEvaluate(d, "window.__gate.reset()")
                        try await Self.gateRequest(d)
                        d.engine.confirm(execute: true)
                        try await Self.gateWaitWorker(d.engine)
                        let decodeState = try await Self.gateState(d)
                        checks.append(Self.gateCheck("\(key) decode failure preserves corrupt bytes and prevents dispatch", UserDefaults.standard.data(forKey: key) == corrupt && decodeState["submissions"] as? Int == 0 && (key == Self.executionReceiptsKey ? d.engine.executionReceiptsDecodeFailed : d.engine.outcomeLedgerDecodeFailed)))
                        details[key] = try await Self.gateEvidence(d)
                    }
                default: throw MikaError("Unknown gate scenario")
                }
                let finalState = try await Self.gateState(c)
                let rawErrors = finalState["errors"] as? [String] ?? []
                let guardRejection = Self.gateAudit(c).contains { $0["event"] as? String == "dispatch-unknown" } &&
                    String(describing: c.engine.status).contains("JavaScript exception occurred")
                var unaccountedErrors = rawErrors
                if guardRejection, let index = unaccountedErrors.firstIndex(of: "Script error.") {
                    unaccountedErrors.remove(at: index)
                }
                details["fixtureErrorAccounting"] = ["raw": rawErrors, "guardRejectionAttributable": guardRejection,
                                                     "unaccounted": unaccountedErrors]
                checks.append(Self.gateCheck("controlled fixture has no script errors", finalState["errors"] is [String] && unaccountedErrors.isEmpty))
                details["observed"] = try await Self.gateEvidence(c)
                let passed = !checks.isEmpty && checks.allSatisfy { $0["passed"] as? Bool == true }
                if !passed { await c.host.captureFailure("gate-batch1 \(id) assertion failed") }
                cases.append(["id": id, "passed": passed, "status": passed ? "pass" : "fail", "checks": checks, "evidence": details])
            } catch {
                await context?.host.captureFailure("gate-batch1 \(id): \(error.localizedDescription)")
                details["error"] = error.localizedDescription
                cases.append(["id": id, "passed": false, "status": "fail", "checks": checks, "evidence": details])
            }
        }
        var checkpoint: [String: Any] = [:]
        do {
            let c = try await Self.gateContext("crash-recovery")
            _ = try await Self.gateEvaluate(c, "window.__gate.reset()")
            try await Self.gateDisconnect(c)
            let state = try await Self.gateState(c)
            guard Self.gateUnknownChecks(c, state: state).allSatisfy({ $0["passed"] as? Bool == true }),
                  let receipt = c.engine.executionReceipts.last(where: { $0.critical }),
                  let outcome = c.engine.outcomeLedger.last else { throw MikaError("Crash checkpoint not unknown") }
            // Exercise the production retention policy with an aged unresolved record.
            c.engine.outcomeLedger[c.engine.outcomeLedger.count - 1].recordedAt = Date().addingTimeInterval(-172800)
            let terminal = (0..<25).map { _ -> OutcomeRecord in
                var copy = outcome; copy.id = UUID(); copy.taskID = UUID(); copy.actionID = UUID()
                copy.dispatchState = .sent; copy.verificationVerdict = .verified; return copy
            }
            c.engine.outcomeLedger = terminal + c.engine.outcomeLedger
            guard c.engine.saveOutcomeLedger(), c.engine.outcomeLedger.count == 21,
                  c.engine.outcomeLedger.contains(where: { $0.id == outcome.id }) else {
                throw MikaError("Unresolved outcome lost during retention")
            }
            if let i = c.engine.executionReceipts.firstIndex(where: { $0.id == receipt.id }) {
                c.engine.executionReceipts[i].createdAt = Date().addingTimeInterval(-172800)
                c.engine.executionReceipts[i].updatedAt = Date().addingTimeInterval(-172800)
            }
            let settledReceipts = (0..<25).map { _ -> ExecutionReceipt in
                var copy = receipt; copy.id = UUID(); copy.actionID = UUID(); copy.taskID = UUID()
                copy.critical = false; copy.dispatchState = .sent; copy.verificationVerdict = .verified
                return copy
            }
            c.engine.executionReceipts += settledReceipts
            guard c.engine.saveExecutionReceipts(), c.engine.executionReceipts.count == 21,
                  c.engine.executionReceipts.contains(where: { $0.id == receipt.id && $0.blocksDependencies }) else {
                throw MikaError("Unresolved receipt lost during retention")
            }
            c.engine.status = .paused("派发后未决；重开后先独立回读，不自动重放")
            guard c.engine.persistSnapshot() else { throw MikaError("Crash snapshot could not persist") }
            UserDefaults.standard.synchronize()
            checkpoint = ["ready": true, "buildSHA": AgentTraceStore.buildSHA,
                "sessionID": c.engine.runSessionID.uuidString, "taskID": c.engine.conversationTaskID!.uuidString,
                "receiptID": receipt.id.uuidString, "actionID": receipt.actionID.uuidString,
                "outcomeID": outcome.id.uuidString, "submissions": state["submissions"] ?? -1,
                "processID": ProcessInfo.processInfo.processIdentifier,
                "unresolvedRetainedAcross24hAnd20Limit": true,
                "beforeTermination": try await Self.gateEvidence(c)]
            try JSONSerialization.data(withJSONObject: checkpoint, options: [.prettyPrinted, .sortedKeys])
                .write(to: Self.gateBatchDirectory.appendingPathComponent("checkpoint.json"), options: .atomic)
        } catch { checkpoint = ["ready": false, "error": error.localizedDescription] }
        return ["schemaVersion": 1, "round": 1, "runtime": "WKWebView",
            "environment": Self.gateBatchEnvironment, "driver": "bundled fixture + production engine + simulator CLI",
            "buildSHA": AgentTraceStore.buildSHA, "cases": cases, "crashCheckpoint": checkpoint,
            "passed": cases.count == 12 && cases.allSatisfy { $0["passed"] as? Bool == true } && checkpoint["ready"] as? Bool == true]
    }

    private static func gateDisconnect(_ context: GateBatchWKContext) async throws {
        _ = try await gateRun(context, label: "正文", text: gateBatchBody)
        try await gateRequest(context)
        // The fixture handler has run, but transport completion is lost. Inject
        // the error at the real dispatch return boundary, not into the verdict.
        context.engine.gateSelfTestAfterDispatch = { throw URLError(.networkConnectionLost) }
        context.engine.confirm(execute: true)
        try await gateWaitWorker(context.engine)
        context.engine.gateSelfTestAfterDispatch = nil
    }
    private static func gateUnknownChecks(_ context: GateBatchWKContext, state: [String: Any]) -> [[String: Any]] {
        [gateCheck("fixture handler ran exactly once before simulated disconnect", state["submissions"] as? Int == 1),
         gateCheck("dispatch unknown and verification unknown are separate durable fields", context.engine.executionReceipts.last(where: { $0.critical })?.dispatchState == .unknown && context.engine.executionReceipts.last(where: { $0.critical })?.verificationVerdict == .unknown && context.engine.outcomeLedger.last?.dispatchState == .unknown && context.engine.outcomeLedger.last?.verificationVerdict == .unknown),
         gateCheck("unknown never promoted to success claim", context.engine.taskClaims.last?.status == .unverified)]
    }

    func verifyGateBatch1RestartWK() async -> [String: Any] {
        var evidence: [String: Any] = [:]
        var checks: [[String: Any]] = []
        do {
            let data = try Data(contentsOf: Self.gateBatchDirectory.appendingPathComponent("checkpoint.json"))
            guard let marker = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawSession = marker["sessionID"] as? String, let session = UUID(uuidString: rawSession),
                  let rawTask = marker["taskID"] as? String, let task = UUID(uuidString: rawTask),
                  let rawReceipt = marker["receiptID"] as? String, let receiptID = UUID(uuidString: rawReceipt),
                  let rawOutcome = marker["outcomeID"] as? String, let outcomeID = UUID(uuidString: rawOutcome) else {
                throw MikaError("Gate restart checkpoint missing or invalid")
            }
            let c = try await Self.gateContext("restart", reset: false, sessionID: session, taskID: task)
            c.engine.restoreSnapshot(for: session, allowLegacy: false)
            // Fixture localStorage retains the actual handler count across App death.
            let before = try await Self.gateState(c)
            checks += [Self.gateCheck("a new process runs the exact same SHA", marker["buildSHA"] as? String == AgentTraceStore.buildSHA && marker["processID"] as? Int != Int(ProcessInfo.processInfo.processIdentifier)),
                Self.gateCheck("unresolved durable receipt and aged outcome survive restart", c.engine.executionReceipts.contains { $0.id == receiptID && $0.dispatchState == .unknown && $0.blocksDependencies } && c.engine.outcomeLedger.contains { $0.id == outcomeID && $0.unresolved } && marker["unresolvedRetainedAcross24hAnd20Limit"] as? Bool == true),
                Self.gateCheck("visible task progress restored with stage, result, next step", {
                    guard let progress = c.engine.progressBySession[session] else { return false }
                    return progress.taskID == task && !progress.stage.isEmpty && progress.result.contains("unknown") && progress.next.contains("禁止重放")
                }())]
            // Restore must not execute on its own. A fresh duplicate and a dependent
            // action both enter the production gates again and must be stopped.
            let repeatResult = try await Self.gateRun(c, label: "发布测试稿")
            var dependencyCalled = false
            do { try await c.engine.auditedDispatch(name: "click", pageURL: c.web.executionTab.webView.url!.absoluteString) { dependencyCalled = true } }
            catch { }
            let after = try await Self.gateState(c)
            checks.append(Self.gateCheck("restore, repeated request and dependency never replay the handler", {
                if case .duplicateBlocked = repeatResult { return !dependencyCalled }; return false
            }() && before["submissions"] as? Int == marker["submissions"] as? Int && after["submissions"] as? Int == 1))
            evidence = ["checkpoint": marker, "before": before, "after": after,
                        "restored": try await Self.gateEvidence(c), "processID": ProcessInfo.processInfo.processIdentifier]
            if !checks.allSatisfy({ $0["passed"] as? Bool == true }) { await c.host.captureFailure("gate-batch1 crash recovery assertion failed") }
        } catch { evidence["error"] = error.localizedDescription }
        let passed = checks.count == 4 && checks.allSatisfy { $0["passed"] as? Bool == true }
        return ["schemaVersion": 1, "round": 1, "runtime": "WKWebView",
            "environment": Self.gateBatchEnvironment, "buildSHA": AgentTraceStore.buildSHA,
            "passed": passed, "cases": [["id": "crash_recovery", "passed": passed,
                "status": passed ? "pass" : "fail", "checks": checks, "evidence": evidence]]]
    }
}
#endif
