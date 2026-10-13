import AppKit
import Observation
import UserNotifications

/// Where the app stands with the system's notification permission.
enum NotificationAuthorization {
    /// Not running from an app bundle (e.g. `swift run`): UserNotifications would crash, so it is not used.
    case unsupported
    case notDetermined
    case denied
    case allowed
}

/// Presents notifications even while the app is frontmost (macOS hides them otherwise).
private final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

/// Permission, user preferences and posting. It never asks for permission by itself: the onboarding (or
/// the Settings window) calls `requestAuthorization()` at the right moment. Until the user has allowed
/// notifications, `post` is a silent no-op.
@MainActor
@Observable
final class NotificationService {
    static let shared = NotificationService()

    private(set) var authorization: NotificationAuthorization = .notDetermined

    var connectedEnabled: Bool = UserDefaults.standard.bool(forKey: Key.connected) {
        didSet { UserDefaults.standard.set(connectedEnabled, forKey: Key.connected) }
    }
    var lowBatteryEnabled: Bool = (UserDefaults.standard.object(forKey: Key.lowBattery) as? Bool) ?? true {
        didSet { UserDefaults.standard.set(lowBatteryEnabled, forKey: Key.lowBattery) }
    }
    var lowBatteryThreshold: Int = {
        let saved = UserDefaults.standard.integer(forKey: Key.threshold)
        return LowBatteryRule.allowedThresholds.contains(saved) ? saved : LowBatteryRule.defaultThreshold
    }() {
        didSet { UserDefaults.standard.set(lowBatteryThreshold, forKey: Key.threshold) }
    }

    enum Key {
        static let connected = "notify.connected"
        static let lowBattery = "notify.lowBattery"
        static let threshold = "notify.lowBattery.threshold"
    }

    /// `UNUserNotificationCenter.current()` traps outside an app bundle.
    private let available = Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    @ObservationIgnored private let presenter = NotificationPresenter()

    private init() {
        guard available else {
            authorization = .unsupported
            return
        }
        UNUserNotificationCenter.current().delegate = presenter
        Task { await refreshAuthorization() }
        // Coming back from System Settings: pick up the choice the user just made.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refreshAuthorization() }
        }
    }

    // MARK: Permission

    /// Reads the current permission without prompting.
    func refreshAuthorization() async {
        guard available else { return }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        switch status {
        case .notDetermined: authorization = .notDetermined
        case .denied: authorization = .denied
        default: authorization = .allowed   // authorized, provisional, ephemeral
        }
    }

    /// Shows the system prompt, once: when the user already answered, macOS does not ask again and this
    /// just reports the standing answer.
    @discardableResult
    func requestAuthorization() async -> Bool {
        guard available else { return false }
        await refreshAuthorization()
        if authorization == .notDetermined {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            await refreshAuthorization()
        }
        return authorization == .allowed
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Posting

    /// Posts a notification unless permission is missing. A fixed `id` makes a newer notification of the
    /// same kind replace the older one instead of stacking.
    @discardableResult
    func post(id: String, title: String, body: String, sound: Bool = false) async -> Bool {
        guard available else { return false }
        await refreshAuthorization()
        guard authorization == .allowed else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            return true
        } catch {
            return false
        }
    }

    func postLowBattery(deviceName: String, level: Int) async {
        let body = String(format: String(localized: "Battery low: %d%%"), level)
        await post(id: "nothingx.lowBattery", title: deviceName, body: body, sound: true)
    }

    func postConnected(deviceName: String) async {
        await post(id: "nothingx.connected", title: deviceName, body: String(localized: "Headphone connected"))
    }
}

/// Feeds the pure rules with what the model observes and posts the result. The model calls it on every
/// link change and every battery reading.
@MainActor
final class NotificationCoordinator {
    private let service: NotificationService
    private let launchUptime = ProcessInfo.processInfo.systemUptime
    private var lowBattery = LowBatteryRule()
    private var connection = ConnectionNotificationRule()

    init(service: NotificationService? = nil) {
        self.service = service ?? .shared
    }

    func connectionChanged(connected: Bool, deviceName: String) {
        let uptime = ProcessInfo.processInfo.systemUptime - launchUptime
        // Evaluated even when the toggle is off, to keep the transition tracking right.
        guard connection.evaluate(connected: connected, uptime: uptime), service.connectedEnabled else { return }
        Task { await service.postConnected(deviceName: deviceName) }
    }

    func batteryChanged(level: Int?, charging: Bool, deviceName: String) {
        // While the toggle is off the rule is not fed, so it stays armed: switching it on at a low level
        // notifies at the next reading.
        guard service.lowBatteryEnabled, let level else { return }
        guard lowBattery.evaluate(level: level, charging: charging, threshold: service.lowBatteryThreshold) else { return }
        Task { await service.postLowBattery(deviceName: deviceName, level: level) }
    }
}
