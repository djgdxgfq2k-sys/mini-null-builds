import Foundation

enum ToolSettingsStore {
    private static let key = "nullmini.toolSettings.v1"
    static func load(defaults: UserDefaults = .standard) -> ToolSettings {
        guard let saved = defaults.data(forKey: key),
              let values = try? JSONSerialization.jsonObject(with: saved) as? [String: Any],
              let baseline = try? JSONEncoder().encode(ToolSettings()),
              var merged = try? JSONSerialization.jsonObject(with: baseline) as? [String: Any] else { return ToolSettings() }
        // Missing/new fields retain their defaults. One obsolete enum value must not discard other preferences.
        for (key, value) in values where merged[key] != nil {
            var candidate = merged; candidate[key] = value
            if let data = try? JSONSerialization.data(withJSONObject: candidate), (try? JSONDecoder().decode(ToolSettings.self, from: data)) != nil { merged = candidate }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: merged), var result = try? JSONDecoder().decode(ToolSettings.self, from: data) else { return ToolSettings() }
        func unit(_ value: Double, fallback: Double) -> Double { value.isFinite ? min(1, max(0, value)) : fallback }
        result.width = result.width.isFinite ? min(100, max(0.1, result.width)) : 1
        let defaults: [CGFloat] = [1, 2, 4]
        result.widthPresets = (0..<3).map { i in let v = result.widthPresets.indices.contains(i) ? result.widthPresets[i] : defaults[i]; return v.isFinite ? min(100, max(0.1, v)) : defaults[i] }
        result.pressure = unit(result.pressure, fallback: 0.5); result.sharpness = unit(result.sharpness, fallback: 0.5)
        result.tipRoundness = unit(result.tipRoundness, fallback: 0.5)
        result.stabilization = unit(result.stabilization, fallback: 0.22); result.highlighterStabilization = unit(result.highlighterStabilization, fallback: 1)
        result.fillOpacity = unit(result.fillOpacity, fallback: 1); result.eraserSize = min(2, max(0, result.eraserSize))
        result.readOnly = false
        return result
    }
    static func save(_ value: ToolSettings, defaults: UserDefaults = .standard) {
        var preferences = value; preferences.readOnly = false
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: key) }
    }
}
