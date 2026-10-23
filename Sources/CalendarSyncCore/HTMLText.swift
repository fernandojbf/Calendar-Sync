import Foundation

/// Turns the HTML body of an Outlook event into readable plain text for a copy's notes.
/// Foundation only (no AppKit HTML import), so it runs anywhere and off the main thread.
public enum HTMLText {
    public static func plainText(from html: String) -> String {
        var text = html
        // Content that is never shown.
        for pattern in [#"(?s)<!--.*?-->"#, #"(?s)<(style|script|head)\b[^>]*>.*?</\1\s*>"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        // Line breaks in the source are just spaces in HTML.
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        // Each <br> is a line break; a run of block tags (</p><p>, </div><div>) is one.
        text = text.replacingOccurrences(of: #" ?<br\s*/?> ?"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(
            of: #"( ?</?(p|div|tr|li|ul|ol|h[1-6]|table|blockquote)\b[^>]*> ?)+"#, with: "\n",
            options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return normalize(decodeEntities(text))
    }

    /// Line endings, non-breaking spaces, trailing spaces and runs of blank lines tidied up,
    /// so text compares equal after a calendar server has stored and returned it.
    public static func normalize(_ text: String) -> String {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .components(separatedBy: "\n")
            .map { line -> String in
                var line = Substring(line)
                while let last = line.last, last.isWhitespace { line.removeLast() }
                return String(line)
            }
        var out: [String] = []
        for line in lines {
            // At most one blank line in a row.
            if line.isEmpty, out.last?.isEmpty ?? true { continue }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var cursor = text.startIndex
        for match in entityRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text), let name = Range(match.range(at: 1), in: text) else { continue }
            result += text[cursor..<whole.lowerBound]
            result += entity(String(text[name])) ?? String(text[whole])
            cursor = whole.upperBound
        }
        result += text[cursor...]
        return result
    }

    private static let entityRegex = try! NSRegularExpression(pattern: #"&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);"#)

    private static func entity(_ name: String) -> String? {
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            return UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        if name.hasPrefix("#") {
            return UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return named[name.lowercased()]
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ndash": "–", "mdash": "—", "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”",
        "ldquo": "“", "bull": "•", "middot": "·", "copy": "©", "reg": "®", "trade": "™",
    ]
}
