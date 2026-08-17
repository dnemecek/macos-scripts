# Dokumentace skriptů pro správu aplikací

## Popis
Dvojice skriptů pro export a import instalovaných aplikací na macOS. Umožňuje vytvořit YAML manifest všech nainstalovaných aplikací, upravit ho a následně provést instalaci na novém/čistém systému.

## Systémové požadavky
- macOS (testováno na Sonoma/Sequoia)
- Homebrew
- yq (`brew install yq`)
- mas (volitelně pro App Store aplikace)

## Instalace
```bash
chmod +x export-apps.sh install-apps.sh
mv export-apps.sh install-apps.sh ~/bin/
```

## export-apps.sh

### Účel
Exportuje seznam všech nainstalovaných aplikací do YAML souboru.

### Použití
```bash
export-apps.sh
```

### Výstup
Soubor `~/.backup/apps-YYYYMMDD.yaml` ve formátu:

```yaml
# Installed apps export - 2026-01-25
# Host: MacBook-Air
# macOS: 15.2

# 1 = install, 0 = skip

formulae:
  git: 1
  node: 1
  php: 1

casks:
  visual-studio-code: 1
  docker: 1
  spotify: 1

mas:
  497799835: 1    # Xcode
  409183694: 1    # Keynote
```

### Workflow
1. Spusť `export-apps.sh`
2. Otevři vygenerovaný YAML soubor
3. Změň `1` na `0` u aplikací, které nechceš instalovat
4. Ulož soubor

## install-apps.sh

### Účel
Nainstaluje aplikace ze YAML souboru.

### Použití
```bash
# Náhled co se nainstaluje
install-apps.sh ~/.backup/apps-20260125.yaml --dry-run

# Ostrá instalace
install-apps.sh ~/.backup/apps-20260125.yaml
```

### Parametry
| Parametr | Popis |
|----------|-------|
| `<soubor.yaml>` | Povinný - cesta k YAML souboru |
| `--dry-run` | Volitelný - pouze zobrazí co by se instalovalo |

### Chování
- Přeskakuje již nainstalované aplikace
- Instaluje pouze položky s hodnotou `1`
- Pokračuje i při selhání jednotlivé instalace (s varováním)

## Formát YAML souboru

### Pravidla
- `1` = instalovat
- `0` = přeskočit
- Komentáře začínající `#` jsou ignorovány

### Sekce
| Sekce | Zdroj | Instalace přes |
|-------|-------|----------------|
| `formulae` | `brew list --formula` | `brew install` |
| `casks` | `brew list --cask` | `brew install --cask` |
| `mas` | `mas list` | `mas install` |
| `manual` | `/Applications` mimo brew/mas | Ručně z webu výrobce |

### Sekce manual
Informativní seznam aplikací nainstalovaných mimo brew a App Store:
- Drag & drop instalace
- .dmg / .pkg instalátory
- Přímé stažení z webu výrobce

```yaml
manual:
  "Affinity Photo 2":
    source: identified_developer
    path: /Applications/Affinity Photo 2.app
  "Logitech Options":
    source: identified_developer
    path: /Applications/Logitech Options.app
```

Tyto aplikace se **neinstalují automaticky** - slouží jako checklist pro ruční instalaci.

## Závislosti

### yq
Parser pro YAML soubory.
```bash
brew install yq
```

### mas
CLI pro Mac App Store (volitelné).
```bash
brew install mas
```

## Příklady

### Export před reinstalací
```bash
export-apps.sh
# Edituj ~/.backup/apps-20260125.yaml
# Zkopíruj na externí disk / cloud
```

### Import na novém Macu
```bash
# Nainstaluj Homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Nainstaluj závislosti
brew install yq mas

# Zkopíruj YAML soubor z externího disku
# Spusť instalaci
install-apps.sh ~/apps-20260125.yaml --dry-run
install-apps.sh ~/apps-20260125.yaml
```

## Známé problémy

### mas install selhává
- Některé aplikace vyžadují předchozí nákup/stažení přes App Store
- Řešení: Nainstaluj ručně přes App Store

### cask vyžaduje heslo
- Některé casks vyžadují sudo pro instalaci
- Skript se zeptá na heslo během instalace

## Autor
David Němeček | DN | Leden 2026
