# VERIFY-1 实施案卷：独立动作后核验合约（窄版试点，shadow 先行）

- 派工依据：VERIFY-1-SPEC-2026-11-03.md（Joey 2026-11-03 02:10 拍板立项；吸收评估汇总 ~/workspace/research_notes/tapilot-2026-11-03/SYNTHESIS.md 第 1+2 项）。
- 基线：feat/zhuanlan-fix2 tip `0ab1354`（构建 202611021908，阿仁已 ASC 亲验 VALID＋挂组）。新分支 `feat/verify-1`，未合 main。
- 功能提交：`46c5b4a`（交付证据回填提交另记，见第 7 节）。

## 1. 合约总览

一句话：**执行器只负责执行与落记（成果台账「已提交（待核查）」），落记之后由独立核验层用新鲜证据判定 verified / contradicted / unknown，判定只落盘与提示，不改流程。**

- 触发点：成果台账落记的同一时刻——`AgentEngine.noteSubmissionIfNeeded` 返回条目 id 后，`runPostSubmissionVerification` 随即运行（自主路径 runTargeted 与确认路径 runConfirmed 共用同一挂钩）。覆盖集合与台账完全一致＝`SubmissionClassifier` 的提交类动作集合（发布/发表/提交/投稿/发送/分享及英文 publish/submit/post/send/share 的 click）。普通浏览动作（滚动/展开/导航/打字）不触发；打字路径既有的编辑器状态硬校验不经本层、不回退。
- 顺序：动作执行 → 台账落记（outcome 步）→ 核验（verify 步）。步序由 pendingVerificationStep 暂存机制保证。
- shadow 边界：三值不写回台账 statusNote、不拦后续动作、不自动重提/重发任何动作；unknown 只在步流提示，contradicted 只标「与自报分歧」。执行器自报口径写死为对照面：`执行器自报：动作已执行、成果台账记为「已提交（待核查）」`；diverged ≡ (verdict == contradicted)。

## 2. 取证采样器（settled-capture 的 DOM 版）

`WebController.settledCapture(timeoutMs:)`（默认 5000ms）：

- 每 300ms 用探针抽一帧：与 PageState 同口径的可见正文（上限 6000 字）＋页面签名（readyState/正文长度/正文 djb2 哈希/节点数/文档高度）＋网络空闲判据（performance 资源计时最近 responseEnd）。
- settled 判据：签名连续 3 帧不变且最近网络响应已结束 600ms 以上。
- 有界超时：只记 settleOutcome=`timeout（证据未稳）`，不算成功、不抛错；探针失败帧跳过；切后台驻停即收口。
- 收口后调 `state()` 对当前执行页重新抽取完整快照（导航/页面代次变化后不用旧定位）；`state()` 失败时以最后一帧采样组装兜底快照。
- 采样帧全量保留进判定输入：toast 一类只活在采样帧里的短暂提示可被捕捉为弱证据。

## 3. 三值判定（ActionVerifier.judge，纯函数）

输入：动作前快照（模型所见快照/确认时重取快照）、settle 后快照、采样帧、是否 settled、提交内容前缀（台账条目的 contentPrefix）。优先级：

1. **contradicted**：动作后（或采样期间）新出现明确拒绝/失败文案（标记表：提交失败/发布失败/保存失败/发送失败/操作失败/被拒绝/未通过/不能为空/不可为空/请先填写/请先输入/敏感词/内容违规），证据引用带原文前后各 18 字片段。动作前页面已有同文案不算。
2. **verified（回读）**：提交内容前缀（规范化后前 12 字作针）在动作后正文的出现次数较动作前增加——内容已进入列表/详情等正文区，不再只躺在编辑器里。
3. **verified（跳转＋文案）**：URL 变化且新出现成功文案（标记表：发布成功/提交成功/保存成功/发送成功/更新成功/已发布/已提交/已保存/已发送/审核中/发布完成）。
4. **unknown**：其余一切。单独成功文案、单独跳转、采样帧 toast 均只记 weakEvidence（注明「只证明被接受，不证明已落定」）。
5. **证据未稳降格**：settle 超时时 verified 一律降 unknown 并在 evidence 注明；contradicted 不降（明确拒绝文案本身是 conclusive 的否定证据）。

