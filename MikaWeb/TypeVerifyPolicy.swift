import Foundation

enum TypeVerifyPolicy {
    static func useEditorPath(baselineFound: Bool, expectedEditable: Bool, locatedByIndex: Bool, textLength: Int) -> Bool {
        baselineFound && (expectedEditable || locatedByIndex || textLength >= 200)
    }

    enum Verdict: Equatable {
        case pass
        case failFrozen(Int)
        case failSignalLost
        case failDomMissing
    }

    /// expectedCount is needed to compare the editor count with the text being typed.
    static func verdict(baselineCount: Int?, postCount: Int?, textOK: Bool, expectedCount: Int, longForm: Bool) -> Verdict {
        guard textOK else { return .failDomMissing }
        guard let postCount else {
            return baselineCount == nil && !longForm ? .pass : .failSignalLost
        }
        return countConsistent(postCount, expected: expectedCount, baseline: baselineCount)
            ? .pass : .failFrozen(postCount)
    }

    /// Keep the existing count tolerance and baseline growth fallback unchanged.
    static func countConsistent(_ count: Int, expected: Int, baseline: Int?) -> Bool {
        if expected == 0 { return true }
        if count == 0 { return false }
        let low = max(0, Int(Double(expected) * 0.85) - 5)
        let high = Int(Double(expected) * 1.15) + 10
        if count >= low && count <= high { return true }
        if let b = baseline, count > b {
            let growth = count - b
            if growth >= low && growth <= high { return true }
        }
        return false
    }
}
