import Foundation

/// Works out whether a newer version of the app is published on GitHub. Pure parsing and
/// comparison, no networking, so it can be unit tested.
public enum UpdateCheck {
    /// The newest published version and where to read about it.
    public struct Latest: Hashable, Sendable {
        public var version: String
        public var url: URL?

        public init(version: String, url: URL? = nil) {
            self.version = version
            self.url = url
        }
    }

    /// True when `candidate` is a higher version than `current`. Versions are dotted numbers
    /// ("0.1.0"); a leading "v" and anything after a dash or plus ("0.2.0-beta") are ignored,
    /// and missing components count as zero, so "1.2" equals "1.2.0" and "1.10" beats "1.9".
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(of: candidate)
        let b = components(of: current)
        guard !a.isEmpty else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func components(of version: String) -> [Int] {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("v") { text.removeFirst() }
        text = text.components(separatedBy: CharacterSet(charactersIn: "-+")).first ?? text
        return text.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    /// Reads the newest release from GitHub's `GET /repos/…/releases/latest` response.
    public static func latest(fromReleaseJSON data: Data) -> Latest? {
        struct Release: Decodable {
            let tag_name: String
            let html_url: String?
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              !release.tag_name.isEmpty
        else { return nil }
        return Latest(version: release.tag_name, url: release.html_url.flatMap(URL.init(string:)))
    }

    /// Reads the version from an app Info.plist. The one on the repo's main branch says what
    /// the newest source build would be, which covers the time before releases are published.
    public static func version(fromInfoPlist data: Data) -> String? {
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        return (plist as? [String: Any])?["CFBundleShortVersionString"] as? String
    }
}
