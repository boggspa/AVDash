//
//  NeuralEngineCapsuleFX.metal
//  PodcastPreview
//
//  Created by Chris Izatt on 21/03/2026.
//

#include <metal_stdlib>
using namespace metal;

struct NeuralEngineCapsuleUniforms {
    float2 drawableSize;
    float4 statusColor;
    float2 capsuleSize;
    float2 glowSize;
    float4 layout;   // x = topPadding, y = railPadding, z = capsuleSpacing, w = rowExtraHeight
    uint capsuleCount;
    uint isIdle;
    uint isActive;
    uint _padding;
};

struct CapsuleVertexOut {
    float4 position [[position]];
    float2 localUV;
    float diagonalOffset;
    uint layerKind;
    uint capsuleIndex;
    uint isIdle;
    uint isActive;
    float4 statusColor;
};

vertex CapsuleVertexOut neuralCapsuleVertex(uint vertexID [[vertex_id]],
                                            uint instanceID [[instance_id]],
                                            const device float2 *vertices [[buffer(0)]],
                                            constant NeuralEngineCapsuleUniforms &u [[buffer(1)]]) {
    CapsuleVertexOut out;

    uint capsuleIndex = instanceID / 3;
    uint layerKind = instanceID % 3;

    float2 baseVertex = vertices[vertexID];
    float visibleCount = max(float(max(u.capsuleCount, 1u) - 1u), 1.0);
    float normalizedIndex = float(capsuleIndex) / visibleCount;
    float diagonalOffset = (normalizedIndex - 0.5) * 1.2;

    float2 size = u.capsuleSize;
    if (layerKind == 0) {
        size = u.glowSize;
    }

    float xCenter = u.drawableSize.x * 0.5;
    float topPadding = u.layout.x;
    float railPadding = u.layout.y;
    float capsuleSpacing = u.layout.z;
    float rowExtraHeight = u.layout.w;
    float yStart = topPadding + railPadding + size.y * 0.5;
    float yStep = u.capsuleSize.y + rowExtraHeight + capsuleSpacing;
    float yCenter = yStart + (float(capsuleIndex) * yStep);

    float2 halfSize = size * 0.5;
    float2 pixelPosition = float2(xCenter, yCenter) + (baseVertex * halfSize);

    float2 ndc = float2(
        (pixelPosition.x / max(u.drawableSize.x, 1.0)) * 2.0 - 1.0,
        1.0 - (pixelPosition.y / max(u.drawableSize.y, 1.0)) * 2.0
    );

    out.position = float4(ndc, 0.0, 1.0);
    out.localUV = baseVertex * 0.5 + 0.5;
    out.diagonalOffset = diagonalOffset;
    out.layerKind = layerKind;
    out.capsuleIndex = capsuleIndex;
    out.isIdle = u.isIdle;
    out.isActive = u.isActive;
    out.statusColor = u.statusColor;
    return out;
}

static float capsuleMask(float2 uv, float edgeSoftness) {
    float2 centered = uv * 2.0 - 1.0;
    float2 d = abs(centered);
    float horizontal = smoothstep(1.0, 1.0 - edgeSoftness, d.x);
    float vertical = smoothstep(1.0, 1.0 - edgeSoftness, d.y);
    return horizontal * vertical;
}

static float4 diagonalGradient(float2 uv, float diagonalOffset, bool idle) {
    float t = clamp(uv.x + diagonalOffset * -0.08, 0.0, 1.0);

    float4 c0 = float4(1.00, 1.00, 1.00, idle ? 0.70 : 0.92);
    float4 c1 = float4(1.00, 0.38, 0.78, idle ? 0.68 : 0.88);
    float4 c2 = float4(0.66, 0.40, 0.98, idle ? 0.70 : 0.90);
    float4 c3 = float4(0.42, 0.55, 1.00, idle ? 0.68 : 0.88);
    float4 c4 = float4(0.33, 0.92, 0.95, idle ? 0.70 : 0.92);
    float4 c5 = float4(0.62, 0.98, 0.78, idle ? 0.66 : 0.88);
    float4 c6 = float4(1.00, 1.00, 1.00, idle ? 0.64 : 0.82);

    if (t < 0.14) return mix(c0, c1, t / 0.14);
    if (t < 0.34) return mix(c1, c2, (t - 0.14) / 0.20);
    if (t < 0.52) return mix(c2, c3, (t - 0.34) / 0.18);
    if (t < 0.72) return mix(c3, c4, (t - 0.52) / 0.20);
    if (t < 0.88) return mix(c4, c5, (t - 0.72) / 0.16);
    return mix(c5, c6, (t - 0.88) / 0.12);
}

fragment float4 neuralCapsuleFragment(CapsuleVertexOut in [[stage_in]]) {
    bool idle = in.isIdle != 0;
    bool active = in.isActive != 0;

    if (in.layerKind == 0) {
        if (idle) {
            return float4(0.0);
        }

        float mask = capsuleMask(in.localUV, 0.75);
        float4 glowBase = diagonalGradient(in.localUV, in.diagonalOffset, false);
        float4 statusGlow = in.statusColor;
        float statusMix = clamp(statusGlow.a, 0.0, 1.0);
        float4 glow = mix(glowBase, statusGlow, statusMix * 0.55);
        glow.rgb *= 1.15;
        glow.a = (active ? 0.42 : 0.22) * mask;
        return glow;
    }

    if (in.layerKind == 1) {
        float mask = capsuleMask(in.localUV, 0.14);
        float alpha = idle ? 0.05 : 0.45;
        float topShade = mix(0.18, 0.07, in.localUV.y);
        float bottomShade = mix(0.07, 0.12, in.localUV.y);
        float shade = mix(topShade, bottomShade, in.localUV.y);
        return float4(shade, shade, shade, alpha * mask);
    }

    float mask = capsuleMask(in.localUV, 0.08);
    float4 base = diagonalGradient(in.localUV, in.diagonalOffset, idle);

    float highlightShift = in.diagonalOffset * 0.8;
    float highlight = smoothstep(0.00 + highlightShift, 0.18 + highlightShift, in.localUV.x) *
                      (1.0 - smoothstep(0.30 + highlightShift, 0.70 + highlightShift, in.localUV.x));
    float verticalHighlight = 1.0 - smoothstep(0.0, 1.0, in.localUV.y);
    float highlightMix = clamp(highlight * verticalHighlight, 0.0, 1.0);

    float border = step(in.localUV.x, 0.02) + step(0.98, in.localUV.x) + step(in.localUV.y, 0.08) + step(0.92, in.localUV.y);
    float borderAlpha = min(border, 1.0) * 0.24;

    float4 color = base;
    color.rgb = mix(color.rgb, float3(1.0), highlightMix * 0.36);
    color.rgb = mix(color.rgb, float3(1.0), borderAlpha * 0.34);
    color.a = 0.96 * mask;
    return color;
}
