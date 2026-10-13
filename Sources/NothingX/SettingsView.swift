import SwiftUI

/// The Settings window (⌘,). Each section is an independent view: to add one, put its view in the stack.
struct SettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 40) {
            Text("Settings").ntLabel()
            NotificationsSettingsSection()
            // Add further sections here, one line each.
        }
        .padding(.horizontal, 32)
        .padding(.top, 34)       // sits below the traffic-light buttons
        .padding(.bottom, 32)
        .frame(width: 480, alignment: .topLeading)
        .background(NTColor.background)
        .foregroundStyle(NTColor.primary)
        .preferredColorScheme(.dark)
        .background(WindowConfigurator(title: String(localized: "Settings")))
    }
}

/// A label and, below it, a short explanation on the left; the control on the right.
struct SettingsRow<Control: View>: View {
    let title: LocalizedStringKey
    var detail: LocalizedStringKey?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).ntLabel(NTColor.primary)
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(NTColor.disabled) }
            }
            Spacer(minLength: 0)
            control.frame(width: 160)
        }
    }
}

struct NotificationsSettingsSection: View {
    private let service = NotificationService.shared

    private var stateLabel: String {
        switch service.authorization {
        case .allowed: String(localized: "Allowed")
        case .denied: String(localized: "Blocked")
        case .notDetermined: String(localized: "Not asked")
        case .unsupported: String(localized: "Unavailable")
        }
    }

    private func onOff(_ value: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        Segmented(options: [(true, String(localized: "On")), (false, String(localized: "Off"))],
                  selection: value) { on in
            set(on)
            // Switching an alert on is the moment to ask, if the system never was.
            if on, service.authorization == .notDetermined { Task { await service.requestAuthorization() } }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(title: "Notifications", trailing: stateLabel)
            SettingsRow(title: "Headphone connected", detail: "When the headphone connects, not at launch.") {
                onOff(service.connectedEnabled) { service.connectedEnabled = $0 }
            }
            SettingsRow(title: "Low battery", detail: "Once per discharge, never while charging.") {
                onOff(service.lowBatteryEnabled) { service.lowBatteryEnabled = $0 }
            }
            SettingsRow(title: "Alert at") {
                Segmented(options: LowBatteryRule.allowedThresholds.map { ($0, "\($0)%") },
                          selection: service.lowBatteryThreshold) { service.lowBatteryThreshold = $0 }
            }
            .disabled(!service.lowBatteryEnabled)
            .opacity(service.lowBatteryEnabled ? 1 : 0.4)
            permissionNote
        }
        .task { await service.refreshAuthorization() }
    }

    @ViewBuilder private var permissionNote: some View {
        switch service.authorization {
        case .allowed:
            EmptyView()
        case .notDetermined:
            note("Notifications are not allowed yet.", button: "[Allow notifications]") {
                Task { await service.requestAuthorization() }
            }
        case .denied:
            note("Notifications are blocked for Nothing X in System Settings.", button: "[Open System Settings]") {
                service.openSystemSettings()
            }
        case .unsupported:
            note("Notifications need the packaged app.", button: nil) {}
        }
    }

    private func note(_ text: LocalizedStringKey, button: LocalizedStringKey?, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text).font(.system(size: 12)).foregroundStyle(NTColor.secondary)
            if let button {
                Button(action: action) { Text(button).ntLabel(NTColor.primary) }
                    .buttonStyle(.plain)
            }
        }
    }
}
