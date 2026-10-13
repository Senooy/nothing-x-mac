import XCTest
@testable import NothingX

final class HeadPoseFilterTests: XCTestCase {
    private let halfTurn = 1_073_741_824.0                      // 2^30 units = 180 degrees of yaw
    private let tiltUnitsPerDegree = (Double.pi / 180) * 536_870_912.0   // 2^-29 rad per unit

    /// A 16-byte `E015` payload: pitch, roll, yaw as little-endian Int32, then a Float32 confidence.
    private func payload(yaw: Double = 0, pitch: Double = 0, roll: Double = 0, settled: Float = 0) -> [UInt8] {
        func le(_ v: Int32) -> [UInt8] {
            let u = UInt32(bitPattern: v)
            return [UInt8(u & 0xFF), UInt8((u >> 8) & 0xFF), UInt8((u >> 16) & 0xFF), UInt8(u >> 24)]
        }
        func units(_ degrees: Double, _ perDegree: Double) -> Int32 { Int32((degrees * perDegree).rounded()) }
        return le(units(pitch, tiltUnitsPerDegree)) + le(units(roll, tiltUnitsPerDegree))
            + le(units(yaw, halfTurn / 180)) + le(Int32(bitPattern: settled.bitPattern))
    }

    /// Smallest absolute angular distance between two directions, in degrees.
    private func circularDistance(_ a: Double, _ b: Double) -> Double {
        let d = (a - b).truncatingRemainder(dividingBy: 360)
        return min(abs(d), 360 - abs(d))
    }

    /// Settles the display smoothing so `orientation` returns the target (long dt makes alpha ~ 1).
    private func settle(_ f: HeadPoseFilter, at now: Double, sensitivity: Double = 1) -> HeadPoseFilter.Angles {
        _ = f.orientation(now: now, sensitivity: sensitivity)
        return f.orientation(now: now + 100, sensitivity: sensitivity)
    }

    // MARK: Scale and signs

    func testYawHalfTurnIsOneEightyDegrees() {
        let f = HeadPoseFilter()
        f.ingest(payload(), now: 1)                         // reference
        f.ingest(payload(yaw: 90), now: 2)
        XCTAssertEqual(f.current.yaw, 90, accuracy: 1e-3)
        XCTAssertEqual(f.current.pitch, 0, accuracy: 1e-6)

        // And literally 2^30 units from the reference is 180 degrees.
        let g = HeadPoseFilter()
        var half = [UInt8](repeating: 0, count: 16)
        g.ingest(half, now: 1)
        half[8] = 0x00; half[9] = 0x00; half[10] = 0x00; half[11] = 0x40   // 0x40000000 = 2^30
        g.ingest(half, now: 2)
        XCTAssertEqual(abs(g.current.yaw), 180, accuracy: 1e-6)
    }

    func testSignConventions() {
        let f = HeadPoseFilter()
        f.ingest(payload(), now: 1)
        f.ingest(payload(yaw: 30, pitch: 20, roll: 10), now: 2)
        XCTAssertEqual(f.current.yaw, 30, accuracy: 1e-3, "yaw + = left")
        XCTAssertEqual(f.current.pitch, 20, accuracy: 1e-3, "pitch + = up")
        XCTAssertEqual(f.current.roll, 10, accuracy: 1e-3, "roll + = right shoulder")

        f.ingest(payload(yaw: -45, pitch: -15, roll: -5), now: 3)
        XCTAssertEqual(f.current.yaw, -45, accuracy: 1e-3)
        XCTAssertEqual(f.current.pitch, -15, accuracy: 1e-3)
        XCTAssertEqual(f.current.roll, -5, accuracy: 1e-3)
    }

    func testLittleEndianWordOrder() {
        // pitch word = 1 << 8 only; if the three words were swapped the other angles would move.
        var bytes = [UInt8](repeating: 0, count: 16)
        let f = HeadPoseFilter()
        f.ingest(bytes, now: 1)
        bytes[1] = 1   // pitch word = 256
        f.ingest(bytes, now: 2)
        XCTAssertEqual(f.current.pitch, 256 / tiltUnitsPerDegree, accuracy: 1e-9)
        XCTAssertEqual(f.current.roll, 0)
        XCTAssertEqual(f.current.yaw, 0)
    }

