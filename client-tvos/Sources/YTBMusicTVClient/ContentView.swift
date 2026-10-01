import AVFoundation
import AVKit
import SwiftUI
#if os(tvOS)
    import UIKit
#endif

private enum AppTab: Hashable, CaseIterable {
    case home
    case search
    case settings

    var systemImage: String {
        switch self {
        case .home:
            return "house.fill"
        case .search:
            return "magnifyingglass"
        case .settings:
            return "gearshape.fill"
        }
    }

    func title(_ l10n: L10n) -> String {
        switch self {
        case .home:
            return l10n.text("nav.home")
        case .search:
            return l10n.text("nav.search")
        case .settings:
            return l10n.text("nav.settings")
        }
    }
}

struct ContentView: View {
    @StateObject private var settings = ServerSettings()
    @StateObject private var discovery = ServerDiscovery()
    @StateObject private var viewModel = PlayerViewModel()
    @ObservedObject private var intentRouter = AppIntentRouter.shared
    @State private var selectedTab: AppTab = .home
    @State private var showingPlayer = false
    @AppStorage("YTBMusicTV.musicLayout") private var musicLayout = true
    @State private var homeFocusRequestID = 0
    @State private var menuFocusRequestID = 0

    private var l10n: L10n {
        L10n(languageCode: settings.languageCode)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ArtworkBackdrop(media: viewModel.state?.currentMedia)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                AppShell(
                    selectedTab: $selectedTab,
                    viewModel: viewModel,
                    l10n: l10n,
                    openPlayer: openPlayer,
                    focusRequestID: menuFocusRequestID,
                    selectTab: selectTab,
                    tabFocused: { tab in
                        if tab == .home {
                            homeFocusRequestID &+= 1
                        }
                    }
                ) {
                    switch selectedTab {
                    case .home:
                        HomeView(
                            viewModel: viewModel,
                            l10n: l10n,
                            restoreRequestID: homeFocusRequestID
                        ) { media, queue in
                            if media.isPlayable {
                                viewModel.preparePlaybackPresentation(media)
                                openPlayer()
                            }
                            Task { _ = await viewModel.selectHome(media, queue: queue) }
                        } returnToMenu: {
                            menuFocusRequestID &+= 1
                        }
                    case .search:
                        SearchView(viewModel: viewModel, l10n: l10n) { media, queue in
                            if media.isPlayable {
                                viewModel.preparePlaybackPresentation(media)
                                openPlayer()
                            }
                            Task { _ = await viewModel.selectSearch(media, queue: queue) }
                        } returnToMenu: {
                            menuFocusRequestID &+= 1
                        }
                    case .settings:
                        SettingsView(
                            settings: settings,
                            discovery: discovery,
                            viewModel: viewModel,
                            l10n: l10n,
                            returnToMenu: { menuFocusRequestID &+= 1 }
                        )
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                .opacity(showingPlayer ? 0 : 1)
                .disabled(showingPlayer)
                .allowsHitTesting(!showingPlayer)
                .accessibilityHidden(showingPlayer)

                if showingPlayer {
                    Group {
                        if musicLayout {
                            MusicPlayerScreen(viewModel: viewModel, l10n: l10n, onBack: returnFromPlayer)
                        } else {
                            PlayerScreen(viewModel: viewModel, l10n: l10n, onBack: returnFromPlayer)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .transition(.opacity.combined(with: .scale(scale: 1.015)))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .background(Color.black)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.22), value: showingPlayer)
        .onChange(of: intentRouter.requestID) {
            handleIntentDestination()
        }
        .overlay(alignment: .top) {
            if let errorMessage = viewModel.errorMessage {
                ErrorBanner(message: errorMessage, dismiss: viewModel.clearError)
                    .padding(.top, showingPlayer ? 42 : 154)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.errorMessage)
        .task {
            discovery.start()
            if let baseURL = settings.serverBaseURL {
                await viewModel.connect(to: baseURL, accessToken: settings.serverAccessToken)
                clearInvalidAssociationIfNeeded()
            }
            handleIntentDestination()
        }
        .onChange(of: discovery.servers) {
            guard
                !settings.hasServerAddress,
                !viewModel.isConnected,
                !viewModel.isConnecting,
                let server = discovery.servers.first
            else {
                return
            }
            settings.selectServer(server.url)
            Task {
                await viewModel.connect(to: server.url, accessToken: settings.serverAccessToken)
                clearInvalidAssociationIfNeeded()
            }
        }
    }

    private func openPlayer() {
        withAnimation(.easeInOut(duration: 0.22)) {
            showingPlayer = true
        }
    }

    private func selectTab(_ tab: AppTab) {
        selectedTab = tab

        guard tab == .home else { return }
        homeFocusRequestID &+= 1
        Task {
            await viewModel.loadHome()
        }
    }

    private func returnFromPlayer() {
        viewModel.cancelPendingPlayback()
        withAnimation(.easeInOut(duration: 0.22)) {
            showingPlayer = false
        }
    }

    private func handleIntentDestination() {
        guard let destination = intentRouter.requestedDestination else { return }
        switch destination {
        case .home:
            showingPlayer = false
            selectedTab = .home
        case .search:
            showingPlayer = false
            selectedTab = .search
        case .settings:
            showingPlayer = false
            selectedTab = .settings
        case .nowPlaying:
            if viewModel.state?.currentMedia != nil {
                openPlayer()
            } else {
                selectedTab = .home
            }
        }
    }

    private func clearInvalidAssociationIfNeeded() {
        guard viewModel.isConnected else { return }
        if viewModel.connectedServerID != settings.associatedServerID || !viewModel.isAssociated {
            settings.clearAssociation()
        }
    }
}

private struct AppShell<Content: View>: View {
    @Binding var selectedTab: AppTab
    @ObservedObject var viewModel: PlayerViewModel
    var l10n: L10n
    var openPlayer: () -> Void
    var focusRequestID: Int
    var selectTab: (AppTab) -> Void
    var tabFocused: (AppTab) -> Void
    @ViewBuilder var content: () -> Content

    @FocusState private var focusedTab: AppTab?

    var body: some View {
        VStack(spacing: 0) {
            TopNavigationBar(
                selectedTab: $selectedTab,
                viewModel: viewModel,
                l10n: l10n,
                openPlayer: openPlayer,
                focusedTab: $focusedTab,
                selectTab: selectTab,
                tabFocused: tabFocused
            )
            .padding(.top, 58)
            .padding(.horizontal, 86)

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 42)
                .padding(.bottom, 72)
                .padding(.horizontal, 86)
        }
        .onChange(of: focusRequestID) {
            DispatchQueue.main.async {
                focusedTab = selectedTab
            }
        }
    }
}

private struct TopNavigationBar: View {
    @Binding var selectedTab: AppTab
    @ObservedObject var viewModel: PlayerViewModel
    var l10n: L10n
    var openPlayer: () -> Void
    var focusedTab: FocusState<AppTab?>.Binding
    var selectTab: (AppTab) -> Void
    var tabFocused: (AppTab) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            if viewModel.state?.currentMedia != nil {
                TopNowPlayingShortcut(viewModel: viewModel, l10n: l10n, openPlayer: openPlayer)
                    .frame(width: 420)
            } else {
                BrandLockup()
                    .frame(width: 420, alignment: .leading)
            }

            Spacer(minLength: 20)

            HStack(spacing: 18) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    TopNavButton(
                        tab: tab,
                        title: tab.title(l10n),
                        icon: tab.systemImage,
                        selected: selectedTab == tab,
                        action: { selectTab(tab) },
                        focusedTab: focusedTab,
                        didFocus: { tabFocused(tab) }
                    )
                }
            }
            .focusSection()

            Spacer(minLength: 20)

            ConnectionPill(viewModel: viewModel, l10n: l10n)
                .frame(width: 420, alignment: .trailing)
        }
        .frame(height: 78)
    }
}

private struct BrandLockup: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.red)
            Text("YTB Music TV")
                .font(.title3.weight(.bold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
    }
}

