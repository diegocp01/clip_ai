"""Soften the original v3 export for a quiet, short UI cue (stdlib only)."""
import array
import math
from pathlib import Path
import wave

root = Path(__file__).resolve().parents[1]
source = root / "desktop/Resources/wake-chime-source.wav"
target = root / "desktop/Resources/wake-chime.wav"
with wave.open(str(source), "rb") as wav:
    assert wav.getsampwidth() == 2
    channels, rate = wav.getnchannels(), wav.getframerate()
    samples = array.array("h", wav.readframes(wav.getnframes()))

tracks = []
for channel in range(channels):
    values = [x / 32768 for x in samples[channel::channels]]
    frames = len(values)
    for i in range(frames):
        attack = min(1, i / (rate * 0.005))
        release = min(1, (frames - 1 - i) / (rate * 0.005))
        values[i] *= math.sin(attack * math.pi / 2)**2 * math.sin(release * math.pi / 2)**2
    tracks.append(values)

# Only attenuate: never amplify a quiet generation to hit a target.
peak = max(abs(x) for track in tracks for x in track)
gain = min(1, 0.16 / max(peak, 1e-9))
output = array.array("h", (round(tracks[c][i] * gain * 32767)
                          for i in range(frames) for c in range(channels)))
with wave.open(str(target), "wb") as wav:
    wav.setnchannels(channels)
    wav.setsampwidth(2)
    wav.setframerate(rate)
    wav.writeframes(output.tobytes())
print(f"Prepared {frames/rate:.4f}s cue; peak {peak*gain:.4f}, app gain 0.20")
