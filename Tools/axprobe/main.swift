// axprobe — dev probe for SnappySnap, never shipped.
// Usage:
//   axprobe prefs                      print com.apple.WindowManager tiling keys
//   axprobe apps                       list regular running apps
//   axprobe windows                    CGWindowList snapshot (id, pid, layer, owner, bounds)
//   axprobe menus <app> [depth]        dump the app's menu bar (default depth 2)
//   axprobe frame <app>                front window frame, margins vs visibleFrame, resizable, title
//   axprobe minsize                    read-only: AXMinSize / AXMinimumSize for every window of every
//                                      regular running app, plus a per-bucket summary
//   axprobe press <app> <i.j.k> [--no-activate]   AXPress a menu item by index path, sample frames 1.5 s
//   axprobe setframe <app> x y w h     set the front window frame via AX
//   axprobe setframeid <id> x y w h    set a window's frame by CGWindowID via AccessibilityWindows,
//                                      for one of several windows of one application
//   axprobe watch <app> [seconds]      print the front window frame whenever it changes
//   axprobe dragtitle <app> <dx> <dy> [sx sy]  synthesize a real mouse drag by (dx, dy) from the title bar
//                                      midpoint, or from (sx, sy) in CG space when given; samples frames 1.5 s
//   axprobe hover <x> <y> [seconds]    move the cursor onto (x, y) with real mouse moves and keep it
//                                      there, so another shell can look at what appeared
//   axprobe click <x> <y> [hold s]     hover onto (x, y), then press and release WITHOUT moving
//   axprobe drag <sx> <sy> <ex> <ey> [steps]   hover into (sx, sy) with real mouse moves, then press,
//                                      drag to (ex, ey) and release. For the handle, which is armed
//                                      by hover and never belongs to any one app's window.
//   axprobe dragvia <steps> x1 y1 x2 y2 [x3 y3 ...]   a drag along a polyline, with a dwell at
//                                      each corner, that exercises a route a straight drag cannot —
//                                      such as a handle's growth phase followed by a shrink of the
//                                      same member.
//   axprobe dragappvia <app> <steps> x1 y1 x2 y2 [x3 y3 ...]   dragvia for a window: activates and
//                                      raises the app first, without which macOS does not treat the
//                                      posted press as a title-bar drag at all.
import AppKit
import ApplicationServices
import Foundation
import SystemAdapters

// MARK: - AX helpers

func axAttr<T>(_ el: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success, let value else { return nil }
    return value as? T
}

func axElement(_ el: AXUIElement, _ name: String) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success, let value,
          CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func axElements(_ el: AXUIElement, _ name: String) -> [AXUIElement] {
    (axAttr(el, name) as [AXUIElement]?) ?? []
}

func axPoint(_ el: AXUIElement, _ name: String) -> CGPoint? {
    guard let v: AXValue = axAttr(el, name) else { return nil }
    var p = CGPoint.zero
    return AXValueGetValue(v, .cgPoint, &p) ? p : nil
}

func axSize(_ el: AXUIElement, _ name: String) -> CGSize? {
    guard let v: AXValue = axAttr(el, name) else { return nil }
    var s = CGSize.zero
    return AXValueGetValue(v, .cgSize, &s) ? s : nil
}

func axSet(_ el: AXUIElement, _ name: String, point: CGPoint) -> AXError {
    var p = point
    return AXUIElementSetAttributeValue(el, name as CFString, AXValueCreate(.cgPoint, &p)!)
}

func axSet(_ el: AXUIElement, _ name: String, size: CGSize) -> AXError {
    var s = size
    return AXUIElementSetAttributeValue(el, name as CFString, AXValueCreate(.cgSize, &s)!)
}

func frame(of window: AXUIElement) -> CGRect? {
    guard let p = axPoint(window, kAXPositionAttribute), let s = axSize(window, kAXSizeAttribute) else { return nil }
    return CGRect(origin: p, size: s)
}

/// Children of a menu element, looking through the transparent AXMenu container.
func menuChildren(_ el: AXUIElement) -> [AXUIElement] {
    var kids = axElements(el, kAXChildrenAttribute)
    if kids.count == 1, (axAttr(kids[0], kAXRoleAttribute) as String?) == (kAXMenuRole as String) {
        kids = axElements(kids[0], kAXChildrenAttribute)
    }
    return kids
}

func resolve(_ path: [Int], from root: AXUIElement) -> AXUIElement? {
    var el = root
    for index in path {
        let kids = menuChildren(el)
        guard index < kids.count else { return nil }
        el = kids[index]
    }
    return el
}

