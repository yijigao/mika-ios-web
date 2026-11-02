import Foundation

// 动作后核验合约（VERIFY-1，2026-11-03）：独立于执行者的事后判定层。
//
// 缘起（Tapilot 吸收评估终审，案卷 research_notes/tapilot-2026-11-03）：
// 我方已有零件——成果台账（提交留痕＋防重复）、编辑器自报状态校验
// （type 路径的计数/保存落定硬口径）——缺的是把「关键动作执行完 ≠ 完成」
// 变成覆盖全部提交类动作的统一合约：动作执行后由本层用新鲜证据独立
// 判定 verified / contradicted / unknown，只有 verified 才算数；
// unknown 绝不触发重放。本单是窄版试点：
// - 覆盖范围＝成果台账的提交类动作集合（SubmissionClassifier，click 路径
//   落记时触发），普通浏览动作（滚动/展开/导航）不纳入；
// - shadow 先行：三值只落盘记录＋步流提示，不改变台账落记与软门行为，
//   不阻断、不重发；转正式阻断门的门槛留待按 shadow 数据另行裁决；
// - 判定以确定性断言与服务端回读为主（页面正文区出现提交内容、跳转＋
//   成功文案、编辑器自报状态类证据），toast 与接口成功只是弱证据、
//   单独不构成 verified。本版不调模型核验：断言不 conclusive 即
//   unknown——避免「同模型二次意见」式的核验表演（终审反例口径），
//   模型兜底待 shadow 数据证明有必要时再议。
// - 唯一硬口径沿用不动：type 路径的编辑器校验（计数冻结不过、保存未
//   落定不报成功）在 WebController，本层不碰、不回退。

/// 核验三值：verified＝有 conclusive 证据证明动作已落定；
/// contradicted＝有 conclusive 证据证明动作没落定（页面明确拒绝等），
/// 与执行器自报构成分歧；unknown＝证据不足以下结论（含证据未稳）。
enum VerificationVerdict: String, Codable {
    case verified, contradicted, unknown
}

/// 取证采样的一帧：settle 窗口内探针抽到的页面地址与可见正文。
/// toast 一类短暂提示只活在采样帧里——它存在的意义是被记为弱证据，
/// 同时证明「只有 toast」不够判 verified。
struct VerificationSample {
    let url: String
    let text: String
}

/// 一条核验记录（台账旁记录）：每个被台账落记的提交类动作一行，
/// append-only 落盘 verification-log.jsonl（一行一条 JSON）。
/// 只存证据引用（文案片段/地址/计数），不存正文全文、不存凭据。
struct VerificationRecord: Codable, Identifiable {
    var id: UUID
    /// ISO8601 时间串（人可读，日志里直接可查）
    var recordedAt: String
    var sessionID: String
    /// 关联的成果台账条目 id（自检合成记录为 nil）
    var outcomeRecordID: UUID?
    /// 被核验动作的人读标识：提交类按钮文案
    var actionLabel: String
    var pageURL: String
    var host: String
    var verdict: VerificationVerdict
    /// conclusive 证据引用（判定依据，逐条人话＋原文片段）
    var evidence: [String]
    /// 弱证据（toast/单独成功文案/单独跳转等）：只记不用作 verified 依据
    var weakEvidence: [String]
    /// 取证收口形态："settled"（页面静默＋网络空闲后取证）或
    /// "timeout（证据未稳）"（有界超时，超时不算成功）
    var settleOutcome: String
    /// 执行器自报（本合约的对照面）：动作已执行、台账记为已提交待核查
    var executorClaim: String
    /// 是否分歧：verdict == contradicted 即自报与核验分歧
    var diverged: Bool
}

