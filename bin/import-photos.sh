#!/bin/bash
#
# Soubor: import-photos.sh
# Projekt: DN/apple-scripts
# Autor: David Nemecek
# Datum: 2026-07-29
# Popis: Import fotografii z pametove karty do slozek pripravenych pro Capture One session.
#        Jedna session = jeden den poriuzeni (EXIF, fallback mtime); typy souboru jsou
#        oddelene podslozky uvnitr Capture (Capture/CR3, Capture/JPG).
#
# Verze: 3.0.0
#
# Historie zmen:
# - 2026-08-03 David Nemecek: 3.0.0 - BREAKING. Session = den: kostra Capture/Selects/
#   Output/Trash se zaklada primo na urovni dne, typy souboru jsou podslozky Capture.
#   Odstranen prepinac --layout - bytype i single vytvarely strukturu v rozporu
#   s modelem jedne session na den (rozhodnuti David 2026-08-03).
# - 2026-07-29 David Nemecek: 2.1.0 - zaloha originalu (--backup). Zaloha se vzdy kopiruje
#   a vzdy overuje checksumem, a to PRED hlavnim prenosem - v rezimu move se tak karta
#   nikdy nemaze driv, nez existuje overena druha kopie.
# - 2026-07-29 David Nemecek: 2.0.0 - BREAKING. Cilova struktura je nyni kostra Capture One
#   session (Capture/Selects/Output/Trash) misto holeho Capture; snimky se deli podle dne
#   poriuzeni z EXIF (sips, fallback mtime) misto jedne slozky s casem importu; slozka s
#   casem importu zcela odstranena. Nove --suffix, --date-source; zrusen --name.
# - 2026-07-29 David Nemecek: 1.0.0 - prvni verze, zobecneni puvodniho rsync_foto.sh.
#
# Overeno v dokumentaci Capture One (support.captureone.com, 2026-07-29):
#   - Session = slozka se ctyrmi podslozkami Capture/Selects/Output/Trash + soubor .cosessiondb.
#   - Podslozky uvnitr Capture jsou v Capture One bezny postup - Session Builder je primo
#     zaklada ("create multiple folders and subfolders within the Capture folder").
#   - Pri File > New Session lze existujici slozky "place", tedy session zalozit nad predem
#     pripravenou strukturou. Skript proto vytvari jen slozky, .cosessiondb nechava na Capture One.
#   - Podslozky CaptureOne / Cache / Settings* si zaklada Capture One sam - skript je nevytvari.
#
# One Module: verzovani uvnitr kodu, nikdy v nazvu souboru.
#
# Predpoklad: nazvy souboru z fotoaparatu neobsahuji znak noveho radku ani "|"
# (DCIM konvence, napr. BL6A7039.CR3). Jina jmena skript ohlasi jako chybu prenosu.
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Konstanty
# ---------------------------------------------------------------------------

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="3.0.0"

# ---- NASTAVENI: uprav tyto tri radky, at skript funguje bez parametru --------
#
# Odkud: prazdna hodnota = autodetekce pripojene karty (jediny svazek v /Volumes
#        s podslozkou DCIM). Konkretni cestu lze zadat natvrdo, napr.
#        "/Volumes/EOS_DIGITAL/DCIM".
readonly DEFAULT_SOURCE=""
#
# Kam: koren, do ktereho se zakladaji slozky dnu poriuzeni.
readonly DEFAULT_DEST="${HOME}/Library/Mobile Documents/com~apple~CloudDocs/Fotky/Capture One"
#
# Kopirovat, nebo prenest: copy = karta zustane plna, move = karta se po
#        overenem prenosu uvolni. Bezpecna vychozi hodnota je copy.
readonly DEFAULT_MODE="copy"
#
# Zaloha originalu: druha kopie snimku mimo hlavni cil, vzdy overena checksumem.
#        Prazdna hodnota = zaloha vypnuta. Slozka smi byt symlink na externi disk
#        nebo NAS - to je cilovy stav. Dokud vede na stejny svazek jako cil, neni to
#        zaloha (tataz domena selhani) a skript na to pri kazdem behu upozorni.
readonly DEFAULT_BACKUP="${HOME}/Library/Mobile Documents/com~apple~CloudDocs/Fotky/Backup"
#
# ---- konec NASTAVENI --------------------------------------------------------

