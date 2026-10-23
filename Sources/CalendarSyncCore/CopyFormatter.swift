import Foundation

/// Turns a source event into the copy that should exist in the target calendar.
public enum CopyFormatter {
    public static func title(for event: SourceEvent, source: SourceConfig) -> String {
        let calendar = source.calendarName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = source.hideMeetingName ? "Busy" : event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let meeting = name.isEmpty ? "Busy" : name
        return calendar.isEmpty ? meeting : "[\(calendar)] \(meeting)"
    }

    /// The meeting link (if any) goes first so it's visible and clickable in Calendar, then the
    /// meeting's description when the source copies details; the hidden marker goes last.
    public static func notes(meetingURL: URL?, details: String? = nil, marker: CopyMarker) -> String {
        var lines: [String] = []
        if let meetingURL { lines.append("Join: \(meetingURL.absoluteString)") }
        if let details, !details.isEmpty { lines.append(details) }
        lines.append("Copied by Calendar Sync. Changes here are overwritten.")
        lines.append(marker.encoded)
        return lines.joined(separator: "\n\n")
    }

    /// Longest description copied into a copy's notes.
    static let maxDetailsLength = 8000

    /// The description and location to copy, or nil for both when the source doesn't copy
    /// details (or hides meeting names, which would make the details give it away).
    static func details(for event: SourceEvent, source: SourceConfig) -> (notes: String?, location: String?) {
        guard source.copyDetails, !source.hideMeetingName else { return (nil, nil) }
        var notes = event.notes.map(HTMLText.normalize)
        if let text = notes, text.count > maxDetailsLength {
            notes = HTMLText.normalize(String(text.prefix(maxDetailsLength))) + "…"
        }
        let location = event.location.map(HTMLText.normalize)
        return (notes?.isEmpty == false ? notes : nil, location?.isEmpty == false ? location : nil)
    }

    /// A main-calendar event shown in a client calendar: the time and "Busy", nothing else.
    /// The notes hold only the hidden marker, whose key is a hash so it reveals nothing about
    /// the original event.
    public static func busySpec(for event: SourceEvent, source: SourceConfig) -> CopySpec {
        let marker = CopyMarker(sourceID: source.id, key: "busy-" + stableHash(event.key))
        return CopySpec(
            marker: marker,
            title: "Busy",
            start: event.start,
            end: event.end,
            isAllDay: event.isAllDay,
            timeZone: event.isAllDay ? nil : event.timeZone,
            url: nil,
            notes: marker.encoded
        )
    }

    /// FNV-1a, 64-bit. Stable across launches and platforms (unlike `Hasher`).
    static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    public static func spec(for event: SourceEvent, source: SourceConfig) -> CopySpec {
        let marker = CopyMarker(sourceID: source.id, key: event.key)
        let details = details(for: event, source: source)
        return CopySpec(
            marker: marker,
            title: title(for: event, source: source),
            start: event.start,
            end: event.end,
            isAllDay: event.isAllDay,
            timeZone: event.isAllDay ? nil : event.timeZone,
            url: event.meetingURL,
            notes: notes(meetingURL: event.meetingURL, details: details.notes, marker: marker),
            location: details.location
        )
    }
}
