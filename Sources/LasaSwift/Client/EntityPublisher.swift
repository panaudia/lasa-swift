// One entity's source track (plan lasa-swift.md §2.3): the gapless
// sequencer with the repeat emitter, the pose cell the pump reads at
// packet assembly, the pose-only path for an entity not flowing audio,
// and the base-profile owner-scope controls. Mirrors the TypeScript
// EntityPublisher plus the bridge's pose-only ticker.
//
// Rules 2 and 3 (§5): an audio packet is built and handed to the send
// the moment its bytes exist, on the caller's thread; the only timed
// send is the pose-only packet of a silent entity, throttled to the
// bridge's 33 ms and sent on change. The send itself is async on
// Apple's API, so one ordered task per publisher drains a stream; it
// never holds a packet back.
//
// 2026-11-03.

import Foundation
import os

#if canImport(Network)

@available(iOS 26.0, macOS 26.0, *)
public final class EntityPublisher: @unchecked Sendable {
    public let id: String
    /// The alias the server's subscription to this source carries.
    public let trackAlias: UInt64
    public static let poseOnlyIntervalMS = 33.0
    /// After this long without audio the pose-only path takes over.
    static let audioQuietMS = 100.0

    private struct Guarded: @unchecked Sendable {
        var sequencer: UplinkSequencer
        var pose: Pose = .home
        var poseDirty = false
        var lastAudioNS: Int64 = 0
        var lastPoseOnlyNS: Int64 = 0
        var poseTask: Task<Void, Never>?
        var sent: UInt64 = 0
        var sendErrors: UInt64 = 0
        var closed = false
    }
    private let g: OSAllocatedUnfairLock<Guarded>
    private let session: MoQSession
    private let writer: any StateWriter
    private let controls: EntityControls
    private let sender: Task<Void, Never>
    private let outgoing: AsyncStream<[UInt8]>.Continuation

    init(id: String, trackAlias: UInt64, declaredRedundancy: Int, session: MoQSession, writer: any StateWriter) throws {
        self.id = id
        self.trackAlias = trackAlias
        self.session = session
        self.writer = writer
        controls = try EntityControls(writer, entityId: id)
        g = OSAllocatedUnfairLock(initialState: Guarded(sequencer: UplinkSequencer(declared: declaredRedundancy)))
        let (stream, cont) = AsyncStream<[UInt8]>.makeStream(bufferingPolicy: .unbounded)
        outgoing = cont
        let gg = g
        sender = Task.detached(priority: .userInitiated) {
            for await dg in stream {
                do {
                    try await session.sendDatagram(dg)
                    gg.withLock { $0.sent += 1 }
                } catch {
                    gg.withLock { $0.sendErrors += 1 }
                }
            }
        }
    }

    deinit { close() }

    func close() {
        let t: Task<Void, Never>? = g.withLock { s in
            guard !s.closed else { return nil }
            s.closed = true
            return s.poseTask
        }
        t?.cancel()
        outgoing.finish()
        sender.cancel()
    }

    // MARK: Publishing

    /// The declared offset, the ceiling.
    public var redundancy: Int { g.withLock { $0.sequencer.declared } }
    public func setRedundancy(_ offset: Int) { g.withLock { $0.sequencer.setRedundancy(offset) } }
    public var sent: UInt64 { g.withLock { $0.sent } }
    public var sendErrors: UInt64 { g.withLock { $0.sendErrors } }

    /// One encoded audio frame, sent now with the freshest pose. The
    /// pump's path: called on the sender thread, never waits.
    public func publishAudio(_ audio: [UInt8]) {
        let bytes: [UInt8] = g.withLock { s in
            s.lastAudioNS = Self.nowNS()
            s.poseDirty = false
            let st = s.sequencer.next(audio: audio, pose: s.pose)
            return Self.frame(alias: trackAlias, st)
        }
        outgoing.yield(bytes)
    }

    /// A caller-built packet, sequenced and sent now. Its pose, if any,
    /// also becomes the freshest pose.
    public func publish(_ packet: MonoObjectPacket) throws {
        try packet.validate()
        let bytes: [UInt8] = g.withLock { s in
            if let p = packet.pose { s.pose = p; s.poseDirty = false }
            if packet.audio != nil { s.lastAudioNS = Self.nowNS() }
            let st = s.sequencer.next(audio: packet.audio, pose: packet.pose ?? s.pose)
            return Self.frame(alias: trackAlias, st)
        }
        outgoing.yield(bytes)
    }

    /// The freshest pose. Wait-free for the caller; an entity flowing
    /// audio stamps it into its next packet, a silent one sends a
    /// pose-only packet at most every 33 ms.
    public func setPose(_ pose: Pose) {
        let schedule: Bool = g.withLock { s in
            guard !s.closed else { return false }
            s.pose = pose
            s.poseDirty = true
            let quiet = Self.nowNS() - s.lastAudioNS > Int64(Self.audioQuietMS * 1e6)
            return quiet && s.poseTask == nil
        }
        if schedule { schedulePoseOnly() }
    }

    public var pose: Pose { g.withLock { $0.pose } }

    private func schedulePoseOnly() {
        let task = Task.detached(priority: .userInitiated) { [self] in
            let wait: Int64 = g.withLock { s in
                let due = s.lastPoseOnlyNS + Int64(Self.poseOnlyIntervalMS * 1e6)
                return max(0, due - Self.nowNS())
            }
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait)) }
            let bytes: [UInt8]? = g.withLock { s in
                s.poseTask = nil
                guard !s.closed, s.poseDirty else { return nil }
                let quiet = Self.nowNS() - s.lastAudioNS > Int64(Self.audioQuietMS * 1e6)
                guard quiet else { return nil }   // audio took over; the pose rides its packets
                s.poseDirty = false
                s.lastPoseOnlyNS = Self.nowNS()
                let st = s.sequencer.next(audio: nil, pose: s.pose)
                return Self.frame(alias: trackAlias, st)
            }
            if let b = bytes { outgoing.yield(b) }
        }
        g.withLock { $0.poseTask = task }
    }

    /// The MoQ datagram around a sequenced packet: seq as the group id,
    /// object 0.
    private static func frame(alias: UInt64, _ st: UplinkSequencer.Stamped) -> [UInt8] {
        var out = [UInt8]()
        st.bytes.withUnsafeBytes {
            MoQ.encodeObjectDatagram(into: &out, trackAlias: alias, groupID: st.seq, objectID: 0, priority: 0, payload: $0)
        }
        return out
    }

    @inline(__always) private static func nowNS() -> Int64 {
        var ts = timespec(); clock_gettime(CLOCK_MONOTONIC, &ts)
        return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
    }

    // MARK: Base-profile owner scope (lasa-base-profile.md §5, §6)

    public func mute(_ other: String) async throws { try await controls.mute(other) }
    public func unmute(_ other: String) async throws { try await controls.unmute(other) }
    public func solo(_ other: String) async throws { try await controls.solo(other) }
    public func unsolo(_ other: String) async throws { try await controls.unsolo(other) }
    public func setAttr(_ path: String, _ value: BaseValue) async throws { try await controls.setAttr(path, value) }
    public func clearAttr(_ path: String) async throws { try await controls.clearAttr(path) }
    public func setAttrs(_ attrs: [String: BaseValue]) async throws { try await controls.setAttrs(attrs) }
}
#endif
