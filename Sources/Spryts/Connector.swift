import AppKit
import SwiftUI

/// One connection per engine, shared by the characters that choose it.
final class Connector: ObservableObject {
    private static var connections: [String: Connector] = [:]
    static var shared: Connector { of(Engine.current) }
    static func of(_ engine: String) -> Connector {
        if let existing = connections[engine] { return existing }
        let connector = Connector(engine: engine)
        connections[engine] = connector
        return connector
    }
    let engine: String
    var name: String { engine == "codex" ? "OpenAI Codex" : (engine == "grok" ? "Grok" : "Claude Code") }

    enum State {
        case checking, missing, signedOut, connected
    }

    @Published var state: State = .checking
    @Published var working = ""     // what is happening right now, in words
    @Published var problem = ""     // the last thing that went wrong
    private var process: Process?

    private init(engine: String) {
        self.engine = engine
        refresh()
    }

    var needsConnecting: Bool { state == .missing || state == .signedOut }

    /// A reply came back through Claude Code, so whatever the status check said, it works.
    func noteWorking() {
        if state != .connected { state = .connected }
        if !problem.isEmpty { problem = "" }
    }

    /// Runs a command and waits for it. Call this off the main thread only.
    private func run(_ path: String, _ arguments: [String], keep: Bool = false) -> (code: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.standardInput = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        if keep {
            DispatchQueue.main.async { self.process = task }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func finish(_ newState: State, problem newProblem: String = "") {
        DispatchQueue.main.async {
            self.process = nil
            self.working = ""
            self.problem = newProblem
            self.state = newState
        }
    }

    /// Looks again at whether the chosen agent is installed and signed in.
    func refresh() {
        guard working.isEmpty else { return }
        if engine == "codex" {
            state = .checking
            DispatchQueue.global(qos: .userInitiated).async {
                guard let binary = CodexAgent.binary else { self.finish(.missing); return }
                let result = self.run(binary, ["login", "status"])
                self.finish(result.code == 0 ? .connected : .signedOut)
            }
            return
        }
        if engine == "grok" {
            let found = Harness.findGrok()
            Harness.grokPath = found
            working = ""
            problem = ""
            state = found == nil ? .missing : (Harness.grokSignedIn || Config.key("XAI_API_KEY") != nil ? .connected : .signedOut)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Harness.findClaude()
            DispatchQueue.main.async { Harness.claudePath = found }
            guard let claude = found else {
                self.finish(.missing)
                return
            }
            let status = self.run(claude, ["auth", "status"])
            self.finish(status.code == 0 ? .connected : .signedOut)
        }
    }

    /// Installs Claude Code if it is missing, then opens the browser to sign in.
    func connect() {
        if !working.isEmpty { return }
        problem = ""
        working = "Getting ready…"
        if engine == "codex" {
            guard let binary = CodexAgent.binary else {
                working = ""
                problem = "Install Codex, then choose Check again."
                NSWorkspace.shared.open(URL(string: "https://developers.openai.com/codex/cli/")!)
                return
            }
            working = "Finish signing in in your browser…"
            DispatchQueue.global(qos: .userInitiated).async {
                let login = self.run(binary, ["login"], keep: true)
                let status = self.run(binary, ["login", "status"])
                self.finish(status.code == 0 ? .connected : .signedOut,
                    problem: status.code == 0 ? "" : (login.code == 0 ? "Check Codex sign-in and try again." : "Sign-in didn't finish."))
            }
            return
        }
        if engine == "grok" {
            connectGrok()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var claude = Harness.findClaude()
            if claude == nil {
                DispatchQueue.main.async { self.working = "Installing Claude Code (about a minute)…" }
                let install = self.run("/bin/bash", ["-c", "curl -fsSL https://claude.ai/install.sh | bash"], keep: true)
                claude = Harness.findClaude()
                if claude == nil {
                    let detail = install.output.split(separator: "\n").last.map(String.init) ?? ""
                    self.finish(.missing, problem: "Claude Code didn't install. " + detail)
                    return
                }
            }
            guard let path = claude else { return }
            DispatchQueue.main.async {
                Harness.claudePath = path
                self.working = "Finish signing in in your browser…"
            }
            let login = self.run(path, ["auth", "login"], keep: true)
            let status = self.run(path, ["auth", "status"])
            if status.code == 0 {
                self.finish(.connected)
            } else {
                let detail = login.output.split(separator: "\n").last.map(String.init) ?? ""
                self.finish(.signedOut, problem: "Sign-in didn't finish. " + String(detail.prefix(160)))
            }
        }
    }

    /// The same two steps for Grok: install if missing, then sign in through the browser.
    private func connectGrok() {
        DispatchQueue.global(qos: .userInitiated).async {
            var grok = Harness.findGrok()
            if grok == nil {
                DispatchQueue.main.async { self.working = "Installing Grok (about a minute)…" }
                let install = self.run("/bin/bash", ["-c", "curl -fsSL https://x.ai/cli/install.sh | bash"], keep: true)
                grok = Harness.findGrok()
                if grok == nil {
                    let detail = install.output.split(separator: "\n").last.map(String.init) ?? ""
                    self.finish(.missing, problem: "Grok didn't install. " + detail)
                    return
                }
            }
            guard let path = grok else { return }
            DispatchQueue.main.async {
                Harness.grokPath = path
                self.working = "Finish signing in in your browser…"
            }
            let login = self.run(path, ["login"], keep: true)
            if Harness.grokSignedIn {
                self.finish(.connected)
            } else {
                let detail = login.output.split(separator: "\n").last.map(String.init) ?? ""
                self.finish(.signedOut, problem: "Sign-in didn't finish. " + String(detail.prefix(160)))
            }
        }
    }

    func cancel() {
        process?.terminate()
    }
}

/// The card a character shows in its popup while it isn't connected.
struct ConnectCard: View {
    @ObservedObject var connector: Connector
    let name: String
    let tint: Color

    var body: some View {
        if connector.needsConnecting { card }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "link.circle.fill").foregroundColor(tint)
                Text(connector.state == .missing ? "\(name) needs \(connector.name)" : "\(name) isn't signed in to \(connector.name)")
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(connector.working.isEmpty
                 ? "Connect to \(connector.name) using its own sign-in. Characters using this engine share the connection."
                 : connector.working)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !connector.problem.isEmpty {
                Text(connector.problem)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if connector.working.isEmpty {
                    Button(action: { connector.connect() }) {
                        Text(connector.state == .missing ? (connector.engine == "codex" ? "Get Codex" : "Install and connect") : "Connect in browser")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(tint.opacity(0.4))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Button(action: { connector.refresh() }) {
                        Text("Check again").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Button(action: { connector.cancel() }) {
                        Text("Cancel").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}
