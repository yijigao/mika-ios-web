import SwiftUI
import UIKit

/// Presentation state only. The live BrowserView always keeps the full working
/// frame; level changes never feed a new size into WKWebView.
enum DockLevel: Int, CaseIterable { case snapshot = 1, panel = 2, fullScreen = 3 }

enum FloatingBrowserStatus {
    case idle, running, intervention, completed, failed
    var color: Color {
        switch self {
        case .idle: return .gray
        case .running: return .blue
        case .intervention: return .orange
        case .completed: return .green
        case .failed: return .red
        }
    }
}

/// Pure throttling state shared by production and Tier A.
struct SnapshotRefreshThrottle {
    static let interval: TimeInterval = 1
    private(set) var lastRefresh: Date?
    private(set) var pending = false

    mutating func request(at now: Date) -> TimeInterval? {
        guard let lastRefresh else { self.lastRefresh = now; return 0 }
        let elapsed = now.timeIntervalSince(lastRefresh)
        guard elapsed < Self.interval else { self.lastRefresh = now; pending = false; return 0 }
        guard !pending else { return nil }
        pending = true
        return Self.interval - elapsed
    }

    mutating func consumePending(at now: Date) -> Bool {
        guard pending else { return false }
        pending = false; lastRefresh = now
        return true
    }
}

enum DockGeometry {
    static let edgeInset: CGFloat = 8
    static let bottomReserve: CGFloat = 120
    static let snapshotSize = CGSize(width: 92, height: 124)
    static let panelWidthFraction: CGFloat = 0.40
    static let panelWidthRange: ClosedRange<CGFloat> = 148...168
    static let panelMaxHeight: CGFloat = 300

    static func panelScale(area: CGSize) -> CGFloat {
        guard area.width > 0, area.height > 0 else { return 1 }
        let width = min(max(area.width * panelWidthFraction, panelWidthRange.lowerBound), panelWidthRange.upperBound)
        return min(width / area.width, panelMaxHeight / area.height)
    }
    static func visualSize(level: DockLevel, area: CGSize) -> CGSize {
        switch level {
        case .snapshot: return snapshotSize
        case .panel:
            let scale = panelScale(area: area)
            return CGSize(width: area.width * scale, height: area.height * scale)
        case .fullScreen: return area
        }
    }
    static func clampedCenter(_ center: CGPoint, level: DockLevel, area: CGSize,
                              bottomReserve: CGFloat = DockGeometry.bottomReserve) -> CGPoint {
        let size = visualSize(level: level, area: area)
        let minX = size.width / 2 + edgeInset
        let maxX = max(minX, area.width - size.width / 2 - edgeInset)
        let minY = size.height / 2 + edgeInset
        let reserve = max(Self.bottomReserve, bottomReserve)
        let maxY = max(minY, area.height - reserve - size.height / 2)
        return CGPoint(x: min(max(center.x, minX), maxX), y: min(max(center.y, minY), maxY))
    }
    static func snappedCenter(_ center: CGPoint, level: DockLevel, area: CGSize,
                              bottomReserve: CGFloat = DockGeometry.bottomReserve) -> CGPoint {
        let size = visualSize(level: level, area: area)
        let left = size.width / 2 + edgeInset
        let right = area.width - size.width / 2 - edgeInset
        let x = abs(center.x - left) <= abs(center.x - right) ? left : right
        return clampedCenter(CGPoint(x: x, y: center.y), level: level, area: area, bottomReserve: bottomReserve)
    }
    static func defaultCenter(level: DockLevel, area: CGSize,
                              bottomReserve: CGFloat = DockGeometry.bottomReserve) -> CGPoint {
        let size = visualSize(level: level, area: area)
        return clampedCenter(CGPoint(x: area.width - size.width / 2 - edgeInset,
                                     y: area.height - max(Self.bottomReserve, bottomReserve) - size.height / 2 - 4),
                             level: level, area: area, bottomReserve: bottomReserve)
    }
}

@MainActor final class DockStateStore: ObservableObject {
    @Published var level: DockLevel = .snapshot
    @Published var floatingCenter: CGPoint?
    @Published var snapshot: UIImage?
    var didInitializeLayout = false
    var snapshotThrottle = SnapshotRefreshThrottle()
    var snapshotTask: Task<Void, Never>?
}

