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
| `bin/claude-rc.sh` | Claude Code Remote Control server ve screenu na pozadí (`start`/`attach`/`stop`/`status`), ovládání sessions z mobilu nebo claude.ai/code. Název `<počítač> - <složka>`, počítač lze přepsat `CLAUDE_RC_HOST`. Volitelně jako služba launchd (`install`/`uninstall`), viz níže. |

## claude-rc jako služba (launchd)

`claude-rc.sh install [DIR]` vytvoří LaunchAgent `~/Library/LaunchAgents/cz.nemecek.claude-rc.<složka>.plist`
a načte ho (`launchctl bootstrap gui/<uid>`). Server se pak spustí po každém přihlášení a po pádu
(KeepAlive, pauza 30 s). Běží dál ve screenu, takže `attach` a `status` fungují stejně.

```bash
claude-rc.sh start   ~/Documents/Source/Repos   # 1. první spuštění ve složce ručně
claude-rc.sh attach  ~/Documents/Source/Repos   #    potvrdit důvěru složky a Remote Control, Ctrl-A D
claude-rc.sh stop    ~/Documents/Source/Repos
claude-rc.sh install ~/Documents/Source/Repos   # 2. služba
claude-rc.sh uninstall ~/Documents/Source/Repos # zrušení služby
```

- `stop` službu vyjme z launchd do dalšího přihlášení nebo `start`; trvale ji zruší `uninstall`.
- LaunchAgent běží jen po přihlášení uživatele. Mac bez monitoru po restartu potřebuje
  automatické přihlášení, jinak se server nespustí.
- Log launchd/screen: `~/Library/Logs/cz.nemecek.claude-rc.<složka>.log`.

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
