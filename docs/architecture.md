# SnappySnap — architecture

How the pieces fit. `docs/functional.md` is *what* the app does; this is *how*. `docs/macOS.md` is
the platform this stands on and `docs/pitfalls.md` is what it makes hard; most of the shapes below are
answers to something in one of them.

## 1. Three layers, dependencies downward only

```
        SnappySnap  (executable — AppKit @main + SwiftUI views, the menu-bar item)
             │   controllers, overlay panels, the engine, Settings and onboarding
             │
        SystemAdapters  (the only code that talks to macOS)
             │   Accessibility, CGWindowList, the event tap, screens, defaults
             │
        SnapCore  (pure Swift — CoreGraphics + Foundation, no AppKit)
                 geometry, resolution, planning, every decision that can be made
                 without asking the system anything
```

`Tools/axprobe` is a fourth target: a development probe that links `SystemAdapters` and ships with
nothing. There is no helper process, no XPC service and no launch agent; launch at login registers the
app itself through `SMAppService`.

The rule that keeps the shape honest: **anything that can be decided without asking macOS a question
lives in `SnapCore`.** That is why the snap bar's geometry, the drop planner, the Snap Assist card
layout, the deck's fan, the junction arithmetic, the minimum-size policy, the orphan rule and the
Mission Control detection rule are all pure functions, while the calls that *ask* live one layer up.

## 2. The one run loop

This is the constraint that shapes everything else.

- The app sees the mouse through a **listen-only `CGEventTap`** (`MouseEvents`) whose run-loop source
  is on the **main run loop**. The same tap carries `flagsChanged`, which is how the app reads
  Command and Option: a modifier inferred from the next mouse event would arrive too late for a key
  pressed with the pointer standing still. A second listen-only tap at the device level hears
  presses and releases only, and `PressReconciler` delivers from it the press and the release of a
  gesture the window server kept from the session (fn + drag).
- Every Accessibility call is a synchronous mach round trip. A call made on the main actor is
  therefore time the tap is not being served, and the window server disables a tap after a single
  stall of 1.00–1.05 s (pitfall 7).

Four mechanisms hold that line, and they are why several things look more elaborate than they need to:

1. **Every `AXUIElement` the app creates carries a 0.25 s messaging timeout**
   (`AccessibilityWindows.messagingTimeout`), so no single call can stall the loop.
2. **No window write happens on the main thread at all.** Every one goes through `WindowWriter`, on a
   serial queue belonging to the target window's **pid**. The main thread's whole share of a write is
   the post: 0.01 ms.
3. **The drag path makes at most one Accessibility read per frame**, and never in front of the frame
   that first shows the preview. `DragSessionController.lastKnownFrame` is a cache; the preview's
   appear-morph and the drop both read it rather than Accessibility.
4. **The main thread makes no Accessibility read of a window with posts in flight** (pitfall 4).
   `DragSessionController.restoringWindow` suspends `readFrame` for a window whose drag-away restore
   is still out; `mouseDown` asks `writer.hasPending` and declines to arm rather than read. What a
   caller needs to know about a window it is writing comes back as a flush outcome instead.

Below the tap's disable threshold the real failure mode is latency, not loss — and that latency
belongs to the *target application's* thread: a hung application blocks its own worker and nothing
else.

## 3. One coordinate space

**CG space**: origin at the **top-left of the primary display**, y **down**. It is what Accessibility,
`CGWindowListCopyWindowInfo` and `CGEvent` all use, so the app uses it everywhere — all of `SnapCore`,
all of `SystemAdapters`' outputs, every zone frame, every cursor point.

Cocoa (`NSScreen`, `NSWindow`, `NSEvent.mouseLocation`) is the exception: origin bottom-left, y up. It
is converted **only at the panel boundary**, by `CoordinateSpace`:

```swift
cgRect(fromCocoa r, primaryHeight h)  =  CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
cgPoint(fromCocoa p, primaryHeight h) =  CGPoint(x: p.x, y: h - p.y)
```

where `h` is the **primary** display's height, not the height of the display the window is on. The
vertical flip is its own inverse, so `cocoaRect(fromCG:)` is the same transform: one function, one
direction to get wrong.

Working area is `DisplayInfo.visibleFrame`; the cursor is resolved against `DisplayInfo.frame`,
because the pointer can enter the menu bar and a window cannot.

## 4. One drag, end to end

`AppDelegate.route(_:)` is the fan-out. Every mouse event is offered to the features in the order they
may claim it — **Snap Assist → junction knobs → handle pill → drag session** — and a feature that
claims one consumes it. Snap Assist is first because a click that ends a phase also puts the parked
windows back; passing it on would arm a drag on whichever window the restore just moved under the
cursor. The knobs precede the pills because at a crossing both would answer for the same point.

1. **`MouseEvents`** delivers `.down(point)` on the main actor.
2. **`DragSessionController.mouseDown`** asks `AccessibilityWindows.window(at:)` for the window under
   the cursor, rejects its own pid and anything whose size attribute is not settable, cancels any
   in-flight snap of that window, reads its frame once and enters `armed(handle, startFrame)`.
   `writer.hasPending(handle)` is asked **before** the cancel — a window with writes in flight cannot
   be read on this thread, and `cancel` makes the writer forget a window whose write is still inside
   Accessibility. A busy window still gets its animation cancelled and arms nothing.
3. **`.dragged`** in `armed`: one throttled frame read (≤ 1 per 1/120 s). Origin moved and size
   unchanged is a drag; a changed size is a resize gesture and the session is dropped. On
   confirmation:
   - `beginDrag` applies the optional drag-away restore from `SnapRegistry`, **posted** through
     `WindowWriter` and flushed. `lastKnownFrame` takes the *asked* frame at once, because the very
     next thing this event does is present the preview's appear-morph from it; the flush's
     `landedFrame` corrects it if the session is still dragging that handle;
   - `SnapBarController.beginSession` resolves the **pair partner once** — one `WindowList` snapshot
     plus a bounded Accessibility scan of at most 8 windows, handles memoised per pid;
   - `captureFillEvidence` caches, also once, every other window on screen from the same kind of
     snapshot and the two known minimums. Which of them stand beside a drop (`NeighbourEvidence`) is
     worked out once per display, the first time a zone of that display is resolved. Everything the
     drag path does afterwards is arithmetic against that cache.
