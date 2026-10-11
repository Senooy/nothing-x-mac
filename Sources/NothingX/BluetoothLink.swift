import Foundation
import IOBluetooth

/// Transport RFCOMM vers le service « NT LINK » du casque.
/// Tout se déroule sur le thread principal (callbacks IOBluetooth inclus).
final class BluetoothLink: NSObject, IOBluetoothRFCOMMChannelDelegate {
    enum State { case searching, connecting, connected }

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

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func stop() {
        timer?.invalidate()
        channel?.close()
    }

    /// Cherche un casque Nothing appairé et connecté, puis résout le canal RFCOMM par SDP.
    private func tick() {
        guard channel == nil, !busy else { return }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        guard let dev = paired.first(where: { ($0.name ?? "").localizedCaseInsensitiveContains("nothing") && $0.isConnected() }) else {
            state = .searching
            return
        }
        busy = true
        device = dev
        deviceName = dev.name
        state = .connecting
        if dev.performSDPQuery(self) != kIOReturnSuccess { fail() }
    }

    private func fail() {
        busy = false
        channel = nil
        parser.reset()
        state = .searching
    }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        guard status == kIOReturnSuccess, let dev = device else { return fail() }
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
        busy = false
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
