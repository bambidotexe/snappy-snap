# Private macOS interfaces SnappySnap uses

**Every private symbol in the app is in the table below.** If a symbol is not here, it is not used; if
it is used and not here, that is a bug in this document. `PrivateSymbol.allCases` in
`Sources/SystemAdapters/PrivateAPI.swift` is the list this table is written from.

## The policy in one paragraph

Private symbols are allowed where they buy performance, smoothness or a capability the public API
demonstrably lacks. Each one is **resolved at runtime with `dlsym`, never linked** — a symbol a future
macOS has dropped is `nil`, not a launch failure. Each one has a **public route** that works with the
symbol absent, which may be less exact or less smooth but may not be less safe and may not crash. All
of them sit behind **one switch**, Settings › System › Compatibility → "Use hidden macOS features"
(`Settings.usePrivateAPIs`, default **on**), which takes effect on the next call and needs no
relaunch. The switch is mirrored into `PrivateAPI.shared.isEnabled` by
`AppDelegate.followPrivateAPISetting()`.

## The symbols

| Symbol | Framework | Used in | Why | Public route, and what it loses | macOS verified |
|---|---|---|---|---|---|
| `_AXUIElementGetWindow` | HIServices (ApplicationServices) — already in the process, so nothing extra is loaded | `SystemAdapters/AccessibilityWindows.swift` — `windowID(of:)`, `windows(ofPid:)`, `identify(_:pid:)` (the last is `window(at:)`'s, on the mouse-down path) | The exact link from an Accessibility window element to its `CGWindowID`, in one call. That id is the key to everything the app remembers about a window: the pre-snap frame in `SnapRegistry`, the pair cell, the Snap Assist phase after a snap-bar drop, the parked-window store, the per-window minimum-size record, and the handle bar's and junction knobs' pairs. | Match by frame against `WindowList.snapshot()`'s entries for the same pid, closest-first, each entry claimed once. Two shapes: `matchWindowIDs` for a whole application (two AX reads per window plus one window-list copy) and `matchWindowID` for the one element already in hand (`identify(_:pid:)` on mouse-down, **two** AX reads and one window-list copy, whatever the app's window count). **Costs** those extra reads; the mouse-down worst case against a hung app is 0.50 s rather than 0.25 s, both under the 1.00–1.05 s tap-disable threshold. **Cannot answer** for a window `snapshot` filters out — minimised, on another Space, not a regular app, or under 50 pt a side — which are the windows no feature offers anyway, since every one of them is built from that same snapshot. **Guesses** when one app has two windows at exactly the same frame: both sequences run front to back, so the *n*th AX window takes the *n*th list entry, and the single-element form takes the frontmost. | 27.0 (build 26A428) |
| `CGSMainConnectionID` | SkyLight (`/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight`, opened lazily by path) | `SystemAdapters/BackgroundCursor.swift` — `enable()`; `SystemAdapters/ElevatedSpace.swift` — `ensureSpace()` | Our process's window-server connection id, which is the first argument of every other SkyLight call in this table. | None needed on its own: without it `enable()` returns false and `ElevatedSpace.add` returns false, and the routes below are simply off. | 27.0 (build 26A428) |
| `CGSSetConnectionProperty` | SkyLight (same image) | `SystemAdapters/BackgroundCursor.swift` — `enable()`, called by `HandleContentView.startAsserting` on every show of the pill (`HandlePanel`) and the knob (`JunctionPanel`) | Sets `SetsCursorInBackground` on our own connection, after which the entirely public `NSCursor.set()` reaches the screen from an app that is neither active nor key. Public AppKit cannot: the window server takes a cursor only from the *active* application, and the `SetsCursorInBackground` **Info.plist key is dead on macOS 27** (four configurations tested), so this property is the only route. The override is **global**, so a cursor is asserted only while the pointer is inside a handle's hover band, re-tested on a 16 ms keepalive. | No cursor over the handles at all: `enable()` returns false, no keepalive runs, and the pill and knob shapes are the whole affordance. | 27.0 (build 26A428) |
| `CGSSpaceCreate` | SkyLight (same image) | `SystemAdapters/ElevatedSpace.swift` — `ensureSpace()`, reached from `prepare()` at the start of a drag and from `add(_:)` | Creates a window-server Space owned by this process — once per launch, kept for the life of the process. With the three rows below it is the **only** way the snap bar's notch shape can draw over another notch utility's: those utilities put their windows in a Space at absolute level 400, and a Space's level is compared before any window's. Measured against one at window levels 2147483629 and 2147483628: a panel of ours lists *below* both at every window level from 19 to `kCGMaximumWindowLevel`, with `orderFrontRegardless` repeated every 50 ms, with `sharingType = .none`, and with `order(.above, relativeTo:)` given its window number. | The notch shape stays on the user's Space at its ordinary level and draws **below** other notch utilities: their shape shows over its top edge. Nothing else changes — the shape, its spring, its cells and its hit testing do not depend on the Space. | 27.0 (build 26A428) |
| `CGSSpaceSetAbsoluteLevel` | SkyLight (same image) | `SystemAdapters/ElevatedSpace.swift` — `ensureSpace()` | Places that Space at absolute level **401**. Measured with a probe panel at plain `.statusBar`: in a Space at 400 it lists below the other utility's panels; at 401 it lists first. | As the row above. | 27.0 (build 26A428) |
| `CGSShowSpaces` | SkyLight (same image) | `SystemAdapters/ElevatedSpace.swift` — `ensureSpace()` | Makes the created Space visible; until then a window in it draws nowhere. | As the row above. | 27.0 (build 26A428) |
| `CGSAddWindowsToSpaces` | SkyLight (same image) | `SystemAdapters/ElevatedSpace.swift` — `add(_:)`, called by `SnapBarPanel.presentNotch` after every order-front | Adds the notch shape's panel to the elevated Space, *in addition to* the user's, so the panel's collection behaviour and the app's Space handling are untouched. Membership ends with the window: `SnapBarController` replaces the panel when the switch changes, which is how a panel leaves the Space without a fifth symbol. | As the row above. | 27.0 (build 26A428) |
| `OBJC_CLASS_$_CABackdropLayer` | QuartzCore — already in the process | `SystemAdapters/BackdropLayers.swift` — `makeBackdropLayer()`, used by `NotchBackdropView` for the blur and by `BackdropLumaTracker` for the luminance reading | A layer that draws the window server's picture of **what is behind this window** — `windowServerAware` — with no material and therefore **no tint**. `NSVisualEffectView` cannot stand in: a material is a uniform blur plus a tint, and around a black shape the tint reads as a grey frame whatever masks it. With `tracksLuma` it also reports that picture's mean luminance to its delegate (`backdropLayer:didChangeLuma:`) — measured at 1.0000 over a white window, 0.0000 over black, 0.5000 over mid grey — which needs no Screen Recording because the picture never leaves the window server. An Objective-C class, resolved through `dlsym` by its linker name like any other symbol. | **No backdrop blur at all**, and the contrast outline becomes a constant hairline at 0.10 instead of following the backdrop. The shape keeps its shadow. Less good; never a grey frame. | 27.0 (build 26A428) |
| `OBJC_CLASS_$_CAFilter` | QuartzCore — already in the process | `SystemAdapters/BackdropLayers.swift` — `makeVariableBlur(radius:mask:)` | Core Animation's `variableBlur` filter (`filterWithType:`), which blurs the backdrop by `inputRadius` scaled per pixel by `inputMaskImage`'s alpha — what makes the blur fade with distance from the shape. Measured with a black/white edge under the filter and luminance probes on the dark side: a gaussian whose **σ is 2 × `inputRadius` × mask alpha**, in points on a 2× display, at radii 8 to 32 with an rms error under 0.01; a mask drawn opaque in its top half blurs the visual top half and leaves the bottom exactly unblurred. | As the row above: with either class absent there is no backdrop layer to filter, and none is made. | 27.0 (build 26A428) |

## What the Settings pane says, and what it does not

Settings › System › Compatibility shows **one line per thing the symbols buy**, not one per symbol —
the symbols' names say nothing to the person being asked. Settings › Health › Compatibility shows the
same lines, in the same colours, with the same tooltips (`PrivateAPI.report(for:)`). The four are `PrivateFeature`, beside
`PrivateSymbol` in `PrivateAPI.swift`:

| Line in Settings | Symbols it needs |
|---|---|
| Exact window matching | `_AXUIElementGetWindow` |
| Pointer over the handles | `CGSMainConnectionID`, `CGSSetConnectionProperty` |
| Snap bar above other notch apps | `CGSMainConnectionID`, `CGSSpaceCreate`, `CGSSpaceSetAbsoluteLevel`, `CGSShowSpaces`, `CGSAddWindowsToSpaces` |
| Blur behind the snap bar | `OBJC_CLASS_$_CABackdropLayer`, `OBJC_CLASS_$_CAFilter` |

A line reads **Available** when `dlsym` found **every** symbol of its row and **Missing** otherwise:
one absent symbol sends the whole feature down its public route, so reporting the others as present
would describe the machine's inventory rather than what the user gets. The connection id is in two
rows because both the cursor property and the Space are set on this process's connection. The line's
tooltip lists its symbols, each with its framework and *found* or *not found* — that is what a bug
report is read from.

A line reports **`dlsym` alone**: not whether the switch is on, and not whether the feature is on
screen. All nine symbols are called by this build, but the cursor shows only while the pointer is
over a handle, and the Space and the two Core Animation classes serve only the snap bar's notch
shape and island — which is why a line names what the symbols are *for* and says *Available*, never
that anything is being shown.

## What "verified" means in the last column

That `dlsym` found the symbol on that macOS build, asserted by
`PrivateAPITests.everySymbolResolvesOnThisMacOS`, which runs with `swift test`. A future macOS that
drops one is *allowed* to fail that test — that is what the test is for — and nothing else may fail
with it. When it happens, the fix is a row here saying so, not a re-link.

Three operational facts: `PrivateAPI` caches a failed lookup as well as a successful one for the life
of the process; it clears `dlerror()` between the `dlopen` and the `dlsym`; and `isEnabled` defaults
to on for the unit tests and for `axprobe`, neither of which has a settings file. Every resolution
logs one line in the `app` category. Opening SkyLight costs about 20 ms once per launch;
`SnapBarController.beginSession` pays it at the start of a drag in the notch appearance, so that it
never lands on the turn the shape starts to grow.

## Adding a symbol

1. A case in `PrivateSymbol`, with its `framework` and its `libraryPath` (nil when the image is
   already in the process), and a place in `PrivateFeature.symbols` — an existing feature's, or a new
   feature with the line Settings shows for it.
2. A call site that asks `PrivateAPI.shared.pointer(for:)` **on every use** — never cached in the
   caller, or the switch would need a relaunch — with a comment naming the symbol, the framework, why,
   and what the public route is.
3. The public route itself, written and tested. A `nil` check that degrades to nothing does not
   satisfy this.
4. A row in this table.

`PrivateAPITests.theInventoryIsNineSymbols` fails on a new case alone, and
`theFourFeaturesCoverEverySymbol` on a symbol no feature reports, which are the reminders to do the
other three.

## One thing this table does not cover

`BackgroundCursor.move` reads the system's own cursor artwork from
`…/HIServices.framework/Versions/A/Resources/cursors/<name>/`, preferring a `macos27/<name>/` variant
where one exists. That is **not a private symbol** — it is an ordinary file read of a PDF and a plist,
with no API, no entitlement and nothing to `dlsym` — so it has no row above and it is not behind the
switch. The path is undocumented all the same, so every step of the read is optional and the caller
falls back to `NSCursor.crosshair`. It is here because a reader looking for "what undocumented parts
of macOS does this app touch" should find it in one place.