readonly DEFAULT_TYPES="CR3,JPG"
readonly DEFAULT_DATE_SOURCE="auto"

# Ctyri podslozky, ktere ocekava Capture One session.
readonly SESSION_FOLDERS="Capture Selects Output Trash"

# Exit kody (ansible_ready: 0 = success, non-zero = error).
readonly EXIT_OK=0
readonly EXIT_USAGE=1
readonly EXIT_SOURCE=2
readonly EXIT_TRANSFER=3
readonly EXIT_DEST=4
readonly EXIT_DEPENDENCY=5

# ---------------------------------------------------------------------------
# Globalni stav
# ---------------------------------------------------------------------------

sourceDir="$DEFAULT_SOURCE"
destRoot="$DEFAULT_DEST"
backupRoot="$DEFAULT_BACKUP"
sessionSuffix=""
fileTypes="$DEFAULT_TYPES"
mode="$DEFAULT_MODE"
dateSource="$DEFAULT_DATE_SOURCE"
logFile=""
jsonOutput=0
verbose=0
dryRun=0
assumeYes=0
doVerify=0

tmpDir=""
listRoot=""
dirIndex=0
totalFiles=0
sessionCount=0

# ---------------------------------------------------------------------------
# Pomocne funkce
# ---------------------------------------------------------------------------

usage() {
    cat <<'USAGE'
import-photos.sh - import fotografii z karty do slozek pro Capture One session

POUZITI
    import-photos.sh [volby]

CO SKRIPT UDELA
    Snimky na karte rozdeli podle DNE PORIZENI. Pro kazdy den zalozi kostru
    JEDNE Capture One session; typy souboru jsou oddelene podslozky Capture:

        <cil>/240827/
        ├── Capture/CR3/  a  Capture/JPG/
        └── Selects/  Output/  Trash/
        <cil>/240828/
        ...

    Soubor .cosessiondb skript nevytvari - session zalozis v Capture One pres
    File > New Session nad prislusnou slozkou (dialog umi existujici slozky prevzit).

    Je-li nastavena zaloha, vznikne PRED hlavnim prenosem druha kopie originalu:

        <zaloha>/240827/CR3/BL6A6655.CR3
        <zaloha>/240827/JPG/BL6A6655.JPG

    Zaloha se vzdy kopiruje (nikdy nepresouva) a vzdy se overuje checksumem.
    V rezimu move se karta maze az pote, co zaloha projde kontrolou.

    Zaloha odpovida nastroji Backup To v importeru Capture One: chrani ORIGINALY
    v podobe, v jake prisly z karty. NECHRANI upravy - ty vznikaji az pri praci
    v Capture One a zijou v podslozkach session (CaptureOne, Settings*), ktere si
    Capture One zaklada sam. Na ty je potreba zalohovat celou slozku session.

VOLBY
    -s, --source DIR     Zdrojova slozka. Prepisuje DEFAULT_SOURCE v hlavicce skriptu.
    -d, --dest DIR       Cilovy koren. Prepisuje DEFAULT_DEST v hlavicce skriptu.
    -b, --backup DIR     Koren zalohy originalu. Prepisuje DEFAULT_BACKUP.
        --no-backup      Vypne zalohu, i kdyz je DEFAULT_BACKUP vyplneny.
    -t, --types LIST     Carkou oddeleny seznam pripon, bez tecky, case-insensitive.
                         Vychozi: CR3,JPG.
    -u, --suffix TEXT    Doplnek k nazvu slozky dne: 240827 -> "240827-CZ, Lipno, ...".
                         Lze jen kdyz import obsahuje prave jeden den poriuzeni.
    -D, --date-source X  auto  = EXIF, pri selhani mtime souboru (vychozi)
                         exif  = jen EXIF, chybejici EXIF je chyba
                         mtime = jen cas souboru, EXIF se necte (rychlejsi)
    -m, --mode NAME      copy = zdroj zustava, move = zdroj se maze az po uspesnem
                         prenosu kazdeho souboru. Prepisuje DEFAULT_MODE v hlavicce.
    -V, --verify         Po prenosu kontrolni porovnani podle checksumu. Jen s --mode copy.
    -j, --json           JSON vystup na stdout dle ansible_ready. Lidsky vystup jde
                         vzdy na stderr, stdout je vyhrazen pro JSON.
    -L, --log FILE       Zapisovat log take do souboru.
    -y, --yes            Neinteraktivni beh (nutne pro --mode move bez terminalu).
    -N, --dry-run        Nic nemeni, jen vypise plan importu.
    -v, --verbose        Vypisovat jednotlive prenasene soubory.
        --version        Vypsat verzi a skoncit.
    -h, --help           Tato napoveda.

EXIT KODY
    0 uspech (i kdyz nebyl nalezen zadny soubor)   3 chyba prenosu (rsync)
    1 chyba parametru / preruseno uzivatelem       4 chyba ciloveho adresare
    2 zdroj nenalezen nebo nejednoznacny           5 chybi zavislost (rsync, sips)

PRIKLADY
    # Bezny import: vse podle DEFAULT_* v hlavicce skriptu, zadne parametry
    import-photos.sh

    # Napred se podivat, co by se stalo
    import-photos.sh --dry-run

    # Jednodenni focení rovnou s popisem v nazvu slozky
    import-photos.sh -u "CZ, Lipno, Vylet parnikem"

    # Presun z karty (karta se po overenem prenosu uvolni)
    import-photos.sh --mode move

    # Neinteraktivni beh s JSON vystupem (ansible_ready)
    import-photos.sh -s /Volumes/EOS_DIGITAL/DCIM -d /data/foto --json --yes
USAGE
}

