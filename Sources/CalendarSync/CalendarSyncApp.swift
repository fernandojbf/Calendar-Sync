import SwiftUI

@main
struct CalendarSyncApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var controller: SyncController
    @StateObject private var alerts: EventAlertController

    init() {
        let settings = SettingsStore()
        let controller = SyncController(settings: settings)
        _settings = StateObject(wrappedValue: settings)
        _controller = StateObject(wrappedValue: controller)
        _alerts = StateObject(wrappedValue: EventAlertController(settings: settings, eventKit: controller.eventKit))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(settings)
                .environmentObject(controller)
        } label: {
            Image(systemName: controller.problems.isEmpty ? "calendar.badge.clock" : "calendar.badge.exclamationmark")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(controller)
        }
    }
}
