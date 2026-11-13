//
//  WebCourierTofu.swift
//  DropPortalCore
//
//  Tofu the cat on the phone page: `DPCourier.register("pounce", def)`, inserted
//  after the toolkit in WebCourierEffect.swift. The approved mockup's rig
//  (`.droppykit/design/fx-mockups-cute-v2/mockups.html`, `drawCat`, `catPhone`,
//  `flap`), in the mockup's phone units scaled to the card (116 units = the
//  card's width):
//
//  - hold (p 0 → 1): Tofu trots in from the right under the card, crouches
//    (1.15 × .85 by p), winds the tail up and watches the card; a hinged cat
//    flap grows on the left edge. Nothing loops while held.
//  - leap: the card's corner snaps to the mouth, Tofu leaps on curve A through
//    the flap (stretch along the velocity, 1.25 at the exit, two tinted ghosts),
//    the tail whips through after the body, the flap swings and settles shut
//    (spring) and fades by the edge's clear time.
//  - sticker (Reduce motion): the happy pose with a paw up, one blink, no travel.
//
//  Poses need no DOM (the tests run them in JavaScriptCore); only `draw` and
//  `extra` touch Path2D and the canvas.
//

enum WebCourierTofu {
    static let script = #"""
(function (DP) {
  "use strict";
  var K = DP.kit, clamp = K.clamp, mix = K.mix, seg = K.seg, E = K.E, xf = K.xf, M = K.M, rotAt = K.rotAt;
  var easeOut = K.easeOut, easeIn = K.easeIn, easeInOut = K.easeInOut, backOut = K.backOut, curveA = K.curveA;
  var settle = K.settle, kick = K.kick, hash = K.hash, qbez = K.qbez, TAU = K.TAU, PI = K.PI, DEG = K.DEG;
  var O = "#2b1a10", COAT = "#f2a03d", SH = "#c8661e", CR = "#fff3e2", PK = "#f59aa8";

  // ───────── geometry (pure maths, no DOM) ─────────
  // The mockup's phone, mapped onto the page: its card (116 wide) is the dragged card,
  // its left edge (x 65) the page's, its ground (340) the toolkit's ground.
  function geo(e) {
    var sc = e.rect.width / 116;
    return { sc: sc, x0: e.rect.cx + 18 * sc, g: e.ground, fx: 7 * sc, fy: e.ground - 46 * sc, fh: 70,
             out: -57 * sc, start: e.W + 46 * sc };
  }
  // A point of the rig (drawing units) on the page: rigM(P, cy) without DOMMatrix.
  function rigPt(P, cy, x, y) {
    var f = P.face === undefined ? 1 : P.face, b = P.breath || 0, r, c, s, nx;
    x *= P.k * f; y *= P.k;
    x *= (P.sx || 1) / (1 + b * 0.6); y *= (P.sy || 1) * (1 + b);
    if (P.rot) { r = P.rot; c = Math.cos(r); s = Math.sin(r); nx = x * c - y * s; y = x * s + y * c; x = nx; }
    if (P.vs && P.vs !== 1) {
      var h = cy * P.k, va = P.va || 0;
      y += h;
      c = Math.cos(-va); s = Math.sin(-va); nx = x * c - y * s; y = x * s + y * c; x = nx;
      x *= P.vs; y /= P.vs;
      c = Math.cos(va); s = Math.sin(va); nx = x * c - y * s; y = x * s + y * c; x = nx;
      y -= h;
    }
    return { x: P.x + x, y: P.y + y };
  }
  // The mouth: (-17, -38) turned with the head about (-4, -36).
  function mouthPt(P) {
    var t = P.tilt || 0, dx = -13, dy = -2, c = Math.cos(t), s = Math.sin(t);
    return rigPt(P, 38, -4 + dx * c - dy * s, -36 + dx * s + dy * c);
  }
  // The card held by its top right corner in the mouth, hanging down and forward.
  function carried(P, e, wob, s) {
    var m = mouthPt(P), r = -0.05 + wob + (P.rot || 0) * 0.5, sc = e.rect.width / 116;
    var a = e.rect.width * s / 2 - 6 * sc, b = e.rect.height * s / 2 - 6 * sc;
    return { cx: m.x - Math.cos(r) * a + Math.sin(r) * b, cy: m.y + Math.cos(r) * b - Math.sin(r) * a, rot: r, s: s };
  }

  // ───────── poses ─────────
  // Held: trots in under the card, crouches, tail winds up, watches the card.
  function holdPose(p, e) {
    var G = geo(e), a = seg(p, 0, 0.4), ee = easeOut(a);
    if (a <= 0) return null;
    var x = mix(G.start, G.x0, ee);
    var P = { k: e.k, x: x, y: G.g, face: 1, mouth: "w" };
    var g = Math.sin((G.start - x) / G.sc * 0.2);
    P.step = g * (1 - ee) * 1.1; P.y -= 1.6 * G.sc * Math.abs(g) * (1 - ee);
    var cr = easeInOut(seg(p, 0.35, 1));
    P.sx = mix(1, 1.15, cr); P.sy = mix(1, 0.85, cr);
    P.tail = mix(0, 0.44, easeInOut(p));
    P.tilt = 0.14 * easeInOut(seg(p, 0.2, 0.55)) * (1 - seg(p, 0.7, 1)) - 0.05 * seg(p, 0.75, 1);
    P.lookY = -1.5 * seg(p, 0.2, 0.55) * (1 - seg(p, 0.7, 1));
    P.rot = -0.07 * cr; P.legF = -0.2 * cr; P.legB = 0.2 * cr;
    // The ears lean forward as it locks on, the trot's bounce settles them.
    P.ear = -0.12 * cr + 0.08 * Math.sin((G.start - x) / G.sc * 0.2) * (1 - ee);
    P.eyes = p > 0.82 ? "wide" : "open"; P.mouth = p > 0.7 ? "puff" : "w";
    return P;
  }
  // The leap's path: curve A from the crouch into the flap, an arc on the way.
  function path(t, e) {
    var G = geo(e), u = seg(t, 40, 300), s = curveA(u);
    return { x: mix(G.x0, G.out, s), y: mix(G.g, G.fy + 18 * G.sc, s) - 200 * G.sc * e.plan.jitter * s * (1 - s), u: u };
  }
  function leapBody(t, e) {
    var G = geo(e);
    if (t < 0) return holdPose(1, e);
    if (t < 40) {
      var u0 = seg(t, 0, 40);
      return { k: e.k, x: G.x0, y: G.g, face: 1, sx: mix(1.15, 1.2, u0), sy: mix(0.85, 0.83, u0), rot: -0.09,
               legF: -0.25, legB: 0.25, tail: 0.5, ear: -0.14, eyes: "wide", mouth: "puff" };
    }
    if (t > 330) return null;
    var q = path(t, e), a = path(t - 8, e), b = path(t + 8, e), vx = (b.x - a.x) / 16, vy = (b.y - a.y) / 16, u = q.u;
    var P = { k: e.k, x: q.x, y: q.y, face: 1, eyes: "open", mouth: "puff", tilt: 0.12,
              legF: mix(0.2, 1.2, easeOut(u * 2)), legB: mix(-0.2, -1.15, easeOut(u * 2)) };
    P.rot = clamp(-Math.atan2(vy, -vx || -1e-3) * 0.8, -0.6, 0.6);
    P.va = Math.atan2(vy, vx);
    P.vs = t > 220 ? mix(1.15, 1.25, seg(t, 220, 250)) : mix(1, 1.15, clamp(u * 3));
    // Follow-through: the tail trails the take-off and whips as the body goes through; the ears fold back.
    P.tail = 0.5 + 0.45 * kick(t - 40, 4, 0.35) + 0.5 * kick(t - 230, 6, 0.3);
    P.ear = -0.3 * easeOut(seg(t, 40, 110)) + 0.12 * kick(t - 40, 5, 0.3);
    return P;
  }

  function leap(t, e) {
    if (t > e.T.clear) return null;
    var G = geo(e), P = leapBody(t, e);
    // Past the flap: nothing but the flap swinging shut (extra) until the edge is clear.
    if (!P) return { k: e.k, x: -1e4, y: G.g, alpha: 0, shadow: false };
    // The card's corner snaps to the mouth in 90 ms, then dangles behind the leap.
    var g = easeOut(seg(t, 0, 90)), wob = 0.22 * kick(t - 40, 4, 0.3) - 0.12 * kick(t - 200, 5, 0.35);
    var to = carried(P, e, wob, 0.3);
    if (t < 40) { to.cy += 4 * G.sc * easeOut(t / 40); to.rot -= 0.05 * easeOut(t / 40); }
    var from = { x: e.rect.cx, y: e.rect.cy };
    var at = qbez(from, { x: mix(from.x, to.cx, 0.5) + 10 * G.sc, y: Math.min(from.y, to.cy) - 10 * G.sc }, { x: to.cx, y: to.cy }, g);
    P.card = { cx: at.x, cy: at.y, s: mix(1, 0.3, g), rot: mix(-0.035, to.rot, g) };
    P.cardBehind = true;
    P.t = t; P.ghost = t > 220 && t < 320; P.clip = G.fx - 1;
    return P;
  }

  // Reduce motion: the happy pose with a paw up on the card, one blink.
  function sticker(ms, e) {
    var a = Math.min(seg(ms, 0, e.all.stickerFade), 1 - seg(ms, e.all.stickerHold, e.all.stickerHold + e.all.stickerFade));
    var bl = K.lid(ms - e.all.stickerBlink), k = e.k * 0.72;
    return { k: k, x: e.rect.right - e.rect.width * 0.08 + 8 * k, y: e.rect.bottom + 2, face: 1,
             eyes: bl > 0.5 ? "open" : "happy", blink: bl > 0.5 ? 1 : 0, mouth: "open", legF: 0.9, tail: 0.4, tilt: 0.05,
             alpha: a, shadow: false };
  }

  // ───────── drawing (the mockup's drawCat) ─────────
  var EARP = null, GH = null;
  function earPath() {
    if (EARP) return EARP;
    var p = new Path2D(); p.moveTo(-11, 3); p.quadraticCurveTo(-9, -12, -2, -19); p.quadraticCurveTo(0, -21.5, 2.4, -19.2);
    p.quadraticCurveTo(9.5, -12, 11, 3); p.closePath(); return (EARP = p);
  }
  function capsule(x, y, len, w, a) { var p = new Path2D(); p.roundRect(-w / 2, -w / 2, w, len + w / 2, w / 2); return xf(p, M().translateSelf(x, y).rotateSelf(a * DEG)); }
  function eye(c, x, y, rx, ry, st, bl, lw, dir) {
    c.save(); c.strokeStyle = O; c.lineCap = "round"; c.lineJoin = "round";
    if (st === "happy") { c.lineWidth = lw * 1.5; c.beginPath(); c.moveTo(x - rx * 1.15, y + ry * 0.35); c.quadraticCurveTo(x, y - ry * 1.25, x + rx * 1.15, y + ry * 0.35); c.stroke(); }
    else if (st === "squeeze") { c.lineWidth = lw * 1.5; c.beginPath(); c.moveTo(x - rx * dir * 1.05, y - ry * 0.85); c.lineTo(x + rx * dir * 0.95, y); c.lineTo(x - rx * dir * 1.05, y + ry * 0.85); c.stroke(); }
    else {
      var b = clamp(bl || 0), sc = st === "wide" ? 1.15 : 1; rx *= sc; ry *= sc;
      if (b > 0.82) { c.lineWidth = lw * 1.4; c.beginPath(); c.moveTo(x - rx * 1.1, y + ry * 0.1); c.quadraticCurveTo(x, y + ry * 0.85, x + rx * 1.1, y + ry * 0.1); c.stroke(); }
      else {
        c.fillStyle = O; c.fill(E(x, y + ry * b * 0.55, rx, ry * (1 - b * 0.92)));
        if (b < 0.45) { c.fillStyle = "#fff"; c.fill(E(x - rx * 0.3, y - ry * 0.36, rx * 0.42, ry * 0.34, -0.4)); c.globalAlpha *= 0.9; c.fill(E(x + rx * 0.36, y + ry * 0.38, rx * 0.19, rx * 0.19)); }
      }
    }
    c.restore();
  }
  function blushAt(c, x, y, rx, ry) { c.save(); c.globalAlpha *= 0.8; c.fillStyle = PK; c.fill(E(x, y, rx, ry)); c.globalAlpha *= 0.55; c.fillStyle = "#fff"; c.fill(E(x - rx * 0.35, y - ry * 0.3, rx * 0.22, ry * 0.22)); c.restore(); }
  function mouth(c, x, y, kind, lw, s) {
    c.save(); c.strokeStyle = O; c.lineWidth = lw * 1.1; c.lineCap = "round"; c.lineJoin = "round"; c.beginPath();
    if (kind === "open") { c.moveTo(x - 4 * s, y); c.quadraticCurveTo(x, y + 0.5 * s, x + 4 * s, y); c.quadraticCurveTo(x, y + 6 * s, x - 4 * s, y); c.fillStyle = O; c.fill(); c.fillStyle = "#ff8a9a"; c.fill(E(x, y + 3.3 * s, 2.2 * s, 1.4 * s)); }
    else if (kind === "puff") { c.moveTo(x - 2 * s, y + s); c.lineTo(x + 2 * s, y + s); c.stroke(); }
    else if (kind === "smile") { c.moveTo(x - 3.4 * s, y); c.quadraticCurveTo(x, y + 3.4 * s, x + 3.4 * s, y); c.stroke(); }
    else { c.moveTo(x - 4 * s, y); c.quadraticCurveTo(x - 2 * s, y + 2.6 * s, x, y + 0.4 * s); c.quadraticCurveTo(x + 2 * s, y + 2.6 * s, x + 4 * s, y); c.stroke(); }
    c.restore();
  }
  function ears(c, eL, eR, TM, ea) {
    var ep = earPath();
    K.fillP(c, eL, COAT); K.fillP(c, eR, COAT);
    c.save(); c.fillStyle = PK;
    c.fill(xf(ep, TM, M().translateSelf(-35, -73).rotateSelf((-0.42 + ea) * DEG).scaleSelf(0.55, 0.6).translateSelf(0, -3)));
    c.fill(xf(ep, TM, M().translateSelf(3, -78).rotateSelf((0.28 + ea) * DEG).scaleSelf(0.55, 0.6).translateSelf(0, -3)));
    c.restore();
  }
  function face(c, P, TM, lw) {
    c.save(); K.applyM(c, TM); var head = E(-14, -53, 35, 29);
    c.save(); c.clip(head); c.fillStyle = SH; c.globalAlpha = 0.8;
    [[-24, -0.25], [-14, 0], [-4, 0.25]].forEach(function (s) { c.beginPath(); c.ellipse(s[0], -80, 2.6, 8, s[1], 0, TAU); c.fill(); });
    c.restore();
    K.hilite(c, -32, -70, 9, 5, -0.6, 0.45);
    var lx = P.lookX || 0, ly = P.lookY || 0; K.fillP(c, E(-19 + lx * 0.5, -42.5 + ly * 0.5, 14, 9), CR);
    var st = P.eyes || "open", b = P.blink || 0;
    eye(c, -31 + lx, -51 + ly, 4.8, 5.9, st, b, lw, 1); eye(c, -4 + lx, -52 + ly, 4.6, 5.6, st, b, lw, -1);
    blushAt(c, -39 + lx * 0.6, -42 + ly, 5.5, 3.3); blushAt(c, 4 + lx * 0.6, -43.5 + ly, 5.5, 3.3);
    var nx = -18.5 + lx * 0.6, ny = -46.8 + ly * 0.6;
    c.fillStyle = "#e2788a"; c.beginPath(); c.moveTo(nx - 2.6, ny - 1.2); c.quadraticCurveTo(nx, ny - 2.2, nx + 2.6, ny - 1.2);
    c.quadraticCurveTo(nx + 0.6, ny + 2, nx, ny + 2); c.quadraticCurveTo(nx - 0.6, ny + 2, nx - 2.6, ny - 1.2); c.fill();
    mouth(c, nx, ny + 3.2, P.mouth || "w", lw, 0.8);
    c.save(); c.strokeStyle = O; c.globalAlpha *= 0.5; c.lineWidth = lw * 0.55; c.lineCap = "round";
    [[-44, -1.5], [-41.5, 1.5]].forEach(function (w) { c.beginPath(); c.moveTo(nx - 9, w[0]); c.quadraticCurveTo(nx - 20, w[0] + w[1] - 1, nx - 29, w[0] + w[1] * 2); c.stroke(); });
    c.restore(); c.restore();
  }
  function drawCat(c, P) {
    c.save(); c.globalAlpha *= P.alpha === undefined ? 1 : P.alpha;
    K.applyM(c, K.rigM(P, 38)); var lw = 2 / P.k, ep = earPath();
    var TM = rotAt(-4, -36, P.tilt || 0), ea = P.ear || 0;
    var eL = xf(ep, TM, M().translateSelf(-35, -73).rotateSelf((-0.42 + ea) * DEG));
    var eR = xf(ep, TM, M().translateSelf(3, -78).rotateSelf((0.28 + ea) * DEG));
    var head = xf(E(-14, -53, 35, 29), TM);
    // The tail: an outlined stroke with dashed stripes.
    c.save(); c.translate(40, -30); c.rotate(P.tail || 0);
    var tp = new Path2D(); tp.moveTo(0, 0); tp.bezierCurveTo(16, -2, 24, -16, 20, -32); tp.bezierCurveTo(18, -40, 11, -44, 7, -39);
    c.lineCap = "round"; c.strokeStyle = O; c.lineWidth = 9 + lw * 2; c.stroke(tp); c.strokeStyle = COAT; c.lineWidth = 9; c.stroke(tp);
    c.strokeStyle = SH; c.lineWidth = 4.5; c.setLineDash([3.5, 6]); c.lineDashOffset = -6; c.stroke(tp); c.setLineDash([]); c.restore();
    var lf = P.legF || 0, lb = P.legB || 0, stp = P.step || 0;
    var far = [capsule(-21, -14, 13, 9.5, lf * 0.85 - stp * 0.4), capsule(27, -14, 13, 9.5, lb * 0.85 + stp * 0.4)];
    K.strokeAll(c, far, O, lw); far.forEach(function (f) { K.fillP(c, f, SH); });
    var body = E(13, -27, 31, 20.5), aF = lf + stp * 0.4, aB = lb - stp * 0.4;
    var near = [capsule(-9, -14, 13, 10, aF), capsule(37, -14, 13, 10, aB)];
    K.strokeAll(c, [body].concat(near, [eL, eR, head]), O, lw);
    K.fillP(c, body, COAT); K.rimShade(c, body, SH, COAT, -4, -5);
    c.save(); c.clip(body); c.fillStyle = SH; c.globalAlpha = 0.75;
    [18, 28].forEach(function (x) { c.beginPath(); c.ellipse(x, -46, 3, 9, 0.2, 0, TAU); c.fill(); });
    c.globalAlpha = 1; K.fillP(c, E(-6, -22, 13, 13), CR); c.restore();
    near.forEach(function (n) { K.fillP(c, n, COAT); });
    [[-9, aF], [37, aB]].forEach(function (l) { c.save(); c.clip(capsule(l[0], -14, 13, 10, l[1])); c.fillStyle = CR; c.fill(xf(E(0, 13, 7, 5), M().translateSelf(l[0], -14).rotateSelf(l[1] * DEG))); c.restore(); });
    ears(c, eL, eR, TM, ea); K.fillP(c, head, COAT); K.rimShade(c, head, SH, COAT, -4, -5);
    face(c, P, TM, lw);
    c.restore();
  }
  // Smear: two earlier poses as flat tinted silhouettes at 40% and 20%.
  function ghosts(c, P, e) {
    var W = c.canvas.width, H = c.canvas.height;
    if (!GH) GH = document.createElement("canvas");
    if (GH.width !== W || GH.height !== H) { GH.width = W; GH.height = H; }
    var g = GH.getContext("2d"), tr = c.getTransform();
    [[34, 0.2], [17, 0.4]].forEach(function (d) {
      var Q = leapBody(P.t - d[0], e); if (!Q) return;
      g.setTransform(1, 0, 0, 1, 0, 0); g.globalCompositeOperation = "source-over"; g.clearRect(0, 0, W, H);
      g.setTransform(tr); Q.blink = 0; drawCat(g, Q);
      g.setTransform(1, 0, 0, 1, 0, 0); g.globalCompositeOperation = "source-atop"; g.fillStyle = "#ffd08a"; g.fillRect(0, 0, W, H);
      g.globalCompositeOperation = "source-over";
      c.save(); c.setTransform(1, 0, 0, 1, 0, 0); c.globalAlpha *= d[1]; c.drawImage(GH, 0, 0); c.restore();
    });
  }
  function draw(c, P, e) {
    if ((P.alpha === undefined ? 1 : P.alpha) <= 0) return;
    // The card has gone through the flap where it is past the hinge line: the flap covers it again.
    if (P.clip !== undefined && P.card) { c.save(); c.beginPath(); c.rect(-1e4, -1e4, 1e4 + P.clip + 1, 2e4); c.clip(); drawFlap(c, "leap", P.t, e); c.restore(); }
    c.save();
    if (P.clip !== undefined) { c.beginPath(); c.rect(P.clip, -1e4, 1e5, 2e4); c.clip(); }
    if (P.ghost) ghosts(c, P, e);
    drawCat(c, P);
    c.restore();
  }

  // ───────── the flap and the puffs ─────────
  // A hinged cat flap on the left edge: a dark frame, the hole, a cream panel
  // with a paw print, swinging on its top hinge by `ang` (radians).
  function flap(c, F, side, amt, ang, sc) {
    if (amt <= 0) return;
    c.save(); c.translate(F.x, F.y); c.scale(amt * sc, amt * sc); var H = F.h, W = H * 0.46;
    c.transform(1, side * 0.12, 0, 1, 0, 0);
    c.fillStyle = O; c.beginPath(); c.roundRect(-W / 2 - 5, -H / 2 - 5, W + 10, H + 10, W * 0.42); c.fill();
    c.fillStyle = "#120a05"; c.beginPath(); c.roundRect(-W / 2, -H / 2, W, H, W * 0.36); c.fill();
    var top = -H / 2 + 4, len = H - 10, cs = Math.cos(ang), sn = Math.sin(ang);
    c.save(); c.beginPath(); c.roundRect(-W / 2, -H / 2, W, H, W * 0.36); c.clip();
    var by = top + len * Math.abs(cs), bx = -side * sn * W * 0.55;
    c.fillStyle = cs > 0 ? "rgba(255,217,160,.9)" : "rgba(214,170,118,.9)";
    c.beginPath(); c.moveTo(-W / 2 + 3, top); c.lineTo(W / 2 - 3, top); c.lineTo(W / 2 - 3 + bx, by);
    c.quadraticCurveTo(bx, by + 6 * Math.abs(cs), -W / 2 + 3 + bx, by); c.closePath(); c.fill();
    c.strokeStyle = "rgba(43,26,16,.5)"; c.lineWidth = 1.3; c.stroke();
    if (Math.abs(cs) > 0.5) {
      c.save(); c.translate(bx * 0.6, (top + by) / 2); c.scale(1, Math.abs(cs)); c.fillStyle = "#c9905e"; c.globalAlpha = 0.8;
      c.beginPath(); c.ellipse(0, 3, 3.6, 3, 0, 0, TAU); c.fill();
      [[-4, -2.5], [-1.4, -4.6], [1.4, -4.6], [4, -2.5]].forEach(function (q) { c.beginPath(); c.arc(q[0], q[1], 1.4, 0, TAU); c.fill(); });
      c.restore();
    }
    c.restore(); c.fillStyle = "#5b3b26"; c.beginPath(); c.roundRect(-W / 2 - 2, top - 3, W + 4, 4, 2); c.fill(); c.restore();
  }
  function puffs(c, x, y, age, n, dir, spread, seed, size) {
    if (age < 0 || age > 420) return; var u = age / 420; c.save();
    for (var i = 0; i < n; i++) {
      var a = (hash(seed + i) - 0.5) * PI * 0.9 * spread + (dir < 0 ? PI : dir > 0 ? 0 : -PI / 2);
      var d = (10 + hash(seed + i * 3) * 12) * size * easeOut(u * 1.4), r = (3 + hash(i + seed * 7) * 3.5) * size * (0.6 + u * 0.9);
      c.globalAlpha = 0.55 * Math.pow(1 - u, 1.4); c.fillStyle = "rgb(255,250,240)";
      c.beginPath(); c.arc(x + Math.cos(a) * d, y - Math.abs(Math.sin(a)) * d * 0.55 - u * 6 * size, r, 0, TAU); c.fill();
    }
    c.restore();
  }
  // The flap's size and swing: grows with p; swings in as Tofu goes through,
  // then springs shut (−43° → +10° → 0) and fades by the edge's clear time.
  function flapAt(phase, x, e) {
    if (phase === "hold") return { amt: backOut(easeOut(seg(x, 0.1, 0.6)), 1.6), ang: 0 };
    var t = x, ang = 0, clear = e.T.clear;
    if (t >= 215 && t < 300) ang = -0.75 * easeOut(seg(t, 215, 250));
    else if (t >= 300) ang = -0.75 * settle(t - 300, 3.2, 0.3);
    return { amt: 1 - easeIn(seg(t, clear - 80, clear)), ang: ang };
  }
  function drawFlap(c, phase, x, e) {
    var G = geo(e), f = flapAt(phase, x, e);
    flap(c, { x: G.fx, y: G.fy, h: G.fh }, -1, f.amt, f.ang, G.sc);
  }
  function extra(c, phase, x, e) {
    if (phase === "sticker") return;
    drawFlap(c, phase, x, e);
    var G = geo(e);
    if (phase === "leap" && x >= 40 && x < 400) puffs(c, G.x0 + 16 * G.sc, G.g, x - 40, 5, 1, 0.8, 5, 0.8 * G.sc);
  }

  DP.register("pounce", { hold: holdPose, leap: leap, sticker: sticker, draw: draw, extra: extra });
})(window.DPCourier);
"""#
}
