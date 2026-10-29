import Foundation
import QuartzCore

/// Must match `Uniforms` in Shaders.metal (96 bytes).
struct Uniforms {
    var time: Float = 0
    var flow: Float = 0
    var bass: Float = 0
    var mid: Float = 0
    var treble: Float = 0
    var level: Float = 0
    var beat: Float = 0
    var activity: Float = 0
    var resolution = SIMD2<Float>(1, 1)
    var drift = SIMD2<Float>(0, 0)
    var hue: Float = 0
    var brightness: Float = 1
    var modeMix: Float = 0
    var kick: Float = 0
    var mode: Int32 = 0
    var mode2: Int32 = 0
    var theme: Int32 = 0
    var flags: Int32 = 0
    /// Current speed of `flow` per second, for motion trails.
    var flowSpeed: Float = 0
    var pad0: Float = 0
    var pad1: Float = 0
    var pad2: Float = 0
}

/// Bit layout of `Uniforms.flags`, read by the Black Hole shader.
enum ShaderFlag {
    static let blackHoleStars: Int32 = 1
    static func blackHoleSize(_ size: BlackHoleSize) -> Int32 { Int32(size.rawValue) << 1 }
}

/// Shared state for every screen: audio analysis, slow drift, style transitions.
final class Engine {
    static let shared = Engine()

    let analyzer = AudioAnalyzer()
    lazy var tap = SystemAudioTap(analyzer: analyzer)
    private let settings = Settings.shared

    private(set) var uniforms = Uniforms()
    /// Fragment buffer 1: 64 bands, 64 peak caps, 256 waveform samples, the black hole's orbiting stars,
    /// then its spacetime ripples (layout documented in Shaders.metal).
    private(set) var shaderData = [Float](repeating: 0, count: AudioAnalyzer.bandCount * 2 + AudioAnalyzer.waveformCount
                                                         + Engine.orbitStarCount * 4 + Engine.rippleCount * 4)
    static let orbitStarCount = 28
    static let rippleCount = 12

    private let start = CACurrentMediaTime()
    private var last = CACurrentMediaTime()
    private var flow: Double = 0
    private var hue: Double = 0
    private var flowSpeed: Float = 0.22
    private var lastOnsetCount = 0

    /// One big spacetime wave per standout hit, newest first. `hold` grows while the hit is sustained,
    /// which makes that wave wider and stronger; `pitch` (0 bass ... 1 treble) sets how broad it is.
    private struct Ripple { var age: Float; var amp: Float; var hold: Float; var pitch: Float }
    private var ripples: [Ripple] = []
    private var lastRipple: CFTimeInterval = -10
    private var onsetAverage: Float = 0.5
    private var rippleHeld = false
    /// Minimum gap between waves.
    static let rippleCooldown: CFTimeInterval = 0.2

    private func updateRipples(dt: Float, now: CFTimeInterval) {
        let a = analyzer
        for i in ripples.indices { ripples[i].age += dt }
        if a.onsetCount != lastOnsetCount {
            lastOnsetCount = a.onsetCount
            // Only hits that stand out from the recent ones count.
            let standout = a.onsetStrength > max(0.7, onsetAverage * 1.25)
            onsetAverage += (a.onsetStrength - onsetAverage) * 0.15
            rippleHeld = standout && now - lastRipple > Self.rippleCooldown
            if rippleHeld {
                lastRipple = now
                ripples.insert(Ripple(age: 0, amp: a.onsetStrength, hold: 0, pitch: a.onsetPitch), at: 0)
            }
        } else if rippleHeld && a.isSustaining && !ripples.isEmpty {
            ripples[0].hold = min(ripples[0].hold + dt, 1.0)
        } else {
            rippleHeld = false
        }
        ripples = Array(ripples.prefix(Self.rippleCount).filter { $0.age < 6 })
    }

    /// (age, amp, hold, pitch) per ripple; unused slots have amp 0.
    func rippleData() -> [Float] {
        var out = [Float]()
        out.reserveCapacity(Self.rippleCount * 4)
        for i in 0..<Self.rippleCount {
            if i < ripples.count {
                let r = ripples[i]
                out += [r.age, r.amp * analyzer.activity, r.hold, r.pitch]
            } else {
                out += [99, 0, 0, 0]
            }
        }
        return out
    }

