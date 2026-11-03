// The audio engine (plan lasa-swift.md §2.5, §4): AVAudioEngine with an
// AVAudioSourceNode draining the playback source and an AVAudioSinkNode
// filling the capture ring. The render blocks call one function each
// and nothing else: never a lock, an allocation, a log, or Swift
// concurrency.
//
// The engine's life is the state machine of §4: it observes the
// AVAudioSession it was GIVEN (interruptions, route changes) and its own
// engine (configuration changes), restarts the engine where §4 says to,
// reports every transition on `events`, and stamps it into the
// diagnostics record through `marks` when a recorder is attached. It
// never fetches the shared session and never configures a session it
// was not asked to: `configure` is the one convenience, called by the
// app (rule 8; decision 2 of 2026-11-03).
//
// Hardened 2026-11-03 after two phone runs lost their audio I/O two
// minutes in with nothing in the record to say why (tests plan §7.13).
// Compiles on iOS only.

#if os(iOS)
import AVFoundation
import CRings
import os

/// The speaker's view of a jitter buffer: one non-blocking read per render
/// call, and the fill for the live line.
public protocol PlaybackReader: AnyObject {
    func readPlayback(into dst: UnsafeMutablePointer<Float>, frames: Int) -> Bool
    var playbackFillFrames: Int64 { get }
}

/// The three routes of ios-library.md §3, for `LasaAudio.configure`.
public enum AudioRoute: Sendable {
    /// A2DP stereo out, the phone's own microphone in, the built-in
    /// speaker rather than the receiver when nothing is plugged in.
    case device
    /// HFP: the headset's microphone, mono call-quality audio.
    case headset
    /// iOS 26's high-quality Bluetooth recording (H2 AirPods; not in the
    /// EU), with HFP as the fallback for other headsets.
    case headsetHighQuality
}

/// What the session actually granted, read whenever it may have changed.
public struct AudioRouteReport: Sendable, CustomStringConvertible {
    public var inputs: String = ""
    public var outputs: String = ""
    public var outputChannels: Int = 0
    public var sampleRate: Double = 0
    public var inputLatencyMS: Double = 0
    public var outputLatencyMS: Double = 0
    public var grantedIODurationMS: Double = 0
    public var highQualityRecordingSupported = false
    public var highQualityRecordingEnabled = false

    public static func read(_ s: AVAudioSession) -> AudioRouteReport {
        var r = AudioRouteReport()
        let route = s.currentRoute
        r.inputs = route.inputs.map { "\($0.portType.rawValue)(\($0.portName))" }.joined(separator: "+")
        r.outputs = route.outputs.map { "\($0.portType.rawValue)(\($0.portName))" }.joined(separator: "+")
        r.outputChannels = s.outputNumberOfChannels
        r.sampleRate = s.sampleRate
        r.inputLatencyMS = s.inputLatency * 1000
        r.outputLatencyMS = s.outputLatency * 1000
        r.grantedIODurationMS = s.ioBufferDuration * 1000
        if let cap = route.inputs.first?.bluetoothMicrophoneExtension?.highQualityRecording {
            r.highQualityRecordingSupported = cap.isSupported
            r.highQualityRecordingEnabled = cap.isEnabled
        }
        return r
    }

    public var description: String {
        String(format: "in %@ out %@ ch %d rate %.0f io %.2f ms lat in %.1f out %.1f ms hq %@/%@",
               inputs, outputs, outputChannels, sampleRate, grantedIODurationMS, inputLatencyMS, outputLatencyMS,
               highQualityRecordingSupported ? "supported" : "no", highQualityRecordingEnabled ? "on" : "off")
    }
}

public final class LasaAudio: @unchecked Sendable {
    public enum State: Sendable { case idle, running, interrupted, stopped }

    /// §4's transitions, in order, one consumer.
    public enum Event: Sendable {
        case interruptionBegan
        case interruptionEnded(shouldResume: Bool)
        case routeChanged(reason: UInt, report: AudioRouteReport)
        case configurationChanged
        case engineRestarted
        case engineStartFailed(String)
    }

    /// Record marks (RecordWriter event codes) for the transitions, in
    /// the T4 record's vocabulary beside 1 foreground, 2 background,
    /// 3 inactive, 9 stop, 20 to 23 the pump's stalls.
    public static let markInterruptionBegan: UInt32 = 30
    public static let markInterruptionEnded: UInt32 = 31   // arg 1 = should resume
    public static let markRouteChanged: UInt32 = 32        // arg = AVAudioSession.RouteChangeReason
    public static let markConfigurationChanged: UInt32 = 33
    public static let markEngineRestarted: UInt32 = 34
    public static let markEngineStartFailed: UInt32 = 35

