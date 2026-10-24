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
    public static func events(fromPayloads payloads: [Data], details detailPayloads: [Data] = []) -> [SourceEvent] {
        let details = self.details(fromPayloads: detailPayloads)
        var seen: Set<String> = []
        var result: [SourceEvent] = []
        forEachEvent(in: payloads) { obj in
            guard let event = event(from: obj, detail: rawItemID(obj).flatMap { details[$0] }) else { return }
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

    static func event(from obj: Obj, detail: Obj? = nil) -> SourceEvent? {
        guard let subject = obj.string("subject") ?? (obj.has("subject") ? "" : nil),
              let startField = obj.value("start"), let endField = obj.value("end"),
              let start = date(startField, fallbackZone: obj.string("startTimeZone") ?? obj.string("originalStartTimeZone")),
              let end = date(endField, fallbackZone: obj.string("endTimeZone") ?? obj.string("originalEndTimeZone")),
              let id = itemID(obj)
        else { return nil }

        let isAllDay = obj.bool("isAllDay") ?? obj.bool("isAllDayEvent") ?? false
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

    static let windowsZones: [String: String] = [
        "utc": "UTC",
        "coordinated universal time": "UTC",
        "gmt standard time": "Europe/London",
        "greenwich standard time": "Atlantic/Reykjavik",
        "w. europe standard time": "Europe/Berlin",
        "romance standard time": "Europe/Paris",
        "central europe standard time": "Europe/Budapest",
        "central european standard time": "Europe/Warsaw",
        "e. europe standard time": "Europe/Chisinau",
        "gtb standard time": "Europe/Bucharest",
        "fle standard time": "Europe/Kiev",
        "russian standard time": "Europe/Moscow",
        "azores standard time": "Atlantic/Azores",
        "cape verde standard time": "Atlantic/Cape_Verde",
        "e. south america standard time": "America/Sao_Paulo",
        "eastern standard time": "America/New_York",
        "central standard time": "America/Chicago",
        "mountain standard time": "America/Denver",
        "us mountain standard time": "America/Phoenix",
        "pacific standard time": "America/Los_Angeles",
        "india standard time": "Asia/Kolkata",
        "singapore standard time": "Asia/Singapore",
        "china standard time": "Asia/Shanghai",
        "tokyo standard time": "Asia/Tokyo",
        "aus eastern standard time": "Australia/Sydney",
        "south africa standard time": "Africa/Johannesburg",
        "arabian standard time": "Asia/Dubai",
        "israel standard time": "Asia/Jerusalem",
        "turkey standard time": "Europe/Istanbul",
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
