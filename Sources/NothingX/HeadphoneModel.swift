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
    private var eqCommitRunning = false
    private var eqCommitQueued = false
    private var eqEditedAt = Date.distantPast
    private(set) var linkStarted = false

    init(startLink: Bool = true, startUSBMonitor: Bool = true) {
        transport.onState = { [weak self] state, name in
            MainActor.assumeIsolated { self?.linkChanged(state, name) }
        }
        transport.onFrame = { [weak self] frame in
            MainActor.assumeIsolated { self?.handle(frame) }
        }
        if startLink { self.startLink() }
        if startUSBMonitor { self.startUSBMonitor() }
        // The headphone can be changed from its own buttons or another device: poll the
        // cheap settings every few seconds, the battery less often.
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        setUpSoftwareEQ()
    }

    // MARK: Connection

    /// Starts the Bluetooth transport once. Deferred by the onboarding so the macOS prompt appears on its Bluetooth step.
    func startLink() {
        guard !linkStarted else { return }
        linkStarted = true
        transport.start()
    }

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
            resetDeviceSettings()
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
        syncSoftwareEQ()
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
        await refreshDeviceSettings()
    }

    private var pollTick = 0

    private func poll() async {
        guard connection == .connected, pending.isEmpty else { return }
        pollTick += 1
        await refreshANC()
        if let p = await request(NT.Cmd.readSpatial), let s = SpatialState.decode(p) { spatial = s }
        if !eqBusy, let p = await request(NT.Cmd.readEQPreset), let v = p.first, v != eqPreset { eqPreset = v; await refreshEQ() }
        if pollTick % 6 == 0 { await refreshBattery() }
        if pollTick % 6 == 3, deviceWrites == 0, !findPlaying { await refreshDeviceSettings() }   // 5 cheap reads, every ~30 s
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
        if isWired { return softwareSelectPreset(preset) }
        guard eqProfile != nil else { return }
        eqCommit?.cancel()
        eqCommit = nil
        eqEditedAt = Date()
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
        if isWired { return softwareSetBandGain(index, gain) }
        guard eqProfile?.bands.indices.contains(index) == true else { return }
        eqEditedAt = Date()
        eqProfile?.bands[index].gain = gain
    }

    /// True while the user is adjusting the bars or a commit is on its way: nothing may overwrite them.
    private var eqBusy: Bool {
        eqCommitRunning || eqCommit != nil || Date().timeIntervalSince(eqEditedAt) < 3
    }

    /// Sends the current bars as the Custom curve (called when a drag ends). Commits never overlap: edits
    /// made while one is in flight are sent right after it, always with the latest bars.
    func commitCustomEQ() {
        if isWired { return softwareCommitCustomEQ() }
        guard let current = eqProfile else { return }
        userCustomGains = current.bands.map(\.gain)
        eqEditedAt = Date()
        if eqCommitRunning { eqCommitQueued = true; return }
        eqCommit?.cancel()
        eqCommit = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            eqCommitRunning = true
            repeat {
                eqCommitQueued = false
                guard let eq = eqProfile else { break }
                var ok = Self.acked(await request(NT.Cmd.setCustomEQ, eq.encode()))
                if ok { ok = Self.acked(await request(NT.Cmd.setEQPreset, [EQPreset.deviceCustom, 0])) }
                await refreshEQ(keepBars: true)
                report(ok && eqPreset == EQPreset.deviceCustom, String(localized: "Custom EQ"))
            } while eqCommitQueued
            eqCommitRunning = false
            eqCommit = nil
            eqEditedAt = Date()
        }
    }

    func resetCustomEQ() {
        if isWired { return softwareResetEQ() }
        guard var eq = eqProfile else { return }
        for i in eq.bands.indices { eq.bands[i].gain = 0 }
        eq.gain = 0
        eqProfile = eq
        commitCustomEQ()
    }

    // MARK: EQ files (AutoEq / Equalizer APO)

    /// Import warnings, shown under the EQ buttons (`status` is red unless it is "[OK]").
    var eqImportNote = ""
    private var eqNoteClear: Task<Void, Never>?

    /// Applies a parametric EQ file to the custom curve (sent to the headphone and read back, like a
    /// manual edit) and returns the warnings. An empty-handed import changes nothing.
    @discardableResult
    func importEQ(from text: String) -> [String] {
        if isWired { return softwareImportEQ(text) }
        guard let current = eqProfile else {
            report(false, String(localized: "Not connected"))
            return []
        }
        guard spatial?.on != true else {
            report(false, String(localized: "EQ is disabled while spatial audio is on"))
            return []
        }
        let parsed = EQInterchange.parse(text)
        guard !parsed.filters.isEmpty else {
            report(false, String(localized: "No EQ filters found"))
            setEQImportNote(parsed.warnings)
            return parsed.warnings
        }
        let mapping = EQInterchange.map(parsed, base: current)
        withAnimation(.easeOut(duration: 0.3)) { eqProfile = mapping.profile }
        commitCustomEQ()
        setEQImportNote(mapping.warnings)
        return mapping.warnings
    }

    /// The current custom curve as `ParametricEQ.txt`, or nil until it has been read.
    func exportEQ() -> String? {
        if isWired { return EQInterchange.export(softwareEQProfile) }
        return eqProfile.map(EQInterchange.export)
    }

    /// For file read / write failures in the view.
    func reportEQFile(ok: Bool, _ what: String) { report(ok, what) }

    private func setEQImportNote(_ warnings: [String]) {
        let shown = warnings.prefix(3).joined(separator: "\n")
        let more = warnings.count > 3 ? "\n" + String(format: String(localized: "+ %d more"), warnings.count - 3) : ""
        eqImportNote = shown + more
        eqNoteClear?.cancel()
        guard !warnings.isEmpty else { return }
        eqNoteClear = Task {
            try? await Task.sleep(for: .seconds(12))
            if !Task.isCancelled { eqImportNote = "" }
        }
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
        if on { leaveSoftwareEQForMacAnchor() }
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
        // Off the main thread: Core Audio blocks until the System Audio Recording prompt is answered.
        anchorDetail = String(localized: "Waiting for audio permission…")
        let engine = spatialEngine
        let failure: String? = await Task.detached(priority: .userInitiated) {
            do { try engine.start(outputDeviceNameContaining: "nothing"); return nil } catch { return error.localizedDescription }
        }.value
        if let failure {
            anchorWanted = false
            anchorDetail = ""
            status = String(format: String(localized: "[ERROR: %@]"), failure)
            return
        }
        guard connection == .connected, anchorWanted else { engine.stop(); anchorDetail = ""; return }   // changed while waiting
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

    // MARK: Wired (USB)

    /// The headphone is plugged in by its USB cable. It drops Bluetooth while the cable is in, so the
    /// control link (noise control, battery, EQ, gestures, settings, head tracking) is unavailable.
    private(set) var usbPresent = false {
        didSet { if oldValue != usbPresent { syncSoftwareEQ() } }   // plug / unplug starts or stops the software EQ
    }

    /// Plugged in and not controllable over Bluetooth. Not a `Connection` case: the Bluetooth link code is unaffected.
    var isWired: Bool { usbPresent && connection != .connected }

    private let usbMonitor = USBHeadphoneMonitor()

    /// Cheap and non-blocking: IOKit notifications on the main run loop, no polling.
    private func startUSBMonitor() {
        usbMonitor.onChange = { [weak self] present in self?.usbChanged(present) }
        usbMonitor.start()
    }

    private func usbChanged(_ present: Bool) {
        usbPresent = present
        // Show the serial number even though the Bluetooth link never ran (the USB descriptor carries the same one).
        if present, serial == nil { serial = usbMonitor.serial }
        // The Mac-anchor renderer needs the Bluetooth sensor stream and output: stop it (the choice is remembered).
        if isWired { stopMacAnchor(remember: true) }
        WiredOutputController.shared.usbPresenceChanged(present)
    }

    // MARK: Software EQ

    // Wired (USB) mode: with the cable plugged in the headphone drops Bluetooth, so its own EQ is out of
    // reach. The Mac then equalizes everything it plays (`EQAudioEngine`) on a local 8-band profile, and
    // the EQ controls drive that profile instead of sending Bluetooth commands. Nothing here runs or
    // changes while not wired. Like the Mac anchor it captures and mutes system audio, so the two are
    // mutually exclusive.

    /// There is no switch: like the headphone's own EQ, the software EQ simply follows the presets and
    /// sliders. It runs only while wired and only when the curve actually changes the sound (a flat curve
    /// needs no capture), and not after the system refused audio capture until the curve is touched again.
    var softwareEQEnabled: Bool {
        !softwareEQBlocked && softwareEQProfile.bands.contains { abs($0.gain) >= 0.05 }
    }
    private var softwareEQBlocked = false
    private(set) var softwareEQRunning = false
    var softwareEQDetail = ""
    /// The local curve shown and applied while wired (8 bands, 55 Hz … 13.2 kHz, ±12 dB), persisted.
    var softwareEQProfile: EQProfile = HeadphoneModel.savedSoftwareEQProfile()
    private let eqEngine = EQAudioEngine()
    private var softwareEQStart: Task<Void, Never>?
    private static let softwareEQProfileKey = "softeq.profile"

    private static func savedSoftwareEQProfile() -> EQProfile {
        if let data = UserDefaults.standard.data(forKey: softwareEQProfileKey),
           let saved = EQProfile.decode(Array(data)), saved.bands.count == SoftwareEQ.frequencies.count {
            return saved
        }
        return SoftwareEQ.profile(gains: EQPreset.balanced.gains!)
    }

    /// Which EQ the equalizer controls drive right now.
    var eqPath: EQPath { EQPath.active(isWired: isWired) }

    var softwareSelectedPreset: EQPreset { SoftwareEQ.preset(matching: softwareEQProfile.bands.map(\.gain)) }

    /// Called once from `init`.
    private func setUpSoftwareEQ() {
        eqEngine.onDeviceLost = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.softwareEQRunning = false
                self.softwareEQDetail = ""
                self.syncSoftwareEQ()   // still wired (device reset): starts again; unplugged: stays off
            }
        }
        observeWiredForSoftwareEQ()
        syncSoftwareEQ()
    }

    /// Re-syncs whenever `isWired` changes (it is computed from observable state).
    private func observeWiredForSoftwareEQ() {
        withObservationTracking { _ = isWired } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncSoftwareEQ()
                self?.observeWiredForSoftwareEQ()
            }
        }
    }

    /// Starts or stops the engine to match the choice, the cable and the Mac anchor. Safe to call any time.
    /// `allowStop: false` while a slider is being dragged: passing through zero must not tear the engine down.
    func syncSoftwareEQ(allowStop: Bool = true) {
        if !isWired { softwareEQBlocked = false }   // a new plug-in gets a fresh attempt
        let active = softwareEQRunning || softwareEQStart != nil
        switch SoftwareEQPolicy.action(enabled: softwareEQEnabled, wired: isWired,
                                       macAnchorActive: macAnchored, active: active) {
        case .start: startSoftwareEQ()
        case .stop: if allowStop { stopSoftwareEQ() }
        case .none: break
        }
    }

    /// Called when the Mac anchor is turned on.
    private func leaveSoftwareEQForMacAnchor() {
        guard softwareEQRunning || softwareEQStart != nil else { return }
        stopSoftwareEQ()
    }

    /// Core Audio may publish the USB device a moment after the cable is detected: wait for it a little.
    private func startSoftwareEQ() {
        softwareEQStart = Task {
            for _ in 0..<10 {
                guard !Task.isCancelled else { return }
                guard SoftwareEQPolicy.shouldRun(enabled: softwareEQEnabled, wired: isWired, macAnchorActive: macAnchored) else {
                    softwareEQStart = nil
                    softwareEQDetail = ""
                    return
                }
                if let device = AudioDevices.usbOutputDevice(forSoftwareEQ: "nothing") {
                    // Core Audio can block for as long as the System Audio Recording prompt is unanswered,
                    // so the engine is started off the main thread and the window stays responsive.
                    let engine = eqEngine, bands = softwareEQProfile.bands
                    softwareEQDetail = String(localized: "Waiting for audio permission…")
                    let failure: String? = await Task.detached(priority: .userInitiated) {
                        do { try engine.start(device: device, bands: bands); return nil } catch { return error.localizedDescription }
                    }.value
                    if let failure {
                        // Capture refused or routing failed: switch off rather than retry in a loop.
                        softwareEQBlocked = true
                        softwareEQDetail = ""
                        status = String(format: String(localized: "[ERROR: %@]"), failure)
                    } else if SoftwareEQPolicy.shouldRun(enabled: softwareEQEnabled, wired: isWired, macAnchorActive: macAnchored) {
                        softwareEQRunning = true
                        softwareEQDetail = String(localized: "Equalizing system audio")
                        eqEngine.setBands(softwareEQProfile.bands)   // pick up edits made while it was starting
                    } else {
                        eqEngine.stop()   // turned off or unplugged while the permission prompt was open
                        softwareEQDetail = ""
                    }
                    softwareEQStart = nil
                    return
                }
                softwareEQDetail = String(localized: "Waiting for the headphone audio device")
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard !Task.isCancelled else { return }
            softwareEQStart = nil
            softwareEQDetail = ""
            report(false, String(localized: "Headphone USB audio device not found"))
        }
    }

    private func stopSoftwareEQ() {
        softwareEQStart?.cancel()
        softwareEQStart = nil
        eqEngine.stop()   // destroys the tap: system audio comes back by itself
        softwareEQRunning = false
        softwareEQDetail = ""
    }

    private func softwareApplyGains(_ gains: [Float], animated: Bool) {
        var profile = softwareEQProfile
        for i in profile.bands.indices where i < gains.count { profile.bands[i].gain = SoftwareEQ.clampedGain(gains[i]) }
        if animated { withAnimation(.easeOut(duration: 0.3)) { softwareEQProfile = profile } } else { softwareEQProfile = profile }
        softwareEQBlocked = false   // touching the curve retries after a refused capture
        eqEngine.setBands(profile.bands)
        syncSoftwareEQ(allowStop: animated)
    }

    private func saveSoftwareEQProfile() {
        UserDefaults.standard.set(Data(softwareEQProfile.encode()), forKey: Self.softwareEQProfileKey)
    }

    private func softwareSelectPreset(_ preset: EQPreset) {
        softwareApplyGains(preset.gains ?? userCustomGains, animated: true)
        saveSoftwareEQProfile()
    }

    /// Live while dragging: the engine follows every step.
    private func softwareSetBandGain(_ index: Int, _ gain: Float) {
        guard softwareEQProfile.bands.indices.contains(index) else { return }
        var gains = softwareEQProfile.bands.map(\.gain)
        gains[index] = gain
        softwareApplyGains(gains, animated: false)
    }

    /// End of a drag: the curve becomes the user's Custom curve (shared with the headphone's Custom preset).
    private func softwareCommitCustomEQ() {
        userCustomGains = softwareEQProfile.bands.map(\.gain)
        saveSoftwareEQProfile()
        syncSoftwareEQ()   // a drag that ended on a flat curve stops the engine
    }

    private func softwareResetEQ() {
        softwareApplyGains([Float](repeating: 0, count: softwareEQProfile.bands.count), animated: true)
        softwareCommitCustomEQ()
    }

    private func softwareImportEQ(_ text: String) -> [String] {
        let parsed = EQInterchange.parse(text)
        guard !parsed.filters.isEmpty else {
            report(false, String(localized: "No EQ filters found"))
            setEQImportNote(parsed.warnings)
            return parsed.warnings
        }
        let mapping = EQInterchange.map(parsed, base: softwareEQProfile)
        withAnimation(.easeOut(duration: 0.3)) { softwareEQProfile = mapping.profile }
        softwareEQBlocked = false
        eqEngine.setBands(mapping.profile.bands)
        softwareCommitCustomEQ()
        setEQImportNote(mapping.warnings)
        return mapping.warnings
    }

    // MARK: Device settings

    var lowLatency: Bool?
    var codec: AudioCodec?
    var dualConnection: Bool?
    var adaptiveANC: Bool?
    var inEarDetection: Bool?
    /// True while a find-my-headphone pulse is playing.
    var findPlaying = false

    /// Writes in flight: the slower poll skips device settings meanwhile so it cannot overwrite a fresh value.
    private var deviceWrites = 0
    /// Set when a codec change is sent: the headphone then drops the link to renegotiate A2DP, so the
    /// check happens after the reconnect (see `refreshDeviceSettings`).
    private var codecExpectation: (codec: AudioCodec, since: Date)?
    private var findTask: Task<Void, Never>?
    private static let findPulseSeconds = 2.0

    private func resetDeviceSettings() {
        lowLatency = nil
        codec = nil
        dualConnection = nil
        adaptiveANC = nil
        inEarDetection = nil
        findTask?.cancel()
        findPlaying = false
    }

    func refreshDeviceSettings() async {
        await refreshLowLatency()
        await refreshDualConnection()
        await refreshAdaptiveANC()
        await refreshInEarDetection()
        let current = await refreshCodec()
        if let expected = codecExpectation, let current {
            codecExpectation = nil
            if Date().timeIntervalSince(expected.since) < 60 {
                report(current == expected.codec, String(localized: "Audio codec"))
            }
        }
    }

    @discardableResult
    func refreshLowLatency() async -> Bool? {
        guard let p = await request(NT.Cmd.readLowLatency), let v = DeviceSetting.decodeLowLatency(p) else { return nil }
        lowLatency = v
        return v
    }

    @discardableResult
    func refreshCodec() async -> AudioCodec? {
        guard let p = await request(NT.Cmd.readCodec) else { return nil }
        let v = AudioCodec.decode(p)   // 1 and 3 are not meaningful here: shown as no selection
        codec = v
        return v
    }

    @discardableResult
    func refreshDualConnection() async -> Bool? {
        guard let p = await request(NT.Cmd.readDualConnection), let v = DeviceSetting.decodeFlag(p) else { return nil }
        dualConnection = v
        return v
    }

    @discardableResult
    func refreshAdaptiveANC() async -> Bool? {
        guard let p = await request(NT.Cmd.readAdaptiveANC), let v = DeviceSetting.decodeFlag(p) else { return nil }
        adaptiveANC = v
        return v
    }

    @discardableResult
    func refreshInEarDetection() async -> Bool? {
        guard let p = await request(NT.Cmd.readFeatureFlags), let table = DeviceFeatureTable.decode(p),
              let v = table.inEarDetectionOn else { return nil }
        inEarDetection = v
        return v
    }

    /// Write, then read back; `readBack` returns whether the headphone now holds the requested value.
    private func commitDeviceSetting(_ cmd: UInt16, _ payload: [UInt8], _ what: String,
                                     readBack: @escaping () async -> Bool) {
        deviceWrites += 1
        Task {
            let r = await request(cmd, payload)
            let stored = await readBack()
            deviceWrites -= 1
            report(Self.acked(r) && stored, what)
        }
    }

    func setLowLatency(_ on: Bool) {
        lowLatency = on
        commitDeviceSetting(NT.Cmd.setLowLatency, DeviceSetting.encodeLowLatency(on), String(localized: "Low latency")) {
            await self.refreshLowLatency() == on
        }
    }

    func setDualConnection(_ on: Bool) {
        dualConnection = on
        commitDeviceSetting(NT.Cmd.setDualConnection, DeviceSetting.encodeFlag(on), String(localized: "Dual connection")) {
            await self.refreshDualConnection() == on
        }
    }

    func setAdaptiveANC(_ on: Bool) {
        adaptiveANC = on
        commitDeviceSetting(NT.Cmd.setAdaptiveANC, DeviceSetting.encodeFlag(on), String(localized: "Adaptive ANC")) {
            await self.refreshAdaptiveANC() == on
        }
    }

    /// Only feature `01` of the `C00E` table is ever written.
    func setInEarDetection(_ on: Bool) {
        inEarDetection = on
        commitDeviceSetting(NT.Cmd.setFeatureFlag, DeviceFeatureTable.encodeInEarDetection(on: on),
                            String(localized: "In-ear detection")) {
            await self.refreshInEarDetection() == on
        }
    }

    /// The headphone drops the RFCOMM link after a codec change (A2DP renegotiation): a missing reply
    /// or a closed link is expected, not an error. The result is checked after the reconnect.
    func setCodec(_ newCodec: AudioCodec) {
        guard newCodec != codec else { return }
        codec = newCodec
        codecExpectation = (newCodec, Date())
        deviceWrites += 1
        Task {
            _ = await request(NT.Cmd.setCodec, newCodec.encode())
            if connection == .connected {
                var current = await refreshCodec()
                if current != newCodec && connection == .connected {
                    try? await Task.sleep(for: .seconds(4))   // the drop may come a moment after the ACK
                    if connection == .connected { current = await refreshCodec() }
                }
                if connection == .connected, codecExpectation != nil {
                    codecExpectation = nil
                    report(current == newCodec, String(localized: "Audio codec"))
                }
            }
            deviceWrites -= 1
        }
    }

    /// Experimental: rings the headphone for a few seconds, then always sends off. Loud if worn:
    /// the UI asks to take it off first.
    func startFindPulse() {
        guard connection == .connected, !findPlaying else { return }
        findPlaying = true
        findTask = Task {
            let on = Self.acked(await request(NT.Cmd.findHeadphone, FindMyHeadphone.payload(on: true)))
            if on { try? await Task.sleep(for: .seconds(Self.findPulseSeconds)) }   // cancelled by stopFind
            let off = Self.acked(await request(NT.Cmd.findHeadphone, FindMyHeadphone.payload(on: false)))
            findPlaying = false
            report(on && off, String(localized: "Find my headphone"))
        }
    }

    func stopFind() { findTask?.cancel() }
}
