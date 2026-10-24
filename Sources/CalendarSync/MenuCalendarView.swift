import AppKit
import CalendarSyncCore
import SwiftUI

/// The month grid and event list shown at the top of the menu when "Show a calendar in the
/// menu" is on. Events come from the main calendar, where client meetings are already copied.
struct MenuCalendarView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var controller: SyncController
    @AppStorage("menuCalendarMode") private var mode: Mode = .month
    @State private var shownMonth = Date()
    /// A day picked in the month grid, shown as that day's event list until dismissed.
    @State private var selectedDay: Date?
    @State private var events: [SourceEvent] = []

    enum Mode: String {
        case month, list
    }

    private var calendar: Calendar { Calendar.current }

    var body: some View {
        VStack(spacing: 10) {
            Picker("View", selection: $mode) {
                Text("Month").tag(Mode.month)
                Text("List").tag(Mode.list)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .month:
                if let day = selectedDay {
                    dayView(day)
                } else {
                    monthView
                }
            case .list:
                listView
            }
        }
        .onAppear { reload() }
        .onChange(of: mode) { _, _ in reload() }
        .onChange(of: shownMonth) { _, _ in reload() }
        .onChange(of: controller.lastSync) { _, _ in reload() }
    }

    // MARK: - Data

    /// Reads the shown month (or the list's window) from the main calendar.
    private func reload() {
        guard let targetID = settings.targetCalendarID else {
            events = []
            return
        }
        let (from, to): (Date, Date)
        switch mode {
        case .month:
            let days = MenuCalendar.gridDays(for: shownMonth, calendar: calendar)
            guard let first = days.first, let last = days.last,
                  let end = calendar.date(byAdding: .day, value: 1, to: last) else { return }
            (from, to) = (first, end)
        case .list:
            let today = calendar.startOfDay(for: Date())
            (from, to) = (calendar.date(byAdding: .day, value: -30, to: today)!,
                          calendar.date(byAdding: .day, value: 60, to: today)!)
        }
        if case .success(let fetched) = controller.eventKit.sourceEvents(calendarID: targetID, from: from, to: to) {
            events = fetched.filter { !$0.isCancelled }
        }
    }

    private func events(on day: Date) -> [SourceEvent] {
        events
            .filter { calendar.isDate($0.start, inSameDayAs: day) }
            .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
    }

    // MARK: - Month

    private var monthView: some View {
        VStack(spacing: 6) {
            HStack {
                Button(action: { shownMonth = calendar.date(byAdding: .month, value: -1, to: shownMonth) ?? shownMonth },
                       label: { Image(systemName: "chevron.left") })
                Spacer()
                Text(shownMonth, format: .dateTime.month(.wide).year()).font(.headline)
                Spacer()
                Button("Today") { shownMonth = Date() }
                    .disabled(calendar.isDate(shownMonth, equalTo: Date(), toGranularity: .month))
                Button(action: { shownMonth = calendar.date(byAdding: .month, value: 1, to: shownMonth) ?? shownMonth },
                       label: { Image(systemName: "chevron.right") })
            }
            .buttonStyle(.borderless)

            let days = MenuCalendar.gridDays(for: shownMonth, calendar: calendar)
            let busyDays = Set(events.map { calendar.startOfDay(for: $0.start) })
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol).font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(days, id: \.self) { day in
                    dayCell(day, hasEvents: busyDays.contains(calendar.startOfDay(for: day)))
                }
            }
        }
    }

    /// Weekday initials starting on the calendar's first weekday.
    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private func dayCell(_ day: Date, hasEvents: Bool) -> some View {
        let isToday = calendar.isDateInToday(day)
        let inMonth = calendar.isDate(day, equalTo: shownMonth, toGranularity: .month)
        return Button {
            selectedDay = day
        } label: {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.callout)
                    .fontWeight(isToday ? .bold : .regular)
                    .foregroundStyle(isToday ? AnyShapeStyle(.white)
                                     : inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                Circle()
                    .fill(hasEvents ? (isToday ? Color.white : Color.accentColor) : .clear)
                    .frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .background(isToday ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - One day

    private func dayView(_ day: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    selectedDay = nil
                } label: {
                    Label("Month", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                Spacer()
                Text(day, format: .dateTime.weekday(.wide).day().month()).font(.headline)
            }
            let dayEvents = events(on: day)
            if dayEvents.isEmpty {
                Text("No events")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(dayEvents, id: \.key) { event in
                            EventRow(event: event)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
    }

    // MARK: - List

    /// Every event of the window, one section per day. Opens at the first event still to
    /// come; scrolling back shows past events dimmed.
    private var listView: some View {
        let sections = MenuCalendar.sections(for: events, calendar: calendar)
        let now = Date()
        let anchor = sections.flatMap(\.events).first { $0.end >= now }?.key
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if sections.isEmpty {
                        Text("No events")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                    ForEach(sections, id: \.day) { section in
                        Text(sectionTitle(section.day))
                            .font(.caption.bold())
                            .foregroundStyle(section.day < calendar.startOfDay(for: now) ? .tertiary : .secondary)
                            .padding(.top, 8)
                        ForEach(section.events, id: \.key) { event in
                            EventRow(event: event)
                                .id(event.key)
                        }
                    }
                }
            }
            .frame(height: 300)
            .onAppear {
                if let anchor { proxy.scrollTo(anchor, anchor: .top) }
            }
        }
    }

    private func sectionTitle(_ day: Date) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month())
    }
}

/// One event line: time, title, location, and a join button when there's a link.
/// Events already over are dimmed.
private struct EventRow: View {
    let event: SourceEvent

    var body: some View {
        let isPast = event.end < Date()
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(event.isAllDay ? "All day" : event.start.formatted(.dateTime.hour().minute()))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title.isEmpty ? "Busy" : event.title)
                    .font(.callout)
                    .lineLimit(1)
                if let location = event.location?.components(separatedBy: .newlines).first,
                   !location.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(location).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let url = event.meetingURL, !isPast {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "video.fill")
                }
                .buttonStyle(.borderless)
                .help("Join the call")
            }
        }
        .opacity(isPast ? 0.4 : 1)
    }
}
