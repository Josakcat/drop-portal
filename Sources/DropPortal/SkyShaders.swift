//
//  SkyShaders.swift
//  DropPortal
//
//  Metal source for Stardust and Lightning (SkyMetal.swift compiles it off
//  the main thread). Everything draws into rgba16Float in extended linear
//  sRGB, so a value above 1 is EDR; only the Stardust glint and the
//  lightning's return stroke ever go there.
//
//  grain_vs/grain_fs     Stardust: one grain per point of the card, flying in
//                        from the right edge (premultiplied over)
//  glitter_vs/glow_fs    one grain in ten twinkling (additive)
//  filler_vs/glow_fs     the holding stardust at the right edge (additive)
//  bolt_vs/bolt_fs       Lightning: the bolt as strips, core and halo (MAX blend)
//  down_fs/up_fs         the bloom chain over the bolt (Karis first, 3×3 tent up)
//  comp_fs               bolt + bloom + the lavender holding glow, onto the canvas
//  lift_fs               the card's own light: the glint, the exposure lift
//
//  Grains are stateless: position = f(id, seconds, seed). Shader rules from
//  MetalFXShaders: no smoothstep with reversed edges (ss), no pow of 0.
//

enum SkyShaders {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

struct SkyU {
    float4 a;  // mode (0 stardust, 1 lightning), p, seconds since send (-1), since landing (-1)
    float4 b;  // layer width, height (pt), pixels per point, headroom
    float4 c;  // landing card centre x, y, width, height (pt)
    float4 d;  // seam x, y; vortex time; filler level
    float4 e;  // glow (linear rgb), rainbow
    float4 f;  // core (linear rgb), rainbow turn
    float4 g;  // grid columns, rows, filler count, seed
    float4 h;  // flight L, bolt level, leader reveal, k (the spec's scale)
    float4 i;  // per pass: lift / glint, core gain, radius, karis
    float4 j;  // Stardust: hold, launch spread, shortest flight, longest flight
};

struct BoltVertex { float2 p; float2 n; float along; float side; float weight; float pad; };

constexpr sampler lin(filter::linear, address::clamp_to_edge);

static uint hsh(uint x) {
    x = x * 747796405u + 2891336453u;
    x = ((x >> ((x >> 28u) + 4u)) ^ x) * 277803737u;
    return (x >> 22u) ^ x;
}
static float rnd(uint n) { return float(hsh(n)) * (1.0 / 4294967296.0); }
static float ss(float a, float b, float x) { float t = clamp((x - a) / (b - a), 0.0, 1.0); return t * t * (3.0 - 2.0 * t); }
static float bez(float x, float x1, float y1, float x2, float y2) {
    x = clamp(x, 0.0, 1.0);
    float lo = 0.0, hi = 1.0, t = 0.5;
    for (int n = 0; n < 14; n++) {
        t = (lo + hi) * 0.5;
        float v = 3.0 * (1.0 - t) * (1.0 - t) * t * x1 + 3.0 * (1.0 - t) * t * t * x2 + t * t * t;
        if (v < x) lo = t; else hi = t;
    }
    return 3.0 * (1.0 - t) * (1.0 - t) * t * y1 + 3.0 * (1.0 - t) * t * t * y2 + t * t * t;
}
static float decel(float x) { return bez(x, 0.05, 0.7, 0.1, 1.0); }
static float4 ndc(float2 p, constant SkyU& u) { return float4(p.x / u.b.x * 2.0 - 1.0, p.y / u.b.y * 2.0 - 1.0, 0.0, 1.0); }
static float3 hue(float h) { h = fract(h); return clamp(abs(fmod(h * 6.0 + float3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0, 0.0, 1.0); }
static float3 toLinear(float3 c) { return c * c * (0.3 + 0.7 * c); }
constant float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };

// The curl of a stream function (two waves): a flow that neither bunches nor thins.
static float2 curl(float2 p, float t) {
    float a = 1.0, b = 0.8;
    float A = p.x * a + 1.3 * t, B = p.y * b - 0.9 * t, C = 1.7 * b * p.x - 1.3 * a * p.y + t;
    float dx = a * cos(A) * cos(B) + 0.85 * b * cos(C);
    float dy = -b * sin(A) * sin(B) - 0.65 * a * cos(C);
    return float2(dy, -dx) * 0.5;
}

// ---------------------------------------------------------------- Stardust

struct GOut { float4 pos [[position]]; float4 col; float2 q; float grow; };

/// One image grain at `ts`: false before it launches.
static bool grainPath(uint id, constant SkyU& u, float ts, thread float2& pos, thread float& prog,
                      thread float& grow, thread float2& uv) {
    uint cols = max(1u, uint(u.g.x)), rows = max(1u, uint(u.g.y));
    uint col = id % cols, row = id / cols;
    uv = float2((float(col) + 0.5) / float(cols), (float(row) + 0.5) / float(rows));
    uint seed = uint(u.g.w);
    float r = rnd(id * 3u + 1u + seed), r2 = rnd(id * 3u + 2u + seed);
    float shape = (sin(uv.x * 12.0 + uv.y * 9.0) + cos(uv.y * 17.0 - uv.x * 5.0) + 2.0) * 0.25;
    float arrival = 0.5 * (1.0 - uv.x) + 0.2 * shape + 0.3 * r;
    float launch = u.j.x + u.j.y * arrival, d = mix(u.j.z, u.j.w, r2);
    if (ts < launch) return false;
    float t = min(1.0, (ts - launch) / d), e = decel(t), k = u.h.w;
    float2 home = u.c.xy + float2((uv.x - 0.5) * u.c.z, (0.5 - uv.y) * u.c.w);
    float2 start = float2(u.d.x + (10.0 + 80.0 * r) * k, u.d.y + (r2 - 0.5) * 70.0 * k + (0.5 - uv.y) * u.c.w * 0.35);
    float2 p = mix(start, home, e);
    p += curl(p / (60.0 * k), ts * 2.0 + r * 6.0) * 30.0 * k * (1.0 - e);
    pos = p; prog = t; grow = clamp((t - 0.8) / 0.2, 0.0, 1.0);
    return true;
}

vertex GOut grain_vs(uint vid [[vertex_id]], uint iid [[instance_id]], constant SkyU& u [[buffer(0)]],
                     texture2d<float> card [[texture(0)]]) {
    GOut o;
    o.pos = float4(-2.0, -2.0, 0.0, 1.0); o.col = 0; o.q = 0; o.grow = 0;
    float ts = u.a.z;
    float2 p, uv; float prog, grow;
    if (ts < 0.0 || !grainPath(iid, u, ts, p, prog, grow, uv)) return o;
    float4 c = card.sample(lin, uv, level(0));
    if (c.a < 0.05) return o;
    // Gone under the real picture as it crossfades in.
    float fade = 1.0 - ss(u.h.x - 0.02, u.h.x + 0.06, ts);
    if (fade <= 0.0) return o;
    float cell = u.c.z / max(1.0, u.g.x);
    float size = max(mix(0.9, cell * 1.12, grow), 1.3 / u.b.z);
    o.pos = ndc(p + corners[vid] * size * 0.5, u);
    o.col = float4(c.rgb / c.a, c.a * fade);
    o.q = corners[vid];
    o.grow = grow;
    return o;
}

fragment float4 grain_fs(GOut in [[stage_in]]) {
    float disc = 1.0 - ss(0.55, 1.0, length(in.q));
    float a = mix(disc, 1.0, in.grow) * in.col.a;
    return float4(in.col.rgb * a, a);
}

struct LOut { float4 pos [[position]]; float3 col; float2 q; };

vertex LOut glitter_vs(uint vid [[vertex_id]], uint iid [[instance_id]], constant SkyU& u [[buffer(0)]]) {
    LOut o;
    o.pos = float4(-2.0, -2.0, 0.0, 1.0); o.col = 0; o.q = 0;
    uint id = iid * 10u + hsh(iid + 77u) % 10u;
    if (float(id) >= u.g.x * u.g.y) return o;
    float ts = u.a.z;
    float2 p, uv; float prog, grow;
    if (ts < 0.0 || !grainPath(id, u, ts, p, prog, grow, uv)) return o;
    // Twinkles at 6 Hz; 0.12 + 0.88·rand⁴, so few are brilliant.
    float tw = rnd(id * 7919u + uint(ts * 6.0) * 104729u);
    float b = (0.12 + 0.88 * tw * tw * tw * tw) * (1.0 - ss(0.6, 0.8, prog));
    if (b <= 0.01) return o;
    float3 tint = u.e.w > 0.5 ? toLinear(hue(u.f.w + uv.y * 0.5)) : u.e.rgb;
    o.col = mix(float3(1.0, 0.98, 0.94), tint, 0.25) * b * 0.8;
    // A 4 pt gaussian, never under three pixels across.
    o.pos = ndc(p + corners[vid] * max(2.0 * u.h.w, 1.5 / u.b.z), u);
    o.q = corners[vid];
    return o;
}

vertex LOut filler_vs(uint vid [[vertex_id]], uint iid [[instance_id]], constant SkyU& u [[buffer(0)]]) {
    LOut o;
    o.pos = float4(-2.0, -2.0, 0.0, 1.0); o.col = 0; o.q = 0;
    float level = u.d.w;
    if (level <= 0.001) return o;
    float k = u.h.w, time = u.d.z;
    float h0 = rnd(iid * 5u + 11u), h1 = rnd(iid * 5u + 12u), h2 = rnd(iid * 5u + 13u), h3 = rnd(iid * 5u + 14u);
    // Streams in from beyond the right edge and spirals into a soft vortex just inside it.
    float phase = fract(time / (0.8 + 0.6 * h2) + h0);
    float2 centre = float2(u.d.x - 34.0 * k, u.d.y);
    // Never into one hot point: the eye of the vortex stays 16 pt wide and dims as grains reach it.
    float radius = (40.0 + 230.0 * h1) * k * pow(max(1.0 - phase, 0.001), 1.2) + 16.0 * k;
    float angle = (h3 - 0.5) * 2.4 + phase * (2.6 + 2.0 * h1);
    float2 p = centre + float2(cos(angle) * radius * 0.55, sin(angle) * radius);
    float b = sin(3.14159 * phase) * (0.3 + 0.7 * (1.0 - phase)) * level * (0.35 + 0.65 * h2);
    float3 tint = u.e.w > 0.5 ? toLinear(hue(u.f.w + angle * 0.08)) : mix(u.e.rgb, u.f.rgb, h3 * 0.6);
    o.col = tint * b * 0.9;
    o.pos = ndc(p + corners[vid] * max((1.0 + 1.4 * h2) * k, 1.4 / u.b.z), u);
    o.q = corners[vid];
    return o;
}

fragment float4 glow_fs(LOut in [[stage_in]]) {
    float g = exp(-dot(in.q, in.q) * 3.0);
    float3 c = in.col * g;
    // Light needs a little cover: a colour over zero alpha is lost in any colour conversion.
    return float4(c, min(1.0, max(c.r, max(c.g, c.b))) * 0.6);
}

// ---------------------------------------------------------------- Lightning

struct BOut { float4 pos [[position]]; float along; float side; float weight; float half_; };

vertex BOut bolt_vs(uint vid [[vertex_id]], constant SkyU& u [[buffer(0)]], const device BoltVertex* v [[buffer(1)]]) {
    BoltVertex b = v[vid];
    BOut o;
    float half_ = 14.0 * u.h.w * max(b.weight, 0.5);
    o.pos = ndc(b.p + b.n * b.side * half_, u);
    o.along = b.along; o.side = b.side; o.weight = b.weight; o.half_ = half_;
    return o;
}

fragment float4 bolt_fs(BOut in [[stage_in]], constant SkyU& u [[buffer(0)]]) {
    if (in.along > u.h.z + 0.001) discard_fragment();
    float d = abs(in.side) * in.half_;
    float px = 1.0 / u.b.z;
    // Core 2 pt on the trunk (1.5 to 2.5 with the screen), branches 40 to 60 % of it.
    float core = 1.0 - ss(in.weight * 1.0 - 0.5 * px, in.weight * 1.0 + 0.5 * px, d);
    float sigma = 6.0 * u.h.w * max(in.weight, 0.5);
    float halo = exp(-d * d / (sigma * sigma));
    float level = u.h.y * (0.55 + 0.45 * in.weight);
    float3 ice = u.e.rgb;
    float3 c = float3(1.0) * core * level * u.i.y + ice * halo * 0.32 * level;
    return float4(c, max(core, halo * 0.32) * level);
}

struct TOut { float4 pos [[position]]; float2 uv; };
vertex TOut sky_tri(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    TOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

// Downsample: four bilinear taps (a 4×4 box); the first level weighs each by 1/(1+luma) (Karis).
fragment float4 down_fs(TOut in [[stage_in]], constant SkyU& u [[buffer(0)]], texture2d<float> src [[texture(0)]]) {
    float2 t = 1.0 / float2(src.get_width(), src.get_height());
    float4 s0 = src.sample(lin, in.uv + t * float2(-1, -1)), s1 = src.sample(lin, in.uv + t * float2(1, -1));
    float4 s2 = src.sample(lin, in.uv + t * float2(-1, 1)), s3 = src.sample(lin, in.uv + t * float2(1, 1));
    if (u.i.w > 0.5) {
        float w0 = 1.0 / (1.0 + dot(s0.rgb, float3(0.2126, 0.7152, 0.0722)));
        float w1 = 1.0 / (1.0 + dot(s1.rgb, float3(0.2126, 0.7152, 0.0722)));
        float w2 = 1.0 / (1.0 + dot(s2.rgb, float3(0.2126, 0.7152, 0.0722)));
        float w3 = 1.0 / (1.0 + dot(s3.rgb, float3(0.2126, 0.7152, 0.0722)));
        return (s0 * w0 + s1 * w1 + s2 * w2 + s3 * w3) / (w0 + w1 + w2 + w3);
    }
    return (s0 + s1 + s2 + s3) * 0.25;
}

// Upsample: a 3×3 tent from the smaller level, added onto the larger.
fragment float4 up_fs(TOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
    float2 t = 1.0 / float2(src.get_width(), src.get_height());
    float4 s = src.sample(lin, in.uv) * 4.0;
    s += (src.sample(lin, in.uv + t * float2(-1, 0)) + src.sample(lin, in.uv + t * float2(1, 0))
        + src.sample(lin, in.uv + t * float2(0, -1)) + src.sample(lin, in.uv + t * float2(0, 1))) * 2.0;
    s += src.sample(lin, in.uv + t * float2(-1, -1)) + src.sample(lin, in.uv + t * float2(1, -1))
       + src.sample(lin, in.uv + t * float2(-1, 1)) + src.sample(lin, in.uv + t * float2(1, 1));
    return s / 16.0;
}

// The bolt, its bloom and the faint lavender glow that holds the edge (opacity only).
fragment float4 comp_fs(TOut in [[stage_in]], constant SkyU& u [[buffer(0)]],
                        texture2d<float> bolt [[texture(0)]], texture2d<float> bloom [[texture(1)]]) {
    float4 b = bolt.sample(lin, in.uv);
    float4 m = bloom.sample(lin, in.uv);
    float2 q = float2(in.uv.x * u.b.x, (1.0 - in.uv.y) * u.b.y);
    float k = u.h.w;
    float2 dq = (q - u.d.xy) / float2(70.0 * k, 240.0 * k);
    float hold = exp(-dot(dq, dq)) * u.d.w;
    float3 c = b.rgb + m.rgb * u.i.x + u.f.rgb * hold * 0.22;
    float cover = clamp(max(b.a, hold * 0.12), 0.0, 1.0);
    return float4(c, cover * 0.6);
}

// ---------------------------------------------------------------- The card's light

// Added inside the card's rounded rect only: Stardust's glint (a band across
// the card at up to the glint's EDR multiple) and Lightning's exposure lift.
fragment float4 lift_fs(TOut in [[stage_in]], constant SkyU& u [[buffer(0)]]) {
    float2 q = float2(in.uv.x * u.b.x, (1.0 - in.uv.y) * u.b.y);
    float2 h = u.c.zw * 0.5, rr = float2(u.i.z);
    float2 dq = abs(q - u.c.xy) - h + rr;
    float sdf = length(max(dq, 0.0)) + min(max(dq.x, dq.y), 0.0) - u.i.z;
    float px = 1.0 / u.b.z;
    float mask = 1.0 - ss(-px, px, sdf);
    if (mask <= 0.0) return float4(0.0);
    float2 n = (q - u.c.xy) / max(h, float2(1.0));
    // The band sweeps from the top right corner to the bottom left while the glint plays.
    float along = (n.x + n.y) * 0.5, sweep = mix(1.2, -1.2, clamp(u.i.y, 0.0, 1.0));
    float band = exp(-(along - sweep) * (along - sweep) * 18.0);
    float add = u.i.x * (0.35 + 0.65 * band);
    return float4(float3(add) * mask, min(0.3, add * 0.3) * mask);
}
"""#
}
