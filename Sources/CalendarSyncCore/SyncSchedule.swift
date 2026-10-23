import Foundation

/// Decides which client calendars are due to be read. Each calendar uses its own interval
/// when it has one, otherwise the app-wide interval.
public enum SyncSchedule {
    public static let minMinutes = 1
    public static let maxMinutes = 24 * 60

    /// Minutes between reads of `source`.
    public static func interval(for source: SourceConfig, defaultMinutes: Int) -> Int {
        min(max(source.intervalMinutes ?? defaultMinutes, minMinutes), maxMinutes)
    }

    /// Enabled sources never read yet, or whose interval has passed since `lastRead`.
    /// Timers drift, so a source is due up to 30 seconds early rather than a whole tick late.
    public static func dueSources(
        _ sources: [SourceConfig],
        lastRead: [UUID: Date],
        defaultMinutes: Int,
        now: Date
    ) -> Set<UUID> {
        Set(sources.filter { source in
            guard source.isEnabled else { return false }
            guard let last = lastRead[source.id] else { return true }
            let seconds = TimeInterval(interval(for: source, defaultMinutes: defaultMinutes) * 60)
            return now.timeIntervalSince(last) >= seconds - 30
        }.map(\.id))
    }
}
