import AppKit
import ApplicationServices
import SnapCore

/// `_AXUIElementGetWindow`'s C signature, for the pointer `PrivateAPI` hands back. Nothing declares
/// the function itself: a private symbol is never linked. A declaration of it would make the symbol a
/// load-time dependency — the day HIServices drops it, the app would fail to launch rather than fall
/// back.
private typealias AXUIElementGetWindowFunction =
    @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

/// A window of another app. `element` is the AXWindow; `windowID` links it to the CoreGraphics window list.
public struct WindowHandle: Hashable, @unchecked Sendable {
    public let element: AXUIElement
    public let pid: pid_t
    public let windowID: CGWindowID?

    public init(element: AXUIElement, pid: pid_t, windowID: CGWindowID?) {
        self.element = element
        self.pid = pid
        self.windowID = windowID
    }

    public static func == (lhs: WindowHandle, rhs: WindowHandle) -> Bool { CFEqual(lhs.element, rhs.element) }
    public func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

@MainActor
public final class AccessibilityWindows {
    /// Every Accessibility call is a synchronous IPC round trip on the main run loop, which is also
    /// the run loop that services our `CGEventTap`. An app busy in its own drag-tracking loop
    /// would otherwise stall us for the system default, the tap would be disabled by timeout and
    /// mouse events would be lost. Nothing we ask for is worth more than a quarter second.
    public static let messagingTimeout: Float = 0.25

    private let systemWide: AXUIElement

    public init() {
        systemWide = AXUIElementCreateSystemWide()
        // On the system-wide element this is also the process-wide default for elements we do not
        // reach with `bounded(_:)` — the per-element calls below are the belt to this braces.
        bounded(systemWide)
    }

    /// Applies the messaging timeout to an element we just created and hands it back.
    @discardableResult
    private func bounded(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        return element
    }

    /// The window under `point` (CG space), whatever element the point hits inside it.
    public func window(at point: CGPoint) -> WindowHandle? {
        var hit: AXUIElement?
        let answer = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit)
        guard answer == .success, let hit else {
            return answer == .cannotComplete ? nil : listedWindow(at: point)
        }
        bounded(hit)
        let windowElement: AXUIElement
        if AX.string(hit, kAXRoleAttribute) == (kAXWindowRole as String) {
            windowElement = hit
        } else if let w = AX.element(hit, kAXWindowAttribute) {
            windowElement = bounded(w)
        } else {
            return nil
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(windowElement, &pid) == .success else { return nil }
        return WindowHandle(element: windowElement, pid: pid, windowID: identify(windowElement, pid: pid))
    }

    /// The window under `point` by the window list, for a point where the application's own hit test
    /// answers an error: a view that implements no Accessibility hit testing makes
    /// `AXUIElementCopyElementAtPosition` fail over exactly that view (measured on Affinity's title
    /// and tab strip: `notImplemented`, −25208, while the rows above and below it answer the window),
    /// and the press there is a title-bar drag like any other.
    ///
    /// The frontmost listed window containing the point names the pid and the id; the element is the
    /// one of that application's windows carrying the id. That is `1 + N` round trips on the private
    /// route and `1 + 2N` on the public one, against an application that has just answered its hit
    /// test with an error rather than with silence — **`cannotComplete` never reaches here**, because
    /// an application that timed out once would time out on every one of these reads too, and the
    /// sum is past what the event tap survives.
    private func listedWindow(at point: CGPoint) -> WindowHandle? {
        guard let listed = WindowList.snapshot().first(where: { $0.frame.contains(point) }) else { return nil }
        return windows(ofPid: listed.pid).first { $0.windowID == listed.id }
    }

