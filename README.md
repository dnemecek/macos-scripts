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
| `bin/claude-rc.sh` | Claude Code Remote Control server jako služba launchd: sessions z mobilu nebo claude.ai/code. Název `<počítač> - <složka>`. Config `claude-rc.conf` (vzor `bin/claude-rc.conf.example`). Viz níže. |

## claude-rc jako služba (launchd)

Server běží nad složkou serveru (obsahuje workspaces, výchozí `~/Documents/Source/Repos`).
`install` vytvoří LaunchAgent `~/Library/LaunchAgents/<labelPrefix>.<složka>.plist`; launchd pak
server spustí po každém přihlášení a po pádu (pauza 30 s). Při každém startu launchd volá
`claude-rc.sh run DIR`, který ověří složku serveru a pak se nahradí procesem `claude remote-control`.

```bash
cp bin/claude-rc.conf.example ~/bin/claude-rc.conf   # config vedle skriptu, upravit hostName
claude-rc.sh init        # 1. první spuštění ve složce: potvrdit důvěru a Remote Control, pak Ctrl+C
claude-rc.sh install     # 2. služba (instalovat z ~/bin, plist ukazuje na cestu skriptu)
claude-rc.sh status      # stav, PID, poslední exit code; chybějící složku označí MISSING
claude-rc.sh restart | stop | start
claude-rc.sh uninstall   # zrušení služby
```

- Config: řádky `klíč=hodnota` (`serverDir`, `hostName`, `labelPrefix`), soubor se nespouští.
  Pořadí: parametr DIR > proměnná prostředí (`CLAUDE_RC_DIR`, `CLAUDE_RC_HOST`, `CLAUDE_RC_LABEL`)
  > config > výchozí hodnota. Změna `hostName` nebo `labelPrefix` platí až po `install`.
- Bez terminálu se `claude remote-control` nemůže zeptat na důvěru složky a skončí chybou
  `Workspace not trusted`; proto nejdřív `init`.
- `stop` službu vyjme z launchd do dalšího přihlášení nebo `start`; trvale ji zruší `uninstall`.
  `stop`, `uninstall` a `status` fungují i pro smazanou složku serveru.
- LaunchAgent běží jen po přihlášení uživatele. Mac bez monitoru po restartu potřebuje
  automatické přihlášení, jinak se server nespustí.
- Log: `~/Library/Logs/<labelPrefix>.<složka>.log` (práva 600, obsahuje odkazy na sessions).

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
