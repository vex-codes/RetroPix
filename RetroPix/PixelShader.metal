// PixelShader.metal
// RetroPix — Custom GPU rendering pipeline.
//
// Compute kernel:  camera texture → dynamic dithered + palette-quantized texture.
// Vertex+fragment: pixel texture → fullscreen letterboxed drawable (nearest-neighbor).

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

// ---------------------------------------------------------------------------
// MARK: — Compute kernel: camera → dynamic dithered pixel art
// ---------------------------------------------------------------------------
struct KernelUniforms {
    float4 cropUV;
    uint2  outputSize;
    float  ditherSpread;
    uint   paletteCount;
    uint   isFrontCamera;
};

kernel void pixelKernel(
    texture2d<float, access::sample>  cameraTexture  [[texture(0)]],
    texture2d<float, access::write>   outputTexture  [[texture(1)]],
    constant float4                  *palette        [[buffer(0)]],   // up to 8 × float4(r,g,b,0)
    constant KernelUniforms          &uniforms       [[buffer(1)]],
    uint2                             gid            [[thread_position_in_grid]])
{
    if (gid.x >= uniforms.outputSize.x || gid.y >= uniforms.outputSize.y) return;

    // --- 1. Compute normalized sample coordinates inside output grid ---
    float nx = (float(gid.x) + 0.5) / float(uniforms.outputSize.x);
    float ny = (float(gid.y) + 0.5) / float(uniforms.outputSize.y);

    // Portrait UV mapping
    float u, v;
    if (uniforms.isFrontCamera == 1u) {
        // Front camera: inverted vertical axis for upright sensor, mirrored horizontal for selfie view
        u = uniforms.cropUV.z - ny * (uniforms.cropUV.z - uniforms.cropUV.x);
        v = uniforms.cropUV.y + nx * (uniforms.cropUV.w - uniforms.cropUV.y);
    } else {
        // Back camera: sensor long axis (ny) -> u, sensor short axis (nx) -> v inverted
        u = uniforms.cropUV.x + ny * (uniforms.cropUV.z - uniforms.cropUV.x);
        v = uniforms.cropUV.w - nx * (uniforms.cropUV.w - uniforms.cropUV.y);
    }

    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 color = cameraTexture.sample(s, float2(u, v)).rgb;

    // --- 2. Bayer threshold in [−0.5, +0.5] ---
    int bx = int(gid.x) % 8;
    int by = int(gid.y) % 8;
    float threshold = (float(bayer8[by * 8 + bx]) / 63.0) - 0.5;

    // --- 3. Apply dither offset to each RGB channel ---
    float3 dithered = clamp(color + threshold * uniforms.ditherSpread, 0.0, 1.0);

    // --- 4. Palette quantize — nearest color in Euclidean RGB space ---
    float  minDist = 1e9;
    float3 bestColor = palette[0].rgb;
    for (uint i = 0u; i < uniforms.paletteCount; i++) {
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
// MARK: — Fullscreen blit (nearest-neighbor upscale → screen)
// ---------------------------------------------------------------------------
struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut blitVertex(
    uint             vid   [[vertex_id]],
    constant float2 &scale [[buffer(0)]])
{
    float2 pos[6] = {
        float2(-1, -1), float2( 1, -1), float2(-1,  1),
        float2( 1, -1), float2( 1,  1), float2(-1,  1)
    };
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
    // nearest: hard pixel edges — essential retro aesthetic
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    return tex.sample(s, in.texCoord);
}
