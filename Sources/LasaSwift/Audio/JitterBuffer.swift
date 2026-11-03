// The v4 jitter buffer, a port of the Go reference
// panaudia-lasa/engine/buffers/jitter_buffer.go (design:
// panaudia-engine/plan/jitter-v4-design.md), the same core the
// TypeScript client carries. Envelope sensing plus a placement servo: a
// sensing window feeds two fill views, the virtual signal (wp − R·tick,
// the input process as it would look without actuation) measured for
// per-side widths and the feed-forward drift slope, and the raw fill
// (wp − rp) measured for the displacement error and the macro-trim
// trigger. A slow drop-only P anchor plus a soft-clamped feed-forward
// term holds the raw-fill window median at a derived setpoint by
// trickling rate-limited ±1-frame splices through a debt bucket; a
// confirmed whole-window displacement goes in one macro-trim. The only
// discrete events are the two physical valves (underrun, capacity) and
// the bounded trim.
//
// Concurrency contract, unchanged from Go: one producer calls write
// (touches only writePos and the ring, release-store after data), one
// consumer calls read (owns everything else). read is the render
// block's path: it never allocates or locks. Observers read
// reader-written atomics through snapshot().
//
// Ported to the letter so that the Go jitterlab's exported traces replay
// to ledger equality (JitterBufferReplayTests): integer positions are
// Int64, the controller is Double with no transcendentals, and the
// splice placement compares Float like Go's float32. Every Go name is
// kept where Swift allows, and the comments that explain a decision
// are carried over in brief; the Go file has the full ones.

import Foundation
import Synchronization

@available(iOS 18.0, macOS 15.0, *)
public final class JitterBuffer: @unchecked Sendable {
    // v4 tuning (Go: the v4 constant block). Windows are read counts,
    // rates are per second of read time.
    static let v4WindowSec = 2.0
    static let v4WidthHistory = 10
    static let v4WidthRank = 3
    static let v4FreezeMs = 40.0
    static let v4NarrowStepMs = 0.5
    static let v4KLow = 1.2
    static let v4KHigh = 1.5
    static let v4WidthLowMax = 30.0
    static let v4WidthHighMax = 60.0
    static let v4DeadbandMs = 0.25
    static let v4GainPerSec = 0.01
    static let v4RateCapPerSec = 20.0
    static let v4FFClampPerSec = 22.0
    static let v4MaxDebt = 1.5

    public struct Config {
        public var sampleRate = 48_000
        public var numChannels = 1
        /// W and R in frames: the caller declares its wire framing and
        /// its callback size (Go: WriterFrames / ReaderFrames).
        public var writerFrames: Int64 = 0
        public var readerFrames: Int64 = 0
        /// S, frames; 0 = 1 ms.
        public var safetyFrames: Int64 = 0
        /// The declared minimum operating latency, frames (quality
        /// level floor, FEC floor), composed with the width-derived
        /// setpoint by max. 0 = none.
        public var floorFrames: Int64 = 0
        /// κ ≥ 1; under 1 clamps to 1.
        public var robustness = 0.0
        /// Ring and latency budget, frames; 0 derives the worst case.
        public var capacityFrames: Int64 = 0
        public init() {}
    }

    public struct Snapshot: Sendable {
        public var fillFrames = 0
        public var setpointFrames = 0
        public var widthLowFrames = 0
        public var widthHighFrames = 0
        public var ratePerSec = 0.0
        public var frozen = false
        public var started = false
        public var underruns: Int64 = 0
        public var laps: Int64 = 0
        public var overruns: Int64 = 0
        public var trims: Int64 = 0
        public var samplesDropped: Int64 = 0
        public var samplesInserted: Int64 = 0
    }

    // Immutable geometry (frames).
    public let capacity: Int64
    let w: Int64, r: Int64, s: Int64
    public let nc: Int
    let sr: Int

    // Immutable derived tuning.
    let windowReads: Int64
    let freezeReads: Int64
    let narrowStep: Double
    let spBase: Int64
    let flDecl: Int64
    let kLow: Double, kHigh: Double
    let wlCap: Int64
    let deadband: Int64
    let gain: Double
    let rateCap: Double
    let ffClamp: Double
    let ffDeadZone: Int64
    let theta: Int64
    let spMax: Int64

