//
//  WaveformShaders.metal
//  PodcastPreview
//
//  Created by Chris Izatt on 18/03/2026.
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Waveform History Shaders

struct WaveformVertexOut {
    float4 position [[position]];
    float alpha;
};

// Vertex shader for waveform history
// Takes 2D positions (x = time, y = amplitude) and outputs clip-space positions
vertex WaveformVertexOut waveformVertexShader(uint vertexID [[vertex_id]],
                                               constant float2 *vertices [[buffer(0)]]) {
    WaveformVertexOut out;
    
    float2 pos = vertices[vertexID];
    out.position = float4(pos.x, pos.y, 0.0, 1.0);
    
    // Calculate alpha based on X position (age fade effect)
    // Older samples (left side, negative X) are more transparent
    // Newer samples (right side, positive X) are more opaque
    float normalizedX = (pos.x + 1.0) * 0.5; // Convert from [-1, 1] to [0, 1]
    out.alpha = mix(0.3, 1.0, normalizedX);  // Fade from 30% to 100% opacity
    
    return out;
}

// Fragment shader for waveform history
// Applies color with age-based transparency
fragment float4 waveformFragmentShader(WaveformVertexOut in [[stage_in]],
                                      constant float3 &baseColor [[buffer(0)]]) {
    // Apply the base color with calculated alpha
    return float4(baseColor, in.alpha);
}
