#!/bin/bash

# --- Configuration ---
# Set to true to create a compressed tar archive of the backup directory
ARCHIVE=true
ARCHIVE_FORMAT="xz" # or "gz" for gzip
ARCHIVE_NAME="ubuntu-backup"

# List of user home directory items to explicitly INCLUDE for config/dotfile backup
# Be selective! Avoid large data directories like .cache, .local/share/Steam, etc.
# Use relative paths from the user's home directory.
CONFIG_ITEMS=(
    ".bashrc"
    ".profile"
    ".zshrc"
    ".config"             # Generic config directory (can contain large data, see EXCLUDES below)
    ".ssh"                # SSH configs and keys (sensitive!)
    ".gnupg"              # GPG keys (sensitive!)
    ".mozilla/firefox"    # Firefox profiles (can be large) - considers all profiles
    ".thunderbird"        # Thunderbird profiles (can be large)
    ".local/share/keyrings" # GNOME Keyring
    ".bash_aliases"
    ".selected_editor"
    ".dircolors"
    # Add other specific dotfiles or directories you need backed up
    # ".mycustomapprc"
    # ".local/share/mycustomapp"
)

# List of patterns to EXCLUDE from the CONFIG_ITEMS directories using rsync's --exclude
# These help avoid large data/cache within potentially included config directories like .config or browser profiles
EXCLUDE_PATTERNS=(
    "*/.cache/*"          # Exclude all cache directories
    "*/cache/*"           # Exclude other cache directories (e.g., inside .config)
    "*.log"               # Exclude log files
    "*/tmp/*"             # Exclude temporary directories
    "*/Trash/*"           # Exclude trash directories
    "*/Code/User/globalStorage/*" # VS Code large storage
    "*/Code/User/workspaceStorage/*" # VS Code large storage
    "*/slack/Cache/*"     # Slack cache
    "*/discord/Cache/*"   # Discord cache
    "*/zoom/data/*"       # Zoom data (can be large)
    "*/electron/Cache/*"  # Electron app caches
    "*/npm/*"             # Node.js package cache/installs in home
    "*/yarn/*"            # Yarn package cache
    "*/go/*"              # Go build cache
    "*/pip/*"             # Python pip cache
    "*/gradle/*"          # Gradle cache
    "*/.var/*"            # Flatpak data (usually large)
    "*/Steam/*"           # Steam data
    "*/lutris/runners/*"  # Lutris runners/games
    "*/Games/*"           # General Games directories
    "*/.local/share/Trash/*"
    "*/.local/share/icc/*" # Color profiles
    "*/.local/share/gvfs-metadata/*" # GVFS metadata
    "*/.local/share/webkitgtk/*" # Webkit cache
    "*/.local/share/flatpak/*" # Flatpak data (redundant if .var is excluded, but safer)
    "*/.local/share/containers/*" # Podman/Buildah data
    "*/.local/share/libvirt/*" # libvirt data
    "*/.local/state/*"    # XDG State directory
    "*/.pki/nssdb/*"      # NSS database (can be regenerated)
    "*/.vscode/extensions/*" # VS Code extensions (can be reinstalled)
)

# --- Script Starts Here ---

# Enable strict mode: exit immediately if a command exits with a non-zero status,
# exit if using an unset variable, and fail if any command in a pipeline fails.
set -euo pipefail

# Define the backup directory (temporary if archiving)
BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
if [ "$ARCHIVE" = true ]; then
    # Create a temporary directory for building the archive content
    # Using a temporary directory ensures partial backups don't clutter things if archiving fails
    BACKUP_ROOT=$(mktemp -d -t ubuntu-backup-XXXXXXXXXX)
    BACKUP_DIR="$BACKUP_ROOT/ubuntu-backup-${BACKUP_TIMESTAMP}"
else
    # Create the final backup directory directly
    BACKUP_DIR="$HOME/ubuntu-backup-${BACKUP_TIMESTAMP}"
fi

# Ensure the final backup directory structure exists within the root
mkdir -p "$BACKUP_DIR"

# --- Helper Functions ---

log_info() {
    echo "🔵 $(date +'%H:%M:%S') $1"
}

log_success() {
    echo "✅ $(date +'%H:%M:%S') $1"
}

log_warning() {
    echo "🟡 $(date +'%H:%M:%S') $1" >&2
}

log_error() {
    echo "🔴 $(date +'%H:%M:%S') $1" >&2
    exit 1 # Exit on critical errors
}

check_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log_error "Required command '$1' not found. Please install it."
    fi
}

