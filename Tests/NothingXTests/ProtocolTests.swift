import XCTest
@testable import NothingX

final class CodecTests: XCTestCase {
    func testCRC16ModbusCheckValue() {
        // The standard CRC-16/MODBUS check value.
        XCTAssertEqual(Codec.crc16(Array("123456789".utf8)), 0x4B37)
        XCTAssertEqual(Codec.crc16([UInt8]()), 0xFFFF, "empty input is the init value")
    }

    func testEncodeReadFirmwareFrame() {
        // C042 read, opId 1, no payload (vector computed independently of the Swift code).
        XCTAssertEqual(Codec.encode(cmd: NT.Cmd.readFirmware, opId: 1, payload: []),
                       [0x55, 0x60, 0x01, 0x42, 0xC0, 0x00, 0x00, 0x01, 0x61, 0x10])
    }

    func testEncodeWithPayload() {
        XCTAssertEqual(Codec.encode(cmd: NT.Cmd.setANC, opId: 5, payload: [1, 1]),
                       [0x55, 0x60, 0x01, 0x0F, 0xF0, 0x02, 0x00, 0x05, 0x01, 0x01, 0x48, 0xF9])
    }

    func testEncodeIsLittleEndianAndSelfChecking() {
        let payload = [UInt8](repeating: 0xAB, count: 300)
        let f = Codec.encode(cmd: 0x1234, opId: 0xFE, payload: payload)
        XCTAssertEqual(Array(f[3...7]), [0x34, 0x12, 0x2C, 0x01, 0xFE], "cmd LE, len 300 LE, opId")
        XCTAssertEqual(f.count, 8 + 300 + 2)
        let crc = UInt16(f[f.count - 2]) | UInt16(f[f.count - 1]) << 8
        XCTAssertEqual(crc, Codec.crc16(f.dropLast(2)))
        XCTAssertEqual(Codec.crc16(f), 0, "CRC over frame including its own CRC is zero")
    }
}

final class FrameParserTests: XCTestCase {
    /// A frame with arbitrary control bytes (the head stream uses `55 20 03`), CRC computed by `Codec`.
    private func raw(control: [UInt8], cmd: UInt16, opId: UInt8, payload: [UInt8]) -> [UInt8] {
        let n = payload.count
        var out = control + [UInt8(cmd & 0xFF), UInt8(cmd >> 8), UInt8(n & 0xFF), UInt8(n >> 8), opId] + payload
        let crc = Codec.crc16(out)
        out += [UInt8(crc & 0xFF), UInt8(crc >> 8)]
        return out
    }

