import Foundation

struct ReadbackTabRegistry: Equatable {
    struct Entry: Equatable {
        let tabID: UUID
        let ownerTaskID: UUID
        let sourceTabID: UUID
        let purpose: String
    }

    private(set) var entries: [UUID: Entry] = [:]

    /// A second readback replaces the first registration and returns its tab ID for safe recycling.
    mutating func register(tabID: UUID, ownerTaskID: UUID, sourceTabID: UUID, purpose: String) -> UUID? {
        let previous = purpose == "readback" ? readbackTab(forTask: ownerTaskID) : nil
        if let previous, previous != tabID { entries.removeValue(forKey: previous) }
        entries[tabID] = Entry(tabID: tabID, ownerTaskID: ownerTaskID, sourceTabID: sourceTabID, purpose: purpose)
        return previous == tabID ? nil : previous
    }

    func readbackTab(forTask taskID: UUID) -> UUID? {
        entries.values.first { $0.ownerTaskID == taskID && $0.purpose == "readback" }?.tabID
    }

    func tabsToRecycle(forTask taskID: UUID) -> [UUID] {
        entries.values.filter { $0.ownerTaskID == taskID && $0.purpose == "readback" }.map(\.tabID)
    }

    mutating func unregister(tabID: UUID) { entries.removeValue(forKey: tabID) }
    mutating func endTask(_ taskID: UUID) { entries = entries.filter { $0.value.ownerTaskID != taskID } }
}
