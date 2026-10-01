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
    @FocusState private var queueCloseFocused: Bool
    @FocusState private var focusedQueueID: String?
    @State private var videoVisible = false
    @State private var scrubbing = false
    @FocusState private var focusedControl: String?
    @State private var controlHighlightVisible = true
    @State private var controlActivityRevision = 0

    private var displayedMedia: MediaItem? { viewModel.pendingMedia ?? viewModel.state?.currentMedia }
    private var musicVideoActive: Bool { videoVisible && viewModel.currentStreamHasVideo }
    private var lookupID: String { (viewModel.state?.currentMediaId ?? "") + (motionArtwork ? ":motion" : ":still") }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ambientBackground
                if musicVideoActive {
                    VideoPlayer(player: viewModel.player)
                        .allowsHitTesting(false)
                        .overlay(Color.black.opacity(0.55))
                }
                VStack(alignment: .leading, spacing: 24) {
                    Text(displayedMedia?.artist ?? "")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, -30)
                    GeometryReader { stage in
                        HStack(alignment: .center, spacing: 80) {
                            VStack(alignment: lyricsVisible ? .leading : .center, spacing: 34) {
                                if musicVideoActive {
                                    Spacer(minLength: 0)
                                } else {
                                    artwork(side: lyricsVisible
                                        ? min(geometry.size.height * 0.53, geometry.size.width * 0.36, max(1, stage.size.height - 145))
                                        : min(geometry.size.height * 0.61, geometry.size.width * 0.44, max(1, stage.size.height - 145)))
                                }
                                trackDetails
                            }
                            .frame(maxWidth: .infinity, maxHeight: musicVideoActive ? .infinity : nil, alignment: lyricsVisible ? .leading : .center)
                            .padding(.leading, lyricsVisible ? 40 : 0)
                            .offset(y: musicVideoActive ? 0 : (lyricsVisible ? 24 : 19))
                            if lyricsVisible {
                                MusicLyricsPane(assets: assets, progress: viewModel.playbackProgress, seek: viewModel.seek, onClose: closeLyrics)
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
                .disabled(showingQueue)
                .accessibilityHidden(showingQueue)
                if showingQueue {
                    Color.black.opacity(0.45).ignoresSafeArea()
                        .onTapGesture { closeQueue() }
                    queueSheet
                        .frame(width: min(geometry.size.width * 0.78, 1500), height: geometry.size.height * 0.84)
                        .background(RoundedRectangle(cornerRadius: 24).fill(Color(red: 0.025, green: 0.035, blue: 0.028).opacity(0.97)))
                        .shadow(color: .black.opacity(0.4), radius: 30)
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: showingQueue)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .task(id: lookupID) {
            await assets.load(viewModel.state?.currentMedia, animated: motionArtwork && !reduceMotion)
        }
        .onAppear { focusedControl = "PlayPause"; noteControlActivity() }
        .onChange(of: focusedControl) { noteControlActivity() }
        .onChange(of: crossfadeSeconds) { noteControlActivity() }
        .onMoveCommand { _ in noteControlActivity() }
        .task(id: controlActivityRevision) {
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { controlHighlightVisible = false }
        }
        .onPlayPauseCommand { noteControlActivity(); Task { await viewModel.togglePlayPause() } }
        .onExitCommand {
            if showingQueue { closeQueue() }
            else if videoVisible { videoVisible = false }
            else if lyricsVisible { closeLyrics() }
            else { onBack() }
        }
        .onChange(of: viewModel.state?.currentMediaId) { videoVisible = false }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: lyricsVisible)
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
        .overlay(alignment: .bottomTrailing) {
            if viewModel.isPreparingPlayback {
                ProgressView().tint(.white).padding(18)
                    .accessibilityLabel("Preparing playback")
            }
        }
        .accessibilityLabel("Album artwork")
    }

    private var trackDetails: some View {
        VStack(alignment: lyricsVisible ? .leading : .center, spacing: 8) {
            Text(displayedMedia.map { MusicLookup.songTitle($0.title, artist: $0.artist) } ?? "Choose a song")
                .font(.system(size: lyricsVisible ? 30 : 34, weight: .bold))
                .lineLimit(2)
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
                HStack(spacing: 24) {
                    control("shuffle", label: "Shuffle", selected: viewModel.state?.shuffle == true) {
                        Task { await viewModel.toggleShuffle() }
                    }
                    control("backward.end.fill", label: "Previous") { Task { await viewModel.previous() } }
                    Button { noteControlActivity(); Task { await viewModel.togglePlayPause() } } label: {
                        Image(systemName: viewModel.state?.status == "playing" ? "pause.fill" : "play.fill")
                            .font(.system(size: 32, weight: .semibold)).frame(width: 70, height: 52)
                    }
                    .buttonStyle(MusicControlButtonStyle(accent: assets.accentColor,
                        highlighted: controlHighlightVisible && focusedControl == "PlayPause"))
                    .foregroundStyle(assets.accentColor)
                    .focusEffectDisabled().focused($focusedControl, equals: "PlayPause")
                    .accessibilityLabel(viewModel.state?.status == "playing" ? "Pause" : "Play")
                    .disabled(scrubbing)
                    control("forward.end.fill", label: "Next") { Task { await viewModel.next() } }
                    control("repeat.1", label: "Repeat song", selected: viewModel.state?.repeatMode == "one") {
                        Task { await viewModel.toggleRepeatOne() }
                    }
                }
                .padding(.leading, -55)
                Spacer()
                HStack(spacing: 16) {
                    control("quote.bubble", label: "Lyrics", selected: lyricsVisible, uniformBackground: true, compact: true) { lyricsVisible.toggle() }
                    if viewModel.currentStreamHasVideo {
                        control("video", label: "Music video", selected: videoVisible, compact: true) { videoVisible.toggle() }
                    }
                    control("list.bullet", label: "Queue", compact: true) { showingQueue = true }
                    Menu {
                        Picker("Crossfade", selection: $crossfadeSeconds) {
                            Text("Off").tag(0.0)
                            ForEach(1...12, id: \.self) { Text("\($0) sec").tag(Double($0)) }
                        }
                    } label: {
                        Image(systemName: "waveform")
                            .font(.system(size: 25, weight: .semibold))
                            .frame(width: 48, height: 44)
                    }
                    .buttonStyle(MusicControlButtonStyle(accent: assets.accentColor,
                        highlighted: controlHighlightVisible && focusedControl == "Crossfade"))
                    .tint(assets.accentColor).foregroundStyle(assets.accentColor)
                    .fixedSize(horizontal: true, vertical: false)
                    .scaleEffect(0.9)
                    .focusEffectDisabled().focused($focusedControl, equals: "Crossfade")
                    .accessibilityLabel("Crossfade duration")
                    .accessibilityValue(crossfadeSeconds == 0 ? "Off" : "\(Int(crossfadeSeconds)) seconds")
                }
                .padding(.trailing, -45)
                .offset(y: 5)
            }
            .focusSection()
            PlayerProgressStrip(progress: viewModel.playbackProgress, l10n: l10n, scrubbing: $scrubbing,
                                onActivity: noteControlActivity, seek: viewModel.seek, accentColor: assets.accentColor, showsBackground: false)
                .padding(.horizontal, -60)
        }
    }

    private func control(_ icon: String, label: String, selected: Bool = false, uniformBackground: Bool = false, compact: Bool = false, action: @escaping () -> Void) -> some View {
        Button { noteControlActivity(); action() } label: {
            Image(systemName: icon).font(.system(size: 25, weight: .semibold)).frame(width: 48, height: 44)
        }
        .buttonStyle(MusicControlButtonStyle(accent: assets.accentColor,
            highlighted: controlHighlightVisible && focusedControl == label,
            backgroundOpacity: selected && !uniformBackground ? 0.20 : 0.08))
        .scaleEffect(compact ? 0.9 : 1)
        .focusEffectDisabled().focused($focusedControl, equals: label)
        .foregroundStyle(assets.accentColor)
        .accessibilityLabel(label)
        .accessibilityValue(selected ? "On" : "Off")
    }

    private func closeLyrics() {
        lyricsVisible = false
        focusedControl = "Lyrics"
        noteControlActivity()
    }

    private func noteControlActivity() {
        controlHighlightVisible = true
        controlActivityRevision &+= 1
    }

    private func closeQueue() {
        showingQueue = false
        focusedControl = "Queue"
        noteControlActivity()
    }

    private var queueSheet: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("Playing next").font(.largeTitle.bold())
                Spacer()
                Button("Done") { closeQueue() }.buttonStyle(.bordered)
                    .focused($queueCloseFocused)
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(viewModel.state?.queue ?? []) { media in
                        Button {
                            closeQueue()
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
                        .buttonStyle(MusicQueueButtonStyle(accent: assets.accentColor, highlighted: focusedQueueID == media.id))
                        .focusEffectDisabled()
                        .focused($focusedQueueID, equals: media.id)
                    }
                    if viewModel.isLoadingPlaybackQueue {
                        ProgressView("Loading the rest of the playlist…").padding()
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(60)
        .foregroundStyle(.white)
        .onAppear { queueCloseFocused = true }
    }
}

