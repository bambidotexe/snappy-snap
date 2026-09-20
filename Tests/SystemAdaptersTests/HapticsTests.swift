import AppKit
import Testing
@testable import SystemAdapters

/// The actuator itself cannot be observed — AppKit will not say whether a tap was felt, or whether
/// there is hardware to feel it with — so what is pinned here is everything up to the hardware: that
/// the switch governs the call, and that the pattern is the light one.
@Suite @MainActor struct HapticsTests {
    /// Records what it was asked to play instead of playing it.
    private final class Spy: NSObject, NSHapticFeedbackPerformer {
        var played: [NSHapticFeedbackManager.FeedbackPattern] = []
        func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern,
                     performanceTime: NSHapticFeedbackManager.PerformanceTime) {
            played.append(pattern)
        }
    }

    @Test func theSwitchGovernsWhetherTheActuatorIsRungAtAll() {
        let spy = Spy()
        let haptics = Haptics(performer: spy)
        haptics.tap(enabled: false)
        #expect(spy.played.isEmpty, "a tap was performed with the setting off")
        haptics.tap(enabled: true)
        #expect(spy.played.count == 1)
    }

    /// `.alignment` is the pattern macOS plays when an alignment guide snaps: the lightest of the three,
    /// and what a window arriving at a zone is. `.levelChange` and `.generic` are both firmer.
    @Test func theTapIsTheAlignmentPattern() {
        let spy = Spy()
        Haptics(performer: spy).tap(enabled: true)
        #expect(spy.played == [.alignment])
    }

    /// One call, one tap. The bar arms more than once in a drag and each arming is its own tap, so a
    /// call that played twice would double every one of them.
    @Test func eachCallPlaysExactlyOneTap() {
        let spy = Spy()
        let haptics = Haptics(performer: spy)
        for _ in 0..<3 { haptics.tap(enabled: true) }
        #expect(spy.played.count == 3)
    }
}
