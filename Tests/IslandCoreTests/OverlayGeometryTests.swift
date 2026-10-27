import CoreGraphics
import XCTest

@testable import IslandCore

/// The panel window is exactly the capsule: the frosted material paints only
/// inside its rounded shape, so there is no shadow margin to leave room for and
/// nothing to click through.
final class OverlayGeometryTests: XCTestCase {
    private let content = CGSize(width: 520, height: 134)

    /// The capsule hangs from the menu bar, so its top edge is the window's.
    func testTheOriginKeepsTheCapsuleTopFlush() {
        let origin = OverlayGeometry.windowOrigin(
            capsuleTop: 900, centerX: 800, content: content)

        XCTAssertEqual(origin.y + content.height, 900)
    }

    func testTheOriginCentresTheCapsule() {
        let origin = OverlayGeometry.windowOrigin(
            capsuleTop: 900, centerX: 800, content: content)

        XCTAssertEqual(origin.x, 800 - content.width / 2)
        XCTAssertEqual(origin.x + content.width / 2, 800)
    }

    /// No margin: anything outside the content would be empty window.
    func testTheOriginLeavesNoMarginAroundTheCapsule() {
        let origin = OverlayGeometry.windowOrigin(
            capsuleTop: 900, centerX: 800, content: content)

        XCTAssertEqual(origin, CGPoint(x: 540, y: 766))
    }
}
