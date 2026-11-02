import SwiftUI
enum ModelProvider: String, CaseIterable, Identifiable {
    case deepseek, openai, openrouter, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .openai: return "OpenAI"
        case .openrouter: return "OpenRouter"
        case .custom: return "自定义"
        }
    }
    var presetBaseURL: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com"
        case .openai: return "https://api.openai.com/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .custom: return ""
        }
    }
    var presetModel: String {
        switch self {
        case .deepseek: return "deepseek-chat"
        case .openai: return "gpt-4o-mini"
        case .openrouter: return "openai/gpt-4o-mini"
        case .custom: return ""
        }
    }
    var suggestedModels: [String] {
        switch self {
        case .deepseek: return ["deepseek-chat", "deepseek-reasoner", "deepseek-flash", "deepseek-v4-pro"]
        case .openai: return ["gpt-4o-mini", "gpt-4o"]
        case .openrouter: return ["openai/gpt-4o-mini"]
        case .custom: return []
        }
    }
    var exampleModel: String { suggestedModels.first ?? "你的网关支持的模型名" }
    var keyGuide: String {
        switch self {
        case .deepseek: return "获取 Key：打开 platform.deepseek.com，登录后进入「API Keys」创建。"
        case .openai: return "获取 Key：打开 platform.openai.com，登录后进入「API Keys」创建。"
        case .openrouter: return "获取 Key：打开 openrouter.ai，登录后进入「Keys」创建。"
        case .custom: return "在你所用服务商的控制台创建 Key，并填写它的 OpenAI 兼容地址与模型名。"
        }
    }
}
struct ModelNameValidationIssue {
    enum Kind { case empty, providerTitle }
    let kind: Kind
    let message: String
}
@MainActor final class SettingsStore: ObservableObject {
    @Published var baseURL = UserDefaults.standard.string(forKey: "baseURL") ?? "https://api.openai.com/v1" { didSet { UserDefaults.standard.set(baseURL, forKey: "baseURL") } }
    @Published var model = UserDefaults.standard.string(forKey: "model") ?? "gpt-4o-mini" { didSet { UserDefaults.standard.set(model, forKey: "model") } }
    @Published var maxSteps: Int { didSet {
        let normalized = min(50, max(5, maxSteps))
        if maxSteps != normalized { maxSteps = normalized; return }
        UserDefaults.standard.set(normalized, forKey: "maxSteps")
    } }
    /// 任务期防锁屏（BACKGROUND-RESILIENCE 层 4）：默认开，会话活跃期禁用自动锁屏、
    /// 会话结束恢复；持久化在 UserDefaults，引擎订阅本属性即时应用。
    @Published var keepScreenAwakeDuringTask = UserDefaults.standard.object(forKey: "keepScreenAwakeDuringTask") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepScreenAwakeDuringTask, forKey: "keepScreenAwakeDuringTask") }
    }
    @Published private(set) var provider: ModelProvider
    @Published private(set) var hasKey = !Keychain.read().isEmpty
    static func validateModelName(_ rawValue: String, provider: ModelProvider) -> ModelNameValidationIssue? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let extra = provider == .custom ? " 请以你的网关支持的模型名为准。" : ""
        if value.isEmpty { return ModelNameValidationIssue(kind: .empty, message: "请填写模型名。例如：\(provider.exampleModel)。\(extra)") }
        if ModelProvider.allCases.contains(where: { $0.title.compare(value, options: .caseInsensitive) == .orderedSame }) {
            return ModelNameValidationIssue(kind: .providerTitle, message: "这看起来是服务商的名字，不是模型名。请填写具体模型名，例如：\(provider.exampleModel)。\(extra)")
        }
        return nil
    }
    init() {
        let savedSteps = UserDefaults.standard.object(forKey: "maxSteps") as? Int ?? 25
        let normalizedSteps = min(50, max(5, savedSteps))
        maxSteps = normalizedSteps
        if savedSteps != normalizedSteps { UserDefaults.standard.set(normalizedSteps, forKey: "maxSteps") }
        if let raw = UserDefaults.standard.string(forKey: "provider"), let saved = ModelProvider(rawValue: raw) {
            provider = saved
        } else {
            let url = UserDefaults.standard.string(forKey: "baseURL") ?? "https://api.openai.com/v1"
            provider = ModelProvider.allCases.first(where: { $0 != .custom && $0.presetBaseURL == url }) ?? .custom
        }
    }
    func applyProvider(_ picked: ModelProvider) {
        provider = picked
        UserDefaults.standard.set(picked.rawValue, forKey: "provider")
        if picked != .custom {
            baseURL = picked.presetBaseURL
            model = picked.presetModel
        }
    }
    func saveKey(_ key: String) throws {
        let cleaned = ModelClient.cleanedKey(key)
        if cleaned.isEmpty && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MikaError("粘贴的内容里没有有效的 Key 字符，请重新复制")
        }
        try Keychain.save(cleaned)
        hasKey = !Keychain.read().isEmpty
    }
    func currentKey() -> String { Keychain.read() }
}
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    var diagnostics: DiagnosticStore? = nil
    @State private var key = ""
    @State private var testing = false
    @State private var testSuccess = ""
    @State private var testFailure = ""
    var body: some View {
        Form {
            Section("当前配置") {
                LabeledContent("服务商", value: settings.provider.title)
                LabeledContent("模型", value: settings.model.isEmpty ? "未填写" : settings.model)
                LabeledContent("API Key") {
                    Text(settings.hasKey ? "已配置" : "未配置")
                        .foregroundStyle(settings.hasKey ? .green : .orange)
                        .fontWeight(.medium)
                }
            }
            Section {
                Picker("服务商", selection: Binding(get: { settings.provider }, set: { settings.applyProvider($0); testSuccess = ""; testFailure = "" })) {
                    ForEach(ModelProvider.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }.pickerStyle(.inline).labelsHidden()
                Text("API Key 是你在模型服务商那里申请的一把「钥匙」，Mika Web 每次请模型看网页、做决定都要用它。\(settings.provider.keyGuide)")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Key 只保存在这台手机的钥匙串（Keychain）里，不会发往除你所选服务商以外的任何地方。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("第一步 · 选择模型服务商") }
            Section {
                if settings.provider == .custom {
                    TextField("Base URL（https://…）", text: $settings.baseURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("模型名", text: $settings.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                } else {
                    LabeledContent("接口地址", value: settings.baseURL).font(.caption)
                    TextField("模型名", text: $settings.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("模型名已按 \(settings.provider.title) 预填，一般不用改；接口地址由服务商决定，不可改。需要完全自定义时选「自定义」。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if settings.provider == .custom { Text("请以你的网关支持的模型名为准。").font(.caption).foregroundStyle(.secondary) }
                else {
                    ScrollView(.horizontal) { HStack { ForEach(settings.provider.suggestedModels, id: \.self) { name in Button(name) { settings.model = name } .buttonStyle(.bordered) } } }
                    Text("快捷填写；是否可用以服务商或网关为准。").font(.caption).foregroundStyle(.secondary)
                }
                if let issue = SettingsStore.validateModelName(settings.model, provider: settings.provider) { Text(issue.message).font(.caption).foregroundStyle(.red) }
            } header: { Text("模型与接口地址") }
            Section {
                SecureField("粘贴 API Key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button {
                    Task { await saveAndTest() }
                } label: {
                    HStack {
                        if testing { ProgressView() }
                        Text(testing ? "正在测试连接…" : "保存并测试连接")
                    }
                }.disabled(testing)
                if settings.hasKey && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("输入框留空时，将用已保存的 Key 测试连接。").font(.caption).foregroundStyle(.secondary)
                }
                if !testSuccess.isEmpty {
                    Label(testSuccess, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                }
                if !testFailure.isEmpty {
                    Label(testFailure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout).textSelection(.enabled)
                }
                if settings.hasKey {
                    Button("删除 API Key", role: .destructive) {
                        do { try settings.saveKey(""); key = ""; testSuccess = ""; testFailure = "已删除 API Key" }
                        catch { testFailure = error.localizedDescription }
                    }
                }
            } header: { Text("第二步 · 填 Key 并测试") }
            Section {
                HStack { Text("最大步数"); Spacer(); Text("\(settings.maxSteps)").monospacedDigit().fontWeight(.semibold); Stepper("最大步数", value: $settings.maxSteps, in: 5...50).labelsHidden() }
                Text("达到上限后暂停，可继续任务。").font(.caption).foregroundStyle(.secondary)
                Toggle("任务运行时保持屏幕常亮", isOn: $settings.keepScreenAwakeDuringTask)
                Text("开启时任务执行期间屏幕不会自动锁屏，任务结束自动恢复。").font(.caption).foregroundStyle(.secondary)
                Text("任务执行时，网页内容及你的任务会发送至所选模型服务。切到后台时任务会驻停并保存进度，回到 App 自动接着跑；单步的页面小错误会自动重试，不再一步失败就停下。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("任务") }
            if let diagnostics { Section { NavigationLink("崩溃报告") { CrashReportsView(store: diagnostics) } } }
        }.navigationTitle("设置")
    }
    private func saveAndTest() async {
        testSuccess = ""; testFailure = ""
        if let issue = SettingsStore.validateModelName(settings.model, provider: settings.provider) { testFailure = issue.message; return }
        let pasted = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if !pasted.isEmpty {
                try settings.saveKey(key)
                key = ""
            }
        } catch {
            testFailure = error.localizedDescription
            return
        }
        let effective = settings.currentKey()
        guard !effective.isEmpty else {
            testFailure = "还没有 API Key：请先在上方输入框粘贴 Key，再点「保存并测试连接」。"
            return
        }
        testing = true
        do {
            let reply = try await ModelClient().testConnection(baseURL: settings.baseURL, model: settings.model, key: effective)
            testing = false
            testSuccess = "连接成功：\(settings.provider.title) / \(settings.model)" + (reply.isEmpty ? "" : "（模型回复：\(reply)）")
        } catch {
            testing = false
            testFailure = error.localizedDescription
        }
    }
}
