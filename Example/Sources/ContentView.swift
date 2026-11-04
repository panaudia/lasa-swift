import SwiftUI
import AVFoundation
import Network
import LasaSwift

struct Settings {
    var address = "test.panaudia.com:443"
    var space = "main"
    var clientID = "ios-" + String(UUID().uuidString.prefix(8)).lowercased()
    var ticket = ""
    var name = "iPhone"
    /// Maximum redundancy offset declared on the entity (core §4.2),
    /// both the sink request and the uplink bound. Offset n repairs a
    /// burst of up to n lost packets and costs a 2 * (n + 2) * 5 ms
    /// buffer floor. Without it a lost sink packet drains the jitter
    /// buffer 5 ms with nothing to conceal the hole (tests plan §7.14).
    var redundancy = 2
    /// The framework's QUIC keep-alive in seconds, 0 off (S7 decides).
    var keepAlive = 0
    /// Off for S7: the session carries no track traffic at all.
    var listen = true
}

@MainActor
final class SessionModel: ObservableObject {
    var settings = Settings()
    @Published var route: AudioRoute = .device
    @Published var sending = false
    @Published var connected = false
    @Published var status = "idle"
    @Published var roster: [RosterEntry] = []
    @Published var levels = Levels()
    @Published var routeReport = ""
    @Published var engine = ""
    @Published var lines: [String] = []

    private var client: LasaClient?
    private var audio: LasaAudio?
    private var player: SinkPlayer?
    private var capture: CaptureHandle?
    private var presence: PresenceRoster?
    private var poll: Timer?
    private var tasks: [Task<Void, Never>] = []
    private var pathMonitor: NWPathMonitor?
    private var lastPath = ""
    private var reconnecting = false
    /// Set by the client's `backgrounded` event: the connection was
    /// closed deliberately on entering the background with the engine
    /// stopped, and the example reconnects on return to the foreground
    /// without asking (an app may put a user action here).
    private var closedForBackground = false
    private var foregroundObserver: NSObjectProtocol?
    private var joinedAt = Date()
    private var allLines: [String] = []
    private var lastReceived: UInt64 = 0
    private var lastRateAt = Date()
    private var sinceEvent = Date()

    var entityID: String { settings.clientID + "-me" }

    // MARK: The log (S6, S7): the session's story as it happens, with
    // the time since Join; "copy log" puts the whole of it on the
    // pasteboard. No files.

    func note(_ s: String) {
        let line = String(format: "%+8.2f  ", Date().timeIntervalSince(joinedAt)) + s
        allLines.append(line)
        lines.append(line)
        if lines.count > 60 { lines.removeFirst(lines.count - 60) }
    }

    func copyLog() {
        UIPasteboard.general.string = allLines.joined(separator: "\n") + "\n"
        note("log copied (\(allLines.count) lines)")
    }

    // MARK: Connect