    /// The CoreGraphics id of an element we already hold, by whichever of the two routes is on. This
    /// runs on the tap's run loop, in `DragSessionController.mouseDown`, so what matters here is not
    /// the average cost but the **worst case**.
    ///
    /// - Private route: **one** call, `_AXUIElementGetWindow`.
    /// - Public route: **two** calls — this element's own position and size — then one
    ///   `CGWindowListCopyWindowInfo` copy (0.2–0.3 ms, no round trip, no permission) and pure
    ///   arithmetic in `matchWindowID`.
    ///
    /// So the worst case against a fully hung application is **2 × 0.25 s = 0.50 s**, against 0.25 s on
    /// the private route: slower, which the policy allows, and still well under the measured
    /// 1.00–1.05 s single stall at which the window server disables our event tap, which it does not.
    /// It is deliberately **not** `windows(ofPid:)`: that answers the same question for an element we
    /// already have at `(1 + 2N) × 0.25 s` for an app with N windows — past the tap-disable threshold
    /// from N ≥ 2 — and it makes the id depend on `CFEqual` agreeing between an element from
    /// `AXUIElementCopyElementAtPosition` and one from `kAXWindows`.
    ///
    /// A handle whose `windowID` is nil still drags and still snaps; what it loses is everything keyed
    /// by the id — the pre-snap frame `restoreOnDragAway` reads, the pair cell and the Snap Assist
    /// phase that follows a snap-bar drop. So it is worth two reads to avoid, and no more than that.
    ///
    /// `kAXPosition` + `kAXSize` rather than a single `AXFrame` read: `AXFrame` is not a constant in
    /// any public header, so reading it would be a fourth undocumented interface — one that would owe
    /// `docs/private-api-index.md` a row and `PrivateAPI` a case. Two documented reads cost one extra
    /// round trip and no policy.
    private func identify(_ element: AXUIElement, pid: pid_t) -> CGWindowID? {
        if let getWindow = Self.windowIDFunction { return Self.windowID(of: element, getWindow) }
        guard let p = AX.point(element, kAXPositionAttribute),
              let s = AX.size(element, kAXSizeAttribute) else { return nil }
        return Self.matchWindowID(axFrame: CGRect(origin: p, size: s), listed: WindowList.snapshot(), pid: pid)
    }

    public func frame(of handle: WindowHandle) -> CGRect? {
        guard let p = AX.point(handle.element, kAXPositionAttribute),
              let s = AX.size(handle.element, kAXSizeAttribute) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// Half of `frame(of:)`, for the caller that only wants to know whether a window took the size it
    /// was given. Round trips on the drag path are counted, and a frame read is two of them: the
    /// handle bar's resize asks this of up to two windows on every write pass.
    public func size(of handle: WindowHandle) -> CGSize? { AX.size(handle.element, kAXSizeAttribute) }

    @discardableResult
    public func setPosition(_ p: CGPoint, of handle: WindowHandle) -> Bool { AX.set(handle.element, kAXPositionAttribute, point: p) }

    @discardableResult
    public func setSize(_ s: CGSize, of handle: WindowHandle) -> Bool { AX.set(handle.element, kAXSizeAttribute, size: s) }

    public func title(of handle: WindowHandle) -> String? { AX.string(handle.element, kAXTitleAttribute) }

    public func isResizable(_ handle: WindowHandle) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(handle.element, kAXSizeAttribute as CFString, &settable) == .success && settable.boolValue
    }

    public func isMinimized(_ handle: WindowHandle) -> Bool { AX.bool(handle.element, kAXMinimizedAttribute) ?? false }

    /// Brings the window to the front of its app. False when the action failed — the caller logs that
    /// and carries on, which it cannot do if the error is swallowed here.
    @discardableResult
    public func raise(_ handle: WindowHandle) -> Bool {
        AXUIElementPerformAction(handle.element, kAXRaiseAction as CFString) == .success
    }

    /// Every window an application reports, each carrying the CoreGraphics id that links it to the
    /// window list. **Both routes are here**, and which one runs is decided per call, so the
    /// Compatibility switch takes effect without a relaunch.
    ///
    /// - The private route asks `_AXUIElementGetWindow` (HIServices) for each element's id: one call
    ///   per window, exact, and it answers for a window the list does not carry — minimised, on
    ///   another Space, or below the list's floor.
    /// - The public route reads each window's position and size (two AX round trips apiece) and pairs
    ///   the frames with `WindowList.snapshot`'s entries for the same pid. What it loses: two extra
    ///   round trips per window plus one window-list copy, nothing at all for a window that is not in
    ///   the list, and — for two windows of one app at exactly the same frame — a guess.
    ///
    /// "Not in the list" is `snapshot`'s own filter: minimised, on another Space, not a regular app, or
    /// under 50 pt a side. Those windows come back with a nil id, which costs nothing — they are
    /// exactly the windows no feature offers, because every feature that offers windows is built from
    /// that same snapshot.
    public func windows(ofPid pid: pid_t) -> [WindowHandle] {
        let app = bounded(AXUIElementCreateApplication(pid))
        let elements = AX.elements(app, kAXWindowsAttribute).map { bounded($0) }
        if let getWindow = Self.windowIDFunction {
            return elements.map { WindowHandle(element: $0, pid: pid, windowID: Self.windowID(of: $0, getWindow)) }
        }
        let frames = elements.map { element -> CGRect in
            guard let p = AX.point(element, kAXPositionAttribute),
                  let s = AX.size(element, kAXSizeAttribute) else { return .null }
            return CGRect(origin: p, size: s)
        }
        let ids = Self.matchWindowIDs(axFrames: frames, listed: WindowList.snapshot(), pid: pid)
        return zip(elements, ids).map { WindowHandle(element: $0, pid: pid, windowID: $1) }
    }

