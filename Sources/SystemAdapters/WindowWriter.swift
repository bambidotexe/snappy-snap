import ApplicationServices
import CoreGraphics
import Foundation

/// Every Accessibility write the app makes, off the main thread.
///
/// **Why**, measured. A window write is a synchronous IPC round trip whose cost is almost entirely
/// *waiting* for the target app's own main thread: 2–13 ms for a size write, 64 ms for one pass over
/// four mixed windows when they are written serially on our main thread — the same run loop that
/// serves the `CGEventTap`. That waiting overlaps across applications and does not
/// overlap within one. So: **one serial queue per pid**, and the main thread only *posts*.
/// Measured on the same four windows: 14.3 ms per pass, 0.01 ms of main thread per post at 121 Hz,
/// and each window then following at its own rate (Finder 81 Hz, TextEdit 109, Chrome 114, Preview 117).
///
/// **The invariants**, which every consumer may rely on:
/// - **One element belongs to one queue for a whole gesture.** The queue is chosen by `handle.pid`, and
///   a pid's queue is never retired, so two windows of one app can never be written concurrently even
///   across a `cancel` and a fresh `begin`.
/// - **One single-slot mailbox per window.** A `post` to a window whose write is still running
///   **replaces** the pending frame; stale frames are dropped, never queued. `Outcome.superseded` is
///   how many were dropped since the previous outcome, so a caller can see it.
/// - **The in-flight write always finishes.** `cancel` drops what is pending and fails the flushes; it
///   never tries to interrupt a write that is already inside Accessibility. So a caller never waits on
///   a hung app: it either cancels, or lets `flush`'s deadline answer for it.
/// - **Order within one pid is the queue's order**, and windows of one pid take turns: a step writes at
///   most one frame and re-enqueues itself, so a window posted at the display rate cannot starve its
///   siblings.
/// - **Everything comes home on the main actor** — `onOutcome` for every applied write, and the flush
///   completions. Nothing else does; in particular a caller must make **no main-thread Accessibility
///   read** of a window with posts in flight (four such reads cost a measured 121 → 83.5 Hz), which is
///   what `readBack` and `flush` are for: those reads ride the worker.
///
/// **What it does not do.** It does not pace: how often to post is `PostRate`'s decision and the
/// caller's. It does not set the per-element messaging timeout — handles arrive carrying
/// `AccessibilityWindows.messagingTimeout` (0.25 s), and that is what bounds any one write here.
///
/// **`@unchecked Sendable`.** The class is used from the main actor and from every pid's worker.
/// `lock` protects exactly two things: the `queues` table and the `boxes` table, including everything
/// reachable through a `Mailbox` (its pending request, its last known frame, its superseded count, its
/// scheduled-step flag and its flush completions). No `Mailbox` reference ever leaves the lock: a
/// worker carries only the `WindowHandle` and the mailbox's generation, and looks the box up again
/// under the lock — which is also what makes `cancel` able to forget a window while its write is still
/// blocked in another app. `backend` is immutable and `Sendable`; `onOutcome` is main-actor isolated
/// and never read off it. It is `@unchecked` because that safety is the lock's to keep and not the
/// type system's.
public final class WindowWriter: @unchecked Sendable {

    // MARK: - Contract

    public struct Request: Sendable, Hashable {
        public var frame: CGRect
        public var writePosition: Bool = true
        public var writeSize: Bool = true
        /// Read the size back after the write and report it in `Outcome.landedSize`. This is how a
        /// caller learns a window's minimum or its size grain without a main-thread read.
        public var readBack: Bool = false

        public init(frame: CGRect, writePosition: Bool = true, writeSize: Bool = true,
                    readBack: Bool = false) {
            self.frame = frame
            self.writePosition = writePosition
            self.writeSize = writeSize
            self.readBack = readBack
        }
    }