func dumpMenu(_ el: AXUIElement, path: [Int], depth: Int, maxDepth: Int) {
    for (i, item) in menuChildren(el).enumerated() {
        let p = path + [i]
        let title: String = axAttr(item, kAXTitleAttribute) ?? ""
        let ident: String = axAttr(item, kAXIdentifierAttribute) ?? ""
        let cmd: String = axAttr(item, kAXMenuItemCmdCharAttribute) ?? ""
        let mods = (axAttr(item, kAXMenuItemCmdModifiersAttribute) as NSNumber?)?.intValue ?? -1
        let glyph = (axAttr(item, kAXMenuItemCmdGlyphAttribute) as NSNumber?)?.intValue ?? -1
        let enabled = (axAttr(item, kAXEnabledAttribute) as NSNumber?)?.boolValue ?? false
        let indent = String(repeating: "  ", count: depth)
        print("\(indent)[\(p.map(String.init).joined(separator: "."))] \"\(title)\" id=\(ident) cmd=\(cmd) mods=\(mods) glyph=\(glyph) enabled=\(enabled)")
        if depth < maxDepth, !menuChildren(item).isEmpty {
            dumpMenu(item, path: p, depth: depth + 1, maxDepth: maxDepth)
        }
    }
}

// MARK: - App and screen helpers

func app(named name: String) -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first { $0.localizedName == name || $0.bundleIdentifier == name }
}

struct AppTarget {
    let running: NSRunningApplication
    let element: AXUIElement
}

func appElement(_ name: String) -> AppTarget? {
    guard let a = app(named: name) else { print("no running app named \(name)"); return nil }
    return AppTarget(running: a, element: AXUIElementCreateApplication(a.processIdentifier))
}

func frontWindow(_ appEl: AXUIElement) -> AXUIElement? {
    axElement(appEl, kAXFocusedWindowAttribute) ?? axElements(appEl, kAXWindowsAttribute).first
}

func cgRect(fromCocoa r: CGRect) -> CGRect {
    let h = NSScreen.screens[0].frame.height
    return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
}

func screenInfo(containing r: CGRect) -> (frame: CGRect, visible: CGRect)? {
    for s in NSScreen.screens {
        let f = cgRect(fromCocoa: s.frame)
        if f.intersects(r) { return (f, cgRect(fromCocoa: s.visibleFrame)) }
    }
    return nil
}

func describe(_ r: CGRect) -> String {
    String(format: "x=%.1f y=%.1f w=%.1f h=%.1f", r.minX, r.minY, r.width, r.height)
}

func report(window w: AXUIElement, label: String) {
    guard let f = frame(of: w) else { print("\(label): no frame"); return }
    print("\(label): \(describe(f))")
    if let s = screenInfo(containing: f) {
        print("  visibleFrame: \(describe(s.visible))")
        print(String(format: "  margins L=%.1f T=%.1f R=%.1f B=%.1f",
                     f.minX - s.visible.minX, f.minY - s.visible.minY,
                     s.visible.maxX - f.maxX, s.visible.maxY - f.maxY))
    }
}

// MARK: - Undocumented minimum-size attributes

/// Rectangle (open source) asks for these two before it falls back to the write-and-read-back probe.
/// Neither is declared in any SDK header, so they are spelled out here as plain strings.
let axMinSizeAttribute = "AXMinSize"
let axMinimumSizeAttribute = "AXMinimumSize"

/// What one attribute answered on one element: the size, or the reason there is none.
struct AttributeAnswer {
    let size: CGSize?
    let detail: String
    let settable: Bool
}

func axErrorName(_ e: AXError) -> String {
    switch e {
    case .success: return "success"
    case .attributeUnsupported: return "attributeUnsupported"
    case .noValue: return "noValue"
    case .illegalArgument: return "illegalArgument"
    case .invalidUIElement: return "invalidUIElement"
    case .cannotComplete: return "cannotComplete"
    case .notImplemented: return "notImplemented"
    case .apiDisabled: return "apiDisabled"
    default: return "error \(e.rawValue)"
    }
}

/// Reads one size attribute and reports *why* it has no value, which is the whole point of the probe:
/// "unsupported" and "supported but empty" are different answers about the same app.
func sizeAnswer(_ el: AXUIElement, _ name: String) -> AttributeAnswer {
    var settable: DarwinBoolean = false
    AXUIElementIsAttributeSettable(el, name as CFString, &settable)
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(el, name as CFString, &value)
    guard err == .success, let value else {
        return AttributeAnswer(size: nil, detail: axErrorName(err), settable: settable.boolValue)
    }
    guard CFGetTypeID(value) == AXValueGetTypeID() else {
        return AttributeAnswer(size: nil, detail: "not an AXValue (\(CFCopyTypeIDDescription(CFGetTypeID(value)) as String? ?? "?"))",
                               settable: settable.boolValue)
    }
    var s = CGSize.zero
    guard AXValueGetValue(value as! AXValue, .cgSize, &s) else {
        return AttributeAnswer(size: nil, detail: "AXValue but not a CGSize", settable: settable.boolValue)
    }
    return AttributeAnswer(size: s, detail: String(format: "%.1f x %.1f", s.width, s.height), settable: settable.boolValue)
}

