import Foundation

/// Date math for the menu's month view and event list. Pure logic, unit tested.
public enum MenuCalendar {
    /// Every day shown in a month grid: the month's days, padded to whole weeks with the
    /// neighbouring months' days. Always whole weeks, starting on the calendar's first weekday.
    public static func gridDays(for month: Date, calendar: Calendar) -> [Date] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: month),
              let firstWeek = calendar.dateInterval(of: .weekOfYear, for: monthInterval.start),
              let lastDay = calendar.date(byAdding: .day, value: -1, to: monthInterval.end),
              let lastWeek = calendar.dateInterval(of: .weekOfYear, for: lastDay)
        else { return [] }

        var days: [Date] = []
        var day = firstWeek.start
        while day < lastWeek.end {
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }

    /// One day of the list view, with its events soonest first.
    public struct DaySection: Hashable, Sendable {
        public var day: Date
        public var events: [SourceEvent]

        public init(day: Date, events: [SourceEvent]) {
            self.day = day
            self.events = events
        }
    }

    /// Groups events into days for the list view, both sorted. A multi-day event appears
    /// under the day it starts.
    public static func sections(for events: [SourceEvent], calendar: Calendar) -> [DaySection] {
        let byDay = Dictionary(grouping: events) { calendar.startOfDay(for: $0.start) }
        return byDay.keys.sorted().map { day in
            DaySection(day: day, events: byDay[day]!.sorted { ($0.start, $0.title) < ($1.start, $1.title) })
        }
    }
}
