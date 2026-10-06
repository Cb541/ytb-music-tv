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
    mimeType: String?,
    audioBitrate: Int?
)

private struct NextPlaybackCache {
    let requestID: UUID
    let mediaID: String
    let resolved: ResolvedPlaybackMedia
    let item: AVPlayerItem?
}

private struct PrefetchedPlaybackMedia {
    let resolved: ResolvedPlaybackMedia
    let item: AVPlayerItem?
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
    @Published private(set) var currentAudioBitrate: Int?
    @Published private(set) var isUpdatingRating = false
    @Published var errorMessage: String?

    @Published private(set) var player = AVPlayer()
    private var standbyPlayer: AVPlayer?
    private var fadingOutPlayer: AVPlayer?
    private var crossfadeTask: Task<Void, Never>?
    private var crossfadeGeneration = UUID()
    private var crossfadeSeconds: Double {
        let defaults = UserDefaults.standard
        let value = defaults.object(forKey: "YTBMusicTV.crossfadeSeconds") == nil
            ? 5.0 : defaults.double(forKey: "YTBMusicTV.crossfadeSeconds")
        return min(12, max(0, value))
    }
    let playbackProgress = PlaybackProgress()

    private var client: APIClient?
    private var timeObservationGeneration = UUID()
    private var timeObserver: Any?
    private var timeObserverPlayer: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var completedPlaybackItem: AVPlayerItem?
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
    private var playbackQueueTask: Task<Void, Never>?
    private var playbackQueueRevision = UUID()
    @Published private(set) var isLoadingPlaybackQueue = false
    @Published private(set) var isLoadingMix = false
    @Published private(set) var isMixActive = false
    private var mixTask: Task<Void, Never>?
    private var mixRevision = UUID()
    private var lastMixSeedID: String?
    private var loadingPlaylistCursors = Set<String>()
    private var browseRequestID = UUID()
    private var homeLoadRevision = 0
    private var searchRevision = 0
    @Published private(set) var homePlaylist: MediaItem?
    @Published private(set) var searchPlaylist: MediaItem?
    @Published private(set) var searchPageTitle: String?
    @Published private(set) var searchQuery = ""
    @Published private(set) var searchCategory = "all"
    private var homePlaylistHistory: [MediaItem?] = []
    private var searchPlaylistHistory: [MediaItem?] = []
    private var searchTitleHistory: [String?] = []
    private var homeNavigationHistory: [[MediaSection]] = []
    private var searchNavigationHistory: [[MediaSection]] = []
    private var knownRatings: [String: String] = [:]
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
            timeObserverPlayer?.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        timeControlObserver?.invalidate()
        itemStatusObserver?.invalidate()
        nextPlaybackTask?.cancel()
        playbackQueueTask?.cancel()
        crossfadeTask?.cancel()
        configUpdateTask?.cancel()
        artworkLoadTask?.cancel()
        for (command, target) in remoteCommandTargets {
            command.removeTarget(target)
        }
    }

    // MARK: - Data source

    func connect(to baseURL: URL, accessToken: String? = nil) async {
        cancelMix()
        cancelPlaybackQueueLoading()
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
            knownRatings.removeAll()
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

        let playbackChanged = config?.playback != nextConfig.playback
        config = nextConfig
        if playbackChanged {
            cancelCrossfade()
            scheduleNextPlaybackPrecache()
        }
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

    func search(_ query: String, type: String = "all") async {
        browseRequestID = UUID()
        searchRevision &+= 1
        let revision = searchRevision
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, !trimmedQuery.isEmpty else {
            searchSections = []
            searchQuery = ""; searchCategory = "all"
            searchNavigationHistory.removeAll(); searchPlaylistHistory.removeAll(); searchTitleHistory.removeAll(); searchPlaylist = nil; searchPageTitle = nil
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
            let sections = try await client.search(query: trimmedQuery, type: type).sections
            guard revision == searchRevision else { return }
            searchSections = applyingKnownRatings(to: sections)
            searchQuery = trimmedQuery; searchCategory = type
            searchNavigationHistory.removeAll(); searchPlaylistHistory.removeAll(); searchTitleHistory.removeAll(); searchPlaylist = nil; searchPageTitle = nil
            errorMessage = nil
        } catch {
            guard revision == searchRevision else { return }
            errorMessage = error.localizedDescription
        }
    }

    func searchPlaylist(_ media: MediaItem, query: String) async -> MediaSectionResponse? {
        guard let client else { return nil }
        do { return try await client.playlistSearch(media: media, query: query) }
        catch { if !Task.isCancelled { errorMessage = error.localizedDescription }; return nil }
    }

    func openRelated(_ media: MediaItem, kind: String) async -> Bool {
        browseRequestID = UUID()
        guard let client else { return false }
        searchRevision &+= 1
        let revision = searchRevision
        isSearching = true
        defer { if revision == searchRevision { isSearching = false } }
        do {
            let response = try await client.browseRelated(media: media, kind: kind)
            guard revision == searchRevision else { return false }
            if !searchSections.isEmpty { searchNavigationHistory.append(searchSections); searchPlaylistHistory.append(searchPlaylist); searchTitleHistory.append(searchPageTitle) }
            searchPlaylist = nil
            searchPageTitle = response.title
            searchSections = applyingKnownRatings(to: response.sections)
            return true
        } catch { if revision == searchRevision { errorMessage = error.localizedDescription }; return false }
    }

    func loadExplore() async {
        guard let client else { return }
        do {
            exploreSections = applyingKnownRatings(to: try await client.explore().sections)
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
            rememberKnownRatings(in: library.sections)
            let ratedLibrary = applyingKnownRatings(to: library.sections)
            let ratedHome = applyingKnownRatings(to: home.sections)
            let ratedExplore = applyingKnownRatings(to: explore.sections)
            librarySections = ratedLibrary
            exploreSections = ratedExplore
            homeSections = composeHomeSections(
                library: ratedLibrary,
                home: ratedHome,
                explore: ratedExplore
            )
            homeNavigationHistory.removeAll(); homePlaylistHistory.removeAll(); homePlaylist = nil

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
            rememberKnownRatings(in: response.sections)
            librarySections = applyingKnownRatings(to: response.sections)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Client-owned playback

    @discardableResult
    func play(_ media: MediaItem, queue: [MediaItem] = []) async -> Bool {
        let continuation = queue.first { $0.type == "playlist-page" }
        let reusesQueue = queue.isEmpty || (continuation == nil && queue == state?.queue)
        if !reusesQueue { cancelMix(); cancelPlaybackQueueLoading() }
        let started = await startPlayback(
            media,
            replacingQueue: reusesQueue ? nil : queue.filter(\.isPlayable),
            recordHistory: true
        )
        if started, let continuation { loadPlaybackQueue(from: continuation) }
        return started
    }

    func startMix() {
        guard state?.currentMedia != nil else { return }
        cancelMix()
        requestMix(replacing: true)
    }

    private func cancelMix() {
        mixRevision = UUID()
        mixTask?.cancel(); mixTask = nil
        isLoadingMix = false; isMixActive = false; lastMixSeedID = nil
    }

    private func maybeExtendMix() {
        guard isMixActive, !isLoadingMix, let current = state,
              let index = current.queue.firstIndex(where: { $0.id == current.currentMediaId }),
              current.queue.count - index <= 6 else { return }
        requestMix(replacing: false)
    }

    private func requestMix(replacing: Bool) {
        guard let client, let current = state,
              let seed = replacing ? current.currentMedia : current.queue.last,
              let seedID = seed.videoId, seedID != lastMixSeedID else { return }
        let revision = mixRevision
        let requestID = playbackRequestID
        lastMixSeedID = seedID
        isLoadingMix = true
        mixTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.mixRevision == revision { self.isLoadingMix = false; self.mixTask = nil }
            }
            do {
                let response = try await client.mix(mediaId: seedID)
                guard !Task.isCancelled, self.mixRevision == revision, var next = self.state,
                      !replacing || self.playbackRequestID == requestID else { return }
                var seen = Set((replacing ? [seed] : next.queue).map { $0.videoId ?? $0.id })
                let songs = self.applyingKnownRatings(to: response.sections.flatMap(\.items)).filter {
                    $0.isPlayable && seen.insert($0.videoId ?? $0.id).inserted
                }
                guard !songs.isEmpty else {
                    if replacing { self.errorMessage = "No mix recommendations are available for this song." }
                    return
                }
                if replacing {
                    self.cancelPlaybackQueueLoading()
                    self.cancelCrossfade()
                    next.queue = [next.currentMedia ?? seed] + songs
                    next.shuffle = false; next.repeatMode = "off"
                    self.isMixActive = true
                } else { next.queue.append(contentsOf: songs) }
                self.state = next
                self.errorMessage = nil
                self.scheduleNextPlaybackPrecache()
            } catch {
                if !Task.isCancelled && self.mixRevision == revision {
                    self.errorMessage = "Could not load the song mix: " + error.localizedDescription
                    self.lastMixSeedID = nil
                }
            }
        }
    }

    private func cancelPlaybackQueueLoading() {
        playbackQueueRevision = UUID()
        playbackQueueTask?.cancel()
        playbackQueueTask = nil
        isLoadingPlaybackQueue = false
    }

    private func loadPlaybackQueue(from firstPage: MediaItem) {
        guard let client else { return }
        cancelPlaybackQueueLoading()
        let revision = playbackQueueRevision
        isLoadingPlaybackQueue = true
        playbackQueueTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.playbackQueueRevision == revision {
                    self.playbackQueueTask = nil
                    self.isLoadingPlaybackQueue = false
                }
            }
            var page = firstPage
            var visited = Set<String>()
            do {
                while let cursor = page.tags.first, visited.insert(cursor).inserted {
                    let response = try await client.browse(media: page)
                    guard !Task.isCancelled, self.playbackQueueRevision == revision,
                          var current = self.state else { return }
                    let songs = self.applyingKnownRatings(to: response.sections.flatMap(\.items).filter(\.isPlayable))
                    current.queue.append(contentsOf: songs)
                    self.state = current
                    if self.nextPlaybackCandidate == nil { self.scheduleNextPlaybackPrecache() }
                    guard let next = response.continuation, !next.isEmpty else { break }
                    page.tags = [next]
                }
            } catch {
                if !Task.isCancelled && self.playbackQueueRevision == revision {
                    self.errorMessage = "Could not finish loading the playback playlist: " + error.localizedDescription
                }
            }
        }
    }

    func preparePlaybackPresentation(_ media: MediaItem) {
        guard media.isPlayable else { return }
        pendingMedia = applyingKnownRating(to: media)
        isPreparingPlayback = true
        errorMessage = nil
    }

    func selectSearch(_ media: MediaItem, queue: [MediaItem] = []) async -> Bool {
        await select(media, queue: queue) { [weak self] sections, append in
            guard let self else { return }
            if !append && !searchSections.isEmpty {
                searchNavigationHistory.append(searchSections)
                searchPlaylistHistory.append(searchPlaylist)
                searchTitleHistory.append(searchPageTitle)
            }
            if !append { searchPlaylist = (media.type == "playlist" || media.playlistId != nil) ? media : nil; searchPageTitle = media.title }
            searchSections = append ? mergeBrowseSections(searchSections, sections) : sections
        }
    }

    func selectHome(_ media: MediaItem, queue: [MediaItem] = []) async -> Bool {
        await select(media, queue: queue) { [weak self] sections, append in
            guard let self else { return }
            if !append && !homeSections.isEmpty {
                homeNavigationHistory.append(homeSections)
                homePlaylistHistory.append(homePlaylist)
            }
            if !append { homePlaylist = (media.type == "playlist" || media.playlistId != nil) ? media : nil }
            homeSections = append ? mergeBrowseSections(homeSections, sections) : sections
        }
    }

    func selectExplore(_ media: MediaItem, queue: [MediaItem] = []) async -> Bool {
        await select(media, queue: queue) { [weak self] sections, append in
            guard let self else { return }
            exploreSections = append ? mergeBrowseSections(exploreSections, sections) : sections
        }
    }

    func selectLibrary(_ media: MediaItem, queue: [MediaItem] = []) async -> Bool {
        await select(media, queue: queue) { [weak self] sections, append in
            guard let self else { return }
            librarySections = append ? mergeBrowseSections(librarySections, sections) : sections
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
            fadingOutPlayer?.pause()
            nextState.status = "paused"
            isPreparingPlayback = false
        } else {
            if playbackDurationMs > 0, playbackTimeMs >= playbackDurationMs - 500 {
                seek(to: 0)
            }
            if crossfadeTask == nil { player.volume = 1 }
            player.playImmediately(atRate: 1)
            fadingOutPlayer?.playImmediately(atRate: 1)
            nextState.status = "playing"
            isPreparingPlayback = player.timeControlStatus != .playing
        }
        state = nextState
        updateNowPlayingInfo()
    }

    func next() async {
        cancelCrossfade()
        guard var state else { return }

        if state.repeatMode == "one" {
            seek(to: 0)
            player.volume = 1
            player.playImmediately(atRate: 1)
            updateStatus("playing")
            return
        }

        let currentID = state.currentMediaId
        while nextPlaybackItem(for: state) == nil && (isLoadingPlaybackQueue || isLoadingMix) {
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            guard let updated = self.state, updated.currentMediaId == currentID else { return }
            state = updated
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
        cancelCrossfade()
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
        cancelCrossfade()
        guard var nextState = state else { return }
        nextState.shuffle.toggle()
        state = nextState
        scheduleNextPlaybackPrecache()
    }

    func toggleRepeatOne() async {
        cancelCrossfade()
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
        cancelCrossfade()
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
        browseRequestID = UUID()
        guard let previous = homeNavigationHistory.popLast() else { return false }
        homeSections = previous
        homePlaylist = homePlaylistHistory.popLast() ?? nil
        return true
    }

    @discardableResult
    func navigateBackSearch() -> Bool {
        browseRequestID = UUID()
        searchRevision &+= 1
        isSearching = false
        guard let previous = searchNavigationHistory.popLast() else { return false }
        searchSections = previous
        searchPlaylist = searchPlaylistHistory.popLast() ?? nil
        searchPageTitle = searchTitleHistory.popLast() ?? nil
        return true
    }

    func reportError(_ message: String) {
        errorMessage = message
    }

    private func select(
        _ media: MediaItem,
        queue: [MediaItem],
        assignSections: @escaping ([MediaSection], Bool) -> Void
    ) async -> Bool {
        guard let client else {
            errorMessage = "Connect to the YTB Music TV server first."
            return false
        }
        if media.isPlayable {
            return await play(media, queue: queue)
        }

        let cursor = media.type == "playlist-page" ? media.tags.first : nil
        if let cursor {
            guard loadingPlaylistCursors.insert(cursor).inserted else { return false }
        }
        defer { if let cursor { loadingPlaylistCursors.remove(cursor) } }

        let requestID = UUID()
        browseRequestID = requestID
        do {
            let response = try await client.browse(media: media)
            guard browseRequestID == requestID else { return false }
            var sections = applyingKnownRatings(to: response.sections)
            if let cursor = response.continuation, !cursor.isEmpty, !sections.isEmpty {
                let id = media.playlistId ?? media.browseId ?? media.id
                let more = MediaItem(id: "playlist-next:" + id, browseId: id, playlistId: id,
                    type: "playlist-page", title: "Load more songs", artist: "Continue playlist",
                    durationMs: 0, likeStatus: "INDIFFERENT", tags: [cursor])
                sections[0].items.append(more)
            }
            assignSections(sections, media.type == "playlist-page")
            errorMessage = response.sections.isEmpty
                ? response.message ?? "No playable items found."
                : nil
            return false
        } catch {
            guard browseRequestID == requestID else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func mergeBrowseSections(_ previous: [MediaSection], _ incoming: [MediaSection]) -> [MediaSection] {
        var result = previous
        for section in incoming {
            if let index = result.firstIndex(where: { $0.id == section.id }) {
                result[index].items.removeAll { $0.type == "playlist-page" }
                result[index].items.append(contentsOf: section.items)
            } else { result.append(section) }
        }
        return result
    }

    private func startPlayback(
        _ media: MediaItem,
        replacingQueue: [MediaItem]?,
        recordHistory: Bool,
        prefetched: PrefetchedPlaybackMedia? = nil
    ) async -> Bool {
        guard let client else {
            if pendingMedia?.id == media.id {
                pendingMedia = nil
                isPreparingPlayback = false
            }
            errorMessage = "Connect to the YTB Music TV server before starting playback."
            return false
        }

        let requestID = UUID()
        playbackRequestID = requestID
        invalidateNextPlaybackCache()
        pendingMedia = media
        currentAudioBitrate = nil
        isPreparingPlayback = true
        errorMessage = nil
        fallbackPlaybackURLs.removeAll()
        audioFallbackAttempted = false

        do {
            let resolved: ResolvedPlaybackMedia
            let prefetchedItem: AVPlayerItem?
            if let prefetched, prefetched.resolved.media.id == media.id {
                resolved = prefetched.resolved
                prefetchedItem = prefetched.item
            } else {
                resolved = try await resolvePlaybackMedia(media, client: client)
                prefetchedItem = nil
            }
            guard playbackRequestID == requestID else { return false }

            let preparedItem: AVPlayerItem?
            if let prefetchedItem {
                preparedItem = prefetchedItem
            } else if let videoURL = resolved.adaptiveVideoURL, let audioURL = resolved.adaptiveAudioURL {
                preparedItem = try? await makeAdaptivePlayerItem(videoURL: videoURL, audioURL: audioURL)
            } else {
                preparedItem = nil
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
            currentAudioBitrate = resolved.adaptiveAudioURL != nil && preparedItem == nil ? nil : resolved.audioBitrate
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

            if let preparedItem {
                let adaptiveFallbacks = resolved.adaptiveVideoURL != nil
                    ? [resolved.url] + (resolved.fallbackURL.map { [$0] } ?? [])
                    : resolved.fallbackURL.map { [$0] } ?? []
                configurePlayer(
                    item: preparedItem,
                    fallbackURLs: adaptiveFallbacks
                )
            } else {
                configurePlayer(
                    url: resolved.url,
                    fallbackURLs: resolved.fallbackURL.map { [$0] } ?? []
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
        if media.videoId != nil {
            let needsSongLookup = media.type != "song" || media.albumBrowseId == nil
            let resolved: ResolvedStream
            let canonical: MediaItem
            let preferVideo: Bool?
            if needsSongLookup {
                // Match and resolve audio together. Never apply only the cover metadata.
                resolved = try await client.resolveSong(media: media)
                canonical = resolved.media ?? media
                preferVideo = false
            } else {
                canonical = media
                preferVideo = config?.playback.preferVideo
                resolved = try await client.resolve(mediaId: media.videoId!, preferVideo: preferVideo)
            }
            let redirected = resolved.videoId != media.videoId
            var merged = merge(canonical, with: resolved.media)
            // Keep the playlist slot stable while using the official recording for playback and ratings.
            merged.id = media.id
            if redirected { merged.artworkUrl = canonical.artworkUrl ?? merged.artworkUrl }
            let playbackURLs = playbackURLs(for: resolved, streamMode: config?.playback.streamMode)
            let adaptiveURLs = preferVideo == true
                ? adaptivePlaybackURLs(for: resolved, streamMode: config?.playback.streamMode) : nil
            let playbackURL = playbackURLs.primary
            merged.playbackUrl = playbackURL
            return (
                merged,
                playbackURL,
                playbackURLs.fallback,
                adaptiveURLs?.video,
                adaptiveURLs?.audio,
                preferVideo == true && resolved.hasVideo == true,
                resolved.mimeType,
                resolved.audioBitrate
            )
        }

        if let playbackURL = media.streamUrl ?? media.playbackUrl {
            var playable = media
            playable.playbackUrl = playbackURL
            return (playable, playbackURL, nil, nil, nil, config?.playback.preferVideo == true, nil, nil)
        }

        throw PlaybackError.notPlayable
    }

    private func configurePlayer(
        url: URL,
        fallbackURLs: [URL]
    ) {
        fallbackPlaybackURLs = fallbackURLs
        replacePlayerItem(url: url)
    }

    private func configurePlayer(item: AVPlayerItem, fallbackURLs: [URL]) {
        var seen = Set<URL>()
        fallbackPlaybackURLs = fallbackURLs.filter { seen.insert($0).inserted }
        replacePlayerItem(item: item)
    }

    private func makeAdaptivePlayerItem(videoURL: URL, audioURL: URL) async throws -> AVPlayerItem {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        // Remote MP4 track loading can stall. Cancel both loads and let the caller
        // fall back to the working stream rather than leave playback spinning.
        let loadDeadline = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            videoAsset.cancelLoading()
            audioAsset.cancelLoading()
        }
        defer { loadDeadline.cancel() }
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

    private func replacePlayerItem(item: AVPlayerItem) {
        cancelCrossfade()
        removePlaybackTimeObserver()
        player.pause()
        completedPlaybackItem = nil
        refreshPlaybackTiming(for: item)
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
                guard let self, self.player === player else { return }
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

    private func removePlaybackTimeObserver() {
        timeObservationGeneration = UUID()
        if let timeObserver { timeObserverPlayer?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        timeObserverPlayer = nil
    }

    @discardableResult
    private func refreshPlaybackTiming(for item: AVPlayerItem) -> PlaybackTiming {
        let timing = PlaybackTiming.resolve(metadataMs: state?.currentMedia?.durationMs ?? 0,
            streamSeconds: CMTimeGetSeconds(item.duration), hasVideo: currentStreamHasVideo)
        if playbackDurationMs != timing.durationMs { playbackDurationMs = timing.durationMs }
        let end = timing.endTimeMs.map { CMTime(value: Int64($0), timescale: 1000) } ?? .invalid
        if item.forwardPlaybackEndTime != end { item.forwardPlaybackEndTime = end }
        return timing
    }

    private func installTimeObserverIfNeeded() {
        guard timeObserver == nil else { return }
        timeObserverPlayer = player
        timeObservationGeneration = UUID()
        let generation = timeObservationGeneration
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self, self.timeObservationGeneration == generation else { return }
                let seconds = CMTimeGetSeconds(time)
                guard seconds.isFinite else { return }

                let previousSecond = self.playbackTimeMs / 1000
                let currentMs = max(0, Int(seconds * 1000))
                self.playbackTimeMs = currentMs

                if let item = self.player.currentItem {
                    let timing = self.refreshPlaybackTiming(for: item)
                    // Re-arm after a repeat or manual seek actually returns to
                    // an earlier position, not while an old end callback is queued.
                    if self.completedPlaybackItem === item && currentMs < max(0, timing.durationMs - 500) {
                        self.completedPlaybackItem = nil
                    }
                    if let end = timing.endTimeMs, currentMs >= max(0, end - 1),
                       self.state?.status == "playing", self.pendingMedia == nil, self.crossfadeTask == nil {
                        self.player.pause()
                        await self.finishPlayback(for: item)
                        return
                    }
                }
                self.maybeBeginCrossfade()
                if currentMs / 1000 != previousSecond { self.updateNowPlayingInfo() }
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
                guard let self else { return }
                await self.finishPlayback(for: item)
            }
        }
    }

    private func finishPlayback(for item: AVPlayerItem) async {
        guard player.currentItem === item, crossfadeTask == nil, pendingMedia == nil,
              state?.status == "playing", completedPlaybackItem !== item else { return }
        completedPlaybackItem = item
        await next()
    }

    private func installStatusObserver(for item: AVPlayerItem) {
        itemStatusObserver?.invalidate()
        itemStatusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                switch item.status {
                case .readyToPlay:
                    self.refreshPlaybackTiming(for: item)
                    if self.crossfadeTask == nil { self.player.volume = 1 }
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
        currentAudioBitrate = nil
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
                self.currentAudioBitrate = resolved.audioBitrate
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
        knownRatings[ratingKey(for: media)] = likeStatus
        nextState.currentMedia = media
        nextState.queue = applyingKnownRatings(to: nextState.queue)
        state = nextState
        searchSections = applyingKnownRatings(to: searchSections)
        homeSections = applyingKnownRatings(to: homeSections)
        exploreSections = applyingKnownRatings(to: exploreSections)
        librarySections = applyingKnownRatings(to: librarySections)
        searchNavigationHistory = searchNavigationHistory.map(applyingKnownRatings(to:))
        homeNavigationHistory = homeNavigationHistory.map(applyingKnownRatings(to:))
        updateNowPlayingInfo()
    }

    private func ratingKey(for media: MediaItem) -> String {
        media.videoId ?? media.id
    }

    private func rememberKnownRatings(in sections: [MediaSection]) {
        for media in sections.flatMap(\.items)
            where media.likeStatus == "LIKE" || media.likeStatus == "DISLIKE" {
            knownRatings[ratingKey(for: media)] = media.likeStatus
        }
    }

    private func applyingKnownRating(to media: MediaItem) -> MediaItem {
        guard let likeStatus = knownRatings[ratingKey(for: media)] else { return media }
        var rated = media
        rated.likeStatus = likeStatus
        return rated
    }

    private func applyingKnownRatings(to items: [MediaItem]) -> [MediaItem] {
        items.map(applyingKnownRating(to:))
    }

    private func applyingKnownRatings(to sections: [MediaSection]) -> [MediaSection] {
        sections.map { section in
            MediaSection(id: section.id, title: section.title, items: applyingKnownRatings(to: section.items))
        }
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
        maybeExtendMix()
        nextPlaybackTask?.cancel()
        nextPlaybackTask = nil
        standbyPlayer?.pause()
        standbyPlayer = nil
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
                let item = await self.preparePlayerItem(for: resolved)
                guard !Task.isCancelled,
                      self.playbackRequestID == requestID,
                      self.nextPlaybackCandidate?.id == nextItem.id
                else { return }

                self.nextPlaybackCache = NextPlaybackCache(
                    requestID: requestID,
                    mediaID: nextItem.id,
                    resolved: resolved,
                    item: item
                )
                if let item {
                    let prepared = AVPlayer(playerItem: item)
                    prepared.volume = 0
                    prepared.automaticallyWaitsToMinimizeStalling = true
                    self.standbyPlayer = prepared
                }
            } catch {
                guard !Task.isCancelled,
                      self.playbackRequestID == requestID,
                      self.nextPlaybackCandidate?.id == nextItem.id
                else { return }
                self.nextPlaybackCache = nil
            }
        }
    }

    // Two AVPlayers overlap only when the next stream is ready. Metadata and lyric time
    // switch to the incoming deck when it becomes the active player.
    private func maybeBeginCrossfade() {
        guard crossfadeSeconds > 0, crossfadeTask == nil,
              state?.status == "playing", state?.repeatMode != "one",
              player.timeControlStatus == .playing, playbackDurationMs > 0,
              let cache = nextPlaybackCache, cache.requestID == playbackRequestID,
              let incoming = standbyPlayer, incoming.currentItem?.status == .readyToPlay,
              cache.mediaID != state?.currentMediaId else { return }
        let remaining = Double(playbackDurationMs - playbackTimeMs) / 1000
        guard remaining > 0.3, remaining <= crossfadeSeconds else { return }
        let generation = UUID(); crossfadeGeneration = generation
        let requestID = playbackRequestID
        let outgoing = player
        let fadeDuration = min(crossfadeSeconds, remaining)
        crossfadeTask = Task { @MainActor [weak self] in
            incoming.volume = 0
            incoming.play()
            // Never fade away a playing song until the incoming deck is producing playback.
            for _ in 0..<100 {
                guard !Task.isCancelled else { incoming.pause(); return }
                if incoming.timeControlStatus == .playing { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let self, !Task.isCancelled, self.crossfadeGeneration == generation,
                  self.playbackRequestID == requestID else { incoming.pause(); return }
            guard incoming.timeControlStatus == .playing, self.state?.status == "playing" else {
                incoming.pause()
                await incoming.seek(to: .zero)
                guard !Task.isCancelled, self.crossfadeGeneration == generation,
                      self.playbackRequestID == requestID else { return }
                self.crossfadeTask = nil
                let oldTime = CMTimeGetSeconds(outgoing.currentTime())
                let oldDuration = CMTimeGetSeconds(outgoing.currentItem?.duration ?? .invalid)
                if self.playbackTimeMs >= self.playbackDurationMs ||
                    (oldTime.isFinite && oldDuration.isFinite && oldTime >= oldDuration - 0.1) {
                    await self.next()
                }
                return
            }
            let outgoingTime = CMTimeGetSeconds(outgoing.currentTime())
            let remainingAtStart = outgoingTime.isFinite
                ? max(0.1, Double(self.playbackDurationMs) / 1000 - outgoingTime) : fadeDuration
            let effectiveDuration = min(fadeDuration, remainingAtStart)
            self.promoteCrossfadePlayer(incoming, outgoing: outgoing, cache: cache)
            let incomingStart = CMTimeGetSeconds(incoming.currentTime())
            let began = incomingStart.isFinite ? incomingStart : 0
            while !Task.isCancelled, self.crossfadeGeneration == generation {
                let now = CMTimeGetSeconds(incoming.currentTime())
                let elapsed = now.isFinite ? max(0, now - began) : 0
                let progress = min(1, elapsed / max(0.1, effectiveDuration))
                incoming.volume = Float(sin(progress * .pi / 2))
                outgoing.volume = Float(cos(progress * .pi / 2))
                if progress >= 1 { break }
                if incoming.currentItem?.status == .failed { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard self.crossfadeGeneration == generation else { return }
            outgoing.pause(); outgoing.replaceCurrentItem(with: nil)
            incoming.volume = 1
            self.fadingOutPlayer = nil
            self.crossfadeTask = nil
        }
    }

    private func promoteCrossfadePlayer(_ incoming: AVPlayer, outgoing: AVPlayer, cache: NextPlaybackCache) {
        removePlaybackTimeObserver()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        itemStatusObserver?.invalidate()
        timeControlObserver?.invalidate()
        if let oldID = state?.currentMediaId { playbackHistory.append(oldID) }
        let oldState = state
        let resolved = cache.resolved
        var queue = oldState?.queue ?? []
        if let index = queue.firstIndex(where: { $0.id == resolved.media.id }) { queue[index] = resolved.media }
        player = incoming
        completedPlaybackItem = nil
        standbyPlayer = nil
        fadingOutPlayer = outgoing
        playbackRequestID = UUID()
        let incomingTime = CMTimeGetSeconds(incoming.currentTime())
        playbackTimeMs = incomingTime.isFinite ? max(0, Int(incomingTime * 1000)) : 0
        playbackDurationMs = resolved.media.durationMs
        currentStreamHasVideo = resolved.hasVideo
        currentAudioBitrate = resolved.audioBitrate
        state = PlayerState(status: "playing", currentTimeMs: playbackTimeMs,
            currentMediaId: resolved.media.id, currentMedia: resolved.media, queue: queue,
            shuffle: oldState?.shuffle ?? false, repeatMode: oldState?.repeatMode ?? "off")
        fallbackPlaybackURLs = resolved.fallbackURL.map { [$0] } ?? []
        audioFallbackAttempted = false
        if let item = incoming.currentItem { installStatusObserver(for: item); installEndObserver(for: item) }
        observeTimeControlStatus()
        installTimeObserverIfNeeded()
        updateNowPlayingInfo()
        scheduleNextPlaybackPrecache()
    }

    private func cancelCrossfade() {
        crossfadeGeneration = UUID()
        crossfadeTask?.cancel()
        crossfadeTask = nil
        fadingOutPlayer?.pause()
        fadingOutPlayer?.replaceCurrentItem(with: nil)
        fadingOutPlayer = nil
        player.volume = 1
    }

    private func preparePlayerItem(for resolved: ResolvedPlaybackMedia) async -> AVPlayerItem? {
        if let videoURL = resolved.adaptiveVideoURL, let audioURL = resolved.adaptiveAudioURL {
            return try? await makeAdaptivePlayerItem(videoURL: videoURL, audioURL: audioURL)
        }

        let asset = AVURLAsset(url: resolved.url)
        do {
            let isPlayable = try await asset.load(.isPlayable)
            guard isPlayable else { return nil }
            _ = try? await asset.load(.duration)
            let item = AVPlayerItem(asset: asset)
            let timing = PlaybackTiming.resolve(metadataMs: resolved.media.durationMs,
                streamSeconds: CMTimeGetSeconds(item.duration), hasVideo: resolved.hasVideo)
            if let end = timing.endTimeMs { item.forwardPlaybackEndTime = CMTime(value: Int64(end), timescale: 1000) }
            return item
        } catch {
            return nil
        }
    }

    private func invalidateNextPlaybackCache() {
        cancelCrossfade()
        standbyPlayer?.pause()
        standbyPlayer = nil
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
        // AVPlayerItems are owned by their deck. A manual skip gets a fresh item,
        // even when AVFoundation is still releasing the standby deck's item.
        let freshItem = cache.item.map { AVPlayerItem(asset: $0.asset) }
        standbyPlayer?.pause()
        standbyPlayer?.replaceCurrentItem(with: nil)
        standbyPlayer = nil
        return PrefetchedPlaybackMedia(resolved: cache.resolved, item: freshItem)
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
    resolved.artistBrowseId = original.artistBrowseId ?? resolved.artistBrowseId
    resolved.albumBrowseId = original.albumBrowseId ?? resolved.albumBrowseId
    resolved.durationMs = PlaybackTiming.metadataDuration(originalMs: original.durationMs, resolvedMs: resolved.durationMs)
    resolved.artworkUrl = resolved.artworkUrl ?? original.artworkUrl
    resolved.sourceUrl = resolved.sourceUrl ?? original.sourceUrl
    resolved.tags = resolved.tags.isEmpty ? original.tags : resolved.tags
    if resolved.likeStatus == "INDIFFERENT", original.likeStatus != "INDIFFERENT" {
        resolved.likeStatus = original.likeStatus
    }
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
