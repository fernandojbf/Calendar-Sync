import CalendarSyncCore
import EventKit
import Foundation
import WebKit

/// Runs syncs: on a timer (each client calendar on its own interval), when Calendar data
/// changes, and on demand.
@MainActor
final class SyncController: ObservableObject {
    @Published private(set) var hasCalendarAccess = false
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastSummary = "Not synced yet"
    @Published private(set) var problems: [String] = []
    @Published private(set) var preview: SyncPlan?
    /// Busy events the next sync would add to client calendars, per client calendar.
    @Published private(set) var busyPreview: [BusyPreview] = []

    struct BusyPreview: Identifiable {
        let id: UUID
        let calendarName: String
        let plan: SyncPlan
    }

    let settings: SettingsStore
    let eventKit = EventKitBridge()
    private var outlookSources: [UUID: OutlookWebSource] = [:]
    private var timer: Timer?
    /// When each client calendar was last read by a sync that applied its changes.
    private var lastRead: [UUID: Date] = [:]
    private var storeObserver: NSObjectProtocol?
    private var pendingChangeSync: Task<Void, Never>?
    /// Our own writes also fire EKEventStoreChanged; ignore those.
    private var ignoreStoreChangesUntil = Date.distantPast

    init(settings: SettingsStore) {
        self.settings = settings
        Task { await start() }
    }

