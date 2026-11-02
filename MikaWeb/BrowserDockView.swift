import SwiftUI

// 浏览器坞（悬浮窗改造，2026-11-02，案卷 FLOATING-UI-IMPL-2026-11-02.md）：
// 对话全屏为根层，浏览器改为盖在其上的坞：expanded＝全屏，mini＝可拖动悬浮小窗。
// 保活原则：坞内承载的 BrowserView（含 WebSurface／同一个 WKWebView 实例）自 App 启动
// 常驻、永不卸载或重建；布局尺寸恒为展开态全尺寸，缩小只走 scaleEffect 渲染变换＋
// 外层 visual frame＋offset 定位，不改 WKWebView 自身 frame，页面不重排、不重载。
// 位置几何走「中心点＋缩放比」模型：动画由 mode 驱动（弹簧、可被新手势打断重定向），
// 拖动位移走无动画事务，松手按预测落点（速度采样）弹簧吸附到最近的左／右边缘。

/// 坞形态：展开（全屏）／小窗。拖动是 mini 上的瞬时手势状态，不单独成态；
/// 收起／展开的动画中间过程由弹簧插值呈现，mode 在手势／信号触发瞬间即切换。
enum DockMode {
    case expanded
    case mini
}

/// 坞几何纯函数：与视图状态解耦，可独立核对。
enum DockGeometry {
    /// 小窗距容器左／右／上边缘的留白（pt）
    static let edgeInset: CGFloat = 10
    /// 底部保留高度（pt）：对话输入区（输入框＋按钮行＋内边距）的大致高度，
    /// 小窗的停靠与拖动钳制不越过此线，避免长期遮住输入栏；键盘弹起时的短暂遮挡不在此列。
    static let bottomReserve: CGFloat = 148
    /// 小窗目标宽度占容器宽度比例与绝对范围（pt）
    static let miniWidthFraction: CGFloat = 0.44
    static let miniWidthRange: ClosedRange<CGFloat> = 150...184
    /// 小窗高度上限占容器高度比例
    static let miniMaxHeightFraction: CGFloat = 0.46

    /// 小窗缩放比：按目标宽度换算，并受高度上限约束（等比缩放、整页可见）。
    static func miniScale(area: CGSize) -> CGFloat {
        guard area.width > 0, area.height > 0 else { return 1 }
        let targetWidth = min(max(area.width * miniWidthFraction, miniWidthRange.lowerBound), miniWidthRange.upperBound)
        return min(targetWidth / area.width, miniMaxHeightFraction)
    }

    /// 给定缩放比时坞的视觉尺寸（＝展开布局尺寸 × 缩放比）
    static func visualSize(area: CGSize, scale: CGFloat) -> CGSize {
        CGSize(width: area.width * scale, height: area.height * scale)
    }

    /// 把小窗中心钳制进合法区间：左右不越边缘，上下不越顶边与底部输入保留线。
    static func clampedCenter(_ center: CGPoint, area: CGSize, scale: CGFloat) -> CGPoint {
        let visual = visualSize(area: area, scale: scale)
        let minX = visual.width / 2 + edgeInset
        let maxX = max(minX, area.width - visual.width / 2 - edgeInset)
        let minY = visual.height / 2 + edgeInset
        let maxY = max(minY, area.height - bottomReserve - visual.height / 2)
        return CGPoint(x: min(max(center.x, minX), maxX),
                       y: min(max(center.y, minY), maxY))
    }

    /// 松手吸附：按预测落点选最近的左／右边缘，纵向钳制进合法区间。
    static func snappedCenter(predicted: CGPoint, area: CGSize, scale: CGFloat) -> CGPoint {
        let visual = visualSize(area: area, scale: scale)
        let leftX = visual.width / 2 + edgeInset
        let rightX = area.width - visual.width / 2 - edgeInset
        let x = abs(predicted.x - leftX) <= abs(predicted.x - rightX) ? leftX : rightX
        return clampedCenter(CGPoint(x: x, y: predicted.y), area: area, scale: scale)
    }

    /// 默认停靠位：右下，贴右边缘、底边在输入保留线之上。
    static func defaultCenter(area: CGSize, scale: CGFloat) -> CGPoint {
        let visual = visualSize(area: area, scale: scale)
        return clampedCenter(CGPoint(x: area.width - visual.width / 2 - edgeInset,
                                     y: area.height - bottomReserve - visual.height / 2 - 4),
                             area: area, scale: scale)
    }
}

