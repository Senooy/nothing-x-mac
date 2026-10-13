import AppKit
import CoreBluetooth
import Foundation

/// What the Bluetooth privacy permission allows the transport to do. Pure mapping, no I/O: the lead can
/// unit-test it without Bluetooth.
enum BluetoothGate: Equatable {
    /// The user has not answered the macOS prompt yet: IOBluetooth would block the calling thread.
    case pending
    /// Denied or restricted: IOBluetooth must not be called at all.
    case denied
    /// Allowed: the transport runs as usual.
    case allowed

    static func gate(for authorization: CBManagerAuthorization) -> BluetoothGate {
        switch authorization {
        case .notDetermined: return .pending
        case .restricted, .denied: return .denied
        case .allowedAlways: return .allowed
        @unknown default: return .denied
        }
    }

    /// The link state shown while the gate is closed; `nil` when allowed (the transport owns the state).
    var linkState: BluetoothLink.State? {
        switch self {
        case .pending: return .permissionPending
        case .denied: return .permissionDenied
        case .allowed: return nil
        }
    }

    /// The current system answer. A TCC preflight: it never shows the prompt and never blocks on it.
    static var current: BluetoothGate { gate(for: CBManager.authorization) }

    /// Opens the Bluetooth pane of Privacy & Security, or Privacy & Security itself if that anchor is gone.
    static func openSettings() {
        let urls = ["x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth",
                    "x-apple.systempreferences:com.apple.preference.security"]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }
}

/// Triggers the macOS Bluetooth prompt without blocking anything, and reports when the user answers.
///
/// Creating a `CBCentralManager` is what makes macOS show "Nothing X would like to use Bluetooth"; its
/// delegate runs on a private queue and the manager is created there too, so the main thread never
/// waits on TCC. Only `CBManager.authorization` is trusted as the answer: `central.state` can be
/// `.unknown` before the answer and `.poweredOff` after Allow.
final class BluetoothPermissionWatcher: NSObject, CBCentralManagerDelegate {
    /// Called on the main thread with the new gate, once the answer is known (never with `.pending`).
    var onChange: ((BluetoothGate) -> Void)?

    private let queue = DispatchQueue(label: "nx.bluetooth.permission")
    private var central: CBCentralManager?

    func start() {
        queue.async { [weak self] in
            guard let self, self.central == nil else { return }
            self.central = CBCentralManager(delegate: self, queue: self.queue,
                                            options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.central?.delegate = nil
            self?.central = nil
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let gate = BluetoothGate.current
        guard gate != .pending else { return }
        DispatchQueue.main.async { [weak self] in self?.onChange?(gate) }
    }
}
