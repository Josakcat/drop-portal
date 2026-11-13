//
//  WebSkyEffect.swift
//  DropPortalCore
//
//  Stardust and Lightning on the phone page: `window.DropPortalSky`, called
//  by flyOut for those two effects. Inserted after WebGLEffect's block.
//
//  Stardust: the card dissolves into grains (one per 2 × 2 px, one per px on
//  a 3x screen, at most 40 000), released by a front of 0.5x + 0.2·noise +
//  0.3·rand that sweeps the card left to right over 0.7 s; released grains
//  blow left at 300–800 px/s on emphasized-accelerate along a curl flow,
//  dwindle to one physical pixel and fade; one in ten glitters at 6 Hz.
//  Stateless: each grain's position is a function of (id, t, seed) in the
//  vertex shader, drawn as instanced quads (WebGL2, or WebGL1 with
//  ANGLE_instanced_arrays), never gl.POINTS, no float targets, so none of
//  iOS's half-float bugs apply. A slow first frames halve the grains. No
//  WebGL, or a lost context: the same grains on a Canvas2D, fewer of them.
//  The colours come from the card itself, drawn to a canvas from its own
//  same-origin picture (never a screen capture).
//
//  Lightning: one bolt (midpoint displacement, 5 generations, 2–4 branches
//  at about ±30°) from the card to the left edge on a Canvas2D: the leader
//  in four steps at 35 %, one 1–2-frame flash (when the cap allows), the card
//  rides it off the edge, an afterglow with τ 100 ms; no bloom, no re-strike
//  on the phone, gone by 0.4 s. At most three flashes in any second
//  (WCAG 2.3.1), the same rule as FlashLimiter on the Mac. Never red: the
//  halo is the effect's colour desaturated toward ice-blue and lavender.
//
//  Both use only what the page already has; nothing goes over the network.
//