本版**不调模型核验**：断言不 conclusive 即 unknown。理由（终审反例口径）：Tapilot 的 verifier 是同模型二次意见、有 verification theater 风险；我方试点先以确定性断言＋服务端回读立住，模型兜底待 shadow 数据证明 unknown 里确有大量「其实已成功」时再议。规格第 3 条「断言不 conclusive 时才可调模型核验」是许可而非义务，本单不行使，并在未证项中明示。

## 4. 记录落盘（台账旁记录）

- 文件：`Application Support/MikaWeb/verification-log.jsonl`，append-only，一行一条 JSON（sortedKeys）。`VerificationLogStore`（可注入路径，自检用临时实例）。
- 字段：id、recordedAt（ISO8601)、sessionID、outcomeRecordID（关联台账条目）、actionLabel（按钮文案）、pageURL、host、verdict、evidence[]、weakEvidence[]、settleOutcome（settled / timeout（证据未稳）)、executorClaim、diverged。
- 只存证据引用（文案片段/地址/计数），不存正文全文、不存凭据。无条数上限（试点期先全量留，保留策略待转正式门时一并定）。

## 5. shadow 分歧统计口径（后续真机累计法）

- 数据来源：只认正式日志 verification-log.jsonl（自检十三的合成记录写临时文件、不入此账，引擎侧已在自检结论行明示正式账条数）。
- 自动可算（VerificationLogStore.stats)：total、verified/contradicted/unknown 三值分布、diverged 数（恒等于 contradicted 数，两路互为校验，不一致即实现有 bug)。
- 人工复核标注（按周或每 20 条抽一次）：对每条记录回页面实况标注「实际结果（成功/失败/不明）」，据此算：
  - 假完成率＝执行器自报已提交中实际失败的占比；其中被 contradicted 命中的比例＝合约对假完成的捕获率；
  - unknown 误杀率＝unknown 中实际已成功的占比；
  - contradicted 精确率＝contradicted 中实际失败的占比；
  - verified 假阳性＝verified 中实际失败的条数（目标恒为 0)。
- 累计节律：随 Joey 真机复测与日常任务自然产生；自检十三 Tier B 的两场景各产生至少 1 条真实记录作为起点。

## 6. 转正式阻断门的建议门槛（只建议，不自行转门）

以下数字供阿仁按 shadow 数据裁决，本单不落任何阻断逻辑：

- 样本量：正式日志 ≥30 条真实记录（非自检合成）后才谈转门；
- unknown 误杀率 ≤5%（高于此值说明断言太弱，转门会误拦真成功）；
- contradicted 精确率 ≥80%（低于此值说明拒绝文案标记太毛躁）；
- verified 假阳性 = 0（出现 1 条即先修断言，不谈转门）；
- 转门范围建议仍只限 contradicted 一值（硬拦「已明确被拒还当成功」), unknown 转门（拦下待人工）另行评估，不与 contradicted 同批。

## 7. 交付证据

