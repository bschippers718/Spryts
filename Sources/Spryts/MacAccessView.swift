import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

/// Checks the running app's access without displaying a permission prompt or changing a grant.
struct MacAccessView: View {
    @ObservedObject var session: ChatSession
    let tint: Color
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var accessibilityAllowed: Bool?
    @State private var screenRecordingAllowed: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionTitle(text: "Mac access")
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }
            accessRow("Accessibility", detail: "Move and interact with windows", icon: "hand.point.up.left",
                      allowed: accessibilityAllowed, pane: "Privacy_Accessibility")
            Divider()
            accessRow("Screen Recording", detail: "Read the screen when you ask", icon: "rectangle.dashed.badge.record",
                      allowed: screenRecordingAllowed, pane: "Privacy_ScreenCapture")
            Text("Automation access is requested for each app when you use it. These checks apply to Spryts; the command-line agent may need its own access.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            MacEngineReadiness(session: session, connector: Connector.of(session.engine), tint: tint)
                .id(session.engine)
        }
        .solidCard(corner: 12, padding: 16)
        .onAppear(perform: refresh)
        .onChange(of: controlActiveState) { if controlActiveState == .active { refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func accessRow(_ title: String, detail: String, icon: String, allowed: Bool?, pane: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 5) {
                Label(allowed == true ? "Allowed" : allowed == false ? "Not enabled" : "Checking…",
                      systemImage: allowed == true ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(allowed == true ? Color.green : Color.secondary)
                    .fixedSize()
                Button("Open Settings") { openSettings(pane) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Open \(title) in System Settings")
                    .accessibilityLabel("Open \(title) settings")
            }
        }
    }

    private func refresh() {
        accessibilityAllowed = AXIsProcessTrusted()
        screenRecordingAllowed = CGPreflightScreenCaptureAccess()
    }

    private func openSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) else { return }
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }
}

private struct MacEngineReadiness: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var connector: Connector
    let tint: Color

    private var status: String {
        if connector.state == .checking { return "Checking…" }
        if session.harnessBinary() == nil { return "Not installed" }
        switch connector.state {
        case .checking: return "Checking…"
        case .missing: return "Not installed"
        case .signedOut: return "Sign in to continue"
        case .connected: return "Connected"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(session.engineLabel, systemImage: "cpu")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ConnectCard(connector: connector, name: session.sheet.name, tint: tint)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        if connector.working.isEmpty && connector.state != .checking { connector.refresh() }
    }
}
