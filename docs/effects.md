# Crossing effects: design note

How each of Drop Portal's five crossing effects is meant to feel, and the
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