    // SPSC heads, atomic, cumulative. Ring index = (pos % capacity) * nc.
    private let writePos = Atomic<Int64>(0)
    private let readPos = Atomic<Int64>(0)
    private let data: UnsafeMutableBufferPointer<Float>

    // Reader-owned sensing and controller state.
    private var started = false
    private var tick: Int64 = 0
    private var lastWp: Int64 = 0
    private var gapRun: Int64 = 0
    private var frozen = false

    // The current window, preallocated to windowReads.
    private var rawBuf: [Int64]
    private var virtBuf: [Int64]
    private var sortBuf: [Int64]
    private var winCount = 0

    private var wlHist: [Int64]
    private var whHist: [Int64]
    private var histLen = 0
    private var histPos = 0

    private var ffTicks: [Int64] = []
    private var ffVals: [Int64] = []

    private var wl = 0.0, wh = 0.0
    private var rate = 0.0
    private var debt = 0.0
    private var pendingTrim: Int64 = 0

    // Reader-written atomics for observers.
    private let setpoint = Atomic<Int64>(0)
    private let curWL = Atomic<Int64>(0)
    private let curWH = Atomic<Int64>(0)
    private let curRate = Atomic<UInt64>(0)
    private let curFrozen = Atomic<Bool>(false)
    private let statsUnderruns = Atomic<Int64>(0)
    private let statsLaps = Atomic<Int64>(0)
    private let statsOverruns = Atomic<Int64>(0)
    private let statsTrims = Atomic<Int64>(0)
    private let statsDropped = Atomic<Int64>(0)
    private let statsInserted = Atomic<Int64>(0)

    static func msToFrames(_ sr: Int, _ ms: Double) -> Int64 {
        Int64(ms * Double(sr) / 1000.0)
    }

    public init(_ cfg: Config) {
        let sr = cfg.sampleRate == 0 ? 48_000 : cfg.sampleRate
        let nc = cfg.numChannels == 0 ? 1 : cfg.numChannels
        let w = cfg.writerFrames, r = cfg.readerFrames
        precondition(w > 0 && r > 0, "JitterBuffer: writer and reader frame sizes must be > 0")
        var s = cfg.safetyFrames
        if s == 0 { s = Self.msToFrames(sr, 1) }
        var kappa = cfg.robustness
        if kappa < 1 { kappa = 1 }

        // The setpoint base includes one whole writer frame of headroom
        // above the read quantum (the W = R fill lattice); the declared
        // floor composes by max, not addition.
        let deadband = Self.msToFrames(sr, Self.v4DeadbandMs)
        let spBase = max(r + s, r + w)
        let flDecl = cfg.floorFrames
        let kLow = Self.v4KLow * kappa
        let kHigh = Self.v4KHigh * kappa
        let wlCap = Int64(Double(Self.msToFrames(sr, Self.v4WidthLowMax)) * kappa)
        let whCap = Int64(Double(Self.msToFrames(sr, Self.v4WidthHighMax)) * kappa)
        var spMax = max(spBase + Int64(kLow * Double(wlCap)), flDecl)
        // FF dead zone in the geometry's median quantum: gcd(W, R) / 2.
        var ffDeadZone = Self.gcd(w, r) / 2
        if ffDeadZone < 1 { ffDeadZone = 1 }
        // Θ is κ-invariant.
        let theta = w + Int64(Self.v4RateCapPerSec * Self.v4WindowSec)
        var capacity = cfg.capacityFrames
        if capacity == 0 {
            capacity = 2 * (spMax + Int64(kHigh * Double(whCap))) + 2 * max(w, r)
        }
        let reserve = 4 * max(w, r)
        if spMax > capacity - reserve {
            spMax = max(spBase, capacity - reserve)
        }

        self.capacity = capacity
        self.w = w; self.r = r; self.s = s
        self.nc = nc
        self.sr = sr
        windowReads = Int64(Self.v4WindowSec * Double(sr) / Double(r))
        freezeReads = max(8, Self.msToFrames(sr, Self.v4FreezeMs) / r)
        narrowStep = Double(Self.msToFrames(sr, Self.v4NarrowStepMs)) / kappa
        self.spBase = spBase
        self.flDecl = flDecl
        self.kLow = kLow; self.kHigh = kHigh
        self.wlCap = wlCap
        self.deadband = deadband
        gain = Self.v4GainPerSec
        rateCap = Self.v4RateCapPerSec
        ffClamp = Self.v4FFClampPerSec
        self.ffDeadZone = ffDeadZone
        self.theta = theta
        self.spMax = spMax
        data = UnsafeMutableBufferPointer<Float>.allocate(capacity: Int(capacity) * nc)
        data.initialize(repeating: 0)
        wlHist = [Int64](repeating: 0, count: Self.v4WidthHistory)
        whHist = [Int64](repeating: 0, count: Self.v4WidthHistory)
        rawBuf = []; rawBuf.reserveCapacity(Int(windowReads))
        virtBuf = []; virtBuf.reserveCapacity(Int(windowReads))
        sortBuf = []; sortBuf.reserveCapacity(Int(windowReads))
        ffTicks.reserveCapacity(Self.v4WidthHistory + 1)
        ffVals.reserveCapacity(Self.v4WidthHistory + 1)
        setpoint.store(min(max(spBase, flDecl), spMax), ordering: .relaxed) // warm start
    }

