import SwiftUI

/// "Device" section: low latency, codec, dual connection, adaptive ANC, in-ear detection, find my headphone.
struct DeviceSettingsView: View {
    @Environment(HeadphoneModel.self) private var model
    /// First step of the find-my-headphone confirmation ("take it off first").
    @State private var confirmingFind = false

    private var connected: Bool { model.connection == .connected }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Device")
            toggleRow("Low latency", model.lowLatency) { model.setLowLatency($0) }
            codecRow
            toggleRow("Dual connection", model.dualConnection) { model.setDualConnection($0) }
            Text("Usually not available together with LDAC.").ntLabel(NTColor.disabled)
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

    private var codecRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Audio codec") {
                Segmented(
                    options: AudioCodec.allCases.map { ($0, $0.label) },
                    selection: model.codec
                ) { model.setCodec($0) }
            }
            Text("Reconnect after changing").ntLabel(NTColor.disabled)
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
