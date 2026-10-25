import Foundation
import SwiftUI

struct DetailsTarget: Identifiable {
    let channel: Channel
    let program: Program
    var id: String { channel.id + "|" + String(program.start.timeIntervalSince1970) }
}

enum ActiveSheet: Identifiable {
    case groups, search, playlists, settings, channels, themes
    case details(DetailsTarget)

    var id: String {
        switch self {
        case .groups: return "groups"
        case .search: return "search"
        case .playlists: return "playlists"
        case .settings: return "settings"
        case .channels: return "channels"
        case .themes: return "themes"
        case .details(let d): return "details-" + d.id
        }
    }
}

struct VisibleGroup: Identifiable {
    let id: String
    let name: String
    let count: Int
}

struct LoginPrefill {
    var name = "", server = "", user = "", pass = "", error: String? = nil
    /// "xtream" or "m3u"
    var kind = "xtream"
    var m3u = "", epg = ""
}

struct ProgramHit: Identifiable {
    let channel: Channel
    let program: Program
    var id: String { channel.id + "_" + String(program.start.timeIntervalSince1970) }
}

struct SearchResults {
    var channels: [Channel]
    var programs: [ProgramHit]
}

@MainActor
final class AppModel: ObservableObject {
    let player: PlayerController
    /// Movies and series, for accounts that include them.
    let vod = OnDemandModel()
    private let store = Store.shared

    @Published private(set) var provider: Provider?
    @Published private(set) var isBackdrop = false
    @Published var showLogin = false
    @Published private(set) var loginPrefill: LoginPrefill?

    @Published private(set) var channels: [Channel] = []
    @Published private(set) var groups: [ChannelGroup] = []
    @Published private(set) var list: [Channel] = []
    @Published private(set) var groupId = "all"
    @Published private(set) var listRevision = 0

    // Guide data is not published directly; `epgRevision` tells views when it changed.
    private(set) var epg: [String: [Program]] = [:]
    private(set) var epgState: [String: EPGLoad] = [:]
    @Published private(set) var epgRevision = 0

    @Published private(set) var focusIndex = 0
    @Published private(set) var focusTime = Date()
    private var focusFollowsNow = true

    @Published private(set) var playingId: String?
    @Published private(set) var catchup: Program?
    @Published private(set) var favorites: Set<String> = []
    /// Favorites in the order you arranged them.
    @Published private(set) var favoriteOrder: [String] = []
    @Published private(set) var hiddenChannels: Set<String> = []
    @Published private(set) var hiddenGroups: Set<String> = []
    @Published var sortMode = "provider" {
        didSet {
            store.setString(sortMode, "sort")
            if oldValue != sortMode { refreshList() }
        }
    }
    @Published private(set) var recents: [String] = []

    @Published var isFullScreen = false
    @Published var showOnDemand = false
    @Published var sheet: ActiveSheet?
    /// Rewound with the provider's catch-up: the moment the stream started from.
    @Published private(set) var timeshift: Date?
    private var timeshiftStarted = Date()
    private var pausedAt: Date?
    private var guideFileLoading = false
    @Published private(set) var toast: String?
    @Published private(set) var now = Date()
    @Published private(set) var scrollToken = 0
    @Published private(set) var jumpNowToken = 0
    @Published private(set) var rangeStart = Date()
    @Published private(set) var rangeEnd = Date()

    @Published var clock24 = false { didSet { store.setBool(clock24, "clock24") } }
    @Published var compactRows = false { didSet { store.setBool(compactRows, "compact") } }
    @Published var useXMLTV = false {
        didSet {
            store.setBool(useXMLTV, "xmltv")
            if oldValue != useXMLTV { reloadGuide() }
        }
    }
    @Published var xmltvURL = "" { didSet { store.setString(xmltvURL, "xmltvURL") } }

    private var byId: [String: Channel] = [:]
    private var client: XtreamClient?
    private var epgQueue: [String] = []
    private var epgActive = 0
    private var flushPending = false
    private var timer: Timer?
    private var toastTask: Task<Void, Never>?

    init() {
        player = PlayerController()
        clock24 = store.bool("clock24", default: Fmt.localeUses24h())
        compactRows = store.bool("compact", default: false)
        useXMLTV = store.bool("xmltv", default: false)
        xmltvURL = store.string("xmltvURL") ?? ""
        sortMode = store.string("sort") ?? "provider"
        computeRange()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        boot()
    }

    // MARK: Start-up

