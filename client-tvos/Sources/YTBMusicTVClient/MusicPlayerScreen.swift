import AVKit
import SwiftUI

struct MusicPlayerScreen: View {
    @ObservedObject var viewModel: PlayerViewModel
    let l10n: L10n
    let onBack: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var assets = MusicPresentationAssets()
    @AppStorage("YTBMusicTV.musicLyricsVisible") private var lyricsVisible = false
    @AppStorage("YTBMusicTV.motionArtwork") private var motionArtwork = true
    @AppStorage("YTBMusicTV.crossfadeSeconds") private var crossfadeSeconds = 5.0
    @State private var showingQueue = false
    @State private var videoVisible = false
    @State private var scrubbing = false
    @FocusState private var playFocused: Bool

    private var displayedMedia: MediaItem? { viewModel.pendingMedia ?? viewModel.state?.currentMedia }
    private var lookupID: String { (viewModel.state?.currentMediaId ?? "") + (motionArtwork ? ":motion" : ":still") }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ambientBackground
                if videoVisible && viewModel.currentStreamHasVideo {
                    VideoPlayer(player: viewModel.player)
                        .allowsHitTesting(false)
                        .overlay(Color.black.opacity(0.55))
                }
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Text("NOW PLAYING").font(.system(size: 21, weight: .semibold)).tracking(4)
                            .foregroundStyle(.white.opacity(0.65))
                        Spacer()
                        if viewModel.isPreparingPlayback { ProgressView().tint(.white) }
                        Button(action: onBack) { Label("Library", systemImage: "chevron.left") }
                            .buttonStyle(.bordered)
                    }
                    HStack(alignment: .center, spacing: 100) {
                        artwork(side: min(geometry.size.height * (lyricsVisible ? 0.47 : 0.57), lyricsVisible ? geometry.size.width * 0.35 : geometry.size.width * 0.42))
                        if lyricsVisible {
                            MusicLyricsPane(assets: assets, progress: viewModel.playbackProgress, seek: viewModel.seek)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .transition(.opacity.combined(with: .move(edge: .trailing)))
                        } else {
                            trackDetails
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxHeight: .infinity)
                    if lyricsVisible {
                        HStack {
                            trackDetails
                            Spacer()
                        }
                    }
                    playbackControls
                }
                .padding(.horizontal, 90)
                .padding(.vertical, 55)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .task(id: lookupID) {
            await assets.load(viewModel.state?.currentMedia, animated: motionArtwork && !reduceMotion)
        }
        .onAppear { playFocused = true }
        .onPlayPauseCommand { Task { await viewModel.togglePlayPause() } }
        .onExitCommand {
            if showingQueue { showingQueue = false }
            else if videoVisible { videoVisible = false }
            else { onBack() }
        }
        .onChange(of: viewModel.state?.currentMediaId) { videoVisible = false }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: lyricsVisible)
        .sheet(isPresented: $showingQueue) { queueSheet }
    }

    private var ambientBackground: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || scenePhase != .active)) { context in
            let phase = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate / 16
            GeometryReader { geometry in
                ZStack {
                    LinearGradient(colors: assets.colors + [.black], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Ellipse().fill(assets.colors.first ?? .indigo)
                        .frame(width: geometry.size.width * 0.75, height: geometry.size.height * 1.2)
                        .blur(radius: 130)
                        .offset(x: CGFloat(sin(phase)) * geometry.size.width * 0.18,
                                y: CGFloat(cos(phase * 0.7)) * geometry.size.height * 0.18)
                    Ellipse().fill(assets.colors.last ?? .purple)
                        .frame(width: geometry.size.width * 0.6, height: geometry.size.height)
                        .blur(radius: 150)
                        .offset(x: geometry.size.width * 0.4 + CGFloat(cos(phase)) * 140, y: geometry.size.height * 0.3)
                    Color.black.opacity(0.42)
                }
            }
        }
        .animation(.easeInOut(duration: 1.5), value: assets.colors)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private func artwork(side: CGFloat) -> some View {
        ZStack {
            if let image = assets.artworkImage {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.08))
                Image(systemName: "music.note").font(.system(size: 110)).foregroundStyle(.white.opacity(0.3))
            }
            if motionArtwork && !reduceMotion, let url = assets.motionURL {
                MusicMotionArtwork(url: url, active: scenePhase == .active && viewModel.state?.status == "playing")
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 35, x: 0, y: 22)
        .accessibilityLabel("Album artwork")
    }

    private var trackDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(displayedMedia?.title ?? "Choose a song")
                .font(.system(size: lyricsVisible ? 32 : 52, weight: .bold))
                .lineLimit(lyricsVisible ? 1 : 3)
            Text(displayedMedia?.artist ?? "")
                .font(.system(size: lyricsVisible ? 26 : 36, weight: .medium))
                .foregroundStyle(.white.opacity(0.7)).lineLimit(2)
            if !lyricsVisible, let album = displayedMedia?.album, !album.isEmpty {
                Text(album).font(.system(size: 26)).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
            }
        }
        .foregroundStyle(.white)
    }

    private var playbackControls: some View {
        VStack(spacing: 20) {
            PlayerProgressStrip(progress: viewModel.playbackProgress, l10n: l10n, scrubbing: $scrubbing,
                                onActivity: {}, seek: viewModel.seek)
            HStack(spacing: 24) {
                control("shuffle", label: "Shuffle", selected: viewModel.state?.shuffle == true) {
                    Task { await viewModel.toggleShuffle() }
                }
                control("backward.end.fill", label: "Previous") { Task { await viewModel.previous() } }
                Button { Task { await viewModel.togglePlayPause() } } label: {
                    Image(systemName: viewModel.state?.status == "playing" ? "pause.fill" : "play.fill")
                        .font(.system(size: 32, weight: .semibold)).frame(width: 70, height: 52)
                }
                .buttonStyle(.borderedProminent).tint(.white.opacity(0.25)).focused($playFocused)
                .accessibilityLabel(viewModel.state?.status == "playing" ? "Pause" : "Play")
                .disabled(scrubbing)
                control("forward.end.fill", label: "Next") { Task { await viewModel.next() } }
                control("repeat.1", label: "Repeat song", selected: viewModel.state?.repeatMode == "one") {
                    Task { await viewModel.toggleRepeatOne() }
                }
                Spacer()
                control("quote.bubble", label: "Lyrics", selected: lyricsVisible) { lyricsVisible.toggle() }
                if viewModel.currentStreamHasVideo {
                    control("video", label: "Music video", selected: videoVisible) { videoVisible.toggle() }
                }
                control("list.bullet", label: "Queue") { showingQueue = true }
                Picker("Crossfade", selection: $crossfadeSeconds) {
                    Text("Off").tag(0.0)
                    ForEach(1...12, id: \.self) { Text("\($0) sec").tag(Double($0)) }
                }
                .pickerStyle(.menu).frame(width: 210)
                .accessibilityLabel("Crossfade duration")
            }
            .focusSection()
        }
    }

    private func control(_ icon: String, label: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 25, weight: .semibold)).frame(width: 48, height: 44)
        }
        .buttonStyle(.bordered).tint(selected ? .pink : .white.opacity(0.12))
        .accessibilityLabel(label)
        .accessibilityValue(selected ? "On" : "Off")
    }

    private var queueSheet: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("Playing next").font(.largeTitle.bold())
                Spacer()
                Button("Done") { showingQueue = false }.buttonStyle(.bordered)
            }
            List(viewModel.state?.queue ?? []) { media in
                Button {
                    showingQueue = false
                    Task { _ = await viewModel.play(media, queue: viewModel.state?.queue ?? []) }
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(media.title).font(.title3)
                            Text(media.artist).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if media.id == viewModel.state?.currentMediaId { Image(systemName: "speaker.wave.2.fill") }
                    }
                }
            }
        }
        .padding(60)
    }
}

