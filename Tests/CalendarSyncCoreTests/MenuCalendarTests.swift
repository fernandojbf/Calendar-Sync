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

    func testGridAcrossAMidnightClockChange() {
        // São Paulo started summer time on 4 November 2018 at midnight: that day began at 01:00.
        var saoPaulo = Calendar(identifier: .gregorian)
        saoPaulo.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        saoPaulo.firstWeekday = 2
        let month = saoPaulo.date(from: DateComponents(year: 2018, month: 11, day: 15))!
        let days = MenuCalendar.gridDays(for: month, calendar: saoPaulo)
        XCTAssertEqual(days.count, 35, "29 October to 2 December")
        XCTAssertEqual(Set(days.map { saoPaulo.startOfDay(for: $0) }).count, 35, "no day twice, none skipped")
        XCTAssertEqual(days.map { saoPaulo.component(.day, from: $0) }.prefix(8), [29, 30, 31, 1, 2, 3, 4, 5])
    }

    func testGridStartingOnSunday() {
        let sunday = MenuCalendarOptions(weekStart: .sunday).applied(to: utc)
        let days = MenuCalendar.gridDays(for: date(2026, 10, 24), calendar: sunday)
        XCTAssertEqual(days.first, date(2026, 9, 27), "padded back to Sunday the 27th of September")
        XCTAssertEqual(days.last, date(2026, 10, 31), "the 31st is a Saturday, so no padding forward")
        XCTAssertEqual(MenuCalendar.weekdays(calendar: sunday), [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(MenuCalendar.weekdays(calendar: utc), [2, 3, 4, 5, 6, 7, 1])
        XCTAssertEqual(MenuCalendarOptions().applied(to: utc).firstWeekday, 2, "system keeps the calendar's own")
    }

    func testGridWithoutWeekends() {
        for weekStart in [MenuCalendarOptions.WeekStart.monday, .sunday] {
            let calendar = MenuCalendarOptions(weekStart: weekStart).applied(to: utc)
            let days = MenuCalendar.gridDays(for: date(2026, 10, 24), calendar: calendar, showsWeekends: false)
            XCTAssertEqual(days.count, 25, "five weeks of five working days")
            XCTAssertFalse(days.contains { calendar.isDateInWeekend($0) })
            XCTAssertEqual(days.first, date(2026, 9, 28))
            XCTAssertEqual(days.last, date(2026, 10, 30))
            XCTAssertEqual(MenuCalendar.weekdays(calendar: calendar, showsWeekends: false), [2, 3, 4, 5, 6])
        }
    }

    func testOptionsFromOlderSettings() throws {
        let options = try JSONDecoder().decode(MenuCalendarOptions.self, from: Data("{}".utf8))
        XCTAssertEqual(options, MenuCalendarOptions(weekStart: .system, showsWeekends: true, shadesAllDay: true,
                                                    colorsByCalendar: true, shadesTimeOfDay: true))
    }

    func testPartsSplitAllDayMorningAndAfternoon() {
        let events = [
            SourceEvent(key: "all", title: "Holiday", start: date(2026, 10, 24), end: date(2026, 10, 25), isAllDay: true),
            SourceEvent(key: "am", title: "Standup", start: date(2026, 10, 24, hour: 9), end: date(2026, 10, 24, hour: 10)),
            SourceEvent(key: "late-am", title: "Review", start: date(2026, 10, 24, hour: 11), end: date(2026, 10, 24, hour: 13)),
            SourceEvent(key: "noon", title: "Lunch", start: date(2026, 10, 24, hour: 12), end: date(2026, 10, 24, hour: 13)),
            SourceEvent(key: "pm", title: "Retro", start: date(2026, 10, 24, hour: 16), end: date(2026, 10, 24, hour: 17)),
        ]
        let parts = MenuCalendar.parts(of: events, calendar: utc)
        XCTAssertEqual(parts.allDay.map(\.key), ["all"])
        XCTAssertEqual(parts.morning.map(\.key), ["am", "late-am"], "by start time, even when it runs past noon")
        XCTAssertEqual(parts.afternoon.map(\.key), ["noon", "pm"])
    }

    func testOriginOfACopyAndOfAnOwnEvent() {
        let sourceID = UUID()
        let marker = CopyMarker(sourceID: sourceID, key: "abc").encoded
        let copy = SourceEvent(key: "c", title: "[A] Standup", start: date(2026, 10, 24, hour: 9),
                               end: date(2026, 10, 24, hour: 10), notes: "Agenda\n\n\(marker)")
        let own = SourceEvent(key: "o", title: "Dentist", start: date(2026, 10, 24, hour: 9), end: date(2026, 10, 24, hour: 10))
        XCTAssertEqual(MenuCalendar.originID(of: copy), sourceID)
        XCTAssertNil(MenuCalendar.originID(of: own))
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
