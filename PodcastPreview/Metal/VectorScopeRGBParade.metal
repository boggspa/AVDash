//
//  VectorScopeRGBParade.metal
//  PodcastPreview
//
//  Created by Chris Izatt on 18/12/2025.
//

#include <metal_stdlib>
using namespace metal;

struct VIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct VOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VOut nv12QuadVertex(uint vid [[vertex_id]],
                           const device float4 *verts [[buffer(0)]]) {
    // verts are packed as float4: (pos.x, pos.y, uv.x, uv.y)
    float4 v = verts[vid];
    VOut o;
    o.position = float4(v.x, v.y, 0.0, 1.0);
    o.texCoord = v.zw;
    return o;
}

// MARK: - Preview Uniforms & Helpers

struct PreviewUniforms {
    float brightness;       // additive to RGB after decode: -0.5..+0.5
    float contrast;         // (rgb - 0.5) * contrast + 0.5; 1.0 = identity
    float saturation;       // 0 = greyscale, 1 = identity, 2 = vivid
    uint  overlayMode;      // 0=none 1=guides 2=zebra 3=falseColor
    float zebraThreshold;   // luma >= this triggers zebra pattern
    uint  pad0;
    uint  pad1;
    uint  pad2;
};

inline float3 applyAdjustments(float3 rgb, constant PreviewUniforms &u) {
    float lum = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    rgb = mix(float3(lum), rgb, u.saturation);
    rgb = (rgb - 0.5) * u.contrast + 0.5;
    return clamp(rgb + u.brightness, 0.0, 1.0);
}

inline float3 applyOverlay(float3 rgb, float luma, float2 uv, constant PreviewUniforms &u) {
    if (u.overlayMode == 1u) {
        // Framing guides: rule of thirds + centre cross + 90% safe zone
        const float lineW  = 0.0012;
        const float crossL = 0.05;   // half-length of centre cross arms in UV
        const float margin = 0.05;   // 90% safe-zone margin

        bool isThirds = (abs(uv.x - 1.0/3.0) < lineW || abs(uv.x - 2.0/3.0) < lineW ||
                         abs(uv.y - 1.0/3.0) < lineW || abs(uv.y - 2.0/3.0) < lineW);
        bool isCross  = (abs(uv.y - 0.5) < lineW && abs(uv.x - 0.5) < crossL) ||
                        (abs(uv.x - 0.5) < lineW && abs(uv.y - 0.5) < crossL);
        bool isSafe   = ((abs(uv.x - margin) < lineW || abs(uv.x - (1.0 - margin)) < lineW) &&
                          uv.y > margin && uv.y < 1.0 - margin) ||
                        ((abs(uv.y - margin) < lineW || abs(uv.y - (1.0 - margin)) < lineW) &&
                          uv.x > margin && uv.x < 1.0 - margin);

        if (isThirds || isCross) return mix(rgb, float3(1.0), 0.75);
        if (isSafe)              return mix(rgb, float3(0.15, 0.75, 1.0), 0.65);

    } else if (u.overlayMode == 2u) {
        // Zebra: diagonal amber stripes on luma >= threshold
        if (luma >= u.zebraThreshold) {
            float stripe = fmod((uv.x + uv.y) * 80.0, 1.0);
            if (stripe > 0.5) return float3(1.0, 0.75, 0.0);
        }

    } else if (u.overlayMode == 3u) {
        // ARRI-inspired false colour exposure map
        if      (luma < 0.03) return float3(0.00, 0.00, 0.00);   // black crush
        else if (luma < 0.12) return float3(0.38, 0.00, 0.55);   // purple  – underexposed
        else if (luma < 0.25) return float3(0.05, 0.10, 0.70);   // blue
        else if (luma < 0.40) return float3(0.00, 0.50, 0.55);   // teal
        else if (luma < 0.60) return float3(0.05, 0.65, 0.10);   // green   – correct
        else if (luma < 0.70) return mix(float3(0.05,0.65,0.10), float3(0.85,0.85,0.10), (luma-0.60)/0.10);
        else if (luma < 0.85) return float3(1.00, 0.75, 0.00);   // amber
        else if (luma < 0.95) return float3(1.00, 0.30, 0.00);   // orange  – near clipping
        else                  return float3(1.00, 0.00, 0.00);   // red     – clipping
    }
    return rgb;
}

