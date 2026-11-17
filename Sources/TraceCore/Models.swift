import Foundation
import GRDB

/// What the watcher sees at one instant: the frontmost app and its focused window.
public struct Sample: Equatable, Sendable {
    public var bundleID: String
    public var appName: String
    public var category: String?
    public var title: String
    public var path: String?
    public var url: String?

    public init(bundleID: String, appName: String, category: String? = nil,
                title: String = "", path: String? = nil, url: String? = nil) {
        self.bundleID = bundleID
        self.appName = appName
        self.category = category
        self.title = title
        self.path = path
        self.url = url
    }
}

/// One uninterrupted stay in the same app, window, document and page.
public struct ActivityEvent: Codable, Identifiable, Equatable, Sendable,
    FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var start: Date
    public var end: Date
    public var bundleID: String
    public var appName: String
    public var category: String?
    public var title: String
    public var path: String?
    public var url: String?
    /// Identifier of the Mac the event was recorded on; empty for this Mac.
    public var device: String = ""
    /// For events from another Mac: the day file they came from.
    public var syncDay: String?
    /// 0 for what was in front; see `Layer` for what ran in the background.
    public var layer: Int = 0

    public static let databaseTableName = "event"

    public var isLocal: Bool { device.isEmpty }

    public init(sample: Sample, start: Date, end: Date) {
        self.start = start
        self.end = end
        bundleID = sample.bundleID
        appName = sample.appName
        category = sample.category
        title = sample.title
        path = sample.path
        url = sample.url
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    public var host: String? {
        guard let url, let host = URL(string: url)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func matches(_ s: Sample) -> Bool {
        bundleID == s.bundleID && title == s.title && path == s.path && url == s.url
    }
}

/// What an event records. Only `front` counts towards tracked time; the
/// others run alongside it.
public enum Layer: Int, Sendable, CaseIterable {
    /// The app and window in front.
    case front = 0
    /// An app playing sound, in front or not.
    case audio = 1
    /// An app using the microphone: a call or a meeting.
    case mic = 2
    /// An app with a window showing on screen, in front or beside it.
    case visible = 3
    /// An app that is open with no window showing: hidden, minimized, on
    /// another desktop or fully covered.
    case open = 4
}

/// How a tag counts when judging focus.
public enum TagRole: Int, Codable, Sendable, CaseIterable {
    case neutral = 0
    /// Work you want long uninterrupted stretches of.
    case focus = 1
    /// Time you would rather keep small.
    case distraction = 2

    /// The role a tag starts with.
    public static func initial(key: String?) -> TagRole {
        switch key {
        case nil, "dev", "study", "design", "office": return .focus
        case "fun", "games": return .distraction
        default: return .neutral
        }
    }
}

/// A stretch of time the user marked by hand: from start to stop, whatever
/// is in front counts as `tagID`. Optionally with a planned length.
public struct FocusSession: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var tagID: Int64
    public var start: Date
    /// Nil while the session is running.
    public var end: Date?
    /// Planned length in minutes; the session ends by itself when it is reached.
    public var targetMinutes: Int?
    /// The Mac the session was run on; empty for this Mac.
    public var device: String = ""

    public static let databaseTableName = "session"

    public init(id: Int64? = nil, tagID: Int64, start: Date, end: Date? = nil, targetMinutes: Int? = nil, device: String = "") {
        self.id = id
        self.tagID = tagID
        self.start = start
        self.end = end
        self.targetMinutes = targetMinutes
        self.device = device
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public var isRunning: Bool { end == nil }
    public var target: TimeInterval? { targetMinutes.map { TimeInterval($0 * 60) } }

    /// Length so far, or in full once ended.
    public func duration(at now: Date = Date()) -> TimeInterval { max(0, (end ?? now).timeIntervalSince(start)) }

    /// Whether an event that started at `date` on `device` falls inside.
    public func contains(_ date: Date, device: String) -> Bool {
        device == self.device && date >= start && date < (end ?? .distantFuture)
    }
}

/// What happens to a running session after time away from the Mac.
public enum AbsenceRule {
    public enum Action: Equatable, Sendable {
        /// Too short to matter: the session runs on as if nothing happened.
        case ignore
        /// The time away is left out and the session goes on.
        case deduct
        /// The session ends at the moment the user left.
        case end
    }

    /// Shorter than this is a break, not an absence.
    public static let shortest: TimeInterval = 15 * 60
    /// From this long on, the session was forgotten.
    public static let longest: TimeInterval = 2 * 3600
    /// A Mac asleep this long was put away.
    public static let longestSleep: TimeInterval = 30 * 60

    public static func action(away: TimeInterval, asleep: TimeInterval = 0) -> Action {
        if away >= longest || asleep >= longestSleep { return .end }
        return away >= shortest ? .deduct : .ignore
    }
}

/// A daily target for a tag: at least, or at most, so many minutes.
public struct Goal: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public enum Kind: String, Codable, Sendable, CaseIterable { case atLeast, atMost }

    public var id: Int64?
    public var tagID: Int64
    public var kind: Kind
    public var minutes: Int

    public static let databaseTableName = "goal"

    public init(id: Int64? = nil, tagID: Int64, kind: Kind, minutes: Int) {
        self.id = id
        self.tagID = tagID
        self.kind = kind
        self.minutes = minutes
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public var seconds: TimeInterval { TimeInterval(minutes * 60) }

    /// Whether a day with `spent` seconds on the tag meets the goal.
    public func isMet(by spent: TimeInterval) -> Bool {
        kind == .atLeast ? spent >= seconds : spent <= seconds
    }
}

/// A label for activity, either a built-in preset (`key` set) or user-defined.
public struct Tag: Codable, Identifiable, Hashable, Sendable,
    FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    /// Stable identifier of a preset tag; nil for custom tags.
    public var key: String?
    public var name: String
    public var colorIndex: Int
    public var enabled: Bool
    public var sortOrder: Int
    public var role: TagRole

    public static let databaseTableName = "tag"

    public init(id: Int64? = nil, key: String? = nil, name: String,
                colorIndex: Int, enabled: Bool = true, sortOrder: Int, role: TagRole? = nil) {
        self.id = id
        self.key = key
        self.name = name
        self.colorIndex = colorIndex
        self.enabled = enabled
        self.sortOrder = sortOrder
        self.role = role ?? TagRole.initial(key: key)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public var isPreset: Bool { key != nil }
}

/// Another Mac whose records were brought in through the sync folder.
public struct SyncedDevice: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public var id: String
    /// The name that Mac gave itself.
    public var name: String
    public var lastSeen: Date?
    /// A name given to it on this Mac, shown instead of `name`.
    public var alias: String?

    public static let databaseTableName = "device"

    public var displayName: String {
        if let alias, !alias.isEmpty { return alias }
        return name
    }

    public init(id: String, name: String, lastSeen: Date? = nil) {
        self.id = id
        self.name = name
        self.lastSeen = lastSeen
    }
}

