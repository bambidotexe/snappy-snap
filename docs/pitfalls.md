# SnappySnap — pitfalls

Traps only: things that look right and are not, on the macOS this app runs on. Each entry names the
symptom, why it fails for this app, what the code does instead, and how not to repeat it. Every
number was measured on an M4 Pro running macOS 27.0 (build 26A428), one 1512 × 982 display at 120 Hz,
working area 1512 × 890. `docs/macOS.md` lists the platform facts the app relies on; this file lists
the ones that bite.

This is the only document that may mention an approach that was tried and does not work.

---

## Accessibility and the window server

### 1. There is no API for a window's minimum size

**Symptom.** A divider drag asks a window for 300 pt; it lands at 480 and the layout overlaps.

**Why.** `AXMinSize` and `AXMinimumSize` do not exist. Measured across 7 windows of 5 applications in
four toolkits (a Cocoa document app, Finder, Safari, Terminal, an Electron app): every window answers
`attributeUnsupported` (−25205) on both, nothing matching "min" appears in any window's attribute
names, and neither is settable. TextEdit asked for 1 × 1 comes back 100 × 82; no attribute would have
said so.

**What the code does.** `MinimumProbe` writes 1 × 1, reads the size back, restores the original — one
visible blink, once per application — and every placement that lands larger than asked raises that
window's own floor (`EngineRouter.observe`, the handle controllers), never the application's row.
`MinimumSizeStore` keeps one row per application on disk and each held window's floor in memory;
`MinimumSizePolicy` decides what is believable.

**How to avoid.** Do not spend round trips on the attributes; they teach nothing. Learn floors from
writes and refusals only.

### 2. A frame is two writes, the size one is dear, and their order matters

**Symptom.** A window shrunk with position written first ends narrower than asked, and gets narrower
on every drag increment.

**Why.** `AXFrame` is not settable on any application tested (−25205 / −25200), so a frame is two
non-atomic writes. A size write costs 2–13 ms (Finder 8.1 ms against 0.13 ms for its position, Safari
13.4 against 3.4, TextEdit 2.2 against 0.09). Writing the position first while the window still has
its old, larger size runs the far edge past where it belongs; for a window at the right or bottom of
the display that is off the display, where macOS clamps the position. The size write then lands at the
clamped origin and the far edge retreats and stays retreated, compounding on every increment.

**What the code does.** `WindowWriter.plan`: size first unless the frame grows on some axis, so the
intermediate frame stays inside the union of the old and the new one.

**How to avoid.** Every window write goes through `WindowWriter`. Never write a frame by hand.

### 3. Waiting on an application does not parallelise within that application

**Symptom.** Four windows of one application released together move in visible steps, about five
frames each over a quarter-second animation; four windows of four applications are smooth.

**Why.** The cost of a write is the target application's main thread answering a synchronous mach
round trip. That waiting overlaps across applications and never within one. Four mixed windows written
serially on the main thread cost 64.0 ms mean / 80.4 ms p95 per pass; through one serial queue per pid
with a single-slot mailbox per window, 14.3 / 22.2 ms, with the main thread paying 0.01 ms per post at
121 Hz (per-window rates on a 120 Hz drag: Finder 81, TextEdit 109, Chrome 114, Preview 117). Four
Finder windows: 29 Hz threaded against ~35 serial. Four different applications are dearer than four of
one when one of them is Chrome, whose size write is the dearest call on this machine.

**What the code does.** `WindowWriter`: one queue per pid, one mailbox per window that drops stale
frames. The handle features move previews during the drag and write the windows once, on release.

**How to avoid.** Never design a live resize through Accessibility for two windows of one application.
Move a picture; write on release.

### 4. A main-thread read of a window with writes in flight queues behind the writes

**Symptom.** A 121 Hz drag drops to 83.5 Hz.

**Why.** The read waits inside the target application behind the worker's own calls. Measured: four
main-thread reads during a drag, 121 → 83.5 Hz.

**What the code does.** `DragSessionController.mouseDown` asks `WindowWriter.hasPending` before
reading and declines to arm rather than read; `restoringWindow` suspends `readFrame` while a drag-away
restore is out; what a caller needs to know about a window it is writing comes back as a flush outcome.

**How to avoid.** No Accessibility read of a window with posts pending, on the main thread, ever.

### 5. `AXPosition` is clamped to the desktop, not to a display

**Symptom.** A window asked to go to (3000, 2000) stops with a 40 × 91 pt sliver on screen; asking
twice changes nothing.

**Why.** The window server keeps a corner of every window on *some* display, whatever its size. The
bound is the union of them all, not the display the window started on.

**The trap that follows.** A position that hides a window on one display does not hide it on two.
Measured on two 2560 × 1440 displays side by side: a 1268 × 663 window anchored at the left display's
bottom-right corner, (2496, 1325), is honoured exactly — and 1204 × 115 pt of it is then drawn on the
right-hand display, unclipped. The Snap Assist deck shipped this: every card of a phase on the left
display appeared as a band along the bottom of the right one.

**What the code does.** `Deck.Placement` sends each card's overhang past whichever edge of the phase's
display has no display beyond it — the near edge when the far one is blocked, measured back from the
card's own size — and centres the card, whole, when neither is free. `Geometry.anchoredOrigin` anchors
a window that refuses the size a handle or junction release gave it to its zone's outer edges, so the
overhang runs inward and the neighbour is re-fitted against it. **An arrangement does the opposite on
purpose** (`functional.md` §5.5): windows whose minimums cannot share the working area pack from the
top-left and what is left over hangs past the right or bottom edge. On a display with another display
beyond that edge, where that overhang is drawn has not been measured: the measurement above is of a
window *mostly* past the edge, which macOS drew on the far display.

**How to avoid.** Nothing is hidden by moving it off *a display*; it is hidden by moving it off the
union. Before relying on an overhang, ask what lies beyond that edge. The clamp is symmetric and a
legal anchor is honoured to the point: on the same pair, requesting (−5000, 1325) lands at
(−1228, 1325), the same 40 pt seen from the other side.

### 6. Accessibility answers `frame` for a minimized window

**Symptom.** A minimized window is placed; the user finds it in the right half when they un-minimize it.

**Why.** A plausible frame is not proof of visibility.

**What the code does.** `EligibleWindows.candidate` asks `isResizable` then `isMinimized` before any
frame read; `snapPartner` re-asks `isMinimized` at mouse-up.

