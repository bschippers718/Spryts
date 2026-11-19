import AppKit
import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Security

struct PipXAccount: Codable, Equatable {
    let id: String
    let name: String
    let username: String
}

struct PipXPost: Identifiable, Equatable {
    let id: String
    let text: String
    let url: URL
    let author: String
    let createdAt: Date?
}

enum PipXFeed: String, CaseIterable, Identifiable {
    case mentions, myPosts, search
    var id: String { rawValue }
    var label: String {
        switch self {
        case .mentions: return "Mentions"
        case .myPosts: return "My Posts"
        case .search: return "Search"
        }
    }
    var title: String { label }
}

/// No token or provider response text is surfaced in errors or logs.
enum PipXFailure: Error, Equatable {
    case configuration, cancelled, callback, denied, token, identity, storage, response, network
    case expired, access, billing, rateLimit, query
    var message: String {
        switch self {
        case .configuration: return "Enter the client ID of a registered X Native App with the Spryts callback URL."
        case .cancelled: return "X sign-in was cancelled."
        case .callback: return "X sign-in could not be verified. Start a new connection."
        case .denied: return "X access was not granted."
        case .token: return "X did not return the required read-only access. Check your Native App settings."
        case .identity: return "X could not verify this account. Check the app’s API access and try again."
        case .storage: return "Spryts could not update this connection in Keychain."
        case .response: return "X returned an unexpected response. Try again later."
        case .network: return "X could not be reached. Check your connection and try again."
        case .expired: return "This X connection has expired. Connect again."
        case .access: return "Your X app does not have access to this request. Check its permissions and API access."
        case .billing: return "X requires API credits for this request. Check billing in the X Developer Console."
        case .rateLimit: return "X has temporarily limited requests. Wait before trying again."
        case .query: return "Enter a search of 1–512 characters."
        }
    }
}

struct PipXCredentials: Codable, Equatable {
    let clientID: String
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
    let scopes: Set<String>
}

protocol PipXTokenStore {
    func load() throws -> PipXCredentials?
    func save(_ value: PipXCredentials) throws
    func clear() throws
}

struct PipXKeychain: PipXTokenStore {
    private var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.spryts.x.oauth2",
         kSecAttrAccount as String: "read-only-connection",
         kSecAttrSynchronizable as String: false]
    }
    func load() throws -> PipXCredentials? {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = try? JSONDecoder().decode(PipXCredentials.self, from: data) else { throw PipXFailure.storage }
        return value
    }
    func save(_ value: PipXCredentials) throws {
        let data = try JSONEncoder().encode(value)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(item as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw PipXFailure.storage }
        var query = item
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw PipXFailure.storage }
    }
    func clear() throws {
        let status = SecItemDelete(item as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PipXFailure.storage }
    }
}

protocol PipXTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

/// Refuse redirects so an API response can never forward a credential to another host.
private final class PipXRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

final class PipXNetwork: PipXTransport {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: PipXRedirectGuard(), delegateQueue: nil)
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard request.url?.scheme == "https", request.url?.host == "api.x.com",
              request.url?.user == nil, request.url?.password == nil else { throw PipXFailure.configuration }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw PipXFailure.response }
        guard response.expectedContentLength <= 1_048_576 else { throw PipXFailure.response }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_048_576 else { throw PipXFailure.response }
            data.append(byte)
        }
        return (data, response.statusCode)
    }
}

