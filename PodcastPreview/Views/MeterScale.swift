//
//  MeterScale.swift
//  PodcastPreview
//
//  Created by Chris Izatt on 07/12/2025.
//

import Foundation

/// Utility for converting audio levels (linear) into dBFS and normalized (0...1)
/// values suitable for UI meters, and for generating tick marks.
enum MeterScale {
    /// Bottom of the meter (dBFS). Values below this are clamped.
    static let defaultMinDB: Float = -50.0
    /// Top of the meter (dBFS). Use 0.0 for full-scale, or e.g. +10.0 to reserve visual headroom.
    static let defaultMaxDB: Float = 0.0

    /// Convert a linear amplitude (0...1) to dBFS, clamped to `minDB`.
    /// - Parameters:
    ///   - x: Linear amplitude (0...1). Values <= 0 are floored to a tiny epsilon to avoid -inf.
    ///   - minDB: Minimum dB floor (default -60 dB).
    /// - Returns: dBFS value, clamped to at least `minDB`.
    static func dbFS(fromLinear x: Float, minDB: Float = defaultMinDB) -> Float {
        let epsilon: Float = 1e-12 // avoid log10(0)
        let clamped = max(x, epsilon)
        let db = 20.0 * log10f(clamped)
        return max(db, minDB)
    }

    /// Convert a linear amplitude (0...1) into a normalized 0...1 position for drawing.
    /// - Parameters:
    ///   - x: Linear amplitude (0...1).
    ///   - minDB: Bottom of the meter (default -60 dB).
    ///   - maxDB: Top of the meter (default 0 dB).
    /// - Returns: Normalized position in 0...1.
    static func normalized(fromLinear x: Float,
                           minDB: Float = defaultMinDB,
                           maxDB: Float = defaultMaxDB) -> Float {
        let db = dbFS(fromLinear: x, minDB: minDB)
        guard maxDB > minDB else { return 0 }
        let t = (db - minDB) / (maxDB - minDB)
        return min(max(t, 0.0), 1.0)
    }

    /// Normalize a dB value into 0...1 range using the same min/max as the scale.
    /// - Parameters:
    ///   - db: The value in dB to normalize.
    ///   - minDB: Bottom of the meter (default -60 dB).
    ///   - maxDB: Top of the meter (default 0 dB).
    /// - Returns: Normalized position in 0...1.
    static func normalized(fromDB db: Float,
                           minDB: Float = defaultMinDB,
                           maxDB: Float = defaultMaxDB) -> Float {
        guard maxDB > minDB else { return 0 }
        let t = (db - minDB) / (maxDB - minDB)
        return min(max(t, 0.0), 1.0)
    }

    /// Generate labeled tick marks between minDB and maxDB.
    /// - Parameters:
    ///   - step: Spacing between ticks in dB (default 10 dB).
    ///   - minDB: Bottom of the meter.
    ///   - maxDB: Top of the meter.
    /// - Returns: Array of (label, pos, db) where `pos` is normalized 0...1.
    static func ticks(step: Float = 10.0,
                      minDB: Float = defaultMinDB,
                      maxDB: Float = defaultMaxDB) -> [(label: String, pos: Float, db: Float)] {
        guard minDB < maxDB, step > 0 else { return [] }
        var ticks: [(String, Float, Float)] = []
        var db = ceil(minDB / step) * step
        while db <= maxDB + 0.0001 { // include top if exactly divisible
            let pos = min(max((db - minDB) / (maxDB - minDB), 0.0), 1.0)
            let label = db == 0 ? "0" : String(format: "%.0f", db)
            ticks.append((label, pos, db))
            db += step
        }
        return ticks
    }
}
