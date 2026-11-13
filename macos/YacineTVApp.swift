import SwiftUI
import AppKit
import AVKit
import WebKit
import Combine
import Metal
import MetalFX
import MetalKit
import CoreVideo

// MARK: - API Models
struct YacineStatusResponse: Decodable {
    let ok: Bool
    let active_host: String
}

struct YacineCategory: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let logo: String?
    let child_count: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, logo, child_count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .id) {
            id = s
        } else if let n = try? c.decode(Int64.self, forKey: .id) {
            id = String(n)
        } else {
            id = UUID().uuidString
        }
        name = (try? c.decode(String.self, forKey: .name)) ?? "Category"
        logo = try? c.decode(String.self, forKey: .logo)
        child_count = try? c.decode(Int.self, forKey: .child_count)
    }
}

struct YacineCategoriesResponse: Decodable {
    let data: [YacineCategory]
}

struct YacineChannel: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let logo: String?
    let is_hide: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, logo, is_hide
    }

    init(id: String, name: String, logo: String?, is_hide: Int? = 0) {
        self.id = id
        self.name = name
        self.logo = logo
        self.is_hide = is_hide
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .id) {
            id = s
        } else if let n = try? c.decode(Int64.self, forKey: .id) {
            id = String(n)
        } else {
            id = UUID().uuidString
        }
        name = (try? c.decode(String.self, forKey: .name)) ?? "Channel"
        logo = try? c.decode(String.self, forKey: .logo)
        is_hide = try? c.decode(Int.self, forKey: .is_hide)
    }
}

struct YacineChannelsResponse: Decodable {
    let data: [YacineChannel]
}

struct YacineTeam: Codable, Hashable {
    let name: String?
    let logo: String?
}

enum MatchLifecycleState: Equatable {
    case live
    case upcoming(minutesUntil: Int)
    case ended
}

struct YacineEvent: Identifiable, Codable, Hashable {
    let id: String
    let champions: String?
    let channel: String?
    let commentary: String?
    let start_time: Int64?
    let end_time: Int64?
    let team_1: YacineTeam?
    let team_2: YacineTeam?

    enum CodingKeys: String, CodingKey {
        case id, champions, channel, commentary, start_time, end_time, team_1, team_2
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .id) {
            id = s
        } else if let n = try? c.decode(Int64.self, forKey: .id) {
            id = String(n)
        } else {
            id = UUID().uuidString
        }
        champions = try? c.decode(String.self, forKey: .champions)
        channel = try? c.decode(String.self, forKey: .channel)
        commentary = try? c.decode(String.self, forKey: .commentary)
        start_time = try? c.decode(Int64.self, forKey: .start_time)
        end_time = try? c.decode(Int64.self, forKey: .end_time)
        team_1 = try? c.decode(YacineTeam.self, forKey: .team_1)
        team_2 = try? c.decode(YacineTeam.self, forKey: .team_2)
    }

    private static func normalizedUnixSeconds(_ raw: Int64?) -> Int64? {
        guard let raw, raw > 0 else { return nil }
        return raw > 10_000_000_000 ? raw / 1000 : raw
    }

    func lifecycleState(at date: Date = Date()) -> MatchLifecycleState {
        let now = Int64(date.timeIntervalSince1970)
        guard let s = Self.normalizedUnixSeconds(start_time) else { return .live }
        let e = Self.normalizedUnixSeconds(end_time) ?? (s + 7200)
        if now >= s && now <= e {
            return .live
        } else if now > e {
            return .ended
        } else {
            let mins = max(1, Int((s - now + 59) / 60))
            return .upcoming(minutesUntil: mins)
        }
    }

    private static let kickoffFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "hh:mm a"
        return fmt
    }()

    func formattedKickoffTime() -> String {
        guard let s = Self.normalizedUnixSeconds(start_time) else { return "LIVE" }
        let date = Date(timeIntervalSince1970: TimeInterval(s))
        return Self.kickoffFormatter.string(from: date)
    }
}

struct YacineEventsResponse: Decodable {
    let data: [YacineEvent]
}

struct YacineStream: Identifiable, Decodable, Hashable {
    var id: String { "\(name ?? "srv")-\(proxy_url ?? resolved_url ?? "")" }
    let name: String?
    let url: String?
    let url_type: Int?
    let resolved_url: String?
    let proxy_url: String?
    let keyword: String?
    let effective_ua: String?
    let effective_ref: String?
    let probe_ok: Bool?
    let probe_height: Int?
    let probe_fps: Double?
    let probe_bandwidth: Int?
    let probe_label: String?
}

struct YacineStreamsResponse: Decodable {
    let data: [YacineStream]
    let recommended_index: Int?
    let recommended_order: [Int]?
}

struct YacineExtractResponse: Decodable {
    let ok: Bool
    let found: Bool
    let m3u8_url: String?
    let referer: String?
    let proxy_url: String?
    let max_height: Int?
    let max_fps: Double?
    let max_bandwidth: Int?
    let label: String?
}

struct YacineVariant: Identifiable, Decodable, Hashable {
    var id: Int { index }
    let index: Int
    let label: String
    let display_label: String?
    let resolution: String
    let bandwidth: Int
    let avg_bandwidth: Int?
    let fps: Double?
    let codecs: String?
    let is_audio_only: Bool?
    let proxy_url: String

    var parsedDimensions: (width: Int, height: Int)? {
        let normalized = resolution.lowercased().replacingOccurrences(of: "×", with: "x")
        let parts = normalized.split(separator: "x")
        guard parts.count == 2,
              let w = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let h = Int(parts[1].trimmingCharacters(in: .whitespaces)),
              w > 0, h > 0 else {
            return nil
        }
        return (w, h)
    }

    var heightPixels: Int {
        if let h = parsedDimensions?.height { return h }
        let lower = label.lowercased()
        if let pIdx = lower.firstIndex(of: "p") {
            let prefix = lower[..<pIdx].filter(\.isNumber)
            if let val = Int(prefix), val > 0 { return val }
        }
        return 0
    }

    var effectiveBandwidth: Int {
        if let abw = avg_bandwidth, abw > 0 { return abw }
        return bandwidth
    }

    var shortQualityName: String {
        if let dl = display_label, !dl.isEmpty { return dl }
        if heightPixels > 0 {
            if let f = fps, f >= 45.0 {
                return "\(heightPixels)p\(Int(f.rounded()))"
            }
            return "\(heightPixels)p"
        }
        return label
    }

    var qualityBadgeTag: String? {
        if heightPixels >= 2160 { return "4K" }
        if heightPixels >= 1080 { return "FHD" }
        if heightPixels >= 720 { return "HD" }
        return nil
    }

    var formattedBitrate: String? {
        let bps = effectiveBandwidth
        guard bps > 0 else { return nil }
        if bps >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bps) / 1_000_000.0)
        }
        return "\(bps / 1000) kbps"
    }
}

struct YacineVariantsResponse: Decodable {
    let ok: Bool
    let is_master: Bool
    let variants: [YacineVariant]
    let auto_proxy_url: String?
}

enum VideoEnhanceMode: String, CaseIterable, Identifiable {
    case off = "Off"
    case autoSD = "Auto (< 720p)"
    case always = "Always On"

    var id: String { rawValue }

    var shortTitle: String {
        switch self {
        case .off: return "Off"
        case .autoSD: return "Auto SD"
        case .always: return "Always"
        }
    }
}

enum PlaybackStageMode: Equatable {
    case nativeAV
    case hiddenSniffWeb(requestID: UUID, url: URL, userAgent: String, referer: String, keyword: String)
    case visibleWeb(requestID: UUID, url: URL, userAgent: String, referer: String, keyword: String, autoUpgrade: Bool)

    var webRequestID: UUID? {
        switch self {
        case .nativeAV: return nil
        case .hiddenSniffWeb(let id, _, _, _, _),
             .visibleWeb(let id, _, _, _, _, _):
            return id
        }
    }

    var webURL: URL? {
        switch self {
        case .nativeAV: return nil
        case .hiddenSniffWeb(_, let url, _, _, _),
             .visibleWeb(_, let url, _, _, _, _):
            return url
        }
    }

    var isWebVisible: Bool {
        if case .visibleWeb = self { return true }
        return false
    }
}

// MARK: - Navigation & Aspect State
enum SidebarSelection: Hashable {
    case matches
    case favorites
    case category(YacineCategory)
}

enum AspectMode: String, CaseIterable, Identifiable {
    case fit = "16:9 Fit"
    case fill = "Widescreen Fill"
    case stretch = "Stretch"

    var id: String { rawValue }

    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .fit: return .resizeAspect
        case .fill: return .resizeAspectFill
        case .stretch: return .resize
        }
    }
}

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system = "Auto"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.stars.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Store / ViewModel
@MainActor
final class LocalHoverState: ObservableObject {
    @Published var isHovered: Bool = false
}

@MainActor
final class YacineImageCache {
    static let shared = YacineImageCache()

    private let memoryCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    private let session: URLSession = {
        let diskCache = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: 128 * 1024 * 1024,
            diskPath: "yacine_tv_logos"
        )
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = diskCache
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.httpMaximumConnectionsPerHost = 12
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 20
        return URLSession(configuration: cfg)
    }()

    private var inflight: [String: Task<NSImage?, Never>] = [:]
    private var failedAt: [String: Date] = [:]

    func cachedImage(for urlString: String) -> NSImage? {
        memoryCache.object(forKey: urlString as NSString)
    }

    func hasFailedRecently(_ urlString: String) -> Bool {
        guard let ts = failedAt[urlString] else { return false }
        if Date().timeIntervalSince(ts) < 30 {
            return true
        }
        failedAt.removeValue(forKey: urlString)
        return false
    }

    func clearTransientFailures() {
        failedAt.removeAll()
    }

    func loadImage(for urlString: String) async -> NSImage? {
        if let hit = memoryCache.object(forKey: urlString as NSString) {
            return hit
        }
        if hasFailedRecently(urlString) {
            return nil
        }
        if let existingTask = inflight[urlString] {
            return await existingTask.value
        }
        guard let url = URL(string: urlString) else {
            failedAt[urlString] = Date()
            return nil
        }

        let sessionRef = session
        let task = Task<NSImage?, Never> {
            defer { self.inflight[urlString] = nil }
            let decoded: (NSImage, Int)? = await Task.detached(priority: .utility) {
                do {
                    var req = URLRequest(url: url)
                    req.cachePolicy = .returnCacheDataElseLoad
                    let (data, resp) = try await sessionRef.data(for: req)
                    if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        return nil
                    }
                    // Eagerly decode raster pixels off the main thread for smooth grid scrolling
                    if let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 0, rep.pixelsHigh > 0 {
                        _ = rep.cgImage
                        let img = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
                        img.addRepresentation(rep)
                        return (img, max(rep.bytesPerRow * rep.pixelsHigh, data.count))
                    }
                    guard let fallbackImg = NSImage(data: data), !fallbackImg.representations.isEmpty else {
                        return nil
                    }
                    return (fallbackImg, max(data.count, 1024))
                } catch {
                    return nil
                }
            }.value

            guard let (img, cost) = decoded else {
                self.failedAt[urlString] = Date()
                return nil
            }
            self.failedAt.removeValue(forKey: urlString)
            self.memoryCache.setObject(img, forKey: urlString as NSString, cost: cost)
            return img
        }

        inflight[urlString] = task
        return await task.value
    }
}

@MainActor
private final class LogoImageLoader: ObservableObject {
    @Published var loadedURL: String? = nil
    @Published var image: NSImage? = nil
    @Published var failedURL: String? = nil

    func load(urlString: String?) async {
        guard let str = urlString, !str.isEmpty else {
            if loadedURL != nil || image != nil || failedURL != nil {
                loadedURL = nil
                image = nil
                failedURL = nil
            }
            return
        }
        if let hit = YacineImageCache.shared.cachedImage(for: str) {
            if loadedURL != str || image !== hit || failedURL != nil {
                loadedURL = str
                image = hit
                failedURL = nil
            }
            return
        }
        let img = await YacineImageCache.shared.loadImage(for: str)
        guard !Task.isCancelled else { return }
        if let img {
            loadedURL = str
            image = img
            failedURL = nil
        } else {
            loadedURL = str
            image = nil
            failedURL = str
        }
    }
}

@MainActor
enum AppIconProvider {
    private static var cachedImages: [String: NSImage] = [:]

    static func bundledImage(named filename: String) -> NSImage? {
        if let hit = cachedImages[filename] {
            return hit
        }
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        let bundleURL = Bundle.main.url(forResource: stem, withExtension: ext)
        let localDevURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("assets/\(filename)")
        let targetURL: URL
        if let bundleURL, FileManager.default.fileExists(atPath: bundleURL.path) {
            targetURL = bundleURL
        } else {
            targetURL = localDevURL
        }
        guard FileManager.default.fileExists(atPath: targetURL.path),
              let img = NSImage(contentsOf: targetURL) else {
            return nil
        }
        cachedImages[filename] = img
        return img
    }

    static func syncDockIcon(for mode: AppAppearanceMode) {
        guard let app = NSApp else { return }
        let isDark: Bool
        switch mode {
        case .dark:
            isDark = true
        case .light:
            isDark = false
        case .system:
            let match = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            isDark = (match == .darkAqua)
        }
        if let img = bundledImage(named: isDark ? "AppIcon-Dark.png" : "AppIcon-Default.png") {
            app.applicationIconImage = img
        }
    }
}

private struct YacineBootstrapSnapshot: Codable {
    let savedAt: Date
    let categories: [YacineCategory]
    let events: [YacineEvent]
    let channelsByCategory: [String: [YacineChannel]]
    let subcategoriesByParent: [String: [YacineCategory]]
}

@MainActor
final class YacineStore: ObservableObject {
    let baseURL = "http://127.0.0.1:19485"

