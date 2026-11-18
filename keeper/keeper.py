#!/usr/bin/env python3
"""
tgLive keeper: crea y mantiene vivo un Telegram Live Story (modo RTMP) por la API.

Uso:
  keeper login            login por QR (+ 2FA), guarda la sesión
  keeper status           ¿hay live activo en TG_PEER?
  keeper start            crea un live RTMP (si no hay uno)
  keeper end              termina el live activo
  keeper rtmp [--revoke]  imprime RTMP_URL / RTMP_KEY para tgstream.env
  keeper run              servicio: vigila y recrea el live (lo usa systemd)

Config por variables de entorno (ver keeper.env.example):
  TG_API_ID, TG_API_HASH   https://my.telegram.org → API development tools
  TG_PEER                  @canal o 'me'                       (default: me)
  TG_SESSION               archivo de sesión ¡acceso total a la cuenta!
  TG_PRIVACY               public | close_friends              (default: public)
  CHECK_INTERVAL           segundos entre comprobaciones       (default: 30)
  ROTATE_BEFORE_EXPIRE     segundos antes de expire_date para rotar el live; 0 = no rotar (default: 120)
  STREAM_SERVICE           unit de systemd a reiniciar tras crear un live (default: tgstream.service; vacío = no reiniciar)
  NOTIFY                   saved = avisar en Mensajes guardados | off   (default: saved)
"""
import asyncio
import datetime as dt
import getpass
import logging
import os
import random
import subprocess
import sys

from telethon import TelegramClient, errors, functions, types

log = logging.getLogger("keeper")


# ---------- config ----------

def env(name, default=None, required=False):
    v = os.environ.get(name, default)
    if required and not v:
        sys.exit(f"Falta la variable {name} (ver keeper.env)")
    return v


PEER = env("TG_PEER", "me")
PRIVACY = env("TG_PRIVACY", "public")
CHECK_INTERVAL = int(env("CHECK_INTERVAL", "30"))
ROTATE_BEFORE_EXPIRE = int(env("ROTATE_BEFORE_EXPIRE", "120"))
STREAM_SERVICE = env("STREAM_SERVICE", "tgstream.service")
NOTIFY = env("NOTIFY", "saved")
MAX_FAILS = int(env("MAX_FAILS", "10"))


def make_client():
    return TelegramClient(
        env("TG_SESSION", "keeper"),
        int(env("TG_API_ID", required=True)),
        env("TG_API_HASH", required=True),
    )


# ---------- API helpers ----------

def is_live(story):
    return isinstance(getattr(story, "media", None), types.MessageMediaVideoStream)


async def get_live(c, peer):
    """Devuelve el StoryItem del live activo, o None."""
    r = await c(functions.stories.GetPeerStoriesRequest(peer=peer))
    for s in r.stories.stories:
        if is_live(s):
            return s
    return None


def privacy_rules():
    if PRIVACY == "close_friends":
        return [types.InputPrivacyValueAllowCloseFriends()]
    return [types.InputPrivacyValueAllowAll()]


async def start_live(c, peer):
    """Crea el live. Devuelve True si lo creó, False si ya había uno."""
    try:
        await c(functions.stories.StartLiveRequest(
            peer=peer,
            privacy_rules=privacy_rules(),
            random_id=random.randint(1, 2**62),
            rtmp_stream=True,
            messages_enabled=True,
        ))
        return True
    except errors.RPCError as e:
        if "STORY_LIVE_ALREADY" in str(e):
            return False
        raise


async def end_live(c, story):
    await c(functions.phone.DiscardGroupCallRequest(call=story.media.call))


async def rtmp_creds(c, peer, revoke=False):
    r = await c(functions.phone.GetGroupCallStreamRtmpUrlRequest(
        peer=peer, revoke=revoke, live_story=True))
    return r.url, r.key


def restart_stream():
    if not STREAM_SERVICE:
        return
    cmd = ["sudo", "-n", "systemctl", "restart", STREAM_SERVICE]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode == 0:
        log.info("reiniciado %s", STREAM_SERVICE)
    else:
        log.error("no pude reiniciar %s: %s", STREAM_SERVICE, r.stderr.strip())


async def notify(c, text):
    log.info(text)
    if NOTIFY == "saved":
        try:
            await c.send_message("me", f"tgLive: {text}")
        except Exception as e:  # el aviso nunca debe tumbar al keeper
            log.warning("no pude avisar: %s", e)


# ---------- comandos ----------

