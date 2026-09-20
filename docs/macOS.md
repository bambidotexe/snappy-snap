# SnappySnap — the macOS it runs on

The platform facts the app relies on, as they are in the code today. `docs/pitfalls.md` is the
companion: the facts that look otherwise until measured. Every API named here has a call site in
`Sources/`.

## Process model

- One process, one target: the `SnappySnap` executable. No helper, no XPC service, no launch agent,
  no extension. `Tools/axprobe` is a separate executable for development and is not bundled.
- `LSUIElement` is true (`Resources/Info.plist`): the app has no Dock icon and no main window. The
  entry point is a plain AppKit `@main` that sets `.accessory` and calls `NSApplication.run()`; the
  status item is an `NSStatusItem` that `AppDelegate` adds to and removes from `NSStatusBar.system`,
  because it is optional and a SwiftUI scene cannot be (`pitfalls.md` 50). A main menu is installed
  and never shown — an accessory application's menus do not reach the menu bar — purely so ⌘Q and ⌘W
  keep working while the Settings or onboarding window is key. The app never activates itself except
  to bring one of those windows forward, with `NSApp.activate(ignoringOtherApps: true)`, and
  deactivates again when that window goes away unless a Snap Assist phase or onboarding still needs it.
- **An accessory application is re-opened, not re-launched.** Opening the bundle again while it runs
  delivers `applicationShouldHandleReopen(_:hasVisibleWindows:)` rather than starting a second
  process, which is what lets opening the app be a route into Settings. A cold launch delivers
  `applicationDidFinishLaunching` instead, and the open-application Apple event it can read there
  carries `keyAELaunchedAsLogInItem` under `keyAEPropData` when `SMAppService` is the launcher and
  nothing when a person is. `NSAppleEventManager.shared().currentAppleEvent` holds that event only
  until the app handles one of its own, so it is read first or not at all.
- No sandbox: the app's one entitlement, `com.apple.security.app-sandbox = false`
  (`Resources/SnappySnap.entitlements`), declares exactly that and nothing else — no usage-description
  keys. The bundle is assembled by `Scripts/build-app.sh`, which signs innermost first (each resource
  bundle, then the app with its entitlements) and adds the Hardened Runtime and a trusted timestamp
  when the identity is a real one.
- Launch at login is `SMAppService.mainApp` registering the app itself. Nothing about it is stored by
  the app; the switch in Settings reads and writes the system's answer.

## Permissions

- Accessibility is the only permission the app needs to work. `AXIsProcessTrusted()` is polled once a second until it is
  true; `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` shows the system prompt
  once. The grant is tied to the code signature, so an ad-hoc signature resets it on every build.
- Screen Recording is never requested. Window names from CGWindowList would need it, so the app never
  reads `kCGWindowName`; titles come from `kAXTitleAttribute`.
- System Settings panes are opened by URL: `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`
  and `x-apple.systempreferences:com.apple.Desktop-Settings.extension`.
- The system's own tiling is read, never written, from `com.apple.WindowManager` through
  `CFPreferencesCopyAppValue`: `EnableTilingByEdgeDrag`, `EnableTopTilingByEdgeDrag`,
  `EnableTiledWindowMargins`, all defaulting to true like macOS.

## Updates: disk images, signatures, the helper

- GitHub's anonymous `GET /repos/<owner>/<repo>/releases/latest` lists each asset with `size` and
  `digest: "sha256:<hex>"`, and `browser_download_url` answers 302 to a 200 that carries
  `content-length`. A repository that is private, or has no release, answers 404.
- A file this app fetches itself is not quarantined (the bundle does not set
  `LSFileQuarantineEnabled`), so the copy taken out of its disk image opens without a Gatekeeper
  prompt whether or not the release is notarized. `Scripts/release.sh`'s releases are notarized and
  stapled anyway, for a copy someone fetches by another route — a browser download, which Safari does
  quarantine — where Gatekeeper does check.
- Finder does not scale a disk image's background; it draws it at natural size from the top-left of
  the icon view's content area, and its own bars (title, tab, status/path) can cover up to about 120
  points at the bottom. `Scripts/dmg-background.swift` draws a 660×480 canvas with every mark inside
  the top 340 points and a plain field below, which `Scripts/dmg-settings.py`'s window matches.
