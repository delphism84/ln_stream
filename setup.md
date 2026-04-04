# 신규 Ubuntu 서버 스트리밍 셋업 가이드 (SRS + Nginx)

본 문서는 신규 Ubuntu 서버에 라이브 스트리밍(홀덤)을 위한 **저지연 HLS(LL-HLS) + SRS + Nginx 서버 환경**을 구축하고 구성하는 최종 정리 가이드입니다. 
구형 `srs` 백업 파일 대신, 현재 서빙 중이며 최적화된 **`ln_srs_v2`** 설정을 기준으로 작성되었습니다.

---

## 1. 사전 준비
- **OS:** Ubuntu 22.04 / 24.04 LTS
- **도메인:** `game.kingofzeusfin.com`, `stream.kingofzeusfin.com` 등 A 레코드가 서버 IP로 매핑되어 있어야 함
- **필수 패키지 설치:**
  ```bash
  sudo apt update
  sudo apt install -y nginx certbot python3 python3-pip git build-essential unzip ffmpeg
  ```

## 2. Nginx & SSL (Certbot) 세팅
Nginx는 정적 파일 서빙과 HLS/WebSocket 프록시, CORS 처리를 전담합니다.

### 2.1. 인증서(SSL) 발급 준비
Nginx가 80번 포트로 ACME 챌린지를 받을 수 있도록 웹루트 디렉터리를 생성합니다.
```bash
sudo mkdir -p /var/www/certbot
sudo chown -R www-data:www-data /var/www/certbot
```
저장소의 `ln_srs_v2/nginx/sites-available/kingofzeusfin.com` 파일(80번 포트 설정만 활성화된 상태)을 Nginx에 올리고 재시작한 뒤, Certbot을 실행합니다.

```bash
# 인증서 발급 예시
sudo certbot certonly --webroot -w /var/www/certbot -d game.kingofzeusfin.com -d www.game.kingofzeusfin.com -d kingofzeusfin.com -d www.kingofzeusfin.com -d holdemlive.kingofzeusfin.com
sudo certbot certonly --webroot -w /var/www/certbot -d stream.kingofzeusfin.com
```

### 2.2. Nginx 최종 설정 적용
인증서가 발급되면 443 포트(HTTPS)가 포함된 Nginx 설정 파일로 교체합니다.
- **경로:** `/etc/nginx/sites-available/kingofzeusfin.com`
- **활성화:** `sudo ln -s /etc/nginx/sites-available/kingofzeusfin.com /etc/nginx/sites-enabled/`
- **핵심 Nginx 튜닝 포인트 (저지연 HLS용):**
  - **CORS 설정:** `Access-Control-Allow-Origin *` 등 스트림 요청을 프론트엔드에서 끌어가도록 허용.
  - **Gzip 해제:** HLS의 m3u8, ts 파일이나 관련 html 서빙 시 `gzip off;` 처리하여 플레이어가 응답을 디코딩할 때 발생하는 오버헤드와 혼동 방지.
  - **Range(206) 이슈 우회:** 일부 웹 플레이어가 HLS 세그먼트(`.ts`)나 플레이리스트(`.m3u8`)를 부분 요청(Range)했다가 끊기는 문제를 방지하기 위해, Nginx 블록에서 `max_ranges 0;`를 선언해 무조건 전체 파일(200 OK)로 응답하게 강제.
  - **Iframe 임베드 보안:** `Content-Security-Policy "frame-ancestors 'self' https://game.kingofzeusfin.com ..."` 헤더를 넣어 허용된 도메인에서만 `ll-player-embed.html`을 iframe으로 불러갈 수 있도록 보호.

## 3. SRS (Simple RTMP Server) 빌드 및 최적화
스트림 인제스트(RTMP)와 HLS 패킷타이징을 담당합니다.

### 3.1. SRS 빌드
```bash
cd /var/www
mkdir -p @rc-streamserver/srs
cd @rc-streamserver/srs
git clone -b 6.0 https://github.com/ossrs/srs.git srs-server-6.0-b0
cd srs-server-6.0-b0/trunk
./configure
make
```

### 3.2. 최적화된 설정(Config) 반영
저장소의 `ln_srs_v2/srs/conf/rc-srs.conf` 파일을 `/var/www/@rc-streamserver/srs/srs-server-6.0-b0/trunk/conf/rc-srs.conf`로 복사합니다.

**✅ [주요 최적화 세팅 복원]**
- `mw_latency 100;` : 머지(Merge) 쓰기 지연 시간을 줄여 스트림 송출 지연 최소화.
- `tcp_nodelay on;` : Nagle 알고리즘 비활성화로 실시간 패킷 전송.
- `queue_length 10;` : 송출 대기 큐를 짧게 가져가 밀림 방지.
- `gop_cache on;` : 접속 시 첫 키프레임을 즉시 보내 재생 시작(First Frame)을 빠르게.
- HLS 옵션:
  - `hls_fragment 1;` : HLS 청크 단위를 1초로 짧게 (저지연).
  - `hls_window 5;` : m3u8 플레이리스트가 유지하는 윈도우 크기를 5초로.
  - `hls_path /var/www/static/live/hls;` : Nginx가 바로 읽어갈 수 있도록 정적 폴더에 HLS 기록.

## 4. 프론트엔드 서빙 HTML 및 스크립트
저지연 플레이어 및 상태 확인용 HTML들은 `/var/www/static/live/hls/` 하위에 위치합니다.

- **`ll-player-embed.html`**: HLS.js 기반의 무조건 자동재생/저지연 프레임리스 플레이어. (tableId, camId 파라미터 수신하여 내부적으로 m3u8 매핑, 버퍼링 시 자동 3초 뒤 reload 기능 내장)
- **`ll-player-embed-sample.html`**: 위 임베드 플레이어의 동작을 테스트하고 프론트엔드용 삽입 코드를 생성하는 테스터 페이지.
- **`hls-verify-player.html`**: 방송 송출 상태 디버깅용 HLS.js 설정 검증기.
- 저장소의 `ln_srs_v2/www/static/live/hls/` 파일들을 통째로 복사해서 사용합니다.

## 5. Systemd 서비스 등록
서버 재부팅 시에도 스트림 서비스가 자동 실행되도록 데몬을 등록합니다.
저장소의 `ln_srs_v2/systemd/` 디렉터리에 있는 `.service` 및 `.timer` 파일들을 `/etc/systemd/system/`으로 복사합니다.

```bash
sudo cp /var/ln_stream/ln_srs_v2/systemd/*.service /etc/systemd/system/
sudo cp /var/ln_stream/ln_srs_v2/systemd/*.timer /etc/systemd/system/
sudo systemctl daemon-reload

# SRS 본체
sudo systemctl enable --now srs.service

# SRS HTTP Callback (On/Off 훅 처리)
sudo systemctl enable --now srs-hooks-http.service

# HLS 동기 시그널 (WebSocket)
sudo systemctl enable --now hls-sync-signal.service

# 로그 주기적 정리용
sudo systemctl enable --now srs-log-cleanup.timer
```

---
**[마무리 체크리스트]**
1. `systemctl status srs` 로 SRS 프로세스가 정상 구동 중인지 확인.
2. OBS 등에서 `rtmp://stream.kingofzeusfin.com/live/table11_01` 로 송출.
3. `https://stream.kingofzeusfin.com/ll-player-embed-sample.html` 접속 후 정상 재생 확인.