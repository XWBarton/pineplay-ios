import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var player: AudioPlayerManager
    @Environment(\.dismiss) var dismiss

    @State private var sortOrder: DownloadSort = .newestFirst
    @State private var isSelecting = false
    @State private var selectedIds: Set<Int> = []

    private enum DownloadSort: String, CaseIterable {
        case newestFirst = "Newest First"
        case oldestFirst = "Oldest First"
        case byShow = "By Show"
    }

    private var activeDownloads: [(episode: EpisodeItem?, id: Int, progress: Double)] {
        downloads.downloadProgress.map { (
            episode: downloads.downloadingEpisodes[$0.key] ?? downloads.episodeMetadata[$0.key],
            id: $0.key,
            progress: $0.value
        )}
        .sorted { $0.id < $1.id }
    }

    private var sortedEpisodes: [EpisodeItem] {
        let base = downloads.locallyDownloaded.compactMap { downloads.episodeMetadata[$0] }
        switch sortOrder {
        case .newestFirst:
            return base.sorted { $0.pubDate > $1.pubDate }
        case .oldestFirst:
            return base.sorted { $0.pubDate < $1.pubDate }
        case .byShow:
            return base.sorted {
                if $0.podcastName != $1.podcastName { return $0.podcastName < $1.podcastName }
                return $0.pubDate > $1.pubDate
            }
        }
    }

    private var episodesByShow: [(show: String, episodes: [EpisodeItem])] {
        var groups: [(show: String, episodes: [EpisodeItem])] = []
        var index: [String: Int] = [:]
        for ep in sortedEpisodes {
            if let i = index[ep.podcastName] {
                groups[i].episodes.append(ep)
            } else {
                index[ep.podcastName] = groups.count
                groups.append((show: ep.podcastName, episodes: [ep]))
            }
        }
        return groups
    }

    private var totalSize: String {
        let bytes = downloads.locallyDownloaded.reduce(0) { sum, id in
            guard let url = downloads.fileURL(for: id) else { return sum }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            return sum + size
        }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func fileSize(for id: Int) -> String {
        guard let url = downloads.fileURL(for: id) else { return "0 bytes" }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    @ViewBuilder
    private func episodeRow(_ episode: EpisodeItem) -> some View {
        HStack(spacing: 12) {
            PodcastArtworkView(url: episode.artwork, size: 44, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if sortOrder != .byShow {
                    Text(episode.podcastName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(fileSize(for: episode.id))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if isSelecting {
                Image(systemName: selectedIds.contains(episode.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selectedIds.contains(episode.id) ? Color.accentColor : Color.secondary)
            } else {
                Button {
                    let localURL = downloads.localURL(for: episode.id)
                    player.play(episode: episode, localURL: localURL)
                    dismiss()
                } label: {
                    Image(systemName: "play.circle")
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard isSelecting else { return }
            if selectedIds.contains(episode.id) {
                selectedIds.remove(episode.id)
            } else {
                selectedIds.insert(episode.id)
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isSelecting {
                    HStack {
                        Button(selectedIds.count == sortedEpisodes.count ? "Deselect All" : "Select All") {
                            if selectedIds.count == sortedEpisodes.count {
                                selectedIds = []
                            } else {
                                selectedIds = Set(sortedEpisodes.map(\.id))
                            }
                        }
                        .font(.subheadline)
                        Spacer()
                        Text("\(selectedIds.count) selected")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                downloadsList
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .task { await downloads.syncMissingMetadata() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Sort", selection: $sortOrder) {
                            ForEach(DownloadSort.allCases, id: \.self) { order in
                                Text(order.rawValue).tag(order)
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if !sortedEpisodes.isEmpty {
                        Button(isSelecting ? "Cancel" : "Select") {
                            isSelecting.toggle()
                            if !isSelecting { selectedIds = [] }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSelecting {
                        Button(role: .destructive) {
                            selectedIds.forEach { downloads.deleteLocalDownload($0) }
                            selectedIds = []
                            isSelecting = false
                        } label: {
                            Text("Delete (\(selectedIds.count))")
                        }
                        .disabled(selectedIds.isEmpty)
                    } else {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
    }

    private var downloadsList: some View {
        List {
                // Active downloads
                if !activeDownloads.isEmpty {
                    Section("Downloading") {
                        ForEach(activeDownloads, id: \.id) { item in
                            HStack(spacing: 12) {
                                ZStack {
                                    if let artwork = item.episode?.artwork {
                                        PodcastArtworkView(url: artwork, size: 44, cornerRadius: 6)
                                    } else {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.secondary.opacity(0.2))
                                            .frame(width: 44, height: 44)
                                    }
                                    ZStack {
                                        Circle()
                                            .stroke(Color.black.opacity(0.35), lineWidth: 3)
                                        Circle()
                                            .trim(from: 0, to: item.progress)
                                            .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                            .rotationEffect(.degrees(-90))
                                            .animation(.linear(duration: 0.2), value: item.progress)
                                    }
                                    .frame(width: 28, height: 28)
                                }
                                .frame(width: 44, height: 44)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.episode?.title ?? "Episode \(item.id)")
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    if let podcastName = item.episode?.podcastName {
                                        Text(podcastName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Text("\(Int(item.progress * 100))%")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }

                                Spacer()

                                Button {
                                    downloads.cancelDownload(item.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // Completed downloads — flat or grouped
                if sortedEpisodes.isEmpty && activeDownloads.isEmpty {
                    ContentUnavailableView(
                        "No Downloads",
                        systemImage: "arrow.down.circle",
                        description: Text("Downloaded episodes will appear here.")
                    )
                } else if sortOrder == .byShow {
                    ForEach(episodesByShow, id: \.show) { group in
                        Section(group.show) {
                            ForEach(group.episodes) { episode in
                                episodeRow(episode)
                            }
                            .onDelete { offsets in
                                let ids = offsets.map { group.episodes[$0].id }
                                ids.forEach { downloads.deleteLocalDownload($0) }
                            }
                        }
                    }
                } else if !sortedEpisodes.isEmpty {
                    Section {
                        ForEach(sortedEpisodes) { episode in
                            episodeRow(episode)
                        }
                        .onDelete { offsets in
                            let ids = offsets.map { sortedEpisodes[$0].id }
                            ids.forEach { downloads.deleteLocalDownload($0) }
                        }
                    } header: {
                        Text("Downloaded · \(totalSize)")
                    }
                }
        }
    }
}
