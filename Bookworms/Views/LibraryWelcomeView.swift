import SwiftUI

/// Keeps first-run setup modal until the selected library is ready to browse.
struct LibraryWelcomeView: View {
    let library: LibraryModel
    let isLibraryReady: @MainActor () -> Bool
    let onDismiss: () -> Void

    @State private var stage = Stage.choices
    @FocusState private var focusedChoice: Choice?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Stage: Equatable { case choices, connection, preparation }
    private enum Choice { case hardcover, sample }

    var body: some View {
        VStack(spacing: 0) {
            switch stage {
            case .choices:
                choices.transition(contentTransition)
            case .connection:
                HardcoverConnectionView(library: library) { stage = .preparation }
                    .transition(contentTransition)
            case .preparation:
                preparation.transition(contentTransition)
            }
        }
        .frame(width: stage == .connection ? 1380 : 940)
        .padding(64)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: stage)
        .interactiveDismissDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library-welcome")
        .onChange(of: stage) { finishIfReady() }
        .onChange(of: isLibraryReady()) { finishIfReady() }
        .onExitCommand {
            switch stage {
            case .choices: onDismiss()
            case .connection: stage = .choices
            case .preparation: finish()
            }
        }
    }

    private var contentTransition: AnyTransition {
        reduceMotion ? .identity : .opacity
    }

    private var choices: some View {
        VStack(spacing: 24) {
            Image(systemName: "books.vertical")
                .appFont(size: 68, weight: .light)
                .accessibilityHidden(true)
            Text("Welcome to Bookworms").appFont(size: 46, weight: .semibold)
            Text("Bring your Hardcover library to the big screen, or explore a sample library.")
                .appFont(size: 26)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 16)
            VStack(spacing: 24) {
                Button("Connect Hardcover") { stage = .connection }
                    .buttonStyle(.glassProminent)
                    .focused($focusedChoice, equals: .hardcover)
                    .accessibilityIdentifier("welcome-connect-hardcover")
                Button("Explore sample library") {
                    library.showSample()
                    if library.isSample { stage = .preparation }
                }
                .buttonStyle(.glass)
                .focused($focusedChoice, equals: .sample)
                .accessibilityIdentifier("welcome-sample-library")
            }
            .appFont(size: 28, weight: .medium)
            .focusSection()
            .defaultFocus($focusedChoice, .hardcover, priority: .userInitiated)
            .disabled(library.isLoading)
            if library.isLoading {
                ProgressView("Please wait…").appFont(size: 23)
            }
        }
    }

    private var preparation: some View {
        VStack(spacing: 28) {
            ProgressView().controlSize(.large)
            Text("Preparing your library").appFont(size: 42, weight: .semibold)
            Text("Loading covers and arranging your shelf…")
                .appFont(size: 26)
                .foregroundStyle(.secondary)
            Text("Your books will appear when they're ready.")
                .appFont(size: 23)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 60)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("welcome-preparing-library")
    }

    private func finishIfReady() {
        // The sheet can retain the empty shelf's readiness while newly downloaded books publish.
        guard stage == .preparation, isLibraryReady() else { return }
        finish()
    }

    private func finish() {
        library.completeWelcome()
        onDismiss()
    }
}
