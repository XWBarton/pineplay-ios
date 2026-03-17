import Foundation
import UIKit
import SwiftUI

// MARK: - Image Cache (memory + disk)

final class ImageCache {
    static let shared = ImageCache()

    private let memory: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 80
        c.totalCostLimit = 30 * 1024 * 1024  // 30 MB
        return c
    }()

    private let diskDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArtworkCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Strip query string so token-expiring CDN URLs (Patreon etc.) still hit the cache
    private func stableKey(for urlString: String) -> String {
        URL(string: urlString).flatMap { url in
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
            c?.query = nil
            return c?.string
        } ?? urlString
    }

    private func diskURL(for key: String) -> URL {
        let safe = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        let name = String(safe.suffix(120))
        return diskDir.appendingPathComponent(name + ".jpg")
    }

    func get(_ key: String) -> UIImage? {
        let k = stableKey(for: key)
        if let img = memory.object(forKey: k as NSString) { return img }
        let url = diskURL(for: k)
        guard let data = try? Data(contentsOf: url), let img = UIImage(data: data) else { return nil }
        memory.setObject(img, forKey: k as NSString)
        return img
    }

    func set(_ image: UIImage, for key: String) {
        let k = stableKey(for: key)
        // Pass pixel memory footprint as cost so totalCostLimit is actually enforced
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        memory.setObject(image, forKey: k as NSString, cost: cost)
        let url = diskURL(for: k)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        if let data = image.jpegData(compressionQuality: 0.85) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Server Config

struct ServerConfig: Codable {
    var serverURL: String
    var apiKey: String
    var userId: Int
    var username: String

    static func load() -> ServerConfig? {
        guard let data = UserDefaults.standard.data(forKey: "serverConfig"),
              let config = try? JSONDecoder().decode(ServerConfig.self, from: data) else {
            return nil
        }
        return config
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "serverConfig")
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: "serverConfig")
    }
}

// MARK: - Domain Models

struct PodcastItem: Identifiable, Hashable {
    let id: Int
    let name: String
    let artworkURL: String?
    let description: String?
    let episodeCount: Int?
    let author: String?
    let feedURL: String
}

struct EpisodeItem: Identifiable, Hashable, Codable {
    let id: Int
    let podcastName: String
    let title: String
    let pubDate: String
    let description: String
    let artwork: String
    let url: String
    let duration: Int
    var listenDuration: Int?
    var completed: Bool
    var saved: Bool
    var queued: Bool
    var downloaded: Bool
    var isYoutube: Bool

    var progress: Double {
        guard let listened = listenDuration, duration > 0 else { return 0 }
        return min(1.0, Double(listened) / Double(duration))
    }

