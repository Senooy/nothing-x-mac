import XCTest
@testable import NothingX

final class LowBatteryRuleTests: XCTestCase {
    func testFiresAtThresholdAndBelow() {
        var r = LowBatteryRule()
        XCTAssertFalse(r.evaluate(level: 21, charging: false, threshold: 20))
        XCTAssertTrue(r.evaluate(level: 20, charging: false, threshold: 20), "level == threshold fires")

        var r2 = LowBatteryRule()
        XCTAssertTrue(r2.evaluate(level: 5, charging: false, threshold: 20), "well below fires too")
    }

    func testDoesNotRepeatWhileStillLow() {
        var r = LowBatteryRule()
        XCTAssertTrue(r.evaluate(level: 20, charging: false, threshold: 20))
        for level in [19, 18, 12, 5, 0] {
            XCTAssertFalse(r.evaluate(level: level, charging: false, threshold: 20), "repeat at \(level)")
        }
        XCTAssertFalse(r.armed)
    }

    func testRearmsOnlyAboveThresholdPlusMargin() {
        var r = LowBatteryRule()
        XCTAssertTrue(r.evaluate(level: 15, charging: false, threshold: 20))
        // Exactly threshold + margin (30) is not enough: it has to be strictly above.
        XCTAssertFalse(r.evaluate(level: 30, charging: false, threshold: 20))
        XCTAssertFalse(r.armed)
        XCTAssertFalse(r.evaluate(level: 31, charging: false, threshold: 20), "re-arms, but the level is fine")
        XCTAssertTrue(r.armed)
        XCTAssertTrue(r.evaluate(level: 20, charging: false, threshold: 20), "fires again in the next cycle")
    }

    func testBatteryWobbleAroundThresholdDoesNotRetrigger() {
        var r = LowBatteryRule()
        XCTAssertTrue(r.evaluate(level: 20, charging: false, threshold: 20))
        for level in [21, 22, 25, 20, 19, 25, 29, 18] {
            XCTAssertFalse(r.evaluate(level: level, charging: false, threshold: 20), "wobble \(level)")
        }
    }

    func testChargingNeverFires() {
        var r = LowBatteryRule()
        for level in [100, 50, 20, 10, 1, 0] {
            XCTAssertFalse(r.evaluate(level: level, charging: true, threshold: 20))
        }
    }

    func testChargingRearms() {
        var r = LowBatteryRule()
        XCTAssertTrue(r.evaluate(level: 18, charging: false, threshold: 20))
        XCTAssertFalse(r.evaluate(level: 18, charging: false, threshold: 20))
        XCTAssertFalse(r.evaluate(level: 19, charging: true, threshold: 20))
        XCTAssertTrue(r.armed)
    }

    func testUnpluggingWhileStillLowFires() {
        var r = LowBatteryRule()
        XCTAssertFalse(r.evaluate(level: 12, charging: true, threshold: 20))
        XCTAssertTrue(r.evaluate(level: 12, charging: false, threshold: 20),
                      "charging barely began, then unplugged below the threshold")
        XCTAssertFalse(r.evaluate(level: 11, charging: false, threshold: 20))
    }

    func testThresholdChangeRearms() {
        var r = LowBatteryRule()
        XCTAssertTrue(r.evaluate(level: 18, charging: false, threshold: 20))
        XCTAssertFalse(r.evaluate(level: 18, charging: false, threshold: 20))
        // Switching to 10 re-arms, but 18 is above 10: nothing yet.
        XCTAssertFalse(r.evaluate(level: 18, charging: false, threshold: 10))
        XCTAssertTrue(r.armed)
        XCTAssertTrue(r.evaluate(level: 10, charging: false, threshold: 10))
        XCTAssertFalse(r.evaluate(level: 9, charging: false, threshold: 10))
        // Back to 20 while at 9: the new choice is judged on its own and fires at once.
        XCTAssertTrue(r.evaluate(level: 9, charging: false, threshold: 20))
    }

    func testSameThresholdDoesNotRearm() {
        var r = LowBatteryRule()
        XCTAssertTrue(r.evaluate(level: 10, charging: false, threshold: 10))
        XCTAssertFalse(r.evaluate(level: 10, charging: false, threshold: 10))
        XCTAssertFalse(r.armed)
    }

