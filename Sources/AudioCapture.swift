import CoreAudio
import AudioToolbox
import Foundation

/// Captures everything the Mac is playing through a Core Audio process tap (macOS 14.2+).
/// No virtual driver needed; macOS asks once for "System Audio Recording" permission.
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "afterglow.audio", qos: .userInteractive)
    private var scratch = [Float](repeating: 0, count: 16384)
    private var listenerInstalled = false
    private let analyzer: AudioAnalyzer

    private(set) var isRunning = false
    private(set) var lastError: String?

    init(analyzer: AudioAnalyzer) {
        self.analyzer = analyzer
    }

    func start() {
        stop()
        do {
            try startTap()
            isRunning = true
            lastError = nil
        } catch {
            lastError = "\(error)"
            NSLog("Afterglow: audio tap failed: \(error)")
            stop()
        }
        installDefaultDeviceListener()
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        isRunning = false
    }

    private func startTap() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Afterglow Visualizer Tap"
        description.muteBehavior = .unmuted
        description.isPrivate = true

        try check(AudioHardwareCreateProcessTap(description, &tapID), "create process tap")

        let outputUID = try defaultOutputDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Afterglow Aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate device")

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "read tap format")
        guard format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else {
            throw TapError.message("unsupported tap format")
        }
        analyzer.sampleRate = format.mSampleRate

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.consume(input)
        }, "create IO proc")
        try check(AudioDeviceStart(aggregateID, procID), "start device")
    }

    /// Mixes whatever channel layout arrives down to mono and hands it to the analyzer.
    private func consume(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard buffers.count > 0 else { return }

        scratch.withUnsafeMutableBufferPointer { out in
            var frames = 0
            if buffers.count == 1 {
                let buffer = buffers[0]
                guard let data = buffer.mData else { return }
                let channels = max(Int(buffer.mNumberChannels), 1)
                frames = min(Int(buffer.mDataByteSize) / (4 * channels), out.count)
                let samples = data.assumingMemoryBound(to: Float.self)
                let scale = 1 / Float(channels)
                for f in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += samples[f * channels + c] }
                    out[f] = sum * scale
                }
            } else {
                frames = min(Int(buffers[0].mDataByteSize) / 4, out.count)
                for f in 0..<frames { out[f] = 0 }
                let scale = 1 / Float(buffers.count)
                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    let samples = data.assumingMemoryBound(to: Float.self)
                    for f in 0..<frames { out[f] += samples[f] * scale }
                }
            }
            if frames > 0 { analyzer.push(out.baseAddress!, count: frames) }
        }
    }

    /// Rebuild the tap when headphones / AirPods / displays change the default output.
    private func installDefaultDeviceListener() {
        guard !listenerInstalled else { return }
        listenerInstalled = true
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            guard let self, self.isRunning || self.lastError != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.start() }
        }
    }

    private func defaultOutputDeviceUID() throws -> String {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device), "default output device")

        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid), "output device UID")
        guard let uid else { throw TapError.message("no output device UID") }
        return uid.takeRetainedValue() as String
    }

    private enum TapError: Error, CustomStringConvertible {
        case message(String)
        var description: String {
            switch self { case .message(let m): return m }
        }
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw TapError.message("\(what) failed (OSStatus \(status))") }
    }
}