**How to avoid.** Ask `isMinimized` first, before the frame read, so the minimized case costs less.

### 7. A stall of about a second on the tap's run loop destroys mouse events

**Symptom.** A drag goes syrupy, then dead; the log says `event tap disabled by TIMEOUT`.

**Why.** The app's mouse events come from a listen-only `CGEventTap` whose run-loop source is on the
main run loop. Every Accessibility call on the main actor is time the tap is not served, and the window
server disables a tap after one stall of 1.00–1.05 s. Events in that window are gone, not delayed.

**What the code does.** Every `AXUIElement` carries a 0.25 s messaging timeout
(`AccessibilityWindows.messagingTimeout`); no window write happens on the main thread; the worst
main-thread path (the public identify route) is two reads, 0.50 s; `MouseEvents` re-enables the tap
and logs the reason and a count.

**How to avoid.** Bound every element's timeout, keep writes off the main thread, and never put an
Accessibility call in front of the frame that first shows a preview.

### 8. Mission Control announces nothing this app can observe

**Symptom.** A pill stays on screen over Mission Control's thumbnails; a Snap Assist phase's parked
windows stay parked.

**Why.** No workspace, distributed or Accessibility notification, no occlusion change, no frontmost
change fires. The only observable is the window list: WindowManager puts a full-size backdrop above
layer 0 (layer 19) 26–57 ms after the gesture. CGWindowList owner names are localized ("Fond d'écran"
on a French Mac), so a name comparison works in one language and fails silently in the next. On the
way out the backdrop leaves 332 ms after the exit keystroke and the Spaces bar at 466 ms, while the
windows are still growing back for ~300 ms more.

**What the code does.** `SpaceWatcher` polls the window list at 60 Hz while anything is live (10 Hz
otherwise); `MissionControlDetector.backdrop` keys on WindowManager's pid and a surface covering
≥ 90 % of a display's width and height; `MissionControlGate` turns it into one edge plus a 150 ms
re-offer grace.

**How to avoid.** Detect, by pid, from the window list. The poll rate is the whole latency.

### 9. A Space change is announced a second late, and an all-Spaces panel cannot be taken down in time

**Symptom.** "The pill was still there on the next Space."

**Why.** `NSWorkspace.activeSpaceDidChangeNotification` arrives 972–1007 ms after the slide starts. A
`.canJoinAllSpaces` panel rides the old Space off and is re-planted on the destination at +994.8 ms,
12.7 ms before the app is told, so no turn exists in which the app could remove it first.
`isOnActiveSpace` lies for one turn after a change. The notification must be observed on
`NSWorkspace.shared.notificationCenter`, not `NotificationCenter.default`.

**What the code does.** Every overlay is `.moveToActiveSpace` (it leaves with its Space and re-plants
in ~7 ms on `orderFrontRegardless()`, which is why every show path orders front before asking for
key). The early signal is two Space-bound 1 × 1 `SpaceSentinelPanel`s per display watched for
occlusion (the leading edge goes occluded at 27–53 ms, the trailing at 439–472 ms), confirmed in the
same turn by one window-list read that the sentinel was displaced (`SpaceSlideDetector`). The
notification stays as the backstop and is the only signal for a full-screen transition. Both routes
coalesce within 1.5 s.

**How to avoid.** Never `.canJoinAllSpaces` an overlay. Never read `isOnActiveSpace`.

### 10. A fully transparent 1 × 1 panel may post no occlusion change

**Symptom.** The sentinel signal silently never arrives.

**Why.** A window that contributes nothing to the window server has no occlusion state worth
changing, and a normal-level 1 × 1 behind a maximized window is already occluded before the slide.

**What the code does.** `SpaceSentinelPanel.alpha = 0.05` and level `.statusBar`, above Mission
Control's backdrop (layer 19). The alpha is a judgement call flagged as unverified on other hardware.

**How to avoid.** Keep the sentinels faintly opaque and above ordinary windows. If one is visible,
that is a report, not a fix.

### 11. A drag to the very top edge opens the Spaces bar

**Symptom.** A synthesized drag dies at y = 0 with every event swallowed; it looks like a dead tap.

**Why.** The Spaces bar takes every mouse event until dismissed, and it appears in the same window-list
sample as Mission Control's backdrop.

**What the code does.** `MissionControlDetector.covers` requires ≥ 90 % of both width and height, so
the bar alone never counts as leaving; `axprobe` drag routes aim at y ≈ 16.

**How to avoid.** Test full-display coverage, never "WindowManager is drawing something".

### 12. A cursor can only be shown through the window-server connection property

**Symptom.** Every AppKit route to a resize cursor over the pill yields the plain arrow.

**Why.** The window server displays a cursor only for the active application, and this app is an
`LSUIElement` accessory that never activates. Proved by elimination: a tracking area,
`acceptsMouseMovedEvents`, a `.cursorUpdate` area (it fires; it is not delivered while inactive),
SwiftUI `.pointerStyle`, and a key panel (making a panel key is activating) all fail. The
`SetsCursorInBackground` Info.plist key is dead on macOS 27 in four configurations.

**What the code does.** `BackgroundCursor.enable()` sets `SetsCursorInBackground` on our own
connection through `CGSMainConnectionID` and `CGSSetConnectionProperty` (SkyLight, `dlsym`), after
which the public `NSCursor.set()` reaches the screen. The override is global, so `HandleContentView`
asserts only while the pointer is inside the hover band, re-asserted at 60 Hz (16 ms and 50 ms held
10/10, 100 ms 9/10; `set()` costs 0.0003 ms), and stops on band exit, dismissal, Mission Control and
a Space change. Stopping never means `NSCursor.arrow.set()`, which would stomp the I-beam underneath.
`ignoresMouseEvents = false` on the panel is load-bearing: a click-through panel loses the cursor
region to the window beneath.

**How to avoid.** Assert only inside the band; stop, never reset.

### 13. A read-back taken before the application applied the write is the frame from before it

**Symptom.** A handle press against Terminal freezes the divider after 8 pt of travel; a floor equal
to the window's current size is stored and never re-probed.

**Why.** An application that reflows on resize (a terminal re-wrapping, an editor re-laying out)
answers the read with the size it still had. That is indistinguishable from "refused entirely", and
the two have opposite consequences. Terminal also rounds to a character grid: height grid 18 pt (ask
381 → 390, ask 380 → 372), width grid 8 pt, so every landing read as a refusal ratcheted a false floor.

