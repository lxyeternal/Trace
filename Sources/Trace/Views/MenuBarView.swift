import SwiftUI
import TraceCore

/// The panel behind the menu bar icon: today's total at a glance.
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var watcher: ActivityWatcher
    @Environment(\.openWindow) private var openWindow
    /// The list of tags to start a session with is unfolded.
    @State private var picking: Bool
    @State private var minutes: Int?

    init(startsPicking: Bool = false) {
        _picking = State(initialValue: startsPicking)
    }

    private var state: (title: String, color: Color) {
        if watcher.isPaused { return (L("Paused"), Palette.color(3)) }
        if watcher.isIdle { return (L("Away"), Theme.muted) }
        return (L("Recording"), Theme.accent)
    }

    /// What else is going on besides the app in front: calls, sound, windows
    /// on screen and apps open out of sight.
    private var alongside: [(symbol: String, color: Color, title: String, apps: String)] {
        func names(_ list: [String], limit: Int = 6) -> String {
            let sorted = Array(Set(list)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            let shown = sorted.prefix(limit).joined(separator: L(", "))
            return sorted.count > limit ? String(format: L("%@ and %d more"), shown, sorted.count - limit) : shown
        }
        let front = watcher.current?.bundleID
        var lines: [(symbol: String, color: Color, title: String, apps: String)] = []
        let calls = watcher.background.filter { $0.layer == .mic }.map(\.appName)
        let sound = watcher.background.filter { $0.layer == .audio }.map(\.appName)
        let showing = watcher.open.filter { $0.isShowing && $0.bundleID != front }.map(\.appName)
        let hidden = watcher.open.filter { !$0.isShowing && $0.bundleID != front }.map(\.appName)
        if !calls.isEmpty { lines.append(("phone.fill", Theme.accent, L("On a call"), names(calls))) }
        if !sound.isEmpty { lines.append(("speaker.wave.2.fill", Theme.accent, L("Playing sound"), names(sound))) }
        if !showing.isEmpty { lines.append(("macwindow", Theme.muted, L("On screen"), names(showing))) }
        if !hidden.isEmpty { lines.append(("square.stack.3d.down.right", Theme.muted, L("Out of sight"), names(hidden))) }
        return lines
    }

    var body: some View {
        let summary = model.summary
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text("Trace").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Circle().fill(state.color).frame(width: 6, height: 6)
                    Text(state.title).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(L("Tracked today")).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(Fmt.duration(summary.total)).font(.system(size: 28, weight: .bold)).tracking(-0.5)
                }
                if summary.total > 0 {
                    GeometryReader { geo in
                        let usable = geo.size.width - CGFloat(max(summary.byTag.count - 1, 0)) * 2
                        HStack(spacing: 2) {
                            ForEach(summary.byTag) { total in
                                Rectangle().fill(Palette.color(total.tag))
                                    .frame(width: max(2, usable * total.seconds / summary.total))
                            }
                        }
                    }
                    .frame(height: 6)
                    .clipShape(Capsule())
                    .accessibilityHidden(true)
                    VStack(spacing: 5) {
                        ForEach(summary.byTag.prefix(3)) { total in
                            HStack(spacing: 8) {
                                Swatch(total.tag, size: 8)
                                Text(tagName(total.tag))
                                Spacer()
                                Text(Fmt.duration(total.seconds)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            separator
            sectionTitle(L("Current activity"))
            VStack(alignment: .leading, spacing: 1) {
                if let current = watcher.current {
                    HStack(spacing: 8) {
                        AppIcon(bundleID: current.bundleID, size: 18)
                        Text(current.headline).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        if let since = watcher.currentSince {
                            Text(Fmt.duration(max(0, Date().timeIntervalSince(since)))).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(watcher.isPaused ? L("Recording is paused")
                         : watcher.isIdle ? L("Away from the keyboard and mouse")
                         : watcher.isSelfInFront ? L("Trace itself is in front") : L("Nothing in front right now"))
                        .fontWeight(.medium)
                    if !watcher.isPaused, !watcher.isIdle, watcher.isSelfInFront {
                        Text(L("Trace does not record its own window")).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            if !watcher.isPaused, !alongside.isEmpty {
                separator
                sectionTitle(L("Also open now"))
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(alongside, id: \.title) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: line.symbol).font(.system(size: 10)).foregroundStyle(line.color).frame(width: 18)
                            Text(line.title).foregroundStyle(.secondary).fixedSize()
                            Text(line.apps).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 12))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }

            separator
            VStack(spacing: 0) {
                if model.running != nil {
                    RunningSessionPill(plain: true).padding(.horizontal, 14).padding(.vertical, 5)
                } else {
                    // Unfolds in place: a menu on top of this panel would close
                    // each time the panel redraws, which it does every two seconds.
                    Button { picking.toggle() } label: {
                        MenuRowLabel(title: L("Start a session…"), showsChevron: true, isOpen: picking)
                    }
                    .buttonStyle(MenuRowStyle())
                    if picking { sessionPicker }
                }
                Button {
                    if watcher.isPaused { watcher.isPaused = false } else { watcher.pause(for: 15 * 60) }
                } label: {
                    MenuRowLabel(title: watcher.isPaused ? L("Resume") : L("Pause 15 minutes"))
                }
                .buttonStyle(MenuRowStyle())
                Button {
                    AppDelegate.shared?.openMain = { openWindow(id: "main") }
                    AppDelegate.shared?.showMain()
                } label: {
                    MenuRowLabel(title: L("Open Trace"))
                }
                .buttonStyle(MenuRowStyle())
            }
            .padding(.vertical, 4)

            separator
            VStack(spacing: 0) {
                SettingsLink { MenuRowLabel(title: L("Settings…")) }
                    .buttonStyle(MenuRowStyle())
                Button { NSApp.terminate(nil) } label: { MenuRowLabel(title: L("Quit Trace")) }
                    .buttonStyle(MenuRowStyle())
            }
            .padding(.top, 4)
            .padding(.bottom, 5)
        }
        .frame(width: 300)
        .background(MaterialBackground(material: .menu).ignoresSafeArea())
        .font(.system(size: 13))
        .monospacedDigit()
        .onAppear { model.goToToday(); model.reload() }
    }

    /// How long, then which tag: a click on a tag starts the session.
    private var sessionPicker: some View {
        let tags = model.tags.filter(\.enabled)
        let lengths: [Int?] = [nil, 25, 50, 60, 120]
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                ForEach(lengths, id: \.self) { length in
                    let isOn = length == minutes
                    Button { minutes = length } label: {
                        Text(length.map { Fmt.duration(TimeInterval($0 * 60)) } ?? L("Until I stop"))
                            .font(.system(size: 11, weight: isOn ? .semibold : .regular))
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .frame(height: 22)
                            .frame(maxWidth: length == nil ? .infinity : nil)
                            .background(.primary.opacity(isOn ? 0.14 : 0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(tags) { tag in
                        Button {
                            model.startSession(tag, minutes: minutes)
                            picking = false
                        } label: {
                            HStack(spacing: 8) {
                                Swatch(tag, size: 8, round: true)
                                Text(tag.displayName).lineLimit(1)
                                Spacer(minLength: 8)
                                Image(systemName: "play.fill").font(.system(size: 8)).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(MenuRowStyle())
                    }
                }
            }
            .frame(height: min(CGFloat(tags.count) * 24, 216))
        }
        .padding(.bottom, 4)
    }

    private var separator: some View {
        Rectangle().fill(.primary.opacity(0.1)).frame(height: 1).padding(.horizontal, 14)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 5)
    }
}

/// The contents of a row that looks and behaves like a menu item.
private struct MenuRowLabel: View {
    let title: String
    var showsChevron = false
    var isOpen = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 12)
            if showsChevron {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
        }
    }
}

/// A full-width row that lights up under the pointer, like a menu item.
private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .background(.primary.opacity(configuration.isPressed ? 0.16 : (hovering ? 0.09 : 0)),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
                .padding(.horizontal, 6)
                .onHover { hovering = $0 }
        }
    }
}
