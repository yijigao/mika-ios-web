import Foundation
import UIKit

// 封面自产（COVER-CONSENT-IMPL-2026-11-03，缺陷 B）：Joey 2026-11-03
// 01:46 真机现场——公众号文章已存草稿、卡在封面：素材库没有可用封面，
// Joey 当场指示 agent「你是 GPT 你自己生产一张弄上去」，而 agent 没有
// 任何图片生成/建文件工具，只能如实拒绝。本文件补上这条能力：纯本机
// 渲染（UIGraphicsImageRenderer＋系统字体＋纯形状装饰），不接外部图像
// 生成 API、无新依赖。产物＝微信封面尺寸 900×383 PNG，经
// AttachmentStore 登记进当前会话附件、来源标为「本任务生成」
// （taskGenerated）——upload_file 引用它时正好走 F1 已落地的 SP-01
// 豁免判定（任务生成文件不弹新卡，原有对外发送/敏感边界不变），
// 附件中心 UI 按来源徽标展示。生成只是把文件备好，设没设上封面以
// 页面回读为准（系统提示与 playbook 均按此口径）。

/// 封面版式：三款内置模板，模型以 dark/light/green（或中文别名）点名。
enum CoverTemplate: String, CaseIterable {
case darkTech = "dark"
case lightMinimal = "light"
case wechatGreen = "green"

static func from(_ raw: String) -> CoverTemplate {
let s = raw.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
if s.contains("浅") || s.contains("light") || s.contains("简约") || s.contains("minimal") { return.lightMinimal}
if s.contains("绿") || s.contains("green") || s.contains("微信") { return.wechatGreen}
return.darkTech
}

var label: String {
switch self {
case.darkTech: return "深色科技"
case.lightMinimal: return "浅色简约"
case.wechatGreen: return "公众号绿系"
}
}

struct Palette {
let bgStart: UIColor
let bgEnd: UIColor
let accent: UIColor
let title: UIColor
let subtitle: UIColor
}

var palette: Palette {
switch self {
case.darkTech:
return Palette(bgStart: UIColor(red: 0.05, green: 0.08, blue: 0.15, alpha: 1),
bgEnd: UIColor(red: 0.07, green: 0.16, blue: 0.27, alpha: 1),
accent: UIColor(red: 0.22, green: 0.88, blue: 1.0, alpha: 1),
title:.white,
subtitle: UIColor(red: 0.74, green: 0.84, blue: 0.91, alpha: 1))
case.lightMinimal:
return Palette(bgStart: UIColor(red: 0.99, green: 0.99, blue: 0.99, alpha: 1),
bgEnd: UIColor(red: 0.93, green: 0.95, blue: 0.96, alpha: 1),
accent: UIColor(red: 0.15, green: 0.39, blue: 0.92, alpha: 1),
title: UIColor(red: 0.07, green: 0.09, blue: 0.15, alpha: 1),
subtitle: UIColor(red: 0.36, green: 0.40, blue: 0.45, alpha: 1))
case.wechatGreen:
return Palette(bgStart: UIColor(red: 0.03, green: 0.76, blue: 0.38, alpha: 1),
bgEnd: UIColor(red: 0.02, green: 0.60, blue: 0.28, alpha: 1),
accent:.white,
title:.white,
subtitle: UIColor(red: 0.90, green: 1.0, blue: 0.95, alpha: 1))
}
}
}

enum CoverGenerator {
/// 微信公众号封面尺寸（头条图 900×383）。
static let canvasSize = CGSize(width: 900, height: 383)
private static let margin: CGFloat = 56

// MARK: - 渲染

/// 渲染一张封面 PNG：渐变底＋低透明装饰圆（纯形状，无外部素材）＋
/// 强调条＋标题（自动换行、字号自适应：从 60pt 起降到能以 ≤3 行放进
/// 文案区为止）＋副标题（可选，≤2 行）。标题为空直接拒绝——不产出
/// 空封面冒充成果。
static func renderPNG(title: String, subtitle: String, template: CoverTemplate) -> Data? {
let title = title.trimmingCharacters(in:.whitespacesAndNewlines)
let subtitle = subtitle.trimmingCharacters(in:.whitespacesAndNewlines)
guard !title.isEmpty else { return nil}
let palette = template.palette
let format = UIGraphicsImageRendererFormat()
format.scale = 1
format.opaque = true
let image = UIGraphicsImageRenderer(size: canvasSize, format: format).image { context in
let cg = context.cgContext
let rect = CGRect(origin:.zero, size: canvasSize)
if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
colors: [palette.bgStart.cgColor, palette.bgEnd.cgColor] as CFArray,
locations: [0, 1]) {
cg.drawLinearGradient(gradient, start:.zero,
end: CGPoint(x: canvasSize.width, y: canvasSize.height), options: [])
} else {
palette.bgStart.setFill()
cg.fill(rect)
}
// 装饰圆：只用版式强调色加低透明度，不抢文案
func circle(_ center: CGPoint, _ radius: CGFloat, _ alpha: CGFloat) {
palette.accent.withAlphaComponent(alpha).setFill()
UIBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius,
width: radius * 2, height: radius * 2)).fill()
}
circle(CGPoint(x: 848, y: 36), 150, 0.13)
circle(CGPoint(x: 768, y: 306), 88, 0.09)
circle(CGPoint(x: 58, y: 366), 66, 0.07)

