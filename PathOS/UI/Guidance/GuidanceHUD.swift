import CoreLocation
import MapKit
import SwiftUI

/// Guidance over the map: an Aurora arrow toward the target, the distance, and your walking route.
/// Heads-up dims the map to leave just the arrow.
struct GuidanceHUD: View {
    let target: CompassTarget

    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayAngle: Double = 0

    static let alignmentTolerance = 12.0

    var body: some View {
        let here = state.location.location
        let distance = here.map { $0.distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude)) }
        let relative = relativeBearing(from: here)
        let isAligned = relative.map { GeoMath.angularDifference($0, 0) < Self.alignmentTolerance } ?? false
        let isPinned = state.pinnedCompassTarget?.id == target.id

        VStack(spacing: state.isHeadsUp ? 28 : 16) {
            if state.isHeadsUp {
                ArrowDial(angle: displayAngle, isAligned: isAligned, hasHeading: relative != nil, size: 240)
            }

            HStack(spacing: 18) {
                if !state.isHeadsUp {
                    ArrowDial(angle: displayAngle, isAligned: isAligned, hasHeading: relative != nil, size: 88)
                }
                VStack(alignment: .leading, spacing: 4) {
                    InstrumentLabel(isAligned ? "You're facing it" : "Guiding to", role: isAligned ? .you : nil)
                    Text(target.name)
                        .font(.headline)
                        .foregroundStyle(.ice)
                        .lineLimit(1)
                    if let distance {
                        let parts = GeoMath.formatDistance(distance).split(separator: " ")
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            MetricText(
                                value: parts.first.map(String.init) ?? "",
                                unit: parts.count > 1 ? String(parts[1]) : nil,
                                role: .you,
                                valueFont: .pathDisplay
                            )
                            .contentTransition(.numericText())
                            Text("· \(state.guidanceRoute?.minutes ?? GeoMath.walkingMinutes(forDistance: distance)) min walk")
                                .font(.subheadline)
                                .foregroundStyle(.mist)
                                .lineLimit(1)
                        }
                    } else {
                        Text("Finding you…")
                            .font(.subheadline)
                            .foregroundStyle(.mist)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            if relative == nil {
                Label(CLLocationManager.headingAvailable() ? "Hold your iPhone flat to find your heading" : "This device has no compass; follow the green route",
                      systemImage: "location.north.line")
                    .font(.footnote)
                    .foregroundStyle(.mist)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if state.location.headingAccuracy < 0 || state.location.headingAccuracy > 30 {
                Label("Wave your phone in a figure-8 to calibrate", systemImage: "gyroscope")
                    .font(.footnote)
                    .foregroundStyle(.amber)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    HUDButton(title: state.isHeadsUp ? "Map" : "Heads-up", symbol: state.isHeadsUp ? "map" : "scope") {
                        withAnimation(PathMotion.resolve(PathMotion.control, reduceMotion: reduceMotion)) {
                            state.isHeadsUp.toggle()
                        }
                    }
                    HUDButton(title: isPinned ? "Unpin" : "Pin", symbol: isPinned ? "pin.slash.fill" : "pin.fill") {
                        Task {
                            if isPinned {
                                await state.unpinCompass()
                            } else if await state.pinCompassToLockScreen() {
                                state.showToast("Pointer is on your Lock Screen and in StandBy")
                            } else {
                                state.showToast("Turn on Live Activities for PathOS in Settings", role: .attention, symbol: "exclamationmark.circle.fill")
                            }
                        }
                    }
                    HUDButton(title: "Maps", symbol: "map.fill") {
                        let item = MKMapItem(location: CLLocation(latitude: target.latitude, longitude: target.longitude), address: nil)
                        item.name = target.name
                        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
                    }
                    HUDButton(title: "End", symbol: "xmark") {
                        state.compassTarget = nil
                    }
                }
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 32, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
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
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                displayAngle += delta
            }
        }
        .onChange(of: isAligned) { _, aligned in
            if aligned {
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

private struct ArrowDial: View {
    let angle: Double
    let isAligned: Bool
    let hasHeading: Bool
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.aurora.opacity(isAligned ? 0.14 : 0))
            Circle()
                .strokeBorder(isAligned ? Color.aurora : Color.ice.opacity(0.16), lineWidth: isAligned ? max(3, size / 40) : 1.5)
            Image(systemName: "location.north.fill")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.aurora)
                .rotationEffect(.degrees(angle))
                .opacity(hasHeading ? 1 : 0.3)
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 0.2), value: isAligned)
        .accessibilityElement()
        .accessibilityLabel(isAligned ? "Facing the target" : hasHeading ? "Turn until the arrow points up" : "Heading unavailable")
    }
}

private struct HUDButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.ice)
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16, style: .continuous))
    }
}