    deinit { data.deallocate() }

    // MARK: Producer

    /// Copies `src` (interleaved, `nc` samples per frame) into the ring.
    /// Never blocks; writes larger than the capacity keep the most
    /// recent frames. A writer that laps a stalled reader overwrites
    /// unread slots (the accepted lap race, recovered by the lap valve):
    /// wp's truthfulness is load-bearing for the sensing.
    public func write(_ src: UnsafeBufferPointer<Float>) {
        var nFrames = Int64(src.count) / Int64(nc)
        if nFrames == 0 { return }
        var base = src.baseAddress!
        if nFrames > capacity {
            let skip = nFrames - capacity
            base += Int(skip) * nc
            nFrames = capacity
        }
        let wp = writePos.load(ordering: .relaxed)
        writeToRing(base, wp, nFrames)
        writePos.store(wp + nFrames, ordering: .releasing)
    }

    public func write(_ src: [Float]) {
        src.withUnsafeBufferPointer { write($0) }
    }

    // MARK: Consumer

    /// Copies `nFrames` frames into `dst` (interleaved), returning true
    /// when audio was produced and false for silence (startup or
    /// underrun). Order per read: startup gate, pending macro-trim,
    /// capacity valves, sense, underrun valve, play with the debt-bucket
    /// splice.
    @discardableResult
    public func read(into dst: UnsafeMutablePointer<Float>, frames nFrames: Int64) -> Bool {
        if nFrames == 0 { return true }
        let wp = writePos.load(ordering: .acquiring)
        var rp = readPos.load(ordering: .relaxed)
        let sp = setpoint.load(ordering: .relaxed)
        let nSamples = Int(nFrames) * nc

        // 1. Startup: wait for a full operating point, then place at it.
        if rp == 0 {
            if wp < sp {
                dst.update(repeating: 0, count: nSamples)
                return false
            }
            rp = wp - sp
            readPos.store(rp, ordering: .relaxed)
            started = true
            lastWp = wp
        }

        // 2. Pending macro-trim: one discard, landing at the setpoint.
        if pendingTrim > 0 {
            let t = min(pendingTrim, wp - rp - sp)
            if t > 0 {
                rp += t
                readPos.store(rp, ordering: .relaxed)
                statsTrims.add(1, ordering: .relaxed)
            }
            pendingTrim = 0
            resetWindow()
        }

        var fill = wp - rp

        // 3. Capacity valves: lap, and the near-capacity guard.
        if fill >= capacity {
            rp = wp - sp
            readPos.store(rp, ordering: .relaxed)
            fill = sp
            statsLaps.add(1, ordering: .relaxed)
            resetWindow()
        } else if fill > capacity - (w + r) {
            rp = wp - sp
            readPos.store(rp, ordering: .relaxed)
            fill = sp
            statsOverruns.add(1, ordering: .relaxed)
            resetWindow()
        }

        // 4. Sense at read entry, before the buffer acts.
        sense(wp, fill)

        // 5. Underrun: silence, rp frozen.
        if fill < nFrames {
            dst.update(repeating: 0, count: nSamples)
            statsUnderruns.add(1, ordering: .relaxed)
            return false
        }

        // 6. Play, paying splice debt at most one per read.
        if !frozen {
            debt += rate * Double(r) / Double(sr)
            if debt > Self.v4MaxDebt { debt = Self.v4MaxDebt } else if debt < -Self.v4MaxDebt { debt = -Self.v4MaxDebt }
        }
        if debt >= 1 && fill >= nFrames + 1 {
            debt -= 1
            spliceDrop(dst, rp, nFrames)
            readPos.store(rp + nFrames + 1, ordering: .relaxed)
            statsDropped.add(1, ordering: .relaxed)
        } else if debt <= -1 && nFrames >= 2 {
            debt += 1
            spliceInsert(dst, rp, nFrames)
            readPos.store(rp + nFrames - 1, ordering: .relaxed)
            statsInserted.add(1, ordering: .relaxed)
        } else {
            readFromRing(dst, rp, nFrames)
            readPos.store(rp + nFrames, ordering: .relaxed)
        }
        return true
    }

