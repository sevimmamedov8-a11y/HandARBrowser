import Foundation

enum GraffitiSound: String, CaseIterable {
    case tap, palette, color, undo, reset, grab, metal, wood, soft, plastic, spray
    static func feedback(for action: String) -> Self {
        if action.hasPrefix("color-") || action == "rainbow" { return .color }
        if action == "undo" { return .undo }
        if action == "setting-props" || action == "setting-reset" { return .reset }
        if ["palette", "setting-close", "room", "home", "exit"].contains(action) { return .palette }
        return .tap
    }
}

#if canImport(AVFoundation) && canImport(UIKit)
import AVFoundation
import UIKit

/// Small, predecoded local effects. No files or players are created by a gesture.
final class GraffitiAudio {
    private var players: [GraffitiSound: [AVAudioPlayer]] = [:]
    private var lastPlayed: [GraffitiSound: Double] = [:]
    private var observers: [NSObjectProtocol] = []
    private var interrupted = false
    private var foreground = true
    private(set) var enabled = !UserDefaults.standard.bool(forKey: "graffiti.sound.muted")
    private(set) var level: Int = {
        let value = UserDefaults.standard.object(forKey: "graffiti.sound.level") as? Int ?? 1
        return (0...2).contains(value) ? value : 1
    }()
    var volumeTitle: String { ["25%", "55%", "85%"][level] }
    private var volume: Float { enabled ? [0.25, 0.55, 0.85][level] : 0 }

    init() {
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            self.interrupted = type == .began
            if self.interrupted { self.stop() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.foreground = false; self?.stop()
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.foreground = true })
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    func prepare() {
        guard players.isEmpty else { return }
        for sound in GraffitiSound.allCases {
            guard let url = Bundle.main.url(forResource: sound.rawValue, withExtension: "wav", subdirectory: "GraffitiSounds") else { continue }
            var voices: [AVAudioPlayer] = []
            for _ in 0..<(sound == .spray ? 1 : 2) {
                guard let player = try? AVAudioPlayer(contentsOf: url) else { continue }
                player.numberOfLoops = sound == .spray ? -1 : 0
                player.prepareToPlay(); voices.append(player)
            }
            players[sound] = voices
        }
        applyVolume()
    }
    func play(_ sound: GraffitiSound, at time: Double = ProcessInfo.processInfo.systemUptime) {
        guard enabled, !interrupted, foreground, sound != .spray, time.isFinite,
              time-(lastPlayed[sound] ?? -.infinity) >= 0.04,
              let voices = players[sound], let player = voices.first(where: { !$0.isPlaying }) ?? voices.first else { return }
        lastPlayed[sound] = time
        player.currentTime = 0; player.volume = volume; player.play()
    }
    func setSpraying(_ spraying: Bool) {
        guard let player = players[.spray]?.first else { return }
        if spraying && enabled && !interrupted && foreground {
            if !player.isPlaying { player.volume = volume*0.6; player.play() }
        } else if player.isPlaying { player.pause(); player.currentTime = 0 }
    }
    func stop() {
        for voices in players.values { for player in voices { player.pause(); player.currentTime = 0 } }
        lastPlayed.removeAll()
    }
    func toggle() {
        enabled.toggle(); UserDefaults.standard.set(!enabled, forKey: "graffiti.sound.muted")
        if !enabled { stop() }; applyVolume()
    }
    func nextVolume() {
        level = (level+1)%3; UserDefaults.standard.set(level, forKey: "graffiti.sound.level"); applyVolume()
    }
    func resetSettings() {
        enabled = true; level = 1
        UserDefaults.standard.removeObject(forKey: "graffiti.sound.muted")
        UserDefaults.standard.removeObject(forKey: "graffiti.sound.level")
        applyVolume()
    }
    private func applyVolume() {
        for (sound, voices) in players { for player in voices { player.volume = volume*(sound == .spray ? 0.6 : 1) } }
    }
}
#endif
