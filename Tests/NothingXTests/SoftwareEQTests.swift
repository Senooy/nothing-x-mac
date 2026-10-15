import AVFoundation
import XCTest
@testable import NothingX

final class SoftwareEQTests: XCTestCase {
    // MARK: Band mapping

    func testFilterTypes() {
        XCTAssertEqual(SoftwareEQ.filterType(0), .lowShelf)
        XCTAssertEqual(SoftwareEQ.filterType(1), .parametric)
        XCTAssertEqual(SoftwareEQ.filterType(2), .highShelf)
        XCTAssertEqual(SoftwareEQ.filterType(9), .parametric, "unknown types fall back to peaking")
    }

    func testBandwidthFromQ() {
        XCTAssertEqual(SoftwareEQ.bandwidth(q: 1), 1.3885, accuracy: 0.001)
        XCTAssertEqual(SoftwareEQ.bandwidth(q: Float(2).squareRoot()), 1.0, accuracy: 0.001)
        XCTAssertEqual(SoftwareEQ.bandwidth(q: 0.7), 1.9169, accuracy: 0.001)
        XCTAssertEqual(SoftwareEQ.bandwidth(q: 100), 0.05, "clamped to AVAudioUnitEQ's minimum")
        XCTAssertEqual(SoftwareEQ.bandwidth(q: 0.01), 5, "clamped to AVAudioUnitEQ's maximum")
        XCTAssertEqual(SoftwareEQ.bandwidth(q: 0), 5)
        XCTAssertEqual(SoftwareEQ.bandwidth(q: .nan), 5)
    }

    func testParametersForBand() {
        let band = EQBand(id: 3, type: 0, gain: 4.5, freq: 440, q: 1)
        let p = SoftwareEQ.parameters(for: band)
        XCTAssertEqual(p.filterType, .lowShelf)
        XCTAssertEqual(p.frequency, 440)
        XCTAssertEqual(p.bandwidth, 1.3885, accuracy: 0.001)
        XCTAssertEqual(p.gain, 4.5)
    }

    func testParametersClampGainAndFrequency() {
        XCTAssertEqual(SoftwareEQ.parameters(for: EQBand(id: 0, type: 1, gain: 20, freq: 55, q: 1)).gain, 12)
        XCTAssertEqual(SoftwareEQ.parameters(for: EQBand(id: 0, type: 1, gain: -40, freq: 55, q: 1)).gain, -12)
        XCTAssertEqual(SoftwareEQ.parameters(for: EQBand(id: 0, type: 1, gain: .infinity, freq: 55, q: 1)).gain, 0)
        XCTAssertEqual(SoftwareEQ.parameters(for: EQBand(id: 0, type: 1, gain: 0, freq: 5, q: 1)).frequency, 20)
        let high = SoftwareEQ.parameters(for: EQBand(id: 0, type: 2, gain: 0, freq: 40_000, q: 1), sampleRate: 48_000)
        XCTAssertLessThan(high.frequency, 24_000, "kept below Nyquist")
    }

    // MARK: Headroom

    func testHeadroom() {
        XCTAssertEqual(SoftwareEQ.headroom([0, 0, 0, 0, 0, 0, 0, 0]), 0)
        XCTAssertEqual(SoftwareEQ.headroom([-3, -2, 0, -6, 0, 0, 0, -1]), 0, "cuts need no headroom")
        XCTAssertEqual(SoftwareEQ.headroom([-3, -2, 0, 2, 4, 3, 0, -2]), -4)
        XCTAssertEqual(SoftwareEQ.headroom(EQPreset.bass.gains!), -6)
        XCTAssertEqual(SoftwareEQ.headroom([30, 0]), -12, "uses the clamped gain")
        XCTAssertEqual(SoftwareEQ.headroom([]), 0)
    }

    // MARK: Ramp

    func testRampStep() {
        let start: [Float] = [0, 0, 6, 0.5]
        let target: [Float] = [12, -3, 6, 0]
        let one = SoftwareEQ.step(start, toward: target, maxStep: 1)
        XCTAssertEqual(one, [1, -1, 6, 0])
        var current = start
        var ticks = 0
        while current != target && ticks < 100 { current = SoftwareEQ.step(current, toward: target, maxStep: 1); ticks += 1 }
        XCTAssertEqual(current, target)
        XCTAssertEqual(ticks, 12, "a 12 dB jump takes 12 one-dB steps")
        XCTAssertEqual(SoftwareEQ.step([0], toward: [1, 2], maxStep: 1), [1, 2], "mismatched sizes jump to the target")
    }

    // MARK: Local profile

    func testDefaultProfile() {
        let p = SoftwareEQ.profile(gains: EQPreset.balanced.gains!)
        XCTAssertEqual(p.bands.map(\.freq), [55, 110, 220, 440, 1320, 3300, 6600, 13200])
        XCTAssertEqual(p.bands.map(\.id), Array(0..<8))
        XCTAssertTrue(p.bands.allSatisfy { $0.type == 1 && $0.q == 1 && $0.gain == 0 })
        XCTAssertEqual(EQProfile.decode(p.encode()), p, "persisted with the headphone's own layout")
    }

    func testProfileClampsAndPads() {
        let p = SoftwareEQ.profile(gains: [15, -20])
        XCTAssertEqual(p.bands.count, 8)
        XCTAssertEqual(p.bands[0].gain, 12)
        XCTAssertEqual(p.bands[1].gain, -12)
        XCTAssertEqual(p.bands[7].gain, 0)
    }

