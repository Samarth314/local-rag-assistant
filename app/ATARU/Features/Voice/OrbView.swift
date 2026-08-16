import SwiftUI

/// The ATARU orb — the reactor from the web dashboard's call mode.
///
/// One control that is also the entire status display: its motion says what
/// the assistant is doing, so the screen needs no spinner and no status text
/// competing for attention. A breathing core with a glow halo, expanding
/// ripples, orbiting arcs and particles, and a waveform ring that wobbles
/// only while ATARU talks. Ported 1:1 from `reactor-orb.js` (`ORB_CFG` +
/// `createReactor`), the same engine the web call overlay and the kiosk
/// dashboard run — per-state speeds, colours, and the eased `wave`
/// transition into and out of speaking are the original tuning.
///
/// Under Reduce Motion the timeline pauses: the orb renders one static frame
/// and the phase is carried by colour and the label instead.
struct OrbView: View {
    let phase: VoicePhase
    /// How big to draw it.
    ///
    /// A real size rather than a `scaleEffect` on a fixed 260: scaling changes
    /// what is drawn and not what is LAID OUT, so every call site that wanted
    /// a smaller orb was still reserving 260pt of column for it - which is
    /// half of why the Ask screen could not fit its own composer with the
    /// keyboard up. The engine derives every radius from `min(W, H)`, so a
    /// smaller canvas is a smaller orb and nothing is clipped.
    var side: CGFloat = 260
    /// Live audio level, 0...1 — the mic while listening, playback while
    /// speaking. A closure rather than a value so the per-frame Canvas reads
    /// the level as it is *now*: a plain parameter only updates when SwiftUI
    /// re-renders the view, and during non-streamed playback nothing else
    /// changes, which froze the orb at whatever level it last saw.
    var level: () -> Double = { 0 }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var engine = ReactorEngine()

    /// The web engine's natural canvas, and this view's default size.
    static let naturalSide: CGFloat = 260

    /// Reduce Motion, or a UI test run.
    ///
    /// The test half is not about motion sickness. `TimelineView(.animation)`
    /// redraws forever, and XCUITest waits for the app to be *idle* around
    /// every synthesised event — an app that never stops animating never goes
    /// idle. On the Ask screen that turned a single tap into an eight-second
    /// round trip that ended with the text field never taking focus, failing
    /// the typed-question test with "Neither element nor any descendant has
    /// keyboard focus". Freezing the orb under test is what makes this screen
    /// testable at all.
    private var isStill: Bool { reduceMotion || RuntimeMode.isUITesting }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: isStill)) { timeline in
            Canvas { context, size in
                engine.render(into: context, size: size,
                              now: timeline.date,
                              config: OrbConfig.for(phase),
                              level: min(max(level(), 0), 1),
                              frozen: isStill)
            }
        }
        .frame(width: side, height: side)
        .accessibilityElement()
        .accessibilityLabel("ATARU")
        .accessibilityValue(phase.label)
    }
}

/// Per-state tuning — `ORB_CFG` verbatim. `speed` and `ripEvery` are in the
/// web engine's frame units (one frame = 1/60 s); `ReactorEngine` converts
/// wall-clock time into frames so the motion matches the demo exactly.
private struct OrbConfig {
    let speed: Double     // t advance per frame
    let glow: Double      // master alpha for halo, arcs, rim
    let pulse: Double     // core breathing amplitude
    let ripEvery: Double  // frames between ripple spawns
    let ripSpeed: Double  // ripple growth per frame (pt)
    let arc: Double       // orbit arc coverage, fraction of pi
    let wave: Double      // waveform ring amplitude target
    let color: (r: Double, g: Double, b: Double)
    var isThinking = false

