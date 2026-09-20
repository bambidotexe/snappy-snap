import Testing
import ApplicationServices
import SnapCore
@testable import SystemAdapters

@Suite @MainActor struct AccessibilityWindowsTests {
    /// The only test that calls **through** the `@convention(c)` pointer, so it pins the switch on
    /// rather than inheriting it: `PrivateAPITests` moves `PrivateAPI.shared.isEnabled`, suites run in
    /// parallel, and without this the riskiest line in the file would have coverage that passes either
    /// way — including the way where the cast is never exercised at all.
    @Test func bogusElementHasNoWindowID() throws {
        let was = PrivateAPI.shared.isEnabled
        defer { PrivateAPI.shared.isEnabled = was }
        PrivateAPI.shared.isEnabled = true
        // `try #require`, not `#expect`: without the pointer the line below proves nothing, and a test
        // that quietly stops testing is worse than one that fails.
        try #require(PrivateAPI.shared.pointer(for: .axUIElementGetWindow) != nil)
        let ax = AccessibilityWindows()
        #expect(ax.windowID(of: AXUIElementCreateSystemWide()) == nil)
    }

    @Test func handlesCompareByElementIdentity() {
        let a = AXUIElementCreateApplication(1)
        let b = AXUIElementCreateApplication(1)
        #expect(WindowHandle(element: a, pid: 1, windowID: nil) == WindowHandle(element: b, pid: 1, windowID: nil))
        #expect(WindowHandle(element: a, pid: 1, windowID: nil).hashValue == WindowHandle(element: b, pid: 1, windowID: nil).hashValue)
    }
}

/// The public route for `_AXUIElementGetWindow`: with the private switch off, an AX window
/// is linked to its CoreGraphics id by pid and frame instead. The matching itself is pure arithmetic,
/// so every property of it is pinned here without Accessibility, without a window and without a
/// permission — which is the whole reason it was factored out of `windows(ofPid:)`.
@Suite struct MatchWindowIDsTests {
    private let pid: pid_t = 501

    private func listed(_ frames: [CGRect], pid: pid_t = 501, firstID: CGWindowID = 10) -> [WindowInfo] {
        frames.enumerated().map { index, frame in
            WindowInfo(id: firstID + CGWindowID(index), pid: pid, frame: frame, zIndex: index)
        }
    }

    @Test func distinctFramesFindTheirOwnEntryWhateverTheListOrder() {
        let a = CGRect(x: 0, y: 0, width: 400, height: 300)
        let b = CGRect(x: 500, y: 100, width: 200, height: 200)
        let c = CGRect(x: 800, y: 400, width: 640, height: 480)
        // The list is front to back and `kAXWindows` is front to back, but the two orders are not
        // guaranteed to agree — one app's third window can be the list's first. A distinct frame is
        // matched on its geometry alone, so the order does not decide anything here.
        let ids = AccessibilityWindows.matchWindowIDs(axFrames: [a, b, c], listed: listed([c, a, b]), pid: pid)
        #expect(ids == [11, 12, 10])
    }

    /// Two windows of one app at exactly the same frame cannot be told apart
    /// by geometry, so they are paired in order — the *n*th such AX window takes the *n*th such list
    /// entry. Both sequences are front to back, which is what makes that the best guess available.
    @Test func identicalFramesArePairedInListOrder() {
        let same = CGRect(x: 100, y: 100, width: 300, height: 300)
        let ids = AccessibilityWindows.matchWindowIDs(axFrames: [same, same, same],
                                                      listed: listed([same, same, same]), pid: pid)
        #expect(ids == [10, 11, 12])
    }

    /// No entry is handed out twice. Two AX windows over one list entry is not a hypothetical: an app
    /// window that is minimised, on another Space or below the list's floor is absent from the list
    /// while `kAXWindows` still reports it.
    @Test func anEntryIsClaimedOnce() {
        let same = CGRect(x: 100, y: 100, width: 300, height: 300)
        let ids = AccessibilityWindows.matchWindowIDs(axFrames: [same, same], listed: listed([same]), pid: pid)
        #expect(ids == [10, nil])
    }

    @Test func anAXFrameWithNoEntryWithinToleranceIsNil() {
        let onScreen = CGRect(x: 0, y: 0, width: 400, height: 300)
        let elsewhere = CGRect(x: 900, y: 900, width: 400, height: 300)
        let ids = AccessibilityWindows.matchWindowIDs(axFrames: [elsewhere, onScreen],
                                                      listed: listed([onScreen]), pid: pid)
        #expect(ids == [nil, 10])
    }

    /// One point of slack in every direction, and not a hair more. AX and CGWindowList agree exactly
    /// on this Mac; the tolerance is there for a window whose frame is written between the two reads,
    /// not to make two different windows interchangeable.
    @Test func toleranceIsOnePointOnEveryEdge() {
        let listed = listed([CGRect(x: 100, y: 100, width: 400, height: 300)])
        let nudged = CGRect(x: 101, y: 99, width: 401, height: 299)
        #expect(AccessibilityWindows.matchWindowIDs(axFrames: [nudged], listed: listed, pid: pid) == [10])
        let tooFar = CGRect(x: 100, y: 100, width: 400, height: 301.5)
        #expect(AccessibilityWindows.matchWindowIDs(axFrames: [tooFar], listed: listed, pid: pid) == [nil])
        #expect(AccessibilityWindows.matchWindowIDs(axFrames: [tooFar], listed: listed, pid: pid, tolerance: 2) == [10])
    }

