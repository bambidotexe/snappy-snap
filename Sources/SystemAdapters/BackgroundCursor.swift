import AppKit
import CoreGraphics
import Foundation
import os

/// How an app that never activates puts a cursor on the screen, and the system's own glyphs to put
/// there.
///
/// **The mechanism.** The window server takes a cursor only from the *active* application, but that
/// rule is a *connection property*: setting `SetsCursorInBackground` on our own window-server
/// connection lifts it, after which the entirely public `NSCursor.set()` reaches the screen from an
/// inactive, non-key accessory app. Measured under this project's signing identity. The
/// `SetsCursorInBackground` **Info.plist key is dead on macOS 27** — four configurations tested — so
/// the connection property is the only route.
///
/// **The override is global, not window-scoped.** Setting it means our `set()` wins over every other
/// application's, wherever the pointer is. That is why nothing here asserts a cursor on its own: the
/// property is set once, and `HandleContentView` asserts only while the pointer is inside a handle's
/// hover band, re-testing the band on every keepalive tick so a stuck timer self-corrects.
///
/// **Restoring never means `NSCursor.arrow.set()`.** Stopping the assertion hands the cursor back to
/// whatever the application underneath had chosen — its I-beam over a text field, say. Setting an
/// arrow would stomp it, globally. There is no "un-set"; there is only stopping.
///
/// **Safety.** A SIGKILL mid-assert restores the user's cursor at once (measured), so a crash cannot
/// strand one on screen.
@MainActor
public enum BackgroundCursor {
    /// What the last log line said, so the `.info` below is written **on change only**. `enable()` is
    /// called on every panel show and the keepalive runs at 60 Hz; neither may log.
    private static var lastLogged: String?

    /// Sets `SetsCursorInBackground` on our window-server connection. Idempotent — the property is
    /// re-applied rather than skipped, because a window-server reconnect drops it and the call is two
    /// C function calls; callers are expected to ask on every panel show.
    ///
    /// Returns false when the user has private interfaces switched off, when either symbol is missing
    /// on this macOS, or when the window server refused. On false the caller runs no keepalive and
    /// asserts no cursor, which is the public route.
    @discardableResult
    public static func enable() -> Bool {
        // PRIVATE: `CGSMainConnectionID` and `CGSSetConnectionProperty`, SkyLight
        // (`/System/Library/PrivateFrameworks/SkyLight.framework`), `dlsym`'d through `PrivateAPI` and
        // never linked. WHY: they are the only route to a cursor from an application that never
        // activates — public AppKit cannot do it at all, which the elimination table in
        // `HandlePanel.swift` proves, and the `SetsCursorInBackground` Info.plist key is dead on
        // macOS 27. PUBLIC ROUTE: none, and none is needed — with either symbol absent this returns
        // false, no keepalive runs, and the pill and the knob shapes stay the only affordance. Asked
        // for on *every* call, never cached in this file, so the Settings switch takes effect without
        // a relaunch.
        guard let connectionID = PrivateAPI.shared.pointer(for: .cgsMainConnectionID),
              let setProperty = PrivateAPI.shared.pointer(for: .cgsSetConnectionProperty) else {
            log("no cursor over the handles: private interfaces are off or SkyLight's connection symbols are not on this macOS")
            return false
        }
        typealias MainConnectionID = @convention(c) () -> Int32
        typealias SetConnectionProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> CGError

        let connection = unsafeBitCast(connectionID, to: MainConnectionID.self)()
        guard connection != 0 else {
            log("no cursor over the handles: the window server gave this process no connection id")
            return false
        }
        let value: CFTypeRef = kCFBooleanTrue
        // Both the target and the owning connection are ours: we are setting a property on our own
        // connection, which is the only connection this app may touch.
        let error = unsafeBitCast(setProperty, to: SetConnectionProperty.self)(
            connection, connection, "SetsCursorInBackground" as CFString, value)
        let enabled = error == .success
        if enabled {
            log("the cursor may be set from the background: SetsCursorInBackground is on connection \(connection)")
        } else {
            log("no cursor over the handles: SetsCursorInBackground was refused (CGError \(error.rawValue))")
        }
        return enabled
    }

