# Dokumentace skriptu backup-folders.sh

## Popis
Skript pro ruční zálohu specifických složek a konfiguračních souborů na macOS. Vytváří timestampované zálohy do `~/.backup/` s manifestem a automatickým SQLite checkpoint pro databázové soubory.

## Systémové požadavky
- macOS (testováno na Sonoma/Sequoia)
- sqlite3 (součást macOS)

## Instalace
```bash
chmod +x backup-folders.sh
mv backup-folders.sh ~/bin/
```

## Použití

### Zobrazení konfigurovaných složek
```bash
backup-folders.sh --list
```
Výstup:
```
[EXISTS] Library/Containers/com.microsoft.rdc.macos (15M)
[EXISTS] .ssh (4.0K)
[EXISTS] .zshrc (2.0K)
[MISSING] .Brewfile
```

### Náhled zálohy (dry run)
```bash
backup-folders.sh --dry-run
```

### Provedení zálohy
```bash
backup-folders.sh
```

## Parametry

| Parametr | Popis |
|----------|-------|
| `--list` | Zobrazí složky a jejich velikosti |
| `--dry-run` | Simulace bez provedení změn |
| `--help` | Nápověda |
| (bez parametru) | Provede zálohu |

## Výstup

### Struktura zálohy
```
~/.backup/
└── 20260125_143022/
    ├── manifest.yaml
    ├── Library/
    │   └── Containers/
    │       └── com.microsoft.rdc.macos/
    ├── .ssh/
    ├── .zshrc
    ├── .gitconfig
    └── bin/
```

### Manifest
```yaml
# Backup manifest
date: 2026-01-25T14:30:22+01:00
host: MacBook-Air
macos: 15.2
backed_up: 5
failed: 1
folders:
  - Library/Containers/com.microsoft.rdc.macos
  - .ssh
  - .zshrc
  - .gitconfig
  - bin
```

## Konfigurované složky

Výchozí seznam složek k záloze (uprav v sekci `BACKUP_FOLDERS`):

| Složka | Účel |
|--------|------|
| `windows-app/` | Windows App SQLite DB (3 soubory) |
| `.ssh` | SSH klíče a konfigurace |
| `.zshrc` | Zsh konfigurace |
| `.zprofile` | Zsh profile |
| `.gitconfig` | Git globální konfigurace |
| `.Brewfile` | Homebrew bundle (pokud existuje) |
| `bin` | Vlastní skripty |

### Windows App
Zálohují se pouze SQLite databázové soubory:
- `com.microsoft.rdc.application-data.sqlite`
- `com.microsoft.rdc.application-data.sqlite-shm`
- `com.microsoft.rdc.application-data.sqlite-wal`

Před zálohou se provede WAL checkpoint pro konzistenci.

### Přidání vlastní složky
Uprav pole `BACKUP_FOLDERS` ve skriptu:
```bash
BACKUP_FOLDERS=(
    # ... existující ...
    ".config/něco"
    "Documents/důležitá-složka"
)
```

## Speciální funkce

### SQLite WAL Checkpoint
Pro Windows App skript automaticky provede před zálohou:
```bash
sqlite3 <database> "PRAGMA wal_checkpoint(FULL);"
```
Tím zajistí konzistenci databáze.

## Obnova ze zálohy

### Windows App připojení
```bash
# 1. Nainstaluj Windows App, spusť a zavři

# 2. Obnov SQLite soubory
cp ~/.backup/20260125_143022/windows-app/*.sqlite* \
   ~/Library/Containers/com.microsoft.rdc.macos/Data/Library/Application\ Support/com.microsoft.rdc.macos/

# 3. Spusť Windows App - připojení budou obnovena
# 4. Hesla zadej ručně při prvním připojení
```

### SSH klíče
```bash
cp -R ~/.backup/20260125_143022/.ssh ~/
chmod 700 ~/.ssh
chmod 600 ~/.ssh/id_*
chmod 644 ~/.ssh/*.pub
```

### Konfigurace
```bash
cp ~/.backup/20260125_143022/.zshrc ~/
cp ~/.backup/20260125_143022/.gitconfig ~/
```

## Doporučený workflow

### Před čistou instalací
```bash
# 1. Export aplikací
export-apps.sh

# 2. Záloha složek
backup-folders.sh

# 3. Zkopíruj ~/.backup na externí disk
cp -R ~/.backup /Volumes/External/MacBackup/
```

### Po čisté instalaci
```bash
# 1. Zkopíruj zálohu z externího disku
cp -R /Volumes/External/MacBackup/.backup ~/

# 2. Obnov konfigurace
cp ~/.backup/*/zshrc ~/
cp ~/.backup/*/.gitconfig ~/

# 3. Nainstaluj aplikace
brew install yq mas
install-apps.sh ~/.backup/apps-*.yaml

# 4. Obnov Windows App
# (viz sekce Obnova ze zálohy)
```

## Známé problémy

### Permission denied
Některé složky mohou mít omezená práva. Skript je přeskočí s varováním.

### Windows App běží
Doporučeno zavřít Windows App před zálohou pro konzistenci SQLite databáze.

## Autor
David Němeček | DN | Leden 2026
