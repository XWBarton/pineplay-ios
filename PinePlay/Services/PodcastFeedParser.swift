import Foundation

// MARK: - Parsed Feed Models

/// A podcast RSS feed parsed directly off the wire — used for shows in the
/// Staging Ground that aren't subscribed on the Pinepods server yet, so there's
/// no server-side episode list to fetch.
struct ParsedFeed {
    var title: String
    var description: String?
    var author: String?
    var artworkURL: String?
    var website: String?
    var explicit: Bool
    var episodes: [ParsedFeedEpisode]
}

struct ParsedFeedEpisode: Identifiable, Hashable {
    var id: String { guid }
    var guid: String
    var title: String
    var pubDate: String   // normalized to "yyyy-MM-dd HH:mm:ss" where possible
    var description: String
    var artworkURL: String?
    var audioURL: String
    var duration: Int

    /// Builds a synthetic EpisodeItem for local (non-Pinepods) playback, browsing,
    /// or download. The id is a deterministic hash of the guid — unique enough to
    /// avoid colliding with real server episode ids (always positive), and stable
    /// across app relaunches so downloaded files stay matched to their id.
    ///
    /// Swift's built-in `Hasher` is seeded randomly per process launch (by design,
    /// to resist hash-flooding), so it must NOT be used here — a downloaded
    /// episode's id would change on the next launch and orphan its file.
    func toEpisodeItem(podcastName: String, fallbackArtwork: String?) -> EpisodeItem {
        let syntheticId = -Self.stableId(for: guid)
        return EpisodeItem(
            id: syntheticId, podcastName: podcastName, title: title, pubDate: pubDate,
            description: description, artwork: artworkURL ?? fallbackArtwork ?? "",
            url: audioURL, duration: duration, listenDuration: nil, completed: false,
            saved: false, queued: false, downloaded: false, isYoutube: false
        )
    }

    /// FNV-1a over the guid's UTF-8 bytes — deterministic across runs, unlike `Hasher`.
    private static func stableId(for string: String) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return Int(hash % 1_000_000_000) + 1
    }
}

enum FeedParseError: LocalizedError {
    case invalidURL
    case network(Error)
    case noEpisodes

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "That doesn't look like a valid feed URL."
        case .network(let e): return "Couldn't load the feed: \(e.localizedDescription)"
        case .noEpisodes: return "This feed doesn't have any episodes."
        }
    }
}

// MARK: - Feed Fetch Service

final class PodcastFeedService {
    static let shared = PodcastFeedService()
    private init() {}

    func fetchFeed(url: String) async throws -> ParsedFeed {
        guard let feedURL = URL(string: url) else { throw FeedParseError.invalidURL }
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(from: feedURL)
        } catch {
            throw FeedParseError.network(error)
        }
        let feed = RSSFeedParser().parse(data: data)
        return feed
    }

    /// Fetches one subscribed show's episodes straight from its RSS feed,
    /// bypassing the Pinepods server entirely — used when the server is
    /// unreachable but the podcast host's own feed still is.
    func fetchEpisodes(for podcast: PodcastItem) async -> [EpisodeItem] {
        guard let feed = try? await fetchFeed(url: podcast.feedURL) else { return [] }
        return feed.episodes.map {
            $0.toEpisodeItem(podcastName: podcast.name, fallbackArtwork: podcast.artworkURL)
        }
    }

    /// Fetches recent episodes across every given (cached) subscription directly
    /// from RSS, in parallel, for the server-unreachable fallback feed. Caps how
    /// many episodes are kept per show so a large library doesn't hammer cellular.
    func fetchRecentEpisodes(from podcasts: [PodcastItem], perShowLimit: Int = 10) async -> [EpisodeItem] {
        await withTaskGroup(of: [EpisodeItem].self) { group in
            for podcast in podcasts {
                group.addTask {
                    let episodes = await self.fetchEpisodes(for: podcast)
                    return Array(episodes.sorted { $0.pubDate > $1.pubDate }.prefix(perShowLimit))
                }
            }
            var all: [EpisodeItem] = []
            for await episodes in group { all.append(contentsOf: episodes) }
            return all.sorted { $0.pubDate > $1.pubDate }
        }
    }
}

// MARK: - RSS XML Parser

