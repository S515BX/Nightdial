import SwiftUI

@MainActor
struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlayerController
    @ObservedObject private var look = Look.shared

    var body: some View {
        ZStack {
            RoomBackground()
            MainView()
                .id(look.revision)   // rebuild with the new colors, font and size when the look changes
                .blur(radius: model.showLogin ? 8 : 0)
                .allowsHitTesting(!model.showLogin)
            if look.decorations, let kind = look.theme.deco {
                DecorationLayer(kind: kind).id("deco-" + kind)
            }
            if model.showLogin {
                LoginView()
                    .transition(.opacity)
            }
            if let text = model.toast {
                VStack {
                    Spacer()
                    ToastView(text: text).padding(.bottom, 84)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.showLogin)
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .fullScreenCover(isPresented: $model.isFullScreen) {
            FullScreenPlayer()
                .environmentObject(model)
                .environmentObject(player)
        }
        .background(
            // A second cover needs its own host view.
            Color.clear.fullScreenCover(isPresented: $model.showOnDemand, onDismiss: { model.onDemandClosed() }) {
                OnDemandView()
                    .environmentObject(model)
                    .environmentObject(model.vod)
                    .preferredColorScheme(.dark)
                    .tint(Theme.accent)
            }
        )
        .sheet(item: $model.sheet) { sheet in
            SheetHost(sheet: sheet)
                .environmentObject(model)
                .environmentObject(player)
        }
        .preferredColorScheme(.dark)
    }
}

/// The room: theme background with two soft neon lights.
struct RoomBackground: View {
    @ObservedObject private var look = Look.shared

    var body: some View {
        ZStack {
            Theme.bg
            if look.glow {
                RadialGradient(colors: [Theme.glowA, .clear], center: .topLeading, startRadius: 0, endRadius: 560)
                RadialGradient(colors: [Theme.glowB, .clear], center: .bottomTrailing, startRadius: 0, endRadius: 600)
            }
        }
        .ignoresSafeArea()
    }
}

@MainActor
struct MainView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GeometryReader { geo in
            let sc = Look.shared.sizeScale
            if geo.size.width >= 700 {
                let wideRail = geo.size.width >= 1100
                let heroH = min(max(geo.size.height * 0.34, 170), 360) * sc
                HStack(spacing: 18) {
                    NavRail(style: wideRail ? .wide : .narrow).frame(width: wideRail ? 200 : 78)
                    VStack(spacing: 16) {
                        HStack(alignment: .top, spacing: 16) {
                            PreviewPlayer().frame(width: heroH * 16 / 9, height: heroH)
                            InfoPanel(compact: false).frame(height: heroH)
                            if geo.size.width >= 1180 {
                                UpNextCard().frame(width: 270, height: heroH)
                            }
                        }
                        .frame(height: heroH)
                        GuideHost()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            } else {
                let playerH = max(0, geo.size.width - 24) * 9 / 16
                VStack(spacing: 10) {
                    PreviewPlayer().frame(height: playerH)
                    InfoPanel(compact: true)
                    GuideHost()
                    NavRail(style: .bar)
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }
        }
    }
}

@MainActor
struct GuideHost: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GuideGrid(
            snapshot: model.guideSnapshot,
            onTapProgram: { index, program in model.tapProgram(index, program) },
            onTapChannel: { index in model.tapChannel(index) },
            onLongPressChannel: { index in model.toggleFavorite(at: index) },
            onVisibleChannels: { ids in model.requestEPG(ids) },
            onTapCorner: { model.sheet = .groups }
        )
    }
}

@MainActor
struct NavRail: View {
    enum Style { case wide, narrow, bar }
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var vod: OnDemandModel
    let style: Style

