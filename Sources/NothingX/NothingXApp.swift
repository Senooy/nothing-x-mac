import SwiftUI
import AppKit

/// Blends the window chrome into the content: the title bar is transparent over a black window, so it
/// reads as black. Content is NOT extended under it, which keeps the traffic-light buttons on top.
struct WindowConfigurator: NSViewRepresentable {
    var title = "Nothing X"

    func makeNSView(context: Context) -> NSView {
        let view = ConfiguratorView()
        view.windowTitle = title
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ConfiguratorView: NSView {
        private var observers: [NSObjectProtocol] = []
        private var hiddenWatchers: [NSKeyValueObservation] = []
        var windowTitle = "Nothing X"

        override func viewDidMoveToWindow() {
            guard let window else { return }
            window.title = windowTitle
            window.styleMask.formUnion([.titled, .closable, .miniaturizable, .fullSizeContentView])
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.backgroundColor = .black
            raiseTrafficLights(in: window)
            // SwiftUI can re-order the window's views; keep the buttons on top.
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResizeNotification, NSWindow.didExposeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                    if let window { self?.raiseTrafficLights(in: window) }
                })
            }
            DispatchQueue.main.async { [weak self, weak window] in
                if let window { self?.raiseTrafficLights(in: window) }
            }
        }

        /// With content extended under the title bar, the hosting view paints over the traffic-light
        /// buttons. Moving the title bar container above the content brings them back.
        private func raiseTrafficLights(in window: NSWindow) {
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.isHidden = false
            }
            guard let frameView = window.contentView?.superview,
                  var container = window.standardWindowButton(.closeButton)?.superview else { return }
            while let parent = container.superview, parent !== frameView { container = parent }
            guard container.superview === frameView else { return }
            if frameView.subviews.last !== container {
                frameView.addSubview(container, positioned: .above, relativeTo: nil)
            }
            hideTitlebarBackground(in: container)
        }

        /// The system paints a grey blur behind the title bar and re-shows it on state changes:
        /// hide it, and hide it again whenever AppKit turns it back on.
        private func hideTitlebarBackground(in view: NSView) {
            for sub in view.subviews {
                let name = String(describing: type(of: sub))
                if name == "NSTitlebarBackgroundView" || sub is NSVisualEffectView {
                    if !sub.isHidden { sub.isHidden = true }
                    if !hiddenWatchers.contains(where: { _ in false }) {
                        hiddenWatchers.append(sub.observe(\.isHidden, options: [.new]) { v, _ in
                            if !v.isHidden { v.isHidden = true }
                        })
                    }
                } else {
                    hideTitlebarBackground(in: sub)
                }
            }
        }
    }
}

@main
struct NothingXApp: App {
    @State private var model = HeadphoneModel()

    /// Dot-X glyph, drawn as a template so macOS tints it for light and dark menu bars.
    private static var menuBarImage: NSImage {
        let image = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "headphones", accessibilityDescription: nil)!
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .preferredColorScheme(.dark)
                .background(WindowConfigurator())
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra {
            MenuContent().environment(model)
        } label: {
            Image(nsImage: Self.menuBarImage)
            if let level = model.battery { Text(verbatim: "\(level)%") }
        }
    }
}

struct MenuContent: View {
    @Environment(HeadphoneModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if model.connection == .connected {
            Text(verbatim: "\(model.deviceName) — \(model.battery.map { "\($0)%" } ?? "…")")
        } else if model.connection == .permissionPending {
            Text("Waiting for Bluetooth permission…")
        } else if model.connection == .permissionDenied {
            Text("Bluetooth access denied")
            Button("Open Bluetooth settings") { BluetoothGate.openSettings() }
        } else {
            Text("Headphone not connected")
        }
        Divider()
        Button("Noise control: ANC") { model.setANCKind(.anc) }
        Button("Transparency") { model.setANCKind(.transparency) }
        Button("Noise control: Off") { model.setANCKind(.off) }
        if model.macAnchored {
            Divider()
            Button("Recenter head") { model.recenterHead() }
        }
        Divider()
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
}
