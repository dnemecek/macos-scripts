#!/bin/bash

# backup-folders.sh - Backup specific folders to ~/.backup
# Author: David Nemecek
# Location: ~/bin/backup-folders.sh

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

# Config
BACKUP_ROOT="$HOME/.backup"
BACKUP_DIR="$BACKUP_ROOT/$(date +'%Y%m%d_%H%M%S')"

# Folders to backup - relativni k $HOME
# Uprav podle potreby
BACKUP_FOLDERS=(
    # SSH keys
    ".ssh"
    
    # Shell config
    ".zshrc"
    ".zprofile"
    
    # Git config
    ".gitconfig"
    
    # Homebrew bundle (pokud existuje)
    ".Brewfile"
    
    # Custom scripts
    "bin"
)

# Windows App SQLite DB path
WINDOWS_APP_DB_DIR="Library/Containers/com.microsoft.rdc.macos/Data/Library/Application Support/com.microsoft.rdc.macos"
WINDOWS_APP_DB_FILES=(
    "com.microsoft.rdc.application-data.sqlite"
    "com.microsoft.rdc.application-data.sqlite-shm"
    "com.microsoft.rdc.application-data.sqlite-wal"
)

# Usage
usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --list       Show folders that would be backed up"
    echo "  --dry-run    Show what would be done without doing it"
    echo "  --help       Show this help"
    echo ""
    echo "Backup location: $BACKUP_ROOT"
    exit 0
}

# WAL checkpoint for SQLite databases
checkpoint_sqlite() {
    local db_path="$1"
    if [ -f "$db_path" ] && command -v sqlite3 &> /dev/null; then
        log "  Running WAL checkpoint on $(basename "$db_path")..."
        sqlite3 "$db_path" "PRAGMA wal_checkpoint(FULL);" >/dev/null 2>&1 || true
    fi
}

# Backup Windows App SQLite DB
backup_windows_app() {
    local src_dir="$HOME/$WINDOWS_APP_DB_DIR"
    local dest_dir="$BACKUP_DIR/windows-app"
    
    if [ ! -d "$src_dir" ]; then
        warn "  Windows App not found: $src_dir"
        return 1
    fi
    
    # Checkpoint first
    checkpoint_sqlite "$src_dir/com.microsoft.rdc.application-data.sqlite"
    
    # Create dest dir
    mkdir -p "$dest_dir"
    
    # Copy only DB files
    local copied=0
    for file in "${WINDOWS_APP_DB_FILES[@]}"; do
        if [ -f "$src_dir/$file" ]; then
            cp "$src_dir/$file" "$dest_dir/"
            ((copied++))
        fi
    done
    
    if [ $copied -gt 0 ]; then
        success "  Backed up: Windows App ($copied files)"
        return 0
    else
        warn "  No Windows App DB files found"
        return 1
    fi
}

# Backup single folder
backup_folder() {
    local src="$HOME/$1"
    local dest="$BACKUP_DIR/$1"
    
    if [ ! -e "$src" ]; then
        warn "  Not found: $src"
        return 1
    fi
    
    # Create parent dir
    mkdir -p "$(dirname "$dest")"
    
    # Copy
    if [ -d "$src" ]; then
        cp -R "$src" "$dest" 2>/dev/null || true
    else
        cp "$src" "$dest" 2>/dev/null || true
    fi
    
    # Verify something was copied
    if [ -e "$dest" ]; then
        success "  Backed up: $1"
        return 0
    else
        warn "  Failed to backup: $1"
        return 1
    fi
}

# List folders
list_folders() {
    log "Folders configured for backup:"
    echo ""
    
    # Windows App
    local wa_dir="$HOME/$WINDOWS_APP_DB_DIR"
    if [ -d "$wa_dir" ]; then
        local wa_size
        wa_size=$(du -sh "$wa_dir" 2>/dev/null | cut -f1)
        echo "  [EXISTS] Windows App DB ($wa_size)"
    else
        echo "  [MISSING] Windows App DB"
    fi
    
    # Other folders
    for folder in "${BACKUP_FOLDERS[@]}"; do
        local src="$HOME/$folder"
        if [ -e "$src" ]; then
            local size
            size=$(du -sh "$src" 2>/dev/null | cut -f1)
            echo "  [EXISTS] $folder ($size)"
        else
            echo "  [MISSING] $folder"
        fi
    done
    echo ""
    log "Backup location: $BACKUP_ROOT"
}

# Dry run
dry_run() {
    log "DRY RUN - would backup to: $BACKUP_DIR"
    echo ""
    
    # Windows App
    local wa_dir="$HOME/$WINDOWS_APP_DB_DIR"
    if [ -d "$wa_dir" ]; then
        echo "  [WOULD BACKUP] Windows App DB (3 SQLite files)"
    else
        echo "  [SKIP - NOT FOUND] Windows App DB"
    fi
    
    # Other folders
    for folder in "${BACKUP_FOLDERS[@]}"; do
        local src="$HOME/$folder"
        if [ -e "$src" ]; then
            echo "  [WOULD BACKUP] $folder"
        else
            echo "  [SKIP - NOT FOUND] $folder"
        fi
    done
}

# Main backup
do_backup() {
    log "Starting backup to: $BACKUP_DIR"
    
    mkdir -p "$BACKUP_DIR"
    
    local backed_up=0
    local failed=0
    
    # Backup Windows App first
    if backup_windows_app; then
        ((backed_up++)) || true
    else
        ((failed++)) || true
    fi
    
    # Backup other folders
    for folder in "${BACKUP_FOLDERS[@]}"; do
        if backup_folder "$folder"; then
            ((backed_up++)) || true
        else
            ((failed++)) || true
        fi
    done
    
    # Create manifest
    {
        echo "# Backup manifest"
        echo "date: $(date -Iseconds)"
        echo "host: $(hostname)"
        echo "macos: $(sw_vers -productVersion)"
        echo "backed_up: $backed_up"
        echo "failed: $failed"
        echo "folders:"
        if [ -d "$BACKUP_DIR/windows-app" ]; then
            echo "  - windows-app"
        fi
        for folder in "${BACKUP_FOLDERS[@]}"; do
            if [ -e "$BACKUP_DIR/$folder" ]; then
                echo "  - $folder"
            fi
        done
    } > "$BACKUP_DIR/manifest.yaml"
    
    # Calculate total size
    local total_size
    total_size=$(du -sh "$BACKUP_DIR" | cut -f1)
    
    echo ""
    success "Backup completed!"
    log "Location: $BACKUP_DIR"
    log "Size: $total_size"
    log "Backed up: $backed_up, Failed/Missing: $failed"
}

# Parse args
case "${1:-}" in
    --list)
        list_folders
        ;;
    --dry-run)
        dry_run
        ;;
    --help|-h)
        usage
        ;;
    "")
        do_backup
        ;;
    *)
        error "Unknown option: $1"
        usage
        ;;
esac
