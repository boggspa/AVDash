#include <metal_stdlib>
using namespace metal;

struct Vertex {
    float2 position;
    float4 color;
    float2 uv;     // 0 bottom, 1 top of bar
    float  level;  // usage 0..1
    float  _pad;
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
    float2 uv;
    float  level;
};

vertex VertexOut meter_vertex(const device Vertex *verts [[buffer(0)]],
                              uint vid [[vertex_id]]) {
    VertexOut out;
    Vertex v = verts[vid];
    out.position = float4(v.position, 0.0, 1.0);
    out.color = v.color;
    out.uv = v.uv;
    out.level = v.level;
    return out;
}

fragment float4 meter_fragment(VertexOut in [[stage_in]]) {
    float4 c = in.color;

    // Only tint filled bars (background bars have level=0)
    const float spikeThreshold = 0.60;
    float spike = smoothstep(spikeThreshold, 1.0, saturate(in.level));
    if (spike <= 0.0) {
        return c;
    }

    // Horizontal tint bands based on absolute bar position (uv.x spans 0..1 across the full bar)
    float orangeBand = smoothstep(0.60, 1.0, saturate(in.uv.x));
    float redBand    = smoothstep(0.90, 1.0, saturate(in.uv.x));

    float3 baseRGB = c.rgb;
    float3 orangeRGB = float3(1.0, 0.55, 0.0);
    float3 redRGB    = float3(1.0, 0.15, 0.10);

    float3 rgb = mix(baseRGB, orangeRGB, spike * orangeBand);
    rgb = mix(rgb, redRGB, spike * redBand);

    return float4(rgb, c.a);
}