    /// Starts empty; signs in to the last playlist if there is one. (The demo is only for screenshots.)
    private func boot() {
        if UserDefaults.standard.bool(forKey: "tuner.debug.demo") {
            loadDemo(backdrop: false)
            return
        }
        loadBlank()
        if let last = store.string("last"), let saved = store.playlists.first(where: { $0.id == last }) {
            Task { await self.connectSaved(saved) }
        } else {
            showLogin = true
        }
    }

    /// No playlist: an empty guide behind the sign-in screen.
    func loadBlank() {
        player.stop()
        provider = nil
        client = nil
        channels = []
        groups = []
        list = []
        byId = [:]
        epg = [:]
        epgState = [:]
        epgQueue = []
        epgRevision += 1
        listRevision += 1
        favoriteOrder = []
        favorites = []
        hiddenChannels = []
        hiddenGroups = []
        recents = []
        groupId = "all"
        focusIndex = 0
        playingId = nil
        catchup = nil
        timeshift = nil
        isBackdrop = false
        showOnDemand = false
        vod.reset()
    }

    private func computeRange() {
        let base = floor(Date().timeIntervalSince1970 / 1800) * 1800
        rangeStart = Date(timeIntervalSince1970: base - 12 * 3600)
        rangeEnd = Date(timeIntervalSince1970: base + 36 * 3600)
    }

    private func tick() {
        let n = Date()
        if n.timeIntervalSince(rangeStart) > 24 * 3600 {
            computeRange()
            if provider?.kind == .demo {
                for c in channels { epg[c.id] = Demo.schedule(for: c, from: rangeStart, to: rangeEnd) }
                epgRevision += 1
            }
        }
        if focusFollowsNow { focusTime = n }
        now = n
        Look.shared.checkSeason()
    }

    // MARK: Providers

    func loadDemo(backdrop: Bool) {
        let demo = Demo.build()
        setProvider(Provider(id: "demo", kind: .demo, name: "Demo playlist", info: AccountInfo(status: "Demo")),
                    channels: demo.channels, groups: demo.groups, client: nil)
        isBackdrop = backdrop
        for c in demo.channels {
            epg[c.id] = Demo.schedule(for: c, from: rangeStart, to: rangeEnd)
            epgState[c.id] = .done
        }
        epgRevision += 1
        vod.configure(client: nil, providerId: "demo", demo: true)
        startUp()
        runDebugHooks()
    }