# Lidsky log. Stdout je rezervovan pro JSON (ansible_ready), proto vse jde na stderr.
# Text logu je anglicky a ASCII-only dle standardu.
log() {
    local level="$1"
    shift
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') [${level}] $*"
    printf '%s\n' "$line" >&2
    if [ -n "$logFile" ]; then
        printf '%s\n' "$line" >>"$logFile"
    fi
}

# JSON facts na stdout, presne ve tvaru predepsanem standardem ansible_ready.
emitJson() {
    local changed="$1"
    local msg="$2"
    if [ "$jsonOutput" -eq 1 ]; then
        # Escapovani zpetnych lomitek a uvozovek, aby zprava neporusila JSON.
        msg="$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        printf '{"changed": %s, "reboot_required": false, "msg": "%s"}\n' "$changed" "$msg"
    fi
}

die() {
    local code="$1"
    shift
    log "ERROR" "$*"
    emitJson "false" "$*"
    exit "$code"
}

cleanup() {
    if [ -n "$tmpDir" ] && [ -d "$tmpDir" ]; then
        rm -rf "$tmpDir"
    fi
}

# ---------------------------------------------------------------------------
# Zpracovani parametru
# ---------------------------------------------------------------------------

parseArgs() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -s|--source)      [ $# -ge 2 ] || die "$EXIT_USAGE" "Option $1 requires a value"; sourceDir="$2"; shift 2 ;;
            -d|--dest)        [ $# -ge 2 ] || die "$EXIT_USAGE" "Option $1 requires a value"; destRoot="$2"; shift 2 ;;
            -b|--backup)      [ $# -ge 2 ] || die "$EXIT_USAGE" "Option $1 requires a value"; backupRoot="$2"; shift 2 ;;
            --no-backup)      backupRoot=""; shift ;;
            -t|--types)       [ $# -ge 2 ] || die "$EXIT_USAGE" "Option $1 requires a value"; fileTypes="$2"; shift 2 ;;
            -u|--suffix)      [ $# -ge 2 ] || die "$EXIT_USAGE" "Option $1 requires a value"; sessionSuffix="$2"; shift 2 ;;
            -D|--date-source) [ $# -ge 2 ] || die "$EXIT_USAGE" "Option $1 requires a value"; dateSource="$2"; shift 2 ;;
            -m|--mode)        [ $# -ge 2 ] || die "$EXIT_USAGE" "Option $1 requires a value"; mode="$2"; shift 2 ;;
            -L|--log)         [ $# -ge 2 ] || die "$EXIT_USAGE" "Option $1 requires a value"; logFile="$2"; shift 2 ;;
            -V|--verify)      doVerify=1; shift ;;
            -j|--json)        jsonOutput=1; shift ;;
            -y|--yes)         assumeYes=1; shift ;;
            -N|--dry-run)     dryRun=1; shift ;;
            -v|--verbose)     verbose=1; shift ;;
            --version)        printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit "$EXIT_OK" ;;
            -h|--help)        usage; exit "$EXIT_OK" ;;
            *)                usage >&2; die "$EXIT_USAGE" "Unknown option: $1" ;;
        esac
    done
}

