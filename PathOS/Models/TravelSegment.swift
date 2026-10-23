import Foundation
import SwiftData

/// A stretch of a day's travel: how, when, how far, from where to where, and what it cost.
@Model
final class TravelSegment {
    var id: UUID = UUID()
    var start: Date = Date()
    var end: Date = Date()
    var modeRaw: String = WayTravelled.walk.rawValue
    var distanceMeters: Double = 0
    var fromName: String?
    var toName: String?
    /// In rupees: PathOS's estimate until a receipt says otherwise.
    var fare: Double?
    var fareIsEstimate: Bool = true
    /// "followed" for a way or ride PathOS led, "noticed" for one seen from movement alone,
    /// "receipt" for a ride a ride app's receipt told of.
    var sourceRaw: String = "followed"
    /// The receipt it is, and the app that sent it: its distance, times and fare are the receipt's.
    var receiptID: UUID?
    var provider: String?

    init(mode: WayTravelled, start: Date, end: Date, distanceMeters: Double, from: String? = nil, to: String? = nil,
         fare: Double? = nil, fareIsEstimate: Bool = true, source: String = "followed") {
        modeRaw = mode.rawValue
        self.start = start
        self.end = end
        self.distanceMeters = distanceMeters
        fromName = from
        toName = to
        self.fare = fare
        self.fareIsEstimate = fareIsEstimate
        sourceRaw = source
    }

    var mode: WayTravelled { WayTravelled(rawValue: modeRaw) ?? .road }

    var stretch: TravelLog.Stretch {
        TravelLog.Stretch(id: id, mode: mode, start: start, end: end, distanceMeters: distanceMeters,
                          from: fromName, to: toName, fare: fare, fareIsEstimate: fareIsEstimate, provider: provider,
                          paid: receiptID.flatMap { receipt in
                              fare.map { TravelLog.Paid(amount: $0, to: provider ?? "Ride app", at: end, paymentID: receipt,
                                                        evidence: .receipt) }
                          },
                          receiptID: receiptID)
    }
}
