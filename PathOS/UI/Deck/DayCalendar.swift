import SwiftUI

/// Day's month at a glance: a grid of dates, each with a dot for each of its first three things,
/// green for your own plans and cyan for events. Choosing a date shows its schedule below.
struct MonthCalendar: View {
    /// Any day of the month on show.
    @Binding var month: Date
    @Binding var selected: Date
    /// The roles of up to three things on a date, for its dots.
    let marks: (Date) -> [SignalRole]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    var body: some View {
        let calendar = Calendar.current
        let days = MonthGrid.days(around: month)

        ContentTile(padding: 14) {
            VStack(spacing: 12) {
                header(calendar: calendar)

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

            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(.headline)
                .foregroundStyle(.ice)
                .frame(maxWidth: .infinity)

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

        return Button {
            withAnimation(PathMotion.resolve(PathMotion.control, reduceMotion: reduceMotion)) {
                selected = day
                if !inMonth { month = MonthGrid.month(0, from: day) }
            }
        } label: {
            VStack(spacing: 4) {
                Text(day.formatted(.dateTime.day()))
                    .font(.subheadline.weight(isToday || isSelected ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(isSelected ? Color.void : isToday ? .aurora : inMonth ? .ice : .mist.opacity(0.5))
                HStack(spacing: 3) {
                    ForEach(Array(dots.enumerated()), id: \.offset) { _, role in
                        Circle()
                            .fill(isSelected ? Color.void : role.color.opacity(inMonth ? 1 : 0.5))
                            .frame(width: 5, height: 5)
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
        .accessibilityValue(count == 0 ? "Nothing planned" : count == 3 ? "3 or more things" : "\(count) \(count == 1 ? "thing" : "things")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func step(_ months: Int) {
        withAnimation(PathMotion.resolve(PathMotion.control, reduceMotion: reduceMotion)) {
            month = MonthGrid.month(months, from: month)
        }
    }
}
