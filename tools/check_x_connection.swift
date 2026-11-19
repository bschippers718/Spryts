import Foundation

// Production OAuth/API/connection code, with only fake transport, storage and browser callbacks.
enum Config { static func key(_ name: String) -> String? { nil } }

private final class MemoryStore: PipXTokenStore {
    var value: PipXCredentials?
    var reads = 0
    var saves = 0
    var clears = 0
    var failSave = false
    var failClear = false
    func load() throws -> PipXCredentials? { reads += 1; return value }
    func save(_ value: PipXCredentials) throws {
        if failSave { throw PipXFailure.storage }
        self.value = value; saves += 1
    }
    func clear() throws {
        if failClear { throw PipXFailure.storage }
        value = nil; clears += 1
    }
}

private final class FixtureTransport: PipXTransport {
    var responses: [(String, Int)]
    var requests: [URLRequest] = []
    init(_ responses: [(String, Int)]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        guard !responses.isEmpty else { throw PipXFailure.network }
        let next = responses.removeFirst()
        return (Data(next.0.utf8), next.1)
    }
}

private actor SuspendedIdentity: PipXTransport {
    let token: String
    var requests = 0
    var pending: CheckedContinuation<(Data, Int), Error>?
    init(token: String) { self.token = token }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests += 1
        if requests == 1 { return (Data(token.utf8), 200) }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func release(_ identity: String) {
        pending?.resume(returning: (Data(identity.utf8), 200)); pending = nil
    }
}

