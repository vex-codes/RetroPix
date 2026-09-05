// PixelShader.metal
// RetroPix — Custom GPU rendering pipeline.
//
// Compute kernel:  camera texture → 256×128 dithered + palette-quantized texture.
// Vertex+fragment: 256×128 pixel texture → fullscreen letterboxed drawable (nearest-neighbor).

#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// MARK: — 8×8 Bayer ordered dither matrix (values 0–63)
// Standard Bayer matrix gives the classic crosshatch / halftone dither pattern.
// ---------------------------------------------------------------------------
constant int bayer8[64] = {
     0, 32,  8, 40,  2, 34, 10, 42,
    48, 16, 56, 24, 50, 18, 58, 26,
    12, 44,  4, 36, 14, 46,  6, 38,
    60, 28, 52, 20, 62, 30, 54, 22,
     3, 35, 11, 43,  1, 33,  9, 41,
    51, 19, 59, 27, 49, 17, 57, 25,
    15, 47,  7, 39, 13, 45,  5, 37,
    63, 31, 55, 23, 61, 29, 53, 21
};

// Camera crop constants — 720p (1280×720) → 2:1 center (1280×640).
// Vertical offset = (720 − 640) / 2 = 40 px → 40/720 ≈ 0.05556
constant float CROP_V0 = 40.0 / 720.0;
constant float CROP_V1 = 680.0 / 720.0;

// Dither spread is now a per-frame uniform — see MetalRenderer.ditherSpread.

// ---------------------------------------------------------------------------
// MARK: — Compute kernel: camera → 256×128 dithered pixel art
// ---------------------------------------------------------------------------
kernel void pixelKernel(
    texture2d<float, access::sample>  cameraTexture  [[texture(0)]],
    texture2d<float, access::write>   outputTexture  [[texture(1)]],
    constant float4                  *palette        [[buffer(0)]],   // up to 8 × float4(r,g,b,0)
    constant uint                    &paletteCount   [[buffer(1)]],
    constant float                   &ditherSpread   [[buffer(2)]],   // 0.0–1.0 from CameraViewModel
    uint2                             gid            [[thread_position_in_grid]])
{
    if (gid.x >= 256u || gid.y >= 128u) return;

    // --- 1. Sample camera texture at pixel center (with 2:1 center crop) ---
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float u = (float(gid.x) + 0.5) / 256.0;
    float v = CROP_V0 + ((float(gid.y) + 0.5) / 128.0) * (CROP_V1 - CROP_V0);
    float3 color = cameraTexture.sample(s, float2(u, v)).rgb;

    // --- 2. Bayer threshold in [−0.5, +0.5] ---
    int bx = int(gid.x) % 8;
    int by = int(gid.y) % 8;
    float threshold = (float(bayer8[by * 8 + bx]) / 63.0) - 0.5;

    // --- 3. Apply dither offset to each RGB channel ---
    float3 dithered = clamp(color + threshold * ditherSpread, 0.0, 1.0);

    // --- 4. Palette quantize — nearest color in Euclidean RGB space ---
    float  minDist = 1e9;
    float3 bestColor = palette[0].rgb;
    for (uint i = 0u; i < paletteCount; i++) {
        float3 diff = dithered - palette[i].rgb;
        float  dist = dot(diff, diff);
        if (dist < minDist) {
            minDist   = dist;
            bestColor = palette[i].rgb;
        }
    }

    outputTexture.write(float4(bestColor, 1.0), gid);
}

// ---------------------------------------------------------------------------
// MARK: — Fullscreen blit (nearest-neighbor upscale 256×128 → screen)
// ---------------------------------------------------------------------------
struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// `scale` shrinks the quad for letterboxing when screen aspect ≠ 2:1.
// Pass float2(1,1) for fill, or e.g. float2(0.92,1) to add side bars.
vertex VertexOut blitVertex(
    uint             vid   [[vertex_id]],
    constant float2 &scale [[buffer(0)]])
{
    // Two-triangle quad covering [−scale, +scale] in NDC.
    float2 pos[6] = {
        float2(-1, -1), float2( 1, -1), float2(-1,  1),
        float2( 1, -1), float2( 1,  1), float2(-1,  1)
    };
    // UV: (0,0)=top-left, (1,1)=bottom-right — matches Metal texture convention.
    float2 uv[6] = {
        float2(0, 1), float2(1, 1), float2(0, 0),
        float2(1, 1), float2(1, 0), float2(0, 0)
    };

    VertexOut out;
    out.position = float4(pos[vid] * scale, 0.0, 1.0);
    out.texCoord = uv[vid];
    return out;
}

fragment float4 blitFragment(
    VertexOut                        in  [[stage_in]],
    texture2d<float, access::sample> tex [[texture(0)]])
{
    // nearest: hard pixel edges — this is the entire point of the app.
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    return tex.sample(s, in.texCoord);
}
