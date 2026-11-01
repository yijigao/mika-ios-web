import SwiftUI

struct FloatingBallView: View {
    @ObservedObject var panel: FloatingPanelStore
    @ObservedObject var engine: AgentEngine
    let availableSize: CGSize
    @State private var dragOffset: CGSize = .zero
    @State private var dragging = false
    var body: some View {
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
        .offset(x: dragOffset.width, y: dragOffset.height)
        .gesture(DragGesture(minimumDistance: 10)
            .onChanged { value in dragging = true; dragOffset = value.translation }
            .onEnded { value in
                let width = availableSize.width
                let height = availableSize.height
                let committedX = panel.edge == .left ? 50 : width - 50
                let committedY = 50 + panel.verticalFraction * max(0, height - 100)
                let finalX = committedX + value.translation.width
                let finalY = min(height - 50, max(50, committedY + value.translation.height))
                panel.commitPosition(edge: finalX < width / 2 ? .left : .right,
                    verticalFraction: (finalY - 50) / max(1, height - 100))
                dragOffset = .zero
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { dragging = false }
            })
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