- `hdiutil attach <dmg> -nobrowse -readonly -noautoopen -mountpoint <folder>` mounts a release's one
  volume on a folder of our choosing, so nothing of its output is parsed. On macOS 27 it still works
  and prints a deprecation notice naming `diskutil image attach --readOnly --nobrowse --mountPoint
  <folder>`, which the stager falls back on. `hdiutil detach <folder> -force` unmounts;
  `diskutil eject` is the fallback. `diskutil eject <plain folder>` names the volume the folder sits
  on, which is the Mac's own, so only a folder whose device differs from its parent's is detached.
- `FileManager.copyItem` out of the mounted image keeps the bundle's signature valid (measured against
  `codesign --verify --deep --strict`, on a bundle signed by `Scripts/build-app.sh`).
- `SecStaticCodeCheckValidity` with `kSecCSCheckAllArchitectures | kSecCSCheckNestedCode |
  kSecCSStrictValidate` is that same check. The requirement `anchor apple generic and certificate
  leaf[subject.OU] = "<team>"` holds for an Apple Development and for a Developer ID certificate of
  one team alike; a copy from another signer fails with `errSecCSReqFailed`, a tampered one with
  `errSecCSBadResource`. `SecCodeCopySigningInformation` gives the running app's team, and none for
  an ad-hoc build. **An update from the same team keeps the Accessibility grant.**
- When a launchd job's main process exits, launchd kills whatever is left in the job's process group
  (measured: a plain `posix_spawn` child of a job that exits is gone before it runs; a child spawned
  with `POSIX_SPAWN_SETPGROUP` and group 0 runs on). Apps opened through LaunchServices are launchd
  jobs too.
- `ps -axo comm=` prints each process's full executable path, which `grep -Fx` matches exactly: that
  is how the helper sees the new version running without matching by name.
- Moving a bundle is one `rename(2)` when source and destination are on the same volume, which is why
  the update is unpacked under Application Support and refused when the app lives on another volume.
- `UNUserNotificationCenter.current()` traps in a process with no bundle, which a binary run out of
  `.build` is. A notification's action button belongs to its `UNNotificationCategory`; with
  `.foreground` the click brings the app forward. Both the button and a click on the notification
  reach `userNotificationCenter(_:didReceive:withCompletionHandler:)`, the second as
  `UNNotificationDefaultActionIdentifier`, off the main actor.

## Accessibility

- Every call is a synchronous mach round trip into the target application, answered on that
  application's main thread. The wait overlaps across applications and never within one.
- Every `AXUIElement` the app creates carries `AXUIElementSetMessagingTimeout(…, 0.25)`. Setting it
  on the system-wide element also sets the process default.
- Reads: `kAXRoleAttribute`, `kAXWindowAttribute` (to climb from a hit element to its window),
  `kAXPositionAttribute` and `kAXSizeAttribute` (each boxed in an `AXValue`; `AXFrame` is not a public
  constant and is not settable on any application tested), `kAXWindowsAttribute`, `kAXTitleAttribute`,
  `kAXMinimizedAttribute`. `AXUIElementIsAttributeSettable(kAXSize)` is how resizability is asked.
  `AXUIElementCopyElementAtPosition` returns the deepest element, not a window.
- Writes: `kAXPositionAttribute` and `kAXSizeAttribute`, always through `WindowWriter`, on a serial
  queue per pid at `.userInteractive`. A position is clamped by the window server so that a
  40 × 91 pt sliver stays on screen. `kAXRaiseAction` raises a window and activates its application
  asynchronously.
- There is no attribute for a minimum size (`AXMinSize`, `AXMinimumSize` are unsupported everywhere
  measured). A floor is learned by writing 1 × 1 and reading back, or from a landing larger than asked.
- One private symbol, `_AXUIElementGetWindow`, links an element to its `CGWindowID` in one call. Its
  public route matches the element's frame against the window list for the same pid.

## The window list

