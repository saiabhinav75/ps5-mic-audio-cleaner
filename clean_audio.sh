#!/usr/bin/env bash
#
# clean_audio.sh — Suppress mic/voice audio from a PS5 gameplay recording
# whose game audio and mic audio were captured as a single mixed track.
#
# Strategy:
#   1. Probe the input to check whether audio is already split into
#      separate streams (mic vs game). If so, just drop the mic stream
#      with ffmpeg -map (cheap, lossless, no ML needed).
#   2. Otherwise, extract the mixed audio, run it through Demucs
#      (ML source separation, two-stems mode: vocals vs. everything else),
#      and mux the "no_vocals" stem back with the original video.
#
# Usage:
#   ./clean_audio.sh input.mp4 [output.mp4]
#
# Options (env vars):
#   DEMUCS_MODEL=htdemucs_ft     Demucs model to use (default: htdemucs_ft,
#                                 the fine-tuned/higher-quality variant).
#                                 Use "htdemucs" for a much faster, slightly
#                                 lower-quality pass.
#   DEMUCS_SHIFTS=2              Random-shift equivariant stabilization
#                                 passes (higher = better separation, slower).
#                                 Set to 0 to disable.
#   POST_FILTER=dynaudnorm=f=200:g=15:maxgain=20
#                                 ffmpeg -af filter chain applied to the
#                                 isolated game-audio stem after separation,
#                                 to fix quiet/uneven segments without
#                                 reintroducing bled-through voice (which a
#                                 flat volume boost or blend-back would do).
#                                 Set to empty ("") to disable.
#   KEEP_TMP=0                   Set to 1 to keep the extracted wav and
#                                 Demucs output directory after finishing.
#   MIC_TRACK_INDEX=0            When audio is already split into separate
#                                 streams, this is the 0-based audio stream
#                                 index (relative to other audio streams)
#                                 to DROP as the mic track. All other audio
#                                 streams are kept.
#
set -euo pipefail

DEMUCS_MODEL="${DEMUCS_MODEL:-htdemucs_ft}"
DEMUCS_SHIFTS="${DEMUCS_SHIFTS:-2}"
POST_FILTER="${POST_FILTER:-dynaudnorm=f=200:g=15:maxgain=20}"
KEEP_TMP="${KEEP_TMP:-0}"
MIC_TRACK_INDEX="${MIC_TRACK_INDEX:-0}"

usage() {
  echo "Usage: $0 input.mp4 [output.mkv]" >&2
  exit 1
}

[ $# -ge 1 ] || usage
INPUT="$1"
# Default output uses .mkv: it accepts any video codec via -c:v copy (H.264,
# VP9, etc.) alongside AAC audio, unlike .mp4 which chokes on VP9-in-MP4.
OUTPUT="${2:-${INPUT%.*}_clean.mkv}"

[ -f "$INPUT" ] || { echo "Error: input file not found: $INPUT" >&2; exit 1; }

command -v ffmpeg  >/dev/null 2>&1 || { echo "Error: ffmpeg not found in PATH."  >&2; exit 1; }
command -v ffprobe >/dev/null 2>&1 || { echo "Error: ffprobe not found in PATH." >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/clean_audio.XXXXXX")"
cleanup() {
  if [ "$KEEP_TMP" != "1" ]; then
    rm -rf "$WORKDIR"
  else
    echo "Kept temp dir: $WORKDIR"
  fi
}
trap cleanup EXIT

echo "== Step 1: Probing audio streams in '$INPUT' =="
STREAM_INFO="$(ffprobe -v error -select_streams a \
  -show_entries stream=index,codec_name,channels -of csv=p=0 "$INPUT")"

if [ -z "$STREAM_INFO" ]; then
  echo "Error: no audio streams found in '$INPUT'." >&2
  exit 1
fi

AUDIO_STREAM_COUNT="$(printf '%s\n' "$STREAM_INFO" | grep -c . || true)"
echo "Found $AUDIO_STREAM_COUNT audio stream(s):"
printf '%s\n' "$STREAM_INFO"

if [ "$AUDIO_STREAM_COUNT" -ge 2 ]; then
  echo
  echo "Audio is already split into separate streams — no ML separation needed."
  echo "Dropping audio stream index $MIC_TRACK_INDEX (assumed to be mic) and keeping the rest."

  MAPS=(-map 0:v)
  i=0
  while IFS= read -r line; do
    if [ "$i" -ne "$MIC_TRACK_INDEX" ]; then
      MAPS+=(-map "0:a:$i")
    fi
    i=$((i + 1))
  done <<< "$STREAM_INFO"

  ffmpeg -y -i "$INPUT" "${MAPS[@]}" -c copy "$OUTPUT"
  echo
  echo "Done. Wrote: $OUTPUT"
  exit 0
fi

echo
echo "Single combined audio track detected — falling back to ML source separation (Demucs)."

DEMUCS_CMD=()
if command -v demucs >/dev/null 2>&1; then
  DEMUCS_CMD=(demucs)
elif python3 -m demucs --help >/dev/null 2>&1; then
  DEMUCS_CMD=(python3 -m demucs)
else
  echo "Demucs not found; installing (python3 -m pip install demucs --break-system-packages)..."
  PIP_CMD=(python3 -m pip)
  python3 -m pip --version >/dev/null 2>&1 || PIP_CMD=(pip3)
  "${PIP_CMD[@]}" install demucs --break-system-packages
  if command -v demucs >/dev/null 2>&1; then
    DEMUCS_CMD=(demucs)
  else
    DEMUCS_CMD=(python3 -m demucs)
  fi
fi

AUDIO_WAV="$WORKDIR/audio.wav"
echo
echo "== Step 2: Extracting audio to WAV =="
ffmpeg -y -i "$INPUT" -vn -acodec pcm_s16le -ar 44100 -ac 2 "$AUDIO_WAV"

SHIFT_ARGS=()
[ "$DEMUCS_SHIFTS" != "0" ] && SHIFT_ARGS=(--shifts "$DEMUCS_SHIFTS")

echo
echo "== Step 3: Running Demucs (model=$DEMUCS_MODEL, shifts=$DEMUCS_SHIFTS, two-stems=vocals) =="
"${DEMUCS_CMD[@]}" --two-stems=vocals -n "$DEMUCS_MODEL" "${SHIFT_ARGS[@]}" -o "$WORKDIR/separated" "$AUDIO_WAV"

NO_VOCALS="$WORKDIR/separated/$DEMUCS_MODEL/audio/no_vocals.wav"
if [ ! -f "$NO_VOCALS" ]; then
  echo "Error: expected Demucs output not found at $NO_VOCALS" >&2
  exit 1
fi

FINAL_AUDIO="$NO_VOCALS"
if [ -n "$POST_FILTER" ]; then
  echo
  echo "== Step 3b: Post-processing isolated audio (-af $POST_FILTER) =="
  FINAL_AUDIO="$WORKDIR/final_audio.wav"
  ffmpeg -y -i "$NO_VOCALS" -af "$POST_FILTER" -ar 44100 "$FINAL_AUDIO"
fi

echo
echo "== Step 4: Muxing cleaned game audio back with original video =="
ffmpeg -y -i "$INPUT" -i "$FINAL_AUDIO" -map 0:v -map 1:a -c:v copy -c:a aac -shortest "$OUTPUT"

echo
echo "Done. Wrote: $OUTPUT"
echo "Note: Demucs is trained mainly on music; some voice bleed or artifacts may remain."
