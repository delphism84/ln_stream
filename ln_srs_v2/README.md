# ln_srs_v2

SRS·Nginx·HLS 플레이어·동기 시그널·systemd 유닛 등 운영 설정 스냅샷입니다.

## 레이아웃 (서버 배치 시 참고)

| 경로 (저장소) | 일반적인 서버 경로 |
|---------------|-------------------|
| `srs/conf/rc-srs.conf` | `/var/www/@rc-streamserver/srs/srs-server-6.0-b0/trunk/conf/rc-srs.conf` |
| `nginx/sites-available/kingofzeusfin.com` | `/etc/nginx/sites-available/kingofzeusfin.com` → `sites-enabled` |
| `www/static/live/hls/` | `/var/www/static/live/hls/` |
| `www/.../scripts/` | SRS 트렁크 `scripts/` (hooks, 로그 정리) |
| `systemd/*.service` | `/etc/systemd/system/` |

## 포함 내용

- **SRS**: `rc-srs.conf` (HLS 경로, RTC, 훅 등)
- **Nginx**: `stream.kingofzeusfin.com`용 HLS `/live`, `/llhls/live`, `/sync`, 플레이어 HTML alias
- **HTML**: `hlsplayer.html`, `player.html`, `status.html`, `thumb.html`, `overview.html`, `hls-verify-player.html`
- **동기 시그널**: `sync-signal/hls-sync-signal.js` (WebSocket + 합성 PDT)
- **스크립트**: `hooks_http.py`, `log-cleanup.sh`
- **systemd**: `srs`, `srs-hooks-http`, `hls-sync-signal`, `srs-log-cleanup` (+ timer)

SRS 바이너리(`objs/srs`)는 용량·빌드 환경 의존으로 포함하지 않습니다.
