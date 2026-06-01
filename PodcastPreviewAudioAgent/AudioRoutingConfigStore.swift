import Foundation

final class AudioRoutingConfigStore {
    private let decoder = PropertyListDecoder()
    private let encoder = PropertyListEncoder()

    func load() -> AudioRoutingConfiguration {
        let url = configurationURL()
        guard let data = try? Data(contentsOf: url),
              let configuration = try? decoder.decode(AudioRoutingConfiguration.self, from: data) else {
            return AudioRoutingConfiguration()
        }
        return configuration
    }

    func save(_ configuration: AudioRoutingConfiguration) {
        let url = configurationURL()
        let directoryURL = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(configuration) else {
            return
        }
        try? data.write(to: url, options: [.atomic])
    }

    private func configurationURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return baseURL
            .appendingPathComponent("PodcastPreview", isDirectory: true)
            .appendingPathComponent("AudioRoutingService", isDirectory: true)
            .appendingPathComponent("RouteConfiguration.plist", isDirectory: false)
    }
}
