import SwiftUI

enum FloatingBrowserStatus {
    case idle, running, intervention, completed, failed
    var color: Color {
        switch self {
        case .idle: return .gray
        case .running: return .blue
        case .intervention, .failed: return .red
        case .completed: return .green
        }
    }
}

enum DockGeometry {
    static let edgeInset: CGFloat = 8
    static let bottomReserve: CGFloat = 120
    static let panelWidthFraction: CGFloat = 0.40
    static let panelWidthRange: ClosedRange<CGFloat> = 148...168
    static let panelMaxHeight: CGFloat = 300

    static func panelScale(area: CGSize) -> CGFloat {
        guard area.width > 0, area.height > 0 else { return 1 }
        let width = min(max(area.width * panelWidthFraction, panelWidthRange.lowerBound), panelWidthRange.upperBound)
        return min(width / area.width, panelMaxHeight / area.height)
    }
    static func panelSize(area: CGSize) -> CGSize {
        let scale = panelScale(area: area)
        return CGSize(width: area.width * scale, height: area.height * scale)
    }
    static func clampedCenter(_ center: CGPoint, area: CGSize,
                              bottomReserve: CGFloat = DockGeometry.bottomReserve) -> CGPoint {
        let size = panelSize(area: area)
        let minX = size.width / 2 + edgeInset
        let maxX = max(minX, area.width - size.width / 2 - edgeInset)
        let minY = size.height / 2 + edgeInset
        let reserve = max(Self.bottomReserve, bottomReserve)
        let maxY = max(minY, area.height - reserve - size.height / 2)
        return CGPoint(x: min(max(center.x, minX), maxX), y: min(max(center.y, minY), maxY))
    }
    static func snappedCenter(_ center: CGPoint, area: CGSize,
                              bottomReserve: CGFloat = DockGeometry.bottomReserve) -> CGPoint {
        let size = panelSize(area: area)
        let left = size.width / 2 + edgeInset
        let right = area.width - size.width / 2 - edgeInset
        let x = abs(center.x - left) <= abs(center.x - right) ? left : right
        return clampedCenter(CGPoint(x: x, y: center.y), area: area, bottomReserve: bottomReserve)
    }
    static func defaultCenter(area: CGSize,
                              bottomReserve: CGFloat = DockGeometry.bottomReserve) -> CGPoint {
        let size = panelSize(area: area)
        return clampedCenter(CGPoint(x: size.width / 2 + edgeInset,
                                     y: area.height - max(Self.bottomReserve, bottomReserve) - size.height / 2 - 4),
                             area: area, bottomReserve: bottomReserve)
    }
}

/// Presentation-only state. Intervention temporarily force-shows the panel
/// without erasing the user's underlying per-task visibility choice.
@MainActor final class DockStateStore: ObservableObject {
    @Published private(set) var desiredVisible = false
    @Published private(set) var interventionRequired = false
    @Published var fullScreen = false
    @Published var floatingCenter: CGPoint?
    var didInitializeLayout = false
    var isVisible: Bool { desiredVisible || interventionRequired }
    var showsVisibilityToggle: Bool { !fullScreen }

    func taskStarted() { desiredVisible = true; fullScreen = false }
    func taskTerminated() { desiredVisible = false; fullScreen = false }
    func setInterventionRequired(_ required: Bool) {
        interventionRequired = required
        if required || !isVisible { fullScreen = false }
    }
    func toggle() {
        guard !interventionRequired else { return }
        desiredVisible.toggle()
        if !desiredVisible { fullScreen = false }
    }
    func showFullScreen() { desiredVisible = true; fullScreen = true }
    func leaveFullScreen() { fullScreen = false }
}

private struct FloatingDragShield: View {
    let label: String
    var onChanged: (DragGesture.Value) -> Void
    var onEnded: (DragGesture.Value) -> Void
    var body: some View {
        Color.white.opacity(0.001).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 8).onChanged(onChanged).onEnded(onEnded))
            .accessibilityLabel(label).accessibilityHint("拖动移动并贴边")
    }
}

