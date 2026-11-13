//
//  WebCourierDigby.swift
//  DropPortalCore
//
//  Digby the mole on the phone page: `DPCourier.register("mole", def)`,
//  inserted after the toolkit in WebCourierEffect.swift. While the finger
//  holds the card a dirt mound bulges near the left edge under it, two
//  hairline cracks run out and, past p 0.5, Digby surfaces with his hard hat
//  right under the card. On the release he crouches, the card hops onto his
//  helmet, and he digs straight DOWN into the mound on curve A, paws
//  wiggling, a few clods spraying both ways and a dashed tunnel running down
//  to the bottom of the screen; the soil closes over him, the mound flattens
//  and the tunnel fades (clear at `T.clear`). The carried
//  card is the toolkit's (`P.card`, behind him); `extra` clips it to above
//  the ground so it goes under with him. Reduce motion:
//  his head and helmet out of a small hill on the card's corner, saluting,
//  one blink.
//
//  The rig and beats are the approved mockup's (`.droppykit/design/
//  fx-mockups-cute-v2/mockups.html`, "Mole Express": `drawMole`, `molePhone`,
//  `mound`, `moundLip`, `crack`, `tunnel`, `crumbs`, `ghosts`), in its phone
//  pixels scaled by the card's width (116 wide in the mockup). Paths are made
//  on first use: the tests run this script in JavaScriptCore, which has no
//  Path2D.
//

