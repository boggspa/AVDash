import Metal

/// Resolves the appropriate render backend for each visualiser type.
///
/// Resolution order:
///   1. If the user has selected `.compatibility` mode → `.cpu`
///   2. If a Metal device is available → `.metal`
///   3. Fallback → `.cpu`
struct RenderBackendResolver {

    // MARK: - Public API

    static func resolveWaveformBackend() -> RenderBackend {
        resolve()
    }

    static func resolveSpectrumBackend() -> RenderBackend {
        resolve()
    }

    static func resolveSpectrogramBackend() -> RenderBackend {
        resolve()
    }

    static func resolveMeterBackend() -> RenderBackend {
        resolve()
    }

    // MARK: - Private

    private static func resolve() -> RenderBackend {
        guard VisualisationSettings.shared.visualisationPerformanceMode != .compatibility else {
            return .cpu
        }
        return MTLCreateSystemDefaultDevice() != nil ? .metal : .cpu
    }
}
