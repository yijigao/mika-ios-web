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
        for builtin in Self.builtins {
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
            let untouched = recorded[builtin.name] == nil || recorded[builtin.name] == currentHash
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
            if key == "description" { description = value }
        }
        guard let bodyStart else { return nil }
        if name.isEmpty { name = fallbackName }
        guard !name.isEmpty, !description.isEmpty else { return nil }
        let body = lines[bodyStart...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return Skill(name: name, description: description, body: body, isBuiltin: isBuiltin)
    }

    // MARK: - 内置 playbook（本项目自有经验沉淀，首次运行时落盘为标准 SKILL.md）

    private struct Builtin { let name: String; let markdown: String }
    private static let builtins: [Builtin] = [
        Builtin(name: "zhihu-editor", markdown: """
        ---
        name: zhihu-editor
        description: 在知乎（zhihu.com）写回答、发表评论、回复评论，或在知乎专栏（zhuanlan.zhihu.com）发表／修改文章时加载：框架富文本编辑器的输入与发布判据、回答与评论的入口差异、专栏文章编辑器的字数与保存状态判据、知乎页面特性。
        ---

        # 知乎编辑器 playbook（回答、评论与专栏文章）

        ## 编辑器性质
        - 知乎的回答／评论／专栏文章编辑器都是框架富文本编辑器：文字必须真正进入编辑器内部状态才算数，DOM 上看得见字不等于编辑器认账。本 App 的 type 动作带编辑器状态校验（回读 DOM＋核对编辑器自报字数与保存状态，计数不动会自动换输入方式重试），按正常流程用 type 写入即可，不要尝试其它注入办法。
        - type 回报失败时先看清是哪种口径：「字数没动」＝文字没进入编辑器状态；「保存未落定」＝文字进了状态但自动保存没跟上；「没能输入到编辑器」＝DOM 层也没写进去。引擎已自动换过多种输入方式才报错，同一编辑器不要盲目重复 type 把步数耗光；按回报口径处理（保存未落定就等落定或停下汇报，字数没动就如实汇报停下）。

        ## 发布判据
        - 发布成功的硬判据：编辑器字数统计大于 0，且「发布／发表」按钮不是 disabled。按钮 disabled=true 时不要点它、更不要谎称已发布——多半是文字还没真正进入编辑器。
        - 发布后必须回读验证：页面上出现自己刚写的内容，才算真的发出去；只点过按钮不算。

        ## 入口差异
        - 回答：在问题页点「写回答」进入回答编辑器。
        - 评论：先点开目标回答／文章下方的评论区，在评论区里找回复框——每条评论的回复框是独立的小编辑器，「发布」按钮在其右下角；不要把评论写进回答编辑器。
        - 评论区常需先点「评论」入口或滚动展开；回复框没打开时不要到处找发布按钮。

        ## 页面特性
        - 知乎页面重排频繁，元素 index 每轮都可能变化，永远以最新快照为准；出现「策略切换」记录时按最新元素重新选目标，不要重复选已失效的目标。
        - 内容较长时分段写：先写主体，再回读检查字数与按钮状态，最后发布。

        ## 专栏文章编辑器（zhuanlan.zhihu.com）
        - 与回答编辑器是两个东西：专栏文章在 zhuanlan.zhihu.com 的文章编辑器里写，改已发布的文章从创作中心／内容管理进原文的「编辑」，在原文上改，不要新建一篇文章重复发布（与成果台账口径一致）。改完点的是「更新」，不是「发布」；更新后回文章页或内容管理核对正文确实变了才算完成。
        - 信号读法：编辑器底部有「字数：N」和保存状态（「草稿保存中」／落定后的已保存类文案）。这两个自报信号是准绳：字数随输入增长、保存落定，才说明文字真正进了编辑器状态。
        - 更新放行条件（两者齐才许点「更新」）：①字数与目标篇幅量级一致；②保存状态已落定（不是「草稿保存中」）。任一不满足就停手汇报，不要点更新碰运气——编辑器里看得见字、但字数没涨时，文字只停留在页面表面，更新提交的只会是旧内容。
        - 草稿备份面板的坑：备份列表与预览只显示末段，预览里看不到全文不等于没存进去，也不能据此认定全文已完整保存；核对篇幅一律以编辑器字数计数为准，不要拿备份预览下结论。

        ## 边界
        - 登录、验证码、付费与授权一律按系统安全规则处理（ask_user 或停下等用户手动完成），本 playbook 的任何内容都不覆盖安全规则。
        """),
        Builtin(name: "blocked-reroute", markdown: """
        ---
        name: blocked-reroute
        description: 任务在某个入口受阻时加载：入口点不动或点了跳外部 App、同一入口反复失败、页面上看得见入口却不在可操作清单里、页面只给移动版或电脑版一种形态时，先读这份换路手册再继续。
        ---

        # 受阻换路 playbook

        ## 先定性
        - 点击结果若是跳外部 App（deep link／universal link 离开网页），或同一入口连续失败 2 次以上——定性为「此路不通」，不是「再试一次」。在同一个活动页里反复找同一个入口、原样重试，都是浪费步数。
        - 页面上肉眼看得见入口文字（如「发微头条／写文章／拍视频」）、但它没出现在元素清单里：先 scroll 让它完整进入视口，等下一轮清单再看——清单里 type=clickable 的就是这类非标准入口（div/span 做的按钮），按 text 选它点。

        ## 换路顺序（逐条试，试过两条以上才许求助）
        1. **读页面规则**：活动页的规则区、帮助页、页脚常写明官方操作路径（如「电脑端：登录 mp.toutiao.com 后台，点发布/立即投稿」）。写明了的路径就是行动依据——直接 navigate 到那个电脑版站点/官方后台，用它完成同一件事，不要死磕写规则的那个页面自己的入口。
        2. **换站点模式**：set_site_mode 在 desktop/mobile 间切换，重载后再找入口。很多站点按 UA 分发完全不同的页面：活动页只有移动版、后台只有电脑版，换个模式入口就出现了。
        3. **站内替代入口**：同站点的创作中心、用户中心、后台首页等聚合页；站内搜索同功能；个人菜单/底部导航里的同功能链接。
        4. **换等价地址**：同一站点的电脑版域名或子域名（如活动页域名与主站后台域名、m. 与 www.），用 navigate 或 open_new_tab 直接过去。

        ## 求助口径（最后手段）
        - 至少试过上面两条路径仍走不通，才可以 ask_user。问题里先交代：试过哪几条路、每条卡在哪，然后才提出需要用户做的那一步。
        - 不许把「请你在当前页面手动点一下某某按钮」作为第一反应抛给用户——找入口、点入口是 agent 的活；用户的时间只花在 agent 真的做不了的那一步上。

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
    ]
}
