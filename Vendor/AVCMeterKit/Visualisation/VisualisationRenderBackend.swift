import Foundation

/// The rendering subsystem used to draw a visualiser.
enum RenderBackend {
    case metal
    case cpu
}

/// User-facing performance mode stored in VisualisationSettings.
enum VisualisationPerformanceMode: String, Codable, CaseIterable {
    /// Let the app pick the best available backend (Metal if possible).
    case automatic
    /// Force CPU rendering for older/weaker GPUs.
    case compatibility
}
