import AppIntents
import SwiftUI
@MainActor final class PendingTaskStore: ObservableObject {
    static let shared = PendingTaskStore()
    @Published var task: String?
}
struct MikaWebTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "用 Mika Web 执行任务"
    static var description = IntentDescription("打开 Mika Web 并预填任务。任务在 App 前台内执行。")
    static var openAppWhenRun: Bool = true
    @Parameter(title: "任务") var task: String
    @MainActor func perform() async throws -> some IntentResult {
        PendingTaskStore.shared.task = task
        return .result()
    }
}
struct MikaWebShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: MikaWebTaskIntent(), phrases: ["用 \(.applicationName) 执行任务"], shortTitle: "执行网页任务", systemImageName: "globe")
    }
}
