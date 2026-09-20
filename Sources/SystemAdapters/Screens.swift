import AppKit
import SnapCore

@MainActor
public protocol ScreensProviding: AnyObject {
    var displays: [DisplayInfo] { get }
    func display(containing point: CGPoint) -> DisplayInfo?
    func sharedEdges(of display: DisplayInfo) -> Set<Edge>
    var onChange: (@MainActor () -> Void)? { get set }
}

/// Displays in CG space, refreshed when the screen configuration changes.
@MainActor
public final class Screens: ScreensProviding {
    public private(set) var displays: [DisplayInfo] = []
    public var onChange: (@MainActor () -> Void)?
    private var observer: (any NSObjectProtocol)?

    public init() {
        reload()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reload()
                self?.onChange?()
            }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    public func reload() {
        let h = CoordinateSpace.primaryHeight
        displays = NSScreen.screens.map { screen in
            DisplayInfo(
                id: screen.displayID,
                frame: CoordinateSpace.cgRect(fromCocoa: screen.frame, primaryHeight: h),
                visibleFrame: CoordinateSpace.cgRect(fromCocoa: screen.visibleFrame, primaryHeight: h),
                notch: Self.notch(of: screen, primaryHeight: h),
                name: screen.localizedName,
                isBuiltIn: screen.isBuiltIn
            )
        }
    }

    /// The camera housing, or nil on a display without one. AppKit does not name the housing; it names
    /// the two strips of menu bar either side of it, and the housing is what lies between them, as
    /// tall as the safe area's top inset. Measured on the built-in 1512 × 982 display: the left strip
    /// ends at 663.5, the right one starts at 848.5, the inset is 32 — a housing of 185 × 32.
    private static func notch(of screen: NSScreen, primaryHeight: CGFloat) -> CGRect? {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
              right.minX > left.maxX else { return nil }
        let height = screen.safeAreaInsets.top
        let cocoa = CGRect(x: left.maxX, y: screen.frame.maxY - height, width: right.minX - left.maxX, height: height)
        return CoordinateSpace.cgRect(fromCocoa: cocoa, primaryHeight: primaryHeight)
    }

    public func display(containing point: CGPoint) -> DisplayInfo? {
        if let hit = displays.first(where: { $0.frame.contains(point) }) { return hit }
        return displays.min { squaredDistance($0.frame, point) < squaredDistance($1.frame, point) }
    }

    public func sharedEdges(of display: DisplayInfo) -> Set<Edge> {
        display.sharedEdges(among: displays)
    }

    private func squaredDistance(_ r: CGRect, _ p: CGPoint) -> Double {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }
}

extension NSScreen {
    public var displayID: UInt32 {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Whether macOS says this is the machine's own panel, as opposed to an attached monitor.
    public var isBuiltIn: Bool {
        CGDisplayIsBuiltin(displayID) != 0
    }
}
