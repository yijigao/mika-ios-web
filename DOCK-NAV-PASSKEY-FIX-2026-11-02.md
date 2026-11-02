# 小窗导航布局修复＋通行密钥降级（DOCK-NAV-PASSKEY-FIX，2026-11-02）

## 交付事实

- 构建 **202611021027**（0.1.0），build id `9ffb4bab-de19-470c-a5d8-922c10bb88ff`：分支 `fix/dock-nav-layout-passkey`（自 `feat/adoption-top3` 新开，未合 main／其他分支），代码提交 `8ad4c54`＋`a6c8d98`（SDK API 改名修正，见过程注记）。
- CI：首轮 Run 41428224490 的 job 结论为 success，但日志实查发现 `** BUILD FAILED **` 与一条真实编译错误（见过程注记）——**不认 job 结论、以日志为准**，修复后重跑 Run **41428566975** success，日志双核对：52 条 SwiftCompile（三个改动文件各有独立编译行、双架构）＋`** BUILD SUCCEEDED **` 1 处、BUILD FAILED 0 处（唯一 `error:` 字样是 appintentsnltrainingprocessor 的系统噪声，与源码无关）。
- Release Run **41428853763** success：agvtool 置构建号 202611021027（日志原文 `agvtool new-version -all 202611021027`），日志含 `Successfully uploaded the new binary to App Store Connect`。
- ASC 回读：processingState=**VALID**、expired=**false**、usesNonExemptEncryption 由 null PATCH→**false**（HTTP 200 回读确认）；Internal 组（6a722377-d7f3-4c76-876f-4c35e193e0e4）挂载 POST **204**，组内回读居首 [202611021027, 202611020942, 202611020838]。
- validate_project.py 全 PASS（22 个 Swift 源）。

背景：Joey 2026-11-02 18:16 真机测构建 202611020942（X 任务）报三结果——发推成功（主推＋回复均发布）；缺陷①小窗态发表跳转后页面布局崩坏；缺陷②X 登录选通行密钥时 iPhone 系统弹窗不出现（Joey 暂不继续测该路）。本单处理缺陷①（主项）与缺陷②（次项）。

## 主项：小窗态导航后布局崩坏——根因（代码实查）与修复

### 根因链（代码事实＋截图互证，与派工单怀疑方向一致并坐实到具体一行）

1. 坞里能把 `layoutScale` 缩到 dockSize 的路径只有一条：`BrowserDockView.scheduleSettle()` 落定时把布局尺寸切到 `settleTargetScale()`（dockSize 所有权＋mini 形态 → miniScale≈0.395，即约 155pt）。
2. settle 的触发源共四个：`expand()`、`collapse()`、`onChange(of: size)`（容器尺寸变化）、`onChange(of: engine.sessionActive)`（会话开始／终结）。**页面导航本身从不直接调 settle**（didFinish 只做 Cookie 同步，不碰坞）。
3. 实查 AgentEngine：`sessionActive` 只在 launch 置真、在任务 done／失败／stop 时置假，任务中途无闪烁。于是真机时序是：任务在小窗态运行期布局锁定工作尺寸（呈现正确）→ 发表动作引发页面跳转（此刻仍无 resize）→ 任务随即终结 → `sessionActive` 落下 → 布局所有权交还 `.dockSize` → 生命周期 settle 在约 480ms 后把视口**真 resize 到约 155pt** → X 页面按窄视口重排成逐字窄列（两张截图里完成态对话旁的小窗正是此形态）。AGENT-VIEWPORT-FIX 的迁移 #5（「会话终结后补落定 resize」）就是这条路径——它把 FIX2 的闲时适配行为错误地挂在了会话终结这一生命周期事件上，而不是只挂在用户收起手势上。

### 修复：settle 触发源门（BrowserDockView.swift）

- `scheduleSettle(userGesture:)` 显式标注触发源：`expand()`／`collapse()` 为 `true`（两者的调用点按 0808／16:01 定版只剩用户动作）；会话开始／终结与容器尺寸变化为 `false`。
- 落定闸门：目标缩放比小于当前 `layoutScale`（＝缩向 dockSize）且触发源非用户手势 → **放弃落定**，布局保持现状。生命周期 settle 只允许「长回工作尺寸」方向（目标 1）：会话开始时布局若停在小窗真实尺寸，仍一次长回工作尺寸（0645 视口锁定迁移 #1 不变）；会话终结时坞若是小窗态，布局保持工作尺寸＋缩放渲染，直到用户下一次显式收起手势才经 collapse 的用户通道落定到小窗真实尺寸。
- 由此：任何导航事件（整页／重定向／SPA 路由）——无论发生在任务中（所有权锁定、本就不 resize）还是紧贴任务终结（发表跳转＋随即 done 的组合，本次实证路径）——都不再可能把活动视口被动缩到 dockSize；容器尺寸变化（旋转等）的 settle 同受此门（旋转后小窗呈现走缩放渲染，下一次用户收放手势再落定真实尺寸）。

