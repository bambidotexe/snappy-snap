import CoreGraphics

/// Remembers which windows we snapped and where they were before.
/// An entry is only valid while the window still sits (±2 pt) where we left it.
public struct SnapRegistry: Hashable, Sendable {
    public struct Entry: Hashable, Sendable {
        public var preSnapFrame: CGRect
        public var snappedFrame: CGRect
        public var zone: Zone
    }

    public static let tolerance: Double = 2
    private var entries: [UInt32: Entry] = [:]

    public init() {}

    /// Records a snap. When the window was already validly snapped, its original pre-snap frame is
    /// preserved so that unsnapping returns to where the user started, not to the previous zone.
    public mutating func record(windowID: UInt32, currentFrame: CGRect, snappedFrame: CGRect, zone: Zone) {
        let pre = entry(for: windowID, currentFrame: currentFrame)?.preSnapFrame ?? currentFrame
        entries[windowID] = Entry(preSnapFrame: pre, snappedFrame: snappedFrame, zone: zone)
    }

    /// The entry exactly as it was recorded, **whatever the window has done since**.
    ///
    /// A different question from `entry(for:currentFrame:)`, which asks "may this window be restored to
    /// where it was before we snapped it" and answers no as soon as the window has moved a hair. This
    /// one asks "did we put this window where it is", and the window it most wants to say yes to is one
    /// the user has since resized along its divider. Where the window is now comes from the window
    /// list; `NeighbourEvidence` is what decides whether it still stands as a tiled window does.
    public func recordedEntry(for windowID: UInt32) -> Entry? {
        entries[windowID]
    }

    public func entry(for windowID: UInt32, currentFrame: CGRect) -> Entry? {
        guard let e = entries[windowID],
              e.snappedFrame.isApproximatelyEqual(to: currentFrame, tolerance: Self.tolerance) else { return nil }
        return e
    }

    public mutating func remove(_ windowID: UInt32) {
        entries[windowID] = nil
    }
}