    func testSingleFrame() {
        var p = FrameParser()
        let frames = p.feed(Codec.encode(cmd: 0x4042, opId: 7, payload: Array("1.0.1.81".utf8)))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].cmd, 0x4042)
        XCTAssertEqual(frames[0].opId, 7)
        XCTAssertEqual(frames[0].payload, Array("1.0.1.81".utf8))
    }

    func testEmptyPayloadFrameAtMinimumLength() {
        var p = FrameParser()
        let frames = p.feed(Codec.encode(cmd: 0x7010, opId: 3, payload: []))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].payload, [])
    }

    func testFrameSplitAcrossChunks() {
        let bytes = Codec.encode(cmd: 0x4007, opId: 9, payload: [0x64, 0x00, 0x50])
        for split in 1..<bytes.count {
            var p = FrameParser()
            XCTAssertTrue(p.feed(Array(bytes[..<split])).isEmpty, "split at \(split)")
            let frames = p.feed(Array(bytes[split...]))
            XCTAssertEqual(frames.count, 1, "split at \(split)")
            XCTAssertEqual(frames.first?.payload, [0x64, 0x00, 0x50])
        }
    }

    func testByteByByte() {
        var p = FrameParser()
        let bytes = Codec.encode(cmd: 0x4007, opId: 1, payload: [1, 2, 3]) + Codec.encode(cmd: 0x4008, opId: 2, payload: [])
        var got: [Frame] = []
        for b in bytes { got += p.feed([b]) }
        XCTAssertEqual(got.map(\.cmd), [0x4007, 0x4008])
    }

    func testSeveralFramesInOneChunk() {
        var p = FrameParser()
        let a = Codec.encode(cmd: 0x4001, opId: 1, payload: [1])
        let b = Codec.encode(cmd: 0x4002, opId: 2, payload: [2, 2])
        let c = Codec.encode(cmd: 0x4003, opId: 3, payload: [3, 3, 3])
        let frames = p.feed(a + b + c)
        XCTAssertEqual(frames.map(\.cmd), [0x4001, 0x4002, 0x4003])
        XCTAssertEqual(frames.map(\.opId), [1, 2, 3])
    }

    func testResyncAfterGarbage() {
        var p = FrameParser()
        let good = Codec.encode(cmd: 0x4007, opId: 4, payload: [9, 8])
        let frames = p.feed([0x00, 0xFF, 0x13, 0x37] + good)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].payload, [9, 8])
    }

    func testResyncAfterGarbageContainingStartBytes() {
        var p = FrameParser()
        let good = Codec.encode(cmd: 0x4007, opId: 4, payload: [9, 8])
        // A fake complete header (starts with 0x55, bad CRC) precedes the real frame.
        let fake: [UInt8] = [0x55, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let frames = p.feed(fake + good)
        XCTAssertEqual(frames.map(\.cmd), [0x4007])
    }

    func testGarbageOnlyDoesNotAccumulateOrProduceFrames() {
        var p = FrameParser()
        XCTAssertTrue(p.feed([UInt8](repeating: 0xAA, count: 5000)).isEmpty)
        // The parser is still healthy afterwards.
        XCTAssertEqual(p.feed(Codec.encode(cmd: 0x4001, opId: 1, payload: [])).count, 1)
    }

    func testHeadStreamControlBytes() {
        var p = FrameParser()
        let payload = (0..<16).map { UInt8($0) }
        let frame = raw(control: [0x55, 0x20, 0x03], cmd: 0xE015, opId: 0, payload: payload)
        let frames = p.feed(frame)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].cmd, 0xE015)
        XCTAssertEqual(frames[0].payload, payload)
    }

    func testBothControlByteVariantsInterleaved() {
        var p = FrameParser()
        let a = Codec.encode(cmd: 0x4007, opId: 1, payload: [5])
        let b = raw(control: [0x55, 0x20, 0x03], cmd: 0xE015, opId: 0, payload: [UInt8](repeating: 0, count: 16))
        let c = Codec.encode(cmd: 0x401E, opId: 2, payload: [7, 0])
        XCTAssertEqual(p.feed(a + b + c).map(\.cmd), [0x4007, 0xE015, 0x401E])
    }

    func testKnownHeadStreamVector() {
        // 55 20 03 E015 len 16, zero payload (vector computed independently of the Swift code).
        let hex = "55 20 03 15 E0 10 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 56 88"
        let bytes = hex.split(separator: " ").map { UInt8($0, radix: 16)! }
        var p = FrameParser()
        let frames = p.feed(bytes)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].payload.count, 16)
    }

    func testBadCRCRejected() {
        var p = FrameParser()
        var bad = Codec.encode(cmd: 0x4007, opId: 1, payload: [1, 2, 3])
        bad[bad.count - 1] ^= 0xFF
        XCTAssertTrue(p.feed(bad).isEmpty)
        // Corrupted payload byte, intact CRC.
        var bad2 = Codec.encode(cmd: 0x4007, opId: 1, payload: [1, 2, 3])
        bad2[9] ^= 0x01
        XCTAssertTrue(p.feed(bad2).isEmpty)
    }

    func testGoodFrameAfterBadCRCStillParses() {
        var p = FrameParser()
        var bad = Codec.encode(cmd: 0x4007, opId: 1, payload: [1, 2, 3])
        bad[bad.count - 2] ^= 0x55
        let good = Codec.encode(cmd: 0x4008, opId: 2, payload: [4])
        let frames = p.feed(bad + good)
        XCTAssertEqual(frames.map(\.cmd), [0x4008])
    }

    func testOversizedLengthRejected() {
        var p = FrameParser()
        // Declared length 0xFFFF: a parser that believed it would wait for 64 KB and swallow the next frames.
        let oversized: [UInt8] = [0x55, 0x60, 0x01, 0x07, 0x40, 0xFF, 0xFF, 0x01, 0x00, 0x00]
        let good = Codec.encode(cmd: 0x4008, opId: 2, payload: [4])
        let frames = p.feed(oversized + good)
        XCTAssertEqual(frames.map(\.cmd), [0x4008])
    }

    func testLengthJustAboveLimitRejectedAndAtLimitAccepted() {
        var p = FrameParser()
        var over = raw(control: [0x55, 0x60, 0x01], cmd: 0x4007, opId: 1, payload: [UInt8](repeating: 1, count: 2049))
        XCTAssertTrue(p.feed(over).isEmpty, "2049 > 2048 is dropped even with a valid CRC")
        over.removeAll()
        let atLimit = raw(control: [0x55, 0x60, 0x01], cmd: 0x4007, opId: 1, payload: [UInt8](repeating: 1, count: 2048))
        let frames = p.feed(atLimit)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.payload.count, 2048)
    }

    func testResetDropsPartialFrame() {
        var p = FrameParser()
        let bytes = Codec.encode(cmd: 0x4007, opId: 1, payload: [1, 2, 3])
        XCTAssertTrue(p.feed(Array(bytes[..<6])).isEmpty)
        p.reset()
        XCTAssertTrue(p.feed(Array(bytes[6...])).isEmpty, "the tail alone is not a frame")
        XCTAssertEqual(p.feed(bytes).count, 1)
    }
}

