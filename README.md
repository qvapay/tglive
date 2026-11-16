![tgLive: tu web, en vivo 24/7 en Telegram](assets/banner.jpg)

# tgLive

Transmite una **página web 24/7 como Telegram Live Story**, con música de fondo, desde un servidor Linux sin GPU y sin ningún teléfono encendido.

Es lo que mueve el live de tasas de [cambiocup.com](https://www.cambiocup.com) en el canal de QvaPay en Telegram: 1080x1920 a 60 fps, ~2 Mbps de subida, 5–6 núcleos de CPU.

<p align="center">
  <img src="assets/live-en-telegram.jpg" alt="El live de cambiocup.com visto en Telegram, con comentarios" width="400">
  &nbsp;
  <img src="assets/qvapay-chats.jpg" alt="El canal de QvaPay con el aro LIVE en la lista de chats" width="400">
</p>

```
Servidor Linux
├── tgstream.service
│   ├── Xvfb :99 ─ Google Chrome (kiosk, viewport móvil) ─ tu página
│   ├── music.sh ─ playlist aleatoria en loop ─┐
│   └── ffmpeg ─ captura pantalla + música ────┴─ RTMPS ─▶ Telegram Live Story
└── tgstream-keeper.service
    └── Telethon: cada 30 s, ¿hay live en el canal? si no, lo crea (stories.startLive) y reinicia tgstream
```

<p align="center"><img src="assets/numeros.jpg" alt="24/7, 60 fps, 0 teléfonos, 0 GPUs" width="320"></p>

## Por qué un keeper

![Antes: el teléfono se duerme y el live se cierra. Después: el servidor crea el live por la API](assets/antes-despues.jpg)

Si creas el live desde la app de Telegram, el live depende de que esa app siga viva: cuando el teléfono se duerme o el sistema mata Telegram, el live se cierra. Y el servidor RTMP de Telegram **sigue aceptando video aunque el live ya no exista**, así que ffmpeg no se entera.

El keeper usa la API con tu usuario (los bots no pueden crear Live Stories):

- `stories.startLive` con `rtmp_stream` crea el live.
- `phone.getGroupCallStreamRtmpUrl` con `live_story` da la URL y la key, **fijas por canal**.
- `stories.getPeerStories` le dice si sigue vivo: un live activo es una story con `messageMediaVideoStream`.

<p align="center"><img src="assets/keeper-ciclo.jpg" alt="Cada 30 segundos el keeper pregunta si hay live y, si no, lo crea" width="420"></p>

## Requisitos

- Ubuntu 24.04 o más nuevo. Sin GPU. Con 8 núcleos libres y 4 GB de RAM va sobrado.
- ~3 Mbps de subida.
- Una cuenta de Telegram admin del canal con permiso para publicar stories (o tu perfil: `TG_PEER=me`).
- `api_id` y `api_hash` de [my.telegram.org](https://my.telegram.org) → API development tools.
- Tu página. Funciona mejor si tiene un modo para el live (ver más abajo).

## Instalación

En el servidor:

```bash
git clone <URL de este repo> tgLive && cd tgLive
sudo bash scripts/install.sh
```

El instalador pone Xvfb, Chrome, ffmpeg, Node y Python, crea el usuario `tgstream` y los dos servicios. Es idempotente: nunca pisa tu config ni reinicia nada.

```bash
sudo nano /etc/tgstream/tgstream.env              # PAGE_URL
sudo nano /etc/tgstream/keeper.env                # TG_API_ID, TG_API_HASH, TG_PEER

sudo -u tgstream /opt/tgstream/bin/keeper login   # QR: Telegram → Ajustes → Dispositivos → Vincular dispositivo de escritorio
sudo -u tgstream /opt/tgstream/bin/keeper rtmp    # copia RTMP_URL / RTMP_KEY a tgstream.env

sudo systemctl enable --now tgstream tgstream-keeper
journalctl -u tgstream -u tgstream-keeper -f
```

En menos de un minuto el keeper crea el live y te avisa en tus **Mensajes guardados**.

### Probar sin salir al aire

```bash
sudo -u tgstream /opt/tgstream/bin/run.sh shot     # captura en /home/tgstream/test.png
sudo -u tgstream env DUR=30 /opt/tgstream/bin/run.sh rec   # 30 s de video en /home/tgstream/test.mp4

# Transmisión completa a un RTMP local (míralo en VLC: rtsp://IP_DEL_SERVIDOR:8554/test)
docker run --rm -it --network=host bluenviron/mediamtx
sudo -u tgstream env RTMP_URL=rtmp://127.0.0.1:1935/ RTMP_KEY=test /opt/tgstream/bin/run.sh live
```

`run.sh` usa la pantalla `:99` y el puerto `9222`: si el servicio está corriendo, páralo antes con `sudo systemctl stop tgstream`.

## Música

Todo lo que pongas en `/srv/tgstream/music` (MP3, M4A, WAV, FLAC, OGG, Opus) suena en orden aleatorio y en loop, con volumen normalizado y fades. La carpeta se relee en cada vuelta: puedes cambiarla con el live al aire.

```bash
TGSTREAM_HOST=usuario@servidor ./scripts/sync-music.sh     # sube ./music (o MUSIC_SRC)
```

Usa música con licencia comercial y sin atribución obligatoria, por ejemplo [Pixabay Music](https://pixabay.com/music/).

## La página

Chrome la abre con un viewport de **540x960** a escala 2 (= 1080x1920), con User-Agent de móvil y **sin GPU**. Lo que la hace ir a 60 fps y aguantar días:

- Nada interactivo: sin modales, avisos ni prompts.
- Efectos baratos: sin `backdrop-filter`, sin sombras grandes ni gradientes animados; animar solo `transform` y `opacity`.
- Tema forzado desde la página, sin depender de `prefers-color-scheme`.
- Datos que se actualizan solos sin recargar, y memoria estable.
- Zonas seguras: Telegram pinta el avatar arriba y los comentarios abajo. Deja libre el ~12 % superior y el ~25 % inferior.
- `window.__streamReady = true` cuando ya pintó los primeros datos. `run.sh` lo espera antes de empezar a capturar.

## Configuración

`/etc/tgstream/tgstream.env` (ver `.env.example`):

| Variable | Default | Qué es |
|---|---|---|
| `PAGE_URL` | — | Página a transmitir |
| `RTMP_URL`, `RTMP_KEY` | — | De `keeper rtmp` |
| `SCALE` | `2` | Escala del viewport. No uses 3: Chrome no baja de ~500 px de ancho de ventana |
| `FPS` | `60` | Bájalo a 30 si `speed` queda por debajo de 1x |
| `VIDEO_BITRATE` / `AUDIO_BITRATE` | `5000k` / `160k` | Siempre en `k` |
| `MUSIC_DIR` / `MUSIC_LUFS` | `/srv/tgstream/music` / `-16` | `-14` más alto, `-20` más bajo |
| `DISPLAY_NUM` / `CDP_PORT` | `99` / `9222` | Solo si corres más de un stream en el mismo servidor |

`/etc/tgstream/keeper.env` (ver `keeper/keeper.env.example`):

| Variable | Default | Qué es |
|---|---|---|
| `TG_API_ID`, `TG_API_HASH` | — | De my.telegram.org |
| `TG_PEER` | `me` | `@canal` o `me` |
| `TG_SESSION` | `/var/lib/tgstream-keeper/keeper` | Sesión de tu usuario. **Acceso total a la cuenta** |
| `CHECK_INTERVAL` | `30` | Segundos entre comprobaciones |
| `ROTATE_BEFORE_EXPIRE` | `120` | Segundos antes del `expire_date` del live para rotarlo (el live muere a las 4 h). `0` = solo recrear cuando muera |
| `STREAM_SERVICE` | `tgstream.service` | Lo que se reinicia tras crear un live |
| `NOTIFY` | `saved` | Avisos en Mensajes guardados, u `off` |

## Operación

| Para | Comando |
|---|---|
| ¿Todo corriendo? | `systemctl status tgstream tgstream-keeper --no-pager` |
| ¿Hay live ahora? | `sudo -u tgstream /opt/tgstream/bin/keeper status` |
| Logs | `journalctl -u tgstream -u tgstream-keeper -f` |
| Qué canción suena | `journalctl -u tgstream -o cat \| grep music: \| tail -3` |
| Progreso de ffmpeg | `journalctl -u tgstream --since "10 min ago" -a -o cat \| tr '\r' '\n' \| grep -o 'frame=.*' \| tail -1` |
| Rotar la key | `sudo -u tgstream /opt/tgstream/bin/keeper rtmp --revoke`, pégala en `tgstream.env` y reinicia `tgstream` |
| Actualizar | `git pull && sudo bash scripts/install.sh && sudo systemctl restart tgstream tgstream-keeper` |
| Desplegar desde tu computadora | `TGSTREAM_HOST=usuario@servidor ./scripts/deploy.sh` |

Con el live al aire, nunca reescribas un script de `/opt/tgstream` encima: bash lo va leyendo del disco mientras corre. Usa el instalador, que reemplaza los archivos.

## Lo que aprendimos a golpes

| Síntoma | Causa | Arreglo |
|---|---|---|
| El live desaparece de madrugada y ffmpeg sigue con `speed=1x` | El live dependía del teléfono que lo creó, y el ingest acepta video sin live | El keeper |
| Video a 20 fps al añadir música | ffmpeg frena la captura esperando el audio que llega a tiempo real (`-re`) | `music.sh` sin `-re` |
| Música lenta y desafinada | `aresample=async=1000` estira el audio | Sin `aresample`: los timestamps salen del conteo de muestras |
| Página a 8 fps | `backdrop-filter`, sombras, SwiftShader | Modo ligero en la página y `--disable-gpu` |
| Página cortada por la derecha | Ancho mínimo de ventana de Chrome | `SCALE=2` |
| Popup de Google Translate | Chrome en inglés, página en español | Política `TranslateEnabled: false` |
| `Owner of /tmp/.X11-unix should be set to root` | Xvfb corre sin root | `deploy/x11-unix.tmpfiles.conf` |
| `Input/output error` contra Telegram | Otra conexión usando la misma key | Una transmisión por key |
| `CAPTION_NOT_EMPTY` | Los Live Stories no aceptan texto | Sin caption |
| El live muere justo a las 4 h | Telegram lo cierra en el `expire_date` (inicio + 4 h) | `ROTATE_BEFORE_EXPIRE=120`: el keeper lo rota 2 min antes |
| El código de login no llega | Filtro antiabuso con apps de terceros | Login por QR |

## Licencia

MIT. Hecho por [QvaPay](https://qvapay.com).
