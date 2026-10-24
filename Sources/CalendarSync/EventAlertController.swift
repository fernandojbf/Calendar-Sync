import AppKit
import CalendarSyncCore
import SwiftUI

/// Shows a full-screen alert when a main-calendar event starts, with buttons to join the
/// call, go to the room, or ignore it. Each occurrence alerts once.
@MainActor
final class EventAlertController: ObservableObject {
    private let settings: SettingsStore
    private let eventKit: EventKitBridge
    private var timer: Timer?
    /// Occurrence keys already alerted, with when, so each event alerts once. Pruned daily.
    private var shown: [String: Date] = [:]
    private var window: NSWindow?

    init(settings: SettingsStore, eventKit: EventKitBridge) {
        self.settings = settings
        self.eventKit = eventKit
        // Scheduled on the main run loop, so the block runs on the main actor.
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer?.tolerance = 5
    }

    private func check() {
        guard settings.alerts.enabled, window == nil, eventKit.hasAccess,
              let targetID = settings.targetCalendarID else { return }
        let now = Date()
        // Events overlapping this window: already under way, or starting within the lead time.
        let ahead = now.addingTimeInterval(60 * Double(settings.alerts.leadMinutes) + 60)
        guard case .success(let events) = eventKit.sourceEvents(calendarID: targetID, from: now, to: ahead) else { return }

        shown = shown.filter { now.timeIntervalSince($0.value) < 24 * 3600 }
        let due = EventAlertPlanner.dueAlerts(
            events: events, shown: Set(shown.keys), now: now, leadMinutes: settings.alerts.leadMinutes)
        guard let event = due.first else { return }
        shown[event.key] = now
        show(event)
    }

    private func show(_ event: SourceEvent) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let panel = AlertPanel(contentRect: screen.frame, styleMask: [.borderless],
                               backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: EventAlertView(event: event) { [weak self] in
            self?.dismiss()
        })
        window = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func dismiss() {
        window?.orderOut(nil)
        window = nil
        // If another event is due at the same time, show it next.
        check()
    }
}

/// Borderless windows can't become key by default, but the alert's buttons need the keyboard
/// (Return joins, Escape ignores).
private final class AlertPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct EventAlertView: View {
    let event: SourceEvent
    let dismiss: () -> Void

    /// The first line of the location, for the "Go to …" button. Room names are short;
    /// addresses pasted into the location field are not.
    private var room: String? {
        guard let line = event.location?
            .components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespaces),
            !line.isEmpty
        else { return nil }
        return line.count > 60 ? String(line.prefix(60)) + "…" : line
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("\(Text(event.start, format: .dateTime.hour().minute())) – \(Text(event.end, format: .dateTime.hour().minute()))")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(event.title.isEmpty ? "Busy" : event.title)
                    .font(.system(size: 34, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                if let room {
                    Label(room, systemImage: "mappin.and.ellipse")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    if let url = event.meetingURL {
                        Button {
                            NSWorkspace.shared.open(url)
                            dismiss()
                        } label: {
                            Label("Join call", systemImage: "video.fill").frame(minWidth: 120)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        if let room {
                            Button { dismiss() } label: {
                                Label("Go to \(room)", systemImage: "figure.walk").frame(minWidth: 120)
                            }
                            .buttonStyle(.bordered)
                        }
                    } else if let room {
                        Button { dismiss() } label: {
                            Label("Go to \(room)", systemImage: "figure.walk").frame(minWidth: 120)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                    Button("Ignore", action: dismiss)
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                }
                .controlSize(.large)
                .padding(.top, 12)
            }
            .padding(44)
            .frame(maxWidth: 640)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        }
    }
}
