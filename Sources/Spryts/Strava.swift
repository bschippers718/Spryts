import AppKit
import Foundation
import Network

/// Strava for the coach. A one-time login in the browser, then the last 60 days of activities are written
/// into the coach's journal folder as strava.md before each conversation (at most every half hour).
///
/// It needs the person's own Strava API application: STRAVA_CLIENT_ID and STRAVA_CLIENT_SECRET in .env, with
/// "localhost" as its Authorization Callback Domain. Tokens live in a private file outside every agent's folders.
@MainActor
final class Strava: ObservableObject {
    static let shared = Strava()

    @Published private(set) var athlete = ""
    @Published private(set) var status = ""
    @Published private(set) var connecting = false

    var connected: Bool { tokens != nil }
    var configured: Bool { Config.key("STRAVA_CLIENT_ID") != nil && Config.key("STRAVA_CLIENT_SECRET") != nil }

    private struct Tokens: Codable {
        var access: String
        var refresh: String
        var expiresAt: Double
        var athlete: String
    }

    private var tokens: Tokens?
    private var lastSync = Date.distantPast
    private var listener: NWListener?
    private var expectedState = ""
    private var pendingID = ""
    private let port: UInt16 = 8723
    private var redirect: String { "http://localhost:\(port)/strava" }

    private static var tokenFile: URL { Harness.support.appendingPathComponent("strava-token.json") }

    private init() {
        if let data = try? Data(contentsOf: Strava.tokenFile), let saved = try? JSONDecoder().decode(Tokens.self, from: data) {
            tokens = saved
            athlete = saved.athlete
        }
    }

    // MARK: Connecting