final class EQProfileTests: XCTestCase {
    private func profile() -> EQProfile {
        let freqs: [Float] = [55, 110, 220, 440, 1320, 3300, 6600, 13200]
        let gains: [Float] = [6, 5, -3.5, 1.25, 0, -12, 0.5, 9.75]
        let bands = (0..<8).map { EQBand(id: $0, type: UInt8($0 % 3), gain: gains[$0], freq: freqs[$0], q: 0.7 + Float($0) / 10) }
        return EQProfile(profile: 5, gain: -2.5, bands: bands)
    }

    func testRoundTrip() {
        let p = profile()
        XCTAssertEqual(EQProfile.decode(p.encode()), p)
    }

    func testEncodedLayout() {
        let bytes = profile().encode()
        XCTAssertEqual(bytes.count, 6 + 8 * 13)
        XCTAssertEqual(bytes[0], 5)
        XCTAssertEqual(bytes[1], 8)
        // -2.5 f32 LE = 0xC0200000
        XCTAssertEqual(Array(bytes[2..<6]), [0x00, 0x00, 0x20, 0xC0])
        XCTAssertEqual(bytes[6], 0, "first band type")
        // 6.0 f32 LE = 0x40C00000
        XCTAssertEqual(Array(bytes[7..<11]), [0x00, 0x00, 0xC0, 0x40])
        // 55.0 f32 LE = 0x425C0000
        XCTAssertEqual(Array(bytes[11..<15]), [0x00, 0x00, 0x5C, 0x42])
    }

    func testFlatEmptyProfile() {
        let p = EQProfile(profile: 0, gain: 0, bands: [])
        XCTAssertEqual(p.encode(), [0, 0, 0, 0, 0, 0])
        XCTAssertEqual(EQProfile.decode(p.encode()), p)
    }

    func testDecodeRejectsTruncated() {
        XCTAssertNil(EQProfile.decode([]))
        XCTAssertNil(EQProfile.decode([0, 0, 0, 0, 0]))
        let bytes = profile().encode()
        XCTAssertNil(EQProfile.decode(Array(bytes.dropLast())), "last band incomplete")
    }

    func testDecodeIgnoresTrailingBytes() {
        let p = profile()
        XCTAssertEqual(EQProfile.decode(p.encode() + [0xDE, 0xAD]), p)
    }

    func testBandIdsFollowPosition() {
        let decoded = EQProfile.decode(profile().encode())
        XCTAssertEqual(decoded?.bands.map(\.id), Array(0..<8))
    }
}

