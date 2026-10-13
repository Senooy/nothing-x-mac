import AppKit
import SwiftUI

// One small view per step of the first-run tour. They only show text and state: the host
// (`OnboardingView`) owns the flow, the hero, the progress bar and the action buttons.

extension OnboardingStep {
    /// Short name shown next to the progress bar.
    var label: String {
        switch self {
        case .welcome: String(localized: "Welcome")
        case .bluetooth: String(localized: "Bluetooth")
        case .connect: String(localized: "Headphone")
        case .notifications: String(localized: "Notifications")
        case .macAnchor: String(localized: "Mac anchor")
        case .done: String(localized: "Ready")
        }
    }
}

enum OnboardingLinks {
    /// Opens the Bluetooth pane of System Settings (pairing), or the Bluetooth privacy pane if that fails.
    static func openBluetoothPairing() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings"),
           NSWorkspace.shared.open(url) { return }
        BluetoothGate.openSettings()
    }
}

// MARK: - Shared layout

/// Title, optional body paragraph and the step's own content, in the fixed 560 pt column.
struct OnboardingPage<Content: View>: View {
    let title: LocalizedStringKey
    var message: LocalizedStringKey?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text(title)
                .font(.system(size: 26))
                .foregroundStyle(NTColor.display)
                .fixedSize(horizontal: false, vertical: true)
            if let message { OnboardingBody(message) }
            content
        }
        .frame(width: 560, alignment: .leading)
    }
}

struct OnboardingBody: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(NTColor.secondary)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Steps

