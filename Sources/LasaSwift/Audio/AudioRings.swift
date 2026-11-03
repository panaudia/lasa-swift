// The audio session for T5 and S4 (plan §3.2, §5.7): AVAudioEngine with
// an AVAudioSourceNode draining the playback ring and an AVAudioSinkNode
// filling the capture ring. The render blocks call two C functions and
// nothing else. They never touch Go, Swift concurrency, locks, or
// allocation.
//
// Untested scaffold, 2026-09-04. Compiles on iOS only.

#if os(iOS)
import AVFoundation
import CRings

/// The speaker's view of a jitter buffer: one non-blocking read per render
/// call, and the fill for the live line.
public protocol PlaybackReader: AnyObject {
    func readPlayback(into dst: UnsafeMutablePointer<Float>, frames: Int) -> Bool
    var playbackFillFrames: Int64 { get }
}

public final class AudioRings {
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
    }

    /// What the speaker's render block drains: T5's fixed-fill ring, or
    /// S4's jitter buffer. Either way the block calls one function that
    /// never blocks, allocates or logs.
    public enum PlaybackSource {
        case ring(OpaquePointer)             // ring_t*, stereo interleaved
        case jitter(any PlaybackReader)      // the v4 buffer
    }

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var sinkNode: AVAudioSinkNode?
    private let source: PlaybackSource
    private let capture: OpaquePointer    // ring_t*, mono

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

    /// The rings come from the Go archive (probe5_playback_ring /
    /// probe5_capture_ring) for T5, or from Swift for S4.
    public convenience init(playbackRing: OpaquePointer, captureRing: OpaquePointer) {
        self.init(playback: .ring(playbackRing), captureRing: captureRing)
    }

    public init(playback: PlaybackSource, captureRing: OpaquePointer) {
        source = playback
        capture = captureRing
    }

    deinit { scratch.deallocate() }

    /// Configures the session (plan §3.4: .playAndRecord, .default mode,
    /// no voice processing) and starts the engine.
    /// speaker routes output to the built-in speaker; otherwise
    /// .playAndRecord defaults to the earpiece receiver on a phone.
    /// primeFrames gates playback: the source block outputs silence until
    /// the ring first holds this many frames, so the standing latency is
    /// the target and not the engine's start-up time. 0 disables the gate.
    public func start(preferredIODurationMS: Double, speaker: Bool = false, primeFrames: Int = 0) throws -> Stats {
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP]
        if speaker { options.insert(.defaultToSpeaker) }
        try session.setCategory(.playAndRecord, mode: .default, options: options)
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(preferredIODurationMS / 1000)
        try session.setActive(true)

        let stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let mono = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

        let prime = UInt32(clamping: primeFrames)
        let source = AVAudioSourceNode(format: stereo) { [unowned self] _, _, frameCount, audioBufferList -> OSStatus in
            let t0 = mach_absolute_time()
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            if case .jitter(let jb) = self.source {
                // S4: the jitter buffer owns startup, fill and splices.
                // One read per render call into the interleaved scratch,
                // then de-interleave; silence comes back as zeros.
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
                    // otherwise stand as latency for the whole run (the
                    // 2026-09-04 "320 ppm" that was really 200 ms of
                    // engine start-up). Discard the excess now.
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
            // Distance from an underrun, measured where it matters: the
            // fill as the render block finds it.
            let fillNow = ring_fill(playback)
            if fillNow < self.fillMinSinceArm { self.fillMinSinceArm = fillNow }
            // Non-interleaved float from AVAudioEngine; the ring is
            // interleaved stereo. Read into the preallocated scratch
            // and de-interleave.
            let n = min(Int(frameCount), Self.maxFrames)
            let scratch = self.scratch
            let got = Int(ring_read(playback, scratch, UInt32(n)))
            for ch in 0..<abl.count {
                let dst = abl[ch].mData!.assumingMemoryBound(to: Float.self)
                for i in 0..<n {
                    dst[i] = i < got ? scratch[i * 2 + ch] : 0
                }
            }
            self.note(t0: t0, frames: frameCount)
            return noErr
        }

        let capture = self.capture
        let sink = AVAudioSinkNode { _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
            guard let src = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            // Accumulate what arrived and wake the sender: the callback is
            // the uplink's only clock (decided 2026-09-04).
            _ = ring_write(capture, src, frameCount)
            ring_signal(capture)
            return noErr
        }

        engine.attach(source)
        engine.attach(sink)
        engine.connect(source, to: engine.mainMixerNode, format: stereo)
        // The input node dictates its own format; connecting with another
        // one throws. The sink block reads channel 0 only, so a stereo
        // input is fine, and a rate other than 48 kHz is reported in Stats
        // and treated as a finding (the pump assumes 48 kHz).
        let inFormat = engine.inputNode.outputFormat(forBus: 0)
        _ = mono
        engine.connect(engine.inputNode, to: sink, format: inFormat)
        sourceNode = source
        sinkNode = sink

        try engine.start()

        var s = Stats()
        s.grantedIODurationMS = session.ioBufferDuration * 1000
        s.sampleRate = inFormat.sampleRate
        return s
    }

    @inline(__always)
    private static func wallNS() -> Int64 {
        var ts = timespec(); clock_gettime(CLOCK_REALTIME, &ts)
        return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
    }

    @inline(__always)
    private func note(t0: UInt64, frames: UInt32) {
        // Audio clock against wall clock (2026-09-04): one clock_gettime
        // per render call, a few hundred ns, no allocation.
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
            // frames counted from the second call, so the span is between
            // the first call's time and the last call's time exactly.
            s.audioClockSeconds = secs
            s.audioClockPPM = (Double(framesRendered) / (secs * 48_000) - 1) * 1e6
        }
        for (frames, calls) in sizeHistogram.enumerated() where calls > 0 {
            s.framesPerCall[UInt32(frames)] = calls
        }
        return s
    }

    public func stop() {
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}
#endif