    @discardableResult
    public func read(into dst: inout [Float]) -> Bool {
        let n = Int64(dst.count) / Int64(nc)
        return dst.withUnsafeMutableBufferPointer { read(into: $0.baseAddress!, frames: n) }
    }

    // MARK: Sensing

    /// One pre-read observation into the window, with the freeze rule: a
    /// no-delivery run longer than freezeReads freezes sensing and the
    /// servo and rewinds the run's own dips out of the window.
    private func sense(_ wp: Int64, _ fill: Int64) {
        if !started { return }
        let tick = self.tick
        self.tick += 1

        let delta = wp - lastWp
        lastWp = wp
        if delta > 0 {
            if frozen {
                frozen = false
                curFrozen.store(false, ordering: .relaxed)
                resetWindow()
                ffTicks.removeAll(keepingCapacity: true)
                ffVals.removeAll(keepingCapacity: true)
            }
            gapRun = 0
        } else {
            gapRun += 1
            if !frozen && gapRun > freezeReads {
                frozen = true
                curFrozen.store(true, ordering: .relaxed)
                rate = 0
                curRate.store(0, ordering: .relaxed)
                debt = 0
                let rw = Int(min(gapRun - 1, Int64(rawBuf.count)))
                rawBuf.removeLast(rw)
                virtBuf.removeLast(rw)
            }
        }
        if frozen { return }

        rawBuf.append(fill)
        virtBuf.append(wp - r * tick)
        if Int64(rawBuf.count) >= windowReads {
            closeWindow()
        }
    }

