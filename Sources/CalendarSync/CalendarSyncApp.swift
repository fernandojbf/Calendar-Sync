import SwiftUI

@main
struct CalendarSyncApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var controller: SyncController
    @StateObject private var alerts: EventAlertController
    @StateObject private var updates = UpdateChecker()
    @StateObject private var today = Today()

    init() {
        let settings = SettingsStore()
        let controller = SyncController(settings: settings)
        _settings = StateObject(wrappedValue: settings)
        _controller = StateObject(wrappedValue: controller)
        _alerts = StateObject(wrappedValue: EventAlertController(settings: settings, eventKit: controller.eventKit))
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
