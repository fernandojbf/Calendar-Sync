import XCTest
@testable import CalendarSyncCore

final class OutlookWebParserTests: XCTestCase {
    func testOWAServiceShape() throws {
        let json = """
        {"Body":{"ResponseClass":"Success","Items":[
          {"__type":"CalendarItem:#Exchange","ItemId":{"Id":"AAMk1","ChangeKey":"x"},
           "Subject":"Sprint planning","Start":"2026-10-23T09:00:00+01:00","End":"2026-10-23T10:00:00+01:00",
           "IsAllDayEvent":false,"IsCancelled":false,"ResponseType":"Accept",
           "Location":{"DisplayName":"Microsoft Teams Meeting"},
           "Preview":"Join: https://teams.microsoft.com/l/meetup-join/19%3aabc/0?context=1"},
          {"ItemId":{"Id":"AAMk2"},"Subject":"Optional sync","Start":"2026-10-23T11:00:00Z","End":"2026-10-23T11:30:00Z",
           "ResponseType":"Decline"},
          {"ItemId":{"Id":"AAMk3"},"Subject":"Old","Start":"2026-10-23T12:00:00Z","End":"2026-10-23T12:30:00Z",
           "IsCancelled":true}
        ]}}
        """
        let events = OutlookWebParser.events(fromPayloads: [Data(json.utf8)])
        XCTAssertEqual(events.count, 3)

        let first = events[0]
        XCTAssertEqual(first.key, "AAMk1")
        XCTAssertEqual(first.title, "Sprint planning")
        XCTAssertEqual(first.start, ISO8601DateFormatter().date(from: "2026-10-23T08:00:00Z"))
        XCTAssertEqual(first.meetingURL?.host, "teams.microsoft.com")
        XCTAssertFalse(first.isDeclined)

        XCTAssertTrue(events[1].isDeclined)
        XCTAssertTrue(events[2].isCancelled)
    }

    func testGraphShapeWithWindowsTimeZoneAndSeriesKey() throws {
        let json = """
        {"value":[{"id":"occ-1","subject":"Standup","type":"occurrence",
          "seriesMasterId":"master-9","originalStart":"2026-10-26T09:30:00Z",
          "start":{"dateTime":"2026-10-27T09:30:00.0000000","timeZone":"GMT Standard Time"},
          "end":{"dateTime":"2026-10-27T09:45:00.0000000","timeZone":"GMT Standard Time"},
          "isAllDay":false,"isCancelled":false,"responseStatus":{"response":"accepted"},
          "onlineMeeting":{"joinUrl":"https://teams.microsoft.com/l/meetup-join/xyz"},
          "location":{"displayName":""}}]}
        """
        let events = OutlookWebParser.events(fromPayloads: [Data(json.utf8)])
        XCTAssertEqual(events.count, 1)
        let e = events[0]
        XCTAssertEqual(e.key, "series:master-9|2026-10-26T09:30:00Z")
        // 27 Oct 2026 is after the UK clocks change, so GMT == UTC.
        XCTAssertEqual(e.start, ISO8601DateFormatter().date(from: "2026-10-27T09:30:00Z"))
        XCTAssertEqual(e.meetingURL?.absoluteString, "https://teams.microsoft.com/l/meetup-join/xyz")
    }

    func testIgnoresNonEventsAndDuplicates() {
        let a = #"{"Items":[{"ItemId":{"Id":"1"},"Subject":"A","Start":"2026-10-23T09:00:00Z","End":"2026-10-23T10:00:00Z"}]}"#
        let noise = #"{"Folders":[{"DisplayName":"Calendar","Id":"f1"}],"start":"x"}"#
        let events = OutlookWebParser.events(fromPayloads: [Data(a.utf8), Data(noise.utf8), Data(a.utf8), Data("not json".utf8)])
        XCTAssertEqual(events.map(\.key), ["1"])
    }