    private func closeWindow() {
        let (medRaw, minRaw, _) = winStats(rawBuf)
        let (medV, minV, maxV) = winStats(virtBuf)

        // Per-side widths from the virtual view, rank-filtered over K
        // windows, held eager-up and reluctant-down.
        let wlMeas = min(medV - minV, wlCap)
        let whMeas = maxV - medV
        wlHist[histPos] = wlMeas
        whHist[histPos] = whMeas
        histPos = (histPos + 1) % Self.v4WidthHistory
        if histLen < Self.v4WidthHistory { histLen += 1 }
        let wlEff = Self.rankNth(wlHist, histLen, Self.v4WidthRank)
        let whEff = Self.rankNth(whHist, histLen, Self.v4WidthRank)
        wl = max(Double(wlEff), wl - narrowStep)
        wh = max(Double(whEff), wh - narrowStep)
        curWL.store(Int64(wl), ordering: .relaxed)
        curWH.store(Int64(wh), ordering: .relaxed)

        // Feed-forward drift estimate: the slope of the window-median
        // virtual signal across the K-window horizon, median-of-triplet
        // endpoints, with a half-quantum dead zone.
        ffTicks.append(tick)
        ffVals.append(medV)
        if ffTicks.count > Self.v4WidthHistory {
            ffTicks.removeFirst()
            ffVals.removeFirst()
        }
        var slope = 0.0
        let n = ffTicks.count
        if n >= 2 && ffTicks[n - 1] > ffTicks[0] {
            var lo = ffVals[0], hi = ffVals[n - 1]
            var ta = ffTicks[0], tb = ffTicks[n - 1]
            if n >= 6 {
                lo = Self.median3(ffVals[0], ffVals[1], ffVals[2])
                hi = Self.median3(ffVals[n - 3], ffVals[n - 2], ffVals[n - 1])
                ta = ffTicks[1]; tb = ffTicks[n - 2]
            }
            let span = tb - ta
            if span > 0 {
                let perRead = Double(hi - lo) / Double(span)
                let d = perRead * Double(span)
                if d >= Double(ffDeadZone) || d <= -Double(ffDeadZone) {
                    slope = perRead * Double(sr) / Double(r)
                }
            }
        }

        // Deadband spans the full measured late-side envelope.
        let dbEff = max(deadband, Int64(wl))
        let sp = min(max(spBase + Int64(kLow * wl + 0.5), flDecl), spMax)
        setpoint.store(sp, ordering: .relaxed)

        // The shipping controller (Go PServo.Decide): the min-displacement
        // macro-trim, else the drop-only P anchor plus the soft-clamped
        // feed-forward term, rate-capped.
        var newRate = 0.0
        var trim: Int64 = 0
        if minRaw - sp > theta {
            trim = medRaw - sp
        } else {
            let ff = Self.softClamp(slope, ffClamp)
            var p = 0.0
            let e = medRaw - sp
            if e > dbEff {
                p = gain * Double(e - dbEff)
            }
            newRate = Self.clampRate(p + ff, rateCap)
        }
        if newRate > rateCap { newRate = rateCap } else if newRate < -rateCap { newRate = -rateCap }
        rate = newRate
        curRate.store(rate.bitPattern, ordering: .relaxed)
        if trim > 0 { pendingTrim = trim }
        resetWindow()
    }

    private func winStats(_ buf: [Int64]) -> (med: Int64, lo: Int64, hi: Int64) {
        sortBuf.removeAll(keepingCapacity: true)
        sortBuf.append(contentsOf: buf)
        sortBuf.sort()
        let n = sortBuf.count
        return (sortBuf[n / 2], sortBuf[0], sortBuf[n - 1])
    }

    private func resetWindow() {
        rawBuf.removeAll(keepingCapacity: true)
        virtBuf.removeAll(keepingCapacity: true)
    }

    static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var a = a, b = b
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    static func median3(_ a: Int64, _ b: Int64, _ c: Int64) -> Int64 {
        var a = a, b = b
        if a > b { swap(&a, &b) }
        if b > c { b = c }
        return max(a, b)
    }

    /// The n-th highest of the first `len` values: the recurrence filter.
    static func rankNth(_ h: [Int64], _ len: Int, _ n: Int) -> Int64 {
        var n = n
        if len < n { n = len }
        var top = [Int64](repeating: -(1 << 62), count: 8)
        for k in 0..<len {
            let v = h[k]
            for i in 0..<n where v > top[i] {
                if i + 1 < n {
                    for j in stride(from: n - 1, to: i, by: -1) { top[j] = top[j - 1] }
                }
                top[i] = v
                break
            }
        }
        return top[n - 1]
    }

    static func softClamp(_ v: Double, _ c: Double) -> Double {
        if v > c || v < -c { return c * c / v }
        return v
    }

    static func clampRate(_ v: Double, _ cap: Double) -> Double {
        if v > cap { return cap }
        if v < -cap { return -cap }
        return v
    }

    // MARK: Splices and ring copies

    /// nFrames+1 ring frames into an nFrames output with one frame
    /// removed at the minimum-discontinuity cut, averaged into one
    /// boundary frame.
    private func spliceDrop(_ dst: UnsafeMutablePointer<Float>, _ rp: Int64, _ nFrames: Int64) {
        var cut: Int64 = 0
        var best: Float = -1
        for i in 0..<nFrames {
            let d = frameDiff(rp + i, rp + i + 1)
            if best < 0 || d <= best { best = d; cut = i }
        }
        let ncI = Int64(nc)
        for j in 0..<nFrames {
            var src = rp + j
            if j > cut { src += 1 }
            let sb = Int((src % capacity) * ncI)
            let db = Int(j * ncI)
            if j == cut {
                let nb = Int(((src + 1) % capacity) * ncI)
                for ch in 0..<nc { dst[db + ch] = (data[sb + ch] + data[nb + ch]) * 0.5 }
                continue
            }
            for ch in 0..<nc { dst[db + ch] = data[sb + ch] }
        }
    }

