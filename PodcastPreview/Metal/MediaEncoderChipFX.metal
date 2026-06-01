// MediaEncoderChipFX.metal
#include <metal_stdlib>
using namespace metal;

struct RasterizerData {
    float4 position [[position]];
    float2 uv;
};

struct Uniforms {
    float2 viewportSize;
    float4 glowColor;
    float intensity;
    float cornerRadius;
    float time;
    float active;
    float2 padding;
};

vertex RasterizerData mediaEncoderChipVertex(uint vertexID [[vertex_id]]) {
    float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };

    float2 uvs[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };

    RasterizerData out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = uvs[vertexID];
    return out;
}

static float roundedRectMask(float2 fragCoord, float2 size, float radius) {
    float2 halfSize = size * 0.5;
    float2 q = abs(fragCoord - halfSize) - (halfSize - radius);
    float outside = length(max(q, 0.0));
    float inside = min(max(q.x, q.y), 0.0);
    float distance = outside + inside - radius;
    return 1.0 - smoothstep(0.0, 1.5, distance);
}

fragment float4 mediaEncoderChipFragment(RasterizerData in [[stage_in]],
                                         constant Uniforms& u [[buffer(0)]],
                                         texture2d<float> symbolTexture [[texture(0)]]) {
    float2 size = max(u.viewportSize, float2(1.0, 1.0));
    float2 fragCoord = in.uv * size;
    float mask = roundedRectMask(fragCoord, size, u.cornerRadius);

    float pulse = 0.88 + (0.12 * sin(u.time * 2.2));
    float activeGlow = u.intensity * pulse;
    float3 color = float3(0.0);

    constexpr sampler symbolSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float symbolAlpha = symbolTexture.get_width() > 0 ? symbolTexture.sample(symbolSampler, in.uv).a : 0.0;
    float symbolGlow = 0.0;

    if (symbolTexture.get_width() > 0 && symbolTexture.get_height() > 0) {
        float2 texel = 1.0 / float2(float(symbolTexture.get_width()), float(symbolTexture.get_height()));
        symbolGlow += symbolTexture.sample(symbolSampler, in.uv + float2( texel.x,  0.0)).a * 0.14;
        symbolGlow += symbolTexture.sample(symbolSampler, in.uv + float2(-texel.x,  0.0)).a * 0.14;
        symbolGlow += symbolTexture.sample(symbolSampler, in.uv + float2( 0.0,  texel.y)).a * 0.14;
        symbolGlow += symbolTexture.sample(symbolSampler, in.uv + float2( 0.0, -texel.y)).a * 0.14;

        symbolGlow += symbolTexture.sample(symbolSampler, in.uv + float2( texel.x * 2.0,  0.0)).a * 0.10;
        symbolGlow += symbolTexture.sample(symbolSampler, in.uv + float2(-texel.x * 2.0,  0.0)).a * 0.10;
        symbolGlow += symbolTexture.sample(symbolSampler, in.uv + float2( 0.0,  texel.y * 2.0)).a * 0.10;
        symbolGlow += symbolTexture.sample(symbolSampler, in.uv + float2( 0.0, -texel.y * 2.0)).a * 0.10;

        symbolGlow += symbolTexture.sample(symbolSampler, in.uv + float2( texel.x,  texel.y)).a * 0.09;
        symbolGlow += symbolTexture.sample(symbolSampler, in.uv + float2(-texel.x,  texel.y)).a * 0.09;
        symbolGlow += symbolTexture.sample(symbolSampler, in.uv + float2( texel.x, -texel.y)).a * 0.09;
        symbolGlow += symbolTexture.sample(symbolSampler, in.uv + float2(-texel.x, -texel.y)).a * 0.09;

        symbolGlow += symbolTexture.sample(symbolSampler, in.uv + float2( texel.x * 2.0,  texel.y * 2.0)).a * 0.05;
        symbolGlow += symbolTexture.sample(symbolSampler, in.uv + float2(-texel.x * 2.0,  texel.y * 2.0)).a * 0.05;
        symbolGlow += symbolTexture.sample(symbolSampler, in.uv + float2( texel.x * 2.0, -texel.y * 2.0)).a * 0.05;
        symbolGlow += symbolTexture.sample(symbolSampler, in.uv + float2(-texel.x * 2.0, -texel.y * 2.0)).a * 0.05;
    }

    float symbolGlowMask = max(symbolGlow - (symbolAlpha * 0.35), 0.0);
    float glow = symbolGlowMask * activeGlow * (0.90 + (u.active * 0.20));
    color += u.glowColor.rgb * glow;

    float3 idleSymbolColor = float3(0.68, 0.68, 0.72);
    float3 activeSymbolColor = mix(float3(0.90, 0.90, 0.93), float3(0.37, 0.36, 0.90), min(0.55 + (u.intensity * 1.2), 1.0));
    float3 symbolColor = mix(idleSymbolColor, activeSymbolColor, u.active);
    color = mix(color, symbolColor, symbolAlpha);

    float glowAlpha = glow * (0.92 + (u.active * 0.16));
    float symbolLayerAlpha = symbolAlpha * (0.92 + (u.active * 0.04));
    float alpha = mask * max(glowAlpha, symbolLayerAlpha);

    return float4(color, alpha);
}