    func start() async {
        hasCalendarAccess = await eventKit.requestAccess()
        guard hasCalendarAccess else {
            lastSummary = "No calendar access. Allow it in System Settings › Privacy & Security › Calendars."
            return
        }
        storeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: eventKit.store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.calendarDataChanged() }
        }
        startTimer()
        await sync()
    }

    /// Checks every minute which client calendars are due, so each can have its own interval
    /// and interval changes apply without restarting anything.
    private func startTimer() {
        timer?.invalidate()
        // Scheduled on the main run loop, so the block runs on the main actor.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.syncDueSources() }
            }
        }
        timer?.tolerance = 10
    }

    private func syncDueSources() async {
        let due = SyncSchedule.dueSources(
            settings.sources, lastRead: lastRead, defaultMinutes: settings.intervalMinutes, now: Date())
        guard !due.isEmpty else { return }
        await sync(only: due)
    }

    /// Calendar.app changed (e.g. a client meeting moved): resync the Calendar.app sources
    /// after a short pause. Outlook web sources wait for their interval, since reading them is slow.
    private func calendarDataChanged() {
        guard Date() > ignoreStoreChangesUntil else { return }
        pendingChangeSync?.cancel()
        pendingChangeSync = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, let self else { return }
            let calendarApp = self.settings.sources.filter {
                if case .eventKit = $0.kind { true } else { false }
            }
            await self.sync(only: Set(calendarApp.map(\.id)))
        }
    }

    // MARK: - Sync

    var window: (start: Date, end: Date) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: settings.options.daysAhead + 1, to: start)!
        return (start, end)
    }

    /// Reads the sources and works out the changes. With `apply == false` nothing is written
    /// (used for the preview). With `only`, just those sources are read; copies of the others
    /// are left as they are.
    @discardableResult
    func sync(apply: Bool = true, only: Set<UUID>? = nil) async -> SyncPlan? {
        // Access may have been granted in System Settings since launch; start() then syncs.
        if !hasCalendarAccess, eventKit.hasAccess {
            await start()
            return nil
        }
        guard hasCalendarAccess, !isSyncing else { return nil }
        guard let targetID = settings.targetCalendarID, eventKit.calendar(id: targetID) != nil else {
            lastSummary = "Choose your main calendar to copy into in Settings."
            return nil
        }
        isSyncing = true
        defer { isSyncing = false }

        let (start, end) = window
        var results: [(config: SourceConfig, result: SourceFetchResult)] = []
        for source in settings.sources where source.isEnabled && only?.contains(source.id) != false {
            if apply { lastRead[source.id] = Date() }
            switch source.kind {
            case .eventKit(let calendarID):
                if calendarID == targetID { continue } // never copy a calendar into itself
                // Copies are prefixed with the calendar's current name, even if it was renamed.
                var source = source
                if let calendar = eventKit.calendar(id: calendarID) { source.calendarName = calendar.title }
                results.append((source, eventKit.sourceEvents(calendarID: calendarID, from: start, to: end)))
            case .outlookWeb:
                results.append((source, await outlookSource(for: source.id).fetch(from: start, to: end)))
            }
        }

        guard let existing = eventKit.existingCopies(targetID: targetID, from: start, to: end) else {
            lastSummary = "Target calendar not found."
            return nil
        }
        let plan = SyncPlanner.plan(sources: results, existing: existing, options: settings.options)

        var problems = plan.failedSources.map { id, reason in
            "\(settings.sources.first { $0.id == id }?.calendarName ?? "Source"): \(reason)"
        }
        if apply {
            ignoreStoreChangesUntil = Date().addingTimeInterval(5)
            problems += eventKit.apply(plan, targetID: targetID)
            ignoreStoreChangesUntil = Date().addingTimeInterval(5)
        }

        // Then show the main calendar (now including the new copies) as Busy in the client
        // calendars that ask for it, and take the Busy events back from ones that no longer do.
        var busyPlans: [BusyPreview] = []
        for source in settings.sources where source.isEnabled {
            guard case .eventKit(let calendarID) = source.kind, calendarID != targetID,
                  let calendar = eventKit.calendar(id: calendarID) else { continue }
            let busy: SyncPlan
            if source.showBusyInClient {
                guard calendar.allowsContentModifications else {
                    problems.append("\(calendar.title): read-only, so Busy events can't be added.")
                    continue
                }
                busy = SyncPlanner.planBusy(
                    for: source,
                    mainEvents: eventKit.sourceEvents(calendarID: targetID, from: start, to: end),
                    existing: eventKit.existingCopies(targetID: calendarID, from: start, to: end) ?? [],
                    options: settings.options)
            } else {
                guard calendar.allowsContentModifications else { continue }
                busy = SyncPlanner.planBusyRemoval(
                    for: source, existing: eventKit.existingCopies(targetID: calendarID, from: start, to: end) ?? [])
                if busy.isEmpty { continue }
            }
            problems += busy.failedSources.values.map { "\(calendar.title) (Busy): \($0)" }
            if apply {
                ignoreStoreChangesUntil = Date().addingTimeInterval(5)
                problems += eventKit.apply(busy, targetID: calendarID).map { "\(calendar.title) (Busy): \($0)" }
                ignoreStoreChangesUntil = Date().addingTimeInterval(5)
            }
            busyPlans.append(BusyPreview(id: source.id, calendarName: calendar.title, plan: busy))
        }

        if apply {
            lastSync = Date()
            // Counts copies of every client calendar, including ones not read this time.
            let copies = existing.count + plan.creates - plan.deletes
            lastSummary = plan.isEmpty
                ? "Up to date (\(copies) copied meetings)"
                : "Added \(plan.creates), updated \(plan.updates), removed \(plan.deletes)"
            let busyChanges = busyPlans.reduce(0) { $0 + $1.plan.actions.count }
            if busyChanges > 0 {
                lastSummary += ". Busy events: \(busyChanges) changed"
            }
        } else {
            preview = plan
            busyPreview = busyPlans
        }
        self.problems = problems.sorted()
        return plan
    }

    // MARK: - Outlook web

    func outlookSource(for sourceID: UUID) -> OutlookWebSource {
        if let existing = outlookSources[sourceID] { return existing }
        let source = OutlookWebSource(sourceID: sourceID)
        outlookSources[sourceID] = source
        return source
    }

    func showOutlookWindow(for source: SourceConfig) {
        outlookSource(for: source.id).showWindow(title: source.calendarName)
    }

    func forgetOutlookSession(for sourceID: UUID) {
        outlookSources[sourceID]?.tearDown()
        outlookSources[sourceID] = nil
        Task {
            // Give WebKit a moment to release the store; it can't be removed while in use.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: sourceID)
            } catch {
                NSLog("Calendar Sync: couldn't delete Outlook sign-in data: \(error)")
            }
        }
    }
}
