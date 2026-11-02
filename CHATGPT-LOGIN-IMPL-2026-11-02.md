# ChatGPT 订阅登录（CHATGPT-LOGIN，2026-11-02）

## 交付事实

- 构建 **202611021031**（0.1.0），build id `65aca652-1ae0-476f-a2da-55415361525b`：分支 `feat/chatgpt-subscription-login`（基线＝`fix/dock-nav-layout-passkey` tip，含小窗导航布局＋通行密钥降级修复构建 202611021027 的全部代码；未合 main），功能提交 `06d8fd2`。
- CI Run **41428667629** success：日志实查 54 条 SwiftCompile（含 ChatGPTAuth.swift 独立编译行、双架构）＋`** BUILD SUCCEEDED **`，双核对通过。首轮 CI Run 41428435967 的日志双核对抓出基线里一处 SDK 改名编译错误（见「过程注记」），修复后重跑即本轮。
- Release Run **41429362442** success：日志含「Successfully uploaded the new binary to App Store Connect」，构建号 202611021031。首轮 Release Run 41428864985 归档成功但上传被 ASC 以 500/409 拒（构建号与同分钟落地的 202611021027 撞号，见「过程注记」），换号重跑成功。
- ASC 回读：processingState=**VALID**、expired=**false**、usesNonExemptEncryption 由 null PATCH→**false** 回读确认；Internal 组（6a722377-d7f3-4c76-876f-4c35e193e0e4）挂载 POST **204**，组内回读居首 [202611021031, 202611021027, 202611020942, 202611020838]。
- validate_project.py 全 PASS（23 个 Swift 源）。
- **交付标准说明**：登录授权只能 Joey 本人在真机完成，本案卷只证明「构建可用＋路径写清」，**不声称已验证登录成功**。订阅通道端到端（授权→换 token→后端调用）未经真机实测，风险点见「真机验收路径」与「未证实项」。

## 背景

Joey 2026-11-02 18:18 亲令：「下一步把模型接入从 OpenMinis 抄过来，让我把 GPT 订阅登录上。」即在既有 API Key 接入之外，扩出「ChatGPT 订阅登录」：用户用自己的 ChatGPT 订阅账号 OAuth 授权后，直接用订阅额度跑任务。SPEC-B 原「不做 ChatGPT OAuth」的押后口径就此解除。

## 研究节（先行只读拆解，OpenMinis 本地 clone：research_notes/adoption-study-20261102/openminis）

研究对象：`src/ios/Providers/OpenAI/OAuth/CodexOAuthManager.swift`、`OpenAIProvider.swift`、`OpenAIModelsAPI.swift`、`LLMTypes.swift`，及共享的回环回调服务实现。协议事实如下（只学协议与思路，代码全部自研，未复制任何 GPL 源码）：