private struct FloatingDragShield: View {
    let label: String
    var onChanged: (DragGesture.Value) -> Void
    var onEnded: (DragGesture.Value) -> Void
    var body: some View {
        Color.white.opacity(0.001).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged(onChanged).onEnded(onEnded))
            .accessibilityLabel(label).accessibilityHint("点按进入下一级，拖动移动并贴边")
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
    @AppStorage("dock.floatingCenterXFrac") private var storedXFrac: Double = -1
    @AppStorage("dock.floatingCenterYFrac") private var storedYFrac: Double = -1
    private let tapThreshold: CGFloat = 8
    private var spring: Animation { .spring(response: 0.42, dampingFraction: 0.86) }

    private var needsIntervention: Bool {
        if engine.pendingUpload != nil { return true }
        if case .waitingConfirm = engine.status { return true }
        if case .waitingManual = engine.status, case .some(.manual) = engine.waitingInput { return true }
        return false
    }
    private var status: FloatingBrowserStatus {
        switch engine.status {
        case .running: return .running
        case .waitingConfirm, .waitingManual: return .intervention
        case .done, .ended: return .completed
        case .failed: return .failed
        default: return .idle
        }
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: size.width, height: size.height).allowsHitTesting(false)
                // The sole visible live surface stays mounted at this exact full frame.
                BrowserView(controller: web, showsTabsUI: dock.level == .fullScreen,
                            onReturnToExecution: onReturnToExecution)
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(dock.level == .panel ? DockGeometry.panelScale(area: size) : 1)
                    .opacity(dock.level == .snapshot ? 0 : 1)
                    .allowsHitTesting(dock.level != .snapshot)
                    .clipShape(RoundedRectangle(cornerRadius: dock.level == .panel ? 14 : 0, style: .continuous))
                    .shadow(color: .black.opacity(dock.level == .panel ? 0.28 : 0), radius: 12, x: 0, y: 4)
                    .position(liveSurfaceCenter(in: size))

