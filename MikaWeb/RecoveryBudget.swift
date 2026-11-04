struct RecoveryBudget: Codable, Equatable {
    static let maxAttempts = 3
    static let maxLoads = 2
    static let backoffSeconds: [Double] = [2, 5, 10]

    private(set) var attemptsUsed = 0
    private(set) var loadsUsed = 0

    var attemptsRemaining: Int { max(0, Self.maxAttempts - attemptsUsed) }
    var loadsRemaining: Int { max(0, Self.maxLoads - loadsUsed) }

    mutating func reserveAttempt() -> Double? {
        guard attemptsRemaining > 0 else { return nil }
        let backoff = nextBackoff()
        attemptsUsed += 1
        return backoff
    }

    mutating func reserveLoad() -> Bool {
        guard loadsRemaining > 0 else { return false }
        loadsUsed += 1
        return true
    }

    func nextBackoff() -> Double {
        Self.backoffSeconds[min(attemptsUsed, Self.backoffSeconds.count - 1)]
    }
}
