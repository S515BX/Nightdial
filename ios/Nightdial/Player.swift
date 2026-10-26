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
    /// Audio tracks of the current stream (languages, Dolby, etc.) when there's more than one.
    @Published private(set) var audioOptions: [String] = []
    @Published private(set) var audioIndex = 0
    /// Paused by you (or by the system, e.g. headphones unplugged).
    @Published private(set) var isPaused = false
    /// Picture shape: "16:9" (default), "fit", "zoom", "stretch", "4:3".
    @Published var aspect: String = UserDefaults.standard.string(forKey: "nightdial.aspect") ?? "16:9" {
        didSet { UserDefaults.standard.set(aspect, forKey: "nightdial.aspect") }
    }
    static let aspects: [(String, String)] = [("16:9", "16:9"), ("fit", "Fit"), ("zoom", "Zoom"), ("stretch", "Stretch"), ("4:3", "4:3")]
    static func aspectName(_ id: String) -> String { aspects.first { $0.0 == id }?.1 ?? "16:9" }
    private var audioGroup: AVMediaSelectionGroup?
    /// Resolution, frame rate, codecs and audio of what's playing (badges in full screen).
    @Published private(set) var streamBadges: [String] = []

    private var statusObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var timeoutTask: Task<Void, Never>?
    private(set) var currentURL: URL?
    /// Reconnecting: providers cut connections now and then (busy servers, links that expire, a connection limit that
    /// still counts the old connection). A stream that was playing is opened again from its link, waiting a little
    /// longer each time, for about a minute before the error shows.
    @Published private(set) var isReconnecting = false
    private var hasPlayed = false
    private var reconnects = 0
    private var reconnectTask: Task<Void, Never>?
    private var steadyTask: Task<Void, Never>?
    private var stallTask: Task<Void, Never>?
    private var resumeAt: Double?
    private static let reconnectDelays: [Double] = [1, 2, 3, 5, 8, 10, 12, 15]

    init() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
        player.allowsExternalPlayback = true
    }

    func play(_ url: URL) {
        play(url, reconnecting: false)
    }

    private func play(_ url: URL, reconnecting: Bool) {
        clearObservers()
        if !reconnecting {
            reconnects = 0
            hasPlayed = false
            isReconnecting = false
            resumeAt = nil
        }
        currentURL = url
        state = .loading
        audioOptions = []
        audioIndex = 0
        audioGroup = nil
        isPaused = false
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": Net.userAgent]])
        let item = AVPlayerItem(asset: asset)
        // best picture: no resolution or bit-rate cap, and start on the best variant the connection allows
        item.preferredPeakBitRate = 0
        item.preferredMaximumResolution = .zero
        item.startsOnFirstEligibleVariant = false
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            let failed = observed.status == .failed, ready = observed.status == .readyToPlay
            Task { @MainActor [weak self] in
                guard let self else { return }
                if failed { self.markFailed("network") }
                // a movie or recording that dropped carries on where it was
                if ready, let at = self.resumeAt, at > 5 {
                    self.resumeAt = nil
                    self.player.seek(to: CMTime(seconds: at, preferredTimescale: 600))
                }
            }
        }
        controlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
            let status = observed.timeControlStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                if status == .playing {
                    self.stallTask?.cancel()
                    self.markPlaying()
                    self.isPaused = false
                } else if status == .paused && self.state == .playing {
                    self.stallTask?.cancel()
                    self.isPaused = true
                } else if status == .waitingToPlayAtSpecifiedRate && self.hasPlayed {
                    // a stream that freezes without an error is opened again after 20 s
                    self.stallTask?.cancel()
                    self.stallTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 20_000_000_000)
                        guard !Task.isCancelled, let self, self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
                        self.markFailed("network")
                    }
                }
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
        cancelReconnect()
        if let url = currentURL { play(url) }
    }

    func fail(_ code: String) {
        clearObservers()
        cancelReconnect()
        player.replaceCurrentItem(with: nil)
        isPaused = false
        state = .failed(code)
    }

    func stop() {
        streamBadges = []
        clearObservers()
        cancelReconnect()
        hasPlayed = false
        isReconnecting = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentURL = nil
        isPaused = false
        state = .idle
    }

    // MARK: Pause and rewind

    struct TimeInfo {
        /// The stream keeps enough of itself to rewind (live DVR window or a recording).
        var seekable = false
        /// Seconds behind the newest point of the stream.
        var behind: Double = 0
        /// How many seconds the stream keeps (its seekable window).
        var window: Double = 0
        var position: Double = 0
        var duration: Double = 0
    }

    var timeInfo: TimeInfo {
        guard let item = player.currentItem else { return TimeInfo() }
        let t = player.currentTime().seconds
        let pos = t.isFinite ? t : 0
        let d = item.duration.seconds
        var info = TimeInfo(position: pos, duration: d.isFinite ? d : 0)
        if let r = item.seekableTimeRanges.last?.timeRangeValue {
            let start = r.start.seconds, end = (r.start + r.duration).seconds
            if start.isFinite, end.isFinite, end - start > 60 {
                info.seekable = true
                info.behind = max(0, end - pos)
                info.window = end - start
            }
        }
        return info
    }

    func setPaused(_ paused: Bool) {
        guard player.currentItem != nil else { return }
        if paused { player.pause() } else { player.play() }
        isPaused = paused
    }

    /// Jumps within what the stream keeps; stays a few seconds short of the live edge.
    func skip(by seconds: Double) {
        guard let item = player.currentItem else { return }
        var target = player.currentTime().seconds + seconds
        if let r = item.seekableTimeRanges.last?.timeRangeValue {
            let start = r.start.seconds, end = (r.start + r.duration).seconds
            if start.isFinite && end.isFinite { target = min(max(start, target), max(start, end - 3)) }
        }
        guard target.isFinite else { return }
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    func seekToLiveEdge() {
        guard let r = player.currentItem?.seekableTimeRanges.last?.timeRangeValue else { return }
        player.seek(to: r.start + r.duration)
        if isPaused { setPaused(false) }
    }

    private func markPlaying() {
        timeoutTask?.cancel()
        hasPlayed = true
        isReconnecting = false
        // half a minute of steady playing counts as healthy again
        steadyTask?.cancel()
        steadyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            self?.reconnects = 0
        }
        let first = state != .playing
        state = .playing
        if first, let item = player.currentItem {
            loadAudioOptions(item)
            refreshStreamInfo()
            Task { @MainActor [weak self] in
                for delay in [1.5, 5.0] {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard let self, self.player.currentItem === item else { return }
                    self.refreshStreamInfo()
                }
            }
        }
    }

    func refreshStreamInfo() {
        guard let item = player.currentItem else { streamBadges = []; return }
        var out: [String] = []
        let size = item.presentationSize
        if size.height > 0 {
            let v = max(size.height, (size.width * 9 / 16).rounded())
            out.append(v >= 2000 ? "4K" : v >= 1400 ? "1440p" : v >= 1000 ? "1080p" : v >= 700 ? "720p" : "SD \(Int(size.height))p")
        }
        var fps: Float = 0
        var vcodec = "", audio = ""
        for t in item.tracks {
            guard let at = t.assetTrack else { continue }
            if at.mediaType == .video {
                let r = t.currentVideoFrameRate > 0 ? t.currentVideoFrameRate : at.nominalFrameRate
                if r > fps { fps = r }
                if let any = at.formatDescriptions.first {
                    vcodec = Self.videoCodec(CMFormatDescriptionGetMediaSubType(any as! CMFormatDescription))
                }
            } else if at.mediaType == .audio, let any = at.formatDescriptions.first,
                      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(any as! CMFormatDescription)?.pointee {
                let n = Int(asbd.mChannelsPerFrame)
                let layout = n == 1 ? "Mono" : n == 2 ? "Stereo" : n == 6 ? "5.1" : n == 8 ? "7.1" : n > 0 ? "\(n) ch" : ""
                audio = [Self.audioCodec(asbd.mFormatID), layout].filter { !$0.isEmpty }.joined(separator: " ")
            }
        }
        if fps > 0 { out.append("\(Int(fps.rounded())) fps") }
        if !vcodec.isEmpty { out.append(vcodec) }
        if !audio.isEmpty { out.append(audio) }
        streamBadges = out
    }

    static func videoCodec(_ t: FourCharCode) -> String {
        switch t {
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_HEVC: return "HEVC"
        case kCMVideoCodecType_MPEG2Video: return "MPEG-2"
        default: return ""
        }
    }

    static func audioCodec(_ id: AudioFormatID) -> String {
        switch id {
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: return "AAC"
        case kAudioFormatAC3: return "Dolby Digital"
        case kAudioFormatEnhancedAC3: return "Dolby Digital+"
        case kAudioFormatMPEGLayer2: return "MP2"
        case kAudioFormatMPEGLayer3: return "MP3"
        default: return ""
        }
    }

    private func loadAudioOptions(_ item: AVPlayerItem) {
        let asset = item.asset
        Task { @MainActor [weak self] in
            guard let group = try? await asset.loadMediaSelectionGroup(for: .audible) else { return }
            guard let self, self.player.currentItem === item else { return }
            self.audioGroup = group
            self.audioOptions = group.options.map { $0.displayName }
            if let selected = item.currentMediaSelection.selectedMediaOption(in: group),
               let i = group.options.firstIndex(of: selected) {
                self.audioIndex = i
            }
        }
    }

    func selectAudio(_ index: Int) {
        guard let group = audioGroup, group.options.indices.contains(index), let item = player.currentItem else { return }
        item.select(group.options[index], in: group)
        audioIndex = index
    }

    private func markFailed(_ code: String) {
        timeoutTask?.cancel()
        stallTask?.cancel()
        steadyTask?.cancel()
        if hasPlayed, let url = currentURL, reconnects < Self.reconnectDelays.count {
            let item = player.currentItem
            let live = item.map { $0.duration.isIndefinite } ?? true
            let t = player.currentTime().seconds
            if !live, t.isFinite, t > 5 { resumeAt = t }
            let delay = Self.reconnectDelays[reconnects]
            reconnects += 1
            isReconnecting = true
            state = .loading
            reconnectTask?.cancel()
            reconnectTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self, self.currentURL == url else { return }
                self.play(url, reconnecting: true)
            }
            return
        }
        isReconnecting = false
        state = .failed(code)
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        steadyTask?.cancel()
        stallTask?.cancel()
        resumeAt = nil
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
        stallTask?.cancel()
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

