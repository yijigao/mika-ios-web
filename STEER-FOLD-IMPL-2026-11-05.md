# MIKA-STEER-FOLD 实施报告（2026-11-05）

## 交付范围与验证口径

- 分支：`feat/steer-fold`；基线：`dc5424626152396347b540de1b77cfb47bcc2f8f`。
- 依据本目录 `DISPATCH-BRIEF.md`、`STEER-FOLD-SPEC-2026-11-05.md`（含末尾阿仁裁决）和 `astra-steerfold-out.md`；同会话覆盖按侧车裁决实施，不扩展按任务快照。
- 已完成 FOLD、STEER、待发条、三态长按菜单、自检四十三/四十四及工程引用；已回读全量改动。
- 本机没有 `xcodebuild` 或 `swift`，没有进行 Swift 编译或运行 App 自检。下表区分“逻辑层断言已覆盖、静态回读核对”和“实际执行通过”；不能把前者冒充运行证明。Swift 断言的执行结果、既有自检全量运行结果及 UI 联动仍须 CI/真机确认。
- 未打开 dsh-Go 仓库，未复制其代码、文案原句或素材；全部按本规格中文描述独立实现，未引入任何第三方代码或应用依赖。
- 不 push，不操作其他分支、主 checkout、凭据或服务。派工输入三份文档保持原状，不纳入本次实现提交。

## FOLD 实现

`MikaWeb/SteerFold.swift` 中的 `ProcessFold.nodes` 是只读 `[ChatEntry]` 的确定性变换：仅相邻、同 taskID 的 process 合组，其余所有 kind 独立成行并打断组。组 ID 为 taskID＋该任务过程组序号；不修改底层条目、stepID 或文本。摘要统一压平空白并截取 96 字符。

消息流和控制台共用 `ProcessFold.nodes/header/summary/accessibility`。消息流默认收起、组头一行；点开沿用每条原文本和无障碍标签。控制台默认最新动作与总数，展开保留原 120pt 滚动列表。展开状态只在视图内存，切会话时清空，控制台新任务时也清空，新过程组默认收起；进入终态自动收起。

最终文案：运行/等待/暂停为“正在执行 · 第 N 步 · 最新摘要”；成功为“已完成 N 步”；失败/结束为“已停止 · 共 N 步”。运行态 N 是尾条的 stepID（无 stepID 才回退组内条数）；终态 N 为该连续组的条数。控制台补总数/最新动作。组头无障碍标签始终包含条数和最新动作。

标题副行保留原步骤计数；滚动跟随仍以 `conversation.entries.count` 变化触发，未改 SESSION-UX 距底阈值、回底按钮或定位函数。FOLD 不改变条目生成、seenSteps 去重、路由、后台攒批或持久化函数。

### 自检四十三：逐项断言

入口：`SelfTestView` → “自检四十三：过程降噪 FOLD” → `ProcessFoldTierA.verify()`。

| 规格项 | 逻辑层断言与静态核对 | 尚待 CI / 真机 |
| --- | --- | --- |
| ① 连续 process 合组、步数/摘要正确 | 两条合一，断言运行组头为第 2 步及尾动作 | Swift 断言执行；实时 UI 更新 |
| ② 错误/结果/用户条目打断 | 对 error/result/userTask/userAnswer/userSteer/question/manual/pause/local 逐项断言前后不合并 | 各类条目的实际可见性 |
| ③ 空流/无 process 等价 | 空数组、单条非 process、非 process 流的条目 ID 顺序等价 | Swift 断言执行 |
| ④ 运行尾行与终态文案 | 运行摘要、成功/停止条数、终态无障碍最新动作断言 | 自动收起、VoiceOver 和滚动表现 |
| ⑤ 跨 taskID 不合并 | 异任务两组，重复变换组 ID 相同 | Swift 断言执行 |

## STEER 数据、消费与持久化

`SteerState` 只拥有 taskID/sessionID、插话项和反馈信息，没有 goal、taskText、answerContext 或 StepBudget 的读写能力。待生效项最多 3 条；第 4 条保留草稿并提示“已有 3 条插话待生效，请等其生效或撤回一条”。

唯一消费调用在 worker 的 `pendingLoopHint/pendingOutcomeHint` 区域、assemblePrompt 之前。按入列顺序一次取尽，持久化 applied/consumedStep，再把本轮局部 steerHint 交给组装函数；段名为“用户插话”。组装的预算重建复用本轮参数，不再次消费；下一轮消费返回 nil。消费本身不 appendStep、不调用 consumeDecision、不写 goal/taskText/answerContext；既有模型返回动作计数点原样保留。

选择的存储方式：快照新增可选 `pendingSteers` 镜像，仅存未生效项；每会话目录另有原子写入的 `steers.json`，内部按 taskID 记录状态及中断待发请求。侧车为消费/转移的权威，快照旧镜像不能复活已消费项。已生效记录作为侧车凭证保留至任务收口/新任务清理，恢复时不注入。没有插话记录的正常新任务不写空侧车。

