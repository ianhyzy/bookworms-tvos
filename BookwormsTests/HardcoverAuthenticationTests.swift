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
        XCTAssertEqual(
            success,
            .success(
                HardcoverTokens(
                    accessToken: "hc_at_success", refreshToken: "hc_rt_success",
                    expiresIn: 604_800)))

        do {
            _ = try await client().pollDeviceToken(deviceCode: "device_rejected")
            XCTFail("A rejected device code must fail.")
        } catch HardcoverError.invalidAuthorizationCode {
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testRefreshSpendsTheRefreshTokenForItsReplacement() async throws {
        // The stub accepts only the percent-encoded `+`, so a token reaches Hardcover unchanged.
        let tokens = try await client().refreshTokens("hc_rt_fixture+plus")
        XCTAssertEqual(
            tokens,
            HardcoverTokens(
                accessToken: "hc_at_rotated", refreshToken: "hc_rt_rotated", expiresIn: 604_800))
    }

    func testRejectedRefreshTokenRequiresReconnection() async {
        do {
            _ = try await client().refreshTokens("hc_rt_spent")
            XCTFail("A spent refresh token must fail.")
        } catch HardcoverError.invalidToken {
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testUnavailableTokenEndpointIsNotReportedAsRevoked() async {
        do {
            _ = try await client().refreshTokens("hc_rt_unavailable")
            XCTFail("A server error must fail.")
        } catch HardcoverError.http(503) {
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testOnlyInvalidGrantWithHTTP400Or401RejectsTheRefreshToken() async {
        let cases: [(token: String, expected: HardcoverError)] = [
            ("hc_rt_spent", .invalidToken), ("hc_rt_unknown_client", .http(401)),
            ("hc_rt_html", .http(400)), ("hc_rt_numeric_error", .http(400)),
            ("hc_rt_forbidden", .http(403)), ("hc_rt_limited", .http(429)),
        ]
        for (token, expected) in cases {
            do {
                _ = try await client().refreshTokens(token)
                XCTFail("\(token) must fail.")
            } catch {
                // `HardcoverError` isn't `Equatable`; its cases describe themselves.
                XCTAssertEqual(String(describing: error), String(describing: expected), token)
            }
        }
    }

    func testTokenResponseDropsAMalformedRefreshTokenOrExpiry() throws {
        for json in [
            #"{"access_token":"hc_at_fixture","refresh_token":"hc_rt two words","expires_in":"604800"}"#,
            #"{"access_token":"hc_at_fixture","refresh_token":42,"expires_in":604800.5}"#,
            #"{"access_token":"hc_at_fixture","refresh_token":null,"expires_in":null}"#,
        ] {
            let tokens = try JSONDecoder().decode(HardcoverTokens.self, from: Data(json.utf8))
            XCTAssertEqual(tokens, HardcoverTokens(accessToken: "hc_at_fixture"), json)
        }
    }

    @MainActor
    func testRenewalIsDueADayEarlyOrHalfwayThroughAShortLifetime() {
        let issued = Date(timeIntervalSince1970: 1_780_000_000)
        func renewal(_ expiresIn: Int?, refreshToken: String? = "hc_rt_fixture") -> Date? {
            HardcoverSession.renewalDate(
                of: HardcoverTokens(
                    accessToken: "hc_at_fixture", refreshToken: refreshToken,
                    expiresIn: expiresIn),
                issued: issued)
        }
        XCTAssertEqual(renewal(604_800), issued.addingTimeInterval(518_400))
        XCTAssertEqual(renewal(172_800), issued.addingTimeInterval(86_400))
        XCTAssertEqual(renewal(3_600), issued.addingTimeInterval(1_800))
        XCTAssertNil(renewal(0))
        XCTAssertNil(renewal(nil))
        XCTAssertNil(renewal(604_800, refreshToken: nil), "A login without a refresh token")
    }

    func testRevocationSendsTheRefreshToken() async throws {
        // The stub accepts only the exact form, with the `+` percent-encoded.
        try await client().revoke(refreshToken: "hc_rt_fixture+plus")
    }

    func testFailedRevocationReportsTheStatus() async {
        do {
            try await client().revoke(refreshToken: "hc_rt_unknown")
            XCTFail("A rejected revocation must fail.")
        } catch HardcoverError.http(400) {
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testReplacementTokenCanBeValidatedWithoutLoadingBooks() async throws {
        let accountID = try await client().validateToken("hc_pat_validate")
        XCTAssertEqual(accountID, "1")
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

    func testSavedCoversStayOnlyForTheAuthenticatedAccount() async throws {
        // The stub's account is 1, and its only book reports a 1500-pixel cover.
        let saved = Book(
            id: 5, title: "Covered", author: "Unknown author",
            coverURL: URL(string: "https://example.com/saved-alternate"),
            detailCoverURL: URL(string: "https://example.com/saved"))
        func snapshot(_ accountID: String) -> SourceSnapshot {
            SourceSnapshot(
                source: .hardcover, accountID: accountID, books: [saved], syncedAt: .distantPast)
        }
        let same = try await client().fetchLibrary(token: "hc_pat_covers", previous: snapshot("1"))
        XCTAssertEqual(same.books.first?.detailCoverURL, saved.detailCoverURL)
        XCTAssertEqual(same.books.first?.coverURL, saved.coverURL)
        let other = try await client()
            .fetchLibrary(token: "hc_pat_covers", previous: snapshot("2"))
        XCTAssertEqual(
            other.books.first?.detailCoverURL, URL(string: "https://example.com/current"),
            "Another account's snapshot never fixes covers")
    }

    func testFailedSeriesBatchKeepsFetchedAndSavedSeries() async throws {
        // The stub's only book is in series 1 to 60, and the second batch of 50 fails.
        let saved = SourceSnapshot(
            source: .hardcover, accountID: "1", books: [], syncedAt: .distantPast,
            series: [
                SeriesInfo(id: 5, name: "Saved five", books: []),
                SeriesInfo(id: 55, name: "Saved fifty-five", books: []),
            ])
        let library = try await client().fetchLibrary(token: "hc_pat_series", previous: saved)
        let series = try XCTUnwrap(library.series)
        XCTAssertEqual(series.map(\.id), Array(1...50) + [55])
        XCTAssertEqual(series.first { $0.id == 5 }?.name, "Fixture series 5")
        XCTAssertEqual(series.last?.name, "Saved fifty-five")
        let unsaved = try await client().fetchLibrary(token: "hc_pat_series")
        XCTAssertEqual(unsaved.series?.map(\.id), Array(1...50))
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

    /// The request's form body, whether URLSession passes it as data or as a stream.
    private func formBody() -> String {
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
        return String(decoding: data, as: UTF8.self)
    }

    override func startLoading() {
        if request.url?.absoluteString == "https://api.hardcover.app/oauth2/device" {
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

        if request.url?.absoluteString == "https://api.hardcover.app/oauth2/token" {
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
                if bodyString.contains("grant_type=refresh_token") {
                    XCTAssertTrue(bodyString.contains("client_id=\(HardcoverClient.clientID)"))
                    XCTAssertFalse(bodyString.contains("scope="), "A renewal keeps its scopes")
                    if bodyString.contains("refresh_token=hc_rt_fixture%2Bplus") {
                        return (
                            200,
                            #"{"access_token":"hc_at_rotated","refresh_token":"hc_rt_rotated","expires_in":604800,"token_type":"Bearer"}"#
                        )
                    }
                    if bodyString.contains("refresh_token=hc_rt_unavailable") {
                        return (503, #"{"error":"temporarily_unavailable"}"#)
                    }
                    if bodyString.contains("refresh_token=hc_rt_unknown_client") {
                        return (401, #"{"error":"invalid_client"}"#)
                    }
                    if bodyString.contains("refresh_token=hc_rt_html") {
                        return (400, "<html>Bad request</html>")
                    }
                    if bodyString.contains("refresh_token=hc_rt_numeric_error") {
                        return (400, #"{"error":400}"#)
                    }
                    if bodyString.contains("refresh_token=hc_rt_forbidden") {
                        return (403, #"{"error":"access_denied"}"#)
                    }
                    if bodyString.contains("refresh_token=hc_rt_limited") {
                        return (429, #"{"error":"slow_down"}"#)
                    }
                    return (400, #"{"error":"invalid_grant"}"#)
                } else if bodyString.contains("device_code=device_pending") {
                    return (400, #"{"error":"authorization_pending"}"#)
                } else if bodyString.contains("device_code=device_slow_down") {
                    return (400, #"{"error":"slow_down"}"#)
                } else if bodyString.contains("device_code=device_expired") {
                    return (400, #"{"error":"expired_token"}"#)
                } else if bodyString.contains("device_code=device_denied") {
                    return (400, #"{"error":"access_denied"}"#)
                } else if bodyString.contains("device_code=device_success") {
                    return (
                        200,
                        #"{"access_token":"hc_at_success","refresh_token":"hc_rt_success","expires_in":604800,"token_type":"Bearer"}"#
                    )
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

        if request.url?.absoluteString == "https://api.hardcover.app/oauth2/revoke" {
            XCTAssertEqual(request.httpMethod, "POST")
            let accepted =
                formBody()
                == "token=hc_rt_fixture%2Bplus&token_type_hint=refresh_token&client_id="
                + HardcoverClient.clientID
            let response = HTTPURLResponse(
                url: request.url!, statusCode: accepted ? 200 : 400, httpVersion: nil,
                headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
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
                let variables = object["variables"] as! [String: Any]
                XCTAssertNotNil(variables["language"] as? String)
                let offset = variables["offset"] as! Int
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
        case "Bearer hc_pat_covers":
            status = 200
            body =
                #"{"data":{"me":[{"id":1}],"user_books":[{"id":1,"book":{"id":5,"title":"Covered","image":{"url":"https://example.com/current","width":1000,"height":1500}}}]}}"#
        case "Bearer hc_pat_series":
            status = 200
            let object =
                try! JSONSerialization.jsonObject(with: Data(formBody().utf8)) as! [String: Any]
            let query = object["query"] as! String
            let ids = (object["variables"] as? [String: Any])?["ids"] as? [Int] ?? []
            let response: Any
            if query.contains("ShelfAccount") {
                response = ["data": ["me": [["id": 1]]]]
            } else if query.contains("ShelfLibrary") {
                let memberships = (1...60)
                    .map { id in
                        ["position": 1, "series": ["id": id, "name": "Fixture series \(id)"]]
                    }
                response = [
                    "data": [
                        "user_books": [
                            [
                                "id": 1,
                                "book": ["id": 1, "title": "Fixture", "book_series": memberships],
                            ]
                        ]
                    ]
                ]
            } else if ids.contains(where: { $0 > 50 }) {
                response = ["errors": [["message": "fixture failure"]]]
            } else {
                response = [
                    "data": [
                        "series": ids.map { id in
                            [
                                "id": id, "name": "Fixture series \(id)",
                                "book_series": [
                                    ["position": 1, "book": ["id": 1, "title": "Fixture"]]
                                ],
                            ] as [String: Any]
                        }
                    ]
                ]
            }
            body = String(
                decoding: try! JSONSerialization.data(withJSONObject: response), as: UTF8.self)
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
