import Foundation
import XCTest

@testable import Bookworms

final class SocialClientTests: XCTestCase {
    private func client() -> HardcoverSocialClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SocialResponseStub.self]
        return HardcoverSocialClient(
            client: HardcoverClient(session: URLSession(configuration: configuration)))
    }

    func testPublishedActivityPayloadsAndUnknownEvents() async throws {
        let activities = try await client().feed(users: [2], token: "hc_pat_fixture")
        XCTAssertEqual(activities.count, 3)
        XCTAssertEqual(activities[0].summary, "Reading progress: 90%")
        XCTAssertEqual(activities[0].rating, 4.5)
        XCTAssertEqual(activities[0].review, "A thoughtful ending.")
        XCTAssertTrue(activities[0].hasSpoilers)
        XCTAssertEqual(activities[1].summary, "Updated list: Memoirs")
        XCTAssertEqual(activities[2].summary, "Shared a reading update")
        XCTAssertTrue(activities[2].hasSpoilers)
    }

    func testCompleteRatedLibraryPaginationKeepsReaderRatingsSeparate() async throws {
        let books = try await client().library(user: 2, token: "hc_pat_fixture")
        XCTAssertEqual(books.count, 101)
        XCTAssertEqual(books.last?.rating, 4.5)
        XCTAssertNil(books.last?.book.rating)
    }

    func testFollowedReadersAndOwnerDecodeWithoutOptionalProfileData() async throws {
        let client = client()
        let owner = try await client.owner(token: "hc_pat_fixture")
        XCTAssertEqual(owner.username, "fixture")
        let following = try await client.following(owner: 1, token: "hc_pat_fixture")
        XCTAssertEqual(following.map(\.id), [2])
    }
}

private final class SocialResponseStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let body: Data
            if let data = request.httpBody {
                body = data
            } else if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                body = data
            } else {
                throw URLError(.badServerResponse)
            }
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let query = try XCTUnwrap(payload["query"] as? String)
            XCTAssertTrue(SocialQuery.allDocuments.contains(query))
            XCTAssertFalse(query.contains("mutation"))
            let profile: [String: Any] = ["id": 2, "username": "fixture"]
            let data: [String: Any]
            if query == SocialQuery.owner.rawValue {
                data = ["me": [profile]]
            } else if query == SocialQuery.following.rawValue {
                data = ["followed_users": [["followed_user": profile]]]
            } else if query == SocialQuery.feed.rawValue {
                let events: [(String, [String: Any])] = [
                    (
                        "UserBookActivity",
                        [
                            "userBook": [
                                "statusId": 2, "progress": 90.5, "rating": "4.5",
                                "reviewHasSpoilers": true,
                                "reviewSlate": [["children": [["text": "A thoughtful ending."]]]],
                            ]
                        ]
                    ),
                    ("ListActivity", ["list": ["name": "Memoirs"]]),
                    ("FutureActivity", ["unsupported": true]),
                ]
                data = [
                    "activities": events.enumerated()
                        .map { index, event in
                            [
                                "id": 3 - index, "event": event.0, "data": event.1,
                                "likes_count": 2, "user": profile,
                            ] as [String: Any]
                        }
                ]
            } else {
                let variables = payload["variables"] as? [String: Any]
                let offset = variables?["offset"] as? Int ?? 0
                data = [
                    "user_books": (offset..<min(101, offset + 100))
                        .map { index in
                            [
                                "id": index, "rating": 4.5, "review_has_spoilers": false,
                                "book": ["id": index, "title": "Book \(index)"],
                            ] as [String: Any]
                        }
                ]
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?
                .urlProtocol(
                    self, didLoad: try JSONSerialization.data(withJSONObject: ["data": data]))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

extension SocialQuery {
    fileprivate static var allDocuments: [String] {
        [owner, following, feed, library].map(\.rawValue)
    }
}