### 不回退核对（状态走查）

| 场景 | 修复后行为 | 对照口径 |
|---|---|---|
| 任务中（小窗）页面跳转／SPA 路由 | 所有权 workingSize，settle 目标恒 1、无 resize；跳转后仍是工作视口缩放渲染 | 0645 视口锁定 ✔ |
| 任务终结（小窗） | 所有权交还 dockSize，但生命周期 settle 被触发源门拦下：**不再**真 resize；小窗保持工作尺寸布局＋缩放渲染 | 本次修复点（旧迁移 #5 的落定部分就此废止，所有权交还本身保留） |
| 用户显式收起（闲时，expanded→mini） | collapse 的用户手势 settle 照常落定真 resize，页面按小窗宽度重排可读 | FIX2 缺陷 1 修复 ✔ 原样 |
| 用户显式收起（任务中） | 所有权 workingSize、目标 1、无 resize（与修复前一致） | 0645 迁移 #2 ✔ |
| 闲时小窗（已落定真实尺寸）发起任务 | 会话开始生命周期 settle 只许长大 → 一次长回工作尺寸 | 0645 迁移 #1 ✔ |
| 会话终结后用户点护盾展开→再点收起 | 展开无 resize（已在工作尺寸）；收起走用户通道落定小窗真实尺寸 | FIX2 ✔ |
| 拖动小窗 | 只改 offset、从不调 settle（原纪律不变） | ✔ |

## 次项：通行密钥（WebAuthn）——平台边界（查证结论）与降级落地

### 平台事实（以 Apple 官方文档口径为准、多源互证）

- WebKit 本身会自动处理 WKWebView 里的 WebAuthentication 请求，宿主 App 不需要写委托代码——但**能为任意 relying party（如 x.com）弹出系统通行密钥确认框的前提，是 App 持有受管 entitlement `com.apple.developer.web-browser.public-key-credential`**（Apple entitlement 文档原文：该 entitlement 让 App「make registration and assertion requests for passkeys and security keys for **any relying party identifier**」，且「Only add this entitlement if your app can act as a user's web browser」）。
- 没有该 entitlement 时，内嵌 WKWebView 只能使用 **App 自己关联域名**（webcredentials）的通行密钥；对第三方站点，`PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()` 返回 false、请求在不呈现任何 UI 的情况下被拒（NotAllowedError；系统侧日志口径为「Client is missing web browser entitlement」）。这与 Joey 在 iOS 27.2 真机上「X 登录页点通行密钥、系统弹窗不出现」的症状严丝合缝。Safari 与已获授权的浏览器（如 Chrome）走的正是这条 entitlement 通道；SFSafariViewController／ASWebAuthenticationSession 亦可，但那是跳出本 App 浏览器的另一条产品路径，不在本单范围。
- 该 entitlement 的获取门槛（Apple 文档步骤）：须由**组织** Apple Developer 账号的 **Account Holder** 提交申请表，Apple 按浏览器标准审核（Info.plist 声明 http／https、启动即提供 URL 输入／搜索／书签、直接导航不劫持等），批准后以 **managed capability** 形式下发到账号，再启用到 App ID 并由描述文件携带；仅在工程里私自声明该 entitlement 而无授权，签名／启动会被 AMFI 拒绝。Mika Web 当前账号为 Joey 个人账号、无此 capability，工程内亦未声明该 entitlement（实查：无 .entitlements 文件、无相关键）。

### 分流结论

