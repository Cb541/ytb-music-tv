import AVFAudio
import Combine
import MusicKit
import SwiftUI
import UIKit

@main
struct MusicKitAtmosTestApp: App {
    init() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            NSLog("MusicKit test audio session setup failed: %@", error.localizedDescription)
        }
    }

    var body: some Scene {
        WindowGroup { MusicKitTestScreen() }
    }
}

@MainActor
final class MusicKitTestModel: ObservableObject {
    @Published var query = "Blinding Lights The Weeknd"
    @Published private(set) var authorization = MusicAuthorization.currentStatus
    @Published private(set) var subscription: MusicSubscription?
    @Published private(set) var songs: [Song] = []
    @Published private(set) var selected: Song?
    @Published private(set) var playbackStarted = false
    @Published private(set) var busy = false
    @Published private(set) var operation = "Connect to Apple Music to begin"
    @Published private(set) var failure: String?
    @Published private(set) var catalogEvidence = "Choose a song"
    @Published private(set) var log: [String] = []
    @Published private(set) var route = ""
    private var generation = 0

    let player = ApplicationMusicPlayer.shared

    var permissionLabel: String {
        switch authorization {
        case .authorized: return "Authorized"
        case .denied: return "Denied — allow access in Settings"
        case .restricted: return "Restricted by account or device settings"
        case .notDetermined: return "Not requested"
        @unknown default: return "Unknown"
        }
    }

    var subscriptionLabel: String {
        guard let subscription else { return "Not checked" }
        return subscription.canPlayCatalogContent ? "Full-track playback available" : "Apple Music subscription required"
    }

    func refreshRoute() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        route = outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
        if route.isEmpty { route = "Not reported by the app audio session" }
    }

    func connect() async {
        guard !busy else { return }
        busy = true
        failure = nil
        defer { busy = false }
        operation = "Requesting Apple Music access…"
        authorization = await MusicAuthorization.request()
        record("Authorization: \(permissionLabel)")
        guard authorization == .authorized else {
            operation = "Apple Music access is required"
            return
        }
        do {
            operation = "Checking subscription…"
            subscription = try await MusicSubscription.current
            operation = subscriptionLabel
            record(subscriptionLabel)
        } catch { report(error, stage: "Subscription check") }
        refreshRoute()
    }

    func search() async {
        guard !busy else { return }
        guard authorization == .authorized else {
            failure = "Choose Connect first and allow Apple Music access."
            return
        }
        guard let input = MusicTestInput.parse(query) else { return }
        busy = true
        failure = nil
        operation = "Searching Apple Music…"
        defer { busy = false }
        do {
            switch input {
            case .search(let term):
                var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
                request.limit = 10
                let response = try await request.response()
                songs = Array(response.songs)
            case .songID(let value):
                let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(value))
                songs = Array(try await request.response().items)
            }
            operation = songs.isEmpty ? "No songs found in this account’s storefront" : "Select a song to test full playback"
            record("Catalog returned \(songs.count) songs")
        } catch {
            songs = []
            report(error, stage: "Catalog search")
        }
    }

    func play(_ song: Song) async {
        guard !busy, authorization == .authorized else { return }
        busy = true
        failure = nil
        generation += 1
        let requestGeneration = generation
        defer { busy = false }
        // Remove the previous queue and evidence before starting a new test.
        player.stop()
        playbackStarted = false
        selected = song
        catalogEvidence = "Checking available mixes…"
        operation = "Loading \(song.title)…"
        do {
            subscription = try await MusicSubscription.current
            guard subscription?.canPlayCatalogContent == true else {
                operation = subscriptionLabel
                catalogEvidence = "Playback unavailable without a subscription"
                return
            }
            var playable = song
            do {
                playable = try await song.with(.audioVariants)
                if let variants = playable.audioVariants {
                    catalogEvidence = variants.contains(.dolbyAtmos)
                        ? "Dolby Atmos is available for this catalog version"
                        : "This catalog version does not list Dolby Atmos"
                } else {
                    catalogEvidence = "Available mixes not reported by the catalog"
                }
            } catch {
                // A metadata failure must not block testing the actual playback engine.
                catalogEvidence = "Could not load mix metadata; checking actual playback"
                record("Mix metadata lookup failed")
            }
            guard requestGeneration == generation else { return }
            selected = playable
            player.queue = ApplicationMusicPlayer.Queue(for: [playable])
            try await player.prepareToPlay()
            guard requestGeneration == generation else { return }
            try await player.play()
            guard requestGeneration == generation else { return }
            playbackStarted = true
            operation = "Playing through native MusicKit"
            record("Playback started: \(playable.title)")
            refreshRoute()
        } catch {
            guard requestGeneration == generation else { return }
            player.stop()
            playbackStarted = false
            report(error, stage: "Playback")
        }
    }

    func togglePlayback() async {
        guard !busy, selected != nil else { return }
        if player.state.playbackStatus == .playing {
            player.pause()
            operation = "Paused"
        } else {
            busy = true
            defer { busy = false }
            do {
                try await player.play()
                playbackStarted = true
                operation = "Playing through native MusicKit"
            } catch { report(error, stage: "Resume") }
        }
    }

    func stop() {
        generation += 1
        player.stop()
        playbackStarted = false
        selected = nil
        catalogEvidence = "Choose a song"
        operation = "Stopped"
    }

    private func record(_ message: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        log.insert("\(stamp)  \(message)", at: 0)
        log = Array(log.prefix(5))
    }

    private func report(_ error: Error, stage: String) {
        let ns = error as NSError
        // Never dump request headers, credentials, or the full NSError userInfo.
        failure = "\(stage): \(ns.domain) (\(ns.code)) — \(ns.localizedDescription)"
        operation = "\(stage) failed"
        record("\(stage) failed: \(ns.domain) (\(ns.code))")
    }
}

