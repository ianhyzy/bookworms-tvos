import RealityKit
import XCTest

@testable import Bookworms

final class BookWallMotionTests: XCTestCase {
    private let fall = BookWallFall(dropHeight: 9, gravity: 22, damping: 0.25)

    private func falling(_ layout: BookWallLayout) -> [BookWallFall.Book] {
        BookWallScene.fallingBooks(of: layout)
    }

    private func wall(_ count: Int) -> BookWallLayout {
        BookWallLayout(
            books: (1...count)
                .map { id in
                    Book(id: id, title: "Book \(id)", author: "Author", pages: 120 + id * 23)
                })
    }

    func testEveryBookWaitsAtTheDropHeightUntilItsTurn() {
        let books = [
            BookWallFall.Book(rest: 0, column: 0, delay: 0),
            BookWallFall.Book(rest: 0, column: 1, delay: 2),
        ]
        let start = fall.heights(of: books, after: 0)
        XCTAssertEqual(start.heights, [9, 9])
        XCTAssertFalse(start.landed)
        let later = fall.heights(of: books, after: 1)
        XCTAssertLessThan(later.heights[0], 9)
        XCTAssertEqual(later.heights[1], 9, "The second book hasn't started")
    }

    func testBooksLandAtTheirRestingHeights() {
        let layout = wall(57)
        let books = falling(layout)
        let end = fall.heights(of: books, after: 60)
        XCTAssertTrue(end.landed)
        XCTAssertEqual(end.heights, layout.slots.map(\.restingY))
        // A book rests where its pose puts it.
        for (slot, height) in zip(layout.slots, end.heights) {
            XCTAssertEqual(
                BookWallScene.restingTransform(for: slot, in: layout).translation.y, height)
        }
    }

    func testAFallingBookOnlyMovesDownAndNeverPassesTheOneBelowIt() {
        let layout = wall(57)
        let books = falling(layout)
        var previous = fall.heights(of: books, after: 0).heights
        var landedAt: TimeInterval?
        for step in 1...3_600 {
            let seconds = Double(step) / 120
            let now = fall.heights(of: books, after: seconds)
            // The book below each book: the one before it in its column.
            var below: [Int: Int] = [:]
            for (index, book) in books.enumerated() {
                XCTAssertLessThanOrEqual(now.heights[index], previous[index])
                XCTAssertGreaterThanOrEqual(now.heights[index], book.rest)
                if let lower = below[book.column] {
                    // Two books of a column are never closer than they rest.
                    XCTAssertGreaterThanOrEqual(
                        now.heights[index] - now.heights[lower],
                        book.rest - books[lower].rest - 1e-4)
                }
                below[book.column] = index
            }
            XCTAssertEqual(now.landed, now.heights == books.map(\.rest))
            if now.landed, landedAt == nil { landedAt = seconds }
            previous = now.heights
        }
        XCTAssertNotNil(landedAt, "The fall ends")
    }

    func testABookStopsOnABookThatIsStillFalling() {
        // The upper book starts first, so it would pass the lower one if nothing held it.
        let books = [
            BookWallFall.Book(rest: 0, column: 0, delay: 1),
            BookWallFall.Book(rest: 1, column: 0, delay: 0),
        ]
        let waiting = fall.heights(of: books, after: 0.9)
        XCTAssertEqual(waiting.heights, [9, 10], "The upper book rests on the waiting one")
        let end = fall.heights(of: books, after: 60)
        XCTAssertEqual(end.heights, [0, 1])
        XCTAssertTrue(end.landed)
    }

    private func frame(x: Float, turn: Float, cameraDepth: Float) -> BookWallFlightFrame {
        BookWallFlightFrame(
            pose: Transform(
                rotation: simd_quatf(angle: turn, axis: [0, 1, 0]), translation: [x, 0, 0]),
            cameraDepth: cameraDepth)
    }

    func testAFlightStartsOnItsFirstFrameAndEndsOnItsLast() throws {
        let frames = [
            frame(x: 0, turn: 0, cameraDepth: 10), frame(x: 2, turn: 0.4, cameraDepth: 12),
            frame(x: 6, turn: 1, cameraDepth: 16),
        ]
        let flight = BookWallFlight(frames: frames, duration: 1.8, fromLevel: 0, toLevel: 1)

        let start = try XCTUnwrap(flight.sample(at: 0))
        XCTAssertEqual(start.pose.translation, frames[0].pose.translation)
        XCTAssertEqual(start.cameraDepth, 10)
        XCTAssertEqual(start.level, 0)
        XCTAssertFalse(start.isOver)

        // A quarter of the way is halfway between the first two samples.
        let quarter = try XCTUnwrap(flight.sample(at: 0.45))
        XCTAssertEqual(quarter.pose.translation.x, 1, accuracy: 1e-5)
        XCTAssertEqual(quarter.pose.rotation.angle, 0.2, accuracy: 1e-5)
        XCTAssertEqual(quarter.cameraDepth, 11, accuracy: 1e-5)
        XCTAssertFalse(quarter.isOver)

        for elapsed in [1.8, 1.9, 60] {
            let end = try XCTUnwrap(flight.sample(at: elapsed))
            XCTAssertEqual(end.pose, frames[2].pose)
            XCTAssertEqual(end.cameraDepth, 16)
            XCTAssertEqual(end.level, 1)
            XCTAssertTrue(end.isOver)
        }
    }

    func testAFlightsLightLevelEasesBetweenItsLevels() throws {
        let frames = [frame(x: 0, turn: 0, cameraDepth: 10), frame(x: 1, turn: 0, cameraDepth: 10)]
        let returning = BookWallFlight(frames: frames, duration: 2, fromLevel: 1, toLevel: 0)
        var previous: Float = 1
        for step in 0...20 {
            let level = try XCTUnwrap(returning.sample(at: Double(step) / 10)).level
            XCTAssertLessThanOrEqual(level, previous)
            previous = level
        }
        XCTAssertEqual(try XCTUnwrap(returning.sample(at: 1)).level, 0.5, accuracy: 1e-6)
        XCTAssertEqual(previous, 0)
    }

    func testReduceMotionsFlightOfNoLengthIsOverAtOnce() throws {
        let destination = frame(x: 6, turn: 1, cameraDepth: 16)
        let flight = BookWallFlight(frames: [destination], duration: 0, fromLevel: 1, toLevel: 1)
        let sample = try XCTUnwrap(flight.sample(at: 0))
        XCTAssertEqual(sample.pose, destination.pose)
        XCTAssertEqual(sample.cameraDepth, 16)
        XCTAssertEqual(sample.level, 1)
        XCTAssertTrue(sample.isOver)
    }

    func testAFlightWithoutFramesHasNothingToShow() {
        XCTAssertNil(
            BookWallFlight(frames: [], duration: 1.8, fromLevel: 0, toLevel: 1).sample(at: 0))
    }
}
