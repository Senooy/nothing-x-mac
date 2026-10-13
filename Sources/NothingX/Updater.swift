import Foundation
import Observation
import Sparkle

/// Sparkle 2 wrapper: owns the standard updater controller (standard UI: update alert, download progress,
/// "install and relaunch") and mirrors the two values the UI needs as observable properties.
///
/// The feed (`SUFeedURL`), the EdDSA public key (`SUPublicEDKey`) and the check interval live in Info.plist.
/// `SUEnableAutomaticChecks` is deliberately absent: Sparkle then asks the user on the second launch whether
/// to check automatically, and the answer is what `automaticallyChecks` reflects afterwards.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    /// False while a check or an update session is in progress, or when the updater could not start.
    private(set) var canCheckForUpdates = false

    /// Daily background checks (`SUScheduledCheckInterval`). Sparkle persists it in the app's defaults.
    var automaticallyChecks: Bool {
        get { automaticChecksValue }
        set {
            guard isAvailable else { return }
            controller.updater.automaticallyChecksForUpdates = newValue
            automaticChecksValue = newValue
        }
    }
    private var automaticChecksValue = false

    /// "0.2.1 (3)", from the running bundle.
    let currentVersion: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "—"
        if let build = info["CFBundleVersion"] as? String { return "\(short) (\(build))" }
        return short
    }()

    /// False for `swift run` / unbundled dev builds: there is no Info.plist feed, and starting Sparkle there
    /// would only put up an error alert.
    let isAvailable: Bool

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    private init() {
        let bundled = Bundle.main.bundleURL.pathExtension == "app"
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        isAvailable = bundled
        controller = SPUStandardUpdaterController(startingUpdater: bundled, updaterDelegate: nil, userDriverDelegate: nil)
        guard bundled else { return }
        let updater = controller.updater
        canCheckForUpdates = updater.canCheckForUpdates
        automaticChecksValue = updater.automaticallyChecksForUpdates
        // Sparkle posts these KVO changes on the main thread.
        observations.append(updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            MainActor.assumeIsolated { self?.canCheckForUpdates = value }
        })
        observations.append(updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] updater, _ in
            let value = updater.automaticallyChecksForUpdates
            MainActor.assumeIsolated { self?.automaticChecksValue = value }
        })
    }

    /// User-initiated check: Sparkle shows its own window with the result ("You're up to date", or the update).
    func checkForUpdates() {
        guard isAvailable else { return }
        controller.checkForUpdates(nil)
    }
}
