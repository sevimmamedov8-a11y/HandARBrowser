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
/// открытой страницы, когда она предоставляет доступный прямой URL.
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
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var generation = UUID()
    private var loadTimeout: DispatchWorkItem?

    /// Показатель того, что экран зала уже переключён на плеер.
    private weak var screenMaterial: SCNMaterial?

    // MARK: Загрузка

    func load(url: URL, into material: SCNMaterial) {
        release()
        screenMaterial = material
        let loadGeneration = generation

        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetAllowsCellularAccessKey": true
        ])
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = false
        player.volume = 1
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = true

        self.player = player
        isActive = true
        showIn(material)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            guard let self, self.generation == loadGeneration else { return }
            self.isPlaying = false
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            guard let self, self.generation == loadGeneration else { return }
            self.release()
            self.onFailed?("Воспроизведение потока прервано")
        }

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == loadGeneration else { return }
            self.release()
            self.onFailed?("Поток не загрузился за 20 секунд")
        }
        loadTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)

        // Статус приходит с внутренней очереди AVFoundation, а материал
        // и UIKit можно трогать только с главной — переводим сами.
        statusObserver = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            guard let self else { return }
            let status = item.status
            let seconds = item.duration.seconds
            let message = item.error?.localizedDescription ?? "Не удалось запустить видео"
            DispatchQueue.main.async {
                guard self.generation == loadGeneration else { return }
                if status == .readyToPlay {
                    self.loadTimeout?.cancel()
                    self.loadTimeout = nil
                    self.duration = seconds.isFinite ? seconds : 0
                    self.startProgress()
                    self.onStarted?()
                    self.play()
                } else if status == .failed {
                    self.release()
                    self.onFailed?(message)
                }
            }
        }

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
        guard let player else { return }
        player.play()
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
        guard value.isFinite else { return }
        player?.volume = min(max(value, 0), 1)
        if value > 0 { player?.isMuted = false }
    }

    var isSoundEnabled: Bool { player.map { !$0.isMuted && $0.volume > 0 } ?? false }

    var volume: Float {
        get { player?.volume ?? 0 }
        set { setVolume(newValue) }
    }

    func seek(by seconds: Double) {
        seek(to: currentTime() + seconds)
    }

    func seek(to seconds: Double) {
        guard let player, seconds.isFinite else { return }
        let upper = duration > 0 ? duration : Double.greatestFiniteMagnitude
        let target = CMTime(seconds: min(max(seconds, 0), upper), preferredTimescale: 600)
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

    deinit { release() }

    // MARK: Стоп

    func release() {
        loadTimeout?.cancel()
        loadTimeout = nil
        generation = UUID()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        endObserver = nil
        failureObserver = nil
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
