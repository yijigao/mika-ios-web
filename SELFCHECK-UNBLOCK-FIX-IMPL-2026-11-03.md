# SELFCHECK-UNBLOCK-FIX 实施案卷（2026-11-03）

## 0. 结论

构建 **202611030713**（0.1.0），分支 `feat/selfcheck-unblock-fix`（基线＝feat/cover-upload-fix tip `38d1632`，含构建 202611030625，未合 main）。功能提交 `a986586`。

0625 真机现场的产品缺口已对治：暂停态任务现在有彻底终结出口——消息区按钮行在暂停态多出「结束任务（不可续跑）」，点后任务落终结态、快照清除、引擎解锁，自检与新任务不再被一个已停止的任务永久挡住；全部自检的忙碌提示文案已改为与实际一致的口径（不再谎称「停止」能解锁）。

ASC 状态：**待阿仁亲验**（本文不记 VALID、未挂组）。

## 1. 根因（真机实证＋代码实证）

Joey 2026-11-03 两张截图（14:52／15:05）：构建 0625 上，一个更新前中断的旧任务被快照恢复，点「停止」后步流显示「用户已停止，可继续或重新开始」，随后跑自检二十二仍两条都报「✗ 引擎忙碌中，未执行（先等当前任务终结或停止）」。

代码事实（基线 AgentEngine.swift）：

- `busy` 计算属性把 `.paused` 也算忙碌（基线约 660 行）；
- `stop()`（基线约 722 行）在 busy 时只把 status 置为 `.paused("用户已停止，可继续或重新开始")` 并 `persistSnapshot()`——「停止」只是暂停：任务保持可续跑、快照保留、引擎永不解锁；
- 自检各条的 `guard !busy` 文案却写「先等当前任务终结或停止」，与实际不符（照文案点停止永远解锁不了）；
- UI 上没有把暂停/中断任务彻底终结（丢弃）的出口：用户只能「继续」把它跑完、等它自然终结，或发新任务覆盖（startInSession 先 stop 再重置）。

定性：产品缺口，非用户操作问题。

## 2. 改动清单（4 文件，diff ＋130／−14）

### AgentEngine.swift

1. **新终结态**：`AgentStatus` 新增 `.ended(String)`，label 为「已结束：…」。其余既有 switch 均有 default 且行为自动正确——`busy` 不含 .ended（解锁）、`currentStatusKind()` 对 .ended 返回 nil（不落盘）、会话 adopt／拒答／介入呈现均不误认它为活动态。唯一需补的穷尽 switch 在 AgentConsoleView（见下）。
2. **`finishTask()`**（stop() 之后新增）：仅 busy 时有意义。动作序列与 stop() 的收尾同源并加终结项——换代次＋取消 worker（迟到回复作废）、`discardPendingUpload()`（SP-01 未消费凭据作废＋待供文件解除武装）、释放运行上下文/后台宽限/持续处理句柄、`web.endExecution()` 释放执行页绑定、清 waitingInput 与段限暂停标记、清中断恢复现场（pendingTabScene/restoredSession/resumeNote）、清 goal（resume 无目标可续）、status 落 `.ended("用户已结束任务")`、`appendStep("ended", …)` 在步流留「任务已结束：用户手动终结本任务——快照已清除、不可续跑…」记录、最后 `clearSnapshot()` 清该会话快照（重启 App 不再恢复此任务）。此后 `busy == false`。
3. **`finishTaskFromUser()`**（stopFromUser() 之后新增）：finishTask 后调 `advanceQueue()`——任务已落终结态、执行权真正空出，排队任务按序启动，与 stopFromUser 的用户终止口径一致。`advanceQueue` 的终结态集合相应加入 `.ended`，其文档注释同步增补此终结点。
4. **自检二十三** `verifyTaskFinishUnlock()`：见 §5。
5. **忙碌文案修齐**：见 §4。

### AgentChatView.swift（UI 落点，见 §3）

按钮行在「停止」之后、「继续」之前插入「结束任务（不可续跑）」按钮，仅 `isPaused && viewingRunSession` 时呈现，点按走 `engine.finishTaskFromUser()`，`!engine.active` 时禁用（与停止/继续的前台与会话归属口径一致）。

### AgentConsoleView.swift

`statusColor` 穷尽 switch 补 `.ended` 与 `.idle` 同归 `.secondary`（一行）。控制台自身的停止/继续行未动（其「停止」仍是暂停；丢弃入口在消息区按钮行，见 §3 注记）。

### SelfTestView.swift

