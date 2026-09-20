# Audit — SnappySnap, the pass that produced 1.0.0

Working record of the end-to-end audit. Every claim here was checked against the code by a named
slice auditor and re-read by the parent where marked. `docs/_coverage.md` is the file manifest.

## 1. What the product is

A menu-bar accessory app (`LSUIElement`) that gives macOS Windows 11-style snapping. Dragging a
window's title bar to an edge, corner or the top of the display shows a preview and, on release,
animates the window into that zone. Dragging to the top also opens a **snap bar** of four layouts
plus a conditional pair cell. A drop from the bar opens **Snap Assist**: the other cells offer the
display's remaining windows as cards, and the windows themselves are dealt into a corner deck until
the phase ends. Two snapped windows whose edges nearly touch get a **handle pill** on hover; a
crossing of two dividers gets a **junction knob**; both drag previews only and move the windows on
release. An **oversize watcher** keeps windows inside the gap. Everything stands down on a Space
change, Mission Control or a display change. Accessibility is the only permission.

## 2. Module and file map

### `Sources/SnapCore` (pure logic, CG space, CoreGraphics + Foundation only)

| File | Purpose |
|---|---|
| `Model.swift` | `DisplayInfo`, `WindowInfo`, `Edge`, `sharedEdges(among:)` |
| `Geometry.swift` | Zone frames with gap insetting (never rounds), `anchoredOrigin`, `ZonePreview.strokeWidth` |
| `Layouts.swift` | `UnitRect`, `Layout`, `LayoutCatalog` (four bar layouts + fill), JSON decoding |
| `Settings.swift` | The 12 stored user choices, `Settings.Fixed` constants, tolerant decoding, legacy `gap` |
| `ZoneResolver.swift` | Cursor → zone with priority bar › corner › side › top; hysteresis |
| `SnapBarGeometry.swift` | Bar frame, cells, pair cell, hit test, arm/hold rules |
| `PairCell.swift` | The conditional first cell: dragged left, partner right |
| `SnapPlanner.swift` | What a drop places: fill, minimum redistribution, anchoring, occupants |
| `SnapRegistry.swift` | windowID → pre-snap frame, valid within 2 pt (drag-away restore) |
| `OrphanDetector.swift` | Lost mouse-up rule: two polls up + 0.1 s quiet |
| `PostRate.swift` | Posts/second per `Smoothness` (display rate / 60 / 30) |
| `Animation.swift` | `AnimationCurve.easeInOut`, `UnitBezier` |
| `SnapAssist.swift` | Sibling cells, card layout, reflow curve, click-safety during reflow |
| `Deck.swift` | Corner, fan slots, stagger, arrival tolerance, record-forget rule |
| `Adjacency.swift` | `HandlePair`, `AdjacencyDetector.pairs/occluder` |
| `HandleBarGeometry.swift` | Pill size, hover band (10 pt), drag band (96 pt), divider |
| `HandleDragMath.swift` | Two-window frames from a divider, `roundingAllowance = 12`, `refit` |
| `MinimumSizePolicy.swift` | `MinimumSizeRecord`, disproof / needsProbe / believable floor rules |
| `Junction.swift` | `Junction`, `JunctionDetector.evaluate/junctions/revalidate`, four `Reason`s |
| `JunctionDragMath.swift` | Three/four-window frames per axis, `refit` after refusals |
| `JunctionGeometry.swift` | Knob 12 pt, band 24 pt, drag band 96 pt, `knobCentre` |
| `SpaceInterruption.swift` | `MissionControlDetector` (≥ 90 % cover), `MissionControlGate` (0.15 s grace), `SpaceSlideDetector` |

### `Sources/SystemAdapters` (the only AppKit / Accessibility code)

