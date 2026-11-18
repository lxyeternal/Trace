import SwiftUI
import TraceCore

/// Sessions, goals and how focused the day was, in one place.
struct FocusView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Page {
            PageHeader(title: L("Focus"), subtitle: Fmt.day(model.day), pill: model.isToday ? L("Today") : "") {
                HStack(spacing: 4) {
                    IconButton(symbol: "chevron.left", label: L("Previous day")) { model.shiftDay(-1) }
                    IconButton(symbol: "chevron.right", label: L("Next day")) { model.shiftDay(1) }
                        .disabled(model.isToday)
                        .opacity(model.isToday ? 0.4 : 1)
                }
            } trailing: {
                if !model.isToday {
                    Button(L("Back to today")) { model.goToToday() }.buttonStyle(.trLink)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                SessionCard().frame(minWidth: 380, maxWidth: 460)
                VStack(spacing: 12) {
                    GoalsCard()
                    SessionListCard()
                }
            }
            FocusCard()
        }
    }
}

/// Start a session, or watch the one that is running.
private struct SessionCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var tagID: Int64?
    @State private var minutes: Int?

    private let lengths: [Int?] = [nil, 25, 50, 60, 120]

    var body: some View {
        Card(padding: .hv(20, 18)) {
            if let session = model.running, let tag = model.tags.first(where: { $0.id == session.tagID }) {
                running(session, tag)
            } else {
                start
            }
        }
    }

    private var start: some View {
        let tags = model.tags.filter(\.enabled)
        let chosen = tags.first { $0.id == tagID } ?? tags.first
        return VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: L("Start a session"))
            Text(L("From the moment you start until you stop, everything you do counts as the tag you pick, whatever the rules say. Use it for a game, a study block, or anything the rules cannot guess."))
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text(L("Count it as")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                FlowLayout(spacing: 6) {
                    ForEach(tags) { tag in
                        let isOn = tag.id == chosen?.id
                        Button { tagID = tag.id } label: {
                            HStack(spacing: 6) {
                                Swatch(tag, size: 8, round: true)
                                Text(tag.displayName).fontWeight(isOn ? .semibold : .medium)
                            }
                            .padding(.horizontal, 11)
                            .frame(height: 28)
                            .background(isOn ? Palette.color(tag).opacity(0.16) : .clear, in: Capsule())
                            .overlay(Capsule().strokeBorder(isOn ? Palette.color(tag) : Theme.line))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("For how long")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                Segmented(options: lengths.map { ($0, $0.map { Fmt.duration(TimeInterval($0 * 60)) } ?? L("Until I stop")) },
                          selection: $minutes)
                Text(minutes == nil ? L("It runs until you press Stop.")
                                    : L("It ends by itself and lets you know."))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Button {
                if let chosen { model.startSession(chosen, minutes: minutes) }
            } label: {
                Label(String(format: L("Start %@"), chosen?.displayName ?? ""), systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TRButtonStyle(kind: .prominent, height: 36))
            .disabled(chosen == nil || !model.isToday || model.isDemo)
            if !model.isToday {
                Text(L("Go back to today to start a session.")).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func running(_ session: FocusSession, _ tag: Tag) -> some View {
        let elapsed = session.duration(at: model.clock)
        let fraction = session.target.map { min(elapsed / max($0, 1), 1) }
        return VStack(spacing: 16) {
            HStack(spacing: 8) {
                Swatch(tag, size: 10, round: true)
                Text(String(format: L("%@ session"), tag.displayName)).font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(String(format: L("since %@"), Fmt.time(session.start))).foregroundStyle(Theme.muted)
            }
            ZStack {
                Circle().stroke(Theme.bg, lineWidth: 12)
                Circle().trim(from: 0, to: fraction ?? 1)
                    .stroke(Palette.color(tag).opacity(fraction == nil ? 0.35 : 1),
                            style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text(Fmt.clock(session.target.map { $0 - elapsed } ?? elapsed))
                        .font(.system(size: 38, weight: .bold))
                        .monospacedDigit()
                    Text(session.target.map { String(format: L("left of %@"), Fmt.duration($0)) } ?? L("so far"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
            }
            .frame(width: 200, height: 200)
            .padding(.vertical, 4)
            Text(String(format: L("Everything you do now counts as %@."), tag.displayName))
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
            Button { model.stopSession() } label: {
                Label(L("Stop"), systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(TRButtonStyle(kind: .prominent, height: 36))
        }
    }
}

/// The sessions of the day; deleting one gives its records back their tags.
private struct SessionListCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var deleting: FocusSession?
    @State private var adds = false

    var body: some View {
        let sessions = model.daySessions
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SectionTitle(title: model.isToday ? L("Today's sessions") : L("Sessions that day"))
                    Spacer()
                    Button { adds = true } label: {
                        Label(L("Add a past one"), systemImage: "plus").font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.trLink)
                    .disabled(model.isDemo)
                    .help(L("Forgot to start a session? Mark the time afterwards."))
                    .popover(isPresented: $adds, arrowEdge: .bottom) {
                        PastSessionForm { adds = false }.environmentObject(model)
                    }
                }
                .padding(.bottom, 8)
                if sessions.isEmpty {
                    Hairline()
                    Text(L("No sessions. Records are tagged by the rules alone."))
                        .foregroundStyle(Theme.muted).padding(.vertical, 12)
                }
                ForEach(sessions.reversed()) { session in
                    Hairline()
                    row(session)
                }
            }
        }
        .confirmationDialog(L("Delete this session?"),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { session in
            Button(L("Delete"), role: .destructive) { model.deleteSession(session) }
            Button(L("Cancel"), role: .cancel) {}
        } message: { _ in
            Text(L("Its records are kept and go back to their own tags."))
        }
    }

    private func row(_ session: FocusSession) -> some View {
        let tag = model.tags.first { $0.id == session.tagID }
        return HStack(spacing: 10) {
            Text("\(Fmt.time(session.start)) – \(session.end.map(Fmt.time) ?? L("now"))")
                .foregroundStyle(Theme.muted)
                .frame(width: 104, alignment: .leading)
            Swatch(tag)
            Text(tagName(tag)).fontWeight(.semibold)
            if let target = session.target {
                Badge(text: String(format: L("planned %@"), Fmt.duration(target)))
            }
            if !model.devices.isEmpty {
                Badge(text: model.deviceName(forDevice: session.device))
            }
            if session.isRunning {
                Text(L("running")).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            Spacer(minLength: 8)
            Text(Fmt.duration(session.duration(at: model.clock))).fontWeight(.semibold)
            if session.device.isEmpty {
                Button { deleting = session } label: {
                    Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Delete this session"))
                .accessibilityLabel(L("Delete this session"))
            }
        }
        .padding(.vertical, 9)
    }
}

/// Marks a stretch of the day as a session after the fact.
private struct PastSessionForm: View {
    @EnvironmentObject private var model: AppModel
    var done: () -> Void
    @State private var tagID: Int64?
    @State private var from = Date()
    @State private var to = Date()

    var body: some View {
        let tags = model.tags.filter(\.enabled)
        let chosen = tags.first { $0.id == tagID } ?? tags.first
        let limit = min(model.dayInterval.end, Date())
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Add a past session")).font(.system(size: 14, weight: .semibold))
            Text(L("Everything recorded on this Mac between the two times counts as the tag you pick."))
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                DatePicker(L("From"), selection: $from, in: model.dayInterval.start...limit, displayedComponents: .hourAndMinute)
                DatePicker(L("to"), selection: $to, in: model.dayInterval.start...limit, displayedComponents: .hourAndMinute)
            }
            .fixedSize()
            FlowLayout(spacing: 6) {
                ForEach(tags) { tag in
                    let isOn = tag.id == chosen?.id
                    Button { tagID = tag.id } label: {
                        HStack(spacing: 6) {
                            Swatch(tag, size: 8, round: true)
                            Text(tag.displayName).fontWeight(isOn ? .semibold : .medium)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(isOn ? Palette.color(tag).opacity(0.16) : .clear, in: Capsule())
                        .overlay(Capsule().strokeBorder(isOn ? Palette.color(tag) : Theme.line))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            HStack {
                Spacer()
                Button(L("Cancel"), action: done).buttonStyle(.trBordered)
                Button(L("Add")) {
                    if let chosen { model.tagPeriod(DateInterval(start: from, end: to), as: chosen) }
                    done()
                }
                .buttonStyle(.trProminent)
                .disabled(chosen == nil || from >= to)
            }
        }
        .padding(18)
        .frame(width: 380)
        .font(.system(size: 13))
        .onAppear {
            to = limit
            from = max(model.dayInterval.start, limit.addingTimeInterval(-3600))
        }
    }
}