- `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)` needs
  no permission for `kCGWindowNumber`, `kCGWindowOwnerPID`, `kCGWindowLayer`, `kCGWindowBounds` and
  `kCGWindowAlpha`. Bounds are in CG space. A call costs 0.2–0.3 ms and lists this app's own panels
  in the same space as everyone else's windows.
- Layer 0 is an application window. WindowManager's Mission Control backdrop is layer 19, its Spaces
  bar 14, its thumbnails 15; the Dock is 20, the menu bar 24. The wallpaper agent sits at a large
  negative layer. Owner names are localized and are never compared.
- `NSRunningApplication(processIdentifier:).activationPolicy == .regular` is how an agent or accessory
  process is excluded; `bundleIdentifier` keys the minimum-size store; a process may have neither.
- `CGWindowID`s are recycled, so every per-window record carries the pid as well.

## Mouse input

- One listen-only `CGEventTap` (`.cgSessionEventTap`, `.headInsertEventTap`, `.listenOnly`) for
  `leftMouseDown`, `leftMouseDragged`, `leftMouseUp` and `mouseMoved`, with its run-loop source on the
  main run loop in the common modes. Creating it requires the Accessibility grant.
- A second listen-only tap at `.cghidEventTap`, masked to `leftMouseDown` and `leftMouseUp`. A
  window-move gesture the window server runs itself — fn held with a drag anywhere on a window —
  reaches the session tap as `leftMouseDragged` alone; the press and the release exist only at the
  device level. One event has the same `timestamp` at both levels, and the device-level callback
  runs first (`pitfalls.md` 47). The Accessibility grant is enough to create it.
- `AXUIElementCopyElementAtPosition` answers `notImplemented` (−25208) over a view that implements
  no Accessibility hit testing, such as an application's custom-drawn title strip (`pitfalls.md` 48),
  and answers the menu bar for every point of an application whose windows are on another Space.
- `kAXWindows` is empty for an application all of whose windows are on another Space;
  `kAXFocusedWindow` and `kAXMainWindow` still answer.
- The window server disables a tap whose callback stalls for 1.00–1.05 s (`tapDisabledByTimeout`)
  and may disable it on user input; the app re-enables it and logs the reason and a count. Events in
  between are lost.
- `CGEventSource.buttonState(.combinedSessionState, .left)` is the authority on the physical button.
  It flips before the tap delivers `.up`.
- `NSEvent.mouseLocation` is read on polls that need the pointer without an event.

## Haptics

- `NSHapticFeedbackManager.defaultPerformer.perform(_:performanceTime:)` is the whole API. Three
  patterns: `.alignment` (the lightest, what macOS plays when an alignment guide snaps), `.levelChange`
  and `.generic`.
- **It is a silent no-op on a Mac with no Force Touch trackpad**, and there is no way to ask whether
  one is attached or whether a tap was felt: `perform` returns nothing and throws nothing. A caller can
  only record that it asked. An external mouse therefore feels nothing however the app is configured.
- The performer is a protocol (`NSHapticFeedbackPerformer`), which is what makes a call site testable
  at all — the actuator itself cannot be observed.
- It needs no permission and no entitlement.

## Coordinate spaces

- CG space: origin at the top-left of the primary display, y down. Accessibility, the window list and
  `CGEvent` all use it, so `SnapCore` and every adapter output do too.
- Cocoa space (`NSScreen`, `NSWindow`, `NSEvent.mouseLocation`): origin bottom-left, y up.
  `CoordinateSpace` converts at the panel boundary only, flipping against the primary display's
  height; the flip is its own inverse.
- `NSScreen.screens.first` is the display at the origin; `NSScreen.main` is the focused one. A
  display's identity is `deviceDescription["NSScreenNumber"]`. `visibleFrame` excludes the menu bar
  and the Dock; `frame` does not. `NSApplication.didChangeScreenParametersNotification` is the one
  signal for a display change.

## Panels

- Every overlay is an `NSPanel` with `[.borderless, .nonactivatingPanel]`, transparent, shadowless,
  `hidesOnDeactivate = false`, `isReleasedWhenClosed = false`, `animationBehavior = .none`, and
  `collectionBehavior = [.moveToActiveSpace, .stationary, .ignoresCycle, .fullScreenAuxiliary]`.
  `canBecomeKey` is false everywhere except the Snap Assist surface, which takes key without
  activating so Escape reaches it.
