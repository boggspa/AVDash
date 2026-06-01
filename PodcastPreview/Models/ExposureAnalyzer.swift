//
//  ExposureAnalyzer.swift
//  PodcastPreview
//
//  Analyses a CVPixelBuffer for luminance distribution and optionally detects
//  faces to give targeted "talking head" exposure feedback.
//

import Foundation
import CoreVideo
import Vision
import Accelerate

final class ExposureAnalyzer {

    // MARK: - Result

    struct Result {
        let meanLuma: Float          // 0..1
        let highlightPercent: Float  // % pixels above 0.95 (clipping)
        let shadowPercent: Float     // % pixels below 0.05 (crushed)
        let histogram: [Float]       // 256-bucket normalised histogram (sums to 1)
        let faceBoxes: [CGRect]      // normalised face rects in image coords (y flipped for SwiftUI)
        let faceMeanLuma: Float?     // mean luma of the largest detected face, nil if none

        enum Rating: String {
            case underexposed   = "Underexposed"
            case slightlyDark   = "Slightly dark"
            case good           = "Well exposed"
            case slightlyBright = "Slightly bright"
            case overexposed    = "Overexposed"
        }

        var rating: Rating {
            let faceRef = faceMeanLuma ?? meanLuma
            if faceRef < 0.25 { return .underexposed }
            if faceRef < 0.40 { return .slightlyDark }
            if faceRef < 0.65 { return .good }
            if faceRef < 0.80 { return .slightlyBright }
            return .overexposed
        }

        var tip: String {
            switch rating {
            case .underexposed:
                return "Very dark exposure. Add more light or increase camera ISO/gain."
            case .slightlyDark:
                return "Slightly underexposed. A fill light or reflector would brighten the subject."
            case .good:
                return "Exposure looks good for a talking-head setup."
            case .slightlyBright:
                return "Slightly hot. Consider reducing the key light intensity or adding a ND filter."
            case .overexposed:
                if highlightPercent > 2 {
                    return "\(String(format: "%.1f", highlightPercent))% of pixels are clipping. Reduce exposure to recover highlights."
                }
                return "Overexposed. Reduce light or lower camera aperture/shutter."
            }
        }

        var ratingColor: (r: Double, g: Double, b: Double) {
            switch rating {
            case .underexposed:   return (0.38, 0.00, 0.55)
            case .slightlyDark:   return (0.05, 0.10, 0.70)
            case .good:           return (0.05, 0.65, 0.10)
            case .slightlyBright: return (1.00, 0.75, 0.00)
            case .overexposed:    return (1.00, 0.20, 0.00)
            }
        }
    }

    // MARK: - Analysis

    func analyze(pixelBuffer: CVPixelBuffer) -> Result? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let isNV12 = (format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                      format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        let isBGRA = (format == kCVPixelFormatType_32BGRA)
        guard isNV12 || isBGRA else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width  = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let total  = width * height

        var lumaValues = [Float](repeating: 0, count: total)

        if isNV12 {
            guard let yPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let src = yPlane.assumingMemoryBound(to: UInt8.self)
            // Convert uint8 Y → normalised float
            var scale: Float = 1.0 / 255.0
            for row in 0..<height {
                let rowBase = row * stride
                var rowFloats = [Float](repeating: 0, count: width)
                vDSP_vfltu8(src + rowBase, 1, &rowFloats, 1, vDSP_Length(width))
                vDSP_vsmul(rowFloats, 1, &scale, &lumaValues[row * width], 1, vDSP_Length(width))
            }
        } else {
            // BGRA: derive luma per pixel
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let src = base.assumingMemoryBound(to: UInt8.self)
            // Rec.709 coefficients (scale by 255 for uint8 input)
            let rCoeff: Float = 0.2126 / 255.0
            let gCoeff: Float = 0.7152 / 255.0
            let bCoeff: Float = 0.0722 / 255.0
            for row in 0..<height {
                let rowBase = row * stride
                for col in 0..<width {
                    let pixel = rowBase + col * 4
                    let b = Float(src[pixel + 0])
                    let g = Float(src[pixel + 1])
                    let r = Float(src[pixel + 2])
                    lumaValues[row * width + col] = r * rCoeff + g * gCoeff + b * bCoeff
                }
            }
        }

        // Mean luma
        var meanLuma: Float = 0
        vDSP_meanv(lumaValues, 1, &meanLuma, vDSP_Length(total))

        // 256-bucket histogram
        var hist = [Float](repeating: 0, count: 256)
        for v in lumaValues {
            let bucket = max(0, min(255, Int(v * 255)))
            hist[bucket] += 1
        }
        var totalF = Float(total)
        vDSP_vsdiv(hist, 1, &totalF, &hist, 1, 256)

        // Highlight / shadow clipping
        let highlightThreshold: Float = 0.95
        let shadowThreshold:    Float = 0.05
        var highlightCount: Float = 0
        var shadowCount:    Float = 0
        for v in lumaValues {
            if v > highlightThreshold { highlightCount += 1 }
            if v < shadowThreshold    { shadowCount    += 1 }
        }
        let highlightPercent = highlightCount / totalF * 100
        let shadowPercent    = shadowCount    / totalF * 100

        // Face detection (synchronous)
        let faceBoxes = detectFaces(in: pixelBuffer, width: width, height: height)

        // Face luma (largest face)
        var faceMeanLuma: Float? = nil
        if let largestFace = faceBoxes.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            faceMeanLuma = meanLumaInRect(largestFace, luma: lumaValues, width: width, height: height)
        }

        return Result(
            meanLuma:         meanLuma,
            highlightPercent: highlightPercent,
            shadowPercent:    shadowPercent,
            histogram:        hist,
            faceBoxes:        faceBoxes,
            faceMeanLuma:     faceMeanLuma
        )
    }

    // MARK: - Private helpers

    private func detectFaces(in pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .up,
                                            options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let results = request.results else { return [] }
        // Vision returns normalised rects with y=0 at bottom; flip for SwiftUI (y=0 at top)
        return results.map { obs in
            let r = obs.boundingBox
            return CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
        }
    }

    private func meanLumaInRect(_ rect: CGRect, luma: [Float], width: Int, height: Int) -> Float {
        let x0 = max(0, Int(rect.minX * CGFloat(width)))
        let x1 = min(width,  Int(rect.maxX * CGFloat(width)))
        let y0 = max(0, Int(rect.minY * CGFloat(height)))
        let y1 = min(height, Int(rect.maxY * CGFloat(height)))
        guard x1 > x0 && y1 > y0 else { return 0 }
        var sum: Float = 0
        var count = 0
        for row in y0..<y1 {
            for col in x0..<x1 {
                sum += luma[row * width + col]
                count += 1
            }
        }
        return count > 0 ? sum / Float(count) : 0
    }
}
