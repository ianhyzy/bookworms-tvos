import SwiftUI

/// App-wide and library settings, shown as a sidebar destination.
///
/// Per-view choices such as the comparison reader and ordering live on their views. Ambient
/// timing lives on the Ambient page.
struct SettingsView: View {
    @AppStorage("fontStyle") private var fontStyle = AppFontStyle.serif
    @AppStorage("dateFormat") private var dateFormat = AppDateFormat.monthName
    @Bindable var library: LibraryModel
    let social: SocialLibraryModel
    @Bindable var coordinator: BookwormsCoordinator
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appearance") private var appearance = AppAppearance.system
    @AppStorage("woodBackground") private var woodBackground = true
    @AppStorage("spoilerPolicy") private var spoilerPolicy = SpoilerPolicy.alwaysHide
    @State private var token = ""
    @State private var apiKey = ""
    @State private var sourceEditor: LibrarySource?
    @State private var cwaDraft = CWAConfiguration()
    @State private var cwaPassword = ""
    enum Section: String, CaseIterable, Identifiable {
        case views = "Views"
        case shelf = "Shelf"
        case ai = "AI spines"
        case sources = "Sources"
        case general = "General"
        var id: Self { self }
        static var visibleSections: [Self] {
            allCases.filter { $0 != .ai || BookPresentation.showsGeneratedSpines }
        }
    }
    @Binding var section: Section
    /// Leaves Settings for My Shelf, for example after choosing the sample shelf.
    let onShowShelf: () -> Void

    /// The section Settings shows first. Debug builds accept `--settings-tab=NAME`.
    static func initialSection() -> Section {
        #if DEBUG
            if let argument = ProcessInfo.processInfo.arguments.first(where: {
                $0.hasPrefix("--settings-tab=")
            }),
                let requested = Section(
                    rawValue: String(argument.dropFirst("--settings-tab=".count))),
                Section.visibleSections.contains(requested)
            {
                return requested
            }
        #endif
        return .shelf
    }

