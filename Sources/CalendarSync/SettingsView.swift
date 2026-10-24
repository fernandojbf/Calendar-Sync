import CalendarSyncCore
import EventKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            SourcesTab().tabItem { Label("Client calendars", systemImage: "calendar") }
            PreviewTab().tabItem { Label("Preview", systemImage: "eye") }
            AuthorTab().tabItem { Label("Author", systemImage: "person.crop.circle") }
        }
        .frame(width: 620, height: 460)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var controller: SyncController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Picker("Main calendar", selection: $settings.targetCalendarID) {
                    Text("Choose a calendar…").tag(String?.none)
                    ForEach(controller.eventKit.calendars().filter(\.allowsContentModifications), id: \.calendarIdentifier) { calendar in
                        CalendarLabel(calendar: calendar).tag(Optional(calendar.calendarIdentifier))
                    }
                }
                .onChange(of: settings.targetCalendarID) { _, _ in Task { await controller.sync() } }
                Text("Client meetings are copied into this calendar. It must be added to Calendar.app.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Stepper("Today plus the next \(settings.options.daysAhead) days",
                        value: $settings.options.daysAhead, in: 0...30)
                IntervalField(label: "Sync every", minutes: $settings.intervalMinutes)
                Toggle("Skip meetings I declined", isOn: $settings.options.skipDeclined)
                Toggle("Skip all-day events", isOn: $settings.options.skipAllDay)
                Toggle("Skip out-of-office events", isOn: $settings.options.skipOutOfOffice)
            } footer: {
                Text("Each client calendar can use its own interval instead (Client calendars tab). Calendar.app calendars also sync about 10 seconds after a change.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if !controller.hasCalendarAccess {
                    Text("Calendar Sync doesn't have calendar access. Allow it in System Settings › Privacy & Security › Calendars.")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Sources

private struct SourcesTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var controller: SyncController
    @State private var showingLinkSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if settings.sources.isEmpty {
                ContentUnavailableView(
                    "No client calendars yet",
                    systemImage: "calendar.badge.plus",
                    description: Text("Add a client calendar to start copying its meetings."))
            } else {
                Form {
                    ForEach($settings.sources) { $source in
                        SourceRow(source: $source)
                    }
                }
                .formStyle(.grouped)
            }

            HStack {
                Menu("Add client calendar") {
                    Section("From Calendar.app") {
                        ForEach(availableCalendars, id: \.calendarIdentifier) { calendar in
                            Button("\(calendar.title) (\(calendar.source.title))") {
                                settings.sources.append(SourceConfig(
                                    kind: .eventKit(calendarID: calendar.calendarIdentifier),
                                    calendarName: calendar.title))
                            }
                        }
                    }
                    Section("Not in Calendar.app") {
                        Button("Outlook on the web (sign in)…") {
                            let source = SourceConfig(kind: .outlookWeb, calendarName: "Outlook")
                            settings.sources.append(source)
                            controller.showOutlookWindow(for: source)
                        }
                        Button("Calendar link (.ics)…") { showingLinkSheet = true }
                    }
                }
                .fixedSize()
                Spacer()
            }
            .padding()
        }
        .sheet(isPresented: $showingLinkSheet) { CalendarLinkSheet() }
    }

    private var availableCalendars: [EKCalendar] {
        let used = Set(settings.sources.compactMap { source -> String? in
            if case .eventKit(let id) = source.kind { return id } else { return nil }
        })
        return controller.eventKit.calendars().filter {
            !used.contains($0.calendarIdentifier) && $0.calendarIdentifier != settings.targetCalendarID
        }
    }
}

private struct SourceRow: View {
    @Binding var source: SourceConfig
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var controller: SyncController

    /// Calendar.app sources use the calendar's current name; Outlook web sources use the typed one.
    private var displayName: String {
        if case .eventKit(let calendarID) = source.kind, let calendar = controller.eventKit.calendar(id: calendarID) {
            return calendar.title
        }
        return source.calendarName
    }

