import Testing
import CoreGraphics
@testable import SnapCore

@Suite struct SnapRegistryTests {
    let display = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 625),
                              visibleFrame: CGRect(x: 0, y: 25, width: 1000, height: 600))
    var leftZone: Zone { Geometry.zone(display: display, layout: LayoutCatalog.halves, cellIndex: 0, gap: 8) }
    var rightZone: Zone { Geometry.zone(display: display, layout: LayoutCatalog.halves, cellIndex: 1, gap: 8) }
    let original = CGRect(x: 100, y: 100, width: 640, height: 480)

    @Test func recordAndFetchWhileFrameMatches() {
        var r = SnapRegistry()
        r.record(windowID: 42, currentFrame: original, snappedFrame: leftZone.frame, zone: leftZone)
        let e = r.entry(for: 42, currentFrame: leftZone.frame)
        #expect(e?.preSnapFrame == original)
        #expect(e?.snappedFrame == leftZone.frame)
        #expect(e?.zone == leftZone)
    }

    @Test func toleratesTwoPointsButNotThree() {
        var r = SnapRegistry()
        r.record(windowID: 42, currentFrame: original, snappedFrame: leftZone.frame, zone: leftZone)
        #expect(r.entry(for: 42, currentFrame: leftZone.frame.offsetBy(dx: 2, dy: -2)) != nil)
        #expect(r.entry(for: 42, currentFrame: leftZone.frame.offsetBy(dx: 3, dy: 0)) == nil)
        #expect(r.entry(for: 42, currentFrame: leftZone.frame.insetBy(dx: 0, dy: 2)) == nil) // height off by 4
    }

    /// The Health page's count: a window on screen still (±2 pt) where a snap left it. One that moved and
    /// one that is gone are not counted.
    @Test func countsOnlyWindowsStillWhereASnapLeftThem() {
        var r = SnapRegistry()
        r.record(windowID: 1, currentFrame: original, snappedFrame: leftZone.frame, zone: leftZone)
        r.record(windowID: 2, currentFrame: original, snappedFrame: rightZone.frame, zone: rightZone)
        r.record(windowID: 3, currentFrame: original, snappedFrame: rightZone.frame, zone: rightZone)
        let frames: [UInt32: CGRect] = [1: leftZone.frame.offsetBy(dx: 1, dy: 1),
                                        2: rightZone.frame.offsetBy(dx: 40, dy: 0),
                                        9: leftZone.frame]
        #expect(r.stillSnapped(among: frames) == 1)
        #expect(SnapRegistry().stillSnapped(among: frames) == 0)
    }

    @Test func reSnappingKeepsTheOriginalPreSnapFrame() {
        var r = SnapRegistry()
        r.record(windowID: 42, currentFrame: original, snappedFrame: leftZone.frame, zone: leftZone)
        r.record(windowID: 42, currentFrame: leftZone.frame, snappedFrame: rightZone.frame, zone: rightZone)
        let e = r.entry(for: 42, currentFrame: rightZone.frame)
        #expect(e?.preSnapFrame == original)
        #expect(e?.zone == rightZone)
    }

    @Test func manualMoveInvalidatesAndNewSnapStartsFresh() {
        var r = SnapRegistry()
        r.record(windowID: 42, currentFrame: original, snappedFrame: leftZone.frame, zone: leftZone)
        let moved = leftZone.frame.offsetBy(dx: 40, dy: 0)
        #expect(r.entry(for: 42, currentFrame: moved) == nil)
        r.record(windowID: 42, currentFrame: moved, snappedFrame: rightZone.frame, zone: rightZone)
        #expect(r.entry(for: 42, currentFrame: rightZone.frame)?.preSnapFrame == moved)
    }

    @Test func removeForgetsOneWindowAndKeepsTheOthers() {
        var r = SnapRegistry()
        r.record(windowID: 1, currentFrame: original, snappedFrame: leftZone.frame, zone: leftZone)
        r.record(windowID: 2, currentFrame: original, snappedFrame: rightZone.frame, zone: rightZone)
        r.remove(1)
        #expect(r.entry(for: 1, currentFrame: leftZone.frame) == nil)
        #expect(r.recordedEntry(for: 1) == nil)
        #expect(r.entry(for: 2, currentFrame: rightZone.frame) != nil)
    }
}
