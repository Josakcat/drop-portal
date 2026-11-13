# Crossing effects: design note

How each of Drop Portal's seven crossing effects is meant to feel, and the
numbers behind it. The code is `Sources/DropPortal/PortalStage.swift` (the
full-screen stage behind the card), `PortalEffects.swift` (the card itself and
the edge light in front of it) and the phone page in
`Sources/DropPortalCore/WebPage.swift`.

## Source

The motion follows a storyboard by a motion designer (kept outside the
repository, with hero-frame mockups): its curves, timings, layer and particle
budgets and its "cut first" lists. Where this note and that spec differ, the
differences are listed under "Not from the spec" below.

## The shape every effect shares

`p` is the drag's progress (0 at the edge, 1 at the landing spot). `t` = 0 is
the release on each device; `L` is the Mac card reaching its spot.

| Beat | Phone | Mac |
| --- | --- | --- |
| Held (`t` < 0) | The card follows the finger; the edge light and the effect's signature follow p only (one transform), nothing loops or emits | The card follows the finger through the critically damped spring (unchanged); every shape follows p, the impact's light builds toward its pose, the card's halo grows |
| Travel | The card leaves from where the finger let go, on curve A, 220 to 260 ms; no pull-back | The card flies on curve T from where it was to its spot and lands at exactly L |
| Impact | The edge flashes (no animated filter, no full-screen flash); Portal light 18 motes, Liquid 16 drops and a ripple, the others no particles | The card pops to 1.14 and springs back (Beam 1.08, no bounce) with the effect's own squash; the stage plays the effect's own signature, no shared shockwave |
| Settle | The card comes back into the grid to show the upload | Everything is gone 0.55 s after L |

## The throw (flow)

The page sends the release with `peek-commit`: `vx`, `vy` (the card's own
velocity, CSS px/s, y down; the card moves 0.4 of the finger's dy), `exitY`
(its middle, 0 top to 1 bottom) and `angle` (degrees, CSS clockwise), and
`y` with every `peek-move`. All optional: an older page gets the travel
curve. While held, the Mac card comes out of the edge at the phone's height
(mapped onto the visible frame, 6% in) and drifts half way to the landing
height with p, on the same spring as x. On the flick, `ThrowFlight` (Core)
takes over: per axis `target − (1 − u)³ (D + (3D − v₀T) u)`, u = t / T, which
starts at the card with the phone's velocity (× 1.6, scaled to the screen,
360 to 6000 pt/s, within 55° of straight left) and arrives at rest with no
acceleration. T is the quartic ease-out's time for that speed, kept within
0.8 × the effect's L and L + 0.3 s; past what the distance can absorb the
card flies beyond the spot (at most 70 pt) and comes back, and its height is
kept on screen. T becomes this crossing's L for the card's look
(`CardLook.thrown`) and the stage (`StageView.flight`), so the impact, its
light and the sound land with the card; Beam's slices stretch with it. The
phone's tilt comes in over 60 ms and straightens with the flight (Wormhole
keeps its own turn). The landing spot itself never moves, so the impact's
light is the one painted for it. A file without a peek keeps the travel
curve; the settings' Preview throws a made-up flick.

## Building with the drag

The impact's own picture is on screen from the first pixel of the drag
(`StageView.build`): pinned at the seam and stretched so its landing spot
sits on the card, horizontally by how far the card has come
(`(seam − card) / (seam − landing)`) and vertically from .62 to 1 with it.
Near the edge it is squeezed against the seam (Wormhole's rims edge-on,
Portal's lens a sliver), and it opens to exactly the impact's pose as the
card reaches its spot, so the landing continues what the drag drew. Its
opacity is .85 × p (eased, full by p .7), .92 in flight, gone 0.1 s after L
while the impact's copy flashes. A cancel feeds p back as the card returns,
so it closes back into the edge; the stage fades only if that takes longer
than 0.45 s. Only its position, transform and opacity change per frame.

The card's halo (two baked glows of the colour, open in the middle) and a
2.4 pt rim just outside its edge sit behind the card on the stage at .5 → .95
with p, take the card's held shape (Wormhole's turn and scale, Liquid's
squash and rounder corners), reach 1 in flight, and pop with the card at L
(1.14, Beam 1.08) before fading with the light. Beam's rim waits for the
slices to line up (p .55 → 1); Paper plane's leaves while the photo folds and
comes back as the halves open.