# Validace vstupu - vse se overuje pred prvni zmenou na disku.
validateArgs() {
    case "$mode" in
        copy|move) ;;
        *) die "$EXIT_USAGE" "Invalid mode: ${mode} (expected copy or move)" ;;
    esac

    case "$dateSource" in
        auto|exif|mtime) ;;
        *) die "$EXIT_USAGE" "Invalid date source: ${dateSource} (expected auto, exif or mtime)" ;;
    esac

    if [ "$doVerify" -eq 1 ] && [ "$mode" = "move" ]; then
        die "$EXIT_USAGE" "Option --verify cannot be combined with --mode move"
    fi

    if [ -z "$fileTypes" ]; then
        die "$EXIT_USAGE" "Option --types must not be empty"
    fi

    # Suffix je soucast nazvu jedne slozky, nikoliv cesta.
    case "$sessionSuffix" in
        */*) die "$EXIT_USAGE" "Session suffix must not contain a slash" ;;
    esac

    command -v rsync >/dev/null 2>&1 || die "$EXIT_DEPENDENCY" "rsync not found in PATH"
    if [ "$dateSource" != "mtime" ]; then
        command -v sips >/dev/null 2>&1 || die "$EXIT_DEPENDENCY" "sips not found in PATH (needed to read EXIF)"
    fi
}

# ---------------------------------------------------------------------------
# Detekce zdroje
# ---------------------------------------------------------------------------

# Najde jediny pripojeny svazek s adresarem DCIM. Vice karet naraz je nejednoznacne
# a resi se explicitnim --source, aby se nikdy neimportovalo z "nejake" karty.
detectSource() {
    local vol
    local found=""
    local count=0

    for vol in /Volumes/*/; do
        [ -d "$vol" ] || continue
        if [ -d "${vol}DCIM" ]; then
            found="${vol}DCIM"
            count=$((count + 1))
        fi
    done

    if [ "$count" -eq 0 ]; then
        die "$EXIT_SOURCE" "No mounted volume with a DCIM folder found - use --source"
    fi
    if [ "$count" -gt 1 ]; then
        die "$EXIT_SOURCE" "Multiple volumes with DCIM found (${count}) - use --source"
    fi

    sourceDir="${found%/}"
    log "INFO" "Source auto-detected: ${sourceDir}"
}

# ---------------------------------------------------------------------------
# Zjisteni dne poriuzeni
# ---------------------------------------------------------------------------

