import AppKit
import Combine

/// An app on the shelf: either running now or recently quit.
struct AppItem: Identifiable {
    let id: String
    let name: String
    let icon: NSImage
    let url: URL?
    let pid: pid_t
    let running: Bool
    let front: Bool
}

/// What is known about one app's recent use.
struct AppActivity {
    var name: String
    var lastActive: Date
    var seconds: Double
    var notes: [String]
}

/// One line of the recent-activity list on Pip's desk.
struct ActivityRow: Identifiable {
    let id: String
    let name: String
    let icon: NSImage
    let when: String
    let spent: String
    let windows: [String]
    let note: String?
    let item: AppItem?
}

/// Tracks open and recently used apps, most recently used first.
final class AppShelf: ObservableObject {
    @Published var running: [AppItem] = []
    @Published var recent: [AppItem] = []
    private(set) var frontName = ""
    @Published var rows: [ActivityRow] = []
    private var activity: [String: AppActivity] = [:]
    private var frontID: String?
    private var frontSince = Date()
    private var order: [String] = []          // bundle ids, most recently used first
    private var quitApps: [AppItem] = []
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.handle(name: note.name, app: app)
            }
            observers.append(token)
        }
        if let front = NSWorkspace.shared.frontmostApplication, let id = front.bundleIdentifier {
            order = [id]
            frontID = id
            activity[id] = AppActivity(name: front.localizedName ?? id, lastActive: Date(), seconds: 0, notes: [])
        }
        refresh()
    }

    private func handle(name: NSNotification.Name, app: NSRunningApplication?) {
        if let app, let id = app.bundleIdentifier, app.activationPolicy == .regular {
            if name == NSWorkspace.didTerminateApplicationNotification {
                order.removeAll(where: { $0 == id })
                quitApps.removeAll(where: { $0.id == id })
                quitApps.insert(AppItem(id: id, name: app.localizedName ?? id, icon: app.icon ?? NSImage(),
                                    url: app.bundleURL, pid: 0, running: false, front: false), at: 0)
                if quitApps.count > 6 { quitApps.removeLast(quitApps.count - 6) }
            } else {
                quitApps.removeAll(where: { $0.id == id })
                if name == NSWorkspace.didActivateApplicationNotification {
                    order.removeAll(where: { $0 == id })
                    order.insert(id, at: 0)
                    // Close out the time spent in the app that was in front, and start the clock on this one.
                    settle()
                    frontID = id
                    frontSince = Date()
                    if activity[id] == nil {
                        activity[id] = AppActivity(name: app.localizedName ?? id, lastActive: Date(), seconds: 0, notes: [])
                    }
                    activity[id]?.lastActive = Date()
                }
            }
        }
        refresh()
    }

    func refresh() {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        var items: [AppItem] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier else { continue }
            let front = app.processIdentifier == frontPID
            if front { frontName = app.localizedName ?? id }
            items.append(AppItem(id: id, name: app.localizedName ?? id, icon: app.icon ?? NSImage(),
                                 url: app.bundleURL, pid: app.processIdentifier, running: true, front: front))
        }
        let rank: (String) -> Int = { id in self.order.firstIndex(of: id) ?? Int.max }
        items.sort(by: { a, b in
            let ra = rank(a.id)
            let rb = rank(b.id)
            if ra != rb { return ra < rb }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        })
        running = items
        recent = quitApps
        refreshActivity()
    }

    // MARK: Recent activity

    /// Adds the time since the last check to whichever app is in front.
    private func settle() {
        let now = Date()
        if let id = frontID {
            activity[id]?.seconds += now.timeIntervalSince(frontSince)
            activity[id]?.lastActive = now
        }
        frontSince = now
    }

    /// Titles of an app's open windows. Empty unless this app has been allowed to see window names.
    private func windowTitles(pid: pid_t) -> [String] {
        if pid == 0 { return [] }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var titles: [String] = []
        for info in list {
            guard let owner = info[kCGWindowOwnerPID as String] as? Int, owner == Int(pid),
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let title = info[kCGWindowName as String] as? String, !title.isEmpty else { continue }
            if !titles.contains(title) { titles.append(title) }
            if titles.count == 3 { break }
        }
        return titles
    }

    private static func ago(_ date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        return "\(minutes / 60) h ago"
    }

    private static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    /// Rebuilds the recent-activity list: the six apps used most recently, with what is known about each.
    func refreshActivity() {
        settle()
        let ranked = activity.sorted(by: { a, b in
            if a.key == frontID { return true }
            if b.key == frontID { return false }
            return a.value.lastActive > b.value.lastActive
        })
        var out: [ActivityRow] = []
        for (id, info) in ranked.prefix(6) {
            let item = running.first(where: { $0.id == id }) ?? quitApps.first(where: { $0.id == id })
            out.append(ActivityRow(
                id: id,
                name: info.name,
                icon: item?.icon ?? NSImage(),
                when: id == frontID ? "in use now" : AppShelf.ago(info.lastActive),
                spent: AppShelf.duration(info.seconds),
                windows: windowTitles(pid: item?.pid ?? 0),
                note: info.notes.first,
                item: item))
        }
        rows = out
    }

    /// Remembers something the agent did, against every app it involved.
    func note(_ text: String, mentioning haystack: String) {
        let lower = haystack.lowercased()
        var short = text.split(separator: "\n").first.map(String.init) ?? text
        if short.count > 80 { short = String(short.prefix(80)) + "…" }
        if short.isEmpty { return }
        for app in running where lower.contains(app.name.lowercased()) {
            if activity[app.id] == nil {
                activity[app.id] = AppActivity(name: app.name, lastActive: Date(), seconds: 0, notes: [])
            }
            activity[app.id]?.notes.insert(short, at: 0)
            if (activity[app.id]?.notes.count ?? 0) > 3 { activity[app.id]?.notes.removeLast() }
        }
        refreshActivity()
    }

    /// A sentence for the agent about what is open.
    var context: String {
        let names = running.prefix(14).map { $0.name }.joined(separator: ", ")
        var text = "the frontmost app is \(frontName.isEmpty ? "unknown" : frontName). Open apps, most recently used first: \(names)."
        // What the person has been doing lately, so the agent has the same picture they do.
        refreshActivity()
        var lines: [String] = []
        for row in rows {
            var line = row.name + " (" + row.when + ", " + row.spent + " this session"
            if !row.windows.isEmpty { line += "; windows: " + row.windows.joined(separator: " | ") }
            if let note = row.note { line += "; you last helped with: " + note }
            lines.append(line + ")")
        }
        if !lines.isEmpty { text += " Recent activity: " + lines.joined(separator: "; ") + "." }
        return text
    }

    func open(_ item: AppItem) {
        guard let url = item.url else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    func hide(_ item: AppItem) {
        _ = NSRunningApplication(processIdentifier: item.pid)?.hide()
    }

    func quit(_ item: AppItem) {
        _ = NSRunningApplication(processIdentifier: item.pid)?.terminate()
    }
}
