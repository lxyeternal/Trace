import SwiftUI
import TraceCore

extension TimelineMode {
    var title: String {
        switch self {
        case .gantt: return L("Lanes")
        case .byTag: return L("By tag")
        case .byApp: return L("By app")
        case .byProject: return L("By project")
        case .records: return L("Records")
        }
    }
}

/// The detailed view of a day: a drill-down outline next to the day laid
/// out top to bottom, or every record one by one.
struct TimelineView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let events = model.filteredEvents
        Page {
            PageHeader(title: L("Timeline"), subtitle: subtitle(events.count)) {
                HStack(spacing: 4) {
                    IconButton(symbol: "chevron.left", label: L("Previous day")) { model.shiftDay(-1) }
                    IconButton(symbol: "chevron.right", label: L("Next day")) { model.shiftDay(1) }
                        .disabled(model.isToday)
                        .opacity(model.isToday ? 0.4 : 1)
                }
            } trailing: {
                Segmented(options: TimelineMode.allCases.map { ($0, $0.title) }, selection: $model.timelineMode)
                SearchField(text: $model.query, placeholder: L("Search titles, paths, URLs"))
            }
            if model.events.isEmpty {
                Card { EmptyState(title: L("No activity recorded"),
                                  note: L("Trace records the app, window, file and page you are using. Keep it running and check back in a few minutes."))
                    .frame(minHeight: 420)
                }
            } else {
                TagFilterBar()
                if model.timelineMode == .records {
                    RecordsView(events: events)
                } else if model.timelineMode == .gantt {
                    GanttCard()
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        OutlineCard(events: events, mode: treeMode)
                        DayColumnCard().frame(width: 360)
                    }
                }
            }
        }
    }

    private var treeMode: TreeMode {
        switch model.timelineMode {
        case .byApp: return .byApp
        case .byProject: return .byProject
        default: return .byTag
        }
    }

    private func subtitle(_ count: Int) -> String {
        let day = Fmt.day(model.day)
        guard model.timelineMode == .records else { return day }
        return "\(day) · " + Fmt.records(count)
    }
}

// MARK: Outline

/// tag › app › file or site › page, each level expandable.
private struct OutlineCard: View {
    @EnvironmentObject private var model: AppModel
    let events: [ActivityEvent]
    let mode: TreeMode

    @State private var collapsed: Set<String> = []
    @State private var opened: Set<String> = []

    private struct Row: Identifiable {
        let node: TreeNode
        let level: Int
        let isOpen: Bool
        var id: String { node.id }
    }

    var body: some View {
        let interval = model.selection ?? model.dayInterval
        let nodes = model.tree(mode, in: interval)
        let total = nodes.reduce(0) { $0 + $1.seconds }
        let peak = nodes.map(\.seconds).max() ?? 1
        Card(padding: EdgeInsets(top: 16, leading: 12, bottom: 12, trailing: 12)) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(model.selection == nil ? L("All activity") : L("Selected period"))
                        .font(.system(size: 14, weight: .semibold))
                        .help(hint)
                    Text(Fmt.duration(total)).font(.system(size: 20, weight: .bold)).tracking(-0.2)
                    if let selection = model.selection {
                        Button { model.selection = nil } label: {
                            HStack(spacing: 4) {
                                Text("\(Fmt.time(selection.start)) – \(Fmt.time(selection.end))")
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Theme.soft, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(L("Show the whole day"))
                        if !model.isDemo, (model.deviceFilter ?? "").isEmpty, selection.start < Date() {
                            Menu {
                                ForEach(model.tags.filter(\.enabled)) { tag in
                                    Button(tag.displayName) { model.tagPeriod(selection, as: tag) }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "tag").font(.system(size: 9, weight: .bold))
                                    Text(L("Count as…"))
                                }
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Theme.fill, in: Capsule())
                                .contentShape(Capsule())
                            }
                            .menuStyle(.button)
                            .buttonStyle(.plain)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help(L("Count everything on this Mac in this period as one tag, like a session added afterwards"))
                        }
                    }
                    Spacer()
                }
                .padding(EdgeInsets(top: 0, leading: 8, bottom: 10, trailing: 8))

