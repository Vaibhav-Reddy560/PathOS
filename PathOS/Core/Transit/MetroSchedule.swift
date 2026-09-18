import Foundation

/// Scheduled service: when a line runs and how often. This is what can honestly be known.
///
/// A real-time feed would sit beside this, but neither BMRCL nor BMTC publishes one — BMTC's live
/// bus positions are private to its own app — so PathOS tracks *you* instead of the vehicle.
protocol TransitSchedule {
    func window(forLine lineID: String, on day: Date, calendar: Calendar) -> ServiceWindow?
}

/// A day's service on one line.
nonisolated struct ServiceWindow: Equatable, Sendable {
    var firstDeparture: Date
    var lastDeparture: Date
    /// Minutes between trains, for the hour asked about.
    var headwayMinutes: Int
    /// Bus timings from BMTC's app data are rough; metro timings are published.
    var isApproximate: Bool
}

/// Is the line running, and how often.
nonisolated enum MetroStatus: Equatable, Sendable {
    case running(everyMinutes: Int, lastTrain: Date)
    /// Within half an hour of the last train.
    case closingSoon(lastTrain: Date)
    case closed(firstTrain: Date)
}

nonisolated enum MetroSchedule {
    /// "monday", "weekday" or "sunday": BMRCL starts early on Mondays and late on Sundays.
    static func dayType(for date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.weekday, from: date) {
        case 1: "sunday"
        case 2: "monday"
        default: "weekday"
        }
    }

    /// Peak hours are when trains run closest together, and when smart cards save least.
    static func isPeak(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard calendar.component(.weekday, from: date) != 1 else { return false }
        let minute = minuteOfDay(date, calendar: calendar)
        return MetroNetwork.data.peakHours.windows.contains { window in
            guard window.count == 2, let start = minutes(window[0]), let end = minutes(window[1]) else { return false }
            return minute >= start && minute < end
        }
    }

    static func headway(for line: MetroLine, at date: Date, calendar: Calendar = .current) -> Int {
        isPeak(date, calendar: calendar) ? line.service.headwayPeak : line.service.headwayOffPeak
    }

    static func window(for line: MetroLine, on day: Date, calendar: Calendar = .current) -> ServiceWindow? {
        let start = calendar.startOfDay(for: day)
        guard let first = line.service.firstTrain[dayType(for: day, calendar: calendar)].flatMap(minutes),
              let last = minutes(line.service.lastTrain) else { return nil }
        return ServiceWindow(
            firstDeparture: start.addingTimeInterval(Double(first) * 60),
            lastDeparture: start.addingTimeInterval(Double(last) * 60),
            headwayMinutes: headway(for: line, at: day, calendar: calendar),
            isApproximate: false
        )
    }

    static func status(for line: MetroLine, at now: Date, calendar: Calendar = .current) -> MetroStatus {
        guard let today = window(for: line, on: now, calendar: calendar) else {
            return .closed(firstTrain: now)
        }
        if now < today.firstDeparture {
            return .closed(firstTrain: today.firstDeparture)
        }
        if now > today.lastDeparture {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return .closed(firstTrain: window(for: line, on: tomorrow, calendar: calendar)?.firstDeparture ?? tomorrow)
        }
        if today.lastDeparture.timeIntervalSince(now) <= 30 * 60 {
            return .closingSoon(lastTrain: today.lastDeparture)
        }
        return .running(everyMinutes: headway(for: line, at: now, calendar: calendar), lastTrain: today.lastDeparture)
    }

    /// "Trains every 8 min", "Last train around 11:00 PM", "Closed · first train 5:00 AM".
    static func describe(_ status: MetroStatus) -> String {
        switch status {
        case let .running(every, _): "Trains about every \(every) min"
        case .closingSoon(let last): "Last trains around \(last.formatted(date: .omitted, time: .shortened))"
        case .closed(let first): "Closed · first train \(first.formatted(date: .omitted, time: .shortened))"
        }
    }

    static func minutes(_ text: String) -> Int? {
        ChangePlanner.minutes(from24Hour: text)
    }

    private static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}

/// The metro timetable, through the shared schedule interface.
nonisolated struct MetroTimetable: TransitSchedule {
    func window(forLine lineID: String, on day: Date, calendar: Calendar = .current) -> ServiceWindow? {
        MetroNetwork.line(id: lineID).flatMap { MetroSchedule.window(for: $0, on: day, calendar: calendar) }
    }
}
