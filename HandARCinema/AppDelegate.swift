import AVFoundation
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Кинотеатр живёт звуком: разрешаем фоновое воспроизведение и
        // не даём переключателю беззвучного режима глушить фильм.
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .moviePlayback,
                options: [.mixWithOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("AudioSession: \(error.localizedDescription)")
        }

        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = CinemaViewController()
        window?.makeKeyAndVisible()
        return true
    }
}