    public struct Stats: Sendable {
        public var renderCalls: UInt64 = 0
        public var renderMaxNS: Int64 = 0
        public var renderOver1ms: UInt64 = 0
        public var framesPerCall: [UInt32: UInt64] = [:]   // granted size -> calls
        public var grantedIODurationMS: Double = 0
        public var sampleRate: Double = 0
        public var armed = false
        public var trimmedAtArmFrames: UInt32 = 0
        public var fillMinSinceArmFrames: UInt32 = 0
        /// The audio hardware's rate against the wall clock: frames the
        /// render block was asked for between its first and last call,
        /// over the wall time between them. Independent of the server.
        public var audioClockPPM: Double = 0
        public var audioClockSeconds: Double = 0
        public var state: State = .idle
        public var restarts: UInt64 = 0
    }

    /// What the speaker's render block drains: a fixed-fill ring (the Go
    /// probe's T5), or the v4 jitter buffer. Either way the block calls
    /// one function that never blocks, allocates or logs.
    public enum PlaybackSource {
        case ring(OpaquePointer)             // ring_t*, stereo interleaved
        case jitter(any PlaybackReader)      // the v4 buffer
    }

    public let session: AVAudioSession
    public let events: AsyncStream<Event>
    /// Set by whoever owns a diagnostics record (S4Session.attach): every
    /// transition is stamped with its mark code and argument.
    public var marks: (@Sendable (UInt32, UInt64) -> Void)? {
        get { guarded.withLock { $0.marks } }
        set { guarded.withLock { $0.marks = newValue } }
    }
    public var state: State { guarded.withLock { $0.state } }
    public var route: AudioRouteReport { guarded.withLock { $0.report } }

    private struct Guarded: @unchecked Sendable {
        var state: State = .idle
        var report = AudioRouteReport()
        var marks: (@Sendable (UInt32, UInt64) -> Void)?
        var restarts: UInt64 = 0
        var primeFrames: UInt32 = 0
    }
    private let guarded = OSAllocatedUnfairLock(initialState: Guarded())
    private let eventsCont: AsyncStream<Event>.Continuation
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var sinkNode: AVAudioSinkNode?
    private let source: PlaybackSource
    private let capture: OpaquePointer    // ring_t*, mono
    private var observers: [NSObjectProtocol] = []

