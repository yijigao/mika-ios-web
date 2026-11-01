import SwiftUI

struct DebugConfig: Sendable {
    let focus: Bool
    let input: Bool
    let scroll: Bool
    let chat: Bool
    let panelState: Bool
    let observe: Bool
    let convSink: Bool
    let panelSink: Bool
    let diag: Bool
    let geo: Bool
}

enum DebugSwitches {
    static let focusKey = "dbg.F_FOCUS"
    static let inputKey = "dbg.F_INPUT"
    static let scrollKey = "dbg.F_SCROLL"
    static let chatKey = "dbg.F_CHAT"
    static let panelStateKey = "dbg.F_PANELSTATE"
    static let observeKey = "dbg.F_OBSERVE"
    static let convSinkKey = "dbg.F_CONVSINK"
    static let panelSinkKey = "dbg.F_PANELSINK"
    static let diagKey = "dbg.F_DIAG"
    static let geoKey = "dbg.F_GEO"
    static let activeSummaryKey = "dbg.activeSummary"

    static let launchConfig: DebugConfig = {
        let defaults = UserDefaults.standard
        func enabled(_ key: String) -> Bool {
            defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
        }

        let config = DebugConfig(
            focus: enabled(focusKey),
            input: enabled(inputKey),
            scroll: enabled(scrollKey),
            chat: enabled(chatKey),
            panelState: enabled(panelStateKey),
            observe: enabled(observeKey),
            convSink: enabled(convSinkKey),
            panelSink: enabled(panelSinkKey),
            diag: enabled(diagKey),
            geo: enabled(geoKey)
        )

        let disabled: [String] = [
            config.focus ? nil : "F_FOCUS",
            config.input ? nil : "F_INPUT",
            config.scroll ? nil : "F_SCROLL",
            config.chat ? nil : "F_CHAT",
            config.panelState ? nil : "F_PANELSTATE",
            config.observe ? nil : "F_OBSERVE",
            config.convSink ? nil : "F_CONVSINK",
            config.panelSink ? nil : "F_PANELSINK",
            config.diag ? nil : "F_DIAG",
            config.geo ? nil : "F_GEO"
        ].compactMap { $0 }
        defaults.set(
            disabled.isEmpty ? "全开（基线）" : "关：" + disabled.joined(separator: "、"),
            forKey: activeSummaryKey
        )
        return config
    }()
}

struct StaticChatView: View {
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mika 助手").font(.headline)
                    Text("就绪 · 已记录步骤 0／本任务上限 10")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button {} label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }
                    .accessibilityLabel("收起助手")
                    .disabled(true)
            }
            VStack(alignment: .leading, spacing: 8) {
                bubble("你好，Mika。", user: true)
                bubble("你好！这是诊断用的静态聊天预览。", user: false)
                bubble("消息内容不会实时更新。", user: false)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 4)
            HStack(alignment: .bottom, spacing: 6) {
                Text("输入网页任务")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                Button("发送") {}
                    .disabled(true).buttonStyle(.borderedProminent)
            }
            HStack(spacing: 8) {
                Button("停止") {}.disabled(true)
                Button("继续") {}.disabled(true)
                Spacer()
            }
            .buttonStyle(.bordered)
            .font(.caption)
        }
        .padding(12)
    }

    private func bubble(_ message: String, user: Bool) -> some View {
        Text(message)
            .font(.callout)
            .padding(9)
            .frame(maxWidth: .infinity, alignment: user ? .trailing : .leading)
            .background(user ? Color.blue.opacity(0.14) : Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct DebugChatPlaceholder: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Mika 助手").font(.headline)
            Text("聊天面板内容已停用（诊断）")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DebugSwitchesSection: View {
    @AppStorage(DebugSwitches.focusKey) private var focus = true
    @AppStorage(DebugSwitches.inputKey) private var input = true
    @AppStorage(DebugSwitches.scrollKey) private var scroll = true
    @AppStorage(DebugSwitches.chatKey) private var chat = true
    @AppStorage(DebugSwitches.panelStateKey) private var panelState = true
    @AppStorage(DebugSwitches.observeKey) private var observe = true
    @AppStorage(DebugSwitches.convSinkKey) private var convSink = true
    @AppStorage(DebugSwitches.panelSinkKey) private var panelSink = true
    @AppStorage(DebugSwitches.diagKey) private var diag = true
    @AppStorage(DebugSwitches.geoKey) private var geo = true
    @AppStorage(DebugSwitches.activeSummaryKey) private var activeSummary = "全开（基线）"

    var body: some View {
        Section {
            Text("这些开关只在 App 冷启动时读取，改动后请完全退出 App 再重新打开才生效。全部开启＝当前正式版行为。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Toggle("焦点绑定（F_FOCUS）", isOn: $focus)
            Toggle("聊天输入框（F_INPUT）", isOn: $input)
            Toggle("消息滚动区（F_SCROLL）", isOn: $scroll)
            Toggle("聊天面板内容（F_CHAT）", isOn: $chat)
            Toggle("冷启动展开面板（F_PANELSTATE）", isOn: $panelState)
            Toggle("聊天实时数据（F_OBSERVE）", isOn: $observe)
            Toggle("对话同步订阅（F_CONVSINK）", isOn: $convSink)
            Toggle("面板自动收起订阅（F_PANELSINK）", isOn: $panelSink)
            Toggle("崩溃诊断注册（F_DIAG）", isOn: $diag)
            Toggle("浏览器尺寸回写（F_GEO）", isOn: $geo)
            Text("本进程实际生效：\(activeSummary)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("诊断开关")
        }
    }
}