    var body: some View {
        ZStack {
            (colorScheme == .dark
                ? Color(red: 0.09, green: 0.12, blue: 0.14)
                : Color(red: 0.95, green: 0.94, blue: 0.91))
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 28) {
                sectionBar
                ScrollView {
                    Group {
                        switch section {
                        case .views: viewsSettings
                        case .shelf: shelfSettings
                        case .ai: aiSettings
                        case .sources: sourcesSettings
                        case .general: generalSettings
                        }
                    }
                    .padding(.vertical, 20).padding(.horizontal, 10)
                    // A full-width section catches Down from any section tab, even one with no
                    // control directly below it.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focusSection()
                }
            }
            // Matches the header position of Compare Shelves and Book Club, level with the
            // sidebar's collapsed title.
            .padding(.top, 54)
            .padding(.horizontal, 80)
            .padding(.bottom, 40)
        }
        .ignoresSafeArea(edges: .top)
        .sheet(item: $sourceEditor) { source in
            VStack(alignment: .leading, spacing: 25) {
                Button("Back to Sources") {
                    library.cancelHardcoverDeviceAuth()
                    sourceEditor = nil
                }
                .font(.system(size: 26))
                .performanceGlassButton()
                ScrollView {
                    if source == .hardcover { accountSettings } else { cwaSettings }
                }
            }
            .padding(65)
            .font(.system(size: 26))
            .fontDesign(.default)
            .onExitCommand {
                library.cancelHardcoverDeviceAuth()
                sourceEditor = nil
            }
            .onAppear {
                if source == .hardcover, !library.hardcoverConnected {
                    library.startHardcoverDeviceAuth()
                }
            }
            .onDisappear {
                library.cancelHardcoverDeviceAuth()
                token = ""
                cwaPassword = ""
            }
            .onChange(of: library.hardcoverConnected) { _, connected in
                if connected {
                    token = ""
                    sourceEditor = nil
                }
            }
        }
        #if BOOKWORMS_DIAGNOSTICS
            .onAppear { PerformanceDiagnostics.event("SettingsReady") }
            .onChange(of: section) { PerformanceDiagnostics.event("SettingsSection") }
        #endif
        .font(.system(size: 26))
        // Settings always uses the system font; only the font sample previews a style.
        .fontDesign(.default)
        .onDisappear {
            token = ""
            apiKey = ""
        }
    }

    /// The native segmented control for sections, in the header row level with the sidebar title.
    private var sectionBar: some View {
        HStack {
            Spacer()
            Picker("Settings", selection: $section) {
                ForEach(Section.visibleSections) {
                    Text($0.rawValue).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 1150)
            .accessibilityIdentifier("settings-sections")
        }
        .focusSection()
    }

    private func settingLabel(_ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 26, weight: .medium))
            Text(description).font(.system(size: 23))
                .foregroundStyle(.secondary)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 23)).foregroundStyle(.secondary)
    }

    /// Lays out a section in two equal columns to use widescreen space.
    private func columns<Leading: View, Trailing: View>(
        @ViewBuilder _ leading: () -> Leading, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .top, spacing: 80) {
            VStack(alignment: .leading, spacing: 24, content: leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 24, content: trailing)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Sets a book limit in steps of five, from 5 to `BookLimit.maximum`.
    ///
    /// The buttons stay enabled at the limits and do nothing there, because disabling the
    /// focused button would force focus to jump elsewhere.
    private func countCard(
        _ title: String, _ description: String, count: Binding<Int>,
        identifiers: (fewer: String, value: String, more: String)
    ) -> some View {
        let value = count.wrappedValue
        return VStack(alignment: .leading, spacing: 20) {
            settingLabel(title, description)
            HStack(spacing: 36) {
                Spacer(minLength: 0)
                countButton("minus", isAtLimit: value <= 5) {
                    count.wrappedValue = max(5, (value - 1) / 5 * 5)
                }
                .accessibilityLabel("Fewer books")
                .accessibilityIdentifier(identifiers.fewer)
                VStack(spacing: 2) {
                    Text("\(value)")
                        .font(.system(size: 64, weight: .semibold)).monospacedDigit()
                        .accessibilityIdentifier(identifiers.value)
                    Text("of \(BookLimit.maximum) books").font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 160)
                .padding(.vertical, 14).padding(.horizontal, 24)
                .background(.regularMaterial, in: .rect(cornerRadius: 32))
                countButton("plus", isAtLimit: value >= BookLimit.maximum) {
                    count.wrappedValue = min(BookLimit.maximum, value / 5 * 5 + 5)
                }
                .accessibilityLabel("More books")
                .accessibilityIdentifier(identifiers.more)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    private func countButton(
        _ systemImage: String, isAtLimit: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .semibold))
                .frame(width: 56, height: 56)
                .opacity(isAtLimit ? 0.35 : 1)
        }
        .buttonBorderShape(.circle)
        .performanceGlassButton()
        .accessibilityValue(isAtLimit ? "At limit" : "")
    }

    private var shelfSettings: some View {
        columns {
            settingLabel("Collection", "Choose which books appear.")
            Picker("Show", selection: $library.shelfPreferences.collection) {
                ForEach(ShelfCollection.allCases) {
                    Text($0.rawValue).font(.system(size: 26)).tag($0)
                }
            }
            .pickerStyle(.segmented).accessibilityIdentifier("shelf-collection")
            settingLabel("Order", "Missing values stay last in either order.")
            HStack(spacing: 35) {
                Picker("Sort by", selection: $library.shelfPreferences.sort) {
                    ForEach(ShelfSort.allCases) {
                        Text($0.rawValue).font(.system(size: 26))
                            .tag($0)
                    }
                }
                .pickerStyle(.menu).accessibilityIdentifier("shelf-sort")
                .accessibilityLabel("Sort by")
                .accessibilityValue(library.shelfPreferences.sort.rawValue)
                .font(.system(size: 26))
                Toggle("Reverse order", isOn: $library.shelfPreferences.reversed)
                    .font(.system(size: 26))
            }
        } trailing: {
            countCard(
                "Books shown", "Books from enabled sources on My Shelf.",
                count: $library.bookCount,
                identifiers: ("fewer-books", "book-limit", "more-books-count"))
            Button("Reset shelf choices") {
                library.shelfPreferences = ShelfPreferences()
                library.bookCount = BookLimit.maximum
            }
            .font(.system(size: 26))
            .performanceGlassButton()
        }
        .disabled(library.isGenerating)
    }

    private var viewsSettings: some View {
        columns {
            settingLabel(
                "Views",
                "Choose which views appear in the menu. My Shelf stays on. Choose ambient views on the Ambient page."
            )
            ForEach(BookwormsView.allCases.filter { $0 != .shelf }) { view in
                Toggle(
                    view.rawValue,
                    isOn: Binding(
                        get: { coordinator.preferences.enabled.contains(view) },
                        set: { coordinator.setEnabled(view, $0) }
                    )
                )
                .font(.system(size: 26))
            }
        } trailing: {
            countCard(
                "Comparison limit",
                "Books per reader in Compare Shelves and Book Club. Choose the reader and order on each view.",
                count: $coordinator.preferences.comparisonCount,
                identifiers: ("fewer-comparison-books", "comparison-limit", "more-comparison-books")
            )
        }
    }

    private var sourcesSettings: some View {
        VStack(alignment: .leading, spacing: 25) {
            note(
                BookPresentation.offersCWA
                    ? "Combine enabled sources. Syncs automatically once a day."
                    : "Syncs automatically once a day.")
            columns {
                Toggle("Hardcover", isOn: $library.hardcoverEnabled)
                    .font(.system(size: 26))
                    .disabled(!library.hardcoverConnected)
                Button(library.hardcoverConnected ? "Update Hardcover login" : "Connect Hardcover")
                { sourceEditor = .hardcover }
                .font(.system(size: 26))
                .performanceGlassButton()
                note("Reading history, ratings, and followed readers.")
                note(library.sourceStatus(.hardcover, dateFormat: dateFormat))
            } trailing: {
                if BookPresentation.offersCWA {
                    Toggle("Calibre Web Automated", isOn: $library.cwaEnabled)
                        .font(.system(size: 26))
                        .disabled(!library.hasCWAPassword)
                    Button(library.hasCWAPassword ? "Update CWA login" : "Connect CWA") {
                        cwaDraft = library.cwaConfiguration
                        sourceEditor = .cwa
                    }
                    .font(.system(size: 26))
                    .performanceGlassButton()
                    note("Owned ebooks from your server.")
                    note(library.sourceStatus(.cwa, dateFormat: dateFormat))
                }
            }
            Button("Sync now") {
                Task {
                    await library.refresh(manual: true)
                    await social.load(
                        token: library.hardcoverTokenForSync(),
                        readerID: coordinator.preferences.readerID, manual: true,
                        enabledViews: Set(coordinator.preferences.activeViews))
                }
            }
            .font(.system(size: 26))
            .performanceGlassButton()
            if let message = library.message {
                note(message)
            }
        }
        .disabled(library.isLoading || library.isGenerating)
    }

    private var generalSettings: some View {
        columns {
            settingLabel("Appearance", "Follow the system or choose a color scheme.")
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases) {
                    Text($0.title).font(.system(size: 26)).tag($0)
                }
            }
            .pickerStyle(.segmented).accessibilityIdentifier("appearance-picker")
            Toggle("Wood background", isOn: $woodBackground)
                .font(.system(size: 26))
                .accessibilityIdentifier("wood-background-toggle")
            note("Turn off for a plain dark or light background across all views.")
            settingLabel("Font", "Used throughout the app except Settings.")
            Picker("Font", selection: $fontStyle) {
                ForEach(AppFontStyle.allCases) {
                    Text($0.title).font(.system(size: 26)).tag($0)
                }
            }
            .pickerStyle(.segmented).accessibilityIdentifier("font-style-picker")
            Text(
                "Hardcover.app is a great way to discover new books and share your favorite reads with friends."
            )
            .font(.system(size: 26, weight: .medium, design: .serif))
            .fontDesign(.serif)
            .accessibilityIdentifier("font-sample")
            settingLabel("Date format", "Choose how dates appear.")
            // A menu fits the four formats, which a segmented control truncated.
            Picker("Date format", selection: $dateFormat) {
                ForEach(AppDateFormat.allCases) {
                    Text($0.title).font(.system(size: 26)).tag($0)
                }
            }
            .pickerStyle(.menu).accessibilityIdentifier("date-format-picker")
            .accessibilityLabel("Date format")
            .accessibilityValue(dateFormat.title)
            .font(.system(size: 26))
        } trailing: {
            settingLabel("Spoilers", "Control review spoilers across views.")
            Toggle(
                "Show spoilers for read books",
                isOn: Binding(
                    get: { spoilerPolicy == .showIfRead },
                    set: { spoilerPolicy = $0 ? .showIfRead : .alwaysHide }
                )
            )
            .font(.system(size: 26))
            .accessibilityIdentifier("spoilers-toggle")
            note(
                spoilerPolicy == .showIfRead
                    ? "Automatically showing spoilers for books you have read on Hardcover."
                    : "Always hiding review spoilers across all views.")
            settingLabel("Social data", "Refresh enabled social views.")
            Button {
                Task {
                    await social.load(
                        token: library.hardcoverTokenForSync(),
                        readerID: coordinator.preferences.readerID, manual: true,
                        enabledViews: Set(coordinator.preferences.activeViews))
                }
            } label: {
                Label("Sync social data", systemImage: "arrow.clockwise")
            }
            .font(.system(size: 26))
            .performanceGlassButton().accessibilityIdentifier("sync-social")
            .disabled(
                social.isLoading || library.isSample || !library.hardcoverConnected
                    || !library.hardcoverEnabled)
            note(social.status).accessibilityIdentifier("social-status")
            settingLabel(
                "iCloud storage",
                "Save library data privately in iCloud. Credentials stay on this Apple TV.")
            Toggle("iCloud storage", isOn: $library.iCloudEnabled)
                .font(.system(size: 26))
                .accessibilityIdentifier("icloud-storage")
            note(library.cloudStatus).accessibilityIdentifier("icloud-status")
            Button("Sync iCloud now") { library.queueCloudSync() }
                .font(.system(size: 26))
                .performanceGlassButton()
                .disabled(!library.iCloudEnabled)
            note("Turning this off keeps saved cloud data. Covers stay cached locally.")
        }
    }

    private var cwaSettings: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("Calibre Web Automated")
                .font(.system(size: 42, weight: .medium))
            settingLabel("Server", "Your CWA HTTPS address.")
            TextField("HTTPS server address", text: $cwaDraft.server)
                .font(.system(size: 26))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            settingLabel("Username", "Your local CWA account.")
            TextField("CWA username", text: $cwaDraft.username)
                .font(.system(size: 26))
                .textContentType(.username).textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            settingLabel("Password", "Stored securely on this Apple TV.")
            SecureField("CWA password", text: $cwaPassword)
                .font(.system(size: 26))
                .textContentType(.password)
            Text(
                "Requires a local account with OPDS access. Books count as owned."
            )
            .font(.system(size: 23)).foregroundStyle(.secondary)
            Button("Connect CWA") {
                Task {
                    if await library.connectCWA(cwaDraft, password: cwaPassword) {
                        cwaPassword = ""
                        sourceEditor = nil
                    }
                }
            }
            .font(.system(size: 26))
            .buttonStyle(.glassProminent).disabled(cwaPassword.isEmpty || library.isLoading)
            if let message = library.message {
                Text(message).font(.system(size: 23))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var aiSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Provider", selection: $library.aiConfiguration.provider) {
                ForEach(AIProvider.allCases) {
                    Text($0.title).font(.system(size: 26)).tag($0)
                }
            }
            .onChange(of: library.aiConfiguration.provider) { _, provider in
                library.aiConfiguration.model = provider.defaultModel
                apiKey = ""
            }
            HStack(spacing: 30) {
                TextField("Vision model ID", text: $library.aiConfiguration.model)
                    .font(.system(size: 26))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField(
                    library.hasAIKey ? "Saved API key (leave blank to keep)" : "API key",
                    text: $apiKey
                )
                .font(.system(size: 26))
                .textContentType(.password).textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
            if library.aiConfiguration.provider == .generic {
                TextField(
                    "HTTPS Chat Completions endpoint", text: $library.aiConfiguration.endpoint
                )
                .font(.system(size: 26))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Text(
                "Match cover lettering with cached Google Fonts."
            )
            .font(.system(size: 23)).foregroundStyle(.secondary)
            Text(
                "Spine generation is currently disabled."
            )
            .font(.system(size: 23)).foregroundStyle(.secondary)
            Text(
                "Generation shares book metadata and covers with your provider and may incur charges."
            )
            .font(.system(size: 23)).foregroundStyle(.secondary)
            HStack(spacing: 28) {
                Button("Save provider") { if library.saveAI(key: apiKey) { apiKey = "" } }
                    .font(.system(size: 26))
                    .performanceGlassButton()
                Button("Regenerate spines") {
                    if library.saveAI(key: apiKey) {
                        apiKey = ""
                        library.regenerateSpines()
                    }
                }
                .font(.system(size: 26))
                .buttonStyle(.glassProminent)
                .disabled(library.isSample || library.books.isEmpty || library.isLoading)
            }
            .disabled(library.isGenerating)
            if library.savedAIKeyAvailable {
                Button("Remove saved API key") {
                    library.removeAIKey()
                    apiKey = ""
                }
                .font(.system(size: 26))
                .performanceGlassButton()
            }
            if library.isGenerating {
                Button("Stop generation") { library.cancelGeneration() }
                    .font(.system(size: 26))
                    .performanceGlassButton()
            }
            if let status = library.generationStatus {
                Text(status).font(.system(size: 23)).lineLimit(3)
            }
        }
    }

    private var accountSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Hardcover").font(.system(size: 42, weight: .medium))
            if library.hardcoverConnected {
                Text("Hardcover is connected to your library.")
                    .font(.system(size: 23))
                    .foregroundStyle(.secondary)
                HStack(spacing: 25) {
                    Button("Disconnect", role: .destructive) {
                        library.disconnect()
                        token = ""
                    }
                    .font(.system(size: 26))
                    .performanceGlassButton().disabled(library.isLoading)
                    Button("Connect another account") {
                        library.disconnect()
                        library.startHardcoverDeviceAuth()
                    }
                    .font(.system(size: 26))
                    .performanceGlassButton().disabled(library.isLoading)
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text("1. On your phone or computer, go to **hardcover.app/link**")
                        .accessibilityIdentifier("hardcover-step-1")
                    Text("2. Enter this code and select **Authorize**:")
                        .accessibilityIdentifier("hardcover-step-2")

                    HStack(alignment: .center, spacing: 24) {
                        if let auth = library.hardcoverDeviceAuth {
                            Text(auth.userCode)
                                .font(.system(size: 54, weight: .bold, design: .monospaced))
                                .tracking(3)
                                .padding(.horizontal, 32)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(
                                            colorScheme == .dark
                                                ? Color.white.opacity(0.12)
                                                : Color.black.opacity(0.06))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(
                                            colorScheme == .dark
                                                ? Color.white.opacity(0.25)
                                                : Color.black.opacity(0.15), lineWidth: 2)
                                )
                                .accessibilityIdentifier("hardcover-device-code")
                        } else if library.hardcoverDeviceAuthLoading {
                            HStack(spacing: 16) {
                                ProgressView()
                                Text("Requesting code…")
                                    .font(.system(size: 26))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 14)
                        } else {
                            Button("Get link code") {
                                library.startHardcoverDeviceAuth()
                            }
                            .font(.system(size: 26))
                            .buttonStyle(.glassProminent)
                        }
                    }

                    Text("3. Bookworms connects automatically once authorized.")
                        .accessibilityIdentifier("hardcover-step-3")

                    if library.hardcoverDeviceAuth != nil {
                        HStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            Text(library.hardcoverDeviceAuthMessage ?? "Waiting for authorization…")
                                .font(.system(size: 23))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("hardcover-device-status")
                    }
                }
                .font(.system(size: 23))

                HStack(alignment: .center, spacing: 20) {
                    Image("HardcoverTokenQR")
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 140, height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("QR code to open hardcover.app/link in browser")
                        .accessibilityIdentifier("hardcover-token-qr")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Or scan to open **hardcover.app/link** in Safari.")
                            .font(.system(size: 23))
                            .foregroundStyle(.secondary)
                        Text("Opens the link page directly in your browser.")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary.opacity(0.75))
                    }
                }
                .padding(.top, 4)

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Or enter code manually with remote or paste:")
                        .font(.system(size: 23))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("hardcover-paste-help")
                    TextField("Authorization code", text: $token)
                        .font(.system(size: 26))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("hardcover-token")
                }

                HStack(spacing: 25) {
                    Button(library.isLoading ? "Connecting…" : "Connect code") {
                        Task {
                            if await library.connectWithCode(token) {
                                token = ""
                                sourceEditor = nil
                            }
                        }
                    }
                    .font(.system(size: 26))
                    .performanceGlassButton().disabled(token.isEmpty || library.isLoading)

                    if library.hardcoverDeviceAuth != nil {
                        Button("Refresh code") {
                            library.startHardcoverDeviceAuth()
                        }
                        .font(.system(size: 26))
                        .performanceGlassButton().disabled(library.isLoading)
                    }

                    Button("Explore sample shelf") {
                        library.showSample()
                        onShowShelf()
                    }
                    .font(.system(size: 26))
                    .performanceGlassButton()
                }
                .disabled(library.isGenerating)

                if let message = library.message {
                    Text(message).font(.system(size: 23))
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}
