import ApplicationServices
import CoreGraphics
import Foundation
import Testing

@testable import SystemAdapters

// MARK: - Test doubles

/// Opens once and stays open. A worker parked on `wait` is how these tests hold a pid's queue still
/// while the main thread keeps posting — the one thing the writer exists to make survivable.
private final class Latch: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false

    @discardableResult
    func wait(timeout: TimeInterval = 10) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !isOpen {
            if !condition.wait(until: deadline) { return false }
        }
        return true
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }
}

/// A rendezvous for `parties` threads. Two writes that must meet inside the backend can only meet if
/// they are running at the same time, so this proves cross-pid concurrency without measuring a clock —
/// the timing test alongside it is the measurement, this one is the proof.
private final class Barrier: @unchecked Sendable {
    private let condition = NSCondition()
    private let parties: Int
    private var arrived = 0
    private var timedOut = false

    init(parties: Int) { self.parties = parties }

    @discardableResult
    func arrive(timeout: TimeInterval = 3) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        arrived += 1
        if arrived >= parties {
            condition.broadcast()
            return true
        }
        let deadline = Date().addingTimeInterval(timeout)
        while arrived < parties {
            if !condition.wait(until: deadline) {
                timedOut = true
                return false
            }
        }
        return true
    }

    var didTimeOut: Bool {
        condition.lock()
        defer { condition.unlock() }
        return timedOut
    }
}

/// A `WindowWriter.Backend` that never touches Accessibility. It records every call at the moment it
/// is entered (so a test can see a blocked write while it is still blocked), stamps its exit, can be
/// held on a latch, delayed, or made to meet another thread at a barrier, and answers with whatever
/// the test chose.
///
/// `@unchecked Sendable`: every stored property is read and written only under `lock`, and the two
/// blocking primitives above are the only things it touches outside it. This is a test double; the
/// plan's one production `@unchecked Sendable` is `WindowWriter` itself.
private final class FakeBackend: WindowWriter.Backend, @unchecked Sendable {
    enum Kind: Sendable, Equatable {
        case setPosition, setSize, readSize, readFrame
    }

    struct Call: Sendable {
        let kind: Kind
        let window: Int
        let pid: pid_t
        let point: CGPoint?
        let size: CGSize?
        let enter: UInt64
        var exit: UInt64 = 0
    }

    private let lock = NSLock()
    private var registry: [(element: AXUIElement, window: Int, pid: pid_t)] = []
    private var record: [Call] = []
    private var latches: [pid_t: Latch] = [:]
    private var delays: [pid_t: TimeInterval] = [:]
    private var rendezvous: Barrier?
    private var active: [pid_t: Int] = [:]
    private var peak: [pid_t: Int] = [:]
    private var positionSucceeds = true
    private var sizeSucceeds = true
    private var frames: [Int: CGRect] = [:]
    private var sizes: [Int: CGSize] = [:]
    private var writtenOrigins: [Int: CGPoint] = [:]
    private var writtenSizes: [Int: CGSize] = [:]

    // MARK: setup

    func register(_ element: AXUIElement, window: Int, pid: pid_t) {
        lock.lock()
        registry.append((element, window, pid))
        lock.unlock()
    }

    /// Writes for `pid` park until `release(pid:)`. Reads are never held: a flush read must be able to
    /// answer while some other pid is stuck.
    func hold(pid: pid_t) {
        lock.lock()
        latches[pid] = Latch()
        lock.unlock()
    }

    func release(pid: pid_t) {
        lock.lock()
        let latch = latches.removeValue(forKey: pid)
        lock.unlock()
        latch?.open()
    }

    func delay(_ seconds: TimeInterval, pid: pid_t) {
        lock.lock()
        delays[pid] = seconds
        lock.unlock()
    }

    func meetAtBarrier(_ barrier: Barrier) {
        lock.lock()
        rendezvous = barrier
        lock.unlock()
    }

    func results(position: Bool, size: Bool) {
        lock.lock()
        positionSucceeds = position
        sizeSucceeds = size
        lock.unlock()
    }

    /// Without an override, `frame(of:)` answers with what was last written to the window — which is
    /// what a healthy app would do, and what lets a test tell *which* frame a flush read.
    func answer(frame: CGRect, window: Int) {
        lock.lock()
        frames[window] = frame
        lock.unlock()
    }

    func answer(size: CGSize, window: Int) {
        lock.lock()
        sizes[window] = size
        lock.unlock()
    }