/// Whether an answered size could be a real floor. An attribute that exists and answers a useless
/// constant is worse than one that is absent: a too-large "minimum" silently ruins a layout.
func plausibility(_ s: CGSize, current: CGSize) -> String {
    if s.width <= 0 || s.height <= 0 { return "SUSPECT(zero)" }
    if s.width <= 1 && s.height <= 1 { return "SUSPECT(one)" }
    if abs(s.width - current.width) < 1 && abs(s.height - current.height) < 1 { return "SUSPECT(==current)" }
    if s.width > current.width || s.height > current.height { return "SUSPECT(>current)" }
    return "plausible"
}

// MARK: - Synthetic mouse drag

func postMouse(_ type: CGEventType, _ p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

// MARK: - Commands

let usage = "usage: axprobe prefs|apps|windows|elements <app> [depth]|hit x y|pressel <app> <i.j.k>|menus <app> [depth]|frame <app>|minsize|floor <bundle id> [--front]|press <app> <i.j.k> [--no-activate]|setframe <app> x y w h|setframeid <id> x y w h|watch <app> [seconds]|dragtitle <app> dx dy [sx sy]|hover x y [seconds]|click x y|drag sx sy ex ey [steps]|dragvia <steps> x1 y1 x2 y2 [x3 y3 ...]|dragappvia <app> <steps> x1 y1 x2 y2 [x3 y3 ...]"
let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(1) }

if !AXIsProcessTrusted() {
    print("Accessibility is not granted to this process (grant it to the terminal app running axprobe). Prompting…")
    // Swift 6: kAXTrustedCheckOptionPrompt is an imported `var` (not concurrency-safe), so use its literal key.
    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    if command != "prefs" && command != "windows" && command != "apps" { exit(2) }
}

