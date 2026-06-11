import AppIntents
import Foundation

// MARK: - Podcast Entity

struct PodcastEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Podcast")
    static var defaultQuery = PodcastEntityQuery()

    var id: Int
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct PodcastEntityQuery: EntityStringQuery {
    func entities(for identifiers: [Int]) async throws -> [PodcastEntity] {
        let podcasts = try await PinepodsAPIService.shared.getPodcasts()
        return podcasts
            .filter { identifiers.contains($0.id) }
            .map { PodcastEntity(id: $0.id, name: $0.name) }
    }

    func entities(matching string: String) async throws -> [PodcastEntity] {
        let podcasts = try await PinepodsAPIService.shared.getPodcasts()
        return podcasts
            .filter { $0.name.localizedCaseInsensitiveContains(string) }
            .map { PodcastEntity(id: $0.id, name: $0.name) }
    }

    func suggestedEntities() async throws -> [PodcastEntity] {
        let podcasts = try await PinepodsAPIService.shared.getPodcasts()
        return podcasts.map { PodcastEntity(id: $0.id, name: $0.name) }
    }
}

// MARK: - Shared helpers

private nonisolated func parseDate(_ string: String) -> Date? {
    let rfc = DateFormatter()
    rfc.locale = Locale(identifier: "en_US_POSIX")
    rfc.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
    let iso = DateFormatter()
    iso.locale = Locale(identifier: "en_US_POSIX")
    iso.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
    return [rfc, iso].lazy.compactMap { $0.date(from: string) }.first
}

private func latestEpisode(for podcast: PodcastEntity) async throws -> EpisodeItem {
    let episodes = try await PinepodsAPIService.shared.getPodcastEpisodes(podcastId: podcast.id)
    guard !episodes.isEmpty else { throw IntentError.noEpisodes(podcast.name) }
    return episodes.max(by: {
        (parseDate($0.pubDate) ?? .distantPast) < (parseDate($1.pubDate) ?? .distantPast)
    }) ?? episodes[0]
}

enum IntentError: LocalizedError {
    case noEpisodes(String)
    case nothingPlaying

    nonisolated var errorDescription: String? {
        switch self {
        case .noEpisodes(let name): return "No episodes found for \(name)"
        case .nothingPlaying: return "Nothing is currently playing in PinePlay"
        }
    }
}

// MARK: - 1. Play Latest Episode

struct PlayLatestEpisodeIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Latest Episode"
    static var description = IntentDescription("Plays the most recent episode of a podcast.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Podcast")
    var podcast: PodcastEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let episode = try await latestEpisode(for: podcast)
        await MainActor.run {
            AudioPlayerManager.shared.play(
                episode: episode,
                localURL: DownloadManager.shared.localURL(for: episode.id)
            )
        }
        return .result(dialog: "Playing \(episode.title) from \(podcast.name)")
    }
}

// MARK: - 2. Resume Playback

struct ResumePlaybackIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume PinePlay"
    static var description = IntentDescription("Resumes the last episode you were listening to.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        if let episode = await MainActor.run(body: { AudioPlayerManager.shared.currentEpisode }) {
            await AudioPlayerManager.shared.resume()
            return .result(dialog: "Resuming \(episode.title)")
        }
        if let data = UserDefaults.standard.data(forKey: "lastPlayingEpisode"),
           let episode = try? JSONDecoder().decode(EpisodeItem.self, from: data) {
            await MainActor.run {
                AudioPlayerManager.shared.play(
                    episode: episode,
                    localURL: DownloadManager.shared.localURL(for: episode.id)
                )
            }
            return .result(dialog: "Resuming \(episode.title)")
        }
        throw IntentError.nothingPlaying
    }
}

// MARK: - 3. What's New

struct WhatsNewIntent: AppIntent {
    static var title: LocalizedStringResource = "What's New in PinePlay"
    static var description = IntentDescription("Reads out your 3 most recent unplayed episodes.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let episodes = try await PinepodsAPIService.shared.getRecentEpisodes()
        let unplayed = episodes
            .filter { !$0.completed && ($0.listenDuration ?? 0) == 0 }
            .prefix(3)

        if unplayed.isEmpty {
            return .result(dialog: "You're all caught up — no new unplayed episodes.")
        }
        let lines = unplayed.enumerated().map { i, ep in
            "\(i + 1). \(ep.title) from \(ep.podcastName)"
        }
        return .result(dialog: "Here's what's new: \(lines.joined(separator: ". "))")
    }
}

