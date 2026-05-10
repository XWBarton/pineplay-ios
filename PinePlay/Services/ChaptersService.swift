import Foundation

// MARK: - Podcast Feed URL Registry
// Maps podcast name → RSS feed URL so ChaptersService can look up the feed
// for any episode. Populated whenever PodcastItems are loaded.

final class PodcastFeedURLRegistry {
    static let shared = PodcastFeedURLRegistry()
    private var registry: [String: String] = [:]
    private init() {}

    func register(_ feedURL: String, for podcastName: String) {
        registry[podcastName] = feedURL
    }

    func feedURL(for podcastName: String) -> String? {
        registry[podcastName]
    }
}

// MARK: - Chapters Service

@MainActor
final class ChaptersService {
    static let shared = ChaptersService()

    private var cache: [Int: [Chapter]] = [:]   // episodeId → chapters (empty array = "checked, none")
    private init() {}

    /// Fetches and returns chapters for the episode. Results are cached.
    func fetchChapters(for episode: EpisodeItem) async -> [Chapter] {
        if let cached = cache[episode.id] { return cached }

        guard let feedURLString = PodcastFeedURLRegistry.shared.feedURL(for: episode.podcastName),
              let feedURL = URL(string: feedURLString) else {
            return []
        }

        guard let (rssData, _) = try? await URLSession.shared.data(from: feedURL) else {
            return []
        }

        guard let chaptersURLString = parseChaptersURL(from: rssData, episodeURL: episode.url),
              let chaptersURL = URL(string: chaptersURLString) else {
            cache[episode.id] = []
            return []
        }

        guard let (chaptersData, _) = try? await URLSession.shared.data(from: chaptersURL) else {
            cache[episode.id] = []
            return []
        }

        let chapters = parseChaptersJSON(chaptersData)
        cache[episode.id] = chapters
        return chapters
    }

    func clearCache(for episodeId: Int) {
        cache.removeValue(forKey: episodeId)
    }

    // MARK: - Private

    private func parseChaptersURL(from data: Data, episodeURL: String) -> String? {
        RSSChaptersParser(targetEpisodeURL: episodeURL).parse(data: data)
    }

    private func parseChaptersJSON(_ data: Data) -> [Chapter] {
        struct Root: Decodable { let chapters: [ChapterJSON] }
        struct ChapterJSON: Decodable {
            let startTime: Double
            let title: String?
            let img: String?
            let url: String?
            let toc: Bool?
        }

        guard let root = try? JSONDecoder().decode(Root.self, from: data) else { return [] }

        return root.chapters
            .filter { $0.toc != false }
            .map { Chapter(startTime: $0.startTime, title: $0.title ?? "Chapter", imageURL: $0.img, linkURL: $0.url) }
            .sorted { $0.startTime < $1.startTime }
    }
}

// MARK: - RSS XML Parser

/// SAX-style parser that walks the RSS feed and finds the `podcast:chapters` URL
/// for the item whose `<enclosure>` matches the target episode audio URL.
private final class RSSChaptersParser: NSObject, XMLParserDelegate {
    private let targetURL: String
    private var inItem = false
    private var currentEnclosureURL: String?
    private var currentChaptersURL: String?
    private(set) var result: String?

    init(targetEpisodeURL: String) {
        self.targetURL = targetEpisodeURL
    }

    func parse(data: Data) -> String? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        parser.parse()
        return result
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String] = [:]
    ) {
        switch elementName {
        case "item":
            inItem = true
            currentEnclosureURL = nil
            currentChaptersURL = nil

        case "enclosure" where inItem:
            currentEnclosureURL = attributes["url"]

        case "chapters" where inItem:
            // Accept any chapters element in a podcast-ish namespace
            let isPodcastNS = namespaceURI?.contains("podcastindex") == true
                || namespaceURI?.contains("podcast") == true
            let isJsonType = attributes["type"].map {
                $0 == "application/json+chapters" || $0.contains("json")
            } ?? true   // assume JSON if type is absent (some feeds omit it)
            if isPodcastNS && isJsonType {
                currentChaptersURL = attributes["url"]
            }

        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard elementName == "item" else { return }
        inItem = false

        if let enclosure = currentEnclosureURL,
           urlsMatch(enclosure, targetURL),
           let chaptersURL = currentChaptersURL {
            result = chaptersURL
            parser.abortParsing()   // found what we need — stop early
        }
    }

    private func urlsMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        func stripQuery(_ s: String) -> String {
            guard let url = URL(string: s) else { return s }
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
            c?.query = nil
            return c?.string ?? s
        }
        return stripQuery(a) == stripQuery(b)
    }
}
