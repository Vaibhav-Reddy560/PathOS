import SwiftUI

/// Day's month at a glance: a grid of dates, each with a dot for each of its first three things,
/// green for your own plans and cyan for events. Choosing a date shows its schedule below.
struct MonthCalendar: View {
    /// Any day of the month on show.
    @Binding var month: Date
    @Binding var selected: Date
    /// The roles of up to three things on a date, for its dots.
    let marks: (Date) -> [SignalRole]
    /// A holiday on the date, or a note left for it.
    var flags: (Date) -> Flags = { _ in [] }

    struct Flags: OptionSet {
        let rawValue: Int
        static let holiday = Flags(rawValue: 1 << 0)
        static let note = Flags(rawValue: 1 << 1)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The month and year wheels, open: for going straight to any month of any year.
    @State private var isChoosingMonth = false
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    var body: some View {
        let calendar = Calendar.current
        let days = MonthGrid.days(around: month)

        ContentTile(padding: 14) {
            VStack(spacing: 12) {
                header(calendar: calendar)

                if isChoosingMonth {
                    monthChooser(calendar: calendar)
                }

                HStack(spacing: 4) {
                    ForEach(Array(MonthGrid.weekdaySymbols().enumerated()), id: \.offset) { _, symbol in
                        Text(symbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.mist)
                            .frame(maxWidth: .infinity)
                    }
                }
                .accessibilityHidden(true)

                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(days, id: \.self) { day in
                        cell(day, calendar: calendar)
                    }
                }
            }
        }
        // Swiping across the grid turns the month, as in Calendar.
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) * 1.5,
                          abs(value.translation.width) > 50 else { return }
                    step(value.translation.width < 0 ? 1 : -1)
                }
        )
    }

    private func header(calendar: Calendar) -> some View {
        HStack(spacing: 8) {
            Button { step(-1) } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 36)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Previous month")

            // Tapped, it opens wheels for the month and the year.
            Button {
                withAnimation(PathMotion.resolve(PathMotion.control, reduceMotion: reduceMotion)) {
                    isChoosingMonth.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Text(month.formatted(.dateTime.month(.wide).year()))
                        .font(.headline)
                        .foregroundStyle(isChoosingMonth ? .aurora : .ice)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(isChoosingMonth ? .aurora : .mist)
                        .rotationEffect(.degrees(isChoosingMonth ? 180 : 0))
                }
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(.rect)
            }
            .accessibilityLabel("\(month.formatted(.dateTime.month(.wide).year())), choose a month and year")

            if !calendar.isDate(month, equalTo: Date(), toGranularity: .month) {
                Button("Today") {
                    withAnimation(PathMotion.resolve(PathMotion.control, reduceMotion: reduceMotion)) {
                        month = MonthGrid.month(0, from: Date())
                        selected = calendar.startOfDay(for: Date())
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.aurora)
            }

            Button { step(1) } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 36)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Next month")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.ice)
    }

    private func cell(_ day: Date, calendar: Calendar) -> some View {
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let isSelected = calendar.isDate(day, inSameDayAs: selected)
        let isToday = calendar.isDateInToday(day)
        let dots = marks(day)
        let count = dots.count
        let flags = flags(day)

        return Button {
            withAnimation(PathMotion.resolve(PathMotion.control, reduceMotion: reduceMotion)) {
                selected = day
                if !inMonth { month = MonthGrid.month(0, from: day) }
            }
        } label: {
            VStack(spacing: 4) {
                // A holiday's date in Ion, the world's colour: it's the calendar's, not yours.
                Text(day.formatted(.dateTime.day()))
                    .font(.subheadline.weight(isToday || isSelected || flags.contains(.holiday) ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(isSelected ? Color.void : isToday ? .aurora
                                     : flags.contains(.holiday) ? .ion.opacity(inMonth ? 1 : 0.5)
                                     : inMonth ? .ice : .mist.opacity(0.5))
                HStack(spacing: 3) {
                    ForEach(Array(dots.enumerated()), id: \.offset) { _, role in
                        Circle()
                            .fill(isSelected ? Color.void : role.color.opacity(inMonth ? 1 : 0.5))
                            .frame(width: 5, height: 5)
                    }
                    // A note left for the day: a short bar beside its dots.
                    if flags.contains(.note) {
                        Capsule()
                            .fill(isSelected ? Color.void : Color.ice.opacity(inMonth ? 0.8 : 0.4))
                            .frame(width: 8, height: 3)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.aurora)
                } else if isToday {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.aurora.opacity(0.6), lineWidth: 1.5)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
        .accessibilityValue([
            flags.contains(.holiday) ? "Holiday" : nil,
            count == 0 ? "Nothing planned" : count == 3 ? "3 or more things" : "\(count) \(count == 1 ? "thing" : "things")",
            flags.contains(.note) ? "Has a note" : nil,
        ].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// A month and a year, each on its own wheel, as in Calendar.
    private func monthChooser(calendar: Calendar) -> some View {
        let thisYear = calendar.component(.year, from: Date())
        let years = Array((thisYear - 10)...(thisYear + 2))
        return HStack(spacing: 0) {
            Picker("Month", selection: Binding(
                get: { calendar.component(.month, from: month) },
                set: { set(month: $0, year: calendar.component(.year, from: month)) }
            )) {
                ForEach(1...12, id: \.self) { number in
                    Text(calendar.standaloneMonthSymbols[number - 1]).tag(number)
                }
            }
            Picker("Year", selection: Binding(
                get: { calendar.component(.year, from: month) },
                set: { set(month: calendar.component(.month, from: month), year: $0) }
            )) {
                ForEach(years, id: \.self) { year in
                    Text(String(year)).tag(year)
                }
            }
        }
        .pickerStyle(.wheel)
        .frame(height: 140)
        .clipped()
    }

    private func set(month number: Int, year: Int) {
        guard let date = Calendar.current.date(from: DateComponents(year: year, month: number, day: 1)) else { return }
        month = date
    }

    private func step(_ months: Int) {
        withAnimation(PathMotion.resolve(PathMotion.control, reduceMotion: reduceMotion)) {
            month = MonthGrid.month(months, from: month)
        }
    }
}
