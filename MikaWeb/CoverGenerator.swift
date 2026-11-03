import Foundation
import UIKit
import Photos

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
//
// COVER-UPLOAD-FIX（2026-11-03）追加：0336 真机现场——封面已生成却
// 传不上：图只在 App 沙箱/附件区，Joey 手动上传时在系统相册里找不到
// 它，文件名又带全角标点（「封面--别让AI替你…；用这套三步法.png」）
// 在选择器里极难对号。本文件两处对治：① 生成文件名改走
// GeneratedFileName（短名、只用 ASCII 安全字符）；② 生成后同时写入
// 系统相册（PhotoLibrarySaver，只申请「添加」权限），步流把「已存入
// 相册＋确切文件名」或失败原因如实说清——用户在相册「最近项目」最新
// 一张即可命中，不必再翻沙箱文件。

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
/// 生成），展示名走 GeneratedFileName 的 ASCII 安全短名（COVER-
/// UPLOAD-FIX B）；登记后附件中心可见、注入段可引用，upload_file
/// 引用时走 SP-01 豁免。
/// 标题为空或渲染失败返回 nil（引擎据此如实回报，不假装已生成）。
@discardableResult
static func generate(title: String, subtitle: String, template: CoverTemplate, sessionID: UUID) -> AttachmentRecord? {
guard let data = renderPNG(title: title, subtitle: subtitle, template: template) else { return nil}
return AttachmentStore.shared.registerData(data, displayName: GeneratedFileName.coverFileName(title: title),
sessionID: sessionID, origin:.taskGenerated,
isScreenshot: false)
}

/// 生成＋登记＋写入系统相册（COVER-UPLOAD-FIX A，引擎 generate_cover
/// 的现行落点）：附件登记与旧路径一致；相册写入是追加动作——成功时
/// 给记录打 savedToPhotos 标记（附件中心与选文件指引据此说话），失败
/// （未授权/系统错误）只如实回报 outcome，不影响附件本身可用。
/// record 为 nil＝渲染失败（photo 恒为 nil）。
static func generateAndSaveToPhotos(title: String, subtitle: String, template: CoverTemplate, sessionID: UUID) async -> (record: AttachmentRecord?, photo: PhotoSaveOutcome?) {
guard let record = generate(title: title, subtitle: subtitle, template: template, sessionID: sessionID) else { return (nil, nil) }
guard let data = try? Data(contentsOf: AttachmentStore.shared.fileURL(for: record)) else {
return (record,.failed("附件落盘后回读失败"))
}
let outcome = await PhotoLibrarySaver.saveImageData(data)
if outcome == .saved {
AttachmentStore.shared.markSavedToPhotos(id: record.id, sessionID: sessionID)
}
return (record, outcome)
}

// MARK: - 生成文件命名规整（COVER-UPLOAD-FIX B）

/// 本任务生成文件的命名规整（纯函数，自检二十二断言）：短名、只用
/// ASCII 字母/数字/连字符——全角标点、空格、中文一律不进文件名（中文
/// 标题进 slug 时整段被折成连字符，slug 为空时退到时间戳名）。这样
/// 文件名在系统选择器、附件中心、模型引用三处都易对号、不会被任何
/// 一层转码或截断搞坏。注意：标题原文只活在步流与图面文字里，文件名
/// 不承担标题语义（附件身份靠稳定 ID，见 AttachmentStore）。
enum GeneratedFileName {
/// slug 部分（cover- 之后、.png 之前）的字符上限
static let slugLimit = 24

static func coverFileName(title: String, date: Date = Date()) -> String {
let slug = asciiSlug(title)
if !slug.isEmpty { return "cover-\(slug).png" }
let formatter = DateFormatter()
formatter.locale = Locale(identifier: "en_US_POSIX")
formatter.dateFormat = "yyyyMMdd-HHmmss"
return "cover-\(formatter.string(from: date)).png"
}

/// ASCII slug：小写字母与数字原样保留，其余字符（空白/标点/全角/
/// 中文等）整段折成单个连字符；首尾连字符去掉；超 slugLimit 截断
/// 后再去尾连字符。纯中文标题 → 空串（调用方退时间戳名）。
static func asciiSlug(_ raw: String) -> String {
var slug = ""
var pendingSeparator = false
for scalar in raw.lowercased().unicodeScalars {
let isSafe = (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57)
if isSafe {
if pendingSeparator, !slug.isEmpty { slug.append("-") }
pendingSeparator = false
slug.append(Character(scalar))
} else {
pendingSeparator = true
}
}
if slug.count > slugLimit {
slug = String(slug.prefix(slugLimit))
while slug.hasSuffix("-") { slug.removeLast() }
}
return slug
}
}

// MARK: - 系统相册写入（COVER-UPLOAD-FIX A）

/// 相册写入结局：三态分开——saved 才许说「已存入相册」；denied（用户
/// 未给「添加照片」权限）与 failed（系统错误）都如实进文案，不许把
/// 「已生成」说成「在相册里能找到」。
enum PhotoSaveOutcome: Equatable {
case saved
case denied
case failed(String)

/// 引擎步流文案（纯函数，自检二十二断言口径）：每态一句话，带确切
/// 文件名——用户照这句去相册「最近项目」对号，或知道图不在相册、
/// 该去附件中心找。
func stepDescription(fileName: String) -> String {
switch self {
case.saved:
return "封面已生成并存入系统相册（相册「最近项目」里最新的一张就是它，文件名 \(fileName)）"
case.denied:
return "封面已生成，但没有存入系统相册（未获得「添加照片」权限，文件名 \(fileName)）——它在本会话附件里，上传时照选文件卡指引从附件中心找它"
case.failed(let reason):
return "封面已生成，但存入系统相册失败（\(reason)，文件名 \(fileName)）——它在本会话附件里，上传时照选文件卡指引从附件中心找它"
}
}
}

/// 相册写入器：只申请 addOnly（只添加、不读用户相册），写入用
/// PHAssetCreationRequest 直接挂 PNG 数据。权限请求会弹一次系统
/// 询问（首次生成封面时）；被拒后系统不再重复弹，本函数照常返回
/// .denied 由步流如实说明，不反复打扰。
enum PhotoLibrarySaver {
static func saveImageData(_ data: Data) async -> PhotoSaveOutcome {
let status = await PHPhotoLibrary.requestAuthorization(for:.addOnly)
guard status == .authorized else { return.denied}
do {
try await PHPhotoLibrary.shared().performChanges {
let request = PHAssetCreationRequest.forAsset()
request.addResource(with:.photo, data: data, options: nil)
}
return.saved
} catch {
return.failed(error.localizedDescription)
}
}
}


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