    func testNilLevelChangesNothing() {
        var r = LowBatteryRule()
        XCTAssertFalse(r.evaluate(level: nil, charging: false, threshold: 20))
        XCTAssertTrue(r.armed, "an unknown level does not disarm")
        XCTAssertTrue(r.evaluate(level: 10, charging: false, threshold: 20))
        XCTAssertFalse(r.evaluate(level: nil, charging: false, threshold: 20))
        XCTAssertFalse(r.armed, "an unknown level does not re-arm")
        XCTAssertFalse(r.evaluate(level: nil, charging: true, threshold: 20))
        XCTAssertFalse(r.armed, "nil is ignored even when charging")
        XCTAssertFalse(r.evaluate(level: 10, charging: false, threshold: 20))
    }

    func testThresholdChangeWithNilLevelStillRearms() {
        var r = LowBatteryRule()
        XCTAssertTrue(r.evaluate(level: 10, charging: false, threshold: 20))
        XCTAssertFalse(r.evaluate(level: nil, charging: false, threshold: 10))
        XCTAssertTrue(r.armed)
        XCTAssertTrue(r.evaluate(level: 10, charging: false, threshold: 10))
    }

    func testConstants() {
        XCTAssertEqual(LowBatteryRule.allowedThresholds, [20, 10])
        XCTAssertTrue(LowBatteryRule.allowedThresholds.contains(LowBatteryRule.defaultThreshold))
        XCTAssertEqual(LowBatteryRule.rearmMargin, 10)
    }
}

final class ConnectionNotificationRuleTests: XCTestCase {
    func testSuppressedDuringStartupGrace() {
        var r = ConnectionNotificationRule()
        XCTAssertFalse(r.evaluate(connected: true, uptime: 0))
        XCTAssertFalse(r.evaluate(connected: true, uptime: 7.99))
        XCTAssertFalse(r.evaluate(connected: true, uptime: 20), "already connected: no edge")
    }

    func testFiresOnEdgeAtGrace() {
        var r = ConnectionNotificationRule()
        XCTAssertFalse(r.evaluate(connected: false, uptime: 1))
        XCTAssertTrue(r.evaluate(connected: true, uptime: ConnectionNotificationRule.startupGrace))
    }

    func testNoFireJustBeforeGrace() {
        var r = ConnectionNotificationRule()
        XCTAssertFalse(r.evaluate(connected: false, uptime: 1))
        XCTAssertFalse(r.evaluate(connected: true, uptime: 7.999))
    }

    func testNeverTwiceWhileConnected() {
        var r = ConnectionNotificationRule()
        XCTAssertFalse(r.evaluate(connected: false, uptime: 10))
        XCTAssertTrue(r.evaluate(connected: true, uptime: 11))
        for t in stride(from: 12.0, through: 60.0, by: 6.0) {
            XCTAssertFalse(r.evaluate(connected: true, uptime: t))
        }
    }

    func testFiresAgainAfterReconnect() {
        var r = ConnectionNotificationRule()
        XCTAssertFalse(r.evaluate(connected: false, uptime: 10))
        XCTAssertTrue(r.evaluate(connected: true, uptime: 11))
        XCTAssertFalse(r.evaluate(connected: false, uptime: 30), "a disconnect never notifies")
        XCTAssertTrue(r.evaluate(connected: true, uptime: 40))
    }

    func testStartupConnectionIsSwallowedButLaterReconnectFires() {
        var r = ConnectionNotificationRule()
        XCTAssertFalse(r.evaluate(connected: true, uptime: 2), "initial connection at startup")
        XCTAssertFalse(r.evaluate(connected: false, uptime: 5))
        XCTAssertFalse(r.evaluate(connected: true, uptime: 6), "reconnect still inside the grace")
        XCTAssertFalse(r.evaluate(connected: false, uptime: 9))
        XCTAssertTrue(r.evaluate(connected: true, uptime: 9.5))
    }

    func testStateIsTrackedEvenWhenCallerIgnoresTheResult() {
        var r = ConnectionNotificationRule()
        _ = r.evaluate(connected: true, uptime: 20)
        _ = r.evaluate(connected: false, uptime: 21)
        XCTAssertTrue(r.evaluate(connected: true, uptime: 22))
    }
}