# Precte EXIF datum poriuzeni pro vsechny soubory jedne pripony v jednom adresari.
# sips je soucast macOS a zvlada CR3 i JPG; volani je davkove, protoze spousteni
# jednoho procesu na soubor by u karty s vice sty snimky trvalo desitky sekund.
# Vystup: radky "relativni_nazev|YYMMDD" pro soubory, u kterych se EXIF podarilo precist.
buildExifMap() {
    local dir="$1"
    local rawList="$2"

    ( cd "$dir" && xargs -0 sips -g creation <"$rawList" 2>/dev/null ) | awk '
        # Radek s vlastnosti patri k naposledy vypsanemu souboru.
        /^  creation: / {
            split($2, parts, ":")
            # Platny format je YYYY:MM:DD; sips vraci "<nil>", kdyz EXIF chybi.
            if (parts[1] ~ /^[0-9][0-9][0-9][0-9]$/) {
                printf "%s|%s%s%s\n", currentFile, substr(parts[1], 3, 2), parts[2], parts[3]
            }
            next
        }
        # Radek bez odsazeni je soubor, ktery sips prave zpracovava. POZOR: sips vypisuje
        # ABSOLUTNI cestu i kdyz dostane relativni nazev, takze klic je nutne srovnat
        # na tvar "./nazev", ve kterem jsou polozky seznamu z findu.
        /^[^ ]/ {
            currentFile = $0
            sub(/.*\//, "", currentFile)
            currentFile = "./" currentFile
        }
    '
}

# Datum ze souboroveho casu (BSD stat + date), pouziva se jako fallback.
dayFromMtime() {
    local file="$1"
    local epoch
    epoch="$(stat -f %m "$file")"
    date -r "$epoch" +%y%m%d
}

# ---------------------------------------------------------------------------
# Trideni souboru do skupin den + typ
# ---------------------------------------------------------------------------

# Projde jeden zdrojovy adresar a jednu priponu a rozradi soubory do seznamu
# ${listRoot}/<den>/<TYP>/<poradi_adresare>.list. Seznamy jsou oddelene znakem NUL,
# aby rsync zvladl i nazvy s mezerami.
collectFiles() {
    local dir="$1"
    local ext="$2"
    local index="$3"
    local extUpper
    extUpper="$(printf '%s' "$ext" | tr '[:lower:]' '[:upper:]')"

    local rawList="${tmpDir}/raw.nul"
    local nameList="${tmpDir}/names.txt"
    local exifMap="${tmpDir}/exif.map"
    local mapped="${tmpDir}/mapped.txt"

    # Necitelny adresar (systemove slozky na karte) se preskoci, ne ukonci beh.
    ( cd "$dir" && find . -maxdepth 1 -type f -iname "*.${ext}" -print0 ) >"$rawList" 2>/dev/null || true
    [ -s "$rawList" ] || return 0

    tr '\0' '\n' <"$rawList" >"$nameList"

    : >"$exifMap"
    if [ "$dateSource" != "mtime" ]; then
        buildExifMap "$dir" "$rawList" >"$exifMap"
    fi

    # Ke kazdemu souboru priradi datum z EXIF, nebo znacku "-" kdyz chybi.
    # POZOR: rozliseni souboru pres FILENAME, ne pres NR==FNR - prazdna EXIF mapa
    # (rezim mtime, nebo skupina bez jedineho EXIF) by jinak spolkla cely seznam.
    awk -F'|' 'FILENAME == ARGV[1] { day[$1] = $2; next } { print (day[$0] == "" ? "-" : day[$0]) "|" $0 }' \
        "$exifMap" "$nameList" >"$mapped"

    local day name targetList
    while IFS='|' read -r day name; do
        [ -n "$name" ] || continue
        if [ "$day" = "-" ]; then
            if [ "$dateSource" = "exif" ]; then
                # Nazev nese predponu "./" z findu, v hlasce by delal /./ - odstranit.
                die "$EXIT_SOURCE" "No EXIF creation date in ${dir}/${name#./} (use --date-source auto)"
            fi
            day="$(dayFromMtime "${dir}/${name}")"
        fi
        mkdir -p "${listRoot}/${day}/${extUpper}"
        targetList="${listRoot}/${day}/${extUpper}/${index}.list"
        printf '%s\0' "$name" >>"$targetList"
        totalFiles=$((totalFiles + 1))
    done <"$mapped"
}

# ---------------------------------------------------------------------------
# Cilova struktura
# ---------------------------------------------------------------------------

# Zalozi kostru Capture One session: ctyri podslozky, nic vic.
# Soubory .cosessiondb ani podslozky CaptureOne/Cache/Settings* skript nevytvari -
# ty patri Capture One (overeno v dokumentaci, viz hlavicka souboru).
createSessionSkeleton() {
    local sessionDir="$1"
    local sub

    for sub in $SESSION_FOLDERS; do
        mkdir -p "${sessionDir}/${sub}" || die "$EXIT_DEST" "Cannot create folder: ${sessionDir}/${sub}"
    done
}

# ---------------------------------------------------------------------------
# Prenos
# ---------------------------------------------------------------------------

# Obalka nad rsync - drzi spolecne prepinace na jednom miste.
runRsync() {
    if [ "$verbose" -eq 1 ]; then
        rsync -av "$@"
    else
        rsync -a "$@"
    fi
}

# Kontrolni porovnani podle checksumu. Prazdny vystup = zdroj a cil jsou shodne.
verifyTransfer() {
    local dir="$1"
    local target="$2"
    local listFile="$3"
    local diffOut

    diffOut="$(rsync -rc --dry-run --out-format='%n' --files-from="$listFile" --from0 \
        "${dir}/" "${target}/" 2>/dev/null || true)"

    if [ -n "$diffOut" ]; then
        die "$EXIT_TRANSFER" "Checksum verification failed for ${dir} -> ${target}"
    fi
    log "INFO" "Checksum verification passed for ${dir}"
}

# Ulozi druhou kopii originalu do zalohy. Zaloha se NIKDY nepresouva a VZDY se overuje
# checksumem, protoze je to jedina pojistka proti tomu, aby rezim move smazal kartu
# driv, nez existuje druha ctitelna kopie.
backupGroup() {
    local target="$1"
    local groupDir="$2"
    local listFile index dir rc

    mkdir -p "$target" || die "$EXIT_DEST" "Cannot create backup folder: ${target}"

    for listFile in "$groupDir"/*.list; do
        [ -f "$listFile" ] || continue
        index="$(basename "$listFile" .list)"
        dir="$(cat "${tmpDir}/dir.${index}")"

        rc=0
        runRsync --files-from="$listFile" --from0 "${dir}/" "${target}/" || rc=$?
        [ "$rc" -eq 0 ] || die "$EXIT_TRANSFER" "Backup failed for ${dir} -> ${target} (exit ${rc})"

        verifyTransfer "$dir" "$target" "$listFile"
    done
    log "INFO" "Backup verified: ${target}"
}

# Prenese jednu skupinu (den + typ) do prislusne session.
transferGroup() {
    local target="$1"
    local groupDir="$2"
    local listFile index dir rc count

    mkdir -p "$target" || die "$EXIT_DEST" "Cannot create target folder: ${target}"

    for listFile in "$groupDir"/*.list; do
        [ -f "$listFile" ] || continue
        index="$(basename "$listFile" .list)"
        dir="$(cat "${tmpDir}/dir.${index}")"
        count="$(tr -cd '\0' <"$listFile" | wc -c | tr -d ' ')"

        log "INFO" "Transferring ${count} file(s) from ${dir}"

        rc=0
        if [ "$mode" = "move" ]; then
            runRsync --remove-source-files --files-from="$listFile" --from0 "${dir}/" "${target}/" || rc=$?
        else
            runRsync --files-from="$listFile" --from0 "${dir}/" "${target}/" || rc=$?
        fi
        [ "$rc" -eq 0 ] || die "$EXIT_TRANSFER" "rsync failed for ${dir} -> ${target} (exit ${rc})"

        if [ "$doVerify" -eq 1 ]; then
            verifyTransfer "$dir" "$target" "$listFile"
        fi
    done
}

# ---------------------------------------------------------------------------
# Hlavni bezec
# ---------------------------------------------------------------------------

# Rozradi vsechny soubory na karte do skupin den + typ.
scanSource() {
    local dir ext typeList
    typeList="$(printf '%s' "$fileTypes" | tr ',' ' ')"

    while IFS= read -r dir; do
        dirIndex=$((dirIndex + 1))
        printf '%s' "$dir" >"${tmpDir}/dir.${dirIndex}"
        for ext in $typeList; do
            [ -n "$ext" ] || continue
            collectFiles "$dir" "$ext" "$dirIndex"
        done
    done < <(find "$sourceDir" -type d)
}

# Zalozi jednu session na den a prenese do ni data vsech typu.
processGroups() {
    local dayPath dayName dayFolder extPath extName sessionDir

    for dayPath in "$listRoot"/*/; do
        [ -d "$dayPath" ] || continue
        dayName="$(basename "$dayPath")"

        # Popis udalosti se pripoji k datu: 240827 -> "240827-CZ, Lipno, ...".
        dayFolder="$dayName"
        if [ -n "$sessionSuffix" ]; then
            dayFolder="${dayName}-${sessionSuffix}"
        fi
        sessionDir="${destRoot}/${dayFolder}"

        if [ "$dryRun" -eq 1 ]; then
            log "INFO" "DRY-RUN: would create session ${sessionDir}"
        else
            createSessionSkeleton "$sessionDir"
            log "INFO" "Session ready: ${sessionDir}"
        fi
        sessionCount=$((sessionCount + 1))

        for extPath in "$dayPath"*/; do
            [ -d "$extPath" ] || continue
            extName="$(basename "$extPath")"

            if [ "$dryRun" -eq 1 ]; then
                if [ -n "$backupRoot" ]; then
                    log "INFO" "DRY-RUN: would back up originals to ${backupRoot}/${dayName}/${extName}"
                fi
                log "INFO" "DRY-RUN: would ${mode} files into ${sessionDir}/Capture/${extName}"
                continue
            fi

            # Poradi je zamerne: nejdriv overena zaloha, teprve pak hlavni prenos,
            # ktery v rezimu move zdroj maze. Zaloha se dela pod holym datem bez
            # popisu udalosti, aby zustala stabilni i kdyz slozku dne prejmenujes.
            if [ -n "$backupRoot" ]; then
                backupGroup "${backupRoot}/${dayName}/${extName}" "${extPath%/}"
            fi

            # Typ = podslozka Capture; jedna session na den, typy se nemichaji.
            transferGroup "${sessionDir}/Capture/${extName}" "${extPath%/}"
        done
    done
}

main() {
    parseArgs "$@"
    validateArgs

    log "INFO" "${SCRIPT_NAME} ${SCRIPT_VERSION} started"

    if [ -z "$sourceDir" ]; then
        detectSource
    fi
    sourceDir="${sourceDir%/}"
    [ -d "$sourceDir" ] || die "$EXIT_SOURCE" "Source folder does not exist: ${sourceDir}"

    [ -d "$destRoot" ] || die "$EXIT_DEST" "Destination root does not exist: ${destRoot}"
    destRoot="${destRoot%/}"

    # Cil uvnitr zdroje by pri rezimu move vedl k mazani prave prenesenych souboru.
    if [ "$destRoot" = "$sourceDir" ]; then
        die "$EXIT_DEST" "Destination must not be the source folder"
    fi
    case "$destRoot/" in
        "$sourceDir"/*) die "$EXIT_DEST" "Destination must not be inside the source folder" ;;
    esac

    # Zaloha musi existovat uz pri startu - chybejici cesta typicky znamena odpojeny
    # externi disk, a tise pokracovat bez zalohy je presne to, co se stat nesmi.
    if [ -n "$backupRoot" ]; then
        backupRoot="${backupRoot%/}"
        [ -d "$backupRoot" ] || die "$EXIT_DEST" \
            "Backup root does not exist: ${backupRoot} (disk not mounted? use --no-backup to skip)"
        if [ "$backupRoot" = "$destRoot" ]; then
            die "$EXIT_DEST" "Backup root must differ from destination - a second copy in the same place is not a backup"
        fi
        case "$backupRoot/" in
            "$sourceDir"/*) die "$EXIT_DEST" "Backup root must not be inside the source folder" ;;
            "$destRoot"/*)  die "$EXIT_DEST" "Backup root must not be inside the destination folder" ;;
        esac

        # Tato zaloha plni stejnou roli jako nastroj Backup To v importeru Capture One:
        # soubezna druha kopie originalu pri importu. Capture One k nemu sam uvadi, ze
        # jde o docasnou zalohu, ktera nenahrazuje hlavni zalohovaci strategii, a
        # doporucuje externi disk. Na tomtez svazku jako cil to jednu poruchu disku
        # neprezije, proto upozorneni. Porovnava se ID zarizeni, takze kontrola sama
        # zmlkne, jakmile ze slozky Backup udelas symlink na externi disk ci NAS.
        local backupDevice destDevice
        backupDevice="$(stat -f %d "$backupRoot" 2>/dev/null || printf 'x')"
        destDevice="$(stat -f %d "$destRoot" 2>/dev/null || printf 'y')"
        if [ "$backupDevice" = "$destDevice" ]; then
            log "WARN" "Backup is on the same volume as the destination - temporary copy only, one disk failure loses both"
        fi
    fi

    tmpDir="$(mktemp -d)"
    trap cleanup EXIT
    listRoot="${tmpDir}/groups"
    mkdir -p "$listRoot"

    log "INFO" "Source: ${sourceDir}"
    log "INFO" "Destination: ${destRoot} (mode ${mode}, dates ${dateSource})"

    scanSource

    local msg
    if [ "$totalFiles" -eq 0 ]; then
        msg="No matching files found in ${sourceDir}"
        log "INFO" "$msg"
        emitJson "false" "$msg"
        exit "$EXIT_OK"
    fi

    # Popis udalosti dava smysl jen u jednoho dne - jinak by se stejny text
    # nalepil na vsechny dny a slozky by lhaly.
    local dayCount
    dayCount="$(find "$listRoot" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
    if [ -n "$sessionSuffix" ] && [ "$dayCount" -gt 1 ]; then
        die "$EXIT_USAGE" "Option --suffix needs a single capture day, but ${dayCount} were found"
    fi
    log "INFO" "Found ${totalFiles} file(s) across ${dayCount} capture day(s)"

    # Presun bez zalohy znamena, ze po behu existuje jedina kopie snimku. Neni to zakaz,
    # ale uzivatel to musi vid-et, ne se to dozvedet az kdyz o data prijde.
    if [ "$mode" = "move" ] && [ -z "$backupRoot" ]; then
        log "WARN" "Mode move without a backup - after this run only one copy of the photos will exist"
    fi

    # Rezim move maze data na karte - bez terminalu vyzaduje explicitni --yes.
    if [ "$mode" = "move" ] && [ "$dryRun" -eq 0 ] && [ "$assumeYes" -eq 0 ]; then
        if [ -t 0 ]; then
            printf 'Mode "move" deletes %s file(s) from %s after transfer. Continue? [y/N] ' \
                "$totalFiles" "$sourceDir" >&2
            local answer=""
            read -r answer
            case "$answer" in
                y|Y|yes|YES) ;;
                *) die "$EXIT_USAGE" "Aborted by user" ;;
            esac
        else
            die "$EXIT_USAGE" "Mode move in a non-interactive run requires --yes"
        fi
    fi

    processGroups

    if [ "$dryRun" -eq 1 ]; then
        msg="DRY-RUN: ${totalFiles} file(s) from ${dayCount} day(s) would fill ${sessionCount} session(s)"
        log "INFO" "$msg"
        emitJson "false" "$msg"
        exit "$EXIT_OK"
    fi

    msg="Imported ${totalFiles} file(s) from ${dayCount} day(s) into ${sessionCount} session(s) under ${destRoot} (mode ${mode})"
    log "INFO" "$msg"
    emitJson "true" "$msg"
    exit "$EXIT_OK"
}

main "$@"