enum PipXOAuth {
    static let callback = "spryts-auth://oauth/x"
    static let scopes: Set<String> = ["tweet.read", "users.read", "offline.access"]
    struct Attempt {
        let clientID: String
        let state: String
        let verifier: String
        var challenge: String { PipXOAuth.base64(Data(SHA256.hash(data: Data(verifier.utf8)))) }
        var url: URL {
            var parts = URLComponents(string: "https://x.com/i/oauth2/authorize")!
            parts.queryItems = [
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "redirect_uri", value: PipXOAuth.callback),
                URLQueryItem(name: "scope", value: PipXOAuth.scopes.sorted().joined(separator: " ")),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256")]
            return parts.url!
        }
        func code(from url: URL) throws -> String {
            guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.scheme == "spryts-auth", parts.host == "oauth", parts.path == "/x",
                  parts.port == nil, parts.user == nil, parts.password == nil, parts.fragment == nil else {
                throw PipXFailure.callback
            }
            let items = parts.queryItems ?? []
            func values(_ name: String) -> [String] { items.filter { $0.name == name }.compactMap(\.value) }
            guard items.filter({ $0.name == "state" }).count == 1, values("state") == [state] else { throw PipXFailure.callback }
            if !values("error").isEmpty { throw PipXFailure.denied }
            let codes = values("code")
            guard items.filter({ $0.name == "code" }).count == 1, codes.count == 1,
                  !codes[0].isEmpty, codes[0].utf8.count <= 4096 else { throw PipXFailure.callback }
            return codes[0]
        }
    }
    static func attempt(clientID: String) throws -> Attempt {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.utf8.count <= 512,
              id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_=")).contains($0) }) else {
            throw PipXFailure.configuration
        }
        return Attempt(clientID: id, state: try random(), verifier: try random())
    }
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw PipXFailure.configuration }
        return base64(Data(bytes))
    }
    static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(values.sorted(by: { $0.key < $1.key }).map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
    static func tokenRequest(_ values: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.x.com/2/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = form(values)
        return request
    }
    static func credentials(_ data: Data, clientID: String, previous: PipXCredentials? = nil, now: Date = Date()) throws -> PipXCredentials {
        struct Token: Decodable { let access_token: String; let token_type: String; let expires_in: Double; let refresh_token: String?; let scope: String? }
        guard let token = try? JSONDecoder().decode(Token.self, from: data),
              token.token_type.lowercased() == "bearer", !token.access_token.isEmpty,
              token.access_token.utf8.count <= 16_384, token.expires_in > 0, token.expires_in.isFinite,
              !token.access_token.contains(where: \.isWhitespace) else { throw PipXFailure.token }
        let granted = token.scope.map { Set($0.split(separator: " ").map(String.init)) } ?? previous?.scopes ?? []
        guard granted.isSubset(of: scopes), granted.contains("tweet.read"), granted.contains("users.read") else { throw PipXFailure.token }
        let refresh = token.refresh_token ?? previous?.refreshToken
        if let refresh, refresh.isEmpty || refresh.utf8.count > 16_384 || refresh.contains(where: \.isWhitespace) { throw PipXFailure.token }
        return PipXCredentials(clientID: clientID, accessToken: token.access_token, refreshToken: refresh,
                               expiresAt: now.addingTimeInterval(token.expires_in), scopes: granted)
    }
    static func check(_ code: Int, tokenRequest: Bool = false) throws {
        switch code {
        case 200..<300: return
        case 401: throw PipXFailure.expired
        case 402: throw PipXFailure.billing
        case 403: throw PipXFailure.access
        case 429: throw PipXFailure.rateLimit
        case 400 where tokenRequest: throw PipXFailure.expired
        default: throw PipXFailure.response
        }
    }
}