enum WebCourierDigby {
    static let script = #"""
(function (DP) {
  "use strict";
  var K = DP.kit, E = K.E, clamp = K.clamp, mix = K.mix, seg = K.seg, PI = K.PI, TAU = K.TAU, DEG = K.DEG;
  var easeOut = K.easeOut, easeIn = K.easeIn, easeInOut = K.easeInOut, hash = K.hash;
  var O = "#2b1a10", FUR = "#7a5a48", SH = "#5e4334", LT = "#b58e76", PK = "#f39aa8", HY = "#ffcf3a", HYS = "#e5a51f",
      PALM = "#f2b2a4", CLAW = "#fbeee0";
  // The mockup's phone scale, its outline (2 px) in drawing units, and how far the card hops onto the helmet.
  var kP = 0.62, LW = 2 / kP, ON_HEAD = 0.55;
  function slope(f, u) { return (f(Math.min(1, u + 0.01)) - f(Math.max(0, u - 0.01))) / 0.02; }

  // ───────── the rig (the mockup's drawMole) ─────────
  var paths = null;
  function P2() { return new Path2D(); }
  function rig() {
    if (paths) return paths;
    var body = P2(); body.moveTo(0, -90); body.bezierCurveTo(24, -90, 39, -72, 41, -50); body.bezierCurveTo(43, -26, 40, -1, 0, -1);
    body.bezierCurveTo(-40, -1, -43, -26, -41, -50); body.bezierCurveTo(-39, -72, -24, -90, 0, -90); body.closePath();
    var shov = P2(); shov.ellipse(0, 6, 10.5, 9, 0, 0, TAU); [-6, 0, 6].forEach(function (x) { shov.moveTo(x + 3.6, 14); shov.arc(x, 14, 3.6, 0, TAU); });
    var dome = P2(); dome.moveTo(-35, -63); dome.bezierCurveTo(-35, -86, -19, -97, 0, -97); dome.bezierCurveTo(19, -97, 35, -86, 35, -63); dome.closePath();
    var brim = P2(); brim.roundRect(-40, -67, 80, 8.5, 4.25);
    var nose = P2();
    for (var i = 0; i < 8; i++) { var a = i * TAU / 8, x = Math.cos(a) * 4.1, y = -41 + Math.sin(a) * 3.6; nose.moveTo(x + 2.4, y); nose.arc(x, y, 2.4, 0, TAU); }
    nose.moveTo(2.8, -41); nose.arc(0, -41, 2.8, 0, TAU);
    paths = { body: body, shov: shov, dome: dome, brim: brim, nose: nose, feet: [E(-16, -3, 10, 5.5), E(16, -3, 10, 5.5)] };
    return paths;
  }
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
  function blush(c, x, y, rx, ry) { c.save(); c.globalAlpha *= 0.7; c.fillStyle = PK; c.fill(E(x, y, rx, ry)); c.globalAlpha *= 0.55; c.fillStyle = "#fff"; c.fill(E(x - rx * 0.35, y - ry * 0.3, rx * 0.22, ry * 0.22)); c.restore(); }
  function mouth(c, x, y, kind, lw, s) {
    c.save(); c.strokeStyle = O; c.lineWidth = lw * 1.1; c.lineCap = "round"; c.lineJoin = "round"; c.beginPath();
    if (kind === "o") { c.fillStyle = O; c.fill(E(x, y + 1.2 * s, 2.6 * s, 3.2 * s)); c.fillStyle = "#ff8a9a"; c.fill(E(x, y + 2.6 * s, 1.6 * s, 1.2 * s)); }
    else if (kind === "puff") { c.moveTo(x - 2 * s, y + s); c.lineTo(x + 2 * s, y + s); c.stroke(); }
    else { c.moveTo(x - 3.4 * s, y); c.quadraticCurveTo(x, y + 3.4 * s, x + 3.4 * s, y); c.stroke(); }
    c.restore();
  }
  function drawMole(c, P) {
    var R = rig(), lw = LW;
    c.save(); c.globalAlpha *= P.alpha === undefined ? 1 : P.alpha;
    K.applyM(c, K.rigM(P, 44));
    K.strokeAll(c, R.feet.concat([R.body]), O, lw); R.feet.forEach(function (f) { K.fillP(c, f, PALM); });
    K.fillP(c, R.body, FUR); K.rimShade(c, R.body, SH, FUR, -5, -6);
    c.save(); c.clip(R.body); K.fillP(c, E(0, -14, 25, 16), LT); c.restore();
    K.hilite(c, -24, -62, 7, 4, -0.9, 0.25);
    // The head turns about its neck.
    c.save(); K.applyM(c, K.rotAt(0, -40, P.tilt || 0));
    K.fillP(c, E(0, -38, 14, 10), LT);
    var st = P.eyes || "open", b = P.blink || 0, lx = P.lookX || 0;
    eye(c, -14 + lx, -51, 4.1, 4.9, st, b, lw, 1); eye(c, 14 + lx, -51, 4.1, 4.9, st, b, lw, -1);
    blush(c, -25 + lx * 0.5, -41, 6, 3.4); blush(c, 25 + lx * 0.5, -41, 6, 3.4);
    c.save(); c.translate(lx, 0); c.strokeStyle = O; c.lineWidth = lw * 1.4; c.stroke(R.nose); K.fillP(c, R.nose, PK); K.fillP(c, E(-1.4, -42.6, 1.6, 1.1), "#ffd3da"); c.restore();
    mouth(c, lx, -32.5, P.mouth || "smile", lw, 0.85);
    // The hard hat and its lamp.
    K.strokeAll(c, [R.dome, R.brim], O, lw); K.fillP(c, R.dome, HY);
    c.save(); c.clip(R.dome); c.fillStyle = HYS; c.fill(E(14, -60, 30, 20)); c.restore(); K.fillP(c, R.brim, HYS);
    c.save(); c.globalAlpha *= 0.6; c.strokeStyle = "#fff8d8"; c.lineWidth = 3; c.lineCap = "round"; c.beginPath(); c.arc(0, -63, 27, PI * 1.18, PI * 1.42); c.stroke(); c.restore();
    var lamp = E(0, -81, 8.2, 8.2); c.strokeStyle = O; c.lineWidth = lw * 2; c.stroke(lamp); K.fillP(c, lamp, "#9aa3ad");
    K.fillP(c, E(0, -81, 5.6, 5.6), "#fff6c8"); K.fillP(c, E(-1.8, -83, 1.8, 1.5), "#fff");
    c.restore();
    // Shovel paws; the right one salutes.
    var sal = P.salute || 0, pv = { x: 31, y: -44 }, ang = mix(72, -112, sal) / DEG, len = mix(15, 24, sal) - 9 * Math.sin(PI * clamp(sal));
    var pr = { x: pv.x + Math.cos(ang) * len, y: pv.y + Math.sin(ang) * len };
    function pawM(x, y, a, f) { return K.M().translateSelf(x, y).rotateSelf(a * DEG).scaleSelf(f, 1); }
    [pawM(-26, -34, 0.5 + (P.pawL || 0), -1), pawM(pr.x, pr.y, mix(-0.5, -3.3, sal), 1)].forEach(function (PM) {
      var s = K.xf(R.shov, PM); c.strokeStyle = O; c.lineWidth = lw * 2; c.stroke(s); K.fillP(c, s, CLAW);
      K.fillP(c, K.xf(E(0, 5, 10.5, 8.4), PM), PALM); K.fillP(c, K.xf(E(0, 3, 5, 3.6), PM), "#f7c9be");
    });
    c.restore();
  }

  // ───────── the ground (the mockup's mound, moundLip, crack, tunnel, crumbs) ─────────
  // Cracks and the tunnel are soil-coloured, not ink, so they read on a dark page too.
  // Each draws in mockup pixels about (x, y), scaled by m.
  function mound(c, x, y, w, h, m, seedN) {
    if (h <= 0.3) return;
    c.save(); c.translate(x, y); c.scale(m, m);
    var p = P2(); p.moveTo(-w, 1); p.bezierCurveTo(-w * 0.75, -h * 0.25, -w * 0.55, -h, -w * 0.1, -h); p.bezierCurveTo(w * 0.35, -h * 1.04, w * 0.65, -h * 0.5, w, 1); p.closePath();
    c.strokeStyle = O; c.lineWidth = 4; c.lineJoin = "round"; c.stroke(p); c.fillStyle = "#8b5e3c"; c.fill(p);
    c.save(); c.clip(p); c.fillStyle = "#74492c"; c.fill(E(w * 0.4, 0, w * 0.8, h * 0.7)); c.fillStyle = "#a8774f";
    for (var i = 0; i < 6; i++) { c.beginPath(); c.ellipse((hash(i + seedN) - 0.5) * w * 1.3, -h * (0.25 + hash(i * 3 + seedN) * 0.6), 1.8 + hash(i) * 1.6, 1.4 + hash(i + 2), 0, 0, TAU); c.fill(); }
    c.fillStyle = "rgba(255,230,200,.35)"; c.fill(E(-w * 0.3, -h * 0.8, w * 0.25, h * 0.12, -0.2)); c.restore();
    c.restore();
  }
  function moundLip(c, x, y, w, h, m) {
    if (h <= 0.3) return;
    c.save(); c.translate(x, y); c.scale(m, m);
    var lh = h * 0.5, p = P2(); p.moveTo(-w * 0.9, 1); p.bezierCurveTo(-w * 0.7, -lh * 0.7, -w * 0.35, -lh, 0, -lh); p.bezierCurveTo(w * 0.35, -lh, w * 0.7, -lh * 0.7, w * 0.9, 1); p.closePath();
    c.strokeStyle = O; c.lineWidth = 4; c.lineJoin = "round"; c.stroke(p); c.fillStyle = "#93643f"; c.fill(p);
    c.save(); c.clip(p); c.fillStyle = "#7a4d2f"; c.fill(E(w * 0.35, 2, w * 0.7, lh * 0.6)); c.fillStyle = "#b5845a";
    for (var i = 0; i < 4; i++) { c.beginPath(); c.ellipse((hash(i + 9) - 0.5) * w * 1.2, -lh * (0.3 + hash(i * 7) * 0.5), 1.7, 1.3, 0, 0, TAU); c.fill(); }
    c.restore(); c.restore();
  }
  function crack(c, pts, u, a, m) {
    if (u <= 0 || a <= 0) return;
    c.save(); c.globalAlpha *= a * 0.9; c.strokeStyle = "#a8774f"; c.lineWidth = 2 * m; c.lineCap = "round"; c.lineJoin = "round";
    var n = pts.length - 1, f = u * n; c.beginPath(); c.moveTo(pts[0][0], pts[0][1]);
    for (var i = 1; i <= n; i++) {
      if (i <= f) c.lineTo(pts[i][0], pts[i][1]);
      else { var r = f - (i - 1); if (r > 0) c.lineTo(mix(pts[i - 1][0], pts[i][0], r), mix(pts[i - 1][1], pts[i][1], r)); break; }
    }
    c.stroke(); c.restore();
  }
  function tunnel(c, x0, y0, x1, y1, u, a, m) {
    if (u <= 0 || a <= 0) return;
    c.save(); c.globalAlpha *= 0.8 * a; c.setLineDash([6 * m, 6 * m]); c.strokeStyle = "#a8774f"; c.lineWidth = 3 * m; c.lineCap = "round";
    c.beginPath(); c.moveTo(x0, y0); c.lineTo(mix(x0, x1, clamp(u)), mix(y0, y1, clamp(u))); c.stroke(); c.restore();
  }
  function crumbs(c, x, y, age, n, dir, seed, life, m) {
    if (age < 0 || age > life) return;
    var s = age / 1000; c.save(); c.globalAlpha *= 1 - easeIn(age / life);
    for (var i = 0; i < n; i++) {
      var vx = dir * (40 + hash(seed + i) * 150) + (hash(i + 9) - 0.5) * 60, vy = -(120 + hash(seed + i * 5) * 170);
      var px = x + (vx * s) * m, py = y + (vy * s + 900 * s * s) * m, r = (1.6 + hash(i + seed) * 2.4) * m;
      c.fillStyle = i % 3 ? "#8b5e3c" : "#b08060"; c.strokeStyle = O; c.lineWidth = 0.8 * m;
      c.beginPath(); c.ellipse(px, py, r * 1.15, r, hash(i) * 3, 0, TAU); c.fill(); c.stroke();
    }
    c.restore();
  }
  // The smear: two earlier poses as flat tinted silhouettes at 40% and 20%.
  var GH = null;
  function ghosts(c, t, e) {
    var W = c.canvas.width, H = c.canvas.height;
    if (!GH) GH = document.createElement("canvas");
    if (GH.width !== W || GH.height !== H) { GH.width = W; GH.height = H; }
    var g = GH.getContext("2d"), tr = c.getTransform();
    [[34, 0.2], [17, 0.4]].forEach(function (d) {
      var Q = def.leap(t - d[0], e); if (!Q || Q.hidden) return;
      g.setTransform(1, 0, 0, 1, 0, 0); g.globalCompositeOperation = "source-over"; g.clearRect(0, 0, W, H);
      g.setTransform(tr); drawMole(g, Q);
      g.setTransform(1, 0, 0, 1, 0, 0); g.globalCompositeOperation = "source-atop"; g.fillStyle = "#c9a58e"; g.fillRect(0, 0, W, H); g.globalCompositeOperation = "source-over";
      c.save(); c.setTransform(1, 0, 0, 1, 0, 0); c.globalAlpha *= d[1]; c.drawImage(GH, 0, 0); c.restore();
    });
  }

  // ───────── where he digs ─────────
  // Mockup pixels per page pixel from the card (116 wide), the mound 47 px in from the
  // left edge, the ground 70 px under the card so his helmet meets it. The hold keeps it
  // on the plan, so the release digs where the hold surfaced.
  function geo(e, hold) {
    if (hold || !e.plan._digby) {
      var m = e.rect.width / 116;
      e.plan._digby = { m: m, x: 47 * m, ground: Math.min(e.H - 24, e.rect.bottom + 70 * m) };
    }
    return e.plan._digby;
  }
  // A point of the drawing on the page through the toolkit's rigM (cy 44), in plain maths:
  // pose functions also run where there is no DOMMatrix.
  function pt(P, x, y) {
    var f = P.face === undefined ? 1 : P.face, b = P.breath || 0;
    x *= P.k * f * (P.sx || 1) / (1 + b * 0.6); y *= P.k * (P.sy || 1) * (1 + b);
    var r = P.rot || 0, c = Math.cos(r), s = Math.sin(r), X = x * c - y * s, Y = x * s + y * c;
    if (P.vs && P.vs !== 1) {
      var h = 44 * P.k, a = P.va || 0, ca = Math.cos(a), sa = Math.sin(a);
      Y += h; var u = X * ca + Y * sa, v = -X * sa + Y * ca; u *= P.vs; v /= P.vs; X = u * ca - v * sa; Y = u * sa + v * ca - h;
    }
    return { x: P.x + X, y: P.y + Y };
  }
  // The card flat on the hard hat's top (the drawing's 0, -97).
  function onHead(P, e) {
    var tp = pt(P, 0, -97), rot = P.rot || 0, hh = e.rect.height * ON_HEAD;
    return { cx: tp.x + Math.sin(rot) * hh / 2, cy: tp.y - Math.cos(rot) * hh / 2, rot: rot, s: ON_HEAD };
  }

  // The mound's height after the release, mockup pixels: it flattens as the edge clears.
  function leapMound(t) { return 28 * (1 - easeIn(seg(t, 280, 450))); }

  var def = {
    // The finger holds the card at p: the mound bulges, then he surfaces under it.
    hold: function (p, e) {
      var G = geo(e, true), m = G.m, r = easeOut(seg(p, 0.5, 1)), st = Math.max(0, (1 - r) * r * 4);
      return { ph: "hold", t: p, G: G, k: e.k, x: G.x, y: G.ground + m * (-8 + (1 - r) * 100 * kP), sy: 1 + 0.08 * st, sx: 1 / (1 + 0.08 * st),
               tilt: 0.1 * seg(p, 0.75, 1), lookX: 1.5 * seg(p, 0.75, 1), mouth: "smile", hidden: p < 0.5, shadow: false };
    },
    // The release: crouch, the card onto his helmet, then straight down into the mound.
    leap: function (t, e) {
      if (t > e.T.clear) return null;
      var G = geo(e, false), m = G.m, P;
      if (t < 60) {
        var u0 = easeOut(seg(t, 0, 60));
        P = { x: G.x, y: G.ground + m * (-8 + 3 * u0), sx: mix(1, 1.15, u0), sy: mix(1, 0.85, u0), mouth: "puff" };
      } else if (t <= 300) {
        var u = seg(t, 60, 280), s = K.curveA(u);
        // A little hop up, then down the hole, wiggling side to side as he digs.
        var dig = Math.sin(u * TAU * 3) * (1 - s);
        P = { x: G.x + m * 3 * dig, y: G.ground + m * (-5 - 16 * e.plan.jitter * Math.sin(PI * Math.min(1, u * 1.7)) * (1 - s) + s * 110),
              rot: 0.12 * dig, eyes: "squeeze", mouth: "puff", pawL: 0.5 * dig, vs: 1 + 0.15 * clamp(slope(K.curveA, u) / 2), va: PI / 2 };
      } else P = { x: G.x, y: G.ground + 110 * m, hidden: true };
      P.ph = "leap"; P.t = t; P.G = G; P.k = e.k; P.shadow = false;
      if (!P.hidden) {
        // The card hops from where the finger let go onto his helmet, then rides it down,
        // behind him and under the ground (the clip `extra` sets).
        var on = onHead(P, e), b = easeInOut(seg(t, 0, 90)), lag = 0.12 * K.kick(t - 60, 5, 0.35);
        P.card = { cx: mix(e.rect.cx, on.cx, b), cy: mix(e.rect.cy, on.cy, b) - 24 * m * Math.sin(PI * b), s: mix(1, on.s, b), rot: mix(0, on.rot, b) + lag };
        P.cardBehind = true;
      }
      return P;
    },
    // Reduce motion: head and helmet out of a small hill on the card's corner, saluting, one blink.
    sticker: function (ms, e) {
      var A = e.all, a = Math.min(seg(ms, 0, A.stickerFade), 1 - seg(ms, A.stickerHold, A.stickerHold + A.stickerFade));
      var k = e.k * 0.8, m = k / kP;
      return { ph: "sticker", t: ms, G: { m: m, x: e.rect.right - 10 * m, ground: e.rect.bottom + 6 * m }, k: k,
               x: e.rect.right - 10 * m, y: e.rect.bottom + 8 * m, salute: 1, tilt: -0.06, mouth: "smile", alpha: a,
               blink: K.lid(ms - A.stickerBlink), shadow: false };
    },
    // Before the toolkit draws the carried card (behind him): clip it to above the ground.
    extra: function (c, phase, x, e) {
      if (phase !== "leap" || x > e.T.clear) return;
      var G = geo(e, false);
      c.save(); c.beginPath(); c.rect(0, 0, e.W, G.ground - leapMound(x) * 0.55 * G.m); c.clip();
      e._digbyClip = true;
    },
    draw: function (c, P, e) {
      if (e._digbyClip) { c.restore(); e._digbyClip = false; }
      var G = P.G, m = G.m, X = G.x, Y = G.ground, t = P.t;
      c.save(); c.globalAlpha *= P.alpha === undefined ? 1 : P.alpha;
      if (P.ph === "sticker") {
        mound(c, X, Y, 44 * kP, 26 * kP, m, 5);
        c.save(); c.beginPath(); c.rect(0, 0, e.W, Y - 8 * kP * m); c.clip(); drawMole(c, P); c.restore();
        moundLip(c, X, Y + m, 40 * kP, 26 * kP, m);
        c.restore(); return;
      }
      var hold = P.ph === "hold", mh, cu, ca, hole;
      if (hold) { mh = 28 * easeOut(seg(t, 0, 0.5)) + 3 * K.kick((t - 0.25) * 600, 4, 0.35); cu = easeOut(seg(t, 0, 0.9)); ca = 1; hole = seg(t, 0.42, 0.55); }
      else { mh = leapMound(t); cu = 1; ca = 1 - seg(t, 280, 450); hole = 1 - seg(t, 280, 400); }
      crack(c, [[X - 30 * m, Y], [X - 38 * m, Y - 4 * m], [X - 46 * m, Y - m], [X - 56 * m, Y - 6 * m]], cu, ca, m);
      crack(c, [[X + 30 * m, Y], [X + 40 * m, Y - 3 * m], [X + 50 * m, Y + m], [X + 62 * m, Y - 3 * m]], cu, ca, m);
      if (!hold) tunnel(c, X, Y + 16 * m, X, e.H + 6 * m, seg(t, 60, 220), 1 - seg(t, 280, 450), m);
      mound(c, X, Y + 2 * m, 34, mh, m, 1);
      if (hole > 0) { c.fillStyle = "#2a170c"; c.beginPath(); c.ellipse(X, Y + (2 - mh * 0.62) * m, 19 * hole * m, (4 * hole + 1) * m, 0, 0, TAU); c.fill(); }
      if (!P.hidden) {
        c.save(); c.beginPath(); c.rect(0, 0, e.W, Y - mh * 0.55 * m); c.clip();
        if (!hold && t > 200 && t < 290) ghosts(c, t, e);
        drawMole(c, P);
        c.restore();
      }
      moundLip(c, X, Y + 3 * m, 30, mh, m);
      if (!hold && t >= 60) { crumbs(c, X - 6 * m, Y - mh * m, t - 60, 6, -1, 4, 300, m); crumbs(c, X + 6 * m, Y - mh * m, t - 70, 5, 1, 9, 300, m); }
      // The soil closes over him: the hole's rim tumbles in once he is down.
      if (!hold && t >= 250) crumbs(c, X, Y - mh * 0.7 * m, t - 250, 4, 0, 13, 220, m);
      c.restore();
    }
  };
  DP.register("mole", def);
})(window.DPCourier);
"""#
}