| File | Purpose |
|---|---|
| `AX.swift` | Typed wrappers over `AXUIElementCopy/SetAttributeValue` |
| `AccessibilityWindows.swift` | `WindowHandle`, hit-test, identify (private or frame-match route), reads, raise, 0.25 s timeout |
| `WindowWriter.swift` | Every window write: one serial queue per pid, one single-slot mailbox per window, flush/read-back |
| `WindowList.swift` | CGWindowList: `snapshot` (layer 0, regular, ≥ 50 pt), `onScreenSurfaces`, `onScreenIDsAndFrames`; never names |
| `MinimumSizeStore.swift` | `minimumSizes.v2` per bundle id + version; per-window in memory (512 cap); disproof |
| `Permissions.swift` | `AXIsProcessTrusted`, prompt, two System Settings deep links |
| `CoordinateSpace.swift` | Cocoa ↔ CG flip against the primary height |
| `Screens.swift` | `DisplayInfo` list in CG space, `onChange`, nearest display |
| `MouseEvents.swift` | Listen-only session `CGEventTap`, re-enable on disable with reason + count |
| `SpaceWatcher.swift` | 10/60 Hz poll, Mission Control detection, 1×1 sentinels at 5 % alpha, 1.5 s coalescing |
| `PrivateAPI.swift` | Three `dlsym` symbols, per-call `pointer(for:)`, `isEnabled` mirror of the switch |
| `BackgroundCursor.swift` | `SetsCursorInBackground` via SkyLight; system `move` glyph from HIServices resources |
| `SystemTilingPrefs.swift` | Three `com.apple.WindowManager` keys |
| `LoginItem.swift` | `SMAppService.mainApp` |
| `SettingsStore.swift` | `settings.v1` JSON blob, `@Published` |
| `ParkedWindowsStore.swift` | `parkedWindows.v1` crash-recovery record, synchronous write |

### `Sources/SnappySnap` (the app)

| File | Purpose |
|---|---|
| `SnappySnapApp.swift` | `@main`, `MenuBarExtra` with Settings… and Quit |
| `AppDelegate.swift` | Wires everything; `route(_:)` fan-out; permission poll; tiling warning; teardown |
| `Logging.swift` | Six `Logger` categories |
| `SnapState.swift` | Holds the `SnapRegistry` |
| `Drag/DragSessionController.swift` | Press → armed → dragging → release; evidence capture; drop placement |
| `Engines/EngineRouter.swift` | Zone → frame, registry record, refusal learning; the one engine's front door |
| `Engines/SteppingSnapEngine.swift` | `CADisplayLink` animation posting through `WindowWriter`; anchoring |
| `OversizeWatcher.swift` | 10 Hz: disprove minimums; correct windows that outgrow the gap |
| `Overlays/OverlayPanel.swift` | Base non-activating panel; `OverlayLevel`; generation-counted fades |
| `Overlays/DimPanel.swift` | 30 % dim per display |
| `Overlays/ZonePreviewController.swift` | One preview per display + the pair's second half |
| `Overlays/ZonePreviewPanel.swift` | The preview drawing and animations |
| `Overlays/SnapBarController.swift` | Bar session, pair partner, hit test |
| `Overlays/SnapBarPanel.swift` / `SnapBarView.swift` | The bar panel and its SwiftUI |
| `Overlays/WindowPreviewGroup.swift` | N previews for a handle/knob drag |
| `Overlays/MinimumProbe.swift` | 1×1 write, read back, restore; press and background paths |
| `Overlays/SnapAssistController.swift` | `EligibleWindows`; the whole Snap Assist phase and parking promise |
| `Overlays/SnapAssistPanel.swift` / `SnapAssistView.swift` | The choosing surfaces |
| `Overlays/DeckAnimator.swift` | The deck's motor |
| `Overlays/HandleBarController.swift` / `HandlePanel.swift` | The pill feature and its panel + background cursor keepalive |
| `Overlays/JunctionHandleController.swift` / `JunctionPanel.swift` | The knob feature and its panel |
| `UI/SettingsView.swift` | Settings window (owned `NSWindow`), 13 controls, status reports |
| `UI/OnboardingWindow.swift` | Accessibility onboarding |
| `Resources/Layouts.json` | The four bar layouts (compiled catalog is the fallback) |

### Others

`Tools/axprobe/main.swift` — 16 dev subcommands, not shipped. `Tests/` — Swift Testing, two targets.

## 3. Live / dead / unclear

Everything not listed below is LIVE with a production caller. Parent re-read every item below.

### DEAD (provably unreachable or unreferenced) — to delete

