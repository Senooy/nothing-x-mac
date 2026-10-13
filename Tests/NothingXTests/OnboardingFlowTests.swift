import XCTest
@testable import NothingX

final class OnboardingFlowTests: XCTestCase {
    /// A flow moved to `step` along the normal path: Bluetooth not asked yet for the Bluetooth step,
    /// already allowed (so Welcome jumps to Connect) for every other step.
    private func flow(at step: OnboardingStep) -> OnboardingFlow {
        if step == .bluetooth {
            var f = OnboardingFlow(bluetooth: .notAsked)
            f.handle(.next)
            return f
        }
        var f = OnboardingFlow(bluetooth: .allowed)
        while f.step != step {
            f.handle(.next)
            if f.outcome != nil { XCTFail("ran past \(step)"); break }
        }
        return f
    }

    // MARK: 1. First launch

    func testFirstLaunchPath() {
        var f = OnboardingFlow(bluetooth: .notAsked)
        XCTAssertEqual(f.step, .welcome)
        f.handle(.next)
        XCTAssertEqual(f.step, .bluetooth)
        XCTAssertFalse(f.autoAdvances)
        f.handle(.allowBluetooth)
        XCTAssertEqual(f.bluetooth, .waiting)
        XCTAssertFalse(f.autoAdvances)
        f.handle(.bluetoothChanged(.allowed))
        XCTAssertTrue(f.autoAdvances)
        f.handle(.next)
        XCTAssertEqual(f.step, .connect)
        XCTAssertFalse(f.autoAdvances)
        f.handle(.next)
        XCTAssertEqual(f.step, .notifications)
        f.handle(.next)
        XCTAssertEqual(f.step, .macAnchor)
        f.handle(.next)
        XCTAssertEqual(f.step, .done)
        XCTAssertNil(f.outcome)
        XCTAssertEqual(f.completedSteps, [.welcome, .bluetooth, .connect, .notifications, .macAnchor])
        f.handle(.next)
        XCTAssertEqual(f.outcome, .completed)
        XCTAssertEqual(f.completedSteps, Set(OnboardingStep.allCases))
    }

    // MARK: 2. Bluetooth already allowed

    func testAlreadyAllowedSkipsBluetoothStep() {
        var f = OnboardingFlow(bluetooth: .allowed)
        XCTAssertTrue(f.completedSteps.isEmpty)
        f.handle(.next)
        XCTAssertEqual(f.step, .connect)
        XCTAssertTrue(f.completedSteps.contains(.bluetooth))
        XCTAssertTrue(f.completedSteps.contains(.welcome))
        XCTAssertFalse(f.completedSteps.contains(.connect))
    }

    // MARK: 3. Next is ignored until access is allowed

    func testNextOnBluetoothIgnoredWhileWaitingOrDenied() {
        for state in [OnboardingFlow.Bluetooth.waiting, .denied] {
            var f = OnboardingFlow(bluetooth: .notAsked)
            f.handle(.next)
            f.handle(.bluetoothChanged(state))
            f.handle(.next)
            XCTAssertEqual(f.step, .bluetooth, "\(state)")
            XCTAssertFalse(f.autoAdvances)
        }
        var f = OnboardingFlow(bluetooth: .notAsked)
        f.handle(.next)
        f.handle(.next)
        XCTAssertEqual(f.step, .bluetooth, "notAsked")
    }

    func testAllowBluetoothOnlyFromNotAskedOnBluetoothStep() {
        var f = OnboardingFlow(bluetooth: .notAsked)
        f.handle(.allowBluetooth)                   // still on welcome
        XCTAssertEqual(f.bluetooth, .notAsked)
        f.handle(.next)
        f.handle(.bluetoothChanged(.denied))
        f.handle(.allowBluetooth)                   // already answered
        XCTAssertEqual(f.bluetooth, .denied)
    }

    // MARK: 4. Revoked while on Connect

    func testDeniedAtConnectRegressesThenAutoAdvancesAgain() {
        var f = flow(at: .connect)
        f.handle(.bluetoothChanged(.denied))
        XCTAssertEqual(f.step, .bluetooth)
        XCTAssertEqual(f.bluetooth, .denied)
        XCTAssertFalse(f.autoAdvances)
        f.handle(.bluetoothChanged(.allowed))
        XCTAssertTrue(f.autoAdvances)
        f.handle(.next)
        XCTAssertEqual(f.step, .connect)
    }

