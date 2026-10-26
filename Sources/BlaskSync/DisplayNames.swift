import HueKit
import SyncCore

// Translated names for values whose raw values are identifiers, not words to show.

extension SyncIntensity {
    var title: String {
        switch self {
        case .subtle: String(localized: "Subtle", comment: "Sync intensity")
        case .moderate: String(localized: "Moderate", comment: "Sync intensity")
        case .high: String(localized: "High", comment: "Sync intensity")
        case .extreme: String(localized: "Extreme", comment: "Sync intensity")
        }
    }
}

extension MusicPalette {
    var title: String {
        switch self {
        case .vivid: String(localized: "Vivid", comment: "Color palette")
        case .sunset: String(localized: "Sunset", comment: "Color palette")
        case .ocean: String(localized: "Ocean", comment: "Color palette")
        case .party: String(localized: "Party", comment: "Color palette")
        }
    }
}

extension EntertainmentArea {
    /// The area's kind as the Hue app names it.
    var configurationTitle: String {
        switch configurationType {
        case "screen": String(localized: "TV", comment: "Entertainment area type")
        case "monitor": String(localized: "Monitor", comment: "Entertainment area type")
        case "music": String(localized: "Music", comment: "Entertainment area type")
        case "3dspace": String(localized: "3D space", comment: "Entertainment area type")
        default: String(localized: "Other", comment: "Entertainment area type")
        }
    }
}
