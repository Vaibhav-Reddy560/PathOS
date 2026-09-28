import CoreLocation
import Foundation
import Observation

/// Asks TomTom where the route you're driving is slow. See `RouteTraffic` for why TomTom.
///
/// It needs a key of your own — free, from developer.tomtom.com, 2,500 requests a day with no
/// card, and past that TomTom refuses rather than bills. Kept in the Keychain on this phone.
/// Without one, the route is drawn plain.
@Observable
final class TrafficService {
    /// What went wrong last, when something did: said in Settings.
    private(set) var problem: String?
    private(set) var hasKey: Bool

    @ObservationIgnored private static let account = "tomtom.key"

    init() {
        hasKey = Keychain.load(String.self, account: Self.account) != nil || Self.isFaking
    }

    /// For the simulator harness only: launched with `-fakeTraffic 1`, a moderate stretch and a
    /// stopped one are painted on every route, so the drawing can be checked without a key.
    private static var isFaking: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "fakeTraffic")
        #else
        false
        #endif
    }

    private var key: String? {
        Keychain.load(String.self, account: Self.account)
    }

    /// Keeps a key and tries it at once on a short stretch of Bengaluru road, so a mistyped key
    /// is found out in Settings rather than on the road. Returns what to say about it.
    func save(key raw: String) async -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            forgetKey()
            return "Live traffic is off."
        }
        let trial = [CLLocationCoordinate2D(latitude: 12.9265, longitude: 77.5935),
                     CLLocationCoordinate2D(latitude: 12.9310, longitude: 77.5980)]
        switch await fetch(trial, key: key) {
        case .success:
            Keychain.save(key, account: Self.account)
            hasKey = true
            problem = nil
            return "Working. The route you drive will show its traffic."
        case .failure(let failure):
            return failure.message
        }
    }

    func forgetKey() {
        Keychain.delete(account: Self.account)
        hasKey = false
        problem = nil
    }

    /// The slow stretches of a route, in metres along it; nil when TomTom couldn't be asked.
    func stretches(along route: [CLLocationCoordinate2D]) async -> [RouteTraffic.Stretch]? {
        if Self.isFaking {
            return [RouteTraffic.Stretch(start: 150, end: 450, level: .moderate),
                    RouteTraffic.Stretch(start: 700, end: 1_000, level: .major)]
        }
        guard let key, route.count > 1 else { return nil }
        switch await fetch(route, key: key) {
        case .success(let response):
            problem = nil
            return RouteTraffic.stretches(from: response, on: route)
        case .failure(let failure):
            problem = failure.message
            return nil
        }
    }

    // MARK: Asking

    private enum Failure: Error {
        case badKey
        case limit
        case unreachable

        var message: String {
            switch self {
            case .badKey: "TomTom didn't accept that key. Check it's the whole of it, from developer.tomtom.com."
            case .limit: "Today's 2,500 free TomTom requests are used up. Traffic comes back tomorrow."
            case .unreachable: "Couldn't reach TomTom. Check the connection and try again."
            }
        }
    }

    private func fetch(_ route: [CLLocationCoordinate2D], key: String) async -> Result<RouteTraffic.Response, Failure> {
        guard let request = RouteTraffic.request(for: route, key: key) else { return .failure(.unreachable) }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .failure(.unreachable) }
        switch status {
        case 200:
            guard let decoded = try? JSONDecoder().decode(RouteTraffic.Response.self, from: data) else {
                return .failure(.unreachable)
            }
            return .success(decoded)
        case 401, 403: return .failure(.badKey)
        case 429: return .failure(.limit)
        default: return .failure(.unreachable)
        }
    }
}
