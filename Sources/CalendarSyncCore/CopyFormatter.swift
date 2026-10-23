import Foundation

/// Turns a source event into the copy that should exist in the target calendar.
public enum CopyFormatter {
    public static func title(for event: SourceEvent, source: SourceConfig) -> String {
        let calendar = source.calendarName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = source.hideMeetingName ? "Busy" : event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let meeting = name.isEmpty ? "Busy" : name
        return calendar.isEmpty ? meeting : "[\(calendar)] \(meeting)"
    }

    /// The meeting link (if any) goes first so it's visible and clickable in Calendar;
    /// the hidden marker goes last.
    public static func notes(meetingURL: URL?, marker: CopyMarker) -> String {
        var lines: [String] = []
        if let meetingURL { lines.append("Join: \(meetingURL.absoluteString)") }
        lines.append("Copied by Calendar Sync. Changes here are overwritten.")
        lines.append(marker.encoded)
        return lines.joined(separator: "\n\n")
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
        return CopySpec(
            marker: marker,
            title: title(for: event, source: source),
            start: event.start,
            end: event.end,
            isAllDay: event.isAllDay,
            timeZone: event.isAllDay ? nil : event.timeZone,
            url: event.meetingURL,
            notes: notes(meetingURL: event.meetingURL, marker: marker)
        )
    }
}
