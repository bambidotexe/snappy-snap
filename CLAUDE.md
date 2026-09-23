# SnappySnap — CLAUDE.md

The operating manual for an agent working in this tree. Read it whole before the first edit.

## What this project is

SnappySnap is a menu-bar accessory that gives macOS 26+ Windows 11-style window snapping. Drag a
window to an edge, a corner or the top and it takes a half, a quarter or the working area, and
holding ⌥ grows the side bands until they meet at the middle of the display; near the
top a **snap bar** — a shape that grows out of the notch, an **island** under the top edge of a
display that has no notch, or a floating bar — offers four layouts
and a conditional **pair cell**; a drop from the bar starts
**Snap Assist**, which offers the other cells to the remaining windows and deals those windows into
a corner **deck** meanwhile; two adjacent windows get a **handle pill**, a crossing of dividers a
**junction knob**, both of which drag a preview and move the windows on release; an **oversize
watcher** keeps windows inside the gap. Everything stands down on a Space change, Mission Control or
a display change. Accessibility is the only permission it needs to work. It is one process, no sandbox.
It looks for a newer release on GitHub at launch and once a week, announces one with a notification, and
installs it on a click: a window fetches and checks the release while the app runs, and **Install and
Relaunch** swaps the bundle once the app has quit (the one helper it ever starts, a shell script that
outlives it for a few seconds).

Swift 6.4, SwiftPM, no Xcode project. Deployment target macOS 26; built and measured on macOS 27.0
(build 26A428) on one 1512 × 982 display. It is a personal app by and for one user. A release is
`Scripts/make-dmg.sh`'s disk image attached to a GitHub release. **The check is anonymous, so the
repository has to be public for it to see anything**: a private one reads exactly like no release at all.

## The family, and the shared documents

This app is one of the macOS apps under `~/Projects` that share one shape; the `macos-map` skill lists
them and routes a task to the right skill. **`docs/shared/` is a synced copy of
`~/Projects/macos-app-template/docs/shared/`, and it is never edited here**: a change goes in the template
and `sh ~/Projects/macos-app-template/scripts/sync-shared-docs.sh` replicates it to every app. A trap, a
convention or a platform fact that applies to more than this app goes there, not in this app's own
documents. `docs/shared/workflow.md` is the change workflow every app of the family follows and
`docs/shared/pitfalls.md` the traps they all share; the sections below are this app's own statement of the
workflow, with its own file names, and this app's own traps.

## Read first

| File | What it is |
|---|---|
| `docs/README.md` | The index: which document answers which question, and how to start. |
| `docs/functional.md` | **The authority on behaviour.** Every rule of the app, by feature, with the numbers. Kept in sync with the code by the rule below. |
| `docs/architecture.md` | How the three targets fit, what each layer owns, the drag → zone → write path, state, threading, build. |
| `docs/macOS.md` | The platform facts the app relies on: APIs, coordinate spaces, panels, Spaces, the cursor, persistence. Read it before designing on a platform assumption. |
| `docs/pitfalls.md` | What looks right on macOS and is not, with the measurements. The only place that records approaches that fail. |
| `docs/manual-test-checklist.md` | The app target's only verification. `Sources/SnappySnap` has no automated tests. |
| `docs/private-api-index.md` | The nine private symbols, what each buys, and the public route that works without it. |

## Changing behaviour — the workflow

Every change to what the app does follows these steps, in this order. A change that skips one is
not done.

1. **Find the rule.** Read the section of `docs/functional.md` that governs the behaviour. It is the
   authority: what it says is what the app is supposed to do today.
2. **Check for a conflict.** If the request contradicts a rule that is written there — a number, a
   trigger, an order, a "never" — **stop and ask the user whether the existing rule is overruled**,
   quoting the rule. Do not guess, do not implement both, do not add an exception beside the old rule.
   A request that merely adds behaviour no rule covers needs no question.
3. **Change the code**, in the layer that owns it (`SnapCore` for anything decidable without asking
   macOS; `SystemAdapters` for the one call that asks; `SnappySnap` for wiring, panels and gestures).
   A comment states the present rule, never the history of the change.
4. **Update `docs/functional.md` in the same commit.** Replace the old rule with the new one. Never
   keep an outdated rule, not as a note, not as "it used to be", not as a crossed-out line. If the
   change touches how it is built, a platform fact or a trap, update `docs/architecture.md`,
   `docs/macOS.md` or `docs/pitfalls.md` the same way. A new setting is a row in `functional.md` §14,
   a row in `README.md`'s table and an entry in `SettingsTests`' roster.
