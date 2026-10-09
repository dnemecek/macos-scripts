#!/bin/bash
#
# Soubor: claude-rc.sh
# Projekt: DN/macos-scripts
# Autor: David Nemecek
# Datum: 2026-10-09
# Popis: Claude Code Remote Control server jako sluzba launchd (LaunchAgent uzivatele).
#        Sessions jdou zakladat a ovladat z mobilu nebo z claude.ai/code.
#
# Verze: 2.0.0
#
# Pouziti:  claude-rc.sh init      [DIR]   prvni spusteni v popredi: potvrdit duveru slozky a Remote Control
#           claude-rc.sh install   [DIR]   vytvori a spusti sluzbu
#           claude-rc.sh start     [DIR]   spusti nainstalovanou sluzbu
#           claude-rc.sh stop      [DIR]   zastavi sluzbu (do dalsiho prihlaseni nebo start)
#           claude-rc.sh restart   [DIR]   restartuje sluzbu
#           claude-rc.sh status            nainstalovane sluzby, stav a PID
#           claude-rc.sh uninstall [DIR]   zastavi a odstrani sluzbu
#           claude-rc.sh run       DIR     jen pro launchd: overi slozku serveru a spusti server
#
# DIR = slozka serveru (nad ni server bezi, obsahuje workspaces). Bez DIR plati serverDir z configu.
# Config: claude-rc.conf vedle skriptu (jinak cesta v CLAUDE_RC_CONFIG), radky klic=hodnota,
# vzor claude-rc.conf.example. Poradi: parametr DIR > promenna prostredi > config > vychozi.
#   serverDir         CLAUDE_RC_DIR        vychozi $HOME/Documents/Source/Repos
#   hostName          CLAUDE_RC_HOST       vychozi LocalHostName pocitace
#   labelPrefix       CLAUDE_RC_LABEL      vychozi local.claude-rc
#
# Nazev v seznamu sessions je "<hostName> - <slozka>", nove sessions dostanou prefix
# "<hostName>". Jedna sluzba na nazev slozky.
# launchd spousti "claude-rc.sh run DIR", ktery pri kazdem startu overi slozku serveru a pak
# se nahradi procesem claude remote-control (PID drzi launchd). launchd server hlida
# (KeepAlive): po prihlaseni, po padu i po ukonceni serveru, ktery se ~10 min nemohl
# pripojit. Skript sam zadne procesy nehleda ani neukoncuje. Sluzba bezi jen po prihlaseni
# uzivatele (Mac bez monitoru potrebuje automaticke prihlaseni).
# Bez terminalu se claude remote-control nemuze zeptat na duveru slozky a skonci chybou
# "Workspace not trusted" -- proto pred install jednou init.
#
# Predpoklady: Claude Code prihlaseny uctem claude.ai (Pro/Max/Team/Enterprise),
#              ne API klicem; perl, launchctl, plutil (soucast macOS).
#

set -o pipefail

readonly SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
readonly CONFIG_FILE="${CLAUDE_RC_CONFIG:-$(dirname "$SCRIPT_PATH")/claude-rc.conf}"
readonly AGENT_DIR="$HOME/Library/LaunchAgents"
readonly LOG_DIR="$HOME/Library/Logs"
readonly DOMAIN="gui/$(id -u)"

readonly RED='\033[1;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# Hodnoty z configu (load_config); vychozi hodnoty doplni apply_settings
cfgServerDir=""
cfgHostName=""
cfgLabelPrefix=""

# Cil: Vypise chybu cervene na stderr.
error()   { echo -e "${RED}[ERROR] $1${NC}" >&2; }
# Cil: Vypise varovani zlute na stdout.
warn()    { echo -e "${YELLOW}[WARN] $1${NC}"; }
# Cil: Vypise uspech zelene na stdout.
success() { echo -e "${GREEN}[OK] $1${NC}"; }
# Cil: Zapise radek s casem do logu sluzby (stdout procesu pod launchd).
log_line() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2"; }

# Cil: Vypise blok Pouziti z hlavicky a skonci s kodem 1.
usage() {
    sed -n '12,19p' "$0" | sed 's/^# //'
    exit 1
}

