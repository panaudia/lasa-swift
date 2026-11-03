// The per-packet record, byte-identical to go/record/record.go so one
// analysis script reads both. Preallocated; append never allocates.

import Foundation

// One writer at a time, the receive loop; the Sendable mark is the
// caller's contract, not a lock.
public final class RecordWriter: @unchecked Sendable {
    public static let recordSize = 32
    static let headerSize = 16
    static let magic: [UInt8] = Array("LASAPRB1".utf8)

    private let buffer: UnsafeMutableRawBufferPointer
    private let capacity: Int
    private(set) public var count = 0
    private(set) public var dropped = 0

    /// 200 packets per second for fifteen minutes is 180,000 records.
    public init(maxRecords: Int = 200 * 60 * 15) {
        capacity = maxRecords
        buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: Self.headerSize + maxRecords * Self.recordSize,
            alignment: 8)
        buffer.initializeMemory(as: UInt8.self, repeating: 0)
    }

    deinit { buffer.deallocate() }

    /// Call from the receive loop only (one writer).
    @inline(__always)
    public func append(seq: UInt64, arrivalNS: Int64, serverUS: UInt64, payloadLen: UInt32) {
        guard count < capacity else { dropped += 1; return }
        let off = Self.headerSize + count * Self.recordSize
        buffer.storeBytes(of: seq.littleEndian, toByteOffset: off, as: UInt64.self)
        buffer.storeBytes(of: arrivalNS.littleEndian, toByteOffset: off + 8, as: Int64.self)
        buffer.storeBytes(of: serverUS.littleEndian, toByteOffset: off + 16, as: UInt64.self)
        buffer.storeBytes(of: payloadLen.littleEndian, toByteOffset: off + 24, as: UInt32.self)
        let flags: UInt32 = serverUS != 0 ? 1 : 0
        buffer.storeBytes(of: flags.littleEndian, toByteOffset: off + 28, as: UInt32.self)
        count += 1
    }

    /// A lifecycle or stall mark in the record stream (flags bit 1; the
    /// probes' event codes, analysis/analyse.py names them), at `nowNS`,
    /// with `arg` in the seq slot. Same layout as the Go record's
    /// AppendEvent.
    public func appendEvent(nowNS: Int64, code: UInt32, arg: UInt64 = 0) {
        guard count < capacity else { dropped += 1; return }
        let off = Self.headerSize + count * Self.recordSize
        buffer.storeBytes(of: arg.littleEndian, toByteOffset: off, as: UInt64.self)
        buffer.storeBytes(of: nowNS.littleEndian, toByteOffset: off + 8, as: Int64.self)
        buffer.storeBytes(of: UInt64(0), toByteOffset: off + 16, as: UInt64.self)
        buffer.storeBytes(of: code.littleEndian, toByteOffset: off + 24, as: UInt32.self)
        buffer.storeBytes(of: UInt32(2).littleEndian, toByteOffset: off + 28, as: UInt32.self)
        count += 1
    }

    public func flush(to url: URL) throws {
        for (i, b) in Self.magic.enumerated() { buffer[i] = b }
        buffer.storeBytes(of: UInt32(1).littleEndian, toByteOffset: 8, as: UInt32.self)
        buffer.storeBytes(of: UInt32(0).littleEndian, toByteOffset: 12, as: UInt32.self)
        let length = Self.headerSize + count * Self.recordSize
        try Data(bytes: buffer.baseAddress!, count: length).write(to: url)
    }
}

/// Arrival clock for records: the wall clock, in unix nanoseconds, the
/// same reading Go's time.Now().UnixNano() gives. Deliberately not
/// monotonic (decided 2026-09-04 after T4 cell B): the server's anchors
/// are UTC and the phone's wall clock is NTP-disciplined toward UTC, so
/// one-way delay reads cleanly, whereas the monotonic clock drifted
/// 40 ppm with temperature and smeared it. NTP slew cannot disturb
/// inter-arrival at the ms scale; a step would show as one absurd
/// interval.
public enum ArrivalClock {
    @inline(__always)
    public static func nowNS() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
    }
}
