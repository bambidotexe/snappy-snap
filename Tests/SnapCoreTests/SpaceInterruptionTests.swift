import CoreGraphics
import Foundation
import Testing
@testable import SnapCore

/// Every window list in here is a **measured** one: taken from CGWindowList on this Mac with
/// Mission Control, App Exposé, a Space change and an idle desktop on screen, and with the
/// geometry of the display they were measured on. The point of the suite is that the rule tells
/// those four apart, so made-up numbers would test nothing.
@Suite struct MissionControlDetectorTests {
    /// The display they were all measured on.
    static let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    /// The WindowManager process pid, as measured.
    static let wm: Int32 = 644

    func win(_ pid: Int32, _ layer: Int, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> SystemWindow {
        SystemWindow(ownerPID: pid, layer: layer, frame: CGRect(x: x, y: y, width: w, height: h))
    }

    /// What is on screen when nothing of the system's is: the wallpaper and Stage Manager's strip from
    /// WindowManager at large negative layers, one app's floating window at layer 1000, the Dock at 20,
    /// the menu bar from the window server at 24, and this app's own overlay at 25 and up.
    var idle: [SystemWindow] {
        [win(Self.wm, -2_147_483_624, 0, 0, 1512, 982),   // WindowManager, below everything
         win(922, 1000, 0, 0, 1512, 982),                  // another app, full screen, high layer
         win(675, 20, 0, 0, 1512, 982),                    // Dock
         win(424, 24, 0, 0, 1512, 33),                     // window server's menu bar
         win(1001, 0, 100, 500, 676, 380),                 // an ordinary window
         win(1002, 0, 760, 41, 744, 874)]
    }

    func isShowing(_ windows: [SystemWindow], displays: [CGRect] = [MissionControlDetectorTests.display]) -> Bool {
        MissionControlDetector.backdrop(in: windows, windowManagerPID: Self.wm, displays: displays) != nil
    }

    @Test func idleDesktopIsNotMissionControl() {
        #expect(isShowing(idle) == false)
    }

    /// Measured: a backdrop over the whole display at layer 19, the Spaces bar at 14, one thumbnail per
    /// Space at 15 — and the user's own windows still at layer 0, scaled down to thumbnails.
    @Test func missionControlIsRecognised() {
        let windows = idle + [
            win(Self.wm, 19, 0, 0, 1512, 982),
            win(Self.wm, 14, 0, 0, 1512, 244),
            win(Self.wm, 15, 330, 55, 169, 129),
            win(Self.wm, 15, 500, 55, 169, 129),
            win(Self.wm, 15, 670, 55, 169, 129),
        ]
        #expect(isShowing(windows))
    }

    /// Measured: App Exposé puts up the same backdrop and nothing else above layer 0. It is the same
    /// kind of interruption — the overlays float over it just as they do over Mission Control — so it
    /// is deliberately recognised by the same rule rather than excluded from it.
    @Test func appExposeIsRecognised() {
        #expect(isShowing(idle + [win(Self.wm, 19, 0, 0, 1512, 982)]))
    }

    /// Measured: a Space change puts **nothing** of WindowManager's above layer 0, at any moment of the
    /// slide. It is `NSWorkspace`'s to report, and this must not double-report it.
    @Test func aSpaceChangeShowsNothingHere() {
        // Mid-slide both Spaces' windows are on screen at once; none of them is the system's.
        let windows = idle + [win(1003, 0, 1512, 500, 676, 380), win(1004, 0, 2000, 41, 744, 874)]
        #expect(isShowing(windows) == false)
    }

    /// The protection that matters most: a drag to the very top edge can reveal the Spaces bar on its
    /// own, and the top edge is this app's maximize zone. The strip is WindowManager's, above layer 0,
    /// and as wide as the display — everything but tall enough — so only the coverage test keeps the
    /// user's maximize alive.
    @Test func theSpacesBarAloneIsNotMissionControl() {
        #expect(isShowing(idle + [win(Self.wm, 14, 0, 0, 1512, 244)]) == false)
    }

    /// Stage Manager's strip is WindowManager's too, and covers the display, and is not this.
    @Test func aWindowManagerSurfaceBelowLayerZeroIsNotMissionControl() {
        #expect(isShowing(idle + [win(Self.wm, 0, 0, 0, 1512, 982)]) == false)
        #expect(isShowing(idle + [win(Self.wm, -2_147_483_625, 0, 0, 1512, 982)]) == false)
    }

    /// Another application's full-screen window, however high it sits. `idle` already carries one at
    /// layer 1000; this is the same fact stated where it can be read.
    @Test func anotherProcessFullScreenWindowIsNotMissionControl() {
        #expect(isShowing([win(922, 1000, 0, 0, 1512, 982)]) == false)
    }

    /// Mission Control on the *other* display of two. The backdrop only has to cover one of them.
    @Test func recognisedOnAnyDisplay() {
        let second = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let windows = idle + [win(Self.wm, 19, 1512, 0, 1920, 1080)]
        #expect(isShowing(windows, displays: [Self.display, second]))
        // …and the same window is nothing at all if that display is not there.
        #expect(isShowing(windows, displays: [Self.display]) == false)
    }

    /// No displays, no backdrop — a reading of *false*, never a reading of "unknown, assume
    /// yes". It falls out of the per-display loop rather than out of a guard of its own; what is
    /// pinned is the answer, which an implementation that special-cased the empty list could
    /// still get wrong.
    @Test func noDisplaysMeansNoAnswer() {
        #expect(isShowing(idle + [win(Self.wm, 19, 0, 0, 1512, 982)], displays: []) == false)
    }

    /// The coverage threshold from both sides, on width and on height, so neither test can be dropped
    /// without a failure.
    @Test func coverageBoundary() {
        let d = Self.display
        let w = d.width * MissionControlDetector.coverage
        let h = d.height * MissionControlDetector.coverage
        #expect(MissionControlDetector.covers(d, CGRect(x: 0, y: 0, width: w, height: h)))
        #expect(MissionControlDetector.covers(d, CGRect(x: 0, y: 0, width: w - 1, height: h)) == false)
        #expect(MissionControlDetector.covers(d, CGRect(x: 0, y: 0, width: w, height: h - 1)) == false)
        #expect(MissionControlDetector.covers(d, CGRect(x: 0, y: 0, width: 1512, height: 982)))
    }

    /// Coverage is of the *overlap*, not of the window: a display-sized surface half off the display
    /// covers half of it. Testing the window's own size instead would call a backdrop on a neighbouring
    /// display this display's.
    @Test func coverageIsMeasuredAgainstTheOverlap() {
        let d = Self.display
        #expect(MissionControlDetector.covers(d, CGRect(x: 756, y: 0, width: 1512, height: 982)) == false)
        #expect(MissionControlDetector.covers(d, CGRect(x: -3000, y: 0, width: 1512, height: 982)) == false)
    }

    @Test func aDegenerateDisplayIsNotCoveredByAnything() {
        #expect(MissionControlDetector.covers(CGRect(x: 0, y: 0, width: 0, height: 0), Self.display) == false)
    }
}

@Suite struct MissionControlGateTests {
    /// `#expect(gate.update(…))` will not compile — the macro captures the value immutably — so every
    /// reading is taken into a `let` first. That is not a workaround: it also names what each pass
    /// returned, which is the thing under test.
    @Test func firstSightIsTheOnlyOne() {
        var gate = MissionControlGate()
        #expect(gate.isShowing == false)
        let first = gate.update(showing: true, now: 0)
        #expect(first)
        #expect(gate.isShowing)
        // Nine more passes of the same poll, and not one of them ends a phase a second time.
        for _ in 0..<9 {
            let again = gate.update(showing: true, now: 0)
            #expect(again == false)
        }
        #expect(gate.isShowing)
    }

