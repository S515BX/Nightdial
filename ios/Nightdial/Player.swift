import AVFoundation
import AVKit
import SwiftUI
import UIKit
#if canImport(MobileVLCKit)
import MobileVLCKit
#endif

/// Wraps one AVPlayer shared by the preview window and the full-screen view.
@MainActor
final class PlayerController: ObservableObject {
    enum State: Equatable { case idle, loading, playing, failed(String) }

    let player = AVPlayer()
    @Published private(set) var state: State = .idle
    @Published var isMuted = false {
        didSet {
            player.isMuted = isMuted
            #if canImport(MobileVLCKit)
            vlcBackend?.player.audio?.isMuted = isMuted
            #endif
        }
    }

    /// Which player shows the stream. Apple's player (AVPlayer) for most channels; the built-in VLC engine for the ones
    /// Apple's can't show: HEVC or MPEG-2 video in a live MPEG-TS stream (often 24/7 channels), where Apple's player
    /// plays only the sound.
    enum Engine { case av, vlc }
    @Published private(set) var engine: Engine = .av { didSet { if engine != oldValue { placeVLC(); applyVLCAspect() } } }
    static var hasVLC: Bool {
        #if canImport(MobileVLCKit)
        return true
        #else
        return false
        #endif
    }
    /// Holds the view VLC draws into; it moves into whichever video surface is in front.
    let vlcView = VLCHolderView()
    #if canImport(MobileVLCKit)
    private var vlcBackend: VLCBackend?
    #endif
    /// The channel being played (to remember that it needs VLC) and the link VLC opens (the provider's original
    /// MPEG-TS link when there is one).
    private var channelKey: String?
    private var groupKey: String?
    private var vlcURL: URL?
    private var triedVLC = false
    private var rememberIfVLCPlays = false
    private var videoCheckTask: Task<Void, Never>?
    private struct Host { weak var view: UIView?; let priority: Int; let order: Int }
    private var vlcHosts: [Host] = []
    private var hostOrder = 0
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
        vlcView.onResize = { [weak self] in self?.applyVLCAspect() }
    }

    /// Plays a stream. `alternate` is what VLC opens if it's needed; `key` and `group` name the channel and its group,
    /// so a channel that needed VLC once (and the rest of its group, like a 24/7 group) starts in VLC.
    func play(_ url: URL, alternate: URL? = nil, key: String? = nil, group: String? = nil) {
        channelKey = key
        groupKey = group
        vlcURL = alternate
        triedVLC = false
        rememberIfVLCPlays = false
        engine = Self.hasVLC && Self.prefersVLC(key: key, group: group) ? .vlc : .av
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
        if engine == .vlc {
            startVLC(url)
            return
        }
        stopVLC()
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
        stopVLC()
        player.replaceCurrentItem(with: nil)
        isPaused = false
        state = .failed(code)
    }

    func stop() {
        streamBadges = []
        clearObservers()
        cancelReconnect()
        stopVLC()
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
        #if canImport(MobileVLCKit)
        if engine == .vlc, let b = vlcBackend {
            // VLC: a recording (catch-up) can be scrubbed; live TV can't
            let length = Double(b.player.media?.length.intValue ?? 0) / 1000, pos = Double(b.player.time.intValue) / 1000
            guard length > 60 else { return TimeInfo(position: max(0, pos)) }
            return TimeInfo(seekable: true, behind: max(0, length - pos), window: length, position: max(0, pos), duration: length)
        }
        #endif
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
        #if canImport(MobileVLCKit)
        if engine == .vlc, let b = vlcBackend {
            if paused { b.player.pause() } else { b.player.play() }
            isPaused = paused
            return
        }
        #endif
        guard player.currentItem != nil else { return }
        if paused { player.pause() } else { player.play() }
        isPaused = paused
    }

    /// Jumps within what the stream keeps; stays a few seconds short of the live edge.
    func skip(by seconds: Double) {
        #if canImport(MobileVLCKit)
        if engine == .vlc, let b = vlcBackend {
            let s = Int32(abs(seconds).rounded())
            if seconds > 0 { b.player.jumpForward(s) } else { b.player.jumpBackward(s) }
            return
        }
        #endif
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
        if engine == .vlc {
            let first = state != .playing
            state = .playing
            if isPaused { isPaused = false }
            if rememberIfVLCPlays { learnNeedsVLC(group: false); rememberIfVLCPlays = false }
            steadyTask?.cancel()
            steadyTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                self?.reconnects = 0
            }
            if first {
                refreshVLCInfo()
                Task { @MainActor [weak self] in
                    for delay in [1.5, 5.0] {
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        guard let self, self.engine == .vlc, self.state == .playing else { return }
                        self.refreshVLCInfo()
                    }
                }
            }
            return
        }
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
            checkVideoShows(item)
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
        #if canImport(MobileVLCKit)
        if engine == .vlc, let b = vlcBackend {
            let ids = (b.player.audioTrackIndexes ?? []).compactMap { ($0 as? NSNumber)?.int32Value }.filter { $0 >= 0 }
            guard ids.indices.contains(index) else { return }
            b.player.currentAudioTrackIndex = ids[index]
            audioIndex = index
            return
        }
        #endif
        guard let group = audioGroup, group.options.indices.contains(index), let item = player.currentItem else { return }
        item.select(group.options[index], in: group)
        audioIndex = index
    }

    private func markFailed(_ code: String) {
        timeoutTask?.cancel()
        stallTask?.cancel()
        steadyTask?.cancel()
        // Apple's player couldn't open it at all: VLC opens more kinds of streams, so try it once before giving up
        if engine == .av, !hasPlayed, code != "timeout", Self.hasVLC, channelKey != nil, !triedVLC, let url = currentURL {
            triedVLC = true
            rememberIfVLCPlays = true
            engine = .vlc
            play(url, reconnecting: true)
            return
        }
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
        videoCheckTask?.cancel()
    }

    // MARK: Built-in VLC

    private static let vlcKeysKey = "nightdial.vlcChannels"
    private static let vlcGroupsKey = "nightdial.vlcGroups"
    private static let avKeysKey = "nightdial.avChannels"
    private static func list(_ k: String) -> [String] { UserDefaults.standard.stringArray(forKey: k) ?? [] }
    private static func put(_ value: String, in k: String, _ on: Bool) {
        var keys = list(k).filter { $0 != value }
        if on { keys.insert(value, at: 0) }
        UserDefaults.standard.set(Array(keys.prefix(1000)), forKey: k)
    }

    /// Plays in VLC: a channel you set to Apple's player never does; one that needed VLC (or you picked VLC) does;
    /// otherwise the channel does when another channel in its group needed VLC.
    static func prefersVLC(key: String?, group: String?) -> Bool {
        guard let key else { return false }
        if list(avKeysKey).contains(key) { return false }
        if list(vlcKeysKey).contains(key) { return true }
        if let group, list(vlcGroupsKey).contains(group) { return true }
        return false
    }

    /// Channel options: you pick the player for this channel.
    static func setUsesVLC(_ key: String, _ on: Bool) {
        put(key, in: vlcKeysKey, on)
        put(key, in: avKeysKey, !on)
    }

    /// Apple's player couldn't show this channel's picture: it and the rest of its group play in VLC from now on.
    private func learnNeedsVLC(group alsoGroup: Bool) {
        guard let key = channelKey else { return }
        Self.put(key, in: Self.vlcKeysKey, true)
        if alsoGroup, let groupKey { Self.put(groupKey, in: Self.vlcGroupsKey, true) }
    }

    /// Apple's player is playing, but if it still has no picture size soon after it starts, the video is a kind it
    /// can't show (HEVC or MPEG-2 in a live MPEG-TS stream; it knows the size of any video it can show before playing):
    /// switch to VLC and remember the channel and its group.
    private func checkVideoShows(_ item: AVPlayerItem) {
        videoCheckTask?.cancel()
        guard Self.hasVLC, engine == .av, channelKey != nil, item.presentationSize == .zero else { return }
        videoCheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self, self.engine == .av, self.player.currentItem === item,
                  self.state == .playing, !self.isPaused, item.presentationSize == .zero, let url = self.currentURL else { return }
            self.learnNeedsVLC(group: true)
            self.triedVLC = true
            self.engine = .vlc
            self.play(url, reconnecting: false)
        }
    }

    private func startVLC(_ url: URL) {
        #if canImport(MobileVLCKit)
        player.pause()
        player.replaceCurrentItem(with: nil)
        state = .loading
        audioOptions = []
        audioIndex = 0
        audioGroup = nil
        isPaused = false
        streamBadges = []
        // a fresh VLC player for each stream; the old one is stopped away from the screen's thread
        retireVLC()
        let b = VLCBackend()
        b.player.drawable = vlcView.drawable
        b.onState = { [weak self] s in self?.vlcStateChanged(s) }
        b.onTime = { [weak self] in
            guard let self, self.engine == .vlc, self.state != .playing, !self.isPaused else { return }
            self.markPlaying()
        }
        vlcBackend = b
        let media = VLCMedia(url: vlcURL ?? url)
        media.addOption(":http-user-agent=\(Net.userAgent)")
        media.addOption(":network-caching=1500")
        b.player.media = media
        b.player.audio?.isMuted = isMuted
        placeVLC()
        applyVLCAspect()
        b.player.play()
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.state == .loading { self.markFailed("timeout") }
        }
        #else
        markFailed("network")
        #endif
    }

    private func stopVLC() {
        retireVLC()
    }

    /// VLC's stop waits for its own threads, which can need the main thread: never stop it on the main thread.
    private func retireVLC() {
        #if canImport(MobileVLCKit)
        guard let b = vlcBackend else { return }
        vlcBackend = nil
        b.onState = nil
        b.onTime = nil
        b.player.delegate = nil
        DispatchQueue.global(qos: .userInitiated).async {
            b.player.stop()
            _ = b
        }
        #endif
    }

    #if canImport(MobileVLCKit)
    private func vlcStateChanged(_ s: VLCMediaPlayerState) {
        guard engine == .vlc else { return }
        // VLC reports buffering and playing many times a second on live streams: only real changes update the screen
        switch s {
        case .playing:
            if state != .playing { markPlaying() } else if isPaused { isPaused = false }
        case .paused:
            if state == .playing && !isPaused { isPaused = true }
        case .error:
            if state == .loading || state == .playing { markFailed("network") }
        case .ended, .stopped:
            // a live stream that ends was cut off by the provider
            if state == .playing { markFailed("stopped") }
        default:
            break
        }
    }
    #endif

    private func refreshVLCInfo() {
        #if canImport(MobileVLCKit)
        guard let b = vlcBackend else { return }
        var out: [String] = []
        let size = b.player.videoSize
        if size.height > 0 {
            let v = max(size.height, (size.width * 9 / 16).rounded())
            out.append(v >= 2000 ? "4K" : v >= 1400 ? "1440p" : v >= 1000 ? "1080p" : v >= 700 ? "720p" : "SD \(Int(size.height))p")
        }
        var vcodec = "", audio = ""
        for case let t as [String: Any] in (b.player.media?.tracksInformation ?? []) {
            let type = t[VLCMediaTracksInformationType] as? String
            let code = Self.fourCC((t[VLCMediaTracksInformationCodec] as? NSNumber)?.uint32Value ?? 0)
            if type == VLCMediaTracksInformationTypeVideo, vcodec.isEmpty {
                vcodec = ["hevc": "HEVC", "hev1": "HEVC", "h265": "HEVC", "h264": "H.264", "avc1": "H.264", "mpgv": "MPEG-2", "mp2v": "MPEG-2"][code] ?? code.uppercased()
            } else if type == VLCMediaTracksInformationTypeAudio, audio.isEmpty {
                let n = (t[VLCMediaTracksInformationAudioChannelsNumber] as? NSNumber)?.intValue ?? 0
                let layout = n == 1 ? "Mono" : n == 2 ? "Stereo" : n == 6 ? "5.1" : n == 8 ? "7.1" : n > 0 ? "\(n) ch" : ""
                let name = ["mp4a": "AAC", "a52 ": "Dolby Digital", "eac3": "Dolby Digital+", "mpga": "MPEG audio", "mp3 ": "MP3", "opus": "Opus"][code] ?? code.uppercased()
                audio = [name, layout].filter { !$0.isEmpty }.joined(separator: " ")
            }
        }
        if !vcodec.isEmpty { out.append(vcodec) }
        if !audio.isEmpty { out.append(audio) }
        out.append("VLC")
        streamBadges = out
        let names = (b.player.audioTrackNames ?? []).compactMap { $0 as? String }
        let ids = (b.player.audioTrackIndexes ?? []).compactMap { ($0 as? NSNumber)?.int32Value }
        let tracks = zip(ids, names).filter { $0.0 >= 0 }
        audioOptions = tracks.count > 1 ? tracks.map { $0.1 } : []
        audioIndex = tracks.firstIndex { $0.0 == b.player.currentAudioTrackIndex } ?? 0
        #endif
    }

    private static func fourCC(_ v: UInt32) -> String {
        let bytes = [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
        return String(bytes: bytes, encoding: .ascii)?.lowercased() ?? ""
    }

    /// Picture shape in VLC, the same choices as Apple's player.
    private func applyVLCAspect() {
        #if canImport(MobileVLCKit)
        guard let b = vlcBackend else { return }
        let size = vlcView.bounds.size
        let viewRatio: String? = size.width > 0 && size.height > 0 ? "\(Int(size.width.rounded())):\(Int(size.height.rounded()))" : nil
        let ratio: String?, crop: String?
        switch aspect {
        case "fit": ratio = nil; crop = nil
        case "zoom": ratio = nil; crop = viewRatio
        case "stretch": ratio = viewRatio; crop = nil
        case "4:3": ratio = "4:3"; crop = nil
        default: ratio = "16:9"; crop = nil
        }
        if let ratio { ratio.withCString { b.player.videoAspectRatio = UnsafeMutablePointer(mutating: $0) } } else { b.player.videoAspectRatio = nil }
        if let crop { crop.withCString { b.player.videoCropGeometry = UnsafeMutablePointer(mutating: $0) } } else { b.player.videoCropGeometry = nil }
        #endif
    }

    /// Video surfaces (the preview and full screen) offer themselves to VLC; it draws in the frontmost one.
    func registerVLCHost(_ view: UIView, priority: Int) {
        hostOrder += 1
        vlcHosts.removeAll { $0.view == nil || $0.view === view }
        vlcHosts.append(Host(view: view, priority: priority, order: hostOrder))
        placeVLC()
    }

    func unregisterVLCHost(_ view: UIView) {
        vlcHosts.removeAll { $0.view == nil || $0.view === view }
        placeVLC()
    }

    func placeVLC() {
        let hidden = engine != .vlc
        if vlcView.isHidden != hidden { vlcView.isHidden = hidden }
        let live = vlcHosts.filter { $0.view != nil }
        guard let top = live.max(by: { ($0.priority, $0.order) < ($1.priority, $1.order) })?.view else {
            if vlcView.superview != nil { vlcView.removeFromSuperview() }
            return
        }
        if vlcView.superview !== top { top.addSubview(vlcView) }
        if vlcView.frame != top.bounds { vlcView.frame = top.bounds }
    }
}

