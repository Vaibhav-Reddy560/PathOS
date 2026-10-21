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

/// Money that left your accounts, as a mail confirmed it: a bank's or a card's alert, a UPI app's
/// receipt, or a shop's own.
@Model
final class PaymentRecord {
    var id: UUID = UUID()
    var at: Date = Date()
    var amount: Double = 0
    var payee: String?
    /// Who said so: "HDFC Bank", "Swiggy".
    var source: String = ""
    var methodRaw: String = PaymentMail.Method.other.rawValue
    var reference: String?
    var account: String?
    /// A shop's own receipt, rather than the bank's word for it.
    var isReceipt: Bool = false
    /// The mail it came from, so it's never counted twice.
    var messageID: String = ""

    init(amount: Double, at: Date, payee: String?, source: String, method: PaymentMail.Method, reference: String? = nil,
         account: String? = nil, isReceipt: Bool = false, messageID: String) {
        self.amount = amount
        self.at = at
        self.payee = payee
        self.source = source
        methodRaw = method.rawValue
        self.reference = reference
        self.account = account
        self.isReceipt = isReceipt
        self.messageID = messageID
    }

    var method: PaymentMail.Method { PaymentMail.Method(rawValue: methodRaw) ?? .other }

    var entry: Spending.Entry {
        // Kept as the bank printed it; read as it's known — "Bangalor" is Namma Metro.
        Spending.Entry(id: id, at: at, amount: amount, payee: PaymentMail.canonicalPayee(payee), source: source, method: method,
                       reference: reference, account: account, isReceipt: isReceipt)
    }
}
