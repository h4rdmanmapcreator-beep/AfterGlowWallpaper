import Accelerate
import Foundation
import QuartzCore

/// Turns raw samples into what the shaders care about: 64 log-spaced bands,
/// bass/mid/treble, overall level, a beat pulse and an "is music playing" activity value.
/// Everything is auto-gained, so quiet and loud tracks both move the visuals.
final class AudioAnalyzer {
    static let bandCount = 64
    private let fftSize = 2048
    private let log2n: vDSP_Length = 11

    var sampleRate: Double = 48000
    var sensitivity: Float = 1

    // Ring buffer written by the audio thread.
    private let lock = NSLock()
    private var ring = [Float](repeating: 0, count: 8192)
    private var writeIndex = 0
    private var lastPush: CFTimeInterval = 0

    private let fftSetup: FFTSetup
    private var window: [Float]
    private var frame: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var power: [Float]
    private var tilt = [Float](repeating: 0, count: AudioAnalyzer.bandCount)

    // Outputs
    private(set) var bands = [Float](repeating: 0, count: AudioAnalyzer.bandCount)
    /// Slowly falling maximum of each band (equalizer peak caps).
    private(set) var peaks = [Float](repeating: 0, count: AudioAnalyzer.bandCount)
    /// Trigger-aligned, auto-gained waveform in -1...1 (oscilloscope).
    private(set) var waveform = [Float](repeating: 0, count: AudioAnalyzer.waveformCount)
    static let waveformCount = 256
    private(set) var bass: Float = 0
    private(set) var mid: Float = 0
    private(set) var treble: Float = 0
    private(set) var level: Float = 0
    private(set) var beat: Float = 0
    /// Fast envelope of how hard the sound is punching, across all frequencies (0...1).
    private(set) var kick: Float = 0
    /// Increments on every hard hit in the deep bass (kicks, 808s) or the high treble (snare cracks, claps, crashes).
    /// Mid-range attacks such as vocals, chords and plucks never count.
    private(set) var hardHitCount = 0
    /// How hard the latest hit landed (0.3 and up, uncapped so hard hits can still be compared), and where: 0 = bass, 1 = treble.
    private(set) var hardHitStrength: Float = 0
    private(set) var hardHitPitch: Float = 0
    /// True while the latest hit is still being held at (close to) its peak.
    private(set) var isSustaining = false
    private(set) var activity: Float = 0

    private var rawBands = [Float](repeating: 0, count: AudioAnalyzer.bandCount)
    private var slowBands = [Float](repeating: 0, count: AudioAnalyzer.bandCount)
    private var fluxAverage: Float = 0
    private var rises = [Float](repeating: 0, count: AudioAnalyzer.bandCount)

    /// Watches one frequency range for a sudden, loud jump above its own recent level.
    private struct HitDetector {
        let bands: Range<Int>
        let pitch: Float
        let minRise: Float
        let contrast: Float
        var average: Float = 0
    }
    private var hitDetectors = [
        HitDetector(bands: 0..<15, pitch: 0, minRise: 0.3, contrast: 2.5),    // ~35–150 Hz: kicks, 808s
        HitDetector(bands: 44..<64, pitch: 1, minRise: 0.3, contrast: 2.5),   // ~2.6–16 kHz: snare cracks, claps, crashes
    ]
    private let hitMinLoudness: Float = 0.5
    private var hitActive = false
    private var hitFired = false
    private var hitPeak: (strength: Float, detector: Int) = (0, 0)
    private var sustainRange = 0..<1
    private var sustainLevel: Float = 0
    private var peakDb: Float = -60
    private var rmsPeak: Float = 1e-4
    private var bassAverage: Float = 0
    private var lastBeat: CFTimeInterval = 0

