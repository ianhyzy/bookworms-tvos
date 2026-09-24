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
                .task {
                    // Unit tests own their model instances; the host UI must not start live syncing.
                    guard NSClassFromString("XCTestCase") == nil else { return }
                    await library.start()
                }
                .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
                    library.cloudAccountChanged()
                }
                .onOpenURL { url in
                    let scheme = url.scheme ?? ""
                    if scheme == "gay.ian.bookworms" || scheme == "bookworms",
                        url.path == "/oauth/callback" || url.host == "oauth",
                        let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                        let code = components.queryItems?.first(where: { $0.name == "code" })?.value
                    {
                        Task {
                            _ = await library.connectWithCode(code)
                        }
                    }
                }
        }
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
