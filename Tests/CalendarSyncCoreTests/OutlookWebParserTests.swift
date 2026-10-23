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

    func testDaylightSavingLocalTime() {
        // 23 Oct 2026 is still British Summer Time (UTC+1).
        let date = OutlookWebParser.parseDate("2026-10-23T09:00:00", zone: "GMT Standard Time")
        XCTAssertEqual(date, ISO8601DateFormatter().date(from: "2026-10-23T08:00:00Z"))
    }
}