    init() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        frame = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: fftSize / 2)
        imag = [Float](repeating: 0, count: fftSize / 2)
        power = [Float](repeating: 0, count: fftSize / 2)
        for b in 0..<Self.bandCount {
            // +3 dB/octave so treble is not drowned by bass (music is roughly pink).
            tilt[b] = 3 * log2(bandFrequency(Float(b)) / 100)
        }
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    func push(_ samples: UnsafePointer<Float>, count: Int) {
        lock.lock()
        let mask = ring.count - 1
        for i in 0..<count {
            ring[writeIndex] = samples[i]
            writeIndex = (writeIndex + 1) & mask
        }
        lastPush = CACurrentMediaTime()
        lock.unlock()
    }

    private func bandFrequency(_ b: Float) -> Float {
        let lo: Float = 35, hi: Float = 16000
        return lo * pow(hi / lo, b / Float(Self.bandCount - 1))
    }

    func update(dt: Float) {
        let now = CACurrentMediaTime()
        lock.lock()
        let stale = now - lastPush > 0.4
        let mask = ring.count - 1
        var r = (writeIndex - fftSize) & mask
        for i in 0..<fftSize {
            frame[i] = stale ? 0 : ring[r]
            r = (r + 1) & mask
        }
        lock.unlock()

        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(fftSize))
        let rmsDb = 20 * log10(rms + 1e-9)
        let playing = rmsDb > -58

        // Activity ramps up quickly when sound starts and fades slowly into the ambient idle look.
        let target: Float = playing ? 1 : 0
        let tau: Float = playing ? 0.35 : 2.5
        activity += (target - activity) * (1 - exp(-dt / tau))

        // Start at a rising zero crossing so the oscilloscope trace holds still instead of scrolling.
        let span = Self.waveformCount * 4
        var start = 0
        for i in 0..<(fftSize - span - 1) where frame[i] <= 0 && frame[i + 1] > 0 {
            start = i
            break
        }
        let waveGain = 1 / max(rmsPeak * 3.5, 1e-3)
        for j in 0..<Self.waveformCount {
            let v = playing ? min(max(frame[start + j * 4] * waveGain, -1), 1) : 0
            waveform[j] += (v - waveform[j]) * 0.6
        }

        vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(fftSize))
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { fp in
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(fftSize / 2))
            }
        }

        let binHz = Float(sampleRate) / Float(fftSize)
        var frameMax: Float = -200
        var dbs = [Float](repeating: -200, count: Self.bandCount)
        for b in 0..<Self.bandCount {
            let lo = max(1, Int(bandFrequency(Float(b) - 0.5) / binHz))
            let hi = min(fftSize / 2 - 1, max(lo, Int(bandFrequency(Float(b) + 0.5) / binHz)))
            var p: Float = 0
            for k in lo...hi { p = max(p, power[k]) }
            let db = 10 * log10(p + 1e-12) + tilt[b]
            dbs[b] = db
            frameMax = max(frameMax, db)
        }

        // Auto gain: track the loudest band, release ~4 dB/s.
        if playing { peakDb = max(frameMax, peakDb - 4 * dt) } else { peakDb -= 4 * dt }
        peakDb = max(peakDb, -30)
        let range: Float = 40
        let attack = 1 - exp(-dt / 0.025)
        let release = 1 - exp(-dt / 0.22)
        for b in 0..<Self.bandCount {
            var v = (dbs[b] - (peakDb - range)) / range
            v = min(max(v, 0), 1)
            v = min(pow(v, 1.6) * sensitivity, 1)
            if !playing { v = 0 }
            rawBands[b] = v
            bands[b] += (v - bands[b]) * (v > bands[b] ? attack : release)
            peaks[b] = max(bands[b], peaks[b] - 0.45 * dt)
        }

        func mean(_ range: Range<Int>, _ arr: [Float]) -> Float {
            var s: Float = 0
            for i in range { s += arr[i] }
            return s / Float(range.count)
        }
        let smooth = 1 - exp(-dt / 0.08)
        bass += (mean(0..<10, bands) - bass) * smooth
        mid += (mean(10..<36, bands) - mid) * smooth
        treble += (mean(36..<64, bands) - treble) * smooth

        rmsPeak = max(rms, rmsPeak * exp(-dt / 6), 1e-4)
        let lv = playing ? min(pow(rms / rmsPeak, 1.3) * sensitivity, 1) : 0
        level += (lv - level) * (1 - exp(-dt / (lv > level ? 0.05 : 0.3)))

        // Beat: bass onset clearly above its recent average.
        let bassNow = mean(0..<8, rawBands)
        if playing && bassNow > bassAverage + 0.12 && bassNow > 0.35 && now - lastBeat > 0.28 {
            beat = 1
            lastBeat = now
        }
        bassAverage += (bassNow - bassAverage) * (1 - exp(-dt / 0.6))
        beat *= exp(-dt * 4.5)

        // Punch across the whole spectrum: how much each band jumps above its own recent level,
        // weighted towards the upper mids where the ear hears "punch" most. Comparing against a
        // smoothed copy (not the previous frame) keeps this independent of the frame rate.
        var flux: Float = 0, weights: Float = 0
        let follow = 1 - exp(-dt / 0.12)
        for b in 0..<Self.bandCount {
            let x = Float(b) / Float(Self.bandCount - 1)
            let w = 0.8 + 0.6 * exp(-pow((x - 0.55) / 0.25, 2))
            rises[b] = max(rawBands[b] - slowBands[b], 0)
            let rise = rises[b] * w
            flux += rise
            weights += w
            slowBands[b] += (rawBands[b] - slowBands[b]) * follow
        }
        flux /= weights

        let punch = playing ? min(max((flux - fluxAverage) * 6, 0), 1) : 0
        kick = max(kick * exp(-dt * 7), punch)

        // Hard hits: the bass or treble range jumps well above its own recent average while it is loud.
        // A hit fires once, at its peak, so its strength does not depend on the frame rate. There is no
        // time-based cooldown: it re-arms as soon as both ranges fall back, so back-to-back hits each
        // count, while a kick and a snare landing together count as one.
        var strongest: (strength: Float, detector: Int)?
        var holding = false
        for i in hitDetectors.indices {
            let d = hitDetectors[i]
            let rise = mean(d.bands, rises)
            let threshold = d.average * d.contrast + d.minRise
            let loud = playing && mean(d.bands, rawBands) > hitMinLoudness
            // A hit starts above the threshold and lasts until it drops well below it, so a hit that
            // wobbles around the threshold still counts once.
            if loud && rise > threshold * (hitActive ? 0.7 : 1) {
                holding = true
                let strength = max((rise - d.average) * 4, 0.3)
                if strength > (strongest?.strength ?? 0) { strongest = (strength, i) }
            }
            hitDetectors[i].average += (rise - d.average) * (1 - exp(-dt / 0.5))
        }
        var hit: (strength: Float, detector: Int)?
        if holding, let now = strongest {
            if !hitActive { hitActive = true; hitFired = false; hitPeak = now }
            if !hitFired && now.strength < hitPeak.strength {
                hit = hitPeak
                hitFired = true
            }
            if now.strength > hitPeak.strength { hitPeak = now }
        } else if hitActive {
            if !hitFired { hit = hitPeak }
            hitActive = false
        }
        if let hit {
            let d = hitDetectors[hit.detector]
            hardHitCount += 1
            hardHitStrength = hit.strength
            hardHitPitch = d.pitch
            sustainRange = d.bands
            sustainLevel = mean(d.bands, rawBands)
            isSustaining = true
        } else if isSustaining {
            let held = mean(sustainRange, rawBands)
            if !playing || held < sustainLevel * 0.7 || held < 0.25 { isSustaining = false }
        }
        fluxAverage += (flux - fluxAverage) * (1 - exp(-dt / 0.5))
    }
}