    public struct Outcome: Sendable {
        public let handle: WindowHandle
        /// Which gesture this belongs to: the value `begin` returned for this window when the work was
        /// posted or the flush registered. It is what makes an outcome's *owner* knowable, which the
        /// handle alone cannot say — `WindowHandle` compares by the AX element, so the same window
        /// looked up again in a later gesture compares equal to the one in this one.
        ///
        /// It matters because an outcome can outlive the gesture that asked for it. `begin` deliberately
        /// does not suppress a write that is already inside Accessibility — it happened, and a cost
        /// model that did not see it would be lying — and a `flush` that gives up at its deadline ends
        /// a gesture while that write is still running. A consumer matching on the handle alone would
        /// then absorb the old write into the new gesture: its telemetry, and worse, whatever it learns
        /// from `landedSize`, which was read at the *old* geometry. Compare this against what `begin`
        /// returned and drop what does not match.
        public let generation: Int
        /// The frame the **caller** asked for: this step's own request, or — on a flush, and on a flush
        /// that timed out — the last frame posted for this window, or `begin`'s seed when nothing has
        /// been posted since. Never a frame that was read back, so a window that refused its size or a
        /// position macOS clamped shows up here as the difference between `asked` and `landedFrame`
        /// rather than being quietly papered over.
        public let asked: CGRect
        /// Only when `readBack` was set, or on a flush.
        public let landedSize: CGSize?
        /// Only on a flush.
        public let landedFrame: CGRect?
        /// Wall time of the write or writes, in seconds — not the read-back, and not the wait in the
        /// mailbox. This is the number a cost model learns from.
        public let cost: TimeInterval
        /// Posts replaced in the mailbox since the previous outcome for this window.
        public let superseded: Int
        /// False when any Accessibility call in this step refused: a `set` that returned an error, or a
        /// read that was asked for and came back nil. A flush that could not read the frame is a
        /// failure and says so here rather than answering nil, because nil means *cancelled*.
        public let succeeded: Bool
    }

    /// The four raw Accessibility calls, behind a seam. The app uses `live()`; the tests use a fake, so
    /// every property of the mailbox is provable without a window, a permission or a real app to hang.
    public protocol Backend: Sendable {
        func setPosition(_ p: CGPoint, of element: AXUIElement) -> Bool
        func setSize(_ s: CGSize, of element: AXUIElement) -> Bool
        func size(of element: AXUIElement) -> CGSize?
        func frame(of element: AXUIElement) -> CGRect?
    }

    // MARK: - State

    /// One outstanding `flush`. A class, because three things race for it — the step that reads the
    /// frame, the deadline, and `cancel` — and whichever sets `answered` first under the lock owns the
    /// answer. That is what makes "the completion is called exactly once" true rather than hoped for.
    private final class Flush {
        let completion: @MainActor (Outcome?) -> Void
        var answered = false

        init(_ completion: @escaping @MainActor (Outcome?) -> Void) { self.completion = completion }
    }

    /// A window's single slot. Only ever touched under `WindowWriter.lock`.
    ///
    /// `generation` is what lets a box be disowned while its write is still blocked: the worker carries
    /// the generation it started with, so the bookkeeping of a step whose gesture has since been
    /// cancelled (the box is gone) or begun again (the box has moved on) cannot land on the slot.
    private final class Mailbox {
        var generation: Int
        var pending: Request?
        /// Where the writer believes the window is: seeded by `begin`, advanced by every applied write
        /// and by every frame a flush reads back. `nil` only for a window posted to without a `begin`.
        /// This is the frame `plan` decides the write order against, and it is deliberately *not* what
        /// `Outcome.asked` reports.
        var lastKnown: CGRect?
        /// The last frame the caller asked for — `begin`'s seed, then every `post`, superseded or not.
        /// Never touched by a read-back. This is `Outcome.asked` on a flush.
        var lastRequested: CGRect
        var superseded = 0
        /// A step is queued or running for this window.
        var stepScheduled = false
        var flushes: [Flush] = []
        var touched: UInt64

        init(generation: Int, requested: CGRect, touched: UInt64) {
            self.generation = generation
            lastRequested = requested
            self.touched = touched
        }

        var isIdle: Bool { pending == nil && !stepScheduled && flushes.isEmpty }

        /// After a step has run, whether there is nothing left to do for this window.
        var isIdleAfterStep: Bool { pending == nil && flushes.isEmpty }
    }

    private enum Write { case position, size }

    /// An idle mailbox is dropped once it has been untouched this long. No gesture or animation has a
    /// 60 s gap in it, so this only ever reaches windows nobody is writing to; it is what keeps the
    /// table proportional to the windows in play rather than to every window the app has ever touched.
    private static let staleAfter: TimeInterval = 60

    /// How often the sweep is worth running. Every main-actor entry point offers — the sweep must not
    /// depend on any one of them being called — but a table walk on the 120 Hz post path would be a
    /// cost for nothing, and nothing goes stale in five seconds.
    private static let sweepInterval: TimeInterval = 5