                if dock.level == .snapshot {
                    snapshotCard.frame(width: DockGeometry.snapshotSize.width, height: DockGeometry.snapshotSize.height)
                        .offset(x: floatingCenter(in: size).x - DockGeometry.snapshotSize.width / 2,
                                y: floatingCenter(in: size).y - DockGeometry.snapshotSize.height / 2)
                } else if dock.level == .panel {
                    let panel = DockGeometry.visualSize(level: .panel, area: size)
                    FloatingDragShield(label: "浏览器浮窗", onChanged: dragChanged, onEnded: dragEnded)
                        .frame(width: panel.width, height: panel.height)
                        .offset(x: floatingCenter(in: size).x - panel.width / 2,
                                y: floatingCenter(in: size).y - panel.height / 2)
                }
                if dock.level != .snapshot {
                    let controlSize = DockGeometry.visualSize(level: dock.level, area: size)
                    levelControls
                        .frame(width: controlSize.width, height: controlSize.height, alignment: .bottomTrailing)
                        .offset(x: (dock.level == .panel ? floatingCenter(in: size).x : size.width / 2) - controlSize.width / 2,
                                y: (dock.level == .panel ? floatingCenter(in: size).y : size.height / 2) - controlSize.height / 2)
                }
            }.frame(width: size.width, height: size.height)
                .onAppear { initialize(area: size) }
                .onChange(of: size) { _, value in resizeArea(value) }
        }
        .ignoresSafeArea(.keyboard)
        .onChange(of: dock.level) { _, level in if level == .fullScreen { chatInputFocus.wrappedValue = false } }
        .onChange(of: expandRequest) { _, _ in setLevel(.fullScreen) }
        .onChange(of: engine.sessionActive) { _, _ in setLevel(.snapshot) }
        .onChange(of: needsIntervention) { _, needed in
            if needed, dock.level == .snapshot { setLevel(.panel) }
        }
        .onChange(of: web.revision) { _, _ in requestSnapshotRefresh() }
        .onChange(of: web.progress) { _, progress in if progress >= 1 { requestSnapshotRefresh() } }
        .onChange(of: engine.steps.count) { _, _ in requestSnapshotRefresh() }
    }

    private var snapshotCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground))
            if let image = dock.snapshot {
                Image(uiImage: image).resizable().scaledToFill().clipped().overlay(Color.black.opacity(0.12))
            } else {
                LinearGradient(colors: [.accentColor.opacity(0.72), .indigo.opacity(0.82)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            VStack(alignment: .leading, spacing: 5) {
                Circle().fill(status.color).frame(width: 9, height: 9)
                Spacer()
                Text(web.activeTab.title.isEmpty ? "Mika Web" : web.activeTab.title)
                    .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                    .lineLimit(1).truncationMode(.tail).shadow(radius: 2)
            }.padding(8)
            FloatingDragShield(label: "浏览器快照卡", onChanged: dragChanged, onEnded: dragEnded)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.4)))
        .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
    }

    @ViewBuilder private var levelControls: some View {
        if dock.level == .panel {
            HStack(spacing: 8) {
                Button { setLevel(.snapshot) } label: { Image(systemName: "pip.exit") }
                    .accessibilityLabel("收起为快照卡")
                Button { setLevel(.fullScreen) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .accessibilityLabel("展开全屏")
            }.padding(8).background(.ultraThinMaterial, in: Capsule()).padding(8)
        } else if dock.level == .fullScreen {
            Button { setLevel(.panel) } label: {
                Image(systemName: "pip.enter").font(.body.weight(.semibold)).padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }.padding(.trailing, 12).padding(.bottom, bottomReserve + 12)
                .accessibilityLabel("收起为浮窗")
        }
    }

    private func liveSurfaceCenter(in size: CGSize) -> CGPoint {
        dock.level == .panel ? floatingCenter(in: size) : CGPoint(x: size.width / 2, y: size.height / 2)
    }
    private func floatingCenter(in size: CGSize) -> CGPoint {
        let level: DockLevel = dock.level == .snapshot ? .snapshot : .panel
        let base = dock.floatingCenter ?? DockGeometry.defaultCenter(level: level, area: size, bottomReserve: bottomReserve)
        return CGPoint(x: base.x + dragDelta.width, y: base.y + dragDelta.height)
    }
    private func initialize(area size: CGSize) {
        area = size
        guard !dock.didInitializeLayout else { resizeArea(size); return }
        dock.didInitializeLayout = true
        if storedXFrac >= 0, storedYFrac >= 0 {
            dock.floatingCenter = DockGeometry.clampedCenter(
                CGPoint(x: storedXFrac * size.width, y: storedYFrac * size.height),
                level: .snapshot, area: size, bottomReserve: bottomReserve)
        } else {
            dock.floatingCenter = DockGeometry.defaultCenter(level: .snapshot, area: size, bottomReserve: bottomReserve)
        }
        requestSnapshotRefresh()
    }
    private func resizeArea(_ size: CGSize) {
        area = size
        guard let current = dock.floatingCenter else { return }
        let level: DockLevel = dock.level == .snapshot ? .snapshot : .panel
        dock.floatingCenter = DockGeometry.clampedCenter(current, level: level, area: size, bottomReserve: bottomReserve)
    }
    private func setLevel(_ level: DockLevel) {
        if level != .fullScreen, let center = dock.floatingCenter, area.width > 0 {
            dock.floatingCenter = DockGeometry.clampedCenter(center, level: level, area: area,
                                                             bottomReserve: bottomReserve)
        }
        withAnimation(spring) { dock.level = level; dragDelta = .zero; dragStartCenter = nil }
        if level == .snapshot { requestSnapshotRefresh() }
    }
    private func dragChanged(_ value: DragGesture.Value) {
        if dragStartCenter == nil {
            dragStartCenter = dock.floatingCenter ?? DockGeometry.defaultCenter(level: dock.level, area: area, bottomReserve: bottomReserve)
        }
        var transaction = Transaction(); transaction.animation = nil
        withTransaction(transaction) { dragDelta = value.translation }
    }
    private func dragEnded(_ value: DragGesture.Value) {
        let start = dragStartCenter ?? dock.floatingCenter ?? DockGeometry.defaultCenter(level: dock.level, area: area, bottomReserve: bottomReserve)
        dragStartCenter = nil
        if hypot(value.translation.width, value.translation.height) < tapThreshold {
            setLevel(dock.level == .snapshot ? .panel : .fullScreen); return
        }
        let predicted = CGPoint(x: start.x + value.predictedEndTranslation.width,
                                y: start.y + value.predictedEndTranslation.height)
        let snapped = DockGeometry.snappedCenter(predicted, level: dock.level, area: area, bottomReserve: bottomReserve)
        withAnimation(spring) { dock.floatingCenter = snapped; dragDelta = .zero }
        if area.width > 0, area.height > 0 {
            storedXFrac = Double(snapped.x / area.width); storedYFrac = Double(snapped.y / area.height)
        }
    }
    private func requestSnapshotRefresh() {
        let now = Date()
        guard let delay = dock.snapshotThrottle.request(at: now) else { return }
        dock.snapshotTask?.cancel()
        dock.snapshotTask = Task { @MainActor in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            if delay > 0, !dock.snapshotThrottle.consumePending(at: Date()) { return }
            dock.snapshot = await web.floatingCardSnapshot()
        }
    }
}