fragment float4 nv12QuadFragment(VOut in [[stage_in]],
                                texture2d<float, access::sample> yTex [[texture(0)]],
                                texture2d<float, access::sample> uvTex [[texture(1)]],
                                sampler samp [[sampler(0)]],
                                constant PreviewUniforms &u [[buffer(0)]]) {
    float y     = yTex.sample(samp, in.texCoord).r;
    float2 cbcr = uvTex.sample(samp, in.texCoord).rg;
    float cb = cbcr.x - 0.5;
    float cr = cbcr.y - 0.5;
    float r = y + 1.402   * cr;
    float g = y - 0.344136 * cb - 0.714136 * cr;
    float b = y + 1.772   * cb;
    float3 rgb = clamp(float3(r, g, b), 0.0, 1.0);
    rgb = applyAdjustments(rgb, u);
    float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    return float4(applyOverlay(rgb, luma, in.texCoord, u), 1.0);
}

// BGRA preview (for older Intel Macs that only support BGRA output)
fragment float4 bgraQuadFragment(VOut in [[stage_in]],
                                 texture2d<float, access::sample> bgraTex [[texture(0)]],
                                 sampler samp [[sampler(0)]],
                                 constant PreviewUniforms &u [[buffer(0)]]) {
    float3 rgb = bgraTex.sample(samp, in.texCoord).rgb;
    rgb = applyAdjustments(rgb, u);
    float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    return float4(applyOverlay(rgb, luma, in.texCoord, u), 1.0);
}

// MARK: - LUT-applied preview shaders

fragment float4 nv12LUTQuadFragment(VOut in [[stage_in]],
                                    texture2d<float, access::sample> yTex [[texture(0)]],
                                    texture2d<float, access::sample> uvTex [[texture(1)]],
                                    texture3d<float, access::sample> lutTex [[texture(2)]],
                                    sampler samp [[sampler(0)]],
                                    constant PreviewUniforms &u [[buffer(0)]]) {
    float y     = yTex.sample(samp, in.texCoord).r;
    float2 cbcr = uvTex.sample(samp, in.texCoord).rg;
    float cb = cbcr.x - 0.5;
    float cr = cbcr.y - 0.5;
    float r = y + 1.402   * cr;
    float g = y - 0.344136 * cb - 0.714136 * cr;
    float b = y + 1.772   * cb;
    float3 rgb = clamp(float3(r, g, b), 0.0, 1.0);
    rgb = applyAdjustments(rgb, u);
    // LUT applied after adjustments so the grade sees corrected input
    return float4(lutTex.sample(samp, rgb).rgb, 1.0);
}

fragment float4 bgraLUTQuadFragment(VOut in [[stage_in]],
                                    texture2d<float, access::sample> bgraTex [[texture(0)]],
                                    texture3d<float, access::sample> lutTex [[texture(1)]],
                                    sampler samp [[sampler(0)]],
                                    constant PreviewUniforms &u [[buffer(0)]]) {
    float3 rgb = bgraTex.sample(samp, in.texCoord).rgb;
    rgb = applyAdjustments(rgb, u);
    return float4(lutTex.sample(samp, rgb).rgb, 1.0);
}

// MARK: - Generic textured quad (for displaying scope textures)

fragment float4 texQuadFragment(VOut in [[stage_in]],
                                texture2d<float, access::sample> tex [[texture(0)]],
                                sampler samp [[sampler(0)]]) {
    return tex.sample(samp, in.texCoord);
}

// MARK: - Compute scopes

// Utility: safe clamp
inline uint clampu(int v, int lo, int hi) {
    return (uint)max(lo, min(v, hi));
}

// Clear a uint histogram buffer.
kernel void clearU32Histogram(device atomic_uint *hist [[buffer(0)]],
                             constant uint &count [[buffer(1)]],
                             uint tid [[thread_position_in_grid]]) {
    if (tid >= count) return;
    atomic_store_explicit(&hist[tid], 0u, memory_order_relaxed);
}

