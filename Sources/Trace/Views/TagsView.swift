import SwiftUI
import TraceCore

/// Time and distinct apps per tag over the current week.
struct TagWeekStats {
    var seconds: [Int64: TimeInterval] = [:]
    var apps: [Int64: Set<String>] = [:]
}

struct TagsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var stats = TagWeekStats()
    @State private var showsForm = false

    private let columns = [GridItem(.adaptive(minimum: 230), spacing: 12, alignment: .top)]

    var body: some View {
        let presets = model.tags.filter(\.isPreset)
        let customs = model.tags.filter { !$0.isPreset }
        Page {
            PageHeader(title: L("Tags"),
                       hint: L("A record can carry several tags; automatic ones can always be changed")) {
                Button(L("New tag")) { showsForm = true }.buttonStyle(.trProminent)
            }
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: L("Preset tags"),
                             note: L("Matched from the category each app declares to macOS and from well-known sites"))
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(presets) { tag in TagCard(tag: tag, stats: stats) }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: L("Custom tags"),
                             note: L("Name it, pick a colour, apply it by hand or add a rule to apply it automatically"))
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(customs) { tag in TagCard(tag: tag, stats: stats) }
                    Button { showsForm = true } label: {
                        Text(L("New tag"))
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity, minHeight: 124)
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if showsForm {
                NewTagForm { showsForm = false }
            }
        }
        .task(id: model.revision) { stats = load() }
    }

    private func load() -> TagWeekStats {
        var stats = TagWeekStats()
        let week = model.weekInterval
        for event in model.events(in: week) {
            let seconds = Analyzer.clipped(event, to: week)
            for tag in model.tagger.tags(for: event) {
                guard let id = tag.id else { continue }
                stats.seconds[id, default: 0] += seconds
                stats.apps[id, default: []].insert(event.bundleID)
            }
        }
        return stats
    }
}

private struct TagCard: View {
    @EnvironmentObject private var model: AppModel
    let tag: Tag
    let stats: TagWeekStats

    @State private var editsGoal = false
    @State private var editsSources = false
    @State private var renames = false
    @State private var deletes = false
    @State private var newName = ""

    private var rules: [Rule] { model.rules.filter { $0.tagID == tag.id } }
    private var goal: Goal? { model.goals.first { $0.tagID == tag.id } }

    private func chip(_ text: String, symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Theme.bg, in: Capsule())
        .contentShape(Capsule())
    }

    var body: some View {
        let id = tag.id ?? 0
        Card(padding: .hv(16, 14)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Swatch(tag, size: 12, round: true)
                    Text(tag.displayName).font(.system(size: 15, weight: .bold)).lineLimit(1)
                    Spacer()
                    if tag.isPreset {
                        Toggle(tag.displayName, isOn: Binding(get: { tag.enabled }, set: { model.setTag(tag, enabled: $0) }))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                    Menu {
                        Button(L("Rename…")) { newName = tag.displayName; renames = true }
                        Button(L("Apps and sites…")) { editsSources = true }
                        Button(L("Edit rules")) { model.pane = .rules }
                        if !tag.isPreset {
                            Divider()
                            Button(L("Delete tag"), role: .destructive) { deletes = true }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.muted)
                            .frame(width: 28, height: 28)
                            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel(String(format: L("Edit tag %@"), tag.displayName))
                }
                Text(ruleSummary)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
                HStack(spacing: 6) {
                    Menu {
                        ForEach(TagRole.allCases, id: \.self) { role in
                            Button(role.title) { model.setRole(role, for: tag) }
                        }
                    } label: {
                        chip(tag.role.title, symbol: tag.role == .focus ? "scope" : (tag.role == .distraction ? "moon.zzz" : "circle.dashed"))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(L("How this tag counts when judging focus"))
                    Button { editsGoal = true } label: {
                        chip(goal?.summary ?? L("Set goal"), symbol: "target")
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $editsGoal) {
                        GoalEditor(tag: tag) { editsGoal = false }.environmentObject(model)
                    }
                    Spacer(minLength: 0)
                }
                Hairline()
                HStack {
                    Text(footnote).foregroundStyle(Theme.muted)
                    Spacer()
                    Text(L("This week") + " " + Fmt.duration(stats.seconds[id] ?? 0)).fontWeight(.semibold)
                }
                .font(.system(size: 12))
            }
            .opacity(tag.enabled ? 1 : 0.5)
        }
        .sheet(isPresented: $editsSources) { TagSourcesSheet(tag: tag).environmentObject(model) }
        .alert(L("Rename tag"), isPresented: $renames) {
            TextField(L("Name"), text: $newName)
            Button(L("Save")) { model.renameTag(tag, to: newName) }
            Button(L("Cancel"), role: .cancel) {}
        }
        .confirmationDialog(String(format: L("Delete the tag %@?"), tag.displayName), isPresented: $deletes) {
            Button(L("Delete"), role: .destructive) { model.deleteTag(tag) }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Its rules, goal and sessions go with it. Records are kept."))
        }
    }

    private var footnote: String {
        if tag.isPreset {
            return String(format: L("Matched %d apps"), stats.apps[tag.id ?? 0]?.count ?? 0)
        }
        return rules.isEmpty ? L("Manual only") : String(format: L("Automatic · %d rules"), rules.count)
    }

    private var ruleSummary: String {
        if rules.isEmpty { return L("No rules") }
        if !tag.isPreset, rules.count == 1, let rule = rules.first, rule.field != .app {
            return "\(rule.field.displayName) \(rule.op.displayName) \(rule.value)"
        }
        return rules.prefix(5).map(\.shortValue).joined(separator: L(", "))
    }
}

