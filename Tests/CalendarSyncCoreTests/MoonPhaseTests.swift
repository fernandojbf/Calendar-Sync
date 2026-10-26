import XCTest
@testable import CalendarSyncCore

final class MoonPhaseTests: XCTestCase {
    func utc(_ time: String) -> Date { ISO8601DateFormatter().date(from: time)! }

    /// Phase times as published in astronomical almanacs. 0.2° of elongation is about 24
    /// minutes of the moon's motion.
    func testElongationMatchesPublishedPhaseTimes() {
        let phases: [(time: String, elongation: Double)] = [
            ("1969-07-14T14:11:00Z", 0), // before the J2000 epoch: the new moon before Apollo 11 landed
            ("2024-01-11T11:57:00Z", 0),
            ("2024-01-25T17:54:00Z", 180),
            ("2024-02-02T23:18:00Z", 270),
            ("2024-02-16T15:01:00Z", 90),
            ("2025-01-13T22:27:00Z", 180),
            ("2025-01-29T12:36:00Z", 0),
            ("2026-01-03T10:03:00Z", 180),
            ("2026-01-18T19:52:00Z", 0),
        ]
        for phase in phases {
            var difference = MoonPhase.elongation(on: utc(phase.time)) - phase.elongation
            if difference > 180 { difference -= 360 }
            XCTAssertEqual(difference, 0, accuracy: 0.2, phase.time)
        }
    }

    func testPrincipalPhasesOnTheirDays() {
        XCTAssertEqual(MoonPhase.phase(on: utc("2024-01-11T00:00:00Z")), .newMoon)
        XCTAssertEqual(MoonPhase.phase(on: utc("2024-01-18T12:00:00Z")), .firstQuarter)
        XCTAssertEqual(MoonPhase.phase(on: utc("2024-01-25T23:59:00Z")), .fullMoon)
        XCTAssertEqual(MoonPhase.phase(on: utc("2024-02-02T12:00:00Z")), .lastQuarter)
        XCTAssertEqual(MoonPhase.phase(on: utc("1969-07-18T00:00:00Z")), .waxingCrescent, "before J2000: four days after the new moon")
    }

    func testEveryPhaseInOrderThroughOneCycle() {
        // Daily from the new moon of 11 January 2024 to just after the next one, on 9 February.
        let newMoon = utc("2024-01-11T12:00:00Z")
        var seen: [MoonPhase] = []
        for day in 0...30 {
            let phase = MoonPhase.phase(on: newMoon + Double(day) * 86400)
            if seen.last != phase { seen.append(phase) }
        }
        XCTAssertEqual(seen, MoonPhase.allCases + [.newMoon])
    }

    func testEveryPhaseHasAName() {
        XCTAssertEqual(Set(MoonPhase.allCases.map(\.name)).count, MoonPhase.allCases.count)
        XCTAssertEqual(MoonPhase.waxingGibbous.name, "Waxing gibbous")
    }
}
