import SwiftUI
@MainActor final class SettingsStore: ObservableObject {
    @Published var baseURL = UserDefaults.standard.string(forKey: "baseURL") ?? "https://api.openai.com/v1" { didSet { UserDefaults.standard.set(baseURL, forKey: "baseURL") } }
    @Published var model = UserDefaults.standard.string(forKey: "model") ?? "gpt-4o-mini" { didSet { UserDefaults.standard.set(model, forKey: "model") } }
    @Published var maxSteps = UserDefaults.standard.object(forKey: "maxSteps") as? Int ?? 25 { didSet { UserDefaults.standard.set(min(50, max(5, maxSteps)), forKey: "maxSteps") } }
    @Published private(set) var hasKey = !Keychain.read().isEmpty
    func saveKey(_ key: String) throws { try Keychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines)); hasKey = !Keychain.read().isEmpty }
}
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @State private var key = ""
    @State private var message = ""
    var body: some View {
        Form {
            Section("模型接口") {
                Menu("Base URL 快捷项") {
                    Button("OpenAI") { settings.baseURL = "https://api.openai.com/v1" }
                    Button("DeepSeek") { settings.baseURL = "https://api.deepseek.com" }
                    Button("OpenRouter") { settings.baseURL = "https://openrouter.ai/api/v1" }
                }
                TextField("Base URL", text: $settings.baseURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("模型名", text: $settings.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("新 API Key", text: $key)
                Button("保存 API Key") { do { try settings.saveKey(key); key = ""; message = "已保存" } catch { message = error.localizedDescription } }
                Button("删除 API Key", role: .destructive) { do { try settings.saveKey(""); message = "已删除" } catch { message = error.localizedDescription } }
                Text(settings.hasKey ? "已配置 API Key（Keychain）" : "未配置 API Key")
                Text(message)
            }
            Stepper("最大步数：\(settings.maxSteps)", value: $settings.maxSteps, in: 5...50)
            Text("网页内容及任务会发送至所选模型服务。任务在 App 前台内执行。")
        }.navigationTitle("设置")
    }
}
