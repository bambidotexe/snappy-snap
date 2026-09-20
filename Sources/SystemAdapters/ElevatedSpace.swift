import AppKit
import os

/// A window-server Space of this app's own, above every Space the user has — the one way a window
/// of ours can draw over another notch utility's.
///
/// **A window level cannot do it.** A level orders a window among the windows of *its* Space; the
/// Space's **absolute level** orders it against every other Space, and that comparison comes first.
/// Notch utilities put their windows in a Space at absolute level 400, the tier the lock screen uses.
/// Measured against one whose panels sit at window levels 2147483629 and 2147483628: a panel of ours
/// at every level from 19 to `kCGMaximumWindowLevel` (2147483631) lists *below* both, with
/// `orderFrontRegardless` repeated every 50 ms, with `sharingType = .none`, and with
/// `order(.above, relativeTo:)` given its window number. In a Space of our own at 400 it still lists
/// below; **at 401 it lists first, with the window itself at plain `.statusBar`.**
///
/// A window is *added* to this Space and stays on the user's as well, so its collection behaviour
/// and the rest of the app's Space handling are untouched. Membership ends with the window: closing
/// it takes it off every Space, which is how a panel leaves this one when the switch goes off.
///
/// Four private symbols and the connection id, asked for on every call. With any of them absent, or
/// the switch off, `add` does nothing and says so once — the window draws under the other utility,
/// which is less good and no less safe.
@MainActor
public final class ElevatedSpace {
    public static let shared = ElevatedSpace()

    /// One above the tier other notch utilities draw in.
    public static let absoluteLevel: Int32 = 401

    /// Created on first use and kept for the life of the process: the window server destroys it with
    /// our connection, and an empty Space draws nothing.
    private var space: UInt64?
    private var didLogUnavailable = false

    private init() {}

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, UInt64, Int32) -> Void
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Void
    private typealias AddWindowsToSpaces = @convention(c) (Int32, CFArray, CFArray) -> Void

    /// Resolves the symbols and creates the Space ahead of the first `add`. Opening SkyLight costs
    /// about 20 ms once per launch; this is how that is paid when a drag begins rather than on the
    /// turn the shape starts to grow.
    public func prepare() {
        _ = ensureSpace()
    }

    /// Adds `window` to the elevated Space, creating the Space if this is the first call. Safe to call
    /// after every `orderFront`: adding a window that is already there changes nothing.
    ///
    /// - Returns: whether the window is on the elevated Space.
    @discardableResult
    public func add(_ window: NSWindow) -> Bool {
        guard window.windowNumber > 0, let (connection, id) = ensureSpace(),
              let addWindows = PrivateAPI.shared.pointer(for: .cgsAddWindowsToSpaces) else { return false }
        unsafeBitCast(addWindows, to: AddWindowsToSpaces.self)(
            connection, [NSNumber(value: window.windowNumber)] as CFArray, [NSNumber(value: id)] as CFArray)
        return true
    }

    /// Our connection and the Space, created on the first call that finds every symbol. Asks for the
    /// symbols each time, so the switch going off is seen on the next call.
    private func ensureSpace() -> (connection: Int32, space: UInt64)? {
        let api = PrivateAPI.shared
        guard let connectionID = api.pointer(for: .cgsMainConnectionID),
              let create = api.pointer(for: .cgsSpaceCreate),
              let setLevel = api.pointer(for: .cgsSpaceSetAbsoluteLevel),
              let show = api.pointer(for: .cgsShowSpaces),
              api.pointer(for: .cgsAddWindowsToSpaces) != nil else {
            if !didLogUnavailable {
                didLogUnavailable = true
                Logger.privateAPI.info("no elevated Space: private interfaces are off or missing; the notch shape draws below other notch utilities")
            }
            return nil
        }
        didLogUnavailable = false
        let connection = unsafeBitCast(connectionID, to: MainConnectionID.self)()
        if let space { return (connection, space) }
        let id = unsafeBitCast(create, to: SpaceCreate.self)(connection, 1, nil)
        guard id != 0 else {
            Logger.privateAPI.info("CGSSpaceCreate returned no Space; the notch shape draws below other notch utilities")
            return nil
        }
        unsafeBitCast(setLevel, to: SpaceSetAbsoluteLevel.self)(connection, id, Self.absoluteLevel)
        unsafeBitCast(show, to: ShowSpaces.self)(connection, [NSNumber(value: id)] as CFArray)
        space = id
        Logger.privateAPI.info("elevated Space \(id) created at absolute level \(Self.absoluteLevel)")
        return (connection, id)
    }
}