    @Test func itRisesAgainAfterItFalls() {
        var gate = MissionControlGate()
        let first = gate.update(showing: true, now: 0)
        #expect(first)
        let fell = gate.update(showing: false, now: 0)
        #expect(fell == false)
        #expect(gate.isShowing == false)
        let second = gate.update(showing: true, now: 0)
        #expect(second)
    }

    @Test func falseAloneNeverInterrupts() {
        var gate = MissionControlGate()
        for _ in 0..<5 {
            let quiet = gate.update(showing: false, now: 0)
            #expect(quiet == false)
        }
        #expect(gate.isShowing == false)
    }

    /// `forget` is for the watcher that stops looking: what it last saw must not go on standing the
    /// handle bar down, and the next thing it sees is a first sight again.
    @Test func forgetReArmsIt() {
        var gate = MissionControlGate()
        let first = gate.update(showing: true, now: 0)
        #expect(first)
        gate.forget()
        #expect(gate.isShowing == false)
        let second = gate.update(showing: true, now: 0)
        #expect(second)
    }
}

/// The two facts a drag suspended by a Space change has to satisfy before it comes back. Each one
/// answers a different way of getting the resumption wrong, so every test here holds one of them and
/// varies the other: satisfying one alone must never be enough.
@Suite struct DragResumptionTests {
    static let settle = Settings.Fixed.dragResumeSettle
    static let minimum = Settings.Fixed.dragResumeTravel
    static let origin = CGPoint(x: 400, y: 300)