### OAuth 全链路
- 授权端点 `https://auth.openai.com/oauth/authorize`；令牌端点 `https://auth.openai.com/oauth/token`（POST JSON）。
- **client_id＝`app_EMoamEEZ73f0CkXaXp7hrann`**。定性（重要）：这是 **OpenAI 官方 Codex CLI 的公开 OAuth 客户端标识**——公开客户端（public client），无 client_secret，靠 PKCE 防护；它不是 OpenMinis 的专属凭据，流程也**不经过 OpenMinis 或任何第三方的服务端中转**，设备直连 auth.openai.com。OpenMinis 本身、opencode 等业界第三方都是以同一公开 client 走同一流程，属于可独立复刻的公开协议面。任务书的停手条件（依赖 OpenMinis 自有中转／专属凭据）经核**不成立**，故继续实现；此定性如实记录在案。
- redirect_uri＝`http://localhost:1455/auth/callback`（回环）。授权参数：`response_type=code`、`scope=openid profile email offline_access`、PKCE `S256`、`state`，另带 Codex 流程参数 `id_token_add_organizations=true`、`codex_cli_simplified_flow=true`、`originator=codex_cli_rs`。
- 回调接收：本机回环 HTTP 监听（OpenMinis 用原始 socket 监听 127.0.0.1:1455）＋`SFSafariViewController` 呈现官方授权页，等回调上限 300 秒，校验 state 后换 token。
- **为何不用 ASWebAuthenticationSession**（与派工单字面要求的一处偏差，理由在此）：该 client 在授权服务器侧注册的 redirect 只有 http 回环地址，而 ASWebAuthenticationSession 的回调 URL 只支持自定义 scheme 与 universal link，**接不了 http://localhost 回调**——这是业界（含 OpenMinis）一致采用回环监听的原因。本实现改用 SFSafariViewController（系统 SafariServices）＋自研 POSIX 回环监听（只绑 127.0.0.1，回环不属「本地网络」隐私范围、不触发局域网权限弹窗、不对局域网开放），实质要求不变：官方页面授权、App 不接触账号密码、系统框架、无第三方依赖。
- 换 token 请求体：`{grant_type: authorization_code, client_id, code, redirect_uri, code_verifier}`（JSON）。响应含 access_token / refresh_token / id_token / expires_in。
- id_token（JWT，只解码载荷读声明）含 `chatgpt_account_id` 与 `chatgpt_plan_type`；邮箱取顶层 `email` claim（缺失时回退 `https://api.openai.com/profile` 内的 email）。
- 刷新：`{grant_type: refresh_token, client_id, refresh_token, scope}`；到期前 5 分钟触发；**refresh token 会轮换**，响应未带新 refresh token 时保留旧的；`invalid_grant`/`refresh_token_reused` 类错误＝授权已失效，须重新登录。
- token 存储：整体 JSON 存 Keychain。

### 登录后的后端调用（Codex 后端，Responses 形态）
- 端点：`POST https://chatgpt.com/backend-api/codex/responses`，SSE 流式。
- 请求头：`Authorization: Bearer <access_token>`、`Chatgpt-Account-Id: <chatgpt_account_id>`、`Openai-Beta: responses=experimental`、`Originator: codex_cli_rs`、`Version: <客户端兼容版本号，OpenMinis 钉 0.159.0>`、User-Agent `codex_cli_rs/<版本> (iOS; arm64)`。
- 请求体要点：`{model, stream: true, store: false, instructions: <系统提示>, input: [Responses 形态消息], reasoning: {effort: "low"}, include: ["reasoning.encrypted_content"]}`；与 chat/completions 的差异：系统提示走 `instructions`、消息走 `input`（`{role, content:[{type:"input_text", text}]}`）、响应是 SSE 事件流（`response.output_text.delta` 增量、`response.completed` 终局载荷）。
- 模型目录：`GET https://chatgpt.com/backend-api/codex/models?client_version=<版本>`（同套请求头），返回 `{models: [{slug, visibility, …}]}`，`visibility == "hide"` 的不展示。拿不到目录时的内置兜底名单来源为 OpenMinis 内置 Codex 模型表（gpt-5.2-codex、gpt-5.1-codex-max、gpt-5.1-codex、gpt-5-codex、gpt-5-codex-mini）。
- 模型命名与选择：以登录后账号目录实测为准；目录条目用 `slug`。

## 实现

### 新增 ChatGPTAuth.swift（自研）
- `ChatGPTTokenStorage`（Codable）＋专用 Keychain 条目（service `com.jigaoyi.mikaweb.chatgpt`，与 API Key 条目完全分开），`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`；token 值不进任何日志/诊断。
- `ChatGPTAuth`（@MainActor ObservableObject，由 SettingsStore 持有——在 AppObjectGraph 内部，不动 App struct）：登录态（isLoggedIn／账号邮箱／套餐）以 @Published 暴露给设置页。
- 登录：PKCE（CryptoKit SHA256）＋state → 自研 `LoopbackCallbackServer`（POSIX socket 只绑 127.0.0.1:1455，accept→解析请求行查询参数→回「登录处理中，可以回到 Mika Web」的简短页面；单次完成即关，300 秒超时）→ SFSafariViewController 打开授权 URL → 校验 state → 换 token → 存 Keychain。授权被拒（error 参数）/state 不一致/无 code 都给人话错误。
- 退出登录：删 Keychain 条目、回未登录态。
- `validAccessToken()`：到期前 5 分钟自动刷新（单飞：并发调用共用一个刷新 Task）；刷新成功保留服务端未轮换的字段；`invalid_grant` 类（HTTP 400/401）→ 清本地登录态＋抛「登录已失效，请重新登录」；网络/5xx → 抛「无法连接模型服务：…」沿用既有瞬时错误分类前缀，引擎会自动退避重试、不静默失败、不反复弹授权页。
- `discoverModels()`：按研究节协议拉账号目录，过滤 hide，返回 slug 列表；401/403 给「登录失效/无权限」人话口径。

