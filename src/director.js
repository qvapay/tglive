#!/usr/bin/env node
// Director de reels: cada REELS_EVERY segundos pone un video al azar de REELS_DIR
// a pantalla completa y luego vuelve a la página.
//
// Cómo: abre una segunda pestaña (un reproductor servido desde 127.0.0.1) y alterna
// la pestaña visible con CDP (bringToFront). Así no toca la página principal: le da
// igual su CSP, sus frames o su código. La página sigue viva por detrás gracias a
// --disable-background-timer-throttling y compañía (ver bin/run.sh).
//
// Los reels se ven SIN su audio: la música de music.sh sigue sonando por encima.
const { chromium } = require('playwright-core');
const http = require('http');
const fs = require('fs');
const path = require('path');

const CDP = `http://127.0.0.1:${process.env.CDP_PORT || 9222}`;
const DIR = process.env.REELS_DIR || '/srv/tgstream/reels';
const EVERY = num('REELS_EVERY', 600);        // segundos de página entre reels
const MAX = num('REELS_MAX', 60);             // duración máxima de un reel (s)
const FIRST = num('REELS_FIRST', EVERY);      // espera antes del primer reel (s)
const PORT = num('REELS_PORT', 8790);
const FADE = 600;                             // ms de fundido a negro
const EXT = /\.(mp4|m4v|webm|mov)$/i;

function num(k, d) { const v = Number(process.env[k]); return Number.isFinite(v) && v > 0 ? v : d; }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (...a) => console.error('reels:', ...a);

const PLAYER = `<!doctype html><meta charset="utf-8"><title>reels</title>
<style>html,body{margin:0;height:100%;background:#000;overflow:hidden}
video{width:100%;height:100%;object-fit:cover;opacity:0;transition:opacity ${FADE}ms}
video.on{opacity:1}</style>
<video id="v" muted playsinline preload="auto"></video>
<script>
const v = document.getElementById('v');
// Carga el video y espera a que pueda arrancar sin cortes.
window.loadReel = (src) => new Promise((ok, ko) => {
  v.classList.remove('on'); v.pause();
  v.onerror = () => ko(new Error('no pude cargar ' + src));
  v.oncanplaythrough = () => ok(v.duration || 0);
  v.src = src; v.load();
});
// Lo pone, espera a que termine (o a max segundos) y funde a negro.
window.playReel = (max) => new Promise((ok) => {
  let done = false;
  const end = () => { if (done) return; done = true; v.classList.remove('on');
    setTimeout(() => { v.pause(); ok(v.currentTime); }, ${FADE}); };
  v.onended = end; v.onerror = end; setTimeout(end, max * 1000);
  v.currentTime = 0; v.play().then(() => v.classList.add('on'), end);
});
</script>`;

// ---------- servidor local: el reproductor y los videos (con Range) ----------
function serve() {
  const srv = http.createServer((req, res) => {
    const url = decodeURIComponent(req.url.split('?')[0]);
    if (url === '/player') {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      return res.end(PLAYER);
    }
    const name = path.basename(url.replace(/^\/v\//, ''));
    const file = path.join(DIR, name);
    if (!url.startsWith('/v/') || !EXT.test(name) || !fs.existsSync(file)) {
      res.writeHead(404); return res.end();
    }
    const size = fs.statSync(file).size;
    const type = name.endsWith('.webm') ? 'video/webm' : 'video/mp4';
    const m = /bytes=(\d*)-(\d*)/.exec(req.headers.range || '');
    if (!m) {
      res.writeHead(200, { 'content-type': type, 'content-length': size, 'accept-ranges': 'bytes' });
      return fs.createReadStream(file).pipe(res);
    }
    const start = m[1] ? Number(m[1]) : size - Number(m[2]);
    const end = m[1] && m[2] ? Math.min(Number(m[2]), size - 1) : size - 1;
    res.writeHead(206, { 'content-type': type, 'content-length': end - start + 1,
      'content-range': `bytes ${start}-${end}/${size}`, 'accept-ranges': 'bytes' });
    fs.createReadStream(file, { start, end }).pipe(res);
  });
  return new Promise((ok, ko) => srv.once('error', ko).listen(PORT, '127.0.0.1', () => ok(srv)));
}

// La carpeta se relee en cada vuelta: puedes añadir o quitar reels en caliente.
function reels() {
  try { return fs.readdirSync(DIR).filter((f) => EXT.test(f) && !f.startsWith('.')); }
  catch { return []; }
}

let last = '';
function pick(list) {
  const pool = list.length > 1 ? list.filter((f) => f !== last) : list;
  last = pool[Math.floor(Math.random() * pool.length)];
  return last;
}

(async () => {
  await serve();
  const browser = await chromium.connectOverCDP(CDP);
  browser.on('disconnected', () => { log('Chrome se fue, salgo'); process.exit(1); });
  const ctx = browser.contexts()[0];
  const main = ctx.pages()[0];
  const player = await ctx.newPage();
  await player.goto(`http://127.0.0.1:${PORT}/player`);
  await main.bringToFront();
  log(`listo: ${DIR}, uno cada ${EVERY}s (máx ${MAX}s), primero en ${FIRST}s`);

  await sleep(FIRST * 1000);
  for (;;) {
    const list = reels();
    if (list.length) {
      const name = pick(list);
      try {
        const dur = await withTimeout(
          player.evaluate((src) => window.loadReel(src), `/v/${encodeURIComponent(name)}`), 20000);
        log(`▶ ${name} (${Math.round(Math.min(dur, MAX))}s)`);
        await player.bringToFront();
        await withTimeout(player.evaluate((m) => window.playReel(m), MAX), (MAX + 10) * 1000);
      } catch (e) {
        log(`error con ${name}: ${e.message}`);
      } finally {
        await main.bringToFront().catch(() => {});
      }
    }
    await sleep(EVERY * 1000);
  }
})().catch((e) => { log('fatal:', e.message); process.exit(1); });

function withTimeout(p, ms) {
  return Promise.race([p, sleep(ms).then(() => { throw new Error(`timeout ${ms}ms`); })]);
}
