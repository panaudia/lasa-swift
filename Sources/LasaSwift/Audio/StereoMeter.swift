// The stereo meter (lasa/typescript/src/audio/stereo-meter-core.ts,
// ported 2026-11-03): three running sums per window, the report at
// snapshot time. Fed off the audio thread: the capture pump meters the
// PCM it encodes, the sink pipeline the PCM it decodes (the TypeScript
// client's tap A), so the render block stays a single buffer read
// (rule 7).

import Foundation
import os

public struct StereoMeterReport: Sendable, Equatable {
    public var frames = 0
    public var rmsL = 0.0
    public var rmsR = 0.0
    /// RMS of (L+R)/2, the mono content.
    public var midRms = 0.0
    /// RMS of (L-R)/2; about 0 means a mono collapse.
    public var sideRms = 0.0
    /// L/R correlation at lag 0, -1 to 1; 0 when either side is silent.
    public var correlation = 0.0
    public init() {}
}

public final class StereoMeter: @unchecked Sendable {
    private struct Acc { var ll = 0.0, rr = 0.0, lr = 0.0; var frames = 0 }
    private let acc = OSAllocatedUnfairLock(initialState: Acc())

    public init() {}

    /// Interleaved PCM; `channels` is the stride and only the first two
    /// are measured. Mono reads as L = R.
    public func write(interleaved pcm: UnsafePointer<Float>, frames n: Int, channels: Int) {
        guard channels >= 1, n > 0 else { return }
        var ll = 0.0, rr = 0.0, lr = 0.0
        for i in 0..<n {
            let l = Double(pcm[i * channels])
            let r = channels > 1 ? Double(pcm[i * channels + 1]) : l
            ll += l * l; rr += r * r; lr += l * r
        }
        let (dll, drr, dlr) = (ll, rr, lr)
        acc.withLock { $0.ll += dll; $0.rr += drr; $0.lr += dlr; $0.frames += n }
    }

    /// The window's report, and a fresh window.
    public func snapshotAndReset() -> StereoMeterReport {
        let a = acc.withLock { a in defer { a = Acc() }; return a }
        var r = StereoMeterReport()
        guard a.frames > 0 else { return r }
        let f = Double(a.frames)
        r.frames = a.frames
        r.rmsL = (a.ll / f).squareRoot()
        r.rmsR = (a.rr / f).squareRoot()
        r.midRms = (max(0, a.ll + a.rr + 2 * a.lr) / (4 * f)).squareRoot()
        r.sideRms = (max(0, a.ll + a.rr - 2 * a.lr) / (4 * f)).squareRoot()
        let denom = (a.ll * a.rr).squareRoot()
        r.correlation = denom > 1e-20 ? max(-1, min(1, a.lr / denom)) : 0
        return r
    }
}

/// The meters an app shows: linear RMS of what went up and what came
/// down in the last window.
public struct Levels: Sendable, Equatable {
    public var input = 0.0
    public var output = 0.0
    public var outputStereo = StereoMeterReport()
    public init() {}
}