    var body: some View {
        switch style {
        case .wide, .narrow:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    BrandMark(size: 40)
                    if style == .wide { Text("Nightdial").font(.cond(20, .semibold)).foregroundStyle(Theme.fg) }
                }
                .frame(maxWidth: .infinity, alignment: style == .wide ? .leading : .center)
                .padding(.horizontal, style == .wide ? 8 : 0)
                .padding(.bottom, 18)
                mainButtons
                item("Edit channels", "list.star", active: false) { model.sheet = .channels }
                item("Themes", "paintpalette", active: false) { model.sheet = .themes }
                Spacer()
                extraButtons
            }
            .padding(.vertical, 8)
            .padding(.horizontal, Theme.railBack == .clear ? 0 : 8)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.railBack))
        case .bar:
            HStack(spacing: 2) {
                mainButtons
                item("Settings", "slider.horizontal.3", active: false) { model.sheet = .settings }
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.panel))
        }
    }

    @ViewBuilder private var mainButtons: some View {
        item("Guide", "rectangle.grid.1x2", active: model.groupId != "fav") { model.showGuide() }
        item("Groups", "line.3.horizontal", active: false) { model.sheet = .groups }
        item("Favorites", "star", active: model.groupId == "fav") { model.toggleFavoritesGroup() }
        item("Search", "magnifyingglass", active: false) { model.sheet = .search }
        if vod.available {
            item("Movies & Series", "film", active: false) { model.openOnDemand() }
        }
    }

    @ViewBuilder private var extraButtons: some View {
        item("Playlists", "list.bullet.rectangle", active: false) { model.sheet = .playlists }
        item("Settings", "slider.horizontal.3", active: false) { model.sheet = .settings }
    }

    @ViewBuilder
    private func item(_ title: String, _ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if style == .wide {
                    HStack(spacing: 12) {
                        Image(systemName: icon).font(.system(size: 17, weight: .medium)).frame(width: 22)
                        Text(title).font(.ui(14.5, .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: icon).font(.system(size: 18, weight: .medium))
                        Text(title == "Edit channels" ? "Channels" : title == "Movies & Series" ? "Movies" : title)
                            .font(.ui(10, .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            }
            .foregroundStyle(active ? Theme.hlInk : Theme.fg2)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(active ? Theme.hl : Color.clear))
            .shadow(color: .black.opacity(active ? 0.25 : 0), radius: 10, y: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

@MainActor
struct PreviewPlayer: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlayerController

    var body: some View {
        ZStack {
            Color.black
            VideoSurface(player: model.isFullScreen ? nil : player.player)
            PlaybackOverlay(compact: true)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
        .contentShape(Rectangle())
        .onTapGesture { model.openFullScreen() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Video preview")
        .accessibilityHint("Opens full screen")
        .accessibilityAddTraits(.isButton)
    }
}

/// Loading spinner, error message, or the drawn demo picture when a demo stream can't load.
@MainActor
struct PlaybackOverlay: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlayerController
    let compact: Bool

    var body: some View {
        switch player.state {
        case .loading:
            ProgressView()
                .tint(Theme.accent)
                .scaleEffect(compact ? 1 : 1.4)
        case .failed(let code):
            if model.provider?.kind == .demo, let ch = model.playingChannel {
                DemoScene(channel: ch, program: model.catchup ?? model.program(for: ch, at: model.now))
            } else {
                let message = PlaybackMessage.text(code)
                VStack(spacing: 8) {
                    Text(message.title).font(.cond(compact ? 16 : 22, .semibold)).foregroundStyle(Theme.fg)
                    Text(message.detail)
                        .font(.ui(compact ? 13 : 15))
                        .foregroundStyle(Theme.fg2)
                        .multilineTextAlignment(.center)
                    Button("Try again") { player.retry() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.cellHover)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.84))
            }
        case .idle, .playing:
            EmptyView()
        }
    }
}

@MainActor
struct InfoPanel: View {
    @EnvironmentObject var model: AppModel
    let compact: Bool

    var body: some View {
        let channel = model.focusedChannel ?? model.playingChannel
        let program: Program? = model.focusedChannel != nil
            ? model.focusedProgram
            : channel.flatMap { model.program(for: $0, at: model.now) }
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            if let ch = channel {
                HStack(spacing: 10) {
                    LogoBadge(channel: ch, size: compact ? 24 : 30)
                    Text("\(ch.num)").font(.cond(14, .medium)).foregroundStyle(Theme.fg3).monospacedDigit()
                    Text(ch.name).font(.cond(14, .medium)).foregroundStyle(Theme.fg2).lineLimit(1)
                    Spacer(minLength: 8)
                    if !compact {
                        Text(Fmt.time(model.now, model.clock24)).font(.cond(22, .semibold)).foregroundStyle(Theme.fg).monospacedDigit()
                    }
                }
                Text(program?.title ?? ch.name)
                    .font(.cond(compact ? 20 : 32, .semibold))
                    .foregroundStyle(Theme.fg)
                    .lineLimit(compact ? 1 : 2)
                MetaLine(channel: ch, program: program)
                if let p = program, p.isNow(model.now) {
                    ProgressBar(value: model.progress(p)).frame(maxWidth: 540)
                }
                if !compact {
                    if let d = program?.desc, !d.isEmpty {
                        Text(d).font(.ui(14)).foregroundStyle(Theme.fg2).lineLimit(3)
                    }
                    if let p = program, let n = model.next(after: p, on: ch) {
                        Text("Next · \(Fmt.time(n.start, model.clock24))  \(n.title)")
                            .font(.ui(13)).foregroundStyle(Theme.fg3).lineLimit(1)
                    }
                }
            }
            if channel == nil && model.provider == nil {
                Text("Welcome to Nightdial").font(.cond(compact ? 20 : 30, .semibold)).foregroundStyle(Theme.fg)
                Text("Add an Xtream Codes or M3U playlist to start watching.").font(.ui(14)).foregroundStyle(Theme.fg2)
                Button { model.addPlaylist() } label: {
                    Label("Add playlist", systemImage: "plus")
                        .font(.cond(15, .semibold))
                        .foregroundStyle(Theme.accentInk)
                        .padding(.horizontal, 18)
                        .frame(height: 40)
                        .background(Capsule().fill(Theme.accentGradient))
                }
                .buttonStyle(.plain)
            }
            if !compact { Spacer(minLength: 0) }
        }
        .padding(.horizontal, compact ? 14 : 22)
        .padding(.vertical, compact ? 12 : 18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: compact ? 18 : 22, style: .continuous).fill(Theme.panel))
    }
}

/// The one white card: what's on next on the selected channel (wide screens).
@MainActor
struct UpNextCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let ch = model.focusedChannel ?? model.playingChannel
        var items: [Program] = []
        if let ch, var p = model.focusedChannel != nil ? model.focusedProgram : model.program(for: ch, at: model.now) {
            items.append(p)
            while items.count < 4, let n = model.next(after: p, on: ch) { items.append(n); p = n }
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Up next").font(.cond(16, .semibold))
                Spacer()
                Text(ch?.name ?? "").font(.ui(12, .medium)).foregroundStyle(Theme.paper2).lineLimit(1)
            }
            if items.isEmpty {
                Text("No guide information for this channel.").font(.ui(13)).foregroundStyle(Theme.paper2)
            }
            ForEach(items, id: \.start) { p in
                let on = p.isNow(model.now)
                HStack(spacing: 12) {
                    Text(Fmt.time(p.start, model.clock24)).font(.cond(12.5, .semibold)).monospacedDigit().frame(minWidth: 52, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.title).font(.cond(13.5, .semibold)).lineLimit(1)
                        Text(on ? "\(Fmt.duration(p.end.timeIntervalSince(model.now))) left" : p.start > model.now ? "In \(Fmt.duration(p.start.timeIntervalSince(model.now)))" : Fmt.duration(p.end.timeIntervalSince(p.start)))
                            .font(.ui(11.5)).opacity(0.7).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .foregroundStyle(on ? Theme.accentInk : Theme.paperInk)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(on ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.paperInk.opacity(0.06))))
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.paperInk)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.paper))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