private struct ConnectionPill: View {
    @ObservedObject var viewModel: PlayerViewModel
    var l10n: L10n

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(statusText)
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(statusColor)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(.black.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusText: String {
        if !viewModel.isConnected {
            return l10n.text("settings.disconnected")
        }
        if !viewModel.isAssociated {
            return l10n.text("settings.notAssociated")
        }
        if !viewModel.isAuthenticated {
            return l10n.text("settings.notLoggedIn")
        }
        return l10n.text("settings.connected")
    }

    private var systemImage: String {
        if !viewModel.isConnected {
            return "xmark.circle.fill"
        }
        if !viewModel.isAssociated {
            return "link.badge.plus"
        }
        if !viewModel.isAuthenticated {
            return "exclamationmark.triangle.fill"
        }
        return "checkmark.circle.fill"
    }

    private var statusColor: Color {
        if !viewModel.isConnected {
            return .secondary
        }
        return viewModel.isAssociated && viewModel.isAuthenticated ? .green : .yellow
    }
}

private struct TopNavButton: View {
    var tab: AppTab
    var title: String
    var icon: String
    var selected: Bool
    var action: () -> Void
    var focusedTab: FocusState<AppTab?>.Binding
    var didFocus: () -> Void

    private var focused: Bool {
        focusedTab.wrappedValue == tab
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .bold))
                Text(title)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 20)
            .frame(height: 58)
            .glassSurface(
                cornerRadius: 29,
                interactive: true,
                emphasized: selected || focused,
                highlightColor: selected ? .red : .white
            )
            .overlay(
                Capsule()
                    .stroke(focused ? .white.opacity(0.72) : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(RemoteButtonStyle())
        .focusEffectDisabled()
        .focused(focusedTab, equals: tab)
        .foregroundStyle(.white)
        .scaleEffect(focused ? 1.08 : 1)
        .animation(.easeOut(duration: 0.14), value: focused)
        .onChange(of: focused) {
            if focused {
                didFocus()
            }
        }
        .accessibilityLabel(title)
    }
}

private struct TopNowPlayingShortcut: View {
    @ObservedObject var viewModel: PlayerViewModel
    var l10n: L10n
    var openPlayer: () -> Void

    @FocusState private var focused: Bool

    private static let width: CGFloat = 440
    private static let height: CGFloat = 74
    private static let artworkSize: CGFloat = 44
    private static let textWidth: CGFloat = 316

    var body: some View {
        if let media = viewModel.state?.currentMedia {
            Button(action: openPlayer) {
                HStack(spacing: 10) {
                    ArtworkThumb(url: media.artworkUrl, size: Self.artworkSize, cornerRadius: 7)

                    VStack(alignment: .leading, spacing: 0) {
                        MarqueeText(
                            text: media.title,
                            font: .system(size: 22, weight: .semibold),
                            color: .white
                        )
                        .frame(height: 30)

                        MarqueeText(
                            text: media.artist,
                            font: .system(size: 17, weight: .medium),
                            color: .white.opacity(0.68)
                        )
                        .frame(height: 22)
                    }
                    .frame(width: Self.textWidth, height: 52, alignment: .leading)
                    .clipped()

                    if viewModel.state?.status == "playing" {
                        PlayingBars()
                    }
                }
                .padding(.horizontal, 12)
                .frame(width: Self.width, height: Self.height, alignment: .leading)
                .glassSurface(cornerRadius: 16, interactive: true, emphasized: focused)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(focused ? .white.opacity(0.86) : .white.opacity(0.12), lineWidth: focused ? 3 : 1)
                )
            }
            .buttonStyle(RemoteButtonStyle())
            .focusEffectDisabled()
            .focused($focused)
            .scaleEffect(focused ? 1.035 : 1)
            .animation(.easeOut(duration: 0.14), value: focused)
        }
    }
}

private struct MarqueeText: View {
    var text: String
    var font: Font
    var color: Color

    @State private var textWidth: CGFloat = 0
    @State private var isScrolling = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Text(text)
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: true)
                    .background {
                        GeometryReader { textProxy in
                            Color.clear.preference(
                                key: MarqueeTextWidthKey.self,
                                value: textProxy.size.width
                            )
                        }
                    }
                    .frame(height: proxy.size.height, alignment: .center)
                    .offset(x: isScrolling ? -overflow(for: proxy.size.width) : 0)
                    .animation(
                        overflow(for: proxy.size.width) > 0
                            ? .linear(duration: scrollDuration(for: proxy.size.width))
                            .repeatForever(autoreverses: true)
                            .delay(0.8)
                            : nil,
                        value: isScrolling
                    )
            }
        }
        .clipped()
        .onPreferenceChange(MarqueeTextWidthKey.self) { width in
            textWidth = width
            restartScrolling()
        }
        .onChange(of: text) {
            restartScrolling()
        }
        .accessibilityLabel(text)
    }

    private func overflow(for containerWidth: CGFloat) -> CGFloat {
        max(0, textWidth - containerWidth)
    }

    private func scrollDuration(for containerWidth: CGFloat) -> Double {
        max(3.2, Double(overflow(for: containerWidth)) / 28)
    }

    private func restartScrolling() {
        isScrolling = false
        DispatchQueue.main.async {
            isScrolling = true
        }
    }
}

private struct MarqueeTextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct HomeView: View {
    @ObservedObject var viewModel: PlayerViewModel
    var l10n: L10n
    var restoreRequestID: Int
    var select: (MediaItem, [MediaItem]) -> Void
    var returnToMenu: () -> Void

    @State private var focusedSectionID: String?

    private static let headerScrollID = "home-header"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 42) {
                    ScreenHeader(title: l10n.text("home.title"), subtitle: l10n.text("home.subtitle"))
                        .id(Self.headerScrollID)

                    if viewModel.isLoadingHome && localizedHomeSections.isEmpty {
                        LoadingRow(title: l10n.text("home.loading"))
                    } else if localizedHomeSections.isEmpty {
                        ContentUnavailableView(l10n.text("home.empty"), systemImage: "music.note.list")
                            .frame(maxWidth: .infinity, minHeight: 480)
                    } else {
                        ForEach(localizedHomeSections) { section in
                            MediaCarousel(section: section, select: select) {
                                alignFocusedSection(section, proxy: proxy)
                            }
                            .id(section.id)
                        }
                    }
                }
                .id(homeContentID)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .onChange(of: restoreRequestID) {
                restoreHomePosition(proxy: proxy)
            }
            .onChange(of: homeContentID) {
                restoreHomePosition(proxy: proxy)
            }
        }
        .task {
            if viewModel.homeSections.isEmpty {
                await viewModel.loadHome()
            }
        }
        .onExitCommand {
            if !viewModel.navigateBackHome() {
                returnToMenu()
            }
        }
    }

    private var localizedHomeSections: [MediaSection] {
        viewModel.homeSections.map { section in
            if section.id == "listen-again" {
                return MediaSection(id: section.id, title: l10n.text("home.relisten"), items: section.items)
            }
            return section
        }
    }

    private var homeContentID: String {
        localizedHomeSections.map { section in
            let itemIDs = section.items.prefix(8).map(\.id).joined(separator: ",")
            return "\(section.id):\(itemIDs)"
        }.joined(separator: "|")
    }

    private func alignFocusedSection(_ section: MediaSection, proxy: ScrollViewProxy) {
        guard focusedSectionID != section.id else { return }
        focusedSectionID = section.id

        let targetID = section.id == localizedHomeSections.first?.id
            ? Self.headerScrollID
            : section.id

        // Run after the focus engine's own visibility adjustment so the explicit
        // section alignment wins over the nested horizontal ScrollView offset.
        DispatchQueue.main.async {
            proxy.scrollTo(targetID, anchor: .top)
        }
    }

    private func restoreHomePosition(proxy: ScrollViewProxy) {
        focusedSectionID = nil
        DispatchQueue.main.async {
            proxy.scrollTo(Self.headerScrollID, anchor: .top)
        }
    }
}

private struct MediaCarousel: View {
    var section: MediaSection
    var select: (MediaItem, [MediaItem]) -> Void
    var didFocusCard: () -> Void

