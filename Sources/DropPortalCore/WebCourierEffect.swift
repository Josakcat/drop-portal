//
//  WebCourierEffect.swift
//  DropPortalCore
//
//  The four couriers on the phone page: `window.DPCourier`, the same contract
//  as `CourierCrossing.swift` on the Mac. One Canvas 2D over the page, drawn
//  by requestAnimationFrame only while a courier is on screen:
//
//  - `DPCourier.begin(effect, files)` at peek-start: the crossing's seed and
//    whether it is the short version (both go to the Mac in `peek-start`).
//  - `DPCourier.hold(effect, p, card)` while the finger holds the card.
//  - `DPCourier.leap(effect, card, rect, done)` at the release: the courier
//    takes a drawn copy of the card and leaves through the left edge; `done`
//    when the edge is clear (`phoneClearMS`).
//  - `DPCourier.sticker(effect, rect, done)` under Reduce motion.
//  - `DPCourier.off()` on a cancel: the courier fades.
//  - `DPCourier.still(effect, phase, x, opts)` draws one instant for the harness.
//
//  The rig toolkit (`DPCourier.kit`) is the approved mockup's
//  (`.droppykit/design/fx-mockups-cute-v2/mockups.html`): Path2D parts, one
//  body transform (`rigM`), springs, squash, blinks, the contact shadow and the
//  drawn card. Every number of the timeline comes from Couriers.swift
//  (`DPCourier.T`); the generator is CourierRandom's (`Math.imul`).
//
//  Each character is one `DPCourier.register(name, def)` in its own file,
//  `WebCourier<Name>.swift`; see "How to add a courier" in effects.md.
//

import Foundation

