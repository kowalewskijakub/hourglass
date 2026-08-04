import SwiftUI
import HourglassCore

/// The Orbit scene: a planet, an orbital track, and the day traced along it.
///
/// The trace is **ambient, not a chart**. Solid ember arcs are stretches of
/// recorded work, gaps are rests, and the satellite marks now at the top of the
/// visible track with the past running away to the left. Exact times live in
/// textual UI and History; nothing here is meant to be read off to the minute,
/// and there is deliberately no scrubbing or segment selection.
///
/// The planet below is the one thing here that *is* literal. It is centred on
/// the viewer's own meridian and parallel, lit where the sun is actually lighting
/// it, and the terminator crosses the visible face at the hour it really crosses
/// — so a dawn arrives on screen as a dawn, not as a palette swap. The one
/// interaction in the whole scene is dragging that globe: the world turns under
/// the finger, and settles back to where the viewer stands when let go.
struct OrbitSceneView: View {
    /// Stretches of actual work today, oldest first.
    var worked: [StatisticsCalculator.WorkedStretch]
    var mode: OrbitSceneMode
    var now: Date
    /// How far back the visible track reaches. Widened to cover the day so far.
    var window: TimeInterval
    var crop: Crop
    /// Which phase of the day it is and where the sun stands, which together
    /// decide every colour here and which half of the globe is lit.
    var sky: OrbitSky

    enum Crop { case portrait, landscape }

