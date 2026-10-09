#!/bin/bash
#
# Soubor: claude-rc.sh
# Projekt: DN/macos-scripts
# Autor: David Nemecek
# Datum: 2026-10-09
# Popis: Claude Code Remote Control server ve screenu na pozadi. Server prezije
#        odhlaseni z SSH a sessions jdou zakladat a ovladat z mobilu nebo z claude.ai/code.
#
# Verze: 1.1.0
#
# Pouziti:  claude-rc.sh start     [DIR]   spusti server ve screenu (vychozi DIR ~/Documents/Source/Repos)
#           claude-rc.sh attach    [DIR]   pripoji se ke screenu serveru (odpojeni: Ctrl-A D)
#           claude-rc.sh stop      [DIR]   ukonci server (sluzbu vyjme z launchd do prihlaseni nebo start)
#           claude-rc.sh status            bezici servery a nainstalovane sluzby
#           claude-rc.sh install   [DIR]   sluzba launchd: server se spusti po prihlaseni a po padu
#           claude-rc.sh uninstall [DIR]   zrusi sluzbu launchd a ukonci server
#
# Nazev v seznamu sessions je "<pocitac> - <slozka>", nove sessions dostanou
# prefix "<pocitac>". Pocitac = LocalHostName, prepsatelny promennou CLAUDE_RC_HOST.
# Jeden screen na slozku (rc-<slozka>), druhy server ve stejne slozce se nespusti.
# Bez sluzby je po restartu Macu potreba server spustit znovu. Sluzba je LaunchAgent
# uzivatele: bezi jen po prihlaseni (Mac bez monitoru potrebuje automaticke prihlaseni).
# Pred install je potreba ve slozce jednou spustit start + attach a potvrdit duveru
# slozky a Remote Control (sluzba na dotazy odpovedet neumi).
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

readonly AGENT_DIR="$HOME/Library/LaunchAgents"
readonly LABEL_PREFIX="cz.nemecek.claude-rc"
readonly LOG_DIR="$HOME/Library/Logs"

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
    sed -n '12,17p' "$0" | sed 's/^# //'
    exit 1
}

for cmd in claude screen scutil perl launchctl plutil; do
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
    LABEL="${LABEL_PREFIX}.${SNAME#rc-}"
    PLIST="${AGENT_DIR}/${LABEL}.plist"
}

# Cil: Vrati 0, pokud je sluzba LABEL nactena v launchd (gui domena uzivatele), jinak 1.
is_loaded() {
    launchctl print "gui/$(id -u)/${LABEL}" >/dev/null 2>&1
}

# Cil: Vypise text escapovany pro XML (& < > ").
xml_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' <<<"$1"
}

# Cil: Overi, ze Claude Code je prihlaseny uctem claude.ai (Remote Control je k dispozici).
# Mantinely: Jen cte; bez prihlaseni skonci exit 1 s navodem.
# Kontrola: Vystup claude remote-control --help obsahuje USAGE.
# Bez platneho prihlaseni claude.ai vypise --help chybu misto napovedy (Remote Control
# eligibility). --help po vypisu sam neskonci, proto casovy limit pres perl alarm
# (macOS nema timeout) a rozhoduje text vystupu, ne navratovy kod.
check_login() {
    local help
    help=$(perl -e 'alarm 10; exec @ARGV' claude remote-control --help </dev/null 2>&1)
    if ! grep -q "USAGE" <<<"$help"; then
        error "Remote Control not available: Claude Code is not logged in with a claude.ai account."
        echo "  Run 'claude', type /login and choose a Claude subscription account (not Anthropic Console)." >&2
        exit 1
    fi
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
    if [[ -f "$PLIST" ]]; then
        if is_loaded; then
            error "Service $LABEL is running for $DIR. Restart: launchctl kickstart -k gui/$(id -u)/${LABEL}"
            exit 1
        fi
        # Sluzba vyjmuta prikazem stop -- nacte se znovu, server spusti launchd
        check_login
        launchctl bootstrap "gui/$(id -u)" "$PLIST" || { error "launchctl bootstrap failed for $PLIST"; exit 1; }
        sleep 3
        if is_running; then
            success "Service $LABEL loaded, server running: '${HOST_NAME} - ${BASE}' (directory $DIR)"
        else
            error "Service loaded but server is not running. See ${LOG_DIR}/${LABEL}.log"
            exit 1
        fi
        return
    fi
    if is_running; then
        error "Server for $DIR is already running (screen $SNAME). Attach: $0 attach \"$DIR\""
        exit 1
    fi
    check_login
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
    if is_loaded; then
        # KeepAlive by screen spustil znovu -- sluzba se proto vyjme z launchd (do dalsiho
        # prihlaseni nebo do start); bootout ukonci i screen
        launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null
        sleep 1
        echo "  Service $LABEL unloaded until next login or start (permanently: $0 uninstall \"$DIR\")."
        if ! is_running; then
            success "Server for $DIR stopped."
            exit 0
        fi
    fi
    is_running || { warn "Server for $DIR is not running."; exit 0; }
    $SCREEN -S "$SNAME" -X quit
    sleep 1
    if is_running; then
        error "Failed to quit screen $SNAME."
        exit 1
    fi
    success "Server for $DIR stopped."
}

