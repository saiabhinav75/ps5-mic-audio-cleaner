# audio-cleaning-ffmpeg

Suppress mic/voice audio from a PS5 gameplay recording whose game audio and
mic audio were captured as a single mixed track.

## Why

PS5 captures with **Settings → Captures and Broadcasts → Captures → Include
Mic Audio** enabled mix the streamer's mic into the same audio track as the
game audio — there's no separate mic stream to just drop. This project uses
[Demucs](https://github.com/facebookresearch/demucs) (ML source separation)
to split that mixed track into "vocals" vs. "everything else," then keeps
the game-audio half.

## Requirements

- `ffmpeg` / `ffprobe` on `PATH`
- `python3` (the script installs `demucs` via pip automatically if missing)

## Usage

```bash
./clean_audio.sh input.mp4 [output.mkv]
```

Output defaults to `<input>_clean.mkv`. `.mkv` is used because it accepts
any input video codec (H.264, VP9, etc.) via `-c:v copy` alongside AAC
audio — `.mp4` doesn't reliably support VP9.

### How it works

1. **Probe** the input's audio streams (`ffprobe`).
   - If mic and game audio are already on **separate streams**, just drop
     the mic stream with `-map` — cheap, lossless, no ML needed.
   - Otherwise, fall through to step 2.
2. **Extract** the single mixed audio track to WAV.
3. **Run Demucs** (`--two-stems=vocals`) to split it into `vocals.wav`
   (mic/voice) and `no_vocals.wav` (game audio).
4. **Post-filter** `no_vocals.wav` with `dynaudnorm` to fix uneven loudness
   introduced by separation, without reintroducing voice.
5. **Mux** the cleaned audio back with the original (untouched) video into
   the output file.

### Options (env vars)

| Var | Default | Description |
|---|---|---|
| `DEMUCS_MODEL` | `htdemucs_ft` | Demucs model. Use `htdemucs` for a much faster, slightly lower-quality pass. |
| `DEMUCS_SHIFTS` | `2` | Random-shift equivariant stabilization passes (higher = better separation, slower). `0` disables. |
| `POST_FILTER` | `dynaudnorm=f=200:g=15:maxgain=20` | `ffmpeg -af` filter chain applied to the isolated game-audio stem. Set to `""` to disable. |
| `KEEP_TMP` | `0` | Set to `1` to keep the extracted WAV and Demucs output directory after finishing. |
| `MIC_TRACK_INDEX` | `0` | When audio is already split into separate streams, the 0-based audio stream index to drop as the mic track. |

Example:

```bash
DEMUCS_MODEL=htdemucs DEMUCS_SHIFTS=0 ./clean_audio.sh recording.webm out.mkv
```

## Known limitations

- Demucs is trained mainly on music (vocals vs. instruments), so it treats
  **any speech-like audio as "vocals"** — it can't distinguish the
  streamer's mic from an NPC's in-game dialogue/voiceover. Both get
  stripped. This is a structural limitation of blind two-stems separation,
  not a tuning knob. See `PROGRESS.md` for a longer write-up and ideas for
  a target-speaker-extraction approach that could fix this.
- `dynaudnorm` results on a short standalone test clip don't perfectly
  predict results in the full-length run (it's adaptive/windowed and
  reacts to surrounding audio context) — only trust spot checks on the
  final output.
- A full 60-minute run with `htdemucs_ft` + `--shifts 2` takes roughly
  30–40 minutes on an Apple M4 (CPU only).

## Prevent the problem at the source

Turn off **Settings → Captures and Broadcasts → Captures → Include Mic
Audio** on the PS5 before recording, so future captures have mic and game
audio on separate tracks (or no mic track at all) and never need this
script's ML path.

## Project files

- `clean_audio.sh` — the script (see header comments for full docs)
- `task.md` — original task spec and manual command reference
- `PROGRESS.md` — detailed log of problems hit while building/tuning this
  against a real recording, and what fixed them
