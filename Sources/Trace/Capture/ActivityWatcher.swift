import AppKit
import Combine
import TraceCore

/// Samples the frontmost app every couple of seconds and writes heartbeats to
/// the store. Idle time is not stored: it shows up as gaps between events.
@MainActor
final class ActivityWatcher: ObservableObject {
    @Published private(set) var current: Sample?
    @Published private(set) var isTrusted = AXReader.isTrusted
    @Published private(set) var isIdle = false
    /// Trace's own window is in front. It does not record itself.
    @Published private(set) var isSelfInFront = false
    @Published var isPaused = false {
        didSet {
            if isPaused { current = nil } else { resume?.invalidate() }
        }
    }

    /// When the current app, window and page were first seen together.
    @Published private(set) var currentSince: Date?

    /// Seconds without keyboard or mouse input before the user counts as away.
    var idleThreshold: TimeInterval = 180
    /// Bundle identifiers that are never recorded.
    var excluded: Set<String> = []
    var captureTitles = true
    var captureTelegramChats = true
    var captureFiles = true
    var captureURLs = true
    /// Whether to record which apps play sound or use the microphone.
    var captureBackground = true
    /// Whether to record every app that is open, not only the one in front.
    var captureOpenApps = true {
        didSet { if !captureOpenApps, !open.isEmpty { open = [] } }
    }
    /// Every app that was open at the last look.
    @Published private(set) var open: Set<OpenApps.App> = []
    private var lastOpenSample = Date.distantPast
    /// Apps heard or on a call at the last sample.
    @Published private(set) var background: Set<AudioMonitor.Activity> = []
    private var audible: Set<String> = []
    private var onCall = false
    /// Whether sound from an app in the background also counts as being
    /// there. Off: only the app in front, or a call, does.
    var anySoundMeansPresent = false
    private var breakNext = false
    private var resume: Timer?

    private let store: EventStore
    private let queue = DispatchQueue(label: "trace.watcher", qos: .utility)
    private var timer: Timer?
    private var busy = false
    private var categories: [String: String?] = [:]
    private var observer: NSObjectProtocol?
    private var lastWindow: (pid: pid_t, info: AXReader.WindowInfo)?

    private static let interval: TimeInterval = 2
    private static let openInterval: TimeInterval = 10
    private static let ignored: Set<String> = ["com.apple.loginwindow", "com.apple.ScreenSaver.Engine"]
    private static let browsers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    init(store: EventStore) {
        self.store = store
    }

    /// Shows `sample` as the current activity without recording anything.
    func showDemo(_ sample: Sample, since: Date) {
        current = sample
        currentSince = since
        isTrusted = true
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Sample right away on app switches so short stays are not missed.
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    /// Makes the next sample open a new record, so that whatever comes after
    /// this moment is kept apart from what came before. Used when a session
    /// starts or stops.
    func splitNow() {
        breakNext = true
        tick()
    }

    /// Stops recording for `seconds`, then picks up again on its own.
    func pause(for seconds: TimeInterval) {
        isPaused = true
        resume?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.isPaused = false }
        }
        RunLoop.main.add(timer, forMode: .common)
        resume = timer
    }

    private func tick() {
        let trusted = AXReader.isTrusted
        if trusted != isTrusted { isTrusted = trusted }
        guard !isPaused, !busy else { return }

        let now = Date()
        let front = NSWorkspace.shared.frontmostApplication
        let anyInput = CGEventType(rawValue: ~0)!
        let idleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        // No keyboard or mouse is not the same as not being there. Listening in
        // on a call, or watching a video in the app in front, counts; music
        // from the background counts only if the user says so.
        let listening = onCall || (front?.bundleIdentifier.map(audible.contains) ?? false)
            || (anySoundMeansPresent && !audible.isEmpty)
        sampleBackground(at: now)
        if idleSeconds >= idleThreshold && !listening {
            if !isIdle {
                isIdle = true
                current = nil
                // The last event kept growing while nobody was there; cut it back.
                let lastInput = now.addingTimeInterval(-idleSeconds)
                queue.async { [store] in try? store.trimLast(to: lastInput) }
            }
            return
        }
        if isIdle { isIdle = false }
        sampleOpen(at: now)

        let selfInFront = front?.bundleIdentifier == Bundle.main.bundleIdentifier
        if selfInFront != isSelfInFront { isSelfInFront = selfInFront }
        guard let app = front,
              let bundleID = app.bundleIdentifier,
              !Self.ignored.contains(bundleID),
              !selfInFront else {
            if current != nil { current = nil }
            return
        }
        if excluded.contains(bundleID) {
            if current != nil { current = nil }
            return
        }

        let pid = app.processIdentifier
        let name = app.localizedName ?? bundleID
        let category = category(for: bundleID, bundleURL: app.bundleURL)
        let isBrowser = Self.browsers.contains(bundleID)

        busy = true
        let pulse = Self.interval * 5
        let previous = lastWindow?.pid == pid ? lastWindow?.info : nil
        let (titles, files, urls) = (captureTitles, captureFiles, captureURLs)
        let telegramChat = titles && captureTelegramChats && bundleID == "ru.keepcoder.Telegram"
        let forceNew = breakNext
        breakNext = false
        queue.async { [store] in
            let window = trusted
                ? AXReader.focusedWindow(pid: pid, isBrowser: isBrowser && urls, telegramChat: telegramChat, previous: previous) : .init()
            let sample = Sample(bundleID: bundleID, appName: name, category: category,
                                title: titles ? window.title : "",
                                path: files ? window.path : nil, url: urls ? window.url : nil)
            _ = try? store.heartbeat(sample, at: now, pulse: pulse, forceNew: forceNew)
            DispatchQueue.main.async {
                if self.current != sample { self.currentSince = now }
                self.current = sample
                self.lastWindow = (pid, window)
                self.busy = false
            }
        }
    }

    /// Notes which apps are playing sound or using the microphone. Runs on
    /// the watcher's queue; the result is used at the next sample.
    private func sampleBackground(at now: Date) {
        guard captureBackground else {
            if !background.isEmpty { background = [] }
            audible = []
            onCall = false
            return
        }
        let (excluded, pulse) = (excluded, Self.interval * 5)
        queue.async { [store] in
            let active = AudioMonitor.current().filter { !excluded.contains($0.bundleID) }
            try? store.backgroundHeartbeat(active.map { (bundleID: $0.bundleID, appName: $0.appName, layer: $0.layer) }, at: now, pulse: pulse)
            DispatchQueue.main.async {
                if self.background != active { self.background = active }
                self.audible = Set(active.filter { $0.layer == .audio }.map(\.bundleID))
                self.onCall = active.contains { $0.layer == .mic }
            }
        }
    }

    /// Notes every app that is open, and whether a window of it shows. Only
    /// while the user is there: apps left open overnight say nothing.
    private func sampleOpen(at now: Date) {
        guard captureOpenApps, now.timeIntervalSince(lastOpenSample) >= Self.openInterval else { return }
        lastOpenSample = now
        let apps = OpenApps.current(excluding: excluded.union(Self.ignored))
        if apps != open { open = apps }
        let items = apps.map { (bundleID: $0.bundleID, appName: $0.appName, layer: $0.isShowing ? Layer.visible : .open) }
        queue.async { [store] in
            try? store.backgroundHeartbeat(items, at: now, pulse: Self.openInterval * 3)
        }
    }

    private func category(for bundleID: String, bundleURL: URL?) -> String? {
        if let cached = categories[bundleID] { return cached }
        let value = bundleURL.flatMap { Bundle(url: $0) }?
            .object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
        categories[bundleID] = value
        return value
    }
}
