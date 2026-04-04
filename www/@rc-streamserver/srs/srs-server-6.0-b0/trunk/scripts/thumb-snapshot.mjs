#!/usr/bin/env node
/**
 * Zenith Park - 스트림 썸네일 자동 생성 서비스
 * - SRS HTTP API로 퍼블리시 여부 확인
 * - RTMP 라이브 시: 10초마다 ffmpeg로 프레임 캡처 → live/thumb/{streamId}.jpg
 * - 미퍼블리시 시: 1분마다 폴백 갱신 (마지막 썸네일 유지 또는 재시도)
 *
 * 실행: node thumb-snapshot.mjs
 * 환경변수: SRS_API_URL, THUMB_OUT_DIR, STREAM_IDS, INTERVAL_LIVE_SEC, INTERVAL_FALLBACK_SEC
 */

import { spawn } from 'child_process';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const SRS_API_URL = process.env.SRS_API_URL || 'http://127.0.0.1:1985';
const THUMB_OUT_DIR = process.env.THUMB_OUT_DIR || '/var/www/static/live/thumb';
const RTMP_BASE = process.env.RTMP_BASE || 'rtmp://127.0.0.1:1935/live';
const HLS_BASE = process.env.HLS_BASE || 'https://stream.kingofzeusfin.com/live';
const CAPTURE_SOURCE = (process.env.CAPTURE_SOURCE || 'rtmp').toLowerCase();
const INTERVAL_LIVE_MS = Number(process.env.INTERVAL_LIVE_SEC || 10) * 1000;
const INTERVAL_FALLBACK_MS = Number(process.env.INTERVAL_FALLBACK_SEC || 60) * 1000;

/** table01_01 ~ table01_16 (쉼표로 오버라이드 가능) */
const DEFAULT_STREAM_IDS = Array.from({ length: 16 }, (_, i) =>
  `table01_${String(i + 1).padStart(2, '0')}`
);
const STREAM_IDS = process.env.STREAM_IDS
  ? process.env.STREAM_IDS.split(',').map((s) => s.trim()).filter(Boolean)
  : DEFAULT_STREAM_IDS;

/** SRS API에서 현재 퍼블리시 중인 스트림 이름 목록 조회 */
async function getLiveStreamNames() {
  try {
    const res = await fetch(`${SRS_API_URL}/api/v1/streams/?count=500`, {
      signal: AbortSignal.timeout(5000),
    });
    if (!res.ok) return new Set();
    const data = await res.json();
    if (data.code !== 0 || !Array.isArray(data.streams)) return new Set();
    const names = new Set(
      data.streams
        .filter((s) => s.publish && s.publish.active === true)
        .map((s) => s.name)
        .filter(Boolean)
    );
    return names;
  } catch (err) {
    console.warn('[thumb] SRS API error:', err.message);
    return new Set();
  }
}

const CAPTURE_TIMEOUT_MS = Number(process.env.CAPTURE_TIMEOUT_MS || 8000);

/** ffmpeg로 RTMP 한 프레임 캡처 → jpg 저장 (타임아웃 적용) */
function captureFrame(streamId, outPath) {
  return new Promise((resolve) => {
    const inputUrl = CAPTURE_SOURCE === 'hls'
      ? `${HLS_BASE}/${streamId}.m3u8`
      : `${RTMP_BASE}/${streamId}`;
    const tmpOutPath = `${outPath}.tmp`;
    const args = [
      '-y',
      '-loglevel', 'error',
      '-rw_timeout', String(CAPTURE_TIMEOUT_MS * 1000), // microseconds
      '-i', inputUrl,
      '-vframes', '1',
      '-f', 'image2',
      '-update', '1',
      tmpOutPath,
    ];
    const proc = spawn('ffmpeg', args, { stdio: ['ignore', 'pipe', 'pipe'] });
    let done = false;
    const finish = (ok) => {
      if (done) return;
      done = true;
      try { proc.kill('SIGKILL'); } catch (_) {}
      clearTimeout(timer);
      if (ok) {
        try {
          // atomic-ish replace so 기존 jpg(마지막 썸네일)를 최대한 유지
          fs.renameSync(tmpOutPath, outPath);
        } catch (_) {
          try { fs.unlinkSync(tmpOutPath); } catch (_) {}
          resolve(false);
          return;
        }
      } else {
        try { fs.unlinkSync(tmpOutPath); } catch (_) {}
      }
      resolve(ok);
    };
    const timer = setTimeout(() => finish(false), CAPTURE_TIMEOUT_MS);
    proc.stderr?.on('data', () => {});
    proc.on('close', (code) => finish(code === 0));
    proc.on('error', () => finish(false));
  });
}

