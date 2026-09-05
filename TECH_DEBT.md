# PinePlay Tech Debt Audit

Full audit of the PinePlay iOS SwiftUI podcast client, covering dead code, duplication, tightly-coupled/overly-complex functions, inconsistent patterns, dependency staleness, and performance issues. Findings are organized by module and ranked by effort vs. impact within each table.

## Top 2 Recommendations

1. **Extract a shared episode-action handler** (`playEpisode` / `downloadEpisode` / `deleteDownload` / `toggleCompleted`) out of `FeedView`, `LibraryView`, and `PodcastDetailView`. These are copy-pasted in all three views and have already drifted: `LibraryView.toggleCompleted`'s failure-revert path calls `api.getRecentEpisodes()` and refreshes `searchEpisodes`, which is semantically wrong in a per-podcast/search context. **Effort: medium. Impact: high** — fixes a live correctness bug and removes the largest duplication surface in the Views layer.
2. **Make `ImageCache.get`/`set` (`Models.swift:39-58`) genuinely async.** Both currently do synchronous `Data(contentsOf:)` disk reads / atomic disk writes, invoked from the main actor via `PodcastArtworkView.loadImage()`, `AudioPlayerManager`, and every episode row across four+ views. In any scrolling list this causes real per-cell hitches today. **Effort: low-medium. Impact: medium-high** — the clearest "blocking call that should be async" in the codebase.

