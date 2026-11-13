//
//  MetalFXShaders.swift
//  DropPortal
//
//  The Metal shaders of the crossing effects, compiled from source at run
//  time by MetalFX (no .metal resource, so the droplet's build is unchanged).
//  Every coordinate is in points with y up, the same space the Core
//  Animation stage and card use; `k` scales the spec's 1280 × 800 sizes.
//
//  stage_fs     the full-screen light behind the card: Portal's lens rift and
//               its chromatic wave, Liquid's metaballs, Wormhole's vortex,
//               Beam's data lines, Paper plane's air
//  particle_vs  thousands of impact particles, each a pure function of its
//               index and the time, so any instant can be drawn on its own
//  card_fs      the card's own picture, distorted: Wormhole's swirl, Portal's
//               refraction at the rift, Beam's glitch, Liquid's wet sheen
//  wing_fs      Paper plane: one half of the photo lit as folded paper
//

enum MetalFXShaders {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

struct U { float4 a, b, c, d, e, f, g, h, i, j; };
// a: effect, p, tSend, tImpact     b: width, height, originX, originY
// c: card cx, cy, w, h             d: seam x, y, landing x, y
// e: core rgb, rainbow             f: glow rgb, rainbow turn
// g: accent rgb, k                 h: flight, sx, sy, turn
// i: px per pt, extra...           j: extra

struct VOut { float4 pos [[position]]; };

vertex VOut fx_tri(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    VOut o; o.pos = float4(p * 2 - 1, 0, 1); return o;
}

static float2 pointOf(constant U& u, float4 pos) {
    float s = u.i.x;
    return float2(u.b.z + pos.x / s, u.b.w + u.b.y - pos.y / s);
}

static float h11(float n) { return fract(sin(n * 127.1) * 43758.5453); }
static float h21(float2 p) { p = fract(p * float2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
static float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p); float2 w = f * f * (3 - 2 * f);
    return mix(mix(h21(i), h21(i + float2(1, 0)), w.x), mix(h21(i + float2(0, 1)), h21(i + float2(1, 1)), w.x), w.y);
}
static float fbm(float2 p) { float s = 0, a = .5; for (int k = 0; k < 4; k++) { s += a * vnoise(p); p = p * 2.03 + 17.1; a *= .5; } return s; }
static float3 hsv(float h, float s, float v) {
    float3 k = clamp(abs(fract(h + float3(0, 2. / 3, 1. / 3)) * 6 - 3) - 1, 0., 1.);
    return v * mix(float3(1), k, s);
}
// pow under fast math is defined only for a base above zero: pow(0, y) can
// come back NaN (outE(1) at the end of every curve did). Never pass it 0.
static float pw(float x, float y) { return pow(max(x, 1e-6), y); }
// smoothstep that also runs downhill (a > b): Metal leaves reversed edges undefined.
static float ss(float a, float b, float x) { float t = clamp((x - a) / (b - a), 0., 1.); return t * t * (3 - 2 * t); }
static float seg(float t, float a, float b) { return clamp((t - a) / (b - a), 0., 1.); }
static float outE(float x) { x = clamp(x, 0., 1.); return 1 - pw(1 - x, 4); }
static float inE(float x) { x = clamp(x, 0., 1.); return x * x * x; }
static float sq(float x) { return x * x; }
static float smin(float a, float b, float k) { float h = clamp(.5 + .5 * (b - a) / k, 0., 1.); return mix(b, a, h) - k * h * (1 - h); }
static float sdBox(float2 p, float2 b, float r) { float2 q = abs(p) - b + r; return length(max(q, 0.)) + min(max(q.x, q.y), 0.) - r; }
static float sdSeg(float2 p, float2 a, float2 b, thread float& h) {
    float2 pa = p - a, ba = b - a; h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-3), 0., 1.); return length(pa - ba * h);
}
static float2 rot(float2 v, float a) { float c = cos(a), s = sin(a); return float2(c * v.x - s * v.y, s * v.x + c * v.y); }

