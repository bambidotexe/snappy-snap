import Foundation

/// When the app looks for a release without being asked: once shortly after launch, then a week after
/// the last check that got an answer, whoever asked. The app puts the question on a coarse tick and at
/// every wake rather than arming one week-long timer, so a Mac that sleeps through the date is asked
/// again as soon as it is awake. A check that could not reach GitHub is tried again at the first tick
/// an hour or more later.
/// Nothing of this is kept across launches, because every launch checks anyway. The four numbers are
/// `Settings.Fixed`'s.
public struct UpdateSchedule: Equatable, Sendable {
    public private(set) var lastAnswer: Date?
    public private(set) var lastFailure: Date?

    public init() {}

    public func isDue(now: Date) -> Bool {
        // A date ahead of `now` means the clock was set back: it holds nothing.
        if let lastFailure, lastFailure <= now,
           now.timeIntervalSince(lastFailure) < Settings.Fixed.updateRetryDelay { return false }
        guard let lastAnswer, lastAnswer <= now else { return true }
        return now.timeIntervalSince(lastAnswer) >= Settings.Fixed.updateInterval
    }

    /// GitHub answered, whatever the answer and whoever asked.
    public mutating func answered(at now: Date) {
        lastAnswer = now
        lastFailure = nil
    }

    public mutating func failed(at now: Date) { lastFailure = now }
}