    @Environment(\.orbitPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    /// How far the globe has been turned away from the viewer's own meridian.
    @State private var spin = GlobeSpin.home
    /// Where it stood when the current drag began, so the gesture stays absolute
    /// and a slow drag back undoes exactly what a fast drag out did.
    @State private var spinAtDragStart: GlobeSpin?
    /// Whether a hand is on the globe right now. Only the pointer cares — on the
    /// phone the finger is its own affordance, but a Mac has to be told that a
    /// thing can be picked up before anyone will try.
    @State private var isDragging = false
    /// The pending settle back home. Cancelled the moment a finger lands again.
    @State private var settling: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            let geometry = SceneGeometry(size: proxy.size, crop: crop)
            ZStack {
                skyGradient
                Canvas { context, size in
                    drawStars(&context, size: size)
                }
                // Its own layer, and the only animatable one: a flick has to be
                // interpolated frame by frame, which a canvas redrawn from plain
                // state cannot be. The rim and the sun's glow ride along inside
                // it — they belong to the body, and a horizon that stayed put
                // while the planet under it moved would come apart.
                PlanetLayer(geometry: geometry, sky: sky, spin: spin)

                // The track and its satellite are in orbit around that planet,
                // so they go where it goes. Drawn at rest and translated, rather
                // than re-measured: `offset` is animatable, so the orbit keeps
                // station through a flick and all the way home, which it could
                // not do from a canvas redrawn off plain state.
                Group {
                    Canvas { context, _ in
                        drawTrack(&context, geometry)
                        drawTrace(&context, geometry)
                    }
                    satellite(geometry)
                }
                .offset(y: -CGFloat(spin.lift))
            }
            // Only the planet takes the drag, and it takes it wherever it has
            // been pushed to. The sky above is where the HUD lives, and a globe
            // that could be moved from the numerals would be a globe the user
            // shoved by accident.
            .contentShape(PlanetDisc(crop: crop, lift: spin.lift))
            .globeCursor(isDraggable: isDraggable, isDragging: isDragging)
            .gesture(isDraggable ? rotation(geometry) : nil)
        }
        .orbitDecoration()
        .onAppear { pulse = mode.isRecording && !reduceMotion }
        .onChange(of: mode) { _, newMode in
            pulse = newMode.isRecording && !reduceMotion
        }
    }

    // MARK: Layer 1 — sky

    /// Three stops rather than two: the whole difference between a sunset and a
    /// blue evening lives in the middle of the gradient, not at either end.
    private var skyGradient: some View {
        LinearGradient(gradient: sky.gradient, startPoint: .top, endPoint: .bottom)
    }

    // MARK: Layer 2 — stars

    /// The field fades in across twilight rather than appearing at sunset, which
    /// is when stars actually arrive.
    private func drawStars(_ context: inout GraphicsContext, size: CGSize) {
        guard sky.starVisibility > 0.01 else { return }
        var context = context
        context.opacity = 0.7 * sky.starVisibility
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

    // MARK: Layer 7 — the orbit itself

    /// The stretch of ring that crosses the crop, dotted.
    private func drawTrack(_ context: inout GraphicsContext, _ geometry: SceneGeometry) {
        let ink = palette.inkSecondary.opacity(mode == .inactive ? 0.22 : 0.34)
        for path in geometry.orbitPaths(from: -geometry.visibleHalfAngle,
                                        to: geometry.visibleHalfAngle) {
            context.stroke(
                path,
                with: .color(ink),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1.5, 6])
            )
        }
    }

    // MARK: Layers 8–9 — the day trace

    private func drawTrace(_ context: inout GraphicsContext, _ geometry: SceneGeometry) {
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
            let paths = geometry.orbitPaths(from: from, to: to)

            for path in paths {
                // Lay the sky down under a dimmed arc first. Without it the
                // dotted track reads straight through the translucent ember and
                // a settled stretch looks like a dashed line rather than solid
                // work. The colour is sampled from the gradient at the track's
                // own height, because the sky is three colours now and the top
                // one is not what is behind the arc.
                if opacity < 1 {
                    context.stroke(
                        path,
                        with: .color(sky.color(atHeight: geometry.trackHeightFraction)),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                }
                context.stroke(
                    path,
                    with: .color(traceColor.opacity(opacity)),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
            }

            // A blurred highlight only works against a dark sky. In daylight the
            // dawn token is a deep brown, and blurring it under the arc head
            // left a muddy smudge rather than a glow, so the day scene simply
            // thickens the head instead.
            if isCurrent, mode == .recording {
                for head in geometry.orbitPaths(from: max(from, to - 0.06), to: to) {
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
    }

    // MARK: Layer 10 — the now satellite

    private func satellite(_ geometry: SceneGeometry) -> some View {
        let point = geometry.orbitPoint(at: 0).point
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

    // MARK: Turning the globe

    /// Only worth offering when there is a map to turn. The procedural fallback
    /// planet has no longitude, so dragging it would be a gesture that does
    /// nothing — worse than no gesture at all.
    private var isDraggable: Bool { OrbitPlanetTexture.isAvailable }

    private func rotation(_ geometry: SceneGeometry) -> some Gesture {
        // Enough slack that a tap or a scroll on the surrounding UI is never
        // mistaken for a turn of the world.
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if spinAtDragStart == nil {
                    spinAtDragStart = spin
                    isDragging = true
                    settling?.cancel()
                    settling = nil
                }
                let base = spinAtDragStart ?? spin
                spin = base.turned(by: value.translation, geometry)
            }
            .onEnded { value in
                let base = spinAtDragStart ?? spin
                spinAtDragStart = nil
                isDragging = false

                // Where the finger left it, with any stretch past the stops let
                // go of. Reduce Motion stops exactly there and comes back.
                var released = base.turned(by: value.translation, geometry)
                released.lift = geometry.clamped(lift: released.lift)

                // A flick still carries — but it carries *into* the way home
                // rather than stopping somewhere and waiting there. The coast is
                // however long the throw is worth and no longer; a release with
                // nothing behind it gets none, and starts back at once.
                let coast = reduceMotion ? 0 : Self.coast(of: value)
                if coast > 0 {
                    var flung = base.turned(by: Self.momentum(of: value, in: geometry), geometry)
                    flung.lift = geometry.clamped(lift: flung.lift)
                    withAnimation(.easeOut(duration: coast)) { spin = flung }
                } else if released != spin {
                    withAnimation(.easeOut(duration: 0.22)) { spin = released }
                } else {
                    spin = released
                }
                settleHome(after: coast)
            }
    }

    /// How far the flick carries past the finger, capped so a hard swipe reads as
    /// a spin rather than a teleport to the far side of the world.
    private static func momentum(
        of value: DragGesture.Value,
        in geometry: SceneGeometry
    ) -> CGSize {
        let extraX = value.predictedEndTranslation.width - value.translation.width
        let extraY = value.predictedEndTranslation.height - value.translation.height
        let limit = geometry.size.width * 1.2
        return CGSize(
            width: value.translation.width + min(max(extraX, -limit), limit),
            height: value.translation.height + min(max(extraY, -limit * 0.4), limit * 0.4)
        )
    }

    /// How long the throw is worth coasting for, before the globe turns for home.
    ///
    /// Zero unless something was actually thrown. That is the whole difference
    /// between a globe that carries and a globe that sits there: a release with no
    /// speed in it has nothing to coast on, and any pause at all reads as the
    /// scene having stopped responding.
    private static func coast(of value: DragGesture.Value) -> TimeInterval {
        let extraX = value.predictedEndTranslation.width - value.translation.width
        let extraY = value.predictedEndTranslation.height - value.translation.height
        let thrown = (extraX * extraX + extraY * extraY).squareRoot()
        guard thrown > 24 else { return 0 }
        return min(0.7, 0.2 + Double(thrown) / 1400)
    }

    /// The globe turns for home the moment it is let go of.
    ///
    /// `coast` is the tail of a throw, not a wait: it is however long the flick
    /// is still visibly carrying, and it is zero whenever the release had no
    /// speed in it. Nothing here ever holds the globe still away from home.
    private func settleHome(after coast: TimeInterval) {
        settling?.cancel()
        settling = Task { @MainActor in
            if coast > 0 { try? await Task.sleep(for: .seconds(coast)) }
            guard !Task.isCancelled, spin != .home else { return }

            // Walked in steps rather than handed to one long animation, so the
            // stored spin never runs ahead of what is on screen. A finger
            // landing mid-settle then picks the globe up exactly where it looks,
            // instead of snapping to the meridian the animation was aiming at.
            // Each step is given longer to run than it is left alone for, so the
            // chain overlaps into one continuous ease.
            let start = spin
            let duration = reduceMotion ? Self.reducedSettle : Self.settleDuration
            let step = duration / Double(Self.settleSteps)

            for index in 1...Self.settleSteps {
                let t = Double(index) / Double(Self.settleSteps)
                let eased = t * t * (3 - 2 * t)
                withAnimation(.linear(duration: step * 1.6)) {
                    spin = GlobeSpin(
                        longitude: start.longitude * (1 - eased),
                        lift: start.lift * (1 - eased)
                    )
                }
                try? await Task.sleep(for: .seconds(step))
                if Task.isCancelled { return }
            }
            spin = .home
        }
    }

    /// Long enough coming back to read as the globe settling, short enough that
    /// it is plainly answering the release rather than drifting off on its own.
    private static let settleDuration: TimeInterval = 1.5
    private static let reducedSettle: TimeInterval = 0.8
    private static let settleSteps = 40

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
}

// MARK: - GlobeSpin

/// How far the globe has been turned away from the viewer's own meridian and
/// parallel, in degrees.
///
/// Degrees rather than points, because that is what the map and the terminator
/// both speak: a spin of 15° is an hour of the world's rotation, whatever the
/// screen it is drawn on.
struct GlobeSpin: Equatable {
    /// Degrees the ball has been turned about its own poles.
    var longitude: Double
    /// Points the whole planet has been lifted up the screen. Positive is up,
    /// which brings more of the sphere into view.
    var lift: Double

    /// Where the globe rests, and always comes back to.
    static let home = GlobeSpin(longitude: 0, lift: 0)

    /// This grip, moved by a drag.
    ///
    /// Sideways turns the ball about its own poles. Up and down picks the whole
    /// planet up and moves it — the one thing in the scene that behaves like an
    /// object rather than a diagram. Pulling it up brings more of the sphere over
    /// the bottom of the screen, which is the fun of it: the horizon view opens
    /// out into a ball and then falls back.
    func turned(by translation: CGSize, _ geometry: SceneGeometry) -> GlobeSpin {
        // Dragging right brings the west into view: the surface follows the
        // finger, so the meridian under it runs the other way.
        let turned = longitude - Double(translation.width) * geometry.degreesPerPoint
        // Screen y runs down and the globe does not, so dragging up raises it.
        let raised = lift - Double(translation.height)
        return GlobeSpin(longitude: turned, lift: geometry.resisted(lift: raised))
    }
}

// MARK: - The planet

/// The globe: a real sphere, projected.
///
/// The body is drawn by a Metal shader ([OrbitGlobe.metal]) that maps every pixel
/// of the disc onto the ball, rotates it in three dimensions and reads the map
/// there — so the ground foreshortens toward the horizon, continents curve over
/// the limb, and the terminator is a curve across a sphere rather than a gradient
/// painted across a circle. The scene before this slid a flat band behind a round
/// mask, which looked passable standing still and gave itself away the moment
/// anyone dragged it.
///
/// `Animatable` for one reason: a view redrawn from plain state jumps straight to
/// its new value, so a flick would land rather than spin. Conforming lets SwiftUI
/// interpolate the aim and redraw at every frame in between.
private struct PlanetLayer: View, Animatable {
    let geometry: SceneGeometry
    let sky: OrbitSky
    var spin: GlobeSpin

    // Interpolation happens off the main actor's clock, so the conformance has
    // to stand outside it — the pair it reads and writes is two doubles.
    nonisolated var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(spin.longitude, spin.lift) }
        set {
            spin.longitude = newValue.first
            spin.lift = newValue.second
        }
    }

    /// The scene's geometry with the planet wherever it has been pushed to.
    /// Everything in this layer measures from here, so the body, its rim and the
    /// light on its horizon move as one object.
    private var moved: SceneGeometry { geometry.lifted(by: spin.lift) }

    var body: some View {
        ZStack {
            if let day = OrbitPlanetTexture.day {
                sphere(day: day)
            } else {
                Canvas { context, _ in
                    let rect = moved.planetRect
                    drawProcedural(&context, in: rect, body: Path(ellipseIn: rect))
                }
            }

            Canvas { context, size in
                // A shade falling away from the visible band, so the body reads
                // as something curving off into the dark rather than a cut-out.
                let rect = moved.planetRect
                context.fill(
                    Path(ellipseIn: rect),
                    with: .radialGradient(
                        Gradient(colors: [.clear, .black.opacity(0.55)]),
                        center: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.12),
                        startRadius: rect.width * 0.1,
                        endRadius: rect.width * 0.62
                    )
                )
                drawAtmosphere(&context, moved)
                drawSunGlow(&context, moved, size: size)
            }
        }
    }

    // MARK: The rim and the light on it

    private func drawAtmosphere(_ context: inout GraphicsContext, _ geometry: SceneGeometry) {
        let limb = Path(ellipseIn: geometry.planetRect)

        // Two passes: a wide soft halo for the atmosphere, then a tight bright
        // line for the limb itself. One blurred stroke alone reads as haze and
        // leaves no edge, which is what made the planet hard to find.
        var halo = context
        halo.addFilter(.blur(radius: 9))
        halo.stroke(
            limb,
            with: .color(sky.atmosphere.opacity(sky.isNight ? 0.55 : 0.75)),
            lineWidth: 10
        )
        context.stroke(
            limb,
            with: .color(sky.atmosphere.opacity(sky.isNight ? 0.85 : 0.95)),
            lineWidth: 1.5
        )
    }

    /// A warm bloom on the horizon, sitting where the sun actually is rather than
    /// in a fixed corner: it crosses the scene through the day, and is at its
    /// strongest in the minutes either side of the horizon. Never interactive,
    /// never carrying state.
    private func drawSunGlow(
        _ context: inout GraphicsContext,
        _ geometry: SceneGeometry,
        size: CGSize
    ) {
        guard sky.glowStrength > 0.01 else { return }
        var context = context
        context.addFilter(.blur(radius: size.width * 0.06))
        context.opacity = sky.glowStrength

        // Where the sun actually stands over the ball, projected back onto the
        // screen, and held near the crop so it never drifts off it entirely.
        let sun = geometry.sunOnScreen(for: sky, turnedBy: spin)
        let offset = sun.point.x - geometry.planetCenter.x
        let x = geometry.planetCenter.x + min(max(offset, -size.width * 0.55), size.width * 0.55)

        let width = size.width * 0.62
        let height = size.height * 0.07
        let rect = CGRect(
            x: x - width / 2,
            y: geometry.planetRect.minY - height * 0.35,
            width: width,
            height: height
        )
        context.fill(Path(ellipseIn: rect), with: .color(sky.glow))
    }

    /// The shader pass. Drawn over the whole crop rather than over the planet's
    /// bounding box, which at this zoom is more than twice the width of the
    /// screen: the shader returns nothing outside the disc, so covering only what
    /// is on screen costs nothing and saves the rest.
    private func sphere(day: Image) -> some View {
        let aim = moved.nadir(for: sky, turnedBy: spin)
        let night = OrbitPlanetTexture.night
        return Rectangle()
            .fill(.white)
            .colorEffect(
                ShaderLibrary.orbitGlobe(
                    .float2(moved.planetCenter),
                    .float(moved.planetRadius),
                    .float(Float(aim.latitude * .pi / 180)),
                    .float(Float(aim.longitude * .pi / 180)),
                    .float(Float(sky.declination * .pi / 180)),
                    .float(Float(sky.subsolarLongitude * .pi / 180)),
                    .float(sky.followsTheSun ? 1 : 0),
                    .float(Float(sky.fixedIllumination)),
                    .float(night == nil ? 0 : 1),
                    .image(day),
                    // The shader still needs something bound in the slot when
                    // there is no night map; the flag above is what decides
                    // whether a single texel of it is ever read.
                    .image(night ?? day)
                )
            )
    }

    // MARK: The fallback planet

    /// Drawn when no imagery is bundled. Not the plan, but it has to be a planet.
    private func drawProcedural(_ context: inout GraphicsContext, in rect: CGRect, body: Path) {
        let stops: [Gradient.Stop] = sky.isNight
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
                center: CGPoint(x: rect.midX, y: rect.minY),
                startRadius: 0,
                endRadius: rect.width / 2 * 1.15
            )
        )

        // Surface detail: a few soft bands just under the limb, so the planet
        // reads as a body rather than a flat disc.
        var detail = context
        detail.addFilter(.blur(radius: rect.width * 0.0225))
        detail.opacity = sky.isNight ? 0.22 : 0.5
        for band in Self.surfaceBands {
            let radius = rect.width / 2
            let width = radius * band.width
            let height = radius * band.height
            let origin = CGPoint(
                x: rect.midX + radius * band.x - width / 2,
                y: rect.minY + radius * band.y
            )
            detail.fill(
                Path(ellipseIn: CGRect(origin: origin, size: CGSize(width: width, height: height))),
                with: .color(sky.isNight ? sky.atmosphere : .white)
            )
        }
    }

    private struct Band { let x: CGFloat; let y: CGFloat; let width: CGFloat; let height: CGFloat }

    private static let surfaceBands: [Band] = [
        Band(x: -0.28, y: 0.06, width: 0.62, height: 0.055),
        Band(x: 0.22, y: 0.13, width: 0.44, height: 0.04),
        Band(x: -0.05, y: 0.21, width: 0.7, height: 0.05),
    ]
}