    static let idle = OrbConfig(speed: 0.006, glow: 0.55, pulse: 0.045,
                                ripEvery: 170, ripSpeed: 0.55, arc: 0.25,
                                wave: 0, color: (143, 211, 230))
    static let listening = OrbConfig(speed: 0.009, glow: 0.8, pulse: 0.08,
                                     ripEvery: 55, ripSpeed: 1.0, arc: 0.45,
                                     wave: 0.10, color: (150, 220, 240))
    static let thinking = OrbConfig(speed: 0.024, glow: 0.72, pulse: 0.05,
                                    ripEvery: 100, ripSpeed: 0.75, arc: 0.9,
                                    wave: 0, color: (175, 200, 235),
                                    isThinking: true)
    static let speaking = OrbConfig(speed: 0.011, glow: 0.92, pulse: 0.10,
                                    ripEvery: 34, ripSpeed: 1.05, arc: 0.5,
                                    wave: 0.16, color: (160, 220, 238))
    // Not in the web table: a failure keeps idle's quiet motion but takes
    // the palette's error colour — the one case where staying on-accent
    // would hide the thing the user needs to see.
    static let failed = OrbConfig(speed: 0.006, glow: 0.6, pulse: 0.045,
                                  ripEvery: 170, ripSpeed: 0.55, arc: 0.25,
                                  wave: 0, color: (235, 96, 96))

    static func `for`(_ phase: VoicePhase) -> OrbConfig {
        switch phase {
        case .idle: return .idle
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return .speaking
        case .failed: return .failed
        }
    }
}

/// The mutable animation state `createReactor` kept in its closure: the time
/// accumulator, the live ripples, and the eased wave amplitude. A reference
/// type so the Canvas draw closure can advance it without touching SwiftUI
/// state mid-render.
private final class ReactorEngine {
    private var t: Double = 0
    private var ripT: Double = 0
    private var wave: Double = 0
    private var ripples: [(r: Double, a: Double)] = []
    private var last: Date?

    func render(into context: GraphicsContext, size: CGSize, now: Date,
                config cfg: OrbConfig, level: Double, frozen: Bool) {
        let W = size.width, H = size.height
        let cx = W / 2, cy = H / 2
        let base = min(W, H) * 0.17

        // -- advance (web engine ran per-frame at 60fps; convert dt) -------- #
        var frames: Double = 0
        if !frozen {
            let dt = last.map { now.timeIntervalSince($0) } ?? 1.0 / 60.0
            last = now
            frames = min(max(dt * 60.0, 0), 4)   // clamp across hitches
            t += cfg.speed * frames
            wave += (cfg.wave - wave) * min(0.06 * frames, 1)
            ripT += frames
        }

        // Live audio drives the breath — the web orb reacts to ripples alone;
        // on the phone the level is right there, so a loud moment deepens the
        // pulse. While speaking the same level also feeds the waveform ring
        // below, which is what makes talking visibly different from idle.
        let pulseAmp = cfg.pulse + level * 0.10
        let pulse = 1 + sin(t * 5) * pulseAmp
        let R = base * pulse
        let col = cfg.color
        func A(_ alpha: Double) -> Color {
            Color(red: col.r / 255, green: col.g / 255, blue: col.b / 255,
                  opacity: alpha)
        }

        if !frozen {
            if ripT >= cfg.ripEvery {
                ripT = 0
                ripples.append((r: R, a: 0.42))
            }
            for i in ripples.indices {
                ripples[i].r += cfg.ripSpeed * 2.0 * frames
                ripples[i].a *= pow(0.986, frames)
            }
            ripples.removeAll { $0.a <= 0.02 || $0.r >= Double(max(W, H)) }
        }

        // -- glow halo ------------------------------------------------------ #
        let halo = Gradient(stops: [
            .init(color: A(0.15 * cfg.glow), location: 0),
            .init(color: A(0.045 * cfg.glow), location: 0.4),
            .init(color: .clear, location: 1),
        ])
        // The halo is painted over the whole canvas, so its gradient has to
        // reach fully transparent *before* the canvas edge — otherwise it is
        // sliced off mid-fade and the four straight cuts read as a square
        // panel around the orb.
        //
        // At the web's ratios it does not: 3.4 x a radius of 0.17 x the canvas
        // is 0.578 of it, against 0.5 to the nearest edge. That leftover alpha
        // is only a few parts in 255, invisible on the web's grey page and
        // plainly a box on this near-black backdrop — worst while speaking,
        // when glow peaks. Capping to the inscribed circle ends the fade
        // exactly at the edge and changes nothing a viewer can see.
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(halo, center: CGPoint(x: cx, y: cy),
                                  startRadius: R * 0.2,
                                  endRadius: min(R * 3.4, min(W, H) / 2)))

