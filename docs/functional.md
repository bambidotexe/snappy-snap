# SnappySnap — functional rules

What the app does, as behaviour a user or a developer can rely on. This is the authority: where a
sentence here and the code disagree, the code is right and this document is wrong, and fixing it is
part of the change. `docs/architecture.md` says how it is built; `docs/macOS.md` lists the platform
facts in play; `docs/pitfalls.md` records what looks right and is not.

SnappySnap is a menu-bar accessory for macOS 26 and newer. It has no window of its own. It brings
Windows 11-style snapping to macOS: drag a window to an edge, a corner or the top and it takes half,
a quarter or the whole working area; a bar at the top offers layouts; after a drop from that bar the
other areas are offered to the other windows; a handle appears between adjacent windows and moves the
edge they share.

---

## 1. Permissions

**Accessibility is the only permission the app needs to work.** It is what lets the app see which
window is under the pointer and move and resize other applications' windows. The one other thing it
ever asks for is notifications, and only to announce an update (last bullet).

- **The app never asks macOS for anything on its own.** Every permission dialog the user sees follows
  a click of theirs, on a button in the welcome window (§14 *The welcome window*), and there is no
  other route: not at launch, not when a window opens, not from the weekly update check. A dialog the
  user did not ask for arrives with no explanation beside it, and a refusal macOS remembers for good.
  Reading a grant and asking for it are two different calls, and the poll only ever reads.
- Without the grant the app polls `AXIsProcessTrusted` once a second and starts the moment it arrives
  — no relaunch, and nothing to close. Until then the menu-bar item, the Settings window and the
  welcome window work and nothing else does.
- If the event tap cannot be created once the grant has arrived, the app logs one line and stays
  inert until it is relaunched; nothing retries.
- **Screen Recording is never asked for.** Window frames, owners and z-order come from
  `CGWindowListCopyWindowInfo`, which needs no permission; window *names* from that list would need
  Screen Recording, so the app never reads them. Titles come through Accessibility instead, which is
  why Snap Assist shows an app icon and a title rather than a live thumbnail.
- No sandbox and no App Store. **The only thing the app uses the network for is its own update**
  (§14 *Updates*): it asks `api.github.com` for this repository's latest release shortly after
  launch, once a week after that and when the button in Settings is pressed, and it fetches that
  release's disk image after a click on **Update**, never before. Nothing but those two requests is
  sent, and no other feature reaches the network at all.
- The Accessibility grant is tied to the code signature. An ad-hoc signature changes on every build
  and resets the grant, so builds are signed with the Wooflab team's Developer ID identity.
- **Notifications are asked for on the welcome window's Allow button and nowhere else.** An automatic
  check that finds a release reads the grant and posts only if it already has it; it never asks, because
  nobody clicked for a dialog on the Tuesday it happens to run. The app posts that one notification and
  no other. Not granted, nothing is lost: the release shows in Settings all the same.

**The system's own edge tiling conflicts with this app** and should be off
(`com.apple.WindowManager`'s "Drag windows to left or right edge of screen to tile" and "Drag windows
to menu bar to fill screen" — the names macOS gives those two switches, quoted wherever the app names
them). The app does not require it, and **it raises no alert about it at launch**: the welcome window's
*Out of the way* page offers it as a row on the first run, Settings › System › macOS tiling reports the
live state for ever after with a button to the Desktop & Dock pane, and Settings › Health has an orange
line for it while it is on.
A third switch, "Hold ⌥ key while dragging windows to tile", fights only the halves held under ⌥ Option
(§3), and is reported in orange only while both are on.

## 2. What a zone is

The working area of a display is its `visibleFrame` — menu bar and Dock excluded. Every zone is
computed in that area and inset by the gap: a gap from the working area's own edges, and half a gap
on each side of a shared divider, so two neighbours end exactly one gap apart.

Cursor tests are against the display's **frame**, not its working area, because the pointer can enter
the menu bar and a window cannot.

Nothing in the geometry rounds. The engine rounds to whole points at the moment it applies a frame.

## 3. Dragging a window to a zone

### Arming

A press on a window arms a drag when all of these hold: the window belongs to another application,
its application is a regular (Dock-showing) one, its size attribute is settable, and it has no window
writes of this app's own still in flight. A press on a window whose animation is still running
**stops that animation and arms nothing** — press again and it works.

**The window pressed is the one Accessibility names at the point**, whatever element of it the point
hits. Where an application's own hit test answers an error — a custom title strip that implements no
Accessibility hit testing answers `notImplemented` over exactly that strip, measured on Affinity's
title and tab row — the window is the **frontmost listed window (§17) containing the point**, found
by its id among that application's windows. A hit test that *timed out* falls back to nothing: an
application that is not answering would not answer those reads either. A press that finds no window,
or a window that is not resizable, logs why and arms nothing.

**A press the window server keeps for itself still arms.** Holding fn and dragging anywhere on a
window is macOS's own window-move gesture, and the session-level event tap receives its drags with
no press before them and no release after. A second, listen-only tap at the device level hears
presses and releases only; a drag that arrives with a device press nobody delivered is preceded by
that press, at the point it was made, and the gesture's release is delivered from the device tap. From
there it is a drag like any other — the zones, the snap bar, ⌥ and the custom areas under ⌘, with fn
still held or let go. Where the device tap cannot be created the app logs it once and such a gesture
arms nothing.

A drag is confirmed on the first move where the window's **origin** changed and its **size** did not.
A changed size is a resize gesture on the left or top border and the session is dropped.

A confirmed drag is armed again without a new press in exactly one case: the Space changed under it
while the user held on. §13 *A held drag survives a Space change* has the rule.

### The zones

With the pointer on a display, in this order of priority:

1. **A snap-bar cell**, when the pointer is inside the bar.
2. **A corner** — within the edge band of a side edge *and* within the corner band of that edge's top
   or bottom end, or within the edge band of the top edge and within the corner band of either end.
   The zone is a quarter.
3. **A side** — within the edge band of the left or right edge. The zone is a half.
4. **The top** — within the edge band of the top edge and not inside the bar. The zone is Fill: the
   whole working area.
5. Otherwise no zone.

The edge band is **24 pt**, so the last pixel never has to be reached; the corner band is **120 pt**.
Once a zone is armed it survives **12 pt further out** than it armed at, so a hand that drifts back
does not lose it, and there is no flicker at the boundary. Each of side halves, corners, top Fill and
the snap bar can be switched off independently.

**A display behaves the same way whether it stands alone or has a neighbour.** An edge shared with
another display arms the same zones on the same terms as an outer one — no setting, no dwell, the
same corner band and the same hysteresis. The **one** difference is the band: a shared edge arms
within **48 pt**, twice an outer edge's 24, because the pointer reaches it from a screen it can
overshoot into rather than from the dead end an outer edge is. A drag on its way to the other screen
therefore does light a zone as it crosses; nothing is placed by it, because the zone is re-resolved
at the release point.

### The halves, held under Option

Off by default, switchable in Settings (§14). **Holding Option (⌥) during a confirmed window drag
grows the left and right edge bands until they meet at the display's own horizontal midpoint**, so
that every point which is not already a corner or the top band resolves to a half: left of the
midpoint the left half, from the midpoint rightwards the right half. It is the second gesture a
modifier adds, and the only other key the app reads (§16).

**Nothing else about the display changes while it is held.**

- **The corners keep their own bands**, the ordinary 24 pt (48 shared) crossed with the 120 pt corner
  band, and their priority over the halves inside it. A pointer 300 pt in from the left edge and 60 pt
  down is therefore the left half, not the top-left quarter; only the narrow band is a quarter.
- **The top band keeps its 24 pt and becomes reachable ahead of the halves.** With Option held the
  order is corner › top › halves rather than corner › halves › top, because a half reaching the middle
  of the display would otherwise swallow the top band and leave Fill with nowhere to arm. With Fill
  switched off the top band is a half like everywhere else.
- **The midpoint is the display frame's**, not the working area's, like every other cursor test (§2).
- **The two halves are exactly equal**, whatever the edges are. An edge shared with another display
  arms from 48 pt rather than 24; Option suspends that asymmetry, and the middle display of a row
  splits at its own centre exactly as an outer one does.

**The centre line carries no hysteresis** — alone among every boundary in the resolver. One point
either side of the midpoint is the other half, whichever half is armed. The 12 pt survival still
applies to the ordinary bands, the corner band and the top band; a sticky centre would read as a dead
band the pointer has to overshoot to leave and overshoot again to come back to.

**The snap bar is off the screen for as long as Option is held**, whatever it is drawn as — the floating
bar goes, and so does the island kept up on a display with no camera housing, through its departure
(§4) — and it claims no hit while it is gone, so a bar that was
showing the frame before cannot take the drop. Both come back on release.

Releasing Option mid-drag restores the ordinary bands at once, resolved from where the pointer already
stands rather than waiting for it to move, because the key can change with the pointer standing still.
**Command outranks Option**: while Command is offering the custom areas, Option means nothing and the
areas behave exactly as §3 *Custom areas* says. With the feature switched off, Option changes nothing
about a drag.

### The drop

The zone is **re-resolved at the release point** — a fast flick can skip the last drag event and the
drop must still count — but nothing is presented for that frame, so there is no preview flash at the
moment of release.

The window then animates to its frame over **0.25 s** on an ease-in-out curve, one frame per tick of
the display's own refresh rate, starting on the same run-loop turn as the mouse-up. Nothing is
activated, awaited or polled first; focus never changes. During the drag the window's frame is read
at most once per 1/120 s.

**A window released across a display seam animates from inside the display it lands on.** Dragged
over from the display next door and let go at the edge nearest it, most of the window still lies on
the display it came from — and with separate Spaces it is drawn on one display at a time, so an
animation from that frame would play on the wrong display and cross the seam part-way. The
animation's first frame is therefore the released frame **slid, never resized, flush against the
seam** — the same departure the drop preview shows. Only a frame that reaches onto another display is
moved: a window hanging past an edge with nothing beyond it leaves from where it hangs. The pre-snap
frame recorded for the drag-away restore is the real one.

### Drag-away restore

Off by default. Switched on, dragging a window that is still sitting in the zone it was snapped into
restores its pre-snap **size** as the drag is confirmed, keeping the pointer at the same proportional
position along the title bar. The record is valid only while the window is within ±2 pt of the frame
the snap gave it; a window the user has since resized or moved has no restore to offer.

### Custom areas, held under Command

On by default, switchable in Settings (§14). **Holding Command (⌘) during a confirmed window drag
replaces the ordinary zones with the user's own areas**, written as JSON on the Settings window's
**Custom Areas** page. It is the one place a modifier *adds* a gesture rather than taking one away
(§16).

While the key is held: the zone preview, its neighbours' previews and the snap bar are taken off the
screen, and **no edge, corner or top zone arms**. Every area that resolves on the display under the
pointer is drawn at once, each one the ordinary drop preview in full — same corner radius, same
stroke, same shadow, same fill. The one area holding the pointer is **only** more opaque: `2 ×` the
ordinary fill, and nothing else about it differs.

Releasing Command mid-drag restores the ordinary behaviour at once, resolved from where the pointer
stands rather than from where it last moved — the key can change with the hand still. Releasing the
mouse with Command held places the window in the area holding the pointer **at the release point**,
animated by the same path as every other snap (§3 *The drop*). It is placed as a single box with no
neighbours, and no Snap Assist follows.

**Command never falls back.** With no area under the pointer, no area resolving on this display, an
empty configuration or one that does not parse, nothing is drawn and the release places nothing: the
window stays where the drag left it. With the feature switched off, Command changes nothing about a
window drag at all.

#### What the configuration says

The stored text is an **array**, and each element is **one area**. Comments are allowed wherever
whitespace is — `//` to the end of the line, and `/* … */` across lines, but not inside a string. The
text is stored exactly as the user wrote it, comments and all; nothing is ever written back over it.

Each element is an object whose keys are **screen selectors**, and optionally `app` and `window`
(*Areas for one application or window* below). For a display, the area takes the first key that
matches, tried in this order of specificity and **not** in the order the keys are written:

1. `screenName:<name>` — the display's name exactly, ignoring case and surrounding space. Never a
   substring: that is what tells `Y27qf-30` and `Y27qf-30 (1)` apart.
2. `screenName:built-in` (or `builtin`) — a **reserved word**, answered by asking macOS which display
   is the built-in one rather than by its name, so it survives Apple renaming the panel. A display
   literally named "built-in" is shadowed by it.
3. `screenResolution:<W>x<H>` — the display's **frame** in points, not its working area, each side
   **0.5 pt** on each side.
4. `*` — any display.

A matched `null` means the area is **not on this display** and **stops the search**: a `*` written
beside it is not consulted. That is what takes one area off one screen and leaves it on the others. No
key matching at all means the same.

A value is an area written in one of two ways, never both at once:

- `bounds: { x, y, width, height }`, or
- `anchor` with a `size`, and an optional `offset: { x, y }` that defaults to nothing. The area is
  placed so its own anchor point lands on the working area's, then displaced by the offset (x right,
  y down). The anchors are `top-left`, `top`, `top-right`, `left`, `center`, `right`, `bottom-left`,
  `bottom`, `bottom-right`. A `size` is `width`/`height` in points or `widthPercent`/`heightPercent`
  as a fraction of the working area, and the two axes may be written differently.

Every number is measured against the display's **working area**, from its top-left with y increasing
downward — the menu bar and the Dock are already excluded.

Each area is then **inset by the gap**, reproducing §2: a whole gap on a side lying on the working
area's own edge (within **0.5 pt**), half a gap on every other side, so
two areas written flush end exactly one gap apart. With the gap switched off nothing is inset and the
numbers written are the frame taken. An area the gap would swallow is dropped rather than offered
inside out.

Areas may overlap freely. The pointer is in the **first element of the array** that holds it: array
order is priority.

#### Areas for one application or window

An area may also say whose window it is for, with two keys written beside its screen selectors:

- `app` — the application's bundle identifier or its name (`"com.vorssaint.utils"` or `"Vorssaint"`);
- `window` — the window's title, exactly, never a part of it.

Each takes one name or an array of names, compared ignoring case and surrounding space, and neither may
be empty. With both written, a window has to answer both. The application is known from the dragged
window's process, which is what reaches a window of an application with no Dock icon, such as a
menu-bar utility's floating panel; the title is read through Accessibility once per drag, and only
while some area names a window by it.

**A window that at least one area targets is offered those areas and no others**, and every other
window is offered only the areas that target nobody. The choice is made for the window, not for the
display: a targeted window on a display where none of its areas exists is offered nothing there, and
Command does not fall back to the untargeted areas. Everything else — the screen selectors, the
insetting, array order as priority — is the same for a targeted area as for any other.

