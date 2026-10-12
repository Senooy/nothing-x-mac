import Foundation

/// Protocole de contrôle Nothing (RFCOMM « NT LINK »). Voir Protocol.md.
enum NT {
    /// UUID du service SDP « NT LINK » (AEAC4A03-DFF5-498F-843A-34487CF133EB).
    static let serviceUUID: [UInt8] = [0xAE, 0xAC, 0x4A, 0x03, 0xDF, 0xF5, 0x49, 0x8F,
                                       0x84, 0x3A, 0x34, 0x48, 0x7C, 0xF1, 0x33, 0xEB]

    enum Cmd {
        static let readDeviceInfo: UInt16 = 0xC006
        static let readBattery: UInt16 = 0xC007
        static let readANC: UInt16 = 0xC01E
        static let readEQPreset: UInt16 = 0xC01F
        static let readFirmware: UInt16 = 0xC042
        static let readCustomEQ: UInt16 = 0xC04D
        static let readBassBoost: UInt16 = 0xC04E
        static let readSpatial: UInt16 = 0xC04F
        static let readGestures: UInt16 = 0xC018
        static let setANC: UInt16 = 0xF00F
        static let setEQPreset: UInt16 = 0xF010
        static let setCustomEQ: UInt16 = 0xF050
        static let setBassBoost: UInt16 = 0xF051
        static let setSpatial: UInt16 = 0xF052
        static let setGestures: UInt16 = 0xF003
        /// Starts the head-orientation stream (`E015`, ~9.5 Hz, until the channel closes).
        static let startHeadStream: UInt16 = 0xC058
        static let notifyANC: UInt16 = 0xE003
        static let notifyHeadPose: UInt16 = 0xE015
    }
}

struct Frame {
    var cmd: UInt16
    var opId: UInt8
    var payload: [UInt8]
}

enum Codec {
    /// CRC16 Modbus (polynôme réfléchi 0xA001, init 0xFFFF).
    static func crc16(_ bytes: some Sequence<UInt8>) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for b in bytes {
            crc ^= UInt16(b)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        }
        return crc
    }

    static func encode(cmd: UInt16, opId: UInt8, payload: [UInt8]) -> [UInt8] {
        let n = UInt16(payload.count)
        var out: [UInt8] = [0x55, 0x60, 0x01, UInt8(cmd & 0xFF), UInt8(cmd >> 8),
                            UInt8(n & 0xFF), UInt8(n >> 8), opId] + payload
        let crc = crc16(out)
        out += [UInt8(crc & 0xFF), UInt8(crc >> 8)]
        return out
    }
}

/// Reassembles frames from the RFCOMM byte stream (resynchronises on 0x55 and validates the CRC).
struct FrameParser {
    private var buffer: [UInt8] = []

    mutating func reset() { buffer.removeAll() }

    mutating func feed(_ data: [UInt8]) -> [Frame] {
        buffer += data
        var frames: [Frame] = []
        while true {
            guard let start = buffer.firstIndex(of: 0x55) else { buffer.removeAll(); break }
            if start > 0 { buffer.removeFirst(start) }
            // The control bytes differ by message kind (`60 01` for replies and most events, `20 03` for the
            // head-tracking stream), so only the CRC decides whether a candidate frame is real.
            if buffer.count < 10 { break }
            let len = Int(buffer[5]) | Int(buffer[6]) << 8
            if len > 2048 { buffer.removeFirst(); continue }
            let total = 8 + len + 2
            if buffer.count < total { break }
            let body = Array(buffer[0..<(total - 2)])
            let crc = UInt16(buffer[total - 2]) | UInt16(buffer[total - 1]) << 8
            if Codec.crc16(body) != crc { buffer.removeFirst(); continue }
            frames.append(Frame(cmd: UInt16(buffer[3]) | UInt16(buffer[4]) << 8,
                                opId: buffer[7],
                                payload: Array(buffer[8..<(total - 2)])))
            buffer.removeFirst(total)
        }
        return frames
    }
}

// MARK: - Noise control

enum ANCKind: CaseIterable {
    case anc, transparency, off
    var label: String {
        switch self {
        case .anc: String(localized: "ANC")
        case .transparency: String(localized: "Transparency")
        case .off: String(localized: "Off")
        }
    }
}

enum ANCLevel: UInt8, CaseIterable {
    case high = 1, mid = 2, low = 3, adaptive = 4
    var label: String {
        switch self {
        case .high: String(localized: "High")
        case .mid: String(localized: "Mid")
        case .low: String(localized: "Low")
        case .adaptive: String(localized: "Adaptive")
        }
    }
}

enum ANCState {
    static let off: UInt8 = 5
    static let transparency: UInt8 = 7

    static func kind(of raw: UInt8) -> ANCKind {
        switch raw {
        case off: .off
        case transparency: .transparency
        default: .anc
        }
    }
}

// MARK: - Equalizer

/// EQ presets as shown in the app. The headphone does not expose the curves of its built-in presets
/// (only the custom profile can be read), so each preset here is an explicit 8-band curve that the
/// app writes to the custom slot (device preset 5). "Balanced" uses the device's own preset 0.
/// Bands: 55 / 110 / 220 / 440 / 1320 / 3300 / 6600 / 13200 Hz.
enum EQPreset: CaseIterable {
    case balanced, bass, treble, voice, custom

    var label: String {
        switch self {
        case .balanced: String(localized: "Balanced")
        case .bass: String(localized: "More bass")
        case .treble: String(localized: "More treble")
        case .voice: String(localized: "Voice")
        case .custom: String(localized: "Custom")
        }
    }

