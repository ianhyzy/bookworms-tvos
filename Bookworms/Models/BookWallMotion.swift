import Foundation
import RealityKit
import simd

/// Easing shared by Book Wall's motion.
enum BookWallEasing {
    /// Eases from 0 to 1 with no velocity or acceleration at either end.
    static func smootherstep(_ value: Float) -> Float {
        let t = min(1, max(0, value))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }
}

/// A wall's fall, as a function of time: each book drops from the drop height under gravity
/// with linear damping and stops on its place, or on the book below it while that one still
/// falls. Nothing simulates it, so a late frame can't change where a book lands.
struct BookWallFall: Sendable {
    /// One falling book. Books are listed in the order they drop, so each column's books run
    /// from the bottom up.
    struct Book: Sendable {
        /// The height the book rests at.
        let rest: Float
        let column: Int
        /// When the book starts to fall, after the fall starts.
        let delay: TimeInterval
    }

    let dropHeight: Float
    let gravity: Float
    let damping: Float

    /// Each book's height `seconds` after the fall starts, and whether every book has landed.
    func heights(of books: [Book], after seconds: TimeInterval) -> (heights: [Float], landed: Bool)
    {
        var heights: [Float] = []
        heights.reserveCapacity(books.count)
        var landed = true
        // How far the last book of each column still is above its place.
        var above: [Int: Float] = [:]
        for book in books {
            let falling = Float(seconds - book.delay)
            var height = dropHeight
            if falling > 0 {
                // A drop from rest under gravity `g` with linear damping `k` has fallen
                // (g / k) · (t − (1 − e^(−kt)) / k) after `t` seconds.
                height -= gravity / damping * (falling - (1 - exp(-damping * falling)) / damping)
            }
            // A book stops on its place, or on the book below it while that one still falls,
            // so it lands the moment its support has.
            height = max(height, book.rest + (above[book.column] ?? 0))
            above[book.column] = height - book.rest
            heights.append(height)
            if height > book.rest { landed = false }
        }
        return (heights, landed)
    }
}

/// A book's flight to or from its details: evenly spaced samples of its path, played over
/// `duration` while the detail light level moves between two levels.
struct BookWallFlight: Sendable {
    /// Samples of the path, not display frames.
    let frames: [BookWallFlightFrame]
    let duration: TimeInterval
    let fromLevel: Float
    let toLevel: Float

    struct Sample {
        var pose: Transform
        var cameraDepth: Float
        /// The detail light level, from 0 at the resting wall to 1 with details open.
        var level: Float
        /// Whether the flight has reached its last frame, which it then holds.
        var isOver: Bool
    }

    /// The flight `elapsed` seconds after it starts, or `nil` for a flight without frames. A
    /// flight of no duration, as Reduce Motion plays, or of one frame is over at once.
    func sample(at elapsed: TimeInterval) -> Sample? {
        guard let last = frames.last else { return nil }
        let progress = duration > 0 ? min(1, Float(elapsed / duration)) : 1
        let level = fromLevel + (toLevel - fromLevel) * BookWallEasing.smootherstep(progress)
        guard progress < 1, frames.count > 1 else {
            return Sample(
                pose: last.pose, cameraDepth: last.cameraDepth, level: level, isOver: true)
        }
        let position = progress * Float(frames.count - 1)
        let index = min(Int(position), frames.count - 2)
        let fraction = position - Float(index)
        let (from, to) = (frames[index], frames[index + 1])
        return Sample(
            pose: Transform(
                rotation: simd_slerp(from.pose.rotation, to.pose.rotation, fraction),
                translation: from.pose.translation
                    + (to.pose.translation - from.pose.translation) * fraction),
            cameraDepth: from.cameraDepth + (to.cameraDepth - from.cameraDepth) * fraction,
            level: level, isOver: false)
    }
}
