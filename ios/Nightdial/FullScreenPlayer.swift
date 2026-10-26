import SwiftUI
import AVKit

@MainActor
struct FullScreenPlayer: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlayerController
    @StateObject private var pip = PiPController()
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showControls = true
    @State private var showChannels = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(player: player.player, aspect: player.aspect, onLayer: { layer in pip.attach(layer) })
                .ignoresSafeArea()
            PlaybackOverlay(compact: false)
            if showControls && !showChannels {
                controls.transition(.opacity)
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

    /// Rewind, pause and fast-forward: small buttons next to the timeline.
    private func transportButton(_ icon: String, label: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button { action(); poke() } label: {
            Image(systemName: icon)
                .font(.system(size: prominent ? 15 : 13, weight: .bold))
                .foregroundStyle(prominent ? Color.black : Theme.fg)
                .frame(width: prominent ? 38 : 34, height: prominent ? 38 : 34)
                .background(Circle().fill(prominent ? Theme.accent : Color.white.opacity(0.12)))
        }
        .accessibilityLabel(label)
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
                        .font(.ui(12, .medium)).foregroundStyle(Theme.fg2).monospacedDigit()
                } else if paused || !behind.isEmpty {
                    Text(paused ? "Paused" + (behind.isEmpty ? "" : " · " + behind) : behind + " live")
                        .lineLimit(1)
                        .font(.ui(12, .medium)).foregroundStyle(Theme.warn).monospacedDigit()
                    if !behind.isEmpty {
                        Button { model.goLive(); poke() } label: {
                            HStack(spacing: 6) {
                                Circle().fill(Theme.live).frame(width: 7, height: 7)
                                Text("Go live").font(.ui(12, .semibold))
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 26)
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
                AirPlayButton().frame(width: 34, height: 34)
                if pip.isSupported {
                    Button { pip.toggle() } label: {
                        Image(systemName: pip.isActive ? "pip.exit" : "pip.enter").osdIcon()
                    }
                    .accessibilityLabel("Picture in Picture")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 18)
            .background(LinearGradient(colors: [Color.black.opacity(0.6), Color.black.opacity(0)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())

            Spacer(minLength: 0)

            // A slim bar: channel and program on one line, the transport next to the timeline, small buttons below.
            VStack(alignment: .leading, spacing: 6) {
                if let ch {
                    HStack(spacing: 8) {
                        LogoBadge(channel: ch, size: 24)
                        Text("\(ch.num)").foregroundStyle(Theme.accent).monospacedDigit()
                        Text(ch.name).foregroundStyle(Theme.fg2).lineLimit(1).layoutPriority(-1)
                        Text("·").foregroundStyle(Theme.fg3)
                        Text(program?.title ?? "No program information").foregroundStyle(Theme.fg).lineLimit(1).layoutPriority(1)
                        Spacer(minLength: 6)
                        if let p = program {
                            Text("\(Fmt.time(p.start, model.clock24)) – \(Fmt.time(p.end, model.clock24))")
                                .font(.ui(11.5)).foregroundStyle(Theme.fg3).monospacedDigit().lineLimit(1)
                        }
                        Text(Fmt.time(model.now, model.clock24)).font(.cond(14, .semibold)).monospacedDigit()
                    }
                    .font(.cond(14, .semibold))
                }
                HStack(alignment: .center, spacing: 8) {
                    if player.state == .playing || player.isPaused {
                        transportButton("gobackward.30", label: "Rewind 30 seconds") { model.seekLive(-30) }
                        transportButton(player.isPaused ? "play.fill" : "pause.fill", label: player.isPaused ? "Play" : "Pause", prominent: true) { model.togglePause() }
                        transportButton("goforward.30", label: "Forward 30 seconds") { model.seekLive(30) }
                    }
                    ScrubBar(onActivity: { poke() })
                        .padding(.leading, 4)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(player.streamBadges.enumerated()), id: \.offset) { i, b in
                            let hi = i == 0 && (b == "4K" || b == "1080p")
                            Text(b)
                                .font(.ui(10.5, .semibold))
                                .foregroundStyle(hi ? Color.black : Theme.fg)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(hi ? Theme.accent : Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                        liveLine
                        Spacer(minLength: 8)
                        Button { model.stepChannel(-1); poke() } label: {
                            Image(systemName: "chevron.up").osdIcon()
                        }
                        .accessibilityLabel("Previous channel")
                        Button { model.stepChannel(1); poke() } label: {
                            Image(systemName: "chevron.down").osdIcon()
                        }
                        .accessibilityLabel("Next channel")
                        Button { showChannels = true } label: {
                            Image(systemName: "list.bullet").osdIcon()
                        }
                        .accessibilityLabel("Channel list")
                        if let ch {
                            Button { model.toggleFavorite(ch); poke() } label: {
                                Image(systemName: favorite ? "star.fill" : "star").osdIcon()
                            }
                            .accessibilityLabel(favorite ? "Remove favorite" : "Add favorite")
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
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.panel.opacity(0.9)))
            .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
            .frame(maxWidth: 820)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
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
            Menu {
                ForEach(PlayerController.aspects.indices, id: \.self) { i in
                    let a = PlayerController.aspects[i]
                    Button { player.aspect = a.0 } label: {
                        if a.0 == player.aspect { Label(a.1, systemImage: "checkmark") } else { Text(a.1) }
                    }
                }
            } label: {
                Label("Picture shape · \(PlayerController.aspectName(player.aspect))", systemImage: "aspectratio")
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
                Text("\(ch.num)").font(.cond(13, .semibold)).monospacedDigit().lineLimit(1).frame(width: CGFloat(max(2, model.numberDigits)) * 8.5 + 4, alignment: .trailing)
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
            .font(.ui(13, .semibold))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Capsule().fill(Color.white.opacity(0.12)))
    }

    func osdIcon() -> some View {
        self
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 34, height: 32)
            .background(Capsule().fill(Color.white.opacity(0.12)))
    }
}

/// Timeline under the program title: drag to scrub through the program (catch-up channels can go back through it;
/// other channels within what the stream keeps). Shows plain progress when the channel can't be rewound.
@MainActor
struct ScrubBar: View {
    @EnvironmentObject var model: AppModel
    let onActivity: () -> Void
    @State private var dragging = false
    @State private var value: Double = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            if let tl = model.liveTimeline() {
                let ws = tl.programStart.timeIntervalSince1970
                let we = max(tl.programEnd.timeIntervalSince1970, ws + 60)
                let lo = max(ws, tl.min.timeIntervalSince1970), hi = min(we, tl.max.timeIntervalSince1970)
                let pos = tl.pos.timeIntervalSince1970
                VStack(spacing: 4) {
                    if tl.canScrub && hi > lo + 5 {
                        Slider(value: Binding(get: { dragging ? value : min(max(pos, lo), hi) }, set: { value = $0 }), in: lo...hi, onEditingChanged: { editing in
                            if editing {
                                dragging = true
                                value = min(max(pos, lo), hi)
                            } else {
                                dragging = false
                                model.seekLive(to: Date(timeIntervalSince1970: value))
                            }
                            onActivity()
                        })
                        .tint(Theme.accent)
                        .accessibilityLabel("Timeline")
                    } else {
                        ProgressBar(value: max(0, min(1, (pos - ws) / (we - ws))))
                    }
                    HStack {
                        Text(Fmt.time(tl.programStart, model.clock24))
                        Spacer()
                        if dragging {
                            Text(headLabel(value, tl)).font(.ui(13, .semibold)).foregroundStyle(Theme.fg)
                        }
                        Spacer()
                        Text(Fmt.time(tl.programEnd, model.clock24))
                    }
                    .font(.ui(12))
                    .foregroundStyle(Theme.fg3)
                    .monospacedDigit()
                }
            }
        }
    }

    private func headLabel(_ t: Double, _ tl: AppModel.LiveTimeline) -> String {
        if tl.catchupProgram { return Fmt.clock(t - tl.programStart.timeIntervalSince1970) }
        let behind = Date().timeIntervalSince1970 - t
        return Fmt.time(Date(timeIntervalSince1970: t), model.clock24) + (behind >= 15 ? "  −" + Fmt.clock(behind) : "  live")
    }
}