/// 核验记录的落盘与统计：append-only JSONL。正式日志在
/// Application Support/MikaWeb/verification-log.jsonl；自检用临时文件
/// 实例（同一实现、独立路径，合成记录不污染 shadow 统计）。
final class VerificationLogStore {
    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MikaWeb/verification-log.jsonl")
    }
    static let shared = VerificationLogStore(fileURL: VerificationLogStore.defaultFileURL)
    let fileURL: URL
    init(fileURL: URL) { self.fileURL = fileURL }

    func append(_ record: VerificationRecord) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record) else { return }
        var line = data
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: fileURL, options: [.atomic])
        }
    }

    func loadAll() -> [VerificationRecord] {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return raw.split(separator: "\n").compactMap { line in
            try? decoder.decode(VerificationRecord.self, from: Data(line.utf8))
        }
    }

    /// shadow 分歧统计口径：总数、三值分布、分歧数（contradicted 数，
    /// 与 diverged 计数互为校验）。误杀/精确率需人工复核标注，不在此
    /// 自动计算（见案卷的统计口径节）。
    struct Stats {
        var total = 0, verified = 0, contradicted = 0, unknown = 0, diverged = 0
    }
    func stats(from records: [VerificationRecord]? = nil) -> Stats {
        let all = records ?? loadAll()
        var s = Stats()
        s.total = all.count
        for r in all {
            switch r.verdict {
            case .verified: s.verified += 1
            case .contradicted: s.contradicted += 1
            case .unknown: s.unknown += 1
            }
            if r.diverged { s.diverged += 1 }
        }
        return s
    }
}

/// 确定性判定器（纯函数，无副作用）：输入动作前快照、settle 后快照、
/// 采样帧与提交内容前缀，输出三值＋证据引用。自检十三以合成页＋本
/// 函数双路验证同一口径（页面驱动走 WebController，判定只经此函数）。
enum ActionVerifier {
    /// 页面明确拒绝/失败的文案标记：须是动作后新出现的（动作前页面
    /// 本来就有的不算），命中即 contradicted 的 conclusive 证据。
    static let rejectionMarkers = ["提交失败", "发布失败", "保存失败", "发送失败", "操作失败",
                                   "被拒绝", "未通过", "不能为空", "不可为空",
                                   "请先填写", "请先输入", "敏感词", "内容违规"]
    /// 成功类文案标记：单独出现只是弱证据（页面自称成功≠已落定），
    /// 须与跳转或回读之一组合才进 verified 判定。
    static let successMarkers = ["发布成功", "提交成功", "保存成功", "发送成功", "更新成功",
                                 "已发布", "已提交", "已保存", "已发送", "审核中", "发布完成"]

    struct Result {
        let verdict: VerificationVerdict
        let evidence: [String]
        let weakEvidence: [String]
    }