// MARK: - Geometry

/// Where the planet and its track sit inside the crop, how a moment in the day
/// maps onto the visible arc, and where a longitude lands on screen.
struct SceneGeometry: Equatable {
    let size: CGSize
    let orbitRadius: CGFloat
    /// Where the planet sits before anyone touches it.
    let restingPlanetCenter: CGPoint
    let planetRadius: CGFloat
    /// Points the planet has been picked up and moved by. Set through
    /// `lifted(by:)`, and deliberately *not* part of how the globe is aimed:
    /// shoving the ball around must reveal more of it, never re-point it.
    private(set) var lift: Double = 0

    /// Where the planet's middle sits, as a fraction of the crop's height, so a
    /// layer over the track can sample the sky's own colour there.
    let trackHeightFraction: Double
    /// How far either side of now the track runs before it leaves the crop.
    let visibleHalfAngle: CGFloat

    /// How far the ring is tipped out of the screen plane, about the vertical,
    /// and how far it is then tipped *within* it.
    ///
    /// Between them these are the slight lean that stops the track reading as a
    /// line ruled parallel to the horizon: the right-hand side of the ring stands
    /// nearer the viewer than the left, and one end of the arc sits clear of the
    /// other across the crop.
    ///
    /// Both are per-crop, because the ceiling on them is the sky between the
    /// track and the limb, and the two crops have wildly different amounts of it.
    /// A tipped ring is narrower than the circle it came from, so reaching the
    /// edge of the screen means going further round it, where it has dropped
    /// further — tip it too far and the arc dives into the planet at the corners.
    /// The phone has 79 pt of altitude and tolerates about 54°; the panel has 10
    /// and tolerates 24, which is why its track is nearly flat and has to be.
    let orbitTilt: Double
    let orbitRoll: Double
    /// Where the top of the crop falls along the ring once it has been tipped
    /// both ways. Rolling slides the ring's high point sideways, so angles are
    /// measured from here — that keeps the satellite marking *now* at the middle
    /// of the crop while the arc leans around it.
    let apexAngle: Double