@MainActor
struct MusicKitTestScreen: View {
    @StateObject private var model = MusicKitTestModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("MusicKit Atmos Test").font(.system(size: 44, weight: .semibold))
                    Text("Native Apple Music playback • separate test app")
                        .font(.system(size: 22)).foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 44) {
                    VStack(alignment: .leading, spacing: 20) {
                        accountPanel
                        searchPanel
                        if let failure = model.failure {
                            Text(failure).font(.system(size: 18)).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("If the catalog reports a developer-token error, enable MusicKit for the signed app’s bundle ID in your Apple Developer account.")
                            .font(.system(size: 17)).foregroundStyle(.secondary)
                        Text("Bundle ID: \(Bundle.main.bundleIdentifier ?? "Unknown")")
                            .font(.system(size: 16, design: .monospaced)).foregroundStyle(.secondary)
                        Text("For Atmos: Settings → Apps → Music → Dolby Atmos → Automatic. Use an Atmos-capable audio output.")
                            .font(.system(size: 17)).foregroundStyle(.secondary)
                    }
                    .frame(width: 480, alignment: .leading)
                    VStack(alignment: .leading, spacing: 22) {
                        ActivePlaybackPanel(model: model)
                        searchResults
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !model.log.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Test activity").font(.headline)
                        ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 16, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 72).padding(.vertical, 50)
        }
        .background(Color.black.ignoresSafeArea())
        .tint(.cyan)
        .task { model.refreshRoute() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            model.refreshRoute()
        }
    }

    private var accountPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apple Music account").font(.title3.bold())
            Text("Access: \(model.permissionLabel)").font(.system(size: 20))
            Text(model.subscriptionLabel).font(.system(size: 19)).foregroundStyle(.secondary)
            Button("Connect / check account") { Task { await model.connect() } }
                .disabled(model.busy)
        }
    }

    private var searchPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Find a test song").font(.title3.bold())
            TextField("Song, artist, song ID or Apple Music song URL", text: $model.query)
                .onSubmit { Task { await model.search() } }
            Button("Search Apple Music") { Task { await model.search() } }
                .disabled(model.busy || model.authorization != .authorized)
            HStack(spacing: 12) {
                if model.busy { ProgressView() }
                Text(model.operation).font(.system(size: 18)).foregroundStyle(.secondary)
            }
        }
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Search results").font(.title3.bold())
            if model.songs.isEmpty {
                Text("Search for a song you know has an Atmos version in Apple Music.")
                    .font(.system(size: 19)).foregroundStyle(.secondary)
            }
            ForEach(model.songs, id: \.id) { song in
                Button {
                    Task { await model.play(song) }
                } label: {
                    HStack(spacing: 18) {
                        SongArtwork(song: song, size: 70)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(song.title).font(.system(size: 23, weight: .medium)).lineLimit(1)
                            Text("\(song.artistName) • \(song.albumTitle ?? "Single")")
                                .font(.system(size: 18)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "play.fill")
                    }
                    .padding(10)
                }
                .buttonStyle(.plain)
                .disabled(model.busy)
            }
        }
    }
}