        // -- ripples -------------------------------------------------------- #
        for p in ripples {
            context.stroke(
                Path(ellipseIn: CGRect(x: cx - p.r, y: cy - p.r,
                                       width: p.r * 2, height: p.r * 2)),
                with: .color(A(p.a * 0.5 * cfg.glow)), lineWidth: 1.1)
        }

        // -- static rings --------------------------------------------------- #
        for i in 1...3 {
            let rr = R * (1 + Double(i) * 0.55)
            context.stroke(
                Path(ellipseIn: CGRect(x: cx - rr, y: cy - rr,
                                       width: rr * 2, height: rr * 2)),
                with: .color(A(0.055 + 0.018 * Double(i))), lineWidth: 1)
        }

        // -- orbit arcs (fast while thinking — the "working" tell) ---------- #
        let cover = Angle(radians: .pi * cfg.arc)
        for i in 0..<3 {
            let a0 = Angle(radians: t * 1.6 + Double(i) * (2 * .pi / 3))
            var arc = Path()
            arc.addArc(center: CGPoint(x: cx, y: cy), radius: R * 1.85,
                       startAngle: a0, endAngle: a0 + cover, clockwise: false)
            context.stroke(arc, with: .color(A(0.45 * cfg.glow)),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }

        // -- waveform ring (the "voice" look, only while speaking) ---------- #
        if wave > 0.005 {
            var wavePath = Path()
            // Amplitude rides the playback level, so the ring wobbles with
            // the voice itself rather than at one fixed depth — quiet words
            // barely stir it, emphasis kicks it visibly outward.
            let rr = R * 1.42, amp = R * wave * (0.75 + level * 1.6)
            var first = true
            for step in stride(from: 0.0, through: 6.2832, by: 0.025) {
                let w = sin(step * 8 + t * 18) * sin(step * 3 - t * 7)
                let rad = rr + w * amp
                let pt = CGPoint(x: cx + cos(step) * rad,
                                 y: cy + sin(step) * rad)
                if first { wavePath.move(to: pt); first = false }
                else { wavePath.addLine(to: pt) }
            }
            wavePath.closeSubpath()
            context.stroke(wavePath, with: .color(A(0.5 * cfg.glow)),
                           lineWidth: 1.3)
        }

        // -- core ----------------------------------------------------------- #
        let coreGradient = Gradient(stops: [
            .init(color: A(0.85 * cfg.glow), location: 0),
            .init(color: A(0.3 * cfg.glow), location: 0.5),
            .init(color: A(0.04), location: 1),
        ])
        let core = Path(ellipseIn: CGRect(x: cx - R, y: cy - R,
                                          width: R * 2, height: R * 2))
        context.fill(
            core,
            with: .radialGradient(coreGradient,
                                  center: CGPoint(x: cx - R * 0.3,
                                                  y: cy - R * 0.3),
                                  startRadius: R * 0.1, endRadius: R * 1.3))
        context.stroke(core, with: .color(A(0.65 * cfg.glow)), lineWidth: 1.3)

        // -- particles on the orbit paths ----------------------------------- #
        let pn = cfg.isThinking ? 10 : 6
        for i in 0..<pn {
            let a = t * (cfg.isThinking ? 4 : 2) + Double(i) * (2 * .pi / Double(pn))
            let rad = R * 2.5 + sin(t * 3.5 + Double(i)) * R * 0.22
            let pt = CGPoint(x: cx + cos(a) * rad, y: cy + sin(a) * rad)
            context.fill(
                Path(ellipseIn: CGRect(x: pt.x - 1.5, y: pt.y - 1.5,
                                       width: 3, height: 3)),
                with: .color(A(0.65)))
        }
    }
}

#Preview {
    VStack(spacing: 40) {
        OrbView(phase: .idle)
        OrbView(phase: .thinking)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .ataruBackdrop()
}