    /// How far above the surface the track flies at the very least.
    ///
    /// A track lying flat on the ground is not an orbit, so it needs some
    /// daylight under it — but on the panel there is exactly 20 pt of sky
    /// between the bottom of the pills and the top of the limb, and the
    /// satellite is 20 pt across. Ten is the one altitude that centres it in
    /// that gap: any lower and the mark sits on the ground it is flying over,
    /// any higher and it disappears behind a pill.
    private static let minimumAltitude: CGFloat = 10

    init(size: CGSize, crop: OrbitSceneView.Crop) {
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        self.size = CGSize(width: width, height: height)

        // The planet is a horizon: a body far larger than the crop, with about a
        // third of the phone's height given to the curve of it. The scene is
        // built on that horizon — the sky above it carries the HUD, the light on
        // it carries the hour — and a whole ball floating in the middle is a
        // different scene, not a better-drawn version of this one.
        let planetTop = height * (crop == .portrait ? 0.70 : 0.52)
        planetRadius = width * (crop == .portrait ? 1.18 : 0.81)
        restingPlanetCenter = CGPoint(x: width / 2, y: planetTop + planetRadius)

        // The track is a **concentric** ring around that planet, at one constant
        // altitude, so it runs with the horizon rather than across it.
        let apexY = height * (crop == .portrait ? 0.61 : 0.50)
        orbitRadius = max(
            planetRadius + Self.minimumAltitude,
            restingPlanetCenter.y - apexY
        )
        trackHeightFraction = Double((restingPlanetCenter.y - orbitRadius) / height)

        // Enough to cover the crop and run off both edges — measured against the
        // tipped ring, which is narrower than the circle it came from, and with
        // room for the roll to lift one end out of the corner.
        // Negative: the *left* half of the ring is the near one. That is the
        // half the day's trace runs down, so the trace is drawn over the world
        // rather than swallowed by it, and the track stays unbroken from the
        // left edge of the crop right up to now. Positive put the near side on
        // the right, which looked the same on the phone — nothing is occluded
        // there — but on the panel it cut the oldest work off in mid-air.
        orbitTilt = (crop == .portrait ? -45.0 : -30.0) * .pi / 180
        orbitRoll = (crop == .portrait ? 7.0 : 5.0) * .pi / 180

        // Where *now* sits along the ring, and the two crops want different
        // things from it.
        //
        // The phone occludes nothing — its track never reaches the world — so
        // the only thing that matters there is that the satellite stays in the
        // middle of the crop, which is the ring's high point once it is rolled.
        //
        // The panel does occlude, and there the near/far boundary is the thing
        // to hit. Put now anywhere past it and the newest work is on the far
        // side: the trace gets cut in mid-air and the satellite floats away from
        // the end of its own arc. At the boundary exactly, everything behind now
        // is on the near half and the whole day stays drawn.
        apexAngle = crop == .portrait ? atan(tan(orbitRoll) / cos(orbitTilt)) : 0

        let reach = (width / 2 + 60) / (orbitRadius * CGFloat(cos(orbitTilt)))
        visibleHalfAngle = asin(min(0.99, reach))
    }