    func testFirstSampleIsTheReference() {
        let f = HeadPoseFilter()
        f.ingest(payload(yaw: 120, pitch: 12, roll: -7), now: 1)
        XCTAssertEqual(f.current, HeadPoseFilter.Angles())
        XCTAssertEqual(f.sampleCount, 1)
    }

    func testShortPayloadIsIgnored() {
        let f = HeadPoseFilter()
        f.ingest([UInt8](repeating: 0, count: 15), now: 1)
        XCTAssertEqual(f.sampleCount, 0)
        XCTAssertEqual(f.current, HeadPoseFilter.Angles())
    }

    func testSettledConfidenceIsClampedAndSanitised() {
        let f = HeadPoseFilter()
        f.ingest(payload(settled: 1), now: 1)
        XCTAssertEqual(f.settled, 1, accuracy: 1e-9)
        f.ingest(payload(settled: 7), now: 2)
        XCTAssertEqual(f.settled, 1, accuracy: 1e-9)
        f.ingest(payload(settled: -3), now: 3)
        XCTAssertEqual(f.settled, 0, accuracy: 1e-9)
        f.ingest(payload(settled: .nan), now: 4)
        XCTAssertEqual(f.settled, 0, accuracy: 1e-9)
        f.ingest(payload(settled: .infinity), now: 5)
        XCTAssertEqual(f.settled, 0, accuracy: 1e-9)
    }

    func testSensitivityScalesOutput() {
        let f = HeadPoseFilter()
        f.ingest(payload(), now: 1)
        f.ingest(payload(yaw: 20, pitch: 10, roll: 6), now: 2)
        f.ingest(payload(yaw: 20, pitch: 10, roll: 6), now: 3)     // head still: no extrapolation
        let one = settle(f, at: 3, sensitivity: 1)
        XCTAssertEqual(one.yaw, 20, accuracy: 1e-2)
        XCTAssertEqual(one.pitch, 10, accuracy: 1e-2)
        let g = HeadPoseFilter()
        g.ingest(payload(), now: 1)
        g.ingest(payload(yaw: 20, pitch: 10, roll: 6), now: 2)
        g.ingest(payload(yaw: 20, pitch: 10, roll: 6), now: 3)
        let two = settle(g, at: 3, sensitivity: 2)
        XCTAssertEqual(two.yaw, 40, accuracy: 2e-2)
        XCTAssertEqual(two.pitch, 20, accuracy: 2e-2)
        XCTAssertEqual(two.roll, 12, accuracy: 2e-2)
    }

    func testOrientationBeforeAnySampleIsZero() {
        XCTAssertEqual(HeadPoseFilter().orientation(now: 5, sensitivity: 1), HeadPoseFilter.Angles())
    }

    // MARK: Continuity across the back (+-180 degrees)

    func testCurrentWrapsIntoPlusMinus180() {
        let f = HeadPoseFilter()
        f.ingest(payload(), now: 1)
        f.ingest(payload(yaw: 170), now: 2)
        XCTAssertEqual(f.current.yaw, 170, accuracy: 1e-3)
        f.ingest(payload(yaw: 190), now: 3)
        XCTAssertEqual(f.current.yaw, -170, accuracy: 1e-3, "190 degrees is the same direction as -170")
    }

    func testDisplayedYawCrossesTheBackWithoutJumpOrLongWaySweep() {
        let f = HeadPoseFilter()
        f.ingest(payload(), now: 0.9)
        // Head turns left through the back at 30 degrees per 0.1 s sample: 150, 170, 190 (= -170), 210 ...
        let yaws: [Double] = [150, 170, 190, 210, 230, 250]
        var previousOut: Double?
        var minAbsNearBack = Double.infinity
        var t = 1.0
        for (i, yaw) in yaws.enumerated() {
            // The raw word wraps at +-360, like the headphone's Int32: send the wrapped value.
            let wireYaw = yaw > 180 ? yaw - 360 : yaw
            f.ingest(payload(yaw: wireYaw), now: t)
            // Render at ~60 Hz until the next sample.
            for k in 0..<6 {
                let out = f.orientation(now: t + Double(k) / 60, sensitivity: 1).yaw
                if i > 0 {
                    if let p = previousOut {
                        XCTAssertLessThan(circularDistance(out, p), 25, "jump at sample \(i), tick \(k): \(p) -> \(out)")
                    }
                    minAbsNearBack = min(minAbsNearBack, abs(out))
                }
                previousOut = out
            }
            t += 0.1
        }
        // A long-way sweep would pass through values near 0; going through the back stays beyond 100.
        XCTAssertGreaterThan(minAbsNearBack, 100)
    }

