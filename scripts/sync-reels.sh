#!/usr/bin/env bash
# Desde tu computadora: prepara tus reels y los sube al servidor.
# El director toma los cambios solo, en el siguiente reel.
#   TGSTREAM_HOST=usuario@servidor ./scripts/sync-reels.sh            # sube lo nuevo
#   TGSTREAM_HOST=usuario@servidor ./scripts/sync-reels.sh --delete   # además borra allá lo que borraste aquí
#
# Cada video se normaliza una vez (1080x1920 recortado al centro, 30 fps, H.264, sin audio,
# faststart) y se guarda en $SRC/.tglive. Así Chrome nunca se encuentra un archivo raro y
# decodificarlo por CPU cuesta poco. Si no tienes ffmpeg, se suben tal cual.
set -euo pipefail

HOST="${TGSTREAM_HOST:?Define TGSTREAM_HOST=usuario@servidor}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${REELS_SRC:-$ROOT/reels}"
DEST="/srv/tgstream/reels"
OUT="$SRC/.tglive"

[ -d "$SRC" ] || { echo "No existe $SRC (crea la carpeta o define REELS_SRC)" >&2; exit 1; }

if command -v ffmpeg >/dev/null; then
  mkdir -p "$OUT"
  shopt -s nullglob nocaseglob
  for f in "$SRC"/*.{mp4,m4v,mov,webm}; do
    out="$OUT/$(basename "${f%.*}").mp4"
    [ "$out" -nt "$f" ] && continue
    echo "preparando $(basename "$f")"
    ffmpeg -nostdin -loglevel error -y -i "$f" -an \
      -vf "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,fps=30" \
      -c:v libx264 -preset medium -crf 21 -pix_fmt yuv420p -movflags +faststart "$out"
  done
  # quitar los preparados cuyo original ya no existe
  for out in "$OUT"/*.mp4; do
    b="$(basename "${out%.*}")"
    ls "$SRC/$b".* >/dev/null 2>&1 || rm -f "$out"
  done
  UP="$OUT"
else
  echo "AVISO: sin ffmpeg, subo los videos tal cual (mejor H.264 vertical 1080x1920)" >&2
  UP="$SRC"
fi

# El rsync de macOS (openrsync) no tiene --chmod: los permisos se arreglan por ssh.
rsync -av --progress --exclude .DS_Store --exclude .tglive "$@" "$UP/" "$HOST:$DEST/"
ssh "$HOST" "chmod 644 $DEST/* 2>/dev/null; ls $DEST | grep -ciE '\.(mp4|m4v|mov|webm)$' | xargs echo 'reels en el servidor:'"