    /// Where the planet is now.
    var planetCenter: CGPoint {
        CGPoint(x: restingPlanetCenter.x, y: restingPlanetCenter.y - CGFloat(lift))
    }

    var planetRect: CGRect { rect(around: planetCenter) }

    /// Where it sits at rest — what the aiming is measured against, so that
    /// picking the globe up does not quietly turn it as well.
    private var restingRect: CGRect { rect(around: restingPlanetCenter) }

    private func rect(around point: CGPoint) -> CGRect {
        CGRect(
            x: point.x - planetRadius,
            y: point.y - planetRadius,
            width: planetRadius * 2,
            height: planetRadius * 2
        )
    }

    // MARK: Picking the planet up

    /// How far the globe can be pulled up the screen before it starts to resist.
    /// Generous: most of the ball comes over the bottom of the crop at the top of
    /// its travel, which is the whole point of being able to pull it.
    private var liftCeiling: Double { Double(size.height) * 0.42 }

    /// And how far it can be pushed away. Much less — there is nothing down
    /// there to look at, and a planet shoved off the bottom is just a gradient.
    private var liftFloor: Double { Double(size.height) * 0.14 }

    /// The distance past a stop that the globe can ever reach, however hard it is
    /// pulled. Small enough that the end of the travel is unmistakable.
    private static let liftGive: Double = 54