    func connect(_ s: Settings) {
        guard client == nil else { return }
        settings = s
        joinedAt = Date()
        lines = []; allLines = []
        note("join \(s.address) space \(s.space) client \(s.clientID) listen \(s.listen) keep-alive \(s.keepAlive) s fec \(s.redundancy) route \(route)")
        status = "connecting"
        UIApplication.shared.isIdleTimerDisabled = true
        startPathMonitor()
        if foregroundObserver == nil {
            foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.becameActive() }
            }
        }
        let c = makeClient()
        client = c
        Task {
            do {
                try await c.connect()
                try await start(c)
                connected = true
                status = "connected, handshake \(Int(c.stats.handshakeMS)) ms"
                note("connected, handshake \(Int(c.stats.handshakeMS)) ms, remote idle \(c.handshake?.remoteIdleTimeoutMS ?? 0) ms")
            } catch {
                status = "failed: \(error)"
                note("connect failed: \(error)")
                disconnect()
            }
        }
    }

    private func makeClient() -> LasaClient {
        var o = LasaClientOptions(address: settings.address, spaceID: settings.space, clientID: settings.clientID)
        o.ticket = settings.ticket.isEmpty ? nil : settings.ticket
        o.entities = [
            // One entity carries both the sink and the source. The server
            // never renders an entity's own source into its own sink, so
            // this is what keeps you from hearing your own microphone.
            Lasa.Entity(id: entityID, name: settings.name, hears: [settings.space], heardIn: [settings.space],
                        redundancy: settings.redundancy > 0 ? settings.redundancy : nil),
        ]
        o.keepAliveSeconds = settings.keepAlive
        // A fresh lifecycle object per client: an AsyncStream has one consumer.
        o.lifecycle = UIApplicationLifecycle()
        o.log = { [weak self] line in Task { @MainActor in self?.note("lasa: " + line) } }
        return LasaClient(o)
    }

    /// After connect: the roster, the sink, the microphone if on, and
    /// the event watchers. Used by Join and by every reconnect.
    private func start(_ c: LasaClient) async throws {
        tasks.append(Task { [weak self] in
            for await e in c.events { await self?.handle(e, from: c) }
        })
        if settings.listen {
            presence = try await c.subscribeRoster()
            let avs = AVAudioSession.sharedInstance()
            let a: LasaAudio
            if let existing = audio {
                a = existing
            } else {
                let report = try LasaAudio.configure(avs, route: route, preferredIODurationMS: 10)
                routeReport = report.description
                a = LasaAudio(session: avs, preferredIODurationMS: 10)
                audio = a
                tasks.append(Task { [weak self] in
                    for await e in a.events { await MainActor.run { self?.note("audio: \(e)") } }
                })
            }
            player = try await c.playSink(entity: entityID, format: .binaural, audio: a)
            if sending { capture = try await c.startCapture(entity: entityID, audio: a) }
        }
        lastReceived = 0
        lastRateAt = Date()
        sinceEvent = Date()
        if poll == nil {
            poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
    }

    // MARK: Events and reconnect

    private func handle(_ e: LasaClient.Event, from c: LasaClient) {
        guard c === client else { return }   // a superseded client's tail
        sinceEvent = Date()
        switch e {
        case .backgrounded:
            note("backgrounded with the engine stopped: closing, will reconnect on return")
            status = "closed for background"
            closedForBackground = true
        case .closed(let code, let reason):
            let name = code.flatMap { LasaRejectionCode(rawValue: $0)?.name } ?? "transport"
            note("closed: \(name) \(reason ?? "")")
            if closedForBackground { return }
            status = "closed: \(name)"
            if code == LasaRejectionCode.blocked.rawValue || code == LasaRejectionCode.superseded.rawValue {
                note("not reconnecting after \(name)")
                return
            }
            Task { await reconnect() }
        case .suspended:
            note("suspended (gap past half the idle timeout)")
        case .resumed(let r):
            switch r {
            case .alive(let ms): note(String(format: "resumed: alive, probe %.1f ms", ms))
            case .dead: note("resumed: dead")   // the client closes; .closed follows and reconnects
            }
        case .pathUpdated(let p):
            note("connection \(p)")
        }
    }

    private func becameActive() {
        guard closedForBackground, client != nil else { return }
        closedForBackground = false
        note("foreground after a background close: reconnecting")
        Task { await reconnect() }
    }

    /// The plan's reconnect (ios-library.md §7): a fresh connection with
    /// the same client and entity ids, which supersedes any half-open
    /// predecessor; a sequence of short dials, retried each second for a
    /// minute, because a dial begun inside the framework's ~3.4 s
    /// post-failure window never completes (tests plan §7.5).
    private func reconnect() async {
        guard !reconnecting, client != nil else { return }
        reconnecting = true
        defer { reconnecting = false }
        let t0 = Date()
        note("reconnecting")
        status = "reconnecting"
        for t in tasks { t.cancel() }; tasks = []
        capture?.stop(); capture = nil
        player?.stop(); player = nil
        client?.close(); client = nil
        presence = nil
        var attempt = 0
        while Date().timeIntervalSince(t0) < 60 {
            attempt += 1
            let c = makeClient()
            client = c
            do {
                try await c.connect(deadlineSeconds: 3)
                try await start(c)
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                note("reconnected on attempt \(attempt) in \(ms) ms, handshake \(Int(c.stats.handshakeMS)) ms")
                status = "reconnected in \(ms) ms"
                return
            } catch {
                note("attempt \(attempt) failed: \(error)")
                c.close()
                if client === c { client = nil }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        note("reconnect gave up after 60 s")
        status = "reconnect failed"
        disconnect()
    }

    // MARK: Device path (iOS 26 has no per-connection path handlers)

    private func startPathMonitor() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let text = QUICTransport.summarise(path)
            Task { @MainActor in
                guard let self, text != self.lastPath else { return }
                self.lastPath = text
                self.note("device path \(text)")
            }
        }
        m.start(queue: DispatchQueue(label: "path"))
        pathMonitor = m
    }

    // MARK: Controls

    func setSending(_ on: Bool) {
        sending = on
        guard let c = client, let a = audio, connected else { return }
        Task {
            if on { capture = try? await c.startCapture(entity: entityID, audio: a) }
            else { capture?.stop(); capture = nil }
        }
    }

    /// Every 250 ms: the meters and the engine line; once a second the
    /// sink's delivery rate, logged when it is not the steady 200
    /// packets a second and for the five seconds after any event, so a
    /// stall, a burst and the resume are in the log without a file.
    private func tick() {
        guard let c = client else { return }
        roster = presence?.entries ?? []
        levels = c.levels
        let s = c.audioStats
        if let sink = s.sink {
            engine = "engine \(s.engine.state) restarts \(s.engine.restarts) render max \(String(format: "%.2f", Double(s.engine.renderMaxNS) / 1e6)) ms"
                + " buffer \(sink.jitter.fillFrames / 48) ms underruns \(sink.jitter.underruns) lost \(sink.lostFrames) received \(sink.received)"
            let now = Date()
            let dt = now.timeIntervalSince(lastRateAt)
            if dt >= 1 {
                let rate = Double(sink.received &- lastReceived) / dt
                if rate < 150 || rate > 250 || now.timeIntervalSince(sinceEvent) < 5 {
                    note(String(format: "sink %.0f packets/s, buffer %d ms, underruns %d, lost %d", rate, sink.jitter.fillFrames / 48, sink.jitter.underruns, sink.lostFrames))
                }
                lastReceived = sink.received
                lastRateAt = now
            }
        } else {
            engine = "no sink"
        }
    }

    func disconnect() {
        poll?.invalidate(); poll = nil
        for t in tasks { t.cancel() }; tasks = []
        pathMonitor?.cancel(); pathMonitor = nil
        lastPath = ""
        if let o = foregroundObserver { NotificationCenter.default.removeObserver(o); foregroundObserver = nil }
        closedForBackground = false
        capture?.stop(); capture = nil
        player?.stop(); player = nil
        client?.close(); client = nil
        audio = nil
        presence = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        UIApplication.shared.isIdleTimerDisabled = false
        connected = false
        roster = []
        note("leave")
        if !status.hasPrefix("failed") && !status.hasPrefix("reconnect failed") { status = "idle" }
    }
}

