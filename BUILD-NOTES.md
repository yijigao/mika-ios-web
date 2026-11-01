# Mika Web 构建记录

日期：2026-11-01。规格基线：已完整阅读 SPEC-B.md。此记录反映当前 Linux 工作目录的实现和静态验证，不声称完成 SPEC-B 的 CI、签名及 TestFlight 验收。

## 已实现

- 标准单 target Xcode 工程、共享 MikaWeb scheme、iOS 17+、Swift 5、iPhone/iPad、固定 Bundle ID/Team/0.1.0 版本设置。
- Info.plist：Mika Web 显示名，仅网页内容放宽 ATS，空启动屏，单场景，手机及平板常规方向支持。
- 桌面 UA、持久登录 WKWebView、地址栏、前进/后退/刷新、进度及加载错误。
- 页面状态 JSON、约 6000 字可见文本、交互元素编号和元数据；原生 setter 填表及 input/change 事件。
- 真实非流式模型请求、完整 JSON 对象提取、缺省字段容错、明确 HTTP/解析错误。
- Agent 状态机、任务与历史提示、5–50 步上限、随时停止和保留步骤、后台暂停、显式继续。
- 硬编码敏感动作确认、密码/验证码手动输入；模型返回后和用户确认后核对目标，执行 JS 再次核对目标与安全条件。
- Keychain 保存 API Key、UserDefaults 普通配置、三个接口地址快捷项及自定义 HTTPS 地址、无 Key 阻止启动。
- 任务控制台、状态和步骤列表；AppIntent/快捷指令预填任务，说明「任务在 App 前台内执行」。
- 两个随包本地 HTML、自检入口及真实模型任务启动逻辑；本地表单提交无需网络。
- 无第三方运行依赖。未修改 fastlane/、.github/、codemagic.yaml、LICENSE、NOTICE、资产目录及 PNG。

## 实际静态校验

在仓库根目录执行 `python3 scripts/validate_project.py`，退出码 0，输出原文：

```text
PASS: OpenStep syntax, object references, single app target, Debug/Release settings
PASS: 13 Swift sources referenced and compiled exactly once; asset catalog and 2 HTML resources
PASS: shared scheme, Info.plist, web-content-only ATS, single scene and orientations
PASS: LICENSE, NOTICE, 18 icon PNGs and Codemagic validator path
PASS: static project validation complete (no Swift compilation performed)
```

校验脚本仅使用 Python 标准库，解析 OpenStep 字典/数组，检查对象引用、target、配置、源文件/资源引用、scheme、plist、许可、图标槽位和 PNG 尺寸，以及 Codemagic 脚本路径。

另使用 Node 检查提取 JS 与替换 Swift 插值后的动作 JS 的语法；对本地表单 submit handler 使用最小 DOM stub 调用，确认 preventDefault 和包含所填姓名/邮箱的成功文案。运行结果：

```text
PASS: local form submit handler includes entered name and email without network
```

此 JS 检查未运行 WKWebView，不证明真实浏览器或真实模型端到端成功。

## 未做与不确定项

- 未本地编译 Swift：当前环境没有 Xcode、xcodebuild 或 Swift 编译器；Swift/UIKit/WebKit/AppIntents 编译兼容性仍需 macOS CI 验证。
- 未运行 GitHub Actions/Codemagic，尚无 CI 绿灯证据。
- 未在模拟器或真机执行真实模型自检；两项自检的端到端成功结果尚未验证，没有使用假模型代替验收。
- 真机两站成功率未验证，按规格留待安装后实测。
- 未执行 match 签名、归档、TestFlight 上传、processingState=VALID、内部组挂载或 ASC 回读；现有发布配置保持原样。
- 无 ChatGPT OAuth（规格明确不做）；无跨 App、后台或定时执行、多标签 Agent；未送审、未上架。
- DOM 关键词安全检查不是交易语义识别器；复杂 iframe、Shadow DOM、验证码和站点反自动化机制可能需要人工操作。模型服务兼容性、网络可用性和 React 站点交互效果仍需实测。
