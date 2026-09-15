# Task: Remove/Reduce Mic Audio from PS5 Gameplay Recording

## Context
A PS5 gameplay recording has microphone audio and game audio mixed into a **single combined audio track** (not separate tracks). The goal is to suppress the mic/voice audio as much as possible while preserving the game audio, using ML-based source separation rather than simple filters, since the audio is already pre-mixed.

## Input
A video file (e.g. `input.mp4`) with one combined audio track containing both game sound and mic/voice.

## Goal
Produce an output video with the mic voice suppressed as much as possible while preserving game audio, using Demucs (ML source separation) plus ffmpeg for muxing.

## Plan / Commands

### 1. Check the input's audio streams first
Confirm it's really one mixed track, not separate ones. If separate tracks exist, this becomes trivial with `-map` instead of source separation.
```bash
ffprobe -v error -show_entries stream=index,codec_type,codec_name -of default=noprint_wrappers=1 input.mp4
```

### 2. Extract the audio track to a standalone WAV
```bash
ffmpeg -i input.mp4 -vn -acodec pcm_s16le -ar 44100 -ac 2 audio.wav
```

### 3. Install Demucs (ML source separation model)
```bash
pip install demucs --break-system-packages
```

### 4. Run Demucs with two-stems mode to split vocals vs. everything else
```bash
demucs --two-stems=vocals audio.wav
```
Outputs (under `separated/htdemucs/audio/`):
- `vocals.wav` — isolated voice/mic
- `no_vocals.wav` — game audio with voice removed

### 5. Mux the cleaned game audio back with the original video
```bash
ffmpeg -i input.mp4 -i separated/htdemucs/audio/no_vocals.wav -map 0:v -map 1:a -c:v copy -c:a aac -shortest output.mp4
```

### 6. Verify output
Play `output.mp4` and listen. Demucs isn't perfect on non-music mixed audio (it's trained mostly on music stems), so some artifacts or residual bleed may remain. If quality is poor, try the `htdemucs_ft` model variant (`-n htdemucs_ft`) — slower but sometimes cleaner:
```bash
demucs --two-stems=vocals -n htdemucs_ft audio.wav
```

## Known Limitations
- Demucs is optimized for music (vocals vs. instruments), so console game audio + voice may separate less cleanly than a song would.
- If results are unusable, fallback is manual EQ/noise-gate in an editor (e.g. DaVinci Resolve Fairlight page), accepting partial bleed reduction rather than full removal.

## Prior Context
- Original recording came from a PS5 capture with "Include Mic Audio" enabled in Settings → Captures and Broadcasts → Captures.
- To prevent this issue in future recordings, that toggle can be turned off before recording.
- If mic and game audio are on **separate tracks** in a given file, no ML separation is needed — just drop the mic track directly:
```bash
ffmpeg -i input.mp4 -map 0:v -map 0:a:0 -c copy output.mp4
```