`SteerProjection` 用插话 ID 和固定反馈 ID 更新/补写条目，保留 userSteer 原文；作废反馈写明条数、逐条 ID、原文和去向。侧车先提交状态，随后将投影原子写入所属会话 entries 文件；写失败保留侧车，恢复按固定 ID 补写。当前会话仍分别保留 entries 与 batchedEntries；其他会话只写所属文件，遵守原持久化条数上限，不提前裁掉当前会话内存条目。

兼容：ChatEntry 模型移到 Foundation 文件，kind 新增 userSteer；自定义解码保留所有旧 rawValue，未知 kind 降级为 local 并保留原文。新增 steerStatus/steerRetryText 均为可选字段，旧文件缺键仍能解码。尾标采用“将在下一步生效”→“已生效”，未吸收到组头；终态改为“未生效（任务已结束）”。

### 冻结与阿仁侧车裁决

- 暂停将原 taskID 的 pending 标为 frozen；显式继续后转回 pending，在原任务下一轮唯一消费点消费。
- done/failed/ended：先持久化作废状态，保留原文条目并落一条可定位 local 反馈，成功后清该 taskID 侧车记录；不重发、不转队列。
- 所有 startInSession 路径在新任务落定前检查目标会话残留：逐条作废，反馈为“N 条插话因新任务启动未生效，已作废……”并列 ID/原文；投影落盘成功后才清记录。
- 跨会话 B 启动只处理 B 的侧车，不清 A 的快照/侧车；待发条按 runSessionID＋conversationTaskID 取数据，不能把 A 的文字显示给 B。切回可恢复的 A 后，冻结项仍可显式继续。过期或已无可恢复快照的任务按作废路径补反馈。

### 转队列与中断的事务边界

待插话改排队：先将侧车项标 queued（不再能作为插话消费），通过 enqueueTask 的转移重载提交到同一 M1 queuedTasks，项 ID 复用插话 ID。队列文件将任务与 acceptedSteerIDs 在一次原子写中保存，成功后才发布内存变化。恢复/重试遇到已接受 ID 不重复入队，即使任务已推进或被取消也不复活。旧数组队列仍可解码，既有 M1 自检九的文件回读仅适配容器，不减少原断言。普通菜单排队仍直接走既有 enqueueTask(sessionID:text:) 和 queueReceipt。advanceQueue 的函数体与调用点不改。

中断请求与原 taskID、会话、固定目标 startingID 一并先写侧车；待插话转中断的项状态和待发文字在同一侧车提交，不存在源列表移除后文字无去向的窗口。UI 异步请求额外校验点击时原 taskID，防止误中断后来接替的任务。

MainActor 同步受理并预留启动权，保存旧 worker 句柄，调用原 stop()，等待 `oldWorker.value` 实际返回；`SteerInterruptGate` 要求原任务不变、generation 已换代、status 非 running、退出回执已到且本次尚未启动。旧 worker 的 done 门和终态 await 后增加代次校验，失效代次不再清现场或推进队列；自然终态先落定时则拒绝新的中断请求。

退出后先完成原插话作废投影，通过原 finishTask() 使旧任务不可续跑（调用原函数，不改函数体，也不调用 finishTaskFromUser）；然后同一 MainActor 回合启动固定 startingID 的新任务，不走 stopFromUser 或 advanceQueue。新目标快照写成功后，才清中断侧车并创建 worker；失败时文字仍在侧车，有显式重试/撤回入口。重启发现目标快照已在位，只恢复该目标，不重提中断请求。受理/停止/新 userTask 已写但目标快照未写等窗口仍保留请求；固定 startingID 防止重试制造第二份任务条目。

中断进行中停止/继续/开始按钮暂不可抢占，正在交接的会话暂不能删除；其他会话仍可按既有 canQueue 路径排队。失败后须重试或撤回待发文字再开始该会话的其他任务。撤回中断待发文字先保存原文凭证、回填草稿；不会恢复已结束的原任务。以上均为新增入口的仲裁绑定，未改 stop/stopFromUser/finishTask/advanceQueue 本身。

## UI 核对

- 运行中查看运行会话：发送点按插话；长按三项为插话、中断并发送、排队。中断项明示“结束当前任务（不可续跑）并立即开始这条”，不加二次确认。
- 确认/手输/提问等待时无三态菜单；新分支排在原 canQueue→续跑拦截→作答之后、新任务之前。手输恢复后遗留的 manual 描述不误判为仍在等待；不清改原等待字段。
- 输入栏上方逐条一行，撤回按空/非空草稿规则回填；改中断/排队复用引擎转移入口。冻结显示“已暂停，继续后生效”。失败的排队/中断有重试入口；待发文字与 M1 队列不混排。
- 作废反馈提供“重新发起（回填草稿）”，只填草稿、聚焦输入，不自动提交。

### 自检四十四：逐项断言

入口：`SelfTestView` → “自检四十四：三态发送 STEER” → `SteerTierA.verify()`＋`AgentEngine.verifySteerPersistence()`。后者只操作局部模型和临时目录，不启动模型或改现役任务。