Rainbow is painted as two alpha masks, the light's coverage and its white
core. The coverage is filled with two turns of the hue wheel side by side
that slide right to left: .3 of a turn with p, the rest of the turn across
the impact's 0.52 s (ease in-out), so every line runs through the whole
wheel while it plays.

Curves: A `cubic-bezier(.40,0,.85,.35)`, T and O `(.16,1,.30,1)`, F
`(.22,0,.58,1)`, I `(.55,0,1,.45)`. The vignette never gets darker than 35%.
Sizes are for a 1280 × 800 screen and scale with it.

## Per effect (Mac L; phone travel)

- **Portal light** (default; L 280 ms; phone 220 ms). Held: a slit on the edge
  220 → 600 tall, a light ribbon to the card, a blue wash on the card at most
  18%. Impact: a thin 560 × 390 elliptical wave around the card (.35 → 1 in
  80 ms, then to 1.18 while it fades), 28 motes off the card's trailing edge, a
  sheen. Phone: the edge halo flashes 1.35 → 1.85 wide in 100 ms, 18 motes.
- **Liquid** (L 320 ms; phone 260 ms). Held: a membrane on the edge 30 → 160
  wide; a rounded copy of the photo with a film of water crossfades in at
  p .35 → .80; the card squashes .90 × 1.08 → 1.16 × .88. Travel: a neck from
  the edge to the card thins to a hairline over the last 120 ms and snaps.
  Impact: a 440 × 300 crown of eight drops, 24 falling droplets, the rounded
  copy crossfades back to the photo, squash 1.10 × .90. Phone: drawn out to
  1.80 × .18, 16 drops and one ripple.
- **Wormhole** (showcase; L 300 ms; phone 240 ms). Held: three rims on the
  edge, 560 / 390 / 250 across, tilted 45° / 30° / 15° in perspective, growing
  .40 → 1 with p; the card turns 18° × (1 − p) and scales .78 + .22p. Travel:
  the rims turn 35° in their plane. Impact: the rims turn edge-on (88°) in
  80 ms, 20 and 40 ms apart, flare and collapse into a point on the edge; a
  480 × 320 shock ellipse around the card; 20 star streaks. Phone: a half-ring
  and two inset rims turned −70° × p, the rims opening from .2 wide, no
  spinner, no particles.
- **Paper plane** (L 560 ms; phone 700 ms). Held: past p .25 the photo's two
  halves hinge up to 34° with fold shading and a crease of light. Travel: they fold to 68° in 90 ms
  and become a plane that loops once, contrails drawn from the edge; 100 ms
  before L the halves reappear at 68° and open to 20°. Impact: they open flat
  into the photo with a crease of light, a 500 × 210 landing ellipse. Phone:
  the sheet folds shut in 100 ms, the plane loops once and leaves.
- **Beam** (L 320 ms; phone 296 ms). Held: the card is nine registered slices,
  each trailing a little more toward the seam, thin lines every 8 pt over
  them, nine lines from the slices back to the seam. Travel: the slices lock
  12 ms apart, 224 ms each, the last at L. Impact: a 3 pt blade crosses the
  card right to left in 96 ms while the slices crossfade to the card, a faint
  520 × 240 halo, 12 pixels, the lines pull back into the seam. Phone: nine
  strips leave 12 ms apart, no glitch, no particles.

## Stardust and Lightning

From the second motion study (`.droppykit/design/fx-mockups-2/`, the
research brief and its timelines; the approved look is `mockups.html`). Their
maths is in Core (`SkyEffects.swift`, tested in `SkyEffectsTests`), the Mac
side in `SkyShaders.swift` / `SkyMetal.swift` / `SkyCrossing.swift`, hooked on
the stage and the card by one-liners like MetalCrossing (`StageView.sky`,
`CardLook.sky`), the phone in `WebSkyEffect.swift` (`window.DropPortalSky`).
Every grain and bolt vertex is a function of (id, time, seed): nothing is
integrated frame to frame. Telegram's dust effect gave the ideas and numbers
only (its code is GPL). Neither takes the phone's throw: each keeps its own
flight (`PortalEffect.isSky`).