let textWidth = canvasSize.width - margin * 2
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .left
paragraph.lineSpacing = 6
let titleFont = fittedTitleFont(title: title, maxWidth: textWidth, hasSubtitle:!subtitle.isEmpty)
let titleAttr = NSAttributedString(string: title, attributes: [
.font: titleFont,.foregroundColor: palette.title,.paragraphStyle: paragraph])
let titleHeight = ceil(titleAttr.boundingRect(
with: CGSize(width: textWidth, height:.greatestFiniteMagnitude),
options: [.usesLineFragmentOrigin,.usesFontLeading], context: nil).height)
var subtitleAttr: NSAttributedString?
var subtitleHeight: CGFloat = 0
if !subtitle.isEmpty {
let attr = NSAttributedString(string: subtitle, attributes: [
.font: UIFont.systemFont(ofSize: 28, weight:.regular),
.foregroundColor: palette.subtitle,.paragraphStyle: paragraph])
subtitleHeight = ceil(attr.boundingRect(
with: CGSize(width: textWidth, height:.greatestFiniteMagnitude),
options: [.usesLineFragmentOrigin,.usesFontLeading], context: nil).height)
subtitleAttr = attr
}
let barHeight: CGFloat = 10, barGap: CGFloat = 26, subGap: CGFloat = 16
let total = barHeight + barGap + titleHeight + (subtitleAttr == nil ? 0 : subGap + subtitleHeight)
var y = max(24, (canvasSize.height - total) / 2)
palette.accent.setFill()
UIBezierPath(roundedRect: CGRect(x: margin, y: y, width: 76, height: barHeight),
cornerRadius: barHeight / 2).fill()
y += barHeight + barGap
titleAttr.draw(with: CGRect(x: margin, y: y, width: textWidth, height: titleHeight),
options: [.usesLineFragmentOrigin,.usesFontLeading], context: nil)
if let subtitleAttr {
y += titleHeight + subGap
subtitleAttr.draw(with: CGRect(x: margin, y: y, width: textWidth, height: subtitleHeight),
options: [.usesLineFragmentOrigin,.usesFontLeading], context: nil)
}
}
return image.pngData()
}

/// 标题字号适配：从 60pt 起逐级减小，直到文本能以 ≤3 行、且总高不
/// 超文案区上限（有副标题 176pt、无副标题 216pt）放下；30pt 兜底
/// （超长标题在 30pt 下仍超限时由绘制区自然裁切，不无限降级到不可读）。
private static func fittedTitleFont(title: String, maxWidth: CGFloat, hasSubtitle: Bool) -> UIFont {
let maxHeight: CGFloat = hasSubtitle ? 176 : 216
var size: CGFloat = 60
while size > 30 {
let font = UIFont.systemFont(ofSize: size, weight:.bold)
let paragraph = NSMutableParagraphStyle()
paragraph.lineSpacing = 6
let attr = NSAttributedString(string: title, attributes: [.font: font,.paragraphStyle: paragraph])
let height = attr.boundingRect(with: CGSize(width: maxWidth, height:.greatestFiniteMagnitude),
options: [.usesLineFragmentOrigin,.usesFontLeading], context: nil).height
if height <= maxHeight, height <= font.lineHeight * 3.4 { return font}
size -= 2
}
return UIFont.systemFont(ofSize: 30, weight:.bold)
}

// MARK: - 生成并登记（引擎 generate_cover 动作的落点）

/// 渲染＋登记进指定会话的附件目录：来源恒为 taskGenerated（本任务
/// 生成），展示名「封面-<标题前 18 字>.png」；登记后附件中心可见、
/// 注入段可引用，upload_file 引用时走 SP-01 豁免。
/// 标题为空或渲染失败返回 nil（引擎据此如实回报，不假装已生成）。
@discardableResult
static func generate(title: String, subtitle: String, template: CoverTemplate, sessionID: UUID) -> AttachmentRecord? {
guard let data = renderPNG(title: title, subtitle: subtitle, template: template) else { return nil}
let short = String(title.trimmingCharacters(in:.whitespacesAndNewlines).prefix(18))
return AttachmentStore.shared.registerData(data, displayName: "封面-\(short).png",
sessionID: sessionID, origin:.taskGenerated,
isScreenshot: false)
}

