import Foundation

final class AVAudioPlayer {
    var enableRate = false, isPlaying = false
    var rate: Float = 1, volume: Float = 1
    var currentTime = 0.0, plays = 0
    init(contentsOf: URL) throws {}
    @discardableResult func prepareToPlay() -> Bool { true }
    @discardableResult func play() -> Bool { isPlaying = true; plays += 1; return true }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false; currentTime = 0 }
}

@main struct AudioTests {
    static func main() throws {
        let bank = TMSoundBank()
        for sound in TMSound.allCases { bank.players[sound] = try AVAudioPlayer(contentsOf:URL(fileURLWithPath:"unused.wav")) }
        var count = 0
        func check(_ result:Bool,_ label:String) {precondition(result,label);count += 1}
        let shot = bank.players[.shot]!,grab = bank.players[.grab]!
        bank.setTimeScale(0.25);bank.play(.shot)
        check(shot.isPlaying && shot.enableRate && shot.rate == 0.5,"combat sound slows within AVAudioPlayer's supported rate")
        shot.currentTime = 0.12
        bank.setTimeScale(0)
        check(!shot.isPlaying && shot.currentTime == 0.12,"exact freeze pauses sound without rewinding")
        bank.play(.shot)
        check(shot.plays == 1,"no new shot sound can start while time is frozen")
        bank.play(.grab)
        check(grab.isPlaying && !grab.enableRate,"UI and grab feedback still works when world is frozen")
        bank.setTimeScale(0.8)
        check(shot.isPlaying && shot.rate == 0.8 && shot.plays == 2 && shot.currentTime == 0.12,"moving resumes the same paused sound at the new rate")
        bank.setTimeScale(0.9)
        check(shot.plays == 2,"ordinary updates do not restart a playing sound")
        bank.setTimeScale(0);bank.stopAll();bank.setTimeScale(1)
        check(!shot.isPlaying && !grab.isPlaying,"exit/reset clears pending sound resumes")
        bank.play(.win);bank.setTimeScale(0)
        check(bank.players[.win]!.isPlaying,"result sound survives the end-of-round freeze")
        print("PASS: \(count) production Time Motion audio checks")
    }
}
