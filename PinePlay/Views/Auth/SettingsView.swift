import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var api: PinepodsAPIService
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var player: AudioPlayerManager
    @Environment(\.dismiss) var dismiss

    @State private var autoDownloadEnabled: Bool
    @State private var wifiOnly: Bool
    @State private var maxEpisodes: Int
    @State private var downloadAllShows: Bool
    @State private var selectedPodcastNames: Set<String>
    @State private var showLogoutConfirm = false

    init() {
        let s = AutoDownloadSettings.load()
        _autoDownloadEnabled = State(initialValue: s.enabled)
        _wifiOnly = State(initialValue: s.onWifiOnly)
        _maxEpisodes = State(initialValue: s.maxEpisodes)
        _downloadAllShows = State(initialValue: s.downloadAllShows)
        _selectedPodcastNames = State(initialValue: s.selectedPodcastNames)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if let config = api.config {
                        LabeledContent("Server", value: config.serverURL)
                        LabeledContent("Username", value: config.username)
                    }

                    Button("Log Out", role: .destructive) {
                        showLogoutConfirm = true
                    }
                }

                Section("Appearance") {
                    Toggle("Artwork Accent Colour", isOn: $player.useArtworkAccent)
                    NavigationLink {
                        PodcastAccentColoursView()
                    } label: {
                        Text("Per-Show Colours")
                    }
                }

                Section("Auto Downloads") {
                    Toggle("Enable Auto Downloads", isOn: $autoDownloadEnabled)
                    Toggle("Wi-Fi Only", isOn: $wifiOnly)
                        .disabled(!autoDownloadEnabled)
                    Stepper("Max \(maxEpisodes) episodes per show", value: $maxEpisodes, in: 1...20)
                        .disabled(!autoDownloadEnabled)
                    NavigationLink {
                        AutoDownloadShowsView(downloadAllShows: $downloadAllShows, selectedPodcastNames: $selectedPodcastNames)
                    } label: {
                        HStack {
                            Text("Shows")
                            Spacer()
                            Text(downloadAllShows ? "All" : (selectedPodcastNames.isEmpty ? "None" : "\(selectedPodcastNames.count) selected"))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!autoDownloadEnabled)
                }

                Section("Storage") {
                    let count = downloads.locallyDownloaded.count
                    LabeledContent("Downloaded Episodes", value: "\(count)")
                    Button("Delete All Local Downloads", role: .destructive) {
                        for id in downloads.locallyDownloaded {
                            downloads.deleteLocalDownload(id)
                        }
                    }
                    .disabled(count == 0)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        saveSettings()
                        dismiss()
                    }
                }
            }
            .confirmationDialog("Log Out", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
                Button("Log Out", role: .destructive) {
                    api.logout()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll need to reconnect to your server to use the app.")
            }
        }
    }

    private func saveSettings() {
        var s = AutoDownloadSettings()
        s.enabled = autoDownloadEnabled
        s.onWifiOnly = wifiOnly
        s.maxEpisodes = maxEpisodes
        s.downloadAllShows = downloadAllShows
        s.selectedPodcastNames = selectedPodcastNames
        s.save()
        downloads.autoDownloadSettings = s
    }
}

// MARK: - Per-Show Accent Colours

struct PodcastAccentColoursView: View {
    @EnvironmentObject var api: PinepodsAPIService
    @EnvironmentObject var player: AudioPlayerManager

    @State private var podcasts: [PodcastItem] = []
    @State private var isLoading = false
    @State private var customColours: [String: String] = PodcastAccentColors.load()

    var body: some View {
        List {
            Section(footer: Text("Auto uses the artwork colour. Tap a swatch to pick a custom colour, or remove it to go back to auto.")) {
                if isLoading {
                    ProgressView()
                } else {
                    ForEach(podcasts) { podcast in
                        PodcastColourRow(
                            podcastName: podcast.name,
                            artworkURL: podcast.artworkURL,
                            customColours: $customColours
                        )
                    }
                }
            }
        }
        .navigationTitle("Per-Show Colours")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            isLoading = true
            podcasts = (try? await api.getPodcasts()) ?? []
            isLoading = false
        }
        .onChange(of: customColours) { _, newValue in
            PodcastAccentColors.save(newValue)
            // Refresh accent if the currently playing show was changed
            if let ep = player.currentEpisode {
                Task { await player.refreshAccentColor(for: ep) }
            }
        }
    }
}

struct PodcastColourRow: View {
    let podcastName: String
    let artworkURL: String?
    @Binding var customColours: [String: String]

    @State private var pickerColour: Color = .yellow
    @State private var showPicker = false
    @State private var showSampler = false

    private var hasCustom: Bool { customColours[podcastName] != nil }
    private var currentColour: Color {
        customColours[podcastName].flatMap { Color(hex: $0) } ?? Color(.systemFill)
    }