private struct MusicLyricsPane: View {
    @ObservedObject var assets: MusicPresentationAssets
    @ObservedObject var progress: PlaybackProgress
    let seek: (Int) -> Void
    let onClose: () -> Void
    @State private var browseRevision = 0
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
                    Button("Follow song") { resumeFollowing() }.buttonStyle(.bordered).tint(assets.accentColor)
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
                                let isPast = assets.lyrics.synchronized && activeLine.map { line.id < $0 } == true
                                Button {
                                    if let time = line.time { seek(Int(time * 1000)); resumeFollowing() }
                                } label: {
                                    lyricText(line, active: isActive)
                                        .font(.system(size: 44, weight: .bold))
                                        .foregroundStyle(isActive ? assets.accentColor : Color.white.opacity(assets.lyrics.synchronized ? 0.38 : 0.95))
                                        .shadow(color: assets.accentColor.opacity(isActive ? 0.7 : 0), radius: 8)
                                        .shadow(color: assets.accentColor.opacity(isActive ? 0.32 : 0), radius: 22)
                                        .blur(radius: isPast ? 3 : 0)
                                        .animation(.easeOut(duration: 0.25), value: isPast)
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
                        if direction == .left { onClose() }
                        else if direction == .up || direction == .down { browseLyrics() }
                    }
                    .onChange(of: focusedLine) {
                        if let focusedLine, focusedLine != activeLine { browseLyrics() }
                    }
                    .task(id: browseRevision) {
                        guard !followPlayback else { return }
                        do { try await Task.sleep(for: .seconds(3)) }
                        catch { return }
                        guard !Task.isCancelled else { return }
                        resumeFollowing()
                        scroll(reader)
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

    private func browseLyrics() {
        followPlayback = false
        browseRevision &+= 1
    }

    private func resumeFollowing() {
        followPlayback = true
        browseRevision &+= 1
    }

    private func lyricText(_ line: MusicLyricLine, active: Bool) -> Text {
        guard active, !line.words.isEmpty else { return Text(line.text.isEmpty ? "•••" : line.text) }
        let seconds = Double(progress.currentMs) / 1000
        return line.words.reduce(Text("")) { text, word in
            text + Text(word.text).foregroundColor(wordColor(progress: word.highlightProgress(at: seconds)))
        }
    }

    private func wordColor(progress: Double) -> Color {
        var red: CGFloat = 1, green: CGFloat = 1, blue: CGFloat = 1, alpha: CGFloat = 1
        UIColor(assets.accentColor).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return Color(red: 1 + (Double(red) - 1) * progress,
                     green: 1 + (Double(green) - 1) * progress,
                     blue: 1 + (Double(blue) - 1) * progress,
                     opacity: 0.38 + (Double(alpha) - 0.38) * progress)
    }

    private func scroll(_ reader: ScrollViewProxy) {
        guard followPlayback, let activeLine else { return }
        // tvOS keeps a focused row in view; move that focus with the song rather
        // than allowing an old row to pull automatic scrolling back.
        if focusedLine != nil { focusedLine = activeLine }
        withAnimation(.easeInOut(duration: 0.45)) { reader.scrollTo(activeLine, anchor: .center) }
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
                if let image = assets.backgroundImage {
                    MusicWarpedArtwork(image: image, active: !paused)
                } else {
                    LinearGradient(colors: assets.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                Color(red: 0.024, green: 0.04, blue: 0.028).opacity(0.42)
                Color(red: 3.0 / 255, green: 7.0 / 255, blue: 4.0 / 255).opacity(assets.backgroundVeil)
                    .animation(.easeInOut(duration: 1.2), value: assets.backgroundVeil)
            }
            .opacity(0.82)
        }
        .clipped()
    }
}

// Focus remains on the button; only its visible emphasis sleeps after inactivity.
private struct MusicControlButtonStyle: ButtonStyle {
    let accent: Color
    let highlighted: Bool
    var backgroundOpacity = 0.08

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(accent.opacity(backgroundOpacity + (highlighted ? 0.10 : 0))))
            .shadow(color: accent.opacity(highlighted ? 0.3 : 0), radius: 12)
            .scaleEffect(configuration.isPressed ? 0.97 : highlighted ? 1.04 : 1)
            .animation(.easeOut(duration: 0.2), value: highlighted)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct MusicQueueButtonStyle: ButtonStyle {
    var accent: Color
    var highlighted: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(accent.opacity(highlighted ? 0.20 : 0.04)))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
