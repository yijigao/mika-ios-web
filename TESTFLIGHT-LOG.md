# Mika Web — TestFlight 分发链日志（2026-11-01）

结论：**构建已上 TestFlight，内部测试组可用（储备状态）。** App：Mika Web（Apple ID 6829467625，SKU mikaweb-001，Bundle ID com.jigaoyi.mikaweb，Bundle ID 资源 id L3BRLX57NY，团队 6566672L5G）。未提交审核、未接受任何协议、未动其他 App。

## 步骤与证据

1. **代码（方案 B，SPEC-B 基线）** ✅
   - 本机 Codex 按 SPEC-B 生成全套 SwiftUI 工程（13 个 Swift 源文件：WKWebView 桌面 UA 浏览器、页面状态抽取 JS、OpenAI 兼容模型客户端、Agent 循环与状态机、硬编码 SafetyPolicy（付款类关键词确认＋密码/验证码手动输入）、Keychain 设置、App Intent 预填任务、两个本地自检页 HTML），工程静态校验 `scripts/validate_project.py` 退出码 0（PASS 原文见 BUILD-NOTES.md）。图标全套占位图（深蓝渐变＋白 W＋绿点，含 iPad 152/167 与 1024 营销图）先行生成，未重演方案 C 的 90023 缺图标失败。

2. **仓库与密钥** ✅
   - 公开仓 `yijigao/mika-ios-web`（Apache-2.0，NOTICE 注明非官方衍生、参考 wangzan101/Mika）；私有仓 `yijigao/mikaweb-certs`。
   - 专用 deploy key 登记 id **168382013**（可写）；私钥与 match 密码存 `~/workspace/mika-ios-web/.secrets/`（0600），未入仓、未入日志（`.gitignore` 含 `.secrets/` 与 `*.log`，推送清单已核）。
   - GitHub Secrets 已注入 6 项（仅名字）：ASC_KEY_ID、ASC_ISSUER_ID、ASC_KEY_P8_B64、MATCH_PASSWORD、MATCH_DEPLOY_KEY、APNS_TEAM_ID。

3. **CI 编译** ✅
   - Run **41322207705**（push 触发），conclusion=**success**，xcodebuild 无签名模拟器编译一次通过。

4. **prepare（match）** ⚠️ 两败一成
   - Run 41322304366 **失败**：`Could not create another Distribution certificate`。ASC API 实查账号已有 3 张分发证书（B48Z8JJ458 为方案 C 的 match 所建，另两张更早），新建被上限拦下。
   - 处置：将方案 C 证书仓中的团队分发证书对（B48Z8JJ458.cer/.p12，match 加密态）原样种入 mikaweb-certs（提交 b1e3459），B 的 match 密码同步为同一值（仅存 .secrets 与 GitHub Secret，未打印）。同一团队证书跨 App 复用是常规做法；B 的描述文件仍为本 App 独立生成。
   - Run 41322438454 **仍失败**：同错误。查日志定位根因——match 默认 `git_branch=master`，种子在 `main` 分支，克隆到空分支后又试图新建证书。Matchfile 补 `git_branch("main")` 后 Run **41322532815** **success**：证书复用、描述文件 `AppStore_com.jigaoyi.mikaweb.mobileprovision` 已生成并存入证书仓（回读文件清单确认）。

5. **release（归档＋上传）** ✅
   - Run **41322679361**，conclusion=success，日志原文：`Successfully uploaded the new binary to App Store Connect`。

6. **ASC 构建与挂组（API 回读）** ✅
   - 构建号 **202611011544**（0.1.0），build id `f53fc10e-2959-4950-b1e7-6cf6d8efa0dc`，上传 2026-11-01 07:47:41 -08:00，processingState=**VALID**，expired=false。
   - 出口合规已补答：PATCH builds `usesNonExemptEncryption=false`（HTTP 200 回读 False）。
   - betaGroup「Internal」id `6a722377-d7f3-4c76-876f-4c35e193e0e4`，isInternalGroup=true；构建挂组 HTTP 204，组内 builds 回读为该 VALID 构建。
   - 测试员：账号持有人 Joey（573496046@qq.com）新建 betaTester 并带组关系成功（HTTP 201，tester id `a5f4a13a-f39b-43c3-b4a6-e9860b049fd4`，组内回读 state=INVITED）。

## 备注