| Item | Evidence |
|---|---|
| The whole **reveal** release mode | `Settings.swift:108` `Fixed.handleRelease = .slide`; `:170` get-only; no setter anywhere in `Sources`. Consumers: `RevealPlacer.swift` (whole file), `HandleBarController.swift:157,170,246,287-289,715-724,747-764,902-914,949-955,959-960`, `JunctionHandleController.swift:137,155,178,344-346,578-587,606-618,755-767,800-806,810`, `WindowPreviewGroup.move` (:41-45), `ZonePreviewPanel.move` (:106-113), `HandleRelease` enum (`Settings.swift:55-77`), the `writer:` parameter both controllers take only to build a `RevealPlacer` |
| `AccessibilityWindows.setFrame(_:of:current:)` | `AccessibilityWindows.swift:142-154`; zero callers; a second copy of `WindowWriter.plan`'s ordering rule (same rule, plus a third size write and a read) |
| `AdjacencyDetector.pairs(... bandThickness:)` parameter | `Adjacency.swift:60-63` says it does nothing; body never reads it |
| `MissionControlGate.observe(_:)` | `SpaceInterruption.swift:162-168`; only tests call it; `update(showing:now:)` is the production form |
| `SnapRegistry.prune(keeping:)`, `SnapRegistry.count` | `SnapRegistry.swift:46-50`; tests only |
| `UnitRect.overlaps` | `Layouts.swift:18-22`; tests only |
| `MouseEvents.isRunning` | `MouseEvents.swift:37`; no reader |
| `BackgroundCursor.isEnabled` | `BackgroundCursor.swift:32`; written, never read |
| `WindowWriter.Order` (two cases, one rule) | `WindowWriter.swift:67-75`, `plan` at `:548-565` handles both in one branch; `.divider` never spelled at a call site |
| `SnapAssistController.EndReason.external` | `SnapAssistController.swift:177`; only the default argument of `dismiss`; every caller names a reason |
| `axprobe` target's `SnapCore` dependency | `Package.swift:18`; `main.swift` never imports it |

### DUPLICATED — to fold

| Item | Evidence |
|---|---|
| `refusalTolerance = 1` | `HandleBarController.swift:89` and `JunctionHandleController.swift:74`, same doc |
| `MinimumSizeStore.learn` body | `:141-147` and `:242-250` |
| `WindowList` CGWindowList preamble | `:8-10`, `:48-50`, `:69-71` |
| `JunctionDetector.evaluate` run twice per 10 Hz poll | `JunctionHandleController.swift:228-229` calls `evaluate` then `junctions`, which calls `evaluate` again (`Junction.swift:275`) |
| "tee" vs "T" for one `Junction.Kind` in one log category | `JunctionHandleController.swift:241` vs `:891` |

### UNCLEAR — resolved by the parent

| Item | Resolution |
|---|---|
| `AccessibilityWindows.windowID(of:)` (tests only) | Keep: it is the testable face of the private/public identify route (`PrivateAPITests`, `AccessibilityWindowsTests`) |
| `WindowWriter.Outcome.asked` (tests only) | Keep: outcome data the tests assert live behaviour through |
| `Screens.reload()` public | Leave |
| `AppDelegate.engineStarted` `private(set)` | Make `private` |
| Three self-documented unreachable guards in `SnapAssistController` (`:517`, `:846`, `:1160`) | Keep: cheap regression catches, documented as such |
| `Layouts.json` duplicates `LayoutCatalog.snapBar` | Keep: the file is the resource the app loads; the catalog is its fallback on a missing or invalid file |
| The pill/knob settle-and-refit pipeline exists twice | Leave: merging is a rewrite of two working subsystems, out of scope |

### Comments that are wrong today (not merely narrative) — to fix

