import CoreLocation
import Foundation
import Observation
import SwiftData

nonisolated struct LocalEvent: Identifiable, Hashable, Sendable {
    nonisolated enum Source: String, Sendable {
        case venue
        case scanned
    }

    var id: String
    var title: String
    var subtitle: String
    var start: Date?
    var latitude: Double?
    var longitude: Double?
    var distanceMeters: Double?
    var source: Source
    var symbol: String
}

/// Pluggable so a paid/third-party events feed can be added later without UI changes.
protocol EventSource {
    func events(near location: CLLocation) async -> [LocalEvent]
}

/// Entertainment venues from Apple Maps (India has no free public events API).
final class VenueEventSource: EventSource {
    private let places: PlacesService

    init(places: PlacesService) {
        self.places = places
    }

    func events(near location: CLLocation) async -> [LocalEvent] {
        let venues = (try? await places.browse(.culture, near: location, radius: 5_000)) ?? []
        return venues.prefix(12).map { venue in
            LocalEvent(
                id: "venue:\(venue.id)",
                title: venue.name,
                subtitle: "\(venue.categoryName) · check today's shows",
                start: nil,
                latitude: venue.latitude,
                longitude: venue.longitude,
                distanceMeters: venue.distanceMeters,
                source: .venue,
                symbol: venue.symbol
            )
        }
    }
}

/// Upcoming events captured from posters with Snap-to-Action.
final class ScannedEventSource: EventSource {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func events(near location: CLLocation) async -> [LocalEvent] {
        let eventKind = ScanKind.event.rawValue
        let descriptor = FetchDescriptor<ScanRecord>(predicate: #Predicate { $0.kindRaw == eventKind })
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let records = (try? context.fetch(descriptor)) ?? []

        return records
            .filter { ($0.eventStart ?? .distantPast) >= startOfToday }
            .map { record in
                let distance: Double? = if let latitude = record.latitude, let longitude = record.longitude {
                    location.distance(from: CLLocation(latitude: latitude, longitude: longitude))
                } else {
                    nil
                }
                return LocalEvent(
                    id: "scan:\(record.id.uuidString)",
                    title: record.title,
                    subtitle: record.venueName ?? record.summary,
                    start: record.eventStart,
                    latitude: record.latitude,
                    longitude: record.longitude,
                    distanceMeters: distance,
                    source: .scanned,
                    symbol: "ticket.fill"
                )
            }
    }
}

@Observable
final class EventsService {
    private(set) var events: [LocalEvent] = []
    @ObservationIgnored private let sources: [any EventSource]

    init(sources: [any EventSource]) {
        self.sources = sources
    }

    func refresh(near location: CLLocation) async {
        var gathered: [LocalEvent] = []
        for source in sources {
            gathered += await source.events(near: location)
        }
        // Dated (scanned) events soonest first, then venues nearest first.
        events = gathered.sorted { first, second in
            switch (first.start, second.start) {
            case let (a?, b?): return a < b
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return (first.distanceMeters ?? .infinity) < (second.distanceMeters ?? .infinity)
            }
        }
    }
}
