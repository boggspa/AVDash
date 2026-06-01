#include <metal_stdlib>
using namespace metal;

float3 rgb_to_hsv(float3 c) {
    float4 K = float4(0.0, -1.0/3.0, 2.0/3.0, -1.0);
    float4 p = (c.g < c.b) ? float4(c.bg, K.wz) : float4(c.gb, K.xy);
    float4 q = (c.r < p.x) ? float4(p.xyw, c.r) : float4(c.r, p.yzx);

    float d = q.x - min(q.w, q.y);
    float e = 1e-10;
    return float3(
        abs(q.z + (q.w - q.y) / (6.0 * d + e)),
        d / (q.x + e),
        q.x
    );
}

float3 hsv_to_rgb(float3 c) {
    float4 K = float4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

// Hue-aware interpolation (wraps around 0..1 so we take the shortest path)
float mix_hue(float h1, float h2, float t) {
    float dh = h2 - h1;
    // Wrap to [-0.5, 0.5] so we don't sweep through unrelated hues
    if (dh > 0.5)  dh -= 1.0;
    if (dh < -0.5) dh += 1.0;
    return fract(h1 + dh * t);
}

float3 mix_hsv_wrap(float3 a, float3 b, float t) {
    return float3(
        mix_hue(a.x, b.x, t),
        mix(a.y, b.y, t),
        mix(a.z, b.z, t)
    );
}

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct MeterStripVertex {
    float2 position;
    float2 uv;
    uint channelIndex;
};

struct MeterStripOut {
    float4 position [[position]];
    float2 uv;
    uint channelIndex [[flat]];
};

vertex VertexOut vertex_main(uint vid [[vertex_id]]) {
    float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };

    float2 uvs[4] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 1.0)
    };

    VertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]],
                              constant float &level [[buffer(0)]],
                              constant float &peakHold [[buffer(1)]],
                              constant float3 &baseColor [[buffer(2)]])
{
    float barHeight = level;        // 0.0 (empty) .. 1.0 (full)
    float y = in.uv.y;              // 0 bottom, 1 top

    // Fixed colour zones based on position, not current level
    // 0.0 - 0.6  : themed region (baseColor)
    // 0.6 - 0.7  : smooth blend from baseColor to orange
    // 0.7 - 0.85 : fixed orange region
    // 0.85 - 1.0 : fixed orange-to-red region
    float3 color;
    float3 orange = float3(1.0, 0.6, 0.0);

    if (y < 0.6) {
        // Base/theme region: bottom = slightly darker theme, top = full theme colour
        float3 dimBase = baseColor * 0.7;   // only mildly darkened
        float t = y / 0.6;                  // 0.0 at bottom, 1.0 at y = 0.6
        t = clamp(t, 0.0, 1.0);
        color = mix(dimBase, baseColor, t); // smooth dark → theme as we go up
    } else if (y < 0.75) {
        float transitionStart = 0.55;
        float transitionEnd   = 0.75;
        float t = (y - transitionStart) / (transitionEnd - transitionStart);
        t = clamp(t, 0.0, 1.0);

        // HSV-based perceptual blending
        float3 hsvBase = rgb_to_hsv(baseColor);
        float3 hsvOrange = rgb_to_hsv(orange);

        // Ensure orange is always hotter/brighter
        hsvOrange.y = max(hsvOrange.y, hsvBase.y);
        hsvOrange.z = max(hsvOrange.z, hsvBase.z);

        float smoothT = smoothstep(0.0, 1.0, t);
        float3 hsvBlend = mix_hsv_wrap(hsvBase, hsvOrange, smoothT);
        color = hsv_to_rgb(hsvBlend);
    } else if (y < 0.85) {
        // Fixed orange band, no baseColor contribution
        color = orange;
    } else {
        // Gradient from orange to red at the very top
        float t = (y - 0.85) / 0.15;
        color = mix(orange, float3(1.0, 0.0, 0.0), t);
    }

    // Subtle glow near current peak (within filled region)
    float topGlow = smoothstep(0.0, 0.05, barHeight - y);
    color += float3(topGlow * 0.1);  // much softer highlight to avoid over-lightening

    // Decide whether this fragment is in the filled bar or the empty region
    bool isFilled = (y <= barHeight);

    // 2px-ish white peak hold bar at peakHold height.
    // UV space is 0..1; for a ~160pt meter, 2px ≈ 0.0125 in UV.
    float peakBandHalfWidth = 0.00625; // ~1px on either side
    bool isPeak = fabs(y - peakHold) < peakBandHalfWidth;

    // Empty region: dark background, except where we draw the peak-hold bar
    if (!isFilled && !isPeak) {
        return float4(0.0, 0.0, 0.0, 0.05);
    }

    // Peak-hold bar overrides both filled and empty regions
    if (isPeak) {
        return float4(1.0, 1.0, 1.0, 1.0);
    }

    // Otherwise, filled region with gradient colour
    return float4(color, 1.0);
}

vertex MeterStripOut vertex_meter_strip(const device MeterStripVertex *vertices [[buffer(0)]],
                                        uint vid [[vertex_id]]) {
    MeterStripOut out;
    out.position = float4(vertices[vid].position, 0.0, 1.0);
    out.uv = vertices[vid].uv;
    out.channelIndex = vertices[vid].channelIndex;
    return out;
}

