import Testing
@testable import SnapCore

@Suite struct IslandPresenceTests {
    func steps(_ from: IslandState, _ to: IslandState, interrupted: Bool = false) -> [IslandStep] {
        IslandPresence.steps(from: from, to: to, interrupted: interrupted)
    }

    @Test func arrivingIsADotThatBecomesACircleThatWidens() {
        #expect(steps(.hidden, .capsule) == [
            IslandStep(state: .circle, motion: .scaleIn, delay: 0),
            IslandStep(state: .capsule, motion: .widen, delay: 0.275),
        ])
        // Re-arriving while the capsule is still narrowing: only the widening is left to do.
        #expect(steps(.circle, .capsule) == [IslandStep(state: .capsule, motion: .widen, delay: 0)])
    }

    @Test func departingNarrowsToTheCircleThenScalesOut() {
        #expect(steps(.capsule, .hidden) == [
            IslandStep(state: .circle, motion: .narrow, delay: 0),
            IslandStep(state: .hidden, motion: .scaleOut, delay: 0.24),
        ])
        #expect(steps(.circle, .hidden) == [IslandStep(state: .hidden, motion: .scaleOut, delay: 0)])
    }

    @Test func expandingAndCollapsingAreOneSpringEach() {
        #expect(steps(.capsule, .expanded) == [IslandStep(state: .expanded, motion: .expand, delay: 0)])
        #expect(steps(.circle, .expanded) == [IslandStep(state: .expanded, motion: .expand, delay: 0)])
        #expect(steps(.expanded, .capsule) == [IslandStep(state: .capsule, motion: .collapse, delay: 0)])
        // A bar that arrives already summoned: the dot first, then straight to the grown shape.
        #expect(steps(.hidden, .expanded) == [
            IslandStep(state: .circle, motion: .scaleIn, delay: 0),
            IslandStep(state: .expanded, motion: .expand, delay: 0.275),
        ])
    }

    /// A drag that ends on an expanded island collapses it first; an interruption has no time for
    /// that and goes straight to the circle.
    @Test func anExpandedIslandCollapsesBeforeItDepartsUnlessInterrupted() {
        #expect(steps(.expanded, .hidden) == [
            IslandStep(state: .capsule, motion: .collapse, delay: 0),
            IslandStep(state: .circle, motion: .narrow, delay: 0.35),
            IslandStep(state: .hidden, motion: .scaleOut, delay: 0.35 + 0.24),
        ])
        #expect(steps(.expanded, .hidden, interrupted: true) == [
            IslandStep(state: .circle, motion: .narrow, delay: 0),
            IslandStep(state: .hidden, motion: .scaleOut, delay: 0.24),
        ])
        // An interruption changes nothing about a collapsed island's departure.
        #expect(steps(.capsule, .hidden, interrupted: true) == steps(.capsule, .hidden))
    }

    @Test func goingNowhereIsNoSteps() {
        for state in IslandState.allCases { #expect(steps(state, state).isEmpty) }
    }

    /// Every transition ends in the state that was asked for, and its delays never run backwards.
    @Test func everyTransitionEndsWhereItWasAskedTo() {
        for from in IslandState.allCases {
            for to in IslandState.allCases where from != to {
                for interrupted in [false, true] {
                    let all = steps(from, to, interrupted: interrupted)
                    #expect(all.last?.state == to)
                    #expect(all.map(\.delay) == all.map(\.delay).sorted())
                }
            }
        }
    }

    /// Only a spring that settles without crossing may run towards a shape that must not be passed:
    /// the narrowing must not dip under the circle, and the collapse must not dip under the capsule.
    @Test func theSpringsThatMustNotOvershootDoNot() {
        #expect(IslandMotion.narrow.spring.bounce <= 0)
        #expect(IslandMotion.collapse.spring.bounce <= 0)
        #expect(IslandMotion.scaleIn.spring.bounce > 0)
        #expect(IslandPresence.cellsFadeInDelay + IslandPresence.cellsFadeIn < IslandMotion.expand.spring.duration)
        #expect(IslandPresence.cellsFadeOut < IslandMotion.collapse.spring.duration)
    }

    /// A step never starts before the spring of the step before it has run its duration: the circle
    /// is a circle before it widens, the capsule is a capsule before it narrows.
    @Test func noStepStartsBeforeTheOneBeforeItHasSettled() {
        for from in IslandState.allCases {
            for to in IslandState.allCases where from != to {
                for interrupted in [false, true] {
                    let all = steps(from, to, interrupted: interrupted)
                    for (earlier, later) in zip(all, all.dropFirst()) {
                        #expect(later.delay >= earlier.delay + earlier.motion.spring.duration)
                    }
                }
            }
        }
    }
}
