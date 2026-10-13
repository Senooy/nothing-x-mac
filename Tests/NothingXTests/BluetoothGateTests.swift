import XCTest
import CoreBluetooth
@testable import NothingX

final class BluetoothGateTests: XCTestCase {
    func testGateForEveryKnownAuthorization() {
        XCTAssertEqual(BluetoothGate.gate(for: .notDetermined), .pending)
        XCTAssertEqual(BluetoothGate.gate(for: .restricted), .denied)
        XCTAssertEqual(BluetoothGate.gate(for: .denied), .denied)
        XCTAssertEqual(BluetoothGate.gate(for: .allowedAlways), .allowed)
    }

    func testUnknownRawValueIsDenied() {
        // A value a future macOS could add: the @unknown default must fail closed.
        let unknown = CBManagerAuthorization(rawValue: 9999)
        XCTAssertNotNil(unknown)
        XCTAssertEqual(BluetoothGate.gate(for: unknown!), .denied)
    }

    func testRawValuesMapAsDocumented() {
        let expected: [Int: BluetoothGate] = [0: .pending, 1: .denied, 2: .denied, 3: .allowed]
        for (raw, gate) in expected {
            XCTAssertEqual(BluetoothGate.gate(for: CBManagerAuthorization(rawValue: raw)!), gate, "raw \(raw)")
        }
    }

    func testLinkState() {
        XCTAssertEqual(BluetoothGate.pending.linkState, .permissionPending)
        XCTAssertEqual(BluetoothGate.denied.linkState, .permissionDenied)
        XCTAssertNil(BluetoothGate.allowed.linkState, "the transport owns the state once allowed")
    }

    func testEveryClosedGateHasALinkState() {
        for auth in [CBManagerAuthorization.notDetermined, .restricted, .denied] {
            XCTAssertNotNil(BluetoothGate.gate(for: auth).linkState)
        }
    }
}
