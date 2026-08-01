import SwiftUI
import HourglassCore

/// The Orbit scene: a planet, an orbital track, and the day traced along it.
///
/// The trace is **ambient, not a chart**. Solid ember arcs are stretches of
/// recorded work, gaps are rests, and the satellite marks now at the top of the
/// visible track with the past running away to the left. Exact times live in
/// textual UI and History; nothing here is meant to be read off to the minute,
/// and there is deliberately no scrubbing or segment selection.
struct OrbitSceneView: View {
    /// Stretches of actual work today, oldest first.
    var worked: [StatisticsCalculator.WorkedStretch]
    var mode: OrbitSceneMode
    var now: Date
    /// How far back the visible track reaches. Widened to cover the day so far.
    var window: TimeInterval
    var crop: Crop
    /// Where the sun sits, used to place the dawn glow. Nil while unknown.
    var isDaylight: Bool

    /// Where the sun is, which decides how much of the visible face is lit and
    /// which longitude is turned toward the viewer.
    private var sun: SunPosition { SunPosition(at: now, isDaylight: isDaylight) }

    enum Crop { case portrait, landscape }

    @Environment(\.orbitPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        GeometryReader { proxy in
            let geometry = Geometry(size: proxy.size, crop: crop)
            ZStack {
                sky
                Canvas { context, size in
                    draw(in: &context, size: size, geometry: geometry)
                }
                satellite(geometry)
            }
        }
        .orbitDecoration()
        .onAppear { pulse = mode.isRecording && !reduceMotion }
        .onChange(of: mode) { _, newMode in
            pulse = newMode.isRecording && !reduceMotion
        }
    }

    // MARK: Layer 1 — sky

    private var sky: some View {
        LinearGradient(
            colors: [palette.sky, palette.skyEdge],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: Layers 2–9, drawn together so they share one geometry pass

    private func draw(in context: inout GraphicsContext, size: CGSize, geometry: Geometry) {
        if palette.isNight { drawStars(&context, size: size) }
        drawPlanet(&context, geometry)
        drawAtmosphere(&context, geometry)
        drawDawnGlow(&context, geometry, size: size)
        drawTrack(&context, geometry)
        drawTrace(&context, geometry)
    }

    // MARK: Layer 2 — stars

    private func drawStars(_ context: inout GraphicsContext, size: CGSize) {
        var context = context
        context.opacity = 0.7
        for star in Self.stars {
            let point = CGPoint(x: star.x * size.width, y: star.y * size.height * 0.72)
            let radius = star.radius
            context.fill(
                Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                       width: radius * 2, height: radius * 2)),
                with: .color(.white.opacity(star.brightness))
            )
        }
    }

    // MARK: Layers 3–4 — planet and surface

    private func drawPlanet(_ context: inout GraphicsContext, _ geometry: Geometry) {
        let rect = CGRect(
            x: geometry.planetCenter.x - geometry.planetRadius,
            y: geometry.planetCenter.y - geometry.planetRadius,
            width: geometry.planetRadius * 2,
            height: geometry.planetRadius * 2
        )
        let body = Path(ellipseIn: rect)

        // Photographic Earth when it has been supplied; the gradient below is
        // the fallback, not the plan.
        if OrbitPlanetTexture.isAvailable {
            drawTexturedPlanet(&context, in: rect, body: body)
            return
        }

        let stops: [Gradient.Stop] = palette.isNight
            ? [.init(color: Color(hex: 0x101B2E), location: 0),
               .init(color: Color(hex: 0x0B1322), location: 0.39),
               .init(color: Color(hex: 0x060A12), location: 1)]
            : [.init(color: Color(hex: 0x5389BB), location: 0),
               .init(color: Color(hex: 0x32618F), location: 0.43),
               .init(color: Color(hex: 0x1E4269), location: 1)]

        context.fill(
            body,
            with: .radialGradient(
                Gradient(stops: stops),
                center: CGPoint(x: geometry.planetCenter.x, y: rect.minY),
                startRadius: 0,
                endRadius: geometry.planetRadius * 1.15
            )
        )

        // Surface detail: a few soft bands just under the limb, so the planet
        // reads as a body rather than a flat disc.
        var detail = context
        detail.addFilter(.blur(radius: geometry.planetRadius * 0.045))
        detail.opacity = palette.isNight ? 0.22 : 0.5
        for band in Self.surfaceBands {
            let width = geometry.planetRadius * band.width
            let height = geometry.planetRadius * band.height
            let origin = CGPoint(
                x: geometry.planetCenter.x + geometry.planetRadius * band.x - width / 2,
                y: rect.minY + geometry.planetRadius * band.y
            )
            detail.fill(
                Path(ellipseIn: CGRect(origin: origin, size: CGSize(width: width, height: height))),
                with: .color(palette.isNight ? palette.atmosphere : .white)
            )
        }
    }