    // Written by the render blocks with plain stores; read by the app once
    // a second. Torn reads are acceptable for a live line.
    private var armed = false      // playback gate, flipped once on the render thread
    private var trimmedAtArm: UInt32 = 0
    private var fillMinSinceArm: UInt32 = .max
    private var framesRendered: UInt64 = 0
    private var firstRenderWallNS: Int64 = 0
    private var lastRenderWallNS: Int64 = 0
    private var renderCalls: UInt64 = 0
    private var renderMaxNS: Int64 = 0
    private var renderOver1ms: UInt64 = 0
    // mach_absolute_time is not nanoseconds on Apple Silicon (timebase
    // 125/3), so convert, or the >1ms threshold below is really ~41ms.
    private static let tb: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t
    }()
    // Fixed-size, allocated once: the render block must not allocate.
    private static let maxFrames = 8192
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * 2)
    private var sizeHistogram = [UInt64](repeating: 0, count: maxFrames + 1)

    /// `session` is the app's: this object configures nothing on it (see
    /// `configure`) and only observes it.
    public init(session: AVAudioSession, playback: PlaybackSource, captureRing: OpaquePointer) {
        self.session = session
        source = playback
        capture = captureRing
        let (stream, cont) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        events = stream
        eventsCont = cont
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        scratch.deallocate()
    }

    // MARK: The one convenience

    /// Configures and activates a session the way the library expects
    /// (ios-library.md §3, §4): `.playAndRecord`, `.default` mode (no
    /// voice processing), the route's options, 48 kHz, the preferred I/O
    /// duration. The app calls it, or does the same itself. Returns what
    /// was granted.
    @discardableResult
    public static func configure(_ session: AVAudioSession, route: AudioRoute,
                                 preferredIODurationMS: Double = 10) throws -> AudioRouteReport {
        let options: AVAudioSession.CategoryOptions
        switch route {
        case .device: options = [.allowBluetoothA2DP, .defaultToSpeaker]
        case .headset: options = [.allowBluetoothHFP]
        case .headsetHighQuality: options = [.allowBluetoothHFP, .bluetoothHighQualityRecording]
        }
        try session.setCategory(.playAndRecord, mode: .default, options: options)
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(preferredIODurationMS / 1000)
        try session.setActive(true)
        return AudioRouteReport.read(session)
    }

    // MARK: Start, stop, restart

    /// Builds the graph on the session as it is and starts the engine.
    /// primeFrames gates the ring source: silence until the ring first
    /// holds this many frames (T5's fixed fill). 0 disables the gate; the
    /// jitter buffer owns its own startup.
    public func start(primeFrames: Int = 0) throws -> Stats {
        guarded.withLock { $0.primeFrames = UInt32(clamping: primeFrames) }
        try buildGraph()
        let report = AudioRouteReport.read(session)
        guarded.withLock { $0.state = .running; $0.report = report }
        observe()
        return stats()
    }

    /// Stops the engine and stops observing. The session is left as it
    /// is: deactivating it is the app's, as activating it was.
    public func stop() {
        engine.stop()
        detachNodes()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        guarded.withLock { $0.state = .stopped }
        eventsCont.finish()
    }

    /// Rebuilds the graph on the session's current formats and starts the
    /// engine again. Called by the §4 transitions, and by the app after
    /// an interruption that ended without `shouldResume`.
    public func restart() {
        do {
            try buildGraph()
            let report = AudioRouteReport.read(session)
            guarded.withLock { $0.state = .running; $0.report = report; $0.restarts += 1 }
            mark(Self.markEngineRestarted)
            eventsCont.yield(.engineRestarted)
        } catch {
            guarded.withLock { $0.state = .stopped }
            mark(Self.markEngineStartFailed)
            eventsCont.yield(.engineStartFailed("\(error)"))
        }
    }

    private func detachNodes() {
        if let s = sourceNode { engine.detach(s); sourceNode = nil }
        if let k = sinkNode { engine.detach(k); sinkNode = nil }
    }

    private func buildGraph() throws {
        if engine.isRunning { engine.stop() }
        detachNodes()
        let stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let prime = guarded.withLock { $0.primeFrames }

        let source = AVAudioSourceNode(format: stereo) { [unowned self] _, _, frameCount, audioBufferList -> OSStatus in
            let t0 = mach_absolute_time()
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            if case .jitter(let jb) = self.source {
                // The jitter buffer owns startup, fill and splices. One
                // read per render call into the interleaved scratch, then
                // de-interleave; silence comes back as zeros.
                let n = min(Int(frameCount), Self.maxFrames)
                let scratch = self.scratch
                let produced = jb.readPlayback(into: scratch, frames: n)
                if produced && !self.armed { self.armed = true }
                let fillNow = UInt32(clamping: jb.playbackFillFrames)
                if self.armed && fillNow < self.fillMinSinceArm { self.fillMinSinceArm = fillNow }
                for ch in 0..<abl.count {
                    let dst = abl[ch].mData!.assumingMemoryBound(to: Float.self)
                    for i in 0..<n { dst[i] = scratch[i * 2 + ch] }
                }
                self.note(t0: t0, frames: frameCount)
                return noErr
            }
            guard case .ring(let playback) = self.source else { return noErr }
            if !self.armed {
                let fill = ring_fill(playback)
                if fill >= prime {
                    // Arm, and TRIM to the target: packets that arrived
                    // between subscribe and the engine's first call would
                    // otherwise stand as latency for the whole run.
                    var excess = fill - prime
                    while excess > 0 {
                        let n = min(excess, UInt32(Self.maxFrames))
                        _ = ring_read(playback, self.scratch, n)
                        excess -= n
                    }
                    self.trimmedAtArm = fill - prime
                    self.armed = true
                } else {
                    for ch in 0..<abl.count { memset(abl[ch].mData, 0, Int(abl[ch].mDataByteSize)) }
                    self.note(t0: t0, frames: frameCount)
                    return noErr
                }
            }
            let fillNow = ring_fill(playback)
            if fillNow < self.fillMinSinceArm { self.fillMinSinceArm = fillNow }
            let n = min(Int(frameCount), Self.maxFrames)
            let scratch = self.scratch
            let got = Int(ring_read(playback, scratch, UInt32(n)))
            for ch in 0..<abl.count {
                let dst = abl[ch].mData!.assumingMemoryBound(to: Float.self)
                for i in 0..<n { dst[i] = i < got ? scratch[i * 2 + ch] : 0 }
            }
            self.note(t0: t0, frames: frameCount)
            return noErr
        }

        let capture = self.capture
        let sink = AVAudioSinkNode { _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
            guard let src = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            // Accumulate what arrived and wake the sender: the callback is
            // the uplink's only clock (rule 3).
            _ = ring_write(capture, src, frameCount)
            ring_signal(capture)
            return noErr
        }

        engine.attach(source)
        engine.attach(sink)
        engine.connect(source, to: engine.mainMixerNode, format: stereo)
        // The input node dictates its own format; connecting with another
        // one throws. The sink block reads channel 0 only, so a stereo
        // input is fine, and a rate other than 48 kHz is reported and
        // treated as a finding (the pump assumes 48 kHz).
        let inFormat = engine.inputNode.outputFormat(forBus: 0)
        engine.connect(engine.inputNode, to: sink, format: inFormat)
        sourceNode = source
        sinkNode = sink
        try engine.start()
    }

    // MARK: §4's transitions

    private func observe() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] n in
            guard let self else { return }
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = (n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
            self.interruption(type, options)
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { [weak self] n in
            guard let self else { return }
            let reason = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            self.routeChange(reason)
        })
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.configurationChange()
        })
    }

    private func interruption(_ type: AVAudioSession.InterruptionType?, _ options: AVAudioSession.InterruptionOptions?) {
        switch type {
        case .began:
            guarded.withLock { $0.state = .interrupted }
            mark(Self.markInterruptionBegan)
            eventsCont.yield(.interruptionBegan)
        case .ended:
            let resume = options?.contains(.shouldResume) ?? false
            mark(Self.markInterruptionEnded, arg: resume ? 1 : 0)
            eventsCont.yield(.interruptionEnded(shouldResume: resume))
            if resume { restart() }
        default:
            break
        }
    }

    private func routeChange(_ reason: UInt) {
        let report = AudioRouteReport.read(session)
        let running = guarded.withLock { g -> Bool in g.report = report; return g.state == .running }
        mark(Self.markRouteChanged, arg: UInt64(reason))
        eventsCont.yield(.routeChanged(reason: reason, report: report))
        if running && !engine.isRunning { restart() }
    }

    private func configurationChange() {
        mark(Self.markConfigurationChanged)
        eventsCont.yield(.configurationChanged)
        if guarded.withLock({ $0.state == .running }) { restart() }
    }

    private func mark(_ code: UInt32, arg: UInt64 = 0) {
        guarded.withLock { $0.marks }?(code, arg)
    }

    // MARK: Counters

    @inline(__always)
    private static func wallNS() -> Int64 {
        var ts = timespec(); clock_gettime(CLOCK_REALTIME, &ts)
        return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
    }

    @inline(__always)
    private func note(t0: UInt64, frames: UInt32) {
        let w = Self.wallNS()
        if firstRenderWallNS == 0 { firstRenderWallNS = w } else { framesRendered &+= UInt64(frames) }
        lastRenderWallNS = w
        let raw = mach_absolute_time() &- t0
        let dt = Int64(raw &* UInt64(Self.tb.numer) / UInt64(Self.tb.denom)) // ns
        renderCalls &+= 1
        if dt > renderMaxNS { renderMaxNS = dt }
        if dt > 1_000_000 { renderOver1ms &+= 1 }
        sizeHistogram[min(Int(frames), Self.maxFrames)] &+= 1
    }

    public func stats() -> Stats {
        var s = Stats()
        s.renderCalls = renderCalls
        s.renderMaxNS = renderMaxNS
        s.renderOver1ms = renderOver1ms
        s.armed = armed
        s.trimmedAtArmFrames = trimmedAtArm
        s.fillMinSinceArmFrames = fillMinSinceArm == .max ? 0 : fillMinSinceArm
        let secs = Double(lastRenderWallNS - firstRenderWallNS) / 1e9
        if secs > 1 {
            s.audioClockSeconds = secs
            s.audioClockPPM = (Double(framesRendered) / (secs * 48_000) - 1) * 1e6
        }
        for (frames, calls) in sizeHistogram.enumerated() where calls > 0 {
            s.framesPerCall[UInt32(frames)] = calls
        }
        let (state, report, restarts) = guarded.withLock { ($0.state, $0.report, $0.restarts) }
        s.state = state
        s.restarts = restarts
        s.grantedIODurationMS = report.grantedIODurationMS
        s.sampleRate = report.sampleRate
        return s
    }
}
#endif
