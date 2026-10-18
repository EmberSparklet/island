import XCTest

@testable import IslandCore

final class OverlayScrollHintTests: XCTestCase {
    func testHidesWhenEverythingFits() {
        XCTAssertFalse(
            OverlayScrollHint.shouldShow(offsetY: 0, visibleHeight: 100, contentHeight: 100))
        XCTAssertFalse(
            OverlayScrollHint.shouldShow(offsetY: 0, visibleHeight: 100, contentHeight: 60))
    }

    func testShowsWhileContentIsBelowTheVisiblePart() {
        XCTAssertTrue(
            OverlayScrollHint.shouldShow(offsetY: 0, visibleHeight: 100, contentHeight: 200))
        XCTAssertTrue(
            OverlayScrollHint.shouldShow(offsetY: 50, visibleHeight: 100, contentHeight: 200))
    }

    func testHidesWhenScrolledToTheBottom() {
        XCTAssertFalse(
            OverlayScrollHint.shouldShow(offsetY: 100, visibleHeight: 100, contentHeight: 200))
        XCTAssertFalse(
            OverlayScrollHint.shouldShow(offsetY: 140, visibleHeight: 100, contentHeight: 200))
    }
}
