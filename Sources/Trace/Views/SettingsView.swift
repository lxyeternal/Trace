import AppKit
import SwiftUI
import TraceCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    private enum Tab: String, CaseIterable, Identifiable {
        case general, recording, privacy, sync, data
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return L("General")
            case .recording: return L("What is recorded")
            case .privacy: return L("Privacy and exclusions")
            case .sync: return L("Sync")
            case .data: return L("Data and export")
            }
        }
    }

    @State private var tab: Tab = .general
    @State private var confirmsErase = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 2) {
                ForEach(Tab.allCases) { item in
                    let isOn = tab == item
                    Button { tab = item } label: {
                        Text(item.title)
                            .fontWeight(isOn ? .semibold : .medium)
                            .foregroundStyle(isOn ? Theme.ink : Theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .background(isOn ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
                Spacer()
            }
            .padding(EdgeInsets(top: 16, leading: 10, bottom: 16, trailing: 10))
            .frame(width: 180)
            .background(Theme.side)
            Rectangle().fill(Theme.line).frame(width: 1)

            VStack(alignment: .leading, spacing: 18) {
                Text(tab.title).font(.system(size: 18, weight: .bold))
                switch tab {
                case .general: general
                case .recording: recording
                case .privacy: privacy
                case .sync: sync
                case .data: data
                }
                Spacer(minLength: 0)
                Text(model.syncFolder == nil
                     ? L("All data stays on this Mac. Trace never connects to the network.")
                     : L("Trace itself never connects to the network. Records are also written to your sync folder."))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
            .padding(EdgeInsets(top: 24, leading: 28, bottom: 24, trailing: 28))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.panel)
        }
        .frame(width: 760, height: 520)
        .font(.system(size: 13))
        .foregroundStyle(Theme.ink)
    }

    // MARK: Panes

    @ViewBuilder private var general: some View {
        row(L("Appearance"), L("Light, dark, or follow the macOS setting")) {
            Segmented(options: [(Appearance.light, L("Light")), (.dark, L("Dark")), (.system, L("System"))],
                      selection: $model.appearance)
        }
        row(L("Language"), L("Interface language; takes effect at once")) {
            Picker(L("Language"), selection: $model.language) {
                Text(L("System")).tag(AppLanguage.system)
                Text("简体中文").tag(AppLanguage.zhHans)
                Text("English").tag(AppLanguage.en)
                Text("Русский").tag(AppLanguage.ru)
            }
            .labelsHidden()
            .fixedSize()
        }
        row(L("Launch at login"), L("Start recording from the menu bar after you log in")) {
            Toggle(L("Launch at login"), isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        row(L("Idle time"), L("With no keyboard or mouse input for this long you count as away, unless you are on a call or the app in front is playing sound")) {
            Picker(L("Idle time"), selection: $model.idleMinutes) {
                ForEach([1, 3, 5, 10, 15], id: \.self) { Text(String(format: L("%d min"), $0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        row(L("Background sound counts too"), L("Also stay counted while music or a podcast plays in the background. Leave it off if sound often plays when you are not at the Mac.")) {
            Toggle(L("Background sound counts too"), isOn: $model.anySoundMeansPresent).toggleStyle(.switch).labelsHidden()
        }
        row(L("Sessions notice when you leave"), L("Away for 15 minutes to 2 hours is left out of a running session. Longer, or a Mac asleep for 30 minutes, ends it at the moment you left. Off: a session runs until you stop it."), last: true) {
            Toggle(L("Sessions notice when you leave"), isOn: $model.pausesSessionsWhenAway).toggleStyle(.switch).labelsHidden()
        }
    }

    @ViewBuilder private var recording: some View {
        row(L("Window titles"), L("The title of the window in front, e.g. a document or chat name")) {
            Toggle(L("Window titles"), isOn: $model.captureTitles).toggleStyle(.switch).labelsHidden()
        }
        row(L("Telegram chat names"), L("Group time by the open chat in Telegram for Mac")) {
            Toggle(L("Telegram chat names"), isOn: $model.captureTelegramChats)
                .toggleStyle(.switch).labelsHidden().disabled(!model.captureTitles)
        }
        row(L("File paths"), L("The file open in document-based apps")) {
            Toggle(L("File paths"), isOn: $model.captureFiles).toggleStyle(.switch).labelsHidden()
        }
        row(L("Web addresses"), L("The page address in browsers, stored without the query string")) {
            Toggle(L("Web addresses"), isOn: $model.captureURLs).toggleStyle(.switch).labelsHidden()
        }
        row(L("Sound and calls"), L("Which apps are playing sound or using the microphone, also in the background. Not what is played or said.")) {
            Toggle(L("Sound and calls"), isOn: $model.captureBackground).toggleStyle(.switch).labelsHidden()
        }
        row(L("All open apps"), L("Every app that is open while you are at the Mac, and whether its window is on screen. Shown beside the app in front; it does not add to tracked time."), last: true) {
            Toggle(L("All open apps"), isOn: $model.captureOpenApps).toggleStyle(.switch).labelsHidden()
        }
        Text(L("The app in front and how long you stay are always recorded. Keystrokes and screen contents never are."))
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted)
    }

    @ViewBuilder private var privacy: some View {
        AppExclusionList()
    }

    @ViewBuilder private var sync: some View {
        let iCloud = model.iCloudFolder
        let usesICloud = model.syncFolder != nil && model.syncFolder == iCloud?.path
        row(L("Sync with iCloud"),
            iCloud == nil ? L("iCloud Drive is not turned on for this Mac. Turn it on in System Settings, or use another folder below.")
                          : L("Keeps your records backed up in iCloud Drive and in step across your Macs. Nothing to set up."),
            last: model.syncFolder == nil) {
            Toggle(L("Sync with iCloud"), isOn: Binding(
                get: { usesICloud },
                set: { on in
                    if on, let iCloud { model.enableSync(folder: iCloud) } else { model.disableSync() }
                }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(iCloud == nil || (model.syncFolder != nil && !usesICloud))
        }
        if let folder = model.syncFolder {
            row(usesICloud ? L("Stored in") : L("Sync folder"), Analyzer.abbreviate(folder), mono: true) {
                Button(L("Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
                }
                .buttonStyle(.trBordered)
            }
            SyncStatusRow()
            Hairline()
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(L("Macs")).fontWeight(.semibold)
                    Text(L("Click a name to change it, for example Home and Lab"))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                deviceRow(name: $model.deviceName, placeholder: Host.current().localizedName ?? "Mac",
                          note: L("this Mac")) { model.syncNow() }
                ForEach(model.devices) { device in
                    DeviceNameRow(device: device)
                }
            }
            if !usesICloud {
                Hairline()
                row(L("Stop syncing"), L("Removes the other Macs' records from this Mac. The files in the folder are kept."), last: true) {
                    Button(L("Stop syncing")) { model.disableSync() }.buttonStyle(.trBordered)
                }
            }
        } else {
            if let error = model.syncError {
                Text(error).font(.system(size: 12)).foregroundStyle(Palette.color(4))
            }
            Text(L("Sync is off until you turn it on. Your records are then also stored in iCloud Drive as readable files, in a folder named Trace. Turning it off removes the other Macs' records from this Mac and leaves the files in place."))
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("Use another folder instead…")) { model.chooseSyncFolder() }
                .buttonStyle(.trLink)
                .font(.system(size: 12))
        }
    }

    private func deviceRow(name: Binding<String>, placeholder: String, note: String,
                           commit: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "laptopcomputer").foregroundStyle(Theme.muted).frame(width: 20)
            TextField(placeholder, text: name)
                .textFieldStyle(.plain)
                .onSubmit(commit)
                .padding(.horizontal, 8)
                .frame(width: 220, height: 26)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.line))
            Spacer()
            Text(note).font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
    }

    @ViewBuilder private var data: some View {
        row(L("Data location"), model.databaseURL.map { Analyzer.abbreviate($0.path) } ?? L("In memory only"), mono: true) {
            Button(L("Show in Finder")) { model.revealDatabase() }
                .buttonStyle(.trBordered)
                .disabled(model.databaseURL == nil)
        }
        row(L("Export"), L("Every record as a CSV file, one row per stay")) {
            Button(L("Export CSV")) {
                model.exportCSV(DateInterval(start: .distantPast, end: Date()), name: L("All records"))
            }
            .buttonStyle(.trBordered)
        }
        row(L("Erase records"), L("Deletes every recorded stay. Tags and rules are kept. This cannot be undone."), last: true) {
            Button(L("Erase…")) { confirmsErase = true }
                .buttonStyle(.trBordered)
                .foregroundStyle(Palette.color(4))
        }
        .confirmationDialog(L("Erase every record?"), isPresented: $confirmsErase) {
            Button(L("Erase all records"), role: .destructive) { model.eraseAllRecords() }
        } message: {
            Text(L("Deletes every recorded stay. Tags and rules are kept. This cannot be undone."))
        }
    }

    // MARK: Helpers

    private func row<Control: View>(_ title: String, _ note: String, mono: Bool = false, last: Bool = false,
                                    @ViewBuilder control: () -> Control) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).fontWeight(.semibold)
                    Text(note).font(mono ? Theme.mono : .system(size: 12)).foregroundStyle(Theme.muted)
                        .lineLimit(2).truncationMode(.middle)
                }
                Spacer(minLength: 12)
                control()
            }
            if !last { Hairline() }
        }
    }
}

