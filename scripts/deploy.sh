#!/usr/bin/env bash
# Desde tu computadora: sube el repo al servidor, instala y (si quieres) reinicia.
#   TGSTREAM_HOST=usuario@servidor ./scripts/deploy.sh
set -euo pipefail

HOST="${TGSTREAM_HOST:?Define TGSTREAM_HOST=usuario@servidor}"
REMOTE_DIR="${TGSTREAM_REMOTE_DIR:-tgLive}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> Subiendo a $HOST:~/$REMOTE_DIR"
rsync -av --delete \
  --exclude .git --exclude node_modules --exclude .venv --exclude .env --exclude .DS_Store \
  --exclude music --exclude reels --exclude '*.session' --exclude '*.mp4' --exclude '*.png' \
  "$ROOT/" "$HOST:$REMOTE_DIR/"

echo "==> Instalando"
ssh -t "$HOST" "sudo bash ~/$REMOTE_DIR/scripts/install.sh"

read -r -p "¿Reiniciar tgstream y el keeper ahora? Corta el live unos segundos [y/N] " ans
if [[ "${ans:-}" =~ ^[yYsS]$ ]]; then
  ssh -t "$HOST" "sudo systemctl restart tgstream tgstream-keeper && sleep 15 && \
    systemctl --no-pager status tgstream tgstream-keeper | grep -E '●|Active' && \
    journalctl -u tgstream -u tgstream-keeper -n 20 --no-pager -o cat | grep -v 'blob data'"
fi
