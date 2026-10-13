import AppKit
import Foundation
import IOBluetooth

/// Transport RFCOMM vers le service « NT LINK » du casque.
/// Tout se déroule sur le thread principal (callbacks IOBluetooth inclus).
///
/// Bluetooth permission: the first IOBluetooth call (`IOBluetoothDevice.pairedDevices()`) blocks the calling
/// thread on a semaphore until the user answers the macOS "would like to use Bluetooth" prompt, which
/// froze the app before its window appeared. So nothing here touches IOBluetooth before
/// `CBManager.authorization` says `.allowedAlways` (see `BluetoothGate`):
/// - not determined → state `.permissionPending`; a `BluetoothPermissionWatcher` creates a CBCentralManager
///   off the main thread, which shows the prompt, and reports the answer;
/// - denied / restricted → state `.permissionDenied`; IOBluetooth is never called;
/// - allowed → the 3 s search timer starts as before.
/// The gate is checked again whenever the app becomes active (the user may have flipped the switch in
/// System Settings) and every 3 s while it is closed, so access granted later works without a restart,
/// and access revoked while running closes the link.
final class BluetoothLink: NSObject, IOBluetoothRFCOMMChannelDelegate {
    enum State { case searching, connecting, connected, permissionPending, permissionDenied }

    var onState: ((State, String?) -> Void)?
    var onFrame: ((Frame) -> Void)?

    private(set) var state: State = .searching {
        didSet { if state != oldValue { onState?(state, deviceName) } }
    }
    private(set) var deviceName: String?

    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var parser = FrameParser()
    private var timer: Timer?
    private var busy = false
    /// When the current connection attempt started, to give up on one that never completes.
    private var attemptStarted: Date?
    private let attemptTimeout: TimeInterval = 12

    private var gate: BluetoothGate?
    private var watcher: BluetoothPermissionWatcher?
    private var gateTimer: Timer?
    private var activeObserver: NSObjectProtocol?

    func start() {
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.applyGate(BluetoothGate.current) }
        applyGate(BluetoothGate.current)
    }

    func stop() {
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
        stopWatcher()
        gateTimer?.invalidate(); gateTimer = nil
        timer?.invalidate(); timer = nil
        channel?.close()
    }

    // MARK: Permission gate

    /// Moves the transport to what the permission allows. Idempotent; main thread only.
    private func applyGate(_ new: BluetoothGate) {
        guard new != gate else { return }
        gate = new
        switch new {
        case .allowed:
            stopWatcher()
            gateTimer?.invalidate(); gateTimer = nil
            state = .searching
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tick() }
            tick()
        case .pending, .denied:
            // Revoked while running (or never granted): drop the link without calling IOBluetooth
            // beyond closing a channel that exists only if access was granted before.
            timer?.invalidate(); timer = nil
            channel?.close()
            channel = nil
            device = nil
            busy = false
            parser.reset()
            if new == .pending {
                startWatcher()
            } else {
                stopWatcher()
            }
            if gateTimer == nil {
                // Fallback in case no delegate callback or activation arrives (prompt on another display).
                gateTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                    self?.applyGate(BluetoothGate.current)
                }
            }
            if let closed = new.linkState { state = closed }
        }
    }

    private func startWatcher() {
        guard watcher == nil else { return }
        let w = BluetoothPermissionWatcher()
        w.onChange = { [weak self] gate in self?.applyGate(gate) }
        watcher = w
        w.start()
    }

    private func stopWatcher() {
        watcher?.stop()
        watcher = nil
    }

    /// Cherche un casque Nothing appairé et connecté, puis résout le canal RFCOMM par SDP.
    private func tick() {
        guard gate == .allowed else { return }
        if busy {
            // The headphone sometimes accepts the Bluetooth link but never opens the control channel
            // (e.g. right after a codec change). Abandon the attempt so the next tick can retry.
            if let started = attemptStarted, Date().timeIntervalSince(started) > attemptTimeout { abortAttempt() }
            return
        }
        guard channel == nil else { return }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        guard let dev = paired.first(where: { ($0.name ?? "").localizedCaseInsensitiveContains("nothing") && $0.isConnected() }) else {
            state = .searching
            return
        }
        busy = true
        attemptStarted = Date()
        device = dev
        deviceName = dev.name
        state = .connecting
        if dev.performSDPQuery(self) != kIOReturnSuccess { fail() }
    }

    private func abortAttempt() {
        channel?.close()
        channel = nil
        fail()
    }

    private func fail() {
        busy = false
        attemptStarted = nil
        channel = nil
        parser.reset()
        if gate == .allowed { state = .searching }
    }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        guard gate == .allowed, status == kIOReturnSuccess, let dev = device else { return fail() }
        let uuid = IOBluetoothSDPUUID(bytes: NT.serviceUUID, length: NT.serviceUUID.count)
        var channelID: BluetoothRFCOMMChannelID = 0
        for case let record as IOBluetoothSDPServiceRecord in dev.services ?? [] {
            var id: BluetoothRFCOMMChannelID = 0
            if record.hasService(from: [uuid as Any]), record.getRFCOMMChannelID(&id) == kIOReturnSuccess {
                channelID = id
                break
            }
        }
        guard channelID != 0 else { return fail() }
        var opened: IOBluetoothRFCOMMChannel?
        if dev.openRFCOMMChannelAsync(&opened, withChannelID: channelID, delegate: self) != kIOReturnSuccess {
            return fail()
        }
        channel = opened
    }

    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        // A late completion for an attempt we already abandoned must not revive the link.
        guard rfcommChannel === channel else { rfcommChannel?.close(); return }
        busy = false
        attemptStarted = nil
        if gate != .allowed {
            // Access revoked while the channel was opening.
            rfcommChannel?.close()
            return fail()
        }
        if error == kIOReturnSuccess {
            state = .connected
        } else {
            fail()
        }
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        channel = nil
        fail()
    }

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let bytes = [UInt8](UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        for frame in parser.feed(bytes) { onFrame?(frame) }
    }

    @discardableResult
    func send(_ bytes: [UInt8]) -> Bool {
        guard let channel, state == .connected else { return false }
        var data = bytes
        let n = UInt16(data.count)
        return data.withUnsafeMutableBytes { channel.writeSync($0.baseAddress, length: n) == kIOReturnSuccess }
    }
}
