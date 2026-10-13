import Foundation

// MARK: - Equalizer curve interchange
//
// Pure, side-effect-free import / export of equalizer curves:
//  - AutoEq / Equalizer APO parametric text (`ParametricEQ.txt`):
//      Preamp: -6.2 dB
//      Filter 1: ON PK Fc 31 Hz Gain 2.4 dB Q 1.41
//  - the single-line `GraphicEQ: 25 -3; 40 -2.5; ...` form (import only).
// Nothing here touches the headphone: `HeadphoneModel.importEQ` / `exportEQ` do the wiring.

/// Filter kinds the headphone understands (device band type 0 / 1 / 2).
enum EQFilterType: Equatable {
    case lowShelf, peaking, highShelf

    /// Band type byte of `EQBand`.
    var deviceType: UInt8 {
        switch self {
        case .lowShelf: 0
        case .peaking: 1
        case .highShelf: 2
        }
    }

    init(deviceType: UInt8) {
        switch deviceType {
        case 0: self = .lowShelf
        case 2: self = .highShelf
        default: self = .peaking
        }
    }
}

struct EQFilter: Equatable {
    var type: EQFilterType
    var freq: Double   // Hz
    var gain: Double   // dB
    var q: Double
}

struct ParsedEQ: Equatable {
    var filters: [EQFilter] = []
    var preamp: Double?
    var warnings: [String] = []
}

/// Result of fitting a `ParsedEQ` onto the device's fixed 8 bands.
struct EQMapping {
    var profile: EQProfile
    var warnings: [String]
}

enum EQInterchange {
    /// The custom EQ always has exactly this many bands.
    static let bandCount = 8
    /// Default band centres of the custom EQ.
    static let defaultFrequencies: [Double] = [55, 110, 220, 440, 1320, 3300, 6600, 13200]
    /// The headphone accepts ±12 dB per band.
    static let gainLimit = 12.0
    /// Sanity bounds applied on import (app-side, not verified on the headphone).
    static let frequencyRange = 20.0...20000.0
    static let qRange = 0.1...20.0

    // MARK: Parsing