@MainActor
struct MetaLine: View {
    @EnvironmentObject var model: AppModel
    let channel: Channel
    let program: Program?

    var body: some View {
        HStack(spacing: 8) {
            if let p = program {
                Text("\(Fmt.time(p.start, model.clock24)) – \(Fmt.time(p.end, model.clock24))").monospacedDigit()
                Text(relative(p)).foregroundStyle(Theme.fg3)
                if !p.episode.isEmpty { Text(p.episode).foregroundStyle(Theme.fg3) }
                if p.live && p.isNow(model.now) { Badge(text: "LIVE", style: .live) }
                if p.isNew { Badge(text: "NEW", style: .new) }
                if !p.rating.isEmpty { Badge(text: p.rating) }
                if model.canCatchup(channel, p) { Badge(text: "CATCH-UP", icon: "gobackward") }
            } else {
                Text(model.isLoadingGuide(channel) ? "Loading guide…" : "No program information")
            }
        }
        .font(.ui(13.5))
        .foregroundStyle(Theme.fg2)
        .lineLimit(1)
    }

    private func relative(_ p: Program) -> String {
        let n = model.now
        if p.isNow(n) { return "\(Fmt.duration(p.end.timeIntervalSince(n))) left" }
        if p.start > n { return "in \(Fmt.duration(p.start.timeIntervalSince(n)))" }
        return Fmt.day(p.start, now: n)
    }
}

