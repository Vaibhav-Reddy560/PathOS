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
    @Query private var savedPlaces: [SavedPlace]
    @Query(sort: \Reminder.createdAt) private var allReminders: [Reminder]

    /// Answered elective questions; watched so an answer takes the question away at once.
    @AppStorage(TimetableService.settledClashesKey) private var settledClashes = ""
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
                // Your schedule, a day or a month at a time, or what your mail is waiting on you for.
                // Fixed titles. A count in Mail's changed with every day moved to, and each change
                // rebuilt the control: its highlight slid across from Day and the text jumped. The
                // day's count is on Mail's own "All" chip instead.
                Picker("View", selection: $mode) {
                    ForEach(DayViewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                switch mode {
                case .day: dayView
                case .month: monthView
                case .mail:
                    // The day you were on: its mail, not everything waiting.
                    dayPicker
                    MailInbox(day: day)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .deckScroll()
        .task {
            // Keeps "in 12 min" honest without a Combine timer.
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .task(id: shownRange) {
            // Read off the main thread: a month of Apple Calendar is a noticeable wait.
            let range = shownRange
            let mirrored = Set(allEvents.compactMap(\.calendarEventID))
            calendarItems = await Task.detached(priority: .userInitiated) {
                CalendarEventSource.items(from: range.lowerBound, to: range.upperBound, excluding: mirrored)
            }.value
        }
        .onChange(of: mode) { _, mode in
            if mode == .month { month = MonthGrid.month(0, from: day) }
        }
    }

    // MARK: Views

    /// What's next and the schedule come first, then the ways to add to it; how the day added up
    /// is last. Mail has its own tab, so it never pushes the schedule down.
    @ViewBuilder
    private var dayView: some View {
        dayPicker
        if let trip = tripForDay {
            tripBanner(trip)
        }
        if isToday, let next = nextItem {
            nextUp(next)
        }
        if !isPast {
            ForEach(openClashes, id: \.self) { group in
                ContentTile {
                    ElectiveQuestion(
                        group: group,
                        when: TimetableClashes.when(group, in: timetableEntries.map(TimetableService.slot)),
                        choose: { kept in
                            state.timetable.keep(kept, of: group)
                            state.showToast("\(kept) kept · the others are off your week")
                        },
                        keepAll: { state.timetable.keepAll(group) }
                    )
                }
            }
        }
        schedule(title: isPast ? "What happened" : "Plan")
        if !dayReminders.isEmpty {
            checklist
        }
        if !isPast {
            quickActions
        }
        // Only where there is something to take off.
        if !isPast, !classSessions.isEmpty || isDayOff {
            classesToggle
        }
        summary
        if isPast || (isToday && !daySummary.isEmpty) {
            Text(daySummary.sentence)
                .font(.subheadline)
                .foregroundStyle(.mist)
                .padding(.horizontal, 4)
                .accessibilityLabel("Day summary: \(daySummary.sentence)")
        }
    }

    /// Sessions at the same time that you haven't chosen between: your electives, as printed.
    private var openClashes: [[String]] {
        let settled = TimetableService.settledClashKeys(from: settledClashes)
        return TimetableClashes.groups(in: timetableEntries.map(TimetableService.slot))
            .filter { !settled.contains(TimetableClashes.key($0)) }
    }


    @ViewBuilder
    private var monthView: some View {
        // Every day's dots worked out in one pass, not the whole schedule rebuilt for each of the
        // forty-odd days on the grid, which is what made switching to Month stutter.
        let marks = monthMarks()
        MonthCalendar(month: $month, selected: $day) { date in
            marks[Calendar.current.startOfDay(for: date)] ?? []
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

    /// How the day added up, in equal columns across the whole tile: four across while each
    /// label fits on one line, two by two when the text is too large for that. A label that
    /// wraps drops its number below the others', and figures bunched to the left leave half the
    /// tile empty.
    private var summary: some View {
        ContentTile {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    column(travelledMetric.fixedSize())
                    column(eventsMetric.fixedSize())
                    column(tasksMetric.fixedSize())
                    column(savedMetric.fixedSize())
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                    GridRow {
                        column(travelledMetric)
                        column(eventsMetric)
                    }
                    GridRow {
                        column(tasksMetric)
                        column(savedMetric)
                    }
                }
            }
        }
    }

    /// An equal share of the width, the figure at its left edge.
    private func column(_ metric: some View) -> some View {
        metric.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var travelledMetric: some View {
        let distance = dayLog?.distanceMeters ?? 0
        let parts = DayDistance.format(distance).split(separator: " ")
        return MetricView(
            label: "Travelled",
            value: distance > 0 ? String(parts.first ?? "0") : "—",
            unit: distance > 0 && parts.count > 1 ? String(parts[1]) : nil,
            role: .you
        )
    }

    private var eventsMetric: some View {
        MetricView(label: "Events", value: "\(eventsAttended)", role: .world)
    }

    private var tasksMetric: some View {
        MetricView(label: "Tasks done", value: "\(tasksDone)", role: .you)
    }

    private var savedMetric: some View {
        MetricView(label: "Saved here", value: "\(memoriesSaved)", role: .you)
    }

    /// The day's reminders, ticked off here. On today, anything left undone on an earlier day is
    /// here too, rather than lost with the day it was for — and stays here once you tick it, so
    /// it doesn't vanish from under your finger.
    private var checklist: some View {
        let open = dayReminders.filter { !$0.isDone }.count
        return VStack(alignment: .leading, spacing: 10) {
            DeckSectionHeader(title: "To do",
                              trailing: open == 0 ? "All done" : "\(dayReminders.count - open) of \(dayReminders.count) done")
            GroupedRows(dayReminders) { reminder in
                ReminderRow(reminder: reminder, shownOn: day)
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

                // Not when you're already there: pointing at the building you're in helps nobody.
                if let coordinate = next.coordinate, !state.isAt(coordinate, within: LeaveOnTime.arrivalRadius),
                   state.routeIsWorthIt(to: coordinate) {
                    Button {
                        state.showWays(to: next.placeName ?? next.title, at: coordinate, id: next.id, arriveBy: next.start)
                    } label: {
                        Label("Take me there", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .pathPrimaryAction()
                }
                // Finished before its time: say so, and it moves on to what's next.
                if next.isUnderway(now: now), next.isFinishable {
                    Button {
                        withAnimation(PathMotion.control) {
                            state.markDone(next.id, start: next.start, plannedEnd: next.end, on: day, now: now)
                        }
                    } label: {
                        Label("Mark as done", systemImage: "checkmark.circle")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .pathSecondaryAction()
                }
            }
        }
    }

    private func schedule(title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            DeckSectionHeader(title: title, trailing: items.isEmpty ? nil : "\(items.count)")
            if isDayOff {
                EmptyState(symbol: "figure.walk.motion", title: "Day off", message: "You took this day off your weekly schedule. Events still show here.", role: .you)
            } else if items.isEmpty {
                EmptyState(
                    symbol: "calendar",
                    title: isPast ? "Nothing recorded" : "Nothing scheduled",
                    message: isPast
                        ? "No events were saved for this day."
                        : "Add an event, paste a message, or set up your weekly schedule."
                )
            }
            if !items.isEmpty {
                GroupedRows(items) { item in
                    DayItemRow(item: item, now: now, day: day, isMissed: missedToday.contains(item.id),
                               completion: completion(of: item))
                }
            }
        }
    }

    /// Adding to the day, one tap each: four across, or two by two when the text is large.
    private var quickActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { quickActionButtons }
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    addEventButton
                    reminderButton
                }
                HStack(spacing: 8) {
                    timetableButton
                    tripButton
                }
            }
        }
        // Tiles rather than capsules: at this height a capsule turns into a blob.
        .buttonBorderShape(.roundedRectangle(radius: 16))
    }

    @ViewBuilder
    private var quickActionButtons: some View {
        addEventButton
        reminderButton
        timetableButton
        tripButton
    }

    private var reminderButton: some View {
        Button {
            state.reminderSheet = ReminderSheetRequest(editing: nil, day: day)
        } label: {
            QuickActionLabel(title: "Reminder", symbol: "checklist")
        }
        .pathSecondaryAction()
        .accessibilityLabel("Add a reminder")
    }

    private var addEventButton: some View {
        Button {
            state.eventSheet = EventSheetRequest(editing: nil, text: nil, day: day)
        } label: {
            QuickActionLabel(title: "Add event", symbol: "calendar.badge.plus")
        }
        .pathPrimaryAction()
    }

    private var timetableButton: some View {
        Button {
            state.isTimetablePresented = true
        } label: {
            QuickActionLabel(title: "Schedule", symbol: "calendar.day.timeline.left")
        }
        .pathSecondaryAction()
        .accessibilityLabel(timetableEntries.isEmpty ? "Set up your weekly schedule" : "Weekly schedule")
    }

    private var tripButton: some View {
        Button {
            state.isTripsPresented = true
        } label: {
            QuickActionLabel(title: trips.isEmpty ? "Trip" : "Trips", symbol: "suitcase.rolling")
        }
        .pathSecondaryAction()
        .accessibilityLabel(trips.isEmpty ? "Plan a trip" : "Trips")
    }

    private var classesToggle: some View {
        Button {
            state.timetable.setDayOff(day, isOff: !isDayOff)
        } label: {
            OneLineButtonLabel(title: isDayOff ? "Undo day off" : "Take \(isToday ? "today" : "this day") off",
                               symbol: isDayOff ? "arrow.uturn.backward" : "xmark.circle")
        }
        .pathSecondaryAction()
    }

    // MARK: Data

    private var events: [PathEvent] { events(on: day) }
    private var classSessions: [ClassSession] { classSessions(on: day) }
    private var legs: [TripLeg] { legs(on: day) }
    private var items: [DayItem] { items(on: day) }

    private func events(on day: Date) -> [PathEvent] {
        let byID = Dictionary(allEvents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return DayPlan.events(allEvents.map(EventStore.plannedEvent), on: day).compactMap { byID[$0.id] }
    }

    /// Up to three dots for each day on the month's grid, earliest first: everything is prepared
    /// once, then each day only picks out its own.
    private func monthMarks() -> [Date: [SignalRole]] {
        let calendar = Calendar.current
        let planned = allEvents.map(EventStore.plannedEvent)
        let slots = timetableEntries.map(TimetableService.slot)
        let skips = timetableExceptions.map(TimetableService.skip)
        let plannedLegs = trips.flatMap { $0.legs }.map(TripStore.plannedLeg)
        var marks: [Date: [SignalRole]] = [:]
        for date in MonthGrid.days(around: month) {
            let dayStart = calendar.startOfDay(for: date)
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
            var timed: [(start: Date, role: SignalRole)] = []
            timed += DayPlan.events(planned, on: date).map { ($0.start, SignalRole.world) }
            timed += TimetableRoutine.sessions(slots: slots, skips: skips, on: date).map { ($0.start, SignalRole.you) }
            timed += TripPlan.legs(plannedLegs, on: date).map { ($0.departure, SignalRole.you) }
            timed += calendarItems
                .filter { $0.start < dayEnd && ($0.end > dayStart || $0.start >= dayStart) }
                .map { ($0.start, SignalRole.world) }
            marks[dayStart] = timed.sorted { $0.start < $1.start }.prefix(3).map(\.role)
        }
        return marks
    }

    /// The day's sessions, at your Work place.
    private func classSessions(on day: Date) -> [ClassSession] {
        let work = savedPlaces.first { $0.kind == .work }
        return ClassSession.at(
            TimetableRoutine.sessions(
                slots: timetableEntries.map(TimetableService.slot),
                skips: timetableExceptions.map(TimetableService.skip),
                on: day
            ),
            name: work?.name, latitude: work?.latitude, longitude: work?.longitude
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
            eventCount: eventsAttended,
            classCount: sessionsAttended,
            legCount: legs.count,
            memoryCount: memoriesSaved,
            taskCount: tasksDone,
            tripName: tripForDay?.name,
            tripDayNumber: tripForDay?.dayNumber(for: day),
            tripDayCount: tripForDay?.dayCount
        )
    }

    private var nextItem: DayItem? {
        items.filter { $0.end > now && completion(of: $0) == nil }.min { $0.start < $1.start }
    }

    /// When you marked it done, if you did.
    private func completion(of item: DayItem) -> ItemCompletion? {
        dayLog?.completions.first { $0.id == item.id }
    }

    private var dayReminders: [Reminder] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return allReminders
            .filter { reminder in
                if calendar.isDate(reminder.day, inSameDayAs: day) { return true }
                guard isToday else { return false }
                return Checklist.isCarriedOver(day: reminder.day, isDone: reminder.isDone, today: today)
                    || reminder.completedAt.map { calendar.isDate($0, inSameDayAs: today) } == true
            }
            .sorted { Checklist.isBefore(($0.dueAt, $0.isDone, $0.createdAt), ($1.dueAt, $1.isDone, $1.createdAt)) }
    }

    /// Reminders ticked off on this day, whichever day they were for.
    private var tasksDone: Int {
        allReminders.filter { $0.completedAt.map { Calendar.current.isDate($0, inSameDayAs: day) } ?? false }.count
    }

    private var isDayOff: Bool {
        timetableExceptions.contains { $0.entryID == nil && Calendar.current.isDate($0.dayStart, inSameDayAs: day) }
    }


    /// What PathOS saw you miss on this day. Anything it never saw counts as attended.
    private var missedToday: Set<String> {
        Set(dayLog?.missedIDs ?? [])
    }

    /// The day's events, less the ones you were seen to miss.
    private var eventsAttended: Int {
        Attendance.count(events.map { "event:\($0.id.uuidString)" }
                         + calendarItems(on: day).map { "calendar:\($0.id)" }, missed: missedToday)
    }

    private var sessionsAttended: Int {
        Attendance.count(classSessions.map { "class:\($0.id)" }, missed: missedToday)
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
        // Mail swaps its list at once: animated, one day's cards slid out and the next's in, and
        // the text around them bobbed up and down.
        if mode == .mail {
            day = next
        } else {
            withAnimation(PathMotion.control) { day = next }
        }
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
        case .classSession(let session): session.whereText
        case .leg(let leg): "from \(leg.origin)"
        case .calendar(let item): item.location?.split(separator: "\n").first.map(String.init)
        }
    }

    var coordinate: CLLocationCoordinate2D? {
        switch self {
        case .event(let event): event.coordinate
        case .classSession(let session):
            if let latitude = session.latitude, let longitude = session.longitude {
                CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            } else {
                nil
            }
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
        case .classSession: "calendar.day.timeline.left"
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
        return .range(start.formatted(date: .omitted, time: .shortened), end.formatted(date: .omitted, time: .shortened))
    }

    func isUnderway(now: Date) -> Bool { start <= now && end > now }

    /// Something you do and finish — not a journey leg, which PathOS follows itself, and not a
    /// whole day.
    var isFinishable: Bool {
        if case .leg = self { return false }
        return !isAllDay
    }
}

private struct DayItemRow: View {
    let item: DayItem
    let now: Date
    /// The day it's on, so "I was there" is written against the right one.
    let day: Date
    /// PathOS saw you somewhere else while this was on.
    let isMissed: Bool
    /// You said it was done, and when.
    let completion: ItemCompletion?

    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isDone = item.end < now || completion != nil
        let isNow = item.isUnderway(now: now) && completion == nil

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
                // How long it really took, which is the point of saying it's done.
                if let completion {
                    Label(Completion.note(start: item.start, plannedEnd: item.end, doneAt: completion.at),
                          systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.aurora)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            if isNow {
                VStack(alignment: .trailing, spacing: 8) {
                    Text("Now")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.amber)
                    if item.isFinishable {
                        Button {
                            withAnimation(PathMotion.resolve(PathMotion.control, reduceMotion: reduceMotion)) {
                                state.markDone(item.id, start: item.start, plannedEnd: item.end, on: day, now: now)
                            }
                        } label: {
                            Label("Done", systemImage: "checkmark")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 4)
                                .frame(minHeight: 30)
                        }
                        .buttonStyle(.glass)
                        .tint(.aurora)
                        .accessibilityLabel("Mark \(item.title) as done")
                    }
                }
            } else if isMissed {
                // Why the day's count is lower than the list is long.
                Text("Missed")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.mist)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(.rect)
        .onTapGesture {
            switch item {
            case .event(let event): state.eventSheet = EventSheetRequest(editing: event.id, text: nil)
            // That session, on that day: changed for the day or for every week.
            case .classSession(let session): state.editingSession = session
            case .leg: state.isTripsPresented = true
            case .calendar(let item):
                // Apple Calendar owns these; it opens at the event's day.
                if let url = URL(string: "calshow:\(Int(item.start.timeIntervalSinceReferenceDate))") {
                    UIApplication.shared.open(url)
                }
            }
        }
        .contextMenu {
            if let coordinate = item.coordinate, !state.isAt(coordinate, within: LeaveOnTime.arrivalRadius) {
                Button("Take me there", systemImage: "arrow.triangle.turn.up.right.diamond.fill") {
                    state.showWays(to: item.placeName ?? item.title, at: coordinate, id: item.id, arriveBy: item.start)
                }
                if state.pointerIsUseful(to: coordinate) {
                    Button("Point me there", systemImage: "location.north.line.fill") {
                        state.startCompass(to: CompassTarget(id: item.id, name: item.title,
                                                             latitude: coordinate.latitude, longitude: coordinate.longitude))
                    }
                }
            }
            if item.isFinishable, Completion.canFinish(start: item.start, now: now) {
                if completion == nil {
                    Button("Mark as done", systemImage: "checkmark.circle") {
                        state.markDone(item.id, start: item.start, plannedEnd: item.end, on: day, now: now)
                    }
                } else {
                    Button("Not done yet", systemImage: "arrow.uturn.backward") {
                        state.markNotDone(item.id, on: day)
                    }
                }
            }
            // PathOS only ever glimpses where you were, so its guess can always be put right.
            if item.coordinate != nil, item.start < now {
                Button(isMissed ? "I was there" : "I didn't go",
                       systemImage: isMissed ? "checkmark.circle" : "xmark.circle") {
                    state.setAttendance(item.id, attended: isMissed, on: day)
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
                Button("Skip this session today", systemImage: "xmark.circle") {
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
    case mail

    var id: String { rawValue }
    var title: String {
        switch self {
        case .day: "Day"
        case .month: "Month"
        case .mail: "Mail"
        }
    }
}

/// A symbol over a word, so four fit across the deck.
private struct QuickActionLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        VStack(spacing: 4) {
            // Every symbol in the same box, or a tall suitcase pushes "Trip" below the others.
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(height: 24)
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
        }
        .frame(maxWidth: .infinity, minHeight: 52)
    }
}

/// One reminder: a box to tick, the thing, and when — its time, the day it was left undone on,
/// or when you ticked it.
private struct ReminderRow: View {
    let reminder: Reminder
    /// The day the list is showing, so a reminder brought forward can say where it came from.
    let shownOn: Date

    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                Image(systemName: reminder.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(reminder.isDone ? Color.aurora : Color.mist)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(reminder.isDone ? "Done: \(reminder.title)" : "Not done: \(reminder.title)")
            .accessibilityHint(reminder.isDone ? "Marks it not done" : "Marks it done")

            VStack(alignment: .leading, spacing: 3) {
                Text(reminder.title)
                    .font(.headline)
                    .foregroundStyle(reminder.isDone ? .mist : .ice)
                    .strikethrough(reminder.isDone, color: .mist)
                    .lineLimit(2)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(isLate ? .amber : .mist)
                        .lineLimit(1)
                }
                if !reminder.notes.isEmpty, !reminder.isDone {
                    Text(reminder.notes)
                        .font(.subheadline)
                        .foregroundStyle(.mist)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
        .padding(.trailing, 14)
        .padding(.vertical, 6)
        .contentShape(.rect)
        .onTapGesture {
            state.reminderSheet = ReminderSheetRequest(editing: reminder.id)
        }
        .contextMenu {
            Button(reminder.isDone ? "Not done yet" : "Mark as done",
                   systemImage: reminder.isDone ? "arrow.uturn.backward" : "checkmark.circle", action: toggle)
            Button("Edit", systemImage: "pencil") {
                state.reminderSheet = ReminderSheetRequest(editing: reminder.id)
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                state.reminders.delete(reminder)
            }
        }
    }

    private func toggle() {
        withAnimation(PathMotion.resolve(PathMotion.control, reduceMotion: reduceMotion)) {
            state.reminders.setDone(reminder, !reminder.isDone)
        }
        state.haptics.tick()
    }

    /// Past its time and still not done.
    private var isLate: Bool {
        guard !reminder.isDone else { return false }
        if let dueAt = reminder.dueAt { return dueAt < Date() }
        return reminder.day < Calendar.current.startOfDay(for: Date())
    }

    private var detail: String? {
        var parts: [String] = []
        let calendar = Calendar.current
        if let completedAt = reminder.completedAt {
            parts.append("Done at \(completedAt.formatted(date: .omitted, time: .shortened))")
        } else if let dueAt = reminder.dueAt {
            parts.append(dueAt.formatted(date: .omitted, time: .shortened))
        }
        if !calendar.isDate(reminder.day, inSameDayAs: shownOn) {
            parts.append(calendar.isDateInYesterday(reminder.day)
                         ? "From yesterday"
                         : "From \(reminder.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
