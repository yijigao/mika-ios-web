# Mika Web

基于 SPEC-B.md 的 iOS 网页 Agent 储备实现。SwiftUI + WKWebView，iOS 17+，无第三方运行依赖。App 名 Mika Web，Bundle ID `com.jigaoyi.mikaweb`，Team ID `6566672L5G`，版本 `0.1.0`。

在内置浏览器打开网页，在控制台输入任务并开始。模型每步根据页面可见文本与可交互元素，返回 click/type/scroll/navigate/wait/done/ask_user 动作；控制台展示步骤、理由和结果。浏览器使用桌面 UA 与默认持久化网站数据存储，支持地址输入、前进、后退、刷新及加载进度。

先到设置填写自己的 API Key、Base URL 和模型名。提供 OpenAI、DeepSeek、OpenRouter 地址快捷项，也可自定义 HTTPS 接口；更换服务时请同时填写该服务实际支持的模型名。最大步数默认 25，可调 5–50。未配置 Key 时会阻止启动，包含自检任务。

## 架构

- `MikaWebApp` / `ContentView`：生命周期、浏览器、控制台和导航；离开前台即暂停，返回后由用户继续。
- `WebController` / `BrowserView` / `PageState`：WKWebView 导航、JS 桥接、约 6000 字可见文本摘要、带 `data-mika-idx` 的元素列表。表单输入采用原生 value setter 并派发 input/change 事件。
- `ModelClient`：非流式 OpenAI 兼容 chat/completions；支持围栏内 JSON、首个完整对象和缺省字段。网络、HTTP、协议或动作解析失败会显式报错。
- `AgentEngine` / `SafetyPolicy`：循环、取消、步骤记录、硬编码安全门及用户确认。页面目标在模型响应后、用户确认后、JS 动作执行时重新校验。
- `SettingsStore` / `Keychain`：普通配置存 UserDefaults；Key 只存本机 Keychain，不打印或记录。SecureField 输入后保存会清空。
- `MikaWebIntents`：快捷指令「用 Mika Web 执行任务」打开 App 并预填任务，不自动开始；任务在 App 前台内执行。
- `SelfTestView`：两个随包本地 HTML，自检一查资讯日期，自检二填写张三及邮箱并提交。两项均走真实模型调用，不用模拟动作替代。

## 安全边界

click/type 目标的文本、placeholder、name、aria-label 命中付款、购买、下单、授权等硬编码中英文关键词时，必须由用户在弹窗选择「执行」或「跳过」。密码及疑似验证码字段的 type 动作被阻止，进入手动输入状态；用户在网页填写后点「继续」，引擎重新观察页面。任务文本和模型输出没有关闭这些规则的接口。

规则是基于 DOM 文本的保守检查，不保证识别所有图片按钮、伪装文案或网站脚本引起的交易；用户应持续核对网页和确认内容。停止会取消模型请求及后续步骤并保留记录，已经提交给网页的操作不能撤销。达到步数上限后暂停；点击开始可重置步骤开启新任务。

页面摘要、元素属性、任务及步骤历史会发送到用户配置的模型服务。提取器不读取表单 value，但网页本身显示的个人信息可能包含在摘要中。API Key 仅作为所配置接口的请求凭据。App 不支持 ChatGPT OAuth、原生 App 操作、后台/定时执行或多标签 Agent。iframe 内部及封闭 Shadow DOM 等复杂页面支持有限，登录或人机验证需要用户手动完成。

## 构建与自检

使用支持 iOS 17+ 的 Xcode 打开 `MikaWeb.xcodeproj`，选择共享 scheme `MikaWeb`。真机签名使用现有团队及合法签名资产。模拟器可免签名构建：

```sh
python3 scripts/validate_project.py
xcodebuild build -project MikaWeb.xcodeproj -scheme MikaWeb \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

启动后配置模型，打开「自检」选择一项，在主界面观察网页与控制台结果。自检只需要本地 HTML 与可访问的模型服务；模型调用需要网络、有效 Key 和额度。资讯预期日期是 2026 年 12 月 5 日；表单预期出现「提交成功：姓名 张三，邮箱 zhangsan@example.com」。

现有 fastlane、GitHub Actions 和 Codemagic 配置原样保留。签名、上传及 TestFlight 内部组的实际结果仍需在授权的 macOS/CI 环境验证；本次未执行上传或送审。静态校验不等同于 Swift 编译、真实模型自检成功或 TestFlight 验收，详见 BUILD-NOTES.md。

## 非官方衍生声明

本项目独立实现 iOS 网页子集，产品概念与交互参考 [wangzan101/Mika](https://github.com/wangzan101/Mika)，不是 Mika 官方发布，未获上游背书，未复制上游安卓代码。按 Apache-2.0 许可，见 LICENSE 与 NOTICE；SPEC-B.md 为唯一规格基线。
