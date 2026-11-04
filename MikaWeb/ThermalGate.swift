import Foundation

enum ThermalLevel: Int, Codable, Comparable {
    case nominal = 0, fair = 1, serious = 2, critical = 3

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }

    static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct ThermalGate: Equatable {
    static let cooldownSeconds: Double = 30
    private(set) var level: ThermalLevel = .nominal
    private(set) var coolingSince: Date?

    mutating func update(level newLevel: ThermalLevel, now: Date) {
        let wasLocked = isLocked
        level = newLevel
        if isLocked {
            coolingSince = nil
        } else if wasLocked && coolingSince == nil {
            coolingSince = now
        }
    }

    var isLocked: Bool { level >= .serious }

    func canResume(now: Date) -> Bool {
        guard !isLocked else { return false }
        guard let coolingSince else { return true }
        return now.timeIntervalSince(coolingSince) >= Self.cooldownSeconds
    }

    func allowsHeavyWork() -> Bool { level < .serious }
    func allowsNonEssential() -> Bool { level < .fair }
}
