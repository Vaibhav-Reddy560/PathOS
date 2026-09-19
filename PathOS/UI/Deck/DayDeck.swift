import CoreLocation
import SwiftData
import SwiftUI

/// Day: what's planned, what's next, and what a past day actually held.
/// Time and place together — every event can point you at its place.
struct DayDeck: View {
    @Environment(AppState.self) private var state
    @Query(sort: \PathEvent.start) private var allEvents: [PathEvent]
    @Query(sort: \SpatialNote.createdAt, order: .reverse) private var notes: [SpatialNote]
    @Query(sort: \DayLog.dayStart, order: .reverse) private var dayLogs: [DayLog]
    @Query private var timetableEntries: [TimetableEntry]
    @Query private var timetableExceptions: [TimetableException]
    @Query private var trips: [Trip]

    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var now = Date()
    /// A day in detail, or the month around it at a glance.
    @AppStorage("pathos.dayViewMode") private var mode: DayViewMode = .day
    /// Any day of the month the calendar shows.
    @State private var month = MonthGrid.month(0, from: Date())
    /// Your Apple Calendar's own events for the days on screen.
    @State private var calendarItems: [CalendarItem] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("View", selection: $mode) {
                    ForEach(DayViewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                switch mode {
                case .day: dayView
                case .month: monthView
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .task {
            // Keeps "in 12 min" honest without a Combine timer.
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .task(id: shownRange) {
            calendarItems = CalendarEventSource.items(
                from: shownRange.lowerBound,
                to: shownRange.upperBound,
                excluding: Set(allEvents.compactMap(\.calendarEventID))
            )
        }
        .onChange(of: mode) { _, mode in
            if mode == .month { month = MonthGrid.month(0, from: day) }
        }
    }

    // MARK: Views

    @ViewBuilder
    private var dayView: some View {
        dayPicker
        if let trip = tripForDay {
            tripBanner(trip)
        }
        summary
        if isPast || (isToday && !daySummary.isEmpty) {
            Text(daySummary.sentence)
                .font(.subheadline)
                .foregroundStyle(.mist)
                .padding(.horizontal, 4)
                .accessibilityLabel("Day summary: \(daySummary.sentence)")
        }
        if isToday, let next = nextItem {
            nextUp(next)
        }
        if isToday {
            MailInbox()
        }
        schedule(title: isPast ? "What happened" : "Schedule")
        actions
    }

    @ViewBuilder
    private var monthView: some View {
        MonthCalendar(month: $month, selected: $day) { date in
            items(on: date).prefix(3).map(\.role)
        }

        schedule(title: day.formatted(.dateTime.weekday(.wide).day().month(.wide)))

        Button {
            withAnimation(PathMotion.control) { mode = .day }
        } label: {
            Label("Open this day", systemImage: "list.bullet.below.rectangle")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 32)
        }
        .pathSecondaryAction()
    }

    // MARK: Sections

    private var dayPicker: some View {
        HStack(spacing: 12) {
            Button {
                shift(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 40)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.ice)
            .accessibilityLabel("Previous day")

            VStack(spacing: 1) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.ice)
                InstrumentLabel(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
            }
            .frame(maxWidth: .infinity)

            Button {
                shift(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 40)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.ice)
            .accessibilityLabel("Next day")
        }
        .accessibilityElement(children: .contain)
    }

    private func tripBanner(_ trip: Trip) -> some View {
        ContentTile(padding: 14) {
            HStack(spacing: 12) {
                SignalGlyph(symbol: "suitcase.rolling.fill", role: .you, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    InstrumentLabel(trip.dayNumber(for: day).map { "Day \($0) of \(trip.dayCount)" } ?? "Trip", role: .you)
                    Text(trip.name)
                        .font(.headline)
                        .foregroundStyle(.ice)
                        .lineLimit(1)
                    if !trip.legs.isEmpty {
                        Text(TripPlan.modeSummary(trip.legs.map(TripStore.plannedLeg)))
                            .font(.subheadline)
                            .foregroundStyle(.mist)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
            .onTapGesture { state.isTripsPresented = true }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
        }
    }

    private var summary: some View {
        ContentTile {
            HStack(spacing: 20) {
                let distance = dayLog?.distanceMeters ?? 0
                let parts = DayDistance.format(distance).split(separator: " ")
                MetricView(
                    label: "Travelled",
                    value: distance > 0 ? String(parts.first ?? "0") : "—",
                    unit: distance > 0 && parts.count > 1 ? String(parts[1]) : nil,
                    role: .you
                )
                MetricView(label: "Events", value: "\(events.count + calendarItems(on: day).count)", role: .world)
                MetricView(label: "Saved here", value: "\(memoriesSaved)", role: .you)
                Spacer(minLength: 0)
            }
        }
    }

    private func nextUp(_ next: DayItem) -> some View {
        ContentTile {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    SignalGlyph(symbol: next.isUnderway(now: now) ? "play.circle.fill" : next.symbol, role: .attention, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        InstrumentLabel(next.isUnderway(now: now) ? "Happening now" : "Next up", role: .attention)
                        Text(next.title)
                            .font(.headline)
                            .foregroundStyle(.ice)
                            .lineLimit(2)
                        Text(next.timeRange + (next.placeName.map { " · \($0)" } ?? ""))
                            .font(.subheadline)
                            .foregroundStyle(.mist)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(DayPlan.relativeTime(to: next.isUnderway(now: now) ? next.end : next.start, now: now))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.amber)
                        if next.isUnderway(now: now) {
                            InstrumentLabel("left")
                        }
                    }
                }
                .accessibilityElement(children: .combine)

                if let coordinate = next.coordinate {
                    Button {
                        state.startCompass(to: CompassTarget(id: next.id, name: next.title, latitude: coordinate.latitude, longitude: coordinate.longitude))
                    } label: {
                        Label("Point me there", systemImage: "location.north.line.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .pathPrimaryAction()
                }
            }
        }
    }

    private func schedule(title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            DeckSectionHeader(title: title, trailing: items.isEmpty ? nil : "\(items.count)")
            if isDayOff {
                EmptyState(symbol: "figure.walk.motion", title: "No classes today", message: "You marked this day off. Events still show here.", role: .you)
            } else if items.isEmpty {
                EmptyState(
                    symbol: "calendar",
                    title: isPast ? "Nothing recorded" : "Nothing scheduled",
                    message: isPast
                        ? "No events were saved for this day."
                        : "Add an event, paste a message, or import your timetable."
                )
            }
            if !items.isEmpty {
                GroupedRows(items) { item in
                    DayItemRow(item: item, now: now)
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                state.eventSheet = EventSheetRequest(editing: nil, text: nil)
            } label: {
                Label("Add an event", systemImage: "calendar.badge.plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .pathPrimaryAction()

            Button {
                state.eventSheet = EventSheetRequest(editing: nil, text: UIPasteboard.general.string)
            } label: {
                Label("Paste a message", systemImage: "doc.on.clipboard")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .pathSecondaryAction()

            // Two to a row, each label on one line; stacked when the text is too large for that.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { tripAndTimetableButtons }
                VStack(spacing: 10) { tripAndTimetableButtons }
            }

            if !timetableEntries.isEmpty {
                Button {
                    state.timetable.setDayOff(day, isOff: !isDayOff)
                } label: {
                    OneLineButtonLabel(title: isDayOff ? "Classes are on today" : "No classes today",
                                       symbol: isDayOff ? "arrow.uturn.backward" : "xmark.circle")
                }
                .pathSecondaryAction()
            }
        }
    }

    @ViewBuilder
    private var tripAndTimetableButtons: some View {
        Button {
            state.isTripsPresented = true
        } label: {
            OneLineButtonLabel(title: trips.isEmpty ? "Plan a trip" : "Trips", symbol: "suitcase.rolling")
        }
        .pathSecondaryAction()

        Button {
            state.isTimetablePresented = true
        } label: {
            OneLineButtonLabel(title: timetableEntries.isEmpty ? "Add timetable" : "Timetable", symbol: "graduationcap")
        }
        .pathSecondaryAction()
    }

    // MARK: Data

    private var events: [PathEvent] { events(on: day) }
    private var classSessions: [ClassSession] { classSessions(on: day) }
    private var legs: [TripLeg] { legs(on: day) }
    private var items: [DayItem] { items(on: day) }

    private func events(on day: Date) -> [PathEvent] {
        DayPlan.events(allEvents.map(EventStore.plannedEvent), on: day).compactMap { event(for: $0.id) }
    }

    private func classSessions(on day: Date) -> [ClassSession] {
        TimetableRoutine.sessions(
            slots: timetableEntries.map(TimetableService.slot),
            skips: timetableExceptions.map(TimetableService.skip),
            on: day
        )
    }

    private func legs(on day: Date) -> [TripLeg] {
        let planned = TripPlan.legs(trips.flatMap { $0.legs }.map(TripStore.plannedLeg), on: day)
        let byID = Dictionary(uniqueKeysWithValues: trips.flatMap { $0.legs }.map { ($0.id, $0) })
        return planned.compactMap { byID[$0.id] }
    }

    private func calendarItems(on day: Date) -> [CalendarItem] {
        guard let interval = Calendar.current.dateInterval(of: .day, for: day) else { return [] }
        return calendarItems.filter { $0.start < interval.end && ($0.end > interval.start || $0.start >= interval.start) }
    }

    /// Everything happening on a day — legs, classes, events and your calendar's own — earliest first.
    private func items(on day: Date) -> [DayItem] {
        (events(on: day).map(DayItem.event) + classSessions(on: day).map(DayItem.classSession)
            + legs(on: day).map(DayItem.leg) + calendarItems(on: day).map(DayItem.calendar))
            .sorted { $0.start < $1.start }
    }

    /// The days on screen, whose calendar events are read: the month's grid, or the one day.
    private var shownRange: Range<Date> {
        let days = mode == .month ? MonthGrid.days(around: month) : [day]
        let start = days.first ?? day
        let end = Calendar.current.date(byAdding: .day, value: 1, to: days.last ?? day) ?? day
        return start..<end
    }

    private var tripForDay: Trip? {
        trips.first { $0.covers(day) }
    }

    private var daySummary: DaySummary {
        DaySummary(
            distanceMeters: dayLog?.distanceMeters ?? 0,
            eventCount: events.count + calendarItems(on: day).count,
            classCount: classSessions.count,
            legCount: legs.count,
            memoryCount: memoriesSaved,
            tripName: tripForDay?.name,
            tripDayNumber: tripForDay?.dayNumber(for: day),
            tripDayCount: tripForDay?.dayCount
        )
    }

    private var nextItem: DayItem? {
        items.filter { $0.end > now }.min { $0.start < $1.start }
    }

    private var isDayOff: Bool {
        timetableExceptions.contains { $0.entryID == nil && Calendar.current.isDate($0.dayStart, inSameDayAs: day) }
    }

    private func event(for id: UUID) -> PathEvent? {
        allEvents.first { $0.id == id }
    }

    private var dayLog: DayLog? {
        dayLogs.first { Calendar.current.isDate($0.dayStart, inSameDayAs: day) }
    }

    private var memoriesSaved: Int {
        notes.filter { Calendar.current.isDate($0.createdAt, inSameDayAs: day) }.count
    }

    private var isToday: Bool { Calendar.current.isDateInToday(day) }
    private var isPast: Bool { day < Calendar.current.startOfDay(for: Date()) }

    private var title: String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        if Calendar.current.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.day().month(.abbreviated).year())
    }

    private func shift(by days: Int) {
        guard let next = Calendar.current.date(byAdding: .day, value: days, to: day) else { return }
        withAnimation(PathMotion.control) { day = next }
    }
}

/// One thing on a day: an event you saved, or a class from your timetable.
enum DayItem: Identifiable {
    case event(PathEvent)
    case classSession(ClassSession)
    case leg(TripLeg)
    /// From your Apple Calendar, which PathOS reads but doesn't own.
    case calendar(CalendarItem)

    var id: String {
        switch self {
        case .event(let event): "event:\(event.id.uuidString)"
        case .classSession(let session): "class:\(session.id)"
        case .leg(let leg): "leg:\(leg.id.uuidString)"
        case .calendar(let item): "calendar:\(item.id)"
        }
    }

    var title: String {
        switch self {
        case .event(let event): event.title
        case .classSession(let session): session.subject
        case .leg(let leg): "\(leg.mode.label) to \(leg.destination)"
        case .calendar(let item): item.title
        }
    }

    var start: Date {
        switch self {
        case .event(let event): event.start
        case .classSession(let session): session.start
        case .leg(let leg): leg.departure
        case .calendar(let item): item.start
        }
    }

    var end: Date {
        switch self {
        case .event(let event): event.end
        case .classSession(let session): session.end
        case .leg(let leg): TripStore.plannedLeg(leg).arrivalEstimate() ?? leg.departure.addingTimeInterval(3_600)
        case .calendar(let item): item.end
        }
    }

    var isAllDay: Bool {
        switch self {
        case .event(let event): event.isAllDay
        case .calendar(let item): item.isAllDay
        default: false
        }
    }

    var placeName: String? {
        switch self {
        case .event(let event): event.placeName
        case .classSession(let session): session.room
        case .leg(let leg): "from \(leg.origin)"
        case .calendar(let item): item.location?.split(separator: "\n").first.map(String.init)
        }
    }

    var coordinate: CLLocationCoordinate2D? {
        switch self {
        case .event(let event): event.coordinate
        case .classSession: nil
        case .leg(let leg): leg.destinationCoordinate
        case .calendar(let item):
            if let latitude = item.latitude, let longitude = item.longitude {
                CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            } else {
                nil
            }
        }
    }

    var tags: [String] {
        switch self {
        case .event(let event): event.tags
        case .classSession(let session): session.isMoved ? ["Changed today"] : []
        case .leg: []
        case .calendar(let item): [item.calendarName]
        }
    }

    var symbol: String {
        switch self {
        case .event: "calendar"
        case .classSession: "graduationcap.fill"
        case .leg(let leg): leg.mode.symbol
        case .calendar: isOnline ? "video.fill" : "calendar"
        }
    }

    /// Happens on a call rather than somewhere.
    var isOnline: Bool {
        guard case .calendar(let item) = self else { return false }
        return item.location.map(MailTriage.isOnline) ?? false
    }

    /// Your own plans are green; events, yours or your calendar's, are the world's cyan.
    var role: SignalRole {
        switch self {
        case .classSession, .leg: .you
        case .event, .calendar: .world
        }
    }

    /// A deadline has no length, so it shows as a single time.
    var isMoment: Bool { !isAllDay && end <= start }

    var timeRange: String {
        if isAllDay { return "All day" }
        if isMoment { return "Due \(start.formatted(date: .omitted, time: .shortened))" }
        return "\(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))"
    }

    func isUnderway(now: Date) -> Bool { start <= now && end > now }
}

private struct DayItemRow: View {
    let item: DayItem
    let now: Date

    @Environment(AppState.self) private var state

    var body: some View {
        let isDone = item.end < now
        let isNow = item.isUnderway(now: now)

        HStack(spacing: 14) {
            TimeSpan(
                start: item.isAllDay ? "All day" : item.start.formatted(date: .omitted, time: .shortened),
                end: item.isAllDay || item.isMoment ? nil : item.end.formatted(date: .omitted, time: .shortened),
                isDone: isDone
            )

            VStack(alignment: .leading, spacing: 3) {
                Label {
                    Text(item.title)
                        .font(.headline)
                        .foregroundStyle(isDone ? .mist : .ice)
                        .lineLimit(2)
                } icon: {
                    Image(systemName: item.symbol)
                        .font(.caption)
                        .foregroundStyle(.mist)
                }
                if let place = item.placeName {
                    Label(place, systemImage: "mappin")
                        .font(.subheadline)
                        .foregroundStyle(.mist)
                        .lineLimit(1)
                }
                if !item.tags.isEmpty {
                    Text(item.tags.joined(separator: " · "))
                        .font(.pathInstrument)
                        .foregroundStyle(.ion)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if isNow {
                Text("Now")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.amber)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(.rect)
        .onTapGesture {
            switch item {
            case .event(let event): state.eventSheet = EventSheetRequest(editing: event.id, text: nil)
            case .classSession: state.isTimetablePresented = true
            case .leg: state.isTripsPresented = true
            case .calendar(let item):
                // Apple Calendar owns these; it opens at the event's day.
                if let url = URL(string: "calshow:\(Int(item.start.timeIntervalSinceReferenceDate))") {
                    UIApplication.shared.open(url)
                }
            }
        }
        .contextMenu {
            if let coordinate = item.coordinate {
                Button("Point me there", systemImage: "location.north.line.fill") {
                    state.startCompass(to: CompassTarget(id: item.id, name: item.title, latitude: coordinate.latitude, longitude: coordinate.longitude))
                }
            }
            if case .event(let event) = item {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    state.eventStore.delete(event)
                }
            }
            if case .leg(let leg) = item {
                Button("Delete leg", systemImage: "trash", role: .destructive) {
                    state.trips.delete(leg)
                }
            }
            if case .classSession(let session) = item {
                Button("Skip this class today", systemImage: "xmark.circle") {
                    let context = state.modelContainer.mainContext
                    context.insert(TimetableException(dayStart: Calendar.current.startOfDay(for: session.start), reason: "Cancelled", entryID: session.slotID))
                    try? context.save()
                    state.timetable.refreshReminders()
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

enum DayViewMode: String, CaseIterable, Identifiable {
    case day
    case month

    var id: String { rawValue }
    var title: String { self == .day ? "Day" : "Month" }
}