    @FocusState private var focusedCardID: String?
    @State private var page = 0
    private let pageSize = 100
    private var contentItems: [MediaItem] { section.items.filter { $0.type != "playlist-page" } }
    private var pageCount: Int { max(1, (contentItems.count + pageSize - 1) / pageSize) }
    private var displayedItems: [(offset: Int, element: MediaItem)] {
        let start = min(page, pageCount - 1) * pageSize
        return Array(contentItems.enumerated().dropFirst(start).prefix(pageSize))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(section.title)
                .font(.title2.bold())
                .lineLimit(1)

            if pageCount > 1 {
                HStack(spacing: 24) {
                    Button("Previous songs") { page = max(0, page - 1) }.disabled(page == 0)
                    Text("Page \(page + 1) of \(pageCount)").font(.caption)
                    Button("Next songs") { page = min(pageCount - 1, page + 1) }.disabled(page == pageCount - 1)
                }
                .buttonStyle(.bordered)
            }
            ScrollView(.horizontal) {
                LazyHStack(spacing: 28) {
                    ForEach(displayedItems, id: \.offset) { index, media in
                        let focusID = "\(section.id)-\(index)-\(media.id)"
                        MediaCard(
                            media: media,
                            focused: focusedCardID == focusID,
                            action: {
                                select(media, section.items)
                            }
                        )
                        .focused($focusedCardID, equals: focusID)
                    }
                }
                .id(page)
                .padding(.vertical, 18)
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)
            .focusSection()
            .onChange(of: focusedCardID) {
                if focusedCardID != nil {
                    didFocusCard()
                }
                loadMoreIfNearEnd()
            }
        }
        .onChange(of: section.items.last?.tags.first) { loadMoreIfNearEnd() }
    }

    private func loadMoreIfNearEnd() {
        guard let focusedCardID,
              let index = displayedItems.first(where: { "\(section.id)-\($0.offset)-\($0.element.id)" == focusedCardID })?.offset,
              index >= max(0, contentItems.count - 10),
              let more = section.items.first(where: { $0.type == "playlist-page" }) else { return }
        select(more, [])
    }
}

private struct MediaCard: View {
    var media: MediaItem
    var focused: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                ArtworkThumb(url: media.artworkUrl, size: 245, cornerRadius: 18)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: media.isPlayable ? "play.fill" : "chevron.right")
                            .font(.system(size: 22, weight: .bold))
                            .frame(width: 52, height: 52)
                            .background(.black.opacity(0.68), in: Circle())
                            .padding(12)
                    }

                Text(media.title)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                Text(media.artist.isEmpty ? media.type ?? "" : media.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 245, alignment: .leading)
            .padding(14)
            .glassSurface(cornerRadius: 22, emphasized: focused)
        }
        .buttonStyle(RemoteButtonStyle())
        .focusEffectDisabled()
        .scaleEffect(focused ? 1.055 : 1)
        .animation(.easeOut(duration: 0.16), value: focused)
        .accessibilityLabel([media.title, media.artist].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}

private struct LoadingRow: View {
    var title: String

    var body: some View {
        HStack(spacing: 18) {
            ProgressView()
            Text(title)
                .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, minHeight: 420)
    }
}

private struct SearchView: View {
    @ObservedObject var viewModel: PlayerViewModel
    var l10n: L10n
    var select: (MediaItem, [MediaItem]) -> Void
    var returnToMenu: () -> Void

    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ScreenHeader(title: l10n.text("nav.search"), subtitle: l10n.text("search.placeholder"))

            HStack(spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(l10n.text("search.placeholder"), text: $query)
                        .font(.title3)
                        .onSubmit(runSearch)
                }
                .padding(.horizontal, 18)
                .frame(height: 64)
                .background(.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Button(l10n.text("search.button")) {
                    runSearch()
                }
                .adaptiveGlassButton(prominent: true)
                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isSearching)

                if viewModel.isSearching {
                    ProgressView()
                        .padding(.leading, 10)
                }
            }
            .frame(maxWidth: 820)
            .focusSection()

            MediaSectionList(sections: viewModel.searchSections, l10n: l10n, select: select)
        }
        .onExitCommand {
            if !viewModel.navigateBackSearch() {
                returnToMenu()
            }
        }
    }

    private func runSearch() {
        Task { await viewModel.search(query) }
    }
}

private struct ScreenHeader: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 48, weight: .bold))
                .lineLimit(1)
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct MediaSectionList: View {
    var sections: [MediaSection]
    var l10n: L10n
    var select: (MediaItem, [MediaItem]) -> Void
    var showsSectionTitle = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        if showsSectionTitle {
                            Text(section.title)
                                .font(.title2.bold())
                                .lineLimit(1)
                        }

                        LazyVStack(spacing: 10) {
                            ForEach(section.items) { media in
                                if media.type == "playlist-page" {
                                    ProgressView("Loading more songs…")
                                        .id(media.tags.first)
                                        .onAppear { select(media, []) }
                                } else {
                                    TrackRow(media: media) {
                                        select(media, section.items)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.trailing, 18)
        }
        .scrollIndicators(.hidden)
    }
}

private struct TrackRow: View {
    var media: MediaItem
    var action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 18) {
                ArtworkThumb(url: media.artworkUrl, size: 104, cornerRadius: 6)

                VStack(alignment: .leading, spacing: 5) {
                    Text(media.title)
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                    Text(secondaryText)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 20)

                if media.durationMs > 0 {
                    Text(formatDuration(media.durationMs))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Image(systemName: media.isPlayable ? "play.fill" : "chevron.right")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 34)
            }
            .padding(.horizontal, 20)
            .frame(height: 132)
            .background(.white.opacity(focused ? 0.12 : 0.045))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(focused ? .white.opacity(0.9) : .clear, lineWidth: 3)
            )
        }
        .buttonStyle(RemoteButtonStyle())
        .focusEffectDisabled()
        .focused($focused)
        .scaleEffect(focused ? 1.01 : 1)
        .animation(.easeOut(duration: 0.12), value: focused)
    }

    private var secondaryText: String {
        [media.artist, media.album].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: " · ")
    }
}

private enum PlayerPanel: Hashable {
    case queue
}

private struct PlayerScreen: View {
    @Environment(\.scenePhase) private var scenePhase

    @ObservedObject var viewModel: PlayerViewModel
    var l10n: L10n
    var onBack: () -> Void

    @State private var panel: PlayerPanel?
    @State private var controlsVisible = true
    @State private var controlsActivityID = 0
    @State private var progressScrubbing = false
    @FocusState private var playButtonFocused: Bool

    private static let controlsTimeoutNanoseconds: UInt64 = 3_500_000_000

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ArtworkBackdrop(media: displayedMedia, strong: true)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .zIndex(0)

                if let pendingMedia = viewModel.pendingMedia {
                    PlayerArtworkSurface(media: pendingMedia)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .zIndex(1)
                        .transition(.opacity)
                } else if viewModel.currentStreamHasVideo {
                    PlayerVideoSurface(
                        player: viewModel.player,
                        isPresentationActive: scenePhase == .active
                    )
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .zIndex(1)
                        .transition(.opacity)
                } else if let media = viewModel.state?.currentMedia {
                    PlayerArtworkSurface(media: media)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .zIndex(1)
                        .transition(.opacity)
                }

