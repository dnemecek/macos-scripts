#!/bin/bash
#
# Soubor: sync-c1-settings.sh
# Projekt: DN/apple-scripts
# Autor: David Nemecek
# Datum: 2026-08-03
# Popis: Synchronizace uzivatelskeho nastaveni Capture One mezi Macy pres sdilenou
#        slozku v iCloud Drive. push = tento Mac -> iCloud, pull = iCloud -> tento Mac.
#
# Verze: 1.0.1
#
# Historie zmen:
# - 2026-08-03 David Nemecek: 1.0.1 - slozka Backups pridana mezi zname vyjimky.
#   Dle dokumentace Capture One jde o vychozi umisteni zaloh databazi katalogu
#   a sessions na macOS - strojove specificka data, nikoli nastaveni.
# - 2026-08-03 David Nemecek: 1.0.0 - prvni verze. Whitelist uzivatelskych slozek
#   (Styles, Presets*, Recipes*, Workspaces, ...), cache/stav/licence se nesynchronizuji.
#   Obe operace default dry-run (--apply), pred ostrym pull lokalni tar zaloha.
#
# Pouziti na druhem Macu (zdroj nastaveni):  sync-c1-settings.sh push --apply
# Pouziti na cilovem Macu:                   sync-c1-settings.sh pull --apply
#
#

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="1.0.1"

# Zdroj nastaveni Capture One na tomto Macu.
readonly C1_DIR="${HOME}/Library/Application Support/Capture One"

# Sdilena slozka - obe strany ji vidi pres iCloud Drive.
readonly SYNC_DIR="${HOME}/Library/Mobile Documents/com~apple~CloudDocs/Fotky/Sync/CaptureOne"

# Lokalni zaloha prepisovaneho nastaveni pred ostrym pull.
readonly BACKUP_DIR="${HOME}/.backup"

# Whitelist uzivatelskeho obsahu jako GLOB VZORY - rozbaluji se az za behu proti
# konkretni slozce (expandItems), ne pri definici. Nazvy s verzi (Presets60,
# Recipes165) diky tomu funguji i pri jine verzi Capture One na druhem Macu.
# Zamerne CHYBI: CaptureCore, ImageCore, Batch Queue*, ApplicationStability*,
# Diagnostics, Plug-ins, Rollbar.txt a preferences plist - cache, stav stroje
# a licencni data se mezi pocitaci prenaset nesmeji.
readonly SYNC_PATTERNS=(
    "Styles"
    "StyleBrushes"
    "Presets*"
    "Recipes*"
    "Workspaces"
    "KeyboardShortcuts"
    "Templates"
    "Keywords"
    "Search Presets"
    "Smart Adjustments"
    "Aspect Ratios*"
    "Guides"
    "Normalizations"
    "Print"
)

# Zname NEsynchronizovane slozky - cache, stav aplikace a stroje, plug-iny.
# Slouzi jen k tomu, aby je push nehlasil jako neznamy nalez.
readonly KNOWN_EXCLUDES=(
    "CaptureCore"
    "ImageCore"
    "Batch Queue*"
    "ApplicationStability*"
    "Diagnostics"
    "Plug-ins"
    "MultipleFolders"
    "Backups"
)

# Vrati 0, kdyz nazev odpovida nekteremu vzoru (case pattern se neword-splituje).
matchesAny() {
    local item="$1" p
    shift
    for p in "$@"; do
        case "$item" in
            $p) return 0 ;;
        esac
    done
    return 1
}

# Rozbali whitelist vzory proti zadane slozce, jeden nazev na radek.
# IFS= vypina word splitting (nazvy s mezerou), nullglob zahazuje vzory bez shody.
expandItems() {
    local base="$1" pattern item
    ( cd "$base" 2>/dev/null || exit 0
      shopt -s nullglob
      IFS=
      for pattern in "${SYNC_PATTERNS[@]}"; do
          for item in $pattern; do
              [ -d "$item" ] && printf '%s\n' "$item"
          done
      done )
}

readonly EXIT_OK=0
readonly EXIT_USAGE=1
readonly EXIT_ENV=2
readonly EXIT_TRANSFER=3

apply=0
delete=0
command=""

usage() {
    cat <<'USAGE'
sync-c1-settings.sh - synchronizace nastaveni Capture One mezi Macy pres iCloud

POUZITI
    sync-c1-settings.sh push [--apply] [--delete]   tento Mac -> iCloud sync slozka
    sync-c1-settings.sh pull [--apply] [--delete]   iCloud sync slozka -> tento Mac

    Bez --apply je kazdy beh jen DRY-RUN (vypise, co by se preneslo).
    --delete navic smaze na cilove strane polozky, ktere na zdrojove nejsou
    (zrcadlo; jen v ramci whitelistu, plati az s --apply).

CO SE SYNCHRONIZUJE
    Uzivatelsky obsah: styly, presety, recipes, workspaces, klavesove zkratky,
    sablony, klicova slova. NIKDY: cache, stav aplikace, plug-iny, licence,
    preferences plist.

TYPICKY POSTUP (prenos nastaveni ze stareho Macu na novy)
    1. na starem Macu:  sync-c1-settings.sh push --apply
    2. pockat na iCloud sync
    3. na novem Macu:   sync-c1-settings.sh pull --apply   (C1 musi byt vypnute)
    4. spustit Capture One a zkontrolovat styly/presety

EXIT KODY
    0 uspech   1 chyba parametru   2 prostredi (bezici C1, chybejici slozka)   3 chyba prenosu
USAGE
}

