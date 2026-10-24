import SwiftUI
import AVKit

@MainActor
struct FullScreenPlayer: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlayerController
    @StateObject private var pip = PiPController()
    @State private var showControls = true
    @State private var showChannels = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(player: player.player, onLayer: { layer in pip.attach(layer) })
                .ignoresSafeArea()
            PlaybackOverlay(compact: false)
            if showControls && !showChannels {
                controls.transition(.opacity)
                if player.state == .playing || player.isPaused {
                    transport.transition(.opacity)
                }
            }
            if showChannels {
                HStack {
                    ChannelPanel(onClose: { showChannels = false; poke() }, onPick: { poke() })
                        .frame(maxWidth: 380)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Spacer(minLength: 0)
                }
                .padding(12)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if showChannels { showChannels = false; poke() } else { toggleControls() }
        }
        .gesture(
            DragGesture(minimumDistance: 40).onEnded { value in
                let dy = value.translation.height, dx = value.translation.width
                if abs(dy) > abs(dx) * 1.5 {
                    model.stepChannel(dy < 0 ? 1 : -1)
                    poke()
                } else if dx > 80 && abs(dx) > abs(dy) * 1.5 {
                    showChannels = true      // swipe right: channel list
                } else if dx < -80 && showChannels {
                    showChannels = false
                }
            }
        )
        .statusBarHidden(!showControls)
        .persistentSystemOverlays(showControls ? .automatic : .hidden)
        .animation(.easeOut(duration: 0.2), value: showControls)
        .animation(.easeOut(duration: 0.22), value: showChannels)
        .onAppear { poke() }
        .onDisappear { hideTask?.cancel() }
    }

    /// Rewind, pause and fast-forward in the middle of the picture.
    private var transport: some View {
        HStack(spacing: 34) {
            Button { model.seekLive(-30); poke() } label: {
                Image(systemName: "gobackward.30").font(.system(size: 24, weight: .semibold)).frame(width: 58, height: 58)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
            .accessibilityLabel("Rewind")
            Button { model.togglePause(); poke() } label: {
                Image(systemName: player.isPaused ? "play.fill" : "pause.fill").font(.system(size: 30, weight: .bold)).frame(width: 76, height: 76)
                    .background(Circle().fill(Color.black.opacity(0.5)))
            }
            .accessibilityLabel(player.isPaused ? "Play" : "Pause")
            Button { model.seekLive(30); poke() } label: {
                Image(systemName: "goforward.30").font(.system(size: 24, weight: .semibold)).frame(width: 58, height: 58)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
            .accessibilityLabel("Fast-forward")
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
    }

    /// "Paused · 2:10 behind" or "2:10 behind live", with a button back to live; position for catch-up.
    private var liveLine: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let behind = model.behindLiveText()
            let paused = player.isPaused
            let info = player.timeInfo
            HStack(spacing: 10) {
                if model.catchup != nil && model.timeshift == nil && info.duration > 0 {
                    Text("\(paused ? "Paused · " : "")\(Fmt.clock(info.position)) / \(Fmt.clock(info.duration))")
                        .font(.ui(14, .medium)).foregroundStyle(Theme.fg2).monospacedDigit()
                } else if paused || !behind.isEmpty {
                    Text(paused ? "Paused" + (behind.isEmpty ? "" : " · " + behind) : behind + " live")
                        .font(.ui(14, .medium)).foregroundStyle(Theme.warn).monospacedDigit()
                    if !behind.isEmpty {
                        Button { model.goLive(); poke() } label: {
                            HStack(spacing: 6) {
                                Circle().fill(Theme.live).frame(width: 7, height: 7)
                                Text("Go live").font(.ui(13, .semibold))
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(Capsule().fill(Color.white.opacity(0.14)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var controls: some View {
        let ch = model.playingChannel
        var program: Program? = model.catchup ?? ch.flatMap { model.program(for: $0, at: model.now) }
        if let ch, let ts = model.timeshift {
            program = model.program(for: ch, at: ts.addingTimeInterval(player.timeInfo.position)) ?? program
        }
        let favorite = ch.map { model.favorites.contains($0.id) } ?? false
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { model.isFullScreen = false } label: {
                    Label("Guide", systemImage: "chevron.left").osdButton()
                }
                Spacer()
                if model.timeshift != nil {
                    Badge(text: "REWOUND", style: .new, icon: "gobackward")
                } else if model.catchup != nil {
                    Badge(text: "CATCH-UP", style: .new, icon: "gobackward")
                }
                AirPlayButton().frame(width: 44, height: 44)
                if pip.isSupported {
                    Button { pip.toggle() } label: {
                        Image(systemName: pip.isActive ? "pip.exit" : "pip.enter").osdIcon()
                    }
                    .accessibilityLabel("Picture in Picture")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 30)
            .background(LinearGradient(colors: [Color.black.opacity(0.7), Color.black.opacity(0)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 10) {
                if let ch {
                    HStack(spacing: 12) {
                        LogoBadge(channel: ch, size: 34)
                        Text("\(ch.num)").foregroundStyle(Theme.accent).monospacedDigit()
                        Text(ch.name).lineLimit(1)
                        Spacer()
                        Text(Fmt.time(model.now, model.clock24)).font(.cond(22, .semibold)).monospacedDigit()
                    }
                    .font(.cond(17, .semibold))
                }
                Text(program?.title ?? "No program information")
                    .font(.cond(28, .semibold))
                    .lineLimit(2)
                if let p = program {
                    Text("\(Fmt.time(p.start, model.clock24)) – \(Fmt.time(p.end, model.clock24))")
                        .font(.ui(14))
                        .foregroundStyle(Theme.fg2)
                        .monospacedDigit()
                }
                if let p = program, model.catchup == nil, p.isNow(model.now) {
                    ProgressBar(value: model.progress(p))
                }
                liveLine
                if let ch, let p = program, model.catchup == nil, let n = model.next(after: p, on: ch) {
                    Text("Next  \(Fmt.time(n.start, model.clock24))  \(n.title)")
                        .font(.ui(14))
                        .foregroundStyle(Theme.fg2)
                        .lineLimit(1)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button { model.stepChannel(-1); poke() } label: {
                            Image(systemName: "chevron.up").osdIcon()
                        }
                        .accessibilityLabel("Previous channel")
                        Button { model.stepChannel(1); poke() } label: {
                            Image(systemName: "chevron.down").osdIcon()
                        }
                        .accessibilityLabel("Next channel")
                        Button { showChannels = true } label: {
                            Label("Channels", systemImage: "list.bullet").osdButton()
                        }
                        if let ch {
                            Button { model.toggleFavorite(ch); poke() } label: {
                                Label(favorite ? "Favorite" : "Add favorite", systemImage: favorite ? "star.fill" : "star").osdButton()
                            }
                        }
                        Button { player.isMuted.toggle(); poke() } label: {
                            Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill").osdIcon()
                        }
                        .accessibilityLabel(player.isMuted ? "Turn sound on" : "Mute")
                        if let ch {
                            optionsMenu(ch, program)
                        }
                    }
                }
                .padding(.top, 4)
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.panel.opacity(0.94)))
            .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .foregroundStyle(Theme.fg)
        .buttonStyle(.plain)
    }

    /// Channel options: favorite, pause, back to live, details, audio track, reload, hide.
    private func optionsMenu(_ ch: Channel, _ program: Program?) -> some View {
        let favorite = model.favorites.contains(ch.id)
        return Menu {
            Button { model.toggleFavorite(ch) } label: {
                Label(favorite ? "Remove from favorites" : "Add to favorites", systemImage: favorite ? "star.slash" : "star")
            }
            if let p = program, model.catchup == nil {
                Button { model.detailsFromFullScreen(ch, p) } label: {
                    Label("Program details", systemImage: "info.circle")
                }
            }
            Button { model.togglePause() } label: {
                Label(player.isPaused ? "Resume" : "Pause", systemImage: player.isPaused ? "play.fill" : "pause.fill")
            }
            if model.timeshift != nil || !model.behindLiveText().isEmpty {
                Button { model.goLive() } label: {
                    Label("Back to live", systemImage: "dot.radiowaves.left.and.right")
                }
            }
            if player.audioOptions.count > 1 {
                Menu {
                    ForEach(Array(player.audioOptions.enumerated()), id: \.offset) { item in
                        Button { player.selectAudio(item.offset) } label: {
                            if item.offset == player.audioIndex {
                                Label(item.element, systemImage: "checkmark")
                            } else {
                                Text(item.element)
                            }
                        }
                    }
                } label: {
                    Label("Audio track", systemImage: "speaker.wave.2")
                }
            }
            Button { player.retry() } label: {
                Label("Reload channel", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) { model.setHidden(ch, true, announce: true) } label: {
                Label("Hide channel", systemImage: "eye.slash")
            }
        } label: {
            Image(systemName: "ellipsis").osdIcon()
        }
        .accessibilityLabel("Channel options")
    }

    private func poke() {
        showControls = true
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled && !showChannels && !player.isPaused { showControls = false }   // stay up while paused
        }
    }

    private func toggleControls() {
        if showControls {
            hideTask?.cancel()
            showControls = false
        } else {
            poke()
        }
    }
}

/// Channel list over full-screen video: tap a channel to switch, like the TV app's list.
@MainActor
struct ChannelPanel: View {
    @EnvironmentObject var model: AppModel
    let onClose: () -> Void
    let onPick: () -> Void

    var body: some View {
        let base = model.list.isEmpty ? model.channels : model.list
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.groupLabel(model.groupId)).font(.cond(18, .semibold))
                Spacer()
                Text(Fmt.time(model.now, model.clock24)).font(.cond(15, .medium)).foregroundStyle(Theme.fg2).monospacedDigit()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).frame(width: 34, height: 34)
                        .background(Circle().fill(Theme.cell))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close channel list")
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(base) { ch in row(ch).id(ch.id) }
                    }
                }
                .onAppear {
                    if let id = model.playingId { proxy.scrollTo(id, anchor: .center) }
                    if model.provider?.kind == .xtream {
                        let i = base.firstIndex(where: { $0.id == model.playingId }) ?? 0
                        let lo = max(0, i - 12), hi = min(base.count, i + 13)
                        if lo < hi { model.requestEPG(base[lo..<hi].map { $0.id }) }
                    }
                }
            }
        }
        .foregroundStyle(Theme.fg)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.menu.opacity(0.96)))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    private func row(_ ch: Channel) -> some View {
        let playing = ch.id == model.playingId
        let p = model.program(for: ch, at: model.now)
        return Button {
            model.playFromList(ch)
            onPick()
        } label: {
            HStack(spacing: 12) {
                Text("\(ch.num)").font(.cond(13, .semibold)).monospacedDigit().frame(width: 36, alignment: .trailing)
                    .foregroundStyle(playing ? Theme.hlInk : Theme.fg3)
                LogoBadge(channel: ch, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ch.name).font(.cond(15, .medium)).lineLimit(1)
                    Text(p?.title ?? (model.isLoadingGuide(ch) ? "Loading guide…" : "No program information"))
                        .font(.ui(12.5)).opacity(0.7).lineLimit(1)
                    if let p, p.isNow(model.now) {
                        ProgressBar(value: model.progress(p)).frame(height: 4)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .foregroundStyle(playing ? Theme.hlInk : Theme.fg)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(playing ? Theme.hl : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension View {
    func osdButton() -> some View {
        self
            .font(.ui(14.5, .semibold))
            .padding(.horizontal, 15)
            .frame(height: 42)
            .background(Capsule().fill(Color.white.opacity(0.12)))
    }

    func osdIcon() -> some View {
        self
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 44, height: 42)
            .background(Capsule().fill(Color.white.opacity(0.12)))
    }
}