    /// The planet as imagery: the day map, the night map fading in across the
    /// terminator, and a limb shade so the sphere still reads as a sphere.
    ///
    /// The visible planet is a huge disc with only its top sliver on screen, so
    /// this maps a band of the equirectangular map rather than projecting the
    /// whole globe — at this crop the difference is invisible and the cost is a
    /// single draw. The band's horizontal offset follows the time of day, which
    /// is what makes the face turn instead of sitting still.
    private func drawTexturedPlanet(
        _ context: inout GraphicsContext,
        in rect: CGRect,
        body: Path
    ) {
        var context = context
        context.clip(to: body)

        // Three widths of map, scrolled by the day fraction, so the longitude
        // under the viewer advances through the day and wraps without a seam.
        let mapWidth = rect.width * 2.6
        let offset = -CGFloat(sun.dayFraction) * mapWidth
        let mapRect = CGRect(
            x: rect.midX - mapWidth / 2 + offset,
            y: rect.minY,
            width: mapWidth,
            height: rect.height
        )

        if let day = OrbitPlanetTexture.day {
            let resolved = context.resolve(day)
            for repetition in 0...2 {
                context.draw(resolved, in: mapRect.offsetBy(dx: mapWidth * CGFloat(repetition), dy: 0))
            }
        }

        // The unlit side. With a night map it is city lights; without one it is
        // simply darkness, which is still the truthful answer.
        let darkness = 1 - sun.illumination
        if darkness > 0.02 {
            if let night = OrbitPlanetTexture.night {
                var lights = context
                lights.opacity = darkness
                lights.blendMode = .screen
                let resolved = lights.resolve(night)
                for repetition in 0...2 {
                    lights.draw(resolved, in: mapRect.offsetBy(dx: mapWidth * CGFloat(repetition), dy: 0))
                }
            }
            // Nearly opaque at full darkness: the lights are what should be
            // visible on the night side, not the daytime colours underneath.
            context.fill(body, with: .color(.black.opacity(darkness * 0.92)))
        }

        // A limb shade, so the edge falls away instead of ending in a hard cut.
        context.fill(
            body,
            with: .radialGradient(
                Gradient(colors: [.clear, .black.opacity(0.55)]),
                center: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.12),
                startRadius: rect.width * 0.1,
                endRadius: rect.width * 0.62
            )
        )
    }

    // MARK: Layer 5 — atmosphere rim

    private func drawAtmosphere(_ context: inout GraphicsContext, _ geometry: Geometry) {
        let rect = CGRect(
            x: geometry.planetCenter.x - geometry.planetRadius,
            y: geometry.planetCenter.y - geometry.planetRadius,
            width: geometry.planetRadius * 2,
            height: geometry.planetRadius * 2
        )
        let limb = Path(ellipseIn: rect)

        // Two passes: a wide soft halo for the atmosphere, then a tight bright
        // line for the limb itself. One blurred stroke alone reads as haze and
        // leaves no edge, which is what made the planet hard to find.
        var halo = context
        halo.addFilter(.blur(radius: 9))
        halo.stroke(
            limb,
            with: .color(palette.atmosphere.opacity(palette.isNight ? 0.55 : 0.75)),
            lineWidth: 10
        )
        context.stroke(
            limb,
            with: .color(palette.atmosphere.opacity(palette.isNight ? 0.85 : 0.95)),
            lineWidth: 1.5
        )
    }

    // MARK: Layer 6 — dawn glow

    /// A warm bloom on the horizon. Present at night as the memory of the day,
    /// and brighter in daylight. Never interactive, never carrying state.
    private func drawDawnGlow(_ context: inout GraphicsContext, _ geometry: Geometry, size: CGSize) {
        var context = context
        context.addFilter(.blur(radius: size.width * 0.06))
        context.opacity = isDaylight ? 0.42 : 0.24
        let width = size.width * 0.55
        let height = size.height * 0.06
        let rect = CGRect(
            x: geometry.planetCenter.x + size.width * 0.06,
            y: geometry.planetCenter.y - geometry.planetRadius + height * 0.4,
            width: width,
            height: height
        )
        context.fill(Path(ellipseIn: rect), with: .color(palette.dawn))
    }

    // MARK: Layer 7 — dotted track

    private func drawTrack(_ context: inout GraphicsContext, _ geometry: Geometry) {
        context.stroke(
            geometry.arcPath(from: -geometry.visibleHalfAngle, to: geometry.visibleHalfAngle),
            with: .color(palette.inkSecondary.opacity(mode == .inactive ? 0.22 : 0.34)),
            style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1.5, 6])
        )
    }

    // MARK: Layers 8–9 — the day trace

    private func drawTrace(_ context: inout GraphicsContext, _ geometry: Geometry) {
        guard !worked.isEmpty else { return }
        let traceColor = mode == .inactive ? palette.ember.opacity(0.18) : palette.ember

        for (index, stretch) in worked.enumerated() {
            let from = geometry.angle(for: stretch.start, now: now, window: window)
            let to = geometry.angle(for: stretch.end, now: now, window: window)
            guard to > from else { continue }

            let isCurrent = index == worked.count - 1 && stretch.end >= now.addingTimeInterval(-1)
            // The head of the current stretch is brighter: that is the work
            // being recorded right now. Every earlier arc settles to ember.
            let opacity: Double = isCurrent ? 1 : 0.62
            let path = geometry.arcPath(from: from, to: to)

            // Lay the sky down under a dimmed arc first. Without it the dotted
            // track reads straight through the translucent ember and a settled
            // stretch looks like a dashed line rather than solid work.
            if opacity < 1 {
                context.stroke(
                    path,
                    with: .color(palette.sky),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
            }
            context.stroke(
                path,
                with: .color(traceColor.opacity(opacity)),
                style: StrokeStyle(lineWidth: 6, lineCap: .round)
            )

            // A blurred highlight only works against a dark sky. In daylight the
            // dawn token is a deep brown, and blurring it under the arc head
            // left a muddy smudge rather than a glow, so the day scene simply
            // thickens the head instead.
            if isCurrent, mode == .recording {
                let head = geometry.arcPath(from: max(from, to - 0.06), to: to)
                if palette.isNight {
                    var glow = context
                    glow.addFilter(.blur(radius: 5))
                    glow.stroke(
                        head,
                        with: .color(palette.dawn.opacity(0.7)),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                } else {
                    context.stroke(
                        head,
                        with: .color(palette.dawn),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                }
            }
        }
    }

    // MARK: Layer 10 — the now satellite

    private func satellite(_ geometry: Geometry) -> some View {
        let point = geometry.point(at: 0)
        let tint = mode == .recording ? palette.dawn : palette.stone
        return Circle()
            .fill(tint)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(tint.opacity(mode == .inactive ? 0.12 : 0.26), lineWidth: 6)
            )
            .opacity(mode == .inactive ? 0.45 : 1)
            .scaleEffect(pulse ? 1.15 : 1)
            .animation(
                pulse
                    ? .easeInOut(duration: 1).repeatForever(autoreverses: true)
                    : .default,
                value: pulse
            )
            .position(point)
    }

    // MARK: Geometry

    /// Where the planet and its track sit inside the crop, and how a moment in
    /// the day maps onto the visible arc.
    private struct Geometry {
        let center: CGPoint
        let orbitRadius: CGFloat
        let planetCenter: CGPoint
        let planetRadius: CGFloat
        let visibleHalfAngle: CGFloat

        init(size: CGSize, crop: Crop) {
            let width = max(size.width, 1)
            let height = max(size.height, 1)

            // The apex is where "now" sits. Portrait puts it low enough to leave
            // the HUD its room; the landscape crop lifts it so the panel keeps
            // clean space for the HUD, pills, controls and footer.
            let apexY = height * (crop == .portrait ? 0.61 : 0.50)
            orbitRadius = width * (crop == .portrait ? 1.27 : 1.6)
            center = CGPoint(x: width / 2, y: apexY + orbitRadius)

            // The panel is only 268 pt tall with a 50 pt footer over it, so a
            // planet placed by the portrait proportions has almost no limb left
            // to see — the scene read as an empty gradient. Landscape brings the
            // horizon up and tightens the curvature so the body is unmistakably
            // a planet rather than a band of colour.
            let planetTop = height * (crop == .portrait ? 0.755 : 0.62)
            planetRadius = width * (crop == .portrait ? 1.18 : 0.95)
            planetCenter = CGPoint(x: width / 2, y: planetTop + planetRadius)

            // Just enough to cover the crop, plus a little so the track runs off
            // the edges instead of stopping inside them.
            visibleHalfAngle = asin(min(0.99, (width / 2 + 12) / orbitRadius))
        }

        /// Angle along the track, measured from the apex. Negative is the past.
        func angle(for instant: Date, now: Date, window: TimeInterval) -> CGFloat {
            guard window > 0 else { return 0 }
            let behind = now.timeIntervalSince(instant) / window
            return CGFloat(-min(1, max(0, behind))) * visibleHalfAngle
        }

        func point(at angle: CGFloat) -> CGPoint {
            CGPoint(
                x: center.x + orbitRadius * sin(angle),
                y: center.y - orbitRadius * cos(angle)
            )
        }

        func arcPath(from start: CGFloat, to end: CGFloat) -> Path {
            var path = Path()
            // Angles are measured from the apex (12 o'clock); `Path.addArc`
            // measures from 3 o'clock and runs clockwise on screen.
            path.addArc(
                center: center,
                radius: orbitRadius,
                startAngle: .radians(Double(start) - .pi / 2),
                endAngle: .radians(Double(end) - .pi / 2),
                clockwise: false
            )
            return path
        }
    }

    // MARK: Constants

    private struct Star { let x: CGFloat; let y: CGFloat; let radius: CGFloat; let brightness: Double }

    /// A fixed field rather than a random one, so the sky is the same every
    /// launch and snapshot tests stay stable.
    private static let stars: [Star] = {
        var seed: UInt64 = 0x0B17_5EED
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((seed >> 33) % 10_000) / 10_000
        }
        return (0..<46).map { _ in
            Star(
                x: CGFloat(next()),
                y: CGFloat(next()),
                radius: CGFloat(0.5 + next() * 0.8),
                brightness: 0.25 + next() * 0.5
            )
        }
    }()

    private struct Band { let x: CGFloat; let y: CGFloat; let width: CGFloat; let height: CGFloat }

    private static let surfaceBands: [Band] = [
        Band(x: -0.28, y: 0.06, width: 0.62, height: 0.055),
        Band(x: 0.22, y: 0.13, width: 0.44, height: 0.04),
        Band(x: -0.05, y: 0.21, width: 0.7, height: 0.05),
    ]
}
