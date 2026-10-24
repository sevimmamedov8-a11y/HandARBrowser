"""Generate original, deterministic PCM effects; no downloaded audio required."""
from pathlib import Path
import array
import math
import random
import sys
import wave

folder = Path(__file__).resolve().parent.parent/'HandARBrowser/GraffitiSounds'
folder.mkdir(exist_ok=True)
rate = 22050
specs = {
    'tap': (0.07, [950, 1425], 0.12, 0.01),
    'palette': (0.16, [520, 780, 1040], 0.12, 0),
    'color': (0.12, [880, 1100, 1320], 0.12, 0),
    'undo': (0.18, [700, 470], 0.11, 0.015),
    'reset': (0.23, [440, 660, 880], 0.12, 0),
    'grab': (0.10, [180, 340], 0.13, 0.10),
    'metal': (0.24, [1250, 2190, 3270], 0.17, 0.025),
    'wood': (0.18, [170, 390, 810], 0.20, 0.06),
    'soft': (0.13, [120], 0.08, 0.12),
    'plastic': (0.14, [620, 1310], 0.16, 0.055),
    'spray': (1.2, [], 0, 0.15),
}
for index, (name, (duration, tones, gain, noise_gain)) in enumerate(specs.items()):
    count = round(duration*rate)
    rng = random.Random(9800+index)
    noise = [rng.uniform(-1, 1) for _ in range(count)]
    samples = array.array('h')
    for i in range(count):
        t = i/rate
        hiss = (noise[i]-0.6*noise[i-1])/1.6
        value = sum(math.sin(2*math.pi*f*t) for f in tones)/max(1,len(tones))*gain + hiss*noise_gain
        if name != 'spray':
            attack = min(1, t/0.004)
            tail = min(1, (count-1-i)/(rate*0.012))
            value *= attack*tail*math.exp(-4*t/duration)
        samples.append(round(max(-0.8,min(0.8,value))*32767))
    if sys.byteorder != 'little':
        samples.byteswap()
    with wave.open(str(folder/(name+'.wav')), 'wb') as wav:
        wav.setparams((1,2,rate,0,'NONE','not compressed'))
        wav.writeframes(samples.tobytes())
print(f'Generated {len(specs)} original effects in {folder}')