    var formattedDuration: String {
        let h = duration / 3600
        let m = (duration % 3600) / 60
        let s = duration % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    var formattedCurrentTime: String {
        let t = listenDuration ?? 0
        let h = t / 3600
        let m = (t % 3600) / 60
        let s = t % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - API Response Models

struct LoginResponse: Decodable {
    let status: String
    let retrieved_key: String?
    let user_id: Int?
    let mfa_required: Bool?
}

struct PodcastListResponse: Decodable {
    let pods: [PodcastResponse]
}

struct PodcastResponse: Decodable {
    let podcastid: Int
    let podcastname: String
    let artworkurl: String?
    let description: String?
    let episodecount: Int?
    let author: String?
    let feedurl: String

    func toPodcastItem() -> PodcastItem {
        PodcastItem(
            id: podcastid,
            name: podcastname,
            artworkURL: artworkurl,
            description: description,
            episodeCount: episodecount,
            author: author,
            feedURL: feedurl
        )
    }
}

// Feed episodes — all lowercase keys
struct EpisodeResponse: Decodable {
    let episodeid: Int
    let podcastname: String
    let episodetitle: String
    let episodepubdate: String
    let episodedescription: String
    let episodeartwork: String
    let episodeurl: String
    let episodeduration: Int
    let listenduration: Int?
    let completed: Bool
    let saved: Bool
    let queued: Bool
    let downloaded: Bool
    let is_youtube: Bool

    func toEpisodeItem() -> EpisodeItem {
        EpisodeItem(
            id: episodeid, podcastName: podcastname, title: episodetitle,
            pubDate: episodepubdate, description: episodedescription,
            artwork: episodeartwork, url: episodeurl, duration: episodeduration,
            listenDuration: listenduration, completed: completed, saved: saved,
            queued: queued, downloaded: downloaded, isYoutube: is_youtube
        )
    }
}

struct EpisodesListResponse: Decodable {
    let episodes: [EpisodeResponse]
}

// Podcast-specific episodes — mixed-case keys from API
struct PodcastEpisodeResponse: Decodable {
    enum CodingKeys: String, CodingKey {
        case podcastname
        case episodetitle = "Episodetitle"
        case episodepubdate = "Episodepubdate"
        case episodedescription = "Episodedescription"
        case episodeartwork = "Episodeartwork"
        case episodeurl = "Episodeurl"
        case episodeduration = "Episodeduration"
        case listenduration = "Listenduration"
        case episodeid = "Episodeid"
        case completed = "Completed"
        case saved, queued, downloaded, is_youtube
    }

    let episodeid: Int
    let podcastname: String
    let episodetitle: String
    let episodepubdate: String
    let episodedescription: String
    let episodeartwork: String
    let episodeurl: String
    let episodeduration: Int
    let listenduration: Int?
    let completed: Bool
    let saved: Bool
    let queued: Bool
    let downloaded: Bool
    let is_youtube: Bool

    func toEpisodeItem() -> EpisodeItem {
        EpisodeItem(
            id: episodeid, podcastName: podcastname, title: episodetitle,
            pubDate: episodepubdate, description: episodedescription,
            artwork: episodeartwork, url: episodeurl, duration: episodeduration,
            listenDuration: listenduration, completed: completed, saved: saved,
            queued: queued, downloaded: downloaded, isYoutube: is_youtube
        )
    }
}

struct PodcastEpisodesListResponse: Decodable {
    let episodes: [PodcastEpisodeResponse]
}

// Downloaded episodes from server
struct DownloadedEpisodeResponse: Decodable {
    let podcastid: Int
    let podcastname: String
    let artworkurl: String?
    let episodeid: Int
    let episodetitle: String
    let episodepubdate: String
    let episodedescription: String
    let episodeartwork: String?
    let episodeurl: String
    let episodeduration: Int
    let downloadedlocation: String
    let listenduration: Int?
    let completed: Bool
    let saved: Bool
    let queued: Bool
    let downloaded: Bool
    let is_youtube: Bool

    func toEpisodeItem() -> EpisodeItem {
        EpisodeItem(
            id: episodeid, podcastName: podcastname, title: episodetitle,
            pubDate: episodepubdate, description: episodedescription,
            artwork: episodeartwork ?? artworkurl ?? "",
            url: episodeurl, duration: episodeduration,
            listenDuration: listenduration, completed: completed, saved: saved,
            queued: queued, downloaded: true, isYoutube: is_youtube
        )
    }
}

struct DownloadedEpisodesListResponse: Decodable {
    let downloaded_episodes: [DownloadedEpisodeResponse]
}

// MARK: - Podcast Accent Colours

struct PodcastAccentColors {
    private static let key = "podcastAccentColors"

    static func load() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    static func save(_ colors: [String: String]) {
        UserDefaults.standard.set(colors, forKey: key)
    }

    static func color(for podcastName: String) -> Color? {
        guard let hex = load()[podcastName] else { return nil }
        return Color(hex: hex)
    }
}

extension Color {
    init?(hex: String) {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6, let value = UInt64(h, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: nil)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

// MARK: - Auto-download settings

struct AutoDownloadSettings: Codable {
    var enabled: Bool = false
    var onWifiOnly: Bool = true
    var maxEpisodes: Int = 3
    /// When true, download from all shows. When false, only download from selectedPodcastNames.
    var downloadAllShows: Bool = true
    var selectedPodcastNames: Set<String> = []

    static func load() -> AutoDownloadSettings {
        guard let data = UserDefaults.standard.data(forKey: "autoDownloadSettings"),
              let settings = try? JSONDecoder().decode(AutoDownloadSettings.self, from: data) else {
            return AutoDownloadSettings()
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "autoDownloadSettings")
        }
    }
}