/// Tags and rules in a form that can be written to a file and applied on
/// another Mac. Presets are matched by key, custom tags by name.
public struct TaggingSnapshot: Codable, Equatable, Sendable {
    public struct RuleEntry: Codable, Equatable, Sendable {
        public var field: RuleField
        public var op: RuleOp
        public var value: String
    }

    public struct TagEntry: Codable, Equatable, Sendable {
        public var key: String?
        public var name: String
        public var colorIndex: Int
        public var enabled: Bool
        public var sortOrder: Int
        public var rules: [RuleEntry]
        public var role: TagRole?
        public var goal: GoalEntry?
    }

    public struct GoalEntry: Codable, Equatable, Sendable {
        public var kind: Goal.Kind
        public var minutes: Int
    }

    public var updated: Date
    public var tags: [TagEntry]
}

/// A tag the user put on, or took off, one specific event by hand.
public struct ManualTag: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public var eventID: Int64
    public var tagID: Int64
    /// True when an automatically applied tag was removed from this event.
    public var removed: Bool

    public static let databaseTableName = "eventTag"

    public init(eventID: Int64, tagID: Int64, removed: Bool = false) {
        self.eventID = eventID
        self.tagID = tagID
        self.removed = removed
    }
}

public enum RuleField: String, Codable, CaseIterable, Sendable {
    case app, category, path, url, title
}

public enum RuleOp: String, Codable, CaseIterable, Sendable {
    case equals, contains, hasPrefix
}

/// A condition that applies a tag automatically.
public struct Rule: Codable, Identifiable, Hashable, Sendable,
    FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var tagID: Int64
    public var field: RuleField
    public var op: RuleOp
    public var value: String

    public static let databaseTableName = "rule"

    public init(id: Int64? = nil, tagID: Int64, field: RuleField, op: RuleOp, value: String) {
        self.id = id
        self.tagID = tagID
        self.field = field
        self.op = op
        self.value = value
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public func matches(_ e: ActivityEvent) -> Bool {
        let needle = value.lowercased()
        guard !needle.isEmpty else { return false }
        let candidates: [String]
        switch field {
        case .app: candidates = [e.bundleID, e.appName]
        case .category: candidates = [e.category ?? ""]
        case .path: candidates = [e.path ?? ""]
        case .url: candidates = [e.url ?? ""]
        case .title: candidates = [e.title]
        }
        return candidates.contains { raw in
            let hay = raw.lowercased()
            guard !hay.isEmpty else { return false }
            switch op {
            case .equals: return hay == needle
            case .contains: return hay.contains(needle)
            case .hasPrefix: return hay.hasPrefix(needle)
            }
        }
    }
}
