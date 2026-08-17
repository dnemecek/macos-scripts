#!/bin/bash
# Stahne skripty z ~/bin zpet do repa (kdyz se editovalo primo v runtime).
# Pouziti: pull-from-bin.sh [--dry-run] [--delete]
#   --dry-run  Pouze zobrazi co by se preneslo, nezapisuje
#   --delete   Smaze v repu bin/*.sh ktere nejsou v ~/bin (zrcadlovy mod)
# Repo je pod gitem, takze pretazena zmena je vzdy dohledatelna v diffu -
# po pull zkontroluj `git status` / `git diff` a commitni.
# Udrzuje: David Nemecek
# Posledni aktualizace: 2026-08-03

set -euo pipefail

readonly scriptDir="$(cd "$(dirname "$0")" && pwd)"
readonly repoBin="${scriptDir}/../bin/"
readonly localBin="${HOME}/bin/"

opts=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) opts="${opts} -n" ;;
        --delete)  opts="${opts} --delete" ;;
        -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 1 ;;
    esac
done

# Explicit whitelist *.sh; editor backupy (*~) nikdy. Prepinac -L dereferencuje
# pripadne symlinky v ~/bin (pozustatek predchoziho modelu) - do repa se vzdy
# ukladaji regularni soubory, nikdy symlink na sebe sama.
# shellcheck disable=SC2086
rsync -avL $opts \
    --exclude='*~' \
    --include='*.sh' \
    --exclude='*' \
    "$localBin" "$repoBin"
