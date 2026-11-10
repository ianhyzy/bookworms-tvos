import CloudKit
import SwiftUI
import os

@main
struct BookwormsApp: App {
    @AppStorage("appearance") private var appearance = AppAppearance.system
    @State private var library: LibraryModel
    private let defaults: UserDefaults
    init() {
        MemoryReport.startIfRequested()
        #if DEBUG && targetEnvironment(simulator)
            if let scenario = ScenarioRuntime.installIfRequested() {
                defaults = scenario.defaults
                _appearance = AppStorage(wrappedValue: .system, "appearance", store: defaults)
                _library = State(initialValue: LibraryModel(dependencies: scenario.dependencies()))
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--reset-test-settings"),
                ProcessInfo.processInfo.arguments.contains("--sample-library"),
                let domain = Bundle.main.bundleIdentifier
            {
                UserDefaults.standard.removePersistentDomain(forName: domain)
                // The app picks a random followed reader; tests start with the same one.
                var preferences = ViewPreferences()
                preferences.readerID = SocialLibraryModel.sampleReaderID
                UserDefaults.standard.set(
                    try? JSONEncoder().encode(preferences), forKey: "viewPreferences")
            }
        #endif
        defaults = .standard
        _library = State(initialValue: LibraryModel())
    }
    var body: some Scene {
        WindowGroup {
            ShelfView(library: library)
                .defaultAppStorage(defaults)
                .appTypography()
                .overlay(alignment: .topTrailing) {
                    if OfflineTestPolicy.isEnabled {
                        Text("Offline tests").font(.system(size: 10))
                            .accessibilityIdentifier("offline-test-guard")
                            .allowsHitTesting(false)
                    }
                }
                .preferredColorScheme(appearance.colorScheme)
                .modifier(CloudAccountAlerts(library: library))
                .task {
                    // Unit tests own their model instances; the host UI must not start live syncing.
                    guard NSClassFromString("XCTestCase") == nil else { return }
                    await library.start()
                }
                // CloudKit can post this on a background queue, and the model is main-actor state.
                .onReceive(
                    NotificationCenter.default.publisher(for: .CKAccountChanged)
                        .receive(on: DispatchQueue.main)
                ) { _ in
                    Task { await library.cloudAccountChanged() }
                }
        }
    }
}

/// The Hardcover account prompts: **Merge** or **Keep iCloud Off** when iCloud holds another
/// account's data, the library choice without a Hardcover credential, and their follow-up
/// alerts. Each prompt shows while its state is set and has no cancel button, so the reader
/// chooses; its actions clear the state.
private struct CloudAccountAlerts: ViewModifier {
    @Bindable var library: LibraryModel

    func body(content: Content) -> some View {
        content
            .alert(
                "Another Hardcover account in iCloud",
                isPresented: Binding(
                    get: { !library.otherICloudAccounts.isEmpty }, set: { _ in })
            ) {
                // Starts at once, so the prompt clears before the alert reads it again.
                Button("Merge") { Task.immediate { await library.mergeOtherAccounts() } }
                Button("Keep iCloud Off") { library.keepICloudOff() }
            } message: {
                Text(otherAccountsMessage)
            }
            .alert(
                "Choose a library",
                isPresented: Binding(
                    get: { !library.iCloudLibraryChoices.isEmpty }, set: { _ in })
            ) {
                ForEach(library.iCloudLibraryChoices) { account in
                    Button(account.name) { library.chooseLibrary(account.id) }
                }
            } message: {
                Text("iCloud has libraries from more than one Hardcover account.")
            }
            .alert(
                "Couldn't merge",
                isPresented: Binding(
                    get: { library.mergeFailure != nil },
                    set: { if !$0 { library.mergeFailure = nil } })
            ) {
                Button("OK") {}
            } message: {
                Text(library.mergeFailure ?? "")
            }
            .alert("iCloud storage is off", isPresented: $library.showsICloudDeletionHelp) {
                Button("OK") {}
            } message: {
                Text(
                    "To delete Bookworms data from iCloud, use an iPhone, iPad, or Mac. This deletes all Bookworms iCloud data, including this account's."
                )
            }
    }

    private var otherAccountsMessage: String {
        let accounts = library.otherICloudAccounts
        let names = ListFormatter.localizedString(byJoining: accounts.map(\.name))
        return accounts.count == 1
            ? "iCloud has Bookworms data from \(names). Merge copies its designs and choices to the same books in your library."
            : "iCloud has Bookworms data from \(names). Merge copies their designs and choices to the same books in your library."
    }
}

/// Reports the app's memory on devices where Instruments cannot attach.
///
/// Launch with `--memory-report` (for example through `devicectl device process launch --console`)
/// to write the physical footprint, its peak, and the memory remaining before the system ends the
/// app to standard error every five seconds. Without the argument it does nothing.
enum MemoryReport {
    static func startIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--memory-report") else { return }
        Task.detached(priority: .utility) {
            var peak: UInt64 = 0
            while !Task.isCancelled {
                let footprint = Self.footprint()
                peak = max(peak, footprint)
                let line =
                    "memory footprint_mb=\(footprint >> 20) peak_mb=\(peak >> 20) available_mb=\(os_proc_available_memory() >> 20)\n"
                FileHandle.standardError.write(Data(line.utf8))
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// The physical footprint the system uses for memory limits, in bytes.
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
