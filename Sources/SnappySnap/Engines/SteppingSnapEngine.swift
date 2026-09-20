import AppKit
import os
import QuartzCore
import SnapCore
import SystemAdapters

/// What becomes of a window's origin when its application will not take the size it was given.
enum RefusalPolicy {
    /// The window is re-positioned once, anchored to the zone's **outer** edges
    /// (`Geometry.anchoredOrigin`), so what it would not give up runs inward. For a write whose
    /// neighbour is then re-fitted against it: a handle or junction release, an oversize correction.
    case anchorInward
    /// The window keeps the origin it was given and extends right and down from it. For a window placed
    /// by an arrangement, which is solved again from what landed: the origin is where the arrangement
    /// wants it, and moving it here would undo that.
    case leaveInPlace
}

/// Animates a window frame through Accessibility on the display link, ~250 ms ease-in-out.
///
/// **Nothing it writes touches the main thread.** Two synchronous Accessibility calls per tick on
/// the run loop that serves the `CGEventTap` cost ~55 ms of that thread per tick for a gesture that
/// animates four Safari windows together, which is a stutter you can count. A tick only *posts* the
/// interpolated frame to `WindowWriter`: 0.01 ms whatever the target application is doing, one
/// serial queue per pid, and a post to a window whose previous frame has not landed yet
/// **replaces** it rather than queueing behind it. So a slow application does not slow the
/// animation of a fast one, and no application can slow the tap.
///
/// The last tick is the one that has to be exact. It posts the target frame with `readBack` and
/// then `flush`es, so the frame the window actually took comes home on the main actor without a
/// main-thread Accessibility read — and that landed frame is what the minimum-size anchoring is
/// decided from. An application that never answers costs the flush's deadline (2 s) and reports a
/// failure; it does not hold the tap.
///
/// Zone snaps, the snap bar's pair drops and Snap Assist's deal-back all run through this engine.
@MainActor
final class SteppingSnapEngine {
    /// One window's animation, from the `begin` that seeds the writer to the completion. A class,
    /// so the display link's tick, a cancel and the flush that comes home last are all looking at
    /// the same `finished` flag — whichever reaches it first owns the completion, and the others
    /// fall silent. Reference semantics are what let an animation that has handed its last frame to
    /// the writer stay one object: its link is gone but it is not over.
    @MainActor
    private final class Job {
        let handle: WindowHandle
        let from: CGRect
        let to: CGRect
        /// `to` rounded to points: the frame that is actually written, and the one a refusal is
        /// measured against.
        let zone: CGRect
        /// The display's working area, in CG space. Only the anchoring reads it.
        let area: CGRect
        let refusal: RefusalPolicy
        let start: CFTimeInterval
        let duration: TimeInterval
        let completion: @MainActor (CGRect?) -> Void
        /// Live only while the curve is being played; nil once the last frame has been posted.
        var link: CADisplayLink?
        var finished = false

        init(handle: WindowHandle, from: CGRect, to: CGRect, area: CGRect, refusal: RefusalPolicy,
             start: CFTimeInterval, duration: TimeInterval, completion: @escaping @MainActor (CGRect?) -> Void) {
            self.handle = handle
            self.from = from
            self.to = to
            zone = to.roundedToPoints()
            self.area = area
            self.refusal = refusal
            self.start = start
            self.duration = duration
            self.completion = completion
        }

        /// Calls the completion at most once, whoever gets here first.
        func finish(_ frame: CGRect?) {
            guard !finished else { return }
            finished = true
            completion(frame)
        }
    }

    /// Below this, a landed frame counts as the frame that was asked for: an app that rounds its size
    /// to a character grid must not buy a corrective write on every snap.
    private static let anchorTolerance: Double = 0.5

    private var jobs: [Int: Job] = [:]
    /// Which job a display link belongs to. `CADisplayLink` carries no payload of its own and the job
    /// outlives its link — the settling between the last posted frame and the flush answering has no
    /// link at all — so the two tables are kept apart rather than keyed together.
    private var linkJobs: [ObjectIdentifier: Int] = [:]
    private var nextJobID = 0
    /// The engine's only seam. Every write and every read it needs is a post or a flush here, so it
    /// touches `AccessibilityWindows` not at all.
    private let writer: WindowWriter

    init(writer: WindowWriter) {
        self.writer = writer
    }

    func snap(_ handle: WindowHandle, from: CGRect, to: CGRect, within area: CGRect, duration: TimeInterval,
              on screen: NSScreen, refusal: RefusalPolicy, completion: @escaping @MainActor (CGRect?) -> Void) {
        cancel(windowID: handle.windowID)
        nextJobID += 1
        let id = nextJobID
        let job = Job(handle: handle, from: from, to: to, area: area, refusal: refusal,
                      start: CACurrentMediaTime(), duration: duration, completion: completion)
        jobs[id] = job
        // One `begin` per animation, before the first post: it seeds the writer with where the window
        // is — which is what decides whether each post writes the size or the position first — and
        // claims the element for its pid's queue.
        writer.begin(handle, current: from)
        guard duration > 0.01 else {
            land(id)
            return
        }
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        job.link = link
        linkJobs[ObjectIdentifier(link)] = id
        link.add(to: .main, forMode: .common)
    }

