import XCTest
@testable import CalendarSyncCore

final class MenuCalendarTests: XCTestCase {
    /// Fixed calendar so the grid doesn't depend on the machine running the tests.
    var utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2 // Monday
        return calendar
    }()

    func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testGridCoversTheMonthInWholeWeeks() {
        // October 2026: the 1st is a Thursday, the 31st a Saturday.
        let days = MenuCalendar.gridDays(for: date(2026, 10, 24), calendar: utc)
        XCTAssertEqual(days.count % 7, 0)
        XCTAssertEqual(days.first, date(2026, 9, 28), "padded back to Monday the 28th of September")
        XCTAssertEqual(days.last, date(2026, 11, 1), "padded forward to Sunday the 1st of November")
        XCTAssertTrue(days.contains(date(2026, 10, 1)))
        XCTAssertTrue(days.contains(date(2026, 10, 31)))
        XCTAssertEqual(utc.component(.weekday, from: days.first!), utc.firstWeekday)
    }

    func testGridOfAMonthThatIsExactWeeks() {
        // February 2027: the 1st is a Monday and it has 28 days, so no padding at all.
        let days = MenuCalendar.gridDays(for: date(2027, 2, 14), calendar: utc)
        XCTAssertEqual(days.count, 28)
        XCTAssertEqual(days.first, date(2027, 2, 1))
        XCTAssertEqual(days.last, date(2027, 2, 28))
    }

    func testSectionsGroupByDaySoonestFirst() {
        let events = [
            SourceEvent(key: "b", title: "Later today", start: date(2026, 10, 24, hour: 15), end: date(2026, 10, 24, hour: 16)),
            SourceEvent(key: "c", title: "Tomorrow", start: date(2026, 10, 25, hour: 9), end: date(2026, 10, 25, hour: 10)),
            SourceEvent(key: "a", title: "Earlier today", start: date(2026, 10, 24, hour: 9), end: date(2026, 10, 24, hour: 10)),
        ]
        let sections = MenuCalendar.sections(for: events, calendar: utc)
        XCTAssertEqual(sections.map(\.day), [date(2026, 10, 24), date(2026, 10, 25)])
        XCTAssertEqual(sections[0].events.map(\.key), ["a", "b"])
        XCTAssertEqual(sections[1].events.map(\.key), ["c"])
    }

    func testSectionsOfNoEvents() {
        XCTAssertEqual(MenuCalendar.sections(for: [], calendar: utc), [])
    }
}
