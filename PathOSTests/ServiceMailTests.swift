import Foundation
import Testing
@testable import PathOS

/// Ride receipts, tickets and order updates, read from who sent them and what they say.
struct ServiceMailTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }

    @Test func servicesAreKnownByWhoSentThem() {
        #expect(ServiceMail.service(of: "noreply@uber.com") == .uber)
        #expect(ServiceMail.service(of: "Receipts <noreply@m.uber.com>".components(separatedBy: "<").last!.dropLast().description) == .uber)
        #expect(ServiceMail.service(of: "shipment-tracking@amazon.in") == .amazon)
        #expect(ServiceMail.service(of: "tickets@bookmyshow.com") == .bookMyShow)
        #expect(ServiceMail.service(of: "noreply@swiggy.in") == .swiggy)
        // Not by a name in the address: someone at gmail writing about Uber is not Uber.
        #expect(ServiceMail.service(of: "uber.fan@gmail.com") == nil)
        #expect(ServiceMail.service(of: "news@notuber.com") == nil)
    }

    @Test func aRideReceiptGivesItsFareAndDistance() throws {
        let body = """
        Thanks for riding, Vaibhav
        We hope you enjoyed your ride this evening.
        Total ₹186.42
        Trip fare ₹172.00
        Booking fee ₹14.42
        Uber Auto · 6.31 kilometres | 24 min
        Pickup
        12th Main Rd, HAL 2nd Stage, Indiranagar, Bengaluru
        Drop
        BMS College of Engineering, Bull Temple Rd, Basavanagudi
        """
        let ride = try #require(ServiceMail.ride(.uber, subject: "Your Sunday evening trip with Uber", body: body))
        #expect(ride.fare == 186.42)
        #expect(ride.distanceKm == 6.31)
        #expect(ride.minutes == 24)
        #expect(ride.vehicle == .auto)
        #expect(ride.pickup?.hasPrefix("12th Main Rd") == true)
        #expect(ride.drop?.hasPrefix("BMS College") == true)
    }

    /// A promotion from a ride app is not a ride.
    @Test func anOfferIsNotARide() {
        #expect(ServiceMail.ride(.rapido, subject: "Flat 50% off your next 3 rides!", body: "Use code RIDE50. Rs. 75 off.") == nil)
    }

    @Test func aBookingGivesItsIDSeatsAndShowtime() throws {
        let received = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 12))!
        let body = """
        Your booking is confirmed!
        Booking ID: WBXK7Q2
        Kantara: Chapter 1 (U/A) Kannada, 2D
        PVR: Forum Mall, Koramangala
        Sat, 25 Oct, 2026 | 07:30 PM
        Seats: GOLD - J10, J11
        Total Amount Rs. 640.00
        """
        let ticket = try #require(ServiceMail.ticket(subject: "Your tickets for Kantara: Chapter 1", body: body,
                                                     received: received, calendar: calendar))
        #expect(ticket.bookingID == "WBXK7Q2")
        #expect(ticket.seats == "GOLD - J10, J11")
        #expect(ticket.showtime == calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 19, minute: 30)))
    }

    @Test func ordersMoveThroughTheirStages() {
        let shipped = ServiceMail.order(.amazon, subject: #"Your Amazon.in order of "boAt Rockerz 450" has shipped"#,
                                        body: "Order #407-1234567-7654321\nArriving Thursday")
        #expect(shipped?.status == .shipped)
        #expect(shipped?.orderID == "407-1234567-7654321")
        #expect(shipped?.item == "boAt Rockerz 450")
        #expect(ServiceMail.order(.amazon, subject: "Out for delivery: boAt Rockerz 450", body: "")?.status == .outForDelivery)
        #expect(ServiceMail.order(.amazon, subject: "Delivered: your package", body: "")?.status == .delivered)
        #expect(ServiceMail.order(.swiggy, subject: "Your order is on the way!", body: "Order No: 178234561290")?.orderID == "178234561290")
        #expect(ServiceMail.order(.zomato, subject: "Your Zomato order from Meghana Foods was delivered", body: "")?.status == .delivered)
        #expect(ServiceMail.order(.amazon, subject: "Deals of the day for you", body: "Shop now") == nil)
        #expect(ServiceMail.OrderStatus.delivered > .outForDelivery)
    }

    /// What rides really cost against the estimate: the middle of the last few.
    @Test func theFareFactorIsTheMiddleOfRecentRides() {
        #expect(ServiceMail.fareFactor([(fare: 120, estimate: 100)]) == nil)
        let rides: [(fare: Double, estimate: Double)] = [(100, 80), (150, 100), (300, 100), (100, 100)]
        #expect(ServiceMail.fareFactor(rides) == 1.375)
    }
}
