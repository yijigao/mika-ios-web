# 0808 真机终止报告（Joey 2026-11-02 16:31 在主聊贴出全文）

- 构建：202611020808（0.1.0，com.jigaoyi.mikaweb，TestFlight）
- 设备/系统：iPhone14,5，iPhone OS 27.2 (24B5110a)，arm64e
- 发生时刻：2026-11-02 16:30:33 CST（Joey 16:25 报「离开前台就不工作了」之后数分钟；当时有知乎任务在跑）
- 类型：**不是代码崩溃，是系统看门狗终止**
  - exceptionType 10，signal 9，exceptionCode 0
  - terminationReason 原文：`scene-update watchdog transgression: app<com.jigaoyi.mikaweb>:50880 exhausted real (wall clock) time allowance of 10.00 seconds`，code **0x8BADF00D**
  - ProcessVisibility: **Background**，ProcessState: Running，WatchdogEvent: scene-update，WatchdogVisibility: Background
  - CPU：Elapsed total 49.520s（user 14.060 / system 35.460，81%），但 **Elapsed application CPU 仅 0.150s（0%）**——App 本体几乎没耗 CPU，是场景更新事务在后台 10 秒内没完成被杀
- 归因线程：CoreFoundation runloop → UIKitCore 场景更新链 → FrontBoardServices → GraphicsServices → SwiftUI → **MikaWeb offsetIntoBinaryTextSegment 131656**（全栈唯一的 App 帧，MikaWeb binary UUID 345CC20D-646D-3CFE-A859-55DBD615B660，待用 0808 dSYM 符号化）
- 其余线程：WebKit/JavaScriptCore/CFNetwork 等系统线程在等待状态，无 App 帧

## 定性（阿仁）
问题 1 的机制实锤：任务运行中切后台，系统要求完成 scene-update 事务，App 主线在 10 秒墙钟内没收尾，被 iOS 直接终止（进程死亡＝任务死亡、状态全丢）。修复要点不在「后台继续跑」而在：进后台瞬间立即让主线安静（停 DOM 轮询/暂停高频状态发布/让 SwiftUI 更新收敛）、快速完成后台收尾；符号化 131656 定位是哪块视图更新在场景事务路径上。

全文 JSON 由 Joey 贴于 2026-11-02 16:31 主聊消息（id 0E777490-CE11-41B6-8EA1-A4AF7EDC61BE 为报告内 id）。
