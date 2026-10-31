import AppKit

struct DrawingModel: Decodable {
    let id: String
    let name: String
    let provider: String
    let efforts: [String]

    static func bundled(resource: String = "drawing-models") -> [DrawingModel] {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let models = try? JSONDecoder().decode([DrawingModel].self, from: data),
              !models.isEmpty else { preconditionFailure("Missing drawing model catalog") }
        return models
    }
}

/// Each provider keeps its model; each model keeps its last chosen effort.
final class DrawingPreferences {
    let models: [DrawingModel]
    private let defaults: UserDefaults
    private let namespace: String
    init(models: [DrawingModel], defaults: UserDefaults = .standard, namespace: String = "drawing") {
        self.models = models
        self.defaults = defaults
        self.namespace = namespace
    }
    func choices(for provider: String) -> [DrawingModel] { models.filter { $0.provider == provider } }
    func model(for provider: String) -> DrawingModel {
        let choices = choices(for: provider)
        let saved = defaults.string(forKey: "\(namespace)Model.\(provider)")
        return choices.first(where: { $0.id == saved }) ?? choices[0]
    }
    func effort(for provider: String) -> String {
        let model = model(for: provider)
        let saved = defaults.string(forKey: "\(namespace)Effort.\(model.id)") ?? "low"
        return model.efforts.contains(saved) ? saved : "low"
    }
    func select(model id: String, provider: String) {
        guard choices(for: provider).contains(where: { $0.id == id }) else { return }
        defaults.set(id, forKey: "\(namespace)Model.\(provider)")
    }
    func select(effort: String, provider: String) {
        let model = model(for: provider)
        guard model.efforts.contains(effort) else { return }
        defaults.set(effort, forKey: "\(namespace)Effort.\(model.id)")
    }
    func request(for provider: String) -> [String: String] {
        ["provider": provider, "model": model(for: provider).id, "reasoningEffort": effort(for: provider)]
    }
    static func effortTitle(_ value: String) -> String {
        ["xhigh": "Extra high", "max": "Maximum"][value] ?? value.capitalized
    }
    func caption(for provider: String) -> String {
        "\(model(for: provider).name) · \(Self.effortTitle(effort(for: provider))) effort"
    }
}
