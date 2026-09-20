import Testing
@testable import SnapCore

/// The watchdog must cancel on evidence the mouse-up is *lost*, never merely on a button that
/// has come up. Every case here is one of the two ways it can be wrong — orphaning an ordinary
/// release, or failing to catch a genuinely lost one.
@Suite struct OrphanDetectorTests {
    /// One poll, 100 ms apart, on a clock that is not near zero (`CACurrentMediaTime` is time since
    /// boot, and a rule that only works near the origin would be a trap).
    let tick: Double = 0.1
    let now: Double = 105_531.4

    @Test func aButtonThatIsStillDownNeverCancels() {
        // However long the stream has been silent: a press held motionless is a press held.
        #expect(OrphanDetector.shouldCancel(buttonUp: false, ticksUp: 0,
                                            lastEventAt: now - 10, now: now, quietFor: tick) == false)
        // And the count cannot survive a down reading, because the caller resets it — but even if it
        // leaked through, the button is the first test.
        #expect(OrphanDetector.shouldCancel(buttonUp: false, ticksUp: 9,
                                            lastEventAt: now - 10, now: now, quietFor: tick) == false)
    }

    /// The physical-release race: the button bit flips milliseconds before the tap delivers `.up`, and
    /// the timer fires before the mach-port source in the same run-loop pass. One tick reading up is
    /// exactly that moment and must not orphan anything.
    @Test func oneTickUpIsThePhysicalReleaseRaceAndNeverCancels() {
        #expect(OrphanDetector.shouldCancel(buttonUp: true, ticksUp: 1,
                                            lastEventAt: now - 5, now: now, quietFor: tick) == false)
    }

    /// The other half of the rule, and the one that catches the same race a tick later: the user
    /// releases mid-drag, so `.dragged` events were arriving right up to the release. Two ticks have
    /// read up, but the stream was alive within the last poll, so the `.up` is still on its way.
    @Test func aLiveEventStreamMeansTheUpIsComingAndNeverCancels() {
        #expect(OrphanDetector.shouldCancel(buttonUp: true, ticksUp: 2,
                                            lastEventAt: now - 0.02, now: now, quietFor: tick) == false)
        #expect(OrphanDetector.shouldCancel(buttonUp: true, ticksUp: 5,
                                            lastEventAt: now - 0.099, now: now, quietFor: tick) == false)
    }

    /// The genuine orphan: a Space change or a disabled tap swallowed the `.up`, so the button has
    /// read up for two polls and nothing has come through the stream for at least one.
    @Test func twoTicksUpAndASilentStreamCancels() {
        #expect(OrphanDetector.shouldCancel(buttonUp: true, ticksUp: 2,
                                            lastEventAt: now - 0.35, now: now, quietFor: tick))
        // A drag whose press was the last thing it ever saw — pressed, then the Space changed — is
        // the same case with a much older stamp.
        #expect(OrphanDetector.shouldCancel(buttonUp: true, ticksUp: 3,
                                            lastEventAt: now - 4, now: now, quietFor: tick))
    }

    /// Both boundaries, stated rather than left to the next reader: the tick count is inclusive, the
    /// silence is `>=`.
    @Test func theBoundariesAreInclusive() {
        #expect(OrphanDetector.shouldCancel(buttonUp: true, ticksUp: OrphanDetector.confirmingTicks,
                                            lastEventAt: now - tick, now: now, quietFor: tick))
        #expect(OrphanDetector.shouldCancel(buttonUp: true, ticksUp: OrphanDetector.confirmingTicks - 1,
                                            lastEventAt: now - tick, now: now, quietFor: tick) == false)
        #expect(OrphanDetector.shouldCancel(buttonUp: true, ticksUp: OrphanDetector.confirmingTicks,
                                            lastEventAt: now - tick + 0.001, now: now, quietFor: tick) == false)
    }

    /// The whole poll sequence of an ordinary release, driven the way a controller drives it: the
    /// counter resets on every down reading, so the two ticks the rule asks for are consecutive ones
    /// and not two scattered through the gesture.
    @Test func anOrdinaryDragWithOneSpuriousUpReadingIsNeverCancelled() {
        // (button up?, ms since the last mouse event) at each 100 ms poll of a 700 ms drag whose
        // events keep arriving; the fourth poll catches a single spurious up reading.
        let polls: [(Bool, Double)] = [(false, 0.01), (false, 0.02), (false, 0.01),
                                       (true, 0.01), (false, 0.02), (false, 0.01), (false, 0.02)]
        var ticksUp = 0
        var cancelled = false
        for (index, poll) in polls.enumerated() {
            ticksUp = poll.0 ? ticksUp + 1 : 0
            let at = now + Double(index) * tick
            cancelled = cancelled || OrphanDetector.shouldCancel(buttonUp: poll.0, ticksUp: ticksUp,
                                                                 lastEventAt: at - poll.1, now: at,
                                                                 quietFor: tick)
        }
        #expect(cancelled == false)
    }

    /// And the sequence of a genuinely lost one: the events stop, the button reads up, and the second
    /// consecutive such poll — 200 ms after the loss — cancels.
    @Test func aLostMouseUpIsCaughtOnTheSecondConsecutivePoll() {
        let polls: [(Bool, Double)] = [(false, 0.01), (true, 0.05), (true, 0.15), (true, 0.25)]
        var ticksUp = 0
        var cancelledAt: Int?
        for (index, poll) in polls.enumerated() {
            ticksUp = poll.0 ? ticksUp + 1 : 0
            let at = now + Double(index) * tick
            if cancelledAt == nil, OrphanDetector.shouldCancel(buttonUp: poll.0, ticksUp: ticksUp,
                                                               lastEventAt: at - poll.1, now: at,
                                                               quietFor: tick) {
                cancelledAt = index
            }
        }
        #expect(cancelledAt == 2)
    }
}
