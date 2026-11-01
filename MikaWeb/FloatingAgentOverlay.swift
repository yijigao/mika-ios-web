import SwiftUI

struct FloatingAgentOverlay: View {
    @ObservedObject var panel: FloatingPanelStore
    @ObservedObject var conversation: AgentConversationStore
    @ObservedObject var engine: AgentEngine
    @ObservedObject var settings: SettingsStore
    @FocusState private var inputFocused: Bool
    @State private var dragOffset: CGSize = .zero
    @State private var dragging = false
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let radius: CGFloat = 30
            let margin: CGFloat = 20
            let y = radius + margin + panel.verticalFraction * max(0, height - 2 * (radius + margin))
            ZStack(alignment: .topLeading) {
                if panel.expanded {
                    AgentChatView(engine: engine, settings: settings, conversation: conversation, panel: panel, inputFocused: $inputFocused)
                        .frame(width: width, height: min(height * 0.55, max(240, height - 12)))
                        .background(.regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))
                        .shadow(radius: 12)
                        .position(x: width / 2, y: height - min(height * 0.55, max(240, height - 12)) / 2)
                } else {
                    Button { if !dragging { panel.expand() } } label: {
                        ZStack(alignment: .bottomTrailing) {
                            Circle().fill(.regularMaterial).frame(width: 60, height: 60).shadow(radius: 5)
                            Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(.primary).frame(width: 60, height: 60)
                            statusMark.frame(width: 24, height: 24).background(.regularMaterial, in: Circle()).offset(x: 2, y: 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("展开助手，\(engine.status.label)")
                    .accessibilityAction(named: "展开") { panel.expand() }
                    .position(x: (panel.edge == .left ? radius + margin : width - radius - margin) + dragOffset.width,
                              y: y + dragOffset.height)
                    .gesture(DragGesture(minimumDistance: 10)
                        .onChanged { value in dragging = true; dragOffset = value.translation }
                        .onEnded { value in
                            let finalX = (panel.edge == .left ? radius + margin : width - radius - margin) + value.translation.width
                            let finalY = min(height - radius - margin, max(radius + margin, y + value.translation.height))
                            panel.commitPosition(edge: finalX < width / 2 ? .left : .right,
                                verticalFraction: (finalY - radius - margin) / max(1, height - 2 * (radius + margin)))
                            dragOffset = .zero
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { dragging = false }
                        })
                }
            }
            .frame(width: width, height: height)
        }
        .onChange(of: panel.expanded) { _, expanded in if !expanded { inputFocused = false } }
    }
    private var statusMark: some View {
        let (symbol, color): (String, Color) = {
            switch engine.status {
            case .idle: return ("circle.fill", .gray)
            case .running: return ("arrow.triangle.2.circlepath", .blue)
            case .paused: return ("pause.fill", .orange)
            case .waitingConfirm: return ("checkmark.shield.fill", .orange)
            case .waitingManual:
                if case .some(.question(_, _)) = engine.waitingInput { return ("questionmark", .orange) }
                return ("hand.raised.fill", .orange)
            case .done: return ("checkmark", .green)
            case .failed: return ("exclamationmark", .red)
            }
        }()
        return Image(systemName: symbol).font(.caption2.bold()).foregroundStyle(color).accessibilityLabel(engine.status.label)
    }
}