struct PipXAPI {
    let transport: PipXTransport
    func exchange(_ attempt: PipXOAuth.Attempt, callback: URL) async throws -> PipXCredentials {
        let code = try attempt.code(from: callback)
        try Task.checkCancellation()
        let request = PipXOAuth.tokenRequest(["grant_type": "authorization_code", "client_id": attempt.clientID,
            "code": code, "redirect_uri": PipXOAuth.callback, "code_verifier": attempt.verifier])
        let (data, status) = try await transport.send(request)
        try PipXOAuth.check(status, tokenRequest: true)
        return try PipXOAuth.credentials(data, clientID: attempt.clientID)
    }
    func refresh(_ saved: PipXCredentials) async throws -> PipXCredentials {
        guard let refresh = saved.refreshToken else { throw PipXFailure.expired }
        let (data, status) = try await transport.send(PipXOAuth.tokenRequest([
            "grant_type": "refresh_token", "refresh_token": refresh, "client_id": saved.clientID]))
        try PipXOAuth.check(status, tokenRequest: true)
        return try PipXOAuth.credentials(data, clientID: saved.clientID, previous: saved)
    }
    func identity(_ credentials: PipXCredentials) async throws -> PipXAccount {
        let data = try await get(path: "/2/users/me", credentials: credentials)
        struct Envelope: Decodable { let data: PipXAccount }
        guard let value = try? JSONDecoder().decode(Envelope.self, from: data).data,
              Self.validID(value.id), !value.name.isEmpty,
              value.username.range(of: "^[A-Za-z0-9_]{1,32}$", options: .regularExpression) != nil else { throw PipXFailure.identity }
        return value
    }
    func feed(_ feed: PipXFeed, query: String, account: PipXAccount, credentials: PipXCredentials) async throws -> [PipXPost] {
        guard Self.validID(account.id) else { throw PipXFailure.identity }
        var items = [URLQueryItem(name: "max_results", value: "10"), URLQueryItem(name: "tweet.fields", value: "created_at,author_id"),
                     URLQueryItem(name: "expansions", value: "author_id"), URLQueryItem(name: "user.fields", value: "username")]
        let path: String
        switch feed {
        case .mentions: path = "/2/users/\(account.id)/mentions"
        case .myPosts: path = "/2/users/\(account.id)/tweets"
        case .search:
            let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 512 else { throw PipXFailure.query }
            path = "/2/tweets/search/recent"
            items.append(URLQueryItem(name: "query", value: value))
        }
        let data = try await get(path: path, items: items, credentials: credentials)
        return try Self.posts(data)
    }
    private func get(path: String, items: [URLQueryItem] = [], credentials: PipXCredentials) async throws -> Data {
        var url = URLComponents(string: "https://api.x.com")!
        url.path = path
        if !items.isEmpty { url.queryItems = items }
        var request = URLRequest(url: url.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer " + credentials.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, status) = try await transport.send(request)
        try PipXOAuth.check(status)
        return data
    }
    static func validID(_ id: String) -> Bool { !id.isEmpty && id.count <= 32 && id.allSatisfy { $0.isASCII && $0.isNumber } }
    static func posts(_ data: Data) throws -> [PipXPost] {
        struct Row: Decodable { let id: String; let text: String; let author_id: String?; let created_at: String? }
        struct Author: Decodable { let id: String; let username: String }
        struct Includes: Decodable { let users: [Author]? }
        struct Meta: Decodable { let result_count: Int? }
        struct Envelope: Decodable { let data: [Row]?; let includes: Includes?; let meta: Meta? }
        guard let value = try? JSONDecoder().decode(Envelope.self, from: data),
              value.data != nil || value.meta?.result_count == 0 else { throw PipXFailure.response }
        let authors = Dictionary((value.includes?.users ?? []).map { ($0.id, $0.username) }, uniquingKeysWith: { first, _ in first })
        let date = ISO8601DateFormatter()
        let fractionalDate = ISO8601DateFormatter()
        fractionalDate.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var seen = Set<String>()
        return try (value.data ?? []).prefix(10).compactMap { row in
            guard validID(row.id), row.text.utf8.count <= 100_000 else { throw PipXFailure.response }
            guard seen.insert(row.id).inserted else { return nil }
            let author = row.author_id.flatMap { authors[$0] } ?? ""
            let safeAuthor = author.range(of: "^[A-Za-z0-9_]{1,32}$", options: .regularExpression) != nil ? "@" + author : "X account"
            return PipXPost(id: row.id, text: row.text, url: URL(string: "https://x.com/i/web/status/" + row.id)!,
                            author: safeAuthor, createdAt: row.created_at.flatMap { fractionalDate.date(from: $0) ?? date.date(from: $0) })
        }
    }
}

/// Owns completion independently of ASWebAuthenticationSession, whose cancel() only promises dismissal.
@MainActor
final class PipXAuthorizationWaiter {
    private var resolution: Result<URL, PipXFailure>?
    private var continuation: CheckedContinuation<URL, Error>?
    func wait() async throws -> URL {
        if let resolution { return try resolution.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ result: Result<URL, PipXFailure>) {
        guard resolution == nil else { return }
        resolution = result
        continuation?.resume(with: result.mapError { $0 as Error })
        continuation = nil
    }
}

@MainActor
final class PipXConnection: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = PipXConnection()
    @Published private(set) var account: PipXAccount?
    @Published private(set) var posts: [PipXPost] = []
    @Published private(set) var isWorking = false
    @Published private(set) var error: String?
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var feedLabel = ""
    var configuredClientID: String { credentials?.clientID ?? Config.key("SPRYTS_X_CLIENT_ID") ?? "" }
    private let api: PipXAPI
    private let store: PipXTokenStore
    private var credentials: PipXCredentials?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var authentication: ASWebAuthenticationSession?
    private var authenticationWaiter: PipXAuthorizationWaiter?
    private let authorize: ((URL) async throws -> URL)?

