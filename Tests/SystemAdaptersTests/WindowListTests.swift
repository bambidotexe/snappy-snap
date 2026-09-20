import Testing
import Foundation
@testable import SystemAdapters

@Suite struct WindowListTests {
    @Test func snapshotExcludesOurselvesAndOrdersFrontToBack() {
        let own = ProcessInfo.processInfo.processIdentifier
        let windows = WindowList.snapshot(excludingPID: own)
        #expect(windows.allSatisfy { $0.pid != own })
        #expect(windows.map(\.zIndex) == Array(windows.indices))
        #expect(windows.allSatisfy { $0.frame.width >= 50 && $0.frame.height >= 50 })
    }

    /// This reading is the complement of `snapshot`'s: the same list before any of those filters,
    /// so that `MissionControlDetector` can see the layers `snapshot` exists to throw away.
    ///
    /// The assertion is containment rather than a count. A count is guaranteed by construction —
    /// same CGWindowList options, strictly fewer filters — so it discriminates nothing, and it is
    /// racy the other way if a window opens between the two calls. Containment can actually fail: it
    /// does the moment the two disagree about a pid or a frame, which is how a mis-mapped field would
    /// show up. Windows that come or go between the calls are allowed for by matching one way only.
    @Test func onScreenSurfacesKeepsWhatSnapshotFiltersOut() {
        let surfaces = WindowList.onScreenSurfaces()
        #expect(surfaces.allSatisfy { $0.ownerPID > 0 })
        let ours = ProcessInfo.processInfo.processIdentifier
        for window in WindowList.snapshot(excludingPID: ours) {
            #expect(surfaces.contains { $0.ownerPID == window.pid && $0.frame == window.frame },
                    "a window snapshot() kept is missing from the unfiltered list")
        }
        // The layer is the field this reading exists for, and `snapshot` can never check it: it keeps
        // layer 0 only. Anything on screen at all on a Mac with a window server puts the Dock or the
        // menu bar above 0 — and on a machine with nothing on screen there is nothing to assert.
        #expect(surfaces.isEmpty || surfaces.contains { $0.layer > 0 })
    }
}