    var body: some View {
        Section {
            if source.kind == .outlookWeb {
                TextField("Calendar name", text: $source.calendarName, prompt: Text("e.g. Calendar A"))
            }
            Toggle("Hide meeting names (copy as “[\(displayName)] Busy”)", isOn: $source.hideMeetingName)
            Toggle("Copy location and description", isOn: $source.copyDetails)
                .disabled(source.hideMeetingName)
            Toggle("Sync this calendar", isOn: $source.isEnabled)
            Toggle("Use its own sync interval", isOn: Binding(
                get: { source.intervalMinutes != nil },
                set: { source.intervalMinutes = $0 ? settings.intervalMinutes : nil }))
            if source.intervalMinutes != nil {
                IntervalField(label: "Sync this calendar every", minutes: Binding(
                    get: { source.intervalMinutes ?? settings.intervalMinutes },
                    set: { source.intervalMinutes = $0 }))
            }
            if case .eventKit(let calendarID) = source.kind {
                let writable = controller.eventKit.calendar(id: calendarID)?.allowsContentModifications ?? false
                Toggle("Show my main calendar here as “\(source.busyStyle.title)”", isOn: $source.showBusyInClient)
                    .disabled(!writable && !source.showBusyInClient)
                    .onChange(of: source.showBusyInClient) { _, _ in Task { await controller.sync() } }
                if source.showBusyInClient {
                    Picker("Show it as", selection: $source.busyStyle) {
                        ForEach(BusyStyle.allCases, id: \.self) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: source.busyStyle) { _, _ in Task { await controller.sync() } }
                }
                if !writable {
                    Text("This calendar is read-only, so Busy events can't be added to it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                if source.kind == .outlookWeb {
                    Button("Open Outlook window") { controller.showOutlookWindow(for: source) }
                }
                Spacer()
                Button("Remove", role: .destructive) {
                    if source.kind == .outlookWeb { controller.forgetOutlookSession(for: source.id) }
                    let id = source.id
                    // Removed on the next run loop so SwiftUI isn't still reading this row's binding.
                    DispatchQueue.main.async { settings.sources.removeAll { $0.id == id } }
                }
            }
        } header: {
            switch source.kind {
            case .eventKit(let calendarID):
                if let calendar = controller.eventKit.calendar(id: calendarID) {
                    CalendarLabel(calendar: calendar)
                } else {
                    Label("Calendar no longer in Calendar.app", systemImage: "exclamationmark.triangle")
                }
            case .outlookWeb:
                Label("Outlook on the web (experimental)", systemImage: "globe")
            }
        } footer: {
            Text(footer).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footer: String {
        var text = "Copies are titled “[\(displayName)] \(source.hideMeetingName ? "Busy" : "Meeting name")” and include the meeting link when there is one."
        if source.copyDetails {
            text += source.hideMeetingName
                ? " Location and description aren't copied while meeting names are hidden."
                : " The location and description are copied too."
        }
        if source.showBusyInClient {
            text += " Your main calendar's events also appear here as “\(source.busyStyle.title)”, with no other details."
        }
        let minutes = SyncSchedule.interval(for: source, defaultMinutes: settings.intervalMinutes)
        text += " Synced every \(minutes) \(minutes == 1 ? "minute" : "minutes")"
        if case .eventKit = source.kind { text += " and about 10 seconds after a change" }
        return text + "."
    }
}

/// "Sync every [15] minutes": type any value, or step through common ones.
private struct IntervalField: View {
    let label: String
    @Binding var minutes: Int

    private static let steps = [1, 2, 5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240, 360, 480, 720, 1440]

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField(label, value: $minutes, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                Text(minutes == 1 ? "minute" : "minutes")
                Stepper(label, onIncrement: {
                    minutes = Self.steps.first { $0 > minutes } ?? SyncSchedule.maxMinutes
                }, onDecrement: {
                    minutes = Self.steps.last { $0 < minutes } ?? SyncSchedule.minMinutes
                })
                .labelsHidden()
            }
        }
        .onChange(of: minutes) { _, value in
            let clamped = min(max(value, SyncSchedule.minMinutes), SyncSchedule.maxMinutes)
            if clamped != value { minutes = clamped }
        }
    }
}

/// Subscribes to a client calendar link through Calendar.app, which then keeps it updated.
private struct CalendarLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a calendar link").font(.headline)
            Text("""
                In Outlook on the web: Settings › Calendar › Shared calendars › Publish a calendar, \
                then copy the ICS link. In Google Calendar: Settings › your calendar › \
                Secret address in iCal format.
                """)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://…/calendar.ics", text: $link)
            Text("Calendar.app will ask how to add it. Once it's added, choose it here under “From Calendar.app”.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Open in Calendar") {
                    if let url = Self.webcalURL(link) { NSWorkspace.shared.open(url) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(Self.webcalURL(link) == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    static func webcalURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "webcal", "webcals"].contains(scheme),
              components.host != nil
        else { return nil }
        components.scheme = "webcal"
        return components.url
    }
}

// MARK: - Preview

private struct PreviewTab: View {
    @EnvironmentObject private var controller: SyncController

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("See what the next sync would change, without changing anything.")
                Spacer()
                Button("Preview") { Task { await controller.sync(apply: false) } }
                    .disabled(controller.isSyncing)
            }
            if let plan = controller.preview {
                Text(plan.isEmpty
                     ? "Nothing to change (\(plan.unchangedCount) copies up to date)."
                     : "\(plan.creates) to add, \(plan.updates) to update, \(plan.deletes) to remove, \(plan.unchangedCount) unchanged.")
                    .foregroundStyle(.secondary)
                ForEach(controller.busyPreview) { busy in
                    Text("Busy in \(busy.calendarName): \(busy.plan.creates) to add, \(busy.plan.updates) to update, \(busy.plan.deletes) to remove.")
                        .foregroundStyle(.secondary)
                }
                List(previewRows(plan), id: \.offset) { row in
                    HStack {
                        Text(row.element.action.verb).frame(width: 60, alignment: .leading).foregroundStyle(.secondary)
                        Text(row.element.title)
                        Spacer()
                        Text(row.element.action.start, format: .dateTime.weekday().day().month().hour().minute())
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Spacer()
            }
            ForEach(controller.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .padding()
    }

    /// Main-calendar changes first, then the Busy events per client calendar.
    private func previewRows(_ plan: SyncPlan) -> [EnumeratedSequence<[(action: SyncAction, title: String)]>.Element] {
        var rows = plan.actions.map { (action: $0, title: $0.title) }
        for busy in controller.busyPreview {
            rows += busy.plan.actions.map { (action: $0, title: "Busy in \(busy.calendarName)") }
        }
        return Array(rows.enumerated())
    }
}

// MARK: - Author

private struct AuthorTab: View {
    @Environment(\.openURL) private var openURL

    private var version: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
            VStack(spacing: 2) {
                Text("Calendar Sync").font(.title2.bold())
                if let version {
                    Text("Version \(version)").foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 4) {
                Text("Made by Pedro Vicente").font(.headline)
                Link("pedrovicente.pt", destination: URL(string: "https://pedrovicente.pt")!)
            }

            Divider().frame(width: 280)

            Text("If Calendar Sync saves you time, a donation helps me keep developing open source and free software.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button {
                    openURL(URL(string: "https://revolut.me/neteinstein")!)
                } label: {
                    Label("Donate with Revolut", systemImage: "heart.fill")
                }
                Button {
                    openURL(URL(string: "https://www.buymeacoffee.com/neteinstein")!)
                } label: {
                    Label("Buy me a coffee", systemImage: "cup.and.saucer.fill")
                }
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CalendarLabel: View {
    let calendar: EKCalendar

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color(cgColor: calendar.cgColor)).frame(width: 9, height: 9)
            Text(calendar.title)
            Text(calendar.source.title).foregroundStyle(.secondary)
        }
    }
}