/// 小窗态手势护盾：覆盖小窗全部面积、拦截一切触摸（绝不下传到 WKWebView 页面）。
/// 点按（位移小于阈值）＝展开复原；拖动＝移动小窗，松手由宿主按预测落点吸附。
/// expanded 态不存在本视图，浏览器恢复正常交互。
struct MiniShieldView: View {
    var onDragChanged: (DragGesture.Value) -> Void
    var onDragEnded: (DragGesture.Value) -> Void

    var body: some View {
        // 近透明填充保证整面可命中（Color.clear 不可靠地参与命中测试）
        Color.white.opacity(0.001)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                // 展开提示（纯视觉，不参与命中，手势全由护盾本体接管）
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                    Text("展开")
                }
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(5)
                .allowsHitTesting(false)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged(onDragChanged)
                    .onEnded(onDragEnded)
            )
            .accessibilityLabel("浏览器小窗")
            .accessibilityHint("点按展开浏览器，拖动移动小窗")
    }
}

/// 浏览器坞：承载现有 BrowserView，在对话层之上呈 expanded／mini 双态。
/// 自动展开接 AgentEngine 既有信号（不新造确认逻辑、不改安全边界）：
/// ① status 进入 .waitingConfirm（执行前确认卡片）→ 展开，且确认卡片随坞底呈现；
/// ② status 进入 .waitingManual 且 waitingInput 为 .manual（密码／验证码框等用户手输）→ 展开，
///    并在坞底给出与聊天区同口径的「已处理，继续」入口（engine.resume() 同一路径）。
/// ask_user 提问（waitingInput 为 .question）在对话层作答，不触发展开。
struct BrowserDockView: View {
    @ObservedObject var web: WebController
    @ObservedObject var engine: AgentEngine

    @State private var mode: DockMode = .mini
    @State private var miniCenter: CGPoint?
    @State private var dragDelta: CGSize = .zero
    @State private var dragStartCenter: CGPoint?
    @State private var area: CGSize = .zero
    @AppStorage("dock.miniCenterXFrac") private var storedXFrac: Double = -1
    @AppStorage("dock.miniCenterYFrac") private var storedYFrac: Double = -1

    private var spring: Animation { .spring(response: 0.42, dampingFraction: 0.86) }
    /// 点按／拖动分界：总位移小于此值（pt）视为点按展开
    private let tapThreshold: CGFloat = 8

