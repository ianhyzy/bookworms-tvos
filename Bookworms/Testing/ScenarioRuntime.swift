#if DEBUG && targetEnvironment(simulator)
    import Foundation
    import CoreFoundation
    import CryptoKit
    import Observation
    import SwiftUI
    import UIKit

    /// Drives ordinary app startup with isolated storage and controlled external responses.
    @MainActor @Observable
    final class ScenarioRuntime {
        static private(set) var current: ScenarioRuntime?
        static let commandNotification = Notification.Name("BookwormsScenarioCommand")
        let defaults: UserDefaults
        let storageDirectory: URL
        let name: String
        private(set) var probe = ""
        @ObservationIgnored private var date = Date(timeIntervalSince1970: 1_789_603_200)
        @ObservationIgnored private var credentials = [
            "hardcover-token": "hc_pat_fictional_ui_fixture"
        ]
        @ObservationIgnored private var sourceCalls = 0
        @ObservationIgnored private var cloudCalls = 0
        @ObservationIgnored private var probeRevision = 0

        static func installIfRequested() -> ScenarioRuntime? {
            if let current { return current }
            guard
                let argument = ProcessInfo.processInfo.arguments.first(where: {
                    $0.hasPrefix("--test-scenario=")
                })
            else { return nil }
            let name = String(argument.dropFirst("--test-scenario=".count))
            precondition(
                ["artwork", "delayed-artwork", "offline", "partial", "empty", "error"]
                    .contains(name), "Unknown simulator test scenario")
            let runtime = ScenarioRuntime(name: name)
            current = runtime
            return runtime
        }

        private init(name: String) {
            self.name = name
            let suite = "bookworms.ui-scenario.\(name)"
            defaults = UserDefaults(suiteName: suite)!
            storageDirectory = URL.cachesDirectory.appending(
                path: suite, directoryHint: .isDirectory)
            if !ProcessInfo.processInfo.arguments.contains("--preserve-test-scenario") {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: storageDirectory)
            }
            try! FileManager.default.createDirectory(
                at: storageDirectory, withIntermediateDirectories: true)
            defaults.set(false, forKey: "iCloudEnabled")
            if defaults.data(forKey: "viewPreferences") == nil {
                var preferences = ViewPreferences()
                preferences.enabled = [.shelf]
                defaults.set(try! JSONEncoder().encode(preferences), forKey: "viewPreferences")
            }
            if let argument = ProcessInfo.processInfo.arguments.first(where: {
                $0.hasPrefix("--test-appearance=")
            }) {
                defaults.set(
                    String(argument.dropFirst("--test-appearance=".count)), forKey: "appearance")
            }
            if name == "partial" {
                defaults.set(true, forKey: "cwaEnabled")
                let configuration = CWAConfiguration(
                    server: "https://fixture.invalid", username: "fictional-reader")
                defaults.set(try! JSONEncoder().encode(configuration), forKey: "cwaConfiguration")
                credentials["cwa-password"] = "fictional-ui-password"
            }
            let images = ScenarioFixtures.images()
            ScenarioNetwork.state.configure(
                scenario: name, artworkRoot: storageDirectory.appending(path: "artwork"),
                images: images)
            URLProtocol.registerClass(ScenarioURLProtocol.self)
            installControlChannel()
            if name == "offline",
                !ProcessInfo.processInfo.arguments.contains("--preserve-test-scenario")
            {
                let root = storageDirectory.appending(path: "artwork")
                try! FileManager.default.createDirectory(
                    at: root, withIntermediateDirectories: true)
                for (path, data) in images where path != "corrupt" {
                    let key =
                        SHA256.hash(
                            data: Data("https://artwork.fixture.invalid/\(path)@source2400".utf8)
                        )
                        .map { String(format: "%02x", $0) }.joined()
                    try! data.write(to: root.appending(path: key), options: .atomic)
                }
                try! SourceLibraryStore(url: storageDirectory.appending(path: "sources.json"))
                    .save([
                        SourceSnapshot(
                            source: .hardcover, accountID: "hardcover",
                            books: ScenarioFixtures.books,
                            syncedAt: date.addingTimeInterval(-172_800))
                    ])
            }
        }

        /// Darwin notifications cross the UI-test process boundary without foregrounding the app.
        private func installControlChannel() {
            let channel =
                ProcessInfo.processInfo.environment["BOOKWORMS_SCENARIO_CONTROL"] ?? "manual"
            for command in ["probe", "release-artwork", "advance-clock"] {
                let name = "gay.ian.Bookworms.scenario.\(channel).\(command)"
                CFNotificationCenterAddObserver(
                    CFNotificationCenterGetDarwinNotifyCenter(), nil,
                    { _, _, name, _, _ in
                        guard let name else { return }
                        let command = (name.rawValue as String).components(separatedBy: ".").last!
                        Task { @MainActor in
                            NotificationCenter.default.post(
                                name: ScenarioRuntime.commandNotification, object: command)
                        }
                    }, name as CFString, nil, .deliverImmediately)
            }
        }

        func commandURL(_ command: String) -> URL {
            let suffix = command == "advance-clock" ? "?seconds=61" : ""
            return URL(string: "bookworms://testing/\(command)\(suffix)")!
        }

        func dependencies() -> LibraryDependencies {
            var dependencies = LibraryDependencies(
                defaults: defaults, storageDirectory: storageDirectory)
            dependencies.allowLaunchOverrides = false
            dependencies.readCredential = { [self] in credentials[$0] }
            dependencies.saveCredential = { [self] value, account in credentials[account] = value }
            dependencies.removeCredential = { [self] in credentials[$0] = nil }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ScenarioURLProtocol.self]
            let client = HardcoverClient(session: URLSession(configuration: configuration))
            dependencies.fetchHardcover = { [self] token in
                sourceCalls += 1
                return try await client.fetchBooks(token: token)
            }
            dependencies.validateHardcover = { token in try await client.validateToken(token) }
            dependencies.fetchCWA = { [self] _, _ in
                sourceCalls += 1
                throw SourceError.credentials
            }
            dependencies.syncCloud = { [self] archive in
                cloudCalls += 1
                return archive
            }
            dependencies.now = { [self] in date }
            dependencies.readTopShelf = { [] }
            dependencies.writeTopShelf = { _ in }
            return dependencies
        }

        func socialModel() -> SocialLibraryModel {
            SocialLibraryModel(
                defaults: defaults, cacheRoot: storageDirectory.appending(path: "social"),
                now: { [self] in date })
        }

        func ambientController() -> AmbientController { AmbientController(now: { [self] in date }) }

        /// Test commands exist only in simulator Debug builds and never accept live URLs or data.
        func handle(
            _ url: URL, library: LibraryModel, ambient: AmbientController,
            availableViews: [BookwormsView], shelfState: [String: Any]
        ) -> Bool {
            guard url.scheme == "bookworms", url.host == "testing" else { return false }
            switch url.path {
            case "/release-artwork": ScenarioNetwork.state.releaseArtwork()
            case "/advance-clock":
                if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                    let text = components.queryItems?.first(where: { $0.name == "seconds" })?.value,
                    let seconds = Double(text), seconds.isFinite, (0...172_800).contains(seconds)
                {
                    date = date.addingTimeInterval(seconds)
                    ambient.tick(views: availableViews)
                }
            case "/probe": break
            default: preconditionFailure("Unknown simulator test command")
            }
            probeRevision += 1
            let evidence: [String: Any] = [
                "revision": probeRevision, "scenario": name, "sourceCalls": sourceCalls,
                "cloudCalls": cloudCalls, "network": ScenarioNetwork.state.evidence(),
                "sample": library.isSample, "generating": library.isGenerating,
                "bookIDs": library.books.map(\.id), "loading": library.isLoading,
                "ambient": ambient.isActive, "ambientIndex": ambient.contentIndex,
                "idleTimerDisabled": UIApplication.shared.isIdleTimerDisabled,
                "appearance": defaults.string(forKey: "appearance") ?? "system",
                "shelf": shelfState,
            ]
            let data = try! JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
            probe = String(decoding: data, as: UTF8.self)
            return true
        }
    }

    /// A noninteractive accessibility probe lets UI tests assert side effects without adding controls.
    struct ScenarioProbe: View {
        let runtime: ScenarioRuntime
        var body: some View {
            Text(runtime.probe)
                .font(.system(size: 1)).foregroundStyle(.clear)
                .accessibilityIdentifier("scenario-probe")
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
    }

    enum ScenarioFixtures {
        static let titles = [
            "The Orchard at Night", "A Field Guide to Elsewhere", "Tides of the Changing Coast",
            "The Long Way Home: A Journey Through the Changing City and Its Forgotten Gardens",
            "An Incomplete Atlas", "The Last Observatory", "Small Hours", "Winter in the Orchard",
        ]
        static let paths: [String?] = [
            "portrait", "square", "landscape", nil, "corrupt", "delayed", "portrait", "square",
        ]
        static var rows: [[String: Any]] {
            titles.enumerated()
                .map { index, title in
                    var book: [String: Any] = [
                        "id": index + 1, "title": title,
                        "cached_contributors": [
                            ["author": ["name": "Alex Rowan"], "contribution": "Author"]
                        ],
                        "description": String(
                            repeating: "A fictional journey through a changing landscape. ",
                            count: 16),
                        "pages": 200 + index * 40, "release_year": 2020 + index,
                        "rating": 4.2, "ratings_count": 100,
                        "ratings_distribution": [["rating": 4.0, "count": 100]],
                    ]
                    if let path = paths[index] {
                        book["image"] = ["url": "https://artwork.fixture.invalid/\(path)"]
                    }
                    return [
                        "id": index + 100, "status_id": 3, "rating": 4.0,
                        "last_read_date": String(format: "2026-09-%02d", 16 - index), "book": book,
                    ]
                }
        }
        static var books: [Book] {
            let data = try! JSONSerialization.data(withJSONObject: rows)
            return HardcoverClient.normalize(try! JSONDecoder().decode([UserBook].self, from: data))
        }

        @MainActor static func images() -> [String: Data] {
            var result = [String: Data]()
            for (name, size, color) in [
                (
                    "portrait", CGSize(width: 400, height: 600),
                    UIColor(red: 0.12, green: 0.32, blue: 0.24, alpha: 1)
                ),
                (
                    "square", CGSize(width: 500, height: 500),
                    UIColor(red: 0.17, green: 0.24, blue: 0.42, alpha: 1)
                ),
                (
                    "landscape", CGSize(width: 700, height: 400),
                    UIColor(red: 0.46, green: 0.20, blue: 0.10, alpha: 1)
                ),
                (
                    "delayed", CGSize(width: 400, height: 600),
                    UIColor(red: 0.29, green: 0.17, blue: 0.37, alpha: 1)
                ),
            ] {
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                format.opaque = true
                result[name] = UIGraphicsImageRenderer(size: size, format: format)
                    .jpegData(
                        withCompressionQuality: 0.9
                    ) { context in
                        color.setFill()
                        context.fill(CGRect(origin: .zero, size: size))
                        UIColor.white.withAlphaComponent(0.25).setFill()
                        context.fill(CGRect(x: 25, y: 25, width: size.width - 50, height: 8))
                        let paragraph = NSMutableParagraphStyle()
                        paragraph.alignment = .center
                        let attributes: [NSAttributedString.Key: Any] = [
                            .font: UIFont.systemFont(ofSize: 34, weight: .semibold),
                            .foregroundColor: UIColor.white, .paragraphStyle: paragraph,
                        ]
                        ("BOOKWORMS\n\n\(name.uppercased())" as NSString)
                            .draw(
                                in: CGRect(
                                    x: 30, y: size.height * 0.3, width: size.width - 60, height: 240
                                ),
                                withAttributes: attributes)
                    }
            }
            result["corrupt"] = Data("This response is deliberately not an image.".utf8)
            return result
        }
    }

    enum ScenarioNetwork { static let state = ScenarioNetworkState() }

    /// URLProtocol callbacks use a lock because Foundation delivers them outside the main actor.
    final class ScenarioNetworkState: @unchecked Sendable {
        private let lock = NSLock()
        private var scenario = ""
        private var images = [String: Data]()
        private var root: URL?
        private var released = false
        private var pending = [ScenarioURLProtocol]()
        private var requestCount = 0
        private var unexpectedCount = 0
        private var deliveredArtwork = 0

        var artworkRoot: URL? { lock.withLock { root } }

        func configure(scenario: String, artworkRoot: URL, images: [String: Data]) {
            lock.withLock {
                self.scenario = scenario
                self.root = artworkRoot
                self.images = images
                released = scenario != "delayed-artwork"
                pending = []
                requestCount = 0
                unexpectedCount = 0
                deliveredArtwork = 0
            }
        }

        func respond(to request: ScenarioURLProtocol) {
            let url = request.request.url!
            let result: (Int, Data)? = lock.withLock {
                requestCount += 1
                if url.host == "artwork.fixture.invalid",
                    let data = images[String(url.path.dropFirst())],
                    request.request.httpMethod == "GET"
                {
                    if scenario == "offline" { return (-1, Data()) }
                    if url.path == "/delayed", !released {
                        pending.append(request)
                        return nil
                    }
                    deliveredArtwork += 1
                    return (200, data)
                }
                if url.absoluteString == "https://hardcover.app/oauth2/device",
                    request.request.httpMethod == "POST"
                {
                    if scenario == "offline" { return (-1, Data()) }
                    if scenario == "error" { return (401, Data()) }
                    return (
                        200,
                        Data(
                            #"{"device_code":"hc_dc_fixture","user_code":"TEST-1234","verification_uri":"https://hardcover.app/link","verification_uri_complete":"https://hardcover.app/link?c=TEST1234","expires_in":900,"interval":5}"#
                                .utf8)
                    )
                }
                if url.absoluteString == "https://hardcover.app/oauth2/token",
                    request.request.httpMethod == "POST"
                {
                    if scenario == "offline" { return (-1, Data()) }
                    if scenario == "error" { return (401, Data()) }
                    return (400, Data(#"{"error":"authorization_pending"}"#.utf8))
                }
                if url.absoluteString == "https://hardcover.app/oauth/token",
                    request.request.httpMethod == "POST"
                {
                    if scenario == "offline" { return (-1, Data()) }
                    if scenario == "error" { return (401, Data()) }
                    return (
                        200,
                        Data(
                            #"{"access_token":"hc_pat_fictional_ui_fixture","token_type":"Bearer"}"#
                                .utf8)
                    )
                }
                if url.absoluteString == "https://api.hardcover.app/v1/graphql",
                    request.request.httpMethod == "POST",
                    let body = request.body(),
                    let envelope = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                    let query = envelope["query"] as? String,
                    query.hasPrefix("query ShelfAccount ") || query.hasPrefix("query ShelfLibrary(")
                {
                    if scenario == "offline" { return (-1, Data()) }
                    if scenario == "error" { return (401, Data()) }
                    if query.hasPrefix("query ShelfAccount ") {
                        return (200, Data(#"{"data":{"me":[{"id":42}]}}"#.utf8))
                    }
                    if query.hasPrefix("query ShelfLibrary(") {
                        let rows = scenario == "empty" ? [] : ScenarioFixtures.rows
                        return (
                            200,
                            try! JSONSerialization.data(withJSONObject: [
                                "data": ["user_books": rows]
                            ])
                        )
                    }
                }
                unexpectedCount += 1
                return (-2, Data())
            }
            guard let result else { return }
            request.finish(status: result.0, data: result.1)
        }

        func cancel(_ request: ScenarioURLProtocol) {
            lock.withLock { pending.removeAll { $0 === request } }
        }

        func releaseArtwork() {
            let held: ([ScenarioURLProtocol], Data) = lock.withLock {
                released = true
                let held = pending
                pending = []
                deliveredArtwork += held.count
                return (held, images["delayed"]!)
            }
            for request in held.0 { request.finish(status: 200, data: held.1) }
        }

        func evidence() -> [String: Any] {
            lock.withLock {
                [
                    "requests": requestCount, "unexpected": unexpectedCount,
                    "heldArtwork": pending.count, "deliveredArtwork": deliveredArtwork,
                ]
            }
        }
    }

    final class ScenarioURLProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool {
            ["http", "https"].contains(request.url?.scheme ?? "")
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() { ScenarioNetwork.state.respond(to: self) }
        override func stopLoading() { ScenarioNetwork.state.cancel(self) }

        func body() -> Data? {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable, data.count < 1_000_000 {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            return data
        }

        func finish(status: Int, data: Data) {
            if status < 0 {
                client?
                    .urlProtocol(
                        self,
                        didFailWithError: URLError(
                            status == -1 ? .notConnectedToInternet : .unsupportedURL))
                return
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    /// Counts native focus updates for UI tests launched with `--focus-probe`.
    ///
    /// A remote press that moves focus once produces one update. A bounce, where the focus engine
    /// moves focus and app code then moves it again, produces two. The count is stored in the
    /// view's accessibility value rather than SwiftUI state, so observing focus never invalidates
    /// views or changes focus timing.
    struct FocusTransitionProbe: UIViewRepresentable {
        static let isEnabled = ProcessInfo.processInfo.arguments.contains("--focus-probe")

        func makeUIView(context: Context) -> ProbeView { ProbeView() }
        func updateUIView(_ uiView: ProbeView, context: Context) {}

        final class ProbeView: UIView {
            private var transitions = 0

            override init(frame: CGRect) {
                super.init(frame: frame)
                isUserInteractionEnabled = false
                isAccessibilityElement = true
                accessibilityIdentifier = "focus-transition-probe"
                accessibilityLabel = "Focus transitions"
                accessibilityValue = "0"
                NotificationCenter.default.addObserver(
                    self, selector: #selector(focusUpdated(_:)),
                    name: UIFocusSystem.didUpdateNotification, object: nil)
            }

            required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

            @objc private func focusUpdated(_ notification: Notification) {
                transitions += 1
                accessibilityValue = String(transitions)
            }
        }
    }
#endif
