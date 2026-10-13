import Foundation

/// The six steps of the first-run tour, in order.
enum OnboardingStep: Int, CaseIterable {
    case welcome, bluetooth, connect, notifications, macAnchor, done
}

/// Pure step state machine of the first-run tour. No I/O and no UI: the host view feeds it events
/// (buttons, keys, link changes) and reads back the step, the Bluetooth sub-state and the outcome.
struct OnboardingFlow: Equatable {
    /// Bump when a future onboarding must be shown again to users who completed an older one.
    static let version = 1

    /// What the tour knows about the Bluetooth permission.
    enum Bluetooth: Equatable {
        /// The system never asked and the transport is not running yet.
        case notAsked
        /// The transport runs and the macOS prompt is (or will be) on screen.
        case waiting
        case denied
        case allowed
    }

    enum Outcome: Equatable { case completed, skipped }

    enum Event: Equatable {
        case next                      // Return / primary action
        case skip                      // Esc / [Skip]
        case allowBluetooth            // [Allow Bluetooth]
        case bluetoothChanged(Bluetooth)
    }

    private(set) var step: OnboardingStep = .welcome
    private(set) var bluetooth: Bluetooth
    private(set) var outcome: Outcome?

    init(bluetooth: Bluetooth) {
        self.bluetooth = bluetooth
    }

    /// True while the view should schedule `.next` after a short beat (Bluetooth step, access allowed).
    var autoAdvances: Bool { outcome == nil && step == .bluetooth && bluetooth == .allowed }

    /// True once the Bluetooth transport must be running (see spec §1). Before that, starting it would show
    /// the macOS prompt over a screen that has not explained it yet.
    var linkShouldRun: Bool {
        outcome != nil || step.rawValue > OnboardingStep.bluetooth.rawValue
            || (step == .bluetooth && bluetooth != .notAsked)
    }

    /// Steps the progress bar paints as done (strictly before `step`, or all when completed).
    var completedSteps: Set<OnboardingStep> {
        if outcome == .completed { return Set(OnboardingStep.allCases) }
        return Set(OnboardingStep.allCases.filter { $0.rawValue < step.rawValue })
    }

    /// Whether the tour must be shown at launch, from what was persisted when it last finished.
    static func shouldPresent(completed: Bool, completedVersion: Int) -> Bool {
        !(completed && completedVersion >= version)
    }

    mutating func handle(_ event: Event) {
        guard outcome == nil else { return }
        switch event {
        case .skip:
            outcome = .skipped
        case .next:
            switch step {
            case .welcome:
                // Access already granted: no ceremony, straight to the headphone.
                step = bluetooth == .allowed ? .connect : .bluetooth
            case .bluetooth:
                if bluetooth == .allowed { step = .connect }
            case .connect:
                step = .notifications
            case .notifications:
                step = .macAnchor
            case .macAnchor:
                step = .done
            case .done:
                outcome = .completed
            }
        case .allowBluetooth:
            if step == .bluetooth, bluetooth == .notAsked { bluetooth = .waiting }
        case .bluetoothChanged(let state):
            bluetooth = state
            // Revoked in System Settings while on Connect: go back and explain. Later steps ignore it.
            if step == .connect, state != .allowed { step = .bluetooth }
        }
    }
}
