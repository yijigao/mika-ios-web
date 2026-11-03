# FLOATING-VISIBILITY 实施记录（2026-11-03）

## 交付状态

- 已按 `FLOATING-VISIBILITY-SPEC-2026-11-03.md` 用隐藏／显示模型替换 `FLOATING-3LEVEL`。
- 变更留在 `feat/floating-visibility` 工作树中，未提交、未推送、未触发 workflow（本环境 Git metadata 只读且禁止 push）。
- SESSION-UX 的会话抽屉、消息滚动、回到底部按钮、输入栏测高与自检二十六保持原样。

## 移除与保留

- 删除 `DockLevel` 及 L1/L2/L3 等级状态机、L1 快照卡、快照刷新节流和等级切换控件。
- 删除以快照卡作为静默默认形态的渲染及刷新监听；`WebController.floatingCardSnapshot()` 辅助函数仍保留，当前显隐实现不调用它。
- 保留既有约 40% 屏宽的浮窗尺寸、拖动贴边位置和面板内“展开全屏”动作；全屏仍由既有收起控件回到浮窗。
- 没有新增、替换、释放或挂起 `WKWebView`。`BrowserView` 始终挂载，始终取得同一个全工作区 frame；隐藏只设置容器 `opacity` 和 `allowsHitTesting`，不改变 webview frame、viewport 或执行通道。

## 实现的显隐状态机

`DockStateStore` 只保存底层期望显隐 `desiredVisible`、安全介入覆盖 `interventionRequired` 和已显示面板的全屏动作标志 `fullScreen`。有效可见性为：

`isVisible = desiredVisible || interventionRequired`

- 冷启动／静默：`desiredVisible = false`，面板隐藏。
- 任务开始或恢复（`sessionActive` 进入 true）：清除上次任务选择并自动显示；全屏回到普通浮窗。
- 任务终止、失败、停止／取消（`sessionActive` 进入 false）：清除选择并隐藏；全屏复位。
- 静默手动开关：直接翻转 `desiredVisible`，保持到再次点按或下一次任务迁移。
- 任务中手动隐藏：将 `desiredVisible` 置假；普通步骤更新不改它，因此在本任务内持续隐藏。
- 安全介入：`interventionRequired = true` 强制有效可见，并临时禁止开关隐藏；底层 `desiredVisible` 不被覆盖。介入解除后，若用户此前在本任务内隐藏则恢复隐藏；若任务仍期望显示则继续显示；若任务已终态则保持隐藏。
- 介入卡的既有“打开浏览器”仍可进入全屏。全屏时按规格隐藏固定开关，退出全屏后恢复。

原实施的固定开关为右下 44pt 圆形 Safari 浏览器图标；其挂载与外观已由下方 2026-11-03 增补替代。显隐状态语义保持不变。

## 自检二十五改版

沿用编号 **自检二十五**，标题改为“浏览器浮窗显隐（FLOATING-VISIBILITY）”。Tier A 现在断言：

1. 冷启动静默隐藏且固定开关可见。
2. 任务开始自动显示，终态自动隐藏。
3. 静默手动开／关。
4. 任务中手动隐藏保持到任务迁移。
5. 安全介入强制显示、拒绝隐藏，解除后恢复本任务底层选择；终态仍隐藏。
6. 真实 live `WKWebView` 从显示切到隐藏前后 frame 与 `window.innerWidth` 不变。
7. 隐藏状态向真实页面注入随机 token JS 并成功回读，证明 agent 执行未暂停。

原三级循环和快照节流断言已删除，不再保留与新模型冲突的 L1/L2/L3 预期。

## 增补：开关夹挂输入栏（2026-11-03）

- 按 `FLOATING-VISIBILITY-ADDENDUM-2026-11-03.md`，固定开关从屏幕右下独立覆盖层移入 `ChatInputBar`，夹在输入栏左上角：32pt 圆钮相对输入栏左上角固定偏移 `(12, -16)`，上下各占半枚按钮。
- 开关与输入栏属于同一视图单元，因此键盘升降时沿输入栏的同一安全区动画同步位移，不再独立定位。浏览器全屏时输入栏整组以底部移动＋淡出过渡收起，开关同时不可见；退出全屏时整组同步呼入。
- 输入栏左侧内容起点由 12pt 调为 52pt，完整避开按钮占位；开关位于左侧，不占用右上方“回到底部”按钮通道。
- 外观改为 32pt 圆形超薄材质按钮，采用 Safari SF Symbol、细描边、轻投影和按压缩放回弹。状态徽标融入右上角：运行态为强调色并轻柔呼吸，介入态红色，静默态降饱和；显隐与状态变化使用同一克制弹簧动画。
- 自检二十五新增三项 Tier A 生产布局断言，并与生产视图共用 `FloatingVisibilityToggleGeometry` 常量：①键盘收起／升起两态相对输入栏左上角锚点偏移恒定；②输入栏隐藏或浏览器全屏时按钮不可见；③两态下按钮 frame 均不与文字输入区相交。
- 本增补没有修改 `DockStateStore` 的显隐状态迁移、`SafetyPolicy`、`AppObjectGraph`、executor 或 queue。

## 验证

- `python3 scripts/validate_project.py`：全部 PASS（OpenStep、引用、单 App target、31 个 Swift 源、15 个 HTML 资源、scheme、Info.plist、ATS 等）。
- `git diff --check`：PASS。
- `SafetyPolicy.swift`、`MikaWebApp.swift` / AppObjectGraph：零 diff。
- 生产执行、串行队列与安全判定逻辑未改；`AgentEngine.swift` 的唯一变化是按要求改写既有自检二十五函数。
- SwiftCompile / 真机自检：当前 Linux 环境没有 `swift` 或 `xcodebuild`，未运行且不声称通过；需由 macOS 构建与 Joey Tier B 真机验收补齐。

## 冲突

实施中没有遇到需要停止并另行裁决的规格冲突。
