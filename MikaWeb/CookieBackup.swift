import Foundation
import WebKit

// 登录 Cookie 备份／回注（ADOPTION-TOP3 第 1 条，2026-11-02）：
// WebKit 的 ITP 会把高流量域名标为 prevalent，无真实用户手势满 30 天后清掉其全部
// 站点数据（含 HttpOnly 登录 Cookie）；agent 驱动的浏览不算手势，于是用户在网页里
// 建立的登录态会**静默集体消失**，且无任何报错、只表现为「突然要重登」。本模块的
// 对策（设计与参数经 OpenMinis CookieBackupStore 的事故复盘验证，本实现为自研）：
//   - 同步节流 60 秒：快照当前 cookie store 的全量 Cookie（name/value/domain/path/
//     expires/secure/httpOnly 完整元数据），按可注册域分文件存本地；
//   - 回注：备份里有、实时 store 里没有、且未过期的条目自动写回（实时优先，备份
//     绝不覆盖实时值）；过期条目剪枝；
//   - 老化：按「最后真实访问」计，域名 30 天未访问则删其备份、不再回注，备份集只
//     跟踪近期真用过的域名；域名总数上限 1000，超出按最久未访问淘汰。
// 存储口径：只存本机 Application Support（completeUntilFirstUserAuthentication
// 文件保护＋排除 iCloud 备份），不进 Keychain、不同步、不进日志——任何路径都不
// 记录 Cookie 值本身；回注发生时只往既有诊断通道记「域名＋恢复条数」。
// 已知限制：经 HTTPCookie 属性重建的 Cookie 无法保留 HttpOnly 标志（WebKit 不
// 提供以编程方式设置该标志的 API），回注的原 HttpOnly Cookie 会变成同源脚本可读；
// 这是「保住登录态」与该系统限制之间的取舍，与所参考设计的一致口径，案卷有记。
@MainActor final class CookieBackup {
    static let shared = CookieBackup()

    /// 两次同步的最小间隔（秒）；进程启动后的第一次调用必同步（恢复离线期被清的）。
    static let syncInterval: TimeInterval = 60
    /// 域名未访问超过此时长（秒）即老化删除，与 ITP 的 30 天窗口同量级。
    static let domainRetention: TimeInterval = 30 * 24 * 3600
    /// 备份域名数上限，超出按最久未访问淘汰。
    static let maxDomains = 1000

