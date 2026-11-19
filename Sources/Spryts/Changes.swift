import AppKit
import SwiftUI

// MARK: - Checkpoints

/// The project as it was just before one of Nova's tasks began, kept as a git tree object.
/// Nothing in the person's repo changes: no commits, no refs, no touched index. Ignored files are not included.
struct Checkpoint: Codable, Identifiable, Equatable {
    var id: String { tree + at.description }
    let tree: String
    let root: String     // the repo's top folder
    let ask: String
    let at: Date
}

struct ChangedFile: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let status: String   // A added, M modified, D deleted
    let added: Int
    let removed: Int
    let binary: Bool
}

struct DiffHunk: Identifiable {
    let id: Int
    let header: String
    let lines: [String]
}

struct FileDiff {
    var head: [String] = []     // diff --git, index, ---, +++
    var hunks: [DiffHunk] = []
}

enum Git {
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    @discardableResult
    static func run(_ arguments: [String], in folder: URL, env: [String: String] = [:], input: String? = nil) -> (out: String, ok: Bool) {
        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        run.arguments = ["-C", folder.path, "-c", "core.quotePath=false"] + arguments
        if !env.isEmpty {
            run.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        }
        let out = Pipe()
        run.standardOutput = out
        run.standardError = FileHandle.nullDevice
        let inPipe = Pipe()
        run.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        do {
            try run.run()
            if let input {
                inPipe.fileHandleForWriting.write(input.data(using: .utf8) ?? Data())
                try? inPipe.fileHandleForWriting.close()
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            run.waitUntilExit()
            return (String(data: data, encoding: .utf8) ?? "", run.terminationStatus == 0)
        } catch {
            return ("", false)
        }
    }

    static func root(of folder: URL) -> URL? {
        let result = run(["rev-parse", "--show-toplevel"], in: folder)
        let path = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.ok && !path.isEmpty ? URL(fileURLWithPath: path) : nil
    }

    /// Every file in the working tree, untracked ones too, written as a tree object through a throwaway index.
    static func snapshot(root: URL) -> String? {
        let fm = FileManager.default
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("spryts-index-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temp) }
        let indexPath = run(["rev-parse", "--git-path", "index"], in: root).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let real = indexPath.hasPrefix("/") ? URL(fileURLWithPath: indexPath) : root.appendingPathComponent(indexPath)
        if fm.fileExists(atPath: real.path) { try? fm.copyItem(at: real, to: temp) }
        let env = ["GIT_INDEX_FILE": temp.path]
        guard run(["add", "-A", "--", "."], in: root, env: env).ok else { return nil }
        let tree = run(["write-tree"], in: root, env: env)
        let hash = tree.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return tree.ok && !hash.isEmpty ? hash : nil
    }

    static func checkpoint(folder: URL, ask: String) -> Checkpoint? {
        guard let root = root(of: folder), let tree = snapshot(root: root) else { return nil }
        return Checkpoint(tree: tree, root: root.path, ask: ask, at: Date())
    }

    static func headTree(root: URL) -> String {
        let result = run(["rev-parse", "HEAD^{tree}"], in: root)
        let hash = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.ok && !hash.isEmpty ? hash : emptyTree
    }

    static func changes(from base: String, to tree: String, root: URL) -> [ChangedFile] {
        var counts: [String: (Int, Int, Bool)] = [:]
        let numstat = run(["diff", "--numstat", "--no-renames", "-z", base, tree], in: root).out
        for record in numstat.split(separator: "\0") {
            let parts = record.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            counts[parts[2]] = (Int(parts[0]) ?? 0, Int(parts[1]) ?? 0, parts[0] == "-")
        }
        var files: [ChangedFile] = []
        let fields = run(["diff", "--name-status", "--no-renames", "-z", base, tree], in: root).out
            .split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i + 1 < fields.count {
            let status = String(fields[i].prefix(1))
            let path = fields[i + 1]
            i += 2
            if status.isEmpty || path.isEmpty { continue }
            let count = counts[path] ?? (0, 0, false)
            files.append(ChangedFile(path: path, status: status, added: count.0, removed: count.1, binary: count.2))
        }
        return files
    }

    static func diff(path: String, from base: String, to tree: String, root: URL) -> FileDiff {
        let text = run(["diff", "--no-color", "--no-renames", "--no-ext-diff", base, tree, "--", path], in: root).out
        var result = FileDiff()
        var header = ""
        var lines: [String] = []
        func flush() {
            if !header.isEmpty { result.hunks.append(DiffHunk(id: result.hunks.count, header: header, lines: lines)) }
            header = ""
            lines = []
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                flush()
                header = line
            } else if header.isEmpty {
                if !line.isEmpty { result.head.append(line) }
            } else {
                lines.append(line)
            }
        }
        flush()
        if let last = result.hunks.last, last.lines.last == "" {
            result.hunks[result.hunks.count - 1] = DiffHunk(id: last.id, header: last.header, lines: Array(last.lines.dropLast()))
        }
        return result
    }

    /// Puts one file back the way it was in `base`, or removes it if it didn't exist there. Only the working copy changes.
    @discardableResult
    static func undo(path: String, to base: String, root: URL) -> Bool {
        if base != emptyTree && run(["cat-file", "-e", base + ":" + path], in: root).ok {
            return run(["restore", "--source=" + base, "--worktree", "--", path], in: root).ok
        }
        let url = root.appendingPathComponent(path)
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    /// Reverses one part of a file's change in the working copy.
    static func undo(hunk: DiffHunk, head: [String], root: URL) -> Bool {
        let patch = (head + [hunk.header] + hunk.lines).joined(separator: "\n") + "\n"
        return run(["apply", "-R", "--whitespace=nowarn", "-"], in: root, input: patch).ok
    }
}

// MARK: - The Changes tab

@MainActor
final class ChangesModel: ObservableObject {
    @Published var files: [ChangedFile] = []
    @Published var open: [String: FileDiff] = [:]
    @Published var loading = false
    @Published var notRepo = false
    @Published var note = ""
    @Published var baseChoice: String?      // a checkpoint's id, or nil for the last commit
    private(set) var root: URL?
    private(set) var base = Git.emptyTree
    private(set) var current = Git.emptyTree

    func refresh(folder: URL?, checkpoints: [Checkpoint]) {
        guard let folder else {
            files = []
            notRepo = false
            return
        }
        loading = true
        let point = checkpoints.first(where: { $0.id == baseChoice })
        let expanded = Array(open.keys)
        Task {
            let result = await Task.detached { () -> (URL?, String, String, [ChangedFile], [String: FileDiff]) in
                guard let root = Git.root(of: folder), let now = Git.snapshot(root: root) else { return (nil, "", "", [], [:]) }
                let base = point.map { $0.tree } ?? Git.headTree(root: root)
                let files = Git.changes(from: base, to: now, root: root)
                var diffs: [String: FileDiff] = [:]
                for path in expanded where files.contains(where: { $0.path == path }) {
                    diffs[path] = Git.diff(path: path, from: base, to: now, root: root)
                }
                return (root, base, now, files, diffs)
            }.value
            self.loading = false
            guard let root = result.0 else {
                self.notRepo = true
                self.files = []
                self.root = nil
                return
            }
            self.notRepo = false
            self.root = root
            self.base = result.1
            self.current = result.2
            self.files = result.3
            self.open = result.4
        }
    }

    func toggle(_ file: ChangedFile) {
        if open[file.path] != nil {
            open[file.path] = nil
        } else if let root {
            open[file.path] = Git.diff(path: file.path, from: base, to: current, root: root)
        }
    }

    func undo(_ file: ChangedFile) {
        guard let root else { return }
        if !Git.undo(path: file.path, to: base, root: root) { note = "Couldn't put \(file.path) back." }
    }

    func undo(_ hunk: DiffHunk, in file: ChangedFile) {
        guard let root, let diff = open[file.path] else { return }
        if !Git.undo(hunk: hunk, head: diff.head, root: root) {
            note = "That part of \(file.path) has changed since. Refresh and try again."
        }
    }

    func undoAll() {
        guard let root else { return }
        let failed = files.filter { !Git.undo(path: $0.path, to: base, root: root) }
        note = failed.isEmpty ? "" : "Couldn't put back: " + failed.map { $0.path }.joined(separator: ", ")
    }
}

struct ChangesView: View {
    @ObservedObject var session: ChatSession
    @StateObject private var model = ChangesModel()
    let name: String
    let tint: Color
    @State private var confirmAll = false

    private var baseLabel: String {
        if let point = session.checkpoints.first(where: { $0.id == model.baseChoice }) {
            return "Since: " + point.ask
        }
        return "Since the last commit"
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.notRepo {
                empty("This folder isn't a git repository, so there is nothing to compare against. Ask \(name) to set one up.")
            } else if session.projectFolder == nil {
                empty("No folder assigned yet.")
            } else if model.files.isEmpty {
                empty(model.loading ? "Looking…" : "No changes.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.files) { file in fileRow(file) }
                    }
                    .padding(10)
                }
            }
            if !model.note.isEmpty {
                Text(model.note)
                    .font(.system(size: 11))
                    .foregroundColor(Highlighter.removed)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Surface.text)
        .onAppear {
            if model.baseChoice == nil { model.baseChoice = session.checkpoints.first?.id }
            reload()
        }
        .onChange(of: session.checkpoints) {
            model.baseChoice = session.checkpoints.first?.id
            reload()
        }
        .onChange(of: session.busy) { if !session.busy { reload() } }
        .onChange(of: session.editCount) { reload() }
        .onChange(of: session.projectFolder) { reload() }
        .onChange(of: model.baseChoice) { reload() }
        .alert("Undo every change \(baseLabel.lowercased())?", isPresented: $confirmAll) {
            Button("Undo all", role: .destructive) {
                model.undoAll()
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(model.files.count) file\(model.files.count == 1 ? "" : "s") go back to how they were. New files are removed. Files git ignores are left alone.")
        }
    }

    private func reload() {
        model.note = ""
        model.refresh(folder: session.projectFolder, checkpoints: session.checkpoints)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(session.checkpoints) { point in
                    Button(action: { model.baseChoice = point.id }) {
                        let title = point.ask + "  ·  " + point.at.formatted(date: .omitted, time: .shortened)
                        if point.id == model.baseChoice { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }
                }
                if !session.checkpoints.isEmpty { Divider() }
                Button(action: { model.baseChoice = nil }) {
                    if model.baseChoice == nil { Label("The last commit", systemImage: "checkmark") } else { Text("The last commit") }
                }
            } label: {
                Text(baseLabel).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .help("Compare against the project as it was before one of \(name)'s tasks, or against the last commit")
            Spacer(minLength: 6)
            if !model.files.isEmpty {
                Text("\(model.files.count) file\(model.files.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Text("+\(model.files.reduce(0) { $0 + $1.added })")
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(Highlighter.added)
                Text("−\(model.files.reduce(0) { $0 + $1.removed })")
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(Highlighter.removed)
            }
            Button(action: reload) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Refresh")
            Button("Undo All", systemImage: "arrow.uturn.backward") { confirmAll = true }
                .capsuleButton(tint: .red)
                .disabled(model.files.isEmpty || session.busy)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "A": return Highlighter.added
        case "D": return Highlighter.removed
        default: return Highlighter.hunk
        }
    }

    private func fileRow(_ file: ChangedFile) -> some View {
        let isOpen = model.open[file.path] != nil
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 10)
                Text(file.status)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(statusColor(file.status))
                Text(file.path)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 6)
                if file.binary {
                    Text("binary").font(.system(size: 10)).foregroundColor(.secondary)
                } else {
                    Text("+\(file.added)").font(.system(size: 10, design: .monospaced)).foregroundColor(Highlighter.added)
                    Text("−\(file.removed)").font(.system(size: 10, design: .monospaced)).foregroundColor(Highlighter.removed)
                }
                Button("Undo") {
                    model.undo(file)
                    reload()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(tint)
                .disabled(session.busy)
                .help(file.status == "A" ? "Remove this new file" : "Put this file back")
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .onTapGesture { if !file.binary { model.toggle(file) } }
            if let diff = model.open[file.path] {
                ForEach(diff.hunks) { hunk in hunkView(hunk, file: file) }
            }
        }
        .background(Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Surface.separator, lineWidth: 0.5))
    }

    private func hunkView(_ hunk: DiffHunk, file: ChangedFile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(hunk.header)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Highlighter.hunk)
                    .lineLimit(1)
                Spacer()
                if file.status == "M" {
                    Button("Undo this part") {
                        model.undo(hunk, in: file)
                        reload()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(tint)
                    .disabled(session.busy)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Surface.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(Highlighter.color(hunk.lines.joined(separator: "\n"), lang: "diff", limit: 400))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
    }
}