// The palette along x in 0...1 (core, glow, accent); Rainbow walks the hue wheel instead.
static float3 pal(constant U& u, float x, float hue) {
    if (u.e.w > .5) return hsv(fract(u.f.w + hue), .72, 1);
    x = clamp(x, 0., 1.);
    return x < .5 ? mix(u.e.rgb, u.f.rgb, x * 2) : mix(u.f.rgb, u.g.rgb, x * 2 - 1);
}
// Chromatic fringe: the palette pulled toward pure R, G, B (Rainbow: the wheel's thirds).
static float3 fringe(constant U& u, int c, float hue) {
    float3 rgb = c == 0 ? float3(1, .25, .3) : (c == 1 ? float3(.3, 1, .45) : float3(.35, .45, 1));
    if (u.e.w > .5) return mix(hsv(fract(u.f.w + hue + c / 3.), .8, 1), rgb, .25);
    return mix(pal(u, c * .5, 0), rgb, .38);
}
// Light over the desktop: mostly additive, a little cover so it reads on a light wallpaper too.
// The cover follows the light's own brightness, so where there is no light nothing is dimmed.
static float4 light(float3 c, float a) {
    a = clamp(a, 0., 1.5);
    float3 l = max(c * a, 0.);
    return float4(l, clamp(max(l.r, max(l.g, l.b)) * .45, 0., 1.));
}

// ---------------------------------------------------------------- Portal light
static float4 portalStage(constant U& u, float2 q) {
    float p = u.a.y, ts = u.a.z, ti = u.a.w, k = u.g.w, L = u.h.x;
    bool held = ts < 0;
    float open = held ? p : 1;
    float fade = held ? pw(p, .7) : 1 - seg(ts, L + .02, L + .3);
    float4 o = 0;
    // The lens rift on the edge: three chromatic rims and caustic light flowing inside.
    float2 d = q - u.d.xy;
    float H = (110 + 190 * open) * k;
    float W = (18 + 62 * open) * k * (held ? 1 : mix(1., 1.35, outE(seg(ts, 0, .1))));
    float ny = d.y / H, prof = sqrt(max(0., 1 - ny * ny)), x = -d.x;
    if (prof > 0 && fade > 0) {
        float3 acc = 0;
        for (int c = 0; c < 3; c++) {
            float r = W * prof * (1 + .1 * c), w = (1.6 + 2.2 * c) * k;
            acc += fringe(u, c, ny * .2) * exp(-sq((x - r) / w)) * .85;
        }
        float inside = ss(W * prof, W * prof * .55, x);
        float flow = fbm(float2(x * .03 / k - open * 3 - max(ts, 0.) * 5, ny * 3.2));
        float caus = pw(abs(sin(flow * 10 + ny * 5)), 7);
        acc += mix(pal(u, .5, ny * .3), u.e.rgb, caus) * inside * (.18 + .7 * caus) * prof;
        acc += u.e.rgb * exp(-sq(x / (1.3 * k))) * exp(-sq(ny * .85)) * 1.2;
        o += light(acc, fade);
    }
    // The impact: a chromatic elliptical wave around the card and an anamorphic streak.
    if (ti >= 0) {
        float2 e = (q - u.c.xy) / (float2(280, 195) * k);
        float s = length(e);
        float R = ti < .08 ? mix(.35, 1., outE(ti / .08)) : mix(1., 1.18, outE(seg(ti, .08, .48)));
        float a = ti < .032 ? .7 * ti / .032 : (ti < .08 ? mix(.7, .28, seg(ti, .032, .08)) : .28 * (1 - seg(ti, .08, .48)));
        float3 acc = 0;
        for (int c = 0; c < 3; c++) {
            float r = R * (1 + (c - 1) * .028);
            acc += fringe(u, c, atan2(e.y, e.x) / 6.283) * exp(-sq((s - r) / .022));
        }
        float glints = pw(vnoise(float2(atan2(e.y, e.x) * 18, s * 6)), 6) * exp(-sq((s - R) / .06));
        acc += u.e.rgb * glints * 2 + pal(u, .5, 0) * exp(-sq((s - R * .92) / .12)) * .25;
        float streak = exp(-sq((q.y - u.c.y) / (2.2 * k))) * exp(-sq((q.x - u.c.x) / (320 * k))) * (1 - seg(ti, .02, .12)) * .9;
        o += light(acc * 1.6 + u.e.rgb * streak, a * 1.6 + streak);
    }
    return o;
}

