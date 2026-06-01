//
//  SpectrumMeshBuilder.swift
//  AVCMeter
//
//  Created by Chris Izatt on 28/06/2025.
//

import Foundation
import simd

/// Builds interleaved spectrum vertices for Metal rendering.
/// - Produces an array of `[x, y, intensity]` repeated for bottom and top vertices per bin.
struct SpectrumMeshBuilder {
    // Keep these in sync with the Metal plotting transform used for the RTA mesh.
    static let rtaXSpread: Double = 1.95
    static let rtaXCenter: Double = -0.95

    static func visibleBinRange(sampleRate: Float,
                                fftSize: Int,
                                magnitudeCount: Int,
                                minFrequency: Float,
                                maxFrequency: Float) -> (startBin: Int, endBin: Int, binWidth: Double)? {
        guard sampleRate > 0, fftSize > 0, magnitudeCount > 1 else { return nil }
        let binWidth = Double(sampleRate) / Double(fftSize)
        guard binWidth > 0 else { return nil }

        let startBin = Int(ceil(Double(minFrequency) / binWidth))
        let endBin = min(magnitudeCount - 1, Int(floor(Double(maxFrequency) / binWidth)))
        guard endBin > startBin else { return nil }
        return (startBin, endBin, binWidth)
    }

    static func xPositionForFrequency(_ frequency: Double,
                                      width: CGFloat,
                                      sampleRate: Float,
                                      fftSize: Int,
                                      magnitudeCount: Int,
                                      minFrequency: Float = 20.0,
                                      maxFrequency: Float = 20_000.0) -> CGFloat? {
        guard width > 0 else { return nil }
        guard let range = visibleBinRange(sampleRate: sampleRate,
                                          fftSize: fftSize,
                                          magnitudeCount: magnitudeCount,
                                          minFrequency: minFrequency,
                                          maxFrequency: maxFrequency) else { return nil }

        let minFreq = Double(range.startBin) * range.binWidth
        let maxFreq = Double(range.endBin) * range.binWidth
        guard minFreq > 0, maxFreq > minFreq else { return nil }

        let clampedFrequency = min(max(frequency, minFreq), maxFreq)
        let log2Freq = log2(clampedFrequency)
        let log2Min = log2(minFreq)
        let log2Max = log2(maxFreq)
        guard log2Max > log2Min else { return nil }

        let xNorm = (log2Freq - log2Min) / (log2Max - log2Min)
        let ndcX = (xNorm * rtaXSpread) + rtaXCenter
        let viewX = ((ndcX + 1.0) * 0.5) * Double(width)
        return CGFloat(viewX)
    }

    static func frequencyForXPosition(_ x: CGFloat,
                                      width: CGFloat,
                                      sampleRate: Float,
                                      fftSize: Int,
                                      magnitudeCount: Int,
                                      minFrequency: Float = 20.0,
                                      maxFrequency: Float = 20_000.0) -> Double? {
        guard width > 0 else { return nil }
        guard let range = visibleBinRange(sampleRate: sampleRate,
                                          fftSize: fftSize,
                                          magnitudeCount: magnitudeCount,
                                          minFrequency: minFrequency,
                                          maxFrequency: maxFrequency) else { return nil }

        let minFreq = Double(range.startBin) * range.binWidth
        let maxFreq = Double(range.endBin) * range.binWidth
        guard minFreq > 0, maxFreq > minFreq else { return nil }

        let clampedX = min(max(Double(x), 0.0), Double(width))
        let ndcX = (clampedX / Double(width)) * 2.0 - 1.0
        let normalized = (ndcX - rtaXCenter) / rtaXSpread
        let clampedNormalized = min(max(normalized, 0.0), 1.0)

        let log2Min = log2(minFreq)
        let log2Max = log2(maxFreq)
        guard log2Max > log2Min else { return nil }

        return exp2(log2Min + clampedNormalized * (log2Max - log2Min))
    }

    /// Generates vertex data for a given FFT magnitude array.
    /// - Parameters:
    ///   - magnitudes: Normalized magnitudes (length = fftSize/2).
    ///   - sampleRate: Audio sample rate (e.g. 48000).
    ///   - fftSize: FFT size used to compute magnitudes.
    ///   - minFrequency: Minimum frequency to include (default 20 Hz).
    ///   - maxFrequency: Maximum frequency to include (default 20000 Hz).
    /// - Returns: A tuple containing:
    ///   - vertexData: Interleaved `[x, y, intensity]` floats for each bottom/top vertex pair.
    ///   - vertexCount: Total number of vertices.
    static func makeSpectrumVertices(
        processor: SafeFFTSpectrumProcessor,
        minFrequency: Float = 20.0,
        maxFrequency: Float = 22000.0
    ) -> (vertexData: [Float], vertexCount: Int) {
        let magnitudes = processor.magnitudes
        let sampleRate = processor.sampleRate
        let fftSize = processor.fftSize
        let binWidth = sampleRate / Float(fftSize)
        let startBin = Int(ceil(minFrequency / binWidth))
        let endBin = min(magnitudes.count - 1, Int(floor(maxFrequency / binWidth)))
        let count = max(0, endBin - startBin + 1)
        var verts = [Float]()
        // reserve 3 floats per vertex * 2 vertices per bin
        verts.reserveCapacity(count * 3 * 2)

        for i in 0..<count {
            let binIndex = startBin + i
            let freq = Float(binIndex) * binWidth

            let log2Freq = log2(freq)
            let log2Min = log2(Float(startBin) * binWidth)
            let log2Max = log2(Float(endBin) * binWidth)
            let xNorm = (log2Freq - log2Min) / (log2Max - log2Min)
            let xSpread: Float = Float(rtaXSpread)
            let xCenter: Float = Float(rtaXCenter)
            let shiftedX = xNorm * xSpread + xCenter

            let nextFreq = Float(binIndex + 1) * binWidth
            let nextLog2Freq = log2(nextFreq)
            let nextXNorm = (nextLog2Freq - log2Min) / (log2Max - log2Min)
            let nextX = nextXNorm * xSpread + xCenter

            let db = magnitudes[binIndex]
            let dbNext = binIndex + 1 < magnitudes.count ? magnitudes[binIndex + 1] : db

            // Normalize for rendering and shader use
            let dBRangeMin: Float = -120.0
            let dBRangeMax: Float = 10.0

            let normalized1 = max(0.0, min(1.0, (db - dBRangeMin) / (dBRangeMax - dBRangeMin)))
            let normalized2 = max(0.0, min(1.0, (dbNext - dBRangeMin) / (dBRangeMax - dBRangeMin)))

            let visualScale: Float = 2.5
            let y1 = (normalized1 * visualScale) - 1.0
            let y2 = (normalized2 * visualScale) - 1.0

            // First triangle
            verts.append(contentsOf: [shiftedX, -1.0, normalized1])
            verts.append(contentsOf: [shiftedX, y1, normalized1])
            verts.append(contentsOf: [nextX, y2, normalized2])

            // Second triangle
            verts.append(contentsOf: [shiftedX, -1.0, normalized1])
            verts.append(contentsOf: [nextX, y2, normalized2])
            verts.append(contentsOf: [nextX, -1.0, normalized2])
        }

        let vertexCount = verts.count / 3
        return (verts, vertexCount)
    }
}