struct BrowserDockView: View {
    @ObservedObject var web: WebController
    @ObservedObject var engine: AgentEngine
    var chatInputFocus: FocusState<Bool>.Binding
    var bottomReserve: CGFloat
    var expandRequest: Int
    @ObservedObject var dock: DockStateStore
    var onReturnToExecution: (() -> Void)? = nil

    @State private var area: CGSize = .zero
    @State private var dragDelta: CGSize = .zero
    @State private var dragStartCenter: CGPoint?
    @State private var statusPulse = false
    @AppStorage("dock.floatingCenterXFrac") private var storedXFrac: Double = -1
    @AppStorage("dock.floatingCenterYFrac") private var storedYFrac: Double = -1
    private var spring: Animation { .spring(response: 0.42, dampingFraction: 0.86) }

    private var needsIntervention: Bool {
        if engine.pendingUpload != nil { return true }
        if case .waitingConfirm = engine.status { return true }
        if case .waitingManual = engine.status, case .some(.manual) = engine.waitingInput { return true }
        return false
    }
    private var status: FloatingBrowserStatus {
        if needsIntervention { return .intervention }
        switch engine.status {
        case .running: return .running
        case .done, .ended: return .completed
        case .failed: return .failed
        default: return engine.sessionActive ? .running : .idle
        }
    }
    private var statusIsRunning: Bool {
        if case .running = status { return true }
        return false
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: size.width, height: size.height).allowsHitTesting(false)
                // Hidden/shown never changes this frame or BrowserView lifetime.
                BrowserView(controller: web, showsTabsUI: dock.fullScreen,
                            onReturnToExecution: onReturnToExecution)
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(dock.fullScreen ? 1 : DockGeometry.panelScale(area: size))
                    .opacity(dock.isVisible ? 1 : 0)
                    .allowsHitTesting(dock.isVisible)
                    .clipShape(RoundedRectangle(cornerRadius: dock.fullScreen ? 0 : 14, style: .continuous))
                    .shadow(color: .black.opacity(dock.isVisible && !dock.fullScreen ? 0.28 : 0), radius: 12, x: 0, y: 4)
                    .position(liveSurfaceCenter(in: size))

