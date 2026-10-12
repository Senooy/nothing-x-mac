import Foundation

/// Head orientation from the headphone's `E015` sensor stream, turned into smooth angles relative to
/// the direction "facing the Mac".
///
/// `E015` payload (16 bytes, ~9.5 Hz, started by `C058`): three little-endian Int32 orientation words
/// — pitch (+ up), roll (+ right shoulder), yaw (+ left) — then a Float32 "settled" confidence that is
/// high when the head has been still and drops to 0 while it is displaced.
/// Yaw is calibrated (half turn = 2³⁰ units); pitch and roll use an estimated scale. A sensitivity
/// setting lets the user fine-tune it.
final class HeadPoseFilter {
    struct Angles: Equatable {
        var yaw = 0.0, pitch = 0.0, roll = 0.0   // degrees
    }

    /// Yaw: a half turn (180°) is 2³⁰ units, measured with a guided 180° chair rotation (plateau ±1040…1070 M).
    private static let yawDegreesPerUnit = 180.0 / 1_073_741_824.0
    /// Pitch and roll keep an estimated scale of 2⁻²⁹ rad per unit (plausible head ranges: ~40° up, ~45° down).
    private static let tiltDegreesPerUnit = 180.0 / .pi / 536_870_912.0

    /// Only yaw drifts (gyro integration); pitch and roll come from gravity and are never auto-corrected.
    /// The yaw reference follows the head only while it is still AND within a few degrees of "facing the
    /// Mac", so looking at a second screen or the keyboard for a while never drags the anchor along.
    private let recenterTimeConstant = 25.0
    private let recenterWindow = 20.0     // degrees either side of the reference
    private let settledThreshold = 0.6

    private var reference: Angles?
    private var latest: Angles?        // relative to the reference
    private var previous: Angles?
    private var latestTime = 0.0, previousTime = 0.0
    private var smoothed = Angles()
    /// Yaw is kept *unwrapped* (it keeps counting past ±180°) so smoothing and extrapolation never take
    /// the long way round at the back; `lastWrappedYaw` is the previous wrapped value used to unwrap.
    private var lastWrappedYaw = 0.0
    private var lastTick: Double?
    private(set) var settled = 0.0
    private(set) var sampleCount = 0
    /// Latest relative head angles in degrees, for display.
    var current: Angles {
        guard var angles = latest else { return Angles() }
        angles.yaw = Self.wrap(angles.yaw)
        return angles
    }

    func reset() {
        reference = nil; latest = nil; previous = nil
        smoothed = Angles(); lastTick = nil; settled = 0; sampleCount = 0; lastWrappedYaw = 0
    }

    /// Makes the current head direction the "facing the Mac" direction.
    func recenter() {
        guard let latest else { reference = nil; return }
        if var ref = reference {
            ref.yaw += Self.wrap(latest.yaw); ref.pitch += latest.pitch; ref.roll += latest.roll
            reference = ref
        }
        self.latest = Angles(); previous = nil
        smoothed = Angles(); lastWrappedYaw = 0
    }

    func ingest(_ payload: [UInt8], now: Double) {
        guard payload.count >= 16 else { return }
        func word(_ o: Int) -> Int32 {
            Int32(bitPattern: UInt32(payload[o]) | UInt32(payload[o + 1]) << 8 | UInt32(payload[o + 2]) << 16 | UInt32(payload[o + 3]) << 24)
        }
        let confidence = Float(bitPattern: UInt32(payload[12]) | UInt32(payload[13]) << 8 | UInt32(payload[14]) << 16 | UInt32(payload[15]) << 24)
        settled = confidence.isFinite ? Double(max(0, min(1, confidence))) : 0
        let raw = Angles(yaw: Double(word(8)) * Self.yawDegreesPerUnit,
                         pitch: Double(word(0)) * Self.tiltDegreesPerUnit,
                         roll: Double(word(4)) * Self.tiltDegreesPerUnit)
        sampleCount += 1
        if reference == nil { reference = raw }
        var ref = reference!

        // Cancel the slow yaw drift: only while settled and already close to the reference direction.
        let offset = Self.wrap(raw.yaw - ref.yaw)
        if settled > settledThreshold, latestTime > 0, abs(offset) < recenterWindow {
            let k = 1 - exp(-(now - latestTime) / recenterTimeConstant)
            ref.yaw += offset * k
            reference = ref
        }
        let wrappedYaw = Self.wrap(raw.yaw - ref.yaw)
        let unwrappedYaw = latest.map { $0.yaw + Self.wrap(wrappedYaw - lastWrappedYaw) } ?? wrappedYaw
        lastWrappedYaw = wrappedYaw
        previous = latest; previousTime = latestTime
        latest = Angles(yaw: unwrappedYaw, pitch: raw.pitch - ref.pitch, roll: raw.roll - ref.roll)
        latestTime = now
    }

    /// Smoothed orientation, to call at display rate. Extrapolates a little between the sparse samples.
    func orientation(now: Double, sensitivity: Double) -> Angles {
        guard let latest else { return Angles() }
        var target = latest
        if let previous, latestTime > previousTime {
            let dt = latestTime - previousTime
            let ahead = min(max(now - latestTime, 0), 0.12)
            func extrapolate(_ a: Double, _ b: Double) -> Double {
                let velocity = max(-400, min(400, (a - b) / dt))
                return a + velocity * ahead
            }
            target.yaw = extrapolate(latest.yaw, previous.yaw)
            target.pitch = extrapolate(latest.pitch, previous.pitch)
            target.roll = extrapolate(latest.roll, previous.roll)
        }
        let dt = lastTick.map { now - $0 } ?? 0
        lastTick = now
        let alpha = 1 - exp(-dt / 0.045)
        smoothed.yaw += (target.yaw - smoothed.yaw) * alpha
        smoothed.pitch += (target.pitch - smoothed.pitch) * alpha
        smoothed.roll += (target.roll - smoothed.roll) * alpha
        // Only here is yaw brought back to ±180°: the renderer treats 181° and -179° as the same direction.
        return Angles(yaw: Self.wrap(smoothed.yaw * sensitivity), pitch: smoothed.pitch * sensitivity, roll: smoothed.roll * sensitivity)
    }

    private static func wrap(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d < -180 { d += 360 }
        return d
    }
}
