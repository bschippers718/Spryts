import AppKit
import SwiftUI

/// A compact view of the same live sessions shown in Team. No inferred availability or progress.
struct DeskTeamPreview: View {
    let sessions: [ChatSession]
    let chiefID: String
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(text: "Your team")
                Spacer()
                Button("View Team", action: onOpen).buttonStyle(.link)
                    .font(.system(size: 12))
            }
            VStack(spacing: 0) {
                ForEach(sessions.filter { $0.sheet.id != chiefID && $0.sheet.role != "companion" }, id: \.sheet.id) { member in
                    DeskMemberRow(session: member, compact: true)
                        .padding(.vertical, 7)
                }
            }
            .solidCard(corner: 12, padding: 14)
        }
    }
}

struct DeskTeamView: View {
    let sessions: [ChatSession]
    @ObservedObject var chief: ChatSession
    let tint: Color
    @ObservedObject private var coordinator = TeamCoordinator.shared
    @State private var expandedJobs: Set<String> = []
    @State private var showAllJobs = false

    private var jobs: [TeamJob] {
        coordinator.jobs.sorted {
            if $0.status.isActive != $1.status.isActive { return $0.status.isActive }
            return $0.updatedAt > $1.updatedAt
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Better together.").font(.system(size: 22, weight: .bold))
                Text("\(chief.sheet.name) coordinates the work. Each Spryt brings their own expertise, and every handoff stays visible here.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "Specialists")
                ForEach(sessions.filter { $0.sheet.id != chief.sheet.id && $0.sheet.role != "companion" }, id: \.sheet.id) { member in
                    DeskMemberRow(session: member, compact: false)
                        .solidCard(corner: 12, padding: 14)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionTitle(text: "Delegated work")
                    Spacer()
                    Button("Plan with \(chief.sheet.name)", systemImage: "text.bubble") {
                        chief.prefillDraft("Help me plan a project and bring in the right Spryts. ")
                        chief.focusTick += 1
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(chief.busy)
                }
                if let error = coordinator.storageError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .solidCard(corner: 12, padding: 14)
                }
                if jobs.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("One request. The right team.").font(.system(size: 13, weight: .semibold))
                        Text("Ask \(chief.sheet.name) to delegate a coding, writing, training, or weather task. You’ll see who owns it, what’s happening, and the result.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .solidCard(corner: 12, padding: 16)
                } else {
                    ForEach(jobs.prefix(showAllJobs ? jobs.count : 30)) { job in
                        jobRow(job)
                    }
                    if !showAllJobs && jobs.count > 30 {
                        Button("Show earlier work") { showAllJobs = true }.buttonStyle(.link)
                    }
                }
            }
        }
    }

    private func jobRow(_ job: TeamJob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(job.status.label, systemImage: job.status.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(job.status.isActive ? tint : Color.secondary)
                Spacer()
                Text(job.updatedAt, style: .relative)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .help(job.updatedAt.formatted(date: .abbreviated, time: .shortened))
            }
            Text(job.task).font(.system(size: 13, weight: .medium))
                .lineLimit(expandedJobs.contains(job.id) ? nil : 3)
                .textSelection(.enabled)
            HStack(spacing: 5) {
                Text(job.fromName ?? job.from)
                Image(systemName: "arrow.right").font(.system(size: 9))
                Text(job.toName ?? job.to)
                Spacer()
                if let target = sessions.first(where: {
                    $0.sheet.id.lowercased() == job.to.lowercased()
                    || $0.sheet.role?.lowercased() == job.to.lowercased()
                    || $0.sheet.name.lowercased() == job.to.lowercased()
                }), target.onOpenWorkspace != nil {
                    Button("Open") { target.onOpenWorkspace?() }
                        .buttonStyle(.link)
                }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            if let detail = job.detail, !detail.isEmpty {
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(expandedJobs.contains(job.id) ? nil : 2)
            }
            if let result = job.result, !result.isEmpty {
                DisclosureGroup(isExpanded: Binding(
                    get: { expandedJobs.contains(job.id) },
                    set: { if $0 { expandedJobs.insert(job.id) } else { expandedJobs.remove(job.id) } }
                )) {
                    Text(result)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 7)
                } label: {
                    Text("Result").font(.system(size: 12, weight: .medium))
                }
            } else {
                Button(expandedJobs.contains(job.id) ? "Show less" : "Show full details") {
                    if expandedJobs.contains(job.id) { expandedJobs.remove(job.id) }
                    else { expandedJobs.insert(job.id) }
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
        }
        .solidCard(corner: 12, padding: 14)
    }
}

private struct DeskMemberRow: View {
    @ObservedObject var session: ChatSession
    let compact: Bool

    private var role: String {
        switch session.sheet.role {
        case "coder": return "Programming"
        case "writer": return "Writing"
        case "coach": return "Training"
        case "gamer": return "Games"
        case "forecaster": return "Weather"
        case "generalist": return "Chief of Staff"
        default: return "Companion"
        }
    }

    private var icon: String {
        switch session.sheet.role {
        case "coder": return "chevron.left.forwardslash.chevron.right"
        case "writer": return "pencil.line"
        case "coach": return "figure.run"
        case "gamer": return "gamecontroller"
        case "forecaster": return "cloud.sun"
        default: return "sparkle"
        }
    }

    private var state: String {
        if session.approval != nil { return "Needs approval" }
        if session.busy { return "Working" }
        return "Idle"
    }

    private var detail: String? {
        if let approval = session.approval { return "Waiting to use \(approval.tool)" }
        if session.busy {
            if let step = session.steps.last(where: { $0.state == "running" }) {
                return step.detail.isEmpty ? step.tool : step.detail
            }
            return "Thinking through the next step"
        }
        if let folder = session.projectFolder { return folder.lastPathComponent }
        return nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: compact ? 15 : 18, weight: .medium))
                .foregroundStyle(Color(nsColor: NSColor(hex: session.sheet.look.body)))
                .frame(width: compact ? 22 : 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(session.sheet.name).font(.system(size: 13, weight: .semibold))
                    Text(role).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if !compact, let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Circle().fill(session.approval != nil ? Color.orange : session.busy ? Color.accentColor : Color.secondary.opacity(0.4))
                    .frame(width: 5, height: 5)
                Text(state).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if session.onOpenWorkspace != nil {
                Button {
                    session.onOpenWorkspace?()
                } label: {
                    if compact { Image(systemName: "arrow.up.forward") }
                    else { Text(session.approval != nil ? "Review" : "Open") }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .help("Open \(session.sheet.name)’s \(AppDelegate.placeName(session.sheet.role))")
                .accessibilityLabel("Open \(session.sheet.name)’s \(AppDelegate.placeName(session.sheet.role))")
            }
        }
    }
}
