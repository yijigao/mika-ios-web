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