## 4. The snap bar

The bar is drawn as one of three **surfaces**: a **floating bar** below the menu bar, a black shape
that grows out of the **notch**, or an **island** that floats under the top edge of a display with no
camera housing. Which one a display gets is the **appearance** chosen in Settings (§14), decided
display by display, so one drag can meet two surfaces:

| Appearance | On a display with a camera housing | On a display with none |
|---|---|---|
| **Notch or island**, the default | the notch shape | the island |
| **Floating bar** | the floating bar | the floating bar |
| **Notch or floating bar** | the notch shape | the floating bar |

The cells, the layouts, the pair cell, what a hover previews and what a drop does are the same on all
three; a surface decides where the bar is drawn, what arms it, what keeps it up and how it arrives and
leaves. The arming dwell immediately below is every surface's; the paragraphs after it are the
floating bar's, the notch shape's are under *The notch appearance* below, and the island's under
*The island* after it. A surface has its own panel: a drag that crosses from one surface to another
takes the panel it leaves off the screen and puts up another, so the floating bar never inherits the
Space the black shapes are drawn in.

**No surface arms on the instant.** The pointer has to stay inside the surface's arming region — the
edge band for the floating bar, the camera housing for the notch shape, the capsule and the strip
above it for the island — continuously
for **125 ms** before anything is drawn, so a drag that only crosses the region on its way to the top
edge, which is the gesture that maximises a window, never flashes the bar. Leaving the region drops
the wait; entering again starts a fresh 125 ms from zero and never resumes what was already waited.
The wait runs every time the bar arms within one drag, not only the first. A bar **already up** that
follows the pointer onto another display moves on the event, with no wait: the dwell is for summoning
a bar, not for moving one. Nothing else moves with it — the zone under the pointer, the preview it
shows, the test that keeps a bar up once it is up and both appear animations are exactly what they
were. The number is fitted by hand: 150 ms read as a lag on a deliberate summon, 100 ms let a fast
pass through.

**The trackpad taps once as the bar appears**, on every surface, at the instant the dwell above
runs out and the bar is drawn. It is the `.alignment` pattern — what macOS plays when an alignment
guide snaps, the lightest of the three it offers. The dwell is what makes the tap safe to give: a bar
is never summoned by a fast pass, so the tap only ever confirms something the hand held still for. It
fires again at every arming within one drag, each being a bar that was not there. **A bar already up
that follows the pointer onto another display does not tap** — moving a bar is not summoning one,
which is the same distinction the dwell itself draws — and nothing taps when the bar leaves, nor when
the island arrives. A Mac with no Force Touch trackpad has no actuator and
feels nothing, and macOS will not say whether a tap landed or whether there is hardware to land it
on, so the app logs that it asked and claims no more. The switch is *Haptic feedback when it
appears* (§14), on by default.

**The floating bar's arming region is exactly the test that resolves the top zone** — the pointer
within the edge band of the display's top edge — so the bar is offered wherever Fill is, a dwell
later.

Once shown it stays while **either** the pointer is within edge band + 12 pt of the display's top
edge, **or** it is within 16 pt of the bar itself (laterally as well as vertically). Both regions
start at the top edge, so their union is contiguous at any gap: there is no strip where the bar
reveals and hides again, and none it cannot be reached from.

The bar sits **gap + preview stroke + gap** below the working area's top edge — 19 pt at the default
gap — so that the two bands the eye reads, menu bar → preview stroke and preview stroke → bar, are
equal. It follows the gap rather than being a constant. The bar is drawn **above** the zone preview
in window level, because the preview shows the zone the bar is offering and must never cover the cell
the pointer is aiming at.

The floating bar slides down 20 pt while fading in over 0.18 s and dismisses over 0.12 s.

The floating bar is drawn on **Liquid Glass**, the `regular` material, in a 16 pt continuous rounded
rectangle. **It takes key for as long as it is shown**, and has to: macOS composites true Liquid Glass
for the key window only and substitutes a flat fallback everywhere else (`pitfalls.md` 44), so a bar
that never took key showed a flat pane of its own material. Taking key is safe with the mouse button
still down because the panel is non-activating — it neither activates this app nor takes the drag
away from the window under the pointer, and the drag is read from the event tap rather than from any
window. Key goes back when the bar leaves; the notch shape and the island never take it, having no
glass to lose.

On every surface cells are 96 × 64 pt, spacing 8, with the zones **drawn** inside a cell inset
3 pt — a rim and a seam the eye reads, not targets the pointer has to find. The floating bar keeps
12 pt of padding around the row. Four layouts, in
this order, from
`Sources/SnappySnap/Resources/Layouts.json` (hand-editable, with a compiled fallback if the file
cannot be read):

1. halves;
2. two-thirds / one-third;
3. left half plus two stacked quarters;
4. a 2 × 2 grid.

**A cell is rounded 8 pt and a zone 4 pt, except where a zone sits in a corner of its cell: that
corner is rounded 5 pt**, which is the cell's 8 less the 3 pt the zone is inset by, so the two curves
are concentric and the rim between them is even the whole way round the bend. Two corners 3 pt apart
with the *same* radius are not parallel — the inner one converges on the outer through the bend and
the rim reads thinner there. A corner qualifies only by lying on **both** of the cell's inset edges:
one that matches on a single axis is halfway along an edge, facing a seam across the other, and
rounding it wide would curve it away from the zone it is meant to sit flush beside. The rule is a
function of the zone's rect and its cell's and nothing else, so the pair cell's two halves follow it
like every other zone.

The **colours** differ by surface, because they stand on different ground. On the floating bar the
cell and the zone are translucent, `primary` at 9 % and 20 %, so the layout carries the glass's own
tone and follows the system appearance. In the notch shape and in the island they are opaque — the
cell white 28 %, the zone `#777777` — the outline darker than the zones, so a layout reads as light
windows inside a darker display rather than as one bright slab on the black shape. A **highlighted**
zone is the accent colour on all three, at full opacity, arriving and leaving over 0.1 s.

Hovering an area inside a cell highlights it and drives the desktop preview. Dropping there places
the window and starts a Snap Assist phase for the rest of that layout. Dropping on the bar's
**background** is Fill.

**A cell has no dead point.** The zones' *targets* tile their cell edge to edge: the 3 pt seam splits
down its middle between the two zones it separates, and the 3 pt rim belongs to the zone it borders.
Sweeping across a cell therefore hands one zone straight to the next and never passes through Fill.
Where a layout's cells do not cover the cell — `Layouts.json` is validated for bounds, never for
coverage — the nearest zone by centre distance claims the point, ties going to the lower cell index.

The bar's **own** empty space is what Fill is aimed at, and it keeps that job: the padding around
the row and the 8 pt spacing between two cells. Crossing from one cell to the next passes through
Fill for those 8 pt, which is deliberate — it is the whole width of the bar's answer for "neither of
these". In the notch shape the bar's own space is the whole shape outside its cells, the camera
housing included; in the island it is the whole grown shape outside its cells.

### The notch appearance

The bar is drawn inside a black shape that rests in the display's **camera housing** and grows out of
it. It exists only on a display that has a housing; one that has none draws the island or the
floating bar, as the appearance says, and nothing in this list applies to either.

- **It arms on the housing alone**: the pointer inside the housing's rectangle — on the built-in
  display x 663.5 to 848.5, the top 32 pt — held for the 125 ms dwell above. **The top zone is
  untouched**: the whole top edge still resolves to Fill (§3), so in this appearance Fill is offered
  along the edge and the bar only where the shape is.
- **Once grown it stays** while the pointer is inside the grown shape plus 16 pt on its left, right
  and bottom. The housing is inside that region, so there is no strip where the shape opens and
  closes again, and none it cannot be reached from.
- **The grown shape** is the cell row plus 20 pt on either side, and as tall as the housing, the
  64 pt row and 20 pt: 448 × 116 pt with four cells, 552 × 116 with the pair cell, centred on
  the housing and flush with the screen's top edge. **The row hangs from the housing's bottom edge**
  — no gap above it, so the cells sit as close to the physical notch as they can — and is inset the
  same 20 pt on the three sides that are not the housing. The whole shape is the bar's hit region:
  outside the cells it is the bar's background, which is Fill.
- **It grows on a spring that overshoots** — duration 0.5 s, bounce 0.375 — and **returns on one that
  does not** — 0.35 s, bounce −0.2 — so the shape never dips below the housing on its way in. Width,
  height and both corner radii move together. The cells fade in over 0.18 s starting 0.10 s into the
  growth, and out over 0.08 s.
- **The shape**: the top corners are concave quarter circles of 17 pt that flare *outside* the body,
  so it flows out of the screen's edge; the bottom corners are continuous corners of 34 pt. At rest
  it is 2 pt inside the housing on either side with radii of 6 and 12 pt. It casts one shadow, black
  at 0.60 with a radius of 21 pt, 6 pt down, which fades in and out with the growth.
- **What is behind the shape is blurred, not tinted**: a blur whose strength falls with distance from
  the grown shape — σ 11 pt at its edge, 5.1 pt at 20 pt, 2.1 pt at 35 pt, 0.7 pt at 50 pt, nothing by about 63 pt —
  fading in over 0.25 s behind the growth and out over 0.15 s ahead of the return. The field is laid
  out for the grown shape and does not follow it frame by frame.
- **A contrast outline**, 1 pt inside the shape's edge, white at 0.22, appears while the backdrop
  around the shape is dark — mean luminance below 0.18 — and leaves when it rises above 0.24, over
  0.2 s either way. It runs along the visible edge only: never along the screen's edge and never
  where a flare meets the body.
- **It draws above other notch utilities**, whose own shape it covers for as long as it is up.
- **Nothing is drawn until the shape arms**, and the panel leaves when the return spring has
  settled.
- **Without private interfaces** (§14) the shape, its spring, its shadow and its cells are unchanged;
  there is no backdrop blur, the outline is a constant hairline at 0.10 instead of following the
  backdrop, and the shape draws *below* other notch utilities.

### The island, on a display with no camera housing

Under the *Notch or island* appearance, a display that has no camera housing — an external display,
or a Mac whose own screen has none — draws the bar in an **island**: a black capsule floating under
the top edge, placed, shaped and moved like the island a notch utility draws there, and drawn above
it, so the two read as one object. The numbers are fitted to captures of that utility on a 1× display:
its island traced row by row, its motion traced frame by frame at 60 fps.

- **Nothing is drawn at rest.** The island **arrives** on the first event of a drag confirmed over
  the display and **departs** when the drag ends, when ⌥ or ⌘ takes the bar away — it arrives again
  on release — and when the drag moves to another display, departing on the one it left while
  arriving on the one it entered. It has no dwell and no haptic tap: both belong to the expansion.
  The island is up while the dwell is waited out; the dwell decides only when it grows.
- **Collapsed** it is a capsule of 262 × 25 pt, 3 pt under the screen's top edge, centred on the
  display: the utility's own height and place, and its widest island, 246 pt, plus 8 pt on either
  side, so that nothing it shows at rest is seen around ours.
- **It arms** with the pointer inside the capsule's rectangle **extended up to the screen's top
  edge** — so the 3 pt above it are not a dead strip, and a pointer pressed against the edge arms it —
  held for the 125 ms dwell. **The top zone is untouched**: the whole top edge still resolves to Fill
  (§3).
- **Expanded** it is the cell row plus **24 pt on all four sides** — no side of it is the screen's
  edge, and 24 is what its wide corner asks for: a cell's corner then stands as far from the curve,
  along the diagonal, as 20 pt would keep it from a straight edge. That is 456 × 112 pt with four
  cells, 560 × 112 with the pair cell. Its top stays 3 pt under the edge; it grows sideways and down.
  It stays while the pointer is inside the shape plus 16 pt on its left, right and bottom, or above
  it up to the screen's edge. The whole shape outside its cells is the bar's background, which is
  Fill; the 3 pt strip above it is the top zone's, which is Fill too.
- **It arrives** as a dot that scales up to a 25 pt circle — a spring of 0.18 s, bounce 0.20 — and,
  0.275 s after it began, widens to the capsule — 0.25 s, bounce 0.20. **It departs** by narrowing to
  the circle — 0.20 s, no bounce — and, 0.24 s after it began, scaling to nothing — 0.35 s, bounce
  0.35, a spring that crosses nothing 0.17 s in, which is where the shape ends. No step starts before
  the spring of the one before it has run its duration.
- **Both scales are taken about one point, 13 pt under the top edge**, just above the island's
  centre: it is where the utility's own departure scales about. The utility's *arrival* grows down
  out of the screen's edge instead, and the island deliberately does not follow it there: it is
  drawn above the utility's resting island, which starts 3 pt under the edge, and a dot at the edge
  shows above it.
- **It expands and collapses** on the notch shape's springs, the cells fading as they do there. A
  drag that ends on an expanded island collapses it, then departs. A motion reversed mid-way — ⌘
  tapped and released — retargets from what is on screen.
- **The shape** has continuous corners: 12.5 pt collapsed, which makes it a capsule, and 38 pt
  expanded. Collapsed it casts no shadow and carries no outline — the utility's resting island has
  none. Expanded it has the notch shape's shadow, backdrop blur and contrast outline, the outline
  running the whole way round.
- **It draws above other notch utilities**, and without private interfaces (§14) below them, with no
  blur and the constant hairline, exactly as the notch shape does.
- **An interruption (§13) does not fade it: it departs.** An expanded island drops its cells on the
  shared 120 ms fade and goes straight to the circle, with no stop at the capsule; one that is
  already departing finishes its departure.
- **Each display has its own island panel**, built the first time a drag needs it and presented again
  afterwards: a drag that crosses between displays pays a lookup however often it crosses, and a
  display never holds two islands — the one still departing there is the one that arrives again.

### The pair cell

A conditional fifth cell, shown **first**, which places two windows in one drop.

- It appears only when at least one other eligible window exists on **the display the drag was
  confirmed on** — not the one currently under the pointer. Re-resolving a partner mid-drag would
  mean an Accessibility sweep on the drag path, which is not affordable. A drag that crosses onto
  another display therefore carries no pair cell there. With no partner the cell is absent and the
  bar is one cell narrower.
- The partner is the **most recently focused** eligible window: the frontmost one in the window list,
  excluding the dragged window and this app's own. It is resolved once, at drag confirmation, by one
  window-list snapshot plus a bounded Accessibility scan of at most 8 windows.
- It draws as two halves, each carrying its window's application icon — the dragged window's on the
  left, the partner's on the right — so the cell names both windows the one drop places and the side
  each lands on. The two icons are the same size and centred the same way in their half; an
  application whose icon does not resolve leaves that half plain, and the cell and the other icon
  stand. Icons, never live thumbnails: a thumbnail would need Screen Recording.