| 规格项 | 逻辑层断言与静态核对 | 尚待 CI / 真机 |
| --- | --- | --- |
| ① 入列与一次性消费 | 顺序拼接、消费步号、清 pending、二次消费 nil | Swift 执行、真实 prompt 与模型后续行为 |
| ② 上限 3 条 | 接受结果 true/true/true/false，前三条不丢 | 满额点按反馈与草稿保留 |
| ③ 撤回草稿 | 原列表移除、空草稿直接填、非空加空格 | 输入焦点与跨会话草稿 |
| ④ 改排队/中断 | 源项移除且不能再消费；队列重复接受/已推进后重放拒绝 | M1 真正启动与取消、存储故障注入 |
| ⑤ 冻结/终态 | 冻结标签、解冻后消费；ended/done 作废；条数/ID/原文反馈；重复投影仅一条 local | 停止→继续、结束、failed、重启及文件保护实测 |
| ⑥ 目标/计数/问答不变 | 状态机编码边界无 goal/taskText/answerContext/StepBudget；源比对确认唯一计数点不动 | 引擎联动时预算和目标的实测回归 |
| ⑦ 等待态禁三态 | 运行/等待/异会话入口真值表 | 确认卡、提问作答、手输、已打开菜单后的状态变化 |
| ⑧ 阿仁新增同会话覆盖 | A 停止→同会话 B：A 侧车清、反馈含原文和原因、B 消费 nil；异会话状态不变 | 真队列、切会话、恢复 A 的实测 |
| 中断仲裁额外断言 | 无退出回执/错任务/未换代/仍 running 均拒绝，仅启动一次；受理/停止后保留请求，目标快照在位后不重提 | worker 实际退出和旧回调隔离、自然终态竞争、取消延迟 |
| 持久化额外断言 | 侧车真实临时文件往返；冻结/已生效往返不重放；旧条目/未知 kind、旧队列数组、旧快照缺新字段；新快照镜像往返 | Codable 编译与全部断言执行、进程强杀各事务窗口 |

## 本机实际验证与红线证据

执行命令：

```sh
python3 scripts/validate_project.py
python3 scripts/validate_steer_fold.py
git diff --check
```

`validate_project.py`：工程语法/引用、39 个 Swift 源文件恰好一次列入构建、资源、scheme、Info.plist、图标及许可证静态检查通过；它不进行 Swift 编译。

`validate_steer_fold.py`：以派工基线逐字核对并通过：

- advanceQueue、stop、stopFromUser、finishTask、finishTaskFromUser、confirm、submitAnswer 函数体不变。
- SafetyPolicy.swift、WebController.swift 文件不变；未触及 zhihu type4 路径。
- consumeDecision 唯一计数点与周围代码不变。
- SESSION-UX 滚动策略/自检不变，触发仍为 entries.count。
- 原 SelfTestView 按钮和测试方法未删改；新增四十三/四十四。既有 M1 引擎自检仅队列容器解码适配。
- 原 route、会话切换、步骤跟踪、append、flushBatch、persistNow、appendToFile、loadPersisted、fileContains、trimHistory 函数体不变。

`git diff --check` 通过。没有声称本机执行了任何 Swift verify 或既有 App 自检，也没有声称编译成功、真机通过或独立验收通过。

## CI / 真机接力清单

1. CI 编译整个 app，执行四十三/四十四的全部逐条断言；确认没有 SwiftUI 类型检查、Codable 或隔离编译错误。
2. 完整复跑既有自检，重点 SESSION-UX、自检九 M1、快照恢复、步数预算、确认/作答与 VERIFY-1；静态不删项不能代替动态零回退结论。
3. 按规格 Tier B 四场景验收：插话即时条目/下一步生效；长按排队与中断；实时组头/展开/终态；停止冻结/继续消费。
4. 补测同会话 A→B 作废、跨会话 A 保留后恢复；中断和 done/failed 同时到达；旧模型请求取消延迟、连点、交接期删会话、跨会话排队。
5. 对侧车提交、条目投影、转队列提交、旧 worker 退出、新目标快照提交/清中断请求的各边界强杀进程；核对原文去向、反馈唯一、无重复任务启动。注入写失败，确认保留侧车/待发文字、仅显式重试。
6. 真机核对键盘避让、长按菜单、待发条可读性、VoiceOver、滚动跟随与展开状态切会话清零。

完成实现与本机静态验证不等于验收；独立验收仍由阿仁完成，发布/出包仍由既定负责人执行。

## 提交阻塞（本轮实际结果）

实现及静态验证已完成，但指定的一次提交尚未生成。执行仅含本次十个交付文件的 `git add` 时，返回：

```text
fatal: Unable to create '/home/hatch/workspace/mika-ios-web/.git/worktrees/mika-steer-fold/index.lock': Read-only file system
```

当前 worktree 的 Git 元数据位于上述共享目录，当前文件系统不允许写入，无法暂存并提交。没有修改权限、主 checkout 或其他分支，也没有 push。需要环境提供该 worktree 所需 Git 元数据的写权限后，沿用现有工作区生成指定提交：`MIKA-STEER-FOLD：过程降噪+三态发送（自检四十三/四十四）`。本轮回执为 blocked，不能将未提交报告成 done。
