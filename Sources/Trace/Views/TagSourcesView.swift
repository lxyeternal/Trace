import SwiftUI
import TraceCore

/// Apps and sites that usually go together, offered as one click.
struct SourceGroup: Identifiable {
    let title: String
    /// Parts of an app's name or bundle identifier, lowercased.
    let keywords: [String]
    let sites: [String]
    var id: String { title }

    func apps(among installed: [InstalledApp]) -> [InstalledApp] {
        installed.filter { app in
            let text = (app.name + " " + app.bundleID).lowercased()
            return keywords.contains { text.contains($0) }
        }
    }

    static var all: [SourceGroup] {
        [SourceGroup(title: L("Meetings"),
                     keywords: ["zoom", "tencent.meeting", "腾讯会议", "voov", "welink", "microsoft.teams", "webex",
                                "facetime", "skype", "gotomeeting", "whereby"],
                     sites: ["meeting.tencent.com", "voovmeeting.com", "zoom.us", "zoom.com", "meet.google.com",
                             "teams.microsoft.com", "teams.live.com", "welink.huaweicloud.com", "webex.com",
                             "whereby.com", "meet.jit.si"])]
    }
}

/// Pick the apps and sites that carry a tag: tick apps in the list of what
/// is installed, type the sites.
struct SourcePicker: View {
    @Binding var apps: Set<String>
    @Binding var sites: [String]

    @State private var installed: [InstalledApp] = []
    @State private var query = ""
    @State private var site = ""
    @State private var isLoading = true

    private var shown: [InstalledApp] {
        let matching = installed.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query)
        }
        // What is ticked comes first, so the choice can be read at a glance.
        return matching.filter { apps.contains($0.bundleID) } + matching.filter { !apps.contains($0.bundleID) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(L("Quick pick")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                ForEach(SourceGroup.all) { group in
                    Button { add(group) } label: {
                        Label(group.title, systemImage: "plus")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 9)
                            .frame(height: 24)
                            .background(Theme.fill, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(L("Adds the meeting apps on this Mac and the usual meeting sites"))
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("Apps")).fontWeight(.semibold)
                    if !apps.isEmpty { Badge(text: "\(apps.count)") }
                    Spacer()
                    SearchField(text: $query, placeholder: L("Search apps"), width: 150)
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { app in row(app) }
                        if shown.isEmpty {
                            Text(isLoading ? L("Looking for apps…") : L("No app with that name"))
                                .foregroundStyle(Theme.muted)
                                .frame(maxWidth: .infinity, minHeight: 80)
                        }
                    }
                    .padding(4)
                }
                .frame(height: 230)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L("Sites")).fontWeight(.semibold)
                if !sites.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(sites, id: \.self) { item in
                            HStack(spacing: 5) {
                                Text(item).font(Theme.mono).lineLimit(1)
                                Button { sites.removeAll { $0 == item } } label: {
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.muted)
                                .accessibilityLabel(String(format: L("Remove %@"), item))
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(Theme.fill, in: Capsule())
                        }
                    }
                }
                HStack(spacing: 6) {
                    TextField(L("e.g. meet.google.com"), text: $site)
                        .textFieldStyle(.plain)
                        .font(Theme.mono)
                        .onSubmit(addSite)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Button(L("Add"), action: addSite)
                        .buttonStyle(TRButtonStyle(kind: .bordered, height: 30))
                        .disabled(Self.clean(site).isEmpty)
                }
            }
        }
        .task { await load() }
    }

    private func row(_ app: InstalledApp) -> some View {
        let isOn = apps.contains(app.bundleID)
        return Button {
            if isOn { apps.remove(app.bundleID) } else { apps.insert(app.bundleID) }
        } label: {
            HStack(spacing: 10) {
                AppIcon(bundleID: app.bundleID, size: 22)
                Text(app.name).lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isOn ? Theme.accent : Theme.line)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(isOn ? Theme.soft.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func add(_ group: SourceGroup) {
        apps.formUnion(group.apps(among: installed).map(\.bundleID))
        for item in group.sites where !sites.contains(item) { sites.append(item) }
    }

    private func addSite() {
        let value = Self.clean(site)
        guard !value.isEmpty else { return }
        if !sites.contains(value) { sites.append(value) }
        site = ""
    }

    /// "https://Meet.Google.com/abc " becomes "meet.google.com/abc".
    static func clean(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://", "www."] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private func load() async {
        var found = await Task.detached(priority: .userInitiated) { InstalledApp.scan() }.value
        // Apps that are ticked but no longer in the usual places stay listed.
        let known = Set(found.map(\.bundleID))
        for id in apps where !known.contains(id) {
            found.append(InstalledApp(bundleID: id, name: Rule(tagID: 0, field: .app, op: .equals, value: id).shortValue,
                                      isSystem: false))
        }
        installed = found.sorted {
            ($0.isSystem ? 1 : 0, $0.name.lowercased()) < ($1.isSystem ? 1 : 0, $1.name.lowercased())
        }
        isLoading = false
    }
}

/// The apps and sites of an existing tag, in a sheet.
struct TagSourcesSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let tag: Tag
    @State private var apps: Set<String> = []
    @State private var sites: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Swatch(tag, size: 12, round: true)
                Text(String(format: L("What counts as %@"), tag.displayName)).font(.system(size: 16, weight: .bold))
            }
            SourcePicker(apps: $apps, sites: $sites)
            HStack {
                Button(L("More kinds of rules")) { dismiss(); model.pane = .rules }.buttonStyle(.trLink)
                    .help(L("Rules on file paths, window titles and app categories"))
                Spacer()
                Button(L("Cancel")) { dismiss() }.buttonStyle(.trBordered)
                Button(L("Save")) {
                    model.setSources(for: tag, apps: apps, sites: Set(sites))
                    dismiss()
                }
                .buttonStyle(.trProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(Theme.panel)
        .font(.system(size: 13))
        .foregroundStyle(Theme.ink)
        .onAppear {
            let rules = model.rules.filter { $0.tagID == tag.id }
            apps = Set(rules.filter { $0.field == .app && $0.op == .equals }.map(\.value))
            sites = rules.filter { $0.field == .url && $0.op == .contains }.map(\.value)
        }
    }
}
