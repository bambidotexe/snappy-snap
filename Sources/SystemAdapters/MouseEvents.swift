import AppKit
import CoreGraphics
import SnapCore

/// Listen-only session event tap for left mouse down/drag/up, mouse moves and flags-changed (for the
/// Command (⌘) and Option (⌥) keys). Requires Accessibility. Events are delivered on the main actor
/// because the tap's run-loop source is on the main run loop.
///
/// A second listen-only tap at the **device (HID) level** hears presses and releases only, and
/// `PressReconciler` delivers from it the press and the release of a gesture the window server kept
/// from the session — fn held with a drag anywhere on a window. Without it the app runs exactly as
/// it does with it, less those gestures.
@MainActor
public final class MouseEvents {
    public enum Event: Sendable {
        case down(CGPoint)
        case dragged(CGPoint)
        case up(CGPoint)
        case moved(CGPoint)
        /// Whether **Command (⌘)** and **Option (⌥)** are held, reported on every `flagsChanged`
        /// rather than inferred from a mouse event: both must answer a key pressed with the pointer
        /// standing still — `SnapCore.HandleSuppression` because the poll behind the handles stands
        /// still with the pointer, and the drag session because a key changed mid-drag has to repaint
        /// the preview where the pointer already is.
        ///
        /// These two are the app's only modifiers, and this is the only place that says which bit of a
        /// `CGEvent` each one is. **Not fn**: holding fn and dragging is a system window-move gesture,
        /// so the key meant to uncover a window's resize edge moved the window instead (`pitfalls.md`).
        case flagsChanged(command: Bool, option: Bool)
    }

    /// Why the system took the tap away. Silence is a defect, and these two are different defects: a
    /// **timeout** is this app's own fault (something on the main run loop held the callback past the
    /// system's patience, which is the exact failure `AccessibilityWindows`' 0.25 s messaging timeout
    /// exists to bound), while **user input** is the system deciding a listening tap had to be
    /// interrupted and is nobody's bug. One log line that could not tell them apart sends a reader
    /// looking in the wrong place.
    public enum TapDisableReason: String, Sendable {
        case timeout, userInput
    }

    public var handler: (@MainActor (Event) -> Void)?
    /// Called when the system disabled the tap, after it has been re-enabled, with why and with how
    /// many times it has happened this launch. Events were lost in between, so the app logs it as an
    /// error; the count is what turns "it happened" into "it is happening".
    public var onTapDisabled: (@MainActor (TapDisableReason, Int) -> Void)?
    /// How many times the tap has been disabled this launch, both reasons together.
    private var tapDisableCount = 0
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var deviceTap: CFMachPort?
    private var deviceSource: CFRunLoopSource?
    private var presses = PressReconciler()
    /// False when the device-level tap could not be created: the app works, and a gesture whose
    /// press the window server keeps from the session arms nothing. The caller logs it.
    public private(set) var hearsDevicePresses = false

    public init() {}

    /// Returns false when the tap could not be created (permission missing).
    public func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                if let userInfo {
                    let owner = Unmanaged<MouseEvents>.fromOpaque(userInfo).takeUnretainedValue()
                    MainActor.assumeIsolated { owner.handle(type: type, event: event) }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        startDeviceTap(userInfo: userInfo)
        return true
    }

    private func startDeviceTap(userInfo: UnsafeMutableRawPointer) {
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                if let userInfo {
                    let owner = Unmanaged<MouseEvents>.fromOpaque(userInfo).takeUnretainedValue()
                    MainActor.assumeIsolated { owner.handleDevice(type: type, event: event) }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else { return }
        deviceTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        deviceSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        hearsDevicePresses = true
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
        if let deviceTap { CGEvent.tapEnable(tap: deviceTap, enable: false) }
        if let deviceSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), deviceSource, .commonModes) }
        if let deviceTap { CFMachPortInvalidate(deviceTap) }
        deviceTap = nil
        deviceSource = nil
        hearsDevicePresses = false
    }

    /// The run loop owns the tap's source, and the callback recovers `self` from an unretained
    /// pointer, so a tap left running would outlive us and dereference freed memory.
    isolated deinit {
        stop()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            tapDisableCount += 1
            onTapDisabled?(type == .tapDisabledByTimeout ? .timeout : .userInput, tapDisableCount)
        case .leftMouseDown:
            if presses.sessionDown(timestamp: event.timestamp) { handler?(.down(event.location)) }
        case .leftMouseDragged:
            if let press = presses.sessionDragged() { handler?(.down(press)) }
            handler?(.dragged(event.location))
        case .leftMouseUp:
            if presses.sessionUp(timestamp: event.timestamp) { handler?(.up(event.location)) }
        case .mouseMoved: handler?(.moved(event.location))
        case .flagsChanged: handler?(.flagsChanged(command: event.flags.contains(.maskCommand),
                                            option: event.flags.contains(.maskAlternate)))
        default: break
        }
    }

    private func handleDevice(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let deviceTap { CGEvent.tapEnable(tap: deviceTap, enable: true) }
            tapDisableCount += 1
            onTapDisabled?(type == .tapDisabledByTimeout ? .timeout : .userInput, tapDisableCount)
        case .leftMouseDown: presses.deviceDown(at: event.location, timestamp: event.timestamp)
        case .leftMouseUp:
            if presses.deviceUp(timestamp: event.timestamp) { handler?(.up(event.location)) }
        default: break
        }
    }
}