    /// 证据片段：取标记前后各约 18 字的人读引用（日志里可核对原文）。
    private static func snippet(in text: String, around marker: String) -> String {
        guard let range = text.range(of: marker) else { return marker }
        let start = text.index(range.lowerBound, offsetBy: -18, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 18, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func occurrences(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return text.components(separatedBy: needle).count - 1
    }

    /// 三值判定（优先级自上而下）：
    /// 1. 动作后新出现明确拒绝/失败文案 → contradicted；
    /// 2. 回读证据：提交内容前缀在动作后正文里的出现次数较动作前增加
    ///    （内容进了列表/详情等正文区，不再只躺在编辑器里）→ verified；
    /// 3. 页面跳转＋新出现成功文案 → verified；
    /// 4. 其余 → unknown：单独成功文案、单独跳转、采样帧里的 toast
    ///    均只记弱证据。证据未稳（settle 超时）时 verified 一律降为
    ///    unknown（超时不算成功），contradicted 不降（明确拒绝文案
    ///    本身是 conclusive 的否定证据）。
    static func judge(before: PageState, after: PageState, samples: [VerificationSample],
                      settled: Bool, contentPrefix: String) -> Result {
        var evidence: [String] = []
        var weak: [String] = []
        let beforeText = before.text, afterText = after.text

        // 1) 拒绝/失败文案（动作后或采样期间新出现）
        for marker in rejectionMarkers {
            if afterText.contains(marker), !beforeText.contains(marker) {
                evidence.append("页面新出现拒绝/失败文案：「\(snippet(in: afterText, around: marker))」")
                return Result(verdict: .contradicted, evidence: evidence, weakEvidence: weak)
            }
            if !afterText.contains(marker), samples.contains(where: { $0.text.contains(marker) && !$0.text.isEmpty }) {
                if let frame = samples.first(where: { $0.text.contains(marker) }) {
                    evidence.append("取证采样期间页面出现拒绝/失败文案：「\(snippet(in: frame.text, around: marker))」")
                    return Result(verdict: .contradicted, evidence: evidence, weakEvidence: weak)
                }
            }
        }

        // 2) 回读证据：内容前缀出现次数增加（规范化后比对，前 12 字作针，
        //    列表截断展示时仍可命中）
        let needle = String(ElementDescriptor.norm(contentPrefix).prefix(12))
        var contentReadback = false
        if !needle.isEmpty {
            let beforeNorm = ElementDescriptor.norm(beforeText)
            let afterNorm = ElementDescriptor.norm(afterText)
            let beforeCount = occurrences(of: needle, in: beforeNorm)
            let afterCount = occurrences(of: needle, in: afterNorm)
            if afterCount > beforeCount {
                contentReadback = true
                evidence.append("回读证据：提交内容「\(needle)…」在页面正文的出现次数由 \(beforeCount) 增至 \(afterCount)（已进入列表/详情等正文区，不再只在编辑器里）")
            }
        }

        // 3) 跳转＋成功文案
        let urlChanged = after.url != before.url
        if urlChanged {
            evidence.append("动作后页面跳转：\(before.url) → \(after.url)")
        }
        var successNew: String?
        for marker in successMarkers where afterText.contains(marker) && !beforeText.contains(marker) {
            successNew = marker
            break
        }
        if let successNew {
            if contentReadback || urlChanged {
                evidence.append("页面新出现成功文案：「\(snippet(in: afterText, around: successNew))」")
            } else {
                weak.append("页面新出现成功文案「\(successNew)」但无回读/跳转佐证（页面自称成功不单独构成 verified）")
            }
        }

        // 4) toast 类弱证据：采样帧里出现过成功文案、收口快照里已消失
        for marker in successMarkers where !afterText.contains(marker) {
            if let frame = samples.first(where: { $0.text.contains(marker) }) {
                weak.append("取证采样期间出现短暂提示含「\(marker)」：「\(snippet(in: frame.text, around: marker))」（toast 只证明被接受，不证明已落定）")
                break
            }
        }
        if urlChanged, !contentReadback, successNew == nil {
            weak.append("仅有页面跳转，无回读证据与成功文案佐证")
        }

        var verdict: VerificationVerdict = .unknown
        if contentReadback || (urlChanged && successNew != nil) { verdict = .verified }
        if !settled {
            evidence.append("证据未稳：取证窗口内页面未静默/网络未空闲，有界超时收口——超时不算成功")
            if verdict == .verified { verdict = .unknown }
        }
        return Result(verdict: verdict, evidence: evidence, weakEvidence: weak)
    }

    /// 记录组装（引擎落记与自检共用同一形状）：执行器自报口径写死为
    /// 对照面，分歧＝verdict 为 contradicted。
    static func makeRecord(sessionID: String, outcomeRecordID: UUID?, actionLabel: String,
                           pageURL: String, result: Result, settled: Bool) -> VerificationRecord {
        VerificationRecord(
            id: UUID(),
            recordedAt: ISO8601DateFormatter().string(from: Date()),
            sessionID: sessionID,
            outcomeRecordID: outcomeRecordID,
            actionLabel: actionLabel,
            pageURL: pageURL,
            host: URL(string: pageURL)?.host ?? "",
            verdict: result.verdict,
            evidence: result.evidence,
            weakEvidence: result.weakEvidence,
            settleOutcome: settled ? "settled" : "timeout（证据未稳）",
            executorClaim: "执行器自报：动作已执行、成果台账记为「已提交（待核查）」",
            diverged: result.verdict == .contradicted)
    }
}
