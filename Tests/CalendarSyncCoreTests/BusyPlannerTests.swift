import XCTest
@testable import CalendarSyncCore

final class BusyPlannerTests: XCTestCase {
    let clientA = SourceConfig(kind: .eventKit(calendarID: "client-a"), calendarName: "Calendar A", showBusyInClient: true)
    let clientB = SourceConfig(kind: .eventKit(calendarID: "client-b"), calendarName: "Calendar B")
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func event(_ key: String, _ title: String, at hour: Double, notes: String? = nil) -> SourceEvent {
        SourceEvent(key: key, title: title, start: base + hour * 3600, end: base + (hour + 1) * 3600,
                    meetingURL: URL(string: "https://zoom.us/j/1"), notes: notes)
    }

    /// A main-calendar event that is itself a copy made from `source`.
    func copyOf(_ source: SourceConfig, key: String, at hour: Double) -> SourceEvent {
        event("main-\(key)", "[\(source.calendarName)] Meeting", at: hour,
              notes: "Copied by Calendar Sync.\n\n" + CopyMarker(sourceID: source.id, key: key).encoded)
    }

    func copies(from plan: SyncPlan) -> [ExistingCopy] {
        plan.actions.enumerated().compactMap { i, action in
            guard case .create(let s) = action else { return nil }
            return ExistingCopy(eventID: "busy-\(i)", marker: s.marker, title: s.title, start: s.start,
                                end: s.end, isAllDay: s.isAllDay, url: s.url, notes: s.notes)
        }
    }

    func testBusyEventsCarryNoDetails() {
        let plan = SyncPlanner.planBusy(for: clientA, mainEvents: .success([event("m1", "Salary review with HR", at: 2)]),
                                        existing: [], options: SyncOptions())
        XCTAssertEqual(plan.creates, 1)
        guard case .create(let spec) = plan.actions[0] else { return XCTFail() }
        XCTAssertEqual(spec.title, "Busy")
        XCTAssertNil(spec.url)
        XCTAssertEqual(spec.notes, spec.marker.encoded, "notes hold only the hidden marker")
        XCTAssertFalse(spec.notes.contains("m1"), "the original event's identifier is hashed")
        XCTAssertFalse(spec.notes.localizedCaseInsensitiveContains("salary"))
        XCTAssertEqual(spec.start, base + 2 * 3600)
        XCTAssertEqual(CopyMarker.find(in: spec.notes)?.sourceID, clientA.id)
    }

    func testOutOfOfficeStyleCarriesNoDetailsEither() {
        var client = clientA
        client.busyStyle = .outOfOffice
        let plan = SyncPlanner.planBusy(for: client, mainEvents: .success([event("m1", "Salary review with HR", at: 2)]),
                                        existing: [], options: SyncOptions())
        XCTAssertEqual(plan.creates, 1)
        guard case .create(let spec) = plan.actions[0] else { return XCTFail() }
        XCTAssertEqual(spec.title, "Out of office")
        XCTAssertTrue(spec.isOutOfOffice)
        XCTAssertNil(spec.url)
        XCTAssertEqual(spec.notes, spec.marker.encoded, "notes hold only the hidden marker")
        XCTAssertFalse(spec.notes.localizedCaseInsensitiveContains("salary"))
    }

    func testSwitchingStyleUpdatesExistingCopies() {
        let main = [event("m1", "A", at: 1)]
        let first = SyncPlanner.planBusy(for: clientA, mainEvents: .success(main), existing: [], options: SyncOptions())
        var client = clientA
        client.busyStyle = .outOfOffice
        let switched = SyncPlanner.planBusy(for: client, mainEvents: .success(main),
                                            existing: copies(from: first), options: SyncOptions())
        XCTAssertEqual(switched.updates, 1, "the same marker is kept, only the title changes")
        XCTAssertEqual(switched.creates, 0)
        XCTAssertEqual(switched.deletes, 0)
        guard case .update(_, let spec) = switched.actions[0] else { return XCTFail() }
        XCTAssertEqual(spec.title, "Out of office")
    }

