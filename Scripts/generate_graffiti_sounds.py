"""Original 44.1 kHz PCM: filtered air, valve transients and damped impacts."""
from pathlib import Path
import array
import math
import random
import sys
import wave

folder = Path(__file__).resolve().parent.parent/'HandARBrowser/GraffitiSounds'
folder.mkdir(exist_ok=True)
rate = 44100
specs = {
    'tap': (0.07, [950,1425], 0.10, 0.015),
    'palette': (0.16, [520,780,1040], 0.10, 0),
    'color': (0.12, [880,1100,1320], 0.10, 0),
    'undo': (0.18, [700,470], 0.10, 0.015),
    'reset': (0.23, [440,660,880], 0.10, 0),
    'grab': (0.12, [143,287,513], 0.13, 0.12),
    'metal': (0.48, [337,893,1517,2673,4011], 0.20, 0.10),
    'wood': (0.26, [137,293,617,1019], 0.22, 0.17),
    'soft': (0.20, [93,163], 0.08, 0.20),
    'plastic': (0.28, [423,967,1891], 0.18, 0.13),
    'rubber': (0.38, [83,147,231], 0.29, 0.13),
    'spray': (1.6, [], 0, 0.30),
    'sprayStart': (0.16, [1700], 0.028, 0.38),
    'sprayEnd': (0.10, [1100], 0.016, 0.22),
    'erase': (1.4, [], 0, 0.22),
}
for index, (name, (duration, tones, gain, noise_gain)) in enumerate(specs.items()):
    count = round(duration*rate)
    rng = random.Random(10000+index)
    raw = [rng.uniform(-1,1) for _ in range(count)]
    # Circular low-pass differences give airy band-limited noise, with no
    # hard random discontinuity at the loop splice.
    filtered = []
    for i in range(count):
        high = sum(raw[(i-j)%count] for j in range(3))/3
        low = sum(raw[(i-j)%count] for j in range(16))/16
        filtered.append(high-low if name.startswith('spray') else low*2)
    samples = array.array('h')
    looping = name in ('spray','erase')
    for i in range(count):
        t = i/rate
        tone = sum(math.sin(2*math.pi*f*t)*math.exp(-t*(7+j*9)) for j,f in enumerate(tones))/max(1,len(tones))
        air = filtered[i]
        if looping:
            value = air*noise_gain*(0.90+0.10*math.sin(2*math.pi*3*t/duration))
        else:
            attack = min(1,t/0.0025)
            tail = min(1,(count-1-i)/(rate*0.018))
            envelope = math.exp(-t*(24 if name.startswith('spray') else 16))
            value = (tone*gain + air*noise_gain*envelope)*attack*tail
        samples.append(round(max(-0.8,min(0.8,value))*32767))
    if looping:
        # Overlap the tail with the head, then start after the consumed head.
        fade = round(rate*0.012)
        for j in range(fade):
            weight = j/(fade-1)
            at = count-fade+j
            samples[at] = round(samples[at]*(1-weight)+samples[j]*weight)
        samples = samples[fade:]
    if sys.byteorder != 'little': samples.byteswap()
    with wave.open(str(folder/(name+'.wav')), 'wb') as wav:
        wav.setparams((1,2,rate,0,'NONE','not compressed'))
        wav.writeframes(samples.tobytes())
print(f'Generated {len(specs)} original 44.1 kHz effects in {folder}')