    /// A lift with the ends of its travel hard, for the moment the finger lifts:
    /// the stretch is something you hold, not somewhere the globe rests.
    func clamped(lift: Double) -> Double {
        min(liftCeiling, max(-liftFloor, lift))
    }

    /// A lift, with the ends of its travel made elastic.
    ///
    /// The first points move one for one and it stiffens from there, so the globe
    /// can always be pulled a little past its stop and never comes off it. A hard
    /// clamp instead makes the finger and the planet visibly disagree, which reads
    /// as the gesture having broken rather than the object having arrived.
    func resisted(lift: Double) -> Double {
        if lift > liftCeiling {
            let over = lift - liftCeiling
            return liftCeiling + Self.liftGive * over / (Self.liftGive + over)
        }
        if lift < -liftFloor {
            let over = -liftFloor - lift
            return -liftFloor - Self.liftGive * over / (Self.liftGive + over)
        }
        return lift
    }

    /// This geometry with the planet picked up and moved. Everything that belongs
    /// to the body — the rim, the horizon glow, the sphere itself — is measured
    /// from the result, so they move as one object.
    func lifted(by lift: Double) -> SceneGeometry {
        var moved = self
        moved.lift = lift
        return moved
    }

    // MARK: The sphere

    /// **The angle the globe is viewed from**, in degrees out from the point
    /// directly below the viewer — and the one number that decides which slice of
    /// the world the scene shows.
    ///
    /// The crop puts the planet's centre far below the screen, so the visible
    /// band runs from the horizon (90° out) down to roughly 35–40° out at the
    /// bottom. Placing the viewer's own latitude this far out sets where
    /// everything else lands: the horizon ends up at
    /// `viewerLatitude + (90 − aimAngle)` and the bottom of the screen at roughly
    /// `viewerLatitude − (aimAngle − 38)`.
    ///
    /// Raise it to look toward the equator, lower it toward the pole. At 68° a
    /// viewer in Warsaw gets about 17°N–74°N: Europe through the middle, the
    /// Sahara along the bottom, a rind of ice at the top. At 53° they got
    /// 39°N–89°N and spent the whole top half of the scene on Arctic ice.
    static let aimAngle: Double = 68