                if dock.isVisible && !dock.fullScreen {
                    let panel = DockGeometry.panelSize(area: size)
                    FloatingDragShield(label: "浏览器浮窗", onChanged: dragChanged, onEnded: dragEnded)
                        .frame(width: panel.width, height: panel.height)
                        .offset(x: floatingCenter(in: size).x - panel.width / 2,
                                y: floatingCenter(in: size).y - panel.height / 2)
                    panelControls.frame(width: panel.width, height: panel.height, alignment: .bottomTrailing)
                        .offset(x: floatingCenter(in: size).x - panel.width / 2,
                                y: floatingCenter(in: size).y - panel.height / 2)
                }
                if dock.isVisible && dock.fullScreen {
                    Button { withAnimation(spring) { dock.leaveFullScreen() } } label: {
                        Image(systemName: "pip.enter").font(.body.weight(.semibold)).padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .position(x: size.width - 34, y: size.height - bottomReserve - 34)
                    .accessibilityLabel("收起为浮窗")
                }
                if dock.showsVisibilityToggle { visibilityToggle(in: size) }
            }
            .frame(width: size.width, height: size.height)
            .onAppear { initialize(area: size) }
            .onChange(of: size) { _, value in resizeArea(value) }
        }
        .ignoresSafeArea(.keyboard)
        .onChange(of: dock.fullScreen) { _, fullScreen in if fullScreen { chatInputFocus.wrappedValue = false } }
        .onChange(of: expandRequest) { _, _ in withAnimation(spring) { dock.showFullScreen() } }
        .onChange(of: engine.sessionActive) { _, active in
            withAnimation(spring) {
                if active { dock.taskStarted() } else { dock.taskTerminated() }
                dock.setInterventionRequired(needsIntervention)
            }
        }
        .onChange(of: needsIntervention) { _, needed in
            withAnimation(spring) { dock.setInterventionRequired(needed) }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                statusPulse = true
            }
        }
    }

    private var panelControls: some View {
        Button { withAnimation(spring) { dock.showFullScreen() } } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
        }
        .accessibilityLabel("展开全屏")
        .padding(8).background(.ultraThinMaterial, in: Circle()).padding(8)
    }

    private func visibilityToggle(in size: CGSize) -> some View {
        Button { withAnimation(spring) { dock.toggle() } } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "safari").font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.35)))
                    .shadow(color: .black.opacity(0.22), radius: 7, y: 3)
                Circle().fill(status.color).frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                    .scaleEffect(statusIsRunning && statusPulse ? 1.25 : 1)
                    .opacity(statusIsRunning && statusPulse ? 0.68 : 1)
                    .offset(x: -1, y: -1)
            }
        }
        .buttonStyle(.plain).disabled(needsIntervention)
        .accessibilityLabel(dock.isVisible ? "隐藏浏览器浮窗" : "显示浏览器浮窗")
        .accessibilityHint(needsIntervention ? "安全介入处理完成前不能隐藏" : "切换浏览器浮窗显隐")
        // A separate trailing height from SESSION-UX's scroll-to-bottom button.
        .position(x: size.width - 34, y: max(34, size.height - bottomReserve - 78))
    }

    private func liveSurfaceCenter(in size: CGSize) -> CGPoint {
        dock.fullScreen ? CGPoint(x: size.width / 2, y: size.height / 2) : floatingCenter(in: size)
    }
    private func floatingCenter(in size: CGSize) -> CGPoint {
        let base = dock.floatingCenter ?? DockGeometry.defaultCenter(area: size, bottomReserve: bottomReserve)
        return CGPoint(x: base.x + dragDelta.width, y: base.y + dragDelta.height)
    }
    private func initialize(area size: CGSize) {
        area = size
        dock.setInterventionRequired(needsIntervention)
        guard !dock.didInitializeLayout else { resizeArea(size); return }
        dock.didInitializeLayout = true
        if engine.sessionActive { dock.taskStarted(); dock.setInterventionRequired(needsIntervention) }
        if storedXFrac >= 0, storedYFrac >= 0 {
            dock.floatingCenter = DockGeometry.clampedCenter(
                CGPoint(x: storedXFrac * size.width, y: storedYFrac * size.height),
                area: size, bottomReserve: bottomReserve)
        } else {
            dock.floatingCenter = DockGeometry.defaultCenter(area: size, bottomReserve: bottomReserve)
        }
    }
    private func resizeArea(_ size: CGSize) {
        area = size
        guard let current = dock.floatingCenter else { return }
        dock.floatingCenter = DockGeometry.clampedCenter(current, area: size, bottomReserve: bottomReserve)
    }
    private func dragChanged(_ value: DragGesture.Value) {
        if dragStartCenter == nil {
            dragStartCenter = dock.floatingCenter ?? DockGeometry.defaultCenter(area: area, bottomReserve: bottomReserve)
        }
        var transaction = Transaction(); transaction.animation = nil
        withTransaction(transaction) { dragDelta = value.translation }
    }
    private func dragEnded(_ value: DragGesture.Value) {
        let start = dragStartCenter ?? dock.floatingCenter ?? DockGeometry.defaultCenter(area: area, bottomReserve: bottomReserve)
        dragStartCenter = nil
        let predicted = CGPoint(x: start.x + value.predictedEndTranslation.width,
                                y: start.y + value.predictedEndTranslation.height)
        let snapped = DockGeometry.snappedCenter(predicted, area: area, bottomReserve: bottomReserve)
        withAnimation(spring) { dock.floatingCenter = snapped; dragDelta = .zero }
        if area.width > 0, area.height > 0 {
            storedXFrac = Double(snapped.x / area.width); storedYFrac = Double(snapped.y / area.height)
        }
    }
}