// ---------------------------------------------------------------- Liquid
static float liquidField(constant U& u, float2 q, thread float& rimBoost) {
    float p = u.a.y, ts = u.a.z, ti = u.a.w, k = u.g.w, L = u.h.x;
    bool held = ts < 0;
    float open = held ? p : 1;
    rimBoost = 0;
    // The card's own blob, a little larger than the card so a wet rim shows round it.
    float pop = ti < 0 ? 1 : (ti < .07 ? mix(1., 1.14, ti / .07) : mix(1.14, 1., outE(seg(ti, .07, .45))));
    float2 hb = u.c.zw * .5 * float2(u.h.y, u.h.z) * pop + 9 * k;
    float d = sdBox(q - u.c.xy, hb, 46 * k);
    // The membrane on the edge, collapsing as the card flies.
    float col = held ? 1 : 1 - outE(seg(ts, 0, L));
    float Rm = (14 + 60 * open) * k * mix(.15, 1., col), Hm = (90 + 160 * open) * k * mix(.4, 1., col);
    float hh;
    float mem = sdSeg(q, u.d.xy + float2(6 * k, -Hm), u.d.xy + float2(6 * k, Hm), hh) - Rm;
    if (ti < .3) d = smin(d, mem + (ti < 0 ? 0 : 200 * k * ti), 38 * k);
    // The neck: beads grow on it (Plateau-Rayleigh) until it pinches into drops.
    if (ti < .3) {
        float2 a = u.d.xy, b = u.c.xy + float2(u.c.z * .4, 0);
        float h; float dist = sdSeg(q, a, b, h);
        float r0 = (held ? 11 * seg(p, .25, .55) * (1.2 - .5 * p) : 9) * k;
        float m = held ? .15 : mix(.25, 1.25, seg(ts, 0, L));
        float lenN = length(b - a);
        float wave = cos(6.283 * h * max(1., lenN / (46 * k)));
        float r = r0 * (1 - m + m * wave);
        float after = ti >= 0 ? 1 - seg(ti, 0, .25) : 1;
        if (r0 > 0) d = smin(d, dist - r * after, 10 * k);
    }
    // The impact's crown: eight drops thrown from the card, joined to it at first, then free.
    if (ti >= 0 && ti < .55) {
        for (int n = 0; n < 8; n++) {
            float ang = 6.283 * (n + .5 * h11(n)) / 8;
            float2 dir = float2(cos(ang) * 1.1, sin(ang) * .78);
            float travel = (150 + 70 * h11(n + 9)) * k * outE(seg(ti, 0, .35));
            float2 c = u.c.xy + dir * (hb + 4 * k) * .9 + dir * travel - float2(0, 900 * k * ti * ti);
            float r = (15 + 6 * h11(n + 3)) * k * (1 - seg(ti, .22, .5));
            d = smin(d, length(q - c) - r, 22 * k);
        }
        rimBoost = 1 - seg(ti, 0, .3);
    }
    return d;
}

static float4 liquidStage(constant U& u, float2 q, float pxPerPt) {
    float p = u.a.y, ts = u.a.z, ti = u.a.w, k = u.g.w;
    float fade = (ts < 0 ? ss(0., .2, p) : 1) * (ti < 0 ? 1 : 1 - seg(ti, .25, .55));
    if (fade <= 0) return 0;
    float rb;
    float d = liquidField(u, q, rb);
    float aa = 1.2 / pxPerPt;
    float cover = ss(aa, -aa, d);
    // Screen-space gradient of the field, y up (taken before any early return).
    float2 g = float2(dfdx(d), -dfdy(d));
    if (cover <= 0) return 0;
    g = length(g) > 1e-5 ? normalize(g) : float2(0);
    float t = clamp(-d / (16 * k), 0., 1.);
    float3 n = normalize(float3(-g * (1 - t) * 1.8, t + .12));
    float3 l = normalize(float3(-.45, .6, .66));
    float spec = pw(max(dot(reflect(-l, n), float3(0, 0, 1)), 0.), 36);
    float spec2 = pw(max(dot(reflect(-normalize(float3(.6, -.3, .74)), n), float3(0, 0, 1)), 0.), 14) * .35;
    float rim = pw(1 - t, 3);
    float caus = pw(vnoise(q / (14 * k) + float2(p * 3, max(ts, 0.) * 4)), 3);
    float3 body = pal(u, .45 + .2 * n.x, (q.x - u.d.x) / 900);
    float3 c = body * (.22 + .25 * caus) + u.e.rgb * rim * (.75 + .6 * rb) + float3(1) * (spec + spec2);
    float a = (.16 + .2 * caus) * (1 - rim) + rim * .55 + spec * .6;
    return float4(c, a) * cover * fade;
}

