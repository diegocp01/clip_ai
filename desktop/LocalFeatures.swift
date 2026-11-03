import Foundation

/// Names and stable IDs live in the user's private settings, never in the app bundle.
struct ClipHabit: Codable, Equatable {
    let id: String
    let title: String
}

struct LocalFeatures: Decodable {
    struct Habits: Codable, Equatable {
        let enabled: Bool
        let items: [ClipHabit]
    }
    let habits: Habits?
    static let disabled = LocalFeatures(habits: nil)
    static var settingsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clip/local-features.json")
    }
    var enabledHabits: [ClipHabit]? {
        guard let habits, habits.enabled, habits.items.count == 7,
              Set(habits.items.map(\.id)).count == 7,
              habits.items.allSatisfy({ item in
                  !item.id.isEmpty && item.id.utf8.count <= 64 &&
                  item.id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } &&
                  !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  item.title.count <= 32 && !item.title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
              }) else { return nil }
        return habits.items
    }
    /// Fail closed. Demo mode ignores all personal configuration, even when locally enabled.
    static func load(from url: URL = settingsURL, arguments: [String] = ProcessInfo.processInfo.arguments) -> LocalFeatures {
        guard !arguments.contains("--public-demo"),
              let data = try? Data(contentsOf: url), data.count <= 16_384,
              let settings = try? JSONDecoder().decode(LocalFeatures.self, from: data) else { return .disabled }
        return settings
    }
}
