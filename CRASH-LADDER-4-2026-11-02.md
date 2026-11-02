# Mika Web 触摸网页闪退最小化阶梯·第四轮 — CRASH-LADDER-4

- 日期：2026-11-02（设计＋构建交付，待主聊转交 Joey 按阶真机测）
- 触发：第三轮单件阶（A-1＝202611020259、A-2＝202611020307、A-3＝202611020316）经 Joey 2026-11-02 12:28 真机实测**全稳**（起始页点网页＋滚动不崩，案卷 CRASH-LADDER-3）。判读：**A 组单件全脱罪 ⇒ 疑为件间交互**。本轮按第三轮判读预写的退路出交互验证阶。
- 交互候选的收敛逻辑：H3a（202611020217）与第三轮各阶的装配差别中，与「多件共存」直接相关者有二：
  1. **engine 与共享 controller 的接线**：生产/H3a 里 AgentEngine 以 `AgentEngine(web:settings:)` 传入**视图正在消费的同一个 WebController 实例**构造；而第三轮唯一涉及 engine 的 A-3 阶，engine 的 web 参数是**独立替身实例**（不入持有者 web 槽、不下传视图、仅由 engine 私有 strong 引用保活，案卷 CRASH-LADDER-3 §1 登记）。即「engine 盯着活的那台 controller」这一形态在前三轮从未以可崩形态单独出现过——H3a 崩、A-3 稳之间的关键未验差别正在于此。
  2. **持有形态本身**：H3a 为 App 直接以三个 @StateObject 分别持有 web/settings/engine（第二轮提交 `0905d58` 的 MikaWebApp.swift 原样）；第三轮改走 HarnessObjectGraph 持有者间接层（缘由：Optional @StateObject 在 Release 编译下报错，案卷 CRASH-LADDER-3 实现注记）。创建时机（App init 内）与生命周期（App 级）两形态等价，差别仅在存储一层间接——但该差别从未被单独验证过。
- 本轮两阶即按此二候选设计：X-1 先在持有者形态下复刻生产对象图（候选 1 在场、候选 2 缺席）；X-2 与 X-1 内容逐字相同、仅把持有形态换回 H3a 原样（候选 1＋2 同时在场）。两阶均为全对象图在场、根视图保持 H2 形态（去 B 组布局——B 组已于第二轮拆半脱罪，本轮不带回）。
- 基线与恒定项：两阶均以 H2 为形态 base（根视图 HarnessH3aView：BrowserView 消费下传 web＋Divider＋120pt 静态占位、无控制台底栏）；起始页、WebSurface/WebController/BrowserView 本体、DiagnosticStore＋MetricKit 导出包装（右下角圆钮）两阶恒定，未改；AgentEngine 只创建、不执行、不发网络（其 init 仅存引用，无副作用，第二轮已源码实查）。
- 代码：分支 `crash-ladder-2`（续第三轮；main 生产分支未动）。

## 1. 两阶构建定义

### 阶 X-1（step=10，角标「X-1」）：生产对象图复刻（持有者形态）

- App 入口与第三轮逐字相同：`MikaWebApp` 以 @StateObject 持有 HarnessObjectGraph（App init 内同步构造）＋DiagnosticStore；本阶的装配差异只在持有者的分阶构造表新增 step=10 一行：`let w = WebController(); let s = SettingsStore(); web = w; settings = s; engine = AgentEngine(web: w, settings: s)`——engine 与根视图消费的是**同一个** w 实例（生产/H3a 形态）。
- 根视图 HarnessH3aView 只消费 web；settings/engine 存在于对象图但不被任何视图观察（与 H3a 的根视图消费形态一致：H3a 根视图同为 H2 形态、只消费 web）。
- 与 A-3 的语义 diff：engine 的 web 由「独立替身实例」变为「视图在用的同一实例」，且 web/settings 改为 App 级持有并下传（A1/A4 在场）；与 H3a 的语义 diff：仅持有形态（持有者间接层）一处，及根视图以上无差别（H3a 根视图同为 HarnessH3aView）。

### 阶 X-2（step=11，角标「X-2」）：X-1 内容＋H3a 持有形态