    /// The default `flush` deadline: eight times the 0.25 s per-element messaging timeout the handles
    /// carry, so an app answering any of its calls at all will make it, and one that never answers is
    /// reported rather than waited on.
    public static let defaultFlushDeadline: TimeInterval = 2.0

    private let backend: any Backend
    private let lock = NSLock()
    private var queues: [pid_t: DispatchQueue] = [:]
    private var boxes: [WindowHandle: Mailbox] = [:]
    private var generations = 0
    private var lastSweep: UInt64 = 0

    public init(backend: any Backend) {
        self.backend = backend
    }

    /// The writer the app runs on: the four calls of `AX`, against the element in the handle.
    public static func live() -> WindowWriter { WindowWriter(backend: AXBackend()) }

    /// Every applied write, on the main actor. Telemetry and learning (a window's minimum, its size
    /// grain) hang off this.
    @MainActor public var onOutcome: (@MainActor (Outcome) -> Void)?

    // MARK: - Main-actor API

    /// Seeds the writer's notion of where the window is — which is what decides the order of the two
    /// writes, see `plan` — and claims the element for its pid's queue. Call once per gesture or
    /// animation, before the first post.
    ///
    /// **`begin` starts the gesture clean.** Whatever the last one left in the mailbox goes: a frame
    /// posted but not yet started is dropped — the caller has just said where the window is, which
    /// supersedes it — `superseded` restarts at 0, and a flush still waiting from the previous gesture
    /// is answered nil, cancelled. Consumers call `begin` only after the previous flush has answered,
    /// so that last part is a safety net rather than a path; what it guarantees is that the first
    /// `Outcome` of a gesture can never carry a count, or a frame, belonging to the one before it.
    ///
    /// **A write already in flight is untouched**: it finishes and still reports its `Outcome`, because
    /// it happened. What it loses is its bookkeeping — the seed given here is what the next post's
    /// write order is decided against, not the frame that write was pushing. The consumers this
    /// matters to are the ones that seed with a frame they are about to write, the Snap Assist
    /// deal-back and the drag-away restore, and for them the caller's intent is the better evidence.
    ///
    /// **It returns the gesture's generation**, which every `Outcome` posted under it carries. The
    /// write still in flight from the previous gesture keeps the *old* one, so a caller that compares
    /// can tell the two apart — see `Outcome.generation` for why that is not optional.
    @discardableResult
    @MainActor public func begin(_ handle: WindowHandle, current: CGRect) -> Int {
        lock.lock()
        let box = mailboxLocked(for: handle, requesting: current)
        box.lastKnown = current
        box.touched = Self.now()
        box.pending = nil
        box.superseded = 0
        let orphaned = claimLocked(box.flushes)
        box.flushes = []
        // A new generation on every `begin`, whether or not a step is running: it is what the caller is
        // handed back and what every outcome of this gesture will carry, so it cannot be conditional on
        // the state the *previous* gesture happened to leave behind.
        generations += 1
        box.generation = generations
        if box.stepScheduled {
            // Disown the running step. Clearing the flag is what keeps the mailbox usable: the step's
            // `complete` will find a generation it does not own and do nothing at all, including not
            // hand the queue back. Nothing needs scheduling in its place — the mailbox is empty now.
            box.stepScheduled = false
        }
        _ = queueLocked(for: handle.pid)   // made here rather than at the first post, so a gesture's
                                           // first frame never pays for building a queue.
        sweepLocked(keeping: handle)
        let generation = box.generation
        lock.unlock()
        deliver(nil, to: orphaned)
        return generation
    }

    /// Replaces the pending frame. Never blocks: 0.01 ms measured, whatever the target app is doing.
    @MainActor public func post(_ request: Request, to handle: WindowHandle) {
        lock.lock()
        let box = mailboxLocked(for: handle, requesting: request.frame)
        if box.pending != nil { box.superseded += 1 }
        box.pending = request
        box.touched = Self.now()
        let work = scheduleLocked(box, handle)
        sweepLocked(keeping: handle)
        lock.unlock()
        work?()
    }

