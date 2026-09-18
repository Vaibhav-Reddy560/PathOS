import CoreLocation
import Foundation
import Testing
@testable import PathOS

struct WorldSignalTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let origin = CLLocationCoordinate2D(latitude: 12.9716, longitude: 77.5946)

    private func place(_ id: String, distance: Double, reason: String? = nil) -> RadarItem {
        RadarItem(id: id, title: id, subtitle: "Café", reason: reason, symbol: "cup.and.saucer.fill",
                  latitude: 12.97, longitude: 77.59, distanceMeters: distance, isEvent: false)
    }

    private func event(_ id: String, startsIn seconds: TimeInterval) -> RadarItem {
        RadarItem(id: id, title: id, subtitle: "Show", symbol: "ticket.fill", latitude: 12.97, longitude: 77.59,
                  distanceMeters: 500, start: now.addingTimeInterval(seconds), isEvent: true)
    }

    private func build(radar: [RadarItem] = [], memories: [MemoryInput] = [], places: [SavedPlaceInput] = [],
                       assistant: [PlaceSummary] = [], layers: MapLayers = .all) -> [WorldSignal] {
        WorldSignalBuilder.build(memories: memories, places: places, radar: radar, assistantPlaces: assistant,
                                 origin: origin, layers: layers, now: now)
    }

    @Test func greenIsYoursCyanIsTheWorld() {
        let memory = MemoryInput(id: UUID(), title: "Car", body: "B2", latitude: 12.97, longitude: 77.59, radius: 80)
        let home = SavedPlaceInput(id: UUID(), kind: .home, name: "Home", latitude: 12.98, longitude: 77.6, radius: 120)
        let signals = build(radar: [place("place:a", distance: 100)], memories: [memory], places: [home])

        #expect(signals.first { $0.kind == .memory }?.role == .you)
        #expect(signals.first { $0.kind == .home }?.role == .you)
        #expect(signals.first { $0.kind == .place }?.role == .world)
    }

    @Test func eventsStartingWithinAnHourAskForAttention() {
        let signals = build(radar: [event("soon", startsIn: 30 * 60), event("later", startsIn: 3 * 3600), event("started", startsIn: -60)])
        #expect(signals.first { $0.id == "soon" }?.role == .attention)
        #expect(signals.first { $0.id == "later" }?.role == .world)
        #expect(signals.first { $0.id == "started" }?.role == .world)
    }

    @Test func assistantPlaceAlreadyOnRadarIsHighlightedNotDuplicated() {
        let summary = PlaceSummary(id: "a", name: "A", categoryName: "Café", group: .dining, symbol: "cup.and.saucer.fill",
                                   latitude: 12.97, longitude: 77.59, distanceMeters: 100)
        let signals = build(radar: [place("place:a", distance: 100)], assistant: [summary])
        #expect(signals.filter { $0.id == "place:a" }.count == 1)
        #expect(signals.first?.isHighlighted == true)
    }

    @Test func worldSignalsAreCappedToTheNearest() {
        let radar = (0..<40).map { place("place:\($0)", distance: Double(40 - $0) * 100) }
        let signals = build(radar: radar)
        #expect(signals.count == WorldSignalBuilder.maxWorldSignals)
        #expect(signals.allSatisfy { ($0.distanceMeters ?? 0) <= Double(WorldSignalBuilder.maxWorldSignals) * 100 })
    }

    @Test func highlightedSignalsSurviveTheCap() {
        var radar = (0..<40).map { place("place:\($0)", distance: Double($0) * 100) }
        radar.append(place("place:far-pick", distance: 99_000, reason: "Great filter coffee"))
        #expect(build(radar: radar).contains { $0.id == "place:far-pick" })
    }

    @Test func placesYouAreStandingOnDontBuryYourDot() {
        let signals = build(radar: [place("place:here", distance: 12), place("place:picked", distance: 8, reason: "Best dosa"), place("place:near", distance: 120)])
        #expect(!signals.contains { $0.id == "place:here" })
        #expect(signals.contains { $0.id == "place:picked" })
        #expect(signals.contains { $0.id == "place:near" })
    }

    @Test func hiddenLayersAndUnlocatedItemsAreSkipped() {
        let memory = MemoryInput(id: UUID(), title: "Car", body: "", latitude: 12.97, longitude: 77.59, radius: 80)
        var unlocated = place("place:nowhere", distance: 10)
        unlocated.latitude = nil
        let signals = build(radar: [unlocated, event("show", startsIn: 600)], memories: [memory], layers: [.places])
        #expect(signals.isEmpty)
    }
}