@main
struct XChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fatalError(message) }
            checks += 1
        }
        func rejects(_ expected: PipXFailure, _ action: () throws -> Void, _ message: String) {
            do { try action(); fatalError(message) }
            catch { check((error as? PipXFailure) == expected, message) }
        }
        func wait(_ connection: PipXConnection) async {
            for _ in 0..<500 where connection.isWorking { try? await Task.sleep(nanoseconds: 1_000_000) }
            check(!connection.isWorking, "operation must finish")
        }
        let token = #"{"access_token":"fake-access","token_type":"bearer","expires_in":7200,"refresh_token":"fake-refresh","scope":"tweet.read users.read offline.access"}"#
        let identity = #"{"data":{"id":"123","name":"Test User","username":"test_user"}}"#
        let posts = #"{"data":[{"id":"456","text":"A fixture post","author_id":"123","created_at":"2026-11-19T12:00:00.000Z"}],"includes":{"users":[{"id":"123","username":"test_user"}]},"meta":{"result_count":1}}"#

        let attempt = PipXOAuth.Attempt(clientID: "public-client", state: "fixture-state", verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        check(attempt.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "RFC 7636 S256 vector")
        let params = URLComponents(url: attempt.url, resolvingAgainstBaseURL: false)!.queryItems!
        check(attempt.url.host == "x.com" && attempt.url.path == "/i/oauth2/authorize", "fixed authorization host")
        check(params.first { $0.name == "code_challenge_method" }?.value == "S256", "PKCE S256")
        check(params.first { $0.name == "scope" }?.value == "offline.access tweet.read users.read", "read-only scopes")
        check(!params.contains { $0.name == "client_secret" }, "no client secret")
        let randomA = try PipXOAuth.attempt(clientID: "public-client")
        let randomB = try PipXOAuth.attempt(clientID: "public-client")
        check(randomA.state.count == 43 && randomA.verifier.count == 43, "256-bit random strings")
        check(randomA.state != randomB.state && randomA.state != randomA.verifier, "per-attempt random state/verifier")
        let callback = URL(string: PipXOAuth.callback + "?state=fixture-state&code=fixture-code")!
        check(try attempt.code(from: callback) == "fixture-code", "matching callback")
        for bad in ["https://oauth/x?state=fixture-state&code=x", "spryts-auth://evil/x?state=fixture-state&code=x",
                    "spryts-auth://oauth/y?state=fixture-state&code=x", "spryts-auth://oauth/x?state=wrong&code=x",
                    "spryts-auth://oauth/x?state=fixture-state&state&code=x", "spryts-auth://oauth/x?state=fixture-state&code=x&code=y",
                    "spryts-auth://oauth/x?state=fixture-state&code=x#fragment", "spryts-auth://user@oauth/x?state=fixture-state&code=x"] {
            rejects(.callback, { _ = try attempt.code(from: URL(string: bad)!) }, "reject malformed/mismatched callback")
        }
        rejects(.denied, { _ = try attempt.code(from: URL(string: PipXOAuth.callback + "?state=fixture-state&error=access_denied")!) }, "denied consent")
        rejects(.configuration, { _ = try PipXOAuth.attempt(clientID: "\n") }, "reject empty ID")
        rejects(.configuration, { _ = try PipXOAuth.attempt(clientID: "id&scope=tweet.write") }, "reject injected ID")
        let saved = try PipXOAuth.credentials(Data(token.utf8), clientID: "public-client", now: Date(timeIntervalSince1970: 0))
        check(saved.expiresAt == Date(timeIntervalSince1970: 7200), "expiry is measured")
        rejects(.token, { _ = try PipXOAuth.credentials(Data(token.replacingOccurrences(of: "tweet.read", with: "tweet.write").utf8), clientID: "public-client") }, "reject write scope")
        rejects(.token, { _ = try PipXOAuth.credentials(Data(token.replacingOccurrences(of: "bearer", with: "basic").utf8), clientID: "public-client") }, "reject nonbearer token")

        let transport = FixtureTransport([(token, 200), (identity, 200), (posts, 200), (posts, 200), (posts, 200)])
        let api = PipXAPI(transport: transport)
        let credentials = try await api.exchange(attempt, callback: callback)
        let account = try await api.identity(credentials)
        check(account.username == "test_user", "verified account response")
        for feed in PipXFeed.allCases {
            let rows = try await api.feed(feed, query: "cats & dogs", account: account, credentials: credentials)
            check(rows.count == 1 && rows[0].author == "@test_user" && rows[0].createdAt != nil, "feed parses authors and fractional date")
        }
        check(transport.requests.allSatisfy { $0.url?.host == "api.x.com" && $0.url?.scheme == "https" }, "fixed API host")
        check(transport.requests.dropFirst().allSatisfy { $0.httpMethod == "GET" }, "no write API calls")
        check(String(data: transport.requests[0].httpBody!, encoding: .utf8)!.contains("code_verifier="), "exchange sends verifier")
        check(!String(data: transport.requests[0].httpBody!, encoding: .utf8)!.contains("client_secret"), "exchange has no secret")
        for request in transport.requests.suffix(3) {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            check(query.first { $0.name == "max_results" }?.value == "10" && !query.contains { $0.name == "pagination_token" }, "bounded ten results without paging")
        }
        check(URLComponents(url: transport.requests.last!.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "query" }?.value == "cats & dogs", "query encoded as a value")
        do { _ = try await api.feed(.search, query: " ", account: account, credentials: credentials); fatalError("empty query accepted") }
        catch { check((error as? PipXFailure) == .query && transport.requests.count == 5, "invalid query never contacts service") }
        check(try PipXAPI.posts(Data(#"{"meta":{"result_count":0}}"#.utf8)).isEmpty, "empty feed")
        rejects(.response, { _ = try PipXAPI.posts(Data(#"{"errors":[{"detail":"secret-value"}]}"#.utf8)) }, "error-only response not empty success")
        rejects(.response, { _ = try PipXAPI.posts(Data(posts.replacingOccurrences(of: "\"456\"", with: "\"../evil\"").utf8)) }, "post URLs cannot inject paths")
        let many = "{\"data\":[" + (1...20).map { "{\"id\":\"\($0)\",\"text\":\"post\"}" }.joined(separator: ",") + "]}"
        check(try PipXAPI.posts(Data(many.utf8)).count == 10, "server oversupply capped")
        for (status, expected) in [(401, PipXFailure.expired), (402, .billing), (403, .access), (429, .rateLimit), (500, .response)] {
            rejects(expected, { try PipXOAuth.check(status) }, "sanitized HTTP errors")
            check(!expected.message.contains("fake-access"), "errors contain no credentials")
        }

        let rotated = #"{"access_token":"rotated-access","token_type":"bearer","expires_in":7200,"refresh_token":"rotated-refresh","scope":"tweet.read users.read offline.access"}"#
        let refreshTransport = FixtureTransport([(rotated, 200), (identity, 200)])
        let restoreStore = MemoryStore(); restoreStore.value = saved
        let restored = PipXConnection(transport: refreshTransport, store: restoreStore)
        check(restoreStore.reads == 0 && refreshTransport.requests.isEmpty, "init is inert")
        restored.restoreSavedConnection(); await wait(restored)
        check(restored.account?.id == "123" && restored.error == nil, "explicit restoration verifies identity")
        check(restoreStore.value?.refreshToken == "rotated-refresh" && restoreStore.saves == 1, "refresh rotation persisted")
        check(refreshTransport.requests.first?.url?.path == "/2/oauth2/token", "refresh before expired identity request")
        restored.disconnect()
        check(restoreStore.value == nil && restored.account == nil && restored.posts.isEmpty && restoreStore.clears == 1, "disconnect clears local data")
        check(refreshTransport.requests.count == 2, "local disconnect makes no remote request")

        let connectStore = MemoryStore()
        let connectTransport = FixtureTransport([(token, 200), (identity, 200), (posts, 200), (posts, 200), (posts, 200)])
        let connection = PipXConnection(transport: connectTransport, store: connectStore) { url in
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
            return URL(string: PipXOAuth.callback + "?state=\(state)&code=fixture")!
        }
        connection.connect(clientID: "public-client"); await wait(connection)
        check(connection.account?.name == "Test User" && connectStore.saves == 1, "connect verifies before saving")
        connection.load(.mentions); await wait(connection)
        check(connection.posts.count == 1 && connection.fetchedAt != nil && connection.feedLabel == "Mentions", "explicit feed state")
        connection.load(.search, query: "  original query  "); await wait(connection)
        check(connection.feedLabel == "Search: original query", "search keeps fetched query provenance")
        let longQuery = String(repeating: "q", count: 300)
        connection.load(.search, query: "  " + longQuery + "  "); await wait(connection)
        check(connection.feedLabel == "Search: " + longQuery, "search provenance retains the full captured query beyond display length")
        connectStore.failClear = true
        connection.disconnect()
        check(connection.account != nil && connectStore.value != nil && connection.error?.contains("Try Disconnect again") == true, "failed deletion remains visible and retryable")
        connectStore.failClear = false
        connection.disconnect()
        check(connection.account == nil && connectStore.value == nil && connection.error == nil, "deletion retry clears account")
        let deniedStore = MemoryStore()
        let deniedTransport = FixtureTransport([])
        let denied = PipXConnection(transport: deniedTransport, store: deniedStore) { _ in throw PipXFailure.cancelled }
        denied.connect(clientID: "public-client"); await wait(denied)
        check(denied.account == nil && deniedStore.saves == 0 && deniedTransport.requests.isEmpty, "cancel before network/storage")
        let badIdentityStore = MemoryStore()
        let badIdentity = PipXConnection(transport: FixtureTransport([(token, 200), (#"{"data":{"id":"bad","name":"User","username":"user"}}"#, 200)]), store: badIdentityStore) { url in
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
            return URL(string: PipXOAuth.callback + "?state=\(state)&code=fixture")!
        }
        badIdentity.connect(clientID: "public-client"); await wait(badIdentity)
        check(badIdentity.account == nil && badIdentityStore.saves == 0, "unverified account never published or saved")
        let wrongStateTransport = FixtureTransport([])
        let wrongStateStore = MemoryStore()
        let wrongState = PipXConnection(transport: wrongStateTransport, store: wrongStateStore) { _ in
            URL(string: PipXOAuth.callback + "?state=wrong&code=fixture")!
        }
        wrongState.connect(clientID: "public-client"); await wait(wrongState)
        check(wrongState.account == nil && wrongStateStore.saves == 0 && wrongStateTransport.requests.isEmpty, "wrong callback state blocks exchange")
        let failingStore = MemoryStore(); failingStore.failSave = true
        let storageFailure = PipXConnection(transport: FixtureTransport([(token, 200), (identity, 200)]), store: failingStore) { url in
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
            return URL(string: PipXOAuth.callback + "?state=\(state)&code=fixture")!
        }
        storageFailure.connect(clientID: "public-client"); await wait(storageFailure)
        check(storageFailure.account == nil && storageFailure.error == PipXFailure.storage.message, "storage failure cannot show connected")
        let suspended = SuspendedIdentity(token: token)
        let cancelledStore = MemoryStore()
        let cancelled = PipXConnection(transport: suspended, store: cancelledStore) { url in
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
            return URL(string: PipXOAuth.callback + "?state=\(state)&code=fixture")!
        }
        cancelled.connect(clientID: "public-client")
        for _ in 0..<500 {
            if await suspended.requests == 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        check(await suspended.requests == 2, "identity request suspended")
        cancelled.disconnect()
        await suspended.release(identity)
        try await Task.sleep(nanoseconds: 5_000_000)
        check(cancelled.account == nil && cancelledStore.saves == 0 && !cancelled.isWorking, "late identity cannot restore disconnected account")
        var browserCalls = 0
        let immediate = PipXConnection(transport: FixtureTransport([]), store: MemoryStore()) { _ in
            browserCalls += 1
            throw PipXFailure.cancelled
        }
        immediate.connect(clientID: "public-client")
        immediate.disconnect()
        try await Task.sleep(nanoseconds: 5_000_000)
        check(browserCalls == 0 && immediate.account == nil && !immediate.isWorking, "immediate disconnect prevents browser launch")
        let authWaiter = PipXAuthorizationWaiter()
        let waiting = Task { try await authWaiter.wait() }
        await Task.yield()
        authWaiter.finish(.failure(.cancelled))
        authWaiter.finish(.success(callback))
        do { _ = try await waiting.value; fatalError("cancelled authorization completed") }
        catch { check((error as? PipXFailure) == .cancelled, "explicit programmatic cancellation releases auth wait; late callback ignored") }
        let earlyWaiter = PipXAuthorizationWaiter()
        earlyWaiter.finish(.success(callback))
        check(try await earlyWaiter.wait() == callback, "synchronous native callback cannot be lost")
        print("\(checks) X connection checks passed; no network, browser or Keychain access.")
    }
}
