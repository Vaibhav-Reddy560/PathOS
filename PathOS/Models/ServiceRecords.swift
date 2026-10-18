import Foundation
import SwiftData

/// A ride you took, from its receipt: what it cost and how far it went.
@Model
final class RideRecord {
    var id: UUID = UUID()
    var serviceRaw: String = ServiceMail.Service.uber.rawValue
    /// When the receipt came, which is about when the ride ended.
    var at: Date = Date()
    var fare: Double?
    var distanceKm: Double?
    var minutes: Int?
    var pickup: String?
    var drop: String?
    var vehicleRaw: String?
    /// The receipt, so it's never counted twice.
    var messageID: String = ""

    init(_ ride: ServiceMail.Ride, at: Date, messageID: String) {
        serviceRaw = ride.service.rawValue
        self.at = at
        fare = ride.fare
        distanceKm = ride.distanceKm
        minutes = ride.minutes
        pickup = ride.pickup
        drop = ride.drop
        vehicleRaw = ride.vehicle?.rawValue
        self.messageID = messageID
    }

    var service: ServiceMail.Service { ServiceMail.Service(rawValue: serviceRaw) ?? .uber }
    var vehicle: DoorToDoor.Mode? { vehicleRaw.flatMap(DoorToDoor.Mode.init(rawValue:)) }

    /// What PathOS would have estimated for the same distance, by the same kind of vehicle, then.
    var estimate: Double? {
        guard let distanceKm, let mode = vehicle ?? (service == .rapido ? .bikeTaxi : nil),
              let rate = RoadFares.rate(mode.rawValue) else { return nil }
        let range = RoadFares.estimate(rate, distanceMeters: distanceKm * 1_000, at: at)
        return Double(range.low + range.high) / 2
    }
}

/// An order on its way to you, as its latest mail has it.
@Model
final class OrderUpdate {
    var id: UUID = UUID()
    var serviceRaw: String = ServiceMail.Service.amazon.rawValue
    var orderID: String?
    var item: String?
    var statusRaw: String = ServiceMail.OrderStatus.placed.rawValue
    var firstSeenAt: Date = Date()
    var updatedAt: Date = Date()
    /// The latest mail about it.
    var messageID: String = ""

    init(_ order: ServiceMail.Order, at: Date, messageID: String) {
        serviceRaw = order.service.rawValue
        orderID = order.orderID
        item = order.item
        statusRaw = order.status.rawValue
        firstSeenAt = at
        updatedAt = at
        self.messageID = messageID
    }

    var service: ServiceMail.Service { ServiceMail.Service(rawValue: serviceRaw) ?? .amazon }
    var status: ServiceMail.OrderStatus { ServiceMail.OrderStatus(rawValue: statusRaw) ?? .placed }

    /// "boAt Rockerz 450", or the service's name when the mail didn't say what it was.
    var title: String { item ?? "\(service.name) order" }

    /// Still coming, and heard about recently: a food order is hours, a parcel a week or two.
    func isActive(now: Date = Date()) -> Bool {
        guard !status.isDone else { return false }
        let patience: TimeInterval = service == .amazon ? 14 * 86_400 : 6 * 3_600
        return now.timeIntervalSince(updatedAt) < patience
    }
}
