# game.kingofzeusfin.com + kingofzeusfin.com + holdemlive.kingofzeusfin.com (DNS 설정 후 certbot으로 HTTPS 발급 → /etc/nginx/sites-available/fairshipstore-certbot-commands.txt 참고)
server {
    listen 80;
    listen [::]:80;
    server_name game.kingofzeusfin.com www.game.kingofzeusfin.com kingofzeusfin.com www.kingofzeusfin.com holdemlive.kingofzeusfin.com;

    root /var/zenithpark/fe/dist;
    index index.html;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        allow all;
    }

    location / {
        allow all;
        try_files $uri $uri/ /index.html;
    }
}

# stream.kingofzeusfin.com (DNS 설정 후 certbot으로 HTTPS 발급)
server {
    listen 80;
    listen [::]:80;
    server_name stream.kingofzeusfin.com;

    # 게임 페이지(다른 도메인)에서 플레이어 iframe 임베드 허용
    add_header Content-Security-Policy "frame-ancestors 'self' https://game.kingofzeusfin.com https://www.game.kingofzeusfin.com https://kingofzeusfin.com https://www.kingofzeusfin.com https://holdemlive.kingofzeusfin.com";
    send_timeout 120s;
    # HLS: 404 등에서 text/html이 gzip되면 플레이어/디버깅 혼동 방지
    gzip off;

    location = /live/thumb.html {
        allow all;
        alias /var/www/static/live/hls/thumb.html;
        add_header Access-Control-Allow-Origin *;
    }
    location = /live/overview.html {
        allow all;
        alias /var/www/static/live/hls/overview.html;
        add_header Access-Control-Allow-Origin *;
    }
    # 썸네일: 실제 존재하는 tableNN_01.jpg, tableNN_03.jpg 등만 그대로 서빙 (_04 등은 404 허용)
    location /live/thumb/ {
        allow all;
        alias /var/www/static/live/thumb/;
        add_header Cache-Control "public, max-age=5";
        add_header Access-Control-Allow-Origin *;
    }
    location = /live/player.html {
        allow all;
        alias /var/www/static/live/hls/player.html;
        add_header Access-Control-Allow-Origin *;
    }
    location = /live/status.html {
        allow all;
        alias /var/www/static/live/hls/status.html;
        add_header Access-Control-Allow-Origin *;
    }
    location = /status.html {
        allow all;
        alias /var/www/static/live/hls/status.html;
        add_header Access-Control-Allow-Origin *;
    }
    location = /hls-verify-player.html {
        allow all;
        alias /var/www/static/live/hls/hls-verify-player.html;
        add_header Access-Control-Allow-Origin *;
        default_type text/html;
    }
    location = /live/hlsplayer.html {
        allow all;
        alias /var/www/static/live/hls/hlsplayer.html;
        add_header Access-Control-Allow-Origin *;
        default_type text/html;
    }
    location = /llhls/hlsplayer.html {
        allow all;
        alias /var/www/static/live/hls/hlsplayer.html;
        add_header Access-Control-Allow-Origin *;
        default_type text/html;
    }
    # /llhls/live/ → 기본 HLS와 동일 TS·m3u8 (저지연 전용 URL; 플레이어가 profile=ll 로 사용)
    location ~ "^/llhls/live/([^/]+\.m3u8)$" {
        allow all;
        etag off;
        if_modified_since off;
        alias /var/www/static/live/hls/live/$1;
        default_type application/vnd.apple.mpegurl;
        add_header Cache-Control "no-cache, no-store, must-revalidate" always;
        add_header Access-Control-Allow-Origin * always;
        add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Range, Content-Type" always;
        add_header Access-Control-Expose-Headers "Content-Length, Content-Range, Accept-Ranges, Date" always;
        add_header Cross-Origin-Resource-Policy "cross-origin" always;
        max_ranges 0;
        if ($request_method = OPTIONS) {
            add_header Access-Control-Allow-Origin * always;
            add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS" always;
            add_header Access-Control-Allow-Headers "Range, Content-Type" always;
            add_header Access-Control-Max-Age 86400 always;
            add_header Content-Length 0;
            return 204;
        }
    }
    location ~ "^/llhls/live/([^/]+\.ts)$" {
        allow all;
        etag off;
        if_modified_since off;
        alias /var/www/static/live/hls/live/$1;
        default_type video/mp2t;
        add_header Cache-Control no-cache always;
        add_header Access-Control-Allow-Origin * always;
        add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Range, Content-Type" always;
        add_header Access-Control-Expose-Headers "Content-Length, Content-Range, Accept-Ranges, Date" always;
        add_header Cross-Origin-Resource-Policy "cross-origin" always;
        max_ranges 0;
        if ($request_method = OPTIONS) {
            add_header Access-Control-Allow-Origin * always;
            add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS" always;
            add_header Access-Control-Allow-Headers "Range, Content-Type" always;
            add_header Access-Control-Max-Age 86400 always;
            add_header Content-Length 0;
            return 204;
        }
    }
    location /llhls/live/ {
        allow all;
        alias /var/www/static/live/hls/live/;
        add_header Cache-Control no-cache always;
        add_header Access-Control-Allow-Origin * always;
        add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Range, Content-Type" always;
        add_header Access-Control-Expose-Headers "Content-Length, Content-Range, Accept-Ranges, Date" always;
        add_header Cross-Origin-Resource-Policy "cross-origin" always;
    }
    # HLS 동기 시그널(WebSocket + health)
    location /sync/ {
        proxy_pass http://127.0.0.1:8090;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 86400s;
    }
    # HLS playlist only: 일부 웹 플레이어가 m3u8 Range(206) 처리에 실패 → 전체 파일 200으로 제공
    location ~ "^/live/([^/]+\.m3u8)$" {
        allow all;
        etag off;
        if_modified_since off;
        alias /var/www/static/live/hls/live/$1;
        default_type application/vnd.apple.mpegurl;
        add_header Cache-Control "no-cache, no-store, must-revalidate" always;
        add_header Access-Control-Allow-Origin * always;
        add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Range, Content-Type" always;
        add_header Access-Control-Expose-Headers "Content-Length, Content-Range, Accept-Ranges, Date" always;
        add_header Cross-Origin-Resource-Policy "cross-origin" always;
        max_ranges 0;
        if ($request_method = OPTIONS) {
            add_header Access-Control-Allow-Origin * always;
            add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS" always;
            add_header Access-Control-Allow-Headers "Range, Content-Type" always;
            add_header Access-Control-Max-Age 86400 always;
            add_header Content-Length 0;
            return 204;
        }
    }
    # HLS 세그먼트: 일부 플레이어(m3u8-player.net)가 .ts를 Range(206)로만 받다 붙지 않음 → 전체 200
    location ~ "^/live/([^/]+\.ts)$" {
        allow all;
        etag off;
        if_modified_since off;
        alias /var/www/static/live/hls/live/$1;
        default_type video/mp2t;
        add_header Cache-Control no-cache always;
        add_header Access-Control-Allow-Origin * always;
        add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Range, Content-Type" always;
        add_header Access-Control-Expose-Headers "Content-Length, Content-Range, Accept-Ranges, Date" always;
        add_header Cross-Origin-Resource-Policy "cross-origin" always;
        max_ranges 0;
        if ($request_method = OPTIONS) {
            add_header Access-Control-Allow-Origin * always;
            add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS" always;
            add_header Access-Control-Allow-Headers "Range, Content-Type" always;
            add_header Access-Control-Max-Age 86400 always;
            add_header Content-Length 0;
            return 204;
        }
    }
    # HLS /live/ 기타 (위에서 매칭 안 된 경로)
    location /live/ {
        allow all;
        alias /var/www/static/live/hls/live/;
        add_header Cache-Control no-cache always;
        add_header Access-Control-Allow-Origin * always;
        add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Range, Content-Type" always;
        add_header Access-Control-Expose-Headers "Content-Length, Content-Range, Accept-Ranges, Date" always;
        add_header Cross-Origin-Resource-Policy "cross-origin" always;
    }
    location /live/hlsfix/ {
        allow all;
        alias /var/www/static/live/hlsfix/live/;
        add_header Cache-Control no-cache always;
        add_header Access-Control-Allow-Origin * always;
        add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Range, Content-Type" always;
        add_header Access-Control-Expose-Headers "Content-Length, Content-Range, Accept-Ranges, Date" always;
        add_header Cross-Origin-Resource-Policy "cross-origin" always;
    }

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        allow all;
    }

    location / {
        allow all;
        return 200 'OK';
        add_header Content-Type text/plain;
    }
}

