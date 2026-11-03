# FLOAT-BUTTON 方案甲实施记录（2026-11-04）

## 规格对照

仅修改 `MikaWeb/AgentChatView.swift` 的任务动作带。停止、继续及结束任务共用毛玻璃胶囊：`.ultraThinMaterial`、0.5pt separator 描边、黑色 0.08／半径 6／y 2 投影、32pt 视觉高度、14pt 水平内边距、64pt 最小宽度。44pt 外层高度与矩形 `contentShape` 构成点按热区。文字为 subheadline semibold；停止的 `pause.fill` 与继续的 `play.fill` 均为 11pt，停止和结束任务用 primary 标签色，继续用 accent tint 色。三个按钮均有对应的中文 accessibilityLabel。

动作带以左侧密钥提示、`Spacer`、右侧胶囊组排列。结束任务紧贴继续左侧。没有胶囊且没有密钥提示时，整个 HStack 不生成，不占高度。胶囊及动作带以 180ms easeOut 透明度过渡，停止与继续切换交叉淡化；系统开启「减少动态效果」时禁用这些动画。输入栏上方的带位置、父层 `.padding(12)` 和 `.padding(.bottom, bottomInset)` 均未改。

## 自检二十五锚点

`BrowserDockView.swift` 内的 `FloatingVisibilityToggle`、`FloatingVisibilityToggleGeometry` 未修改；`AgentChatView.swift` 内 `ChatInputBar` 的圆钮挂载、offset 和文本让位未修改。自检二十五的既有文件及断言未修改。圆钮的材质、位置和动效沿用原实现。

## 可见性矩阵

| 状态 | 停止 | 继续 | 结束任务 | 无密钥提示 |
|---|---|---|---|---|
| 待命 | 隐藏 | 隐藏 | 隐藏 | `!settings.hasKey` 时左侧显示；否则整带消失 |
| 运行且正看任务会话 | 显示 | 隐藏 | 隐藏 | `!settings.hasKey` 时左侧显示 |
| 待确认／待手输介入 | 隐藏 | 隐藏 | 隐藏 | `!settings.hasKey` 时左侧显示；介入入口仍由介入卡提供 |
| 暂停且正看任务会话 | 隐藏 | `canResume` 为真时显示 | `engine.active` 时显示，位于继续左侧 | `!settings.hasKey` 时左侧显示 |
| 失败且正看任务会话 | 隐藏 | `canResume` 为真时显示 | 隐藏 | `!settings.hasKey` 时左侧显示 |
| 键盘起落 | 依当前任务状态 | 依当前任务状态 | 依当前任务状态 | 依密钥状态；动作带随输入栏原有布局升降 |

停止判断式为 `engine.busy && engine.active && viewingRunSession && questionID == nil`，并排除 `.waitingConfirm`、`.waitingManual`。继续直接使用原 `canResume`，要求 active、无 questionID、正看任务会话且状态为 `.paused` 或 `.failed`。结束任务要求 `isPaused && viewingRunSession && engine.active`。密钥提示只取决于 `!settings.hasKey`。键盘起落不引入独立位置或曲线。

## 原置灰语义对应

原停止按钮在 `!engine.busy || !engine.active || !viewingRunSession` 时置灰；现在这些条件使按钮不渲染，并额外在问题待答或介入态隐藏。原继续按钮在 `!canResume` 时置灰；现在仅在 `canResume` 时渲染。原结束任务按钮在暂停且正看任务会话时呈现、`!engine.active` 时置灰；现在仅在原呈现条件且 active 时渲染。三个点击调用分别仍为 `engine.stopFromUser()`、`engine.resume()`、`engine.finishTaskFromUser()`；`viewingRunSession` 的会话归属口径未变。