- **It is one zone, not two.** The sides are fixed — the dragged window always lands left, the
  partner right. The whole cell, including the gap down its middle, is a single hit region: hovering
  anywhere in it lights *both* halves, and crossing the middle neither drops the zone nor replays the
  preview's appear animation.
- Dropping anywhere in it snaps both windows in one gesture. Both go through the engine and both are
  recorded. No Snap Assist follows — the layout has no empty cell left.
- If the second placement fails, the first stands. The dragged window stays where the user's own
  gesture put it; rolling it back would discard the drop they made.
- The partner is deliberately not raised: it is by definition the frontmost eligible window, and
  raising it would take focus off the window being dragged.

## 5. What a snap actually takes: the arrangement

Every snap is solved as an **arrangement**: the windows it places, the cells still open, and the
working area they have to share. One solver places all of them, by these rules, in the order they
yield to each other, on one axis at a time:

1. Nothing starts before the working area's left or top edge.
2. Every window gets at least its minimum size.
3. Windows that stand apart stay apart, in the order they were in.
4. Everything stays inside the working area — given up only when 1–3 cannot otherwise hold, by the
   smallest amount that makes them hold, and **only past the right or the bottom edge**.
5. A divider stays where it is; forced, it moves the least it can.

What differs between one kind of snap and another is only **who is in the arrangement**.

### 5.1 Who is in it

- **A cell of the snap bar is a reset.** The arrangement is the chosen layout with the dragged window
  in its cell, and **no window that was on screen before is consulted**: the two-thirds cell is the
  two-thirds cell whatever stands there. Only the dragged window's own limits can change it.
- **The pair cell** is the halves layout with both windows in it.
- **A Snap Assist pick** joins the phase's arrangement: the layout, and every window placed in it so
  far (§8).
- **A drop on a side edge or a corner** holds the dragged window and its **neighbours** (§5.2).
  A window lying *under* the zone is covered, as it is by every snapping system: it is not beside the
  drop, it takes no part, and nothing is promised about it.
- **A drop on the top edge is a maximize, unconditionally**, and holds the dragged window alone. The
  frame is the whole working area, whatever stands on the display: no window is consulted, no window
  is moved, and no window can make it smaller — the neighbours of §5.2 and the taking of §5.3 do not
  apply to it, and the window list is not read for it at all. Every other window is under the
  maximize and is covered by it. Only the dragged window's own minimum, larger than the working area,
  can take it off that frame, past the right or bottom edge as any arrangement overflows (§5.5).

### 5.2 Neighbours

Evidence is gathered once, at drag confirmation, from one window-list snapshot: visible, layer 0,
regular applications, at least 50 pt a side, never a window name, the dragged window excluded. **It
does not matter who placed the window.** A window the user sized by hand counts exactly as much as
one this app snapped.

A **neighbour** is a window that:

- **looks tiled** — inside the working area (within 1 pt) and standing against **at least two** of
  its sides, anywhere from flush with them to gap + 4 pt inside. A half stands against three sides, a
  quarter or a middle column against two. A window merely pushed up under the menu bar stands against
  one and is not a neighbour; neither is a window floating in the middle. A drop whose edge was
  pulled to such a window is a drop nobody can predict;
- **can be seen** — at least **half** of its area is not covered by the windows in front of it, from
  the frames and the stacking order of the same snapshot. No measurement establishes the 50 %: it is
  "the user can see most of it", stated as a share. A divider nobody can see moves nothing;
- **stands clear of the frame the dragged window takes** (§5.3).

A window of the display left out is logged once per drag, at debug level, with the reason.

### 5.3 Taking what is free

On a side or corner drop — never on the top, which is a maximize and reads nothing (§5.1) — a zone
edge that faces a neighbour standing **beside** the zone moves to that neighbour's facing edge,
one gap clear of it. It works in both directions: a window on the left **third** leaves the right
**two-thirds**; a window on the left **two-thirds** leaves the right **third**. The rule is "take
what is free", not "grow".

- A neighbour stands beside the zone when it starts before the zone and ends before the zone's far
  edge. One that spans the zone — a maximized window, or the window already sitting in that very
  cell — is lying under it and says nothing about it.
- **It must own more than half of the zone's extent on the other axis.** A quarter-height window
  beside a full-height zone says nothing about that zone's width.
- Where several stand on one side, the nearest facing edge is the boundary.
- **Growth never crosses anything else.** An edge moving outward stops one gap short of any other
  neighbour standing in the same rows.
- **Both axes are taken at once.** The second axis is adjusted against the extent the first has
  already taken, so a corner drop that grows across towards a narrow window and down towards a short
  one does not reach the window standing diagonally from it. Both orders are tried and the larger
  frame wins; a tie keeps across first.
- An adjustment that would leave nothing keeps the nominal edges.

Filling is on and is not a user setting. It governs a side or corner drop and nothing else.

### 5.4 Giving room

When a window needs more than its share — a known minimum larger than its cell, or than what is
free — the dividers move: into free space first, then **the windows standing on the other side of the
divider give**, down to their own minimum and no further.

- **In a layout, a divider is one line for the whole layout.** A grid stays a grid: when one window
  of a 2 × 2 needs room, the other row follows, and the four-way crossing the junction knob works on
  is kept.
- **On an edge drop only facing edges are one divider**, so a row is never resized for the sake of a
  window in another row.
- A window standing between two dividers takes what it needs evenly from both sides, and whatever
  one side cannot give is asked of the other.
- **A window that will not grow to its cell** — a maximum, learned from a landing (§5.6) — lets its
  divider come in, so that its neighbour fills what it leaves. A minimum always wins over a maximum:
  a hole beside a window that will not grow is better than an overlap with one that will not shrink.
- **An unmeasured window is presumed to go down to 200 × 150.** That is how far it may be asked; no
  measurement establishes the number. An application that refuses raises that window's own floor (§6), and
  the correction pass (§5.6) puts the arrangement right.

Every window that gives room is written in the same gesture as the dragged one, each animated through
the engine like any other placement.

### 5.5 When it does not fit

Minimums that cannot share the working area cannot be made to. The windows keep their order, pack
from the top-left, and **the excess leaves the display past the right and/or the bottom edge — never
as an overlap in the middle**. A drop on the left half whose minimum is wider than the half, beside a
right-hand neighbour that cannot shrink enough, pushes that neighbour right, partly off the display.

**Overflow is per window, not per divider.** A window that ends at the working area's edge and cannot
fit runs past it alone; every other window ending at that edge stays inside. One log line per window
that overflows, with the numbers.

### 5.6 The correction pass

macOS publishes neither a minimum nor a maximum window size, so an arrangement is solved with what is
known and the rest is found out by asking. Once every window of a placement has landed, per window
and per axis:

- landed **larger** than asked, by more than the 12 pt rounding allowance: that is its **minimum**,
  kept for this arrangement and raised on the window's own floor as every refusal is (§6);
- landed **smaller** than asked, by more than the allowance: that is its **maximum**, kept for this
  arrangement only;
- anything within the allowance is an application rounding its own frame and says nothing, and a
  landing identical to the frame the window came in with proves nothing at all.

With a new limit the arrangement is solved again, from the same layout or the same neighbours, and
only the windows whose frame that changes are written again. **At most two rounds**; an arrangement
still off after them is logged and left as it landed. A window that refused its size keeps the origin
it was given, extending right and down, until the next solution moves it. A window the user picks up
again in the middle of a correction loses its write and is left alone, and a Space change or Mission
Control ends the pass where it stands: a correction is a new write, and everything this app does
stands down when the screen is no longer the arrangement (§13).

A Snap Assist phase starts from the **first** landing of a snap-bar drop, with what that landing
revealed, and does not wait for the drop's corrections.

## 6. Minimum window sizes

**macOS publishes no minimum size.** `AXMinSize` and `AXMinimumSize` were measured across five
applications and four window toolkits (Cocoa, Finder, Safari's, Terminal's, Electron): every real
window answered `attributeUnsupported` on both, and neither attribute appeared in any window's
published attribute names. There is no cheap read and no route by which this app could set one.
Everything below exists because of that.

**The guideline every rule here serves:** a saved size must never leave the user opening Settings to
get a window to shrink. So a saved size errs low, every free look at a smaller window lowers it, and a
refusal raises nothing that outlives the window. The cost accepted in exchange is a handle or a drop
whose preview shows a window smaller than it lands; the correction that follows is §5.6's.

### The list

**One row per application** — bundle identifier, name, width, height in points, and a mark saying
where the numbers came from: **built-in**, **measured** or **edited**. Width and height are at least
1 pt; a row has no unknown axis. Settings › Handles shows the list sorted by name (§14).

The list is the **built-in rows**, minus the ones the user removed, overridden by **the rows this Mac
produced**, measured or edited. Only the Mac's own rows and the removed built-in identifiers are stored
(`minimumSizes.v3`), and nothing at all is stored while the list equals the built-in one, so an
untouched list follows the built-in one from build to build. `minimumSizes.v2`, `minimumSizes.v1` and
`knownMinimums.v1` are deleted on launch and never read.

A row's name is not editable: it is the built-in list's, the running application's when the row is
measured or added, or typed with the identifier for an application that is not running.

**Three things write a row, and nothing else does:**

1. **A measurement.** A probe of a window whose application has no row makes the row, marked measured,
   when the probe was believed on both axes. A probe believed on one axis makes no row: the believed
   axis becomes that window's own floor and the application stays rowless.
2. **A smaller window.** A **held** window seen smaller than its row by more than 1 pt lowers the row
   to the observed size on that axis and marks it measured. It is lowered, never deleted, and never
   raised again by anything but the user.
3. **The user.** Editing a width or a height marks the row edited; a value under 1 pt is refused.
   **An edit does not hold**: a row edited above what a window is then seen at is lowered again by
   that window — the edit is a statement about the application, the window is the evidence. Adding a
   row marks it edited. Removing a row means *measure this application again*, from nothing: a removed
   built-in row is remembered as removed, the application's windows forget their own floors and the
   probes spent on them, and the next probe makes the measured row. Reset drops every measured and
   edited row and every removal, and every window's own floor and probe with them, so what the tab
   shows is what every handle clamps with.

**Held** means observed through an Accessibility path: at a pill or knob press, at a drag start (the
dragged window and the pair partner), when parked in the deck, and at every landing the engine reads
back. The 10 Hz sweep of the window list (§12) looks at every window on screen but **lowers only a
held one**: CGWindowList cannot tell a Save sheet, an alert sheet or a Get Info panel from a main
window, and a row lowered to a sheet's size would be wrong for every main window afterwards. The
sweep asks *held?* first, one dictionary lookup, and makes no Accessibility call. Windows the engine
is animating are skipped; a window under 50 pt a side is not listed. One log line per size lowered,
with the window's size and both numbers.

### A window's own floor

**A refusal never raises a row.** A landing larger than asked by more than the 12 pt rounding
allowance — a snap, a handle release, a junction release, the oversize watcher's correction — raises
**that one window's floor**, per axis, in memory. The window's floor is a raise over its application's
row: what the window will not go below is the row lifted, axis by axis, by its own floor. It is
lowered by the same observations that lower a row, it is never persisted, and it is keyed by
`CGWindowID` and pid so it dies with the window; the table holds 512 windows and drops the least
recently touched first.

A landing is believed as a refusal only when the frame actually changed from the one before the write
(a frame identical to the one before proves nothing was applied) and only past the 12 pt allowance,
one allowance for every path: a handle or junction release re-fits the neighbour against any landing
more than 1 pt over its ask, and raises a floor from it only past the 12.

### The probe

The one measurement is a **1 × 1 write, a read-back and a restore** — one visible blink of the window.
Per axis, a read-back is believed when it is smaller than the size the window came in with (an
application that reflows on resize can answer with the size it still had, which is indistinguishable
from a total refusal; the tie goes to learning nothing), positive, and under 80 % of the working area
on that axis (a floor claiming four fifths of the screen is what an unsettled read looks like). When
the first read is not believable a second is taken — another turn of the application's run loop — and
the smaller per axis kept; on the deck's background path the wait before it is 120 ms, because
patience there is free. An axis not believed is written nowhere.

**At a pill or knob press**, per window, in this order:

1. the window is observed at its current size, which may lower its row and its floor;
2. *Measure an app the first time you use a handle next to it* (§14) is **off** → no probe; the
   clamp is the larger of what is known for the window and **120 × 80**, per axis. The switch forbids
   the measurement, not the knowledge: a floor already known still stops the divider where the window
   stops. 120 × 80 only keeps a window large enough to see and grab back; it is fitted by eye, and no
   measurement establishes it;
3. the application **has a row** → no probe, ever, whatever the switch says; the clamp is the row
   raised by the window's own floor;
4. no row, and the window **has already been probed this session** → no probe; the clamp is the
   window's own floor where it has one and **200 × 150** where it has not. An application that never
   answers a probe believably blinks each of its windows once, not at every press;
5. otherwise **one probe**, whose result is recorded as below. The gesture clamps with its result, and
   with 200 × 150 on an axis that was not believed — erring large, because a divider that stops early
   is a smaller failure than one that promises a size the application refuses.

**In the Snap Assist deck**, once the deal has landed, every parked window is observed at its size, and
then the parked windows **not yet probed this session** are queued — windows of applications **with no
row first**, in deck order, then the rest — and the queue is cut at **four**. Each probe runs on the
writer's own queue and blinks a card in the deck corner, not where the user is looking, so the switch
does not gate it. A probe counts as spent the moment it is written, whatever it reads back.

**Nothing else probes.** There is no probe on a timer, on a covered window or on another Space: a
resize is not a side-effect-free operation (a terminal reflows its scrollback at 1 × 1 and does not
unreflow it), and unattended it is damage with nothing to blame it on.

**Recording a result**, per believed axis: the window was seen at that size, so its row and its floor
are lowered to it if they were larger; an application with no row gets the believed axis as the
window's floor, and both axes as its row; an application with a row and a result **higher** than it by
more than 1 pt gets the window's floor raised — **the row does not move**.

### What a layout does with it

Every arrangement and every drop preview is solved with a window's floor — the row raised by its own
floor — and with the presumed **200 × 150** on an axis nothing knows (§5.4). A refusing window lands
larger than shown, and the correction pass (§5.6) settles the arrangement a beat later. On a handle or
junction release the divider stops at the tightest floor among the windows involved, per axis; a
window that refuses anyway has its neighbour re-fitted once against the frame it took (§9, §10).

### The built-in list

