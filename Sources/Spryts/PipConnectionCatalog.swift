import Foundation
import Darwin

struct PipInstalledApp: Identifiable, Equatable {
    let id: String
    let name: String
    let bundleID: String?
    let url: URL
}

enum PipAppCatalog {
    struct Scan {
        var apps: [PipInstalledApp]
        var limited: Bool
    }

    /// Only visits application folders. App bundles and directory symlinks are never traversed.
    static func scan(roots: [URL], maximumDepth: Int = 3, maximumApps: Int = 600,
                     maximumEntries: Int = 8_000) -> Scan {
        let manager = FileManager.default
        var found: [String: PipInstalledApp] = [:]
        var visited = 0
        var limited = false
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]

        func visit(_ directory: URL, depth: Int) {
            guard depth <= maximumDepth, visited < maximumEntries, found.count < maximumApps else {
                limited = true
                return
            }
            guard let entries = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles]) else { return }
            for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard visited < maximumEntries, found.count < maximumApps else { limited = true; break }
                visited += 1
                let values = try? url.resourceValues(forKeys: Set(keys))
                if url.pathExtension.lowercased() == "app" {
                    guard values?.isDirectory == true || values?.isSymbolicLink == true, let bundle = Bundle(url: url),
                          let info = bundle.infoDictionary else { continue }
                    let bundleID = info["CFBundleIdentifier"] as? String
                    let rawName = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
                        ?? info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String
                        ?? url.deletingPathExtension().lastPathComponent
                    let scalars = rawName.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(120)
                    let name = String(String.UnicodeScalarView(scalars))
                    let id = bundleID?.isEmpty == false ? bundleID! : url.standardizedFileURL.path
                    if found[id] == nil {
                        found[id] = PipInstalledApp(id: id, name: name.isEmpty ? "Application" : name,
                                                    bundleID: bundleID, url: url)
                    }
                } else if values?.isDirectory == true, values?.isSymbolicLink != true, values?.isPackage != true {
                    if depth < maximumDepth { visit(url, depth: depth + 1) }
                }
            }
        }
        for root in roots { visit(root, depth: 0) }
        return Scan(apps: found.values.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }, limited: limited)
    }
}

enum PipServiceStatus: String, Equatable {
    case connected, configured, needsSignIn, needsApproval, disabled, unavailable, notConfigured

    var label: String {
        switch self {
        case .connected: return "Connected"
        case .configured: return "Configured"
        case .needsSignIn: return "Sign-in needed"
        case .needsApproval: return "Approval needed"
        case .disabled: return "Disabled"
        case .unavailable: return "Unavailable"
        case .notConfigured: return "Setup needed"
        }
    }

    var icon: String {
        switch self {
        case .connected: return "checkmark.circle.fill"
        case .configured: return "link"
        case .needsSignIn: return "person.crop.circle.badge.exclamationmark"
        case .needsApproval: return "hand.raised"
        case .disabled: return "pause.circle"
        case .unavailable: return "exclamationmark.circle"
        case .notConfigured: return "plus.circle"
        }
    }
}

struct PipServiceConnection: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let status: PipServiceStatus
}

enum PipConnectionParser {
    struct Result {
        let services: [PipServiceConnection]
        let recognized: Bool
    }

