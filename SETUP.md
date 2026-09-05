# PinePods iOS App — Xcode Setup

## Requirements

- iOS 26+
- Xcode 26+ (Swift 5)

## Create the Xcode Project

1. Open Xcode → **File > New > Project**
2. Choose **iOS → App**
3. Set:
   - Product Name: `PinePlay`
   - Bundle Identifier: `com.yourname.pineplay` (or any unique ID)
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Uncheck "Include Tests" for now
4. Save into the `pineplayer` folder

## Add Source Files

Delete the auto-generated `ContentView.swift` and `<AppName>App.swift` from the project.

Then drag all folders from `PinePlay/` into the Xcode project navigator:
- `App/` — PinePodsApp.swift, ContentView.swift
- `Intents/` — SiriIntents.swift
- `Models/` — Models.swift
- `Services/` — PinepodsAPIService.swift, AudioPlayerManager.swift, DownloadManager.swift, ChaptersService.swift, NetworkMonitor.swift, PodcastFeedParser.swift, PodcastSearchService.swift
- `Views/Auth/` — ServerSetupView.swift, SettingsView.swift
- `Views/Library/` — LibraryView.swift, PodcastDetailView.swift, DownloadsView.swift, StagingGroundView.swift
- `Views/Feed/` — FeedView.swift
- `Views/Player/` — PlayerView.swift
- `Views/Shared/` — EpisodeRowView.swift, PodcastArtworkView.swift

Make sure "Copy items if needed" is **unchecked** (files are already in place).

## Replace Info.plist

Replace your project's `Info.plist` with the one provided, or manually add:

```xml
<!-- Required entries -->
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
    <string>fetch</string>
</array>
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
</dict>
```

> **Note:** `NSAllowsArbitraryLoads` is needed if your Pinepods server uses HTTP or a self-signed HTTPS cert.
> For production, use HTTPS and restrict to your server domain instead.

## Build & Run

Select a simulator or your iPhone, then press **Run (⌘R)**.

## Features

### Library Tab
- Grid view of all your subscribed podcasts
- Tap a podcast to see its episodes
- Swipe left on an episode to mark as played
- Tap the download button to save locally to your iPhone
- Shuffle a show's episodes into the queue or into downloads
- Staging Ground strip — search by name or paste an RSS URL to preview a show and play it locally before subscribing

### Feed Tab
- Latest episodes across all subscribed podcasts
- Swipe right to download, left to mark played
- Pull to refresh
- Continue Listening strip for in-progress episodes, swipe to dismiss

### Player Tab
- Full-screen player with artwork
- Scrub bar with elapsed / remaining time
- Skip back 15s / skip forward 30s
- Playback speed control and sleep timer
- Parsed chapters with tap-to-seek
- Play queue — add, reorder, play next, auto-advance, persists across app kills
- Lock screen & AirPods controls, including hold-to-fast-forward/rewind
- Download button in top-right to save offline

### Downloads (from Library)
- Sort by newest / oldest / show
- Live download progress with cancel
- Multi-select delete and total storage usage shown

### Settings (gear icon in Library)
- Auto-download new episodes (Wi-Fi only option, per-show selection, max-episodes-per-show cap)
- Offline Mode toggle (hide non-downloaded episodes, skip network calls); also auto-engages when disconnected
- Per-show accent colours with a built-in colour picker and eyedropper
- View local storage usage
- Log out / change server

### Siri Shortcuts
- Play a show's latest episode, resume playback, hear what's new, add to queue, play next, shuffle a show, or download the latest episode — by podcast name

## API Endpoints Used

| Feature | Endpoint |
|---------|----------|
| Login | `GET /api/data/get_key` (Basic Auth) |
| Podcasts | `GET /api/data/return_pods/{user_id}` |
| Subscribe to podcast | `POST /api/data/add_podcast` |
| Feed | `GET /api/data/return_episodes/{user_id}` |
| Podcast episodes | `GET /api/data/podcast_episodes?user_id=&podcast_id=` |
| Server downloads list | `GET /api/data/download_episode_list?user_id=` |
| Request server download | `POST /api/data/download_podcast` |
| Delete server download | `POST /api/data/delete_episode` |
| Save progress | `POST /api/data/update_episode_duration` |
| Mark completed | `POST /api/data/mark_episode_completed` |
| Mark uncompleted | `POST /api/data/mark_episode_uncompleted` |
| Record history | `POST /api/data/record_podcast_history` |

Authentication uses `Api-Key: <key>` header on all data requests.
