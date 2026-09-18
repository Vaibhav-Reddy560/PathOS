import Foundation
import Testing
@testable import PathOS

struct PlaceDetailsTests {
    @Test func appleIdentifiersAreRecognised() {
        #expect(PlaceDetailsService.appleIdentifier(from: "place:I1234ABCD") == "I1234ABCD")
    }

    @Test func venueEventsCarryAppleIdentifiersToo() {
        // VenueEventSource prefixes Apple's id with "venue:"; scanned events use our own UUIDs.
        #expect(PlaceDetailsService.appleIdentifier(from: "venue:I9876ZZZZ") == "I9876ZZZZ")
        #expect(PlaceDetailsService.appleIdentifier(from: "scan:\(UUID().uuidString)") == nil)
    }

    @Test func ourOwnIdsAreNotAppleIdentifiers() {
        // Saved places and memories use UUIDs; Radar falls back to name@lat,lng when Apple has no id.
        #expect(PlaceDetailsService.appleIdentifier(from: "place:\(UUID().uuidString)") == nil)
        #expect(PlaceDetailsService.appleIdentifier(from: "place:Third Wave@12.97,77.59") == nil)
        #expect(PlaceDetailsService.appleIdentifier(from: "note:\(UUID().uuidString)") == nil)
        #expect(PlaceDetailsService.appleIdentifier(from: "scan:abc") == nil)
    }
}
