import SwiftData
import SwiftUI

/// A month or a year of your days, below its calendar: what you went to and what you missed,
/// days off and holidays, tasks done, how far you went and where the money went. A day's own
/// travel, leg by leg, is the day's — not repeated here. Anything PathOS got wrong is put right
/// here — "I was there", or a holiday that was or wasn't a day off for you.
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
    @State private var spending: [Spending.Entry] = []
    @State private var isSpendingShown = false
    @State private var showsAllMissed = false
    @State private var isImporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            totals
            if isYear, months.count > 1 {
                monthsSection
            }
            spendingSection
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
        .sheet(isPresented: $isSpendingShown) {
            SpendingSheet(title: name, entries: spending)
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
                        metric(MetricView(label: "Spent", value: spending.isEmpty ? "—" : "₹\(Int(Spending.total(spending).rounded()).formatted())",
                                          role: .you))
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
        let spentByMonth = Dictionary(grouping: spending) {
            Calendar.current.dateInterval(of: .month, for: $0.at)?.start ?? $0.at
        }.mapValues(Spending.total)
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

    /// Who the money went to, most first; every payment is a tap away.
    @ViewBuilder
    private var spendingSection: some View {
        if !spending.isEmpty {
            let payees = Spending.byPayee(spending)
            VStack(alignment: .leading, spacing: 10) {
                DeckSectionHeader(title: "Where it went", trailing: "\(spending.count) \(spending.count == 1 ? "payment" : "payments")")
                GroupedRows(payees.prefix(6).map { PayeeTotal(payee: $0.payee, amount: $0.amount, count: $0.count) }) { total in
                    HStack(spacing: 12) {
                        Text(total.payee)
                            .foregroundStyle(.ice)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(total.count == 1 ? "" : "\(total.count)×")
                            .font(.subheadline)
                            .foregroundStyle(.mist)
                        Text("₹\(Int(total.amount.rounded()).formatted())")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.ice)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                Button("See every payment") { isSpendingShown = true }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.aurora)
                    .padding(.horizontal, 4)
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

    private var sourceNote: String {
        let official = Holidays.bundled.sources.first.map { "Public holidays: \($0.notification)." } ?? ""
        return "\(official) Next year's list comes with PathOS once the state publishes it, usually in November. A college's own calendar — a photo, a PDF or pasted text — is read on your iPhone, and you check it before anything is saved."
    }

    private func refresh() {
        let days = state.overviewDays(in: interval)
        summary = Overview.summary(of: days, now: Date())
        months = isYear ? Overview.byMonth(days, now: Date()) : []
        spending = state.spending(in: interval)
    }
}

/// One payee's share of a month or a year.
private struct PayeeTotal: Identifiable {
    var payee: String
    var amount: Double
    var count: Int
    var id: String { payee }
}

/// Every payment in a day, a month or a year: when, to whom, how much, and who said so.
struct SpendingSheet: View {
    var title: String
    let entries: [Spending.Entry]
    /// A day's payments read only the time; a month's or a year's, the date as well.
    var showsDates = true

    @Environment(\.dismiss) private var dismiss

    init(title: String, entries: [Spending.Entry]) {
        self.title = title
        self.entries = entries
    }

    init(day: Date, entries: [Spending.Entry]) {
        title = day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        self.entries = entries
        showsDates = false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ContentTile {
                        HStack(alignment: .top, spacing: 12) {
                            MetricView(label: "Spent", value: entries.isEmpty ? "—" : "₹\(Int(Spending.total(entries).rounded()).formatted())",
                                       role: .you)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            MetricView(label: "Payments", value: "\(entries.count)")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if entries.isEmpty {
                        Text("Nothing yet. Payments are read from your Gmail as they arrive: your bank's and cards' alerts, UPI apps' and shops' receipts, ride receipts — and bills you scan.")
                            .font(.subheadline)
                            .foregroundStyle(.mist)
                            .padding(.horizontal, 4)
                    } else {
                        GroupedRows(entries.reversed()) { entry in
                            PaymentRow(entry: entry, showsDate: showsDates)
                        }
                    }
                    Text("A payment your bank tells you about and the shop sends a receipt for is counted once. Banks that only send SMS can't be read: iOS doesn't let apps read messages.")
                        .font(.footnote)
                        .foregroundStyle(.mist)
                        .padding(.horizontal, 4)
                }
                .padding(20)
            }
            .background(Color.deepSurface)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// One payment.
private struct PaymentRow: View {
    let entry: Spending.Entry
    let showsDate: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            SignalGlyph(symbol: symbol, role: .you, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.payee ?? entry.source)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.ice)
                    .lineLimit(2)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.mist)
                    .lineLimit(2)
                if let travel = entry.forTravel {
                    Label("For \(travel)", systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill")
                        .font(.footnote)
                        .foregroundStyle(.aurora)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Text("₹\(entry.amount.formatted(.number.precision(.fractionLength(0...2))))")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.ice)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch entry.method {
        case .upi: "qrcode"
        case .card: "creditcard.fill"
        case .transfer: "building.columns.fill"
        case .wallet: "wallet.pass.fill"
        case .other: entry.isReceipt ? "doc.plaintext.fill" : "indianrupeesign.circle.fill"
        }
    }

    /// "9:12 AM · HDFC Bank · UPI · ••1234".
    private var detail: String {
        let when = showsDate ? entry.at.formatted(.dateTime.day().month(.abbreviated).hour().minute())
            : entry.at.formatted(date: .omitted, time: .shortened)
        let said = entry.payee == nil || entry.payee == entry.source ? nil : entry.source
        return [when, said, entry.isReceipt ? "receipt" : entry.method.label, entry.account.map { "••\($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// A row of the day by how you went: a way of going, or the rest of the day's distance.
private struct ModeRow: Identifiable {
    var total: TravelLog.ModeTotal?
    var metres: Double
    var id: String { total?.mode.rawValue ?? "other" }
}

/// The part of the day's distance no stretch accounts for.
private struct OtherMovementRow: View {
    let metres: Double

    var body: some View {
        HStack(spacing: 14) {
            SignalGlyph(symbol: "point.3.filled.connected.trianglepath.dotted", role: .you, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Moving about")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.ice)
                Text("\(DayDistance.format(metres)) · too broken up to tell how")
                    .font(.subheadline)
                    .foregroundStyle(.mist)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

/// One way of getting about over a day: how far, how long, and what was paid for it.
private struct TravelModeRow: View {
    let total: TravelLog.ModeTotal

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
                Text("₹\(Int(total.fare.rounded()).formatted())")
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
                            // Adding up to the day's distance: what couldn't be told as a walk or a
                            // ride is a line of its own, not a footnote.
                            DeckSectionHeader(title: "By how you went", trailing: DayDistance.format(travelled))
                            GroupedRows(byMode) { row in
                                if let total = row.total {
                                    TravelModeRow(total: total)
                                } else {
                                    OtherMovementRow(metres: row.metres)
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            DeckSectionHeader(title: "Through the day", trailing: "\(stretches.count)")
                            GroupedRows(stretches) { stretch in
                                StretchRow(stretch: stretch)
                            }
                        }
                    }

                    Text("What a ride cost shows once it's paid: a ride app's receipt, which also sets its distance and times; a payment to Namma Metro that day for the ride's fare or at the station; or a UPI payment as an auto ride ended for about its fare. Travel is noticed only while PathOS is running, open or in the background.")
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

    /// The day's distance: what GPS counted, or the stretches' own when they come to more.
    private var travelled: Double {
        max(recorded, stretches.map(\.distanceMeters).reduce(0, +))
    }

    /// Each way of going, and what's left of the day's distance — moving about, or travel too
    /// broken up to tell how — so the rows add up to the total above them.
    private var byMode: [ModeRow] {
        var rows = TravelLog.byMode(stretches).map { ModeRow(total: $0, metres: $0.distanceMeters) }
        let other = TravelLog.otherMovement(total: travelled, stretches: stretches)
        if other >= 50 {
            rows.append(ModeRow(total: nil, metres: other))
        }
        return rows
    }

    private var distance: some View {
        let total = travelled
        let parts = DayDistance.format(total).split(separator: " ")
        return MetricView(label: "Travelled", value: total > 0 ? String(parts.first ?? "0") : "—",
                          unit: total > 0 && parts.count > 1 ? String(parts[1]) : nil, role: .you)
    }

    /// What the day's travel was paid: receipts and the payments found for it, never estimates.
    private var spentText: String? {
        let paid = stretches.filter { !$0.fareIsEstimate }.compactMap(\.fare)
        guard !paid.isEmpty else { return nil }
        return "₹\(Int(paid.reduce(0, +).rounded()).formatted())"
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
                Text(stretch.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.ice)
                    .lineLimit(2)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.mist)
                    .lineLimit(2)
                // What paid for it, and why that payment is believed to be this ride's.
                if let paid = stretch.paid {
                    Label(paidLine(paid), systemImage: "checkmark.seal.fill")
                        .font(.footnote)
                        .foregroundStyle(.aurora)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            // Only what was paid: an estimate isn't what it cost you.
            if let fare = stretch.fare, fare > 0, !stretch.fareIsEstimate {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("₹\(Int(fare.rounded()).formatted())")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.ice)
                    Text("paid")
                        .font(.caption)
                        .foregroundStyle(.aurora)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    /// "Paid Namma Metro at 8:41, for its fare", "Uber's receipt".
    private func paidLine(_ paid: TravelLog.Paid) -> String {
        let time = paid.at.formatted(date: .omitted, time: .shortened)
        switch paid.evidence {
        case .receipt: return "\(paid.to)'s receipt"
        case .fareAndTime: return "Paid \(paid.to) at \(time), for its fare"
        case .time: return stretch.mode == .metro ? "Paid \(paid.to) at \(time), at the station" : "Paid \(paid.to) at \(time), as it ended"
        }
    }

    /// "9:12–9:40 AM · 4.2 km · 28 min".
    private var detail: String {
        let time = (stretch.start..<max(stretch.start, stretch.end)).formatted(.interval.hour().minute())
        let distance = stretch.distanceMeters > 0 ? DayDistance.format(stretch.distanceMeters) : nil
        return [time, distance, TravelLogSheet.duration(minutes: stretch.minutes)].compactMap { $0 }.joined(separator: " · ")
    }
}
