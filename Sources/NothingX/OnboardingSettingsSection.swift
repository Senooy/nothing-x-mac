import SwiftUI

/// Settings block that replays the first-run tour in the main window.
struct OnboardingSettingsSection: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(title: "Welcome")
            SettingsRow(title: "First-launch tour", detail: "Replay it any time.") {
                HStack {
                    Spacer(minLength: 0)
                    Button {
                        OnboardingController.shared.replay { openWindow(id: "main") }
                    } label: {
                        Text("[Show]").ntLabel(NTColor.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
