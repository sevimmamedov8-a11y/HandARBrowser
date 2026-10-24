import AVFoundation
import UIKit
import UniformTypeIdentifiers

/// Local music keeps drawing independent of network buffering and web players.
final class GraffitiRadio: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var tracks: [URL] = []
    private var index = 0
    private var background = false
    private var interrupted = false
    private var observers: [NSObjectProtocol] = []
    private(set) var level = 1
    private(set) var title = "Спокойная музыка"
    var onChange: (() -> Void)?
    var isPlaying: Bool { player?.isPlaying == true }
    var volumeTitle: String { ["20%", "40%", "65%", "85%"][level] }
    private var volume: Float { [0.2,0.4,0.65,0.85][level] }
    private var library: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("GraffitiMusic", isDirectory: true)
    }
    override init() {
        super.init()
        let saved = UserDefaults.standard.object(forKey: "graffiti.radio.volume") as? Int ?? 1
        level = (0...3).contains(saved) ? saved : 1
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.background = true; self?.pause()
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.background = false
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 1
            self?.interrupted = type == AVAudioSession.InterruptionType.began.rawValue
            if self?.interrupted == true { self?.pause() }
        })
        builtIn()
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    func builtIn() {
        stop()
        tracks = ["Chill - Alex McCulloch", "Gone Fishin - iamoneabe"].compactMap {
            Bundle.main.url(forResource: $0, withExtension: "mp3", subdirectory: "GraffitiMusic")
        }
        index = 0; title = tracks.first?.deletingPathExtension().lastPathComponent ?? "Музыка не найдена"
        onChange?()
    }
    func toggle() { if isPlaying { pause() } else { play() } }
    func play() {
        guard !background, !interrupted else { return }
        guard tracks.indices.contains(index) else { title = "Добавь песни из «Файлов»"; onChange?(); return }
        do {
            if player == nil {
                player = try AVAudioPlayer(contentsOf: tracks[index]); player?.delegate = self
                player?.prepareToPlay()
            }
            player?.volume = volume
            if player?.play() == true { title = tracks[index].deletingPathExtension().lastPathComponent }
            else { title = "Не удалось включить звук · попробуй ещё раз" }
        } catch { player = nil; title = "Файл не воспроизводится · выбери другую песню" }
        onChange?()
    }
    func pause() { player?.pause(); onChange?() }
    func stop() { player?.stop(); player = nil; onChange?() }
    func next() {
        guard !tracks.isEmpty else { return }
        stop(); index = (index+1)%tracks.count; play()
    }
    func nextVolume() {
        level = (level+1)%4; player?.volume = volume
        UserDefaults.standard.set(level, forKey: "graffiti.radio.volume"); onChange?()
    }
    func ownMusic() {
        guard let library else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let available = files.filter { ["mp3","m4a","wav","aac","aif","aiff"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !available.isEmpty else { title = "Нажми «Добавить песни»"; onChange?(); return }
        stop(); tracks = available; index = 0; play()
    }
    func importSongs(_ urls: [URL]) {
        guard let library else { return }
        do {
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            let existing = try FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)
            var copied = 0
            for url in urls.prefix(max(0,24-existing.count)) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard ["mp3","m4a","wav","aac","aif","aiff"].contains(url.pathExtension.lowercased()),
                      let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 40_000_000 else { continue }
                let destination = library.appendingPathComponent("\(UUID().uuidString.prefix(6)) \(url.lastPathComponent)")
                try FileManager.default.copyItem(at: url, to: destination); copied += 1
            }
            if copied > 0 { ownMusic() }
            else { title = "До 24 песен, по 40 МБ · MP3, M4A, WAV, AAC"; onChange?() }
        } catch { title = "Не удалось добавить файл"; onChange?() }
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard self.player === player else { return }
        if flag { next() } else { title = "Ошибка песни · нажми «Следующая»"; onChange?() }
    }
}

final class GraffitiMusicPicker: NSObject, UIDocumentPickerDelegate {
    private let completion: ([URL]) -> Void
    init(completion: @escaping ([URL]) -> Void) { self.completion = completion }
    func present(from host: UIViewController) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio], asCopy: true)
        picker.allowsMultipleSelection = true; picker.delegate = self
        host.present(picker, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completion(urls) }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion([]) }
}