    /// After the last posted frame has been applied — or at once when nothing is pending — reads the
    /// frame back on the worker and delivers it on the main actor.
    ///
    /// **The completion is called exactly once, with one of three answers.**
    /// - **Landed:** an `Outcome` carrying `landedFrame`, the frame that was read after the last posted
    ///   frame was written. `succeeded == false` with `landedFrame == nil` means the read itself
    ///   refused — the window is gone, or the app will not answer.
    /// - **Timed out:** after `deadline`, an `Outcome` with `succeeded == false` and no `landedFrame`,
    ///   because the last posted frame had not landed yet. A write still queued behind a hung app can
    ///   otherwise wait 0.25 s for every step already queued for every window of that pid; this is the
    ///   bound, and it is the caller's to shorten. The write, if it ever completes, still reports
    ///   through `onOutcome` — it just cannot answer this completion a second time.
    /// - **Cancelled:** `nil`, and only ever that. `cancel` came first, or arrived while this flush was
    ///   still waiting its turn; a window the writer has never been given, or has been made to forget,
    ///   is cancelled in the same sense. The parking safety has to tell "cancelled" from "could not
    ///   land", which is why a failure is an `Outcome` and never nil.
    ///
    /// The default deadline is a generous multiple of the 0.25 s per-element messaging timeout every
    /// handle carries (`AccessibilityWindows.messagingTimeout`): an app that answers its calls at all
    /// will make it long before.
    @MainActor public func flush(_ handle: WindowHandle,
                                 deadline: TimeInterval = WindowWriter.defaultFlushDeadline,
                                 _ completion: @escaping @MainActor (Outcome?) -> Void) {
        lock.lock()
        guard let box = boxes[handle] else {
            lock.unlock()
            deliver(nil, to: [completion])
            return
        }
        let entry = Flush(completion)
        box.flushes.append(entry)
        box.touched = Self.now()
        let asked = box.lastRequested
        let generation = box.generation
        let work = scheduleLocked(box, handle)
        sweepLocked(keeping: handle)
        lock.unlock()
        work?()

        DispatchQueue.main.asyncAfter(deadline: .now() + deadline) { [self] in
            MainActor.assumeIsolated { expire(entry, handle, asked: asked, generation: generation) }
        }
    }

    /// The deadline came first. Claims the flush if nothing else has, and answers with what is true: the
    /// frame the caller asked for, nothing read, and `succeeded == false`. `cost` and `superseded` are
    /// zero because this outcome measured nothing — the write it was waiting for will report its own.
    @MainActor private func expire(_ entry: Flush, _ handle: WindowHandle, asked: CGRect, generation: Int) {
        lock.lock()
        guard !entry.answered else { lock.unlock(); return }
        entry.answered = true
        let box = boxes[handle]
        box?.flushes.removeAll { $0 === entry }
        let requested = box?.lastRequested ?? asked
        lock.unlock()
        entry.completion(Outcome(handle: handle, generation: generation, asked: requested,
                                 landedSize: nil, landedFrame: nil, cost: 0, superseded: 0,
                                 succeeded: false))
    }

    /// Drops the pending frame and fails every flush that was waiting. The in-flight write finishes on
    /// its own; this returns immediately even when that write is blocked in an app that has stopped
    /// answering, which is the whole point of it.
    ///
    /// Two things survive a cancel, both deliberately. The write that is already inside Accessibility
    /// still reports its `Outcome` — it happened, and a cost model that did not see it would be lying
    /// to itself. And a flush whose *read* has already started answers with what it read rather than
    /// nil, by the same rule: only a flush still waiting its turn is cancellable.
    ///
    /// Afterwards the writer has forgotten the window: `hasPending` is false and `flush` is nil until
    /// the next `begin`. So a caller that cancels and then immediately reads that window from the main
    /// thread can still queue behind the write that is finishing — rare, and the cost is the read, not
    /// the truth of it.
    @MainActor public func cancel(_ handle: WindowHandle) {
        lock.lock()
        guard let box = boxes[handle] else { lock.unlock(); return }
        let completions = claimLocked(box.flushes)
        box.flushes = []
        box.pending = nil
        boxes[handle] = nil
        lock.unlock()
        deliver(nil, to: completions)
    }