新增自检二十三按钮＋预期说明＋编排 `runTaskFinishTest()`（模式同自检二十二编排：localFeedback 逐条写回对话＋结论行）。

## 3. UI 落点

- 位置：消息区底部按钮行（Joey 截图里「停止／继续」所在行），顺序为 停止 → **结束任务（不可续跑）** → 继续。
- 呈现条件：任务处于 `.paused`（用户停止的暂停、中断恢复待决策的暂停、步数段限暂停等一切非运行暂停同为此态）且正看的就是任务所在会话。运行中不呈现（跑动中的任务先「停止」变暂停、再决定是否结束——两段式与「停止」的既有手感一致）；等待确认／等待手输不呈现（那两态各有专属介入卡出口，终结诉求可先经停止落到暂停态再结束，或直接发新任务覆盖，同既有口径）。
- 无二次确认弹窗（与「停止」同级）；文案带「不可续跑」与「停止（可继续）」明示区别，点了即真丢弃。
- 注记：AgentConsoleView（旧控制台面）的按钮行未加此按钮——Joey 的实际使用面是消息区（两张现场截图均在此面），控制台留待后续如有需要再补；引擎侧 `finishTaskFromUser()` 是共用入口，补按钮只是呈现层一行。

## 4. 文案逐条对照（忙碌提示）

统一改动：后缀「（先等当前任务终结或停止）」→「（当前任务未终结：可等它跑完，或在暂停时点『结束任务』）」。grep "引擎忙碌中" 全量核对，AgentEngine.swift 内 guard 行共 10 条全改，无遗漏；仓内其他文件无此文案。

| # | 函数（自检） | 改前 | 改后 |
|---|---|---|---|
| 1 | verifyMultiSessionShell（九 Tier A） | ✗ 引擎忙碌中，Tier A 未执行（先等当前任务终结或停止） | ✗ 引擎忙碌中，Tier A 未执行（当前任务未终结：可等它跑完，或在暂停时点『结束任务』） |
| 2 | verifyCoverAndModal（十一 Tier A） | …自检十一 Tier A 未执行（先等当前任务终结或停止） | …自检十一 Tier A 未执行（当前任务未终结：…） |
| 3 | verifyActionVerificationContract（十三 Tier A） | …自检十三 Tier A 未执行（先等…） | …自检十三 Tier A 未执行（当前任务未终结：…） |
| 4 | verifyFrameProbe（十四 Tier A） | …自检十四 Tier A 未执行（先等…） | …自检十四 Tier A 未执行（当前任务未终结：…） |
| 5 | verifyEditorNav（十六 Tier A） | …自检十六 Tier A 未执行（先等…） | …自检十六 Tier A 未执行（当前任务未终结：…） |
| 6 | verifyAutonomy（十八） | …自检十八未执行（先等…） | …自检十八未执行（当前任务未终结：…） |
| 7 | verifyTrustedClick（二十） | …自检二十未执行（先等…） | …自检二十未执行（当前任务未终结：…） |
| 8 | verifyLadderFix（二十一） | …自检二十一未执行（先等…） | …自检二十一未执行（当前任务未终结：…） |
| 9 | verifyCoverUploadFix（二十二） | …自检二十二未执行（先等…） | …自检二十二未执行（当前任务未终结：…） |
| 10 | verifyUploadPanelSupply（二十二回路） | …自检二十二回路未执行（先等…） | …自检二十二回路未执行（当前任务未终结：…） |

（表中「当前任务未终结：…」为统一后缀「（当前任务未终结：可等它跑完，或在暂停时点『结束任务』）」的缩写。仓内现存「当前任务未终结：可等它跑完」共 11 处：上表 10 条＋自检二十三 guard 1 条，后者新写即为新口径，grep 实查。）

## 5. 自检二十三设计（verifyTaskFinishUnlock）

纯逻辑演练，不调用模型、不占用标签页；入口 `guard !busy` 与其余自检同口径（引擎须空闲——这正是本单要修的用户路径：先点「结束任务」解锁、再跑自检）。流程：

1. 保存引擎现场（status、goal、steps、stepSeq、waitingInput、stepLimitPaused、conversationTaskID、stateCard——落盘会经 refreshStateCard 改卡，一并保存）；演练期间 conversationTaskID 暂置 nil，使合成步流不路由进真实对话。
2. 合成暂停态：goal 置合成目标、status 置 `.paused`、waitingInput 置合成 question、persistSnapshot 落盘；断言 busy == true 且快照文件在位（未结束时引擎保持锁定，与真机现场同型）。
3. 调 finishTask()，逐项断言：busy == false 且 status 为 .ended；会话快照文件已删除；waitingInput 已清且 goal 已清；再调 resume() 后状态仍为 .ended 且不忙碌（任务不复活）；web.executionTabID == nil 且待供文件未武装。
4. 还原全部保存现场并 clearSnapshot 兜底，断言回到空闲。

