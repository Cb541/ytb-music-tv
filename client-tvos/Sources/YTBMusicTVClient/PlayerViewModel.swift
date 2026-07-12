import AVKit
import Foundation
import MediaPlayer
import UIKit

private typealias ResolvedPlaybackMedia = (
    media: MediaItem,
    url: URL,
    fallbackURL: URL?,
    adaptiveVideoURL: URL?,
    adaptiveAudioURL: URL?,
    hasVideo: Bool,
    mimeType: String?
)

private struct NextPlaybackCache {
    let requestID: UUID
    let mediaID: String
    let resolved: ResolvedPlaybackMedia
    let asset: AVURLAsset?
}

private struct PrefetchedPlaybackMedia {
    let resolved: ResolvedPlaybackMedia
    let asset: AVURLAsset?
}

@MainActor
final class PlaybackProgress: ObservableObject {
    @Published var currentMs = 0
    @Published var durationMs = 0
}

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var state: PlayerState?
    @Published var searchSections: [MediaSection] = []
    @Published var homeSections: [MediaSection] = []
    @Published var exploreSections: [MediaSection] = []
    @Published var librarySections: [MediaSection] = []
    @Published var config: ServerConfig?
    @Published var isConnected = false
    @Published var isAssociated = false
    @Published var isAuthenticated = false
    @Published var isConnecting = false
    @Published var connectedServerID: String?
    @Published var connectedServerName: String?
    @Published var isLoadingHome = false
    @Published var isSearching = false
    @Published var isPreparingPlayback = false
    @Published private(set) var pendingMedia: MediaItem?
    @Published var currentStreamHasVideo = false
    @Published private(set) var isUpdatingRating = false
    @Published var errorMessage: String?

    let player = AVPlayer()
    let playbackProgress = PlaybackProgress()

    private var client: APIClient?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var timeControlObserver: NSKeyValueObservation?
    private var itemStatusObserver: NSKeyValueObservation?
    private var fallbackPlaybackURLs: [URL] = []
    private var audioFallbackAttempted = false
    private var playbackRequestID = UUID()
    private var ratingRequestID = UUID()
    private var playbackHistory: [String] = []
    private var nextPlaybackTask: Task<Void, Never>?
    private var nextPlaybackCandidate: MediaItem?
    private var nextPlaybackCache: NextPlaybackCache?
    private var configUpdateTask: Task<Void, Never>?
    private var configRevision = 0
    private var connectionRevision = 0
    private var homeLoadRevision = 0
    private var searchRevision = 0
    private var homeNavigationHistory: [[MediaSection]] = []
    private var searchNavigationHistory: [[MediaSection]] = []
    private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    private let artworkCache = NSCache<NSURL, UIImage>()
    private var artworkLoadTask: Task<Void, Never>?
    private var nowPlayingArtworkURL: URL?
    private var nowPlayingArtwork: MPMediaItemArtwork?

    private var playbackTimeMs: Int {
        get { playbackProgress.currentMs }
        set { playbackProgress.currentMs = newValue }
    }

    private var playbackDurationMs: Int {
        get { playbackProgress.durationMs }
        set { playbackProgress.durationMs = newValue }
    }

    init() {
        player.volume = 1
        player.automaticallyWaitsToMinimizeStalling = true
        observeTimeControlStatus()
        configureRemoteCommands()
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        timeControlObserver?.invalidate()
        itemStatusObserver?.invalidate()
        nextPlaybackTask?.cancel()
        configUpdateTask?.cancel()
        artworkLoadTask?.cancel()
        for (command, target) in remoteCommandTargets {
            command.removeTarget(target)
        }
    }

    // MARK: - Data source

    func connect(to baseURL: URL, accessToken: String? = nil) async {
        connectionRevision &+= 1
        let revision = connectionRevision
        homeLoadRevision &+= 1
        searchRevision &+= 1
        ratingRequestID = UUID()
        isLoadingHome = false
        isSearching = false
        isUpdatingRating = false
        if client?.baseURL != baseURL {
            configUpdateTask?.cancel()
            configRevision &+= 1
        }
        isConnecting = true
        defer {
            if revision == connectionRevision {
                isConnecting = false
            }
        }

        let nextClient = APIClient(baseURL: baseURL, accessToken: accessToken)
        do {
            let connection = try await nextClient.health()
            guard connection.ok else {
                throw APIError.invalidResponse
            }
            let nextConfig = try? await nextClient.config()
            guard revision == connectionRevision else { return }
            client = nextClient
            invalidateNextPlaybackCache()
            isConnected = true
            isAssociated = connection.associated
            isAuthenticated = connection.authenticated
            connectedServerID = connection.serverId
            connectedServerName = connection.serverName
            config = nextConfig
            errorMessage = nil
            await loadHome()
        } catch {
            guard revision == connectionRevision else { return }
            client = nil
            invalidateNextPlaybackCache()
            isConnected = false
            isAssociated = false
            isAuthenticated = false
            connectedServerID = nil
            connectedServerName = nil
            config = nil
            errorMessage = error.localizedDescription
        }
    }

    func associate(deviceCode: String) async -> PairingResult? {
        guard let client else { return nil }
        let code = deviceCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return nil }

        do {
            let result = try await client.pair(deviceCode: code)
            let associatedClient = APIClient(baseURL: client.baseURL, accessToken: result.token)
            let connection = try await associatedClient.health()
            self.client = associatedClient
            isAssociated = connection.associated
            isAuthenticated = connection.authenticated
            errorMessage = nil
            return result
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func updateConfig(
        debounce: Duration = .milliseconds(250),
        _ update: (inout ServerConfig) -> Void
    ) {
        guard var nextConfig = config else { return }
        update(&nextConfig)
        guard nextConfig != config else { return }

        config = nextConfig
        configRevision &+= 1
        let revision = configRevision
        configUpdateTask?.cancel()
        configUpdateTask = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
                guard !Task.isCancelled, let self, let client = self.client else { return }
                let saved = try await client.patchConfig(nextConfig)
                guard !Task.isCancelled, revision == self.configRevision else { return }
                self.config = saved
                self.errorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self, revision == self.configRevision else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func search(_ query: String) async {
        searchRevision &+= 1
        let revision = searchRevision
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, !trimmedQuery.isEmpty else {
            searchSections = []
            searchNavigationHistory.removeAll()
            isSearching = false
            return
        }

        isSearching = true
        defer {
            if revision == searchRevision {
                isSearching = false
            }
        }
        do {
            let sections = try await client.search(query: trimmedQuery).sections
            guard revision == searchRevision else { return }
            searchSections = sections
            searchNavigationHistory.removeAll()
            errorMessage = nil
        } catch {
            guard revision == searchRevision else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadExplore() async {
        guard let client else { return }
        do {
            exploreSections = try await client.explore().sections
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadHome() async {
        guard let client else { return }
        homeLoadRevision &+= 1
        let revision = homeLoadRevision
        isLoadingHome = true
        defer {
            if revision == homeLoadRevision {
                isLoadingHome = false
            }
        }

        do {
            async let libraryResponse = client.library()
            async let homeResponse = client.home()
            async let exploreResponse = client.explore()

            let library = try await libraryResponse
            let home = try await homeResponse
            let explore = try await exploreResponse

            guard revision == homeLoadRevision else { return }
            librarySections = library.sections
            exploreSections = explore.sections
            homeSections = composeHomeSections(
                library: library.sections,
                home: home.sections,
                explore: explore.sections
            )
            homeNavigationHistory.removeAll()

            errorMessage = nil
        } catch {
            guard revision == homeLoadRevision else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadLibrary() async {
        guard let client else { return }
        do {
            let response = try await client.library()
            librarySections = response.sections
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Client-owned playback

    @discardableResult
    func play(_ media: MediaItem, queue: [MediaItem] = []) async -> Bool {
        await startPlayback(
            media,
            replacingQueue: queue.isEmpty ? nil : queue.filter(\.isPlayable),
            recordHistory: true
        )
    }

    func selectSearch(_ media: MediaItem, queue: [MediaItem] = []) async -> Bool {
        await select(media, queue: queue) { [weak self] sections in
            guard let self else { return }
            if !searchSections.isEmpty {
                searchNavigationHistory.append(searchSections)
            }
            searchSections = sections
        }
    }

    func selectHome(_ media: MediaItem, queue: [MediaItem] = []) async -> Bool {
        await select(media, queue: queue) { [weak self] sections in
            guard let self else { return }
            if !homeSections.isEmpty {
                homeNavigationHistory.append(homeSections)
            }
            homeSections = sections
        }
    }

    func selectExplore(_ media: MediaItem, queue: [MediaItem] = []) async -> Bool {
        await select(media, queue: queue) { [weak self] sections in
            self?.exploreSections = sections
        }
    }

    func selectLibrary(_ media: MediaItem, queue: [MediaItem] = []) async -> Bool {
        await select(media, queue: queue) { [weak self] sections in
            self?.librarySections = sections
        }
    }

    func togglePlayPause() async {
        guard var nextState = state else { return }

        if nextState.status == "failed", let media = nextState.currentMedia {
            _ = await startPlayback(
                media,
                replacingQueue: nextState.queue,
                recordHistory: false
            )
            return
        }

        guard player.currentItem != nil else { return }

        if nextState.status == "playing" {
            player.pause()
            nextState.status = "paused"
            isPreparingPlayback = false
        } else {
            if playbackDurationMs > 0, playbackTimeMs >= playbackDurationMs - 500 {
                seek(to: 0)
            }
            player.volume = 1
            player.playImmediately(atRate: 1)
            nextState.status = "playing"
            isPreparingPlayback = player.timeControlStatus != .playing
        }
        state = nextState
        updateNowPlayingInfo()
    }

    func next() async {
        guard let state else { return }

        if state.repeatMode == "one" {
            seek(to: 0)
            player.volume = 1
            player.playImmediately(atRate: 1)
            updateStatus("playing")
            return
        }

        guard let nextItem = nextPlaybackItem(for: state) else {
            invalidateNextPlaybackCache()
            player.pause()
            updateStatus("ended")
            return
        }
        _ = await startPlayback(
            nextItem,
            replacingQueue: nil,
            recordHistory: true,
            prefetched: cachedPrefetchedPlayback(for: nextItem)
        )
    }

    func previous() async {
        if playbackTimeMs > 3000 {
            seek(to: 0)
            return
        }

        guard let state else { return }
        let previousID = playbackHistory.popLast()
        let previousItem = previousID.flatMap { id in state.queue.last(where: { $0.id == id }) }
            ?? previousQueueItem(in: state.queue, currentID: state.currentMediaId)

        guard let previousItem else {
            seek(to: 0)
            return
        }
        _ = await startPlayback(previousItem, replacingQueue: nil, recordHistory: false)
    }

    func toggleShuffle() async {
        guard var nextState = state else { return }
        nextState.shuffle.toggle()
        state = nextState
        scheduleNextPlaybackPrecache()
    }

    func toggleRepeatOne() async {
        guard var nextState = state else { return }
        nextState.repeatMode = nextState.repeatMode == "one" ? "off" : "one"
        state = nextState
        scheduleNextPlaybackPrecache()
    }

    func likeCurrent() async {
        await setCurrentRating(state?.currentMedia?.likeStatus == "LIKE" ? "INDIFFERENT" : "LIKE")
    }

    func dislikeCurrent() async {
        await setCurrentRating(state?.currentMedia?.likeStatus == "DISLIKE" ? "INDIFFERENT" : "DISLIKE")
    }

    func seek(to milliseconds: Int) {
        let upperBound = playbackDurationMs > 0 ? playbackDurationMs : milliseconds
        let targetMs = min(max(0, milliseconds), upperBound)
        playbackTimeMs = targetMs
        if var nextState = state {
            nextState.currentTimeMs = targetMs
            state = nextState
        }
        player.seek(
            to: CMTime(seconds: Double(targetMs) / 1000, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        updateNowPlayingInfo()
    }

    func skip(by seconds: Double) {
        seek(to: playbackTimeMs + Int(seconds * 1000))
    }

    func clearError() {
        errorMessage = nil
    }

    func cancelPendingPlayback() {
        guard pendingMedia != nil else { return }
        playbackRequestID = UUID()
        pendingMedia = nil
        isPreparingPlayback = false
    }

    @discardableResult
    func navigateBackHome() -> Bool {
        guard let previous = homeNavigationHistory.popLast() else { return false }
        homeSections = previous
        return true
    }

    @discardableResult
    func navigateBackSearch() -> Bool {
        guard let previous = searchNavigationHistory.popLast() else { return false }
        searchSections = previous
        return true
    }

    func reportError(_ message: String) {
        errorMessage = message
    }

    private func select(
        _ media: MediaItem,
        queue: [MediaItem],
        assignSections: @escaping ([MediaSection]) -> Void
    ) async -> Bool {
        guard let client else {
            errorMessage = "Connect to the YTB Music TV server first."
            return false
        }
        if media.isPlayable {
            return await play(media, queue: queue)
        }

        do {
            let response = try await client.browse(media: media)
            assignSections(response.sections)
            errorMessage = response.sections.isEmpty
                ? response.message ?? "No playable items found."
                : nil
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func startPlayback(
        _ media: MediaItem,
        replacingQueue: [MediaItem]?,
        recordHistory: Bool,
        prefetched: PrefetchedPlaybackMedia? = nil
    ) async -> Bool {
        guard let client else {
            errorMessage = "Connect to the YTB Music TV server before starting playback."
            return false
        }

        let requestID = UUID()
        playbackRequestID = requestID
        invalidateNextPlaybackCache()
        pendingMedia = media
        isPreparingPlayback = true
        errorMessage = nil
        fallbackPlaybackURLs.removeAll()
        audioFallbackAttempted = false

        do {
            let resolved: ResolvedPlaybackMedia
            let prefetchedAsset: AVURLAsset?
            if let prefetched, prefetched.resolved.media.id == media.id {
                resolved = prefetched.resolved
                prefetchedAsset = prefetched.asset
            } else {
                resolved = try await resolvePlaybackMedia(media, client: client)
                prefetchedAsset = nil
            }
            guard playbackRequestID == requestID else { return false }

            let adaptiveItem: AVPlayerItem?
            if let videoURL = resolved.adaptiveVideoURL, let audioURL = resolved.adaptiveAudioURL {
                adaptiveItem = try? await makeAdaptivePlayerItem(videoURL: videoURL, audioURL: audioURL)
            } else {
                adaptiveItem = nil
            }
            guard playbackRequestID == requestID else { return false }

            let oldState = state
            if recordHistory, let oldID = oldState?.currentMediaId, oldID != resolved.media.id {
                playbackHistory.append(oldID)
            }

            var nextQueue = replacingQueue ?? oldState?.queue ?? []
            if !nextQueue.contains(where: { $0.id == resolved.media.id }) {
                nextQueue.insert(media, at: 0)
            }
            if let index = nextQueue.firstIndex(where: { $0.id == resolved.media.id }) {
                nextQueue[index] = resolved.media
            }

            playbackTimeMs = 0
            playbackDurationMs = max(0, resolved.media.durationMs)
            currentStreamHasVideo = resolved.hasVideo
            state = PlayerState(
                status: "playing",
                currentTimeMs: 0,
                currentMediaId: resolved.media.id,
                currentMedia: resolved.media,
                queue: nextQueue,
                shuffle: oldState?.shuffle ?? false,
                repeatMode: oldState?.repeatMode ?? "off"
            )
            pendingMedia = nil

            if let adaptiveItem {
                configurePlayer(
                    item: adaptiveItem,
                    fallbackURLs: [resolved.url] + (resolved.fallbackURL.map { [$0] } ?? [])
                )
            } else {
                configurePlayer(
                    url: resolved.url,
                    fallbackURLs: resolved.fallbackURL.map { [$0] } ?? [],
                    prefetchedAsset: prefetchedAsset
                )
            }
            updateNowPlayingInfo()
            scheduleNextPlaybackPrecache()
            errorMessage = nil
            return true
        } catch {
            guard playbackRequestID == requestID else { return false }
            pendingMedia = nil
            isPreparingPlayback = false
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func resolvePlaybackMedia(
        _ media: MediaItem,
        client: APIClient
    ) async throws -> ResolvedPlaybackMedia {
        if let videoID = media.videoId {
            let resolved = try await client.resolve(mediaId: videoID)
            var merged = merge(media, with: resolved.media)
            let playbackURLs = playbackURLs(for: resolved, streamMode: config?.playback.streamMode)
            let adaptiveURLs = adaptivePlaybackURLs(for: resolved, streamMode: config?.playback.streamMode)
            let playbackURL = playbackURLs.primary
            merged.playbackUrl = playbackURL
            return (
                merged,
                playbackURL,
                playbackURLs.fallback,
                adaptiveURLs?.video,
                adaptiveURLs?.audio,
                resolved.hasVideo == true,
                resolved.mimeType
            )
        }

        if let playbackURL = media.streamUrl ?? media.playbackUrl {
            var playable = media
            playable.playbackUrl = playbackURL
            return (playable, playbackURL, nil, nil, nil, config?.playback.preferVideo == true, nil)
        }

        throw PlaybackError.notPlayable
    }

    private func configurePlayer(
        url: URL,
        fallbackURLs: [URL],
        prefetchedAsset: AVURLAsset? = nil
    ) {
        fallbackPlaybackURLs = fallbackURLs
        if let prefetchedAsset, prefetchedAsset.url == url {
            replacePlayerItem(asset: prefetchedAsset)
        } else {
            replacePlayerItem(url: url)
        }
    }

    private func configurePlayer(item: AVPlayerItem, fallbackURLs: [URL]) {
        var seen = Set<URL>()
        fallbackPlaybackURLs = fallbackURLs.filter { seen.insert($0).inserted }
        replacePlayerItem(item: item)
    }

    private func makeAdaptivePlayerItem(videoURL: URL, audioURL: URL) async throws -> AVPlayerItem {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        async let videoTracks = videoAsset.loadTracks(withMediaType: .video)
        async let audioTracks = audioAsset.loadTracks(withMediaType: .audio)
        guard let videoTrack = try await videoTracks.first,
              let audioTrack = try await audioTracks.first else {
            throw PlaybackError.notPlayable
        }

        async let videoRange = videoTrack.load(.timeRange)
        async let audioRange = audioTrack.load(.timeRange)
        let sourceVideoRange = try await videoRange
        let sourceAudioRange = try await audioRange
        let duration = CMTimeMinimum(sourceVideoRange.duration, sourceAudioRange.duration)
        guard duration.isNumeric, CMTimeCompare(duration, .zero) > 0 else {
            throw PlaybackError.notPlayable
        }

        let composition = AVMutableComposition()
        guard let compositionVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ), let compositionAudio = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw PlaybackError.notPlayable
        }

        try compositionVideo.insertTimeRange(
            CMTimeRange(start: sourceVideoRange.start, duration: duration),
            of: videoTrack,
            at: .zero
        )
        try compositionAudio.insertTimeRange(
            CMTimeRange(start: sourceAudioRange.start, duration: duration),
            of: audioTrack,
            at: .zero
        )
        return AVPlayerItem(asset: composition)
    }

    private func replacePlayerItem(url: URL) {
        replacePlayerItem(item: AVPlayerItem(url: url))
    }

    private func replacePlayerItem(asset: AVURLAsset) {
        replacePlayerItem(item: AVPlayerItem(asset: asset))
    }

    private func replacePlayerItem(item: AVPlayerItem) {
        player.pause()
        player.replaceCurrentItem(with: item)
        installStatusObserver(for: item)
        installEndObserver(for: item)
        installTimeObserverIfNeeded()
        player.volume = 1
        player.playImmediately(atRate: 1)
    }

    private func observeTimeControlStatus() {
        timeControlObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                switch player.timeControlStatus {
                case .playing:
                    self.isPreparingPlayback = false
                case .waitingToPlayAtSpecifiedRate:
                    self.isPreparingPlayback = self.state?.status == "playing"
                case .paused:
                    if self.state?.status != "playing" {
                        self.isPreparingPlayback = false
                    }
                @unknown default:
                    break
                }
            }
        }
    }

    private func installTimeObserverIfNeeded() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let seconds = CMTimeGetSeconds(time)
                guard seconds.isFinite else { return }

                let currentMs = max(0, Int(seconds * 1000))
                self.playbackTimeMs = currentMs

                let durationSeconds = CMTimeGetSeconds(self.player.currentItem?.duration ?? .invalid)
                if durationSeconds.isFinite, durationSeconds > 0 {
                    self.playbackDurationMs = Int(durationSeconds * 1000)
                }
                self.updateNowPlayingInfo()
            }
        }
    }

    private func installEndObserver(for item: AVPlayerItem) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.next()
            }
        }
    }

    private func installStatusObserver(for item: AVPlayerItem) {
        itemStatusObserver?.invalidate()
        itemStatusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    let durationSeconds = CMTimeGetSeconds(item.duration)
                    if durationSeconds.isFinite, durationSeconds > 0 {
                        self.playbackDurationMs = Int(durationSeconds * 1000)
                    }
                    self.player.volume = 1
                case .failed:
                    if self.retryFallbackPlayback(failedItem: item) {
                        return
                    }
                    let reason = item.error?.localizedDescription
                        ?? self.player.error?.localizedDescription
                        ?? "Unknown playback error."
                    if self.beginAudioFallback(failedItem: item) {
                        return
                    }
                    self.reportPlaybackFailure(reason)
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    private func retryFallbackPlayback(failedItem: AVPlayerItem) -> Bool {
        guard player.currentItem === failedItem, !fallbackPlaybackURLs.isEmpty else { return false }
        let fallbackPlaybackURL = fallbackPlaybackURLs.removeFirst()
        isPreparingPlayback = true
        replacePlayerItem(url: fallbackPlaybackURL)
        return true
    }

    private func beginAudioFallback(failedItem: AVPlayerItem) -> Bool {
        guard player.currentItem === failedItem,
              !audioFallbackAttempted,
              let client,
              let currentMedia = state?.currentMedia,
              let videoID = currentMedia.videoId else { return false }

        audioFallbackAttempted = true
        isPreparingPlayback = true
        let requestID = playbackRequestID

        Task { [weak self] in
            guard let self else { return }
            do {
                let resolved = try await client.resolve(mediaId: videoID, preferVideo: false)
                guard self.playbackRequestID == requestID,
                      self.state?.currentMediaId == currentMedia.id else { return }

                var merged = merge(currentMedia, with: resolved.media)
                let playbackURLs = self.playbackURLs(for: resolved, streamMode: self.config?.playback.streamMode)
                merged.playbackUrl = playbackURLs.primary
                if var nextState = self.state {
                    nextState.currentMedia = merged
                    if let index = nextState.queue.firstIndex(where: { $0.id == merged.id }) {
                        nextState.queue[index] = merged
                    }
                    self.state = nextState
                }

                self.currentStreamHasVideo = false
                self.configurePlayer(
                    url: playbackURLs.primary,
                    fallbackURLs: playbackURLs.fallback.map { [$0] } ?? []
                )
            } catch {
                guard self.playbackRequestID == requestID else { return }
                self.reportPlaybackFailure(error.localizedDescription)
            }
        }
        return true
    }

    private func playbackURLs(
        for resolved: ResolvedStream,
        streamMode: String?
    ) -> (primary: URL, fallback: URL?) {
        let directURL = resolved.directUrl
        guard let proxyURL = resolved.proxyUrl, proxyURL != directURL else {
            return (directURL, nil)
        }

        if streamMode?.lowercased() == "direct" {
            return (directURL, proxyURL)
        }

        return (proxyURL, directURL)
    }

    private func adaptivePlaybackURLs(
        for resolved: ResolvedStream,
        streamMode: String?
    ) -> (video: URL, audio: URL)? {
        guard let directVideo = resolved.adaptiveVideoUrl,
              let directAudio = resolved.adaptiveAudioUrl else { return nil }

        if streamMode?.lowercased() == "direct" {
            return (directVideo, directAudio)
        }
        if let proxyVideo = resolved.adaptiveVideoProxyUrl,
           let proxyAudio = resolved.adaptiveAudioProxyUrl {
            return (proxyVideo, proxyAudio)
        }
        return (directVideo, directAudio)
    }

    private func reportPlaybackFailure(_ reason: String) {
        isPreparingPlayback = false
        updateStatus("failed")
        let detail = player.currentItem?.errorLog()?.events.last?.errorComment
        errorMessage = "Playback failed: \(detail ?? reason)"
    }

    private func updateLikeStatus(_ likeStatus: String) {
        guard var nextState = state, var media = nextState.currentMedia else { return }
        media.likeStatus = likeStatus
        nextState.currentMedia = media
        if let index = nextState.queue.firstIndex(where: { $0.id == media.id }) {
            nextState.queue[index] = media
        }
        state = nextState
        updateNowPlayingInfo()
    }

    private func setCurrentRating(_ likeStatus: String) async {
        guard let client, let media = state?.currentMedia, let videoID = media.videoId else {
            errorMessage = "This item cannot be rated on YouTube."
            return
        }

        let requestID = UUID()
        ratingRequestID = requestID
        isUpdatingRating = true
        defer {
            if ratingRequestID == requestID {
                isUpdatingRating = false
            }
        }

        do {
            let result = try await client.setRating(mediaId: videoID, likeStatus: likeStatus)
            guard ratingRequestID == requestID, state?.currentMediaId == media.id else { return }
            updateLikeStatus(result.likeStatus)
            errorMessage = nil
            if result.likeStatus == "DISLIKE", config?.features.skipDislikedSongs.enabled == true {
                await next()
            }
        } catch {
            guard ratingRequestID == requestID else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func updateStatus(_ status: String) {
        guard var nextState = state else { return }
        nextState.status = status
        state = nextState
        updateNowPlayingInfo()
    }

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.isEnabled = true
        commands.pauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.isEnabled = true
        commands.nextTrackCommand.isEnabled = true
        commands.previousTrackCommand.isEnabled = true
        commands.changePlaybackPositionCommand.isEnabled = true
        commands.skipForwardCommand.isEnabled = true
        commands.skipBackwardCommand.isEnabled = true
        commands.skipForwardCommand.preferredIntervals = [10]
        commands.skipBackwardCommand.preferredIntervals = [10]

        addRemoteTarget(to: commands.playCommand) { model, _ in
            guard model.state?.status != "playing" else { return }
            await model.togglePlayPause()
        }
        addRemoteTarget(to: commands.pauseCommand) { model, _ in
            guard model.state?.status == "playing" else { return }
            await model.togglePlayPause()
        }
        addRemoteTarget(to: commands.togglePlayPauseCommand) { model, _ in
            await model.togglePlayPause()
        }
        addRemoteTarget(to: commands.nextTrackCommand) { model, _ in
            await model.next()
        }
        addRemoteTarget(to: commands.previousTrackCommand) { model, _ in
            await model.previous()
        }
        addRemoteTarget(to: commands.skipForwardCommand) { model, _ in
            model.skip(by: 10)
        }
        addRemoteTarget(to: commands.skipBackwardCommand) { model, _ in
            model.skip(by: -10)
        }
        addRemoteTarget(to: commands.changePlaybackPositionCommand) { model, event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return }
            model.seek(to: Int(event.positionTime * 1000))
        }
    }

    private func addRemoteTarget(
        to command: MPRemoteCommand,
        action: @escaping @MainActor (PlayerViewModel, MPRemoteCommandEvent) async -> Void
    ) {
        let target = command.addTarget { [weak self] event in
            guard self != nil else { return .commandFailed }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await action(self, event)
            }
            return .success
        }
        remoteCommandTargets.append((command, target))
    }

    private func updateNowPlayingInfo() {
        guard let media = state?.currentMedia else {
            artworkLoadTask?.cancel()
            artworkLoadTask = nil
            nowPlayingArtworkURL = nil
            nowPlayingArtwork = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        prepareNowPlayingArtwork(for: media)

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: media.title,
            MPMediaItemPropertyArtist: media.artist,
            MPMediaItemPropertyAlbumTitle: media.album ?? "",
            MPMediaItemPropertyPlaybackDuration: Double(playbackDurationMs) / 1000,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(playbackTimeMs) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: state?.status == "playing" ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = nowPlayingArtwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func prepareNowPlayingArtwork(for media: MediaItem) {
        guard nowPlayingArtworkURL != media.artworkUrl else { return }

        artworkLoadTask?.cancel()
        artworkLoadTask = nil
        nowPlayingArtworkURL = media.artworkUrl
        nowPlayingArtwork = nil

        guard let artworkURL = media.artworkUrl else { return }
        if let image = artworkCache.object(forKey: artworkURL as NSURL) {
            nowPlayingArtwork = makeNowPlayingArtwork(from: image)
            return
        }

        artworkLoadTask = Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(from: artworkURL)
                try Task.checkCancellation()
                if let response = response as? HTTPURLResponse,
                   !(200 ..< 300).contains(response.statusCode) {
                    return
                }
                guard let image = UIImage(data: data),
                      let self,
                      self.state?.currentMedia?.artworkUrl == artworkURL
                else {
                    return
                }

                self.artworkCache.setObject(image, forKey: artworkURL as NSURL)
                self.nowPlayingArtwork = self.makeNowPlayingArtwork(from: image)
                self.updateNowPlayingInfo()
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func makeNowPlayingArtwork(from image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func scheduleNextPlaybackPrecache() {
        nextPlaybackTask?.cancel()
        nextPlaybackTask = nil
        nextPlaybackCache = nil

        guard let client,
              let state,
              state.repeatMode != "one",
              let nextItem = nextQueueItem(
                  in: state.queue,
                  currentID: state.currentMediaId,
                  shuffled: state.shuffle
              )
        else {
            nextPlaybackCandidate = nil
            return
        }

        let requestID = playbackRequestID
        nextPlaybackCandidate = nextItem
        nextPlaybackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let resolved = try await self.resolvePlaybackMedia(nextItem, client: client)
                let asset = resolved.adaptiveVideoURL == nil
                    ? await self.preloadPlaybackAsset(for: resolved.url)
                    : nil
                guard !Task.isCancelled,
                      self.playbackRequestID == requestID,
                      self.nextPlaybackCandidate?.id == nextItem.id
                else { return }

                self.nextPlaybackCache = NextPlaybackCache(
                    requestID: requestID,
                    mediaID: nextItem.id,
                    resolved: resolved,
                    asset: asset
                )
            } catch {
                guard !Task.isCancelled,
                      self.playbackRequestID == requestID,
                      self.nextPlaybackCandidate?.id == nextItem.id
                else { return }
                self.nextPlaybackCache = nil
            }
        }
    }

    private func preloadPlaybackAsset(for url: URL) async -> AVURLAsset? {
        let asset = AVURLAsset(url: url)
        do {
            let isPlayable = try await asset.load(.isPlayable)
            guard isPlayable else { return nil }
            _ = try? await asset.load(.duration)
            return asset
        } catch {
            return nil
        }
    }

    private func invalidateNextPlaybackCache() {
        nextPlaybackTask?.cancel()
        nextPlaybackTask = nil
        nextPlaybackCandidate = nil
        nextPlaybackCache = nil
    }

    private func nextPlaybackItem(for state: PlayerState) -> MediaItem? {
        if let candidate = nextPlaybackCandidate,
           candidate.id != state.currentMediaId,
           state.queue.contains(where: { $0.id == candidate.id }) {
            return candidate
        }

        return nextQueueItem(
            in: state.queue,
            currentID: state.currentMediaId,
            shuffled: state.shuffle
        )
    }

    private func cachedPrefetchedPlayback(for media: MediaItem) -> PrefetchedPlaybackMedia? {
        guard let cache = nextPlaybackCache,
              cache.requestID == playbackRequestID,
              cache.mediaID == media.id
        else { return nil }
        return PrefetchedPlaybackMedia(resolved: cache.resolved, asset: cache.asset)
    }

    private func nextQueueItem(
        in queue: [MediaItem],
        currentID: String?,
        shuffled: Bool
    ) -> MediaItem? {
        guard !queue.isEmpty else { return nil }
        if shuffled {
            let historyIDs = Set(playbackHistory)
            let unplayed = queue.filter { item in
                item.id != currentID && !historyIDs.contains(item.id)
            }
            let candidates = unplayed.isEmpty
                ? queue.filter { $0.id != currentID }
                : unplayed
            return candidates.randomElement()
        }

        guard let currentID, let index = queue.firstIndex(where: { $0.id == currentID }) else {
            return queue.first
        }
        return queue.indices.contains(index + 1) ? queue[index + 1] : nil
    }

    private func previousQueueItem(in queue: [MediaItem], currentID: String?) -> MediaItem? {
        guard
            let currentID,
            let index = queue.firstIndex(where: { $0.id == currentID }),
            index > queue.startIndex
        else {
            return nil
        }
        return queue[index - 1]
    }
}

private enum PlaybackError: LocalizedError {
    case notPlayable

    var errorDescription: String? {
        switch self {
        case .notPlayable:
            return "This item does not contain a playable stream."
        }
    }
}

private func merge(_ original: MediaItem, with resolved: MediaItem?) -> MediaItem {
    guard var resolved else { return original }
    resolved.id = original.id
    resolved.videoId = original.videoId ?? resolved.videoId
    resolved.browseId = original.browseId ?? resolved.browseId
    resolved.playlistId = original.playlistId ?? resolved.playlistId
    resolved.type = original.type ?? resolved.type
    resolved.title = resolved.title.isEmpty ? original.title : resolved.title
    resolved.artist = resolved.artist.isEmpty ? original.artist : resolved.artist
    resolved.album = resolved.album ?? original.album
    resolved.durationMs = resolved.durationMs > 0 ? resolved.durationMs : original.durationMs
    resolved.artworkUrl = resolved.artworkUrl ?? original.artworkUrl
    resolved.sourceUrl = resolved.sourceUrl ?? original.sourceUrl
    resolved.tags = resolved.tags.isEmpty ? original.tags : resolved.tags
    return resolved
}

private func composeHomeSections(
    library: [MediaSection],
    home: [MediaSection],
    explore: [MediaSection]
) -> [MediaSection] {
    var output: [MediaSection] = []

    if let listenAgain = (library + home + explore).first(where: { section in
        section.items.contains(where: \.isPlayable)
    }) ?? library.first(where: { !$0.items.isEmpty }) {
        let playableItems = listenAgain.items.filter(\.isPlayable)
        output.append(MediaSection(
            id: "listen-again",
            title: "Listen Again",
            items: Array((playableItems.isEmpty ? listenAgain.items : playableItems).prefix(12))
        ))
    }

    output.append(contentsOf: home.filter { section in
        section.items.contains(where: \.isPlayable)
    }.prefix(3))
    output.append(contentsOf: explore.filter { section in
        section.items.contains(where: \.isPlayable)
    }.prefix(3))
    output.append(contentsOf: library.filter { !$0.items.isEmpty }.prefix(2))

    var seenSectionIDs = Set<String>()
    var seen = Set<String>()
    return output.compactMap { section in
        guard seenSectionIDs.insert(section.id).inserted else { return nil }
        let items = section.items.filter { item in
            guard !seen.contains(item.id) else { return false }
            seen.insert(item.id)
            return true
        }
        guard !items.isEmpty else { return nil }
        return MediaSection(id: section.id, title: section.title, items: items)
    }
}
