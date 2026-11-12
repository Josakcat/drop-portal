# Store plan

Where Drop Portal stands before a Droppy Store submission, what the remaining
policy questions are, and what the developer has to decide. Written 2026-11-12
against DroppyKit 1.23.0 (the SDK checkout this package pins).

Status at the time of writing (from the build copy, `~/Library/Caches/Portal/src`):

| Check | Result |
| --- | --- |
| `swift test --package-path .droppykit/tests` | 40 tests, 0 failures |
| `droppykit build` | builds, universal, `kit.minAPI 1.23.0 covers every DroppyKit API it calls` |
| `droppykit validate` | 0 errors, 2 warnings, "Ready to submit." |
| `droppykit lint --submit` | 0 errors, 2 warnings (both `process`, FileTray.swift), 1 waiver (`own-window`, LandingPanel.swift), 1 note (`docs/` folder) |
| `droppykit run -- --shots` | 11 of 11 shots, `problems` empty, `activation.error` null, `shelf-widget` and `settings-pane` provided |
| Droppy Playground | not installed (out of scope for this pass) |

## 1. The own windows (`own-window` waiver)

### What the droplet draws outside Droppy's surfaces

`Sources/DropPortal/LandingPanel.swift` makes four kinds of `LandingPanel`
(an `NSPanel` subclass, borderless, non-activating, `.floating` level,
`[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`):

1. **Landing card** (`LandingPresenter`): mid-screen on the display with the
   pointer, a thumbnail, name and size; click opens the file (apps, scripts and
   installers are revealed instead), drag exports the file URL
   (`NSDraggingSource`); shrinks away after a few seconds, longer under the
   pointer.
2. **Peek card** (`PeekCard`): slides in from the right screen edge while the
   phone drags, follows the finger with a spring, turns into "Receiving" with
   a ring on a flick, flies on the effect's curve and becomes the landing card
   in place.
3. **Edge seam** (`PortalSeam`): a click-through light on the right screen
   edge that follows the drag.
4. **Stage** (`PortalStage`): a click-through panel the size of the screen,
   just under the card, for at most a few seconds per crossing (closed 0.9 s
   after the impact); not made under Reduce motion.

The waiver on `LandingPanel.swift:16` only names the landing card. The other
three panels ride on the same `allow-file` waiver without being described.

### What the host offers instead (DroppyKit 1.23.0)

Read: `Rules.md` (own-window, Asking for an exception), `HUDsAndNotifications.md`,
`ExpandedSurfaces.md`, `LiveActivities.md`, `Capabilities/`, `Services/DropletServices.swift`.
None of them lets a droplet choose where on screen something appears, draw
across the whole screen, or follow a position that changes 60 times a second.

| Option | Position | Drag-out / click | Animation | Full-screen effect | Limits | Verdict |
| --- | --- | --- | --- | --- | --- | --- |
| **A. Keep the panels + waiver** (today) | Anywhere, display with the pointer, peek follows the finger | Drag exports the URL, click opens | Everything in `docs/effects.md` | Yes | Needs a maintainer to agree; panels also show over full-screen apps (`.fullScreenAuxiliary`), which Rules lists as something Droppy never does | Keeps the product |
| **B. HUD card** (`DropletHUDCard`, `host.hud`) | The notch only | Up to two buttons ("Open", "Show in Finder"); no drag | Droppy's own spring; a progress ring for "Receiving 42%" | No | Queued behind Droppy's HUDs; 30 s max; 6 new a minute, 3 waiting; refused while the shelf is open; `.high` only right after a user action on the droplet, so a phone send is `.normal`; no thumbnail (an SF Symbol only) | Fully compliant, loses the look |
| **C. Free-form HUD strip** (`DropletHUDRequest(leading:trailing:)`) | The notch's two outer edges | A SwiftUI view, but whether a drag can start from a HUD window is not documented; nothing in the middle (camera) | Only what is swapped (`DroppyTransition.compactContent`) | No | Same queue and bounds as B | Small thumbnail possible, drag unproven |
| **D. Notification** (`host.notifications`, already used for text) | Droppy's banner stack under the notch | Click = `.opened`, up to two buttons; no drag | None of its own | No | 10 a minute; Focus can silence it; the user can switch it off | Good as a record ("photo.jpg received, Open / Show in Finder"), not as the landing |
| **E. Expanded surface** | The shelf under the notch, up to `proposal.maximumSize` | A real SwiftUI view, so a thumbnail with `.onDrag` / `.draggable` is plausible (untested in the host) | Inside the surface only | No | Must be presented from a widget, shortcut, launcher or route; Droppy refuses to open it while the user works in the shelf or during a file drag; takes over the shelf | Best compliant home for drag-out, but needs a click |
| **F. Shelf widget** (already declared) | In the shelf | A "last received" tile could be dragged out, like Droppy's own File Tray | Widget transitions only | No | Only seen when the shelf is open | A complement, not a landing |
| **G. Live activity** (`progress` band) | Notch wings | No buttons, no drag (`makeExpanded` is not mounted) | `DroppyCompactClock` only | No | Compact only | Could show upload progress, nothing else |

