import Foundation
import SwiftUI
import AVFoundation
import MediaPlayer
import Combine

@MainActor
class AudioPlayerManager: ObservableObject {
    static let shared = AudioPlayerManager()

    @Published var currentEpisode: EpisodeItem?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isLoading = false
    @Published var error: String?
    @Published var queue: [EpisodeItem] = []
    @Published var artworkAccent: Color = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.78, alpha: 1)   // light grey in dark mode
                : UIColor(white: 0.15, alpha: 1)   // dark grey in light mode
        })
    @Published var playbackRate: Double = {
        let saved = UserDefaults.standard.double(forKey: "playbackRate")
        return saved > 0 ? saved : 1.0
    }() {
        didSet {
            UserDefaults.standard.set(playbackRate, forKey: "playbackRate")
            if isPlaying { player?.rate = Float(playbackRate) }
            updateNowPlayingInfo()
        }
    }
    @Published var sleepTimerEnd: Date? = nil
    private var sleepTimerTask: Task<Void, Never>?

    @Published var useArtworkAccent: Bool = UserDefaults.standard.object(forKey: "useArtworkAccent") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(useArtworkAccent, forKey: "useArtworkAccent")
            if !useArtworkAccent { artworkAccent = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.78, alpha: 1)   // light grey in dark mode
                : UIColor(white: 0.15, alpha: 1)   // dark grey in light mode
        }) }
            else if let ep = currentEpisode { Task { await extractAccentColor(from: ep.artwork) } }
        }
    }

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var statusCancellable: AnyCancellable?
    private var durationCancellable: AnyCancellable?
    private var endCancellable: AnyCancellable?

    private var progressSaveTask: Task<Void, Never>?
    private var timeControlCancellable: AnyCancellable?
    /// Most-recent local playback position per episode — source of truth for resume position.
    /// Updated every time progress is persisted to the server, so it's always ≥ listenDuration.
    private var localProgress: [Int: Double] = [:]
    /// Timestamp of the last time each episode was played — used to sort Continue Listening.
    /// Persisted across launches so the order survives app restarts.
    private(set) var lastListenedDates: [Int: Date] = {
        guard let raw = UserDefaults.standard.dictionary(forKey: "lastListenedDates") as? [String: Double] else { return [:] }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in
            guard let id = Int(k) else { return nil }
            return (id, Date(timeIntervalSince1970: v))
        })
    }()
    var onEpisodeCompleted: ((EpisodeItem) -> Void)?

    private var cachedArtwork: MPMediaItemArtwork?
    private var cachedArtworkEpisodeId: Int?

    private init() {
        configureAudioSession()
        configureRemoteCommands()
    }

    // MARK: - Playback

    func play(episode: EpisodeItem, localURL: URL? = nil) {
        tearDown()
        currentEpisode = episode
        // Persist so the mini-player can be restored after an app kill/relaunch
        if let data = try? JSONEncoder().encode(episode) {
            UserDefaults.standard.set(data, forKey: "lastPlayingEpisode")
        }
        // Record when this episode was last played so Continue Listening can be sorted
        // most-recently-listened-first across launches.
        lastListenedDates[episode.id] = Date()
        var raw = (UserDefaults.standard.dictionary(forKey: "lastListenedDates") as? [String: Double]) ?? [:]
        raw["\(episode.id)"] = Date().timeIntervalSince1970
        UserDefaults.standard.set(raw, forKey: "lastListenedDates")
        isLoading = true
        error = nil
        playInternal(episode: episode, localURL: localURL)
    }

    private func playInternal(episode: EpisodeItem, localURL: URL?, isRetry: Bool = false) {
        let url: URL
        if let local = localURL, !isRetry {
            url = local
        } else if let remote = URL(string: episode.url) {
            url = remote
        } else {
            error = "Invalid episode URL"
            isLoading = false
            return
        }

        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        // Start playing immediately — don't wait for the buffer to fill
        player?.automaticallyWaitsToMinimizeStalling = false

        // Prefer the live local cache (updated every 15 s) over the server-fetched listenDuration,
        // which may be stale if the episode was recently played without a feed refresh.
        // If the episode is marked completed, always start from the beginning.
        let resumeSeconds: Double = {
            guard !episode.completed else { return 0 }
            if let local = localProgress[episode.id], local > 0 { return local }
            if let server = episode.listenDuration, server > 0 { return Double(server) }
            return 0
        }()

        // Seek to saved position then play
        if resumeSeconds > 0 {
            let target = CMTime(seconds: resumeSeconds, preferredTimescale: 600)
            if localURL != nil && !isRetry {
                // Local file: start playing immediately, seek in parallel (no network latency)
                player?.rate = Float(playbackRate)
                isPlaying = true
                isLoading = false
                player?.seek(to: target,
                             toleranceBefore: CMTime(seconds: 1, preferredTimescale: 600),
                             toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600))
            } else {
                // Remote stream: wait for seek before playing to avoid buffering from wrong position
                item.seek(to: target, toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600)) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.player?.rate = Float(self.playbackRate)
                        self.isPlaying = true
                        self.isLoading = false
                    }
                }
            }
        } else {
            player?.rate = Float(playbackRate)
            isPlaying = true
            isLoading = false
        }

        statusCancellable = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, episode, localURL, isRetry] status in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    self.isLoading = false
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let dur = try? await item.asset.load(.duration) {
                            let s = dur.seconds
                            if !s.isNaN, !s.isInfinite { self.duration = s }
                        }
                    }
                case .failed:
                    if localURL != nil && !isRetry {
                        print("Local playback failed, retrying as stream: \(item.error?.localizedDescription ?? "")")
                        self.statusCancellable = nil
                        self.playInternal(episode: episode, localURL: nil, isRetry: true)
                    } else {
                        self.isLoading = false
                        self.isPlaying = false
                        self.error = item.error?.localizedDescription ?? "Playback failed"
                    }
                default: break
                }
            }

        timeControlCancellable = player?.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                Task { @MainActor [weak self] in
                    self?.isLoading = status == .waitingToPlayAtSpecifiedRate
                }
            }

        durationCancellable = item.publisher(for: \.duration)
            .receive(on: DispatchQueue.main)
            .compactMap { d -> Double? in
                let s = d.seconds
                return (s.isNaN || s.isInfinite) ? nil : s
            }
            .assign(to: \.duration, on: self)

        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let s = time.seconds
                guard !s.isNaN, !s.isInfinite else { return }
                self.currentTime = s
                self.scheduleProgressSave()
                // iOS interpolates elapsed time from playback rate automatically —
                // only sync Now Playing info every 10 s to avoid pointless system calls
                if Int(s) % 10 == 0 {
                    self.updateNowPlayingInfo()
                }
            }
        }

        endCancellable = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let ep = self.currentEpisode else { return }
                self.isPlaying = false
                self.currentTime = 0
                self.localProgress.removeValue(forKey: ep.id)
                self.onEpisodeCompleted?(ep)
                self.playNextInQueue()
            }

        updateNowPlayingInfo()
        Task { await extractAccentColor(from: episode.artwork) }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlayingInfo()
        saveProgressNow()
    }

    func resume() {
        player?.rate = Float(playbackRate)
        isPlaying = true
        updateNowPlayingInfo()
    }

    // MARK: - Sleep Timer

    func setSleepTimer(minutes: Double?) {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        guard let minutes else {
            sleepTimerEnd = nil
            return
        }
        sleepTimerEnd = Date().addingTimeInterval(minutes * 60)
        sleepTimerTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(minutes * 60 * 1_000_000_000))
            guard !Task.isCancelled else { return }
            pause()
            sleepTimerEnd = nil
        }
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func seek(to seconds: Double, precise: Bool = false) {
        let clamped = max(0, min(seconds, duration))
        let tolerance = precise ? CMTime.zero : CMTime(seconds: 1, preferredTimescale: 600)
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                     toleranceBefore: tolerance, toleranceAfter: tolerance)
        currentTime = clamped
        updateNowPlayingInfo()
    }

    func skip(by delta: Double) {
        seek(to: currentTime + delta)
    }

    // MARK: - Queue

    func addToQueue(_ episode: EpisodeItem) {
        guard currentEpisode?.id != episode.id,
              !queue.contains(where: { $0.id == episode.id }) else { return }
        queue.append(episode)
    }

    func removeFromQueue(at offsets: IndexSet) {
        queue.remove(atOffsets: offsets)
    }

    func moveInQueue(from source: IndexSet, to destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
    }

    func playNextInQueue() {
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        play(episode: next, localURL: DownloadManager.shared.localURL(for: next.id))
    }

    func playEpisodeNext(_ episode: EpisodeItem) {
        queue.removeAll { $0.id == episode.id }
        queue.insert(episode, at: 0)
    }

    var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    func formattedTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let t = Int(seconds)
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // MARK: - Private

    func refreshAccentColor(for episode: EpisodeItem) async {
        await extractAccentColor(from: episode.artwork)
    }

    private func extractAccentColor(from urlString: String) async {
        guard useArtworkAccent else { return }
        // Custom per-show colour overrides artwork extraction
        if let podcastName = currentEpisode?.podcastName,
           let custom = PodcastAccentColors.color(for: podcastName) {
            artworkAccent = custom
            return
        }
        // Use cached image if available, else fetch a small version
        let image: UIImage?
        if let cached = ImageCache.shared.get(urlString) {
            image = cached
        } else if let url = URL(string: urlString),
                  let (data, _) = try? await URLSession.shared.data(from: url) {
            image = UIImage(data: data)
        } else {
            image = nil
        }

        guard let img = image,
              let color = await Task.detached(priority: .utility, operation: {
                  dominantColor(of: img)
              }).value else { return }

        artworkAccent = color
    }

    private func tearDown() {
        // Save progress immediately before switching episodes
        if let ep = currentEpisode, currentTime > 0 {
            let t = currentTime
            localProgress[ep.id] = t  // always keep the freshest position
            UserDefaults.standard.set(Int(t), forKey: "lastPlaybackTime")
            var updated = ep
            updated.listenDuration = Int(t)
            if let data = try? JSONEncoder().encode(updated) {
                UserDefaults.standard.set(data, forKey: "lastPlayingEpisode")
            }
            let id = ep.id, isYT = ep.isYoutube
            Task {
                try? await PinepodsAPIService.shared.updateEpisodeProgress(
                    episodeId: id, listenDuration: Int(t), isYoutube: isYT
                )
            }
        }
        progressSaveTask?.cancel()
        progressSaveTask = nil
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEnd = nil
        if let obs = timeObserver { player?.removeTimeObserver(obs); timeObserver = nil }
        player?.pause()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        isLoading = false
        statusCancellable = nil
        durationCancellable = nil
        endCancellable = nil
        timeControlCancellable = nil
        cachedArtwork = nil
        cachedArtworkEpisodeId = nil
    }

    private func scheduleProgressSave() {
        guard progressSaveTask == nil else { return }  // already a save in flight
        progressSaveTask = Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000) // save every 15s while playing
            guard !Task.isCancelled, let ep = currentEpisode else {
                progressSaveTask = nil
                return
            }
            let t = currentTime
            localProgress[ep.id] = t
            // Keep UserDefaults in sync so the fallback in Continue Listening is always
            // fresh — not just when the user explicitly pauses or the app goes to background.
            UserDefaults.standard.set(Int(t), forKey: "lastPlaybackTime")
            var updated = ep
            updated.listenDuration = Int(t)
            if let data = try? JSONEncoder().encode(updated) {
                UserDefaults.standard.set(data, forKey: "lastPlayingEpisode")
            }
            try? await PinepodsAPIService.shared.updateEpisodeProgress(
                episodeId: ep.id,
                listenDuration: Int(t),
                isYoutube: ep.isYoutube
            )
            progressSaveTask = nil
        }
    }

    func saveProgressNow() {
        guard let ep = currentEpisode, currentTime > 0 else { return }
        let id = ep.id, t = Int(currentTime), isYT = ep.isYoutube
        // Persist position locally so Continue Listening can show the episode even if
        // the network call doesn't finish before the app is killed.
        // Also update lastPlayingEpisode with the current time so the card progress bar
        // and resume position are accurate after a restart.
        UserDefaults.standard.set(t, forKey: "lastPlaybackTime")
        var updated = ep
        updated.listenDuration = t
        if let data = try? JSONEncoder().encode(updated) {
            UserDefaults.standard.set(data, forKey: "lastPlayingEpisode")
        }
        // Request background execution time so the network call survives app kill/force-quit.
        // The expiration handler must also end the task so iOS doesn't leak the assertion.
        var bgTask = UIBackgroundTaskIdentifier.invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "saveProgress") {
            UIApplication.shared.endBackgroundTask(bgTask)
        }
        Task {
            try? await PinepodsAPIService.shared.updateEpisodeProgress(
                episodeId: id, listenDuration: t, isYoutube: isYT
            )
            UIApplication.shared.endBackgroundTask(bgTask)
        }
    }

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .spokenAudio,
            options: [.allowAirPlay, .allowBluetoothHFP, .allowBluetoothA2DP]
        )
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.togglePlayPause() }
            return .success
        }

        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] event in
            if let e = event as? MPSkipIntervalCommandEvent {
                Task { @MainActor [weak self] in self?.skip(by: e.interval) }
            }
            return .success
        }
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] event in
            if let e = event as? MPSkipIntervalCommandEvent {
                Task { @MainActor [weak self] in self?.skip(by: -e.interval) }
            }
            return .success
        }

        // Some AirPod models send nextTrack/previousTrack instead of skip
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.skip(by: 30) }
            return .success
        }
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.skip(by: -15) }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let e = event as? MPChangePlaybackPositionCommandEvent {
                Task { @MainActor [weak self] in self?.seek(to: e.positionTime, precise: true) }
            }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let ep = currentEpisode else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        // Fetch artwork once per episode — never on subsequent per-second calls
        if cachedArtworkEpisodeId != ep.id {
            cachedArtwork = nil
            cachedArtworkEpisodeId = ep.id
            if let artURL = URL(string: ep.artwork) {
                Task {
                    let image: UIImage?
                    if let cached = ImageCache.shared.get(ep.artwork) {
                        image = cached
                    } else if let (data, _) = try? await URLSession.shared.data(from: artURL) {
                        image = UIImage(data: data)
                    } else {
                        image = nil
                    }
                    guard let img = image else { return }
                    let art = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                    cachedArtwork = art
                    cachedArtworkEpisodeId = ep.id
                    updateNowPlayingInfo()  // re-call now that artwork is ready
                }
            }
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: ep.title,
            MPMediaItemPropertyArtist: ep.podcastName,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0.0
        ]
        if let art = cachedArtwork {
            info[MPMediaItemPropertyArtwork] = art
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

// MARK: - Dominant colour extraction

nonisolated func dominantColor(of image: UIImage) -> Color? {
    // Render into an explicit RGBA context.
    // UIGraphicsBeginImageContextWithOptions returns BGRA on iOS, which would swap
    // red ↔ blue and produce completely wrong hues (yellow → teal, red → blue, etc.).
    let side = 64
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: side, height: side,
        bitsPerComponent: 8,
        bytesPerRow: side * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue  // RGBA byte order
    ), let cgSrc = image.cgImage else { return nil }
    context.draw(cgSrc, in: CGRect(x: 0, y: 0, width: side, height: side))
    guard let rawData = context.data else { return nil }
    let bytes = rawData.bindMemory(to: UInt8.self, capacity: side * side * 4)
    let count = side * side

    // Hue histogram: 36 buckets × 10° each.
    // Each qualifying pixel contributes equally — area coverage determines the dominant hue,
    // not vividness. This prevents a small vivid foreground object (e.g. orange carrots)
    // from overriding a large muted background (e.g. teal).
    let buckets = 36
    var weights    = [CGFloat](repeating: 0, count: buckets)
    var hueSums    = [CGFloat](repeating: 0, count: buckets)
    var satSums    = [CGFloat](repeating: 0, count: buckets)
    var brightSums = [CGFloat](repeating: 0, count: buckets)

    for i in 0..<count {
        let offset = i * 4
        let r = CGFloat(bytes[offset])     / 255
        let g = CGFloat(bytes[offset + 1]) / 255
        let b = CGFloat(bytes[offset + 2]) / 255

        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        UIColor(red: r, green: g, blue: b, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: &a)

        // Skip near-white, near-black, and near-grey
        guard s > 0.15, v > 0.15, v < 0.97 else { continue }

        // Red hue wraps at 0/1. Pixels near hue=1.0 (e.g. 0.97) belong with pixels near
        // hue=0.0 — merge them into bucket 0 using a negative offset so the average
        // stays near 0 (true red) rather than pulling toward 0.5 (teal).
        let threshold = CGFloat(buckets - 1) / CGFloat(buckets)
        let bucket: Int
        let hForSum: CGFloat
        if h >= threshold {
            bucket = 0
            hForSum = h - 1.0   // negative: pulls weighted average toward 0
        } else {
            bucket = min(Int(h * CGFloat(buckets)), buckets - 1)
            hForSum = h
        }

        weights[bucket]    += 1
        hueSums[bucket]    += hForSum
        satSums[bucket]    += s
        brightSums[bucket] += v
    }

    guard let best = weights.indices.max(by: { weights[$0] < weights[$1] }),
          weights[best] > 0 else {
        return Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.40, alpha: 1)
                : UIColor(white: 0.28, alpha: 1)
        })
    }

    let w      = weights[best]
    var hue    = hueSums[best] / w
    if hue < 0 { hue += 1.0 }  // unwrap red back into [0, 1]
    let avgSat = satSums[best]    / w
    let avgBri = brightSums[best] / w

    let sat = min(max(avgSat, 0.40) * 1.15, 1.0)

    return Color(UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            let bri = min(max(avgBri, 0.55) * 1.25, 0.90)
            return UIColor(hue: hue, saturation: sat * 0.90, brightness: bri, alpha: 1)
        } else {
            // Yellow/orange hues (≈40°–80°) look brown/olive when brightness is crushed —
            // they need higher brightness to stay golden rather than muddy.
            let isYellow = hue >= 0.10 && hue <= 0.22
            let bri = isYellow
                ? min(max(avgBri, 0.72) * 1.15, 0.95)
                : min(max(avgBri, 0.30) * 0.55, 0.52)
            // Pin yellow hues to #FDDA0D (canary gold, visible on white)
            if isYellow {
                return UIColor(hue: 0.142, saturation: 0.95, brightness: 0.99, alpha: 1)
            }
            return UIColor(hue: hue, saturation: min(sat * 1.10, 1.0), brightness: bri, alpha: 1)
        }
    })
}
