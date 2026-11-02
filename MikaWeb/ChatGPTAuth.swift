import Foundation
import SafariServices
import UIKit
import CryptoKit
import Security

/// ChatGPT 订阅登录（Joey 2026-11-02 亲令新增）：用户用自己的 ChatGPT 订阅账号
/// 在 OpenAI 官方授权页完成 OAuth 授权后，App 用订阅额度经 ChatGPT 的 Codex
/// 后端（Responses 形态）调用模型，与既有 API Key 通道并存。
///
/// 协议事实（拆 OpenMinis 的 CodexOAuthManager 只读研究所得，代码全部自研，
/// 详见案卷 CHATGPT-LOGIN-IMPL-2026-11-02.md 研究节）：
/// - 授权端点 https://auth.openai.com/oauth/authorize、令牌端点 …/oauth/token；
/// - client_id 是 OpenAI 官方 Codex CLI 的公开 OAuth 客户端标识（公开客户端，
///   无 secret，PKCE S256），不是任何第三方的专属凭据，流程不经过任何中转服务，
///   本机直连 auth.openai.com；业界第三方客户端（OpenMinis、opencode 等）同此做法；
/// - redirect_uri 为本机回环 http://localhost:1455/auth/callback，因此回调必须
///   由本机回环监听接收（ASWebAuthenticationSession 的回调只支持自定义 scheme
///   与 universal link，接不了 http 回环），呈现层用 SFSafariViewController；
/// - 登录后调用端点 https://chatgpt.com/backend-api/codex/responses，模型目录
///   GET https://chatgpt.com/backend-api/codex/models?client_version=…。
///
/// 安全口径：App 不接触账号密码（授权在官方页面由用户本人完成）；access /
/// refresh / id token 整体只存本机 Keychain，绝不进日志、截图、仓库；token
/// 值不写 DiagnosticStore。退出登录即删 Keychain 记录。

struct ChatGPTTokenStorage: Codable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var expireDate: Date?
    var accountId: String?
    var planType: String?
    var email: String?
}

/// token 存储专用 Keychain（与 API Key 的条目分开，互不影响）。
private enum ChatGPTKeychain {
    static let service = "com.jigaoyi.mikaweb.chatgpt"
    static let account = "oauth-token"
    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    static func load() -> ChatGPTTokenStorage? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(ChatGPTTokenStorage.self, from: data)
    }
    static func save(_ storage: ChatGPTTokenStorage) {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
    static func clear() { SecItemDelete(query as CFDictionary) }
}

/// 本机回环回调监听：原始 POSIX socket 只绑定 127.0.0.1:1455（回环不属于
/// 「本地网络」隐私范围，不触发局域网权限弹窗，也不对外网开放）。自研实现：
/// accept 一条连接、解析请求行里的查询参数、回一个「可以回到 App」的简短页面。
final class LoopbackCallbackServer: @unchecked Sendable {
    struct Callback {
        let code: String?
        let state: String?
        let error: String?
    }
    enum ServerError: LocalizedError {
        case bindFailed
        case timeout
        case stopped
        var errorDescription: String? {
            switch self {
            case .bindFailed: return "本机回调端口被占用，无法完成登录"
            case .timeout: return "等待登录授权超时，请重试"
            case .stopped: return "登录已取消"
            }
        }
    }
    private let port: UInt16
    private let path: String
    private var listenFD: Int32 = -1
    private let stateLock = NSLock()
    private var continuation: CheckedContinuation<Callback, Error>?
    private var finished = false
    private var timeoutItem: DispatchWorkItem?
    private let workerQueue = DispatchQueue(label: "mikaweb.oauth.loopback")