*(The single largest structural item — splitting the `AudioPlayerManager` god object into playback/persistence/NowPlaying/remote-command/accent-color concerns, see Services §1 — is high-effort/high-impact but deliberately not in the top 2: it's a multi-day refactor, not a tractable next step.)*

---

## Services

### `AudioPlayerManager.swift` (867 lines)

A `@MainActor` singleton God object: playback engine, queue, sleep timer, chapter sync, Now Playing/remote-command center, progress persistence (local + server), background tasks, and image dominant-color extraction all in one class.

| # | Lines | Finding | Effort/Impact |
|---|---|---|---|
| 1 | 8–767 (whole class) | Single class owns 7+ unrelated responsibilities — classic SRP violation, hard to test in isolation. | High / High |
| 2 | 143–305 (`playInternal`) | ~160-line function: URL resolution, AVPlayer setup, resume-position math, dual seek strategies, observer wiring, retry logic, near-finished flagging, chapter updates, throttled Now Playing sync, accent-color kickoff — 7+ concerns in one function. | High / High |
| 3 | 482–494, 536–550, 562–579 | Progress-persistence block (write `localProgress`, `saveLocalProgressMap()`, `lastPlaybackTime`, re-encode `lastPlayingEpisode`, call `updateEpisodeProgress`) duplicated near-verbatim in `tearDown()`, `scheduleProgressSave()`, `saveProgressNow()`. Should be one `persistProgress(episodeId:seconds:isYoutube:)` helper. | Medium / Medium |
| 4 | 771–867 (`dominantColor(of:)`) | ~100-line pixel-level image/color analysis embedded in the audio-player file — no relation to playback; should live in its own file/service. | Medium / Medium |
| 5 | 90, 704–723 | `seekScrubTimer` declared/invalidated but never actually instantiated anywhere — vestigial dead property. `seekBackwardCommand.isEnabled = false` sits right after a fully-implemented `seekForwardCommand` — asymmetric, seemingly unfinished. | Low / Low |
| 6 | 420–425 (`formattedTime`) | Duplicates the same h:mm:ss formatting hand-rolled 3 more times (`EpisodeItem.formattedDuration`/`formattedCurrentTime` in Models.swift, `Chapter.formattedTime`). 4 copies total across the codebase. | Low-Med / Medium |
| 7 | 446–475 vs 726–766 | `extractAccentColor` and `updateNowPlayingInfo` each independently fetch the same artwork URL via `URLSession.shared.data(from:)` on a cache miss — two uncoordinated network fetches per episode start. | Medium / Medium |
| 8 | 458, 739 | `ImageCache.shared.get(...)` (synchronous disk I/O, see Models §3) called directly from this `@MainActor` class — blocks main thread on episode start/Now-Playing refresh. | Medium / Medium |
| 9 | 216–226 | Local-file playback failure triggers a recursive re-entrant call into `playInternal` from within its own Combine sink — works, but fragile self-referential retry pattern. | Medium / Low-Med |
| 10 | 187–194, 238, 255, 611–629 | Three different concurrency-bridging idioms coexist: completion-handler→`Task {@MainActor}`, `MainActor.assumeIsolated` inside a Combine sink, `NotificationCenter`→`Task {@MainActor}`. Individually justified, collectively inconsistent. | Medium / Low-Med |
| 11 | 598, 602, 625 | `configureAudioSession()` swallows `AVAudioSession` errors via `try?` with no logging — inconsistent with the rest of the class's user-facing `error: String?` threading. | Low / Low |

### `PinepodsAPIService.swift` (244 lines)

Comparatively clean thin API wrapper, with one confirmed dead method and real boilerplate duplication.

| # | Lines | Finding | Effort/Impact |
|---|---|---|---|
| 1 | 126–131 (`getInProgressEpisodes`) | **Confirmed dead code** — no call sites anywhere (repo-wide grep). Never invoked. | Low / Low (delete) |
| 2 | 144–191 | Six near-identical functions (`requestServerDownload`, `deleteServerDownload`, `markEpisodeUncompleted`, `markEpisodeCompleted`, `updateEpisodeProgress`, `recordHistory`) all repeat `requireConfig()` + `post(path, body: [...])`. Consolidate into `episodeAction(path:episodeId:isYoutube:extra:)`. | Low-Med / Low-Med |
| 3 | 88–109 (`addPodcast`) | Builds a stringly-typed `[String: Any]` dict via `JSONSerialization` — the only place in the service not using `Codable`/`JSONEncoder`. | Medium / Low |
| 4 | 120–131 | `getRecentEpisodes()` and the dead `getInProgressEpisodes()` hit the identical endpoint; no caching layer anywhere in this service — every screen load re-fetches from network. | Medium / Medium |
| 5 | throughout | Callers (`AudioPlayerManager`, others) routinely wrap calls in `try?`, discarding the well-typed `APIError` this service produces. | Low / Low-Med |

### `PodcastFeedParser.swift` (249 lines, new)

| # | Lines | Finding | Effort/Impact |
|---|---|---|---|
| 1 | 60, 81 | Filename says "Parser," public type is `PodcastFeedService`, actual parser is `RSSFeedParser` — naming mismatch. | Low / Low |
| 2 | 81–249 vs `ChaptersService.swift:92-170` | Two independent, near-identical `XMLParserDelegate` SAX parsers (`RSSFeedParser` vs `RSSChaptersParser`) both walk RSS `<item>` structures for different purposes. A shared SAX-state base would remove real duplication. | Med-High / Medium |
| 3 | 64–74 (`fetchFeed`) | No caching — every Staging Ground detail-view open re-downloads and re-parses the entire feed from scratch. | Medium / Medium |
| 4 | 173, 219–248 (`normalizeDate`) | Tries up to 5 `DateFormatter`s sequentially per episode; not O(n²) but adds up over large feeds with no early-exit optimization. | Low / Low |
| 5 | 208–213 (`parseDuration`) | Uses `pow(60.0, ...)` floating-point math for HH:MM:SS→seconds where integer `* 60` arithmetic would be simpler and avoid float-rounding edge cases. | Low / Low |

### `PodcastSearchService.swift` (81 lines, new)

| # | Lines | Finding | Effort/Impact |
|---|---|---|---|
| 1 | 70 | `(try? JSONDecoder().decode(...)) ?? SearchResponse(results: [])` silently swallows decode failures and presents them to the user as "no results" instead of surfacing `PodcastSearchError` — hides real API-shape bugs. | Low / Medium |
| 2 | 51–68 | A third independent "build URL → fetch → map errors" implementation, alongside `PinepodsAPIService.fetch` and `PodcastFeedService.fetchFeed` — each with different error types and structure. | Medium / Medium |
| 3 | 41 | `private struct Result` shadows `Swift.Result` — harmless while private, but a latent foot-gun if extended later. | Low / Low |
| 4 | 51–80 | No caching of repeated identical searches (minor — search is a deliberate user action). | Low / Low |

---

## Models

### `Models.swift` (491 lines)

A de facto god-file mixing 7+ unrelated concerns: image cache, config persistence, domain models, ~7 API response DTOs + mappers, staging-ground persistence, feed-mute persistence, a `Color` hex extension, and podcasting-2.0 models.

| # | Lines | Finding | Effort/Impact |
|---|---|---|---|
| 1 | 7–59 (`ImageCache`) | A full memory+disk image-cache engine (NSCache, FileManager, JPEG encode) living inside "Models" — this is infra/service code, forces UIKit/SwiftUI imports into what should be a plain data-model file. Move to `Services/ImageCache.swift`. | Low / Medium |
| 2 | 39–46 (`ImageCache.get`) | `Data(contentsOf: url)` is synchronous disk I/O run from the main actor at every call site (`AudioPlayerManager`, `PodcastArtworkView`) — see Top 3 #3. | Medium / Medium-High |
| 3 | 48–58 (`ImageCache.set`) | `guard !FileManager.default.fileExists(...) else { return }` means the disk cache is *never* overwritten once written — a changed-artwork-at-same-URL or a corrupt initial write is stuck until manual cache clear. No TTL/invalidation. | Low-Med / Low-Med |
| 4 | 33–37 (`diskURL`) | Cache key truncated to `.suffix(120)` of the percent-encoded URL — two distinct long URLs sharing the same last-120-char suffix (plausible with long CDN token prefixes) would collide and overwrite each other's cached artwork. | Low / Low-Med |
| 5 | 63–86, 296–311, 359–393, 402–423, 469–490 | Five separate ad-hoc `UserDefaults` + `JSONEncoder`/`JSONDecoder` persistence implementations (`ServerConfig`, `PodcastAccentColors`, `StagingGround`, `FeedPreferences`, `AutoDownloadSettings`), ~90 combined lines. A generic `UserDefaultsStore<T: Codable>` would collapse all five. | Medium / Medium |
| 6 | 181–206, 213–256, 259–292 | Three near-identical `Decodable` structs (`EpisodeResponse`, `PodcastEpisodeResponse`, `DownloadedEpisodeResponse`) each with an ~90%-identical `toEpisodeItem()` mapper. A 4th near-duplicate builder is `ParsedFeedEpisode.toEpisodeItem()` in `PodcastFeedParser.swift:29-40`. Adding/renaming a field means touching 4 places. | Med / Medium |
| 7 | 213–241 vs 181–195 | `PodcastEpisodeResponse` needs a bespoke `CodingKeys` (mixed-case `Episodetitle` etc.) to reconcile inconsistent server key casing vs. `EpisodeResponse`'s all-lowercase keys for the same conceptual episode — no shared abstraction over the API's own inconsistency. | Medium / Medium |
| 8 | 135–142 (`formattedCurrentTime`) | **Confirmed dead** — grepped repo-wide, referenced nowhere; `PlayerView` calls `AudioPlayerManager.formattedTime` instead, which reimplements the same logic (3rd copy; 4th is `Chapter.formattedTime` L460-464). Delete this one, consolidate the rest into one `Double.formattedDuration` helper. | Low / Low-Med |
| 9 | 147–152 (`LoginResponse`) | Plain `Decodable` with no `toX()` mapper, unlike every other Response type in the file — inconsistent convention. | Low / Low |
| 10 | 315, 397 | Two separate `extension Notification.Name { ... }` blocks that could be merged. | Low / Low |
| 11 | n/a | Newer feature code (`ParsedFeed`/`ParsedFeedEpisode` in `PodcastFeedParser.swift`, `PodcastSearchResult` in `PodcastSearchService.swift`) keeps its models local to the service file instead of in `Models.swift` — a better pattern than the old file, but undocumented/inconsistent for new contributors. | Low / Low |

---

## Views

### Cross-cutting (see dedicated section below for detail)
Episode-action duplication, shuffle-sheet duplication, `@EnvironmentObject` re-render tax, inconsistent singleton access, direct `UserDefaults` use in views, and duplicated HTML rendering all appear across 3+ files — detailed once in **Cross-Cutting Issues** rather than repeated per file.

### `Feed/FeedView.swift` (536 lines)

| # | Lines | Finding | Effort/Impact |
|---|---|---|---|
| 1 | 189–252 (`loadFeed`) | ~65 lines of merge/rescue/sort business logic living in a View: reconciles server episodes, in-flight local progress, dismissed IDs, muted podcasts, and a UserDefaults fallback for a possibly-unsynced "last played" episode. Untestable without instantiating the View; duplicates concerns already tracked in `AudioPlayerManager`. | High / High |
| 2 | 294–329 (`toggleCompleted`) | Duplicates the cross-cutting episode-action pattern, plus duplicates `isNearlyFinished` gating already computed at 257-263. | Medium / High (shared w/ cross-cutting) |
| 3 | 406–414 (`ContinueListeningCard` progress bar) | Re-implements the same `GeometryReader` + double-`Capsule()` progress bar already in `Shared/EpisodeRowView.swift:283-293`. Should be a shared `ProgressBarView(progress:)`. | Low / Low-Med |
| 4 | 445–536 (`SwipeUpToDismissModifier`/`VerticalDismissGesture`) | ~90-line self-contained UIKit gesture bridge unrelated to `FeedView`'s concerns, bloating the file. Should move to its own file under `Shared/`. | Low / Low |
| 5 | 20–187 (`body`) | Single ~170-line computed property mixing loading/error/empty states, the List, a horizontal "Continue Listening" carousel embedded inside a `Section` header, and sheet presentation. Extract `feedList`/`continueListeningHeader` computed properties. | Low-Med / Medium |
| 6 | 150, 157, 163, 267, 286-287, 311, 315 | Reaches `AudioPlayerManager.shared` directly instead of the injected `@EnvironmentObject` used elsewhere — see cross-cutting #4. | Low / Medium |

### `Library/LibraryView.swift` (551 lines)

| # | Lines | Finding | Effort/Impact |
|---|---|---|---|
| 1 | 51–65 (`applySearch`) | **Best-handled async pattern of the six view files** — correctly precomputes filters off-main-thread via `Task.detached`. Worth using as the reference pattern elsewhere. | n/a (positive) |
| 2 | 51–65 | Runs 3 `Task.detached` calls sequentially even though the "pods" filter has no dependency on "titles"; only "notes" depends on `titleIds`. Minor missed parallelism (`async let`). | Low / Low |
| 3 | 328–417 (`libraryShuffleSheet`) | ~90% identical to `PodcastDetailView.shuffleQueueSheet` — cross-cutting #2. | Low-Med / Medium |
| 4 | 490–505 (`toggleCompleted`) | **Correctness bug**: on failure, refetches via `api.getRecentEpisodes()` to refresh `searchEpisodes` — semantically wrong for a per-podcast/search context (recent episodes ≠ search results), and inconsistent with the other two views' revert strategy. This is Top 3 recommendation #2. | Low / Medium (bug) |
| 5 | 508–551 (`PodcastGridCell`) | Clean, correctly reuses `PodcastArtworkView`/`MarqueeText` — no issues. | n/a (positive) |
| 6 | whole file | 551 lines covering grid, search results, shuffle-sheet UI, and all actions in one struct — candidate to split into separate files. | Low-Med / Low-Med |

### `Library/PodcastDetailView.swift` (309 lines)

| # | Lines | Finding | Effort/Impact |
|---|---|---|---|
| 1 | 40–52 (`filteredEpisodes`) | Computed property filters+sorts the full episode array on *every* access — accessed ~7 times per body evaluation (100, 150, 152, 156, 184, 206, 210, 213, 220), 3x inside `shuffleQueueSheet` alone. For a large back-catalog this re-runs redundantly per render. Cache into `@State`, recompute via `.onChange`. | Low / Medium-High (scales w/ episode count) |
| 2 | 149–158 | Shuffle button uses `.onTapGesture`/`.onLongPressGesture` on a bare `Image` instead of `Button` — bypasses standard hit-testing/accessibility used everywhere else. | Low / Low-Med (a11y) |
| 3 | 182–238 (`shuffleQueueSheet`) | Duplicates `LibraryView.libraryShuffleSheet` — cross-cutting #2. | Low-Med / Medium |
| 4 | 288–308 (`toggleCompleted`) | Duplicates the `FeedView` pattern — cross-cutting #1. | Medium / High (shared) |
| 5 | 21–23, 164–166 | Reads/writes `UserDefaults` directly (`"sortOrder_\(podcast.id)"`) — cross-cutting #5. | Low / Medium |

### `Library/StagingGroundView.swift` (492 lines, new)

| # | Lines | Finding | Effort/Impact |
|---|---|---|---|
| 1 | whole file | Bundles 5 unrelated view types (`StagingGroundSection`, `AddToStagingView`, `StagingPodcastDetailView`, `StagingEpisodeRow`, `StagingEpisodeDetailSheet`) in one 492-line file. Cheapest point to fix file organization since it's brand new. | Low / Low |
| 2 | 349–409, 414–492 | **Largest concrete duplication in the audit**: `StagingEpisodeRow`/`StagingEpisodeDetailSheet` substantially re-implement `Shared/EpisodeRowView.swift`'s `EpisodeRowView`/`EpisodeDetailSheet` (same artwork+title+meta layout, same now-playing waveform overlay, same play/pause logic) against `ParsedFeedEpisode` instead of `EpisodeItem` — both types already have a `toEpisodeItem()` conversion (357-359, 422-424), so the existing components could just be parameterized/reused instead of forked. | Medium / High |
| 3 | 223–235 | `StagingPodcastDetailView`'s header duplicates `PodcastDetailView`'s header block (57-73) verbatim — candidate for a shared `PodcastHeaderView`. | Low / Medium |
| 4 | 96–121 | `AddToStagingView`'s search-result row duplicates `LibraryView.searchResults`'s row pattern (253-266). | Low / Low-Med |
| 5 | 283–287 | `.alert(..., isPresented: .constant(subscribeError != nil), ...)` — using `.constant()` means SwiftUI's own dismiss gesture can't drive the binding back to `false`; fragile compared to every other alert in the codebase which uses a real `@State var show...: Bool`. | Low / Medium |

### `Player/PlayerView.swift` (714 lines)

| # | Lines | Finding | Effort/Impact |
|---|---|---|---|
| 1 | whole file | Houses 7 distinct view types (`PlayerView`, `WaveLoadingBar`, `GravityDotLoader`, `ChaptersSheet`, `PlaybackOptionsSheet`, `QueueView`, `EpisodeNotesView`) — largest, most tangled file in the app. Split into separate files under `Player/`. | Medium / Medium-High (navigability) |
| 2 | 15 (`hSizeClass`) | Declared `@Environment(\.horizontalSizeClass)` never read anywhere in the file — dead code, likely leftover from an abandoned iPad layout. | Low / Low (delete) |
| 3 | 136–289 (`playerControls`) | ~150-line `@ViewBuilder` mixing title/chapter label, scrubber with a hand-rolled conditional `Binding` swap, wave-loading-bar swap-in, chapter tick marks via `GeometryReader`, transport buttons, error text, and an episode-notes `DisclosureGroup`. Decompose into `PlayerHeader`/`PlayerScrubber`/`PlayerTransportControls`. | Medium-High / Medium-High |
| 4 | 174–179 | Slider binding: `isSeeking ? $seekValue : .init(get: {...}, set: { _ in })` builds a throwaway `Binding` every body evaluation with a no-op `set` — if a drag begins before `editing: true` is delivered, the input is silently dropped. Low-probability latent bug. | Low / Low-Med |
| 5 | 224–237 | `.onChange(of: player.isLoading)` spawns an un-cancelled `Task` with a hardcoded 1.8s sleep each toggle — self-correcting via a guard, but unmanaged concurrency that should hold/cancel a `Task` handle. | Low / Low |
| 6 | 530–653 (`QueueView`) | Reimplements the episode-row layout a 3rd time (Now Playing / Up Next rows) instead of reusing `EpisodeRowView` — cross-cutting duplication. | Low-Med / Medium |
| 7 | 475–487 | Sleep-timer "which option is active" logic (nested conditionals, magic tolerances `< 1`, `< 5`) embedded directly in the view body — hard to test, should be a computed property/method. | Low-Med / Low-Med |
| 8 | 667–714 (`EpisodeNotesView`) | Duplicates `HTMLInlineView` in `PodcastArtworkView.swift` — cross-cutting #6. | Low-Med / Medium |

### `Shared/PodcastArtworkView.swift` (184 lines)

| # | Lines | Finding | Effort/Impact |
|---|---|---|---|
| 1 | 67–86 (`loadImage`) | Synchronous, blocking disk-read fast path via `ImageCache.shared.get` — runs inline on the main actor from `.task(id: url)`. Across a scrolling list this causes visible per-cell hitches. This is Top 3 recommendation #3. | Low-Med / Medium-High |
| 2 | rest of file | Otherwise clean: cache-hit/network-fetch/cancellation flow is well-structured, `.task(id:)` correctly re-triggers only on URL change, no dead code found (`GlassCardModifier`, `HTMLInlineView`, `isApproximatelyBlack` are all used elsewhere). | n/a (positive) |

---

## Cross-Cutting Issues

Issues that appear identically (or near-identically) in 3+ files — the highest-ROI fixes, since one change collapses multiple duplication sites at once.

| # | Where | Finding | Effort/Impact |
|---|---|---|---|
| 1 | `FeedView:265-329`, `LibraryView:480-505`, `PodcastDetailView:257-270,288-308` | `playEpisode`/`downloadEpisode`/`deleteDownload`/`toggleCompleted` copy-pasted in all three, each reimplementing the same fire-and-forget `Task { try? await ... }` + optimistic-revert pattern — and they've already drifted behaviorally (see LibraryView bug above). **Top 3 #2.** | Medium / High |
| 2 | `LibraryView.swift:328-417` vs `PodcastDetailView.swift:182-238` | "Shuffle N episodes" sheet (~90% identical Form/Slider/Stepper/count-clamping code) duplicated wholesale. Extract a reusable `ShuffleSheet` parameterized by episode pool + action. | Low-Med / Medium |
| 3 | `AudioPlayerManager.swift` (`currentTime` published every 1s at L251-259) consumed via `@EnvironmentObject` by `EpisodeRowView`, `ContinueListeningCard`, `StagingEpisodeRow`/`StagingEpisodeDetailSheet`, `QueueView` | `AudioPlayerManager` is one big `ObservableObject` mixing `currentTime` (ticks every second) with unrelated state (`chapters`, `queue`, `sleepTimerEnd`) on the same `@Published` surface — every view holding it re-evaluates `body` on every tick even when it doesn't render `currentTime`. In a list with dozens of rows this is a continuous, unnecessary re-render tax while anything is playing. | Medium-High / High |
| 4 | `FeedView` (direct `AudioPlayerManager.shared` access) vs `LibraryView`/`PodcastDetailView`/`PlayerView` (`@EnvironmentObject`) | Inconsistent access to the player singleton — makes the dependency invisible at the call site in `FeedView` and harder to test/mock. | Low / Medium |
| 5 | `FeedView.swift:12-15,92,172,229-236`, `PodcastDetailView.swift:21-23,164-166` | Views read/write `UserDefaults` directly with stringly-typed keys (`"dismissedContinueListeningIds"`, `"lastPlaybackTime"`, `"sortOrder_\(podcast.id)"`) instead of going through a settings/persistence service. | Low-Med / Medium |
| 6 | `PlayerView.swift`'s `EpisodeNotesView` (667-714) vs `PodcastArtworkView.swift`'s `HTMLInlineView` (120-175) | HTML-to-`AttributedString` parsing implemented twice, nearly identically (same `<style>` wrapper, same off-main-thread `NSAttributedString` decode via `Task.detached`, same color post-processing with slightly different rules). Unify into one `HTMLTextView(text:mode:font:)`. | Low-Med / Medium |
| 7 | `PinepodsAPIService.fetch`, `PodcastFeedService.fetchFeed`, `PodcastSearchService.search` | Three independent "build URL → fetch → map network errors to a local error type" implementations. | Medium / Medium |
| 8 | `PodcastFeedParser.swift`'s `RSSFeedParser` vs `ChaptersService.swift`'s `RSSChaptersParser` | Two independent SAX (`XMLParserDelegate`) parsers walking RSS `<item>` structures for different purposes. | Med-High / Medium |
| 9 | `AudioPlayerManager.formattedTime`, `EpisodeItem.formattedDuration`, `EpisodeItem.formattedCurrentTime` (dead), `Chapter.formattedTime` | Same h:mm:ss formatting hand-rolled 4 times. One shared `Double.formattedDuration` helper removes all four. | Low / Medium |
| 10 | No ViewModel layer anywhere (`FeedView`, `LibraryView`, `PodcastDetailView`, `PlayerView`, `StagingGroundView`) | Every view does its own networking, filtering/sorting, optimistic mutation, and persistence inline in `private func`s on the View struct. Consistent across all files (at least uniformly inconsistent with MV/MVVM), but means business logic is untestable without instantiating a View. Architectural — noted once here rather than per file. | High / High |

---

## Dependencies

None. No `Package.swift`, `Package.resolved`, `Podfile`, `Cartfile`, or `XCRemoteSwiftPackageReference` anywhere in `project.pbxproj` — 100% Foundation/UIKit/SwiftUI/AVFoundation with hand-rolled networking and RSS parsing. Not tech debt per se (nothing to update, nothing at risk), just worth noting since the audit brief assumed a dependency manifest exists.

---

## Xcode Project & Repo Hygiene

`project.pbxproj` (498 lines) is actually clean — every `PBXFileReference`/`PBXBuildFile` was cross-checked against the real `Views/` folder tree: no orphaned references, no duplicate file references, no stray build phases, and only one (correctly gitignored) scheme.

| # | Location | Finding | Effort/Impact |
|---|---|---|---|
| 1 | `project.pbxproj` lines 339, 396 vs 422, 456 | Project-level default `IPHONEOS_DEPLOYMENT_TARGET = 26.2` vs. the actual target-level override `17.6` used for Debug/Release (matching the README's "iOS 17+"). The stale project-level default is confusing cruft, presumably left from project creation against a newer default SDK. | Low / Low |
| 2 | `Info.plist:19-21` | Blanket `NSAllowsArbitraryLoads = true` (ATS disabled globally, not scoped to specific domains). SETUP.md explains it's for self-signed/HTTP Pinepods servers, but a per-domain ATS exception would be safer and still App-Store-friendly. | Low-Med / Medium (security/App Store review risk) |
| 3 | `/.Rhistory` (repo root) | Stray, empty, tracked R session-history file unrelated to this Swift project — pure noise. | Trivial / Low (delete + gitignore) |
| 4 | `/PinePlayer/` (repo root) | Empty, untracked directory containing only `.DS_Store` — likely leftover from an early `PinePlayer` → `PinePlay` rename. Harmless but confusing to a new contributor. | Trivial / Low (delete locally) |
| 5 | `/.claude/settings.local.json` (repo root) vs `PinePlay/.claude/settings.local.json` | The root-level file contains permission grants for an unrelated project ("on-notice" / Australian parliament scraping work) — clearly copied from a different repo's Claude Code config and doesn't belong here. | Trivial / Low (housekeeping) |
| 6 | repo root | No CI (`.github/workflows` or otherwise), no `fastlane`, no `.swiftlint.yml`. Every build is manual today despite the app apparently already being distributed (README has a Ko-fi link/screenshots). A linter with a duplication/complexity rule would likely have caught several of the findings above earlier. | Medium / Medium (process, not code) |

