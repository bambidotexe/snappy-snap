# SnappySnap documentation

Windows 11-style window snapping for macOS 26+, as a menu-bar accessory. Swift 6, SwiftPM, no Xcode
project. Accessibility is the only permission it needs to work.

## Where to look

| Document | Read it when |
|---|---|
| [`functional.md`](functional.md) | You need to know what the app does: every feature, trigger, number, setting, limit. The authority on behaviour. |
| [`architecture.md`](architecture.md) | You need to know how it is built: targets, the drag → zone → write path, overlays, state, threading, build. |
| [`macOS.md`](macOS.md) | You are about to rely on a platform assumption: the APIs in play, coordinate spaces, panels, Spaces, the cursor, persistence. |
| [`pitfalls.md`](pitfalls.md) | Something looks like it should work and does not. The only place that records approaches that fail. |
| [`manual-test-checklist.md`](manual-test-checklist.md) | You changed something and want to see it work. The app target has no automated tests. |
| [`private-api-index.md`](private-api-index.md) | You are adding, removing or auditing a private symbol. The complete inventory. |
| [`../CLAUDE.md`](../CLAUDE.md) | You are an agent working in this tree: commands, rules, traps, status. |
| [`../README.md`](../README.md) | You are a user: what it does, requirements, install, settings. |

`_audit.md` and `_coverage.md` are the records of the September 2026 whole-codebase audit: what was
read, what was found, what was deleted.

## How to start

```sh
swift build                                     # all four code targets
swift test                                      # two targets; count two summary lines
swift run axprobe prefs                         # the system's own tiling must be off
Scripts/install.sh                              # production build, notarized, into /Applications
/usr/bin/log stream --predicate 'subsystem == "dev.rubens.SnappySnap"' --level debug
```

The first launch opens the welcome window and waits there; the Accessibility dialog comes from its
**Allow…** button and from nothing else. Signing identity comes from
`Scripts/signing.env` (tracked, no secret in it): it looks the Wooflab team's Developer ID
Application certificate up in the keychain by team id; an ad-hoc signature resets the Accessibility
grant on every build.

## The shape in one paragraph

`SnapCore` decides everything that can be decided without asking macOS: zones, the snap bar, the drop
planner, the Snap Assist cards and deck, the handle and junction arithmetic, minimum-size policy,
Mission Control detection. `SystemAdapters` is the only code that talks to Accessibility, the window
list, the event tap, screens and defaults, and `WindowWriter` in it is the only place a window is
written. `SnappySnap` wires the two into features: a drag session, the overlays, Snap Assist, the
handle pill, the junction knob, the oversize watcher, the Settings window.

## The shared documents

`shared/` is a byte-for-byte copy of `~/Projects/macos-app-template/docs/shared/`: the workflow every app
of the family follows, the conventions, the platform facts, the traps and the walks they all share. **It is
never edited here**; a change goes in the template and `sh ~/Projects/macos-app-template/scripts/sync-shared-docs.sh`
replicates it. What is this app's own stays in the documents above.
