import Foundation

// 跨步循环检测与分级熔断（ADOPTION-TOP3 第 2 条，2026-11-02）：
// 模型在两页之间打转、或反复对同一元素执行同一动作时，旧引擎只有步数上限兜底，
// 只能白白耗尽步数（Joey 在 OpenMinis 上实测死于 26 步耗尽，同型风险）。本检测器
// 把每一步的（动作＋目标＋结果）压成指纹记入滑动窗口，按同一指纹的重复次数分级：
//   ≥ warningThreshold(3)：一级提醒——引擎把换做法的要求注入下一步提示；
//   ≥ severeThreshold(5)：二级严重提醒——明示再重复将自动停下；
//   ≥ tripThreshold(7)：熔断——引擎把会话停驻为「真正停驻」（已暂停，可继续），
//     由用户决定是让它再试还是换个说法重来。
// 阈值按我方步数上限（5–50，默认 25）的量级适配（所参考设计的 10/20/30 面向其
// 更长任务设定，原样搬过来在我方步数耗尽前几乎不会触发）；窗口 30 条。同一指纹
// 的同一级别只报一次（级别台账），避免提醒本身在历史里刷屏；熔断后清掉该指纹的
// 窗口记录，用户点继续后从零重新计数、不会一恢复就立刻再熔断。
// 与既有机制的关系：不改步数上限（熔断是更早、更具体的停驻）；瞬时错误重试是
// 「单步失败恢复」，本检测是「多步成功但无进展」的识别，两者正交；安全确认门在
// 执行前判定，本检测只观察已执行动作的结果，不参与放行。
struct LoopDetector {
    enum Level: Int, Comparable {
        case none = 0, warning = 1, severe = 2, tripped = 3
        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    struct Verdict {
        let level: Level
        /// 该指纹在窗口内的累计重复次数（含本次）
        let count: Int
    }

    static let windowSize = 30
    static let warningThreshold = 3
    static let severeThreshold = 5
    static let tripThreshold = 7

    private var window: [String] = []
    /// 指纹 → 已宣布过的最高提醒级别（熔断不入台账，熔断即清窗口另行处理）
    private var announced: [String: Int] = [:]

    mutating func reset() {
        window.removeAll()
        announced.removeAll()
    }

    /// 记入一步并给出裁决。level 为 .warning/.severe 时只在该指纹首次跨入该级别
    /// 时返回（后续同级重复返回 .none）；.tripped 每次达阈都返回（引擎随即停驻，
    /// 本函数已把该指纹的窗口记录清掉，恢复后重新计数）。
    mutating func record(fingerprint: String) -> Verdict {
        window.append(fingerprint)
        if window.count > Self.windowSize { window.removeFirst(window.count - Self.windowSize) }
        let count = window.reduce(0) { $0 + ($1 == fingerprint ? 1 : 0) }
        if count >= Self.tripThreshold {
            window.removeAll { $0 == fingerprint }
            announced[fingerprint] = nil
            return Verdict(level: .tripped, count: count)
        }
        let level: Level = count >= Self.severeThreshold ? .severe : (count >= Self.warningThreshold ? .warning : .none)
        guard level > .none else { return Verdict(level: .none, count: count) }
        let highest = announced[fingerprint] ?? 0
        guard level.rawValue > highest else { return Verdict(level: .none, count: count) }
        announced[fingerprint] = level.rawValue
        return Verdict(level: level, count: count)
    }

    /// 指纹构成：动作名＋目标稳定标识＋结果标签，FNV-1a 压成十六进制串。
    /// 目标标识由引擎侧给出（click/type 用元素稳定描述键、navigate 用网址、
    /// scroll 用方向、type 另掺入输入文本指纹——同元素换内容不算同动作）。
    static func fingerprint(action: String, target: String, outcome: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in "\(action)\u{1}\(target)\u{1}\(outcome)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    /// 文本指纹（type 动作区分「同元素同内容」与「同元素换内容」用）：只出哈希。
    static func textFingerprint(_ text: String) -> String {
        fingerprint(action: "text", target: text, outcome: "")
    }
}
