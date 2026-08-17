#!/bin/bash

# export-apps.sh - Export installed apps to YAML
# Author: David Nemecek
# Location: ~/bin/export-apps.sh

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[1;31m'
NC='\033[0m'

log()     { echo -e "${CYAN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" >&2; }
error()   { echo -e "${RED}[ERROR] $1${NC}" >&2; }
success() { echo -e "${GREEN}[SUCCESS] $1${NC}" >&2; }
warn()    { echo -e "${YELLOW}[WARNING] $1${NC}" >&2; }

# Config
BACKUP_DIR="$HOME/.backup"
OUTPUT_FILE="$BACKUP_DIR/apps-$(date +'%Y%m%d').yaml"

# Ensure backup dir exists
mkdir -p "$BACKUP_DIR"

# Check dependencies
check_dependencies() {
    if ! command -v brew &> /dev/null; then
        error "Homebrew is not installed"
        exit 1
    fi
    
    if ! command -v yq &> /dev/null; then
        warn "yq not installed. Installing..."
        brew install yq
    fi
}

# Export formulae
export_formulae() {
    log "Exporting Homebrew formulae..."
    echo "# 1 = install, 0 = skip"
    echo ""
    echo "formulae:"
    brew list --formula -1 | while read -r pkg; do
        echo "  $pkg: 1"
    done
}

# Export casks
export_casks() {
    log "Exporting Homebrew casks..."
    echo ""
    echo "casks:"
    brew list --cask -1 | while read -r pkg; do
        echo "  $pkg: 1"
    done
}

# Export mas apps
export_mas() {
    if command -v mas &> /dev/null; then
        log "Exporting Mac App Store apps..."
        echo ""
        echo "mas:"
        mas list | while read -r line; do
            # Format: 497799835 Xcode (15.0)
            id=$(echo "$line" | awk '{print $1}')
            name=$(echo "$line" | sed 's/^[0-9]* //' | sed 's/ ([^)]*$//')
            echo "  $id: 1    # $name"
        done
    else
        warn "mas not installed - skipping App Store export"
        echo ""
        echo "mas: {}"
    fi
}

# Export manually installed apps (outside brew/mas)
export_manual() {
    log "Detecting manually installed apps..."
    
    # Get brew casks (lowercase for comparison)
    local brew_casks
    brew_casks=$(brew list --cask -1 2>/dev/null | tr '[:upper:]' '[:lower:]')
    
    # Get mas apps
    local mas_apps
    if command -v mas &> /dev/null; then
        mas_apps=$(mas list 2>/dev/null | sed 's/^[0-9]* //' | sed 's/ ([^)]*)$//' | tr '[:upper:]' '[:lower:]')
    else
        mas_apps=""
    fi
    
    echo ""
    echo "# Manually installed apps (informational only - not auto-installed)"
    echo "# Reinstall these from vendor websites"
    echo "manual:"
    
    for app in /Applications/*.app; do
        [ -e "$app" ] || continue
        
        app_name=$(basename "$app" .app)
        app_name_lower=$(echo "$app_name" | tr '[:upper:]' '[:lower:]')
        
        # Skip system apps
        [[ "$app_name" == "Safari" ]] && continue
        [[ "$app_name" == "Mail" ]] && continue
        [[ "$app_name" == "Calendar" ]] && continue
        [[ "$app_name" == "Notes" ]] && continue
        [[ "$app_name" == "Reminders" ]] && continue
        [[ "$app_name" == "Maps" ]] && continue
        [[ "$app_name" == "Photos" ]] && continue
        [[ "$app_name" == "Messages" ]] && continue
        [[ "$app_name" == "FaceTime" ]] && continue
        [[ "$app_name" == "Music" ]] && continue
        [[ "$app_name" == "Podcasts" ]] && continue
        [[ "$app_name" == "TV" ]] && continue
        [[ "$app_name" == "News" ]] && continue
        [[ "$app_name" == "Stocks" ]] && continue
        [[ "$app_name" == "Books" ]] && continue
        [[ "$app_name" == "App Store" ]] && continue
        [[ "$app_name" == "System Preferences" ]] && continue
        [[ "$app_name" == "System Settings" ]] && continue
        
        # Check if in brew casks (fuzzy match)
        local cask_match=0
        echo "$brew_casks" | grep -q "${app_name_lower// /-}" && cask_match=1
        echo "$brew_casks" | grep -q "${app_name_lower// /}" && cask_match=1
        
        # Check if in mas
        local mas_match=0
        echo "$mas_apps" | grep -qi "$app_name_lower" && mas_match=1
        
        # If not in brew or mas, it's manual
        if [ $cask_match -eq 0 ] && [ $mas_match -eq 0 ]; then
            # Get source info
            local source="unknown"
            local codesign_info
            codesign_info=$(codesign -dv "$app" 2>&1 || true)
            
            if echo "$codesign_info" | grep -q "Authority=Apple"; then
                source="apple"
            elif echo "$codesign_info" | grep -q "Authority=Developer ID"; then
                source="identified_developer"
            elif echo "$codesign_info" | grep -q "Authority="; then
                source="signed"
            fi
            
            echo "  \"$app_name\":"
            echo "    source: $source"
            echo "    path: $app"
        fi
    done
}

# Main
main() {
    log "Starting apps export..."
    
    check_dependencies
    
    {
        echo "# Installed apps export - $(date +'%Y-%m-%d')"
        echo "# Host: $(hostname)"
        echo "# macOS: $(sw_vers -productVersion)"
        export_formulae
        export_casks
        export_mas
        export_manual
    } > "$OUTPUT_FILE"
    
    success "Export saved to: $OUTPUT_FILE"
    
    # Stats
    formulae_count=$(grep -c "^  " "$OUTPUT_FILE" | head -1 || echo "0")
    log "Total entries exported"
    
    echo ""
    log "Next steps:"
    echo "  1. Edit $OUTPUT_FILE"
    echo "  2. Set 0 for apps you don't want to install"
    echo "  3. Run: install-apps.sh $OUTPUT_FILE"
}

main "$@"
