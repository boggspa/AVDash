//
//  SpectroMeshBuilder.swift
//  AVCMeter
//
//  Created by Chris Izatt on 29/06/2025.
//

import Foundation

import simd

// MARK: - SpectroMeshBuilder Logging Utilities
// These print statements assist in verifying buffer connectivity and usage.

/// Utility for building Metal vertex meshes from FFT data.
///
/// Used by MetalSpectroRenderer to convert ring-buffered audio data into
/// draw-ready vertex buffers with heatmap-style gain shading.
struct SpectroMeshBuilder {
    // MARK: - Stripe Mesh Builder

    /// Builds a vertical vertex stripe from a single FFT frame.
    ///
    /// This mode is typically used for displaying a snapshot-style spectrum
    /// where each bin is vertically scaled by intensity and time is not a factor.
    ///
    /// - Parameters:
    ///   - spectrum: A single FFT magnitude array (linear or normalized).
    ///   - timeOffset: Offset index for debugging multiple stripes in sequence.
    ///   - fftSize: Total number of FFT bins.
    ///   - scrollRate: Optional horizontal scroll factor to position stripe along time axis.
    ///   - heightScale: Optional vertical exaggeration multiplier.
    ///
    /// - Returns: A tuple containing:
    ///   - `vertices`: Array of 2D vertex positions.
    ///   - `intensities`: Matching gain values for each vertex.
    @inline(__always)
    static func buildVertexStripe(from spectrum: [Float], timeOffset: Int, fftSize: Int, scrollRate: Float = 0.05, heightScale: Float = 0.3) -> ([SIMD2<Float>], [Float]) {
        var vertices: [SIMD2<Float>] = []
        var intensities: [Float] = []
        let numBins = min(spectrum.count, fftSize)

        let x = 0.1 - Float(timeOffset) * scrollRate
        for bin in 0..<numBins {
            let normY = Float(bin) / Float(numBins - 1)
            let y = normY * 2.0 - 1.0

            // Clamp gain between -60dB and 0d, then normalize to [0...1]
            let gain = min(1.0, max(0.0, spectrum[bin])) // assume spectrum[bin] is already linear

            let scaledY = y * heightScale + gain * 0.1
            vertices.append(SIMD2<Float>(x, scaledY))
            intensities.append(gain)
        }

        return (vertices, intensities)
    }

    /// Builds a grid mesh from the history ring buffer snapshot.
    ///
    /// This method uses the SpectroHistoryRingBuffer to generate a grid mesh
    /// for rendering the spectrogram over time.
    ///
    /// - Parameters:
    ///   - buffer: Pointer to the history ring buffer.
    ///   - delayFrames: Number of frames to delay for snapshot.
    ///   - scrollRate: Horizontal scroll rate (normalized to Metal view width).
    ///
    /// - Returns: A tuple of vertex positions and corresponding gain intensities.
    @inline(__always)
    static func buildGridFromHistoryRingBuffer(
        buffer: UnsafeMutableRawPointer,
        delayFrames: Int32 = 2,
        scrollRate: Float = 0.05
    ) -> ([SIMD2<Float>], [Float]) {
        var width: Int = 0
        var height: Int = 0
        let pointer = SpectroHistoryRingBuffer_GetSnapshot(
            buffer,
            delayFrames,
            &width,
            &height
        )

        var vertices: [SIMD2<Float>] = []
        var intensities: [Float] = []

        let binHeight: Float = 2.0 / Float(height)

        for x in 0..<(width - 1) {
            let xA = 1.0 - Float(x) * scrollRate
            let xB = 1.0 - Float(x + 1) * scrollRate

            for y in 0..<height {
                let indexA = y * width + x
                let indexB = y * width + (x + 1)
                let gainA = min(1.0, max(0.0, pointer[indexA]))
                let gainB = min(1.0, max(0.0, pointer[indexB]))

                let logY = log10(1.0 + 9.0 * Float(y) / Float(height - 1)) // maps 0 → 0, max → 1
                let yPos = -0.5 + logY * 2.0
                let top = yPos
                let bottom = yPos + binHeight

                vertices.append(SIMD2<Float>(xA, top))
                vertices.append(SIMD2<Float>(xB, top))
                vertices.append(SIMD2<Float>(xB, bottom))

                vertices.append(SIMD2<Float>(xA, top))
                vertices.append(SIMD2<Float>(xB, bottom))
                vertices.append(SIMD2<Float>(xA, bottom))

                intensities.append(contentsOf: Array(repeating: gainA, count: 3))
                intensities.append(contentsOf: Array(repeating: gainB, count: 3))
            }
        }

        return (vertices, intensities)
    }

    /// Builds a grid mesh from the 2D ring buffer snapshot.
    ///
    /// This method uses the Spectro2DRingBuffer to generate a mesh
    /// for rendering the spectrogram over time.
    ///
    /// - Parameters:
    ///   - buffer: Pointer to the 2D ring buffer.
    ///   - delayFrames: Number of frames to delay for snapshot.
    ///   - scrollRate: Horizontal scroll rate (normalized to Metal view width).
    ///
    /// - Returns: A tuple of vertex positions and corresponding gain intensities.
    @inline(__always)
    static func buildGridFrom2DRingBuffer(
        buffer: UnsafeMutableRawPointer,
        delayFrames: Int32 = 2,
        scrollRate: Float = 0.05
    ) -> ([SIMD2<Float>], [Float]) {
        var width: Int32 = 0
        var height: Int32 = 0
        let pointer = Spectro2DRingBuffer_GetSnapshot(buffer, delayFrames, &width, &height)

        var vertices: [SIMD2<Float>] = []
        var intensities: [Float] = []

        let binHeight: Float = 2.0 / Float(height)

        for x in 0..<(Int(width) - 1) {
            let xA = 1.0 - Float(x) * scrollRate
            let xB = 1.0 - Float(x + 1) * scrollRate

            for y in 0..<Int(height) {
                let indexA = y * Int(width) + x
                let indexB = y * Int(width) + (x + 1)
                let gainA = min(1.0, max(0.0, pointer[indexA]))
                let gainB = min(1.0, max(0.0, pointer[indexB]))

                let logY = log10(1.0 + 9.0 * Float(y) / Float(height - 1)) // maps 0 → 0, max → 1
                let yPos = -0.5 + logY * 2.0
                let top = yPos
                let bottom = yPos + binHeight

                vertices.append(SIMD2<Float>(xA, top))
                vertices.append(SIMD2<Float>(xB, top))
                vertices.append(SIMD2<Float>(xB, bottom))


                vertices.append(SIMD2<Float>(xA, top))
                vertices.append(SIMD2<Float>(xB, bottom))
                vertices.append(SIMD2<Float>(xA, bottom))

                intensities.append(contentsOf: Array(repeating: gainA, count: 3))
                intensities.append(contentsOf: Array(repeating: gainB, count: 3))
            }
        }

        return (vertices, intensities)
    }
}