    /// How far out the *middle* of the visible band lies, in radians.
    ///
    /// Purely geometric — where the surface actually is on screen, rather than
    /// where it is aimed — because its only job is to say how foreshortened the
    /// ground under the finger is, and so how fast a drag should turn it.
    var bandAngle: Double {
        let top = Double(restingRect.minY)
        let visibleBottom = Double(min(restingRect.maxY, size.height))
        let middleY = top + (visibleBottom - top) * 0.5
        let rise = Double(restingPlanetCenter.y) - middleY
        return asin(min(0.999, max(-0.999, rise / Double(planetRadius))))
    }

    /// How many points of drag one radian of rotation is worth, measured where
    /// the user can actually see the surface.
    ///
    /// Not at the disc's centre: out at the band the sphere is turned away from
    /// the viewer, so the same rotation moves the ground across fewer pixels.
    /// Scaling by that foreshortening is what makes the surface keep up with the
    /// finger instead of crawling.
    var pointsPerRadian: Double { Double(planetRadius) * cos(bandAngle) }

    /// How many degrees of rotation one point of drag is worth.
    var degreesPerPoint: Double { 180 / (.pi * pointsPerRadian) }

    /// Where the globe points when nothing has been dragged.
    ///
    /// The longitude is the viewer's own, so their meridian runs down the middle
    /// of the disc. The latitude is dropped `aimAngle` south of them, because the
    /// nadir is far below the crop: aim it straight at the viewer and they end up
    /// behind the horizon rather than on screen.
    func homeNadir(for sky: OrbitSky) -> (latitude: Double, longitude: Double) {
        (sky.latitude - Self.aimAngle, sky.longitude)
    }

    /// Where the globe points now, in degrees.
    func nadir(for sky: OrbitSky, turnedBy spin: GlobeSpin) -> (latitude: Double, longitude: Double) {
        let home = homeNadir(for: sky)
        return (home.latitude, home.longitude + spin.longitude)
    }

    /// Where the sun sits on screen, and whether it is on the near face at all.
    ///
    /// The inverse of what the shader does to every pixel: the sun's direction in
    /// the globe's frame, turned back into the viewer's, which places the glow on
    /// the limb exactly where the light is actually coming from.
    func sunOnScreen(for sky: OrbitSky, turnedBy spin: GlobeSpin) -> (point: CGPoint, isFacing: Bool) {
        let aim = nadir(for: sky, turnedBy: spin)
        let sun = sky.sunDirection
        let turn = -aim.longitude * .pi / 180
        let tilt = aim.latitude * .pi / 180

        // Undo the turn about the pole, then the tilt — the shader's rotation run
        // backwards.
        let x1 = sun.x * cos(turn) + sun.z * sin(turn)
        let z1 = -sun.x * sin(turn) + sun.z * cos(turn)
        let y2 = sun.y * cos(tilt) - z1 * sin(tilt)
        let z2 = sun.y * sin(tilt) + z1 * cos(tilt)

        return (
            CGPoint(
                x: planetCenter.x + CGFloat(x1) * planetRadius,
                y: planetCenter.y - CGFloat(y2) * planetRadius
            ),
            z2 > 0
        )
    }

