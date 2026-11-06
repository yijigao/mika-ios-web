import Foundation

// Skill 体系：指令型 playbook＋渐进披露（ADOPTION-TOP3 第 3 条，2026-11-02）：
// 一个 skill＝Application Support/MikaWeb/Skills/<name>/SKILL.md，文件头是
// YAML frontmatter（name＋description，description 写清「何时用」——它就是触发
// 依据），正文是给模型的经验手册（playbook）。渐进披露：系统提示里只放全部
// skill 的 name+description 清单，模型判断任务对口后用 use_skill 动作点名加载，
// 正文才注入本任务上下文，不常驻烧上下文。SKILL.md 是已成事实标准的格式
// （思路借鉴，存储／解析／注入均为自研实现）；MinisSkills 等外部 skill 的具体
// 内容各有其来源许可，本仓不搬运任何外部 playbook 内容，内置各份均为本项目
// 自有经验沉淀（zhihu-editor／form-fill／blocked-reroute）。
// 安全口径（硬性）：playbook 只是提示层的经验，**永远低于代码层安全规则**——
// SafetyPolicy 的付款／授权确认、密码验证码手输等判定不读 playbook、不可被
// playbook 文本覆盖或绕过；系统提示词中同步写明了这一优先级。只做指令型：
// 不引入任何可执行脚本机制（见 ADOPTION-STUDY「明确不抄的」第 6 条）。
final class SkillStore: @unchecked Sendable {
    static let shared = SkillStore()

    struct Skill: Identifiable {
        let name: String
        let version: String
        let description: String
        let body: String
        let isBuiltin: Bool
        var id: String { name }
    }

    private let lock = NSLock()
    private var cached: [Skill] = []
    private var seeded = false

