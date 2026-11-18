import Foundation
import GRDB

/// Local SQLite storage for events, tags and rules.
public final class EventStore: @unchecked Sendable {
    private let db: DatabaseQueue

    /// Opens (or creates) the database file at `path`.
    public init(path: String) throws {
        db = try DatabaseQueue(path: path)
        try migrate()
    }

    /// In-memory database, for tests.
    public init() throws {
        db = try DatabaseQueue()
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "event") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("start", .datetime).notNull().indexed()
                t.column("end", .datetime).notNull().indexed()
                t.column("bundleID", .text).notNull()
                t.column("appName", .text).notNull()
                t.column("category", .text)
                t.column("title", .text).notNull()
                t.column("path", .text)
                t.column("url", .text)
            }
            try db.create(table: "tag") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("key", .text).unique()
                t.column("name", .text).notNull()
                t.column("colorIndex", .integer).notNull()
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("sortOrder", .integer).notNull()
            }
            try db.create(table: "rule") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("tagID", .integer).notNull().indexed()
                    .references("tag", onDelete: .cascade)
                t.column("field", .text).notNull()
                t.column("op", .text).notNull()
                t.column("value", .text).notNull()
            }
        }
        migrator.registerMigration("v2") { db in
            try db.create(table: "eventTag") { t in
                t.column("eventID", .integer).notNull().references("event", onDelete: .cascade)
                t.column("tagID", .integer).notNull().references("tag", onDelete: .cascade)
                t.column("removed", .boolean).notNull().defaults(to: false)
                t.primaryKey(["eventID", "tagID"])
            }
        }
        migrator.registerMigration("v3") { db in
            try db.alter(table: "event") { t in
                t.add(column: "device", .text).notNull().defaults(to: "")
                t.add(column: "syncDay", .text)
            }
            try db.create(index: "event_on_device", on: "event", columns: ["device", "syncDay"])
            try db.create(table: "device") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("lastSeen", .datetime)
            }
            // What has been read from each other Mac's day files.
            try db.create(table: "syncState") { t in
                t.column("device", .text).notNull()
                t.column("day", .text).notNull()
                t.column("stamp", .text).notNull()
                t.primaryKey(["device", "day"])
            }
            try db.create(table: "meta") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
            // A database that already has tags may have been customised, so
            // its tagging counts as edited now; a brand-new one does not.
            if try Tag.fetchCount(db) > 0 {
                try Self.setMeta(db, "taggingUpdated", String(Date().timeIntervalSince1970))
            }
        }
        migrator.registerMigration("v4") { db in
            try db.alter(table: "device") { t in t.add(column: "alias", .text) }
        }
        migrator.registerMigration("v5") { db in
            try db.alter(table: "event") { t in t.add(column: "layer", .integer).notNull().defaults(to: 0) }
            try db.alter(table: "tag") { t in t.add(column: "role", .integer).notNull().defaults(to: 0) }
            for key in ["dev", "study", "design", "office"] {
                try db.execute(sql: "UPDATE tag SET role = 1 WHERE key = ?", arguments: [key])
            }
            try db.execute(sql: "UPDATE tag SET role = 1 WHERE key IS NULL")
            try db.execute(sql: "UPDATE tag SET role = 2 WHERE key IN ('fun', 'games')")
            try db.create(table: "goal") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("tagID", .integer).notNull().unique().references("tag", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("minutes", .integer).notNull()
            }
        }
        migrator.registerMigration("v6") { db in
            try db.create(table: "session") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("tagID", .integer).notNull().references("tag", onDelete: .cascade)
                t.column("start", .datetime).notNull().indexed()
                t.column("end", .datetime)
                t.column("targetMinutes", .integer)
                t.column("device", .text).notNull().defaults(to: "")
            }
        }
        try migrator.migrate(db)
        try seedPresetsIfNeeded()
        try addNewPresetRules()
    }

    // MARK: Events

    /// Records that `sample` was observed at `now`.
    ///
    /// If the latest event describes the same thing and ended at most `pulse`
    /// seconds ago, it is extended; otherwise a new event starts. This keeps one
    /// row per stay instead of one row per sample.
    @discardableResult
    ///
    /// `forceNew` starts a new event even if nothing changed, so that a
    /// session boundary falls between two events instead of inside one.
    public func heartbeat(_ sample: Sample, at now: Date, pulse: TimeInterval = 15,
                          forceNew: Bool = false) throws -> ActivityEvent {
        try db.write { db in
            if !forceNew, var last = try ActivityEvent.filter(Column("device") == "" && Column("layer") == 0)
                .order(Column("id").desc).fetchOne(db),
               last.matches(sample),
               now >= last.end,
               now.timeIntervalSince(last.end) <= pulse {
                last.end = now
                try last.update(db)
                return last
            }
            var event = ActivityEvent(sample: sample, start: now, end: now)
            try event.insert(db)
            return event
        }
    }

    /// Cuts the latest event back to `date`, used when the user turns out to
    /// have been idle since then.
    public func trimLast(to date: Date) throws {
        try db.write { db in
            guard var last = try ActivityEvent.filter(Column("device") == "" && Column("layer") == 0)
                .order(Column("id").desc).fetchOne(db),
                  last.end > date else { return }
            last.end = max(last.start, date)
            try last.update(db)
        }
    }

    /// Events overlapping `[from, to)`, oldest first.
    public func events(from: Date, to: Date) throws -> [ActivityEvent] {
        try db.read { db in
            try ActivityEvent
                .filter(Column("layer") == 0 && Column("end") > from && Column("start") < to)
                .order(Column("start"))
                .fetchAll(db)
        }
    }

    /// What ran in the background (sound, microphone) overlapping `[from, to)`.
    public func background(from: Date, to: Date) throws -> [ActivityEvent] {
        try db.read { db in
            try ActivityEvent
                .filter(Column("layer") > 0 && Column("end") > from && Column("start") < to)
                .order(Column("start"))
                .fetchAll(db)
        }
    }

    /// Records that these apps were playing sound or using the microphone
    /// at `now`. Works like `heartbeat`, one running record per app and layer.
    public func backgroundHeartbeat(_ active: [(bundleID: String, appName: String, layer: Layer)],
                                    at now: Date, pulse: TimeInterval = 15) throws {
        guard !active.isEmpty else { return }
        try db.write { db in
            for item in active where item.layer != .front {
                if var last = try ActivityEvent
                    .filter(Column("device") == "" && Column("layer") == item.layer.rawValue && Column("bundleID") == item.bundleID)
                    .order(Column("id").desc).fetchOne(db),
                   now >= last.end, now.timeIntervalSince(last.end) <= pulse {
                    last.end = now
                    try last.update(db)
                } else {
                    var event = ActivityEvent(sample: Sample(bundleID: item.bundleID, appName: item.appName), start: now, end: now)
                    event.layer = item.layer.rawValue
                    try event.insert(db)
                }
            }
        }
    }

    /// Stores ready-made events, e.g. demo data.
    public func insert(_ events: [ActivityEvent]) throws {
        try db.write { db in
            for var event in events { try event.insert(db) }
        }
    }

    /// Deletes one event. For an event of this Mac, its day is remembered so
    /// that the next sync rewrites that day's file.
    public func deleteEvent(id: Int64, calendar: Calendar = .current) throws {
        try db.write { db in
            guard let event = try ActivityEvent.fetchOne(db, key: id) else { return }
            try event.delete(db)
            if event.isLocal {
                var days = Set((try Self.meta(db, "dirtyDays") ?? "").split(separator: ",").map(String.init))
                days.insert(SyncEngine.dayKey(event.start, calendar: calendar))
                try Self.setMeta(db, "dirtyDays", days.sorted().joined(separator: ","))
            }
        }
    }

    public func eventCount() throws -> Int {
        try db.read { db in try ActivityEvent.filter(Column("layer") == 0).fetchCount(db) }
    }

    // MARK: Tags and rules

    public func tags() throws -> [Tag] {
        try db.read { db in try Tag.order(Column("sortOrder"), Column("id")).fetchAll(db) }
    }

    public func rules() throws -> [Rule] {
        try db.read { db in try Rule.order(Column("id")).fetchAll(db) }
    }

    public func setTagEnabled(id: Int64, enabled: Bool) throws {
        try db.write { db in
            guard var tag = try Tag.fetchOne(db, key: id) else { return }
            tag.enabled = enabled
            try tag.update(db)
            try Self.touchTagging(db)
        }
    }

    /// Creates a custom tag, optionally with one rule. Custom tags sort before
    /// presets so that a specific tag wins over a generic one.
    @discardableResult
    public func addTag(name: String, colorIndex: Int,
                       rule: (field: RuleField, op: RuleOp, value: String)? = nil) throws -> Tag {
        try db.write { db in
            let minOrder = try Int.fetchOne(db, sql: "SELECT MIN(sortOrder) FROM tag") ?? 0
            var tag = Tag(name: name, colorIndex: colorIndex, sortOrder: min(minOrder, 0) - 1)
            try tag.insert(db)
            if let rule, let tagID = tag.id, !rule.value.trimmingCharacters(in: .whitespaces).isEmpty {
                var record = Rule(tagID: tagID, field: rule.field, op: rule.op,
                                  value: rule.value.trimmingCharacters(in: .whitespaces))
                try record.insert(db)
            }
            try Self.touchTagging(db)
            return tag
        }
    }

    public func renameTag(id: Int64, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        try db.write { db in
            guard var tag = try Tag.fetchOne(db, key: id) else { return }
            tag.name = trimmed
            try tag.update(db)
            try Self.touchTagging(db)
        }
    }

    /// Makes the apps and sites that carry a tag match the given ones: a rule
    /// per app (by bundle identifier) and per site (the address contains it).
    /// Rules of other kinds are left alone.
    public func setSources(tagID: Int64, apps: Set<String>, sites: Set<String>) throws {
        try db.write { db in
            var apps = apps, sites = Set(sites.map { $0.lowercased() })
            for rule in try Rule.filter(Column("tagID") == tagID).fetchAll(db) {
                if rule.field == .app, rule.op == .equals {
                    if apps.remove(rule.value) == nil { try rule.delete(db) }
                } else if rule.field == .url, rule.op == .contains {
                    if sites.remove(rule.value.lowercased()) == nil { try rule.delete(db) }
                }
            }
            for app in apps.sorted() where !app.isEmpty {
                var rule = Rule(tagID: tagID, field: .app, op: .equals, value: app)
                try rule.insert(db)
            }
            for site in sites.sorted() where !site.isEmpty {
                var rule = Rule(tagID: tagID, field: .url, op: .contains, value: site)
                try rule.insert(db)
            }
            try Self.touchTagging(db)
        }
    }

    public func deleteTag(id: Int64) throws {
        try db.write { db in
            _ = try Tag.deleteOne(db, key: id)
            try Self.touchTagging(db)
        }
    }

    @discardableResult
    public func addRule(tagID: Int64, field: RuleField, op: RuleOp, value: String) throws -> Rule? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return try db.write { db in
            var rule = Rule(tagID: tagID, field: field, op: op, value: trimmed)
            try rule.insert(db)
            try Self.touchTagging(db)
            return rule
        }
    }

    public func deleteRule(id: Int64) throws {
        try db.write { db in
            _ = try Rule.deleteOne(db, key: id)
            try Self.touchTagging(db)
        }
    }

    /// Moves a tag up (negative `delta`) or down in priority. When several
    /// tags match an event, the one listed first is its primary tag.
    public func moveTag(id: Int64, by delta: Int) throws {
        try db.write { db in
            var tags = try Tag.order(Column("sortOrder"), Column("id")).fetchAll(db)
            guard let index = tags.firstIndex(where: { $0.id == id }) else { return }
            let target = min(max(index + delta, 0), tags.count - 1)
            guard target != index else { return }
            let moved = tags.remove(at: index)
            tags.insert(moved, at: target)
            for (order, var tag) in tags.enumerated() where tag.sortOrder != order {
                tag.sortOrder = order
                try tag.update(db)
            }
            try Self.touchTagging(db)
        }
    }

    public func setTagRole(id: Int64, role: TagRole) throws {
        try db.write { db in
            guard var tag = try Tag.fetchOne(db, key: id) else { return }
            tag.role = role
            try tag.update(db)
            try Self.touchTagging(db)
        }
    }

    // MARK: Sessions

    /// Every session, of this Mac and the others, oldest first.
    public func sessions() throws -> [FocusSession] {
        try db.read { db in try FocusSession.order(Column("start")).fetchAll(db) }
    }

    /// The session running on this Mac, if any.
    public func runningSession() throws -> FocusSession? {
        try db.read { db in
            try FocusSession.filter(Column("device") == "" && Column("end") == nil).order(Column("start").desc).fetchOne(db)
        }
    }

    /// Starts a session on this Mac, ending one that is still running.
    @discardableResult
    public func startSession(tagID: Int64, targetMinutes: Int? = nil, at now: Date = Date()) throws -> FocusSession {
        try db.write { db in
            try db.execute(sql: "UPDATE session SET end = ? WHERE device = '' AND end IS NULL", arguments: [now])
            var session = FocusSession(tagID: tagID, start: now, targetMinutes: targetMinutes)
            try session.insert(db)
            return session
        }
    }

    /// Ends the running session. Returns it, or nil if none was running.
    @discardableResult
    public func endSession(at now: Date = Date()) throws -> FocusSession? {
        try db.write { db in
            guard var session = try FocusSession.filter(Column("device") == "" && Column("end") == nil)
                .order(Column("start").desc).fetchOne(db) else { return nil }
            session.end = max(now, session.start)
            try session.update(db)
            return session
        }
    }

    /// Adds a session after the fact: what was done on this Mac between
    /// `from` and `to` counts as the tag. Records that reach across either end
    /// are cut there, and sessions already in that time make room.
    @discardableResult
    public func addSession(tagID: Int64, from: Date, to: Date) throws -> FocusSession? {
        guard from < to else { return nil }
        return try db.write { db in
            for moment in [from, to] {
                let across = try ActivityEvent
                    .filter(Column("device") == "" && Column("layer") == 0 && Column("start") < moment && Column("end") > moment)
                    .fetchAll(db)
                for var event in across {
                    guard let id = event.id else { continue }
                    var tail = event
                    tail.id = nil
                    tail.start = moment
                    event.end = moment
                    try event.update(db)
                    try tail.insert(db)
                    // Tags put on the record by hand stay on both halves.
                    try db.execute(sql: "INSERT INTO eventTag (eventID, tagID, removed) SELECT ?, tagID, removed FROM eventTag WHERE eventID = ?",
                                   arguments: [tail.id, id])
                }
            }
            for var other in try FocusSession.filter(Column("device") == "").fetchAll(db) {
                let end = other.end ?? .distantFuture
                guard other.start < to, end > from else { continue }
                if other.start >= from, end <= to {
                    try other.delete(db)
                } else if other.start < from, end > to {
                    // The new session sits in the middle: the rest carries on after it.
                    var rest = FocusSession(tagID: other.tagID, start: to, end: other.end)
                    if other.end == nil, let target = other.target {
                        rest.targetMinutes = max(1, Int(((target - to.timeIntervalSince(other.start)) / 60).rounded(.up)))
                    }
                    other.end = from
                    try other.update(db)
                    try rest.insert(db)
                } else if other.start < from {
                    other.end = from
                    try other.update(db)
                } else {
                    other.start = to
                    try other.update(db)
                }
            }
            var session = FocusSession(tagID: tagID, start: from, end: to)
            try session.insert(db)
            return session
        }
    }

    /// Sets when a session of this Mac ended; nil lets it run again. Fails
    /// when another session is running, since only one can.
    @discardableResult
    public func setSessionEnd(id: Int64, to end: Date?) throws -> Bool {
        try db.write { db in
            guard var session = try FocusSession.fetchOne(db, key: id), session.device.isEmpty else { return false }
            if end == nil, try FocusSession.filter(Column("device") == "" && Column("end") == nil && Column("id") != id)
                .fetchCount(db) > 0 { return false }
            session.end = end.map { max($0, session.start) }
            try session.update(db)
            return true
        }
    }

    /// Makes one session of two: the first runs until the second ended (or
    /// still runs, if the second does), and the second is removed.
    @discardableResult
    public func joinSessions(_ first: Int64, _ second: Int64) throws -> Bool {
        try db.write { db in
            guard var a = try FocusSession.fetchOne(db, key: first),
                  let b = try FocusSession.fetchOne(db, key: second),
                  a.device.isEmpty, b.device.isEmpty, b.start >= a.start else { return false }
            a.end = b.end
            try FocusSession.deleteOne(db, key: second)
            try a.update(db)
            return true
        }
    }

    /// Removes a session; the records in it go back to their own tags.
    public func deleteSession(id: Int64) throws {
        _ = try db.write { db in try FocusSession.deleteOne(db, key: id) }
    }

    /// Replaces what is known about another Mac's sessions.
    func replaceRemoteSessions(device: String, with sessions: [FocusSession]) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM session WHERE device = ?", arguments: [device])
            for var session in sessions {
                session.id = nil
                session.device = device
                try session.insert(db)
            }
        }
    }

    // MARK: Goals

    public func goals() throws -> [Goal] {
        try db.read { db in try Goal.order(Column("id")).fetchAll(db) }
    }

    /// Sets the daily goal of a tag, replacing any it had.
    public func setGoal(tagID: Int64, kind: Goal.Kind, minutes: Int) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM goal WHERE tagID = ?", arguments: [tagID])
            var goal = Goal(tagID: tagID, kind: kind, minutes: max(1, minutes))
            try goal.insert(db)
            try Self.touchTagging(db)
        }
    }

    public func removeGoal(tagID: Int64) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM goal WHERE tagID = ?", arguments: [tagID])
            try Self.touchTagging(db)
        }
    }

    public func tagger() throws -> Tagger {
        Tagger(tags: try tags(), rules: try rules(), manual: try manualTags(), sessions: try sessions())
    }

    // MARK: Manual tags

    public func manualTags() throws -> [ManualTag] {
        try db.read { db in try ManualTag.fetchAll(db) }
    }

    /// Adds `tagID` to one event by hand, or (with `removed`) hides a tag
    /// that a rule applied to it.
    public func setManualTag(eventID: Int64, tagID: Int64, removed: Bool = false) throws {
        try db.write { db in try ManualTag(eventID: eventID, tagID: tagID, removed: removed).save(db) }
    }

    /// Forgets a manual change, so the rules decide again.
    public func clearManualTag(eventID: Int64, tagID: Int64) throws {
        _ = try db.write { db in
            try ManualTag.deleteOne(db, key: ["eventID": eventID, "tagID": tagID])
        }
    }

    /// Removes every event, including those brought in from other Macs. With
    /// sync on, this Mac's files are emptied and the others are read again.
    public func deleteAllEvents() throws {
        try db.write { db in
            _ = try ActivityEvent.deleteAll(db)
            try db.execute(sql: "DELETE FROM syncState")
            try Self.setMeta(db, "fullExport", "1")
        }
    }

    // MARK: Sync support

    static func meta(_ db: Database, _ key: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
    }

    static func setMeta(_ db: Database, _ key: String, _ value: String?) throws {
        if let value {
            try db.execute(sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [key, value])
        } else {
            try db.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [key])
        }
    }

    private static func touchTagging(_ db: Database) throws {
        try setMeta(db, "taggingUpdated", String(Date().timeIntervalSince1970))
    }

    func meta(_ key: String) throws -> String? {
        try db.read { db in try Self.meta(db, key) }
    }

    func setMeta(_ key: String, _ value: String?) throws {
        try db.write { db in try Self.setMeta(db, key, value) }
    }

    /// Events recorded on this Mac that start inside `[from, to)`.
    func localEvents(startingFrom from: Date, to: Date) throws -> [ActivityEvent] {
        try db.read { db in
            try ActivityEvent
                .filter(Column("device") == "" && Column("start") >= from && Column("start") < to)
                .order(Column("start"))
                .fetchAll(db)
        }
    }

    func firstLocalStart() throws -> Date? {
        try db.read { db in
            try ActivityEvent.filter(Column("device") == "").order(Column("start")).fetchOne(db)?.start
        }
    }

    /// Replaces what is stored for one day of another Mac. `events == nil`
    /// means the day file is gone.
    func replaceRemote(device: String, day: String, stamp: String?, with events: [ActivityEvent]?) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM event WHERE device = ? AND syncDay = ?", arguments: [device, day])
            for var event in events ?? [] {
                event.id = nil
                event.device = device
                event.syncDay = day
                try event.insert(db)
            }
            if let stamp, events != nil {
                try db.execute(sql: "INSERT INTO syncState (device, day, stamp) VALUES (?, ?, ?) ON CONFLICT(device, day) DO UPDATE SET stamp = excluded.stamp",
                               arguments: [device, day, stamp])
            } else {
                try db.execute(sql: "DELETE FROM syncState WHERE device = ? AND day = ?", arguments: [device, day])
            }
        }
    }

    func syncStamps(device: String) throws -> [String: String] {
        try db.read { db in
            var stamps: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT day, stamp FROM syncState WHERE device = ?", arguments: [device]) {
                stamps[row["day"]] = row["stamp"]
            }
            return stamps
        }
    }

    func saveDevice(_ device: SyncedDevice) throws {
        try db.write { db in
            var device = device
            // The name given here survives whatever the other Mac reports.
            device.alias = try SyncedDevice.fetchOne(db, key: device.id)?.alias
            try device.save(db)
        }
    }

    /// Names another Mac on this Mac only. An empty name goes back to the
    /// name that Mac gave itself.
    public func renameDevice(id: String, to alias: String) throws {
        try db.write { db in
            guard var device = try SyncedDevice.fetchOne(db, key: id) else { return }
            let trimmed = alias.trimmingCharacters(in: .whitespaces)
            device.alias = trimmed.isEmpty || trimmed == device.name ? nil : trimmed
            try device.update(db)
        }
    }

    /// Other Macs whose records are in this database.
    public func devices() throws -> [SyncedDevice] {
        try db.read { db in try SyncedDevice.order(Column("name")).fetchAll(db) }
    }

    /// Forgets everything that came from other Macs. Their files in the
    /// sync folder are not touched.
    public func removeRemoteData() throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM event WHERE device <> ''")
            try db.execute(sql: "DELETE FROM session WHERE device <> ''")
            try db.execute(sql: "DELETE FROM syncState")
            _ = try SyncedDevice.deleteAll(db)
        }
    }

    public func taggingSnapshot() throws -> TaggingSnapshot? {
        try db.read { db in
            guard let raw = try Self.meta(db, "taggingUpdated"), let seconds = Double(raw) else { return nil }
            let rules = Dictionary(grouping: try Rule.order(Column("id")).fetchAll(db), by: \.tagID)
            let goals = Dictionary(uniqueKeysWithValues: try Goal.fetchAll(db).map { ($0.tagID, $0) })
            let tags = try Tag.order(Column("sortOrder"), Column("id")).fetchAll(db).map { tag in
                TaggingSnapshot.TagEntry(key: tag.key, name: tag.name, colorIndex: tag.colorIndex, enabled: tag.enabled,
                                         sortOrder: tag.sortOrder,
                                         rules: (rules[tag.id ?? 0] ?? []).map { .init(field: $0.field, op: $0.op, value: $0.value) },
                                         role: tag.role,
                                         goal: goals[tag.id ?? 0].map { .init(kind: $0.kind, minutes: $0.minutes) })
            }
            return TaggingSnapshot(updated: Date(timeIntervalSince1970: seconds), tags: tags)
        }
    }

    /// Makes tags and rules match `snapshot`. Existing tags are updated in
    /// place (presets by key, custom tags by name) so that tags put on
    /// single records by hand stay attached.
    public func applyTagging(_ snapshot: TaggingSnapshot) throws {
        try db.write { db in
            var remaining = try Tag.fetchAll(db)
            for entry in snapshot.tags {
                let index = remaining.firstIndex { tag in
                    entry.key != nil ? tag.key == entry.key : (tag.key == nil && tag.name == entry.name)
                }
                var tag = index.map { remaining.remove(at: $0) }
                    ?? Tag(key: entry.key, name: entry.name, colorIndex: entry.colorIndex, sortOrder: entry.sortOrder)
                tag.name = entry.name
                tag.colorIndex = entry.colorIndex
                tag.enabled = entry.enabled
                tag.sortOrder = entry.sortOrder
                if let role = entry.role { tag.role = role }
                try tag.save(db)
                guard let tagID = tag.id else { continue }
                try db.execute(sql: "DELETE FROM goal WHERE tagID = ?", arguments: [tagID])
                if let goal = entry.goal {
                    var record = Goal(tagID: tagID, kind: goal.kind, minutes: goal.minutes)
                    try record.insert(db)
                }
                try db.execute(sql: "DELETE FROM rule WHERE tagID = ?", arguments: [tagID])
                for rule in entry.rules {
                    var record = Rule(tagID: tagID, field: rule.field, op: rule.op, value: rule.value)
                    try record.insert(db)
                }
            }
            for tag in remaining { try tag.delete(db) }
            try Self.setMeta(db, "taggingUpdated", String(snapshot.updated.timeIntervalSince1970))
        }
    }

    private func seedPresetsIfNeeded() throws {
        try db.write { db in
            guard try Tag.fetchCount(db) == 0 else { return }
            for (index, preset) in Presets.all.enumerated() {
                var tag = Tag(key: preset.key, name: preset.name,
                              colorIndex: preset.colorIndex, sortOrder: index)
                try tag.insert(db)
                guard let tagID = tag.id else { continue }
                for r in preset.rules + preset.added {
                    var rule = Rule(tagID: tagID, field: r.0, op: r.1, value: r.2)
                    try rule.insert(db)
                }
            }
            try Self.setMeta(db, "presetsVersion", String(Presets.version))
        }
    }

    /// Gives a database created by an earlier version the preset rules that
    /// have been added since. Runs once per version.
    private func addNewPresetRules() throws {
        try db.write { db in
            let have = Int(try Self.meta(db, "presetsVersion") ?? "") ?? 1
            guard have < Presets.version else { return }
            var changed = false
            for preset in Presets.all {
                guard let tag = try Tag.filter(Column("key") == preset.key).fetchOne(db), let tagID = tag.id else { continue }
                let existing = Set(try Rule.filter(Column("tagID") == tagID).fetchAll(db)
                    .map { "\($0.field.rawValue)|\($0.value.lowercased())" })
                for r in preset.added where !existing.contains("\(r.0.rawValue)|\(r.2.lowercased())") {
                    var rule = Rule(tagID: tagID, field: r.0, op: r.1, value: r.2)
                    try rule.insert(db)
                    changed = true
                }
            }
            try Self.setMeta(db, "presetsVersion", String(Presets.version))
            // Publish the additions to other Macs only if this Mac already shares its tagging.
            if changed, try Self.meta(db, "taggingUpdated") != nil { try Self.touchTagging(db) }
        }
    }
}
