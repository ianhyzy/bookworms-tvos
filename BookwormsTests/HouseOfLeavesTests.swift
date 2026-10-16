import XCTest

@testable import Bookworms

final class HouseOfLeavesTests: XCTestCase {
    private func book(_ title: String, by author: String) -> Book {
        Book(id: 1, title: title, author: author)
    }

    func testRecognizesTheNovelByAuthorAndTitleInAnyEdition() {
        XCTAssertTrue(HouseOfLeaves.isNovel(book("House of Leaves", by: "Mark Z. Danielewski")))
        XCTAssertTrue(
            HouseOfLeaves.isNovel(
                book("HOUSE OF LEAVES: The Remastered Full-Color Edition", by: "Mark Danielewski")))
        XCTAssertTrue(
            HouseOfLeaves.isNovel(book("House of Leaves (2nd ed.)", by: "Mark Z. Danielewski")))
        XCTAssertFalse(HouseOfLeaves.isNovel(book("House of Leaves", by: "Someone Else")))
        XCTAssertFalse(
            HouseOfLeaves.isNovel(book("The Fifty Year Sword", by: "Mark Z. Danielewski")))
        XCTAssertFalse(HouseOfLeaves.isNovel(book("Bleak House", by: "Charles Dickens")))
    }

    func testFindsWholeWordHousesOnly() {
        let text = "House, houses, HOUSE's, house’s; household, lighthouse, Housing, the house."
        XCTAssertEqual(
            HouseOfLeaves.houseRanges(in: text).map { String(text[$0]) },
            ["House", "houses", "HOUSE's", "house’s", "house"])
    }

    func testBlueMovesOnlyInLightnessUntilItReadsOnItsGround() {
        let white = StyleColor(red: 1, green: 1, blue: 1)
        let onWhite = HouseOfLeaves.lettering(on: white)
        XCTAssertEqual(onWhite.blue, HouseOfLeaves.novelBlue, "The novel's blue reads on white")
        XCTAssertTrue(onWhite.glows, "A blue darker than its ground glows")

        for ground in [HouseOfLeaves.darkGround, HouseOfLeaves.lightGround] {
            let lettering = HouseOfLeaves.lettering(on: ground)
            XCTAssertTrue(HouseOfLeaves.passes(lettering.blue, on: ground))
            let lab = lettering.blue.oklab
            let novel = HouseOfLeaves.novelBlue.oklab
            XCTAssertEqual(atan2(lab.b, lab.a), atan2(novel.b, novel.a), accuracy: 0.05)
        }
        XCTAssertFalse(HouseOfLeaves.onDark.glows, "A blue lighter than its ground has no glow")
        XCTAssertGreaterThan(HouseOfLeaves.onDark.blue.oklab.l, HouseOfLeaves.novelBlue.oklab.l)
        XCTAssertTrue(HouseOfLeaves.onLight.glows)

        // No lightness of the blue reads on a mid-blue cloth, so the word takes the ink.
        let cloth = StyleColor(red: 0.40, green: 0.44, blue: 0.68)
        XCTAssertEqual(HouseOfLeaves.lettering(on: cloth, ink: white).blue, white)
    }

    func testAttributedLetteringBluesOnlyTheNovel() {
        let font = UIFont.systemFont(ofSize: 40)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: UIColor.white,
        ]
        let lettering = HouseOfLeaves.Lettering(blue: HouseOfLeaves.novelBlue, glows: true)
        let novel = HouseOfLeaves.attributed(
            "House of Leaves", of: book("House of Leaves", by: "Mark Z. Danielewski"),
            attributes: attributes, lettering: lettering)
        XCTAssertEqual(
            novel.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor,
            HouseOfLeaves.novelBlue.uiColor)
        XCTAssertNotNil(novel.attribute(.shadow, at: 0, effectiveRange: nil))
        XCTAssertEqual(
            novel.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? UIColor, .white)
        let other = HouseOfLeaves.attributed(
            "Bleak House", of: book("Bleak House", by: "Charles Dickens"),
            attributes: attributes, lettering: lettering)
        XCTAssertEqual(
            other.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? UIColor, .white)
    }
}