run_rsync() {
    local src="$1"
    local dest="$2"
    local excludes=("${@:3}") # Get the rest of the arguments as excludes

    log_info "Backing up $(basename "$src")..."
    mkdir -p "$dest" || log_error "Failed to create directory $dest"

    local rsync_cmd=(rsync -avh --delete-excluded) # --delete-excluded removes files from dest that match exclude patterns
    for excl in "${excludes[@]}"; do
        rsync_cmd+=(--exclude="$excl")
    done
    rsync_cmd+=("$src" "$dest")

    # Add --progress only if not archiving, as it can be noisy and less useful during archive prep
    # if [ "$ARCHIVE" != true ]; then
    #    rsync_cmd+=(--progress) # Uncomment if you want progress even when archiving
    # fi

    if ! "${rsync_cmd[@]}"; then
        log_warning "rsync failed for $src. Continuing with other backups."
        # Optionally log the failure more prominently or exit
        # log_error "rsync failed for $src" # Uncomment to stop on any rsync failure
    else
        log_success "Backed up $(basename "$src")."
    fi
}

# --- Main Backup Logic ---

log_info "🚀 Starting backup process."
log_info "Backup content will be stored in: ${BACKUP_DIR} (temporary if archiving)"

# Check for essential commands
check_command "rsync"
check_command "crontab"
check_command "dpkg"
# snap and flatpak are optional, handle missing commands gracefully
# dconf is optional, handle missing gracefully

# --- 1. Backup specified user configuration items (dotfiles, etc.) ---
log_info "📁 Backing up specified user configuration items..."
for item in "${CONFIG_ITEMS[@]}"; do
    if [ -e "$HOME/$item" ]; then # Check if the item exists (file or directory)
        run_rsync "$HOME/$item" "$BACKUP_DIR/home-config/" "${EXCLUDE_PATTERNS[@]}"
    else
        log_info "$HOME/$item not found, skipping."
    fi
done
log_success "Finished backing up user configuration items."

# --- 2. Backup user-level cron jobs ---
log_info "🕒 Backing up user cron jobs..."
mkdir -p "$BACKUP_DIR/cronjobs" || log_error "Failed to create cronjobs directory"
if crontab -l > "$BACKUP_DIR/cronjobs/crontab.bak" 2>/dev/null; then
    log_success "User cron jobs backed up."
else
    log_info "No user cron jobs found or error accessing them."
    # Create an empty file to indicate this section was attempted
    touch "$BACKUP_DIR/cronjobs/crontab.bak.empty"
fi

# --- 3. Backup system-wide cron jobs (Requires sudo) ---
log_info "🛡️ Backing up system-wide cron jobs (requires sudo)..."
mkdir -p "$BACKUP_DIR/system-cron" || log_error "Failed to create system-cron directory"
# Check if sudo works without password for this command (optional but nice)
if sudo -n true 2>/dev/null; then
    # Passwordless sudo available, proceed directly
    if sudo rsync -avh /etc/cron* "$BACKUP_DIR/system-cron/"; then
         log_success "System-wide cron jobs backed up."
    else
         log_warning "sudo rsync failed for system cron jobs. Check permissions or sudo setup."
         # Optionally exit here if system cron backup is critical
         # log_error "System-wide cron backup failed."
    fi
elif sudo true 2>/dev/null; then
    # Sudo requires password, let it prompt or inform user
    log_info "Sudo password may be required for system cron backup."
     if sudo rsync -avh /etc/cron* "$BACKUP_DIR/system-cron/"; then
         log_success "System-wide cron jobs backed up."
    else
         log_warning "sudo rsync failed for system cron jobs after prompt. Check permissions or password."
    fi
else
    log_warning "sudo command not available or user not in sudoers file. Cannot backup system cron jobs."
fi


# --- 4. Backup shell history ---
log_info "📜 Backing up shell history..."
mkdir -p "$BACKUP_DIR/shell-history" || log_error "Failed to create shell-history directory"

declare -A history_files
history_files["bash"]="$HOME/.bash_history"
history_files["zsh"]="$HOME/.zsh_history"
history_files["fish"]="$HOME/.local/share/fish/fish_history" # Fish keeps history here by default

backed_up_history=false
for shell in "${!history_files[@]}"; do
    hist_path="${history_files[$shell]}"
    if [ -f "$hist_path" ]; then
        if cp "$hist_path" "$BACKUP_DIR/shell-history/${shell}_history.bak"; then
            log_success "Backed up ${shell} history."
            backed_up_history=true
        else
            log_warning "Failed to backup ${shell} history ($hist_path)."
        fi
    fi
done
if [ "$backed_up_history" = false ]; then
    log_info "No common shell history files found."
    touch "$BACKUP_DIR/shell-history/history.bak.empty"
fi


# --- 5. Backup installed package lists ---
log_info "📦 Backing up package lists..."
mkdir -p "$BACKUP_DIR/package-lists" || log_error "Failed to create package-lists directory"