    // MARK: observation

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return record
    }

    func calls(window: Int) -> [Call] { calls.filter { $0.window == window } }

    func kinds(window: Int) -> [Kind] { calls(window: window).map(\.kind) }

    func peakConcurrency(pid: pid_t) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return peak[pid] ?? 0
    }

    /// True when two completed calls of one pid were ever inside the backend at the same time. The belt
    /// to `peakConcurrency`'s braces: it looks at the recorded intervals rather than a live counter.
    func callsOverlapped(pid: pid_t) -> Bool {
        let own = calls.filter { $0.pid == pid && $0.exit != 0 }
        for i in own.indices {
            for j in own.indices where j > i {
                if own[i].enter < own[j].exit && own[j].enter < own[i].exit { return true }
            }
        }
        return false
    }

    // MARK: WindowWriter.Backend

    func setPosition(_ p: CGPoint, of element: AXUIElement) -> Bool {
        let (index, pid) = enter(.setPosition, element, point: p, size: nil)
        park(pid: pid)
        lock.lock()
        let ok = positionSucceeds
        if ok { writtenOrigins[record[index].window] = p }
        lock.unlock()
        leave(index, pid: pid)
        return ok
    }

    func setSize(_ s: CGSize, of element: AXUIElement) -> Bool {
        let (index, pid) = enter(.setSize, element, point: nil, size: s)
        park(pid: pid)
        lock.lock()
        let ok = sizeSucceeds
        if ok { writtenSizes[record[index].window] = s }
        lock.unlock()
        leave(index, pid: pid)
        return ok
    }

    func size(of element: AXUIElement) -> CGSize? {
        let (index, pid) = enter(.readSize, element, point: nil, size: nil)
        lock.lock()
        let window = record[index].window
        let answer = sizes[window] ?? frames[window]?.size
        lock.unlock()
        leave(index, pid: pid)
        return answer
    }

    func frame(of element: AXUIElement) -> CGRect? {
        let (index, pid) = enter(.readFrame, element, point: nil, size: nil)
        lock.lock()
        let window = record[index].window
        var answer = frames[window]
        if answer == nil, let origin = writtenOrigins[window], let size = writtenSizes[window] {
            answer = CGRect(origin: origin, size: size)
        }
        lock.unlock()
        leave(index, pid: pid)
        return answer
    }

    // MARK: internals

    private func enter(_ kind: Kind, _ element: AXUIElement, point: CGPoint?, size: CGSize?) -> (Int, pid_t) {
        lock.lock()
        let match = registry.first { CFEqual($0.element, element) }
        let window = match?.window ?? -1
        let pid = match?.pid ?? -1
        let count = (active[pid] ?? 0) + 1
        active[pid] = count
        peak[pid] = max(peak[pid] ?? 0, count)
        record.append(Call(kind: kind, window: window, pid: pid, point: point, size: size,
                           enter: DispatchTime.now().uptimeNanoseconds))
        let index = record.count - 1
        lock.unlock()
        return (index, pid)
    }

    /// Held outside the lock: the point of the latch is to stall one pid's worker without stalling the
    /// main thread's next post, and a post that had to take this lock would stall with it.
    private func park(pid: pid_t) {
        lock.lock()
        let latch = latches[pid]
        let pause = delays[pid]
        let barrier = rendezvous
        lock.unlock()
        latch?.wait()
        barrier?.arrive()
        if let pause, pause > 0 { Thread.sleep(forTimeInterval: pause) }
    }

    private func leave(_ index: Int, pid: pid_t) {
        lock.lock()
        record[index].exit = DispatchTime.now().uptimeNanoseconds
        active[pid] = (active[pid] ?? 1) - 1
        lock.unlock()
    }
}

/// A window the writer can be given without Accessibility ever being asked about it. The element is
/// real (`AXUIElementCreateApplication`) because `WindowHandle` hashes on `CFHash`, but nothing ever
/// calls AX on it; a distinct `element` pid per window is what makes two windows of one *handle* pid
/// distinct keys.
private struct FakeWindow {
    let index: Int
    let element: AXUIElement
    let handle: WindowHandle

    init(_ index: Int, pid: pid_t) {
        self.index = index
        element = AXUIElementCreateApplication(pid_t(9000 + index))
        handle = WindowHandle(element: element, pid: pid, windowID: CGWindowID(index))
    }
}

@MainActor private final class Collector {
    var outcomes: [WindowWriter.Outcome] = []
    var allOnMain = true

    func attach(to writer: WindowWriter) {
        writer.onOutcome = { [self] outcome in
            if !Thread.isMainThread { allOnMain = false }
            outcomes.append(outcome)
        }
    }

    func outcomes(for window: FakeWindow) -> [WindowWriter.Outcome] {
        outcomes.filter { $0.handle == window.handle }
    }
}

/// Polls on the main actor without ever blocking it — a blocked main thread would stop the main queue
/// draining and the writer delivers everything there, so a `semaphore.wait()` in a test would deadlock
/// the thing it is testing.
@MainActor private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

/// A flush answer parked somewhere a test can look at it later, for the cases that have to observe the
/// completion *not* arriving before something else happens.
@MainActor private final class FlushResult {
    private(set) var arrived = false
    private(set) var count = 0
    private(set) var outcome: WindowWriter.Outcome?

    func record(_ outcome: WindowWriter.Outcome?) {
        self.outcome = outcome
        arrived = true
        count += 1
    }
}

@MainActor private func flushed(_ writer: WindowWriter, _ window: FakeWindow) async -> WindowWriter.Outcome? {
    await withCheckedContinuation { continuation in
        writer.flush(window.handle) { continuation.resume(returning: $0) }
    }
}

private func makeWriter(_ backend: FakeBackend) -> WindowWriter { WindowWriter(backend: backend) }

// MARK: - Tests

/// Everything here runs against `FakeBackend`; no Accessibility, no window, no
/// permission. `.serialized` because two of these measure wall time and one counts threads.
@Suite(.serialized) @MainActor struct WindowWriterTests {

    /// The premise of every test below: two windows of one pid are two keys. `WindowHandle` compares by
    /// `CFEqual` on the element, so a fake that reused one element would be testing one mailbox twice.
    @Test func twoFakeWindowsOfOnePidAreDistinctHandles() {
        let a = FakeWindow(0, pid: 100)
        let b = FakeWindow(1, pid: 100)
        #expect(a.handle != b.handle)
        #expect(a.handle.pid == b.handle.pid)
    }

    // MARK: latest wins