switch command {
case "prefs":
    for key in ["EnableTilingByEdgeDrag", "EnableTopTilingByEdgeDrag", "EnableTiledWindowMargins", "EnableTilingOptionAccelerator"] {
        let v = CFPreferencesCopyAppValue(key as CFString, "com.apple.WindowManager" as CFString)
        print("\(key) = \(v.map { "\($0)" } ?? "nil")")
    }

case "apps":
    for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular {
        print("\(a.processIdentifier)\t\(a.localizedName ?? "?")\t\(a.bundleIdentifier ?? "?")")
    }

case "windows":
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for (i, w) in list.enumerated() {
        let bounds = (w[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
        print("\(i)\tid=\(w[kCGWindowNumber as String] ?? 0)\tpid=\(w[kCGWindowOwnerPID as String] ?? 0)\tlayer=\(w[kCGWindowLayer as String] ?? 0)\t\(w[kCGWindowOwnerName as String] ?? "")\t\(describe(bounds))")
    }

case "elements":
    // The front window's Accessibility subtree, with each element's role, title, enabled flag and
    // frame. The instrument for a window built in code: it says where a control actually is, which a
    // screenshot cannot, and whether anything answers at that point at all.
    guard args.count >= 2, let target = appElement(args[1]), let w = frontWindow(target.element) else { exit(1) }
    let maxDepth = args.count >= 3 ? (Int(args[2]) ?? 6) : 6
    func dumpElements(_ el: AXUIElement, path: [Int], depth: Int) {
        let kids = (axAttr(el, kAXChildrenAttribute) as [AXUIElement]?) ?? []
        for (i, kid) in kids.enumerated() {
            let p = path + [i]
            let role: String = axAttr(kid, kAXRoleAttribute) ?? ""
            let title: String = axAttr(kid, kAXTitleAttribute) ?? (axAttr(kid, kAXValueAttribute) as String? ?? "")
            let enabled = (axAttr(kid, kAXEnabledAttribute) as NSNumber?)?.boolValue
            let f = frame(of: kid)
            let indent = String(repeating: "  ", count: depth)
            let box = f.map { describe($0) } ?? "no frame"
            let en = enabled.map { " enabled=\($0)" } ?? ""
            print("\(indent)[\(p.map(String.init).joined(separator: "."))] \(role) \"\(title)\"\(en) \(box)")
            if depth < maxDepth { dumpElements(kid, path: p, depth: depth + 1) }
        }
    }
    report(window: w, label: "front window")
    dumpElements(w, path: [], depth: 0)

case "pressel":
    // AXPress on one element of the front window, by the index path `elements` prints. It bypasses
    // hit testing entirely, which is what separates "the button's action is broken" from "the click
    // never reached the button".
    guard args.count >= 3, let target = appElement(args[1]), let w = frontWindow(target.element) else { exit(1) }
    let path = args[2].split(separator: ".").compactMap { Int($0) }
    var el: AXUIElement? = w
    for index in path {
        guard let here = el, let kids = axAttr(here, kAXChildrenAttribute) as [AXUIElement]?, index < kids.count
        else { el = nil; break }
        el = kids[index]
    }
    guard let el else { print("bad path"); exit(1) }
    let role: String = axAttr(el, kAXRoleAttribute) ?? ""
    let title: String = axAttr(el, kAXTitleAttribute) ?? ""
    let err = AXUIElementPerformAction(el, kAXPressAction as CFString)
    print("AXPress \(role) \"\(title)\" -> \(err == .success ? "success" : "error \(err.rawValue)")")

case "hit":
    // What Accessibility says is at a screen point, and every element under it. The one honest answer
    // to "is my click reaching the button".
    guard args.count >= 3, let x = Double(args[1]), let y = Double(args[2]) else { exit(1) }
    let system = AXUIElementCreateSystemWide()
    var hit: AXUIElement?
    var raw: AXUIElement?
    let err = AXUIElementCopyElementAtPosition(system, Float(x), Float(y), &raw)
    hit = raw
    guard err == .success, let hit else { print("no element at \(x), \(y): error \(err.rawValue)"); exit(1) }
    var pid: pid_t = 0
    AXUIElementGetPid(hit, &pid)
    let owner = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
    let role: String = axAttr(hit, kAXRoleAttribute) ?? ""
    let title: String = axAttr(hit, kAXTitleAttribute) ?? (axAttr(hit, kAXValueAttribute) as String? ?? "")
    let enabled = (axAttr(hit, kAXEnabledAttribute) as NSNumber?)?.boolValue
    print("at \(x), \(y): \(owner) (pid \(pid)) \(role) \"\(title)\" enabled=\(enabled.map(String.init) ?? "?")")
    if let f = frame(of: hit) { print("  frame: " + describe(f)) }

case "menus":
    guard args.count >= 2, let target = appElement(args[1]) else { exit(1) }
    guard let bar = axElement(target.element, kAXMenuBarAttribute) else { print("no menu bar"); exit(1) }
    let depth = args.count >= 3 ? (Int(args[2]) ?? 2) : 2
    dumpMenu(bar, path: [], depth: 0, maxDepth: depth)

case "frame":
    guard args.count >= 2, let target = appElement(args[1]), let w = frontWindow(target.element) else { exit(1) }
    report(window: w, label: "front window")
    var settable: DarwinBoolean = false
    AXUIElementIsAttributeSettable(w, kAXSizeAttribute as CFString, &settable)
    print("  size settable: \(settable.boolValue)")
    print("  subrole: \(axAttr(w, kAXSubroleAttribute) as String? ?? "")")
    print("  title: \(axAttr(w, kAXTitleAttribute) as String? ?? "")")

case "press":
    guard args.count >= 3, let target = appElement(args[1]) else { exit(1) }
    let path = args[2].split(separator: ".").compactMap { Int($0) }
    guard let bar = axElement(target.element, kAXMenuBarAttribute), let item = resolve(path, from: bar) else { print("bad path"); exit(1) }
    let title: String = axAttr(item, kAXTitleAttribute) ?? ""
    let w = frontWindow(target.element)
    if let w { report(window: w, label: "before") }
    if !args.contains("--no-activate") {
        target.running.activate(options: [])
        if let w { AXUIElementPerformAction(w, kAXRaiseAction as CFString) }
        usleep(150_000)
    }
    let t0 = Date()
    let err = AXUIElementPerformAction(item, kAXPressAction as CFString)
    print("press \"\(title)\" -> \(err == .success ? "success" : "error \(err.rawValue)")")
    if let w {
        var last: CGRect?
        for _ in 0..<15 {
            usleep(100_000)
            if let f = frame(of: w), f != last {
                print(String(format: "  t=%.2fs ", Date().timeIntervalSince(t0)) + describe(f))
                last = f
            }
        }
        report(window: w, label: "after")
    }

case "setframe":
    guard args.count >= 6, let target = appElement(args[1]), let w = frontWindow(target.element) else { exit(1) }
    let v = args[2...5].compactMap(Double.init)
    guard v.count == 4 else { print(usage); exit(1) }
    let r = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    report(window: w, label: "before")
    let e1 = axSet(w, kAXPositionAttribute, point: r.origin)
    let e2 = axSet(w, kAXSizeAttribute, size: r.size)
    print("set position -> \(e1.rawValue), size -> \(e2.rawValue)")
    report(window: w, label: "after")

// Placing four windows of one application needs each one addressed on its own: the front-window
// route can only ever reach one of them, and an AppleScript window index moves under you. This takes
// the CGWindowID `axprobe windows` prints and resolves it through `AccessibilityWindows`, the same
// private-SPI lookup the app itself uses — reused rather than declared a second time here.
case "setframeid":
    guard args.count >= 6, let wid = UInt32(args[1]) else { print(usage); exit(1) }
    let v = args[2...5].compactMap(Double.init)
    guard v.count == 4 else { print(usage); exit(1) }
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    guard let entry = list.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == wid }),
          let owner = entry[kCGWindowOwnerPID as String] as? pid_t else {
        print("no on-screen window with id \(wid)"); exit(1)
    }
    let adapters = AccessibilityWindows()
    guard let handle = adapters.handle(forWindowID: wid, pid: owner) else {
        print("no Accessibility window for id \(wid) of pid \(owner)"); exit(1)
    }
    let want = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    _ = adapters.setPosition(want.origin, of: handle)
    _ = adapters.setSize(want.size, of: handle)
    _ = adapters.setPosition(want.origin, of: handle)
    print("window \(wid) (pid \(owner)) -> " + describe(adapters.frame(of: handle) ?? .zero))

// Read-only. Asks every window of every regular running application for the two undocumented
// minimum-size attributes, and says why each one has no answer when it has none. Moves nothing.
case "minsize":
    var minSizeIDs: [String] = []
    var minimumSizeIDs: [String] = []
    var neitherIDs: [String] = []
    var windowCount = 0, appCount = 0
    var minSizeWindows = 0, minimumSizeWindows = 0, neitherWindows = 0

    for a in NSWorkspace.shared.runningApplications.sorted(by: { ($0.localizedName ?? "") < ($1.localizedName ?? "") })
    where a.activationPolicy == .regular {
        let appEl = AXUIElementCreateApplication(a.processIdentifier)
        // The same quarter-second bound the app itself uses: one hung application must not stall the probe.
        AXUIElementSetMessagingTimeout(appEl, 0.25)
        let windows = axElements(appEl, kAXWindowsAttribute)
        guard !windows.isEmpty else { continue }
        appCount += 1
        let name = a.localizedName ?? "?"
        let bundle = a.bundleIdentifier ?? "pid:\(a.processIdentifier)"
        print("\(name)  [\(bundle)]  pid=\(a.processIdentifier)")

        var appAnsweredMin = false, appAnsweredMinimum = false
        for (i, w) in windows.enumerated() {
            AXUIElementSetMessagingTimeout(w, 0.25)
            let minimized = (axAttr(w, kAXMinimizedAttribute) as NSNumber?)?.boolValue ?? false
            let current = axSize(w, kAXSizeAttribute) ?? .zero
            let title: String = axAttr(w, kAXTitleAttribute) ?? ""
            let subrole: String = axAttr(w, kAXSubroleAttribute) ?? ""
            let a1 = sizeAnswer(w, axMinSizeAttribute)
            let a2 = sizeAnswer(w, axMinimumSizeAttribute)
            windowCount += 1
            if a1.size != nil { minSizeWindows += 1; appAnsweredMin = true }
            if a2.size != nil { minimumSizeWindows += 1; appAnsweredMinimum = true }
            if a1.size == nil && a2.size == nil { neitherWindows += 1 }

            let v1 = a1.size.map { " \(plausibility($0, current: current))" } ?? ""
            let v2 = a2.size.map { " \(plausibility($0, current: current))" } ?? ""
            print(String(format: "  [%d] %@%@ size=%.1f x %.1f  \"%@\"", i, subrole, minimized ? " MINIMIZED" : "",
                         current.width, current.height, title))
            print("      AXMinSize     = \(a1.detail)\(v1)  settable=\(a1.settable)")
            print("      AXMinimumSize = \(a2.detail)\(v2)  settable=\(a2.settable)")
            // The cross-check that makes an "unsupported" believable: what the window *does* publish.
            // If no name containing "Min" or "Size" is listed, the attribute is genuinely absent rather
            // than merely refused on this call.
            var names: CFArray?
            if AXUIElementCopyAttributeNames(w, &names) == .success,
               let all = names as? [String] {
                let sized = all.filter { $0.localizedCaseInsensitiveContains("min") || $0.localizedCaseInsensitiveContains("size") }
                print("      published size-ish attributes: \(sized.isEmpty ? "(none)" : sized.joined(separator: ", "))")
            }
        }
        if appAnsweredMin { minSizeIDs.append(bundle) }
        if appAnsweredMinimum { minimumSizeIDs.append(bundle) }
        if !appAnsweredMin && !appAnsweredMinimum { neitherIDs.append(bundle) }
    }

    print("")
    print("— summary —")
    print("\(windowCount) windows across \(appCount) applications")
    print("answered AXMinSize:     \(minSizeWindows) windows / \(minSizeIDs.count) apps")
    print("answered AXMinimumSize: \(minimumSizeWindows) windows / \(minimumSizeIDs.count) apps")
    print("answered neither:       \(neitherWindows) windows / \(neitherIDs.count) apps")
    print("AXMinSize apps:     \(minSizeIDs.joined(separator: ", "))")
    print("AXMinimumSize apps: \(minimumSizeIDs.joined(separator: ", "))")
    print("neither apps:       \(neitherIDs.joined(separator: ", "))")

// The instrument behind `MinimumSizeList.builtIn`: what the app's own probe does to one window, from
// outside the app. Asks a bundle identifier's standard, resizable windows for 1 × 1, reads the size
// back twice 150 ms apart and keeps the smaller per axis (an application still applying the write
// answers the first read with a size on its way down), then puts the window back. One tab-separated
// line per window: bundle id, name, width, height, version. Nothing is printed for a window whose
// size did not move, which is a window that was not measured. `--front` takes the focused window
// alone and whatever subrole it reports — Numbers' document window is not `AXStandardWindow` — so
// the subrole filter stands only where the tool chooses the windows itself.
case "floor":
    guard args.count >= 2,
          let a = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == args[1] }) else {
        print("no running app with bundle id \(args.count >= 2 ? args[1] : "?")"); exit(1)
    }
    let floorApp = AXUIElementCreateApplication(a.processIdentifier)
    AXUIElementSetMessagingTimeout(floorApp, 1)
    var version = ""
    if let url = a.bundleURL, let b = Bundle(url: url) {
        version = "\(b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")/\(b.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")"
    }
    var measured = 0
    // An application whose windows are all on another Space lists none of them, and still answers for
    // its focused and its main window. `--front` asks for that one window alone, which is how to
    // measure an application one of whose windows must not be touched.
    let frontOnly = args.contains("--front")
    var floorWindows = frontOnly ? [] : axElements(floorApp, kAXWindowsAttribute)
    if floorWindows.isEmpty {
        floorWindows = [axElement(floorApp, kAXFocusedWindowAttribute) ?? axElement(floorApp, kAXMainWindowAttribute)]
            .compactMap { $0 }
    }
    for w in floorWindows {
        let subrole: String = axAttr(w, kAXSubroleAttribute) ?? ""
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(w, kAXSizeAttribute as CFString, &settable)
        let minimized = (axAttr(w, kAXMinimizedAttribute) as NSNumber?)?.boolValue ?? false
        guard frontOnly || subrole == (kAXStandardWindowSubrole as String), settable.boolValue, !minimized,
              let before = frame(of: w) else {
            FileHandle.standardError.write("\(args[1]): skipping a window (subrole \(subrole), settable \(settable.boolValue), minimized \(minimized))\n".data(using: .utf8)!)
            continue
        }
        _ = axSet(w, kAXSizeAttribute, size: CGSize(width: 1, height: 1))
        usleep(150_000)
        let first = axSize(w, kAXSizeAttribute)
        usleep(150_000)
        let second = axSize(w, kAXSizeAttribute)
        _ = axSet(w, kAXSizeAttribute, size: before.size)
        _ = axSet(w, kAXPositionAttribute, point: before.origin)
        guard let first, let second else { continue }
        let floor = CGSize(width: min(first.width, second.width), height: min(first.height, second.height))
        guard floor.width < before.width - 1 || floor.height < before.height - 1 else {
            FileHandle.standardError.write("\(args[1]): a \(Int(before.width))×\(Int(before.height)) window did not move; not measured\n".data(using: .utf8)!)
            continue
        }
        measured += 1
        print("\(args[1])\t\(a.localizedName ?? "?")\t\(Int(floor.width))\t\(Int(floor.height))\t\(version)\t(from \(Int(before.width))×\(Int(before.height)))")
    }
    if measured == 0 { FileHandle.standardError.write("\(args[1]): no standard resizable window to measure\n".data(using: .utf8)!) }

