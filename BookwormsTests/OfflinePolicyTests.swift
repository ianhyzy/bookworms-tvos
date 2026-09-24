import XCTest

@testable import Bookworms

final class OfflinePolicyTests: XCTestCase {
    func testWorkerBuildRejectsUnexpectedNetworkAndCredentials() async throws {
        XCTAssertTrue(OfflineTestPolicy.isEnabled, "Run through the offline test runner")
        #if BOOKWORMS_OFFLINE_TESTS
            XCTAssertNil(CredentialStore.read())
            XCTAssertThrowsError(try CredentialStore.save("fictional"))
            do {
                _ = try await OfflineTestPolicy.data(
                    for: URLRequest(url: URL(string: "https://unexpected.invalid/blocked")!),
                    session: .shared)
                XCTFail("Unexpected request escaped the offline guard")
            } catch let error as URLError {
                XCTAssertEqual(error.code, .notConnectedToInternet)
            }
        #endif
    }
}
