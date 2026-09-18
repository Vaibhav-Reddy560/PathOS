import CoreLocation
import Foundation
import SwiftData

/// How you're getting there. Everything from a walk to a ferry, because a trip is
/// usually several of these strung together.
nonisolated enum TravelMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case walk
    case scooter
    case car
    case cab
    case bus
    case metro
    case train
    case flight
    case ferry

    var id: String { rawValue }

    var label: String {
        switch self {
        case .walk: "Walk"
        case .scooter: "Scooter"
        case .car: "Car"
        case .cab: "Cab"
        case .bus: "Bus"
        case .metro: "Metro"
        case .train: "Train"
        case .flight: "Flight"
        case .ferry: "Ferry"
        }
    }

    var symbol: String {
        switch self {
        case .walk: "figure.walk"
        case .scooter: "scooter"
        case .car: "car.fill"
        case .cab: "car.side.fill"
        case .bus: "bus.fill"
        case .metro: "tram.fill"
        case .train: "train.side.front.car"
        case .flight: "airplane"
        case .ferry: "ferry.fill"
        }
    }

    /// Rough speed used only to estimate an arrival when you haven't given one.
    var averageKilometresPerHour: Double {
        switch self {
        case .walk: 4.5
        case .scooter: 25
        case .car, .cab: 22
        case .bus: 18
        case .metro: 32
        case .train: 60
        case .flight: 700
        case .ferry: 35
        }
    }
}

/// A trip: several days, each with its own legs and whatever else you planned.
@Model
final class Trip {
    var id: UUID = UUID()
    var name: String = ""
    var notes: String = ""
    var startDate: Date = Date()
    var endDate: Date = Date()
    @Relationship(deleteRule: .cascade, inverse: \TripLeg.trip) var legs: [TripLeg] = []
    var createdAt: Date = Date()

    init(name: String, startDate: Date, endDate: Date, notes: String = "") {
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
        self.notes = notes
    }

    var dayCount: Int {
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: startDate), to: Calendar.current.startOfDay(for: endDate)).day ?? 0
        return max(1, days + 1)
    }

    func covers(_ day: Date, calendar: Calendar = .current) -> Bool {
        let dayStart = calendar.startOfDay(for: day)
        return dayStart >= calendar.startOfDay(for: startDate) && dayStart <= calendar.startOfDay(for: endDate)
    }

    /// "Day 2 of 5" for a date inside the trip.
    func dayNumber(for day: Date, calendar: Calendar = .current) -> Int? {
        guard covers(day, calendar: calendar) else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: startDate), to: calendar.startOfDay(for: day)).day ?? 0
        return days + 1
    }
}

/// One hop: a mode, a start and an end, and when it happens.
@Model
final class TripLeg {
    var id: UUID = UUID()
    var modeRaw: String = TravelMode.train.rawValue
    var origin: String = ""
    var destination: String = ""
    var departure: Date = Date()
    var arrival: Date?
    var notes: String = ""
    var originLatitude: Double?
    var originLongitude: Double?
    var destinationLatitude: Double?
    var destinationLongitude: Double?
    var trip: Trip?

    init(mode: TravelMode, origin: String, destination: String, departure: Date, arrival: Date? = nil, notes: String = "") {
        modeRaw = mode.rawValue
        self.origin = origin
        self.destination = destination
        self.departure = departure
        self.arrival = arrival
        self.notes = notes
    }

    var mode: TravelMode {
        get { TravelMode(rawValue: modeRaw) ?? .train }
        set { modeRaw = newValue.rawValue }
    }

    var originCoordinate: CLLocationCoordinate2D? {
        guard let originLatitude, let originLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: originLatitude, longitude: originLongitude)
    }

    var destinationCoordinate: CLLocationCoordinate2D? {
        guard let destinationLatitude, let destinationLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: destinationLatitude, longitude: destinationLongitude)
    }

    var notificationID: String { "pathos.leg.\(id.uuidString)" }
}
