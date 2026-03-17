import SwiftUI
import UIKit
import BackgroundTasks

private let feedRefreshIdentifier = "com.pinepods.feed.refresh"

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: feedRefreshIdentifier, using: nil) { task in
            Self.handleFeedRefresh(task: task as! BGAppRefreshTask)
        }
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if identifier == "com.pinepods.episode.downloads" {
            DownloadManager.shared.backgroundCompletionHandler = completionHandler
        }
    }

    static func scheduleFeedRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: feedRefreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)  // 1 hour
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handleFeedRefresh(task: BGAppRefreshTask) {
        scheduleFeedRefresh()  // reschedule next run

        let fetchTask = Task {
            let api = PinepodsAPIService.shared
            let downloads = DownloadManager.shared
            if let episodes = try? await api.getRecentEpisodes() {
                await MainActor.run {
                    downloads.autoDownloadNewEpisodes(episodes)
                }
            }
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            fetchTask.cancel()
            task.setTaskCompleted(success: false)
        }
    }
}

@main
struct PinePodsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var api = PinepodsAPIService.shared
    @StateObject private var player = AudioPlayerManager.shared
    @StateObject private var downloads = DownloadManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if api.isAuthenticated {
                    ContentView()
                } else {
                    ServerSetupView()
                }
            }
            .environmentObject(api)
            .environmentObject(player)
            .environmentObject(downloads)
            .tint(player.artworkAccent)
            .onAppear {
                player.onEpisodeCompleted = { episode in
                    Task {
                        try? await api.markEpisodeCompleted(episodeId: episode.id, isYoutube: episode.isYoutube)
                    }
                }
                AppDelegate.scheduleFeedRefresh()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                // Save progress immediately when app backgrounds
                player.saveProgressNow()
                AppDelegate.scheduleFeedRefresh()
            }
        }
    }
}
