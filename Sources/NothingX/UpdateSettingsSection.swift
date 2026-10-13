import SwiftUI

/// Settings block for Sparkle updates: automatic daily checks, the running version and a manual check.
/// Self-contained (reads `Updater.shared`), so it can be dropped into any settings layout.
struct UpdateSettingsSection: View {
    private let updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Updates")
            VStack(alignment: .leading, spacing: 8) {
                Text("Check automatically").ntLabel(NTColor.disabled)
                Segmented(
                    options: [(false, String(localized: "Off")), (true, String(localized: "On"))],
                    selection: updater.isAvailable ? updater.automaticallyChecks : nil
                ) { updater.automaticallyChecks = $0 }
                .disabled(!updater.isAvailable)
                .opacity(updater.isAvailable ? 1 : 0.4)
            }
            HStack {
                Text("Version").ntLabel(NTColor.disabled)
                Spacer()
                Text(verbatim: updater.currentVersion)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(NTColor.secondary)
            }
            HStack {
                Button { updater.checkForUpdates() } label: {
                    Text("[Check now]").ntLabel(updater.canCheckForUpdates ? NTColor.primary : NTColor.disabled)
                }
                .buttonStyle(.plain)
                .disabled(!updater.canCheckForUpdates)
                Spacer()
                if !updater.isAvailable {
                    Text("Unavailable in development builds").ntLabel(NTColor.disabled)
                }
            }
        }
    }
}
