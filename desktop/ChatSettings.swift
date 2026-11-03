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
    var autoScope: String {
        get { let value = defaults.string(forKey: "chatAutoScope") ?? "all"; return ["all", "gpt", "claude"].contains(value) ? value : "all" }
        set { defaults.set(newValue, forKey: "chatAutoScope") }
    }
    var isGlobalAuto: Bool { isAuto && autoScope == "all" }
    func selectGlobalAuto() { autoScope = "all"; isAuto = true }
    func selectProvider(_ provider: String) {
        autoScope = provider
        isAuto = defaults.object(forKey: "chatAuto.\(provider)") == nil || defaults.bool(forKey: "chatAuto.\(provider)")
    }
    func setAuto(_ value: Bool, for provider: String) {
        autoScope = provider; isAuto = value
        defaults.set(value, forKey: "chatAuto.\(provider)")
    }
    func request(for provider: String) -> [String: String] {
        var result = isAuto ? ["provider": provider, "model": "auto", "reasoningEffort": "auto", "autoScope": autoScope] : manual.request(for: provider)
        result["mode"] = "chat"
        return result
    }
    func caption(for provider: String) -> String {
        isAuto ? "Auto · \(isGlobalAuto ? "All models" : provider == "gpt" ? "Codex" : "Claude")" : manual.caption(for: provider)
    }
}