// ---------------------------------------------------------------- Wormhole
static float4 wormholeStage(constant U& u, float2 q) {
    float p = u.a.y, ts = u.a.z, ti = u.a.w, k = u.g.w, L = u.h.x;
    bool held = ts < 0;
    float grow = held ? .4 + .6 * p : 1;
    float spin = 2.6 * (held ? p : 1) + (held ? 0 : .61 * outE(seg(ts, 0, L))) + (ti >= 0 ? 4 * inE(seg(ti, 0, .3)) : 0);
    float collapse = ti >= 0 ? 1 - inE(seg(ti, .08, .28)) : 1;
    float flare = ti >= 0 ? 1 + 1.6 * (1 - seg(ti, 0, .12)) : 1;
    float fade = (held ? pw(p, .6) : 1) * (ti < 0 ? 1 : 1 - seg(ti, .2, .32));
    float4 o = 0;
    if (fade > 0 && collapse > 0) {
        float2 v = q - u.d.xy;
        float3 acc = 0; float dark = 0;
        const float Rs[3] = {280, 195, 125};
        const float tilts[3] = {.785, .524, .262};
        for (int i = 0; i < 3; i++) {
            float edgeOn = ti >= 0 ? outE(seg(ti, .02 * i, .08 + .02 * i)) : 0;
            float tilt = mix(tilts[i], 1.53, edgeOn);
            float R = Rs[i] * k * grow * collapse;
            float2 w = float2(v.x / max(cos(tilt), .05), v.y);
            float r = length(w), th = atan2(w.y, w.x);
            float arms = .5 + .5 * sin(3 * th + 7 * log(max(r, 1.) / max(R, 1.)) - spin * (1.4 + .3 * i));
            float gas = fbm(float2(th * 2.2 + spin, log(max(r, 1.)) * 3));
            float env = exp(-sq((r - R * .78) / (R * .32)));
            float hue = r / max(R, 1.) * .25 + i * .12;
            acc += pal(u, .25 + .35 * i, hue) * pw(arms, 3) * env * (.35 + .7 * gas) * .8;
            acc += pal(u, .1 * i, hue) * exp(-sq((r - R) / (2.4 * k))) * 1.1;
            if (i == 2) dark = ss(R * .5, R * .2, r);
        }
        o += light(acc * flare, fade);
        o = o * (1 - dark * .55 * fade) + float4(0, 0, 0, dark * .55 * fade);
    }
    // The shock ellipse round the landed card.
    if (ti >= 0) {
        float2 e = (q - u.c.xy) / (float2(240, 160) * k);
        float s = length(e), R = mix(.5, 1.15, outE(seg(ti, 0, .3)));
        float a = (1 - seg(ti, .05, .4)) * ss(0., .03, ti);
        float3 acc = 0;
        for (int c = 0; c < 3; c++) acc += fringe(u, c, atan2(e.y, e.x) / 6.283) * exp(-sq((s - R * (1 + (c - 1) * .035)) / .03));
        o += light(acc, a * 1.4);
    }
    return o;
}

// ---------------------------------------------------------------- Beam
static float4 beamStage(constant U& u, float2 q) {
    float p = u.a.y, ts = u.a.z, ti = u.a.w, k = u.g.w;
    bool held = ts < 0;
    float fade = (held ? seg(p, 0, .3) : 1) * (ti < 0 ? 1 : 1 - seg(ti, 0, .2));
    if (fade <= 0) return 0;
    float x0 = u.c.x + u.c.z * .5, x1 = u.d.x;
    if (q.x < x0 - 4 || q.x > x1) return 0;
    float along = (q.x - x0) / max(x1 - x0, 1.);
    float slice = u.c.w / 9;
    float3 acc = 0;
    float clock = held ? floor(p * 40) : floor(ts * 50);
    for (int n = 0; n < 9; n++) {
        float y = u.c.y + u.c.w * .5 - (n + .5) * slice;
        for (int c = 0; c < 3; c++) {
            float dy = q.y - y - (c - 1) * 1.6 * k * (1 + 2 * (1 - p));
            float line = exp(-sq(dy / (.9 * k)));
            float dash = step(.35, fract(along * 14 - clock * .07 - n * .13 + c * .02));
            acc += fringe(u, c, along * .4 + n * .05) * line * (.35 + .65 * dash) * .55;
        }
    }
    // Glitch blocks near the seam, a new pattern every step of p or time.
    float2 cell = floor(float2(q.x / (26 * k), q.y / (7 * k)));
    float r = h21(cell + clock * 1.37);
    float block = step(.985, r) * ss(.1, .9, along) * step(abs(q.y - u.c.y), u.c.w * .7);
    acc += pal(u, r, r) * block * .9;
    return light(acc, fade * (1 - .6 * along * along));
}

