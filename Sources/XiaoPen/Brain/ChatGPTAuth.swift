import Foundation
import AppKit
import CryptoKit
import Network
import Observation
import Security
import OSLog

/// "Sign in with ChatGPT" for open-source, locally run apps: OAuth authorization
/// code + PKCE through a loopback redirect, dynamic client registration, and
/// requests billed to the user's ChatGPT plan. No API key or client secret.
/// https://developers.openai.com/siwc/token-sharing-open-source/sign-in
@Observable
@MainActor
public final class ChatGPTAuth {
    public static let shared = ChatGPTAuth()

    public enum Status: Equatable {
        case signedOut
        case signingIn
        case signedIn(email: String?)
        case failed(String)
    }

    public private(set) var status: Status = .signedOut
    public private(set) var models: [String] = []
    /// Why the model list could not be loaded, shown next to a manual model field.
    public private(set) var modelsError: String?

    struct Credentials: Codable, Equatable {
        var clientID: String
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var scope: String
        var subject: String
        var email: String?
    }

    nonisolated static let issuer = "https://auth.openai.com"
    nonisolated static let authorizeURL = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    nonisolated static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    nonisolated static let revokeURL = URL(string: "https://auth.openai.com/api/accounts/oauth/revoke")!
    nonisolated static let jwksURL = URL(string: "https://auth.openai.com/.well-known/jwks.json")!
    nonisolated static let resource = "https://api.openai.com/v1"
    nonisolated static let planScope = "chatgpt.tokens.use.direct"
    nonisolated static let scopes = "openid profile email offline_access resource.invoke \(planScope)"
    private static let keychainAccount = "chatgpt_credentials"

