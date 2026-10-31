# Clippy wake chime

Generated with ElevenLabs Sound Effects **v3** in the browser on 2026-10-30.
Selected output: **#2**, chosen by the user from the second generation below. Duration: **0.6 seconds**.
Loop off, prompt influence **30%**, automatic prompt improvement off.

`wake-chime-source.wav` preserves the original 48 kHz stereo, 16-bit export.
`scripts/prepare-wake-sound.py` creates `wake-chime.wav`: 5 ms endpoint fades and peak capped at 0.16
without amplification. App playback gain is 0.20 (peak at most -29.9 dBFS
before system volume). The first 0.8-second glassy version was rejected as
loud/noisy; it is not shipped.

Exact prompt:

> A very quiet, pure rounded sine-wave UI wake tone. One smooth gentle upward pitch glide, like a tiny soft electronic hum opening, then fading fully to silence. Warm, clean, intimate, minimal. Only one tonal layer. Absolutely no hiss, air, whoosh, sparkle, glass, distortion, buzz, clicks, percussion, speech, music or reverb. Soft slow attack, soft decay. 0.6 seconds.

Sound effect generated with ElevenLabs: https://elevenlabs.io

The selected tone retains its original timbre; no EQ or noise filtering is applied.