    private var needsIntervention: Bool {
        if case .waitingConfirm = engine.status { return true }
        if case .waitingManual = engine.status, case .some(.manual) = engine.waitingInput { return true }
        return false
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let scale = mode == .expanded ? 1 : DockGeometry.miniScale(area: size)
            let visual = DockGeometry.visualSize(area: size, scale: scale)
            let baseCenter = mode == .expanded
                ? CGPoint(x: size.width / 2, y: size.height / 2)
                : (miniCenter ?? DockGeometry.defaultCenter(area: size, scale: DockGeometry.miniScale(area: size)))
            let center = CGPoint(x: baseCenter.x + dragDelta.width, y: baseCenter.y + dragDelta.height)
            ZStack(alignment: .topLeading) {
                // 尺寸锚：保证 ZStack 恒为容器全尺寸（小窗态也不缩），且不拦截触摸
                Color.clear
                    .frame(width: size.width, height: size.height)
                    .allowsHitTesting(false)
                dockCard(area: size, scale: scale, visual: visual)
                    .offset(x: center.x - visual.width / 2, y: center.y - visual.height / 2)
            }
            .frame(width: size.width, height: size.height)
            .onAppear {
                area = size
                restoreCenter(area: size)
            }
            .onChange(of: size) { _, newSize in
                area = newSize
                // 容器尺寸变化（旋转等）时把记忆位置钳制回合法区间；键盘不改本层尺寸（见下）
                if let current = miniCenter {
                    miniCenter = DockGeometry.clampedCenter(current, area: newSize, scale: DockGeometry.miniScale(area: newSize))
                }
            }
        }
        // 仅忽略键盘安全区：键盘弹起时坞的坐标系不变，小窗保持屏幕坐标（允许被键盘短暂遮挡）
        .ignoresSafeArea(.keyboard)
        .onChange(of: needsIntervention) { _, needed in
            if needed, mode != .expanded { expand() }
        }
    }

    /// 坞卡片：BrowserView 恒以展开尺寸布局，仅经 scaleEffect 做渲染缩放；
    /// 外层 frame 取视觉尺寸承接圆角裁剪／描边／阴影与护盾、按钮等覆盖层。
    private func dockCard(area size: CGSize, scale: CGFloat, visual: CGSize) -> some View {
        BrowserView(controller: web)
            .frame(width: size.width, height: size.height)
            .scaleEffect(scale)
            .frame(width: visual.width, height: visual.height)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: mode == .mini ? 14 : 0, style: .continuous))
            .shadow(color: .black.opacity(mode == .mini ? 0.28 : 0), radius: 12, x: 0, y: 4)
            .overlay {
                if mode == .mini {
                    MiniShieldView(onDragChanged: shieldDragChanged, onDragEnded: shieldDragEnded)
                }
            }
            .overlay {
                if mode == .mini {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if mode == .expanded {
                    Button { collapse() } label: {
                        Image(systemName: "pip.enter")
                            .font(.body.weight(.semibold))
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                    }
                    .padding(12)
                    .accessibilityLabel("缩小浏览器为悬浮小窗")
                }
            }
            .overlay(alignment: .bottom) {
                if mode == .expanded {
                    interventionOverlay
                }
            }
            .animation(spring, value: mode)
    }

    /// 展开态下随坞呈现的用户介入 UI（与聊天区同源同口径，不另造逻辑）：
    /// 确认等待时复用 AgentChatView 的 ConfirmCard（同一 engine.confirm 路径与内部防重复守卫）；
    /// 手动输入等待时给出同口径提示＋「已处理，继续」（engine.resume() 同一路径）。
    @ViewBuilder
    private var interventionOverlay: some View {
        if case .waitingConfirm(let action) = engine.status {
            ConfirmCard(engine: engine, action: action, taskID: engine.conversationTaskID)
                .padding(10)
        } else if case .waitingManual = engine.status, case .some(.manual) = engine.waitingInput {
            VStack(alignment: .leading, spacing: 8) {
                Text("请在网页完成处理，然后点击「已处理，继续」。")
                Button("已处理，继续") { engine.resume() }
                    .buttonStyle(.borderedProminent)
            }
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .padding(10)
        }
    }

    // MARK: - 状态切换

    private func expand() {
        withAnimation(spring) {
            mode = .expanded
            dragDelta = .zero
            dragStartCenter = nil
        }
    }

    private func collapse() {
        withAnimation(spring) { mode = .mini }
    }

    private func restoreCenter(area size: CGSize) {
        let scale = DockGeometry.miniScale(area: size)
        if storedXFrac >= 0, storedYFrac >= 0, size.width > 0, size.height > 0 {
            miniCenter = DockGeometry.clampedCenter(
                CGPoint(x: storedXFrac * size.width, y: storedYFrac * size.height),
                area: size, scale: scale)
        } else if miniCenter == nil {
            miniCenter = DockGeometry.defaultCenter(area: size, scale: scale)
        }
    }

    // MARK: - 护盾手势

    private func shieldDragChanged(_ value: DragGesture.Value) {
        if dragStartCenter == nil {
            dragStartCenter = miniCenter ?? DockGeometry.defaultCenter(area: area, scale: DockGeometry.miniScale(area: area))
        }
        // 拖动跟手不走动画事务，避免弹簧滞后
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) { dragDelta = value.translation }
    }

    private func shieldDragEnded(_ value: DragGesture.Value) {
        let start = dragStartCenter ?? miniCenter ?? DockGeometry.defaultCenter(area: area, scale: DockGeometry.miniScale(area: area))
        dragStartCenter = nil
        let moved = hypot(value.translation.width, value.translation.height)
        if moved < tapThreshold {
            expand()
            return
        }
        // 速度采样：用系统预测落点（predictedEndTranslation 已含甩动速度）决定吸附侧与纵向落点
        let predicted = CGPoint(x: start.x + value.predictedEndTranslation.width,
                                y: start.y + value.predictedEndTranslation.height)
        let scale = DockGeometry.miniScale(area: area)
        let snapped = DockGeometry.snappedCenter(predicted: predicted, area: area, scale: scale)
        withAnimation(spring) {
            miniCenter = snapped
            dragDelta = .zero
        }
        if area.width > 0, area.height > 0 {
            storedXFrac = Double(snapped.x / area.width)
            storedYFrac = Double(snapped.y / area.height)
        }
    }
}
