import CloudKit
import XCTest

@testable import Bookworms

final class UserFacingErrorTests: XCTestCase {
    func testAuthenticationAndPermissionErrorsHaveDifferentRecoverySteps() {
        XCTAssertTrue(UserFacingError.message(SourceError.credentials).contains("login"))
        XCTAssertTrue(UserFacingError.message(SourceError.forbidden).contains("OPDS permission"))
        XCTAssertTrue(UserFacingError.message(SourceError.invalidCredentials).contains("Enter"))
        XCTAssertTrue(UserFacingError.message(AIError.request(401)).contains("API key"))
        XCTAssertTrue(UserFacingError.message(AIError.request(403)).contains("permissions"))
        XCTAssertTrue(UserFacingError.message(AIError.request(429)).contains("quota"))
        XCTAssertTrue(UserFacingError.message(AIError.request(404)).contains("model ID"))
    }

    func testAIRequestValidationDoesNotMislabelKeysOrImagesAsModelErrors() {
        let configuration = AIConfiguration(provider: .openAI, model: "fixture")
        XCTAssertThrowsError(
            try AIStyleGenerator.request(
                prompt: "test", images: [], configuration: configuration, key: "bad key")
        ) {
            XCTAssertTrue(UserFacingError.message($0).contains("spaces"))
        }
        XCTAssertThrowsError(
            try AIStyleGenerator.request(
                prompt: "test", images: [Data(), Data(), Data()], configuration: configuration,
                key: "fixture")
        ) {
            XCTAssertTrue(UserFacingError.message($0).contains("images"))
        }
    }

    func testNetworkErrorsDoNotBlameCredentials() {
        for code in [
            URLError.timedOut, .notConnectedToInternet, .cannotFindHost,
            .serverCertificateUntrusted,
        ] {
            let text = UserFacingError.message(URLError(code))
            XCTAssertFalse(text.contains("API key"))
            XCTAssertFalse(text.contains("expired"))
            XCTAssertFalse(text.contains("NSURLErrorDomain"))
        }
        XCTAssertTrue(UserFacingError.message(URLError(.timedOut)).contains("Tailscale"))
    }

    func testCloudErrorsDistinguishQuotaAccountAndTemporaryFailure() {
        XCTAssertTrue(UserFacingError.message(CKError(.quotaExceeded)).contains("storage is full"))
        XCTAssertTrue(UserFacingError.message(CKError(.notAuthenticated)).contains("Sign in"))
        XCTAssertFalse(UserFacingError.message(CKError(.serviceUnavailable)).contains("Sign in"))
        XCTAssertFalse(UserFacingError.message(CloudStorageError.restricted).contains("Sign in"))
    }

    func testUnknownErrorsNeverExposeServerPayloadOrFilePaths() {
        let error = NSError(
            domain: "SecretServer", code: 9,
            userInfo: [NSLocalizedDescriptionKey: "/private/token-secret"])
        XCTAssertFalse(UserFacingError.message(error).contains("secret"))
        XCTAssertFalse(UserFacingError.message(error).contains("/private"))
    }

    func testInvalidCalendarDateDoesNotBecomeADifferentCompletionDate() {
        var book = SampleLibrary.books[0]
        for date in ["2026-02-30", "2026-13-01", "unknown"] {
            book.finished = date
            XCTAssertEqual(book.finishedLabel, "Date not recorded")
        }
        book.finished = "2024-02-29"
        XCTAssertNotEqual(book.finishedLabel, "Date not recorded")
    }
}