- Window levels are offsets from `.statusBar` (25): dim 0, zone preview 1, Snap Assist 4, handle bar
  8, snap bar 12. Nothing in AppKit sits between `.statusBar` and `.popUpMenu` (101).
- A `.moveToActiveSpace` panel leaves with the Space it was shown on and re-plants in about 7 ms on
  `orderFrontRegardless()`, so every show path orders front before it asks for key.
- Panel moves use `animator()` inside `NSAnimationContext.runAnimationGroup`; the animating `setFrame`
  spins a nested run loop.
- A non-activating panel of an inactive app delivers clicks only to views that take first mouse; a
  SwiftUI gesture never fires. `ignoresMouseEvents = false` is what makes the window server hand a
  panel the cursor region.
- **Liquid Glass renders for real in the key window only.** Everywhere else `.glassEffect` falls back
  to a flat fill of the same material: no refraction, no specular edge. Measured across two
  arrangements with a panel per Snap Assist area — exactly one area, always the last one shown and so
  the one holding key, was real glass. It is a per-window rule, not a per-view one, so several glass
  views in one key window are all real. `Glass.interactive()` is governed by the same fact and never
  fires in this app: an accessory that never activates has no window the system treats as frontmost,
  so a hover has to be fed in from the event tap.
- **A panel's appearance is pinned with `NSAppearance(named: .darkAqua)`**, which applies to the whole
  hosted SwiftUI tree. Without it a translucent material resolves light or dark from what is behind
  the window, so two surfaces over one wallpaper can disagree.
- **A window level orders a window only among the windows of its Space.** A Space has an absolute
  level that is compared first; the user's Spaces are at the bottom and notch utilities create one at
  400. A window in a Space at 401 lists above theirs at plain `.statusBar`; at 400 it lists below,
  and no window level — up to `kCGMaximumWindowLevel`, 2147483631 — changes that. A window can be in
  more than one Space at once; membership ends when the window does. Measured on an external display
  too, with `axprobe windows` during a held drag: the island's panel lists above both of a notch
  utility's windows on the primary display for the whole hold.
- **On a display with no camera housing a notch utility draws an island instead**, and only on one
  display — the primary, here. Traced from captures of a 2560 × 1440 display at 1×: a capsule 25 pt
  tall, 3 pt under the screen's top edge in every state, 74 pt wide at rest and 246 pt at its widest
  (the volume indicator), with continuous ends; grown, about 321 × 175 pt with continuous corners of
  38 pt. It is two windows of 624 × 320 pt centred on the top edge, at `CGWindowList` layers
  2147483628 and 2147483629. It leaves by narrowing to a circle and scaling to nothing about a point
  13 pt under the edge, and arrives by growing down out of the edge and then widening.

## The camera housing and what is behind a window

- AppKit does not name the housing. `NSScreen.auxiliaryTopLeftArea` and `auxiliaryTopRightArea` are
  the two strips of menu bar either side of it, and `safeAreaInsets.top` is its height: on the
  built-in 1512 × 982 display the left strip ends at 663.5, the right one starts at 848.5 and the
  inset is 32 — a housing of **185 × 32** at x 663.5. All three are nil or zero on a display without
  one. The pointer can be moved inside the housing; it is simply not drawn there.
- `CABackdropLayer` with `windowServerAware` set draws the window server's picture of what is behind
  its window — other applications' windows included — with nothing laid over it. Measured with a
  window of our own underneath: its luminance callback reads 1.0000 over white, 0.0000 over black,
  0.5000 over mid grey. `NSVisualEffectView` is the same picture under a material, and a material is
  a blur **plus a tint**.
- The `variableBlur` `CAFilter` on that layer blurs by `inputRadius` scaled per pixel by
  `inputMaskImage`'s alpha. Measured with a black/white edge underneath and luminance probes on the
  dark side: a gaussian with **σ = 2 × inputRadius × mask alpha**, in points on a 2× display (radii
  8–32, rms error under 0.01; linear in alpha from 0.2 to 1). The mask is stretched over the layer's
  bounds, and a bitmap whose first row is the top of the image maps upright onto an unflipped layer:
  a mask opaque in its top half blurs the visual top half and leaves the bottom exactly unblurred.