                if nodes.isEmpty {
                    Text(mode == .byProject ? L("No files were open in this period, so there are no projects to show.")
                                            : L("No matching records"))
                        .foregroundStyle(Theme.muted).padding(8)
                }
                ForEach(flatten(nodes, level: 0)) { row in
                    OutlineRow(node: row.node, level: row.level, isOpen: row.isOpen,
                               fraction: row.node.seconds / peak) { toggle(row) }
                }
            }
        }
    }

    private var hint: String {
        switch mode {
        case .byTag: return L("Expand level by level: tag › app › file or site › page")
        case .byApp: return L("Expand level by level: app › file or site › page")
        case .byProject: return L("Projects are found from the folder each file is in")
        }
    }

    /// Top-level nodes start open; deeper ones start closed.
    private func isOpen(_ node: TreeNode, level: Int) -> Bool {
        level == 0 ? !collapsed.contains(node.id) : opened.contains(node.id)
    }

    private func flatten(_ nodes: [TreeNode], level: Int) -> [Row] {
        nodes.flatMap { node -> [Row] in
            let open = node.children != nil && isOpen(node, level: level)
            let row = Row(node: node, level: level, isOpen: open)
            return [row] + (open ? flatten(node.children ?? [], level: level + 1) : [])
        }
    }

    private func toggle(_ row: Row) {
        guard row.node.children != nil else { return }
        if row.level == 0 {
            if row.isOpen { collapsed.insert(row.id) } else { collapsed.remove(row.id) }
        } else {
            if row.isOpen { opened.remove(row.id) } else { opened.insert(row.id) }
        }
    }
}

private struct OutlineRow: View {
    let node: TreeNode
    let level: Int
    let isOpen: Bool
    let fraction: Double
    let toggle: () -> Void
    @State private var hovering = false

    private var isMono: Bool { node.kind == .file || node.kind == .web }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.muted)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .opacity(node.children == nil ? 0 : 1)
                    .frame(width: 11)
                icon
                Text(node.kind == .tag ? tagName(node.tag) : node.label)
                    .font(isMono ? Theme.mono : .system(size: 13))
                    .fontWeight(level == 0 ? .bold : (level == 1 ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Meter(fraction: fraction, color: Palette.color(node.tag), height: 4).frame(width: 72)
                Text(Fmt.duration(node.seconds))
                    .fontWeight(level == 0 ? .bold : (level == 1 ? .semibold : .regular))
                    .foregroundStyle(level < 2 ? Theme.ink : Theme.muted)
                    .frame(width: 72, alignment: .trailing)
            }
            .padding(EdgeInsets(top: 0, leading: 8 + CGFloat(level) * 22, bottom: 0, trailing: 8))
            .frame(minHeight: 32)
            .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isOpen)
    }

    @ViewBuilder private var icon: some View {
        switch node.kind {
        case .tag: Swatch(node.tag, size: 11, round: true)
        case .app: AppIcon(bundleID: node.bundleID ?? "", size: 20)
        case .file: glyph("doc")
        case .web: glyph("globe")
        case .page: glyph("doc.text")
        case .window: glyph("macwindow")
        case .project:
            Image(systemName: "folder.fill").font(.system(size: 12)).foregroundStyle(Palette.color(node.tag)).frame(width: 14)
        }
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 12)).foregroundStyle(Theme.muted).frame(width: 14)
    }
}

// MARK: Day column

