# ZORDER-FIX 案卷：介入态下浏览器浮到顶层（层级修复）

- 构建：**202611030239**（0.1.0），分支 `feat/zorder-fix`（基线＝feat/autonomy-fix tip `a45afc4`，含构建 0227，未合 main），功能提交 `c439f73`；本案卷＋日志随证据提交入库。
- 规格：ZORDER-FIX-SPEC-2026-11-03.md（父级单据，未动未提交）。

## 立项与现场
Joey 2026-11-03 10:20 真机截图＋亲述：介入卡（需要你手动处理）出现后点卡上「打开浏览器」，预期浏览器浮到最顶层供亲手操作网页（这正是介入请他做的事）；实际介入卡＋UI-LEGIBILITY 引入的整屏变暗遮罩仍压在浏览器之上，浏览器被遮挡、手动那一步做不了。0209 的可读性修复已获 Joey 确认「弹窗对味了」，本单只修层级、不回退可读性成果。

## 根因（代码定位）
ContentView 根 ZStack 的既有顺序把介入层（遮罩＋卡）整体放在浏览器坞之上：坞经 expandRequest 展开为全屏后，遮罩仍整屏压暗坞、介入卡（手输卡正文较长时占屏下部约四成）仍覆在网页之上并拦截其区域的触摸。介入请用户去网页上亲手处理，呈现层却把网页挡在介入层之下——层级与流程自相矛盾。

## 实现（纯呈现层，只动 3 个文件）
### 1. 层级换位：根层级表 InterventionZOrder（MikaWeb/ContentView.swift 新增）
层级名次抽成纯函数表，ContentView 的 ZStack 五个子层各自以 `.zIndex(InterventionZOrder.*(browserRaised:))` 取值，自检十九断言同一份数值（非另抄常量）：
- 常态（browserRaised=false）：对话 0 ＜ 坞 1 ＜ 遮罩 2 ＜ 介入卡 3 ＜ 输入栏 4——与 0209 定版逐值一致，非介入态与未置顶的介入态层级零变化，OverlayStyle／遮罩参数（0.42、不拦截触摸）原样未动。
- 置顶态：对话 0 ＜ 遮罩 1 ＜ 坞 2 ＜ 介入卡（小条）3 ＜ 输入栏 4——**只交换坞与遮罩的名次**：遮罩退到坞之下，结构上不再覆盖浏览器窗口（坞展开态为整屏不透明层，其下遮罩无从透出；坞小窗态下遮罩只压暗对话层）；卡与输入栏名次不变。

### 2. 置顶态的进入与退出（ContentView）
- 进入：InterventionPrompt 的 onOpenBrowser 回调改为同一次点击内 `dockExpandRequest += 1; interventionBrowserRaised = true`——与既有展开令牌同源同刻，都是用户点击，不是程序自动动作；坞的展开路径（expandRequest onChange→expand()）零改动。
- 新状态 `@State interventionBrowserRaised` 只活在 ContentView，只驱动 zIndex 与卡片 compact 下传，不参与任何引擎／安全判定；与 AUTONOMY-FIX 的分类门只做呈现配合（哪些介入许停车由引擎判，本单不读不改）。
- 退出（层级恢复）：`.onChange(of: showsInterventionPrompt)` 在介入解除（点「已处理，继续」走 engine.resume()、确认卡 submit、上传卡解决，乃至切走会话使卡片隐去）时自动复位 raised=false，名次回到常态——与 AUTONOMY 后的介入语义一致，安全类停车点「已处理」的回读口径未动（resume 路径零改动）。
- 另一退出：小条上的「说明」按钮（onShowFull）只复位 raised 回到全卡＋常态层级，供用户重读详情；不是解决动作，不碰引擎状态。

### 3. 退让形态：介入卡收成小条（MikaWeb/AgentChatView.swift）
三卡各加 compact 渲染分支（InterventionPrompt 新增 `compact`/`onShowFull` 两参数下传），形态＝固定在输入栏上方的单行条（沿用 .padding(.bottom, inputBarHeight + 6) 与 interventionCardBackground 厚材质背景，可读性规格不降）：
- 手输卡小条：「需要你手动处理」短标题＋「说明」＋「已处理，继续」（.borderedProminent，走 engine.resume() 既有路径）。
- 确认卡小条：「等待确认」短标题＋「说明」＋「拒绝」＋「确认执行」——仍走本卡 submit(_:) 的全字段比对守卫与 engine.confirm 路径。
- 上传卡小条：按阶段——confirmUpload：「上传确认」＋「说明」＋「取消」＋「确认上传」；pickFile：「选择文件」＋「说明」＋「取消上传」＋「已选好，继续核验」——仍走本卡 lock 守卫与引擎既有解决路径。
- 紧凑渲染是各卡 body **内部**分支：卡视图身份不变，@State locked 防重复锁不因全卡↔小条切换丢失；说明文字在小条不绘制（用户已从全卡读过、且「说明」随时可回看），按钮文案与全卡逐字一致（小条标题为短标题，属退让形态的呈现压缩，不改任何解决语义）。

