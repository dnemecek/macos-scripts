#!/bin/bash
# Nahraje skripty z repa do ~/bin (runtime umisteni na tomto Macu).
# Default: DRY-RUN (bezpecny - jen zobrazi co by se preneslo). Pro skutecny push --apply.
# Pouziti: push-to-bin.sh [--apply] [--delete]
#   bez flagu  Dry-run, pouze zobrazi co by se nahralo
#   --apply    Skutecne provede prenos (bez --apply je pouze dry-run)
#   --delete   Smaze v ~/bin *.sh soubory ktere nejsou v repu (zrcadlovy mod;
#              vyzaduje --apply; netyka se souboru mimo whitelist *.sh)
# Udrzuje: David Nemecek
# Posledni aktualizace: 2026-08-03

set -euo pipefail

readonly scriptDir="$(cd "$(dirname "$0")" && pwd)"
readonly repoBin="${scriptDir}/../bin/"
readonly localBin="${HOME}/bin/"

apply=0
delete=0
for arg in "$@"; do
    case "$arg" in
        --apply)  apply=1 ;;
        --delete) delete=1 ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 1 ;;
    esac
done

opts=""
if [ "$apply" -eq 0 ]; then
    opts="${opts} -n"
    echo "*** DRY-RUN -- pro skutecny push pridej --apply ***"
fi
if [ "$delete" -eq 1 ]; then
    if [ "$apply" -eq 0 ]; then
        echo "ERROR: --delete vyzaduje --apply" >&2
        exit 1
    fi
    opts="${opts} --delete"
fi

mkdir -p "$localBin"

# Explicit whitelist *.sh - v ~/bin ziji i dokumentacni .md a jine soubory,
# tech se sync nedotyka. Editor backupy (*~) se neprenaseji nikdy.
# shellcheck disable=SC2086
rsync -av $opts \
    --exclude='*~' \
    --include='*.sh' \
    --exclude='*' \
    "$repoBin" "$localBin"
