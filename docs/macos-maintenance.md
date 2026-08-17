# Dokumentace údržbového skriptu pro macOS

## Popis
Skript pro komplexní údržbu macOS systému. Provádí aktualizace, čištění cache a generuje report o stavu systému. Vyžaduje interakci uživatele pro potvrzení některých operací a zadání administrátorských práv.

## Systémové požadavky
- macOS (testováno na Sonoma/Sequoia 15.1.1)
- Homebrew
- mas (volitelně pro aktualizace App Store)
- Administrátorská práva

## Instalace
1. Stáhněte skript `macos-maintenance.sh`
2. Nastavte práva pro spuštění:
```bash
chmod +x macos-maintenance.sh
```

## Hlavní funkce

### Zálohování
- Vytvoření Time Machine snapshotu před začátkem údržby

### Homebrew
- Aktualizace Homebrew repositáře
- Aktualizace všech balíčků
- Čištění starých verzí
- Kontrola pomocí `brew doctor`
- Aktualizace casks (s potvrzením)

### App Store
- Kontrola a instalace dostupných aktualizací přes `mas`

### Systémová údržba
- Čištění DNS cache
- Bezpečné čištění vybraných cache adresářů
- Verifikace startovacího disku
- Reset QuickLook cache
- Vyčištění neaktivní paměti

### Reportování
Generuje report (`mac_maintenance_report_YYYYMMDD.txt`) obsahující:
- Systémové informace
- Seznam Homebrew balíčků
- Stav disku
- Stav paměti

## Použití

### Spuštění
```bash
./macos-maintenance.sh
```

### Průběh
1. Kontrola závislostí
2. Vytvoření Time Machine snapshotu
3. Homebrew aktualizace
4. App Store aktualizace
5. Systémová údržba
6. Generování reportu

### Interakce
Skript vyžaduje interakci uživatele pro:
- Zadání administrátorského hesla (sudo operace)
- Potvrzení aktualizací casks
- Potvrzení dalších systémových operací

## Výstup
Barevně označené zprávy:
- 🔵 (CYAN) - Informace o průběhu
- 🟢 (GREEN) - Úspěšné operace
- 🟡 (YELLOW) - Varování
- 🔴 (RED) - Chyby

## Bezpečnost
- Vytváří zálohu před započetím operací
- Pracuje pouze s bezpečnými cache adresáři
- Respektuje systémová omezení
- Vyžaduje explicitní potvrzení pro kritické operace

## Známé problémy a řešení

### "Operation not permitted"
- Běžné při čištění cache
- Skript bezpečně přeskočí chráněné soubory

### "Volume could not be unmounted"
- Očekávané chování při verifikaci aktivního systémového disku
- Kontrola proběhne v "live" módu

### App Store aktualizace
- `mas` může mít omezení na novějších verzích macOS
- V případě problémů použijte přímo aplikaci App Store

## Poznámky
- Skript není vhodný pro automatické spouštění kvůli potřebě interakce uživatele
- Doba běhu závisí na velikosti systému a počtu aktualizací
- Report je uložen na ploše pro snadný přístup
