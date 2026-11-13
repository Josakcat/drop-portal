//
//  WebCourierMatcha.swift
//  DropPortalCore
//
//  The Matcha Trio on the phone page (Duckling Parade): `DPCourier.register("ducks", def)`,
//  inserted after the toolkit in WebCourierEffect.swift. The approved mockup's
//  `drawDuck` rig (`.droppykit/design/fx-mockups-cute-v2/mockups.html`), one
//  duckling per file (three to five, `plan.actors`):
//
//  - hold: the ducklings pop in under the card one by one as p crosses
//    `ducklingStart` (0.2, 0.45, 0.7 for the trio), caps up to the card, and
//    mark time with the drag, each on its own phase;
//  - leap: a crouch (1.1 × 0.9), then the card hops onto their caps and they
//    march off the left edge on curve A, waddling ±8° on their own phases and
//    periods, the card bobbing; the gag (1 in 4): the last duckling trips at
//    t 200, pitches forward, its cap pops up, and it catches up; a soft
//    pitter-patter and peep when audio is allowed;
//  - sticker (Reduce motion): the ducklings in a row on the card's lower edge,
//    caps on, one blink.
//
//  Cap and tail lag the body on springs integrated over the last 300 ms.
//

enum WebCourierMatcha {
    static let script = #"""
(function (DP) {
  "use strict";
  var K = DP.kit, clamp = K.clamp, mix = K.mix, seg = K.seg, E = K.E, xf = K.xf, M = K.M, TAU = K.TAU, PI = K.PI, DEG = K.DEG;
  var O = "#2f3a24", G = "#a8d08d", SH = "#86b36c", CR = "#fff6ea", CO = "#ff8a65", COS = "#e8704c", CAP = "#2b3a5c", CAPS = "#1f2b47";
  var KD = 0.76, PERIOD = [120, 113, 127, 117, 124];

  function start(i, n) { return n > 1 ? 0.2 + 0.5 * i / (n - 1) : 0.2; }
  // Phone px per mockup px, and where the ducklings stand under the card.
  function lay(e) {
    var n = e.plan.actors, m = e.rect.width / 116, sp = n <= 3 ? 40 : Math.max(30, 120 / (n - 1)), xs = [];
    for (var i = 0; i < n; i++) xs.push(e.rect.cx + (i - (n - 1) / 2) * sp * m);
    var g = Math.min(e.H - 10 * m, e.rect.bottom + (92 * KD - 3) * m);
    return { n: n, m: m, k: KD * m, xs: xs, g: g };
  }
  function phase(i, t, seed) { return (t - i * 31 - K.hash((seed % 997) + i) * 22) / PERIOD[i % 5] * TAU; }
  function sat(x, m) { return m * Math.tanh(x / m); }
  // Cap and tail on springs driven by the duckling's acceleration (the mockup's GAINS).
  function springs(fx, t, t0) {
    var S = [[4, 0.3, -0.022, 0.4], [3.2, 0.3, -0.018, 0.6]], x = [0, 0], v = [0, 0], dt = 6, h = 8;
    for (var s = Math.max(t0, t - 300); s + dt <= t; s += dt) {
      var a = fx(s - h), b = fx(s), c = fx(s + h); if (a === null || b === null || c === null) continue;
      var acc = clamp((a - 2 * b + c) / (h * h) * 1e6, -60000, 60000);
      for (var j = 0; j < 2; j++) { var w = TAU * S[j][0], f = S[j][2] * acc - w * w * x[j] - 2 * S[j][1] * w * v[j]; v[j] += f * dt / 1000; x[j] += v[j] * dt / 1000; }
    }
    return { cap: sat(x[0], S[0][3]), tail: sat(x[1], S[1][3]) };
  }

  // ───────── leap: duckling i, t ms after the release (mockup px are scaled by L.m) ─────────
  function marcher(i, t, L, e) {
    var x0 = L.xs[i], last = i === L.n - 1, m = L.m, P = { x: x0, y: L.g, k: L.k, face: 1, eyes: "open" };
    if (t < 40) { var u0 = K.easeOut(seg(t, 0, 40)); P.sx = mix(1, 1.1, u0); P.sy = mix(1, 0.9, u0); return P; }
    var u = seg(t, 40, 400); if (u >= 1) return null;
    var s = K.curveA(u), ph = phase(i, t - 40, e.plan.seed), D = L.xs[L.n - 1] + 42 * m;
    var slope = (K.curveA(Math.min(1, u + 0.01)) - K.curveA(Math.max(0, u - 0.01))) / 0.02;
    P.x = x0 - D * s; P.y = L.g - 2.6 * m * Math.abs(Math.sin(ph)) * e.plan.jitter;
    P.rot = (last ? 0.17 : 0.14) * Math.sin(ph) * e.plan.jitter; P.step = Math.sin(ph);
    P.sx = 1 + 0.08 * clamp(slope / 2.5); P.sy = 1 / P.sx;
    if (e.plan.gag && last && t > 195 && t < 345) {
      var fall = K.easeOut(seg(t, 195, 235)), rise = t < 250 ? 1 : K.settle(t - 250, 4, 0.45);
      P.rot = -0.5 * fall * rise; P.x += 16 * m * Math.sin(PI * seg(t, 195, 345));
      P.eyes = t < 290 ? "squeeze" : "open"; P.step = t < 250 ? -1 : P.step;
      P.capLift = 9 * Math.sin(PI * seg(t, 200, 300)); P.capTilt = -0.45 * Math.sin(PI * seg(t, 200, 310));
      P.wing = 0.55 * Math.sin(PI * seg(t, 200, 290)); P.jaw = 0.6 * Math.sin(PI * seg(t, 205, 260));
    }
    return P;
  }

  // ───────── the rig: the mockup's drawDuck ─────────
  function rimShade(c, path, shade, base, dx, dy) { c.save(); c.clip(path); c.fillStyle = shade; c.fill(path); c.translate(dx, dy); c.fillStyle = base; c.fill(path); c.restore(); }
  function eye(c, x, y, rx, ry, st, bl, lw, dir) {
    c.save(); c.strokeStyle = O; c.lineCap = "round"; c.lineJoin = "round";
    if (st === "happy") { c.lineWidth = lw * 1.5; c.beginPath(); c.moveTo(x - rx * 1.15, y + ry * 0.35); c.quadraticCurveTo(x, y - ry * 1.25, x + rx * 1.15, y + ry * 0.35); c.stroke(); }
    else if (st === "squeeze") { c.lineWidth = lw * 1.5; c.beginPath(); c.moveTo(x - rx * dir * 1.05, y - ry * 0.85); c.lineTo(x + rx * dir * 0.95, y); c.lineTo(x - rx * dir * 1.05, y + ry * 0.85); c.stroke(); }
    else {
      var b = clamp(bl || 0);
      if (b > 0.82) { c.lineWidth = lw * 1.4; c.beginPath(); c.moveTo(x - rx * 1.1, y + ry * 0.1); c.quadraticCurveTo(x, y + ry * 0.85, x + rx * 1.1, y + ry * 0.1); c.stroke(); }
      else { c.fillStyle = O; c.fill(E(x, y + ry * b * 0.55, rx, ry * (1 - b * 0.92))); if (b < 0.45) { c.fillStyle = "#fff"; c.fill(E(x - rx * 0.3, y - ry * 0.36, rx * 0.42, ry * 0.34, -0.4)); c.globalAlpha *= 0.9; c.fill(E(x + rx * 0.36, y + ry * 0.38, rx * 0.19, rx * 0.19)); } }
    }
    c.restore();
  }
  function blush(c, x, y, rx, ry, a) { c.save(); c.globalAlpha *= a; c.fillStyle = "#ff9fb2"; c.fill(E(x, y, rx, ry)); c.globalAlpha *= 0.55; c.fillStyle = "#fff"; c.fill(E(x - rx * 0.35, y - ry * 0.3, rx * 0.22, ry * 0.22)); c.restore(); }
  function duck(c, P) {
    c.save(); c.globalAlpha *= P.alpha === undefined ? 1 : P.alpha;
    K.applyM(c, K.rigM(P, 40));
    var lw = (P.out || 2) / P.k, TM = K.rotAt(-2, -40, P.tilt || 0), stp = P.step || 0;
    function foot(x, lift, a) { return xf(E(-4, 0, 7.5, 3.6), M().translateSelf(x, -3 - Math.max(0, lift) * 5).rotateSelf(a * DEG)); }
    var f1 = foot(-4, stp, -stp * 0.3), f2 = foot(12, -stp, stp * 0.3);
    var tuft = xf(E(0, 0, 8.5, 5.6), M().translateSelf(35, -36).rotateSelf((-0.7 + (P.tail || 0)) * DEG));
    var body = E(8, -26, 30, 22), head = xf(E(-8, -57, 24.5, 23.5), TM);
    K.strokeAll(c, [f2, f1], O, lw); K.fillP(c, f2, COS); K.fillP(c, f1, CO);
    K.strokeAll(c, [tuft, body, head], O, lw); K.fillP(c, tuft, G); K.fillP(c, body, G); rimShade(c, body, SH, G, -4, -5);
    c.save(); c.clip(body); K.fillP(c, E(-4, -12, 21, 13), CR); c.restore();
    var wa = P.wing || 0, wing = xf(E(15, -28, 13.5, 8.6), M().translateSelf(5, -31).rotateSelf((-0.22 - wa) * DEG).translateSelf(-5, 31));
    c.strokeStyle = O; c.lineWidth = lw; c.stroke(wing); K.fillP(c, wing, SH);
    c.save(); c.clip(wing); c.globalAlpha *= 0.5; K.fillP(c, E(12, -31, 10, 4), "#c8e3b4"); c.restore();
    K.fillP(c, head, G); rimShade(c, head, SH, G, -4, -4);
    c.save(); K.applyM(c, TM); K.hilite(c, -18, -69, 7, 4, -0.6, 0.5);
    var jaw = P.jaw || 0, up = new Path2D(), lo0 = new Path2D();
    up.moveTo(-28, -54.5); up.bezierCurveTo(-36, -56, -43, -53, -42, -49.5); up.bezierCurveTo(-41, -46.5, -34, -46, -28, -47.2); up.closePath();
    lo0.moveTo(-28, -47.6); lo0.bezierCurveTo(-34, -47.2, -39, -46.6, -38.5, -44.4); lo0.bezierCurveTo(-37.8, -42.2, -32, -42.6, -28, -44.4); lo0.closePath();
    var lo = xf(lo0, K.rotAt(-28, -47, -jaw * 0.55));
    if (jaw > 0.05) { c.fillStyle = "#7a2e22"; c.fill(E(-33, -47.4, 5, 2.2 * jaw + 0.5)); }
    K.strokeAll(c, [lo, up], O, lw * 0.8); K.fillP(c, lo, COS); K.fillP(c, up, CO); K.fillP(c, E(-37, -52, 2.2, 1), "#ffc2a8");
    var st = P.eyes || "open", b = P.blink || 0;
    eye(c, -18, -57, 4.1, 5, st, b, lw, 1); eye(c, 3, -58.5, 3.6, 4.5, st, b, lw, -1);
    blush(c, -15, -47.5, 4.8, 2.8, 0.75); blush(c, 7, -48.5, 4.4, 2.6, 0.65);
    // The mail cap with a coral band, on a spring.
    c.save(); c.translate(-6, -75 - (P.capLift || 0)); c.rotate((P.cap || 0) + (P.capTilt || 0) - 0.08); c.translate(6, 75);
    var crown = new Path2D(); crown.moveTo(-23, -74); crown.bezierCurveTo(-23, -90, -8, -92, -4, -92); crown.bezierCurveTo(4, -92, 12, -88, 12, -74); crown.closePath();
    var visor = E(-26, -74, 10.5, 2.8, -0.12), band = new Path2D(); band.roundRect(-23.5, -79, 36, 5, 2);
    K.strokeAll(c, [visor, crown], O, lw * 0.85); K.fillP(c, visor, CAPS); K.fillP(c, crown, CAP); K.fillP(c, band, CO);
    K.fillP(c, E(-12, -86, 4, 2, -0.4), "#4b5d8a"); K.fillP(c, E(-4, -92, 2.6, 2), CO);
    c.restore(); c.restore(); c.restore();
  }

  // A quiet pitter-patter and a peep at the release, only where the page may play audio.
  var actx = null;
  function peep(gag) {
    try {
      var AC = window.AudioContext || window.webkitAudioContext; if (!AC) return;
      actx = actx || new AC(); if (actx.state === "suspended") actx.resume();
      var t0 = actx.currentTime + 0.01, out = actx.createGain(); out.gain.value = 0.12; out.connect(actx.destination);
      function tone(at, f0, f1, dur, type, vol) {
        var o = actx.createOscillator(), g = actx.createGain(); o.type = type; o.frequency.setValueAtTime(f0, at); o.frequency.exponentialRampToValueAtTime(f1, at + dur);
        g.gain.setValueAtTime(0.0001, at); g.gain.exponentialRampToValueAtTime(vol, at + 0.008); g.gain.exponentialRampToValueAtTime(0.0001, at + dur);
        o.connect(g); g.connect(out); o.start(at); o.stop(at + dur + 0.02);
      }
      for (var j = 0; j < 5; j++) tone(t0 + 0.04 + j * 0.06, j % 2 ? 300 : 340, 200, 0.035, "triangle", 0.5);
      tone(t0, 700, 1100, 0.08, "sine", 0.35);
      if (gag) { tone(t0 + 0.2, 150, 90, 0.12, "sine", 0.7); tone(t0 + 0.26, 1300, 700, 0.1, "sine", 0.3); }
    } catch (err) {}
  }

  DP.register("ducks", {
    hold: function (p, e) {
      var L = lay(e), ducks = [];
      for (var i = L.n - 1; i >= 0; i--) {
        var st = start(i, L.n), a = seg(p, st, st + 0.12); if (a <= 0) continue;
        var sc = K.backOut(a, 2.6), ph = p * 26 + i * 1.9;
        ducks.push({ x: L.xs[i], y: L.g, k: L.k, face: 1, sx: sc, sy: sc * (1 + 0.12 * Math.max(0, (1 - a) * a * 4)),
          tilt: 0.12 * seg(p, st + 0.1, st + 0.3), wing: 0.4 * K.kick((p - st) * 600, 6, 0.3), cap: -0.1 * K.kick((p - st) * 600, 4, 0.3),
          step: 0.6 * Math.sin(ph) * seg(p, st + 0.1, st + 0.25), rot: 0.05 * Math.sin(ph) * seg(p, st + 0.1, st + 0.25),
          blink: e.plan.blink(p * 600 + i * 911), shadow: 1, gy: L.g });
      }
      return { x: e.rect.cx, y: L.g, k: L.k, shadow: false, ducks: ducks, alpha: 1 };
    },
    leap: function (t, e) {
      if (t > e.T.clear) return null;
      if (!e._peeped && t < 60) { e._peeped = true; peep(e.plan.gag); }
      var L = lay(e), ducks = [], xs = [], ys = [];
      for (var i = L.n - 1; i >= 0; i--) {
        var P = marcher(i, t, L, e); if (!P) continue;
        if (t > 40) { var sp = springs(function (s) { var q = marcher(i, s, L, e); return q ? q.x / L.m : null; }, t, 40); P.cap = sp.cap; P.tail = sp.tail; }
        P.blink = P.eyes === "open" ? e.plan.blink(600 + t + i * 911) : 0; P.shadow = 1; P.gy = L.g;
        ducks.push(P);
        if (!(e.plan.gag && i === L.n - 1 && L.n > 1 && t > 195 && t < 345)) { xs.push(P.x); ys.push({ y: P.y, sy: P.sy || 1 }); }
      }
      var card = null;
      if (xs.length) {
        var cx = xs.reduce(function (a, b) { return a + b; }, 0) / xs.length - 2 * L.m, y0 = ys[0], ph = phase(1, t - 40, e.plan.seed);
        var top = y0.y - 92 * L.k * y0.sy, amp = t > 40 ? 1 : 0;
        var onX = cx, onY = top - e.rect.height / 2 + 3 * L.m + 3 * L.m * Math.sin(ph) * amp;
        // The card hops from where the finger let go onto their caps.
        var b = K.easeOut(seg(t, 0, 110)), q = K.qbez({ x: e.rect.cx, y: e.rect.cy }, { x: mix(e.rect.cx, onX, 0.5), y: Math.min(e.rect.cy, onY) - 14 * L.m }, { x: onX, y: onY }, b);
        var rot = 0.025 * Math.sin(ph * 0.5) * amp + (e.plan.gag ? -0.07 * Math.sin(PI * seg(t, 200, 340)) : 0);
        card = { cx: q.x, cy: q.y, s: 1, rot: rot };
      }
      return { x: e.rect.cx, y: L.g, k: L.k, shadow: false, ducks: ducks, card: card };
    },
    sticker: function (ms, e) {
      var a = Math.min(seg(ms, 0, e.all.stickerFade), 1 - seg(ms, e.all.stickerHold, e.all.stickerHold + e.all.stickerFade));
      var m = e.rect.width / 116, k = KD * m * 0.62, ducks = [], n = e.plan.actors, bl = K.lid(ms - e.all.stickerBlink);
      for (var i = n - 1; i >= 0; i--) ducks.push({ x: e.rect.left + e.rect.width * 0.22 + i * 30 * m * 0.8, y: e.rect.bottom - 4 * m, k: k, face: 1, tilt: 0.05 * (i - 1), blink: bl });
      return { x: e.rect.cx, y: e.rect.bottom, k: k, alpha: a, shadow: false, ducks: ducks };
    },
    draw: function (c, P, e) {
      c.save(); c.globalAlpha *= P.alpha === undefined ? 1 : P.alpha;
      var ds = P.ducks || [];
      for (var i = 0; i < ds.length; i++) {
        var d = ds[i];
        if (d.shadow) K.cshadow(c, d.x + 3 * d.k / KD, (d.gy || d.y) + 1, 34 * d.k / KD * Math.min(1, d.sx || 1), 1);
        duck(c, d);
      }
      c.restore();
    }
  });
})(window.DPCourier);
"""#
}
