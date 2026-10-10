// AestheticShader.metal
// RetroPix — DIGICAM / film engine. Lives apart from PixelShader.metal so the 8-bit path stays byte-identical.
//
// Per frame (all GPU: one compute encoder + one render pass):
//   1. aestheticBrightKernel  camera → ¼-res linear highlights (halation seed)
//   2. aestheticBlurKernel    separable Gaussian ×2 (H then V), channel-isolated σ: R > G > B
//   3. aestheticKernel        full-res grade: CA → optical softening → WB/matrix → halation → HSL bands
//                             → global sat → split-tone → tone curve → vignette → grain / chroma noise
//   4. aestheticBlitFragment  bilinear blit to drawable (pairs with blitVertex from PixelShader.metal)
//
// Numbers trace to aesthetic-camera-deep-dive.md §6 (curves §6.1, HSL §6.2, grain §6.3.2, halation §6.3.3).

#include <metal_stdlib>
using namespace metal;

// Mirrors AestheticUniforms in AestheticEngine.swift — 17×float4 + uint2 + 2×float = 288 bytes.
struct AestheticUniforms {
    float4 cropUV;          // sensor-space crop (u0, v0, u1, v1)
    float4 curveA;          // tone curve outputs at x = 0, .25, .5, .75
    float4 curveB;          // x: output at 1.0, y: highlight rolloff (desaturate toward white)
    float4 hueA, hueB;      // HSL band hue shift (deg)   R O Y G | A B P M
    float4 satA, satB;      // HSL band saturation delta
    float4 lumA, lumB;      // HSL band luminance delta
    float4 wbGain;          // rgb: linear WB gains, w: global saturation
    float4 shadowTint;      // rgb: split-tone offset for shadows
    float4 highlightTint;   // rgb: split-tone offset for highlights
    float4 m0, m1, m2;      // 3×3 colour matrix rows (linear light)
    float4 fx;              // x: grain amount, y: grain size (px), z: halation strength, w: halation threshold
    float4 fx2;             // x: vignette, y: softness (<0 sharpens), z: chromatic aberration, w: chroma noise
    uint2  outputSize;
    float  seed;
    float  pixelScale;      // min(outW, outH) / 720 — keeps grain/blur size resolution-independent
};

// Portrait mapping:
// - Back camera: output y → sensor u, output x → sensor v (inverted).
// - Front camera: output x → sensor u (mirrored selfie), output y → sensor v (upright portrait).
static inline float2 cameraUV(float nx, float ny, float4 c, bool isFrontCamera) {
    if (isFrontCamera) {
        return float2(c.z - nx * (c.z - c.x), c.y + ny * (c.w - c.y));
    } else {
        return float2(c.x + ny * (c.z - c.x), c.w - nx * (c.w - c.y));
    }
}

static inline float  luma(float3 c)     { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
static inline float3 toLinear(float3 c) { return pow(max(c, 0.0), 2.2); }
static inline float3 toGamma(float3 c)  { return pow(max(c, 0.0), 1.0 / 2.2); }

static inline float3 rgb2hsv(float3 c) {
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float  d = q.x - min(q.w, q.y);
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + 1e-10)), d / (q.x + 1e-10), q.x);
}

static inline float3 hsv2rgb(float3 c) {
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, saturate(p - K.xxx), c.y);
}

static inline float pick(float4 a, float4 b, int i) { return i < 4 ? a[i] : b[i - 4]; }

// Lightroom-style HSL: 8 band centres, linear blend between neighbours. Returns (dHue°, dSat, dLum).
static inline float3 hslBands(float hDeg, constant AestheticUniforms &u) {
    const float c[9] = { 0.0, 30.0, 60.0, 120.0, 180.0, 240.0, 270.0, 300.0, 360.0 };
    int i = 0;
    while (i < 7 && hDeg >= c[i + 1]) i++;
    float t = saturate((hDeg - c[i]) / (c[i + 1] - c[i]));
    int j = (i + 1) % 8;
    float3 lo = float3(pick(u.hueA, u.hueB, i), pick(u.satA, u.satB, i), pick(u.lumA, u.lumB, i));
    float3 hi = float3(pick(u.hueA, u.hueB, j), pick(u.satA, u.satB, j), pick(u.lumA, u.lumB, j));
    return mix(lo, hi, t);
}

