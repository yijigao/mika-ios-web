# FLOATING-3LEVEL 实施记录（2026-11-03）

## 交付状态

- 目标分支：`feat/floating-3level`，基线 `feat/editor-entry-bind@7b7f5ee`，不合 `main`。
- 功能代码与 Tier A 自检二十五已实现；临时 metadata 中已形成清晰的单一功能提交（最终哈希见交付回报）。
- 本会话的 canonical `.git` 被权限配置为只读，不能在原仓库写 branch/ref/index；使用 `/tmp` 中的 Git metadata 副本从同一 `7b7f5ee` 建立目标分支并完成本地提交。向 `https://github.com/yijigao/mika-ios-web.git` 推送时，环境代理 `hatch-egress-proxy:3128` 拒绝连接；原仓库分支、远端推送和 workflow dispatch 因此仍属环境阻塞，不能冒充已完成。
- 构建号：**未知（release workflow 尚未触发）**。

## 实现内容

### 三级形态

- L1（默认）：92×124pt 快照卡，只显示页面快照、状态点和单行截断标题；整卡点按进入 L2；拖动后左右 8pt 贴边，纵向保留；默认右下且强制避开至少底部 120pt 禁停带。
- L2：保留原浮窗的约 40% 屏宽视觉尺寸、拖动/贴边行为；新增收起到 L1、展开到 L3 两个控件。
- L3：全屏浏览器；收起回 L2。
- App 冷启动、任务开始、任务终结信号均回 L1；会话内手动等级不被普通步骤改变。确认、密码/验证码手输及上传介入是唯一自动升到 L2 的路径。

### 视口与执行红线

- `BrowserView` 在 L1/L2/L3 始终以容器完整工作尺寸布局。L2 只使用 `scaleEffect` 做视觉缩放；L1 只把 live surface 设为 `opacity(0)` 并禁止触摸，另画快照卡。等级切换不再写 live webview 的 layout frame，旧 `layoutScale`/settle 真 resize 路径已删除。
- L1 不卸载、不释放、不挂起 live webview；agent 的 JS 注入、页面回读和步骤执行仍走原 `WebController`。
- 快照在导航完成（progress 到 1）和 agent 步流更新后请求刷新；生产节流器把 1 秒窗口内重复请求合并。`takeSnapshot` 失败返回 `nil`，L1 退化为带标题/状态的渐变纯色卡，不空白、不崩溃。
- `SafetyPolicy.swift` 零改动；`MikaWebApp.swift` / `AppObjectGraph` 零改动。

## 规格冲突（按令停止该点，未即兴改架构）

规格写“全局只有一个 WKWebView 实例”，但基线 `7b7f5ee` 已有标签架构：每个 `BrowserTab` 各自强持有一个 `WKWebView`，离屏标签依靠各实例保存 URL、滚动、登录及 JS 状态。这是本需求开始前已存在的直接架构冲突。

本实现没有创建任何额外 WKWebView，也没有改变 `AppObjectGraph` 持有形态；三级 UI 只复用当前标签原实例。没有把多标签强拆成单 WKWebView，因为那会破坏现有每标签状态契约，且属于规格明确要求“冲突则停止并记录、不要 improvising”的点。因此“全局物理实例数为 1”未声称达成；“三级切换不新建/释放/替换当前 live WKWebView”已达成。

## Tier A 自检

新增“自检二十五：三级浏览器浮窗（FLOATING-3LEVEL）”，不调用模型：

1. 直接驱动生产 `DockStateStore`，断言初始 L1 及 L1→L2→L3→L2→L1 顺序。
2. L2→L1 前后读取真实 `WKWebView.frame.size` 与页面 `window.innerWidth`，断言均不变。
3. L1 下向真实页面注入随机 token JS 并回读，证明 live webview 未挂起。
4. 生产 `SnapshotRefreshThrottle` 以合成时钟断言：1 秒窗口内第一次立即刷新，后续多次变化只合并为一个到期刷新。

本地结果：

- `python3 scripts/validate_project.py`：全 PASS（OpenStep、引用、单 App target、31 Swift 源、15 HTML 资源、scheme/Info.plist/ATS 等）。
- `git diff --check`：PASS。
- `SafetyPolicy.swift` 与 `MikaWebApp.swift` diff：0 行。
- SwiftCompile / BUILD SUCCEEDED：**未运行**。当前执行环境没有 `swift`/`xcodebuild`，不能伪造结果；需在 macOS CI 运行后回填真实日志双核对。
- 自检二十五真机结果：**未运行**，需构建安装后点按回读。

## CI / TestFlight

- 参照构建 `202611030901` 的路径：先跑 `.github/workflows/ci.yml` 做真实 SwiftCompile＋BUILD SUCCEEDED 双核对，再以 `workflow_dispatch` 触发 `.github/workflows/release.yml`（Release (TestFlight)）。
- CI run：未产生（canonical 分支无法推送；GitHub 网络连接失败）。
- Release run：未产生。
- 已实际执行 `gh workflow run release.yml --repo yijigao/mika-ios-web --ref feat/floating-3level`；GitHub API 请求被本环境代理策略拒绝（`socket: operation not permitted`），未产生伪 run。
- TestFlight build：未知。
- ASC VALID / Internal 组：未验，不声称交付。

## Tier B 待验

1. 新任务首帧为右下 L1 卡且不挡输入栏/停止继续区。
2. 卡→L2→L3→L2→L1 全循环，拖动贴边和两个收回控件均顺畅。
3. L1 下跑公众号取数步骤完整结束，期间状态点和快照刷新。
4. 长截图遮挡只剩约 92×124pt 卡片。
5. 安全介入自动升 L2，处理后可手动回 L1；URL、滚动、登录及 JS 状态不丢。
