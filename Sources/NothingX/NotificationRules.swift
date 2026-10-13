import Foundation

// Pure decision logic for notifications: no UserNotifications, no UserDefaults, no clock.
// Everything the rules need is passed in, so they can be unit-tested directly.

/// Fires once per discharge cycle when the battery falls to the threshold.
///
/// - Fires when not charging and `level <= threshold` while armed, then disarms.
/// - Re-arms when the level rises above `threshold + rearmMargin`, or as soon as the headphone charges.
/// - Never fires while charging; an unknown level (`nil`) changes nothing.
/// - Changing the threshold re-arms, so the new choice is judged on its own.
struct LowBatteryRule {
    static let allowedThresholds = [20, 10]
    static let defaultThreshold = 20
    /// Points above the threshold the battery must climb before the rule can fire again.
    static let rearmMargin = 10

    private(set) var armed = true
    private var lastThreshold: Int?

    /// Returns true when a notification should be posted for this reading.
    mutating func evaluate(level: Int?, charging: Bool, threshold: Int) -> Bool {
        if let last = lastThreshold, last != threshold { armed = true }
        lastThreshold = threshold
        guard let level else { return false }
        if charging {
            armed = true
            return false
        }
        if !armed, level > threshold + Self.rearmMargin { armed = true }
        guard armed, level <= threshold else { return false }
        armed = false
        return true
    }
}

/// Fires on the transition to connected, except during the first seconds after launch (the initial
/// connection at startup would only be noise).
struct ConnectionNotificationRule {
    static let startupGrace: TimeInterval = 8

    private var wasConnected = false

    /// `uptime` is the time since the app launched, in seconds. Call it on every state change, even when
    /// the notification is switched off, so the transition tracking stays correct.
    mutating func evaluate(connected: Bool, uptime: TimeInterval) -> Bool {
        defer { wasConnected = connected }
        return connected && !wasConnected && uptime >= Self.startupGrace
    }
}
