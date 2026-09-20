import AppKit
import os
import SnapCore
import SystemAdapters

/// Places the windows of an arrangement, and keeps the arrangement true to what actually landed.
///
/// **macOS publishes no minimum and no maximum window size**, so an arrangement is solved with what is
/// known and the rest is found out by asking: a window that comes back larger than it was asked for has
/// shown its minimum, one that comes back smaller its maximum (`ArrangementFacts`). Either makes the
/// solution that was written wrong — a window standing in its neighbour's space, or a hole beside one
/// that would not grow — so the arrangement is solved again with the new limit and the boxes that
/// changed are written again. That is the **correction pass**, and this is the one place it lives: the
/// drop, the pair and the Snap Assist pick all place their windows through here.
///
/// Every write is `.leaveInPlace`. A window that refuses its size keeps the origin the arrangement gave
/// it and extends right and down from there; what moves it next, if anything does, is the next
/// solution.
///
/// **At most `maximumCorrections` rounds.** Each round can only add a limit nobody knew, so the rounds
/// end by themselves; the ceiling is for the application that answers differently every time. Two
/// windows that both refuse on first encounter take two.
@MainActor
final class ArrangementCoordinator {
    /// One window of the arrangement that this run may write.
    struct Member {
        let id: ArrangementBox.ID
        /// The window's Accessibility handle, asked for the first time the window has to be written.
        /// Every window of an arrangement is a member, because a correction may have to move one that
        /// the first solution left alone — and a neighbour that never moves then costs no
        /// Accessibility call at all. Nil is a window that cannot be written: gone, or minimized.
        let resolve: @MainActor () -> WindowHandle?
        /// Where the window is now: the frame its animation leaves from, and the frame a landing has to
        /// differ from to prove the write was applied at all.
        var current: CGRect
        /// What the registry records for this window. Its frame is replaced by the solved one.
        let zone: Zone

        init(id: ArrangementBox.ID, handle: WindowHandle, current: CGRect, zone: Zone) {
            self.init(id: id, current: current, zone: zone) { handle }
        }

        init(id: ArrangementBox.ID, current: CGRect, zone: Zone, resolve: @escaping @MainActor () -> WindowHandle?) {
            self.id = id
            self.resolve = resolve
            self.current = current
            self.zone = zone
        }
    }

    struct Outcome {
        /// The arrangement, carrying every limit the landings revealed.
        let arrangement: Arrangement
        /// The last frame each window was read back at. A window that never landed is absent; one that
        /// landed and then lost a later write keeps the landing it had.
        let landed: [ArrangementBox.ID: CGRect]
    }

    static let maximumCorrections = 2

    private let engines: EngineRouter

    init(engines: EngineRouter) {
        self.engines = engines
    }

    /// Solves `arrangement`, writes every member whose frame that changes, and corrects.
    ///
    /// `onSolved` is handed every solution as it is reached, before its writes — Snap Assist moves its
    /// open areas from it. `isCurrent` is asked before each correction, so a gesture that has since
    /// been superseded stops writing. `afterFirstLandings` runs once the first solution has landed and
    /// before any correction: the drop starts Snap Assist from it, so the choosing phase does not wait
    /// for a correction it has no part in. `completion` runs once, after the last landing.
    ///
    /// **Nothing here calls back on the turn it was called on.** The engine cancels a window's running
    /// animation synchronously when a new one is started for it, so a second run that writes a window
    /// the first is still animating would otherwise finish the first run — and run its completion,
    /// which may end a whole Snap Assist phase — from inside the caller of the second. Every callback
    /// but `onSolved` is therefore put on the next turn of the main queue.
    func run(_ arrangement: Arrangement, members: [Member], display: DisplayInfo,
             isCurrent: @escaping @MainActor () -> Bool,
             onSolved: @escaping @MainActor (ArrangementSolution) -> Void,
             afterFirstLandings: (@MainActor (Outcome) -> Void)? = nil,
             completion: @escaping @MainActor (Outcome) -> Void) {
        let run = Run(arrangement: arrangement, members: members, display: display, isCurrent: isCurrent,
                      onSolved: onSolved, afterFirstLandings: afterFirstLandings, completion: completion)
        round(run)
    }