**What the code does.** `MinimumSizePolicy.believableFloor`: an axis is believed only if the read-back
is smaller than the incoming size, positive, and under 80 % of the working area; otherwise a second
read is taken and the smaller kept (`settledFloor`). `landingIsEvidence` accepts a landing as a
refusal only if the frame differs from the pre-write frame by more than 1 pt on some axis.
`HandleDragMath.roundingAllowance = 12` (a third more than the measured 9 pt worst case) separates an
application's rounding from a refusal.

**How to avoid.** Never learn from a read that is not smaller than what the window came in with.

### 14. A wrong minimum cannot disprove itself through the feature that uses it

**Symptom.** A divider stops at a floor that is a lie, and every later probe sees a window already at
that floor.

**Why.** Once the store says 480, nothing ever asks for less than 480.

**What the code does.** `OversizeWatcher.observe` runs on every 10 Hz tick, gated by nothing — not
the preferences, not a live gesture, not the mouse button: a held window smaller than its saved size
right now lowers that size to its own on sight (`MinimumSizeStore.observe(windowID:pid:size:)`). Only
a window the app has held through Accessibility may do so, because CGWindowList cannot tell a sheet
from a main window.

**How to avoid.** Any cached fact about another application needs an observer that can contradict it
without the feature that consumes it.

### 15. `CGWindowID`s are recycled

**Symptom.** A record for a closed window answers for a new window of another application.

**Why.** The window server hands ids out again.

**What the code does.** Every per-window record carries the pid too: `MinimumSizeStore`'s window
table, `ParkedWindowsStore.Entry`, `AccessibilityWindows.handle(forWindowID:pid:)`.

**How to avoid.** Never key by `CGWindowID` alone across time.

### 16. The native `Window ▸ Move & Resize` path is real and unusable

**Symptom.** Tiling through the system's own menu items lands the window 300–600 ms after the drop and
steals focus.

**Why.** macOS 15+ adds the submenu to every AppKit application's Window menu with stable `_zoom*`
identifiers. The item only fires in the active application, so the target must be activated and given
≥ 300 ms to settle (150 ms silently does nothing); `AXPress` returning `.success` proves nothing, and
`AXEnabled` is a hint, not a gate; the frame has to be polled; the system animates the tile over
300–450 ms with no completion signal; discovering the items means walking the target's whole menu bar
over synchronous IPC on the run loop that serves the tap. Keystroke synthesis is no better: a
session-tap post goes to whatever application is frontmost, and `CGEvent.postToPid` moved nothing.
Writing `AXPosition`/`AXSize` to a natively tiled window drops it out of the tiled set, and macOS draws
its own 16 × 52 pt handle in the gap between two menu-tiled windows. The system's animation measured no
smoother than a display-link stepper started on the same run-loop turn as the drop.

**What the code does.** Places windows through Accessibility writes on a display link
(`SteppingSnapEngine`). `axprobe menus` and `axprobe press` remain as the instruments; the measurements
live in git history under `docs/spike-native-tiling.md` and `docs/spike/`, removed from the tree.

**How to avoid.** Do not try the menu route or keystroke synthesis again without re-reading this entry.

### 17. `@_silgen_name` makes a private symbol a load-time dependency

**Symptom.** The app fails to launch on a macOS that dropped `_AXUIElementGetWindow`.

**Why.** A linked declaration is resolved by dyld at load, not by the caller at call time.

**What the code does.** `PrivateAPI` resolves every private symbol with `dlopen`/`dlsym`, caches
failures as well as successes, clears `dlerror()` between the open and the lookup, and answers `nil`.
`rg silgen Sources` finds nothing.

**How to avoid.** Never declare a private symbol; resolve it.

---

## AppKit, SwiftUI and overlays

### 18. A SwiftUI gesture never fires on this app's panels

**Symptom.** Clicking beside a card does nothing; a `Color.clear` tap layer does nothing either.

**Why.** The app never activates and every overlay is a `.nonactivatingPanel`, so AppKit delivers a
click only to views that take first mouse. A SwiftUI `Button` does; `onTapGesture` does not.

**What the code does.** Every click on an overlay is hit-tested in the controller, against the global
mouse stream from the event tap, using the same SnapCore function that positions the view
(`SnapAssistCardLayout.cardFrame`, `HandleBarGeometry.band`, `JunctionGeometry.band`). The Snap Assist
card is not a `Button`; its only input is the Accessibility default action.

**How to avoid.** One geometry function draws the thing and answers the click. Two hit areas that can
disagree is a bug shape this project has paid for.

### 19. A panel that shows a cursor must still accept mouse events

**Symptom.** The pill draws and the cursor over it is the arrow.

**Why.** The window server hands the cursor to the topmost non-click-through window.

**What the code does.** `OverlayPanel.init(acceptsMouse:level:)` requires the flag; the pill and knob
panels pass `true` and handle no click. Their frames are exactly the hit band, so no point they cover
is a point where a click does nothing.

**How to avoid.** `ignoresMouseEvents = true` on a cursor panel silently removes the cursor.

### 20. A pointer outruns a 10 pt panel

**Symptom.** During a divider drag the cursor flickers to the I-beam of the window underneath.

**Why.** Over a 600 ms drag the pointer left and re-entered the resting 10 pt band five times, handing
the cursor region back each time.

**What the code does.** The pill panel widens to 96 pt across the divider while dragging
(`HandleBarGeometry.dragBandThickness`); the knob to 96 × 96 (`JunctionGeometry.dragBandSize`);
`HandleContentView.isDragging` keeps the cursor asserted for the whole gesture.

**How to avoid.** Widen the panel for the gesture, not the band.

### 21. `alphaValue` mid-fade is not a statement of intent

**Symptom.** A re-show landing during a dismiss reads "still visible", takes the move branch, and the
fade-out finishes and orders the panel out for the rest of the drag.

**Why.** The animator reports the value in flight.

**What the code does.** Every panel holds `isShown` as intent and voids superseded fades with a
generation counter (`OverlayPanel.fadeGeneration`).

**How to avoid.** Never infer visibility from alpha.

### 22. `setFrame(_:display:animate:)` spins a nested run loop

**Symptom.** The event tap stalls under a preview move.

