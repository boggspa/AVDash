//
//  MetalCapsuleShader.metal
//  AVCMeter
//
//  Created by Chris Izatt on 13/06/2025.
//

#include <metal_stdlib>
using namespace metal;

/// -----------------------------------------------------------------------------
/// MetalCapsuleShader.metal
///
/// Metal shading language functions for rendering a vertical capsule meter
/// with a theme-adaptive gradient fill.
///
/// - Author: Chris Izatt
/// - Created: 13/06/2025
///
/// This file defines the input/output structures, vertex shader, and fragment
/// shader for drawing a capsule-shaped meter with a customizable vertical
/// gradient and theme-based color palettes.
/// -----------------------------------------------------------------------------

/// Represents the input structure for each vertex in the capsule meter.
///
/// - Parameters:
///   - position: The 2D position of the vertex in normalized device coordinates.
///   - texCoord: The 2D texture coordinate used to determine gradient fill.
struct VertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

/// Represents the output structure from the vertex shader stage.
///
/// - Parameters:
///   - position: The transformed 4D clip-space position.
///   - texCoord: Passed-through texture coordinate for use in the fragment stage.
struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

/// Vertex shader responsible for preparing geometry for the capsule meter.
///
/// - Parameter in: Input vertex data, including position and texture coordinates.
/// - Returns: VertexOut containing the transformed clip-space position and texture coordinate.
vertex VertexOut vertex_main(VertexIn in [[stage_in]]) {
    VertexOut out;
    out.position = float4(in.position, 0.0, 1.0);
    out.texCoord = in.texCoord;
    return out;
}

/// Fragment shader that renders the vertical gradient of the capsule meter based on fill level.
///
/// - Parameters:
///   - in: The interpolated vertex output from the vertex shader.
///   - fillLevel: A float between 0.0 and 1.0 representing how much of the meter is "filled".
///   - startColor: The base color at the top of the capsule (not actively used in this version).
///   - endColor: The target color at the bottom of the capsule (not actively used in this version).
///   - themeMode: An integer representing the selected theme mode, used to apply adaptive colors.
/// - Returns: A float4 color value based on fill height and theme-specific palette.
fragment float4 fragment_main(VertexOut in [[stage_in]],
                              constant float &fillLevel [[buffer(0)]],
                              constant float4 &startColor [[buffer(1)]],
                              constant float4 &endColor [[buffer(2)]],
                              constant int &themeMode [[buffer(3)]]) {
    // These legacy uniforms are intentionally ignored; theme + vertical position
    // now drive a fixed full-height gradient so the bar doesn't "color swap" as
    // levels move.
    (void)startColor;
    (void)endColor;

    const float clampedFill = clamp(fillLevel, 0.0, 1.0);
    // Convert to "height from bottom": 0.0 = bottom, 1.0 = top.
    const float y = clamp(1.0 - in.texCoord.y, 0.0, 1.0);

    // Clip above the current level; keep gradient anchored to full meter height.
    if (y > clampedFill) {
        return float4(0.0, 0.0, 0.0, 0.0);
    }

    // Theme-aware low/mid palette. Theme integer mapping is supplied by Swift:
    // 0 light, 1 dark, 2 thinMaterial, 3 liquid/poorMansGlass, 4 purple,
    // 5 mint, 6 lavender, 7 indigo, 8 gray, 9 hollow.
    float4 lowBand;
    float4 midBand;
    switch (themeMode) {
        case 4:
            lowBand = float4(0.30, 0.12, 0.45, 1.0);
            midBand = float4(0.80, 0.40, 1.00, 1.0);
            break;
        case 5:
            lowBand = float4(0.12, 0.45, 0.28, 1.0);
            midBand = float4(0.55, 1.00, 0.75, 1.0);
            break;
        case 6:
            lowBand = float4(0.36, 0.28, 0.52, 1.0);
            midBand = float4(0.78, 0.70, 1.00, 1.0);
            break;
        case 7:
            lowBand = float4(0.20, 0.20, 0.46, 1.0);
            midBand = float4(0.58, 0.52, 1.00, 1.0);
            break;
        case 8:
            lowBand = float4(0.28, 0.28, 0.28, 1.0);
            midBand = float4(0.78, 0.78, 0.78, 1.0);
            break;
        case 9:
            lowBand = float4(0.65, 0.65, 0.70, 0.20);
            midBand = float4(0.90, 0.90, 0.90, 0.35);
            break;
        default:
            // Keep classic metering colors for host/normal themes.
            lowBand = float4(0.08, 0.40, 0.08, 1.0);
            midBand = float4(0.30, 1.00, 0.30, 1.0);
            break;
    }

    const float4 yellow = float4(1.00, 0.95, 0.20, 1.0);
    const float4 orange = float4(1.00, 0.56, 0.08, 1.0);
    const float4 red    = float4(0.90, 0.10, 0.10, 1.0);

    float4 gradientColor;
    if (y < 0.58) {
        gradientColor = mix(lowBand, midBand, y / 0.58);
    } else if (y < 0.80) {
        gradientColor = mix(midBand, yellow, (y - 0.58) / 0.22);
    } else if (y < 0.93) {
        gradientColor = mix(yellow, orange, (y - 0.80) / 0.13);
    } else {
        gradientColor = mix(orange, red, (y - 0.93) / 0.07);
    }

    return gradientColor;
}