- 构建号由 fastlane 按分钟生成（202611011544），上传回执时间略晚于构建号分钟，属正常。
- 真机两站成功率验证不在本轮范围（SPEC-B 定版），待 Joey 安装后另行实测；App 内自检页已备好，自检仍需在设置页填入自有 API Key 才可跑。
- 查询教训：`/v1/apps/{id}/builds` 不接受 `sort` 参数（400），首次轮询因此误判为空，已纠正。

## Joey 需要做的动作（装上备用，不急）

1. iPhone 打开 **TestFlight** → 应能看到 **Mika Web**（构建 0.1.0 / 202611011544）→ 点「安装」。
2. 首次使用：设置页选接口预置（OpenAI/DeepSeek/OpenRouter）并填自己的 API Key（只存本机 Keychain）；无 Key 时 agent 不会启动，属预期行为。

## 增补（2026-11-02）：真机首测问题修复，新构建已上

- 构建 **202611011652**（0.1.0）：CI Run 41328399800 success、Release Run 41328541913 success；ASC 回读 processingState=**VALID**、expired=false、出口合规已补答、已挂 Internal 组（组内回读确认）。提交 `3165943`。
- 内容：设置页引导式重做（服务商预设成对填充地址＋模型、人话说明、「保存并测试连接」带明确成败反馈、当前配置状态区）；闪退审计加固（抽取脚本无 body 守卫、Key 清洗防请求头异常、setter 守卫、步骤 id 单调化等）。真机闪退未能必现复现，结论分「已复现并修复／未复现但已加固」两类，详见 FIX-LOG-2026-11-02.md。
- Joey 在 TestFlight 更新到 202611011652 后按新设置页流程复测即可。

## 增补（2026-11-02）：v0.2 体验改造，新构建已上

- 构建 **202611011747**（0.1.0）：CI Run 41333114322 success、Release Run 41333235827 success；ASC 回读 processingState=**VALID**、expired=false、出口合规已补答、已挂 Internal 组（组内回读 [202611011747, 202611011652, 202611011544]）。代码提交 `d6b873d`（Astra 规划 PLAN-V02-ASTRA.md、Sol 实现、阿仁验收发版）。
- 内容：对话式主界面（聊天流＋过程条目＋助手结论）＋应用内悬浮面板（悬浮球/55% 面板、执行动作自动收起、位置记忆）；ask_user 对话内作答注入 prompt 续跑；waitingConfirm 对话内卡片；模型名防呆拦截＋常用模型 chips；MetricKit 崩溃诊断本地回收（最近 5 份，设置页可分享导出）；maxSteps 数字直显与初始化归一化。引擎循环语义与 SafetyPolicy 等七个安全相关文件零改动。详见 UX-LOG-2026-11-02.md。
- Joey 在 TestFlight 更新到 202611011747 后按 UX-LOG 的真机验收重点复测即可。

## 增补（2026-11-02）：v0.2.1 紧急修复（展开面板触摸网页必崩），新构建已上

- 构建 **202611011811**（0.1.0）：CI Run 41335174142 success、Release Run 41335309286 success；ASC 回读 processingState=**VALID**、expired=false、出口合规已补答、已挂 Internal 组（组内回读 [202611011811, 202611011747, 202611011652, 202611011544]）。代码提交 `aa3a3bb`（Astra 定界 PLAN-V021-ASTRA.md、Sol 实现、编排方验收发版）。
- 内容：悬浮层触摸架构重做——删除全屏 GeometryReader＋ZStack＋.position 覆盖层，面板/球改为 .overlay(alignment:) 受限挂载；删除聊天 ScrollView 的 simultaneousGesture 写状态、跟随滚动去动画；FloatingPanelStore 加同值保护。基线中「球体手势统一化」与「Store sink 全面异步化」两条经 Astra 定界推翻、按更保守裁决暂缓（理由见 FIX-LOG-V021-2026-11-02.md 分歧节）。根因机制未证实（无崩溃栈），结论分层级如实记录；SafetyPolicy 等安全文件与引擎语义零改动。
- Joey 在 TestFlight 更新到 202611011811 后按 FIX-LOG-V021 的复测清单验证（重点：展开面板触摸/滚动网页不崩）。

## 增补（2026-11-02）：v0.2.2 开关版（按栈定界后交付，非修复版）