    private let apiSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpMaximumConnectionsPerHost = 12
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg)
    }()

    @Published var isConnected = false
    @Published var bootstrapFailed = false
    @Published var categories: [YacineCategory] = []
    @Published var subcategories: [YacineCategory] = []
    @Published var parentCategory: YacineCategory? = nil
    @Published var channels: [YacineChannel] = []
    @Published var events: [YacineEvent] = []
    @Published var favorites: [YacineChannel] = []

    @Published var selection: SidebarSelection? = nil
    @Published var searchText: String = ""
    @Published var searchResults: [YacineChannel] = []
    @Published var isLoadingGrid = false
    @Published var gridError: String? = nil

    // Player state
    @Published var player = AVPlayer()
    @Published var stageMode: PlaybackStageMode = .nativeAV
    @Published var nowPlayingTitle: String = "Select a Channel or Live Match"
    @Published var nowPlayingSubtitle: String = "Native AVKit Hardware Acceleration · Liquid Glass"
    @Published var activePlayingKey: String? = nil
    @Published var streams: [YacineStream] = []
    @Published var selectedStreamIndex: Int = 0
    @Published var variants: [YacineVariant] = []
    @Published var selectedVariantIndex: Int? = nil
    @Published var isLoadingStream = false
    @Published var aspectMode: AspectMode = .fit
    @Published var isTheaterMode = false
    @Published var isSidebarVisible = true
    @Published var isFullScreenVideo = false
    @Published var appearanceMode: AppAppearanceMode = .system {
        didSet { applyAppearance() }
    }
    @Published var videoEnhanceMode: VideoEnhanceMode = .autoSD {
        didSet {
            UserDefaults.standard.set(videoEnhanceMode.rawValue, forKey: Self.enhanceStorageKey)
            qualityMenuVersion &+= 1
        }
    }
    @Published var isPictureInPictureActive = false
    @Published var currentVideoHeight: Int = 0
    @Published var videoResolutionText: String = "—"
    @Published var activeTrackResolutionBadge: String = "Auto"
    @Published var activeBitrateText: String = ""
    @Published var qualityMenuVersion: Int = 0
    @Published var nowPlayingLogoURL: String? = nil

    var isMetalFXCurrentlyActive: Bool {
        guard stageMode == .nativeAV, !isPictureInPictureActive else { return false }
        switch videoEnhanceMode {
        case .off: return false
        case .always: return currentVideoHeight > 0
        case .autoSD: return currentVideoHeight > 0 && currentVideoHeight < 720
        }
    }

    private var presentationObserver: AnyCancellable?
    private var statusObserver: AnyCancellable?
    private var accessLogObserver: AnyCancellable?
    private var failedToEndObserver: AnyCancellable?
    private var searchTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var variantsTask: Task<Void, Never>?
    private var activeBaseProxyPath: String? = nil
    private var activeCurrentProxyPath: String? = nil
    private var recommendedOrder: [Int] = []
    private var playbackToken = UUID()
    private var gridLoadToken = UUID()
    private var inflightCategoryId: String? = nil
    private var triedIndices: Set<Int> = []
    private var channelsByCategoryCache: [String: [YacineChannel]] = [:]
    private var subcategoriesByParentCache: [String: [YacineCategory]] = [:]
    private let favStorageKey = "yacine_native_favorites_v1"
    static let appearanceStorageKey = "yacine_appearance_mode_v1"
    static let enhanceStorageKey = "yacine_video_enhance_mode_v1"

    var liveEventsCount: Int {
        let now = Date()
        return events.filter { $0.lifecycleState(at: now) == .live }.count
    }

    var currentQualityButtonTitle: String {
        if let idx = selectedVariantIndex,
           let selected = variants.first(where: { $0.id == idx }) {
            return selected.shortQualityName
        }
        if !activeTrackResolutionBadge.isEmpty, activeTrackResolutionBadge != "Auto" {
            return "Auto · \(activeTrackResolutionBadge)"
        }
        return "Auto"
    }

    var activeAutoHeightDescription: String? {
        guard !activeTrackResolutionBadge.isEmpty, activeTrackResolutionBadge != "Auto" else {
            return nil
        }
        return "Streaming \(activeTrackResolutionBadge)"
    }

    private var gridSpinnerTask: Task<Void, Never>? = nil
    private var prefetchTask: Task<Void, Never>? = nil
    private static let snapshotURL: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = caches.appendingPathComponent("YacineTV", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bootstrap_v1.json")
    }()

    init() {
        loadFavorites()
        loadAppearance()
        if let rawEnh = UserDefaults.standard.string(forKey: Self.enhanceStorageKey),
           let parsedEnh = VideoEnhanceMode(rawValue: rawEnh) {
            videoEnhanceMode = parsedEnh
        }
        loadCachedSnapshot()
        player.allowsExternalPlayback = true
    }

    private func loadCachedSnapshot() {
        guard let url = Self.snapshotURL,
              let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(YacineBootstrapSnapshot.self, from: data) else {
            return
        }
        if !snap.categories.isEmpty {
            categories = snap.categories
        }
        if !snap.events.isEmpty {
            events = snap.events
        }
        channelsByCategoryCache = snap.channelsByCategory
        subcategoriesByParentCache = snap.subcategoriesByParent

        if selection == nil, let first = snap.categories.first {
            selection = .category(first)
            if (first.child_count ?? 0) > 0, let subs = snap.subcategoriesByParent[first.id] {
                subcategories = subs
            } else if let chans = snap.channelsByCategory[first.id] {
                channels = chans
            }
        }
    }

    private func saveSnapshotAsync() {
        guard let url = Self.snapshotURL, !categories.isEmpty else { return }
        let snapshot = YacineBootstrapSnapshot(
            savedAt: Date(),
            categories: categories,
            events: events,
            channelsByCategory: channelsByCategoryCache,
            subcategoriesByParent: subcategoriesByParentCache
        )
        Task.detached(priority: .utility) {
            if let encoded = try? JSONEncoder().encode(snapshot) {
                try? encoded.write(to: url, options: .atomic)
            }
        }
    }

    func loadAppearance() {
        if let raw = UserDefaults.standard.string(forKey: Self.appearanceStorageKey),
           let mode = AppAppearanceMode(rawValue: raw) {
            appearanceMode = mode
        }
        applyAppearance()
    }

    func applyAppearance() {
        UserDefaults.standard.set(appearanceMode.rawValue, forKey: Self.appearanceStorageKey)
        NSApp?.appearance = appearanceMode.nsAppearance
        AppIconProvider.syncDockIcon(for: appearanceMode)
    }

    func loadFavorites() {
        guard let data = UserDefaults.standard.data(forKey: favStorageKey),
              let saved = try? JSONDecoder().decode([YacineChannel].self, from: data) else {
            return
        }
        favorites = saved
    }

    func saveFavorites() {
        if let data = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(data, forKey: favStorageKey)
        }
    }

    func isFavorite(_ channel: YacineChannel) -> Bool {
        favorites.contains { $0.id == channel.id }
    }

    func toggleFavorite(_ channel: YacineChannel) {
        if let idx = favorites.firstIndex(where: { $0.id == channel.id }) {
            favorites.remove(at: idx)
        } else {
            favorites.append(channel)
        }
        saveFavorites()
    }

    func bootstrap(forceRefresh: Bool = false) async {
        bootstrapFailed = false
        if !isConnected {
            // Fast initial poll so local Python backend connects immediately on first socket bind
            let delaysNs: [UInt64] = [
                20_000_000, 30_000_000, 45_000_000, 65_000_000,
                90_000_000, 120_000_000, 180_000_000
            ]
            for attempt in 0..<32 {
                if let status: YacineStatusResponse = try? await fetchJSON("/api/status", timeout: 1.0), status.ok {
                    isConnected = true
                    bootstrapFailed = false
                    break
                }
                let delay = delaysNs[min(attempt, delaysNs.count - 1)]
                try? await Task.sleep(nanoseconds: delay)
            }
        }

        guard isConnected else {
            bootstrapFailed = true
            return
        }

        // Start first channel immediately from warm snapshot cache while refreshing metadata in parallel
        if !forceRefresh,
           activePlayingKey == nil,
           let firstCachedChannel = channels.first {
            Task { @MainActor [weak self] in
                guard let self, self.activePlayingKey == nil else { return }
                await self.playItem(
                    kind: "channel",
                    id: firstCachedChannel.id,
                    title: firstCachedChannel.name,
                    logoURL: firstCachedChannel.logo
                )
            }
        }

        let suffix = forceRefresh ? "?refresh=1" : ""
        async let catsResp: YacineCategoriesResponse = fetchJSON("/api/categories\(suffix)")
        async let evtsResp: YacineEventsResponse = fetchJSON("/api/events\(suffix)")

        do {
            let (cats, evts) = try await (catsResp, evtsResp)
            self.categories = cats.data
            self.events = evts.data

            if selection == nil, let first = cats.data.first {
                self.selection = .category(first)
                await loadCategory(first, autoPlayFirst: true, forceRefresh: forceRefresh)
            } else if case .category(let currentCat) = selection {
                await loadCategory(currentCat, parent: parentCategory, autoPlayFirst: activePlayingKey == nil, forceRefresh: forceRefresh)
            }
            saveSnapshotAsync()
            scheduleCategoryPrefetch()
        } catch {
            if categories.isEmpty {
                gridError = error.localizedDescription
            }
        }
    }

    private func scheduleCategoryPrefetch() {
        prefetchTask?.cancel()
        let toWarm = Array(categories.prefix(8))
        prefetchTask = Task { [weak self] in
            // Let initial video buffering claim bandwidth first before warming category caches
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard let self, !Task.isCancelled else { return }
            await withTaskGroup(of: (String, Bool, [YacineCategory]?, [YacineChannel]?).self) { group in
                for cat in toWarm {
                    let hasSubs = (cat.child_count ?? 0) > 0
                    if hasSubs, self.subcategoriesByParentCache[cat.id] != nil { continue }
                    if !hasSubs, self.channelsByCategoryCache[cat.id] != nil { continue }
                    group.addTask {
                        if hasSubs {
                            let res: YacineCategoriesResponse? = try? await self.fetchJSON("/api/categories?id=\(cat.id)")
                            return (cat.id, true, res?.data, nil)
                        } else {
                            let res: YacineChannelsResponse? = try? await self.fetchJSON("/api/channels?category_id=\(cat.id)")
                            let visible = res?.data.filter { ($0.is_hide ?? 0) == 0 }
                            return (cat.id, false, nil, visible)
                        }
                    }
                }
                for await (id, isSub, subs, chans) in group {
                    if Task.isCancelled { break }
                    if isSub, let subs {
                        self.subcategoriesByParentCache[id] = subs
                    } else if !isSub, let chans {
                        self.channelsByCategoryCache[id] = chans
                    }
                }
            }
            if !Task.isCancelled {
                self.saveSnapshotAsync()
            }
        }
    }

    func refreshAll() async {
        channelsByCategoryCache.removeAll()
        subcategoriesByParentCache.removeAll()
        YacineImageCache.shared.clearTransientFailures()
        await bootstrap(forceRefresh: true)
    }

    func handleSelectionChange(_ newSel: SidebarSelection?) async {
        guard let newSel else { return }
        if case .category(let cat) = newSel,
           inflightCategoryId == cat.id,
           activePlayingKey == nil || !channels.isEmpty || !subcategories.isEmpty {
            return
        }
        parentCategory = nil
        subcategories = []
        gridError = nil

        switch newSel {
        case .matches:
            gridLoadToken = UUID()
            inflightCategoryId = nil
            if events.isEmpty {
                isLoadingGrid = true
            }
            let token = gridLoadToken
            if let evts: YacineEventsResponse = try? await fetchJSON("/api/events") {
                guard gridLoadToken == token else { return }
                events = evts.data
            }
            if gridLoadToken == token {
                isLoadingGrid = false
            }
        case .favorites:
            gridLoadToken = UUID()
            inflightCategoryId = nil
            isLoadingGrid = false
        case .category(let cat):
            await loadCategory(cat, autoPlayFirst: false)
        }
    }

    func loadCategory(_ cat: YacineCategory, parent: YacineCategory? = nil, autoPlayFirst: Bool = false, forceRefresh: Bool = false) async {
        if !forceRefresh, inflightCategoryId == cat.id {
            return
        }
        gridError = nil
        parentCategory = parent
        let hasSubcategories = (cat.child_count ?? 0) > 0
        gridLoadToken = UUID()
        let token = gridLoadToken

        if !forceRefresh {
            if hasSubcategories, let cachedSubs = subcategoriesByParentCache[cat.id] {
                subcategories = cachedSubs
                channels = []
                isLoadingGrid = false
                return
            } else if !hasSubcategories, let cachedChans = channelsByCategoryCache[cat.id] {
                subcategories = []
                channels = cachedChans
                isLoadingGrid = false
                if autoPlayFirst, let firstCh = cachedChans.first, activePlayingKey == nil {
                    await playItem(kind: "channel", id: firstCh.id, title: firstCh.name, logoURL: firstCh.logo)
                }
                return
            }
        }

        inflightCategoryId = cat.id
        gridSpinnerTask?.cancel()
        // Only reveal a loading spinner if no cached cards exist and network takes >110ms
        let hadDisplayedItems = !channels.isEmpty || !subcategories.isEmpty
        if !hadDisplayedItems {
            isLoadingGrid = true
        } else {
            gridSpinnerTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 110_000_000)
                guard let self, !Task.isCancelled, self.gridLoadToken == token else { return }
                self.isLoadingGrid = true
            }
        }
        let qRefresh = forceRefresh ? "&refresh=1" : ""

        defer {
            gridSpinnerTask?.cancel()
            if gridLoadToken == token {
                inflightCategoryId = nil
                isLoadingGrid = false
            }
        }

        do {
            if hasSubcategories {
                let sub: YacineCategoriesResponse = try await fetchJSON("/api/categories?id=\(cat.id)\(qRefresh)")
                guard gridLoadToken == token else { return }
                subcategoriesByParentCache[cat.id] = sub.data
                subcategories = sub.data
                channels = []
                saveSnapshotAsync()
            } else {
                subcategories = []
                let chResp: YacineChannelsResponse = try await fetchJSON("/api/channels?category_id=\(cat.id)\(qRefresh)")
                guard gridLoadToken == token else { return }
                let visible = chResp.data.filter { ($0.is_hide ?? 0) == 0 }
                channelsByCategoryCache[cat.id] = visible
                channels = visible
                saveSnapshotAsync()
                if autoPlayFirst, let firstCh = visible.first, activePlayingKey == nil {
                    await playItem(kind: "channel", id: firstCh.id, title: firstCh.name, logoURL: firstCh.logo)
                }
            }
        } catch {
            if gridLoadToken == token {
                gridError = error.localizedDescription
            }
        }
    }

    func performSearch(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard !Task.isCancelled else { return }
            let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
            if let res: YacineChannelsResponse = try? await fetchJSON("/api/search?query=\(encoded)") {
                self.searchResults = res.data.filter { ($0.is_hide ?? 0) == 0 }
            }
        }
    }

    private func b64uEncode(_ text: String) -> String {
        Data(text.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    func playItem(kind: String, id: String, title: String, logoURL: String? = nil) async {
        activePlayingKey = "\(kind):\(id)"
        nowPlayingTitle = title
        nowPlayingLogoURL = logoURL
        nowPlayingSubtitle = "Decrypting stream keys & negotiating HLS..."
        isLoadingStream = true
        streams = []
        selectedStreamIndex = 0
        variants = []
        selectedVariantIndex = nil
        activeBaseProxyPath = nil
        activeCurrentProxyPath = nil
        recommendedOrder = []
        triedIndices = []
        currentVideoHeight = 0
        videoResolutionText = "—"
        activeTrackResolutionBadge = "Auto"
        activeBitrateText = ""
        qualityMenuVersion &+= 1
        watchTask?.cancel()
        variantsTask?.cancel()
        playbackToken = UUID()
        let token = playbackToken

        do {
            let res: YacineStreamsResponse = try await fetchJSON("/api/stream?type=\(kind)&id=\(id)")
            guard playbackToken == token else { return }
            streams = res.data
            recommendedOrder = res.recommended_order ?? Array(0..<streams.count)
            let startIdx = res.recommended_index.flatMap { ($0 >= 0 && $0 < streams.count) ? $0 : nil } ?? 0
            if !streams.isEmpty {
                startStream(at: startIdx, allowAutoFallback: true)
            } else {
                isLoadingStream = false
                nowPlayingSubtitle = "No servers returned for \(title)"
            }
        } catch {
            guard playbackToken == token else { return }
            isLoadingStream = false
            nowPlayingSubtitle = "Stream error: \(error.localizedDescription)"
        }
    }

    func selectVariant(_ variant: YacineVariant?) {
        selectedVariantIndex = variant?.index
        qualityMenuVersion &+= 1
        let srvName = (selectedStreamIndex >= 0 && selectedStreamIndex < streams.count)
            ? (streams[selectedStreamIndex].name ?? "Live")
            : "Live"

        guard let baseProxy = activeBaseProxyPath else { return }
        let targetProxyPath = variant.map { baseProxy + "&variant=\($0.index)" } ?? baseProxy

        if stageMode == .nativeAV,
           activeCurrentProxyPath == targetProxyPath,
           let item = player.currentItem {
            if variant == nil {
                item.preferredMaximumResolution = CGSize(width: 3840, height: 2160)
                item.preferredMaximumResolutionForExpensiveNetworks = CGSize(width: 3840, height: 2160)
                item.preferredPeakBitRate = 0
                item.preferredPeakBitRateForExpensiveNetworks = 0
                nowPlayingSubtitle = "Server: \(srvName) · Auto (Max) HLS"
            }
            return
        }

        // Strict variant locking via single-variant &variant=N master manifest (or restore full Auto master)
        let token = playbackToken
        launchAVPlayer(
            proxyPath: targetProxyPath,
            baseProxyPath: baseProxy,
            subtitle: "Server: \(srvName) · \(variant?.shortQualityName ?? "Auto (Max)") HLS",
            token: token,
            allowAutoFallback: false,
            fetchVariants: false
        )
    }

    func startStream(at index: Int, allowAutoFallback: Bool = false) {
        guard index >= 0 && index < streams.count else { return }
        selectedStreamIndex = index
        triedIndices.insert(index)
        variants = []
        selectedVariantIndex = nil
        activeBaseProxyPath = nil
        activeCurrentProxyPath = nil
        currentVideoHeight = 0
        activeTrackResolutionBadge = "Auto"
        activeBitrateText = ""
        qualityMenuVersion &+= 1

        watchTask?.cancel()
        variantsTask?.cancel()
        playbackToken = UUID()
        let token = playbackToken

        let stream = streams[index]
        let urlType = stream.url_type ?? 1
        let srvName = stream.name ?? "Live"
        let rawTarget = (stream.resolved_url ?? stream.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let ua = stream.effective_ua ?? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        let ref = stream.effective_ref ?? ""
        let keyword = stream.keyword ?? "m3u8"

        if urlType == 4 || urlType == 5 || urlType == 6 {
            player.pause()
            player.replaceCurrentItem(with: nil)
            presentationObserver?.cancel()
            statusObserver?.cancel()
            accessLogObserver?.cancel()
            failedToEndObserver?.cancel()

            guard let pageURL = URL(string: rawTarget) else {
                tryNextFallbackIfAllowed(allowAutoFallback, token: token, failedLabel: srvName)
                return
            }

            isLoadingStream = true
            nowPlayingSubtitle = "Server: \(srvName) · Resolving web stream..."

            let host = (pageURL.host ?? "").lowercased()
            let isInteractiveWebOnly = (urlType == 4)
                || host.contains("youtube.com")
                || host.contains("youtu.be")
                || host.contains("dailymotion.com")
                || host.contains("twitch.tv")

            if isInteractiveWebOnly {
                stageMode = .visibleWeb(
                    requestID: token,
                    url: pageURL,
                    userAgent: ua,
                    referer: ref,
                    keyword: keyword,
                    autoUpgrade: false
                )
                nowPlayingSubtitle = "Server: \(srvName) · Interactive Web Player"
                videoResolutionText = "Web Embed"
                watchTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard let self, self.playbackToken == token else { return }
                    self.isLoadingStream = false
                }
                return
            }

            // Fast server-side HTML/iframe extractor first (covers tunisiatv.tn, static m3u8 pages, etc.)
            watchTask = Task { [weak self] in
                guard let self else { return }
                let extractPath = "/api/extract_m3u8?u=\(self.b64uEncode(rawTarget))&ua=\(self.b64uEncode(ua))&ref=\(self.b64uEncode(ref))"
                if let extracted: YacineExtractResponse = try? await self.fetchJSON(extractPath),
                   self.playbackToken == token,
                   extracted.found,
                   let proxyPath = extracted.proxy_url {
                    self.launchAVPlayer(
                        proxyPath: proxyPath,
                        baseProxyPath: proxyPath,
                        subtitle: "Server: \(srvName) · Native Hardware HLS",
                        token: token,
                        allowAutoFallback: allowAutoFallback,
                        fetchVariants: true
                    )
                    return
                }

                guard self.playbackToken == token else { return }
                if urlType == 5 {
                    // For web embed channels (url_type 5), show immediately (supporting DASH/MSE/Shaka players)
                    // while still upgrading seamlessly if a native .m3u8 stream request is sniffed.
                    self.stageMode = .visibleWeb(
                        requestID: token,
                        url: pageURL,
                        userAgent: ua,
                        referer: ref,
                        keyword: keyword,
                        autoUpgrade: true
                    )
                    self.isLoadingStream = false
                    self.nowPlayingSubtitle = "Server: \(srvName) · Live Web Player"
                    self.videoResolutionText = "Web Stream"
                    return
                }

                // For url_type 6: run hidden all-frames WKWebView sniffer (APK PlayerActivity.f0 + LM8/i)
                self.stageMode = .hiddenSniffWeb(
                    requestID: token,
                    url: pageURL,
                    userAgent: ua,
                    referer: ref,
                    keyword: keyword
                )

                // If JS player doesn't emit a sniffable .m3u8/.mp4 within 6s, reveal live WebView seamlessly
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard self.playbackToken == token else { return }
                if case .hiddenSniffWeb = self.stageMode {
                    self.stageMode = .visibleWeb(
                        requestID: token,
                        url: pageURL,
                        userAgent: ua,
                        referer: ref,
                        keyword: keyword,
                        autoUpgrade: true
                    )
                    self.isLoadingStream = false
                    self.nowPlayingSubtitle = "Server: \(srvName) · Live Web Player"
                    self.videoResolutionText = "Web Stream"
                }
            }
            return
        }

        guard let proxyPath = stream.proxy_url else {
            tryNextFallbackIfAllowed(allowAutoFallback, token: token, failedLabel: srvName)
            return
        }

        launchAVPlayer(
            proxyPath: proxyPath,
            baseProxyPath: proxyPath,
            subtitle: "Server: \(srvName) · Hardware-Accelerated HLS",
            token: token,
            allowAutoFallback: allowAutoFallback,
            fetchVariants: true
        )
    }

    func handleSniffedWebMedia(requestID: UUID, mediaURL: String, referer: String, userAgent: String, cookies: String = "") {
        guard playbackToken == requestID else { return }
        switch stageMode {
        case .hiddenSniffWeb:
            break
        case .visibleWeb(_, _, _, _, _, let autoUpgrade) where autoUpgrade:
            break
        default:
            return
        }

        let srvName = (selectedStreamIndex >= 0 && selectedStreamIndex < streams.count)
            ? (streams[selectedStreamIndex].name ?? "Live")
            : "Live"
        let ua = userAgent.isEmpty
            ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
            : userAgent
        let ckPart = cookies.isEmpty ? "" : "&ck=\(b64uEncode(cookies))"
        let proxyPath = "/proxy/m3u8?u=\(b64uEncode(mediaURL))&ua=\(b64uEncode(ua))&ref=\(b64uEncode(referer))\(ckPart)"

        // Upgrade extracted stream straight to native hardware-accelerated AVPlayer
        launchAVPlayer(
            proxyPath: proxyPath,
            baseProxyPath: proxyPath,
            subtitle: "Server: \(srvName) · Hardware-Accelerated HLS",
            token: requestID,
            allowAutoFallback: true,
            fetchVariants: true
        )
    }

    func handleWebEmbedError(requestID: UUID, message: String) {
        guard playbackToken == requestID else { return }
        let srvName = (selectedStreamIndex >= 0 && selectedStreamIndex < streams.count)
            ? (streams[selectedStreamIndex].name ?? "server")
            : "server"
        if !tryNextFallbackIfAllowed(true, token: requestID, failedLabel: srvName) {
            isLoadingStream = false
            nowPlayingSubtitle = "Web playback failed (\(message))"
        }
    }

    @discardableResult
    private func tryNextFallbackIfAllowed(_ allow: Bool, token: UUID, failedLabel: String) -> Bool {
        guard playbackToken == token, allow else { return false }
        for nextIdx in recommendedOrder where nextIdx >= 0 && nextIdx < streams.count && !triedIndices.contains(nextIdx) {
            startStream(at: nextIdx, allowAutoFallback: true)
            return true
        }
        for nextIdx in 0..<streams.count where !triedIndices.contains(nextIdx) {
            startStream(at: nextIdx, allowAutoFallback: true)
            return true
        }
        isLoadingStream = false
        nowPlayingSubtitle = "Playback failed on \(failedLabel) — try another server or channel"
        return false
    }

    private func launchAVPlayer(
        proxyPath: String,
        baseProxyPath: String,
        subtitle: String,
        token: UUID,
        allowAutoFallback: Bool,
        fetchVariants: Bool
    ) {
        guard let url = URL(string: baseURL + proxyPath) else {
            isLoadingStream = false
            return
        }

        stageMode = .nativeAV
        activeBaseProxyPath = baseProxyPath
        activeCurrentProxyPath = proxyPath
        nowPlayingSubtitle = subtitle
        isLoadingStream = true

        let item = AVPlayerItem(url: url)
        // Unlock full ABR bitrate & prevent small player viewport bounds from capping to <=360p
        item.preferredPeakBitRate = 0
        item.preferredPeakBitRateForExpensiveNetworks = 0
        item.preferredMaximumResolution = CGSize(width: 3840, height: 2160)
        item.preferredMaximumResolutionForExpensiveNetworks = CGSize(width: 3840, height: 2160)
        item.preferredForwardBufferDuration = 10.0
        if #available(macOS 14.0, *) {
            item.startsOnFirstEligibleVariant = true
        }

        presentationObserver?.cancel()
        presentationObserver = item.publisher(for: \.presentationSize)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] size in
                guard let self, self.playbackToken == token, size.width > 0, size.height > 0 else { return }
                self.isLoadingStream = false
                let w = Int(size.width.rounded())
                let h = Int(size.height.rounded())
                self.currentVideoHeight = h
                let ratio = String(format: "%.2f:1", size.width / size.height)
                self.videoResolutionText = "\(w)×\(h) (\(ratio))"
                self.activeTrackResolutionBadge = h > 0 ? "\(h)p" : "Auto"
                self.qualityMenuVersion &+= 1
            }

        accessLogObserver?.cancel()
        accessLogObserver = NotificationCenter.default
            .publisher(for: AVPlayerItem.newAccessLogEntryNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] _ in
                guard let self, let item, self.playbackToken == token else { return }
                item.fetchAccessLog { [weak self] log in
                    guard let last = log?.events.last else { return }
                    let bps = last.indicatedBitrate > 0 ? last.indicatedBitrate : last.observedBitrate
                    Task { @MainActor [weak self] in
                        guard let self, self.playbackToken == token, bps > 0 else { return }
                        if bps >= 1_000_000 {
                            self.activeBitrateText = String(format: "%.1f Mbps", bps / 1_000_000.0)
                        } else {
                            self.activeBitrateText = "\(Int(bps / 1000)) kbps"
                        }
                    }
                }
            }

        failedToEndObserver?.cancel()
        failedToEndObserver = NotificationCenter.default
            .publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.playbackToken == token else { return }
                let srvName = (self.selectedStreamIndex >= 0 && self.selectedStreamIndex < self.streams.count)
                    ? (self.streams[self.selectedStreamIndex].name ?? "server")
                    : "server"
                _ = self.tryNextFallbackIfAllowed(allowAutoFallback, token: token, failedLabel: srvName)
            }

        statusObserver?.cancel()
        statusObserver = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self, self.playbackToken == token else { return }
                switch status {
                case .readyToPlay:
                    self.isLoadingStream = false
                case .failed:
                    let srvName = (self.selectedStreamIndex >= 0 && self.selectedStreamIndex < self.streams.count)
                        ? (self.streams[self.selectedStreamIndex].name ?? "server")
                        : "server"
                    if !self.tryNextFallbackIfAllowed(allowAutoFallback, token: token, failedLabel: srvName) {
                        self.isLoadingStream = false
                        self.nowPlayingSubtitle = "Playback failed on \(srvName) — try another server"
                    }
                default:
                    break
                }
            }

        player.replaceCurrentItem(with: item)
        player.play()

        if fetchVariants, let qMark = baseProxyPath.firstIndex(of: "?") {
            let qsPart = String(baseProxyPath[baseProxyPath.index(after: qMark)...])
            variantsTask?.cancel()
            variantsTask = Task { [weak self] in
                guard let self else { return }
                if let resp: YacineVariantsResponse = try? await self.fetchJSON("/api/variants?\(qsPart)"),
                   self.playbackToken == token,
                   resp.is_master,
                   !resp.variants.isEmpty {
                    let videoOnly = resp.variants.filter { $0.is_audio_only != true }
                    let pool = videoOnly.isEmpty ? resp.variants : videoOnly
                    var seenKeys = Set<String>()
                    let deduplicated = pool.filter { variant in
                        let key = "\(variant.heightPixels)-\(Int((variant.fps ?? 0).rounded()))-\(variant.effectiveBandwidth)"
                        return seenKeys.insert(key).inserted
                    }
                    if deduplicated.count > 1 {
                        self.variants = deduplicated
                        self.qualityMenuVersion &+= 1
                    }
                }
            }
        }
    }

    private func fetchJSON<T: Decodable>(_ path: String, timeout: TimeInterval = 15) async throws -> T {
        guard let url = URL(string: baseURL + path) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, response) = try await apiSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Fullscreen HUD Synchronization & Native AVPlayerView Wrapper
