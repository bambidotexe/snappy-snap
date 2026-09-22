# SnappySnap — manual test checklist

**This is the app target's only verification.** `swift test` covers `SnapCore` and `SystemAdapters`
(357 tests, two summary lines); `Sources/SnappySnap` — the controllers, the panels, the animations —
has no automated test, and everything below is what a person has to look at. About 30 minutes end to
end.

---

## Before you start (2 min)

```sh
cd ~/Projects/snappy-snap
swift run axprobe prefs          # EnableTilingByEdgeDrag and EnableTopTilingByEdgeDrag must be 0
Scripts/install.sh               # production build, notarized, into /Applications
```

In a second terminal, leave this running for the whole pass — several checks are log lines, not
pixels, and `log show` will not give them to you:

```sh
/usr/bin/log stream --predicate 'subsystem == "dev.rubens.SnappySnap"' --level debug
```

- [ ] The menu-bar item is there; its menu has **Settings…** and **Quit SnappySnap**, and nothing else.
- [ ] The item's icon is the **snake mark**, not an SF Symbol, and it holds its own beside the icons
      next to it — neither smaller nor paler. Open the menu: the mark **inverts** with the highlight.
      Switch the system appearance between light and dark: it follows, because it is a template image.
      An **empty** item that still opens its menu means `MenuBarMark.pdf` is missing from the bundle,
      and the log says so.
- [ ] `/Applications/SnappySnap.app` in Finder carries the **colour snake icon**, and it is the copy
      that is running (`ps -p $(pgrep -x SnappySnap) -o args=`). macOS caches icons hard, so a stale
      one here is the cache rather than the build — `ls /Applications/SnappySnap.app/Contents/Resources`
      shows `Assets.car` and `snappy-snap.icns` when the `actool` step ran.
- [ ] The Settings window came up by itself on this launch, frontmost. Close it, open SnappySnap
      again from Spotlight: it comes back, on the tab you left, with no second copy of the app.
- [ ] Settings › General › **Show in menu bar**, off: the icon goes as the checkbox moves, no
      relaunch, and the icons beside it close up. `menu bar icon hidden` in the log. On again puts it
      back, and `menu bar icon shown` prints.
- [ ] With the icon hidden, snap a window to an edge, to a corner and from the snap bar, and drag a
      handle pill. All unchanged — hiding the icon hides only the icon.
- [ ] With the icon hidden and Settings closed, open SnappySnap from Spotlight: Settings comes back.
      That is the only route in, so a failure here strands the app.
- [ ] With the icon hidden, quit and relaunch: the icon is still hidden and Settings still opens.
- [ ] ⌘W closes the Settings window and ⌘Q quits, with Settings key. Neither shortcut has a visible
      menu to come from — an accessory application's menus never reach the menu bar — so this is the
      only place they are checked.
- [ ] `engine started` in the log (it prints at launch, so start the stream and relaunch if you missed it).
- [ ] Settings › Accessibility shows the grant, and macOS window tiling shows no conflict.

Open at least **Finder**, **Safari or Chrome**, **TextEdit** and **Terminal**, unmaximised.

---

## 1. Drag to an edge (3 min)

