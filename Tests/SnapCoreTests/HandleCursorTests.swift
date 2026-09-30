import Testing
@testable import SnapCore

@Suite struct HandleCursorTests {
    private let handle = 61347
    private let beneath = 61346
    private let menu = 61348

    @Test func theHandleOnTopIsNotCovered() {
        #expect(!HandleCursor.isCovered(topmost: handle, belowHandle: beneath, handle: handle))
    }

    // The measured case: a menu at level 101 over the handle's band.
    @Test func aWindowInFrontOfTheHandleCoversIt() {
        #expect(HandleCursor.isCovered(topmost: menu, belowHandle: beneath, handle: handle))
    }

    // Measured: at alpha 0, and at 0.02, a click passes through the handle to the window beneath it.
    // A handle fading in is not a covered one.
    @Test func aHandleTheHitTestSkipsIsNotCoveredByWhatIsUnderIt() {
        #expect(!HandleCursor.isCovered(topmost: beneath, belowHandle: beneath, handle: handle))
    }

    @Test func theCursorGoesBackToWhatIsUnderTheHandle() {
        #expect(HandleCursor.windowUnderPointer(topmost: handle, belowHandle: beneath, handle: handle) == beneath)
        #expect(HandleCursor.windowUnderPointer(topmost: menu, belowHandle: beneath, handle: handle) == menu)
    }

    @Test func theFrontmostAppKeepsItsOwnCursor() {
        #expect(!HandleCursor.handsBackArrow(ownerPID: 500, frontmostPID: 500))
    }

    // The measured case: Slack's window while Terminal is frontmost kept the resize glyph.
    @Test func anyOtherAppGetsTheArrow() {
        #expect(HandleCursor.handsBackArrow(ownerPID: 945, frontmostPID: 500))
        #expect(HandleCursor.handsBackArrow(ownerPID: 945, frontmostPID: nil))
    }

    @Test func noWindowAtAllGetsTheArrow() {
        #expect(HandleCursor.handsBackArrow(ownerPID: nil, frontmostPID: 500))
    }
}
