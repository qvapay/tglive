#!/usr/bin/env bash
# tgstream: página web (Chrome en Xvfb) + música → ffmpeg → RTMP(S)
#
# Uso:  run.sh shot   → captura un PNG de la pantalla
#       run.sh rec    → graba DUR segundos (default 25) a MP4, con música
#       run.sh live   → transmite a RTMP_URL + RTMP_KEY
#
# Toda la config sale de variables de entorno y de $TGSTREAM_ENV
# (default /etc/tgstream/tgstream.env). Las del entorno ganan.
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
MODE="${1:-shot}"

# Carga la config sin pisar lo que ya venga en el entorno
# (así funciona igual bajo systemd, a mano, y con overrides tipo `env FPS=30 run.sh rec`).
ENV_FILE="${TGSTREAM_ENV:-/etc/tgstream/tgstream.env}"
if [ -r "$ENV_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    k="${line%%=*}"
    [ -n "${!k+x}" ] && continue
    eval "export $line"
  done < "$ENV_FILE"
fi

# --- Config (los defaults son los valores probados en producción) ---
: "${PAGE_URL:?falta PAGE_URL (ver $ENV_FILE)}"
SCALE="${SCALE:-2}"                 # NO usar 3: Chrome tiene ancho mínimo de ventana ~500 DIP
FPS="${FPS:-60}"
VIDEO_BITRATE="${VIDEO_BITRATE:-5000k}"
AUDIO_BITRATE="${AUDIO_BITRATE:-160k}"
DISPLAY_NUM="${DISPLAY_NUM:-99}"
CDP_PORT="${CDP_PORT:-9222}"
GPU_FLAGS="${GPU_FLAGS:---disable-gpu}"   # CPU raster: ~49 fps. SwiftShader daba 8–14
STATE="${STATE_DIRECTORY:-$HOME}"         # systemd: /var/lib/tgstream
RUNDIR="${RUNTIME_DIRECTORY:-$HOME}"      # systemd: /run/tgstream
CHROME_DATA_DIR="${CHROME_DATA_DIR:-$STATE/chrome}"
OUT_DIR="${OUT_DIR:-$STATE}"
FIFO="$RUNDIR/music.fifo"
UA="Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/157.0.0.0 Mobile Safari/537.36"

W=1080; H=1920
export DISPLAY=":$DISPLAY_NUM"
export CDP_PORT
WIN_W=$(awk -v w=$W -v s="$SCALE" 'BEGIN{printf "%d", w/s}')
WIN_H=$(awk -v h=$H -v s="$SCALE" 'BEGIN{printf "%d", h/s}')
GOP=$((FPS * 2))
BUFSIZE="$(( ${VIDEO_BITRATE%k} * 2 ))k"

log() { echo "tgstream: $*" >&2; }

case "$MODE" in shot|rec|live) ;; *) echo "Uso: $0 shot|rec|live" >&2; exit 2 ;; esac

# --- Limpieza: al salir por lo que sea, matar todo lo que arrancamos ---
XPID=""; CPID=""; MPID=""; DPID=""
cleanup() {
  # shellcheck disable=SC2086
  kill $DPID $MPID $CPID $XPID 2>/dev/null || true
  rm -f "$FIFO"
}
trap cleanup EXIT
trap 'exit 143' TERM INT

# --- Pantalla virtual ---
Xvfb "$DISPLAY" -screen 0 ${W}x${H}x24 -nolisten tcp &
XPID=$!
sleep 2
kill -0 "$XPID" 2>/dev/null || { log "ERROR: Xvfb no levantó ($DISPLAY ocupado? ¿corrida manual viva?)"; exit 1; }

# --- Chrome ---
mkdir -p "$CHROME_DATA_DIR"
# shellcheck disable=SC2086
google-chrome --kiosk --no-first-run --no-default-browser-check \
  $GPU_FLAGS --disable-infobars --noerrdialogs --hide-scrollbars \
  --disable-session-crashed-bubble --disable-renderer-backgrounding \
  --disable-background-timer-throttling --disable-backgrounding-occluded-windows \
  --force-device-scale-factor="$SCALE" \
  --window-size="${WIN_W},${WIN_H}" --window-position=0,0 \
  --user-agent="$UA" --touch-events=enabled \
  --autoplay-policy=no-user-gesture-required \
  --lang=es --disable-features=Translate,TranslateUI \
  --user-data-dir="$CHROME_DATA_DIR" --remote-debugging-port="$CDP_PORT" \
  "$PAGE_URL" >/dev/null 2>&1 &
CPID=$!
sleep 3
node "$ROOT/src/wait-ready.js" || log "WARN: la página no marcó __streamReady"

# Reels (opcional): si existe REELS_DIR, el director intercala videos cada REELS_EVERY s
start_reels() {
  [ -n "${REELS_DIR:-}" ] && [ -d "$REELS_DIR" ] || return 0
  export REELS_DIR REELS_EVERY REELS_MAX REELS_FIRST REELS_PORT
  node "$ROOT/src/director.js" &
  DPID=$!
}

# --- ffmpeg ---
VIN=(-thread_queue_size 1024 -f x11grab -draw_mouse 0 -video_size "${W}x${H}" -framerate "$FPS" -i "$DISPLAY")
AIN=(-thread_queue_size 1024 -f s16le -ar 44100 -ac 2 -i "$FIFO")
VENC=(-c:v libx264 -preset veryfast -b:v "$VIDEO_BITRATE" -maxrate "$VIDEO_BITRATE" -bufsize "$BUFSIZE"
      -pix_fmt yuv420p -g "$GOP")
# Audio sin reloj ni aresample: los timestamps salen del conteo de muestras (exacto).
# Requiere que music.sh NO use -re (ver comentario allí).
AENC=(-c:a aac -b:a "$AUDIO_BITRATE" -ar 44100)

start_music() {
  rm -f "$FIFO"; mkfifo "$FIFO"
  "$ROOT/bin/music.sh" > "$FIFO" &
  MPID=$!
}

case "$MODE" in
  shot)
    mkdir -p "$OUT_DIR"
    ffmpeg -y -loglevel error -f x11grab -draw_mouse 0 -video_size ${W}x${H} -i "$DISPLAY" \
      -frames:v 1 "$OUT_DIR/test.png"
    log "OK -> $OUT_DIR/test.png (viewport ${WIN_W}x${WIN_H})"
    ;;
  rec)
    mkdir -p "$OUT_DIR"
    start_music; start_reels
    ffmpeg -hide_banner -y "${VIN[@]}" "${AIN[@]}" "${VENC[@]}" "${AENC[@]}" \
      -t "${DUR:-25}" "$OUT_DIR/test.mp4"
    log "OK -> $OUT_DIR/test.mp4"
    ;;
  live)
    : "${RTMP_URL:?falta RTMP_URL (ver $ENV_FILE)}"
    : "${RTMP_KEY:?falta RTMP_KEY (ver $ENV_FILE)}"
    start_music; start_reels
    ffmpeg -hide_banner "${VIN[@]}" "${AIN[@]}" "${VENC[@]}" "${AENC[@]}" \
      -f flv "${RTMP_URL%/}/${RTMP_KEY}"
    ;;
esac
