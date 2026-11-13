//
//  WebCourierPip.swift
//  DropPortalCore
//
//  Pip the hamster on the phone page: `DPCourier.register("cheek", def)`,
//  inserted after the toolkit in WebCourierEffect.swift. Ported from the
//  approved mockup (`.droppykit/design/fx-mockups-cute-v2/mockups.html`,
//  "1. Cheek Stash": `drawHamster`, `hamPhone`, `hamCardPhone`):
//
//  - hold(p): Pip pops up under the card with a stretch, tilts its head
//    toward it, nibbles, raises its paws and leans in, mouth open and eyes
//    wide, cheeks already a little greedy;
//  - leap(t): the drawn card is sucked into its mouth (0–110 ms), the cheeks
//    balloon, a squash, then it rolls off the left edge on curve A with a
//    stretch on the fastest frames, a smear, dust and spilled seeds; null
//    once the edge is clear;
//  - sticker: Pip smiling under the card's corner, one blink, a fade;
//  - the rare gag (`plan.gag`): one big sunflower seed pops out of the
//    stuffed cheek and bounces.
//
//  Ears, splay and cheeks lag the body on the mockup's damped springs,
//  integrated over the body's own path, so `still` draws a live frame. The
//  toolkit has no audio, so the phone stays silent (Pip's sounds are the
//  Mac's, PipCourier.swift). See "How to add a courier" in effects.md.
//