**Why.** The synchronous animating variant runs a nested run loop under the tap's callback.

**What the code does.** Every panel move goes through `animator()` inside
`NSAnimationContext.runAnimationGroup`, including zero-duration groups used to cancel an animation in
flight.

**How to avoid.** Never call the animating `setFrame` on the tap's run loop.

### 23. A SwiftUI `Settings` scene cannot bring an `LSUIElement` accessory forward

**Symptom.** The Settings window opens behind the window it covers; the cooperative `activate()` lands
behind Finder.

**Why.** `.onAppear` fires once per scene, not per open, so there is no hook to activate from, and an
accessory app needs `activate(ignoringOtherApps: true)` to come forward. Centring in `init` measured
x = 756 on a 1512 pt display: it must wait for the first layout.

**What the code does.** `SettingsWindow` is an ordinary `NSWindow` the delegate owns; every `show()`
activates with `ignoringOtherApps: true`, and `windowWentAway` deactivates unless Snap Assist or
onboarding still needs the app active.

**How to avoid.** Own the window.

### 24. Overlay window levels are structural, not per-panel

**Symptom.** A preview that re-orders itself to the front on every zone change climbs over the bar.

**Why.** Nothing in AppKit sits between `.statusBar` (25) and `.popUpMenu` (101); a level chosen per
panel drifts.

**What the code does.** `OverlayLevel` is an offset from `.statusBar` — dim 0, zone preview 1, Snap
Assist 4, handle bar 8, snap bar 12 — written once in `OverlayPanel.init` and required, not defaulted.
The dim sits at `.statusBar` itself to cover the menu bar (24) and the Dock (20).

**How to avoid.** Add a level to the enum, never to a panel.

### 25. A raise activates the other application asynchronously

**Symptom.** Escape stops working in Snap Assist after a pick.

**Why.** `ax.raise` activates the picked window's application a moment later, undoing a
`makeKeyAndOrderFront` made on the same turn.

**What the code does.** `SnapAssistController.takeKeyBack` asks for key now and again after 0.12 s.

**How to avoid.** Re-assert key after any raise.

### 26. A drag can outlive its mouse-up

**Symptom.** A `.up` lost to a Space change leaves the gesture latched and the next click moves three
windows.

**Why.** The physical button bit flips milliseconds before the tap delivers `.up`, and a due `Timer`
runs before a mach-port source in the same run-loop pass, so "the button is up" on one poll orphans an
ordinary release.

**What the code does.** `OrphanDetector.shouldCancel`: the button up on two consecutive polls and no
mouse event in the last one. A cancelled drag writes nothing; a `.up` with no live drag writes nothing.

**How to avoid.** Two polls and a quiet stream, never one reading.

### 27. `CACurrentMediaTime()` is time since boot

**Symptom.** A zero-initialised timestamp reports the age of the machine.

**What the code does.** Every idle stamp is initialised to the current time.

### 28. A persisted default is not a default

**Symptom.** A default raised in code reached nobody whose file already held the old value, and the
migration written to fix it re-ran on every launch, because `didSet` does not fire in `init`.

**What the code does.** `SettingsStore` loads and never rewrites; every number that used to be a
slider is a constant in `Settings.Fixed` that was never persisted; the one key whose meaning changed
(`gap`, a number → a switch) is reinterpreted on read, not migrated on disk.

**How to avoid.** A control the user can move, or a constant that was never persisted. Never a rule
that rewrites their file.

---

### 47. A `Toggle` is a switch inside a grouped `Form` and a checkbox outside one

**Symptom.** The Settings window's Custom areas page was built as a `ScrollView` over a `VStack`,
because a full-height text editor does not belong in a settings form. The same `Toggle(_:isOn:)`
that draws a switch on the Settings tab drew a **checkbox** there, and the two tabs did not look
like the same application.

**Why.** On macOS a bare `Toggle` has no fixed appearance: `.formStyle(.grouped)` gives its
descendants the switch style and the trailing placement, and outside that context AppKit's default
is a checkbox. Nothing in the control says which it will be, and it is correct in both places.

**What the code does.** No page depends on a `Form`'s context. Every switch in the window is the
kit's `ToggleRow` (`UI/SettingsRows.swift`), which fixes both halves itself: `.toggleStyle(.switch)` at
`.controlSize(.mini)` with its label hidden, at the trailing edge of a row whose own `Text` is the
label. A page with a text editor in it and a page of switches are built from the same rows.

**How to avoid.** `.toggleStyle(.switch)` fixes the control and not its placement, so a toggle patched
that way on one page still reads as foreign beside a real form row on another. Build every row from
one kit, or every row from a grouped form, and never some of each. **A control's appearance is a property of where it is,
and the only way to know is to look at it in the running app beside the one it must match.**

---

### 50. A `MenuBarExtra`'s `isInserted` binding is read when the scene is re-evaluated, and an app with one scene is not re-evaluated

**Symptom.** *Show in menu bar* (§14) was built as
`MenuBarExtra("SnappySnap", systemImage: …, isInserted: <binding>)`, with the binding reading an
`@Published` property on the `AppDelegate` that mirrored the setting. The property changed — the
store published, the sink ran, the value was right — and the icon stayed in the menu bar. It only
ever followed the setting across a relaunch, which is the one thing the feature exists to avoid.

**Why.** `isInserted` is not observed. It is read when SwiftUI re-evaluates the scene, and nothing
made it: `@NSApplicationDelegateAdaptor` re-evaluating a *view* on an `ObservableObject` delegate is
not the same as a `Scene` body being rebuilt, and an `App` whose whole body is one `MenuBarExtra` has
no other reason to rebuild. The binding was read once, at launch.

**What the code does.** The SwiftUI app lifecycle is gone. `SnappySnapApp.swift` is a plain AppKit
`@main` that sets `.accessory` and calls `NSApplication.run()`, and `AppDelegate` owns an
`NSStatusItem` it adds to and removes from `NSStatusBar.system` in the same Combine sink that every
other followed setting uses. `NSStatusBar.system.removeStatusItem(_:)` takes the icon out and the
icons beside it close up; there is no state to observe and nothing to re-evaluate.

**How to avoid.** **A SwiftUI `Scene` is not a view: do not put a value that has to change at
runtime into one and expect it to be re-read.** Where the presence of a piece of AppKit is itself
the feature, own the AppKit object. The cost here was one round of "the toggle does nothing", which
looked like a broken binding and was a scene that was never asked again.