    private struct CookieRecord: Codable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var expires: Double? // Unix 秒；nil＝会话 Cookie
        var secure: Bool
        var httpOnly: Bool
        var key: String { "\(domain)|\(path)|\(name)" }
        var isExpired: Bool {
            guard let expires else { return false }
            return expires <= Date().timeIntervalSince1970
        }
    }

    private var lastSyncAt: Date?
    private var syncInFlight = false
    /// 可注册域 → 最后访问时刻（Unix 秒），随每次真实导航更新（内存态，变更时落盘）。
    private var visits: [String: Double] = [:]
    private var visitsLoaded = false

    private var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MikaWeb/CookieBackup", isDirectory: true)
    }
    private var visitsFile: URL { directory.appendingPathComponent("visits.json") }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = directory
        try? dir.setResourceValues(values)
    }

    private func loadVisitsIfNeeded() {
        guard !visitsLoaded else { return }
        visitsLoaded = true
        guard let data = try? Data(contentsOf: visitsFile),
              let decoded = try? JSONDecoder().decode([String: Double].self, from: data) else { return }
        visits = decoded
    }

    private func saveVisits() {
        ensureDirectory()
        guard let data = try? JSONEncoder().encode(visits) else { return }
        try? data.write(to: visitsFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// 记录一次真实导航（用户手动浏览与 agent 导航都算）：刷新该域名的老化时钟。
    func noteVisit(url: URL?) {
        guard let host = url?.host, !host.isEmpty else { return }
        loadVisitsIfNeeded()
        let domain = Self.registrableDomain(of: host)
        let now = Date().timeIntervalSince1970
        if let last = visits[domain], now - last < 3600 { return } // 一小时内不重复落盘
        visits[domain] = now
        saveVisits()
    }

    /// 节流同步入口：60 秒内重复调用直接返回；首次调用必执行。
    func syncIfNeeded(store: WKHTTPCookieStore) async {
        if let lastSyncAt, Date().timeIntervalSince(lastSyncAt) < Self.syncInterval { return }
        await sync(store: store)
    }

    /// 一次完整同步：老化清理 → 回注缺失条目 → 快照现状（实时＋刚回注的）落盘。
    func sync(store: WKHTTPCookieStore) async {
        guard !syncInFlight else { return }
        syncInFlight = true
        defer { syncInFlight = false; lastSyncAt = Date() }
        ensureDirectory()
        loadVisitsIfNeeded()
        let now = Date().timeIntervalSince1970

        // 老化：lastVisit 超过保留期的域名删备份、不再回注（从未记过访问的备份
        // 文件以文件修改时间兜底计龄，避免首版上线前的存量被误判为「刚访问」）。
        pruneAgedDomains(now: now)

        let live: [HTTPCookie] = await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
        var liveByDomain: [String: [HTTPCookie]] = [:]
        var liveKeys: Set<String> = []
        for cookie in live {
            liveByDomain[Self.registrableDomain(of: cookie.domain), default: []].append(cookie)
            liveKeys.insert(Self.record(of: cookie).key)
        }

        // 回注：逐个备份域名比对，缺失且未过期的写回；实时条目优先、绝不覆盖。
        var restoredTotal = 0
        for domain in backedUpDomains() {
            guard let records = loadRecords(domain: domain) else { continue }
            var restoredHere = 0
            for record in records where !record.isExpired && !liveKeys.contains(record.key) {
                if let cookie = Self.httpCookie(from: record) {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        store.setCookie(cookie) { continuation.resume() }
                    }
                    liveKeys.insert(record.key)
                    liveByDomain[domain, default: []].append(cookie)
                    restoredHere += 1
                }
            }
            if restoredHere > 0 {
                restoredTotal += restoredHere
                writeRestoreDiagnostic(domain: domain, count: restoredHere)
            }
        }

        // 快照：以「实时＋刚回注」的并集为最新备份，过期条目剪掉；实时已无任何
        // Cookie 的域名删掉其备份文件（用户清了站点数据时备份不该无限留存——
        // 但注意回注刚发生过的域名其并集非空，不会被误删）。
        let fm = FileManager.default
        for domain in Set(liveByDomain.keys).union(backedUpDomains()) {
            let cookies = (liveByDomain[domain] ?? []).filter { !Self.record(of: $0).isExpired }
            let file = directory.appendingPathComponent("\(domain).json")
            if cookies.isEmpty {
                try? fm.removeItem(at: file)
            } else {
                saveRecords(cookies.map { Self.record(of: $0) }, domain: domain)
            }
        }

        // 容量上限：超出时按最久未访问淘汰（备份域名基本都应有访问记录）。
        let domains = backedUpDomains()
        if domains.count > Self.maxDomains {
            let sorted = domains.sorted { (visits[$0] ?? 0) < (visits[$1] ?? 0) }
            for domain in sorted.prefix(domains.count - Self.maxDomains) {
                try? fm.removeItem(at: directory.appendingPathComponent("\(domain).json"))
            }
        }
        _ = restoredTotal
    }

    // MARK: - 文件存取

    private func backedUpDomains() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasSuffix(".json") && $0 != "visits.json" }.map { String($0.dropLast(5)) }
    }

    private func loadRecords(domain: String) -> [CookieRecord]? {
        let file = directory.appendingPathComponent("\(domain).json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode([CookieRecord].self, from: data)
    }

    private func saveRecords(_ records: [CookieRecord], domain: String) {
        ensureDirectory()
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: directory.appendingPathComponent("\(domain).json"),
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func pruneAgedDomains(now: Double) {
        let fm = FileManager.default
        for domain in backedUpDomains() {
            let lastVisit: Double
            if let recorded = visits[domain] {
                lastVisit = recorded
            } else if let attrs = try? fm.attributesOfItem(atPath: directory.appendingPathComponent("\(domain).json").path),
                      let mtime = attrs[.modificationDate] as? Date {
                lastVisit = mtime.timeIntervalSince1970
            } else {
                lastVisit = now
            }
            if now - lastVisit > Self.domainRetention {
                try? fm.removeItem(at: directory.appendingPathComponent("\(domain).json"))
                visits[domain] = nil
            }
        }
    }

    /// 回注留证：与 WebController 失败快照、AgentEngine 瞬时错误同目录同信封，
    /// 诊断页可见；只记域名与条数，绝不记 Cookie 名／值。
    private func writeRestoreDiagnostic(domain: String, count: Int) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MikaWeb/Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID(), formatter = ISO8601DateFormatter(), now = Date()
        let envelope: [String: Any] = ["schemaVersion": 1, "id": id.uuidString, "receivedAt": formatter.string(from: now),
                                       "types": ["Cookie 回注"],
                                       "payload": ["kind": "cookie-restore", "domain": domain, "restoredCount": count]]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]) else { return }
        let name = formatter.string(from: now).replacingOccurrences(of: ":", with: "-") + "-" + id.uuidString + ".json"
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    // MARK: - 转换与域名归一

    private static func record(of cookie: HTTPCookie) -> CookieRecord {
        CookieRecord(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path,
                     expires: cookie.expiresDate?.timeIntervalSince1970, secure: cookie.isSecure, httpOnly: cookie.isHTTPOnly)
    }

    private static func httpCookie(from record: CookieRecord) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: record.name, .value: record.value, .domain: record.domain, .path: record.path,
        ]
        if let expires = record.expires { properties[.expires] = Date(timeIntervalSince1970: expires) }
        if record.secure { properties[.secure] = "TRUE" }
        return HTTPCookie(properties: properties)
    }

    /// 可注册域归一（自研简化版）：去掉前导点与端口后取末两段；命中常见两级公共
    /// 后缀（com.cn/co.uk 等）时取末三段。仅用于备份分文件与老化归组，不做完整
    /// 公共后缀列表匹配——归组略粗不影响正确性（同一文件的 Cookie 回注时仍按其
    /// 各自原始 domain 写入）。
    static func registrableDomain(of host: String) -> String {
        var name = host.lowercased()
        if name.hasPrefix(".") { name.removeFirst() }
        if let portRange = name.range(of: ":[0-9]+$", options: .regularExpression) { name.removeSubrange(portRange) }
        let labels = name.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return name }
        let twoLevelSuffixes: Set<String> = ["com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
                                             "co.uk", "org.uk", "com.au", "net.au", "co.jp", "co.kr", "com.tw", "com.hk"]
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if twoLevelSuffixes.contains(lastTwo) { return labels.suffix(3).joined(separator: ".") }
        return lastTwo
    }
}
