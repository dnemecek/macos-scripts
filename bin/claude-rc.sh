#!/bin/bash
#
# Soubor: claude-rc.sh
# Projekt: DN/macos-scripts
# Autor: David Nemecek
# Datum: 2026-10-09
# Popis: Claude Code Remote Control server ve screenu na pozadi. Server prezije
#        odhlaseni z SSH a sessions jdou zakladat a ovladat z mobilu nebo z claude.ai/code.
#
# Verze: 1.0.0
#
# Pouziti:  claude-rc.sh start  [DIR]   spusti server ve screenu (vychozi DIR ~/Documents/Source/Repos)
#           claude-rc.sh attach [DIR]   pripoji se ke screenu serveru (odpojeni: Ctrl-A D)
#           claude-rc.sh stop   [DIR]   ukonci server
#           claude-rc.sh status         bezici servery
#
# Nazev v seznamu sessions je "<pocitac> - <slozka>", nove sessions dostanou
# prefix "<pocitac>". Pocitac = LocalHostName, prepsatelny promennou CLAUDE_RC_HOST.
# Jeden screen na slozku (rc-<slozka>), druhy server ve stejne slozce se nespusti.
# Po restartu Macu je potreba server spustit znovu.
#
# Predpoklady: Claude Code prihlaseny uctem claude.ai (Pro/Max/Team/Enterprise),
#              ne API klicem; screen a perl (soucast macOS).
#

set -o pipefail

readonly DEFAULT_DIR="$HOME/Documents/Source/Repos"
# Nazev pocitace v seznamu sessions; prepsatelny promennou CLAUDE_RC_HOST (napr. Studio)
readonly HOST_NAME="${CLAUDE_RC_HOST:-$(scutil --get LocalHostName 2>/dev/null || hostname -s)}"

# Stary screen v macOS neumi dlouhe $TERM (napr. xterm-ghostty): "$TERM too long"
readonly SCREEN="env TERM=xterm-256color screen"

readonly RED='\033[1;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# Cil: Vypise chybu cervene na stderr.
error()   { echo -e "${RED}[ERROR] $1${NC}" >&2; }
# Cil: Vypise varovani zlute na stdout.
warn()    { echo -e "${YELLOW}[WARN] $1${NC}"; }
# Cil: Vypise uspech zelene na stdout.
success() { echo -e "${GREEN}[OK] $1${NC}"; }

# Cil: Vypise blok Pouziti z hlavicky a skonci s kodem 1.
usage() {
    sed -n '12,15p' "$0" | sed 's/^# //'
    exit 1
}

for cmd in claude screen scutil perl; do
    command -v "$cmd" >/dev/null || { error "Missing dependency: $cmd"; exit 1; }
done

# Cil: Nastavi DIR (absolutni cesta), BASE (nazev slozky) a SNAME (nazev screenu rc-<slozka>).
# Mantinely: Vstup je cesta ke slozce nebo prazdny (pak DEFAULT_DIR); neexistujici slozka ukonci skript.
#            Do SNAME jdou jen znaky A-Z a-z 0-9 . _ - (ostatni nahradi pomlcka).
# Kontrola: Navratovy kod 0 a nastavene DIR, BASE, SNAME; jinak exit 1 s chybou.
resolve() {
    local dir="${1:-$DEFAULT_DIR}"
    [[ -d "$dir" ]] || { error "Directory not found: $dir"; exit 1; }
    DIR="$(cd "$dir" && pwd)"
    BASE="$(basename "$DIR")"
    SNAME="rc-$(echo "$BASE" | sed 's/[^A-Za-z0-9._-]/-/g')"
}

# Cil: Vypise seznam screenu (screen -ls).
# screen -ls vraci nenulovy kod i kdyz screeny existuji -- s pipefail by roura
# hlasila neuspech, proto se vystup nejdriv ulozi a teprve pak vypise.
list_screens() {
    local out
    out=$($SCREEN -ls 2>/dev/null)
    echo "$out"
}

