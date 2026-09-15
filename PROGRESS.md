# Progress Log & Next Steps

Working notes from building and testing `clean_audio.sh` against a real PS5
gameplay recording (`Black Myth: Wukong`, ~60 min, single mixed audio track).
Kept here so future work doesn't have to rediscover what was already tried.

## What works today

`clean_audio.sh` (see script for full usage/flags):

1. Probes the input; if mic and game audio are already on separate streams,
   just drops the mic stream via `-map` — no ML needed.
2. Otherwise extracts the mixed audio and runs it through **Demucs**
   (`htdemucs_ft`, `--shifts 2`, `--two-stems=vocals`) to split it into
   `vocals.wav` / `no_vocals.wav`.
3. Post-processes `no_vocals.wav` with `dynaudnorm` to fix uneven loudness.
4. Muxes the cleaned audio back with the original (untouched) video into a
   new `.mkv` file.

Verified end-to-end on the real 60-minute recording, on an Apple M4 (CPU
only). Full run (with `htdemucs_ft` + shifts) takes roughly 30–40 minutes.

## Problems hit along the way, and what fixed them

| Problem | Cause | Fix |
|---|---|---|
| `pip: command not found` | Script assumed `pip` on `PATH` | Fall back through `demucs` → `python3 -m demucs` → install via `python3 -m pip` / `pip3` |
| `ModuleNotFoundError: No module named 'numpy'` | `pip install demucs` didn't pull in numpy on this machine | Installed `numpy` explicitly |
| MP4 output was broken | Source is VP9 (`.webm`); MP4 doesn't reliably support VP9 via `-c:v copy` | Default output changed to `.mkv`, which accepts VP9 + AAC together |
| Cleaned audio sounded "numb" / muffled / bass-heavy | Default `htdemucs` two-stems model dulls high frequencies on non-music content | Switched to `htdemucs_ft` (fine-tuned model) + `--shifts 2` |
| Volume dropped to near-silence in some sections | In dialogue-heavy stretches, Demucs decided most of the segment *was* vocals and suppressed almost everything (measured -54 dB vs. original -24.6 dB in one 20s test window) | Rejected simple `loudnorm` (just amplifies noise) and blending back original audio (reintroduces too much voice, confirmed by ear); adaptive `dynaudnorm` on the isolated track alone gave the best result — brings up quiet stretches without amplifying pure noise and without reintroducing voice |
| Blending 15% of original audio back in to "fill gaps" | Made the plan look reasonable on paper (loudness matched original closely) | Rejected by ear test — voice came back "too much", confirmed blending is the wrong lever here |
| `dynaudnorm` result differs between a standalone clip test and the same window inside the full-length run | `dynaudnorm` is adaptive/windowed and reacts to surrounding audio context, so results on an isolated 20s test clip don't perfectly predict results in the full file | Documented as a known gap; only trust final-output spot checks, not standalone snippet tests, for tuning decisions |

## Open problem: game voiceover/dialogue also gets removed

Demucs's "vocals" model detects generic **speech-like audio**, not a
specific person. It can't distinguish "the streamer talking into their mic"
from "an NPC's voiceover line in a cutscene" — both look like "vocals" to
the model, so both get stripped. This is a structural limitation of blind
two-stems separation, not a tuning knob.

### What would actually solve it: target speaker extraction

Instead of "remove anything that sounds like a voice," the right tool is
"remove only *this* person's voice, leave everything else (including other
voices) alone." That needs:

1. A **reference sample** of just the streamer's voice — even ~15–30s with
   minimal game audio overlapping (a loading screen, pause menu, quiet
   moment) — to build a voice embedding/fingerprint.
2. A model conditioned on that embedding to suppress only matching audio
   (e.g. target-speaker-extraction approaches like SpeakerBeam, VoiceFilter,
   or speaker-embedding-conditioned separation networks — as opposed to
   Demucs's blind vocal/instrumental split).

**Caveat that won't go away even with this approach:** it should work well
when the streamer talks while the game is otherwise quiet, but when the
streamer's voice and an NPC's dialogue genuinely overlap in time and
frequency, separating two human voices from each other is a much harder,
largely unsolved problem — expect residual artifacts or bleed in those
specific overlapping moments even with better tooling.

### Next step (not yet started)

Needs a reference clip of the streamer talking with little/no other
dialogue in the background, to prototype a target-speaker-extraction
pipeline and see whether it preserves game voiceover meaningfully better
than the current blanket `--two-stems=vocals` approach.

## Ideas not yet tried

- Selective processing: only run suppression during time windows where the
  streamer's voice is actually detected (via VAD/diarization), and pass the
  original mixed audio through untouched elsewhere — limits collateral
  damage to game dialogue in the stretches where the streamer isn't talking
  at all.
- Tune `dynaudnorm` parameters further (shorter analysis window `f`,
  different `maxgain`) directly against full-length runs rather than short
  clips, now that we know standalone-clip tuning doesn't transfer perfectly.
- Prevent the problem at the source: PS5 Settings → Captures and
  Broadcasts → Captures → turn off "Include Mic Audio" before recording, so
  future captures don't need any of this.
