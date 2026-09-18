import CoreLocation
import MapKit
import SwiftUI

/// Heads-up pointer: a single arrow toward the destination, no map.
struct PointerCompassView: View {
    let target: CompassTarget

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var displayAngle: Double = 0
    @State private var pinMessage: String?

    static let alignmentTolerance = 12.0

    var body: some View {
        let here = state.location.location
        let distance = here.map { $0.distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude)) }
        let relative = relativeBearing(from: here)
        let aligned = relative.map { GeoMath.angularDifference($0, 0) < Self.alignmentTolerance } ?? false
        let isPinned = state.pinnedCompassTarget?.id == target.id

        ZStack {
            AmbientBackground()

            VStack(spacing: 28) {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Close")
                    Spacer()
                }

                VStack(spacing: 4) {
                    Text(target.name)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text(aligned ? "You're facing it" : "Turn until the arrow points up")
                        .font(.subheadline)
                        .foregroundStyle(aligned ? .mint : .secondary)
                }

                ZStack {
                    Circle()
                        .strokeBorder(aligned ? Color.mint : Color.white.opacity(0.12), lineWidth: aligned ? 6 : 2)
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 120, weight: .bold))
                        .foregroundStyle(aligned ? .mint : .white)
                        .rotationEffect(.degrees(displayAngle))
                        .opacity(relative == nil ? 0.25 : 1)
                }
                .frame(width: 280, height: 280)
                .glassEffect(.regular, in: .circle)
                .animation(.easeInOut(duration: 0.2), value: aligned)

                if let distance {
                    VStack(spacing: 2) {
                        Text(GeoMath.formatDistance(distance))
                            .font(.system(size: 54, weight: .bold, design: .rounded).monospacedDigit())
                        Text("about \(GeoMath.walkingMinutes(forDistance: distance)) min walk")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView("Finding you…")
                }

                if state.location.headingAccuracy < 0 || state.location.headingAccuracy > 30 {
                    Label("Wave your phone in a figure-8 to calibrate", systemImage: "gyroscope")
                        .font(.footnote)
                        .foregroundStyle(.yellow)
                }

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        Task {
                            if isPinned {
                                await state.unpinCompass()
                                pinMessage = nil
                            } else {
                                let shown = await state.pinCompassToLockScreen()
                                pinMessage = shown ? "Pointer is on your Lock Screen and in StandBy." : "Turn on Live Activities for PathOS in Settings."
                            }
                        }
                    } label: {
                        Label(isPinned ? "Remove from Lock Screen" : "Pin to Lock Screen", systemImage: isPinned ? "pin.slash.fill" : "pin.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)

                    Button {
                        let item = MKMapItem(location: CLLocation(latitude: target.latitude, longitude: target.longitude), address: nil)
                        item.name = target.name
                        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
                    } label: {
                        Label("Walking directions in Maps", systemImage: "map")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)

                    if let pinMessage {
                        Text(pinMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .onAppear {
            state.location.startUpdates()
            state.location.beginHeadingUpdates()
        }
        .onDisappear {
            state.location.endHeadingUpdates()
        }
        .onChange(of: relative) { _, newValue in
            guard let newValue else { return }
            // Take the short way round so the arrow never spins through 360°.
            let current = GeoMath.normalize(displayAngle)
            var delta = newValue - current
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            withAnimation(.easeOut(duration: 0.15)) {
                displayAngle += delta
            }
        }
        .onChange(of: aligned) { _, isAligned in
            if isAligned {
                state.haptics.tick()
            }
        }
    }

    private func relativeBearing(from here: CLLocation?) -> Double? {
        guard let here, let heading = state.location.headingDegrees else { return nil }
        let bearing = GeoMath.bearing(from: here.coordinate, to: target.coordinate)
        return GeoMath.relativeBearing(target: bearing, heading: heading)
    }
}
