import Foundation

@MainActor
final class PersistedDisplayConfig {
    static let defaultsKey = "titanplayer.displays.config.v1"

    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func load() throws -> [String: ExternalDisplayConfig] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [:] }
        return try decoder.decode([String: ExternalDisplayConfig].self, from: data)
    }

    func save(_ configs: [ExternalDisplayConfig]) throws {
        let dict = Dictionary(uniqueKeysWithValues: configs.map { ($0.stableID, $0) })
        let data = try encoder.encode(dict)
        defaults.set(data, forKey: Self.defaultsKey)
    }

    func merge(newDisplays: [ExternalDisplayConfig]) throws {
        var current = (try? load()) ?? [:]
        for display in newDisplays { current[display.stableID] = display }
        try save(Array(current.values))
    }
}