# Cil: Overi, ze jsou k dispozici zadane prikazy.
# Mantinely: Jen cte. stop, uninstall a status claude nepotrebuji -- sluzbu jde odstranit
#            i po odinstalovani Claude Code.
# Kontrola: Chybejici prikaz ukonci skript exit 1 s nazvem prikazu.
require_cmds() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null || { error "Missing dependency: $cmd"; exit 1; }
    done
}

# Cil: Nacte config (klic=hodnota) do promennych cfg*.
# Mantinely: Config je volitelny; chybejici soubor neni chyba. Soubor se NEspousti (source),
#            cte se po radcich: povolene klice serverDir, hostName, labelPrefix;
#            prazdne radky a komentare (#) se preskoci, uvozovky kolem hodnoty se odstrani,
#            ~ a $HOME na zacatku hodnoty se rozvine. Neznamy klic nebo spatny radek = chyba.
# Kontrola: Navratovy kod 0 a nastavene cfg*; jinak exit 1 s cislem radku.
load_config() {
    local line key value lineNo=0 lineRe='^([A-Za-z]+)=(.*)$'
    [[ -f "$CONFIG_FILE" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineNo=$((lineNo + 1))
        line="${line%%#*}"
        line="$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<<"$line")"
        [[ -z "$line" ]] && continue
        if [[ ! "$line" =~ $lineRe ]]; then
            error "Invalid line $lineNo in $CONFIG_FILE (expected key=value)"
            exit 1
        fi
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        value="${value#\"}"; value="${value%\"}"
        value="${value#\'}"; value="${value%\'}"
        case "$value" in
            "~"*)     value="$HOME${value#\~}" ;;
            '$HOME'*) value="$HOME${value#\$HOME}" ;;
        esac
        case "$key" in
            serverDir)   cfgServerDir="$value" ;;
            hostName)    cfgHostName="$value" ;;
            labelPrefix) cfgLabelPrefix="$value" ;;
            *) error "Unknown key '$key' on line $lineNo in $CONFIG_FILE"; exit 1 ;;
        esac
    done <"$CONFIG_FILE"
}