- (a) 正规路径存在（向 Apple 申请上述 entitlement），但它卡在**账号层外部审批**：申请主体资格（组织账号 Account Holder）、审核周期、产品定位（须能作为用户的浏览器）都不在本轮构建可自证的范围，且获批前任何代码／签名改动都落不了地。故本轮按 (b) 落地，并把 (a) 的申请路径与门槛留作 Joey 后续决策项（若将来以组织账号＋浏览器定位申请获批，只需在签名侧加 entitlement，本轮探针的提示会自动只剩极少数真失败场景，届时可按需关掉）。
- (b) 优雅降级（本轮已落地）：
  - **检测**：每个标签页（含 window.open 新标签）的 WKWebView 配置在建页前装入文档起始探针脚本（WebController.swift BrowserTab）：只**观察** `navigator.credentials.get／create`——原样透传调用参数与返回的 Promise（返回同一 Promise、仅旁挂 then 观察）、不改页面语义、不读取／不拦截／不代填任何凭据材料；消息经弱代理 WKScriptMessageHandler 回传（防配置强持有造成标签页泄漏）。
  - **留痕**：每次尝试（resolved／rejected／throw，含 conditional 自动填充调用）以与失败快照同目录、同信封格式记入 DiagnosticStore（types「通行密钥尝试」，payload 只含事件、API、rp、host、conditional、错误名、URL 等元数据）。
  - **提示**：仅「模态调用被拒／同步抛错」（非 conditional）才经 NotificationCenter 通知 AgentConversationStore，在对话区追加一条 `.local` 人话提示：「<host> 刚才想用通行密钥（passkey）登录，但 iOS 不允许在 Mika Web 的内置浏览器里弹出通行密钥确认框——只有 Safari 和拿到 Apple 专门授权的浏览器能调它，这边弹不出来。请改用密码在这里登录一次（在 Safari 里登录不会同步到 Mika Web，两边状态是分开的）。」同一站点 120 秒内只提示一次（站点重试不刷屏；诊断记录不受节流影响）。任务运行中与手动浏览时都会出现（走同一对话条目通道，后台期随既有攒批机制回前台刷入）。

## 红线自查（git diff 对 feat/adoption-top3 实查）

- 变更文件仅 3 个：BrowserDockView.swift（settle 触发源门＋注释口径修正）、WebController.swift（WebAuthn 探针：脚本、安装、消息处理、诊断留痕、通知名）、AgentConversationStore.swift（订阅通知＋节流提示）。**MikaWebApp.swift 单持有者形态零改动；SafetyPolicy.swift 零改动**；AgentEngine.swift 零改动——0942 全部行为（后台驻停／自动续跑、防看门狗收敛、JS 异常分类重试、介入对话提示、键盘收起、输入栏最上层、Cookie 回注、循环熔断、Skill playbook）无回退；探针不触碰安全确认门（它只观察 credentials API，与元素级 SafetyPolicy 通道无关）。
- 无新第三方依赖；无凭据入日志（探针消息与诊断 payload 均不含任何凭据材料，rp／host／错误名除外）；GPL 无关（本轮未参考 OpenMinis／Palvia 代码）。

## 过程注记（如实）

- 首轮 CI（Run 41428224490）：job 结论 success 但日志里是 `** BUILD FAILED **`——该工作流的构建步不以 xcodebuild 失败为 job 失败，结论不可信；日志双核对抓到真实错误：`addScriptMessageHandler(_:contentWorld:name:)` 在当前 SDK 已改名 `add(_:contentWorld:name:)`，按改名修正（提交 `a6c8d98`）后重跑 CI（41428566975）真绿。此事再次印证「编译结论只认日志」口径。
- ASC 首次按猜测的构建号 202611021028 查询为空——回 Release 日志以 agvtool 原文锁定真号 **202611021027** 后回读完成（与 0838／0942 两轮的索引延迟注记同类教训：先以日志定号、再查 ASC）。

## 给 Joey 的真机复测清单（构建 202611021027；0942 的 11 项合并清单继续有效，本轮新增以下 4 项）

1. **小窗态发表跳转（主项核心）**：坞保持小窗，发一个会在 X 发帖的任务——发表跳转发生时、以及任务显示已完成之后，小窗里的页面都应保持整页等比缩小的形态（文字小但排版成行、头像与按钮位置正常），**不再**出现按约 155pt 重排的逐字窄列；随后在小窗里再让它做一次站内跳转（如点进一条推文再返回），布局形态应始终一致。
2. **用户收起的真适配仍在**：展开态手动浏览任意网页，点右下角收起按钮变回小窗——等约半秒，页面应按小窗宽度真重排（文字变大、窄版排版，FIX2 行为）；再点小窗展开，恢复全宽。再补一程：闲时小窗（已是窄版排版）直接发起一个任务，任务开始时页面应一次长回全尺寸布局（小窗里看到整页缩小图），任务办完后保持该形态、不自动变回窄版。
3. **通行密钥降级提示**：在 X 登录页点「用通行密钥登录」——预期系统弹窗仍不出现（平台边界，非本轮可解），但对话区应在约 1 秒内多出一条提示，说明这边弹不出通行密钥、请改用密码登录；2 分钟内再点一次不应重复刷第二条；设置页的诊断列表里应能看到一条「通行密钥尝试」记录。之后用密码应能正常登录（探针不干扰正常登录流程）。
4. **顺带回归**：任务中切后台两分钟回来自动续跑、循环熔断自检三、知乎 playbook 加载提示、Cookie 回注验证（0942 清单第 9–11 项）均不应有变化；小窗拖动、位置记忆与从前一致。
