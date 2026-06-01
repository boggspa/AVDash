//
//  WhiteBalanceAnalyzer.swift
//  PodcastPreview
//
//  Automatic white balance inference from video frames
//

import Foundation
import CoreVideo
import Metal
import simd

/// Analyzes video frames to infer white balance adjustments
final class WhiteBalanceAnalyzer {

    struct WhiteBalanceResult {
        let temperature: Float  // In Kelvin (2000-10000)
        let tint: Float        // Green-Magenta adjustment (-1.0 to 1.0)
        let redGain: Float     // RGB multipliers for correction
        let greenGain: Float
        let blueGain: Float
        let confidence: Float  // 0.0-1.0 (how confident the estimate is)
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?
    private let histogramPipeline: MTLComputePipelineState?

    // Histogram buffer (256 bins × 3 channels RGB)
    private var histogramBuffer: MTLBuffer?

    init?(device: MTLDevice) {
        let compilerCache = HardwareMetalCompilerCache.shared
        guard let sharedDevice = compilerCache.device,
              let queue = compilerCache.commandQueue else {
            return nil
        }

        self.device = sharedDevice
        self.commandQueue = queue

        // Create texture cache
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, sharedDevice, nil, &cache)
        self.textureCache = cache

        // Load histogram compute shader
        self.histogramPipeline = compilerCache.computePipelineState(functionName: "computeRGBHistogram")

        // Create histogram buffer (256 bins × 3 channels = 768 values)
        self.histogramBuffer = sharedDevice.makeBuffer(
            length: 256 * 3 * MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        )
    }