case "watch":
    guard args.count >= 2, let target = appElement(args[1]) else { exit(1) }
    let seconds = args.count >= 3 ? (Double(args[2]) ?? 10) : 10
    let t0 = Date()
    var last: CGRect?
    while Date().timeIntervalSince(t0) < seconds {
        if let w = frontWindow(target.element), let f = frame(of: w), f != last {
            print(String(format: "t=%.2fs ", Date().timeIntervalSince(t0)) + describe(f))
            last = f
        }
        usleep(100_000)
    }

case "dragtitle":
    guard args.count >= 4, let target = appElement(args[1]), let w = frontWindow(target.element) else { exit(1) }
    guard let dx = Double(args[2]), let dy = Double(args[3]) else { print(usage); exit(1) }
    guard let f0 = frame(of: w) else { print("no frame"); exit(1) }
    report(window: w, label: "before")
    target.running.activate(options: [])
    AXUIElementPerformAction(w, kAXRaiseAction as CFString)
    usleep(300_000)
    let restoreCursor = CGEvent(source: nil)?.location ?? CGPoint(x: f0.midX, y: f0.minY)
    var start = CGPoint(x: f0.midX, y: f0.minY + 12)
    if args.count >= 6, let sx = Double(args[4]), let sy = Double(args[5]) { start = CGPoint(x: sx, y: sy) }
    let end = CGPoint(x: start.x + dx, y: start.y + dy)
    print("drag \(describe(CGRect(origin: start, size: .zero))) -> \(describe(CGRect(origin: end, size: .zero)))")
    postMouse(.leftMouseDown, start)
    usleep(50_000)
    let steps = 12
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        postMouse(.leftMouseDragged, CGPoint(x: start.x + dx * t, y: start.y + dy * t))
        usleep(16_000)
    }
    // A real drag always produces several events once the cursor reaches the edge; posting a single
    // one lets the window server coalesce it away, so dwell on the end point before releasing.
    for _ in 0..<4 {
        postMouse(.leftMouseDragged, end)
        usleep(25_000)
    }
    usleep(50_000)
    postMouse(.leftMouseUp, end)
    let t0 = Date()
    for _ in 0..<15 {
        usleep(100_000)
        if let f = frame(of: w) {
            print(String(format: "  t=%.2fs ", Date().timeIntervalSince(t0)) + describe(f))
        }
    }
    CGWarpMouseCursorPosition(restoreCursor)
    report(window: w, label: "after")

