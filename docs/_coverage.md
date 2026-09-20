# Coverage manifest — SnappySnap audit

Working file for the audit. Deleted at the end of the mission with `docs/_audit.md`.

## Inventory (Phase 0)

Source of truth for membership: `Package.swift` (SwiftPM, no `.xcodeproj`). Six targets:
`SnapCore`, `SystemAdapters`, `SnappySnap` (executable, resources `Sources/SnappySnap/Resources`),
`axprobe` (executable, `Tools/axprobe`), `SnapCoreTests`, `SystemAdaptersTests`.

SwiftPM includes every `.swift` under a target directory, so **project membership = disk**. There
is no orphan in either direction. Confirmed by `git ls-files` against the target paths above.

Files on disk, in scope at the start: 110 (tracked + untracked, `git ls-files --cached --others
--exclude-standard`), 21,421 lines. After the cleanup: `Sources/SnappySnap/Overlays/RevealPlacer.swift`
and `docs/pitfall.md` are deleted; `docs/macOS.md`, `docs/pitfalls.md` and `docs/README.md` are added.

Ignored, out of scope: `.build/`, `build/`, `.claude/settings.local.json` (sandbox flag only),
`.signing.env` (secret), `.superpowers/` (the user's; never touched).

Deleted in the working tree at session start (staged `D`, not on disk): `docs/spike/*.txt` (18
axprobe transcripts), `docs/spike-native-tiling.md`, `docs/decisions-awaiting-review.md`,
`docs/superpowers/**` (2 specs, 2 plans, 1 handoff). Read from `HEAD` for pitfall evidence only
(slice `docs`).

## Slice plan (Phase 1)

| Slice | Files | Lines |
|---|---|---|
| core-geometry | SnapCore: Model, Geometry, Layouts, Settings, ZoneResolver, SnapBarGeometry, PairCell, SnapPlanner, SnapRegistry, OrphanDetector, PostRate, Animation; Resources/Layouts.json | ~1530 |
| core-assist-handles | SnapCore: SnapAssist, Deck, Adjacency, HandleBarGeometry, HandleDragMath, MinimumSizePolicy, Junction, JunctionDragMath, JunctionGeometry, SpaceInterruption | ~2070 |
| adapters-ax-write | SystemAdapters: AX, AccessibilityWindows, WindowWriter, WindowList, MinimumSizeStore, Permissions, CoordinateSpace, Screens | ~1450 |
| adapters-input-spaces-prefs | SystemAdapters: MouseEvents, SpaceWatcher, PrivateAPI, BackgroundCursor, SystemTilingPrefs, LoginItem, SettingsStore, ParkedWindowsStore | ~930 |
| app-drag-engine | SnappySnap: AppDelegate, SnappySnapApp, Logging, SnapState, Drag/DragSessionController, Engines/EngineRouter, Engines/SteppingSnapEngine, OversizeWatcher | ~1630 |
| overlays-preview-bar | Overlays: OverlayPanel, DimPanel, ZonePreviewController, ZonePreviewPanel, SnapBarController, SnapBarPanel, SnapBarView, WindowPreviewGroup, MinimumProbe, RevealPlacer | ~1210 |
| overlays-snap-assist | Overlays: SnapAssistController, SnapAssistPanel, SnapAssistView, DeckAnimator | ~1950 |
| overlays-handles | Overlays: HandleBarController, HandlePanel | ~1280 |
| overlays-junction | Overlays: JunctionHandleController, JunctionPanel | ~990 |
| ui-build | UI/SettingsView, UI/OnboardingWindow, Package.swift, Resources/Info.plist, Scripts/build-app.sh, Scripts/run.sh, .vscode/launch.json, .gitignore | ~620 |
| tests-core-1 | SnapCoreTests: Adjacency, Animation, Deck, Geometry, HandleBarGeometry, HandleDragMath, Layouts, MinimumSizePolicy, Model, OrphanDetector, PairCell, PostRate | ~1350 |
| tests-core-2 | SnapCoreTests: Junction, Settings, SnapAssist, SnapBarGeometry, SnapRegistry, SpaceInterruption, ZoneResolver | ~2200 |
| tests-adapters | SystemAdaptersTests: all nine files | ~1620 |
| axprobe | Tools/axprobe/main.swift | 583 |
| docs | README.md, CLAUDE.md, docs/architecture.md, docs/functional.md, docs/pitfall.md, docs/manual-test-checklist.md, docs/private-api-index.md; HEAD copies of deleted docs | ~2010 |

Parent reads personally: Package.swift, .gitignore, Resources/Info.plist, Scripts/*, .vscode/launch.json,
SnappySnapApp.swift, Logging.swift, SnapState.swift, Layouts.json (done), AppDelegate.swift, and every
file a slice marks UNCLEAR or LIVE-CRITICAL.

## File table

109 in-scope files, 109 read, 0 unread. Every file was read start to end by the named
slice auditor; the parent additionally read the files marked (full) in full and the files marked
(regions) in the regions it edited or resolved as UNCLEAR.

| path | slice | reader | status | lines |
|---|---|---|---|---|
| `.gitignore` | ui-build | subagent ui-build + parent (full) | READ | 10 |
| `.vscode/launch.json` | ui-build | subagent ui-build + parent (full) | READ | 44 |
| `CLAUDE.md` | docs | subagent docs + parent (full) | READ | 160 |
| `Package.swift` | ui-build | subagent ui-build + parent (full) | READ | 23 |
| `README.md` | docs | subagent docs + parent (full) | READ | 182 |
| `Resources/Info.plist` | ui-build | subagent ui-build + parent (full) | READ | 19 |
| `Scripts/build-app.sh` | ui-build | subagent ui-build + parent (full) | READ | 28 |
| `Scripts/run.sh` | ui-build | subagent ui-build + parent (full) | READ | 8 |
| `Sources/SnapCore/Adjacency.swift` | core-assist-handles | subagent core-assist-handles + parent (full) | READ | 123 |
| `Sources/SnapCore/Animation.swift` | core-geometry | subagent core-geometry | READ | 81 |
| `Sources/SnapCore/Deck.swift` | core-assist-handles | subagent core-assist-handles | READ | 239 |
| `Sources/SnapCore/Geometry.swift` | core-geometry | subagent core-geometry | READ | 88 |
| `Sources/SnapCore/HandleBarGeometry.swift` | core-assist-handles | subagent core-assist-handles | READ | 109 |
| `Sources/SnapCore/HandleDragMath.swift` | core-assist-handles | subagent core-assist-handles | READ | 147 |
| `Sources/SnapCore/Junction.swift` | core-assist-handles | subagent core-assist-handles + parent (regions) | READ | 476 |
| `Sources/SnapCore/JunctionDragMath.swift` | core-assist-handles | subagent core-assist-handles | READ | 218 |
| `Sources/SnapCore/JunctionGeometry.swift` | core-assist-handles | subagent core-assist-handles | READ | 103 |
| `Sources/SnapCore/Layouts.swift` | core-geometry | subagent core-geometry + parent (full) | READ | 81 |
| `Sources/SnapCore/MinimumSizePolicy.swift` | core-assist-handles | subagent core-assist-handles | READ | 184 |
| `Sources/SnapCore/Model.swift` | core-geometry | subagent core-geometry | READ | 72 |
| `Sources/SnapCore/OrphanDetector.swift` | core-geometry | subagent core-geometry | READ | 55 |
| `Sources/SnapCore/PairCell.swift` | core-geometry | subagent core-geometry | READ | 61 |
| `Sources/SnapCore/PostRate.swift` | core-geometry | subagent core-geometry | READ | 43 |
| `Sources/SnapCore/Settings.swift` | core-geometry | subagent core-geometry + parent (full) | READ | 214 |
| `Sources/SnapCore/SnapAssist.swift` | core-assist-handles | subagent core-assist-handles | READ | 271 |
| `Sources/SnapCore/SnapBarGeometry.swift` | core-geometry | subagent core-geometry + parent (regions) | READ | 164 |
| `Sources/SnapCore/SnapPlanner.swift` | core-geometry | subagent core-geometry | READ | 422 |
| `Sources/SnapCore/SnapRegistry.swift` | core-geometry | subagent core-geometry + parent (full) | READ | 51 |
| `Sources/SnapCore/SpaceInterruption.swift` | core-assist-handles | subagent core-assist-handles + parent (regions) | READ | 198 |
| `Sources/SnapCore/ZoneResolver.swift` | core-geometry | subagent core-geometry + parent (regions) | READ | 193 |
| `Sources/SnappySnap/AppDelegate.swift` | app-drag-engine | subagent app-drag-engine + parent (full) | READ | 378 |
| `Sources/SnappySnap/Drag/DragSessionController.swift` | app-drag-engine | subagent app-drag-engine | READ | 571 |
| `Sources/SnappySnap/Engines/EngineRouter.swift` | app-drag-engine | subagent app-drag-engine | READ | 81 |
| `Sources/SnappySnap/Engines/SteppingSnapEngine.swift` | app-drag-engine | subagent app-drag-engine | READ | 224 |
| `Sources/SnappySnap/Logging.swift` | app-drag-engine | subagent app-drag-engine + parent (full) | READ | 16 |
| `Sources/SnappySnap/Overlays/DeckAnimator.swift` | overlays-snap-assist | subagent overlays-snap-assist | READ | 396 |
| `Sources/SnappySnap/Overlays/DimPanel.swift` | overlays-preview-bar | subagent overlays-preview-bar | READ | 83 |
| `Sources/SnappySnap/Overlays/HandleBarController.swift` | overlays-handles | subagent overlays-handles + parent (regions) | READ | 1003 |
| `Sources/SnappySnap/Overlays/HandlePanel.swift` | overlays-handles | subagent overlays-handles | READ | 273 |
| `Sources/SnappySnap/Overlays/JunctionHandleController.swift` | overlays-junction | subagent overlays-junction + parent (regions) | READ | 892 |
| `Sources/SnappySnap/Overlays/JunctionPanel.swift` | overlays-junction | subagent overlays-junction | READ | 101 |
| `Sources/SnappySnap/Overlays/MinimumProbe.swift` | overlays-preview-bar | subagent overlays-preview-bar | READ | 278 |
| `Sources/SnappySnap/Overlays/OverlayPanel.swift` | overlays-preview-bar | subagent overlays-preview-bar | READ | 141 |
| `Sources/SnappySnap/Overlays/RevealPlacer.swift` | overlays-preview-bar | subagent overlays-preview-bar + parent (full) | READ, then DELETED (unreachable) | 153 |
| `Sources/SnappySnap/Overlays/SnapAssistController.swift` | overlays-snap-assist | subagent overlays-snap-assist + parent (regions) | READ | 1206 |
| `Sources/SnappySnap/Overlays/SnapAssistPanel.swift` | overlays-snap-assist | subagent overlays-snap-assist | READ | 124 |
| `Sources/SnappySnap/Overlays/SnapAssistView.swift` | overlays-snap-assist | subagent overlays-snap-assist | READ | 220 |
| `Sources/SnappySnap/Overlays/SnapBarController.swift` | overlays-preview-bar | subagent overlays-preview-bar | READ | 141 |
| `Sources/SnappySnap/Overlays/SnapBarPanel.swift` | overlays-preview-bar | subagent overlays-preview-bar | READ | 61 |
| `Sources/SnappySnap/Overlays/SnapBarView.swift` | overlays-preview-bar | subagent overlays-preview-bar | READ | 77 |
| `Sources/SnappySnap/Overlays/WindowPreviewGroup.swift` | overlays-preview-bar | subagent overlays-preview-bar + parent (full) | READ | 59 |
| `Sources/SnappySnap/Overlays/ZonePreviewController.swift` | overlays-preview-bar | subagent overlays-preview-bar | READ | 88 |
| `Sources/SnappySnap/Overlays/ZonePreviewPanel.swift` | overlays-preview-bar | subagent overlays-preview-bar + parent (full) | READ | 130 |
| `Sources/SnappySnap/OversizeWatcher.swift` | app-drag-engine | subagent app-drag-engine | READ | 320 |
| `Sources/SnappySnap/Resources/Layouts.json` | core-geometry | subagent core-geometry + parent (full) | READ | 6 |
| `Sources/SnappySnap/SnapState.swift` | app-drag-engine | subagent app-drag-engine + parent (full) | READ | 12 |
| `Sources/SnappySnap/SnappySnapApp.swift` | app-drag-engine | subagent app-drag-engine + parent (full) | READ | 28 |
| `Sources/SnappySnap/UI/OnboardingWindow.swift` | ui-build | subagent ui-build | READ | 53 |
| `Sources/SnappySnap/UI/SettingsView.swift` | ui-build | subagent ui-build | READ | 448 |
| `Sources/SystemAdapters/AX.swift` | adapters-ax-write | subagent adapters-ax-write | READ | 58 |
| `Sources/SystemAdapters/AccessibilityWindows.swift` | adapters-ax-write | subagent adapters-ax-write + parent (regions) | READ | 286 |
| `Sources/SystemAdapters/BackgroundCursor.swift` | adapters-input-spaces-prefs | subagent adapters-input-spaces-prefs + parent (regions) | READ | 153 |
| `Sources/SystemAdapters/CoordinateSpace.swift` | adapters-ax-write | subagent adapters-ax-write | READ | 28 |
| `Sources/SystemAdapters/LoginItem.swift` | adapters-input-spaces-prefs | subagent adapters-input-spaces-prefs | READ | 9 |
| `Sources/SystemAdapters/MinimumSizeStore.swift` | adapters-ax-write | subagent adapters-ax-write + parent (regions) | READ | 301 |
| `Sources/SystemAdapters/MouseEvents.swift` | adapters-input-spaces-prefs | subagent adapters-input-spaces-prefs + parent (full) | READ | 97 |
| `Sources/SystemAdapters/ParkedWindowsStore.swift` | adapters-input-spaces-prefs | subagent adapters-input-spaces-prefs | READ | 71 |
| `Sources/SystemAdapters/Permissions.swift` | adapters-ax-write | subagent adapters-ax-write | READ | 24 |
| `Sources/SystemAdapters/PrivateAPI.swift` | adapters-input-spaces-prefs | subagent adapters-input-spaces-prefs | READ | 168 |
| `Sources/SystemAdapters/Screens.swift` | adapters-ax-write | subagent adapters-ax-write | READ | 66 |
| `Sources/SystemAdapters/SettingsStore.swift` | adapters-input-spaces-prefs | subagent adapters-input-spaces-prefs | READ | 43 |
| `Sources/SystemAdapters/SpaceWatcher.swift` | adapters-input-spaces-prefs | subagent adapters-input-spaces-prefs | READ | 350 |
| `Sources/SystemAdapters/SystemTilingPrefs.swift` | adapters-input-spaces-prefs | subagent adapters-input-spaces-prefs | READ | 35 |
| `Sources/SystemAdapters/WindowList.swift` | adapters-ax-write | subagent adapters-ax-write + parent (full) | READ | 79 |
| `Sources/SystemAdapters/WindowWriter.swift` | adapters-ax-write | subagent adapters-ax-write + parent (regions) | READ | 604 |
| `Tests/SnapCoreTests/AdjacencyTests.swift` | tests-core-1 | subagent tests-core-1 | READ | 141 |
| `Tests/SnapCoreTests/AnimationTests.swift` | tests-core-1 | subagent tests-core-1 | READ | 94 |
| `Tests/SnapCoreTests/DeckTests.swift` | tests-core-1 | subagent tests-core-1 + parent (regions) | READ | 251 |
| `Tests/SnapCoreTests/GeometryTests.swift` | tests-core-1 | subagent tests-core-1 | READ | 148 |
| `Tests/SnapCoreTests/HandleBarGeometryTests.swift` | tests-core-1 | subagent tests-core-1 | READ | 175 |
| `Tests/SnapCoreTests/HandleDragMathTests.swift` | tests-core-1 | subagent tests-core-1 | READ | 199 |
| `Tests/SnapCoreTests/JunctionTests.swift` | tests-core-2 | subagent tests-core-2 + parent (regions) | READ | 707 |
| `Tests/SnapCoreTests/LayoutsTests.swift` | tests-core-1 | subagent tests-core-1 + parent (full) | READ | 50 |
| `Tests/SnapCoreTests/MinimumSizePolicyTests.swift` | tests-core-1 | subagent tests-core-1 | READ | 65 |
| `Tests/SnapCoreTests/ModelTests.swift` | tests-core-1 | subagent tests-core-1 | READ | 22 |
| `Tests/SnapCoreTests/OrphanDetectorTests.swift` | tests-core-1 | subagent tests-core-1 | READ | 100 |
| `Tests/SnapCoreTests/PairCellTests.swift` | tests-core-1 | subagent tests-core-1 | READ | 93 |
| `Tests/SnapCoreTests/PostRateTests.swift` | tests-core-1 | subagent tests-core-1 | READ | 16 |
| `Tests/SnapCoreTests/SettingsTests.swift` | tests-core-2 | subagent tests-core-2 + parent (full) | READ | 232 |
| `Tests/SnapCoreTests/SnapAssistTests.swift` | tests-core-2 | subagent tests-core-2 | READ | 494 |
| `Tests/SnapCoreTests/SnapBarGeometryTests.swift` | tests-core-2 | subagent tests-core-2 + parent (full) | READ | 282 |
| `Tests/SnapCoreTests/SnapRegistryTests.swift` | tests-core-2 | subagent tests-core-2 + parent (full) | READ | 57 |
| `Tests/SnapCoreTests/SpaceInterruptionTests.swift` | tests-core-2 | subagent tests-core-2 + parent (regions) | READ | 179 |
| `Tests/SnapCoreTests/ZoneResolverTests.swift` | tests-core-2 | subagent tests-core-2 + parent (full) | READ | 253 |
| `Tests/SystemAdaptersTests/AccessibilityWindowsTests.swift` | tests-adapters | subagent tests-adapters | READ | 163 |
| `Tests/SystemAdaptersTests/CoordinateSpaceTests.swift` | tests-adapters | subagent tests-adapters | READ | 23 |
| `Tests/SystemAdaptersTests/ParkedWindowsStoreTests.swift` | tests-adapters | subagent tests-adapters | READ | 60 |
| `Tests/SystemAdaptersTests/PrivateAPITests.swift` | tests-adapters | subagent tests-adapters | READ | 65 |
| `Tests/SystemAdaptersTests/ScreensTests.swift` | tests-adapters | subagent tests-adapters | READ | 33 |
| `Tests/SystemAdaptersTests/SettingsStoreTests.swift` | tests-adapters | subagent tests-adapters + parent (full) | READ | 78 |
| `Tests/SystemAdaptersTests/SystemTilingPrefsTests.swift` | tests-adapters | subagent tests-adapters | READ | 26 |
| `Tests/SystemAdaptersTests/WindowListTests.swift` | tests-adapters | subagent tests-adapters | READ | 35 |
| `Tests/SystemAdaptersTests/WindowWriterTests.swift` | tests-adapters | subagent tests-adapters | READ | 1132 |
| `Tools/axprobe/main.swift` | axprobe | subagent axprobe | READ | 583 |
| `docs/architecture.md` | docs | subagent docs + parent (full) | READ | 362 |
| `docs/functional.md` | docs | subagent docs + parent (full) | READ | 659 |
| `docs/manual-test-checklist.md` | docs | subagent docs + parent (full) | READ | 235 |
| `docs/pitfall.md` | docs | subagent docs + parent (full) | READ, then REPLACED by `docs/pitfalls.md` | 344 |
| `docs/private-api-index.md` | docs | subagent docs + parent (full) | READ | 64 |

## Files added by the audit

`docs/macOS.md`, `docs/pitfalls.md`, `docs/README.md`, `docs/_audit.md`, this file. Written by the
parent from the slice and stitch reports.

## Membership check

- Files in `Package.swift` targets not on disk: none (SwiftPM globs the target directories).
- Files on disk not in any target: none. `.vscode/launch.json` is an untracked editor file
  (`git status` shows `??`), outside every target, left alone.
- Files unread with an allowed reason: none in scope. Out of scope and unread: `.build/`, `build/`
  (generated), `.signing.env` (secret), `.claude/settings.local.json` (harness), `.superpowers/`
  (the user's).

## End-to-end paths stitched

| Path | Files re-read on the path | Report |
|---|---|---|
| A. Window drag → zone → AX write | MouseEvents, AppDelegate.route, DragSessionController, ZoneResolver, SnapPlanner, SnapBarGeometry, PairCell, ZonePreviewController/Panel, SnapBarController, EngineRouter, SteppingSnapEngine, WindowWriter, AX | `stitch-drag-settings.md` |
| B. Settings → persistence → consumers | SettingsView, SettingsStore, Settings, every stored-property consumer, LoginItem, MinimumSizeStore, ParkedWindowsStore keys | same |
| C. Snap Assist, drop to every window home | DragSessionController.onSnapped, SnapAssistController, SnapAssistPanel/View, ParkedWindowsStore, DeckAnimator, WindowWriter, MinimumProbe, EngineRouter | `stitch-assist-handles-spaces.md` |
| D. Pill and knob, poll to release | HandleBarController, WindowList, Adjacency, JunctionHandleController, Junction, MinimumProbe, HandleDragMath, JunctionDragMath, SteppingSnapEngine, HandlePanel, JunctionPanel | same |
| E. Space / Mission Control / display interruption | SpaceWatcher, SpaceInterruption, AppDelegate.leftTheArrangement, every cancel/dismiss, OverlayPanel, Screens | same |
| F. Launch, permissions, onboarding | SnappySnapApp, AppDelegate, Permissions, OnboardingWindow, MouseEvents.start, SystemTilingPrefs, SettingsView (window) | `stitch-launch-watchers-logging.md` |
| G. Oversize watcher and the write-in-flight rule | OversizeWatcher, WindowList, MinimumSizeStore, SteppingSnapEngine, WindowWriter.hasPending, every main-thread AX read | same |
| H. Logging contract | Logging.swift and every `Logger.<category>` call site | same |

Stitch reports live in the session scratchpad (`reports/`), not in the repo.
