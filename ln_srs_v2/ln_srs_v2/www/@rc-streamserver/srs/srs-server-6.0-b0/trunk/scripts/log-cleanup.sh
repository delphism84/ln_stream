#!/usr/bin/env bash
# 로그 자동 정리 스크립트
# 디스크 공간 확보를 위해 오래된 로그 파일 및 임시 파일 삭제

set -euo pipefail

LOG_FILE="/var/log/srs-log-cleanup.log"
MAX_LOG_SIZE_MB=100
NGINX_ACCESS_MAX_MB=200
NGINX_ROTATED_MAX_MB=80
JOURNAL_VACUUM_SIZE_G=2
RETENTION_DAYS=7
MIN_FREE_MB=1024

# 로그 함수
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# 디스크 사용률 확인
check_disk_usage() {
    local usage=$(df -h / | tail -1 | awk '{print $5}' | sed 's/%//')
    echo "$usage"
}

# 디스크 여유공간(MB) 확인
check_free_mb() {
    # Available in KB
    df -Pk / | awk 'NR==2{printf "%.0f\n", $4/1024}'
}
# syslog 정리 (크기 제한)
cleanup_syslog() {
    local syslog_size=$(du -m /var/log/syslog 2>/dev/null | cut -f1)
    if [ -n "$syslog_size" ] && [ "$syslog_size" -gt "$MAX_LOG_SIZE_MB" ]; then
        log "syslog 크기 초과 ($syslog_size MB > $MAX_LOG_SIZE_MB MB), 정리 중..."
        sudo truncate -s 0 /var/log/syslog 2>/dev/null || true
        log "syslog 정리 완료"
    fi
}

# 오래된 로그 파일 삭제
cleanup_old_logs() {
    log "오래된 로그 파일 정리 중 (${RETENTION_DAYS}일 이상)..."
    local deleted=0
    
    # /var/log의 오래된 로그 파일
    deleted=$((deleted + $(find /var/log -name "*.log.*" -type f -mtime +${RETENTION_DAYS} -delete -print 2>/dev/null | wc -l)))
    deleted=$((deleted + $(find /var/log -name "*.gz" -type f -mtime +${RETENTION_DAYS} -delete -print 2>/dev/null | wc -l)))
    
    # rc-rtmp-monitor 로그 파일 (오래된 것만)
    deleted=$((deleted + $(find /var/log -name "rc-rtmp-monitor.log.*" -type f -mtime +${RETENTION_DAYS} -delete -print 2>/dev/null | wc -l)))
    
    log "오래된 로그 파일 $deleted 개 삭제 완료"
}

# journal 로그 정리
cleanup_journal() {
    log "journal 로그 정리 중..."
    journalctl --vacuum-time=${RETENTION_DAYS}d >/dev/null 2>&1 || true
    journalctl --vacuum-size=${JOURNAL_VACUUM_SIZE_G}G >/dev/null 2>&1 || true
    log "journal 로그 정리 완료"
}

# nginx 액세스 로그(증가율 큼): 로테이션된 비압축 파일 비우기, 활성 파일은 크기 초과 시 truncate + USR1
cleanup_nginx_logs() {
    local pidfile=/run/nginx.pid
    if [ ! -f "$pidfile" ]; then
        return 0
    fi
    local f sz
    while IFS= read -r -d '' f; do
        [ -f "$f" ] || continue
        sz=$(du -m "$f" 2>/dev/null | cut -f1)
        if [ -n "$sz" ] && [ "$sz" -gt "$NGINX_ROTATED_MAX_MB" ]; then
            log "nginx: truncating rotated $f (${sz}MB)"
            truncate -s 0 "$f" 2>/dev/null || true
        fi
    done < <(find /var/log/nginx -maxdepth 1 -type f -name 'access.log.*' ! -name '*.gz' -print0 2>/dev/null)

    if [ -f /var/log/nginx/access.log ]; then
        sz=$(du -m /var/log/nginx/access.log 2>/dev/null | cut -f1)
        if [ -n "$sz" ] && [ "$sz" -gt "$NGINX_ACCESS_MAX_MB" ]; then
            log "nginx: truncating active access.log (${sz}MB), reopen"
            truncate -s 0 /var/log/nginx/access.log 2>/dev/null || true
            kill -USR1 "$(cat "$pidfile")" 2>/dev/null || true
        fi
    fi
}