// Accumulate vectorscope histogram from NV12.
// Hist layout: width*bins + x
// bins = scopeW*scopeH
kernel void accumulateVectorscopeNV12(texture2d<float, access::sample> yTex [[texture(0)]],
                                      texture2d<float, access::sample> uvTex [[texture(1)]],
                                      sampler samp [[sampler(0)]],
                                      device atomic_uint *hist [[buffer(0)]],
                                      constant uint2 &scopeSize [[buffer(1)]],
                                      constant uint2 &inputSize [[buffer(2)]],
                                      constant uint &step [[buffer(3)]],
                                      uint2 gid [[thread_position_in_grid]]) {
    // gid is in input pixel space
    if (gid.x >= inputSize.x || gid.y >= inputSize.y) return;
    if ((gid.x % step) != 0 || (gid.y % step) != 0) return;

    float2 uv = float2((float)gid.x / (float)inputSize.x,
                       (float)gid.y / (float)inputSize.y);

    // Sample chroma from uv plane; values are 0..1
    float2 cbcr01 = uvTex.sample(samp, uv).rg;
    float cb = cbcr01.x - 0.5;
    float cr = cbcr01.y - 0.5;

    // Map to scope coordinates centered at middle
    float x = (cb * 2.0); // -1..1
    float y = (cr * 2.0); // -1..1

    // Convert to pixel coords
    int sx = (int)round((x * 0.5 + 0.5) * (float)(scopeSize.x - 1));
    int sy = (int)round(((-y) * 0.5 + 0.5) * (float)(scopeSize.y - 1));

    uint ux = clampu(sx, 0, (int)scopeSize.x - 1);
    uint uy = clampu(sy, 0, (int)scopeSize.y - 1);

    uint idx = uy * scopeSize.x + ux;
    atomic_fetch_add_explicit(&hist[idx], 1u, memory_order_relaxed);
}

// Accumulate vectorscope histogram from BGRA (for older Intel Macs).
kernel void accumulateVectorscopeBGRA(texture2d<float, access::sample> bgraTex [[texture(0)]],
                                      sampler samp [[sampler(0)]],
                                      device atomic_uint *hist [[buffer(0)]],
                                      constant uint2 &scopeSize [[buffer(1)]],
                                      constant uint2 &inputSize [[buffer(2)]],
                                      constant uint &step [[buffer(3)]],
                                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= inputSize.x || gid.y >= inputSize.y) return;
    if ((gid.x % step) != 0 || (gid.y % step) != 0) return;

    float2 uv = float2((float)gid.x / (float)inputSize.x,
                       (float)gid.y / (float)inputSize.y);

    float4 rgba = bgraTex.sample(samp, uv);
    float3 rgb = rgba.rgb;

    // RGB -> YCbCr (ITU-R BT.601)
    // We only need Cb and Cr for vectorscope
    float cb = -0.168736 * rgb.r - 0.331264 * rgb.g + 0.5 * rgb.b;
    float cr = 0.5 * rgb.r - 0.418688 * rgb.g - 0.081312 * rgb.b;

    // Map to scope coordinates
    float x = (cb * 2.0); // -1..1
    float y = (cr * 2.0); // -1..1

    int sx = (int)round((x * 0.5 + 0.5) * (float)(scopeSize.x - 1));
    int sy = (int)round(((-y) * 0.5 + 0.5) * (float)(scopeSize.y - 1));

    uint ux = clampu(sx, 0, (int)scopeSize.x - 1);
    uint uy = clampu(sy, 0, (int)scopeSize.y - 1);

    uint idx = uy * scopeSize.x + ux;
    atomic_fetch_add_explicit(&hist[idx], 1u, memory_order_relaxed);
}

