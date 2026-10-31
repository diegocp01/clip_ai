import AppKit

final class ChatPreferences {
    let manual: DrawingPreferences
    private let defaults: UserDefaults
    init(models: [DrawingModel], defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Preserve the former shared selection once, then keep chat independent.
        if !defaults.bool(forKey: "chatPreferencesInitialized") {
            for model in models {
                for suffix in ["Model.\(model.provider)", "Effort.\(model.id)"] {
                    if let value = defaults.string(forKey: "drawing\(suffix)") {
                        defaults.set(value, forKey: "chat\(suffix)")
                    }
                }
            }
            defaults.set(true, forKey: "chatPreferencesInitialized")
        }
        manual = DrawingPreferences(models: models, defaults: defaults, namespace: "chat")
    }
    var isAuto: Bool {
        get { defaults.object(forKey: "chatAuto") == nil || defaults.bool(forKey: "chatAuto") }
        set { defaults.set(newValue, forKey: "chatAuto") }
    }
    func request(for provider: String) -> [String: String] {
        var result = isAuto ? ["provider": provider, "model": "auto", "reasoningEffort": "auto"] : manual.request(for: provider)
        result["mode"] = "chat"
        return result
    }
    func caption(for provider: String) -> String {
        isAuto ? "Auto · Model & effort" : manual.caption(for: provider)
    }
}