// Uniform Catmull-Rom through 5 knots at x = 0, .25, .5, .75, 1 (end tangents extrapolated).
static inline float toneCurve(float x, float4 a, float e) {
    float p[7] = { 2.0 * a.x - a.y, a.x, a.y, a.z, a.w, e, 2.0 * e - a.w };
    x = saturate(x) * 4.0;
    int   i = min(int(x), 3);
    float t = x - float(i);
    float p0 = p[i], p1 = p[i + 1], p2 = p[i + 2], p3 = p[i + 3];
    return saturate(0.5 * ((2.0 * p1) + (p2 - p0) * t
                         + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t * t
                         + (3.0 * p1 - p0 - 3.0 * p2 + p3) * t * t * t));
}

static inline float hash(uint x, uint y, uint z) {
    uint h = (x * 0x8da6b343u) ^ (y * 0xd8163841u) ^ (z * 0xcb1ab31fu);
    h ^= h >> 16; h *= 0x7feb352du;
    h ^= h >> 15; h *= 0x846ca68bu;
    h ^= h >> 16;
    return float(h) * (1.0 / 4294967295.0);
}

// Bilinear value noise in [-1, 1] — spatially correlated clumps, not per-pixel TV static (§7.3).
static inline float valueNoise(float2 p, uint seed) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    uint x = uint(i.x), y = uint(i.y);
    float a = hash(x, y, seed),     b = hash(x + 1u, y, seed);
    float c = hash(x, y + 1u, seed), d = hash(x + 1u, y + 1u, seed);
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y) * 2.0 - 1.0;
}

// ---------------------------------------------------------------------------
// MARK: — 1. Highlight extraction (¼ res, linear light)
// ---------------------------------------------------------------------------
kernel void aestheticBrightKernel(
    texture2d<float, access::sample> cameraTexture [[texture(0)]],
    texture2d<float, access::write>  outTexture    [[texture(1)]],
    constant AestheticUniforms      &u             [[buffer(0)]],
    uint2                            gid           [[thread_position_in_grid]])
{
    uint w = outTexture.get_width(), h = outTexture.get_height();
    if (gid.x >= w || gid.y >= h) return;

    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float nx = (float(gid.x) + 0.5) / float(w);
    float ny = (float(gid.y) + 0.5) / float(h);
    bool isFront = (u.shadowTint.w > 0.5);
    float2 uv = cameraUV(nx, ny, u.cropUV, isFront);

    // 4 bilinear taps at ±1 full-res px ≈ 4×4 box downsample (avoids sparkle aliasing)
    float2 d = float2((u.cropUV.z - u.cropUV.x) / float(h), (u.cropUV.w - u.cropUV.y) / float(w)) * 0.25;
    float3 c = cameraTexture.sample(s, uv + float2(-d.x, -d.y)).rgb
             + cameraTexture.sample(s, uv + float2( d.x, -d.y)).rgb
             + cameraTexture.sample(s, uv + float2(-d.x,  d.y)).rgb
             + cameraTexture.sample(s, uv + float2( d.x,  d.y)).rgb;
    c = toLinear(c * 0.25);

    float thr = u.fx.w;
    float m = pow(saturate((luma(c) - thr) / max(1.0 - thr, 1e-3)), 1.5);
    outTexture.write(float4(c * m, 1.0), gid);
}

