# lasa-swift

The Swift LASA client (module `LasaSwift`): Apple's QUIC (`NetworkConnection<QUIC>`) under
a MoQ session, the LASA layer, and the audio engine with the v4
jitter buffer. Design: `lasa-planning/plan/lasa-swift.md`; plan:
`lasa-planning/plan/ios-library.md`; the measurements it rests on:
`lasa-planning/plan/ios-transport-tests.md` §7.

**Floor: iOS 26 and macOS 26.** The transport API is iOS 26 only
(`ios-transport.md` §4.1). Raw QUIC with ALPN `moqt-16`; Apple exposes
no WebTransport client.

Status, 2026-11-03: lifted from `lasa-ios-probe`'s ProbeKit (step 1
of the plan). What is here passes S1 to S4 on an iPhone 17; what is
not yet here is the port map's "to port" rows in the spec §3 (state
store and sync, presence and roster, the uplink sequencer, controls,
coordinates), the engine's interruption handling (spec §4) and the
public names of spec §2. The `LasaClient` type is still the probe's shape.

## Build and test

```
swift build
swift test                                   # vectors, replays, Opus timing
scripts/live-suite.sh                        # S1 to S4 smokes against test.panaudia.com
```

Xcode 27 (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`).
libopus ships as `opus.xcframework` (device, simulator, macOS arm64),
a path-based binary target until the release pipeline attaches it to
a tag.

## Rules

The twelve rules are in the spec §5. The two that matter most, from
Paul: no timestamps beyond the LASA spec, out or in; and outgoing
audio is never buffered or timed.

## Licences

MIT (`LICENSE`). libopus is BSD-3-Clause (`LICENSES/opus.txt`, also
inside the xcframework).