    init(transport: PipXTransport = PipXNetwork(), store: PipXTokenStore = PipXKeychain(),
         authorize: ((URL) async throws -> URL)? = nil) {
        self.api = PipXAPI(transport: transport)
        self.store = store
        self.authorize = authorize
        super.init()
        // Restoration is explicit: construction never reads Keychain or contacts X.
    }
    func connect(clientID: String) {
        guard !isWorking else { return }
        let attempt: PipXOAuth.Attempt
        do { attempt = try PipXOAuth.attempt(clientID: clientID) }
        catch { self.error = PipXFailure.configuration.message; return }
        run { [self] generation in
            let callback: URL
            if let authorize { callback = try await authorize(attempt.url) }
            else { callback = try await authenticate(attempt.url) }
            try Task.checkCancellation()
            let saved = try await api.exchange(attempt, callback: callback)
            try Task.checkCancellation()
            let identity = try await api.identity(saved)
            guard generation == self.generation else { return }
            try store.save(saved)
            credentials = saved
            account = identity
            posts = []; fetchedAt = nil; feedLabel = ""
        }
    }
    func restoreSavedConnection() {
        guard !isWorking else { return }
        run { [self] generation in
            guard let saved = try store.load() else { throw PipXFailure.expired }
            let current = try await valid(saved, generation: generation)
            try Task.checkCancellation()
            let identity = try await api.identity(current)
            guard generation == self.generation else { return }
            credentials = current
            account = identity
            posts = []; fetchedAt = nil; feedLabel = ""
        }
    }
    func load(_ feed: PipXFeed, query: String = "") {
        guard !isWorking else { return }
        guard let credentials, let account else { error = PipXFailure.expired.message; return }
        run { [self] generation in
            let current = try await valid(credentials, generation: generation)
            try Task.checkCancellation()
            let rows = try await api.feed(feed, query: query, account: account, credentials: current)
            guard generation == self.generation else { return }
            self.credentials = current
            posts = rows
            fetchedAt = Date()
            feedLabel = feed == .search ? "Search: " + query.trimmingCharacters(in: .whitespacesAndNewlines) : feed.label
        }
    }
    /// Removes only Spryts' saved credentials. Revoke remote access in X's Connected apps settings.
    func disconnect() {
        generation = UUID()
        operation?.cancel(); operation = nil
        authenticationWaiter?.finish(.failure(.cancelled)); authenticationWaiter = nil
        authentication?.cancel(); authentication = nil
        isWorking = false; error = nil
        do { try store.clear() }
        catch { self.error = "This X sign-in could not be removed from Keychain. Try Disconnect again."; return }
        credentials = nil; account = nil; posts = []; fetchedAt = nil; feedLabel = ""
    }
    private func valid(_ saved: PipXCredentials, generation: UUID) async throws -> PipXCredentials {
        guard saved.scopes.isSubset(of: PipXOAuth.scopes), saved.scopes.contains("tweet.read"), saved.scopes.contains("users.read") else { throw PipXFailure.token }
        guard !saved.accessToken.isEmpty, saved.accessToken.utf8.count <= 16_384,
              !saved.accessToken.contains(where: \.isWhitespace) else { throw PipXFailure.token }
        _ = try PipXOAuth.attempt(clientID: saved.clientID)
        if saved.expiresAt.timeIntervalSinceNow > 60 { return saved }
        let refreshed = try await api.refresh(saved)
        try Task.checkCancellation()
        guard generation == self.generation else { throw CancellationError() }
        // Persist token rotation before any billable API read; old refresh tokens may be invalidated.
        try store.save(refreshed)
        self.credentials = refreshed
        return refreshed
    }
    private func run(_ action: @escaping (UUID) async throws -> Void) {
        error = nil; isWorking = true
        let generation = UUID(); self.generation = generation
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                try await action(generation)
            }
            catch {
                guard self.generation == generation else { return }
                self.error = (error as? PipXFailure)?.message ?? (error is CancellationError ? PipXFailure.cancelled.message : PipXFailure.network.message)
                if let failure = error as? PipXFailure, failure == .expired || failure == .token {
                    self.account = nil; self.posts = []; self.fetchedAt = nil; self.feedLabel = ""
                }
            }
            guard self.generation == generation else { return }
            self.isWorking = false; self.operation = nil
        }
    }
    private func authenticate(_ url: URL) async throws -> URL {
        let authGeneration = generation
        let waiter = PipXAuthorizationWaiter()
        authenticationWaiter = waiter
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "spryts-auth") { [weak self] callback, error in
            Task { @MainActor in
                if let callback { waiter.finish(.success(callback)) }
                else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { waiter.finish(.failure(.cancelled)) }
                else { waiter.finish(.failure(.callback)) }
                if self?.generation == authGeneration {
                    self?.authentication = nil
                    self?.authenticationWaiter = nil
                }
            }
        }
        session.presentationContextProvider = self
        authentication = session
        if !session.start() {
            authentication = nil; authenticationWaiter = nil
            waiter.finish(.failure(.callback))
        }
        return try await withTaskCancellationHandler {
            try await waiter.wait()
        } onCancel: {
            Task { @MainActor in waiter.finish(.failure(.cancelled)) }
        }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? ASPresentationAnchor()
    }
}