    init(port: UInt16, path: String) {
        self.port = port
        self.path = path
    }

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.bindFailed }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw ServerError.bindFailed
        }
        listenFD = fd
        workerQueue.async { [weak self] in self?.acceptLoop() }
    }

    func waitForCallback(timeout: TimeInterval) async throws -> Callback {
        try await withCheckedThrowingContinuation { cont in
            stateLock.lock()
            if finished {
                stateLock.unlock()
                cont.resume(throwing: ServerError.stopped)
                return
            }
            continuation = cont
            stateLock.unlock()
            let item = DispatchWorkItem { [weak self] in
                self?.finish(.failure(ServerError.timeout))
            }
            timeoutItem = item
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
        }
    }

    func stop() { finish(.failure(ServerError.stopped)) }

    private func finish(_ result: Result<Callback, Error>) {
        stateLock.lock()
        if finished {
            stateLock.unlock()
            return
        }
        finished = true
        let cont = continuation
        continuation = nil
        let fd = listenFD
        listenFD = -1
        stateLock.unlock()
        timeoutItem?.cancel()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        cont?.resume(with: result)
    }

    private func acceptLoop() {
        while true {
            stateLock.lock()
            let fd = listenFD
            let done = finished
            stateLock.unlock()
            if done || fd < 0 { return }
            var clientAddr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(fd, &clientAddr, &len)
            if client < 0 { return } // 监听已关或出错，退出
            handle(client)
            stateLock.lock()
            let isFinished = finished
            stateLock.unlock()
            if isFinished { return }
        }
    }

    private func handle(_ client: Int32) {
        defer { close(client) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        // 只读到请求头结束或上限为止（回调请求很小）
        while buffer.count < 32768 {
            let n = recv(client, &chunk, chunk.count, 0)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.range(of: Data([13, 10, 13, 10])) != nil { break }
        }
        guard let head = String(data: buffer, encoding: .utf8),
              let firstLine = head.split(separator: "\r\n").first else { return }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        let target = String(parts[1])
        guard let components = URLComponents(string: "http://localhost" + target) else { return }
        guard components.path == path else {
            respond(client, status: "404 Not Found", body: "not found")
            return
        }
        let items = components.queryItems ?? []
        let callback = Callback(
            code: items.first(where: { $0.name == "code" })?.value,
            state: items.first(where: { $0.name == "state" })?.value,
            error: items.first(where: { $0.name == "error" })?.value)
        respond(client, status: "200 OK",
                body: "<html><head><meta charset=\"utf-8\"></head><body style=\"font-family:-apple-system;text-align:center;padding-top:80px\"><h2>登录处理中</h2><p>可以回到 Mika Web 了。</p></body></html>")
        finish(.success(callback))
    }

    private func respond(_ client: Int32, status: String, body: String) {
        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(bodyData)
        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = send(client, base, payload.count, 0)
        }
    }
}

@MainActor
final class ChatGPTAuth: ObservableObject {
    // MARK: 协议常量（来源见文件头注释与案卷研究节）
    private static let authorizeEndpoint = "https://auth.openai.com/oauth/authorize"
    private static let tokenEndpoint = "https://auth.openai.com/oauth/token"
    /// OpenAI 官方 Codex CLI 的公开 OAuth 客户端标识（公开客户端，无 secret）。
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let callbackPort: UInt16 = 1455
    private static let callbackPath = "/auth/callback"
    private static var redirectURI: String { "http://localhost:\(callbackPort)\(callbackPath)" }
    private static let scopes = "openid profile email offline_access"
    /// 与 Codex 客户端版本对齐的兼容版本号（仅作版本参数，非凭据）。
    static let clientVersion = "0.159.0"
    static let backendResponsesURL = "https://chatgpt.com/backend-api/codex/responses"
    private static let refreshLead: TimeInterval = 5 * 60

    @Published private(set) var isLoggedIn: Bool
    @Published private(set) var accountEmail: String?
    @Published private(set) var planType: String?
    @Published private(set) var isAuthenticating = false

    private var callbackServer: LoopbackCallbackServer?
    private weak var safariVC: SFSafariViewController?
    private var refreshTask: Task<ChatGPTTokenStorage, Error>?

    init() {
        let stored = ChatGPTKeychain.load()
        isLoggedIn = stored != nil
        accountEmail = stored?.email
        planType = stored?.planType
    }

    // MARK: 登录 / 退出

