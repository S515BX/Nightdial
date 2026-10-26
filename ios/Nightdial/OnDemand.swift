import AVKit
import SwiftUI
import UIKit

/// Movies and series from the provider (Xtream Codes accounts that include them).
@MainActor
final class OnDemandModel: ObservableObject {
    @Published private(set) var available = false
    @Published var kind: VodKind = .movies
    @Published private(set) var categories: [VodKind: [VodCategory]] = [:]
    @Published private(set) var items: [VodKind: [VodItem]] = [:]
    @Published private(set) var loading: Set<VodKind> = []
    @Published private(set) var errors: [VodKind: String] = [:]
    @Published private var selectedCategory: [VodKind: String] = [:]
    @Published var query = ""
    @Published private(set) var resumes: [String: ResumePoint] = [:]

    private(set) var client: XtreamClient?
    private(set) var emby: EmbyClient?
    private(set) var providerId = ""
    private(set) var isDemo = false
    /// Emby: Continue watching and Next up from the server, genres from the library, and a counter that tells open
    /// screens to refresh after something was played or marked watched.
    @Published private(set) var embyContinue: [VodKind: [(id: String, fraction: Double)]] = [:]
    @Published private(set) var embyNextUp: [String] = []
    @Published private(set) var embyGenres: [VodKind: [VodCategory]] = [:]
    @Published private(set) var embyRevision = 0
    var isEmby: Bool { emby != nil }
    private let store = Store.shared
    private var token = 0

    func reset() {
        token += 1
        available = false
        client = nil
        emby = nil
        embyContinue = [:]
        embyNextUp = []
        embyGenres = [:]
        providerId = ""
        isDemo = false
        kind = .movies
        categories = [:]
        items = [:]
        loading = []
        errors = [:]
        selectedCategory = [:]
        query = ""
        resumes = [:]
    }

    /// Called after signing in: checks whether the account has movies or series.
    func configure(client: XtreamClient?, providerId: String, demo: Bool) {
        reset()
        self.client = client
        self.providerId = providerId
        self.isDemo = demo
        resumes = store.resumes(providerId)
        if demo {
            categories = DemoVod.categories
            available = true
            return
        }
        guard let client else { return }
        let t = token
        Task {
            async let m = client.vodCategories(.movies)
            async let s = client.vodCategories(.series)
            let (mc, sc) = await (m, s)
            guard t == self.token else { return }
            self.categories = [.movies: mc, .series: sc]
            self.available = !mc.isEmpty || !sc.isEmpty
            if mc.isEmpty && !sc.isEmpty { self.kind = .series }
        }
    }

    /// Emby: libraries first, then Continue watching and Next up.
    func configureEmby(_ client: EmbyClient, providerId: String) {
        reset()
        emby = client
        self.providerId = providerId
        let t = token
        Task {
            let libs = await client.libraries()
            guard t == self.token else { return }
            self.categories = libs
            self.available = true
            if (libs[.movies] ?? []).isEmpty && !(libs[.series] ?? []).isEmpty { self.kind = .series }
            self.ensureLoaded(self.kind)
            await self.refreshEmbyHome()
        }
    }

    func refreshEmbyHome() async {
        guard let emby else { return }
        let t = token
        async let m = emby.resumeList(.movies)
        async let s = emby.resumeList(.series)
        async let n = emby.nextUpSeries()
        let (mc, sc, nu) = await (m, s, n)
        guard t == token else { return }
        embyContinue = [.movies: mc, .series: sc]
        embyNextUp = nu
    }

    func title(_ k: VodKind) -> String { k == .movies ? "Movies" : (isEmby ? "TV shows" : "Series") }

    /// Emby: after playing or marking something, keep the library in step (progress bars, watched marks).
    func embyNote(_ id: String, kind k: VodKind, position: Double, runtime: Double, finished: Bool) {
        if var list = items[k], let i = list.firstIndex(where: { $0.id == id }) {
            let done = finished || (runtime > 0 && position / runtime > 0.9)
            list[i].played = done || list[i].played
            list[i].position = done ? 0 : position
            if runtime > 0 { list[i].runtime = runtime }
            items[k] = list
        }
        embyRevision += 1
        Task { await self.refreshEmbyHome() }
    }

    func embySetPlayed(_ id: String, kind k: VodKind, played: Bool) async -> Bool {
        guard let emby else { return false }
        do { try await emby.setPlayed(id, played) } catch { return false }
        if var list = items[k], let i = list.firstIndex(where: { $0.id == id }) {
            list[i].played = played
            list[i].position = 0
            items[k] = list
        }
        embyRevision += 1
        await refreshEmbyHome()
        return true
    }

    var kinds: [VodKind] { VodKind.allCases.filter { !(categories[$0] ?? []).isEmpty } }

    func ensureLoaded(_ k: VodKind) {
        guard items[k] == nil, !loading.contains(k) else { return }
        if isDemo { items[k] = DemoVod.items(k); return }
        if let emby {
            guard available else { return }      // the libraries come first, so each title knows which one it's in
            loading.insert(k)
            errors[k] = nil
            let t = token, libs = categories[k] ?? []
            Task {
                do {
                    let list = try await emby.items(k, in: libs)
                    guard t == self.token else { return }
                    self.items[k] = list
                    let genres = Set(list.flatMap { $0.categories.filter { $0.hasPrefix("g:") } })
                    self.embyGenres[k] = genres.sorted().map { VodCategory(id: $0, name: String($0.dropFirst(2))) }
                } catch {
                    guard t == self.token else { return }
                    self.errors[k] = "Your Emby server didn't send the library. Check that it's on."
                }
                self.loading.remove(k)
            }
            return
        }
        guard let client else { return }
        loading.insert(k)
        errors[k] = nil
        let t = token
        Task {
            do {
                let list = try await client.vodItems(k)
                guard t == self.token else { return }
                self.items[k] = list
            } catch {
                guard t == self.token else { return }
                self.errors[k] = error.localizedDescription
            }
            self.loading.remove(k)
        }
    }

    func retry(_ k: VodKind) {
        errors[k] = nil
        items[k] = nil
        ensureLoaded(k)
    }

    // MARK: Browsing

    func category(_ k: VodKind) -> String {
        let c = selectedCategory[k] ?? "all"
        if c == "continue" && continueItems(k).isEmpty { return "all" }
        if c == "nextup" && nextUpItems().isEmpty { return "all" }
        return c
    }

    func setCategory(_ id: String, for k: VodKind) { selectedCategory[k] = id }

    /// Continue watching (when there's any), everything, recently added, then the provider's categories.
    func chips(_ k: VodKind) -> [VodCategory] {
        var out: [VodCategory] = []
        if isEmby {
            if !continueItems(k).isEmpty { out.append(VodCategory(id: "continue", name: "Continue watching")) }
            if k == .series && !nextUpItems().isEmpty { out.append(VodCategory(id: "nextup", name: "Next up")) }
            out.append(VodCategory(id: "all", name: k == .movies ? "All movies" : "All TV shows"))
            out.append(VodCategory(id: "new", name: "Recently added"))
            let libs = categories[k] ?? []
            if libs.count > 1 { out += libs }
            out += embyGenres[k] ?? []
            return out
        }
        if !continueItems(k).isEmpty { out.append(VodCategory(id: "continue", name: "Continue watching")) }
        out.append(VodCategory(id: "all", name: k == .movies ? "All movies" : "All series"))
        out.append(VodCategory(id: "new", name: "Recently added"))
        let cats = categories[k] ?? []
        if let list = items[k] {
            let used = Set(list.map { $0.categoryId })
            out += cats.filter { used.contains($0.id) }
        } else {
            out += cats
        }
        return out
    }

