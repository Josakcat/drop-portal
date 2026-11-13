//
//  WebGLEffect.swift
//  DropPortalCore
//
//  The phone page's left-edge light drawn on the GPU: one WebGL1 canvas,
//  one full-screen triangle, one fragment shader with a branch per effect
//  (Portal light's rift, Liquid's membrane, Wormhole's rims, Beam's lines,
//  Paper plane's fold). WebPage puts this block in front of its own script
//  and calls `window.DropPortalGL` from four places: hold (every pointer
//  move), off (glowOff), send (flyOut) and flash (the impact).
//
//  While it draws, `<html class="gl">` hides the CSS edge (`.portal`); the
//  veil, the card's flare and the sparks canvas stay as they are. Without
//  WebGL, after the context is lost twice, under prefers-reduced-motion or
//  when the shader does not build, the class is never set and the CSS edge
//  is the effect, as before.
//
//  Cost: the canvas exists only from the first drag, is drawn only when p
//  changes while held and for at most 1.5 s after a send, its device pixel
//  ratio is capped at 1.5 and its size at 520 000 pixels, and it is
//  destroyed (loseContext) when the page is hidden. Nothing loops while a
//  card is held.
//

enum WebGLEffect {
    /// Inserted where the template says `<!--webgl-->`.
    static let block = #"""
<style>html.gl .portal{visibility:hidden}.fxgl{position:fixed;left:0;top:0;z-index:10;pointer-events:none;display:none}</style>
<script>
(function () {
  "use strict";
  var root = document.documentElement, FX = { portal: 0, liquid: 1, wormhole: 2, beam: 3, plane: 4, stardust: 5, lightning: 6 };
  // Travel (ms) per effect, the page's own flight times; the impact fades in 340 ms.
  var TRAVEL = [220, 260, 240, 296, 700, 720, 250], IMPACT = 340, FADE = 140, MAXPX = 520000;
  var calmQ = window.matchMedia ? window.matchMedia("(prefers-reduced-motion: reduce)") : null;
  var cv = null, gl = null, prog = null, buf = null, U = {}, losses = 0, broken = false, frame = 0;
  var st = { live: false, p: 0, y: 0, sendAt: -1, flashAt: -1, fadeAt: -1 };
  var VS = "attribute vec2 v;void main(){gl_Position=vec4(v,0.,1.);}";
  var FS = [
    "#ifdef GL_FRAGMENT_PRECISION_HIGH\nprecision highp float;\n#else\nprecision mediump float;\n#endif",
    "uniform vec2 uR;uniform float uD,uY,uP,uS,uI,uO,uA,uX,uB,uU,uK;uniform vec3 uC0,uC1,uC2;",
    "vec3 hue(float h){return clamp(abs(mod(h*6.+vec3(0.,4.,2.),6.)-3.)-1.,0.,1.);}",
    "float g(float d,float w){return exp(-d*d/(w*w));}",
    "void main(){",
    " vec2 q=vec2(gl_FragCoord.x,uR.y-gl_FragCoord.y)/uD;float x=q.x,y=q.y-uY,ax=abs(y),k=uK,p=uP,s=uS,fl=uO*(1.-uI);",
    " float c0=0.,c1=0.,c2=0.,dk=0.;",
    " c2+=exp(-x/(30.*k))*g(y,300.*k)*.25*p;",
    // Portal light: the rift on the edge, its lens and a ribbon toward the card; the send widens it.
    " if(uX<.5){float w=1.+.35*s+.5*fl,hs=(110.+190.*p)*k*(1.+.3*fl),v=clamp(1.-ax*ax/(hs*hs),0.,1.);",
    "  c0+=exp(-x/((2.+3.*p)*w*k))*v+.18*v*exp(-x/(40.*k))*(.5+.5*sin(y*.19/k+x*.05/k));",
    "  float e=length(vec2(x/((30.+120.*p)*w*k),y/(hs*1.05)));",
    "  c1+=exp(-e*e*2.2)*(.8+.6*p)*(1.+.8*fl)+g(y,(8.+16.*p)*k)*smoothstep((40.+260.*p)*k,0.,x)*.4*p*(1.-s);",
    "  c2+=exp(-e*1.6)*.6;",
    // Liquid: a membrane bulging out of the edge, a film of water inside, a ripple at the impact.
    " }else if(uX<1.5){float hm=(140.+170.*p)*k,wm=(18.+90.*p)*k*(1.+.7*sin(3.1416*s)),v=clamp(1.-ax*ax/(hm*hm),0.,1.);",
    "  float d=x-wm*sqrt(v)-5.*k*p*sin(y*.045/k+p*6.)*v,i=step(d,0.)*step(.001,v);",
    "  c0+=exp(-abs(d)/(1.6*k))*v;",
    "  c1+=exp(-abs(d)/(7.*k))*v*.9+i*(.22+.12*sin(y*.08/k+x*.11/k)*sin(y*.05/k-x*.07/k));",
    "  c2+=exp(-max(d,0.)/(24.*k))*v*.5;",
    "  float r=abs(length(vec2(x,y))-(30.+190.*uI)*k);c1+=fl*exp(-r/(3.*k));c2+=fl*exp(-r/(14.*k))*.6;",
    // Wormhole: three rims in perspective opening from edge-on with p, turned -70° x p (35° more in
    // flight); at the impact they go edge-on and collapse into a point on the edge.
    " }else if(uX<2.5){float sc=(.4+.6*p)*k*(1.-.92*uO*smoothstep(0.,1.,uI)),an=-1.22*p+.61*s;",
    "  for(int n=0;n<3;n++){float f=float(n),R=(190.-55.*f)*sc,cx=mix(mix(.08,.71+.13*f,p),.03,uO*min(1.,uI*3.));",
    "   vec2 u=vec2(x/(R*cx),y/R);float e=length(u),m=abs(e-1.)*R,b=.65+.35*cos(atan(u.y,u.x)*2.+an*3.+f*2.1);",
    "   c0+=exp(-m/(1.4*k))*b*.8;c1+=exp(-m/(5.*k))*b;c2+=exp(-m/(16.*k))*.45;",
    "   if(n==2)dk=.6*p*exp(-e*e*1.5);}",
    "  c0+=fl*g(length(vec2(x,y)),18.*k)*1.5;",
    // Beam: nine lines stream out of the seam with p over fine scanlines, pulled back on the send;
    // the 3 px blade on the edge flashes at the impact.
    " }else if(uX<3.5){float sp=(10.+16.*p)*k,yy=y/sp,n=floor(yy+.5),dl=abs(yy-n)*sp,L=(60.+240.*p)*k*(1.-s)*(1.-.06*abs(n));",
    "  float m=smoothstep(L,L*.5,x)*step(abs(n),4.),vb=g(y,(sp*5.+40.*k)*(1.+.4*fl));",
    "  c0+=exp(-dl/(.7*k))*m+exp(-x/(1.3*k))*vb*(1.+2.*fl);c1+=exp(-dl/(3.*k))*m*.8;",
    "  c1+=step(fract(q.y/(6.*k)),.18)*exp(-x/((50.+90.*p)*k))*vb*.45;c2+=exp(-x/(22.*k))*vb*(.5+fl);",
    // Paper plane: the sheet's two halves unfold from a crease with p (the lower one in shade),
    // contrail dashes trail toward the card, a breeze over the edge; the send flies it out.
    " }else if(uX<4.5){float op=mix(.12,1.,p),Lp=110.*k,u=x-(26.-300.*s*s)*k,hw=clamp(u/Lp,0.,1.)*46.*k*op,in_=step(0.,u)*step(u,Lp);",
    "  float sh=in_*step(ax,hw)*(y<0.?.85:.5);",
    "  c0+=sh*.8+exp(-ax/k)*in_*.6;c1+=in_*g(ax-hw,6.*k)*.6+g(length(vec2(u-Lp*.5,y)),70.*k)*.3*p;",
    "  float t=u-Lp,yc=46.*k*op+t*.35,ds=step(.45,fract(t/(18.*k)))*step(0.,t)*smoothstep(220.*k,0.,t)*p;",
    "  c1+=exp(-abs(ax-yc)/(1.5*k))*ds;",
    "  c2+=step(fract((y+x*.3)/(26.*k)),.07)*exp(-x/(60.*k))*g(y,160.*k)*.5*p*(1.+fl);",
    // Stardust: a soft glow and a dusting of still grains that thickens with p (they never move on their own).
    " }else if(uX<5.5){vec2 cq=q/(7.*k),cell=floor(cq);float hh=fract(sin(dot(cell,vec2(12.99,78.23)))*43758.55);",
    "  float dot_=smoothstep(.22,.05,length(fract(cq)-.5));",
    "  float dust=step(1.-.18*p,hh)*dot_*exp(-x/((10.+26.*p)*k))*g(y,(110.+110.*p)*k);",
    "  c0+=dust*1.4;c1+=exp(-x/(10.*k))*g(y,190.*k)*.4*p;c2+=exp(-x/(30.*k))*g(y,240.*k)*.25*p;",
    // Lightning: a faint lavender glow on the edge, opacity only; no flash of its own.
    " }else{c1+=exp(-x/(16.*k))*g(y,170.*k)*.28*p;c2+=exp(-x/(55.*k))*g(y,260.*k)*.45*p;",
    " }",
    // The effect's colour; Rainbow slides the hue wheel down the edge, .3 of a turn with p.
    " vec3 a=uC1,b=uC2;if(uB>.5){float h=uU+y/(900.*k)+.3*p+.5*s;a=hue(h)*.85+.15;b=hue(h+.333);}",
    " if(uX>5.5){a=mix(a,vec3(.86,.82,1.),.65);b=mix(b,vec3(.8,.78,1.),.65);}",
    " vec3 c=min((uC0*min(c0,1.5)+a*c1+b*c2)*uA,1.);",
    " gl_FragColor=vec4(c,max(max(c.r,max(c.g,c.b)),dk*uA));",
    "}"].join("\n");

  function calm() { return !!(calmQ && calmQ.matches); }
  function shader(type, src) {
    var sh = gl.createShader(type); gl.shaderSource(sh, src); gl.compileShader(sh);
    return gl.getShaderParameter(sh, gl.COMPILE_STATUS) ? sh : null;
  }
  function init() {
    if (broken || !window.WebGLRenderingContext) return false;
    cv = document.createElement("canvas"); cv.className = "fxgl"; cv.setAttribute("aria-hidden", "true");
    var o = { alpha: true, premultipliedAlpha: true, antialias: false, depth: false, stencil: false, preserveDrawingBuffer: false, powerPreference: "low-power" };
    try { gl = cv.getContext("webgl", o) || cv.getContext("experimental-webgl", o); } catch (_) { gl = null; }
    if (!gl) { broken = true; cv = null; return false; }
    var vs = shader(gl.VERTEX_SHADER, VS), fs = shader(gl.FRAGMENT_SHADER, FS);
    prog = gl.createProgram();
    if (vs && fs) { gl.attachShader(prog, vs); gl.attachShader(prog, fs); gl.linkProgram(prog); }
    if (!vs || !fs || !gl.getProgramParameter(prog, gl.LINK_STATUS)) { broken = true; dispose(); return false; }
    gl.useProgram(prog);
    "uR uD uY uP uS uI uO uA uX uB uU uK uC0 uC1 uC2".split(" ").forEach(function (n) { U[n] = gl.getUniformLocation(prog, n); });
    buf = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    var at = gl.getAttribLocation(prog, "v"); gl.enableVertexAttribArray(at); gl.vertexAttribPointer(at, 2, gl.FLOAT, false, 0, 0);
    gl.clearColor(0, 0, 0, 0);
    cv.addEventListener("webglcontextlost", lost, false);
    document.body.appendChild(cv);
    root.classList.add("gl");
    return true;
  }
  // A lost context hands the edge back to CSS at once; the next drag tries again, twice at most.
  function lost(e) { if (e) e.preventDefault(); if (++losses >= 2) broken = true; dispose(true); }
  function dispose(wasLost) {
    if (frame) { cancelAnimationFrame(frame); frame = 0; }
    root.classList.remove("gl"); st.live = false;
    // Off first: our own loseContext below is not a loss to count.
    if (cv) cv.removeEventListener("webglcontextlost", lost, false);
    if (gl && wasLost !== true) {
      try { var ext = gl.getExtension("WEBGL_lose_context"); gl.deleteBuffer(buf); gl.deleteProgram(prog); if (ext) ext.loseContext(); } catch (_) {}
    }
    if (cv && cv.parentNode) cv.parentNode.removeChild(cv);
    cv = gl = prog = buf = null; U = {};
  }
  document.addEventListener("visibilitychange", function () { if (document.hidden) dispose(); });
  window.addEventListener("pagehide", function () { dispose(); });

  function rgb(name, d) { return (root.style.getPropertyValue(name) || d).split(",").map(function (v) { return (+v || 0) / 255; }); }
  // Once per drag: size (DPR capped at 1.5, pixels at MAXPX), effect and colour as the page set them.
  function begin() {
    var w = Math.round(Math.min(innerWidth * 0.8, 400)), h = innerHeight, d = Math.min(window.devicePixelRatio || 1, 1.5);
    if (w * h * d * d > MAXPX) d = Math.sqrt(MAXPX / (w * h));
    var bw = Math.round(w * d), bh = Math.round(h * d);
    if (cv.width !== bw || cv.height !== bh) { cv.width = bw; cv.height = bh; }
    cv.style.width = w + "px"; cv.style.height = h + "px"; cv.style.display = "block";
    gl.viewport(0, 0, bw, bh);
    var c1 = rgb("--fx", "47,107,255"), mx = Math.max(c1[0], c1[1], c1[2]), mn = Math.min(c1[0], c1[1], c1[2]), hh = 0;
    if (mx > mn) { hh = mx === c1[0] ? (c1[1] - c1[2]) / (mx - mn) : mx === c1[1] ? 2 + (c1[2] - c1[0]) / (mx - mn) : 4 + (c1[0] - c1[1]) / (mx - mn); hh /= 6; }
    gl.uniform2f(U.uR, bw, bh); gl.uniform1f(U.uD, d); gl.uniform1f(U.uK, Math.max(0.8, Math.min(1.3, h / 844)));
    gl.uniform1f(U.uX, FX[root.getAttribute("data-effect")] || 0);
    gl.uniform1f(U.uB, root.getAttribute("data-tint") === "rainbow" ? 1 : 0); gl.uniform1f(U.uU, hh);
    gl.uniform3fv(U.uC0, rgb("--fx2", "221,230,255")); gl.uniform3fv(U.uC1, c1); gl.uniform3fv(U.uC2, rgb("--fx3", "75,47,255"));
    st.live = true; st.sendAt = st.flashAt = st.fadeAt = -1;
  }
  function clamp01(v) { return v < 0 ? 0 : v > 1 ? 1 : v; }
  function draw(now) {
    frame = 0;
    if (!gl || !st.live) return;
    var fx = FX[root.getAttribute("data-effect")] || 0;
    var s = st.sendAt < 0 ? 0 : clamp01((now - st.sendAt) / TRAVEL[fx]), i = st.flashAt < 0 ? 0 : clamp01((now - st.flashAt) / IMPACT);
    var a = st.sendAt < 0 ? Math.pow(st.p, 0.6) : 1;
    if (st.fadeAt >= 0) a *= 1 - clamp01((now - st.fadeAt) / FADE);
    if (st.flashAt >= 0) a *= 1 - clamp01((i - 0.45) / 0.55);
    var done = (st.fadeAt >= 0 && now - st.fadeAt >= FADE) || (st.flashAt >= 0 && i >= 1) || (st.sendAt >= 0 && now - st.sendAt > 1500);
    if (done) { gl.clear(gl.COLOR_BUFFER_BIT); cv.style.display = "none"; st.live = false; return; }
    gl.uniform1f(U.uX, fx);
    gl.uniform1f(U.uY, st.y); gl.uniform1f(U.uP, st.p); gl.uniform1f(U.uS, s * s); // curve A, near enough
    gl.uniform1f(U.uI, i); gl.uniform1f(U.uO, st.flashAt < 0 ? 0 : 1); gl.uniform1f(U.uA, a);
    gl.clear(gl.COLOR_BUFFER_BIT); gl.drawArrays(gl.TRIANGLES, 0, 3);
    if (st.sendAt >= 0 || st.fadeAt >= 0) frame = requestAnimationFrame(draw);
  }
  function kick() { if (!frame) frame = requestAnimationFrame(draw); }

  window.DropPortalGL = {
    // While held: p and the card's centre line. False when the CSS edge is the effect.
    hold: function (p, y) {
      if (calm()) { if (gl) dispose(); return false; }
      if (!gl && !init()) return false;
      if (!st.live || st.sendAt >= 0) begin();
      st.p = p; st.y = y; st.fadeAt = -1; kick();
      return true;
    },
    send: function () { if (st.live) { st.sendAt = performance.now(); kick(); } },
    flash: function () { if (st.live) { st.flashAt = performance.now(); st.fadeAt = -1; kick(); } },
    // A cancel fades; during a send the impact ends it instead.
    off: function () { if (st.live && st.sendAt < 0) { st.fadeAt = performance.now(); kick(); } },
    dispose: dispose,
    // For the harness: the shader's cost of n frames (ms each), at the current size.
    bench: function (n, now) {
      if (!gl) return -1; now = now || function () { return performance.now(); };
      var px = new Uint8Array(4), t = now();
      for (var j = 0; j < n; j++) { gl.drawArrays(gl.TRIANGLES, 0, 3); gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px); }
      return (now() - t) / n;
    }
  };
})();
</script>
"""#
}
