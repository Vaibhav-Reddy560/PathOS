import Foundation

/// How long it takes to get somewhere, by the ways people actually go: a car or a two-wheeler
/// first, then the metro or a bus, and on foot only when it's a walk someone would take.
nonisolated enum TravelTimes {
    nonisolated enum Mode: Hashable, Sendable {
        case car
        case twoWheeler
        case transit
        case walk

        var symbol: String {
            switch self {
            case .car: "car.fill"
            case .twoWheeler: "scooter"
            case .transit: "tram.fill"
            case .walk: "figure.walk"
            }
        }

        /// Follows the minutes: "25 min by car".
        var phrase: String {
            switch self {
            case .car: "by car"
            case .twoWheeler: "on a two-wheeler"
            case .transit: "by metro or bus"
            case .walk: "on foot"
            }
        }
    }

    nonisolated struct Option: Hashable, Sendable {
        var mode: Mode
        var minutes: Int
        /// Worked out rather than routed: Apple Maps has no two-wheeler routes.
        var isEstimate = false
    }

    /// Longer than this on foot and walking isn't a way anyone would go, so it isn't offered.
    static let longestWalk = 25

    /// A two-wheeler threads through traffic a car sits in. Apple Maps doesn't route them, so it's
    /// the car's time, less a fifth: about what two-wheeler routing gives across Indian cities.
    static let twoWheelerShare = 0.8

    static func twoWheelerMinutes(car: Int) -> Int {
        max(1, Int((Double(car) * twoWheelerShare).rounded()))
    }

    /// The ways worth showing, in the order to show them.
    static func options(car: Int?, transit: Int?, walk: Int?) -> [Option] {
        var options: [Option] = []
        if let car {
            options.append(Option(mode: .car, minutes: car))
            options.append(Option(mode: .twoWheeler, minutes: twoWheelerMinutes(car: car), isEstimate: true))
        }
        if let transit {
            options.append(Option(mode: .transit, minutes: transit))
        }
        // Close enough to walk, it's worth knowing; also the only time there is when the roads
        // couldn't be timed.
        if let walk, walk <= longestWalk || options.isEmpty {
            options.append(Option(mode: .walk, minutes: walk))
        }
        return options
    }

    /// The one line for the Lock Screen: by road if the roads were timed.
    static func headline(car: Int?, transit: Int?, walk: Int?) -> Option? {
        let options = options(car: car, transit: transit, walk: walk)
        if let walk = options.first(where: { $0.mode == .walk }), walk.minutes <= 10 { return walk }
        return options.first
    }
}
