import SwiftUI

/// Settings block for wired (USB) mode: optionally make the headphone the Mac's output while it is plugged in.
struct WiredSettingsSection: View {
    private let controller = WiredOutputController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(title: "Wired mode")
            SettingsRow(title: "Use as the Mac’s output",
                        detail: "When plugged in by USB, make the headphone the sound output, then give the previous output back when unplugged. Off leaves your output choice alone.") {
                Segmented(options: [(true, String(localized: "On")), (false, String(localized: "Off"))],
                          selection: controller.enabled) { controller.enabled = $0 }
            }
        }
    }
}
