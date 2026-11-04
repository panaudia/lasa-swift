import SwiftUI
import AVFoundation
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
}

@MainActor
final class SessionModel: ObservableObject {
    var address = "", space = "", clientID = "", ticket = "", name = ""
    var redundancy = 0
    @Published var route: AudioRoute = .device
    @Published var sending = false
    @Published var connected = false
    @Published var status = "idle"
    @Published var roster: [RosterEntry] = []
    @Published var levels = Levels()
    @Published var routeReport = ""
    @Published var engine = ""

    private var client: LasaClient?
    private var audio: LasaAudio?
    private var capture: CaptureHandle?
    private var player: SinkPlayer?
    private var presence: PresenceRoster?
    private var poll: Timer?
    private var tasks: [Task<Void, Never>] = []
    private let lifecycle = UIApplicationLifecycle()

    // One entity carries both the sink and the source. The server
    // never renders an entity's own source into its own sink, so this
    // is what keeps you from hearing your own microphone; two entities
    // (ears and mic) would hear each other.
    var entityID: String { clientID + "-me" }

    func connect(_ s: Settings) {
        guard client == nil else { return }
        address = s.address; space = s.space; clientID = s.clientID; ticket = s.ticket; name = s.name
        redundancy = s.redundancy
        status = "connecting"
        var o = LasaClientOptions(address: address, spaceID: space, clientID: clientID)
        o.ticket = ticket.isEmpty ? nil : ticket
        o.entities = [
            Lasa.Entity(id: entityID, name: name, hears: [space], heardIn: [space],
                        redundancy: redundancy > 0 ? redundancy : nil),
        ]
        o.lifecycle = lifecycle
        o.log = { line in print("[lasa] \(line)") }
        let c = LasaClient(o)
        client = c
        Task {
            do {
                try await c.connect()
                let r = try await c.subscribeRoster()
                presence = r
                let avs = AVAudioSession.sharedInstance()
                let report = try LasaAudio.configure(avs, route: route, preferredIODurationMS: 10)
                routeReport = report.description
                let a = LasaAudio(session: avs, preferredIODurationMS: 10)
                audio = a
                player = try await c.playSink(entity: entityID, format: .binaural, audio: a)
                if sending { capture = try await c.startCapture(entity: entityID, audio: a) }
                connected = true
                status = "connected, handshake \(Int(c.stats.handshakeMS)) ms"
                tasks.append(Task { [weak self] in
                    for await e in c.events { await MainActor.run { self?.status = "\(e)" } }
                })
                tasks.append(Task { [weak self] in
                    for await e in a.events { await MainActor.run { self?.engine = "\(e)" } }
                })
                poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.tick() }
                }
            } catch {
                status = "failed: \(error)"
                disconnect()
            }
        }
    }

    func setSending(_ on: Bool) {
        sending = on
        guard let c = client, let a = audio, connected else { return }
        Task {
            if on { capture = try? await c.startCapture(entity: entityID, audio: a) }
            else { capture?.stop(); capture = nil }
        }
    }

    private func tick() {
        guard let c = client else { return }
        roster = presence?.entries ?? []
        levels = c.levels
        let s = c.audioStats
        engine = "engine \(s.engine.state) restarts \(s.engine.restarts) render max \(String(format: "%.2f", Double(s.engine.renderMaxNS) / 1e6)) ms"
            + (s.sink.map { " buffer \($0.jitter.fillFrames / 48) ms underruns \($0.jitter.underruns) lost \($0.lostFrames)" } ?? "")
    }

    func disconnect() {
        poll?.invalidate(); poll = nil
        for t in tasks { t.cancel() }; tasks = []
        capture?.stop(); capture = nil
        player?.stop(); player = nil
        client?.close(); client = nil
        audio = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        connected = false
        roster = []
        if !status.hasPrefix("failed") { status = "idle" }
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
                Section("Session") {
                    Button(model.connected ? "Leave" : "Join") {
                        if model.connected { model.disconnect() }
                        else { model.connect(Settings(address: address, space: space, clientID: clientID, ticket: ticket, name: name, redundancy: redundancy)) }
                    }
                    Text(model.status).font(.footnote.monospaced())
                    if !model.engine.isEmpty { Text(model.engine).font(.footnote.monospaced()).foregroundStyle(.secondary) }
                    LevelBar(label: "in", value: model.levels.input)
                    LevelBar(label: "out", value: model.levels.output)
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