@MainActor
struct ActivePlaybackPanel: View {
    @ObservedObject var model: MusicKitTestModel
    @ObservedObject private var state = ApplicationMusicPlayer.shared.state
    @ObservedObject private var queue = ApplicationMusicPlayer.shared.queue

    private var variantLabel: String? {
        guard let value = state.audioVariant else { return nil }
        if value == .dolbyAtmos { return "Dolby Atmos" }
        if value == .dolbyAudio { return "Dolby Audio" }
        if value == .lossless { return "Lossless" }
        if value == .highResolutionLossless { return "Hi-Res Lossless" }
        if value == .lossyStereo { return "Stereo (lossy)" }
        // Keep future spatial formats distinct from verified Dolby Atmos.
        return String(describing: value)
    }

    private var isPlaying: Bool {
        state.playbackStatus == .playing && model.playbackStarted && model.selected != nil && queue.currentEntry != nil
    }

    var body: some View {
        let confirmed = AtmosEvidence.isConfirmed(isPlaying: isPlaying, activeVariant: variantLabel)
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .top, spacing: 26) {
                SongArtwork(song: model.selected, size: 168)
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.selected?.title ?? "Ready to test").font(.system(size: 29, weight: .semibold))
                    Text(model.selected?.artistName ?? "Apple Music subscription required")
                        .font(.system(size: 21)).foregroundStyle(.secondary)
                    Text(model.catalogEvidence).font(.system(size: 18)).foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        let time = model.player.playbackTime
                        Text("Playback: \(time.isFinite ? Int(max(0, time)) : 0) seconds")
                            .font(.system(size: 18, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("MusicKit active audio").font(.system(size: 18)).foregroundStyle(.secondary)
                Text(AtmosEvidence.label(isPlaying: isPlaying, activeVariant: variantLabel))
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(confirmed ? Color.green : Color.white)
                Text(confirmed ? "MusicKit reports the Atmos variant during playback." : "An available Atmos mix alone is not proof of active Atmos playback.")
                    .font(.system(size: 17)).foregroundStyle(.secondary)
            }
            Text("App audio route: \(model.route)").font(.system(size: 17)).foregroundStyle(.secondary)
            HStack(spacing: 22) {
                Button(state.playbackStatus == .playing ? "Pause" : "Play") {
                    Task { await model.togglePlayback() }
                }
                .disabled(model.busy || model.selected == nil)
                Button("Stop") { model.stop() }.disabled(model.selected == nil)
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 20))
    }
}

struct SongArtwork: View {
    let song: Song?
    let size: CGFloat

    var body: some View {
        Group {
            if let url = song?.artwork?.url(width: Int(size * 2), height: Int(size * 2)) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: { placeholder }
            } else { placeholder }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var placeholder: some View {
        ZStack {
            Color.white.opacity(0.06)
            Image(systemName: "music.note").font(.system(size: size * 0.35)).foregroundStyle(.cyan)
        }
    }
}
