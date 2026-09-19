import CoreLocation
import Foundation
import Observation
import SwiftData

nonisolated struct LocalEvent: Identifiable, Hashable, Sendable {
    nonisolated enum Source: String, Sendable {
        case venue
        case scanned
        case trip
        case calendar
        case mail

        /// Has a time, as opposed to a place you could go.
        var isEvent: Bool { self != .venue }
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
