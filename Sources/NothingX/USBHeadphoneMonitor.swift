import Foundation
import IOKit
import Observation

// Detects the headphone being plugged in by its USB-C cable. While the cable is in, the headphone drops
// Bluetooth by design, so this is the only signal the app has in wired mode. Imports nothing from the rest
// of the app so the file can be compiled alone in a throwaway tool.

/// What the monitor decides from a USB device's registry properties. Pure, so it is unit-tested.
enum USBHeadphoneMatch {
    /// "Nothing Tech" USB vendor id.
    static let vendorID = 0xBE58
    /// Other Nothing USB products must not match: the product name has to say "Headphone".
    static let productFragment = "Headphone"

    static func matches(vendorID: Int, productName: String?) -> Bool {
        guard vendorID == Self.vendorID, let productName else { return false }
        return productName.localizedCaseInsensitiveContains(productFragment)
    }
}

/// The set of matching devices currently attached, by registry entry id. A terminated notification can
/// arrive after the device's properties are gone, so removal goes by id and never by re-reading the name.
struct USBPresenceTracker: Equatable {
    struct Entry: Equatable { let productName: String; let serial: String? }

    private(set) var entries: [UInt64: Entry] = [:]

    var isPresent: Bool { !entries.isEmpty }
    /// The most recently attached device, if two ever matched at once.
    private(set) var current: Entry?
    private var order: [UInt64] = []

    mutating func attach(id: UInt64, productName: String, serial: String?) {
        let entry = Entry(productName: productName, serial: serial)
        entries[id] = entry
        order.removeAll { $0 == id }
        order.append(id)
        current = entry
    }

    /// Returns false when the id was not tracked (a device that never matched).
    @discardableResult
    mutating func detach(id: UInt64) -> Bool {
        guard entries.removeValue(forKey: id) != nil else { return false }
        order.removeAll { $0 == id }
        current = order.last.flatMap { entries[$0] }
        return true
    }
}

@MainActor
@Observable
final class USBHeadphoneMonitor {
    private(set) var isPresent = false
    private(set) var productName: String?
    private(set) var serial: String?

    /// Called on the main thread whenever `isPresent` flips.
    @ObservationIgnored var onChange: ((Bool) -> Void)?

    @ObservationIgnored private var tracker = USBPresenceTracker()
    @ObservationIgnored private var session: Session?

    /// Starts watching and reports devices already attached before it returns. Cheap: no polling, no I/O
    /// beyond a registry walk of the (at most one) device with this vendor id.
    func start() {
        guard session == nil else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let session = Session(refcon: refcon) else { return }
        self.session = session
        // Draining an iterator arms its notification, and yields what is attached right now.
        drainAttached(session.firstMatch)
        drainTerminated(session.terminated)
    }

    func stop() {
        session = nil
        tracker = USBPresenceTracker()
        publish()
    }

    // MARK: Iterators

    fileprivate func drainAttached(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { continue }
            let vendor = Self.number(service, "idVendor") ?? 0
            let name = Self.string(service, "kUSBProductString") ?? Self.string(service, "USB Product Name")
            guard USBHeadphoneMatch.matches(vendorID: vendor, productName: name), let name else { continue }
            let serial = Self.string(service, "kUSBSerialNumberString") ?? Self.string(service, "USB Serial Number")
            tracker.attach(id: entryID, productName: name, serial: serial)
        }
        publish()
    }

    fileprivate func drainTerminated(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var entryID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS { tracker.detach(id: entryID) }
        }
        publish()
    }

    private func publish() {
        let present = tracker.isPresent
        let was = isPresent
        productName = tracker.current?.productName
        serial = tracker.current?.serial
        isPresent = present
        if present != was { onChange?(present) }
    }

    // MARK: Registry properties

    private static func string(_ service: io_registry_entry_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    private static func number(_ service: io_registry_entry_t, _ key: String) -> Int? {
        (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber)?.intValue
    }

    // MARK: IOKit resources

    /// Owns the notification port and the two iterators; its `deinit` tears everything down.
    private final class Session {
        let port: IONotificationPortRef
        var firstMatch: io_iterator_t = 0
        var terminated: io_iterator_t = 0

        init?(refcon: UnsafeMutableRawPointer) {
            guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return nil }
            self.port = port
            if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            }
            // Each registration consumes its matching dictionary: build a fresh one for each.
            let first = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, Self.matching(), { refcon, iterator in
                guard let refcon else { return }
                let monitor = Unmanaged<USBHeadphoneMonitor>.fromOpaque(refcon).takeUnretainedValue()
                MainActor.assumeIsolated { monitor.drainAttached(iterator) }
            }, refcon, &firstMatch)
            let gone = IOServiceAddMatchingNotification(port, kIOTerminatedNotification, Self.matching(), { refcon, iterator in
                guard let refcon else { return }
                let monitor = Unmanaged<USBHeadphoneMonitor>.fromOpaque(refcon).takeUnretainedValue()
                MainActor.assumeIsolated { monitor.drainTerminated(iterator) }
            }, refcon, &terminated)
            guard first == KERN_SUCCESS, gone == KERN_SUCCESS else {
                teardown()
                return nil
            }
        }

        /// USB devices of the Nothing vendor. The product name is checked in `USBHeadphoneMatch`.
        private static func matching() -> CFMutableDictionary {
            let dict = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
            // Matched against the registry properties; a top-level `idVendor` key matches nothing on IOUSBHostDevice.
            dict["IOPropertyMatch"] = ["idVendor": NSNumber(value: USBHeadphoneMatch.vendorID)]
            return dict as CFMutableDictionary
        }

        private func teardown() {
            if firstMatch != 0 { IOObjectRelease(firstMatch); firstMatch = 0 }
            if terminated != 0 { IOObjectRelease(terminated); terminated = 0 }
            if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            IONotificationPortDestroy(port)
        }

        deinit { teardown() }
    }
}
