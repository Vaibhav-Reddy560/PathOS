import CoreLocation
import Foundation
import Testing
@testable import PathOS

struct BusNetworkTests {
    /// Three stops along a road, the first on both sides of it, and two routes.
    private let fixture = """
    {"generated":"2026-09-18",
     "source":{"what":"test","url":"","licence":"ODbL","caveat":"test"},
     "stops":[["Domlur","Majestic",12.9610,77.6387],["Domlur","Kadugodi",12.9612,77.6390],
              ["Indiranagar 100 Feet Road","Majestic",12.9719,77.6412],["Trinity Circle","Majestic",12.9730,77.6170]],
     "routes":[["333G","Kadugodi ⇔ Majestic"],["201","Domlur ⇔ Trinity"]],
     "patterns":[
       {"r":0,"h":"Majestic","s":[0,2,3],"d":[6,9],"n":60,"f":360,"l":1320,"hp":8,"ho":15},
       {"r":1,"h":"Trinity","s":[0,3],"d":[20],"n":3,"f":480,"l":1080,"hp":null,"ho":null},
       {"r":0,"h":"Kadugodi","s":[3,2,1],"d":[9,6],"n":60,"f":360,"l":1320,"hp":8,"ho":15}
     ]}
    """

    private var network: BusNetwork { try! BusNetwork(json: Data(fixture.utf8)) }
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: hour, minute: minute))!
    }

    @Test func nearbyStopsComeNearestFirst() {
        let here = CLLocationCoordinate2D(latitude: 12.9611, longitude: 77.6388)
        let nearby = network.nearbyStops(to: here, within: 500)
        #expect(nearby.map(\.stop.name) == ["Domlur", "Domlur"])
        #expect(nearby.first!.distance < nearby.last!.distance)
        #expect(network.nearbyStops(to: here, within: 2_000).count == 3)
    }

    @Test func aStopListsWhatLeavesFromIt() {
        let services = network.services(at: 0, at: at(9), calendar: calendar)
        #expect(services.map(\.pattern.route.number) == ["201", "333G"])
        // Peak hour: every 8 minutes; a route with three buses a day has no frequency to give.
        #expect(services.first { $0.pattern.route.number == "333G" }?.everyMinutes == 8)
        #expect(services.first { $0.pattern.route.number == "201" }?.everyMinutes == nil)
        #expect(BusNetwork.describe(services.first { $0.pattern.route.number == "201" }!) == "3 buses a day")
        // A route that ends here doesn't leave from here.
        #expect(network.services(at: 1, at: at(9), calendar: calendar).isEmpty)
    }

    @Test func servicesOutsideTheirHoursSaySo() {
        let early = network.services(at: 0, at: at(5), calendar: calendar)
        #expect(early.allSatisfy { !$0.isRunningNow })
        #expect(BusNetwork.describe(early.first { $0.pattern.route.number == "333G" }!).hasPrefix("Not running now"))
        // The first bus reaches the second stop six minutes after it leaves the first.
        let second = network.services(at: 2, at: at(12), calendar: calendar).first!
        #expect(second.firstAtStop == 366)
        #expect(second.everyMinutes == 15)
    }

    @Test func directBusesRunTheRightWay() {
        let options = network.directOptions(from: "Domlur", to: "Trinity Circle", at: at(9), calendar: calendar)
        #expect(options.map(\.service.pattern.route.number) == ["333G", "201"])
        #expect(options[0].stopsCount == 2)
        #expect(options[0].rideMinutes == 15)
        #expect(options[0].fromStop.towards == "Majestic")
        // Nothing goes back towards Domlur from the 100 Feet Road stop on the Majestic side.
        #expect(network.directOptions(from: "Trinity Circle", to: "Domlur", at: at(9), calendar: calendar).map(\.toStop.towards) == ["Kadugodi"])
        #expect(network.directOptions(from: "Domlur", to: "Nowhere").isEmpty)
    }

    @Test func aBusJourneyAddsTheWaitOnce() {
        let option = network.directOptions(from: "Domlur", to: "Trinity Circle", at: at(9), calendar: calendar)[0]
        let journey = Journey.bus(option, network: network)
        #expect(journey.kind == .bus)
        #expect(journey.lineName == "Bus 333G")
        #expect(journey.stops.map(\.name) == ["Domlur", "Indiranagar 100 Feet Road", "Trinity Circle"])
        // Half of an 8-minute wait, then the scheduled 6 and 9 minutes.
        #expect(journey.stops.map(\.minutesFromStart) == [0, 10, 19])
    }

    @Test func stopSearchPutsPrefixesFirst() {
        #expect(network.stopNames(matching: "tri") == ["Trinity Circle"])
        #expect(network.stopNames(matching: "d") == ["Domlur", "Indiranagar 100 Feet Road"])
        #expect(network.stopNames(matching: "  ").isEmpty)
    }

    @Test func theBundledNetworkLoads() async {
        let bundled = await BusNetwork.load()
        #expect((bundled?.stops.count ?? 0) > 5_000)
        #expect((bundled?.patterns.count ?? 0) > 2_000)
        #expect(bundled?.source.licence.contains("ODbL") == true)
    }
}
