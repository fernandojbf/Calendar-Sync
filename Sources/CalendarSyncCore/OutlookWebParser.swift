import Foundation

/// Extracts meetings from the JSON that Outlook on the web (outlook.office.com) loads for its
/// own calendar view. The format isn't documented and differs between Outlook versions, so
/// this walks any JSON and accepts objects that look like events in either of the two shapes
/// Outlook uses:
///
/// - OWA service style: `Subject`, `Start`/`End` as ISO strings, `ItemId.Id`, `IsAllDayEvent`,
///   `IsCancelled`, `ResponseType`, `FreeBusyType`, `Location.DisplayName`, `Body.Value`.
/// - Graph / REST style: `subject`, `start.dateTime` + `start.timeZone`, `id`, `isAllDay`,
///   `isCancelled`, `responseStatus.response`, `showAs`, `onlineMeeting.joinUrl`, `body.content`.
///
/// Keys are matched case-insensitively.
///
/// The week view usually leaves out the meeting body, and with it the join link (in Teams
/// invites the link sits behind "Join the meeting now", so it isn't in the text preview
/// either). `OutlookWebSource` therefore also loads each meeting in full; those responses are
/// passed as `details` and merged into the week-view events by item id.
public enum OutlookWebParser {
    /// - Parameter timeZone: this Mac's time zone, whose days all-day events are placed on.
    public static func events(fromPayloads payloads: [Data], details detailPayloads: [Data] = [],
                              timeZone: TimeZone = .current) -> [SourceEvent] {
        let details = self.details(fromPayloads: detailPayloads)
        var seen: Set<String> = []
        var result: [SourceEvent] = []
        forEachEvent(in: payloads) { obj in
            guard let event = event(from: obj, detail: rawItemID(obj).flatMap { details[$0] }, timeZone: timeZone)
            else { return }
            if seen.insert(event.key).inserted { result.append(event) }
        }
        return result.sorted { $0.start < $1.start }
    }

    /// Outlook's own ids of the meetings in `payloads`, used to load each one in full.
    public static func itemIDs(fromPayloads payloads: [Data]) -> [String] {
        var seen: Set<String> = []
        var ids: [String] = []
        forEachEvent(in: payloads) { obj in
            if let id = rawItemID(obj), seen.insert(id).inserted { ids.append(id) }
        }
        return ids
    }

    private static func forEachEvent(in payloads: [Data], _ found: (Obj) -> Void) {
        for data in payloads {
            guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { continue }
            collect(json, found)
        }
    }

    private static func collect(_ json: Any, _ found: (Obj) -> Void) {
        if let object = json as? [String: Any] {
            let obj = Obj(object)
            if event(from: obj) != nil {
                found(obj)
                return
            }
            for value in object.values { collect(value, found) }
        } else if let array = json as? [Any] {
            for value in array { collect(value, found) }
        }
    }