// ---------------------------------------------------------------- Paper plane
static float4 planeStage(constant U& u, float2 q) {
    float p = u.a.y, ts = u.a.z, ti = u.a.w, k = u.g.w;
    bool held = ts < 0;
    float fade = (held ? seg(p, .1, .6) : 1) * (ti < 0 ? 1 : 1 - seg(ti, .05, .45));
    if (fade <= 0 || q.x < u.c.x - u.c.z) return 0;
    // Air: thin streamlines from the seam that bend round the card.
    float3 acc = 0;
    float flow = held ? p * 3 : 3 + ts * 9;
    for (int n = 0; n < 7; n++) {
        float baseY = u.c.y + (n - 3) * 34 * k;
        float bend = (n - 3) * 26 * k * exp(-sq((q.x - u.c.x) / (u.c.z * .9)));
        float y = baseY + bend + 6 * k * sin(q.x / (60 * k) + n * 1.7 + flow);
        float line = exp(-sq((q.y - y) / (.8 * k)));
        float dash = ss(.2, .8, sin(q.x / (18 * k) - flow * 6 + n * 2.1) * .5 + .5);
        float reach = ss(u.c.x - u.c.z * .6, u.c.x + u.c.z * .3, q.x) * (1 - ss(u.d.x - 40 * k, u.d.x, q.x) * .5);
        acc += mix(float3(.96, .97, 1), pal(u, .4, n * .08), .45) * line * dash * reach * .45;
    }
    return light(acc, fade);
}

fragment float4 stage_fs(VOut in [[stage_in]], constant U& u [[buffer(0)]]) {
    float2 q = pointOf(u, in.pos);
    int fx = int(u.a.x + .5);
    switch (fx) {
        case 0: return portalStage(u, q);
        case 1: return liquidStage(u, q, u.i.x);
        case 2: return wormholeStage(u, q);
        case 3: return beamStage(u, q);
        default: return planeStage(u, q);
    }
}

// ---------------------------------------------------------------- Particles
struct PVOut { float4 pos [[position]]; float2 local; float4 color; float shape; };

