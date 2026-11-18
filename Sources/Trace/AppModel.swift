import AppKit
import Combine
import ServiceManagement
import SwiftUI
import TraceCore
import UniformTypeIdentifiers

enum Appearance: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }
}

enum Pane: String, CaseIterable, Identifiable {
    case overview, timeline, focus, reports, tags, rules
    var id: String { rawValue }
}

enum TimelineMode: String, CaseIterable, Identifiable {
    case gantt, byTag, byApp, byProject, records
    var id: String { rawValue }
}

enum ReportPeriod: String, CaseIterable, Identifiable {
    case week, month, year
    var id: String { rawValue }
    var component: Calendar.Component {
        switch self {
        case .week: return .weekOfYear
        case .month: return .month
        case .year: return .year
        }
    }
}

/// App-wide state: settings, navigation, the selected day and everything
/// derived from it.
@MainActor
final class AppModel: ObservableObject {
    let store: EventStore
    let watcher: ActivityWatcher
    let databaseURL: URL?
    /// Started with `--demo`: made-up data in memory, nothing recorded.
    let isDemo: Bool

    // Navigation and selection, shared so one page can send you to another.
    @Published var pane: Pane = .overview
    @Published var timelineMode: TimelineMode = .gantt
    @Published var query = "" { didSet { memo.removeAll() } }
    @Published var tagFilter: Int64? { didSet { memo.removeAll() } }
    /// A stretch of the day picked in the timeline; the outline sums only this.
    @Published var selection: DateInterval?
    @Published var selectedBlock: Date?
    @Published var selectedEventID: Int64?
    @Published var reportPeriod: ReportPeriod = .week
    @Published var reportAnchor = Date()
    /// Prefills the new-rule form, e.g. from "Create rule" on untagged activity.
    @Published var ruleDraft: (field: RuleField, value: String)?
    @Published var showsOnboarding: Bool
    /// The short guide to the app, shown once after setup and from the Help menu.
    @Published var showsTour = false

    @Published var day = Calendar.current.startOfDay(for: Date()) {
        didSet { selection = nil; selectedBlock = nil; selectedEventID = nil; reload() }
    }
    @Published private(set) var events: [ActivityEvent] = []
    @Published private(set) var summary = DaySummary()
    @Published private(set) var blocks: [Block] = []
    @Published private(set) var appRuns: [AppRun] = []
    /// Sound and microphone records of the selected day.
    @Published private(set) var background: [ActivityEvent] = []
    @Published private(set) var focus = FocusSummary()
    @Published private(set) var goals: [Goal] = []
    /// Days in a row each goal has been met, keyed by goal id.
    @Published private(set) var streaks: [Int64: Int] = [:]
    let projects = ProjectResolver()
    /// Sessions started by hand, on this Mac and the others.
    @Published private(set) var sessions: [FocusSession] = []
    /// The session running on this Mac.
    @Published private(set) var running: FocusSession?
    /// The present moment, refreshed every second while a session runs.
    @Published private(set) var clock = Date()
    private var sessionTimer: Timer?
    /// When the next automatic sync is due.
    @Published private(set) var nextSync: Date?
    @Published private(set) var yesterdayTotal: TimeInterval = 0
    @Published private(set) var tags: [Tag] = []
    @Published private(set) var rules: [Rule] = []
    @Published private(set) var tagger = Tagger(tags: [], rules: [])
    /// Bumped whenever tags, rules or manual tags change.
    @Published private(set) var revision = 0