    /// Full meetings by Outlook item id: any object with an id and a body or join link.
    static func details(fromPayloads payloads: [Data]) -> [String: Obj] {
        var result: [String: Obj] = [:]
        func walk(_ json: Any) {
            if let object = json as? [String: Any] {
                let obj = Obj(object)
                if let id = rawItemID(obj), obj.object("body") != nil || joinURL(obj) != nil {
                    result[id] = obj
                    return
                }
                object.values.forEach(walk)
            } else if let array = json as? [Any] {
                array.forEach(walk)
            }
        }
        for data in payloads {
            if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) { walk(json) }
        }
        return result
    }

    // MARK: - Meetings on screen

    /// Key for a meeting read from Outlook on the web: title + start. Outlook's own item ids
    /// aren't available when a week is read from the page, so every meeting uses this key,
    /// whichever way it was read, and a copy doesn't flip between two keys. A moved meeting
    /// gets a new key: its copy is replaced instead of updated.
    public static func screenKey(title: String, start: Date) -> String {
        "outlook:" + title + "|" + ISO8601DateFormatter().string(from: start)
    }

    /// Parses the description Outlook on the web gives each meeting on screen (its
    /// accessibility label), e.g. "Team stand-up, 10:15 AM to 10:30 AM, Monday, October 26,
    /// 2026, Microsoft Teams Meeting, By Alex Morgan, Busy, Recurring event".
    ///
    /// Used when a week's data can't be captured. All-day events, meetings spanning several
    /// days and labels in other languages are skipped. Teams links aren't in the label, so
    /// only links written out in it (e.g. Google Meet) are kept.
    public static func events(fromScreenLabels labels: [String], timeZone: TimeZone = .current) -> [SourceEvent] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "MMMM d, yyyy h:mm a"

        var seen: Set<String> = []
        var result: [SourceEvent] = []
        for raw in labels {
            let label = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            let range = NSRange(label.startIndex..., in: label)
            guard let m = screenLabelRegex.firstMatch(in: label, range: range),
                  let title = Range(m.range(at: 1), in: label).map({ String(label[$0]).trimmingCharacters(in: .whitespaces) }),
                  let startTime = Range(m.range(at: 2), in: label).map({ String(label[$0]) }),
                  let endTime = Range(m.range(at: 3), in: label).map({ String(label[$0]) }),
                  let day = Range(m.range(at: 4), in: label).map({ String(label[$0]) }),
                  let start = f.date(from: day + " " + startTime),
                  var end = f.date(from: day + " " + endTime)
            else { continue }
            if end < start { end = end.addingTimeInterval(86400) } // ends after midnight
            let rest = Range(m.range(at: 5), in: label).map { String(label[$0]) } ?? ""

            let lowered = title.lowercased()
            let key = screenKey(title: title, start: start)
            guard seen.insert(key).inserted else { continue }
            result.append(SourceEvent(
                key: key,
                title: title,
                start: start,
                end: end,
                isCancelled: lowered.hasPrefix("canceled:") || lowered.hasPrefix("cancelled:"),
                meetingURL: MeetingLink.firstMeetingLink(in: rest)
            ))
        }
        return result.sorted { $0.start < $1.start }
    }

    /// "<title>, <h:mm AM> to <h:mm PM>, <Weekday>, <Month d, yyyy><, rest>"
    private static let screenLabelRegex = try! NSRegularExpression(
        pattern: #"^(.+?), (\d{1,2}:\d{2} [AP]M) to (\d{1,2}:\d{2} [AP]M), (?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday), ([A-Z][a-z]+ \d{1,2}, \d{4})(.*)$"#)

    // MARK: - One event

    static func event(from obj: Obj, detail: Obj? = nil, timeZone: TimeZone = .current) -> SourceEvent? {
        guard let subject = obj.string("subject") ?? (obj.has("subject") ? "" : nil),
              let startField = obj.value("start"), let endField = obj.value("end"),
              var start = date(startField, fallbackZone: obj.string("startTimeZone") ?? obj.string("originalStartTimeZone")),
              var end = date(endField, fallbackZone: obj.string("endTimeZone") ?? obj.string("originalEndTimeZone")),
              let id = itemID(obj),
              !isMeetingMail(obj, subject: subject)
        else { return nil }

        let isAllDay = obj.bool("isAllDay") ?? obj.bool("isAllDayEvent") ?? false
        if isAllDay {
            let eventZone = Self.timeZone(named: obj.string("originalStartTimeZone") ?? obj.string("startTimeZone")
                ?? obj.string("startTimeZoneId") ?? obj.object("startTimeZone")?.string("id"))
            (start, end) = allDayRange(startField, endField, start: start, end: end, eventZone: eventZone, timeZone: timeZone)
        }
        let isCancelled = obj.bool("isCancelled") ?? false

        let response = (obj.string("responseType")
            ?? obj.string("myResponseType")
            ?? obj.object("responseStatus")?.string("response")
            ?? "").lowercased()
        let isDeclined = response.hasPrefix("decline")

        // OWA: FreeBusyType / LegacyFreeBusyStatus "OOF"; Graph: showAs "oof".
        let showAs = (obj.string("freeBusyType") ?? obj.string("legacyFreeBusyStatus") ?? obj.string("showAs") ?? "").lowercased()
        let isOutOfOffice = showAs == "oof" || showAs == "outofoffice"

        // The full meeting, when loaded, knows more than the week view.
        let sources = [detail, obj].compactMap { $0 }
        func first<T>(_ read: (Obj) -> T?) -> T? {
            for source in sources { if let value = read(source) { return value } }
            return nil
        }

        let location = first { $0.string("location") ?? $0.object("location")?.string("displayName") }
        let joinURL = first(joinURL)
        let body = first(self.body)
        let notes = body?.text ?? first { $0.string("bodyPreview") ?? $0.string("preview") }
        let meetingURL = MeetingLink.find(url: joinURL.flatMap(URL.init(string:)), location: location, notes: body?.raw ?? notes)
            ?? joinURL.flatMap(URL.init(string:))
            ?? MeetingLink.firstMeetingLink(in: sources.flatMap { $0.allStrings() }.joined(separator: " "))

        return SourceEvent(
            key: id,
            title: subject,
            start: start,
            end: end,
            isAllDay: isAllDay,
            timeZone: nil,
            isDeclined: isDeclined,
            isCancelled: isCancelled,
            isOutOfOffice: isOutOfOffice,
            meetingURL: meetingURL,
            notes: notes,
            location: location
        )
    }

    /// Mail about a meeting: an invitation, a reply ("Declined: Standup") or a cancellation
    /// notice. Outlook loads mail along with the calendar, and this mail has the meeting's
    /// subject, start and end, so it would be copied as a meeting of its own. A reply stays in
    /// the inbox after the meeting is deleted, and its copy with it.
    static func isMeetingMail(_ obj: Obj, subject: String) -> Bool {
        // OWA "MeetingResponseMessage:#Exchange", Graph "#microsoft.graph.eventMessageRequest",
        // GraphQL "Message". Meetings are "CalendarItem:#Exchange", "#microsoft.graph.event", …
        if let type = obj.string("__type") ?? obj.string("@odata.type") ?? obj.string("__typename") {
            let name = type.prefix { $0 != ":" }.split(separator: ".").last.map { $0.lowercased() } ?? ""
            if name.contains("message")
                || ["meetingrequest", "meetingresponse", "meetingcancellation"].contains(where: name.hasPrefix) {
                return true
            }
        }
        // Meetings are IPM.Appointment; mail about them IPM.Schedule.Meeting.*, other mail IPM.Note.
        if let itemClass = obj.string("itemClass")?.lowercased(),
           itemClass.hasPrefix("ipm.schedule.meeting.") || itemClass.hasPrefix("ipm.note") {
            return true
        }
        // Graph's meeting mail says which kind it is.
        if obj.has("meetingMessageType") { return true }
        // Mail sent without a type: Exchange starts the subject of a reply with the answer.
        return subject.range(of: #"^(Accepted|Tentative|Declined):"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func joinURL(_ obj: Obj) -> String? {
        obj.object("onlineMeeting")?.string("joinUrl")
            ?? obj.string("joinOnlineMeetingUrl")
            ?? obj.string("onlineMeetingJoinUrl")
            ?? obj.object("onlineMeetingInfo")?.string("joinUrl")
            ?? obj.string("onlineMeetingUrl")
            ?? obj.string("skypeTeamsMeetingUrl")
    }

    /// The meeting body as sent (`raw`, HTML or text) and as plain text. OWA uses
    /// `Body.Value` + `BodyType`, Graph `body.content` + `contentType`.
    static func body(_ obj: Obj) -> (raw: String, text: String)? {
        guard let body = obj.object("body"), let raw = body.string("value") ?? body.string("content") else { return nil }
        let type = (body.string("bodyType") ?? body.string("contentType") ?? "").lowercased()
        let isHTML = type == "html" || (type.isEmpty && raw.range(of: #"<[a-zA-Z!/][^>]*>"#, options: .regularExpression) != nil)
        let text = isHTML ? HTMLText.plainText(from: raw) : HTMLText.normalize(raw)
        return text.isEmpty ? nil : (raw, text)
    }

    /// Outlook's own id of the item, as used to load it.
    static func rawItemID(_ obj: Obj) -> String? {
        obj.object("itemId")?.string("id") ?? obj.string("itemId") ?? obj.string("id")
    }

    /// A key that survives the meeting being moved: series id + original start for recurring
    /// occurrences when available, otherwise the item id.
    static func itemID(_ obj: Obj) -> String? {
        if let master = obj.string("seriesMasterId") ?? obj.object("seriesMasterItemId")?.string("id"),
           let original = obj.string("originalStart") ?? obj.string("recurrenceId") {
            return "series:\(master)|\(original)"
        }
        if let id = obj.object("itemId")?.string("id") { return id }
        if let id = obj.string("id") { return id }
        if let id = obj.string("itemId") { return id }
        if let id = obj.string("iCalUId") ?? obj.string("uid") { return id }
        return nil
    }

    // MARK: - Dates

    /// An all-day event the way Calendar.app has one: from midnight of its first day to a
    /// second before midnight after its last day, on this Mac's days. Outlook writes all-day
    /// events as midnights in the mailbox's time zone (or UTC); read as instants, they land on
    /// the previous or next day whenever that zone isn't this Mac's. A time not written as
    /// midnight goes on the day it falls on in the event's own zone when Outlook names it,
    /// else on this Mac's.
    static func allDayRange(_ startField: Any, _ endField: Any, start: Date, end: Date,
                            eventZone: TimeZone? = nil, timeZone: TimeZone) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func day(_ field: Any, _ instant: Date) -> Date {
            if let written = writtenMidnight(field, calendar: calendar) { return written }
            guard let eventZone else { return calendar.startOfDay(for: instant) }
            var eventCalendar = calendar
            eventCalendar.timeZone = eventZone
            let day = eventCalendar.dateComponents([.year, .month, .day], from: instant)
            return calendar.date(from: day) ?? calendar.startOfDay(for: instant)
        }
        let first = day(startField, start)
        let afterLast = day(endField, end)
        // At least one day, whatever the end says.
        let next = max(afterLast, calendar.date(byAdding: .day, value: 1, to: first) ?? afterLast)
        return (first, next.addingTimeInterval(-1))
    }

    /// The day a date field names when it's written as midnight ("2026-10-26T00:00:00+09:00",
    /// or Graph's `dateTime` "2026-10-26T00:00:00.0000000"), as midnight in `calendar`.
    static func writtenMidnight(_ value: Any, calendar: Calendar) -> Date? {
        let raw = (value as? String) ?? (value as? [String: Any]).flatMap { Obj($0).string("dateTime") }
        guard let raw else { return nil }
        let string = raw.trimmingCharacters(in: .whitespaces)
        guard let m = midnightRegex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) else { return nil }
        func number(_ i: Int) -> Int? { Range(m.range(at: i), in: string).flatMap { Int(string[$0]) } }
        guard let year = number(1), let month = number(2), let day = number(3) else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    private static let midnightRegex = try! NSRegularExpression(
        pattern: #"^(\d{4})-(\d{2})-(\d{2})T00:00(:00(\.0+)?)?(Z|[+-]\d{2}(:?\d{2})?)?$"#)

    static func date(_ value: Any, fallbackZone: String?) -> Date? {
        if let string = value as? String {
            return parseDate(string, zone: fallbackZone)
        }
        if let dict = value as? [String: Any] {
            let obj = Obj(dict)
            guard let string = obj.string("dateTime") else { return nil }
            return parseDate(string, zone: obj.string("timeZone") ?? fallbackZone)
        }
        return nil
    }

    static func parseDate(_ raw: String, zone: String?) -> Date? {
        let string = raw.trimmingCharacters(in: .whitespaces)
        // Strings with an offset or Z are absolute.
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime],
        ] {
            let f = ISO8601DateFormatter()
            f.formatOptions = options
            if let d = f.date(from: string) { return d }
        }
        // Otherwise it's a local time in `zone` (Graph style). Drop fractional seconds,
        // which can have 7 digits.
        let base = String(string.prefix { $0 != "." })
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = timeZone(named: zone) ?? TimeZone(identifier: "UTC")
        return f.date(from: base)
    }

    /// Accepts IANA names ("Europe/Lisbon") and the Windows names Outlook uses
    /// ("GMT Standard Time").
    public static func timeZone(named name: String?) -> TimeZone? {
        guard let name, !name.isEmpty else { return nil }
        if let tz = TimeZone(identifier: name) { return tz }
        if let iana = windowsZones[name.lowercased()] { return TimeZone(identifier: iana) }
        return nil
    }

    /// Windows time zone names, lowercased, with their IANA zone: CLDR's mapping for each
    /// (territory "001"), as ICU has it.
    static let windowsZones: [String: String] = [
        "afghanistan standard time": "Asia/Kabul",
        "alaskan standard time": "America/Anchorage",
        "aleutian standard time": "America/Adak",
        "altai standard time": "Asia/Barnaul",
        "arab standard time": "Asia/Riyadh",
        "arabian standard time": "Asia/Dubai",
        "arabic standard time": "Asia/Baghdad",
        "argentina standard time": "America/Buenos_Aires",
        "astrakhan standard time": "Europe/Astrakhan",
        "atlantic standard time": "America/Halifax",
        "aus central standard time": "Australia/Darwin",
        "aus central w. standard time": "Australia/Eucla",
        "aus eastern standard time": "Australia/Sydney",
        "azerbaijan standard time": "Asia/Baku",
        "azores standard time": "Atlantic/Azores",
        "bahia standard time": "America/Bahia",
        "bangladesh standard time": "Asia/Dhaka",
        "belarus standard time": "Europe/Minsk",
        "bougainville standard time": "Pacific/Bougainville",
        "canada central standard time": "America/Regina",
        "cape verde standard time": "Atlantic/Cape_Verde",
        "caucasus standard time": "Asia/Yerevan",
        "cen. australia standard time": "Australia/Adelaide",
        "central america standard time": "America/Guatemala",
        "central asia standard time": "Asia/Bishkek",
        "central brazilian standard time": "America/Cuiaba",
        "central europe standard time": "Europe/Budapest",
        "central european standard time": "Europe/Warsaw",
        "central pacific standard time": "Pacific/Guadalcanal",
        "central standard time": "America/Chicago",
        "central standard time (mexico)": "America/Mexico_City",
        "chatham islands standard time": "Pacific/Chatham",
        "china standard time": "Asia/Shanghai",
        "coordinated universal time": "UTC",
        "cuba standard time": "America/Havana",
        "dateline standard time": "Etc/GMT+12",
        "e. africa standard time": "Africa/Nairobi",
        "e. australia standard time": "Australia/Brisbane",
        "e. europe standard time": "Europe/Chisinau",
        "e. south america standard time": "America/Sao_Paulo",
        "easter island standard time": "Pacific/Easter",
        "eastern standard time": "America/New_York",
        "eastern standard time (mexico)": "America/Cancun",
        "egypt standard time": "Africa/Cairo",
        "ekaterinburg standard time": "Asia/Yekaterinburg",
        "fiji standard time": "Pacific/Fiji",
        "fle standard time": "Europe/Kiev",
        "georgian standard time": "Asia/Tbilisi",
        "gmt standard time": "Europe/London",
        "greenland standard time": "America/Godthab",
        "greenwich standard time": "Atlantic/Reykjavik",
        "gtb standard time": "Europe/Bucharest",
        "haiti standard time": "America/Port-au-Prince",
        "hawaiian standard time": "Pacific/Honolulu",
        "india standard time": "Asia/Kolkata",
        "iran standard time": "Asia/Tehran",
        "israel standard time": "Asia/Jerusalem",
        "jordan standard time": "Asia/Amman",
        "kaliningrad standard time": "Europe/Kaliningrad",
        "korea standard time": "Asia/Seoul",
        "libya standard time": "Africa/Tripoli",
        "line islands standard time": "Pacific/Kiritimati",
        "lord howe standard time": "Australia/Lord_Howe",
        "magadan standard time": "Asia/Magadan",
        "magallanes standard time": "America/Punta_Arenas",
        "marquesas standard time": "Pacific/Marquesas",
        "mauritius standard time": "Indian/Mauritius",
        "middle east standard time": "Asia/Beirut",
        "montevideo standard time": "America/Montevideo",
        "morocco standard time": "Africa/Casablanca",
        "mountain standard time": "America/Denver",
        "mountain standard time (mexico)": "America/Mazatlan",
        "myanmar standard time": "Asia/Rangoon",
        "n. central asia standard time": "Asia/Novosibirsk",
        "namibia standard time": "Africa/Windhoek",
        "nepal standard time": "Asia/Katmandu",
        "new zealand standard time": "Pacific/Auckland",
        "newfoundland standard time": "America/St_Johns",
        "norfolk standard time": "Pacific/Norfolk",
        "north asia east standard time": "Asia/Irkutsk",
        "north asia standard time": "Asia/Krasnoyarsk",
        "north korea standard time": "Asia/Pyongyang",
        "omsk standard time": "Asia/Omsk",
        "pacific sa standard time": "America/Santiago",
        "pacific standard time": "America/Los_Angeles",
        "pacific standard time (mexico)": "America/Tijuana",
        "pakistan standard time": "Asia/Karachi",
        "paraguay standard time": "America/Asuncion",
        "qyzylorda standard time": "Asia/Qyzylorda",
        "romance standard time": "Europe/Paris",
        "russia time zone 10": "Asia/Srednekolymsk",
        "russia time zone 11": "Asia/Kamchatka",
        "russia time zone 3": "Europe/Samara",
        "russian standard time": "Europe/Moscow",
        "sa eastern standard time": "America/Cayenne",
        "sa pacific standard time": "America/Bogota",
        "sa western standard time": "America/La_Paz",
        "saint pierre standard time": "America/Miquelon",
        "sakhalin standard time": "Asia/Sakhalin",
        "samoa standard time": "Pacific/Apia",
        "sao tome standard time": "Africa/Sao_Tome",
        "saratov standard time": "Europe/Saratov",
        "se asia standard time": "Asia/Bangkok",
        "singapore standard time": "Asia/Singapore",
        "south africa standard time": "Africa/Johannesburg",
        "south sudan standard time": "Africa/Juba",
        "sri lanka standard time": "Asia/Colombo",
        "sudan standard time": "Africa/Khartoum",
        "syria standard time": "Asia/Damascus",
        "taipei standard time": "Asia/Taipei",
        "tasmania standard time": "Australia/Hobart",
        "tocantins standard time": "America/Araguaina",
        "tokyo standard time": "Asia/Tokyo",
        "tomsk standard time": "Asia/Tomsk",
        "tonga standard time": "Pacific/Tongatapu",
        "transbaikal standard time": "Asia/Chita",
        "turkey standard time": "Europe/Istanbul",
        "turks and caicos standard time": "America/Grand_Turk",
        "ulaanbaatar standard time": "Asia/Ulaanbaatar",
        "us eastern standard time": "America/Indianapolis",
        "us mountain standard time": "America/Phoenix",
        "utc": "UTC",
        "utc+12": "Etc/GMT-12",
        "utc+13": "Etc/GMT-13",
        "utc-02": "Etc/GMT+2",
        "utc-08": "Etc/GMT+8",
        "utc-09": "Etc/GMT+9",
        "utc-11": "Etc/GMT+11",
        "venezuela standard time": "America/Caracas",
        "vladivostok standard time": "Asia/Vladivostok",
        "volgograd standard time": "Europe/Volgograd",
        "w. australia standard time": "Australia/Perth",
        "w. central africa standard time": "Africa/Lagos",
        "w. europe standard time": "Europe/Berlin",
        "w. mongolia standard time": "Asia/Hovd",
        "west asia standard time": "Asia/Tashkent",
        "west bank standard time": "Asia/Hebron",
        "west pacific standard time": "Pacific/Port_Moresby",
        "yakutsk standard time": "Asia/Yakutsk",
        "yukon standard time": "America/Whitehorse",
    ]
}

/// Case-insensitive view over a JSON object.
struct Obj {
    private let storage: [String: Any]

    init(_ dict: [String: Any]) {
        var lowered: [String: Any] = [:]
        for (k, v) in dict { lowered[k.lowercased()] = v }
        storage = lowered
    }

    func has(_ key: String) -> Bool { storage[key.lowercased()] != nil }

    func value(_ key: String) -> Any? {
        let v = storage[key.lowercased()]
        return v is NSNull ? nil : v
    }

    func string(_ key: String) -> String? {
        guard let s = value(key) as? String, !s.isEmpty else { return nil }
        return s
    }

    func bool(_ key: String) -> Bool? {
        switch value(key) {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return ["true", "1", "yes"].contains(s.lowercased())
        default: return nil
        }
    }

    func object(_ key: String) -> Obj? {
        (value(key) as? [String: Any]).map(Obj.init)
    }

    /// Every string nested anywhere inside this object.
    func allStrings() -> [String] {
        var out: [String] = []
        func walk(_ v: Any) {
            if let s = v as? String { out.append(s) }
            else if let d = v as? [String: Any] { d.values.forEach(walk) }
            else if let a = v as? [Any] { a.forEach(walk) }
        }
        storage.values.forEach(walk)
        return out
    }
}
