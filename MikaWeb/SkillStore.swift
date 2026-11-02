import Foundation

// Skill 体系：指令型 playbook＋渐进披露（ADOPTION-TOP3 第 3 条，2026-11-02）：
// 一个 skill＝Application Support/MikaWeb/Skills/<name>/SKILL.md，文件头是
// YAML frontmatter（name＋description，description 写清「何时用」——它就是触发
// 依据），正文是给模型的经验手册（playbook）。渐进披露：系统提示里只放全部
// skill 的 name+description 清单，模型判断任务对口后用 use_skill 动作点名加载，
// 正文才注入本任务上下文，不常驻烧上下文。SKILL.md 是已成事实标准的格式
// （思路借鉴，存储／解析／注入均为自研实现）；MinisSkills 等外部 skill 的具体
// 内容各有其来源许可，本仓不搬运任何外部 playbook 内容，内置两份均为本项目
// 自有经验沉淀。
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
    /// 与外部导入的 skill 同权同格式；已存在的文件不覆盖，留给用户改的余地）。
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
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for builtin in Self.builtins {
            let folder = directory.appendingPathComponent(builtin.name, isDirectory: true)
            let file = folder.appendingPathComponent("SKILL.md")
            if FileManager.default.fileExists(atPath: file.path) { continue }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? builtin.markdown.write(to: file, atomically: true, encoding: .utf8)
        }
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
        description: 在知乎（zhihu.com）写回答、发表评论或回复评论时加载：框架富文本编辑器的输入与发布判据、回答与评论的入口差异、知乎页面特性。
        ---

        # 知乎编辑器 playbook（回答与评论）

        ## 编辑器性质
        - 知乎的回答／评论编辑器是框架富文本编辑器：文字必须真正进入编辑器内部状态才算数。本 App 的 type 动作已走原生编辑管线并带写后回读校验，按正常流程用 type 写入即可，不要尝试其它注入办法。
        - 若 type 回报「文字没能输入到编辑器」：同一编辑器最多再试一次；仍失败就如实汇报并停下，不要反复重试把步数耗光。

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

        ## 边界
        - 登录、验证码、付费与授权一律按系统安全规则处理（ask_user 或停下等用户手动完成），本 playbook 的任何内容都不覆盖安全规则。
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