    static func parse(_ text: String) -> ParsedEQ {
        var result = ParsedEQ()
        var graphic: [(freq: Double, gain: Double)] = []
        var graphicSeen = false

        let cleaned = text.replacingOccurrences(of: "\u{FEFF}", with: "")
        for (index, raw) in cleaned.components(separatedBy: .newlines).enumerated() {
            let lineNumber = index + 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if let rest = value(of: "Preamp", in: line) {
                if let v = firstNumber(#"^"#, in: rest) { result.preamp = v }
                continue
            }
            if let rest = value(of: "GraphicEQ", in: line) {
                graphicSeen = true
                graphic = parseGraphic(rest, into: &result.warnings, line: lineNumber)
                continue
            }
            if let rest = filterBody(line) {
                if let f = parseFilter(rest, line: lineNumber, warnings: &result.warnings) {
                    result.filters.append(f)
                }
                continue
            }
            // Channel:, Device:, Include:, Copy: ... are valid APO lines that carry no curve.
        }

        if graphicSeen {
            if !result.filters.isEmpty {
                result.warnings.append(String(localized: "GraphicEQ ignored: the file also has parametric filters"))
            } else if !graphic.isEmpty {
                result.filters = defaultFrequencies.map {
                    EQFilter(type: .peaking, freq: $0, gain: interpolate(graphic, at: $0), q: 1)
                }
                result.warnings.append(String(localized: "GraphicEQ sampled at the 8 band centres"))
            }
        }
        return result
    }

    /// `Key: value` (case-insensitive key); returns the part after the colon.
    private static func value(of key: String, in line: String) -> String? {
        guard line.range(of: "^\(key)\\s*:", options: [.regularExpression, .caseInsensitive]) != nil,
              let colon = line.firstIndex(of: ":") else { return nil }
        return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }

    /// `Filter 3: ON PK ...` / `Filter: ON PK ...`; returns what follows the colon.
    private static func filterBody(_ line: String) -> String? {
        guard line.range(of: #"^Filter\s*\d*\s*:"#, options: [.regularExpression, .caseInsensitive]) != nil,
              let colon = line.firstIndex(of: ":") else { return nil }
        return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func parseFilter(_ body: String, line: Int, warnings: inout [String]) -> EQFilter? {
        // Optional ON / OFF, then the filter type, then key/value pairs.
        let words = body.split(whereSeparator: \.isWhitespace).map(String.init)
        var idx = 0
        if let first = words.first?.uppercased(), first == "ON" || first == "OFF" {
            if first == "OFF" { return nil }
            idx = 1
        }
        guard idx < words.count else {
            warnings.append(String(format: String(localized: "Line %d: filter could not be read, ignored"), line))
            return nil
        }
        let typeName = words[idx].uppercased()
        let rest = words[(idx + 1)...].joined(separator: " ")

        let type: EQFilterType
        switch typeName {
        case "PK", "PEQ", "PEAK": type = .peaking
        case "LSC", "LS", "LSQ": type = .lowShelf
        case "HSC", "HS", "HSQ": type = .highShelf
        default:
            warnings.append(String(format: String(localized: "Filter type %@ is not supported, ignored (line %d)"), typeName, line))
            return nil
        }

        guard var freq = firstNumber(#"\bFc\s*=?\s*"#, in: rest), let gain = firstNumber(#"\bGain\s*=?\s*"#, in: rest) else {
            warnings.append(String(format: String(localized: "Line %d: filter could not be read, ignored"), line))
            return nil
        }
        var q: Double
        if let v = firstNumber(#"\bQ\s*=?\s*"#, in: rest) {
            q = v
        } else if let bw = firstNumber(#"\bBW\s*(?:Oct\w*)?\s*=?\s*"#, in: rest), bw > 0 {
            // Bandwidth in octaves to Q: Q = sqrt(2^BW) / (2^BW - 1).
            let p = pow(2, bw)
            q = p > 1 ? p.squareRoot() / (p - 1) : 0
        } else {
            q = type == .peaking ? 1 : 0.707
        }

        if !(q > 0) {
            q = type == .peaking ? 1 : 0.707
            warnings.append(String(format: String(localized: "Line %d: invalid Q, default used"), line))
        }
        if !frequencyRange.contains(freq) {
            freq = min(max(freq, frequencyRange.lowerBound), frequencyRange.upperBound)
            warnings.append(String(format: String(localized: "Line %d: frequency out of range, clamped to 20 to 20000 Hz"), line))
        }
        if !qRange.contains(q) {
            q = min(max(q, qRange.lowerBound), qRange.upperBound)
            warnings.append(String(format: String(localized: "Line %d: Q out of range, clamped"), line))
        }
        return EQFilter(type: type, freq: freq, gain: gain, q: q)
    }

    private static func parseGraphic(_ body: String, into warnings: inout [String], line: Int) -> [(freq: Double, gain: Double)] {
        var points: [(freq: Double, gain: Double)] = []
        var bad = false
        for pair in body.split(separator: ";") {
            let parts = pair.split(whereSeparator: \.isWhitespace)
            if parts.isEmpty { continue }
            if parts.count == 2, let f = parseNumber(String(parts[0])), let g = parseNumber(String(parts[1])), f > 0 {
                points.append((f, g))
            } else {
                bad = true
            }
        }
        if bad {
            warnings.append(String(format: String(localized: "Line %d: some GraphicEQ points could not be read"), line))
        }
        return points.sorted { $0.freq < $1.freq }
    }

    /// Linear interpolation of the gain in log-frequency; flat beyond the first and last point.
    private static func interpolate(_ points: [(freq: Double, gain: Double)], at f: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if f <= first.freq { return first.gain }
        if f >= last.freq { return last.gain }
        for i in 1..<points.count where points[i].freq >= f {
            let a = points[i - 1], b = points[i]
            if b.freq == a.freq { return b.gain }
            let t = (log(f) - log(a.freq)) / (log(b.freq) - log(a.freq))
            return a.gain + t * (b.gain - a.gain)
        }
        return last.gain
    }

    // MARK: Number helpers

    private static let numberPattern = #"([-+]?(?:\d+(?:[.,]\d*)?|[.,]\d+))"#

    /// Parses `1.5` and `1,5` alike.
    private static func parseNumber(_ s: String) -> Double? {
        guard let v = Double(s.replacingOccurrences(of: ",", with: ".")), v.isFinite else { return nil }
        return v
    }

    /// The number that follows `prefix` (a regex) in `s`.
    private static func firstNumber(_ prefix: String, in s: String) -> Double? {
        guard let re = try? NSRegularExpression(pattern: prefix + numberPattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return parseNumber(String(s[r]))
    }

    // MARK: Mapping to the device

    /// Fits the filters onto the headphone's 8 bands, on top of `base` (which keeps its `profile`
    /// id and `gain` field untouched).
    ///
    /// - Up to 8 usable filters: used as given, sorted by frequency, padded with 0 dB peaking bands at
    ///   the default centres (preferring centres not already covered within a third of an octave).
    /// - More than 8: keep the 8 with the largest |gain| (the original, unclamped value; ties keep the
    ///   earlier filter), then sort by frequency. |gain| is a simple proxy for how audible a band is.
    /// - Gains are clamped to ±12 dB.
    /// - Preamp: **not applied**. `EQProfile.gain` is encoded in the custom EQ payload (`F050`) but
    ///   what the firmware does with it is unverified, so folding a file's preamp into it could silently
    ///   do nothing or do something unexpected. It is reported as a warning instead.
    static func map(_ parsed: ParsedEQ, base: EQProfile) -> EQMapping {
        var warnings = parsed.warnings
        var filters = parsed.filters

        if filters.count > bandCount {
            let keep = filters.enumerated()
                .sorted { abs($0.element.gain) != abs($1.element.gain)
                    ? abs($0.element.gain) > abs($1.element.gain) : $0.offset < $1.offset }
                .prefix(bandCount)
                .map(\.offset)
            let dropped = filters.count - bandCount
            filters = keep.sorted().map { filters[$0] }
            warnings.append(String(format: String(localized: "%d filters dropped: only 8 bands, kept the 8 with the largest gain"), dropped))
        }

        if filters.count < bandCount {
            func covered(_ f: Double) -> Bool {
                filters.contains { abs(log2($0.freq / f)) < 1.0 / 3.0 }
            }
            var free = defaultFrequencies.filter { !covered($0) }
            free += defaultFrequencies.filter { !free.contains($0) }
            for f in free.prefix(bandCount - filters.count) {
                filters.append(EQFilter(type: .peaking, freq: f, gain: 0, q: 1))
            }
        }

        filters = filters.enumerated()
            .sorted { $0.element.freq != $1.element.freq ? $0.element.freq < $1.element.freq : $0.offset < $1.offset }
            .map(\.element)

        var clamped = 0
        var bands: [EQBand] = []
        for (i, f) in filters.enumerated() {
            let g = min(max(f.gain, -gainLimit), gainLimit)
            if g != f.gain { clamped += 1 }
            bands.append(EQBand(id: i, type: f.type.deviceType, gain: Float(g), freq: Float(f.freq), q: Float(f.q)))
        }
        if clamped > 0 {
            warnings.append(String(format: String(localized: "%d gains clamped to ±12 dB"), clamped))
        }
        if let p = parsed.preamp, abs(p) >= 0.05 {
            warnings.append(String(format: String(localized: "Preamp %@ dB not applied"), format(p, min: 1, max: 1)))
        }

        var profile = base
        profile.bands = bands
        return EQMapping(profile: profile, warnings: warnings)
    }

    // MARK: Export

    /// AutoEq-style `ParametricEQ.txt`.
    static func export(_ profile: EQProfile) -> String {
        var lines = ["Preamp: 0.0 dB"]
        for (i, b) in profile.bands.enumerated() {
            let kind: String
            switch EQFilterType(deviceType: b.type) {
            case .lowShelf: kind = "LSC"
            case .highShelf: kind = "HSC"
            case .peaking: kind = "PK"
            }
            lines.append("Filter \(i + 1): ON \(kind) Fc \(format(Double(b.freq), min: 0, max: 1)) Hz"
                + " Gain \(format(Double(b.gain), min: 1, max: 2)) dB Q \(format(Double(b.q), min: 1, max: 2))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Locale-independent decimal, trailing zeros trimmed down to `min` decimals, never "-0.0".
    private static func format(_ v: Double, min lo: Int, max hi: Int) -> String {
        var s = String(format: "%.\(hi)f", v)
        var decimals = hi
        while decimals > lo, s.hasSuffix("0") { s.removeLast(); decimals -= 1 }
        if decimals == 0, s.hasSuffix(".") { s.removeLast() }
        if s.hasPrefix("-"), Double(s) == 0 { s.removeFirst() }
        return s
    }
}
