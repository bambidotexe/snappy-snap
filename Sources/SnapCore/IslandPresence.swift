import Foundation

/// What the island's shape is drawn as. `hidden` is the circle scaled to nothing.
public enum IslandState: Hashable, Sendable, CaseIterable {
    case hidden, circle, capsule, expanded
}

/// A `Spring(duration:bounce:)`, as plain numbers: SnapCore never imports SwiftUI.
public struct IslandSpring: Hashable, Sendable {
    public let duration: Double
    public let bounce: Double
}

/// One spring of the island's motion. Each was fitted to a 60 fps capture of the reference notch
/// utility's own island on a 1× display — two samples per transition, the black blob traced per frame,
/// the spring found by least squares with the start free within one frame either way.
public enum IslandMotion: Hashable, Sendable, CaseIterable {
    /// Nothing → circle. Overshoots 4 %; joint rms error 0.037 of the travel. The spring is the
    /// reference's; the point it scales about is not — see `IslandPresence.scaleAnchorY`.
    case scaleIn
    /// Circle → capsule. Joint rms 0.028.
    case widen
    /// Capsule → circle. Rms 0.020; it never dips under the circle.
    case narrow
    /// Circle → nothing. The spring crosses zero 0.167 s in and the shape clamps there, which is what
    /// gives the departure its abrupt end; joint rms 0.025.
    case scaleOut
    /// Capsule → grown shape, and back. The notch shape's springs, which were fitted by eye to the
    /// same utility: a capture of its island growing on a display with no housing has not been
    /// measured.
    case expand, collapse

    public var spring: IslandSpring {
        switch self {
        case .scaleIn: IslandSpring(duration: 0.18, bounce: 0.20)
        case .widen: IslandSpring(duration: 0.25, bounce: 0.20)
        case .narrow: IslandSpring(duration: 0.20, bounce: 0)
        case .scaleOut: IslandSpring(duration: 0.35, bounce: 0.35)
        case .expand: IslandSpring(duration: NotchGeometry.openDuration, bounce: NotchGeometry.openBounce)
        case .collapse: IslandSpring(duration: NotchGeometry.closeDuration, bounce: NotchGeometry.closeBounce)
        }
    }
}

/// One step of a transition: the state to animate to, the spring to get there on, and how long after
/// the transition began it starts.
public struct IslandStep: Hashable, Sendable {
    public let state: IslandState
    public let motion: IslandMotion
    public let delay: Double

    public init(state: IslandState, motion: IslandMotion, delay: Double) {
        self.state = state
        self.motion = motion
        self.delay = delay
    }
}

/// The rule of the island's motion: which steps take it from one state to another. Pure, so the
/// panel that plays the steps decides nothing.
///
/// `from` is the state last *asked for*, not the one on screen: every step is a SwiftUI animation,
/// which leaves from whatever is rendered, so a transition reversed mid-way retargets by itself.
public enum IslandPresence {
    /// The circle holds before it widens: the widening starts this long after the arrival began
    /// (measured 282 and 268 ms).
    public static let widenDelay: Double = 0.275
    /// The circle holds before it scales out: this long after the departure began (235 and 250 ms).
    public static let scaleOutDelay: Double = 0.24
    /// How far under the screen's top edge the point lies that the shape scales about, arriving and
    /// departing alike: 13 pt, just above the island's centre. It is where the reference's own
    /// departure scales about — that anchor predicts the traced blob's top and bottom on every
    /// captured frame. The reference's *arrival* grows down out of the screen's edge instead, and
    /// this island deliberately does not follow it there: it is drawn above the reference's resting
    /// island, which starts 3 pt under the edge, so a dot at the edge shows above it.
    public static let scaleAnchorY: Double = 13
    /// The cells arrive after the shape has room for them and leave before it has taken it back.
    public static let cellsFadeIn: Double = 0.18
    public static let cellsFadeInDelay: Double = 0.10
    public static let cellsFadeOut: Double = 0.08

    public static func steps(from: IslandState, to: IslandState, interrupted: Bool = false) -> [IslandStep] {
        func step(_ state: IslandState, _ motion: IslandMotion, _ delay: Double = 0) -> IslandStep {
            IslandStep(state: state, motion: motion, delay: delay)
        }
        let collapse = IslandMotion.collapse.spring.duration
        switch (from, to) {
        case (.hidden, .hidden), (.circle, .circle), (.capsule, .capsule), (.expanded, .expanded):
            return []
        case (.hidden, .circle):
            return [step(.circle, .scaleIn)]
        case (.hidden, .capsule):
            return [step(.circle, .scaleIn), step(.capsule, .widen, widenDelay)]
        case (.hidden, .expanded):
            return [step(.circle, .scaleIn), step(.expanded, .expand, widenDelay)]
        case (.circle, .capsule):
            return [step(.capsule, .widen)]
        case (.circle, .expanded), (.capsule, .expanded):
            return [step(.expanded, .expand)]
        case (.expanded, .capsule):
            return [step(.capsule, .collapse)]
        case (.capsule, .circle), (.expanded, .circle):
            return [step(.circle, .narrow)]
        case (.circle, .hidden):
            return [step(.hidden, .scaleOut)]
        case (.capsule, .hidden):
            return [step(.circle, .narrow), step(.hidden, .scaleOut, scaleOutDelay)]
        case (.expanded, .hidden):
            if interrupted { return [step(.circle, .narrow), step(.hidden, .scaleOut, scaleOutDelay)] }
            return [step(.capsule, .collapse), step(.circle, .narrow, collapse),
                    step(.hidden, .scaleOut, collapse + scaleOutDelay)]
        }
    }
}
