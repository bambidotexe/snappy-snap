---
name: install-locally
description: Use when the owner asks to install SnappySnap on this Mac, to apply a change, to rebuild, to reinstall, to "run the app", to see a change working, or to get the newest build into /Applications. This is one of only two ways a build of this app ever reaches a Mac; the other is publish-release. Also use when about to build the app for any reason, to check first whether a build is even the right action.
---

# Install locally

**This app reaches a Mac in exactly two ways.** This skill is the first: a production build, installed in
`/Applications`, leaving nothing behind. The second is `publish-release`, which does the same and puts the
disk image on GitHub as well.

```bash
Scripts/install.sh
```

That is the whole action. It takes about five minutes, most of it Apple's notary service.

## What it does, and why each part is not optional

1. **Checks the version rule** (`Scripts/version.sh`): the tree is always one patch ahead of the newest
   release on GitHub. So the copy on this Mac is always newer than anything published, and is never
   offered an update that would replace it with something older.
2. **Builds the real thing** — release configuration, signed with the Wooflab team's Developer ID under the
   Hardened Runtime, notarized by Apple, stapled, wrapped in the disk image. Not a shortcut, not a debug
   build, not an unsigned one. What lands in `/Applications` is byte-for-byte what a stranger would download.
3. **Quits the running copy and waits for it to actually exit**, then installs the bundle from inside the
   disk image, so what runs is what a release would hand out, stapled ticket and all. There is no CLI and
   no status to ask first — SnappySnap holds no state worth checking before a quit — so the quit is
   unconditional; the wait keeps the replace from racing the old process's exit.
4. **Leaves nothing behind.** No `.app` and no `.dmg` anywhere under the repository when it returns,
   including when it fails. `Scripts/no-leftovers.sh` holds that rule.

## The rule about leftovers, which is the point

A signed bundle sitting in `build/` is a complete, working application. Spotlight indexes it, the Finder
opens it, and it runs **beside** the copy in `/Applications` as a second instance with the same bundle
identifier and its own Accessibility grant.

So: **only `/Applications/SnappySnap.app` exists.** A build is a step on the way there, never a thing left
lying about. `Scripts/install.sh` and `Scripts/publish.sh` both clean up on every exit path. If you ever
build by another route, delete the bundle yourself before you finish.

## Never do these

| Never | Instead |
|---|---|
| Build debug to "try something" | `Scripts/install.sh`. Debug is refused without `DEBUG_OK=1`, and **you must ask the owner first** — see below |
| `open` a `.app` from `build/` | Install it. Launching a build bundle is what creates a second instance |
| Leave a built bundle behind "for next time" | There is no next time; the next build makes its own |
| Skip notarizing "because it is only local" | Then the installed copy is not what a release ships, and the release path goes untested until it matters |

## Debug builds

A debug build exists to read something a release build will not show — a crash, a symbol, a log line. It
is **never installed** and it is **never made without the owner's explicit consent.**
`CONFIG=debug Scripts/build-app.sh` refuses unless `DEBUG_OK=1`, which is there to make the decision
deliberate, not to be worked around.

If you think a debug build would help, **ask the owner and say why.** If they agree:

```bash
DEBUG_OK=1 CONFIG=debug Scripts/build-app.sh
```

and delete the bundle when you are done with it. `Scripts/run.sh` is not a separate path: it is a familiar
name for `Scripts/install.sh` and does exactly the same thing.

## Checking it worked

```bash
codesign -dvv /Applications/SnappySnap.app 2>&1 | grep -E 'Authority=Developer|flags='
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/SnappySnap.app/Contents/Info.plist
```

The authority is `Developer ID Application: Wooflab (85F6AC5QZF)` and the flags include `runtime`. The
version is whatever `Scripts/version.sh`'s rule gave, one patch above the newest GitHub release.

## The Accessibility grant

SnappySnap's only permission is Accessibility, and macOS ties that grant to the code signature. A build
signed ad-hoc (`Scripts/build-app.sh`'s own warning) gets a new signature — and so needs the grant
re-approved — on every build. A build made through this skill is signed with the Wooflab team's stable
Developer ID identity, so the signature does not change between installs and **the grant survives a
reinstall.** Nothing in this skill asks for or resets that grant; it is only preserved by keeping the
identity the same.

## Taking it off again

There is one way, and it is not the Finder. **Settings › General › Uninstall** removes what SnappySnap put
outside its own bundle, moves the bundle to the Trash and quits. Dragging the bundle to the Trash removes
the app and nothing else, and what is left goes on running against an app that is gone.

The last removals belong to a detached helper that waits for the pid: anything taken away while the app is
still up is written back as it exits. Never suggest removing the pieces by hand instead, and never suggest
`launchctl disable` for the launch agent — it is permanent, and nothing but `launchctl enable` undoes it.
