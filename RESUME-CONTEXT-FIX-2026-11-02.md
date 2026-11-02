# RESUME-CONTEXT-FIX（2026-11-02）：中断恢复只剩空壳——工作现场（页面＋上下文）全量恢复

## 报障

Joey 2026-11-02 19:36 真机（构建 202611021031）：任务（在某创作任务站找「发文就能领钱的任务」）执行中先后经历页面自动重试与 App 退出中断（即 19:30 那次 1031 崩溃），重开后出现「上次任务在 App 退出时中断，点继续可接着跑」；点继续／在输入框答「现在继续」后，agent 回复：「目前页面为空白，未显示之前的任务内容。请告诉我需要继续做什么，并提供相关网址或上一步的进度。」——浏览器停在 about:blank 起始页，agent 对原任务目标、已做步骤、所在站点一无所知，反过来向用户索要网址与进度。定性：**上下文记忆丢失**。

## 代码实查：四个断点（逐个坐实，非推测）

1. **快照没有页面现场**（主断点）：0838 的 `SessionSnapshot` 只存 goal／步骤／问答／playbook 名单，不存任何标签页地址；`restoreSnapshotIfNeeded` 的注释甚至明写「执行页绑定与页面状态不跨进程恢复：继续时重新绑定当前页」。冷启动后 WebController 只剩一个起始页标签，`resume()` 把执行绑定到起始页——agent 睁眼就是 about:blank，历史步骤的 reason 是纯文字、没有结构化网址可回。
2. **输入框打字把恢复会话冲掉**（截图里实际发生的那条）：`ChatInputBar.isNewTask` 把「.paused 且无待答问题」一律当新任务——恢复会话正是这个状态。Joey 在输入框打「现在继续」点发送，走的是 `engine.start()`：goal 被覆写为「现在继续」、步骤／问答／playbook 整体清零，快照随即被新会话覆写。模型拿到的就是 goal「现在继续」＋起始页，于是反问任务内容与网址。截图中「现在继续」之后紧跟的「用户已停止，可继续或重新开始」条目，正是 start() 开头 stop() 留下的痕迹，与此机制逐项吻合。
3. **续跑就绪检查漏了订阅来源**：`resume()` 与 `submitAnswer()` 只查 `settings.hasKey`（API Key），`start()` 才有按来源分支。ChatGPT 订阅来源的会话（Joey 当天正是切到 ChatGPT 在用）在没有 API Key 的设备上点「继续」会被误拦为「未配置 API Key」。本次真机上他另配有 Key 未触发，但路径不修则订阅用户必中。
4. **恢复现场会被后台落盘冲掉**（预防性堵漏）：恢复后若用户先切后台再回来，`setForeground(false)` 的 persistSnapshot 会按「起始页」现场重写快照，把中断时的原地址覆掉——恢复还没被消费，凭据先没了。

（附带坐实：快照此前不存 conversationTaskID，恢复时新生成一个，CRASH-1031 对话持久化的「同 taskID 去重」跨进程实际不成立——恢复会把任务条目与步流整段重播一遍，截图上方成串的旧步流即此。本次一并补存、沿用原 taskID。）

## 修复（分支 fix/resume-context，基线 fix/crash-1031 tip a95edbb）

变更 5 文件：AgentEngine.swift、WebController.swift、AgentChatView.swift、SelfTestView.swift、ContentView.swift（仅给 SelfTestView 多传 conversation）。MikaWebApp.swift、SafetyPolicy.swift 零改动；无新第三方依赖；validate_project.py 全 PASS（23 源）。

