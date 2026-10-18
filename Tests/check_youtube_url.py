"""Golden URL checks against the exact Swift router; run with macOS Swift."""
from pathlib import Path
import tempfile
from swift_test_support import run_swift_sources
r=Path(__file__).resolve().parent.parent
s=(r/'HandARBrowser/MainViewController.swift').read_text(encoding='utf-8')
start=s.index('    private func youtubeWatchURL(')
end=s.index('    // MARK: Жизненный цикл',start)
tests='''
let sample = URL(string: "https://youtu.be/LnFf8iFs0a8?si=PX3WwRLuzdupfdnN")!
precondition(youtubeWatchURL(sample)?.absoluteString == "https://m.youtube.com/watch?v=LnFf8iFs0a8")
precondition(youtubeWatchURL(URL(string:"https://www.youtube.com/watch?v=LnFf8iFs0a8&t=42s")!)?.absoluteString == "https://m.youtube.com/watch?v=LnFf8iFs0a8&t=42s")
precondition(youtubeWatchURL(URL(string:"https://youtube.com/shorts/LnFf8iFs0a8")!) != nil)
precondition(youtubeWatchURL(URL(string:"https://youtube.com.evil.example/watch?v=LnFf8iFs0a8")!) == nil)
precondition(youtubeWatchURL(URL(string:"https://youtu.be/bad")!) == nil)
print("PASS: example link, timestamp, Shorts, domain and ID validation")
'''
with tempfile.TemporaryDirectory(prefix='handar-youtube-') as directory:
    script=Path(directory)/'url.swift'
    script.write_text('import Foundation\n'+s[start:end]+tests,encoding='utf-8')
    run_swift_sources([script])