### ModelClient.swift（扩展，差异收口在模型层）
- `nextViaChatGPT(auth:model:prompt:skillCatalog:)`：系统提示（含 playbook 清单拼法）与 `next()` 完全一致，输出仍是同一个 AgentAction 解码与动作白名单校验；AgentEngine 不感知通道差异。
- 传输：POST Codex 后端 responses 端点（请求头/体按研究节），`data(for:)` 收全量后解析 SSE：累积 `response.output_text.delta`，缺失时从 `response.completed` 的 output 取文本，`response.failed`/`error` 事件抛人话错误；HTTP 错误按状态码给订阅口径的人话说明（401 引导重新登录、404 引导刷新模型列表等）；URLError 沿用「无法连接模型服务」前缀。
- `testChatGPT(auth:model:)`：设置页测试用最小请求。

### SettingsStore.swift / SettingsView
- 新增 `ModelSource`（apiKey / chatGPT）：设置页第零步来源 Picker；「当前配置」区按来源显示（订阅时显示模型名＋登录状态）。
- 订阅区（来源＝ChatGPT 订阅时显示，API Key 的三段设置整体隐藏、数据不动）：未登录时显示说明＋「用 ChatGPT 登录」按钮（授权进行中禁用并显示等待文案）；已登录时显示账号邮箱、套餐、「退出登录」；模型名可编辑输入框＋候选快捷按钮（有账号目录缓存用缓存，否则用内置兜底名单并注明来源与「以账号实测为准」）；「刷新模型列表」（拉目录、写缓存、当前模型不在目录时切到目录首个）；「测试订阅连接」。
- 持久化：modelSource / chatGPTModel / chatGPTModels 均存 UserDefaults；token 只在 Keychain。

### AgentEngine.swift（仅两处分流）
- `start()` 守卫按来源分流：订阅来源要求已登录＋模型名非空（人话失败文案）；API Key 来源保持原 hasKey＋模型名校验，一字未改。
- 模型调用点按来源分发到 `nextViaChatGPT` 或原 `next`，其余循环逻辑（步数、瞬时重试、安全门、playbook、循环熔断）完全共用。

### 工程文件
- project.pbxproj 注册 ChatGPTAuth.swift（新 id 0047/0048，入组＋Sources 阶段）；Info.plist 无改动（回环监听走原始 socket，不需要本地网络权限声明；全部网络请求为 https）。

## 红线自查（git diff 对基线 f479b23 实查）

- 变更文件仅 5 个：ChatGPTAuth.swift（新）、ModelClient.swift、SettingsStore.swift、AgentEngine.swift、project.pbxproj。
- **MikaWebApp.swift（AppObjectGraph 单持有者形态）零改动**；ChatGPTAuth 由 SettingsStore 持有，不新增 App 层 @StateObject。
- **SafetyPolicy.swift 零改动**；安全确认门、密码/验证码手输、playbook 不覆盖安全规则等语义全部原样（订阅通道与 Key 通道共用同一 system 提示与同一引擎安全路径）。
- 0942＋1027 全部行为不回退：本分支基线即 fix/dock-nav-layout-passkey tip，diff 不含 BrowserDockView/WebController/BackgroundResilience 相关文件的任何回退性改动（WebController 与基线逐字一致——同一处 SDK 改名修复两线各自独立做出、内容相同）。
- 无新第三方依赖（OAuth 用 SafariServices＋Security＋CryptoKit＋POSIX socket，均为系统框架）。
- 凭据口径：token 只存 Keychain；不落盘明文、不进日志/DiagnosticStore/仓库；案卷与提交信息不含任何 token 值。client_id 为公开客户端标识（非秘密），按协议事实如实写入代码注释与本案卷。
- GPL 口径：OpenMinis 只读研究协议事实，未复制其源码（实现为自研：回环监听、PKCE、JWT 解析、SSE 解析均为按协议事实独立编写）；NOTICE 无需变更。

