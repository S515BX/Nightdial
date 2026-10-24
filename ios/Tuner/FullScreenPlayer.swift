import SwiftUI
import AVKit

@MainActor
struct FullScreenPlayer: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlayerController
    @StateObject private var pip = PiPController()
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(player: player.player, onLayer: { layer in pip.attach(layer) })
                .ignoresSafeArea()
            PlaybackOverlay(compact: false)
            if showControls {
                controls.transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleControls() }
        .gesture(
            DragGesture(minimumDistance: 40).onEnded { value in
                let dy = value.translation.height, dx = value.translation.width
                if abs(dy) > abs(dx) * 1.5 {
                    model.stepChannel(dy < 0 ? 1 : -1)
                    poke()
                }
            }
        )
        .statusBarHidden(!showControls)
        .persistentSystemOverlays(showControls ? .automatic : .hidden)
        .animation(.easeOut(duration: 0.2), value: showControls)
        .onAppear { poke() }
        .onDisappear { hideTask?.cancel() }
    }

    private var controls: some View {
        let ch = model.playingChannel
        let program: Program? = model.catchup ?? ch.flatMap { model.program(for: $0, at: model.now) }
        let favorite = ch.map { model.favorites.contains($0.id) } ?? false
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { model.isFullScreen = false } label: {
                    Label("Guide", systemImage: "chevron.left").osdButton()
                }
                Spacer()
                if model.catchup != nil {
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
            .background(LinearGradient(colors: [Color.black.opacity(0.75), Color.black.opacity(0)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 10) {
                if let ch {
                    HStack(spacing: 12) {
                        LogoBadge(channel: ch, size: 34)
                        Text("\(ch.num)").foregroundStyle(Theme.accent).monospacedDigit()
                        Text(ch.name).lineLimit(1)
                        Spacer()
                        Text(Fmt.time(model.now, model.clock24)).font(.cond(24, .semibold)).monospacedDigit()
                    }
                    .font(.cond(19, .semibold))
                }
                Text(program?.title ?? "No program information")
                    .font(.cond(32, .semibold))
                    .lineLimit(2)
                if let p = program {
                    Text("\(Fmt.time(p.start, model.clock24)) – \(Fmt.time(p.end, model.clock24))")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.fg2)
                        .monospacedDigit()
                }
                if let p = program, model.catchup == nil, p.isNow(model.now) {
                    ProgressBar(value: model.progress(p))
                }
                if let ch, let p = program, model.catchup == nil, let n = model.next(after: p, on: ch) {
                    Text("Next  \(Fmt.time(n.start, model.clock24))  \(n.title)")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.fg2)
                        .lineLimit(1)
                }
                HStack(spacing: 10) {
                    Button { model.stepChannel(-1); poke() } label: {
                        Label("Channel", systemImage: "chevron.up").osdButton()
                    }
                    .accessibilityLabel("Previous channel")
                    Button { model.stepChannel(1); poke() } label: {
                        Label("Channel", systemImage: "chevron.down").osdButton()
                    }
                    .accessibilityLabel("Next channel")
                    if let ch {
                        Button { model.toggleFavorite(ch); poke() } label: {
                            Label(favorite ? "Favorite" : "Add favorite", systemImage: favorite ? "star.fill" : "star").osdButton()
                        }
                    }
                    Button { player.isMuted.toggle(); poke() } label: {
                        Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill").osdIcon()
                    }
                    .accessibilityLabel(player.isMuted ? "Turn sound on" : "Mute")
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.top, 70)
            .padding(.bottom, 16)
            .background(LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.9)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        }
        .foregroundStyle(Theme.fg)
        .buttonStyle(.plain)
    }

    private func poke() {
        showControls = true
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            if !Task.isCancelled { showControls = false }
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

extension View {
    func osdButton() -> some View {
        self
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.12)))
    }

    func osdIcon() -> some View {
        self
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 44, height: 42)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.12)))
    }
}