| Location | Says | Truth |
|---|---|---|
| `AppDelegate.swift:217-219` | every surface is `.canJoinAllSpaces` | `OverlayPanel.swift:64` is `.moveToActiveSpace` |
| `SpaceInterruption.swift:9,46` | same | same |
| `HandleBarController.swift:41,133` | `fallbackMinimum` | `MinimumProbe.fallback` |
| `HandleBarGeometry.swift:31` | "min(100, overlap − 16)" | 48 in the code |
| `HandlePanel.swift:218-219`, `JunctionPanel.swift:63-64` | "the resize is live" | nothing resizes live |
| `OverlayPanel` level comment | levels "spaced by 4" | preview is +1 |
| `SnapAssistController.swift:599` | `unparkAll` | no such symbol |
| `SnapAssist.swift:24` | the view centres `contentSize` | it fills and uses `blockOrigin` |
| `SteppingSnapEngine.swift:28-32,145` | `lastApplied` | no such symbol |
| `WindowWriter.swift:369-377` | `hasPending` covers "a flush on its way" | code: `pending != nil || stepScheduled` |
| `WindowWriter.swift:44` | "the one `@unchecked Sendable`" | `WindowHandle` is the other |
| `Tools/axprobe/main.swift:1-20` | 13 commands | 16 |

### Narration to strip (keep the invariant, drop the history)

Counted before cleanup: `§N` spec references 327, `Round N` 142, `Task N` 30, dated remarks 45,
"used to" 37, "no longer" 29. The slice reports list every line. Rule applied: a sentence that
states a rule, a measurement or a failure mode stays, reworded in the present tense; the round,
task, date, attribution and section number go; a sentence whose only content is history goes.

## 4. Behaviour extracted from code (the numbers)

The full list is in `docs/functional.md` after the rewrite. Defaults and constants the docs must
state, all from `Settings.swift`, `SnapCore` and the controllers:

- Stored settings (defaults): sideHalves, corners, topFill, snapBar, snapAssist = on;
  sharedDisplayEdges off; gapEnabled on; correctOversizedWindows on; restoreOnDragAway off;
  smoothness balanced (60 Hz); handleBar on; usePrivateAPIs on. Key `settings.v1`.
- Fixed: cornerBand 120, edgeBand 24, animationDuration 0.25 s, handleMaxGap 16, handleMinOverlap
  60, deckCeiling 20, snapFill on, gap 8 (0 when off).
- Resolver: hysteresis 12, shared-edge threshold 4 + dwell 0.15 s. Bar: cells 96×64, spacing 8,
  padding 12, inner gap 3, hide margin 16, pair icon 24, top inset gap+3+gap.
- Planner: span tolerance 2, minimum span fraction 0.5, edge tolerance 1, evidence slack gap+4.
- Registry tolerance 2. Orphan: 2 ticks + 0.1 s. Post rate fallback 60.
- Snap Assist: cards 80–180 pt, spacing 12, padding 24, reflow 0.22 s, look-back 0.05 s, present
  0.2 s, dismiss 0.15 s, scale inset 4 %, key re-assert 0.12 s, restore deadline 0.15 s, probe
  budget 4, partner scan limit 8. Deck: sliver 40×91, margin 24, spacing 8–14, radius 200, angles
  10–72°, stagger ≤ 0.03 s capped 0.15 s, arrival tolerance 1.
- Handles: poll 0.1 s, cursor idle 2 s, hide grace 0.1 s, band 10, pill 4 × min(overlap, min(48,
  max(24, overlap−16))), drag band 96, dim 30 %, fades 0.12 s, refusal tolerance 1, rounding
  allowance 12, probe fallback 200×150, background settle 0.12 s, background deadline 0.6 s.
- Junction: knob 12, band 24, drag band 96, edge tolerance 24, centre tolerance 48.
- Cursor: keepalive 1/60 s. Spaces: idle 0.1 s, live 1/60 s, coalescing 1.5 s, sentinel alpha
  0.05, Mission Control cover 0.9, re-offer grace 0.15 s, interruption fade 0.12 s.
- Oversize: poll 0.1 s, settle 0.5 s, tolerance 1.
- AX: messaging timeout 0.25 s, frame-match tolerance 1. Writer: QoS userInteractive, stale 60 s,
  sweep 5 s, flush deadline 2 s. Window list: ≥ 50 pt a side, layer 0, alpha > 0, regular apps.