- 与 X-1 的唯一差异：持有形态。`MikaWebApp.swift` 替换为第二轮 H3a 的直接持有版（提交 `0905d58` 文件形态）：App 直接声明 `@StateObject private var web/settings/engine/diagnostics`，init 内依次构造 web→settings→engine（engine 仍以同一个 web 实例构造）并以 `StateObject(wrappedValue:)` 赋值；body 把三件以非 Optional 普通值传入 HarnessRootView。不存在 HarnessObjectGraph 实例（该类在本阶二进制内不被实例化）。
- Harness.swift 内两阶差异仅 `Harness.step` 10→11 一行（step=11 时根视图走同一 HarnessH3aView 分支；持有者的构造表不会被以 11 调用）。**两阶的整体源码 diff＝step 一行＋MikaWebApp.swift 的持有形态**，此外无任何文件差异（交付时以 git diff 实查登记，见 §3）。
- 与 H3a 的装配等价性：对象图内容、构造顺序、构造时机（App init）、根视图形态、诊断包装均与 H3a（202611020217）一致——X-2 即 H3a 的复刻锚点，预期结果为崩；若 X-2 不崩，则 H3a 与本轮之间必有未登记差别，须先逐项列 diff 再谈（§2 末行）。

## 2. 判读预写（只定位到区，不写根因确认）

| 结果 | 定位 | 下一步 |
|---|---|---|
| X-1 崩 | 触发区＝**engine 与共享 controller 的接线**（持有形态无关：持有者形态下已复现） | 下一轮拆 engine init 内部：其对 web 的订阅/观察装配逐项回退（如 init 内 sink/KVO/代理赋值分件） |
| X-1 稳、X-2 崩 | 触发条件＝**持有形态本身**（App 直接 @StateObject 逐个持有） | 查直接持有与持有者在对象身份/观察注册上的实际差异（如 @StateObject 对 ObservableObject 的 objectWillChange 订阅路径），在该层内细分 |
| 两台全稳 | 与 H3a 预期矛盾（X-2 应为 H3a 复刻锚点）⇒ 先查**包装等价性**：逐项列 H3a（202611020217 对应提交）与 X-2 的全部残余差别（App 入口外的一切：如同批入仓的视图代码版本、导出包装版本、构建环境）再定下一轮 | 逐项 diff 清单先行，不盲出新阶 |
| 任一阶崩法/签名与既往不一致 | 先停，核对该阶崩溃报告再谈定位 | — |

- Joey 测试规程（主聊转交）：按 X-1 → X-2 顺序装；每阶打开 App 停留在起始页（不要先输网址跳转），点上方网页 5 次＋滚动；首崩即停，重开 App 点右下角圆钮导出最新崩溃报告发回。右下角角标分别为 X-1 / X-2，与构建号可互核。

## 3. 构建与 ASC 回读证据

分支 `crash-ladder-2`（续第三轮；main 未动）；validate_project.py 两阶均全 PASS。以下两阶均经 ASC API 逐台回读：processingState=**VALID**、expired=false、usesNonExemptEncryption 已 PATCH=false（组内回读确认）、Internal 组（6a722377-d7f3-4c76-876f-4c35e193e0e4）挂载 POST 204 且组内回读居首。

### 阶 X-1（step=10）— 构建 202611020431

- 代码提交：`abaf077`（Harness.swift：step 9→10、角标 X-1/X-2、持有者构造表 step=10 全图＋共享实例、根视图 step 10/11 接 HarnessH3aView 分支；MikaWebApp.swift 未动；本案卷初版同批入仓）。
- CI Run **41388910697** success → Release Run **41388922547** success。
- build id `2ebb3f22-1f95-4e7e-95fc-c93b06c5dc05`；ASC 回读 VALID、expired=false、合规 PATCH=false 后组内回读确认；Internal 组挂载 204，组内回读居首。

### 阶 X-2（step=11）— 构建 202611020437

- 代码提交：`b170254`。**两阶 git diff 实查（abaf077..b170254）恰为两处**：Harness.swift 的 `Harness.step` 10→11 一行；MikaWebApp.swift 的持有形态（持有者 @StateObject graph → App 直接三件 @StateObject，含文件头注释）。对象图内容、构造顺序（web→settings→engine）、构造时机（App init）、engine 的共享实例接线、diagnostics 处理（init 构造＋start()）两阶逐字等价，无其他文件差异。
- CI Run **41389435339** success → Release Run **41389446381** success。
- build id `7cc5bc2a-2ef8-45ce-bedf-1866ba578436`；ASC 回读 VALID、expired=false、合规 PATCH=false 后组内回读确认；Internal 组挂载 204，组内回读为 [202611020437, 202611020431, 202611020316, 202611020307]，X-2 居首。

- 构建号由 fastlane 现场生成（UTC 时间戳 %Y%m%d%H%M），不落仓；两阶构建号分别为 202611020431 / 202611020437。

待主聊转交 Joey：按 §2 规程按 X-1 → X-2 顺序装（TestFlight 内按构建号选装：X-1 为 202611020431、X-2 为 202611020437；最新构建为 X-2，测 X-1 时须从「以前的构建」里手动选号），首崩即停并导出崩溃报告。