    func testWeekViewIsCompletedWithFullMeetingDetails() {
        // The week view has no body and no join link, as Outlook on the web sends it.
        let week = """
        {"Body":{"Items":[{"ItemId":{"Id":"AAMk1"},"Subject":"Sprint planning",
          "Start":"2026-10-23T09:00:00Z","End":"2026-10-23T10:00:00Z","FreeBusyType":"Busy",
          "Location":{"DisplayName":"Microsoft Teams Meeting"},
          "Preview":"Microsoft Teams Need help? Join the meeting now Meeting ID: 123 456"}]}}
        """
        // GetItem response: HTML body with the link behind Safe Links and "Join the meeting now".
        let full = """
        {"Body":{"ResponseMessages":{"Items":[{"ResponseClass":"Success","Items":[
          {"__type":"CalendarItem:#Exchange","ItemId":{"Id":"AAMk1","ChangeKey":"c"},"Subject":"Sprint planning",
           "Body":{"BodyType":"HTML","Value":"<html><head><style>p{}</style></head><body><p>Agenda:&nbsp;stories</p><div>________________</div><a href=\\"https://eur01.safelinks.protection.outlook.com/?url=https%3A%2F%2Fteams.microsoft.com%2Fl%2Fmeetup-join%2F19%253ameeting_x%2540thread.v2%2F0&amp;data=05%7C02&amp;reserved=0\\">Join the meeting now</a><br>Meeting ID: 123 456</body></html>"},
           "Location":{"DisplayName":"Microsoft Teams Meeting"}}]}]}}}
        """
        XCTAssertEqual(OutlookWebParser.itemIDs(fromPayloads: [Data(week.utf8)]), ["AAMk1"])

        let without = OutlookWebParser.events(fromPayloads: [Data(week.utf8)])
        XCTAssertNil(without[0].meetingURL)

        let events = OutlookWebParser.events(fromPayloads: [Data(week.utf8)], details: [Data(full.utf8)])
        XCTAssertEqual(events.count, 1, "details never add events of their own")
        let e = events[0]
        XCTAssertEqual(e.key, "AAMk1")
        XCTAssertEqual(e.meetingURL?.absoluteString, "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0")
        XCTAssertEqual(e.location, "Microsoft Teams Meeting")
        XCTAssertEqual(e.notes, "Agenda: stories\n________________\nJoin the meeting now\nMeeting ID: 123 456")
    }

    func testOutOfOffice() {
        let json = """
        {"Items":[{"ItemId":{"Id":"1"},"Subject":"Holiday","Start":"2026-10-23T00:00:00Z","End":"2026-10-24T00:00:00Z","FreeBusyType":"OOF"},
                  {"ItemId":{"Id":"2"},"Subject":"Standup","Start":"2026-10-23T09:00:00Z","End":"2026-10-23T09:15:00Z","FreeBusyType":"Busy"}],
         "value":[{"id":"3","subject":"Leave","start":{"dateTime":"2026-10-23T00:00:00","timeZone":"UTC"},
                   "end":{"dateTime":"2026-10-24T00:00:00","timeZone":"UTC"},"showAs":"oof"}]}
        """
        let events = OutlookWebParser.events(fromPayloads: [Data(json.utf8)])
        XCTAssertEqual(Set(events.filter(\.isOutOfOffice).map(\.key)), ["1", "3"])
    }

