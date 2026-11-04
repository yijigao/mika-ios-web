import Foundation

enum DrawerSessionOrdering {
    static func split(_ sessions: [SessionMeta]) -> (pinned: [SessionMeta], rest: [SessionMeta]) {
        let pinned = sessions.filter(\.pinned).sorted { $0.lastActiveAt > $1.lastActiveAt }
        let rest = sessions.filter { !$0.pinned }.sorted { $0.lastActiveAt > $1.lastActiveAt }
        return (pinned, rest)
    }
}
