import SwiftUI

// 浏览器坞（悬浮窗改造，2026-11-02，案卷 FLOATING-UI-IMPL-2026-11-02.md；
// 真 resize 修复 2026-11-02，案卷 FLOATING-UI-FIX2-2026-11-02.md；
// 视口所有权修复 2026-11-02，案卷 AGENT-VIEWPORT-FIX-2026-11-02.md）：
// 对话全屏为根层，浏览器改为盖在其上的坞：expanded＝全屏，mini＝可拖动悬浮小窗。
// 保活原则：坞内承载的 BrowserView（含 WebSurface／同一个 WKWebView 实例）自 App 启动
// 常驻、永不卸载或重建、永不重载。收放动画期间只走 scaleEffect 渲染变换过渡；状态落定
// （弹簧结束约 480ms 后）把 BrowserView 的布局尺寸切到当前态的真实尺寸，WKWebView 随之
// 按新视口响应式重排（内容随窗口适配）；resize 只发生在落定时点，拖动过程中不触发。
// resize 前后保存／恢复页面滚动比例，页面导航（revision 变化）时不恢复。
//
// 视口所有权（布局尺寸归谁管，由 DockLayoutMode 显式表达，不用布尔拼凑）：
// - 任务会话活跃期间（DockLayoutMode.workingSize）：布局尺寸锁定为展开态工作尺寸——
//   agent 的工作视口就是这个尺寸，坞收起只把全尺寸布局缩放渲染（回到 0540 的 scale 路径），
//   绝不因收起而 resize；会话终结后若坞仍是小窗态再补落定 resize。任务开始**不改变坞
//   形态**：原「任务开始自动展开」经 Joey 问题 2（2026-11-02）摘除，用户停在哪态就
//   保持哪态。
// - 无任务时（DockLayoutMode.dockSize）：布局跟随坞态，即 FIX2 的落定真 resize 行为。
//
// 坞形态触发口径（2026-11-02 16:01 Joey 定版，案卷 INTERVENTION-PROMPT-IMPL-2026-11-02.md）：
// **任何自动展开都不要了**——任务开始（问题 2 已摘）与介入场景（确认／手输，本轮摘净）
// 都不再程序触发 expand()；坞形态变化只来自用户动作：点按／拖动护盾、点右下收起按钮、
// 点对话区介入卡上的「打开浏览器查看／打开浏览器」（经 ContentView 的 expandRequest
// 令牌下传，仍是用户点击）。介入呈现改走对话区置顶卡片（InterventionPrompt），
// 小窗坞只加橙点＋「等你处理」状态提示（纯视觉、不触发任何动作）。
// 落定 resize 的触发源纪律（2026-11-02 晚，案卷 DOCK-NAV-PASSKEY-FIX-2026-11-02.md）：
// 真机实证——任务在小窗态跑完后，页面在小窗里按约 155pt 真实重排成逐字窄列。根因是
// 「会话终结」这一生命周期迁移（sessionActive ↓ → layoutMode 交还 .dockSize）触发的
// settle 把视口缩到了小窗真实尺寸：它紧跟在任务的最后一次导航（发表跳转）之后约
// 480ms 落定，用户席位上就读作「导航把布局弄坏了」。定版规则：**缩到 dockSize 的真
// resize 只允许由用户显式展开／收起手势的收敛 settle 落定**（FIX2 的「用户收起落定后
// 内容按小窗宽度重排可读」保留）；一切生命周期 settle（会话开始／终结、容器尺寸
// 变化）只允许把布局往工作尺寸方向推（会话开始时从小窗真实尺寸一次长回工作尺寸，
// 0645 视口锁定的迁移 #1 不变），**绝不缩**。会话终结时坞若是小窗态，布局保持工作
// 尺寸＋缩放渲染，直到用户下一次显式收起手势才落定到小窗真实尺寸；页面导航本身
// （整页／重定向／SPA 路由）从不直接触发 settle，本纪律把「导航刚结束就赶上会话
// 终结」这条被动路径一并堵死。
//
// 视觉呈现（DisplayMode）由 mode（坞形态）×layoutMode（布局所有权）导出：
// 布局缩放比 layoutScale 与视觉缩放比之商走 scaleEffect，组合真值表见案卷。
// 位置几何走「中心点＋缩放比」模型：动画由 mode 驱动（弹簧、可被新手势打断重定向），
// 拖动位移走无动画事务，松手按预测落点（速度采样）弹簧吸附到最近的左／右边缘。

