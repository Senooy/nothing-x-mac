import AppKit
import Foundation
import Observation

/// Whether the first-run tour is on screen, and what was persisted when it last finished.
/// Nothing partial is stored: a relaunch mid-tour starts again at Welcome.
@MainActor
@Observable
final class OnboardingController {
    static let shared = OnboardingController()

    private(set) var isPresented: Bool

    enum Key {
        static let completed = "onboarding.completed"
        static let version = "onboarding.version"
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    private init() {
        isPresented = OnboardingFlow.shouldPresent(completed: defaults.bool(forKey: Key.completed),
                                                   completedVersion: defaults.integer(forKey: Key.version))
    }

    /// Replay: the host inserts a fresh `OnboardingView`, so the flow starts again at Welcome.
    func present() { isPresented = true }

    /// Both outcomes persist completion: a skipped tour is not shown again at launch.
    func finish(_ outcome: OnboardingFlow.Outcome) {
        defaults.set(true, forKey: Key.completed)
        defaults.set(OnboardingFlow.version, forKey: Key.version)
        isPresented = false
    }

    /// Brings the main window forward and shows the tour in it (menu bar item and Settings).
    /// `openWindow(id:)` on a `WindowGroup` opens a new window each time, so an existing main window is reused
    /// instead: two windows would run two flows against the one controller.
    func replay(openWindow: () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: {
            $0.title == "Nothing X" && $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized)
        }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow()
        }
        present()
    }
}