public enum WebCourierEffect {
    /// Every courier's timings from Couriers.swift, as the page's `DPCourier.T`.
    static var timings: String {
        var rows = Courier.allCases.map { c in
            let color = "#" + String(format: "%06X", c.color)
            return #""\#(c.rawValue)":{"L":\#(c.landingMS),"exit":\#(c.exitMS),"gone":\#(c.goneMS),"clear":\#(c.phoneClearMS),"gagOneIn":\#(c.gagOneIn),"who":"\#(c.who)","color":"\#(color)"}"#
        }
        rows.append(#""_":{"interactiveAt":\#(Courier.interactiveAt),"shortWindow":\#(Courier.shortWindow),"shortIdle":\#(Courier.shortIdleMS),"skip":\#(Courier.skipMS),"jitter":\#(Courier.jitter),"ducks":[\#(Courier.ducklingRange.lowerBound),\#(Courier.ducklingRange.upperBound)],"stickerFade":\#(Courier.stickerFadeMS),"stickerBlink":\#(Courier.stickerBlinkMS),"stickerHold":\#(Courier.stickerHoldMS),"cancelFade":\#(Courier.cancelFadeMS)}"#)
        return "{" + rows.joined(separator: ",") + "}"
    }

    /// The characters' scripts, one per courier, in `Courier.allCases` order.
    static let characters: [Courier: String] = [
        .cheek: WebCourierPip.script, .pounce: WebCourierTofu.script,
        .mole: WebCourierDigby.script, .ducks: WebCourierMatcha.script,
    ]

    /// The toolkit and the four characters, plain JavaScript (the tests run it in JavaScriptCore).
    public static var script: String {
        toolkit.replacingOccurrences(of: "/*timings*/{}", with: timings)
            + Courier.allCases.compactMap { characters[$0] }.joined(separator: "\n")
    }

    /// What WebPage.swift inserts, once.
    public static var block: String {
        let names = Courier.allCases.map { "html[data-effect=\($0.rawValue)]" }
        // A courier has no edge light: the character is the effect.
        let css = names.map { "\($0) .portal" }.joined(separator: ",") + "{display:none}"
            + ".courierfx{position:fixed;left:0;top:0;width:100%;height:100%;z-index:12;pointer-events:none}"
        return "<style>\(css)</style>\n<script>\n\(script)\n</script>\n"
    }

    static let toolkit = #"""
(function (W) {
  "use strict";
  var T = /*timings*/{};
  var TAU = Math.PI * 2, PI = Math.PI, DEG = 180 / PI;

  // ───────── maths (the mockup's) ─────────
  function clamp(v, a, b) { a = a === undefined ? 0 : a; b = b === undefined ? 1 : b; return v < a ? a : v > b ? b : v; }
  function mix(a, b, t) { return a + (b - a) * t; }
  function seg(t, a, b) { return clamp((t - a) / (b - a)); }
  function easeOut(x) { x = clamp(x); return 1 - Math.pow(1 - x, 3); }
  function easeIn(x) { return Math.pow(clamp(x), 3); }
  function easeInOut(x) { x = clamp(x); return x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2; }
  function sine(x) { return 0.5 - 0.5 * Math.cos(PI * clamp(x)); }
  function backOut(x, s) { s = s === undefined ? 1.70158 : s; x = clamp(x) - 1; return 1 + (s + 1) * x * x * x + s * x * x; }
  function bez(x1, y1, x2, y2) {
    return function (x) {
      x = clamp(x); var lo = 0, hi = 1, u = x;
      for (var i = 0; i < 22; i++) { u = (lo + hi) / 2; var v = 3 * (1 - u) * (1 - u) * u * x1 + 3 * (1 - u) * u * u * x2 + u * u * u; if (v < x) lo = u; else hi = u; }
      return 3 * (1 - u) * (1 - u) * u * y1 + 3 * (1 - u) * u * u * y2 + u * u * u;
    };
  }
  var curveA = bez(0.3, 0, 0.8, 0.15), decel = bez(0.05, 0.7, 0.1, 1), travel = bez(0.2, 0.7, 0.3, 1);
  // A damped spring's offset from 1 to 0 (zero start velocity), f in Hz, a in ms; kick starts at 0 with a push.
  function settle(a, f, z) { f = f || 3; z = z || 0.5; if (a <= 0) return 1; var w = TAU * f / 1000, q = Math.sqrt(1 - z * z), wd = w * q; return Math.exp(-z * w * a) * (Math.cos(wd * a) + z / q * Math.sin(wd * a)); }
  function kick(a, f, z) { f = f || 3; z = z || 0.4; if (a <= 0) return 0; var w = TAU * f / 1000, wd = w * Math.sqrt(1 - z * z); return Math.exp(-z * w * a) * Math.sin(wd * a); }
  // Volume-preserving squash and stretch: s along y, 1/s across.
  function squash(s) { return { sx: 1 / s, sy: s }; }
  // Landing: squash to `peak` across for `hold` ms, rebound, then a spring (returns sx; sy = 1/sx).
  function landSq(a, peak, reb, hold) {
    peak = peak || 1.25; reb = reb || 0.95; hold = hold || 50;
    if (a < 0) return 1; if (a < 16) return mix(1, peak, easeOut(a / 16)); if (a < hold) return peak;
    if (a < hold + 50) return mix(peak, reb, sine((a - hold) / 50)); return 1 + (reb - 1) * settle(a - hold - 50, 3.2, 0.55);
  }
  function hash(n) { var x = Math.sin(n * 127.1 + 311.7) * 43758.5453; return x - Math.floor(x); }
  function qbez(a, b, c, t) { return { x: (1 - t) * (1 - t) * a.x + 2 * (1 - t) * t * b.x + t * t * c.x, y: (1 - t) * (1 - t) * a.y + 2 * (1 - t) * t * b.y + t * t * c.y }; }

  // ───────── the seed: CourierRandom and CourierPlan in Couriers.swift ─────────
  function rng(seed) {
    var s = Math.imul(seed >>> 0, 2654435761 | 0) >>> 0 || 1;
    return function () { s ^= s << 13; s >>>= 0; s ^= s >>> 17; s ^= s << 5; s >>>= 0; return s / 4294967296; };
  }
  // Blink: close 50 ms, hold 30, open 70.
  function lid(a) { if (a < 0 || a > 150) return 0; if (a < 50) return Math.pow(Math.pow(a / 50, 3), 0.6); if (a < 80) return 1; return Math.pow(1 - (a - 80) / 70, 3); }
  function blinkTimes(seed, end) {
    var r = rng(seed), out = [], t = 400 + r() * 1400;
    end = end || 6000;
    while (t < end) { out.push(t); t += Math.min(7000, Math.max(1500, 2500 - Math.log(1 - r()) * 2000)); }
    return out;
  }
  function plan(name, seed, short, files) {
    var c = T[name], J = T._.jitter, r = rng(seed);
    var jitter = 1 - J + 2 * J * r(), roll = r();
    var gag = c.gagOneIn > 0 && roll < 1 / c.gagOneIn;
    var blinkSeed = ((r() * 4294967296) >>> 0 | 1) >>> 0;
    var actors = name === "ducks" ? Math.min(T._.ducks[1], Math.max(T._.ducks[0], files || 1)) : 1;
    var times = blinkTimes(blinkSeed, 60000);
    return {
      name: name, seed: seed >>> 0, short: !!short, jitter: jitter, gag: gag, blinkSeed: blinkSeed, actors: actors, blinks: times,
      // Eyes at `ms` on the clock (0 = the hold's start): 0 open, 1 shut.
      blink: function (ms) { var k = -1; for (var i = 0; i < times.length && times[i] <= ms; i++) k = i; return k < 0 ? 0 : lid(ms - times[k]); }
    };
  }

  // ───────── drawing (the mockup's) ─────────
  function M() { return new DOMMatrix(); }
  function E(x, y, rx, ry, r) { var p = new Path2D(); p.ellipse(x, y, Math.max(0.01, rx), Math.max(0.01, ry), r || 0, 0, TAU); return p; }
  function xf(path) { var m = new DOMMatrix(); for (var i = 1; i < arguments.length; i++) m = m.multiply(arguments[i]); var p = new Path2D(); p.addPath(path, m); return p; }
  function rotAt(x, y, a) { return M().translateSelf(x, y).rotateSelf(a * DEG).translateSelf(-x, -y); }
  function applyM(c, m) { c.transform(m.a, m.b, m.c, m.d, m.e, m.f); }
  // One body transform for every rig: feet at (x, y); stretch along the velocity (vs, va); turn;
  // squash about the feet (sx, sy, breath); facing (1 left, -1 right); spin about the middle (cy units up).
  function rigM(P, cy) {
    var m = M().translateSelf(P.x, P.y);
    if (P.vs && P.vs !== 1) { var h = cy * P.k; m.translateSelf(0, -h); m.rotateSelf((P.va || 0) * DEG); m.scaleSelf(P.vs, 1 / P.vs); m.rotateSelf(-(P.va || 0) * DEG); m.translateSelf(0, h); }
    if (P.rot) m.rotateSelf(P.rot * DEG);
    var b = P.breath || 0; m.scaleSelf((P.sx || 1) / (1 + b * 0.6), (P.sy || 1) * (1 + b));
    var f = P.face === undefined ? 1 : P.face; m.scaleSelf(P.k * f, P.k);
    if (P.spin) { m.translateSelf(0, -cy); m.rotateSelf(P.spin * f * DEG); m.translateSelf(0, cy); }
    return m;
  }
  function wpt(m, x, y) { var p = m.transformPoint(new DOMPoint(x, y)); return { x: p.x, y: p.y }; }
  // Union outline: every part stroked at twice the width, then filled on top.
  function strokeAll(c, paths, o, lw) { c.lineJoin = "round"; c.lineCap = "round"; c.strokeStyle = o; c.lineWidth = lw * 2; paths.forEach(function (p) { c.stroke(p); }); }
  function fillP(c, p, col) { c.fillStyle = col; c.fill(p); }
  function rimShade(c, path, shade, base, dx, dy) { c.save(); c.clip(path); c.fillStyle = shade; c.fill(path); c.translate(dx === undefined ? -5 : dx, dy === undefined ? -6 : dy); c.fillStyle = base; c.fill(path); c.restore(); }
  function hilite(c, x, y, rx, ry, r, a) { c.save(); c.globalAlpha *= a === undefined ? 0.55 : a; c.fillStyle = "#fff"; c.fill(E(x, y, rx, ry, r === undefined ? -0.5 : r)); c.restore(); }
  // An eye: `bl` is the lid (0 open, 1 shut).
  function eye(c, x, y, rx, ry, bl, o, lw) {
    c.save(); var b = clamp(bl || 0);
    if (b > 0.82) { c.strokeStyle = o; c.lineCap = "round"; c.lineWidth = lw * 1.4; c.beginPath(); c.moveTo(x - rx * 1.1, y + ry * 0.1); c.quadraticCurveTo(x, y + ry * 0.85, x + rx * 1.1, y + ry * 0.1); c.stroke(); }
    else { c.fillStyle = o; c.fill(E(x, y + ry * b * 0.55, rx, ry * (1 - b * 0.92))); if (b < 0.45) { c.fillStyle = "#fff"; c.fill(E(x - rx * 0.3, y - ry * 0.36, rx * 0.42, ry * 0.34, -0.4)); } }
    c.restore();
  }
  // The soft contact shadow under the feet; `a` fades it as the courier lifts.
  function cshadow(c, x, y, w, a) {
    a = a === undefined ? 1 : a; if (a <= 0 || w <= 0) return;
    c.save(); c.translate(x, y); c.scale(1, 0.24);
    var g = c.createRadialGradient(0, 0, 0, 0, 0, w);
    g.addColorStop(0, "rgba(0,0,0," + 0.28 * a + ")"); g.addColorStop(0.55, "rgba(0,0,0," + 0.16 * a + ")"); g.addColorStop(1, "rgba(0,0,0,0)");
    c.fillStyle = g; c.beginPath(); c.arc(0, 0, w, 0, TAU); c.fill(); c.restore();
  }
  // The drawn copy of the card the courier carries: a white card with the photo (or a grey one).
  function card(c, cx, cy, w, h, o) {
    o = o || {}; var s = o.s === undefined ? 1 : o.s, a = o.alpha === undefined ? 1 : o.alpha;
    if (a <= 0.002 || s <= 0.01) return;
    c.save(); c.globalAlpha *= clamp(a); c.translate(cx, cy); c.rotate(o.rot || 0); c.scale(s * (o.qx || 1), s * (o.qy || 1));
    var r = Math.min(14, w * 0.08);
    c.shadowColor = "rgba(0,0,0," + (o.sh === undefined ? 0.35 : o.sh) + ")"; c.shadowBlur = 14 * Math.max(0.4, s); c.shadowOffsetY = 6 * Math.max(0.4, s);
    c.beginPath(); c.roundRect(-w / 2, -h / 2, w, h, r); c.fillStyle = "#fbf8f2"; c.fill(); c.shadowColor = "transparent";
    var m = w * 0.055;
    c.save(); c.beginPath(); c.roundRect(-w / 2 + m, -h / 2 + m, w - 2 * m, h - 2 * m, r * 0.6); c.clip();
    if (o.img && o.img.width) {
      var iw = o.img.width, ih = o.img.height, k = Math.max((w - 2 * m) / iw, (h - 2 * m) / ih);
      c.drawImage(o.img, -iw * k / 2, -ih * k / 2, iw * k, ih * k);
    } else {
      var g = c.createLinearGradient(0, -h / 2, 0, h / 2); g.addColorStop(0, "#ffc59a"); g.addColorStop(0.55, "#5fb3c1"); g.addColorStop(1, "#ffe0a8");
      c.fillStyle = g; c.fillRect(-w / 2, -h / 2, w, h);
    }
    c.restore(); c.restore();
  }

  var kit = {
    TAU: TAU, PI: PI, DEG: DEG, clamp: clamp, mix: mix, seg: seg, easeOut: easeOut, easeIn: easeIn, easeInOut: easeInOut,
    sine: sine, backOut: backOut, bez: bez, curveA: curveA, decel: decel, travel: travel, settle: settle, kick: kick,
    squash: squash, landSq: landSq, hash: hash, qbez: qbez, rng: rng, lid: lid,
    M: M, E: E, xf: xf, rotAt: rotAt, applyM: applyM, rigM: rigM, wpt: wpt, strokeAll: strokeAll, fillP: fillP,
    rimShade: rimShade, hilite: hilite, eye: eye, cshadow: cshadow, card: card
  };

  // ───────── the registry and the player ─────────
  var DP = { T: T, kit: kit, plan: plan, names: Object.keys(T).filter(function (k) { return k !== "_"; }) };
  // A character: DPCourier.register("cheek", { hold(p, env), leap(t, env), sticker(ms, env), draw(c, P, env), extra?(c, phase, x, env) }).
  DP.register = function (name, def) { if (DP.names.indexOf(name) >= 0) DP[name] = def; };
  DP.has = function (name) { return DP.names.indexOf(name) >= 0 && !!DP[name]; };

  var cv = null, ctx = null, raf = 0, live = null, current = null, lastFlick = 0;
  function now() { return W.performance ? performance.now() : Date.now(); }
  function canvas() {
    if (!cv) { cv = document.createElement("canvas"); cv.className = "courierfx"; cv.setAttribute("aria-hidden", "true"); document.body.appendChild(cv); ctx = cv.getContext("2d"); }
    var dpr = Math.min(3, Math.max(1, W.devicePixelRatio || 1)), w = innerWidth, h = innerHeight;
    if (cv.width !== Math.round(w * dpr) || cv.height !== Math.round(h * dpr)) { cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr); }
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    return ctx;
  }
  function box(r) { return { left: r.left, top: r.top, width: r.width, height: r.height, cx: r.left + r.width / 2, cy: r.top + r.height / 2, bottom: r.top + r.height, right: r.left + r.width }; }
  // What every pose function gets: the card's box, the screen, the scale (the mockup's phone units), the plan.
  function env(name, rect, p, img) {
    var r = box(rect);
    return { name: name, T: T[name], all: T._, kit: kit, plan: p, rect: r, W: innerWidth, H: innerHeight,
             k: r.width / 116 * 0.62, ground: Math.min(innerHeight - 24, r.bottom + r.height * 0.18), img: img || null };
  }
  // One frame: the shadow, the courier, the card it carries, the character's extras.
  function paint(c, def, phase, x, e) {
    var P = phase === "hold" ? def.hold(x, e) : phase === "leap" ? def.leap(x, e) : def.sticker(x, e);
    if (def.extra) def.extra(c, phase, x, e);
    if (!P) return false;
    var lift = Math.max(0, e.ground - P.y), a = P.alpha === undefined ? 1 : P.alpha;
    if (P.shadow !== false) cshadow(c, P.x, e.ground + 1, 40 * P.k / 0.62 * (1 - Math.min(0.8, lift / 120)), a * (1 - Math.min(1, lift / 160)));
    if (P.blink === undefined) P.blink = e.plan.blink(phase === "hold" ? x * 600 : 600 + x);
    if (P.card && P.cardBehind) card(c, P.card.cx, P.card.cy, e.rect.width, e.rect.height, { s: P.card.s, rot: P.card.rot, alpha: a, img: e.img });
    def.draw(c, P, e);
    if (P.card && !P.cardBehind) card(c, P.card.cx, P.card.cy, e.rect.width, e.rect.height, { s: P.card.s, rot: P.card.rot, alpha: a, img: e.img });
    return true;
  }
  function frame() {
    raf = 0; if (!live) return;
    var c = canvas(); c.clearRect(0, 0, innerWidth, innerHeight);
    var t = now() - live.t0, def = DP[live.name], on = true, x;
    if (live.mode === "hold") x = live.p;
    else if (live.mode === "leap") { x = t; on = t <= live.e.T.clear; }
    else { x = t; on = t <= T._.stickerHold + T._.stickerFade; }
    if (live.fadeAt) { var f = 1 - (now() - live.fadeAt) / T._.cancelFade; if (f <= 0) on = false; else c.globalAlpha = f; }
    if (on) on = paint(c, def, live.mode, x, live.e) !== false;
    c.globalAlpha = 1;
    if (!on) { var done = live.done; stop(); if (done) done(); return; }
    if (live.mode !== "hold" || live.fadeAt) raf = requestAnimationFrame(frame);
  }
  function kickFrame() { if (!raf) raf = requestAnimationFrame(frame); }
  function stop() { live = null; if (raf) cancelAnimationFrame(raf); raf = 0; if (ctx) ctx.clearRect(0, 0, cv.width, cv.height); }
  function picture(card) { if (!card || !card._thumb) return null; var i = new Image(); i.src = card._thumb; return i; }

  // peek-start: this crossing's seed and the short version, for the Mac.
  DP.begin = function (name, files) {
    if (!DP.has(name)) { current = null; return null; }
    var seed = (Math.floor(Math.random() * 4294967295) + 1) >>> 0;
    var short = lastFlick > 0 && now() - lastFlick < T._.shortWindow * 1000;
    current = plan(name, seed, short, files);
    return { seed: seed, short: short };
  };
  // The finger holds the card at p (0 … 1): the courier waits and reacts. Redrawn on every move.
  DP.hold = function (name, p, cardEl) {
    if (!DP.has(name) || !cardEl) return;
    if (!current || current.name !== name) current = plan(name, 1, false, 1);
    var e = env(name, cardEl.getBoundingClientRect(), current);
    live = { name: name, mode: "hold", p: clamp(p), t0: now(), e: e, done: null };
    kickFrame();
  };
  // The release: the courier takes a copy of the card and leaves through the left edge.
  DP.leap = function (name, cardEl, rect, done) {
    if (!DP.has(name)) { if (done) done(); return; }
    if (!current || current.name !== name) current = plan(name, 1, false, 1);
    lastFlick = now();
    live = { name: name, mode: "leap", t0: now(), e: env(name, rect, current, picture(cardEl)), done: done };
    kickFrame();
  };
  // Reduce motion: the courier is a still sticker beside the card that blinks once and fades.
  DP.sticker = function (name, rect, done) {
    if (!DP.has(name)) { if (done) done(); return; }
    if (!current || current.name !== name) current = plan(name, 1, false, 1);
    live = { name: name, mode: "sticker", t0: now(), e: env(name, rect, current), done: done };
    kickFrame();
  };
  // A cancel or the edge going dark: a hold fades, a leap or a sticker plays on.
  DP.off = function () { if (live && live.mode === "hold" && !live.fadeAt) { live.fadeAt = now(); kickFrame(); } };
  // The harness: one instant, `phase` "hold" (x = p), "leap" (x = ms after the release) or "sticker" (x = ms).
  DP.still = function (name, phase, x, rect, seed) {
    if (!DP.has(name)) return false;
    stop(); var c = canvas(); c.clearRect(0, 0, innerWidth, innerHeight);
    return paint(c, DP[name], phase, x, env(name, rect, plan(name, seed || 7, false, 3)));
  };
  // The placeholder a stub registers: a blob in the character's colour that plays the whole flow.
  // A character replaces it with a def of its own (same five functions).
  DP.placeholder = function (name) {
    var col = T[name].color, ink = "#2b1a10";
    function home(e) { return Math.max(30, Math.min(e.rect.left - 24, 60)); }
    return {
      hold: function (p, e) {
        var a = backOut(seg(p, 0, 0.4), 2.2); if (a <= 0) return null;
        var q = squash(mix(1, 0.86, easeInOut(seg(p, 0.5, 1))));
        return { k: e.k, x: home(e), y: e.ground + 30 * (1 - a), sx: q.sx, sy: q.sy, alpha: clamp(a * 4), face: 1 };
      },
      leap: function (t, e) {
        var u = seg(t, 0, e.T.clear); if (t > e.T.clear) return null;
        var s = curveA(u), x = mix(home(e), -60, s), y = e.ground - 34 * Math.sin(PI * u) * e.plan.jitter;
        var q = squash(t < 40 ? mix(0.86, 1.12, t / 40) : mix(1.12, 1, seg(t, 40, 160)));
        var g = easeOut(seg(t, 0, e.T.clear * 0.35)), head = { x: x, y: y - 82 * e.k };
        var at = qbez({ x: e.rect.cx, y: e.rect.cy }, { x: mix(e.rect.cx, head.x, 0.5), y: Math.min(e.rect.cy, head.y) - 30 }, head, g);
        return { k: e.k, x: x, y: y, sx: q.sx, sy: q.sy, rot: -0.2 * Math.sin(PI * u), card: { cx: at.x, cy: at.y, s: mix(1, 0.3, g), rot: -0.1 * g } };
      },
      sticker: function (ms, e) {
        var a = Math.min(seg(ms, 0, e.all.stickerFade), 1 - seg(ms, e.all.stickerHold, e.all.stickerHold + e.all.stickerFade));
        return { k: e.k * 0.6, x: e.rect.left + e.rect.width * 0.2, y: e.rect.bottom - 6, alpha: a, shadow: false, blink: lid(ms - e.all.stickerBlink) };
      },
      draw: function (c, P, e) {
        c.save(); c.globalAlpha *= P.alpha === undefined ? 1 : P.alpha; applyM(c, rigM(P, 40));
        var lw = 2 / P.k, body = E(0, -38, 40, 36);
        strokeAll(c, [body], ink, lw); fillP(c, body, col); hilite(c, -16, -58, 10, 5, -0.5, 0.45);
        eye(c, -14, -44, 4.5, 5.5, P.blink, ink, lw); eye(c, 10, -45, 4.2, 5.2, P.blink, ink, lw);
        c.restore();
      }
    };
  };
  W.DPCourier = DP;
})(typeof window !== "undefined" ? window : this);
"""#
}
