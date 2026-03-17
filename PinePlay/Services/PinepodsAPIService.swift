import Combine
import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case authFailed
    case mfaRequired
    case notAuthenticated
    case networkError(Error)
    case serverError(Int)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid server URL"
        case .authFailed: return "Invalid username or password"
        case .mfaRequired: return "MFA is required. Please log in via the web interface first."
        case .notAuthenticated: return "Not authenticated. Please configure your server."
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .serverError(let code): return "Server error (\(code))"
        case .decodingError(let e): return "Failed to parse server response: \(e.localizedDescription)"
        }
    }
}

@MainActor
class PinepodsAPIService: ObservableObject {
    static let shared = PinepodsAPIService()

    @Published var isAuthenticated = false
    @Published var config: ServerConfig?

    private let session = URLSession.shared

    init() {
        config = ServerConfig.load()
        isAuthenticated = config != nil
    }

    // MARK: - Auth

    func login(serverURL: String, username: String, password: String) async throws {
        let base = serverURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let url = URL(string: "\(base)/api/data/get_key") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let credData = "\(username):\(password)".data(using: .utf8) {
            request.setValue("Basic \(credData.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }

        let data = try await fetch(request)
        let response = try decode(LoginResponse.self, from: data)

        if response.mfa_required == true { throw APIError.mfaRequired }
        guard let apiKey = response.retrieved_key, let userId = response.user_id else {
            throw APIError.authFailed
        }

        let cfg = ServerConfig(serverURL: base, apiKey: apiKey, userId: userId, username: username)
        cfg.save()
        self.config = cfg
        self.isAuthenticated = true
    }

    func logout() {
        ServerConfig.clear()
        config = nil
        isAuthenticated = false
    }

    // MARK: - Podcasts

    func getPodcasts() async throws -> [PodcastItem] {
        let cfg = try requireConfig()
        let data = try await get("\(cfg.serverURL)/api/data/return_pods/\(cfg.userId)")
        return try decode(PodcastListResponse.self, from: data).pods.map { $0.toPodcastItem() }
    }

    func getPodcastEpisodes(podcastId: Int) async throws -> [EpisodeItem] {
        let cfg = try requireConfig()
        let data = try await get(
            "\(cfg.serverURL)/api/data/podcast_episodes",
            params: ["user_id": "\(cfg.userId)", "podcast_id": "\(podcastId)"]
        )
        return try decode(PodcastEpisodesListResponse.self, from: data).episodes.map { $0.toEpisodeItem() }
    }

    func getRecentEpisodes() async throws -> [EpisodeItem] {
        let cfg = try requireConfig()
        let data = try await get("\(cfg.serverURL)/api/data/return_episodes/\(cfg.userId)")
        return try decode(EpisodesListResponse.self, from: data).episodes.map { $0.toEpisodeItem() }
    }

    func getInProgressEpisodes() async throws -> [EpisodeItem] {
        let cfg = try requireConfig()
        let data = try await get("\(cfg.serverURL)/api/data/return_episodes/\(cfg.userId)")
        let all = try decode(EpisodesListResponse.self, from: data).episodes.map { $0.toEpisodeItem() }
        return all.filter { ($0.listenDuration ?? 0) > 0 && !$0.completed }
    }

    func getServerDownloadedEpisodes() async throws -> [EpisodeItem] {
        let cfg = try requireConfig()
        let data = try await get(
            "\(cfg.serverURL)/api/data/download_episode_list",
            params: ["user_id": "\(cfg.userId)"]
        )
        return try decode(DownloadedEpisodesListResponse.self, from: data).downloaded_episodes.map { $0.toEpisodeItem() }
    }

    // MARK: - Episode Actions

    func requestServerDownload(episodeId: Int, isYoutube: Bool = false) async throws {
        let cfg = try requireConfig()
        try await post(
            "\(cfg.serverURL)/api/data/download_podcast",
            body: ["episode_id": episodeId, "user_id": cfg.userId, "is_youtube": isYoutube]
        )
    }

    func deleteServerDownload(episodeId: Int, isYoutube: Bool = false) async throws {
        let cfg = try requireConfig()
        try await post(
            "\(cfg.serverURL)/api/data/delete_episode",
            body: ["episode_id": episodeId, "user_id": cfg.userId, "is_youtube": isYoutube]
        )
    }

    func markEpisodeUncompleted(episodeId: Int, isYoutube: Bool = false) async throws {
        let cfg = try requireConfig()
        try await post(
            "\(cfg.serverURL)/api/data/mark_episode_uncompleted",
            body: ["episode_id": episodeId, "user_id": cfg.userId, "is_youtube": isYoutube]
        )
    }

    func markEpisodeCompleted(episodeId: Int, isYoutube: Bool = false) async throws {
        let cfg = try requireConfig()
        try await post(
            "\(cfg.serverURL)/api/data/mark_episode_completed",
            body: ["episode_id": episodeId, "user_id": cfg.userId, "is_youtube": isYoutube]
        )
    }

    func updateEpisodeProgress(episodeId: Int, listenDuration: Int, isYoutube: Bool = false) async throws {
        let cfg = try requireConfig()
        try await post(
            "\(cfg.serverURL)/api/data/update_episode_duration",
            body: ["episode_id": episodeId, "user_id": cfg.userId,
                   "listen_duration": listenDuration, "is_youtube": isYoutube]
        )
    }

    func recordHistory(episodeId: Int, isYoutube: Bool = false) async throws {
        let cfg = try requireConfig()
        try await post(
            "\(cfg.serverURL)/api/data/record_podcast_history",
            body: ["episode_id": episodeId, "user_id": cfg.userId, "is_youtube": isYoutube]
        )
    }

    // MARK: - Private helpers

    private func requireConfig() throws -> ServerConfig {
        guard let cfg = config else { throw APIError.notAuthenticated }
        return cfg
    }

    private func get(_ path: String, params: [String: String] = [:]) async throws -> Data {
        let cfg = try requireConfig()
        var components = URLComponents(string: path)
        if !params.isEmpty {
            components?.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue(cfg.apiKey, forHTTPHeaderField: "Api-Key")
        return try await fetch(request)
    }

    @discardableResult
    private func post(_ path: String, body: [String: Any]) async throws -> Data {
        let cfg = try requireConfig()
        guard let url = URL(string: path) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(cfg.apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await fetch(request)
    }

    private func fetch(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.networkError(URLError(.badServerResponse)) }
            guard (200...299).contains(http.statusCode) else { throw APIError.serverError(http.statusCode) }
            return data
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.networkError(error)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }
}
