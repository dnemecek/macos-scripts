#!/bin/bash
# ============================================================================
# claude-rc.sh — Claude Code Remote Control server ve screenu na pozadí
# ============================================================================
# Použití:  claude-rc.sh start  [DIR]   spustí server ve screenu (výchozí DIR ~/Documents/Source/Repos)
#           claude-rc.sh attach [DIR]   připojí se ke screenu serveru (odpojení: Ctrl-A D)
#           claude-rc.sh stop   [DIR]   ukončí server
#           claude-rc.sh status         běžící servery
#
# Co dělá: spustí `claude remote-control` v odpojeném screenu, takže server
#          přežije odhlášení z SSH a sessions jdou zakládat a ovládat z mobilu
#          nebo z claude.ai/code. Název v seznamu sessions je
#          "<počítač> · <složka>", nové sessions dostanou prefix "<počítač>".
#          Jeden screen na složku (rc-<složka>), druhý server ve stejné složce
#          se nespustí. Po restartu Macu je potřeba server spustit znovu.
#
# Předpoklady: Claude Code přihlášený účtem claude.ai (Pro/Max/Team/Enterprise),
#              ne API klíčem; screen (součást macOS).
#
# David Němeček | 2026
# ============================================================================

set -o pipefail

DEFAULT_DIR="$HOME/Documents/Source/Repos"
# Název počítače v seznamu sessions; přepsatelný proměnnou CLAUDE_RC_HOST (např. Studio)
HOST_NAME="${CLAUDE_RC_HOST:-$(scutil --get LocalHostName 2>/dev/null || hostname -s)}"

# Starý screen v macOS neumí dlouhé $TERM (např. xterm-ghostty): "$TERM too long"
SCREEN="env TERM=xterm-256color screen"

RED='\033[1;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error()   { echo -e "${RED}[ERROR] $1${NC}" >&2; }
warn()    { echo -e "${YELLOW}[WARN] $1${NC}"; }
success() { echo -e "${GREEN}[OK] $1${NC}"; }

usage() {
    sed -n '4,7p' "$0" | sed 's/^# //'
    exit 1
}

for cmd in claude screen scutil; do
    command -v "$cmd" >/dev/null || { error "Chybí závislost: $cmd"; exit 1; }
done

# Absolutní cesta ke složce a název screenu z ní (jen bezpečné znaky)
resolve() {
    local dir="${1:-$DEFAULT_DIR}"
    [[ -d "$dir" ]] || { error "Složka neexistuje: $dir"; exit 1; }
    DIR="$(cd "$dir" && pwd)"
    BASE="$(basename "$DIR")"
    SNAME="rc-$(echo "$BASE" | sed 's/[^A-Za-z0-9._-]/-/g')"
}

# screen -ls vrací nenulový kód i když screeny existují -- s pipefail by roura
# hlásila neúspěch, proto se výstup nejdřív uloží a teprve pak prohledá
list_screens() {
    local out
    out=$($SCREEN -ls 2>/dev/null)
    echo "$out"
}

is_running() {
    list_screens | grep -qE "[0-9]+\.${SNAME}[[:space:]]"
}

cmd_start() {
    resolve "$1"
    if is_running; then
        error "Server pro $DIR už běží (screen $SNAME). Připojení: $0 attach \"$DIR\""
        exit 1
    fi
    # Bez platného přihlášení claude.ai vypíše --help chybu místo nápovědy (Remote Control
    # eligibility). --help po výpisu sám neskončí, proto časový limit přes perl alarm
    # (macOS nemá timeout) a rozhoduje text výstupu, ne návratový kód.
    local help
    help=$(perl -e 'alarm 10; exec @ARGV' claude remote-control --help </dev/null 2>&1)
    if ! grep -q "USAGE" <<<"$help"; then
        error "Remote Control není dostupný: Claude Code není přihlášený účtem claude.ai."
        echo "  Spusť 'claude', zadej /login a zvol účet Claude s předplatným (ne Anthropic Console)." >&2
        exit 1
    fi
    cd "$DIR" || exit 1
    $SCREEN -dmS "$SNAME" claude remote-control \
        --name "${HOST_NAME} · ${BASE}" \
        --remote-control-session-name-prefix "$HOST_NAME"
    sleep 3
    if is_running; then
        success "Server běží: '${HOST_NAME} · ${BASE}' (screen $SNAME, složka $DIR)"
        echo "  Při prvním spuštění ve složce se Claude Code ptá na důvěru adresáře a na zapnutí"
        echo "  Remote Control -- odpověz po: $0 attach \"$DIR\" (odpojení Ctrl-A D)."
    else
        error "Server se nespustil. Spusť ručně pro výpis chyby: cd \"$DIR\" && claude remote-control"
        exit 1
    fi
}

cmd_attach() {
    resolve "$1"
    is_running || { error "Server pro $DIR neběží. Spuštění: $0 start \"$DIR\""; exit 1; }
    exec $SCREEN -r "$SNAME"
}

cmd_stop() {
    resolve "$1"
    is_running || { warn "Server pro $DIR neběží."; exit 0; }
    $SCREEN -S "$SNAME" -X quit
    sleep 1
    if is_running; then
        error "Screen $SNAME se nepodařilo ukončit."
        exit 1
    fi
    success "Server pro $DIR ukončen."
}

cmd_status() {
    local list
    list=$(list_screens | grep -E '\.rc-[^[:space:]]+' | sed 's/^[[:space:]]*//')
    if [[ -z "$list" ]]; then
        echo "Žádný claude-rc server neběží."
    else
        echo "Servery (screen):"
        echo "$list"
    fi
    echo "Procesy claude remote-control:"
    pgrep -fl "claude remote-control" || echo "  žádné"
}

case "${1:-}" in
    start)  cmd_start  "${2:-}" ;;
    attach) cmd_attach "${2:-}" ;;
    stop)   cmd_stop   "${2:-}" ;;
    status) cmd_status ;;
    *)      usage ;;
esac
