import AVFoundation

// Software equalizer (wired mode): the pure parts, free of audio objects so they can be unit tested.
// `EQAudioEngine` applies them, `HeadphoneModel` (MARK: Software EQ) decides when it runs.

enum SoftwareEQ {
    /// Same 8 bands as the headphone's own custom EQ (`Protocol.md`): peaking, Q = 1.
    static let frequencies: [Float] = [55, 110, 220, 440, 1320, 3300, 6600, 13200]
    static let defaultQ: Float = 1
    /// Range of the sliders; anything outside is clamped before it reaches the audio unit.
    static let gainRange: ClosedRange<Float> = -12...12

    struct BandParameters: Equatable {
        var filterType: AVAudioUnitEQFilterType
        var frequency: Float
        /// Octaves (AVAudioUnitEQ's unit), ignored by the plain shelf types.
        var bandwidth: Float
        var gain: Float
    }

    /// Band type byte of `EQBand`: 0 = low shelf, 1 = peaking, 2 = high shelf.
    static func filterType(_ type: UInt8) -> AVAudioUnitEQFilterType {
        switch type {
        case 0: .lowShelf
        case 2: .highShelf
        default: .parametric
        }
    }

    /// Bandwidth in octaves for a peaking filter of quality factor `q`:
    /// BW = 2 / ln 2 · asinh(1 / (2Q)), so Q = 1 → ≈ 1.39 octaves, Q = √2 → 1 octave.
    /// Clamped to what AVAudioUnitEQ accepts (0.05…5 octaves).
    static func bandwidth(q: Float) -> Float {
        guard q.isFinite, q > 0 else { return 5 }
        let octaves = 2 / Float(M_LN2) * asinh(1 / (2 * q))
        return min(max(octaves, 0.05), 5)
    }

    static func clampedGain(_ gain: Float) -> Float {
        gain.isFinite ? min(max(gain, gainRange.lowerBound), gainRange.upperBound) : 0
    }

    /// `EQBand` → AVAudioUnitEQ band. The frequency is kept inside 20 Hz … Nyquist.
    static func parameters(for band: EQBand, sampleRate: Double = 48_000) -> BandParameters {
        let nyquist = Float(sampleRate / 2) * 0.95
        let frequency = band.freq.isFinite ? min(max(band.freq, 20), nyquist) : 1000
        return BandParameters(filterType: filterType(band.type), frequency: frequency,
                              bandwidth: bandwidth(q: band.q), gain: clampedGain(band.gain))
    }

    /// Headroom: the unit's global gain is lowered by the largest positive band boost, so a boosted curve
    /// cannot push a full-scale signal into clipping (at the boosted band the overall gain stays ≤ 0 dB).
    /// Cuts need no headroom: an all-cut curve gives 0. Overlapping neighbouring boosts can still add up a
    /// little above the largest single one; the curves here are gentle enough for that to stay marginal.
    static func headroom(_ gains: [Float]) -> Float {
        -max(0, gains.map(clampedGain).max() ?? 0)
    }

    /// One step of the gain ramp: each gain moves toward its target by at most `maxStep` dB, so a preset
    /// jump is spread over a few audio blocks instead of changing the filters at once (no click).
    static func step(_ current: [Float], toward target: [Float], maxStep: Float) -> [Float] {
        guard current.count == target.count else { return target }
        return zip(current, target).map { c, t in
            abs(t - c) <= maxStep ? t : c + (t > c ? maxStep : -maxStep)
        }
    }

    /// The local 8-band profile used while wired (the headphone cannot be read then).
    static func profile(gains: [Float]) -> EQProfile {
        EQProfile(profile: 0, gain: 0, bands: frequencies.enumerated().map { i, f in
            EQBand(id: i, type: 1, gain: i < gains.count ? clampedGain(gains[i]) : 0, freq: f, q: defaultQ)
        })
    }

    /// Which preset a curve corresponds to; `.custom` when it is none of the fixed ones.
    static func preset(matching gains: [Float]) -> EQPreset {
        EQPreset.allCases.first { preset in
            guard let curve = preset.gains, curve.count == gains.count else { return false }
            return zip(curve, gains).allSatisfy { abs($0 - $1) < 0.05 }
        } ?? .custom
    }
}

/// Which equalizer the EQ controls drive.
enum EQPath: Equatable {
    /// The headphone's own EQ over Bluetooth (unchanged behaviour).
    case hardware
    /// The Mac's software EQ: the cable is plugged in, Bluetooth is down, the headphone's EQ is out of reach.
    case software

    static func active(isWired: Bool) -> EQPath { isWired ? .software : .hardware }
}

/// When the software EQ engine runs: enabled by the user, the headphone is wired, and the Mac anchor
/// (which also captures and mutes system audio) is not running.
enum SoftwareEQPolicy {
    enum Action: Equatable { case start, stop, none }

    static func shouldRun(enabled: Bool, wired: Bool, macAnchorActive: Bool) -> Bool {
        enabled && wired && !macAnchorActive
    }

    /// `active` = running or starting (a start may be waiting for the USB audio device to appear).
    static func action(enabled: Bool, wired: Bool, macAnchorActive: Bool, active: Bool) -> Action {
        let run = shouldRun(enabled: enabled, wired: wired, macAnchorActive: macAnchorActive)
        if run && !active { return .start }
        if !run && active { return .stop }
        return .none
    }
}