    /// Analyze a frame and return white balance estimate
    func analyze(pixelBuffer: CVPixelBuffer) -> WhiteBalanceResult? {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        print("White Balance: Analyzing pixel buffer with format: \(pixelFormat)")

        guard let pipeline = histogramPipeline,
              let histBuffer = histogramBuffer else {
            print("Warning: White Balance has no Metal pipeline, using CPU fallback")
            return fallbackAnalysis(pixelBuffer)
        }

        // Get RGB texture from pixel buffer
        guard let rgbTexture = makeRGBTexture(from: pixelBuffer) else {
            print("Warning: White Balance failed to create RGB texture, trying CPU fallback")
            return fallbackAnalysis(pixelBuffer)
        }

        print("Success: White Balance created RGB texture (\(rgbTexture.width)x\(rgbTexture.height))")

        // Clear histogram
        memset(histBuffer.contents(), 0, histBuffer.length)

        // Compute histogram using Metal
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        commandBuffer.label = "WhiteBalanceAnalyzer.Histogram"
        MetalGPUStatsCollector.shared.record(commandBuffer: commandBuffer)

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(rgbTexture, index: 0)
        encoder.setBuffer(histBuffer, offset: 0, index: 0)

        let width = rgbTexture.width
        let height = rgbTexture.height
        var imageSize = SIMD2<UInt32>(UInt32(width), UInt32(height))
        encoder.setBytes(&imageSize, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 1)

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (width + 15) / 16,
            height: (height + 15) / 16,
            depth: 1
        )

        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Analyze histogram data
        return analyzeHistogram(histBuffer)
    }

    private func analyzeHistogram(_ buffer: MTLBuffer) -> WhiteBalanceResult {
        let ptr = buffer.contents().bindMemory(to: UInt32.self, capacity: 256 * 3)

        // Calculate average values for each channel (Gray World algorithm)
        var rSum: UInt64 = 0
        var gSum: UInt64 = 0
        var bSum: UInt64 = 0
        var totalPixels: UInt64 = 0

        for i in 0..<256 {
            let rCount = UInt64(ptr[i])
            let gCount = UInt64(ptr[256 + i])
            let bCount = UInt64(ptr[512 + i])

            rSum += UInt64(i) * rCount
            gSum += UInt64(i) * gCount
            bSum += UInt64(i) * bCount

            totalPixels += rCount // Same for all channels
        }

        guard totalPixels > 0 else {
            return WhiteBalanceResult(
                temperature: 6500,
                tint: 0,
                redGain: 1.0,
                greenGain: 1.0,
                blueGain: 1.0,
                confidence: 0.0
            )
        }

        // Average channel values
        let rAvg = Float(rSum) / Float(totalPixels)
        let gAvg = Float(gSum) / Float(totalPixels)
        let bAvg = Float(bSum) / Float(totalPixels)

        print("White Balance: Histogram RGB averages: R=\(String(format: "%.1f", rAvg)), G=\(String(format: "%.1f", gAvg)), B=\(String(format: "%.1f", bAvg))")

        // Gray World: assume the average of the scene should be neutral gray
        let gray = (rAvg + gAvg + bAvg) / 3.0

        // Calculate gains to normalize each channel to gray
        let redGain = gray / max(rAvg, 1.0)
        let greenGain = gray / max(gAvg, 1.0)
        let blueGain = gray / max(bAvg, 1.0)

        // Normalize gains so the largest is 1.0 (avoid overbrightening)
        let maxGain = max(redGain, greenGain, blueGain)
        let normalizedRed = redGain / maxGain
        let normalizedGreen = greenGain / maxGain
        let normalizedBlue = blueGain / maxGain

        // Estimate color temperature from red/blue ratio
        let rbRatio = rAvg / max(bAvg, 1.0)
        let temperature = estimateTemperature(rbRatio: rbRatio)

        // Estimate tint from green deviation
        let expectedGreen = (rAvg + bAvg) / 2.0
        let tint = (gAvg - expectedGreen) / 128.0  // Normalize to -1...1

        // Confidence based on how far from neutral the image is
        // Higher deviation = more color cast = more confident we can detect it
        let deviation = abs(rAvg - gray) + abs(gAvg - gray) + abs(bAvg - gray)
        let normalizedDeviation = deviation / 100.0

        // Map deviation to confidence (0.5 to 1.0 range)
        // Small deviation (neutral scene) = 0.5 confidence (uncertain)
        // Large deviation (obvious cast) = 1.0 confidence (very sure)
        let confidence = 0.5 + min(0.5, normalizedDeviation)

        print("White Balance: Deviation=\(String(format: "%.1f", deviation)), Confidence=\(String(format: "%.2f", confidence)), Temp=\(Int(temperature))K")

        return WhiteBalanceResult(
            temperature: temperature,
            tint: Float(tint),
            redGain: normalizedRed,
            greenGain: normalizedGreen,
            blueGain: normalizedBlue,
            confidence: confidence
        )
    }

    private func estimateTemperature(rbRatio: Float) -> Float {
        // Empirical mapping from R/B ratio to color temperature
        // Based on blackbody radiation curves
        // High R/B = warm/low temp, Low R/B = cool/high temp

        if rbRatio > 1.5 {
            // Very warm (tungsten/candlelight)
            return 2000 + (rbRatio - 1.5) * 1000
        } else if rbRatio > 1.0 {
            // Warm (sunset, indoor)
            return 3000 + (rbRatio - 1.0) * 2000
        } else if rbRatio > 0.8 {
            // Neutral to slightly warm (daylight)
            return 5000 + (rbRatio - 0.8) * 5000
        } else {
            // Cool (overcast, shade)
            return 6000 + (1.0 - rbRatio) * 2000
        }
    }

    private func fallbackAnalysis(_ pixelBuffer: CVPixelBuffer) -> WhiteBalanceResult? {
        // CPU-based fallback (slower but works without Metal shader)
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        print("White Balance: CPU fallback for format \(pixelFormat)")

        // Handle BGRA
        if pixelFormat == kCVPixelFormatType_32BGRA {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

            guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                print("Error: White Balance failed to get base address")
                return nil
            }

            var rSum: UInt64 = 0
            var gSum: UInt64 = 0
            var bSum: UInt64 = 0

            // Sample every 10th pixel for speed
            let sampleStride = 10
            let pixelBuffer = baseAddress.assumingMemoryBound(to: UInt8.self)

            for y in stride(from: 0, to: height, by: sampleStride) {
                for x in stride(from: 0, to: width, by: sampleStride) {
                    let offset = y * bytesPerRow + x * 4
                    let b = UInt64(pixelBuffer[offset])
                    let g = UInt64(pixelBuffer[offset + 1])
                    let r = UInt64(pixelBuffer[offset + 2])

                    rSum += r
                    gSum += g
                    bSum += b
                }
            }

            let samples = UInt64((width / sampleStride) * (height / sampleStride))
            let rAvg = Float(rSum) / Float(samples)
            let gAvg = Float(gSum) / Float(samples)
            let bAvg = Float(bSum) / Float(samples)

            return computeWhiteBalanceFromRGB(rAvg: rAvg, gAvg: gAvg, bAvg: bAvg)
        }

        // Handle NV12 (most common video format)
        if pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
           pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {

            // Get Y plane
            guard let yBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
                  let uvBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
                print("Error: White Balance failed to get NV12 plane addresses")
                return nil
            }

            let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

            let yData = yBaseAddress.assumingMemoryBound(to: UInt8.self)
            let uvData = uvBaseAddress.assumingMemoryBound(to: UInt8.self)

            var rSum: UInt64 = 0
            var gSum: UInt64 = 0
            var bSum: UInt64 = 0

            let sampleStride = 10
            var sampleCount = 0

            for y in stride(from: 0, to: height, by: sampleStride) {
                for x in stride(from: 0, to: width, by: sampleStride) {
                    // Get Y value
                    let yOffset = y * yBytesPerRow + x
                    let yValue = Float(yData[yOffset])

                    // Get UV values (subsampled 2x)
                    let uvX = x / 2
                    let uvY = y / 2
                    let uvOffset = uvY * uvBytesPerRow + uvX * 2
                    let uValue = Float(uvData[uvOffset]) - 128.0
                    let vValue = Float(uvData[uvOffset + 1]) - 128.0

                    // Convert YUV to RGB (BT.709)
                    let r = yValue + 1.5748 * vValue
                    let g = yValue - 0.1873 * uValue - 0.4681 * vValue
                    let b = yValue + 1.8556 * uValue

                    rSum += UInt64(max(0, min(255, r)))
                    gSum += UInt64(max(0, min(255, g)))
                    bSum += UInt64(max(0, min(255, b)))
                    sampleCount += 1
                }
            }

            guard sampleCount > 0 else {
                print("Error: White Balance no samples collected")
                return nil
            }

            let rAvg = Float(rSum) / Float(sampleCount)
            let gAvg = Float(gSum) / Float(sampleCount)
            let bAvg = Float(bSum) / Float(sampleCount)

            print("White Balance: RGB averages: R=\(rAvg), G=\(gAvg), B=\(bAvg)")

            return computeWhiteBalanceFromRGB(rAvg: rAvg, gAvg: gAvg, bAvg: bAvg)
        }

        print("Error: White Balance unsupported pixel format in CPU fallback: \(pixelFormat)")
        return nil
    }

    /// Compute white balance result from RGB averages
    private func computeWhiteBalanceFromRGB(rAvg: Float, gAvg: Float, bAvg: Float) -> WhiteBalanceResult {
        let gray = (rAvg + gAvg + bAvg) / 3.0

        let redGain = gray / max(rAvg, 1.0)
        let greenGain = gray / max(gAvg, 1.0)
        let blueGain = gray / max(bAvg, 1.0)

        let maxGain = max(redGain, greenGain, blueGain)

        let rbRatio = rAvg / max(bAvg, 1.0)
        let temperature = estimateTemperature(rbRatio: rbRatio)

        let expectedGreen = (rAvg + bAvg) / 2.0
        let tint = (gAvg - expectedGreen) / 128.0

        // Confidence based on color deviation from neutral
        // Higher deviation = more obvious color cast = higher confidence
        let deviation = abs(rAvg - gray) + abs(gAvg - gray) + abs(bAvg - gray)
        let normalizedDeviation = deviation / 100.0

        // Map to 0.5-1.0 range (always show some confidence for CPU fallback)
        let confidence = 0.5 + min(0.5, normalizedDeviation)

        return WhiteBalanceResult(
            temperature: temperature,
            tint: Float(tint),
            redGain: redGain / maxGain,
            greenGain: greenGain / maxGain,
            blueGain: blueGain / maxGain,
            confidence: confidence
        )
    }

    private func makeRGBTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let cache = textureCache else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        // Handle BGRA directly
        if pixelFormat == kCVPixelFormatType_32BGRA {
            var cvTexture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                cache,
                pixelBuffer,
                nil,
                .bgra8Unorm,
                width,
                height,
                0,
                &cvTexture
            )

            guard status == kCVReturnSuccess,
                  let cvTexture = cvTexture else {
                return nil
            }

            return CVMetalTextureGetTexture(cvTexture)
        }

        // Handle NV12 (YUV 4:2:0) - most common video format
        if pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
           pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {

            // Get Y plane
            var yTexture: CVMetalTexture?
            let yStatus = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                cache,
                pixelBuffer,
                nil,
                .r8Unorm,
                width,
                height,
                0,
                &yTexture
            )

            guard yStatus == kCVReturnSuccess,
                  let yTexture = yTexture,
                  let yTex = CVMetalTextureGetTexture(yTexture) else {
                return nil
            }

            // Get UV plane
            var uvTexture: CVMetalTexture?
            let uvStatus = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                cache,
                pixelBuffer,
                nil,
                .rg8Unorm,
                width / 2,
                height / 2,
                1,
                &uvTexture
            )

            guard uvStatus == kCVReturnSuccess,
                  let uvTexture = uvTexture,
                  let uvTex = CVMetalTextureGetTexture(uvTexture) else {
                return nil
            }

            // Create RGB output texture
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite]

            guard let rgbTexture = device.makeTexture(descriptor: descriptor) else {
                return nil
            }

            // Convert NV12 → RGB using Metal compute shader
            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let nv12Pipeline = HardwareMetalCompilerCache.shared.computePipelineState(functionName: "convertNV12ToRGB"),
                  let encoder = commandBuffer.makeComputeCommandEncoder() else {
                return nil
            }
            commandBuffer.label = "WhiteBalanceAnalyzer.ConvertNV12ToRGB"
            MetalGPUStatsCollector.shared.record(commandBuffer: commandBuffer)

            encoder.setComputePipelineState(nv12Pipeline)
            encoder.setTexture(yTex, index: 0)
            encoder.setTexture(uvTex, index: 1)
            encoder.setTexture(rgbTexture, index: 2)

            let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
            let threadGroups = MTLSize(
                width: (width + 15) / 16,
                height: (height + 15) / 16,
                depth: 1
            )

            encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
            encoder.endEncoding()

            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()

            return rgbTexture
        }

        print("Warning: White Balance unsupported pixel format: \(pixelFormat)")
        return nil
    }
}