The peek card (2), the edge seam (3) and the stage (4) have no host
equivalent at all: no surface follows a moving point, sits at the right screen
edge, or covers the screen. Migrating means dropping the crossing effects on
the Mac side and keeping them only on the phone.

The File Tray already gives drag-out after a landing (item 2 below): every
received file is put in Droppy's own File Tray, where Droppy's own drag works.

### Recommendation

Keep option A and ask early, as `Rules.md` "Asking for an exception" says: an
issue in the Store repository (or a note at the top of the merge request)
before the submission, with:

- the waiver text widened to name all four panels (below);
- two concessions offered up front, each a small change the developer can make
  if the maintainer asks: drop `.fullScreenAuxiliary` so nothing shows over a
  full-screen app, and a setting "Show crossings on screen" whose off state
  lands a file as a HUD card (B) plus a notification (D) with Open and Show in
  Finder, the File Tray covering drag-out;
- a pointer to `docs/effects.md`-style limits: a few seconds per crossing,
  click-through except the card, nothing under Reduce motion but a fade, all
  closed in `deactivate()`.

If the maintainer says no, the fallback is B + D + F (+ G for progress): fully
compliant, no waiver, but the Mac side becomes a notch HUD and the crossing
effects live only on the phone.

### Waiver text a maintainer would need to agree to

The current line names only the landing card. If option A is kept, the
developer (not an agent) would replace it with something like:

```swift
// droppykit-lint: allow-file own-window: Drop Portal's crossing needs four short-lived, borderless, non-activating panels that no DroppyKit surface can place: the landing card mid-screen on the display with the pointer (click opens, drag exports the file URL), the peek card that follows the phone's drag in from the right screen edge, a click-through light on that edge, and a click-through layer the size of the screen behind the card for at most a few seconds per crossing (not made under Reduce motion). Each is ordered out after the landing or on cancel, and all are closed in deactivate(); agreed in droplets#<issue>.
```

## 2. File Tray helper (`process` warnings)

- DroppyKit has no host call that adds a file to Droppy's shelf or File Tray.
  `DropletShelfService` only opens, closes, focuses, holds and re-measures;
  `DropletWorkspaceService` opens URLs and reveals in Finder. (The
  `shelf-write` permission's doc comment says "Add items to the shelf", but no
  service method does that.) So the `osascript` helper stays.
- Done in this pass (`Sources/DropPortal/FileTray.swift`): a termination
  handler instead of a wait, output read while it runs, a 10 s deadline that
  sends SIGTERM to the helper's whole process group (`kill(-pid, …)`) and
  SIGKILL 2 s later, every running helper tracked and stopped from
  `deactivate()` (`FileTray.cancelAll()`), `apple-events` declared in
  `droplet.json`, and the README says which app it drives (Droppy's own
  "Add to Droppy Shelf" service) and why.
- The two `process` warnings remain by design: the lint flags every process
  start and every `osascript` string whatever the code around it does
  (`Rules.md`: "is allowed and is a warning"). The lint's text does not ask for
  a waiver, so none was added. Review reads the code and the README.
- Better long term: ask for a host call (for example
  `host.shelf.add(fileURLs:)` behind `shelf-write`) in the same Store issue; the
  helper then goes away.

## 3. `kit.minAPI` 1.23.0

- `COMPATIBILITY.md`: 1.23.0 ships in "nightlies since the second of
  2026-11-03; no beta, stable or Playground yet". The newest stable is Droppy
  16.0.1 / Playground 1.0.27 with DroppyKit 1.20.1; 1.21.0 was betas only and
  1.22.0 one nightly.
- What the droplet imports from 1.23.0 (from the built bundle's symbols against
  `Scripts/api-symbols.txt`):
  - `host.notifications` / `DropletNotification` (the "Clipboard received"
    banner, `notch-banner`);
  - `ShelfWidgetCompositionProviding`, `ShelfWidgetLayoutTraits(single:split:…)`,
    `ShelfWidgetModeSize`, `ShelfWidgetHeaderTraits`, `DropletWidgetComposition`,
    `droppyWidgetText` (the pairing QR widget).
  Everything else is 1.9.0 or older.