- 构建 **202611011920**（0.1.0）：CI Run 41341136126 success、Release Run 41341240021 success；ASC 回读 processingState=**VALID**、expired=false、usesNonExemptEncryption 已 PATCH=false、已挂 Internal 组（组内回读 [202611011920, 202611011811, 202611011747, 202611011652, 202611011544]）。代码提交 `03daf50`（Astra 定界 PLAN-V022-ASTRA.md、Sol 实现、编排方验收发版）。
- 背景：Joey 发回 4 份 MetricKit 崩溃报告（证据 STACK-EVIDENCE-2026-11-02.md）——异常签名一致（NSInvalidArgumentException，-[__NSArrayM insertObject:atIndex:] 插入 nil），**1747 与 1811 已证同源**；异常由 UIKitCore 在触摸后的 SwiftUI UpdateCycle 内抛出，抛出路径无 App 业务帧。
- Astra 定界（effort high）结论 **NOT_LOCKED**：能锁定故障层级、锁不住单一触发构造，此时删 `.focused` 仍属盲修。按硬性分流纪律本轮改发 CRASH-HUNT §4 开关版：设置页新增「诊断开关」区（10 个 UserDefaults 开关、冷启动读取、全开＝1811 行为），供 Joey 按 FIX-LOG-V022-2026-11-02.md §5 的序列单因素定位（F_FOCUS → F_INPUT → F_SCROLL → F_CHAT → F_PANELSTATE → 其余）。
- 红线复核：安全与网页层文件全部零改动（git diff 实查）；validate_project.py 全 PASS。

## 增补（2026-11-02）：v0.2.3 结构修复版（浮层整体回退至 1652 流内骨架），新构建已上

- 构建 **202611012002**（0.1.0）：CI Run 41344557312（push）与 41344558364（dispatch）均 success、Release Run 41344759590 success；ASC 回读 processingState=**VALID**、expired=false、usesNonExemptEncryption 已 PATCH=false、已挂 Internal 组（组内回读 [202611012002, 202611011920, 202611011811, 202611011747, 202611011652, 202611011544]）。代码提交 `8ffed71`（CRASH-HUNT-2 定版规格、Sol 实现、编排方验收发版）。
- 背景：开关版定位终局——10 开关逐个单关全崩、10 个全关仍崩（Joey 真机 03:40–03:49，栈报告 5/6 佐证同签名），单因素矩阵整体证伪；CRASH-HUNT-2 审计收敛嫌疑至开关覆盖外的结构残件（S-A 浮层共存容器结构、S-B 根图常驻 FocusState），Astra 结论「只做一次完整的 UI 结构回退」。
- 内容：ContentView 回 1652 骨架（NavigationStack→VStack：BrowserView 流内分区＋Divider＋聊天区流内分区），删 GeometryReader 与全部 overlay；删根图 @FocusState 声明/onChange 写回/`.focused` 绑定，聊天输入改 1652 控制台同款无绑定 TextField；FloatingPanelStore 与悬浮球退出 UI（文件整体删除）；BrowserView 按钮回 1652 形态（与基线零 diff）；DebugSwitches 整体移除（残留 dbg.* 键无代码读取、零影响）。**数据层逐字保留**：AgentConversationStore＋binds、AgentEngine 全部增量、DiagnosticStore/MetricKit、模型名防呆、ask_user/确认卡片业务语义，仅聊天呈现位置由浮层改流内分区。红线文件全部零改动（git 实查），validate_project.py 全 PASS。详见 FIX-LOG-V023-2026-11-02.md。
- 结论口径：「回退该组 UI 结构变化后待真机验证」——根因机制未分离、未确认。Joey 在 TestFlight 更新到 202611012002 后按 FIX-LOG-V023 §6 做产品级复测（点网页 5 次＋滚动、跑任务、ask_user 作答、确认卡片、模型名防呆），不再做开关实验。

## 增补（2026-11-02）：基线确认构建（1652 逐字源码），新构建已上

- 构建 **202611020016**（0.1.0），build id `f9ab837d-fdd8-483f-aba6-ee731d91d192`：源码＝提交 `3165943` 逐字（分支 `baseline-1652-confirm` 直接指向该提交，diff 为空、tree hash 一致，零夹带）；CI Run 41366049681 success、Release Run 41366185979 success；ASC 回读 processingState=**VALID**、expired=false、usesNonExemptEncryption 已 PATCH=false、已挂 Internal 组（组内回读 [202611020016, 202611012002, 202611011920, 202611011811, 202611011747, 202611011652, 202611011544]）。构建号由 fastlane 现场生成、不落仓；版本串保持基线 0.1.0（改版本串会破坏零 diff，取舍理由见 BASELINE-CONFIRM-2026-11-02.md）。
- 背景：v0.2.3 结构修复版 202611012002 真机复测仍闪退（Joey 2026-11-02 08:12），UI 结构组整体回退不足以止崩。本版按 CRASH-HUNT-2 预写退路验证「1652 基线在当前设备仍不崩」这一前提：Joey 装 202611020016 后点网页 5 次＋滚动、口头报崩/不崩即可（此版无崩溃报告导出）。基线不崩→逐个回加 1652 后增量（DiagnosticStore＋MetricKit、conversation store＋binds、AgentEngine 增量、App 装配）；基线也崩→增量整体脱罪、转查设备/iOS/页面环境。两种结论均非根因确认。

