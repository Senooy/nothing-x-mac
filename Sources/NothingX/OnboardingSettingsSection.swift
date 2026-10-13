import SwiftUI

/// Settings block that replays the first-run tour in the main window.
struct OnboardingSettingsSection: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(title: "Welcome")
            SettingsRow(title: "Show Welcome…", detail: "Replay the first-launch tour.") {
                HStack {
                    Spacer(minLength: 0)
                    Button {
                        OnboardingController.shared.replay { openWindow(id: "main") }
                    } label: {
                        Text("[Show Welcome…]").ntLabel(NTColor.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