# game.kingofzeusfin.com + kingofzeusfin.com + holdemlive.kingofzeusfin.com HTTPS
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name game.kingofzeusfin.com www.game.kingofzeusfin.com kingofzeusfin.com www.kingofzeusfin.com holdemlive.kingofzeusfin.com;

    ssl_certificate     /etc/letsencrypt/live/game.kingofzeusfin.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/game.kingofzeusfin.com/privkey.pem;
    include             /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

    root /var/zenithpark/fe/dist;
    index index.html;

    # ZenithPark 홀덤 BE (Node :3080) — WebSocket만 프록시 (기존 location / 는 유지)
    location /ws/holdem {
        proxy_pass http://127.0.0.1:3080/ws/holdem;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 86400s;
    }

    location / {
        allow all;
        try_files $uri $uri/ /index.html;
    }
}

# stream.kingofzeusfin.com HTTPS
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name stream.kingofzeusfin.com;

    ssl_certificate     /etc/letsencrypt/live/stream.kingofzeusfin.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/stream.kingofzeusfin.com/privkey.pem;
    include             /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

    # 게임 페이지(다른 도메인)에서 플레이어 iframe 임베드 허용
    add_header Content-Security-Policy "frame-ancestors 'self' https://game.kingofzeusfin.com https://www.game.kingofzeusfin.com https://kingofzeusfin.com https://www.kingofzeusfin.com https://holdemlive.kingofzeusfin.com";
    send_timeout 120s;
    # HLS: 404 등에서 text/html이 gzip되면 플레이어/디버깅 혼동 방지
    gzip off;

    location = /live/thumb.html {
        allow all;
        alias /var/www/static/live/hls/thumb.html;
        add_header Access-Control-Allow-Origin *;
    }
    location = /live/overview.html {
        allow all;
        alias /var/www/static/live/hls/overview.html;
        add_header Access-Control-Allow-Origin *;
    }
    # 썸네일: 실제 존재하는 tableNN_01.jpg, tableNN_03.jpg 등만 그대로 서빙 (_04 등은 404 허용)
    location /live/thumb/ {
        allow all;
        alias /var/www/static/live/thumb/;
        add_header Cache-Control "public, max-age=5";
        add_header Access-Control-Allow-Origin *;
    }
    location = /live/player.html {
        allow all;
        alias /var/www/static/live/hls/player.html;
        add_header Access-Control-Allow-Origin *;
    }
    location = /live/status.html {
        allow all;
        alias /var/www/static/live/hls/status.html;
        add_header Access-Control-Allow-Origin *;
    }
    location = /status.html {
        allow all;
        alias /var/www/static/live/hls/status.html;
        add_header Access-Control-Allow-Origin *;
    }
    location = /hls-verify-player.html {
        allow all;
        alias /var/www/static/live/hls/hls-verify-player.html;
        add_header Access-Control-Allow-Origin *;
        default_type text/html;
    }
    location = /live/hlsplayer.html {
        allow all;
        alias /var/www/static/live/hls/hlsplayer.html;
        add_header Access-Control-Allow-Origin *;
        default_type text/html;
    }
    location = /llhls/hlsplayer.html {
        allow all;
        alias /var/www/static/live/hls/hlsplayer.html;
        add_header Access-Control-Allow-Origin *;
        default_type text/html;
    }
    # /llhls/live/ → 기본 HLS와 동일 TS·m3u8 (저지연 전용 URL; 플레이어가 profile=ll 로 사용)
    location ~ "^/llhls/live/([^/]+\.m3u8)$" {
        allow all;
        etag off;
        if_modified_since off;
        alias /var/www/static/live/hls/live/$1;
        default_type application/vnd.apple.mpegurl;
        add_header Cache-Control "no-cache, no-store, must-revalidate" always;
        add_header Access-Control-Allow-Origin * always;
        add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Range, Content-Type" always;
        add_header Access-Control-Expose-Headers "Content-Length, Content-Range, Accept-Ranges, Date" always;
        add_header Cross-Origin-Resource-Policy "cross-origin" always;
        max_ranges 0;
        if ($request_method = OPTIONS) {
            add_header Access-Control-Allow-Origin * always;
            add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS" always;
            add_header Access-Control-Allow-Headers "Range, Content-Type" always;
            add_header Access-Control-Max-Age 86400 always;
            add_header Content-Length 0;
            return 204;
        }
    }
    location ~ "^/llhls/live/([^/]+\.ts)$" {
        allow all;
        etag off;
        if_modified_since off;
        alias /var/www/static/live/hls/live/$1;
        default_type video/mp2t;
        add_header Cache-Control no-cache always;
        add_header Access-Control-Allow-Origin * always;
        add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Range, Content-Type" always;
        add_header Access-Control-Expose-Headers "Content-Length, Content-Range, Accept-Ranges, Date" always;
        add_header Cross-Origin-Resource-Policy "cross-origin" always;
        max_ranges 0;
        if ($request_method = OPTIONS) {
            add_header Access-Control-Allow-Origin * always;
            add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS" always;
            add_header Access-Control-Allow-Headers "Range, Content-Type" always;
            add_header Access-Control-Max-Age 86400 always;
            add_header Content-Length 0;
            return 204;
        }
    }
    location /llhls/live/ {
        allow all;
        alias /var/www/static/live/hls/live/;
        add_header Cache-Control no-cache always;
        add_header Access-Control-Allow-Origin * always;
        add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Range, Content-Type" always;
        add_header Access-Control-Expose-Headers "Content-Length, Content-Range, Accept-Ranges, Date" always;
        add_header Cross-Origin-Resource-Policy "cross-origin" always;
    }
    # HLS 동기 시그널(WebSocket + health)
    location /sync/ {
        proxy_pass http://127.0.0.1:8090;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 86400s;
    }
    # HLS playlist only: 일부 웹 플레이어가 m3u8 Range(206) 처리에 실패 → 전체 파일 200으로 제공
    location ~ "^/live/([^/]+\.m3u8)$" {
        allow all;
        etag off;
        if_modified_since off;
        alias /var/www/static/live/hls/live/$1;
        default_type application/vnd.apple.mpegurl;
        add_header Cache-Control "no-cache, no-store, must-revalidate" always;
        add_header Access-Control-Allow-Origin * always;
        add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Range, Content-Type" always;
        add_header Access-Control-Expose-Headers "Content-Length, Content-Range, Accept-Ranges, Date" always;
        add_header Cross-Origin-Resource-Policy "cross-origin" always;
        max_ranges 0;
        if ($request_method = OPTIONS) {
            add_header Access-Control-Allow-Origin * always;
            add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS" always;
            add_header Access-Control-Allow-Headers "Range, Content-Type" always;
            add_header Access-Control-Max-Age 86400 always;
            add_header Content-Length 0;
            return 204;
        }
    }
    # HLS 세그먼트: 일부 플레이어(m3u8-player.net)가 .ts를 Range(206)로만 받다 붙지 않음 → 전체 200
    location ~ "^/live/([^/]+\.ts)$" {
        allow all;
        etag off;
        if_modified_since off;
        alias /var/www/static/live/hls/live/$1;
        default_type video/mp2t;
        add_header Cache-Control no-cache always;
        add_header Access-Control-Allow-Origin * always;
        add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Range, Content-Type" always;
        add_header Access-Control-Expose-Headers "Content-Length, Content-Range, Accept-Ranges, Date" always;
        add_header Cross-Origin-Resource-Policy "cross-origin" always;
        max_ranges 0;
        if ($request_method = OPTIONS) {
            add_header Access-Control-Allow-Origin * always;
            add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS" always;
            add_header Access-Control-Allow-Headers "Range, Content-Type" always;
            add_header Access-Control-Max-Age 86400 always;
            add_header Content-Length 0;
            return 204;
        }
    }
    location /live/ {
        allow all;
        alias /var/www/static/live/hls/live/;
        add_header Cache-Control no-cache always;
        add_header Access-Control-Allow-Origin * always;
        add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Range, Content-Type" always;
        add_header Access-Control-Expose-Headers "Content-Length, Content-Range, Accept-Ranges, Date" always;
        add_header Cross-Origin-Resource-Policy "cross-origin" always;
    }
    location /live/hlsfix/ {
        allow all;
        alias /var/www/static/live/hlsfix/live/;
        add_header Cache-Control no-cache always;
        add_header Access-Control-Allow-Origin * always;
        add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Range, Content-Type" always;
        add_header Access-Control-Expose-Headers "Content-Length, Content-Range, Accept-Ranges, Date" always;
        add_header Cross-Origin-Resource-Policy "cross-origin" always;
    }
    location / {
        allow all;
        return 200 'OK';
        add_header Content-Type text/plain;
    }
}
