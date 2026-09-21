import Darwin
import Foundation
import os

/// Every private macOS symbol SnappySnap uses, and nothing else. This enum **is** the inventory —
/// `docs/private-api-index.md` is its prose form, and `PrivateFeature` below is its visible form: the
/// Settings window reports one line per feature, and a symbol that belongs to no feature is a symbol
/// the user cannot see.
///
/// The raw value is the C symbol name exactly as `dlsym` wants it. `_AXUIElementGetWindow` really does
/// carry the leading underscore in its source name; the extra underscore the C ABI adds is `dlsym`'s
/// business, not ours (it strips one itself).
public enum PrivateSymbol: String, CaseIterable, Sendable {
    /// The CGWindowID of an AX window element, in one call. Long-stable SPI (Rectangle, AltTab, yabai).
    case axUIElementGetWindow = "_AXUIElementGetWindow"
    /// Our process's window-server connection id — the argument the next symbol needs. Read in
    /// `BackgroundCursor.enable()` and nowhere else.
    case cgsMainConnectionID = "CGSMainConnectionID"
    /// Sets a property on a window-server connection; `SetsCursorInBackground` on ours is what lets
    /// `BackgroundCursor` put a cursor over the handles without the app activating.
    case cgsSetConnectionProperty = "CGSSetConnectionProperty"
    /// Creates a window-server Space owned by this process. With the three below it is how
    /// `ElevatedSpace` puts the notch shape above other notch utilities.
    case cgsSpaceCreate = "CGSSpaceCreate"
    /// Places a Space above or below the user's own. A window's *level* only orders it among the
    /// windows of its Space; the Space's absolute level orders it against every other Space.
    case cgsSpaceSetAbsoluteLevel = "CGSSpaceSetAbsoluteLevel"
    /// Makes a created Space visible; until then the windows in it draw nowhere.
    case cgsShowSpaces = "CGSShowSpaces"
    /// Adds a window to a Space, in addition to whichever it is already on.
    case cgsAddWindowsToSpaces = "CGSAddWindowsToSpaces"
    /// The layer that hands the window server's picture of *what is behind this window* to Core
    /// Animation — with no material and therefore no tint — and reports that picture's luminance.
    /// An Objective-C class, resolved like any other symbol: the linker names it `OBJC_CLASS_$_…`.
    case caBackdropLayer = "OBJC_CLASS_$_CABackdropLayer"
    /// Core Animation's own filters; `variableBlur` is the one that blurs by a per-pixel radius.
    case caFilter = "OBJC_CLASS_$_CAFilter"

    public var framework: String {
        switch self {
        case .axUIElementGetWindow: "HIServices (ApplicationServices)"
        case .cgsMainConnectionID, .cgsSetConnectionProperty, .cgsSpaceCreate, .cgsSpaceSetAbsoluteLevel,
             .cgsShowSpaces, .cgsAddWindowsToSpaces: "SkyLight"
        case .caBackdropLayer, .caFilter: "QuartzCore"
        }
    }

    /// The image to `dlopen` before looking the symbol up, or nil when it is already in the process.
    ///
    /// `_AXUIElementGetWindow` is exported by HIServices, which `ApplicationServices` has already
    /// brought in by the time any of this runs — so it is found through the process's own image list
    /// and nothing extra is loaded for it. SkyLight is a private framework this app does not otherwise
    /// link, so it is opened by path, lazily, and only if someone asks.
    var libraryPath: String? {
        switch self {
        // QuartzCore is linked by AppKit, so its two classes are found the way HIServices' symbol is.
        case .axUIElementGetWindow, .caBackdropLayer, .caFilter: nil
        case .cgsMainConnectionID, .cgsSetConnectionProperty, .cgsSpaceCreate, .cgsSpaceSetAbsoluteLevel,
             .cgsShowSpaces, .cgsAddWindowsToSpaces:
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
        }
    }
}

