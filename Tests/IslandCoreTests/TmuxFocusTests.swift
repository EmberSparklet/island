import XCTest

@testable import IslandCore

final class TmuxFocusTests: XCTestCase {
    private func step(_ command: String, _ status: Int32) -> TmuxFocus.Step {
        TmuxFocus.Step(command: command, status: status)
    }

    func testAllStepsSucceededHasNoFallback() {
        let steps = [
            step("select-window", 0), step("select-pane", 0), step("switch-client", 0),
        ]

        XCTAssertNil(TmuxFocus.firstFailure(in: steps))
        XCTAssertNil(TmuxFocus.fallbackReason(steps))
    }

    func testNoStepsHasNoFallback() {
        XCTAssertNil(TmuxFocus.firstFailure(in: []))
        XCTAssertNil(TmuxFocus.fallbackReason([]))
    }

    func testAFailedSelectWindowFallsBack() {
        let steps = [
            step("select-window", 1), step("select-pane", 0), step("switch-client", 0),
        ]

        XCTAssertEqual(TmuxFocus.firstFailure(in: steps), steps[0])
        XCTAssertEqual(TmuxFocus.fallbackReason(steps), "tmux select-window failed (status 1)")
    }

    func testAFailedSelectPaneFallsBack() {
        let steps = [
            step("select-window", 0), step("select-pane", 1), step("switch-client", 0),
        ]

        XCTAssertEqual(TmuxFocus.fallbackReason(steps), "tmux select-pane failed (status 1)")
    }

    func testAFailedSwitchClientFallsBack() {
        let steps = [
            step("select-window", 0), step("select-pane", 0), step("switch-client", 1),
        ]

        XCTAssertEqual(TmuxFocus.fallbackReason(steps), "tmux switch-client failed (status 1)")
    }

    func testTheFirstFailureIsReported() {
        let steps = [
            step("select-window", 2), step("select-pane", 0), step("switch-client", 1),
        ]

        XCTAssertEqual(TmuxFocus.fallbackReason(steps), "tmux select-window failed (status 2)")
    }

    func testACommandThatCouldNotStartCountsAsFailure() {
        let steps = [
            step("select-window", 0), step("select-pane", 0), step("switch-client", -1),
        ]

        XCTAssertEqual(TmuxFocus.fallbackReason(steps), "tmux switch-client failed (status -1)")
    }
}
