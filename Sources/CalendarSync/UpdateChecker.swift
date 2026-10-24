import CalendarSyncCore
import Combine
import Foundation

/// Checks GitHub for a newer version: the newest release when one is published, otherwise
/// the version on the main branch (what a fresh source build would be). Checks at launch,
/// once a day, and on demand.
@MainActor
final class UpdateChecker: ObservableObject {
    static let repoPage = URL(string: "https://github.com/neteinstein/Calendar-Sync")!
    private static let releaseAPI = URL(string: "https://api.github.com/repos/neteinstein/Calendar-Sync/releases/latest")!
    private static let mainInfoPlist = URL(string: "https://raw.githubusercontent.com/neteinstein/Calendar-Sync/main/Support/Info.plist")!

    /// Set when a version newer than the running one is published.
    @Published private(set) var available: UpdateCheck.Latest?
    @Published private(set) var isChecking = false
    @Published private(set) var lastChecked: Date?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private var timer: Timer?

    init() {
        // Scheduled on the main run loop, so the block runs on the main actor.
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.check() }
            }
        }
        timer?.tolerance = 3600
        Task { await check() }
    }

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer {
            isChecking = false
            lastChecked = Date()
        }
        guard let latest = await fetchLatest() else { return }
        available = UpdateCheck.isNewer(latest.version, than: currentVersion) ? latest : nil
    }

    private func fetchLatest() async -> UpdateCheck.Latest? {
        if let data = await fetch(Self.releaseAPI), let release = UpdateCheck.latest(fromReleaseJSON: data) {
            return release
        }
        // No release published (or no reply): the version on main is the newest source build.
        if let data = await fetch(Self.mainInfoPlist), let version = UpdateCheck.version(fromInfoPlist: data) {
            return UpdateCheck.Latest(version: version, url: Self.repoPage)
        }
        return nil
    }

    private func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }
}
