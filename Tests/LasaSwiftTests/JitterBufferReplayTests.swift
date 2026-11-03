// Fixture-equality replay of the ported v4 jitter buffer: the Go
// jitterlab's exported traces (lasa/typescript/tests/fixtures/jitter-v4,
// from panaudia-engine jitterlab/export.go) are replayed against the Swift
// core and the artifact ledger must match the Go reference's entry for
// entry, the same test the TypeScript port passes
// (lasa/typescript/tests/jitter-v4-replay.test.ts). The buffer is never
// asked what it did: the ramp signal carries each frame's stream position
// and a black-box decoder (a port of tests/ramp-ledger.ts) reads drops,
// inserts, snaps and silence off the output by value.

import XCTest
@testable import LasaSwift

@available(macOS 15.0, iOS 18.0, *)
final class JitterBufferReplayTests: XCTestCase {
    static let rampWrap = 1 << 20

    static func fillRamp(_ dst: UnsafeMutableBufferPointer<Float>, pos: Int, frames: Int, nc: Int) {
        for f in 0..<frames {
            let v = Float(1 + ((pos + f) % rampWrap))
            for ch in 0..<nc { dst[f * nc + ch] = v }
        }
    }

    static func markerValue(_ p: Int) -> Float {
        let a = Float(1 + (p % rampWrap))
        let b = Float(1 + ((p + 1) % rampWrap))
        return (a + b) * 0.5
    }

    static func unwrapPos(_ lastAbs: Int, _ w: Int) -> Int {
        let next = lastAbs + 1
        var d = (((w - (next % rampWrap)) % rampWrap) + rampWrap) % rampWrap
        if d > rampWrap / 2 { d -= rampWrap }
        return next + d
    }

    enum Kind: Int { case drop = 0, insert, snap, silence, alien, lossGap }
    typealias Row = [Int] // [kind, time, pos, delta]

    final class RampDecoder {
        let nc: Int
        var lastPos = -1
        var silenceOpen = false
        var silenceTime = 0
        var silenceFrames = 0
        var joinSilenceFrames = 0
        var alienSamples = 0
        var artifacts: [Row] = []
        init(nc: Int) { self.nc = nc }

        func feed(_ time: Int, _ block: UnsafeBufferPointer<Float>) {
            let nFrames = block.count / nc
            for f in 0..<nFrames {
                let v = block[f * nc]
                if v == 0 {
                    if lastPos < 0 { joinSilenceFrames += 1; continue }
                    if !silenceOpen { silenceOpen = true; silenceTime = time; silenceFrames = 0 }
                    silenceFrames += 1
                    continue
                }
                let i = Int(v.rounded(.towardZero))
                let frac = v - Float(i)
                if frac == 0 {
                    if i >= 1 && i <= rampWrap { closeSilence(); plainSample(time, i - 1) } else { alienSamples += 1 }
                } else if frac == 0.5 {
                    closeSilence(); markerSample(time, v)
                } else {
                    alienSamples += 1
                }
            }
        }

        func plainSample(_ time: Int, _ w: Int) {
            if lastPos < 0 { lastPos = w; return }
            let pos = unwrapPos(lastPos, w)
            if pos != lastPos + 1 { artifacts.append([Kind.snap.rawValue, time, pos, pos - (lastPos + 1)]) }
            lastPos = pos
        }

        func markerSample(_ time: Int, _ v: Float) {
            if lastPos < 0 { alienSamples += 1; return }
            if v == markerValue(lastPos) {
                artifacts.append([Kind.insert.rawValue, time, lastPos + 1, 0])
            } else if v == markerValue(lastPos + 1) {
                artifacts.append([Kind.drop.rawValue, time, lastPos + 2, 0])
                lastPos += 2
            } else {
                alienSamples += 1
            }
        }

        func closeSilence() {
            if !silenceOpen { return }
            silenceOpen = false
            artifacts.append([Kind.silence.rawValue, silenceTime, lastPos, silenceFrames])
        }

        func finish() { closeSilence() }
    }

    struct Fixture: Decodable {
        struct Geometry: Decodable { let sampleRate, numChannels, writerFrames, readerFrames: Int }
        struct Config: Decodable { let floorFrames: Int; let robustness: Double; let capacityFrames: Int }
        struct Summary: Decodable, Equatable {
            let drops, inserts, snaps, lossGaps, silenceRuns, silenceFrames, concealedFrames, alienSamples, joinTime: Int
        }
        let name: String
        let geometry: Geometry
        let config: Config
        let events: [[Int]]
        let ledger: [[Int]]?
        let summary: Summary
    }

