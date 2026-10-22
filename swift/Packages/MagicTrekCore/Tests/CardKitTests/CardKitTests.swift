import XCTest
@testable import CardKit

final class CardKitTests: XCTestCase {
    func testDatabaseLoads() throws {
        let db = try CardDatabase.bundled()
        XCTAssertGreaterThan(db.cards.count, 300)
        XCTAssertNotNil(db.card(named: "Captain Jean-Luc Picard"))
        XCTAssertEqual(db.card(named: "Swamp")?.isBasicLand, true)
    }

    func testManaCostParsing() {
        let c = ManaCost(parsing: "{2}{W}{W}")
        XCTAssertEqual(c.generic, 2); XCTAssertEqual(c.colored[.white], 2); XCTAssertEqual(c.manaValue, 4)
        let h = ManaCost(parsing: "{X}{U/B}{C}")
        XCTAssertTrue(h.hasX); XCTAssertEqual(h.hybrid, [[.blue, .black]]); XCTAssertEqual(h.generic, 1)
        XCTAssertEqual(ManaCost(parsing: "").manaValue, 0)
    }

    func testBasicLandMana() throws {
        let db = try CardDatabase.bundled()
        let swamp = try XCTUnwrap(db.card(named: "Swamp"))
        XCTAssertEqual(db.parsed(swamp).manaColors, [.black])
        XCTAssertTrue(db.parsed(swamp).fullySupported)
    }
}