# Cil: Nainstaluje a spusti sluzbu launchd (LaunchAgent) pro server ve slozce DIR.
# Mantinely: Prepise jen vlastni plist LABEL; kdyz server bezi rucne (start), skonci chybou.
#            screen -D -m bezi v popredi, takze ho launchd hlida a attach/status funguji dal.
#            KeepAlive spusti server znovu po jakemkoli ukonceni, ThrottleInterval brani rychle smycce.
# Kontrola: plutil -lint plistu, launchctl bootstrap a po 3 s is_running; jinak exit 1.
cmd_install() {
    resolve "$1"
    check_login
    if is_running && ! is_loaded; then
        error "Server for $DIR runs manually (screen $SNAME). Stop it first: $0 stop \"$DIR\""
        exit 1
    fi
    local claude_bin screen_bin path_env
    claude_bin="$(command -v claude)"
    screen_bin="$(command -v screen)"
    path_env="$(dirname "$claude_bin"):/usr/bin:/bin:/usr/sbin:/sbin"
    mkdir -p "$AGENT_DIR" "$LOG_DIR"
    if is_loaded; then
        launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null
        sleep 1
    fi
    cat >"$PLIST" <<PLIST_END
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(xml_escape "$screen_bin")</string>
        <string>-D</string>
        <string>-m</string>
        <string>-S</string>
        <string>${SNAME}</string>
        <string>$(xml_escape "$claude_bin")</string>
        <string>remote-control</string>
        <string>--name</string>
        <string>$(xml_escape "${HOST_NAME} - ${BASE}")</string>
        <string>--remote-control-session-name-prefix</string>
        <string>$(xml_escape "$HOST_NAME")</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$(xml_escape "$DIR")</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$(xml_escape "$path_env")</string>
        <key>TERM</key>
        <string>xterm-256color</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>StandardOutPath</key>
    <string>$(xml_escape "${LOG_DIR}/${LABEL}.log")</string>
    <key>StandardErrorPath</key>
    <string>$(xml_escape "${LOG_DIR}/${LABEL}.log")</string>
</dict>
</plist>
PLIST_END
    plutil -lint "$PLIST" >/dev/null || { error "Invalid plist: $PLIST"; exit 1; }
    if ! launchctl bootstrap "gui/$(id -u)" "$PLIST"; then
        error "launchctl bootstrap failed for $PLIST"
        exit 1
    fi
    sleep 3
    if is_running; then
        success "Service $LABEL installed, server running: '${HOST_NAME} - ${BASE}' (directory $DIR)"
        echo "  Plist: $PLIST"
        echo "  Log:   ${LOG_DIR}/${LABEL}.log"
    else
        error "Service loaded but server is not running. See ${LOG_DIR}/${LABEL}.log"
        exit 1
    fi
}

# Cil: Zrusi sluzbu launchd pro slozku DIR a ukonci jeji server.
# Mantinely: Smaze jen vlastni plist LABEL; log ponecha.
# Kontrola: Sluzba neni nactena, plist neexistuje a screen SNAME nebezi; jinak exit 1.
cmd_uninstall() {
    resolve "$1"
    if [[ ! -f "$PLIST" ]] && ! is_loaded; then
        warn "Service $LABEL is not installed."
        exit 0
    fi
    is_loaded && launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null
    rm -f "$PLIST"
    sleep 1
    if is_running; then
        $SCREEN -S "$SNAME" -X quit
        sleep 1
    fi
    if is_loaded || [[ -f "$PLIST" ]] || is_running; then
        error "Failed to remove service $LABEL completely."
        exit 1
    fi
    success "Service $LABEL removed, server for $DIR stopped."
}

# Cil: Vypise bezici screeny rc-*, nainstalovane sluzby a procesy claude remote-control. Jen cte.
cmd_status() {
    local list
    list=$(list_screens | grep -E '\.rc-[^[:space:]]+' | sed 's/^[[:space:]]*//')
    if [[ -z "$list" ]]; then
        echo "No claude-rc server is running."
    else
        echo "Servers (screen):"
        echo "$list"
    fi
    echo "Services (launchd):"
    local plist found=0
    for plist in "${AGENT_DIR}/${LABEL_PREFIX}".*.plist; do
        [[ -f "$plist" ]] || continue
        found=1
        LABEL="$(basename "$plist" .plist)"
        if is_loaded; then echo "  $LABEL (loaded)"; else echo "  $LABEL (not loaded)"; fi
    done
    [[ $found -eq 1 ]] || echo "  none"
    echo "claude remote-control processes:"
    pgrep -fl "claude remote-control" || echo "  none"
}

case "${1:-}" in
    start)  cmd_start  "${2:-}" ;;
    attach) cmd_attach "${2:-}" ;;
    stop)   cmd_stop   "${2:-}" ;;
    status) cmd_status ;;
    install)   cmd_install   "${2:-}" ;;
    uninstall) cmd_uninstall "${2:-}" ;;
    *)      usage ;;
esac