struct Badge: View {
    enum Style { case live, new, plain }
    let text: String
    var style: Style = .plain
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.cond(10.5, .semibold)).tracking(0.5)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(foreground)
        .background(Capsule().fill(fill))
    }

    private var foreground: Color {
        switch style {
        case .live: return .white
        case .new: return Theme.accent
        case .plain: return Theme.fg2
        }
    }

    private var fill: Color {
        switch style {
        case .live: return Theme.live
        case .new: return Theme.accentSoft
        case .plain: return Theme.cell
        }
    }
}

struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.cell)
                Capsule().fill(Theme.accentGradient)
                    .frame(width: g.size.width * CGFloat(max(0, min(1, value))))
                    .shadow(color: Theme.accent.opacity(0.45), radius: 6)
            }
        }
        .frame(height: 6)
    }
}

struct LogoBadge: View {
    let channel: Channel
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            Color(uiColor: Palette.logo(channel.hue))
            Text(channel.initials).font(.cond(size * 0.4, .bold)).foregroundStyle(Color.white)
            if let url = channel.logo {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit().padding(2).background(Color(uiColor: Palette.logoBack))
                } placeholder: {
                    Color.clear
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// The Nightdial logo, with a little holiday badge when a holiday theme is on.
struct BrandMark: View {
    var size: CGFloat = 38

    var body: some View {
        let t = Look.shared.theme
        ZStack(alignment: .topTrailing) {
            Image("Logo")
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
                .shadow(color: Theme.accent2.opacity(0.25), radius: 10, y: 4)
            if let g = t.glyph {
                Image(g)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color(uiColor: UIColor(hex: t.glyphColor ?? 0xFFFFFF)))
                    .frame(width: size * 0.5, height: size * 0.5)
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                    .offset(x: size * 0.2, y: -size * 0.22)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.ui(14, .medium))
            .foregroundStyle(Theme.paperInk)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Capsule().fill(Theme.paper))
            .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
            .padding(.horizontal, 24)
    }
}

/// Holiday decorations drifting over the guide: snow, bats, leaves, hearts, clovers, petals, fireworks.
struct DecorationLayer: View {
    let kind: String

    private struct Spec {
        let glyph: String
        let colors: [UInt32]
        let count: Int
        let size: ClosedRange<Double>
        let duration: ClosedRange<Double>
        let opacity: ClosedRange<Double>
        let mode: Int        // 0 fall, 1 rise, 2 fly, 3 twinkle
        var spin = false
    }

    private struct Particle {
        let x, y, size, duration, offset, opacity, spin: Double
        let color: Color
    }

    private var spec: Spec {
        switch kind {
        case "bats": return Spec(glyph: "deco-bat", colors: [0xB98CFF, 0xFF9A4D, 0x8A6BD1], count: 6, size: 24...42, duration: 15...26, opacity: 0.28...0.5, mode: 2)
        case "leaves": return Spec(glyph: "deco-leaf", colors: [0xF29E4C, 0xE0605E, 0xF2C94C, 0xC2410C], count: 10, size: 14...24, duration: 12...20, opacity: 0.35...0.6, mode: 0, spin: true)
        case "hearts": return Spec(glyph: "deco-heart", colors: [0xFF4D8D, 0xFF9EB5, 0xFF2E63], count: 10, size: 10...20, duration: 12...20, opacity: 0.25...0.5, mode: 1)
        case "clover": return Spec(glyph: "deco-clover", colors: [0x3DDC84, 0x2FBF6C, 0x8BE15B], count: 10, size: 12...20, duration: 12...20, opacity: 0.3...0.55, mode: 0, spin: true)
        case "petals": return Spec(glyph: "deco-flower", colors: [0xFFB3D1, 0xB8A1FF, 0x7EE8C8, 0xFFF1A8], count: 10, size: 12...20, duration: 12...20, opacity: 0.3...0.55, mode: 0, spin: true)
        case "fireworks": return Spec(glyph: "deco-spark", colors: [0xFF4D5E, 0xFFFFFF, 0x5B8CFF], count: 9, size: 16...34, duration: 3.5...6, opacity: 0.5...0.85, mode: 3)
        case "sparkle": return Spec(glyph: "deco-spark", colors: [0xF5D06F, 0xFFFFFF, 0xE2E4FF], count: 10, size: 10...26, duration: 3...6, opacity: 0.45...0.85, mode: 3)
        default: return Spec(glyph: "deco-snow", colors: [0xFFFFFF, 0xDCEFFF], count: 14, size: 10...22, duration: 11...20, opacity: 0.35...0.8, mode: 0)
        }
    }

