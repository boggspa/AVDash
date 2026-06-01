//
//  FocusPeaking.metal
//  PodcastPreview
//
//  Metal compute shaders for real-time focus peaking
//

#include <metal_stdlib>
using namespace metal;

// MARK: - NV12 to RGB Conversion

/// Convert NV12 (YCbCr) to RGB/BGRA
/// Uses BT.709 color space (standard for HD video)
kernel void convertNV12ToRGB(
    texture2d<float, access::read>  yTexture   [[texture(0)]],  // Luma plane (full res)
    texture2d<float, access::read>  uvTexture  [[texture(1)]],  // Chroma plane (half res)
    texture2d<float, access::write> rgbTexture [[texture(2)]],  // Output RGB
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= rgbTexture.get_width() || gid.y >= rgbTexture.get_height()) {
        return;
    }
    
    // Sample Y at full resolution
    float y = yTexture.read(gid).r;
    
    // Sample UV at half resolution (chroma subsampling)
    uint2 uvCoord = gid / 2;
    float2 uv = uvTexture.read(uvCoord).rg;
    
    // Convert YUV to RGB using BT.709 matrix
    // Video range [16-235] for Y, [16-240] for UV
    y = (y - 0.0625) * 1.164; // Normalize from video range
    float u = (uv.r - 0.5);
    float v = (uv.g - 0.5);
    
    float r = y + 1.793 * v;
    float g = y - 0.213 * u - 0.533 * v;
    float b = y + 2.112 * u;
    
    // Clamp to valid range
    float3 rgb = clamp(float3(r, g, b), 0.0, 1.0);
    
    rgbTexture.write(float4(rgb, 1.0), gid);
}

// MARK: - Sobel Edge Detection

/// Sobel edge detection kernel
/// Computes gradient magnitude using 3x3 Sobel operators
kernel void sobelEdgeDetect(
    texture2d<float, access::read>  inTexture  [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    constant float &threshold [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    // Bounds check
    if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) {
        return;
    }
    
    // Sample 3x3 neighborhood (convert to grayscale luminance)
    float3 weights = float3(0.299, 0.587, 0.114); // Rec. 709 luma coefficients
    
    float p00 = dot(inTexture.read(uint2(gid.x - 1, gid.y - 1)).rgb, weights);
    float p01 = dot(inTexture.read(uint2(gid.x,     gid.y - 1)).rgb, weights);
    float p02 = dot(inTexture.read(uint2(gid.x + 1, gid.y - 1)).rgb, weights);
    
    float p10 = dot(inTexture.read(uint2(gid.x - 1, gid.y)).rgb, weights);
    float p12 = dot(inTexture.read(uint2(gid.x + 1, gid.y)).rgb, weights);
    
    float p20 = dot(inTexture.read(uint2(gid.x - 1, gid.y + 1)).rgb, weights);
    float p21 = dot(inTexture.read(uint2(gid.x,     gid.y + 1)).rgb, weights);
    float p22 = dot(inTexture.read(uint2(gid.x + 1, gid.y + 1)).rgb, weights);
    
    // Sobel kernels
    // Gx (horizontal):        Gy (vertical):
    // [-1  0  1]             [-1 -2 -1]
    // [-2  0  2]             [ 0  0  0]
    // [-1  0  1]             [ 1  2  1]
    
    float gx = -p00 + p02 - 2.0 * p10 + 2.0 * p12 - p20 + p22;
    float gy = -p00 - 2.0 * p01 - p02 + p20 + 2.0 * p21 + p22;
    
    // Gradient magnitude
    float magnitude = length(float2(gx, gy)) / 8.0; // Normalize by kernel sum
    
    // Apply threshold
    float edge = (magnitude > threshold) ? magnitude : 0.0;
    
    // Write result (edge strength in all channels for simplicity)
    outTexture.write(float4(edge, edge, edge, 1.0), gid);
}

// MARK: - Gaussian Blur (Pre-processing)

/// Optional: Gaussian blur to reduce noise before edge detection
kernel void gaussianBlur(
    texture2d<float, access::read>  inTexture  [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) {
        return;
    }
    
    float4 result = float4(0.0);
    
    int2 minPos = int2(0, 0);
    int2 maxPos = int2(int(inTexture.get_width()) - 1, int(inTexture.get_height()) - 1);
    
    int kernelIndex = 0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int2 samplePos = clamp(int2(gid) + int2(dx, dy), minPos, maxPos);
            
            float weight = 0.0;
            switch (kernelIndex) {
                case 0: weight = 0.0625; break;
                case 1: weight = 0.125; break;
                case 2: weight = 0.0625; break;
                case 3: weight = 0.125; break;
                case 4: weight = 0.25; break;
                case 5: weight = 0.125; break;
                case 6: weight = 0.0625; break;
                case 7: weight = 0.125; break;
                default: weight = 0.0625; break;
            }
            
            result += inTexture.read(uint2(samplePos)) * weight;
            kernelIndex++;
        }
    }
    
    outTexture.write(result, gid);
}

