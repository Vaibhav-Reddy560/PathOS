import CoreLocation
import Foundation
import Testing
@testable import PathOS

struct EventDiscoveryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let here = CLLocation(latitude: 12.9716, longitude: 77.5946)

    private func item(_ id: String, inHours hours: Double, lasting: Double = 2, location: String? = nil) -> CalendarItem {
        let start = now.addingTimeInterval(hours * 3_600)
        return CalendarItem(id: id, title: "Event \(id)", start: start, end: start.addingTimeInterval(lasting * 3_600),
                            isAllDay: false, location: location, calendarName: "Bengaluru Tech Meetups")
    }

    @Test func pathOSsOwnEventsArentShownTwice() {
        let items = [item("a", inHours: 2), item("mirrored", inHours: 3), item("b", inHours: 1)]
        let chosen = CalendarEvents.select(items, mirroredIDs: ["mirrored"], now: now)
        #expect(chosen.map(\.id) == ["b", "a"])
    }

    @Test func onlyTheComingWeekCounts() {
        let items = [
            item("over", inHours: -5),                 // finished an hour ago
            item("running", inHours: -1),              // started an hour ago, still on
            item("next week", inHours: 24 * 8),
        ]
        #expect(CalendarEvents.select(items, mirroredIDs: [], now: now).map(\.id) == ["running"])
    }

    @Test func aCalendarEventReadsLikeAnyOther() {
        let meetup = item("m", inHours: 3, location: "Toit, 100 Feet Road\nIndiranagar, Bengaluru")
        let pin = CLLocationCoordinate2D(latitude: 12.9791, longitude: 77.6408)
        let event = CalendarEvents.localEvent(meetup, coordinate: pin, from: here)
        #expect(event.id == "calendar:m")
        #expect(event.subtitle == "Toit, 100 Feet Road · Bengaluru Tech Meetups")
        #expect(event.source == .calendar)
        #expect(event.source.isEvent)
        #expect((event.distanceMeters ?? 0) > 4_000)

        let unplaced = CalendarEvents.localEvent(item("u", inHours: 1), coordinate: nil, from: here)
        #expect(unplaced.latitude == nil)
        #expect(unplaced.subtitle == "Bengaluru Tech Meetups")
    }

    @Test func venuesAreNotEvents() {
        #expect(!LocalEvent.Source.venue.isEvent)
        #expect(LocalEvent.Source.mail.isEvent)
        #expect(LocalEvent.Source.trip.isEvent)
    }
}
