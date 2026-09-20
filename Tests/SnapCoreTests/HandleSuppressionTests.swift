import Testing
@testable import SnapCore

/// Command takes away what has not been grabbed yet, and nothing else. The two ways this rule can be
/// wrong are leaving a handle on screen while Command is held — which is the whole feature failing to
/// happen — and dropping a drag already in flight, which loses a gesture the user is in the middle of.
@Suite struct HandleSuppressionTests {
    @Test func commandUpSuppressesNothing() {
        #expect(HandleSuppression.suppressed(commandDown: false, ownDragLive: false) == false)
        // Not even while a drag is live: a drag is not a reason to hide anything, it is the reason
        // everything else stands down.
        #expect(HandleSuppression.suppressed(commandDown: false, ownDragLive: true) == false)
    }

    @Test func commandDownSuppressesAnOffer() {
        #expect(HandleSuppression.suppressed(commandDown: true, ownDragLive: false) == true)
    }

    /// The boundary the feature is defined by. Command pressed in the middle of a divider drag is
    /// invisible: the previews keep following, the dim stays, and the release writes both windows.
    @Test func commandDownNeverSuppressesALiveDrag() {
        #expect(HandleSuppression.suppressed(commandDown: true, ownDragLive: true) == false)
    }
}
