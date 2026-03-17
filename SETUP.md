# PinePods iOS App — Xcode Setup

## Create the Xcode Project

1. Open Xcode → **File > New > Project**
2. Choose **iOS → App**
3. Set:
   - Product Name: `PinePods`
   - Bundle Identifier: `com.yourname.pinepods` (or any unique ID)
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Uncheck "Include Tests" for now
4. Save into the `pineplayer` folder

## Add Source Files

Delete the auto-generated `ContentView.swift` and `<AppName>App.swift` from the project.

Then drag all folders from `PinePods/` into the Xcode project navigator:
- `App/` — PinePodsApp.swift, ContentView.swift
- `Models/` — Models.swift
- `Services/` — PinepodsAPIService.swift, AudioPlayerManager.swift, DownloadManager.swift
- `Views/Auth/` — ServerSetupView.swift, SettingsView.swift
- `Views/Library/` — LibraryView.swift, PodcastDetailView.swift
- `Views/Feed/` — FeedView.swift
- `Views/Player/` — PlayerView.swift, MiniPlayerView.swift
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

### Feed Tab
- Latest episodes across all subscribed podcasts
- Swipe right to download, left to mark played
- Pull to refresh

### Player Tab
- Full-screen player with artwork
- Scrub bar with elapsed / remaining time
- Skip back 15s / skip forward 30s
- Lock screen & AirPods controls
- Download button in top-right to save offline

### Mini Player
- Appears above the tab bar when audio is playing
- Tap it to jump to the Player tab
- Quick play/pause and +30s skip

### Settings (gear icon in Library)
- Auto-download new episodes (with Wi-Fi only option)
- View local storage usage
- Log out / change server

## API Endpoints Used

| Feature | Endpoint |
|---------|----------|
| Login | `GET /api/data/get_key` (Basic Auth) |
| Podcasts | `GET /api/data/return_pods/{user_id}` |
| Feed | `GET /api/data/return_episodes/{user_id}` |
| Podcast episodes | `GET /api/data/podcast_episodes?user_id=&podcast_id=` |
| Server downloads list | `GET /api/data/download_episode_list?user_id=` |
| Request server download | `POST /api/data/download_podcast` |
| Delete server download | `POST /api/data/delete_episode` |
| Save progress | `POST /api/data/update_episode_duration` |
| Mark completed | `POST /api/data/mark_episode_completed` |
| Record history | `POST /api/data/record_podcast_history` |

Authentication uses `Api-Key: <key>` header on all data requests.