    /// Ten posts to a window whose pid's queue is held still by a sibling window's write: one write,
    /// the last frame, and the nine posts it replaced counted on the outcome.
    @Test func tenPostsToABlockedWindowCollapseToOneWriteOfTheLastFrame() async throws {
        let backend = FakeBackend()
        let writer = makeWriter(backend)
        let collector = Collector()
        collector.attach(to: writer)

        let blocker = FakeWindow(0, pid: 100)
        let target = FakeWindow(1, pid: 100)
        backend.register(blocker.element, window: blocker.index, pid: 100)
        backend.register(target.element, window: target.index, pid: 100)
        backend.answer(frame: CGRect(x: 0, y: 0, width: 100, height: 100), window: target.index)
        backend.hold(pid: 100)
        defer { backend.release(pid: 100) }

        writer.begin(blocker.handle, current: CGRect(x: 0, y: 0, width: 400, height: 400))
        writer.begin(target.handle, current: CGRect(x: 0, y: 0, width: 400, height: 400))

        // The sibling's write takes the pid's one queue and parks on the latch.
        writer.post(WindowWriter.Request(frame: CGRect(x: 0, y: 0, width: 380, height: 400)), to: blocker.handle)
        #expect(await waitUntil { backend.calls(window: blocker.index).count == 1 })

        var last = CGRect.zero
        for step in 1...10 {
            last = CGRect(x: CGFloat(step), y: 0, width: 400 - CGFloat(step), height: 400)
            writer.post(WindowWriter.Request(frame: last), to: target.handle)
        }
        #expect(backend.calls(window: target.index).isEmpty, "nothing may be written while the queue is held")
        #expect(writer.hasPending(target.handle))

        backend.release(pid: 100)
        let outcome = try #require(await flushed(writer, target))

        let written = backend.calls(window: target.index).filter { $0.kind == .setPosition || $0.kind == .setSize }
        #expect(written.count == 2, "one write pass, not ten")
        // What the pass wrote, not the order — order has its own tests below; this one is about ten
        // posts collapsing to one frame.
        #expect(written.compactMap(\.point) == [last.origin])
        #expect(written.compactMap(\.size) == [last.size])

        let applied = collector.outcomes(for: target)
        let one = try #require(applied.first)
        #expect(applied.count == 1)
        #expect(one.superseded == 9)
        #expect(one.asked == last)
        #expect(outcome.landedFrame == CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    // MARK: per-pid serial, cross-pid concurrent

    @Test func twoWindowsOfOnePidNeverWriteAtTheSameTime() async throws {
        let backend = FakeBackend()
        let writer = makeWriter(backend)

        let a = FakeWindow(0, pid: 100)
        let b = FakeWindow(1, pid: 100)
        for window in [a, b] {
            backend.register(window.element, window: window.index, pid: 100)
            backend.answer(frame: CGRect(x: 0, y: 0, width: 200, height: 200), window: window.index)
            writer.begin(window.handle, current: CGRect(x: 0, y: 0, width: 400, height: 400))
        }
        backend.delay(0.005, pid: 100)

        for step in 0..<5 {
            for window in [a, b] {
                writer.post(WindowWriter.Request(frame: CGRect(x: 0, y: 0, width: 400 - CGFloat(step), height: 400)),
                            to: window.handle)
            }
        }
        _ = await flushed(writer, a)
        _ = await flushed(writer, b)

        #expect(backend.peakConcurrency(pid: 100) == 1)
        #expect(!backend.callsOverlapped(pid: 100))
    }

    /// The proof, without a clock: each write must meet the other inside the backend. Two writes can
    /// only meet if they are running at once, and a serialised writer would time the barrier out.
    @Test func writesToTwoPidsRunAtTheSameTime() async throws {
        let backend = FakeBackend()
        let writer = makeWriter(backend)

        let a = FakeWindow(0, pid: 100)
        let b = FakeWindow(1, pid: 200)
        backend.register(a.element, window: a.index, pid: 100)
        backend.register(b.element, window: b.index, pid: 200)
        for window in [a, b] {
            backend.answer(frame: CGRect(x: 0, y: 0, width: 200, height: 200), window: window.index)
            writer.begin(window.handle, current: CGRect(x: 0, y: 0, width: 400, height: 400))
        }
        let barrier = Barrier(parties: 2)
        backend.meetAtBarrier(barrier)

        let request = WindowWriter.Request(frame: CGRect(x: 0, y: 0, width: 380, height: 400), writeSize: false)
        writer.post(request, to: a.handle)
        writer.post(request, to: b.handle)

        let first = try #require(await flushed(writer, a))
        let second = try #require(await flushed(writer, b))
        #expect(!barrier.didTimeOut, "the two pids' writes never met: they were serialised")
        #expect(first.succeeded)
        #expect(second.succeeded)
    }

    /// The measurement the design rests on, in miniature: two pids blocking 20 ms each finish in about
    /// 20 ms, not 40. The bound is 35 ms rather than the design's 30 to leave room for a busy machine —
    /// it still separates "overlapped" from "serial" beyond argument.
    @Test func twoBlockedPidsFinishInOneBlockNotTwo() async throws {
        let backend = FakeBackend()
        let writer = makeWriter(backend)

        let a = FakeWindow(0, pid: 100)
        let b = FakeWindow(1, pid: 200)
        backend.register(a.element, window: a.index, pid: 100)
        backend.register(b.element, window: b.index, pid: 200)
        for window in [a, b] {
            backend.answer(frame: CGRect(x: 0, y: 0, width: 200, height: 200), window: window.index)
            writer.begin(window.handle, current: CGRect(x: 0, y: 0, width: 400, height: 400))
        }
        backend.delay(0.020, pid: 100)
        backend.delay(0.020, pid: 200)

        let request = WindowWriter.Request(frame: CGRect(x: 0, y: 0, width: 380, height: 400), writeSize: false)
        let started = DispatchTime.now().uptimeNanoseconds
        writer.post(request, to: a.handle)
        writer.post(request, to: b.handle)
        _ = await flushed(writer, a)
        _ = await flushed(writer, b)
        let wall = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9

        #expect(wall < 0.035, "two 20 ms pids took \(Int(wall * 1000)) ms — they did not overlap")
    }

    // MARK: order

    /// Position first while the frame still has its old, larger size moves the far edge *past* where
    /// it belongs — over the neighbour a divider is shared with and, for the right or bottom window of
    /// a pair, off the display, where macOS clamps the position and the far edge is lost for good.
    @Test func shrinkingWritesSizeFirstAndGrowingWritesPositionFirst() async throws {
        let backend = FakeBackend()
        let writer = makeWriter(backend)
        let window = FakeWindow(0, pid: 100)
        backend.register(window.element, window: window.index, pid: 100)
        backend.answer(frame: CGRect(x: 0, y: 0, width: 200, height: 200), window: window.index)
        let current = CGRect(x: 0, y: 0, width: 200, height: 200)

        writer.begin(window.handle, current: current)
        writer.post(WindowWriter.Request(frame: CGRect(x: 20, y: 0, width: 180, height: 200)),
                    to: window.handle)
        _ = await flushed(writer, window)
        #expect(backend.kinds(window: window.index).filter { $0 == .setPosition || $0 == .setSize }
                == [.setSize, .setPosition])

        let grown = FakeWindow(1, pid: 100)
        backend.register(grown.element, window: grown.index, pid: 100)
        backend.answer(frame: CGRect(x: 0, y: 0, width: 200, height: 200), window: grown.index)
        writer.begin(grown.handle, current: current)
        writer.post(WindowWriter.Request(frame: CGRect(x: 0, y: 0, width: 220, height: 200)),
                    to: grown.handle)
        _ = await flushed(writer, grown)
        #expect(backend.kinds(window: grown.index).filter { $0 == .setPosition || $0 == .setSize }
                == [.setPosition, .setSize])
    }

    @Test func sizeGoesFirstOnlyWhenBothDimensionsShrinkOrStay() async throws {
        let backend = FakeBackend()
        let writer = makeWriter(backend)
        let current = CGRect(x: 0, y: 0, width: 200, height: 200)

        let shrinking = FakeWindow(0, pid: 100)
        backend.register(shrinking.element, window: shrinking.index, pid: 100)
        backend.answer(frame: current, window: shrinking.index)
        writer.begin(shrinking.handle, current: current)
        writer.post(WindowWriter.Request(frame: CGRect(x: 10, y: 10, width: 180, height: 180)),
                    to: shrinking.handle)
        _ = await flushed(writer, shrinking)
        #expect(backend.kinds(window: shrinking.index).filter { $0 == .setPosition || $0 == .setSize }
                == [.setSize, .setPosition])

        let mixed = FakeWindow(1, pid: 100)
        backend.register(mixed.element, window: mixed.index, pid: 100)
        backend.answer(frame: current, window: mixed.index)
        writer.begin(mixed.handle, current: current)
        writer.post(WindowWriter.Request(frame: CGRect(x: 0, y: 0, width: 220, height: 180)),
                    to: mixed.handle)
        _ = await flushed(writer, mixed)
        #expect(backend.kinds(window: mixed.index).filter { $0 == .setPosition || $0 == .setSize }
                == [.setPosition, .setSize])
    }

    @Test func theFlagsDecideWhichOfTheTwoWritesHappensAtAll() async throws {
        let backend = FakeBackend()
        let writer = makeWriter(backend)
        let current = CGRect(x: 0, y: 0, width: 200, height: 200)

        let moved = FakeWindow(0, pid: 100)
        backend.register(moved.element, window: moved.index, pid: 100)
        backend.answer(frame: current, window: moved.index)
        writer.begin(moved.handle, current: current)
        writer.post(WindowWriter.Request(frame: CGRect(x: 40, y: 0, width: 200, height: 200), writeSize: false),
                    to: moved.handle)
        _ = await flushed(writer, moved)
        #expect(backend.kinds(window: moved.index) == [.setPosition, .readFrame])

        let resized = FakeWindow(1, pid: 100)
        backend.register(resized.element, window: resized.index, pid: 100)
        backend.answer(frame: current, window: resized.index)
        writer.begin(resized.handle, current: current)
        writer.post(WindowWriter.Request(frame: CGRect(x: 0, y: 0, width: 180, height: 200), writePosition: false),
                    to: resized.handle)
        _ = await flushed(writer, resized)
        #expect(backend.kinds(window: resized.index) == [.setSize, .readFrame])
    }

    @Test func readBackRidesTheWorkerAndComesHomeAsLandedSize() async throws {
        let backend = FakeBackend()
        let writer = makeWriter(backend)
        let collector = Collector()
        collector.attach(to: writer)
        let window = FakeWindow(0, pid: 100)
        backend.register(window.element, window: window.index, pid: 100)
        backend.answer(frame: CGRect(x: 0, y: 0, width: 200, height: 200), window: window.index)
        backend.answer(size: CGSize(width: 300, height: 200), window: window.index)

        writer.begin(window.handle, current: CGRect(x: 0, y: 0, width: 400, height: 400))
        writer.post(WindowWriter.Request(frame: CGRect(x: 0, y: 0, width: 180, height: 200), readBack: true),
                    to: window.handle)
        #expect(await waitUntil { !collector.outcomes(for: window).isEmpty })

        let outcome = try #require(collector.outcomes(for: window).first)
        #expect(outcome.landedSize == CGSize(width: 300, height: 200))
        #expect(backend.kinds(window: window.index).contains(.readSize))
    }

    // MARK: flush semantics

    @Test func flushCompletesAfterTheLastFrameLandedAndCarriesTheFrameItRead() async throws {
        let backend = FakeBackend()
        let writer = makeWriter(backend)
        let window = FakeWindow(0, pid: 100)
        backend.register(window.element, window: window.index, pid: 100)
        let landed = CGRect(x: 7, y: 8, width: 123, height: 456)
        backend.answer(frame: landed, window: window.index)

        writer.begin(window.handle, current: CGRect(x: 0, y: 0, width: 400, height: 400))
        for step in 1...4 {
            writer.post(WindowWriter.Request(frame: CGRect(x: CGFloat(step), y: 0, width: 400, height: 400)),
                        to: window.handle)
        }
        let outcome = try #require(await flushed(writer, window))

        #expect(outcome.landedFrame == landed)
        #expect(outcome.landedSize == landed.size)
        #expect(!writer.hasPending(window.handle))
        let kinds = backend.kinds(window: window.index)
        #expect(kinds.last == .readFrame, "the read must come after the last write")
        #expect(kinds.filter { $0 == .readFrame }.count == 1)
    }

    @Test func flushWithNothingPendingReadsAndAnswersAnyway() async throws {
        let backend = FakeBackend()
        let writer = makeWriter(backend)
        let window = FakeWindow(0, pid: 100)
        backend.register(window.element, window: window.index, pid: 100)
        let landed = CGRect(x: 1, y: 2, width: 3, height: 4)
        backend.answer(frame: landed, window: window.index)

        writer.begin(window.handle, current: CGRect(x: 0, y: 0, width: 400, height: 400))
        let outcome = try #require(await flushed(writer, window))
        #expect(outcome.landedFrame == landed)
        #expect(backend.kinds(window: window.index) == [.readFrame])
    }

    @Test func cancelThenFlushIsNil() async throws {
        let backend = FakeBackend()
        let writer = makeWriter(backend)
        let window = FakeWindow(0, pid: 100)
        backend.register(window.element, window: window.index, pid: 100)
        backend.answer(frame: .zero, window: window.index)

        writer.begin(window.handle, current: CGRect(x: 0, y: 0, width: 400, height: 400))
        writer.cancel(window.handle)
        let outcome = await flushed(writer, window)
        #expect(outcome == nil)
        #expect(backend.calls.isEmpty)
    }

    @Test func cancelFailsTheFlushThatWasAlreadyWaiting() async throws {
        let backend = FakeBackend()
        let writer = makeWriter(backend)
        let window = FakeWindow(0, pid: 100)
        let other = FakeWindow(1, pid: 100)
        backend.register(window.element, window: window.index, pid: 100)
        backend.register(other.element, window: other.index, pid: 100)
        backend.answer(frame: .zero, window: window.index)
        backend.hold(pid: 100)
        defer { backend.release(pid: 100) }

        writer.begin(other.handle, current: CGRect(x: 0, y: 0, width: 400, height: 400))
        writer.begin(window.handle, current: CGRect(x: 0, y: 0, width: 400, height: 400))
        writer.post(WindowWriter.Request(frame: CGRect(x: 0, y: 0, width: 380, height: 400)), to: other.handle)
        #expect(await waitUntil { backend.calls(window: other.index).count == 1 })

        writer.post(WindowWriter.Request(frame: CGRect(x: 0, y: 0, width: 380, height: 400)), to: window.handle)
        let waiting = FlushResult()
        writer.flush(window.handle) { [waiting] outcome in waiting.record(outcome) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!waiting.arrived, "the flush cannot answer while the window's write is still queued")

        writer.cancel(window.handle)
        #expect(await waitUntil { waiting.arrived })
        #expect(waiting.outcome == nil)
        #expect(backend.calls(window: window.index).isEmpty, "the cancelled window's pending frame was dropped")
    }

    @Test func aWindowTheWriterWasNeverGivenFlushesToNil() async throws {
        let backend = FakeBackend()
        let writer = makeWriter(backend)
        let window = FakeWindow(0, pid: 100)
        backend.register(window.element, window: window.index, pid: 100)
        backend.answer(frame: .zero, window: window.index)

        let outcome = await flushed(writer, window)
        #expect(outcome == nil)
        #expect(backend.calls.isEmpty)
    }

    // MARK: outcomes on main

    @Test func everyAppliedWriteComesBackOnTheMainActor() async throws {
        let backend = FakeBackend()
        let writer = makeWriter(backend)
        let collector = Collector()
        collector.attach(to: writer)
        let window = FakeWindow(0, pid: 100)
        backend.register(window.element, window: window.index, pid: 100)
        backend.answer(frame: CGRect(x: 0, y: 0, width: 200, height: 200), window: window.index)

        writer.begin(window.handle, current: CGRect(x: 0, y: 0, width: 400, height: 400))
        writer.post(WindowWriter.Request(frame: CGRect(x: 0, y: 0, width: 380, height: 400)), to: window.handle)
        _ = await flushed(writer, window)

        let outcome = try #require(collector.outcomes(for: window).first)
        #expect(collector.allOnMain)
        #expect(outcome.cost >= 0)
        #expect(outcome.succeeded)
        #expect(outcome.asked == CGRect(x: 0, y: 0, width: 380, height: 400))
        #expect(outcome.handle == window.handle)
    }

    @Test func aBackendThatRefusesAWriteIsReportedAsFailure() async throws {
        let backend = FakeBackend()
        let writer = makeWriter(backend)
        let collector = Collector()
        collector.attach(to: writer)
        let window = FakeWindow(0, pid: 100)
        backend.register(window.element, window: window.index, pid: 100)
        backend.answer(frame: CGRect(x: 0, y: 0, width: 200, height: 200), window: window.index)
        backend.results(position: true, size: false)

        writer.begin(window.handle, current: CGRect(x: 0, y: 0, width: 400, height: 400))
        writer.post(WindowWriter.Request(frame: CGRect(x: 0, y: 0, width: 380, height: 400)), to: window.handle)
        _ = await flushed(writer, window)

        let outcome = try #require(collector.outcomes(for: window).first)
        #expect(!outcome.succeeded)
    }

    /// A flush that cannot land is reported as a failure, so an unreadable frame must not
    /// come home looking like a success.
    @Test func aFlushThatCannotReadTheFrameSaysSoRatherThanAnsweringNil() async throws {
        let backend = FakeBackend()
        let writer = makeWriter(backend)
        let window = FakeWindow(0, pid: 100)
        backend.register(window.element, window: window.index, pid: 100)

        writer.begin(window.handle, current: CGRect(x: 0, y: 0, width: 400, height: 400))
        let outcome = try #require(await flushed(writer, window))
        #expect(outcome.landedFrame == nil)
        #expect(!outcome.succeeded)
    }

    // MARK: never blocks the caller

    @Test func postReturnsWhileTheBackendIsStillBlocked() async throws {
        let backend = FakeBackend()
        let writer = makeWriter(backend)
        let window = FakeWindow(0, pid: 100)
        backend.register(window.element, window: window.index, pid: 100)
        backend.answer(frame: .zero, window: window.index)
        backend.hold(pid: 100)
        defer { backend.release(pid: 100) }

        writer.begin(window.handle, current: CGRect(x: 0, y: 0, width: 400, height: 400))
        writer.post(WindowWriter.Request(frame: CGRect(x: 0, y: 0, width: 380, height: 400)), to: window.handle)
        #expect(await waitUntil { backend.calls(window: window.index).count == 1 })

        var worst: Double = 0
        for step in 1...20 {
            let started = DispatchTime.now().uptimeNanoseconds
            writer.post(WindowWriter.Request(frame: CGRect(x: CGFloat(step), y: 0, width: 380, height: 400)),
                        to: window.handle)
            worst = max(worst, Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9)
        }
        // Measured at 0.01 ms; the bound is three orders of magnitude looser and still proves the post
        // did not wait for a backend that is parked indefinitely.
        #expect(worst < 0.010, "slowest post took \(worst * 1000) ms")
    }

    // MARK: a hung pid blocks only itself

    @Test func aHungPidStopsNothingButItsOwnWindowsAndCancelDoesNotWaitForIt() async throws {
        let backend = FakeBackend()
        let writer = makeWriter(backend)
        let collector = Collector()
        collector.attach(to: writer)

        let hung = FakeWindow(0, pid: 100)
        let healthy = FakeWindow(1, pid: 200)
        backend.register(hung.element, window: hung.index, pid: 100)
        backend.register(healthy.element, window: healthy.index, pid: 200)
        backend.answer(frame: CGRect(x: 0, y: 0, width: 200, height: 200), window: healthy.index)
        backend.answer(frame: CGRect(x: 0, y: 0, width: 200, height: 200), window: hung.index)
        backend.hold(pid: 100)
        defer { backend.release(pid: 100) }

        writer.begin(hung.handle, current: CGRect(x: 0, y: 0, width: 400, height: 400))
        writer.begin(healthy.handle, current: CGRect(x: 0, y: 0, width: 400, height: 400))
        writer.post(WindowWriter.Request(frame: CGRect(x: 0, y: 0, width: 380, height: 400)), to: hung.handle)
        #expect(await waitUntil { backend.calls(window: hung.index).count == 1 })

        for step in 1...5 {
            writer.post(WindowWriter.Request(frame: CGRect(x: 0, y: 0, width: 400 - CGFloat(step), height: 400)),
                        to: healthy.handle)
            #expect(await waitUntil { collector.outcomes(for: healthy).count >= step })
        }
        #expect(collector.outcomes(for: healthy).count >= 5, "the healthy pid kept going")

        writer.cancel(hung.handle)
        let started = DispatchTime.now().uptimeNanoseconds
        let outcome = await flushed(writer, hung)
        let waited = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
        #expect(outcome == nil)
        #expect(waited < 0.5, "the flush waited \(waited) s for a backend that never returned")
    }

    // MARK: hasPending

    @Test func hasPendingIsTrueExactlyWhileTheWriterStillOwesTheWindowSomething() async throws {
        let backend = FakeBackend()
        let writer = makeWriter(backend)
        let blocker = FakeWindow(0, pid: 100)
        let window = FakeWindow(1, pid: 100)
        backend.register(blocker.element, window: blocker.index, pid: 100)
        backend.register(window.element, window: window.index, pid: 100)
        backend.answer(frame: .zero, window: window.index)
        backend.hold(pid: 100)
        defer { backend.release(pid: 100) }

        writer.begin(blocker.handle, current: CGRect(x: 0, y: 0, width: 400, height: 400))
        writer.begin(window.handle, current: CGRect(x: 0, y: 0, width: 400, height: 400))
        #expect(!writer.hasPending(window.handle))

        writer.post(WindowWriter.Request(frame: CGRect(x: 0, y: 0, width: 380, height: 400)), to: blocker.handle)
        #expect(await waitUntil { backend.calls(window: blocker.index).count == 1 })
        writer.post(WindowWriter.Request(frame: CGRect(x: 0, y: 0, width: 380, height: 400)), to: window.handle)
        #expect(writer.hasPending(window.handle))

        backend.release(pid: 100)
        _ = await flushed(writer, window)
        #expect(!writer.hasPending(window.handle))
    }

    // MARK: what `asked` means

    /// `Outcome.asked` is the caller's own frame, never one that came back from the window. A window
    /// that refuses its size or a position macOS clamps must show up as the
    /// difference between `asked` and `landedFrame`, and a second flush must not quietly start
    /// reporting the first flush's read-back as if the caller had asked for it.
    @Test func flushReportsTheFrameTheCallerAskedForAndNotTheOneItRead() async throws {
        let backend = FakeBackend()
        let writer = makeWriter(backend)
        let window = FakeWindow(0, pid: 100)
        backend.register(window.element, window: window.index, pid: 100)
        let stubborn = CGRect(x: 0, y: 0, width: 500, height: 500)
        backend.answer(frame: stubborn, window: window.index)   // whatever it is told, it reads back this

        let asked = CGRect(x: 0, y: 0, width: 380, height: 400)
        writer.begin(window.handle, current: CGRect(x: 0, y: 0, width: 400, height: 400))
        writer.post(WindowWriter.Request(frame: asked), to: window.handle)

        let first = try #require(await flushed(writer, window))
        #expect(first.asked == asked)
        #expect(first.landedFrame == stubborn)

        let second = try #require(await flushed(writer, window))
        #expect(second.asked == asked, "the first flush's read-back became the second flush's `asked`")

        let untouched = FakeWindow(1, pid: 100)
        backend.register(untouched.element, window: untouched.index, pid: 100)
        backend.answer(frame: stubborn, window: untouched.index)
        let seed = CGRect(x: 10, y: 20, width: 300, height: 200)
        writer.begin(untouched.handle, current: seed)
        let seeded = try #require(await flushed(writer, untouched))
        #expect(seeded.asked == seed, "with nothing posted, `asked` is `begin`'s seed")
    }

    // MARK: the flush deadline

    /// A flush behind a pid that has stopped answering gives up at its deadline and says so, and the
    /// write that eventually lands reports through `onOutcome` without answering the completion twice.
    @Test func aFlushGivesUpAtItsDeadlineAndIsNeverAnsweredTwice() async throws {
        let backend = FakeBackend()
        let writer = makeWriter(backend)
        let collector = Collector()
        collector.attach(to: writer)
        let window = FakeWindow(0, pid: 100)
        backend.register(window.element, window: window.index, pid: 100)
        backend.hold(pid: 100)
        defer { backend.release(pid: 100) }

        let asked = CGRect(x: 0, y: 0, width: 380, height: 400)
        writer.begin(window.handle, current: CGRect(x: 0, y: 0, width: 400, height: 400))
        writer.post(WindowWriter.Request(frame: asked), to: window.handle)
        #expect(await waitUntil { backend.calls(window: window.index).count == 1 })

        let result = FlushResult()
        writer.flush(window.handle, deadline: 0.05) { outcome in result.record(outcome) }
        #expect(await waitUntil { result.arrived })

        let timedOut = try #require(result.outcome, "nil means cancelled; a deadline is a failure")
        #expect(!timedOut.succeeded)
        #expect(timedOut.landedFrame == nil)
        #expect(timedOut.landedSize == nil)
        #expect(timedOut.asked == asked)

        backend.release(pid: 100)
        #expect(await waitUntil { collector.outcomes(for: window).count == 1 })
        try await Task.sleep(for: .milliseconds(150))
        #expect(result.count == 1, "the write that finally landed answered the flush a second time")
        #expect(collector.outcomes(for: window).count == 1)
        #expect(!backend.kinds(window: window.index).contains(.readFrame),
                "a flush nobody is waiting for must not cost a read")
    }

    /// The other side of the same guard, and the one the consumers actually live on: the flush lands
    /// **first** and the deadline arrives afterwards, into a completion that has already been answered.
    /// Exactly one answer, and it is the one that read the frame — a `succeeded == false` landing on
    /// top of it would tell a caller its window is not where it left it, about a window that is.
    /// A drag whose flush is given a short deadline outlives that deadline by the whole of the next
    /// gesture, so "the timer fires late into a finished flush" is the ordinary case, not the odd one.
    @Test func aDeadlineThatArrivesAfterTheFlushLandedAnswersNothing() async throws {
        let backend = FakeBackend()
        let writer = makeWriter(backend)
        let window = FakeWindow(0, pid: 100)
        backend.register(window.element, window: window.index, pid: 100)
        let asked = CGRect(x: 10, y: 20, width: 300, height: 200)
        backend.answer(frame: asked, window: window.index)

        writer.begin(window.handle, current: CGRect(x: 10, y: 20, width: 400, height: 200))
        writer.post(WindowWriter.Request(frame: asked), to: window.handle)

        let result = FlushResult()
        writer.flush(window.handle, deadline: 0.2) { outcome in result.record(outcome) }
        #expect(await waitUntil { result.arrived })

        let landed = try #require(result.outcome, "nothing cancelled this flush")
        #expect(landed.succeeded)
        #expect(landed.landedFrame == asked)

        // Outlive the deadline: the timer fires into a flush that answered long before it.
        try await Task.sleep(for: .milliseconds(350))
        #expect(result.count == 1, "the deadline answered a flush that had already landed")
        #expect(result.outcome?.succeeded == true, "and it did not overwrite the answer with a failure")
    }

    // MARK: a begin that arrives mid-write

    /// The seed wins over the bookkeeping of a write that was already running: the next post's order is
    /// decided against 100×100, not against the 380×400 the parked write was pushing. The two
    /// hypotheses give opposite orders, which is what makes this test able to fail.
    @Test func aBeginDuringAWriteWinsOverThatWritesBookkeeping() async throws {
        let backend = FakeBackend()
        let writer = makeWriter(backend)
        let collector = Collector()
        collector.attach(to: writer)
        let window = FakeWindow(0, pid: 100)
        backend.register(window.element, window: window.index, pid: 100)
        backend.hold(pid: 100)
        defer { backend.release(pid: 100) }

        writer.begin(window.handle, current: CGRect(x: 0, y: 0, width: 400, height: 400))
        writer.post(WindowWriter.Request(frame: CGRect(x: 0, y: 0, width: 380, height: 400)), to: window.handle)
        #expect(await waitUntil { backend.calls(window: window.index).count == 1 })

        writer.begin(window.handle, current: CGRect(x: 0, y: 0, width: 100, height: 100))
        backend.release(pid: 100)
        #expect(await waitUntil { collector.outcomes(for: window).count == 1 })

        writer.post(WindowWriter.Request(frame: CGRect(x: 0, y: 0, width: 200, height: 200)), to: window.handle)
        _ = await flushed(writer, window)

        #expect(backend.kinds(window: window.index).filter { $0 == .setPosition || $0 == .setSize }
                == [.setSize, .setPosition, .setPosition, .setSize],
                "the second pass grew from the seed; size-first would mean the parked write's frame won")
    }

    // MARK: an outcome says which gesture it belongs to

    /// The write that outlives its gesture is the reason `Outcome.generation` exists. `begin` does not
    /// suppress a write already inside Accessibility, and a flush that gives up at its deadline ends
    /// the gesture while that write is still running — so the outcome arrives after a second `begin`
    /// for the same window, and `WindowHandle` compares equal for both. Here the parked write reports
    /// the **first** generation and the post made after the second `begin` reports the **second**, so a
    /// consumer comparing against what `begin` returned can drop exactly the stale one.
    @Test func anOutcomeCarriesTheGenerationOfTheBeginItWasPostedUnder() async throws {
        let backend = FakeBackend()
        let writer = makeWriter(backend)
        let collector = Collector()
        collector.attach(to: writer)
        let window = FakeWindow(0, pid: 100)
        backend.register(window.element, window: window.index, pid: 100)
        backend.hold(pid: 100)
        defer { backend.release(pid: 100) }

        let first = writer.begin(window.handle, current: CGRect(x: 0, y: 0, width: 400, height: 400))
        writer.post(WindowWriter.Request(frame: CGRect(x: 0, y: 0, width: 380, height: 400)), to: window.handle)
        #expect(await waitUntil { backend.calls(window: window.index).count == 1 })

        let second = writer.begin(window.handle, current: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(second != first, "every begin opens a gesture of its own, running step or not")

        backend.release(pid: 100)
        #expect(await waitUntil { collector.outcomes(for: window).count == 1 })
        #expect(collector.outcomes(for: window)[0].generation == first,
                "the parked write was posted under the first gesture and must still say so")

        writer.post(WindowWriter.Request(frame: CGRect(x: 0, y: 0, width: 200, height: 200)), to: window.handle)
        let flushOutcome = try #require(await flushed(writer, window))
        let outcomes = collector.outcomes(for: window)
        #expect(outcomes.count == 2)
        #expect(outcomes[1].generation == second, "a post after the second begin belongs to it")
        #expect(flushOutcome.generation == second, "and so does the flush registered under it")

        // Nothing is running now, and the generation must still move: an outcome can be sitting on the
        // main queue while the mailbox is already idle, and a `begin` that left the number alone would
        // hand the next gesture an identity the previous one's last write also carries.
        let third = writer.begin(window.handle, current: CGRect(x: 0, y: 0, width: 200, height: 200))
        #expect(third != second, "a begin over an idle mailbox opens a gesture too")
    }

    // MARK: two behaviours other code relies on

    /// The flush answers after the LAST posted frame lands: a post that arrives after the flush
    /// was registered, while the previous write is still in flight, is still written first, and the
    /// frame the flush reports is that new one.
    @Test func aPostRegisteredAfterAFlushStillLandsBeforeTheFlushAnswers() async throws {
        let backend = FakeBackend()
        let writer = makeWriter(backend)
        let window = FakeWindow(0, pid: 100)
        backend.register(window.element, window: window.index, pid: 100)   // no override: it reads back what it was given
        backend.hold(pid: 100)
        defer { backend.release(pid: 100) }

        let first = CGRect(x: 0, y: 0, width: 380, height: 400)
        let second = CGRect(x: 0, y: 0, width: 360, height: 400)
        writer.begin(window.handle, current: CGRect(x: 0, y: 0, width: 400, height: 400))
        writer.post(WindowWriter.Request(frame: first), to: window.handle)
        #expect(await waitUntil { backend.calls(window: window.index).count == 1 })

        let result = FlushResult()
        writer.flush(window.handle) { outcome in result.record(outcome) }
        writer.post(WindowWriter.Request(frame: second), to: window.handle)
        #expect(!result.arrived)

        backend.release(pid: 100)
        #expect(await waitUntil { result.arrived })

        let outcome = try #require(result.outcome)
        #expect(outcome.landedFrame == second)
        #expect(outcome.asked == second)
        #expect(backend.kinds(window: window.index)
                == [.setSize, .setPosition, .setSize, .setPosition, .readFrame])
    }

    /// `cancel` during a write: the write finishes and still reports once — a cost model that did not
    /// see a write that happened would be lying to itself — while the flush answers nil.
    @Test func cancelDuringAWriteStillReportsThatWriteExactlyOnce() async throws {
        let backend = FakeBackend()
        let writer = makeWriter(backend)
        let collector = Collector()
        collector.attach(to: writer)
        let window = FakeWindow(0, pid: 100)
        backend.register(window.element, window: window.index, pid: 100)
        backend.hold(pid: 100)
        defer { backend.release(pid: 100) }

        writer.begin(window.handle, current: CGRect(x: 0, y: 0, width: 400, height: 400))
        writer.post(WindowWriter.Request(frame: CGRect(x: 0, y: 0, width: 380, height: 400)), to: window.handle)
        #expect(await waitUntil { backend.calls(window: window.index).count == 1 })

        let result = FlushResult()
        writer.flush(window.handle) { outcome in result.record(outcome) }
        writer.cancel(window.handle)
        #expect(await waitUntil { result.arrived })
        #expect(result.outcome == nil)

        backend.release(pid: 100)
        #expect(await waitUntil { collector.outcomes(for: window).count == 1 })
        try await Task.sleep(for: .milliseconds(150))
        #expect(collector.outcomes(for: window).count == 1)
        #expect(result.count == 1)
        #expect(!backend.kinds(window: window.index).contains(.readFrame))
    }

    // MARK: a gesture starts clean

    /// Nothing of the previous gesture survives a `begin`: not a frame posted but never started, not the
    /// count of what it superseded, not a flush still waiting. The first `Outcome` of a gesture is about
    /// that gesture only.
    @Test func beginStartsAGestureCleanAndDropsWhatTheLastOneLeft() async throws {
        let backend = FakeBackend()
        let writer = makeWriter(backend)
        let collector = Collector()
        collector.attach(to: writer)

        let blocker = FakeWindow(0, pid: 100)
        let target = FakeWindow(1, pid: 100)
        backend.register(blocker.element, window: blocker.index, pid: 100)
        backend.register(target.element, window: target.index, pid: 100)
        backend.hold(pid: 100)
        defer { backend.release(pid: 100) }

        writer.begin(blocker.handle, current: CGRect(x: 0, y: 0, width: 400, height: 400))
        writer.begin(target.handle, current: CGRect(x: 0, y: 0, width: 400, height: 400))

        // The sibling takes the pid's one queue, so the target's frames never leave the mailbox.
        writer.post(WindowWriter.Request(frame: CGRect(x: 0, y: 0, width: 380, height: 400)), to: blocker.handle)
        #expect(await waitUntil { backend.calls(window: blocker.index).count == 1 })

        writer.post(WindowWriter.Request(frame: CGRect(x: 0, y: 0, width: 380, height: 400)), to: target.handle)
        writer.post(WindowWriter.Request(frame: CGRect(x: 0, y: 0, width: 360, height: 400)), to: target.handle)
        let orphan = FlushResult()
        writer.flush(target.handle) { outcome in orphan.record(outcome) }
        #expect(backend.calls(window: target.index).isEmpty)

        let seed = CGRect(x: 40, y: 50, width: 200, height: 200)
        writer.begin(target.handle, current: seed)
        #expect(await waitUntil { orphan.arrived })
        #expect(orphan.outcome == nil, "a flush left over from the gesture that ended is cancelled")

        backend.release(pid: 100)
        let afterBegin = try #require(await flushed(writer, target))
        #expect(afterBegin.asked == seed, "the stale frame was still being reported as what was asked for")
        #expect(afterBegin.superseded == 0, "the previous gesture's count leaked into this one")
        #expect(backend.kinds(window: target.index) == [.readFrame], "the dropped frame was written after all")

        let fresh = CGRect(x: 0, y: 0, width: 180, height: 200)
        writer.post(WindowWriter.Request(frame: fresh), to: target.handle)
        let afterPost = try #require(await flushed(writer, target))
        #expect(afterPost.asked == fresh)
        #expect(afterPost.superseded == 0)
        #expect(backend.kinds(window: target.index)
                == [.readFrame, .setSize, .setPosition, .readFrame])
        #expect(collector.outcomes(for: target).count == 1, "exactly one write, and it was the fresh frame")
    }
}
