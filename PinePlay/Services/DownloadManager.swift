import Combine
import Foundation

@MainActor
class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published var downloadProgress: [Int: Double] = [:]
    @Published var locallyDownloaded: Set<Int> = []
    @Published var downloadingEpisodes: [Int: EpisodeItem] = [:]
    /// Persisted metadata for all downloaded episodes — available offline.
    @Published var episodeMetadata: [Int: EpisodeItem] = [:]

    private var backgroundSession: URLSession!
    private var episodeIdToTask: [Int: URLSessionDownloadTask] = [:]

    var autoDownloadSettings = AutoDownloadSettings.load()
    var backgroundCompletionHandler: (() -> Void)?
    /// Episodes the user explicitly deleted — never re-downloaded by auto-download.
    private var manuallyDeleted: Set<Int> = {
        let ids = (UserDefaults.standard.array(forKey: "manuallyDeletedEpisodes") as? [Int]) ?? []
        return Set(ids)
    }()

    // Thread-safe task map — nonisolated so delegates can call it without hopping to main actor
    nonisolated private let taskMap = TaskMap()

    // Episodes directory — nonisolated so it's safe to use from nonisolated delegate methods
    nonisolated static let episodesDirectory: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PinePods/Episodes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    var episodesDirectory: URL { DownloadManager.episodesDirectory }

    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: "com.pinepods.episode.downloads")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        backgroundSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        loadLocalDownloads()
        loadTaskMap()
        loadEpisodeMetadata()
    }

    func localURL(for episodeId: Int) -> URL? {
        let url = DownloadManager.episodesDirectory.appendingPathComponent("\(episodeId).audio")
        guard locallyDownloaded.contains(episodeId),
              FileManager.default.fileExists(atPath: url.path),
              let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > 1000 else { return nil }
        return url
    }

    func isDownloading(_ episodeId: Int) -> Bool {
        downloadProgress[episodeId] != nil
    }

    func downloadEpisode(_ episode: EpisodeItem) {
        guard !locallyDownloaded.contains(episode.id),
              !isDownloading(episode.id),
              let url = URL(string: episode.url) else { return }

        let task = backgroundSession.downloadTask(with: url)
        episodeIdToTask[episode.id] = task
        downloadProgress[episode.id] = 0
        downloadingEpisodes[episode.id] = episode
        episodeMetadata[episode.id] = episode   // persist for offline access
        persistEpisodeMetadata()
        taskMap.set(task.taskIdentifier, episodeId: episode.id)
        task.resume()
    }

    func cancelDownload(_ episodeId: Int) {
        if let task = episodeIdToTask[episodeId] {
            taskMap.remove(task.taskIdentifier)
            task.cancel()
        }
        episodeIdToTask.removeValue(forKey: episodeId)
        downloadProgress.removeValue(forKey: episodeId)
        downloadingEpisodes.removeValue(forKey: episodeId)
    }

    func deleteLocalDownload(_ episodeId: Int) {
        let url = DownloadManager.episodesDirectory.appendingPathComponent("\(episodeId).audio")
        try? FileManager.default.removeItem(at: url)
        locallyDownloaded.remove(episodeId)
        episodeMetadata.removeValue(forKey: episodeId)
        manuallyDeleted.insert(episodeId)
        persistLocalDownloads()
        persistEpisodeMetadata()
        UserDefaults.standard.set(Array(manuallyDeleted), forKey: "manuallyDeletedEpisodes")
    }

    func autoDownloadNewEpisodes(_ episodes: [EpisodeItem]) {
        guard autoDownloadSettings.enabled else { return }
        let selectedNames = autoDownloadSettings.selectedPodcastNames
        let downloadAll = autoDownloadSettings.downloadAllShows
        let grouped = Dictionary(grouping: episodes) { $0.podcastName }
        var toDownload: [EpisodeItem] = []
        for (podcastName, podcastEpisodes) in grouped {
            if !downloadAll, !selectedNames.contains(podcastName) { continue }
            // Sort most recent first, then take up to maxEpisodes undownloaded
            let sorted = podcastEpisodes.sorted { $0.pubDate > $1.pubDate }
            let undownloaded = sorted.filter { !$0.downloaded && !locallyDownloaded.contains($0.id) && !manuallyDeleted.contains($0.id) }
            toDownload += undownloaded.prefix(autoDownloadSettings.maxEpisodes)
        }
        for ep in toDownload { downloadEpisode(ep) }
    }

    private func loadLocalDownloads() {
        let dir = DownloadManager.episodesDirectory
        let ids = (UserDefaults.standard.array(forKey: "locallyDownloadedEpisodes") as? [Int]) ?? []
        locallyDownloaded = Set(ids.filter {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("\($0).audio").path)
        })
    }

    private func persistLocalDownloads() {
        UserDefaults.standard.set(Array(locallyDownloaded), forKey: "locallyDownloadedEpisodes")
    }

    private func loadTaskMap() {
        taskMap.load()
    }

    private func loadEpisodeMetadata() {
        guard let data = UserDefaults.standard.data(forKey: "downloadedEpisodeMetadata"),
              let decoded = try? JSONDecoder().decode([Int: EpisodeItem].self, from: data) else { return }
        // Keep all metadata — includes in-progress downloads from previous sessions
        episodeMetadata = decoded
    }

    private func persistEpisodeMetadata() {
        if let data = try? JSONEncoder().encode(episodeMetadata) {
            UserDefaults.standard.set(data, forKey: "downloadedEpisodeMetadata")
        }
    }

    /// Backfill metadata for locally-downloaded episodes that have no persisted metadata
    /// (e.g. files carried over from a previous build where metadata wasn't saved).
    func syncMissingMetadata() async {
        let missingIds = locallyDownloaded.filter { episodeMetadata[$0] == nil }
        guard !missingIds.isEmpty else { return }
        guard let serverEpisodes = try? await PinepodsAPIService.shared.getServerDownloadedEpisodes() else { return }
        var changed = false
        for ep in serverEpisodes where missingIds.contains(ep.id) {
            episodeMetadata[ep.id] = ep
            changed = true
        }
        if changed { persistEpisodeMetadata() }
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskId = downloadTask.taskIdentifier
        guard let episodeId = taskMap.get(taskId) else { return }

        // Save file synchronously NOW — iOS deletes `location` after this method returns
        let dest = DownloadManager.episodesDirectory.appendingPathComponent("\(episodeId).audio")
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: location, to: dest)
        } catch {
            print("Failed to save episode \(episodeId): \(error)")
            Task { @MainActor [self] in
                downloadProgress.removeValue(forKey: episodeId)
                episodeIdToTask.removeValue(forKey: episodeId)
            }
            taskMap.remove(taskId)
            return
        }

        // Update state on main actor
        Task { @MainActor [self] in
            locallyDownloaded.insert(episodeId)
            downloadProgress.removeValue(forKey: episodeId)
            episodeIdToTask.removeValue(forKey: episodeId)
            downloadingEpisodes.removeValue(forKey: episodeId)
            persistLocalDownloads()
        }
        taskMap.remove(taskId)
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0,
              let id = taskMap.get(downloadTask.taskIdentifier) else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor [self] in
            downloadProgress[id] = progress
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [self] in
            backgroundCompletionHandler?()
            backgroundCompletionHandler = nil
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let taskId = task.taskIdentifier
        guard let id = taskMap.get(taskId) else { return }
        print("Download failed for episode \(id): \(error.localizedDescription)")
        taskMap.remove(taskId)
        Task { @MainActor [self] in
            downloadProgress.removeValue(forKey: id)
            episodeIdToTask.removeValue(forKey: id)
            downloadingEpisodes.removeValue(forKey: id)
        }
    }
}

// MARK: - Thread-safe task identifier map

private final class TaskMap: @unchecked Sendable {
    private let lock = NSLock()
    private var dict: [Int: Int] = [:]

    func get(_ taskId: Int) -> Int? {
        lock.withLock { dict[taskId] }
    }

    func set(_ taskId: Int, episodeId: Int) {
        lock.withLock { dict[taskId] = episodeId }
        persist()
    }

    func remove(_ taskId: Int) {
        lock.withLock { _ = dict.removeValue(forKey: taskId) }
        persist()
    }

    func load() {
        let pairs = (UserDefaults.standard.array(forKey: "taskIdentifierToEpisodeId") as? [[Int]]) ?? []
        lock.withLock {
            dict = Dictionary(uniqueKeysWithValues: pairs.compactMap { p in
                p.count == 2 ? (p[0], p[1]) : nil
            })
        }
    }

    private func persist() {
        let pairs = lock.withLock { dict.map { [$0.key, $0.value] } }
        UserDefaults.standard.set(pairs, forKey: "taskIdentifierToEpisodeId")
    }
}
