import SwiftUI
import UIKit
import Combine

struct PlayerView: View {
    @EnvironmentObject var player: AudioPlayerManager

    @State private var isSeeking = false
    @State private var seekValue: Double = 0
    @State private var showQueue = false
    @State private var showPlaybackOptions = false
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.verticalSizeClass) private var vSizeClass

    private var isLandscape: Bool { vSizeClass == .compact }

    var body: some View {
        NavigationStack {
            if let episode = player.currentEpisode {
                nowPlayingContent(episode)
            } else {
                emptyState
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "Nothing Playing",
            systemImage: "play.slash",
            description: Text("Pick an episode from your Library or Feed to start listening.")
        )
    }

    private func nowPlayingContent(_ episode: EpisodeItem) -> some View {
        Group {
            if isLandscape {
                // Landscape: artwork left, controls right
                HStack(spacing: 0) {
                    PodcastArtworkView(url: episode.artwork, size: .infinity, cornerRadius: 16)
                        .aspectRatio(1, contentMode: .fit)
                        .padding(16)
                        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
                    ScrollView {
                        VStack(spacing: 0) {
                            playerControls(episode)
                        }
                        .padding(.vertical, 8)
                    }
                }
            } else {
                // Portrait: stacked
                ScrollView {
                    VStack(spacing: 0) {
                        PodcastArtworkView(url: episode.artwork, size: .infinity, cornerRadius: 20)
                            .aspectRatio(1, contentMode: .fit)
                            .padding(.horizontal, 40)
                            .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
                            .padding(.top, 12)
                        playerControls(episode)
                    }
                }
            }
        }
        .navigationTitle("Now Playing")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showQueue = true } label: {
                    Image(systemName: player.queue.isEmpty ? "list.bullet" : "list.bullet.indent")
                        .overlay(alignment: .topTrailing) {
                            if !player.queue.isEmpty {
                                Text("\(player.queue.count)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(3)
                                    .background(player.artworkAccent, in: Circle())
                                    .offset(x: 8, y: -8)
                            }
                        }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showPlaybackOptions = true } label: {
                    Image(systemName: player.sleepTimerEnd != nil ? "timer" : "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showQueue) { QueueView() }
        .sheet(isPresented: $showPlaybackOptions) { PlaybackOptionsSheet() }
    }

    @ViewBuilder
    private func playerControls(_ episode: EpisodeItem) -> some View {
        // Title + podcast
        VStack(spacing: 4) {
            Text(episode.title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Text(episode.podcastName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)

        // Glass controls card
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Slider(
                    value: isSeeking ? $seekValue : .init(
                        get: { player.progressFraction },
                        set: { _ in }
                    ),
                    in: 0...1
                ) { editing in
                    if editing {
                        isSeeking = true
                        seekValue = player.progressFraction
                    } else {
                        player.seek(to: seekValue * player.duration, precise: true)
                        isSeeking = false
                    }
                }
                .tint(player.artworkAccent)

                HStack {
                    Text(player.formattedTime(player.currentTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("-\(player.formattedTime(max(0, player.duration - player.currentTime)))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 44) {
                Button { player.skip(by: -15) } label: {
                    Image(systemName: "gobackward.15")
                        .font(.title2).foregroundStyle(.primary)
                }
                Button { player.togglePlayPause() } label: {
                    ZStack {
                        Circle()
                            .fill(player.artworkAccent)
                            .frame(width: 68, height: 68)
                            .shadow(color: player.artworkAccent.opacity(0.35), radius: 10, y: 4)
                        if player.isLoading {
                            ProgressView().tint(.white).scaleEffect(1.1)
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2).foregroundStyle(.white)
                                .offset(x: player.isPlaying ? 0 : 2)
                                .contentTransition(.symbolEffect(.replace.byLayer.downUp))
                                .animation(.spring(duration: 0.3), value: player.isPlaying)
                        }
                    }
                }
                Button { player.skip(by: 30) } label: {
                    Image(systemName: "goforward.30")
                        .font(.title2).foregroundStyle(.primary)
                }
            }

            if let error = player.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
        .modifier(GlassCardModifier())
        .padding(.horizontal, 16)
        .padding(.top, 20)

        // Episode notes
        DisclosureGroup("Episode Notes") {
            EpisodeNotesView(text: episode.description)
                .padding(.top, 8)
        }
        .font(.subheadline)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 24)
    }
}

// MARK: - Playback Options Sheet (speed + sleep timer)

private struct PlaybackOptionsSheet: View {
    @EnvironmentObject var player: AudioPlayerManager
    @Environment(\.dismiss) var dismiss

    private let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    private let sleepOptions: [(label: String, minutes: Double?)] = [
        ("Off", nil),
        ("15 min", 15),
        ("30 min", 30),
        ("45 min", 45),
        ("60 min", 60),
        ("End of episode", -1)   // -1 = special case handled below
    ]

    @State private var timerDisplay: String = ""
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                Section("Playback Speed") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
                        ForEach(speeds, id: \.self) { speed in
                            Button {
                                player.playbackRate = speed
                            } label: {
                                Text(speed == 1.0 ? "1×" : "\(speed.formatted(.number.precision(.fractionLength(0...2))))×")
                                    .font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(
                                        player.playbackRate == speed
                                            ? player.artworkAccent
                                            : Color(.systemFill),
                                        in: RoundedRectangle(cornerRadius: 8)
                                    )
                                    .foregroundStyle(player.playbackRate == speed ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                Section {
                    ForEach(sleepOptions, id: \.label) { option in
                        Button {
                            if option.minutes == -1 {
                                // End of episode: use remaining duration
                                let remaining = max(player.duration - player.currentTime, 0)
                                player.setSleepTimer(minutes: remaining / 60)
                            } else {
                                player.setSleepTimer(minutes: option.minutes)
                            }
                        } label: {
                            HStack {
                                Text(option.label)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if option.minutes == nil && player.sleepTimerEnd == nil {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                } else if let end = player.sleepTimerEnd {
                                    // Highlight whichever option is active
                                    let activeMinutes = end.timeIntervalSinceNow / 60
                                    if let m = option.minutes, m > 0, abs(activeMinutes - m) < 1 {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    } else if option.minutes == -1, activeMinutes < 5 {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
                    if let end = player.sleepTimerEnd {
                        HStack {
                            Image(systemName: "timer").foregroundStyle(.secondary)
                            Text("Sleeps in \(timerDisplay)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .onReceive(ticker) { _ in
                            let remaining = max(end.timeIntervalSinceNow, 0)
                            let m = Int(remaining) / 60
                            let s = Int(remaining) % 60
                            timerDisplay = m > 0 ? "\(m)m \(s)s" : "\(s)s"
                        }
                        .onAppear {
                            let remaining = max(end.timeIntervalSinceNow, 0)
                            let m = Int(remaining) / 60
                            let s = Int(remaining) % 60
                            timerDisplay = m > 0 ? "\(m)m \(s)s" : "\(s)s"
                        }
                    }
                } header: {
                    Text("Sleep Timer")
                }
            }
            .navigationTitle("Playback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Queue Sheet

struct QueueView: View {
    @EnvironmentObject var player: AudioPlayerManager
    @EnvironmentObject var downloads: DownloadManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if player.queue.isEmpty {
                    ContentUnavailableView(
                        "Queue is Empty",
                        systemImage: "list.bullet",
                        description: Text("Long press any episode and choose \"Add to Queue\" or \"Play Next\".")
                    )
                } else {
                    List {
                        // Currently playing
                        if let current = player.currentEpisode {
                            Section("Now Playing") {
                                HStack(spacing: 12) {
                                    PodcastArtworkView(url: current.artwork, size: 48, cornerRadius: 8)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(current.title)
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(2)
                                        Text(current.podcastName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "waveform")
                                        .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                                        .foregroundStyle(.tint)
                                }
                            }
                        }

                        // Up next
                        Section("Up Next") {
                            ForEach(player.queue) { episode in
                                HStack(spacing: 12) {
                                    PodcastArtworkView(url: episode.artwork, size: 48, cornerRadius: 8)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(episode.title)
                                            .font(.subheadline)
                                            .lineLimit(2)
                                        Text(episode.podcastName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        Text(episode.formattedDuration)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        player.play(episode: episode, localURL: downloads.localURL(for: episode.id))
                                        player.queue.removeAll { $0.id == episode.id }
                                    } label: {
                                        Label("Play Now", systemImage: "play.fill")
                                    }
                                    .tint(.green)
                                }
                            }
                            .onDelete { player.removeFromQueue(at: $0) }
                            .onMove { player.moveInQueue(from: $0, to: $1) }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .environment(\.editMode, .constant(.active))
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !player.queue.isEmpty {
                        Button("Clear", role: .destructive) {
                            player.queue.removeAll()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Episode Notes (HTML-aware, async parse so it never blocks the main thread)

private struct EpisodeNotesView: View {
    let text: String
    @State private var attributed: AttributedString?

    var body: some View {
        Group {
            if text.isEmpty {
                Text("No description available.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let attr = attributed {
                Text(attr)
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // task(id:) only re-runs when the episode changes, not on every currentTime tick
        .task(id: text) {
            guard text.contains("<"), text.contains(">") else { return }
            attributed = await Task.detached(priority: .utility) {
                guard let data = text.data(using: .utf8),
                      let ns = try? NSAttributedString(
                          data: data,
                          options: [.documentType: NSAttributedString.DocumentType.html,
                                    .characterEncoding: String.Encoding.utf8.rawValue],
                          documentAttributes: nil
                      ) else { return nil }
                return try? AttributedString(ns, including: \.uiKit)
            }.value
        }
    }
}
