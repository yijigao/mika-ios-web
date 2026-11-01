# Mika 方案 B（iOS 子集版）规格 —— 储备构建

立项：Joey 2026-11-01 23:25 亲令「把第二个 B 开发出来备着」（覆盖评估终审的 B 押后触发条件；本构建为储备，不送审、不推广）。
定位：不需要安卓执行端的 iOS 原生子集——App 内浏览器 web agent：用户在 iPhone 上用一句话给网页任务，agent 在 App 内置浏览器里自己浏览、点击、填表并回报结果。只处理网页，不碰其他 App（iOS 机制边界，评估报告定版）。

## 产品形态

- 名称（暂定）：Mika Web；Bundle ID：com.jigaoyi.mikaweb；SKU：mikaweb-001。
- 仓库：yijigao/mika-ios-web（公开，Apache-2.0，NOTICE 注明为非官方衍生实现、灵感与协议参考 wangzan101/Mika；代码为自有实现）。
- 技术：SwiftUI + WKWebView（桌面 UA），iOS 17+。

## 核心功能（本次构建范围）

1. **浏览器**：WKWebView 全屏浏览，地址栏、前进/后退/刷新；保持网站登录（默认数据存储）。
2. **Agent 循环**：
   - 用户输入一句话任务 → 循环：注入 JS 抽取页面状态（可见文本摘要＋可交互元素清单：序号、类型、文本/占位符、链接）→ 连同任务与历史步骤发给模型 → 模型回一个动作 → App 执行 → 直到 done/ask/步数上限。
   - 动作集：click(index)、type(index, text)、scroll(down/up)、navigate(url)、wait(seconds)、done(summary)、ask_user(question)。
   - 步数上限默认 25，可停（取消按钮随时中断并保留已执行步骤记录）。
   - 进度 UI：当前步数、模型给出的动作与理由、页面实时画面（WebView 本身可见），用户全程看得见 agent 在干什么。
3. **模型接入**：设置页配置 OpenAI 兼容接口（Base URL、模型名、API Key）；Key 只存 Keychain，绝不进日志/仓库/截图。预置位：OpenAI、DeepSeek、OpenRouter 三个 Base URL 快捷项（Key 仍由用户自填）。无 Key 时给出明确提示，不假跑。
4. **安全边界（硬编码，不可被任务文本绕过）**：
   - 目标元素文本命中付款/支付/购买/下单/确认订单/同意授权等关键词时，执行前必须弹窗由用户本人在屏幕上确认，否则不执行。
   - 密码框、验证码框：agent 不填，暂停并提示用户手动输入后点「继续」。
   - 不做任何后台执行：App 切后台任务即暂停（iOS 事实，如实呈现，不宣称后台运行）。
5. **Shortcuts 入口**：App Intent「用 Mika Web 执行任务」，参数为任务文本；从快捷指令/Siri 触发后打开 App 并预填任务（执行仍需在 App 前台进行，意图说明中如实写明）。
6. **本地自检页**：内置两个本地测试页与一键自检——①在本地资讯页中找出指定信息并 done 汇报；②在本地表单页填写姓名/邮箱并提交、汇报结果页文本。自检不需要外网与 Key 之外的配置（仍走真实模型调用），用于证明 agent 循环端到端可用。

## 不做（本轮）

- 不做 ChatGPT OAuth 登录（模型层只做 API Key；OAuth 口径未证实，留待后续）。
- 不做原生 App 操作、不做后台/定时任务、不做多 tab 并行 agent。
- 不送审、不上架、不做商店页素材；只进 TestFlight 内部组备着。

## 验收（备着状态的定义）

1. GitHub Actions macOS 编译通过（CI 绿）。
2. 签名与 TestFlight 链打通（照 Mika Console 的 match＋certs 仓模式复制），构建 processingState=VALID 并挂内部测试组，阿仁 ASC API 回读核对。
3. BUILD-NOTES 如实记录：已实现/未实现、模拟器或 CI 层面的自检结果；真机两站成功率验证不在本轮（待 Joey 装好后另行实测，属原评估的 B 触发验证，状态在收口报告中标注为未做）。