    /// True while a frame is waiting in this window's mailbox, or a step is queued or already running
    /// for it. A window the writer has forgotten — cancelled, or never begun — answers false. A caller
    /// that wants to read a window from the main thread must wait for this to be false: main-thread
    /// reads during writes cost a measured 121 → 83.5 Hz.
    @MainActor public func hasPending(_ handle: WindowHandle) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let box = boxes[handle] else { return false }
        return box.pending != nil || box.stepScheduled
    }

    // MARK: - The worker

    /// One step: at most one write, or — when nothing is pending and flushes are waiting — one frame
    /// read. Never both, so an outcome means exactly one thing. The step re-enqueues itself while the
    /// mailbox still has work, which is what gives the windows of one pid their turns.
    private func step(_ handle: WindowHandle, generation: Int) {
        lock.lock()
        guard let box = boxes[handle], box.generation == generation else { lock.unlock(); return }
        let element = handle.element

        if let request = box.pending {
            box.pending = nil
            let superseded = box.superseded
            box.superseded = 0
            let current = box.lastKnown
            lock.unlock()

            var succeeded = true
            let start = Self.now()
            for write in Self.plan(request, current: current) {
                switch write {
                case .position: succeeded = backend.setPosition(request.frame.origin, of: element) && succeeded
                case .size: succeeded = backend.setSize(request.frame.size, of: element) && succeeded
                }
            }
            let cost = Self.seconds(from: start)

            var landedSize: CGSize?
            if request.readBack {
                landedSize = backend.size(of: element)
                if landedSize == nil { succeeded = false }
            }

            let landed = Self.landed(request, current: current, size: landedSize)
            let outcome = Outcome(handle: handle, generation: generation, asked: request.frame,
                                  landedSize: landedSize, landedFrame: nil, cost: cost,
                                  superseded: superseded, succeeded: succeeded)
            complete(handle, generation: generation, lastKnown: landed)
            deliver(outcome)
        } else if !box.flushes.isEmpty {
            let flushes = box.flushes
            box.flushes = []
            let superseded = box.superseded
            box.superseded = 0
            let asked = box.lastRequested
            lock.unlock()

            let start = Self.now()
            let landed = backend.frame(of: element)
            let cost = Self.seconds(from: start)

            let outcome = Outcome(handle: handle, generation: generation, asked: asked,
                                  landedSize: landed?.size, landedFrame: landed, cost: cost,
                                  superseded: superseded, succeeded: landed != nil)
            complete(handle, generation: generation, lastKnown: landed)
            lock.lock()
            let completions = claimLocked(flushes)
            lock.unlock()
            deliver(outcome, to: completions)
        } else {
            box.stepScheduled = false
            lock.unlock()
        }
    }

    /// Books a finished step: advances the window's known frame and either takes the next turn or hands
    /// the queue back. A box that has been cancelled — or forgotten and begun again — is simply gone,
    /// and then this does nothing at all.
    private func complete(_ handle: WindowHandle, generation: Int, lastKnown: CGRect?) {
        lock.lock()
        guard let box = boxes[handle], box.generation == generation else { lock.unlock(); return }
        if let lastKnown { box.lastKnown = lastKnown }
        box.touched = Self.now()
        var work: (() -> Void)?
        if box.isIdleAfterStep {
            box.stepScheduled = false
        } else {
            work = rescheduleLocked(handle, generation: generation)
        }
        lock.unlock()
        work?()
    }

    // MARK: - Scheduling (all callers hold the lock)

    /// The window's slot, made on first use. `requesting` is the frame the caller is asking for right
    /// now — `begin`'s seed or a post's frame — which is what `Outcome.asked` reports on a flush, so it
    /// is recorded on every call and not only when the box is made.
    private func mailboxLocked(for handle: WindowHandle, requesting frame: CGRect) -> Mailbox {
        if let box = boxes[handle] {
            box.lastRequested = frame
            return box
        }
        generations += 1
        let box = Mailbox(generation: generations, requested: frame, touched: Self.now())
        boxes[handle] = box
        return box
    }

    /// Marks every flush that has not answered yet and hands back their completions. Whoever calls this
    /// first owns those answers; the losers hand back nothing and stay silent.
    private func claimLocked(_ flushes: [Flush]) -> [@MainActor (Outcome?) -> Void] {
        flushes.compactMap { flush in
            guard !flush.answered else { return nil }
            flush.answered = true
            return flush.completion
        }
    }

    /// A pid's queue, made on first use and then kept for the app's lifetime. Keeping it is what makes
    /// "one element belongs to one queue" hold across a `cancel`: a queue dropped while a write of a
    /// hung app was still inside it would be replaced by a second queue, and that app would have two
    /// threads writing to it. The table is bounded by the number of *applications* whose windows this
    /// app has ever moved.
    private func queueLocked(for pid: pid_t) -> DispatchQueue {
        if let queue = queues[pid] { return queue }
        let queue = DispatchQueue(label: "dev.rubens.SnappySnap.write.\(pid)", qos: .userInteractive)
        queues[pid] = queue
        return queue
    }

    /// Hands back the dispatch to make once the lock is released, or nil when a step is already on its
    /// way. Dispatching outside the lock keeps the lock's hold time to a few instructions, which is what
    /// makes `post` free for the main thread.
    private func scheduleLocked(_ box: Mailbox, _ handle: WindowHandle) -> (() -> Void)? {
        guard !box.stepScheduled else { return nil }
        box.stepScheduled = true
        return rescheduleLocked(handle, generation: box.generation)
    }

    private func rescheduleLocked(_ handle: WindowHandle, generation: Int) -> () -> Void {
        let queue = queueLocked(for: handle.pid)
        return { queue.async { [self] in step(handle, generation: generation) } }
    }

    /// Drops the mailboxes nobody is writing to any more. Offered by `begin`, `post` and `flush` alike —
    /// a consumer that only ever posts is legal, and retirement must not depend on which entry point it
    /// happens to use — and rate-limited to `sweepInterval` so the 120 Hz post path walks the table
    /// about once in six hundred posts rather than on every one.
    private func sweepLocked(keeping handle: WindowHandle) {
        let now = Self.now()
        guard Self.seconds(from: lastSweep, to: now) >= Self.sweepInterval else { return }
        lastSweep = now
        boxes = boxes.filter { key, box in
            key == handle || !box.isIdle || Self.seconds(from: box.touched, to: now) < Self.staleAfter
        }
    }

    // MARK: - Delivery

    private func deliver(_ outcome: Outcome) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { onOutcome?(outcome) }
        }
    }

    private func deliver(_ outcome: Outcome?, to flushes: [@MainActor (Outcome?) -> Void]) {
        guard !flushes.isEmpty else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for flush in flushes { flush(outcome) }
            }
        }
    }

    // MARK: - Pure rules

    /// Which writes happen, and in what order: **size first unless the frame grows on some axis.**
    ///
    /// The intermediate frame between the two writes is visible — at 8 Hz it is 20–40 pt wide, at
    /// 81 Hz 2–5 pt — and this order keeps it inside the union of the old and the new frame: never
    /// outside the screen, never over a neighbour. Position first while the frame still has its old,
    /// larger size would run the far edge past where it belongs and, for a window at the right or the
    /// bottom of the display, off it — where macOS clamps the position, the size write then lands at
    /// the clamped origin, and the far edge retreats and stays retreated. `current` nil — a window
    /// posted to without a `begin` — writes position first.
    private static func plan(_ request: Request, current: CGRect?) -> [Write] {
        let positionFirst = current.map { request.frame.width > $0.width || request.frame.height > $0.height } ?? true
        var writes: [Write] = []
        if positionFirst {
            if request.writePosition { writes.append(.position) }
            if request.writeSize { writes.append(.size) }
        } else {
            if request.writeSize { writes.append(.size) }
            if request.writePosition { writes.append(.position) }
        }
        return writes
    }

    /// Where the window is after a step that wrote only what its flags allowed — with the read-back
    /// preferred over what was asked for, when there was one.
    private static func landed(_ request: Request, current: CGRect?, size: CGSize?) -> CGRect {
        var frame = current ?? request.frame
        if request.writePosition { frame.origin = request.frame.origin }
        if request.writeSize { frame.size = request.frame.size }
        if let size { frame.size = size }
        return frame
    }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    private static func seconds(from start: UInt64, to end: UInt64 = DispatchTime.now().uptimeNanoseconds) -> TimeInterval {
        end > start ? Double(end - start) / 1e9 : 0
    }

    // MARK: - The real back end

    private struct AXBackend: Backend {
        func setPosition(_ p: CGPoint, of element: AXUIElement) -> Bool {
            AX.set(element, kAXPositionAttribute, point: p)
        }

        func setSize(_ s: CGSize, of element: AXUIElement) -> Bool {
            AX.set(element, kAXSizeAttribute, size: s)
        }

        func size(of element: AXUIElement) -> CGSize? { AX.size(element, kAXSizeAttribute) }

        /// Two round trips, like `AccessibilityWindows.frame(of:)` — `AXFrame` is not a public constant
        /// and, measured, not settable on any app tested.
        func frame(of element: AXUIElement) -> CGRect? {
            guard let p = AX.point(element, kAXPositionAttribute),
                  let s = AX.size(element, kAXSizeAttribute) else { return nil }
            return CGRect(origin: p, size: s)
        }
    }
}