4. **`.dragged`** in `dragging`, every event: `update(cursor:)` first, then the throttled frame read —
   the preview is presented from the cache before any round trip. `update` does three things:
   - `SnapBarController.update` decides whether the bar is visible — the floating bar's arming region
     being the identical test that resolves the top zone, the notch shape's the camera housing alone.
     Neither shows on that event: `SnapBarArming` turns it into a 125 ms dwell and the controller runs
     the clock, so the bar arrives off a `Task` with no event behind it. That is why the controller
     holds the last armed cursor, display and settings, and why it calls back to set the highlight;
   - `resolveZone` calls **`ZoneResolver.resolve`** (priority: snap-bar cell › corner › side › top ›
     none; an edge shared with another display differs only in its wider band), then builds and
     solves the **arrangement** for what the drop will actually place — once per zone, not once per
     event (§5);
   - `setZone` compares **both** the zone and the pair cell's companion half before presenting, which
     is what stops the preview replaying its appear animation as the cursor crosses the middle of the
     pair cell.
5. **`ZonePreviewController`** shows one click-through `ZonePreviewPanel` per display (plus a second
   pool for the pair cell's facing half), and `WindowPreviewGroup` draws any neighbour the
   arrangement moves.
   The frame the preview morphs out of is `Geometry.slid` onto the zone's own display first: a panel
   is planted on one display's Space and clipped there, so it cannot draw a journey across a seam.
   Both hold their intent in `isShown` and void superseded fades by generation (pitfall 21).
6. **`.up`**: the zone is re-resolved at the release point but **not presented**, then `finish`.
7. **`finish`** hands every window the arrangement places — the dragged one, a pair partner, the
   neighbours that give room — to **`ArrangementCoordinator.run`**, which writes each through
   **`EngineRouter.snap`** → **`SteppingSnapEngine`**, starting on *this run-loop turn*. A
   `CADisplayLink` at the display's refresh rate interpolates `from → to` with
   `AnimationCurve.easeInOut` and **posts** each tick's frame to `WindowWriter`, unthrottled — one
   post, two Accessibility calls on the pid's own worker, size first unless the frame grows, and the
   mailbox drops whatever the application was too slow to take (`PostRate` and the Smoothness setting
   pace the Snap Assist deck only). The exact final frame is posted and then
   *flushed*; that flush is the only read-back. What comes back is observed by `MinimumSizeStore` — a
   refusal raises the window's own floor — and the coordinator reads it for the **correction pass**: a landing that reveals a limit
   has the arrangement solved again and the windows that changed written again, at most twice.
8. The router records each result in **`SnapRegistry`** (`windowID → (preSnapFrame, snappedFrame,
   zone)`, valid while the window is within ±2 pt of `snappedFrame`). Once the **first** solution has
   landed — before any correction — the coordinator calls `DragSessionController.onSnapped`, which
   `AppDelegate` forwards to `SnapAssistController.begin` **with the `ZoneOrigin`** and the dragged
   window's `SizeLimits` as that landing left them.
9. **`ZoneOrigin` is the whole trigger**: `.snapBar` starts a Snap Assist phase; `.screenEdge` and
   `.pairCell` do not. It travels with the resolution rather than being re-derived, because by the
   time the window lands the bar is gone.

A **pair drop** places the dragged window left and the partner right, as one arrangement through the
same coordinator, both recorded. The partner is checked for `isMinimized` *before* its frame is read
(pitfall 6). If the partner's placement fails, the first stands.

## 5. What a drop will actually place

Every snap is an **`Arrangement`** (SnapCore, pure): a working area, a gap, and boxes — windows and
still-open cells — each with a preferred frame and its `SizeLimits`. **`ArrangementSolver`** is one
function from an arrangement to a frame per box. It works one axis at a time, in a space where every
frame is grown by half a gap so that neighbours share an exact edge, and its variables are the
**dividers**: a box's minimum is `X[hi] − X[lo] ≥ minimum`, two boxes in order are
`X[lo of the later] − X[hi of the earlier] ≥ 0`, and a longest path from the low edge, another to the
high edge, and the largest amount by which the first exceeds the second give the earliest and latest
position of every divider and the smallest overflow there can be. Dividers are then assigned as close
to where they are preferred as those bounds allow. The area's own high edge never moves: a box that
ends at it and cannot fit runs past it alone. A pair that stands diagonally is invisible to either
axis on its own, so the two are solved, checked, and — where such a pair has met — put in order on the
axis of the smaller push and solved again. The rules and their reasons are in `docs/functional.md` §5.

Who is in an arrangement is decided by three small builders, and that is the whole difference between
the kinds of snap:

- **`LayoutArrangement`** — a snap-bar layout with its members and its open cells; `aligned`, so every
  edge at one coordinate is one divider and a grid stays a grid. It takes no window that was on
  screen before. The bar drop, the pair cell and the Snap Assist phase are this.
- **`EdgeDrop`** — `plan`, for a side edge or a corner: the dragged window at the frame left by
  **taking what is free** on both axes at once, and the neighbours where they stand; not aligned, so
  only facing edges are one divider. `maximised`, for the top edge: the dragged window at the whole
  working area and nothing else in the arrangement, so no window on screen can change that frame.
- **`NeighbourEvidence`** (with `Occlusion`) — which windows stand beside an edge drop: they look
  tiled and they can be seen.

**`ArrangementFacts`** reads a landing: larger than asked is a minimum, smaller a maximum, within the
rounding allowance nothing. **`ArrangementCoordinator`** (app layer) is the one place the correction
pass lives: it solves, writes every member whose frame changes with `RefusalPolicy.leaveInPlace`,
gathers the landings, folds what they reveal into the arrangement, and solves again — at most twice.
Every window of the arrangement is a member, moved by the first solution or not, because a correction
may have to move one the first solution left alone; a neighbour's Accessibility handle is asked for
only when it has to be written. A member whose write was cancelled is never written again by that
run. **No callback runs on the turn it was caused on**: the engine cancels a window's running
animation synchronously when a new one starts for it, so one run's completion — which can end a whole
Snap Assist phase — would otherwise fire from inside the caller of another. Snap Assist numbers its
placements for the same reason: picks overlap in time, only the newest may move the open areas, and a
placement that ended while a newer one was running has the arrangement placed once more.

One consequence worth stating architecturally: **the solver is the only thing that decides a snap's
frames**, and the preview, the engine and the Snap Assist areas all read the same solution. There is
no second arithmetic that can disagree with what the user was shown.

## 6. Why every click on an overlay is hit-tested by hand

The app is an `LSUIElement` accessory that **never activates**, and every overlay is a
`.nonactivatingPanel`, so a SwiftUI gesture never fires (pitfall 18). The answer everywhere is the
same shape: **the controller hit-tests the global mouse stream against the same SnapCore geometry
function that positions the view.** `SnapAssistCardLayout.cardFrame` places the cards *and* answers
the clicks; `HandleBarGeometry.band` draws the pill *and* claims the press; `JunctionGeometry`
likewise.

The cursor is the other half of the same platform fact. `BackgroundCursor.enable()` sets
`SetsCursorInBackground` on our own window-server connection — `CGSMainConnectionID` and
`CGSSetConnectionProperty`, both resolved through `PrivateAPI`, both in `docs/private-api-index.md` —
after which the public `NSCursor.set()` reaches the screen. The property is global, so
`HandleContentView` asserts a cursor only while the pointer is inside the same band the controller
hit-tests the press against, on a 16 ms keepalive, and `AppDelegate.leftTheArrangement` stops both
handle controllers' assertions **before** anything else is cancelled. With the switch off or a symbol
missing, `enable()` returns false, no keepalive runs, and there is no cursor.

## 7. A handle drag, and a junction drag

One 10 Hz poll feeds both features, and it costs no Accessibility.

1. **`HandleBarController.tick`** (every 100 ms, and only while the cursor moved in the last 2 s)
   takes a `WindowList.snapshot()` and runs **`AdjacencyDetector.pairs`**. The snapshot carries
   z-order, so a pair's two windows are the frontmost windows visible on either side of the divider,
   and occlusion is judged where the pill is drawn.
2. The **snapshot** goes to **`JunctionHandleController.update(windows:)`** *first* — not the pairs,
   which cannot reach a diagonal pair or the free end of a divider. **`JunctionDetector.evaluate`**
   clusters every window's corners within the crossing tolerance, judges each cluster of two or more
   windows once, logs every verdict that changed, and keeps the accepted ones (`junctions(from:)`).
   Quadrant occupancy is resolved front to back; a member keeps the quadrants it wins and is dropped
   only when it wins none, and a quadrant nothing claims is left empty.
3. Then `updateHover` offers the pill, **unless** a knob claims that point.
   `JunctionGeometry.knobCentre(for:frames:)` puts the knob at the midpoint of the members' own facing
   edges — or at their shared edge on an axis where they all take the same side — read off the same
   frames the previews draw, so the disc and the previews can never disagree.
4. **Hover** fades in a `HandlePanel` over a 10 pt hit band and starts the cursor keepalive. The panel
   must still *accept* mouse events although it never handles a click (pitfall 19).

### Press, drag, release

5. **Press** pays the gesture's whole Accessibility cost and is the only place that pays any: two
   window lookups, two resizable checks, one frame read per window, and — for a window whose floor is
   not known — a **probe** (`MinimumProbe`). `MinimumSizeStore` holds the list — one row per
   application, on disk — and each held window's own floor in memory; `MinimumSizeList` and
   `MinimumSizePolicy` (pure, tested) decide what a row is, how it comes down and what counts as evidence.
6. **Each drag event makes no Accessibility call whatsoever.** `HandleDragMath.frames` puts the
   divider under the cursor, normalises the gap and clamps it so neither window goes under its floor;
   what moves is overlays only — the pill or knob, one `ZonePreviewPanel` per window
   (`WindowPreviewGroup`), and a `DimPanel` per display over the full display frame at
   `OverlayLevel.dim`. Because the clamp is a pure function of the requested divider and nothing is
   carried between passes, everything simply **stops** at a minimum and re-engages without a jump.
7. **A junction drag** is the same machinery in two axes. `JunctionDragMath` moves both dividers with
   per-window, per-axis clamping, and every member gets its own preview. What each axis spends on the
   gap is `Junction.halfGap`: half a gap where members face each other across it, nothing where they
   all take the same side. A one-sided axis is also the only one the working area bounds, because it
   is the only one whose members' shared edge grows outwards with nothing else to stop it — the press
   captures the `visibleFrame` of the display under the crossing for exactly that.
8. **A drag cannot outlive the mouse button.** `OrphanDetector` (pure, tested) watches the real button
   state on every poll and cancels a drag whose up was lost (pitfall 26).

### Release

The previews and the dim go at the mouse-up and every window animates to its frame through
`SteppingSnapEngine`, **shrinkers first, growers behind them** — a divider moves shared edges, and a
grower's target overlaps where a shrinker still is. The display's working area travels with each
animation, because the anchoring rule needs to know which edges are the display's own.

A window that lands larger than it was asked for is an application refusing the size: the window's
own floor is raised, and the **neighbour** is re-fitted once against the frame the refuser actually took
(`HandleDragMath.refit`). A landing counts as a refusal only when the frame differs from the pre-write
frame (`MinimumSizePolicy.landingIsEvidence`), because a read-back taken before the application
applied the write returns the old frame.

## 8. Leaving the arrangement

Every overlay is a `.moveToActiveSpace` panel and a live Snap Assist phase holds real windows parked
off-screen, so both ways out have to be *caught*, and they are not the same kind of signal (pitfalls 8
and 9).

- **Mission Control** is detected from `CGWindowListCopyWindowInfo` by `MissionControlDetector.backdrop`.
  `SpaceWatcher` polls at 60 Hz while anything is live and 10 Hz otherwise; `MissionControlGate` makes
  it an edge, so a phase is not ended ten times a second, and holds a 150 ms re-offer grace after the
  falling edge. The two handle features and the drag session still read `isShowing` as a **level**,
  because they re-offer themselves from their own poll and the window list inside Mission Control is
  full of scaled thumbnails.
- **A Space change** is caught by two 1 × 1 Space-bound `SpaceSentinelPanel`s per display, watched
  with `didChangeOcclusionStateNotification` and confirmed by `SpaceSlideDetector` asking whether the
  sentinel has been *displaced*. `activeSpaceDidChangeNotification` is the backstop and the only
  signal for a full-screen transition. Both routes report through one path that coalesces within
  1.5 s; the sentinels are lowered on report, because they belong to the Space just left. A sentinel
  is deliberately **not** an `OverlayPanel` — it must stay Space-bound to be displaced at all, and
  `OverlayPanel` is `.moveToActiveSpace` by definition.
- **One interruption fade covers every surface**: `OverlayPanel.interruptionFadeDuration`, 120 ms,
  alpha only. Each surface keeps its own timing for the ordinary end of its own gesture; an
  interruption is one event.
- **One piece of state survives a Space change**: a confirmed window drag, because macOS's own
  hold-at-the-edge gesture switches Space with the button still down. `cancelSession` takes the
  `SpaceInterruption` and leaves `DragSessionController.Phase.suspended` on a `.spaceChange` where it
  would otherwise leave `.idle`; `DragResumption` is the rule for which later drag event rebuilds the
  session. Everything else, Mission Control included, still ends outright.

The poll is behind `isLive`, so an idle app pays a 10 Hz timer and four boolean reads.
`leftTheArrangement` runs the same order as a display change: cursor assertions, drag session, phase,
knobs, pills.

## 9. The oversize watcher

`OversizeWatcher` runs its own 10 Hz timer and does two jobs from one `WindowList.snapshot()`.

- **Disproof** runs first and is gated by nothing: a window smaller than its own recorded floor loses
  that record (pitfall 14). It makes no Accessibility call, so it is safe while any gesture is live
  and while the button is down.
- **Correction** sits behind the gap switch, its own switch, `isSuspended()`, the left button, and its
  own in-flight set. It corrects one window per pass, through the engine, after the frame has been
  stable for 0.5 s, asks a window that rounded itself just over the gap once more for a size that
  rounds down, and remembers a refusal by its size so a window with a large floor is not fought ten
  times a second nor sent back to the gap's edge when it is moved. The rules are
  `SnapCore/OversizeCorrection.swift`.

It is the one background feature that writes, which is why every guard above is about *not* writing.

## 10. File → responsibility

### `Sources/SnapCore` — pure, no AppKit

| File | Responsibility |
|---|---|
| `Model.swift` | `DisplayInfo` (with `sharedEdges(among:)`), `WindowInfo`, `Edge` |
| `Localized.swift` | `L(_:)`, the one route a sentence this target shows a person takes to the screen, over `Bundle.module`; `localizationBundle`, so a test can ask which languages shipped |
| `Layouts.swift` | `UnitRect`, `Layout`, `LayoutCatalog` (four snap-bar layouts plus halves/quarters/fill, decoded from `Layouts.json` with a compiled fallback) |
| `Geometry.swift` | `Zone`, `ZonePreview.strokeWidth`, `ZonePreview.highlightFillWeight`, `Geometry.frame` (gap insetting, never rounds), `Geometry.anchoredOrigin` (the inward anchoring of a handle or junction release), `Geometry.slid` and `Geometry.departure` (where a snap animates from when the window was released across a display seam) |
| `ZoneResolver.swift` | `SnapBarHit`, `ZoneOrigin`, `ZoneResolution`, `ZoneResolver.resolve` |
| `CustomZones.swift` | The areas held under Command: the configuration's own JSON parser (comments, and a failure that names the array index, the key, the line and the column), the selector match by specificity, the anchor/percent/bounds arithmetic, the gap inset, and which area holds a point. `defaultConfiguration` and `example` are the two texts that ship |
| `SnapBarGeometry.swift` | The bar's frame, cells, zones and hit tests on whichever surface the appearance comes to on this display — floating bar, notch shape or island (`SnapBarAppearance.surface(on:)`, in `Settings.swift`) — carrying a `NotchGeometry` or an `IslandGeometry`, never both; `topInset = gap + strokeWidth + gap`; the arming and keep regions; `panelFrame`, which every panel-relative rect is measured from |
| `SnapBarArming.swift` | The arming dwell as a rule: whether an event starts a clock, keeps one, shows the bar at once or drops the wait, and whether an elapsed clock is still the one being waited on. The clock itself is `SnapBarController`'s |
| `NotchGeometry.swift` | The notch shape, on a display with a camera housing and nil on any other: the housing, the collapsed and grown shape, the panel that holds both, the stay region, its `BackdropField` — and every number the shape is drawn with, each with the measurement it was fitted to |
| `IslandGeometry.swift` | The island, on a display with no housing: the circle, the capsule and the grown shape 3 pt under the top edge, the arming region that reaches up to the edge, the stay region, its `BackdropField` — and every drawing number, each with the capture it was fitted to |
| `IslandPresence.swift` | The island's motion as a pure rule: its four states, the steps a transition between any two of them takes (with and without an interruption), each step's spring and delay, and the one point both scales are taken about |
| `BackdropField.swift` | What is laid out around a black shape at the top of a display, shared by the notch shape and the island: the blur field's weight at a point, the luminance region, and the panel that holds both and starts at the screen's edge |
| `PairCell.swift` | The conditional first cell as one zone with a fixed dragged/partner side |
| `Arrangement.swift` | What every snap places: `SizeLimits`, `ArrangementBox`, `Arrangement`, `ArrangementSolver` (dividers as variables, minimums as constraints, overflow past the right/bottom edge) |
| `LayoutArrangement.swift` | A snap-bar layout with its members and open cells, the cells withdrawn from the offer; `ArrangementFacts`, what a landing reveals |
| `EdgeDrop.swift` | A drop on a side edge or a corner: taking what is free on both axes at once, and the arrangement of the dragged window and its neighbours. A drop on the top edge: the whole working area, alone |
| `NeighbourEvidence.swift` | Which windows stand beside an edge drop — tiled-looking and visible — and `Occlusion.visibleFraction` |
| `SnapOccupant.swift` | `SnapAxis`, and `SnapOccupant`: a window on screen as a drop sees it |
| `SnapAssist.swift` | `SnapAssistCardLayout`, `SnapAssistCardReflow` (the shared curve and the click-resolution rule), `SnapAssistCardTarget` |
| `Deck.swift` | The clamp sliver, `Placement` (which corner of the phase's display the fan hangs from, and each card's slot), the fan, `animatedCount`, `overflowDelay`, the deal timing, `arrived`, `mayForgetRecord` |
| `Adjacency.swift` | `HandlePair`, `AdjacencyDetector.pairs` |
| `HandleDragMath.swift` | Divider maths, gap normalisation, minimum clamping with the 12 pt rounding allowance, `refit` |
| `MinimumSizeList.swift` | `MinimumRow` with its origin; `MinimumSizeList`: the built-in rows (every one a measurement), this Mac's own rows and removals, the effective list, and the four mutations — a row only ever comes down by itself |
| `OversizeCorrection.swift` | The oversize watcher's rules: `correction(for:in:gap:)` (what an oversized window is asked for, the offending axis only), `gridRetry` (the second ask for a window that rounded itself just over the gap), `sameSize` (a refusal is remembered by size, so moving the window does not re-correct it) |
| `PressReconciler.swift` | Pairs the device-level presses and releases with the session's mouse stream by timestamp, and says which ones the session never delivered |
| `CoveringSurface.swift` | Which non-participating windows can hide a pill or a knob (layer 0 up to the Dock's), and the `zIndex` that places one among the participants |
| `MinimumSizePolicy.swift` | `revealedFloor`, the one rule for what a landing reveals (past the 12 pt rounding allowance, per axis); what counts as evidence of a floor; `lowered(_:seeing:)`, how a saved size comes down; `WindowFloor`, a window's own raise over its row; the floor a press clamps with when the user has switched probing off (`unprobedFloor`, `floorWithoutProbing`); `presumedFloor`, how small an unmeasured window is presumed to go |
| `HandleBarGeometry.swift` | Pill size (4 × ≤ 48), hit band (10), drag band (96), the divider a pair of frames leaves |
| `Junction.swift` | `Junction`, `JunctionDetector`, the crossing tolerances |
| `JunctionGeometry.swift` | Knob diameter (3 × pill thickness), the 24 pt band, `knobCentre` |
| `JunctionDragMath.swift` | Two-axis divider maths with per-window, per-axis clamping |
| `PostRate.swift` | The rate the deck *aims* posts at, from the display's refresh rate and `Smoothness`; `DeckAnimator` is its only consumer |
| `OrphanDetector.swift` | The only evidence a mouse-up was lost |
| `HandleSuppression.swift` | Whether Command is holding the pill and the knobs off the screen; never a drag already in flight |
| `Animation.swift` | `AnimationCurve`, `UnitBezier` |
| `SnapRegistry.swift` | `windowID → (preSnapFrame, snappedFrame, zone)`, valid within ±2 pt; `stillSnapped(among:)`, how many windows on screen still sit where a snap left them |
| `Health.swift` | The Health page's shape: `HealthLevel` (green, orange, red; a reading is never a level), `HealthRow` (label, word, tooltip, fix) and `[HealthRow].warnings` (the fixes of its orange and red lines, each once), `InfoRow` (a blue reading), `HealthLimits` (at most 10 checks and 5 readings) |
| `HealthRules.swift` | Every state's colour, one rule each, used by the Health page **and** by every other page that shows the same state: `grant(held:required:)` (red only when the welcome window marks it required), the three tiling switches, the drag detection, its pauses, the Space watcher, stranded windows, the hidden features; `isCrashReport`; `EngineState`/`EngineFacts`, `NotificationGrant` |
| `HealthReport.swift` | `HealthFacts` (everything the page reports, as plain values, the moment included) → `checks(for:)`, the Health table (three lines always there, every other only while it is wrong), and `readings(for:)`, the Information table |
| `HealthWords.swift` | Every word the Health page shows, and the System and Gap groups' words for the states they share with it, through this target's catalogue |
| `SpaceInterruption.swift` | `SpaceInterruption`, `SystemWindow`, `MissionControlDetector`, `MissionControlGate`, `SpaceSlideDetector`, `DragResumption` |
| `UpdateCheck.swift` | The update check's whole decision, with no network in it: `ReleaseVersion` (dotted, numeric per component), `LatestRelease` + its parse of GitHub's JSON (the disk image, and the length and SHA-256 GitHub states for it), `decide` (strictly newer only) and `interpret` (a reply read by its status first) |
| `UpdateSchedule.swift`, `UpdatePanel.swift`, `UpdateSession.swift`, `StagedUpdateCheck.swift`, `UpdateInstallScript.swift` | The rest of the update's rules, all pure: when an unasked check is due; the Updates group (`press`, `checked`, `autoChecked`, `installFailed`); the update window's phases; what the copy taken out of a disk image must say about itself (same app, strictly newer, this macOS is enough); and the install helper — `UpdateInstallPlan` (its arguments), the `/bin/sh` text itself and `UpdateResult` (the one line it leaves for the next launch) |
| `Settings.swift` | `Settings` (the user's choices, one control each) and `Settings.Fixed` (everything that is a constant); `Smoothness` |

### `Sources/SystemAdapters` — the boundary

| File | Responsibility |
|---|---|
| `AX.swift` | Thin typed wrappers over `AXUIElementCopyAttributeValue` / `SetAttributeValue` |
| `Localized.swift` | `L(_:)` and `localizationBundle` for this target, as in `SnapCore` |
| `AccessibilityWindows.swift` | Window at a point — by the application's hit test, and by the window list where that answers an error other than a timeout — frame and size reads, direct position/size writes for the probe and the restore pass, title, raise, `isResizable`, `isMinimized`, windows of a pid, CGWindowID for an AX window. **Every element carries the 0.25 s messaging timeout** |
| `WindowList.swift` | Three `CGWindowList` reads, **no names**: `snapshot` (layer 0, regular apps, ≥ 50 × 50, own pid excluded) and `snapshotWithCoverers`, the same read with the `CoveringSurface`s beside it, `onScreenSurfaces` (unfiltered, for Mission Control), `onScreenIDsAndFrames` (for the sentinels) |
| `WindowWriter.swift` | **Every window write in the app.** One serial queue per pid, one single-slot mailbox per window; `begin`/`post`/`flush`/`cancel`, generations, outcomes back on the main actor |
| `MouseEvents.swift` | Listen-only session `CGEventTap` over the four left-button/move events **and `flagsChanged`**, beside a device-level one for presses and releases only, reconciled by `PressReconciler` so a gesture the window server keeps from the session still has its press and its release (`hearsDevicePresses`); which reports Command (⌘) and Option (⌥) — the app's two modifiers, named here and nowhere else; `onTapDisabled(reason, count)`, the pauses counted by reason, and `isListening`, whether macOS has the tap switched on |
| `Screens.swift` | Displays in CG space — the camera housing included, from the two auxiliary top areas — display under a point, shared edges, change notifications |
| `CoordinateSpace.swift` | Cocoa ↔ CG, used only at the panel boundary |
| `SpaceWatcher.swift` | The backstop notification, the 60/10 Hz Mission Control poll behind `isLive`, the Space-bound sentinels, and the 1.5 s coalescing that makes the two routes one; `isWatching` for the Health page |
| `PrivateAPI.swift` | `dlsym` resolution of the nine symbols, the switch, and `PrivateFeature`: the four things they buy, which is what Settings › System reports; `report(for:)`, a feature's symbols and whether each was found, the tooltip on System |
| `ElevatedSpace.swift` | A window-server Space of the app's own at absolute level 401, and adding a window to it — what draws the notch shape above other notch utilities |
| `BackdropLayers.swift` | `CABackdropLayer` told to look behind its window, the `variableBlur` filter, and `BackdropLumaTracker`, which reads the backdrop's luminance from the window server |
| `BackgroundCursor.swift` | `SetsCursorInBackground` on our connection; the system move glyph read from HIServices; `pointerLocation` |
| `MinimumSizeStore.swift` | The list under `minimumSizes.v3`, published; the held-window table (own floor, probed this session); `observe` from an Accessibility path and from the sweep, `recordProbe`, `refused`, and the user's `edit`/`add`/`remove`/`reset` |
| `SystemTilingPrefs.swift` | Reads `com.apple.WindowManager`'s four tiling keys: the two drag switches, the margins, and the ⌥ accelerator |
| `CrashReports.swift` | The Health page's crash line: this app's crash reports of the last week from `~/Library/Logs/DiagnosticReports` (by name, `HealthRules.isCrashReport`) |
| `Haptics.swift` | The trackpad actuator: one `.alignment` tap behind the user's switch, a no-op on a Mac with no Force Touch trackpad. The performer is injectable, which is the only way the switch's effect is testable |
| `Permissions.swift` | `AXIsProcessTrusted`, the prompt, deep links to the two System Settings panes |
| `SettingsStore.swift` | `Settings` as one JSON blob under `settings.v1`, published to SwiftUI. Tolerant decoding, no migrations |
| `ParkedWindowsStore.swift` | The crash-recovery record for parked windows, under `parkedWindows.v1`; `lastLoadWasUnreadable`, a record that was there and could not be read, for the Health page |
| `OnboardingState.swift` | Whether the welcome window has been finished, under `onboardingCompleted`. One fact about this Mac, not a setting: written only by the last page's button |
| `LoginItem.swift` | `SMAppService.mainApp` — the only source of truth for "launch at login" |
| `UpdateChecker.swift` | **The only network code in the app.** `UpdateChecker.check`, the latest-release request (`SNAPPYSNAP_UPDATE_FEED` replaces its URL with a stand-in), and `UpdateDownload`, one fetch of a disk image with its progress, held against the asset's stated length and SHA-256 before it is reported; completions come back off the main actor |
| `UpdateStager.swift`, `CodeSignature.swift`, `UpdateInstaller.swift`, `DetachedProcess.swift` | Making an update ready and handing it over. The stager mounts the image (`hdiutil`, then `diskutil image`), copies out the app carrying our bundle identifier, applies `StagedUpdateCheck` and `CodeSignature.verify` (valid, and from the running app's team when it has one), and detaches. `UpdateInstaller.obstacle` says why the app cannot replace itself where it is; `start` writes the helper and runs it through `DetachedProcess`, a `posix_spawn` in a process group of its own so that it outlives the app |

### `Sources/SnappySnap` — the app

| File | Responsibility |
|---|---|
| `SnappySnapApp.swift` | `@main`: holds the delegate, sets the accessory policy, runs `NSApplication`. The run loop is AppKit's, not SwiftUI's — the status item is added and removed as the user's choice changes, and a `MenuBarExtra` cannot be (`pitfalls.md` 50) |
| `AppDelegate.swift` | Permission gate, the welcome window, the whole wiring graph, `route(_:)`, `leftTheArrangement`, and `engineState`: whether the drag detection waits for the permission, runs, or failed to start, for the Health page |
| `SnapState.swift` | The shared `SnapRegistry`, and when a snap last landed |
| `Drag/DragSessionController.swift` | The drag state machine, the frame cache, the fill evidence, the drop |
| `Engines/EngineRouter.swift` | Screen resolution, registry bookkeeping, learning a refusal, cancellation |
| `Engines/SteppingSnapEngine.swift` | The display-link animation; the one engine. Posts through `WindowWriter`, flushes the last frame, and does what the job's `RefusalPolicy` says with a refused size: anchors inward, or leaves the window in place |
| `Engines/ArrangementCoordinator.swift` | Places an arrangement and corrects it from what landed: the drop, the pair and the Snap Assist pick |
| `OversizeWatcher.swift` | The 10 Hz sweep: disproving a floor, and bringing a window back inside the gap |
| `Overlays/OverlayPanel.swift` | Non-activating panel base, `OverlayLevel`, generation-counted fades |
| `Overlays/ZonePreviewPanel.swift` / `ZonePreviewController.swift` | The drop preview, one pool per display plus the pair's companion; `heavierFill` is the custom areas' highlight |
| `Overlays/CustomZonesPanel.swift` | Every custom area on one display, drawn as the drop preview, the one under the pointer more opaque; one pooled panel per display |
| `Overlays/SnapBar*.swift` | The bar's panel, view and controller on all three surfaces, including the pair partner resolved once per drag; the island kept up for the length of a drag over a display with no housing, its motion played one `IslandPresence` step at a time, and one island panel per display, built once and presented again; and the floating bar's and the notch shape's panel replaced when the surface or the private-interfaces switch changes |
| `Overlays/IslandBarView.swift` | `IslandShape` — continuous corners, scaled about a fixed point inside the path itself so fill, clip and stroke shrink together and a spring that crosses zero simply ends the shape — and the island's body: shape, shadow once grown, cells clipped to it, contrast outline all the way round |
| `Overlays/NotchBarView.swift` | `NotchShape` — one unioned contour, so its stroke has no edge inside it — and the notch body: shape, shadow, cells clipped to it, contrast outline, on one spring each way |
| `Overlays/NotchBackdropView.swift` | Under the notch shape and the island, from the `BackdropField` it is given: the backdrop blur with its once-per-bar mask, faded by Core Animation alone, and the luminance layer that drives the outline |
| `Overlays/SnapAssist*.swift` | The choosing phase: eligibility, **the phase's one `LayoutArrangement`**, solved again at every pick and every landing that reveals a limit, with the open areas following it; **one surface per display holding every area**, parking, hit testing, hover, restoration, the deck probe |
| `Overlays/DeckAnimator.swift` | The deck's display link; every card posted every frame through the writer, one flush per card as its only evidence |
| `Overlays/DimPanel.swift` | The 30 % click-through dim over each **full** display, menu bar and Dock included |
| `Overlays/WindowPreviewGroup.swift` | One zone-preview panel per window in a handle or junction drag, or per neighbour a drop moves |
| `Overlays/MinimumProbe.swift` | The 1 × 1 write / read-back / restore, on the press (five steps: observe, switch, row, probed, probe) and on the deck |
| `Overlays/HandlePanel.swift` / `HandleBarController.swift` | The pill, the 10 Hz poll, the cursor keepalive, preview-and-release |
| `Overlays/JunctionPanel.swift` / `JunctionHandleController.swift` | The knob, its two axes, and the same preview-and-release |
| `UI/OnboardingWindow.swift` | The welcome window: `OnboardingWindowController`, the four pages, the 2 s poll, and who is in front after a grant flow. An ordinary window, no level and no collection behaviour |
| `UI/GrantRow.swift` | What a grant is (`GrantID`, `GrantItem`), `FocusReturnWatch` (the front back when the app a button opened quits), `GrantRow` (built once, updated in place, with its loading state), and `Metrics`, every number of the window |
| `UI/GrantCatalog.swift` | The rows themselves: the two macOS grants and the two settings, each with how it is **read** and how it is **asked for**, which are never the same call |
| `UI/ControlActionHandler.swift` | A closure target for any `NSControl`, which an AppKit page built in a loop needs |
| `UI/SettingsWindow.swift` | The Settings window: the toolbar that picks a page, one hosting controller, the height that follows the shown page, the `SystemStatus` poll's start and stop, and the Health page's readings taken when that page is shown |
| `UI/SettingsView.swift` | The window's SwiftUI root, the eight pages' identifiers, and `SystemStatus`: the 2 s poll of every state the window shows and does not own (the two grants, the tiling switches, the login item, the drag detection through `AppDelegate.engineState`) |
| `UI/HealthCheck.swift` | The Health page's own readings, taken on show, on picking Health and on Check Again, never on a timer; `AppHealthState`, what `AppDelegate` hands it (the last snap, the registry, the stranded windows, whether the parked record could be read); `facts(_:)`, which joins them with the poll and the one setting a line is judged against into `HealthFacts` |
| `UI/SettingsHealthPage.swift` | The Health page: two groups, the checks with Check Again and their fixes under the card, and the readings, drawn with the kit |
| `UI/SettingsRows.swift` | The kit every page is built from: `SettingsGroup` (title, card, then hint, warnings, notes), `ToggleRow`, `StatusRow` + `StatusMark` (and `StatusMark(level, word)`, the mark for a `HealthLevel`), `ButtonRow`, and `SettingsMetrics`, every spacing number |
| `UI/Settings…Page.swift` | One file per page: General (its Updates group reads `UpdateController.shared`), Snapping, Snap Bar (and the Style tiles), Handles (and the list of window sizes), Custom Areas, System, Health, Tip |
| `UpdateController.swift`, `UpdateNotifier.swift`, `UI/UpdateWindow.swift` | The update feature's one owner, main actor: the schedule's timer (10 s after launch, every 30 min, at wake), the checks, the panel and the session the two windows observe, the fetch, the unpacking off the main actor, Install and Relaunch, and the outcome read at the next launch. `UpdateNotifier` posts the app's one notification: the `update` category with its one action, posted only when the grant is already there (it never asks; the welcome window's Allow button does). `UpdateWindowController` sizes the window to what it says, around its top-left corner |
| `Logging.swift` | Six `os.Logger` categories: `app`, `drag`, `assist`, `deck`, `handle`, `junction`. `Logger.privateAPI` is `app` under another name |
| `Resources/Layouts.json` | The four snap-bar layouts, hand-editable |

## 11. Overlay levels

`OverlayLevel` is an offset from `.statusBar` (25), written once in `OverlayPanel.init` and required
rather than defaulted: **dim 0, zone preview 1, Snap Assist 4, handle bar 8, snap bar 12.** The dim
sits at `.statusBar` itself so it covers the menu bar (24) and the Dock (20). Nothing in AppKit sits
between `.statusBar` and `.popUpMenu` (101). Every overlay panel is `.moveToActiveSpace`, never
`.canJoinAllSpaces`.

**Snap Assist is one panel per display, not one per area.** It covers the display's working area and
places every offered area inside it (`SnapAssist.areaFrame`), because macOS renders true Liquid Glass
only in the key window and there is one of those — a panel per area left all but the last one shown
with a flat fallback (`pitfalls.md` 44, `macOS.md`). The fade and the scale each area plays on the
way in belong to SwiftUI for the same reason: one panel cannot scale onto several cells at once. It
is also why that panel takes mouse events across the whole working area, and why a click outside
every area ends the phase without reaching the window beneath it.

**A level orders a window among the windows of its Space, and no further.** A Space has an *absolute
level* of its own, compared first, and notch utilities put their windows in a Space at 400. The snap
bar's notch shape therefore keeps its `snapBar` level and is *added* to `ElevatedSpace`, a Space of
the app's own at 401 — added, not moved, so it stays `.moveToActiveSpace` on the user's Space as
well. It is the only panel there, it is there only while a drag has it on screen, and it leaves with
every other surface on an interruption (§8). Without private interfaces there is no such Space and
the shape draws under those utilities.

**The notch shape's panel never moves while the shape animates.** It takes the frame
`NotchGeometry.panel` once per show, and everything that moves inside it is either a SwiftUI spring
on `NotchShape`'s four numbers or a Core Animation opacity fade on the blur layer — neither runs
main-thread code per frame, and the blur's mask is built once per bar size. The main thread is where
the zone preview animates, and a per-frame mask rebuild starves it (`pitfalls.md`).

## 12. State: memory and disk

| State | Where | Lifetime |
|---|---|---|
| The user's choices (`Settings`) | `SettingsStore`, `UserDefaults` key `settings.v1` | persisted; tolerant decoding, no migration; a numeric legacy `gap` is read as a switch |
| The list of window sizes | `MinimumSizeStore`, key `minimumSizes.v3` (this Mac's own rows and removals) | persisted; absent while the list is the built-in one; `minimumSizes.v2`, `.v1` and `knownMinimums.v1` are deleted, never read |
| A window's own floor | `MinimumSizeStore`, per `CGWindowID` + pid, with whether the window was probed this session | memory, capped at 512, least recently touched evicted |
| Parked windows | `ParkedWindowsStore`, key `parkedWindows.v1`, written per window before its first move, synchronously | persisted until every window is home; restored at the next launch |
| The welcome window has been finished | `onboardingCompleted` | persisted; written only by the last page's button |
| Launch at login | `SMAppService.mainApp` | the system's |
| Snapped windows and their pre-snap frames | `SnapRegistry` in `SnapState` | memory, never pruned; an entry is valid only within 2 pt of the frame the snap gave it |
| When a snap last landed | `SnapState.lastSnap` | memory; the Health page's reading |
| How often macOS paused the event tap, by reason | `MouseEvents` | memory, this launch |
| Gesture state | each controller's `phase`/`drag`/`parked` | the gesture |

## 13. Threading and run-loop constraints

- Everything AppKit, Accessibility and SwiftUI is on the main actor; the tap callback and notification
  blocks re-enter it with `MainActor.assumeIsolated`.
- Only `WindowHandle` and `WindowWriter` are `@unchecked Sendable`.
- Window writes run on `WindowWriter`'s per-pid queues; outcomes come back with
  `DispatchQueue.main.async`. The main thread never reads a window with posts in flight
  (`WindowWriter.hasPending`, `DragSessionController.restoringWindow`).
- Two main-thread write paths remain by design, both bounded and off the drag path: the probe's
  1 × 1 write at a handle press (three round trips, once per application), and Snap Assist's
  restore pass on an interruption or quit (0.15 s deadline per turn, the rest deferred a window per
  run-loop turn).
- Every animation is a `CADisplayLink` on the display the window is on; every poll is a `Timer` in the
  common run-loop modes.

## 14. Extension points

- **Layouts**: `Sources/SnappySnap/Resources/Layouts.json`, decoded by `LayoutCatalog.decodeSnapBar`
  with the compiled `LayoutCatalog.snapBar` as fallback. Cell order is the Snap Assist order.
- **Constants**: `Settings.Fixed`. Promoting one to a user setting is a stored property on `Settings`
  plus a row on the page it belongs to (`UI/Settings…Page.swift`); `SettingsTests` pins the roster.
- **Private symbols**: a case in `PrivateSymbol`, a call site that asks `pointer(for:)` on every use,
  a public route, and a row in `docs/private-api-index.md`.
- **Seams**: `ScreensProviding` (displays), `WindowWriter.Backend` (the four raw AX calls; the tests
  use a fake), `SettingsStore(defaults:)`, `MinimumSizeStore(defaults:)`, `ParkedWindowsStore`.

## 15. Build, signing, entitlements

SwiftPM only (`Package.swift`, tools 6.2, macOS 26). `Scripts/build-app.sh` assembles
`build/SnappySnap.app` by hand — binary, `Resources/Info.plist`, the resource bundle, the app icon —
then signs it innermost first: each resource bundle, then the app bundle with
`Resources/SnappySnap.entitlements`. The identity comes from `Scripts/signing.env` (tracked, holds no
secret): it looks the Wooflab team's Developer ID Application certificate up in the keychain by team
id, `SIGN_IDENTITY` in the environment overrides it, and `-` signs ad-hoc with a warning. A real
identity also gets the Hardened Runtime and a trusted timestamp, both of which notarization refuses a
build without; ad-hoc gets neither. `Scripts/install.sh` is the installer: it builds the notarized disk
image, waits for any running copy to exit, `ditto`s the bundle out of the image to
`/Applications/SnappySnap.app`, verifies the signature and the version, opens it, and leaves no `.app` and
no `.dmg` under the repository on any exit path. `Scripts/run.sh` is a familiar name for it.
**The app always runs from `/Applications`**,
never from `build/`, which is a staging directory — one fixed installed path is what lets macOS keep
one Accessibility grant and one Finder icon for the app across rebuilds. `Scripts/release.sh` is the
shippable build built on top of this: it signs with the Developer ID identity, verifies the signature,
notarizes and staples the app, wraps it with `Scripts/make-dmg.sh`, then signs, notarizes and staples
the disk image, and checks Gatekeeper accepts both before printing the image's path. The app carries
one entitlement, `com.apple.security.app-sandbox = false`: it is not sandboxed because it reads other
applications' windows through the Accessibility API and the private window-server symbols in
`SystemAdapters/PrivateAPI.swift`, neither of which a sandbox allows. Those private frameworks
(SkyLight, HIServices) are Apple-signed, so the Hardened Runtime's library validation already permits
opening them and needs no exception entry. `Info.plist` holds the bundle id, `LSUIElement`, the
minimum system version, the app icon's name, `CFBundleLocalizations` and nothing else that affects
behaviour.

**The two languages ride in on the resource bundles.** `Package.swift` declares
`defaultLocalization: "en"`, which SwiftPM requires as soon as a target carries localized resources,
and all three targets that show a sentence declare `resources: [.process("Resources")]` — the app
target already did, for `Layouts.json` and `MenuBarMark.pdf`. Each one's `Resources/en.lproj` and
`Resources/fr.lproj` hold a `Localizable.strings`, SwiftPM compiles them into that target's
`SnappySnap_<target>.bundle`, and `build-app.sh` copies every `*.bundle` it finds into
`Contents/Resources` exactly as before: **the script needed no change.** The catalogues are old-style
`.strings` files rather than a `.xcstrings` String Catalog because compiling a catalog is an Xcode
build step and there is no Xcode project here; a `.xcstrings` would be copied in uncompiled and
resolve to nothing, silently. `Info.plist`'s `CFBundleLocalizations` is the separate, main-bundle
half: without it macOS reads the app as English-only and leaves it out of the per-app language list
in System Settings, whatever the resource bundles carry.

**The two brand assets live in `Assets/` and reach the bundle by different routes.** The app icon is
`Assets/snappy-snap.icon`, an Icon Composer document; `build-app.sh` runs `/usr/bin/actool` over it
before signing and copies the resulting `Assets.car` and `snappy-snap.icns` into `Contents/Resources`,
which is what `CFBundleIconFile` and `CFBundleIconName` name. `actool` comes with Xcode, so the step
is guarded: without it the script warns and produces an icon-less bundle rather than failing, and
everything it prints goes to stderr so that stdout stays the one line `run.sh` captures — the bundle
path. The menu-bar mark takes the other route: `Scripts/make-menu-bar-mark.swift` converts
`Assets/1_snake_solid_alt.svg` into `Sources/SnappySnap/Resources/MenuBarMark.pdf` **ahead of time**,
and that PDF is committed and bundled by SwiftPM like any other resource, so no build needs the script.
`NSImage` cannot read SVG, which is why the conversion exists at all; the SVG is straight lines only,
so the script needs nothing beyond CoreGraphics.

## 16. Testing

`swift test` builds and runs two targets, `SnapCoreTests` (638 tests) and `SystemAdaptersTests`
(122), on Swift Testing. Count **two** summary lines: a crashed target prints none. They need no
permission; a handful read the live desktop or the real `defaults` and tolerate what they find.
`WindowWriterTests` drive the writer through a fake `Backend`.

`SnapCoreTests`' `LocalizationTests` is the exception to the layering: it reads all six
`Localizable.strings` **from the source tree**, through `#filePath`, and so covers the app target's
184 sentences as well as its own. It also reads every `L("…")` in each target's sources and holds the
call sites and the catalogue to each other: a sentence shown and not catalogued, or catalogued and no
longer shown, fails. That is deliberate. The app target has no test target, the
catalogues are the authority rather than any compiled artefact, and the failure being guarded
against — a sentence translated in one language and not the other — is invisible at runtime, because
`String(localized:)` falls back to the English key and says nothing. Each target additionally owns a
test that **its own built bundle** carries both languages, which is what catches a `resources:` line
lost from `Package.swift`.

A test may not assert that a piece of copy reads a particular English string: `title` and its kind
are localized now, so they read French on a Mac set to French. Those assertions moved into
`LocalizationTests`, against the English catalogue, where they are deterministic on any Mac.

`Sources/SnappySnap` has **no test target**: it is AppKit, panels and display links. Anything in it
that could be pure was pushed down into `SnapCore`, which is why the planner, the card layout, the
deck's fan, the minimum-size policy, the orphan rule and the junction arithmetic live there and are
tested. The Health page is the same: its lines, their colours and their words are built in
`SnapCore.HealthReport` from plain facts and tested in `HealthTests`, the worst case held to
`HealthLimits`; the app only reads the facts and draws the lines. `SpaceWatcher` has no tests. What no automated test reaches is in
`docs/manual-test-checklist.md`.
