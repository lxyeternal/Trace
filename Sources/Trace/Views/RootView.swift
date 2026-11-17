import SwiftUI
import TraceCore

extension Pane {
    var title: String {
        switch self {
        case .overview: return L("Overview")
        case .timeline: return L("Timeline")
        case .focus: return L("Focus")
        case .reports: return L("Reports")
        case .tags: return L("Tags")
        case .rules: return L("Rules")
        }
    }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .timeline: return "list.bullet.indent"
        case .focus: return "scope"
        case .reports: return "chart.bar"
        case .tags: return "tag"
        case .rules: return "line.3.horizontal.decrease"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var watcher: ActivityWatcher

    var body: some View {
        content
        .ignoresSafeArea()
        .sheet(isPresented: $model.showsOnboarding) {
            OnboardingView()
                .environmentObject(model)
                .environmentObject(watcher)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $model.showsTour) {
            TourView().environmentObject(model)
        }
    }

    private var content: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 220)
                .background(MaterialBackground(material: .sidebar))
            Rectangle().fill(Theme.line).frame(width: 1)
            VStack(spacing: 0) {
                if !watcher.isTrusted && !model.showsOnboarding { PermissionBanner() }
                if let notice = model.sessionNotice { SessionNoticeBanner(notice: notice) }
                Group {
                    switch model.pane {
                    case .overview: OverviewView()
                    case .timeline: TimelineView()
                    case .focus: FocusView()
                    case .reports: ReportsView()
                    case .tags: TagsView()
                    case .rules: RulesView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .id(model.pane)
                .transition(.opacity)
                .animation(.easeOut(duration: 0.16), value: model.pane)
            }
            .background(Theme.bg)
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.ink)
        .monospacedDigit()
    }
}

enum WindowMetrics {
    /// The window has no visible title bar, but its top strip (28 points)
    /// still moves the window when dragged. Pages keep their buttons below
    /// it: a click with the slightest movement would otherwise nudge the window.
    static let pageTopInset: CGFloat = 34
}

/// Standard padding and scrolling for a page.
struct Page<Content: View>: View {
    @ViewBuilder var content: Content
    private let topInset = WindowMetrics.pageTopInset

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }
                .padding(EdgeInsets(top: topInset, leading: 32, bottom: 32, trailing: 32))
        }
    }
}

private struct Sidebar: View {
    @EnvironmentObject private var model: AppModel

    private var deviceLabel: String {
        switch model.deviceFilter {
        case nil: return L("All Macs")
        case "": return model.deviceName
        case let id?: return model.deviceName(forDevice: id)
        }
    }

    /// A Mac's name followed by its time on the selected day.
    private func menuTitle(_ name: String, device: String) -> String {
        guard let seconds = model.deviceTotals[device], seconds >= 1 else { return name }
        return "\(name)  –  \(Fmt.duration(seconds))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                BrandMark()
                Text("Trace").font(.system(size: 16, weight: .bold)).tracking(-0.2)
            }
            .padding(.horizontal, 8)

            VStack(spacing: 2) {
                ForEach(Pane.allCases) { pane in
                    let isOn = model.pane == pane
                    Button { model.pane = pane } label: {
                        HStack(spacing: 10) {
                            Image(systemName: pane.icon)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 16)
                            Text(pane.title)
                                .fontWeight(isOn ? .semibold : .medium)
                                .foregroundStyle(isOn ? Theme.ink : Theme.muted)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 32)
                        .background(isOn ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }

            if !model.devices.isEmpty {
                Menu {
                    Button(L("All Macs")) { model.deviceFilter = nil }
                    Divider()
                    Button(menuTitle(model.deviceName + " · " + L("this Mac"), device: "")) { model.deviceFilter = "" }
                    ForEach(model.devices) { device in
                        Button(menuTitle(device.displayName, device: device.id)) { model.deviceFilter = device.id }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "laptopcomputer").font(.system(size: 12, weight: .medium)).frame(width: 16)
                        Text(deviceLabel).fontWeight(.medium).lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.line))
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .accessibilityLabel(L("Show records from"))
            }

            if !model.summary.byTag.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.isToday ? L("TODAY") : Fmt.day(model.day))
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 8)
                    ForEach(model.summary.byTag.prefix(8)) { total in
                        SidebarTagRow(total: total)
                    }
                }
            }

            Spacer(minLength: 0)

            VStack(spacing: 8) {
                SettingsLink {
                    HStack(spacing: 10) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 13, weight: .medium)).frame(width: 16)
                        Text(L("Settings")).fontWeight(.medium)
                        Spacer()
                    }
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 8)
                    .frame(height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if model.running != nil { RunningSessionPill() }
                RecordingStatus()
            }
        }
        .padding(EdgeInsets(top: 46, leading: 12, bottom: 16, trailing: 12))
    }
}