enum WebSkyEffect {
    static let block = #"""
<style>.skyfx{position:fixed;left:0;top:0;width:100%;height:100%;z-index:12;pointer-events:none}</style>
<script>
(function () {
  "use strict";
  var root = document.documentElement;
  function clamp01(v) { return v < 0 ? 0 : v > 1 ? 1 : v; }
  function bez(x, x1, y1, x2, y2) {
    x = clamp01(x); var lo = 0, hi = 1, u = 0.5;
    for (var i = 0; i < 14; i++) { u = (lo + hi) / 2; var v = 3 * (1 - u) * (1 - u) * u * x1 + 3 * (1 - u) * u * u * x2 + u * u * u; if (v < x) lo = u; else hi = u; }
    return 3 * (1 - u) * (1 - u) * u * y1 + 3 * (1 - u) * u * u * y2 + u * u * u;
  }
  function accel(x) { return bez(x, 0.3, 0, 0.8, 0.15); }
  function rgbVar(name, d) { return (root.style.getPropertyValue(name) || d).split(",").map(function (v) { return (+v || 0) / 255; }); }

  // ---- The flash cap: a flash is refused while three others lie within a second of it.
  var flashes = [];
  function allowFlash(now) {
    flashes = flashes.filter(function (t) { return Math.abs(now - t) < 2000; });
    var near = flashes.filter(function (t) { return Math.abs(now - t) < 1000; }).length;
    if (near >= 3) return false;
    flashes.push(now); return true;
  }

  function layer() {
    var c = document.createElement("canvas"); c.className = "skyfx"; c.setAttribute("aria-hidden", "true");
    document.body.appendChild(c); return c;
  }

  // ---- The card as a picture: its background, its photo (cover) or its file label.
  function snapshot(card, w, h) {
    var c = document.createElement("canvas"); c.width = Math.max(1, Math.round(w)); c.height = Math.max(1, Math.round(h));
    var x = c.getContext("2d"), cs = getComputedStyle(card), r = Math.min(18, w / 6);
    x.beginPath(); if (x.roundRect) x.roundRect(0, 0, c.width, c.height, r); else x.rect(0, 0, c.width, c.height); x.clip();
    x.fillStyle = cs.backgroundColor || "#1c2333"; x.fillRect(0, 0, c.width, c.height);
    var m = card.querySelector("img,video");
    try {
      var sw = m && (m.naturalWidth || m.videoWidth), sh = m && (m.naturalHeight || m.videoHeight);
      if (m && sw && sh) {
        var s = Math.max(c.width / sw, c.height / sh), dw = sw * s, dh = sh * s;
        x.drawImage(m, (c.width - dw) / 2, (c.height - dh) / 2, dw, dh);
      } else {
        var d = card.querySelector(".doc");
        x.fillStyle = "#cfd8ea"; x.font = "600 " + Math.round(c.height * 0.16) + "px -apple-system,sans-serif";
        x.textAlign = "center"; x.textBaseline = "middle"; x.fillText(d ? d.textContent : "FILE", c.width / 2, c.height * 0.45);
      }
    } catch (_) {}
    return c;
  }

  // ---- Stardust on WebGL
  var VS = [
    "precision highp float;",
    "attribute vec2 c;attribute float id;",
    "uniform vec2 uR,uGrid;uniform vec4 uCard;uniform float uT,uDpr,uGlit,uSeed,uStride;",
    "varying vec2 vUV,vQ;varying float vA,vRel,vG;",
    "float h(float n){return fract(sin(n*12.9898+uSeed)*43758.5453);}",
    "float acc(float x){x=clamp(x,0.,1.);float lo=0.,hi=1.,u=.5;for(int i=0;i<10;i++){u=(lo+hi)*.5;float v=3.*(1.-u)*(1.-u)*u*.3+3.*(1.-u)*u*u*.8+u*u*u;if(v<x)lo=u;else hi=u;}",
    " return 3.*(1.-u)*u*u*.15+u*u*u;}",
    "vec2 curl(vec2 p,float t){float A=p.x+1.3*t,B=p.y*.8-.9*t,C=1.36*p.x-1.3*p.y+t;",
    " float dx=cos(A)*cos(B)+.68*cos(C),dy=-.8*sin(A)*sin(B)-.65*cos(C);return vec2(dy,-dx)*.5;}",
    "void main(){",
    " float n=id*uStride;if(uGlit>.5)n=id*10.*uStride+floor(h(id+77.)*10.);",
    " float col=mod(n,uGrid.x),row=floor(n/uGrid.x);",
    " vec2 uv=vec2((col+.5)/uGrid.x,(row+.5)/uGrid.y);vUV=uv;vQ=c;",
    " float r=h(n*3.+1.),r2=h(n*3.+2.),shape=(sin(uv.x*12.+uv.y*9.)+cos(uv.y*17.-uv.x*5.)+2.)*.25;",
    // The front: 0.5x + 0.2 noise + 0.3 rand, over 0.7 s, left edge first.
    " float rel=.7*(.5*uv.x+.2*shape+.3*r),age=uT-rel;",
    " vec2 p=uCard.xy+uv*uCard.zw;p.x-=10.*acc(uT/.06);",
    " float size=uCard.z/uGrid.x*uStride+.4,a=1.;vRel=0.;vG=0.;",
    " if(age>0.){vRel=1.;",
    "  p.x-=(300.+500.*r)*age*acc(age/.55);",
    "  p+=curl(p/60.,uT*2.+r*6.)*40.*age;",
    "  p.y=mix(p.y,uCard.y+uCard.w*.5,clamp(age*.5,0.,.25));",
    "  size=mix(.6+1.2*r2,1./uDpr,clamp(age/(.5+.8*r2),0.,1.));a=1.-clamp((age-.35)/.2,0.,1.);",
    " }else if(age>-.023){p+=vec2(sin(uT*90.+n),cos(uT*80.+n))*.4;}",
    " if(uGlit>.5){if(age<=0.){a=0.;}else{vG=(.12+.88*pow(h(n+floor(uT*6.)*13.),4.))*a;size=4.;}}",
    " if(a<=0.||n>=uGrid.x*uGrid.y){gl_Position=vec4(-2.,-2.,0.,1.);vA=0.;return;}",
    " vA=a;vec2 q=p+c*size*.5;",
    " gl_Position=vec4(q.x/uR.x*2.-1.,1.-q.y/uR.y*2.,0.,1.);",
    "}"].join("\n");
  var FS = [
    "precision mediump float;",
    // Its own uniform for the pass: one shared with the vertex shader must match its precision.
    "uniform sampler2D uTex;uniform float uPass;uniform vec3 uTint;",
    "varying vec2 vUV,vQ;varying float vA,vRel,vG;",
    "void main(){",
    " if(uPass>.5){float g=exp(-dot(vQ,vQ)*3.)*vG;vec3 w=mix(vec3(1.,.98,.94),uTint,.25)*g;gl_FragColor=vec4(w,g*.6);return;}",
    " vec4 t=texture2D(uTex,vUV);float d=length(vQ),m=mix(1.,1.-smoothstep(.55,1.,d),vRel)*vA;",
    " gl_FragColor=t*m;",
    "}"].join("\n");

  function glSetup(cv) {
    var o = { alpha: true, premultipliedAlpha: true, antialias: false, depth: false, stencil: false, powerPreference: "default" };
    var gl = null, inst = null;
    try { gl = cv.getContext("webgl2", o); } catch (_) {}
    if (gl) inst = { div: function (l, d) { gl.vertexAttribDivisor(l, d); }, draw: function (n) { gl.drawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, n); } };
    else {
      try { gl = cv.getContext("webgl", o); } catch (_) {}
      var ext = gl && gl.getExtension("ANGLE_instanced_arrays");
      if (!ext) return null;
      inst = { div: function (l, d) { ext.vertexAttribDivisorANGLE(l, d); }, draw: function (n) { ext.drawArraysInstancedANGLE(gl.TRIANGLE_STRIP, 0, 4, n); } };
    }
    function sh(t, s) { var x = gl.createShader(t); gl.shaderSource(x, s); gl.compileShader(x); return gl.getShaderParameter(x, gl.COMPILE_STATUS) ? x : null; }
    var vs = sh(gl.VERTEX_SHADER, VS), fs = sh(gl.FRAGMENT_SHADER, FS);
    if (!vs || !fs) return null;
    var pr = gl.createProgram(); gl.attachShader(pr, vs); gl.attachShader(pr, fs); gl.linkProgram(pr);
    if (!gl.getProgramParameter(pr, gl.LINK_STATUS)) return null;
    gl.useProgram(pr);
    return { gl: gl, inst: inst, pr: pr };
  }

  function stardust(card, done) {
    var rect = card.getBoundingClientRect(), W = innerWidth, H = innerHeight;
    var dpr = Math.min(window.devicePixelRatio || 1, 2);
    // One grain per 2 × 2 px on a 2x phone (iPhone 11 class), one per px on 3x; at most 40 000.
    var step = (window.devicePixelRatio || 1) >= 3 ? 1 : 2;
    while ((rect.width / step) * (rect.height / step) > 40000) step *= 1.415;
    var cols = Math.max(1, Math.round(rect.width / step)), rows = Math.max(1, Math.round(rect.height / step)), N = cols * rows;
    var pic = snapshot(card, rect.width * dpr, rect.height * dpr);
    var cv = layer(); cv.width = Math.round(W * dpr); cv.height = Math.round(H * dpr);
    var s = null;
    try { s = glSetup(cv); } catch (_) { s = null; }
    card.style.opacity = "0";
    var start = performance.now(), END = 1300, called = false, frame = 0, lost = false, stride = 1, slow = 0, last = start, frames = 0;
    function finish() { if (frame) cancelAnimationFrame(frame); if (cv.parentNode) cv.parentNode.removeChild(cv); }
    function call() { if (!called) { called = true; done(); } }
    // The page moves on once the front has crossed the card; the dust drifts out on its own.
    setTimeout(call, 720);
    if (!s) {
      // A canvas that tried WebGL cannot give a 2D context: a fresh one for the fallback.
      if (cv.parentNode) cv.parentNode.removeChild(cv);
      cv = layer(); cv.width = Math.round(W * dpr); cv.height = Math.round(H * dpr);
      return canvas2d(cv, pic, rect, cols, rows, dpr, start, finish);
    }
    var gl = s.gl, pr = s.pr;
    cv.addEventListener("webglcontextlost", function (e) { e.preventDefault(); lost = true; finish(); }, false);
    var U = {}; "uR uGrid uCard uT uDpr uGlit uPass uSeed uStride uTex uTint".split(" ").forEach(function (n) { U[n] = gl.getUniformLocation(pr, n); });
    var quad = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, quad);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
    var lc = gl.getAttribLocation(pr, "c"); gl.enableVertexAttribArray(lc); gl.vertexAttribPointer(lc, 2, gl.FLOAT, false, 0, 0); s.inst.div(lc, 0);
    var ids = new Float32Array(N); for (var i = 0; i < N; i++) ids[i] = i;
    var ib = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, ib); gl.bufferData(gl.ARRAY_BUFFER, ids, gl.STATIC_DRAW);
    var li = gl.getAttribLocation(pr, "id"); gl.enableVertexAttribArray(li); gl.vertexAttribPointer(li, 1, gl.FLOAT, false, 0, 0); s.inst.div(li, 1);
    var tex = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, true);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, pic);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.viewport(0, 0, cv.width, cv.height); gl.enable(gl.BLEND); gl.clearColor(0, 0, 0, 0);
    gl.uniform2f(U.uR, W, H); gl.uniform2f(U.uGrid, cols, rows); gl.uniform4f(U.uCard, rect.left, rect.top, rect.width, rect.height);
    gl.uniform1f(U.uDpr, dpr); gl.uniform1f(U.uSeed, Math.random() * 100); gl.uniform1i(U.uTex, 0);
    var tint = rgbVar("--fx", "255,194,26"); gl.uniform3f(U.uTint, tint[0], tint[1], tint[2]);
    function draw(now) {
      frame = 0;
      if (lost) return;
      var t = now - start;
      // Warm-up: a frame over 24 ms (two at 60 Hz) in the first ten halves the grains.
      if (frames < 10 && frames > 0 && now - last > 24 && ++slow >= 2 && stride === 1) stride = 2;
      frames++; last = now;
      if (t > END) { finish(); return; }
      gl.clear(gl.COLOR_BUFFER_BIT);
      gl.uniform1f(U.uT, t / 1000); gl.uniform1f(U.uStride, stride);
      gl.uniform1f(U.uGlit, 0); gl.uniform1f(U.uPass, 0); gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA); s.inst.draw(Math.ceil(N / stride));
      gl.uniform1f(U.uGlit, 1); gl.uniform1f(U.uPass, 1); gl.blendFunc(gl.ONE, gl.ONE); s.inst.draw(Math.ceil(N / 10 / stride));
      frame = requestAnimationFrame(draw);
    }
    frame = requestAnimationFrame(draw);
  }

  // No WebGL: the same release and wind on a Canvas2D, one grain per 4 px.
  function canvas2d(cv, pic, rect, cols, rows, dpr, start, finish) {
    var x = cv.getContext("2d"); if (!x) return finish();
    var k = Math.max(1, Math.round(4 / (rect.width / cols))), c2 = Math.ceil(cols / k), r2 = Math.ceil(rows / k);
    var px = pic.getContext("2d").getImageData(0, 0, pic.width, pic.height).data, g = [];
    for (var j = 0; j < r2; j++) for (var i = 0; i < c2; i++) {
      var u = (i + 0.5) / c2, v = (j + 0.5) / r2, o = (Math.floor(v * (pic.height - 1)) * pic.width + Math.floor(u * (pic.width - 1))) * 4;
      if (px[o + 3] < 20) continue;
      var r = Math.random();
      g.push({ u: u, v: v, r: r, rel: 0.7 * (0.5 * u + 0.2 * (Math.sin(u * 12 + v * 9) + Math.cos(v * 17 - u * 5) + 2) / 4 + 0.3 * r), c: "rgb(" + px[o] + "," + px[o + 1] + "," + px[o + 2] + ")" });
    }
    var cw = rect.width / c2, ch = rect.height / r2;
    function draw(now) {
      var t = (now - start) / 1000;
      if (t > 1.3) return finish();
      x.setTransform(dpr, 0, 0, dpr, 0, 0); x.clearRect(0, 0, cv.width, cv.height);
      for (var n = 0; n < g.length; n++) {
        var q = g[n], age = t - q.rel, X = rect.left + q.u * rect.width, Y = rect.top + q.v * rect.height, s = cw, a = 1;
        if (age > 0) { X -= (300 + 500 * q.r) * age * accel(age / 0.55); s = Math.max(0.5, 1.8 * (1 - age)); a = 1 - clamp01((age - 0.35) / 0.2); }
        if (a <= 0) continue;
        x.globalAlpha = a; x.fillStyle = q.c; x.fillRect(X, Y, s, age > 0 ? s : ch);
      }
      requestAnimationFrame(draw);
    }
    requestAnimationFrame(draw);
  }

  // ---- Lightning
  function boltShape(seed) {
    var rnd = (function (s) { return function () { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; }; })(seed >>> 0 || 1);
    // In the unit frame: along 0..1 from the card to the edge, offsets across.
    function md(a, b, gens, sway) {
      var pts = [a, b], off = sway;
      for (var gI = 0; gI < gens; gI++) {
        var nx = [pts[0]];
        for (var i = 0; i < pts.length - 1; i++) {
          var p = pts[i], q = pts[i + 1], dx = q[0] - p[0], dy = q[1] - p[1], l = Math.max(1e-6, Math.hypot(dx, dy)), o = (rnd() * 2 - 1) * off;
          nx.push([(p[0] + q[0]) / 2 - dy / l * o, (p[1] + q[1]) / 2 + dx / l * o, (p[2] + q[2]) / 2], q);
        }
        pts = nx; off /= 2;
      }
      return pts;
    }
    var trunk = md([0, 0, 0], [1, 0, 1], 5, 0.16), lines = [{ p: trunk, w: 1 }], n = 2 + Math.floor(rnd() * 3);
    var cand = trunk.filter(function (p, i) { return i % 4 === 0 && p[2] > 0.12 && p[2] < 0.7; });
    for (var b = 0; b < n && cand.length; b++) {
      var st = cand.splice(Math.floor(rnd() * cand.length), 1)[0], side = b % 2 ? -1 : 1;
      var ang = side * (Math.PI / 6) * (0.8 + 0.4 * rnd()), reach = (1 - st[2]) * (0.6 + 0.1 * rnd()) * 0.55;
      lines.push({ p: md(st, [st[0] + Math.cos(ang) * reach, st[1] + Math.sin(ang) * reach, st[2] + 0.25], 4, 0.13), w: 0.4 + 0.2 * rnd() });
    }
    return lines;
  }
  function safeTone() {
    var c = rgbVar("--fx", "0,212,255"), mx = Math.max(c[0], c[1], c[2]), mn = Math.min(c[0], c[1], c[2]), d = mx - mn, h = 0;
    if (d > 0) { h = mx === c[0] ? (c[1] - c[2]) / d : mx === c[1] ? 2 + (c[2] - c[0]) / d : 4 + (c[0] - c[1]) / d; h /= 6; if (h < 0) h += 1; }
    var deg = h * 360; if (deg < 25) deg = deg < 12 ? 335 : 25; else if (deg > 335) deg = 335;
    var s = Math.min(mx === 0 ? 0 : d / mx, 0.45), v = Math.max(mx, 0.9), f = (deg / 60) % 6, i = Math.floor(f), fr = f - i;
    var p = v * (1 - s), q = v * (1 - s * fr), t = v * (1 - s * (1 - fr));
    var rgb = [[v, t, p], [q, v, p], [p, v, t], [p, q, v], [t, p, v], [v, p, q]][i];
    return rgb.map(function (x, k) { return Math.round(255 * (x * 0.65 + [0.9, 0.8, 1][k] * 0.35)); }).join(",");
  }
  function lightning(card, opts, done) {
    var rect = card.getBoundingClientRect(), W = innerWidth, H = innerHeight, dpr = Math.min(window.devicePixelRatio || 1, 2);
    var cv = layer(); cv.width = Math.round(W * dpr); cv.height = Math.round(H * dpr);
    var x = cv.getContext("2d"), lines = boltShape(Math.random() * 4294967296), ice = safeTone();
    var start = performance.now(), flash = null, cy = rect.top + rect.height / 2, called = false;
    function draw(now) {
      var t = now - start;
      if (t > 420) { if (cv.parentNode) cv.parentNode.removeChild(cv); return; }
      if (t >= 250 && !called) { called = true; done(); }
      // From inside the card (it rides the bolt: the page moves it on the same curve) to the left edge.
      var q = accel((t - 60) / 190), x1 = rect.left + rect.width * 0.4 + opts.exitX * q, y1 = cy + opts.y * q;
      if (t >= 60 && flash === null) flash = allowFlash(now);
      var lit = t >= 60 && t < 85 && flash, steps = t < 60 ? Math.min(4, Math.floor(t / 15) + 1) / 4 : 1;
      var a = t < 60 ? 0.35 : (flash ? 0.7 : 0.35) * Math.exp(-Math.max(0, t - 85) / 100);
      if (lit) a = 1;
      if (t > 320) a *= 1 - clamp01((t - 320) / 100);
      x.setTransform(dpr, 0, 0, dpr, 0, 0); x.clearRect(0, 0, W, H);
      x.globalCompositeOperation = "lighter"; x.lineJoin = "round"; x.lineCap = "round";
      var dx = 0 - x1, dy = cy - y1, L = Math.max(1, Math.hypot(dx, dy)), nx = -dy / L, ny = dx / L;
      [[18, "rgba(" + ice + ",", 0.14], [8, "rgba(" + ice + ",", 0.22], [2, "rgba(255,255,255,", 1]].forEach(function (s) {
        lines.forEach(function (ln) {
          x.beginPath(); var started = false;
          for (var i = 0; i < ln.p.length; i++) {
            var p = ln.p[i]; if (p[2] > steps + 0.001) break;
            var X = x1 + dx * p[0] + nx * p[1] * L, Y = y1 + dy * p[0] + ny * p[1] * L;
            if (!started) { x.moveTo(X, Y); started = true; } else x.lineTo(X, Y);
          }
          x.lineWidth = s[0] * (ln.w < 1 ? ln.w + 0.1 : 1);
          var o = s[2] * a * (ln.w < 1 ? 0.6 : 1) * (s[0] === 2 && !lit ? 0.7 : 1);
          x.strokeStyle = s[1] + o.toFixed(3) + ")"; x.stroke();
        });
      });
      requestAnimationFrame(draw);
    }
    requestAnimationFrame(draw);
  }

  window.DropPortalSky = { stardust: stardust, lightning: lightning, allowFlash: allowFlash };
})();
</script>
"""#
}