// MARK: - 自检十一 Tier A（COVER-CONSENT）：封面自产的程序化核查

/// 渲染三款版式（尺寸＋非空白像素）、空标题拒绝、scratch 会话里
/// 生成登记（落盘/来源标记/缩放副本）、SP-01 豁免判定、注入段口径。
/// 结论逐条人读（✓/✗ 开头）；scratch 会话结束时切回原会话并删除干净。
static func verifyCoverGeneration() -> [String] {
var lines: [String] = []
let longTitle = "用豆包整理会议纪要：一套能直接复制的提示词与核对清单（自检十一长标题样本）"
var renders: [(template: CoverTemplate, data: Data, image: UIImage)] = []
var renderFailed = false
for template in CoverTemplate.allCases {
guard let data = renderPNG(title: longTitle, subtitle: "自检十一副标题样本", template: template),
let image = UIImage(data: data) else { renderFailed = true; break}
renders.append((template, data, image))
}
lines.append(!renderFailed && renders.count == 3 && renders.allSatisfy { $0.image.size == canvasSize}
? "✓ 三款版式渲染：深色科技／浅色简约／公众号绿系各产出一张 900×383 PNG（长标题自动换行与字号适配已走通）"
: "✗ 版式渲染异常（完成 \(renders.count)/3 款）")
if let first = renders.first {
lines.append(isNonBlank(first.data)
? "✓ 非空白核查：抽样像素含足够多不同色值（渐变底与装饰在场，不是白图/纯色图冒充）"
: "✗ 非空白核查未过（渲染疑似空白或纯色）")
}
lines.append(renderPNG(title: " ", subtitle: "", template:.darkTech) == nil
? "✓ 空标题被拒：不产出空封面冒充成果"
: "✗ 空标题未被拒")
let store = SessionStore.shared
let originalID = store.currentSessionID
let scratch = store.createSession(title: "自检十一临时会话")
defer {
store.setCurrentSession(id: originalID)
_ = store.deleteSession(id: scratch.id)
}
let record = generate(title: "自检十一封面", subtitle: "来源标记核查", template:.wechatGreen, sessionID: scratch.id)
let fm = FileManager.default
let registered = record.map {
$0.origin == .taskGenerated && $0.readState == .imageScaled
&& fm.fileExists(atPath: AttachmentStore.shared.fileURL(for: $0).path)
&& AttachmentStore.shared.fileURL(for: $0).path.contains("/attachments/")
} ?? false
lines.append(registered
? "✓ 生成登记：封面落进会话 attachments/ 目录、来源标记＝本任务生成、图片缩放副本就绪（附件中心按来源徽标展示）"
: "✗ 生成登记异常（记录 \(record == nil ? "缺失" : "在位")）")
if let record {
lines.append(SafetyPolicy.uploadDecision(isTaskGenerated: record.origin == .taskGenerated) == .allow
? "✓ SP-01 豁免判定：本任务生成的封面走.allow（不弹 SP-01 新卡；原有对外发送与敏感信息边界不变）"
: "✗ SP-01 豁免判定异常")
let block = AttachmentStore.shared.promptBlock(for: scratch.id)
lines.append(block.contains(record.displayName) && block.contains("本任务生成")
? "✓ 注入段：封面在清单内、来源标为本任务生成，模型可按编号引用它走 upload_file"
: "✗ 注入段口径异常（清单或来源标记缺失）")
}
lines.append("临时会话将在本自检结束时切回原会话并删除干净")
return lines
}

/// 非空白判定：对 PNG 解码后的像素抽样（约 2000 点），不同 RGB 色值
/// 超过 24 种即判非空白——渐变底必然过线，纯色/空白图必然不过。
private static func isNonBlank(_ pngData: Data) -> Bool {
guard let image = UIImage(data: pngData), let cg = image.cgImage,
let provider = cg.dataProvider, let cf = provider.data,
let ptr = CFDataGetBytePtr(cf) else { return false}
let length = CFDataGetLength(cf)
guard length > 4 else { return false}
var distinct = Set<Int>()
let stride = max(4, (length / 2000) / 4 * 4)
var offset = 0
while offset + 2 < length {
distinct.insert((Int(ptr[offset]) << 16) | (Int(ptr[offset + 1]) << 8) | Int(ptr[offset + 2]))
if distinct.count > 24 { return true}
offset += stride
}
return distinct.count > 24
}
}
