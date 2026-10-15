import AudioToolbox
import CoreAudio
import Foundation

/// The capture half shared by the Mac anchor and the software equalizer: a Core Audio process tap on
/// everything every app plays (our own process excluded), muted while it is read, inside a private
/// aggregate device that holds only the tap, read by an IOProc that hands each block to a writer.
///
/// Extracted unchanged from `SpatialAudioEngine` (validated by ear on hardware): same tap description,
/// same tap-only aggregate, same IOProc. Two steps on purpose, so callers keep the original order:
/// `prepare()` (tap + aggregate + sample rate) → build the playback graph → `startIO(_:)` → start the engine.
///
/// Because the tap uses `CATapMutedWhenTapped`, the normal system output is silenced only while we are
/// reading, so audio comes back by itself once `stop()` destroys the tap (or the app stops or crashes).
final class SystemAudioTap {
    /// Receives one block of left / right samples on the tap's I/O queue (real-time: no locks held long,
    /// no allocation).
    typealias Writer = (_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>, _ frames: Int) -> Void

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let tapName: String
    private let aggregateName: String

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue: DispatchQueue
    private var tapUUID = UUID()

    init(tapName: String, aggregateName: String, queueLabel: String) {
        self.tapName = tapName
        self.aggregateName = aggregateName
        ioQueue = DispatchQueue(label: queueLabel, qos: .userInteractive)
    }

    /// Creates the tap and its aggregate device; returns the tap's sample rate.
    func prepare() throws -> Double {
        try createTap(excludingOwnProcess: true)
        try createAggregate()
        return try tapSampleRate()
    }

    /// Releases everything; safe to call more than once. Destroying the tap un-mutes system audio.
    func stop() {
        if let proc = ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: Core Audio tap

    private func createTap(excludingOwnProcess: Bool) throws {
        var excluded: [AudioObjectID] = []
        if excludingOwnProcess, let own = AudioDevices.processObject(for: getpid()) { excluded = [own] }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.name = tapName
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &id)
        guard status == noErr else {
            throw Failure(message: String(format: String(localized: "System audio capture failed (%d)"), Int(status)))
        }
        tapID = id
        tapUUID = description.uuid
    }

    /// The aggregate device holds only the tap. Adding the headphone as a sub-device would also open its
    /// Bluetooth microphone, which forces the headset into the low-quality phone profile (16 kHz).
    private func createAggregate() throws {
        let dictionary: [String: Any] = [
            kAudioAggregateDeviceNameKey: aggregateName,
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUUID.uuidString,
            ]],
        ]
        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(dictionary as CFDictionary, &id)
        guard status == noErr else {
            throw Failure(message: String(format: String(localized: "Audio routing failed (%d)"), Int(status)))
        }
        aggregateID = id
    }

    private func tapSampleRate() throws -> Double {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr, format.mSampleRate > 0 else {
            throw Failure(message: String(format: String(localized: "System audio capture failed (%d)"), Int(status)))
        }
        return format.mSampleRate
    }

    func startIO(_ write: @escaping Writer) throws {
        var scratchL = [Float](repeating: 0, count: 16384)
        var scratchR = [Float](repeating: 0, count: 16384)
        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) { _, inputData, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard buffers.count > 0 else { return }
            if buffers.count >= 2 {
                // Non-interleaved: one buffer per channel.
                guard let l = buffers[0].mData, let r = buffers[1].mData else { return }
                let frames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
                write(l.assumingMemoryBound(to: Float.self), r.assumingMemoryBound(to: Float.self), frames)
            } else if let data = buffers[0].mData {
                // Interleaved stereo.
                let channels = max(Int(buffers[0].mNumberChannels), 1)
                let frames = min(Int(buffers[0].mDataByteSize) / (MemoryLayout<Float>.size * channels), scratchL.count)
                let samples = data.assumingMemoryBound(to: Float.self)
                for i in 0..<frames {
                    scratchL[i] = samples[i * channels]
                    scratchR[i] = samples[i * channels + (channels > 1 ? 1 : 0)]
                }
                scratchL.withUnsafeBufferPointer { l in
                    scratchR.withUnsafeBufferPointer { r in write(l.baseAddress!, r.baseAddress!, frames) }
                }
            }
        }
        guard status == noErr, let proc = ioProcID else {
            throw Failure(message: String(format: String(localized: "System audio capture failed (%d)"), Int(status)))
        }
        let started = AudioDeviceStart(aggregateID, proc)
        guard started == noErr else {
            throw Failure(message: String(format: String(localized: "System audio capture failed (%d)"), Int(started)))
        }
    }
}
