import AVFoundation
import QuartzCore

/// A local, preloaded one-shot: no network request or audio-session changes on hover.
final class WakeSound {
    private var player: AVAudioPlayer?
    private var lastPlayed: CFTimeInterval = -.infinity
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "wakeSoundEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "wakeSoundEnabled")
            if !newValue { player?.stop() }
        }
    }

    init() {
        guard let url = Bundle.main.url(forResource: "wake-chime", withExtension: "wav"),
              let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.volume = 0.20
        player.numberOfLoops = 0
        player.prepareToPlay()
        self.player = player
    }

    func play() {
        let now = CACurrentMediaTime()
        guard enabled, now - lastPlayed >= 2, let player, !player.isPlaying else { return }
        player.currentTime = 0
        if player.play() { lastPlayed = now }
    }
}