5. **Verify.** `swift build`, then `swift test` and count two summary lines. Add or amend a unit test
   in `SnapCoreTests`/`SystemAdaptersTests` for any pure rule, and a line in
   `docs/manual-test-checklist.md` for anything only a person can see.
6. **Commit per task**, conventional commits, staged by path, with the attribution trailers from the
   session's system reminder.

The sync rule in one sentence: **the code and `docs/functional.md` describe the same app at every
commit, and the newer of a request and a written rule wins only after the user has said so.**

### Where a change usually lands

| To change… | Edit | Then document in |
|---|---|---|
| a zone, band or priority | `SnapCore/ZoneResolver.swift`, `Geometry.swift` | `functional.md` §2–3 |
| what a snap actually places | `SnapCore/Arrangement.swift` (the solver), `LayoutArrangement.swift` (bar, pair, Snap Assist), `EdgeDrop.swift` + `NeighbourEvidence.swift` (an edge drop and who stands beside it), `Engines/ArrangementCoordinator.swift` (the correction pass) | §5 |
| the snap bar or pair cell | `SnapCore/SnapBarGeometry.swift`, `PairCell.swift`, `Overlays/SnapBar*` | §4 |
| the notch shape | `SnapCore/NotchGeometry.swift` (every drawing number, with its measurement), `BackdropField.swift` (the blur field, shared with the island), `Overlays/NotchBarView.swift`, `NotchBackdropView.swift`, `SnapBarPanel.presentNotch`; `SystemAdapters/ElevatedSpace.swift`, `BackdropLayers.swift` | §4 *The notch appearance*, `macOS.md`, `private-api-index.md` |
| the island (a display with no camera housing) | `SnapCore/IslandGeometry.swift` (every rect and drawing number, with its measurement), `IslandPresence.swift` (the motion: states, steps, springs, delays, the scale's anchor), `BackdropField.swift`; `Overlays/IslandBarView.swift`, `SnapBarPanel.presentIsland` / `collapseIsland` / `departIsland`, `SnapBarController.restIsland` / `standDown` / `islandPanels` | §4 *The island*, §13, `macOS.md` |
| which surface an appearance comes to on a display | `SnapCore/Settings.swift` (`SnapBarAppearance.surface(on:)`, `SnapBarSurface`), `SnapBarGeometry.swift`, `SnapBarController.PanelRoute` | §4 (the table), §14 |
| the bar's layouts | `Sources/SnappySnap/Resources/Layouts.json` (+ `LayoutCatalog` fallback) | §4 |
| the custom areas held under ⌘ | `SnapCore/CustomZones.swift` (the format, the selectors, the geometry), `Overlays/CustomZonesPanel.swift`, `Drag/DragSessionController` (the ⌘ branch), `UI/SettingsCustomAreasPage` | §3 *Custom areas*, §14 |
| the halves held under ⌥ | `SnapCore/ZoneResolver.swift` (the grown bands and the centre line), `Drag/DragSessionController` (`optionModeActive`, which also hides the bar), `SystemAdapters/MouseEvents` (the ⌥ bit) | §3 *The halves, held under Option*, §16 |
| Snap Assist or the deck | `SnapCore/SnapAssist.swift`, `Deck.swift`, `Overlays/SnapAssist*`, `DeckAnimator.swift` | §8 |
| the pill or knob | `SnapCore/Adjacency`, `HandleBarGeometry`, `HandleDragMath`, `Junction*`; `Overlays/Handle*`, `Junction*` | §9–10 |
| minimum sizes — the list, a window's own floor, the probe | `SnapCore/MinimumSizeList.swift` (a row of `builtIn` is a measurement: `swift run axprobe floor <bundle id>`), `SnapCore/MinimumSizePolicy.swift` (`revealedFloor` is the one rule for what a landing reveals; `lowered` how a saved size comes down), `SystemAdapters/MinimumSizeStore.swift` (`observe`, `recordProbe`, `refused`), `Overlays/MinimumProbe.swift`, `UI/SettingsHandlesPage` (the Apps list and its Add sheet) | §6, §14 |
| how a press arms a drag | `SystemAdapters/MouseEvents.swift` (the two taps), `SnapCore/PressReconciler.swift`, `AccessibilityWindows.window(at:)` (the hit test and its window-list fallback), `DragSessionController.mouseDown` | §3 *Arming*, `pitfalls.md` 47–48 |
| what can hide a pill or a knob | `SnapCore/CoveringSurface.swift`, `WindowList.snapshotWithCoverers` | §17, `pitfalls.md` 49 |
| updates: the check, its schedule, the notification | `SnapCore/UpdateCheck.swift`, `UpdateSchedule.swift`, `UpdatePanel.swift`, the numbers in `Settings.Fixed` (`update…`); `SnappySnap/UpdateController.swift` (the one owner), `UpdateNotifier.swift`; `SystemAdapters/UpdateChecker.swift`; the Updates group of `UI/SettingsGeneralPage.swift` | §14 *Updates*, §1, `architecture.md`, `macOS.md` *Updates* |
| updates: the window, the fetch, making it ready, Install and Relaunch | `SnapCore/UpdateSession.swift`, `StagedUpdateCheck.swift`, `UpdateInstallScript.swift` (the helper's text, its plan, its result); `SystemAdapters/UpdateChecker.swift` (`UpdateDownload`), `UpdateStager.swift`, `CodeSignature.swift`, `UpdateInstaller.swift`, `DetachedProcess.swift`; `SnappySnap/UI/UpdateWindow.swift`, `UpdateController.installAndRelaunch` | the same, plus `pitfalls.md` 51–56 and the checklist's §9b. **Read `pitfalls.md` 51–56 before touching the order of an install** |
| the welcome window: a page, a row, what a grant button does, who is in front | **Invoke the `macos-building-onboarding` skill first.** `SnappySnap/UI/OnboardingWindow.swift` (the controller, the four pages), `GrantRow.swift` (`GrantItem`, `FocusReturnWatch`, `GrantRow`, `Metrics` — every number), `GrantCatalog.swift` (the rows: how each is **read**, how each is **asked for**), `ControlActionHandler.swift`; `SystemAdapters/OnboardingState.swift`; `AppDelegate.showOnboarding`; the Start over group of `UI/SettingsSystemPage.swift` | `functional.md` §14 *The welcome window*, §1 |
| the menu-bar icon, or what opens Settings | `SnappySnap/SnappySnapApp.swift` (the AppKit `@main`), `AppDelegate` (`installMainMenu`, `launchedAsLoginItem`, `followShowInMenuBarSetting`, the status item) | §14–15, `macOS.md`, `pitfalls.md` 50 |
| either brand mark | `Assets/` holds both sources. The menu bar: `Scripts/make-menu-bar-mark.swift` (the two fitted numbers) → the committed `SnappySnap/Resources/MenuBarMark.pdf`, shown by `AppDelegate.menuBarMark()`. The app icon: `Assets/snappy-snap.icon` → the `actool` step in `Scripts/build-app.sh` → the keys in `Resources/Info.plist` | §15, `architecture.md` §15 |
| a sentence the user reads, in either language | the call site, which says `L("The English sentence")`, then **both** `Sources/<target>/Resources/{en,fr}.lproj/Localizable.strings` — each of the three targets carries its own pair, and `Localized.swift` is that target's one route | `functional.md` §18, plus §14 or §15 if the words are the window's or the menu's |
| a constant | `SnapCore/Settings.swift` `Fixed` | the section that states the number |
| a user setting | **Invoke the `macos-building-settings-pages` skill first.** `Settings` stored property + a row on its page, `UI/Settings…Page.swift` + `SettingsTests` roster | §14, `README.md` |
| the Settings window's pages, look or copy | **Invoke the `macos-building-settings-pages` skill first**: it holds every rule of the window's structure, numbers and wording. `UI/SettingsRows.swift` (the kit: `SettingsGroup`, `ToggleRow`, `StatusRow` + `StatusMark`, `SettingsMetrics` with every spacing number), `UI/SettingsView.swift` (`SettingsPageID`: the pages, their titles and symbols), `UI/SettingsWindow.swift` (the toolbar, the height that follows the page), `UI/Settings…Page.swift`; an option's own words sit beside its title in `SnapCore/Settings.swift`, a private feature's in `SystemAdapters/PrivateAPI.swift` (`PrivateFeature`) | §14 *How every page is built*: the group's three parts, the status row, the four copy rules |
| the Health page: a line, its colour, its words, when it is read | **Invoke the `macos-building-settings-pages` skill first** (*The Health page*): two tables, the checks (green, orange or red, at most `HealthLimits.checks`) and the readings (blue, at most `HealthLimits.readings`), and never a preference. A line and its colour: `SnapCore/HealthReport.swift` (`HealthFacts` → `checks(for:)`, `readings(for:)`) and `HealthRules.swift` (every colour, shared with the System page and the Gap group), tested in `HealthTests` (the worst case included); its words: `SnapCore/HealthWords.swift` + SnapCore's catalogues. A polled state (a permission, a tiling switch, the drag detection): `UI/SettingsView.swift` `SystemStatus`; a reading taken on show and Check Again: `UI/HealthCheck.swift`, fed by `AppDelegate` (`engineState`, `AppHealthState`); the readers: `SystemAdapters/CrashReports.swift`, `MouseEvents.isListening`, `SpaceWatcher.isWatching`; the page: `UI/SettingsHealthPage.swift` | `functional.md` §14 *The Health page* |
| Space / Mission Control handling | `SystemAdapters/SpaceWatcher.swift`, `SnapCore/SpaceInterruption.swift`, `AppDelegate.leftTheArrangement`, `DragSessionController.cancelSession` (the one gesture a Space change suspends rather than ends) | §13 |
| a private symbol | `SystemAdapters/PrivateAPI.swift` + a call site that asks `pointer(for:)` every time + a public route | `private-api-index.md` |
| whether a launch opens Settings | `SystemAdapters/QuietLaunch.swift` (the marker and its freshness), `AppDelegate.applicationDidFinishLaunching` (`openedByHand`), `Scripts/install.sh` and `UpdateController.installAndRelaunch` (write the marker) | `functional.md` §14 |
| the uninstall | `SystemAdapters/Uninstall.swift` (what is removed and in what order), the Uninstall group of `UI/SettingsGeneralPage.swift`, `Uninstall.helperScript` (the preferences and the folder go to a process that outlives the app: cfprefsd writes the domain back as this one exits) | `functional.md` §14 *Uninstalling* |
| how windows are written | `SystemAdapters/WindowWriter.swift` | `architecture.md` §2, `macOS.md` |

## Commands

- `swift build` — builds all four code targets. **This is the truth**; SourceKit diagnostics in tool
  results are frequently stale.
- `swift test` — two targets, `SnapCoreTests` (643 tests) and `SystemAdaptersTests` (122). Plain
  `swift test` prints **one summary line per target — count two**; a crashed target prints none, so a
  crash reads as a pass if you grep for one green line.
- `swift test --filter <SuiteName>` — one suite by name. A filter matching nothing in a target means
  that target contributes no summary line.
- Sandboxed Bash fallback: `CLANG_MODULE_CACHE_PATH="$TMPDIR/clang-module-cache" swift test
  --build-system native --disable-sandbox --cache-path .build/cache --config-path .build/config
  --security-path .build/security`. **This one merges the targets and prints ONE summary line.**
- `Scripts/install.sh` — production build → notarized disk image → `/Applications/SnappySnap.app` →
  relaunch, leaving no `.app` and no `.dmg` under the repository. **This is how the app is installed and
  reinstalled, and the app always runs from `/Applications`**; `build/` is only where the bundle is
  assembled, and nothing launchable is left there. `Scripts/publish.sh` does the same and puts the image
  on a GitHub release. `Scripts/run.sh` is a familiar name for `Scripts/install.sh`. Signing
  identity comes from `Scripts/signing.env` (tracked, holds no secret): it looks the Wooflab team's
  Developer ID Application certificate up in the keychain by team id (`TEAM_ID=85F6AC5QZF`);
  `SIGN_IDENTITY` in the environment overrides it, and `-` signs ad-hoc for a throwaway build that
  cannot be notarized. `CONFIG=release Scripts/build-app.sh` prints the path to a release bundle in
  `build/`, installing and relaunching nothing.
- `Scripts/release.sh` — the shippable build: release build → verify the signature (Developer ID for
  the team, Hardened Runtime, no `get-task-allow`) → zip and notarize the app → staple it → build the
  disk image (`Scripts/make-dmg.sh`) → sign, notarize and staple the image → confirm Gatekeeper accepts
  both (`spctl`). Prints the image's path; publishes nothing — `gh release create` stays a separate,
  deliberate step. One-time setup by the Wooflab team's Account Holder: the Developer ID Application
  certificate in the keychain, and `xcrun notarytool store-credentials wooflab-notary --key
  <AuthKey_XXXX.p8> --key-id <KEY_ID> --issuer <ISSUER_ID>`.
- `Scripts/make-dmg.sh` — an already-signed release bundle wrapped in `build/SnappySnap-<version>.dmg`,
  the one asset a GitHub release needs for the installed copies to update themselves. It signs and
  notarizes nothing itself — that is what `Scripts/release.sh` does around it — and publishes nothing.
  `SNAPPYSNAP_UPDATE_FEED=file:///…/latest.json` on the installed app's own binary replaces GitHub's
  reply with a stand-in (`{"tag_name": "v9.9.9", "assets": [{"name": "….dmg", "browser_download_url":
  "file:///…", "size": …, "digest": "sha256:…"}]}`), which is how the whole update is walked offline
  (`docs/manual-test-checklist.md` §9b). The update is only accepted from a build signed by the same
  team as the running one, and the app replaces the bundle it runs from.
- `/usr/bin/log stream --predicate 'subsystem == "dev.rubens.SnappySnap"' --level debug` — live logs.
  `log` alone is a zsh builtin, hence the full path. `--level debug` is required for the deck, handle
  and junction lines. **`log show` returns nothing for this app at any level.** Categories: `app`,
  `drag`, `assist`, `deck`, `handle`, `junction`, `onboarding`.
- `swift run axprobe <command>` — dev probe (`Tools/axprobe`, never shipped). Run it with no argument
  for the usage line. Commands: `prefs`, `apps`, `windows`, `menus <app> [depth]`, `frame <app>`,
  `minsize`, `floor <bundle id> [--front]` (measures a minimum the way the probe does), `press <app> <i.j.k> [--no-activate]`,
  **`elements <app> [depth]`** (the front window's Accessibility subtree, every element's role, title and
  frame — the instrument for a window built in code), **`hit x y`** (what a *real* hit test finds at a
  point: a frame that names a rectangle where `hit` finds nothing is `pitfalls.md` 57),
  **`pressel <app> <i.j.k>`** (AXPress one element, which bypasses hit testing and so separates a broken
  action from a click that never arrived), `setframe <app> x y w h`,
  `setframeid <id> x y w h`, `watch <app> [seconds]`, `dragtitle <app> dx dy [sx sy]`,
  `hover x y [seconds]`, `click x y`, `drag sx sy ex ey [steps]`, `dragvia <steps> x1 y1 x2 y2 …`,
  `dragappvia <app> <steps> x1 y1 x2 y2 …`. The `via` forms post a real multi-leg drag with a dwell at
  each corner, which is what a snap-bar drop needs; `dragappvia` also activates and raises the app
  first, without which macOS does not treat the posted press as a title-bar drag at all.
  `axprobe windows` lists **this app's own overlay panels too**, in the same CG space as everybody
  else's windows — it is the instrument for measuring an overlay, not a screenshot.

## Architecture

Three targets, dependencies downward only. Full version in `docs/architecture.md`.

- **`Sources/SnapCore`** — pure logic, no AppKit, in **CG space** (origin top-left of the primary
  display, y down). `Model` (`DisplayInfo`, `WindowInfo`, `Edge`) · `Settings` (the user's choices) +
  `Settings.Fixed` (every constant) · `Layouts`/`Geometry` (gap insetting, never rounds;
  `anchoredOrigin`) · `ZoneResolver` · `CustomZones` (the areas held under Command, with the
  configuration's own JSON parser) · `SnapBarGeometry` + `NotchGeometry` + `IslandGeometry` + `IslandPresence` +
  `BackdropField` · `PairCell` ·
  **`Arrangement`** + `ArrangementSolver` (what every snap places: dividers as variables, minimums as
  constraints, overflow past the right/bottom edge) · `LayoutArrangement` + `ArrangementFacts` ·
  `EdgeDrop` + `NeighbourEvidence` + `SnapOccupant` ·
  `SnapAssist` · `Deck` · `Adjacency` + `HandleBarGeometry` + `HandleDragMath` + `MinimumSizeList` + `MinimumSizePolicy` ·
  `Junction` + `JunctionDetector` + `JunctionGeometry` + `JunctionDragMath` · `PostRate` (the deck's
  post rate; its only consumer is `DeckAnimator`) · `OrphanDetector` · `AnimationCurve` + `UnitBezier`
  · `SnapRegistry` · `Health` + `HealthRules` + `HealthReport` + `HealthWords` (the Health page's two tables,
  their colours and their words, built from plain facts) · the update's rules (`UpdateCheck`, `UpdateSchedule`, `UpdatePanel`, `UpdateSession`,
  `StagedUpdateCheck`, `UpdateInstallScript`) · `SpaceInterruption` + `MissionControlDetector` + `MissionControlGate` +
  `SpaceSlideDetector` + `DragResumption`.
- **`Sources/SystemAdapters`** — the only code that talks to AppKit and Accessibility.
  `AX` + `AccessibilityWindows` (every element carries a **0.25 s** messaging timeout) ·
  **`WindowWriter`** (one serial queue per pid, one single-slot mailbox per window — **every animated
  window write in the app goes through it**; the probe's 1 × 1 press write and Snap Assist's bounded
  restore pass are the two direct writes) · `WindowList` (CGWindowList, three reads, **never window
  names**) · `MouseEvents` (listen-only CGEventTap) · `Screens` · `CoordinateSpace` (Cocoa↔CG, at the
  panel boundary only) · `SpaceWatcher` (the 60/10 Hz poll and the Space sentinels) · `PrivateAPI`
  (`dlsym`, never linked) + `BackgroundCursor` + `ElevatedSpace` + `BackdropLayers` (the notch
  shape's and the island's Space, backdrop blur and luminance reading) · `MinimumSizeStore` · `SystemTilingPrefs` ·
  `Permissions` · `LoginItem` · `SettingsStore` · `ParkedWindowsStore` · `CrashReports` (the Health page's
  crash line) · the update's I/O
  (`UpdateChecker` + `UpdateDownload`, the only network code; `UpdateStager`, `CodeSignature`,
  `UpdateInstaller`, `DetachedProcess`).
- **`Sources/SnappySnap`** — `AppDelegate` wires everything and owns `route(_:)`, the fan-out that
  decides which feature claims a mouse event (Snap Assist → junction knobs → handle pill → drag
  session). `DragSessionController` · `ArrangementCoordinator` (places an arrangement and corrects it
  from what landed) · `EngineRouter` → `SteppingSnapEngine` (**the one engine**) ·
  `OversizeWatcher` (the 10 Hz sweep: disproving a floor, and keeping windows inside the gap) ·
  `Overlays/` (zone preview, snap bar on all three surfaces — `NotchBarView`, `IslandBarView`,
  `NotchBackdropView` —
  Snap Assist surfaces + `DeckAnimator`, handle pill, junction
  knob, `DimPanel`, `WindowPreviewGroup`, `MinimumProbe`) · `UI/` (onboarding, Settings with its eight pages
  and the Health page's `HealthCheck`, the update window) ·
  `UpdateController` + `UpdateNotifier` (the update's one owner, and its notification) · `SnapState`
  · `Logging`.
- **`Tools/axprobe`** — dev probe. Ships with nothing.

Overlay window levels are structural, not per-panel: `OverlayLevel` is an offset from `.statusBar`
(25) — dim 0, zone preview 1, Snap Assist 4, handle bar 8, snap bar 12 — written once in
`OverlayPanel.init` and required, not defaulted. The dim sits at `.statusBar` itself so it covers the
menu bar (24) and the Dock (20). Nothing in AppKit sits between `.statusBar` and `.popUpMenu` (101).
Every overlay panel is `.moveToActiveSpace`, never `.canJoinAllSpaces`. **A level orders a window only
within its Space**: notch utilities draw in a Space at absolute level 400, so the snap bar's notch
shape and its island keep their level and are *added* to `ElevatedSpace`, a Space of the app's own
at 401. Their panel never moves while the shape animates, and nothing under it runs main-thread code per frame.

## Rules

- **A build of this app reaches a Mac in exactly two ways, and there is no third.** `Scripts/install.sh`
  (skill `macos-install-locally`) builds the production bundle and puts it in `/Applications`;
  `Scripts/publish.sh` (skill `macos-publish-release`) does the same and puts the disk image on GitHub. Both
  build the real thing — release, Developer ID, Hardened Runtime, notarized, stapled — so what runs here
  is what a stranger would download. **Neither leaves an `.app` or a `.dmg` anywhere under the
  repository**, on any exit path including a failed one: a signed bundle in `build/` is a complete
  application that Spotlight indexes and that runs beside the installed copy as a second menu-bar item
  with the same bundle identifier and the same preferences. `Scripts/no-leftovers.sh` holds that rule.
  `Scripts/run.sh` is a familiar name for `Scripts/install.sh`, not a third path.
- **A debug build is never installed, and never made without asking the owner first.** It exists only to
  read something a release build will not show. `CONFIG=debug Scripts/build-app.sh` refuses without
  `DEBUG_OK=1`; that guard is there to make the decision deliberate, not to be worked around. If a debug
  build would help, say why and ask. Delete the bundle when done with it.
- **The version is not chosen ad hoc.** `Scripts/version.sh` holds the rule: a local install always builds
  and installs exactly the tree's own version. `Scripts/publish.sh <patch|minor|major>` is the only thing
  that moves it: it bumps by that level, commits and pushes the bump before it builds anything, then
  releases exactly that version. Nothing bumps it again afterward.
- **`docs/functional.md` is kept in sync with every behaviour change, in the same commit, and never
  carries an outdated rule.** A rule the user has overruled is replaced, not annotated. "It was like
  that before" is not a sentence that belongs in any document or comment in this repo.
- **A request that conflicts with a written rule is a question, not a change.** Quote the rule, ask
  whether it is overruled, and only then implement. If the user reaffirms the request, that is the
  answer: replace the rule.
- **Comments state the present.** A comment records a rule, an invariant, a measurement or a platform
  constraint. No spec section numbers, round or task numbers, dates, attributions, or accounts of what
  the code replaced. History belongs in git and, for traps only, in `docs/pitfalls.md`.
- Swift 6 language mode, strict concurrency. All AppKit/AX/SwiftUI on the main actor. Only
  `WindowHandle` and `WindowWriter` are `@unchecked Sendable`.
- **Accessibility is the only permission the app needs to work.** Never read window names from
  CGWindowList (that needs Screen Recording); titles come through Accessibility. No sandbox, no App
  Store.
- **The app never asks macOS for a permission on its own.** Every prompt follows a click, on a button
  in the welcome window, and there is no second route: not at launch, not from a timer, not from the
  update check. Reading a grant and asking for it are two different calls — a `request` API returns the
  current state too, which is what makes it tempting behind a poll that would then prompt every tick.
- **An update never installs by itself, and a failed one never leaves the Mac without the app.** The
  automatic check only announces; the fetch and the install each need a click. Everything that can
  refuse an update runs while the app is up; the install leaves through `NSApp.terminate`, so
  `applicationWillTerminate` puts the parked windows back; the helper touches nothing until the pid is
  gone, and the previous bundle is kept until the new version is seen running. The network is used
  for the update and for nothing else.
- **Private symbols are allowed under four conditions**: resolved at runtime with `dlsym` and never
  linked, so a symbol a future macOS drops is `nil` rather than a launch failure; a **public route
  that works with the symbol absent** — it may be less exact or less smooth, it may not be less safe
  and it may not crash; behind the one switch `Settings.usePrivateAPIs` (default **on**, effective
  without relaunch); and a row in **`docs/private-api-index.md`**, which is the whole inventory —
  nine symbols today. Ask `PrivateAPI.shared.pointer(for:)` on **every** use, never cache the pointer
  in the caller, or the switch would need a relaunch.
- **The main thread makes no Accessibility read of a window with posts in flight** (measured: four
  such reads take a drag from 121 Hz to 83.5 Hz). Ask `WindowWriter.hasPending` first, or read back
  through a flush outcome.
- **No animated window write on the main thread.** Post it through `WindowWriter`.
- `SnapCore` imports CoreGraphics and Foundation only. Never AppKit.
- `Geometry` never rounds; the engine rounds with `roundedToPoints()` when it applies a frame.
- **A user-facing setting is a stored property on `Settings` and a control in the Settings window.
  Everything else is a `static let` in `Settings.Fixed`** — deliberately not reachable by
  `defaults write`. Promoting one back is the same line moved. `SettingsTests` pins the roster.
- **Every sentence the user reads goes through `L("…")`, in English, and is added to both catalogues
  of its target in the same commit.** English is the key, so the sentence stays beside the thing it
  labels. A sentence with no French falls back to the English silently; `LocalizationTests` fails the
  build instead. Log lines, SF Symbol names, persisted keys and identifiers are never translated.
- **Silence is a defect.** Anything that declines to act logs why, once per change, with the numbers.
- **Measurement before design** on any platform assumption; where a measurement is not available, say
  so in the same breath as the number chosen instead. When sending a fix back, state the property that
  must hold rather than prescribing the patch.
- No `.xcodeproj`. Bundle and signing live in `Scripts/build-app.sh`; the identity comes from
  `Scripts/signing.env`. Ad-hoc signing resets the Accessibility grant on every build and cannot be
  notarized — use the Wooflab Developer ID identity for anything but a throwaway build.
- The system's own edge tiling must be **off** on the dev Mac
  (`com.apple.WindowManager EnableTilingByEdgeDrag` / `EnableTopTilingByEdgeDrag` = 0; check with
  `swift run axprobe prefs`). Settings › System reports it and Settings › Health flags it while it is on;
  nothing warns at launch.
- Subagents run on Sonnet by default and Opus only for judgement-heavy slices; never on the default
  model without an explicit `model`, and never in a fan-out larger than the session limit allows.
- Commit per task, conventional commits, attribution trailers from the session's system reminder.
- **Stage by path. Never `git add -A`** — another agent may be working in this tree, and
  `.superpowers/` is the user's.

## Traps

`docs/pitfalls.md` is the full list, with the measurements. The five that cost the most time:

1. **`swift build` is the truth.** SourceKit diagnostics are stale.
2. **A crashed test target reads as passing** — no summary line is printed for it, so grepping finds
   the other target's green one.
3. **`#expect` does not abort** (`try #require` does) and **compares `CGFloat` to `Double` by
   boxing**, so identical bit patterns report as unequal.
4. **A SwiftUI gesture never fires on this app's panels.** Every click on an overlay is hit-tested in
   the controller, against the same SnapCore geometry function that positions the view.
5. **A size write costs 2–13 ms and is spent waiting for the target application.** Waiting overlaps
   across applications and never within one. Four windows of one application cannot be animated
   smoothly, by any arrangement of the code.

## Status

`swift build` is clean and `swift test` is green (122 + 643 tests) at this commit. The app target has
no automated tests; `docs/manual-test-checklist.md` is its verification. The full account of the
September 2026 audit is `docs/_audit.md`, and `docs/_coverage.md` is that audit's own file manifest;
both describe the tree as the audit found it.

Known defects and limitations, in plain words (the authority is `docs/functional.md` §20):

- **A one-sided junction axis is not re-fitted when an application refuses its size.** Where every
  member of an axis takes the same side, a window that will not shrink leaves the others where the
  drag put them and their shared edge ends ragged. A two-sided axis still corrects itself. The
  diagnostic for anything the knob declines is the **`junction`** log category at `--level debug`,
  which prints the reason a candidate crossing was rejected. Verdicts are logged only on change and
  only while the pointer has moved in the last 2 s, so keep it moving. The checklist (§6) lists the
  lines and what each one means. Capture the log line and `swift run axprobe windows` at the same
  instant; the knob is a function of those frames and nothing else.
- **The update has never been seen end to end in this app.** Its rules are unit-tested, the install
  helper has installed and rolled back a stand-in app for real, and the stager has accepted and
  refused this app's own disk image; the notification, the update window and SnappySnap installing
  over itself are the checklist's §9b. The repository is **public** and carries releases (v1.0.0, v1.0.1,
  v1.0.2), so a check now finds one and the whole path is walkable from an installed copy a version behind:
  `Scripts/publish.sh <level> --no-install` is what leaves one there to walk.
- **A login-item launch has never been seen.** Opening the app opens Settings; started by
  `SMAppService`, it should open nothing, and the Apple event that tells the two apart is unexercised
  because Launch at login is off on the dev Mac. It fails towards a Settings window at login, never
  towards an app with no route in. The third case, a reinstall, **has** been walked: `Scripts/install.sh`
  writes a marker and the launch that follows opens nothing (`QuietLaunch`).
- **The uninstall has been walked end to end** on the dev Mac: Settings › General › Uninstall left no
  login item, no Accessibility grant, no preferences and no Application Support folder.
- A drop preview cannot promise the landing for a window whose minimum size has never been measured;
  it shows the arrangement solved with the presumed 200 × 150, a refusing application lands larger,
  and the correction pass settles the arrangement a beat later.
- Where minimums cannot share the working area, a window is left hanging past the right or bottom
  edge on purpose. What that looks like on a display with another display beyond that edge has not
  been measured.
- A window can be grabbed while the deck is still dealing it back; it ends at its recorded home. The
  property behind it: `DragSessionController` is the one feature whose suspension does not consult
  `SnapAssistController.isActive`.
- A press on a window with writes in flight arms no drag; the press stops the animation and the next
  press works.
- A press outside a pill's band during the quarter second after its release arms a drag that then
  receives no moves and no release; press again once the two windows have landed.
- If the event tap cannot be created after the Accessibility grant arrives, the app logs once and is
  inert until relaunched.
- `Settings.smoothness` paces the Snap Assist deck only; snaps and handle releases run at the display
  link's rate.
- The notch shape's blur strength and reach and its spring are fitted by eye (the shape and the
  shadow are fitted to measurements). The island is fitted to captures and verified on external 1×
  displays only — above a notch utility's island on the primary one — and has never been seen at 2×
  nor on a Mac whose own screen has no housing; its expansion springs and shadow are the notch
  shape's, a capture of the reference island growing never having been measured.
- Multi-display behaviour is verified for edges, zones and the drop preview, on three displays in a
  row, and for the deck, on two side by side. The bar, the pair cell, the dim and a display change
  mid-gesture are written for several displays but unexercised. **Nothing this app shows may span
  two displays**: they have separate Spaces, so a panel is planted on one display's Space and
  clipped there (`pitfalls.md` 43).
