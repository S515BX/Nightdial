import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// Wraps one AVPlayer shared by the preview window and the full-screen view.
@MainActor
final class PlayerController: ObservableObject {
    enum State: Equatable { case idle, loading, playing, failed(String) }

    let player = AVPlayer()
    @Published private(set) var state: State = .idle
    @Published var isMuted = false { didSet { player.isMuted = isMuted } }

    private var statusObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var timeoutTask: Task<Void, Never>?
    private(set) var currentURL: URL?

    init() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
        player.allowsExternalPlayback = true
    }

    func play(_ url: URL) {
        clearObservers()
        currentURL = url
        state = .loading
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": "Tuner/1.0"]])
        let item = AVPlayerItem(asset: asset)
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            let failed = observed.status == .failed
            Task { @MainActor [weak self] in
                if failed { self?.markFailed("network") }
            }
        }
        controlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
            let playing = observed.timeControlStatus == .playing
            Task { @MainActor [weak self] in
                if playing { self?.markPlaying() }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.markFailed("stopped") }
        }
        player.replaceCurrentItem(with: item)
        player.isMuted = isMuted
        player.play()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.state == .loading { self.markFailed("timeout") }
        }
    }

    func retry() {
        if let url = currentURL { play(url) }
    }

    func fail(_ code: String) {
        clearObservers()
        player.replaceCurrentItem(with: nil)
        state = .failed(code)
    }

    func stop() {
        clearObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentURL = nil
        state = .idle
    }

    private func markPlaying() {
        timeoutTask?.cancel()
        state = .playing
    }

    private func markFailed(_ code: String) {
        timeoutTask?.cancel()
        state = .failed(code)
    }

    private func clearObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
        controlObservation?.invalidate()
        controlObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        timeoutTask?.cancel()
        timeoutTask = nil
    }
}

enum PlaybackMessage {
    static func text(_ code: String) -> (title: String, detail: String) {
        switch code {
        case "timeout": return ("The channel didn't start", "It may be offline, or your connection limit may be reached.")
        case "stopped": return ("Playback stopped", "The stream was interrupted.")
        default: return ("This channel isn't playing", "The stream couldn't be loaded. Try again in a moment.")
        }
    }
}

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Shows an AVPlayer. Only one surface holds the player at a time (preview or full screen).
struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer?
    var onLayer: ((AVPlayerLayer) -> Void)? = nil

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        onLayer?(view.playerLayer)
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

/// Picture in Picture for the full-screen player.
final class PiPController: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    @Published private(set) var isActive = false
    private var controller: AVPictureInPictureController?

    var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func attach(_ layer: AVPlayerLayer) {
        guard isSupported, controller == nil else { return }
        let c = AVPictureInPictureController(playerLayer: layer)
        c?.delegate = self
        c?.canStartPictureInPictureAutomaticallyFromInline = true
        controller = c
    }

    func toggle() {
        guard let c = controller else { return }
        if c.isPictureInPictureActive { c.stopPictureInPicture() } else { c.startPictureInPicture() }
    }

    // AVKit calls these on the main thread.
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = true
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = false
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = Palette.accent
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
