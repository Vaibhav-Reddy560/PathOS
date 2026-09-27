import SwiftUI

/// PathOS opening: the mark where iOS's own launch screen left it, a dark city spreading out from
/// behind it, and a route drawing itself across the streets to a pin — the app in miniature.
/// While it waits, a pulse of light runs along the route. "PathOS" sits at the bottom.
///
/// Every stage is a function of the time since it appeared, so nothing can fall out of step.
struct LaunchView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = Date()
    @State private var scene: LaunchScene?
    @State private var map: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        // The reader itself respects the safe area, so it can report the island and home-indicator
        // insets the layout keeps clear of; the content inside is stretched over the whole screen.
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let full = CGSize(width: proxy.size.width + insets.leading + insets.trailing,
                              height: proxy.size.height + insets.top + insets.bottom)
            ZStack {
                if let scene, let map, scene.size == full {
                    TimelineView(.animation(paused: reduceMotion)) { context in
                        // Reduce Motion shows the finished picture: route drawn, pin down, no pulse.
                        LaunchStage(scene: scene, map: map,
                                    t: reduceMotion ? LaunchStage.settled : context.date.timeIntervalSince(appeared),
                                    pulses: !reduceMotion)
                    }
                } else {
                    // The first frame, before the scene is laid out: exactly iOS's launch screen.
                    Image("LaunchMark")
                        .position(x: full.width / 2, y: full.height / 2)
                }
            }
            .frame(width: full.width, height: full.height)
            .offset(x: -insets.leading, y: -insets.top)
            .onAppear { layOut(full, insets: insets) }
            .onChange(of: full) { _, size in layOut(size, insets: insets) }
        }
        .background(Color.void.ignoresSafeArea())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PathOS, loading")
    }

    private func layOut(_ size: CGSize, insets: EdgeInsets) {
        let mark = UIImage(named: "LaunchMark")?.size ?? CGSize(width: 140, height: 115)
        let laidOut = LaunchScene(map: LaunchMapData.bundled, size: size, markSize: mark,
                                  topInset: insets.top, bottomInset: insets.bottom)
        // Thousands of streets are drawn once, into an image; each frame only moves and reveals it.
        map = LaunchMapImage.render(laidOut, scale: displayScale)
        scene = laidOut
        appeared = Date()
    }
}

/// One frame of the opening, at `t` seconds.
private struct LaunchStage: View {
    let scene: LaunchScene
    let map: UIImage
    let t: TimeInterval
    let pulses: Bool

    /// Long enough for every stage to have finished.
    static let settled: TimeInterval = 1.6

    private static let routeStart = 0.2
    private static let routeEnd = 1.0
    private static let pinLands = 1.2
    private static let pulseLength = 1.4
    /// Where the ride is, along the route: the middle of the journey is the part you don't drive.
    private static let ride = 0.34...0.68

    var body: some View {
        ZStack {
            city
            route
            markHalo
            glow
            Image("LaunchMark")
                .position(scene.center)
            Text("PathOS")
                .font(.pathTitle)
                .foregroundStyle(.ice)
                .opacity(ease(t, from: 0.2, over: 0.45))
                .offset(y: 8 * (1 - ease(t, from: 0.2, over: 0.45)))
                .position(scene.nameCenter)
        }
    }

    // MARK: The city and the route