fragment float4 fragment_meter_strip(MeterStripOut in [[stage_in]],
                                     constant float *levels [[buffer(0)]],
                                     constant float *peakHolds [[buffer(1)]],
                                     constant float3 &baseColor [[buffer(2)]])
{
    float barHeight = levels[in.channelIndex];
    float peakHold = peakHolds[in.channelIndex];
    float y = in.uv.y;

    float3 color;
    float3 orange = float3(1.0, 0.6, 0.0);

    if (y < 0.6) {
        float3 dimBase = baseColor * 0.7;
        float t = clamp(y / 0.6, 0.0, 1.0);
        color = mix(dimBase, baseColor, t);
    } else if (y < 0.75) {
        float transitionStart = 0.55;
        float transitionEnd = 0.75;
        float t = clamp((y - transitionStart) / (transitionEnd - transitionStart), 0.0, 1.0);

        float3 hsvBase = rgb_to_hsv(baseColor);
        float3 hsvOrange = rgb_to_hsv(orange);
        hsvOrange.y = max(hsvOrange.y, hsvBase.y);
        hsvOrange.z = max(hsvOrange.z, hsvBase.z);

        float smoothT = smoothstep(0.0, 1.0, t);
        float3 hsvBlend = mix_hsv_wrap(hsvBase, hsvOrange, smoothT);
        color = hsv_to_rgb(hsvBlend);
    } else if (y < 0.85) {
        color = orange;
    } else {
        float t = (y - 0.85) / 0.15;
        color = mix(orange, float3(1.0, 0.0, 0.0), t);
    }

    float topGlow = smoothstep(0.0, 0.05, barHeight - y);
    color += float3(topGlow * 0.1);

    bool isFilled = (y <= barHeight);
    float peakBandHalfWidth = 0.00625;
    bool isPeak = fabs(y - peakHold) < peakBandHalfWidth;

    if (!isFilled && !isPeak) {
        return float4(0.0, 0.0, 0.0, 0.05);
    }

    if (isPeak) {
        return float4(1.0, 1.0, 1.0, 1.0);
    }

    return float4(color, 1.0);
}

fragment float4 fragment_meter_strip_horizontal(MeterStripOut in [[stage_in]],
                                                constant float *levels [[buffer(0)]],
                                                constant float *peakHolds [[buffer(1)]],
                                                constant float3 &baseColor [[buffer(2)]])
{
    float barWidth = levels[in.channelIndex];
    float peakHold = peakHolds[in.channelIndex];
    float x = in.uv.x;
    float y = in.uv.y;

    float3 color;
    float3 orange = float3(1.0, 0.6, 0.0);

    if (x < 0.6) {
        float3 dimBase = baseColor * 0.7;
        float t = clamp(x / 0.6, 0.0, 1.0);
        color = mix(dimBase, baseColor, t);
    } else if (x < 0.75) {
        float transitionStart = 0.55;
        float transitionEnd = 0.75;
        float t = clamp((x - transitionStart) / (transitionEnd - transitionStart), 0.0, 1.0);

        float3 hsvBase = rgb_to_hsv(baseColor);
        float3 hsvOrange = rgb_to_hsv(orange);
        hsvOrange.y = max(hsvOrange.y, hsvBase.y);
        hsvOrange.z = max(hsvOrange.z, hsvBase.z);

        float smoothT = smoothstep(0.0, 1.0, t);
        float3 hsvBlend = mix_hsv_wrap(hsvBase, hsvOrange, smoothT);
        color = hsv_to_rgb(hsvBlend);
    } else if (x < 0.85) {
        color = orange;
    } else {
        float t = (x - 0.85) / 0.15;
        color = mix(orange, float3(1.0, 0.0, 0.0), t);
    }

    float centerContour = 0.9 + 0.1 * (1.0 - fabs(y - 0.5) * 2.0);
    color *= centerContour;

    float leadingGlow = smoothstep(0.0, 0.05, barWidth - x);
    color += float3(leadingGlow * 0.1);

    bool isFilled = (x <= barWidth);
    float peakBandHalfWidth = 0.004;
    bool isPeak = fabs(x - peakHold) < peakBandHalfWidth;

    if (!isFilled && !isPeak) {
        return float4(0.0, 0.0, 0.0, 0.05);
    }

    if (isPeak) {
        return float4(1.0, 1.0, 1.0, 1.0);
    }

    return float4(color, 1.0);
}

struct SpectrumVertex {
    float2 position;
    float  magnitude;
};

struct SpectrumOut {
    float4 position [[position]];
    float  y01;
};

vertex SpectrumOut vertex_spectrum(const device SpectrumVertex *vertices [[buffer(0)]],
                                   uint vid [[vertex_id]]) {
    SpectrumOut out;
    float2 pos = vertices[vid].position;
    out.position = float4(pos, 0.0, 1.0);

    // Convert NDC y (-1..+1) to 0..1 for gradient mapping
    out.y01 = pos.y * 0.5 + 0.5;
    return out;
}

fragment float4 fragment_spectrum_fill(SpectrumOut in [[stage_in]],
                                       constant float3 &baseColor [[buffer(1)]]) {
    float y = in.y01;
    float3 orange = float3(1.0, 0.6, 0.0);
    float3 hsvBase = rgb_to_hsv(baseColor);
    float3 hsvOrange = rgb_to_hsv(orange);
    hsvOrange.y = max(hsvOrange.y, hsvBase.y);
    hsvOrange.z = max(hsvOrange.z, hsvBase.z);
    float t = clamp((y - 0.55) / 0.45, 0.0, 1.0);
    float smoothT = smoothstep(0.0, 1.0, t);
    float3 hsvBlend = mix_hsv_wrap(hsvBase, hsvOrange, smoothT);
    float3 color = hsv_to_rgb(hsvBlend);
    return float4(color, 1.0);
}