- Could it go lower? Only by rewriting both: the widget back on
  `makeWidgetView` with its own insets (which `AGENTS.md` and the lint now tell
  every droplet to leave), and the text banner as a free-form HUD (which the
  rules say is wrong for a message the user should read). DroppyKit documents
  weak linking (`@_weakLinked` + `#_hasSymbol`) only for a view type such as
  `DroppyNowPlayingPlayer`; a protocol conformance like
  `ShelfWidgetCompositionProviding` cannot be made optional that way. So
  lowering loses features and goes against the current rules. **minAPI is left
  at 1.23.0.**
- `minAppVersion` is `15.3.0`, which no longer matches: the lint cannot check
  it because the ledger names no Droppy release for 1.23.0 yet. Once a Droppy
  release ships 1.23.0, `minAppVersion` must be raised to it
  (`python3 ~/Desktop/Private/droppy/droppykit/Scripts/lint-droplet.py --app-floor 1.23.0`
  will print it), or the Store would offer the droplet to a Droppy that refuses
  it.
- In practice the submission waits for that release: a merge request on
  1.23.0 today could only be installed by people on a nightly.

## 4. Store metadata (done in this pass)

- Screenshots: five PNGs in `Assets/` (`screenshot-1-portal-light.png` …
  `screenshot-5-paper-plane.png`), 1440 × 900, from
  `DropPortalHarness --peek-shots` (each effect 40 ms after the landing,
  harness sample photo). Portal light, the default, is first (the Store card).
  Not used: the harness shelf and settings shots, because their QR codes encode
  this Mac's real LAN address (with a harness token), and the harness widget
  said "Another app is using port 8787" (the running Droppy holds the port).
- Description: a short privacy paragraph (local network only, ports 8787 and
  8788 while on, nothing leaves the Wi-Fi, pairing code, Reset pairing,
  Downloads › Drop Portal, quarantine, plain HTTP). The full text is the
  README's "Privacy and security".
- Keyword `airdrop` removed (another company's mark).
- CHANGELOG: one user-facing `## [1.0.0] - 2026-11-12` entry, 1.6 KB. The
  development history that was under `[Unreleased]` is in git.
- Creator: `Josak Cat`, gitlab `Josakcat`; `Assets/Creator.png` is not the
  scaffold disc (`lint --submit` passes); no `creator.url` (not required).
- LICENSE: `Copyright (c) 2026 Josak Cat`.
- No home-folder name, email or `/Users/` path in `droplet.json`,
  `Package.swift`, `Sources/`, `Assets/` (PNG metadata included),
  `CHANGELOG.md`, `README.md` or `LICENSE`.

Icon concept for the merge request (Jordy designs the icon; nothing was
drawn): a card crossing a vertical edge of light, starting from the SF Symbols
`iphone.and.arrow.forward` or `rectangle.portrait.and.arrow.right`.

## Remaining blockers

1. **minAPI 1.23.0 is nightly only.** Wait for a Droppy release that ships
   DroppyKit 1.23.0, then raise `minAppVersion` to it (section 3).
2. **The `own-window` exception** for four panels, one of them full screen,
   needs a maintainer's agreement; today's waiver text names only the landing
   card (section 1). Only the developer can change the waiver.
3. **`docs/` is not part of a droplet.** The lint notes that `droppykit submit`
   sends it and the Store refuses it. Move `docs/` (this file and `effects.md`)
   to `.droppykit/docs/` or out of the package before submitting; `CLAUDE.md`
   points at `docs/effects.md`.
4. **Playground check not done.** "Done means" includes the bundle loading in
   Droppy Playground; this pass did not install anything.
5. **Two `process` warnings** stay (section 2); review reads them.

## Questions for the user

1. Option A (keep the panels, ask a maintainer, widen the waiver) or the
   compliant fallback (HUD card + notification + File Tray, effects only on the
   phone)? If A: should the concessions (no `.fullScreenAuxiliary`, a "Show
   crossings on screen" setting) be built before asking?
2. Wait for a stable Droppy with DroppyKit 1.23.0, or rewrite the widget and
   the text banner to target 1.20.x now (losing the host-owned widget box and
   the notification banner)?
3. Move `docs/` to `.droppykit/docs/` (and update `CLAUDE.md`)?
4. "Add received files to File Tray" is on by default and runs a helper for
   every file. Keep it on, or start it off as Good citizen suggests for things
   that run work on their own?
5. Is a `creator.url` wanted (a GitLab profile or a site)? None was invented.
6. Should a Store screenshot show the QR widget or settings? It would need a
   harness-only fake address and token; today's shots encode the real LAN
   address, so none was used.
7. Is the icon concept above what you want in the merge request?