struct WelcomeStep: View {
    var body: some View {
        OnboardingPage(title: "Your headphone, from the Mac.",
                       message: "Nothing X controls the Nothing Headphone (1) from macOS: battery, noise control, spatial audio, equalizer and gestures.") {
            Text("Unofficial. Not affiliated with Nothing Technology Limited.")
                .ntLabel(NTColor.disabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct BluetoothStep: View {
    let state: OnboardingFlow.Bluetooth

    var body: some View {
        OnboardingPage(title: "Bluetooth access",
                       message: "The app needs Bluetooth to reach the headphone. macOS asks once.") {
            VStack(alignment: .leading, spacing: 10) {
                switch state {
                case .notAsked:
                    EmptyView()
                case .waiting:
                    Text("Waiting for Bluetooth permission…").ntLabel(NTColor.primary)
                    Text("Answer the macOS prompt. It may be on another display.").ntLabel(NTColor.disabled)
                case .denied:
                    Text("Bluetooth access denied").ntLabel(NTColor.primary)
                    Text("Allow it in Privacy & Security › Bluetooth.").ntLabel(NTColor.disabled)
                    Text("The tour continues as soon as access is allowed.").ntLabel(NTColor.disabled)
                case .allowed:
                    Text("Bluetooth access allowed").ntLabel(NTColor.display)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ConnectStep: View {
    @Environment(HeadphoneModel.self) private var model

    private var connected: Bool { model.connection == .connected }

    var body: some View {
        OnboardingPage(title: "Connect the headphone") {
            ZStack(alignment: .topLeading) {
                if connected {
                    connectedState.transition(.opacity)
                } else {
                    searchingState.transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.3), value: connected)
        }
    }

    private var searchingState: some View {
        VStack(alignment: .leading, spacing: 28) {
            OnboardingBody("Switch the headphone on. If it is not paired with this Mac yet, hold its pairing button until the light blinks, then pair it in System Settings › Bluetooth.")
            HStack(spacing: 8) {
                Circle()
                    .stroke(NTColor.disabled, lineWidth: 1)
                    .frame(width: 7, height: 7)
                (model.connection == .connecting ? Text("Connecting…") : Text("Searching for headphone"))
                    .ntLabel(NTColor.disabled)
            }
        }
    }

    private var connectedState: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: model.deviceName).font(.system(size: 17)).foregroundStyle(NTColor.primary)
                Text("Battery").ntLabel()
                if model.charging { Text("[Charging]").ntLabel(NTColor.display) }
            }
            OnboardingBody("Connected. Battery, noise control and the rest are live.")
            HStack(spacing: 8) {
                Circle()
                    .fill(NTColor.display)
                    .frame(width: 7, height: 7)
                Text("Connected").ntLabel(NTColor.primary)
            }
        }
    }
}

struct NotificationsStep: View {
    private let service = NotificationService.shared

    /// On/Off bound to the stored preference. Unlike Settings, switching on does not ask for permission:
    /// the explicit `[Allow]` button of this step does.
    private func onOff(_ value: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        Segmented(options: [(true, String(localized: "On")), (false, String(localized: "Off"))],
                  selection: value) { set($0) }
    }

    var body: some View {
        OnboardingPage(title: "Notifications",
                       message: "Two optional alerts, delivered by macOS. Change them any time in Settings.") {
            VStack(alignment: .leading, spacing: 24) {
                SettingsRow(title: "Low battery", detail: "Once per discharge, never while charging.") {
                    onOff(service.lowBatteryEnabled) { service.lowBatteryEnabled = $0 }
                }
                SettingsRow(title: "Headphone connected", detail: "When the headphone connects, not at launch.") {
                    onOff(service.connectedEnabled) { service.connectedEnabled = $0 }
                }
            }
            permissionState
        }
        .task { await service.refreshAuthorization() }
    }

    @ViewBuilder private var permissionState: some View {
        switch service.authorization {
        case .notDetermined:
            EmptyView()
        case .allowed:
            Text("Allowed").ntLabel(NTColor.display)
        case .denied:
            Text("Notifications are blocked for Nothing X in System Settings.")
                .font(.system(size: 12)).foregroundStyle(NTColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .unsupported:
            Text("Notifications need the packaged app.")
                .font(.system(size: 12)).foregroundStyle(NTColor.secondary)
        }
    }
}

struct MacAnchorStep: View {
    var body: some View {
        OnboardingPage(title: "Mac anchor",
                       message: "Under Spatial audio, Mac anchor turns what the Mac plays into sound fixed in front of you. It follows your head with the headphone’s motion sensor, like AirPods on a Mac.") {
            Text("The first time you switch it on, macOS asks to allow System Audio Recording. Nothing is captured before that.")
                .ntLabel(NTColor.disabled)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct DoneStep: View {
    var body: some View {
        OnboardingPage(title: "Ready.") {
            VStack(alignment: .leading, spacing: 20) {
                row("Menu bar", "Battery and noise control, always at hand.")
                row("Settings ⌘,", "Notifications and updates.")
                row("Recenter", "In Spatial audio and the menu bar, when the Mac anchor drifts.")
            }
            Text("This tour: Settings › Welcome.").ntLabel(NTColor.disabled)
        }
    }

    private func row(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).ntLabel(NTColor.primary)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(NTColor.disabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Hero and progress

/// The Dot X mark of the app icon: both diagonals of a 7×7 grid (`dotXPoints` in `tools/make-icons.swift`),
/// all white here. The dots fade in from the centre outwards, unless Reduce Motion is on.
struct DotXMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    private static let dot: CGFloat = 10
    private static let pitch: CGFloat = 14.5        // dot × 1.45, like DotMatrixText

    /// Grid position and ring (0 = centre, 3 = corners) of the 13 dots.
    private static let points: [(row: Int, col: Int, ring: Int)] = {
        var pts: [(row: Int, col: Int, ring: Int)] = []
        for i in 0..<7 { for j in 0..<7 where i == j || i + j == 6 {
            pts.append((i, j, max(abs(i - 3), abs(j - 3))))
        } }
        return pts
    }()

    var body: some View {
        let side = 6 * Self.pitch + Self.dot
        ZStack(alignment: .topLeading) {
            ForEach(Self.points.indices, id: \.self) { index in
                let p = Self.points[index]
                Circle()
                    .fill(NTColor.display)
                    .frame(width: Self.dot, height: Self.dot)
                    .offset(x: CGFloat(p.col) * Self.pitch, y: CGFloat(p.row) * Self.pitch)
                    .opacity(shown || reduceMotion ? 1 : 0)
                    // 4 rings × 0.1 s stagger + 0.2 s fade = 0.5 s in total.
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2).delay(Double(p.ring) * 0.1), value: shown)
            }
        }
        .frame(width: side, height: side, alignment: .topLeading)
        .accessibilityHidden(true)
        .onAppear { shown = true }
    }
}

/// Six thin segments (done and current lit), then "03 / 06" and the step name.
struct OnboardingProgress: View {
    let step: OnboardingStep
    let completed: Set<OnboardingStep>

    private var number: Int { step.rawValue + 1 }
    private var total: Int { OnboardingStep.allCases.count }

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases, id: \.self) { s in
                    Rectangle()
                        .fill(completed.contains(s) || s == step ? NTColor.display : NTColor.border)
                        .frame(width: 36, height: 2)
                }
            }
            Text(verbatim: String(format: "%02d / %02d", number, total)).ntLabel(NTColor.disabled)
                .fixedSize()
            Text(verbatim: step.label).ntLabel(NTColor.disabled)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: String(localized: "Step %d of %d: %@"), number, total, step.label))
    }
}