- A backdrop layer with `tracksLuma` tells its delegate (`backdropLayer:didChangeLuma:`, on the main
  thread) the mean luminance of what it covers, 0…1 in display-encoded values, whenever it changes.
  It needs no permission: the picture never leaves the window server. The values arrive quantised to
  1/64.
- **Reading the backdrop any other way needs Screen Recording.** `CGWindowListCreateImage` is
  unavailable to code built against the macOS 15 SDK or later; reached through `dlsym` it still
  captures this process's *own* window, and the capture of a window whose content is a behind-window
  backdrop is fully transparent — the backdrop is composited in the window server and not handed
  back.
- SwiftUI's `shadow(radius:)` is a gaussian whose σ equals the radius (measured through
  `ImageRenderer` at radii 10, 20 and 40: σ/radius 1.005–1.009). `ImageRenderer` draws SwiftUI into
  a bitmap with no screen involved, which is how a shape or a shadow of this app's can be compared
  with a reference numerically.

## Spaces, Mission Control and full screen

- Mission Control and App Exposé post no notification. They are detected from the window list by
  WindowManager's pid (resolved by bundle id `com.apple.WindowManager`) owning a surface above layer 0
  that covers at least 90 % of a display's width and height.
- `NSWorkspace.activeSpaceDidChangeNotification`, observed on `NSWorkspace.shared.notificationCenter`,
  arrives about a second after a Space slide begins. It is the only signal for a full-screen
  transition. The early signal is a 1 × 1 Space-bound panel (`collectionBehavior = [.ignoresCycle]`,
  alpha 0.05, level `.statusBar`) at each horizontal edge of each display, watched through
  `NSWindow.didChangeOcclusionStateNotification` and confirmed by its absence or displacement in the
  window list.
- A window filling the whole display frame is native full screen and is never corrected.

## The cursor

- The window server shows a cursor only for the active application. Two private SkyLight symbols,
  `CGSMainConnectionID` and `CGSSetConnectionProperty`, set `SetsCursorInBackground` on the app's own
  connection, after which the public `NSCursor.set()` reaches the screen. The override is global to
  the connection, so it is asserted only while the pointer is inside a handle's band, re-asserted at
  60 Hz, and stopped, never reset to an arrow.
- The system's `move` glyph is read from
  `/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/Versions/A/Resources/cursors/<name>/cursor.pdf`
  with its hotspot from the `info.plist` beside it, preferring a `macos27/<name>/` variant. That is a
  file read, not an API; `NSCursor.crosshair` is the fallback. `columnResize` and `rowResize` are
  public.

## Concurrency

- Swift 6 language mode, strict concurrency. Every AppKit, Accessibility and SwiftUI call is on the
  main actor. The C event-tap callback and `NotificationCenter` blocks re-enter it with
  `MainActor.assumeIsolated`; `MouseEvents` and `Screens` use `isolated deinit` to unregister.