                if controlsVisible {
                    LinearGradient(
                        colors: [.black.opacity(0.12), .black.opacity(0.54), .black.opacity(0.92)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .allowsHitTesting(false)
                    .zIndex(2)
                    .transition(.opacity)
                }

                if viewModel.pendingMedia == nil, let media = viewModel.state?.currentMedia {
                    PlayerControlsOverlay(
                        screenSize: proxy.size,
                        media: media,
                        viewModel: viewModel,
                        l10n: l10n,
                        panel: panel,
                        controlsVisible: controlsVisible,
                        playButtonFocused: $playButtonFocused,
                        progressScrubbing: $progressScrubbing,
                        onActivity: registerActivity,
                        togglePanel: togglePanel
                    )
                    .zIndex(3)
                    .transition(.opacity)
                } else if displayedMedia == nil {
                    ContentUnavailableView(l10n.text("player.noMedia"), systemImage: "music.note")
                        .padding(.bottom, 80)
                        .zIndex(3)
                }

                if viewModel.isPreparingPlayback {
                    LoadingOverlay(title: l10n.text("player.loading"))
                        .allowsHitTesting(false)
                        .zIndex(4)
                }

                if controlsVisible, let panel, let media = viewModel.state?.currentMedia {
                    PlayerSidePanel(
                        panel: panel,
                        media: media,
                        viewModel: viewModel,
                        l10n: l10n,
                        close: { self.panel = nil }
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topTrailing)
                    .padding(.top, 145)
                    .padding(.trailing, 74)
                    .padding(.bottom, 350)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(5)
                }

                #if os(tvOS)
                    if !controlsVisible, viewModel.state?.currentMedia != nil {
                        HiddenPlayerRemoteObserver(
                            onActivity: registerActivity,
                            onExit: onBack
                        )
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .zIndex(6)
                    }
                #endif
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .background(Color.black)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .simultaneousGesture(TapGesture().onEnded(registerActivity))
        .onMoveCommand { _ in
            registerActivity()
        }
        .onPlayPauseCommand {
            registerActivity()
            Task { await viewModel.togglePlayPause() }
        }
        .onExitCommand {
            if controlsVisible {
                hideControls()
            } else {
                onBack()
            }
        }
        .onAppear {
            controlsVisible = true
            playButtonFocused = true
            registerActivity()
        }
        .onChange(of: panel) {
            if panel == nil {
                playButtonFocused = true
            }
            registerActivity()
        }
        .onChange(of: viewModel.state?.status) {
            registerActivity()
        }
        .onChange(of: viewModel.state?.currentMediaId) {
            registerActivity()
        }
        .onChange(of: viewModel.currentStreamHasVideo) {
            registerActivity()
        }
        .task(id: controlsActivityID) {
            guard controlsVisible else { return }
            try? await Task.sleep(nanoseconds: Self.controlsTimeoutNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if progressScrubbing {
                    registerActivity()
                    return
                }
                hideControls()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: panel)
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
    }

    private func togglePanel(_ nextPanel: PlayerPanel) {
        panel = panel == nextPanel ? nil : nextPanel
        registerActivity()
    }

    private var displayedMedia: MediaItem? {
        viewModel.pendingMedia ?? viewModel.state?.currentMedia
    }

    private func registerActivity() {
        let wasHidden = !controlsVisible
        controlsVisible = true
        controlsActivityID &+= 1

        guard wasHidden else { return }
        DispatchQueue.main.async {
            playButtonFocused = true
        }
    }

    private func hideControls() {
        panel = nil
        progressScrubbing = false
        controlsVisible = false
        playButtonFocused = false
    }
}

private struct PlayerMetadataOverlay: View {
    private static let horizontalInset: CGFloat = 86
    private static let topInset: CGFloat = 72

    var screenSize: CGSize
    var media: MediaItem

    var body: some View {
        let width = max(0, screenSize.width - Self.horizontalInset * 2)

        HStack(alignment: .center, spacing: 18) {
            ArtworkThumb(url: media.artworkUrl, size: 112, cornerRadius: 6)

            VStack(alignment: .leading, spacing: 6) {
                Text(media.title)
                    .font(.system(size: 42, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text(media.artist)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 20)
        }
        .frame(width: width, alignment: .leading)
        .position(
            x: screenSize.width / 2,
            y: Self.topInset + 56
        )
        .frame(width: screenSize.width, height: screenSize.height)
    }
}

private struct PlayerControlsOverlay: View {
    private static let horizontalInset: CGFloat = 86
    private static let bottomInset: CGFloat = 86

    var screenSize: CGSize
    var media: MediaItem
    @ObservedObject var viewModel: PlayerViewModel
    var l10n: L10n
    var panel: PlayerPanel?
    var controlsVisible: Bool
    var playButtonFocused: FocusState<Bool>.Binding
    var progressScrubbing: Binding<Bool>
    var onActivity: () -> Void
    var togglePanel: (PlayerPanel) -> Void

    var body: some View {
        let width = max(0, screenSize.width - Self.horizontalInset * 2)
        let centerY = max(
            PlayerBottomBar.layoutHeight / 2,
            screenSize.height - Self.bottomInset - PlayerBottomBar.layoutHeight / 2
        )

        PlayerBottomBar(
            media: media,
            viewModel: viewModel,
            l10n: l10n,
            panel: panel,
            playButtonFocused: playButtonFocused,
            progressScrubbing: progressScrubbing,
            onActivity: onActivity,
            togglePanel: togglePanel
        )
        .frame(width: width, height: PlayerBottomBar.layoutHeight, alignment: .topLeading)
        .position(x: screenSize.width / 2, y: centerY)
        .opacity(controlsVisible ? 1 : 0)
        .disabled(panel != nil || !controlsVisible)
        .allowsHitTesting(controlsVisible)
        .accessibilityHidden(!controlsVisible)
        .frame(width: screenSize.width, height: screenSize.height)
    }
}

#if os(tvOS)
    private struct PlayerVideoSurface: UIViewRepresentable {
        let player: AVPlayer
        let isPresentationActive: Bool

        func makeUIView(context _: Context) -> PlayerLayerView {
            let view = PlayerLayerView()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
            view.isOpaque = false
            view.playerLayer.backgroundColor = UIColor.clear.cgColor
            view.playerLayer.isOpaque = false
            view.playerLayer.player = isPresentationActive ? player : nil
            view.playerLayer.videoGravity = .resizeAspectFill
            return view
        }

        func updateUIView(_ uiView: PlayerLayerView, context _: Context) {
            uiView.playerLayer.player = isPresentationActive ? player : nil
        }

        static func dismantleUIView(_ uiView: PlayerLayerView, coordinator _: ()) {
            uiView.playerLayer.player = nil
        }
    }

    private final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass {
            AVPlayerLayer.self
        }

        var playerLayer: AVPlayerLayer {
            layer as! AVPlayerLayer
        }
    }

    private struct HiddenPlayerRemoteObserver: UIViewControllerRepresentable {
        var onActivity: () -> Void
        var onExit: () -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(onActivity: onActivity, onExit: onExit)
        }

        func makeUIViewController(context: Context) -> HiddenPlayerRemoteViewController {
            let controller = HiddenPlayerRemoteViewController()
            update(controller, coordinator: context.coordinator)
            DispatchQueue.main.async {
                controller.becomeFirstResponder()
            }
            return controller
        }

        func updateUIViewController(_ controller: HiddenPlayerRemoteViewController, context: Context) {
            update(controller, coordinator: context.coordinator)
            DispatchQueue.main.async {
                controller.becomeFirstResponder()
            }
        }

        static func dismantleUIViewController(
            _ controller: HiddenPlayerRemoteViewController,
            coordinator _: Coordinator
        ) {
            controller.resignFirstResponder()
        }

        private func update(_ controller: HiddenPlayerRemoteViewController, coordinator: Coordinator) {
            coordinator.onActivity = onActivity
            coordinator.onExit = onExit
            controller.coordinator = coordinator
        }

        final class Coordinator {
            var onActivity: () -> Void
            var onExit: () -> Void

            init(onActivity: @escaping () -> Void, onExit: @escaping () -> Void) {
                self.onActivity = onActivity
                self.onExit = onExit
            }
        }
    }

    private final class HiddenPlayerRemoteViewController: UIViewController {
        var coordinator: HiddenPlayerRemoteObserver.Coordinator?

        override var canBecomeFirstResponder: Bool { true }

        override func loadView() {
            let view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = true
            self.view = view
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if presses.contains(where: { $0.type == .menu }) {
                coordinator?.onExit()
                return
            }

            if presses.contains(where: { $0.type != .menu }) {
                coordinator?.onActivity()
            }
            super.pressesBegan(presses, with: event)
        }
    }
#endif

private struct PlayerArtworkSurface: View {
    var media: MediaItem

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black

                AsyncImage(url: media.artworkUrl) { image in
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } placeholder: {
                    ArtworkBackdrop(media: media, strong: true)
                }

                Color.black.opacity(0.22)

                LinearGradient(
                    colors: [.clear, .black.opacity(0.82)],
                    startPoint: .center,
                    endPoint: .bottom
                )
            }
        }
    }
}

