import AppKit
import SwiftUI

/// One sign-in for every character: they all talk through Claude Code on this Mac,
/// so connecting once in the browser connects all of them.
final class Connector: ObservableObject {
    static let shared = Connector()

    enum State {
        case checking, missing, signedOut, connected
    }

    @Published var state: State = .checking
    @Published var working = ""     // what is happening right now, in words
    @Published var problem = ""     // the last thing that went wrong
    private var process: Process?

    private init() {
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
        if Engine.current == "grok" {
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
        if Engine.current == "grok" {
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
    @ObservedObject var connector = Connector.shared
    let name: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "link.circle.fill").foregroundColor(tint)
Text(connector.state == .missing ? "\(name) needs \(Engine.current == "grok" ? "Grok" : "Claude Code")" : "\(name) isn't signed in to \(Engine.name)")
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(connector.working.isEmpty
                 ? "Connect once in your browser and every character is ready. It uses your \(Engine.name) plan, not an API key."
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
                        Text(connector.state == .missing ? "Install and connect" : "Connect in browser")
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
