"""Generate the Time Motion sound effects as 16-bit mono WAV files (standard library only).

Run from the repository root:  python3 Scripts/generate_time_motion_sounds.py
Output: HandARBrowser/TimeMotionSounds/*.wav (registered as a folder reference in Xcode).
"""
import math
import random
import struct
import wave
from pathlib import Path

RATE = 22050
OUT = Path(__file__).resolve().parent.parent / 'HandARBrowser' / 'TimeMotionSounds'


def tone(freq, seconds, decay, amp=0.6, sweep=None):
    n = int(RATE * seconds)
    samples = []
    phase = 0.0
    for i in range(n):
        t = i / RATE
        f = freq if sweep is None else freq + (sweep - freq) * (i / n)
        phase += 2 * math.pi * f / RATE
        env = math.exp(-decay * t) * min(1.0, i / 200.0)
        samples.append(amp * env * math.sin(phase))
    return samples


def noise(seconds, decay, amp=0.5, seed=1):
    rnd = random.Random(seed)
    n = int(RATE * seconds)
    return [amp * math.exp(-decay * i / RATE) * (rnd.random() * 2 - 1) for i in range(n)]


def mix(*layers):
    length = max(len(layer) for layer in layers)
    out = [0.0] * length
    for layer in layers:
        for i, v in enumerate(layer):
            out[i] += v
    return out


def sequence(*parts):
    out = []
    for part in parts:
        out.extend(part)
    return out


def write(name, samples):
    peak = max(1e-9, max(abs(s) for s in samples))
    scale = min(1.0, 0.92 / peak)
    OUT.mkdir(parents=True, exist_ok=True)
    with wave.open(str(OUT / f'{name}.wav'), 'wb') as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(RATE)
        f.writeframes(b''.join(struct.pack('<h', int(max(-1, min(1, s * scale)) * 32767)) for s in samples))


def silence(seconds):
    return [0.0] * int(RATE * seconds)


write('tm_shot', mix(noise(0.35, 22, 0.8, seed=3), tone(140, 0.3, 14, 0.5, sweep=60)))
write('tm_enemy_shot', mix(noise(0.25, 30, 0.35, seed=5), tone(420, 0.18, 22, 0.25, sweep=260)))
write('tm_hit', mix(tone(180, 0.25, 9, 0.7, sweep=90), noise(0.05, 80, 0.5, seed=7)))
write('tm_grab', mix(tone(1200, 0.09, 40, 0.35), tone(1800, 0.05, 60, 0.15)))
write('tm_release', tone(800, 0.16, 12, 0.35, sweep=480))
write('tm_shatter', mix(noise(0.6, 6, 0.6, seed=9), tone(2400, 0.4, 14, 0.12), tone(3100, 0.3, 18, 0.08)))
write('tm_thud', mix(tone(110, 0.22, 16, 0.8, sweep=70), noise(0.04, 120, 0.4, seed=11)))
write('tm_win', sequence(tone(523, 0.14, 8, 0.4), tone(659, 0.14, 8, 0.4), tone(784, 0.14, 8, 0.4), tone(1046, 0.4, 5, 0.45)))
write('tm_lose', sequence(tone(392, 0.2, 6, 0.45), tone(330, 0.2, 6, 0.45), tone(262, 0.2, 6, 0.45), tone(196, 0.5, 4, 0.45)))
print('wrote', len(list(OUT.glob('*.wav'))), 'sounds to', OUT)