    func testCrossingBackInTheOtherDirection() {
        let f = HeadPoseFilter()
        f.ingest(payload(), now: 0.9)
        var previousOut: Double?
        var t = 1.0
        for yaw in stride(from: -150.0, through: -250.0, by: -20) {
            let wireYaw = yaw < -180 ? yaw + 360 : yaw
            f.ingest(payload(yaw: wireYaw), now: t)
            for k in 0..<6 {
                let out = f.orientation(now: t + Double(k) / 60, sensitivity: 1).yaw
                if let p = previousOut, yaw < -150 {
                    XCTAssertLessThan(circularDistance(out, p), 25, "jump \(p) -> \(out)")
                    XCTAssertGreaterThan(abs(out), 100)
                }
                previousOut = out
            }
            t += 0.1
        }
    }

    func testUnwrappedYawKeepsCountingAfterSeveralTurns() {
        let f = HeadPoseFilter()
        f.ingest(payload(), now: 1)
        var t = 1.1
        var previousOut = 0.0
        // Full turn and a half in steps of 20 degrees.
        for deg in stride(from: 20.0, through: 540.0, by: 20) {
            var wire = deg.truncatingRemainder(dividingBy: 360)
            if wire > 180 { wire -= 360 }
            f.ingest(payload(yaw: wire), now: t)
            let out = settle(f, at: t).yaw
            if deg > 20 { XCTAssertLessThanOrEqual(circularDistance(out, previousOut), 20 + 1e-2, "at \(deg)") }
            previousOut = out
            t += 1000   // settle() advanced the tick clock by 100 s
        }
    }

    // MARK: Recenter

    func testRecenterMakesCurrentDirectionZero() {
        let f = HeadPoseFilter()
        f.ingest(payload(), now: 1)
        f.ingest(payload(yaw: 40, pitch: 10, roll: -6), now: 2)
        f.recenter()
        XCTAssertEqual(f.current.yaw, 0, accuracy: 1e-6)
        XCTAssertEqual(f.current.pitch, 0, accuracy: 1e-6)
        XCTAssertEqual(f.current.roll, 0, accuracy: 1e-6)
        let out = f.orientation(now: 2.01, sensitivity: 1)
        XCTAssertEqual(out.yaw, 0, accuracy: 1e-6)
        XCTAssertEqual(out.pitch, 0, accuracy: 1e-6)

        // Turning further is measured from the new direction, and coming back reads zero again.
        f.ingest(payload(yaw: 55, pitch: 10, roll: -6), now: 3)
        XCTAssertEqual(f.current.yaw, 15, accuracy: 1e-3)
        f.ingest(payload(yaw: 40, pitch: 10, roll: -6), now: 4)
        XCTAssertEqual(f.current.yaw, 0, accuracy: 1e-3)
        XCTAssertEqual(f.current.pitch, 0, accuracy: 1e-3)
    }

    func testRecenterTwiceAccumulates() {
        let f = HeadPoseFilter()
        f.ingest(payload(), now: 1)
        f.ingest(payload(yaw: 30), now: 2)
        f.recenter()
        f.ingest(payload(yaw: 50), now: 3)
        f.recenter()
        f.ingest(payload(yaw: 60), now: 4)
        XCTAssertEqual(f.current.yaw, 10, accuracy: 1e-3)
    }

    func testRecenterAfterCrossingTheBack() {
        let f = HeadPoseFilter()
        f.ingest(payload(), now: 1)
        f.ingest(payload(yaw: 120), now: 2)
        f.ingest(payload(yaw: -160), now: 3)       // 200 degrees round the back
        f.recenter()
        XCTAssertEqual(f.current.yaw, 0, accuracy: 1e-6)
        f.ingest(payload(yaw: -150), now: 4)
        XCTAssertEqual(f.current.yaw, 10, accuracy: 1e-3)
    }

