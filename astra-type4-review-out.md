**结论：核心方向可接受，但不能判为修复验收 PASS。五项重点中，纯文本构造、已提交状态读取、复位标记和安全边界均通过源码复核；五跳观测口径基本诚实。自检仍有证据缺口，其中“保存重建”存在明确过度表述。**

已核对 `feat/zhihu-type4` 工作树、指定基线 diff、两份规格及 IMPL，并额外检查未跟踪的两个测试脚本。以下 PASS 均指源码审查，不代表 WKWebView 实测通过。

| 核查项 | 判定 | 证据与限制 |
|---|---|---|
| 纯文本粘贴两路均不带 HTML | **PASS／运行覆盖风险** | `DataTransfer` 仅在 `!plainOnly` 时写 HTML；兼容 store 的 plain 分支只有 `text/plain`，`types` 从键生成。虽然仍计算 HTML 字符串，但未装入载荷。顺序确为 `paste-plain → paste → events → chunks → exec → range`。[实现](/home/hatch/workspace/mika-ios-web/MikaWeb/WebController.swift:2003) |
| 五跳是否冒充已观测 | **PASS／观测不完整** | 生产 hop2 标记为 `clipboard-read`，没有称为框架处理器执行；hop3/4 保留 `unobserved`；hop5 为 `counter-observed`，没有称为已更新。fixture 才用处理器、`onChange`、提交生命周期提供明确证据。符合 IMPL 的限制声明，**尚不能定位知乎具体断点**。[埋点](/home/hatch/workspace/mika-ios-web/MikaWeb/WebController.swift:1960) |
| 全文断言读取已提交状态 | **PASS** | `assert` 读取 `instance.state.editorState`；`__stateText` 在 `componentDidMount/DidUpdate` 发布。`onChange(next)` 只记录候选生成，不提前发布断言状态。全文比较仅规范换行，保留空格、空行。[断言](/home/hatch/workspace/mika-ios-web/MikaWeb/Resources/test-draft.html:109) |
| 基线复位标记是否诚实 | **PASS／已声明风险** | 生产每次尝试记录 `baseline-reset=unavailable,independent=false`，没有新增 DOM 伪复位。自检独立策略通过 React 卸载、重建复位；生产仍可能沿污染 DOM 回退，不能当独立实验。[回退链](/home/hatch/workspace/mika-ios-web/MikaWeb/WebController.swift:2394) |
| 安全边界、TypeVerifyPolicy | **PASS** | diff 未修改密码／验证码／付款安全规则、`guardScript` 或 `TypeVerifyPolicy`；注入仍先执行 guard，生产结果仍进入原 verdict。浮窗／抽屉也未改。 |
| Simulator workflow 草案 | **PASS（交付范围）／运行未证** | 新 workflow 无自动触发规则，Debug Simulator 参数入口会运行自检并输出 JSON。满足“写草案、不触发”的要求；没有 Swift 编译或 WKWebView 通过证据。[workflow](/home/hatch/workspace/mika-ios-web/codemagic.yaml:28) |

需要修正或补证的具体问题：

1. **FAIL：把内存重建称作保存结果重建。**  
   `rebuild()` 直接读取当前 EditorState 的正文再 `reset()`；没有独立保存载荷及回读。`savestate` 也只是 setState 回调修改的提示文字。因此 `rebuild saved content` 最多证明“当前内存正文可重建”，未达到上一轮“从保存结果重建”的门槛。[实现](/home/hatch/workspace/mika-ios-web/MikaWeb/Resources/test-draft.html:116)、[断言标签](/home/hatch/workspace/mika-ios-web/MikaWeb/WebController.swift:2130)

2. **风险：忽略事件负例可能因错误原因通过。**  
   `performType` 的任何异常都令 `rejected=true`；定位失效、脚本异常也能配合 `updateCalls=0` 显示通过。应断言预期的状态拒绝原因，并确认实际走到了忽略处理器。[负例](/home/hatch/workspace/mika-ios-web/MikaWeb/WebController.swift:2144)

3. **风险：两条 clipboard 构造分支没有分别强制运行。**  
   当前 WK 自检只检查发送端 `types`，未强制覆盖兼容 store，也未断言接收端 `htmlPresent=false`。源码排除了 HTML，不等于两路运行证据齐备。另外，埋点将 `clipboardData` 替换为普通包装对象，存在影响依赖 DataTransfer 原型／其他方法的站点处理器的风险。

4. **风险：验收覆盖仍小于上一轮定界要求。**  
   未运行已实现的 `reject` 模式；缺少数据丢失、多编辑器／计数器绑定、真正长文及旧失败→新通过对照。正例直接调用 `runTypeScript`，仅忽略事件负例经过生产 `performType` 编排。自检全绿也不能推出生产链或知乎已修复。

本轮重跑 `git diff --check`、项目静态校验均通过，并执行核对了 fixture 的换行与计数函数；未编译 Swift、未触发 CI、未修改文件。IMPL 将交接结论写为 blocked、明确没有 WKWebView 证据，这一表述诚实。

**这份改动值得进 Codemagic 模拟器 workflow 取 WKWebView 证据，但只能作为诊断试跑，不能据此直接放行“知乎已修复”。**