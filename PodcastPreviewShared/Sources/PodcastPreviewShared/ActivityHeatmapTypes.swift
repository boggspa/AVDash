import Foundation
import SwiftUI

// MARK: - Activity Heatmap Types
//
// Shared types for activity heatmap visualization across platforms.
// These are pure data structures that can be used by both macOS and iOS.

public struct RGBTriplet: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let idle = RGBTriplet(red: 0.10, green: 0.10, blue: 0.11)
    public static let white = RGBTriplet(red: 1.0, green: 1.0, blue: 1.0)

    public func interpolated(to other: RGBTriplet, amount: Double) -> RGBTriplet {
        let t = min(max(amount, 0.0), 1.0)
        return RGBTriplet(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t
        )
    }

    public var color: Color {
        Color(red: red, green: green, blue: blue)
    }
}

public enum HeatmapMetric: String, CaseIterable, Sendable, Identifiable {
    case overall = "All"
    case cpu     = "CPU"
    case gpu     = "GPU"
    case ane     = "ANE"
    case memory  = "Press"
    case power   = "Pwr"
    case network = "Net"

    public var id: String { rawValue }

    public var compactLabel: String {
        switch self {
        case .overall: return "All"
        case .cpu:     return "CPU"
        case .gpu:     return "GPU"
        case .ane:     return "ANE"
        case .memory:  return "Prs"
        case .power:   return "Pwr"
        case .network: return "Net"
        }
    }

    public var tinyLabel: String {
        switch self {
        case .overall: return "A"
        case .cpu:     return "C"
        case .gpu:     return "G"
        case .ane:     return "AI"
        case .memory:  return "M"
        case .power:   return "W"
        case .network: return "N"
        }
    }

    public var color: Color {
        switch self {
        case .overall: return Color.white
        case .cpu:     return .blue
        case .gpu:     return Color(red: 0.85, green: 0.20, blue: 0.20)
        case .ane:     return Color(red: 0.65, green: 0.00, blue: 0.65)
        case .memory:  return Color(red: 0.10, green: 0.65, blue: 0.28)
        case .power:   return .orange
        case .network: return Color(red: 0.40, green: 0.40, blue: 0.50)
        }
    }

    public var rgb: RGBTriplet? {
        switch self {
        case .overall:
            return nil
        case .cpu:
            return RGBTriplet(red: 0.16, green: 0.49, blue: 0.95)
        case .gpu:
            return RGBTriplet(red: 0.85, green: 0.20, blue: 0.20)
        case .ane:
            return RGBTriplet(red: 0.65, green: 0.00, blue: 0.65)
        case .memory:
            return RGBTriplet(red: 0.10, green: 0.65, blue: 0.28)
        case .power:
            return RGBTriplet(red: 0.98, green: 0.54, blue: 0.12)
        case .network:
            return RGBTriplet(red: 0.40, green: 0.40, blue: 0.50)
        }
    }
}

public struct OverallHeatmapCell: Equatable, Sendable {
    public var cpu: Double = 0
    public var gpu: Double? = nil
    public var memory: Double = 0
    public var power: Double = 0
    public var network: Double = 0

    public init(cpu: Double = 0, gpu: Double? = nil, memory: Double = 0, power: Double = 0, network: Double = 0) {
        self.cpu = cpu
        self.gpu = gpu
        self.memory = memory
        self.power = power
        self.network = network
    }

    /// In the combined "All" view, memory pressure and power often sit at high baselines that are
    /// informative in isolation but visually drown out CPU/GPU/ANE/network. Scale their contribution
    /// to both hue blending and cell brightness so the composite reads more like "compute activity."
    public static func overallBlendInfluence(for metric: HeatmapMetric) -> Double {
        switch metric {
        case .memory, .power:
            return 0.45
        case .gpu:
            return 1.5
        case .cpu, .ane, .network, .overall:
            return 1.0
        }
    }

    public var components: [(HeatmapMetric, Double)] {
        var out: [(HeatmapMetric, Double)] = [(.cpu, cpu)]
        if let gpu {
            out.append((.gpu, gpu))
        }
        out.append((.memory, memory))
        out.append((.power, power))
        out.append((.network, network))
        return out
    }

    private var influencedValues: [Double] {
        components.map { metric, value in value * Self.overallBlendInfluence(for: metric) }
    }

    public var peakIntensity: Double {
        influencedValues.max() ?? 0
    }

    public var averageIntensity: Double {
        let values = influencedValues
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    public var sharedBusyRatio: Double {
        influencedValues.min() ?? 0
    }

    public var displayIntensity: Double {
        min(1.0, peakIntensity * 0.72 + averageIntensity * 0.28)
    }
}
