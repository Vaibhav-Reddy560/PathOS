import CoreLocation
import Foundation

nonisolated enum GeoMath {
    static let earthRadiusMeters = 6_371_000.0

    static func toRadians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    static func toDegrees(_ radians: Double) -> Double { radians * 180 / .pi }

    /// Initial great-circle bearing from `from` to `to`, in degrees clockwise from true north (0..<360).
    static func bearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = toRadians(from.latitude)
        let lat2 = toRadians(to.latitude)
        let deltaLon = toRadians(to.longitude - from.longitude)
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        return normalize(toDegrees(atan2(y, x)))
    }

    /// Haversine distance in meters.
    static func distance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = toRadians(from.latitude)
        let lat2 = toRadians(to.latitude)
        let deltaLat = lat2 - lat1
        let deltaLon = toRadians(to.longitude - from.longitude)
        let a = sin(deltaLat / 2) * sin(deltaLat / 2)
            + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        return earthRadiusMeters * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Angle to draw the pointer at, given the target bearing and the phone's heading (both true north).
    static func relativeBearing(target: Double, heading: Double) -> Double {
        normalize(target - heading)
    }

    static func normalize(_ degrees: Double) -> Double {
        let remainder = degrees.truncatingRemainder(dividingBy: 360)
        return remainder < 0 ? remainder + 360 : remainder
    }

    /// Smallest angle between two bearings, 0...180.
    static func angularDifference(_ a: Double, _ b: Double) -> Double {
        let difference = normalize(a - b)
        return min(difference, 360 - difference)
    }

    /// Rough walking time: straight-line distance × 1.3 detour factor at 80 m/min.
    static func walkingMinutes(forDistance meters: Double) -> Int {
        max(1, Int((meters * 1.3 / 80).rounded(.up)))
    }

    /// Straight-line radius you can walk in `minutes`; the inverse of `walkingMinutes`.
    static func walkingRadius(minutes: Int) -> Double {
        Double(minutes) * 80 / 1.3
    }

    /// The point `meters` due north of `coordinate`.
    /// A point `metres` away on a bearing, for looking ahead of where someone is.
    static func coordinate(_ coordinate: CLLocationCoordinate2D, metres: Double, bearing: Double) -> CLLocationCoordinate2D {
        let radians = bearing * .pi / 180
        let north = metres * cos(radians), east = metres * sin(radians)
        let latitude = coordinate.latitude + north / 111_320
        let scale = cos(coordinate.latitude * .pi / 180)
        return CLLocationCoordinate2D(
            latitude: latitude,
            longitude: coordinate.longitude + (scale > 0.000_001 ? east / (111_320 * scale) : 0)
        )
    }

    static func coordinate(_ coordinate: CLLocationCoordinate2D, offsetNorthBy meters: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: coordinate.latitude + toDegrees(meters / earthRadiusMeters), longitude: coordinate.longitude)
    }

    static func formatDistance(_ meters: Double) -> String {
        if meters < 1000 {
            return "\(Int((meters / 10).rounded()) * 10) m"
        }
        return String(format: "%.1f km", meters / 1000)
    }
}