    var body: some View {
        HStack {
            Text(podcastName)
                .lineLimit(1)
            Spacer()
            if hasCustom {
                Button {
                    customColours.removeValue(forKey: podcastName)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Button {
                if let existing = customColours[podcastName] {
                    pickerColour = Color(hex: existing) ?? .yellow
                }
                showPicker = true
            } label: {
                RoundedRectangle(cornerRadius: 6)
                    .fill(currentColour)
                    .frame(width: 32, height: 32)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(.separator), lineWidth: 0.5)
                    )
                    .overlay(
                        Group {
                            if !hasCustom {
                                Image(systemName: "paintpalette")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 14))
                            }
                        }
                    )
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showPicker) {
                NavigationStack {
                    VStack(spacing: 24) {
                        ColorPicker("Pick a colour for \(podcastName)", selection: $pickerColour, supportsOpacity: false)

                        Button {
                            showSampler = true
                        } label: {
                            Label("Sample from Artwork", systemImage: "eyedropper")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(artworkURL == nil)
                    }
                    .padding()
                    .navigationTitle(podcastName)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") {
                                customColours[podcastName] = pickerColour.hexString
                                showPicker = false
                            }
                        }
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Cancel") { showPicker = false }
                        }
                    }
                }
                .presentationDetents([.medium])
                .sheet(isPresented: $showSampler) {
                    if let url = artworkURL {
                        ArtworkColourSamplerView(imageURL: url) { colour in
                            pickerColour = colour
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Artwork colour sampler

struct ArtworkColourSamplerView: View {
    let imageURL: String
    let onSelect: (Color) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var uiImage: UIImage?
    @State private var samplingImage: UIImage?   // 256-px render used for per-pixel reads
    @State private var isLoading = true
    @State private var sampledColour: Color = .gray
    @State private var indicator: CGPoint?       // position in the displayed image frame

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if isLoading {
                    ProgressView("Loading artwork…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let img = uiImage {
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay {
                                GeometryReader { geo in
                                    let frame = geo.frame(in: .local)
                                    Color.clear
                                        .contentShape(Rectangle())
                                        .gesture(
                                            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                                .onChanged { val in
                                                    let loc = val.location
                                                    let norm = CGPoint(
                                                        x: max(0, min(loc.x / frame.width,  1)),
                                                        y: max(0, min(loc.y / frame.height, 1))
                                                    )
                                                    indicator = loc
                                                    sampledColour = samplingImage?.pixelColour(at: norm) ?? .gray
                                                }
                                        )
                                }
                            }

                        if let pt = indicator {
                            Circle()
                                .strokeBorder(.white, lineWidth: 2.5)
                                .background(Circle().fill(sampledColour))
                                .frame(width: 32, height: 32)
                                .shadow(color: .black.opacity(0.35), radius: 3)
                                .offset(x: pt.x - 16, y: pt.y - 16)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.horizontal)

                    HStack(spacing: 12) {
                        if indicator != nil {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(sampledColour)
                                .frame(width: 40, height: 40)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Color(.separator), lineWidth: 0.5)
                                )
                        }
                        Text(indicator == nil
                             ? "Tap or drag the artwork to pick a colour"
                             : "Tap OK to use this colour")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Could not load artwork")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                }

                Spacer()
            }
            .padding(.top)
            .navigationTitle("Sample Colour")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("OK") {
                        onSelect(sampledColour)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(indicator == nil)
                }
            }
        }
        .task {
            guard let url = URL(string: imageURL),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let loaded = UIImage(data: data) else {
                isLoading = false
                return
            }
            // Pre-render a 256×256 bitmap so per-pixel reads during drag are fast
            let side: CGFloat = 256
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
            let small = renderer.image { _ in loaded.draw(in: CGRect(x: 0, y: 0, width: side, height: side)) }
            uiImage = loaded
            samplingImage = small
            isLoading = false
        }
    }
}

private extension UIImage {
    /// Returns the colour of the pixel at a normalised point (origin top-left, both axes 0…1).
    func pixelColour(at normalised: CGPoint) -> Color? {
        guard let cgImg = cgImage else { return nil }
        let w = cgImg.width, h = cgImg.height
        let px = min(max(Int(normalised.x * CGFloat(w)), 0), w - 1)
        let py = min(max(Int(normalised.y * CGFloat(h)), 0), h - 1)

        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(
            data: &pixel, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        // CGImage y=0 is at the bottom; normalised y=0 is at the top — flip accordingly
        ctx.translateBy(x: CGFloat(-px), y: CGFloat(-(h - 1 - py)))
        ctx.draw(cgImg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Color(red: CGFloat(pixel[0]) / 255,
                     green: CGFloat(pixel[1]) / 255,
                     blue: CGFloat(pixel[2]) / 255)
    }
}

// MARK: - Show Picker

struct AutoDownloadShowsView: View {
    @EnvironmentObject var api: PinepodsAPIService
    @Binding var downloadAllShows: Bool
    @Binding var selectedPodcastNames: Set<String>

    @State private var podcasts: [PodcastItem] = []
    @State private var isLoading = false

    private func isSelected(_ name: String) -> Bool {
        downloadAllShows || selectedPodcastNames.contains(name)
    }

    private func toggle(_ name: String) {
        if downloadAllShows {
            // Switch from "all" to explicit — pre-select every show except the one being toggled off
            downloadAllShows = false
            selectedPodcastNames = Set(podcasts.map(\.name).filter { $0 != name })
        } else if selectedPodcastNames.contains(name) {
            selectedPodcastNames.remove(name)
        } else {
            selectedPodcastNames.insert(name)
            // If every show is now checked, switch back to the "all" shortcut
            if selectedPodcastNames.count == podcasts.count {
                downloadAllShows = true
                selectedPodcastNames = []
            }
        }
    }

    var body: some View {
        List {
            Section {
                Button("Select All") {
                    downloadAllShows = true
                    selectedPodcastNames = []
                }
                Button("Select None") {
                    downloadAllShows = false
                    selectedPodcastNames = []
                }
            }

            Section("Podcasts") {
                if isLoading {
                    ProgressView()
                } else {
                    ForEach(podcasts) { podcast in
                        Button {
                            toggle(podcast.name)
                        } label: {
                            HStack {
                                Text(podcast.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if isSelected(podcast.name) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Auto-Download Shows")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            isLoading = true
            podcasts = (try? await api.getPodcasts()) ?? []
            isLoading = false
        }
    }
}