    /// One `.info` line per distinct message, and nothing at all while the message is unchanged.
    private static func log(_ message: String) {
        guard lastLogged != message else { return }
        lastLogged = message
        Logger.privateAPI.info("\(message, privacy: .public)")
    }

    // MARK: - The system's own glyphs

    /// Where macOS keeps the cursor artwork every application sees. Undocumented as a *path* — this is
    /// nothing but a public file read of two files, no API and no entitlement — so every step of it is
    /// optional and the caller has a fallback.
    private static let cursorsDirectory =
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/Versions/A/Resources/cursors"

    /// Resolved glyphs, successes and failures alike: the files cannot change while the process lives
    /// and the keepalive must not read the disk at 60 Hz.
    private static var cache: [String: NSCursor?] = [:]

    /// The system's own glyph of that name — `move`, `cell`, `poof` — built from
    /// `cursors/<name>/cursor.pdf` with the hotspot from the `info.plist` beside it, preferring a
    /// `cursors/macos27/<name>/` variant where macOS 27 ships one (it does for the three hand
    /// cursors, and may for more in a later build).
    ///
    /// nil when the directory, the PDF or a sane size is missing. There is no public API for these —
    /// AppKit exposes a fixed list of `NSCursor` class properties and an omnidirectional move is not
    /// among them — and the alternative to reading the system's own artwork is drawing an
    /// approximation of it, which would be the one glyph on screen that does not match the platform.
    private static func systemCursor(named name: String) -> NSCursor? {
        if let cached = cache[name] { return cached }
        let cursor = loadCursor(named: name)
        cache[name] = cursor
        if cursor == nil {
            log("the system move glyph could not be read from \(cursorsDirectory); the fallback cursor is used")
        }
        return cursor
    }

    /// The glyph for a T or cross junction knob: the system's own move cursor, or `.crosshair` when
    /// it cannot be read. The fallback is the honest one of AppKit's fixed list — it says "both axes"
    /// without promising a shape macOS does not have.
    public static var move: NSCursor { systemCursor(named: "move") ?? .crosshair }

    private static func loadCursor(named name: String) -> NSCursor? {
        for directory in ["\(cursorsDirectory)/macos27/\(name)", "\(cursorsDirectory)/\(name)"] {
            guard let image = NSImage(contentsOfFile: "\(directory)/cursor.pdf"),
                  image.size.width > 0, image.size.height > 0 else { continue }
            // Hotspot in points from the plist beside the artwork. A plist that will not read, or has
            // no `hotx`/`hoty`, leaves the hotspot at the image's centre — wrong by at most half a
            // glyph, never a crash. The measured values for `move` are (12, 12) on a 24 pt image,
            // which is that centre anyway.
            let info = NSDictionary(contentsOfFile: "\(directory)/info.plist")
            let x = (info?["hotx"] as? NSNumber)?.doubleValue ?? image.size.width / 2
            let y = (info?["hoty"] as? NSNumber)?.doubleValue ?? image.size.height / 2
            return NSCursor(image: image, hotSpot: CGPoint(x: x, y: y))
        }
        return nil
    }

    // MARK: - Where the pointer is

    /// The pointer in **CG space** (origin top-left of the primary display), which is the space every
    /// `SnapCore` band is expressed in. Read on each keepalive tick rather than taken from the event
    /// tap: the tick has to answer "is the pointer in the band *now*", including when no event has
    /// arrived because the pointer stopped moving.
    public static var pointerLocation: CGPoint {
        CoordinateSpace.cgPoint(fromCocoa: NSEvent.mouseLocation)
    }
}