1. **快照补全工作现场（v2）**：`SessionSnapshot` 新增可选字段 `taskID`、`tabURLs`（全部标签页地址，起始页为空串）、`activeTabIndex`、`executionTabIndex`。v1 旧快照无此三键照常解码、恢复降级为「无页面记录」口径，不崩不丢会话。
2. **续跑先回到原页面**：恢复时标签现场先暂存（pendingTabScene）；第一次续跑（resume／问答作答／确认三条路径统一经 resume 或 launch 入口的 applyPendingTabRestore，只消费一次）时：现场仍全新（用户没动过浏览器）→ WebController.rebuildTabs 整组按原地址重建，当前页与执行页立即载入（file 页走 loadFileURL 同目录读权限、http(s) 走普通请求；其余标签只记地址、切到时才载入），执行绑定按原下标恢复；随后主循环第一轮 state() 等加载稳定后才抽状态。若用户重启后已手动浏览过，则**不覆盖**手动现场，改为把中断时地址写进续跑提示、由模型自行导航回去。
3. **续跑提示（resumeNote）**：恢复会话存续期间每轮 prompt 在「任务」后注入一段：原页面恢复结果（三种口径分别措辞）＋硬性规则——目标、网址、进度都在上下文里，**不得用 ask_user 向用户索要任务内容、网址或进度**；页面对不上或已失效时，先在说明里讲清记得的目标与已做到哪一步，再自行经站内导航／搜索／直接打开网址找回入口；只有需要用户做**新决策**时才许提问。会话 done／failed／新任务开始时清除。
4. **落盘防冲**：pendingTabScene 未被消费前，persistSnapshot 写暂存现场而不是起始页现场（断点 4）。
5. **输入框续跑拦截**：暂停／失败且目标在位、无待答问题时，输入框文本若是续跑短语（「继续」「现在继续」「接着跑」等精确集，或 ≤6 字且含「继续」），改走 resume() 并把用户原话以回答条目入对话；resume 未能启动（如设置问题）则留草稿并给人话反馈。其他文本仍按既有「新任务」语义，按钮文案不变。
6. **就绪检查统一**：抽出 `modelReadinessIssue()`（按来源分支），start／resume／submitAnswer 三处共用（断点 3）。
7. **自检四「中断恢复」**（SelfTestView 新增）：本地表单任务跑出 ≥2 步后，调引擎 `simulateInterruptionForResumeTest()` 做进程级中断模拟——先落盘，再把引擎内存态全清、标签打回单页起始页，然后只走冷启动恢复路径（与真机强退重开同一条路、同一份落盘数据）；模拟与恢复报告写入对话（条目独立落盘，即自检报告），随后由真人点「继续」续跑，编排继续守到 done／failed 再写结论条目（汇报内容＋是否出现反问的判读口径）。

## 不回退声明（逐项对照既有构建）

- 后台驻停／自动续跑、瞬时错误分类重试、JS 异常恢复（0838）：未触碰 checkpoint／瞬时分类逻辑；恢复流程仍走原 restore→paused→resume 骨架，只在其上补现场与提示。
- 确认门／手输等待：runConfirmed 的网址与目标复核一字未改；confirm 路径新增的现场重建只发生在复核之前，页面对不上仍安全失败、不误执行。
- Cookie 回注、循环熔断、playbook（0942）：快照的 skillNames 恢复逻辑未动，resumeNote 与 playbook 注入并列拼接、互不覆盖。
- 坞布局与 DockStateStore（1027／1114）：未触碰 BrowserDockView 与 DockStateStore；rebuildTabs 只换标签对象，不动坞状态。
- 对话持久化（1114）：entries.json 机制未动；taskID 沿用反而使既有去重按原设计跨进程生效。
- 通行密钥探针复用器（1114）：rebuildTabs 新建的 BrowserTab 仍经 WebAuthnProbeMultiplexer 装配（init 内），共享 controller 只装一次的约束不变。

## 交付凭据

- 构建 **202611021148**（0.1.0），build id `01e5e630-107f-46ec-baf1-94e335784ca5`：分支 `fix/resume-context`（基线＝fix/crash-1031 tip a95edbb，含 1114 全部内容，未合 main），功能提交 `fb1f652`（主体）＋`f111d3f`（launch 入口兜底重建）。
- CI：Run 41439025068（fb1f652）与 Run 41439378018（f111d3f）均作业 success，日志双核对一致——各 54 条 SwiftCompile＋BUILD SUCCEEDED 1 处、FAILED 0。
- Release：Run 41439681736 success，日志含 agvtool 置构建号 202611021148 与「Successfully uploaded the new binary to App Store Connect」；dSYM artifact `dsym-41439681736`（2,981,552 字节）实存、防复发链路在位。
- ASC 回读（本单自验，另待阿仁亲验）：processingState=**VALID**、expired=false、usesNonExemptEncryption=false（1114 起 Info.plist 已声明，本版天生合规、免手工 PATCH）；Internal 组挂载 POST **204**，组内回读居首 [202611021148, 202611021114, 202611021031]。

## 真机复测清单（按序）

1. **原报障路径**：真实任务中途强退 App → 重开 → 点「继续」：agent 应先回到原页面、带着原目标与已完成步骤续作，全程不反问「做什么／网址／进度」。
2. 恢复后在输入框打「现在继续」发送：应走续跑（不出现「用户已停止」后开新任务、更不出现反问任务内容）。
3. 恢复后切后台数分钟再回来点「继续」：原页面地址仍恢复得回来（落盘防冲）。
4. 多标签任务中断恢复：执行页与当前页回到各自原地址；未激活的标签切过去时才载入原页面。
5. ChatGPT 订阅来源（退出 API Key 或用无 Key 环境）恢复后点「继续」：不出现「未配置 API Key」误拦。
6. 等待确认状态下中断恢复：确认后应在原页面上复核执行；页面确实已变时安全失败、不误点。
7. 自检四跑一遍：对话里应出现中断模拟报告、恢复报告与最终结论；结论为完成表单提交汇报。
8. 顺带回归：1114 的知乎编辑器路径、设置往返坞不变、任务完成切后台对话在位、0942 的熔断自检三。