private struct PlayerControls: View {
    @ObservedObject var viewModel: PlayerViewModel
    var l10n: L10n

    var body: some View {
        HStack(spacing: 22) {
            ControlButton(icon: "backward.end.fill", label: l10n.text("player.previous")) {
                Task { await viewModel.previous() }
            }

            ControlButton(icon: "forward.end.fill", label: l10n.text("player.next")) {
                Task { await viewModel.next() }
            }

            ControlButton(
                icon: viewModel.state?.shuffle == true ? "shuffle.circle.fill" : "shuffle",
                label: l10n.text("player.shuffle"),
                active: viewModel.state?.shuffle == true
            ) {
                Task { await viewModel.toggleShuffle() }
            }

            ControlButton(
                icon: viewModel.state?.repeatMode == "one" ? "repeat.1.circle.fill" : "repeat.1",
                label: l10n.text("player.repeatOne"),
                active: viewModel.state?.repeatMode == "one"
            ) {
                Task { await viewModel.toggleRepeatOne() }
            }

            ControlButton(
                icon: viewModel.state?.currentMedia?.likeStatus == "LIKE" ? "hand.thumbsup.fill" : "hand.thumbsup",
                label: l10n.text("player.like"),
                active: viewModel.state?.currentMedia?.likeStatus == "LIKE",
                activeColor: .green
            ) {
                Task { await viewModel.likeCurrent() }
            }
            .disabled(viewModel.isUpdatingRating)

            ControlButton(
                icon: viewModel.state?.currentMedia?.likeStatus == "DISLIKE" ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                label: l10n.text("player.dislike"),
                active: viewModel.state?.currentMedia?.likeStatus == "DISLIKE",
                activeColor: .red
            ) {
                Task { await viewModel.dislikeCurrent() }
            }
            .disabled(viewModel.isUpdatingRating)
        }
        .focusSection()
    }
}

private struct PlayerBottomBar: View {
    static let layoutHeight: CGFloat = 382

    var media: MediaItem
    @ObservedObject var viewModel: PlayerViewModel
    var l10n: L10n
    var panel: PlayerPanel?
    var playButtonFocused: FocusState<Bool>.Binding
    var progressScrubbing: Binding<Bool>
    var onActivity: () -> Void
    var togglePanel: (PlayerPanel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 18) {
                ArtworkThumb(url: media.artworkUrl, size: 126, cornerRadius: 6)

                VStack(alignment: .leading, spacing: 6) {
                    Text(media.title)
                        .font(.system(size: 46, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    Text(media.artist)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }

            HStack(alignment: .center, spacing: 24) {
                PrimaryPlayButton(
                    viewModel: viewModel,
                    l10n: l10n,
                    focused: playButtonFocused,
                    disabled: progressScrubbing.wrappedValue
                )

                PlayerProgressStrip(
                    progress: viewModel.playbackProgress,
                    l10n: l10n,
                    scrubbing: progressScrubbing,
                    onActivity: onActivity,
                    seek: viewModel.seek
                )
                .frame(maxWidth: .infinity)
            }

            HStack(alignment: .center, spacing: 22) {
                PlayerControls(viewModel: viewModel, l10n: l10n)

                Spacer()

                Button { togglePanel(.queue) } label: {
                    Label(l10n.text("player.queue"), systemImage: "list.bullet")
                        .font(.headline.weight(.semibold))
                }
                .adaptiveGlassButton(selected: panel == .queue)
            }
            .focusSection()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 18)
        .focusSection()
    }
}

struct PlayerProgressStrip: View {
    @ObservedObject var progress: PlaybackProgress
    var l10n: L10n
    @Binding var scrubbing: Bool
    var onActivity: () -> Void
    var seek: (Int) -> Void
    var accentColor: Color = .red
    var showsBackground = true

    var body: some View {
        ProgressStrip(
            currentMs: progress.currentMs,
            durationMs: progress.durationMs,
            l10n: l10n,
            scrubbing: $scrubbing,
            onActivity: onActivity,
            seek: seek,
            accentColor: accentColor,
            showsBackground: showsBackground
        )
    }
}

private struct PlayerSidePanel: View {
    var panel: PlayerPanel
    var media: MediaItem
    @ObservedObject var viewModel: PlayerViewModel
    var l10n: L10n
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(l10n.text("player.queue"), systemImage: "list.bullet")
                    .font(.title2.bold())
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .frame(width: 42, height: 42)
                }
                .adaptiveGlassButton()
                .accessibilityLabel(l10n.text("player.closePanel"))
            }

            Divider()

            switch panel {
            case .queue:
                queueContent
            }
        }
        .padding(24)
        .frame(width: 620, height: 560, alignment: .topLeading)
        .glassSurface(cornerRadius: 28, emphasized: true)
    }

    @ViewBuilder
    private var queueContent: some View {
        let queue = viewModel.state?.queue ?? []
        if queue.isEmpty {
            ContentUnavailableView(l10n.text("player.emptyQueue"), systemImage: "list.bullet")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                AdaptiveGlassGroup(spacing: 10) {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(queue.enumerated()), id: \.offset) { _, item in
                            QueueItemButton(item: item, isCurrent: item.id == media.id) {
                                if await viewModel.play(item, queue: queue) {
                                    close()
                                }
                            }
                        }
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct QueueItemButton: View {
    var item: MediaItem
    var isCurrent: Bool
    var action: () async -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 14) {
                ArtworkThumb(url: item.artworkUrl, size: 72, cornerRadius: 8)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                    Text(item.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isCurrent {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 92)
            .glassSurface(
                cornerRadius: 14,
                interactive: true,
                emphasized: isCurrent || focused,
                highlightColor: isCurrent ? .red : .white
            )
        }
        .buttonStyle(RemoteButtonStyle())
        .focusEffectDisabled()
        .focused($focused)
        .scaleEffect(focused ? 1.025 : 1)
        .animation(.easeOut(duration: 0.14), value: focused)
    }
}

private struct PrimaryPlayButton: View {
    @ObservedObject var viewModel: PlayerViewModel
    var l10n: L10n
    var focused: FocusState<Bool>.Binding
    var disabled = false

    var body: some View {
        Button {
            Task { await viewModel.togglePlayPause() }
        } label: {
            Image(systemName: viewModel.state?.status == "playing" ? "pause.fill" : "play.fill")
                .font(.system(size: 34, weight: .bold))
                .frame(width: 82, height: 82)
        }
        .adaptiveGlassButton(prominent: true)
        .controlSize(.large)
        .tint(.white)
        .foregroundStyle(.black)
        .focused(focused)
        .disabled(disabled)
        .accessibilityLabel(viewModel.state?.status == "playing" ? l10n.text("player.pause") : l10n.text("player.play"))
    }
}

private struct ControlButton: View {
    var icon: String
    var label: String
    var active = false
    var activeColor: Color = .green
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 25, weight: .bold))
                .frame(width: 58, height: 58)
        }
        .adaptiveGlassButton(selected: active)
        .controlSize(.regular)
        .tint(buttonTint)
        .foregroundStyle(.white)
        .accessibilityLabel(label)
    }

    private var buttonTint: Color {
        if active {
            return activeColor
        }
        return .white.opacity(0.22)
    }
}

private struct ProgressStrip: View {
    var currentMs: Int
    var durationMs: Int
    var l10n: L10n
    @Binding var scrubbing: Bool
    var onActivity: () -> Void
    var seek: (Int) -> Void
    var accentColor: Color = .red
    var showsBackground = true

    @State private var scrubMs = 0
    @State private var scrubRunDirection: ScrubDirection?
    @State private var scrubRunCount = 0
    @State private var lastScrubMoveAt = Date.distantPast
    @State private var scrubHoldTask: Task<Void, Never>?
    @State private var lastPressLifecycleAt = Date.distantPast
    @State private var lastObservedSelectAt = Date.distantPast
    @FocusState private var focused: Bool

