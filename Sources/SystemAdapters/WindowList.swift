import AppKit
import CoreGraphics
import SnapCore

/// On-screen windows of regular apps, front to back, from CGWindowList. Needs no permission.
public enum WindowList {
    /// Every on-screen window the window server lists, front to back, wallpaper elements excluded.
    private static func onScreen() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    }

    public static func snapshot(excludingPID excluded: pid_t = ProcessInfo.processInfo.processIdentifier) -> [WindowInfo] {
        snapshotWithCoverers(excludingPID: excluded).windows
    }

    /// `snapshot`, and beside it the windows that take no part in anything and can still **sit on top
    /// of a handle**: a floating panel, a menu-bar application's window (`CoveringSurface` is the
    /// rule). One copy of the window list serves both, and a coverer's `zIndex` places it among the
    /// snapshot's windows — `CoveringSurface.zIndex` — so "in front of" is one comparison for both.
    public static func snapshotWithCoverers(excludingPID excluded: pid_t = ProcessInfo.processInfo.processIdentifier)
        -> (windows: [WindowInfo], coverers: [WindowInfo]) {
        let raw = onScreen()
        let dockLayer = Int(CGWindowLevelForKey(.dockWindow))
        var regularByPID: [pid_t: Bool] = [:]
        func isRegularApp(_ pid: pid_t) -> Bool {
            if let cached = regularByPID[pid] { return cached }
            let regular = NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
            regularByPID[pid] = regular
            return regular
        }

        var result: [WindowInfo] = []
        var coverers: [WindowInfo] = []
        for info in raw {
            guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != excluded,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0 else { continue }
            if layer == 0, bounds.width >= 50, bounds.height >= 50, isRegularApp(pid) {
                result.append(WindowInfo(id: id, pid: pid, frame: bounds, zIndex: result.count))
            } else if CoveringSurface.covers(layer: layer, dockLayer: dockLayer) {
                coverers.append(WindowInfo(id: id, pid: pid, frame: bounds,
                                           zIndex: CoveringSurface.zIndex(participantsInFront: result.count)))
            }
        }
        return (result, coverers)
    }

    /// Every on-screen window with its owner, level and bounds, and no filtering whatsoever —
    /// `MissionControlDetector`'s input. Needs no permission either: the owner *pid* and the bounds
    /// are public, and the window **name**, which would need Screen Recording, is never read here any
    /// more than it is in `snapshot`.
    ///
    /// Separate from `snapshot` because it is the complement of it. That one answers "which windows
    /// could the user snap": layer 0, regular applications, at least 50 pt a side. The surfaces
    /// Mission Control puts up fail every one of those tests, which is exactly what makes them
    /// recognisable.
    ///
    /// `.excludeDesktopElements` is kept: measured, it leaves all seven of Mission Control's own
    /// windows in the list and takes the wallpaper windows out — 18 entries instead of 25 for the same
    /// reading, at 0.2–0.3 ms a call.
    public static func onScreenSurfaces() -> [SystemWindow] {
        let raw = onScreen()
        return raw.compactMap { info in
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            return SystemWindow(ownerPID: pid, layer: layer, frame: bounds)
        }
    }

    /// Every on-screen window's **number and bounds**, in CG space — `SpaceSlideDetector`'s input. No
    /// owner, no name, no filtering: the one question asked of it is whether a sentinel this app
    /// placed is still where it put it, and the answer is an id and an origin.
    ///
    /// `.excludeDesktopElements` is kept for the reason `onScreenSurfaces` keeps it — it takes the
    /// wallpaper windows out and leaves everything an application or this app owns in, for 0.2–0.3 ms
    /// a call. A window that is not listed at all is a valid answer here and means "not on the Space
    /// the window server is showing".
    public static func onScreenIDsAndFrames() -> [(id: UInt32, frame: CGRect)] {
        let raw = onScreen()
        return raw.compactMap { info in
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            return (id: id, frame: bounds)
        }
    }
}