    /// The map, spreading out from behind the mark and settling as it arrives.
    private var city: some View {
        let reveal = ease(t, from: 0, over: 0.8) * hypot(scene.size.width, scene.size.height) * 0.62
        return Image(uiImage: map)
            .resizable()
            .frame(width: scene.size.width, height: scene.size.height)
            .scaleEffect(1.04 - 0.04 * ease(t, from: 0, over: 2.4))
            .mask {
                RadialGradient(stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.8),
                                       .init(color: .clear, location: 1)],
                               center: .center, startRadius: 0, endRadius: max(reveal, 1))
            }
            .position(scene.center)
    }

    /// The route drawing itself, the pulse that runs along it while PathOS starts, and its ends.
    private var route: some View {
        Canvas { context, _ in
            let center = scene.center
            // Drifts with the map, so the route stays on its streets.
            let drift = 1.04 - 0.04 * ease(t, from: 0, over: 2.4)
            context.translateBy(x: center.x, y: center.y)
            context.scaleBy(x: drift, y: drift)
            context.translateBy(x: -center.x, y: -center.y)

            var route = Path()
            route.addLines(scene.route)

            // The route draws itself, dashed like the one in the icon. The middle of a PathOS
            // journey is the part you're carried rather than the part you travel, and it's drawn
            // in the palette's red so the three legs read as three legs.
            let drawn = ease(t, from: Self.routeStart, over: Self.routeEnd - Self.routeStart, curve: .inOut)
            if drawn > 0 {
                let whole = route.trimmedPath(from: 0, to: drawn)
                context.stroke(whole, with: .color(Color.void.opacity(0.9)),
                               style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                context.stroke(whole, with: .color(.aurora),
                               style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [9, 7]))
                if drawn > Self.ride.lowerBound {
                    let ride = route.trimmedPath(from: Self.ride.lowerBound, to: min(drawn, Self.ride.upperBound))
                    context.stroke(ride, with: .color(.coral),
                                   style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [9, 7]))
                }
            }

            // While PathOS finishes starting, light runs along the route: the loader.
            if pulses, t > Self.pinLands {
                let phase = ((t - Self.pinLands) / Self.pulseLength).truncatingRemainder(dividingBy: 1)
                let head = phase * 1.15
                let segment = route.trimmedPath(from: max(0, head - 0.12), to: min(1, head))
                context.stroke(segment, with: .color(Color.aurora.opacity(0.35)),
                               style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                context.stroke(segment, with: .color(.aurora),
                               style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }

            // Where you start: a solid dot in a dark collar.
            let dot = overshoot(t, from: 0.25, over: 0.35)
            if dot > 0 {
                context.fill(circle(at: scene.start, radius: 10 * dot), with: .color(.void))
                context.fill(circle(at: scene.start, radius: 6.5 * dot), with: .color(.aurora))
            }

            // Where you're going: a pin that drops onto the end, then breathes.
            if t > Self.routeEnd - 0.05 {
                let fall = bounce(t, from: Self.routeEnd - 0.05, over: Self.pinLands - Self.routeEnd + 0.05)
                if pulses, t > Self.pinLands {
                    let ring = ((t - Self.pinLands) / Self.pulseLength).truncatingRemainder(dividingBy: 1)
                    context.stroke(circle(at: scene.end, radius: 5 + 22 * ring),
                                   with: .color(Color.amber.opacity(0.45 * (1 - ring))), lineWidth: 1.5)
                }
                let tip = CGPoint(x: scene.end.x, y: scene.end.y - 18 * (1 - fall))
                context.fill(PinShape.path(tip: tip), with: .color(.void))
                context.fill(PinShape.path(tip: tip, inset: 1.5), with: .color(.amber), style: FillStyle(eoFill: true))
            }
        }
    }

    /// Keeps the streets off the mark's edges, so the figure reads cleanly against the city.
    private var markHalo: some View {
        RadialGradient(colors: [Color.void.opacity(0.92), Color.void.opacity(0)],
                       center: .center, startRadius: 0, endRadius: max(scene.markRect.width, scene.markRect.height) * 0.95)
            .frame(width: scene.markRect.width * 2.2, height: scene.markRect.width * 2.2)
            .position(scene.center)
            .allowsHitTesting(false)
    }

    /// A soft Ion light behind the glass, arriving after the hand-over.
    private var glow: some View {
        Image("LaunchMark")
            .renderingMode(.template)
            .foregroundStyle(.ion)
            .blur(radius: 22)
            .opacity(0.28 * ease(t, from: 0.1, over: 0.6))
            .position(scene.center)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
    }

    // MARK: Timing

    private enum Curve { case out, inOut }

    /// 0 before `from`, 1 after `from + over`, eased between.
    private func ease(_ t: TimeInterval, from start: TimeInterval, over duration: TimeInterval, curve: Curve = .out) -> Double {
        let x = min(1, max(0, (t - start) / duration))
        switch curve {
        case .out: return 1 - pow(1 - x, 3)
        case .inOut: return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
        }
    }

    /// Grows past full size and settles back: a marker being set down.
    private func overshoot(_ t: TimeInterval, from start: TimeInterval, over duration: TimeInterval) -> Double {
        let x = min(1, max(0, (t - start) / duration))
        guard x > 0 else { return 0 }
        let c = 1.70158
        return 1 + (c + 1) * pow(x - 1, 3) + c * pow(x - 1, 2)
    }

    /// Falls and bounces once, lightly.
    private func bounce(_ t: TimeInterval, from start: TimeInterval, over duration: TimeInterval) -> Double {
        let x = min(1, max(0, (t - start) / duration))
        if x < 0.7 { return pow(x / 0.7, 2) }
        let y = (x - 0.85) / 0.15
        return 1 - 0.12 * (1 - y * y)
    }

    private func circle(at center: CGPoint, radius: Double) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }
}