// MARK: - 4. Add Latest Episode to Queue

struct AddLatestToQueueIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Latest Episode to Queue"
    static var description = IntentDescription("Adds the latest episode of a podcast to the end of your queue.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Podcast")
    var podcast: PodcastEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let episode = try await latestEpisode(for: podcast)
        await AudioPlayerManager.shared.addToQueue(episode)
        return .result(dialog: "Added \(episode.title) to your queue")
    }
}

// MARK: - 6. Download Latest Episode

struct DownloadLatestIntent: AppIntent {
    static var title: LocalizedStringResource = "Download Latest Episode"
    static var description = IntentDescription("Downloads the latest episode of a podcast for offline listening.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Podcast")
    var podcast: PodcastEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let episode = try await latestEpisode(for: podcast)
        try await PinepodsAPIService.shared.requestServerDownload(episodeId: episode.id, isYoutube: episode.isYoutube)
        return .result(dialog: "Downloading \(episode.title)")
    }
}

// MARK: - Shuffle Show Episodes

struct ShuffleShowIntent: AppIntent {
    static var title: LocalizedStringResource = "Shuffle Show Episodes"
    static var description = IntentDescription("Shuffles episodes of a podcast into your queue and starts playing.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Podcast")
    var podcast: PodcastEntity

    @Parameter(title: "Number of Episodes")
    var count: Int?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let episodes = try await PinepodsAPIService.shared.getPodcastEpisodes(podcastId: podcast.id)
        guard !episodes.isEmpty else { throw IntentError.noEpisodes(podcast.name) }
        let pool = episodes.filter { !$0.completed }
        let source = pool.isEmpty ? episodes : pool
        let limit = count ?? 10
        let shuffled = Array(source.shuffled().prefix(limit))

        await MainActor.run {
            let player = AudioPlayerManager.shared
            player.queue = Array(shuffled.dropFirst())
            player.play(
                episode: shuffled[0],
                localURL: DownloadManager.shared.localURL(for: shuffled[0].id)
            )
        }
        let actual = shuffled.count
        return .result(dialog: "Shuffling \(actual) episode\(actual == 1 ? "" : "s") of \(podcast.name)")
    }
}

// MARK: - Play Next

struct PlayNextIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Episode Next"
    static var description = IntentDescription("Adds the latest episode of a podcast to play next in your queue.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Podcast")
    var podcast: PodcastEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let episode = try await latestEpisode(for: podcast)
        await AudioPlayerManager.shared.playEpisodeNext(episode)
        return .result(dialog: "Added \(episode.title) to play next")
    }
}

// MARK: - App Shortcuts (Siri Phrases)

struct PinePlayShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayLatestEpisodeIntent(),
            phrases: [
                "Play latest \(\.$podcast) in \(.applicationName)",
                "Play newest \(\.$podcast) in \(.applicationName)",
            ],
            shortTitle: "Play Latest Episode",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: ResumePlaybackIntent(),
            phrases: [
                "Resume \(.applicationName)",
                "Continue listening in \(.applicationName)",
            ],
            shortTitle: "Resume",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: WhatsNewIntent(),
            phrases: [
                "What's new in \(.applicationName)",
                "New episodes in \(.applicationName)",
            ],
            shortTitle: "What's New",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: AddLatestToQueueIntent(),
            phrases: [
                "Add latest \(\.$podcast) to \(.applicationName) queue",
                "Queue latest \(\.$podcast) in \(.applicationName)",
            ],
            shortTitle: "Add to Queue",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: DownloadLatestIntent(),
            phrases: [
                "Download latest \(\.$podcast) in \(.applicationName)",
            ],
            shortTitle: "Download Latest",
            systemImageName: "arrow.down.circle"
        )
        AppShortcut(
            intent: ShuffleShowIntent(),
            phrases: [
                "Shuffle \(\.$podcast) in \(.applicationName)",
                "Shuffle \(\.$podcast) episodes in \(.applicationName)",
            ],
            shortTitle: "Shuffle Show",
            systemImageName: "shuffle"
        )
        AppShortcut(
            intent: PlayNextIntent(),
            phrases: [
                "Play \(\.$podcast) next in \(.applicationName)",
                "Add \(\.$podcast) to play next in \(.applicationName)",
            ],
            shortTitle: "Play Next",
            systemImageName: "text.insert"
        )
    }
}
