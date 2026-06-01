#include <metal_stdlib>
using namespace metal;

struct SpectrumVertexIn {
    float2 position [[attribute(0)]];
    float value [[attribute(1)]];
};

struct SpectrumVertexOut {
    float4 position [[position]];
    float value;
    float y;
};

vertex SpectrumVertexOut spectrumVertexShader(SpectrumVertexIn in [[stage_in]]) {
    SpectrumVertexOut out;
    out.position = float4(in.position, 0.0, 1.0);
    out.value = in.value;
    out.y = in.position.y;
    return out;
}

fragment float4 spectrumFragmentShader(SpectrumVertexOut in [[stage_in]],
                                       constant float4 &baseColor [[buffer(0)]],
                                       constant int &themeMode [[buffer(1)]]) {
    float fade = clamp((in.y + 1.0) / 2.0, 0.0, 1.0);  // Map y [-1, 1] → [0, 1]

    float4 red        = float4(0.85, 0.0, 0.0, 1.0);
    float4 orange     = float4(1.0, 0.5, 0.0, 1.0);
    float4 yellow     = float4(1.0, 1.0, 0.0, 1.0);

    // Match base color to themeMode
    float4 themeColor = (themeMode == 1) ? float4(0.0, 0.2, 0.6, 1.0) :
                        (themeMode == 2) ? float4(0.0, 0.3, 0.3, 1.0) :
                        (themeMode == 3) ? float4(0.6, 0.3, 0.6, 1.0) :
                        (themeMode == 4) ? float4(0.3, 0.0, 0.4, 1.0) :
                        (themeMode == 5) ? float4(0.3, 0.6, 0.3, 1.0) :
                        (themeMode == 6) ? float4(0.5, 0.3, 0.6, 1.0) :
                        (themeMode == 7) ? float4(0.2, 0.2, 0.5, 1.0) :
                        (themeMode == 8) ? float4(0.2, 0.2, 0.2, 1.0) :
                        (themeMode == 9) ? float4(0.0, 0.0, 0.0, 0.0) :
                                           float4(0.1, 0.4, 0.1, 1.0); // fallback

    float4 baseShadow = (themeMode == 0) ? float4(0.0, 0.3, 0.0, 1.0) :     // light
                        (themeMode == 1) ? float4(0.0, 0.2, 0.6, 1.0) :     // dark
                        (themeMode == 2) ? float4(0.0, 0.3, 0.3, 1.0) :     // thinMaterial
                        (themeMode == 3) ? float4(0.2, 0.1, 0.2, 1.0) :     // liquidGlass
                        (themeMode == 4) ? float4(0.3, 0.0, 0.4, 1.0) :     // purple
                        (themeMode == 5) ? float4(0.3, 0.6, 0.3, 1.0) :     // mint
                        (themeMode == 6) ? float4(0.5, 0.3, 0.6, 1.0) :     // lavender
                        (themeMode == 7) ? float4(0.2, 0.2, 0.5, 1.0) :     // indigo
                        (themeMode == 8) ? float4(0.2, 0.2, 0.2, 1.0) :     // gray
                        (themeMode == 9) ? float4(0.0, 0.0, 0.0, 0.0) :     // hollow
                                           float4(0.1, 0.4, 0.1, 1.0);     // fallback

    float4 gradientColor;
    if (fade < 0.3) {
        float t = smoothstep(0.0, 0.3, fade);  // matches 0.0–0.3 range
        gradientColor = mix(baseShadow, themeColor, t);
    } else if (fade < 0.48) {
        float t = smoothstep(0.3, 0.48, fade);  // matches 0.3–0.65 range
        gradientColor = mix(themeColor, themeColor, t);
    } else if (fade < 0.6) {
        float t = smoothstep(0.48, 0.6, fade);  // matches 0.3–0.65 range
        gradientColor = mix(themeColor, orange, t);
    } else {
        float t = smoothstep(0.6, 1.0, fade);  // matches 0.65–1.0 range
        gradientColor = mix(orange, red, t);
    }

    return gradientColor;
}