## 增补（2026-11-02）：最小化阶梯 H0/H1/H2（1652 基线真机仍崩后），三构建已上

- 背景：基线确认构建 202611020016（1652 逐字源码）Joey 真机复测**一点网页即崩**（08:30）——v0.2 以来全部增量整体脱罪，且「1652 点网页不崩」的前提从未被验证（1652 当时只验设置页与跑任务）。病因在所有构建共有的地基里，改走最小化阶梯自下而上分离层级。案卷 CRASH-LADDER-2026-11-02.md。
- 代码：分支 `crash-ladder`（主线未动），新文件 Harness.swift + 分支专用 App 入口（仅装配 DiagnosticStore）；三构建间唯一源码差异为 Harness.step 常量（0/1/2，每阶 diff 经核验恰 1 行）。起始页三阶恒定＝WebController 的 loadHTMLString 本地页原文（脚本比对一致），WKWebView 配置与 UA 亦与原文一致；三阶均带 MetricKit 崩溃报告导出（右下角按钮）。
- **H0＝202611020036**（提交 a3cabd2；CI 41367853188、Release 41368007955 均 success）：单屏裸 WKWebView representable，无导航栈/工具栏/地址栏/任何 store（诊断除外）。ASC 回读 VALID、expired=false、合规已 PATCH=false、已挂 Internal 组。
- **H1＝202611020045**（提交 a638f2d；CI 41368716521、Release 41368837716 均 success）：H0 + 1652 形态 chrome（NavigationStack+toolbar+地址栏行，按钮/地址栏直连裸 WKWebView；观察/代理装配不在本阶）。ASC 同上 VALID 并挂组。
- **H2＝202611020054**（提交 2e9a33d；CI 41369501063、Release 41369619422 均 success）：换现行 BrowserView/WebSurface/WebController 地基原文 + 底部静态占位，无 conversation store 与 AgentEngine。ASC 同上 VALID 并挂组（组内共 10 构建，三阶梯居前三）。
- Joey 规程：按 H0→H1→H2 顺序装、起始页上点网页 5 次＋滚动，在第一个崩的构建停下并从右下角按钮导出最新崩溃报告发回。判读只定位到层（H0 崩→裸挂载/起始页/系统层；H1 崩→chrome 层；H2 崩→地基本体层；全稳→地基之上装配组合另开一轮），不写根因确认。

## 增补（2026-11-02）：生产版持有形态修复构建已上（待真机验收）

- 背景：第四轮阶梯判读落行——X-1（202611020431，生产对象图＋持有者形态）Joey 真机稳、X-2（202611020437，同内容＋App 直接 @StateObject 逐个持有形态）12:45 崩、崩溃报告在案（案卷 CRASH-LADDER-4、CRASH-X2-EVIDENCE）。定案触发条件＝「App struct 里直接以多个 @StateObject 逐个持有对象图」这一形态（机制未分离，不声称根因）。
- 修复：分支 `fix/app-holding-form`（自 main 新开，未合 main），提交 `4419fbd`，全仓仅 `MikaWeb/MikaWebApp.swift` 一文件（+33/−15）：生产 App 原 5 个 @StateObject（web/settings/engine/conversation/diagnostics）全部移入新增持有者 `AppObjectGraph`（@MainActor ObservableObject，App init 内同步构造、构造顺序与 bind/start 副作用与原 init 逐字等价），App 只以一个 @StateObject 持有该持有者，五件经原参数通道下传 ContentView。WebSurface/WebController/AgentEngine/UI/模型/Keychain/网络全部零改动；validate_project.py 全 PASS。修复记录 FIX-PROD-HOLDING-FORM-2026-11-02.md（含 @StateObject 枚举附注与 X-1 对应关系表）。
- **生产修复构建＝202611020450**（build id `791d0160-70cd-4b90-a77e-e902ba27ce9b`）：CI Run 41390473187 success → Release Run 41390586904 success（日志实查真上传）；ASC 回读 processingState=VALID、expired=false、usesNonExemptEncryption 已 PATCH=false、Internal 组挂载 POST 204 且组内回读居首。
- 待 Joey 真机验收：TestFlight 更新到 202611020450 后产品级复测（点网页多次＋滚动、跑低风险任务、作答续跑、确认卡片、模型名防呆）；验收通过前不合 main。