    var body: some View {
        progressControl
            .buttonStyle(RemoteButtonStyle())
            .focusEffectDisabled()
            .disabled(durationMs <= 0)
            .focused($focused)
            .onMoveCommand(perform: handleScrubMove)
            .onChange(of: focused) {
                if !focused && !scrubbing {
                    stopScrubHold()
                }
            }
            .onChange(of: currentMs) {
                if !scrubbing {
                    scrubMs = currentMs
                }
            }
            .onChange(of: durationMs) {
                scrubMs = clamped(scrubMs)
                if durationMs <= 0 {
                    cancelScrubbing()
                }
            }
            .onChange(of: scrubbing) {
                if !scrubbing {
                    stopScrubHold()
                }
            }
            .onDisappear {
                stopScrubHold()
            }
            .accessibilityLabel(l10n.text("player.position"))
            .accessibilityValue(
                "\(formatDuration(displayedMs)), \(l10n.text("player.remaining")) \(formatDuration(max(0, durationMs - displayedMs)))"
            )
    }

    @ViewBuilder
    private var progressControl: some View {
        Button(action: handleButtonSelect) {
            progressLabel
        }
        .overlay {
            #if os(tvOS)
                if scrubbing {
                    ScrubPressObserver(
                        onDirectionBegan: handleObservedDirectionBegan,
                        onDirectionEnded: { _ in stopScrubHold() },
                        onSelect: handleObservedSelect,
                        onCancel: cancelScrubbing
                    )
                }
            #endif
        }
    }

    @ViewBuilder
    private var progressLabel: some View {
        if showsBackground {
            progressContents
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassSurface(
                    cornerRadius: 16,
                    interactive: true,
                    emphasized: focused || scrubbing,
                    highlightColor: scrubbing ? accentColor : .white
                )
        } else {
            progressContents
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }

    private var progressContents: some View {
        VStack(spacing: 10) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(trackOpacity))
                    Capsule()
                        .fill(accentColor)
                        .frame(width: proxy.size.width * displayedProgress)
                        .animation(scrubbing ? nil : .linear(duration: 0.95), value: currentMs)

                    Circle()
                        .fill(.white)
                        .frame(width: knobSize, height: knobSize)
                        .offset(x: max(0, proxy.size.width * displayedProgress - knobSize / 2))
                        .opacity(durationMs > 0 ? 1 : 0)
                }
            }
            .frame(height: trackHeight)

            HStack {
                Text(formatDuration(displayedMs))
                Spacer()
                Text("-\(formatDuration(max(0, durationMs - displayedMs)))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(scrubbing ? .white : .secondary)
        }
    }

    private func handleButtonSelect() {
        guard Date().timeIntervalSince(lastObservedSelectAt) > 0.25 else { return }
        toggleScrubbing()
    }

    private func handleObservedSelect() {
        lastObservedSelectAt = Date()
        toggleScrubbing()
    }

    private func toggleScrubbing() {
        guard durationMs > 0 else { return }
        onActivity()
        if scrubbing {
            seek(clamped(scrubMs))
            scrubbing = false
            stopScrubHold()
        } else {
            scrubMs = clamped(currentMs)
            scrubbing = true
            stopScrubHold()
        }
    }

    private func handleScrubMove(_ direction: MoveCommandDirection) {
        guard Date().timeIntervalSince(lastPressLifecycleAt) > 0.18 else { return }
        guard scrubbing, let scrubDirection = ScrubDirection(direction) else { return }

        updateScrubAcceleration(direction: scrubDirection)
        onActivity()

        let step = scrubStepMs(for: scrubRunCount)
        moveScrub(scrubDirection, by: step)
    }

    private func handleObservedDirectionBegan(_ direction: ScrubDirection) {
        lastPressLifecycleAt = Date()
        beginScrubHold(direction)
    }

    private func beginScrubHold(_ direction: ScrubDirection) {
        guard scrubbing else { return }
        stopScrubHold(resetAcceleration: false)
        scrubRunDirection = direction
        scrubRunCount = 1
        lastScrubMoveAt = Date()
        onActivity()
        moveScrub(direction, by: 1_000)

        let startedAt = Date()
        scrubHoldTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(330))
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(startedAt)
                onActivity()
                moveScrub(direction, by: scrubHoldStepMs(elapsed: elapsed))
                try? await Task.sleep(for: .milliseconds(110))
            }
        }
    }

    private func moveScrub(_ direction: ScrubDirection, by step: Int) {
        switch direction {
        case .left:
            scrubMs = clamped(scrubMs - step)
        case .right:
            scrubMs = clamped(scrubMs + step)
        }
    }

    private func updateScrubAcceleration(direction: ScrubDirection) {
        let now = Date()
        if scrubRunDirection == direction,
           now.timeIntervalSince(lastScrubMoveAt) < 0.55 {
            scrubRunCount += 1
        } else {
            scrubRunDirection = direction
            scrubRunCount = 1
        }
        lastScrubMoveAt = now
    }

    private var displayedMs: Int {
        scrubbing ? scrubMs : currentMs
    }

    private var displayedProgress: CGFloat {
        guard durationMs > 0 else { return 0 }
        return min(1, max(0, CGFloat(displayedMs) / CGFloat(durationMs)))
    }

    private var trackOpacity: Double {
        if !showsBackground { return scrubbing ? 0.26 : focused ? 0.18 : 0.12 }
        if scrubbing { return 0.42 }
        return focused ? 0.34 : 0.2
    }

    private var trackHeight: CGFloat {
        scrubbing || focused ? 16 : 8
    }

    private var knobSize: CGFloat {
        scrubbing || focused ? 24 : 14
    }

    private func scrubStepMs(for count: Int) -> Int {
        switch count {
        case ...3:
            return 1_000
        case 4 ... 7:
            return 2_000
        case 8 ... 12:
            return 5_000
        case 13 ... 20:
            return 10_000
        case 21 ... 32:
            return 30_000
        default:
            return 60_000
        }
    }

    private func scrubHoldStepMs(elapsed: TimeInterval) -> Int {
        switch elapsed {
        case ..<1.1:
            return 1_000
        case ..<2.2:
            return 2_000
        case ..<4.0:
            return 5_000
        case ..<7.0:
            return 10_000
        case ..<12.0:
            return 30_000
        default:
            return 60_000
        }
    }

    private func clamped(_ value: Int) -> Int {
        min(max(0, value), max(0, durationMs))
    }

    private func cancelScrubbing() {
        scrubbing = false
        stopScrubHold()
    }

    private func stopScrubHold(resetAcceleration: Bool = true) {
        scrubHoldTask?.cancel()
        scrubHoldTask = nil
        if resetAcceleration {
            scrubRunDirection = nil
            scrubRunCount = 0
            lastScrubMoveAt = .distantPast
        }
    }
}

private enum ScrubDirection: Hashable {
    case left
    case right

    init?(_ direction: MoveCommandDirection) {
        switch direction {
        case .left:
            self = .left
        case .right:
            self = .right
        default:
            return nil
        }
    }
}