    func replay(_ fx: Fixture) -> (ledger: [Row], summary: Fixture.Summary) {
        let nc = fx.geometry.numChannels
        var cfg = JitterBuffer.Config()
        cfg.sampleRate = fx.geometry.sampleRate
        cfg.numChannels = nc
        cfg.writerFrames = Int64(fx.geometry.writerFrames)
        cfg.readerFrames = Int64(fx.geometry.readerFrames)
        cfg.floorFrames = Int64(fx.config.floorFrames)
        cfg.robustness = fx.config.robustness
        cfg.capacityFrames = Int64(fx.config.capacityFrames)
        let core = JitterBuffer(cfg)
        let dec = RampDecoder(nc: nc)
        var maxW = 0, maxR = 0
        for e in fx.events {
            if (e[1] == 0 || e[1] == 3) && e[2] > maxW { maxW = e[2] }
            if e[1] == 1 && e[2] > maxR { maxR = e[2] }
        }
        let wbuf = UnsafeMutableBufferPointer<Float>.allocate(capacity: max(maxW, 1) * nc)
        let rbuf = UnsafeMutableBufferPointer<Float>.allocate(capacity: max(maxR, 1) * nc)
        defer { wbuf.deallocate(); rbuf.deallocate() }
        typealias Gap = (pos: Int, frames: Int)
        var gaps: [Gap] = []
        var concealed: [Gap] = []
        var concealedFrames = 0
        var joinTime = -1
        for e in fx.events {
            let (time, kind, frames, pos) = (e[0], e[1], e[2], e[3])
            switch kind {
            case 0, 3:
                let src = UnsafeMutableBufferPointer(rebasing: wbuf[0..<frames * nc])
                if kind == 3 {
                    src.update(repeating: 0)
                    concealed.append((pos, frames)); concealedFrames += frames
                } else {
                    Self.fillRamp(src, pos: pos, frames: frames, nc: nc)
                }
                core.write(UnsafeBufferPointer(src))
            case 2:
                gaps.append((pos, frames))
            case 1:
                let produced = core.read(into: rbuf.baseAddress!, frames: Int64(frames))
                dec.feed(time, UnsafeBufferPointer(rebasing: rbuf[0..<frames * nc]))
                if produced && joinTime < 0 { joinTime = time }
            default: break
            }
        }
        dec.finish()
        concealed.sort { $0.pos < $1.pos }
        func rangeIn(_ list: [Gap], _ lo: Int, _ hi: Int) -> Int {
            var n = 0
            for g in list { if g.pos >= hi { break }; if g.pos >= lo { n += g.frames } }
            return n
        }
        var ledger = dec.artifacts
        for i in ledger.indices {
            let a = ledger[i]
            if a[0] == Kind.snap.rawValue && a[3] > 0 && rangeIn(gaps, a[2] - a[3], a[2]) + rangeIn(concealed, a[2] - a[3], a[2]) == a[3] {
                ledger[i][0] = Kind.lossGap.rawValue
            }
            if a[0] == Kind.silence.rawValue && rangeIn(concealed, a[2] + 1, a[2] + 1 + a[3]) == a[3] {
                ledger[i][0] = Kind.lossGap.rawValue
            }
        }
        var drops = 0, inserts = 0, snaps = 0, lossGaps = 0, silenceRuns = 0, silenceFrames = 0
        for a in ledger {
            switch Kind(rawValue: a[0])! {
            case .drop: drops += 1
            case .insert: inserts += 1
            case .snap: snaps += 1
            case .lossGap: lossGaps += 1
            case .silence: silenceRuns += 1; silenceFrames += a[3]
            case .alien: break
            }
        }
        let summary = Fixture.Summary(drops: drops, inserts: inserts, snaps: snaps, lossGaps: lossGaps,
                                      silenceRuns: silenceRuns, silenceFrames: silenceFrames,
                                      concealedFrames: concealedFrames, alienSamples: dec.alienSamples, joinTime: joinTime)
        return (ledger, summary)
    }

    static let kindNames = ["drop", "insert", "snap", "silence", "alien", "lossgap"]
    static func rowStr(_ r: Row) -> String { "\(kindNames[r[0]]) t=\(r[1]) pos=\(r[2]) delta=\(r[3])" }

    func testLedgerEqualityWithTheGoReference() throws {
        guard let dir = Bundle.module.url(forResource: "Fixtures/jitter-v4", withExtension: nil)
            ?? Bundle.module.resourceURL?.appendingPathComponent("Fixtures/jitter-v4") else {
            return XCTFail("fixtures not in the bundle")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertGreaterThan(files.count, 0, "no fixtures in \(dir.path)")
        for file in files {
            let fx = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: dir.appendingPathComponent(file)))
            let want = fx.ledger ?? []
            let got = replay(fx)
            let n = min(want.count, got.ledger.count)
            for i in 0..<n where want[i] != got.ledger[i] {
                XCTFail("\(fx.name): ledger diverges at entry \(i): go \(Self.rowStr(want[i])), swift \(Self.rowStr(got.ledger[i]))")
                break
            }
            XCTAssertEqual(want.count, got.ledger.count, "\(fx.name): ledger length")
            XCTAssertEqual(got.summary, fx.summary, "\(fx.name): summary")
            print("[jitter] \(fx.name): \(fx.events.count) events, ledger \(want.count) entries, summary matches: \(got.summary == fx.summary)")
        }
    }
}
