// The audio surface (plan lasa-swift.md §2.5): startCapture runs a
// CapturePump feeding an EntityPublisher; playSink subscribes a sink
// into a SinkPipeline whose jitter buffer the engine's render block
// reads. The app owns the AVAudioSession and hands a LasaAudio in;
// the client attaches its pipelines to it and starts the engine when
// the first one is attached. One LasaAudio, one engine. 2026-11-03.

import Foundation
import os

#if os(iOS)
import AVFoundation
import CRings

public struct CaptureOptions: Sendable {
    public var bitrate: Int32 = 64_000       // the bridge's default
    public var complexity: Int32 = 5
    public var pose: Pose = .home
    /// nil = the entity's declaration.
    public var redundancy: Int? = nil
    public init() {}
}

public struct SinkPlayerOptions: Sendable {
    /// LASA quality level 0 to 2 -> floor, robustness, capacity.
    public var quality = 0
    /// Writes the arrival record (the T4 format) for the analysis script.
    public var recordMaxRecords = 0
    public init() {}
}

@available(iOS 26.0, *)
public final class CaptureHandle: @unchecked Sendable {
    public let entity: String
    let pump: CapturePump
    let publisher: EntityPublisher
    private let onStop: @Sendable () -> Void
    init(entity: String, pump: CapturePump, publisher: EntityPublisher, onStop: @escaping @Sendable () -> Void) {
        self.entity = entity; self.pump = pump; self.publisher = publisher; self.onStop = onStop
    }
    /// The entity's freshest pose; wait-free, call at any rate.
    public func setPose(_ pose: Pose) { publisher.setPose(pose) }
    public var stats: CapturePump.Stats { pump.stats() }
    public func stop() { onStop() }
}

@available(iOS 26.0, *)
public final class SinkPlayer: @unchecked Sendable {
    public let entity: String
    public let format: SinkFormat
    let pipeline: SinkPipeline
    let record: RecordWriter?
    private let onStop: @Sendable () -> Void
    init(entity: String, format: SinkFormat, pipeline: SinkPipeline, record: RecordWriter?, onStop: @escaping @Sendable () -> Void) {
        self.entity = entity; self.format = format; self.pipeline = pipeline; self.record = record; self.onStop = onStop
    }
    public var ingress: SinkPipeline.Ingress { pipeline.ingress() }
    public var jitter: JitterBuffer.Snapshot { pipeline.jitter.snapshot() }
    /// Writes the arrival record, with a stop mark, when recording was on.
    public func flushRecord(to url: URL) throws {
        guard let r = record else { return }
        r.appendEvent(nowNS: ArrivalClock.nowNS(), code: SwiftPump.eventStop)
        try r.flush(to: url)
    }
    public func stop() { onStop() }
}

public struct AudioStats: Sendable {
    public var engine = LasaAudio.Stats()
    public var capture: CapturePump.Stats?
    public var sink: SinkPipeline.Ingress?
}

@available(iOS 26.0, *)
extension LasaClient {
    private final class AudioState: @unchecked Sendable {
        var audio: LasaAudio?
        var capture: CaptureHandle?
        var sink: SinkPlayer?
        var sinkAlias: UInt64?
    }
    private static let audioStates = OSAllocatedUnfairLock<[ObjectIdentifier: AudioState]>(initialState: [:])
    private var audioState: AudioState {
        Self.audioStates.withLock { m in
            if let s = m[ObjectIdentifier(self)] { return s }
            let s = AudioState(); m[ObjectIdentifier(self)] = s; return s
        }
    }

    /// Starts the engine when its first pipeline is attached, on the
    /// session as the app configured it.
    private func ensureRunning(_ audio: LasaAudio) throws {
        let st = audioState
        if st.audio == nil { st.audio = audio }
        if audio.state == .idle || audio.state == .stopped { _ = try audio.start() }
    }

