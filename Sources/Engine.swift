import Foundation
import QuartzCore

/// Must match `Uniforms` in Shaders.metal (80 bytes).
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
    var pad0: Float = 0
    var mode: Int32 = 0
    var mode2: Int32 = 0
    var theme: Int32 = 0
    var pad1: Int32 = 0
}

/// Shared state for every screen: audio analysis, slow drift, style transitions.
final class Engine {
    static let shared = Engine()

    let analyzer = AudioAnalyzer()
    lazy var tap = SystemAudioTap(analyzer: analyzer)
    private let settings = Settings.shared

    private(set) var uniforms = Uniforms()
    /// Fragment buffer 1: 64 bands, then 64 peak caps, then 256 waveform samples (see Shaders.metal).
    private(set) var shaderData = [Float](repeating: 0, count: AudioAnalyzer.bandCount * 2 + AudioAnalyzer.waveformCount)

    private let start = CACurrentMediaTime()
    private var last = CACurrentMediaTime()
    private var flow: Double = 0
    private var hue: Double = 0
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
        shaderData = analyzer.bands + analyzer.peaks + analyzer.waveform
        let a = analyzer

        // Motion speeds up with the music, and never fully stops when silent.
        flow += Double(dt * (0.22 + 1.5 * a.level * a.activity + 0.9 * a.beat * a.activity))
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
        u.bass = a.bass
        u.mid = a.mid
        u.treble = a.treble
        u.level = a.level
        u.beat = a.beat * a.activity
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