    private var particles: [Particle] {
        var seed: UInt64 = 0x9E3779B97F4A7C15 &+ UInt64(kind.count)
        func rnd() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let s = spec
        return (0..<s.count).map { k in
            let sz = s.size.lowerBound + rnd() * (s.size.upperBound - s.size.lowerBound)
            let d = s.duration.lowerBound + rnd() * (s.duration.upperBound - s.duration.lowerBound)
            return Particle(x: (Double(k) + rnd() * 0.9) / Double(s.count), y: 0.04 + rnd() * 0.56, size: sz, duration: d, offset: rnd(),
                            opacity: (s.opacity.lowerBound + rnd() * (s.opacity.upperBound - s.opacity.lowerBound)) * 0.8,
                            spin: s.spin ? rnd() * 540 - 270 : 0,
                            color: Color(uiColor: UIColor(hex: s.colors[k % s.colors.count])))
        }
    }

    var body: some View {
        let s = spec
        let ps = particles
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let W = Double(size.width), H = Double(size.height)
                var image = ctx.resolve(Image(s.glyph).renderingMode(.template))
                for (k, p) in ps.enumerated() {
                    let phase = (t / p.duration + p.offset).truncatingRemainder(dividingBy: 1)
                    var x = p.x * W, y = 0.0, opacity = p.opacity, scale = 1.0, angle = 0.0
                    switch s.mode {
                    case 1:
                        y = H * 1.1 - phase * H * 1.25
                        x += sin(t * 1.1 + Double(k)) * 14
                    case 2:
                        x = -0.12 * W + phase * W * 1.25
                        y = p.y * H - phase * H * 0.08 + sin(t * 2 + Double(k)) * 6
                    case 3:
                        y = p.y * H * 0.7
                        if phase < 0.35 { scale = 0.2 + 0.8 * phase / 0.35; opacity = p.opacity * phase / 0.35 }
                        else if phase < 0.7 { scale = 1 + 0.15 * (phase - 0.35) / 0.35; opacity = p.opacity * (1 - (phase - 0.35) / 0.35) }
                        else { opacity = 0 }
                    default:
                        y = -0.1 * H + phase * H * 1.25
                        x += sin(t * 1.3 + Double(k)) * 14
                        angle = sin(t * 1.3 + Double(k)) * 14 + p.spin * phase
                    }
                    guard opacity > 0.01 else { continue }
                    image.shading = .color(p.color)
                    var c = ctx
                    c.opacity = opacity
                    c.translateBy(x: CGFloat(x), y: CGFloat(y))
                    c.rotate(by: .degrees(angle))
                    let flap = s.mode == 2 ? 0.7 + 0.3 * abs(sin(t * 9 + Double(k))) : 1
                    c.scaleBy(x: CGFloat(scale), y: CGFloat(scale * flap))
                    c.draw(image, in: CGRect(x: CGFloat(-p.size / 2), y: CGFloat(-p.size / 2), width: CGFloat(p.size), height: CGFloat(p.size)))
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

extension View {
    func inputBox(focused: Bool) -> some View {
        self
            .font(.ui(16))
            .foregroundStyle(Theme.fg)
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.bg))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(focused ? Theme.accent : Theme.line, lineWidth: focused ? 2 : 1))
    }

    func primaryButton() -> some View {
        self
            .font(.cond(16, .semibold))
            .foregroundStyle(Theme.accentInk)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .topLeading, endPoint: .bottomTrailing)))
            .shadow(color: Theme.accent.opacity(0.25), radius: 12, y: 6)
    }

    func secondaryButton() -> some View {
        self
            .font(.cond(16, .semibold))
            .foregroundStyle(Theme.fg)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.cell))
    }

    @ViewBuilder func buttonLook(primary: Bool) -> some View {
        if primary { primaryButton() } else { secondaryButton() }
    }
}