    /// 拉起官方授权页完成登录。用户在 OpenAI 页面本人完成授权；App 只接收回环
    /// 回调里的授权码并换取 token，全程不接触账号密码。
    func login() async throws {
        guard !isAuthenticating else { throw MikaError("登录正在进行中") }
        callbackServer?.stop()
        callbackServer = nil
        isAuthenticating = true
        defer {
            isAuthenticating = false
            callbackServer?.stop()
            callbackServer = nil
            safariVC?.dismiss(animated: true)
            safariVC = nil
        }
        let (verifier, challenge) = Self.makePKCE()
        let state = Self.randomToken(byteCount: 32)
        let server = LoopbackCallbackServer(port: Self.callbackPort, path: Self.callbackPath)
        callbackServer = server
        do { try server.start() } catch { throw MikaError("登录启动失败：\(error.localizedDescription)") }

        var components = URLComponents(string: Self.authorizeEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: "codex_cli_rs"),
        ]
        guard let authorizeURL = components?.url else { throw MikaError("登录启动失败：授权地址构造失败") }
        presentSafari(authorizeURL)
        let callback = try await server.waitForCallback(timeout: 300)
        if let oauthError = callback.error {
            throw MikaError("OpenAI 授权未完成（\(oauthError)），请重试登录")
        }
        guard callback.state == state else { throw MikaError("登录校验失败（state 不一致），请重试") }
        guard let code = callback.code, !code.isEmpty else { throw MikaError("OpenAI 未返回授权码，请重试登录") }
        let storage = try await postToken(body: [
            "grant_type": "authorization_code",
            "client_id": Self.clientID,
            "code": code,
            "redirect_uri": Self.redirectURI,
            "code_verifier": verifier,
        ], context: "登录")
        ChatGPTKeychain.save(storage)
        applyLoginState(storage)
    }

    func logout() {
        ChatGPTKeychain.clear()
        isLoggedIn = false
        accountEmail = nil
        planType = nil
    }

    // MARK: token 使用与刷新

    /// 返回可用 access token（必要时先刷新）与账号 id。刷新失败分流：
    /// refresh token 已失效 → 清除登录态并提示重新登录；网络问题 → 按
    /// 「无法连接模型服务」口径抛出（与引擎瞬时错误分类的既有前缀一致）。
    func validAccessToken() async throws -> (token: String, accountId: String?) {
        guard var storage = ChatGPTKeychain.load() else {
            throw MikaError("尚未登录 ChatGPT 订阅：请在设置页点「用 ChatGPT 登录」")
        }
        let expiring = storage.expireDate.map { $0.timeIntervalSinceNow <= Self.refreshLead } ?? false
        if expiring, storage.refreshToken != nil {
            storage = try await refreshGuarded(current: storage)
        }
        guard !storage.accessToken.isEmpty else {
            throw MikaError("ChatGPT 登录已失效，请在设置页重新登录")
        }
        return (storage.accessToken, storage.accountId)
    }

    private func refreshGuarded(current: ChatGPTTokenStorage) async throws -> ChatGPTTokenStorage {
        if let existing = refreshTask {
            return try await existing.value
        }
        let staleRefresh = current.refreshToken ?? ""
        let task = Task { [self] in
            var refreshed = try await postToken(body: [
                "grant_type": "refresh_token",
                "client_id": Self.clientID,
                "refresh_token": staleRefresh,
                "scope": Self.scopes,
            ], context: "刷新登录")
            // 服务端并非每次都轮换 refresh token；没给新的就保留旧的
            if refreshed.refreshToken == nil { refreshed.refreshToken = staleRefresh }
            // 刷新响应可能不带账号信息时保留旧值，避免登录态信息丢失
            if refreshed.accountId == nil { refreshed.accountId = current.accountId }
            if refreshed.planType == nil { refreshed.planType = current.planType }
            if refreshed.email == nil { refreshed.email = current.email }
            ChatGPTKeychain.save(refreshed)
            return refreshed
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let refreshed = try await task.value
            applyLoginState(refreshed)
            return refreshed
        } catch let error as ChatGPTTokenError where error.isInvalidGrant {
            // refresh token 已被服务端作废：清掉本地登录态，明确引导重新登录
            ChatGPTKeychain.clear()
            isLoggedIn = false
            accountEmail = nil
            planType = nil
            throw MikaError("ChatGPT 登录已失效（授权被撤销或过期），请在设置页重新登录")
        } catch let error as ChatGPTTokenError {
            throw MikaError("无法连接模型服务：刷新 ChatGPT 登录时服务返回 HTTP \(error.status)，请稍后重试")
        }
    }

    // MARK: 模型目录

    /// 向 Codex 后端查询当前账号实际可用的模型目录（登录后实测为准）。
    func discoverModels() async throws -> [String] {
        let (token, accountId) = try await validAccessToken()
        guard let url = URL(string: "https://chatgpt.com/backend-api/codex/models?client_version=\(Self.clientVersion)") else {
            throw MikaError("模型目录地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "Originator")
        request.setValue("codex_cli_rs/\(Self.clientVersion) (iOS; arm64)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountId { request.setValue(accountId, forHTTPHeaderField: "Chatgpt-Account-Id") }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch let error as URLError { throw MikaError("无法连接模型服务：\(error.localizedDescription)") }
        guard let http = response as? HTTPURLResponse else { throw MikaError("模型目录未返回 HTTP 响应") }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw MikaError("ChatGPT 登录已失效或无权限读取模型目录（HTTP \(http.statusCode)），请重新登录")
            }
            throw MikaError("读取模型目录失败（HTTP \(http.statusCode)），可直接在下方手动填写模型名")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["models"] as? [[String: Any]] else {
            throw MikaError("模型目录格式异常，可直接在下方手动填写模型名")
        }
        let models = items.compactMap { item -> String? in
            if let visibility = item["visibility"] as? String, visibility == "hide" { return nil }
            return (item["slug"] as? String) ?? (item["id"] as? String)
        }
        guard !models.isEmpty else { throw MikaError("账号模型目录为空，可直接在下方手动填写模型名") }
        return models
    }

    // MARK: 内部

    private func applyLoginState(_ storage: ChatGPTTokenStorage) {
        isLoggedIn = true
        accountEmail = storage.email
        planType = storage.planType
    }

    private struct ChatGPTTokenError: Error {
        let status: Int
        let serverCode: String?
        var isInvalidGrant: Bool {
            status == 400 || status == 401
        }
    }

    private func postToken(body: [String: String], context: String) async throws -> ChatGPTTokenStorage {
        guard let url = URL(string: Self.tokenEndpoint) else { throw MikaError("登录服务地址无效") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch let error as URLError { throw MikaError("无法连接模型服务：\(context)时网络出错（\(error.localizedDescription)）") }
        guard let http = response as? HTTPURLResponse else { throw MikaError("\(context)失败：服务未返回 HTTP 响应") }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200...299).contains(http.statusCode) else {
            let serverCode = (object?["error"] as? [String: Any])?["code"] as? String
                ?? object?["error"] as? String
            if context == "刷新登录" {
                throw ChatGPTTokenError(status: http.statusCode, serverCode: serverCode)
            }
            throw MikaError("\(context)失败（HTTP \(http.statusCode)），请重试登录")
        }
        guard let object, let accessToken = object["access_token"] as? String, !accessToken.isEmpty else {
            throw MikaError("\(context)失败：服务没有返回 access token，请重试")
        }
        var storage = ChatGPTTokenStorage(
            accessToken: accessToken,
            refreshToken: object["refresh_token"] as? String,
            idToken: object["id_token"] as? String,
            expireDate: (object["expires_in"] as? TimeInterval).map { Date().addingTimeInterval($0) },
            accountId: nil, planType: nil, email: nil)
        if let idToken = storage.idToken, let claims = Self.decodeJWTPayload(idToken) {
            storage.accountId = claims["chatgpt_account_id"] as? String
            storage.planType = claims["chatgpt_plan_type"] as? String
            if let email = claims["email"] as? String {
                storage.email = email
            } else if let profile = claims["https://api.openai.com/profile"] as? [String: Any] {
                storage.email = profile["email"] as? String
            }
        }
        return storage
    }

    /// 只解码 JWT 载荷取账号信息（不做签名验证——token 由本机刚从官方令牌端点
    /// 经 TLS 直接换得，此处仅读取展示/路由用的声明）。
    static func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func makePKCE() -> (verifier: String, challenge: String) {
        let verifier = randomToken(byteCount: 64)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64URLEncoded
        return (verifier, challenge)
    }

    private static func randomToken(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }

    private func presentSafari(_ url: URL) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let vc = SFSafariViewController(url: url)
        safariVC = vc
        top.present(vc, animated: true)
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