    private final class Run {
        var arrangement: Arrangement
        var members: [Member]
        let display: DisplayInfo
        let isCurrent: @MainActor () -> Bool
        let onSolved: @MainActor (ArrangementSolution) -> Void
        var afterFirstLandings: (@MainActor (Outcome) -> Void)?
        let completion: @MainActor (Outcome) -> Void
        var handles: [Int: WindowHandle] = [:]
        var landed: [ArrangementBox.ID: CGRect] = [:]
        /// Members that cannot be written, or whose write came back with nothing: cancelled by a newer
        /// gesture on that window, or refused outright. They are never written again by this run — a
        /// window the user has just picked up is not one to yank back for a correction.
        var lost: Set<ArrangementBox.ID> = []
        var corrections = 0

        init(arrangement: Arrangement, members: [Member], display: DisplayInfo,
             isCurrent: @escaping @MainActor () -> Bool,
             onSolved: @escaping @MainActor (ArrangementSolution) -> Void,
             afterFirstLandings: (@MainActor (Outcome) -> Void)?,
             completion: @escaping @MainActor (Outcome) -> Void) {
            self.arrangement = arrangement
            self.members = members
            self.display = display
            self.isCurrent = isCurrent
            self.onSolved = onSolved
            self.afterFirstLandings = afterFirstLandings
            self.completion = completion
        }

        var outcome: Outcome { Outcome(arrangement: arrangement, landed: landed) }
    }

    private func later(_ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
    }

    private func round(_ run: Run) {
        let solution = run.arrangement.solve()
        run.onSolved(solution)
        var writes: [(index: Int, handle: WindowHandle, solved: CGRect)] = []
        for index in run.members.indices {
            let member = run.members[index]
            guard !run.lost.contains(member.id), let solved = solution.frames[member.id],
                  ArrangementFacts.isWorthWriting(solved, over: member.current, correcting: run.corrections > 0) else { continue }
            guard let handle = run.handles[index] ?? member.resolve() else {
                Logger.drag.error("\(String(describing: member.id), privacy: .public) cannot be written; it keeps its frame and may be overlapped")
                run.lost.insert(member.id)
                continue
            }
            run.handles[index] = handle
            writes.append((index, handle, solved))
        }
        guard !writes.isEmpty else {
            later { [weak self] in self?.finishRound(run, revealed: false) }
            return
        }
        var pending = writes.count
        var revealed = false
        for write in writes {
            let member = run.members[write.index]
            var zone = member.zone
            zone.frame = write.solved
            let asked = write.solved.roundedToPoints()
            let before = member.current
            engines.snap(write.handle, from: before, to: zone, display: run.display,
                         refusal: .leaveInPlace) { [weak self] landed in
                pending -= 1
                if let landed {
                    run.landed[member.id] = landed
                    run.members[write.index].current = landed
                    if Self.learn(from: landed, asked: asked, before: before, member: member.id, in: run) { revealed = true }
                } else {
                    run.lost.insert(member.id)
                }
                guard pending == 0 else { return }
                let revealedSomething = revealed
                self?.later { [weak self] in self?.finishRound(run, revealed: revealedSomething) }
            }
        }
    }

    private func finishRound(_ run: Run, revealed: Bool) {
        if let afterFirstLandings = run.afterFirstLandings {
            run.afterFirstLandings = nil
            afterFirstLandings(run.outcome)
        }
        guard revealed, run.isCurrent() else {
            run.completion(run.outcome)
            return
        }
        guard run.corrections < Self.maximumCorrections else {
            Logger.drag.info("arrangement still off after \(Self.maximumCorrections) corrections; leaving it as it landed")
            run.completion(run.outcome)
            return
        }
        run.corrections += 1
        round(run)
    }

    /// Records what a landing revealed in the run's arrangement. True when it revealed anything.
    private static func learn(from landed: CGRect, asked: CGRect, before: CGRect,
                              member id: ArrangementBox.ID, in run: Run) -> Bool {
        guard let index = run.arrangement.boxes.firstIndex(where: { $0.id == id }),
              let limits = ArrangementFacts.revealed(run.arrangement.boxes[index].limits,
                                                     asked: asked, landed: landed, before: before) else { return false }
        run.arrangement.boxes[index].limits = limits
        Logger.drag.info("""
            \(String(describing: id), privacy: .public) was asked \(asked.width, format: .fixed(precision: 0))×\
            \(asked.height, format: .fixed(precision: 0)) and took \(landed.width, format: .fixed(precision: 0))×\
            \(landed.height, format: .fixed(precision: 0)); solving the arrangement again
            """)
        return true
    }
}