# Cil: Nastavi konstanty DEFAULT_DIR, HOST_NAME a LABEL_PREFIX (prostredi > config > vychozi).
# Mantinely: DEFAULT_DIR absolutni cesta; HOST_NAME 1-63 znaku A-Z a-z 0-9 mezera . _ -;
#            LABEL_PREFIX reverse-DNS (A-Z a-z 0-9 . -), protoze je soucasti nazvu souboru plistu.
# Kontrola: Neplatna hodnota ukonci skript exit 1 se jmenem klice a zdrojem hodnoty.
apply_settings() {
    local serverDir hostName labelPrefix
    local hostRe='^[A-Za-z0-9._ -]{1,63}$' labelRe='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'
    serverDir="${CLAUDE_RC_DIR:-${cfgServerDir:-$HOME/Documents/Source/Repos}}"
    hostName="${CLAUDE_RC_HOST:-${cfgHostName:-$(scutil --get LocalHostName 2>/dev/null || hostname -s)}}"
    labelPrefix="${CLAUDE_RC_LABEL:-${cfgLabelPrefix:-local.claude-rc}}"
    if [[ "$serverDir" != /* ]]; then
        error "serverDir must be an absolute path: '$serverDir' (config $CONFIG_FILE or CLAUDE_RC_DIR)"
        exit 1
    fi
    if [[ ! "$hostName" =~ $hostRe ]]; then
        error "hostName must be 1-63 chars A-Z a-z 0-9 space . _ -: '$hostName' (config or CLAUDE_RC_HOST)"
        exit 1
    fi
    if [[ ! "$labelPrefix" =~ $labelRe ]]; then
        error "labelPrefix must be reverse-DNS (A-Z a-z 0-9 . -): '$labelPrefix' (config or CLAUDE_RC_LABEL)"
        exit 1
    fi
    readonly DEFAULT_DIR="$serverDir" HOST_NAME="$hostName" LABEL_PREFIX="$labelPrefix"
}

# Cil: Nastavi workDir (absolutni cesta), baseName (nazev slozky), label, plistPath a logPath.
# Mantinely: Vstup je cesta ke slozce nebo prazdny (pak DEFAULT_DIR). Neexistujici slozka
#            ukonci skript jen s parametrem must_exist (init, install, start, restart, run);
#            stop, uninstall a status musi jit i pro smazanou slozku. Do label jdou jen znaky
#            A-Z a-z 0-9 . _ - (ostatni nahradi pomlcka); kolizi slozek se stejnym nazvem hlida
#            check_owner.
# Kontrola: Navratovy kod 0 a nastavene promenne; jinak exit 1 s chybou.
resolve() {
    local dir="${1:-$DEFAULT_DIR}" mode="${2:-}"
    if [[ -d "$dir" ]]; then
        workDir="$(cd "$dir" && pwd)"
    elif [[ "$mode" == "must_exist" ]]; then
        error "Server directory not found: $dir"
        exit 1
    else
        # Smazana slozka: absolutni cesta bez cd (odstrani koncove lomitko)
        [[ "$dir" == /* ]] || dir="$PWD/$dir"
        workDir="${dir%/}"
    fi
    baseName="$(basename "$workDir")"
    label="${LABEL_PREFIX}.$(sed 's/[^A-Za-z0-9._-]/-/g' <<<"$baseName")"
    plistPath="${AGENT_DIR}/${label}.plist"
    logPath="${LOG_DIR}/${label}.log"
}

# Cil: Vrati 0, pokud je sluzba label nactena v launchd, jinak 1.
is_loaded() {
    launchctl print "${DOMAIN}/${label}" >/dev/null 2>&1
}

# Cil: Vypise hodnotu polozky nejvyssi urovne z launchctl print (napr. pid, state, last exit code).
# Polozky nejvyssi urovne maji odsazeni jednim tabulatorem, vnorene bloky vice.
service_field() {
    launchctl print "${DOMAIN}/${label}" 2>/dev/null | awk -F' = ' -v k="\t$1" '$1 == k { print $2; exit }'
}

# Cil: Vypise hodnotu klice z plistu sluzby (plutil -extract, napr. WorkingDirectory).
plist_value() {
    plutil -extract "$1" raw -o - "$plistPath" 2>/dev/null
}

# Cil: Vypise text escapovany pro XML (& < > ").
xml_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' <<<"$1"
}

# Cil: Ukonci skript chybou, kdyz sluzba pro workDir neni nainstalovana.
require_installed() {
    [[ -f "$plistPath" ]] || { error "Service for $workDir is not installed. Run: $0 install \"$workDir\""; exit 1; }
}

# Cil: Overi, ze existujici plist label patri slozce workDir (stejny label maji slozky se stejnym nazvem).
# Mantinely: Jen cte; bez plistu nic nekontroluje.
# Kontrola: Kdyz plist patri jine slozce, exit 1 s chybou a cestou te slozky.
check_owner() {
    local owner
    [[ -f "$plistPath" ]] || return 0
    owner="$(plist_value WorkingDirectory)"
    if [[ "$owner" != "$workDir" ]]; then
        error "Service $label belongs to another server directory: $owner"
        echo "  One service per folder name. Remove it first: $0 uninstall \"$owner\"" >&2
        exit 1
    fi
}

# Cil: Overi, ze Claude Code je prihlaseny uctem claude.ai (Remote Control je k dispozici).
# Mantinely: Jen cte; bez prihlaseni skonci exit 1 s navodem.
#            Bez platneho prihlaseni claude.ai vypise --help chybu misto napovedy. --help po
#            vypisu sam neskonci, proto casovy limit pres perl alarm (macOS nema timeout)
#            a rozhoduje text vystupu, ne navratovy kod.
# Kontrola: Vystup claude remote-control --help obsahuje USAGE.
check_login() {
    local helpText
    helpText=$(perl -e 'alarm 10; exec @ARGV' claude remote-control --help </dev/null 2>&1)
    if ! grep -q "USAGE" <<<"$helpText"; then
        error "Remote Control not available: Claude Code is not logged in with a claude.ai account."
        echo "  Run 'claude', type /login and choose a Claude subscription account (not Anthropic Console)." >&2
        exit 1
    fi
}

# Cil: Pocka, az launchd sluzbu label po bootout opravdu vyjme (bootout dobiha asynchronne).
# Kontrola: Navratovy kod 0, kdyz sluzba neni nactena do 10 s, jinak 1.
wait_unloaded() {
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        is_loaded || return 0
        sleep 1
    done
    ! is_loaded
}

# Cil: Vyjme sluzbu label z launchd; launchd ukonci jeji proces vcetne skupiny procesu.
# Mantinely: Meni jen sluzbu label; plist ponecha.
# Kontrola: wait_unloaded; jinak exit 1 s chybou.
unload_service() {
    launchctl bootout "${DOMAIN}/${label}" || { error "launchctl bootout failed for $label"; exit 1; }
    wait_unloaded || { error "Service $label is still loaded."; exit 1; }
}

# Cil: Nacte sluzbu z plistPath do launchd (gui domena uzivatele), launchd ji hned spusti (RunAtLoad).
# Mantinely: gui domena existuje jen pri prihlaseni do plochy macOS, ne pres samotne SSH.
# Kontrola: Navratovy kod launchctl bootstrap; pri chybe exit 1 s napovedou.
load_service() {
    if ! launchctl bootstrap "$DOMAIN" "$plistPath"; then
        error "launchctl bootstrap failed for $plistPath"
        echo "  The user must be logged in to the macOS desktop (gui domain); SSH alone is not enough." >&2
        exit 1
    fi
}

# Velikost logu pred spustenim -- check_running pak ukaze jen radky tohoto behu
logOffset=0

# Cil: Zapamatuje velikost logu (logOffset) a nastavi log citelny jen pro uzivatele.
# Mantinely: Log obsahuje odkazy na sessions, proto prava 600. Vytvori prazdny log, kdyz chybi.
# Kontrola: logOffset je cislo; chyba touch/chmod se vypise na stderr.
mark_log() {
    touch "$logPath" && chmod 600 "$logPath"
    logOffset=$(wc -c <"$logPath" | tr -d ' ')
}

# Cil: Overi, ze sluzba po spusteni bezi stabilne (server neskoncil hned po startu).
# Mantinely: Ceka max. 10 s na PID odlisny od oldPid (restart) a pak 5 s overuje, ze se PID
#            nezmenil. Server, ktery spadne pozdeji, odhali az status. Pri neuspechu sluzbu
#            vyjme z launchd, aby KeepAlive server nespoustel dokola.
# Kontrola: Navratovy kod 0 a vypis uspechu; jinak 1 s chybou a novymi radky logu.
check_running() {
    local oldPid="${1:-}" pid="" pid2 i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        pid=$(service_field pid)
        [[ -n "$pid" && "$pid" != "$oldPid" ]] && break
        pid=""
        sleep 1
    done
    sleep 5
    pid2=$(service_field pid)
    if [[ -n "$pid" && "$pid" == "$pid2" ]]; then
        success "Service $label running (PID $pid), server directory $workDir"
        return 0
    fi
    error "Service $label is not running stably (last exit code: $(service_field 'last exit code'))."
    echo "  Output of this start ($logPath):" >&2
    tail -c "+$((logOffset + 1))" "$logPath" 2>/dev/null | tail -5 | sed 's/^/    /' >&2
    is_loaded && launchctl bootout "${DOMAIN}/${label}" 2>/dev/null && wait_unloaded
    echo "  Service stopped. Workspace not trusted or Remote Control not enabled? Run: $0 init \"$workDir\"" >&2
    return 1
}

# Cil: Spusti claude remote-control v popredi v terminalu, aby slo odpovedet na dotazy
#      na duveru slozky a zapnuti Remote Control.
# Mantinely: Slozka serveru musi existovat. Kdyz sluzba pro workDir bezi, skonci chybou (dva servery
#            ve stejne slozce). Proces nahradi skript (exec), ukonceni Ctrl+C.
# Kontrola: Server vypise, ze bezi; pak Ctrl+C a install nebo start.
cmd_init() {
    require_cmds claude perl
    resolve "$1" must_exist
    if is_loaded; then
        error "Service $label is running for $workDir. Stop it first: $0 stop \"$workDir\""
        exit 1
    fi
    check_login
    echo "Answer the trust and Remote Control questions. When the server is running, stop it"
    echo "with Ctrl+C and run: $0 install \"$workDir\" (or start, if already installed)."
    cd "$workDir" || exit 1
    exec claude remote-control --name "${HOST_NAME} - ${baseName}" --remote-control-session-name-prefix "$HOST_NAME"
}

# Cil: Spusteni serveru launchd: overi slozku serveru a claude, pak se nahradi procesem claude remote-control.
# Mantinely: Vola jen launchd z plistu (HOST_NAME z EnvironmentVariables plistu). Chybejici
#            slozku serveru nebo claude zapise do logu a skonci exit 1; launchd to zkusi znovu po
#            ThrottleInterval (30 s). Nic nemeni.
# Kontrola: Radek [ERROR] v logu sluzby a status s MISSING u chybejici slozky serveru.
cmd_run() {
    if [[ -z "$1" ]]; then
        log_line ERROR "Missing server directory argument (run is called only by launchd from the plist)."
        exit 1
    fi
    if [[ ! -d "$1" ]]; then
        log_line ERROR "Server directory not found: ${1:-<empty>}. Restore it or run: $0 uninstall \"$1\""
        exit 1
    fi
    if ! command -v claude >/dev/null; then
        log_line ERROR "claude not found in PATH ($PATH). Reinstall the service: $0 install \"$1\""
        exit 1
    fi
    resolve "$1" must_exist
    log_line INFO "Starting claude remote-control '${HOST_NAME} - ${baseName}' in $workDir"
    cd "$workDir" || exit 1
    exec claude remote-control --name "${HOST_NAME} - ${baseName}" --remote-control-session-name-prefix "$HOST_NAME"
}

# Cil: Vytvori plist sluzby launchd pro slozku serveru workDir a sluzbu spusti.
# Mantinely: Slozka serveru musi existovat. Prepise jen vlastni plist label; nactenou sluzbu nejdriv
#            zastavi (reinstall). Plist jine slozky se stejnym nazvem neprepise (check_owner).
#            launchd spousti "claude-rc.sh run DIR" z teto cesty skriptu, bez TTY (vstup /dev/null),
#            proto instalovat z nasazene kopie (napr. ~/bin), ne z pracovniho klonu.
#            PATH sluzby = PATH shellu pri install (sessions potrebuji git, gh, node...) + systemove
#            cesty; po zmene nastroju (napr. nvm) je potreba install zopakovat.
# Kontrola: plutil -lint plistu, launchctl bootstrap a check_running; jinak exit 1.
cmd_install() {
    require_cmds claude perl
    resolve "$1" must_exist
    check_owner
    check_login
    local claudeBin pathEnv
    claudeBin="$(command -v claude)"
    pathEnv="$(dirname "$claudeBin"):${PATH}:/usr/bin:/bin:/usr/sbin:/sbin"
    mkdir -p "$AGENT_DIR" "$LOG_DIR"
    is_loaded && unload_service
    cat >"$plistPath" <<PLIST_END
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$(xml_escape "$SCRIPT_PATH")</string>
        <string>run</string>
        <string>$(xml_escape "$workDir")</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$(xml_escape "$workDir")</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$(xml_escape "$pathEnv")</string>
        <key>CLAUDE_RC_HOST</key>
        <string>$(xml_escape "$HOST_NAME")</string>
        <key>CLAUDE_RC_LABEL</key>
        <string>$(xml_escape "$LABEL_PREFIX")</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>StandardOutPath</key>
    <string>$(xml_escape "$logPath")</string>
    <key>StandardErrorPath</key>
    <string>$(xml_escape "$logPath")</string>
</dict>
</plist>
PLIST_END
    plutil -lint "$plistPath" >/dev/null || { error "Invalid plist: $plistPath"; exit 1; }
    mark_log
    load_service
    check_running || exit 1
    echo "  Session name: '${HOST_NAME} - ${baseName}'"
    echo "  Plist: $plistPath"
    echo "  Log:   $logPath"
}

# Cil: Spusti nainstalovanou sluzbu pro slozku serveru workDir.
# Mantinely: Slozka serveru musi existovat. Bez plistu nebo s plistem jine slozky skonci chybou;
#            bezici sluzbu nemeni.
# Kontrola: check_running; jinak exit 1.
cmd_start() {
    require_cmds claude perl
    resolve "$1" must_exist
    require_installed
    check_owner
    if is_loaded && [[ -n "$(service_field pid)" ]]; then
        warn "Service $label is already running (PID $(service_field pid))."
        exit 0
    fi
    check_login
    mark_log
    if is_loaded; then
        # Nactena, ale proces nebezi (ceka na dalsi pokus po ThrottleInterval) -- spustit hned
        launchctl kickstart "${DOMAIN}/${label}" || { error "launchctl kickstart failed for $label"; exit 1; }
    else
        load_service
    fi
    check_running || exit 1
}

# Cil: Zastavi sluzbu pro slozku serveru workDir (vyjme ji z launchd do dalsiho prihlaseni nebo start).
# Mantinely: Plist ponecha. Proces ukonci launchd vcetne jeho skupiny procesu. Funguje i pro
#            smazanou slozku serveru.
# Kontrola: Sluzba neni nactena; jinak exit 1.
cmd_stop() {
    resolve "$1"
    require_installed
    check_owner
    if ! is_loaded; then
        warn "Service $label is not running."
        exit 0
    fi
    unload_service
    success "Service $label stopped (starts again at next login or with: $0 start \"$workDir\")."
}

# Cil: Restartuje bezici sluzbu pro slozku serveru workDir (launchctl kickstart -k).
# Mantinely: Slozka serveru musi existovat. Nenactenou sluzbu jen spusti (jako start).
# Kontrola: check_running s PID puvodniho procesu (novy PID se musi lisit); jinak exit 1.
cmd_restart() {
    require_cmds claude perl
    resolve "$1" must_exist
    require_installed
    check_owner
    if ! is_loaded; then
        cmd_start "$1"
        return
    fi
    local oldPid
    oldPid=$(service_field pid)
    mark_log
    launchctl kickstart -k "${DOMAIN}/${label}" || { error "launchctl kickstart failed for $label"; exit 1; }
    check_running "$oldPid" || exit 1
}

# Cil: Zastavi a odstrani sluzbu pro slozku serveru workDir.
# Mantinely: Smaze jen vlastni plist label (ne plist jine slozky se stejnym nazvem); log ponecha.
#            Funguje i pro smazanou slozku serveru a bez nainstalovaneho Claude Code.
# Kontrola: Sluzba neni nactena a plist neexistuje; jinak exit 1.
cmd_uninstall() {
    resolve "$1"
    if [[ ! -f "$plistPath" ]] && ! is_loaded; then
        warn "Service $label is not installed."
        exit 0
    fi
    check_owner
    is_loaded && unload_service
    rm -f "$plistPath"
    if is_loaded || [[ -f "$plistPath" ]]; then
        error "Failed to remove service $label completely."
        exit 1
    fi
    success "Service $label removed (log kept: $logPath)."
}

# Cil: Vypise nainstalovane sluzby: label, slozku serveru, stav, PID a posledni exit code. Jen cte.
cmd_status() {
    local found=0 dir
    for plistPath in "${AGENT_DIR}/${LABEL_PREFIX}".*.plist; do
        [[ -f "$plistPath" ]] || continue
        found=1
        label="$(basename "$plistPath" .plist)"
        dir="$(plist_value WorkingDirectory)"
        echo "$label"
        if [[ -d "$dir" ]]; then
            echo "  directory: $dir"
        else
            echo "  directory: $dir (MISSING -- server cannot start; remove: $0 uninstall \"$dir\")"
        fi
        if is_loaded; then
            echo "  state:     $(service_field state), PID $(service_field pid)"
            echo "  last exit: $(service_field 'last exit code')"
        else
            echo "  state:     not loaded (stopped)"
        fi
    done
    [[ $found -eq 1 ]] || echo "No claude-rc service is installed (label prefix $LABEL_PREFIX)."
}

require_cmds launchctl plutil scutil
load_config
apply_settings

case "${1:-}" in
    init)      cmd_init      "${2:-}" ;;
    install)   cmd_install   "${2:-}" ;;
    start)     cmd_start     "${2:-}" ;;
    stop)      cmd_stop      "${2:-}" ;;
    restart)   cmd_restart   "${2:-}" ;;
    status)    cmd_status ;;
    uninstall) cmd_uninstall "${2:-}" ;;
    run)       cmd_run       "${2:-}" ;;
    *)         usage ;;
esac