    /// The closest unclaimed entry wins, not merely the first one inside the tolerance — otherwise an
    /// AX window a point away from its own entry could take the entry that matches another exactly.
    @Test func theClosestEntryWinsAndTiesGoToTheListOrder() {
        let exact = CGRect(x: 100, y: 100, width: 400, height: 300)
        let nudged = CGRect(x: 100.6, y: 100, width: 400, height: 300)
        let ids = AccessibilityWindows.matchWindowIDs(axFrames: [exact, nudged],
                                                      listed: listed([nudged, exact]), pid: pid)
        #expect(ids == [11, 10])
    }

    @Test func entriesOfAnotherProcessAreNeverMatched() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let other = listed([frame], pid: 999, firstID: 77)
        #expect(AccessibilityWindows.matchWindowIDs(axFrames: [frame], listed: other, pid: pid) == [nil])
        #expect(AccessibilityWindows.matchWindowIDs(axFrames: [frame], listed: other + listed([frame]), pid: pid) == [10])
    }

    /// `windows(ofPid:)` reads two attributes per window and passes `.null` for a window that answered
    /// neither. A frame nobody could read matches nothing — and, above all, does not throw the windows
    /// after it off by one.
    @Test func anUnreadableFrameMatchesNothingAndDoesNotShiftTheRest() {
        let a = CGRect(x: 0, y: 0, width: 400, height: 300)
        let b = CGRect(x: 500, y: 0, width: 400, height: 300)
        let ids = AccessibilityWindows.matchWindowIDs(axFrames: [a, .null, b], listed: listed([a, b]), pid: pid)
        #expect(ids == [10, nil, 11])
        #expect(AccessibilityWindows.matchWindowIDs(axFrames: [.infinite], listed: listed([a]), pid: pid) == [nil])
    }

    /// The one-element form `identify(_:pid:)` uses, which is the whole of the public route on the
    /// mouse-down path: the element is in hand, two reads gave its frame, and the only question left is
    /// which entry it is. Among entries that match equally well it must take the **frontmost**, because
    /// the element came from `AXUIElementCopyElementAtPosition` and that is the window the pointer is
    /// on.
    @Test func oneFrameTakesTheFrontmostOfTheEntriesThatMatchItEquallyWell() {
        let same = CGRect(x: 100, y: 100, width: 300, height: 300)
        // Front to back, so id 10 is the frontmost of the three.
        #expect(AccessibilityWindows.matchWindowID(axFrame: same, listed: listed([same, same, same]), pid: pid) == 10)
    }

    @Test func oneFrameAnswersNilWhenNothingMatchesIt() {
        let listed = listed([CGRect(x: 0, y: 0, width: 400, height: 300)])
        #expect(AccessibilityWindows.matchWindowID(axFrame: CGRect(x: 900, y: 900, width: 400, height: 300),
                                                   listed: listed, pid: pid) == nil)
        #expect(AccessibilityWindows.matchWindowID(axFrame: .null, listed: listed, pid: pid) == nil)
        #expect(AccessibilityWindows.matchWindowID(axFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
                                                   listed: [], pid: pid) == nil)
    }

    /// The single form is the plural one, not a second algorithm — tolerance, the pid filter and the
    /// closest-first rule must all behave identically or the two routes could disagree about the same
    /// window.
    @Test func theOneFrameFormIsTheManyFrameFormOnAListOfOne() {
        let frames = [CGRect(x: 100, y: 100, width: 400, height: 300),
                      CGRect(x: 100.6, y: 100, width: 400, height: 300),
                      CGRect(x: 900, y: 900, width: 10, height: 10)]
        let entries = listed(frames)
        for frame in frames + [CGRect(x: 100, y: 100, width: 400, height: 301.5)] {
            for tolerance in [0.0, 1.0, 2.0] {
                #expect(AccessibilityWindows.matchWindowID(axFrame: frame, listed: entries, pid: pid, tolerance: tolerance)
                    == AccessibilityWindows.matchWindowIDs(axFrames: [frame], listed: entries, pid: pid, tolerance: tolerance)[0])
            }
        }
        #expect(AccessibilityWindows.matchWindowID(axFrame: frames[0], listed: entries, pid: 999) == nil)
    }

    @Test func theAnswerHasOneEntryPerAXWindowEvenWithNothingToMatchAgainst() {
        let frames = [CGRect(x: 0, y: 0, width: 400, height: 300), CGRect(x: 1, y: 1, width: 2, height: 2)]
        #expect(AccessibilityWindows.matchWindowIDs(axFrames: frames, listed: [], pid: pid) == [nil, nil])
        #expect(AccessibilityWindows.matchWindowIDs(axFrames: [], listed: listed(frames), pid: pid).isEmpty)
    }
}