    // MARK: The orbit

    /// Where a point on the ring falls on screen, and how far toward the viewer
    /// it stands.
    ///
    /// The ring is a circle in space, tipped about the vertical axis, projected
    /// the same way the planet is. Angle 0 is the top of it; the day runs round
    /// from there. Positive depth is the near half — the half that passes in
    /// front of the world.
    func orbitPoint(at angle: CGFloat) -> (point: CGPoint, depth: Double) {
        let along = Double(angle) + apexAngle
        let across = sin(along) * Double(orbitRadius)

        // Tipped about the vertical: this is the near/far half, and it is what
        // the ring is drawn from.
        let tipped = CGPoint(
            x: CGFloat(across * cos(orbitTilt)),
            y: CGFloat(cos(along) * Double(orbitRadius))
        )
        // Then rolled about the line of sight, which only changes where the ring
        // lies on screen and never which side of the world it is on.
        let roll = orbitRoll
        let x = Double(tipped.x) * cos(roll) - Double(tipped.y) * sin(roll)
        let y = Double(tipped.x) * sin(roll) + Double(tipped.y) * cos(roll)

        return (
            CGPoint(x: planetCenter.x + CGFloat(x), y: planetCenter.y - CGFloat(y)),
            across * sin(orbitTilt)
        )
    }

    /// Whether a point on the ring can be seen, or whether the planet is in the
    /// way. Behind *and* within the disc is the only way to be hidden — behind
    /// but off to the side is just sky.
    private func isVisible(_ sample: (point: CGPoint, depth: Double)) -> Bool {
        if sample.depth >= 0 { return true }
        let dx = sample.point.x - planetCenter.x
        let dy = sample.point.y - planetCenter.y
        return (dx * dx + dy * dy).squareRoot() > planetRadius
    }

    /// The stretch of ring between two angles, cut into the pieces of it that
    /// are actually in view.
    ///
    /// One path per piece rather than one path with gaps, so a stroke never
    /// bridges the place where the ring went behind the planet — that bridge is
    /// exactly the line that would give the whole illusion away.
    func orbitPaths(from start: CGFloat, to end: CGFloat) -> [Path] {
        guard end > start else { return [] }
        let steps = max(2, Int((end - start) / Self.orbitStep) + 1)

        var paths: [Path] = []
        var current = Path()
        var drawing = false

        for step in 0...steps {
            let angle = start + (end - start) * CGFloat(step) / CGFloat(steps)
            let sample = orbitPoint(at: angle)
            if isVisible(sample) {
                if drawing {
                    current.addLine(to: sample.point)
                } else {
                    current.move(to: sample.point)
                    drawing = true
                }
            } else if drawing {
                paths.append(current)
                current = Path()
                drawing = false
            }
        }
        if drawing { paths.append(current) }
        return paths
    }

    /// Fine enough that the ring reads as a curve and the moment it slips behind
    /// the planet lands within a point or so of where it truly does.
    private static let orbitStep: CGFloat = 0.012

    // MARK: The day along it

    /// Where a moment sits along the track, measured from the apex where now is.
    /// Negative is the past, running away to the left.
    func angle(for instant: Date, now: Date, window: TimeInterval) -> CGFloat {
        guard window > 0 else { return 0 }
        let behind = now.timeIntervalSince(instant) / window
        return CGFloat(-min(1, max(0, behind))) * visibleHalfAngle
    }
}

private extension View {
    /// Tells a pointer that the globe can be picked up.
    ///
    /// Only macOS has anything to say here. A finger discovers a draggable thing
    /// by touching it, but a cursor has to be told before anyone tries — an
    /// interaction nothing hints at is one nobody finds.
    func globeCursor(isDraggable: Bool, isDragging: Bool) -> some View {
        #if os(macOS)
        return pointerStyle(isDraggable ? (isDragging ? .grabActive : .grabIdle) : nil)
        #else
        return self
        #endif
    }
}

/// The planet's disc, as a hit region: the globe is draggable exactly where it is
/// visible, and the sky above it belongs to the HUD.
private struct PlanetDisc: Shape {
    let crop: OrbitSceneView.Crop
    /// The globe is grabbable where it *is*, not where it started.
    var lift: Double

    func path(in rect: CGRect) -> Path {
        Path(ellipseIn: SceneGeometry(size: rect.size, crop: crop).lifted(by: lift).planetRect)
    }
}
