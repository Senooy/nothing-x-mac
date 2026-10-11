import SwiftUI
import AppKit

/// Makes the window chrome disappear into the content: transparent title bar, black background,
/// draggable from anywhere. The traffic-light buttons stay.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ConfiguratorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ConfiguratorView: NSView {
        override func viewDidMoveToWindow() {
            guard let window else { return }
            window.title = "Nothing X"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.backgroundColor = .black
        }
    }
}

@main
struct NothingXApp: App {
    @State private var model = HeadphoneModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .preferredColorScheme(.dark)
                .background(WindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuContent().environment(model)
        } label: {
            Image(systemName: "headphones")
            if let level = model.battery { Text(verbatim: "\(level)%") }
        }
    }
}

struct MenuContent: View {
    @Environment(HeadphoneModel.self) private var model

    var body: some View {
        if model.connection == .connected {
            Text(verbatim: "\(model.deviceName) — \(model.battery.map { "\($0)%" } ?? "…")")
        } else {
            Text("Headphone not connected")
        }
        Divider()
        Button("Noise control: ANC") { model.setANCKind(.anc) }
        Button("Transparency") { model.setANCKind(.transparency) }
        Button("Noise control: Off") { model.setANCKind(.off) }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
}
