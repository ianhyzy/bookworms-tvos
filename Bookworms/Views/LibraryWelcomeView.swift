import SwiftUI

/// Keeps first-run setup modal until the selected library is ready to browse.
struct LibraryWelcomeView: View {
    let library: LibraryModel
    let isLibraryReady: @MainActor () -> Bool
    let onDismiss: () -> Void

    @State private var stage = Stage.choices
    @State private var exampleFailed = false
    @FocusState private var focusedChoice: Choice?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Stage: Equatable { case choices, connection, preparation }
    private enum Choice { case hardcover, example }

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
                .padding(.bottom, 16)
            VStack(spacing: 34) {
                Button("Connect Hardcover") { stage = .connection }
                    .buttonStyle(.glassProminent)
                    .focused($focusedChoice, equals: .hardcover)
                    .accessibilityIdentifier("welcome-connect-hardcover")
                if library.offersExample {
                    Button("View example profile", action: showExample)
                        .buttonStyle(.glass)
                        .focused($focusedChoice, equals: .example)
                        .accessibilityIdentifier("welcome-example-profile")
                }
            }
            .appFont(size: 28, weight: .medium)
            .focusSection()
            .defaultFocus($focusedChoice, .hardcover, priority: .userInitiated)
            .disabled(library.isLoading)
            if library.isLoading {
                ProgressView("Please wait…").appFont(size: 26)
            } else if exampleFailed {
                Text("The example profile couldn't be opened.")
                    .appFont(size: 26)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Prepares the example profile behind the preparation card, which closes once its shelf is
    /// ready (`isLibraryReady`). A profile that can't be read returns to the choices.
    private func showExample() {
        exampleFailed = false
        stage = .preparation
        Task {
            guard !(await library.showExample()), library.books.isEmpty else { return }
            exampleFailed = true
            stage = .choices
        }
    }

    private var preparation: some View {
        VStack(spacing: 28) {
            ProgressView().controlSize(.large)
            // Neutral wording, since the shelf can be the example profile's.
            Text("Preparing the shelf").appFont(size: 42, weight: .semibold)
            Text("Loading covers and arranging the books…")
                .appFont(size: 26)
                .foregroundStyle(.secondary)
            Text("The books will appear when they're ready.")
                .appFont(size: 26)
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