private struct MusicLyricsPane: View {
    @ObservedObject var assets: MusicPresentationAssets
    @ObservedObject var progress: PlaybackProgress
    let seek: (Int) -> Void
    @State private var followPlayback = true
    private var activeLine: Int? { assets.lyrics.activeLine(at: Double(progress.currentMs) / 1000) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(assets.lyrics.synchronized ? "LYRICS" : "LYRICS · UNSYNCED")
                    .font(.system(size: 17, weight: .semibold)).tracking(3).foregroundStyle(.white.opacity(0.5))
                Spacer()
                if !followPlayback && assets.lyrics.synchronized {
                    Button("Follow song") { followPlayback = true }.buttonStyle(.bordered)
                }
            }
            if assets.lyricsLoading {
                ProgressView("Finding lyrics…").tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if assets.lyrics.lines.isEmpty {
                Text(assets.lyrics.instrumental ? "Instrumental" : "Lyrics aren’t available for this song.")
                    .font(.title2).foregroundStyle(.white.opacity(0.6)).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 26) {
                            ForEach(assets.lyrics.lines) { line in
                                Button {
                                    if let time = line.time { seek(Int(time * 1000)); followPlayback = true }
                                } label: {
                                    Text(line.text.isEmpty ? "•••" : line.text)
                                        .font(.system(size: 44, weight: .bold))
                                        .foregroundStyle(.white.opacity(!assets.lyrics.synchronized || line.id == activeLine ? 1 : 0.3))
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain).id(line.id)
                            }
                        }
                        .padding(.vertical, 100)
                    }
                    .scrollIndicators(.hidden)
                    .onMoveCommand { direction in
                        if direction == .up || direction == .down { followPlayback = false }
                    }
                    .onChange(of: activeLine) { scroll(reader) }
                    .onChange(of: followPlayback) { scroll(reader) }
                    .onChange(of: assets.lyrics) { followPlayback = true; scroll(reader) }
                    .onAppear { scroll(reader) }
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1),
                                                  .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                }
            }
        }
    }

    private func scroll(_ reader: ScrollViewProxy) {
        guard followPlayback, let activeLine else { return }
        withAnimation(.easeInOut(duration: 0.3)) { reader.scrollTo(activeLine, anchor: .center) }
    }
}