## 增补（2026-11-02）：悬浮窗改造构建（对话全屏＋浏览器悬浮小窗），新构建已上

- 构建 **202611020540**（0.1.0），build id `3175f80c-b228-4384-b8ea-67d059a64382`：分支 `feat/floating-browser-dock`（自 fix/app-holding-form 新开，未合 main、未合 fix 分支），代码提交 `619feaa`；CI Run 41395277316 success、Release Run 41395382176 success；ASC 回读 processingState=**VALID**、expired=false、usesNonExemptEncryption 已 PATCH=false、Internal 组挂载 POST 204 且组内回读居首；validate_project.py 全 PASS。
- 内容（Joey 13:27 亲令、13:33 批准；选型＝自研不引库，案卷 FLOATING-UI-IMPL-2026-11-02.md）：ContentView 改 ZStack——对话全屏常驻根层，浏览器坞盖其上双态（expanded 全屏／mini 约 0.44 等比缩放悬浮小窗，可拖动、松手按预测落点吸附左右边缘、停靠位跨启动记忆并钳制在输入栏之上）；保活靠「BrowserView 恒以展开尺寸布局＋scaleEffect 渲染缩放」，WKWebView frame 永不变化、不重排不重载；mini 态手势护盾拦截全部页面触摸（点按展开／拖动移动）；接 engine 既有信号自动展开（waitingConfirm＋确认卡片随坞底呈现、waitingManual 的 .manual 密码手输＋同口径「已处理，继续」）。
- 红线复核：MikaWebApp.swift 持有形态、WebController/WebSurface/AgentEngine 全部零改动（git diff 实查）；安全边界与确认／手输语义不变。
- 待 Joey 按案卷真机清单验收（重点：展开态点网页不崩回归、连续收放 30 次不重载、mini 态长任务持续运行、两类自动展开、键盘与位置记忆）；验收通过前不合 main。

## 增补（2026-11-02）：悬浮窗两缺陷修复构建（真 resize＋输入注入硬化），新构建已上

- 构建 **202611020602**（0.1.0），build id `65d0f392-91b7-4aab-9898-aa5b3d09baed`：分支 `feat/floating-browser-dock` 续提交 `736170e`（未合 main、未合 fix 分支）；CI Run 41397273588 success、Release Run 41397400728 success；ASC 回读 processingState=**VALID**、expired=false、usesNonExemptEncryption 已 PATCH=false 回读确认、Internal 组挂载 POST 204 且组内回读居首；validate_project.py 全 PASS。
- 背景：0540 真机验收（Joey 13:55）悬浮成功、无闪退，两缺陷：①内容不随窗口适配（旧实现只做渲染缩放、不重排）；②知乎答评论「找不到发表按钮」——13:55 截图＋Joey 判断定性为评论文字压根没真正打进编辑器（旧 contenteditable 写入用 textContent＋无 inputType 的普通事件，框架编辑器状态不更新），任务在展开态跑、与浮窗形态无关。
- 内容（案卷 FLOATING-UI-FIX2-2026-11-02.md）：①BrowserDockView 落定真 resize——动画期渲染缩放过渡、落定后布局尺寸切当前态真实尺寸让页面响应式重排，同 WKWebView 实例不重载/不重建、拖动不触发、滚动比例存恢复，小窗默认尺寸适度调大；②输入注入重写——contenteditable 主路径 execCommand insertText、备用 Range＋InputEvent，写后回读硬校验（文本＋发布按钮禁用状态），不过关换路径重试、再失败如实报「没输入进去」；click 加禁用判定与约 3.6 秒等待重扫，失败口径分「按钮是灰的／找不到／没输入进去」，失败留截图＋DOM 摘要到既有诊断通道；PageElement 新增 disabled。
- 红线复核：MikaWebApp.swift 持有形态、WebSurface/AgentEngine/SafetyPolicy 零改动；安全边界与确认/手输语义不变。
- 待 Joey 按案卷复测清单验收（知乎评论展开/小窗各测一次、适配重排与滚动位置）；验收通过前不合 main。