| | Do this | Expect |
|---|---|---|
| [ ] | Drag a Finder window until the pointer is ~20 pt from the **left** edge | The preview appears **morphing out of the window's own frame**, not popping in. Drop: the window animates to the left half, 8 pt from the screen edges |
| [ ] | The same to the **right** edge, with a browser | Right half, same 8 pt |
| [ ] | Drag to each of the **four corners** | A quarter each time. The corner beats the side: 120 pt from the end of an edge is corner, further along is half |
| [ ] | Drag to the **top** edge and hold | The preview covers the whole working area **at once**. The snap bar follows a beat later — 125 ms of holding the band, not on the same event |
| [ ] | **Flick** a window up to the top edge and drop it in one quick motion | Fill, with **no bar at all** on the way. Not even a flash |
| [ ] | Arm the left edge, then pull the pointer slowly **away** | The zone survives about 12 pt past where it armed, then releases cleanly. No flicker at the boundary |
| [ ] | **Flick** a window at an edge and release fast | It still snaps. No preview flash at the moment of release |
| [ ] | Grab a window by its **left or top resize border** and drag | Nothing arms. Log: `resize gesture … not a move; ignoring` |
| [ ] | Grab a window mid-animation | The animation stops where it is. The press itself arms nothing; release and press again and the drag works |
| [ ] | Hold **fn**, press in the **middle** of a window and drag it to the left edge; repeat to the top, and once more pressing ⌘ part-way, with fn still held and with fn let go | macOS moves the window and SnappySnap follows it as any drag: the preview, the snap bar, the custom areas under ⌘, and the snap on release. Log: `drag confirmed` |
| [ ] | Drag **Affinity** by its title and tab strip — several places along it, not only the very top row | It snaps from every one of them. (Its strip answers Accessibility's hit test with an error; the window list names the window instead. A press that finds nothing logs `no window under it`) |

## 1b. Custom areas, held under Command (5 min)

Settings → **Custom areas**. Leave the configuration at its default for the first three rows, then
paste the one below, which overlaps on purpose.

```json
[
  { "*": { "anchor": "center",      "size": { "widthPercent": 0.5,  "heightPercent": 0.5 } } },
  { "*": { "anchor": "bottom-left", "size": { "widthPercent": 0.66, "heightPercent": 0.4 } } },
  { "*": { "anchor": "top-left",    "size": { "widthPercent": 0.66, "heightPercent": 1.0 } } },
  { "*": { "anchor": "top-right",   "size": { "widthPercent": 0.34, "heightPercent": 1.0 } } }
]
```

| | Do this | Expect |
|---|---|---|
| [ ] | Drag a window, then **press ⌘** and hold | The zone preview and the snap bar go at the keystroke, not at the next mouse move. The custom areas appear |
| [ ] | Look at an area the pointer is **not** in | It is the ordinary drop preview in full — same corner radius, same stroke, same shadow, **and a fill**. Not an empty outline |
| [ ] | Move the pointer between two areas | Only the **fill's opacity** changes. Nothing scales, glows, moves or re-strokes |
| [ ] | Release the mouse with ⌘ held | The window animates into the filled area over the usual 0.25 s |
| [ ] | Paste the overlapping configuration. Hover the **middle** | The centre area fills, not the left two-thirds it sits inside: the first in the list wins |
| [ ] | Hold ⌘ and release over a **gap** between areas | Nothing is placed. The window stays exactly where the drag left it — it does **not** fall back to an edge zone |
| [ ] | Hold ⌘, then **let go of ⌘** with the drag still live | The areas go and the snap bar and edge zones come back **from where the pointer stands**, without moving the mouse |
| [ ] | Press ⌘ **before** starting to drag, then drag | The areas appear as soon as the drag confirms |
| [ ] | Turn the switch at the top of the page **off**, then drag with ⌘ held | Nothing changes about the drag: ordinary zones throughout. The editor and Verify go grey but keep the text |
| [ ] | Turn it back on | The text is exactly as it was, comments included |
| [ ] | Flick between the **Settings** tab and this one, watching the switch | The same control in both: a switch on the trailing edge, same row height and margins, the grey line wrapping the same way. Not a checkbox (`pitfalls.md` 47) |

### The editor (3 min)

| | Do this | Expect |
|---|---|---|
| [ ] | Type a `"` in the editor | A straight quote. **Not** a curly one — smart substitution is off, or every configuration typed by hand is broken |
| [ ] | Add `// a note` above a key and press **Verify** | Green, with the number of areas. Comments are allowed wherever whitespace is |
| [ ] | Wrap two elements in `/* … */` across several lines | Green, with the count reduced accordingly |
| [ ] | Put a syntax error **below** a long block comment | Red, naming the error's **own** line — the comment must not shift the count |
| [ ] | Open `/*` and never close it | Red, saying the comment is never closed, pointing at the opening |
| [ ] | Misspell a key, e.g. `"screenname:x"` | Red, saying it is not a screen selector, naming the array index and the key |
| [ ] | Quit Settings and reopen the page | Verify runs on its own, and the text is byte-for-byte what you typed, comments and spacing included |
| [ ] | Read the **Displays attached now** list | Each display's exact name and frame in points, with the built-in one marked. Copying a name into `screenName:` matches |
| [ ] | `screenName:built-in` on the laptop panel | Claims it, even though its name is "Built-in Retina Display" — the token asks macOS, not the name |

## 1c. The halves, held under Option (3 min)

Settings › Snapping › **⌥ Option key** → *Hold ⌥ Option to snap to halves from anywhere*. It is
**off by default**, so switch it on first; the first row checks that it was.

| | Do this | Expect |
|---|---|---|
| [ ] | With the switch **off**, drag a window to the middle of the screen and hold ⌥ | Nothing arms. Option means nothing to a drag until the switch is on |
| [ ] | Switch it on. Drag a window anywhere in the left half of the screen and hold ⌥ | The **left half** preview, however far from the edge the pointer stands |
| [ ] | Keep ⌥ held and move across to the right of centre | The **right half**. Nothing else on screen changes |
| [ ] | Park the pointer on the centre line and nudge it one point each way, repeatedly | It flips **every time, both directions**. No overshoot to leave, no overshoot to come back — the centre line is the one boundary in the app with no hysteresis |
| [ ] | ⌥ held, pointer ~300 pt in from the left edge and ~60 pt down | The **left half**, not a quarter. Corners keep their own narrow band and nothing wider |
| [ ] | ⌥ held, pointer hard into the top-left corner (within 24 pt of the left edge, 120 pt down) | The **top-left quarter**, exactly as without ⌥ |
| [ ] | ⌥ held, pointer in the top 24 pt, away from either end | **Fill**, exactly as without ⌥. Under ⌥ the top band is resolved ahead of the halves, which would otherwise swallow it |
| [ ] | ⌥ held, anywhere | **No snap bar and no island** — nothing at all at the top of the screen, whatever the appearance; an island that was up leaves through its departure |
| [ ] | Release ⌥ **without moving the mouse** | The bar and the pill come back and the ordinary narrow bands are back with them, resolved from where the pointer already stands. In the middle of the screen that means the preview goes |
| [ ] | Hold ⌘ as well as ⌥ | The **custom areas**, exactly as §1b. Command outranks Option |
| [ ] | Switch the feature off in Settings with ⌥ still held, then move the pointer | The grown halves go on that move. No key event announces a switch |
| [ ] | Switch *Drag to the left or right edge for a half* off, with the Option switch still on | ⌥ does nothing. It grows a band that is switched off |
| [ ] | Without ⌥: arm the left edge, pull the pointer slowly away | Still survives ~12 pt past where it armed. Option took the hysteresis off the **centre line only** |

## 2. A drop on an edge: what is free, and who gives room (5 min)

This is what stops a snap leaving a hole beside a window that is already there, and what stops it
overlapping one. Keep `log stream … --level debug` open on the `drag` category.

| | Do this | Expect |
|---|---|---|
| [ ] | Snap a window to the **right** half, drag its handle to make it about a third, then snap another to the **left** half | The left window takes **two-thirds**, stopping one gap short of the other. No hole. Log: `took what is free: window … is offered W×H … for a … cell` |
| [ ] | Snap a window left, **drag its handle** to make it a third, then snap a third window right | It takes the remaining **two-thirds**, from where the divider actually is |
| [ ] | Push a window up **under the menu bar**, in the middle of the screen, touching nothing else, and snap another to the right half | The plain half. A window standing against one side of the screen is not a neighbour. Log (debug): `window … does not stand beside this drop: it stands against 1 side(s) …` |
| [ ] | Put a window **floating in the middle** of the screen (touching no edge) and snap another to the left half | The plain half, unchanged. A floating window moves nothing — and the snapped one may overlap it |
| [ ] | Snap a window to the left third, then **cover it entirely** with another, larger window placed by hand, and snap a third window to the right half | The plain half. A window nobody can see moves no divider. Log (debug): `… only 0 % of it is visible` |
| [ ] | Put a **short** window (a quarter of the screen tall) at the bottom right corner, snap to the left half | The plain half. A window that owns less than half the zone's rows says nothing about its width |
| [ ] | Make a 2 × 2 of four windows, close the top-right one, shrink the top-left one's width and the bottom-right one's height with their handles, then snap a window to the **top-right corner** | It grows across *or* down, whichever gives the larger frame — never both, and never into the bottom-left window |
| [ ] | Nothing else on the display at all, snap left | The plain half |
| [ ] | Snap a window to the **right half**, then drag its right border out until it is **flush with the screen's edge** (no gap), and drag another window to the **top edge** | The whole working area. A top drop is a maximize whatever stands there: the preview covers the screen, the flush window is covered and **does not move**. Never the left half |
| [ ] | Snap an application with a **large minimum width** (wider than half your display) beside a snapped window | The divider moves: the neighbour gives exactly what was needed, and both animate together. Log: `window … needs more than is free: neighbour … gives W×H pt …` |
| [ ] | The same with an application that has **no row** (remove its row in Settings › Handles › Apps first) | The window lands larger than the preview showed, and a beat later the neighbour gives room. Log: `… was asked W×H and took W×H; solving the arrangement again`. Repeat the drop: one move, and the preview is right |
| [ ] | Two applications with large minimums whose widths **cannot both fit**: snap one right, then the other left | No overlap. The left window takes its minimum from the left edge and the right one is **pushed right, partly off the display**. Log: `minimums do not fit: … runs W×H pt past the right/bottom edge` |
| [ ] | After that last row, wait a few seconds | The oversize watcher leaves the overhanging window alone: it is not wider than the screen |
| [ ] | With the gap on, zoom a **Terminal** window (double-click its title bar) and wait a second | It comes back inside the gap and stays there: its bottom edge is at or above the other windows', never below. Log: `window … rounded W×H up to W×H; asking for W×H so it rounds inside the gap` |
| [ ] | Move that Terminal window somewhere else by its title bar | It stays where it was dropped. It does not slide back to the top |

## 3. The snap bar and the pair cell (3 min)

| | Do this | Expect |
|---|---|---|
| [ ] | Drag to the top edge and look at the three bands | Menu bar → preview stroke, and preview stroke → bar, are **equal** |
| [ ] | Dip out of the band and back in, faster than twice in a quarter second | The bar waits the full 125 ms from the **last** entry. It never arrives early on the strength of the first |
| [ ] | Hold still in the band until the bar arrives, without moving the mouse | It still arrives — no event is needed — and the cell under the pointer is **already highlighted** when it does |
| [ ] | Let the bar come up, then leave the band and come back | The wait runs again. Every arming within one drag has its own 125 ms |
| [ ] | **Dragging with the trackpad**, arm the bar and feel for the tap | One light tap at the instant the bar appears, not when the band is entered. Arm again in the same drag and it taps again |
| [ ] | Sweep fast across the band without pausing, still on the trackpad | No bar and **no tap**. The tap can never arrive without the bar |
| [ ] | Settings › Snap Bar › *Haptic feedback when it appears* → off, then arm the bar | Nothing is felt; the bar is unchanged. `log stream … --level debug`, category `drag`, prints `haptic off` beside `snap bar summoned` |
| [ ] | Turn the snap bar itself off | The haptic row greys out with the Style tiles and the two Snap Assist rows |
| [ ] | Count the cells | A **pair cell** first (two halves), then halves, two-thirds/one-third, left-half-plus-two-quarters, 2×2 |
| [ ] | Read the pair cell's two icons, dragging a window whose app differs from the partner's | The **dragged** app's icon on the left, the **partner's** on the right — same size, same height, one per half |
| [ ] | Travel down into the bar and along it | The bar stays up the whole way in, and while you slide off either end by less than 16 pt |
| [ ] | Hover each area of each layout | The desktop preview follows exactly, gap included |
| [ ] | Sweep **slowly** across a cell, through the seam between two zones, and along the cell's outer rim | One zone hands straight to the next. Nothing ever goes dark inside a cell — not on the seam, not on the rim, not on the 2×2's centre corner |
| [ ] | Sweep on across the **8 pt spacing** to the next cell | Here it *does* go dark, for those 8 pt: that space is Fill and stays Fill |
| [ ] | Hover the pair cell, including the **gap down its middle** | **Both** halves light at once and stay lit crossing the middle. No flicker, no replayed animation |
| [ ] | Drop on the pair cell | **Two** windows land: yours left, the partner right |
| [ ] | Drop on the bar's **background** | Fill |
| [ ] | Close every window but one, then drag to the top | The pair cell is **absent** and the bar is one cell narrower |
| [ ] | Bring the bar up over a **busy wallpaper**, and again over a plain window | The bar is **real Liquid Glass**: what is behind it refracts and moves as the bar does, with a specular edge. A flat evenly-tinted pane means it has lost key |
| [ ] | While the bar is up, watch the window you are dragging and the drag itself | The drag continues normally and drops where you aim. The bar taking key must not interrupt it or hand the window to anyone else |
| [ ] | Leave the band so the bar goes, then finish the drag | Focus is where you left it. No window is left looking active that is not |
| [ ] | Look closely at a cell's **outer corner** — the 2×2 is clearest | The zone's curve runs **parallel** to the cell's, an even rim the whole way round the bend. Each 2×2 zone rounds wide at exactly one corner, the outward one, and stays tight at the three facing a seam |
| [ ] | Look at the **pair cell's** outer corners | Same rule: wide on the two outer sides, tight down the middle seam |

### The notch appearance (4 min)

Settings › Snap Bar › Style → **Notch or island**. Everything in the table above still holds for the
cells; this table is what the appearance adds. Have a notch utility running if you use one, with
something playing, so its own shape is showing.

| | Do this | Expect |
|---|---|---|
| [ ] | Drag a window to the top edge **away** from the notch | The Fill preview, and **no bar** |
| [ ] | Sweep the pointer **across** the housing without stopping | Nothing grows. The shape is only for a pointer that stays |
| [ ] | Drag into the notch and hold | After 125 ms a black shape **grows out of it and bounces once**; the cells fade in as it settles. The top corners flow out of the screen's edge, the bottom ones are round |
| [ ] | With the shape open, look at the black around the cell row | The cells **hang from the bottom of the physical notch** — no gap above the row — and the margin is the same 20 pt on the left, on the right and below |
| [ ] | Look at the cells themselves | **Opaque**, not translucent: no black shows through a zone. The outline is darker than the zones, so a layout reads as light windows in a darker display rather than one bright slab |
| [ ] | Watch the zone preview while the shape opens and closes | As smooth as it is without the shape. A stutter here is a main-thread regression under the shape |
| [ ] | Look around the shape over a text-heavy window | The text is **blurred, not tinted**: strongest at the shape's edge, gone about 60 pt out. One soft shadow. No grey frame and no glow |
| [ ] | Look at the top corners while it opens and closes, over something **dark** | A faint outline along the shape's edge and the curve of each flare. **No** hairline down the body's edge beside a flare, **none** along the top of the screen |
| [ ] | Move it over something **light** | The outline fades out within a fifth of a second |
| [ ] | With the other utility showing an activity, open the shape | Ours **covers** it completely; theirs is back, untouched, once ours has closed. Check with `swift run axprobe windows` during the drag: SnappySnap's 772 × 226 panel lists **first** |
| [ ] | Drag down into the cells, and off any side by less than 16 pt | It stays open; further, it **returns into the notch without dipping below it** |
| [ ] | Drop on a cell, on the pair cell, and on the black outside the cells | A snap and Snap Assist, two windows, and Fill — exactly as from the floating bar |
| [ ] | Settings › System › Compatibility, turn **Use hidden macOS features** off, and drag again — no relaunch | The same shape, spring and shadow; **no blur**, a constant faint outline, and the shape now draws *under* the other utility. Plainer, never broken |
| [ ] | Turn it back on, and switch the appearance back to **Floating bar** | Both take effect on the next drag; the floating bar is exactly as it was |

## 4. Snap Assist and the deck (5 min)

| | Do this | Expect |
|---|---|---|
| [ ] | Drop a window on a **2×2 cell** from the snap bar | The other three areas appear **at once**, each with a card per other window. The windows they cleared are **dealt into the bottom-right corner**, staggered, each leaving a small sliver |
| [ ] | Click a card | That window **flies out of the deck** into that area. Its card fades out of the other areas and the remaining cards slide — they do not jump |
| [ ] | Fill every area | The phase ends; the last window ends up frontmost; every deck card is back at its exact original frame |
| [ ] | Start again, then click a **surface between the cards** | The whole phase cancels and every parked window comes home |
| [ ] | Start again, pick one card, then press **Escape** | The phase ends. The one you placed **stays placed**; the rest come home |
| [ ] | With a window already snapped to the right half, drop another into the bar's **two-thirds** cell | It takes the full two-thirds — a drop from the bar looks at nothing that was on screen — and the area offered beside it is the remaining third |
| [ ] | Drop an application with a **large minimum width** into the bar's left half | It lands wider than half; the area offered on the right is **what is left**, and a pick lands there without overlapping |
| [ ] | Drop a small window into the left half, then pick an application with a **large minimum width** for the right | The first window **gives room**: it is re-fitted narrower in the same motion, the picked one takes its minimum, nothing overlaps and nothing leaves the display |
| [ ] | In a 2 × 2, pick an application with a large minimum for the top-left | The divider moves for the **whole grid**: the areas still open slide and resize with their cards, and a click on a moving area does nothing rather than ending the phase |
| [ ] | Drop a window that refuses to **grow** (System Settings) into the bar's left half | It lands at its own width; the area offered on the right takes everything it left |
| [ ] | Drop an application whose minimum is nearly the **whole display** into the left half | No area is offered and no phase starts. Log (`assist`): `no cell of … is left on the display; no choosing phase` |
| [ ] | Watch the deck deal with ten or so windows open, one of them Safari | **Every** card animates into the corner, none teleports below the ceiling of 20. A dear window may lag the others and still arrive exactly in its slot |
| [ ] | Read the deck's log line at the end of each deal (category `deck`) | `deck <label>: N cards, F frames, P posts, S superseded, slowest <pid> … ms`. `never arrived` should be **0** |
| [ ] | Drop on a **2×2 cell** with a wallpaper that is bright in one half and dark in the other | **Every** area's cards are true Liquid Glass — refractive, with a specular edge — not one glassy and the rest flat. They look the same over the bright half as over the dark one. This is the key-window rule (`pitfalls.md` 44); a single flat area means the surfaces have gone back to one panel each |
| [ ] | Move the pointer slowly onto a card, hold, then off it | The card's glass tints white and fades back over about an eighth of a second. No border, no fill, no growth, and the card does not move |
| [ ] | Move the pointer across the gap between two cards, and across a card that is still sliding after a pick | Nothing lights up in either case: no card is claimed in a gap, and none while the reflow could be drawing two of them over the same point |
| [ ] | Read a card's title over a busy wallpaper | Legible: a black gradient sits under the labels, strongest at the card's bottom edge and gone by the icon |
| [ ] | Start a phase and click the desktop **outside every area** | The phase ends and the click goes no further — the window under the pointer is not activated and nothing in it is clicked |
| [ ] | Drag a window to a plain **edge**, and separately drop on the **pair cell** | **No** Snap Assist in either case |
| [ ] | Start a phase, `kill -9 $(pgrep SnappySnap)` **while the cards are still moving**, then `Scripts/run.sh` | `putting N window(s) back` in the log, and **every** window ends at its original frame. This is the one promise the deck must not break |
| [ ] | Start a phase and **switch Space** mid-deal | Every window comes home, and nothing of ours is visible on the new Space |

## 5. The handle pill (4 min)

| | Do this | Expect |
|---|---|---|
| [ ] | With two halves snapped, open a **floating widget of a menu-bar application** over the gap (Vorssaint's Brouillon, ⌃⌥⌘B) and hover the gap | **No pill and no knob** anywhere the widget crosses their band — nothing of SnappySnap's is drawn over the widget. Log: `pair … occluded by …`. Close the widget and hover again: the pill is back |
| [ ] | Snap **Terminal** beside another window, drag the pill a few times to arbitrary places and release | Terminal lands on whole character cells, a few points off the ask, and **no floor is raised from it**: log `within what an application rounds by; no minimum learned`, never `its own floor is now` for Terminal. The divider still goes as small as it did before |
| [ ] | Snap two windows to left and right halves, hover the gap | A small pill in the shared overlay shape colour — **#E6E6E6 in Light, #CFCFCF in Dark** — **4 pt thick and about 48 pt long**, centred on the overlap. It fades in and does not flicker as you move along the gap |
| [ ] | With a pill on screen, switch System Settings → Appearance between **Light** and **Dark**, without relaunching | The pill changes colour **on the switch**, with no relaunch and no second hover. Repeat over a **knob** and over a **drop preview**: all three change together |
| [ ] | Put a pill, a knob and a drop preview on screen in turn in the **same** appearance, and compare them | All three are **exactly the same colour** — the pill, the knob and the preview's stroke share one constant and may never disagree. This is the rule; two of them matching and the third not is the defect to look for |
| [ ] | Drag a preview across a **very dark** and a **very pale** part of the desktop, in Dark | The stroke does **not** change — it is opaque on purpose. It will not track macOS's own preview at those two extremes, which is by design and not a defect (`pitfalls.md` 46) |
| [ ] | Press the pill beside a window of an application with **no row** (remove its row first) | **One visible blink**: that window flickers to tiny and back. It is the minimum-size probe, and the row is made from it: log `it is now the row for …`. Press again, and press beside a **second window of the same application** — no blink either time |
| [ ] | Drag the pill | **Nothing resizes.** The pill and one **preview rectangle per window** follow the pointer smoothly, and the rest of the screen **dims** — including the **menu bar and the Dock**. The gap between the two previews is the standard gap |
| [ ] | Keep dragging past the point where one window cannot shrink further | The divider, the pill **and both previews stop** while your pointer keeps going. Come back and they **re-engage without a jump** |
| [ ] | Watch the pill against the previews while dragging slowly | The pill stays exactly on the centre of the gap the previews leave. No sawtooth, no sub-point drift |
| [ ] | Release | Both windows animate to the previews' frames, the shrinking one first. The previews and the dim go at the mouse-up |
| [ ] | Press and release **without moving** | Nothing happens at all |
| [ ] | Do the whole thing with **two Terminal windows** | Terminal snaps to a character grid, so it lands a few points off what was asked. The pair must not end **overlapping**: the neighbour is re-fitted against where Terminal really went |
| [ ] | Stack two windows top and bottom | The same, horizontally |
| [ ] | Put a **third window in front** of the gap | No pill |
| [ ] | Put a third window **behind** both, with an identical frame | The pill is still offered |
| [ ] | Place two windows ~20 pt apart by hand | No pill — the maximum gap is 16 pt and is not a setting |
| [ ] | Let go of the button somewhere unusual — outside the band, during a Space change | The drag ends. It never continues with the button up, and it never writes what it was not asked for |
| [ ] | Watch the log through a pill drag | **Zero** `event tap disabled` lines, and no Accessibility per event |
| [ ] | Hover a pill, then **hold ⌘ without moving the pointer** | The pill goes **at once** — no fade, and without waiting for you to move the mouse. Nothing else on screen changes |
| [ ] | With ⌘ still held, press and drag on that same divider | macOS's **own resize** of the one window under the pointer. No pill, no previews, no dim |
| [ ] | Release ⌘ and hover the gap again | The pill fades back in as usual. No lost state, no double pill |
| [ ] | Start a real pill drag, then **press ⌘ in the middle of it** | **Nothing changes.** The previews keep following, the dim stays, and the release lands both windows exactly as it would have |
| [ ] | Hold ⌘ and hover along a gap that has no pill yet | No pill is ever offered while ⌘ is down |

## 6. The junction knob (4 min)

| | Do this | Expect |
|---|---|---|
| [ ] | Make a **2×2** and hover the centre | A round **knob** replaces the two pills, centred on the crossing — at the default gap it overlaps each side by about 2 pt, which is deliberate |
| [ ] | Drag it diagonally | A preview per window follows, and one axis stopping at a minimum does not stop the other |
| [ ] | **Make a T** — one window full height beside two stacked — and hover the junction | A knob **4.5 pt to the side of the crossing, away from the full-height window**: out in the gap the two stacked ones leave, visibly clear of the tall window's edge rather than resting against it. Dragging across the through-divider moves all three; the other axis moves only the two on its side |
| [ ] | **Rotate that T** — one window full width across the top, two side by side under it | The knob is pushed **downwards** off the crossing by the same amount. Check the other two orientations too: always away from the window the divider runs through |
| [ ] | Press that T's knob and drag it around, then release | The disc does not jump at the press or the release, keeps the same offset for the whole drag, and is grabbed where it is drawn — press on the disc itself, not on the crossing beside it |
| [ ] | **Make an L** — three windows, fourth quadrant empty desktop — and hover the corner | A knob, **exactly on** the corner: only a T is pushed. Both axes move all three windows; nothing grows into the empty quadrant that was not already facing it |
| [ ] | **Two windows corner to corner diagonally**, the other two quadrants empty | A knob at the single corner they share. Both axes resize both windows |
| [ ] | **A plain left-half / right-half split.** Hover the **top** of the gap, then the **bottom** | A knob at each end, both on the screen's own edge. The pill still owns everything between them |
| [ ] | Drag the top knob **upwards**, hard | The previews stop 8 pt below the menu bar and go no further. The same downwards, against the Dock, and sideways on a stacked pair |
| [ ] | **Press a knob at a divider's end and release without moving** | Nothing moves at all. No window shifts by a few points on either axis |
| [ ] | Drag a knob at a divider's end and watch the moment the button goes down and comes up | The disc does not jump at either, and it tracks the pointer on **both** axes |
| [ ] | Settings → turn the **gap off**, then repeat the drag against the menu bar | The windows stop flush against the working area instead of 8 pt short |
| [ ] | Two windows stacked exactly on top of each other, same size | **No** knob at any of their corners — corners pointing the same way are not a crossing |
| [ ] | Make a cross of **four windows of one application** and release it | Visible steps, about five frames per window. One application serialises its own Accessibility calls; this is the floor, not a fault |
| [ ] | Hover a knob, then **hold ⌘** | The knob goes at once, like the pill, and a press there reaches the window corner underneath. Press ⌘ during a live knob drag: nothing changes, and the release still moves every member |

### When a knob does not appear, and how to diagnose it

With the arrangement on screen and the pointer moving — the poll stands down after 2 s without a
mouse move, and verdicts are logged only when they change — read the **`junction`** category at
`--level debug`. One of four things will be there, and each names its own cause:

- `accepted junction of N at (x,y)` (or `accepted T of N` when a divider runs through a member) — the
  crossing **is** found, so the fault is downstream of the detector: the hover, the precedence against
  the pill, or the panel.
- `rejected at (x,y): N member(s) at the crossing, need 2, 3 or 4: <ids and roles>` — occupancy. One
  member usually means two corners pointing the same way; the ids say which window survived.
- `rejected at (x,y): more than one member spans a divider: <ids and roles>` — two windows each run
  past a whole divider with nobody at the crossing itself.
- `rejected at (x,y): covered by window <id> (pid <pid>)` — something is lying across the 24 pt band.
- **Nothing at all** for that point — no two windows have corners within 24 pt of each other there.
  `swift run axprobe windows` settles that in two subtractions.

Capture the log line **and** `swift run axprobe windows` at the same moment. The knob's position and
existence are a function of those frames and of nothing else.

## 7. The cursor over the handles (2 min)

| | Do this | Expect |
|---|---|---|
| [ ] | Hover a pill on a **vertical** divider | A left-right resize cursor — and nothing else changes: the frontmost app keeps its key appearance, the menu bar stays its own |
| [ ] | Hover a pill on a **horizontal** divider | An up-down resize cursor |
| [ ] | Hover a **knob** | The system's own **move** glyph (four arrows). A crosshair means the artwork could not be read — worth a line, not a defect |
| [ ] | Move the pointer along the gap, fast and slow | **No flicker.** The glyph is steady the whole time the pointer is in the band |
| [ ] | Move off the band, then into a **text field** of the window beside it | The application's own **I-beam** comes back. An arrow here means we stomped it — the worst failure this design has |
| [ ] | Drag a pill until the divider **stops** at a minimum, so the pointer leaves the band | The glyph **stays** for the whole gesture and goes on the mouse-up |
| [ ] | Hover a pill and **switch Space** | The cursor is an ordinary pointer on the far Space. A resize glyph riding a Space change onto somebody else's windows is the failure to report immediately |
| [ ] | With a pill hovered, `pkill SnappySnap` | The pointer is normal again at once |
| [ ] | Settings › System › Compatibility → turn **"Use hidden macOS features" off**, hover a pill | **No glyph at all**, with no relaunch. Turn it back on: the glyph returns on the next band entry |
| [ ] | Hover a pill so the resize glyph is showing, then **hold ⌘** | The glyph **stops** with the pill. The window underneath gets its own cursor back — an arrow here is the same stomp as above |

The log should carry **one** `SetsCursorInBackground is on connection …` line, and nothing per hover
or per frame.

## 8. The gap, and windows that outgrow it (3 min)

| | Do this | Expect |
|---|---|---|
| [ ] | Turn the **gap** off and snap | Windows touch, edge to edge, no inset |
| [ ] | Turn it back on and snap | 8 pt from the screen edges and between neighbours |
| [ ] | With the gap on, **zoom** a window (green button or double-click its title bar) | About half a second later it eases back inside the gap — the same frame a top-edge snap would give it. Log: `window … is W×H on a … area; resizing it to …` |
| [ ] | Zoom a window and immediately start dragging it | It is **not** corrected while you hold it |
| [ ] | Make a window as wide as the display but half its height | Only the width is corrected; the height and the top edge are left alone |
| [ ] | Put an application in **native full screen** | It is never touched |
| [ ] | Turn **"Keep every window inside the gap"** off, then zoom a window | It is left exactly where macOS put it |
| [ ] | Take a handle beside a listed application's window (Finder), then hand-resize that window narrower than its row | Log (category `app`): `window … is W×H; the row for com.apple.finder lowered from …×… to …×…`, and in Settings › Window sizes the Finder row reads the new width, marked **Measured**, while you watch. Hand-resize a Finder window you have **never** snapped or handled: nothing is logged and the row stands |

## 9. Settings and permissions (2 min)

| | Do this | Expect |
|---|---|---|
| [ ] | Open Settings and click through the eight toolbar items | **General, Snapping, Snap Bar, Handles, Custom Areas, System, Health, Tip**, each a symbol above its title (Health a stethoscope), the shown one highlighted, and the window's title following it. The window opens on General already at its size and centred, with no jump; on every switch its bottom edge moves, animated, and its top-left corner does not. Custom Areas is taller than the screen allows: it scrolls, the window stopping short of the display's height |
| [ ] | Read any page | Every group is a bold title, a card of rows, and *under* the card a grey hint, then orange warnings, then blue notes — never text inside a card. **Nothing is smaller than the body text**, there is no radio button anywhere, keys read **⌥ Option** and **⌘ Command**, and no sentence carries a long dash. `rg -n '"[^"]*[—–‒―‐‑−][^"]*"' Sources/SnappySnap/UI Sources/SnapCore/Settings.swift Sources/SystemAdapters/PrivateAPI.swift` prints nothing |
| [ ] | General | The app icon alone at the top, centred, 144 pt. No hint under Updates or under Quit; one blue note under Startup naming the Applications folder and Spotlight |
| [ ] | Snap Bar › **Style** | Three picture tiles, each a MacBook and an external display side by side: *Notch or island* draws the black shape and the island, *Floating bar* a bar on both, *Notch or floating bar* the shape and a bar. The selected tile is tinted and ringed in the accent colour, and the hint under the group changes with it. **Animation** under Snap Assist is a segmented control, greyed while Snap Assist is off |
| [ ] | Snapping › **Gap**, with the gap on | A row *macOS margins for tiled windows*, green **Enabled**. Turn *Tiled windows have margins* off in Desktop & Dock: within 2 s the row is orange **Disabled**, an **Open Desktop & Dock Settings** button appears under it and an orange warning under the hint says to also turn it on, the window growing to fit. Turn it back on: button and warning go, the green row stays. Turn the gap off: the row goes too |
| [ ] | System › **macOS tiling**, with every switch as it should be | Three green rows, *macOS edge tiling*, *macOS margins for tiled windows*, *macOS tiling while ⌥ Option is held*, and **no button and no warning** |
| [ ] | System › **macOS tiling**, with *Tiled windows have margins* off and the gap on | *macOS margins for tiled windows* is orange **Disabled**, an **Open Desktop & Dock Settings** button appears and one orange warning names the switch to turn on. With the gap off as well, the same row is green **Disabled** and the button and the warning are gone |
| [ ] | System › **macOS tiling**, with *Hold ⌥ key while dragging windows to tile* on in Desktop & Dock | Its row is green **Enabled** while *Hold ⌥ Option to snap to halves from anywhere* is off; turn that on: the row goes orange, the button appears and a warning names the switch |
| [ ] | System › **Accessibility**, granted | A green **Granted** row, the note under the card, **no button and no warning**. Revoke it in System Settings: within 2 s the row is red **Denied** behind a stop sign, **Open Accessibility Settings** appears and an orange warning names SnappySnap under *Device Control and Data Access* |
| [ ] | Custom Areas, break the JSON and press **Verify** | A status row: the sentence naming what failed on the left, a red stop sign and **Invalid** on the right. Fix it and Verify: *N areas*, green **Valid** |
| [ ] | Turn off **Drag to a corner for a quarter** | Corners give halves |
| [ ] | Settings › Snap Bar, turn off **Show the snap bar when dragging to the top** | *Haptic feedback*, the three Style tiles, *Suggest windows for the remaining spaces* and *Animation* all grey out, labels included. The blue note under Snap Assist says why: it only starts from a snap bar layout |
| [ ] | Turn off **Show handles between windows** | No pill and no knob |
| [ ] | Quit and relaunch | Every setting survived |
| [ ] | Settings › **Handles** | Under the handle switch and the probe switch, the **Apps** card: one row per application sorted by name — Finder, Safari… — each with a width, a height and **Built in**, and the bundle identifier as the row's tooltip. **Add…** opens a sheet offering the running applications without a row and *Other…*, and only *Other…* shows the identifier and name fields; Add stays disabled until both sizes are filled. Edit a width, press Return, quit and relaunch: it survived and reads **Edited**. **Remove** takes the selected row. **Reset** is enabled only once something differs, and puts the list back |
| [ ] | With probing on, press a pill beside a window of a **listed** application (Finder) | **No blink** — an application with a row is never probed outside the deck — and the divider stops at the row. Remove Finder's row and press again: one blink, and the row is back, marked **Measured** |
| [ ] | Open Settings while a pill is showing | The pill stands down while the window is up; the controls take your clicks |
| [ ] | Revoke Accessibility in System Settings and relaunch | **No dialog at launch.** The app is inert. Re-grant it in System Settings: the app starts within a second, no relaunch and no window |
| [ ] | Settings › System › **Start over**, press **Show Onboarding Again** | Page one: the icon, the headline with *snaps* in the icon's red, and the three capsules. **Continue** walks to **Permissions** |
| [ ] | On **Permissions**, with Accessibility revoked | *Device Control and Data Access* carries an orange triangle and an **Allow…** button; *Allow Notifications* has its own. The stepping button reads **Skip** |
| [ ] | Press **Allow…** on the Accessibility row | **Only** the system dialog, never System Settings beside it. The row shows its button disabled with a spinner while the flow runs. Press it a second time after refusing once: still nothing but the dialog |
| [ ] | Grant it in System Settings and leave the pane open | Within about 2 s the row reads **Granted** on its own and the button becomes **Continue** — **and nothing else on the page moves**: no blink, no reload, the header and the other row stay put. The wizard is still behind the pane |
| [ ] | Close the System Settings window | The wizard comes back in front of what it was in front of. Re-open the pane, leave it open, and click another app instead: the wizard does not move |
| [ ] | **Out of the way**, with macOS tiling on | *macOS window tiling* offers **Open Desktop & Dock Settings** and names both switches word for word. Turn both off there: the row reads **Off** within 2 s. *Open at Login* toggles between **Turn On** and **On** / **Turn Off** from the row itself, with no trip to System Settings |
| [ ] | On **Permissions**, once a row flips from its **Allow…** button to **Granted**, press the stepping button | It advances. The row losing its button shortens the list by 36 pt, and the slack must go to the page's own spacer, never into the footer (`pitfalls.md` 57). The check without clicking: `swift run axprobe elements SnappySnap` names the button's frame and `axprobe hit x y` at its centre must answer `AXButton`, not `AXWindow` |
| [ ] | Walk to **All set** and press **Finish** | The window closes and the front goes back to whoever had it — type in that app and the keystrokes land there. Quit and relaunch twice: **no window and no dialog appear by themselves**, at launch or after |
| [ ] | `defaults delete dev.rubens.SnappySnap onboardingCompleted`, relaunch | The wizard is back at page one, and Settings does **not** open beside it. Close it with the red button, relaunch: it is back again — only **Finish** records it |
| [ ] | With the wizard up, `open -b dev.rubens.SnappySnap` | The wizard comes forward, not Settings. Open Settings too, click another app, then activate SnappySnap: **Settings** comes forward, not the wizard |
| [ ] | Settings › System › Compatibility | Four status rows under the switch — *Exact window matching*, *Pointer over the handles*, *Snap bar above other notch apps*, *Blur behind the snap bar* — each **Available** in green. Hover one: the tooltip lists its symbols, each with its framework and *found*. Turn the switch off: every row still reads Available, because a row reports the Mac and not the switch. A **Missing** row is not a failure — that feature falls back to its public route — but report it, with the tooltip |
| [ ] | Settings › General › **Updates**, press **Check for Updates**, on a copy a version behind the latest release | The running version on the left of the first row; then a spinner and **Checking**, then a blue **Update** button where **Check for Updates** was, naming the newer version. Log (`update`): one `check (asked)` line naming the tag it found. On a copy that is already the latest, the row says so instead and the button does not change |
| [ ] | Turn Wi-Fi off and press **Check for Updates** again | An orange **Could not check: …** with a reason, on the right of the version row, wrapped over two lines and aligned right without squeezing `SnappySnap 1.0.0`, and within 15 s — not a hang. The button is enabled again and the app is otherwise untouched: drag a window to an edge and it still snaps |
| [ ] | Quit, reopen, and watch the `update` log for 15 s | One `check (automatic): …` line about 10 s after launch, nobody having pressed anything, and no orange mark in Settings when it fails |
| [ ] | Settings › **Health**, on a Mac where everything is as it should be | **Two groups and nothing else.** **Health** holds three green lines, *Accessibility permission* **Granted**, *Notifications permission* **Granted**, *Drag detection* **Enabled**, then **Check Again**, and nothing under the card. **Information** holds two blue lines, *Last snap* and *Windows where a snap left them*. No overview, no Copy Report, no version or update, no macOS version, no hidden macOS features, no margins, no handles, no custom areas, no Launch at login, no memory, no running time |
| [ ] | Snap a window, come back to Health and press **Check Again** | A small spinner beside the button for about half a second, the button greyed, then *Last snap* reads a few seconds ago (the moment as its tooltip) and *Windows where a snap left them* counts that window. Nothing on the page moves by itself while you wait: it is read on show and on Check Again only |
| [ ] | With Health open, turn on “Drag windows to left or right edge of screen to tile” in Desktop & Dock | Within 2 s a line *macOS tiling* appears, orange **Enabled**, and a warning under the card names both drag switches. Turn it back off: the line and the warning go. Turning *Tiled windows have margins* off changes nothing on Health. There is no fix button on Health |
| [ ] | Revoke Accessibility, quit and reopen SnappySnap, open Health | *Accessibility permission* is red **Denied** behind the stop sign, the warning under the card names SnappySnap under *Device Control and Data Access*, and there is **no** *Drag detection* line (it waits for the permission). Grant it again: within about 2 s the permission is green and *Drag detection* appears, green **Enabled** |
| [ ] | Settings › **Tip** | The toolbar shows a mug; the first card has no title and carries the app icon beside the sentence; **One-time tip** shows the Ko-fi cup on its red wash, *A cup of coffee*, its grey line, and **Tip €5**, with the hint under the card |
| [ ] | Press **Tip €5** | The Ko-fi page opens in the default browser at `https://ko-fi.com/bambidotexe`. Nothing else moves: the window stays open and in front, and the `update` log stays silent |
| [ ] | Turn **Show in menu bar** off, then press **Quit SnappySnap**, the last group of General | The app is gone: no icon, no snapping, and `pgrep -x SnappySnap` finds nothing. This is the route that does not exist without the button — with the icon hidden there is no menu to quit from. Reopen it and it comes back with Settings |
| [ ] | Settings › General › **Uninstall** | A grey hint, and under it an orange warning that always stands there: it is the hazard of the Trash, not a state to fix |
| [ ] | Press **Désinstaller SnappySnap**, confirm | Every parked window is back, an alert says SnappySnap is in the Trash, and the app exits |
| [ ] | About 5 s after that uninstall | `/Applications/SnappySnap.app` is in the Trash, `defaults read dev.rubens.SnappySnap` fails and `~/Library/Preferences/dev.rubens.SnappySnap.plist` does not exist at all (not an empty one), `~/Library/Application Support/SnappySnap`, `~/Library/Caches/dev.rubens.SnappySnap` and `~/Library/HTTPStorages/dev.rubens.SnappySnap` are gone, System Settings › General › Login Items shows no SnappySnap, and Privacy & Security › Accessibility shows no SnappySnap |
| [ ] | Run a Snap Assist choosing phase, and quit from that button mid-phase | Every window the deck parked is back on screen, not stranded off it. The button quits the same way the menu item does |
| [ ] | Open the **menu bar** menu | **Settings…**, a separator, **Quit SnappySnap** — and nothing else |
| [ ] | Remove an application's row, turn **Measure an app the first time you use a handle next to it** off, then press a pill beside one of its windows | **No blink.** The window does not flash small at the press |
| [ ] | With it still off, drag that divider as far as it will go | The window stops at **120 × 80** and no smaller, on both axes |
| [ ] | Turn it back **on** and press a pill beside a window of that application | The blink is back, the row is made, and the divider now stops at the real floor instead |
| [ ] | With it **off**, remove an application's row, run a Snap Assist phase with one of its windows in the deck, then take a handle on that window | The deck probed it anyway (log `deck`: `probing N of M card(s) not yet probed this session`) — the row is back and the divider stops at the real floor, not at 120 × 80. Run a second phase with the same windows: `probing` is not logged again; each card is probed once a session |
| [ ] | Snap a listed application's window (Finder) into a cell narrower than its row, so it refuses | Log (`drag`): `… its own floor is now W×H; the row stands`. Settings › Handles › Apps: the Finder row has **not** changed. Close that window and open a new Finder window: its preview is the row again |
| [ ] | With that refusing window still open, press **Reset to the built-in list**, then take a handle beside it | The divider goes below the floor the refusal had raised, down to the row: Reset forgets every window's own floor too. The window refuses again on release and re-fits its neighbour once |
| [ ] | Turn it off, quit and relaunch | It is **still off**. A silent revert to on means the setting is missing from `Settings.init(from:)` |

## 9b. Updating (10 min, with a stand-in release)

No release is published, so the update is walked against a stand-in: `Scripts/make-dmg.sh` with a
higher `CFBundleShortVersionString` in `Resources/Info.plist` (put it back afterwards), a
`latest.json` naming that image by a `file://` URL, and the **installed** app started by hand with
`SNAPPYSNAP_UPDATE_FEED=file:///…/latest.json /Applications/SnappySnap.app/Contents/MacOS/SnappySnap`
(CLAUDE.md, *Commands*). The helper's own account is
`~/Library/Application Support/SnappySnap/updates/install.log`.

| | Do | Expect |
|---|---|---|
| [ ] | Start the app with the stand-in and wait 10 s | macOS asks to allow notifications, once; allowed, a notification **Version … is available** with an **Update** button when hovered. Settings › General shows the blue mark and a blue **Update** without having been asked |
| [ ] | Press the notification's **Update**, then **Update** in Settings | The same **Software Update** window both times, brought forward the second time and not opened twice |
| [ ] | Watch the window | **Downloading: … of …** with the bar moving, **Preparing the update**, then **Ready to install. SnappySnap will quit and reopen.** and **Install and Relaunch** turning blue. Log: `downloaded`, `staged`, `ready to install` |
| [ ] | **Cancel**, and the window's close button, mid-fetch | The window goes, `cancelled` in the log, and `updates/` holds no `.dmg` and no `staged` |
| [ ] | A wrong `digest` in `latest.json` | **Update failed: The download is damaged.** and **Try Again** |
| [ ] | An image built with `SIGN_IDENTITY=-` | **Update failed: The update is not signed by the same developer.** |
| [ ] | An image whose version is not higher | **Update failed: The disk image does not hold a newer version.** |
| [ ] | **Install and Relaunch**, with a Snap Assist phase open | The parked windows come back first, the app quits, and a few seconds later it is back: one window, **The update is installed. SnappySnap is running the new version.** with **Done**, and **no Settings window behind it**; the Accessibility grant still holds (drag a window to an edge), `install.log` ends with `version … is running`, `updates/previous` is gone |
| [ ] | Quit the new version within two seconds of its relaunch (Settings › General › **Quit SnappySnap**) | It stays quit and stays updated: `install.log` still ends with `version … is running`, and reopening it shows the new version |
| [ ] | An image whose executable has been replaced by `exit 1` before signing | The previous version comes back by itself, its window says **Version … was not installed. The new version did not start, so the previous one was put back.** with **Close**, Settings › General carries the same reason as an orange mark once opened, and `install.log` has `did not start; putting the previous one back` |
| [ ] | The app run from a read-only folder | After the fetch the window offers **Open Disk Image** and the sentence about dragging SnappySnap to Applications |

## 10. Leaving the arrangement (4 min)

| | Do this | Expect |
|---|---|---|
| [ ] | Start a Snap Assist phase, then open **Mission Control by trackpad** | Everything of ours is gone **before** the windows have finished shrinking into thumbnails, and every parked window comes home. Log: `left the arrangement: missionControl` |
| [ ] | The same with **⌃↑** | Identical — they are different code paths in WindowManager and only the window list tells us about either |
| [ ] | Hover a pill, open Mission Control, close it | The pill goes before the windows finish shrinking, and comes back only **after** they have returned to their places |
| [ ] | Start a phase, then **switch Space** | Everything comes down, every parked window comes home, and **nothing of ours is visible on the new Space at any point** |
| [ ] | Watch the log during a Space change | One `space change detected via sentinel at <edge>` line, **not** one via the notification. The notification means the sentinels are not working |
| [ ] | Put an application **full screen** and come back out, with a pill hovered | Still caught — a full-screen transition has no sentinel signal and rides the notification alone |
| [ ] | Drag a window to the very **top edge** so the Spaces bar appears | This must **not** count as leaving. The Fill preview and the snap bar stay |
| [ ] | Mid-drag, open Mission Control, keep dragging, then close it | Preview and bar are gone and stay gone; a fresh drag afterwards works normally |
| [ ] | Watch any of the above closely | Every surface leaves **together**, on one 120 ms fade |

### A held drag across a Space change (§13)

The one thing a Space change does not end. Needs two Spaces, and **never let go of the button** until
the row says to.

| | Do this | Expect |
|---|---|---|
| [ ] | Drag a window against the **left or right edge** and hold until macOS slides to the next Space. Keep holding, move the pointer, drag to an edge there | The preview lights and the release snaps, with no re-grab. Log: `suspended by a Space change`, then `resumed after N s, pointer moved N pt` |
| [ ] | The same, but **let go the instant** you land | Nothing is placed, and the window stays where the slide left it |
| [ ] | After landing, **hold perfectly still** for several seconds | Nothing lights, however long you wait — the pointer is still on the edge that switched the Space. A nudge of about 8 pt lights it |
| [ ] | After landing, snap to a **half beside another window** | The neighbour gives room the same as on any other Space. A half that lands narrow, or a neighbour that should move and does not, means the window list was re-read before the slide finished |
| [ ] | Ride the edge through **two Spaces** in a row without letting go | Two `suspended` lines and one `resumed`; both the 0.6 s and the 8 pt restart from the second slide |
| [ ] | Land on the new Space, then drag to the **top edge** | The snap bar comes back — its session is rebuilt against this Space, pair partner included |
| [ ] | Land on the new Space and open **Mission Control** while still holding | The drag ends for good. No `resumed` line, and a fresh press afterwards works |
| [ ] | Let go while suspended, then press again straight away | Arms a new drag normally. If a `press while suspended` line appears here, the mouse-up was missed — that is the escape hatch working, not a pass |

## 11. A frozen application (2 min)

| | Do this | Expect |
|---|---|---|
| [ ] | Find a window's pid (`swift run axprobe windows`), `kill -STOP` it, then drag the handle between it and a lively window and release. `kill -CONT` afterwards | The **lively** window lands exactly where its preview was; the frozen one does not and does not have to. The drag stays smooth and there is **no `event tap disabled` line** |
| [ ] | Make a 2×2 of four windows of **one** application and drag the knob | The previews stay smooth — they are ours. The release is the slow part, and that is the documented floor |

## 12. Two displays (2 min — skip if you have one)

Edges, zones and the drop preview are verified on a three-display row, and the deck on two
displays side by side; everything else here is not.

| | Do this | Expect |
|---|---|---|
| [ ] | Snap on each display | Zones are that display's working area |
| [ ] | Drag a window from one display onto its neighbour and drop it on the edge **nearest the display it came from**, most of the window still hanging over that display | The animation plays **entirely on the display it lands on**, smoothly, from the window's own size flush against the seam — not on the first display, and not across the seam. Log: `released across a display seam`. **Never yet seen on two displays** |
| [ ] | Drag to the edge a display **shares** with its neighbour | Halves and corners arm exactly as on an outer edge — no hold, no setting — but from **48 pt** out rather than 24 |
| [ ] | On the same display, drag to an edge facing **nothing** | It arms at the ordinary 24 pt. The wider band is the shared edge's alone |
| [ ] | With the Option switch on, hold ⌥ and cross each display's own centre line | Each display splits at **its own exact middle**, the shared edge's 48 pt band notwithstanding. The two halves are equal on every display in the row |
| [ ] | Cross from one display to the other without stopping | A zone lights as you pass through the band and nothing is placed: the drop is re-resolved where you let go |
| [ ] | On the trackpad, bring the bar up on one display, then carry the pointer along the top edge onto the other | The bar moves with no dwell and **without tapping**. The tap is for summoning a bar, not moving one |
| [ ] | Grab a **wide** window near its middle so it lies across the seam, then aim at the shared edge | The preview morphs out of a rectangle the window's own size, flush against the seam, at the height the window really is — one piece, on the display the pointer is on. Never half an animation on each screen, never a plain fade-in |
| [ ] | Same, with a window **wider than** the target display | Still flush at the seam and still the window's own width; the part beyond the display's far edge is simply not drawn |
| [ ] | Drag a window that sits above the shorter display's top edge onto that display | The departure rectangle slides down to the display's top edge. Only the axis that overhangs moves |
| [ ] | Drag from one display to the other with the pair cell showing | The pair cell is **absent** on the far display. That is the documented limit |
| [ ] | Start Snap Assist from the snap bar on the **left** display, with windows open on both | The deck fans into the left display's bottom **left** corner — its right edge is blocked, so the cards hang off its free edge. **Nothing whatever appears on the right display.** Log (`assist`, `--level debug`): `deck on display N: pastNear / pastFar` |
| [ ] | Repeat from the **right** display | The deck fans into its bottom **right** corner, the usual way. Log: `pastFar / pastFar`. Only that display's windows are parked either way, so the other display never moves |
| [ ] | Unplug or re-arrange a display mid-phase | Everything comes down, every parked window comes home |
| [ ] | *Notch or island*. Start dragging a window on a display with **no** camera housing, where a notch utility shows its island | Its pill widens into ours: a black capsule, 262 × 25, 3 pt under the top edge, centred, covering the utility's island completely — nothing of it shows around ours, even while its volume indicator is up, and **no dot shows above it** while ours arrives |
| [ ] | Same, on a display where no notch utility draws | The whole arrival is seen: a dot grows into a circle where the capsule will be, holds a beat, and widens into the capsule |
| [ ] | Press the pointer against the top edge inside the capsule's width and hold still | The island grows after the dwell, with the haptic tap; the 3 pt above the capsule are not a dead strip. Outside the capsule's width the top edge shows Fill and no bar |
| [ ] | Start a drag with the pointer already inside the capsule's width at the top | The capsule is there **before** the dwell runs out, then grows — never nothing, then a grown island |
| [ ] | Look at the grown island | The cell row sits 24 pt from all four sides and no cell crowds a corner; four continuous corners; shadow and blurred backdrop around it; its top is still 3 pt under the edge. Its background drops Fill, its cells drop their zones |
| [ ] | Move the pointer out of the grown island | It collapses to the capsule and **stays** for the rest of the drag. Log: `island collapsed on display …` |
| [ ] | Hold ⌘, then release it, mid-drag; then the same with ⌥ | The capsule narrows to a circle and scales away about its own centre line, never riding up toward the edge; on release it arrives again. From a grown island it collapses first, then departs |
| [ ] | Tap ⌘ and release it within a tenth of a second | The departure turns round from where it is: no jump, no flash, the capsule comes back |
| [ ] | End the drag with the island collapsed, then with it grown | Collapsed: narrows, scales away. Grown: collapses, narrows, scales away. The panel is gone afterwards (`swift run axprobe windows`). Log: `island down` |
| [ ] | Drag from one display with no housing to another, and straight back | It departs on the display left **while** it arrives on the display entered; coming straight back, the island still departing there is the one that returns — never two on one display |
| [ ] | Drag onto the built-in display from an external one | The island departs; the built-in shows nothing until the notch shape arms |
| [ ] | Open Mission Control mid-drag, island collapsed; then island grown | It departs through its own motion, in step with the utility's island under it, while every other surface fades in 120 ms. Grown: the cells fade on the 120 ms and the shape goes straight to the circle |
| [ ] | `swift run axprobe windows` during a held drag on the display where a notch utility draws | The `SnappySnap` panel — 676 × 225 at y 0, or 780 wide with the pair cell — is listed **above** both of the utility's windows |
| [ ] | *Use hidden macOS features* off, drag on a display where a notch utility draws | Same shape and motion, no blur, a constant hairline when grown, and the island draws **below** the utility's |
| [ ] | *Notch or floating bar*, drag on a display with no housing, then onto the built-in | No island at all: the top edge arms the floating bar there, on Liquid Glass; on the built-in the notch shape arms on the housing. Crossing takes the one off and the other comes up on its own summon |
| [ ] | *Floating bar*, any display | The floating bar everywhere; no black shape and no island, on the built-in either |
| [ ] | A settings file with no `snapBarAppearance`, or a fresh install | *Notch or island* is selected, and is first in the list |

---

## 13. Language (4 min)

The app follows macOS. Nothing in Settings chooses a language, and a catalogue is read once, so every
step here needs the app reopened, not just the window closed.

**In French** (the dev Mac's own setting):

- [ ] Open Settings. **All eight pages are French**, titles, labels, hints, warnings, notes and the
      toolbar; Health reads **Santé**. A single English sentence among them is a missing translation, not
      a style choice: report the exact sentence.
- [ ] The menu-bar icon's menu reads **Réglages…** and **Quitter SnappySnap**.
- [ ] No label is clipped, truncated with an ellipsis, or overlapping its control. French is longer
      than English and the page is taller for it; **that is correct**. Text cut off is not.
- [ ] The window's height still follows the page on every toolbar switch, with the French wrapping.
- [ ] On the System page, in the Health page's warnings and under the Gap group, the quoted macOS switches and
      panes read **exactly as System Settings names them in French**. Open System Settings beside it and compare the
      words. A guess that does not match is a defect.
- [ ] A keyboard key is written symbol first, **⌘ Commande** and **⌥ Option**, in labels and in hints.

**In English**, with `defaults write dev.rubens.SnappySnap AppleLanguages '("en")'` and the app
reopened:

- [ ] Every page is English again, word for word as it was before the app spoke any French.
- [ ] `defaults delete dev.rubens.SnappySnap AppleLanguages`, reopen: French comes back.

**The two windows Settings does not show** (both need the state set up on purpose):

- [ ] With `onboardingCompleted` cleared, all four welcome pages are French: the title bar, the
      headline with its accented word, every row title and grey line, **Continuer** / **Ignorer** /
      **Terminer**, and the tooltip on the required triangle. *Contrôle de l'appareil et accès aux
      données* is the name macOS itself uses — check it against the pane the button opens.
- [ ] The two switches quoted on the *macOS window tiling* row read exactly as Desktop & Dock writes
      them, in French as in English.

## Known residuals — expected, not defects to report

- **A knob at a divider's end does not re-fit when an application refuses its size** (§6). The
  other windows sharing that edge stay where the drag put them and the edge ends ragged.
- **A handle drag does not resize anything until you let go.** That is the design, not lag.
- **One visible blink** the first time a handle is pressed beside a window of an application with no
  row, and one per card the deck probes. It is the minimum-size probe, and macOS offers no other way to
  get the number.
- **A cross of four windows of one application releases in visible steps.**
- **A drop preview can be wrong for a window whose minimum has never been measured** — it shows the
  arrangement solved with the presumed 200 × 150, and a window that refuses lands larger; the
  correction pass settles the arrangement a beat later.
- **The update check says "No release published yet."** Not a defect: it is the honest answer whenever the
  anonymous check can see no release. GitHub answers 404 for a repository that has none and for one it will
  not show an anonymous caller alike, and does not tell them apart. `bambidotexe/snappy-snap` is public and
  carries releases, so a check on a copy behind the latest should now find one instead; seeing this on such
  a copy *is* worth reporting. **Could not check:** is a defect either way. The automatic check gets the
  same 404 and says nothing.
- The snap bar's Liquid Glass does not visibly render.
- **The notch appearance's blur strength and reach, and its spring, are fitted by eye**; the shape and
  the shadow are fitted to measurements. A difference from the reference in the first two is expected
  and worth describing; in the last two it is a defect.
- With **eight or more** cards in a 2×2 area, a card that changes line answers no clicks for ~220 ms
  after each pick.
- An application whose size grain is coarser than 24 pt could still freeze one handle gesture.
- A pill may take a moment to be offered again right after a Snap Assist deal ends.
- Two 1 × 1 panels at 5 % opacity sit at each display's left and right edges while a gesture is live.
  If you can *see* one, that is worth reporting.
- A press outside a pill's band in the quarter second after its release arms a drag that receives no
  moves; press again once the two windows have landed.