case "hover":
    guard args.count >= 3, let hx = Double(args[1]), let hy = Double(args[2]) else { print(usage); exit(1) }
    let hold = args.count >= 4 ? (Double(args[3]) ?? 3) : 3
    for i in 0...10 {
        let t = Double(i) / 10
        postMouse(.mouseMoved, CGPoint(x: hx - 40 * (1 - t), y: hy))
        usleep(16_000)
    }
    let until = Date().addingTimeInterval(hold)
    while Date() < until {
        // A jitter of a point: hovering is armed by movement, and a cursor that never moves again
        // stops the poll after two seconds by design.
        postMouse(.mouseMoved, CGPoint(x: hx, y: hy))
        usleep(200_000)
        postMouse(.mouseMoved, CGPoint(x: hx + 1, y: hy))
        usleep(200_000)
    }

case "click":
    guard args.count >= 3, let cx = Double(args[1]), let cy = Double(args[2]) else { print(usage); exit(1) }
    for i in 0...10 {
        let t = Double(i) / 10
        postMouse(.mouseMoved, CGPoint(x: cx - 40 * (1 - t), y: cy))
        usleep(16_000)
    }
    usleep(300_000)
    print("click \(Int(cx)),\(Int(cy)) — no movement between down and up")
    postMouse(.leftMouseDown, CGPoint(x: cx, y: cy))
    // Short on purpose: a real hand on the trackpad during a held button posts `leftMouseDragged`
    // events of its own, and this probe exists to produce a press with none.
    usleep(args.count >= 4 ? UInt32((Double(args[3]) ?? 0.01) * 1_000_000) : 10_000)
    postMouse(.leftMouseUp, CGPoint(x: cx, y: cy))
    usleep(300_000)