struct ContentView: View {
    @StateObject private var model = SessionModel()
    @AppStorage("address") private var address = Settings().address
    @AppStorage("space") private var space = Settings().space
    @AppStorage("clientID") private var clientID = Settings().clientID
    @AppStorage("ticket") private var ticket = Settings().ticket
    @AppStorage("name") private var name = Settings().name
    @AppStorage("redundancy") private var redundancy = Settings().redundancy
    @AppStorage("keepAlive") private var keepAlive = Settings().keepAlive
    @AppStorage("listen") private var listen = Settings().listen

    var body: some View {
        NavigationStack {
            Form {
                Section("Space") {
                    TextField("host:port", text: $address).autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("space", text: $space).autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("client id", text: $clientID).autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("name", text: $name)
                    TextField("ticket (empty for an open space)", text: $ticket).autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                Section("Audio") {
                    Picker("route", selection: $model.route) {
                        Text("device").tag(AudioRoute.device)
                        Text("headset").tag(AudioRoute.headset)
                        Text("headset HQ").tag(AudioRoute.headsetHighQuality)
                    }.disabled(model.connected)
                    Stepper("FEC frames: \(redundancy)", value: $redundancy, in: 0...7).disabled(model.connected)
                    Toggle("send microphone", isOn: Binding(get: { model.sending }, set: { model.setSending($0) }))
                    if !model.routeReport.isEmpty { Text(model.routeReport).font(.footnote).foregroundStyle(.secondary) }
                }
                Section("Connection") {
                    Toggle("listen (subscribe the sink)", isOn: $listen).disabled(model.connected)
                    Stepper("keep-alive: \(keepAlive == 0 ? "off" : "\(keepAlive) s")", value: $keepAlive, in: 0...60, step: 5).disabled(model.connected)
                }
                Section("Session") {
                    Button(model.connected ? "Leave" : "Join") {
                        if model.connected { model.disconnect() }
                        else {
                            var s = Settings(address: address, space: space, clientID: clientID, ticket: ticket, name: name, redundancy: redundancy)
                            s.keepAlive = keepAlive
                            s.listen = listen
                            model.connect(s)
                        }
                    }
                    Text(model.status).font(.footnote.monospaced())
                    if !model.engine.isEmpty { Text(model.engine).font(.footnote.monospaced()).foregroundStyle(.secondary) }
                    LevelBar(label: "in", value: model.levels.input)
                    LevelBar(label: "out", value: model.levels.output)
                }
                Section("Log") {
                    Button("copy log") { model.copyLog() }
                    ForEach(Array(model.lines.suffix(30).enumerated()), id: \.offset) { _, l in
                        Text(l).font(.system(size: 10, design: .monospaced)).lineLimit(2)
                    }
                }
                Section("Roster (\(model.roster.count))") {
                    ForEach(model.roster, id: \.id) { e in
                        HStack {
                            Text(e.id).font(.footnote.monospaced())
                            Spacer()
                            Text(String(format: "%.0f dB", Lasa.loudnessToDBFS(e.loudness))).font(.footnote)
                            if e.headFrame { Image(systemName: "person.crop.circle") }
                        }
                    }
                }
            }
            .navigationTitle("LASA")
        }
    }
}

struct LevelBar: View {
    let label: String
    let value: Double   // linear RMS
    var body: some View {
        HStack {
            Text(label).font(.footnote.monospaced()).frame(width: 28, alignment: .leading)
            GeometryReader { g in
                let db = 20 * log10(max(value, 1e-5))
                let frac = max(0, min(1, (db + 60) / 60))
                ZStack(alignment: .leading) {
                    Rectangle().fill(.quaternary)
                    Rectangle().fill(.green).frame(width: g.size.width * frac)
                }
            }.frame(height: 8)
        }
    }
}
