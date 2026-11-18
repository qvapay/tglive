#!/usr/bin/env bash
# Instala o actualiza tgLive en el servidor. Idempotente. Correr como root:
#   sudo bash scripts/install.sh
# Nunca pisa tu configuración y nunca reinicia ni habilita servicios.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Correr con sudo" >&2; exit 1; }

REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
PREFIX="/opt/tgstream"
ETC="/etc/tgstream"
MUSIC_DIR="/srv/tgstream/music"
REELS_DIR="/srv/tgstream/reels"
KEEPER_STATE="/var/lib/tgstream-keeper"
SVC_USER="tgstream"
OWNER="${SUDO_USER:-root}"   # dueño de la carpeta de música (quien sube con rsync)

say()  { echo -e "\033[1;32m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m!!\033[0m $*"; }

# 1. Paquetes
say "Paquetes"
pkgs=(xvfb ffmpeg fonts-liberation fonts-noto-color-emoji nodejs npm python3-venv rsync curl)
missing=()
for p in "${pkgs[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
if [ ${#missing[@]} -gt 0 ]; then
  apt-get update -qq && apt-get install -y "${missing[@]}"
fi
if ! command -v google-chrome >/dev/null; then
  say "Google Chrome"
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/chrome.deb" https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  apt-get install -y "$tmp/chrome.deb"
  rm -rf "$tmp"
fi

# 2. Usuario
id "$SVC_USER" >/dev/null 2>&1 || { say "Usuario $SVC_USER"; useradd -m -s /bin/bash "$SVC_USER"; }

# 3. Código → /opt/tgstream
#    rsync reemplaza los archivos en vez de reescribirlos: seguro aunque run.sh esté corriendo.
say "Código en $PREFIX"
mkdir -p "$PREFIX"
if [ "$REPO" != "$PREFIX" ]; then
  rsync -a --delete \
    --exclude .git --exclude node_modules --exclude .venv --exclude .env \
    --exclude .DS_Store --exclude music --exclude reels --exclude '*.session' \
    "$REPO/" "$PREFIX/"
fi
chown -R root:root "$PREFIX"
# Los archivos pueden venir con permisos 600/700: tgstream necesita leer y entrar
chmod -R u=rwX,go=rX "$PREFIX"
chmod 755 "$PREFIX"/bin/* "$PREFIX"/scripts/*.sh "$PREFIX"/src/*.js "$PREFIX"/keeper/keeper.py

say "Dependencias de Node"
(cd "$PREFIX" && npm install --omit=dev --no-audit --no-fund --loglevel=error)

say "Dependencias del keeper (Python)"
[ -x "$PREFIX/keeper/.venv/bin/python" ] || python3 -m venv "$PREFIX/keeper/.venv"
"$PREFIX/keeper/.venv/bin/pip" install -q --upgrade -r "$PREFIX/keeper/requirements.txt"

# 4. Política de Chrome + /tmp/.X11-unix
say "Política de Chrome y tmpfiles"
install -D -m 644 "$PREFIX/deploy/chrome-policy.json" /etc/opt/chrome/policies/managed/tgstream.json
install -m 644 "$PREFIX/deploy/x11-unix.tmpfiles.conf" /etc/tmpfiles.d/x11-unix.conf
systemd-tmpfiles --create /etc/tmpfiles.d/x11-unix.conf

# 5. Config (nunca se sobrescribe)
install -d -m 750 -o root -g "$SVC_USER" "$ETC"
new_env() {  # new_env <ejemplo> <destino>
  if [ ! -f "$2" ]; then
    cp "$1" "$2"; chown root:"$SVC_USER" "$2"; chmod 640 "$2"
    say "Creado $2"
  fi
}
new_env "$PREFIX/.env.example" "$ETC/tgstream.env"
new_env "$PREFIX/keeper/keeper.env.example" "$ETC/keeper.env"

# Migración desde una instalación manual vieja: traer la key
if [ -r "/home/$SVC_USER/tg.env" ] && ! grep -q '^RTMP_KEY="\?[^"]\+' "$ETC/tgstream.env"; then
  sed -i '/^RTMP_URL=/d; /^RTMP_KEY=/d' "$ETC/tgstream.env"
  grep '^RTMP_' "/home/$SVC_USER/tg.env" >> "$ETC/tgstream.env"
  say "RTMP_URL/RTMP_KEY copiados de /home/$SVC_USER/tg.env"
fi
grep -q '^PAGE_URL="\?[^"]\+' "$ETC/tgstream.env" || warn "Falta PAGE_URL en $ETC/tgstream.env"
grep -q '^RTMP_KEY="\?[^"]\+' "$ETC/tgstream.env" || warn "RTMP_KEY vacía en $ETC/tgstream.env (sácala con: sudo -u $SVC_USER $PREFIX/bin/keeper rtmp)"
grep -q '^TG_API_ID=[0-9]' "$ETC/keeper.env" || warn "Falta TG_API_ID / TG_API_HASH / TG_PEER en $ETC/keeper.env"

# 6. Carpetas de datos
[ -d "$MUSIC_DIR" ] || { say "Carpeta de música $MUSIC_DIR"; install -d -m 2775 -o "$OWNER" -g "$SVC_USER" "$MUSIC_DIR"; }
[ -d "$REELS_DIR" ] || { say "Carpeta de reels $REELS_DIR"; install -d -m 2775 -o "$OWNER" -g "$SVC_USER" "$REELS_DIR"; }
install -d -m 700 -o "$SVC_USER" -g "$SVC_USER" "$KEEPER_STATE"

# 7. El keeper puede reiniciar el stream (y nada más)
tmp=$(mktemp)
cp "$PREFIX/deploy/tgstream-keeper.sudoers" "$tmp"
if visudo -cf "$tmp" >/dev/null; then
  install -m 440 "$tmp" /etc/sudoers.d/tgstream-keeper
else
  warn "sudoers inválido, no lo instalé: el keeper no podrá reiniciar el stream"
fi
rm -f "$tmp"

# 8. systemd
for unit in tgstream.service tgstream-keeper.service; do
  dst="/etc/systemd/system/$unit"
  if [ -f "$dst" ] && ! cmp -s "$PREFIX/deploy/$unit" "$dst"; then
    cp "$dst" "$dst.bak-$(date +%Y%m%d-%H%M%S)"; say "Respaldo de $unit anterior"
  fi
  install -m 644 "$PREFIX/deploy/$unit" "$dst"
done
systemctl daemon-reload

say "Listo. No reinicié ni habilité nada."
cat <<EOT
    1. Config:       sudo nano $ETC/tgstream.env   y   sudo nano $ETC/keeper.env
    2. Login:        sudo -u $SVC_USER $PREFIX/bin/keeper login
    3. Key:          sudo -u $SVC_USER $PREFIX/bin/keeper rtmp   → pégala en tgstream.env
    4. Arrancar:     sudo systemctl enable --now tgstream tgstream-keeper
    5. Logs:         journalctl -u tgstream -u tgstream-keeper -f
EOT
