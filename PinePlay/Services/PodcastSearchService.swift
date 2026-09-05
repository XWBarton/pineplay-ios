import Foundation

/// A podcast result from Apple's public iTunes Search API — used to find shows
/// to add to the Staging Ground. No API key or Pinepods server involvement needed.
struct PodcastSearchResult: Identifiable, Hashable {
    var id: Int
    var title: String
    var author: String?
    var artworkURL: String?
    var feedURL: String
    var episodeCount: Int?

    func toStagedPodcast() -> StagedPodcast {
        StagedPodcast(
            title: title, artworkURL: artworkURL, author: author, description: nil,
            feedURL: feedURL, episodeCount: episodeCount, podcastIndexId: id
        )
    }
}

enum PodcastSearchError: LocalizedError {
    case invalidQuery
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .invalidQuery: return "Enter something to search for."
        case .network(let e): return "Search failed: \(e.localizedDescription)"
        }
    }
}

final class PodcastSearchService {
    static let shared = PodcastSearchService()
    private init() {}

    private struct SearchResponse: Decodable {
        let results: [Result]
    }

    private struct Result: Decodable {
        let collectionId: Int?
        let collectionName: String?
        let artistName: String?
        let feedUrl: String?
        let artworkUrl600: String?
        let artworkUrl100: String?
        let trackCount: Int?
    }

    func search(term: String) async throws -> [PodcastSearchResult] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PodcastSearchError.invalidQuery }

        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: trimmed),
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "limit", value: "25")
        ]
        guard let url = components?.url else { throw PodcastSearchError.invalidQuery }

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(from: url)
        } catch {
            throw PodcastSearchError.network(error)
        }

        let decoded = (try? JSONDecoder().decode(SearchResponse.self, from: data)) ?? SearchResponse(results: [])
        return decoded.results.compactMap { result in
            guard let id = result.collectionId, let feedUrl = result.feedUrl,
                  let title = result.collectionName else { return nil }
            return PodcastSearchResult(
                id: id, title: title, author: result.artistName,
                artworkURL: result.artworkUrl600 ?? result.artworkUrl100,
                feedURL: feedUrl, episodeCount: result.trackCount
            )
        }
    }
}