final class GestureAndSpatialTests: XCTestCase {
    func testDecodeGestureTable() {
        // 2 rows: roller press -> play/pause, button triple press -> next.
        let rows = GestureBinding.decodeTable([2, 6, 1, 1, 9, 6, 0x0A, 7, 8])
        XCTAssertEqual(rows, [GestureBinding(side: 6, button: 1, gesture: 1, action: 9),
                              GestureBinding(side: 6, button: 0x0A, gesture: 7, action: 8)])
    }

    func testDecodeGestureTableEdgeCases() {
        XCTAssertEqual(GestureBinding.decodeTable([]), [])
        XCTAssertEqual(GestureBinding.decodeTable([0]), [])
        // Declares 3 rows but only 1.5 are present: keeps the complete one.
        XCTAssertEqual(GestureBinding.decodeTable([3, 6, 1, 1, 9, 6, 0x0A]).count, 1)
    }

    func testEncodeSet() {
        XCTAssertEqual(GestureBinding(side: 6, button: 0x0A, gesture: 7, action: 0x0B).encodeSet(), [1, 6, 0x0A, 7, 0x0B])
    }

    func testIdentityIsButtonAndGesture() {
        XCTAssertEqual(GestureBinding(side: 6, button: 0x0A, gesture: 7, action: 1).id, 0x0A07)
        XCTAssertEqual(GestureBinding(side: 6, button: 1, gesture: 1, action: 9).id, 0x0101)
    }

    func testSpatialDecodeEncode() {
        XCTAssertEqual(SpatialState.decode([1, 1]), SpatialState(on: true, headTracking: true))
        XCTAssertEqual(SpatialState.decode([1, 0]), SpatialState(on: true, headTracking: false))
        XCTAssertEqual(SpatialState.decode([0, 1]), SpatialState(on: false, headTracking: true))
        XCTAssertEqual(SpatialState.decode([2, 7]), SpatialState(on: true, headTracking: true), "non-zero is on")
        XCTAssertEqual(SpatialState.decode([1]), SpatialState(on: true, headTracking: false), "short payload")
        XCTAssertNil(SpatialState.decode([]))
    }

    func testSpatialEncode() {
        XCTAssertEqual(SpatialState(on: true, headTracking: false).encode(), [1, 0])
        XCTAssertEqual(SpatialState(on: false, headTracking: true).encode(), [0, 1])
        for on in [false, true] {
            for head in [false, true] {
                let s = SpatialState(on: on, headTracking: head)
                XCTAssertEqual(SpatialState.decode(s.encode()), s)
            }
        }
    }
}

final class DeviceSettingTests: XCTestCase {
    func testFeatureTableSample() {
        let sample: [UInt8] = [0x09, 0x01, 0x00, 0x02, 0x01, 0x07, 0x01, 0x09, 0x01, 0x0A, 0x01,
                               0x0B, 0x00, 0x0E, 0x01, 0x12, 0x01, 0x15, 0x01]
        let table = DeviceFeatureTable.decode(sample)
        XCTAssertEqual(table?.entries.count, 9)
        XCTAssertEqual(table?.entries.first, DeviceFeatureTable.Entry(id: 0x01, flag: 0))
        XCTAssertEqual(table?.entries.last, DeviceFeatureTable.Entry(id: 0x15, flag: 1))
        XCTAssertEqual(table?.inEarDetectionOn, false, "feature 01 is 00 in the sample")
        XCTAssertEqual(table?.flag(0x02), true)
        XCTAssertEqual(table?.flag(0x0B), false)
        XCTAssertEqual(table?.flag(0x0E), true)
        XCTAssertNil(table?.flag(0x7F), "unknown feature")
    }

    func testFeatureTableInEarOn() {
        XCTAssertEqual(DeviceFeatureTable.decode([1, 1, 1])?.inEarDetectionOn, true)
        XCTAssertEqual(DeviceFeatureTable.decode([1, 1, 5])?.inEarDetectionOn, true, "any non-zero is on")
    }

    func testFeatureTableAbsentInEarIsUnknown() {
        XCTAssertNil(DeviceFeatureTable.decode([1, 2, 1])?.inEarDetectionOn)
        XCTAssertEqual(DeviceFeatureTable.decode([0]), DeviceFeatureTable(entries: []))
        XCTAssertNil(DeviceFeatureTable.decode([0])?.inEarDetectionOn)
    }

