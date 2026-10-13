import XCTest
@testable import NothingX

final class EQInterchangeTests: XCTestCase {
    private func base() -> EQProfile {
        let freqs: [Float] = [55, 110, 220, 440, 1320, 3300, 6600, 13200]
        return EQProfile(profile: 0, gain: 0, bands: freqs.enumerated().map {
            EQBand(id: $0.offset, type: 1, gain: 0, freq: $0.element, q: 1)
        })
    }

    // MARK: Parsing

    func testAutoEqFile() {
        let text = """
        Preamp: -6.2 dB
        Filter 1: ON LSC Fc 105 Hz Gain 4.5 dB Q 0.70
        Filter 2: ON PK Fc 31 Hz Gain 2.4 dB Q 1.41
        Filter 3: ON HSC Fc 10000 Hz Gain -3.0 dB Q 0.70
        """
        let p = EQInterchange.parse(text)
        XCTAssertEqual(p.preamp, -6.2)
        XCTAssertEqual(p.filters.count, 3)
        XCTAssertEqual(p.filters[0], EQFilter(type: .lowShelf, freq: 105, gain: 4.5, q: 0.7))
        XCTAssertEqual(p.filters[1], EQFilter(type: .peaking, freq: 31, gain: 2.4, q: 1.41))
        XCTAssertEqual(p.filters[2].type, .highShelf)
        XCTAssertTrue(p.warnings.isEmpty)
    }

    func testQuirks() {
        let text = "\u{FEFF}Preamp:  -3,5\r\n"
            + "# comment\r\n"
            + "Filter 1:   ON   PK   Fc   Hz\r\n"                      // no frequency value: skipped with a warning
            + "Filter 2: ON PK Fc 250,5 Gain 1,5 Q 2\r\n"            // decimal commas, no units
            + "Filter 3: OFF PK Fc 500 Hz Gain 5 dB Q 1\r\n"         // OFF is skipped silently
            + "filter 4: on lsq fc 80hz gain -2db q 0.9\r\n"         // lower case, no spaces before units
            + "Filter 5: ON PK Fc 1000 Hz Gain 3 dB BW Oct 1.0\r\n"  // bandwidth instead of Q
            + "Filter 6: ON LP Fc 18000 Hz\r\n"                      // unknown type
            + "Channel: all\r\n"
        let p = EQInterchange.parse(text)
        XCTAssertEqual(p.preamp, -3.5)
        XCTAssertEqual(p.filters.count, 3)
        XCTAssertEqual(p.filters[0].freq, 250.5)
        XCTAssertEqual(p.filters[0].gain, 1.5)
        XCTAssertEqual(p.filters[1], EQFilter(type: .lowShelf, freq: 80, gain: -2, q: 0.9))
        // BW 1 octave -> Q = sqrt(2) / 1
        XCTAssertEqual(p.filters[2].q, 2.0.squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(p.warnings.count, 2)
    }

    func testMissingQDefaults() {
        let p = EQInterchange.parse("Filter 1: ON PK Fc 100 Hz Gain 1 dB\nFilter 2: ON HS Fc 8000 Hz Gain 2 dB")
        XCTAssertEqual(p.filters[0].q, 1)
        XCTAssertEqual(p.filters[1].q, 0.707, accuracy: 1e-9)
    }

    func testGarbageDoesNotCrash() {
        for text in ["", "\n\n", "Filter", "Filter 1:", "Filter 1: ON", "Preamp:", "GraphicEQ:", "GraphicEQ: a b; ;", "Filter 1: ON PK Fc Gain Q"] {
            XCTAssertTrue(EQInterchange.parse(text).filters.isEmpty, text)
        }
    }

    // MARK: Mapping

    func testFewerThanEightIsPaddedAndSorted() {
        let p = EQInterchange.parse("Filter 1: ON PK Fc 3000 Hz Gain 2 dB Q 1\nFilter 2: ON LSC Fc 60 Hz Gain -4 dB Q 0.7")
        let m = EQInterchange.map(p, base: base())
        XCTAssertEqual(m.profile.bands.count, 8)
        let freqs = m.profile.bands.map(\.freq)
        XCTAssertEqual(freqs, freqs.sorted())
        XCTAssertTrue(freqs.contains(3000) && freqs.contains(60))
        XCTAssertEqual(m.profile.bands.filter { $0.gain != 0 }.count, 2)
        XCTAssertEqual(m.profile.bands.map(\.id), Array(0..<8))
        XCTAssertEqual(m.profile.bands.first { $0.freq == 60 }?.type, 0)
        // Padding avoids the centres already covered by the file (55 ~ 60, 3300 ~ 3000).
        XCTAssertFalse(freqs.contains(55))
        XCTAssertFalse(freqs.contains(3300))
        XCTAssertTrue(m.warnings.isEmpty)
    }

    func testEmptyFileMapsToDefaults() {
        let m = EQInterchange.map(ParsedEQ(), base: base())
        XCTAssertEqual(m.profile.bands.map(\.freq), [55, 110, 220, 440, 1320, 3300, 6600, 13200])
        XCTAssertTrue(m.profile.bands.allSatisfy { $0.gain == 0 && $0.type == 1 })
    }

    func testMoreThanEightKeepsLargestGains() {
        // Gains 1...10 dB (alternating sign) at increasing frequencies: the two smallest must be dropped.
        let lines = (1...10).map { "Filter \($0): ON PK Fc \($0 * 100) Hz Gain \($0 % 2 == 0 ? -$0 : $0) dB Q 1" }
        let m = EQInterchange.map(EQInterchange.parse(lines.joined(separator: "\n")), base: base())
        XCTAssertEqual(m.profile.bands.count, 8)
        XCTAssertEqual(m.profile.bands.map(\.freq), (3...10).map { Float($0 * 100) })
        XCTAssertEqual(m.warnings.count, 1)
        XCTAssertTrue(m.warnings[0].contains("2"))
    }

    func testClampingAndPreampWarning() {
        let text = "Preamp: -6.2 dB\nFilter 1: ON PK Fc 100 Hz Gain 15 dB Q 1\nFilter 2: ON PK Fc 200 Hz Gain -20 dB Q 1"
        let m = EQInterchange.map(EQInterchange.parse(text), base: base())
        XCTAssertEqual(m.profile.bands.first { $0.freq == 100 }?.gain, 12)
        XCTAssertEqual(m.profile.bands.first { $0.freq == 200 }?.gain, -12)
        XCTAssertEqual(m.warnings.count, 2)   // clamp + preamp
        XCTAssertEqual(m.profile.gain, 0)     // the preamp is not folded into the device gain field
        XCTAssertEqual(m.profile.profile, 0)
    }

    func testOutOfRangeFrequencyAndQ() {
        let p = EQInterchange.parse("Filter 1: ON PK Fc 5 Hz Gain 1 dB Q 500\nFilter 2: ON PK Fc 100 Hz Gain 1 dB Q -1")
        XCTAssertEqual(p.filters[0].freq, 20)
        XCTAssertEqual(p.filters[0].q, 20)
        XCTAssertEqual(p.filters[1].q, 1)
        XCTAssertEqual(p.warnings.count, 3)
    }

    // MARK: Export and round trip

    func testExportFormat() {
        var profile = base()
        profile.bands[0].type = 0
        profile.bands[0].gain = 3.5
        profile.bands[7].type = 2
        profile.bands[7].gain = -0.0
        profile.bands[3].gain = 2.25
        let lines = EQInterchange.export(profile).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 9)
        XCTAssertEqual(lines[0], "Preamp: 0.0 dB")
        XCTAssertEqual(lines[1], "Filter 1: ON LSC Fc 55 Hz Gain 3.5 dB Q 1.0")
        XCTAssertEqual(lines[4], "Filter 4: ON PK Fc 440 Hz Gain 2.25 dB Q 1.0")
        XCTAssertEqual(lines[8], "Filter 8: ON HSC Fc 13200 Hz Gain 0.0 dB Q 1.0")
    }