// MARK: - Morphological Dilation (Thicken Edges)

/// Dilate edge mask to make edges more visible
kernel void dilateEdges(
    texture2d<float, access::read>  inTexture  [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    constant int *radius [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) {
        return;
    }
    
    float maxValue = 0.0;
    int r = *radius;
    
    for (int dy = -r; dy <= r; dy++) {
        for (int dx = -r; dx <= r; dx++) {
            uint2 pos = uint2(int2(gid) + int2(dx, dy));
            pos = clamp(pos, uint2(0), uint2(inTexture.get_width() - 1, inTexture.get_height() - 1));
            maxValue = max(maxValue, inTexture.read(pos).r);
        }
    }
    
    outTexture.write(float4(maxValue, maxValue, maxValue, 1.0), gid);
}

// MARK: - Color Overlay (Fragment Shader)

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

/// Vertex shader for full-screen quad
vertex VertexOut overlayVertex(uint vertexID [[vertex_id]]) {
    // Full-screen triangle strip: (-1, -1), (1, -1), (-1, 1), (1, 1)
    float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    
    float2 texCoords[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };
    
    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

/// Fragment shader: composite colored edge overlay
fragment float4 overlayFragment(
    VertexOut in [[stage_in]],
    texture2d<float> videoTexture [[texture(0)]],
    texture2d<float> edgeMask [[texture(1)]],
    constant float3 &peakColor [[buffer(0)]],
    constant float &opacity [[buffer(1)]]
) {
    constexpr sampler textureSampler(filter::linear, address::clamp_to_edge);
    
    // Sample original video
    float4 video = videoTexture.sample(textureSampler, in.texCoord);
    
    // Sample edge strength (grayscale)
    float edgeStrength = edgeMask.sample(textureSampler, in.texCoord).r;
    
    // Create colored overlay for edges with specified opacity
    float3 overlayColor = peakColor * edgeStrength * opacity;
    
    // Simple additive blend: video + colored highlights on edges
    // This ensures the original video is always visible, with bright focus peaking on top
    float3 finalColor = video.rgb + overlayColor;
    
    // Clamp to prevent oversaturation
    finalColor = clamp(finalColor, 0.0, 1.0);
    
    return float4(finalColor, 1.0);
}

fragment float4 edgeOverlayFragment(
    VertexOut in [[stage_in]],
    texture2d<float> edgeMask [[texture(0)]],
    constant float3 &peakColor [[buffer(0)]],
    constant float &opacity [[buffer(1)]]
) {
    constexpr sampler textureSampler(filter::linear, address::clamp_to_edge);

    float edgeStrength = edgeMask.sample(textureSampler, in.texCoord).r;
    float alpha = clamp(edgeStrength * opacity, 0.0, 1.0);
    return float4(peakColor, alpha);
}

// MARK: - White Balance Analysis

/// Compute RGB histogram for white balance analysis
kernel void computeRGBHistogram(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    device atomic_uint *histogram [[buffer(0)]],  // 256 bins × 3 channels
    constant uint2 &imageSize [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= imageSize.x || gid.y >= imageSize.y) {
        return;
    }
    
    float4 color = inputTexture.read(gid);
    
    // Convert to 0-255 range and quantize
    uint r = uint(clamp(color.r * 255.0, 0.0, 255.0));
    uint g = uint(clamp(color.g * 255.0, 0.0, 255.0));
    uint b = uint(clamp(color.b * 255.0, 0.0, 255.0));
    
    // Accumulate into histogram bins
    // Layout: [R bins 0-255][G bins 0-255][B bins 0-255]
    atomic_fetch_add_explicit(&histogram[r], 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&histogram[256 + g], 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&histogram[512 + b], 1, memory_order_relaxed);
}


