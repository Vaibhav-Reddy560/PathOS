import SwiftData
import SwiftUI

/// Orders on their way to you, as their latest mail has them: an Amazon parcel shipped, a
/// Swiggy order out for delivery. Gone once delivered.
///
/// Only as current as the mail: each service mails when it chooses, and PathOS checks mail every
/// so often, so a food order's "on the way" can arrive after the food does. It says so.
struct DeliveriesCard: View {
    @Query(sort: \OrderUpdate.updatedAt, order: .reverse) private var orders: [OrderUpdate]

    var body: some View {
        let active = orders.filter { $0.isActive() }
        if !active.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                DeckSectionHeader(title: "On their way", trailing: "\(active.count)")
                ContentTile {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(active) { order in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: order.service.symbol)
                                    .font(.title3)
                                    .foregroundStyle(order.status == .outForDelivery ? .amber : .ion)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(order.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.ice)
                                        .lineLimit(2)
                                    Text("\(order.service.name) · \(order.status.label) · \(order.updatedAt.formatted(.relative(presentation: .named)))")
                                        .font(.caption)
                                        .foregroundStyle(.mist)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                        Text("From the services' mail, as often as PathOS checks it.")
                            .font(.caption2)
                            .foregroundStyle(.mist)
                    }
                }
            }
        }
    }
}