Native macOS applications, plus Chrome, Firefox, Slack and WhatsApp, and nothing else. **Every row is
a measurement**, taken with `swift run axprobe floor <bundle id>` (a 1 × 1 write to a standard window,
the smaller of two reads 150 ms apart) on macOS 27.0, on a real, signed-in main window: Finder,
Safari, Terminal, TextEdit, Notes, Reminders, Contacts, Maps, TV, Podcasts, Books, Stocks, Weather,
Home, Find My, Freeform, Shortcuts, App Store, Photos, Dictionary, Font Book, Clock, Voice Memos,
Passwords, Journal, Activity Monitor, Console, Disk Utility, System Information, System Settings,
Music, Mail, Calendar, Messages, Preview, QuickTime Player, Pages, Numbers, Keynote, Firefox, Google
Chrome, Slack and WhatsApp. Terminal's height is the smaller of two measurements (138 and 174 pt, two windows
of one build); Music's and Preview's rows were read from a window enlarged first, because a window
already standing at its minimum reads as one that did not move. An application that was not measured
is not on it.

## 7. The drop preview

One click-through panel per display, above normal windows. It draws a rounded rectangle at the
window corner radius of macOS (17 pt), a 3 pt stroke in the shared overlay shape colour, a thin
translucent fill, and a tight dark shadow clipped to the rounded rectangle so none of it spills
outward.

- **The shared overlay shape colour is #E6E6E6 in the light appearance and #CFCFCF in the dark**,
  opaque in both. This stroke, the handle pill (§9) and the junction knob (§10) are drawn in it and
  in nothing else: **the three are always the same colour as each other in each appearance**, so a
  change to one is a change to all three. It follows a live appearance switch without a relaunch.
- Both values are fitted by eye against the installed app, the dark one beside macOS's own drop
  preview. Being opaque, it **matches that preview on a mid-tone desktop and drifts from it over a
  very dark or very pale one** — macOS strokes with a translucent grey, which no single opaque colour
  tracks. That is a deliberate trade and not a defect to re-fit (`pitfalls.md` 46).
- **The fill takes its direction from the appearance**: white at 18 % in the light one, black at 13 %
  in the dark. It lightens a light desktop and darkens a dark one, which is two colours by
  definition — it is the one part of the preview that is not the shared shape colour.

- It shows **exactly the frame the window is going to be asked for**, gap included: the
  arrangement's solution (§5), not the nominal cell. A frame that leaves the display is drawn as far
  as the display goes.
- On its first appearance it **morphs out of the dragged window's own frame** over 180 ms while
  fading in over 100 ms — the way the window itself will move on the drop. Zone-to-zone moves take
  150 ms. It fades out in place over 100 ms on no zone and on the drop.
- **The frame it departs from is slid onto the zone's own display**, by the smallest translation that
  brings it inside, and is never resized. Displays have separate Spaces, so a panel is planted on one
  display's Space and clipped to it: a departure rectangle lying across a seam would play half its
  journey on a screen this panel cannot draw on. Each axis is decided on its own — one already inside
  the display does not move at all, so a window held across a vertical seam departs from its own size
  and its own height, flush against the seam. A rectangle larger than the display keeps its size and
  overhangs the far edge, where it is simply not drawn.
- A drop that also moves a neighbour draws **that neighbour too**, as a second preview morphing from
  where it is now.
- A pair-cell drop draws both halves before release, so the whole outcome is visible while the drag
  is still live.

**Where the preview cannot promise the landing.** When the dragged window's minimum has never been
measured, the preview is the arrangement solved with the presumed 200 × 150, and an application that
refuses will land larger; the correction pass (§5.6) then solves the arrangement again — visible as
the windows settling, a beat later, into frames the preview did not draw. This is not fixable without
writing a size to the window mid-drag, which is a visible blink on the window the user is holding,
and the design forbids it. Once the window's floor is known — its application's row, or its own floor
from one refusal — the preview and the landing agree.

Two other honest limits: an application whose size grain is coarse (a terminal on a character grid)
lands within its grain of the preview, not on it; and a window whose own floor covers one axis and
whose application has no row can claim honesty on the other for one gesture.

## 8. Snap Assist

**The trigger is the snap bar and nothing else.** A plain edge, corner or top snap places a window and
does nothing more. A pair-cell drop does not start a phase either. Only a drop made from a bar
layout, where the user has explicitly chosen an arrangement, starts one. A dropped window that could
not be matched to the window list keeps its snap and starts no phase: it could not be told from the
windows on offer.

### What is offered

- **Eligible windows**: on the same display by centre point, regular application, layer 0, resizable,
  not minimized, not this app's own.
- **Every cell of the layout except the one the drop filled** is presented **at once**, each drawn as
  a zone preview on its own cell frame, each showing a card for every eligible window. Nothing is
  filtered: from the snap bar the user is redoing the whole arrangement, so a cell that already has a
  window in it is still offered and a window already placed is still offered as a card.
- **The phase owns one arrangement** (§5): the chosen layout, and every window placed in it so far
  with what is known of its limits. Every other window of the display is in the deck, so nothing else
  is in it. The offered cells are that arrangement's open cells, which makes them **what the placed
  windows actually leave**: a drop that landed wider than its cell because of its minimum leaves its
  sibling the rest, and one that would not grow to its cell leaves it more.
- The arrangement is solved again **at every pick, and at every landing that reveals a limit**, and
  the areas still open **move and resize** with it, in the same motion and on the same curve as the
  cards.
- An open cell is solved with a **200 × 150** placeholder minimum, so a placed window's needs cannot
  squeeze it to nothing, and it is offered only while it lies **entirely inside the working area**. A
  cell the placed windows have pushed off the display is withdrawn — it fades like a filled one — and
  a drop that leaves no cell at all starts no phase.
- **Cards** carry the application icon and the window title (two lines maximum). They run along the
  cell's long axis — horizontally in a landscape cell, vertically in a portrait one — and wrap into a
  grid when one line cannot hold them at a usable size. Card size shrinks as the count grows. Each
  area fades and scales in over 200 ms, from 92 % of its cell.
- **A card is Liquid Glass**, the `clear` material, rounded at 14 % of the card's side. Nothing is
  drawn around it: the material's own edge is the only one, and the regular material is deliberately
  not used — on a card this small its defined edge reads as a border and it carries too little of the
  desktop through. Under the icon and the titles, and above the glass, a black gradient runs from
  55 % at the card's bottom edge to nothing at its top, so the labels stay readable over whatever
  wallpaper shows through. The labels are white.
- **Hovering a card tints its glass white at 12 %**, over 120 ms, and leaves the same way. The tint
  is the whole of the hover: no border, no fill, no growth. The card under the pointer is decided by
  the controller from the event tap, against the same card frame a click is resolved against, and
  never by the view — the material's own interactive response answers a pointer this app never
  receives, because an accessory that never activates has no window the system treats as frontmost.
- **Every area of a display is drawn in one surface**, covering that display's working area, with
  each area placed at its own cell inside it. One and not one per cell, because **macOS renders true
  Liquid Glass only in the key window**: with a surface per cell exactly one area — whichever was
  shown last, so it changed with the arrangement — was real glass and the rest were a flat fallback
  of the same material. The surface is pinned to the dark appearance, so an area looks the same over
  a bright wallpaper as over a dark one.

### Picking

Clicking a card raises that window and places it in that area; that area stops offering cards. The
chosen window's card **leaves every other area**, fading out and scaling down, and the remaining cards
animate to their new positions rather than jumping. A window can be placed once.

The pick joins the phase's arrangement, which is solved for everything the pick decides (§5): the
window takes its cell; **a window placed earlier gives room** when the picked one's minimum needs it,
re-fitted through the engine in the same motion; and what cannot fit leaves past the right or the
bottom edge rather than overlapping. The correction pass (§5.6) follows the landings.

Clicks are hit-tested by the controller against the same geometry that positions the cards. A point
resolves to a card only when no *other* card could have been drawn over that point during the 0.22 s
reflow — the app cannot see its own pixels, and a click aims at a frame the display presented tens of
milliseconds ago, so the honest answer is a narrow band that does nothing rather than a guess that
picks the wrong window. For the same reason an area that is still travelling to a new frame answers
nothing for the 0.27 s that takes — not on its cards, which are carried by the area's motion and
their own at once, nor anywhere it has been since it set off — and such a click is never read as a
click outside.

### Ending

A phase ends on: the last area being filled or withdrawn, a click on a surface's backdrop between the cards, a
click outside every area, Escape, a new window drag, a display change, a Space change, Mission
Control, or quitting. Escape always ends it, at any point, including after picks.

**A click anywhere on the display the phase is running on ends it there and goes no further.** The
surface covers the working area, so the click that ends a phase does not also reach the window it
landed on. A click on another display is not the phase's to take and passes through untouched.

**Ending never undoes what is already placed.** Windows already chosen stay in their cells; only
still-parked windows are dealt home.

### The deck, and parking safety

The windows cleared out of the way are not hidden or minimized. They are dealt into a bottom corner of
**the display the phase is running on** and dealt back when the phase ends. That display and no other:
only windows whose centre is on it are eligible, so only windows from it are ever parked, and a deck
anywhere else would clear a screen the user is not looking at while leaving the one they are.

- macOS will not let a window leave the desktop: asking for a far-off position leaves a **40 × 91 pt**
  sliver whatever the window's size. The deck uses that deliberately — an arc of offsets so the
  slivers stagger like the edge of a deck of cards. There is no rotation; Accessibility exposes
  position and size and nothing else.
- **Which corner is decided by the arrangement, not chosen.** The desktop is the union of the
  displays, so a card's body is hidden only where no display can draw it: the overhang goes past
  whichever edge of the phase's display has nothing beyond it. A lone display, and the right-hand one
  of a pair, keep the **bottom right**. The left-hand one of a pair hangs its cards off its own
  **left** edge, so its deck sits at the bottom left. A display hemmed in on both sides has no free
  horizontal edge, so its cards are **centred** and hang straight down from the bottom. The same rule
  turns the deck upwards on a display with another below it. A neighbour counts only where it
  overlaps on the other axis, and it need not abut: a display set off to the right with a gap before
  it still draws whatever slides into the gap.
- A card that hangs past the near edge is placed from its own size, because a window extends right
  and down from the origin Accessibility sets. That size is the one already in the snapshot the phase
  was started from, so it costs no extra read. **A card longer than the display it is dealt on cannot
  be kept off a neighbour** — it is centred, and the overhang shows. Only a resize would prevent it,
  and the deck never resizes.
- **Position writes only.** A card is never resized, so no application's minimum can distort one.
- **Every card may be probed** (§6 *The probe*): once the deal has landed, up to four cards not yet
  probed this session — those of applications with no row first — blink in the deck corner, one at
  a time, on the writer's own queue.
- Cards start 30 ms apart, the whole stagger capped at 150 ms, each travelling 0.25 s on the same
  ease-in-out curve as a snap, so a deal takes at most 0.40 s. The slots lie on an arc from 10° to 72°
  around the corner, 8–14 pt apart, out to a 200 pt radius.
- Every card is posted on every frame of the display link, under one rate gate for the whole pass so
  the cards move together — this is the one place the Smoothness setting applies. A card whose
  *rounded* position has not changed since its last post is skipped — that cannot delay it, and it
  saves a round trip into the target application for a write that could not change a pixel. A cheap
  card follows the curve; a dear one drops its own stale frames and lands exactly at the end. A card's
  final read-back may wait up to 2 s for a slow application before it counts as not arrived.
- Above the deck ceiling (**20** windows) the overflow is placed without animation, because a deck
  that stutters is worse than one that does not play.
- **Every window is recorded to disk before it is moved** (`parkedWindows.v1`), and un-recorded only
  if the move fails. That ordering is the whole safety property: a crash can leave a record naming a
  window that never moved — restoring which is a no-op — but never a moved window with nothing naming
  it. On the next launch every persisted frame is restored to the windows that still exist. The
  record is cleared only once every window is actually back, so a partial restore stays recoverable.
- A window the app **failed** to move is not recorded, so nothing it did not touch is touched on the
  way back.
- Arrival is decided by a read-back, not assumed: within 1 pt of the target is *arrived*; anything
  else, a failed write, or no answer at all is *failed* and the record is kept. A cancelled write is
  never read as "confirmed home".
- After a pick, the chosen window ends up frontmost, raised once the others are back. Raising it
  activates its application a moment later, so the surfaces take key back 120 ms after the pick and
  Escape keeps working.

## 9. The handle pill

### When it appears

A 10 Hz poll of the window list — running only while the pointer has moved in the last 2 seconds —
finds every **pair**: two windows whose facing edges are between −1 pt and **16 pt** apart, whose
overlap along that edge is at least **60 pt**, in either orientation, with the band not covered by a
window in front of either — a window that takes part (§17) or a covering surface (§17). It costs no
Accessibility at all.

Two refinements the window list's z-order makes possible:

- A pair's two windows are the **frontmost windows visible on either side** of the divider. Identical
  frames stacked behind never win a pill.
- Occlusion is judged **where the pill is drawn**, not along the whole divider.

Hovering the hit band — the gap widened to at least **10 pt**, over the overlap — fades in a pill
over 120 ms: **4 pt thick and `min(overlap, min(48, max(24, overlap − 16)))` pt long** — 44 pt at the
60 pt minimum overlap, 48 from 64 pt up — fully rounded, in the **shared overlay shape colour (§7)**
and opaque with it, with a soft shadow, centred on the overlap and on the gap the previews leave. The
shadow is the whole of what separates the pill from a pale wallpaper. Leaving the band hides it after
a 100 ms grace.
While a drag is live the panel widens to 96 pt across the divider, so a pointer that outruns a 10 pt
band does not hand the cursor back to the window underneath.

It does not care who placed the two windows, whether they are the same height, or whether they were
ever snapped by this app.

### Holding Command

A pill and a knob are drawn in the gap between two windows, which is exactly where macOS puts a
window's own resize edge, and while one is on offer it claims the press. **Holding Command (⌘) takes
both features away entirely** so that edge can be reached: nothing is drawn, a pill or knob already on
screen leaves **at once and with no fade**, none is offered on hover, no press in a hit band is
claimed, and the background cursor override stops (§11). The press lands on the window underneath and
macOS resizes that one window natively. Releasing Command restores the ordinary behaviour with no
special case — the next hover fades a handle back in over its usual 120 ms.

**A drag already in flight is never suppressed.** Once a pill or a knob is being dragged it is no
longer an offer to take away but the divider the user is holding, with previews and the dim behind it
and windows waiting to be written on release. Command pressed mid-drag is therefore invisible: the
previews keep following, and the release lands both windows as it would have. Command answers only
what has not been grabbed yet.

