import AppKit

/// Closure target for any `NSControl`.
///
/// The onboarding window is AppKit rather than SwiftUI, and an `NSButton` built in a loop has no
/// selector of its own to point at. The trampoline is retained by the control it serves, so it lives
/// exactly as long as the page that built it.
private final class ActionTrampoline: NSObject {
    let handler: () -> Void
    init(_ h: @escaping () -> Void) { handler = h }
    @objc func fire(_ sender: Any?) { handler() }
}

/// The associated object needs a unique address and nothing else: the byte behind it is never read and
/// never written, by this file or by the Objective-C runtime. `nonisolated(unsafe)` says exactly that —
/// a pointer that is an identity rather than storage. The usual `&someGlobal` spelling is what Swift 6
/// refuses, because passing it is a write to shared mutable state whatever the callee does.
private nonisolated(unsafe) let trampolineKey = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

extension NSControl {
    var actionHandler: (() -> Void)? {
        get { (objc_getAssociatedObject(self, trampolineKey) as? ActionTrampoline)?.handler }
        set {
            guard let h = newValue else {
                objc_setAssociatedObject(self, trampolineKey, nil, .OBJC_ASSOCIATION_RETAIN)
                return
            }
            let t = ActionTrampoline(h)
            objc_setAssociatedObject(self, trampolineKey, t, .OBJC_ASSOCIATION_RETAIN)
            target = t
            action = #selector(ActionTrampoline.fire(_:))
        }
    }
}