    func continueItems(_ k: VodKind) -> [VodItem] {
        guard let list = items[k] else { return [] }
        if isEmby {
            let byId = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return (embyContinue[k] ?? []).compactMap { byId[$0.id] }
        }
        var latest: [String: Double] = [:]
        for (key, r) in resumes {
            let id: String?
            if k == .movies { id = key.hasPrefix("m:") ? String(key.dropFirst(2)) : nil }
            else { id = key.hasPrefix("e:") ? r.series : nil }
            if let id { latest[id] = max(latest[id] ?? 0, r.at) }
        }
        guard !latest.isEmpty else { return [] }
        return list.filter { latest[$0.id] != nil }.sorted { (latest[$0.id] ?? 0) > (latest[$1.id] ?? 0) }
    }

    func nextUpItems() -> [VodItem] {
        guard isEmby, let list = items[.series] else { return [] }
        let byId = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return embyNextUp.compactMap { byId[$0] }
    }

    func visible(_ k: VodKind) -> [VodItem] {
        guard let list = items[k] else { return [] }
        let q = query.trimmed.lowercased()
        if !q.isEmpty { return list.filter { $0.name.lowercased().contains(q) } }
        switch category(k) {
        case "continue": return continueItems(k)
        case "nextup": return nextUpItems()
        case "all": return list
        case "new": return Array(list.sorted { $0.added > $1.added }.prefix(isEmby ? 60 : 300))
        case let id: return list.filter { $0.categoryId == id || $0.categories.contains(id) }
        }
    }

    /// The progress bar under a poster.
    func progress(_ item: VodItem) -> Double {
        if isEmby {
            if item.kind == .movies { return item.runtime > 0 && item.position > 0 ? min(1, item.position / item.runtime) : 0 }
            return embyContinue[.series]?.first(where: { $0.id == item.id })?.fraction ?? 0
        }
        if item.kind == .movies { return resumes[item.resumeKey]?.fraction ?? 0 }
        return lastEpisode(of: item.id)?.point.fraction ?? 0
    }

    // MARK: Details and playback

    func movieDetails(_ item: VodItem) async -> VodDetails? {
        if isDemo { return DemoVod.movieDetails(item) }
        if let emby { return try? await emby.details(item.id) }
        return try? await client?.movieInfo(item.id)
    }

    func seriesDetails(_ item: VodItem) async throws -> SeriesDetails {
        if isDemo { return DemoVod.seriesDetails(item) }
        if let emby {
            do { return try await emby.seriesDetails(item.id) }
            catch { throw AppError("Your Emby server didn't send the episodes. Check that it's on.") }
        }
        guard let client else { throw AppError("Not signed in.") }
        do { return try await client.seriesInfo(item.id) }
        catch { throw XtreamClient.friendly(error, server: client.server) }
    }

    func movieURL(_ item: VodItem, ext: String?) -> URL? {
        isDemo ? DemoVod.stream : client?.movieURL(item, ext: ext)
    }

    func episodeURL(_ e: Episode) -> URL? {
        isDemo ? DemoVod.stream : client?.episodeURL(e)
    }

    /// Remembers where you stopped. Near the start or the end it forgets instead.
    func saveResume(_ key: String, pos: Double, dur: Double, title: String, series: String?) {
        guard !providerId.isEmpty, pos.isFinite else { return }
        if pos < 20 || (dur > 0 && (pos > dur * 0.95 || dur - pos < 45)) {
            resumes[key] = nil
        } else {
            resumes[key] = ResumePoint(pos: pos, dur: dur.isFinite ? dur : 0, at: Date().timeIntervalSince1970, title: title, series: series)
        }
        if resumes.count > 80 {
            let keep = resumes.sorted { $0.value.at > $1.value.at }.prefix(80)
            resumes = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        store.setResumes(resumes, providerId)
    }

    /// The episode of a series you watched last.
    func lastEpisode(of seriesId: String) -> (key: String, point: ResumePoint)? {
        resumes.filter { $0.key.hasPrefix("e:") && $0.value.series == seriesId }
            .max { $0.value.at < $1.value.at }
            .map { (key: $0.key, point: $0.value) }
    }
}

// MARK: - Browse screen

@MainActor
struct OnDemandView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var vod: OnDemandModel
    /// Emby playlists: the library is the app's main screen instead of a screen over the guide.
    let embedded: Bool
    @State private var selected: VodItem?
    @FocusState private var searchFocused: Bool