/// What the private symbols buy, as the user would name it: the four lines under the switch in
/// Settings › System › Compatibility. The symbols themselves say nothing to the person being asked,
/// so the window reports these instead and keeps the symbols for the tooltip a bug report is read from.
///
/// **A feature is available only when every one of its symbols is.** One missing symbol sends the
/// whole feature down its public route, so reporting the others as present would describe the
/// machine's inventory rather than what the user gets.
public enum PrivateFeature: String, CaseIterable, Sendable {
    /// A window element linked to its system id in one call, instead of matched by position and size.
    case windowMatching
    /// A pointer over the pill and the knobs from an app that never takes focus.
    case handlePointer
    /// The notch shape and the island in a Space of their own, above the one notch utilities draw in.
    case elevatedSnapBar
    /// What is behind the notch shape and the island blurred without a tint, fading with distance.
    case snapBarBlur

    /// The line's text in Settings.
    public var title: String {
        switch self {
        case .windowMatching: L("Exact window matching")
        case .handlePointer: L("Pointer over the handles")
        case .elevatedSnapBar: L("Snap bar above other notch apps")
        case .snapBarBlur: L("Blur behind the snap bar")
        }
    }

    /// Every symbol the feature needs. The connection id is in two of them: both the cursor property
    /// and the Space are set on this process's window-server connection.
    public var symbols: [PrivateSymbol] {
        switch self {
        case .windowMatching: [.axUIElementGetWindow]
        case .handlePointer: [.cgsMainConnectionID, .cgsSetConnectionProperty]
        case .elevatedSnapBar: [.cgsMainConnectionID, .cgsSpaceCreate, .cgsSpaceSetAbsoluteLevel,
                                .cgsShowSpaces, .cgsAddWindowsToSpaces]
        case .snapBarBlur: [.caBackdropLayer, .caFilter]
        }
    }
}

/// The one door to every private symbol in the app.
///
/// **Why this exists at all.** A private symbol is resolved at runtime and never linked. A linked
/// declaration would make `_AXUIElementGetWindow` a load-time dependency — the day macOS drops it,
/// the app does not start, which is the one failure mode a private symbol must never have. Here a
/// missing symbol is `nil`, the caller takes its public route, and the Settings pane says so in words.
///
/// **Why it is a switch and not only a fallback.** The user owns the trade. `isEnabled` mirrors
/// `Settings.usePrivateAPIs` — `AppDelegate` pushes it in at launch and on every settings change — and
/// `pointer(for:)` answers nil while it is off, so a feature that asks on every call moves onto its
/// public route on the *next* call rather than on the next launch.
///
/// Resolution is cached per symbol, including the failures: `dlsym` on a symbol that is not there
/// costs a search of every loaded image, and the answer cannot change while the process lives.
@MainActor
public final class PrivateAPI {
    public static let shared = PrivateAPI()

    /// Mirrors `Settings.usePrivateAPIs`. Set by `AppDelegate` at launch and whenever settings change.
    /// Defaults to `true` for the same reason the setting does — and so that a unit test or the
    /// `axprobe` tool, neither of which has a settings file, behaves like the shipped app.
    public var isEnabled: Bool = true {
        didSet {
            guard isEnabled != oldValue else { return }
            Logger.privateAPI.info("private interfaces \(self.isEnabled ? "on" : "off", privacy: .public)")
        }
    }

    /// Resolved symbols, successes and failures alike. The outer `Optional` is "have we looked yet",
    /// the inner one is "was it there".
    private var resolved: [PrivateSymbol: UnsafeMutableRawPointer?] = [:]
    /// Open images, keyed by `libraryPath` (and `""` for the process's own images), so the second
    /// SkyLight symbol does not re-open SkyLight and nothing takes a second reference on dyld's
    /// process-wide handle.
    private var images: [String: UnsafeMutableRawPointer?] = [:]

    private init() {}

    /// The symbol's address, or nil when the switch is off **or** the symbol is not on this macOS.
    /// Every caller branches on this and nothing else: one nil check chooses between the two routes.
    ///
    /// Ask on each use rather than caching the answer in the caller — that is what makes the switch
    /// take effect without a relaunch. The cost of asking is a dictionary lookup.
    public func pointer(for symbol: PrivateSymbol) -> UnsafeMutableRawPointer? {
        guard isEnabled else { return nil }
        return resolve(symbol)
    }