# Cil: Vrati 0, pokud bezi screen se jmenem SNAME, jinak 1.
is_running() {
    list_screens | grep -qE "[0-9]+\.${SNAME}[[:space:]]"
}

# Cil: Spusti claude remote-control v odpojenem screenu ve slozce DIR.
# Mantinely: Druhy server ve stejne slozce nespusti; bez prihlaseni claude.ai skonci chybou
#            pred spustenim screenu; nic nemaze a nemeni konfiguraci Claude Code.
# Kontrola: Po 3 s overi, ze screen SNAME bezi (is_running); jinak exit 1 s navodem na rucni spusteni.
cmd_start() {
    resolve "$1"
    if is_running; then
        error "Server for $DIR is already running (screen $SNAME). Attach: $0 attach \"$DIR\""
        exit 1
    fi
    # Bez platneho prihlaseni claude.ai vypise --help chybu misto napovedy (Remote Control
    # eligibility). --help po vypisu sam neskonci, proto casovy limit pres perl alarm
    # (macOS nema timeout) a rozhoduje text vystupu, ne navratovy kod.
    local help
    help=$(perl -e 'alarm 10; exec @ARGV' claude remote-control --help </dev/null 2>&1)
    if ! grep -q "USAGE" <<<"$help"; then
        error "Remote Control not available: Claude Code is not logged in with a claude.ai account."
        echo "  Run 'claude', type /login and choose a Claude subscription account (not Anthropic Console)." >&2
        exit 1
    fi
    cd "$DIR" || exit 1
    $SCREEN -dmS "$SNAME" claude remote-control \
        --name "${HOST_NAME} - ${BASE}" \
        --remote-control-session-name-prefix "$HOST_NAME"
    sleep 3
    if is_running; then
        success "Server running: '${HOST_NAME} - ${BASE}' (screen $SNAME, directory $DIR)"
        echo "  On first start in a directory Claude Code asks to trust it and to enable"
        echo "  Remote Control -- answer after: $0 attach \"$DIR\" (detach Ctrl-A D)."
    else
        error "Server did not start. Run manually to see the error: cd \"$DIR\" && claude remote-control"
        exit 1
    fi
}

# Cil: Pripoji terminal ke screenu serveru ve slozce DIR (nahradi proces skriptu).
# Mantinely: Server musi bezet; odpojeni Ctrl-A D server neukonci.
# Kontrola: Kdyz server nebezi, exit 1 s chybou; jinak exec screen -r.
cmd_attach() {
    resolve "$1"
    is_running || { error "Server for $DIR is not running. Start: $0 start \"$DIR\""; exit 1; }
    exec $SCREEN -r "$SNAME"
}

# Cil: Ukonci screen serveru ve slozce DIR.
# Mantinely: Ukonci jen screen SNAME, jine screeny ani procesy claude nemeni.
# Kontrola: Po 1 s overi, ze screen nebezi (is_running); jinak exit 1.
cmd_stop() {
    resolve "$1"
    is_running || { warn "Server for $DIR is not running."; exit 0; }
    $SCREEN -S "$SNAME" -X quit
    sleep 1
    if is_running; then
        error "Failed to quit screen $SNAME."
        exit 1
    fi
    success "Server for $DIR stopped."
}

# Cil: Vypise bezici screeny rc-* a procesy claude remote-control. Jen cte.
cmd_status() {
    local list
    list=$(list_screens | grep -E '\.rc-[^[:space:]]+' | sed 's/^[[:space:]]*//')
    if [[ -z "$list" ]]; then
        echo "No claude-rc server is running."
    else
        echo "Servers (screen):"
        echo "$list"
    fi
    echo "claude remote-control processes:"
    pgrep -fl "claude remote-control" || echo "  none"
}

case "${1:-}" in
    start)  cmd_start  "${2:-}" ;;
    attach) cmd_attach "${2:-}" ;;
    stop)   cmd_stop   "${2:-}" ;;
    status) cmd_status ;;
    *)      usage ;;
esac