    func mayResume(after elapsed: TimeInterval, movedTo pointer: CGPoint) -> Bool {
        DragResumption.mayResume(elapsed: elapsed,
                                 travel: DragResumption.travel(from: Self.origin, to: pointer))
    }

    func offset(_ dx: Double, _ dy: Double) -> CGPoint {
        CGPoint(x: Self.origin.x + dx, y: Self.origin.y + dy)
    }

    /// The whole point of the settle: the slide is still running, and the window list read the
    /// resumption depends on would describe the Space being left.
    @Test func aWideMoveDuringTheSlideDoesNotResume() {
        #expect(mayResume(after: 0, movedTo: offset(300, 0)) == false)
        #expect(mayResume(after: Self.settle - 0.001, movedTo: offset(300, 0)) == false)
    }

    /// The whole point of the travel: the pointer is resting against the edge that triggered the
    /// slide, so waiting alone must not light that edge's zone under a motionless hand.
    @Test func aMotionlessPointerNeverResumesHoweverLongItWaits() {
        #expect(mayResume(after: Self.settle, movedTo: Self.origin) == false)
        #expect(mayResume(after: 60, movedTo: Self.origin) == false)
        #expect(mayResume(after: 60, movedTo: offset(Self.minimum - 0.001, 0)) == false)
    }

    /// Both boundaries are inclusive, and both are tested from either side so neither comparison can
    /// be loosened without a failure.
    @Test func bothBoundariesAreInclusive() {
        #expect(mayResume(after: Self.settle, movedTo: offset(Self.minimum, 0)))
        #expect(mayResume(after: Self.settle - 0.001, movedTo: offset(Self.minimum, 0)) == false)
        #expect(mayResume(after: Self.settle, movedTo: offset(Self.minimum - 0.001, 0)) == false)
    }

    /// Travel is the straight line between the two points, not the larger axis and not the sum of
    /// both. A diagonal nudge of 6 pt on each axis is 8.49 pt and resumes, though neither axis
    /// reaches the minimum on its own; one of 5 pt on each axis is 7.07 pt and does not, though the
    /// two axes add to 10.
    @Test func travelIsTheStraightLine() {
        #expect(DragResumption.travel(from: Self.origin, to: offset(3, 4)) == 5)
        #expect(mayResume(after: Self.settle, movedTo: offset(6, 6)))
        #expect(mayResume(after: Self.settle, movedTo: offset(5, 5)) == false)
    }

    /// Distance, not displacement: a pointer dragged back towards the middle of the screen has moved
    /// exactly as far as one pushed further into the edge, and the user aimed with both.
    @Test func travelHasNoDirection() {
        let out = DragResumption.travel(from: Self.origin, to: offset(Self.minimum, 0))
        let back = DragResumption.travel(from: Self.origin, to: offset(-Self.minimum, 0))
        let up = DragResumption.travel(from: Self.origin, to: offset(0, -Self.minimum))
        #expect(out == Self.minimum)
        #expect(back == Self.minimum)
        #expect(up == Self.minimum)
    }

    /// A pointer that wanders out past the minimum and comes back under it is not resumed by having
    /// once been far away: the rule is asked fresh on every drag event, against the same origin.
    @Test func comingBackInsideTheMinimumStopsResuming() {
        #expect(mayResume(after: Self.settle, movedTo: offset(40, 0)))
        #expect(mayResume(after: Self.settle, movedTo: offset(2, 0)) == false)
    }

    /// The defaults are the two constants and nothing else, so a change to either is a change to
    /// this rule rather than to one call site.
    @Test func theDefaultsAreTheFixedConstants() {
        #expect(DragResumption.mayResume(elapsed: Settings.Fixed.dragResumeSettle,
                                         travel: Settings.Fixed.dragResumeTravel))
        #expect(DragResumption.mayResume(elapsed: 10, travel: 100, settle: 20, minimumTravel: 8) == false)
        #expect(DragResumption.mayResume(elapsed: 10, travel: 100, settle: 1, minimumTravel: 200) == false)
        #expect(DragResumption.mayResume(elapsed: 10, travel: 100, settle: 1, minimumTravel: 2))
    }
}
