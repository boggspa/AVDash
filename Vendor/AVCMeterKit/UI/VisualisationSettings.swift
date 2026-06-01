import Foundation

final class VisualisationSettings: ObservableObject {
    static let shared = VisualisationSettings()

    // MARK: - Spectrum
    @Published var spectrumFFTSize: Int {
        didSet { UserDefaults.standard.set(spectrumFFTSize, forKey: "vis.spectrumFFTSize") }
    }
    @Published var spectrumDecaySpeed: String {
        didSet { UserDefaults.standard.set(spectrumDecaySpeed, forKey: "vis.spectrumDecaySpeed") }
    }
    @Published var spectrumMinDB: Float {
        didSet { UserDefaults.standard.set(spectrumMinDB, forKey: "vis.spectrumMinDB") }
    }
    @Published var spectrumGainTrimDB: Float {
        didSet { UserDefaults.standard.set(spectrumGainTrimDB, forKey: "vis.spectrumGainTrimDB") }
    }

    // MARK: - Spectrogram
    @Published var spectrogramDisplaySeconds: Int {
        didSet { UserDefaults.standard.set(spectrogramDisplaySeconds, forKey: "vis.spectrogramDisplaySeconds") }
    }
    @Published var spectrogramThresholdDB: Float {
        didSet { UserDefaults.standard.set(spectrogramThresholdDB, forKey: "vis.spectrogramThresholdDB") }
    }
    @Published var spectrogramGate: Float {
        didSet { UserDefaults.standard.set(spectrogramGate, forKey: "vis.spectrogramGate") }
    }
    @Published var spectrogramPowerCurve: Float {
        didSet { UserDefaults.standard.set(spectrogramPowerCurve, forKey: "vis.spectrogramPowerCurve") }
    }
    @Published var spectrogramGainTrimDB: Float {
        didSet { UserDefaults.standard.set(spectrogramGainTrimDB, forKey: "vis.spectrogramGainTrimDB") }
    }

    // MARK: - Waveform
    @Published var waveformDurationSeconds: Int {
        didSet { UserDefaults.standard.set(waveformDurationSeconds, forKey: "vis.waveformDurationSeconds") }
    }

    // MARK: - Rendering
    @Published var visualisationPerformanceMode: VisualisationPerformanceMode {
        didSet { UserDefaults.standard.set(visualisationPerformanceMode.rawValue, forKey: "vis.performanceMode") }
    }

    /// EMA alpha for spectrum smoothing derived from the chosen decay speed.
    var spectrumAlpha: Float {
        switch spectrumDecaySpeed {
        case "Fast": return 0.9
        case "Slow": return 0.4
        default:     return 0.7
        }
    }

    private init() {
        let ud = UserDefaults.standard
        spectrumFFTSize          = ud.object(forKey: "vis.spectrumFFTSize")          as? Int   ?? 1024
        spectrumDecaySpeed       = ud.string(forKey: "vis.spectrumDecaySpeed")               ?? "Medium"
        spectrumMinDB            = ud.object(forKey: "vis.spectrumMinDB")          as? Float ?? -60.0
        spectrumGainTrimDB       = ud.object(forKey: "vis.spectrumGainTrimDB")     as? Float ?? 0.0
        spectrogramDisplaySeconds = ud.object(forKey: "vis.spectrogramDisplaySeconds") as? Int ?? 30
        spectrogramThresholdDB   = ud.object(forKey: "vis.spectrogramThresholdDB") as? Float ?? -100.0
        spectrogramGate          = ud.object(forKey: "vis.spectrogramGate")        as? Float ?? 0.08
        spectrogramPowerCurve    = ud.object(forKey: "vis.spectrogramPowerCurve")  as? Float ?? 0.5
        spectrogramGainTrimDB    = ud.object(forKey: "vis.spectrogramGainTrimDB")  as? Float ?? 0.0
        waveformDurationSeconds  = ud.object(forKey: "vis.waveformDurationSeconds") as? Int  ?? 1
        let rawMode = ud.string(forKey: "vis.performanceMode") ?? "automatic"
        visualisationPerformanceMode = VisualisationPerformanceMode(rawValue: rawMode) ?? .automatic
    }
}