/// 坞形态：展开（全屏）／小窗。拖动是 mini 上的瞬时手势状态，不单独成态；
/// 收起／展开的动画中间过程由弹簧插值呈现，mode 在手势／信号触发瞬间即切换。
enum DockMode {
    case expanded
    case mini
}

/// 布局尺寸所有权：布局尺寸（＝WKWebView 的真实视口）当前归谁管。
/// - workingSize：任务会话活跃期，布局锁定展开态工作尺寸，坞收放只影响视觉呈现；
/// - dockSize：无任务，布局跟随坞态（展开＝全尺寸、小窗＝小窗真实尺寸，FIX2 行为）。
/// 迁移点（任务会话开始／终结、坞收放、容器尺寸变化）逐个列在案卷的状态迁移表里。
enum DockLayoutMode {
    case workingSize
    case dockSize
}

/// 坞几何纯函数：与视图状态解耦，可独立核对。
enum DockGeometry {
    /// 小窗距容器左／右／上边缘的留白（pt）
    static let edgeInset: CGFloat = 10
    /// 底部保留高度（pt）的兜底常量：层级调整（问题 3）后，钳制改用 ContentView
    /// 下传的实测值（输入栏实测高＋底部安全区上限＋余量，见 ContentView 的
    /// dockBottomReserve），本常量只在未收到下传值时兜底。旧值 148 对应旧层级下
    /// 「输入行＋按钮行」两行区的高度；新层级按钮行回到消息层、只护输入栏一行，
    /// 故实测口径的数值变小属预期。键盘弹起时的短暂遮挡不在此列。
    static let bottomReserve: CGFloat = 148
    /// 小窗目标宽度占容器宽度比例与绝对范围（pt）。
    /// AGENT-VIEWPORT-FIX：FIX2 的 0.50／170–210（约 196×380）盖住半个对话区、观感压迫，
    /// 调小为屏宽×0.40（钳 148–168）；高度按整页等比、上限约 300pt。小窗态下 agent 任务的
    /// 工作视口不再是这个尺寸（布局锁定工作尺寸，见 DockLayoutMode），调小只影响
    /// 用户闲时浏览的真实视口与任务期的缩放渲染观感。手感不合仍可一行调整。
    static let miniWidthFraction: CGFloat = 0.40
    static let miniWidthRange: ClosedRange<CGFloat> = 148...168
    /// 小窗高度上限（pt，整页等比缩放后的视觉高度封顶）
    static let miniMaxHeight: CGFloat = 300

    /// 小窗缩放比：按目标宽度换算，并受高度上限约束（等比缩放、整页可见）。
    static func miniScale(area: CGSize) -> CGFloat {
        guard area.width > 0, area.height > 0 else { return 1 }
        let targetWidth = min(max(area.width * miniWidthFraction, miniWidthRange.lowerBound), miniWidthRange.upperBound)
        return min(targetWidth / area.width, miniMaxHeight / area.height)
    }

    /// 给定缩放比时坞的视觉尺寸（＝展开布局尺寸 × 缩放比）
    static func visualSize(area: CGSize, scale: CGFloat) -> CGSize {
        CGSize(width: area.width * scale, height: area.height * scale)
    }

    /// 把小窗中心钳制进合法区间：左右不越边缘，上下不越顶边与底部输入保留线。
    /// bottomReserve 由调用方下传实测值（问题 3），缺省用兜底常量。
    static func clampedCenter(_ center: CGPoint, area: CGSize, scale: CGFloat, bottomReserve: CGFloat = DockGeometry.bottomReserve) -> CGPoint {
        let visual = visualSize(area: area, scale: scale)
        let minX = visual.width / 2 + edgeInset
        let maxX = max(minX, area.width - visual.width / 2 - edgeInset)
        let minY = visual.height / 2 + edgeInset
        let maxY = max(minY, area.height - bottomReserve - visual.height / 2)
        return CGPoint(x: min(max(center.x, minX), maxX),
                       y: min(max(center.y, minY), maxY))
    }