    func testAllDayEventsKeepTheirDaysInAnotherTimeZone() {
        // A Tokyo mailbox (OWA style) and a mailbox read in UTC (Graph style), on a Mac in New
        // York. As instants, the 26th in Tokyo starts at 11:00 on the 25th in New York.
        let json = """
        {"Items":[{"ItemId":{"Id":"1"},"Subject":"Release day","IsAllDayEvent":true,
                   "Start":"2026-10-26T00:00:00+09:00","End":"2026-10-27T00:00:00+09:00"},
                  {"ItemId":{"Id":"2"},"Subject":"Standup","IsAllDayEvent":false,
                   "Start":"2026-10-26T09:00:00+09:00","End":"2026-10-26T09:15:00+09:00"}],
         "value":[{"id":"3","subject":"Offsite","isAllDay":true,
                   "start":{"dateTime":"2026-10-28T00:00:00.0000000","timeZone":"UTC"},
                   "end":{"dateTime":"2026-10-30T00:00:00.0000000","timeZone":"UTC"}}]}
        """
        let newYork = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        func midnight(_ day: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: day))! }

        let events = Dictionary(uniqueKeysWithValues: OutlookWebParser.events(fromPayloads: [Data(json.utf8)], timeZone: newYork)
            .map { ($0.key, $0) })
        // Like Calendar.app's own all-day events: midnight to a second before the next midnight.
        XCTAssertEqual(events["1"]?.start, midnight(26))
        XCTAssertEqual(events["1"]?.end, midnight(27) - 1)
        XCTAssertEqual(events["3"]?.start, midnight(28))
        XCTAssertEqual(events["3"]?.end, midnight(30) - 1, "two days: the 28th and the 29th")
        XCTAssertEqual(events["2"]?.start, ISO8601DateFormatter().date(from: "2026-10-26T00:00:00Z"), "timed events are instants")
    }

    func testAllDayEventWithoutAWrittenMidnight() {
        // Only an instant to go on: it's placed on this Mac's day, and lasts at least that day.
        let json = #"{"Items":[{"ItemId":{"Id":"1"},"Subject":"Leave","IsAllDayEvent":true,"Start":"2026-10-26T04:00:00Z","End":"2026-10-26T04:00:00Z"}]}"#
        let newYork = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        let event = OutlookWebParser.events(fromPayloads: [Data(json.utf8)], timeZone: newYork).first
        XCTAssertEqual(event?.start, calendar.date(from: DateComponents(year: 2026, month: 10, day: 26)))
        XCTAssertEqual(event?.end, calendar.date(from: DateComponents(year: 2026, month: 10, day: 27))! - 1)
    }

    func testAllDayEventGivenAsInstantsInItsOwnZone() {
        // Midnight in Berlin written in UTC, read on a Mac in New York (where it's 19:00 the
        // day before): the event names its zone, so it stays on the 26th.
        let json = """
        {"Items":[{"ItemId":{"Id":"1"},"Subject":"Holiday","IsAllDayEvent":true,"StartTimeZoneId":"W. Europe Standard Time",
                   "Start":"2026-10-25T23:00:00Z","End":"2026-10-26T23:00:00Z"}],
         "value":[{"id":"2","subject":"Offsite","isAllDay":true,"originalStartTimeZone":"W. Europe Standard Time",
                   "start":{"dateTime":"2026-10-27T23:00:00.0000000","timeZone":"UTC"},
                   "end":{"dateTime":"2026-10-29T23:00:00.0000000","timeZone":"UTC"}}]}
        """
        let newYork = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        func midnight(_ day: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: day))! }
        let events = Dictionary(uniqueKeysWithValues: OutlookWebParser.events(fromPayloads: [Data(json.utf8)], timeZone: newYork)
            .map { ($0.key, $0) })
        XCTAssertEqual(events["1"]?.start, midnight(26))
        XCTAssertEqual(events["1"]?.end, midnight(27) - 1)
        XCTAssertEqual(events["2"]?.start, midnight(28))
        XCTAssertEqual(events["2"]?.end, midnight(30) - 1)
    }

    func testDaylightSavingLocalTime() {
        // 23 Oct 2026 is still British Summer Time (UTC+1).
        let date = OutlookWebParser.parseDate("2026-10-23T09:00:00", zone: "GMT Standard Time")
        XCTAssertEqual(date, ISO8601DateFormatter().date(from: "2026-10-23T08:00:00Z"))
    }

    func testScreenLabels() {
        let labels = [
            "Team stand-up, 10:15 AM to 10:30 AM, Monday, October 26, 2026, Microsoft Teams Meeting, By Alex Morgan, Busy, Recurring event",
            "Sprint close, retro & planning, 1:00 PM to 2:00 PM, Thursday, October 29, 2026, Microsoft Teams Meeting, By Alex Morgan, Busy, Recurring event",
            " Architecture open class (session 1), 3:00 PM to 4:30 PM, Wednesday, October 28, 2026, https://meet.google.com/abc-defg-hij, By Sam Lee, Busy",
            "Canceled: Retro, 11:00 AM to 11:30 AM, Friday, October 30, 2026, By Chris Park, Free",
            "Annual leave, all day event, Saturday, October 17, 2026 to Monday, October 26, 2026, By Chris Park, Free",
            "Team stand-up, 10:15 AM to 10:30 AM, Monday, October 26, 2026, Microsoft Teams Meeting, By Alex Morgan, Busy, Recurring event",
        ]
        let london = TimeZone(identifier: "Europe/London")!
        let events = OutlookWebParser.events(fromScreenLabels: labels, timeZone: london)
        XCTAssertEqual(events.map(\.title), [
            "Team stand-up",
            "Architecture open class (session 1)",
            "Sprint close, retro & planning",
            "Canceled: Retro",
        ])

        let standup = events[0]
        // 26 Oct 2026 is after the UK clocks change, so London == UTC.
        XCTAssertEqual(standup.start, ISO8601DateFormatter().date(from: "2026-10-26T10:15:00Z"))
        XCTAssertEqual(standup.end, ISO8601DateFormatter().date(from: "2026-10-26T10:30:00Z"))
        XCTAssertEqual(standup.key, OutlookWebParser.screenKey(title: "Team stand-up", start: standup.start))
        XCTAssertNil(standup.meetingURL)

        XCTAssertEqual(events[1].meetingURL?.host, "meet.google.com")
        XCTAssertTrue(events[3].isCancelled)
    }
}