log() {
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "${*:2}" >&2
}

die() {
    local code="$1"; shift
    log "ERROR" "$*"
    exit "$code"
}

# Bezici Capture One drzi soubory nastaveni otevrene - ostry zapis by mohl
# skoncit poskozenym nastavenim nebo tichym prepsanim po ukonceni aplikace.
guardNotRunning() {
    if pgrep -xq "Capture One"; then
        die "$EXIT_ENV" "Capture One is running - quit it before using --apply"
    fi
}

# Zaloha lokalniho nastaveni pred prepsanim (jen existujici polozky whitelistu).
backupLocal() {
    local stamp archive item
    stamp="$(date +%Y%m%dT%H%M%S)"
    archive="${BACKUP_DIR}/c1-settings-${stamp}.tar.gz"
    mkdir -p "$BACKUP_DIR"

    local existing=()
    while IFS= read -r item; do
        existing+=("$item")
    done < <(expandItems "$C1_DIR")

    if [ "${#existing[@]}" -eq 0 ]; then
        log "INFO" "Nothing to back up locally (no whitelist items present)"
        return 0
    fi
    tar -czf "$archive" -C "$C1_DIR" "${existing[@]}"
    log "INFO" "Local settings backed up: ${archive}"
}

# Ohlasit slozky, ktere v C1 nastaveni existuji, ale nejsou ve whitelistu ani mezi
# znamymi vyjimkami. Nic se nesmi preskocit potichu - nalez se resi rozsirenim
# whitelistu v repu, ne lokalni upravou.
reportUnknown() {
    local item
    for item in "$C1_DIR"/*/; do
        [ -d "$item" ] || continue
        item="$(basename "$item")"
        if ! matchesAny "$item" "${SYNC_PATTERNS[@]}" && ! matchesAny "$item" "${KNOWN_EXCLUDES[@]}"; then
            log "WARN" "Unknown folder not synced: ${item} - report it so the whitelist can be extended"
        fi
    done
}

# Prenos jedne polozky whitelistu. Smer urcuji parametry, prazdne zdroje se preskoci.
syncItem() {
    local src="$1" dst="$2" name="$3"
    local opts=(-a --exclude='.DS_Store')

    [ -d "$src" ] || return 0
    # Prazdnou slozku nema smysl prenaset - jen by zakladala prazdne cile.
    [ -n "$(find "$src" -type f -not -name '.DS_Store' -print -quit 2>/dev/null)" ] || return 0

    [ "$delete" -eq 1 ] && opts+=(--delete)

    # Dry-run nesmi na disku nic zalozit - ani cilovou slozku.
    if [ "$apply" -eq 0 ]; then
        opts+=(-n -v)
        log "INFO" "Would sync: ${name}"
        rsync "${opts[@]}" "$src/" "$dst/" 2>/dev/null || true
        return 0
    fi

    mkdir -p "$dst"
    rsync "${opts[@]}" "$src/" "$dst/" || die "$EXIT_TRANSFER" "rsync failed for ${name}"
    log "INFO" "Synced: ${name}"
}

main() {
    for arg in "$@"; do
        case "$arg" in
            push|pull) command="$arg" ;;
            --apply)   apply=1 ;;
            --delete)  delete=1 ;;
            --version) printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit "$EXIT_OK" ;;
            -h|--help) usage; exit "$EXIT_OK" ;;
            *) usage >&2; die "$EXIT_USAGE" "Unknown argument: $arg" ;;
        esac
    done
    [ -n "$command" ] || { usage >&2; die "$EXIT_USAGE" "Missing command: push or pull"; }

    [ -d "$C1_DIR" ] || die "$EXIT_ENV" "Capture One settings folder not found: ${C1_DIR}"

    if [ "$apply" -eq 0 ]; then
        log "INFO" "*** DRY-RUN - add --apply to actually transfer ***"
    else
        guardNotRunning
    fi

    local item
    if [ "$command" = "push" ]; then
        [ "$apply" -eq 1 ] && mkdir -p "$SYNC_DIR"
        while IFS= read -r item; do
            syncItem "${C1_DIR}/${item}" "${SYNC_DIR}/${item}" "$item"
        done < <(expandItems "$C1_DIR")
        reportUnknown
    else
        [ -d "$SYNC_DIR" ] || die "$EXIT_ENV" "Sync folder not found (run push on the source Mac first): ${SYNC_DIR}"
        if [ "$apply" -eq 1 ]; then
            backupLocal
        fi
        while IFS= read -r item; do
            syncItem "${SYNC_DIR}/${item}" "${C1_DIR}/${item}" "$item"
        done < <(expandItems "$SYNC_DIR")
    fi

    if [ "$apply" -eq 0 ]; then
        log "INFO" "DRY-RUN finished - nothing was changed"
    else
        log "INFO" "${command} finished"
    fi
    exit "$EXIT_OK"
}

main "$@"
