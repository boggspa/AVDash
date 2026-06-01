//
//  MetalWaveform.metal
//  AVCMeter
//
//  Created by Chris Izatt on 24/06/2025.
//

#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float4 color;
};

vertex VertexOut vertex_passthrough(uint vertexID [[vertex_id]],
                                     const device float2* vertices [[buffer(0)]],
                                     const device float4* colors [[buffer(1)]]) {
    VertexOut out;
    float2 pos = vertices[vertexID];
    out.position = float4(pos, 0.0, 1.0);
    out.color = colors[vertexID];
    return out;
}

fragment float4 fragment_color(VertexOut in [[stage_in]]) {
    return in.color;
}

// Returns the color from a uniform buffer, for theme support.
fragment float4 fragment_color_with_theme(constant float4& themeColor [[ buffer(0) ]]) {
    return themeColor;
}