    func testPresetMatching() {
        XCTAssertEqual(SoftwareEQ.preset(matching: [0, 0, 0, 0, 0, 0, 0, 0]), .balanced)
        XCTAssertEqual(SoftwareEQ.preset(matching: EQPreset.bass.gains!), .bass)
        XCTAssertEqual(SoftwareEQ.preset(matching: EQPreset.treble.gains!), .treble)
        XCTAssertEqual(SoftwareEQ.preset(matching: EQPreset.voice.gains!), .voice)
        XCTAssertEqual(SoftwareEQ.preset(matching: [1, 0, 0, 0, 0, 0, 0, 0]), .custom)
    }

    // MARK: Which EQ, and when the engine runs

    func testActivePath() {
        XCTAssertEqual(EQPath.active(isWired: true), .software)
        XCTAssertEqual(EQPath.active(isWired: false), .hardware)
    }

    func testPolicyShouldRun() {
        XCTAssertTrue(SoftwareEQPolicy.shouldRun(enabled: true, wired: true, macAnchorActive: false))
        XCTAssertFalse(SoftwareEQPolicy.shouldRun(enabled: false, wired: true, macAnchorActive: false), "default Off")
        XCTAssertFalse(SoftwareEQPolicy.shouldRun(enabled: true, wired: false, macAnchorActive: false), "only while wired")
        XCTAssertFalse(SoftwareEQPolicy.shouldRun(enabled: true, wired: true, macAnchorActive: true), "never with the Mac anchor")
    }

    func testPolicyActions() {
        // Plug with the EQ enabled → start; already starting / running → nothing.
        XCTAssertEqual(SoftwareEQPolicy.action(enabled: true, wired: true, macAnchorActive: false, active: false), .start)
        XCTAssertEqual(SoftwareEQPolicy.action(enabled: true, wired: true, macAnchorActive: false, active: true), .none)
        // Unplug → stop, the choice stays so it resumes on the next plug.
        XCTAssertEqual(SoftwareEQPolicy.action(enabled: true, wired: false, macAnchorActive: false, active: true), .stop)
        XCTAssertEqual(SoftwareEQPolicy.action(enabled: true, wired: false, macAnchorActive: false, active: false), .none)
        // Turned off while wired → stop.
        XCTAssertEqual(SoftwareEQPolicy.action(enabled: false, wired: true, macAnchorActive: false, active: true), .stop)
        XCTAssertEqual(SoftwareEQPolicy.action(enabled: false, wired: true, macAnchorActive: false, active: false), .none)
        // Mac anchor running → stop.
        XCTAssertEqual(SoftwareEQPolicy.action(enabled: true, wired: true, macAnchorActive: true, active: true), .stop)
    }
}

final class StereoRingTests: XCTestCase {
    private func write(_ ring: StereoRing, from start: Int, count: Int) {
        let l = (0..<count).map { Float(start + $0) }
        let r = l.map { -$0 }
        ring.write(l, r, count)
    }

    private func read(_ ring: StereoRing, count: Int) -> (l: [Float], r: [Float]) {
        var l = [Float](repeating: .nan, count: count), r = [Float](repeating: .nan, count: count)
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in ring.read(left: lp.baseAddress!, right: rp.baseAddress!, count) }
        }
        return (l, r)
    }

    func testSilentUntilPrefilled() {
        let ring = StereoRing()
        write(ring, from: 1, count: 512)
        let out = read(ring, count: 256)
        XCTAssertEqual(out.l, [Float](repeating: 0, count: 256))
        XCTAssertEqual(out.r, [Float](repeating: 0, count: 256))
        XCTAssertEqual(ring.fill, 512, "nothing consumed before the prefill")
    }

    func testChannelsStayInLockstep() {
        let ring = StereoRing()
        write(ring, from: 1, count: 2048)
        let out = read(ring, count: 512)
        XCTAssertEqual(out.l, (1...512).map(Float.init))
        XCTAssertEqual(out.r, out.l.map { -$0 })
        XCTAssertEqual(ring.fill, 1536)
    }

    func testUnderrunZeroFillsAndRebuffers() {
        let ring = StereoRing()
        write(ring, from: 1, count: 1024)
        let out = read(ring, count: 1500)
        XCTAssertEqual(Array(out.l.prefix(1024)), (1...1024).map(Float.init))
        XCTAssertEqual(Array(out.l.suffix(476)), [Float](repeating: 0, count: 476))
        write(ring, from: 2000, count: 100)
        XCTAssertEqual(read(ring, count: 50).l, [Float](repeating: 0, count: 50), "waits for the prefill again")
    }

    func testLatencyBounded() {
        let ring = StereoRing()
        write(ring, from: 0, count: 7000)
        XCTAssertEqual(ring.fill, 2048, "past 6144 frames the oldest are dropped")
        let out = read(ring, count: 4)
        XCTAssertEqual(out.l, [4952, 4953, 4954, 4955])
        XCTAssertEqual(out.r, [-4952, -4953, -4954, -4955])
    }

    func testReset() {
        let ring = StereoRing()
        write(ring, from: 1, count: 2048)
        ring.reset()
        XCTAssertEqual(ring.fill, 0)
        XCTAssertEqual(read(ring, count: 8).l, [Float](repeating: 0, count: 8))
    }
}