---

## Measuring this app

### 29. Screenshots are a poor instrument for overlay geometry; the window list is the instrument

**Symptom.** Hours squinting at a low-alpha overlay on a busy wallpaper in a 256-colour PNG.

**What the code does.** `swift run axprobe windows` reports this app's own panels in the same CG space
as every other window, at 0.25 ms a call.

**How to avoid.** Measure rects from the window list; use screenshots only to compare two shots at an
identical gap, or to look at a glyph.

### 30. `swift build` is the truth; SourceKit diagnostics are stale

**Symptom.** Tool-result diagnostics describe a file as it was several edits ago.

**How to avoid.** Build.

### 31. `swift test` prints one summary line per target, and a crashed target prints none

**Symptom.** A crashed target prints `Note: Some test targets reported failures:` with no summary
line, so a grep finds the other target's green line and the crash reads as a pass.

**How to avoid.** Count two summary lines for plain `swift test` (the sandboxed
`--build-system native --disable-sandbox` fallback merges the targets and prints one). A filter that
matches nothing in a target means that target prints no line either.

### 32. `#expect` does not abort, and it boxes `CGFloat` against `Double`

**Symptom.** `#expect(x.count == 1)` followed by `x[0]` traps and crashes the whole target (see 31);
two identical numbers print the same and compare unequal.

**How to avoid.** `try #require` where the next line indexes; compare whole `CGPoint`/`CGRect` values
or make both sides the same type (the tests use a `near` helper with an epsilon).

### 33. A test that reads the live desktop is nondeterministic

**Symptom.** `WindowListTests.onScreenSurfacesKeepsWhatSnapshotFiltersOut` failed twice in one day.

**Why.** It makes two window-list calls and a window changed between them.

**How to avoid.** Treat a one-off failure there as environmental; rerun before investigating.

### 34. `log show` returns nothing for this app; `log stream` does

**Symptom.** A diagnostic session with no data.

**How to avoid.** Start `/usr/bin/log stream --predicate 'subsystem == "dev.rubens.SnappySnap"'
--level debug` before reproducing. `--level debug` is required for the deck, handle and junction
lines; `log` alone is a zsh builtin.

### 35. Silence is a defect

**Symptom.** A feature that declines to offer itself and says nothing is indistinguishable from one
that is broken. Three investigations into a missing junction knob ended at a rejection that logged
nothing, and the cause turned out to be a candidate that was never proposed at all — the rule looked
for two dividers measuring as crossing, and the shapes that failed had no second divider to measure.
The junction diagnostic is also quieter than the defect: verdicts are logged only on change, and not
at all while the pointer has been still for 2 s.

