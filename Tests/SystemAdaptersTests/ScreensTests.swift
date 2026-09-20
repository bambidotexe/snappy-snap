import Testing
import AppKit
@testable import SystemAdapters
import SnapCore

@Suite @MainActor struct ScreensTests {
    /// `NSScreen.screens` is the machine's, not the test's: it is empty on a headless runner, where a
    /// subscript traps and takes the target down with no issue line and no summary line for it.
    /// `try #require` aborts this one test and lets the rest of the suite report.
    @Test func reportsAtLeastThePrimaryDisplayInCGSpace() throws {
        let screens = Screens()
        #expect(!screens.displays.isEmpty)
        let primary = try #require(screens.displays.first)
        #expect(primary.frame.origin == .zero)               // primary display is at the CG origin
        #expect(primary.visibleFrame.minY >= primary.frame.minY) // menu bar pushes the working area down
        #expect(primary.frame.contains(primary.visibleFrame))
    }

    @Test func findsTheDisplayUnderAPoint() throws {
        let screens = Screens()
        let primary = try #require(screens.displays.first)
        #expect(screens.display(containing: primary.frame.center) == primary)
        // A point just past the right edge still resolves to the nearest display.
        #expect(screens.display(containing: CGPoint(x: primary.frame.maxX + 0.5, y: primary.frame.midY)) != nil)
    }

    @Test func sharedEdgesDelegateToTheModel() {
        let screens = Screens()
        for d in screens.displays {
            #expect(screens.sharedEdges(of: d) == d.sharedEdges(among: screens.displays))
        }
    }
}
