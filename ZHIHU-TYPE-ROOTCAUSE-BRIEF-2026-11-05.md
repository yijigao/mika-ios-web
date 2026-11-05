# 知乎 type 字数 0 —— 第四轮根因咨询包（2026-11-05）

## 症状（Joey 真机，2026-11-05 19:23，构建 202611040911）

Mika Web 在知乎回答编辑器执行 type：文字视觉上出现在编辑器里，但编辑器内部字数仍为 0（写入前 0 字）。App 内置校验正确检出该状态，自动轮换 5 种输入方式全部失败后停手，并拒绝在该状态下点更新（会提交旧内容）——即「防假成功」层生效，但输入路径本身三轮修复仍未攻下。Joey 原话：「这个问题始终没修复」「之前都能发表成功 现在怎么还更傻了」。

## 前三轮改了什么（关键事实）

- 刀 in 0834 包：字数修复第二轮。
- 刀5（commit ba72cd6，0911 包）：「探针全域搜字数＋长文分发收紧＋路径留痕」——改动集中在 TypeVerifyPolicy.swift（校验探针）与 SelfTestView.swift（自检四十/四十一），WebController.swift 的改动以分发收紧与留痕为主。**即第三轮主要修的是「检测与诚实报错」，不是输入机制本身。**
- 现有输入路径（WebController.swift 约 L1946–2055）：聚焦＋全选后 execCommand('insertText')；beforeinput/input（InputEvent，inputType=insertText，honor preventDefault 防双写）；逐段插入＋insertParagraph；若干 fallback 的 input/change 事件分发。5 条路径对知乎编辑器全部无效。

## 环境与约束

- WKWebView（iOS），JS 注入驱动，无硬件键盘通道；点击为脚本注入事件（不可信事件）。
- 目标是知乎移动 Web 回答编辑器（Draft.js 类富文本，contentEditable，框架自管 EditorState）。
- 安全边界不变：密码/验证码/付款步 agent 不填；type 失败必须 fail-closed 报错，不许假成功（此层已达标，不得回退）。

## 待裁决问题（请 Astra 输出：结论＋关键依据＋最强反例＋还缺哪条证据）

1. 根因排序：为什么 execCommand insertText 与合成 beforeinput/input 都进不了知乎编辑器的内部状态？候选：(a) 合成事件 isTrusted=false 被框架/编辑器忽略；(b) 事件目标/传播路径不对（React 根监听、composed 路径）；(c) WKWebView 内 execCommand 在无第一响应者/无真实键盘焦点时只改 DOM 不同步框架；(d) 知乎编辑器为自研而非 Draft.js，另有私有输入管线；(e) 选区不在编辑器内（焦点落在宿主文档）。
2. 最有希望的输入机制：粘贴路线（ClipboardEvent＋DataTransfer 分发）、带 getTargetRanges 的 InputEvent、真实点击聚焦后逐字 KeyboardEvent、调用页面编辑器自身 API（如有）、或其他——给出首选＋备选及各自判据。
3. 验收设计（先于实现定死）：本地复现页（Draft.js 官方 demo 或等价 contentEditable 框架页）＋断言口径——成功＝编辑器**内部状态**字数 > 0 且与输入一致（读框架状态/字数控件），DOM 有字不算过。此验收不过，不许出包给 Joey 复测。
