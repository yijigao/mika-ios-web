# Mika Web 触摸网页闪退最小化阶梯 — CRASH-LADDER

- 日期：2026-11-02（构建交付完成，待 Joey 按阶真机测）
- 触发：1652 逐字基线构建 202611020016 真机复测**一点网页即崩**（Joey 2026-11-02 08:30）。结论：v0.2 以来的全部增量整体脱罪；「1652 点网页不崩」这一前提从未被真机验证过（1652 当时只验了设置页与跑任务，点网页手势的首测在 1747 上）。病因在所有构建共有的地基里，本轮用最小化阶梯自下而上分离地基层级。
- 代码：分支 `crash-ladder`（自主线 HEAD 另建，主线规格文件未动）。三阶共用同一套阶梯代码（新文件 `MikaWeb/Harness.swift` + 分支专用 `MikaWebApp.swift` 入口），**三个构建之间唯一的源码差异是 `Harness.step` 常量取值（0→1→2）**，每阶提交经 `git diff --stat` 核验为 1 行。validate_project.py 全 PASS（18 源文件）。

## 0. 共同点（三阶恒定，不构成阶梯内变量）

- **起始页**：生产 App 没有远程默认 URL——`WebController.init` 用 `loadHTMLString` 加载一段本地 HTML（标题页：`<h1>Mika Web</h1><p>在地址栏打开网页，或输入包含网址的任务。</p>`，baseURL=nil）。阶梯三阶均逐字复刻该 HTML（已用脚本与 WebController.swift 原文比对，一致）、同样的 `WKWebViewConfiguration`（`websiteDataStore=.default()`）与同样的 customUserAgent（Mac Safari 串，比对一致）。Joey 测试时打开 App 停留在起始页直接点，**不要先输网址跳转**（页面变量恒定要求）。
- **诊断**：三阶均带 DiagnosticStore + MetricKit，App 入口启动即 `diagnostics.start()`；崩溃报告导出入口为右下角圆形按钮（打开 CrashReportsView），三阶恒定。该包装（根 Group + overlay 按钮 + sheet）位于视图树外层、按钮不遮挡上方网页区（必崩手势区）。
- **App 入口**：三阶同为阶梯专用最小装配（仅 DiagnosticStore），与生产 App 的对象装配（WebController/SettingsStore/AgentEngine/AgentConversationStore 由 App 持有）不同——此差异三阶恒定，属「三阶全稳」分支另开一轮的范围（装配组合层）。
- 构建号机制同既往：fastlane 现场以 UTC 时间戳生成、不落仓；版本串均为 0.1.0，认构建号区分。

## 1. 三阶构建

### H0 — 裸 WKWebView

- 构建号 **202611020036**（build id `bd581e50-2f4f-4cdf-a0d7-ebbbd79b49d4`），提交 `a3cabd2`；CI Run 41367853188 success、Release Run 41368007955 success。
- 内容：单屏只有一层 WKWebView 的 UIViewRepresentable（`HarnessBareSurface`：makeUIView 返回裸持有者 `HarnessWebBox` 创建的 WKWebView，updateUIView 空操作，无 Coordinator）。无 NavigationStack、无 toolbar、无地址栏、无任何 store 注入（诊断除外）。裸持有者无 ObservableObject/无 @Published/无 navigationDelegate/无 KVO；其创建口径（配置、UA、起始页加载）与 WebController.init 一致，差别仅在不装配观察与代理。
- ASC：processingState=**VALID**、expired=false、usesNonExemptEncryption 已 PATCH=false、已挂 Internal 组（组内回读在位、居首）。

### H1 — H0 + 1652 形态浏览器 chrome