The hide happens on the keystroke itself rather than on the next poll. The 10 Hz poll stands still
while the pointer has not moved for 2 seconds, so a handle under a motionless pointer would otherwise
stay on screen until the mouse was jiggled — which is the whole gesture failing, because the pointer
is motionless exactly when the user is about to press.

### Press

The press is the **only** part of the gesture that touches Accessibility: two window lookups, two
resizable checks, one frame read per window, and a minimum-size probe for a window whose application
has no row and which has not been probed this session (§6).

### Drag

**A drag event makes no Accessibility call whatsoever, and no window moves.** What follows the pointer
is a picture:

- the pill itself;
- **one preview rectangle per window**, drawn in the zone preview's own style, showing exactly where
  each window will end up;
- everything else **dims**: one click-through panel per display, 30 % black, over the **full display
  frame including the menu bar and the Dock**, fading 120 ms in and out. During a divider drag nothing
  on screen is true, and a bright menu bar over a dimmed desktop reads as a rendering fault.

The divider follows the pointer, each window keeps its far edge, the gap between them is normalised
to the standard gap, and the divider is clamped so neither window goes under its floor. Because the
clamp is a pure function of the requested divider and nothing is carried between passes, the pill and
both previews simply **stop** at a minimum while the pointer carries on, and re-engage without a jump
when it comes back.

**A drag cannot outlive the mouse button.** The real button state is checked on every poll; a drag
whose mouse-up was lost — the button up on two consecutive polls with no mouse event received between
them — is **cancelled**, and a cancelled drag writes nothing. Never merely "the button is up": the
physical release precedes the tap's `.up` by milliseconds, and a timer firing in that window would
orphan an ordinary release. A `.up` that finds no live drag writes nothing either.

### Release

Both windows animate to the frames the previews were showing, **shrinkers first** — a divider moves
shared edges, and a grower's target overlaps where a shrinker still is. Each window's placement runs
through the engine, so it animates and is written off the main thread.

A press and release with no movement does nothing at all: no resize, no normalised gap.

A window that lands larger than it was asked for raises its own floor (§6) — never its application's
row — and its neighbour is re-fitted once against the frame it actually took (§6).

## 10. The junction knob

Where the corners of two or more windows meet, a round knob replaces the pills that meet there — two
targets at one point would make which windows move depend on a pixel.

- **A knob appears wherever two, three or four windows' corners meet at a point.** A quadrant no
  window claims is simply empty: there is nobody there to resize, and nothing else about the junction
  changes. So a knob appears at the middle of a 2 × 2 cross, at a T (three windows, one divider
  running through one of them), at an L (three windows, one quadrant empty), at a diagonal pair (two
  windows touching corner to corner), and at **each end** of every divider — including where that end
  is the edge of the screen. A plain left-half / right-half split therefore carries a knob at the top
  of its gap and another at the bottom.
- **Corners have to point in different directions.** Two windows sharing a bottom-right corner are not
  a junction: they claim the same quadrant, the frontmost wins it, and one window is not a crossing.
  A window on its own is never a crossing.
- **Candidates are corners, not pairs of dividers.** Every window's four corners are clustered within
  the tolerance below, and a cluster holding corners from two or more windows is a candidate. Nothing
  has to be measured as crossing anything.
- Junctions are computed from the same window-list snapshot the pill poll already takes, so a
  junction costs no new Accessibility traffic to detect.
- **A window takes part only if it is visible at the crossing.** Quadrant occupancy is resolved front
  to back and the frontmost claimant of each quadrant wins. A window hidden behind a member is not a
  member. A member keeps the quadrants it wins and is dropped only when it wins none — so a window
  lying in front of *part* of a spanning window does not destroy the junction. A window may **cancel**
  a crossing only when it is in front of at least one member, intersects the 24 pt knob band, and some
  part of that intersection is itself visible.
- Two corners count as meeting within a tolerance of **24 pt** — the knob's own hit band, the region
  in which the user can already grab the crossing. A member's edge must be within that tolerance of
  the crossing, and the re-derived centre within twice it.
- At most **one** member may span a divider. Two windows each running past a whole divider, with
  nobody at the crossing itself, is not a shape the drag can resize and gets no knob.
- The knob is drawn **centred on the junction point** — except at a T, below — read from the frames
  the previews are drawing: per axis, the midpoint of the members' facing edges where windows face
  each other across it, and the members' **shared edge** where they all take the same side. At a gap
  narrower than the 12 pt disc it overlaps both sides equally — 2 pt each at the default gap. Its hit
  band is a 24 pt square at the same point, widened to 96 × 96 pt while a drag is live. It is filled
  in the **shared overlay shape colour (§7)**, the pill's own, with the pill's shadow, so the two read
  as one family.
- **At a T the knob is pushed 4.5 pt off the crossing, away from the member that spans**: outward
  along the divider that terminates, into the gap the two windows facing each other leave. A T's free
  space is not symmetric about its crossing — the spanning member presents a flat face half a gap
  away, while on the other side the two facing windows round their 17 pt corners away from it and the
  gap between them carries on as a corridor — so a disc drawn on the crossing reads as pressed against
  that face. The push applies at rest and under the pointer alike, and the **hit band goes with it**,
  so the knob is grabbed where it is seen. The distance is judged by eye rather than measured, and is
  a flat number rather than a fraction of the gap: what opens the space is the corner radius, which is
  still there with the gap switched off. **Only a T is pushed** — a cross, an L, a diagonal pair and
  the free end of a divider are all drawn exactly on the crossing.

**Dragging is two-dimensional**, and every member's far edges stay put while the edge that touches the
knob moves. What each axis means depends on what is around it:

- **Both sides occupied**: the axis moves the divider between the windows, and the gap between them
  becomes the gap setting — half a gap either side of the crossing. All the members on that axis
  change.
- **One side occupied** (an empty quadrant, or the free end of a divider): the crossing **is** the
  members' shared edge and no gap is reserved at all, so pressing the knob and releasing it without
  moving changes nothing. The axis stops a whole gap inside the working area — the same distance a
  snapped window keeps from the screen edge — so a knob on a screen edge cannot be dragged over the
  menu bar or behind the Dock. With the gap switched off it stops flush instead.
- **A spanning member** is not resized on the axis it runs past, and says nothing about where that
  divider is.
- Either axis may clamp on a minimum, or on the working area, independently — a drag blocked
  horizontally still moves vertically.

Everything else is the pill's behaviour: no Accessibility during the drag, one preview per member,
the dim, the button-state check, Command taking the knob away while it is held (§9 *Holding
Command*), and a release that animates every member to its preview's frame, shrinkers first.

## 11. The cursor over the handles

macOS shows a cursor only for the **active** application, and this app never activates. The route
that works does not go through AppKit: the app sets `SetsCursorInBackground` on its own window-server
connection, after which the ordinary public `NSCursor.set()` reaches the screen from this inactive,
non-key accessory.

The override is **global**, so the discipline around it is the design:

- A cursor is asserted **only while the pointer is inside the handle's hover band**, and re-asserted
  on a **16 ms** keepalive — a single `set()` does not stick.
- It **stops** on band exit, on dismissal, on the end of a drag outside the band, while Command is
  held (§9 *Holding Command*), and on both Mission Control and a Space change, before anything else
  is torn down. A global override left asserted across a Space change is this app's resize cursor
  sitting over somebody else's windows — and one left asserted under Command would promise a divider
  drag at the very moment the app has stood down from offering one.
- **Stopping never means setting an arrow.** `NSCursor.arrow.set()` would stomp the I-beam of the
  application underneath. Stopping is stopping.
- The keepalive re-tests the band every tick, so a stuck timer self-corrects; a kill mid-assert
  restores the user's cursor at once.

The glyphs are the system's own: a column-resize cursor on a vertical divider, row-resize on a
horizontal one, and for a knob the system's **move** glyph read out of HIServices' own cursor
resources, falling back to a crosshair if any step of that read fails.

The two window-server symbols are private. With the private-interface switch off, or on a macOS that
has dropped them, there is **no cursor over the handles** and the pill and knob shapes are the whole
affordance.

## 12. The gap, and keeping windows inside it

**The gap is a switch, not a number.** On, a snapped window sits **8 pt** from the screen edges and
8 pt from the window beside it. Off, windows fill the working area edge to edge. The size is a code
constant on purpose, and it is not reachable by `defaults write`.

**The oversize watcher** (a second switch, on by default, read only while the gap is on) brings back
inside the gap any window that has outgrown it — zoomed, title-bar double-clicked, or tiled by macOS
itself. macOS's own zoom places a window flush against the working area, and this is what makes one
arrangement have one kind of edge in it.

- **Oversized** means wider or taller than the working area *less a gap at each end*, within 1 pt.
  The threshold is read from the gap, so it follows it.
- **Only the offending axis is touched.** A window as wide as the display but half its height is
  given the gap left and right and keeps its height and its top edge.
- A window that fills the whole display **frame**, menu bar included, is native full screen and is
  never touched.
- The correction waits for the frame to **stop changing** and then for **0.5 s** on top, so a
  just-zoomed window gets half a second of being exactly what the user asked for, and a window
  mid-zoom is never corrected to a frame nobody chose.
- It stands down for every gesture this app owns, for Mission Control and its re-entry grace, and
  **while the left button is down** — a window being dragged or hand-resized is one the user is
  holding, whatever its frame says.
- The correction animates through the engine like any other placement, one window per pass, and a
  refusal raises the window's own floor (§6).
- **An application that rounds its size to a grid** (Terminal: whole rows of 18 pt and columns of 8 pt,
  to the nearest) can land up to half a cell over the gap. A landing over by no more than the rounding
  allowance (12 pt) is asked once more, for the size as far under as it landed over, which rounds to the
  cell below: the window ends inside the gap, up to one cell short of it, never over it.
- A window that **refuses** to come inside is asked once and then left alone until its **size** changes
  again. Moving it is not resizing it: a refused window put somewhere else stays where it was put.
- It logs a correction and a refusal, with the numbers. A sweep that finds nothing is silent.
- **A window left hanging past the right or the bottom edge by an arrangement (§5.5) is not
  oversized.** The test is the window's size, never where it stands, so such a window is left where
  the arrangement put it. Only one whose own minimum exceeds the working area is asked to come
  inside, once.

## 13. Mission Control and Space changes

Both take every surface down and send every parked window home. Neither is announced by macOS in time
to be useful, so both are *caught* rather than observed.

- **Mission Control posts nothing at all** — no workspace, distributed or Accessibility notification,
  no occlusion change, no frontmost change. It is detected from the window list: WindowManager's
  **pid** (never its owner name, which is localized) owning a surface above layer 0 that covers
  **≥ 90 % of a display's width *and* height**. That backdrop is there full-size at layer 19 within
  **26–57 ms** of the gesture. The full-display test is what separates it from the bare Spaces bar
  that an ordinary drag to the top edge opens.
  The poll runs at **60 Hz while anything is live** and **10 Hz** otherwise. The falling edge carries
  a **150 ms** re-offer grace before pills and knobs may come back — the backdrop leaves 332 ms after
  the exit keystroke and the Spaces bar at 466.
- **A Space change** posts `activeSpaceDidChangeNotification` at **972–1007 ms**, most of a second too
  late. The early signal is two 1 × 1 **Space-bound** sentinel panels per display at 5 % opacity, one at
  each horizontal edge, watched for occlusion: whichever edge leads goes occluded at **27–53 ms**, and
  the alarm is confirmed in the same turn by one window-list read that the sentinel has been
  *displaced* — a slide displaces it, a menu merely covers it. The notification stays as the backstop
  and is **the only signal for a full-screen transition**. A change is acted on exactly once; reports
  within 1.5 s of the last are dropped.
- **Every surface leaves on one 120 ms alpha fade** — the preview, the bar, the Snap Assist surfaces,
  the pill, the knob, the dim and the window previews. Each surface keeps its own timing for the
  ordinary end of its own gesture; an interruption is one event, and five surfaces leaving at three
  speeds reads as five bugs rather than as one dismissal. **The one exception is the snap bar's
  island (§4)**, which leaves through its own departure: it is drawn to pass for the island of the
  utility it sits above, and that one plays the same departure underneath it at the same moment.
- The parked windows are sent straight home on the interruption turn, without animation. Those writes
  are invisible anyway, and correctness outranks the effect.
- Nothing is restored afterwards, save the one case below. Ending it is otherwise the whole
  requirement.

Every overlay is a `.moveToActiveSpace` panel, so it leaves with the Space it was shown on.

A display change (unplugged, rearranged, resolution changed) does the same thing.

### A held drag survives a Space change

macOS has its own gesture on the same edges: hold a dragged window against a side edge and the Space
switches, carrying the window along. **The mouse button never goes up**, so the drag that arrives on
the new Space is the same drag, and it is **suspended rather than ended** — the user snaps on the new
Space without ever letting go. Only a *confirmed* drag: a press that has not yet moved the window goes
idle with everything else, because there is no drag to bring back.

- **Every surface still leaves**, on the same 120 ms fade as any other interruption — the island
  through its departure. The resumption
  puts nothing back on screen; it brings the session back invisibly.
- It comes back on the first drag event at least **0.6 s** after the change was caught **and** at
  least **8 pt** from where the pointer stood when it was caught — a straight-line distance, not
  either axis alone. The 0.6 s is the slide: the change is caught 27–53 ms in and the slide runs about
  450 ms longer, and a window list read taken during it describes the Space being *left*. The 8 pt is
  the pointer, which is still resting against the edge that triggered the slide; resuming where it
  stands would light that edge's zone the instant the new Space appeared, under a hand that was
  holding still to switch Spaces. Until both hold, the drag does nothing at all.
- **Coming back means rebuilding, not unfreezing.** The dragged window's frame, the display under the
  pointer, the snap bar's session and its pair partner, and the window list the arrangement reasons
  about are all read again against this Space. Nothing the session held before the change is reused —
  those windows are on a Space the user has left. The drag-away restore (§3) does not run a second
  time; it is a one-shot at the start of a gesture.
- **The other ways it ends.** A release places nothing, because no zone was ever resolved against this
  Space. A press ends it too: the button is down, so the mouse-up it was waiting for never reached the
  event tap. Mission Control, a display change and an ordinary cancel all end it outright. A second
  Space change suspends it again, restarting both the 0.6 s and the 8 pt from the new one.
- **Mission Control is not included**, and neither is a display change. Thumbnails are not an
  arrangement to snap into, and the whole gesture is already declined for as long as Mission Control
  is up; a display change invalidates the geometry the drag was measured against.

## 14. Settings