    @Published var appearance: Appearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance"); applyAppearance() }
    }
    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "language"); L10n.apply(language) }
    }
    @Published var idleMinutes: Int {
        didSet { UserDefaults.standard.set(idleMinutes, forKey: "idleMinutes"); watcher.idleThreshold = TimeInterval(idleMinutes * 60) }
    }
    @Published var captureTitles: Bool {
        didSet { UserDefaults.standard.set(captureTitles, forKey: "captureTitles"); watcher.captureTitles = captureTitles }
    }
    @Published var captureTelegramChats: Bool {
        didSet {
            UserDefaults.standard.set(captureTelegramChats, forKey: "captureTelegramChats")
            watcher.captureTelegramChats = captureTelegramChats
        }
    }
    @Published var captureFiles: Bool {
        didSet { UserDefaults.standard.set(captureFiles, forKey: "captureFiles"); watcher.captureFiles = captureFiles }
    }
    @Published var captureBackground: Bool {
        didSet { UserDefaults.standard.set(captureBackground, forKey: "captureBackground"); watcher.captureBackground = captureBackground }
    }
    @Published var captureOpenApps: Bool {
        didSet { UserDefaults.standard.set(captureOpenApps, forKey: "captureOpenApps"); watcher.captureOpenApps = captureOpenApps }
    }
    @Published var anySoundMeansPresent: Bool {
        didSet { UserDefaults.standard.set(anySoundMeansPresent, forKey: "anySoundMeansPresent"); watcher.anySoundMeansPresent = anySoundMeansPresent }
    }
    /// Whether time away is taken out of a running session.
    @Published var pausesSessionsWhenAway: Bool {
        didSet { UserDefaults.standard.set(pausesSessionsWhenAway, forKey: "sessionAbsence") }
    }
    /// What was done to a session while the user was away, until dismissed.
    @Published var sessionNotice: SessionNotice?
    @Published var captureURLs: Bool {
        didSet { UserDefaults.standard.set(captureURLs, forKey: "captureURLs"); watcher.captureURLs = captureURLs }
    }
    /// Bundle identifiers of apps that are never recorded.
    @Published var excludedApps: [String] {
        didSet { UserDefaults.standard.set(excludedApps, forKey: "excludedApps"); watcher.excluded = Set(excludedApps) }
    }
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    // Sync through a shared folder.
    private(set) var deviceID: String
    /// This Mac's name as other Macs see it; the system's name unless changed.
    @Published var deviceName: String {
        didSet {
            let trimmed = deviceName.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: "deviceName")
            } else {
                UserDefaults.standard.set(trimmed, forKey: "deviceName")
            }
        }
    }
    /// Today's time per Mac, whatever the device filter; keyed by device id.
    @Published private(set) var deviceTotals: [String: TimeInterval] = [:]
    @Published private(set) var syncFolder: String?
    @Published private(set) var lastSync: Date?
    @Published private(set) var syncError: String?
    @Published private(set) var isSyncing = false
    /// Other Macs whose records are in the database.
    @Published private(set) var devices: [SyncedDevice] = []
    /// Which Mac's records to show: nil for all, "" for this Mac, else a device id.
    @Published var deviceFilter: String? { didSet { reload() } }
    private var syncTimer: Timer?

    private var refresh: Timer?

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["captureTelegramChats": true, "captureTitles": true, "captureFiles": true, "captureURLs": true,
                                     "captureBackground": true, "captureOpenApps": true, "sessionAbsence": true])
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        language = AppLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .system
        let minutes = defaults.integer(forKey: "idleMinutes")
        idleMinutes = minutes > 0 ? minutes : 3
        captureTitles = defaults.bool(forKey: "captureTitles")
        captureTelegramChats = defaults.bool(forKey: "captureTelegramChats")
        captureFiles = defaults.bool(forKey: "captureFiles")
        captureURLs = defaults.bool(forKey: "captureURLs")
        captureBackground = defaults.bool(forKey: "captureBackground")
        captureOpenApps = defaults.bool(forKey: "captureOpenApps")
        anySoundMeansPresent = defaults.bool(forKey: "anySoundMeansPresent")
        pausesSessionsWhenAway = defaults.bool(forKey: "sessionAbsence")
        excludedApps = defaults.stringArray(forKey: "excludedApps") ?? []
        if let id = defaults.string(forKey: "deviceID") {
            deviceID = id
        } else {
            deviceID = UUID().uuidString.lowercased()
            defaults.set(deviceID, forKey: "deviceID")
        }
        syncFolder = defaults.string(forKey: "syncFolder")
        deviceName = defaults.string(forKey: "deviceName") ?? Host.current().localizedName ?? "Mac"

        // Launch arguments, used for demos and screenshots; they are not saved.
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        let demo = args.contains("--demo")
        isDemo = demo
        if let override = value(after: "--language").flatMap(AppLanguage.init(rawValue:)) { language = override }
        if let override = value(after: "--appearance").flatMap(Appearance.init(rawValue:)) { appearance = override }
        showsOnboarding = !demo && !defaults.bool(forKey: "onboarded")
        // For trying sync without touching real data: a separate database
        // folder, sync folder and device identity for this run only.
        let dataDir = value(after: "--data-dir")
        if let override = value(after: "--sync-folder") { syncFolder = override }
        if let override = value(after: "--device-id") { deviceID = override }

        // Keep data in Application Support; fall back to memory if that fails
        // so the app still opens and can say what went wrong.
        var url: URL?
        var opened: EventStore?
        if !demo, let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true) {
            let folder = dataDir.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? support.appendingPathComponent("Trace", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("trace.sqlite")
            if let store = try? EventStore(path: file.path) {
                opened = store
                url = file
            }
        }
        store = opened ?? (try! EventStore())
        databaseURL = url
        watcher = ActivityWatcher(store: store)
        watcher.idleThreshold = TimeInterval(idleMinutes * 60)
        watcher.captureTitles = captureTitles
        watcher.captureTelegramChats = captureTelegramChats
        watcher.captureFiles = captureFiles
        watcher.captureURLs = captureURLs
        watcher.captureBackground = captureBackground
        watcher.captureOpenApps = captureOpenApps
        watcher.anySoundMeansPresent = anySoundMeansPresent
        watcher.excluded = Set(excludedApps)
        watcher.onReturn = { [weak self] left, back, asleep in self?.cameBack(left: left, back: back, asleep: asleep) }

        L10n.apply(language)
        if demo, let tags = try? store.tags(), let study = tags.first(where: { $0.key == "study" })?.id,
           let games = tags.first(where: { $0.key == "games" })?.id {
            // Two sessions on the demo day: a timed one and an open one.
            let day = Calendar.current.startOfDay(for: Date())
            _ = try? store.startSession(tagID: study, targetMinutes: 50, at: day.addingTimeInterval(790 * 60))
            _ = try? store.endSession(at: day.addingTimeInterval(840 * 60))
            _ = try? store.startSession(tagID: games, at: day.addingTimeInterval(1150 * 60))
            _ = try? store.endSession(at: day.addingTimeInterval(1185 * 60))
        }
        if demo {
            // Always a full day, whatever the clock says, so the demo never looks empty.
            let evening = Calendar.current.startOfDay(for: Date()).addingTimeInterval(21 * 3600)
            try? store.insert(DemoData.events(now: evening, days: 400) + DemoData.background(now: evening))
            if let tags = try? store.tags() {
                if let dev = tags.first(where: { $0.key == "dev" })?.id { try? store.setGoal(tagID: dev, kind: .atLeast, minutes: 240) }
                if let study = tags.first(where: { $0.key == "study" })?.id { try? store.setGoal(tagID: study, kind: .atLeast, minutes: 60) }
                if let fun = tags.first(where: { $0.key == "fun" })?.id { try? store.setGoal(tagID: fun, kind: .atMost, minutes: 45) }
            }
            if let last = (try? store.events(from: evening.addingTimeInterval(-86_400), to: evening))?.last {
                watcher.showDemo(Sample(bundleID: last.bundleID, appName: last.appName, title: last.title,
                                        path: last.path, url: last.url), since: last.start)
            }
        }
        devices = (try? store.devices()) ?? []
        reload()
        if !demo {
            watcher.start()
            let sync = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.nextSync = Date().addingTimeInterval(300)
                    self?.syncNow()
                }
            }
            nextSync = Date().addingTimeInterval(300)
            runSessionTimer()
            RunLoop.main.add(sync, forMode: .common)
            syncTimer = sync
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.syncNow() }
        }

        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reloadIfToday() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refresh = timer
        DispatchQueue.main.async { [weak self] in self?.applyAppearance() }
        if !demo, !showsOnboarding, !defaults.bool(forKey: "tourSeen") {
            // Someone who set Trace up before the guide existed sees it once.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.showsTour = true }
        }
    }

    // MARK: Day

    var isToday: Bool { Calendar.current.isDateInToday(day) }
    var dayInterval: DateInterval {
        DateInterval(start: day, end: Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day + 86_400)
    }
    /// The current calendar week.
    var weekInterval: DateInterval {
        Calendar.current.dateInterval(of: .weekOfYear, for: Date()) ?? DateInterval(start: Date(), duration: 7 * 86_400)
    }
    /// Time between the first and last record of the day that was not recorded.
    var away: TimeInterval {
        guard let first = summary.first, let last = summary.last else { return 0 }
        return max(0, last.timeIntervalSince(first) - summary.total)
    }

    func shiftDay(_ delta: Int) {
        guard let next = Calendar.current.date(byAdding: .day, value: delta, to: day),
              next <= Calendar.current.startOfDay(for: Date()) else { return }
        day = next
    }

    func goToToday() {
        day = Calendar.current.startOfDay(for: Date())
    }

    func reload() {
        let interval = dayInterval
        tags = (try? store.tags()) ?? []
        rules = (try? store.rules()) ?? []
        sessions = (try? store.sessions()) ?? []
        running = sessions.last { $0.device.isEmpty && $0.isRunning }
        tagger = Tagger(tags: tags, rules: rules, manual: (try? store.manualTags()) ?? [], sessions: sessions,
                        reusing: tagger)
        memo.removeAll()
        events = events(in: interval)
        if devices.isEmpty {
            deviceTotals = [:]
        } else {
            var totals: [String: TimeInterval] = [:]
            for event in (try? store.events(from: interval.start, to: interval.end)) ?? [] {
                totals[event.device, default: 0] += Analyzer.clipped(event, to: interval)
            }
            deviceTotals = totals
        }
        summary = Analyzer.summarize(events, in: interval, tagger: tagger)
        blocks = Analyzer.blocks(events, in: interval, tagger: tagger)
        appRuns = Analyzer.appRuns(events, in: interval, tagger: tagger)
        background = ((try? store.background(from: interval.start, to: interval.end)) ?? [])
            .filter { deviceFilter == nil || $0.device == deviceFilter }
        focus = Analyzer.focus(events, in: interval, tagger: tagger)
        goals = (try? store.goals()) ?? []
        reloadStreaks()
        if let before = Calendar.current.date(byAdding: .day, value: -1, to: day) {
            let previous = DateInterval(start: before, end: day)
            yesterdayTotal = events(in: previous).reduce(0) { $0 + (Analyzer.clipped($1, to: previous)) }
        }
    }

    private var streaksKey = ""

    /// Streaks look back a month, so they are recomputed only when the day
    /// or the goals change.
    private func reloadStreaks() {
        let key = "\(day.timeIntervalSince1970)-\(revision)-\(goals.count)-\(deviceFilter ?? "*")"
        guard key != streaksKey else { return }
        streaksKey = key
        guard !goals.isEmpty, let from = Calendar.current.date(byAdding: .day, value: -60, to: day) else {
            streaks = [:]
            return
        }
        // Up to yesterday: today is added from the live summary by the view.
        let range = DateInterval(start: from, end: day)
        let days = Analyzer.report(events(in: range), in: range, tagger: tagger).days
        var result: [Int64: Int] = [:]
        for goal in goals {
            guard let id = goal.id, let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: day) else { continue }
            result[id] = Analyzer.streak(for: goal, days: days, today: yesterday)
        }
        streaks = result
    }

    /// Days in a row the goal has been met, counting today once it is met.
    func streak(for goal: Goal) -> Int {
        let before = streaks[goal.id ?? 0] ?? 0
        let spent = summary.byTag.first { $0.tag?.id == goal.tagID }?.seconds ?? 0
        // "At most" is only settled when the day is over.
        let metToday = goal.kind == .atLeast ? goal.isMet(by: spent) : (!isToday && summary.total > 0 && goal.isMet(by: spent))
        return before + (metToday ? 1 : 0)
    }

    // MARK: Sessions

    /// Sessions that overlap the selected day, for the Macs being shown.
    var daySessions: [FocusSession] {
        let day = dayInterval
        return sessions.filter { session in
            (deviceFilter == nil || session.device == deviceFilter)
                && session.start < day.end && (session.end ?? clock) > day.start
        }
    }

    /// From now until stopped (or for `minutes`), everything counts as `tag`.
    func startSession(_ tag: Tag, minutes: Int?) {
        guard let id = tag.id, !isDemo else { return }
        _ = try? store.startSession(tagID: id, targetMinutes: minutes)
        sessionNotice = nil
        watcher.splitNow()
        if minutes != nil || pausesSessionsWhenAway { Notifier.prepare() }
        changed()
        runSessionTimer()
    }

    func stopSession(at end: Date = Date()) {
        guard let ended = try? store.endSession(at: end) else { return }
        _ = ended
        sessionNotice = nil
        watcher.splitNow()
        changed()
        runSessionTimer()
    }

    /// The user is back after `left`. A break is nothing; a longer absence is
    /// taken out of the running session; a very long one, or a Mac put to
    /// sleep, means the session was forgotten and ends where the user left.
    private func cameBack(left: Date, back: Date, asleep: TimeInterval) {
        guard pausesSessionsWhenAway, !isDemo, let session = running, let id = session.id else { return }
        let left = max(left, session.start)
        let action = AbsenceRule.action(away: back.timeIntervalSince(left), asleep: asleep)
        guard action != .ignore, (try? store.endSession(at: left)) != nil else { return }
        let name = tags.first { $0.id == session.tagID }?.displayName ?? ""
        var notice = SessionNotice(kind: .ended, tagName: name, left: left, back: back, session: id)
        if action == .deduct {
            // A timed session goes on with what was left of its time.
            let remaining = session.target.map { max(1, Int((($0 - left.timeIntervalSince(session.start)) / 60).rounded(.up))) }
            if let next = try? store.startSession(tagID: session.tagID, targetMinutes: remaining, at: back) {
                notice.kind = .deducted
                notice.resumed = next.id
            }
        }
        watcher.splitNow()
        changed()
        runSessionTimer()
        sessionNotice = notice
        Notifier.post(title: notice.title, body: notice.detail)
    }

    /// Takes back what `cameBack` did: the time away counts after all.
    func undoSessionNotice() {
        guard let notice = sessionNotice else { return }
        sessionNotice = nil
        if let resumed = notice.resumed {
            try? store.joinSessions(notice.session, resumed)
        } else if let session = sessions.first(where: { $0.id == notice.session && $0.device.isEmpty }) {
            // A timed session whose time is up by now ended when it was due.
            let due = session.target.map { session.start.addingTimeInterval($0) }
            try? store.setSessionEnd(id: notice.session, to: due.flatMap { $0 <= Date() ? $0 : nil })
        }
        watcher.splitNow()
        changed()
        runSessionTimer()
    }

    func deleteSession(_ session: FocusSession) {
        guard let id = session.id else { return }
        try? store.deleteSession(id: id)
        if sessionNotice?.session == id || sessionNotice?.resumed == id { sessionNotice = nil }
        if session.isRunning { watcher.splitNow() }
        changed()
        runSessionTimer()
    }

    /// Ticks once a second while a session runs, and ends a timed session
    /// when its time is up.
    private func runSessionTimer() {
        clock = Date()
        guard running != nil else {
            sessionTimer?.invalidate()
            sessionTimer = nil
            return
        }
        guard sessionTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.clock = Date()
                // While the user is away the session is left for `cameBack`.
                if let session = self.running, let target = session.target, session.duration(at: self.clock) >= target,
                   !(self.pausesSessionsWhenAway && self.watcher.awaySince != nil) {
                    let name = self.tags.first { $0.id == session.tagID }?.displayName ?? ""
                    self.stopSession(at: session.start.addingTimeInterval(target))
                    Notifier.post(title: String(format: L("%@ session finished"), name),
                                  body: String(format: L("%@ done. Recording goes on as usual."), Fmt.duration(target)))
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sessionTimer = timer
    }

    // MARK: Derived data
    //
    // The outline, the sessions and the lanes are worked out from the day's
    // events. Views ask for them on every redraw, so each answer is kept
    // until the events, the search text or the tag filter change.

    private var memo: [String: Any] = [:]

    private func remembered<T>(_ key: String, _ make: () -> T) -> T {
        if let known = memo[key] as? T { return known }
        let value = make()
        memo[key] = value
        return value
    }

    /// The day's events that pass the search text and tag filter.
    var filteredEvents: [ActivityEvent] {
        remembered("events") { events.filter(passesFilter) }
    }

    /// The filtered events grouped into sessions.
    var filteredBlocks: [Block] {
        remembered("blocks") { Analyzer.blocks(filteredEvents, in: dayInterval, tagger: tagger) }
    }

    func tree(_ mode: TreeMode, in interval: DateInterval) -> [TreeNode] {
        remembered("tree-\(mode)-\(interval.start.timeIntervalSince1970)-\(interval.duration)") {
            Analyzer.tree(filteredEvents, in: interval, tagger: tagger, mode: mode, projects: projects)
        }
    }

    func gantt(_ grouping: GanttGrouping) -> Gantt {
        remembered("gantt-\(grouping)") {
            Analyzer.gantt(filteredEvents, background: background, in: dayInterval, tagger: tagger,
                           grouping: grouping, deviceName: { [weak self] in self?.deviceName(forDevice: $0) ?? $0 })
        }
    }

    private func reloadIfToday() {
        if isToday { reload() }
    }

    private func changed() {
        revision += 1
        reload()
    }

    func events(in range: DateInterval) -> [ActivityEvent] {
        let all = (try? store.events(from: range.start, to: range.end)) ?? []
        guard let deviceFilter else { return all }
        return all.filter { $0.device == deviceFilter }
    }

    /// Name of the Mac an event was recorded on.
    func deviceName(for event: ActivityEvent) -> String {
        deviceName(forDevice: event.device)
    }

    func deviceName(forDevice id: String) -> String {
        id.isEmpty ? deviceName : (devices.first { $0.id == id }?.displayName ?? id)
    }

    /// Names another Mac on this Mac only.
    func renameDevice(_ device: SyncedDevice, to name: String) {
        try? store.renameDevice(id: device.id, to: name)
        devices = (try? store.devices()) ?? []
        memo.removeAll()
    }

    /// Whether `event` matches the search text and tag filter.
    func passesFilter(_ event: ActivityEvent) -> Bool {
        // The main tag, so the result adds up to the tag's total; 0 stands
        // for untagged, as in `TagTotal.id`.
        if let tagFilter, (tagger.primary(for: event)?.id ?? 0) != tagFilter { return false }
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        return [event.appName, event.title, event.path ?? "", event.url ?? ""]
            .contains { $0.lowercased().contains(needle) }
    }

    // MARK: Navigation

    func showRecords(block: Date? = nil, event: Int64? = nil) {
        timelineMode = .records
        if let block { selectedBlock = block }
        selectedEventID = event
        pane = .timeline
    }

    /// Opens the timeline narrowed to one tag (0 for untagged); asking for
    /// the tag that is already showing clears the filter.
    func showTag(_ id: Int64) {
        if pane == .timeline, tagFilter == id {
            tagFilter = nil
            return
        }
        tagFilter = id
        if timelineMode == .gantt { timelineMode = .byTag }
        pane = .timeline
    }

    func showReport(_ period: ReportPeriod) {
        reportPeriod = period
        reportAnchor = day
        pane = .reports
    }

    // MARK: Tags and rules

    func setTag(_ tag: Tag, enabled: Bool) {
        guard let id = tag.id else { return }
        try? store.setTagEnabled(id: id, enabled: enabled)
        changed()
    }

    func addTag(name: String, colorIndex: Int, field: RuleField, op: RuleOp, value: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        _ = try? store.addTag(name: trimmed, colorIndex: colorIndex, rule: (field, op, value))
        changed()
    }

    /// A new tag carried by these apps and sites.
    func addTag(name: String, colorIndex: Int, apps: Set<String>, sites: Set<String>) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let id = try? store.addTag(name: trimmed, colorIndex: colorIndex).id else { return }
        try? store.setSources(tagID: id, apps: apps, sites: sites)
        changed()
    }

    func renameTag(_ tag: Tag, to name: String) {
        guard let id = tag.id else { return }
        try? store.renameTag(id: id, to: name)
        changed()
    }

    func setSources(for tag: Tag, apps: Set<String>, sites: Set<String>) {
        guard let id = tag.id else { return }
        try? store.setSources(tagID: id, apps: apps, sites: sites)
        changed()
    }

    /// Counts what was done on this Mac in `period` as `tag`, after the fact.
    func tagPeriod(_ period: DateInterval, as tag: Tag) {
        let end = min(period.end, Date())
        guard let id = tag.id, !isDemo, period.start < end else { return }
        _ = try? store.addSession(tagID: id, from: period.start, to: end)
        sessionNotice = nil
        watcher.splitNow()
        changed()
        runSessionTimer()
    }

    func deleteTag(_ tag: Tag) {
        guard let id = tag.id else { return }
        try? store.deleteTag(id: id)
        changed()
    }

    func setRole(_ role: TagRole, for tag: Tag) {
        guard let id = tag.id else { return }
        try? store.setTagRole(id: id, role: role)
        changed()
    }

    func setGoal(for tag: Tag, kind: Goal.Kind, minutes: Int) {
        guard let id = tag.id else { return }
        try? store.setGoal(tagID: id, kind: kind, minutes: minutes)
        changed()
    }

    func removeGoal(for tag: Tag) {
        guard let id = tag.id else { return }
        try? store.removeGoal(tagID: id)
        changed()
    }

    func addRule(to tag: Tag, field: RuleField, op: RuleOp, value: String) {
        guard let id = tag.id else { return }
        _ = try? store.addRule(tagID: id, field: field, op: op, value: value)
        changed()
    }

    func deleteRule(_ rule: Rule) {
        guard let id = rule.id else { return }
        try? store.deleteRule(id: id)
        changed()
    }

    func moveTag(_ tag: Tag, by delta: Int) {
        guard let id = tag.id else { return }
        try? store.moveTag(id: id, by: delta)
        changed()
    }

    /// Puts `tag` on one record by hand.
    func addTag(_ tag: Tag, to event: ActivityEvent) {
        guard let eventID = event.id, let tagID = tag.id else { return }
        try? store.setManualTag(eventID: eventID, tagID: tagID)
        changed()
    }

    /// Takes `tag` off one record: a hand-added tag is forgotten, an
    /// automatic one is hidden for this record only.
    func removeTag(_ tag: Tag, from event: ActivityEvent) {
        guard let eventID = event.id, let tagID = tag.id else { return }
        if tagger.isManual(tag, for: event) {
            try? store.clearManualTag(eventID: eventID, tagID: tagID)
        } else {
            try? store.setManualTag(eventID: eventID, tagID: tagID, removed: true)
        }
        changed()
    }

    func deleteEvent(_ event: ActivityEvent) {
        guard let id = event.id else { return }
        try? store.deleteEvent(id: id)
        if selectedEventID == id { selectedEventID = nil }
        reload()
    }

    // MARK: Reports and export

    func report(for range: DateInterval) -> RangeReport {
        Analyzer.report(events(in: range), in: range, tagger: tagger, projects: projects)
    }

    func review(for range: DateInterval, previous: DateInterval) -> PeriodReview {
        Analyzer.review(events(in: range), in: range, previous: events(in: previous), in: previous,
                        tagger: tagger, projects: projects)
    }

    /// Asks where to save, then writes every record in `range` as CSV.
    func exportCSV(_ range: DateInterval, name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Trace \(name).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = Analyzer.csv(events(in: range), tagger: tagger)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func eraseAllRecords() {
        try? store.deleteAllEvents()
        reload()
    }

    // MARK: Sync

    /// A "Trace" folder in iCloud Drive, when iCloud Drive is set up on this Mac.
    var iCloudFolder: URL? {
        let drive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: drive.path) else { return nil }
        return drive.appendingPathComponent("Trace", isDirectory: true)
    }

    func chooseSyncFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("Use this folder")
        panel.directoryURL = iCloudFolder?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        enableSync(folder: url)
    }

    func enableSync(folder: URL) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            syncError = error.localizedDescription
            return
        }
        syncFolder = folder.path
        UserDefaults.standard.set(folder.path, forKey: "syncFolder")
        syncNow()
    }

    /// Stops syncing and forgets the other Macs' records here. The files in
    /// the folder stay, so turning sync on again brings everything back.
    func disableSync() {
        syncFolder = nil
        UserDefaults.standard.removeObject(forKey: "syncFolder")
        try? store.removeRemoteData()
        devices = []
        deviceFilter = nil
        lastSync = nil
        syncError = nil
        reload()
    }

    func syncNow() {
        guard !isDemo, !isSyncing, let path = syncFolder else { return }
        isSyncing = true
        let trimmed = deviceName.trimmingCharacters(in: .whitespaces)
        let (store, id, name) = (store, deviceID, trimmed.isEmpty ? (Host.current().localizedName ?? "Mac") : trimmed)
        DispatchQueue.global(qos: .utility).async {
            let outcome: Result<SyncEngine.Result, Error> = Result {
                try SyncEngine(store: store, folder: URL(fileURLWithPath: path, isDirectory: true),
                               deviceID: id, deviceName: name).sync()
            }
            DispatchQueue.main.async {
                self.isSyncing = false
                switch outcome {
                case .success(let result):
                    self.lastSync = Date()
                    self.syncError = nil
                    self.devices = (try? store.devices()) ?? []
                    if result.appliedTagging { self.revision += 1 }
                    if result.importedDays > 0 || result.appliedTagging { self.reload() }
                case .failure(let error):
                    self.syncError = error.localizedDescription
                }
            }
        }
    }

    // MARK: Settings

    private func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Trace: launch at login failed: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboarded")
        showsOnboarding = false
        // One sheet has to be gone before the next can come up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showsTour = true }
    }

    func finishTour() {
        UserDefaults.standard.set(true, forKey: "tourSeen")
        showsTour = false
    }

    func revealDatabase() {
        guard let databaseURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([databaseURL])
    }
}

/// What Trace did to a session because the user was away.
struct SessionNotice: Equatable {
    enum Kind { case deducted, ended }
    var kind: Kind
    var tagName: String
    var left: Date
    var back: Date
    /// The session that was running when the user left.
    var session: Int64
    /// The session that carries on from the return, when time was deducted.
    var resumed: Int64?

    var title: String {
        switch kind {
        case .deducted: return String(format: L("Away %@ – %@"), Fmt.time(left), Fmt.time(back))
        case .ended: return String(format: L("%@ session ended at %@"), tagName, Fmt.time(left))
        }
    }

    var detail: String {
        switch kind {
        case .deducted:
            return String(format: L("%@ left out of the %@ session, which goes on."), Fmt.duration(back.timeIntervalSince(left)), tagName)
        case .ended:
            return L("You were away for a long time, so it ended when you left.")
        }
    }

    var undoTitle: String { kind == .deducted ? L("Count that time") : L("Resume session") }
}
