#!/bin/bash
# Synthesise the v7 soundtrack, master it to -14 LUFS (true peak -1.5 dBTP or lower), and lay it under the silent cut.
# Usage: ./build.sh [path/to/Hintlet-silent.mp4] [every-key]
# Writes the mix (.wav, .mp3), the music and SFX stems (-music.wav, -sfx.wav, which add up to the mix) and a .mid.
# With the silent cut it also writes the .mp4. every-key builds the take where each keystroke is a note.
set -euo pipefail
cd "$(dirname "$0")"
VIDEO=${1:-}
VARIANT=${2:-}
OUT=Hintlet-v7${VARIANT:+-$VARIANT}
python3 music-v7.py raw.wav $VARIANT
# one gain for the mix and both stems, so the stems still add up to the mix
GAIN=$(ffmpeg -hide_banner -i raw.wav -af loudnorm=I=-14:TP=-1.5:print_format=json -f null - 2>&1 | sed -n '/^{/,/^}/p' |
  python3 -c "import json,sys;d=json.load(sys.stdin);i,tp=float(d['input_i']),float(d['input_tp']);print(f'{min(-14-i,-1.5-tp):.2f}')")
for s in '' -music -sfx; do
  ffmpeg -v error -y -i raw$s.wav -af "volume=${GAIN}dB" -c:a pcm_s16le ${OUT}$s.wav
  rm raw$s.wav
done
mv raw.mid ${OUT}.mid
ffmpeg -v error -y -i ${OUT}.wav -c:a libmp3lame -b:a 256k ${OUT}.mp3
[ -n "$VIDEO" ] && ffmpeg -v error -y -i "$VIDEO" -i ${OUT}.wav -map 0:v -map 1:a -c:v copy -c:a aac -b:a 256k -shortest -movflags +faststart ${OUT}.mp4
echo "gain ${GAIN} dB"