- 构建号 **202611020045**（build id `b59589a3-ab9e-4f41-a23d-8bc78e4021b3`），提交 `a638f2d`（与 H0 的 diff 恰为 step 0→1 一行）；CI Run 41368716521 success、Release Run 41368837716 success。
- 内容：NavigationStack + toolbar（标题「Mika Web」inline；toolbar 仅放阶梯标记占位——自检/设置导航项依赖地基之上的 App 装配，不在本阶）+ 地址栏行（后退/前进/TextField/刷新，布局形态取 1652 BrowserView 的 chrome 原文），底部不放控制台；WebView 仍用 H0 的裸 representable，按钮与地址栏直连 WKWebView（地址校验口径与 WebController.load 一致）。
- 与上一阶的唯一差异点：**chrome 层（导航栈/工具栏/地址栏输入链）加入**。
- 已知与 1652 原文的差别（全部属观察/代理装配，即 H2 层的内容，故不计入 H1 层）：前进/后退无 canGoBack/canGoForward 门控、无进度条行、无 pageError 行、地址栏不与 webView.url 同步（仅 onSubmit 直连加载）。

### H2 — H1 + 现行 BrowserView 地基本体

- 构建号 **202611020054**（build id `e6cd9fb7-9c1f-4c21-ab07-c8466a3fc80d`），提交 `2e9a33d`（与 H1 的 diff 恰为 step 1→2 一行）；CI Run 41369501063 success、Release Run 41369619422 success。
- 内容：chrome 骨架内换现行地基原文——`BrowserView`/`WebSurface`/`WebController` 均为仓库现行文件逐字使用（BrowserView 与 1652 本就逐字一致，前轮已验）；底部为静态占位视图（120pt 占位条），不接 AgentConsole/AgentChat，不带 conversation store 与 AgentEngine。
- 与上一阶的唯一差异点：**浏览器地基本体（WebSurface representable 包装 + WebController 的 KVO 观察/导航代理/@Published 同步装配 + BrowserView 全文呈现）替换裸 representable 与直连 chrome**。
- 注：WebController 由根视图以 @StateObject 持有（生产 App 由 MikaWebApp 持有），构造时机不同；BrowserView 挂载语境为原文。
- ASC：同 H0/H1——processingState=**VALID**、expired=false、usesNonExemptEncryption 已 PATCH=false、已挂 Internal 组。组内回读共 10 个构建在位，三阶梯构建居前三。

## 2. Joey 测试规程（按序，首崩即停）

1. TestFlight 更新到 **202611020036（H0）** → 打开 App（停留在起始页）→ 点上方网页 5 次 + 滚动 → 记崩/不崩。
2. H0 不崩才装 **202611020045（H1）**，同法测；H1 不崩才装 **202611020054（H2）**，同法测。
3. 在第一个崩的构建停下：崩后**重新打开 App**，点右下角圆形按钮打开崩溃报告，待系统送达后把最新一份分享发回（报告可能延迟送达；三阶都有此通道，与基线版 202611020016 无导出不同）。
4. 每阶根视图右下角有 H0/H1/H2 标记，可与构建号互核。

## 3. 判读预写（只定位到层，不写根因确认）

- **H0 崩** → 病因在 WKWebView 裸挂载 / 起始页 / iOS 系统层这一层：WKWebView 以最裸方式挂载、加载与生产相同的起始页仍崩，则转查页面与系统层（起始页内容、WKWebView 与当前 iOS 版本的交互、设备状态）。
- **H0 稳、H1 崩** → 病因在 chrome 层：NavigationStack / toolbar / 地址栏 TextField 输入链这一层。
- **H1 稳、H2 崩** → 病因在 BrowserView 地基本体层：WebSurface representable 包装 / WebController 观察与代理装配 / BrowserView 呈现这一层。
- **三阶全稳** → 触发点在地基之上的装配组合（生产 App 对象图 / 数据流：App 级 store 装配与 binds、conversation/engine 数据流、ContentView 观察扇出等），另开一轮自 H2 向上回加。
- 以上均为层级定位，不是根因确认；具体触发机制仍未分离。崩溃报告（带本阶构建的新偏移）回收后先核签名是否仍与既往一致，再决定该层内的下一步。
