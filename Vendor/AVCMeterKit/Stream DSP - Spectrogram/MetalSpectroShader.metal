///
/// @file MetalSpectroShader.metal
/// @brief Metal shading language source for real-time spectrogram rendering in AVCMeter.
///
/// This shader program transforms 2D spectrogram vertex data into screen space and encodes
/// frequency intensity as color using a theme-aware dynamic palette. The result is a smooth,
/// performant heatmap-style visualization of spectral content.
///
/// @discussion
/// This file defines both the vertex and fragment stages for the spectrogram rendering pipeline.
/// Inputs are passed as `VertexIn` structures with 2D positions and normalized intensities (0–1),
/// which are then converted into final screen-space positions and colored pixels depending on
/// their amplitude and theme.
///
/// @author Chris Izatt
/// @date June 29, 2025
//

#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut vertex_fullscreen(uint vertexID [[vertex_id]]) {
    VertexOut out;

    // Fullscreen triangle vertices (clip space)
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    out.position = float4(positions[vertexID], 0.0, 1.0);

    // UV coordinates for full-screen triangle.
    // The triangle spans clip x/y from -1 to 3, so at the screen edge (clip=1)
    // the interpolated UV must equal 1.0: (1-(-1))/(3-(-1)) * uvMax = 1.0 → uvMax = 2.0.
    float2 uvs[3] = {
        float2(0.0, 0.0),
        float2(2.0, 0.0),
        float2(0.0, 1.0)
    };
    out.uv = uvs[vertexID];

    return out;
}

float4 getThemeColor(int themeMode) {
    return (themeMode == 0) ? float4(0.1, 0.2, 0.6, 1.0) :
           (themeMode == 1) ? float4(0.2, 0.6, 1.0, 1.0) :
           (themeMode == 2) ? float4(0.0, 0.8, 0.8, 1.0) :
           (themeMode == 3) ? float4(0.7, 0.2, 1.0, 1.0) :
           (themeMode == 4) ? float4(0.6, 1.0, 0.6, 1.0) :
           (themeMode == 5) ? float4(0.9, 0.6, 1.0, 1.0) :
           (themeMode == 6) ? float4(0.5, 0.5, 1.0, 1.0) :
           (themeMode == 7) ? float4(0.6, 0.6, 0.6, 1.0) :
           (themeMode == 8) ? float4(1.0, 1.0, 1.0, 1.0) :
                              float4(0.2, 1.0, 0.2, 1.0);
}

float4 getBaseShadow(int themeMode) {
    return (themeMode == 0) ? float4(0.0, 0.0, 0.3, 1.0) :
           (themeMode == 1) ? float4(0.0, 0.2, 0.6, 1.0) :
           (themeMode == 2) ? float4(0.0, 0.3, 0.3, 1.0) :
           (themeMode == 3) ? float4(0.3, 0.0, 0.4, 1.0) :
           (themeMode == 4) ? float4(0.3, 0.6, 0.3, 1.0) :
           (themeMode == 5) ? float4(0.5, 0.3, 0.6, 1.0) :
           (themeMode == 6) ? float4(0.2, 0.2, 0.5, 1.0) :
           (themeMode == 7) ? float4(0.2, 0.2, 0.2, 1.0) :
           (themeMode == 8) ? float4(0.0, 0.0, 0.0, 0.0) :
                              float4(0.1, 0.4, 0.1, 1.0);
}

fragment float4 fragment_spectrogram(VertexOut in [[stage_in]],
                                     texture2d<float, access::sample> spectroTexture [[texture(0)]],
                                     sampler spectroSampler [[sampler(0)]],
                                     constant float4 &spectrumColor [[buffer(0)]],
                                     constant int &themeMode [[buffer(1)]],
                                     constant float &sampleRate [[buffer(2)]]) {

    float2 uv = in.uv;

    // --- Logarithmic frequency Y-axis remapping ---
    // The full-screen triangle produces UV.y in [0, 0.5] across the screen
    // (vertex UV.y=1.0 means screen-top interpolates to 0.5 — see vertex shader comment).
    // Normalise to [0,1]: 0 = screen bottom (low freq), 1 = screen top (high freq).
    float screenFrac = clamp(uv.y / 0.5, 0.0, 1.0);

    // Map screen fraction → frequency on a log scale (20 Hz … 12500 Hz).
    const float f_min = 20.0;
    const float f_max = 12500.0;
    float f_nyquist = sampleRate * 0.5;
    float freq = f_min * pow(f_max / f_min, screenFrac);

    // Convert frequency → linear texture Y (bins 0..numBins map linearly to texY 0..1)
    float texY = clamp(freq / f_nyquist, 0.0, 1.0);
    float2 remappedUV = float2(uv.x, texY);

    // Sample the texture
    float4 sampleColor = spectroTexture.sample(spectroSampler, remappedUV);

    // Use red channel as gain (intensity)
    float gain = clamp(sampleColor.r, 0.0, 1.0);

    float4 red    = float4(0.85, 0.0, 0.0, 1.0);
    float4 orange = float4(1.0, 0.5, 0.0, 1.0);

    float4 themeColor = spectrumColor;
    float4 baseShadow = getBaseShadow(themeMode);

    float4 color;
    float alpha = 1.0;

    if (gain < 0.01) {
        // Very deep silence - transparent
        alpha = 0.0;
        color = float4(0.0, 0.0, 0.0, 0.0);
    } else if (gain < 0.15) {
        // Quiet - blend from shadow to theme color
        float t = smoothstep(0.01, 0.15, gain);
        color = mix(baseShadow, themeColor, t);
        alpha = mix(0.2, 1.0, t);  // Fade in from 20% opacity
    } else if (gain < 0.5) {
        // Mid - theme color to orange
        float t = smoothstep(0.15, 0.5, gain);
        color = mix(themeColor, orange, t);
        alpha = 1.0;
    } else {
        // Loud - orange to red
        float t = smoothstep(0.5, 1.0, gain);
        color = mix(orange, red, t);
        alpha = 1.0;
    }

    return float4(color.rgb, alpha);
}
