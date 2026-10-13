import SwiftUI

struct ContentView: View {
    @Environment(HeadphoneModel.self) private var model

    private var connected: Bool { model.connection == .connected }
    private var spatialOn: Bool { model.spatial?.on == true }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 32)
                .padding(.top, 34)       // sits below the traffic-light buttons
                .frame(height: 64, alignment: .top)
            HStack(alignment: .top, spacing: 56) {
                VStack(alignment: .leading, spacing: 40) {
                    hero
                    BluetoothPermissionNotice()
                    noiseControl
                    spatialAudio
                    Spacer(minLength: 0)
                    footer
                }
                .frame(width: 340)
                ScrollView {
                    VStack(alignment: .leading, spacing: 40) {
                        equalizer
                        gestures
                    }
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .frame(maxHeight: .infinity)
        }
        .frame(width: 900, height: 700)
        .background(NTColor.background)
        .foregroundStyle(NTColor.primary)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            Text("Nothing X").ntLabel()
            Spacer()
            if !model.status.isEmpty {
                Text(verbatim: model.status).ntLabel(model.status == "[OK]" ? NTColor.secondary : NTColor.accent)
                    .padding(.trailing, 20)
                    .transition(.opacity)
            }
            HStack(spacing: 8) {
                Circle()
                    .fill(connected ? NTColor.display : Color.clear)
                    .overlay(Circle().stroke(connected ? Color.clear : NTColor.disabled, lineWidth: 1))
                    .frame(width: 7, height: 7)
                statusText.ntLabel(connected ? NTColor.primary : NTColor.disabled)
            }
        }
    }

    private var statusText: Text {
        switch model.connection {
        case .connected: Text("Connected")
        case .connecting: Text("Connecting…")
        case .searching: Text("Searching for headphone")
        case .permissionPending: Text("Waiting for Bluetooth permission…")
        case .permissionDenied: Text("Bluetooth access denied")
        }
    }

    // MARK: Hero — battery

    private var hero: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let level = model.battery {
                DotMatrixText(text: "\(level)%", dot: 8)
            } else {
                DotMatrixText(text: "--", dot: 8, color: NTColor.disabled)
            }
            HStack(spacing: 12) {
                Text("Battery").ntLabel()
                if model.charging { Text("[Charging]").ntLabel(NTColor.display) }
            }
            Text(verbatim: model.deviceName).font(.system(size: 17)).foregroundStyle(NTColor.primary)
        }
    }

    // MARK: Noise control

    private var noiseControl: some View {
        let raw = model.ancRaw
        let kind = raw.map(ANCState.kind(of:))
        return VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Noise control")
            Segmented(
                options: ANCKind.allCases.map { ($0, $0.label) },
                selection: kind
            ) { model.setANCKind($0) }
            if kind == .anc {
                Segmented(
                    options: ANCLevel.allCases.map { ($0.rawValue, $0.label) },
                    selection: raw
                ) { model.setANC($0) }
            }
        }
        .disabled(!connected)
        .opacity(connected ? 1 : 0.4)
    }

    // MARK: Spatial audio

    private enum SpatialChoice { case off, headphone, mac }

    private var spatialChoice: SpatialChoice? {
        if model.macAnchored { return .mac }
        guard let state = model.spatial else { return nil }
        return state.on ? .headphone : .off
    }

    private var spatialAudio: some View {
        let state = model.spatial
        return VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Spatial audio")
            Segmented(
                options: [(SpatialChoice.off, String(localized: "Off")),
                          (.headphone, String(localized: "Headphone")),
                          (.mac, String(localized: "Mac anchor"))],
                selection: spatialChoice
            ) { choice in
                switch choice {
                case .off:
                    if model.macAnchored { model.setMacAnchored(false) }
                    model.setSpatial(on: false, headTracking: false)
                case .headphone:
                    if model.macAnchored { model.setMacAnchored(false) }
                    model.setSpatial(on: true, headTracking: state?.headTracking ?? true)
                case .mac:
                    model.setMacAnchored(true)
                }
            }
            if spatialChoice == .headphone {
                HStack(spacing: 16) {
                    Text("Head tracking").ntLabel().frame(width: 130, alignment: .leading)
                    Segmented(
                        options: [(false, String(localized: "Off")), (true, String(localized: "On"))],
                        selection: state?.headTracking
                    ) { model.setSpatial(on: true, headTracking: $0) }
                }
                Text("EQ presets are disabled while spatial audio is on.").ntLabel(NTColor.disabled)
            }
            if spatialChoice == .mac {
                macAnchorControls
            }
        }
        .disabled(!connected || state == nil)
        .opacity(connected ? 1 : 0.4)
    }

    private var macAnchorControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button { model.recenterHead() } label: {
                    Text("[Recenter]").ntLabel(NTColor.primary)
                }
                .buttonStyle(.plain)
                Spacer()
                Text(verbatim: model.anchorDetail).ntLabel(NTColor.disabled)
            }
            HStack(spacing: 14) {
                Text("Sensitivity").ntLabel()
                Slider(value: Binding(get: { model.anchorSensitivity }, set: { model.anchorSensitivity = $0 }),
                       in: 0.5...1.5, step: 0.05)
                    .controlSize(.small)
                Text(verbatim: String(format: "%.2f×", model.anchorSensitivity))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(NTColor.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            Text("Sound stays fixed in front of you, where the Mac is. Look at the Mac and press Recenter if it drifts.")
                .ntLabel(NTColor.disabled)
        }
    }

    // MARK: Equalizer

    private var equalizer: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(title: "Equalizer")
            Segmented(
                options: EQPreset.allCases.map { ($0, $0.label) },
                selection: model.selectedPreset
            ) { model.selectPreset($0) }
            if let eq = model.eqProfile {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(eq.bands) { band in
                        BandSlider(gain: band.gain, freq: band.freq) { model.setBandGain(band.id, $0) } onEnd: {
                            model.commitCustomEQ()
                        }
                    }
                }
                Button { model.resetCustomEQ() } label: {
                    Text("[Reset to zero]").ntLabel(NTColor.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .disabled(!connected || spatialOn)
        .opacity(connected ? (spatialOn ? 0.4 : 1) : 0.4)
    }

    // MARK: Gestures

    private var gestures: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Gestures", trailing: String(localized: "Experimental"))
            if model.gestures.isEmpty {
                Text("—").ntLabel(NTColor.disabled)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.gestures) { row in
                        gestureRow(row)
                    }
                }
                if model.gesturesDifferFromOriginal {
                    Button { model.restoreOriginalGestures() } label: {
                        Text("[Restore original]").ntLabel(NTColor.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .disabled(!connected)
        .opacity(connected ? 1 : 0.4)
    }

    private func gestureRow(_ row: GestureBinding) -> some View {
        var options = GestureBinding.knownActions
        if !options.contains(row.action) { options.append(row.action) }
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: GestureBinding.controlName(row.button)).ntLabel(NTColor.disabled)
                Text(verbatim: GestureBinding.gestureName(row.gesture)).font(.system(size: 15))
            }
            Spacer()
            Menu {
                ForEach(options, id: \.self) { action in
                    Button(GestureBinding.actionName(action)) { model.setGestureAction(row, action: action) }
                }
            } label: {
                Text(verbatim: GestureBinding.actionName(row.action))
                    .font(.system(size: 11, design: .monospaced))
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .foregroundStyle(NTColor.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .overlay(Capsule().stroke(NTColor.border, lineWidth: 1))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 10)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            infoRow("Firmware", model.firmware)
            infoRow("Serial number", model.serial)
        }
    }

    private func infoRow(_ label: LocalizedStringKey, _ value: String?) -> some View {
        HStack {
            Text(label).ntLabel(NTColor.disabled)
            Spacer()
            Text(verbatim: value ?? "—").font(.system(size: 11, design: .monospaced)).foregroundStyle(NTColor.secondary)
        }
    }
}