    func testRecenterBeforeAnySampleDoesNothingHarmful() {
        let f = HeadPoseFilter()
        f.recenter()
        f.ingest(payload(yaw: 77), now: 1)
        XCTAssertEqual(f.current.yaw, 0, accuracy: 1e-6, "first sample still becomes the reference")
        f.ingest(payload(yaw: 80), now: 2)
        XCTAssertEqual(f.current.yaw, 3, accuracy: 1e-3)
    }

    func testResetForgetsEverything() {
        let f = HeadPoseFilter()
        f.ingest(payload(yaw: 10), now: 1)
        f.ingest(payload(yaw: 50, settled: 1), now: 2)
        f.reset()
        XCTAssertEqual(f.sampleCount, 0)
        XCTAssertEqual(f.settled, 0)
        XCTAssertEqual(f.current, HeadPoseFilter.Angles())
        f.ingest(payload(yaw: 99), now: 3)
        XCTAssertEqual(f.current.yaw, 0, accuracy: 1e-6)
    }

    // MARK: Auto-recenter (yaw drift)

    func testDriftIsCancelledWhileSettledAndNearReference() {
        let f = HeadPoseFilter()
        f.ingest(payload(settled: 1), now: 1)
        // 25 s later (one time constant) the reference has moved 1 - e^-1 of the 10 degree offset.
        f.ingest(payload(yaw: 10, settled: 1), now: 26)
        let expected = 10 * exp(-1.0)
        XCTAssertEqual(f.current.yaw, expected, accuracy: 1e-3)
    }

    func testDriftIsCancelledForNegativeOffsetsToo() {
        let f = HeadPoseFilter()
        f.ingest(payload(settled: 0.9), now: 1)
        f.ingest(payload(yaw: -10, settled: 0.9), now: 26)
        XCTAssertEqual(f.current.yaw, -10 * exp(-1.0), accuracy: 1e-3)
    }

    func testNoAutoRecenterWhenNotSettled() {
        let f = HeadPoseFilter()
        f.ingest(payload(settled: 1), now: 1)
        f.ingest(payload(yaw: 10, settled: 0.5), now: 26)
        XCTAssertEqual(f.current.yaw, 10, accuracy: 1e-3)
        let g = HeadPoseFilter()
        g.ingest(payload(settled: 1), now: 1)
        g.ingest(payload(yaw: 10, settled: 0), now: 26)
        XCTAssertEqual(g.current.yaw, 10, accuracy: 1e-3)
    }

    func testNoAutoRecenterOutsideTheTwentyDegreeWindow() {
        let f = HeadPoseFilter()
        f.ingest(payload(settled: 1), now: 1)
        // Looking at a second screen, still head: the anchor must not follow.
        f.ingest(payload(yaw: 35, settled: 1), now: 26)
        XCTAssertEqual(f.current.yaw, 35, accuracy: 1e-3)
        f.ingest(payload(yaw: 35, settled: 1), now: 1000)
        XCTAssertEqual(f.current.yaw, 35, accuracy: 1e-3, "staying there never drags the anchor along")
        f.ingest(payload(yaw: 20.5, settled: 1), now: 2000)
        XCTAssertEqual(f.current.yaw, 20.5, accuracy: 1e-3, "just outside the window")
        let inside = HeadPoseFilter()
        inside.ingest(payload(settled: 1), now: 1)
        inside.ingest(payload(yaw: 19, settled: 1), now: 26)
        XCTAssertEqual(inside.current.yaw, 19 * exp(-1.0), accuracy: 1e-3, "just inside the window")
    }

    func testWindowAppliesAroundTheReferenceAcrossTheBack() {
        // Reference faces the Mac; a head looking behind (about 180 degrees) is far outside the window.
        let f = HeadPoseFilter()
        f.ingest(payload(settled: 1), now: 1)
        f.ingest(payload(yaw: 179, settled: 1), now: 26)
        XCTAssertEqual(f.current.yaw, 179, accuracy: 1e-3)
    }

    func testPitchAndRollAreNeverAutoRecentred() {
        let f = HeadPoseFilter()
        f.ingest(payload(settled: 1), now: 1)
        f.ingest(payload(yaw: 0, pitch: 15, roll: -8, settled: 1), now: 100)
        f.ingest(payload(yaw: 0, pitch: 15, roll: -8, settled: 1), now: 5000)
        XCTAssertEqual(f.current.pitch, 15, accuracy: 1e-3)
        XCTAssertEqual(f.current.roll, -8, accuracy: 1e-3)
    }

