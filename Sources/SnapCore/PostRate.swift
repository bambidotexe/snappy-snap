import Foundation

/// Every window write goes through `WindowWriter`'s per-window mailbox, which is the pacing — a post
/// to a busy window replaces the pending frame, and the worker's own write is the back-pressure. The
/// one decision left on the main thread is how often it computes and posts a target frame at all.
/// `PostRate` is that decision: pure arithmetic over a display's refresh rate and the user's
/// `Smoothness` choice, no clock of its own.
///
/// `Smoothness` is the aim rate: `smooth` aims at the display's own refresh rate; `adaptive`
/// ("Balanced" in Settings) and `battery` cap the aim at 60 and 30 posts a second respectively,
/// whatever the display can do. A display slower than a preset's cap is never exceeded.
public struct PostRate: Hashable, Sendable {
    /// Used when the display's refresh rate cannot be read.
    public static let fallbackRefreshRate: Double = 60

    /// Posts per second this preset aims for.
    public let rate: Double

    public init(refreshRate: Double, smoothness: Smoothness) {
        let effectiveRefreshRate = refreshRate > 0 ? refreshRate : Self.fallbackRefreshRate
        switch smoothness {
        case .smooth:
            rate = effectiveRefreshRate
        case .adaptive:
            rate = min(effectiveRefreshRate, 60)
        case .battery:
            rate = min(effectiveRefreshRate, 30)
        }
    }

    /// Target period between two posts.
    public var interval: Double { 1 / rate }

    /// True when a post is due: there has been none yet, or `interval` has elapsed since the last one.
    ///
    /// The `1e-6` tolerance absorbs the clock's own jitter, so a post landing a microsecond short of
    /// the interval is not held back an extra tick.
    public func shouldPost(now: Double, lastPost: Double?) -> Bool {
        guard let lastPost else { return true }
        return now - lastPost >= interval - 1e-6
    }
}