- Minimums: `minimumSizes.v2`, v1 deleted on construction, window cap 512, disproof tolerance 1,
  settle tolerance 1, implausible share 0.8. Parked: `parkedWindows.v1`. Tiling warning key
  `didWarnSystemTiling`.

## 5. Spec-vs-code disparities

- `CLAUDE.md`: "Only `WindowHandle` is `@unchecked Sendable`" — `WindowWriter` is too.
- `CLAUDE.md`: the test suite fails in two files — it fails in six (`SettingsTests`,
  `SnapBarGeometryTests`, `ZoneResolverTests`, `DeckTests`, `JunctionTests`, `SettingsStoreTests`).
- `CLAUDE.md` SnapCore inventory omits `Model.swift` and `HandleBarGeometry.swift`.
- `functional.md` §9 pill formula omits the 24 pt floor and the `min(overlap, …)` cap.
- `private-api-index.md` names two tests as the live guarantee without saying they cannot run.
- `pitfall.md` 14 rests on deleted spike files; 29 names `scratchpad/grab.swift`, not in the repo.
- Everything else in the seven docs was VERIFIED against code by the docs auditor.

Behaviours in code that no doc describes: the bar's own appear animation (0.18/0.12 s, slide 20),
deck stagger and fan numbers, Snap Assist key re-assertion, writer flush deadline and stale sweep,
the probe-restore net, legacy `gap` decoding, `minimumSizes.v1` deletion, the Settings window's
2 s status poll, the drag path's 1/120 s read throttle, the 96 pt drag bands, `innerGap`, sentinel
alpha, the no-retry when the event tap cannot be created after the grant, and the press/drag
claiming asymmetry during a pill's settling window.

## 6. Candidate behaviour findings (not changed — recorded as limitations)

- **Pill settling window:** a press outside the band while `drag != nil && released` passes to the
  drag session, but the `.dragged`/`.up` that follow are swallowed by the pill
  (`HandleBarController.swift:353-356, 380-382`). A window drag begun in that ~250 ms gets its
  press and nothing else.
- **Event tap failure after the grant:** `startEngine` logs once and returns; nothing retries.
- **Oversize refusal teaches nothing:** `OversizeWatcher` calls `forgetDisproved` but never
  `learn` on a refused correction, unlike every other placement path.
- **`MinimumProbe.probe` second read has no delay** on the press path (immediate re-read).
- **`Settings.smoothness` reaches only the Snap Assist deck:** `PostRate` has one consumer, `DeckAnimator`; `SteppingSnapEngine` posts one frame per display-link tick. The doc comments in both handle controllers that list `PostRate` among their machinery are stale.
- **`SnapRegistry` is never pruned:** entries stay for the life of the process, guarded only by the 2 pt validity test at read time.

## 7. Tests

Six files fail to compile, one root cause: nine `Settings` members became fixed constants and the
range/clamp API was removed. Disposition:

| File | Verdict | Fix |
|---|---|---|
| `DeckTests` | stale API | literal 40 for the removed range bound |
| `JunctionTests:361` | stale API | compare against `Settings.Fixed.handleMaxGap` |
| `SettingsTests` | mostly obsolete | rewrite around the current struct |
| `SnapBarGeometryTests` | fixture obsolete | use the two reachable gap states (8 / 0) |
| `ZoneResolverTests` | fixture obsolete | use the fixed 24 pt band; drop `cornerBandSettingIsHonored` |
| `SettingsStoreTests` | obsolete | rewrite around `gapEnabled`; drop clamp/migration tests |
| `SpaceInterruptionTests`, `SnapRegistryTests`, `LayoutsTests` | follow deletions | use `update(showing:now:)`; drop `count`/`prune`/`overlaps` assertions |
| `WindowWriterTests` | follows `Order` removal | drop the `order:` labels |

All other 20 files are LIVE and unchanged.

## 8. Questions for the owner

None blocking. Decisions taken under the mission's rules, to be confirmed in the final report:

1. The reveal release mode is deleted as provably unreachable (CLAUDE.md recorded it as "kept
   behind that one line"; the mission's cleanup rule outranks that note).
2. `WindowWriter.Order` is removed as a one-rule enum.
3. Log text harmonised to "T" for a three-window junction (the checklist is updated to match).
