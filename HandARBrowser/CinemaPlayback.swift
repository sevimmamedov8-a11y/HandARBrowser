import AVFoundation
import SceneKit
import UIKit

// MARK: - Кино-плеер ---------------------------------------------------------

/// Нативный AVPlayer-экран зала.
///
/// Зачем: WKWebView.takeSnapshot не захватывает аппаратное HTML5-видео
/// (кадр видео уходит отдельным слоем), поэтому картинка YouTube в VR
/// всегда чёрная, а субтитры — DOM-ом — видны. Аппаратный плеер рисует
/// кадры прямо в сцену SceneKit, ссылку на поток мы забираем у `<video>`
/// открытой страницы (в iOS YouTube отдаёт HLS прямым URL).
final class CinemaPlayback: NSObject {
    var onProgress: ((Double, Double) -> Void)?
    var onFailed: ((String) -> Void)?
    var onStarted: (() -> Void)?

    private(set) var isActive = false
    private(set) var isPlaying = false
    private(set) var duration: Double = 0
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?

    /// Показатель того, что экран зала уже переключён на плеер.
    private weak var screenMaterial: SCNMaterial?

    // MARK: Загрузка

    func load(url: URL, into material: SCNMaterial) {
        release()
        screenMaterial = material

        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetAllowsCellularAccessKey": true
        ])
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = true

        statusObserver = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            guard let self else { return }
            if item.status == .readyToPlay {
                self.duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
                self.startProgress()
                self.onStarted?()
                self.play()
            } else if item.status == .failed {
                self.onFailed?(item.error?.localizedDescription ?? "Не удалось запустить видео")
            }
        }

        self.player = player
        isActive = true
        showIn(material)
    }

    /// Переключить экран зала на кадры плеера.
    func showIn(_ material: SCNMaterial) {
        guard let player else { return }
        screenMaterial = material
        material.lightingModel = .constant
        material.diffuse.contents = player
        material.emission.contents = player
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
    }

    private func startProgress() {
        guard let player else { return }
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, let item = self.player?.currentItem else { return }
            let current = time.seconds.isFinite ? time.seconds : 0
            let total = item.duration.seconds.isFinite ? item.duration.seconds : 0
            self.duration = total
            self.onProgress?(current, total)
        }
    }

    private func removeObserver() {
        statusObserver?.invalidate()
        statusObserver = nil
    }

    // MARK: Управление

    func play() {
        player?.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func setVolume(_ value: Float) {
        player?.volume = min(max(value, 0), 1)
    }

    var volume: Float {
        get { player?.volume ?? 0 }
        set { setVolume(newValue) }
    }

    func seek(by seconds: Double) {
        seek(to: currentTime() + seconds)
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        let target = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func restart() {
        seek(to: 0)
        play()
    }

    func currentTime() -> Double {
        guard let player else { return 0 }
        let t = player.currentTime().seconds
        return t.isFinite ? t : 0
    }

    // MARK: Стоп

    func release() {
        if let player, let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        removeObserver()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        isActive = false
        isPlaying = false
        duration = 0
        screenMaterial?.diffuse.contents = UIColor.black
        screenMaterial?.emission.contents = UIColor.black
        screenMaterial = nil
    }
}
