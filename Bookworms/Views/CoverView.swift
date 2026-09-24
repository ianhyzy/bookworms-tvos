import SwiftUI

struct CoverView: View {
    let book: Book
    /// Draws a contact shadow where the cover's base meets a `ShelfBoard`.
    var standsOnShelf = false
    var onAspectRatio: ((Double) -> Void)? = nil
    @Environment(\.isFocused) private var isFocused
    @Environment(\.coverIsPressed) private var isPressed
    @Environment(\.artworkGeneration) private var artworkGeneration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var loadedBookID: Int?
    /// The decode size for this cover's on-screen height, set after the first layout.
    @State private var pixelSize: Int?
    @State private var failed = false

    var body: some View {
        let currentImage =
            (loadedBookID == book.id ? image : nil)
            ?? CoverImageCache.shared.uiImage(for: book, size: pixelSize ?? 800)
        GeometryReader { geometry in
            let ratio = currentImage.map { $0.size.width / $0.size.height } ?? (2.0 / 3.0)
            let height = min(geometry.size.height, geometry.size.width / ratio)
            let width = height * ratio
            let cornerRadius = height * 0.012
            if standsOnShelf, currentImage != nil {
                // Darkens the shelf where the base touches it; a gradient, not a blur, so it
                // costs nothing to draw. It lightens while focus lifts the cover.
                EllipticalGradient(colors: [.black.opacity(0.4), .black.opacity(0)])
                    .frame(width: width * 1.12, height: max(8, height * 0.045))
                    .opacity(isFocused && !reduceMotion ? 0.45 : 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isFocused)
                    .position(x: geometry.size.width / 2, y: geometry.size.height)
            }
            artwork(with: currentImage, compact: geometry.size.height < 350)
                .frame(width: width, height: height)
                .clipShape(.rect(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.white.opacity(isFocused ? 0.08 : 0))
                        .allowsHitTesting(false)
                }
                .background {
                    // A fixed-radius shadow on a simple shape that fades in with focus, which
                    // composites cheaply; animating a blur radius re-renders it every frame.
                    // Resting covers have no shadow so they sit cleanly on the shelf line.
                    if currentImage != nil {
                        RoundedRectangle(cornerRadius: cornerRadius).fill(.black)
                            .shadow(
                                color: .black.opacity(0.38), radius: height * 0.028,
                                y: height * 0.018
                            )
                            .opacity(isFocused ? 1 : 0)
                    }
                }
                .opacity(isPressed ? 0.85 : 1)
                .scaleEffect(reduceMotion || !isFocused ? 1 : 1.04, anchor: .bottom)
                // Focus lifts the cover off the shelf.
                .offset(y: isFocused && !reduceMotion ? -height * 0.03 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isFocused)
                // On a shelf, a cover narrower than its frame stands at the bottom.
                .position(
                    x: geometry.size.width / 2,
                    y: standsOnShelf
                        ? geometry.size.height - height / 2 : geometry.size.height / 2)
        }
        .onGeometryChange(for: Int.self) { [displayScale] proxy in
            CoverSize.bucket(forPixels: proxy.size.height * displayScale)
        } action: {
            pixelSize = $0
        }
        .task(
            id:
                "\(book.id):\(pixelSize ?? 0):\(book.coverURL?.absoluteString ?? ""):\(book.detailCoverURL?.absoluteString ?? ""):\(artworkGeneration)"
        ) { await load() }
    }

    /// Shows the nearest cached size at once, then decodes the exact size from the disk cache when
    /// the cached one is smaller than the cover's on-screen pixels. Never downloads.
    private func load() async {
        guard let pixelSize else { return }
        if let cached = CoverImageCache.shared.image(for: book, size: pixelSize) {
            show(cached)
            if max(cached.width, cached.height) >= pixelSize
                || CoverImageCache.shared.exactImage(for: book, size: pixelSize) != nil
            {
                return
            }
        }
        failed = false
        guard book.coverURL != nil || book.detailCoverURL != nil else { return }
        do {
            let decoded = try await ArtworkStore.shared.detailImage(
                for: book, maximumPixelSize: pixelSize, allowsNetwork: false)
            try Task.checkCancellation()
            show(decoded)
        } catch {
            if !Task.isCancelled, loadedBookID != book.id { failed = true }
        }
    }

    private func show(_ decoded: CGImage) {
        image = UIImage(cgImage: decoded)
        loadedBookID = book.id
        onAspectRatio?(Double(decoded.width) / Double(decoded.height))
    }

    private func artwork(with currentImage: UIImage?, compact: Bool) -> some View {
        ZStack {
            if let currentImage {
                Image(uiImage: currentImage).resizable().scaledToFit()
                    .accessibilityLabel("Cover of \(book.title)")
                    .accessibilityIdentifier("detail-cover")
            } else {
                Rectangle().fill(.gray.opacity(0.18))
                VStack(spacing: compact ? 12 : 20) {
                    Image(systemName: "book.closed")
                        .appFont(size: compact ? 32 : 48)
                        .accessibilityHidden(true)
                    Text(book.title).appFont(size: compact ? 23 : 30)
                        .multilineTextAlignment(.center).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(book.author).appFont(size: 20).lineLimit(2)
                        .multilineTextAlignment(.center)
                    if !compact {
                        Text(
                            (book.coverURL == nil && book.detailCoverURL == nil) || failed
                                ? "Cover unavailable" : "Loading cover…"
                        )
                        .appFont(size: 22).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .padding(compact ? 12 : 28)
            }
        }
    }

}

extension EnvironmentValues {
    @Entry var coverIsPressed = false
    /// Changes after background artwork preparation so mounted covers reload from the local cache.
    @Entry var artworkGeneration = 0
}

/// Keep focus decoration on the artwork rather than the surrounding card or letterboxing.
struct CoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.coverIsPressed, configuration.isPressed)
    }
}