vertex PVOut particle_vs(uint vid [[vertex_id]], uint iid [[instance_id]], constant U& u [[buffer(0)]]) {
    PVOut o;
    float k = u.g.w, ti = u.a.w;
    int fx = int(u.a.x + .5);
    float fi = float(iid);
    float r1 = h11(fi * 1.31 + 1), r2 = h11(fi * 2.17 + 5), r3 = h11(fi * 3.71 + 9), r4 = h11(fi * 5.03 + 13), r5 = h11(fi * 7.9 + 17);
    float2 c = u.c.xy, hs = u.c.zw * .5;
    float delay = .045 * r4, life = .22 + .3 * r5;
    float t = ti - delay;
    float2 pos = c, vel = 0; float size = 2, shape = 0; float3 col = u.e.rgb; float alpha = 1;
    float drag = 2.4; float2 gravity = 0;
    bool orbit = false;
    if (fx == 0) {
        // Motes off the card's trailing edge and the wave, drifting toward the seam.
        float side = r1 * 2 - 1;
        float2 p0 = r3 < .65 ? c + float2(hs.x * (.6 + .5 * r2), side * hs.y * 1.1)
                             : c + float2(cos(r1 * 6.283) * 280, sin(r1 * 6.283) * 195) * k * (.4 + .3 * r2);
        float ang = (r2 - .5) * 1.4 + (r3 < .65 ? 0 : r1 * 6.283);
        pos = p0; vel = float2(cos(ang), sin(ang)) * (80 + 260 * r5) * k;
        size = (1 + 2.4 * r2) * k; col = r3 < .7 ? u.e.rgb : u.f.rgb; shape = 0;
    } else if (fx == 1) {
        // Spray: droplets thrown up and out from the card's edge, then falling.
        float ang = r1 * 6.283;
        float2 dir = float2(cos(ang), sin(ang));
        pos = c + dir * hs * (.9 + .15 * r2);
        vel = (dir * float2(1.1, .8) + float2(0, .55)) * (140 + 420 * r3) * k;
        gravity = float2(0, -1500 * k); drag = 1.3;
        size = (1.2 + 3.2 * r5 * r5) * k; col = mix(u.f.rgb, u.e.rgb, r2); shape = 4;
    } else if (fx == 2) {
        // Star streaks: half spiral into the point on the edge, half burst off the card.
        if (r3 < .55) {
            orbit = true;
            float2 o0 = u.d.xy; float rr = (120 + 420 * r1) * k; float th = 1.57 + r2 * 3.14;
            life += .1;
            float u1 = inE(seg(t, 0, life));
            float r = rr * (1 - u1), a = th + 2.2 * u1;
            pos = o0 + float2(cos(a) * r * .55, sin(a) * r);
            float2 nxt = o0 + float2(cos(a + .08) * r * .52 * .97, sin(a + .08) * r * .97);
            vel = (nxt - pos) * 60; drag = 0;
        } else {
            float ang = r1 * 6.283;
            pos = c + float2(cos(ang), sin(ang)) * hs * .8;
            vel = float2(cos(ang), sin(ang)) * (220 + 520 * r2) * k;
        }
        size = (1 + 1.6 * r5) * k; col = mix(u.e.rgb, u.f.rgb, r4); shape = 1;
    } else if (fx == 3) {
        // Pixels on a 3 pt grid, from the blade's path across the card, mostly sideways.
        pos = c + float2((r1 * 2 - 1) * hs.x, (r2 * 2 - 1) * hs.y);
        vel = float2((r3 < .7 ? 1 : -1) * (120 + 380 * r4), (r5 - .5) * 40) * k;
        size = (1.6 + 1.6 * r5) * k; shape = 2; life = .12 + .22 * r5;
        col = r3 < .3 ? mix(u.e.rgb, float3(1, .2, .3), .5) : (r3 < .6 ? mix(u.e.rgb, float3(.2, .5, 1), .5) : u.f.rgb);
    } else {
        // Paper flecks, tumbling as they settle.
        float ang = r1 * 6.283;
        pos = c + float2(cos(ang), sin(ang)) * hs * (.7 + .3 * r2);
        vel = float2(cos(ang) * 1.2, sin(ang) * .8 + .4) * (90 + 260 * r3) * k;
        gravity = float2(0, -380 * k); drag = 2;
        size = (2 + 3 * r4) * k; shape = 3; life = .3 + .25 * r5;
        col = mix(float3(.96, .97, 1), u.f.rgb, .18 + .2 * r2);
    }
    if (u.e.w > .5 && fx != 4) col = hsv(fract(u.f.w + r1 * .5 + (pos.x - u.d.x) / 1400), .7, 1);
    bool alive = ti >= 0 && t >= 0 && t <= life;
    float tt = max(t, 0.);
    float2 travel = drag > 0 ? vel * (1 - exp(-drag * tt)) / drag : vel * tt;
    float2 at = orbit ? pos : pos + travel + .5 * gravity * tt * tt;
    if (fx == 3) at = floor(at / (3 * k)) * 3 * k;
    float age = tt / life;
    alpha = ss(0., .08, age) * (1 - ss(.55, 1., age));
    if (fx == 4) alpha *= .55 + .45 * abs(sin(tt * 14 + r1 * 6));
    // The quad: stretched along the velocity for streaks, turning for paper.
    float2 corner = float2(float(vid & 1), float(vid >> 1)) * 2 - 1;
    float2 v = (drag > 0 ? vel * exp(-drag * tt) : vel) + gravity * tt;
    float2 dir = length(v) > 1 ? normalize(v) : float2(1, 0);
    float2 nrm = float2(-dir.y, dir.x);
    float len = shape == 1 ? size * (3 + 6 * r2) : size;
    float2 off = shape == 3 ? rot(corner * float2(size, size * .6), tt * 9 + r1 * 6) : dir * corner.x * len + nrm * corner.y * size;
    float2 pt = at + off;
    float2 ndc = (pt - u.b.zw) / u.b.xy * 2 - 1;
    o.pos = float4(alive ? ndc : float2(-9, -9), 0, 1);
    o.local = corner;
    o.color = float4(col, alpha);
    o.shape = shape;
    return o;
}

