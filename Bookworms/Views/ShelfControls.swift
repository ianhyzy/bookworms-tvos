import SwiftUI

/// View-specific status rendered on screen in the bottom-right position.
struct ViewSpecificControls: View {
    let library: LibraryModel
    let coordinator: BookwormsCoordinator
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("woodBackground") private var woodBackground = true
    private var palette: ShelfPalette {
        ShelfPalette(isDark: colorScheme == .dark, isWood: woodBackground)
    }

    var body: some View {
        HStack(spacing: 16) {
            if library.isLoading {
                ProgressView().tint(palette.text).accessibilityLabel("Loading library")
            }
        }
    }
}