**What the code does.** Every rejection logs why, once per change, with the numbers
(`JunctionDetector.Reason`, the oversize watcher, Snap Assist's declines).

**How to avoid.** Keep the pointer moving while capturing the `junction` log; add a log line before
adding a guard.

### 36. `open` fails with Launch Services error −600 from a sandboxed shell

**Symptom.** `Scripts/run.sh` builds, signs, kills the running app, and then prints
`_LSOpenURLsWithCompletionHandler() failed with error -600.` The app is left not running.

**Why.** Launch Services is not reachable from an agent's sandboxed shell; `pkill` ran, `open` did
not.

**How to avoid.** Run the relaunch step outside the sandbox (or `open /Applications/SnappySnap.app`
by hand) and confirm with `pgrep -x SnappySnap`. Never `open` a folder from an agent shell: it
navigates the user's own frontmost Finder window.

### 37. The development relaunch always exercises the crash path

**Symptom.** None, if you know: `Scripts/run.sh` uses `pkill` (SIGTERM), so every dev relaunch goes
through parked-window crash recovery rather than `applicationWillTerminate`.

**How to avoid.** Never make that path depend on a graceful exit; it is free coverage of the path that
matters most.

## The notch appearance

### 38. No window level puts a panel above a notch utility

**Symptom.** A panel at `.screenSaver`, at `CGShieldingWindowLevel() + 2`, even at
`kCGMaximumWindowLevel` (2147483631) still draws *under* a notch utility whose own panels report
levels 2147483629 and 2147483628. `CGWindowListCopyWindowInfo` lists our panels in the right order
among themselves and all of them after the utility's.

**Why.** A level orders a window among the windows of its Space. The utility's windows are in a Space
of their own at **absolute level 400**, and a Space's level is compared first. Repeating
`orderFrontRegardless` every 50 ms, `sharingType = .none`, the utility's exact collection behaviour
and `order(.above, relativeTo:)` with its window number all change nothing.

**What the code does.** `ElevatedSpace` creates a Space at 401 and *adds* the notch shape's panel to
it. Measured with a probe panel at plain `.statusBar`: in a Space at 400 it lists below the
utility's panels, at 401 it lists first.

**How to avoid.** When a window will not come forward, read `axprobe windows` — front to back — and
ask whether the window above is in the same Space before reaching for a higher level.

### 39. A material cannot be the blur around a shape

**Symptom.** A blur drawn with `NSVisualEffectView` around the black notch shape reads as a grey
frame over a light window, or a glow over a dark one. Masking it with a gradient moves the frame's
edge; forcing `darkAqua` changes its colour.

**Why.** A material is a uniform blur *plus a tint*, and the tint is what shows. There is no public
material without one.

**What the code does.** `BackdropLayers` makes a bare `CABackdropLayer` with `windowServerAware` —
the same behind-window picture, untinted — and blurs it with `variableBlur` by a per-pixel radius.
Where the mask is clear the backdrop is drawn exactly as it is, which cannot be told from its not
being there. Without private interfaces there is **no** backdrop blur rather than a tinted one.

**How to avoid.** Two separate masks exist and do different things: `CAFilter`'s `inputMaskImage`
scales the blur's *radius*, `NSVisualEffectView.maskImage` clips a material's *alpha* — and the
latter ignores an `NSImage(cgImage:size:)`, honouring only one built with a drawing handler.

### 40. A blur that follows an animating shape starves the zone preview

**Symptom.** The notch shape's own animation stutters, **and so does the zone preview's**, which
shares nothing with it but the main thread.

**Why.** Sizing the backdrop view to the animating shape means a layout pass, and a mask bitmap, on
the main thread on every frame of the spring — and a behind-window backdrop that changes size every
frame is re-sampled by the window server as well. The zone preview animates on the same run loop.

**What the code does.** The blur is one layer the size of the panel, masked once per bar size for the
*grown* shape; opening and closing only fades its opacity, which the render server animates. The
field is wide and soft enough — σ 27 pt — that at its final size behind a shape still arriving it
does not read as an object of its own, which a hard-edged material does.

**How to avoid.** Nothing under `SnapBarPanel` may run main-thread code per frame. If a regression in
one overlay's smoothness shows up in another's, look for per-frame main-thread work before anything
else.

### 41. A stroked shape made of touching pieces shows its seams

**Symptom.** Hairlines beside the notch shape's top corners — one down the body's edge through each
flare, one along the screen's edge — coming and going during the animation.

**Why.** A stroke traces every edge a path has. A shape assembled from sub-paths that touch has edges
inside it, and the contrast outline draws them; it fades in and out with the backdrop's luminance,
which moves while the shape grows, so the lines come and go.

**What the code does.** `NotchShape` is one contour: `Path.union` of the body and the two flares,
with the pieces **overlapping** by 2 pt rather than meeting on a shared edge — a boolean operation can
leave a sliver along one — and every piece starting above the panel's top edge, so the contour's top
side is off screen and is never stroked.

**How to avoid.** Render the shape offline with the stroke at full opacity over grey
(`ImageRenderer`) and sample just inside each join, at fractional sizes. Keep the sampling windows
clear of the real contour: near a flare's tip the legitimate outline runs along the top rows.

### 42. A number read off a screenshot by eye is not a measurement

**Symptom.** Four builds of the notch appearance, each rejected as looking nothing like the
reference: a 20 pt tinted halo where the reference has a 95 pt untinted blur, two tight dark shadows
where it has one soft one, corner radii of 14.5 and 26 pt where it has 17 and 34.

**Why.** Each number had been estimated from a glance at a capture, and an agent's shell has no
Screen Recording grant (`screencapture` fails with *could not create image from rect*), so nothing it
built was ever looked at before the user did.

**What the code does.** Every drawing number in `NotchGeometry` carries the measurement it was fitted
to: edge profiles and grey levels extracted from a 2× capture with a CoreGraphics script, this app's
own shape and shadow rendered offline through `ImageRenderer` and compared row by row, and the blur
calibrated on a bench of the app's own windows read by luminance probes.

**How to avoid.** Fit, then build. A row-0 reading of a concave fillet under-reads its radius — the
tip is thinner than any darkness threshold — so fit the whole profile, not its first point.

### 43. An overlay panel cannot be drawn across a display seam

**Symptom.** With three displays in a row, a drop preview on a display the drag had crossed onto
played half its appear animation. One screen showed the morph begin at the dragged window and the
rectangle vanish at the boundary; the other showed it arrive from nowhere. Bidirectional, at both
seams. The panel's own frame measured *correct* — `axprobe windows` put it at
`x=1504 y=-435 w=1300 h=1425`, the left half of the 2560 × 1440 external to within a point.

**Why.** `defaults read com.apple.spaces spans-displays` is `0`: displays have separate Spaces. A
window belongs to exactly one display's Space, so the window server clips it at the boundary. The
preview morphs out of the dragged window's frame, and a window grabbed near its middle beside a seam
straddles it — so the panel was ordered front straddling, planted on one side, and clipped there for
the rest of the gesture. The frame being right is what makes this expensive to find: every number in
the geometry checks out and the pixels still are not there.

**What the code does.** `Geometry.slid(_:inside:)` translates the departure rectangle onto the zone's
own display before the morph — smallest translation, never a resize, each axis on its own. The
journey then lies entirely on one display and one panel can draw all of it.

**The approach that failed.** Drawing the same morph on one panel *per* display the journey crosses,
each ordered front while inside its own display so the window server would plant it there, each
clipping its own share — the composition the user asked for. It was worse than the fade-in it
replaced. `.moveToActiveSpace` sends a panel to the *active* Space when it is ordered front, and
during a drag that is the Space of the display holding the dragged window, not the one the panel's
frame is over. Both panels land on the same Space and the second is clipped to nothing.

**How to avoid.** Nothing this app shows may span two displays. A surface whose geometry would is
confined to one of them before it is ordered front — and confining it is arithmetic in `SnapCore`,
not a collection-behaviour flag. `.canJoinAllSpaces` is not the escape either; pitfall 9 has the
measurement that rules it out.

### 44. Liquid Glass is real in the key window and flat in every other one

**Symptom.** Snap Assist offered three areas at once, each a panel of its own, each drawing its cards
with `.glassEffect(.clear, in:)`. Exactly **one** area showed real refractive glass; the other two
showed a flat fill of the same colour, with no refraction and no specular edge. Which area it was
moved with the arrangement: filling the top-left cell made the bottom-right one glassy, filling the
bottom-right made the bottom-left one glassy.

**Why.** It is the key window, and nothing about the wallpaper, the level, the size or the order the
panels were shown in. `SnapAssistPanel.present` ends in `makeKeyAndOrderFront`, so the last panel
presented held key — and in both arrangements that is exactly the area that looked right. macOS
composites true Liquid Glass for the key window and substitutes a flat fallback everywhere else.

The first explanation offered was that the material adapts to the luminance behind it, and two
screenshots killed it: the flat area sat on *darker* wallpaper than the glassy one in one shot and on
lighter in the next.

**What the code does.** All of a display's areas are drawn in **one** panel covering its working
area, each at its own cell inside it (`SnapAssist.areaFrame`). One window, one key window, real glass
on every card. The per-area fade and scale that the panels used to perform moved into SwiftUI, in
`SnapAssistAreaHost`.

**The same fix, mid-drag.** The floating snap bar had the identical symptom for the identical reason,
and takes key too (`SnapBarPanel.wantsKey`). The bar is up while the mouse button is *down* on another
application's window, which Snap Assist's surface never is, and taking key there is still safe:
`.nonactivatingPanel` takes key without activating this app, and the drag is read from a listen-only
event tap rather than from any window, so nothing about the gesture depends on who holds key. The
notch appearance draws on black, has no glass to lose, and never takes it.

**The consequence to accept.** That panel takes mouse events across the whole working area, so a
click outside every area ends the phase without reaching the window under it. Documented in
`functional.md` §8 rather than worked around: a click that cancels an arrangement is not also a click
on whatever it landed on.

**Related.** `Glass.interactive()` never fires anywhere in this app, for the neighbouring reason —
an accessory that never activates has no frontmost window, so the material sees no pointer. The hover
tint is fed from the event tap, hit-tested against the same card frame a click is (`functional.md`
§8). And the snap bar's glass, which has never rendered, is the same rule seen from the other side:
its panel is not key-capable at all.

### 46. A pipette on a translucent overlay reads a composite, not a colour

**Symptom.** Five opaque greys were tried for the drop preview's stroke against macOS's own, each
rejected: 186 too dark, 216 slightly too light, 204 slightly too dark, 210 too light, and 135 — the
value a colour pipette returned from the native preview itself — far too dark. The bracket kept
collapsing without closing.

**Why.** macOS strokes its preview with a **translucent** grey, so what a pipette returns is that
grey composited over whatever the stroke happens to cross. The same stroke reads ~147 over near-black
content, 204 over a mid wallpaper and ~227 over a pale one. No opaque colour is all three, so an
opaque stroke fitted against one wallpaper is wrong on the next, and a verdict gathered on a second
wallpaper reopens a number that was already right.

**What the measurement was.** Decomposing a capture of the native preview over a **yellow** wallpaper
— whose blue channel is 0, which makes the blend a two-equation solve rather than one equation in two
unknowns — gives the stroke's own colour as grey 216 at 68 % opacity: `c·a = 148` from blue, and red
falling 237 → 222 fixes `a = 0.685`. Green then predicts 206 against 204 measured, a residual of 2,
which is what confirms the colour is neutral rather than tinted.

**What the code does.** `OverlayAppearance.shapeColor` is opaque on purpose and is **not** trying to
track the system's. It is fitted by eye against the installed app, and `functional.md` §7 records
that it drifts from macOS's over very dark and very pale desktops by design.

**How to avoid.** Before fitting a colour to a system surface, establish whether that surface is
opaque. If it is not, a single sample is one equation in two unknowns: find a background with a
channel pinned at 0 or 255, or sample the same surface over two backgrounds, and solve for the colour
and its alpha together. Then decide whether to copy the alpha too — and if not, say in the document
that the match holds on one background only, so the next verdict is not read as a new defect.

---

## Modifiers and system gestures

### 45. fn is a system window-move gesture, so it cannot uncover a resize edge

**Symptom.** The handle pill and the junction knob sit in the gap between two windows, exactly over
the resize edge macOS gives each window, and they claim the press — so a single window cannot be
resized by hand while a handle is on offer. The fix is a modifier that takes the handles away while
it is held. fn (🌐) was the obvious candidate and it is the wrong one: holding fn and dragging is one
of macOS's own window-move gestures, so the key meant to uncover a resize edge **moved the window**
instead. The app's half worked perfectly — the pill vanished on the keystroke — and the gesture
underneath was still not a resize.

**Why it is not obvious.** The conflict is invisible from inside the app. Nothing is logged, nothing
fails, and the tap sees the modifier arrive exactly as designed; the system consumes the drag one
layer below. No amount of reading this app's own frames or log lines would have shown it.

**The modifiers in use.** **Command (⌘)** and **Option (⌥)**, named once each, in
`MouseEvents.Event.flagsChanged`. ⌘-dragging a *background* window is also a system gesture — it moves
the window without activating it — but a press that begins on the resize edge is resolved as a resize
before that gesture applies, which is what makes ⌘ usable here where fn is not. ⌥ is claimed by macOS
too, by `EnableTilingOptionAccelerator` — "Hold ⌥ while dragging windows to tile them" — which is off
on this Mac and which the app does not read (`functional.md` §20).

**The same gesture hides its press from a session tap** — entry 47.

**The rule this leaves.** A modifier for this app is not chosen by reading documentation. macOS
claims several of them for window management and says so nowhere in one place. Try it by hand on the
gesture it is meant to serve, with the app installed, before writing the behaviour down.

### 47. A window-server gesture reaches a session event tap as drags with no press and no release

**Symptom.** Holding fn and dragging from anywhere inside a window moved the window and nothing of
this app ever appeared: no zone, no snap bar, no custom areas. Nothing was logged either, because
nothing had been declined — the drag session arms on a press, and there was no press.

**Measured.** A listen-only tap at `.cgSessionEventTap` during a posted fn-drag received the two
`flagsChanged` and **30 `leftMouseDragged`, no `leftMouseDown` and no `leftMouseUp`**, while the
window's origin followed the pointer on every event. The same drag under a tap at `.cghidEventTap`
received the press, the 30 drags and the release. The window server takes the press and the release
between the two levels and lets the drags through.

**What holds.** One event carries **the same `timestamp` at both levels**, and the device-level
callback ran first on all six samples, registered second. `SnapCore.PressReconciler` pairs the two
streams on that: the session stays the authority, and the device tap — masked to presses and
releases, two events a click — supplies only a press no session press claimed before the first drag,
and that gesture's release. A device-level tap needs nothing beyond the Accessibility grant (it is
created or it is not; `MouseEvents.hearsDevicePresses`).