    private var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MikaWeb/Skills", isDirectory: true)
    }

    /// 全部已安装 skill（首次访问时把内置 playbook 落盘到 Skills 目录——落盘后
    /// 与外部导入的 skill 同权同格式。内置文件的后续更新走哈希迁移：内容从未
    /// 被用户改过的才同步覆盖成新版 bundled 文本，改过的不动——否则已装设备
    /// 永远用着旧 playbook，新版经验沉淀到不了真机（ZHIHU-COLUMN-SYNC）。
    var skills: [Skill] {
        lock.lock(); defer { lock.unlock() }
        seedBuiltinsIfNeeded()
        if cached.isEmpty { reloadLocked() }
        return cached
    }

    func skill(named name: String) -> Skill? {
        skills.first { $0.name == name }
    }

    /// 系统提示用的清单段：只含 name+description（渐进披露的第一层），条数与
    /// 单条长度有上限，避免清单本身膨胀。
    func catalogFragment() -> String {
        let list = skills
        guard !list.isEmpty else { return "" }
        let lines = list.prefix(20).map { "- \($0.name)：\(String($0.description.prefix(160)))" }
        return (["可用 playbook（经验手册）清单——任务与某条对口时，先用 use_skill 加载全文再执行，不要凭清单猜正文："] + lines).joined(separator: "\n")
    }

    private func seedBuiltinsIfNeeded() {
        guard !seeded else { return }
        seeded = true
        Self.installBuiltins(in: directory)
    }

    /// 文件级安装/迁移实现；生产启动与自检临时目录调用同一入口。
    private static func installBuiltins(in directory: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // 内置 playbook 版本迁移（ZHIHU-COLUMN-SYNC）：落盘时记录每份内置文本
        // 的内容哈希；再次启动时，磁盘内容与记录一致（或压根没有记录——旧版
        // 落盘的）视为未被用户改过，bundled 有更新就同步覆盖；哈希对不上的
        // 视为用户改过，不动。外部导入／用户自建的 skill 不在此列。
        let hashFile = directory.appendingPathComponent("builtin-hashes.json")
        var recorded: [String: String] = [:]
        if let data = try? Data(contentsOf: hashFile),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) { recorded = decoded }
        var hashesChanged = false
        for builtin in builtins {
            let folder = directory.appendingPathComponent(builtin.name, isDirectory: true)
            let file = folder.appendingPathComponent("SKILL.md")
            let bundledHash = Self.contentHash(builtin.markdown)
            guard fm.fileExists(atPath: file.path) else {
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try? builtin.markdown.write(to: file, atomically: true, encoding: .utf8)
                recorded[builtin.name] = bundledHash; hashesChanged = true
                continue
            }
            let current = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let currentHash = Self.contentHash(current)
            // 无哈希的旧安装只在命中已知旧内置版本时迁移；其它内容视为
            // 用户自行编辑并保留，不能再用“没有记录”推定未修改。
            let untouched = Self.shouldReplaceBuiltin(recordedHash: recorded[builtin.name], currentHash: currentHash,
                                                       bundledHash: bundledHash, legacyHashes: builtin.legacyHashes)
            if untouched && currentHash != bundledHash {
                try? builtin.markdown.write(to: file, atomically: true, encoding: .utf8)
                recorded[builtin.name] = bundledHash; hashesChanged = true
            } else if recorded[builtin.name] == nil {
                recorded[builtin.name] = currentHash; hashesChanged = true
            }
        }
        if hashesChanged, let data = try? JSONEncoder().encode(recorded) {
            try? data.write(to: hashFile, options: .atomic)
        }
    }

    /// FNV-1a 64 位内容指纹（与 LoopDetector／OutcomeLedger 同算法），只判
    /// 「内置 playbook 是否被用户改过」，不需要密码学强度。
    private static func contentHash(_ s: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 { hash ^= UInt64(byte); hash = hash &* 0x100000001b3 }
        return String(hash, radix: 16)
    }

    private static func shouldReplaceBuiltin(recordedHash: String?, currentHash: String,
                                             bundledHash: String, legacyHashes: Set<String>) -> Bool {
        recordedHash == currentHash ||
            (recordedHash == nil && (currentHash == bundledHash || legacyHashes.contains(currentHash)))
    }

    func verifyBuiltinMigrationPolicy() -> [String] {
        let legacy = "6eb36d78775da35", bundled = "new-v4", edited = "user-edited"
        let oldUpgrades = Self.shouldReplaceBuiltin(recordedHash: nil, currentHash: legacy,
                                                     bundledHash: bundled, legacyHashes: [legacy])
        let editedStays = !Self.shouldReplaceBuiltin(recordedHash: nil, currentHash: edited,
                                                      bundledHash: bundled, legacyHashes: [legacy])
        let trackedUpgrades = Self.shouldReplaceBuiltin(recordedHash: legacy, currentHash: legacy,
                                                         bundledHash: bundled, legacyHashes: [legacy])
        let bundledV4 = Self.builtins.first(where: { $0.name == "zhihu-editor" })?.markdown
        let rulesCurrent = bundledV4?.contains("version: 4") == true &&
            bundledV4?.contains("disabled、字数计数") == true &&
            bundledV4?.contains("一次传完整正文") == true
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("mika-skill-migration-\(UUID().uuidString)", isDirectory: true)
        var fileLevel = false
        if let builtin = Self.builtins.first(where: { $0.name == "zhihu-editor" }) {
            let folder = temp.appendingPathComponent(builtin.name, isDirectory: true)
            let file = folder.appendingPathComponent("SKILL.md")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let installedOld = "---\nname: zhihu-editor\nversion: 3\n---\n旧内置规则"
            try? installedOld.write(to: file, atomically: true, encoding: .utf8)
            let hashes = [builtin.name: Self.contentHash(installedOld)]
            if let data = try? JSONEncoder().encode(hashes) { try? data.write(to: temp.appendingPathComponent("builtin-hashes.json"), options: .atomic) }
            Self.installBuiltins(in: temp)
            let migrated = try? String(contentsOf: file, encoding: .utf8)
            let ledger = (try? Data(contentsOf: temp.appendingPathComponent("builtin-hashes.json"))).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
            fileLevel = migrated == builtin.markdown && ledger?[builtin.name] == Self.contentHash(builtin.markdown)
        }
        try? FileManager.default.removeItem(at: temp)
        return [
            "\(oldUpgrades && trackedUpgrades ? "✓" : "✗") 旧内置 zhihu-editor（有/无哈希账）迁移到当前版本",
            "\(editedStays ? "✓" : "✗") 用户自行编辑且无已知内置哈希的手册保持原文件",
            "\(rulesCurrent ? "✓" : "✗") 随包 zhihu-editor v4 使用统一发布规则与完整正文一次 replace",
            "\(fileLevel ? "✓" : "✗") 临时安装目录写入旧手册＋哈希账后，生产文件级迁移入口实际覆盖正文并更新哈希"
        ]
    }

    private func reloadLocked() {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { cached = []; return }
        var loaded: [Skill] = []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let file = folder.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let skill = Self.parse(markdown: text, fallbackName: folder.lastPathComponent,
                                         isBuiltin: Self.builtins.contains(where: { $0.name == folder.lastPathComponent })) else { continue }
            loaded.append(skill)
        }
        cached = loaded
    }

    /// frontmatter 解析（自研，只认本格式用到的子集）：文件以 --- 开头、下一个
    /// --- 行结束，其间逐行 key: value（值可带引号）；正文为其后全文。name 缺失
    /// 时以文件夹名兜底，description 缺失则该 skill 不入清单（触发依据不全）。
    static func parse(markdown: String, fallbackName: String, isBuiltin: Bool) -> Skill? {
        let lines = markdown.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var name = ""
        var version = "1"
        var description = ""
        var bodyStart: Int?
        for i in 1..<lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces) == "---" { bodyStart = i + 1; break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            if key == "name" { name = value }
            if key == "version" { version = value }
            if key == "description" { description = value }
        }
        guard let bodyStart else { return nil }
        if name.isEmpty { name = fallbackName }
        guard !name.isEmpty, !description.isEmpty else { return nil }
        let body = lines[bodyStart...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return Skill(name: name, version: version, description: description, body: body, isBuiltin: isBuiltin)
    }

    // MARK: - 内置 playbook（本项目自有经验沉淀，首次运行时落盘为标准 SKILL.md）

    private struct Builtin {
        let name: String
        let markdown: String
        var legacyHashes: Set<String> = []
    }
    private static let builtins: [Builtin] = [
        Builtin(name: "zhihu-editor", markdown: """
        ---
        name: zhihu-editor
        version: 4
        description: 在知乎（zhihu.com）写回答、发表评论、回复评论，或在知乎专栏（zhuanlan.zhihu.com）发表／修改文章时加载：框架富文本编辑器的输入与发布判据、回答与评论的入口差异、专栏文章编辑器的字数与保存状态判据、知乎页面特性。
        ---

        # 知乎编辑器 playbook（回答、评论与专栏文章）

        ## 编辑器性质
        - 知乎的回答／评论／专栏文章编辑器都是框架富文本编辑器：文字必须真正进入编辑器内部状态才算数，DOM 上看得见字不等于编辑器认账。本 App 的 type 动作带编辑器状态校验（回读 DOM＋核对编辑器自报字数与保存状态，计数不动会自动换输入方式重试），按正常流程用 type 写入即可，不要尝试其它注入办法。
        - type 回报失败时先看清是哪种口径：「字数没动」＝文字没进入编辑器状态；「保存未落定」＝文字进了状态但自动保存没跟上；「没能输入到编辑器」＝DOM 层也没写进去。引擎已自动换过多种输入方式才报错，同一编辑器不要盲目重复 type 把步数耗光；按回报口径处理（保存未落定就等落定或停下汇报，字数没动就如实汇报停下）。
        - 回答正文用一次 type=replace 传入完整正文；长文也不拆成多次 type。正文凭证只取目标 Draft committed 的全文回读，比较仅统一 CRLF/CR 为 LF，标点、数字、大小写、空格与段落都须一致。

        ## 发布判据
        - 当前回答正文经引擎核实且发布条件成立时，执行一次发布尝试。按钮 disabled、字数计数和「Markdown 语法输入中」仅为页面观测，不能单独推翻正文凭证，也不能阻止这次首次尝试。
        - 发布按钮必须与当前回答编辑器有唯一容器归属并对应当前问题；同名多候选或隐藏副本不能靠全页第一个或旧 index 猜。
        - 点击只表示「已尝试」。成功必须独立回读到对应问题的回答 ID/稳定链接、当前账号作者身份、编辑器外完整正文逐段一致；错误提示、审核提示、toast、跳转、编辑器残稿、相同前缀、超时或回读失败都统一为结果未知。结果未知时提示「发布结果未确认，可能已经成功。已暂停同题自动重试，请先检查回答详情。」并保留同题阻断，绝不重放点击。

        ## 入口差异
        - 回答：在问题页点「写回答」进入回答编辑器。
        - 评论：先点开目标回答／文章下方的评论区，在评论区里找回复框——每条评论的回复框是独立的小编辑器，「发布」按钮在其右下角；不要把评论写进回答编辑器。
        - 评论区常需先点「评论」入口或滚动展开；回复框没打开时不要到处找发布按钮。

        ## 页面特性
        - 知乎页面重排频繁，元素 index 每轮都可能变化，永远以最新快照为准；出现「策略切换」记录时按最新元素重新选目标，不要重复选已失效的目标。
        - 内容较长时仍一次传完整正文并按 committed 全文等值核对，不分段追加。

        ## 专栏文章编辑器（zhuanlan.zhihu.com）
        - 与回答编辑器是两个东西：专栏文章在 zhuanlan.zhihu.com 的文章编辑器里写，改已发布的文章从创作中心／内容管理进原文的「编辑」，在原文上改，不要新建一篇文章重复发布（与成果台账口径一致）。改完点的是「更新」，不是「发布」；更新后回文章页或内容管理核对正文确实变了才算完成。
        - 信号读法：编辑器底部有「字数：N」和保存状态（「草稿保存中」／落定后的已保存类文案）。这两个自报信号是准绳：字数随输入增长、保存落定，才说明文字真正进了编辑器状态。
        - 更新放行条件（两者齐才许点「更新」）：①字数与目标篇幅量级一致；②保存状态已落定（不是「草稿保存中」）。任一不满足就停手汇报，不要点更新碰运气——编辑器里看得见字、但字数没涨时，文字只停留在页面表面，更新提交的只会是旧内容。
        - 草稿备份面板的坑：备份列表与预览只显示末段，预览里看不到全文不等于没存进去，也不能据此认定全文已完整保存；核对篇幅一律以编辑器字数计数为准，不要拿备份预览下结论。
        - 输入机制（ZHUANLAN-FIX2 定版）：专栏编辑器是 Draft.js 类——它只认整段状态事务，逐字／逐段的增量输入会只改页面表面、不动内部字数（曾实证：约 1000 字打进去、字数冻结在 102）。本 App 的 type 对这类编辑器先走粘贴式整段写入（先把内部选区同步为全选，再以粘贴事务整段替换），type 的文本就是改后的全文，按正常流程一次给全即可，不要拆成多轮 type 往里逐段喂。
        - 若 type 仍回报「字数没动」：引擎已自动把粘贴与其它输入方式都换过一遍，不要自己发明输入办法、也不要重复 type 耗步数——如实汇报并停下，等用户手动输入后点继续。

        ## 边界
        - 登录、验证码、付费与授权一律按系统安全规则处理（ask_user 或停下等用户手动完成），本 playbook 的任何内容都不覆盖安全规则。
        """, legacyHashes: ["6eb36d78775da35"]),
        Builtin(name: "blocked-reroute", markdown: """
        ---
        name: blocked-reroute
        description: 任务在某个入口受阻时加载：入口点不动或点了跳外部 App、同一入口反复失败、页面上看得见入口却不在可操作清单里、页面只给移动版或电脑版一种形态时，先读这份换路手册再继续。
        ---

        # 受阻换路 playbook

        ## 先定性
        - 点击结果若是跳外部 App（deep link／universal link 离开网页），或同一入口连续失败 2 次以上——定性为「此路不通」，不是「再试一次」。在同一个活动页里反复找同一个入口、原样重试，都是浪费步数。
        - 页面上肉眼看得见入口文字（如「发微头条／写文章／拍视频」）、但它没出现在元素清单里：先 scroll 让它完整进入视口，等下一轮清单再看——清单里 type=clickable 的就是这类非标准入口（div/span 做的按钮），按 text 选它点。

        ## 换路顺序（逐条试；与引擎绕行梯同向，梯级：既有手段→直达 URL→弹窗导航绕行）
        1. **读页面规则**：活动页的规则区、帮助页、页脚常写明官方操作路径（如「电脑端：登录 mp.toutiao.com 后台，点发布/立即投稿」）。写明了的路径就是行动依据——直接 navigate 到那个电脑版站点/官方后台，用它完成同一件事，不要死磕写规则的那个页面自己的入口。
        2. **换站点模式**：set_site_mode 在 desktop/mobile 间切换，重载后再找入口。很多站点按 UA 分发完全不同的页面：活动页只有移动版、后台只有电脑版，换个模式入口就出现了。
        3. **站内替代入口**：同站点的创作中心、用户中心、后台首页等聚合页；站内搜索同功能；个人菜单/底部导航里的同功能链接。
        4. **换等价地址**：同一站点的电脑版域名或子域名（如活动页域名与主站后台域名、m. 与 www.），用 navigate 或 open_new_tab 直接过去。

        ## 求助口径（只许澄清，不许代劳）
        - ask_user 只许用于任务歧义澄清（缺信息、要选择）。能力类卡点（入口点不开、弹窗关不掉）不许用 ask_user 请用户代劳：上面四条换路逐条试；都试过仍走不通时，用 ask_user 如实交代卡点——先写清试过哪几条路、每条卡在哪——引擎会继续走绕行梯（直达 URL、弹窗导航绕行），梯尽按失败结案，不要在问题里写「请你点/请你打开」类的话。
        - 找入口、点入口、关弹窗是 agent 的活（自主完成口径，Joey 2026-11-03 亲令）；用户只在安全类步骤出面（付款/授权确认、密码、验证码、扫码、实名、发表确认）。

        ## 边界
        - 换路不改变安全规则：改道后的页面上遇到付款、购买、授权确认，仍走系统确认流程；密码、验证码仍停下等用户手动输入。遇到「跳 App 是为了支付/登录验证」的入口，按安全规则处理，不算普通换路对象。本 playbook 不覆盖任何安全规则。
        """),
        Builtin(name: "form-fill", markdown: """
        ---
        name: form-fill
        description: 在网页上填写表单并提交时加载：填写顺序、逐项核对、提交成功的判据。
        ---

        # 通用填表 playbook

        - 按页面从上到下的顺序逐项填写；每填一两项，等下一轮快照确认值已经进入字段，再继续下一项。
        - 下拉框、单选、多选不是 type 的目标：先 click 展开，再 click 目标选项。
        - 提交前回读关键字段（邮箱、手机号、日期、金额）与任务给定的值逐一核对；不一致先修正再提交。
        - 提交成功的判据是页面出现成功提示或跳转到结果页；只点过提交按钮不算。若按钮变灰或出现报错提示，如实汇报页面原文，不要反复点提交。
        - 密码、验证码类字段不要填：用 ask_user 或停下等用户手动输入（系统安全规则，本 playbook 不覆盖）。
        """),
        Builtin(name: "wechat-oa-editor", markdown: """
        ---
        name: wechat-oa-editor
        description: 在微信公众号后台（mp.weixin.qq.com）编辑、存草稿或发表文章时加载：AI 配图条款弹窗的处理顺序、封面自产优先路径、草稿与发表的回读判据。
        ---

        # 微信公众号编辑器 playbook

        ## AI 配图条款弹窗：封面不走 AI 配图，这弹窗就不该被触发
        - 封面只走下节的两条既定路径（经正文或经图片库），因此正常流程里根本不需要点开 AI 配图的任何入口。规则先行：不点「AI 配图／AI 生成图／智能配图」等任何 AI 配图入口——点了就必然先撞上这份使用条款弹窗，白白断链。素材库现成图同样不是封面来源（见下节顺序）。
        - 若条款弹窗已经在场（误点入口、或页面自己弹出）：处理顺序固定：①先关弹窗再谈其他——照常 click 弹窗里的「取消」（中性按钮，先脱离再说），引擎会自动升级点按方式、并可能在页面内嵌 frame 里定位弹窗尝试关闭，你不需要做特殊动作；②若点按与框内关闭都过不去，引擎会走弹窗导航绕行（离开再经直达地址返回编辑页，离开前会先保存回读落定），不会停下等用户点按：你不要原样反复 click 同一个按钮、不要改点「同意」绕开问题、不要声称已经取得同意；③绕行回来后，先回读页面现状（正文与封面是否都在）再继续，不要假定后续状态。
        - 弹窗未关之前，不得把「需要同意才能用」的功能当作已可用继续往下走；这篇文章的封面改走下节的两条既定路径，与该弹窗无关。

        ## 封面：自产优先；封面区没有本地上传，走正文或图片库两条路径（2026-11-03 真机实证定版）
        - 封面的主题与文案必须从文章标题与正文主题推导：generate_cover 的 text 就用文章标题（副标题从正文主题里提炼），不得按素材库里图片的文件名猜主题、更不得拿主题对不上的图凑数。现场反例：文章是《用豆包整理会议纪要》，却提议选一张贴合「日常习惯与个人成长」的素材图当封面——主题完全对不上，属于凑数，禁止。
        - 顺序固定：先自产（标题即文案，主题天然对版）→ 自产实在不合用时，先调整标题/版式重新生成一次。素材库现成图不作为封面来源——翻素材库选图既偏题、又容易误入 AI 配图入口触发条款弹窗。
        - **封面区结构实证（2026-11-03 用户真机截图）**：编辑器封面区的「+」点开后，二级菜单只有四项——「从正文选择」「从图片库选择」「微信扫码上传」「一键生成封面」，**没有「本地上传」**。封面控件根本不是文件控件入口：在封面区找本地上传、或对封面控件走 upload_file，都是错路（现场回读永远确认不了，因为页面根本没收文件）。正文工具栏的「图片」插入与图片库自己的上传入口才是标准文件控件入口，upload_file 只在这些入口用。
        - **路径一（首选，经正文）**：①先在正文里用工具栏「图片」插入封面图（照常走 upload_file 供文件、双回读确认图已进正文）；②封面区点「+」→「从正文选择」→在弹窗里选刚插入的那张图（弹窗里只有本文图片，容易对号）→裁剪确认；③回读封面区已显示该图缩略图才算设上；④然后尝试把正文里那张图删掉、保存草稿、回草稿箱重开回读封面是否仍在——在，正文保持干净收工；丢了，就把图留在正文里并如实记录（封面靠正文图存续），不要反复删试。
        - **路径二（备选，经图片库）**：①先去素材/图片库页面，用图片库自己的上传入口把封面图传进图库（upload_file 走该入口）；②回编辑器封面区点「+」→「从图片库选择」→图库默认新在前，选第一张（刚传的那张）→裁剪确认；③回读封面区缩略图。正文保持干净，代价是多一次页面导航、且靠位置对号（传图前先记下图库原第一张是谁，防选错）。
        - **二级菜单的操作口径（先看诊断、再定点法）**：你读不到悬浮二级菜单是常态——菜单可能不出现在你的元素清单里。点击「+」后先看步流里的「浮动层诊断」：若诊断说已感知到菜单项（带文本），就按文本正常定位点选；若诊断说未感知到，按固定布局坐标点：菜单布局是固定结构（以用户截图为准，四项自上而下依次为：从正文选择／从图片库选择／微信扫码上传／一键生成封面），按「+」元素的位置推算菜单第一项的坐标点下去，每点一步后用页面变化回读判成败（弹窗出现＝点中了；页面无变化＝没点中，换下一推算位置，不要原样连点）。不许因为「看不见菜单」就声称无入口或停工。
        - **红线**：「一键生成封面」永不点（同 AI 配图入口口径）；「微信扫码上传」是扫码步，停下等用户本人，不自动走。
        - 设完封面必须回读核对才算设上：封面区出现该图的缩略图（路径一还要加删图后的存续回读）。回读不到就按未证处理：不要声称封面已设好，下一轮回读封面区现状再判断。

        ## 草稿与发表判据
        - 存草稿后要重开或回读草稿核对正文与封面都在，编辑器里当时的状态不算数。
        - 框架编辑器（公众号编辑器同类）以编辑器自报的字数与保存状态为准：字数没涨、一直显示「保存中」，多半是内容还没真正同步进去，如实汇报，不要按已输入的字数声称完成。
        - 发表是对外发布动作：按系统安全规则等用户确认后再点，本 playbook 不覆盖。

        ## 编辑器入口寻找与未保存禁重载（WECHAT-EDITOR-NAV 定版）
        - **未保存禁重载逃生**：只要还在编辑器里、正文没有存草稿并回读成功（回草稿箱核对标题与字数对得上），就禁止用 set_site_mode 或重载/导航离开编辑器页当逃生手段——重载会把未保存的正文丢掉。确实需要重载时，先存草稿→回读确认→在说明里写明已保存，才许重载。
        - **入口寻找顺序写死**（找已存草稿的编辑入口时逐级走，每级只走一遍）：①草稿箱列表里点该条目的标题；②同一条目的其它落点（封面图、时间区等卡片区域）——标题与其它落点各只试一次，不许在同一落点反复点（与循环熔断同口径）；③列表页/编辑器的「选择已有内容」入口，选中该草稿进入；④先 scroll 揭示（含页面内滚动区域滚到底）再看新一轮元素清单，清单里带 inView=false 的条目就是没进视口、不是不存在，直接点即可。四级都走完仍找不到，才许说无入口，且汇报里写明试过哪几级与揭示手段。
        - **发表记录对账**：核对某篇是否已发表，只认双条件同时命中——发表记录里标题与目标标题精确一致，且记录时间落在成果台账提交时刻的 ±10 分钟内。对账全程只读：只看记录页，不点发表、不重发。双条件对不上就如实记「待核查」，不要回编辑器凭残稿下结论、更不要据此重复提交。

        ## 边界
        - 登录、扫码、短信验证码、发表确认都按系统安全规则走（停在那一步等用户），本 playbook 不覆盖任何安全规则；playbook 与系统提示冲突时一律以系统提示为准。
        """),
    ]
}
