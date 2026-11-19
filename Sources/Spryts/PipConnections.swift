import AppKit
import SwiftUI

private final class PipConnectionsModel: ObservableObject {
    @Published private(set) var apps: [PipInstalledApp] = []
    @Published private(set) var scanning = false
    @Published private(set) var scanLimited = false
    @Published private(set) var services: [PipServiceConnection] = []
    @Published private(set) var checking = false
    @Published private(set) var checkedAt: Date?
    @Published private(set) var serviceMessage = ""
    @Published var openProblem = ""
    private var generation = UUID()

    func refreshApps() {
        guard !scanning else { return }
        scanning = true
        let roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = PipAppCatalog.scan(roots: roots)
            DispatchQueue.main.async {
                self?.apps = result.apps
                self?.scanLimited = result.limited
                self?.scanning = false
            }
        }
    }

    func resetServices() {
        generation = UUID()
        checking = false
        checkedAt = nil
        services = []
        serviceMessage = ""
    }

    func noteConfigured(_ service: PipRemoteService, message: String) {
        services.removeAll { $0.name == service.name }
        services.append(PipServiceConnection(name: service.name, status: .configured))
        services.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        serviceMessage = message
    }

    func checkServices(engine: String, binary: String?, directory: URL) {
        guard !checking else { return }
        guard engine == "claude" || engine == "grok" else {
            serviceMessage = "Service discovery isn’t available for this engine."
            return
        }
        guard let binary else {
            serviceMessage = "Connect this engine below, then check its services."
            return
        }
        let token = UUID()
        generation = token
        checking = true
        serviceMessage = ""
        let arguments = engine == "grok" ? ["mcp", "list", "--json"] : ["mcp", "list"]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = PipConnectionCommand.run(binary: binary, arguments: arguments, directory: directory)
            let parsed = engine == "grok" ? PipConnectionParser.grok(result.output)
                : PipConnectionParser.claude(String(data: result.output, encoding: .utf8) ?? "")
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.checking = false
                self.checkedAt = Date()
                self.services = parsed.services
                if result.timedOut { self.serviceMessage = "The check timed out. Try again, or check services in the agent." }
                else if result.truncated { self.serviceMessage = "The service list was too large to read completely. Check it in the agent." }
                else if result.exitCode != 0 { self.serviceMessage = "The agent couldn’t list its services. Check its connection and try again." }
                else if !parsed.recognized { self.serviceMessage = "This agent version returned a service list Spryts couldn’t read." }
                else if parsed.services.isEmpty { self.serviceMessage = "No services were listed for this workspace." }
            }
        }
    }

    func open(_ app: PipInstalledApp) {
        openProblem = ""
        NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            DispatchQueue.main.async {
                if error != nil { self?.openProblem = "\(app.name) couldn’t be opened. Try opening it in Finder." }
            }
        }
    }
}