fragment float4 particle_fs(PVOut in [[stage_in]]) {
    float2 l = in.local; float m;
    if (in.shape < .5) m = exp(-dot(l, l) * 3);
    else if (in.shape < 1.5) m = exp(-l.y * l.y * 4) * (1 - abs(l.x));
    else if (in.shape < 2.5) m = 1;
    else if (in.shape < 3.5) m = .9;
    else { m = ss(1., .7, length(l)); float2 hl = l - float2(-.3, .35); m += .8 * exp(-dot(hl, hl) * 18); }
    float a = in.color.a * m;
    // Paper is not a light: it covers a little; the rest is additive light.
    float cover = in.shape > 2.5 && in.shape < 3.5 ? a * .8 : a * .3;
    return float4(in.color.rgb * a, cover);
}

// ---------------------------------------------------------------- The card
// i: px per pt, clip x (the screen's edge), corner radius, strength   j: per effect
static float4 cardSample(texture2d<float> tex, sampler s, constant U& u, float2 pt) {
    float2 local = pt - u.c.xy;
    float2 uv = float2(local.x / u.c.z + .5, .5 - local.y / u.c.w);
    float d = sdBox(local, u.c.zw * .5, u.i.z);
    float m = ss(.75, -.75, d);
    return tex.sample(s, uv) * m;
}