/// One other Mac in the Sync pane, with a name that can be changed here.
private struct DeviceNameRow: View {
    @EnvironmentObject private var model: AppModel
    let device: SyncedDevice
    @State private var name = ""

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "laptopcomputer").foregroundStyle(Theme.muted).frame(width: 20)
            TextField(device.name, text: $name)
                .textFieldStyle(.plain)
                .onSubmit { model.renameDevice(device, to: name) }
                .padding(.horizontal, 8)
                .frame(width: 220, height: 26)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.line))
            if name != device.displayName {
                Button(L("Save")) { model.renameDevice(device, to: name) }
                    .buttonStyle(TRButtonStyle(kind: .bordered, height: 26))
            }
            Spacer()
            Text(device.lastSeen.map { String(format: L("last synced %@"), Fmt.dateTime($0)) } ?? "")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
        }
        .onAppear { name = device.displayName }
        .onChange(of: device.displayName) { name = device.displayName }
    }
}

/// Whether the last sync worked, when it happened and when the next one is due.
private struct SyncStatusRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if model.isSyncing {
                    ProgressView().controlSize(.small)
                } else if model.syncError != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.color(4))
                } else if model.lastSync != nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                } else {
                    Image(systemName: "circle.dashed").foregroundStyle(Theme.muted)
                }
            }
            .font(.system(size: 22))
            .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.semibold).foregroundStyle(model.syncError == nil && model.lastSync != nil && !model.isSyncing ? Theme.ok : Theme.ink)
                Text(note).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(2)
            }
            Spacer(minLength: 12)
            Button(model.isSyncing ? L("Syncing…") : L("Sync now")) { model.syncNow() }
                .buttonStyle(.trBordered)
                .disabled(model.isSyncing)
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        if model.isSyncing { return L("Syncing…") }
        if model.syncError != nil { return L("Sync failed") }
        if let last = model.lastSync { return String(format: L("Synced at %@"), Fmt.time(last)) }
        return L("Not synced yet")
    }

    private var note: String {
        if let error = model.syncError { return error }
        guard let next = model.nextSync else { return L("Syncs by itself every 5 minutes") }
        return String(format: L("Syncs by itself every 5 minutes; next at about %@"), Fmt.time(next))
    }
}

