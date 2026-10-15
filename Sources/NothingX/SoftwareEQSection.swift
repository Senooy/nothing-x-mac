import SwiftUI

/// The equalizer section while the headphone is wired (USB): same preset pills and 8 sliders as the
/// headphone EQ, bound to the Mac's software EQ (`HeadphoneModel` routes `selectPreset`, `setBandGain`,
/// `commitCustomEQ`, `resetCustomEQ` and the EQ files to it while wired), plus the On/Off switch.
/// When the software EQ is off the curve stays editable but dimmed, and the On/Off control stays bright.
struct SoftwareEQSection: View {
    @Environment(HeadphoneModel.self) private var model

    var body: some View {
        let on = model.softwareEQEnabled
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(title: "Equalizer")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    Text("Software equalizer").ntLabel().frame(width: 150, alignment: .leading)
                    Segmented(
                        options: [(false, String(localized: "Off")), (true, String(localized: "On"))],
                        selection: on
                    ) { model.setSoftwareEQEnabled($0) }
                }
                Text("Equalizes everything the Mac plays, before the headphone. Needs System Audio Recording permission. Use the Mac's volume; the headphone's own EQ cannot be changed while the cable is plugged in.")
                    .ntLabel(NTColor.disabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.softwareEQDetail.isEmpty {
                    Text(verbatim: model.softwareEQDetail).ntLabel(NTColor.disabled)
                }
            }
            VStack(alignment: .leading, spacing: 24) {
                Segmented(
                    options: EQPreset.allCases.map { ($0, $0.label) },
                    selection: model.softwareSelectedPreset
                ) { model.selectPreset($0) }
                HStack(alignment: .top, spacing: 0) {
                    ForEach(model.softwareEQProfile.bands) { band in
                        BandSlider(gain: band.gain, freq: band.freq) { model.setBandGain(band.id, $0) } onEnd: {
                            model.commitCustomEQ()
                        }
                    }
                }
                HStack(spacing: 24) {
                    Button { model.resetCustomEQ() } label: {
                        Text("[Reset to zero]").ntLabel(NTColor.secondary)
                    }
                    .buttonStyle(.plain)
                    EQFileActions(model: model)
                }
                if !model.eqImportNote.isEmpty {
                    Text(verbatim: model.eqImportNote).ntLabel(NTColor.disabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .opacity(on ? 1 : 0.4)
        }
    }
}
