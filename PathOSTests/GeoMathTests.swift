import CoreLocation
import Testing
@testable import PathOS

struct GeoMathTests {
    private func coordinate(_ latitude: Double, _ longitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    @Test func cardinalBearings() {
        #expect(abs(GeoMath.bearing(from: coordinate(0, 0), to: coordinate(0, 1)) - 90) < 0.01)
        #expect(abs(GeoMath.bearing(from: coordinate(0, 0), to: coordinate(1, 0)) - 0) < 0.01)
        #expect(abs(GeoMath.bearing(from: coordinate(0, 0), to: coordinate(-1, 0)) - 180) < 0.01)
    }

    @Test func oneDegreeOfLatitudeIsAbout111km() {
        #expect(abs(GeoMath.distance(from: coordinate(0, 0), to: coordinate(1, 0)) - 111_195) < 50)
    }

    @Test func relativeBearingWrapsAroundNorth() {
        #expect(GeoMath.relativeBearing(target: 10, heading: 350) == 20)
        #expect(GeoMath.angularDifference(350, 10) == 20)
    }

    @Test func distanceFormatting() {
        #expect(GeoMath.formatDistance(87) == "90 m")
        #expect(GeoMath.formatDistance(1234) == "1.2 km")
    }
}