    /// Whether this window has an animation running here — which is also the one question that says
    /// whether it may have posts in flight with `WindowWriter`. `OversizeWatcher` asks it before it
    /// reads anything about a window at all, because a main-thread Accessibility read of a window
    /// being written is exactly the cost the writer exists to avoid.
    func isAnimating(windowID: CGWindowID) -> Bool {
        jobs.values.contains { $0.handle.windowID == windowID }
    }

    /// Stops any animation of that window; its completion receives nil. The writer is told too, so a
    /// frame still sitting in the mailbox is dropped and a flush still waiting its turn is answered
    /// nil rather than left to its deadline. Completions run only after every entry is gone, so a
    /// completion that starts a new snap cannot race the teardown.
    func cancel(windowID: CGWindowID?) {
        guard let windowID else { return }
        var cancelled: [Job] = []
        for (id, job) in jobs where job.handle.windowID == windowID {
            retire(job)
            jobs[id] = nil
            writer.cancel(job.handle)
            cancelled.append(job)
        }
        for job in cancelled { job.finish(nil) }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let key = ObjectIdentifier(link)
        guard let id = linkJobs[key], let job = jobs[id] else { link.invalidate(); return }
        let t = min(1, (link.targetTimestamp - job.start) / job.duration)
        if t >= 1 {
            retire(job)
            land(id)
            return
        }
        // One post, and the two writes it turns into happen on the window's own pid queue. No
        // reads: the writer knows where it last put this window, which is what the order of the two
        // writes is decided from.
        let frame = AnimationCurve.interpolate(job.from, job.to, progress: AnimationCurve.easeInOut(t)).roundedToPoints()
        writer.post(WindowWriter.Request(frame: frame), to: job.handle)
    }

    /// The last frame, and the only one that has to be exact: posted with a read-back, then
    /// flushed. The flush answers on the main actor with what the window took, which is what the
    /// anchoring needs and what the caller is handed.
    private func land(_ id: Int) {
        guard let job = jobs[id] else { return }
        writer.post(WindowWriter.Request(frame: job.zone, readBack: true), to: job.handle)
        writer.flush(job.handle) { [weak self] outcome in
            self?.landed(id, outcome)
        }
    }

    /// nil is a cancel — and a cancel has already answered this job's completion, so the lookup finds
    /// nothing. An `Outcome` with no `landedFrame` is a flush that reached its deadline or a read the
    /// application refused; both mean the same thing to a caller, which is that the window is not
    /// known to be where it was asked to be.
    private func landed(_ id: Int, _ outcome: WindowWriter.Outcome?) {
        guard let job = jobs[id] else { return }
        guard let landed = outcome?.landedFrame else {
            jobs[id] = nil
            job.finish(nil)
            return
        }
        switch job.refusal {
        case .anchorInward:
            anchor(id, landed: landed)
        case .leaveInPlace:
            jobs[id] = nil
            job.finish(landed)
        }
    }

    /// A window that cannot reach the zone's size is placed at the size it *will* take, anchored to
    /// the zone's **outer** edges. The flush has already handed back what the window took, so the
    /// refusal is known without another read, and `Geometry.anchoredOrigin` says where it then
    /// belongs — inward across the layout rather than off the display. One position-only post, and
    /// only on the path where an application refused the size it was given; every other snap
    /// returns here untouched.
    ///
    /// The corrective post is flushed as well, so the frame the caller is handed is still one that was
    /// read back rather than one that was assumed. It costs a second round of the writer's own queue
    /// and no main-thread time at all.
    private func anchor(_ id: Int, landed: CGRect) {
        guard let job = jobs[id] else { return }
        guard landed.width > job.zone.width + Self.anchorTolerance
                || landed.height > job.zone.height + Self.anchorTolerance else {
            jobs[id] = nil
            job.finish(landed)
            return
        }
        let wanted = Geometry.anchoredOrigin(for: landed.size, in: job.zone, within: job.area)
        let origin = CGPoint(x: wanted.x.rounded(), y: wanted.y.rounded())
        guard abs(origin.x - landed.minX) > Self.anchorTolerance
                || abs(origin.y - landed.minY) > Self.anchorTolerance else {
            jobs[id] = nil
            job.finish(landed)
            return
        }
        Logger.drag.debug("""
            minimum anchor: window took \(landed.width, format: .fixed(precision: 0))×\
            \(landed.height, format: .fixed(precision: 0)) for a \
            \(job.zone.width, format: .fixed(precision: 0))×\(job.zone.height, format: .fixed(precision: 0)) zone; \
            anchoring to \(origin.x, format: .fixed(precision: 0)),\(origin.y, format: .fixed(precision: 0))
            """)
        let anchored = CGRect(origin: origin, size: landed.size)
        writer.post(WindowWriter.Request(frame: anchored, writeSize: false), to: job.handle)
        writer.flush(job.handle) { [weak self] outcome in
            guard let self, let job = self.jobs[id] else { return }
            self.jobs[id] = nil
            job.finish(outcome?.landedFrame ?? anchored)
        }
    }

    /// Takes a job's display link off the run loop and out of the table. The job itself stays: the
    /// curve is over but the last frame has not landed yet.
    private func retire(_ job: Job) {
        guard let link = job.link else { return }
        link.invalidate()
        linkJobs[ObjectIdentifier(link)] = nil
        job.link = nil
    }
}
