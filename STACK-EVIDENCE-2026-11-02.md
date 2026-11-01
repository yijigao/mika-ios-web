# Mika Web 触摸闪退 — MetricKit 崩溃栈证据（Joey 2026-11-02 03:10 发回，共 4 份）

## 共同异常签名（4 份完全一致）

- 异常：`NSInvalidArgumentException`
- 原文：`*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil`
- exceptionType 10，signal 6（未捕获 ObjC 异常 → abort），exceptionCode 0
- 设备 iPhone14,5；iOS 27.2 (24B5110a)；TestFlight；bundle com.jigaoyi.mikaweb

## 4 份报告清单

| # | 构建 | 崩溃时刻 (CST) | pid | MikaWeb UUID | MikaWeb 帧偏移 |
|---|------|---------------|-----|--------------|----------------|
| 1 | 202611011747 | 2026-11-02 02:01:31 | 43590 | 7D230838-DF32-30AC-A246-2C1B2AECB4C0 | 94536 |
| 2 | 202611011747 | 2026-11-02 02:04:37 | 43618 | 同上 | 94536 |
| 3 | 202611011811 | 2026-11-02 02:43:35 | 44134 | 51C51A14-23DF-38CE-9A9F-2886C241FA49 | 97816 |
| 4 | 202611011811 | 2026-11-02 02:43:41→43 | 44159 | 同上 | 97816 |
| 5 | 202611011920 | 2026-11-02 03:40:34 | 44735 | F0B09D5F-16F3-37B4-BAA7-6E64AD7D985A | 99412 |
| 6 | 202611011920 | 2026-11-02 03:43:15 | 44775 | 同上 | 99412 |

补充定位结果（开关版 1920，Joey 真机，2026-11-02）：
- 第 0 步全开：崩（报告 5，03:40:34）。
- 第 1 步仅关 F_FOCUS：崩（报告 6，03:43:15，Joey 确认「关了还崩」）→ `.focused` 连接单独排除。
- 其后 Joey 将其余开关逐个单关试完（F_INPUT/F_SCROLL/F_CHAT/F_PANELSTATE/F_OBSERVE/F_CONVSINK/F_PANELSINK/F_DIAG/F_GEO）：**全部仍崩**（03:47 口头报告，未逐份导栈）。单因素矩阵证伪：触发点不在任一单个开关之后——或为多路径冗余触发，或在开关覆盖之外（App 入口/新父树/WebView 挂载路径等），待 CRASH-HUNT-2 审计与「全关」实验判读。

结论一：**1747 与 1811 是同一个 bug**（异常签名一致、同构建内 MikaWeb 帧偏移一致）。CRASH-HUNT-V022 中「症状相同≠已证同源」的限定就此解除。
结论二：02:43 两份即 Joey 对 1811 的复测点击——Z1/Z2 零构建实验无需再做，数据已有。

## 崩溃线程（threadAttributed=true）帧链（自顶向下，偏移为 offsetIntoBinaryTextSegment）

顶层为异常终止链：libsystem_kernel 45564 → libsystem_pthread 29760 (pthread_kill) → libsystem_c 498028 (abort) → libc++abi 15772/36844 → libobjc 201748 → libc++abi 80988/88252/8052 → libobjc 50424 (objc_exception_throw) → CoreFoundation 157080 (__exceptionPreprocess) → 然后进入抛出点：

- UIKitCore 6172552
- UIKitCore 963900
- UIKitCore 963760
- UIKitCore 963116
- UIKitCore 970768
- UIKitCore 6162088
- UIKitCore 932180
- UIKitCore 440156
- UIKitCore 435564
- UIKitCore 434956
- UpdateCycle 3060
- CoreFoundation 若干帧（CFRunLoop 观察者/主循环；第 1 份 1747 报告此段为 CF 157628/303296/303824/239140，其余三份为 368052/367912/242264(或242380)/238452）
- CoreFoundation 243684
- GraphicsServices 3876
- UIKitCore 764760（UIApplicationMain 区域）
- SwiftUI 293604 / 266876 / 266556
- **MikaWeb 94536（1747）/ 97816（1811）— 全栈唯一的 App 帧，位于栈底（main 入口）**
- dyld 21796 (start)

其余线程：JavaScriptCore/WebKit 工作线程各一份，无 App 帧，与崩溃无关。

## 判读

1. 抛出路径中**没有任何 App 业务代码帧**（只有栈底 main）。异常由 UIKitCore 在一次 SwiftUI UpdateCycle（触摸后触发的界面更新周期）内部抛出：某条系统代码路径往 NSMutableArray 插入了 nil。
2. 因此这不是「我们的代码直接调错 API」，而是**视图层级中某个构造让系统在触摸后重建某组对象时拿到 nil**。v0.2 新增构造中与该路径相干的嫌疑（按栈特征排序，供定界参考、非结论）：
   - 聊天输入区：纵向 TextField（UITextView 底座）＋ @FocusState——点 WKWebView 会引发 first responder / 输入链重建，是「触摸网页→系统更新周期→数组插入 nil」最贴合的已知类别（C1b 升为第一嫌疑）。
   - 聊天 ScrollView 的手势仲裁依赖（C1a）。
   - 任何向 responder 链提供 toolbar / inputAssistantItem 的构造（若有）。
3. 1652 不崩、v0.2 起崩、改覆盖层几何不影响——与上述判读自洽：触发点在 v0.2 引入的聊天子树与系统输入/手势系统的交互，不在覆盖层几何。
4. 符号化备注：MikaWeb 帧只是 main，符号化它没有定位价值；UIKitCore 偏移（963900 簇、440156 簇、6172552）可用公开符号知识/检索比对函数族，但不必强求——修复验证靠真机复测同场景。

## 修复纪律

- 不许再按单一嫌疑盲修发版让 Joey 试错。优先顺序：① Astra 拿本证据＋ CRASH-HUNT-V022 做定界，给出最小改动方案；② 若定界仍不能锁定单一构造，则按 CRASH-HUNT §4 发开关版（F_INPUT/F_FOCUS 优先），一个构建内定位；③ 改动后必须说明「为何该改动能切断 insertObject nil 这条链」，说不清不发版。
