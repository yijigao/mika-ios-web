# ZHIHU-COLUMN-SYNC 知乎专栏编辑器同步修复案卷（2026-11-02）

## 1. 缘起：Joey 真机实证（2026-11-02 21:34，构建 1300）

专栏文章《真正持久的改变，不靠狠劲，而靠一套低门槛的日常》（zhuanlan.zhihu.com/p/2100696940291821754/edit）此前发布的正文只有约 102 字、未达 1000 字要求。agent 行为全程正确（走成果台账口径编辑原文不重复新建、加载 zhihu-editor playbook、无法核实保存时拒绝点「更新」），已把约 1000 字打进编辑器、Joey 亲眼确认「能看到字了」；但编辑器「字数」始终停在 102、状态始终「草稿保存中」——文字只到了 DOM 层、没进编辑器内部状态，自动保存不落定，任务未完成。草稿备份面板有 21:30 备份与当前草稿，但预览只显末段、计数仍 102，无法据此核实全文已存。

基线：fix/outcome-ledger tip（9d3ba25，构建 202611021300）。分支：fix/zhihu-column-editor-sync。功能提交：90c85bd。

## 2. 根因口径

FIX2 的输入管线（execCommand insertText 主路径＋写后 DOM 回读校验）在知乎**回答**编辑器有效（Joey 15:03 在 0645 实测两个回答自动写成），但旧校验只认 DOM 文本在场。本次实证形态＝DOM 有字、编辑器自报字数冻结、保存状态不落定，说明写入没有进入专栏文章编辑器（zhuanlan，Draft.js 类）的内部状态事务：这类编辑器靠 beforeinput 事件的 data 驱动状态更新，整段原生插入在 WKWebView 里可能只改 DOM 不动状态；而 DOM 回读校验对此完全无感，曾误判成功（本次靠 playbook 口径与 agent 自查才没误点更新）。修复方向因此是两条：①给编辑器一条按其事件模型设计的输入路径；②校验升级为「编辑器状态校验」——DOM 在场不再算写成功，字数不动即判失败并自动换策略。

## 3. 改动（WebController.swift 为主）

1. **type 分发**：`performType` 先探基线信号——目标是 contenteditable 且探针找得到编辑器才走新流程 `performTypeInEditor`；其余（表单字段、探针落空）走 `performTypeLegacy`，旧流程逐字不变。
2. **策略阶梯 exec→events→chunks→range**：首策略严格 guard（expected 逐字段比对，与旧版同口径）；后续策略宽松 guard（只核 tag／editable 身份——编辑器文本已被前一策略改动，逐字段比对必然误判；敏感字段与安全词检查不放松）。逐策略读数写入失败快照 context 留痕。
3. **events 策略（新）**：按段落逐段派发 `beforeinput`（InputEvent，bubbles/composed/cancelable，带 inputType 与 data）——dispatchEvent 返回 false 即框架已 preventDefault 接管、**不再原生插入防双写**；未被接管才退回 execCommand insertText 补该段；段后再派 `input` 事件；段间走 insertParagraph 的事件序列；框架重渲染换掉编辑器节点时 rehost（按 data-mika-idx 或首个可见 contenteditable 重新锚定、caret 回末尾）；末尾派 selectionchange。**chunks 策略（新）**：按段 execCommand insertText＋逐段 input 事件，给框架逐段吃进状态的节奏。两条新路径都禁止 textContent 直写。
4. **编辑器自报信号探针**（`probeEditorSignals`）：定位编辑器（data-mika-idx 优先、退首个可见 contenteditable），在其祖先作用域内由近及远找短文案（≤40 字、排除编辑器自身内容）里的「字数：N」与保存状态；无果才扫全页。保存状态判读「保存中」优先于「已保存」（保存进行时旧标签可能同时在场）。
5. **字数一致性**（`countConsistent`）：全选替换口径下，落定字数应落在目标归一化长度 ±15%（+10/−5 余量）内；或较基线增长同量级也算吃进去。**计数与基线相同（冻结）必不过**——正是本次实证形态。
6. **保存落定处理**（`waitForEditorSaveSettle`）：计数已对上但状态为「保存中」时，先让编辑器失焦促一次同步，再 10×500ms 轮询至落定；仍不落定按 saveUnsettled 口径收尾。**计数对上但保存未落定时绝不返回成功**，更不会去点更新。无字数信号的编辑器只等一轮落定、结果记 trace、不单独判失败（保旧行为不回退）。
7. **失败按性质三分口径**（阶梯耗尽后按最后一次失败性质汇报）：domMissing＝「文字没能输入到编辑器：4 种写入方式都已尝试…」；stateRejected＝「文字已出现在编辑器里，但编辑器内部字数仍停在 N 字…这种状态下点更新只会提交旧内容」；saveUnsettled＝「文字已进入编辑器、字数已更新到 N 字，但保存状态一直停在『草稿保存中』未落定…已停手」。

