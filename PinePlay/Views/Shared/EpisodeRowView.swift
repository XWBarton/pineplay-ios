import SwiftUI

// MARK: - Marquee Text

struct MarqueeText: View {
    let text: String
    let font: Font
    var speed: Double = 28  // points per second

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var animating = false

    private let gap: CGFloat = 48

    var body: some View {
        GeometryReader { geo in
            let cw = geo.size.width
            ZStack(alignment: .leading) {
                if textWidth > cw {
                    (Text(text) + Text("        ") + Text(text))
                        .font(font)
                        .lineLimit(1)
                        .fixedSize()
                        .offset(x: offset)
                } else {
                    Text(text)
                        .font(font)
                        .lineLimit(1)
                }
            }
            .clipped()
            .onAppear { containerWidth = cw }
            .onChange(of: containerWidth) { _, cw in startIfNeeded(cw: cw) }
            .onChange(of: textWidth) { _, _ in startIfNeeded(cw: containerWidth) }
        }
        .background(
            Text(text)
                .font(font)
                .lineLimit(1)
                .fixedSize()
                .hidden()
                .background(GeometryReader { tg in
                    Color.clear.preference(key: _MarqueeWidthKey.self, value: tg.size.width)
                })
        )
        .onPreferenceChange(_MarqueeWidthKey.self) { w in textWidth = w }
    }

    private func startIfNeeded(cw: CGFloat) {
        guard textWidth > cw, !animating else { return }
        animating = true
        offset = 0
        let total = textWidth + gap
        let duration = total / speed
        withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
            offset = -total
        }
    }
}

private struct _MarqueeWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Episode Detail Sheet

struct EpisodeDetailSheet: View {
    let episode: EpisodeItem
    let onPlay: () -> Void
    let onDownload: () -> Void
    let onDelete: () -> Void
    let onToggleCompleted: () -> Void

    @EnvironmentObject var player: AudioPlayerManager
    @EnvironmentObject var downloads: DownloadManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    PodcastArtworkView(url: episode.artwork, size: 160, cornerRadius: 16)
                        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)

                    VStack(spacing: 6) {
                        Text(episode.title)
                            .font(.title3.bold())
                            .multilineTextAlignment(.center)
                        Text(episode.podcastName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Text(episode.pubDate.prefix(10))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(episode.formattedDuration)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if episode.completed {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .padding(.horizontal)

                    HStack(spacing: 32) {
                        actionButton(
                            icon: player.currentEpisode?.id == episode.id && player.isPlaying
                                ? "pause.circle.fill" : "play.circle.fill",
                            label: "Play"
                        ) {
                            onPlay()
                            dismiss()
                        }
                        actionButton(
                            icon: "text.line.first.and.arrowtriangle.forward",
                            label: "Play Next"
                        ) {
                            player.playEpisodeNext(episode)
                            dismiss()
                        }
                        actionButton(icon: "text.badge.plus", label: "Queue") {
                            player.addToQueue(episode)
                            dismiss()
                        }
                        if downloads.locallyDownloaded.contains(episode.id) {
                            actionButton(icon: "arrow.down.circle.fill", label: "Downloaded", tint: .accentColor) {
                                onDelete()
                            }
                        } else {
                            actionButton(icon: "arrow.down.circle", label: "Download") {
                                onDownload()
                            }
                        }
                    }
                    .padding(.horizontal)

                    Button {
                        onToggleCompleted()
                        dismiss()
                    } label: {
                        Label(
                            episode.completed ? "Mark as Unplayed" : "Mark as Played",
                            systemImage: episode.completed ? "circle" : "checkmark.circle"
                        )
                        .font(.subheadline)
                    }
                    .buttonStyle(.bordered)

                    if !episode.description.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Episode Notes")
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            EpisodeNotesView(text: episode.description)
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical, 24)
            }
            .navigationTitle("Episode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func actionButton(icon: String, label: String, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 32))
                Text(label)
                    .font(.caption)
            }
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Episode Row

struct EpisodeRowView: View {
    let episode: EpisodeItem
    var showPodcastName: Bool = true
    var onTap: (() -> Void)? = nil
    let onPlay: () -> Void
    let onDownload: () -> Void
    let onDelete: () -> Void
    let onToggleCompleted: () -> Void

    @EnvironmentObject var player: AudioPlayerManager
    @EnvironmentObject var downloads: DownloadManager

    private var isCurrentEpisode: Bool {
        player.currentEpisode?.id == episode.id
    }

    private var isDownloadingLocally: Bool {
        downloads.isDownloading(episode.id)
    }

    private var isLocallyDownloaded: Bool {
        downloads.locallyDownloaded.contains(episode.id)
    }

    var body: some View {
        HStack(spacing: 12) {
            PodcastArtworkView(
                url: episode.artwork,
                size: 56,
                downloadProgress: downloads.downloadProgress[episode.id]
            )

            VStack(alignment: .leading, spacing: 4) {
                if showPodcastName {
                    Text(episode.podcastName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                }

                Text(episode.title)
                    .font(.subheadline.weight(isCurrentEpisode ? .semibold : .regular))
                    .lineLimit(2)
                    .foregroundStyle(episode.completed ? .secondary : .primary)

                HStack(spacing: 8) {
                    Text(episode.pubDate.prefix(10))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(episode.formattedDuration)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if episode.completed {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                // Progress bar
                if episode.progress > 0, !episode.completed {
                    GeometryReader { geo in
                        let w = max(0, geo.size.width * episode.progress)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.2)).frame(height: 3)
                            Capsule().fill(Color.accentColor)
                                .frame(width: w, height: 3)
                        }
                    }
                    .frame(height: 3)
                }
            }
            .onTapGesture { onTap?() }

            Spacer()

            VStack(spacing: 8) {
                // Play/Pause button
                Button(action: onPlay) {
                    Image(systemName: isCurrentEpisode && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(isCurrentEpisode ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)

                // Download button
                downloadButton
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                onPlay()
            } label: {
                Label("Play", systemImage: "play.fill")
            }

            Button {
                player.playEpisodeNext(episode)
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Button {
                player.addToQueue(episode)
            } label: {
                Label("Add to Queue", systemImage: "text.badge.plus")
            }

            Divider()

            Button {
                onToggleCompleted()
            } label: {
                if episode.completed {
                    Label("Mark as Unplayed", systemImage: "circle")
                } else {
                    Label("Mark as Played", systemImage: "checkmark.circle")
                }
            }

            Divider()

            if isLocallyDownloaded {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete Download", systemImage: "trash")
                }
            } else {
                Button {
                    onDownload()
                } label: {
                    Label("Download Episode", systemImage: "arrow.down.circle")
                }
            }
        }
    }

    @ViewBuilder
    private var downloadButton: some View {
        if isDownloadingLocally, let progress = downloads.downloadProgress[episode.id] {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 2)
                    .frame(width: 22, height: 22)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .frame(width: 22, height: 22)
                    .rotationEffect(.degrees(-90))
                Button { downloads.cancelDownload(episode.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        } else if isLocallyDownloaded {
            Button(action: onDelete) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.body)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
        } else if episode.downloaded {
            // Downloaded on server but not locally
            Button(action: onDownload) {
                Image(systemName: "arrow.down.to.line.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        } else {
            Button(action: onDownload) {
                Image(systemName: "arrow.down.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}