    /// Whether this macOS has the symbol, **independent of the switch** — the Settings status lines
    /// report what is on the machine, not what the user has turned on, so that turning the switch off
    /// does not make every symbol read as missing.
    public func isAvailable(_ symbol: PrivateSymbol) -> Bool { resolve(symbol) != nil }

    /// Whether this macOS has every symbol the feature needs, independent of the switch like the
    /// answer above, and for the same reason.
    public func isAvailable(_ feature: PrivateFeature) -> Bool {
        feature.symbols.allSatisfy { isAvailable($0) }
    }

    /// The feature's symbols, one per line, each with its framework and whether this macOS has it: what a
    /// bug report is read from, and so the tooltip of the feature's line on the System and Health pages.
    /// Symbol names are never translated, and neither is this.
    public func report(for feature: PrivateFeature) -> String {
        feature.symbols
            .map { "\($0.rawValue) (\($0.framework)): \(isAvailable($0) ? "found" : "not found")" }
            .joined(separator: "\n")
    }

    private func resolve(_ symbol: PrivateSymbol) -> UnsafeMutableRawPointer? {
        if let cached = resolved[symbol] { return cached }
        guard let handle = image(for: symbol) else {
            // `image(for:)` has already logged why, with `dlopen`'s own message. Cached as absent so a
            // framework that would not open is not re-opened once per symbol per call.
            resolved[symbol] = UnsafeMutableRawPointer?.none
            return nil
        }
        // `dlsym` leaves an error behind on failure whether or not anyone reads it, and so does the
        // `dlopen` above; clearing it *here*, after the open and before the lookup, is what makes
        // `dlerror()` below describe this lookup and not that open.
        dlerror()
        let pointer = dlsym(handle, symbol.rawValue)
        resolved[symbol] = pointer
        if pointer != nil {
            Logger.privateAPI.info("resolved \(symbol.rawValue, privacy: .public) from \(symbol.framework, privacy: .public)")
        } else {
            let reason = dlerror().map { String(cString: $0) } ?? "not found"
            Logger.privateAPI.info("\(symbol.rawValue, privacy: .public) is not available on this macOS: \(reason, privacy: .public); the public route is used")
        }
        return pointer
    }

    /// The image `symbol` lives in, opened at most once per path for the life of the process.
    ///
    /// A nil `libraryPath` means "already in this process", and `dlopen(nil, …)` is how dyld is asked
    /// for a handle that searches what is loaded. It is memoised under a key of its own rather than
    /// called again: each `dlopen` takes a reference, and nothing here ever calls `dlclose` — a handle
    /// this class hands out may be a function pointer some caller is still holding.
    private func image(for symbol: PrivateSymbol) -> UnsafeMutableRawPointer? {
        // Not a path any `libraryPath` can be, so it cannot collide with a real one.
        let key = symbol.libraryPath ?? ""
        if let cached = images[key] { return cached }
        // `RTLD_LAZY` for a named image: we want one symbol's address, not every binding in a private
        // framework resolved. `RTLD_NOLOAD` is not used — SkyLight is not already in this process.
        let handle = symbol.libraryPath.map { dlopen($0, RTLD_LAZY) } ?? dlopen(nil, RTLD_NOW)
        images[key] = handle
        if handle == nil {
            let reason = dlerror().map { String(cString: $0) } ?? "no reason given"
            Logger.privateAPI.info("could not open \(key.isEmpty ? "this process's own images" : key, privacy: .public): \(reason, privacy: .public); its symbols fall back to their public routes")
        }
        return handle
    }
}

extension Logger {
    /// `SystemAdapters` has no logging of its own; the app's categories live in `SnappySnap/Logging.swift`
    /// and this target cannot see them. One category, for the one thing here worth a line: which
    /// private symbols this machine has.
    static let privateAPI = Logger(subsystem: "dev.rubens.SnappySnap", category: "app")
}