- 功能提交：`46c5b4a`（分支 feat/verify-1，基线 0ab1354，未合 main）；本案卷与 TestFlight 日志为其后的回填提交（见 git log）。
- CI：Run **41509603798** success；日志原文双核对：70 条 SwiftCompile（新文件 ActionVerification.swift 在编译列）、BUILD SUCCEEDED ×1、BUILD FAILED ×0；唯一 `error:` 为既有 AppIntents 训练噪声（appintentsnltrainingprocessor，历单一致，非编译错误）。
- Release：Run **41510817410** success；日志原文 `agvtool new-version -all 202611021932`、Successfully uploaded 在位；构建号 **202611021932**。
- dSYM：artifact `dsym-41510817410`，**4,554,759 字节**，expired=false（gh api 回读实存）。
- validate_project.py：全 PASS（31 Swift 源逐一引用且只编译一次、10 个 HTML 资源）。
- 本机预检：判定逻辑 JS 等价移植＋jsdom 驱动同一合成页冒烟，四场景 ALL PASS（甲 verified：内容出现次数 1→2；乙 unknown：成功文案无佐证仅记弱证据；丙 contradicted：拒绝文案带原文片段；丁 unknown：settled=false＋证据未稳）。
- ASC：待阿仁亲验（本单未代记 VALID、未挂组）。

## 8. 自检（自检十三）

- Tier A（程序化，本机构建后由 Joey 在 App 内点按，或后续真机第一条）：合成页 test-verify.html 四场景真实驱动「点击→settle 采样→判定」——甲 verified（回读）、乙 unknown（toast-only)、丙 contradicted+diverged、丁 unknown（settle 超时＋证据未稳）；引擎侧另核记录落盘往返（临时 JSONL 回读条数/判定/id 一致）与分歧统计（4=1+1+2、diverged=1)。
- 本机预检（无 Swift 工具链环境下）：validate_project.py 全 PASS（31 Swift 源、10 HTML 资源）；判定逻辑 JS 等价移植＋jsdom 驱动同一合成页冒烟四场景 ALL PASS（甲 verified 出现次数 1→2、乙 unknown、丙 contradicted、丁 settled=false→unknown）——JS 冒烟只证明断言设计与页面行为自洽，Swift 本体以 CI 编译＋真机 Tier A 为准。
- Tier B（真机人工，复测清单）：
  1. 知乎专栏原场景（与 ZHUANLAN-FIX2 复测同程）：102 字文章改约 1000 字→点「更新」→步流应出现「动作后核验（影子记录）」步；回正式日志查对应记录（actionLabel=更新类按钮、outcomeRecordID 与台账条目对得上），判定与页面实况（文章页正文已变长）对照记入复测结论；
  2. 公众号存草稿/发表场景（与 COVER-CONSENT 复测同程）：发表被平台以缺封面拦下时，核验应记 contradicted 或 unknown（不得 verified)，且 agent 不因核验记录自动重发；
  3. 常规回归抽查：自检六（台账软门）、自检十一、十二各跑一遍，步序「动作→台账→核验」不乱、软门口径不变。

## 9. 红线自查

- MikaWebApp.swift 对基线 diff 0 行（单持有者形态零改动）；SafetyPolicy.swift 对基线 diff 0 行（零改动）。
- 无新第三方依赖（仅 Foundation/WebKit 既有面）；新文件 ActionVerification.swift 只用 Foundation。
- 凭据不落盘：核验记录不含正文全文与任何凭据（只有 24 字内容前缀派生的 12 字针与文案片段）。
- 用户可见文案无「并行执行」。
- CI 日志双核对、dSYM 实存、ASC 待阿仁亲验：见第 7 节。

## 10. 未证项

1. 真机 Tier A（自检十三）未在设备上运行：本机无 Swift 工具链，Tier A 结论以 CI 编译通过为下限、真机点按为准。
2. 真实站点（知乎专栏/公众号）的核验判定质量未证：合成页断言成立≠真实页面文案形态全覆盖（知乎更新成功可能只弹 toast 且不跳转——按本合约将判 unknown，这是刻意的保守侧，不是 bug；shadow 数据会量化这类占比）。
3. settle 采样对执行时延的影响未测：每次提交类 click 后主循环多耗 ≤5s（settle 收口通常更快），长任务总时延变化待真机观察。
4. 模型核验兜底未实现（见第 3 节理由）；unknown 的人工复核标注流程未工具化（先手工按第 5 节口径抽样）。
5. 核验日志无保留上限：试点期全量留存，若长期运行体积增长需另定滚动策略。