    /// Fixed random circular orbit for each star around the black hole: radius (event-horizon radii), phase, size, hue.
    private static let orbitStarParams: [(radius: Float, phase: Float, size: Float, hue: Float)] = {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func rand() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(seed >> 40) / Float(1 << 24)
        }
        return (0..<orbitStarCount).map { _ in
            let a = rand(), b = rand(), c = rand()
            return (1.3 + 1.2 * a, c * 2 * .pi, 0.0025 + 0.002 * b, a * 0.7)
        }
    }()

    /// (radius, angle, size, hue) per star, orbiting flat in the screen plane.
    func orbitStars() -> [Float] {
        var out = [Float]()
        out.reserveCapacity(Self.orbitStarCount * 4)
        for star in Self.orbitStarParams {
            // Kepler: inner stars go round faster.
            let angle = Float((Double(star.phase) + flow * 0.45 * pow(Double(star.radius) / 1.3, -1.5))
                .truncatingRemainder(dividingBy: 2 * .pi))
            out += [star.radius, angle, star.size, star.hue]
        }
        return out
    }
    private var mode = Settings.shared.style.rawValue
    private var nextMode = Settings.shared.style.rawValue
    private var transition: Float = 0
    private var lastCycle = CACurrentMediaTime()

    static let cycleInterval: CFTimeInterval = 8 * 60

    var isIdle: Bool { analyzer.activity < 0.02 }

    /// Called by each screen's renderer; only advances once per display frame.
    func tick() {
        let now = CACurrentMediaTime()
        guard now - last > 0.002 else { return }
        let dt = Float(min(now - last, 0.1))
        last = now

        analyzer.sensitivity = settings.sensitivity
        analyzer.update(dt: dt)
        let a = analyzer

        // Motion speeds up with the music, and never fully stops when silent. The speed itself is
        // eased so beats never make the animation lurch.
        let targetSpeed = 0.22 + 1.5 * a.level * a.activity + 0.9 * a.beat * a.activity
        flowSpeed += (targetSpeed - flowSpeed) * (1 - exp(-dt / 0.25))
        flow += Double(dt * flowSpeed)

        updateRipples(dt: dt, now: now)
        shaderData = a.bands + a.peaks + a.waveform + orbitStars() + rippleData()

        hue += Double(dt * (1.0 / 240 + 0.015 * a.level * a.activity))
        if flow > 20000 { flow -= 20000 }
        if hue > 1 { hue -= 1 }

        if settings.autoCycle && now - lastCycle > Self.cycleInterval && transition == 0 {
            lastCycle = now
            let all = Style.allCases
            settings.style = all[(settings.style.rawValue + 1) % all.count]
        }
        let desired = settings.style.rawValue
        if transition == 0 && desired != mode {
            nextMode = desired
            transition = 0.0001
        }
        if transition > 0 {
            transition += dt / 2.5
            if transition >= 1 {
                mode = nextMode
                transition = 0
            }
        }

        let t = now - start
        // Slow Lissajous drift of the whole composition: nothing stays on the same pixels (burn-in guard).
        let drift = SIMD2<Float>(
            Float(0.04 * sin(t * 2 * .pi / 431)),
            Float(0.025 * sin(t * 2 * .pi / 293 + 1.3)))

        var u = Uniforms()
        u.time = Float(t.truncatingRemainder(dividingBy: 20000))
        u.flow = Float(flow)
        u.flowSpeed = flowSpeed
        u.bass = a.bass
        u.mid = a.mid
        u.treble = a.treble
        u.level = a.level
        u.beat = a.beat * a.activity
        u.kick = a.kick * a.activity
        u.flags = (settings.blackHoleStars ? ShaderFlag.blackHoleStars : 0) | ShaderFlag.blackHoleSize(settings.blackHoleSize)
        u.activity = a.activity
        u.drift = drift
        u.hue = Float(hue)
        // Ambient mode sits dimmer than the reactive mode.
        u.brightness = settings.brightness * (0.6 + 0.4 * a.activity)
        u.mode = Int32(mode)
        u.mode2 = Int32(nextMode)
        let x = transition
        u.modeMix = x * x * (3 - 2 * x)
        u.theme = Int32(settings.theme.rawValue)
        uniforms = u
    }
}