/// A tag and its time for the day; a click opens the timeline for that tag.
private struct SidebarTagRow: View {
    @EnvironmentObject private var model: AppModel
    let total: TagTotal
    @State private var hovering = false

    var body: some View {
        let isOn = model.pane == .timeline && model.tagFilter == total.id
        Button { model.showTag(total.id) } label: {
            HStack(spacing: 10) {
                Swatch(total.tag)
                Text(tagName(total.tag)).lineLimit(1).fontWeight(isOn ? .semibold : .regular)
                Spacer(minLength: 4)
                Text(Fmt.duration(total.seconds)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isOn || hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L("Show this tag in the timeline"))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Bottom of the sidebar: whether Trace is recording, and what.
struct RecordingStatus: View {
    @EnvironmentObject private var watcher: ActivityWatcher

    private var state: (title: String, color: Color) {
        if watcher.isPaused { return (L("Paused"), Palette.color(3)) }
        if watcher.isIdle { return (L("Away"), Theme.muted) }
        return (L("Recording"), Theme.accent)
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(state.color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(state.title).fontWeight(.semibold)
                if let current = watcher.current {
                    Text(current.headline)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if !watcher.isPaused, !watcher.background.isEmpty {
                    // What is heard or on a call right now, in front or not.
                    HStack(spacing: 4) {
                        Image(systemName: watcher.background.contains { $0.layer == .mic } ? "phone.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 8))
                        Text(Set(watcher.background.map(\.appName)).sorted().joined(separator: L(", ")))
                            .lineLimit(1)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
                }
            }
            Spacer(minLength: 4)
            IconButton(symbol: watcher.isPaused ? "play.fill" : "pause.fill",
                       label: watcher.isPaused ? L("Resume recording") : L("Pause recording")) {
                watcher.isPaused.toggle()
            }
        }
        .padding(10)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Explains why Accessibility access is needed and how to grant it.
struct PermissionBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield").font(.system(size: 20)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Accessibility permission needed")).fontWeight(.semibold)
                Text(L("Trace uses it to read window titles, file paths and page URLs. It never records keystrokes or screen contents."))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            Button(L("Open System Settings")) {
                AXReader.requestTrust()
                AXReader.openSettings()
            }
            .buttonStyle(.trProminent)
        }
        .padding(14)
        .background(Theme.soft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(EdgeInsets(top: WindowMetrics.pageTopInset, leading: 28, bottom: 0, trailing: 28))
    }
}

/// Says what happened to a session while the user was away, with a way back.
struct SessionNoticeBanner: View {
    @EnvironmentObject private var model: AppModel
    let notice: SessionNotice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: notice.kind == .ended ? "moon.zzz" : "figure.walk")
                .font(.system(size: 18)).foregroundStyle(Theme.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title).fontWeight(.semibold)
                Text(notice.detail).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(2)
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            Button(notice.undoTitle) { model.undoSessionNotice() }.buttonStyle(.trBordered)
            IconButton(symbol: "xmark", label: L("Dismiss")) { model.sessionNotice = nil }
        }
        .padding(14)
        .background(Theme.soft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(EdgeInsets(top: WindowMetrics.pageTopInset, leading: 28, bottom: 0, trailing: 28))
        .transition(.opacity)
    }
}

/// The session that is running, with its clock and a stop button.
struct RunningSessionPill: View {
    @EnvironmentObject private var model: AppModel
    /// Without the tinted box, for the menu bar panel.
    var plain = false

    var body: some View {
        if let session = model.running, let tag = model.tags.first(where: { $0.id == session.tagID }) {
            let elapsed = session.duration(at: model.clock)
            HStack(spacing: 8) {
                Swatch(tag, size: 8, round: true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(tag.displayName).fontWeight(.semibold).lineLimit(1)
                    Text(session.target.map { String(format: L("%@ left"), Fmt.clock($0 - elapsed)) } ?? Fmt.clock(elapsed))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .monospacedDigit()
                }
                Spacer(minLength: 4)
                Button(L("Stop")) { model.stopSession() }
                    .buttonStyle(TRButtonStyle(kind: .bordered, height: 24))
            }
            .padding(plain ? 0 : 10)
            .background(Palette.color(tag).opacity(plain ? 0 : 0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { model.pane = .focus }
            .help(L("Everything you do now counts towards this tag"))
        }
    }
}