extension Rule {
    /// Names for the preset apps, used when the app is not installed.
    private static let knownApps = [
        "com.figma.Desktop": "Figma", "company.thebrowser.Browser": "Arc", "com.bohemiancoding.sketch3": "Sketch",
        "com.googlecode.iterm2": "iTerm", "com.tinyspeck.slackmacgap": "Slack", "com.tencent.xinWeChat": "WeChat",
        "us.zoom.xos": "Zoom", "com.microsoft.teams2": "Teams", "com.electron.lark": "Lark",
        "com.valvesoftware.steam": "Steam", "com.epicgames.EpicGamesLauncher": "Epic Games",
        "org.mozilla.firefox": "Firefox", "com.kingsoft.wpsoffice.mac": "WPS Office", "dev.zed.Zed": "Zed",
        "com.brave.Browser": "Brave", "net.battle.app": "Battle.net", "com.mojang.minecraftlauncher": "Minecraft",
        "com.todesktop.230313mzl4w4u92": "Cursor", "com.tencent.qq": "QQ", "com.tencent.meeting": "Tencent Meeting", "com.microsoft.VSCode": "VS Code", "com.apple.MobileSMS": "Messages",
    ]

    /// The value in a readable form: categories without their prefix, bundle
    /// identifiers as the app's name when it is installed.
    var shortValue: String {
        switch field {
        case .category: return value.replacingOccurrences(of: "public.app-category.", with: "")
        case .app:
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: value) {
                return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            }
            if let known = Self.knownApps[value] { return known }
            // "com.sublimetext.4" reads better as "sublimetext 4" than as "4".
            let parts = value.split(separator: ".").map(String.init)
            if let last = parts.last, parts.count > 1, last.allSatisfy(\.isNumber) { return "\(parts[parts.count - 2]) \(last)" }
            return parts.last ?? value
        default: return value
        }
    }
}

struct NewTagForm: View {
    @EnvironmentObject private var model: AppModel
    var done: () -> Void = {}
    @State private var name = ""
    @State private var colorIndex = 6
    @State private var apps: Set<String> = []
    @State private var sites: [String] = []
    @State private var picks = false
    @FocusState private var nameFocused: Bool

    private var chosen: String {
        if apps.isEmpty && sites.isEmpty { return L("Choose apps and sites…") }
        var parts: [String] = []
        if !apps.isEmpty { parts.append(String(format: L("%d apps"), apps.count)) }
        if !sites.isEmpty { parts.append(String(format: L("%d sites"), sites.count)) }
        return parts.joined(separator: L(", "))
    }

    var body: some View {
        Card(padding: .hv(20, 18)) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .bottom, spacing: 14) {
                    labeled(L("Name")) {
                        TextField(L("e.g. Meetings"), text: $name)
                            .textFieldStyle(.plain)
                            .focused($nameFocused)
                            .padding(.horizontal, 10)
                            .frame(width: 180, height: 32)
                            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    labeled(L("Colour")) {
                        HStack(spacing: 6) {
                            ForEach(Palette.colors.indices, id: \.self) { index in
                                Button { colorIndex = index } label: {
                                    Circle().fill(Palette.color(index)).frame(width: 18, height: 18)
                                        .padding(3)
                                        .overlay(Circle().strokeBorder(colorIndex == index ? Theme.ink : .clear, lineWidth: 2))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(L("Colour")) \(index + 1)")
                                .accessibilityAddTraits(colorIndex == index ? .isSelected : [])
                            }
                        }
                        .frame(height: 32)
                    }
                    labeled(L("Applied automatically to")) {
                        Button { picks = true } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "square.grid.2x2").font(.system(size: 11, weight: .semibold))
                                Text(chosen).fontWeight(.medium)
                            }
                            .foregroundStyle(apps.isEmpty && sites.isEmpty ? Theme.accent : Theme.ink)
                        }
                        .buttonStyle(TRButtonStyle(kind: .bordered, height: 32))
                        .popover(isPresented: $picks, arrowEdge: .bottom) {
                            VStack(alignment: .trailing, spacing: 14) {
                                SourcePicker(apps: $apps, sites: $sites)
                                Button(L("Done")) { picks = false }.buttonStyle(.trProminent)
                            }
                            .padding(18)
                            .frame(width: 440)
                            .font(.system(size: 13))
                        }
                    }
                    Spacer(minLength: 0)
                    Button(L("Cancel"), action: done).buttonStyle(TRButtonStyle(kind: .bordered, height: 32))
                    Button(L("Save")) {
                        model.addTag(name: name, colorIndex: colorIndex, apps: apps, sites: Set(sites))
                        done()
                    }
                    .buttonStyle(TRButtonStyle(kind: .prominent, height: 32))
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text(L("Pick nothing to use the tag by hand only. Rules on file paths or window titles can be added on the Rules page."))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
        }
        .onAppear { nameFocused = true }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            content()
        }
    }
}

/// Field, comparison and value of one rule, as three inline controls.
struct RuleFields: View {
    @Binding var field: RuleField
    @Binding var op: RuleOp
    @Binding var value: String
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Picker(L("Field"), selection: $field) {
                ForEach(RuleField.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Picker(L("Match"), selection: $op) {
                ForEach(RuleOp.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            TextField(field.placeholder, text: $value)
                .textFieldStyle(.plain)
                .font(Theme.mono)
                .onSubmit(onSubmit)
                .padding(.horizontal, 10)
                .frame(minWidth: 140, maxWidth: .infinity)
                .frame(height: 32)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line))
        }
    }
}
