// PixelShader.metal
// RetroPix — Custom GPU rendering pipeline.
//
// Compute kernels:
//   - pixelKernel:          parallel Bayer 8×8 & Blue Noise spatial dithering + palette quantization.
//   - errorDiffusionKernel: Atkinson (Mac '84) & Floyd-Steinberg scanline error diffusion.
// Vertex+fragment:          pixel texture → fullscreen letterboxed drawable (nearest-neighbor).

#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// MARK: — 8×8 Bayer ordered dither matrix (values 0–63)
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
// MARK: — 16×16 Blue Noise spatial dither matrix (values 0–255)
// Void-and-cluster high-frequency distribution for filmic organic grain.
// ---------------------------------------------------------------------------
constant uchar blueNoise16[256] = {
     35, 185,  75, 245,  15, 175,  65, 225,  40, 190,  80, 250,  20, 180,  70, 230,
    215, 105, 145,  45, 195,  95, 135,  10, 220, 110, 150,  50, 200, 100, 140,  12,
     85, 255,  25, 165,  55, 235,  30, 160,  88, 254,  28, 168,  58, 238,  32, 162,
    135,  60, 205, 115, 155,   5, 125,  78, 138,  62, 208, 118, 158,   8, 128,  76,
     18, 178,  68, 228,  38, 188,  82, 248,  16, 176,  66, 226,  36, 186,  84, 246,
    198,  98, 138,  14, 218, 108, 148,  48, 196,  96, 136,  16, 216, 106, 146,  46,
     52, 232,  34, 164,  86, 252,  26, 170,  54, 234,  36, 166,  84, 251,  24, 172,
    152,   2, 122,  74, 132,  58, 202, 112, 154,   4, 124,  72, 134,  56, 204, 114,
     42, 192,  82, 242,  22, 182,  72, 232,  34, 184,  74, 244,  14, 174,  64, 224,
    222, 112, 152,  52, 202, 102, 142,   8, 214, 104, 144,  44, 194,  94, 134,  11,
     90, 252,  27, 167,  57, 237,  33, 163,  82, 253,  23, 163,  53, 233,  29, 159,
    140,  64, 210, 120, 160,   7, 127,  77, 133,  59, 203, 113, 153,   3, 123,  79,
     24, 184,  72, 234,  44, 194,  88, 254,  21, 181,  69, 229,  39, 189,  83, 249,
    204, 104, 144,  20, 224, 114, 154,  54, 201, 101, 141,  15, 219, 109, 149,  49,
     60, 240,  40, 172,  92, 253,  31, 174,  56, 236,  34, 168,  86, 250,  26, 168,
    160,  10, 130,  80, 140,  66, 212, 122, 156,   6, 126,  75, 136,  60, 206, 116
};

// ---------------------------------------------------------------------------
// MARK: — Kernel Uniforms (16-byte aligned, 48 bytes total)
// ---------------------------------------------------------------------------
struct KernelUniforms {
    float4 cropUV;
    uint2  outputSize;
    float  ditherSpread;
    uint   paletteCount;
    uint   ditherAlgorithm; // 0: Bayer 8x8, 1: Blue Noise, 2: Atkinson, 3: Floyd-Steinberg
    uint   _pad0;
    uint   _pad1;
    uint   _pad2;
};