# 자체 로그 파일 상한
trim_self_log() {
    if [ -f "$LOG_FILE" ]; then
        local sz=$(du -m "$LOG_FILE" 2>/dev/null | cut -f1)
        if [ -n "$sz" ] && [ "$sz" -gt 20 ]; then
            tail -n 5000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
        fi
    fi
}

# HLS 오래된 세그먼트 파일 정리
cleanup_hls_segments() {
    log "HLS 오래된 세그먼트 파일 정리 중..."
    local hls_path="/var/www/static/live/hls"
    if [ -d "$hls_path" ]; then
        # 7일 이상 된 .ts 파일 삭제 (SRS의 hls_dispose가 180초이므로, 이건 백업용)
        local deleted=$(find "$hls_path" -name "*.ts" -type f -mtime +${RETENTION_DAYS} -delete -print 2>/dev/null | wc -l)
        log "HLS 세그먼트 파일 $deleted 개 삭제 완료"
    fi
    
    # hlsfix 폴더 정리 (비정상적으로 큰 파일 및 오래된 파일)
    local hlsfix_path="/var/www/static/live/hlsfix/live"
    if [ -d "$hlsfix_path" ]; then
        # 100MB 이상의 비정상적으로 큰 .ts 파일 삭제
        local large_deleted=$(find "$hlsfix_path" -name "*.ts" -type f -size +100M -delete -print 2>/dev/null | wc -l)
        if [ "$large_deleted" -gt 0 ]; then
            log "hlsfix 비정상 큰 파일 $large_deleted 개 삭제 완료"
        fi
        
        # 7일 이상 된 .ts 파일 삭제
        local old_deleted=$(find "$hlsfix_path" -name "*.ts" -type f -mtime +${RETENTION_DAYS} -delete -print 2>/dev/null | wc -l)
        if [ "$old_deleted" -gt 0 ]; then
            log "hlsfix 오래된 파일 $old_deleted 개 삭제 완료"
        fi
    fi
}

# 임시 파일 정리
cleanup_temp_files() {
    log "임시 파일 정리 중..."
    local deleted=0
    
    # /tmp의 오래된 파일 (7일 이상)
    deleted=$((deleted + $(find /tmp -type f -mtime +${RETENTION_DAYS} -delete -print 2>/dev/null | wc -l)))
    
    # /var/tmp의 오래된 파일
    deleted=$((deleted + $(find /var/tmp -type f -mtime +${RETENTION_DAYS} -delete -print 2>/dev/null | wc -l)))
    
    log "임시 파일 $deleted 개 삭제 완료"
}

# 메인 실행
main() {
    trim_self_log
    log "=== 로그 정리 시작 ==="
    
    local disk_usage=$(check_disk_usage)
    log "현재 디스크 사용률: ${disk_usage}%"
    local free_mb=$(check_free_mb)
    log "현재 디스크 여유공간: ${free_mb}MB"
    
    # 최우선: 여유공간 1GB 미만이면 공격적으로 정리
    if [ "$free_mb" -lt "$MIN_FREE_MB" ]; then
        log "경고: 디스크 여유공간이 ${MIN_FREE_MB}MB 미만입니다. 공격적 정리 모드 활성화"
        RETENTION_DAYS=1
    # 디스크 사용률이 90% 이상이면 더 공격적으로 정리
    elif [ "$disk_usage" -ge 90 ]; then
        log "경고: 디스크 사용률이 90% 이상입니다. 공격적 정리 모드 활성화"
        RETENTION_DAYS=3
    fi
    
    cleanup_syslog
    cleanup_nginx_logs
    cleanup_old_logs
    cleanup_journal
    cleanup_hls_segments
    cleanup_temp_files
    
    local final_usage=$(check_disk_usage)
    local freed_space=$(df -h / | tail -1 | awk '{print $4}')
    log "정리 완료 - 최종 디스크 사용률: ${final_usage}%, 사용 가능 공간: ${freed_space}"
    log "=== 로그 정리 종료 ==="
    echo ""
}

# 스크립트 직접 실행 시
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi

