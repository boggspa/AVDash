//
//  HardwareGraphs.metal
//  PodcastPreview
//
//  Created by Chris Izatt on 17/12/2025.
//

#include <metal_stdlib>
using namespace metal;

struct Vertex {
    float2 position;
    float4 color;
    float2 uv;
    float  level;
    float  _pad;
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
    float2 uv;
    float  level;
};

vertex VertexOut graph_vertex(const device Vertex *verts [[buffer(0)]],
                              uint vid [[vertex_id]]) {
    VertexOut out;
    Vertex v = verts[vid];
    out.position = float4(v.position, 0.0, 1.0);
    out.color = v.color;
    out.uv = v.uv;
    out.level = v.level;
    return out;
}

fragment float4 graph_fragment(VertexOut in [[stage_in]]) {
    float4 c = in.color;

    // Only tint when the sample value itself is high (>= 75%)
    const float spikeThreshold = 0.75;
    float spike = smoothstep(spikeThreshold, 1.0, saturate(in.level));
    if (spike <= 0.0) {
        return c;
    }

    // Top-band mask: only affect the upper part of the filled region.
    // uv.y is 0 at baseline, 1 at the top edge (the line).
    // This creates the "orange cap" look rather than tinting the whole fill.
    float topBand = smoothstep(0.70, 1.0, saturate(in.uv.y));

    // Orange -> Red ramp near the very top
    float redBand = smoothstep(0.92, 1.0, saturate(in.uv.y));

    float3 baseRGB = c.rgb;
    float3 orangeRGB = float3(1.0, 0.55, 0.0);
    float3 redRGB    = float3(1.0, 0.15, 0.10);

    // First, blend base -> orange only in the top band, scaled by spike intensity
    float tOrange = spike * topBand;
    float3 rgb = mix(baseRGB, orangeRGB, tOrange);

    // Then, near the very top, push orange -> red (also scaled by spike)
    float tRed = spike * redBand;
    rgb = mix(rgb, redRGB, tRed);

    return float4(rgb, c.a);
}
