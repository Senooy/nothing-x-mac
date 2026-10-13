import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// `[Import…]` and `[Export…]` for the custom equalizer (AutoEq / Equalizer APO text files).
/// Warnings land in `model.eqImportNote`, failures in the usual inline `status`. The app is not
/// sandboxed, so the panels read and write the chosen files directly.
struct EQFileActions: View {
    let model: HeadphoneModel

    var body: some View {
        HStack(spacing: 24) {
            Button(action: importFile) { Text("[Import…]").ntLabel(NTColor.secondary) }
                .buttonStyle(.plain)
            Button(action: exportFile) { Text("[Export…]").ntLabel(NTColor.secondary) }
                .buttonStyle(.plain)
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose an AutoEq or Equalizer APO parametric EQ file")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var encoding = String.Encoding.utf8
        // Detects UTF-8 / UTF-16 byte-order marks (Windows tools write them); Latin-1 as a last resort.
        guard let text = (try? String(contentsOf: url, usedEncoding: &encoding))
            ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else {
            model.reportEQFile(ok: false, String(localized: "Could not read the file"))
            return
        }
        model.importEQ(from: text)
    }

    private func exportFile() {
        guard let text = model.exportEQ() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Nothing X EQ.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            model.reportEQFile(ok: true, "")
        } catch {
            model.reportEQFile(ok: false, String(localized: "Could not save the file"))
        }
    }
}