// Render vectorscope histogram to RGBA texture.
kernel void renderVectorscope(device atomic_uint *hist [[buffer(0)]],
                              texture2d<float, access::read_write> outTex [[texture(0)]],
                              constant uint2 &scopeSize [[buffer(1)]],
                              constant float &decay [[buffer(2)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= scopeSize.x || gid.y >= scopeSize.y) return;

    uint idx = gid.y * scopeSize.x + gid.x;
    uint v = atomic_load_explicit(&hist[idx], memory_order_relaxed);

    // Map count to intensity (very simple curve)
    float inten = clamp(log(1.0 + (float)v) / 6.0, 0.0, 1.0);

    // Persistence/decay: fade previous value slightly each frame
    float4 prev = outTex.read(gid);
    float3 faded = prev.rgb * decay;
    float3 rgb = clamp(faded + float3(inten), 0.0, 1.0);
    // Alpha = brightness of trace; background (black) becomes fully transparent
    float alpha = max(rgb.r, max(rgb.g, rgb.b));
    outTex.write(float4(rgb, alpha), gid);
}

// Accumulate RGB parade histogram from NV12.
// Output is a texture (paradeW x paradeH) where the width is split into 3 equal lanes:
// [R lane | G lane | B lane]. Each lane uses xBucket based on input X.
kernel void accumulateParadeNV12(texture2d<float, access::sample> yTex [[texture(0)]],
                                 texture2d<float, access::sample> uvTex [[texture(1)]],
                                 sampler samp [[sampler(0)]],
                                 device atomic_uint *hist [[buffer(0)]],
                                 constant uint2 &paradeSize [[buffer(1)]],
                                 constant uint2 &inputSize [[buffer(2)]],
                                 constant uint &step [[buffer(3)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= inputSize.x || gid.y >= inputSize.y) return;
    if ((gid.x % step) != 0 || (gid.y % step) != 0) return;

    float2 uv = float2((float)gid.x / (float)inputSize.x,
                       (float)gid.y / (float)inputSize.y);

    float y = yTex.sample(samp, uv).r;
    float2 cbcr01 = uvTex.sample(samp, uv).rg;
    float cb = cbcr01.x - 0.5;
    float cr = cbcr01.y - 0.5;

    // Y'CbCr -> RGB (matches preview)
    float r = y + 1.402 * cr;
    float g = y - 0.344136 * cb - 0.714136 * cr;
    float b = y + 1.772 * cb;
    float3 rgb = clamp(float3(r, g, b), 0.0, 1.0);

    uint laneW = paradeSize.x / 3u;
    // Bucket X to lane width
    uint xBucket = (uint)((float)gid.x / (float)inputSize.x * (float)(laneW - 1u));

    // Map value to Y bin (0 at bottom)
    uint ry = (uint)round((1.0 - rgb.r) * (float)(paradeSize.y - 1u));
    uint gy = (uint)round((1.0 - rgb.g) * (float)(paradeSize.y - 1u));
    uint by = (uint)round((1.0 - rgb.b) * (float)(paradeSize.y - 1u));

    uint rx = xBucket + 0u * laneW;
    uint gx = xBucket + 1u * laneW;
    uint bx = xBucket + 2u * laneW;

    uint ridx = ry * paradeSize.x + rx;
    uint gidx = gy * paradeSize.x + gx;
    uint bidx = by * paradeSize.x + bx;

    atomic_fetch_add_explicit(&hist[ridx], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&hist[gidx], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&hist[bidx], 1u, memory_order_relaxed);
}

// Accumulate RGB parade histogram from BGRA (for older Intel Macs).
kernel void accumulateParadeBGRA(texture2d<float, access::sample> bgraTex [[texture(0)]],
                                 sampler samp [[sampler(0)]],
                                 device atomic_uint *hist [[buffer(0)]],
                                 constant uint2 &paradeSize [[buffer(1)]],
                                 constant uint2 &inputSize [[buffer(2)]],
                                 constant uint &step [[buffer(3)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= inputSize.x || gid.y >= inputSize.y) return;
    if ((gid.x % step) != 0 || (gid.y % step) != 0) return;

    float2 uv = float2((float)gid.x / (float)inputSize.x,
                       (float)gid.y / (float)inputSize.y);

    float4 rgba = bgraTex.sample(samp, uv);
    float3 rgb = clamp(rgba.rgb, 0.0, 1.0);

    uint laneW = paradeSize.x / 3u;
    uint xBucket = (uint)((float)gid.x / (float)inputSize.x * (float)(laneW - 1u));

    uint ry = (uint)round((1.0 - rgb.r) * (float)(paradeSize.y - 1u));
    uint gy = (uint)round((1.0 - rgb.g) * (float)(paradeSize.y - 1u));
    uint by = (uint)round((1.0 - rgb.b) * (float)(paradeSize.y - 1u));

    uint rx = xBucket + 0u * laneW;
    uint gx = xBucket + 1u * laneW;
    uint bx = xBucket + 2u * laneW;

    uint ridx = ry * paradeSize.x + rx;
    uint gidx = gy * paradeSize.x + gx;
    uint bidx = by * paradeSize.x + bx;

    atomic_fetch_add_explicit(&hist[ridx], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&hist[gidx], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&hist[bidx], 1u, memory_order_relaxed);
}

// Render parade histogram into a texture with colored lanes.
kernel void renderParade(device atomic_uint *hist [[buffer(0)]],
                         texture2d<float, access::read_write> outTex [[texture(0)]],
                         constant uint2 &paradeSize [[buffer(1)]],
                         constant float &decay [[buffer(2)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= paradeSize.x || gid.y >= paradeSize.y) return;

    uint idx = gid.y * paradeSize.x + gid.x;
    uint v = atomic_load_explicit(&hist[idx], memory_order_relaxed);

    float inten = clamp(log(1.0 + (float)v) / 6.0, 0.0, 1.0);

    float4 prev = outTex.read(gid);
    float3 faded = prev.rgb * decay;

    uint laneW = paradeSize.x / 3u;
    float3 laneColor = float3(1.0);
    if (gid.x < laneW) {
        laneColor = float3(1.0, 0.1, 0.1); // R
    } else if (gid.x < 2u * laneW) {
        laneColor = float3(0.1, 1.0, 0.1); // G
    } else {
        laneColor = float3(0.1, 0.1, 1.0); // B
    }

    float3 rgb = clamp(faded + laneColor * inten, 0.0, 1.0);
    float alpha = max(rgb.r, max(rgb.g, rgb.b));
    outTex.write(float4(rgb, alpha), gid);
}

// MARK: - Vectorscope Hue Ring (static)

inline float3 hsv2rgb(float3 c) {
    float4 K = float4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

kernel void renderVectorscopeHueRing(texture2d<float, access::write> outTex [[texture(0)]],
                                     constant float &innerR [[buffer(0)]],
                                     constant float &outerR [[buffer(1)]],
                                     constant float &alpha [[buffer(2)]],
                                     uint2 gid [[thread_position_in_grid]]) {
    uint w = outTex.get_width();
    uint h = outTex.get_height();

    float2 uv = (float2(gid) + 0.5) / float2((float)w, (float)h);
    float2 p = uv * 2.0 - 1.0;

    // Keep circle correct if non-square
    float aspect = (float)w / (float)h;
    p.x *= aspect;

    float r = length(p);
    if (r < innerR || r > outerR) {
        outTex.write(float4(0,0,0,0), gid);
        return;
    }

    // Angle: -pi..pi -> hue 0..1
    float ang = atan2(p.y, p.x);
    float hue = (ang + M_PI_F) / (2.0 * M_PI_F);

    float3 rgb = hsv2rgb(float3(hue, 1.0, 1.0));

    // Soft edges (prettier ring)
    float t = (r - innerR) / max(outerR - innerR, 1e-5);
    float edge = smoothstep(0.0, 0.06, t) * (1.0 - smoothstep(0.94, 1.0, t));

    outTex.write(float4(rgb, alpha * edge), gid);
}

// MARK: - Luma Waveform
// x-axis = horizontal pixel position in the source frame
// y-axis = luminance value (bright at top, dark at bottom)

kernel void accumulateLumaWaveformNV12(texture2d<float, access::sample> yTex [[texture(0)]],
                                       texture2d<float, access::sample> uvTex [[texture(1)]],
                                       sampler samp [[sampler(0)]],
                                       device atomic_uint *hist [[buffer(0)]],
                                       constant uint2 &scopeSize [[buffer(1)]],
                                       constant uint2 &inputSize [[buffer(2)]],
                                       constant uint &step [[buffer(3)]],
                                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= inputSize.x || gid.y >= inputSize.y) return;
    if ((gid.x % step) != 0 || (gid.y % step) != 0) return;

    float2 uv   = float2((float)gid.x / (float)inputSize.x,
                         (float)gid.y / (float)inputSize.y);
    float luma  = yTex.sample(samp, uv).r;   // NV12 Y plane = pure luma

    uint xBin = (uint)((float)gid.x / (float)inputSize.x * (float)(scopeSize.x - 1u));
    uint yBin = min((uint)round((1.0 - luma) * (float)(scopeSize.y - 1u)), scopeSize.y - 1u);

    atomic_fetch_add_explicit(&hist[yBin * scopeSize.x + xBin], 1u, memory_order_relaxed);
}

kernel void accumulateLumaWaveformBGRA(texture2d<float, access::sample> bgraTex [[texture(0)]],
                                       sampler samp [[sampler(0)]],
                                       device atomic_uint *hist [[buffer(0)]],
                                       constant uint2 &scopeSize [[buffer(1)]],
                                       constant uint2 &inputSize [[buffer(2)]],
                                       constant uint &step [[buffer(3)]],
                                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= inputSize.x || gid.y >= inputSize.y) return;
    if ((gid.x % step) != 0 || (gid.y % step) != 0) return;

    float2 uv  = float2((float)gid.x / (float)inputSize.x,
                        (float)gid.y / (float)inputSize.y);
    float luma = clamp(dot(bgraTex.sample(samp, uv).rgb, float3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);

    uint xBin = (uint)((float)gid.x / (float)inputSize.x * (float)(scopeSize.x - 1u));
    uint yBin = min((uint)round((1.0 - luma) * (float)(scopeSize.y - 1u)), scopeSize.y - 1u);

    atomic_fetch_add_explicit(&hist[yBin * scopeSize.x + xBin], 1u, memory_order_relaxed);
}

kernel void renderLumaWaveform(device atomic_uint *hist [[buffer(0)]],
                               texture2d<float, access::read_write> outTex [[texture(0)]],
                               constant uint2 &scopeSize [[buffer(1)]],
                               constant float &decay [[buffer(2)]],
                               uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= scopeSize.x || gid.y >= scopeSize.y) return;

    uint  v     = atomic_load_explicit(&hist[gid.y * scopeSize.x + gid.x], memory_order_relaxed);
    float inten = clamp(log(1.0 + (float)v) / 6.0, 0.0, 1.0);

    float3 faded = outTex.read(gid).rgb * decay;
    float3 rgb = clamp(faded + float3(inten), 0.0, 1.0);
    outTex.write(float4(rgb, max(rgb.r, max(rgb.g, rgb.b))), gid);
}

// Horizontal reference lines for waveform / RGB parade scopes.
// Draws solid lines at 0 %, 25 %, 50 %, 75 %, 100 % of the luma axis.
// y = 0 = top = 100 %, y = size.y-1 = bottom = 0 %.
kernel void renderWaveformParadeGraticule(
    texture2d<float, access::write> outTex [[texture(0)]],
    constant uint2 &size [[buffer(0)]],
    constant uint &mode [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= size.x || gid.y >= size.y) return;

    float a = 0.0;
    uint divisions = 4u;  // 25 % steps
    uint tickLength = max((uint)6u, size.x / 28u);
    for (uint i = 0u; i <= divisions; i++) {
        uint lineY = (uint)round((float)i / (float)divisions * (float)(size.y - 1u));
        if (gid.y == lineY) {
            // 0 % and 100 % edges slightly brighter
            a = (i == 0u || i == divisions) ? 0.40 : 0.22;
            if (gid.x < tickLength || gid.x >= size.x - tickLength) {
                a = max(a, 0.42);
            }
        }
    }

    if (mode == 1u) {
        uint laneW = size.x / 3u;
        if ((laneW > 0u && abs((int)gid.x - (int)laneW) <= 1) ||
            (laneW > 0u && abs((int)gid.x - (int)(2u * laneW)) <= 1)) {
            a = max(a, 0.18);
        }

        uint laneTickInset = max((uint)4u, laneW / 10u);
        if (laneW > 0u) {
            for (uint lane = 0u; lane < 3u; lane++) {
                uint laneStart = lane * laneW;
                uint laneEnd = min(size.x - 1u, laneStart + laneW - 1u);
                bool onLaneTick = gid.x >= laneStart + laneTickInset && gid.x <= min(laneStart + laneTickInset + 5u, laneEnd);
                bool onRightLaneTick = gid.x <= laneEnd - laneTickInset && gid.x + 5u >= laneEnd - laneTickInset;
                if (onLaneTick || onRightLaneTick) {
                    for (uint i = 0u; i <= divisions; i++) {
                        uint lineY = (uint)round((float)i / (float)divisions * (float)(size.y - 1u));
                        if (gid.y == lineY) {
                            a = max(a, 0.30);
                        }
                    }
                }
            }
        }
    } else {
        uint centerX = size.x / 2u;
        if (abs((int)gid.x - (int)centerX) <= 0) {
            a = max(a, 0.08);
        }
    }

    outTex.write(float4(1.0, 1.0, 1.0, a), gid);
}

// Concentric reference circles + centre crosshair for the vectorscope.
kernel void renderVectorscopeGraticule(
    texture2d<float, access::write> outTex [[texture(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = outTex.get_width();
    uint h = outTex.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float2 uv  = (float2(gid) + 0.5) / float2((float)w, (float)h);
    float2 p   = uv * 2.0 - 1.0;
    float aspect = (float)w / (float)h;
    p.x *= aspect;

    float r    = length(p);
    float lineW = 0.015;

    // Circles at 50 % and 75 % of full chroma range
    bool onCircle = abs(r - 0.50) < lineW || abs(r - 0.75) < lineW;

    // Short crosshair at centre
    float crossLen = 0.07;
    bool onCross = (abs(p.x) < lineW * 0.6 && r < crossLen) ||
                   (abs(p.y) < lineW * 0.6 && r < crossLen);

    float a = 0.0;
    if (onCircle) a = 0.28;
    if (onCross)  a = 0.38;

    outTex.write(float4(0.75, 0.75, 0.75, a), gid);
}