    /// Curve in dB; `nil` for Custom (the user's own saved curve).
    var gains: [Float]? {
        switch self {
        case .balanced: [0, 0, 0, 0, 0, 0, 0, 0]
        case .bass: [6, 5, 3, 1, 0, 0, 0, 0]
        case .treble: [0, 0, 0, 0, 1, 3, 5, 6]
        case .voice: [-3, -2, 0, 2, 4, 3, 0, -2]
        case .custom: nil
        }
    }

    /// Device preset values: 0 = balanced, 5 = custom curve (the others are accepted but not used).
    static let deviceBalanced: UInt8 = 0
    static let deviceCustom: UInt8 = 5
}

struct EQBand: Identifiable, Equatable {
    var id: Int
    var type: UInt8   // 0 = low-shelf, 1 = peaking, 2 = high-shelf
    var gain: Float   // dB
    var freq: Float   // Hz
    var q: Float
}

struct EQProfile: Equatable {
    var profile: UInt8
    var gain: Float
    var bands: [EQBand]

    private static func float(_ p: [UInt8], _ o: Int) -> Float {
        Float(bitPattern: UInt32(p[o]) | UInt32(p[o + 1]) << 8 | UInt32(p[o + 2]) << 16 | UInt32(p[o + 3]) << 24)
    }

    private static func bytes(_ f: Float) -> [UInt8] {
        let b = f.bitPattern
        return [UInt8(b & 0xFF), UInt8((b >> 8) & 0xFF), UInt8((b >> 16) & 0xFF), UInt8(b >> 24)]
    }

    static func decode(_ p: [UInt8]) -> EQProfile? {
        guard p.count >= 6 else { return nil }
        let n = Int(p[1])
        guard p.count >= 6 + n * 13 else { return nil }
        var bands: [EQBand] = []
        var o = 6
        for i in 0..<n {
            bands.append(EQBand(id: i, type: p[o], gain: float(p, o + 1), freq: float(p, o + 5), q: float(p, o + 9)))
            o += 13
        }
        return EQProfile(profile: p[0], gain: float(p, 2), bands: bands)
    }

    func encode() -> [UInt8] {
        var out: [UInt8] = [profile, UInt8(bands.count)] + Self.bytes(gain)
        for b in bands { out += [b.type] + Self.bytes(b.gain) + Self.bytes(b.freq) + Self.bytes(b.q) }
        return out
    }
}

// MARK: - Spatial audio

/// `C04F` → `[on, headTracking]` ; `F052` prend le même format.
/// Le firmware ignore (en accusant réception) les écritures d'EQ non plat ou de basses
/// tant que l'audio spatial est actif : voir `HeadphoneModel.setSpatial`.
struct SpatialState: Equatable {
    var on: Bool
    var headTracking: Bool

    static func decode(_ p: [UInt8]) -> SpatialState? {
        guard let first = p.first else { return nil }
        return SpatialState(on: first != 0, headTracking: p.count > 1 && p[1] != 0)
    }

    func encode() -> [UInt8] { [on ? 1 : 0, headTracking ? 1 : 0] }
}

// MARK: - Gestures

/// Une ligne de la table `C018` : `[side, button, gesture, action]` (4 octets).
/// Sur le Headphone (1), `side` vaut toujours 0x06 (appareil unique).
struct GestureBinding: Identifiable, Equatable {
    var side: UInt8
    var button: UInt8
    var gesture: UInt8
    var action: UInt8

    var id: Int { Int(button) << 8 | Int(gesture) }

    static func decodeTable(_ p: [UInt8]) -> [GestureBinding] {
        guard let count = p.first else { return [] }
        var rows: [GestureBinding] = []
        for i in 0..<Int(count) {
            let o = 1 + 4 * i
            guard o + 4 <= p.count else { break }
            rows.append(GestureBinding(side: p[o], button: p[o + 1], gesture: p[o + 2], action: p[o + 3]))
        }
        return rows
    }

    /// Payload `F003` : `[01, side, button, gesture, action]`.
    func encodeSet() -> [UInt8] { [1, side, button, gesture, action] }

    // Libellés : 0x01/0x0A et les gestes 0x01/0x07 sont déduits de la table réelle
    // (roller / bouton, appui / triple appui) ; les actions 08/09/16 sont mesurées
    // sur d'autres modèles (AVRCP), 0B est supposée être « contrôle du bruit ».
    static func controlName(_ b: UInt8) -> String {
        switch b {
        case 0x01: String(localized: "Roller")
        case 0x0A: String(localized: "Button")
        default: String(format: String(localized: "Control 0x%02X"), b)
        }
    }

    static func gestureName(_ g: UInt8) -> String {
        switch g {
        case 0x01: String(localized: "Press")
        case 0x02: String(localized: "Single press")
        case 0x03: String(localized: "Double press")
        case 0x07: String(localized: "Triple press")
        case 0x09: String(localized: "Press and hold")
        default: String(format: String(localized: "Gesture 0x%02X"), g)
        }
    }

    static let knownActions: [UInt8] = [0x01, 0x09, 0x08, 0x16, 0x0B]

    static func actionName(_ a: UInt8) -> String {
        switch a {
        case 0x01: String(localized: "None")
        case 0x08: String(localized: "Next track")
        case 0x09: String(localized: "Play / pause")
        case 0x16: String(localized: "Previous track")
        case 0x0B: String(localized: "Noise control")
        default: String(format: String(localized: "Action 0x%02X"), a)
        }
    }
}
