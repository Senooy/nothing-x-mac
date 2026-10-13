import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class HeadphoneModel {
    enum Connection { case searching, connecting, connected, permissionPending, permissionDenied }

    var connection: Connection = .searching
    var deviceName = "Nothing Headphone"
    var battery: Int?
    var charging = false
    var firmware: String?
    var serial: String?
    var ancRaw: UInt8?
    var lastANCLevel: UInt8 = ANCLevel.high.rawValue
    var eqPreset: UInt8?
    var eqProfile: EQProfile?
    var spatial: SpatialState?
    var bassBoostOn = false
    var bassBoostLevel: UInt8 = 6
    var gestures: [GestureBinding] = []
    /// Inline status text (no toasts): `[OK]`, `[ERROR: …]`.
    var status = ""

    // Mac-anchored spatial audio (own binaural renderer)
    var macAnchored = false
    var anchorDetail = ""
    var anchorSensitivity: Double = {
        let saved = UserDefaults.standard.double(forKey: "anchor.sensitivity")
        return saved > 0 ? saved : 1.0
    }() {
        didSet { UserDefaults.standard.set(anchorSensitivity, forKey: "anchor.sensitivity") }
    }
    private let spatialEngine = SpatialAudioEngine()
    private let headPose = HeadPoseFilter()
    private var anchorTimer: Timer?
    private var anchorWanted: Bool {
        get { UserDefaults.standard.bool(forKey: "anchor.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "anchor.enabled") }
    }

    private let notifier = NotificationCoordinator()
    private let transport = BluetoothLink()
    private var opCounter: UInt8 = 0
    private var pending: [UInt8: CheckedContinuation<[UInt8]?, Never>] = [:]
    private var batteryTimer: Timer?
    private var eqCommit: Task<Void, Never>?

    init() {
        transport.onState = { [weak self] state, name in
            MainActor.assumeIsolated { self?.linkChanged(state, name) }
        }
        transport.onFrame = { [weak self] frame in
            MainActor.assumeIsolated { self?.handle(frame) }
        }
        transport.start()
        // The headphone can be changed from its own buttons or another device: poll the
        // cheap settings every few seconds, the battery less often.
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
    }

    // MARK: Connection

    private func linkChanged(_ state: BluetoothLink.State, _ name: String?) {
        if let name { deviceName = name }
        switch state {
        case .searching, .permissionPending, .permissionDenied:
            stopMacAnchor(remember: true)
            connection = state == .permissionPending ? .permissionPending
                : state == .permissionDenied ? .permissionDenied : .searching
            for (_, cont) in pending { cont.resume(returning: nil) }
            pending.removeAll()
            battery = nil
            ancRaw = nil
            eqPreset = nil
            spatial = nil
            gestures = []
        case .connecting:
            connection = .connecting
        case .connected:
            connection = .connected
            Task {
                await refreshAll()
                if anchorWanted { await startMacAnchor() }
            }
        }
        notifier.connectionChanged(connected: connection == .connected, deviceName: deviceName)
    }

    private func handle(_ frame: Frame) {
        if frame.cmd & 0xF000 != 0xE000, let cont = pending.removeValue(forKey: frame.opId) {
            cont.resume(returning: frame.payload)
            return
        }
        if frame.cmd == NT.Cmd.notifyANC { applyANC(frame.payload) }
        if frame.cmd == NT.Cmd.notifyHeadPose { headPose.ingest(frame.payload, now: Date.timeIntervalSinceReferenceDate) }
    }

    /// Sends a command and waits for the reply carrying the same opId.
    func request(_ cmd: UInt16, _ payload: [UInt8] = []) async -> [UInt8]? {
        guard connection == .connected else { return nil }
        opCounter = opCounter == 255 ? 1 : opCounter + 1
        let id = opCounter
        return await withCheckedContinuation { cont in
            pending[id] = cont
            guard transport.send(Codec.encode(cmd: cmd, opId: id, payload: payload)) else {
                pending[id] = nil
                cont.resume(returning: nil)
                return
            }
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                pending.removeValue(forKey: id)?.resume(returning: nil)
            }
        }
    }

    // MARK: Reads

    func refreshAll() async {
        await refreshInfo()
        await refreshBattery()
        await refreshANC()
        await refreshEQ()
        await refreshSpatial()
        await refreshGestures()
    }

    private var pollTick = 0

    private func poll() async {
        guard connection == .connected, pending.isEmpty else { return }
        pollTick += 1
        await refreshANC()
        if let p = await request(NT.Cmd.readSpatial), let s = SpatialState.decode(p) { spatial = s }
        if let p = await request(NT.Cmd.readEQPreset), let v = p.first, v != eqPreset { eqPreset = v; await refreshEQ() }
        if pollTick % 6 == 0 { await refreshBattery() }
    }

    private func refreshInfo() async {
        if let p = await request(NT.Cmd.readFirmware) { firmware = String(decoding: p, as: UTF8.self) }
        if let p = await request(NT.Cmd.readDeviceInfo), p.count > 1 {
            // Lines "6,<key>,<value>"; key 4 = serial number.
            let text = String(decoding: p.dropFirst(), as: UTF8.self)
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
                if parts.count == 3, parts[1] == "4" { serial = String(parts[2]) }
            }
        }
    }

    func refreshBattery() async {
        guard let p = await request(NT.Cmd.readBattery), p.count >= 3 else { return }
        battery = Int(p[2] & 0x7F)
        charging = p[2] & 0x80 != 0
        notifier.batteryChanged(level: battery, charging: charging, deviceName: deviceName)
    }

    func refreshANC() async {
        if let p = await request(NT.Cmd.readANC) { applyANC(p) }
    }

    /// Reads the preset and the custom curve. When the device is on its built-in Balanced preset the
    /// bars are shown flat; otherwise they show the device's custom curve.
    func refreshEQ(keepBars: Bool = false) async {
        if let p = await request(NT.Cmd.readEQPreset), let v = p.first { eqPreset = v }
        if let p = await request(NT.Cmd.readCustomEQ, [0]), let eq = EQProfile.decode(p), !keepBars {
            eqProfile = eq
            if eqPreset == EQPreset.deviceBalanced { showGains(EQPreset.balanced.gains!) }
        }
    }

    func refreshSpatial() async {
        if let p = await request(NT.Cmd.readSpatial), let s = SpatialState.decode(p) { spatial = s }
        if let p = await request(NT.Cmd.readBassBoost), p.count >= 2 {
            bassBoostOn = p[0] != 0
            bassBoostLevel = p[1]
        }
    }

    func refreshGestures() async {
        guard let p = await request(NT.Cmd.readGestures) else { return }
        gestures = GestureBinding.decodeTable(p)
        saveOriginalGesturesIfNeeded(p)
    }

    /// Payload `01 <mode> 00 [02 <last level> 00]`.
    private func applyANC(_ p: [UInt8]) {
        guard p.count >= 2 else { return }
        ancRaw = p[1]
        if p.count >= 5, (1...4).contains(p[4]) { lastANCLevel = p[4] }
        if (1...4).contains(p[1]) { lastANCLevel = p[1] }
    }

    // MARK: Writes

    /// Write acknowledged: reply received, empty payload or `00` (F00F → `00`, F010/F050 → empty).
    private static func acked(_ r: [UInt8]?) -> Bool { r != nil && (r!.first ?? 0) == 0 }

    private var statusClear: Task<Void, Never>?

    /// Inline status; success fades after a moment, errors stay a bit longer.
    private func report(_ ok: Bool, _ what: String) {
        status = ok ? "[OK]" : String(format: String(localized: "[ERROR: %@]"), what)
        statusClear?.cancel()
        statusClear = Task {
            try? await Task.sleep(for: .seconds(ok ? 2 : 6))
            if !Task.isCancelled { status = "" }
        }
    }

    func setANC(_ raw: UInt8) {
        ancRaw = raw
        if (1...4).contains(raw) { lastANCLevel = raw }
        Task {
            let r = await request(NT.Cmd.setANC, [1, raw, 0])
            report(Self.acked(r), String(localized: "ANC"))
            await refreshANC()
        }
    }

    func setANCKind(_ kind: ANCKind) {
        switch kind {
        case .anc: setANC(lastANCLevel)
        case .transparency: setANC(ANCState.transparency)
        case .off: setANC(ANCState.off)
        }
    }

    // MARK: Equalizer

    private static let customKey = "eq.custom.gains"

    /// The user's own curve, kept locally so it survives selecting other presets.
    private var userCustomGains: [Float] {
        get {
            if let saved = UserDefaults.standard.array(forKey: Self.customKey) as? [Double], saved.count == 8 {
                return saved.map(Float.init)
            }
            return EQPreset.balanced.gains!
        }
        set { UserDefaults.standard.set(newValue.map(Double.init), forKey: Self.customKey) }
    }

    private static func matches(_ gains: [Float], _ bands: [EQBand]) -> Bool {
        gains.count == bands.count && zip(gains, bands).allSatisfy { abs($0 - $1.gain) < 0.05 }
    }

    /// Which preset the bars currently show.
    var selectedPreset: EQPreset? {
        guard let raw = eqPreset, let eq = eqProfile else { return nil }
        if raw == EQPreset.deviceBalanced { return .balanced }
        return EQPreset.allCases.first { $0 != .custom && Self.matches($0.gains!, eq.bands) } ?? .custom
    }

    private func showGains(_ gains: [Float]) {
        guard eqProfile != nil else { return }
        withAnimation(.easeOut(duration: 0.3)) {
            for i in eqProfile!.bands.indices where i < gains.count { eqProfile!.bands[i].gain = gains[i] }
        }
    }

    /// Picks a preset: the bars move right away, then the curve is sent to the headphone and read back.
    func selectPreset(_ preset: EQPreset) {
        guard eqProfile != nil else { return }
        eqCommit?.cancel()
        let gains = preset.gains ?? userCustomGains
        showGains(gains)
        Task {
            var ok: Bool
            if preset == .balanced {
                ok = Self.acked(await request(NT.Cmd.setEQPreset, [EQPreset.deviceBalanced, 0]))
            } else {
                ok = Self.acked(await request(NT.Cmd.setCustomEQ, eqProfile!.encode()))
                if ok { ok = Self.acked(await request(NT.Cmd.setEQPreset, [EQPreset.deviceCustom, 0])) }
            }
            await refreshEQ(keepBars: true)
            let expected = preset == .balanced ? EQPreset.deviceBalanced : EQPreset.deviceCustom
            report(ok && eqPreset == expected, String(localized: "EQ"))
        }
    }

    /// Edits a band locally; the write to the headphone is deferred while dragging.
    func setBandGain(_ index: Int, _ gain: Float) {
        guard eqProfile?.bands.indices.contains(index) == true else { return }
        eqProfile?.bands[index].gain = gain
    }

    /// Sends the current bars as the Custom curve (called when a drag ends).
    func commitCustomEQ() {
        guard let eq = eqProfile else { return }
        userCustomGains = eq.bands.map(\.gain)
        eqCommit?.cancel()
        eqCommit = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            var ok = Self.acked(await request(NT.Cmd.setCustomEQ, eq.encode()))
            if ok { ok = Self.acked(await request(NT.Cmd.setEQPreset, [EQPreset.deviceCustom, 0])) }
            await refreshEQ(keepBars: true)
            report(ok && eqPreset == EQPreset.deviceCustom, String(localized: "Custom EQ"))
        }
    }

    func resetCustomEQ() {
        guard var eq = eqProfile else { return }
        for i in eq.bands.indices { eq.bands[i].gain = 0 }
        eq.gain = 0
        eqProfile = eq
        commitCustomEQ()
    }

    // MARK: Spatial audio

    /// The firmware refuses spatial audio alongside bass boost or a non-flat EQ
    /// (it acknowledges the write and ignores it), so those are cleared first.
    func setSpatial(on: Bool, headTracking: Bool) {
        spatial = SpatialState(on: on, headTracking: on && headTracking)
        Task {
            if on {
                if eqPreset != EQPreset.deviceBalanced {
                    _ = await request(NT.Cmd.setEQPreset, [EQPreset.deviceBalanced, 0])
                    showGains(EQPreset.balanced.gains!)
                }
                if bassBoostOn {
                    _ = await request(NT.Cmd.setBassBoost, [0, bassBoostLevel])
                }
            }
            let target = SpatialState(on: on, headTracking: on && headTracking)
            let r = await request(NT.Cmd.setSpatial, target.encode())
            await refreshSpatial()
            await refreshEQ()
            report(Self.acked(r) && spatial?.on == on, String(localized: "Spatial audio"))
        }
    }

    // MARK: Gestures

    private var gestureBackupKey: String { "gestures.original.\(serial ?? "unknown")" }

    /// Keeps the very first table read from the headphone so it can always be restored.
    private func saveOriginalGesturesIfNeeded(_ payload: [UInt8]) {
        let defaults = UserDefaults.standard
        if defaults.array(forKey: gestureBackupKey) == nil {
            defaults.set(payload.map { Int($0) }, forKey: gestureBackupKey)
        }
    }

    var hasGestureBackup: Bool { UserDefaults.standard.array(forKey: gestureBackupKey) != nil }

    var gesturesDifferFromOriginal: Bool {
        guard let saved = UserDefaults.standard.array(forKey: gestureBackupKey) as? [Int] else { return false }
        return GestureBinding.decodeTable(saved.map { UInt8($0) }) != gestures
    }

    func setGestureAction(_ binding: GestureBinding, action: UInt8) {
        var updated = binding
        updated.action = action
        if let i = gestures.firstIndex(where: { $0.id == binding.id }) { gestures[i] = updated }
        Task {
            let r = await request(NT.Cmd.setGestures, updated.encodeSet())
            await refreshGestures()
            let stored = gestures.first(where: { $0.id == binding.id })?.action == action
            report(Self.acked(r) && stored, String(localized: "Gestures"))
        }
    }

    func restoreOriginalGestures() {
        guard let saved = UserDefaults.standard.array(forKey: gestureBackupKey) as? [Int] else { return }
        let rows = GestureBinding.decodeTable(saved.map { UInt8($0) })
        Task {
            var ok = true
            for row in rows { ok = Self.acked(await request(NT.Cmd.setGestures, row.encodeSet())) && ok }
            await refreshGestures()
            report(ok && !gesturesDifferFromOriginal, String(localized: "Gestures"))
        }
    }

    // MARK: Mac-anchored spatial audio

    /// Turns the app's own binaural renderer on or off. While on, the headphone's built-in spatial
    /// processing is switched off so the effect is not applied twice.
    func setMacAnchored(_ on: Bool) {
        anchorWanted = on
        if on { Task { await startMacAnchor() } } else { stopMacAnchor(remember: false) }
    }

    func recenterHead() { headPose.recenter() }

    private func startMacAnchor() async {
        guard connection == .connected, !macAnchored else { return }
        if spatial?.on == true {
            _ = await request(NT.Cmd.setSpatial, [0, 0])
            await refreshSpatial()
        }
        // Start the sensor stream and wait for the first sample so "forward" is the current pose.
        headPose.reset()
        _ = await request(NT.Cmd.startHeadStream)
        do {
            try spatialEngine.start(outputDeviceNameContaining: "nothing")
        } catch {
            anchorWanted = false
            anchorDetail = ""
            status = String(format: String(localized: "[ERROR: %@]"), error.localizedDescription)
            return
        }
        macAnchored = true
        anchorDetail = String(localized: "Capturing system audio")
        // The sensor stream sometimes does not start on the first request: ask again until samples arrive.
        Task {
            for attempt in 1...4 {
                try? await Task.sleep(for: .seconds(2))
                guard macAnchored, headPose.sampleCount == 0 else { return }
                _ = await request(NT.Cmd.startHeadStream)
            }
        }
        anchorTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.anchorTick() }
        }
    }

    private var anchorTicks = 0
    private var lastSampleCount = 0

    private func anchorTick() {
        let a = headPose.orientation(now: Date.timeIntervalSinceReferenceDate, sensitivity: anchorSensitivity)
        anchorTicks += 1
        if anchorTicks % 30 == 0 {   // twice a second: live feedback
            let rate = (headPose.sampleCount - lastSampleCount) * 2
            lastSampleCount = headPose.sampleCount
            anchorDetail = rate == 0
                ? String(localized: "No sensor data")
                : String(format: String(localized: "Tracking · yaw %+.0f°"), headPose.current.yaw)
        }
        // Axis conventions checked by ear: the listener yaw has to be the opposite of the sensor yaw
        // (sensor + = head turned left), otherwise the sound slides the wrong way.
        spatialEngine.setListener(yaw: Float(-a.yaw), pitch: Float(a.pitch), roll: Float(-a.roll))
    }

    private func stopMacAnchor(remember: Bool) {
        anchorTimer?.invalidate(); anchorTimer = nil
        spatialEngine.stop()
        macAnchored = false
        anchorDetail = ""
        if !remember { anchorWanted = false }
    }
}