enum WebCourierPip {
    static let script = #"""
(function (DP) {
  "use strict";
  var K = DP.kit, E = K.E, xf = K.xf, M = K.M, rotAt = K.rotAt, clamp = K.clamp, mix = K.mix, seg = K.seg;
  var easeOut = K.easeOut, easeIn = K.easeIn, easeInOut = K.easeInOut, backOut = K.backOut, settle = K.settle, kick = K.kick;
  var TAU = K.TAU, PI = K.PI, hash = K.hash, curveA = K.curveA;
  var O = "#3a2414", FUR = "#f2a65a", SH = "#d98840", CR = "#fff6ea", PK = "#ffc0ae", BL = "#ff9fb2";
  var kP = 0.62;
  function slope(f, u) { return (f(Math.min(1, u + 0.01)) - f(Math.max(0, u - 0.01))) / 0.02; }
  function fillP(c, p, col) { c.fillStyle = col; c.fill(p); }

  // ───────── the rig (the mockup's drawHamster) ─────────
  // Built on first use: the tests load the script where there is no Path2D.
  var HAMB_ = null;
  function hamb() {
    if (HAMB_) return HAMB_;
    var p = new Path2D(); p.moveTo(0, -92); p.bezierCurveTo(30, -92, 50, -70, 50, -42); p.bezierCurveTo(50, -14, 31, -1, 0, -1);
    p.bezierCurveTo(-31, -1, -50, -14, -50, -42); p.bezierCurveTo(-50, -70, -30, -92, 0, -92); p.closePath(); HAMB_ = p; return p;
  }
  function eye(c, x, y, rx, ry, st, bl, o, lw, dir) {
    c.save(); c.strokeStyle = o; c.lineCap = "round"; c.lineJoin = "round";
    if (st === "happy") { c.lineWidth = lw * 1.5; c.beginPath(); c.moveTo(x - rx * 1.15, y + ry * 0.35); c.quadraticCurveTo(x, y - ry * 1.25, x + rx * 1.15, y + ry * 0.35); c.stroke(); }
    else if (st === "squeeze") { c.lineWidth = lw * 1.5; c.beginPath(); c.moveTo(x - rx * dir * 1.05, y - ry * 0.85); c.lineTo(x + rx * dir * 0.95, y); c.lineTo(x - rx * dir * 1.05, y + ry * 0.85); c.stroke(); }
    else {
      var b = clamp(bl || 0), sc = st === "wide" ? 1.15 : 1; rx *= sc; ry *= sc;
      if (b > 0.82) { c.lineWidth = lw * 1.4; c.beginPath(); c.moveTo(x - rx * 1.1, y + ry * 0.1); c.quadraticCurveTo(x, y + ry * 0.85, x + rx * 1.1, y + ry * 0.1); c.stroke(); }
      else {
        c.fillStyle = o; c.fill(E(x, y + ry * b * 0.55, rx, ry * (1 - b * 0.92)));
        if (b < 0.45) { c.fillStyle = "#fff"; c.fill(E(x - rx * 0.3, y - ry * 0.36, rx * 0.42, ry * 0.34, -0.4)); c.globalAlpha *= 0.9; c.fill(E(x + rx * 0.36, y + ry * 0.38, rx * 0.19, rx * 0.19)); }
      }
    }
    c.restore();
  }
  function blushAt(c, x, y, rx, ry, col) { c.save(); c.globalAlpha *= 0.8; c.fillStyle = col; c.fill(E(x, y, rx, ry)); c.globalAlpha *= 0.55; c.fillStyle = "#fff"; c.fill(E(x - rx * 0.35, y - ry * 0.3, rx * 0.22, ry * 0.22)); c.restore(); }
  function mouth(c, x, y, kind, o, lw, s) {
    c.save(); c.strokeStyle = o; c.lineWidth = lw * 1.1; c.lineCap = "round"; c.lineJoin = "round"; c.beginPath();
    if (kind === "o") { c.fillStyle = o; c.fill(E(x, y + 1.2 * s, 2.6 * s, 3.2 * s)); c.fillStyle = "#ff8a9a"; c.fill(E(x, y + 2.6 * s, 1.6 * s, 1.2 * s)); }
    else if (kind === "puff") { c.moveTo(x - 2 * s, y + s); c.lineTo(x + 2 * s, y + s); c.stroke(); }
    else if (kind === "smile") { c.moveTo(x - 3.4 * s, y); c.quadraticCurveTo(x, y + 3.4 * s, x + 3.4 * s, y); c.stroke(); }
    else { c.moveTo(x - 4 * s, y); c.quadraticCurveTo(x - 2 * s, y + 2.6 * s, x, y + 0.4 * s); c.quadraticCurveTo(x + 2 * s, y + 2.6 * s, x + 4 * s, y); c.stroke(); }
    c.restore();
  }
  // `flat`: a tinted silhouette only (the smear's ghosts).
  function drawHamster(c, P, sp, flat) {
    sp = sp || {};
    c.save(); c.globalAlpha *= P.alpha === undefined ? 1 : P.alpha;
    var m = K.rigM(P, 46), HAMB = hamb(); K.applyM(c, m);
    var lw = 2 / P.k, lx = P.lookX === undefined ? -3 : P.lookX, ly = P.lookY || 0;
    var ch = Math.max(0.8, (P.cheek === undefined ? 1 : P.cheek) + (sp.cheek || 0)), TM = rotAt(0, -46, P.tilt || 0);
    var ea = (P.ear || 0) + (sp.ear || 0), spl = (sp.splay || 0) + (P.splay || 0);
    function earRot(sx) { return rotAt(sx * 24, -76, ea + sx * (spl + 0.12)); }
    var earL = xf(E(-26, -84, 11.5, 10.5), TM, earRot(-1)), earR = xf(E(26, -84, 11.5, 10.5), TM, earRot(1));
    var cx = 34 + (ch - 1) * 8, cr = 12 * ch, cy = -40;
    var chL = xf(E(lx * 0.5 - cx, cy + ly * 0.4, cr, cr * 0.92), TM), chR = xf(E(lx * 0.5 + cx, cy + ly * 0.4, cr, cr * 0.92), TM);
    var feet = [E(-20, -4, 10, 6), E(20, -4, 10, 6)];
    function paw(sx, u) { return xf(E(0, 0, 5, 3.9), M().translateSelf(lx * 0.55 + sx * (12 - u * 2), -22 - u * 9), M().rotateSelf(sx * (25 + u * 25))); }
    var pawL = paw(-1, P.pawL || 0), pawR = paw(1, P.pawR || 0);
    if (flat) { c.fillStyle = flat; [feet[0], feet[1], earL, earR, HAMB, chL, chR, pawL, pawR].forEach(function (p) { c.fill(p); }); c.restore(); return; }
    K.strokeAll(c, [feet[0], feet[1], earL, earR, HAMB, chL, chR], O, lw);
    fillP(c, feet[0], PK); fillP(c, feet[1], PK);
    [[earL, -1], [earR, 1]].forEach(function (q) {
      var sx = q[1]; fillP(c, q[0], FUR); c.save(); c.clip(q[0]); c.fillStyle = "#ffb3a4"; c.fill(xf(E(sx * 26, -86, 6.5, 6), TM, earRot(sx))); c.restore();
    });
    fillP(c, HAMB, FUR); K.rimShade(c, HAMB, SH, FUR, -5, -6);
    c.save(); c.clip(HAMB); fillP(c, E(0, -14, 31, 22), CR); c.restore();
    fillP(c, chL, FUR); fillP(c, chR, FUR);
    if (ch > 1.08) {
      c.save(); c.strokeStyle = O; c.globalAlpha *= 0.45 * clamp((ch - 1.08) * 4); c.lineWidth = lw * 0.8; c.lineCap = "round"; K.applyM(c, TM);
      [-1, 1].forEach(function (sx) { c.beginPath(); c.arc(lx * 0.5 + sx * cx, cy + ly * 0.4, cr * 0.82, sx < 0 ? -0.6 : PI - 0.9, sx < 0 ? 0.9 : PI + 0.6); c.stroke(); });
      c.restore();
    }
    K.hilite(c, -22, -74, 10, 5.5, -0.55, 0.5);
    c.save(); K.applyM(c, TM);
    fillP(c, E(lx, -41 + ly, 15, 10.5), CR);
    var st = P.eyes || "open", b = P.blink || 0;
    eye(c, lx - 17, -53 + ly, 5.2, 6.3, st, b, O, lw, 1); eye(c, lx + 17, -53 + ly, 5.2, 6.3, st, b, O, lw, -1);
    var bx = 17 + (ch - 1) * 12; blushAt(c, lx * 0.5 - bx - 7, -40 + ly, 7.5, 4.2, BL); blushAt(c, lx * 0.5 + bx + 7, -40 + ly, 7.5, 4.2, BL);
    fillP(c, E(lx, -46.5 + ly, 2.9, 2.1), "#d9687a");
    mouth(c, lx, -42.8 + ly + (P.chew ? Math.abs(P.chew) : 0) * 0.8, P.mouth || "w", O, lw, 0.9);
    c.save(); c.strokeStyle = O; c.globalAlpha *= 0.55; c.lineWidth = lw * 0.6; c.lineCap = "round";
    [-1, 1].forEach(function (sx) { [-2.5, 2].forEach(function (dy) {
      c.beginPath(); c.moveTo(lx + sx * 12, -43 + ly + dy * 0.5); c.quadraticCurveTo(lx + sx * 24, -45 + ly + dy, lx + sx * (36 + (P.whisk || 0)), -46 + ly + dy * 1.6); c.stroke();
    }); });
    c.restore(); c.restore();
    K.strokeAll(c, [pawL, pawR], O, lw * 0.6); fillP(c, pawL, "#ffd2c2"); fillP(c, pawR, "#ffd2c2");
    c.restore();
  }
  // The mouth on the page: the toolkit's rigM in plain maths (the poses need no DOM).
  function mul(m, n) { return [m[0] * n[0] + m[2] * n[1], m[1] * n[0] + m[3] * n[1], m[0] * n[2] + m[2] * n[3], m[1] * n[2] + m[3] * n[3], m[0] * n[4] + m[2] * n[5] + m[4], m[1] * n[4] + m[3] * n[5] + m[5]]; }
  function Tm(x, y) { return [1, 0, 0, 1, x, y]; }
  function Rm(a) { var c = Math.cos(a), s = Math.sin(a); return [c, s, -s, c, 0, 0]; }
  function Sm(x, y) { return [x, 0, 0, y, 0, 0]; }
  function hamMouth(P) {
    var cy = 46, m = Tm(P.x, P.y), f = P.face === undefined ? 1 : P.face;
    if (P.vs && P.vs !== 1) { var h = cy * P.k; m = mul(m, Tm(0, -h)); m = mul(m, Sm(P.vs, 1 / P.vs)); m = mul(m, Tm(0, h)); }
    if (P.rot) m = mul(m, Rm(P.rot));
    var b = P.breath || 0; m = mul(m, Sm((P.sx || 1) / (1 + b * 0.6), (P.sy || 1) * (1 + b)));
    m = mul(m, Sm(P.k * f, P.k));
    if (P.spin) { m = mul(m, Tm(0, -cy)); m = mul(m, Rm(P.spin * f)); m = mul(m, Tm(0, cy)); }
    m = mul(m, mul(Tm(0, -46), mul(Rm(P.tilt || 0), Tm(0, 46))));
    var x = P.lookX === undefined ? -3 : P.lookX, y = -42 + (P.lookY || 0);
    return { x: m[0] * x + m[2] * y + m[4], y: m[1] * x + m[3] * y + m[5] };
  }

  // ───────── props ─────────
  function seed(c, x, y, rot, s, a) {
    if (a <= 0) return;
    c.save(); c.globalAlpha *= a; c.translate(x, y); c.rotate(rot); c.scale(s, s);
    c.beginPath(); c.moveTo(0, -5); c.quadraticCurveTo(3.4, -1, 0, 5); c.quadraticCurveTo(-3.4, -1, 0, -5);
    c.fillStyle = "#3a2f2a"; c.fill(); c.strokeStyle = "#1d1612"; c.lineWidth = 0.8; c.stroke();
    c.strokeStyle = "#e8e0d0"; c.lineWidth = 0.9; c.beginPath(); c.moveTo(0, -3.6); c.lineTo(0, 3.6); c.stroke(); c.restore();
  }
  function puffs(c, x, y, age, n, dir, spread, sd, size, col) {
    if (age < 0 || age > 420) return; var u = age / 420; c.save();
    for (var i = 0; i < n; i++) {
      var a = (hash(sd + i) - 0.5) * PI * 0.9 * spread + (dir < 0 ? PI : dir > 0 ? 0 : -PI / 2) + (dir === 0 ? (i / (n - 1 || 1) - 0.5) * PI * 1.4 : 0);
      var d = (10 + hash(sd + i * 3) * 12) * size * easeOut(u * 1.4), r = (3 + hash(i + sd * 7) * 3.5) * size * (0.6 + u * 0.9);
      c.globalAlpha = 0.55 * Math.pow(1 - u, 1.4); c.fillStyle = "rgb(" + col + ")";
      c.beginPath(); c.arc(x + Math.cos(a) * d, y - Math.abs(Math.sin(a)) * d * 0.55 - u * 6 * size, r, 0, TAU); c.fill();
    }
    c.restore();
  }
  // Two earlier poses as flat tinted silhouettes at 40% and 20% (the mockup's ghosts).
  var GH = null;
  function ghosts(c, t, poseAt, sp, tint) {
    if (typeof document === "undefined") return;
    var W = c.canvas.width, H = c.canvas.height;
    if (!GH) GH = document.createElement("canvas");
    if (GH.width !== W || GH.height !== H) { GH.width = W; GH.height = H; }
    var g = GH.getContext("2d"), tr = c.getTransform();
    [[34, 0.2], [17, 0.4]].forEach(function (q) {
      var P = poseAt(t - q[0]); if (!P) return;
      g.setTransform(1, 0, 0, 1, 0, 0); g.clearRect(0, 0, W, H); g.setTransform(tr);
      var Q = {}; for (var k in P) Q[k] = P[k]; Q.alpha = 1;
      drawHamster(g, Q, sp, tint);
      c.save(); c.setTransform(1, 0, 0, 1, 0, 0); c.globalAlpha *= q[1]; c.drawImage(GH, 0, 0); c.restore();
    });
  }

  // ───────── the choreography ─────────
  // The page's px per mockup px, Pip's spot and its ground.
  function geo(e) {
    // Never smaller than the mockup's Pip on its phone (201 px wide), less a fifth.
    var f = Math.max(e.k / kP, e.W / 201 * 0.8);
    return { f: f, k: kP * f, x0: Math.max(30 * f, Math.min(53 * f, e.W * 0.32)), g: Math.min(e.H - 18, e.rect.bottom + 62 * f) };
  }
  // Held at p: pops up, tilts to the card, nibbles, paws up, leans in hungry.
  function holdPose(p, e) {
    var G = geo(e), f = G.f, a = seg(p, 0, 0.42), pop = backOut(a, 2.4);
    if (a <= 0) return null;
    var P = { k: G.k, x: G.x0, y: G.g + 40 * f * (1 - pop), face: 1, lookX: -2, lookY: -1.5 * seg(p, 0.1, 0.4), cheek: 1, mouth: "w", alpha: clamp(a * 6), shadow: false };
    var st = Math.max(0, (1 - a) * a * 4); P.sy = 1 + 0.16 * st; P.sx = 1 / P.sy;
    P.tilt = 0.17 * easeInOut(seg(p, 0.12, 0.4)); P.pawL = P.pawR = easeOut(seg(p, 0.24, 0.46));
    if (p > 0.28 && p <= 0.5) P.chew = Math.sin((p - 0.28) * 140);
    if (p > 0.5) {
      var s = easeInOut(seg(p, 0.5, 1));
      P.sx = mix(1, 1.15, s); P.sy = mix(1, 0.87, s); P.tilt = mix(0.17, -0.06, s);
      P.cheek = 1 + 0.15 * easeInOut(seg(p, 0.6, 1)); P.chew = Math.sin(p * 80) * (1 - s);
      P.mouth = s > 0.55 ? "o" : "w"; P.eyes = s > 0.55 ? "wide" : "open";
      P.pawL = P.pawR = mix(1, 0.65, s); P.lookX = mix(-2, -6, s); P.lookY = mix(-1.5, 0, s);
    }
    P.ear = 0.3 * kick((p - 0.08) * 600, 5, 0.3);
    return P;
  }
  // After the release: gulp (0–110), the stuffed squash (110–170), the roll out (170–400).
  function leapPose(t, e) {
    var G = geo(e), f = G.f, j = e.plan.jitter;
    if (t < 0) t = 0;
    if (t < 110) {
      var P = holdPose(1, e), g = seg(t, 40, 110);
      P.cheek = mix(1.15, 1.6, easeIn(g)); P.mouth = "o"; P.eyes = g > 0.7 ? "open" : "wide"; P.lookX = -6;
      P.chew = 0; P.ear = 0; P.rot = -0.04 * Math.sin(PI * seg(t, 0, 110)); return P;
    }
    if (t < 170) {
      var u = seg(t, 110, 170);
      return { k: G.k, x: G.x0, y: G.g, face: 1, lookX: -6, cheek: 1.6 + 0.2 * Math.sin(u * PI / 2), sx: mix(1.15, 1.2, u), sy: mix(0.87, 0.83, u),
               mouth: u < 0.6 ? "o" : "puff", pawL: 0.6 * (1 - u), pawR: 0.6 * (1 - u), rot: 0.06 * u, eyes: "open", shadow: false };
    }
    var w = seg(t, 170, 400), s = curveA(w), sl = slope(curveA, w) / 2.2;
    return { k: G.k, x: mix(G.x0, Math.min(G.x0 - 114 * f, -44 * f), s), y: G.g - 3 * f * j * Math.abs(Math.sin(s * TAU)), face: 1, lookX: -6,
             cheek: 1.7 + 0.1 * settle(t - 170, 6, 0.35), spin: -TAU * s, vs: 1 + 0.1 * clamp(sl) + (t > 350 ? 0.15 * seg(t, 350, 395) : 0), va: 0,
             eyes: "squeeze", mouth: "puff", shadow: false };
  }
  // Ears, splay and cheeks: the mockup's GAINS springs, pushed by the body's acceleration (mock px).
  function springs(t, poseAt, f) {
    var dt = 2, span = 600, h = 8, n = span / dt, t0 = t - span, pts = [];
    for (var i = -4; i <= n + 4; i++) { var P = poseAt(t0 + i * dt); pts.push(P ? { x: P.x / f, y: P.y / f } : null); }
    var S = [[4.5, 0.28, -0.028, 0, 0.55], [4, 0.32, -0.008, 1, 0.35], [5, 0.3, -0.003, 1, 0.14]].map(function (g) { return { w: TAU * g[0], z: g[1], k: g[2], y: g[3], m: g[4], x: 0, v: 0 }; });
    var L = 60000;
    for (var s = 0; s < n; s++) {
      var a = pts[s], b = pts[s + 4], c = pts[s + 8], ax = 0, ay = 0;
      if (a && b && c) { ax = clamp((a.x - 2 * b.x + c.x) / (h * h) * 1e6, -L, L); ay = clamp((a.y - 2 * b.y + c.y) / (h * h) * 1e6, -L, L); }
      S.forEach(function (q) { var F = q.k * (q.y ? ay : ax), acc = F - q.w * q.w * q.x - 2 * q.z * q.w * q.v; q.v += acc * 0.002; q.x += q.v * 0.002; });
    }
    function sat(q) { return q.m * Math.tanh(q.x / q.m); }
    return { ear: sat(S[0]), splay: sat(S[1]), cheek: sat(S[2]) };
  }
  function cardAt(t, e) {
    var r = e.rect, G = geo(e);
    if (t < 110) {
      var g = easeInOut(seg(t, 0, 110)), m = hamMouth(leapPose(t, e));
      var q = K.qbez({ x: r.cx, y: r.cy }, { x: mix(r.cx, m.x, 0.35), y: Math.min(r.cy, m.y) - 34 * G.f }, m, g);
      return { cx: q.x, cy: q.y, s: mix(1, 0.17, Math.pow(g, 0.8)), rot: mix(0, -0.45, g) };
    }
    if (t < 170) { var m2 = hamMouth(leapPose(t, e)); return { cx: m2.x, cy: m2.y, s: 0.17 * (1 - easeIn(seg(t, 110, 160))), rot: -0.45 }; }
    return null;
  }
  function shadowUnder(c, P, e, a) {
    var G = geo(e), lift = Math.max(0, G.g - P.y);
    K.cshadow(c, P.x, G.g + 1, 32 * G.f * (1 - Math.min(0.8, lift / (120 * G.f))), a * (1 - Math.min(1, lift / (60 * G.f))));
  }

  DP.register("cheek", {
    hold: function (p, e) { var P = holdPose(p, e); if (P) { P.phase = "hold"; P.sp = { ear: 0, splay: 0, cheek: 0 }; } return P; },
    leap: function (t, e) {
      if (t > e.T.clear) return null;
      var P = leapPose(t, e); P.phase = "leap"; P.t = t;
      P.sp = springs(t, function (x) { return leapPose(x, e); }, geo(e).f);
      P.card = cardAt(t, e);
      return P;
    },
    sticker: function (ms, e) {
      var f = geo(e).f, all = e.all;
      var a = Math.min(seg(ms, 0, all.stickerFade), 1 - seg(ms, all.stickerHold, all.stickerHold + all.stickerFade));
      return { k: geo(e).k * 0.85, x: Math.min(e.W - 40 * f, e.rect.right - 14 * f), y: Math.min(e.H - 10, e.rect.bottom + 52 * f), face: 1, lookX: -3, pawL: 0, pawR: 1,
               mouth: "smile", tilt: 0.06, alpha: a, shadow: false, blink: K.lid(ms - all.stickerBlink), phase: "sticker" };
    },
    // Behind: the contact shadow and the roll's smear.
    extra: function (c, phase, x, e) {
      if (phase === "hold") { var H = holdPose(x, e); if (H) shadowUnder(c, H, e, H.alpha); return; }
      if (phase !== "leap" || x > e.T.clear) return;
      var P = leapPose(x, e); shadowUnder(c, P, e, 1);
      if (x > 350 && x < 430) ghosts(c, x, function (t) { return leapPose(t, e); }, {}, "#ffd3a2");
    },
    // Pip, then in front: dust, spilled seeds and the gag's seed.
    draw: function (c, P, e) {
      drawHamster(c, P, P.sp);
      if (P.phase !== "leap") return;
      var t = P.t, G = geo(e), f = G.f;
      if (t >= 170) puffs(c, G.x0 + 18 * f, G.g - 2 * f, t - 170, 4, 1, 0.8, 3, 0.8 * f, "255,250,240");
      for (var i = 0; i < 4; i++) {
        var tb = 140 + i * 45, age = t - tb; if (age < 0 || age > 140) continue;
        var b = leapPose(tb, e), s = age / 1000, vx = -40 + (hash(i + 2) - 0.5) * 140, vy = -150 - hash(i + 7) * 90;
        seed(c, b.x + vx * s * f, b.y - 30 * f + (vy * s + 1400 * s * s) * f, hash(i) * 6 + age * 0.02, 1.5 * f, 1 - easeIn(age / 140));
      }
      if (e.plan.gag && t > 120) {
        // The gag: one big seed pops out of the stuffed cheek and bounces.
        var a2 = t - 120, sec = a2 / 1000, m = hamMouth(leapPose(120, e)), y0 = m.y, floor = G.g - 3 * f;
        var y = y0 + (-220 * sec + 1500 * sec * sec) * f, yy = y;
        if (y > floor) { var land = (220 + Math.sqrt(220 * 220 + 4 * 1500 * (floor - y0) / f)) / 3000 * 1000; yy = floor - Math.max(0, 22 * f * kick(a2 - land, 3, 0.4) * 1.4); }
        seed(c, m.x + 70 * sec * f, Math.min(yy, floor), a2 * 0.012, 2 * f, 1 - seg(t, 340, e.T.clear));
      }
    }
  });
})(window.DPCourier);
"""#
}