    /// Launch arguments used to take screenshots of particular screens (e.g. -tuner.debug.sheet themes).
    private func runDebugHooks() {
        let d = UserDefaults.standard
        let sheetName = d.string(forKey: "tuner.debug.sheet")
        let full = d.bool(forKey: "tuner.debug.full")
        let pause = d.bool(forKey: "tuner.debug.pause")
        guard sheetName != nil || full else { return }
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if full { self.isFullScreen = true }
            if pause {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.togglePause()
            }
            switch sheetName {
            case "themes": self.sheet = .themes
            case "channels": self.sheet = .channels
            case "settings": self.sheet = .settings
            case "groups": self.sheet = .groups
            case "ondemand": self.openOnDemand()
            default: break
            }
        }
    }

    private func setProvider(_ p: Provider, channels newChannels: [Channel], groups newGroups: [ChannelGroup], client newClient: XtreamClient?) {
        player.stop()
        provider = p
        client = newClient
        channels = newChannels
        groups = newGroups
        byId = Dictionary(newChannels.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        epg = [:]
        epgState = [:]
        epgQueue = []
        epgRevision += 1
        favoriteOrder = store.strings("fav." + p.id)
        favorites = Set(favoriteOrder)
        hiddenChannels = Set(store.strings("hide." + p.id))
        hiddenGroups = Set(store.strings("hideg." + p.id))
        recents = store.strings("recent." + p.id).filter { byId[$0] != nil }
        var g = store.string("group." + p.id) ?? "all"
        if !["all", "fav", "recent"].contains(g) && (!newGroups.contains(where: { $0.id == g }) || hiddenGroups.contains(g)) { g = "all" }
        groupId = g
        playingId = nil
        catchup = nil
        timeshift = nil
        showOnDemand = false
    }

    /// Xtream with "Use XMLTV file", or an M3U playlist with a guide link: the whole guide comes from one file.
    private var usesGuideFile: Bool {
        guard let p = provider else { return false }
        return (p.kind == .xtream && useXMLTV) || (p.kind == .m3u && !p.epgUrl.isEmpty)
    }

    private func startUp() {
        if usesGuideFile {
            for c in channels { epgState[c.id] = .loading }
        }
        applyGroup(groupId, keepFocus: false)
        var lastChannel: Channel? = nil
        if let p = provider, let id = store.string("lastch." + p.id) { lastChannel = byId[id] }
        if let ch = lastChannel ?? list.first ?? channels.first {
            if let i = list.firstIndex(where: { $0.id == ch.id }) { focusIndex = i }
            focusTime = Date()
            focusFollowsNow = true
            play(ch, quiet: true)
        }
        jumpNowToken += 1
        if usesGuideFile {
            Task { await self.loadXMLTV() }
        }
    }

    func signIn(name: String, server: String, user: String, pass: String, remember: Bool,
                step: @escaping @MainActor (String) -> Void) async throws {
        let result = try await XtreamClient.connect(name: name, serverInput: server, user: user, pass: pass, step: step)
        apply(result, remember: remember)
        showLogin = false
        showToast("Signed in to \(result.provider.name) · \(result.channels.count) channels")
    }

    func signInM3U(name: String, url: String, epg: String, remember: Bool,
                   step: @escaping @MainActor (String) -> Void) async throws {
        let result = try await M3U.connect(name: name, urlInput: url, epgInput: epg, step: step)
        apply(result, remember: remember)
        showLogin = false
        showToast("Signed in to \(result.provider.name) · \(result.channels.count) channels")
    }

    private func apply(_ r: XtreamClient.LoginResult, remember: Bool) {
        let p = r.provider
        let c: XtreamClient? = p.kind == .xtream ? XtreamClient(server: p.server, user: p.user, pass: p.pass) : nil
        setProvider(p, channels: r.channels, groups: r.groups, client: c)
        isBackdrop = false
        if remember {
            var saved = store.playlists.filter { $0.id != p.id }
            if p.kind == .m3u {
                // The link usually contains your username and password, so it goes in the Keychain, not the list.
                saved.insert(Playlist(id: p.id, name: p.name, server: "", user: "", kind: "m3u", host: URL(string: p.url)?.host), at: 0)
                store.setPlaylistLink(p.url, epg: p.epgUrl, for: p.id)
            } else {
                saved.insert(Playlist(id: p.id, name: p.name, server: p.server, user: p.user, kind: "xtream"), at: 0)
                store.setPassword(p.pass, for: p.id)
            }
            store.playlists = saved
            store.setString(p.id, "last")
        }
        vod.configure(client: c, providerId: p.id, demo: false)
        startUp()
    }

    func connectSaved(_ pl: Playlist) async {
        showToast("Connecting to \(pl.name)…", seconds: 0)
        if pl.kind == "m3u" {
            let link = store.playlistLink(for: pl.id)
            do {
                let r = try await M3U.connect(name: pl.name, urlInput: link.url, epgInput: link.epg, step: { _ in })
                apply(r, remember: true)
                showLogin = false
                showToast("Signed in to \(pl.name)")
            } catch {
                toast = nil
                loginPrefill = LoginPrefill(name: pl.name, error: error.localizedDescription, kind: "m3u", m3u: link.url, epg: link.epg)
                showLogin = true
            }
            return
        }
        let pass = store.password(for: pl.id)
        do {
            let r = try await XtreamClient.connect(name: pl.name, serverInput: pl.server, user: pl.user, pass: pass, step: { _ in })
            apply(r, remember: true)
            showLogin = false
            showToast("Signed in to \(pl.name)")
        } catch {
            toast = nil
            loginPrefill = LoginPrefill(name: pl.name, server: pl.server, user: pl.user, pass: pass, error: error.localizedDescription)
            showLogin = true
        }
    }

    var savedPlaylists: [Playlist] { store.playlists }

    var canCancelLogin: Bool { provider != nil && !isBackdrop }

    func addPlaylist() {
        sheet = nil
        loginPrefill = nil
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            self.showLogin = true
        }
    }

    func switchTo(_ pl: Playlist) {
        sheet = nil
        if provider?.id == pl.id && !isBackdrop { return }
        Task { await self.connectSaved(pl) }
    }

    func removeCurrentPlaylist() {
        guard let p = provider, p.kind != .demo else { return }
        store.removePlaylist(p.id)
        if store.string("last") == p.id { store.remove("last") }
        sheet = nil
        loadBlank()
        loginPrefill = nil
        showLogin = true
        showToast("Removed \(p.name)")
    }

    /// M3U playlists: change the TV guide (XMLTV) link from Settings.
    func setM3UGuide(_ link: String) {
        guard var p = provider, p.kind == .m3u else { return }
        p.epgUrl = link.trimmed
        provider = p
        if store.playlists.contains(where: { $0.id == p.id }) {
            store.setPlaylistLink(p.url, epg: p.epgUrl, for: p.id)
        }
        reloadGuide()
    }

    // MARK: On Demand

    func openOnDemand() {
        guard vod.available else { return }
        let wait = sheet != nil || isFullScreen
        sheet = nil
        isFullScreen = false
        player.stop()            // the live channel resumes when you come back
        if wait {
            Task {
                try? await Task.sleep(nanoseconds: 450_000_000)
                self.showOnDemand = true
            }
        } else {
            showOnDemand = true
        }
    }

    func closeOnDemand() { showOnDemand = false }

    /// Back from Movies & Series: pick the live channel up again.
    func onDemandClosed() {
        guard let ch = playingChannel, player.state == .idle else { return }
        play(ch, quiet: true)
    }

    // MARK: Groups

    /// Favorites keep your order; hidden channels and groups stay out of the guide; the rest follow the sort setting.
    func channelsFor(_ id: String) -> [Channel] {
        switch id {
        case "all": return sorted(channels.filter { isVisible($0) })
        case "fav": return favoriteOrder.compactMap { byId[$0] }.filter { !hiddenChannels.contains($0.id) }
        case "recent": return recents.compactMap { byId[$0] }.filter { isVisible($0) }
        default: return sorted(channels.filter { $0.groupId == id && !hiddenChannels.contains($0.id) })
        }
    }

    func isVisible(_ c: Channel) -> Bool { !hiddenChannels.contains(c.id) && !hiddenGroups.contains(c.groupId) }

    func sorted(_ list: [Channel]) -> [Channel] {
        switch sortMode {
        case "number": return list.sorted { ($0.num == 0 ? Int.max : $0.num) < ($1.num == 0 ? Int.max : $1.num) }
        case "name": return list.sorted { Channel.sortName($0.name).localizedStandardCompare(Channel.sortName($1.name)) == .orderedAscending }
        default: return list
        }
    }

    var visibleGroups: [VisibleGroup] {
        var counts: [String: Int] = [:]
        for c in channels where !hiddenChannels.contains(c.id) { counts[c.groupId, default: 0] += 1 }
        return groups.filter { !hiddenGroups.contains($0.id) }.map { VisibleGroup(id: $0.id, name: $0.name, count: counts[$0.id] ?? 0) }
    }

    var visibleChannelCount: Int { channels.filter { isVisible($0) }.count }

    func channels(inGroup id: String) -> [Channel] { sorted(channels.filter { $0.groupId == id }) }

    var favoriteChannels: [Channel] { favoriteOrder.compactMap { byId[$0] } }

    func channel(_ id: String) -> Channel? { byId[id] }

    /// Re-applies filters and sorting after favorites, hiding or sort order change.
    func refreshList() {
        guard provider != nil else { return }
        let special = ["all", "fav", "recent"].contains(groupId)
        applyGroup(!special && hiddenGroups.contains(groupId) ? "all" : groupId)
    }

    private func saveFavorites() {
        guard let p = provider else { return }
        favorites = Set(favoriteOrder)
        store.setStrings(favoriteOrder, "fav." + p.id)
    }

    private func saveHidden() {
        guard let p = provider else { return }
        store.setStrings(Array(hiddenChannels), "hide." + p.id)
        store.setStrings(Array(hiddenGroups), "hideg." + p.id)
    }

    func moveFavorites(from source: IndexSet, to destination: Int) {
        var order = favoriteChannels.map { $0.id }
        order.move(fromOffsets: source, toOffset: destination)
        favoriteOrder = order
        saveFavorites()
        refreshList()
    }

    func removeFavorites(at offsets: IndexSet) {
        var order = favoriteChannels.map { $0.id }
        order.remove(atOffsets: offsets)
        favoriteOrder = order
        saveFavorites()
        refreshList()
    }

    func setHidden(_ ch: Channel, _ hidden: Bool, announce: Bool = false) {
        if hidden { hiddenChannels.insert(ch.id) } else { hiddenChannels.remove(ch.id) }
        saveHidden()
        refreshList()
        if announce && hidden { showToast("\(ch.name) is hidden. Bring it back in Edit channels.", seconds: 4) }
    }

    func setGroupHidden(_ id: String, _ hidden: Bool) {
        if hidden { hiddenGroups.insert(id) } else { hiddenGroups.remove(id) }
        saveHidden()
        refreshList()
    }

    func groupLabel(_ id: String) -> String {
        switch id {
        case "all": return "All channels"
        case "fav": return "Favorites"
        case "recent": return "Recently watched"
        default: return groups.first(where: { $0.id == id })?.name ?? "Channels"
        }
    }

    func applyGroup(_ id: String, keepFocus: Bool = true) {
        var previousId: String? = nil
        if keepFocus && list.indices.contains(focusIndex) { previousId = list[focusIndex].id }
        groupId = id
        list = channelsFor(id)
        listRevision += 1
        if let p = provider { store.setString(id, "group." + p.id) }
        var index: Int? = nil
        if let previousId { index = list.firstIndex(where: { $0.id == previousId }) }
        if index == nil, let playing = playingId { index = list.firstIndex(where: { $0.id == playing }) }
        focusIndex = max(0, index ?? 0)
    }

    func selectGroup(_ id: String) {
        sheet = nil
        applyGroup(id)
        jumpToNow()
    }

    func showGuide() {
        if groupId == "fav" { applyGroup("all") }
        jumpToNow()
    }

    func toggleFavoritesGroup() {
        applyGroup(groupId == "fav" ? "all" : "fav")
        jumpToNow()
    }

    var emptyText: String {
        switch groupId {
        case _ where provider == nil: return "No playlist yet.\nAdd one to start watching."
        case "fav": return "No favorites yet.\nTouch and hold a channel, or use Edit channels to pick some."
        case "recent": return "Nothing watched yet.\nChannels you watch show up here."
        default: return "No channels in this group."
        }
    }

    // MARK: Focus and guide

    var focusedChannel: Channel? { list.indices.contains(focusIndex) ? list[focusIndex] : nil }

    var focusedProgram: Program? {
        guard let ch = focusedChannel else { return nil }
        return epg[ch.id]?.program(near: focusTime)
    }

    var playingChannel: Channel? { playingId.flatMap { byId[$0] } }

    func program(for ch: Channel, at t: Date) -> Program? { epg[ch.id]?.program(containing: t) }

    func next(after p: Program, on ch: Channel) -> Program? { epg[ch.id]?.neighbor(of: p, 1) }

    func progress(_ p: Program) -> Double {
        let total = p.end.timeIntervalSince(p.start)
        guard total > 0 else { return 0 }
        return min(1, max(0, now.timeIntervalSince(p.start) / total))
    }

    func isLoadingGuide(_ ch: Channel) -> Bool {
        switch provider?.kind {
        case .some(.xtream):
            let st = epgState[ch.id]
            return st != .done && st != .failed
        case .some(.m3u):
            return epgState[ch.id] == .loading
        default:
            return false
        }
    }

    func canCatchup(_ ch: Channel, _ p: Program) -> Bool {
        let n = Date()
        return ch.archive && p.end <= n && p.start >= n.addingTimeInterval(-Double(max(1, ch.archiveDays)) * 86400)
    }

    private func setFocus(_ index: Int, _ p: Program?) {
        focusIndex = index
        let n = Date()
        if let p, !p.isNow(n) {
            focusFollowsNow = false
            focusTime = p.start
        } else {
            focusFollowsNow = true
            focusTime = n
        }
    }

    func jumpToNow() {
        focusTime = Date()
        focusFollowsNow = true
        jumpNowToken += 1
    }

    /// First tap selects (and previews a live program); a second tap watches full screen or opens details.
    func tapProgram(_ index: Int, _ p: Program?) {
        guard list.indices.contains(index) else { return }
        let ch = list[index]
        let wasFocused = index == focusIndex && focusedProgram?.start == p?.start
        setFocus(index, p)
        let isLive = p == nil || p!.isNow(Date())
        if isLive {
            if wasFocused {
                if playingId == ch.id && catchup == nil { isFullScreen = true } else { play(ch, fullScreen: true) }
            } else if playingId != ch.id || catchup != nil {
                play(ch)
            }
        } else if wasFocused, let p {
            sheet = .details(DetailsTarget(channel: ch, program: p))
        }
    }

    func tapChannel(_ index: Int) {
        guard list.indices.contains(index) else { return }
        let ch = list[index]
        setFocus(index, nil)
        if playingId == ch.id && catchup == nil { isFullScreen = true } else { play(ch) }
    }

    func goTo(_ ch: Channel, program p: Program?) {
        sheet = nil
        var index = list.firstIndex(where: { $0.id == ch.id })
        if index == nil {
            applyGroup("all")
            index = list.firstIndex(where: { $0.id == ch.id })
        }
        guard let i = index else { return }
        setFocus(i, p)
        scrollToken += 1
        if let p, !p.isNow(Date()) {
            Task {
                try? await Task.sleep(nanoseconds: 450_000_000)
                self.sheet = .details(DetailsTarget(channel: ch, program: p))
            }
        } else {
            play(ch)
        }
    }

    func search(_ q: String) -> SearchResults {
        let query = q.trimmed.lowercased()
        if query.isEmpty {
            return SearchResults(channels: recents.prefix(8).compactMap { byId[$0] }, programs: [])
        }
        let matches = channels.filter { $0.name.lowercased().contains(query) || String($0.num) == query }
        var hits: [ProgramHit] = []
        let n = Date()
        outer: for c in channels {
            guard let ps = epg[c.id] else { continue }
            for p in ps where p.end > n && p.start < rangeEnd && p.title.lowercased().contains(query) {
                hits.append(ProgramHit(channel: c, program: p))
                if hits.count >= 200 { break outer }
            }
        }
        hits.sort { $0.program.start < $1.program.start }
        return SearchResults(channels: Array(matches.prefix(25)), programs: Array(hits.prefix(40)))
    }

    // MARK: Playback

    func play(_ ch: Channel, catchup cu: Program? = nil, fullScreen: Bool = false, quiet: Bool = false) {
        guard let p = provider else { return }
        playingId = ch.id
        catchup = cu
        timeshift = nil
        pausedAt = nil
        if !quiet {
            recents = [ch.id] + recents.filter { $0 != ch.id }
            if recents.count > 30 { recents = Array(recents.prefix(30)) }
            store.setStrings(recents, "recent." + p.id)
        }
        store.setString(ch.id, "lastch." + p.id)
        if fullScreen { isFullScreen = true }
        var url: URL? = nil
        switch p.kind {
        case .demo:
            url = ch.demoStream
        case .xtream:
            if let cu { url = client?.catchupURL(ch, cu, timezone: p.info.timezone) }
            if url == nil { url = client?.liveURL(ch) }
        case .m3u:
            url = ch.streamURL
        }
        if let url { player.play(url) } else { player.fail("network") }
    }

    // MARK: Pause and rewind (live TV)

    func canTimeshift(_ ch: Channel) -> Bool { provider?.kind == .xtream && ch.archive }

    /// Pause; when you come back after the stream has moved on, continue from the provider's catch-up if it has one.
    func togglePause() {
        guard let ch = playingChannel else { return }
        if !player.isPaused {
            player.setPaused(true)
            pausedAt = Date()
            return
        }
        let at = pausedAt
        pausedAt = nil
        let away = at.map { Date().timeIntervalSince($0) } ?? 0
        if player.timeInfo.seekable || away < 45 || catchup != nil || provider?.kind == .demo {
            player.setPaused(false)
        } else if canTimeshift(ch), let at {
            playTimeshift(ch, from: at)
            showToast("Continuing from where you paused")
        } else {
            play(ch, quiet: true)
            showToast("Back to live. This channel can't continue from where you paused.", seconds: 4)
        }
    }

    /// Rewind or fast-forward: within the stream when it allows, otherwise 5 minutes at a time with catch-up.
    func seekLive(_ seconds: Double) {
        guard let ch = playingChannel else { return }
        if player.timeInfo.seekable {
            player.skip(by: seconds)
            return
        }
        if let ts = timeshift {
            let at = ts.addingTimeInterval(Date().timeIntervalSince(timeshiftStarted) + (seconds < 0 ? -300 : 300))
            if at >= Date().addingTimeInterval(-60) {
                play(ch, quiet: true)
                showToast("Back to live")
            } else {
                playTimeshift(ch, from: at)
            }
            return
        }
        if seconds < 0 && canTimeshift(ch) {
            playTimeshift(ch, from: Date().addingTimeInterval(-300))
            showToast("Rewound 5 minutes")
            return
        }
        showToast(seconds < 0 ? "This channel can't be rewound" : "You're watching live")
    }

    func goLive() {
        guard let ch = playingChannel else { return }
        if timeshift != nil || catchup != nil {
            play(ch, quiet: true)
        } else {
            player.seekToLiveEdge()
        }
        showToast("Back to live")
    }

    /// Where playback is on the clock and how far it can be scrubbed (the full-screen timeline).
    struct LiveTimeline {
        let catchupProgram: Bool
        let min: Date
        let max: Date
        let pos: Date
        let canScrub: Bool
        let programStart: Date
        let programEnd: Date
    }

    func liveTimeline() -> LiveTimeline? {
        guard let ch = playingChannel else { return nil }
        let now = Date(), info = player.timeInfo
        if let cu = catchup, timeshift == nil {
            let pos = cu.start.addingTimeInterval(Swift.min(cu.end.timeIntervalSince(cu.start), info.position))
            return LiveTimeline(catchupProgram: true, min: cu.start, max: cu.end.addingTimeInterval(-5), pos: pos, canScrub: true,
                                programStart: cu.start, programEnd: cu.end)
        }
        var pos = now
        if let ts = timeshift { pos = Swift.min(now, ts.addingTimeInterval(info.position)) }
        else if info.seekable { pos = now.addingTimeInterval(-info.behind) }
        else if let p = pausedAt { pos = p }
        var lo = now
        if canTimeshift(ch) { lo = now.addingTimeInterval(-Double(Swift.max(1, ch.archiveDays)) * 86400 + 3600) }
        else if info.seekable { lo = timeshift ?? now.addingTimeInterval(-info.window) }
        lo = Swift.min(lo, pos)
        let p = program(for: ch, at: pos)
        return LiveTimeline(catchupProgram: false, min: lo, max: now, pos: pos, canScrub: lo < now.addingTimeInterval(-20),
                            programStart: p?.start ?? pos.addingTimeInterval(-1800), programEnd: p?.end ?? pos.addingTimeInterval(1800))
    }

    /// Jump to a moment: inside the stream when it allows, otherwise with the provider's catch-up; near now means live.
    func seekLive(to target: Date) {
        guard let ch = playingChannel, let tl = liveTimeline() else { return }
        let now = Date(), delta = target.timeIntervalSince(tl.pos)
        guard abs(delta) >= 2 else { return }
        if tl.catchupProgram { player.skip(by: delta); return }
        if target >= now.addingTimeInterval(-15) { goLive(); return }
        let info = player.timeInfo
        if let ts = timeshift, info.seekable, target >= ts { player.skip(by: delta); return }
        if timeshift == nil, info.seekable, target >= now.addingTimeInterval(-info.window) { player.skip(by: delta); return }
        if canTimeshift(ch) { playTimeshift(ch, from: target); return }
        showToast("This channel can't go back that far")
    }

    /// "4:12 behind" while paused or rewound on a live channel.
    func behindLiveText() -> String {
        guard let p = provider, p.kind != .demo else { return "" }
        if let ts = timeshift {
            let behind = Date().timeIntervalSince(ts) - player.timeInfo.position
            return behind > 30 ? Fmt.clock(behind) + " behind" : ""
        }
        guard catchup == nil else { return "" }
        let info = player.timeInfo
        return info.seekable && info.behind > 15 ? Fmt.clock(info.behind) + " behind" : ""
    }

    private func playTimeshift(_ ch: Channel, from: Date) {
        let n = Date()
        let earliest = n.addingTimeInterval(-Double(max(1, ch.archiveDays)) * 86400 + 3600)
        let start = min(n.addingTimeInterval(-60), max(earliest, from))
        let title = program(for: ch, at: start)?.title ?? ch.name
        play(ch, catchup: Program(start: start, end: n.addingTimeInterval(3 * 3600), title: title), quiet: true)
        timeshift = start
        timeshiftStarted = Date()
    }

    func watchFromDetails(_ ch: Channel, catchup cu: Program?) {
        sheet = nil
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            self.play(ch, catchup: cu, fullScreen: true)
        }
    }

    /// Channel list in full screen: switch channel and keep the guide's selection in step.
    func playFromList(_ ch: Channel) {
        if let i = list.firstIndex(where: { $0.id == ch.id }) {
            focusIndex = i
            focusTime = Date()
            focusFollowsNow = true
            scrollToken += 1
        }
        if ch.id != playingId || catchup != nil { play(ch) }
    }

    func detailsFromFullScreen(_ ch: Channel, _ p: Program) {
        isFullScreen = false
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            self.sheet = .details(DetailsTarget(channel: ch, program: p))
        }
    }

    func openFullScreen() {
        if playingId != nil { isFullScreen = true }
    }

    func stepChannel(_ d: Int) {
        let base = list.isEmpty ? channels : list
        guard !base.isEmpty else { return }
        var i = base.firstIndex(where: { $0.id == playingId }) ?? 0
        i = (i + d + base.count) % base.count
        let ch = base[i]
        if !list.isEmpty {
            focusIndex = i
            focusTime = Date()
            focusFollowsNow = true
            scrollToken += 1
        }
        play(ch)
    }

    func toggleFavorite(_ ch: Channel, quiet: Bool = false) {
        guard provider != nil else { return }
        if favorites.contains(ch.id) {
            favoriteOrder.removeAll { $0 == ch.id }
            if !quiet { showToast("Removed \(ch.name) from favorites") }
        } else {
            favoriteOrder.append(ch.id)
            if !quiet { showToast("Added \(ch.name) to favorites") }
        }
        saveFavorites()
        if groupId == "fav" { applyGroup("fav") }
    }

    func toggleFavorite(at index: Int) {
        guard list.indices.contains(index) else { return }
        toggleFavorite(list[index])
    }

    // MARK: Guide loading

    /// Called by the grid with the channels on screen; loads their guide four at a time.
    func requestEPG(_ ids: [String]) {
        guard provider?.kind == .xtream, client != nil else { return }
        var st = epgState
        for (k, v) in epgState where v == .queued && !ids.contains(k) { st[k] = nil }
        for id in ids where st[id] == nil { st[id] = .queued }
        epgState = st
        epgQueue = ids.filter { st[$0] == .queued }
        pump()
    }

    private func pump() {
        guard let client, let pid = provider?.id else { return }
        var started: [String] = []
        while epgActive < 4, !epgQueue.isEmpty {
            let id = epgQueue.removeFirst()
            guard epgState[id] == .queued else { continue }
            epgState[id] = .loading
            epgActive += 1
            started.append(id)
        }
        for id in started {
            Task { [weak self] in
                let result = try? await client.epg(streamId: id)
                self?.epgFinished(id, result, providerId: pid)
            }
        }
    }

    private func epgFinished(_ id: String, _ result: [Program]?, providerId: String) {
        epgActive = max(0, epgActive - 1)
        if provider?.id == providerId {
            epg[id] = result ?? []
            epgState[id] = result == nil ? .failed : .done
            scheduleFlush()
        }
        pump()
    }

    private func scheduleFlush() {
        guard !flushPending else { return }
        flushPending = true
        Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            self.flushPending = false
            self.epgRevision += 1
        }
    }

    func reloadGuide() {
        guard let p = provider, p.kind == .xtream || p.kind == .m3u else { return }
        epg = [:]
        epgState = [:]
        epgQueue = []
        epgRevision += 1
        if usesGuideFile { Task { await self.loadXMLTV() } }
    }

    func loadXMLTV() async {
        guard let p = provider else { return }
        let downloader: XtreamClient
        let source: String?
        switch p.kind {
        case .xtream:
            guard let client else { return }
            downloader = client
            source = xmltvURL.trimmed.nonEmpty
        case .m3u:
            guard !p.epgUrl.isEmpty else { return }
            downloader = XtreamClient(server: "", user: "", pass: "")
            source = p.epgUrl
        case .demo:
            return
        }
        for c in channels { epgState[c.id] = .loading }
        guideFileLoading = true
        epgRevision += 1
        defer { guideFileLoading = false }
        showToast("Loading TV guide…", seconds: 0)
        var wantedIds: [String: [String]] = [:]
        for c in channels where !c.epgId.isEmpty { wantedIds[c.epgId, default: []].append(c.id) }
        let wanted = wantedIds
        let from = rangeStart.addingTimeInterval(-86400)
        let to = rangeEnd
        do {
            let file = try await downloader.downloadXMLTV(from: source)
            let parsed = await Task.detached(priority: .userInitiated) {
                XMLTVParser.parse(file: file, wanted: wanted, from: from, to: to)
            }.value
            guard provider?.id == p.id else { return }
            guard let parsed else { throw TunerError("The guide file couldn't be read.") }
            for c in channels {
                epg[c.id] = parsed.lists[c.id] ?? []
                epgState[c.id] = .done
            }
            epgRevision += 1
            showToast("TV guide loaded · \(parsed.count) programs")
        } catch {
            guard provider?.id == p.id else { return }
            epg = [:]
            epgState = [:]
            if p.kind == .m3u {
                for c in channels { epgState[c.id] = .failed }
                showToast("Couldn't load the TV guide from your guide link. Check it in Settings.", seconds: 4)
            } else {
                showToast("Couldn't load the XMLTV guide. Using the provider's guide instead.", seconds: 4)
            }
            epgRevision += 1
        }
    }

    // MARK: Toasts

    func showToast(_ message: String, seconds: Double = 2.8) {
        toast = message
        toastTask?.cancel()
        guard seconds > 0 else { return }
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    // MARK: Snapshot for the UIKit guide grid

    var guideSnapshot: GuideSnapshot {
        GuideSnapshot(
            channels: list,
            listRevision: listRevision,
            epg: epg,
            epgState: epgState,
            epgRevision: epgRevision,
            isXtream: provider?.kind == .xtream || guideFileLoading,
            focusIndex: focusIndex,
            focusStart: focusedProgram?.start,
            playingId: playingId,
            favorites: favorites,
            now: now,
            clock24: clock24,
            compact: compactRows,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            scrollToken: scrollToken,
            jumpNowToken: jumpNowToken,
            groupTitle: "\(groupLabel(groupId)) · \(list.count)",
            emptyText: emptyText,
            scale: Look.shared.sizeScale
        )
    }
}