    init(embedded: Bool = false) { self.embedded = embedded }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 700
            let sc = Look.shared.sizeScale
            ZStack {
                RoomBackground()
                VStack(spacing: 12) {
                    header(wide: wide)
                    if wide {
                        HStack(alignment: .top, spacing: 16) {
                            sidebar.frame(width: 220 * sc)
                            content(width: geo.size.width - 220 * sc - 48)
                        }
                    } else {
                        chipRow
                        content(width: geo.size.width - 24)
                    }
                }
                .padding(.horizontal, wide ? 16 : 12)
                .padding(.top, 8)
            }
        }
        .foregroundStyle(Theme.fg)
        .overlay(alignment: .bottom) { if !embedded { ToastOverlay() } }
        .sheet(item: $selected) { item in
            VodDetailView(item: item)
                .environmentObject(model)
                .environmentObject(vod)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .onAppear {
            vod.ensureLoaded(vod.kind)
            if let d = UserDefaults.standard.string(forKey: "nightdial.debug.vod"), d == "details" || d == "series" {
                if d == "series" { vod.kind = .series; vod.ensureLoaded(.series) }
                Task {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    selected = vod.visible(vod.kind).first
                }
            }
        }
        .onChange(of: vod.kind) { k in vod.ensureLoaded(k) }
    }

    private func header(wide: Bool) -> some View {
        HStack(spacing: 12) {
            if embedded {
                Menu {
                    Button { model.sheet = .playlists } label: { Label("Playlists", systemImage: "list.bullet.rectangle") }
                    Button { model.sheet = .settings } label: { Label("Settings", systemImage: "gearshape") }
                    Button { model.sheet = .themes } label: { Label("Themes & look", systemImage: "paintpalette") }
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Theme.cell))
                }
                .accessibilityLabel("Menu")
            } else {
                Button { model.closeOnDemand() } label: {
                    Label("Guide", systemImage: "chevron.left")
                        .font(.ui(14.5, .semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .background(Capsule().fill(Theme.cell))
                }
                .buttonStyle(.plain)
            }
            if wide {
                Text(embedded ? (model.provider?.name ?? "Library") : "Movies & Series").font(.cond(24, .semibold)).lineLimit(1)
            }
            if vod.kinds.count > 1 {
                Picker("Type", selection: $vod.kind) {
                    ForEach(vod.kinds, id: \.self) { k in Text(vod.title(k)).tag(k) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.fg3)
                TextField("", text: $vod.query, prompt: Text("Search \(vod.title(vod.kind).lowercased())").foregroundColor(Theme.fg3))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($searchFocused)
                    .submitLabel(.search)
                if !vod.query.isEmpty {
                    Button { vod.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.fg3) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                }
            }
            .font(.ui(15))
            .padding(.horizontal, 14)
            .frame(height: 40)
            .frame(maxWidth: wide ? 300 : 190)
            .background(Capsule().fill(Theme.cell))
        }
    }

    private var sidebar: some View {
        let k = vod.kind
        let current = vod.query.isEmpty ? vod.category(k) : ""
        return ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(vod.chips(k)) { c in
                    Button { vod.query = ""; vod.setCategory(c.id, for: k) } label: {
                        HStack(spacing: 10) {
                            if c.id == "continue" { Image(systemName: "play.circle").font(.system(size: 14, weight: .semibold)) }
                            if c.id == "nextup" { Image(systemName: "forward.end.circle").font(.system(size: 14, weight: .semibold)) }
                            Text(c.name).font(.ui(14, .medium)).lineLimit(2).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .foregroundStyle(current == c.id ? Theme.hlInk : Theme.fg2)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(current == c.id ? Theme.hl : Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.panel))
    }

    private var chipRow: some View {
        let k = vod.kind
        let current = vod.query.isEmpty ? vod.category(k) : ""
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(vod.chips(k)) { c in
                    Button { vod.query = ""; vod.setCategory(c.id, for: k) } label: {
                        Text(c.name)
                            .font(.ui(13.5, .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .foregroundStyle(current == c.id ? Theme.hlInk : Theme.fg2)
                            .background(Capsule().fill(current == c.id ? Theme.hl : Theme.cell))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        let k = vod.kind
        if let message = vod.errors[k] {
            centered {
                Text("Couldn't load \(vod.title(k).lowercased())").font(.cond(20, .semibold))
                Text(message).font(.ui(14)).foregroundStyle(Theme.fg2).multilineTextAlignment(.center)
                Button("Try again") { vod.retry(k) }.buttonStyle(.borderedProminent).tint(Theme.accent)
            }
        } else if vod.items[k] == nil {
            centered {
                ProgressView().tint(Theme.accent).scaleEffect(1.3)
                Text("Loading \(vod.title(k).lowercased())…").font(.ui(15)).foregroundStyle(Theme.fg2)
            }
        } else {
            let list = vod.visible(k)
            if list.isEmpty {
                centered {
                    Image(systemName: "film").font(.system(size: 30)).foregroundStyle(Theme.fg3)
                    Text(vod.query.isEmpty ? "Nothing in this category." : "Nothing matches \u{201C}\(vod.query)\u{201D}.")
                        .font(.ui(15)).foregroundStyle(Theme.fg2)
                }
            } else {
                let sc = Look.shared.sizeScale
                let minW = (width < 500 ? 104 : 138) * sc
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: minW, maximum: minW * 1.45), spacing: 14, alignment: .top)], spacing: 18) {
                        ForEach(list) { item in
                            Button { searchFocused = false; selected = item } label: {
                                PosterCard(item: item, progress: progress(item))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.bottom, 20)
                }
                .scrollDismissesKeyboard(.immediately)
                .id(k.rawValue + "|" + vod.category(k))
            }
        }
    }

    private func centered<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(spacing: 12) { c() }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func progress(_ item: VodItem) -> Double { vod.progress(item) }
}

/// Poster art: the provider's image over a colored card with the title, so missing artwork still looks deliberate.
struct PosterArt: View {
    let name: String
    let url: URL?
    let hue: Double
    var showTitle = true

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Color(hue: hue.truncatingRemainder(dividingBy: 360) / 360, saturation: 0.42, brightness: 0.42),
                                    Color(hue: (hue + 40).truncatingRemainder(dividingBy: 360) / 360, saturation: 0.55, brightness: 0.16)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if showTitle {
                Text(name)
                    .font(.cond(15, .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(4)
                    .padding(10)
            }
            if let url {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct PosterCard: View {
    let item: VodItem
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay { PosterArt(name: item.name, url: item.poster, hue: item.hue) }
                .overlay(alignment: .bottom) {
                    if progress > 0.01 {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(Color.black.opacity(0.55))
                                Rectangle().fill(Theme.accentGradient).frame(width: g.size.width * CGFloat(progress))
                            }
                        }
                        .frame(height: 5)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if item.played {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(Theme.accentInk)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Theme.accent))
                            .padding(6)
                            .accessibilityLabel("Watched")
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 5)
            Text(item.name).font(.cond(13.5, .semibold)).foregroundStyle(Theme.fg).lineLimit(2)
            if !meta.isEmpty {
                Text(meta).font(.ui(11.5)).foregroundStyle(Theme.fg3).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.name, meta].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
    }

    private var meta: String {
        [item.rating > 0 ? "★ " + String(format: "%.1f", item.rating) : "", item.year].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - Details

@MainActor
struct VodDetailView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var vod: OnDemandModel
    @Environment(\.dismiss) private var dismiss
    let item: VodItem

    @State private var details: VodDetails?
    @State private var series: SeriesDetails?
    @State private var season = 1
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        let info = series?.info ?? details ?? VodDetails()
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero(info)
                VStack(alignment: .leading, spacing: 14) {
                    actions
                    if !info.tagline.isEmpty {
                        Text(info.tagline).font(.ui(15).italic()).foregroundStyle(Theme.fg2)
                    }
                    let plot = info.plot.nonEmpty ?? item.plot
                    if !plot.isEmpty {
                        Text(plot).font(.ui(15)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
                    }
                    if !info.cast.isEmpty { credit("Cast", info.cast) }
                    if !info.director.isEmpty { credit("Director", info.director) }
                    if item.kind == .series { episodesSection }
                    if let error {
                        Text(error).font(.ui(14)).foregroundStyle(Color(uiColor: UIColor(hex: 0xFFC0BA)))
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 30)
        }
        .background(Theme.menu.ignoresSafeArea())
        .foregroundStyle(Theme.fg)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.black.opacity(0.5)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(14)
            .accessibilityLabel("Close")
        }
        .overlay(alignment: .bottom) { ToastOverlay() }
        .task { await load() }
        .onChange(of: vod.embyRevision) { _ in Task { await load(quiet: true) } }
    }

    private func hero(_ info: VodDetails) -> some View {
        ZStack(alignment: .bottomLeading) {
            // Overlay, so a wide backdrop image can't make the sheet wider than the screen.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 230)
                .overlay {
                    ZStack {
                        PosterArt(name: item.name, url: info.backdrop ?? info.poster ?? item.poster, hue: item.hue, showTitle: false)
                            .blur(radius: info.backdrop == nil ? 18 : 0)
                        LinearGradient(colors: [Theme.menu.opacity(0.1), Theme.menu], startPoint: .top, endPoint: .bottom)
                    }
                }
                .clipped()
            HStack(alignment: .bottom, spacing: 16) {
                Color.clear
                    .frame(width: 104, height: 156)
                    .overlay { PosterArt(name: item.name, url: info.poster ?? item.poster, hue: item.hue) }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.45), radius: 14, y: 8)
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.kind == .movies ? "MOVIE" : "SERIES")
                        .font(.cond(11, .semibold)).tracking(1)
                        .foregroundStyle(Theme.accent)
                    Text(item.name).font(.cond(26, .semibold)).lineLimit(3)
                    Text(metaLine(info)).font(.ui(13.5)).foregroundStyle(Theme.fg2).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .offset(y: 40)
        }
        .padding(.bottom, 40)
    }

    private func metaLine(_ info: VodDetails) -> String {
        let rating: Double = info.rating > 0 ? info.rating : item.rating
        var parts: [String] = []
        parts.append(info.year.nonEmpty ?? item.year)
        parts.append(info.duration)
        parts.append(info.official)
        if rating > 0 { parts.append("★ " + String(format: "%.1f", rating)) }
        parts.append(info.genre.nonEmpty ?? item.genre)
        if let s = series { parts.append(s.seasons.count == 1 ? "1 season" : "\(s.seasons.count) seasons") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func credit(_ title: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.ui(13, .semibold)).foregroundStyle(Theme.fg3).frame(width: 64, alignment: .leading)
            Text(text).font(.ui(13.5)).foregroundStyle(Theme.fg2).lineLimit(3)
        }
    }

    /// Where a movie stopped: Emby's own record, or this device's.
    private var movieResume: Double? {
        if vod.isEmby { let p = details?.position ?? item.position; return p > 15 ? p : nil }
        return vod.resumes[item.resumeKey]?.pos
    }

    @ViewBuilder private var actions: some View {
        if item.kind == .movies {
            let r = movieResume
            HStack(spacing: 10) {
                Button { playMovie(from: r ?? 0) } label: {
                    Label(r != nil ? "Resume from \(Fmt.clock(r ?? 0))" : "Play", systemImage: "play.fill").primaryButton()
                }
                if r != nil {
                    Button { playMovie(from: 0) } label: {
                        Label("Start over", systemImage: "arrow.counterclockwise").secondaryButton()
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(loading && details == nil && !vod.isDemo)
            if vod.isEmby {
                let seen = details?.played ?? item.played
                Button {
                    Task {
                        let ok = await vod.embySetPlayed(item.id, kind: .movies, played: !seen)
                        model.showToast(ok ? (seen ? "Marked as unwatched" : "Marked as watched") : "Emby didn't save that. Try again.", seconds: 2)
                    }
                } label: {
                    Label(seen ? "Mark unwatched" : "Mark watched", systemImage: seen ? "eye.slash" : "checkmark").secondaryButton()
                }
                .buttonStyle(.plain)
            }
        } else if let s = series {
            if let first = nextEpisode(s) {
                Button { play(first.episode, from: first.from) } label: {
                    Label(first.from > 0 ? "Resume S\(first.episode.season) E\(first.episode.number) · \(Fmt.clock(first.from))"
                                         : "Play S\(first.episode.season) E\(first.episode.number)",
                          systemImage: "play.fill").primaryButton()
                }
                .buttonStyle(.plain)
            }
        } else if loading {
            HStack(spacing: 10) {
                ProgressView().tint(Theme.accent)
                Text("Loading episodes…").font(.ui(14)).foregroundStyle(Theme.fg2)
            }
        }
    }

    @ViewBuilder private var episodesSection: some View {
        if let s = series, !s.seasons.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                if s.seasons.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(s.seasons, id: \.self) { n in
                                Button { season = n } label: {
                                    Text(n == 0 && vod.isEmby ? "Specials" : "Season \(n)")
                                        .font(.ui(13.5, .semibold))
                                        .padding(.horizontal, 14)
                                        .frame(height: 34)
                                        .foregroundStyle(season == n ? Theme.hlInk : Theme.fg2)
                                        .background(Capsule().fill(season == n ? Theme.hl : Theme.cell))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } else {
                    Text(s.seasons[0] == 0 && vod.isEmby ? "Specials" : "Season \(s.seasons[0])").font(.cond(18, .semibold))
                }
                ForEach(s.episodes[season] ?? []) { e in episodeRow(e) }
            }
            .padding(.top, 6)
        } else if series != nil {
            Text("No episodes are available for this series.").font(.ui(14)).foregroundStyle(Theme.fg3)
        }
    }

    private func episodeRow(_ e: Episode) -> some View {
        let r: ResumePoint? = vod.isEmby ? (e.position > 15 ? ResumePoint(pos: e.position, dur: e.runtime, at: 0, title: e.title) : nil) : vod.resumes[e.resumeKey]
        return Button { play(e, from: r?.pos ?? 0) } label: {
            HStack(alignment: .top, spacing: 12) {
                Color.clear
                    .frame(width: 124, height: 70)
                    .overlay { PosterArt(name: "E\(e.number)", url: e.image, hue: item.hue + Double(e.number * 9)) }
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color.black.opacity(0.45)))
                    }
                    .overlay(alignment: .bottom) {
                        if let r, r.fraction > 0.01 {
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(Color.black.opacity(0.55))
                                    Rectangle().fill(Theme.accentGradient).frame(width: g.size.width * CGFloat(r.fraction))
                                }
                            }
                            .frame(height: 4)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("\(e.number). \(e.title)").font(.cond(14.5, .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                        if e.played {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.accent).accessibilityLabel("Watched")
                        }
                    }
                    let sub = [e.duration, r.map { "\(Fmt.clock($0.pos)) watched" } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
                    if !sub.isEmpty { Text(sub).font(.ui(12)).foregroundStyle(Theme.fg3) }
                    if !e.plot.isEmpty {
                        Text(e.plot).font(.ui(12.5)).foregroundStyle(Theme.fg2).lineLimit(2).multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.cell.opacity(0.6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The episode to continue: the last one you were watching, or the first.
    private func nextEpisode(_ s: SeriesDetails) -> (episode: Episode, from: Double)? {
        let all = s.seasons.flatMap { s.episodes[$0] ?? [] }
        if vod.isEmby {
            if let id = s.nextEpisodeId, let e = all.first(where: { $0.id == id }) { return (episode: e, from: e.position > 15 ? e.position : 0) }
            if let e = all.first(where: { !$0.played && $0.season != 0 }) ?? all.first { return (episode: e, from: e.position > 15 ? e.position : 0) }
            return nil
        }
        if let last = vod.lastEpisode(of: item.id), let e = all.first(where: { $0.resumeKey == last.key }) {
            return (episode: e, from: last.point.pos)
        }
        if let f = all.first { return (episode: f, from: 0) }
        return nil
    }

    private func load(quiet: Bool = false) async {
        if !quiet { loading = true }
        if item.kind == .movies {
            details = await vod.movieDetails(item)
        } else {
            do {
                let s = try await vod.seriesDetails(item)
                series = s
                if quiet {
                    // after watching: stay on the season you're in
                } else if vod.isEmby, let next = nextEpisode(s) {
                    season = next.episode.season
                } else if let last = vod.lastEpisode(of: item.id),
                   let e = s.seasons.flatMap({ s.episodes[$0] ?? [] }).first(where: { $0.resumeKey == last.key }) {
                    season = e.season
                } else {
                    season = s.seasons.first ?? 1
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
        loading = false
    }

    private func playMovie(from start: Double) {
        if let emby = vod.emby {
            playEmby(emby, id: item.id, kind: .movies, title: item.name, subtitle: metaLine(details ?? VodDetails()), details: details, from: start)
            return
        }
        guard let url = vod.movieURL(item, ext: details?.ext) else { return }
        let key = item.resumeKey, title = item.name
        let store = vod, app = model     // keep the objects themselves; the closures outlive this view
        VodPlayback.present(url: url, title: title, subtitle: metaLine(details ?? VodDetails()), start: start, ext: details?.ext.nonEmpty ?? item.ext) { pos, dur in
            store.saveResume(key, pos: pos, dur: dur, title: title, series: nil)
        } onError: { message in
            app.showToast(message, seconds: 5)
        }
    }

    /// Emby: ask how to play it, then report start, progress every 10 s and where you stopped.
    private func playEmby(_ emby: EmbyClient, id: String, kind: VodKind, title: String, subtitle: String, details: VodDetails?, from start: Double) {
        let store = vod, app = model, seriesItem = item
        Task { @MainActor in
            guard let pb = await emby.playback(id, details: details) else { app.showToast("Couldn't start this on your Emby server. Try again.", seconds: 4); return }
            Task { await emby.report("start", pb, itemId: id, position: start) }
            VodPlayback.present(url: pb.url, title: title, subtitle: subtitle, start: start, ext: "") { pos, dur in
                guard pos > 0 || dur > 0 else { return }
                Task { await emby.report("progress", pb, itemId: id, position: pos) }
            } onError: { message in
                app.showToast(message, seconds: 5)
            } onStop: { pos, dur, finished in
                Task { @MainActor in
                    await emby.report("stop", pb, itemId: id, position: finished ? max(pos, dur) : pos)
                    store.embyNote(kind == .movies ? id : seriesItem.id, kind: kind, position: finished ? 0 : pos, runtime: kind == .movies ? dur : 0, finished: finished && kind == .movies)
                }
            }
        }
    }

    private func play(_ e: Episode, from start: Double) {
        if let emby = vod.emby {
            playEmby(emby, id: e.id, kind: .series, title: "\(item.name) · S\(e.season) E\(e.number)", subtitle: e.title, details: nil, from: start)
            return
        }
        guard let url = vod.episodeURL(e) else { return }
        let key = e.resumeKey, seriesId = item.id
        let title = "\(item.name) · S\(e.season) E\(e.number)"
        let store = vod, app = model
        VodPlayback.present(url: url, title: title, subtitle: e.title, start: start, ext: e.ext) { pos, dur in
            store.saveResume(key, pos: pos, dur: dur, title: title, series: seriesId)
        } onError: { message in
            app.showToast(message, seconds: 5)
        }
    }
}

// MARK: - Player

/// Apple's own full-screen player for movies and episodes: scrubbing, pause, skip, AirPlay and audio/subtitle menus.
@MainActor
enum VodPlayback {
    static func present(url: URL, title: String, subtitle: String, start: Double, ext: String,
                        onSave: @escaping (Double, Double) -> Void, onError: @escaping (String) -> Void,
                        onStop: ((Double, Double, Bool) -> Void)? = nil) {
        guard let top = topController() else { return }
        let vc = VodPlayerController()
        vc.modalPresentationStyle = .fullScreen
        vc.onSave = onSave
        vc.onStop = onStop
        vc.onError = { [weak vc] in
            vc?.dismiss(animated: true)
            let e = ext.lowercased()
            onError(["mkv", "avi", "wmv", "flv"].contains(e)
                    ? "This video is a .\(e) file, which iPhone and iPad can't play. Try it on Fire TV or in the browser."
                    : "This video couldn't be played. Try again in a moment.")
        }
        top.present(vc, animated: true) {
            vc.start(url: url, title: title, subtitle: subtitle, startAt: start)
        }
    }

    static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var vc = window?.rootViewController
        while let p = vc?.presentedViewController, !p.isBeingDismissed { vc = p }
        return vc
    }
}

final class VodPlayerController: AVPlayerViewController {
    var onSave: ((Double, Double) -> Void)?
    var onError: (() -> Void)?
    /// Where playback ended (position, length, played to the end), once.
    var onStop: ((Double, Double, Bool) -> Void)?
    private var stopSent = false
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var finished = false

    override func viewDidLoad() {
        super.viewDidLoad()
        allowsPictureInPicturePlayback = false
        view.backgroundColor = .black
    }

    func start(url: URL, title: String, subtitle: String, startAt: Double) {
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": Net.userAgent]])
        let item = AVPlayerItem(asset: asset)
        item.externalMetadata = [Self.meta(.commonIdentifierTitle, title), Self.meta(.iTunesMetadataTrackSubTitle, subtitle)]
        let p = AVPlayer(playerItem: item)
        p.allowsExternalPlayback = true
        player = p
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            let failed = observed.status == .failed
            Task { @MainActor [weak self] in if failed { self?.fail() } }
        }
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.report() }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reachedEnd() }
        }
        if startAt > 5 { p.seek(to: CMTime(seconds: startAt, preferredTimescale: 600)) }
        p.play()
    }

    private static func meta(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let m = AVMutableMetadataItem()
        m.identifier = id
        m.value = value as NSString
        m.extendedLanguageTag = "und"
        return m
    }

    private func report() {
        guard !finished, let p = player, let item = p.currentItem, item.status == .readyToPlay else { return }
        let pos = p.currentTime().seconds
        let dur = item.duration.seconds
        if pos.isFinite { onSave?(pos, dur.isFinite ? dur : 0) }
    }

    private func reachedEnd() {
        guard !finished else { return }
        finished = true
        onSave?(0, 0)          // finished: forget the position
        if !stopSent, let item = player?.currentItem {
            stopSent = true
            let d = item.duration.seconds
            onStop?(d.isFinite ? d : 0, d.isFinite ? d : 0, true)
        }
        dismiss(animated: true)
    }

    private func fail() {
        guard !finished else { return }
        finished = true
        onError?()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || presentingViewController == nil else { return }
        report()
        if !stopSent, let p = player, let item = p.currentItem {
            stopSent = true
            let pos = p.currentTime().seconds, d = item.duration.seconds
            onStop?(pos.isFinite ? pos : 0, d.isFinite ? d : 0, false)
        }
        finished = true
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.replaceCurrentItem(with: nil)
    }
}

// MARK: - Demo catalog (only used for screenshots with -nightdial.debug.demo)

enum DemoVod {
    static let stream = URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")

    static let categories: [VodKind: [VodCategory]] = [
        .movies: [VodCategory(id: "1", name: "Drama"), VodCategory(id: "2", name: "Thriller"), VodCategory(id: "3", name: "Family")],
        .series: [VodCategory(id: "10", name: "Drama series"), VodCategory(id: "11", name: "Comedy & reality"), VodCategory(id: "12", name: "Documentary & kids")]
    ]

    private static let movies: [(String, String)] = [
        ("The Lantern Keeper", "A lighthouse keeper on a storm-bound island finds a logbook that rewrites her family history."),
        ("Northbound Express", "Strangers on an overnight train realize one of them isn't who they claim to be."),
        ("A Quiet Harbor", "A retired ferry captain and his estranged son spend one summer restoring an old boat."),
        ("Glass Orchard", "Two rival glassblowers are forced to share a workshop in a small mountain town."),
        ("The Cartographer's Daughter", "A young mapmaker sets out to finish the survey her father never completed."),
        ("Seven Winters", "A love story told across seven winters in the same snowed-in cabin."),
        ("Static Bloom", "A radio engineer picks up a signal that seems to come from tomorrow."),
        ("Iron Meridian", "A railway detective chases a gang of thieves across the frontier."),
        ("Paper Moons", "A struggling puppet theater gets one last chance at a sold-out show."),
        ("The Long Field", "A farming family fights to keep their land through a year of drought."),
        ("Neon Tide", "A night-shift paramedic is pulled into a citywide conspiracy."),
        ("Under Copper Skies", "Miners trapped underground keep each other going for nine days."),
        ("Saltwater Kings", "Two brothers inherit a failing fishing fleet and a dangerous debt."),
        ("The Last Ferry", "Passengers on the final crossing of the season are stranded by fog.")
    ]

    private static let series: [(String, String, String)] = [
        ("Harbor Lights", "A coastal town keeps its secrets until a new harbor master starts asking questions.", "Drama"),
        ("The Night Desk", "Reporters on the overnight shift of a city newspaper chase the stories nobody else will.", "Drama"),
        ("Kitchen Rivals: Grand Tour", "Twelve cooks travel the country, one regional dish at a time.", "Reality"),
        ("Wild Atlas", "Six landscapes followed through a single year.", "Documentary"),
        ("Flat 4B", "Three friends, one tiny apartment and a landlord who never fixes anything.", "Comedy"),
        ("Northbound", "A train crew and its passengers cross a continent over one long winter.", "Thriller"),
        ("Pip & Pebble", "Small adventures around the harbor for little viewers.", "Kids"),
        ("The Clockmakers", "A family workshop, five generations and one impossible commission.", "Drama")
    ]

    static func items(_ k: VodKind) -> [VodItem] {
        if k == .movies {
            return movies.enumerated().map { i, m in
                let h = fnv1a(m.0)
                return VodItem(id: "dm\(i)", kind: .movies, name: m.0, poster: nil, categoryId: ["1", "2", "3"][i % 3],
                               rating: 6.4 + Double(h % 30) / 10, year: String(1986 + Int(h % 38)), ext: "mp4", added: Double(i), plot: m.1)
            }
        }
        return series.enumerated().map { i, s in
            let h = fnv1a(s.0)
            let cat = s.2 == "Documentary" || s.2 == "Kids" ? "12" : s.2 == "Comedy" || s.2 == "Reality" ? "11" : "10"
            return VodItem(id: "ds\(i)", kind: .series, name: s.0, poster: nil, categoryId: cat,
                           rating: 7 + Double(h % 25) / 10, year: String(2012 + Int(h % 13)), ext: "mp4", added: Double(i), plot: s.1, genre: s.2)
        }
    }

    static func movieDetails(_ item: VodItem) -> VodDetails {
        var d = VodDetails()
        d.plot = item.plot
        d.genre = DemoVod.categories[.movies]?.first(where: { $0.id == item.categoryId })?.name ?? ""
        d.cast = "Mara Ellison, Tom Avery, June Okafor"
        d.director = "Lena Hart"
        d.duration = Fmt.duration(Double(5400 + Int(fnv1a(item.name) % 2400)))
        d.year = item.year
        d.rating = item.rating
        return d
    }

    static func seriesDetails(_ item: VodItem) -> SeriesDetails {
        var s = SeriesDetails()
        s.info.plot = item.plot
        s.info.genre = item.genre
        s.info.cast = "Ana Ruiz, Ben Calder, Priya Shah"
        s.info.year = item.year
        s.info.rating = item.rating
        let seasons = 1 + Int(fnv1a(item.name) % 3)
        let titles = ["Pilot", "Low Tide", "The Visitor", "Old Debts", "Crossing", "Signals", "Undertow", "Homecoming"]
        for n in 1...seasons {
            s.episodes[n] = (1...6).map { e in
                Episode(id: "\(item.id)-\(n)-\(e)", season: n, number: e, title: titles[(e - 1 + n) % titles.count], ext: "mp4",
                        plot: "Episode \(e) of season \(n).", duration: Fmt.duration(Double(2400 + e * 60)))
            }
        }
        s.seasons = Array(1...seasons)
        return s
    }
}

/// Toasts also show over screens presented on top of the guide.
@MainActor
struct ToastOverlay: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if let text = model.toast {
                ToastView(text: text).padding(.bottom, 30).transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.2), value: model.toast)
    }
}

// MARK: - Emby (and Jellyfin)

/// How a movie or episode is played from Emby: the file as it is, or converted to HLS by the server.
struct EmbyPlayback {
    let url: URL
    let session: String
    let mediaSourceId: String
    let method: String
}

/// Your own movies and shows from an Emby (or Jellyfin) server. Signing in gives an access token, which is kept in the
/// Keychain instead of the password. What you watch is reported back, so Continue watching and watched marks match
/// your other Emby apps.
final class EmbyClient {
    let server: String
    let userId: String
    let token: String

    init(server: String, userId: String, token: String) {
        self.server = server
        self.userId = userId
        self.token = token
    }

    struct HTTPError: Error { let code: Int }

    static let fields = "Genres,ProductionYear,CommunityRating,OfficialRating,DateCreated,RunTimeTicks"

    static var deviceId: String {
        let key = "nightdial.deviceId"
        if let d = UserDefaults.standard.string(forKey: key), !d.isEmpty { return d }
        let d = "nd" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24))
        UserDefaults.standard.set(d, forKey: key)
        return d
    }

    static func authHeader(_ token: String?) -> String {
        var s = "MediaBrowser Client=\"Nightdial\", Device=\"iPhone\", DeviceId=\"\(deviceId)\", Version=\"1.0\""
        if let token, !token.isEmpty { s += ", Token=\"\(token)\"" }
        return s
    }

    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    static func call(_ server: String, _ method: String, _ path: String, token: String?, body: [String: Any]? = nil, timeout: TimeInterval = 30) async throws -> Any? {
        guard let url = URL(string: server + path) else { throw AppError("That server address doesn't look right.") }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue(authHeader(token), forHTTPHeaderField: "X-Emby-Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code >= 400 { throw HTTPError(code: code) }
        if data.isEmpty { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func get(_ path: String, timeout: TimeInterval = 30) async throws -> [String: Any] {
        (try await Self.call(server, "GET", path, token: token, timeout: timeout) as? [String: Any]) ?? [:]
    }

    private func send(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws {
        _ = try await Self.call(server, method, path, token: token, body: body)
    }

    // MARK: Sign-in

    /// What people type: "192.168.1.20:8096", "emby.example.com", or the address of Emby's web page.
    static func servers(_ raw: String) -> [String] {
        var s = raw.trimmed
        if let i = s.firstIndex(where: { $0 == "#" || $0 == "?" }) { s = String(s[..<i]) }
        if let r = s.range(of: "/web", options: [.caseInsensitive, .backwards]), s[r.upperBound...].isEmpty || s[r.upperBound...].hasPrefix("/") { s = String(s[..<r.lowerBound]) }
        while s.hasSuffix("/") { s.removeLast() }
        if s.isEmpty { return [] }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "http://" + s }
        guard var c = URLComponents(string: s) else { return [s] }
        c.query = nil
        c.fragment = nil
        guard let base = c.string else { return [s] }
        var out = [base]
        if c.port == nil {
            c.port = c.scheme == "https" ? 8920 : 8096
            if let alt = c.string { out.append(alt) }
        }
        return out
    }

    private static func provider(_ base: String, _ user: String, _ uid: String, _ token: String, _ info: [String: Any], _ name: String) -> Provider {
        let jelly = ((info["ProductName"] as? String) ?? "").lowercased().contains("jellyfin")
        var p = Provider(id: "e" + String(fnv1a(base + "|" + uid), radix: 36), kind: .emby,
                         name: name.trimmed.nonEmpty ?? (info["ServerName"] as? String)?.nonEmpty ?? (jelly ? "Jellyfin" : "Emby"))
        p.server = base
        p.user = user
        p.userId = uid
        p.token = token
        p.info = AccountInfo(status: (jelly ? "Jellyfin " : "Emby ") + ((info["Version"] as? String) ?? ""))
        return p
    }

    static func connect(name: String, server raw: String, user: String, pass: String,
                        step: @escaping @MainActor (String) -> Void) async throws -> XtreamClient.LoginResult {
        let list = servers(raw)
        guard let first = list.first else { throw AppError("Enter your Emby server address, like http://192.168.1.20:8096") }
        guard !user.trimmed.isEmpty else { throw AppError("Enter your Emby username.") }
        await step("Finding your server…")
        var found: (String, [String: Any])? = nil
        for s in list {
            if let info = (try? await call(s, "GET", "/System/Info/Public", token: nil, timeout: 12)) as? [String: Any],
               info["Id"] != nil || info["ServerName"] != nil {
                found = (s, info)
                break
            }
        }
        guard let found else {
            throw AppError("No Emby server answered at \(URL(string: first)?.host ?? first). Check the address and port (Emby uses 8096, or 8920 for https).")
        }
        let (base, info) = found
        await step("Signing in…")
        let auth: [String: Any]
        do {
            auth = (try await call(base, "POST", "/Users/AuthenticateByName", token: nil, body: ["Username": user.trimmed, "Pw": pass]) as? [String: Any]) ?? [:]
        } catch let e as HTTPError where e.code == 401 {
            throw AppError("Emby didn't accept that username and password.")
        } catch {
            throw AppError("Emby couldn't sign you in (\(error.localizedDescription)).")
        }
        guard let token = auth["AccessToken"] as? String, let u = auth["User"] as? [String: Any], let uid = u["Id"] as? String else {
            throw AppError("Emby didn't accept that username and password.")
        }
        return XtreamClient.LoginResult(provider: provider(base, user.trimmed, uid, token, info, name), channels: [], groups: [])
    }

    /// A saved Emby playlist signs in with its saved access token.
    static func resume(_ pl: Playlist, token: String) async throws -> XtreamClient.LoginResult {
        guard !token.isEmpty, let uid = pl.userId, !uid.isEmpty else { throw AppError("Sign in to Emby again.") }
        let host = URL(string: pl.server)?.host ?? pl.server
        let info: [String: Any]
        do { info = (try await call(pl.server, "GET", "/System/Info/Public", token: nil, timeout: 15) as? [String: Any]) ?? [:] }
        catch { throw AppError("Couldn't reach your Emby server at \(host). Is it on?") }
        do { _ = try await call(pl.server, "GET", "/Users/\(uid)", token: token, timeout: 15) }
        catch let e as HTTPError where e.code == 401 { throw AppError("Emby signed you out. Enter your password to sign in again.") }
        catch { throw AppError("Couldn't reach your Emby server at \(host).") }
        return XtreamClient.LoginResult(provider: provider(pl.server, pl.user, uid, token, info, pl.name), channels: [], groups: [])
    }

    func logout() async { try? await send("POST", "/Sessions/Logout") }

    // MARK: Library

    func image(_ id: String, tag: String?, kind: String = "Primary", size: String = "maxHeight=450") -> URL? {
        var s = "\(server)/Items/\(id)/Images/\(kind)?\(size)&quality=90"
        if let tag, !tag.isEmpty { s += "&tag=\(tag)" }
        return URL(string: s)
    }

    private static func num(_ d: [String: Any], _ k: String) -> Double { (d[k] as? NSNumber)?.doubleValue ?? 0 }
    private static func text(_ d: [String: Any], _ k: String) -> String { (d[k] as? String) ?? "" }
    private static func items(_ d: [String: Any]) -> [[String: Any]] { (d["Items"] as? [[String: Any]]) ?? [] }
    private static let created: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    /// Libraries for movies and for TV shows.
    func libraries() async -> [VodKind: [VodCategory]] {
        guard let d = try? await get("/Users/\(userId)/Views") else { return [:] }
        var out: [VodKind: [VodCategory]] = [.movies: [], .series: []]
        for v in Self.items(d) {
            let id = Self.text(v, "Id"), name = Self.text(v, "Name").nonEmpty ?? "Library"
            let type = (Self.text(v, "CollectionType").nonEmpty ?? "mixed").lowercased()
            if type == "movies" || type == "mixed" { out[.movies, default: []].append(VodCategory(id: id, name: name)) }
            if type == "tvshows" || type == "mixed" { out[.series, default: []].append(VodCategory(id: id, name: name)) }
        }
        return out
    }

    func vodItem(_ it: [String: Any], library: String?) -> VodItem {
        let ud = it["UserData"] as? [String: Any] ?? [:]
        let id = Self.text(it, "Id"), type = Self.text(it, "Type")
        let tags = it["ImageTags"] as? [String: Any] ?? [:]
        let genres = it["Genres"] as? [String] ?? []
        let year = Self.num(it, "ProductionYear")
        let added = Self.created.date(from: String(Self.text(it, "DateCreated").prefix(19)))?.timeIntervalSince1970 ?? 0
        var item = VodItem(id: id, kind: type == "Series" ? .series : .movies, name: Self.text(it, "Name"),
                           poster: (tags["Primary"] as? String).flatMap { image(id, tag: $0) }, categoryId: library ?? "",
                           rating: Self.num(it, "CommunityRating"), year: year > 0 ? String(Int(year)) : "", ext: "", added: added,
                           genre: genres.prefix(3).joined(separator: ", "))
        item.played = (ud["Played"] as? Bool) ?? false
        item.position = Self.num(ud, "PlaybackPositionTicks") / 1e7
        item.runtime = Self.num(it, "RunTimeTicks") / 1e7
        item.categories = ([library].compactMap { $0 } + genres.map { "g:" + $0 }).filter { !$0.isEmpty }
        return item
    }

    func items(_ k: VodKind, in libraries: [VodCategory]) async throws -> [VodItem] {
        let type = k == .movies ? "Movie" : "Series"
        var seen: [String: Int] = [:]
        var out: [VodItem] = []
        let libs: [VodCategory?] = libraries.isEmpty ? [nil] : libraries.map { Optional($0) }
        for lib in libs {
            let parent = lib.map { "ParentId=\($0.id)&" } ?? ""
            let d = try await get("/Users/\(userId)/Items?\(parent)IncludeItemTypes=\(type)&Recursive=true&Fields=\(Self.fields)&SortBy=SortName&SortOrder=Ascending&EnableImageTypes=Primary&ImageTypeLimit=1", timeout: 120)
            for it in Self.items(d) {
                let id = Self.text(it, "Id")
                if let i = seen[id] {
                    if let lib, !out[i].categories.contains(lib.id) { out[i].categories.append(lib.id) }
                } else {
                    seen[id] = out.count
                    out.append(vodItem(it, library: lib?.id))
                }
            }
        }
        return out
    }

    /// Continue watching: movies, or the series of episodes you're partway through (with how far in).
    func resumeList(_ k: VodKind) async -> [(id: String, fraction: Double)] {
        let type = k == .movies ? "Movie" : "Episode"
        guard let d = try? await get("/Users/\(userId)/Items/Resume?Limit=40&Recursive=true&IncludeItemTypes=\(type)&Fields=\(Self.fields)") else { return [] }
        var out: [(id: String, fraction: Double)] = []
        for it in Self.items(d) {
            let ud = it["UserData"] as? [String: Any] ?? [:]
            let run = Self.num(it, "RunTimeTicks"), pos = Self.num(ud, "PlaybackPositionTicks")
            let id = k == .movies ? Self.text(it, "Id") : Self.text(it, "SeriesId")
            if !id.isEmpty, !out.contains(where: { $0.id == id }) { out.append((id: id, fraction: run > 0 ? pos / run : 0)) }
        }
        return out
    }

    /// Next up: series with an episode waiting.
    func nextUpSeries() async -> [String] {
        guard let d = try? await get("/Shows/NextUp?UserId=\(userId)&Limit=40&Fields=\(Self.fields)") else { return [] }
        var out: [String] = []
        for it in Self.items(d) { let s = Self.text(it, "SeriesId"); if !s.isEmpty, !out.contains(s) { out.append(s) } }
        return out
    }

    private func people(_ d: [String: Any], _ type: String) -> String {
        ((d["People"] as? [[String: Any]]) ?? []).filter { Self.text($0, "Type") == type }.prefix(6).map { Self.text($0, "Name") }.joined(separator: ", ")
    }

    func details(_ id: String) async throws -> VodDetails {
        let d = try await get("/Users/\(userId)/Items/\(id)?Fields=MediaSources,People,Genres,Overview,Taglines")
        var v = VodDetails()
        v.plot = Self.text(d, "Overview")
        v.genre = ((d["Genres"] as? [String]) ?? []).prefix(3).joined(separator: ", ")
        v.cast = people(d, "Actor")
        v.director = people(d, "Director")
        let run = Self.num(d, "RunTimeTicks") / 1e7
        v.runtime = run
        v.duration = run > 0 ? Fmt.duration(run) : ""
        let year = Self.num(d, "ProductionYear")
        v.year = year > 0 ? String(Int(year)) : ""
        v.rating = Self.num(d, "CommunityRating")
        v.official = Self.text(d, "OfficialRating")
        v.tagline = ((d["Taglines"] as? [String]) ?? []).first ?? ""
        if let tags = d["BackdropImageTags"] as? [String], let t = tags.first { v.backdrop = image(id, tag: t, kind: "Backdrop/0", size: "maxWidth=1280") }
        if let tags = d["ImageTags"] as? [String: Any], let t = tags["Primary"] as? String { v.poster = image(id, tag: t) }
        let ud = d["UserData"] as? [String: Any] ?? [:]
        v.played = (ud["Played"] as? Bool) ?? false
        v.position = Self.num(ud, "PlaybackPositionTicks") / 1e7
        if let ms = (d["MediaSources"] as? [[String: Any]])?.first {
            v.mediaSourceId = Self.text(ms, "Id")
            v.ext = (Self.text(ms, "Container").split(separator: ",").first.map(String.init) ?? "").lowercased()
            let streams = (ms["MediaStreams"] as? [[String: Any]]) ?? []
            v.videoCodec = streams.first(where: { Self.text($0, "Type") == "Video" }).map { Self.text($0, "Codec").lowercased() } ?? ""
            let audio = streams.first(where: { Self.text($0, "Type") == "Audio" && (($0["IsDefault"] as? Bool) ?? false) }) ?? streams.first(where: { Self.text($0, "Type") == "Audio" })
            v.audioCodec = audio.map { Self.text($0, "Codec").lowercased() } ?? ""
        }
        return v
    }

    func seriesDetails(_ id: String) async throws -> SeriesDetails {
        async let info = self.details(id)
        async let eps = self.get("/Shows/\(id)/Episodes?UserId=\(userId)&Fields=Overview,RunTimeTicks&EnableImageTypes=Primary&ImageTypeLimit=1", timeout: 60)
        async let next = try? self.get("/Shows/NextUp?UserId=\(userId)&SeriesId=\(id)&Limit=1")
        var s = SeriesDetails()
        s.info = (try? await info) ?? VodDetails()
        let list = try await eps
        for it in Self.items(list) {
            let ud = it["UserData"] as? [String: Any] ?? [:]
            let season = Int(Self.num(it, "ParentIndexNumber")), run = Self.num(it, "RunTimeTicks") / 1e7
            let eid = Self.text(it, "Id"), tags = it["ImageTags"] as? [String: Any] ?? [:]
            var e = Episode(id: eid, season: season, number: Int(Self.num(it, "IndexNumber")), title: Self.text(it, "Name"), ext: "",
                            plot: Self.text(it, "Overview"), duration: run > 0 ? Fmt.duration(run) : "",
                            image: (tags["Primary"] as? String).flatMap { image(eid, tag: $0, size: "maxWidth=400") })
            e.played = (ud["Played"] as? Bool) ?? false
            e.position = Self.num(ud, "PlaybackPositionTicks") / 1e7
            e.runtime = run
            s.episodes[season, default: []].append(e)
        }
        s.seasons = s.episodes.keys.sorted { ($0 == 0 ? Int.max : $0) < ($1 == 0 ? Int.max : $1) }   // specials last
        if let n = (await next).flatMap({ Self.items($0).first }) { s.nextEpisodeId = Self.text(n, "Id") }
        return s
    }

    // MARK: Playing

    /// iPhone plays MP4/MOV with H.264 or HEVC as they are; anything else (MKV, other codecs) Emby converts to HLS.
    func playback(_ id: String, details: VodDetails?) async -> EmbyPlayback? {
        var d = details
        if d == nil || d?.mediaSourceId.isEmpty == true { d = try? await self.details(id) }
        let ps = "nd" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16))
        let container = d?.ext ?? "", v = d?.videoCodec ?? "", a = d?.audioCodec ?? ""
        let msid = d?.mediaSourceId.nonEmpty ?? id
        let q = "api_key=\(token)&DeviceId=\(Self.deviceId)&PlaySessionId=\(ps)"
        let direct = ["mp4", "m4v", "mov"].contains(container) && ["h264", "avc", "hevc", "h265"].contains(v) && ["aac", "ac3", "eac3", "mp3", "alac", "flac", ""].contains(a)
        let path = direct
            ? "/Videos/\(id)/stream.\(container)?static=true&MediaSourceId=\(msid)&\(q)"
            : "/Videos/\(id)/master.m3u8?MediaSourceId=\(msid)&VideoCodec=h264&AudioCodec=aac,ac3,eac3&MaxAudioChannels=6&TranscodingMaxAudioChannels=6&VideoBitRate=40000000&AudioBitRate=640000&SegmentContainer=ts&BreakOnNonKeyFrames=True&EnableAutoStreamCopy=true&\(q)"
        guard let url = URL(string: server + path) else { return nil }
        return EmbyPlayback(url: url, session: ps, mediaSourceId: msid, method: direct ? "DirectStream" : "Transcode")
    }

    /// "start", "progress" or "stop", with where you are.
    func report(_ what: String, _ pb: EmbyPlayback, itemId: String, position: Double, paused: Bool = false) async {
        let path = what == "start" ? "/Sessions/Playing" : what == "stop" ? "/Sessions/Playing/Stopped" : "/Sessions/Playing/Progress"
        let body: [String: Any] = ["ItemId": itemId, "MediaSourceId": pb.mediaSourceId, "PlaySessionId": pb.session,
                                   "PositionTicks": Int64(max(0, position) * 1e7), "IsPaused": paused, "CanSeek": true, "PlayMethod": pb.method]
        try? await send("POST", path, body)
    }

    func setPlayed(_ id: String, _ played: Bool) async throws {
        try await send(played ? "POST" : "DELETE", "/Users/\(userId)/PlayedItems/\(id)")
    }
}