    func testRoundTrip() {
        var profile = base()
        let gains: [Float] = [4.5, -2.0, 0, 1.25, 3.0, -6.5, 12, -12]
        for i in 0..<8 { profile.bands[i].gain = gains[i] }
        profile.bands[0].type = 0
        profile.bands[7].type = 2
        profile.bands[2].q = 1.41
        profile.bands[5].freq = 3250.5

        let parsed = EQInterchange.parse(EQInterchange.export(profile))
        XCTAssertTrue(parsed.warnings.isEmpty)
        let back = EQInterchange.map(parsed, base: base())
        XCTAssertTrue(back.warnings.isEmpty)
        XCTAssertEqual(back.profile.bands.count, 8)
        for (a, b) in zip(profile.bands, back.profile.bands) {
            XCTAssertEqual(a.type, b.type)
            XCTAssertEqual(a.gain, b.gain, accuracy: 0.01)
            XCTAssertEqual(a.freq, b.freq, accuracy: 0.1)
            XCTAssertEqual(a.q, b.q, accuracy: 0.01)
        }
    }

    // MARK: GraphicEQ

    func testGraphicEQSampling() {
        // Flat -2 dB up to 100 Hz, then linear in log-frequency to +4 dB at 10 kHz, flat after.
        let p = EQInterchange.parse("GraphicEQ: 20 -2; 100 -2; 10000 4; 20000 4")
        XCTAssertEqual(p.filters.count, 8)
        XCTAssertEqual(p.filters.map(\.freq), EQInterchange.defaultFrequencies)
        XCTAssertEqual(p.filters[0].gain, -2, accuracy: 1e-9)
        XCTAssertEqual(p.filters[1].gain, -2 + 6 * log(1.1) / log(100), accuracy: 1e-9)
        XCTAssertEqual(p.filters[5].gain, -2 + 6 * log(33) / log(100), accuracy: 1e-9)
        XCTAssertEqual(p.filters[7].gain, 4, accuracy: 1e-9)
        XCTAssertTrue(p.filters.allSatisfy { $0.type == .peaking })
        XCTAssertEqual(p.warnings.count, 1)
    }

    func testGraphicEQQuirks() {
        let p = EQInterchange.parse("GraphicEQ: 25 -3,0; 40 -2,5; 63 -1;100 0 ; bogus; 16000 2")
        XCTAssertEqual(p.filters.count, 8)
        // 55 Hz lies between the points at 40 (-2.5) and 63 (-1).
        XCTAssertEqual(p.filters[0].gain, -2.5 + 1.5 * log(55.0 / 40) / log(63.0 / 40), accuracy: 1e-9)
        XCTAssertEqual(p.warnings.count, 2)   // unreadable point + sampling note
    }

    func testFiltersWinOverGraphicEQ() {
        let p = EQInterchange.parse("Filter 1: ON PK Fc 100 Hz Gain 1 dB Q 1\nGraphicEQ: 25 -3; 40 -2")
        XCTAssertEqual(p.filters.count, 1)
        XCTAssertEqual(p.warnings.count, 1)
    }
}