**Do not** move the whole tap to the device level: an event another process posts at the session
level never passes it.

### 48. `AXUIElementCopyElementAtPosition` fails over a view that implements no hit testing

**Symptom.** Snapping worked on Affinity when the window was grabbed by some parts of its title area
and not by others — no preview, no bar, nothing logged.

**Measured.** A grid of system-wide hit tests over the top 140 pt of its window: the first row and
everything from 51 pt down answered the `AXWindow` or an element inside it, and **the 15–42 pt band —
the custom title and tab strip — answered error −25208, `notImplemented`**, except over the few real
controls in it. `window(at:)` returned nil there and the press armed nothing. Asking the
*application* element rather than the system-wide one is no way round it, and off the application's
Space it answers the menu bar for every point.

**What holds.** On an error other than `cannotComplete`, the window is the frontmost listed window
containing the point, resolved to its element by id among `windows(ofPid:)` — 1 + N round trips on the
private route, spent only on a press whose hit test has already failed fast. `cannotComplete` is a
timeout, and an application that timed out once is not asked N more questions on the tap's run loop.

### 49. The window list cannot tell a window that draws from one that does not

**Symptom.** The handle pill was drawn on top of a note widget that a menu-bar application floats
over the desktop.

**Measured.** The widget: owner activation policy **accessory**, window **layer 3**, 719 × 539. It
fails `WindowList.snapshot`'s participant test twice, so the occlusion test — which only ever looked
at participants — never saw it. The obvious widening, "any on-screen window in front", is wrong on
this same desktop: the Dock owns a layer-20 window the size of the display, the menu bar a layer-24
one, and another application a click-through overlay at layer 1000 over the entire display, all with
alpha 1 and nothing drawn over most of their area. `kCGWindowAlpha` is the window's, not its
content's; nothing in the list says whether a window draws.