/// The day from top to bottom: an app strip and one titled block per session.
private struct DayColumnCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var drag: ClosedRange<CGFloat>?

    private let hourHeight: CGFloat = 60

    var body: some View {
        let scale = DayScale(day: model.day, first: model.summary.first, last: model.summary.last)
        let height = CGFloat(scale.hours.count - 1) * hourHeight
        Card(padding: EdgeInsets(top: 16, leading: 12, bottom: 16, trailing: 16)) {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: L("Day timeline"), note: L("Click a block or drag to pick a period"))
                    .padding(.leading, 8)

                HStack(alignment: .top, spacing: 8) {
                    ZStack(alignment: .topTrailing) {
                        ForEach(Array(scale.hours), id: \.self) { hour in
                            Text(String(format: "%02d:00", hour))
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.muted)
                                .offset(y: CGFloat(hour - scale.hours.lowerBound) * hourHeight)
                        }
                    }
                    .frame(width: 38, height: height + 16, alignment: .topTrailing)
                    .accessibilityHidden(true)

                    ZStack(alignment: .top) {
                        ForEach(model.appRuns) { run in
                            Rectangle().fill(Palette.color(run.tag))
                                .frame(height: max(1, CGFloat(scale.length(run.end.timeIntervalSince(run.start))) * height - 1))
                                .offset(y: CGFloat(scale.fraction(run.start)) * height)
                                .help("\(run.appName) · \(Fmt.time(run.start)) – \(Fmt.time(run.end))")
                        }
                    }
                    .frame(width: 10, height: height, alignment: .top)
                    .background(Theme.bg)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .padding(.top, 8)
                    .accessibilityLabel(L("Apps through the day, top to bottom"))

                    GeometryReader { geo in
                        // Sessions on two Macs at the same time sit side by side.
                        let lanes = Lanes.assign(model.blocks.map { ($0.start, $0.end) })
                        ZStack(alignment: .topLeading) {
                            ForEach(Array(scale.hours), id: \.self) { hour in
                                Hairline().offset(y: CGFloat(hour - scale.hours.lowerBound) * hourHeight)
                            }
                            ForEach(Array(model.blocks.enumerated()), id: \.element.id) { index, block in
                                let blockHeight = max(4, CGFloat(scale.length(block.duration)) * height - 2)
                                let interval = DateInterval(start: block.start, end: block.end)
                                let width = (geo.size.width - 4) / CGFloat(lanes[index].of)
                                BlockTile(block: block, height: blockHeight, isSelected: model.selection == interval) {
                                    model.selection = model.selection == interval ? nil : interval
                                }
                                .frame(width: max(8, width - (lanes[index].of > 1 ? 2 : 0)))
                                .offset(x: 4 + CGFloat(lanes[index].lane) * width,
                                        y: CGFloat(scale.fraction(block.start)) * height)
                            }
                            if let drag {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Theme.accent.opacity(0.18))
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.accent))
                                    .frame(height: drag.upperBound - drag.lowerBound)
                                    .offset(y: drag.lowerBound)
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(width: geo.size.width, height: height, alignment: .topLeading)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: height, alignment: .top)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { value in
                                let a = min(max(0, value.startLocation.y), height)
                                let b = min(max(0, value.location.y), height)
                                drag = min(a, b)...max(a, b)
                            }
                            .onEnded { _ in
                                if let drag, drag.upperBound - drag.lowerBound > 4 {
                                    model.selection = DateInterval(start: scale.date(at: drag.lowerBound / height),
                                                                   end: scale.date(at: drag.upperBound / height))
                                }
                                drag = nil
                            }
                    )
                    .padding(.top, 8)
                }
            }
        }
    }
}

private struct BlockTile: View {
    @EnvironmentObject private var model: AppModel
    let block: Block
    let height: CGFloat
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: min(7, height / 2), style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                if height >= 18 {
                    Text(block.title).fontWeight(.semibold).lineLimit(1)
                }
                if height >= 36 {
                    Text((model.devices.isEmpty ? "" : model.deviceName(forDevice: block.device) + " · ")
                         + "\(Fmt.time(block.start)) – \(Fmt.time(block.end)) · \(Fmt.duration(block.duration))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, height >= 36 ? 2 : 0)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: height >= 36 ? .topLeading : .leading)
            .background(Palette.color(block.tag).opacity(0.18))
            .background(Theme.panel)
            .clipShape(shape)
            .overlay(shape.strokeBorder(isSelected ? Theme.accent : Theme.line, lineWidth: isSelected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(tagName(block.tag)) · \(block.title) · \(Fmt.time(block.start)) – \(Fmt.time(block.end))"
              + (model.devices.isEmpty ? "" : " · " + model.deviceName(forDevice: block.device)))
    }
}