    public func handle(forWindowID id: CGWindowID, pid: pid_t) -> WindowHandle? {
        windows(ofPid: pid).first { $0.windowID == id }
    }

    /// The window's CoreGraphics id, by the private route alone.
    ///
    /// **Symbol:** `_AXUIElementGetWindow`, HIServices (ApplicationServices), resolved through
    /// `PrivateAPI` and nil when the user has turned private interfaces off or this macOS has dropped
    /// it. **Why:** it is the only exact link from an AX element to a `CGWindowID`, and it costs one
    /// call. **Public route:** there is none *for a bare element* — matching against the window list
    /// needs the owning pid as well, which is why the two callers that have one take their own route:
    /// `identify(_:pid:)` for a single element and `windows(ofPid:)` for an application. So this
    /// answering nil is not a failure to report; it is the switch being off.
    public func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let getWindow = Self.windowIDFunction else { return nil }
        return Self.windowID(of: element, getWindow)
    }

    private static var windowIDFunction: AXUIElementGetWindowFunction? {
        PrivateAPI.shared.pointer(for: .axUIElementGetWindow).map {
            unsafeBitCast($0, to: AXUIElementGetWindowFunction.self)
        }
    }

    private static func windowID(of element: AXUIElement, _ getWindow: AXUIElementGetWindowFunction) -> CGWindowID? {
        var id: CGWindowID = 0
        guard getWindow(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    /// The public route, as arithmetic: pairs AX windows — their frames, in `kAXWindows` order — with
    /// the window list's entries for the same pid.
    ///
    /// Pure and static so that every property of it is testable without Accessibility, without a
    /// window and without a permission. The answer has exactly one element per AX frame, in the same
    /// order, `nil` where nothing matched.
    ///
    /// The rule is closest-first, each entry claimed once: for each AX frame in turn, the unclaimed
    /// entry of this pid whose every edge is within `tolerance` and whose worst edge is nearest wins,
    /// ties going to the entry earlier in the list. Both sequences run front to back, so **identical
    /// frames pair in order** — the only honest guess available, and the index says so. A frame
    /// that could not be read is passed as `.null` and matches nothing, without shifting its
    /// neighbours.
    ///
    /// Greedy, and so not globally optimal: an earlier frame can take the entry a later one needed and
    /// leave that later one nil. At a 1 pt tolerance the only inputs where that can happen are frames
    /// within a point of each other, where the pairing is already a guess. Stated so it is not
    /// rediscovered as a defect.
    nonisolated public static func matchWindowIDs(axFrames: [CGRect], listed: [WindowInfo], pid: pid_t,
                                                  tolerance: Double = 1) -> [CGWindowID?] {
        let candidates = listed.filter { $0.pid == pid }
        var claimed = [Bool](repeating: false, count: candidates.count)
        return axFrames.map { ax in
            guard !ax.isNull, ax.minX.isFinite, ax.minY.isFinite, ax.width.isFinite, ax.height.isFinite else { return nil }
            var best: (index: Int, deviation: Double)?
            for (index, candidate) in candidates.enumerated() where !claimed[index] {
                let frame = candidate.frame
                let deviation = max(abs(Double(frame.minX - ax.minX)), abs(Double(frame.minY - ax.minY)),
                                    abs(Double(frame.width - ax.width)), abs(Double(frame.height - ax.height)))
                guard deviation <= tolerance else { continue }
                if best == nil || deviation < best!.deviation { best = (index, deviation) }
            }
            guard let best else { return nil }
            claimed[best.index] = true
            return candidates[best.index].id
        }
    }

    /// The same rule for **one** window, which is the case `identify(_:pid:)` has: the element is
    /// already in hand, its frame has been read, and the question is only which list entry it is.
    ///
    /// Among entries that match equally well — two windows of one app at exactly the same frame — this
    /// takes the **frontmost**, because `listed` runs front to back and `matchWindowIDs` breaks its
    /// ties on list order. That is the right guess here and not merely a consistent one: the caller's
    /// element came from `AXUIElementCopyElementAtPosition`, which answers with the window the pointer
    /// is *on*, and of two stacked windows at the same frame that is the front one.
    ///
    /// A thin wrapper rather than a second algorithm, so the one-window and many-window cases cannot
    /// drift apart — this project has been bitten by a second copy of a geometry rule before.
    nonisolated public static func matchWindowID(axFrame: CGRect, listed: [WindowInfo], pid: pid_t,
                                                 tolerance: Double = 1) -> CGWindowID? {
        matchWindowIDs(axFrames: [axFrame], listed: listed, pid: pid, tolerance: tolerance)[0]
    }
}
