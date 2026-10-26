import CalendarSyncCore
import SwiftUI

@main
struct CalendarSyncApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var controller: SyncController
    @StateObject private var alerts: EventAlertController
    @StateObject private var updates = UpdateChecker()
    @StateObject private var today = Today()

    /// Held until the process ends. See `InstanceLock`.
    private static var instanceLock: InstanceLock?

    init() {
        Self.quitIfAlreadyRunning()
        let settings = SettingsStore()
        let controller = SyncController(settings: settings)
        _settings = StateObject(wrappedValue: settings)
        _controller = StateObject(wrappedValue: controller)
        _alerts = StateObject(wrappedValue: EventAlertController(settings: settings, eventKit: controller.eventKit))
    }

    /// A copy already running would sync the same calendars: an "Open at login" item next to
    /// a `brew services` one, or a source build next to a Homebrew one. Every copy shares the
    /// lock file, so a later one quits here, before it asks for calendar access, syncs or shows
    /// anything. If the lock can't be taken at all, running beats not running.
    private static func quitIfAlreadyRunning() {
        guard instanceLock == nil else { return }
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("org.neteinstein.calendarsync/instance.lock")
        do {
            guard let lock = try InstanceLock.acquire(at: url) else {
                NSLog("Calendar Sync is already running, so this copy quits.")
                exit(0)
            }
            instanceLock = lock
        } catch {
            NSLog("Calendar Sync couldn't check for another running copy, so it runs anyway: \(error)")
        }
    }

    /// The icon in the menu bar: a calendar glyph, plus today's date when the menu calendar
    /// is on. `Today` keeps the date right past midnight. Not a TimelineView: in a menu bar
    /// label it re-renders the button in an endless loop and the app hangs at launch.
    private struct MenuBarLabel: View {
        @ObservedObject var settings: SettingsStore
        @ObservedObject var controller: SyncController
        @ObservedObject var today: Today

        var body: some View {
            let icon = controller.problems.isEmpty ? "calendar" : "calendar.badge.exclamationmark"
            if settings.menuCalendarEnabled {
                HStack(spacing: 3) {
                    Image(systemName: icon)
                    Text(today.date, format: .dateTime.day().month(.abbreviated))
                }
            } else {
                Image(systemName: controller.problems.isEmpty ? "calendar.badge.clock" : "calendar.badge.exclamationmark")
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(settings)
                .environmentObject(controller)
        } label: {
            MenuBarLabel(settings: settings, controller: controller, today: today)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(controller)
                .environmentObject(updates)
        }
    }
}

/// Today's date for the menu bar label. Checks every minute and publishes only when the day
/// changes, so the label redraws once a day.
@MainActor
final class Today: ObservableObject {
    @Published private(set) var date = Calendar.current.startOfDay(for: Date())
    private var timer: Timer?

    init() {
        // Scheduled on the main run loop, so the block runs on the main actor.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 10
    }

    private func refresh() {
        let day = Calendar.current.startOfDay(for: Date())
        if day != date { date = day }
    }
}