function ensureDir(dir) {
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
}

const THUMB_LIST_PATH = path.join(THUMB_OUT_DIR, 'thumb-list.json');

function fileLooksLikeJpeg(p) {
  try {
    const st = fs.statSync(p);
    return st.isFile() && st.size > 1024; // 너무 작은 파일(에러/빈 파일) 제외
  } catch (_) {
    return false;
  }
}

function writeJsonAtomic(filePath, value) {
  const tmp = `${filePath}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(value), 'utf-8');
  fs.renameSync(tmp, filePath);
}

/**
 * thumb-list.json 갱신:
 * - 기본은 STREAM_IDS 순서대로, 실제 jpg가 존재하는 것만 리스트업
 * - STREAM_IDS에 아무것도 없으면(혹은 전부 없음) 디렉토리 내 *.jpg 중 최신 순으로 fallback
 */
function updateThumbList() {
  try {
    const existingInOrder = STREAM_IDS.filter((id) =>
      fileLooksLikeJpeg(path.join(THUMB_OUT_DIR, `${id}.jpg`))
    );

    const jpgs = fs.readdirSync(THUMB_OUT_DIR)
      .filter((f) => f.toLowerCase().endsWith('.jpg'))
      .map((f) => {
        const p = path.join(THUMB_OUT_DIR, f);
        let mtime = 0;
        try { mtime = fs.statSync(p).mtimeMs || 0; } catch (_) {}
        return { f, p, mtime };
      })
      .filter(({ p }) => fileLooksLikeJpeg(p))
      .sort((a, b) => b.mtime - a.mtime);

    // STREAM_IDS에 없는 jpg도(예: table01_03) 마지막 썸네일로 노출되도록 뒤에 붙인다.
    const extras = jpgs
      .map(({ f }) => f.replace(/\.jpg$/i, ''))
      .filter((id) => !existingInOrder.includes(id));

    let finalList = [...existingInOrder, ...extras];

    // 어떤 jpg도 없으면 빈 리스트
    if (finalList.length === 0) finalList = [];

    // 변경 없으면 불필요한 write 방지
    let prev = null;
    try {
      prev = JSON.parse(fs.readFileSync(THUMB_LIST_PATH, 'utf-8') || 'null');
    } catch (_) {
      prev = null;
    }
    if (Array.isArray(prev) && JSON.stringify(prev) === JSON.stringify(finalList)) {
      return;
    }
    writeJsonAtomic(THUMB_LIST_PATH, finalList);
  } catch (err) {
    console.warn('[thumb] updateThumbList error:', err?.message || String(err));
  }
}

/** 한 스트림에 대해 썸네일 생성 시도 */
async function tryCapture(streamId, outPath, isLive) {
  const ok = await captureFrame(streamId, outPath);
  if (ok) {
    console.log(`[thumb] ${streamId} ${isLive ? 'live' : 'fallback'} -> ${outPath}`);
  }
  return ok;
}

/** 메인 루프: 라이브는 10초마다, 비라이브는 60초마다 */
async function main() {
  ensureDir(THUMB_OUT_DIR);
  console.log(`[thumb] Thumb service started. OutDir=${THUMB_OUT_DIR} Streams=${STREAM_IDS.length}`);
  console.log(`[thumb] Live interval=${INTERVAL_LIVE_MS}ms Fallback=${INTERVAL_FALLBACK_MS}ms`);

  const lastCaptureMs = new Map(); // streamId -> last capture time
  updateThumbList();

  while (true) {
    const liveNames = await getLiveStreamNames();
    const now = Date.now();

    for (const streamId of STREAM_IDS) {
      const isLive = liveNames.has(streamId);
      const outPath = path.join(THUMB_OUT_DIR, `${streamId}.jpg`);
      const last = lastCaptureMs.get(streamId) ?? 0;
      const elapsed = now - last;

      if (isLive) {
        if (elapsed >= INTERVAL_LIVE_MS) {
          await tryCapture(streamId, outPath, true);
          lastCaptureMs.set(streamId, now);
        }
      } else {
        if (elapsed >= INTERVAL_FALLBACK_MS) {
          await tryCapture(streamId, outPath, false);
          lastCaptureMs.set(streamId, now);
        }
      }
    }

    // 라이브가 0개여도 마지막 썸네일이 보이도록, 현재 존재하는 jpg 목록을 계속 유지/갱신
    updateThumbList();
    await new Promise((r) => setTimeout(r, 2000)); // 2초마다 상태만 폴링, 실제 캡처는 위 간격으로
  }
}

main().catch((err) => {
  console.error('[thumb] Fatal:', err);
  process.exit(1);
});