- Two types are `@unchecked Sendable`: `WindowHandle` (an `AXUIElement` plus ids) and `WindowWriter`
  (used from the main actor and from every pid's worker under one lock).
- `WindowWriter` returns every outcome to the main actor with `DispatchQueue.main.async`. Its flush
  deadline is 2 s, an idle mailbox is dropped after 60 s, and the sweep runs at most every 5 s.
- Timers run on `RunLoop.main` in `.common` modes so they survive any run-loop mode AppKit enters.
  `SteppingSnapEngine` and `DeckAnimator` drive animation from `NSScreen.displayLink(target:selector:)`.
- `CACurrentMediaTime()` is time since boot and is the clock for every gesture stamp.

## Persistence

All in `UserDefaults.standard`, JSON-encoded:

| Key | Holds |
|---|---|
| `settings.v1` | `Settings`, the twelve stored user choices |
| `minimumSizes.v3` | `MinimumSizeList.Stored` — this Mac's own rows and the removed built-in identifiers; absent while the list is the built-in one |
| `minimumSizes.v2`, `minimumSizes.v1`, `knownMinimums.v1` | deleted on construction, never read |
| `parkedWindows.v1` | `[{windowID, pid, frame}]` — Snap Assist's crash-recovery record, written synchronously |
| `didWarnSystemTiling` | the one-shot tiling alert has been shown |

A window's own floor is memory only. The bar's layouts are `Layouts.json` in the app
resources, with the compiled catalog as the fallback.

## Language

- **A bundle resolves its own language.** `String(localized:bundle:)` picks a `.lproj` inside the
  bundle it is given, against the process's preferred languages, and falls back to the key itself
  when the chosen catalogue has no entry. There is no error and no log line: a missing translation
  reads as English inside an otherwise French window.
- The strings ship inside SwiftPM's per-target resource bundles, so every lookup passes
  `bundle: .module`, never `.main`. `Bundle.module` exists only for a target that declares
  `resources:` in `Package.swift`; a target that loses that line still compiles and silently shows
  English.
- **`CFBundleLocalizations` in the *main* bundle is a separate thing from the catalogues**, and both
  are needed. macOS reads it to decide which languages an app claims, which is what puts the app in
  System Settings › General › Language & Region › Applications. Without it the per-app override is
  not offered, whatever the resource bundles hold.
- A per-app override is stored as `AppleLanguages` in the app's own defaults domain, so
  `defaults write dev.rubens.SnappySnap AppleLanguages '("en")'` forces one language for the next
  launch and `defaults delete` returns the app to following the system. **The preferred languages are
  read once, at launch**; changing them while the app runs changes nothing until it is reopened.
- **A `.xcstrings` String Catalog is compiled by an Xcode build step.** There is no Xcode project
  here, so a `.xcstrings` would be copied into the bundle uncompiled and resolve to nothing. The
  catalogues are old-style `.strings` files, which SwiftPM's `.process` rule handles on its own, and
  which are also an old-style property list — so a test parses one with
  `PropertyListSerialization` rather than by hand.

## Build and signing

- SwiftPM, tools version 6.2, platform macOS 26, no Xcode project. Six targets: `SnapCore`,
  `SystemAdapters`, `SnappySnap`, `axprobe`, and two test targets.
- `Scripts/build-app.sh` builds the `SnappySnap` product, copies the binary, `Resources/Info.plist`
  and the SwiftPM resource bundle into `build/SnappySnap.app`, compiles the app icon with `actool`
  where Xcode is installed, and signs innermost first — each resource bundle, then the app bundle with
  `Resources/SnappySnap.entitlements` — with `SIGN_IDENTITY` from `Scripts/signing.env` (tracked, no
  secret in it: the identity is looked up in the keychain by the Wooflab team's id), falling back to
  ad-hoc with a warning. A Developer ID identity also gets the Hardened Runtime and a trusted
  timestamp; ad-hoc gets neither and cannot be notarized. `Scripts/install.sh` builds the notarized disk
  image, `pkill -x SnappySnap`, waits for the process to go, `ditto`s the bundle out of the image to
  `/Applications/SnappySnap.app` and opens that, leaving nothing launchable under the repository. The
  installed copy is the one that runs; `build/` is staging.
- `Scripts/release.sh` is the shippable build: it verifies the app signs with the team's Developer ID
  certificate and the Hardened Runtime, notarizes and staples the app, wraps it in the disk image with
  `Scripts/make-dmg.sh`, then signs, notarizes and staples the image, and checks Gatekeeper accepts
  both with `spctl`.
- `Info.plist` carries the bundle identifier `dev.rubens.SnappySnap`, `LSUIElement`,
  `LSMinimumSystemVersion 26.0`, `NSHighResolutionCapable`, `NSPrincipalClass NSApplication` and
  `CFBundleLocalizations` (`en`, `fr`).

## Private symbols

Nine, resolved with `dlopen`/`dlsym` at first use and never linked, behind the one switch
`Settings.usePrivateAPIs` (default on, effective on the next call). The inventory, each symbol's
public route and what it loses, is `docs/private-api-index.md`.