    /// Captures the microphone into `entity`'s source track: the capture
    /// callback fills a ring, a dedicated thread encodes and the entity's
    /// publisher sends, each frame the moment it exists (rules 2, 3).
    public func startCapture(entity id: String, audio: LasaAudio, options: CaptureOptions = CaptureOptions()) async throws -> CaptureHandle {
        let st = audioState
        if let existing = st.capture { if existing.entity == id { return existing }; existing.stop() }
        let publisher = try await self.entity(id)
        if let r = options.redundancy { publisher.setRedundancy(r) }
        publisher.setPose(options.pose)
        var pc = CapturePump.Config()
        pc.bitrate = options.bitrate
        pc.complexity = options.complexity
        let pump = try CapturePump(pc, record: st.sink?.record)
        pump.run { [publisher] bytes in publisher.publishAudio(Array(bytes)) }
        audio.attach(captureRing: pump.capture)
        try ensureRunning(audio)
        let handle = CaptureHandle(entity: id, pump: pump, publisher: publisher) { [weak self, weak audio] in
            guard let self else { return }
            let st = self.audioState
            guard let h = st.capture, h.entity == id else { return }
            st.capture = nil
            h.pump.stop()
            audio?.attach(captureRing: nil)
            self.stopEngineIfIdle()
        }
        st.capture = handle
        return handle
    }

    public func stopCapture(entity id: String) {
        guard let h = audioState.capture, h.entity == id else { return }
        h.stop()
    }

    /// Plays `entity`'s sink through the engine: subscribe, reassemble
    /// when the entity declared redundancy, decode, the v4 buffer, the
    /// render block. Binaural renders; ambi2 and ambi3 have no local
    /// renderer in v1 and are refused here (subscribeSink still works).
    public func playSink(entity id: String, format: SinkFormat = .binaural, audio: LasaAudio, options: SinkPlayerOptions = SinkPlayerOptions()) async throws -> SinkPlayer {
        guard format == .binaural else { throw MalformedError("\(format.rawValue) has no local renderer in v1") }
        let st = audioState
        if let existing = st.sink { if existing.entity == id { return existing }; existing.stop() }
        var sc = SinkPipeline.Config()
        sc.readerFrames = Int64((audio.preferredIODurationMS * 48).rounded())
        sc.quality = options.quality
        sc.redundancy = config.entities.first(where: { $0.id == id })?.redundancy ?? 0
        let record = options.recordMaxRecords > 0 ? RecordWriter(maxRecords: options.recordMaxRecords) : nil
        let pipeline = try SinkPipeline(sc, record: record)
        let sub = try await subscribeSink(entity: id, format: format.rawValue) { [pipeline] a, seq, p in
            pipeline.onSink(arrivalNS: a, seq: seq, payload: p)
        }
        audio.attach(playback: .jitter(pipeline.jitter))
        try ensureRunning(audio)
        let player = SinkPlayer(entity: id, format: format, pipeline: pipeline, record: record) { [weak self, weak audio] in
            guard let self else { return }
            let st = self.audioState
            guard let s = st.sink, s.entity == id else { return }
            st.sink = nil
            if let alias = st.sinkAlias { self.session.unregisterDatagramHandler(alias: alias) }
            st.sinkAlias = nil
            audio?.attach(playback: nil)
            self.stopEngineIfIdle()
        }
        st.sink = player
        st.sinkAlias = sub.trackAlias
        return player
    }

    public func stopSink(entity id: String) {
        guard let s = audioState.sink, s.entity == id else { return }
        s.stop()
    }

    public func sinkIngress(entity id: String) -> SinkPipeline.Ingress? {
        guard let s = audioState.sink, s.entity == id else { return nil }
        return s.ingress
    }

    private func stopEngineIfIdle() {
        let st = audioState
        guard st.capture == nil, st.sink == nil, let a = st.audio else { return }
        a.stop()
        st.audio = nil
    }

    /// The meters: what went up and what came down in the last window.
    public var levels: Levels {
        let st = audioState
        var l = Levels()
        if let c = st.capture { l.input = c.pump.meter.snapshotAndReset().rmsL }
        if let s = st.sink { let r = s.pipeline.meter.snapshotAndReset(); l.output = r.midRms; l.outputStereo = r }
        return l
    }

    public var audioStats: AudioStats {
        let st = audioState
        var a = AudioStats()
        if let e = st.audio { a.engine = e.stats() }
        a.capture = st.capture?.stats
        a.sink = st.sink?.ingress
        return a
    }
}
#endif
