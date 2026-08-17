#!/bin/bash

# install-apps.sh - Install apps from YAML export
# Author: David Nemecek
# Location: ~/bin/install-apps.sh

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[1;31m'
NC='\033[0m'

log()     { echo -e "${CYAN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error()   { echo -e "${RED}[ERROR] $1${NC}"; }
success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }
warn()    { echo -e "${YELLOW}[WARNING] $1${NC}"; }

# Usage
usage() {
    echo "Usage: $0 <apps.yaml> [--dry-run]"
    echo ""
    echo "Options:"
    echo "  --dry-run    Show what would be installed without installing"
    echo ""
    echo "Automatically installs Homebrew, yq and mas if missing."
    exit 1
}

# Check args
if [ -z "$1" ]; then
    usage
fi

YAML_FILE="$1"
DRY_RUN=0

if [ "$2" = "--dry-run" ]; then
    DRY_RUN=1
    warn "DRY RUN mode - no changes will be made"
fi

if [ ! -f "$YAML_FILE" ]; then
    error "File not found: $YAML_FILE"
    exit 1
fi

# Bootstrap - install dependencies if missing
bootstrap() {
    log "Checking dependencies..."
    
    # Homebrew
    if ! command -v brew &> /dev/null; then
        log "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        
        # Add to PATH for Apple Silicon
        if [ -f "/opt/homebrew/bin/brew" ]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        fi
        
        if ! command -v brew &> /dev/null; then
            error "Homebrew installation failed"
            exit 1
        fi
        success "Homebrew installed"
    else
        log "  Homebrew - OK"
    fi
    
    # yq
    if ! command -v yq &> /dev/null; then
        log "Installing yq..."
        brew install yq
        success "yq installed"
    else
        log "  yq - OK"
    fi
    
    # mas
    if ! command -v mas &> /dev/null; then
        log "Installing mas..."
        brew install mas
        success "mas installed"
    else
        log "  mas - OK"
    fi
    
    success "All dependencies ready"
    echo ""
}

# Install formulae
install_formulae() {
    log "Processing Homebrew formulae..."
    
    local pkgs
    pkgs=$(yq '.formulae | to_entries | .[] | select(.value == 1) | .key' "$YAML_FILE" 2>/dev/null)
    
    if [ -z "$pkgs" ]; then
        warn "No formulae marked for installation"
        return
    fi
    
    local count=0
    while IFS= read -r pkg; do
        if brew list --formula | grep -q "^${pkg}$"; then
            log "  $pkg - already installed"
        else
            if [ $DRY_RUN -eq 1 ]; then
                echo "  [DRY] Would install formula: $pkg"
            else
                log "  Installing: $pkg"
                brew install "$pkg" || warn "Failed to install $pkg"
            fi
            ((count++)) || true
        fi
    done <<< "$pkgs"
    
    success "Formulae processed: $count new"
}

# Install casks
install_casks() {
    log "Processing Homebrew casks..."
    
    local pkgs
    pkgs=$(yq '.casks | to_entries | .[] | select(.value == 1) | .key' "$YAML_FILE" 2>/dev/null)
    
    if [ -z "$pkgs" ]; then
        warn "No casks marked for installation"
        return
    fi
    
    local count=0
    while IFS= read -r pkg; do
        if brew list --cask | grep -q "^${pkg}$"; then
            log "  $pkg - already installed"
        else
            if [ $DRY_RUN -eq 1 ]; then
                echo "  [DRY] Would install cask: $pkg"
            else
                log "  Installing: $pkg"
                brew install --cask "$pkg" || warn "Failed to install $pkg"
            fi
            ((count++)) || true
        fi
    done <<< "$pkgs"
    
    success "Casks processed: $count new"
}

# Install mas apps
install_mas() {
    log "Processing Mac App Store apps..."
    
    # Check if signed into App Store
    if ! mas account &> /dev/null; then
        warn "Not signed into App Store - open App Store and sign in first"
        warn "Skipping App Store apps"
        return
    fi
    
    local ids
    ids=$(yq '.mas | to_entries | .[] | select(.value == 1) | .key' "$YAML_FILE" 2>/dev/null)
    
    if [ -z "$ids" ]; then
        warn "No App Store apps marked for installation"
        return
    fi
    
    local count=0
    while IFS= read -r id; do
        if mas list | grep -q "^${id} "; then
            log "  $id - already installed"
        else
            if [ $DRY_RUN -eq 1 ]; then
                echo "  [DRY] Would install App Store app: $id"
            else
                log "  Installing App Store app: $id"
                mas install "$id" || warn "Failed to install $id"
            fi
            ((count++)) || true
        fi
    done <<< "$ids"
    
    success "App Store apps processed: $count new"
}

# Main
main() {
    log "Starting installation from: $YAML_FILE"
    echo ""
    
    bootstrap
    
    install_formulae
    install_casks
    install_mas
    
    echo ""
    success "Installation completed!"
}

main "$@"