// ---------------------------------------------------------------------------
// MARK: — Parallel Compute Kernel: Bayer 8×8 & Blue Noise
// ---------------------------------------------------------------------------
kernel void pixelKernel(
    texture2d<float, access::sample>  cameraTexture  [[texture(0)]],
    texture2d<float, access::write>   outputTexture  [[texture(1)]],
    constant float4                  *palette        [[buffer(0)]],   // up to 8 × float4(r,g,b,0)
    constant KernelUniforms          &uniforms       [[buffer(1)]],
    uint2                             gid            [[thread_position_in_grid]])
{
    if (gid.x >= uniforms.outputSize.x || gid.y >= uniforms.outputSize.y) return;

    // 1. Compute normalized sample coordinates inside output grid
    float nx = (float(gid.x) + 0.5) / float(uniforms.outputSize.x);
    float ny = (float(gid.y) + 0.5) / float(uniforms.outputSize.y);

    // Portrait: sensor long axis (ny) -> u, sensor short axis (nx) -> v inverted
    float u = uniforms.cropUV.x + ny * (uniforms.cropUV.z - uniforms.cropUV.x);
    float v = uniforms.cropUV.w - nx * (uniforms.cropUV.w - uniforms.cropUV.y);

    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 color = cameraTexture.sample(s, float2(u, v)).rgb;

    // 2. Spatial dither threshold in [-0.5, +0.5]
    float threshold = 0.0;
    if (uniforms.ditherAlgorithm == 1) {
        int bx = int(gid.x) % 16;
        int by = int(gid.y) % 16;
        threshold = (float(blueNoise16[by * 16 + bx]) / 255.0) - 0.5;
    } else {
        int bx = int(gid.x) % 8;
        int by = int(gid.y) % 8;
        threshold = (float(bayer8[by * 8 + bx]) / 63.0) - 0.5;
    }

    // 3. Apply dither offset
    float3 dithered = clamp(color + threshold * uniforms.ditherSpread, 0.0, 1.0);

    // 4. Palette quantize — nearest color in Euclidean RGB space
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
// MARK: — Error Diffusion Kernel: Atkinson (1984 Mac) & Floyd-Steinberg
// Runs sequentially on GPU thread 0 for scanline error propagation.
// ---------------------------------------------------------------------------
kernel void errorDiffusionKernel(
    texture2d<float, access::sample>  cameraTexture  [[texture(0)]],
    texture2d<float, access::write>   outputTexture  [[texture(1)]],
    constant float4                  *palette        [[buffer(0)]],
    constant KernelUniforms          &uniforms       [[buffer(1)]],
    uint2                             gid            [[thread_position_in_grid]])
{
    if (gid.x > 0 || gid.y > 0) return;

    uint w = uniforms.outputSize.x;
    uint h = uniforms.outputSize.y;
    if (w == 0 || h == 0 || w > 320) return;

    // Line buffers for error diffusion: err0 (current row), err1 (+1 row), err2 (+2 row)
    // Extra 4 elements for border neighborhood offsets (-1, +1, +2)
    float3 err0[324];
    float3 err1[324];
    float3 err2[324];

    for (uint i = 0; i < w + 4; i++) {
        err0[i] = float3(0.0);
        err1[i] = float3(0.0);
        err2[i] = float3(0.0);
    }

    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float spread = uniforms.ditherSpread;
    bool isAtkinson = (uniforms.ditherAlgorithm == 2);

    for (uint y = 0; y < h; y++) {
        for (uint x = 0; x < w; x++) {
            float nx = (float(x) + 0.5) / float(w);
            float ny = (float(y) + 0.5) / float(h);

            float u = uniforms.cropUV.x + ny * (uniforms.cropUV.z - uniforms.cropUV.x);
            float v = uniforms.cropUV.w - nx * (uniforms.cropUV.w - uniforms.cropUV.y);

            float3 rawColor = cameraTexture.sample(s, float2(u, v)).rgb;

            uint ex = x + 2;
            float3 dithered = clamp(rawColor + err0[ex] * spread, 0.0, 1.0);

            // Palette quantize — nearest Euclidean RGB
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

            outputTexture.write(float4(bestColor, 1.0), uint2(x, y));

            float3 err = dithered - bestColor;

            if (isAtkinson) {
                // Atkinson (1984 Macintosh): diffuse 1/8 to 6 neighbors, discard 2/8
                float3 step = err * 0.125;
                err0[ex + 1] += step;
                err0[ex + 2] += step;
                err1[ex - 1] += step;
                err1[ex]     += step;
                err1[ex + 1] += step;
                err2[ex]     += step;
            } else {
                // Floyd-Steinberg: 7/16, 3/16, 5/16, 1/16
                err0[ex + 1] += err * (7.0 / 16.0);
                err1[ex - 1] += err * (3.0 / 16.0);
                err1[ex]     += err * (5.0 / 16.0);
                err1[ex + 1] += err * (1.0 / 16.0);
            }
        }

        // Shift scanlines
        for (uint i = 0; i < w + 4; i++) {
            err0[i] = err1[i];
            err1[i] = err2[i];
            err2[i] = float3(0.0);
        }
    }
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
