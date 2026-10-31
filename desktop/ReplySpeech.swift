import AppKit
import AVFoundation

enum ReplyVoice {
    static let names = ["marin", "cedar", "coral", "ash", "alloy", "ballad", "echo", "fable", "nova", "onyx", "sage", "shimmer", "verse"]
    static func selected(_ defaults: UserDefaults = .standard) -> String {
        let value = defaults.string(forKey: "replyVoice") ?? "marin"
        return names.contains(value) ? value : "marin"
    }
    // Preserve the exact displayed text and split at whitespace when possible.
    // Bound each request by UTF-16 units, including non-English text and emoji.
    static func chunks(_ text: String) -> [String] {
        var rest = text[...], result = [String]()
        while !rest.isEmpty {
            var end = rest.startIndex, units = 0, boundary: String.Index?
            while end < rest.endIndex {
                let next = rest.index(after: end), count = rest[end..<next].utf16.count
                if units + count > 1200 && end > rest.startIndex { break }
                units += count
                if rest[end].isWhitespace { boundary = next }
                end = next
            }
            if end < rest.endIndex, let boundary { end = boundary }
            result.append(String(rest[..<end])); rest = rest[end...]
        }
        return result
    }
}

/// One in-memory MP3 at a time; no audio files or local model retained.
final class ReplySpeech: NSObject, AVAudioPlayerDelegate {
    var onState: ((String) -> Void)?
    private(set) var isActive = false
    private var generation = 0
    private var task: URLSessionDataTask?
    private var player: AVAudioPlayer?
    private let session = URLSession(configuration: .ephemeral)
    private var parts = [String](), index = 0, token = "", voice = "marin"
    private var base = URL(string: "http://127.0.0.1:4317")!
    func stop() {
        generation += 1; task?.cancel(); task = nil
        player?.stop(); player = nil; parts = []; isActive = false
        onState?("Ready")
    }
    func speak(_ text: String, voice: String, baseURL: URL) {
        stop(); guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        self.voice = voice; base = baseURL; parts = ReplyVoice.chunks(text); index = 0; isActive = true
        onState?("Preparing voice…")
        let current = generation
        task = session.dataTask(with: URLRequest(url: base.appendingPathComponent("api/session"), timeoutInterval: 5)) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200,
                      let data, let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: String], let token = value["token"] else { self.fail(); return }
                self.token = token; self.next(current)
            }
        }; task?.resume()
    }
    private func next(_ current: Int) {
        guard generation == current else { return }
        while index < parts.count && parts[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { index += 1 }
        guard index < parts.count else { stop(); return }
        onState?("Preparing voice…")
        var request = URLRequest(url: base.appendingPathComponent("api/speech"), timeoutInterval: 50)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-Clippy-Session")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": parts[index], "voice": voice])
        task = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.task = nil
                guard error == nil, let response = response as? HTTPURLResponse, response.statusCode == 200,
                      response.mimeType == "audio/mpeg", let data, data.count <= 8 * 1024 * 1024 else { self.fail(); return }
                do {
                    self.player = try AVAudioPlayer(data: data); self.player?.delegate = self
                    guard self.player?.play() == true else { self.fail(); return }
                    self.onState?("Speaking")
                } catch { self.fail() }
            }
        }; task?.resume()
    }
    private func fail() { stop(); onState?("Voice unavailable · text reply kept") }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === self.player else { return }
        self.player = nil
        guard flag else { fail(); return }
        index += 1; next(generation)
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard player === self.player else { return }; fail()
    }
}