// A drag along a polyline. A straight drag never exercises a two-dimensional handle's growth phase
// followed by a shrink of the same member, which is where a cached size goes stale.
case "dragappvia":
    // `dragvia` with the one step that turns out to be load-bearing for a *window* drag: the owning
    // application is activated and the window raised first. Without it macOS does not treat the posted
    // press as a title-bar drag at all — the window never moves, so `DragSessionController` never
    // confirms a drag and the whole route is silently inert. `dragtitle` already did this and could
    // only travel in a straight line; a snap-bar drop needs a route (top edge, then a cell).
    guard args.count >= 7, let target = appElement(args[1]), let w = frontWindow(target.element),
          let legSteps = Int(args[2]) else { print(usage); exit(1) }
    let appCoords = args[3...].compactMap(Double.init)
    guard appCoords.count >= 4, appCoords.count % 2 == 0 else { print(usage); exit(1) }
    var appRoute: [CGPoint] = []
    for i in stride(from: 0, to: appCoords.count, by: 2) {
        appRoute.append(CGPoint(x: appCoords[i], y: appCoords[i + 1]))
    }
    report(window: w, label: "before")
    target.running.activate(options: [])
    AXUIElementPerformAction(w, kAXRaiseAction as CFString)
    usleep(300_000)
    let appRestore = CGEvent(source: nil)?.location ?? appRoute[0]
    print("drag " + appRoute.map { "\(Int($0.x)),\(Int($0.y))" }.joined(separator: " -> ") + " in \(legSteps) steps a leg")
    postMouse(.leftMouseDown, appRoute[0])
    usleep(50_000)
    for leg in 1..<appRoute.count {
        let from = appRoute[leg - 1], to = appRoute[leg]
        for i in 1...legSteps {
            let t = Double(i) / Double(legSteps)
            postMouse(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
            usleep(16_000)
        }
        // Dwell at each corner: the snap bar arms on the top edge and needs more than one event there,
        // and the window server coalesces a lone one away.
        for _ in 0..<6 { postMouse(.leftMouseDragged, to); usleep(25_000) }
    }
    usleep(50_000)
    postMouse(.leftMouseUp, appRoute[appRoute.count - 1])
    usleep(600_000)
    CGWarpMouseCursorPosition(appRestore)
    report(window: w, label: "after")

case "dragvia":
    guard args.count >= 6, let legSteps = Int(args[1]) else { print(usage); exit(1) }
    let coords = args[2...].compactMap(Double.init)
    guard coords.count >= 4, coords.count % 2 == 0 else { print(usage); exit(1) }
    var route: [CGPoint] = []
    for i in stride(from: 0, to: coords.count, by: 2) { route.append(CGPoint(x: coords[i], y: coords[i + 1])) }
    let first = route[0]
    for i in 0...10 {
        let t = Double(i) / 10
        postMouse(.mouseMoved, CGPoint(x: first.x + (first.x < route[1].x ? -40 : 40) * (1 - t), y: first.y))
        usleep(16_000)
    }
    usleep(300_000)
    print("drag via " + route.map { "\(Int($0.x)),\(Int($0.y))" }.joined(separator: " -> ") + " in \(legSteps) steps a leg")
    postMouse(.leftMouseDown, first)
    usleep(50_000)
    for leg in 1..<route.count {
        let from = route[leg - 1], to = route[leg]
        for i in 1...legSteps {
            let t = Double(i) / Double(legSteps)
            postMouse(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
            usleep(16_000)
        }
    }
    let last = route[route.count - 1]
    for _ in 0..<3 { postMouse(.leftMouseDragged, last); usleep(25_000) }
    usleep(50_000)
    postMouse(.leftMouseUp, last)
    usleep(300_000)

case "drag":
    guard args.count >= 5, let sx = Double(args[1]), let sy = Double(args[2]),
          let ex = Double(args[3]), let ey = Double(args[4]) else { print(usage); exit(1) }
    let steps = args.count >= 6 ? (Int(args[5]) ?? 20) : 20
    let start = CGPoint(x: sx, y: sy), end = CGPoint(x: ex, y: ey)
    // Hover in first, with real moves: anything armed by hovering needs the
    // move stream, and a single warp posts no event at all.
    for i in 0...10 {
        let t = Double(i) / 10
        postMouse(.mouseMoved, CGPoint(x: start.x + (start.x < end.x ? -40 : 40) * (1 - t), y: start.y))
        usleep(16_000)
    }
    usleep(300_000)
    print("drag \(Int(start.x)),\(Int(start.y)) -> \(Int(end.x)),\(Int(end.y)) in \(steps) steps")
    postMouse(.leftMouseDown, start)
    usleep(50_000)
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        postMouse(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
        usleep(16_000)
    }
    for _ in 0..<3 {
        postMouse(.leftMouseDragged, end)
        usleep(25_000)
    }
    usleep(50_000)
    postMouse(.leftMouseUp, end)
    usleep(300_000)

default:
    print(usage)
}