    /// Output may include URLs, headers and command arguments. Only a conservative name and enum survive.
    static func claude(_ output: String) -> Result {
        let plain = output.replacingOccurrences(of: "\\u001B\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        var services: [String: PipServiceConnection] = [:]
        for line in plain.split(whereSeparator: \.isNewline) {
            let statusPattern = " - [^A-Za-z]*(?:Connected\\b|Needs authentication\\b|Pending approval\\b|Disabled\\b|Rejected\\b|Blocked\\b|Failed\\b|Connection error\\b|not configured\\b|cached\\b)"
            guard let delimiter = line.range(of: ": "), let statusDelimiter = line.range(of: statusPattern, options: [.regularExpression, .caseInsensitive]),
                  delimiter.upperBound <= statusDelimiter.lowerBound,
                  let name = safeName(String(line[..<delimiter.lowerBound])) else { continue }
            let statusStart = line.index(statusDelimiter.lowerBound, offsetBy: 3)
            let rawStatus = String(line[statusStart...]).lowercased()
            let status: PipServiceStatus
            if rawStatus.contains("needs authentication") || rawStatus.contains("needs-auth") { status = .needsSignIn }
            else if rawStatus.contains("pending approval") { status = .needsApproval }
            else if rawStatus.contains("disabled") || rawStatus.contains("rejected") || rawStatus.contains("blocked") { status = .disabled }
            else if rawStatus.contains("not configured") { status = .notConfigured }
            else if rawStatus.contains("failed") || rawStatus.contains("connection error") { status = .unavailable }
            else {
                let words = rawStatus.drop(while: { !$0.isLetter })
                if words == "connected" || words.hasPrefix("connected ") { status = .connected }
                else if words.hasPrefix("cached") { status = .configured }
                else { continue }
            }
            services[name] = PipServiceConnection(name: name, status: status)
        }
        let lower = plain.lowercased()
        let empty = lower.contains("no mcp servers configured") || lower.contains("no servers configured")
        return Result(services: sorted(services.values), recognized: !services.isEmpty || empty)
    }

    /// Grok's list command describes configuration, not a connectivity or OAuth health check.
    static func grok(_ output: Data) -> Result {
        guard let value = try? JSONSerialization.jsonObject(with: output) else {
            return Result(services: [], recognized: false)
        }
        let rows: [[String: Any]]?
        if let array = value as? [[String: Any]] { rows = array }
        else if let object = value as? [String: Any], let array = object["servers"] as? [[String: Any]] { rows = array }
        else { rows = nil }
        guard let rows else { return Result(services: [], recognized: false) }
        var services: [String: PipServiceConnection] = [:]
        for row in rows {
            guard let rawName = row["name"] as? String, let name = safeName(rawName) else { continue }
            let disabled = row["enabled"] as? Bool == false || row["disabled"] as? Bool == true
            services[name] = PipServiceConnection(name: name, status: disabled ? .disabled : .configured)
        }
        return Result(services: sorted(services.values), recognized: rows.isEmpty || !services.isEmpty)
    }

    static func safeName(_ value: String) -> String? {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.range(of: "^[A-Za-z0-9][A-Za-z0-9_.: -]{0,95}$", options: .regularExpression) != nil,
              !name.contains("://"), !name.lowercased().contains("bearer ") else { return nil }
        return name
    }

    private static func sorted<S: Sequence>(_ values: S) -> [PipServiceConnection] where S.Element == PipServiceConnection {
        values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

struct PipRemoteService: Equatable {
    let name: String
    let address: String

    enum ValidationError: LocalizedError, Equatable {
        case name, address, credentials
        var errorDescription: String? {
            switch self {
            case .name: return "Use a name beginning with a letter, with up to 64 letters, numbers, hyphens or underscores."
            case .address: return "Enter a complete HTTPS server address."
            case .credentials: return "Use a server address without passwords, tokens, query parameters or a fragment. Sign in through the agent afterward."
            }
        }
    }

    init(name: String, address: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.range(of: "^[A-Za-z][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil else {
            throw ValidationError.name
        }
        guard let parts = URLComponents(string: address), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, !host.contains(where: \.isWhitespace),
              let url = parts.url, url.scheme?.lowercased() == "https",
              parts.port.map({ $0 > 0 && $0 <= 65535 }) ?? true,
              !address.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw ValidationError.address }
        guard parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              !parts.path.lowercased().contains("bearer"),
              parts.path.range(of: "(?:sk-|xox[baprs]-|ghp_|github_pat_)[A-Za-z0-9_-]{12,}", options: .regularExpression) == nil else {
            throw ValidationError.credentials
        }
        self.name = name
        self.address = url.absoluteString
    }

    /// Both CLIs document these flags. Each value is an argument; nothing is interpreted by a shell.
    var addArguments: [String] { ["mcp", "add", "--transport", "http", "--scope", "user", name, address] }
}

enum PipServiceSetup {
    struct Result {
        let saved: Bool
        let message: String
    }
    typealias Runner = (String, [String], URL) -> PipConnectionCommand.Result

    static func save(_ service: PipRemoteService, engine: String, binary: String, directory: URL,
                     run: Runner = { PipConnectionCommand.run(binary: $0, arguments: $1, directory: $2) }) -> Result {
        guard engine == "claude" || engine == "grok" else {
            return Result(saved: false, message: "Adding services isn’t available for this engine.")
        }
        if engine == "grok" {
            // Grok's add command can overwrite existing entries. Refuse to replace any visible name.
            let listing = run(binary, ["mcp", "list", "--json"], directory)
            let parsed = PipConnectionParser.grok(listing.output)
            guard listing.exitCode == 0, !listing.timedOut, !listing.truncated, parsed.recognized else {
                return Result(saved: false, message: "Grok couldn’t check its existing services. Nothing was added; try again after checking the engine.")
            }
            if parsed.services.contains(where: { $0.name.caseInsensitiveCompare(service.name) == .orderedSame }) {
                return duplicate()
            }
        }
        let result = run(binary, service.addArguments, directory)
        if result.timedOut {
            return Result(saved: false, message: "Saving took too long. Check the agent’s service list before trying again; the configuration may have been saved.")
        }
        let output = String(data: result.output, encoding: .utf8) ?? ""
        if output.lowercased().contains("already exists") { return duplicate() }
        guard result.exitCode == 0, !result.truncated else {
            return Result(saved: false, message: "The agent couldn’t confirm this service was saved. Check its service settings before trying again.")
        }
        if engine == "claude" {
            let pattern = "(?m)^Added\\b[^\\n]*" + NSRegularExpression.escapedPattern(for: service.name)
            guard !output.lowercased().contains("not saved"), !output.lowercased().contains("not have been saved"),
                  output.range(of: pattern, options: .regularExpression) != nil else {
                return Result(saved: false, message: "Claude Code didn’t confirm a save. Check its service list before trying again.")
            }
        } else {
            // This list is configuration-only; it does not contact or authenticate the new service.
            let listing = run(binary, ["mcp", "list", "--json"], directory)
            let rows = (try? JSONSerialization.jsonObject(with: listing.output)) as? [[String: Any]]
            let verified = rows?.contains { ($0["name"] as? String) == service.name && ($0["url"] as? String) == service.address } ?? false
            guard listing.exitCode == 0, !listing.timedOut, !listing.truncated, verified else {
                return Result(saved: false, message: "Grok finished saving, but Spryts couldn’t verify the address. Check its service settings before trying again.")
            }
        }
        return Result(saved: true, message: "\(service.name) was added to this engine’s personal services. Finish any sign-in in the agent, then check services here.")
    }

    private static func duplicate() -> Result {
        Result(saved: false, message: "A service with this name already exists. Choose another name, or manage the existing service in the agent.")
    }
}

/// Used by the fixed list/add argument builders. No raw output, endpoint, header or environment is logged.
enum PipConnectionCommand {
    struct Result {
        var output = Data()
        var exitCode: Int32 = -1
        var timedOut = false
        var truncated = false
    }

    static func run(binary: String, arguments: [String], directory: URL, timeout: TimeInterval = 12) -> Result {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        environment["CLICOLOR"] = "0"
        environment["MCP_TIMEOUT"] = "8000"
        environment["PATH"] = [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                                environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        process.environment = environment
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var result = Result()
        do { try process.run() } catch { return result }
        let deadline = Date().addingTimeInterval(timeout)
        let maximum = 256 * 1024
        var bytes = [UInt8](repeating: 0, count: 8192)
        func drain() {
            while Date() < deadline {
                let count = Darwin.read(fd, &bytes, bytes.count)
                guard count > 0 else { return }
                let remaining = max(0, maximum - result.output.count)
                result.output.append(contentsOf: bytes.prefix(min(count, remaining)))
                if count > remaining { result.truncated = true }
            }
        }
        while Date() < deadline {
            drain()
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.025)
        }
        if process.isRunning {
            result.timedOut = true
            process.interrupt()
            let grace = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.025) }
            if process.isRunning { process.terminate() }
            let end = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.025) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        } else {
            drain()
            result.exitCode = process.terminationStatus
        }
        try? pipe.fileHandleForReading.close()
        return result
    }
}
