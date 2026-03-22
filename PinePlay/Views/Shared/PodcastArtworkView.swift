import SwiftUI
import UIKit

struct PodcastArtworkView: View {
    let url: String?
    var size: CGFloat = 56
    var cornerRadius: CGFloat = 8
    var downloadProgress: Double? = nil  // 0–1 while downloading, nil otherwise

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholderView
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay {
            if let progress = downloadProgress {
                GeometryReader { geo in
                    let side = min(geo.size.width, geo.size.height)
                    ZStack {
                        Color.black.opacity(0.35)
                        Circle()
                            .stroke(Color.white.opacity(0.3), lineWidth: 3)
                            .frame(width: side * 0.55, height: side * 0.55)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .frame(width: side * 0.55, height: side * 0.55)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.2), value: progress)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                }
            }
        }
        .task(id: url) {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard let urlString = url, let imageURL = URL(string: urlString) else { return }

        // Instant cache hit — no async work needed
        if let cached = ImageCache.shared.get(urlString) {
            image = cached
            return
        }

        var request = URLRequest(url: imageURL)
        request.timeoutInterval = 30
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let loaded = UIImage(data: data) else { return }

        ImageCache.shared.set(loaded, for: urlString)

        // Check task wasn't cancelled while loading
        guard !Task.isCancelled else { return }
        image = loaded
    }

    private var placeholderView: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.secondary.opacity(0.15))
                .overlay(
                    Image(systemName: "headphones")
                        .font(.system(size: side * 0.35))
                        .foregroundStyle(.secondary)
                )
        }
    }
}

// MARK: - Glass Card Modifier
// Uses iOS 26 glassEffect when available, regularMaterial fallback otherwise.

struct GlassCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(in: .rect(cornerRadius: 20))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }
}

// MARK: - HTML Inline View
// Lightweight HTML renderer for snippets (lineLimit-friendly).
// Uses AttributedString parsed on a background thread.

struct HTMLInlineView: View {
    let text: String
    var lineLimit: Int? = nil

    @State private var attributed: AttributedString?

    private var looksLikeHTML: Bool {
        text.contains("<") && text.contains(">")
    }

    var body: some View {
        Group {
            if let attributed {
                Text(attributed)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: text) {
            guard looksLikeHTML else { return }
            attributed = await parseHTML(text)
        }
    }

    private func parseHTML(_ html: String) async -> AttributedString? {
        await Task.detached(priority: .utility) {
            let styled = """
                <style>body { font-family: -apple-system; font-size: 12px; color: inherit; }</style>
                \(html)
                """
            guard let data = styled.data(using: .utf8),
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