async def cmd_login():
    import qrcode
    c = make_client()
    await c.connect()
    if await c.is_user_authorized():
        me = await c.get_me()
        print(f"Ya hay sesión: {me.first_name} id={me.id}")
        await c.disconnect()
        return
    qr = await c.qr_login()
    while True:
        q = qrcode.QRCode(border=2)
        q.add_data(qr.url)
        q.make()
        q.print_ascii(invert=True)
        print("Escanéalo: Telegram → Ajustes → Dispositivos → Vincular dispositivo de escritorio (60 s)")
        try:
            await qr.wait(timeout=60)
            break
        except asyncio.TimeoutError:
            print("Expiró, genero otro...\n")
            await qr.recreate()
        except errors.SessionPasswordNeededError:
            await c.sign_in(password=getpass.getpass("Contraseña 2FA: "))
            break
    me = await c.get_me()
    print(f"Sesión OK: {me.first_name} id={me.id}")
    await c.disconnect()


async def cmd_status():
    async with make_client() as c:
        peer = await c.get_input_entity(PEER)
        s = await get_live(c, peer)
        if not s:
            print("NO hay live activo")
            return
        left = s.expire_date - dt.datetime.now(dt.timezone.utc) if s.expire_date else None
        print(f"LIVE ACTIVO story={s.id} desde={s.date:%Y-%m-%d %H:%M} UTC "
              f"expira={s.expire_date:%H:%M} UTC (en {left})")


async def cmd_start():
    async with make_client() as c:
        peer = await c.get_input_entity(PEER)
        print("Live creado" if await start_live(c, peer) else "Ya había un live activo")


async def cmd_end():
    async with make_client() as c:
        peer = await c.get_input_entity(PEER)
        s = await get_live(c, peer)
        if not s:
            print("No hay live activo")
            return
        await end_live(c, s)
        print(f"Live {s.id} terminado")


async def cmd_rtmp(revoke):
    async with make_client() as c:
        peer = await c.get_input_entity(PEER)
        url, key = await rtmp_creds(c, peer, revoke)
        print(f'RTMP_URL="{url}"')
        print(f'RTMP_KEY="{key}"')
        if revoke:
            print("# key rotada: actualiza tgstream.env y reinicia tgstream")


async def cmd_run():
    c = make_client()
    await c.connect()
    if not await c.is_user_authorized():
        sys.exit("Sin sesión: corre 'keeper login' primero")
    peer = await c.get_input_entity(PEER)
    log.info("vigilando %s cada %ss (rotar %ss antes de expirar: %s)",
             PEER, CHECK_INTERVAL, ROTATE_BEFORE_EXPIRE, "sí" if ROTATE_BEFORE_EXPIRE else "no")
    last_error = None
    fails = 0
    while True:
        try:
            if not c.is_connected():
                # Telethon se rinde tras unos reintentos y deja el cliente muerto
                log.warning("desconectado de Telegram, reconectando")
                await c.connect()
            s = await get_live(c, peer)
            if not s:
                if await start_live(c, peer):
                    restart_stream()
                    await notify(c, "no había live, creé uno nuevo")
            elif ROTATE_BEFORE_EXPIRE and s.expire_date:
                left = (s.expire_date - dt.datetime.now(dt.timezone.utc)).total_seconds()
                if left <= ROTATE_BEFORE_EXPIRE:
                    await end_live(c, s)
                    await asyncio.sleep(3)
                    if await start_live(c, peer):
                        restart_stream()
                        await notify(c, f"live {s.id} rotado antes de expirar")
            last_error = None
            fails = 0
        except errors.FloodWaitError as e:
            log.warning("FLOOD_WAIT de %ss", e.seconds)
            await asyncio.sleep(e.seconds + 1)
        except (errors.AuthKeyUnregisteredError, errors.SessionRevokedError):
            log.error("la sesión ya no es válida: corre 'keeper login' de nuevo")
            sys.exit(1)
        except Exception as e:
            msg = f"error: {type(e).__name__}: {e}"
            log.error(msg)
            fails += 1
            if fails >= MAX_FAILS:
                # mejor morir y que systemd nos levante limpios que quedarnos en bucle
                log.error("%s errores seguidos, saliendo para que systemd reinicie", fails)
                sys.exit(1)
            if msg != last_error:  # avisar una vez por error distinto, no cada 30 s
                await notify(c, msg)
                last_error = msg
        await asyncio.sleep(CHECK_INTERVAL)


def main():
    logging.basicConfig(level=logging.INFO, format="keeper: %(message)s")
    args = sys.argv[1:]
    cmd = args[0] if args else ""
    run = {
        "login": cmd_login,
        "status": cmd_status,
        "start": cmd_start,
        "end": cmd_end,
        "rtmp": lambda: cmd_rtmp("--revoke" in args),
        "run": cmd_run,
    }.get(cmd)
    if not run:
        sys.exit(__doc__)
    asyncio.run(run())


if __name__ == "__main__":
    main()
