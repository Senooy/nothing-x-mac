import SwiftUI

/// "Device" section: low latency, dual connection, adaptive ANC, in-ear detection, find my headphone.
/// The audio codec (LDAC) is deliberately not offered: macOS only plays SBC and AAC over Bluetooth, so
/// switching the headphone to LDAC changes nothing audible on a Mac (the model still supports it).
struct DeviceSettingsView: View {
    @Environment(HeadphoneModel.self) private var model
    /// First step of the find-my-headphone confirmation ("take it off first").
    @State private var confirmingFind = false

    private var connected: Bool { model.connection == .connected }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Device")
            toggleRow("Low latency", model.lowLatency) { model.setLowLatency($0) }
            toggleRow("Dual connection", model.dualConnection) { model.setDualConnection($0) }
            toggleRow("Adaptive ANC", model.adaptiveANC) { model.setAdaptiveANC($0) }
            toggleRow("In-ear detection", model.inEarDetection) { model.setInEarDetection($0) }
            findRow
        }
        .disabled(!connected)
        .opacity(connected ? 1 : 0.4)
        .onChange(of: connected) { _, now in if !now { confirmingFind = false } }
    }

    private func row<Control: View>(_ title: LocalizedStringKey, @ViewBuilder _ control: () -> Control) -> some View {
        HStack(spacing: 16) {
            Text(title).ntLabel().frame(width: 150, alignment: .leading)
            control()
        }
    }

    private func toggleRow(_ title: LocalizedStringKey, _ value: Bool?, _ onSelect: @escaping (Bool) -> Void) -> some View {
        row(title) {
            Segmented(
                options: [(false, String(localized: "Off")), (true, String(localized: "On"))],
                selection: value,
                onSelect: onSelect
            )
        }
    }

    // MARK: Find my headphone

    private var findRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.findPlaying {
                HStack {
                    Text("Playing…").ntLabel(NTColor.primary)
                    Spacer()
                    textButton("[Stop]", NTColor.primary) { model.stopFind() }
                }
            } else if confirmingFind {
                Text("Take the headphone off first").ntLabel(NTColor.primary)
                HStack(spacing: 24) {
                    textButton("[Play sound]", NTColor.primary) {
                        confirmingFind = false
                        model.startFindPulse()
                    }
                    textButton("[Cancel]", NTColor.secondary) { confirmingFind = false }
                }
            } else {
                HStack {
                    textButton("[Find my headphone]", NTColor.secondary) { confirmingFind = true }
                    Spacer()
                    Text("Experimental").ntLabel(NTColor.disabled)
                }
            }
        }
        .padding(.top, 4)
    }

    private func textButton(_ title: LocalizedStringKey, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).ntLabel(color) }
            .buttonStyle(.plain)
    }
}
