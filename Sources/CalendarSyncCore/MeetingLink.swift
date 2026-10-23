import Foundation

/// Finds the online meeting link (Teams, Zoom, Google Meet, Webex, …) for an event.
public enum MeetingLink {
    /// Hosts that are online meeting links, matched against the URL's host and path.
    static let patterns: [String] = [
        #"teams\.microsoft\.com/l/meetup-join/"#,
        #"teams\.live\.com/meet/"#,
        #"teams\.microsoft\.com/meet/"#,
        #"([a-z0-9-]+\.)?zoom\.us/(j|my|w)/"#,
        #"([a-z0-9-]+\.)?zoomgov\.com/(j|my|w)/"#,
        #"meet\.google\.com/[a-z0-9-]+"#,
        #"([a-z0-9-]+\.)?webex\.com/"#,
        #"([a-z0-9-]+\.)?gotomeeting\.com/join/"#,
        #"meet\.goto\.com/"#,
        #"([a-z0-9-]+\.)?chime\.aws/"#,
        #"([a-z0-9-]+\.)?whereby\.com/"#,
        #"meet\.jit\.si/"#,
    ]

    private static let urlRegex = try! NSRegularExpression(
        pattern: #"https?://[^\s<>"'\)\]]+"#, options: [.caseInsensitive])

    private static let meetingRegexes: [NSRegularExpression] = patterns.map {
        try! NSRegularExpression(pattern: "^https?://" + $0, options: [.caseInsensitive])
    }

    /// Returns `url` if it's already a meeting link, else the first meeting link found in
    /// `location`, then `notes`. Other links (agendas, docs) are ignored.
    public static func find(url: URL?, location: String?, notes: String?) -> URL? {
        if let url {
            let unwrapped = unwrap(url.absoluteString)
            if isMeetingLink(unwrapped) { return URL(string: unwrapped) ?? url }
        }
        for text in [location, notes] {
            if let text, let link = firstMeetingLink(in: text) { return link }
        }
        return nil
    }

    public static func isMeetingLink(_ string: String) -> Bool {
        let range = NSRange(string.startIndex..., in: string)
        return meetingRegexes.contains { $0.firstMatch(in: string, range: range) != nil }
    }

    /// Also finds links inside HTML (`href="…"`, with `&amp;` escapes) and behind Microsoft
    /// Defender Safe Links, which many company mailboxes wrap every link in.
    public static func firstMeetingLink(in text: String) -> URL? {
        let range = NSRange(text.startIndex..., in: text)
        for match in urlRegex.matches(in: text, range: range) {
            guard let r = Range(match.range, in: text) else { continue }
            // Drop trailing punctuation that is usually sentence text, not part of the link.
            var candidate = String(text[r]).replacingOccurrences(of: "&amp;", with: "&")
            while let last = candidate.last, ".,;:!?".contains(last) { candidate.removeLast() }
            candidate = unwrap(candidate)
            if isMeetingLink(candidate), let url = URL(string: candidate) { return url }
        }
        return nil
    }

    /// The original link inside a Safe Links URL
    /// (`https://eur01.safelinks.protection.outlook.com/?url=<encoded link>&data=…`).
    static func unwrap(_ string: String) -> String {
        guard let components = URLComponents(string: string),
              let host = components.host?.lowercased(),
              host.hasSuffix("safelinks.protection.outlook.com"),
              let inner = components.queryItems?.first(where: { $0.name.lowercased() == "url" })?.value,
              inner.lowercased().hasPrefix("http")
        else { return string }
        return inner
    }
}