/// Moves between video surfaces and holds the view VLC draws into. Touches go straight through to the player's
/// controls, and the tap handler VLC attaches around its picture (meant for DVD menus) is switched off.
final class VLCHolderView: UIView {
    let drawable = VLCDrawableView()
    var onResize: (() -> Void)?
    private var lastSize = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        drawable.frame = bounds
        addSubview(drawable)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if drawable.frame != bounds { drawable.frame = bounds }
        if bounds.size != lastSize {
            lastSize = bounds.size
            onResize?()
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override func addGestureRecognizer(_ g: UIGestureRecognizer) {
        g.cancelsTouchesInView = false
        g.isEnabled = false
        super.addGestureRecognizer(g)
    }
}

/// The view VLC draws into. It never takes touches.
final class VLCDrawableView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override func addGestureRecognizer(_ g: UIGestureRecognizer) {
        g.cancelsTouchesInView = false
        g.isEnabled = false
        super.addGestureRecognizer(g)
    }
}

#if canImport(MobileVLCKit)
/// VLC's player (VLCKit, LGPL 2.1). Its callbacks arrive on the main thread.
final class VLCBackend: NSObject, VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()
    var onState: ((VLCMediaPlayerState) -> Void)?
    var onTime: (() -> Void)?

    override init() {
        super.init()
        player.delegate = self
    }

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        let s = player.state
        DispatchQueue.main.async { [weak self] in self?.onState?(s) }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.onTime?() }
    }
}
#endif

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
    weak var vlcController: PlayerController?
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
    /// Also hosts the built-in VLC engine's picture; the surface with the highest priority (full screen) shows it.
    var controller: PlayerController? = nil
    var priority = 0

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.backgroundColor = .black
        view.aspect = aspect
        view.playerLayer.player = player
        onLayer?(view.playerLayer)
        view.vlcController = controller
        controller?.registerVLCHost(view, priority: priority)
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.aspect = aspect
        controller?.placeVLC()
    }

    static func dismantleUIView(_ view: PlayerLayerView, coordinator: ()) {
        view.vlcController?.unregisterVLCHost(view)
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
