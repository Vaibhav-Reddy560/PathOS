import SwiftUI

/// A change the assistant has drafted: what it is now, what it would become, and your call.
/// Nothing in your schedule moves until you tap Approve.
struct ChangeProposalCard: View {
    let pending: PendingChange

    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                SignalGlyph(symbol: symbol, role: .you, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    InstrumentLabel("Proposed change", role: .you)
                    Text(headline)
                        .font(.headline)
                        .foregroundStyle(.ice)
                        .lineLimit(2)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                if let before {
                    Text(before)
                        .strikethrough(after != nil, color: .mist)
                        .foregroundStyle(.mist)
                }
                if let after {
                    Label(after, systemImage: "arrow.turn.down.right")
                        .foregroundStyle(.ice)
                        .fontWeight(.semibold)
                }
            }
            .font(.subheadline)
            .accessibilityElement(children: .combine)

            if let everyWeek = pending.change.everyWeek {
                Picker("How often", selection: Binding(
                    get: { everyWeek },
                    set: { state.pendingChange?.change = pending.change.withEveryWeek($0) }
                )) {
                    Text("Just \(Self.shortDay(originalDay))").tag(false)
                    Text("Every \(Self.weekday(originalDay))").tag(true)
                }
                .pickerStyle(.segmented)
            }

            if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.mist)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await state.approvePendingChange() }
                } label: {
                    // Text only: three equal buttons leave no room for an icon without breaking the word.
                    Text(state.isApplyingChange ? "Updating…" : "Approve")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .pathPrimaryAction()
                .disabled(state.isApplyingChange)

                Button {
                    state.editPendingChange()
                } label: {
                    Text("Edit")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .pathSecondaryAction()

                Button {
                    state.pendingChange = nil
                } label: {
                    Text("Cancel")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .pathSecondaryAction()
            }
        }
        .padding(14)
        .background(Color.elevatedSurface.opacity(0.72), in: .rect(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.aurora.opacity(0.25), lineWidth: 1)
        }
    }

    // MARK: Wording

    private var headline: String {
        switch pending.change {
        case .moveClass(_, let subject, _, _, _, _), .moveEvent(_, let subject, _, _), .moveLeg(_, let subject, _, _): "Move \(subject)"
        case .cancelClass(_, let subject, _, _), .cancelEvent(_, let subject, _): "Cancel \(subject)"
        case .cancelLeg(_, let title, _): "Remove \(title)"
        case .dayOff: "No classes"
        case .classesOn: "Classes back on"
        case .renameEvent: "Rename event"
        case .addEvent(let title, _, _): "Add \(title)"
        }
    }

    private var symbol: String {
        switch pending.change {
        case .moveClass, .moveEvent, .moveLeg: "calendar.badge.clock"
        case .cancelClass, .cancelEvent, .cancelLeg, .dayOff: "calendar.badge.minus"
        case .classesOn, .addEvent: "calendar.badge.plus"
        case .renameEvent: "pencil"
        }
    }

    private var before: String? {
        switch pending.change {
        case let .moveClass(_, _, _, from, _, everyWeek):
            everyWeek ? Self.weekly(from) : Self.interval(from)
        case .cancelClass(_, _, let at, _), .cancelEvent(_, _, let at):
            Self.interval(at)
        case .moveEvent(_, _, let from, _):
            Self.interval(from)
        case .moveLeg(_, _, let from, _), .cancelLeg(_, _, let from):
            Self.moment(from)
        case .renameEvent(_, let old, _):
            old
        case .dayOff, .classesOn, .addEvent:
            nil
        }
    }

    private var after: String? {
        switch pending.change {
        case let .moveClass(_, _, _, _, to, everyWeek):
            everyWeek ? Self.weekly(to) : Self.interval(to)
        case .moveEvent(_, _, _, let to):
            Self.interval(to)
        case .moveLeg(_, _, _, let to):
            Self.moment(to)
        case .renameEvent(_, _, let new):
            new
        case .dayOff(let day), .classesOn(let day):
            day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        case let .addEvent(_, at, place):
            [Self.interval(at), place].compactMap { $0 }.joined(separator: " · ")
        case .cancelClass, .cancelEvent, .cancelLeg:
            nil
        }
    }

    private var note: String? {
        switch pending.change {
        case .cancelClass(_, _, _, let everyWeek):
            everyWeek ? "It comes off your timetable. You can turn it back on from the Timetable sheet." : "Just this once. Every other week stays as it is."
        case .dayOff:
            "Your timetable is skipped that day. Events and trips stay."
        case .cancelEvent:
            "It's removed from PathOS and from your Calendar."
        case let .moveClass(_, _, _, from, to, everyWeek):
            !everyWeek && !Calendar.current.isDate(from.start, inSameDayAs: to.start)
                ? "That day's class is cancelled and a one-off class is added on the new day."
                : nil
        default:
            nil
        }
    }

    private var originalDay: Date {
        switch pending.change {
        case .moveClass(_, _, _, let from, _, _): from.start
        case .cancelClass(_, _, let at, _): at.start
        default: Date()
        }
    }

    // MARK: Formatting

    private static func interval(_ interval: DateInterval) -> String {
        let day = interval.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        let start = interval.start.formatted(date: .omitted, time: .shortened)
        guard interval.end > interval.start else { return "\(day), \(start)" }
        return "\(day), \(start)–\(interval.end.formatted(date: .omitted, time: .shortened))"
    }

    private static func weekly(_ interval: DateInterval) -> String {
        "\(weekday(interval.start))s, \(interval.start.formatted(date: .omitted, time: .shortened))–\(interval.end.formatted(date: .omitted, time: .shortened))"
    }

    private static func moment(_ date: Date) -> String {
        "\(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))), \(date.formatted(date: .omitted, time: .shortened))"
    }

    private static func weekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide))
    }

    private static func shortDay(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "today" }
        if Calendar.current.isDateInTomorrow(date) { return "tomorrow" }
        return date.formatted(.dateTime.weekday(.abbreviated).day())
    }
}