    func testWaitingOrNotAskedAtConnectAlsoRegress() {
        for state in [OnboardingFlow.Bluetooth.waiting, .notAsked] {
            var f = flow(at: .connect)
            f.handle(.bluetoothChanged(state))
            XCTAssertEqual(f.step, .bluetooth, "\(state)")
        }
        var f = flow(at: .connect)
        f.handle(.bluetoothChanged(.allowed))
        XCTAssertEqual(f.step, .connect)
    }

    // MARK: 5. Later steps ignore Bluetooth

    func testBluetoothChangesIgnoredAfterConnect() {
        for step in [OnboardingStep.notifications, .macAnchor, .done] {
            var f = flow(at: step)
            for state in [OnboardingFlow.Bluetooth.denied, .waiting, .notAsked, .allowed] {
                f.handle(.bluetoothChanged(state))
                XCTAssertEqual(f.step, step, "\(state)")
                XCTAssertEqual(f.bluetooth, state)
                XCTAssertFalse(f.autoAdvances)
            }
        }
    }

    // MARK: 6. Skip

    func testSkipFromEveryStepEndsTheFlow() {
        for step in OnboardingStep.allCases {
            var f = flow(at: step)
            f.handle(.skip)
            XCTAssertEqual(f.outcome, .skipped, "\(step)")
            let frozen = f
            for event in [OnboardingFlow.Event.next, .skip, .allowBluetooth, .bluetoothChanged(.denied)] {
                f.handle(event)
            }
            XCTAssertEqual(f, frozen, "\(step)")
            XCTAssertFalse(f.autoAdvances)
        }
    }

    func testEventsAfterCompletionAreIgnored() {
        var f = flow(at: .done)
        f.handle(.next)
        XCTAssertEqual(f.outcome, .completed)
        f.handle(.skip)
        XCTAssertEqual(f.outcome, .completed)
    }

    // MARK: 7. When the Bluetooth transport may start

    func testLinkShouldRun() {
        for state in [OnboardingFlow.Bluetooth.notAsked, .waiting, .denied, .allowed] {
            XCTAssertFalse(OnboardingFlow(bluetooth: state).linkShouldRun, "welcome \(state)")
        }

        var f = OnboardingFlow(bluetooth: .notAsked)
        f.handle(.next)
        XCTAssertEqual(f.step, .bluetooth)
        XCTAssertFalse(f.linkShouldRun)
        f.handle(.allowBluetooth)
        XCTAssertTrue(f.linkShouldRun)

        var denied = OnboardingFlow(bluetooth: .denied)
        denied.handle(.next)
        XCTAssertEqual(denied.step, .bluetooth)
        XCTAssertTrue(denied.linkShouldRun)

        var allowed = OnboardingFlow(bluetooth: .notAsked)
        allowed.handle(.next)
        allowed.handle(.bluetoothChanged(.allowed))
        XCTAssertTrue(allowed.linkShouldRun)

        for step in [OnboardingStep.connect, .notifications, .macAnchor, .done] {
            XCTAssertTrue(flow(at: step).linkShouldRun, "\(step)")
        }

        var skipped = OnboardingFlow(bluetooth: .notAsked)
        skipped.handle(.skip)
        XCTAssertTrue(skipped.linkShouldRun)
    }

    // MARK: 8. Presentation at launch

    func testShouldPresent() {
        XCTAssertTrue(OnboardingFlow.shouldPresent(completed: false, completedVersion: 0))
        XCTAssertFalse(OnboardingFlow.shouldPresent(completed: true, completedVersion: 1))
        XCTAssertTrue(OnboardingFlow.shouldPresent(completed: true, completedVersion: 0))
        XCTAssertFalse(OnboardingFlow.shouldPresent(completed: true, completedVersion: 2))
    }

    // MARK: 9. Steps

    func testSteps() {
        XCTAssertEqual(OnboardingStep.allCases.count, 6)
        XCTAssertEqual(OnboardingStep.allCases, [.welcome, .bluetooth, .connect, .notifications, .macAnchor, .done])
        XCTAssertEqual(OnboardingStep.allCases.map(\.rawValue), Array(0..<6))
    }
}