## 过程注记（如实）

1. **基线编译错误拦截**：首轮 CI（41428435967）作业结论为 success，但日志双核对发现 `** BUILD FAILED **`——唯一错误是基线修复分支 WebController.swift 的 WebAuthn 探针注册用了 iOS 26 SDK 已改名的旧 API 拼写。本线先以一字之差的同义修复提交，随后发现修复分支已独立做出**完全相同**的修复（其提交 a6c8d98，构建 202611021027 因此编译通过），rebase 后本线的重复修复提交自动消解，最终分支与基线在该文件逐字一致。
2. **首轮 Release 上传撞号**：Release Run 41428864985 归档成功，上传被 ASC 以 500（ContentDelivery internal）＋409（buildUpload 状态）拒绝。事后查明：构建号按分钟生成，本轮与修复线同分钟生成的都是 202611021027，修复线的同号构建已先行落地。等待数分钟后以新构建号 202611021031 重跑 Release（41429362442）上传成功。ASC 索引延迟与既往同型（上传后约 1–5 分钟可见），按构建号锁定回读完成。

## 未证实项（交付时点）

- 订阅 OAuth 端到端未经真机验证：授权页呈现、回环回调被 SFSafariViewController 正常加载、换 token、后端 responses 调用、模型目录拉取，均待 Joey 真机走一遍（见下）。
- 本地回环页在 SFSafariViewController 内的加载行为以 OpenMinis 同机制已上架运行为旁证，本机未自测。
- id_token 中 email claim 的确切位置以顶层 email 为主、profile 子对象为备；取不到时设置页只显示「已登录」，不影响调用（account id 取不到时请求头省略，Codex 后端是否接受无账号头未实测——目录与调用都以带账号头为设计主路径）。

## Joey 真机验收路径（构建 202611021031，TestFlight 更新后）

1. **切来源**：设置页顶部「第零步 · 选择模型来源」选「ChatGPT 订阅」；「当前配置」应显示来源＝ChatGPT 订阅、登录＝未登录。
2. **登录**：在「ChatGPT 订阅」区点「用 ChatGPT 登录」→ 弹出 OpenAI 官方授权页（auth.openai.com）→ **用你要用的订阅账号本人完成登录与授权**（注意：哪个账号授权就走哪个账号的订阅；yijigao@outlook.com 的 Plus 已定版不再续订，别误用它）→ 授权完成后页面显示「登录处理中，可以回到 Mika Web」→ 回到 App，设置页应显示已登录＋账号邮箱（＋套餐如 plus/pro）＋自动刷出的模型列表。
3. **验通道**：点「测试订阅连接」，应回「订阅连接成功：<模型名>（模型回复：ok）」。再去对话页发一条低风险任务（如打开知乎热榜并读出前三条标题），确认任务用订阅通道跑通；任务中途不应再要求 API Key。
4. **验并存**：切回「API Key」来源，原服务商/Key/模型配置应原样还在，任务可照旧跑；再切回订阅，登录态应保持已登录（不用重新授权）。
5. **退出**：订阅区点「退出登录」→ 当前配置回到未登录；再发任务应被明确拦下并提示先登录（不是静默失败）。
6. 顺带回归（本构建同时含 1027 的两项修复）：小窗态在 X 发表跳转后布局不再被压成窄列；X 登录点通行密钥时对话区出现人话提示（平台边界，改用密码登录）。