/// An app installed on this Mac.
struct InstalledApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    /// Comes with macOS, or lives in a Utilities folder.
    let isSystem: Bool
    var id: String { bundleID }

    /// Every app in the usual places, one entry per bundle identifier.
    static func scan() -> [InstalledApp] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let roots: [(String, Bool)] = [("/Applications", false), ("\(home)/Applications", false),
                                       ("/Applications/Utilities", true), ("/System/Applications", true),
                                       ("/System/Applications/Utilities", true)]
        var found: [String: InstalledApp] = [:]
        func add(_ path: String, system: Bool) {
            guard let bundle = Bundle(path: path), let id = bundle.bundleIdentifier,
                  id != Bundle.main.bundleIdentifier, found[id] == nil else { return }
            let name = fm.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
            found[id] = InstalledApp(bundleID: id, name: name, isSystem: system)
        }
        for (root, system) in roots {
            for item in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
                let path = "\(root)/\(item)"
                if item.hasSuffix(".app") {
                    add(path, system: system)
                } else if !item.hasPrefix("."), item != "Utilities" {
                    // One level down, for suites that install into a folder.
                    for inner in (try? fm.contentsOfDirectory(atPath: path)) ?? [] where inner.hasSuffix(".app") {
                        add("\(path)/\(inner)", system: system)
                    }
                }
            }
        }
        return Array(found.values)
    }
}