#if os(tvOS)
    private struct ScrubPressObserver: UIViewControllerRepresentable {
        var onDirectionBegan: (ScrubDirection) -> Void
        var onDirectionEnded: (ScrubDirection) -> Void
        var onSelect: () -> Void
        var onCancel: () -> Void

        func makeUIViewController(context: Context) -> ScrubPressViewController {
            let controller = ScrubPressViewController()
            update(controller, coordinator: context.coordinator)
            DispatchQueue.main.async {
                controller.becomeFirstResponder()
            }
            return controller
        }

        func updateUIViewController(_ controller: ScrubPressViewController, context: Context) {
            update(controller, coordinator: context.coordinator)
            DispatchQueue.main.async {
                controller.becomeFirstResponder()
            }
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(
                onDirectionBegan: onDirectionBegan,
                onDirectionEnded: onDirectionEnded,
                onSelect: onSelect,
                onCancel: onCancel
            )
        }

        static func dismantleUIViewController(
            _ controller: ScrubPressViewController,
            coordinator _: Coordinator
        ) {
            controller.endActiveDirections()
            controller.resignFirstResponder()
        }

        private func update(_ controller: ScrubPressViewController, coordinator: Coordinator) {
            coordinator.onDirectionBegan = onDirectionBegan
            coordinator.onDirectionEnded = onDirectionEnded
            coordinator.onSelect = onSelect
            coordinator.onCancel = onCancel
            controller.coordinator = coordinator
        }

        final class Coordinator {
            var onDirectionBegan: (ScrubDirection) -> Void
            var onDirectionEnded: (ScrubDirection) -> Void
            var onSelect: () -> Void
            var onCancel: () -> Void

            init(
                onDirectionBegan: @escaping (ScrubDirection) -> Void,
                onDirectionEnded: @escaping (ScrubDirection) -> Void,
                onSelect: @escaping () -> Void,
                onCancel: @escaping () -> Void
            ) {
                self.onDirectionBegan = onDirectionBegan
                self.onDirectionEnded = onDirectionEnded
                self.onSelect = onSelect
                self.onCancel = onCancel
            }
        }
    }

    private final class ScrubPressViewController: UIViewController {
        var coordinator: ScrubPressObserver.Coordinator?
        private var activeDirections = Set<ScrubDirection>()

        override var canBecomeFirstResponder: Bool { true }

        override func loadView() {
            let view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = true
            self.view = view
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var handled = false
            for press in presses {
                switch press.type {
                case .leftArrow:
                    handled = begin(.left) || handled
                case .rightArrow:
                    handled = begin(.right) || handled
                case .select:
                    coordinator?.onSelect()
                    handled = true
                case .menu:
                    coordinator?.onCancel()
                    handled = true
                default:
                    break
                }
            }

            if !handled {
                super.pressesBegan(presses, with: event)
            }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if !endDirections(in: presses) {
                super.pressesEnded(presses, with: event)
            }
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if !endDirections(in: presses) {
                super.pressesCancelled(presses, with: event)
            }
        }

        private func begin(_ direction: ScrubDirection) -> Bool {
            guard activeDirections.insert(direction).inserted else { return true }
            coordinator?.onDirectionBegan(direction)
            return true
        }

        private func endDirections(in presses: Set<UIPress>) -> Bool {
            var handled = false
            for press in presses {
                switch press.type {
                case .leftArrow:
                    end(.left)
                    handled = true
                case .rightArrow:
                    end(.right)
                    handled = true
                default:
                    break
                }
            }
            return handled
        }

        private func end(_ direction: ScrubDirection) {
            guard activeDirections.remove(direction) != nil else { return }
            coordinator?.onDirectionEnded(direction)
        }

        func endActiveDirections() {
            for direction in activeDirections {
                coordinator?.onDirectionEnded(direction)
            }
            activeDirections.removeAll()
        }
    }
#endif

private struct SettingsView: View {
    private enum ConnectionFocus: Hashable {
        case serverURL
        case manualConnect
        case refreshDiscovery
        case discoveredServer(String)
        case language
    }

    @ObservedObject var settings: ServerSettings
    @ObservedObject var discovery: ServerDiscovery
    @ObservedObject var viewModel: PlayerViewModel
    var l10n: L10n
    var returnToMenu: () -> Void

    @AppStorage("YTBMusicTV.musicLayout") private var musicLayout = true
    @AppStorage("YTBMusicTV.motionArtwork") private var motionArtwork = true
    @AppStorage("YTBMusicTV.crossfadeSeconds") private var crossfadeSeconds = 5.0
    @State private var deviceCode = ""
    @State private var isAssociating = false
    @FocusState private var connectionFocus: ConnectionFocus?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ScreenHeader(title: l10n.text("settings.title"), subtitle: l10n.text("settings.connection"))

                SettingsSection(title: l10n.text("settings.connection")) {
                    HStack(spacing: 16) {
                        TextField(l10n.text("settings.serverURL"), text: $settings.serverBaseURLString)
                            .settingsField()
                            .focused($connectionFocus, equals: .serverURL)
                            .onMoveCommand { direction in
                                if direction == .down {
                                    connectionFocus = .refreshDiscovery
                                }
                            }

                        Label(
                            viewModel.isConnected
                                ? l10n.text("settings.connected")
                                : l10n.text("settings.disconnected"),
                            systemImage: viewModel.isConnected
                                ? "checkmark.circle.fill"
                                : "xmark.circle.fill"
                        )
                        .foregroundStyle(viewModel.isConnected ? .green : .red)

                        Button(l10n.text("settings.connect")) {
                            guard let baseURL = settings.serverBaseURL else {
                                viewModel.reportError(l10n.text("settings.invalidURL"))
                                return
                            }
                            connect(to: baseURL)
                        }
                        .adaptiveGlassButton(prominent: true)
                        .disabled(viewModel.isConnecting)
                        .focused($connectionFocus, equals: .manualConnect)
                        .onMoveCommand { direction in
                            if direction == .down {
                                connectionFocus = .refreshDiscovery
                            }
                        }
                    }

                    HStack {
                        Text(l10n.text("settings.discoveredServers"))
                            .font(.headline)
                        Spacer()
                        Button {
                            discovery.refresh()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .adaptiveGlassButton()
                        .focused($connectionFocus, equals: .refreshDiscovery)
                        .onMoveCommand { direction in
                            switch direction {
                            case .up:
                                connectionFocus = .manualConnect
                            case .down:
                                connectionFocus = discovery.servers.first
                                    .map { .discoveredServer($0.id) } ?? .language
                            default:
                                break
                            }
                        }
                        .accessibilityLabel(l10n.text("settings.refreshDiscovery"))
                    }

                    if discovery.servers.isEmpty {
                        Text(
                            discovery.isSearching
                                ? l10n.text("settings.searchingServers")
                                : l10n.text("settings.noServersFound")
                        )
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(discovery.servers) { server in
                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(server.name)
                                        .font(.headline)
                                    Text(server.url.absoluteString)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    settings.selectServer(server.url)
                                    connect(to: server.url)
                                } label: {
                                    Label(l10n.text("settings.connect"), systemImage: "link")
                                }
                                .adaptiveGlassButton()
                                .disabled(viewModel.isConnecting)
                                .focused($connectionFocus, equals: .discoveredServer(server.id))
                                .onMoveCommand { direction in
                                    moveDiscoveryFocus(from: server.id, direction: direction)
                                }
                            }
                        }
                    }
                }
                .focusSection()

                SettingsSection(title: l10n.text("settings.language")) {
                    Picker(l10n.text("settings.language"), selection: $settings.languageCode) {
                        ForEach(L10n.languageOptions) { option in
                            Text(l10n.resolvedLanguage == "zh" ? option.zh : option.en).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 520, alignment: .leading)
                    .focused($connectionFocus, equals: .language)
                    .onMoveCommand { direction in
                        if direction == .up {
                            connectionFocus = discovery.servers.last
                                .map { .discoveredServer($0.id) } ?? .refreshDiscovery
                        }
                    }
                }

                if viewModel.isConnected {
                    SettingsSection(title: l10n.text("settings.association")) {
                        HStack(spacing: 16) {
                            TextField(l10n.text("settings.deviceCode"), text: $deviceCode)
                                .settingsField()

                            Button {
                                associate()
                            } label: {
                                Label(l10n.text("settings.associate"), systemImage: "link.badge.plus")
                            }
                            .adaptiveGlassButton(prominent: true)
                            .disabled(isAssociating || !isValidDeviceCode)

                            if viewModel.isAssociated {
                                Label(l10n.text("settings.associated"), systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Label(
                                    l10n.text("settings.notAssociated"),
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .foregroundStyle(.yellow)
                            }
                        }
                    }
                }

                SettingsSection(title: "Music presentation") {
                    Toggle("Apple Music style player", isOn: $musicLayout)
                    Toggle("Animated album artwork", isOn: $motionArtwork)
                    Picker("Crossfade", selection: $crossfadeSeconds) {
                        Text("Off").tag(0.0)
                        ForEach(1...12, id: \.self) { Text("\($0) seconds").tag(Double($0)) }
                    }
                    .pickerStyle(.menu)
                    Text("Motion artwork and lyrics depend on available matches. Crossfade overlaps adjacent songs when the next stream is ready.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                SettingsSection(title: l10n.text("settings.features")) {
                    Toggle(l10n.text("settings.adFiltering"), isOn: adblockBinding)
                    Toggle(l10n.text("settings.skipDisliked"), isOn: skipDislikedBinding)
                    Toggle(l10n.text("settings.preferVideo"), isOn: preferVideoBinding)

                    Picker(l10n.text("settings.quality"), selection: qualityBinding) {
                        Text("Best").tag("best")
                        Text("Efficient").tag("bestefficiency")
                        Text("720p").tag("720p")
                        Text("480p").tag("480p")
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 520, alignment: .leading)

                    TextField(l10n.text("settings.selectedLibrary"), text: selectedLibraryBinding)
                        .settingsField()
                }
                .disabled(viewModel.config == nil)
            }
            .padding(.trailing, 18)
        }
        .scrollIndicators(.hidden)
        .task {
            discovery.start()
        }
        .onChange(of: discovery.servers) {
            guard case let .discoveredServer(serverID) = connectionFocus,
                  !discovery.servers.contains(where: { $0.id == serverID })
            else {
                return
            }
            connectionFocus = .refreshDiscovery
        }
        .onExitCommand(perform: returnToMenu)
    }

    private func moveDiscoveryFocus(from serverID: String, direction: MoveCommandDirection) {
        guard let index = discovery.servers.firstIndex(where: { $0.id == serverID }) else {
            connectionFocus = .refreshDiscovery
            return
        }

        switch direction {
        case .up:
            if index == discovery.servers.startIndex {
                connectionFocus = .refreshDiscovery
            } else {
                connectionFocus = .discoveredServer(discovery.servers[index - 1].id)
            }
        case .down:
            let nextIndex = index + 1
            if discovery.servers.indices.contains(nextIndex) {
                connectionFocus = .discoveredServer(discovery.servers[nextIndex].id)
            } else {
                connectionFocus = .language
            }
        default:
            break
        }
    }

    private func connect(to url: URL) {
        Task {
            await viewModel.connect(to: url, accessToken: settings.serverAccessToken)
            if viewModel.isConnected,
               viewModel.connectedServerID != settings.associatedServerID || !viewModel.isAssociated {
                settings.clearAssociation()
            }
        }
    }

    private func associate() {
        guard !isAssociating else { return }
        isAssociating = true
        Task {
            defer { isAssociating = false }
            guard
                let serverID = viewModel.connectedServerID,
                let result = await viewModel.associate(deviceCode: deviceCode)
            else {
                return
            }
            settings.saveAssociation(result, serverID: serverID)
            deviceCode = ""
        }
    }

    private var isValidDeviceCode: Bool {
        deviceCode.count == 6 && deviceCode.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private var adblockBinding: Binding<Bool> {
        Binding(
            get: { viewModel.config?.features.adblock.enabled ?? false },
            set: { value in
                viewModel.updateConfig { $0.features.adblock.enabled = value }
            }
        )
    }

    private var skipDislikedBinding: Binding<Bool> {
        Binding(
            get: { viewModel.config?.features.skipDislikedSongs.enabled ?? false },
            set: { value in
                viewModel.updateConfig { $0.features.skipDislikedSongs.enabled = value }
            }
        )
    }

    private var preferVideoBinding: Binding<Bool> {
        Binding(
            get: { viewModel.config?.playback.preferVideo ?? false },
            set: { value in
                viewModel.updateConfig { $0.playback.preferVideo = value }
            }
        )
    }

    private var qualityBinding: Binding<String> {
        Binding(
            get: { viewModel.config?.playback.defaultQuality ?? "best" },
            set: { value in
                viewModel.updateConfig { $0.playback.defaultQuality = value }
            }
        )
    }

    private var selectedLibraryBinding: Binding<String> {
        Binding(
            get: { viewModel.config?.playback.selectedLibrary ?? "" },
            set: { value in
                viewModel.updateConfig(debounce: .milliseconds(600)) {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    $0.playback.selectedLibrary = trimmed.isEmpty ? nil : value
                }
            }
        )
    }
}

private struct SettingsSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title2.bold())
            content()
        }
        .padding(18)
        .glassSurface(cornerRadius: 18)
    }
}

