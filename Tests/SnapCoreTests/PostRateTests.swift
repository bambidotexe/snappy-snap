import Testing
@testable import SnapCore

@Suite struct PostRateTests {
    @Test func smoothAimsAtTheDisplay() { #expect(PostRate(refreshRate: 120, smoothness: .smooth).rate == 120) }
    @Test func balancedCapsAtSixty() { #expect(PostRate(refreshRate: 120, smoothness: .adaptive).rate == 60) }
    @Test func batteryCapsAtThirty() { #expect(PostRate(refreshRate: 120, smoothness: .battery).rate == 30) }
    @Test func aSlowDisplayIsNeverExceeded() { #expect(PostRate(refreshRate: 48, smoothness: .adaptive).rate == 48) }
    @Test func zeroRefreshFallsBack() { #expect(PostRate(refreshRate: 0, smoothness: .smooth).rate == PostRate.fallbackRefreshRate) }
    @Test func firstPostIsAlwaysDue() { #expect(PostRate(refreshRate: 60, smoothness: .smooth).shouldPost(now: 10, lastPost: nil)) }
    @Test func aPostInsideTheIntervalIsNotDue() {
        let p = PostRate(refreshRate: 60, smoothness: .smooth)
        #expect(!p.shouldPost(now: 10.010, lastPost: 10))
        #expect(p.shouldPost(now: 10 + p.interval, lastPost: 10))
    }
}
