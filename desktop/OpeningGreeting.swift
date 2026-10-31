import Foundation

// Local microcopy keeps every opening immediate, including offline.
// Shuffle without repeats until the deck is exhausted; remember the last line
// across launches so restarting does not greet with the same line again.
struct OpeningGreeting {
    static let phrases = [
        "What’s on your mind?", "Ready when you are.", "Let’s explore an idea.",
        "A little clarity?", "Where shall we start?", "Bring me your curiosity.",
        "Something worth exploring?", "Let’s make it simpler.", "An idea taking shape?",
        "Room for a new thought.", "What are we discovering?", "Let’s think it through.",
        "A fresh perspective awaits.", "One thought at a time.", "What shall we untangle?",
        "Your next idea starts here.", "Small questions welcome.", "Curious about something?",
        "Let’s find the next step.", "A question worth asking?", "What caught your attention?",
        "Make room for curiosity.", "Let’s connect the dots.", "Something new to explore?"
    ]
    private var remaining: [String] = []
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    mutating func next() -> String {
        if remaining.isEmpty { remaining = Self.phrases.shuffled() }
        let previous = defaults.string(forKey: "lastOpeningGreeting")
        let index = remaining.firstIndex { $0 != previous } ?? 0
        let phrase = remaining.remove(at: index)
        defaults.set(phrase, forKey: "lastOpeningGreeting")
        return phrase
    }
}

struct OpeningCaptionFrame {
    let greeting: Bool
    let opacity: Double
    let finished: Bool
    static func at(_ elapsed: TimeInterval, reducedMotion: Bool) -> Self {
        let hold = 3.2, fade = 1.2, reveal = 0.5
        if elapsed < hold { return Self(greeting: true, opacity: 1, finished: false) }
        if reducedMotion { return Self(greeting: false, opacity: 1, finished: true) }
        func smooth(_ value: Double) -> Double { let t = min(1, max(0, value)); return t * t * (3 - 2 * t) }
        if elapsed < hold + fade { return Self(greeting: true, opacity: 1 - smooth((elapsed - hold) / fade), finished: false) }
        return Self(greeting: false, opacity: smooth((elapsed - hold - fade) / reveal), finished: elapsed >= hold + fade + reveal)
    }
}
