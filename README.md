# apple-scripts

Rodina shell skriptů pro každodenní správu macOS: import fotek, zálohy, údržba a síťová diagnostika.

## Obsah

| Skript | Účel |
|---|---|
| `bin/import-photos.sh` | Import z paměťové karty do složek připravených pro Capture One session. Dělí podle dne pořízení (EXIF) a typu souboru. |
| `bin/backup-folders.sh` | Ruční záloha vybraných složek a konfigurací do `~/.backup/` s manifestem. |
| `bin/export-apps.sh` / `bin/install-apps.sh` | Export instalovaných aplikací do YAML manifestu a instalace z něj na čistém systému. |
| `bin/macos-maintenance.sh` | Údržba macOS — aktualizace, čištění cache, report stavu. |
| `bin/http2-test.sh` | Diagnostika HTTP/2 pro lokalitu. |
| `bin/mtu-discover.sh` | Zjištění MTU k cíli. |
| `bin/claude-rc.sh` | Claude Code Remote Control server ve screenu na pozadí (`start`/`attach`/`stop`/`status`), ovládání sessions z mobilu nebo claude.ai/code. Název `<počítač> - <složka>`, počítač lze přepsat `CLAUDE_RC_HOST`. |

## Nasazení do ~/bin

Runtime = `~/bin` (reálné soubory), zdroj pravdy = toto repo. Sync mezi repem a runtime:

```bash
scripts/push-to-bin.sh --apply   # repo -> ~/bin (bez --apply jen dry-run)
scripts/pull-from-bin.sh         # ~/bin -> repo (po editaci v runtime; pak git diff + commit)
```

Whitelist `*.sh`; editor backupy (`*~`) se nepřenášejí. `docs/` = převzatá dokumentace
skriptů (v `~/bin` jako symlinky); cílové místo dle standardů je BSO.

Výchozí hodnoty (odkud, kam, záloha, kopírovat/přenášet) jsou v bloku `NASTAVENI` v hlavičce
skriptu — vždy nastavené na bezpečnou variantu. Nápověda: `bin/import-photos.sh --help`.

## Dokumentace

Zdroj pravdy = BSO. Tady jen mapa.

Autor: David Němeček
