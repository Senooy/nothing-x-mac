import SwiftUI

/// Calm inline notice while the headphone is plugged in by USB: Bluetooth is off by design then, so the
/// controls stay dimmed (the existing `connected` checks). Nothing is shown otherwise.
struct WiredNotice: View {
    @Environment(HeadphoneModel.self) private var model

    var body: some View {
        if model.isWired {
            VStack(alignment: .leading, spacing: 10) {
                Text("Wired (USB)").ntLabel(NTColor.primary)
                Text("Bluetooth is off while the cable is plugged in, so noise control, battery and the other settings are unavailable. The buttons on the headphone still work. Unplug the cable to control it from here.")
                    .font(.system(size: 12))
                    .foregroundStyle(NTColor.disabled)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
