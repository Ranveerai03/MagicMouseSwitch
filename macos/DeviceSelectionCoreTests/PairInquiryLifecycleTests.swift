import XCTest
@testable import MagicMouseSwitchServices

final class PairInquiryLifecycleTests: XCTestCase {
    private final class LifetimeProbe {}

    func testDelegateIsRetainedUntilInquiryCompletion() {
        let retainer = InquiryObjectRetainer()
        var delegate: LifetimeProbe? = LifetimeProbe()
        let inquiry = LifetimeProbe()
        weak let weakDelegate = delegate

        retainer.retain(delegate: delegate!, inquiry: inquiry)
        delegate = nil
        XCTAssertNotNil(weakDelegate)

        retainer.releaseAfterCompletion()
        XCTAssertNil(weakDelegate)
    }

    func testInquiryIsRetainedUntilInquiryCompletion() {
        let retainer = InquiryObjectRetainer()
        let delegate = LifetimeProbe()
        var inquiry: LifetimeProbe? = LifetimeProbe()
        weak let weakInquiry = inquiry

        retainer.retain(delegate: delegate, inquiry: inquiry!)
        inquiry = nil
        XCTAssertNotNil(weakInquiry)

        retainer.releaseAfterCompletion()
        XCTAssertNil(weakInquiry)
    }

    func testDeviceFoundCallbackCanPrecedeCompletion() {
        var state = InquiryLifecycleState()
        state.recordStarted()
        XCTAssertTrue(state.recordDeviceFound(matchesPinned: true))
        XCTAssertNil(state.terminalDecision)
        XCTAssertTrue(state.recordCompletion(error: 0, aborted: true))
        XCTAssertEqual(state.terminalDecision, .succeededAfterPinnedMatch)
    }

    func testCompletionErrorBeforePinnedMatchFails() {
        var state = InquiryLifecycleState()
        XCTAssertTrue(state.recordCompletion(error: 1, aborted: false))
        XCTAssertEqual(state.terminalDecision, .failed(error: 1, aborted: false))
        XCTAssertFalse(state.pinnedMatchFound)
    }

    func testCompletionErrorAfterPinnedMatchAndStopDoesNotOverrideSuccess() {
        var state = InquiryLifecycleState()
        XCTAssertTrue(state.recordDeviceFound(matchesPinned: true))
        XCTAssertTrue(state.stopRequested)
        XCTAssertTrue(state.recordCompletion(error: 1, aborted: true))
        XCTAssertEqual(state.terminalDecision, .succeededAfterPinnedMatch)
    }

    func testDuplicateCallbacksProduceOnePinnedMatchAndOneTerminalDecision() {
        var state = InquiryLifecycleState()
        XCTAssertTrue(state.recordDeviceFound(matchesPinned: true))
        XCTAssertFalse(state.recordDeviceFound(matchesPinned: true))
        XCTAssertTrue(state.recordCompletion(error: 0, aborted: true))
        XCTAssertFalse(state.recordCompletion(error: 1, aborted: false))
        XCTAssertTrue(state.pinnedMatchFound)
        XCTAssertEqual(state.deviceFoundCallbackCount, 2)
        XCTAssertEqual(state.completionCallbackCount, 2)
        XCTAssertEqual(state.terminalDecision, .succeededAfterPinnedMatch)
    }
}