struct PipConnectionsView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var shelf: AppShelf
    let tint: Color
    var onScenes: (() -> Void)? = nil
    var onPrepared: (() -> Void)? = nil
    @StateObject private var model = PipConnectionsModel()
    @State private var search = ""
    @State private var showingMacAccess = false
    @State private var serviceSetup: PipServiceSetupContext?

    private var matchingApps: [PipInstalledApp] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return model.apps }
        return model.apps.filter { $0.name.localizedCaseInsensitiveContains(term) || ($0.bundleID?.localizedCaseInsensitiveContains(term) ?? false) }
    }

    private var matchingServices: [PipServiceConnection] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? model.services : model.services.filter { $0.name.localizedCaseInsensitiveContains(term) }
    }

    private var directory: URL {
        let workspace = session.projectFolder ?? (session.engine == "grok" ? Harness.grokWorkspace : Harness.workspace)
        return FileManager.default.fileExists(atPath: workspace.path) ? workspace : FileManager.default.homeDirectoryForCurrentUser
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let onScenes {
                HStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 25)).foregroundStyle(tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Put your connections to work").font(.system(size: 15, weight: .semibold))
                        Text("Five starter Scenes bring your apps, files, and Spryts together around a useful result.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Explore Scenes", action: onScenes)
                }.solidCard(corner: 12, padding: 18)
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search apps and services", text: $search).textFieldStyle(.plain)
                    .accessibilityLabel("Search apps and services")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(10)
            .background(Surface.card, in: RoundedRectangle(cornerRadius: 9))

            PipSocialConnectionsView(session: session, tint: tint, onPrepared: { onPrepared?() })

            servicesSection

            DisclosureGroup("Mac access and engine setup", isExpanded: $showingMacAccess) {
                MacAccessView(session: session, tint: tint).padding(.top, 12)
            }
            .font(.system(size: 12, weight: .medium))

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionTitle(text: "Apps on this Mac")
                    Text("\(model.apps.count)").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Spacer()
                    if model.scanning { ProgressView().controlSize(.small) }
                    Button("Refresh", systemImage: "arrow.clockwise") { model.refreshApps() }
                        .buttonStyle(.borderless).font(.system(size: 11)).disabled(model.scanning)
                }
                Text("Open an app or prepare a request for \(session.sheet.name). Installed apps aren’t connected accounts; macOS asks for Automation access when an app is first used.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.openProblem.isEmpty {
                    Text(model.openProblem).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if !model.scanning && matchingApps.isEmpty {
                    Text(search.isEmpty ? "No applications were found in the usual Applications folders." : "No apps match this search.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 12)
                }
                LazyVStack(spacing: 0) {
                    ForEach(matchingApps) { app in
                        appRow(app)
                        Divider().padding(.leading, 49)
                    }
                }
                if model.scanLimited {
                    Text("Showing the first \(model.apps.count) apps found in Applications. Some folders weren’t scanned.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

        }
        .onAppear { if model.apps.isEmpty { model.refreshApps() } }
        .onChange(of: session.engine) { model.resetServices() }
        .onChange(of: session.projectFolder) { model.resetServices() }
        .sheet(item: $serviceSetup) { context in
            PipAddServiceSheet(context: context) { service, message in
                if context.engine == session.engine { model.noteConfigured(service, message: message) }
            }
        }
    }

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(text: "Services")
                Spacer()
                if model.checking { ProgressView().controlSize(.small) }
                Button(model.checkedAt == nil ? "Check services" : "Check again") {
                    model.checkServices(engine: session.engine, binary: session.harnessBinary(), directory: directory)
                    if session.harnessBinary() == nil { showingMacAccess = true }
                }
                .buttonStyle(.bordered).controlSize(.small).disabled(model.checking || session.busy)
                Button("Add Service", systemImage: "plus") {
                    guard let binary = session.harnessBinary() else { showingMacAccess = true; return }
                    serviceSetup = PipServiceSetupContext(engine: session.engine, engineName: session.engineLabel,
                                                         binary: binary, directory: directory,
                                                         names: Set(model.services.map(\.name)))
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(model.checking || session.busy || !["claude", "grok"].contains(session.engine))
            }
            Text(session.engine == "grok"
                 ? "Lists the services configured for Grok in this workspace. Grok checks their connection when you use them."
                 : "Checks the services configured for \(session.engineLabel) in this workspace. The agent may start approved servers to check their connection.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let date = model.checkedAt {
                Text("Checked " + date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            if !model.serviceMessage.isEmpty {
                Text(model.serviceMessage).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(matchingServices) { service in
                HStack(spacing: 10) {
                    Image(systemName: "network").foregroundStyle(.secondary).frame(width: 26)
                    Text(service.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 12)
                    Label(service.status.label, systemImage: service.status.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(service.status == .connected ? Color.green : Color.secondary)
                }
                .padding(.vertical, 7)
            }
            HStack(spacing: 12) {
                Link("Connection setup", destination: URL(string: session.engine == "grok"
                     ? "https://docs.x.ai/build/features/mcp-servers" : "https://code.claude.com/docs/en/mcp")!)
                if model.services.contains(where: { $0.status == .needsSignIn || $0.status == .needsApproval }) {
                    Text(session.engine == "grok" ? "Manage sign-in in Grok’s /mcps panel." : "Manage sign-in and approvals in Claude Code’s /mcp panel.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
        }
        .solidCard(corner: 12, padding: 16)
    }

    private func appRow(_ app: PipInstalledApp) -> some View {
        let running = shelf.running.contains { $0.id == app.bundleID || $0.url?.standardizedFileURL == app.url.standardizedFileURL }
        return HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable().frame(width: 34, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(running ? "Open on this Mac" : "Installed on this Mac")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Ask \(session.sheet.name)") {
                if !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { session.draft += "\n\n" }
                session.draft += "In \(app.name): "
                session.focusTick += 1
            }
            .buttonStyle(.borderless).controlSize(.small)
            .help("Prepare a request about \(app.name)")
            Button("Open") { model.open(app) }
                .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.vertical, 10)
    }
}

private struct PipServiceSetupContext: Identifiable {
    let id = UUID()
    let engine: String
    let engineName: String
    let binary: String
    let directory: URL
    let names: Set<String>
}

private struct PipAddServiceSheet: View {
    let context: PipServiceSetupContext
    let onSaved: (PipRemoteService, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var saving = false
    @State private var problem = ""

    private var validation: String? {
        do {
            let service = try PipRemoteService(name: name, address: address)
            if context.names.contains(where: { $0.caseInsensitiveCompare(service.name) == .orderedSame }) {
                return "This name is already in the service list. Choose another name."
            }
            return nil
        } catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add Service").font(.system(size: 20, weight: .semibold))
                Text("Add a remote service to \(context.engineName). It will be available to this engine across your projects on this Mac.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Form {
                TextField("Name", text: $name, prompt: Text("work-notes"))
                TextField("Server URL", text: $address, prompt: Text("https://service.example/mcp"))
            }
            .textFieldStyle(.roundedBorder)
            .disabled(saving)
            Text("Use the service’s HTTPS MCP address, without passwords or tokens. This saves the connection settings; sign-in and any tool approvals stay with \(context.engineName).")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !problem.isEmpty {
                Text(problem).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if (!name.isEmpty || !address.isEmpty), let validation {
                Text(validation).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if saving { ProgressView().controlSize(.small); Text("Saving…").font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || validation != nil)
            }
        }
        .padding(24)
        .frame(width: 500)
        .interactiveDismissDisabled(saving)
    }

    private func save() {
        guard !saving, validation == nil, let service = try? PipRemoteService(name: name, address: address) else { return }
        saving = true
        problem = ""
        let context = context
        DispatchQueue.global(qos: .userInitiated).async {
            let result = PipServiceSetup.save(service, engine: context.engine, binary: context.binary, directory: context.directory)
            DispatchQueue.main.async {
                saving = false
                if result.saved {
                    onSaved(service, result.message)
                    dismiss()
                } else { problem = result.message }
            }
        }
    }
}
