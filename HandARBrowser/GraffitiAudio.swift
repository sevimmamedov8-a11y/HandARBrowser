import Foundation

enum GraffitiSound: String, CaseIterable {
    case tap, palette, color, undo, reset, grab, metal, wood, soft, plastic, rubber, spray, sprayStart, sprayEnd, erase
    var loops: Bool { self == .spray || self == .erase }
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
    private var sprayStartedAt: Double?
    private var variation = 0
    private var brushing = false, erasing = false
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
            for _ in 0..<(sound.loops ? 1 : 2) {
                guard let player = try? AVAudioPlayer(contentsOf: url) else { continue }
                player.numberOfLoops = sound.loops ? -1 : 0
                player.enableRate = true
                player.prepareToPlay(); voices.append(player)
            }
            players[sound] = voices
        }
        applyVolume()
    }
    func play(_ sound: GraffitiSound, intensity: Float = 1, at time: Double = ProcessInfo.processInfo.systemUptime) {
        guard enabled, !interrupted, foreground, !sound.loops, time.isFinite, intensity.isFinite,
              time-(lastPlayed[sound] ?? -.infinity) >= 0.04,
              let voices = players[sound], let player = voices.first(where: { !$0.isPlaying }) ?? voices.first else { return }
        lastPlayed[sound] = time
        variation = (variation+1)%5
        let impact = [GraffitiSound.metal,.wood,.soft,.plastic,.rubber].contains(sound)
        player.rate = impact ? [0.96,1.02,0.99,1.04,1][variation] : 1
        player.currentTime = 0; player.volume = volume*max(0,min(1,intensity)); player.play()
    }
    func setSpraying(_ spraying: Bool, at time: Double = ProcessInfo.processInfo.systemUptime) {
        guard let player = players[.spray]?.first else { return }
        if spraying && enabled && !interrupted && foreground && time.isFinite {
            guard sprayStartedAt == nil else { return }
            sprayStartedAt = time
            play(.sprayStart, intensity: 0.8, at: time)
            player.currentTime = 0; player.volume = volume*0.10; player.play()
            player.setVolume(volume*0.6, fadeDuration: 0.55)
        } else if let start = sprayStartedAt {
            sprayStartedAt = nil
            player.setVolume(0, fadeDuration: 0); player.pause(); player.currentTime = 0
            let duration = time.isFinite ? max(0,time-start) : 0
            play(.sprayEnd, intensity: Float(min(0.7,0.25+duration)), at: time)
        }
    }
    func setBrushing(_ value: Bool) { brushing = value; updateRubbing() }
    func setErasing(_ value: Bool) { erasing = value; updateRubbing() }
    private func updateRubbing() {
        guard let player = players[.erase]?.first else { return }
        if (erasing || brushing) && enabled && !interrupted && foreground {
            let gain: Float = erasing ? 0.32 : 0.12
            if !player.isPlaying { player.volume = 0; player.play() }
            player.setVolume(volume*gain,fadeDuration:0.06)
        } else { player.setVolume(0,fadeDuration:0); player.pause(); player.currentTime = 0 }
    }
    func stop() {
        sprayStartedAt = nil; brushing = false; erasing = false
        for voices in players.values { for player in voices { player.setVolume(0, fadeDuration: 0); player.pause(); player.currentTime = 0 } }
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
        for (sound, voices) in players { for player in voices {
            if sound == .spray, let start = sprayStartedAt {
                let remaining = max(0,0.55-(ProcessInfo.processInfo.systemUptime-start))
                player.setVolume(volume*0.6, fadeDuration: remaining)
            } else { player.volume = volume*(sound == .erase ? (erasing ? 0.32 : 0.12) : (sound == .spray ? 0.1 : 1)) }
        } }
    }
}
#endif