// ---------------------------------------------------------------------------
// MARK: — 2. Channel-isolated separable Gaussian (one tap, three weights)
// ---------------------------------------------------------------------------
kernel void aestheticBlurKernel(
    texture2d<float, access::read>  inTexture  [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    constant float4                &p          [[buffer(0)]],   // σR, σG, σB (px), w > .5 → horizontal
    uint2                           gid        [[thread_position_in_grid]])
{
    int w = int(inTexture.get_width()), h = int(inTexture.get_height());
    if (int(gid.x) >= w || int(gid.y) >= h) return;

    float3 sig = max(p.xyz, 0.3);
    int2   dir = p.w > 0.5 ? int2(1, 0) : int2(0, 1);
    int    radius = min(int(ceil(sig.x * 3.0)), 32);   // σR is the widest
    float3 inv = 1.0 / (2.0 * sig * sig);

    float3 acc = 0.0, wsum = 0.0;
    for (int i = -radius; i <= radius; i++) {
        int2 q = clamp(int2(gid) + dir * i, int2(0), int2(w - 1, h - 1));
        float3 wt = exp(-float(i * i) * inv);
        acc  += inTexture.read(uint2(q)).rgb * wt;
        wsum += wt;
    }
    outTexture.write(float4(acc / wsum, 1.0), gid);
}

// ---------------------------------------------------------------------------
// MARK: — 3. Full-resolution film / digicam grade
// ---------------------------------------------------------------------------
kernel void aestheticKernel(
    texture2d<float, access::sample> cameraTexture [[texture(0)]],
    texture2d<float, access::sample> haloTexture   [[texture(1)]],
    texture2d<float, access::write>  outTexture    [[texture(2)]],
    constant AestheticUniforms      &u             [[buffer(0)]],
    uint2                            gid           [[thread_position_in_grid]])
{
    if (gid.x >= u.outputSize.x || gid.y >= u.outputSize.y) return;

    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float nx = (float(gid.x) + 0.5) / float(u.outputSize.x);
    float ny = (float(gid.y) + 0.5) / float(u.outputSize.y);
    bool isFront = (u.shadowTint.w > 0.5);

    // Lens: barrel distortion / fisheye accessory
    float barrel = u.m1.w;
    if (barrel > 0.0) {
        float2 centered = float2(nx - 0.5, ny - 0.5);
        float r2 = dot(centered, centered);
        float f = 1.0 + barrel * r2 * 2.2;
        nx = 0.5 + centered.x * f;
        ny = 0.5 + centered.y * f;
        if (nx < 0.0 || nx > 1.0 || ny < 0.0 || ny > 1.0) {
            outTexture.write(float4(0.0, 0.0, 0.0, 1.0), gid);
            return;
        }
    }

    float2 uv = cameraUV(nx, ny, u.cropUV, isFront);
    float  r  = length(float2(nx, ny) * 2.0 - 1.0) * 0.70710678;   // 0 centre → 1 corner

    // Lens: lateral chromatic aberration — R scaled out, B scaled in about crop centre (§5.2.2)
    float3 col = cameraTexture.sample(s, uv).rgb;
    float  ca  = u.fx2.z;
    if (ca > 0.0) {
        float2 c = (u.cropUV.xy + u.cropUV.zw) * 0.5;
        col.r = cameraTexture.sample(s, c + (uv - c) * (1.0 + ca)).r;
        col.b = cameraTexture.sample(s, c + (uv - c) * (1.0 - ca)).b;
    }

    // Optical softening: radial mask keeps the centre (focal plane) crisp; negative = CCD-style sharpening (§6.3.4)
    float soft = u.fx2.y;
    if (soft != 0.0) {
        float2 st = float2((u.cropUV.z - u.cropUV.x) / float(u.outputSize.y),
                           (u.cropUV.w - u.cropUV.y) / float(u.outputSize.x)) * (1.5 * u.pixelScale);
        float3 blur = 0.25 * (cameraTexture.sample(s, uv + float2(st.x, 0)).rgb
                            + cameraTexture.sample(s, uv - float2(st.x, 0)).rgb
                            + cameraTexture.sample(s, uv + float2(0, st.y)).rgb
                            + cameraTexture.sample(s, uv - float2(0, st.y)).rgb);
        col = soft > 0.0
            ? mix(col, blur, saturate(soft * (0.15 + 0.85 * smoothstep(0.3, 1.0, r))))
            : saturate(col + (col - blur) * (-soft));
    }

    // Linear light: white balance + colour matrix
    float3 lin = toLinear(col) * u.wbGain.rgb;
    lin = max(float3(dot(u.m0.xyz, lin), dot(u.m1.xyz, lin), dot(u.m2.xyz, lin)), 0.0);

    // Halation: red-dominant re-exposure from blurred highlights, added before tone mapping (§6.3.3)
    float3 h = haloTexture.sample(s, float2(nx, ny)).rgb;
    lin += float3(h.r, h.g * 0.35, h.b * 0.05) * (u.fx.z * 2.0);
    lin /= max(1.0, max(lin.r, max(lin.g, lin.b)));                       // hue-preserving clip
    float Ll = luma(lin);
    lin = mix(lin, float3(Ll), smoothstep(0.7, 1.0, Ll) * u.curveB.y);    // highlight rolloff to white

    // Display space: HSL bands (Lightroom units pre-scaled on CPU)
    float3 g   = toGamma(lin);
    float3 hsv = rgb2hsv(g);
    float3 dv  = hslBands(hsv.x * 360.0, u);
    hsv.x = fract(hsv.x + dv.x / 360.0 + 1.0);
    hsv.z = hsv.z * (1.0 + dv.z * hsv.y);
    hsv.y = saturate(hsv.y * (1.0 + dv.y));
    g = hsv2rgb(hsv);

    // Global saturation + split toning (shadows ∝ (1-L)², highlights ∝ L²)
    float L = luma(g);
    g = mix(float3(L), g, u.wbGain.w);
    g += u.shadowTint.rgb * (1.0 - L) * (1.0 - L) + u.highlightTint.rgb * L * L;

    // Tone curve (toe / shoulder per look)
    g = float3(toneCurve(g.r, u.curveA, u.curveB.x),
               toneCurve(g.g, u.curveA, u.curveB.x),
               toneCurve(g.b, u.curveA, u.curveB.x));

    // Vignette: I·(1 − k·r^2.5)
    g *= 1.0 - u.fx2.x * pow(r, 2.5);

    // Direct flash point-source falloff & warm skin specular bloom
    float flashActive = u.highlightTint.w;
    if (flashActive > 0.0) {
        float falloff = 1.0 - 0.35 * flashActive * smoothstep(0.18, 0.95, r);
        g *= falloff;
        float spec = smoothstep(0.68, 0.98, luma(g)) * flashActive;
        g += float3(0.08, 0.045, 0.01) * spec;
    }

    // Procedural warm film light leak / edge burn
    float leakStrength = u.m0.w;
    if (leakStrength > 0.0) {
        float lkSeed = fract(u.seed * 0.00137 + 0.17);
        float2 lkOrigin = (lkSeed > 0.5)
            ? float2(0.02, 0.15 + 0.7 * lkSeed)
            : float2(0.98, 0.85 - 0.7 * lkSeed);
        float dLk = distance(float2(nx, ny), lkOrigin);
        float lkNoise = 0.5 + 0.5 * valueNoise(float2(nx, ny) * 3.5, uint(u.seed) + 42u);
        float lkMask = smoothstep(0.65, 0.0, dLk) * lkNoise * leakStrength;
        float3 lkColor = float3(1.0, 0.38, 0.06);
        g = 1.0 - (1.0 - g) * (1.0 - lkColor * lkMask);
    }

    // Film grain: two octaves of correlated noise, peaks in midtones, extra in shadows, fades in highlights (§6.3.2)
    float Lg = saturate(luma(g));
    uint  sd = uint(u.seed);
    if (u.fx.x > 0.0) {
        float2 pp = float2(gid) / max(u.fx.y * u.pixelScale, 0.5);
        float  n  = 0.7 * valueNoise(pp, sd) + 0.3 * valueNoise(pp * 0.43 + 17.0, sd + 7u);
        float  mask = 0.12 * pow(4.0 * Lg * (1.0 - Lg), 0.7) + 0.05 * (1.0 - Lg) * (1.0 - Lg);
        g += n * mask * u.fx.x * 2.0;
    }

    // Sensor chroma noise (CCD / tiny sensor): blotchy, blue/magenta-biased, shadows only (§6.5)
    if (u.fx2.w > 0.0) {
        uint2 q = gid / uint(max(u.pixelScale * 1.5, 1.0));
        float3 rn = float3(hash(q.x, q.y, sd * 3u + 1u),
                           hash(q.x, q.y, sd * 3u + 2u),
                           hash(q.x, q.y, sd * 3u + 3u)) * 2.0 - 1.0;
        g += rn * float3(1.2, 0.8, 1.6) * (u.fx2.w * 0.06 * (1.0 - Lg) * (1.0 - Lg));
    }

    outTexture.write(float4(saturate(g), 1.0), gid);
}

// ---------------------------------------------------------------------------
// MARK: — 4. Bilinear blit (film output must not get nearest-neighbour blocks)
// ---------------------------------------------------------------------------
struct AestheticVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

fragment float4 aestheticBlitFragment(
    AestheticVertexOut               in  [[stage_in]],
    texture2d<float, access::sample> tex [[texture(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return tex.sample(s, in.texCoord);
}