/// Every installed app with a switch: on is recorded, off is left out.
/// The apps used most come first; what ships with macOS is listed apart.
private struct AppExclusionList: View {
    @EnvironmentObject private var model: AppModel
    @State private var apps: [InstalledApp] = []
    @State private var usage: [String: TimeInterval] = [:]
    @State private var search = ""
    @State private var isLoading = true

    var body: some View {
        let excluded = Set(model.excludedApps)
        let shown = apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(L("Apps that are recorded")).fontWeight(.semibold)
                    Text(excluded.isEmpty ? L("Switch an app off and time in it is not recorded at all")
                                          : String(format: L("%d apps are switched off and not recorded"), excluded.count))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 12)
                SearchField(text: $search, placeholder: L("Search apps"), width: 140)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    if isLoading {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                    section(L("YOUR APPS"), shown.filter { !$0.isSystem }, excluded)
                    section(L("SYSTEM APPS AND TOOLS"), shown.filter(\.isSystem), excluded)
                    if !isLoading && shown.isEmpty {
                        Text(L("No app matches the search.")).foregroundStyle(Theme.muted).padding(.vertical, 12)
                    }
                }
                .padding(.trailing, 6)
            }
        }
        .task { await load() }
    }

    @ViewBuilder private func section(_ title: String, _ apps: [InstalledApp], _ excluded: Set<String>) -> some View {
        if !apps.isEmpty {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(Theme.muted)
                .padding(.top, 10)
                .padding(.bottom, 4)
            ForEach(apps) { app in
                let isOn = !excluded.contains(app.bundleID)
                HStack(spacing: 10) {
                    AppIcon(bundleID: app.bundleID, size: 24)
                    Text(app.name).lineLimit(1).foregroundStyle(isOn ? Theme.ink : Theme.muted)
                    if let seconds = usage[app.bundleID], seconds >= 60 {
                        Text(String(format: L("%@ in 30 days"), Fmt.duration(seconds)))
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 8)
                    if !isOn {
                        Text(L("not recorded")).font(.system(size: 12)).foregroundStyle(Palette.color(3))
                    }
                    Toggle(app.name, isOn: Binding(get: { isOn }, set: { on in
                        if on {
                            model.excludedApps.removeAll { $0 == app.bundleID }
                        } else if !model.excludedApps.contains(app.bundleID) {
                            model.excludedApps.append(app.bundleID)
                        }
                    }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                }
                .padding(.vertical, 6)
                Hairline()
            }
        }
    }

    private func load() async {
        let month = DateInterval(start: Date().addingTimeInterval(-30 * 86_400), end: Date())
        var totals: [String: TimeInterval] = [:]
        var names: [String: String] = [:]
        for event in model.events(in: month) where event.isLocal {
            totals[event.bundleID, default: 0] += Analyzer.clipped(event, to: month)
            names[event.bundleID] = event.appName
        }
        var found = await Task.detached(priority: .userInitiated) { InstalledApp.scan() }.value
        // Apps that were recorded or switched off but are not in the usual places.
        let known = Set(found.map(\.bundleID))
        for id in Set(totals.keys).union(model.excludedApps) where !known.contains(id) && id != Bundle.main.bundleIdentifier {
            let name = names[id] ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
            found.append(InstalledApp(bundleID: id, name: name, isSystem: false))
        }
        usage = totals
        apps = found.sorted {
            let (a, b) = (totals[$0.bundleID] ?? 0, totals[$1.bundleID] ?? 0)
            return a != b ? a > b : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        isLoading = false
    }
}