    /// Opens Strava's consent page and waits on localhost for it to send the person back.
    func connect(for id: String) {
        guard let clientID = Config.key("STRAVA_CLIENT_ID"), Config.key("STRAVA_CLIENT_SECRET") != nil else {
            status = "Add STRAVA_CLIENT_ID and STRAVA_CLIENT_SECRET to .env first."
            return
        }
        do {
            try listen()
        } catch {
            status = "Couldn't open port \(port) for Strava's reply."
            return
        }
        expectedState = UUID().uuidString
        pendingID = id
        var parts = URLComponents(string: "https://www.strava.com/oauth/authorize")!
        parts.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "approval_prompt", value: "auto"),
            URLQueryItem(name: "scope", value: "read,activity:read_all"),
            URLQueryItem(name: "state", value: expectedState),
        ]
        connecting = true
        status = "Finish connecting in your browser…"
        NSWorkspace.shared.open(parts.url!)
    }

    func disconnect(for id: String) {
        if let access = tokens?.access {
            var request = URLRequest(url: URL(string: "https://www.strava.com/oauth/deauthorize")!)
            request.httpMethod = "POST"
            request.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: request).resume()
        }
        tokens = nil
        athlete = ""
        status = ""
        try? FileManager.default.removeItem(at: Strava.tokenFile)
        try? FileManager.default.removeItem(at: Harness.trainingFolder(for: id).appendingPathComponent("strava.md"))
    }

    /// A tiny one-shot web server on the loopback interface only, for Strava's redirect.
    private func listen() throws {
        listener?.cancel()
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let server = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        server.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let query = URLComponents(string: "http://localhost" + path)?.queryItems ?? []
                let value = { (name: String) in query.first(where: { $0.name == name })?.value }
                let ok = path.hasPrefix("/strava") && value("code") != nil
                let page = ok ? "Rally is connected to Strava. You can close this tab."
                              : "Strava wasn't connected. You can close this tab and try again from Rally."
                let body = "<html><body style=\"font-family:-apple-system;padding:48px\"><h2>\(page)</h2></body></html>"
                let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                if !path.hasPrefix("/strava") { return }   // a stray favicon request, say
                Task { @MainActor in
                    await Strava.shared.finish(code: value("code"), state: value("state"), error: value("error"))
                }
            }
        }
        server.start(queue: .main)
        listener = server
    }

    private func finish(code: String?, state: String?, error: String?) async {
        listener?.cancel()
        listener = nil
        connecting = false
        guard error == nil, let code, state == expectedState else {
            status = "Strava wasn't connected."
            return
        }
        do {
            let json = try await tokenRequest(["grant_type": "authorization_code", "code": code])
            try store(json)
            status = "Connected."
            await sync(for: pendingID, force: true)
        } catch {
            status = "Strava refused the login. Check the client ID and secret."
        }
    }

    // MARK: Tokens

    private func tokenRequest(_ fields: [String: String]) async throws -> [String: Any] {
        guard let clientID = Config.key("STRAVA_CLIENT_ID"), let secret = Config.key("STRAVA_CLIENT_SECRET") else {
            throw URLError(.userAuthenticationRequired)
        }
        var all = fields
        all["client_id"] = clientID
        all["client_secret"] = secret
        var form = URLComponents()
        form.queryItems = all.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: URL(string: "https://www.strava.com/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.userAuthenticationRequired)
        }
        return json
    }

    private func store(_ json: [String: Any]) throws {
        guard let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String,
              let expires = json["expires_at"] as? Double ?? (json["expires_at"] as? Int).map(Double.init) else {
            throw URLError(.cannotParseResponse)
        }
        let name = (json["athlete"] as? [String: Any])?["firstname"] as? String ?? tokens?.athlete ?? ""
        let saved = Tokens(access: access, refresh: refresh, expiresAt: expires, athlete: name)
        tokens = saved
        athlete = name
        try FileManager.default.createDirectory(at: Harness.support, withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: Strava.tokenFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Strava.tokenFile.path)
    }

    private func freshAccess() async throws -> String {
        guard let current = tokens else { throw URLError(.userAuthenticationRequired) }
        if current.expiresAt > Date().timeIntervalSince1970 + 120 { return current.access }
        let json = try await tokenRequest(["grant_type": "refresh_token", "refresh_token": current.refresh])
        try store(json)
        return tokens?.access ?? current.access
    }

    // MARK: Activities

    /// Writes the last 60 days into the coach's folder. Quietly does nothing when not connected.
    func sync(for id: String, force: Bool = false) async {
        guard connected else { return }
        if !force && Date().timeIntervalSince(lastSync) < 1800 { return }
        do {
            let access = try await freshAccess()
            let after = Int(Date().addingTimeInterval(-60 * 86400).timeIntervalSince1970)
            var activities: [[String: Any]] = []
            for page in 1...3 {
                var parts = URLComponents(string: "https://www.strava.com/api/v3/athlete/activities")!
                parts.queryItems = [URLQueryItem(name: "after", value: String(after)),
                                    URLQueryItem(name: "per_page", value: "100"),
                                    URLQueryItem(name: "page", value: String(page))]
                var request = URLRequest(url: parts.url!)
                request.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let batch = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    throw URLError(.badServerResponse)
                }
                activities += batch
                if batch.count < 100 { break }
            }
            let folder = Harness.trainingFolder(for: id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Strava.render(activities).write(to: folder.appendingPathComponent("strava.md"), atomically: true, encoding: .utf8)
            lastSync = Date()
            status = "\(activities.count) activities in the last 60 days."
        } catch {
            status = "Couldn't reach Strava just now."
        }
    }

    /// One line per activity, newest first, with weekly totals on top. Units follow the Mac's settings.
    private static func render(_ activities: [[String: Any]]) -> String {
        let imperial = Locale.current.measurementSystem == .us
        let unit = imperial ? "mi" : "km"
        let perUnit = imperial ? 1609.344 : 1000.0
        func clock(_ seconds: Double) -> String {
            let s = Int(seconds.rounded())
            return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
        }
        let isoIn = ISO8601DateFormatter()
        let dayOut = DateFormatter()
        dayOut.dateFormat = "yyyy-MM-dd EEE HH:mm"
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current

        var weekly: [String: (count: Int, time: Double, distance: Double)] = [:]
        var lines: [String] = []
        let sorted = activities.sorted { ($0["start_date"] as? String ?? "") > ($1["start_date"] as? String ?? "") }
        for a in sorted {
            let sport = a["sport_type"] as? String ?? a["type"] as? String ?? "Activity"
            let name = a["name"] as? String ?? ""
            let distance = a["distance"] as? Double ?? 0
            let moving = a["moving_time"] as? Double ?? Double(a["moving_time"] as? Int ?? 0)
            let date = (a["start_date"] as? String).flatMap { isoIn.date(from: $0) }
            var parts = [date.map { dayOut.string(from: $0) } ?? "?", sport, "\"" + name + "\""]
            if distance > 0 { parts.append(String(format: "%.2f %@", distance / perUnit, unit)) }
            parts.append(clock(moving))
            if distance > 0 && moving > 0 {
                if ["Run", "TrailRun", "Walk", "Hike", "VirtualRun"].contains(sport) {
                    parts.append(clock(moving / (distance / perUnit)) + " /" + unit)
                } else {
                    parts.append(String(format: "%.1f %@/h", (distance / perUnit) / (moving / 3600), unit))
                }
            }
            if let climb = a["total_elevation_gain"] as? Double, climb > 0 {
                parts.append(imperial ? String(format: "+%.0f ft", climb * 3.281) : String(format: "+%.0f m", climb))
            }
            if let hr = a["average_heartrate"] as? Double {
                var heart = String(format: "HR %.0f avg", hr)
                if let top = a["max_heartrate"] as? Double { heart += String(format: " / %.0f max", top) }
                parts.append(heart)
            }
            if let watts = a["average_watts"] as? Double { parts.append(String(format: "%.0f W", watts)) }
            if let effort = a["suffer_score"] as? Double { parts.append(String(format: "effort %.0f", effort)) }
            lines.append("- " + parts.joined(separator: " · "))

            if let date {
                let week = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
                let key = String(format: "%04d-W%02d", week.yearForWeekOfYear ?? 0, week.weekOfYear ?? 0)
                var total = weekly[key] ?? (0, 0, 0)
                total.count += 1
                total.time += moving
                total.distance += distance
                weekly[key] = total
            }
        }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        var out = "# Strava, last 60 days\nSynced \(stamp.string(from: Date())). Written by Spryts; read it, don't edit it.\n\n## Weekly totals\n"
        for key in weekly.keys.sorted(by: >) {
            let w = weekly[key]!
            out += String(format: "- %@: %d sessions, %@, %.1f %@\n", key, w.count, clock(w.time), w.distance / perUnit, unit)
        }
        if weekly.isEmpty { out += "- Nothing recorded.\n" }
        out += "\n## Activities, newest first\n" + (lines.isEmpty ? "- None.\n" : lines.joined(separator: "\n") + "\n")
        return out
    }
}