    /// 松手吸附：按预测落点选最近的左／右边缘，纵向钳制进合法区间。
    static func snappedCenter(predicted: CGPoint, area: CGSize, scale: CGFloat, bottomReserve: CGFloat = DockGeometry.bottomReserve) -> CGPoint {
        let visual = visualSize(area: area, scale: scale)
        let leftX = visual.width / 2 + edgeInset
        let rightX = area.width - visual.width / 2 - edgeInset
        let x = abs(predicted.x - leftX) <= abs(predicted.x - rightX) ? leftX : rightX
        return clampedCenter(CGPoint(x: x, y: predicted.y), area: area, scale: scale, bottomReserve: bottomReserve)
    }

    /// 默认停靠位：右下，贴右边缘、底边在输入保留线之上。
    static func defaultCenter(area: CGSize, scale: CGFloat, bottomReserve: CGFloat = DockGeometry.bottomReserve) -> CGPoint {
        let visual = visualSize(area: area, scale: scale)
        return clampedCenter(CGPoint(x: area.width - visual.width / 2 - edgeInset,
                                     y: area.height - bottomReserve - visual.height / 2 - 4),
                             area: area, scale: scale, bottomReserve: bottomReserve)
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

/// 浏览器坞的几何／形态状态存储（CRASH-1031 追加项）：由 WebController 持有
/// （App 级寿命），BrowserDockView 只是它的呈现层。mode／miniCenter／
/// layoutScale／layoutMode 放这里而不是 View 的 @State，是因为设置页这类
/// 导航 push／pop（及 sheet 呈现）会让 SwiftUI 拆建根视图层级、@State 随之
/// 清零，视图 onAppear 再按冷启动路径「恢复」出错误布局（Joey 2026-11-02
/// 18:59 真机：从设置返回后坞被还原成贴右侧的大面板、盖住对话区）。状态在
/// 本存储里跨视图重建原样保留；onAppear 只在 didInitializeLayout 为假的
/// 真冷启动时跑一次初始布局落定，往返重现只做位置钳制、不重导布局。
@MainActor final class DockStateStore: ObservableObject {
    @Published var mode: DockMode = .mini
    @Published var miniCenter: CGPoint?
    @Published var layoutScale: CGFloat = 1
    @Published var layoutMode: DockLayoutMode = .dockSize
    /// 冷启动初始布局是否已落定（见类注释）：非 @Published，仅作 onAppear 门。
    var didInitializeLayout = false
}

/// 浏览器坞：承载现有 BrowserView，在对话层之上呈 expanded／mini 双态。
/// 介入呈现（2026-11-02 16:01 Joey 定版）：坞**不再**因 engine 信号自动展开，
/// 也不再在坞底呈现介入 UI——确认（.waitingConfirm）与手输（.waitingManual＋.manual）
/// 一律走对话区置顶卡片（ContentView 的 InterventionPrompt 层，同一 engine.confirm／
/// engine.resume 路径与防重复守卫）；小窗态坞上只加橙点＋「等你处理」状态提示
/// （纯视觉、allowsHitTesting(false)，点按仍由护盾接管＝用户手势展开）。
/// expand() 的调用点只剩用户动作：护盾点按、介入卡「打开浏览器」类按钮（经
/// expandRequest 令牌下传）。ask_user 提问在对话层作答，本就不涉及坞。
struct BrowserDockView: View {
    @ObservedObject var web: WebController
    @ObservedObject var engine: AgentEngine
    /// 对话输入框焦点（由 ContentView 下传）：坞展开即全屏盖住对话层，若对话输入框
    /// 此前持有焦点，键盘（系统级浮层）会继续悬浮在浏览器上方、而对话层不可达，
    /// 用户无从收起——故在切到 expanded 的瞬间代为收起（见 mode 的 onChange）。
    /// 仅此一个写入点；mini 态不动它（边看小窗边在对话打字是常态路径）。
    /// 网页内的手输焦点是 WKWebView 自己的 first responder，与本状态无关、不受影响。
    /// 类型须是 FocusState 的 Binding（与输入栏 TextField 绑定的同一个），
    /// 普通 Binding<Bool> 与之不互通（首版 Release 编译实证，见案卷）。
    var chatInputFocus: FocusState<Bool>.Binding
    /// 底部保留高度（本坞全出血坐标）：ContentView 按输入栏实测高度推导后下传
    /// （问题 3）——小窗钳制下界与展开态收起按钮的底部避让都用它，
    /// 输入栏永远在坞之上、压不住。草稿变高（输入栏变高）时经 onChange 重钳小窗。
    var bottomReserve: CGFloat
    /// 用户主动展开请求令牌（ContentView 持有）：对话区介入卡上的「打开浏览器查看／
    /// 打开浏览器」被点击时 +1，坞据此展开。这是用户点击、不是程序自动展开——
    /// 与护盾点按同级（见文件头「坞形态触发口径」）。只增不减，坞只认变化本身。
    var expandRequest: Int

    /// 坞几何状态存储（WebController 持有，App 级寿命，见 DockStateStore）：
    /// 视图只是呈现层，导航／sheet 往返重建视图时状态不丢。下四名为转发
    /// 计算属性，本文件其余代码读写习惯不变。
    @ObservedObject var dock: DockStateStore
    /// 「返回执行页」回调（M1，ContentView 提供）：任务在别的会话执行时，
    /// 坞的会话条上给出此入口——把查看侧整体带回任务会话并让执行标签
    /// 成为当前页（编排在 ContentView.returnToExecution）。经 BrowserView
    /// 的会话条呈现，本层只透传。
    var onReturnToExecution: (() -> Void)? = nil
    private var mode: DockMode {
        get { dock.mode }
        nonmutating set { dock.mode = newValue }
    }
    private var miniCenter: CGPoint? {
        get { dock.miniCenter }
        nonmutating set { dock.miniCenter = newValue }
    }
    /// 已落定的布局缩放比：BrowserView 按 area×layoutScale 布局；动画期间的视觉缩放比
    /// （由 mode 决定）与它之商走 scaleEffect 过渡，落定后 layoutScale 追平目标缩放比、
    /// 渲染缩放归 1，页面按真实尺寸重排（FIX2 缺陷 1）。目标缩放比由 layoutMode 决定，
    /// 不是直接由 mode 决定（任务期布局锁定，见 settleTargetScale）。
    private var layoutScale: CGFloat {
        get { dock.layoutScale }
        nonmutating set { dock.layoutScale = newValue }
    }
    /// 布局尺寸所有权：任务会话活跃＝.workingSize（布局锁定工作尺寸），否则 .dockSize。
    /// 只在 onChange(engine.sessionActive) 两个迁移点写入，坞自身的收放不改它。
    private var layoutMode: DockLayoutMode {
        get { dock.layoutMode }
        nonmutating set { dock.layoutMode = newValue }
    }
    @State private var dragDelta: CGSize = .zero
    @State private var dragStartCenter: CGPoint?
    @State private var area: CGSize = .zero
    @State private var settleTask: Task<Void, Never>?
    @AppStorage("dock.miniCenterXFrac") private var storedXFrac: Double = -1
    @AppStorage("dock.miniCenterYFrac") private var storedYFrac: Double = -1

    private var spring: Animation { .spring(response: 0.42, dampingFraction: 0.86) }
    /// 点按／拖动分界：总位移小于此值（pt）视为点按展开
    private let tapThreshold: CGFloat = 8

    /// 是否正等待用户介入（确认／手输）：现在只驱动小窗上的状态提示（橙点＋
    /// 「等你处理」），**不再**触发任何形态变化（自动展开已按 Joey 定版摘净）。
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
                : (miniCenter ?? DockGeometry.defaultCenter(area: size, scale: DockGeometry.miniScale(area: size), bottomReserve: bottomReserve))
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
                if !dock.didInitializeLayout {
                    // 真冷启动（进程内首次出现）：恢复记忆位置，布局尺寸直接
                    // 落到初始态（mini）无过渡动画，起始页一次排好。
                    dock.didInitializeLayout = true
                    restoreCenter(area: size)
                    if mode == .mini {
                        layoutScale = DockGeometry.miniScale(area: size)
                    }
                } else if let current = miniCenter {
                    // 导航 push／pop、sheet 呈现等往返后的重现：mode／位置／
                    // 布局缩放都在 DockStateStore 里原样保留，这里只把小窗
                    // 位置钳制进当前容器合法区间——绝不重跑冷启动恢复、
                    // 不动 mode／layoutScale／layoutMode（CRASH-1031 追加项：
                    // 从设置返回后坞被「还原」成大面板的成因路径）。
                    miniCenter = DockGeometry.clampedCenter(current, area: size, scale: DockGeometry.miniScale(area: size), bottomReserve: bottomReserve)
                }
            }
            .onChange(of: size) { _, newSize in
                area = newSize
                // 容器尺寸变化（旋转等）时把记忆位置钳制回合法区间；键盘不改本层尺寸（见下）
                if let current = miniCenter {
                    miniCenter = DockGeometry.clampedCenter(current, area: newSize, scale: DockGeometry.miniScale(area: newSize), bottomReserve: bottomReserve)
                }
                // 容器尺寸变化是生命周期事件、不是收放手势：settle 只许往工作尺寸推、不许缩
                scheduleSettle(userGesture: false)
            }
            .onChange(of: bottomReserve) { _, _ in
                // 输入栏变高（草稿长到多行）时保留线随之下移，小窗若已越线则重钳回线之上
                if let current = miniCenter, area.width > 0 {
                    miniCenter = DockGeometry.clampedCenter(current, area: area, scale: DockGeometry.miniScale(area: area), bottomReserve: bottomReserve)
                }
            }
        }
        // 仅忽略键盘安全区：键盘弹起时坞的坐标系不变，小窗保持屏幕坐标（允许被键盘短暂遮挡）
        .ignoresSafeArea(.keyboard)
        .onChange(of: mode) { _, newMode in
            // 展开＝对话层被全屏盖住：顺手收起对话键盘（触发来源不限：护盾点按、
            // 介入卡「打开浏览器」按钮皆走此一条——均为用户动作）。expanded 期间
            // 用户与网页的交互走 WKWebView 自己的焦点，不受影响。
            if newMode == .expanded { chatInputFocus.wrappedValue = false }
        }
        .onChange(of: expandRequest) { _, _ in
            // 用户在对话区介入卡上主动点「打开浏览器查看／打开浏览器」→ 展开。
            // 这是 expand() 仅剩的两个调用点之一（另一个是护盾点按），都是用户动作；
            // engine 的任何状态信号都不再触发形态变化（Joey 2026-11-02 16:01 定版）。
            if mode != .expanded { expand() }
        }
        .onChange(of: engine.sessionActive) { _, active in
            // 视口所有权迁移点（任务会话开始／终结）：
            if active {
                // 会话开始：只移交布局所有权到工作尺寸（settle 会把布局从小窗真实尺寸
                // 一次切回工作尺寸，视觉仍按坞当前形态呈现），**不改变坞的形态**——
                // 任务开始自动展开已被 Joey 否掉（问题 2，2026-11-02：「消息发出后
                // 自动放大到全屏，没有必要，很突兀」）：用户停在小窗就保持小窗（工作
                // 尺寸布局＋缩放渲染，页面实时可见），停在展开态就保持展开。
                // 介入场景（waitingConfirm／waitingManual）同样不自动展开（Joey
                // 2026-11-02 16:01 定版）：只在对话里出卡提示，用户自己决定开不开。
                layoutMode = .workingSize
                // 生命周期 settle：只许把布局从小窗真实尺寸长回工作尺寸（迁移 #1），不许缩
                scheduleSettle(userGesture: false)
            } else {
                // 会话终结（完成／失败／停止／切后台暂停）：所有权交还坞态，但**不再**
                // 在此刻补做落定 resize 到小窗真实尺寸——那正是「任务一结束、发表跳转
                // 后的页面就在小窗里挤成窄列」的成因（DOCK-NAV-PASSKEY-FIX）。坞若仍是
                // 小窗态，布局保持工作尺寸＋缩放渲染；缩到小窗真实尺寸只等用户下一次
                // 显式收起手势的 settle（collapse 的 userGesture 通道）。
                layoutMode = .dockSize
                scheduleSettle(userGesture: false)
            }
        }
    }

    /// 坞卡片：BrowserView 按已落定的 layoutScale 布局，动画期间以「视觉缩放比／layoutScale」
    /// 的渲染缩放过渡；外层 frame 取视觉尺寸承接圆角裁剪／描边／阴影与护盾、按钮等覆盖层。
    /// 落定后渲染缩放归 1、布局尺寸＝视觉尺寸，WKWebView 按该视口真实排版（FIX2）。
    private func dockCard(area size: CGSize, scale: CGFloat, visual: CGSize) -> some View {
        let layoutSize = CGSize(width: size.width * layoutScale, height: size.height * layoutScale)
        let renderScale = layoutScale > 0 ? scale / layoutScale : scale
        return BrowserView(controller: web, showsTabsUI: mode == .expanded, onReturnToExecution: onReturnToExecution)
            .frame(width: layoutSize.width, height: layoutSize.height)
            .scaleEffect(renderScale)
            .frame(width: visual.width, height: visual.height)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: mode == .mini ? 14 : 0, style: .continuous))
            .shadow(color: .black.opacity(mode == .mini ? 0.28 : 0), radius: 12, x: 0, y: 4)
            .overlay(alignment: .top) {
                // 任务绑定在别的标签页执行时（用户已切到其他页），在地址栏下方给一行最小提示；
                // 纯视觉不拦截触摸。小窗态不显示（坞内只呈现当前页，见 TABS-IMPL 案卷）。
                if mode == .expanded, engine.busy, let execID = web.executionTabID, execID != web.activeTabID {
                    Text("任务在标签页「\(web.tabTitle(for: execID))」执行中")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.orange.opacity(0.18), in: Capsule())
                        .padding(.top, 46)
                        .allowsHitTesting(false)
                }
            }
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
                    // 输入栏在坞之上浮于底部（问题 3）：收起按钮抬到输入栏之上，不被压住
                    .padding(.trailing, 12)
                    .padding(.bottom, bottomReserve + 12)
                    .accessibilityLabel("缩小浏览器为悬浮小窗")
                }
            }
            .overlay(alignment: .top) {
                // 小窗状态提示（纯视觉，INTERVENTION-PROMPT 定版）：等待用户介入时
                // 在小窗顶部给橙点＋「等你处理」——只提示、不展开、不可点出动作
                // （allowsHitTesting(false)，点按仍落在护盾上＝用户点按展开，是允许的
                // 用户路径）。介入卡本体在对话区（ContentView 的 InterventionPrompt 层）。
                if mode == .mini, needsIntervention {
                    HStack(spacing: 4) {
                        Circle().fill(.orange).frame(width: 7, height: 7)
                        Text("等你处理").font(.caption2.weight(.semibold))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 6)
                    .allowsHitTesting(false)
                }
            }
            .animation(spring, value: mode)
    }

    // MARK: - 状态切换

    private func expand() {
        withAnimation(spring) {
            mode = .expanded
            dragDelta = .zero
            dragStartCenter = nil
        }
        // expand() 的调用点只剩用户动作（护盾点按、介入卡「打开浏览器」按钮），
        // 其 settle 是允许落定真 resize 的用户手势通道
        scheduleSettle(userGesture: true)
    }

    private func collapse() {
        withAnimation(spring) { mode = .mini }
        // 用户显式收起：FIX2 的落定真 resize（页面按小窗宽度重排可读）走这一条通道
        scheduleSettle(userGesture: true)
    }

    /// 落定 resize 的目标布局缩放比：由布局所有权决定。
    /// - workingSize（任务会话活跃）：恒为 1（展开态工作尺寸）——坞收起时 settle 到这里
    ///   等于「不 resize」，视觉缩小完全由 scaleEffect 渲染承担，agent 工作视口纹丝不动；
    /// - dockSize（无任务）：跟随坞态，展开＝1、小窗＝小窗缩放比（FIX2 落定真 resize）。
    private func settleTargetScale() -> CGFloat {
        switch layoutMode {
        case .workingSize: return 1
        case .dockSize: return mode == .expanded ? 1 : DockGeometry.miniScale(area: area)
        }
    }

    /// 落定真 resize（FIX2 缺陷 1）：弹簧（0.42s）结束后，把布局尺寸切到目标尺寸，
    /// 页面随之按新视口重排。切换在禁用动画的事务里完成，切换前先存页面滚动比例、
    /// 切换后恢复（页面在等待期间发生导航＝revision 变化则不恢复，避免跳错位置）。
    /// 拖动不改 mode、不调本方法，故拖动过程中绝不 resize。任务会话活跃期目标恒为
    /// 工作尺寸：若布局已在工作尺寸则直接返回（收起不触发任何 resize），若会话开始时
    /// 布局还停在小窗真实尺寸（闲时小窗浏览后直接发起任务），则在此一次切回工作尺寸。
    ///
    /// 触发源门（DOCK-NAV-PASSKEY-FIX）：userGesture=false 的生命周期 settle（会话
    /// 开始／终结、容器尺寸变化）只允许「长回工作尺寸」方向的 resize；目标小于当前
    /// layoutScale（＝缩到 dockSize）时直接放弃落定，布局保持现状（小窗态即工作尺寸
    /// 布局＋缩放渲染）。缩到 dockSize 只允许 userGesture=true 的用户显式展开／收起
    /// 手势 settle 落定。这样任何导航事件——包括紧跟任务终结的发表跳转——都无法再
    /// 把活动视口被动缩到小窗真实尺寸。
    private func scheduleSettle(userGesture: Bool) {
        settleTask?.cancel()
        let targetMode = mode
        let targetLayoutMode = layoutMode
        let revisionAtSchedule = web.revision
        settleTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(480))
            guard !Task.isCancelled, mode == targetMode, layoutMode == targetLayoutMode, area.width > 0 else { return }
            let target = settleTargetScale()
            guard abs(layoutScale - target) > 0.001 else { return }
            // 触发源门：非用户手势的 settle 不许缩（往 dockSize 方向一律放弃落定）
            if !userGesture, target < layoutScale { return }
            let fraction = await scrollFraction()
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { layoutScale = target }
            if web.revision == revisionAtSchedule, let fraction {
                try? await Task.sleep(for: .milliseconds(150))
                guard mode == targetMode, layoutMode == targetLayoutMode else { return }
                await restoreScrollFraction(fraction)
            }
        }
    }

    /// 页面纵向滚动比例（0–1）；页面不可滚动时返回 nil（无需恢复）。
    private func scrollFraction() async -> Double? {
        guard let raw = try? await web.evaluate("(()=>{const h=document.documentElement.scrollHeight-window.innerHeight;if(h<=0)return -1;return Math.min(1,Math.max(0,window.scrollY/h));})()"),
              let number = raw as? NSNumber else { return nil }
        let value = number.doubleValue
        return value >= 0 ? value : nil
    }

    private func restoreScrollFraction(_ fraction: Double) async {
        _ = try? await web.evaluate("(()=>{const h=document.documentElement.scrollHeight-window.innerHeight;if(h>0)window.scrollTo(0,\(fraction)*h);return true;})()")
    }

    private func restoreCenter(area size: CGSize) {
        let scale = DockGeometry.miniScale(area: size)
        if storedXFrac >= 0, storedYFrac >= 0, size.width > 0, size.height > 0 {
            miniCenter = DockGeometry.clampedCenter(
                CGPoint(x: storedXFrac * size.width, y: storedYFrac * size.height),
                area: size, scale: scale, bottomReserve: bottomReserve)
        } else if miniCenter == nil {
            miniCenter = DockGeometry.defaultCenter(area: size, scale: scale, bottomReserve: bottomReserve)
        }
    }

    // MARK: - 护盾手势

    private func shieldDragChanged(_ value: DragGesture.Value) {
        if dragStartCenter == nil {
            dragStartCenter = miniCenter ?? DockGeometry.defaultCenter(area: area, scale: DockGeometry.miniScale(area: area), bottomReserve: bottomReserve)
        }
        // 拖动跟手不走动画事务，避免弹簧滞后
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) { dragDelta = value.translation }
    }

    private func shieldDragEnded(_ value: DragGesture.Value) {
        let start = dragStartCenter ?? miniCenter ?? DockGeometry.defaultCenter(area: area, scale: DockGeometry.miniScale(area: area), bottomReserve: bottomReserve)
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
        let snapped = DockGeometry.snappedCenter(predicted: predicted, area: area, scale: scale, bottomReserve: bottomReserve)
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
