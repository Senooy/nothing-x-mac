import SwiftUI

/// Calm inline notice while the Bluetooth permission is missing; nothing otherwise.
/// The controls below stay dimmed by the existing `connected` checks.
struct BluetoothPermissionNotice: View {
    @Environment(HeadphoneModel.self) private var model

    var body: some View {
        switch model.connection {
        case .permissionPending:
            VStack(alignment: .leading, spacing: 10) {
                Text("Waiting for Bluetooth permission…").ntLabel(NTColor.primary)
                Text("Answer the macOS prompt. It may be on another display.")
                    .ntLabel(NTColor.disabled)
            }
        case .permissionDenied:
            VStack(alignment: .leading, spacing: 10) {
                Text("Bluetooth access denied").ntLabel(NTColor.primary)
                Text("Allow it in Privacy & Security › Bluetooth.")
                    .ntLabel(NTColor.disabled)
                Button { BluetoothGate.openSettings() } label: {
                    Text("[Open Bluetooth settings]").ntLabel(NTColor.secondary)
                }
                .buttonStyle(.plain)
            }
        case .searching, .connecting, .connected:
            EmptyView()
        }
    }
}