已知化妆性副作用（如实记）：演练中状态机经过 .paused，对话层状态 sink 会按既有行为把一条「自检二十三合成暂停」状态条目写进当前对话（与自检四模拟中断同级的测试噪声，不影响功能状态）；演练前的完成/失败展示态在还原时会被状态 sink 再写一条同文条目，同属既有对话层行为、非本单引入。

Tier A 未在本机运行（无 Swift 工具链）；实际结论以真机运行为准，不得视为已验。

## 6. 不变的语义（工单第 3 条逐项核对）

- `busy` 判定不变：仍为 running/waitingConfirm/waitingManual/paused 四态为真（diff 实查该计算属性未动）。
- 「停止＝可续跑暂停」不变：stop() 本体未动（仅其后新增 finishTask）。
- 中断恢复链路不变：restoreSnapshot／applyPendingTabRestore／resume 未动；只是多了用户主动丢弃的出口（finishTask 清的恢复现场是内存暂存与该会话快照文件，正是恢复的两个来源，语义自洽）。
- 多会话队列与代次绑定不变：advanceQueue 仅在终结态集合中增补 .ended（与 done/failed 同列），推进条件（active、模型就绪）未动；代次机制未动（finishTask 换代次与 stop 同款）。

## 7. 发版链证据

- validate_project.py：全 PASS（31 Swift 源恰好引用一次、Info.plist 与资源集通过）。
- CI Run **41594523715** success（日志原文双核对：70 条 SwiftCompile、本单 4 个改动文件 AgentEngine/AgentChatView/AgentConsoleView/SelfTestView 均在编译列、BUILD SUCCEEDED ×1、BUILD FAILED ×0，唯一 error: 为既有 AppIntents 训练噪声）。首跑即真绿，无假绿重跑。
- Release Run **41594831597** success（agvtool 置号 202611030713、Archive Succeeded ×1、Successfully uploaded package to App Store Connect、dSYM artifact dsym-41594831597 5,504,585 字节实存未过期；日志内 error: 仅同上 AppIntents 噪声）。ASC 状态：**待阿仁亲验**。

## 8. 红线复核

- AppObjectGraph 持有形态零改动：`git diff 38d1632..HEAD -- MikaWeb/MikaWebApp.swift` 实查 0 行。
- SafetyPolicy 零改动：同法实查 0 行。
- 无新依赖（仅既有系统框架内改动）；新增文案无「并行」表述（diff 实查）。
- 未合 main；父级 SPEC 文件未动未提交。

## 9. 未证项与 Tier B 真机复测清单（Joey）

未证（不得视为已验）：

1. 自检二十三 Tier A 未真机运行。
2. 「结束任务」按钮的真机呈现（暂停态出现、运行态不出现、切到别的会话不出现）与点按全程（状态标签变「已结束」、步流出现「任务已结束」记录）未真机验。
3. 结束后冷启动不恢复：以真机杀进程重启实证为准（自检二十三只证快照文件已删，恢复链只读该文件是代码事实、未在真机走完一轮）。

Tier B 复测（按序）：

1. **原现场复现与解锁**：让一个任务中断/暂停（或直接用现存的已暂停旧任务），先点「停止」确认仍是暂停、按钮行出现「结束任务（不可续跑）」；点它——状态变「已结束」、步流多一条「任务已结束」；随后跑**自检二十二**，应能正常执行（不再报引擎忙碌）。再跑**自检二十三**留逐条结论。
2. **重启不恢复**：结束任务后杀掉 App 重开，原会话不得再出现「上次任务在 App 退出时中断，点继续可接着跑」，该任务不得被恢复。
3. **暂停续跑不回退**：新开一个任务，跑动中点「停止」（仍是暂停、文案「可继续或重新开始」），点「继续」应能续跑同一任务到完成。
4. **运行中停止语义不回退**：任务运行中点「停止」仍是暂停而非终结（按钮行随后出现「结束任务」即为佐证）；等待确认/手输态不出现「结束任务」按钮（各走介入卡），属预期。
5. （可选）队列：一个任务暂停时若有排队任务，点「结束任务」后排队任务应自动启动。