    func testSkipsCopiesOfTheSameClientButShowsOtherClients() {
        let main = [copyOf(clientA, key: "a1", at: 1), copyOf(clientB, key: "b1", at: 3), event("own", "Dentist", at: 5)]
        let plan = SyncPlanner.planBusy(for: clientA, mainEvents: .success(main), existing: [], options: SyncOptions())
        let starts = plan.actions.compactMap { if case .create(let s) = $0 { s.start } else { nil } }
        XCTAssertEqual(starts, [base + 3 * 3600, base + 5 * 3600])
    }

    func testBusyEventsAreNeverCopiedBackIntoMain() {
        let plan = SyncPlanner.planBusy(for: clientA, mainEvents: .success([event("m1", "Dentist", at: 2)]),
                                        existing: [], options: SyncOptions())
        guard case .create(let busy) = plan.actions[0] else { return XCTFail() }
        // The client calendar now holds the Busy event; syncing that calendar into main must skip it.
        let clientEvents = [event("busy-event", busy.title, at: 2, notes: busy.notes)]
        let forward = SyncPlanner.plan(sources: [(clientA, .success(clientEvents))], existing: [], options: SyncOptions())
        XCTAssertTrue(forward.isEmpty)
    }

    func testSecondRunIsNoOpAndChangesFollow() {
        let main = [event("m1", "A", at: 1), event("m2", "B", at: 3)]
        let first = SyncPlanner.planBusy(for: clientA, mainEvents: .success(main), existing: [], options: SyncOptions())
        let existing = copies(from: first)
        XCTAssertTrue(SyncPlanner.planBusy(for: clientA, mainEvents: .success(main), existing: existing, options: SyncOptions()).isEmpty)

        let moved = SyncPlanner.planBusy(for: clientA, mainEvents: .success([event("m1", "A", at: 6)]),
                                         existing: existing, options: SyncOptions())
        XCTAssertEqual(moved.updates, 1)
        XCTAssertEqual(moved.deletes, 1)
    }

    func testFailureLeavesBusyEventsAlone() {
        let first = SyncPlanner.planBusy(for: clientA, mainEvents: .success([event("m1", "A", at: 1)]),
                                         existing: [], options: SyncOptions())
        let next = SyncPlanner.planBusy(for: clientA, mainEvents: .failure("Main calendar not found"),
                                        existing: copies(from: first), options: SyncOptions())
        XCTAssertTrue(next.isEmpty)
        XCTAssertEqual(next.failedSources[clientA.id], "Main calendar not found")
    }

    func testOnlyTouchesItsOwnBusyEvents() {
        let other = ExistingCopy(eventID: "x", marker: CopyMarker(sourceID: clientB.id, key: "busy-1"), title: "Busy",
                                 start: base, end: base + 3600, isAllDay: false, url: nil, notes: "")
        let plan = SyncPlanner.planBusy(for: clientA, mainEvents: .success([]), existing: [other], options: SyncOptions())
        XCTAssertTrue(plan.isEmpty)
    }

    func testFiltersFollowOptions() {
        var declined = event("d", "Declined", at: 1); declined.isDeclined = true
        var allDay = event("a", "Holiday", at: 2); allDay.isAllDay = true
        var cancelled = event("c", "Cancelled", at: 3); cancelled.isCancelled = true
        let plan = SyncPlanner.planBusy(for: clientA, mainEvents: .success([declined, allDay, cancelled]),
                                        existing: [], options: SyncOptions(skipDeclined: true, skipAllDay: true))
        XCTAssertTrue(plan.isEmpty)
    }

    func testOldSettingsStillDecode() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":{"outlookWeb":{}},"calendarName":"Calendar B","hideMeetingName":true,"isEnabled":true}"#
        let decoded = try JSONDecoder().decode(SourceConfig.self, from: Data(old.utf8))
        XCTAssertFalse(decoded.showBusyInClient)
        XCTAssertEqual(decoded.busyStyle, .busy)
        XCTAssertTrue(decoded.hideMeetingName)
        var ooo = clientA
        ooo.busyStyle = .outOfOffice
        let roundTrip = try JSONDecoder().decode(SourceConfig.self, from: JSONEncoder().encode(ooo))
        XCTAssertEqual(roundTrip, ooo)
    }
}
