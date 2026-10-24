import SwiftUI

@main
struct CalendarSyncApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var controller: SyncController
    @StateObject private var alerts: EventAlertController
    @StateObject private var updates = UpdateChecker()

    init() {
        let settings = SettingsStore()
        let controller = SyncController(settings: settings)
        _settings = StateObject(wrappedValue: settings)
        _controller = StateObject(wrappedValue: controller)
        _alerts = StateObject(wrappedValue: EventAlertController(settings: settings, eventKit: controller.eventKit))
    }

    /// The icon in the menu bar: a calendar glyph, plus today's date when the menu calendar
    /// is on. TimelineView keeps the date right past midnight.
    private struct MenuBarLabel: View {
        @ObservedObject var settings: SettingsStore
        @ObservedObject var controller: SyncController

        var body: some View {
            let icon = controller.problems.isEmpty ? "calendar" : "calendar.badge.exclamationmark"
            if settings.menuCalendarEnabled {
                TimelineView(.everyMinute) { context in
                    HStack(spacing: 3) {
                        Image(systemName: icon)
                        Text(context.date, format: .dateTime.day().month(.abbreviated))
                    }
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
            MenuBarLabel(settings: settings, controller: controller)
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