private struct ErrorBanner: View {
    var message: String
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.headline)
                .lineLimit(2)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .frame(width: 36, height: 36)
            }
            .adaptiveGlassButton()
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: 980)
        .glassSurface(cornerRadius: 18, emphasized: true)
    }
}

private struct ArtworkBackdrop: View {
    var media: MediaItem?
    var strong = false

    var body: some View {
        ZStack {
            Color.black

            AsyncImage(url: media?.artworkUrl) { image in
                image
                    .resizable()
                    .scaledToFill()
                    .blur(radius: strong ? 34 : 58)
                    .scaleEffect(1.16)
                    .opacity(strong ? 0.52 : 0.36)
            } placeholder: {
                LinearGradient(
                    colors: [.black, .gray.opacity(0.22), .black],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            RadialGradient(
                colors: [.clear, .black.opacity(strong ? 0.45 : 0.68)],
                center: .center,
                startRadius: 80,
                endRadius: 900
            )

            LinearGradient(
                colors: [.black.opacity(0.12), .black.opacity(0.82)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

struct ArtworkThumb: View {
    var url: URL?
    var size: CGFloat
    var cornerRadius: CGFloat

    var body: some View {
        AsyncImage(url: url) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            Rectangle()
                .fill(.white.opacity(0.12))
                .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

private struct LoadingOverlay: View {
    var title: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(title)
                .font(.headline)
        }
        .padding(24)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct PlayingBars: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0 ..< 4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.red)
                        .frame(width: 4, height: 8 + abs(sin(time * 3.2 + Double(index))) * 17)
                }
            }
            .frame(width: 28, height: 28)
        }
    }
}

private extension View {
    func settingsField() -> some View {
        padding(.horizontal, 16)
            .frame(height: 58)
            .background(.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    func glassSurface(
        cornerRadius: CGFloat,
        interactive: Bool = false,
        emphasized: Bool = false,
        highlightColor: Color = .white
    ) -> some View {
        modifier(AdaptiveGlassSurface(
            cornerRadius: cornerRadius,
            interactive: interactive,
            emphasized: emphasized,
            highlightColor: highlightColor
        ))
    }

    func adaptiveGlassButton(
        prominent: Bool = false,
        selected: Bool = false
    ) -> some View {
        modifier(AdaptiveGlassButton(prominent: prominent, selected: selected))
    }
}

private struct AdaptiveGlassSurface: ViewModifier {
    var cornerRadius: CGFloat
    var interactive: Bool
    var emphasized: Bool
    var highlightColor: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(tvOS 26.0, *) {
            if interactive {
                content.glassEffect(
                    .regular.tint(emphasized ? highlightColor.opacity(0.14) : .clear).interactive(),
                    in: .rect(cornerRadius: cornerRadius)
                )
            } else {
                content.glassEffect(
                    .regular.tint(emphasized ? highlightColor.opacity(0.12) : .clear),
                    in: .rect(cornerRadius: cornerRadius)
                )
            }
        } else {
            content
                .background(
                    emphasized
                        ? highlightColor.opacity(0.16)
                        : Color.black.opacity(0.34),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(
                            emphasized
                                ? highlightColor.opacity(0.58)
                                : Color.white.opacity(0.08),
                            lineWidth: emphasized ? 2 : 1
                        )
                )
        }
    }
}

private struct AdaptiveGlassButton: ViewModifier {
    var prominent: Bool
    var selected: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(tvOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content
                    .buttonStyle(.glass)
                    .tint(selected ? .red : .white.opacity(0.16))
            }
        } else if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content
                .buttonStyle(.bordered)
                .tint(selected ? .red : .white.opacity(0.16))
        }
    }
}

struct RemoteButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.78 : 1)
            .brightness(configuration.isPressed ? 0.08 : 0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct AdaptiveGlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: () -> Content

    @ViewBuilder
    var body: some View {
        if #available(tvOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

private func formatDuration(_ ms: Int) -> String {
    guard ms > 0 else { return "0:00" }
    let totalSeconds = max(0, ms / 1000)
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    return "\(minutes):\(String(format: "%02d", seconds))"
}
