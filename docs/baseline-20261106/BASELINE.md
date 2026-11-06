# MIKA trace 基线（2026-11-06）

## 代码与构建口径

- 封存时仓库 HEAD：`b8cdb8e75608357a09f6fed56d7e53ecfba5916d`（`MIKA-ROUND2-FIX: committed-miss vetoes count pass`）。
- Xcode 工程的版本口径：`MARKETING_VERSION=0.1.0`，`CURRENT_PROJECT_VERSION=1`；运行时 trace 另读 App bundle 的 `CFBundleVersion`，构建 SHA 优先读构建系统写入的 `MikaBuildSHA`，本基线未注入该键时回落为上述封存 HEAD。以上是仓库/构建配置口径，不冒充某台真机已安装包的实际版本。

## SettingsStore 默认值与通道口径

- 默认模型来源：API Key 通道（`modelSource=.apiKey`）。
- API Key 通道默认 Base URL：`https://api.openai.com/v1`；默认模型：`gpt-4o-mini`；chat/completions 请求不发送 reasoning effort（trace 记 `not-sent`）。
- ChatGPT 订阅通道默认模型：`gpt-5.2-codex`；当前请求体固定发送 `reasoning.effort=low`。
- 默认最大步数：25（设置允许 5–50）；任务运行时保持屏幕常亮默认开启。
- 上述全部是 `SettingsStore` 在没有持久设置时的源码默认值。UserDefaults、账号模型目录和用户选择均可覆盖它们，**默认值不等于真机实际值**；实际运行以每步 trace 中的通道、实际请求模型、请求 effort 与限制为准。API Key/登录令牌不进入 trace。

## 原失败长文案卷引用

- `/home/hatch/workspace/task-index/run-files/TIERB-0050-RESULT-2026-11-06.md`
- `/home/hatch/workspace/task-index/run-files/FORENSICS45-RESULT-2026-11-06.md`

这里只封存案卷引用，不复制或改写失败正文，也不把短文自检当成长文现场。

## 本单改动范围

本单仅增加最小逐步 trace 的本机 JSONL 落盘与 App 内导出入口、trace 完整性自检，并修正 `type` 写入账/状态卡的呈现语义：`type=replace`，旧版本与当前内容分开，attempt 与 `verified/failed/unknown` 分开。未改 prompt 文本、折叠策略、effort、输入策略链、`TypeVerifyPolicy`、`SafetyPolicy`，未增加 append 或文档事务；知乎人工粘贴交付不在本单范围内。