fragment float4 card_fs(VOut in [[stage_in]], constant U& u [[buffer(0)]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 q = pointOf(u, in.pos);
    int fx = int(u.a.x + .5);
    float p = u.a.y, ts = u.a.z, ti = u.a.w, k = u.g.w, strength = u.i.w;
    float2 c = u.c.xy, hs = u.c.zw * .5;
    if (fx == 2) {
        // Wormhole: the picture wound into a vortex toward the edge it came from, pinched and split in colour.
        float2 cs = c + float2(hs.x * .45, 0);
        float R = length(hs) * 1.05;
        float2 v = q - cs; float r = length(v);
        float f = clamp(1 - r / R, 0., 1.);
        float a = strength * f * f;
        float pinch = 1 + .45 * (strength / 5) * f;
        float4 col = 0;
        for (int ch = 0; ch < 3; ch++) {
            float aa = a * (1 + (ch - 1) * .05);
            float2 sp = cs + rot(v, -aa) * pinch;
            float4 smp = cardSample(tex, s, u, sp);
            col[ch] = smp[ch]; col.a = max(col.a, smp.a);
        }
        float glowLine = pw(.5 + .5 * sin(atan2(v.y, v.x) * 3 + a * 2), 6) * f * (strength / 5) * col.a;
        col.rgb += pal(u, .4, f) * glowLine * .6;
        return col;
    }
    if (fx == 3) {
        // Beam: nine slices at the offsets Core Animation gives them, glitched rows and an RGB split.
        float slice = u.c.w / 9;
        int n = clamp(int((c.y + hs.y - q.y) / slice), 0, 8);
        float base = u.j.x, lock = u.j.y;
        float off = base * float(n) / 8 * (1 - outE((lock - .012 * n) / .224));
        float g = strength;
        float clock = u.j.z;
        float row = floor(q.y / (3 + 9 * h11(floor(q.y / 11) + clock)));
        float jit = (h21(float2(row, clock)) - .5) * 2;
        jit *= step(.72, h21(float2(row * 1.7, clock + 3)));
        float shift = off + jit * 22 * k * g;
        float split = (1.2 + 6 * g) * k;
        float2 sp = q - float2(shift, 0);
        float4 r = cardSample(tex, s, u, sp + float2(split, 0));
        float4 gg = cardSample(tex, s, u, sp);
        float4 b = cardSample(tex, s, u, sp - float2(split, 0));
        float4 col = float4(r.r, gg.g, b.b, max(max(r.a, gg.a), b.a));
        col.rgb = min(col.rgb, float3(col.a));
        float scan = 1 - .22 * g * step(.5, fract(q.y / (2 * k)));
        col.rgb *= scan;
        float lines = exp(-sq((fract((q.y - c.y) / (8 * k)) - .5) * 8)) * u.j.w;
        col.rgb += mix(u.e.rgb, u.f.rgb, .5) * lines * col.a * .5;
        // A thin coloured edge on each slice.
        float edge = exp(-sq(fract((c.y + hs.y - q.y) / slice) * slice / (1 * k))) * g * col.a;
        col.rgb += pal(u, .3, float(n) * .08) * edge * .5;
        return col;
    }
    if (fx == 0) {
        // Portal light: a lens at the rift, refracting the picture with a chromatic edge.
        float clipX = u.i.y, W = 76 * k;
        float dx = clipX - q.x;
        float f = clamp(1 - dx / W, 0., 1.); f = f * f * (3 - 2 * f);
        // Held and in flight the card is hidden and drawn here whole: plain
        // away from the edge, bent and split in colour as it nears the rift.
        // From the landing the real card is back and only light is drawn.
        float4 col = 0;
        if (ti < 0) {
            if (f > .002) {
                for (int ch = 0; ch < 3; ch++) {
                    float sc = 1 + .3 * ch;
                    float2 sp = q + float2(-f * f * 30 * k * sc, -(q.y - c.y) * .1 * f * sc);
                    float4 smp = cardSample(tex, s, u, sp);
                    col[ch] = smp[ch]; col.a = max(col.a, smp.a);
                }
                float3 edgeLight = u.e.rgb * exp(-sq(dx / (2.5 * k))) + pal(u, .5, q.y / 600) * f * .3;
                col.rgb = min(col.rgb + edgeLight * col.a, float3(col.a));
            } else {
                col = cardSample(tex, s, u, q);
            }
            col *= step(q.x, clipX);
        }
        // The impact's wave runs over the card as light, split in colour.
        if (ti >= 0) {
            float2 lv = q - c; float rr = mix(10., length(hs) * 1.25, outE(seg(ti, 0, .22)));
            float a = 1 - seg(ti, .05, .3);
            float m = ss(.75, -.75, sdBox(lv, hs, u.i.z));
            float3 acc = 0;
            for (int ch = 0; ch < 3; ch++) acc += fringe(u, ch, 0) * exp(-sq((length(lv) - rr * (1 + (ch - 1) * .04)) / (5 * k)));
            col += float4(acc * a * m * .9, 0);
        }
        return col;
    }
    if (fx == 1) {
        // Liquid: a wet sheen sweeping over the picture, ripples at the impact.
        float2 lv = q - c;
        float m = ss(.75, -.75, sdBox(lv, hs, u.i.z));
        float sweep = (ts < 0 ? p : 1 + ts * 2) * 1.6 - .5;
        float band = exp(-sq((dot(lv / hs, normalize(float2(1, .6))) - (1 - 2 * sweep)) / .18));
        float rip = 0;
        if (ti >= 0) rip = pw(.5 + .5 * sin(length(lv) / (7 * k) - ti * 40), 6) * (1 - seg(ti, 0, .4)) * ss(0., 30 * k, length(lv));
        float a = (band * .35 * strength + rip * .3) * m;
        return float4(mix(float3(1), u.e.rgb, .3) * a, a * .4);
    }
    return 0;
}

// ---------------------------------------------------------------- Paper plane
// i: px per pt, left (1) or right (0), corner radius, fold angle (radians)   j.x: crease light
fragment float4 wing_fs(VOut in [[stage_in]], constant U& u [[buffer(0)]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 q = pointOf(u, in.pos);  // the wing's own space: 0...w, 0...h
    bool left = u.i.y > .5;
    float w = u.b.x, h = u.b.y, ang = u.i.w, k = u.g.w;
    float2 uv = float2((left ? 0 : .5) + q.x / w * .5, 1 - q.y / h);
    float4 photo = tex.sample(s, uv);
    // Paper: fibres and a faint tooth.
    float fibre = fbm(q * float2(.9, .22) / k) - .5;
    float tooth = vnoise(q * 1.6 / k) - .5;
    float3 paperTint = float3(.96, .97, 1);
    float3 base = mix(photo.rgb, paperTint * photo.a, .06) * (1 + .05 * fibre + .03 * tooth);
    // Fold light: the half's normal turned by the fold, lit from the upper left.
    float sgn = left ? 1 : -1;
    float3 n = normalize(float3(sin(ang) * sgn, 0, cos(ang)));
    n = normalize(n + float3(fibre * .04, tooth * .04, 0));
    float3 l = normalize(float3(-.35, .5, .8));
    float diffuse = .62 + .45 * max(dot(n, l), 0.);
    float spec = pw(max(dot(reflect(-l, n), float3(0, 0, 1)), 0.), 18) * .35;
    // Toward the crease: ambient occlusion in the valley, a highlight on the ridge.
    float toCrease = left ? (w - q.x) : q.x;
    float ao = 1 - .32 * sin(ang) * exp(-toCrease / (16 * k));
    float ridge = exp(-sq(toCrease / (1.4 * k))) * u.j.x;
    float3 col = base * diffuse * ao + (spec + ridge * .8) * photo.a;
    return float4(min(col + ridge * .2 * photo.a, float3(photo.a)), photo.a);
}
"""#
}
