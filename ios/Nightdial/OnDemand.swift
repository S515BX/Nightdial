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
    private(set) var providerId = ""
    private(set) var isDemo = false
    private let store = Store.shared
    private var token = 0

    func reset() {
        token += 1
        available = false
        client = nil
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

    var kinds: [VodKind] { VodKind.allCases.filter { !(categories[$0] ?? []).isEmpty } }

    func ensureLoaded(_ k: VodKind) {
        guard items[k] == nil, !loading.contains(k) else { return }
        if isDemo { items[k] = DemoVod.items(k); return }
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
        return c
    }

    func setCategory(_ id: String, for k: VodKind) { selectedCategory[k] = id }

    /// Continue watching (when there's any), everything, recently added, then the provider's categories.
    func chips(_ k: VodKind) -> [VodCategory] {
        var out: [VodCategory] = []
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

    func visible(_ k: VodKind) -> [VodItem] {
        guard let list = items[k] else { return [] }
        let q = query.trimmed.lowercased()
        if !q.isEmpty { return list.filter { $0.name.lowercased().contains(q) } }
        switch category(k) {
        case "continue": return continueItems(k)
        case "all": return list
        case "new": return Array(list.sorted { $0.added > $1.added }.prefix(300))
        case let id: return list.filter { $0.categoryId == id }
        }
    }

    // MARK: Details and playback

    func movieDetails(_ item: VodItem) async -> VodDetails? {
        if isDemo { return DemoVod.movieDetails(item) }
        return try? await client?.movieInfo(item.id)
    }

    func seriesDetails(_ item: VodItem) async throws -> SeriesDetails {
        if isDemo { return DemoVod.seriesDetails(item) }
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
    @State private var selected: VodItem?
    @FocusState private var searchFocused: Bool

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
        .overlay(alignment: .bottom) { ToastOverlay() }
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
            Button { model.closeOnDemand() } label: {
                Label("Guide", systemImage: "chevron.left")
                    .font(.ui(14.5, .semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .background(Capsule().fill(Theme.cell))
            }
            .buttonStyle(.plain)
            if wide {
                Text("Movies & Series").font(.cond(24, .semibold)).lineLimit(1)
            }
            if vod.kinds.count > 1 {
                Picker("Type", selection: $vod.kind) {
                    ForEach(vod.kinds, id: \.self) { k in Text(k.title).tag(k) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.fg3)
                TextField("", text: $vod.query, prompt: Text("Search \(vod.kind.title.lowercased())").foregroundColor(Theme.fg3))
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
                Text("Couldn't load \(k.title.lowercased())").font(.cond(20, .semibold))
                Text(message).font(.ui(14)).foregroundStyle(Theme.fg2).multilineTextAlignment(.center)
                Button("Try again") { vod.retry(k) }.buttonStyle(.borderedProminent).tint(Theme.accent)
            }
        } else if vod.items[k] == nil {
            centered {
                ProgressView().tint(Theme.accent).scaleEffect(1.3)
                Text("Loading \(k.title.lowercased())…").font(.ui(15)).foregroundStyle(Theme.fg2)
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

    private func progress(_ item: VodItem) -> Double {
        if item.kind == .movies { return vod.resumes[item.resumeKey]?.fraction ?? 0 }
        return vod.lastEpisode(of: item.id)?.point.fraction ?? 0
    }
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

    @ViewBuilder private var actions: some View {
        if item.kind == .movies {
            let r = vod.resumes[item.resumeKey]
            HStack(spacing: 10) {
                Button { playMovie(from: r?.pos ?? 0) } label: {
                    Label(r != nil ? "Resume from \(Fmt.clock(r!.pos))" : "Play", systemImage: "play.fill").primaryButton()
                }
                if r != nil {
                    Button { playMovie(from: 0) } label: {
                        Label("Start over", systemImage: "arrow.counterclockwise").secondaryButton()
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(loading && details == nil && !vod.isDemo)
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
                                    Text("Season \(n)")
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
                    Text("Season \(s.seasons[0])").font(.cond(18, .semibold))
                }
                ForEach(s.episodes[season] ?? []) { e in episodeRow(e) }
            }
            .padding(.top, 6)
        } else if series != nil {
            Text("No episodes are available for this series.").font(.ui(14)).foregroundStyle(Theme.fg3)
        }
    }

    private func episodeRow(_ e: Episode) -> some View {
        let r = vod.resumes[e.resumeKey]
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
                    Text("\(e.number). \(e.title)").font(.cond(14.5, .semibold)).lineLimit(2).multilineTextAlignment(.leading)
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
        if let last = vod.lastEpisode(of: item.id), let e = all.first(where: { $0.resumeKey == last.key }) {
            return (episode: e, from: last.point.pos)
        }
        if let f = all.first { return (episode: f, from: 0) }
        return nil
    }

    private func load() async {
        loading = true
        if item.kind == .movies {
            details = await vod.movieDetails(item)
        } else {
            do {
                let s = try await vod.seriesDetails(item)
                series = s
                if let last = vod.lastEpisode(of: item.id),
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
        guard let url = vod.movieURL(item, ext: details?.ext) else { return }
        let key = item.resumeKey, title = item.name
        let store = vod, app = model     // keep the objects themselves; the closures outlive this view
        VodPlayback.present(url: url, title: title, subtitle: metaLine(details ?? VodDetails()), start: start, ext: details?.ext.nonEmpty ?? item.ext) { pos, dur in
            store.saveResume(key, pos: pos, dur: dur, title: title, series: nil)
        } onError: { message in
            app.showToast(message, seconds: 5)
        }
    }

    private func play(_ e: Episode, from start: Double) {
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
                        onSave: @escaping (Double, Double) -> Void, onError: @escaping (String) -> Void) {
        guard let top = topController() else { return }
        let vc = VodPlayerController()
        vc.modalPresentationStyle = .fullScreen
        vc.onSave = onSave
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