/// The map pin from the icon: a round head tapering to a point, with a hole in the head.
private enum PinShape {
    static let headRadius = 11.0
    static let height = 30.0

    static func path(tip: CGPoint, inset: Double = 0) -> Path {
        let r = headRadius - inset
        let head = CGPoint(x: tip.x, y: tip.y - (height - headRadius))
        // Tangents from the tip to the head's circle, so the sides meet the head smoothly.
        let distance = hypot(tip.x - head.x, tip.y - head.y)
        let spread = asin(min(1, r / distance))
        let down = Double.pi / 2
        var path = Path()
        path.move(to: CGPoint(x: tip.x, y: tip.y - inset * 1.4))
        path.addArc(center: head, radius: r,
                    startAngle: .radians(down + (Double.pi / 2 - spread)),
                    endAngle: .radians(down - (Double.pi / 2 - spread)),
                    clockwise: false)
        path.closeSubpath()
        path.addEllipse(in: CGRect(x: head.x - 4.2, y: head.y - 4.2, width: 8.4, height: 8.4))
        return path
    }
}

/// Draws the launch map once, in the app's own colours, the way a dark city map reads: water and
/// parks as quiet areas, side streets fine and faint, main roads wider and brighter.
private enum LaunchMapImage {
    static func render(_ scene: LaunchScene, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: scene.size, format: format).image { renderer in
            let context = renderer.cgContext
            context.setFillColor(UIColor(Color.void).cgColor)
            context.fill(CGRect(origin: .zero, size: scene.size))

            func fill(_ rings: [[CGPoint]], _ color: Color) {
                for ring in rings where ring.count > 2 {
                    context.addLines(between: ring)
                    context.closePath()
                }
                context.setFillColor(UIColor(color).cgColor)
                context.fillPath()
            }
            fill(scene.green, Color.ion.opacity(0.09))
            fill(scene.water, Color.ion.opacity(0.2))

            context.setLineCap(.round)
            context.setLineJoin(.round)
            func stroke(_ lines: [[CGPoint]], _ color: Color, width: CGFloat) {
                for line in lines where line.count > 1 {
                    context.addLines(between: line)
                }
                context.setStrokeColor(UIColor(color).cgColor)
                context.setLineWidth(width)
                context.strokePath()
            }
            stroke(scene.roads[.service] ?? [], Color.ice.opacity(0.04), width: 0.6)
            stroke(scene.roads[.minor] ?? [], Color.ice.opacity(0.085), width: 0.9)
            stroke(scene.roads[.secondary] ?? [], Color.mist.opacity(0.24), width: 1.7)
            stroke(scene.roads[.major] ?? [], Color.mist.opacity(0.34), width: 2.8)

            context.setLineDash(phase: 0, lengths: [3, 3])
            stroke(scene.rail, Color.mist.opacity(0.2), width: 1)
        }
    }
}