/// SAX-style parser for standard podcast RSS 2.0 feeds (with iTunes/Podcasting 2.0
/// extensions). Namespaces are left unprocessed so tags read as e.g. "itunes:image".
private final class RSSFeedParser: NSObject, XMLParserDelegate {
    private var channelTitle = ""
    private var channelDescription = ""
    private var channelAuthor: String?
    private var channelImage: String?
    private var channelWebsite: String?
    private var channelExplicit = false

    private var episodes: [ParsedFeedEpisode] = []

    private var currentText = ""
    private var inItem = false
    private var inImageTag = false

    private var itemTitle = ""
    private var itemDescription = ""
    private var itemPubDate = ""
    private var itemGUID = ""
    private var itemAudioURL: String?
    private var itemDuration = 0
    private var itemImage: String?

    func parse(data: Data) -> ParsedFeed {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.parse()
        return ParsedFeed(
            title: channelTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            description: nonEmpty(channelDescription),
            author: channelAuthor,
            artworkURL: channelImage,
            website: channelWebsite,
            explicit: channelExplicit,
            episodes: episodes
        )
    }

    private func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        currentText = ""
        switch elementName {
        case "item":
            inItem = true
            itemTitle = ""; itemDescription = ""; itemPubDate = ""; itemGUID = ""
            itemAudioURL = nil; itemDuration = 0; itemImage = nil
        case "enclosure" where inItem:
            itemAudioURL = attributeDict["url"]
        case "itunes:image":
            let href = attributeDict["href"]
            if inItem {
                itemImage = href
            } else if channelImage == nil {
                channelImage = href
            }
        case "image":
            inImageTag = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "title":
            if inItem {
                itemTitle = text
            } else if !inImageTag {
                channelTitle = text
            }
        case "description", "itunes:summary":
            if inItem {
                if itemDescription.isEmpty { itemDescription = text }
            } else if channelDescription.isEmpty {
                channelDescription = text
            }
        case "pubDate":
            if inItem { itemPubDate = normalizeDate(text) }
        case "guid":
            if inItem { itemGUID = text }
        case "itunes:duration":
            if inItem { itemDuration = Self.parseDuration(text) }
        case "itunes:author", "author", "managingEditor":
            if !inItem && channelAuthor == nil { channelAuthor = text }
        case "link":
            if !inItem && !inImageTag && channelWebsite == nil { channelWebsite = text }
        case "url":
            if inImageTag && channelImage == nil { channelImage = text }
        case "itunes:explicit":
            if !inItem { channelExplicit = ["yes", "true", "explicit"].contains(text.lowercased()) }
        case "image":
            inImageTag = false
        case "item":
            inItem = false
            if let audioURL = itemAudioURL, !itemTitle.isEmpty {
                episodes.append(ParsedFeedEpisode(
                    guid: itemGUID.isEmpty ? audioURL : itemGUID,
                    title: itemTitle,
                    pubDate: itemPubDate,
                    description: itemDescription,
                    artworkURL: itemImage,
                    audioURL: audioURL,
                    duration: itemDuration
                ))
            }
        default:
            break
        }
        currentText = ""
    }

    /// iTunes durations show up as plain seconds ("1800") or "HH:MM:SS" / "MM:SS".
    private static func parseDuration(_ s: String) -> Int {
        let parts = s.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty else { return Int(Double(s) ?? 0) }
        return parts.reversed().enumerated().reduce(0) { total, pair in
            total + pair.element * Int(pow(60.0, Double(pair.offset)))
        }
    }

    // Instance-level (not static): DateFormatter isn't thread-safe, and a fresh
    // RSSFeedParser is created per parse, so sharing formatters across instances
    // would race if two feeds are parsed concurrently.
    private let inputFormats = [
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "dd MMM yyyy HH:mm:ss Z",
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss"
    ].map { fmt -> DateFormatter in
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = fmt
        return df
    }

    private let outputFormat: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df
    }()

    /// Reformats RFC-822-ish RSS dates to "yyyy-MM-dd HH:mm:ss" so they sort and
    /// display (`pubDate.prefix(10)`) the same way as server-supplied dates.
    private func normalizeDate(_ raw: String) -> String {
        for formatter in inputFormats {
            if let date = formatter.date(from: raw) {
                return outputFormat.string(from: date)
            }
        }
        return raw
    }
}
