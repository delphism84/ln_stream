#!/usr/bin/env node
/**
 * HLS 동기 시그널: m3u8 기준 합성 PDT + targetSn 브로드캐스트.
 */
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const ws = require('ws');

const HOST = process.env.HLS_SYNC_HOST || '127.0.0.1';
const PORT = parseInt(process.env.HLS_SYNC_PORT || '8090', 10);
const HLS_ROOT = process.env.HLS_SYNC_M3U8_ROOT || '/var/www/static/live/hls/live';
const TICK_MS = parseInt(process.env.HLS_SYNC_TICK_MS || '300', 10);

const STREAM_RE = /^[a-zA-Z0-9_.-]+$/;

/** @type {Map<string, Set<import('ws')>>} */
const rooms = new Map();
/** @type {Map<string, { syncSegs: number }>} */
const roomMeta = new Map();

function parseM3u8(text) {
  const lines = text.split(/\r?\n/);
  let mediaSequence = 0;
  const frags = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const mseq = line.match(/^#EXT-X-MEDIA-SEQUENCE:(\d+)/);
    if (mseq) {
      mediaSequence = parseInt(mseq[1], 10);
      continue;
    }
    const inf = line.match(/^#EXTINF:([\d.]+),/);
    if (inf) {
      const dur = parseFloat(inf[1]);
      const uri = (lines[i + 1] || '').trim();
      if (uri && !uri.startsWith('#')) {
        frags.push({ durSec: dur, uri });
      }
    }
  }
  if (!frags.length) return null;
  let sn = mediaSequence;
  for (const f of frags) {
    f.sn = sn++;
  }
  return { mediaSequence, fragments: frags };
}

function buildSyntheticPdt(fragments, serverNowMs) {
  const n = fragments.length;
  const out = [];
  let endMs = serverNowMs;
  for (let i = n - 1; i >= 0; i--) {
    const durMs = fragments[i].durSec * 1000;
    const startMs = endMs - durMs;
    out[i] = { startMs, endMs };
    endMs = startMs;
  }
  return out;
}

function tickStream(stream) {
  const safe = stream.replace(/[^a-zA-Z0-9_.-]/g, '');
  if (safe !== stream || !STREAM_RE.test(safe)) return null;
  const m3u8Path = path.join(HLS_ROOT, `${safe}.m3u8`);
  let text;
  try {
    text = fs.readFileSync(m3u8Path, 'utf8');
  } catch {
    return null;
  }
  const parsed = parseM3u8(text);
  if (!parsed) return null;
  const serverNowMs = Date.now();
  const pdt = buildSyntheticPdt(parsed.fragments, serverNowMs);
  const fr = parsed.fragments.map((f, i) => ({
    sn: f.sn,
    durSec: f.durSec,
    uri: f.uri,
    pdtStartMs: Math.round(pdt[i].startMs),
    pdtEndMs: Math.round(pdt[i].endMs),
  }));
  const lastSn = fr[fr.length - 1].sn;
  return {
    v: 1,
    op: 'tick',
    stream: safe,
    serverNowMs,
    mediaSequence: parsed.mediaSequence,
    fragments: fr,
    lastSn,
    syntheticPdt: true,
  };
}

function getSyncSegs(stream) {
  const m = roomMeta.get(stream);
  return m && m.syncSegs >= 1 && m.syncSegs <= 20 ? m.syncSegs : 1;
}

function enrichTick(base, stream) {
  const syncSegs = getSyncSegs(stream);
  const targetSn = Math.max(base.mediaSequence, base.lastSn - syncSegs);
  const targetFrag = base.fragments.find((f) => f.sn === targetSn);
  const playheadPdtMs = targetFrag ? Math.round((targetFrag.pdtStartMs + targetFrag.pdtEndMs) / 2) : null;
  return Object.assign({}, base, { targetSn, playheadPdtMs, syncSegs });
}

function broadcast(stream, payload) {
  const set = rooms.get(stream);
  if (!set || !payload) return;
  const data = JSON.stringify(payload);
  for (const client of set) {
    if (client.readyState === ws.OPEN) client.send(data);
  }
}

function tickAll() {
  for (const stream of rooms.keys()) {
    const base = tickStream(stream);
    if (!base) continue;
    broadcast(stream, enrichTick(base, stream));
  }
}

setInterval(tickAll, TICK_MS).unref();

const server = http.createServer((req, res) => {
  const u = (req.url || '').split('?')[0];
  if (u === '/health' || u === '/sync/health' || u === '/') {
    res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    res.end(JSON.stringify({ ok: true, service: 'hls-sync-signal', port: PORT }));
    return;
  }
  res.writeHead(404);
  res.end();
});

const wss = new ws.Server({ noServer: true });

wss.on('connection', (socket, req) => {
  let subscribed = null;

  socket.on('message', (raw) => {
    let msg;
    try {
      msg = JSON.parse(String(raw));
    } catch {
      return;
    }
    if (msg.op === 'sub' && typeof msg.stream === 'string') {
      const stream = msg.stream.replace(/\.m3u8$/i, '');
      if (!STREAM_RE.test(stream)) {
        socket.send(JSON.stringify({ op: 'err', error: 'invalid stream' }));
        return;
      }
      if (subscribed) {
        const prev = rooms.get(subscribed);
        if (prev) {
          prev.delete(socket);
          if (!prev.size) {
            rooms.delete(subscribed);
            roomMeta.delete(subscribed);
          }
        }
      }
      subscribed = stream;
      if (!rooms.has(stream)) rooms.set(stream, new Set());
      rooms.get(stream).add(socket);

      const ss = parseInt(msg.syncSegs, 10);
      if (!isNaN(ss) && ss >= 1 && ss <= 20) {
        roomMeta.set(stream, { syncSegs: ss });
      } else if (!roomMeta.has(stream)) {
        roomMeta.set(stream, { syncSegs: 1 });
      }

      const sg = getSyncSegs(stream);
      socket.send(JSON.stringify({ op: 'subscribed', stream, syncSegs: sg }));

      const base = tickStream(stream);
      if (base) socket.send(JSON.stringify(enrichTick(base, stream)));
    }
  });

  socket.on('close', () => {
    if (!subscribed) return;
    const set = rooms.get(subscribed);
    if (set) {
      set.delete(socket);
      if (!set.size) {
        rooms.delete(subscribed);
        roomMeta.delete(subscribed);
      }
    }
  });
});

server.on('upgrade', (request, socket, head) => {
  const p = (request.url || '').split('?')[0];
  if (p === '/sync/ws' || p === '/ws') {
    wss.handleUpgrade(request, socket, head, (client) => {
      wss.emit('connection', client, request);
    });
  } else {
    socket.destroy();
  }
});

server.listen(PORT, HOST, () => {
  console.log(`hls-sync-signal http+ws http://${HOST}:${PORT} path /sync/ws`);
});