## 4. playbook 与内置 playbook 投递（SkillStore.swift）

- zhihu-editor 补「专栏文章编辑器（zhuanlan.zhihu.com）」专节：与回答编辑器是两个东西、改已发布文章进原文编辑点「更新」；信号读法（字数＋保存状态为准绳）；**更新放行条件＝字数与目标量级一致＋保存落定，两者齐才许点更新**；草稿备份面板的坑（预览只显末段、核对篇幅以计数为准）。描述同步扩展到专栏发表／修改场景；「编辑器性质」段同步更新为状态校验与三分口径。
- **投递问题（本单发现并修复）**：`seedBuiltinsIfNeeded` 原逻辑对已落盘的内置 SKILL.md 永不覆盖——已装设备会永远用旧 playbook，本节更新到不了 Joey 的真机（此前各单只新增内置文件、未改过既有正文，本单是首例）。改为**哈希迁移**：落盘时记录每份内置文本的 FNV-1a 内容哈希（与 LoopDetector／OutcomeLedger 同算法）；启动时磁盘内容与记录一致（或无记录——旧版落盘的）视为未被用户改过，bundled 有更新即同步覆盖；哈希对不上视为用户改过、不动；用户自建／外部导入的 skill 不在此列。

## 5. 自检七（新页 test-editor.html＋SelfTestView 入口）

计数器驱动型模拟框架编辑器：内部状态是计数与保存的唯一准绳；beforeinput 仅当 DOM 与状态一致（未被外来改动）且 inputType/data 合规时才接管（preventDefault＋按选区应用＋重渲染＋置保存中）；250ms 周期重渲染冲掉外来 DOM 写入；保存 800ms 去抖后落定；「更新」按钮判据＝字数>0 且保存已落定。本地 jsdom 冒烟 15 项 **ALL PASS**：直写与旧 range 路径在该页上同样计数冻结并被冲掉（复现了实证的失败形态）、events 策略（等义移植）让字数涨到 49、保存由「草稿保存中」落定、更新回报「更新成功：正文共 49 字，保存已落定」、探针正则与页面文案契合。真机自检七任务：两段短文输入→汇报字数（约 49）与保存状态→点更新回报成功。

## 6. 交付证据

- validate_project.py：全 PASS（资源断言已含 test-editor.html，总数 6）。
- CI Run 41456406903 success：日志双核对 56 条 SwiftCompile＋`** BUILD SUCCEEDED **`（唯一 error 行是既有 AppIntents 训练噪声，非编译错误）。
- Release Run 41456600556 success：构建 **202611021351**，dSYM artifact dsym-41456600556（约 3.15MB）已存，上传成功。
- ASC 回读：1351 processingState=**VALID**、未过期；Internal 组挂载 POST 204；组内回读居首 [202611021351, 202611021300, 202611021218]。**取代 1300 成为唯一复测目标。**

## 7. 红线复核

MikaWebApp.swift 单持有者形态零改动；SafetyPolicy 关键词与确认门语义不变（宽松 guard 只放宽 expected 逐字段比对，敏感字段拦截与安全词检查两模式都在）；无新第三方依赖；凭据不进日志（探针只读字数与状态文案，不回传正文）；知乎回答与 X 既有行为不回退（回答编辑器走新流程时首策略仍是 exec 原路径，信号无果回落 DOM 口径）。

## 8. 复测清单（给 Joey）

1. **知乎专栏已发布文章改长文（本单主场景）**：打开那篇 102 字文章的编辑页，把正文改到约 1000 字——期望 type 成功、编辑器字数涨到目标量级、保存状态落定后再点「更新」成功，回文章页核对正文已变长。若步流出现换策略重试属预期自动升级；最终仍失败时，报错应明确区分「字数没动」还是「保存未落定」。
2. **自检七**：计数器驱动编辑器——字数约 49、保存落定、更新成功。
3. **playbook 迁移**：更新到 1351 后让 agent 在知乎专栏任务里加载 zhihu-editor，应能引用专栏专节的更新放行条件（字数＋保存落定）。
4. **回归**：知乎写回答一篇（输入与发布判据不回退）；自检既有项抽查（一／四／六）不回退。

## 9. 未证项

events 策略的 beforeinput 接管语义在真 zhuanlan（Draft.js）上是否被接管，未在真机证实——复测第 1 条即验证点。若真机仍不接管，chunks／range 兜底＋状态校验保证不再误报成功，失败会按 stateRejected 口径如实汇报，届时按真机步流 trace 再迭代。探针的文案形态假设（「字数：N」「保存中／已保存」类）以真机实际文案为准，无信号时回落 DOM 口径。
