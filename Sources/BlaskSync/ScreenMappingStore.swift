import Foundation
import SyncCore

/// Persists each area's screen mapping in UserDefaults.
struct ScreenMappingStore {
    private let defaults = UserDefaults.standard

    private func key(_ areaId: String) -> String { "screenMapping.\(areaId)" }

    func load(areaId: String) -> ScreenMapping? {
        defaults.data(forKey: key(areaId)).flatMap { try? JSONDecoder().decode(ScreenMapping.self, from: $0) }
    }

    func save(_ mapping: ScreenMapping, areaId: String) {
        guard let data = try? JSONEncoder().encode(mapping) else { return }
        defaults.set(data, forKey: key(areaId))
    }
}
