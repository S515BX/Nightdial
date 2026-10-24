import SwiftUI

@MainActor
struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlayerController

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            MainView()
                .blur(radius: model.showLogin ? 8 : 0)
                .allowsHitTesting(!model.showLogin)
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
        .sheet(item: $model.sheet) { sheet in
            SheetHost(sheet: sheet)
                .environmentObject(model)
                .environmentObject(player)
        }
        .preferredColorScheme(.dark)
    }
}

@MainActor
struct MainView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GeometryReader { geo in
            if geo.size.width >= 700 {
                let heroH = min(max(geo.size.height * 0.34, 170), 360)
                HStack(spacing: 14) {
                    NavRail(vertical: true).frame(width: 76)
                    VStack(spacing: 14) {
                        HStack(alignment: .top, spacing: 22) {
                            PreviewPlayer().frame(width: heroH * 16 / 9, height: heroH)
                            InfoPanel(compact: false)
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
                    NavRail(vertical: false)
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
    @EnvironmentObject var model: AppModel
    let vertical: Bool

    var body: some View {
        if vertical {
            VStack(spacing: 6) {
                BrandMark(size: 38).padding(.bottom, 12)
                mainButtons
                Spacer()
                extraButtons
            }
            .padding(.vertical, 4)
        } else {
            HStack(spacing: 0) {
                mainButtons
                extraButtons
            }
        }
    }

    @ViewBuilder private var mainButtons: some View {
        item("Guide", "rectangle.grid.1x2", active: model.groupId != "fav") { model.showGuide() }
        item("Groups", "line.3.horizontal", active: false) { model.sheet = .groups }
        item("Favorites", "star", active: model.groupId == "fav") { model.toggleFavoritesGroup() }
        item("Search", "magnifyingglass", active: false) { model.sheet = .search }
    }

    @ViewBuilder private var extraButtons: some View {
        item("Playlists", "list.bullet.rectangle", active: false) { model.sheet = .playlists }
        item("Settings", "slider.horizontal.3", active: false) { model.sheet = .settings }
    }

    private func item(_ title: String, _ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 19, weight: .medium))
                Text(title.uppercased())
                    .font(.cond(10, .semibold))
                    .tracking(0.4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(active ? Theme.accent : Theme.fg3)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(active ? Theme.panel : Color.clear))
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
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line, lineWidth: 1))
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
                    Text(message.title).font(.cond(compact ? 17 : 24, .semibold)).foregroundStyle(Theme.fg)
                    Text(message.detail)
                        .font(.system(size: compact ? 13 : 15))
                        .foregroundStyle(Theme.fg2)
                        .multilineTextAlignment(.center)
                    Button("Try again") { player.retry() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.cellHover)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.82))
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
                    Text("\(ch.num)").font(.cond(15, .semibold)).foregroundStyle(Theme.fg3).monospacedDigit()
                    Text(ch.name).font(.cond(15, .semibold)).foregroundStyle(Theme.fg2).lineLimit(1)
                    Spacer(minLength: 8)
                    if !compact {
                        Text(Fmt.time(model.now, model.clock24)).font(.cond(24, .semibold)).foregroundStyle(Theme.fg).monospacedDigit()
                    }
                }
                Text(program?.title ?? ch.name)
                    .font(.cond(compact ? 22 : 36, .semibold))
                    .foregroundStyle(Theme.fg)
                    .lineLimit(compact ? 1 : 2)
                MetaLine(channel: ch, program: program)
                if let p = program, p.isNow(model.now) {
                    ProgressBar(value: model.progress(p)).frame(maxWidth: 540)
                }
                if !compact {
                    if let d = program?.desc, !d.isEmpty {
                        Text(d).font(.system(size: 15)).foregroundStyle(Theme.fg2).lineLimit(3)
                    }
                    if let p = program, let n = model.next(after: p, on: ch) {
                        Text("Next · \(Fmt.time(n.start, model.clock24))  \(n.title)")
                            .font(.system(size: 14)).foregroundStyle(Theme.fg3).lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
        .font(.system(size: 14))
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
            Text(text).font(.cond(11, .bold)).tracking(0.6)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .foregroundStyle(foreground)
        .background(RoundedRectangle(cornerRadius: 4).fill(style == .live ? Theme.live : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(border, lineWidth: 1))
    }

    private var foreground: Color {
        switch style {
        case .live: return .white
        case .new: return Theme.accent
        case .plain: return Theme.fg2
        }
    }

    private var border: Color {
        switch style {
        case .live: return Theme.live
        case .new: return Theme.accent
        case .plain: return Theme.line
        }
    }
}

struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                Capsule().fill(Theme.accent).frame(width: g.size.width * CGFloat(max(0, min(1, value))))
            }
        }
        .frame(height: 4)
    }
}

struct LogoBadge: View {
    let channel: Channel
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            Color(uiColor: Palette.logo(channel.hue))
            Text(channel.initials).font(.cond(size * 0.42, .bold)).foregroundStyle(Color.white)
            if let url = channel.logo {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit().padding(2).background(Color(uiColor: Palette.logoBack))
                } placeholder: {
                    Color.clear
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct BrandMark: View {
    var size: CGFloat = 38

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                .fill(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: size * 0.29, style: .continuous).stroke(Theme.line, lineWidth: 1))
                .overlay(Text("T").font(.cond(size * 0.5, .bold)).foregroundStyle(Theme.fg))
            Circle()
                .fill(Theme.accent)
                .frame(width: size * 0.18, height: size * 0.18)
                .shadow(color: Theme.accent, radius: 4)
                .padding(size * 0.16)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Theme.fg)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Capsule().fill(Color(uiColor: UIColor(hex: 0x1F2D3B))))
            .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
            .padding(.horizontal, 24)
    }
}

extension View {
    func inputBox(focused: Bool) -> some View {
        self
            .font(.system(size: 16))
            .foregroundStyle(Theme.fg)
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.bg))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(focused ? Theme.accent : Theme.line, lineWidth: 1))
    }

    func primaryButton() -> some View {
        self
            .font(.cond(17, .semibold))
            .foregroundStyle(Theme.accentInk)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent))
    }

    func secondaryButton() -> some View {
        self
            .font(.cond(17, .semibold))
            .foregroundStyle(Theme.fg)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cell))
    }

    @ViewBuilder func buttonLook(primary: Bool) -> some View {
        if primary { primaryButton() } else { secondaryButton() }
    }
}
