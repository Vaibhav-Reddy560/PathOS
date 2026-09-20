import CoreLocation
import MapKit
import SwiftUI

/// Shown in the deck when a signal on the map is selected: a real place card built from
/// Apple's own record — street imagery, address, phone, website — plus PathOS's actions.
struct SignalDetailView: View {
    let signal: WorldSignal

    @Environment(AppState.self) private var state
    @Environment(PlaceDetailsService.self) private var details
    @State private var isShowingFullDetails = false

    private var mapItem: MKMapItem? { details.item(for: signal.id) }
    private var isApplePlace: Bool { PlaceDetailsService.appleIdentifier(from: signal.id) != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let scene = details.scene(for: signal.id) {
                    LookAroundPreview(initialScene: scene, allowsNavigation: true, showsRoadLabels: true)
                        .frame(height: 170)
                        .clipShape(.rect(cornerRadius: 22, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .strokeBorder(Hairline.style, lineWidth: 1)
                        }
                        .accessibilityLabel("Street view of \(signal.title)")
                }
                if !memoryPhotos.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(Array(memoryPhotos.enumerated()), id: \.offset) { _, data in
                                if let image = UIImage(data: data) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 150, height: 150)
                                        .clipShape(.rect(cornerRadius: 18, style: .continuous))
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .accessibilityLabel("\(memoryPhotos.count) photos of this spot")
                }
                if let note = memoryNote, !note.tags.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(note.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.aurora)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 32)
                                .background(Color.aurora.opacity(0.12), in: .capsule)
                        }
                    }
                }
                metrics
                if let reason = signal.reason {
                    ContentTile {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: "apple.intelligence")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.ion)
                                InstrumentLabel("Why PathOS picked this")
                            }
                            Text(reason)
                                .font(.body)
                                .foregroundStyle(.ice)
                        }
                    }
                }
                if signal.kind == .transitStop {
                    TransitStopDetail(signal: signal)
                }
                placeInfo
                actions
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .deckScroll()
        .task(id: signal.id) {
            await details.load(id: signal.id, coordinate: signal.coordinate, name: signal.title)
        }
        .mapItemDetailSheet(isPresented: $isShowingFullDetails, item: mapItem)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            SignalGlyph(symbol: signal.symbol, role: signal.role, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                InstrumentLabel(category, role: signal.role)
                Text(signal.title)
                    .font(.pathTitle)
                    .foregroundStyle(.ice)
                    .lineLimit(3)
                if !signal.subtitle.isEmpty, signal.subtitle != category {
                    Text(signal.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.mist)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
            Button {
                state.selectedSignalID = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.ice)
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Close")
        }
    }

    private var metrics: some View {
        HStack(spacing: 24) {
            if let distance = signal.distanceMeters {
                let formatted = GeoMath.formatDistance(distance).split(separator: " ")
                MetricView(label: "Distance", value: String(formatted.first ?? ""), unit: formatted.count > 1 ? String(formatted[1]) : nil, role: signal.role)
                MetricView(label: "Walk", value: "\(GeoMath.walkingMinutes(forDistance: distance))", unit: "min", role: signal.role)
            }
            if let start = signal.start {
                MetricView(label: "Starts", value: start.formatted(date: .omitted, time: .shortened), role: signal.role)
            }
            if let radius = signal.radius {
                MetricView(label: "Resurfaces within", value: "\(Int(radius))", unit: "m", role: signal.role)
            }
        }
    }

    /// Address, phone and website, straight from Apple's record.
    @ViewBuilder
    private var placeInfo: some View {
        let address = mapItem?.address?.fullAddress
        let phone = mapItem?.phoneNumber
        let website = mapItem?.url

        if address != nil || phone != nil || website != nil {
            ContentTile(padding: 0) {
                VStack(spacing: 0) {
                    if let address {
                        InfoRow(symbol: "mappin.circle.fill", text: address)
                    }
                    if let phone {
                        if address != nil { RowDivider() }
                        InfoRow(symbol: "phone.fill", text: phone, link: URL(string: "tel:\(phone.filter { !$0.isWhitespace })"))
                    }
                    if let website {
                        if address != nil || phone != nil { RowDivider() }
                        InfoRow(symbol: "safari.fill", text: website.host() ?? website.absoluteString, link: website)
                    }
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                state.selectedSignalID = nil
                state.startCompass(to: CompassTarget(id: signal.id, name: signal.title, latitude: signal.latitude, longitude: signal.longitude))
            } label: {
                Label("Point me there", systemImage: "location.north.line.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .pathPrimaryAction()

            Button {
                state.showWays(to: signal.title,
                               at: CLLocationCoordinate2D(latitude: signal.latitude, longitude: signal.longitude),
                               id: "signal:\(signal.id)", arriveBy: signal.start)
            } label: {
                Label("Ways to get there", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .pathSecondaryAction()

            if let legID {
                let isFollowing = state.trackedLegID == legID
                Button {
                    Task {
                        if isFollowing {
                            await state.stopLegTracking(declined: true)
                        } else {
                            await state.startLegTracking(legID)
                        }
                    }
                } label: {
                    Label(isFollowing ? "Stop tracking this leg" : "Track this leg on the Lock Screen",
                          systemImage: isFollowing ? "stop.circle" : "location.fill.viewfinder")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .pathSecondaryAction()
            }

            if isApplePlace {
                Button {
                    isShowingFullDetails = true
                } label: {
                    Label("Photos, hours & reviews", systemImage: "photo.on.rectangle.angled")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .pathSecondaryAction()
                .disabled(mapItem == nil)
            }

            Button {
                let item = mapItem ?? MKMapItem(location: CLLocation(latitude: signal.latitude, longitude: signal.longitude), address: nil)
                item.name = signal.title
                item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
            } label: {
                Label("Walking directions in Maps", systemImage: "map")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .pathSecondaryAction()

            if signal.kind != .memory && signal.kind != .home && signal.kind != .work {
                HStack(spacing: 8) {
                    ForEach(CabProvider.allCases) { provider in
                        Button {
                            CabLauncher.open(provider, drop: signal.coordinate, pickup: state.location.location?.coordinate)
                        } label: {
                            Label(provider.name, systemImage: provider.symbol)
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 28)
                        }
                        .pathSecondaryAction()
                    }
                }
            }

            if signal.kind == .memory, let note = memoryNote {
                Button(role: .destructive) {
                    state.selectedSignalID = nil
                    Task { await state.vault.delete(note) }
                } label: {
                    Label("Forget this spot", systemImage: "trash")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.glass)
                .foregroundStyle(.coral)
            }
        }
    }

    private var category: String {
        if let poi = mapItem?.pointOfInterestCategory {
            return PlacesService.describe(poi).name
        }
        return signal.kind.spokenName.localizedCapitalized
    }

    private var memoryPhotos: [Data] {
        memoryNote?.allPhotoData ?? []
    }

    /// Set when the signal is a trip leg.
    private var legID: UUID? {
        guard signal.id.hasPrefix("leg:") else { return nil }
        return UUID(uuidString: String(signal.id.dropFirst(4)))
    }

    private var memoryNote: SpatialNote? {
        guard signal.id.hasPrefix("note:"), let id = UUID(uuidString: String(signal.id.dropFirst(5))) else { return nil }
        return state.vault.note(withID: id)
    }
}

private struct InfoRow: View {
    let symbol: String
    let text: String
    var link: URL?

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let link { openURL(link) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(link == nil ? .mist : Color.ion)
                    .frame(width: 24)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.ice)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if link != nil {
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.mist)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(link == nil)
        .accessibilityElement(children: .combine)
    }
}