@MainActor
final class FullscreenHUDController: ObservableObject {
    @Published var isHUDVisible: Bool = true
    @Published var isPopoverOpen: Bool = false

    let autoHideDelay: TimeInterval = 1.5
    var onAutoHide: (() -> Void)?

    private var hideTimer: Timer?

    var shouldShowOverlayControls: Bool {
        isHUDVisible || isPopoverOpen
    }

    func revealHUD(resetTimer: Bool = true) {
        if !isHUDVisible {
            withAnimation(.easeOut(duration: 0.16)) {
                isHUDVisible = true
            }
        }
        NSCursor.setHiddenUntilMouseMoves(false)
        guard resetTimer else { return }
        scheduleAutoHide()
    }

    func closePopover() {
        guard isPopoverOpen else { return }
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            isPopoverOpen = false
        }
        scheduleAutoHide()
    }

    func togglePopover() {
        withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
            isPopoverOpen.toggle()
        }
        if isPopoverOpen {
            isHUDVisible = true
            hideTimer?.invalidate()
        } else {
            scheduleAutoHide()
        }
    }

    func scheduleAutoHide() {
        hideTimer?.invalidate()
        guard !isPopoverOpen else { return }
        let timer = Timer(timeInterval: autoHideDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isPopoverOpen else { return }
                if let onAutoHide = self.onAutoHide {
                    onAutoHide()
                } else {
                    self.hideNowForIdle()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    func hideNowForIdle() {
        guard !isPopoverOpen else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            isHUDVisible = false
        }
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    func resetForExit() {
        hideTimer?.invalidate()
        hideTimer = nil
        isPopoverOpen = false
        isHUDVisible = true
        NSCursor.setHiddenUntilMouseMoves(false)
    }
}

private final class PassthroughOverlayHostingView<Content: View>: NSHostingView<Content> {
    var shouldInterceptHits: Bool = true

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard shouldInterceptHits else { return nil }
        return super.hitTest(point)
    }
}

private final class GPUBufferKeepAlive: @unchecked Sendable {
    private let objects: [AnyObject]
    init(_ objects: [AnyObject]) { self.objects = objects }
}

@MainActor
final class MetalFXVideoRenderView: MTKView, MTKViewDelegate {
    private struct RCASUniforms {
        var posScale: SIMD2<Float>
        var uvScale: SIMD2<Float>
        var sharpness: Float
        var pad: Float = 0
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct RCASUniforms {
        float2 posScale;
        float2 uvScale;
        float sharpness;
        float pad;
    };

    struct Varyings {
        float4 position [[position]];
        float2 uv;
    };

    vertex Varyings yacineQuadVertex(uint vid [[vertex_id]], constant RCASUniforms &u [[buffer(0)]]) {
        const float2 coords[4] = {
            float2(-1.0, -1.0),
            float2( 1.0, -1.0),
            float2(-1.0,  1.0),
            float2( 1.0,  1.0)
        };
        float2 pos = coords[vid] * u.posScale;
        float2 baseUV = float2((coords[vid].x + 1.0) * 0.5, 1.0 - (coords[vid].y + 1.0) * 0.5);
        Varyings out;
        out.position = float4(pos, 0.0, 1.0);
        out.uv = (baseUV - 0.5) * u.uvScale + 0.5;
        return out;
    }

    fragment float4 yacineRCASFragment(
        Varyings in [[stage_in]],
        texture2d<float, access::sample> tex [[texture(0)]],
        constant RCASUniforms &u [[buffer(0)]]
    ) {
        constexpr sampler linSampler(address::clamp_to_edge, filter::linear);
        float2 texSize = float2(tex.get_width(), tex.get_height());
        float2 px = 1.0 / max(texSize, float2(1.0));

        float3 c = tex.sample(linSampler, in.uv).rgb;
        if (u.sharpness <= 0.001) {
            return float4(c, 1.0);
        }

        float3 n = tex.sample(linSampler, in.uv + float2(0.0, -px.y)).rgb;
        float3 s = tex.sample(linSampler, in.uv + float2(0.0,  px.y)).rgb;
        float3 w = tex.sample(linSampler, in.uv + float2(-px.x, 0.0)).rgb;
        float3 e = tex.sample(linSampler, in.uv + float2( px.x, 0.0)).rgb;

        const float3 lumaW = float3(0.2126, 0.7152, 0.0722);
        float lc = dot(c, lumaW);
        float ln = dot(n, lumaW);
        float ls = dot(s, lumaW);
        float lw = dot(w, lumaW);
        float le = dot(e, lumaW);

        float mnL = min(lc, min(min(ln, ls), min(lw, le)));
        float mxL = max(lc, max(max(ln, ls), max(lw, le)));

        float amp = clamp(min(mnL, 1.0 - mxL) / max(mxL, 0.001), 0.0, 1.0);
        float wSharp = -sqrt(amp) * (0.20 * clamp(u.sharpness, 0.0, 0.6));
        float norm = 1.0 / max(1.0 + 4.0 * wSharp, 0.25);

        float3 sharpened = (c + wSharp * (n + s + w + e)) * norm;
        float3 mnRGB = min(c, min(min(n, s), min(w, e)));
        float3 mxRGB = max(c, max(max(n, s), max(w, e)));
        return float4(clamp(sharpened, mnRGB, mxRGB), 1.0);
    }
    """

    private let metalDevice: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?
    private var rcasPipeline: MTLRenderPipelineState?
    private var spatialScaler: MTLFXSpatialScaler?
    private var upscaledTexture: MTLTexture?
    private var scalerInputSize: (Int, Int) = (0, 0)
    private var scalerOutputSize: (Int, Int) = (0, 0)

    private weak var observedPlayer: AVPlayer?
    private weak var attachedItem: AVPlayerItem?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var lastPixelBuffer: CVPixelBuffer?
    private var aspectMode: AspectMode = .fit
    private var isEnhancementEnabled: Bool = false
    private var needsRedraw: Bool = false
    private var hasRenderedFrame: Bool = false

    static func createIfSupported() -> MetalFXVideoRenderView? {
        guard let dev = MTLCreateSystemDefaultDevice(),
              MTLFXSpatialScalerDescriptor.supportsDevice(dev),
              let queue = dev.makeCommandQueue() else {
            return nil
        }
        return MetalFXVideoRenderView(metalDevice: dev, commandQueue: queue)
    }

    private init(metalDevice dev: MTLDevice, commandQueue queue: MTLCommandQueue) {
        self.metalDevice = dev
        self.commandQueue = queue
        super.init(frame: .zero, device: dev)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.colorPixelFormat = .bgra8Unorm
        self.framebufferOnly = true
        self.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        self.enableSetNeedsDisplay = false
        self.isPaused = true
        self.isHidden = true
        self.alphaValue = 0
        self.preferredFramesPerSecond = 60
        self.delegate = self

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &textureCache)
        buildPipeline()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Never intercept mouse hover or clicks meant for AVPlayerView / Fullscreen HUD
        return nil
    }

    deinit {
        if let item = attachedItem, let output = videoOutput {
            item.remove(output)
        }
    }

    private func buildPipeline() {
        guard let lib = try? metalDevice.makeLibrary(source: Self.shaderSource, options: nil),
              let vfn = lib.makeFunction(name: "yacineQuadVertex"),
              let ffn = lib.makeFunction(name: "yacineRCASFragment") else {
            return
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        rcasPipeline = try? metalDevice.makeRenderPipelineState(descriptor: desc)
    }

    func updateConfiguration(player: AVPlayer, aspect: AspectMode, enabled: Bool) {
        observedPlayer = player
        if aspectMode != aspect {
            aspectMode = aspect
            needsRedraw = true
        }
        if isEnhancementEnabled != enabled {
            isEnhancementEnabled = enabled
            if enabled {
                hasRenderedFrame = false
                alphaValue = 0
                isHidden = false
                isPaused = false
                needsRedraw = true
                syncVideoOutputIfNeeded(for: player.currentItem)
            } else {
                isPaused = true
                isHidden = true
                alphaValue = 0
                hasRenderedFrame = false
                lastPixelBuffer = nil
                detachVideoOutput()
                spatialScaler = nil
                upscaledTexture = nil
                scalerInputSize = (0, 0)
                scalerOutputSize = (0, 0)
            }
        } else if enabled {
            syncVideoOutputIfNeeded(for: player.currentItem)
        }
    }

    private func detachVideoOutput() {
        if let item = attachedItem, let output = videoOutput {
            item.remove(output)
        }
        attachedItem = nil
        videoOutput = nil
    }

    private func syncVideoOutputIfNeeded(for item: AVPlayerItem?) {
        guard isEnhancementEnabled else { return }
        if attachedItem === item && videoOutput != nil { return }
        detachVideoOutput()
        guard let item else { return }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let out = AVPlayerItemVideoOutput(outputSettings: attrs)
        out.suppressesPlayerRendering = false
        item.add(out)
        attachedItem = item
        videoOutput = out
        lastPixelBuffer = nil
        hasRenderedFrame = false
        alphaValue = 0
        needsRedraw = true
    }

    private func ensureScaler(srcW: Int, srcH: Int, dstW: Int, dstH: Int) -> Bool {
        if scalerInputSize == (srcW, srcH) && scalerOutputSize == (dstW, dstH) && spatialScaler != nil && upscaledTexture != nil {
            return true
        }
        let sDesc = MTLFXSpatialScalerDescriptor()
        sDesc.inputWidth = srcW
        sDesc.inputHeight = srcH
        sDesc.outputWidth = dstW
        sDesc.outputHeight = dstH
        sDesc.colorTextureFormat = .bgra8Unorm
        sDesc.outputTextureFormat = .bgra8Unorm
        sDesc.colorProcessingMode = .perceptual
        guard let scaler = sDesc.makeSpatialScaler(device: metalDevice) else {
            return false
        }
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: dstW,
            height: dstH,
            mipmapped: false
        )
        texDesc.usage = [.shaderWrite, .renderTarget, .shaderRead]
        texDesc.storageMode = .private
        guard let outTex = metalDevice.makeTexture(descriptor: texDesc) else {
            return false
        }
        spatialScaler = scaler
        upscaledTexture = outTex
        scalerInputSize = (srcW, srcH)
        scalerOutputSize = (dstW, dstH)
        return true
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        needsRedraw = true
    }

    func draw(in view: MTKView) {
        guard isEnhancementEnabled, let player = observedPlayer else { return }
        syncVideoOutputIfNeeded(for: player.currentItem)
        guard let output = videoOutput, let cache = textureCache, let rcasPipeline else { return }

        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        var pbToRender: CVPixelBuffer? = nil
        if output.hasNewPixelBuffer(forItemTime: itemTime) {
            if #available(macOS 27.0, *) {
                if let ro = output.pixelBufferAndDisplayTime(forItemTime: itemTime).pixelBuffer {
                    ro.withUnsafeBuffer { buf in
                        pbToRender = buf
                    }
                }
            } else {
                pbToRender = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
            }
            if let fresh = pbToRender {
                lastPixelBuffer = fresh
            }
        } else if needsRedraw {
            pbToRender = lastPixelBuffer
        }

        guard let pixelBuffer = pbToRender else { return }

        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        let dw = Int(drawableSize.width)
        let dh = Int(drawableSize.height)
        guard srcW >= 64, srcH >= 64, dw >= 64, dh >= 64 else { return }

        var cvMetalTex: CVMetalTexture?
        let rc = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            srcW,
            srcH,
            0,
            &cvMetalTex
        )
        guard rc == kCVReturnSuccess,
              let cvTex = cvMetalTex,
              let inputTex = CVMetalTextureGetTexture(cvTex) else {
            return
        }

        let srcAspect = Double(srcW) / Double(srcH)
        let viewAspect = Double(dw) / Double(dh)
        var posScale = SIMD2<Float>(1, 1)
        var uvScale = SIMD2<Float>(1, 1)
        switch aspectMode {
        case .fit:
            if srcAspect > viewAspect {
                posScale = SIMD2<Float>(1, Float(viewAspect / srcAspect))
            } else {
                posScale = SIMD2<Float>(Float(srcAspect / viewAspect), 1)
            }
        case .fill:
            if srcAspect > viewAspect {
                uvScale = SIMD2<Float>(Float(viewAspect / srcAspect), 1)
            } else {
                uvScale = SIMD2<Float>(1, Float(srcAspect / viewAspect))
            }
        case .stretch:
            break
        }

        let displayScale = max(Double(dw) / Double(srcW), Double(dh) / Double(srcH))
        let targetFactor = srcW >= 3840 ? 1.0 : max(1.5, min(2.2, displayScale))
        let dstW = min(3840, max(srcW, (Int(round(Double(srcW) * targetFactor)) + 1) & ~1))
        let dstH = min(2160, max(srcH, (Int(round(Double(srcH) * targetFactor)) + 1) & ~1))

        guard let drawable = view.currentDrawable,
              let passDesc = view.currentRenderPassDescriptor,
              let cb = commandQueue.makeCommandBuffer() else {
            return
        }

        var sourceForRCAS: MTLTexture = inputTex
        if (dstW > srcW || dstH > srcH),
           ensureScaler(srcW: srcW, srcH: srcH, dstW: dstW, dstH: dstH),
           let scaler = spatialScaler,
           let outTex = upscaledTexture {
            scaler.colorTexture = inputTex
            scaler.outputTexture = outTex
            scaler.encode(commandBuffer: cb)
            sourceForRCAS = outTex
        }

        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: passDesc) else { return }
        var uniforms = RCASUniforms(posScale: posScale, uvScale: uvScale, sharpness: 0.28)
        enc.setRenderPipelineState(rcasPipeline)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<RCASUniforms>.stride, index: 0)
        enc.setFragmentTexture(sourceForRCAS, index: 0)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<RCASUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()

        let keepAlive = GPUBufferKeepAlive([pixelBuffer, cvTex])
        cb.addCompletedHandler { _ in
            _ = keepAlive
        }
        cb.present(drawable)
        cb.commit()

        needsRedraw = false
        if !hasRenderedFrame {
            hasRenderedFrame = true
            alphaValue = 1
        }
    }
}

struct NativeAVPlayerView: NSViewRepresentable {
    let store: YacineStore
    let player: AVPlayer
    let aspectMode: AspectMode
    let isFullScreenVideo: Bool
    let qualityMenuVersion: Int
    let enhanceActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.videoGravity = aspectMode.videoGravity
        view.delegate = context.coordinator
        view.pictureInPictureDelegate = context.coordinator
        context.coordinator.attachOverlay(to: view)
        context.coordinator.rebuildActionMenu(on: view)
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
        if nsView.videoGravity != aspectMode.videoGravity {
            nsView.videoGravity = aspectMode.videoGravity
        }
        context.coordinator.attachOverlay(to: nsView)
        context.coordinator.syncMetalEnhancer(player: player, aspectMode: aspectMode, enabled: enhanceActive)
        context.coordinator.syncMenuIfNeeded(on: nsView, menuVersion: qualityMenuVersion)
        context.coordinator.syncOverlayVisibility(isFullScreen: isFullScreenVideo)
    }

    @MainActor
    final class Coordinator: NSObject, AVPlayerViewDelegate, AVPlayerViewPictureInPictureDelegate {
        let store: YacineStore
        let hudController = FullscreenHUDController()
        weak var playerView: AVPlayerView?
        private var overlayHost: PassthroughOverlayHostingView<FullscreenQualityOverlayView>?
        private var metalOverlayView: MetalFXVideoRenderView? = MetalFXVideoRenderView.createIfSupported()
        private var eventMonitor: Any?
        private var menuObservers: [NSObjectProtocol] = []
        private var hudCancellables = Set<AnyCancellable>()
        private var lastMenuVersion: Int = -1
        private var lastWasFullScreen: Bool = false
        private var lastPopoverOpen: Bool = false
        private var hideHostTask: Task<Void, Never>?
        private var settleHideTask: Task<Void, Never>?
        private var inlineIdleTimer: Timer?
        private var lastMousePoint: NSPoint = NSEvent.mouseLocation
        private var menuTrackingDepth: Int = 0
        private var wasInsideInlinePlayer: Bool = false

        init(store: YacineStore) {
            self.store = store
            super.init()

            hudController.onAutoHide = { [weak self] in
                self?.performFullscreenAutoHide()
            }

            let nc = NotificationCenter.default
            menuObservers.append(
                nc.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.menuTrackingDepth += 1
                    }
                }
            )
            menuObservers.append(
                nc.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.menuTrackingDepth = max(0, self.menuTrackingDepth - 1)
                        if self.store.isFullScreenVideo {
                            self.hudController.scheduleAutoHide()
                        } else if self.wasInsideInlinePlayer {
                            self.scheduleInlineIdleHide()
                        }
                    }
                }
            )

            hudController.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.syncHostInteractivity()
                    }
                }
                .store(in: &hudCancellables)
        }

        deinit {
            inlineIdleTimer?.invalidate()
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
            }
            for observer in menuObservers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        private func syncHostInteractivity() {
            guard let host = overlayHost else { return }
            let isFullScreen = store.isFullScreenVideo
            let shouldShow = isFullScreen && hudController.shouldShowOverlayControls
            host.shouldInterceptHits = shouldShow

            if hudController.isPopoverOpen != lastPopoverOpen {
                lastPopoverOpen = hudController.isPopoverOpen
                host.invalidateIntrinsicContentSize()
            }

            hideHostTask?.cancel()
            if shouldShow {
                if host.isHidden {
                    host.isHidden = false
                }
            } else if !isFullScreen {
                host.isHidden = true
            } else {
                // Hide the hosting NSView once the fade-out finishes so AVPlayerView sees zero active overlay views when idle
                hideHostTask = Task { @MainActor [weak self, weak host] in
                    try? await Task.sleep(nanoseconds: 280_000_000)
                    guard let self, let host, !Task.isCancelled else { return }
                    if !self.store.isFullScreenVideo || !self.hudController.shouldShowOverlayControls {
                        host.isHidden = true
                    }
                }
            }
        }

        func attachOverlay(to view: AVPlayerView) {
            playerView = view
            view.window?.acceptsMouseMovedEvents = true
            installInputMonitorIfNeeded()
            guard let contentOverlay = view.contentOverlayView else { return }

            if let mView = metalOverlayView, mView.superview !== contentOverlay {
                mView.removeFromSuperview()
                contentOverlay.addSubview(mView, positioned: .below, relativeTo: overlayHost)
                NSLayoutConstraint.activate([
                    mView.topAnchor.constraint(equalTo: contentOverlay.topAnchor),
                    mView.bottomAnchor.constraint(equalTo: contentOverlay.bottomAnchor),
                    mView.leadingAnchor.constraint(equalTo: contentOverlay.leadingAnchor),
                    mView.trailingAnchor.constraint(equalTo: contentOverlay.trailingAnchor),
                ])
            }

            if let existing = overlayHost {
                if existing.superview !== contentOverlay {
                    existing.removeFromSuperview()
                    contentOverlay.addSubview(existing)
                    NSLayoutConstraint.activate([
                        existing.topAnchor.constraint(equalTo: contentOverlay.topAnchor, constant: 4),
                        existing.trailingAnchor.constraint(equalTo: contentOverlay.trailingAnchor, constant: -6),
                        existing.leadingAnchor.constraint(greaterThanOrEqualTo: contentOverlay.leadingAnchor, constant: 12),
                        existing.bottomAnchor.constraint(lessThanOrEqualTo: contentOverlay.bottomAnchor, constant: -12),
                    ])
                }
                return
            }

            let root = FullscreenQualityOverlayView(store: store, hudController: hudController)
            let host = PassthroughOverlayHostingView(rootView: root)
            host.translatesAutoresizingMaskIntoConstraints = false
            host.sizingOptions = [.intrinsicContentSize]
            host.wantsLayer = true
            host.clipsToBounds = false
            host.layer?.masksToBounds = false
            host.layer?.backgroundColor = NSColor.clear.cgColor
            host.setContentHuggingPriority(.required, for: .horizontal)
            host.setContentHuggingPriority(.required, for: .vertical)
            host.setContentCompressionResistancePriority(.required, for: .horizontal)
            host.setContentCompressionResistancePriority(.required, for: .vertical)
            host.isHidden = !store.isFullScreenVideo

            contentOverlay.addSubview(host)
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: contentOverlay.topAnchor, constant: 4),
                host.trailingAnchor.constraint(equalTo: contentOverlay.trailingAnchor, constant: -6),
                host.leadingAnchor.constraint(greaterThanOrEqualTo: contentOverlay.leadingAnchor, constant: 12),
                host.bottomAnchor.constraint(lessThanOrEqualTo: contentOverlay.bottomAnchor, constant: -12),
            ])
            overlayHost = host
            syncHostInteractivity()
        }

        func syncMetalEnhancer(player: AVPlayer, aspectMode: AspectMode, enabled: Bool) {
            metalOverlayView?.updateConfiguration(player: player, aspect: aspectMode, enabled: enabled)
        }

        func syncOverlayVisibility(isFullScreen: Bool) {
            if isFullScreen,
               let pvWin = playerView?.window,
               let ovWin = overlayHost?.window ?? playerView?.contentOverlayView?.window,
               pvWin === ovWin,
               !pvWin.styleMask.contains(.fullScreen) {
                store.isFullScreenVideo = false
                overlayHost?.isHidden = true
                overlayHost?.shouldInterceptHits = false
                lastWasFullScreen = false
                return
            }
            guard lastWasFullScreen != isFullScreen else { return }
            lastWasFullScreen = isFullScreen
            syncHostInteractivity()
            if isFullScreen {
                overlayHost?.invalidateIntrinsicContentSize()
            }
        }

        func syncMenuIfNeeded(on view: AVPlayerView, menuVersion: Int) {
            guard lastMenuVersion != menuVersion else { return }
            lastMenuVersion = menuVersion
            rebuildActionMenu(on: view)
            if store.isFullScreenVideo {
                overlayHost?.invalidateIntrinsicContentSize()
            }
        }

        func rebuildActionMenu(on view: AVPlayerView) {
            let rootMenu = NSMenu(title: "Playback Options")
            let qualityHeader = NSMenuItem(title: "Video Quality", action: nil, keyEquivalent: "")
            qualityHeader.isEnabled = false
            rootMenu.addItem(qualityHeader)

            let autoSubtitle = store.activeAutoHeightDescription.map { " (\($0))" } ?? ""
            let autoItem = NSMenuItem(
                title: "Auto (Recommended)\(autoSubtitle)",
                action: #selector(handleQualityMenuAction(_:)),
                keyEquivalent: ""
            )
            autoItem.target = self
            autoItem.representedObject = NSNumber(value: -1)
            autoItem.state = store.selectedVariantIndex == nil ? .on : .off
            rootMenu.addItem(autoItem)

            if !store.variants.isEmpty {
                rootMenu.addItem(.separator())
                for variant in store.variants {
                    let bitratePart = variant.formattedBitrate.map { " · \($0)" } ?? ""
                    let item = NSMenuItem(
                        title: "\(variant.shortQualityName)\(bitratePart)",
                        action: #selector(handleQualityMenuAction(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.representedObject = NSNumber(value: variant.index)
                    item.state = (store.selectedVariantIndex == variant.index) ? .on : .off
                    rootMenu.addItem(item)
                }
            }

            rootMenu.addItem(.separator())
            let enhHeader = NSMenuItem(title: "M1 GPU Upscale (MetalFX)", action: nil, keyEquivalent: "")
            enhHeader.isEnabled = false
            rootMenu.addItem(enhHeader)
            for mode in VideoEnhanceMode.allCases {
                let item = NSMenuItem(
                    title: mode.rawValue,
                    action: #selector(handleEnhanceMenuAction(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = mode.rawValue
                item.state = (store.videoEnhanceMode == mode) ? .on : .off
                rootMenu.addItem(item)
            }

            view.actionPopUpButtonMenu = rootMenu
        }

        @objc private func handleEnhanceMenuAction(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String,
                  let mode = VideoEnhanceMode(rawValue: raw) else { return }
            store.videoEnhanceMode = mode
            if let pv = playerView {
                rebuildActionMenu(on: pv)
            }
        }

        nonisolated func playerViewWillStartPicture(inPicture playerView: AVPlayerView) {
            Task { @MainActor [weak self] in
                self?.store.isPictureInPictureActive = true
            }
        }

        nonisolated func playerViewDidStopPicture(inPicture playerView: AVPlayerView) {
            Task { @MainActor [weak self] in
                self?.store.isPictureInPictureActive = false
            }
        }

        nonisolated func playerView(_ playerView: AVPlayerView, failedToStartPictureInPictureWithError error: Error) {
            Task { @MainActor [weak self] in
                self?.store.isPictureInPictureActive = false
            }
        }

        @objc private func handleQualityMenuAction(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? NSNumber else { return }
            let idx = raw.intValue
            if idx < 0 {
                store.selectVariant(nil)
            } else if let target = store.variants.first(where: { $0.index == idx }) {
                store.selectVariant(target)
            }
            if let pv = playerView {
                rebuildActionMenu(on: pv)
            }
        }

        nonisolated func playerViewWillEnterFullScreen(_ playerView: AVPlayerView) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inlineIdleTimer?.invalidate()
                self.inlineIdleTimer = nil
                self.wasInsideInlinePlayer = false
                self.store.isFullScreenVideo = true
                self.attachOverlay(to: playerView)
                self.overlayHost?.isHidden = false
                self.lastMousePoint = NSEvent.mouseLocation
                self.hudController.revealHUD()
                self.installInputMonitorIfNeeded()
            }
        }

        nonisolated func playerViewDidEnterFullScreen(_ playerView: AVPlayerView) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inlineIdleTimer?.invalidate()
                self.inlineIdleTimer = nil
                self.wasInsideInlinePlayer = false
                self.store.isFullScreenVideo = true
                self.attachOverlay(to: playerView)
                self.overlayHost?.isHidden = false
                self.lastMousePoint = NSEvent.mouseLocation
                self.hudController.revealHUD()
                self.installInputMonitorIfNeeded()
            }
        }

        nonisolated func playerViewWillExitFullScreen(_ playerView: AVPlayerView) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.settleHideTask?.cancel()
                self.hudController.resetForExit()
                self.store.isFullScreenVideo = false
                self.overlayHost?.isHidden = true
                self.overlayHost?.shouldInterceptHits = false
            }
        }

        nonisolated func playerViewDidExitFullScreen(_ playerView: AVPlayerView) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.settleHideTask?.cancel()
                self.hudController.resetForExit()
                self.store.isFullScreenVideo = false
                self.overlayHost?.isHidden = true
            }
        }

        private func findDesktopContentView() -> NSView? {
            func search(_ view: NSView?) -> NSView? {
                guard let view else { return nil }
                if String(describing: type(of: view)) == "AVDesktopPlayerViewContentView" {
                    return view
                }
                for sub in view.subviews {
                    if let hit = search(sub) {
                        return hit
                    }
                }
                return nil
            }
            if let hit = search(playerView) {
                return hit
            }
            let fsRoot = overlayHost?.window?.contentView ?? playerView?.contentOverlayView?.window?.contentView
            return search(fsRoot)
        }

        private func isNativeControlsShowing(on dcv: NSView) -> Bool {
            let sel = NSSelectorFromString("showingPlaybackControls")
            guard dcv.responds(to: sel),
                  let num = dcv.value(forKey: "showingPlaybackControls") as? NSNumber else {
                return false
            }
            return num.boolValue
        }

        private func showNativePlaybackControlsIfNeeded() {
            guard let dcv = findDesktopContentView(), !isNativeControlsShowing(on: dcv) else { return }
            let showSel = NSSelectorFromString("_showControlsWithTrigger:")
            if dcv.responds(to: showSel),
               let imp = class_getMethodImplementation(type(of: dcv), showSel) {
                typealias TriggerFn = @convention(c) (AnyObject, Selector, UInt) -> Void
                unsafeBitCast(imp, to: TriggerFn.self)(dcv, showSel, 1)
                return
            }
            let fallbackSel = NSSelectorFromString("showControlsTemporarily")
            if dcv.responds(to: fallbackSel) {
                dcv.perform(fallbackSel)
            }
        }

        private func hideNativePlaybackControls() {
            guard NSEvent.pressedMouseButtons == 0,
                  menuTrackingDepth == 0,
                  !hudController.isPopoverOpen,
                  let dcv = findDesktopContentView() else { return }

            // AppKit refuses to hide AVPlayerView floating controls whenever _mouseIsOverControlsView is true
            // (for example, when the cursor stops on top of the bar or right after clicking the fullscreen button).
            if class_getInstanceVariable(type(of: dcv), "_mouseIsOverControlsView") != nil {
                dcv.setValue(false, forKey: "_mouseIsOverControlsView")
            }

            let hideSel = NSSelectorFromString("_hideControlsWithTrigger:")
            if dcv.responds(to: hideSel),
               let imp = class_getMethodImplementation(type(of: dcv), hideSel) {
                typealias TriggerFn = @convention(c) (AnyObject, Selector, UInt) -> Void
                unsafeBitCast(imp, to: TriggerFn.self)(dcv, hideSel, 0)
            }
        }

        private func performFullscreenAutoHide() {
            guard store.isFullScreenVideo else { return }
            if NSEvent.pressedMouseButtons != 0 || menuTrackingDepth > 0 || hudController.isPopoverOpen {
                hudController.scheduleAutoHide()
                return
            }
            settleHideTask?.cancel()
            hudController.hideNowForIdle()
            hideNativePlaybackControls()

            // Re-verify once after overlayHost finishes hiding (280ms) in case AppKit layout re-triggered tracking hover.
            settleHideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 340_000_000)
                guard let self,
                      !Task.isCancelled,
                      self.store.isFullScreenVideo,
                      !self.hudController.shouldShowOverlayControls,
                      NSEvent.pressedMouseButtons == 0,
                      self.menuTrackingDepth == 0 else { return }
                if let dcv = self.findDesktopContentView(), self.isNativeControlsShowing(on: dcv) {
                    self.hideNativePlaybackControls()
                }
            }
        }

        private func scheduleInlineIdleHide() {
            settleHideTask?.cancel()
            inlineIdleTimer?.invalidate()
            let timer = Timer(timeInterval: hudController.autoHideDelay, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.store.isFullScreenVideo else { return }
                    if NSEvent.pressedMouseButtons != 0 || self.menuTrackingDepth > 0 {
                        self.scheduleInlineIdleHide()
                        return
                    }
                    self.hideNativePlaybackControls()

                    self.settleHideTask?.cancel()
                    self.settleHideTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 240_000_000)
                        guard let self,
                              !Task.isCancelled,
                              !self.store.isFullScreenVideo,
                              NSEvent.pressedMouseButtons == 0,
                              self.menuTrackingDepth == 0 else { return }
                        if let dcv = self.findDesktopContentView(), self.isNativeControlsShowing(on: dcv) {
                            self.hideNativePlaybackControls()
                        }
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            inlineIdleTimer = timer
        }

        private func installInputMonitorIfNeeded() {
            if eventMonitor != nil { return }
            lastMousePoint = NSEvent.mouseLocation
            // Do NOT monitor .mouseEntered (relayout fires synthetic enter events and prevents auto-hide).
            // Note: AVPlayerView presents fullscreen inside AVDetachedFullscreenWindow, which is overlayHost?.window
            // rather than playerView?.window, so accept events from either window.
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged, .scrollWheel, .leftMouseDown, .rightMouseDown, .keyDown]
            ) { [weak self] event in
                guard let self else { return event }

                if self.store.isFullScreenVideo {
                    let fsWin = self.overlayHost?.window ?? self.playerView?.contentOverlayView?.window
                    if let evWin = event.window,
                       evWin !== fsWin,
                       evWin !== self.playerView?.window {
                        return event
                    }

                    self.settleHideTask?.cancel()
                    switch event.type {
                    case .mouseMoved, .leftMouseDragged:
                        let currentPt = NSEvent.mouseLocation
                        let dist = hypot(currentPt.x - self.lastMousePoint.x, currentPt.y - self.lastMousePoint.y)
                        guard dist >= 2.0 else { return event }
                        self.lastMousePoint = currentPt
                        self.hudController.revealHUD()
                        self.showNativePlaybackControlsIfNeeded()
                    case .keyDown:
                        if event.keyCode == 53, self.hudController.isPopoverOpen {
                            Task { @MainActor [weak self] in
                                self?.hudController.closePopover()
                            }
                            return nil
                        }
                        self.hudController.revealHUD()
                        self.showNativePlaybackControlsIfNeeded()
                    case .leftMouseDown, .rightMouseDown:
                        if self.hudController.isPopoverOpen, let host = self.overlayHost {
                            let pt = host.convert(event.locationInWindow, from: nil)
                            if !host.bounds.contains(pt) {
                                Task { @MainActor [weak self] in
                                    self?.hudController.closePopover()
                                }
                            }
                        }
                        self.hudController.revealHUD()
                        self.showNativePlaybackControlsIfNeeded()
                    default:
                        self.hudController.revealHUD()
                        self.showNativePlaybackControlsIfNeeded()
                    }
                    return event
                }

                // Inline windowed mode: also auto-hide the floating controls bar after cursor stops inside the player.
                guard let pv = self.playerView,
                      let pvWin = pv.window,
                      !self.store.stageMode.isWebVisible else {
                    return event
                }
                if let evWin = event.window, evWin !== pvWin {
                    return event
                }

                let winPt = event.window === pvWin
                    ? event.locationInWindow
                    : pvWin.convertPoint(fromScreen: NSEvent.mouseLocation)
                let localPt = pv.convert(winPt, from: nil)
                let isInsidePlayer = pv.bounds.contains(localPt)

                switch event.type {
                case .mouseMoved, .leftMouseDragged:
                    if isInsidePlayer {
                        let currentPt = NSEvent.mouseLocation
                        let dist = hypot(currentPt.x - self.lastMousePoint.x, currentPt.y - self.lastMousePoint.y)
                        guard dist >= 2.0 else { return event }
                        self.lastMousePoint = currentPt
                        self.wasInsideInlinePlayer = true
                        self.settleHideTask?.cancel()
                        self.showNativePlaybackControlsIfNeeded()
                        self.scheduleInlineIdleHide()
                    } else if self.wasInsideInlinePlayer {
                        self.wasInsideInlinePlayer = false
                        self.settleHideTask?.cancel()
                        self.inlineIdleTimer?.invalidate()
                        self.inlineIdleTimer = nil
                        self.hideNativePlaybackControls()
                    }
                case .leftMouseDown, .rightMouseDown, .scrollWheel:
                    if isInsidePlayer {
                        self.wasInsideInlinePlayer = true
                        self.settleHideTask?.cancel()
                        self.showNativePlaybackControlsIfNeeded()
                        self.scheduleInlineIdleHide()
                    }
                default:
                    break
                }
                return event
            }
        }
    }
}

struct FullscreenQualityOverlayView: View {
    @ObservedObject var store: YacineStore
    @ObservedObject var hudController: FullscreenHUDController

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var qualityNamespace

    private let cardShape = ConcentricRectangle(corners: .concentric(minimum: .fixed(20)), isUniform: true)
    private let rowShape = ConcentricRectangle(corners: .concentric(minimum: .fixed(12)), isUniform: true)

    private var isVisible: Bool {
        store.isFullScreenVideo && hudController.shouldShowOverlayControls
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .trailing, spacing: 8) {
                triggerButton
                    .glassEffectID("fullscreenQualityTrigger", in: qualityNamespace)

                if hudController.isPopoverOpen {
                    qualityPopoverCard
                        .glassEffectID("fullscreenQualityMenu", in: qualityNamespace)
                        .glassEffectTransition(.matchedGeometry)
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .topTrailing)),
                                removal: .opacity.combined(with: .scale(scale: 0.94, anchor: .topTrailing))
                            )
                        )
                }
            }
        }
        // Reserve generous bleed margin so Liquid Glass specular halos and drop shadows are never cropped
        .padding(.top, 12)
        .padding(.trailing, 14)
        .padding(.leading, 26)
        .padding(.bottom, 28)
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.96, anchor: .topTrailing)
        .allowsHitTesting(isVisible)
        .animation(.spring(response: 0.26, dampingFraction: 0.88), value: hudController.isPopoverOpen)
        .animation(.easeInOut(duration: 0.22), value: isVisible)
    }

    private var triggerButton: some View {
        Button {
            hudController.togglePopover()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text(store.currentQualityButtonTitle)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .frame(minWidth: 44, minHeight: 44)
            .fixedSize(horizontal: true, vertical: true)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(
            (reduceTransparency || contrast == .increased) ? .identity : .regular.interactive(),
            in: Capsule()
        )
        .background {
            if reduceTransparency || contrast == .increased {
                Capsule()
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.96))
            }
        }
        .overlay {
            if reduceTransparency || contrast == .increased {
                Capsule()
                    .stroke(
                        Color.primary.opacity(contrast == .increased ? 0.7 : 0.25),
                        lineWidth: contrast == .increased ? 1.5 : 1
                    )
            }
        }
        .accessibilityLabel("Stream Quality, \(store.currentQualityButtonTitle)")
        .accessibilityHint("Opens video quality options without interrupting playback")
    }

    private var qualityPopoverCard: some View {
        GlassEffectContainer(spacing: 6) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label("Video Quality", systemImage: "sparkles.tv")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    if store.videoResolutionText != "—" {
                        Text(store.videoResolutionText)
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

                ScrollView {
                    VStack(spacing: 4) {
                        qualityOptionRow(
                            title: "Auto",
                            subtitle: store.activeAutoHeightDescription ?? "Adaptive (Highest Available)",
                            badge: "ABR",
                            isSelected: store.selectedVariantIndex == nil,
                            isCurrentlyStreaming: store.selectedVariantIndex == nil
                        ) {
                            store.selectVariant(nil)
                            hudController.closePopover()
                        }

                        if store.variants.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "info.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Single-tier live stream (\(store.activeTrackResolutionBadge))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .frame(minHeight: 36)
                        } else {
                            ForEach(store.variants) { variant in
                                let bitrateLabel = variant.formattedBitrate.map { "\(variant.resolution) · \($0)" } ?? variant.resolution
                                let isAutoStreamingThis = store.selectedVariantIndex == nil && variant.shortQualityName == store.activeTrackResolutionBadge
                                qualityOptionRow(
                                    title: variant.shortQualityName,
                                    subtitle: bitrateLabel.isEmpty ? variant.label : bitrateLabel,
                                    badge: variant.qualityBadgeTag,
                                    isSelected: store.selectedVariantIndex == variant.index,
                                    isCurrentlyStreaming: isAutoStreamingThis
                                ) {
                                    store.selectVariant(variant)
                                    hudController.closePopover()
                                }
                            }
                        }
                    }
                    .padding(2)
                }
                .frame(maxHeight: 300)
                .scrollEdgeEffectStyle(.soft, for: .all)

                Divider()
                    .opacity(0.4)
                    .padding(.horizontal, 10)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("M1 MetalFX Upscale")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if store.isMetalFXCurrentlyActive {
                            Text("ACTIVE")
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.red, in: Capsule())
                        }
                    }
                    HStack(spacing: 6) {
                        ForEach(VideoEnhanceMode.allCases) { mode in
                            let sel = store.videoEnhanceMode == mode
                            Button {
                                store.videoEnhanceMode = mode
                            } label: {
                                Text(mode.shortTitle)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(sel && reduceTransparency ? Color.white : Color.primary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 5)
                            }
                            .buttonStyle(.plain)
                            .adaptiveGlassControl(in: Capsule(), tint: sel ? .red : nil)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

                if !store.activeBitrateText.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.caption2.weight(.semibold))
                        Text("Live throughput: \(store.activeBitrateText)")
                            .font(.caption2.weight(.medium).monospacedDigit())
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
            .padding(8)
            .frame(width: 292)
            .glassEffect(
                (reduceTransparency || contrast == .increased) ? .identity : .regular,
                in: cardShape
            )
            .background {
                if reduceTransparency || contrast == .increased {
                    cardShape
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.97))
                }
            }
            .overlay {
                cardShape
                    .stroke(
                        contrast == .increased
                            ? Color.primary.opacity(0.65)
                            : Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.10),
                        lineWidth: contrast == .increased ? 1.5 : 0.75
                    )
            }
            .shadow(color: .black.opacity(0.32), radius: 22, y: 10)
        }
    }

    private func qualityOptionRow(
        title: String,
        subtitle: String,
        badge: String?,
        isSelected: Bool,
        isCurrentlyStreaming: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let glass: Glass = (!reduceTransparency && contrast != .increased && isSelected)
            ? .regular.tint(Color.red.opacity(colorScheme == .dark ? 0.50 : 0.34)).interactive()
            : .identity

        return Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.red : Color.secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 13.5, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(.primary)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                                .background(
                                    isSelected ? Color.red : Color.primary.opacity(0.10),
                                    in: Capsule()
                                )
                        }
                        if isCurrentlyStreaming && !isSelected {
                            Label("Playing", systemImage: "waveform")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(rowShape)
            .glassEffect(glass, in: rowShape)
            .background {
                if isSelected && (reduceTransparency || contrast == .increased) {
                    rowShape.fill(Color.red.opacity(contrast == .increased ? 0.24 : 0.16))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - WebKit Sniffer & Embedded Web Player (url_type 4, 5, 6)
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

struct LiveWebPlayerView: NSViewRepresentable {
    let requestID: UUID?
    let url: URL?
    let userAgent: String
    let referer: String
    let keyword: String
    let onSniffedMedia: (UUID, String, String, String, String) -> Void
    let onError: (UUID, String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSniffedMedia: onSniffedMedia, onError: onError)
    }

    func makeNSView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(WeakScriptHandler(delegate: context.coordinator), name: "yacineSniffer")

        let hookJS = #"""
        (function() {
            if (window.__yacineSnifferInstalled) return;
            window.__yacineSnifferInstalled = true;
            const reported = new Set();
            const mediaExtRe = /\.(m3u8|mp4|mov)(\?|#|$)/i;
            const mediaQueryRe = /\.m3u8(\?|#|&|$)/i;
            const assetSkipRe = /\.(js|css|png|jpe?g|gif|svg|ico|woff2?|ttf|map)(\?|#|$)/i;
            const adSkipRe = /(doubleclick|googlesyndication|googletagmanager|google-analytics|adsystem|popads)/i;

            function report(rawUrl) {
                try {
                    if (!rawUrl || typeof rawUrl !== 'string') return;
                    const trimmed = rawUrl.trim();
                    if (!trimmed || trimmed.startsWith('blob:') || trimmed.startsWith('data:')) return;
                    const parsed = new URL(trimmed, window.location.href);
                    const abs = parsed.href;
                    const pathname = (parsed.pathname || '').toLowerCase();
                    if (!abs.startsWith('http://') && !abs.startsWith('https://')) return;
                    if (adSkipRe.test(abs) || assetSkipRe.test(abs)) return;
                    const kw = (window.__yacineKeyword || 'm3u8').toLowerCase();
                    const customMatch = (kw && kw !== 'm3u8' && kw !== 'none' && pathname.indexOf(kw) !== -1);
                    if (mediaExtRe.test(pathname) || mediaQueryRe.test(abs) || pathname.endsWith('.mpd') || customMatch) {
                        if (reported.has(abs)) return;
                        reported.add(abs);
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.yacineSniffer) {
                            window.webkit.messageHandlers.yacineSniffer.postMessage({
                                url: abs,
                                referer: window.location.href || '',
                                ua: navigator.userAgent || ''
                            });
                        }
                    }
                } catch (e) {}
            }

            if (window.fetch) {
                const origFetch = window.fetch;
                window.fetch = function(input, init) {
                    try {
                        const u = (typeof input === 'string') ? input : (input && input.url);
                        report(u);
                    } catch (e) {}
                    return origFetch.apply(this, arguments);
                };
            }

            const origOpen = XMLHttpRequest.prototype.open;
            XMLHttpRequest.prototype.open = function(method, url) {
                try { report(typeof url === 'string' ? url : String(url)); } catch (e) {}
                return origOpen.apply(this, arguments);
            };

            const mediaDesc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
            if (mediaDesc && mediaDesc.set) {
                Object.defineProperty(HTMLMediaElement.prototype, 'src', {
                    get: mediaDesc.get,
                    set: function(v) {
                        report(v);
                        return mediaDesc.set.call(this, v);
                    },
                    configurable: true
                });
            }

            try {
                const po = new PerformanceObserver((list) => {
                    for (const entry of list.getEntries()) {
                        report(entry.name);
                    }
                });
                po.observe({ type: 'resource', buffered: true });
            } catch (e) {}

            setInterval(() => {
                try {
                    document.querySelectorAll('video, source, video source').forEach(el => {
                        report(el.src || el.getAttribute('src'));
                    });
                    if (performance && performance.getEntriesByType) {
                        performance.getEntriesByType('resource').forEach(r => report(r.name));
                    }
                } catch (e) {}
            }, 600);
        })();
        """#

        let script = WKUserScript(source: hookJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        contentController.addUserScript(script)

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.webView = nsView
        context.coordinator.onSniffedMedia = onSniffedMedia
        context.coordinator.onError = onError

        guard let reqID = requestID, let targetURL = url else {
            if context.coordinator.currentRequestID != nil {
                context.coordinator.currentRequestID = nil
                nsView.stopLoading()
                nsView.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(m=>{try{m.pause();m.src='';}catch(e){}});", completionHandler: nil)
                nsView.loadHTMLString("", baseURL: nil)
            }
            return
        }

        guard context.coordinator.currentRequestID != reqID else { return }
        context.coordinator.currentRequestID = reqID

        if !userAgent.isEmpty {
            nsView.customUserAgent = userAgent
        }
        let safeKw = keyword
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        nsView.evaluateJavaScript("window.__yacineKeyword = '\(safeKw)';", completionHandler: nil)

        if let ytEmbedURL = Self.youtubeEmbedURL(from: targetURL) {
            let html = """
            <!doctype html><html><body style="margin:0;background:#000;overflow:hidden;">
            <iframe src="\(ytEmbedURL.absoluteString)" style="position:fixed;inset:0;width:100%;height:100%;border:0;" allow="autoplay; fullscreen; encrypted-media" allowfullscreen></iframe>
            </body></html>
            """
            nsView.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com/"))
            return
        }

        var req = URLRequest(url: targetURL)
        if !referer.isEmpty {
            req.setValue(referer, forHTTPHeaderField: "Referer")
        }
        nsView.load(req)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.currentRequestID = nil
        nsView.stopLoading()
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "yacineSniffer")
        nsView.loadHTMLString("", baseURL: nil)
    }

    private static func youtubeEmbedURL(from url: URL) -> URL? {
        guard let host = url.host?.lowercased() else { return nil }
        var videoID: String? = nil
        if host.contains("youtu.be") {
            let trimmed = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !trimmed.isEmpty { videoID = trimmed }
        } else if host.contains("youtube.com") {
            if url.path.hasPrefix("/embed/") {
                return URL(string: "\(url.scheme ?? "https")://\(host)\(url.path)?autoplay=1&playsinline=1&rel=0")
            }
            if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let v = comps.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty {
                videoID = v
            }
        }
        guard let vid = videoID else { return nil }
        return URL(string: "https://www.youtube.com/embed/\(vid)?autoplay=1&playsinline=1&rel=0")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        var onSniffedMedia: (UUID, String, String, String, String) -> Void
        var onError: (UUID, String) -> Void
        var currentRequestID: UUID? = nil
        weak var webView: WKWebView?

        init(onSniffedMedia: @escaping (UUID, String, String, String, String) -> Void, onError: @escaping (UUID, String) -> Void) {
            self.onSniffedMedia = onSniffedMedia
            self.onError = onError
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "yacineSniffer",
                  let reqID = currentRequestID,
                  let dict = message.body as? [String: Any],
                  let mediaURL = dict["url"] as? String else {
                return
            }
            let referer = (dict["referer"] as? String) ?? ""
            let ua = (dict["ua"] as? String) ?? ""
            let cookieStore = webView?.configuration.websiteDataStore.httpCookieStore
            let targetHost = (URL(string: mediaURL)?.host ?? "").lowercased()
            let refHost = (URL(string: referer)?.host ?? "").lowercased()

            guard let cookieStore else {
                Task { @MainActor [weak self] in
                    guard let self, self.currentRequestID == reqID else { return }
                    self.onSniffedMedia(reqID, mediaURL, referer, ua, "")
                }
                return
            }

            cookieStore.getAllCookies { [weak self] cookies in
                let relevant = cookies.filter { cookie in
                    let dom = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                    guard !dom.isEmpty else { return false }
                    return targetHost.hasSuffix(dom) || refHost.hasSuffix(dom)
                }
                let cookieHeader = relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                Task { @MainActor [weak self] in
                    guard let self, self.currentRequestID == reqID else { return }
                    self.onSniffedMedia(reqID, mediaURL, referer, ua, cookieHeader)
                }
            }
        }

        // Block third-party popup windows cleanly while allowing inline playback
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            return nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            reportWebError(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            reportWebError(error)
        }

        private func reportWebError(_ error: Error) {
            let nsErr = error as NSError
            if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled { return }
            guard let reqID = currentRequestID else { return }
            Task { @MainActor [weak self] in
                guard let self, self.currentRequestID == reqID else { return }
                self.onError(reqID, nsErr.localizedDescription)
            }
        }
    }
}

// MARK: - Main SwiftUI Content View (macOS Liquid Glass Architecture)
// MARK: - Shared Adaptive HIG Surfaces & Liquid Glass Modifiers
private struct AdaptiveGlassControlModifier<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool
    let isElevatedOpaqueFallback: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    private var glassStyle: Glass {
        guard !reduceTransparency else { return .identity }
        var g: Glass = .regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }

    func body(content: Content) -> some View {
        content
            .glassEffect(glassStyle, in: shape)
            .background {
                if reduceTransparency && isElevatedOpaqueFallback {
                    if let tint {
                        shape.fill(tint.opacity(contrast == .increased ? 0.92 : 0.85))
                    } else {
                        shape.fill(Color(nsColor: .controlBackgroundColor))
                    }
                }
            }
            .overlay {
                if reduceTransparency || contrast == .increased {
                    shape.stroke(
                        contrast == .increased
                            ? Color.primary.opacity(tint == nil ? 0.65 : 0.85)
                            : Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.14),
                        lineWidth: contrast == .increased ? 1.5 : 1
                    )
                }
            }
    }
}

private struct ContentCardSurfaceModifier: ViewModifier {
    let isPlaying: Bool
    let isHovered: Bool
    let cornerRadius: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var fillColor: Color {
        if isPlaying {
            return Color.red.opacity(colorScheme == .dark ? 0.16 : 0.10)
        }
        if isHovered {
            return colorScheme == .dark
                ? Color(nsColor: .controlBackgroundColor).opacity(0.95)
                : Color(nsColor: .selectedContentBackgroundColor).opacity(0.08)
        }
        return colorScheme == .dark
            ? Color(nsColor: .controlBackgroundColor).opacity(0.68)
            : Color(nsColor: .controlBackgroundColor)
    }

    private var strokeColor: Color {
        if isPlaying { return .red }
        if contrast == .increased {
            return Color.primary.opacity(isHovered ? 0.80 : 0.45)
        }
        return Color.primary.opacity(colorScheme == .dark ? (isHovered ? 0.22 : 0.10) : (isHovered ? 0.18 : 0.09))
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(fillColor, in: shape)
            .overlay {
                shape.strokeBorder(strokeColor, lineWidth: isPlaying || contrast == .increased ? 1.5 : 1)
            }
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.18 : 0.06),
                radius: isHovered ? 10 : 5,
                y: isHovered ? 4 : 2
            )
    }
}

private extension View {
    func adaptiveGlassControl<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = true,
        elevatedFallback: Bool = true
    ) -> some View {
        modifier(AdaptiveGlassControlModifier(
            shape: shape,
            tint: tint,
            interactive: interactive,
            isElevatedOpaqueFallback: elevatedFallback
        ))
    }

    func contentCardSurface(isPlaying: Bool, isHovered: Bool = false, cornerRadius: CGFloat = 14) -> some View {
        modifier(ContentCardSurfaceModifier(isPlaying: isPlaying, isHovered: isHovered, cornerRadius: cornerRadius))
    }
}

// MARK: - Window Chrome Configurator & Wrapping Flow Layout
private struct WindowChromeConfigurator: NSViewRepresentable {
    let cornerRadius: CGFloat
    let titlebarHeight: CGFloat

    final class Coordinator: NSObject {
        weak var window: NSWindow?
        var targetCornerRadius: CGFloat
        var targetTitlebarHeight: CGFloat
        private var observers: [NSObjectProtocol] = []

        init(targetCornerRadius: CGFloat, targetTitlebarHeight: CGFloat) {
            self.targetCornerRadius = targetCornerRadius
            self.targetTitlebarHeight = targetTitlebarHeight
        }

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func attach(to window: NSWindow) {
            guard self.window !== window else { return }
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
            self.window = window

            let nc = NotificationCenter.default
            let chromeNames: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didExitFullScreenNotification,
                NSWindow.didBecomeKeyNotification
            ]
            for name in chromeNames {
                let token = nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.applyChromeIfNeeded()
                }
                observers.append(token)
            }

            let fullScreenEnterToken = nc.addObserver(
                forName: NSWindow.willEnterFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.setThemeTitlebarHeight(-1.0)
            }
            observers.append(fullScreenEnterToken)
        }

        func applyChromeIfNeeded() {
            guard let window,
                  window.styleMask.contains(.titled) else { return }

            if window.styleMask.contains(.fullScreen) {
                setThemeTitlebarHeight(-1.0)
                return
            }

            setThemeTitlebarHeight(targetTitlebarHeight)

            let cornerSel = NSSelectorFromString("_setCornerRadius:")
            if window.responds(to: cornerSel) {
                let current = (window.value(forKey: "_cornerRadius") as? NSNumber)?.doubleValue
                if current == nil || abs((current ?? 0) - Double(targetCornerRadius)) > 0.1 {
                    typealias SetCornerRadiusFn = @convention(c) (AnyObject, Selector, CGFloat) -> Void
                    if let imp = class_getMethodImplementation(type(of: window), cornerSel) {
                        let fn = unsafeBitCast(imp, to: SetCornerRadiusFn.self)
                        fn(window, cornerSel, targetCornerRadius)
                    }
                    let updateMaskSel = NSSelectorFromString("_updateWindowCornerMask")
                    if window.responds(to: updateMaskSel) {
                        window.perform(updateMaskSel)
                    }
                    window.invalidateShadow()
                }
            }
        }

        private func setThemeTitlebarHeight(_ height: CGFloat) {
            guard let themeView = window?.contentView?.superview else { return }
            let getSel = NSSelectorFromString("customTitlebarHeight")
            let setSel = NSSelectorFromString("setCustomTitlebarHeight:")
            guard themeView.responds(to: setSel) else { return }

            if themeView.responds(to: getSel),
               let getImp = class_getMethodImplementation(type(of: themeView), getSel) {
                typealias GetHeightFn = @convention(c) (AnyObject, Selector) -> CGFloat
                let getFn = unsafeBitCast(getImp, to: GetHeightFn.self)
                if abs(getFn(themeView, getSel) - height) <= 0.1 {
                    return
                }
            }

            if let setImp = class_getMethodImplementation(type(of: themeView), setSel) {
                typealias SetHeightFn = @convention(c) (AnyObject, Selector, CGFloat) -> Void
                let setFn = unsafeBitCast(setImp, to: SetHeightFn.self)
                setFn(themeView, setSel, height)
                themeView.needsLayout = true
                themeView.layoutSubtreeIfNeeded()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(targetCornerRadius: cornerRadius, targetTitlebarHeight: titlebarHeight)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            configure(window: view?.window, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.targetCornerRadius = cornerRadius
        context.coordinator.targetTitlebarHeight = titlebarHeight
        DispatchQueue.main.async { [weak nsView] in
            configure(window: nsView?.window, coordinator: context.coordinator)
        }
    }

    private func configure(window: NSWindow?, coordinator: Coordinator) {
        guard let window,
              window.styleMask.contains(.titled),
              window.styleMask.contains(.closable) else { return }

        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.acceptsMouseMovedEvents = true

        // Unified transparent toolbar keeps native macOS traffic lights inset at (19, 29..43)
        // with customTitlebarHeight = 72pt (centerY = 36pt) so the 36x36 toggle sits 14pt below
        // the sidebar top border and 16pt inside its trailing border, aligned with traffic lights.
        if window.toolbar == nil {
            let toolbar = NSToolbar(identifier: "YacineMainToolbar")
            toolbar.allowsUserCustomization = false
            window.toolbar = toolbar
        }
        if window.toolbarStyle != .unified {
            window.toolbarStyle = .unified
        }

        coordinator.attach(to: window)
        coordinator.applyChromeIfNeeded()
    }
}

private struct WrappingFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxUsedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0 && rowWidth + horizontalSpacing + size.width > maxWidth {
                maxUsedWidth = max(maxUsedWidth, rowWidth)
                totalHeight += rowHeight + verticalSpacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth = rowWidth == 0 ? size.width : (rowWidth + horizontalSpacing + size.width)
                rowHeight = max(rowHeight, size.height)
            }
        }
        maxUsedWidth = max(maxUsedWidth, rowWidth)
        totalHeight += rowHeight

        let resolvedWidth = proposal.width.map { min(maxUsedWidth, $0) } ?? maxUsedWidth
        return CGSize(width: max(resolvedWidth, maxUsedWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX + 0.5 {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Main Workspace (Full-Bleed Content Layer + Floating Liquid Glass Drawer)
struct ContentView: View {
    @StateObject private var store = YacineStore()
    @Namespace private var drawerNamespace

    // Apple HIG macOS 26 Tahoe native toolbar & concentric squircle geometry:
    // Custom 72pt unified titlebar places traffic lights on centerY = 36pt (close at minX = 19, topY = 29..43).
    // Outer window squircle = 26pt -> 4pt margin -> sidebar squircle = 22pt.
    // 36x36 toggle centers at y = 36pt (topY = 18pt -> 14pt below sidebar top edge) and 16pt inside
    // the sidebar trailing edge so it clears the top-right 22pt squircle corner in both directions.
    private let windowCornerRadius: CGFloat = 26
    private let headerHeight: CGFloat = 72
    private let sidebarWidth: CGFloat = 276
    private let sidebarOuterMargin: CGFloat = 4

    private var leadingContentInset: CGFloat {
        store.isSidebarVisible ? (sidebarWidth + sidebarOuterMargin * 2) : 0
    }

    private let toggleSize: CGFloat = 36
    private var toggleLeadingOffset: CGFloat {
        store.isSidebarVisible
            ? (sidebarOuterMargin + sidebarWidth - 16 - toggleSize)
            : (79 + 13)
    }

    private var toggleTopOffset: CGFloat {
        (headerHeight - toggleSize) / 2
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            DetailWorkspaceView(
                store: store,
                leadingSafeInset: leadingContentInset,
                headerHeight: headerHeight
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if store.isSidebarVisible {
                FloatingSidebarView(
                    store: store,
                    width: sidebarWidth,
                    namespace: drawerNamespace
                )
                .padding(.all, sidebarOuterMargin)
                .transition(.move(edge: .leading).combined(with: .opacity))
                .zIndex(10)
            }

            // Adaptive HIG Liquid Glass sidebar toggle aligned to native traffic-light centerline (centerY = 36pt)
            SidebarToggleButton(isSidebarVisible: store.isSidebarVisible, size: toggleSize) {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.88)) {
                    store.isSidebarVisible.toggle()
                }
            }
            .padding(.leading, toggleLeadingOffset)
            .padding(.top, toggleTopOffset)
            .zIndex(30)
        }
        .containerShape(RoundedRectangle(cornerRadius: windowCornerRadius, style: .continuous))
        .ignoresSafeArea(.all, edges: .vertical)
        .background(WindowChromeConfigurator(cornerRadius: windowCornerRadius, titlebarHeight: headerHeight))
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .animation(.spring(response: 0.30, dampingFraction: 0.88), value: store.isSidebarVisible)
        .preferredColorScheme(store.appearanceMode.colorScheme)
        .onChange(of: store.searchText) { _, newValue in
            store.performSearch(newValue)
        }
        .onChange(of: store.selection) { _, newValue in
            Task { await store.handleSelectionChange(newValue) }
        }
        .task {
            await store.bootstrap()
        }
    }
}

// MARK: - Sidebar Toggle (Apple HIG 36pt Liquid Glass Toolbar Platter Aligned with Traffic Lights)
private struct SidebarToggleButton: View {
    let isSidebarVisible: Bool
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 16, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.primary.opacity(0.84))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .adaptiveGlassControl(in: Circle())
        .keyboardShortcut("s", modifiers: [.command, .control])
        .help(isSidebarVisible ? "Hide Sidebar (⌃⌘S)" : "Show Sidebar (⌃⌘S)")
        .accessibilityLabel(isSidebarVisible ? "Hide Sidebar" : "Show Sidebar")
    }
}

// MARK: - Floating Liquid Glass Navigation Drawer (macOS 26 HIG)
private struct CategoryRowPresentation {
    let title: String
    let systemImage: String
    let badgeText: String?

    static func resolve(_ category: YacineCategory) -> CategoryRowPresentation {
        let upper = category.name.uppercased()
        let defaultBadge = (category.child_count ?? 0) > 0 ? "\(category.child_count ?? 0)" : nil

        if upper.contains("BEIN SPORTS") {
            if upper.contains("1080") {
                return CategoryRowPresentation(title: "beIN SPORTS", systemImage: "soccerball", badgeText: "1080P")
            }
            if upper.contains("720") {
                return CategoryRowPresentation(title: "beIN SPORTS", systemImage: "trophy.fill", badgeText: "720P")
            }
            if upper.contains("360") {
                return CategoryRowPresentation(title: "beIN SPORTS", systemImage: "tv.inset.filled", badgeText: "360P")
            }
            if upper.contains("244") || upper.contains("240") {
                return CategoryRowPresentation(title: "beIN SPORTS", systemImage: "dot.radiowaves.left.and.right", badgeText: "244P")
            }
        }

        let symbol: String
        if upper.contains("ENTERTAINMENT") {
            symbol = "sparkles.tv"
        } else if upper.contains("ARABIC") {
            symbol = "globe.europe.africa.fill"
        } else if upper.contains("MBC") {
            symbol = "antenna.radiowaves.left.and.right"
        } else if upper.contains("FRANCE") {
            symbol = "film.stack.fill"
        } else if upper.contains("TURKISH") {
            symbol = "moon.stars.fill"
        } else if upper.contains("KIDS") {
            symbol = "teddybear.fill"
        } else if upper.contains("WEYYAK") {
            symbol = "play.rectangle.on.rectangle.fill"
        } else if upper.contains("SHAHID") {
            symbol = "crown.fill"
        } else {
            symbol = "play.tv"
        }

        return CategoryRowPresentation(title: category.name, systemImage: symbol, badgeText: defaultBadge)
    }
}

struct FloatingSidebarView: View {
    @ObservedObject var store: YacineStore
    let width: CGFloat
    let namespace: Namespace.ID

    @Namespace private var categoryGlassNS
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    // Concentric with the 26pt window squircle across the 4pt outer margin (26 - 4 = 22pt continuous squircle)
    private let drawerShape = ConcentricRectangle(corners: .concentric(minimum: .fixed(22)), isUniform: true)
    private let innerRowShape = ConcentricRectangle(corners: .concentric(minimum: .fixed(12)), isUniform: true)

    private var adaptiveGoldColor: Color {
        colorScheme == .light
            ? Color(red: 0.78, green: 0.44, blue: 0.0)
            : Color.yellow
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 0) {
                // Top chrome clearance for elevated traffic lights & top-trailing toggle button, followed by brand masthead
                HStack(spacing: 10) {
                    if let brandImg = AppIconProvider.bundledImage(
                        named: colorScheme == .dark ? "AppBrand-Dark.png" : "AppBrand-Default.png"
                    ) {
                        Image(nsImage: brandImg)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 26, height: 26)
                            .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.14), radius: 2, y: 1)
                    } else {
                        Image(systemName: "play.tv.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.red)
                    }
                    Text("Yacine TV")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 16)
                .padding(.top, 64)
                .padding(.bottom, 10)

                ScrollView(.vertical, showsIndicators: false) {
                    GlassEffectContainer(spacing: 6) {
                        VStack(alignment: .leading, spacing: 16) {
                            // Discover Section
                            VStack(alignment: .leading, spacing: 4) {
                                sectionTitle("DISCOVER")

                                let liveCount = store.liveEventsCount
                                SidebarDrawerRow(
                                    glassID: "discover.matches",
                                    glassNamespace: categoryGlassNS,
                                    title: "Today's Matches",
                                    systemImage: "sportscourt.fill",
                                    iconTint: .red,
                                    badgeText: liveCount > 0 ? "\(liveCount) LIVE" : (store.events.isEmpty ? nil : "\(store.events.count)"),
                                    badgeColor: liveCount > 0 ? .red : nil,
                                    isSelected: store.selection == .matches,
                                    rowShape: innerRowShape
                                ) {
                                    select(.matches)
                                }

                                SidebarDrawerRow(
                                    glassID: "discover.favorites",
                                    glassNamespace: categoryGlassNS,
                                    title: "Favorites",
                                    systemImage: "star.fill",
                                    iconTint: adaptiveGoldColor,
                                    badgeText: "\(store.favorites.count)",
                                    badgeColor: nil,
                                    isSelected: store.selection == .favorites,
                                    rowShape: innerRowShape
                                ) {
                                    select(.favorites)
                                }
                            }

                            // Categories Section (distinct icons & resolution pills, Liquid Glass selector)
                            VStack(alignment: .leading, spacing: 4) {
                                sectionTitle("LIVE TV CATEGORIES")

                                ForEach(store.categories) { cat in
                                    let presentation = CategoryRowPresentation.resolve(cat)
                                    SidebarDrawerRow(
                                        glassID: "category.\(cat.id)",
                                        glassNamespace: categoryGlassNS,
                                        title: presentation.title,
                                        systemImage: presentation.systemImage,
                                        iconTint: .secondary,
                                        badgeText: presentation.badgeText,
                                        badgeColor: nil,
                                        isSelected: store.selection == .category(cat),
                                        rowShape: innerRowShape
                                    ) {
                                        select(.category(cat))
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                    }
                }
                .scrollEdgeEffectStyle(.soft, for: .all)

                if store.bootstrapFailed {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 8, height: 8)
                        Text("Backend Offline")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)
                    .adaptiveGlassControl(in: Capsule(), tint: .orange, interactive: false)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                }

                // Liquid Glass Appearance Switcher (Auto / Light / Dark, >= 44pt height hit target)
                SidebarThemeSelector(appearanceMode: $store.appearanceMode)
                    .padding(10)
            }
            .frame(width: width)
            .frame(maxHeight: .infinity, alignment: .top)
            .glassEffect(
                (reduceTransparency || contrast == .increased) ? .identity : .clear,
                in: drawerShape
            )
            .glassEffectID("floatingNavigationDrawer", in: namespace)
            .glassEffectTransition(.matchedGeometry)
            .background {
                if reduceTransparency || contrast == .increased {
                    drawerShape
                        .fill(Color(nsColor: .controlBackgroundColor))
                }
            }
            .overlay {
                if reduceTransparency || contrast == .increased {
                    drawerShape.stroke(
                        contrast == .increased
                            ? Color.primary.opacity(0.65)
                            : Color(nsColor: .separatorColor).opacity(0.95),
                        lineWidth: contrast == .increased ? 1.5 : 1
                    )
                } else {
                    drawerShape.stroke(
                        Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.08),
                        lineWidth: 0.75
                    )
                }
            }
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.36 : 0.14),
                radius: 22,
                x: 0,
                y: 10
            )
        }
    }

    private func select(_ item: SidebarSelection) {
        if !store.searchText.isEmpty {
            store.searchText = ""
        }
        withAnimation(.spring(response: 0.24, dampingFraction: 0.90)) {
            store.selection = item
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .tracking(0.6)
            .foregroundStyle(contrast == .increased ? .primary : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
    }
}

private struct SidebarThemeSelector: View {
    @Binding var appearanceMode: AppAppearanceMode

    @Namespace private var themeGlassNS
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(AppAppearanceMode.allCases) { mode in
                    SidebarThemeOptionButton(
                        mode: mode,
                        isSelected: appearanceMode == mode,
                        namespace: themeGlassNS
                    ) {
                        withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                            appearanceMode = mode
                        }
                    }
                }
            }
            .padding(4)
            .frame(minHeight: 44)
            .glassEffect((reduceTransparency || contrast == .increased) ? .identity : .clear, in: Capsule())
            .background {
                if reduceTransparency || contrast == .increased {
                    Capsule().fill(Color(nsColor: .controlBackgroundColor))
                }
            }
            .overlay {
                if reduceTransparency || contrast == .increased {
                    Capsule().stroke(
                        Color.primary.opacity(contrast == .increased ? 0.55 : 0.18),
                        lineWidth: contrast == .increased ? 1.25 : 0.75
                    )
                }
            }
        }
    }
}

private struct SidebarThemeOptionButton: View {
    let mode: AppAppearanceMode
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @StateObject private var hoverState = LocalHoverState()
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    private var activeTintColor: Color {
        switch mode {
        case .system: return Color.red.opacity(colorScheme == .dark ? 0.48 : 0.30)
        case .light: return Color.orange.opacity(colorScheme == .dark ? 0.45 : 0.28)
        case .dark: return Color.indigo.opacity(colorScheme == .dark ? 0.55 : 0.32)
        }
    }

    private var iconTintColor: Color {
        if isSelected && (reduceTransparency || contrast == .increased) {
            return .white
        }
        guard isSelected else { return .secondary }
        switch mode {
        case .system: return .red
        case .light: return colorScheme == .light ? Color(red: 0.82, green: 0.42, blue: 0.0) : .orange
        case .dark: return colorScheme == .light ? Color(red: 0.28, green: 0.25, blue: 0.78) : .indigo
        }
    }

    private var pillGlass: Glass {
        guard !reduceTransparency && contrast != .increased else { return .identity }
        if isSelected {
            return .regular.tint(activeTintColor).interactive()
        }
        if hoverState.isHovered {
            return .clear.interactive()
        }
        return .identity
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(iconTintColor)
                Text(mode.rawValue)
                    .font(.caption.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(
                        isSelected && (reduceTransparency || contrast == .increased)
                            ? Color.white
                            : (isSelected ? Color.primary : Color.secondary)
                    )
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 36)
            .contentShape(Capsule())
            .glassEffect(pillGlass, in: Capsule())
            .background {
                if isSelected && (reduceTransparency || contrast == .increased) {
                    Capsule().fill(Color.red.opacity(contrast == .increased ? 0.95 : 0.88))
                }
            }
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.16), value: isSelected)
        .onHover { hovering in
            hoverState.isHovered = hovering
        }
        .accessibilityLabel("\(mode.rawValue) appearance")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SidebarDrawerRow: View {
    let glassID: String
    let glassNamespace: Namespace.ID
    let title: String
    let systemImage: String
    let iconTint: Color
    let badgeText: String?
    let badgeColor: Color?
    let isSelected: Bool
    let rowShape: ConcentricRectangle
    let action: () -> Void

    @StateObject private var hoverState = LocalHoverState()
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    private var symbolWeight: Font.Weight {
        (isSelected || contrast == .increased) ? .semibold : .medium
    }

    private var effectiveForeground: Color {
        if isSelected && (reduceTransparency || contrast == .increased) {
            return .white
        }
        return .primary
    }

    private var rowGlass: Glass {
        guard !reduceTransparency && contrast != .increased else { return .identity }
        if isSelected {
            return .regular
                .tint(Color.red.opacity(colorScheme == .dark ? 0.50 : 0.34))
                .interactive()
        }
        if hoverState.isHovered {
            return .clear.interactive()
        }
        return .identity
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: symbolWeight))
                    .foregroundStyle(
                        isSelected
                            ? (reduceTransparency || contrast == .increased ? Color.white : (iconTint == .secondary ? Color.red : iconTint))
                            : iconTint
                    )
                    .frame(width: 24, height: 24)

                Text(title)
                    .font(.system(size: 13.5, weight: symbolWeight))
                    .foregroundStyle(effectiveForeground)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let badgeText {
                    Text(badgeText)
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .foregroundStyle(
                            badgeColor != nil || (isSelected && (reduceTransparency || contrast == .increased))
                                ? Color.white
                                : (isSelected ? Color.primary : Color.secondary)
                        )
                        .background(
                            badgeColor ?? Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.09),
                            in: Capsule()
                        )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(rowShape)
            .glassEffect(rowGlass, in: rowShape)
            .background {
                if isSelected && (reduceTransparency || contrast == .increased) {
                    rowShape.fill(Color.red.opacity(contrast == .increased ? 0.95 : 0.88))
                }
            }
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.16), value: isSelected)
        .onHover { hovering in
            hoverState.isHovered = hovering
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(badgeText != nil ? "\(title), \(badgeText ?? "")" : title)
    }
}

// MARK: - Detail Workspace (Edge-to-Edge Adaptive Canvas + Content Layer)
struct DetailWorkspaceView: View {
    @ObservedObject var store: YacineStore
    let leadingSafeInset: CGFloat
    let headerHeight: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            // Edge-to-edge ambient canvas extending seamlessly beneath the floating sidebar
            extendedBackdropCanvas
                .ignoresSafeArea()
                .backgroundExtensionEffect()

            VStack(spacing: 0) {
                WorkspaceFloatingHeaderView(
                    store: store,
                    title: currentHeaderTitle,
                    subtitle: currentHeaderSubtitle,
                    leadingSafeInset: leadingSafeInset,
                    headerHeight: headerHeight
                )

                PlayerDockView(store: store, leadingSafeInset: leadingSafeInset)
                Divider().opacity(contrast == .increased ? 0.45 : 0.14)
                ContentBrowserView(store: store, leadingSafeInset: leadingSafeInset)
            }
        }
    }

    private var extendedBackdropCanvas: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)

            // Subtle dynamic glow inspired by active stream/selection refracting beneath Liquid Glass
            RadialGradient(
                colors: [
                    Color.red.opacity(colorScheme == .dark ? 0.18 : 0.10),
                    Color.blue.opacity(colorScheme == .dark ? 0.10 : 0.05),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 30,
                endRadius: 680
            )

            AmbientBackdropLogoView(urlString: store.nowPlayingLogoURL, colorScheme: colorScheme)
        }
    }

    private var currentHeaderTitle: String {
        if !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Search: \"\(store.searchText)\""
        }
        switch store.selection {
        case .matches:
            return "Today's Live Matches"
        case .favorites:
            return "Favorite Channels"
        case .category(let cat):
            if let parent = store.parentCategory {
                return "\(parent.name) › \(cat.name)"
            }
            return cat.name
        case .none:
            return "Yacine TV"
        }
    }

    private var currentHeaderSubtitle: String {
        if !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(store.searchResults.count) matching channels"
        }
        switch store.selection {
        case .matches:
            let liveCount = store.liveEventsCount
            if liveCount > 0 {
                return "\(liveCount) live now · \(store.events.count) matches scheduled"
            }
            return "\(store.events.count) matches scheduled"
        case .favorites:
            return "\(store.favorites.count) saved channels"
        case .category:
            if !store.subcategories.isEmpty {
                return "\(store.subcategories.count) packages"
            }
            return "\(store.channels.count) live channels"
        case .none:
            return "Native macOS Liquid Glass Edition"
        }
    }
}

// MARK: - Seamless Floating Header (Replaces Heavy Top Toolbar)
private struct WorkspaceFloatingHeaderView: View {
    @ObservedObject var store: YacineStore
    let title: String
    let subtitle: String
    let leadingSafeInset: CGFloat
    let headerHeight: CGFloat

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 12) {
            if let parent = store.parentCategory,
               case .category = store.selection {
                Button {
                    Task { await store.loadCategory(parent) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .bold))
                        Text(parent.name)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .adaptiveGlassControl(in: Capsule())
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("· \(subtitle)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextField("Search 130+ live channels...", text: $store.searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                        if !store.searchText.isEmpty {
                            Button {
                                store.searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear search")
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(width: 228, height: 36)
                    .adaptiveGlassControl(in: Capsule())

                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                            store.isTheaterMode.toggle()
                        }
                    } label: {
                        Image(systemName: store.isTheaterMode ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: 36, height: 36)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .adaptiveGlassControl(
                        in: Circle(),
                        tint: store.isTheaterMode ? .red.opacity(0.45) : nil
                    )
                    .help(store.isTheaterMode ? "Exit Theater Mode" : "Theater Mode")
                    .accessibilityLabel(store.isTheaterMode ? "Exit Theater Mode" : "Theater Mode")

                    Button {
                        Task { await store.refreshAll() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: 36, height: 36)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .adaptiveGlassControl(in: Circle())
                    .help("Refresh Channels & Live Matches")
                    .accessibilityLabel("Refresh")
                }
            }
        }
        .frame(height: headerHeight)
        .padding(.leading, store.isSidebarVisible ? (leadingSafeInset + 16) : 142)
        .padding(.trailing, 18)
    }
}

// MARK: - Hero 16:9 Player Dock with Adaptive Controls
struct PlayerDockView: View {
    @ObservedObject var store: YacineStore
    let leadingSafeInset: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            // 16:9 Hardware-Accelerated AVKit Stage (WKWebView mounted lazily only for web-embed streams)
            ZStack {
                if store.stageMode != .nativeAV {
                    LiveWebPlayerView(
                        requestID: store.stageMode.webRequestID,
                        url: store.stageMode.webURL,
                        userAgent: {
                            switch store.stageMode {
                            case .hiddenSniffWeb(_, _, let ua, _, _),
                                 .visibleWeb(_, _, let ua, _, _, _):
                                return ua
                            case .nativeAV:
                                return ""
                            }
                        }(),
                        referer: {
                            switch store.stageMode {
                            case .hiddenSniffWeb(_, _, _, let ref, _),
                                 .visibleWeb(_, _, _, let ref, _, _):
                                return ref
                            case .nativeAV:
                                return ""
                            }
                        }(),
                        keyword: {
                            switch store.stageMode {
                            case .hiddenSniffWeb(_, _, _, _, let kw),
                                 .visibleWeb(_, _, _, _, let kw, _):
                                return kw
                            case .nativeAV:
                                return "m3u8"
                            }
                        }(),
                        onSniffedMedia: { reqID, mediaURL, docRef, ua, cookies in
                            store.handleSniffedWebMedia(requestID: reqID, mediaURL: mediaURL, referer: docRef, userAgent: ua, cookies: cookies)
                        },
                        onError: { reqID, msg in
                            store.handleWebEmbedError(requestID: reqID, message: msg)
                        }
                    )
                    .opacity(store.stageMode.isWebVisible ? 1 : 0)
                    .allowsHitTesting(store.stageMode.isWebVisible)
                }

                if !store.stageMode.isWebVisible {
                    NativeAVPlayerView(
                        store: store,
                        player: store.player,
                        aspectMode: store.aspectMode,
                        isFullScreenVideo: store.isFullScreenVideo,
                        qualityMenuVersion: store.qualityMenuVersion,
                        enhanceActive: store.isMetalFXCurrentlyActive
                    )
                }

                if store.isLoadingStream {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.regular)
                        Text("Decrypting stream & buffering HLS...")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.black.opacity(reduceTransparency ? 0.92 : 0.65))
                    )
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxHeight: store.isTheaterMode ? 500 : 320)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.12),
                        lineWidth: contrast == .increased ? 1.5 : 1
                    )
            )
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.18), radius: 18, y: 8)

            // Right-Side Control Console
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("LIVE")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.red, in: Capsule())

                    Text(store.nowPlayingTitle)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Text(store.nowPlayingSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                // Server Pills wrapped in GlassEffectContainer
                VStack(alignment: .leading, spacing: 5) {
                    Text("STREAM SERVERS")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(contrast == .increased ? .primary : .secondary)

                    if store.streams.isEmpty {
                        Text("Select a channel below to load servers")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        GlassEffectContainer(spacing: 8) {
                            WrappingFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                                ForEach(Array(store.streams.enumerated()), id: \.offset) { idx, srv in
                                    let isSelected = idx == store.selectedStreamIndex
                                    let baseName = srv.name ?? "Server \(idx + 1)"
                                    let pillLabel: String = {
                                        if let p = srv.probe_label, !p.isEmpty, p != "Web" {
                                            return "\(baseName) · \(p)"
                                        }
                                        return baseName
                                    }()
                                    Button {
                                        store.startStream(at: idx)
                                    } label: {
                                        Text(pillLabel)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(
                                                isSelected && reduceTransparency
                                                    ? Color.white
                                                    : (srv.probe_ok == false ? Color.secondary : Color.primary)
                                            )
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .fixedSize(horizontal: true, vertical: true)
                                    }
                                    .buttonStyle(.plain)
                                    .adaptiveGlassControl(
                                        in: Capsule(),
                                        tint: isSelected ? .red : nil
                                    )
                                }
                            }
                            .padding(.vertical, 2)
                            .padding(.horizontal, 2)
                        }
                    }
                }

                // Stream Quality Pills wrapped cleanly so every quality button is uncropped
                if !store.variants.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("STREAM QUALITY")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(contrast == .increased ? .primary : .secondary)

                        GlassEffectContainer(spacing: 8) {
                            WrappingFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                                let isAuto = store.selectedVariantIndex == nil
                                Button {
                                    store.selectVariant(nil)
                                } label: {
                                    Text("Auto (Max)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(isAuto && reduceTransparency ? Color.white : Color.primary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .fixedSize(horizontal: true, vertical: true)
                                }
                                .buttonStyle(.plain)
                                .adaptiveGlassControl(
                                    in: Capsule(),
                                    tint: isAuto ? .red : nil
                                )

                                ForEach(store.variants) { variant in
                                    let isSel = store.selectedVariantIndex == variant.index
                                    Button {
                                        store.selectVariant(variant)
                                    } label: {
                                        Text(variant.shortQualityName)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(isSel && reduceTransparency ? Color.white : Color.primary)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .fixedSize(horizontal: true, vertical: true)
                                    }
                                    .buttonStyle(.plain)
                                    .adaptiveGlassControl(
                                        in: Capsule(),
                                        tint: isSel ? .red : nil
                                    )
                                }
                            }
                            .padding(.vertical, 2)
                            .padding(.horizontal, 2)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("ASPECT RATIO")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(contrast == .increased ? .primary : .secondary)

                    GlassEffectContainer(spacing: 8) {
                        WrappingFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                            ForEach(AspectMode.allCases) { mode in
                                let isSelected = store.aspectMode == mode
                                Button {
                                    store.aspectMode = mode
                                } label: {
                                    Text(mode.rawValue)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(isSelected && reduceTransparency ? Color.white : Color.primary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .fixedSize(horizontal: true, vertical: true)
                                }
                                .buttonStyle(.plain)
                                .adaptiveGlassControl(
                                    in: Capsule(),
                                    tint: isSelected ? .red : nil
                                )
                            }
                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, 2)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("M1 GPU UPSCALE (METALFX + RCAS)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(contrast == .increased ? .primary : .secondary)

                    GlassEffectContainer(spacing: 8) {
                        WrappingFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                            ForEach(VideoEnhanceMode.allCases) { mode in
                                let isSelected = store.videoEnhanceMode == mode
                                Button {
                                    store.videoEnhanceMode = mode
                                } label: {
                                    Text(mode.rawValue)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(isSelected && reduceTransparency ? Color.white : Color.primary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .fixedSize(horizontal: true, vertical: true)
                                }
                                .buttonStyle(.plain)
                                .adaptiveGlassControl(
                                    in: Capsule(),
                                    tint: isSelected ? .red : nil
                                )
                            }
                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, 2)
                    }
                }

                HStack(spacing: 16) {
                    Label(store.videoResolutionText, systemImage: "display")
                    if !store.activeBitrateText.isEmpty {
                        Label(store.activeBitrateText, systemImage: "waveform.path.ecg")
                    }
                    Label(
                        store.isMetalFXCurrentlyActive ? "MetalFX + RCAS" : "libpk-lib + AVKit",
                        systemImage: store.isMetalFXCurrentlyActive ? "sparkles.tv" : "cpu"
                    )
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, leadingSafeInset + 20)
        .padding(.trailing, 20)
        .padding(.vertical, 14)
    }
}

// MARK: - Content Browser Grid (Pure Content Layer - No Liquid Glass)
struct ContentBrowserView: View {
    @ObservedObject var store: YacineStore
    let leadingSafeInset: CGFloat

    private let channelColumns = [GridItem(.adaptive(minimum: 175, maximum: 230), spacing: 14)]
    private let eventColumns = [GridItem(.adaptive(minimum: 320, maximum: 420), spacing: 14)]

    var body: some View {
        ScrollView {
            Group {
                if store.isLoadingGrid {
                    ProgressView("Loading...")
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else if let err = store.gridError {
                    Text("Error: \(err)")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else if !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    channelsGrid(store.searchResults)
                } else {
                    switch store.selection {
                    case .matches:
                        eventsGrid(store.events)
                    case .favorites:
                        channelsGrid(store.favorites)
                    case .category(let cat):
                        if !store.subcategories.isEmpty {
                            subcategoriesGrid(store.subcategories, parent: cat)
                        } else {
                            channelsGrid(store.channels)
                        }
                    case .none:
                        EmptyView()
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .safeAreaPadding(.leading, leadingSafeInset)
        .scrollEdgeEffectStyle(.soft, for: .all)
    }

    @ViewBuilder
    private func channelsGrid(_ list: [YacineChannel]) -> some View {
        if list.isEmpty {
            Text("No channels found.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 200)
        } else {
            LazyVGrid(columns: channelColumns, spacing: 14) {
                ForEach(list) { ch in
                    ChannelCardView(
                        channel: ch,
                        isPlaying: store.activePlayingKey == "channel:\(ch.id)",
                        isFavorite: store.isFavorite(ch),
                        onPlay: {
                            Task { await store.playItem(kind: "channel", id: ch.id, title: ch.name, logoURL: ch.logo) }
                        },
                        onToggleFav: {
                            store.toggleFavorite(ch)
                        }
                    )
                }
            }
        }
    }

    private func subcategoriesGrid(_ list: [YacineCategory], parent: YacineCategory) -> some View {
        LazyVGrid(columns: channelColumns, spacing: 14) {
            ForEach(list) { sc in
                Button {
                    Task { await store.loadCategory(sc, parent: parent) }
                } label: {
                    VStack(spacing: 10) {
                        LogoImageView(urlString: sc.logo, fallbackText: sc.name)
                            .frame(height: 68)
                        Text(sc.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .contentCardSurface(isPlaying: false, cornerRadius: 12)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func eventsGrid(_ list: [YacineEvent]) -> some View {
        // Share one 30-second periodic timer across all visible match cards
        TimelineView(.periodic(from: .now, by: 30)) { context in
            LazyVGrid(columns: eventColumns, spacing: 14) {
                ForEach(list) { ev in
                    EventCardView(
                        event: ev,
                        referenceDate: context.date,
                        isPlaying: store.activePlayingKey == "event:\(ev.id)"
                    ) {
                        let t1 = ev.team_1?.name ?? "Team 1"
                        let t2 = ev.team_2?.name ?? "Team 2"
                        Task { await store.playItem(kind: "event", id: ev.id, title: "\(t1) vs \(t2)", logoURL: ev.team_1?.logo) }
                    }
                }
            }
        }
    }
}

struct ChannelCardView: View {
    let channel: YacineChannel
    let isPlaying: Bool
    let isFavorite: Bool
    let onPlay: () -> Void
    let onToggleFav: () -> Void

    @StateObject private var hoverState = LocalHoverState()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var starColor: Color {
        if !isFavorite { return .secondary }
        return colorScheme == .light ? Color(red: 0.78, green: 0.44, blue: 0.0) : .yellow
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onPlay) {
                VStack(spacing: 10) {
                    LogoImageView(urlString: channel.logo, fallbackText: channel.name)
                        .frame(height: 68)

                    Text(channel.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .contentCardSurface(isPlaying: isPlaying, isHovered: hoverState.isHovered, cornerRadius: 12)
            }
            .buttonStyle(.plain)

            // Semantic Opaque Favorite Badge (No Liquid Glass on content layer; 44x44pt accessible hit target)
            Button(action: onToggleFav) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.caption.bold())
                    .foregroundStyle(starColor)
                    .frame(width: 28, height: 28)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.90), in: Circle())
                    .overlay(
                        Circle()
                            .strokeBorder(
                                Color.primary.opacity(contrast == .increased ? 0.5 : 0.14),
                                lineWidth: 1
                            )
                    )
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFavorite ? "Remove \(channel.name) from Favorites" : "Add \(channel.name) to Favorites")
        }
        .onHover { hovering in
            hoverState.isHovered = hovering
        }
    }
}

struct EventCardView: View {
    let event: YacineEvent
    let referenceDate: Date
    let isPlaying: Bool
    let onPlay: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var adaptiveChampColor: Color {
        colorScheme == .light ? Color(red: 0.76, green: 0.36, blue: 0.0) : Color.orange
    }

    private func topBadgeText(for state: MatchLifecycleState) -> String {
        switch state {
        case .live:
            return "● LIVE"
        case .upcoming(let mins):
            if mins < 60 { return "IN \(mins)M" }
            let h = mins / 60
            let rem = mins % 60
            if h < 24 { return rem > 0 ? "IN \(h)H \(rem)M" : "IN \(h)H" }
            return "UPCOMING"
        case .ended:
            return "ENDED"
        }
    }

    var body: some View {
        let state = event.lifecycleState(at: referenceDate)
        let kickoff = event.formattedKickoffTime()
        let isLive = (state == .live)
        let isEnded = (state == .ended)

        Button(action: onPlay) {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Text(event.champions ?? "Live Match")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(adaptiveChampColor)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(topBadgeText(for: state))
                        .font(.caption2.weight(.heavy).monospacedDigit())
                        .foregroundStyle(
                            isLive ? Color.white : (isEnded ? Color.secondary : Color.primary)
                        )
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background {
                            if isLive {
                                Capsule().fill(Color.red)
                            } else if isEnded {
                                Capsule().fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06))
                            } else {
                                Capsule().fill(Color.blue.opacity(colorScheme == .dark ? 0.25 : 0.14))
                            }
                        }
                        .overlay {
                            if contrast == .increased && !isLive {
                                Capsule().stroke(Color.primary.opacity(0.45), lineWidth: 1)
                            }
                        }
                }

                HStack(spacing: 12) {
                    VStack(spacing: 6) {
                        LogoImageView(urlString: event.team_1?.logo, fallbackText: event.team_1?.name ?? "T1")
                            .frame(width: 44, height: 44)
                            .opacity(isEnded && !isPlaying ? 0.72 : 1.0)
                        Text(event.team_1?.name ?? "Team 1")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isEnded ? .secondary : .primary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 3) {
                        switch state {
                        case .live:
                            Text("LIVE NOW")
                                .font(.caption.weight(.heavy))
                                .foregroundStyle(.red)
                            Text("جارية الآن")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.red.opacity(0.9))
                        case .upcoming:
                            Text(kickoff)
                                .font(.subheadline.weight(.bold).monospacedDigit())
                                .foregroundStyle(.primary)
                            Text("VS")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                        case .ended:
                            Text("Ended")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text("إنتهت المباراة")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(kickoff)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(minWidth: 82)

                    VStack(spacing: 6) {
                        LogoImageView(urlString: event.team_2?.logo, fallbackText: event.team_2?.name ?? "T2")
                            .frame(width: 44, height: 44)
                            .opacity(isEnded && !isPlaying ? 0.72 : 1.0)
                        Text(event.team_2?.name ?? "Team 2")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isEnded ? .secondary : .primary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }

                Divider().opacity(0.2)

                HStack {
                    Label(event.channel ?? "Live Feed", systemImage: "tv")
                    Spacer()
                    Label(event.commentary ?? "Commentary", systemImage: "mic")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(14)
            .contentCardSurface(isPlaying: isPlaying, cornerRadius: 12)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(event.team_1?.name ?? "Team 1") vs \(event.team_2?.name ?? "Team 2"), \(topBadgeText(for: state)), \(event.channel ?? "")")
    }
}

private struct CachedRemoteImage<Content: View, Placeholder: View>: View {
    let urlString: String?
    let content: (NSImage) -> Content
    let placeholder: (_ didFail: Bool) -> Placeholder

    @StateObject private var loader = LogoImageLoader()

    var body: some View {
        let immediate = urlString.flatMap { YacineImageCache.shared.cachedImage(for: $0) }
        Group {
            if let img = immediate ?? (loader.loadedURL == urlString ? loader.image : nil) {
                content(img)
            } else if let str = urlString, !str.isEmpty {
                let didFail = loader.failedURL == str || YacineImageCache.shared.hasFailedRecently(str)
                placeholder(didFail)
            } else {
                placeholder(true)
            }
        }
        .task(id: urlString) {
            await loader.load(urlString: urlString)
        }
    }
}

private struct AmbientBackdropLogoView: View {
    let urlString: String?
    let colorScheme: ColorScheme

    var body: some View {
        CachedRemoteImage(urlString: urlString) { img in
            Image(nsImage: img)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: 360)
                .blur(radius: 72)
                .opacity(colorScheme == .dark ? 0.16 : 0.12)
                .clipped()
                .mask(
                    LinearGradient(
                        colors: [.black, .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .drawingGroup()
        } placeholder: { _ in
            EmptyView()
        }
    }
}

struct LogoImageView: View {
    let urlString: String?
    let fallbackText: String

    var body: some View {
        CachedRemoteImage(urlString: urlString) { img in
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
        } placeholder: { didFail in
            fallbackBadge.opacity(didFail ? 1.0 : 0.35)
        }
    }

    private var fallbackBadge: some View {
        let initials = fallbackText
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
            .map(String.init)
            .joined()
            .uppercased()
        return Text(initials.isEmpty ? "TV" : initials)
            .font(.headline.weight(.heavy))
            .foregroundStyle(.secondary)
    }
}

// MARK: - App Lifecycle & Embedded Backend Process
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var backendProcess: Process?
    private var appearanceObservation: NSKeyValueObservation?
    private let backendPort = 19485

    func applicationDidFinishLaunching(_ notification: Notification) {
        let initialMode: AppAppearanceMode
        if let raw = UserDefaults.standard.string(forKey: YacineStore.appearanceStorageKey),
           let mode = AppAppearanceMode(rawValue: raw) {
            NSApp.appearance = mode.nsAppearance
            initialMode = mode
        } else {
            initialMode = .system
        }
        Task { @MainActor in
            AppIconProvider.syncDockIcon(for: initialMode)
        }
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { _, _ in
            Task { @MainActor in
                let raw = UserDefaults.standard.string(forKey: YacineStore.appearanceStorageKey)
                let mode = raw.flatMap(AppAppearanceMode.init(rawValue:)) ?? .system
                AppIconProvider.syncDockIcon(for: mode)
            }
        }
        startBackend()
    }

    private func startBackend() {
        let bundleServer = Bundle.main.resourceURL?.appendingPathComponent("backend/server.py").path
        let devServer = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("backend/server.py").path
        let scriptPath = (bundleServer.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }) ?? devServer

        let cltPython = "/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python"
        let pythonPath = FileManager.default.isExecutableFile(atPath: cltPython) ? cltPython : "/usr/bin/python3"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = ["-O", scriptPath]
        var env = ProcessInfo.processInfo.environment
        env["YACINE_PORT"] = String(backendPort)
        proc.environment = env
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            backendProcess = proc
        } catch {
            NSLog("Failed to launch backend: \(error)")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let proc = backendProcess, proc.isRunning {
            proc.terminate()
        }
    }
}

@main
struct YacineTVMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Yacine TV") {
            ContentView()
                .frame(minWidth: 1080, minHeight: 680)
        }
        .defaultSize(width: 1480, height: 920)
        .windowStyle(.hiddenTitleBar)
    }
}
