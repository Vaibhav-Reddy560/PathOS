import MapKit
import Observation

/// Apple Maps' own suggestions as you type: places, addresses and searches ("Coffee · Search
/// nearby"), many more and much sooner than a full search returns. Picking one runs it.
@Observable
final class SearchSuggestions: NSObject {
    nonisolated struct Suggestion: Identifiable, Hashable, Sendable {
        var id: String { "\(title)|\(subtitle)" }
        var title: String
        var subtitle: String
        /// A search rather than one place: "Coffee", "ATMs".
        var isQuery: Bool
    }

    private(set) var suggestions: [Suggestion] = []

    @ObservationIgnored private let completer = MKLocalSearchCompleter()
    /// The completer's own results, to run the one picked.
    @ObservationIgnored private var completions: [String: MKLocalSearchCompletion] = [:]

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address, .query]
    }

    func update(_ text: String, near location: CLLocation?) {
        if let location {
            completer.region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 40_000, longitudinalMeters: 40_000)
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.count < 2 {
            suggestions = []
            completer.cancel()
        } else {
            completer.queryFragment = trimmed
        }
    }

    /// The places a suggestion stands for: one for a place, many for a search.
    func places(for suggestion: Suggestion, near location: CLLocation?) async -> [PlaceSummary] {
        guard let completion = completions[suggestion.id] else { return [] }
        let request = MKLocalSearch.Request(completion: completion)
        if let location {
            request.region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 30_000, longitudinalMeters: 30_000)
        }
        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
        return response.mapItems.map { item in
            PlacesService.summary(of: item, from: location)
        }
    }
}

// MapKit calls the completer's delegate on the main thread, where it was set up.
extension SearchSuggestions: @MainActor MKLocalSearchCompleterDelegate {
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        var byID: [String: MKLocalSearchCompletion] = [:]
        var list: [Suggestion] = []
        for result in completer.results.prefix(15) {
            let suggestion = Suggestion(title: result.title, subtitle: result.subtitle,
                                        isQuery: result.subtitle.isEmpty || result.subtitle.hasPrefix("Search"))
            guard byID[suggestion.id] == nil else { continue }
            byID[suggestion.id] = result
            list.append(suggestion)
        }
        completions = byID
        suggestions = list
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        suggestions = []
    }
}