    func testFeatureTableTruncationKeepsCompletePairs() {
        let t = DeviceFeatureTable.decode([3, 1, 1, 2, 0, 3])
        XCTAssertEqual(t?.entries, [.init(id: 1, flag: 1), .init(id: 2, flag: 0)])
        XCTAssertNil(DeviceFeatureTable.decode([]))
    }

    func testSetFeatureFlagPayload() {
        XCTAssertEqual(DeviceFeatureTable.encodeSet(feature: 1, on: true), [1, 1, 1])
        XCTAssertEqual(DeviceFeatureTable.encodeSet(feature: 1, on: false), [1, 1, 0])
        XCTAssertEqual(DeviceFeatureTable.encodeInEarDetection(on: true), [1, 1, 1])
        XCTAssertEqual(DeviceFeatureTable.encodeInEarDetection(on: false), [1, 1, 0])
        XCTAssertEqual(DeviceFeatureTable.encodeSet(feature: 0x0E, on: true), [1, 0x0E, 1])
    }

    func testLowLatency() {
        XCTAssertEqual(DeviceSetting.decodeLowLatency([1]), true)
        XCTAssertEqual(DeviceSetting.decodeLowLatency([2]), false)
        XCTAssertNil(DeviceSetting.decodeLowLatency([0]), "0 is not part of the protocol")
        XCTAssertNil(DeviceSetting.decodeLowLatency([3]))
        XCTAssertNil(DeviceSetting.decodeLowLatency([]))
        XCTAssertEqual(DeviceSetting.encodeLowLatency(true), [1])
        XCTAssertEqual(DeviceSetting.encodeLowLatency(false), [2], "off is 2, not 0")
        for on in [false, true] {
            XCTAssertEqual(DeviceSetting.decodeLowLatency(DeviceSetting.encodeLowLatency(on)), on)
        }
    }

    func testPlainFlag() {
        XCTAssertEqual(DeviceSetting.decodeFlag([1]), true)
        XCTAssertEqual(DeviceSetting.decodeFlag([0]), false)
        XCTAssertEqual(DeviceSetting.decodeFlag([9]), true)
        XCTAssertNil(DeviceSetting.decodeFlag([]))
        XCTAssertEqual(DeviceSetting.encodeFlag(true), [1])
        XCTAssertEqual(DeviceSetting.encodeFlag(false), [0])
    }

    func testAudioCodec() {
        XCTAssertEqual(AudioCodec.decode([0]), .standard)
        XCTAssertEqual(AudioCodec.decode([2]), .ldac)
        XCTAssertNil(AudioCodec.decode([1]), "ACKed by the firmware but meaningless")
        XCTAssertNil(AudioCodec.decode([3]))
        XCTAssertNil(AudioCodec.decode([]))
        XCTAssertEqual(AudioCodec.standard.encode(), [0])
        XCTAssertEqual(AudioCodec.ldac.encode(), [2])
        XCTAssertEqual(AudioCodec.allCases.count, 2)
    }

    func testFindMyHeadphone() {
        XCTAssertEqual(FindMyHeadphone.payload(on: true), [6, 1])
        XCTAssertEqual(FindMyHeadphone.payload(on: false), [6, 0])
    }

    func testCommandIds() {
        XCTAssertEqual(NT.Cmd.readLowLatency, 0xC041)
        XCTAssertEqual(NT.Cmd.setLowLatency, 0xF040)
        XCTAssertEqual(NT.Cmd.readFeatureFlags, 0xC00E)
        XCTAssertEqual(NT.Cmd.setFeatureFlag, 0xF004)
        XCTAssertEqual(NT.Cmd.readCodec, 0xC029)
        XCTAssertEqual(NT.Cmd.setCodec, 0xF01C)
        XCTAssertEqual(NT.Cmd.findHeadphone, 0xF002)
    }

    func testANCStateKinds() {
        XCTAssertEqual(ANCState.kind(of: 5), .off)
        XCTAssertEqual(ANCState.kind(of: 7), .transparency)
        for raw in [UInt8(1), 2, 3, 4] { XCTAssertEqual(ANCState.kind(of: raw), .anc) }
    }
}