Opened from the menu-bar item (⌘,), and by opening the app itself — from the Applications folder,
from Spotlight or with `open` — whether it is already running or not. That second route is what makes
the icon optional: it is the only way back in once **Show in menu bar** is off. **A launch macOS
makes on the user's behalf is not one of them**: started as a login item, the app comes up with no
window. On a first run the welcome window is shown instead, never both at once, and opening the app
again while it is up brings it forward rather than Settings.
**A reinstall is not one of them either**: `Scripts/install.sh` opens the bundle for its own reasons, so
it writes a marker under `~/Library/Application Support/SnappySnap/` first, and the launch that follows
reads it, removes it and opens no Settings window (`QuietLaunch`). **The welcome window is not silenced
by it**, deliberately: the launch a first install makes is the user's first sight of the app, and since
nothing asks for a permission at launch any more, that window is the only route to the one grant the app
needs — a marker that swallowed it would leave a fresh install inert with nothing on screen. A reinstall
has `onboardingCompleted` set already, so nothing opens there either. An update does the same before it quits (Updates, below):
the launch the helper makes is nobody's request either, and the only window it opens is the one saying
how the install ended. An unread install outcome says it a second way, which holds whatever version
wrote it: a launch that finds one is that install's, marker or no marker. It counts once and lapses after two minutes, so a marker left behind by an install
that died cannot silence a window the user asks for.

**Everything the window offers is below. Everything else is a
code constant** — one `static let` in `Settings.Fixed` with a comment saying what it does, not
reachable by `defaults write`. Settings are one JSON blob under `settings.v1`; any key the file does
not hold keeps its default, so adding or removing a control never resets the file.

**The window has eight pages, picked from a toolbar** that draws each page's symbol above its title —
*General*, *Snapping*, *Snap Bar*, *Handles*, *Custom Areas*, *System*, *Health*, *Tip* — and the window's
title is the shown page's. The window is **640 pt** wide and **as tall as the shown page**: it resizes around its
top-left corner, animated, on a page switch and whenever a page gains or loses a line, and never grows
past the display's visible height less **140 pt**, beyond which the page scrolls. It opens on General,
already at that page's height and centred.

| Page | Group | Control | Default |
|---|---|---|---|
| General | Startup | Launch at login | off |
| General | Startup | Show in menu bar | on |
| Snapping | Edges and corners | Drag to the left or right edge for a half | on |
| Snapping | Edges and corners | Drag to the top edge to fill the screen | on |
| Snapping | Edges and corners | Drag to a corner for a quarter | on |
| Snapping | ⌥ Option key | Hold ⌥ Option to snap to halves from anywhere | off |
| Snapping | Unsnapping | Restore a window's size when you drag it away | off |
| Snapping | Gap | Leave a gap around snapped windows | on |
| Snapping | Gap | Keep every window inside the gap | on (read only while the gap is on) |
| Snap Bar | Snap bar | Show the snap bar when dragging to the top | on |
| Snap Bar | Snap bar | Haptic feedback when it appears | on (needs the snap bar) |
| Snap Bar | Style | Notch or island · Floating bar · Notch or floating bar | Notch or island (needs the snap bar) |
| Snap Bar | Snap Assist | Suggest windows for the remaining spaces | on (needs the snap bar) |
| Snap Bar | Snap Assist | Animation — Smooth · Balanced · Battery | Balanced (needs the snap bar and Snap Assist) |
| Handles | Handles | Show handles between windows | on (governs the junction knobs too) |
| Handles | Smallest window sizes | Measure an app the first time you use a handle next to it | on |
| Handles | Apps | The list of window sizes — one row per application, built in, measured or edited, with **Add…**, **Remove** and **Reset** (§6) | the built-in list |
| Custom Areas | Custom areas | Hold ⌘ Command while dragging to use your own areas | on |
| System | Compatibility | Use hidden macOS features | on |

A control that *needs* a switch that is off is disabled, and its label is dimmed with it.

### How every page is built

**Every group is a title, a card of rows, and under the card — outside it — a hint, then warnings, then
notes.** A row is a control and its label and nothing else, so what a setting does is said once, under
its card. The **hint** says what the group does, in the secondary colour. A **warning** asks the user to
fix something: an orange line behind a triangle, there only while the thing is wrong. A **note** is the
one thing the user must not miss: a blue line behind an info mark. A group with nothing to say has none
of the three.

**A state is always one row**: what is reported on the left, in ordinary text, and at the trailing edge
a symbol and one word — or a short sentence, which wraps — both in the state's colour. There are five
marks and each keeps its symbol and its colour on every page: a **green checkmark** for what is as it
should be; a **blue info mark** for a reading with nothing to judge; an **orange triangle** for what is not as it should be while windows still
snap (an optional permission missing, a macOS switch that fights a feature, a feature switched on that
cannot work, something that did not work this time); a **red stop sign** for what stops windows from
snapping (the Accessibility permission denied, the drag detection down), and for text in front of the
user that does not parse; and a **spinner** for what is still happening.

**One colour rule holds on every page** (`SnapCore.HealthRules`, the same rule on System, on a feature
page and on Health): a grant the welcome window marks required is red while it is missing, an optional
one orange, and neither is ever blue. **Health holds what has to be in place or running for windows to
snap**, and another page shows the same state only as the context of what is there: beside the control
that changes it (a permission above its button, macOS's switches above the button to their pane, the
margins beside the gap switch, the hidden features' lines beside their switch, the custom areas'
verdict beside the editor).

**The copy has four rules.** Every text is the default size — body, bold for a group's title,
monospaced for what is code — and nothing is smaller. A keyboard key is written symbol first:
**⌥ Option**, **⌘ Command**. No sentence the user reads carries a dash other than the keyboard's
hyphen. And sentences are short, written for a person rather than for a developer, and say what a
switch costs wherever it costs something.

**No choice is a radio group.** The snap bar's *Style* is three picture tiles, each drawing what the
appearance comes to on a MacBook and on an external display — §4's table, from the same rule that
gives a real display its surface — and the hint under the group describes the selected one. Snap
Assist's *Animation* is a segmented control.

### What the pages say

**General opens with the app's icon**, 144 pt, centred, with nothing beside it.

Launch at login is read from and written to `SMAppService` only. A stored copy would be a second
source of truth that can disagree with System Settings. A registration the system refuses adds a row
under the two switches: the system's own message, marked **Failed** in orange. The Startup group's note
says that the app keeps working with its icon hidden, and names the way back to this window: the
Applications folder or Spotlight.

**Animation applies to the Snap Assist deck and to nothing else.** It is `Settings.smoothness`, the rate
the deck *asks* its cards to move at: Smooth aims at the display's refresh rate, Balanced at 60, Battery
at 30. Each card then follows as fast as its own application allows. A snap, a handle release and a
knob release always run at the display link's own rate.

**The Gap group reports macOS's own margins while the gap is on**: a row *macOS margins for tiled
windows*, green **Enabled** or orange **Disabled**. macOS applies its margins to the placements this app
does not own — a title bar double-clicked, the green button's tiling menu — so with them off those leave
a window flush against the screen edge while a snap leaves the gap. While the row is orange the group
adds a button to Desktop & Dock and a warning telling the user to also turn on *Tiled windows have
margins*; once it is green both are gone and the row stays. With the gap off the row is not shown.

**The Handles group's note is where the app says that holding Command (⌘) hides the pill
and the knobs so a window can be resized by its own edge** (§9 *Holding Command*). It is text and not
a control: the behaviour is always on, and there is nothing to switch.

**The Handles page holds §6's list, under the probe switch.** A row shows the application's name, its
width and height, and where the numbers came from — *Built in*, *Measured* or *Edited*; the bundle
identifier is the row's tooltip. The list follows the store live, so a row a window lowers while the
page is open changes as the user watches. Width and height commit on Return or when the field loses
focus; a value under 1 pt is refused and the field reverts. Add opens a sheet — a running application
with no row, or *Other…*, which shows an identifier and a name to type by hand, and both sizes — whose
Add button is enabled only for a complete, unlisted row. Remove takes the selected row, and with it
what that application's windows had shown and been asked this session; Reset is disabled while the list
already equals the built-in one.

**The Custom Areas page is the whole of §3 *Custom areas, held under Command***: the switch that governs
the feature, a monospaced editor holding the JSON, a status row, a **Verify** button, the displays
attached right now, and the example.

The editor stores on every keystroke like every other control, and macOS's smart quotes, dashes and
text replacement are switched off inside it, because what is typed there is code. With the feature
off the editor and Verify are **disabled rather than hidden**: the text is still the user's, and it is
still there when the feature comes back on.

**Verify runs when the button is pressed and when the page appears, and at no other time** — it does
not follow the typing, which would flash red at every half-written key. Its status row reports either
the number of areas the text defines, marked **Valid** in green, or one sentence naming the array index
and the key that failed, with the line and column for a syntax error, marked **Invalid** in red. The
configuration the drag reads is parsed separately, once per edit rather than once per event, so a text
that does not parse simply offers no areas.

The displays list gives each attached display's exact name and its frame in points, marking the
built-in one, and under them the two selectors exactly as the JSON takes them, so a selector can be
copied rather than guessed.

**The System page is what the app needs from macOS and the controls that give it.** The Accessibility
grant, **Granted** in green or **Denied** in red; while it is denied, a button to its pane and a warning
naming the switch, SnappySnap under *Device Control and Data Access* in Privacy & Security. macOS's
tiling: its edge tiling, **Disabled** in green or **Enabled** in orange; its margins, green when they
agree with the gap switch — on with the gap, off without — and orange otherwise; and its ⌥ tiling, *Hold
⌥ key while dragging windows to tile*, orange only while it is on together with the halves held under
⌥ Option. While any of the three is orange, a button to Desktop & Dock and one warning per orange row
naming the switch to flip. **Once a state is green its button and its warning go and the row stays**, so
the link stays visible. And under *Use hidden macOS features*, **one line per thing the private
symbols buy** — *Exact window matching*, *Pointer over the handles*, *Snap bar above other notch apps*,
*Blur behind the snap bar* — **Available** in green when `dlsym` found **every** symbol the feature
needs on this macOS, **Missing** in orange otherwise. A line reports the machine, not the switch, so
turning the switch off changes none of them. The symbols behind a line, their frameworks and whether
each was found are the line's tooltip, which is what a bug report is read from
(`docs/private-api-index.md`).

Its last group is **Start over**, whose one button, **Show Onboarding Again**, opens the welcome window
at page one. It is the only route back to it once the first run is over.

The code constants, for reference: edge band 24 pt, shared-edge band 48 pt, corner band 120 pt,
animation duration 0.25 s,
handle maximum gap 16 pt, handle minimum overlap 60 pt, deck ceiling 20 windows, gap 8 pt, fill on,
unprobed floor 120 × 80 pt.

Every change is written as it is made; there is no Apply. While the window is open it re-reads the
Accessibility and notification grants, the four tiling preferences, the login-item state and whether
the drag detection is running every 2 s. Those are readers only: nothing the window reads ever asks
macOS for anything.

### The Health page

**Whether SnappySnap works, at a glance.** The second to last page, between System and Tip, titled
*Health* (*Santé*) with a stethoscope. It is **two tables and nothing else**, and it reports and changes
nothing: a state is put right on the page that owns it. The app's version and its updates are not on it:
they are General's. Neither is a preference, whichever way it is set (the gap, the handles, the custom
areas, the hidden macOS features, the snap bar, Launch at login), nor the macOS version, the memory used
or how long the app has run.

**Health** (*Santé*) holds the checks, each one line, **green, orange or red and never blue**: what has
to be in place or running for windows to snap. Three are always there; every other one is a line only
while it is wrong, because it has nothing to say while it is fine. Under the lines, one button, **Check
Again**, which reads everything at once and shows a spinner beside itself for at least **0.5 s**
(`Settings.Fixed.healthMinimumBusy`), so the press is seen to do something. Under the card, while a line
is orange or red, the sentence that says how to put it right, each once. With everything gone wrong at
once the table holds nine lines, within the ten every app of the family is held to
(`HealthLimits.checks`).

| Line | When | Reads |
|---|---|---|
| Accessibility permission | always | **Granted** green; **Denied** red, "In Privacy & Security, turn on SnappySnap under “Device Control and Data Access”…" |
| Notifications permission | always | **Granted** green; **Denied** orange: never asked, the fix names Show Onboarding Again; refused, it names System Settings › Notifications › “Allow notifications” |
| Drag detection | always, once the permission is there | **Enabled** green; **Failed** red when the event tap could not be started once the permission arrived, or macOS keeps it switched off: quit and reopen. No line while the permission is still missing, whose own line is then the one red |
| Drags with fn held | only while it is wrong | **Failed** orange: the device-level listener could not be started (§3 *Arming*), so a drag made with fn held is not snapped |
| Drag detection pauses | only while it is wrong | orange once macOS paused the detection because the app answered too slowly (a drag may have been missed); the word is how many pauses since launch, the split the tooltip. A pause macOS makes for its own reasons is no line |
| Space tracking | only while it is wrong | **Failed** orange: §13's watcher is not running, so a gesture does not stand down on a Space change or Mission Control |
| macOS tiling | only while it is wrong | **Enabled** orange, one line, while “Drag windows to left or right edge of screen to tile” or “Drag windows to menu bar to fill screen” is on, or “Hold ⌥ key while dragging windows to tile” is on with the halves held under ⌥ Option: the fix names each switch that fights the drag. “Tiled windows have margins” is not on Health |
| Windows not put back | only while it is wrong | a count, orange: the windows Snap Assist could not deal home (§8), which the next launch puts back; **Invalid** orange when the record an earlier run left could not be read at launch, so those windows cannot be named: look for them in a corner of the screen |
| Crashes in the last 7 days | only while there is one | a count, orange, the last one's date as the tooltip, from `~/Library/Logs/DiagnosticReports`; the fix names Console's “Crash Reports” |

**Information** (*Informations*) holds two readings, blue:

| Line | Reads |
|---|---|
| Last snap | how long ago a window last landed where a snap put it (*12 s ago*, *3 min ago*), or **None yet**; the moment is the tooltip |
| Windows where a snap left them | how many windows on screen still sit (±2 pt) where a snap left them |

**When it reads.** The permissions, the tiling switches and whether the drag detection runs are the
window's 2 s poll, shared with System. The rest is read when the window opens on Health, when Health is
picked, and on Check Again, **never on a timer**: every one of those readings is a cheap local read (a
directory listing, one window list), taken on the main thread. The one setting a line is judged against,
the halves held under ⌥ Option, is read as it is.

### The welcome window