    func testAutoRecenterNeedsAPreviousSampleTime() {
        // The very first update after the reference has no elapsed time to integrate.
        let f = HeadPoseFilter()
        f.ingest(payload(settled: 1), now: 0)
        f.ingest(payload(yaw: 10, settled: 1), now: 25)
        XCTAssertEqual(f.current.yaw, 10, accuracy: 1e-3, "latestTime was 0, so no correction yet")
    }

    func testLongGapFullyAbsorbsSmallDriftOnlyWhenSettled() {
        let f = HeadPoseFilter()
        f.ingest(payload(settled: 1), now: 1)
        f.ingest(payload(yaw: 5, settled: 1), now: 1001)   // 1000 s: k ~ 1
        XCTAssertEqual(f.current.yaw, 0, accuracy: 1e-3)
    }

    // MARK: Smoothing and extrapolation at 10 Hz

    func testSparseSamplesAreSmoothedMonotonically() {
        let f = HeadPoseFilter()
        f.ingest(payload(), now: 0.9)
        var t = 1.0
        var yaw = 0.0
        var last = -Double.infinity
        var series: [Double] = []
        // 10 Hz samples, constant 40 degrees per second, rendered at 60 Hz.
        for _ in 0..<30 {
            yaw += 4
            f.ingest(payload(yaw: yaw), now: t)
            for k in 0..<6 {
                let out = f.orientation(now: t + Double(k) / 60, sensitivity: 1).yaw
                XCTAssertGreaterThanOrEqual(out, last - 1e-9, "went backwards at t=\(t + Double(k) / 60)")
                last = out
                series.append(out)
            }
            t += 0.1
        }
        // It follows the head: within a fraction of one sample step of the newest sample.
        XCTAssertEqual(last, yaw, accuracy: 6)
        // And it moves in small increments (no stair-stepping at the 10 Hz sample rate).
        let steps = zip(series.dropFirst(), series).map { $0 - $1 }
        XCTAssertLessThan(steps.max() ?? 0, 4, "no step bigger than one whole sample")
    }

    func testSmoothedOutputConvergesToAStationaryHead() {
        let f = HeadPoseFilter()
        f.ingest(payload(), now: 0)
        f.ingest(payload(yaw: 30, pitch: 12), now: 1)
        f.ingest(payload(yaw: 30, pitch: 12), now: 1.1)      // head still: zero velocity
        var t = 1.1
        var out = HeadPoseFilter.Angles()
        for _ in 0..<120 {
            out = f.orientation(now: t, sensitivity: 1)
            t += 1.0 / 60
        }
        XCTAssertEqual(out.yaw, 30, accuracy: 0.05)
        XCTAssertEqual(out.pitch, 12, accuracy: 0.05)
    }

    func testExtrapolationIsCappedToTwelveHundredthsOfASecond() {
        let f = HeadPoseFilter()
        f.ingest(payload(), now: 1)
        f.ingest(payload(yaw: 10), now: 1.1)     // 100 degrees per second
        // Rendering long after the last sample must not keep extrapolating: converge to latest + 0.12 * v.
        let out = settle(f, at: 1.1).yaw
        XCTAssertEqual(out, 10 + 100 * 0.12, accuracy: 1e-2)
    }

    func testExtrapolatedVelocityIsClamped() {
        let f = HeadPoseFilter()
        f.ingest(payload(), now: 1)
        f.ingest(payload(yaw: 90), now: 1.1)     // 900 deg/s -> clamped to 400
        let out = settle(f, at: 1.1).yaw
        XCTAssertEqual(out, 90 + 400 * 0.12, accuracy: 1e-2)
    }

    func testNoExtrapolationWithoutTwoSamples() {
        let f = HeadPoseFilter()
        f.ingest(payload(), now: 1)
        f.ingest(payload(yaw: 10), now: 2)
        f.recenter()                              // drops the previous sample, latest becomes zero
        XCTAssertEqual(settle(f, at: 2).yaw, 0, accuracy: 1e-9, "no velocity estimate: no extrapolation")
    }
}