### 4. 几何核对（静态推算，真机观感属未证项）
小条位于屏底输入栏之上（底边距输入栏 6pt、高约 46–50pt），占据的是网页最底部一条；坞展开态的收起按钮底边在 bottomReserve+12（≈输入栏高＋54pt）处，与小条顶边（≈输入栏高＋52–56pt）邻接、基本不重叠——置顶态下收起按钮若被小条右端轻微压住，用户仍可经「说明」回全卡或解决介入后恢复常态，不构成死锁。

## 自检十九（MikaWeb/SelfTestView.swift 续排）
Tier A（本按钮，不调用模型、不占用标签页）：对 InterventionZOrder 层级表与 cardCompact 真值共 7 项结构断言——①常态遮罩＞坞（0209 口径）；②常态卡＞遮罩、坞＞对话、输入栏最上；③置顶态坞＞遮罩（遮罩不覆盖浏览器窗口）；④置顶态卡（小条）＞坞（解决按钮可达）；⑤置顶态遮罩仍＞对话、输入栏仍最上；⑥置顶切换只交换坞与遮罩名次、卡与输入栏名次不变；⑦收条与置顶同进退。
Tier B 真机清单（人工，不在本按钮内执行）：
1. 公众号场（或任一安全类停车场）遇介入卡→点「打开浏览器」：浏览器应浮到顶层（页面不再被压暗、卡不再覆在网页上），能亲手点网页弹窗（如条款弹窗的「取消」）完成处理。
2. 点小条「已处理，继续」：层级恢复常态、任务按 AUTONOMY 口径续跑；安全类停车（发表确认）的回读口径与此前一致。
3. 小条「说明」：回全卡可重读详情，再点「打开浏览器」可再次置顶。
4. 确认卡／上传卡在小条上各解决一次，守卫与全卡一致（防重复点按不串）。
5. 非介入态回归：坞小窗／展开、输入栏、sheet 的层级与手感与 0227 一致；介入卡未点「打开浏览器」时仍是 0209 的压暗＋全卡形态。
6. WKWebView 连续性：置顶换位前后页面不重载、不丢登录态与编辑器内容（zIndex 只换名次的预期须真机证实）。

## CI／Release 双核对（日志原文，不认 run 结论）
- validate_project.py：全 PASS（31 Swift 源、12 项资源集，与基线同数，无新增文件）。
- CI Run **41567228809** success：日志原文核对——70 条 SwiftCompile、ContentView/AgentChatView/SelfTestView 三个改动文件均在编译列、BUILD SUCCEEDED ×1、BUILD FAILED ×0，唯一 `error:` 为既有 AppIntents 训练噪声（appintentsnltrainingprocessor SSU artifacts，与历轮一致）。
- Release Run **41567382463** success：agvtool 置号 202611030239、Archive Succeeded ×1、Successfully uploaded package ×1；dSYM artifact `dsym-41567382463` 实存 **4,988,814 字节**、未过期（本地下载解开核对：MikaWeb.app.dSYM 目录在位，DWARF 主文件 9,134,536 字节）。
- ASC 状态：**待阿仁亲验**（本单未记 VALID、未挂组）。

## 红线自查（git diff 对基线 a45afc4 实查）
- MikaWeb/SafetyPolicy.swift：**0 行**改动；MikaWeb/MikaWebApp.swift（单持有者）：**0 行**改动；MikaWeb/AgentEngine.swift 及全部引擎／感知文件：**0 行**改动（本单只动 ContentView.swift、AgentChatView.swift、SelfTestView.swift 三个呈现层文件，共 +203/−28）。
- 无新依赖；凭据不落盘；新增用户可见文案无「并行执行」；未合 main；父级各 SPEC 文件未动、未提交（仍为未跟踪状态）。

## 未证项（不得视为已验）
1. 自检十九 Tier A 未真机运行（本机无 Swift 工具链，与历轮同口径）——断言代码已编译进构建，待真机点按回读。
2. 真机层级观感未证：浏览器是否真浮到顶层、网页弹窗是否真可亲手点、小条是否挡到具体页面操作区（微信编辑器底部按钮区）、深色模式下小条观感，均待 Tier B 第一条起逐项实测。
3. zIndex 换位对 WKWebView 实例连续性的影响未经真机证实：实现上是同一视图实例只改名次、不重建，但「页面不重载／不丢状态」须 Tier B 第 6 条实测确认后才算成立。
4. 小条与坞收起按钮的几何邻接为静态推算（见实现 4），真机若发现压挡，按实测再调（二选一：小条缩短右端让位或收起按钮上移），不在本单预先改动。
