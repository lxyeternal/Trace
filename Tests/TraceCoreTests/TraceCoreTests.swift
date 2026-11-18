import XCTest
@testable import TraceCore

final class TraceCoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func xcode(_ file: String) -> Sample {
        Sample(bundleID: "com.apple.dt.Xcode", appName: "Xcode",
               category: "public.app-category.developer-tools",
               title: file, path: "/Users/me/Trace/\(file)")
    }

    func testHeartbeatExtendsSameSampleAndSplitsOnChange() throws {
        let store = try EventStore()
        try store.heartbeat(xcode("A.swift"), at: t0)
        try store.heartbeat(xcode("A.swift"), at: t0 + 2)
        try store.heartbeat(xcode("A.swift"), at: t0 + 4)
        try store.heartbeat(xcode("B.swift"), at: t0 + 6)

        let events = try store.events(from: t0 - 1, to: t0 + 100)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].duration, 4, accuracy: 0.001)
        XCTAssertEqual(events[1].title, "B.swift")
    }

    func testTelegramChatTotalsAcrossRevisits() throws {
        let store = try EventStore()
        for (offset, name) in [(0, "One"), (2, "One"), (4, "Two"), (6, "Two"), (8, "One"), (10, "One")] {
            let sample = Sample(bundleID: "ru.keepcoder.Telegram", appName: "Telegram", title: name)
            try store.heartbeat(sample, at: t0 + Double(offset))
        }
        let range = DateInterval(start: t0, duration: 12)
        let events = try store.events(from: range.start, to: range.end)
        let tree = Analyzer.tree(events, in: range, tagger: try store.tagger(), mode: .byApp)
        let chats = try XCTUnwrap(tree.first?.children)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: chats.map { ($0.label, $0.seconds) }),
                       ["One": 4, "Two": 2])
    }

    func testHeartbeatStartsNewEventAfterLongGap() throws {
        let store = try EventStore()
        try store.heartbeat(xcode("A.swift"), at: t0)
        try store.heartbeat(xcode("A.swift"), at: t0 + 600)
        XCTAssertEqual(try store.eventCount(), 2)
    }

    func testTrimLastCutsIdleTail() throws {
        let store = try EventStore()
        try store.heartbeat(xcode("A.swift"), at: t0)
        try store.heartbeat(xcode("A.swift"), at: t0 + 10)
        try store.trimLast(to: t0 + 4)
        let events = try store.events(from: t0 - 1, to: t0 + 100)
        XCTAssertEqual(events[0].duration, 4, accuracy: 0.001)
    }

    func testPresetsTagByCategoryAndSiteBeforeBrowser() throws {
        let store = try EventStore()
        let tagger = try store.tagger()

        let dev = ActivityEvent(sample: xcode("A.swift"), start: t0, end: t0 + 60)
        XCTAssertEqual(tagger.primary(for: dev)?.key, "dev")

        let video = ActivityEvent(
            sample: Sample(bundleID: "com.apple.Safari", appName: "Safari",
                           title: "Video", url: "https://www.youtube.com/watch"),
            start: t0, end: t0 + 60)
        XCTAssertEqual(tagger.primary(for: video)?.key, "fun")
        XCTAssertEqual(tagger.tags(for: video).map(\.key), ["fun", "browse"])

        let plain = ActivityEvent(
            sample: Sample(bundleID: "com.apple.Safari", appName: "Safari",
                           title: "Example", url: "https://example.com/"),
            start: t0, end: t0 + 60)
        XCTAssertEqual(tagger.primary(for: plain)?.key, "browse")
    }

    func testCustomTagWinsOverPreset() throws {
        let store = try EventStore()
        try store.addTag(name: "Trace", colorIndex: 2, rule: (.path, .contains, "/Trace/"))
        let tagger = try store.tagger()
        let event = ActivityEvent(sample: xcode("A.swift"), start: t0, end: t0 + 60)
        XCTAssertEqual(tagger.primary(for: event)?.name, "Trace")
    }

    func testSummarySplitsAcrossHoursAndClipsToDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let dayStart = calendar.startOfDay(for: t0)
        let day = DateInterval(start: dayStart, duration: 86_400)
        let store = try EventStore()
        let tagger = try store.tagger()

        // 09:30 to 10:30, plus an event that started the previous evening.
        let events = [
            ActivityEvent(sample: xcode("Late.swift"), start: dayStart - 1800, end: dayStart + 600),
            ActivityEvent(sample: xcode("A.swift"), start: dayStart + 9.5 * 3600, end: dayStart + 10.5 * 3600),
        ]
        let summary = Analyzer.summarize(events, in: day, tagger: tagger, calendar: calendar)

        XCTAssertEqual(summary.total, 600 + 3600, accuracy: 0.001)
        let hours = Dictionary(uniqueKeysWithValues: summary.hourly.map { ($0.hour, $0.seconds) })
        XCTAssertEqual(hours[0] ?? 0, 600, accuracy: 0.001)
        XCTAssertEqual(hours[9] ?? 0, 1800, accuracy: 0.001)
        XCTAssertEqual(hours[10] ?? 0, 1800, accuracy: 0.001)
        XCTAssertEqual(summary.byApp.first?.appName, "Xcode")
    }

    func testTreeDrillsFromTagToPage() throws {
        let store = try EventStore()
        let tagger = try store.tagger()
        let day = DateInterval(start: t0 - 10, duration: 86_400)
        let safari = { (title: String, url: String, start: TimeInterval, length: TimeInterval) in
            ActivityEvent(sample: Sample(bundleID: "com.apple.Safari", appName: "Safari", title: title, url: url),
                          start: self.t0 + start, end: self.t0 + start + length)
        }
        let events = [
            safari("AXUIElement", "https://developer.apple.com/documentation/a", 0, 120),
            safari("Accessibility", "https://developer.apple.com/documentation/b", 120, 60),
        ]
        let tree = Analyzer.tree(events, in: day, tagger: tagger, mode: .byTag)

        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].tag?.key, "study")
        let site = tree[0].children?.first?.children?.first
        XCTAssertEqual(site?.label, "developer.apple.com")
        XCTAssertEqual(site?.seconds ?? 0, 180, accuracy: 0.001)
        XCTAssertEqual(site?.children?.map(\.label), ["AXUIElement", "Accessibility"])
    }

    func testBlocksMergeSameTagAcrossShortGaps() throws {
        let store = try EventStore()
        let tagger = try store.tagger()
        let day = DateInterval(start: t0 - 10, duration: 86_400)
        let events = [
            ActivityEvent(sample: xcode("A.swift"), start: t0, end: t0 + 600),
            ActivityEvent(sample: xcode("B.swift"), start: t0 + 660, end: t0 + 900),
            ActivityEvent(sample: xcode("C.swift"), start: t0 + 3000, end: t0 + 3300),
        ]
        let blocks = Analyzer.blocks(events, in: day, tagger: tagger)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].events.count, 2)
        XCTAssertEqual(blocks[0].title, "Xcode · A.swift")
    }

    func testReportSumsDaysAndFillsHeatGrid() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let store = try EventStore()
        let day1 = calendar.startOfDay(for: t0)
        let day3 = day1 + 2 * 86_400
        // 30 minutes at 09:00 on day 1, 90 minutes across 10:30-12:00 on day 3.
        try store.heartbeat(xcode("A.swift"), at: day1 + 9 * 3600)
        try store.heartbeat(xcode("A.swift"), at: day1 + 9 * 3600 + 10, pulse: 15)
        var events = try store.events(from: day1, to: day1 + 7 * 86_400)
        events[0].end = day1 + 9 * 3600 + 1800
        var second = events[0]
        second.id = 2
        second.start = day3 + 10 * 3600 + 1800
        second.end = day3 + 12 * 3600
        events.append(second)

        let range = DateInterval(start: day1, end: day1 + 7 * 86_400)
        let report = Analyzer.report(events, in: range, tagger: try store.tagger(), calendar: calendar)
        XCTAssertEqual(report.days.count, 7)
        XCTAssertEqual(report.total, 7200, accuracy: 0.001)
        XCTAssertEqual(report.activeDays, 2)
        XCTAssertEqual(report.dailyAverage, 3600, accuracy: 0.001)
        XCTAssertEqual(report.busiest?.day, day3)
        XCTAssertEqual(report.days[2].total, 5400, accuracy: 0.001)
        let weekday3 = calendar.component(.weekday, from: day3)
        let cell = report.heat.first { $0.weekday == weekday3 && $0.hour == 11 }
        XCTAssertEqual(cell?.seconds ?? 0, 3600, accuracy: 0.001)
        XCTAssertEqual(report.heat.reduce(0) { $0 + $1.seconds }, 7200, accuracy: 0.001)
    }

    func testAddAndDeleteRuleRetagsEvents() throws {
        let store = try EventStore()
        let tag = try store.addTag(name: "Thesis", colorIndex: 1)
        let event = ActivityEvent(sample: Sample(bundleID: "com.apple.TextEdit", appName: "TextEdit",
                                                 title: "draft.txt", path: "/Users/me/thesis/draft.txt"),
                                  start: t0, end: t0 + 60)
        XCTAssertNotEqual(try store.tagger().primary(for: event)?.id, tag.id)

        let rule = try XCTUnwrap(store.addRule(tagID: tag.id!, field: .path, op: .contains, value: " /thesis/ "))
        XCTAssertEqual(rule.value, "/thesis/")
        XCTAssertEqual(try store.tagger().primary(for: event)?.id, tag.id)
        XCTAssertNil(try store.addRule(tagID: tag.id!, field: .path, op: .contains, value: "  "))

        try store.deleteRule(id: rule.id!)
        XCTAssertNotEqual(try store.tagger().primary(for: event)?.id, tag.id)
    }

    func testMoveTagChangesPriority() throws {
        let store = try EventStore()
        let event = ActivityEvent(sample: xcode("A.swift"), start: t0, end: t0 + 60)
        let dev = try XCTUnwrap(store.tagger().primary(for: event))
        XCTAssertEqual(dev.key, "dev")

        let other = try XCTUnwrap(store.tags().first { $0.key == "office" })
        try store.addRule(tagID: other.id!, field: .path, op: .contains, value: "/Trace/")
        XCTAssertEqual(try store.tagger().primary(for: event)?.key, "dev")

        try store.moveTag(id: other.id!, by: -100)
        XCTAssertEqual(try store.tags().first?.key, "office")
        XCTAssertEqual(try store.tagger().primary(for: event)?.key, "office")
    }

    func testManualTagOverridesRules() throws {
        let store = try EventStore()
        try store.heartbeat(xcode("A.swift"), at: t0)
        let event = try XCTUnwrap(store.events(from: t0 - 1, to: t0 + 1).first)
        let dev = try XCTUnwrap(store.tags().first { $0.key == "dev" })
        let fun = try XCTUnwrap(store.tags().first { $0.key == "fun" })

        try store.setManualTag(eventID: event.id!, tagID: fun.id!)
        var tagger = try store.tagger()
        XCTAssertEqual(tagger.primary(for: event)?.key, "fun")
        XCTAssertEqual(tagger.tags(for: event).map(\.key), ["fun", "dev"])
        XCTAssertTrue(tagger.isManual(fun, for: event))
        XCTAssertFalse(tagger.isManual(dev, for: event))

        try store.setManualTag(eventID: event.id!, tagID: dev.id!, removed: true)
        tagger = try store.tagger()
        XCTAssertEqual(tagger.tags(for: event).map(\.key), ["fun"])

        try store.clearManualTag(eventID: event.id!, tagID: fun.id!)
        try store.clearManualTag(eventID: event.id!, tagID: dev.id!)
        XCTAssertEqual(try store.tagger().tags(for: event).map(\.key), ["dev"])
    }

    func testReportListsSitesFilesAndUntagged() throws {
        let store = try EventStore()
        let tagger = try store.tagger()
        let web = ActivityEvent(sample: Sample(bundleID: "com.apple.Safari", appName: "Safari", title: "Docs",
                                               url: "https://www.example.org/a"), start: t0, end: t0 + 120)
        let file = ActivityEvent(sample: xcode("A.swift"), start: t0 + 120, end: t0 + 180)
        let odd = ActivityEvent(sample: Sample(bundleID: "x.y.Odd", appName: "Odd"), start: t0 + 180, end: t0 + 200)
        let range = DateInterval(start: t0, end: t0 + 3600)
        let report = Analyzer.report([web, file, odd], in: range, tagger: tagger)
        XCTAssertEqual(report.sites.first?.label, "example.org")
        XCTAssertEqual(report.files.first?.label, "/Users/me/Trace/A.swift")

        let loose = Analyzer.untagged([web, file, odd], in: range, tagger: tagger)
        XCTAssertEqual(loose.map(\.label), ["Odd"])
        XCTAssertEqual(loose.first?.field, .app)
        XCTAssertEqual(loose.first?.value, "x.y.Odd")

        let runs = Analyzer.appRuns([web, file, odd], in: range, tagger: tagger)
        XCTAssertEqual(runs.map(\.appName), ["Safari", "Xcode", "Odd"])
    }

    func testCSVQuotesFields() throws {
        let store = try EventStore()
        let e = ActivityEvent(sample: Sample(bundleID: "a.b", appName: "App", title: "say \"hi\", ok"),
                              start: t0, end: t0 + 61)
        let csv = Analyzer.csv([e], tagger: try store.tagger())
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains(",61,\"App\",\"a.b\",\"say \"\"hi\"\", ok\","))
    }

    func testBlocksAbsorbBriefInterruptions() throws {
        let store = try EventStore()
        let tagger = try store.tagger()
        let day = DateInterval(start: t0 - 10, duration: 86_400)
        let mail = Sample(bundleID: "com.apple.mail", appName: "Mail", title: "Inbox")
        let events = [
            ActivityEvent(sample: xcode("A.swift"), start: t0, end: t0 + 600),
            ActivityEvent(sample: mail, start: t0 + 600, end: t0 + 620),
            ActivityEvent(sample: xcode("A.swift"), start: t0 + 620, end: t0 + 1200),
            ActivityEvent(sample: mail, start: t0 + 1200, end: t0 + 1800),
        ]
        let blocks = Analyzer.blocks(events, in: day, tagger: tagger)
        XCTAssertEqual(blocks.map { $0.tag?.key }, ["dev", "comm"])
        XCTAssertEqual(blocks[0].events.count, 3)
        XCTAssertEqual(blocks[0].duration, 1200, accuracy: 0.001)
    }

    func testDemoDataIsTaggedAndStopsAtNow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.startOfDay(for: t0)
        let now = day + 12 * 3600
        let events = DemoData.events(now: now, days: 7, calendar: calendar, home: "/Users/me")
        XCTAssertFalse(events.isEmpty)
        XCTAssertTrue(events.allSatisfy { $0.end <= now && $0.end > $0.start })

        let store = try EventStore()
        try store.insert(events)
        let tagger = try store.tagger()
        let today = try store.events(from: day, to: now)
        XCTAssertEqual(Set(today.compactMap { tagger.primary(for: $0)?.key }), ["dev", "comm"])
        XCTAssertEqual(today.first?.path, "/Users/me/Developer/Trace/Sources/Trace/Views/TimelineView.swift")
    }

    // MARK: Sync

    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trace-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testSyncCopiesRecordsBetweenTwoMacs() throws {
        let folder = try tempFolder()
        let a = try EventStore(), b = try EventStore()
        let syncA = SyncEngine(store: a, folder: folder, deviceID: "mac-a", deviceName: "Studio", calendar: utc)
        let syncB = SyncEngine(store: b, folder: folder, deviceID: "mac-b", deviceName: "Laptop", calendar: utc)

        try a.heartbeat(xcode("A.swift"), at: t0)
        try a.heartbeat(xcode("A.swift"), at: t0 + 10)
        try b.heartbeat(xcode("B.swift"), at: t0 + 100)
        XCTAssertEqual(try syncA.sync(now: t0 + 200).exportedDays, 1)
        let first = try syncB.sync(now: t0 + 200)
        XCTAssertEqual(first.importedDays, 1)

        let inB = try b.events(from: t0 - 1, to: t0 + 1000)
        XCTAssertEqual(inB.map(\.title), ["A.swift", "B.swift"])
        XCTAssertEqual(inB.map(\.device), ["mac-a", ""])
        XCTAssertEqual(inB[0].duration, 10, accuracy: 0.001)
        XCTAssertEqual(try b.devices().map(\.name), ["Studio"])

        // Nothing changed: nothing is read again and nothing is duplicated.
        XCTAssertEqual(try syncB.sync(now: t0 + 300).importedDays, 0)
        XCTAssertEqual(try b.eventCount(), 2)

        // A sees B's record after its next sync, and still has one copy of its own.
        _ = try syncA.sync(now: t0 + 400)
        XCTAssertEqual(try a.events(from: t0 - 1, to: t0 + 1000).map(\.device), ["", "mac-b"])
    }

    func testSyncFollowsChangesAndDeletions() throws {
        let folder = try tempFolder()
        let a = try EventStore(), b = try EventStore()
        let syncA = SyncEngine(store: a, folder: folder, deviceID: "mac-a", deviceName: "Studio", calendar: utc)
        let syncB = SyncEngine(store: b, folder: folder, deviceID: "mac-b", deviceName: "Laptop", calendar: utc)

        try a.heartbeat(xcode("A.swift"), at: t0)
        try a.heartbeat(xcode("B.swift"), at: t0 + 60)
        _ = try syncA.sync(now: t0 + 100)
        _ = try syncB.sync(now: t0 + 100)
        XCTAssertEqual(try b.eventCount(), 2)

        // The record grows on A: B replaces its copy instead of adding one.
        try a.heartbeat(xcode("B.swift"), at: t0 + 70)
        try a.heartbeat(xcode("C.swift"), at: t0 + 80)
        _ = try syncA.sync(now: t0 + 200)
        XCTAssertEqual(try syncB.sync(now: t0 + 200).importedDays, 1)
        XCTAssertEqual(try b.events(from: t0 - 1, to: t0 + 1000).map(\.title), ["A.swift", "B.swift", "C.swift"])

        // Deleting on A removes it on B.
        let doomed = try XCTUnwrap(a.events(from: t0 - 1, to: t0 + 1000).first { $0.title == "A.swift" })
        try a.deleteEvent(id: doomed.id!, calendar: utc)
        _ = try syncA.sync(now: t0 + 300)
        _ = try syncB.sync(now: t0 + 300)
        XCTAssertEqual(try b.events(from: t0 - 1, to: t0 + 1000).map(\.title), ["B.swift", "C.swift"])

        // Erasing everything on A empties its folder; B drops A's records.
        try a.deleteAllEvents()
        _ = try syncA.sync(now: t0 + 400)
        _ = try syncB.sync(now: t0 + 400)
        XCTAssertEqual(try b.eventCount(), 0)
    }

    func testHeartbeatIgnoresRecordsFromOtherMacs() throws {
        let folder = try tempFolder()
        let a = try EventStore(), b = try EventStore()
        try b.heartbeat(xcode("B.swift"), at: t0)
        try a.heartbeat(xcode("A.swift"), at: t0 + 5)
        _ = try SyncEngine(store: a, folder: folder, deviceID: "mac-a", deviceName: "A", calendar: utc).sync(now: t0 + 6)
        _ = try SyncEngine(store: b, folder: folder, deviceID: "mac-b", deviceName: "B", calendar: utc).sync(now: t0 + 6)

        // The imported record has the newest id, but B keeps extending its own.
        try b.heartbeat(xcode("B.swift"), at: t0 + 8)
        let own = try b.events(from: t0 - 1, to: t0 + 100).filter(\.isLocal)
        XCTAssertEqual(own.count, 1)
        XCTAssertEqual(own[0].duration, 8, accuracy: 0.001)
    }

    func testSyncSharesTagsAndRulesNewestWins() throws {
        let folder = try tempFolder()
        let a = try EventStore(), b = try EventStore()
        let syncA = SyncEngine(store: a, folder: folder, deviceID: "mac-a", deviceName: "A", calendar: utc)
        let syncB = SyncEngine(store: b, folder: folder, deviceID: "mac-b", deviceName: "B", calendar: utc)

        // Untouched presets are not published.
        _ = try syncA.sync(now: t0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("tagging.json").path))

        let thesis = try a.addTag(name: "Thesis", colorIndex: 1, rule: (.path, .contains, "/thesis/"))
        _ = try syncA.sync(now: t0)
        XCTAssertTrue(try syncB.sync(now: t0).appliedTagging)
        let inB = try XCTUnwrap(b.tags().first { $0.name == "Thesis" })
        XCTAssertEqual(try b.rules().filter { $0.tagID == inB.id }.map(\.value), ["/thesis/"])
        XCTAssertEqual(try b.tags().count, try a.tags().count)

        // A later edit on B travels back to A, and A keeps the same tag row.
        Thread.sleep(forTimeInterval: 1.1)
        try b.addRule(tagID: inB.id!, field: .app, op: .equals, value: "Zotero")
        XCTAssertFalse(try syncB.sync(now: t0).appliedTagging)
        XCTAssertTrue(try syncA.sync(now: t0).appliedTagging)
        XCTAssertEqual(try a.rules().filter { $0.tagID == thesis.id }.map(\.value).sorted(), ["/thesis/", "Zotero"])

        // Deleting the tag on A removes it on B.
        Thread.sleep(forTimeInterval: 1.1)
        try a.deleteTag(id: thesis.id!)
        _ = try syncA.sync(now: t0)
        _ = try syncB.sync(now: t0)
        XCTAssertNil(try b.tags().first { $0.name == "Thesis" })
    }

    func testOverlappingMacsKeepSeparateSessions() throws {
        let store = try EventStore()
        let tagger = try store.tagger()
        let day = DateInterval(start: t0 - 10, duration: 86_400)
        var remote = ActivityEvent(sample: Sample(bundleID: "com.apple.mail", appName: "Mail", title: "Inbox"),
                                   start: t0 + 300, end: t0 + 900)
        remote.device = "mac-b"
        let events = [
            ActivityEvent(sample: xcode("A.swift"), start: t0, end: t0 + 600),
            remote,
            ActivityEvent(sample: xcode("A.swift"), start: t0 + 600, end: t0 + 1200),
        ]
        let blocks = Analyzer.blocks(events, in: day, tagger: tagger)
        XCTAssertEqual(blocks.map(\.device), ["", "mac-b"])
        XCTAssertEqual(blocks[0].duration, 1200, accuracy: 0.001)
        XCTAssertEqual(blocks[1].duration, 600, accuracy: 0.001)
        // Both count: the total is the sum, not the union.
        XCTAssertEqual(Analyzer.summarize(events, in: day, tagger: tagger).total, 1800, accuracy: 0.001)

        let lanes = Lanes.assign(blocks.map { ($0.start, $0.end) })
        XCTAssertEqual(lanes.map(\.lane), [0, 1])
        XCTAssertEqual(lanes.map(\.of), [2, 2])
        let apart = Lanes.assign([(t0, t0 + 10), (t0 + 10, t0 + 20)])
        XCTAssertEqual(apart.map(\.of), [1, 1])
    }

    func testDeviceAliasSurvivesSyncAndReportSplitsByMac() throws {
        let folder = try tempFolder()
        let a = try EventStore(), b = try EventStore()
        let syncA = SyncEngine(store: a, folder: folder, deviceID: "mac-a", deviceName: "Studio", calendar: utc)
        let syncB = SyncEngine(store: b, folder: folder, deviceID: "mac-b", deviceName: "Laptop", calendar: utc)
        try a.heartbeat(xcode("A.swift"), at: t0)
        try a.heartbeat(xcode("A.swift"), at: t0 + 60, pulse: 100)
        try b.heartbeat(xcode("B.swift"), at: t0)
        try b.heartbeat(xcode("B.swift"), at: t0 + 20, pulse: 100)
        _ = try syncA.sync(now: t0 + 100)
        _ = try syncB.sync(now: t0 + 100)

        try b.renameDevice(id: "mac-a", to: " Lab ")
        XCTAssertEqual(try b.devices().first?.displayName, "Lab")
        try a.heartbeat(xcode("C.swift"), at: t0 + 70)
        _ = try syncA.sync(now: t0 + 200)
        _ = try syncB.sync(now: t0 + 200)
        XCTAssertEqual(try b.devices().first?.displayName, "Lab")
        try b.renameDevice(id: "mac-a", to: "")
        XCTAssertEqual(try b.devices().first?.displayName, "Studio")

        let range = DateInterval(start: t0 - 10, duration: 3600)
        let report = Analyzer.report(try b.events(from: range.start, to: range.end), in: range, tagger: try b.tagger())
        XCTAssertEqual(report.byDevice.map(\.label), ["mac-a", ""])
        XCTAssertEqual(report.byDevice.map(\.seconds), [60, 20])
    }

    func testWiderPresetsCoverCommonAppsAndSites() throws {
        let store = try EventStore()
        let tagger = try store.tagger()
        func key(_ bundleID: String, url: String? = nil) -> String? {
            tagger.primary(for: ActivityEvent(sample: Sample(bundleID: bundleID, appName: "x", url: url),
                                              start: t0, end: t0 + 1))?.key
        }
        XCTAssertEqual(key("com.tencent.qq"), "comm")
        XCTAssertEqual(key("com.tencent.meeting"), "comm")
        XCTAssertEqual(key("com.netease.163music"), "fun")
        XCTAssertEqual(key("com.jetbrains.pycharm"), "dev")
        XCTAssertEqual(key("org.zotero.zotero"), "study")
        XCTAssertEqual(key("md.obsidian"), "office")
        XCTAssertEqual(key("com.adobe.Photoshop"), "design")
        XCTAssertEqual(key("com.microsoft.edgemac", url: "https://arxiv.org/abs/1234"), "study")
        XCTAssertEqual(key("com.microsoft.edgemac", url: "https://x.com/home"), "fun")
        XCTAssertEqual(key("com.microsoft.edgemac", url: "https://example.com/"), "browse")
        // No two presets claim the same app or site.
        var seen: [String: String] = [:]
        for preset in Presets.all {
            for rule in preset.rules + preset.added {
                let id = "\(rule.0.rawValue)|\(rule.2.lowercased())"
                XCTAssertNil(seen[id], "\(id) is in both \(seen[id] ?? "") and \(preset.key)")
                seen[id] = preset.key
            }
        }
    }

    // MARK: Background, Gantt, focus, goals, projects, review

    private func mail(_ title: String = "Inbox") -> Sample {
        Sample(bundleID: "com.apple.mail", appName: "Mail", title: title)
    }

    private func event(_ sample: Sample, _ from: TimeInterval, _ to: TimeInterval, device: String = "") -> ActivityEvent {
        var e = ActivityEvent(sample: sample, start: t0 + from, end: t0 + to)
        e.device = device
        return e
    }

    func testBackgroundActivityIsKeptApartFromTrackedTime() throws {
        let store = try EventStore()
        let music = (bundleID: "com.apple.Music", appName: "Music", layer: Layer.audio)
        let call = (bundleID: "us.zoom.xos", appName: "zoom.us", layer: Layer.mic)
        try store.heartbeat(xcode("A.swift"), at: t0)
        try store.backgroundHeartbeat([music], at: t0)
        try store.backgroundHeartbeat([music, call], at: t0 + 10)
        try store.heartbeat(xcode("A.swift"), at: t0 + 10)
        try store.backgroundHeartbeat([music], at: t0 + 20)
        try store.backgroundHeartbeat([music], at: t0 + 600)   // after a pause: a new record

        let front = try store.events(from: t0 - 1, to: t0 + 1000)
        XCTAssertEqual(front.count, 1)
        XCTAssertEqual(front[0].duration, 10, accuracy: 0.001)
        XCTAssertEqual(try store.eventCount(), 1)

        let background = try store.background(from: t0 - 1, to: t0 + 1000)
        XCTAssertEqual(background.map(\.layer), [1, 2, 1])
        XCTAssertEqual(background[0].duration, 20, accuracy: 0.001)

        // It travels through sync with its layer.
        let folder = try tempFolder()
        let other = try EventStore()
        _ = try SyncEngine(store: store, folder: folder, deviceID: "a", deviceName: "A", calendar: utc).sync(now: t0 + 700)
        _ = try SyncEngine(store: other, folder: folder, deviceID: "b", deviceName: "B", calendar: utc).sync(now: t0 + 700)
        XCTAssertEqual(try other.events(from: t0 - 1, to: t0 + 1000).count, 1)
        XCTAssertEqual(try other.background(from: t0 - 1, to: t0 + 1000).map(\.layer), [1, 2, 1])
    }

    func testOpenAppsAreRecordedBesideTheFrontAppAndGetTheirOwnLanes() throws {
        let store = try EventStore()
        let zoom = (bundleID: "us.zoom.xos", appName: "zoom.us", layer: Layer.visible)
        let edge = (bundleID: "com.microsoft.edgemac", appName: "Microsoft Edge", layer: Layer.open)
        let edgeShown = (bundleID: "com.microsoft.edgemac", appName: "Microsoft Edge", layer: Layer.visible)
        for step in 0...30 { try store.backgroundHeartbeat([zoom, edge], at: t0 + Double(step) * 10, pulse: 30) }
        // Edge comes on screen: its hidden record stops and a showing one starts.
        for step in 31...60 { try store.backgroundHeartbeat([zoom, edgeShown], at: t0 + Double(step) * 10, pulse: 30) }
        _ = try store.heartbeat(xcode("A.swift"), at: t0)
        _ = try store.heartbeat(xcode("A.swift"), at: t0 + 10)

        // Tracked time is still only what was in front.
        XCTAssertEqual(try store.events(from: t0 - 1, to: t0 + 1000).count, 1)
        let background = try store.background(from: t0 - 1, to: t0 + 1000)
        XCTAssertEqual(background.map(\.layer).sorted(), [3, 3, 4])

        let day = DateInterval(start: t0 - 10, duration: 86_400)
        let gantt = Analyzer.gantt(try store.events(from: day.start, to: day.end), background: background, in: day,
                                   tagger: try store.tagger(), grouping: .app)
        XCTAssertTrue(gantt.background.isEmpty)                    // no sound, no call
        XCTAssertEqual(gantt.open.map(\.label), ["zoom.us", "Microsoft Edge"])   // longest on screen first
        XCTAssertEqual(gantt.open[0].seconds, 600, accuracy: 0.001)
        XCTAssertEqual(gantt.open[0].bars.map(\.faint), [false])
        XCTAssertEqual(gantt.open[1].bars.map(\.faint), [true, false])
        XCTAssertEqual(gantt.open[1].seconds, 590, accuracy: 0.001)
    }

    func testGanttBuildsLanesForTagsAppsSoundAndMacs() throws {
        let store = try EventStore()
        let tagger = try store.tagger()
        let day = DateInterval(start: t0 - 10, duration: 86_400)
        var song = event(Sample(bundleID: "com.apple.Music", appName: "Music"), 0, 1500)
        song.layer = Layer.audio.rawValue
        var song2 = event(Sample(bundleID: "com.spotify.client", appName: "Spotify"), 1000, 2000)
        song2.layer = Layer.audio.rawValue
        let events = [event(xcode("A.swift"), 0, 600), event(mail(), 600, 700), event(xcode("B.swift"), 700, 1800),
                      event(mail(), 900, 1200, device: "mac-b")]

        let byTag = Analyzer.gantt(events, background: [song, song2], in: day, tagger: tagger, grouping: .tag,
                                   deviceName: { $0.isEmpty ? "Here" : "There" })
        XCTAssertEqual(byTag.rows.map { $0.tag?.key }, ["dev", "comm"])
        XCTAssertEqual(byTag.rows[0].seconds, 1700, accuracy: 0.001)
        XCTAssertEqual(byTag.rows[0].bars.count, 2)                 // the mail break splits the lane
        XCTAssertEqual(byTag.background.map(\.kind), [.audio])
        XCTAssertEqual(byTag.background[0].bars.map(\.label), ["Music", "Spotify"])
        XCTAssertEqual(byTag.background[0].seconds, 2000, accuracy: 0.001)   // the overlap counts once
        XCTAssertEqual(byTag.devices.map(\.label), ["Here", "There"])

        let byApp = Analyzer.gantt(events, in: day, tagger: tagger, grouping: .app)
        XCTAssertEqual(byApp.rows.map(\.label), ["Xcode", "Mail"])
        XCTAssertTrue(byApp.background.isEmpty)
    }

    func testFocusCountsDeepWorkSwitchesAndInterrupters() throws {
        let store = try EventStore()
        let tagger = try store.tagger()
        let day = DateInterval(start: t0 - 10, duration: 86_400)
        let video = Sample(bundleID: "com.apple.Safari", appName: "Safari", title: "Video", url: "https://www.youtube.com/watch")
        let events = [
            event(xcode("A.swift"), 0, 1200),          // 20 min
            event(mail(), 1200, 1230),                 // 30 s glance: does not break the session
            event(xcode("A.swift"), 1230, 2400),       // session of 40 min in all
            event(mail(), 2400, 3000),                 // 10 min of mail
            event(xcode("B.swift"), 3000, 3600),       // 10 min: too short to be deep work
            event(video, 3600, 4200),
        ]
        let focus = Analyzer.focus(events, in: day, tagger: tagger, calendar: utc)
        XCTAssertEqual(focus.deepCount, 1)
        XCTAssertEqual(focus.deepSeconds, 2400, accuracy: 0.001)
        XCTAssertEqual(focus.focusSeconds, 2970, accuracy: 0.001)
        XCTAssertEqual(focus.distractionSeconds, 600, accuracy: 0.001)
        XCTAssertEqual(focus.switches, 5)
        XCTAssertEqual(focus.interrupters.map(\.appName), ["Mail", "Safari"])
        XCTAssertEqual(focus.interrupters.first?.count, 2)
        XCTAssertEqual(focus.deepShare, 2400.0 / 4200, accuracy: 0.001)
    }

    func testGoalsAreStoredSyncedAndStreaksCounted() throws {
        let folder = try tempFolder()
        let a = try EventStore(), b = try EventStore()
        let dev = try XCTUnwrap(a.tags().first { $0.key == "dev" })
        XCTAssertEqual(dev.role, .focus)
        XCTAssertEqual(try a.tags().first { $0.key == "fun" }?.role, .distraction)
        XCTAssertEqual(try a.tags().first { $0.key == "comm" }?.role, .neutral)

        try a.setGoal(tagID: dev.id!, kind: .atLeast, minutes: 240)
        try a.setGoal(tagID: dev.id!, kind: .atLeast, minutes: 120)   // replaces the first
        try a.setTagRole(id: dev.id!, role: .neutral)
        XCTAssertEqual(try a.goals().map(\.minutes), [120])
        _ = try SyncEngine(store: a, folder: folder, deviceID: "a", deviceName: "A", calendar: utc).sync(now: t0)
        _ = try SyncEngine(store: b, folder: folder, deviceID: "b", deviceName: "B", calendar: utc).sync(now: t0)
        let devB = try XCTUnwrap(b.tags().first { $0.key == "dev" })
        XCTAssertEqual(devB.role, .neutral)
        XCTAssertEqual(try b.goals().first?.tagID, devB.id)
        XCTAssertEqual(try b.goals().first?.minutes, 120)

        let goal = try XCTUnwrap(a.goals().first)
        XCTAssertTrue(goal.isMet(by: 7200))
        XCTAssertFalse(goal.isMet(by: 7199))
        let today = utc.startOfDay(for: t0)
        func dayTotal(_ back: Int, _ hours: Double) -> DayTotal {
            DayTotal(day: today - TimeInterval(back * 86_400), total: hours * 3600,
                     byTag: [TagTotal(tag: dev, seconds: hours * 3600)])
        }
        // Today not there yet, three good days before it, then a miss.
        let days = [dayTotal(0, 1), dayTotal(1, 3), dayTotal(2, 2), dayTotal(3, 2.5), dayTotal(4, 1), dayTotal(5, 4)]
        XCTAssertEqual(Analyzer.streak(for: goal, days: days, today: t0, calendar: utc), 3)
        XCTAssertEqual(Analyzer.streak(for: goal, days: [dayTotal(0, 2)] + days.dropFirst(), today: t0, calendar: utc), 4)

        try a.removeGoal(tagID: dev.id!)
        XCTAssertTrue(try a.goals().isEmpty)
    }

    func testProjectsAreFoundFromMarkersAndFolders() throws {
        let onDisk: Set<String> = ["/Users/me/code/app/Sources/UI", "/Users/me/code/app/.git", "/Users/me/Documents/Thesis/ch"]
        let resolver = ProjectResolver(home: "/Users/me") { onDisk.contains($0) }
        XCTAssertEqual(resolver.project(for: "/Users/me/code/app/Sources/UI/View.swift")?.name, "app")
        XCTAssertEqual(resolver.project(for: "/Users/me/code/app/Sources/UI/View.swift")?.id, "/Users/me/code/app")
        XCTAssertEqual(resolver.project(for: "/Users/me/Documents/Thesis/ch/one.tex")?.name, "Thesis")
        XCTAssertNil(resolver.project(for: "/Users/me/Documents/notes.txt"))
        // A file from another Mac: only the path is known.
        XCTAssertEqual(resolver.project(for: "/Users/lab/Developer/Parser/src/main.c")?.name, "Parser")
        XCTAssertEqual(resolver.project(for: "/Users/lab/Developer/Parser/src/lexer/scan.c")?.name, "Parser")
        XCTAssertEqual(resolver.project(for: "/Users/lab/Documents/GitHub/Site/index.html")?.name, "Site")
        XCTAssertNil(resolver.project(for: "/var/log/system.log"))

        let store = try EventStore()
        let day = DateInterval(start: t0 - 10, duration: 86_400)
        let file = Sample(bundleID: "com.apple.dt.Xcode", appName: "Xcode", title: "View.swift",
                          path: "/Users/me/code/app/Sources/UI/View.swift")
        let events = [event(file, 0, 600), event(mail(), 600, 900)]
        let tree = Analyzer.tree(events, in: day, tagger: try store.tagger(), mode: .byProject, projects: resolver)
        XCTAssertEqual(tree.map(\.label), ["app"])
        XCTAssertEqual(tree[0].kind, .project)
        XCTAssertEqual(tree[0].seconds, 600, accuracy: 0.001)
        XCTAssertEqual(tree[0].children?.first?.label, "Xcode")
        let report = Analyzer.report(events, in: day, tagger: try store.tagger(), calendar: utc, projects: resolver)
        XCTAssertEqual(report.projects.map(\.label), ["app"])
    }

    func testReviewComparesWithThePeriodBefore() throws {
        let store = try EventStore()
        let tagger = try store.tagger()
        let start = utc.startOfDay(for: t0)
        let previous = DateInterval(start: start - 7 * 86_400, duration: 7 * 86_400)
        let current = DateInterval(start: start, duration: 7 * 86_400)
        func at(_ base: Date, _ sample: Sample, _ from: TimeInterval, _ minutes: Double) -> ActivityEvent {
            ActivityEvent(sample: sample, start: base + from, end: base + from + minutes * 60)
        }
        let zotero = Sample(bundleID: "org.zotero.zotero", appName: "Zotero", title: "Library")
        let before = [at(previous.start, xcode("A.swift"), 9 * 3600, 60), at(previous.start, mail(), 11 * 3600, 60)]
        let now = [at(current.start, xcode("A.swift"), 9 * 3600, 120), at(current.start, mail(), 12 * 3600, 20),
                   at(current.start + 86_400, zotero, 9 * 3600, 30)]
        let review = Analyzer.review(now, in: current, previous: before, in: previous, tagger: tagger, calendar: utc)
        XCTAssertEqual(review.total, 170 * 60, accuracy: 0.001)
        XCTAssertEqual(review.previousTotal, 120 * 60, accuracy: 0.001)
        XCTAssertEqual(review.topTag?.tag?.key, "dev")
        XCTAssertEqual(review.risers.map { $0.tag?.key }, ["dev", "study"])
        XCTAssertEqual(review.fallers.map { $0.tag?.key }, ["comm"])
        XCTAssertEqual(review.newApps, ["Zotero"])
        XCTAssertEqual(review.busiest?.day, current.start)
        XCTAssertEqual(review.deepSeconds, 150 * 60, accuracy: 0.001)       // 2 h of Xcode and 30 min of Zotero
        XCTAssertEqual(review.previousDeepSeconds, 60 * 60, accuracy: 0.001)
        XCTAssertEqual(review.bestFocusDay?.day, current.start)
    }

    // MARK: Sessions

    func testSessionClaimsEverythingBetweenStartAndStop() throws {
        let store = try EventStore()
        let games = try XCTUnwrap(store.tags().first { $0.key == "games" })
        let day = DateInterval(start: t0 - 10, duration: 86_400)

        try store.heartbeat(xcode("A.swift"), at: t0)
        try store.heartbeat(xcode("A.swift"), at: t0 + 10)
        // Start: the next sample opens a new record even though nothing changed.
        let session = try store.startSession(tagID: games.id!, at: t0 + 12)
        try store.heartbeat(xcode("A.swift"), at: t0 + 12, forceNew: true)
        try store.heartbeat(xcode("A.swift"), at: t0 + 20)
        try store.heartbeat(mail(), at: t0 + 30)
        try store.heartbeat(mail(), at: t0 + 40)
        XCTAssertEqual(try store.runningSession()?.id, session.id)
        try store.endSession(at: t0 + 45)
        try store.heartbeat(mail(), at: t0 + 45, forceNew: true)
        try store.heartbeat(mail(), at: t0 + 60)
        XCTAssertNil(try store.runningSession())

        let events = try store.events(from: t0 - 1, to: t0 + 100)
        XCTAssertEqual(events.count, 4)
        var tagger = try store.tagger()
        XCTAssertEqual(events.map { tagger.primary(for: $0)?.key }, ["dev", "games", "games", "comm"])
        // The record keeps its own tag as well, after the session's.
        XCTAssertEqual(tagger.tags(for: events[1]).map(\.key), ["games", "dev"])
        XCTAssertEqual(Analyzer.summarize(events, in: day, tagger: tagger).byTag.first?.tag?.key, "games")

        // A tag put on one record by hand still wins; removing the session's tag works too.
        let study = try XCTUnwrap(store.tags().first { $0.key == "study" })
        try store.setManualTag(eventID: events[1].id!, tagID: study.id!)
        try store.setManualTag(eventID: events[2].id!, tagID: games.id!, removed: true)
        tagger = try store.tagger()
        XCTAssertEqual(tagger.primary(for: events[1])?.key, "study")
        XCTAssertEqual(tagger.primary(for: events[2])?.key, "comm")

        // Deleting the session gives the records back their own tags.
        try store.clearManualTag(eventID: events[1].id!, tagID: study.id!)
        try store.deleteSession(id: session.id!)
        XCTAssertEqual(try store.tagger().primary(for: events[1])?.key, "dev")
    }

    func testStartingASessionEndsTheRunningOneAndSessionsSync() throws {
        let folder = try tempFolder()
        let a = try EventStore(), b = try EventStore()
        let games = try XCTUnwrap(a.tags().first { $0.key == "games" })
        let study = try XCTUnwrap(a.tags().first { $0.key == "study" })
        try a.startSession(tagID: games.id!, at: t0)
        try a.heartbeat(xcode("A.swift"), at: t0 + 5)
        try a.heartbeat(xcode("A.swift"), at: t0 + 15)
        let second = try a.startSession(tagID: study.id!, targetMinutes: 120, at: t0 + 100)
        let all = try a.sessions()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].end, t0 + 100)
        XCTAssertTrue(all[1].isRunning)
        XCTAssertEqual(second.target, 7200)
        XCTAssertEqual(all[1].duration(at: t0 + 160), 60, accuracy: 0.001)

        _ = try SyncEngine(store: a, folder: folder, deviceID: "a", deviceName: "A", calendar: utc).sync(now: t0 + 200)
        _ = try SyncEngine(store: b, folder: folder, deviceID: "b", deviceName: "B", calendar: utc).sync(now: t0 + 200)
        let inB = try b.sessions()
        XCTAssertEqual(inB.map(\.device), ["a", "a"])
        XCTAssertEqual(inB[1].targetMinutes, 120)
        // A's record shows as Games on B; a record of B's at the same time is untouched.
        try b.heartbeat(xcode("B.swift"), at: t0 + 6)
        let events = try b.events(from: t0 - 1, to: t0 + 50)
        let tagger = try b.tagger()
        XCTAssertEqual(events.map { "\($0.device):\(tagger.primary(for: $0)?.key ?? "")" }, ["a:games", ":dev"])
        // B has no session of its own running.
        XCTAssertNil(try b.runningSession())
    }

    func testAbsenceRule() {
        XCTAssertEqual(AbsenceRule.action(away: 14 * 60), .ignore)
        XCTAssertEqual(AbsenceRule.action(away: 15 * 60), .deduct)
        XCTAssertEqual(AbsenceRule.action(away: 119 * 60), .deduct)
        XCTAssertEqual(AbsenceRule.action(away: 2 * 3600), .end)
        // A Mac that slept for half an hour was put away, however short the absence.
        XCTAssertEqual(AbsenceRule.action(away: 40 * 60, asleep: 30 * 60), .end)
        XCTAssertEqual(AbsenceRule.action(away: 40 * 60, asleep: 29 * 60), .deduct)
    }

    func testTimeAwayIsTakenOutOfASessionAndCanBeCountedAgain() throws {
        let store = try EventStore()
        let tag = try XCTUnwrap(try store.tags().first?.id)
        let first = try XCTUnwrap(try store.startSession(tagID: tag, targetMinutes: 50, at: t0).id)
        // Left after 20 minutes, back 40 minutes later.
        let (left, back) = (t0 + 20 * 60, t0 + 60 * 60)
        try store.endSession(at: left)
        let second = try XCTUnwrap(try store.startSession(tagID: tag, targetMinutes: 30, at: back).id)
        XCTAssertEqual(try store.sessions().map { $0.duration(at: back + 600) }, [20 * 60, 600])

        XCTAssertTrue(try store.joinSessions(first, second))
        let joined = try store.sessions()
        XCTAssertEqual(joined.count, 1)
        XCTAssertEqual(joined[0].start, t0)
        XCTAssertTrue(joined[0].isRunning)
        XCTAssertEqual(joined[0].targetMinutes, 50)
    }

    func testAnEndedSessionCanRunAgainUnlessAnotherDoes() throws {
        let store = try EventStore()
        let tag = try XCTUnwrap(try store.tags().first?.id)
        let first = try XCTUnwrap(try store.startSession(tagID: tag, at: t0).id)
        try store.endSession(at: t0 + 600)
        XCTAssertTrue(try store.setSessionEnd(id: first, to: nil))
        XCTAssertEqual(try store.runningSession()?.id, first)

        try store.endSession(at: t0 + 600)
        try store.startSession(tagID: tag, at: t0 + 900)
        XCTAssertFalse(try store.setSessionEnd(id: first, to: nil))
        XCTAssertTrue(try store.setSessionEnd(id: first, to: t0 + 700))
        XCTAssertEqual(try store.sessions().first?.end, t0 + 700)
    }

    func testAPastSessionClaimsItsPeriodAndCutsRecordsAtItsEnds() throws {
        let store = try EventStore()
        let tags = try store.tags()
        let study = try XCTUnwrap(tags.first { $0.key == "study" }?.id)
        // One record from 0 to 100 s, another from 100 to 200 s.
        for (offset, name) in [(0, "A.swift"), (100, "A.swift"), (100, "B.swift"), (200, "B.swift")] {
            try store.heartbeat(xcode(name), at: t0 + Double(offset), pulse: 200, forceNew: offset == 100 && name == "B.swift")
        }
        try store.addSession(tagID: study, from: t0 + 50, to: t0 + 150)

        let events = try store.events(from: t0, to: t0 + 300)
        XCTAssertEqual(events.map { [$0.start.timeIntervalSince(t0), $0.end.timeIntervalSince(t0)] },
                       [[0, 50], [50, 100], [100, 150], [150, 200]])
        let tagger = try store.tagger()
        XCTAssertEqual(events.map { tagger.primary(for: $0)?.key }, ["dev", "study", "study", "dev"])
    }

    func testAPastSessionMakesRoomAmongOtherSessions() throws {
        let store = try EventStore()
        let tags = try store.tags()
        let (study, games) = (try XCTUnwrap(tags.first { $0.key == "study" }?.id), try XCTUnwrap(tags.first { $0.key == "games" }?.id))
        // A running session since t0; an hour in the middle turns out to have been a game.
        try store.startSession(tagID: study, at: t0)
        try store.addSession(tagID: games, from: t0 + 3600, to: t0 + 7200)

        let sessions = try store.sessions()
        XCTAssertEqual(sessions.map(\.tagID), [study, games, study])
        XCTAssertEqual(sessions.map { $0.start.timeIntervalSince(t0) }, [0, 3600, 7200])
        XCTAssertEqual(sessions.map { $0.end?.timeIntervalSince(t0) }, [3600, 7200, nil])
        XCTAssertEqual(try store.runningSession()?.start, t0 + 7200)

        // A session that lies inside the new one is replaced by it.
        try store.addSession(tagID: study, from: t0 + 3000, to: t0 + 8000)
        XCTAssertEqual(try store.sessions().map { $0.start.timeIntervalSince(t0) }, [0, 3000, 8000])
    }

    func testAppsAndSitesOfATagAreSetInOneGo() throws {
        let store = try EventStore()
        let tag = try XCTUnwrap(try store.addTag(name: "Meetings", colorIndex: 2).id)
        try store.addRule(tagID: tag, field: .title, op: .contains, value: "standup")
        try store.setSources(tagID: tag, apps: ["us.zoom.xos", "com.tencent.meeting"], sites: ["meet.google.com"])
        try store.setSources(tagID: tag, apps: ["us.zoom.xos"], sites: ["meet.google.com", "zoom.us"])

        let rules = try store.rules().filter { $0.tagID == tag }
        XCTAssertEqual(Set(rules.map { "\($0.field.rawValue):\($0.value)" }),
                       ["title:standup", "app:us.zoom.xos", "url:meet.google.com", "url:zoom.us"])
        // A custom tag comes before the presets, so Zoom is a meeting now.
        let zoom = ActivityEvent(sample: Sample(bundleID: "us.zoom.xos", appName: "Zoom"), start: t0, end: t0 + 60)
        XCTAssertEqual(try store.tagger().primary(for: zoom)?.name, "Meetings")

        try store.renameTag(id: tag, to: "  Calls ")
        XCTAssertEqual(try store.tags().first { $0.id == tag }?.name, "Calls")
    }
}