    @ObservationIgnored private var credentials: Credentials?
    @ObservationIgnored private var refreshTask: Task<Credentials, Error>?
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "com.jiaqianjing.XiaoPen", category: "chatgpt-auth")

    private init() {}

    /// Loads saved credentials without prompting; call once at launch or when the entry is shown.
    public func restore() async {
        guard credentials == nil, case .signedOut = status else { return }
        guard let text = try? await KeychainHelper.readKeyAsync(key: Self.keychainAccount),
              let data = text.data(using: .utf8),
              let saved = try? JSONDecoder().decode(Credentials.self, from: data) else { return }
        credentials = saved
        status = .signedIn(email: saved.email)
    }

    /// Stable, opaque per-installation identifier required by dynamic registration.
    /// Accepted forms are `urn:uuid:`, a JWK thumbprint URI, or `did:key:`; a UUIDv4 URI is used here.
    private var hostID: String {
        let key = "chatgptHostID"
        if let saved = UserDefaults.standard.string(forKey: key), Self.isValidHostID(saved) { return saved }
        let value = "urn:uuid:" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    nonisolated static func isValidHostID(_ value: String) -> Bool {
        if value.hasPrefix("urn:uuid:") { return UUID(uuidString: String(value.dropFirst(9))) != nil }
        return value.hasPrefix("urn:ietf:params:oauth:jwk-thumbprint:") || value.hasPrefix("did:key:")
    }

    /// The client ID issued at first sign-in is reused for later sign-ins.
    private var savedClientID: String? {
        get { UserDefaults.standard.string(forKey: "chatgptClientID") }
        set { UserDefaults.standard.set(newValue, forKey: "chatgptClientID") }
    }

    // MARK: - Sign in

    public func signIn() {
        guard signInTask == nil else { return }
        status = .signingIn
        signInTask = Task { [weak self] in
            guard let self else { return }
            defer { self.signInTask = nil }
            do {
                let credentials = try await self.performSignIn()
                try self.save(credentials)
                self.credentials = credentials
                self.status = .signedIn(email: credentials.email)
                self.logger.notice("ChatGPT 登录成功")
                await self.loadModels()
            } catch is CancellationError {
                self.status = .signedOut
            } catch {
                self.logger.error("ChatGPT 登录失败：\(error.localizedDescription, privacy: .public)")
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    public func cancelSignIn() {
        signInTask?.cancel()
    }

    private func performSignIn() async throws -> Credentials {
        let verifier = Self.randomURLSafe(32)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafe(24)
        let nonce = Self.randomURLSafe(24)
        let server = LoopbackCallbackServer()
        let port = try await server.start(preferredPorts: Array(1455...1465))
        defer { server.stop() }
        let redirectURI = "http://127.0.0.1:\(port)/auth/callback"

        var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
        var query = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: savedClientID ?? "dynamic_agent_client"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "resource", value: Self.resource),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        // The same host ID is sent on every sign-in; the name hint only on first registration.
        query.append(URLQueryItem(name: "ext_agent_host_id", value: hostID))
        if savedClientID == nil {
            query.append(URLQueryItem(name: "agent_name_hint", value: "XiaoPen"))
        }
        components.queryItems = query
        NSWorkspace.shared.open(components.url!)

        let callback = try await withTaskCancellationHandler {
            try await server.waitForCallback(timeout: 300)
        } onCancel: {
            server.stop()
        }
        if let error = callback["error"] {
            throw AuthError.message("登录被拒绝：\(callback["error_description"] ?? error)")
        }
        guard callback["state"] == state, let code = callback["code"] else {
            throw AuthError.message("登录回调无效，请重试。")
        }
        let clientID = callback["client_id"] ?? savedClientID ?? "dynamic_agent_client"
        if clientID != "dynamic_agent_client" { savedClientID = clientID }

        let json = try await Self.postForm(Self.tokenURL, [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
            "client_id": clientID, "code_verifier": verifier, "resource": Self.resource,
        ])
        return try await Self.credentials(from: json, clientID: clientID, nonce: nonce, previous: nil)
    }

    // MARK: - Tokens

    /// A valid access token, refreshed shortly before expiry. Refreshes are serialized
    /// because each one rotates the refresh token.
    public func accessToken() async throws -> String {
        if credentials == nil { await restore() }
        guard let current = credentials else { throw AuthError.message("还没有用 ChatGPT 登录。请在设置 → 大脑中登录。") }
        if current.expiresAt.timeIntervalSinceNow > 300 { return current.accessToken }
        if let refreshTask { return try await refreshTask.value.accessToken }
        let task = Task { () throws -> Credentials in
            let json = try await Self.postForm(Self.tokenURL, [
                "grant_type": "refresh_token", "client_id": current.clientID,
                "refresh_token": current.refreshToken, "resource": Self.resource,
            ])
            return try await Self.credentials(from: json, clientID: current.clientID, nonce: nil, previous: current)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let renewed = try await task.value
            try save(renewed)
            credentials = renewed
            return renewed.accessToken
        } catch AuthError.terminal(let message) {
            // invalid_grant / token_expired: the refresh token is unusable; sign in again.
            clearLocal()
            status = .failed(message)
            throw AuthError.message(message)
        }
    }

    public func signOut() {
        let current = credentials
        clearLocal()
        status = .signedOut
        guard let current else { return }
        Task {
            _ = try? await Self.postForm(Self.revokeURL, [
                "token": current.refreshToken, "token_type_hint": "refresh_token", "client_id": current.clientID,
            ], allowEmpty: true)
        }
    }

    /// Model IDs the signed-in account may use (`visibility: "list"`).
    public func loadModels() async {
        let token: String
        do {
            token = try await accessToken()
        } catch {
            modelsError = error.localizedDescription
            return
        }
        var request = URLRequest(url: URL(string: "\(Self.resource)/models")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard status == 200, let json, let ids = Self.modelIDs(in: json) else {
                let detail = (json?["error"] as? [String: Any]).map { "\($0["code"] as? String ?? "") \($0["message"] as? String ?? "")" }
                    ?? String(decoding: data.prefix(200), as: UTF8.self)
                logger.error("ChatGPT 模型列表读取失败：status=\(status), detail=\(detail, privacy: .public)")
                modelsError = "读取模型列表失败（HTTP \(status)）\(detail.isEmpty ? "" : "：\(detail)")"
                return
            }
            models = ids
            modelsError = models.isEmpty ? "账号下没有可用的模型。" : nil
            logger.notice("ChatGPT 模型列表：count=\(self.models.count), models=\(self.models.prefix(12).joined(separator: ","), privacy: .public)")
        } catch {
            logger.error("ChatGPT 模型列表请求失败：\(error.localizedDescription, privacy: .public)")
            modelsError = "读取模型列表失败：\(error.localizedDescription)"
        }
    }

    /// Model IDs from either list shape: the API's `{"data":[{"id"}]}` or the plan
    /// catalog's `{"models":[{"slug"}]}`. Entries marked hidden are skipped unless
    /// that would hide every model.
    nonisolated static func modelIDs(in json: [String: Any]) -> [String]? {
        let entries: [[String: Any]]
        let idKey: String
        if let data = json["data"] as? [[String: Any]] {
            (entries, idKey) = (data, "id")
        } else if let models = json["models"] as? [[String: Any]] {
            (entries, idKey) = (models, "slug")
        } else {
            return nil
        }
        let all = entries.compactMap { ($0[idKey] as? String) ?? ($0["id"] as? String) }
        let listed = entries.filter { ($0["visibility"] as? String ?? "list") == "list" }
            .compactMap { ($0[idKey] as? String) ?? ($0["id"] as? String) }
        return listed.isEmpty ? all : listed
    }

    private func save(_ credentials: Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        try KeychainHelper.save(key: Self.keychainAccount, data: String(decoding: data, as: UTF8.self))
    }

    private func clearLocal() {
        credentials = nil
        models = []
        try? KeychainHelper.delete(key: Self.keychainAccount)
    }

    // MARK: - Token responses

    enum AuthError: LocalizedError {
        case message(String)
        case terminal(String)
        var errorDescription: String? {
            switch self {
            case .message(let text), .terminal(let text): return text
            }
        }
    }

    nonisolated private static func credentials(from json: [String: Any], clientID: String, nonce: String?,
                                    previous: Credentials?) async throws -> Credentials {
        guard let accessToken = json["access_token"] as? String else {
            throw AuthError.message("登录服务没有返回访问令牌。")
        }
        let scope = json["scope"] as? String ?? previous?.scope ?? ""
        guard scope.split(separator: " ").contains(Substring(planScope)) else {
            throw AuthError.message("没有获得使用 ChatGPT 订阅额度的授权，请重新登录并同意授权。")
        }
        var subject = previous?.subject ?? ""
        var email = previous?.email
        if let idToken = json["id_token"] as? String {
            let claims = try await IDTokenVerifier.verify(idToken, clientID: clientID, nonce: nonce)
            subject = claims["sub"] as? String ?? subject
            email = claims["email"] as? String ?? email
        }
        guard !subject.isEmpty else { throw AuthError.message("登录服务没有返回有效的身份令牌。") }
        let expiresIn = json["expires_in"] as? Double ?? 3600
        return Credentials(clientID: clientID, accessToken: accessToken,
                           refreshToken: json["refresh_token"] as? String ?? previous?.refreshToken ?? "",
                           expiresAt: Date().addingTimeInterval(expiresIn), scope: scope,
                           subject: subject, email: email)
    }

    nonisolated private static func postForm(_ url: URL, _ fields: [String: String], allowEmpty: Bool = false) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if (200...299).contains(status) {
            if json.isEmpty && !allowEmpty { throw AuthError.message("登录服务返回了无法解析的数据。") }
            return json
        }
        let code = json["error"] as? String ?? "HTTP \(status)"
        let description = json["error_description"] as? String ?? ""
        if code == "invalid_grant" || code == "token_expired" {
            throw AuthError.terminal("ChatGPT 登录已失效，请重新登录。")
        }
        throw AuthError.message("ChatGPT 登录服务出错：\(code) \(description)")
    }

    // MARK: - Helpers

    nonisolated static func randomURLSafe(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }

    nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Verifies an RS256 ID token against OpenAI's published JWKS and checks iss, aud, exp and nonce.
enum IDTokenVerifier {
    static func verify(_ token: String, clientID: String, nonce: String?, jwks injected: Data? = nil) async throws -> [String: Any] {
        let parts = token.split(separator: ".").map(String.init)
        guard parts.count == 3,
              let headerData = decodeBase64URL(parts[0]), let payloadData = decodeBase64URL(parts[1]),
              let signature = decodeBase64URL(parts[2]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              header["alg"] as? String == "RS256" else {
            throw ChatGPTAuth.AuthError.message("身份令牌格式无效。")
        }
        let jwksData: Data
        if let injected { jwksData = injected } else { (jwksData, _) = try await URLSession.shared.data(from: ChatGPTAuth.jwksURL) }
        guard let jwks = try? JSONSerialization.jsonObject(with: jwksData) as? [String: Any],
              let keys = jwks["keys"] as? [[String: Any]],
              let jwk = keys.first(where: { $0["kid"] as? String == header["kid"] as? String }) ?? keys.first,
              let modulus = (jwk["n"] as? String).flatMap(decodeBase64URL),
              let exponent = (jwk["e"] as? String).flatMap(decodeBase64URL),
              let key = rsaPublicKey(modulus: modulus, exponent: exponent) else {
            throw ChatGPTAuth.AuthError.message("无法获取身份令牌的签名公钥。")
        }
        let signed = Data("\(parts[0]).\(parts[1])".utf8)
        guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, signature as CFData, nil) else {
            throw ChatGPTAuth.AuthError.message("身份令牌签名校验失败。")
        }
        let audience = claims["aud"]
        let audienceMatches = (audience as? String) == clientID || (audience as? [String])?.contains(clientID) == true
        guard claims["iss"] as? String == ChatGPTAuth.issuer, audienceMatches,
              let exp = claims["exp"] as? Double, exp > Date().timeIntervalSince1970 - 60 else {
            throw ChatGPTAuth.AuthError.message("身份令牌校验失败（签发方、受众或有效期不符）。")
        }
        if let nonce, claims["nonce"] as? String != nonce {
            throw ChatGPTAuth.AuthError.message("身份令牌校验失败（nonce 不符）。")
        }
        return claims
    }

    static func decodeBase64URL(_ value: String) -> Data? {
        var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        return Data(base64Encoded: text)
    }

    /// PKCS#1 RSAPublicKey DER: SEQUENCE { INTEGER n, INTEGER e }.
    static func rsaPublicKey(modulus: Data, exponent: Data) -> SecKey? {
        func integer(_ bytes: Data) -> Data {
            var value = Data(bytes.drop(while: { $0 == 0 }))
            if let first = value.first, first & 0x80 != 0 { value.insert(0, at: 0) }
            return Data([0x02]) + length(value.count) + value
        }
        func length(_ count: Int) -> Data {
            if count < 0x80 { return Data([UInt8(count)]) }
            var bytes = withUnsafeBytes(of: UInt32(count).bigEndian, Array.init).drop(while: { $0 == 0 })
            bytes.insert(0x80 | UInt8(bytes.count), at: bytes.startIndex)
            return Data(bytes)
        }
        let body = integer(modulus) + integer(exponent)
        let der = Data([0x30]) + length(body.count) + body
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                         kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
    }
}

/// Minimal one-shot HTTP server on 127.0.0.1 for the OAuth redirect.
final class LoopbackCallbackServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.jiaqianjing.XiaoPen.oauth-callback")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var pendingResult: Result<[String: String], Error>?

    func start(preferredPorts: [Int]) async throws -> Int {
        for port in preferredPorts {
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { continue }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
            parameters.allowLocalEndpointReuse = true
            guard let listener = try? NWListener(using: parameters) else { continue }
            if try await ready(listener) {
                self.listener = listener
                return port
            }
        }
        throw ChatGPTAuth.AuthError.message("无法在本机开启登录回调端口（1455–1465 都被占用）。")
    }

    private func ready(_ listener: NWListener) async throws -> Bool {
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        return await withCheckedContinuation { continuation in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.set() { continuation.resume(returning: true) }
                case .failed, .cancelled:
                    listener.cancel()
                    if once.set() { continuation.resume(returning: false) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if let pendingResult {
                    continuation.resume(with: pendingResult)
                } else {
                    self.continuation = continuation
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(ChatGPTAuth.AuthError.message("登录超时，请重试。")))
            }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<[String: String], Error>) {
        let waiting: CheckedContinuation<[String: String], Error>? = lock.withLock {
            if continuation == nil, pendingResult == nil { pendingResult = result }
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let line = request.split(separator: "\r\n").first else {
                connection.cancel()
                return
            }
            let parts = line.split(separator: " ")
            guard parts.count >= 2, let components = URLComponents(string: String(parts[1])),
                  components.path == "/auth/callback" else {
                self.respond(connection, status: "404 Not Found", body: "Not found")
                return
            }
            var values: [String: String] = [:]
            for item in components.queryItems ?? [] { values[item.name] = item.value ?? "" }
            let succeeded = values["code"] != nil
            self.respond(connection, status: "200 OK", body: succeeded
                ? "<meta charset=utf-8><h2>登录成功</h2><p>可以关闭这个页面，回到小喷。</p>"
                : "<meta charset=utf-8><h2>登录没有完成</h2><p>请回到小喷重试。</p>")
            self.finish(.success(values))
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func set() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}
