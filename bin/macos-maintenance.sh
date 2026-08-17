#!/bin/bash

# Error handling: NEobalujeme celý skript do `set -e`, protože údržbový
# skript má být odolný — když selže jeden úklidový krok (brew doctor,
# diskutil, mas...), má pokračovat dál, ne skončit uprostřed.
# Nezachycené chyby v rourách hlásíme, ať nezůstanou skryté.
set -o pipefail

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[1;31m'
NC='\033[0m'

# Logger functions
log() {
    echo -e "${CYAN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

success() {
    echo -e "${GREEN}[SUCCESS] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

# Check dependencies
check_dependencies() {
    log "Checking dependencies..."
    if ! command -v brew &> /dev/null; then
        error "Homebrew is not installed. Please install it first."
        exit 1
    fi
}

# Homebrew maintenance
update_homebrew() {
    log "Updating Homebrew..."
    brew update || warn "brew update encountered issues (continuing)"

    log "Upgrading Homebrew packages..."
    brew upgrade || warn "brew upgrade encountered issues (continuing)"

    log "Cleaning up Homebrew..."
    brew cleanup -s || warn "brew cleanup encountered issues (continuing)"

    # `brew doctor` vrací nenulový kód i u neškodných varování — nesmí
    # shodit zbytek skriptu, proto || true.
    log "Running Homebrew doctor..."
    brew doctor || warn "brew doctor reported warnings (this is normal, continuing)"

    log "Checking for outdated casks..."
    OUTDATED_CASKS=$(brew outdated --cask 2>/dev/null || true)
    if [ -n "$OUTDATED_CASKS" ]; then
        echo "Outdated casks:"
        echo "$OUTDATED_CASKS"
        # Interaktivní dotaz jen když skript běží v terminálu; jinak přeskoč.
        if [ -t 0 ]; then
            read -r -p "Do you want to upgrade outdated casks? (y/n) " -n 1 REPLY
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                brew upgrade --cask || warn "Some casks could not be upgraded (check App Management permissions)"
            fi
        else
            warn "Non-interactive shell; skipping cask upgrade prompt"
        fi
    else
        success "No outdated casks found"
    fi
}

# Mac App Store maintenance
update_mas() {
    if command -v mas &> /dev/null; then
        log "Checking Mac App Store updates..."
        
        OUTDATED=$(mas outdated 2>/dev/null || true)
        if [ -n "$OUTDATED" ]; then
            log "Found outdated App Store apps:"
            echo "$OUTDATED"
            log "Upgrading App Store apps..."
            mas upgrade || warn "mas upgrade encountered issues (continuing)"
        else
            success "No App Store updates available"
        fi
    else
        warn "mas CLI not found. Install with: brew install mas"
    fi
}

# System maintenance
system_maintenance() {
    log "Running system maintenance tasks..."
    
    log "Flushing DNS cache..."
    sudo dscacheutil -flushcache || warn "Could not flush DNS cache"
    sudo killall -HUP mDNSResponder || warn "Could not restart mDNSResponder"

    log "Cleaning safe-to-remove caches..."
    # Seznam bezpečných cache adresářů
    SAFE_CACHE_DIRS=(
        "$HOME/Library/Caches/Homebrew"
        "$HOME/Library/Caches/pip"
        "$HOME/Library/Caches/com.apple.dt.Xcode"
    )

    for dir in "${SAFE_CACHE_DIRS[@]}"; do
        # Dvojitá pojistka proti smazání něčeho nechtěného:
        # proměnná nesmí být prázdná A musí to být existující adresář.
        if [ -n "$dir" ] && [ -d "$dir" ]; then
            log "Cleaning: $dir"
            rm -rf "${dir:?}"/* 2>/dev/null || warn "Could not fully clean $dir"
        fi
    done

    # Pozn.: `diskutil verifyVolume /` na běžícím systému (primární APFS
    # svazek připojený pro zápis) skoro vždy vrací chybu/varování, je to
    # jen šum — kontrolu tu vynecháváme. Ověřit disk lze v Disk Utility
    # nebo z recovery módu.

    log "Resetting QuickLook cache..."
    qlmanage -r cache >/dev/null 2>&1 || warn "Could not reset QuickLook cache"

    log "Purging inactive memory..."
    sudo purge || warn "Could not purge inactive memory"

    success "System maintenance completed"
}

# Generate report
generate_report() {
    local report_file="$HOME/Desktop/mac_maintenance_report_$(date +'%Y%m%d').txt"
    
    log "Generating system report..."

    # Nejdřív ověříme, že na Desktop vůbec lze zapsat — tím testujeme
    # skutečnou zapisovatelnost, ne exit kód posledního příkazu v bloku.
    if ! : > "$report_file" 2>/dev/null; then
        error "Could not write report to $report_file"
        return 1
    fi

    {
        echo "=== Mac Maintenance Report ==="
        echo "Date: $(date)"
        echo
        echo "=== System Info ==="
        system_profiler SPSoftwareDataType 2>/dev/null || echo "(system_profiler unavailable)"
        echo
        echo "=== Homebrew Packages ==="
        brew list --versions 2>/dev/null || echo "(brew list unavailable)"
        echo
        echo "=== Disk Space ==="
        df -h /
        echo
        echo "=== Memory Status ==="
        vm_stat
    } >> "$report_file"

    success "Report generated at: $report_file"
}

# Main execution
main() {
    # Odmítni běh jako root: Homebrew se pod rootem odmítne spustit
    # ("Running Homebrew as root is extremely dangerous"). Root příkazy
    # uvnitř skriptu (dscacheutil, killall, purge) si o sudo řeknou samy.
    if [ "$EUID" -eq 0 ]; then
        error "Nespouštěj tento skript přes sudo. Homebrew nesmí běžet jako root."
        error "Spusť ho normálně: ./macos-maintenance.sh — o heslo si řekne sám, kde je potřeba."
        exit 1
    fi

    log "Starting Mac maintenance script..."

    check_dependencies
    
    # Create backup point
    log "Creating Time Machine backup point..."
    tmutil snapshot || warn "Could not create Time Machine snapshot (continuing)"
    
    update_homebrew
    update_mas
    system_maintenance
    generate_report
    
    success "Maintenance completed successfully!"
}

# Execute main function
main "$@"