**What holds.** `CoveringSurface`: a non-participant counts as covering from layer 0 up to, and not
including, the Dock's — where windows are panels somebody put there to be looked at. It carries a
`zIndex` placed among the participants' so one comparison answers "in front of" for both.

## Updates

### 51. A helper started by the app dies with the app

**Symptom.** The app quits for an update and nothing happens: the helper that was to swap the two
bundles is gone.

**Measured.** Three throwaway launchd jobs, each spawning `sh -c 'sleep 4; echo > marker'` and
exiting at once. The plain `posix_spawn` child never wrote its marker: launchd kills whatever is left
in a job's process group when the job's main process exits, and an app opened through LaunchServices
is a launchd job too. The child spawned with `POSIX_SPAWN_SETPGROUP` and group 0 wrote it.

**What holds.** `DetachedProcess`: a process group of its own, no inherited descriptors, and an
environment of the app's making. Never a plain `posix_spawn`, never a shell `&`.

### 52. Everything that can refuse an update has to happen before the quit

**Symptom.** An updater that quits first and installs after can end with no app running and nothing
on screen to say why: the download was cut short, the image would not mount, the copy was not signed
by the same team, the folder was not writable.

**What holds.** The release is fetched, held against GitHub's length and SHA-256, unpacked, checked
(`StagedUpdateCheck`, `CodeSignature`) and the folder tried (`UpdateInstaller.obstacle`) while the
app is still up, where a failure is a sentence in the window. **Install and Relaunch** is enabled
only after all of it. What is left for after the quit is two renames on one volume and a launch,
each with its way back: a failed second rename undoes the first, and a new version that is not seen
running within 15 s, or is gone 2 s after it was seen, is moved out and the previous one moved back
and opened. The helper touches nothing until the app's pid is gone, and gives up untouched after
20 s.

### 53. The outcome has to be written before the new version starts

**Symptom.** The new version starts, finds no outcome to read and opens nothing; or it tidies the
`updates` folder while the helper still needs the previous bundle.

**What holds.** The helper writes `installed` before it opens the app and overwrites it if it rolls
back. The app's own tidying at launch removes the disk image, `staged` and `install.sh`, **never
`previous`**, which only the helper deletes, once it has seen the new version running.

### 54. A new version that is gone two seconds later has crashed, or has been quit

**Symptom.** The update is rolled back, and the previous version comes back, because the user quit
the new one as soon as it appeared: the relaunch shows the update window saying the install worked,
with a **Done** button and the menu bar a click away.

**What holds.** The launch that reads the outcome renames it to `result.read`. Gone with that mark in
place, the version had started and its quit is the user's; gone without it, the helper looks again for
as long as it first looked (an app changing hands with launchd is gone for that moment), and only if
it is still nowhere is the previous one put back. `UpdateController.start()` runs last in
`applicationDidFinishLaunching`, so the mark means the launch got that far.

### 55. A helper that gives up while the app may still quit

**Symptom.** Two clocks, the helper's limit and the app's "did not quit" notice, leave a gap in which
the app quits with no helper left: nothing installed, nothing running, nothing said.

**What holds.** One clock decides. After `Settings.Fixed.updateStallNotice` the app stops the helper
(`SIGTERM`; while the app runs the helper can only be in its wait, having touched nothing) and then
says so. The helper's own, longer limit serves only an app too hung to do that.

### 56. `ps` lists the path the kernel ran, not the one the app was installed at

**Measured.** An app reached through a symbolic link (`/tmp` is one) runs under its resolved path,
and `ps -axo comm=` lists that one. `kill -0` still answers for a process that has exited and has not
been reaped by whoever started it.

**What holds.** The helper looks for the executable under the installed path and under `pwd -P` of
it: missing a running version would roll back a good install. It counts an exited, unreaped app
(state `Z` in `ps`) as gone, and anything `ps` cannot say as still running, the safe way round.


## Onboarding

### 57. An `NSStackView` spacer with no intrinsic height absorbs every point of a page's slack

**Symptom.** The welcome window's stepping button was drawn at the bottom right of a list page and
could not be clicked, for ever, however many times it was pressed. `AXPress` on it worked. Every other
element of the page — the header, the row text, the "Granted" labels, the title bar's close button —
hit-tested correctly; only the button answered `AXWindow`, as if nothing were there. It began the
moment a permission was granted.

**Measured.** The footer was an `NSStackView` holding an invisible spacer and the button
(`NSStackView(views: [spacer, primary])`), with a width constraint and no height constraint. A bare
`NSView` has no intrinsic size, so nothing decided the footer's own height, and the enclosing vertical
stack handed it every point the page was not using. Granting a permission swaps a row's 26 pt button
for an 18 pt "Granted" label; the list shrinks by 36 pt, and that slack goes into the footer:

```
before the swap   footer bounds 460 × 24    button frame (381, 0,  79, 24)
after the swap    footer bounds 460 × 186   button frame (381, 81, 79, 24)
```

The button is still inside the footer, so nothing reports a broken constraint and `AXFrame` keeps
naming a plausible rectangle. It has simply stopped being where the page put it.

**What holds.** A footer is a plain `NSView` with the button pinned to its trailing edge **and to both
its top and bottom**, which fixes the footer's height to the button's. The slack is given somewhere on
purpose — a dedicated view between the list and the footer, with vertical hugging and compression
resistance at priority 1 — so it can never be taken by a control. `Metrics` decides sizes; a stack
view left free to decide one will.

**The instrument.** `swift run axprobe elements <app>` prints the front window's Accessibility subtree
with every element's frame, and `axprobe hit x y` says what a real hit test finds at a point. A frame
that names a rectangle and a hit test that finds nothing there is this class of bug. The
`onboarding` log category at `--level debug` prints the button's frame and, up the chain, each
superview's height and whether it still contains it.
