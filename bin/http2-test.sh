#!/bin/bash
# HTTP/2 Diagnostic Test
# Usage: ./http2-test.sh "nazev lokality"
# Author: David Nemecek | Feb 2026

# Volitelny vlastni cil testu (napr. vlastni router/server):
#   http2-test.sh https://example.com:8443/
# Bez parametru se testuji jen verejne weby - skript zamerne neobsahuje
# zadnou konkretni adresu infrastruktury.
TARGET="${1:-}"
TARGET_HOST="$(printf '%s' "$TARGET" | sed -E 's#^[a-z]+://##; s#[:/].*$##')"

LOCATION=${1:-"Unknown"}
LOGDIR="$HOME/http2-logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/http2-test-$(date +%Y%m%d-%H%M%S).log"

log() {
    echo "$1" | tee -a "$LOGFILE"
}

timer_start() {
    TIMER_START=$(python3 -c 'import time; print(time.time())' 2>/dev/null || date +%s)
}

timer_end() {
    TIMER_END=$(python3 -c 'import time; print(time.time())' 2>/dev/null || date +%s)
    ELAPSED=$(python3 -c "print(f'{$TIMER_END - $TIMER_START:.3f}')" 2>/dev/null || echo "N/A")
    log "  [Section: ${ELAPSED}s]"
    log ""
}

log "=== HTTP/2 Diagnostic Test ==="
log "Location: $LOCATION"
log "Date: $(date)"
log "Log: $LOGFILE"
log ""

log "--- Public IP ---"
timer_start
PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me)
log "IP: $PUBLIC_IP"
timer_end

log "--- First Hop Latency ---"
timer_start
GATEWAY=$(netstat -rn 2>/dev/null | grep -E '^default|^0.0.0.0' | awk '{print $2}' | head -1)
if [ -z "$GATEWAY" ]; then
    GATEWAY=$(route -n get default 2>/dev/null | grep gateway | awk '{print $2}')
fi
if [ -n "$GATEWAY" ]; then
    log "Gateway: $GATEWAY"
    ping -c 3 "$GATEWAY" 2>&1 | tee -a "$LOGFILE"
else
    log "Gateway: not detected"
fi
timer_end

log "--- HTTP/2 Tests ---"
timer_start
curl -k --http2 -w "Cloudflare:  DNS %{time_namelookup}s | Conn %{time_connect}s | TLS %{time_appconnect}s | Total %{time_total}s\n" -o /dev/null -s "https://cloudflare.com/" | tee -a "$LOGFILE"
curl -k --http2 -w "Google:      DNS %{time_namelookup}s | Conn %{time_connect}s | TLS %{time_appconnect}s | Total %{time_total}s\n" -o /dev/null -s "https://google.com/" | tee -a "$LOGFILE"
curl -k --http2 -w "Seznam:      DNS %{time_namelookup}s | Conn %{time_connect}s | TLS %{time_appconnect}s | Total %{time_total}s\n" -o /dev/null -s "https://www.seznam.cz/" | tee -a "$LOGFILE"
curl -k --http2 -w "iDNES:       DNS %{time_namelookup}s | Conn %{time_connect}s | TLS %{time_appconnect}s | Total %{time_total}s\n" -o /dev/null -s "https://www.idnes.cz/" | tee -a "$LOGFILE"
if [ -n "$TARGET" ]; then
  curl -k --http2 -w "target:      DNS %{time_namelookup}s | Conn %{time_connect}s | TLS %{time_appconnect}s | Total %{time_total}s\n" -o /dev/null -s "$TARGET" | tee -a "$LOGFILE"
fi
timer_end

log "--- HTTP/1.1 Baseline ---"
timer_start
if [ -n "$TARGET" ]; then
  curl -k --http1.1 -w "target:      DNS %{time_namelookup}s | Conn %{time_connect}s | TLS %{time_appconnect}s | Total %{time_total}s\n" -o /dev/null -s "$TARGET" | tee -a "$LOGFILE"
fi
timer_end

log "--- Traceroute (15 hops) ---"
timer_start
if [ -n "$TARGET_HOST" ]; then
  traceroute -m 15 "$TARGET_HOST" 2>/dev/null | tee -a "$LOGFILE" || log "traceroute not available"
else
  log "(preskoceno - zadny vlastni cil)"
fi
timer_end

log "=== Test Complete ==="
log "Log saved: $LOGFILE"