**The first run's window, and the only place in the app that asks macOS for anything.** Titled "Welcome
to SnappySnap", 540 pt wide, titled and closable and nothing more: the ordinary window level, the default
collection behaviour, not resizable and not minimizable. It opens on a launch where
`onboardingCompleted` is false, whatever the grants are, and it wins over the Settings window — a launch
never shows two. **A quiet launch does not silence it** (§14 above), because a first install's launch is
where the user meets the app; the one launch it does stand aside for is the one that reports how an
update's install ended. The app is activated once, as it opens, and never again from it. Afterwards,
Settings › System › Start over is the way back.

Four pages, one button at the bottom right, ⏎ Return on it:

1. **Drag a window to the edge. It snaps.** — the app icon, the headline with one word in the icon's red,
   what the app does in three lines, and three capsules: *Halves and quarters*, *Snap bar*, *Handles*.
2. **Permissions** — two rows. *Device Control and Data Access*, the name macOS gives the Accessibility
   grant, marked required with an orange triangle; and *Allow Notifications*, optional. Each row is a
   title, one grey line saying what the app can do with it, and a trailing control: an **Allow…** button,
   or **Granted** once it is there.
3. **Out of the way** — two optional rows. *macOS window tiling*, whose row is done once both of the
   system's switches are off and whose button opens Desktop & Dock; and *Open at Login*, which registers
   and unregisters `SMAppService.mainApp` from the app itself and shows **Turn Off** once on.
4. **All set** — where to find the menu-bar mark, and what to drag.

**The button reads Continue once the page's rule is met and Skip until then**: every required grant on
the permissions page, any one row on *Out of the way*. Nothing is compulsory; **Skip** walks on. The last
page's button says **Finish**, records `onboardingCompleted` and closes. **Closing the window any other
way records nothing**, so the wizard returns at the next launch.

**A button asks macOS and does nothing else.** It never opens a pane beside the dialog, and never instead
of it once a grant has been refused — a refused grant means the button does nothing visible, which is the
cost of never ambushing the user. macOS tiling is the one row with no dialog behind it, so there the pane
*is* the flow and the button says so.

**Nothing tells an app that a grant was made in System Settings**, so while the window is up it re-reads
every row every **2 s**. A grant that moves redraws that one row and nothing else; a row whose flow is
still running keeps its button, disabled, with a spinner beside it, and the poll leaves it alone.

**Who is in front.** The window stays where it is when a button hands over to System Settings or to a
system dialog — activating there is what drops it on top of what it just opened. It comes back when the
app it sent the user to quits, which macOS does for an ordinary app and not for this one. It orders front
when the app is activated, but only while no other window of the app is up, so it never lands on the
Settings window the user asked for. Opening the bundle again brings it forward rather than Settings.
Closing it gives the front back: with no window left, an accessory app that stayed active would swallow
the user's keystrokes.

### Updates

The second group of General, and **the only thing in the app that uses the network**. Its first row
is the running version — `CFBundleShortVersionString`, from the bundle — and its second a single
button, **Check for Updates**.

**The app also looks on its own**: once **10 s** after launch, then **a week** after the last check
that got an answer, whoever asked (`UpdateSchedule`). The question is put on a **30-minute** tick and
at every wake rather than on one week-long timer, so a Mac asleep on the date is asked as soon as it
is awake. A check that could not reach GitHub is silent and tried again at the first tick **an hour**
or more later, so 60 to 90 minutes on. Nothing is fetched or installed without a click.

Either kind of check asks `https://api.github.com/repos/bambidotexe/snappy-snap/releases/latest`,
anonymously, with a **15 s** timeout and the local cache bypassed, and the answer is the version
row's mark (`UpdatePanel`):

| The reply | The mark |
|---|---|
| while a press is in flight | a spinner and **Checking**, the button disabled so a second press cannot start a second request. An automatic check shows no spinner, and a press made while one is in flight adopts its answer |
| a release **strictly newer** than the running version, whoever asked | blue: **Version 1.2.0 is available**, and the button becomes **Update**, prominent and blue |
| a release equal to or older than it — or a running version that does not parse, which is any binary started outside its bundle — whoever asked | green: **Up to date** |
| 404, to a press | orange: **No release published yet**. GitHub answers 404 both for a repository with no release and for one it will not show an anonymous caller, and does not tell them apart. To an automatic check it is no news, and changes nothing |
| any other status, or a body that is not a release, to a press | orange: **Could not check: …**, carrying the status code or the reason. An automatic check that fails changes nothing |
| the last **Install and Relaunch** did not end with the new version running | orange: **Update failed: …** with the reason, until the next answer. The button checks, and is **Update** again once a check has found the release |

A release counts only if its tag parses as a dotted version — a leading `v` is allowed, a missing
trailing component is 0, and components compare as numbers, so 1.0.10 is newer than 1.0.9 — **and**
it carries an asset whose name ends in `.dmg`. A release failing either test is read as no release at all.

**An automatic check that finds a newer release posts one notification**, **Version 1.2.0 is
available**, with an **Update** button; a later check's notification replaces it. The button, and a
click on the notification itself, do what **Update** does in Settings. A notification left by an
earlier run asks GitHub first, then opens the update window on the answer, or Settings when nothing
is newer. The group has no hint.

**The update window.** **Update** opens one small window titled **Software Update** and starts
fetching at once: the app icon, **SnappySnap 1.2.0**, one status line, a bar, **Cancel** and
**Install and Relaunch**, which stays disabled until the update is ready. Pressing **Update** again,
anywhere, shows that same window (`UpdateSession`).

| Phase | The status line | The bar | The buttons |
|---|---|---|---|
| fetching | **Downloading: 1.2 MB of 2.8 MB**; **Downloading** when no total is known | follows the bytes | Cancel · Install and Relaunch, disabled |
| making it ready | **Preparing the update** | indeterminate | the same |
| ready | **Ready to install. SnappySnap will quit and reopen.** | full | Cancel · **Install and Relaunch** |
| it cannot replace itself | **SnappySnap cannot replace itself where it is installed. Open the disk image and drag SnappySnap to Applications, then quit and reopen it.** | none | Cancel · **Open Disk Image** |
| installing | **Installing** | indeterminate | both disabled; the window does not close |
| failed | **Update failed: …** | none | Close · **Try Again**, which fetches again |

Everything that can refuse an update happens while making it ready, with the app still running. The
fetched file, `~/Library/Application Support/SnappySnap/updates/SnappySnap-<version>.dmg`, is held
against the length and the SHA-256 GitHub states for the asset; the disk image is mounted read-only
and hidden; the app in it that carries SnappySnap's bundle identifier is copied to `updates/staged/`;
that copy must be **strictly newer** than the running version, ask for no newer macOS than this one,
and carry a valid signature **from the same team as the running app** (a running app with no team,
an ad-hoc build, only asks for a valid signature). The app cannot replace itself when it does not
run from an `.app`, runs translocated, cannot write to its folder or its bundle, or sits on another
volume than its Application Support folder; the window then offers the disk image, which macOS
mounts and shows with its Applications link. **Cancel** and the window's close button stop the fetch
and delete what was fetched.

**Install and Relaunch** starts a helper (`UpdateInstallScript`, a shell script in a process group of
its own) and quits the app the way the menu's **Quit** does, so every window Snap Assist has parked
is put back first. The helper touches nothing until the app is gone. If the app is still there **20 s**
after the click, it stops the helper, so that a quit that comes later is only ever a quit, and the
window says **SnappySnap did not quit. Close its open dialogs, then try again.** with the update still
ready; the helper's own limit, **30 s**, only serves an app too hung to do that. Once the app is gone
the helper moves the installed bundle to `updates/previous/`, moves the new one into its place (a
failed move puts the previous one back), writes the outcome, opens the app, and looks for the new
executable among the running processes for **15 s**, by the path it was installed at or by the one the
system knows that folder by. Seen, it looks once more **2 s** later: still there, or gone after having
read the outcome (the user quit it, which is their business), the previous copy is deleted. Gone
without that mark it is looked for again, for as long as the first look lasted, because an app that
hands itself to launchd quits so that the job's own copy can take its place and nothing runs in
between. Never seen, not openable, or still gone at the end of that second look (it crashed on its way
up), the new copy is moved out, the previous one moved back and opened. Nothing is ever deleted to
make room: when the previous copy cannot be moved back it stays in `updates/previous/`, and the
outcome says so.

The install also writes the quiet-launch marker before it quits, so the launch the helper makes opens
no window of its own (the start of §14).

The next launch reads the outcome, leaves `result.read` in its place for the helper, and says how it
ended in the update window, which is the whole news: after an install, **SnappySnap 1.2.0** and **The
update is installed. SnappySnap is running the new version.** with one button, **Done**; after a
failure, the version that is still running and **Version 1.2.0 was not installed.** followed by the
reason, with one button, **Close**, and the Updates group of Settings carries the same reason as its
orange mark. **Nothing else opens**: no Settings window behind it. The three reasons are **The new
version could not be put in place.**, **The new version did not start, so the previous one was put
back.** and **The new version did not start and the previous one could not be put back. Download
SnappySnap again.** An outcome older than **10 min** was left behind by an install nobody is waiting
on any more: it is logged and opens nothing. The Accessibility grant follows the code signature, which an update from the
same team keeps.

Every check, the fetch, the unpacking and the hand-over to the helper are logged to the `update`
category, at `notice`; the helper keeps its own account in `updates/install.log`.

### Supporting the app

**Tip** is a page of its own, the last one, after Health, and it holds two cards. The first has no
title: the app's icon beside the sentence saying every feature is free to everyone and always will be,
and that a coffee is how the project is supported. The second is **One-time tip**: the Ko-fi cup on a
wash of its own red, *A cup of coffee* with a line saying what it is, and a button naming the smallest
tip the page takes (`SupportLink.smallestTip`, 5 €). Under the card, one hint says the browser opens and
that any larger amount is typed on the page itself.

The button opens `https://ko-fi.com/bambidotexe` in the default browser and nothing else moves: the app
stores nothing about it, asks nothing back, pays nothing itself, and shows the page whatever the state
of anything else. The address and the amount are `SupportLink` in `SnapCore`, the same page for every
app of this author.

These two cards hold pictures and sentences rather than controls, which no other page does, and the
first has no title at all. The owner asked for that look; every other page keeps the rule that a row is
a control and its label and that nothing explanatory goes inside a card.

### Quitting

The last group of General is a single **Quit SnappySnap** button, styled as destructive, with no
hint and no note under it. It quits on the first press: there is no confirmation sheet, because
reopening the app is the whole of undoing it and a modal on an accessory app costs more than the
mistake it would prevent. It quits through `NSApplication.terminate`, exactly as the menu-bar item
does (§15), so the windows Snap Assist has parked are put back (§8) rather than stranded off-screen.

It is a button, not a setting: nothing about it is stored.

### Uninstalling

Under Quit sits **Uninstall**, one destructive **Uninstall SnappySnap** button under a hint, with an orange
warning that always stands there. The warning is not a state that can be put right but the hazard of the
other way out: **dragging the bundle to the Trash is not an uninstall.** It removes the app and nothing
else, and the entry in System Settings › General › Login Items goes on listing an app that is not there and
offering to start it, while the Accessibility grant stays in the privacy list, where a later build signed by
the same team inherits a decision nobody remembers making.

The button asks for confirmation, then, in this order:

1. resets the Accessibility grant, while the bundle it names is still where it names it (`tccutil reset`
   against a bundle identifier with no bundle behind it fails, and nothing puts that right afterwards);
2. unregisters the login item, and drops this app's entry from usernoted's own preferences so that the
   notification authorization goes back to "not asked yet", which no public API does: left behind, a
   reinstall inherits a decision the user made once about an app they have since removed;
3. moves the bundle to the Trash, not to a delete: what was just removed is still there to put back;
4. says what it could not remove, if anything, and quits through `NSApplication.terminate`, so every parked
   window is put back first (§8);
5. starts a detached helper for the preferences and `~/Library/Application Support/SnappySnap/`.

**Step 5 cannot be done by the app at all, and that was seen on a real uninstall.** The quit puts the parked
windows back and the stores that do it write into the preferences as it happens, and `cfprefsd` writes the
domain out again as the process exits whatever happens, leaving an empty plist where a Mac that never had
SnappySnap has no file at all. So the helper waits for the pid to go, for at most a minute, then deletes the
domain and removes the folder, the preferences file, the ByHost preferences, the caches, the HTTP storage and
the saved window state, all of which are named after the bundle identifier and belong to nothing else.

### What is stored

| Key | Holds |
|---|---|
| `settings.v1` | the seventeen stored settings above — every row of the table except Launch at login, which lives in `SMAppService`, and the list of window sizes, which has its own key below — as one JSON object; a key the file does not hold keeps its default, an unknown key is ignored, and a numeric `gap` from an older file is read as "on unless it was 0" |
| `customZones.v1` | the custom areas' JSON, **as the text the user wrote** — comments, spacing and all. Its own string key, not part of the blob above, because it is a document rather than a setting. Nothing stored yet reads as the default configuration; an empty string the user left is stored as empty and offers no areas |
| `minimumSizes.v3` | the list of window sizes (§6): this Mac's own rows and the removed built-in identifiers — **absent while the list equals the built-in one**. `minimumSizes.v2`, `minimumSizes.v1` and `knownMinimums.v1` are deleted on launch, never read |
| `parkedWindows.v1` | the windows Snap Assist has parked, for crash recovery (§8) |
| `onboardingCompleted` | the welcome window has been walked to its last page and finished. Not a setting: no control in the Settings window turns it on or off, and **only the last page's Finish writes it** — a window closed before that leaves it false, so the wizard comes back at the next launch |

Launch at login is in `SMAppService`, not here. A window's own floor is memory only.

## 15. The menu bar

A status item and nothing else. Its menu has **Settings…** and, under a separator, **Quit
SnappySnap**. There is no pause: a user who does not want snapping quits the app. The separator keeps
Quit apart from Settings so that a mis-click costs a gap.

**The item's icon is the app's own mark**, a snake, drawn from a vector PDF as a **template image**:
macOS recolours it, so it is dark on a light menu bar, light on a dark one, and inverted while the
menu is open. The image is **18 pt** square, the mark inside it **15.5 pt** tall and sitting **0.5 pt
below centre** — the artwork's own box leaves 14% padding on every side, and drawn to the full 18 the
mark reads small and pale beside neighbouring icons. Those two numbers are fitted by eye against a
real menu bar, not measured. If the PDF is missing from the resource bundle the item is created with
no image: an empty slot that still opens the menu, never a stand-in glyph that would pass for the
real one.

**Quit is offered twice**, here and as the last group of the Settings window's General page (§14). The icon's item
is the quick one; Settings' is the one that is still there when the icon is hidden. Both go through
`NSApplication.terminate`, so both put back whatever Snap Assist has parked (§8) on the way out.

**The item itself is optional.** With **Show in menu bar** off (§14) it is taken out of the menu bar
and the icons beside it close up; switching it back puts it there again. Either way it happens as the
switch moves, with no relaunch.

**Hiding the icon hides nothing else.** The event tap, every drag, the snap bar, Snap Assist, the
handle pill, the junction knobs and the oversize watcher all run exactly as they do with the icon
shown: the setting reaches the status item and nothing further. The app is an accessory with no Dock
icon either way, so with the icon off it is running and entirely invisible — which is why
**opening the app again is a route into Settings** (§14), and why the Startup group's note says so in
words. Settings is also the way out: the General page's last group quits the app, so hiding the icon never leaves a
running app with no way to stop it.

**The app icon** is the same snake, in colour, composed from a layered Icon Composer document and
compiled into the bundle at build time. An accessory app has no Dock icon, so it is seen in Finder,
in Spotlight, in the Accessibility list in System Settings, and on the alerts the app raises. A build made on a Mac with no Xcode has no app icon and is otherwise
identical: the bundle still names one, and macOS treats a named icon that is absent as no icon rather
than as an error.

## 16. Keyboard, pointer and modifiers

Every gesture is a left-button drag from the event tap; the trackpad counts. No keyboard shortcut
snaps a window.

**Command (⌘) and Option (⌥) are the two modifiers the app reads.** Command has exactly two meanings,
told apart by whether a window drag is in flight; Option has one, and only during a drag.

**Command with no drag in flight takes something away**: it hides the handle pill and the junction
knobs so that the window edge underneath can be resized by macOS itself (§9 *Holding Command*).

**Command during a confirmed window drag adds one**: it replaces the ordinary zones with the user's
custom areas (§3 *Custom areas, held under Command*). The two never collide — no pill or knob is
offered while a window is being dragged — and the drag meaning can be switched off in Settings, which
leaves Command with its first meaning alone.

**Option during a confirmed window drag grows the left and right edge bands until they meet at the
display's midpoint** (§3 *The halves, held under Option*), and takes the snap bar off the screen while
it is held. Outside a drag it means nothing. **Command outranks it**: while the custom areas are on
offer, Option is ignored.

No other key adds a gesture anywhere in the app. Snap Assist and the pair cell behave with either key
down exactly as they do without it.

Both are read from the event tap's own `flagsChanged` events, not inferred from the next mouse event,
because each must answer a key pressed with the pointer standing still — the handles because the poll
behind them stands still with the pointer, the drag session because the preview has to be repainted
where the pointer already is. **It is Command and Option and not fn**: holding fn and dragging is one
of macOS's own window-move gestures, so the key meant to uncover a resize edge moved the window
instead (`pitfalls.md` 45). fn is never read; the gesture it starts is followed like any other drag
(§3 *Arming*).

macOS has its own **"Hold ⌥ key while dragging windows to tile"**
(`com.apple.WindowManager` `EnableTilingOptionAccelerator`), which answers the same gesture. It is off
on the development Mac. With it on and the halves held under ⌥ Option switched on, both fire on the same
drag; Settings › System and Health report it in orange and name the switch (§14), and nothing stops it
(§20).

Besides Command the keyboard is read in two places: Escape ends a Snap Assist phase, and the menu-bar
item's items carry ⌘, and ⌘Q.

## 17. Which windows take part

A window is offered, snapped, paired or counted as occupying space only when the window list shows it
on screen at layer 0, owned by a regular (Dock-showing) application other than this one, at least
50 pt on each side and not fully transparent. Snap Assist and the pair cell also require the window
to be resizable and not minimized, through Accessibility; a drag arms only on a resizable window. A
window native full screen is never touched by the oversize watcher. Behaviour on a full-screen Space
is unconfirmed; the overlays carry `.fullScreenAuxiliary` and may appear there.

**A covering surface** is a window that takes no part in any of that and can still sit on top of a
handle: any other on-screen, not fully transparent window of another process **from layer 0 up to,
and not including, the Dock's layer (20)** — a menu-bar application's window, a floating panel (3), a
modal panel (8), a utility window (19). The pill and the junction knob treat one exactly as they
treat a participating window in front of them: a pill whose band it crosses is not shown, and a
crossing whose knob band it visibly covers has no knob. It is never snapped, paired, offered or
counted as occupying space. From the Dock's layer upwards nothing counts, because the window list
cannot tell a window that draws from one that does not, and that range is full of windows that cover
a whole display and draw almost nothing: the Dock's own, the menu bar, other applications'
click-through overlays.

## 18. Language

**The app speaks English and French, and macOS chooses.** It reads the system's preferred languages,
which macOS lets the user override for one app in System Settings › General › Language & Region ›
Applications. A Mac asking for French gets French; a Mac asking for anything else gets English. The
bundle declares both in `CFBundleLocalizations`, which is what puts the app in that per-app list.

**There is no language setting.** §14's window offers none: the app follows the system and nothing
else. Changing the language is quitting and reopening the app, because a catalogue is read once.

**Every sentence a person reads comes from a catalogue, and the English sentence is its key.** A call
site reads `L("Show in menu bar")`, so the sentence is still beside the thing it labels; `en.lproj`
maps each key to itself and `fr.lproj` to the French. A value inside a sentence is interpolated into
the key, so the French is free to put it where its own sentence needs it. Three catalogues, one per
target that shows text: **`SnapCore` 109 sentences, `SystemAdapters` 4, `SnappySnap` 184 — 297 in all.**
The Health page's words are `SnapCore`'s, because its lines are built there, and so are the System page's
states it shares with Health.

**A sentence with no French falls back to its English key, silently**, which is the one failure this
arrangement can have. `LocalizationTests` is what stops it reaching a build: it holds the two
catalogues of every target to exactly the same keys, fails on a sentence translated in one language
and not the other, reads every `L("…")` in the sources and fails on one its target's catalogue does not
hold, and fails on a catalogue sentence no call site shows any more.

**What is never translated**, in either direction: the app's own name; every log line; SF Symbol
names; the keys and raw values written to the settings file (`settings.v1`, `minimumSizes.v3` and the
rest, §14 *What is stored*); bundle identifiers, URLs and paths; the private symbols' own names
(`private-api-index.md`); and the custom areas' JSON example, its selector keys and its `kind` words
(§3). The sentences that report what is wrong with that JSON *are* translated; the JSON is not.

**§14's copy rules hold in both languages.** No sentence carries a dash other than the keyboard's
hyphen, in French either, where prose reaches for one constantly. A key is its symbol and then its
name at every mention, so ⌘ Command is **⌘ Commande**. A state's word stays one word: **Activé /
Désactivé**, **Disponible / Absent**, **Accordé / Refusé**. And macOS's own switches and panes are
quoted in curly quotes under the name **macOS itself gives them in the language being written**, so
the French names the French pane.

**The French vocabulary is fixed**, so a sentence added later reads like the ones beside it: snap is
*aimanter*, the snap bar is the *barre d'aimantation*, Snap Assist is the *assistant d'aimantation*,
a handle is a *poignée*, the gap is an *espacement*. The user is addressed as *vous*, everywhere.

**French is longer, and nothing is shrunk to fit.** A label wraps where the English did not and its
page is taller; the Settings window follows its page's height (§14), which is the whole answer. No
font is made smaller, no line is clipped and no sentence is abbreviated to save a wrap.

## 19. What the app deliberately does not do

No keyboard shortcuts, no Snap Groups, no Dock or App Switcher integration, no snap flyout on the
green button, no *graphical* layout editor — the snap bar's layouts are a hand-editable JSON file and
the custom areas are hand-written JSON in Settings (§3, §14) — no live thumbnails in Snap Assist, no
pause switch, no window of its own, no sandbox, no App Store, no Screen Recording, no network except its own update
(§14), and no update fetched or installed without a click. Nothing is resized while a handle or knob is dragged; the
windows move on release.

## 20. Known limitations and defects

- **The custom areas' editor switches macOS's smart substitutions off by walking the view hierarchy
  for the `NSTextView` inside SwiftUI's `TextEditor`.** There is no public way to ask for that view.
  A macOS that changes how `TextEditor` is built would leave the walk finding nothing, silently, and
  the editor would start turning `"` into a curly quote — which makes every configuration typed by
  hand fail to parse. The checklist's first editor row is what catches it.

- **A login-item launch is told apart from a hand-opened one by an Apple event, and that has not been
  seen.** §14's rule that starting as a login item opens no window rests on the open-application
  event carrying `keyAELaunchedAsLogInItem`; the development Mac has never launched the app that way,
  because Launch at login is off there. An event the check cannot recognise reads as opened by hand,
  so the failure it has is a Settings window at login, never a hidden app with no route in.

- **A drag suspended by a Space change whose mouse-up is lost stays suspended until the next press.**
  A `.up` can be lost to a Space change (`pitfalls.md` 26), and the drag session is event-driven with
  no poll of its own, so it cannot run the `OrphanDetector` rule the pill and the knob run. The press
  that follows ends it and arms normally, and logs `press while suspended`; until that press the
  session still counts as live, which keeps the oversize watcher standing down and the Space poll at
  60 Hz. Nothing is written and nothing is shown in the meantime (§13).
- **The system's own ⌥ tiling is reported, not prevented.** macOS's third switch,
  `EnableTilingOptionAccelerator` — "Hold ⌥ key while dragging windows to tile" — answers the same
  gesture as §3 *The halves, held under Option*. With both on, the two fight on the same drag; the app
  says so in orange on Settings › System and Health (§14), and cannot stop macOS from tiling. It has
  not been seen, because the key is off on the development Mac.
- **A one-sided axis is not re-fitted when an application refuses its size.** On an axis where every
  member takes the same side, a window that will not shrink to the frame it was given leaves the
  others where the drag put them, so their shared edge ends ragged by whatever the refuser kept. A
  two-sided axis still corrects itself (§10).
- **A drop preview cannot promise the landing for a window whose minimum has never been measured**
  (§7). The window lands larger than it was shown and the correction pass settles the arrangement a
  beat later. Where both the dragged window and the neighbour it asks for room refuse for the first
  time, the settling shows up to three moves; from then on both windows' floors are known and it is one.
- **Three or more columns whose minimums exceed the display** leave the last window starting beyond
  the right edge. macOS keeps a 40 × 91 pt sliver of any window on screen, so that sliver overlaps
  the window before it. No shipped layout has three columns.
- **A window left hanging past an edge that has another display beyond it has not been measured.**
  With separate Spaces a window is drawn on one display, which macOS chooses: a window *mostly* past
  the edge was measured being drawn on the far display (`pitfalls.md` 5), and an overhang that leaves
  most of the window on its own display has not been tried on two displays.
- **Several windows of one application move one at a time.** A cross of four Safari windows lands in
  visible steps; different applications overlap and are fine. This is Accessibility's floor and no
  arrangement of code changes it.
- **One visible blink** the first time a handle is pressed beside a window of an application that has
  no row, and one per card the deck probes. That is the minimum-size probe, and there is no other way
  to get the number.
- **A window can be grabbed while the deck is still dealing it back.** It ends at its recorded home,
  so it is not a stranding.
- **A press on a window with writes in flight arms no drag.** The press stops the animation; the next
  press works.
- **A press during the quarter second after a pill release is only half heard.** A press outside the
  pill's band while its two windows are still animating passes to the drag session, but the moves and
  the release that follow are swallowed by the pill until its animations report; the drag is dropped.
- **The event tap is not retried.** If it cannot be created after the grant arrives, the app is inert
  until relaunched; Settings › Health reads *Drag detection* **Failed** in red and says so.
- **The pair cell is resolved on the display the drag started on**, so a drag onto another display
  carries no pair cell there.
- **With eight or more cards in a Snap Assist area**, a card that changes line answers no clicks for
  about 220 ms after each pick.
- **An application whose size grain is coarser than twice the 12 pt rounding allowance** could still
  freeze one handle gesture.
- **The departure of a window released across a display seam (§3) has not been seen on two
  displays.** It is built from two measured facts — a window is drawn on one display at a time, and a
  surface across a seam is clipped there (`pitfalls.md` 5, 43) — on a Mac that had one display
  attached when it was written. The `drag` log names every snap it applies to.
- **An application that was not installed when the built-in list was measured is not on it.** It is
  measured once, at the first press or deck.
- **A row can be too low for an application's main window** once a smaller window of the same
  application — a compose window, a Get Info panel the user snapped — has been held and seen. The main
  window then refuses once per window and keeps its own floor; its preview under-shows it once. This
  is the direction §6 chooses on purpose: a row too low costs a correction, a row too high costs the
  user a trip to Settings.
- **A covering surface at or above the Dock's layer hides nothing** (§17): a widget an application
  floats at the status-bar level or higher still has the pill drawn over it.
- **The island is verified on external 1× displays only.** Its presence, its summon, its crossing
  between two displays and its place above a notch utility's island are measured there, the last on
  the primary display, which is the only one the utility drew on. It has never been seen at 2×, nor
  on a Mac whose own screen has no housing. Its expansion springs and its shadow are the notch
  shape's: a capture of the utility's island growing has not been measured.
- **The notch appearance's blur and spring are fitted by eye.** The shape and its shadow are fitted
  to measurements; the blur's strength and reach and the choice of spring are not, and neither is
  the luminance at which the outline appears.
- **The notch shape stays on screen through a Space change until the app hears of it.** On the
  private route it is on a Space of its own above the user's, so it does not leave with the Space it
  was shown on; it is faded out with every other surface when the change is reported (§13).
- **Multi-display behaviour is verified for edges, zones, the drop preview and the deck**, and for
  nothing else. Edges, zones and the preview were exercised on a three-display arrangement in a row —
  a 1512 × 982 built-in and two 2560 × 1440 externals, bottom aligned, so the externals reach 458 pt
  above the CG origin — which covered shared edges and their wider band, the zone resolved on the
  display the pointer is on, and the preview's departure rectangle across both seams. The deck was
  exercised on two 2560 × 1440 displays side by side: a phase on the left display fans into its
  bottom **left** corner and nothing whatever appears on the right one. What is written but still
  unverified: the bar and the pair cell per display; the dim over every display; a display change
  ending every gesture and every phase.
- **An overlay cannot be drawn across a display seam.** Displays have separate Spaces on this machine,
  so a panel is planted on one display's Space and clipped there; nothing this app shows spans two
  displays, and a surface whose geometry would is confined to one of them. `pitfalls.md` has the
  measurement and the approach that failed.
