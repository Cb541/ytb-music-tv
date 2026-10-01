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
                    GeometryReader { stage in
                        HStack(alignment: .center, spacing: 80) {
                            VStack(spacing: 22) {
                                artwork(side: lyricsVisible
                                    ? min(geometry.size.height * 0.47, geometry.size.width * 0.34)
                                    : min(geometry.size.height * 0.61, geometry.size.width * 0.44, max(1, stage.size.height - 180)))
                                trackDetails
                            }
                            .frame(maxWidth: .infinity)
                            if lyricsVisible {
                                MusicLyricsPane(assets: assets, progress: viewModel.playbackProgress, seek: viewModel.seek)
                                    .frame(width: geometry.size.width * 0.43, height: geometry.size.height * 0.64)
                                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                            }
                        }
                        .frame(width: stage.size.width, height: stage.size.height)
                    }
                    playbackControls
                }
                .padding(.horizontal, 90)
                .padding(.top, 45)
                .padding(.bottom, 22)
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
        MusicAmbientBackground(assets: assets, paused: reduceMotion || scenePhase != .active || viewModel.state?.status != "playing")
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
        VStack(alignment: lyricsVisible ? .leading : .center, spacing: 8) {
            Text(displayedMedia?.title ?? "Choose a song")
                .font(.system(size: lyricsVisible ? 30 : 34, weight: .bold))
                .lineLimit(2)
            Text(displayedMedia?.artist ?? "")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.white.opacity(0.7)).lineLimit(2)
            if !lyricsVisible, let album = displayedMedia?.album, !album.isEmpty {
                Text(album).font(.system(size: 26)).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
            }
        }
        .multilineTextAlignment(lyricsVisible ? .leading : .center)
        .foregroundStyle(.white)
    }

    private var playbackControls: some View {
        VStack(spacing: 20) {
            HStack(spacing: 24) {
                control("shuffle", label: "Shuffle", selected: viewModel.state?.shuffle == true) {
                    Task { await viewModel.toggleShuffle() }
                }
                control("backward.end.fill", label: "Previous") { Task { await viewModel.previous() } }
                Button { Task { await viewModel.togglePlayPause() } } label: {
                    Image(systemName: viewModel.state?.status == "playing" ? "pause.fill" : "play.fill")
                        .font(.system(size: 32, weight: .semibold)).frame(width: 70, height: 52)
                }
                .buttonStyle(.borderedProminent).tint(assets.accentColor).foregroundStyle(.black).focused($playFocused)
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
                .pickerStyle(.menu).tint(assets.accentColor).frame(width: 210)
                .accessibilityLabel("Crossfade duration")
            }
            .focusSection()
            PlayerProgressStrip(progress: viewModel.playbackProgress, l10n: l10n, scrubbing: $scrubbing,
                                onActivity: {}, seek: viewModel.seek, accentColor: assets.accentColor, showsBackground: false)
        }
    }

    private func control(_ icon: String, label: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 25, weight: .semibold)).frame(width: 48, height: 44)
        }
        .buttonStyle(.bordered).tint(assets.accentColor.opacity(selected ? 0.65 : 0.16))
        .foregroundStyle(assets.accentColor)
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
                    HStack(spacing: 22) {
                        ArtworkThumb(url: media.artworkUrl, size: 80, cornerRadius: 8)
                            .accessibilityHidden(true)
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
    @FocusState private var focusedLine: Int?
    private var activeLine: Int? { assets.lyrics.activeLine(at: Double(progress.currentMs) / 1000) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(assets.lyrics.wordSynchronized ? "LYRICS · WORD SYNC" : assets.lyrics.synchronized ? "LYRICS" : "LYRICS · UNSYNCED")
                    .font(.system(size: 17, weight: .semibold)).tracking(3).foregroundStyle(.white.opacity(0.5))
                Spacer()
                if !followPlayback && assets.lyrics.synchronized {
                    Button("Follow song") { followPlayback = true }.buttonStyle(.bordered).tint(assets.accentColor)
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
                                let isActive = assets.lyrics.synchronized && line.id == activeLine
                                Button {
                                    if let time = line.time { seek(Int(time * 1000)); followPlayback = true }
                                } label: {
                                    lyricText(line, active: isActive)
                                        .font(.system(size: 44, weight: .bold))
                                        .foregroundStyle(isActive ? assets.accentColor : Color.white.opacity(assets.lyrics.synchronized ? 0.38 : 0.95))
                                        .shadow(color: assets.accentColor.opacity(isActive ? 0.7 : 0), radius: 8)
                                        .shadow(color: assets.accentColor.opacity(isActive ? 0.32 : 0), radius: 22)
                                        .animation(.easeOut(duration: 0.25), value: isActive)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(RemoteButtonStyle())
                                .focusEffectDisabled()
                                .focused($focusedLine, equals: line.id)
                                .brightness(focusedLine == line.id ? 0.08 : 0)
                                .id(line.id)
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

    private func lyricText(_ line: MusicLyricLine, active: Bool) -> Text {
        guard active, !line.words.isEmpty else { return Text(line.text.isEmpty ? "•••" : line.text) }
        let seconds = Double(progress.currentMs) / 1000
        return line.words.reduce(Text("")) { text, word in
            text + Text(word.text).foregroundColor(seconds >= word.start ? assets.accentColor : .white.opacity(0.38))
        }
    }

    private func scroll(_ reader: ScrollViewProxy) {
        guard followPlayback, let activeLine else { return }
        withAnimation(.easeInOut(duration: 0.3)) { reader.scrollTo(activeLine, anchor: .center) }
    }
}

// Balanced uses Orchard's 0.82 layer opacity, 0.42 dark tint and 0.34 veil floor.
private struct MusicAmbientBackground: View {
    @ObservedObject var assets: MusicPresentationAssets
    let paused: Bool
    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.035, blue: 0.028)
            ZStack {
                if let image = assets.artworkImage {
                    MusicWarpedArtwork(image: image, active: !paused)
                } else {
                    LinearGradient(colors: assets.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                Color(red: 0.024, green: 0.04, blue: 0.028).opacity(0.42)
                Color(red: 3.0 / 255, green: 7.0 / 255, blue: 4.0 / 255).opacity(assets.backgroundVeil)
            }
            .opacity(0.82)
        }
        .clipped()
    }
}