    /// nFrames−1 ring frames into an nFrames output with one synthetic
    /// frame added at the cut, the average of the pair around it.
    private func spliceInsert(_ dst: UnsafeMutablePointer<Float>, _ rp: Int64, _ nFrames: Int64) {
        var cut: Int64 = 1
        var best: Float = -1
        var i: Int64 = 1
        while i < nFrames {
            let d = frameDiff(rp + i - 1, rp + i)
            if best < 0 || d <= best { best = d; cut = i }
            i += 1
        }
        let ncI = Int64(nc)
        for j in 0..<nFrames {
            var src = rp + j
            if j > cut { src -= 1 }
            let db = Int(j * ncI)
            if j == cut {
                let ab = Int(((rp + cut - 1) % capacity) * ncI)
                let bb = Int(((rp + cut) % capacity) * ncI)
                for ch in 0..<nc { dst[db + ch] = (data[ab + ch] + data[bb + ch]) * 0.5 }
                continue
            }
            let sb = Int((src % capacity) * ncI)
            for ch in 0..<nc { dst[db + ch] = data[sb + ch] }
        }
    }

    private func frameDiff(_ p: Int64, _ q: Int64) -> Float {
        let ncI = Int64(nc)
        let pb = Int((p % capacity) * ncI)
        let qb = Int((q % capacity) * ncI)
        var d: Float = 0
        for ch in 0..<nc {
            var x = data[pb + ch] - data[qb + ch]
            if x < 0 { x = -x }
            d += x
        }
        return d
    }

    private func writeToRing(_ src: UnsafePointer<Float>, _ wp: Int64, _ nFrames: Int64) {
        let startFrame = wp % capacity
        let ncI = Int64(nc)
        let base = data.baseAddress!
        if startFrame + nFrames <= capacity {
            (base + Int(startFrame * ncI)).update(from: src, count: Int(nFrames * ncI))
            return
        }
        let first = capacity - startFrame
        (base + Int(startFrame * ncI)).update(from: src, count: Int(first * ncI))
        base.update(from: src + Int(first * ncI), count: Int((nFrames - first) * ncI))
    }

    private func readFromRing(_ dst: UnsafeMutablePointer<Float>, _ rp: Int64, _ nFrames: Int64) {
        let startFrame = rp % capacity
        let ncI = Int64(nc)
        let base = data.baseAddress!
        if startFrame + nFrames <= capacity {
            dst.update(from: base + Int(startFrame * ncI), count: Int(nFrames * ncI))
            return
        }
        let first = capacity - startFrame
        dst.update(from: base + Int(startFrame * ncI), count: Int(first * ncI))
        (dst + Int(first * ncI)).update(from: base, count: Int((nFrames - first) * ncI))
    }

    // MARK: Observers

    /// Fill in frames, safe from any thread.
    public var fillFrames: Int64 {
        writePos.load(ordering: .relaxed) - readPos.load(ordering: .relaxed)
    }

    /// The stats view; every field is a reader-written atomic.
    public func snapshot() -> Snapshot {
        let rp = readPos.load(ordering: .relaxed)
        let wp = writePos.load(ordering: .relaxed)
        var s = Snapshot()
        s.fillFrames = Int(wp - rp)
        s.setpointFrames = Int(setpoint.load(ordering: .relaxed))
        s.widthLowFrames = Int(curWL.load(ordering: .relaxed))
        s.widthHighFrames = Int(curWH.load(ordering: .relaxed))
        s.ratePerSec = Double(bitPattern: curRate.load(ordering: .relaxed))
        s.frozen = curFrozen.load(ordering: .relaxed)
        s.started = rp > 0
        s.underruns = statsUnderruns.load(ordering: .relaxed)
        s.laps = statsLaps.load(ordering: .relaxed)
        s.overruns = statsOverruns.load(ordering: .relaxed)
        s.trims = statsTrims.load(ordering: .relaxed)
        s.samplesDropped = statsDropped.load(ordering: .relaxed)
        s.samplesInserted = statsInserted.load(ordering: .relaxed)
        return s
    }
}
