import XCTest

@testable import Bookworms

final class HardcoverAuthenticationTests: XCTestCase {
    func testAcceptsOAuthAndPersonalAccessTokens() throws {
        for input in [
            "hc_pat_example", "  hc_pat_example\n", "Bearer hc_pat_example",
            "bearer  hc_pat_example", "oauth_access_token_12345", "Bearer oauth_token_abc",
        ] {
            let expected: String
            var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("bearer ") {
                trimmed = String(trimmed.dropFirst(7))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            expected = trimmed
            XCTAssertEqual(try HardcoverToken(input).value, expected)
        }
    }

    func testRejectsMalformedCredentials() {
        for input in [
            "", "   \n\t", "hc_pat_two words", "oauth token with spaces",
            "token_header\r\nInjected: value", "token_null\u{0}",
        ] {
            XCTAssertThrowsError(try HardcoverToken(input))
        }
    }

    func testMalformedTokenNeverReachesTransport() async {
        do {
            _ = try await client().fetchBooks(token: "malformed token with spaces")
            XCTFail("Malformed credentials must be rejected.")
        } catch HardcoverError.invalidToken {
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testPATUsesBearerAuthentication() async throws {
        let books = try await client().fetchBooks(token: "hc_pat_success")
        XCTAssertTrue(books.isEmpty)
    }

    func testExchangeAuthorizationCodeSuccess() async throws {
        let token = try await client().exchangeAuthorizationCode("valid_code_123")
        XCTAssertEqual(token, "hc_pat_success")
    }

    func testExchangeAuthorizationCodeRejectsMalformedCode() async {
        do {
            _ = try await client().exchangeAuthorizationCode("code with spaces")
            XCTFail("Malformed authorization code must be rejected.")
        } catch HardcoverError.invalidAuthorizationCode {
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testExchangeAuthorizationCodeHandlesErrorResponse() async {
        do {
            _ = try await client().exchangeAuthorizationCode("expired_code")
            XCTFail("Invalid grant must fail.")
        } catch HardcoverError.invalidAuthorizationCode {
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testRequestDeviceAuthSuccess() async throws {
        let auth = try await client().requestDeviceAuth()
        XCTAssertEqual(auth.deviceCode, "hc_dc_stub")
        XCTAssertEqual(auth.userCode, "YSVA-NBK1")
        XCTAssertEqual(auth.verificationURI, URL(string: "https://hardcover.app/link")!)
        XCTAssertEqual(
            auth.verificationURIComplete, URL(string: "https://hardcover.app/link?c=YSVANBK1")!)
        XCTAssertEqual(auth.expiresIn, 900)
        XCTAssertEqual(auth.interval, 5)
    }

    func testPollDeviceTokenStates() async throws {
        let pending = try await client().pollDeviceToken(deviceCode: "device_pending")
        XCTAssertEqual(pending, .pending)

        let slowDown = try await client().pollDeviceToken(deviceCode: "device_slow_down")
        XCTAssertEqual(slowDown, .slowDown)

        let expired = try await client().pollDeviceToken(deviceCode: "device_expired")
        XCTAssertEqual(expired, .expired)

        let denied = try await client().pollDeviceToken(deviceCode: "device_denied")
        XCTAssertEqual(denied, .accessDenied)

        let success = try await client().pollDeviceToken(deviceCode: "device_success")
        XCTAssertEqual(success, .success(token: "hc_pat_success"))
    }

    func testReplacementTokenCanBeValidatedWithoutLoadingBooks() async throws {
        try await client().validateToken("hc_pat_validate")
    }

    func testLibraryPaginationLoadsAllPagesAndRejectsPartialFailure() async throws {
        let books = try await client().fetchBooks(token: "hc_pat_pages")
        XCTAssertEqual(books.count, 101)
        XCTAssertEqual(Set(books.map(\.id)).count, 101)
        do {
            _ = try await client().fetchBooks(token: "hc_pat_partial")
            XCTFail("A failed later page must not be returned as a successful partial library.")
        } catch HardcoverError.rejected {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testMissingScopeIsNotReportedAsExpired() async {
        do {
            _ = try await client().fetchBooks(token: "hc_pat_scope")
            XCTFail("Missing permissions must fail.")
        } catch HardcoverError.insufficientScope {
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testOtherForbiddenResponsesAreNotReportedAsExpired() async {
        do {
            _ = try await client().fetchBooks(token: "hc_pat_forbidden")
            XCTFail("Forbidden requests must fail.")
        } catch HardcoverError.forbidden {
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testUnauthorizedResponseRequestsReplacementToken() async {
        do {
            _ = try await client().fetchBooks(token: "hc_pat_expired")
            XCTFail("Expired credentials must fail.")
        } catch HardcoverError.invalidToken {
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    @MainActor
    func testRejectedConnectionPreservesDisplayedBooks() async {
        let library = LibraryModel()
        library.showSample()
        let ids = library.books.map(\.id)
        let connected = await library.connect("invalid token with spaces")
        XCTAssertFalse(connected)
        XCTAssertEqual(library.books.map(\.id), ids)
        let hasExpectedMessage =
            library.message?.contains("invalid") == true
            || library.message?.contains("Reconnect") == true
        XCTAssertTrue(hasExpectedMessage)
    }

    private func client() -> HardcoverClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthenticationStub.self]
        return HardcoverClient(session: URLSession(configuration: configuration))
    }
}

private final class AuthenticationStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.absoluteString == "https://hardcover.app/oauth2/device" {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Content-Type"),
                "application/x-www-form-urlencoded")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let payload =
                #"{"device_code":"hc_dc_stub","user_code":"YSVA-NBK1","verification_uri":"https://hardcover.app/link","verification_uri_complete":"https://hardcover.app/link?c=YSVANBK1","expires_in":900,"interval":5}"#
            client?.urlProtocol(self, didLoad: Data(payload.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        if request.url?.absoluteString == "https://hardcover.app/oauth2/token" {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Content-Type"),
                "application/x-www-form-urlencoded")
            var bodyData = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    bodyData.append(contentsOf: bytes.prefix(count))
                }
            }
            let bodyString = String(decoding: bodyData, as: UTF8.self)
            let (statusCode, payload): (Int, String) = {
                if bodyString.contains("device_code=device_pending") {
                    return (400, #"{"error":"authorization_pending"}"#)
                } else if bodyString.contains("device_code=device_slow_down") {
                    return (400, #"{"error":"slow_down"}"#)
                } else if bodyString.contains("device_code=device_expired") {
                    return (400, #"{"error":"expired_token"}"#)
                } else if bodyString.contains("device_code=device_denied") {
                    return (400, #"{"error":"access_denied"}"#)
                } else if bodyString.contains("device_code=device_success") {
                    return (200, #"{"access_token":"hc_pat_success","token_type":"Bearer"}"#)
                } else {
                    return (400, #"{"error":"invalid_grant"}"#)
                }
            }()
            let response = HTTPURLResponse(
                url: request.url!, statusCode: statusCode, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(payload.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        if request.url?.absoluteString == "https://hardcover.app/oauth/token" {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Content-Type"),
                "application/x-www-form-urlencoded")
            var bodyData = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    bodyData.append(contentsOf: bytes.prefix(count))
                }
            }
            let bodyString = String(decoding: bodyData, as: UTF8.self)
            if bodyString.contains("code=valid_code")
                || bodyString.contains("code=auth_code_success")
            {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                let payload = #"{"access_token":"hc_pat_success","token_type":"Bearer"}"#
                client?.urlProtocol(self, didLoad: Data(payload.utf8))
                client?.urlProtocolDidFinishLoading(self)
                return
            } else {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 400, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                let payload = #"{"error":"invalid_grant"}"#
                client?.urlProtocol(self, didLoad: Data(payload.utf8))
                client?.urlProtocolDidFinishLoading(self)
                return
            }
        }

        XCTAssertEqual(request.url?.absoluteString, "https://api.hardcover.app/v1/graphql")
        XCTAssertEqual(request.httpMethod, "POST")
        let status: Int
        let body: String
        switch request.value(forHTTPHeaderField: "Authorization") {
        case "Bearer hc_pat_validate", "Bearer hc_pat_pages", "Bearer hc_pat_partial":
            status = 200
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    data.append(contentsOf: bytes.prefix(count))
                }
            }
            let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            let query = object["query"] as! String
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer hc_pat_validate" {
                XCTAssertTrue(
                    query.contains("ShelfAccount"), "Token rotation must not resync the library.")
            }
            if query.contains("ShelfAccount") {
                body = #"{"data":{"me":[{"id":1}]}}"#
            } else {
                let offset = (object["variables"] as! [String: Int])["offset"]!
                if offset > 0
                    && request.value(forHTTPHeaderField: "Authorization") == "Bearer hc_pat_partial"
                {
                    body = #"{"errors":[{"message":"fixture failure"}]}"#
                } else {
                    let rows = (offset..<(offset == 0 ? 100 : 101))
                        .map { index in
                            [
                                "id": index + 1,
                                "book": ["id": index + 1, "title": "Fixture \(index)"],
                            ] as [String: Any]
                        }
                    body = String(
                        decoding: try! JSONSerialization.data(withJSONObject: [
                            "data": ["user_books": rows]
                        ]), as: UTF8.self)
                }
            }
        case "Bearer hc_pat_success":
            status = 200
            // The account and library decoders each consume their own response field.
            body = #"{"data":{"me":[{"id":1}],"user_books":[]}}"#
        case "Bearer hc_pat_scope":
            status = 403
            body = #"{"error":"insufficient_scope","scope":"read:library"}"#
        case "Bearer hc_pat_forbidden":
            status = 403
            body = #"{"error":"unsupported_operation"}"#
        case "Bearer hc_pat_expired":
            status = 401
            body = #"{"error":"invalid_token"}"#
        default:
            XCTFail("An unexpected credential reached the transport.")
            status = 401
            body = "{}"
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
