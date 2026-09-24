import XCTest

@testable import Bookworms

/// Opt-in compatibility checks using an explicitly configured simulator's Keychain.
@MainActor
final class LiveServiceTests: XCTestCase {
    private func requireAuthorization() throws {
        guard ProcessInfo.processInfo.environment["VERIFY_LIVE_SERVICES"] == "1" else {
            throw LivePrecondition.authorizationRequired
        }
    }

    func testHardcoverReadOnlyContract() async throws {
        try requireAuthorization()
        guard let token = CredentialStore.read() else {
            throw LivePrecondition.hardcoverNotConfigured
        }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        do {
            let books = try await HardcoverClient(session: session).fetchBooks(token: token)
            assertDecodedContract(books, source: .hardcover)
        } catch {
            // Raw errors and decoded responses can contain private library or server data.
            XCTFail("Hardcover compatibility check failed: " + UserFacingError.message(error))
        }
    }

    func testCWAReadOnlyContract() async throws {
        try requireAuthorization()
        guard let password = CredentialStore.read(account: "cwa-password"),
            let data = UserDefaults.standard.data(forKey: "cwaConfiguration"),
            let configuration = try? JSONDecoder().decode(CWAConfiguration.self, from: data)
        else {
            throw LivePrecondition.cwaNotConfigured
        }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        do {
            let books = try await CWAClient(session: session)
                .fetchBooks(
                    configuration: configuration, password: password)
            assertDecodedContract(books, source: .cwa)
        } catch {
            XCTFail("CWA compatibility check failed: " + UserFacingError.message(error))
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(
            configuration: configuration, delegate: SourceRedirectPolicy(), delegateQueue: nil)
    }

    /// Checks the common fixture contract without attaching private records or URLs.
    private func assertDecodedContract(_ books: [Book], source: LibrarySource) {
        XCTAssertFalse(books.isEmpty, "Use a nonempty test library to verify record decoding.")
        XCTAssertEqual(Set(books.map(\.id)).count, books.count)
        XCTAssertTrue(books.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(books.allSatisfy { $0.sources?.contains(source) == true })
        XCTAssertTrue(books.allSatisfy { $0.rating.map { (0...5).contains($0) } ?? true })
        XCTAssertTrue(books.allSatisfy { $0.pages.map { $0 >= 0 } ?? true })
        XCTAssertTrue(books.allSatisfy { $0.ratingsCount.map { $0 >= 0 } ?? true })
    }
}

private enum LivePrecondition: LocalizedError {
    case authorizationRequired, hardcoverNotConfigured, cwaNotConfigured

    var errorDescription: String? {
        switch self {
        case .authorizationRequired:
            "Live verification was not enabled. Set TEST_RUNNER_VERIFY_LIVE_SERVICES=1 only for an authorized read-only check."
        case .hardcoverNotConfigured:
            "Configure a read-only Hardcover test account in this simulator before live verification."
        case .cwaNotConfigured:
            "Configure a read-only CWA test account in this simulator before live verification."
        }
    }
}
