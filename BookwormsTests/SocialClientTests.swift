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
        XCTAssertEqual(
            activities.count, 3, "The goal and the event without a reader are left out")
        XCTAssertEqual(activities[0].summary, "Reading progress: 90%")
        XCTAssertEqual(activities[0].rating, 4.5)
        XCTAssertEqual(activities[0].review, "A thoughtful ending.")
        XCTAssertTrue(activities[0].hasSpoilers)
        XCTAssertEqual(activities[1].summary, "Updated list: Memoirs")
        XCTAssertEqual(activities[2].summary, "Shared a reading update")
        XCTAssertTrue(activities[2].hasSpoilers)
        XCTAssertEqual(
            activities[0].book?.detailCoverURL?.absoluteString,
            "https://artwork.fixture.invalid/e.jpg")
    }

    func testCompleteRatedLibraryPaginationKeepsReaderRatingsSeparate() async throws {
        let books = try await client().library(user: 2, token: "hc_pat_fixture")
        XCTAssertEqual(books.count, 100)
        XCTAssertFalse(books.contains { $0.id == 1 }, "Ignored books are left out")
        XCTAssertEqual(books.last?.rating, 4.5)
        XCTAssertNil(books.last?.book.rating)
        XCTAssertEqual(books.last?.book.isRead, true, "Status Read marks a book read")
        XCTAssertNil(books.first?.book.isRead)
        // Details for followed readers' books show the same catalog data as library books.
        let book = try XCTUnwrap(books.last?.book)
        XCTAssertEqual(book.communityRating, 4.2)
        XCTAssertEqual(book.ratingDistribution?.map(\.rating), [4.5])
        XCTAssertEqual(book.genres, ["Fantasy"])
        XCTAssertEqual(book.publicationYear, 2014)
        let unrated = try JSONDecoder()
            .decode(SourceBook.self, from: Data(#"{"id":11,"rating":0,"ratings_count":0}"#.utf8))
        XCTAssertNil(
            HardcoverSocialClient.book(unrated).communityRating,
            "Hardcover's 0 average for an unrated book shows no rating")
    }

    func testFollowedReadersAndOwnerDecodeWithoutOptionalProfileData() async throws {
        let client = client()
        let owner = try await client.owner(token: "hc_pat_fixture")
        XCTAssertEqual(owner.username, "fixture")
        let following = try await client.following(owner: 1, token: "hc_pat_fixture")
        XCTAssertEqual(
            following.map(\.id), [2],
            "Blocked reader 3 and readers whose profile Hardcover withholds are left out")
    }

    /// Without the block list, followed readers and community reviews fail instead of showing
    /// readers the owner blocked.
    func testFailedBlockListStopsFollowingAndReviews() async {
        let client = client()
        do {
            _ = try await client.following(owner: 1, token: SocialResponseStub.blockFailureToken)
            XCTFail("Following must not load without the block list")
        } catch HardcoverError.forbidden {
        } catch { XCTFail("Unexpected error: \(error)") }
        do {
            _ = try await client.reviews(book: 7, token: SocialResponseStub.blockFailureToken)
            XCTFail("Reviews must not load without the block list")
        } catch HardcoverError.forbidden {
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testCommunityReviewsLeaveOutBlockedReadersEvenWithoutProfiles() async throws {
        let reviews = try await client().reviews(book: 7, token: "hc_pat_fixture")
        XCTAssertEqual(reviews.map(\.id), [10, 13])
        XCTAssertEqual(reviews.last?.reader.name, "Hardcover reader")
    }
}

private final class SocialResponseStub: URLProtocol, @unchecked Sendable {
    /// Requests with this token get HTTP 403 for the block list.
    static let blockFailureToken = "hc_pat_fixture_block_failure"
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
            if query == SocialQuery.blocked.rawValue,
                request.value(forHTTPHeaderField: "Authorization")
                    == "Bearer \(Self.blockFailureToken)"
            {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("{}".utf8))
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let profile: [String: Any] = ["id": 2, "username": "fixture"]
            let data: [String: Any]
            if query == SocialQuery.owner.rawValue {
                data = ["me": [profile]]
            } else if query == SocialQuery.following.rawValue {
                data = [
                    "followed_users": [
                        ["followed_user": profile],
                        ["followed_user": ["id": 3, "username": "blocked"]],
                        // Hardcover withholds these two readers' profiles.
                        ["followed_user": NSNull()],
                        ["followed_user": ["id": 4]],
                    ] as [[String: Any]]
                ]
            } else if query == SocialQuery.blocked.rawValue {
                data = ["user_blocks": [["blocked_user_id": 3]]]
            } else if query == SocialQuery.bookReviews.rawValue {
                let variables = payload["variables"] as? [String: Any]
                XCTAssertEqual(variables?["blocked"] as? [Int], [3])
                // Reader 3 is blocked, including a review whose profile Hardcover withholds.
                let rows: [(id: Int, user: Int?, profile: [String: Any]?)] = [
                    (10, 2, profile), (11, 3, ["id": 3, "username": "blocked"]), (12, 3, nil),
                    (13, nil, nil),
                ]
                data = [
                    "user_books": rows.map { row in
                        [
                            "id": row.id, "review": "Review \(row.id)",
                            "review_has_spoilers": false, "likes_count": 0,
                            "user_id": row.user ?? NSNull(), "user": row.profile ?? NSNull(),
                        ] as [String: Any]
                    }
                ]
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
                    ("GoalActivity", ["goal": ["goal": 40, "progress": 30]]),
                    // Hardcover withholds the last event's reader, so the feed leaves it out.
                    ("UserBookActivity", ["userBook": ["statusId": 3]]),
                ]
                data = [
                    "activities": events.enumerated()
                        .map { index, event in
                            [
                                "id": 3 - index, "event": event.0, "data": event.1,
                                "likes_count": 2,
                                "user": index == events.count - 1 ? NSNull() : profile,
                                // Goals have no book, so the feed leaves them out.
                                "book": event.0 == "GoalActivity"
                                    ? NSNull()
                                    : [
                                        "id": 20 + index, "title": "Book \(index)",
                                        // No default image; the cover comes from an edition.
                                        "editions": [
                                            [
                                                "image": [
                                                    "url": "https://artwork.fixture.invalid/e.jpg",
                                                    "width": 400, "height": 600,
                                                ]
                                            ]
                                        ],
                                    ],
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
                                "status_id": index == 100 ? 3 : index == 1 ? 6 : 1,
                                "book": [
                                    "id": index, "title": "Book \(index)", "release_year": 2014,
                                    "rating": 4.2, "ratings_count": 4,
                                    "ratings_distribution": [
                                        ["rating": 4.5, "count": 3], ["rating": 7, "count": 1],
                                    ],
                                    "cached_tags": [
                                        "Genre": [
                                            ["tag": "Fiction", "count": 9],
                                            ["tag": "Fantasy", "count": 5],
                                        ]
                                    ],
                                ],
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
        [owner, following, feed, library, bookReviews, blocked].map(\.rawValue)
    }
}