/// Video layer sized for the chosen picture shape: 16:9 and 4:3 are drawn into a box of that shape (stretching the
/// picture to it), Fit keeps the channel's own shape, Zoom fills by trimming the edges, Stretch fills everything.
final class PlayerLayerView: UIView {
    let playerLayer = AVPlayerLayer()
    var aspect = "16:9" { didSet { if aspect != oldValue { setNeedsLayout() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(playerLayer)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var r = bounds
        switch aspect {
        case "fit": playerLayer.videoGravity = .resizeAspect
        case "zoom": playerLayer.videoGravity = .resizeAspectFill
        case "stretch": playerLayer.videoGravity = .resize
        default:
            let ratio: CGFloat = aspect == "4:3" ? 4.0 / 3.0 : 16.0 / 9.0
            if r.width / max(1, r.height) > ratio {
                let w = r.height * ratio
                r = CGRect(x: (r.width - w) / 2, y: 0, width: w, height: r.height)
            } else {
                let h = r.width / ratio
                r = CGRect(x: 0, y: (r.height - h) / 2, width: r.width, height: h)
            }
            playerLayer.videoGravity = .resize
        }
        playerLayer.frame = r
        CATransaction.commit()
    }
}

/// Shows an AVPlayer. Only one surface holds the player at a time (preview or full screen).
struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer?
    var aspect: String = "16:9"
    var onLayer: ((AVPlayerLayer) -> Void)? = nil

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.backgroundColor = .black
        view.aspect = aspect
        view.playerLayer.player = player
        onLayer?(view.playerLayer)
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.aspect = aspect
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
