import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Renders the Mac's system audio as binaural sound anchored in front of the listener.
///
/// Pipeline: a Core Audio process tap captures everything every app plays (our own process excluded)
/// and mutes it while we read it → two lock-protected ring buffers (left / right) → two mono
/// `AVAudioSourceNode`s placed like virtual speakers → `AVAudioEnvironmentNode` (HRTF) whose listener
/// orientation follows the head tracker → the headphone's output device.
///
/// Because the tap uses `CATapMutedWhenTapped`, the normal system output is silenced only while we are
/// reading, so audio comes back by itself if the app stops or crashes.
final class SpatialAudioEngine {
    enum Mode { case passthrough, hrtf }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private(set) var isRunning = false

    /// Tap + tap-only aggregate + IOProc (see `SystemAudioTap`).
    private let tap = SystemAudioTap(tapName: "Nothing X spatial tap", aggregateName: "Nothing X spatial",
                                     queueLabel: "nx.spatial.tap")

    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private var sources: [AVAudioSourceNode] = []

    private var configObserver: NSObjectProtocol?

    private let ringL = AudioRing()
    private let ringR = AudioRing()

    /// Virtual speakers: ±25° around the front at about one metre, like a laptop on a desk.
    private let speakerAzimuth: Float = 25
    private let speakerDistance: Float = 1.0

    // MARK: Lifecycle

    func start(outputDeviceNameContaining name: String, mode: Mode = .hrtf) throws {
        guard !isRunning else { return }
        guard let device = AudioDevices.outputDevice(nameContaining: name) else {
            throw Failure(message: String(localized: "Headphone audio device not found"))
        }
        do {
            let sampleRate = try tap.prepare()
            try buildGraph(sampleRate: sampleRate, outputDevice: device.id, mode: mode)
            let left = ringL, right = ringR
            try tap.startIO { l, r, frames in
                left.write(l, frames)
                right.write(r, frames)
            }
            try engine.start()
            isRunning = true
            // The output device can change its sample rate or format (e.g. when the headset switches profile).
            configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                guard let self, self.isRunning, !self.engine.isRunning else { return }
                try? self.engine.start()
            }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if engine.isRunning { engine.stop() }
        tap.stop()
        for node in sources { engine.detach(node) }
        sources.removeAll()
        if environment.engine != nil { engine.detach(environment) }
        ringL.reset(); ringR.reset()
        isRunning = false
    }

    /// Head orientation in degrees (yaw positive = turn left, like AVAudio3DAngularOrientation).
    func setListener(yaw: Float, pitch: Float, roll: Float) {
        environment.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: yaw, pitch: pitch, roll: roll)
    }

    // MARK: Playback graph

    private func buildGraph(sampleRate: Double, outputDevice: AudioObjectID, mode: Mode) throws {
        try engine.outputNode.auAudioUnit.setDeviceID(outputDevice)
        let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        func makeSource(_ ring: AudioRing) -> AVAudioSourceNode {
            AVAudioSourceNode(format: mono) { _, _, frameCount, bufferList in
                let list = UnsafeMutableAudioBufferListPointer(bufferList)
                guard let out = list[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                ring.read(into: out, Int(frameCount))
                return noErr
            }
        }
        let left = makeSource(ringL), right = makeSource(ringR)
        sources = [left, right]
        engine.attach(left); engine.attach(right)

        switch mode {
        case .passthrough:
            left.pan = -1; right.pan = 1
            engine.connect(left, to: engine.mainMixerNode, format: mono)
            engine.connect(right, to: engine.mainMixerNode, format: mono)
        case .hrtf:
            engine.attach(environment)
            environment.outputType = .headphones
            environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
            environment.distanceAttenuationParameters.rolloffFactor = 0   // keep level constant
            environment.reverbParameters.enable = true
            environment.reverbParameters.loadFactoryReverbPreset(.smallRoom)
            environment.reverbParameters.level = -20
            engine.connect(left, to: environment, format: mono)
            engine.connect(right, to: environment, format: mono)
            engine.connect(environment, to: engine.mainMixerNode, format: nil)
            let radians = speakerAzimuth * .pi / 180
            let x = speakerDistance * sin(radians), z = -speakerDistance * cos(radians)
            left.position = AVAudio3DPoint(x: -x, y: 0, z: z)
            right.position = AVAudio3DPoint(x: x, y: 0, z: z)
            for node in [left, right] {
                node.renderingAlgorithm = .HRTFHQ
                node.reverbBlend = 0.12
            }
        }
        engine.mainMixerNode.outputVolume = 1.0
        engine.prepare()
    }
}

// MARK: - Ring buffer

/// Single-producer / single-consumer ring of mono samples, guarded by an unfair lock.
/// Keeps latency bounded: if the reader falls behind, the oldest samples are dropped.
final class AudioRing {
    private let capacity = 1 << 15          // 32768 frames
    private let prefill = 1024              // wait for this much before starting playback
    private let maxFill = 6144              // never let latency grow past this
    private let keepAfterDrop = 2048
    private let buffer: UnsafeMutablePointer<Float>
    private var readPos = 0, writePos = 0
    private var playing = false
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    init() {
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit { buffer.deallocate(); lock.deallocate() }

    func reset() {
        os_unfair_lock_lock(lock)
        readPos = 0; writePos = 0; playing = false
        os_unfair_lock_unlock(lock)
    }

    func write(_ src: UnsafePointer<Float>, _ count: Int) {
        os_unfair_lock_lock(lock)
        for i in 0..<count { buffer[(writePos + i) & (capacity - 1)] = src[i] }
        writePos += count
        if writePos - readPos > maxFill { readPos = writePos - keepAfterDrop }
        os_unfair_lock_unlock(lock)
    }

    func read(into dst: UnsafeMutablePointer<Float>, _ count: Int) {
        os_unfair_lock_lock(lock)
        let available = writePos - readPos
        if !playing { playing = available >= prefill }
        var produced = 0
        if playing {
            produced = min(available, count)
            for i in 0..<produced { dst[i] = buffer[(readPos + i) & (capacity - 1)] }
            readPos += produced
            if produced < count { playing = false }   // underrun: rebuffer
        }
        os_unfair_lock_unlock(lock)
        if produced < count { for i in produced..<count { dst[i] = 0 } }
    }
}

// MARK: - Audio device helpers

enum AudioDevices {
    struct Device { let id: AudioObjectID; let uid: String; let name: String }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func hasOutput(_ device: AudioObjectID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr && size > 0
    }

    static func outputDevice(nameContaining fragment: String) -> Device? {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            guard let name = string(id, kAudioObjectPropertyName),
                  name.localizedCaseInsensitiveContains(fragment),
                  hasOutput(id),
                  let uid = string(id, kAudioDevicePropertyDeviceUID) else { continue }
            return Device(id: id, uid: uid, name: name)
        }
        return nil
    }

    /// The Core Audio process object for a pid, used to keep our own output out of the tap.
    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pidValue = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pidValue, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}