- **Stardust** (Mac L 0.78 s; phone 0.72 s, dust gone by 1.3 s). Phone: the
  card dissolves into one grain per 2 × 2 px (per px on a 3x screen, at most
  40 000, halved when two of the first ten frames take over 24 ms), released by
  `0.7 s × (0.5x + 0.2·noise + 0.3·rand)`, left edge first; grains within 16 px
  of the front shiver 0.4 px; released grains blow left at 300–800 px/s on
  emphasized-accelerate along a curl flow, dwindle from 0.6–1.8 px to one
  physical pixel and fade; 10 % glitter at 6 Hz (`0.12 + 0.88·rand⁴`), warm
  white tinted 25 % with the colour, additive. Instanced quads (WebGL2, or
  WebGL1 + ANGLE_instanced_arrays), never `gl.POINTS`, no float targets; the
  colours come from the card drawn to a canvas from its own picture. No WebGL:
  the same grains on a Canvas2D at one per 4 px. Mac: while held, 16 000 filler
  grains stream in from beyond the edge into a soft vortex there, its clock the
  drag's p (it moves only with the finger); after the release it holds 50 ms,
  then 64 320 image grains (one per point of the 240 × 268 card) launch over
  0.18 s by `0.5(1 − x) + 0.2·noise + 0.3·rand` (right side first) and fly
  450–550 ms on emphasized-decelerate, their curl offset decaying to 0, growing
  from a dot to a square over the last 20 %; the card crossfades in over the
  last 120 ms from 1.02 to 1.0, then one glint: a band across the card at up
  to 3× SDR white (EDR, never past the screen's headroom), back to 1 by
  0.15 s. The card's halo and the impact light are off; the file's sound is a
  shimmer settling into one chime.
- **Lightning** (Mac L 0.085 s, strike gone by 0.45 s; phone 0.25 s, bolt
  gone by 0.42 s). Bolt: midpoint displacement, 5 generations (33 trunk
  points), 2–4 branches at about ±30° from the first three generations'
  midpoints, 0.6–0.7 of the length left, 40–60 % of the trunk's width; ends
  pinned. Phone (Canvas2D, additive, no bloom): the leader draws from inside
  the card to the left edge in four 15 ms steps at 35 %, one 25 ms flash, the
  card rides it off the edge (still for 60 ms, then curve A, gone at 250 ms),
  afterglow τ 100 ms; no re-strike. Mac: a faint lavender glow on the edge
  while held (opacity only), then the leader from the edge to the card's spot
  in four steps, the return stroke 25 ms with a 2 pt core at min(headroom,
  2.5)× white (EDR), an ice-blue halo (σ 6 pt) and a five-level bloom (Karis
  first, 3 × 3 tent up, mix 0.6), MAX blending so the joints leave no dots;
  one re-strike with a new seed at +90 ms (60 %); afterglow
  τ 100 ms. The card lands as the stroke ends and pops 1.0 → 1.03 (a 0.35 s
  spring); an exposure lift of 18 % (× the EDR gain) only inside its rounded
  rect. Colour: `SkyColor.lightningSafe` keeps every hue 25° or more from red
  and desaturates to at most 0.45 toward (0.9, 0.8, 1.0), on the stage, the
  seam, the phone's bolt and its edge.
- **The flash cap** (WCAG 2.3.1): `FlashLimiter`, one per process on each
  side, refuses a flash while three others lie within a second of it, so no
  one-second window holds four; a strike books its flashes when it starts. A
  refused flash is drawn at the leader's 35 % and lifts nothing. A Mac strike
  has two (the stroke and one re-strike; the spec's second re-strike at
  +160 ms was dropped for this), so a second flick within a second still gets
  its bright stroke and only its re-strike dims; a third strikes dim. No CA impact light or seam flare plays for either effect.
- **Reduce motion**: the phone fades and scales to 0.9 over 200 ms with no
  edge flash; the Mac makes no stage and the card fades in, as for every
  effect.
- **Core Animation fallback** (no Metal, still compiling, Low Power Mode, the
  settings process): Stardust's card flies as it is with a soft glow on the
  edge; Lightning's bolt is three stroked paths (halo, glow, core) with the
  same timeline and cap, and a white lift layer on the card.
- **Harness**: `--metal-shots` also writes `sky-<effect>-*.png` (held p
  .25/.5/.85, moments after the release, Lime, Rainbow, red, the CA fallback,
  a light wallpaper) and `sky-<effect>-sheet.png`; `--metal-bench` prints
  `sky …` lines; `--phone-shots <dir> stardust|lightning` adds `-sky-<ms>.png`.
  Harness stills convert the float canvas to sRGB without unpremultiplying
  (CG's own conversion drops light over little cover); EDR clips to white.

## Phone: WebGL edge

`WebGLEffect.swift` draws the phone's edge light with one WebGL1 canvas (one
triangle, one fragment shader, a branch per effect) from the first drag;
`<html class="gl">` then hides the CSS `.portal`, and the veil, the card's
flare and the sparks canvas stay. Held, it draws only when p changes; after
a send it runs for the travel and a 340 ms impact (1.5 s at most). DPR is
capped at 1.5 and the canvas at 520 000 pixels; the context is destroyed
when the page is hidden. No WebGL, a shader that does not build, a lost
context (twice) or Reduce motion: the CSS edge, as before. Shots:
`DropPortalHarness --phone-shots <dir> [effect] [css|gl|gl-rainbow|gl-send]`.

## On the GPU (Metal)

When the main process has a Metal device (`MetalFX`, compiled from source
off the main thread in about 10 ms at activation), a crossing gets two
canvases (`MetalCrossing.swift`): `GPUStage` over the stage, under the card
(the effect's light from `stage_fs` and, from L, 1,400 to 3,000 particles
computed in the vertex shader), and `GPUCard` inside the card's host, so the
card's pose still comes from `host.sublayerTransform` (`card_fs` draws the
card's own snapshot distorted; Paper plane's halves get `wing_fs`). The CA
layers the shader replaces are hidden: Wormhole's tunnel, Beam's lines,
Portal's slit and ribbon, Liquid's membrane and neck. Everything else
(vignette, wash, the impact's light bitmap, the halo, the seam) stays CA.

- Held: a frame only when p or the card moves. After the release: every
  display-link frame until 0.62 s after L, encoded on a render queue; a third
  frame in flight is dropped, the main thread never waits for a drawable.
- The stage canvas is capped at 1 Mpx (the light is soft), the card's at
  1.4 Mpx. M4 Pro, 1728 × 1117: stage 0.3 to 1.8 ms a frame (Wormhole's
  vortex the most), card under 0.5 ms; the engine costs about 1.7 MB plus
  three drawables per canvas.
- Never under Reduce motion or Low Power Mode, never in the settings
  process, never a screen capture: the shaders only read the card's snapshot.
- Shader rules learnt the hard way: no `smoothstep` with reversed edges
  (undefined in Metal; `ss`), no `pow` of 0 under fast math (`pw`), and
  `light()`'s cover follows its brightness, or it dims the whole desktop.
- Harness: `--metal-shots <dir>` (GPU stills at p .25/.5/.85, impact and
  0.2 s in, default/Lime/Rainbow, a light wallpaper, and `compare-*` with
  the CA path at half size), `--metal-bench` (GPU and CA costs).

The CA fallback avoids offscreen passes: Wormhole's rims are
`CATransformLayer`s, the stage's ambient group, the tunnel and the seam fade
without group opacity, Beam's seam lines are one baked bitmap, the card's
scanlines have no rounded mask and the card's edge clip is a mask only while
the screen's edge cuts the card.

## Landing touches (every effect)

Two touches play on top of whichever effect crossed, each with its own switch
under Look & sound (`landingCelebration`, `kineticName`, both on). Spec:
`.droppykit/design/fx-mockups-2/brief-research.md` ("Landing celebration",
"Kinetic filename" and their timelines), look approved in `mockups.html`.
The numbers live in `DropPortalCore/LandingTouches.swift` (tested in
`LandingTouchesTests`), the Mac side in `LandingCelebration.swift`, the glass
in `LandingDepth` (PortalFeel.swift), the phone's mirror in `WebPage.swift`.

Landing celebration, Mac only, from the impact (the spec's contact beat):

| | |
|---|---|
| Sparks | 20 (14 in Low Power Mode) spawned in one frame on the card's rounded perimeter, evenly round the ring with ±35% jitter, straight out at 180–320 pt/s, drag e^(−4t), no gravity, radius 2–5 pt shrinking to 0, life 0.45–0.7 s, additive |
| Colour | the photo's two strongest hues (16 × 16 sample, 12 hue bins weighted by saturation × brightness, off main), normalised to full brightness and 30–35% toward white; no picture or no colour: the effect's palette (glow, core), so every tint and Rainbow works |
| Glow | one radial under the card, 1.3× its size, 0.25 → 0 over 0.35 s |
| Settle | the landing pop (to 1.14 in 70 ms) comes home on the land spring, 0.35 s / bounce 0.1 (k 322.3, c 32.31, ζ 0.9), instead of the dip and rebound; the effect's own squash stays |
| Tilt | after the settle (0.19 s after the landed card appears): up to 6°, m34 −1/900, rotY = nx·θ, rotX = −ny·θ, on a 0.25 s critically damped spring (k 631.7) integrated per frame by a `FrameClock` so it retargets smoothly; the contact shadow shifts 4–6 pt; a radial sheen (screen blend, 0 → 0.15 with the lean) sits opposite the lean; flat on exit or with a button held |
| Paths | GPU: an instanced quad per spark in its own two shaders (`spark_vs`, `spark_fs`, compiled once off main) on a small `FXCanvas` driven by `FXDriver`; Core Animation: one `Sprite.glow` per spark, sampled by `timeline` so `still:` renders any instant |
| Reduce motion | nothing: no sparks, no settle spring (the effect's land does not play), no tilt; the shadow stays |

The trackpad's land tap and the contact shadow are PortalFeel's own; the
celebration adds none. Clicks and drags are untouched: the sparks, the glow
and the depth view take no hits and the tilt is a layer transform.

Kinetic filename, Mac (the landed card's name) and phone (the "Sent" line):

| | |
|---|---|
| Cut | middle-truncated first to the label's width, keeping an extension of 2–9 characters, no space beside the ellipsis; then split into letters (the ellipsis is one) |
| Each letter | 0.32 s: opacity easeIn(1.4p), blur 3 → 0 pt, rising 4.5 pt on a spring with bounce 0.08, drifting in from 0.16 em right (the tracking closing) |
| Stagger | min(25 ms, 300 ms / n): 40 letters are in by 0.61 s, never past 0.65 |
| Extension | arrives last and stays at 0.62 opacity |
| Mac | each letter a sharp and a blurred bitmap (the blur is the letter's own shadow, no Core Image), drawn off main, crossfaded; starts with the landed card (T ≈ 0.16 s) |
| Phone | spans animated by Web Animations, after the card is back in view (a quick upload waits for it, at most 3 s); the card stays 1.15 s instead of 0.9 |
| VoiceOver | the Mac's label keeps the full name and the letters are layers; the phone reads a visually hidden full name and hides the letters |
| Reduce motion | the whole label fades over 0.2 s |

Bench (`--metal-bench`, this M-series Mac): tones 0.26 ms off main; CA
sparks 2.1 ms on main to start, 0.34 ms per frame to render at 2x; GPU sparks
0.31 ms per frame; the name 0.6–1.7 ms of letters off main, then 1.7 ms (12
letters) to 4.5 ms (40) on main to start.

Not from the spec: the card does not arrive tilted 8–10° (the throw already
brings the phone's angle in and straightens it); the spark ring starts at the
impact rather than at the settle's perceptual end; the CA path uses sprite
layers, not `CAEmitterLayer` (an emitter has no drag, no outward direction per
point and cannot draw a still for the harness); there is no shockwave.

With Stardust and Lightning (merged in fx2-merge): both keep their own land
with the celebration on. Lightning's pop stays 1.0 → 1.03 on its 0.35 s
spring and Stardust's card stays its 1.02 → 1 handoff (no pop): the settle
(`LandingCelebration.settle`) only replaces the five older effects' dip and
rebound. The sparks, glow, tilt and name play for every effect.

Stardust's landed card takes clicks and drags `Stardust.interactiveAt`
(0.4 s) after the release, in place under grains that are still flying (the
spec's 450–600 ms grain flight is kept); it stays invisible until the impact,
then shows as usual. A click or drag before then ends the crossing at once
and lets the stage finish on its own clock.

Follow-up, not done: a true wait-for-bytes holding state (the card held at
its spot, grains or bolt idling, until the upload has finished, instead of
the landed card appearing only when the file is here).

## Couriers: the foundation

Pip (`cheek`), Tofu (`pounce`), Digby (`mole`) and the Matcha Trio (`ducks`)
share one timeline and one rig toolkit; the character is the effect, so a
courier crossing has no light on either side (no vignette, edge wash, halo,
WebGL or Metal).

- Numbers: `Sources/DropPortalCore/Couriers.swift` only (beats, the seed's
  `CourierPlan`, the short version, sticker and skip timings). The page gets
  them as `DPCourier.T`; a test fails if a shared flow file writes a beat out.
- Mac: `Sources/DropPortal/Couriers/CourierCrossing.swift`. `StageView` makes
  a `CourierCrossing` for a courier effect: it waits at the right edge from
  `peek-start` and follows p, arrives from the send (T = 0) to L carrying a
  drawn copy of the card, hands the copy over at L (CardLook shows the real
  card), has its moment and leaves on `CourierPlan.clock` (short version
  included); a click on it (button polled each frame, the click still goes
  through) lands the card now and fades the courier in `skipMS`. Reduce
  motion: no stage, `CourierSticker` on the landed card (fade in, one blink,
  fade out). One `FrameClock` per crossing, live only; `stop()` from the
  stage's `stop()`, which `tearDown` reaches in `deactivate()`.
- Phone: `Sources/DropPortalCore/WebCourierEffect.swift`, `window.DPCourier`
  (Canvas 2D, rAF only while a courier shows): `begin` at peek-start (seed,
  short), `hold(p)`, `leap` at the release (the card element fades, the
  courier carries its copy out of the left edge), `sticker` under Reduce
  motion, `off` on a cancel, `still` for the harness. WebPage.swift inserts the
  block once, next to WebGL and Sky.

### How to add a courier

A character session edits ONLY its own files:

| Courier | Mac | Phone | Assets (optional) |
| --- | --- | --- | --- |
| Pip, `cheek` | `Sources/DropPortal/Couriers/PipCourier.swift` | `Sources/DropPortalCore/WebCourierPip.swift` | `.droppykit/design/couriers/pip/` |
| Tofu, `pounce` | `Sources/DropPortal/Couriers/TofuCourier.swift` | `Sources/DropPortalCore/WebCourierTofu.swift` | `.droppykit/design/couriers/tofu/` |
| Digby, `mole` | `Sources/DropPortal/Couriers/DigbyCourier.swift` | `Sources/DropPortalCore/WebCourierDigby.swift` | `.droppykit/design/couriers/digby/` |
| Matcha Trio, `ducks` | `Sources/DropPortal/Couriers/MatchaCourier.swift` | `Sources/DropPortalCore/WebCourierMatcha.swift` | `.droppykit/design/couriers/matcha/` |

The assets folder is for references and sketches only (ignored by git with the
rest of `.droppykit/design/`, never shipped): everything the droplet draws is
code, paths and colours, in the two files.

- Mac: keep `final class <Name>Courier: CourierCharacter` and
  `let courier: Courier = .<case>`. Build the parts once in `build(_:)` with
  `rig.part(name, path, fill:, ink:, width:, pivot:, in:)` in the mockup's
  units (feet at 0,0, y down, facing left, about 100 tall), puffs and props
  under `rig.behind` / `rig.front` (stage points, y up). Override what you
  need: `waiting` (p), `arrive` (T 0 … L; set `pose.card` and end it exactly at
  `scene.landing`, scale 1), `leave` (T on the plan's clock, nil once gone),
  `sticker`, `draw` (move parts each frame, `f.blink` is the lid), `gag` (only
  when `plan.gag`), `cues` + `sound` (its own sounds, samples at 44.1 kHz;
  the landing sound stays PortalSound's). `scene.mock(x, y)` maps a point of
  the mockup's Mac screen onto the stage; `CourierKit` has the eases, springs,
  `squash`, `landSquash`, `qbez`.
- Phone: `DP.register("<case>", { hold(p, env), leap(t, env), sticker(ms, env),
  draw(c, P, env), extra(c, phase, x, env) })` with `DPCourier.kit` (the
  mockup's `rigM`, `E`, `xf`, `eye`, `cshadow`, `card`, springs). A pose is
  `{ x, y, k, sx, sy, rot, face, alpha, blink?, shadow?, card: { cx, cy, s, rot } }`;
  `leap` returns null once the edge is clear (`env.T.clear`).
- Shots, just your courier:
  `swift run -q DropPortalHarness --courier-shots ./shots/couriers <case or name>`
  (e.g. `pip`): `<case>-mac-{waiting,arrival,landing,after}-{light,dark}.png`
  and `<case>-phone-{hold,leap,exit}-{light,dark}.png`. Look at them.
- Off-limits for a character session: `CourierCrossing.swift`,
  `CourierShots.swift`, `WebCourierEffect.swift`, `Couriers.swift`,
  `PortalEffects.swift`, `PortalStage.swift`, `LandingPanel.swift`,
  `WebPage.swift`, the harness and the tests. If a character needs something
  there, write it down for the foundation instead of editing it.

## Not from the spec

- The peek keeps its spring while the finger holds the card (the spec sets the
  anchor directly).
- The card pops to 1.14 at the landing on every effect, Beam included: on a
  whole screen a 240 pt card reads small.
- Paper plane loops once on both sides (the spec has no loop), so its flight
  is 0.56 s on the Mac instead of 0.38.
- Portal light's motes drift toward the seam, as in the mockup, not left over
  the card; there is no front half of the wave in front of the card.
- Paper plane's wings are the photo's two halves on the middle crease, not
  triangles.
- The phone keeps its rift and veil (capped at 35%) and the contrail dashes.
- The impact's light builds through the whole drag ("Building with the
  drag"), on top of the spec's held shapes, and the card has a halo and rim
  of its own; Paper plane folds from p .25 instead of .6, to 34° instead of
  18°.
- Phone, held: the edge signature grows with p (Portal 0.4 → 1, Liquid 0.3 →
  1.1 wide, Beam streams in from 160 px and 0.4 wide, Paper plane opens
  from 0.12 tall).

## UI/UX Pro Max rules applied

Queried with the skill's search tool (`--domain ux` and `--domain gsap`) and
its quick reference, Animation section. No database match was found for
"particle burst celebration" or "anticipation overshoot spring" in the gsap
domain; the anticipation and overshoot numbers above are general motion
practice, not from the skill.

- `continuity`: "Page/screen transitions should maintain spatial continuity
  (shared element, directional slide)". The card is one object across both
  screens: it leaves the phone's left edge and enters the Mac's right edge,
  and the Mac's rays and contrail aim at it the whole way.
- `motion-meaning`: "Every animation must express a cause-effect
  relationship". The light grows with the drag, flares on the send and ends
  where the card lands; nothing loops without a cause except the effect's
  motion of its own while a card is held.
- `spring-physics`: "Prefer spring/physics-based curves". The peek keeps its
  critically damped spring; the landing pops and springs back.
- `gesture-feedback`: "Drag, swipe, and pinch must provide real-time visual
  response tracking the finger". The Mac card, the edge light and the phone's
  trail all follow the drag frame by frame.
- `exit-faster-than-enter`: "Exit animations shorter than enter (~60-70%)". A
  cancel fades the stage in 0.14 s; the impact clears within 0.55 s.
- `easing`: "Use deceleration when arriving, acceleration when leaving". The
  vortex collapse and the cancel fade ease in; the impact, ripples and
  shockwave ease out.
- `transform-performance`: "Use transform/opacity only". Both sides animate
  transform and opacity only; the phone draws particles on a single canvas.
- `excessive-motion`: "Animate 1-2 key elements per view max". The card is the
  hero; everything else is light around it, and it is all gone 0.55 s after
  the landing.
- `no-blocking-animation`: "Never block user input during an animation". The
  Mac stage ignores the mouse and never takes focus; the phone's other cards
  stay usable while one flies.
- `cancellable-state-transitions`: "never depend on an animation-end event for
  correctness". The phone puts the card back on a 1.3 s timer whatever the
  animation does; the Mac's landed card waits for the impact but the impact
  never waits for an animation.
- Reduced motion (ux, severity High): "Respect user's motion preferences".
  Reduce motion on the Mac skips the stage and the shapes (the card fades in,
  the edge light fades); on the phone `prefers-reduced-motion` turns the send
  into a plain 160 ms fade with no veil, rays or particles.

## Not used

- Haptics: iOS Safari has none for a web page.
- Sound: one cue, Droppy's own `drop` sound through `host.feedback`, when the
  file has landed. It follows Droppy's sound setting.
