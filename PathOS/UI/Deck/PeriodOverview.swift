import SwiftData
import SwiftUI

/// A month or a year of your days, below its calendar: what you went to and what you missed,
/// days off and holidays, tasks done, and how you got about and what it cost. Anything PathOS got
/// wrong is put right here — "I was there", or a holiday that was or wasn't a day off for you.
///
/// One year at a time, never every year together: that grows too long to read.
struct PeriodOverview: View {
    enum Period: Hashable {
        /// Any day of the month, or of the year.
        case month(Date)
        case year(Date)
    }

    let period: Period
    /// Opens one of the year's months in the calendar.
    var openMonth: ((Date) -> Void)?

    @Environment(AppState.self) private var state
    @Query(sort: \Holiday.dayStart) private var holidays: [Holiday]
    @State private var summary = Overview.Summary()
    @State private var months: [Overview.MonthTotal] = []
    @State private var travel: [TravelLog.Stretch] = []
    @State private var showsAllMissed = false
    @State private var isImporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            totals
            if isYear, months.count > 1 {
                monthsSection
            }
            travelSection
            missedSection
            daysOffSection
            holidaySection
            if isYear {
                collegeCalendar
            }
        }
        .task(id: "\(interval.start.timeIntervalSince1970)·\(state.holidays.version)") { refresh() }
        .sheet(isPresented: $isImporting, onDismiss: refresh) {
            HolidayImportSheet()
        }
    }

    // MARK: Sections

    private var totals: some View {
        VStack(alignment: .leading, spacing: 10) {
            DeckSectionHeader(title: name, trailing: isCurrent ? "So far" : nil)
            ContentTile {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                    GridRow {
                        metric(MetricView(label: "Went to", value: "\(summary.attended)",
                                          unit: summary.attendance.map { "· \(Int(($0 * 100).rounded()))%" }, role: .you))
                        metric(MetricView(label: "Missed", value: "\(summary.missed.count)",
                                          role: summary.missed.isEmpty ? nil : .attention))
                        metric(MetricView(label: "Days off", value: "\(summary.daysOff.count)", role: .you))
                    }
                    GridRow {
                        metric(MetricView(label: "Tasks done", value: "\(summary.tasksDone)", role: .you))
                        metric(distanceMetric)
                        metric(MetricView(label: "Spent", value: spent.map { "₹\($0.formatted())" } ?? "—"))
                    }
                }
            }
        }
    }

    private func metric(_ view: some View) -> some View {
        view.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var distanceMetric: some View {
        let parts = DayDistance.format(summary.distanceMeters).split(separator: " ")
        return MetricView(label: "Travelled",
                          value: summary.distanceMeters > 0 ? String(parts.first ?? "0") : "—",
                          unit: summary.distanceMeters > 0 && parts.count > 1 ? String(parts[1]) : nil,
                          role: .you)
    }

    /// The year month by month; a month opens in the calendar above.
    private var monthsSection: some View {
        let spentByMonth = Dictionary(grouping: travel) {
            Calendar.current.dateInterval(of: .month, for: $0.start)?.start ?? $0.start
        }.mapValues { $0.compactMap(\.fare).reduce(0, +) }
        return VStack(alignment: .leading, spacing: 10) {
            DeckSectionHeader(title: "Month by month")
            GroupedRows(months.reversed()) { month in
                Button {
                    openMonth?(month.month)
                } label: {
                    HStack(spacing: 12) {
                        Text(month.month.formatted(.dateTime.month(.wide)))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.ice)
                            .frame(width: 104, alignment: .leading)
                        Text(monthLine(month.summary, spent: spentByMonth[month.month]))
                            .font(.subheadline)
                            .foregroundStyle(.mist)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.mist)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func monthLine(_ summary: Overview.Summary, spent: Double?) -> String {
        [summary.attendance.map { "went to \(Int(($0 * 100).rounded()))%" },
         summary.distanceMeters > 0 ? DayDistance.format(summary.distanceMeters) : nil,
         spent.flatMap { $0 > 0 ? "₹\(Int($0.rounded()).formatted())" : nil }]
            .compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "Nothing kept"
    }

    /// How you got about: walking, by road, the metro — how far, how long, what it cost.
    @ViewBuilder
    private var travelSection: some View {
        let totals = TravelLog.byMode(travel)
        VStack(alignment: .leading, spacing: 10) {
            DeckSectionHeader(title: "How you got about")
            if totals.isEmpty {
                Text("Nothing kept yet. Ways you follow in PathOS are kept leg by leg, and so is travel it notices while it's running, with what each cost.")
                    .font(.subheadline)
                    .foregroundStyle(.mist)
                    .padding(.horizontal, 4)
            } else {
                GroupedRows(totals) { total in
                    TravelModeRow(total: total, isEstimate: travel.contains { $0.mode == total.mode && $0.fareIsEstimate && $0.fare != nil })
                }
                let byProvider = Dictionary(grouping: travel.filter { $0.provider != nil }, by: { $0.provider ?? "" })
                if !byProvider.isEmpty {
                    Text(byProvider.keys.sorted().map { provider in
                        let list = byProvider[provider] ?? []
                        let spent = Int(list.compactMap(\.fare).reduce(0, +).rounded())
                        return "\(provider) ₹\(spent.formatted()) · \(list.count) \(list.count == 1 ? "ride" : "rides")"
                    }.joined(separator: "\n"))
                    .font(.subheadline)
                    .foregroundStyle(.mist)
                    .padding(.horizontal, 4)
                }
                if let learned = state.rideFares {
                    Text("Your last \(learned.rides) rides cost \(Int((learned.factor * 100).rounded()))% of PathOS's estimate for the same distance; ways to get somewhere say so beside their fares.")
                        .font(.footnote)
                        .foregroundStyle(.mist)
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var missedSection: some View {
        if !summary.missed.isEmpty {
            let shown = showsAllMissed ? summary.missed : Array(summary.missed.prefix(5))
            VStack(alignment: .leading, spacing: 10) {
                DeckSectionHeader(title: "Missed", trailing: "\(summary.missed.count)")
                GroupedRows(shown) { missed in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(missed.title)
                                .font(.body)
                                .foregroundStyle(.ice)
                                .lineLimit(2)
                            Text(missed.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                                .font(.subheadline)
                                .foregroundStyle(.mist)
                        }
                        Spacer(minLength: 8)
                        Button("I was there") {
                            state.setAttendance(missed.id, attended: true, on: missed.dayStart)
                            refresh()
                        }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderless)
                        .foregroundStyle(.aurora)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                if summary.missed.count > shown.count || showsAllMissed && summary.missed.count > 5 {
                    Button(showsAllMissed ? "Show fewer" : "Show all \(summary.missed.count)") {
                        withAnimation(PathMotion.control) { showsAllMissed.toggle() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.aurora)
                    .padding(.horizontal, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var daysOffSection: some View {
        if !summary.daysOff.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                DeckSectionHeader(title: "Days off",
                                  trailing: summary.holidaysTaken > 0 ? "\(summary.holidaysTaken) of them holidays" : nil)
                GroupedRows(summary.daysOff) { off in
                    HStack(spacing: 12) {
                        Image(systemName: off.isHoliday ? "calendar.badge.checkmark" : "moon.zzz.fill")
                            .foregroundStyle(off.isHoliday ? .ion : .aurora)
                            .frame(width: 24)
                        Text(off.reason)
                            .foregroundStyle(.ice)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(off.dayStart.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                            .font(.subheadline)
                            .foregroundStyle(.mist)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    /// The period's holidays, each with whether it was — or will be — a day off for you.
    @ViewBuilder
    private var holidaySection: some View {
        let shown = holidays.filter { interval.contains($0.dayStart) }
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                DeckSectionHeader(title: "Holidays", trailing: "\(shown.count)")
                GroupedRows(shown) { holiday in
                    HolidayAnswerRow(holiday: holiday)
                }
            }
        }
    }

    private var collegeCalendar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isImporting = true
            } label: {
                Label("Add your college's calendar", systemImage: "calendar.badge.plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .pathSecondaryAction()
            Text(sourceNote)
                .font(.footnote)
                .foregroundStyle(.mist)
                .padding(.horizontal, 4)
        }
    }

    // MARK: Working it out

    private var isYear: Bool {
        if case .year = period { return true }
        return false
    }

    private var interval: DateInterval {
        let calendar = Calendar.current
        switch period {
        case .month(let day):
            return calendar.dateInterval(of: .month, for: day) ?? DateInterval(start: day, duration: 86_400)
        case .year(let day):
            return calendar.dateInterval(of: .year, for: day) ?? DateInterval(start: day, duration: 86_400)
        }
    }

    private var name: String {
        switch period {
        case .month(let day): day.formatted(.dateTime.month(.wide).year())
        case .year(let day): day.formatted(.dateTime.year())
        }
    }

    private var isCurrent: Bool { interval.contains(Date()) }

    /// What the period's travel cost, in whole rupees, where any of it is known.
    private var spent: Int? {
        let fares = travel.compactMap(\.fare)
        return fares.isEmpty ? nil : Int(fares.reduce(0, +).rounded())
    }

    private var sourceNote: String {
        let official = Holidays.bundled.sources.first.map { "Public holidays: \($0.notification)." } ?? ""
        return "\(official) Next year's list comes with PathOS once the state publishes it, usually in November. A college's own calendar — a photo, a PDF or pasted text — is read on your iPhone, and you check it before anything is saved."
    }

    private func refresh() {
        let days = state.overviewDays(in: interval)
        summary = Overview.summary(of: days, now: Date())
        months = isYear ? Overview.byMonth(days, now: Date()) : []
        travel = state.travel(in: interval)
    }
}

/// One way of getting about, over a day, a month or a year.
private struct TravelModeRow: View {
    let total: TravelLog.ModeTotal
    /// Some of what it cost is PathOS's estimate, not a receipt's.
    let isEstimate: Bool

    var body: some View {
        HStack(spacing: 14) {
            SignalGlyph(symbol: total.mode.symbol, role: .you, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(total.mode.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.ice)
                Text("\(DayDistance.format(total.distanceMeters)) · \(TravelLogSheet.duration(minutes: total.minutes))")
                    .font(.subheadline)
                    .foregroundStyle(.mist)
            }
            Spacer(minLength: 8)
            if total.fare > 0 {
                Text((isEstimate ? "about " : "") + "₹\(Int(total.fare.rounded()).formatted())")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.ice)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

/// One holiday, and whether it was — or will be — a day off for you.
struct HolidayAnswerRow: View {
    let holiday: Holiday

    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: holiday.kind.symbol)
                .foregroundStyle(.ion)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(holiday.name)
                    .foregroundStyle(.ice)
                    .lineLimit(2)
                Text("\(holiday.dayStart.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) · \(holiday.kind.label)")
                    .font(.subheadline)
                    .foregroundStyle(.mist)
            }
            Spacer(minLength: 8)
            Picker("Day off?", selection: Binding(
                get: { holiday.isOff },
                set: { answer in
                    if let answer { state.holidays.answer(holiday, isOff: answer) }
                }
            )) {
                if holiday.isOff == nil {
                    // Still to come, it's asked about in the month before; gone by, it's yours to say.
                    Text(holiday.dayStart >= Calendar.current.startOfDay(for: Date()) ? "Ask me" : "Not said").tag(Bool?.none)
                }
                Text("Day off").tag(Bool?.some(true))
                Text("Not off").tag(Bool?.some(false))
            }
            .labelsHidden()
            .tint(holiday.isOff == true ? .aurora : .mist)
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, 8)
        .contextMenu {
            // Ones you added can be taken away again; the official list stays.
            if holiday.kind == .college || holiday.kind == .own {
                Button("Remove", systemImage: "trash", role: .destructive) {
                    state.holidays.delete(holiday)
                }
            }
        }
    }
}

/// A day's travel, stretch by stretch: when, how, from where to where, how far, how long and what
/// it cost — and the day by mode.
struct TravelLogSheet: View {
    let day: Date
    /// The day's distance as GPS counted it, rides PathOS knew the length of included.
    let recorded: Double

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var stretches: [TravelLog.Stretch] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ContentTile {
                        HStack(alignment: .top, spacing: 12) {
                            column(distance)
                            column(MetricView(label: "On the move", value: Self.duration(minutes: stretches.map(\.minutes).reduce(0, +)),
                                              role: .you))
                            column(MetricView(label: "Spent", value: spentText ?? "—"))
                        }
                    }

                    if stretches.isEmpty {
                        Text("Nothing kept for this day. Ways you follow in PathOS are kept leg by leg, and so is travel it notices while it's running; ride receipts in your Gmail add what they cost.")
                            .font(.subheadline)
                            .foregroundStyle(.mist)
                            .padding(.horizontal, 4)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            DeckSectionHeader(title: "By how you went")
                            GroupedRows(TravelLog.byMode(stretches)) { total in
                                TravelModeRow(total: total,
                                              isEstimate: stretches.contains { $0.mode == total.mode && $0.fareIsEstimate && $0.fare != nil })
                            }
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            DeckSectionHeader(title: "Through the day", trailing: "\(stretches.count)")
                            GroupedRows(stretches) { stretch in
                                StretchRow(stretch: stretch)
                            }
                        }
                    }

                    let other = TravelLog.otherMovement(total: recorded, stretches: stretches)
                    if other >= 100 {
                        Text("Another \(DayDistance.format(other)) was moving about, or travel too broken up to tell how.")
                            .font(.footnote)
                            .foregroundStyle(.mist)
                            .padding(.horizontal, 4)
                    }
                    Text("Fares are PathOS's estimate until a ride's receipt arrives. A metro ride is its token fare. Travel is noticed only while PathOS is running, open or in the background.")
                        .font(.footnote)
                        .foregroundStyle(.mist)
                        .padding(.horizontal, 4)
                }
                .padding(20)
            }
            .background(Color.deepSurface)
            .navigationTitle(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                let start = Calendar.current.startOfDay(for: day)
                stretches = state.travel(in: DateInterval(start: start, end: Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start))
            }
        }
    }

    private func column(_ metric: some View) -> some View {
        metric.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var distance: some View {
        let total = max(recorded, stretches.map(\.distanceMeters).reduce(0, +))
        let parts = DayDistance.format(total).split(separator: " ")
        return MetricView(label: "Travelled", value: total > 0 ? String(parts.first ?? "0") : "—",
                          unit: total > 0 && parts.count > 1 ? String(parts[1]) : nil, role: .you)
    }

    private var spentText: String? {
        let fares = stretches.compactMap(\.fare)
        guard !fares.isEmpty else { return nil }
        let estimated = stretches.contains { $0.fare != nil && $0.fareIsEstimate }
        return (estimated ? "~" : "") + "₹\(Int(fares.reduce(0, +).rounded()).formatted())"
    }

    /// "25 min", "1 h 40 min".
    static func duration(minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }
}

/// One stretch of a day's travel.
private struct StretchRow: View {
    let stretch: TravelLog.Stretch

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            SignalGlyph(symbol: stretch.mode.symbol, role: .you, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.ice)
                    .lineLimit(2)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.mist)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if let fare = stretch.fare, fare > 0 {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("₹\(Int(fare.rounded()).formatted())")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.ice)
                    Text(stretch.provider ?? (stretch.fareIsEstimate ? "estimate" : "fare"))
                        .font(.caption)
                        .foregroundStyle(.mist)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    /// "Auto · Home → Jayadeva Hospital".
    private var title: String {
        let places = [stretch.from, stretch.to].compactMap { $0 }
        return places.count == 2 ? "\(stretch.mode.name) · \(places[0]) → \(places[1])"
            : places.first.map { "\(stretch.mode.name) · \(stretch.to == nil ? "from" : "to") \($0)" } ?? stretch.mode.name
    }

    /// "9:12–9:40 AM · 4.2 km · 28 min".
    private var detail: String {
        let time = (stretch.start..<max(stretch.start, stretch.end)).formatted(.interval.hour().minute())
        let distance = stretch.distanceMeters > 0 ? DayDistance.format(stretch.distanceMeters) : nil
        return [time, distance, TravelLogSheet.duration(minutes: stretch.minutes)].compactMap { $0 }.joined(separator: " · ")
    }
}