# APT packages
if command -v dpkg >/dev/null 2>&1; then
    if dpkg --get-selections > "$BACKUP_DIR/package-lists/dpkg-selections.list"; then
        log_success "Backed up APT package list."
    else
        log_warning "Failed to backup APT package list."
    fi
else
    log_info "dpkg not found, skipping APT package list backup."
fi

# Snap packages
if command -v snap >/dev/null 2>&1; then
    if snap list > "$BACKUP_DIR/package-lists/snap-packages.list"; then
        log_success "Backed up Snap package list."
    else
        log_warning "Failed to backup Snap package list."
    fi
else
    log_info "snap not found, skipping Snap package list backup."
fi

# Flatpak packages
if command -v flatpak >/dev/null 2>&1; then
     if flatpak list > "$BACKUP_DIR/package-lists/flatpak-packages.list"; then
        log_success "Backed up Flatpak package list."
    else
        log_warning "Failed to backup Flatpak package list."
    fi
else
    log_info "flatpak not found, skipping Flatpak package list backup."
fi


# --- 6. Backup custom scripts from ~/bin ---
if [ -d "$HOME/bin" ]; then
    run_rsync "$HOME/bin/" "$BACKUP_DIR/custom-scripts/"
else
    log_info "$HOME/bin not found, skipping custom scripts backup."
fi

# --- 7. Backup GNOME settings (if applicable) ---
if command -v dconf >/dev/null 2>&1; then
    log_info "🖥️ Backing up GNOME settings..."
    mkdir -p "$BACKUP_DIR/gnome-settings" || log_error "Failed to create gnome-settings directory"
    if dconf dump / > "$BACKUP_DIR/gnome-settings/dconf-settings.ini"; then
        log_success "GNOME settings backed up."
    else
        log_warning "Failed to backup GNOME settings."
    fi
else
    log_info "dconf not found, skipping GNOME settings backup."
fi

# --- 8. Backup systemd user services ---
if [ -d "$HOME/.config/systemd/user" ]; then
    run_rsync "$HOME/.config/systemd/user/" "$BACKUP_DIR/systemd-user/"
else
    log_info "$HOME/.config/systemd/user not found, skipping systemd user services backup."
fi


# --- Archiving ---
if [ "$ARCHIVE" = true ]; then
    log_info "📦 Creating archive..."

    # Trap to clean up temporary directory on exit (success or failure)
    # Make sure this trap is set *after* the temp dir is created
    cleanup_temp_dir() {
        log_info "Cleaning up temporary directory ${BACKUP_ROOT}..."
        if [ -d "$BACKUP_ROOT" ]; then
             # Use '|| true' to prevent the trap itself from failing if rm fails
            rm -rf "$BACKUP_ROOT" || true
            log_info "Temporary directory cleaned up."
        fi
    }
    # Trap on EXIT (script finished) or ERR (non-zero exit status)
    trap cleanup_temp_dir EXIT
    trap cleanup_temp_dir ERR # Might be redundant with set -e, but safer

    ARCHIVE_FILE="$HOME/${ARCHIVE_NAME}-${BACKUP_TIMESTAMP}.tar.${ARCHIVE_FORMAT}"
    ARCHIVE_CMD=("tar" "cJf" "$ARCHIVE_FILE" "-C" "$BACKUP_ROOT" "$(basename "$BACKUP_DIR")")

    # Use J for xz, z for gzip
    if [ "$ARCHIVE_FORMAT" == "gz" ]; then
        ARCHIVE_CMD=("tar" "czf" "$ARCHIVE_FILE" "-C" "$BACKUP_ROOT" "$(basename "$BACKUP_DIR")")
        check_command "gzip"
    elif [ "$ARCHIVE_FORMAT" == "xz" ]; then
        ARCHIVE_CMD=("tar" "cJf" "$ARCHIVE_FILE" "-C" "$BACKUP_ROOT" "$(basename "$BACKUP_DIR")")
        check_command "xz"
    else
        log_error "Invalid ARCHIVE_FORMAT '$ARCHIVE_FORMAT'. Use 'gz' or 'xz'."
    fi

    log_info "Archiving to $ARCHIVE_FILE..."
    if "${ARCHIVE_CMD[@]}"; then
        log_success "Archive created successfully at $ARCHIVE_FILE."
        # Temp directory will be cleaned up by the trap on exit
    else
        # The trap will run due to set -e on tar failure
        log_error "Failed to create archive. Backup contents left in temporary directory: $BACKUP_DIR (will be cleaned up)."
        # Note: The trap message might appear after this depending on shell execution
    fi
else
    # No archiving, backup is in the final directory
    log_success "Backup completed successfully at $BACKUP_DIR."
fi

log_info "✨ Backup process finished."
