#!/bin/bash

# ==============================================================================
# Ubuntu User and Configuration Backup Script
# ==============================================================================
# This script backs up essential user configurations, dotfiles, package lists,
# and selected system configuration files on an Ubuntu system.
# It is NOT a full system backup and does NOT include user data like Documents,
# Pictures, Videos, etc.
#
# Restore is a MANUAL process and depends on the item being restored.
#
# ==============================================================================
# --- Configuration ---
# ==============================================================================

# Backup location: Where the final archive or directory will be placed.
# Defaults to the user's home directory.
BACKUP_DEST_DIR="$HOME"

# Archiving: Set to true to create a compressed tar archive of the backup directory.
# Set to false to leave the backup as a directory tree.
ARCHIVE=true
ARCHIVE_FORMAT="xz" # or "gz" for gzip. 'xz' provides better compression, 'gz' is faster.
ARCHIVE_NAME="ubuntu-config-backup" # Base name for the archive file/directory

# User configuration items (dotfiles and dot-directories) to explicitly INCLUDE.
# Be selective! Avoid large data directories like .cache, .local/share/Steam, etc.
# Use paths relative to the user's home directory (~).
# These items will be backed up using rsync with the EXCLUDE_PATTERNS applied.
# Add paths line by line, separated by spaces or newlines.
# Example: ".bashrc" ".config/myapp" ".local/share/anotherapp"
# Note: If you include a directory here, items in EXCLUDE_PATTERNS *within* it will be skipped.
USER_CONFIG_RSYNC_ITEMS=(
    ".bashrc"
    ".profile"
    ".zshrc"
    ".config"               # Generic config directory (apply EXCLUDE_PATTERNS)
    ".ssh"                  # SSH configs and keys (sensitive!)
    ".gnupg"                # GPG keys (sensitive!)
    ".mozilla/firefox"      # Firefox profiles (apply EXCLUDE_PATTERNS) - considers all profiles
    ".thunderbird"          # Thunderbird profiles (apply EXCLUDE_PATTERNS)
    ".local/share/keyrings" # GNOME Keyring
    ".bash_aliases"
    ".selected_editor"
    ".dircolors"
    ".themes"               # User-installed themes (can be large, relies on excludes)
    ".icons"                # User-installed icons (can be large, relies on excludes)
    ".fonts"                # User-installed fonts
    ".local/share/applications" # Custom .desktop files
    ".config/autostart"     # Startup applications
    # Add other specific directories/dotfiles you need backed up via rsync:
    # ".vscode"             # VS Code config (relies on excludes for extensions/storage)
    # ".gitconfig"          # Git user config file (can also add to USER_CONFIG_COPY_ITEMS)
)

# List of specific user configuration FILES or SMALL DIRECTORIES to copy directly.
# These items will be copied using 'cp -a'. No excludes are applied here.
# Useful for individual dotfiles or small directories that don't need rsync logic.
# Add paths line by line, separated by spaces or newlines.
USER_CONFIG_COPY_ITEMS=(
    ".gitconfig"
    ".vimrc"
    ".tmux.conf"
    ".screenrc"
    ".Xresources"
    ".gtkrc-2.0"
    ".config/mimeapps.list"
    ".editorconfig"
    # Add other specific dotfiles or small directories to copy:
    # ".mycustomapprc"
    # ".myotherconfigdir"
)


# List of patterns to EXCLUDE from the USER_CONFIG_RSYNC_ITEMS directories using rsync's --exclude.
# These help avoid large data/cache/temp files within potentially included config directories.
# Patterns are relative to the source directory being rsynced (e.g., if backing up .config,
# an exclude like "*/cache/*" will match .config/app/cache).
EXCLUDE_PATTERNS=(
    "*/.cache/*"            # Exclude all cache directories
    "*/cache/*"             # Exclude other cache directories (e.g., inside .config)
    "*.log"                 # Exclude log files
    "*/tmp/*"               # Exclude temporary directories
    "*/Trash/*"             # Exclude trash directories
    "*/Code/User/globalStorage/*" # VS Code large storage
    "*/Code/User/workspaceStorage/*" # VS Code large storage
    "*/slack/Cache/*"       # Slack cache
    "*/discord/Cache/*"     # Discord cache
    "*/zoom/data/*"         # Zoom data (can be large)
    "*/electron/Cache/*"    # Electron app caches
    "*/npm/*"               # Node.js package cache/installs in home
    "*/yarn/*"              # Yarn package cache
    "*/go/*"                # Go build cache
    "*/pip/*"               # Python pip cache
    "*/gradle/*"            # Gradle cache
    "*/.var/*"              # Flatpak data (usually large)
    "*/Steam/*"             # Steam data
    "*/lutris/runners/*"    # Lutris runners/games
    "*/Games/*"             # General Games directories
    "*/.local/share/Trash/*"
    "*/.local/share/icc/*"   # Color profiles
    "*/.local/share/gvfs-metadata/*" # GVFS metadata
    "*/.local/share/webkitgtk/*" # Webkit cache
    "*/.local/share/flatpak/*" # Flatpak data (redundant if .var is excluded, but safer)
    "*/.local/share/containers/*" # Podman/Buildah data
    "*/.local/share/libvirt/*" # libvirt data
    "*/.local/state/*"      # XDG State directory
    # NSS database (can be regenerated) <--- Moved comment UP
    "*/.pki/nssdb/*"
    # VS Code extensions (can be reinstalled) <--- Moved comment UP
    "*/.vscode/extensions/*"
    # Common directory for dependencies <--- Moved comment UP
    "*/vendor/*"
    # Node.js dependencies <--- Moved comment UP
    "*/node_modules/*"
)

# List of system configuration files and directories to back up.
# These REQUIRE sudo privileges. Select carefully.
# Add paths line by line, separated by spaces or newlines.
SYSTEM_CONFIG_ITEMS=(
    "/etc/fstab"
    "/etc/hosts"
    "/etc/hostname"
    "/etc/resolv.conf" # Note: Often a symlink, backs up the target
    "/etc/netplan"       # Netplan network configuration
    "/etc/network/interfaces" # Older network config style
    "/etc/default"       # Default settings for many services/commands
    "/etc/environment"
    "/etc/sysctl.conf"
    "/etc/sysctl.d"
    "/etc/sudoers"       # VERY SENSITIVE! Handle with care.
    "/etc/sudoers.d"     # Custom sudo rules
    "/etc/apt/sources.list"
    "/etc/apt/sources.list.d"
    "/etc/ufw"           # UFW firewall configuration files
    "/etc/ssh/sshd_config" # SSH server configuration
    "/etc/lightdm"       # LightDM display manager config
    "/etc/gdm3"          # GDM3 display manager config
    "/etc/default/grub"  # GRUB bootloader config
    "/etc/X11/xorg.conf" # X.org server config (often not present)
    "/etc/X11/xorg.conf.d" # X.org server config snippets
    # Add other system-wide config files/directories you need backed up:
    # "/etc/myapp.conf"
    # "/etc/security/limits.conf"
)

# ==============================================================================
# --- Script Starts Here ---
# ==============================================================================

# Enable strict mode: exit immediately if a command exits with a non-zero status,
# exit if using an unset variable, and fail if any command in a pipeline fails.
set -euo pipefail

# --- Variables ---
BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
FINAL_BACKUP_NAME="${ARCHIVE_NAME}-${BACKUP_TIMESTAMP}"

# Determine the root directory where backup content is built.
# If archiving, this is a temporary directory. If not, it's the final destination.
if [ "$ARCHIVE" = true ]; then
    # Create a temporary directory for building the archive content
    # Using a temporary directory ensures partial backups don't clutter things if archiving fails
    BACKUP_ROOT=$(mktemp -d -t "${ARCHIVE_NAME}-XXXXXXXXXX")
    log_info "Building backup content in temporary directory: ${BACKUP_ROOT}"
    # The actual backup directory *within* the temp root
    BACKUP_DIR="$BACKUP_ROOT/$FINAL_BACKUP_NAME"
else
    # Create the final backup directory directly in the destination
    BACKUP_DIR="$BACKUP_DEST_DIR/$FINAL_BACKUP_NAME"
fi

# Ensure the final backup directory structure exists within the root
mkdir -p "$BACKUP_DIR"

# --- Helper Functions ---

log_info() {
    echo "🔵 $(date +'%Y-%m-%d %H:%M:%S') $1"
}

log_success() {
    echo "✅ $(date +'%Y-%m-%d %H:%M:%S') $1"
}

log_warning() {
    echo "🟡 $(date +'%Y-%m-%d %H:%M:%S') $1" >&2
}

log_error() {
    echo "🔴 $(date +'%Y-%m-%d %H:%M:%S') $1" >&2
    # The trap will handle cleanup before exiting
    exit 1
}

check_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log_error "Required command '$1' not found. Please install it."
    fi
}

# Function to perform rsync backup with excludes
# Args: src, dest, exclude_patterns (array)
run_rsync() {
    local src="$1"
    local dest="$2"
    shift 2 # Remove the first two arguments (src, dest)
    local excludes=("$@") # Get the rest of the arguments as excludes

    local item_name="$(basename "$src")"
    log_info "Backing up '$item_name' using rsync..."
    mkdir -p "$dest" || log_error "Failed to create directory $dest"

    local rsync_cmd=(rsync -avh --delete-excluded) # --delete-excluded removes files from dest that match exclude patterns
    for excl in "${excludes[@]}"; do
        rsync_cmd+=(--exclude="$excl")
    done
    rsync_cmd+=("$src" "$dest")

    # Add --progress only if not archiving and output is interactive
    # if [ "$ARCHIVE" != true ] && [ -t 1 ]; then
    #    rsync_cmd+=(--progress) # Uncomment if you want progress bars
    # fi

    # Run the command and check exit status
    if "${rsync_cmd[@]}"; then
        log_success "Backed up '$item_name'."
    else
        log_warning "rsync failed for '$item_name'. Continuing with other backups."
        # Optionally uncomment the line below to stop the script on any rsync failure
        # log_error "rsync failed for '$item_name'."
    fi
}

# Function to perform copy backup
# Args: src, dest
run_copy() {
    local src="$1"
    local dest="$2"

    local item_name="$(basename "$src")"
    log_info "Backing up '$item_name' using cp..."
    mkdir -p "$(dirname "$dest")" || log_error "Failed to create directory for $dest"

    # Use cp -a for archive mode (preserves permissions, timestamps, etc.)
    if cp -a "$src" "$dest"; then
        log_success "Backed up '$item_name'."
    else
        log_warning "cp failed for '$item_name'. Continuing with other backups."
    fi
}


# --- Main Backup Logic ---

log_info "🚀 Starting Ubuntu configuration backup process."
log_info "Backup destination: ${BACKUP_DEST_DIR}"
log_info "Backup content path: ${BACKUP_DIR}"

# Check for essential commands
check_command "rsync"
check_command "crontab"
check_command "dpkg"
check_command "tar" # Needed for archiving

# --- 1. Backup specified user configuration items (using rsync) ---
log_info "📁 Backing up specified user configuration items with rsync..."
mkdir -p "$BACKUP_DIR/home-config-rsync/" || log_error "Failed to create directory for rsync user configs"
for item in "${USER_CONFIG_RSYNC_ITEMS[@]}"; do
    # Ensure source path exists and is within home directory
    if [ -e "$HOME/$item" ]; then
        run_rsync "$HOME/$item" "$BACKUP_DIR/home-config-rsync/" "${EXCLUDE_PATTERNS[@]}"
    else
        log_info "$HOME/$item not found, skipping."
    fi
done
log_success "Finished backing up rsync user configuration items."

# --- 2. Backup specified user configuration items (using cp) ---
log_info "📄 Backing up specified user configuration items with cp..."
mkdir -p "$BACKUP_DIR/home-config-copy/" || log_error "Failed to create directory for copy user configs"
for item in "${USER_CONFIG_COPY_ITEMS[@]}"; do
    # Ensure source path exists and is within home directory
    if [ -e "$HOME/$item" ]; then
        # Use basename to keep the original file/dir name in the destination
        run_copy "$HOME/$item" "$BACKUP_DIR/home-config-copy/$(basename "$HOME/$item")"
    else
        log_info "$HOME/$item not found, skipping."
    fi
done
log_success "Finished backing up copy user configuration items."


# --- 3. Backup user-level cron jobs ---
log_info "🕒 Backing up user cron jobs..."
mkdir -p "$BACKUP_DIR/cronjobs" || log_error "Failed to create cronjobs directory"
if crontab -l > "$BACKUP_DIR/cronjobs/crontab.bak" 2>/dev/null; then
    log_success "User cron jobs backed up."
else
    log_info "No user cron jobs found or error accessing them."
    # Create an empty file to indicate this section was attempted
    touch "$BACKUP_DIR/cronjobs/crontab.bak.empty"
fi

# --- 4. Backup system-wide cron jobs (Requires sudo) ---
log_info "🛡️ Backing up system-wide cron jobs (requires sudo)..."
mkdir -p "$BACKUP_DIR/system-cron/" || log_error "Failed to create system-cron directory"
# Check if sudo works without password for this command (optional but nice)
if sudo -n true 2>/dev/null; then
    log_info "Passwordless sudo detected, proceeding with system cron backup."
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


# --- 5. Backup system configuration files (Requires sudo) ---
log_info "⚙️ Backing up selected system configuration files (requires sudo)..."
mkdir -p "$BACKUP_DIR/system-config/" || log_error "Failed to create system-config directory"
backed_up_system_config=false

# Check for sudo access once for this block
if sudo -v >/dev/null 2>&1; then # Check if user *can* sudo
    log_info "Sudo access confirmed for system configuration backup."
    for item in "${SYSTEM_CONFIG_ITEMS[@]}"; do
        # Check if the source path exists *before* attempting sudo copy
        if [ -e "$item" ]; then
            # Use basename to keep the original file/dir name in the destination
            if sudo rsync -avh "$item" "$BACKUP_DIR/system-config/$(basename "$item")"; then
                 log_success "Backed up system config: '$item'."
                 backed_up_system_config=true
            else
                 log_warning "Failed to backup system config: '$item' (sudo rsync failed)."
            fi
        else
            log_info "System config item '$item' not found, skipping."
        fi
    done
    if [ "$backed_up_system_config" = false ]; then
        log_info "No system config items were successfully backed up (might be missing or due to permissions)."
         touch "$BACKUP_DIR/system-config/system-configs.bak.empty"
    fi
else
    log_warning "Sudo access required but not available. Cannot backup system configuration files."
     touch "$BACKUP_DIR/system-config/system-configs.bak.skipped"
fi


# --- 6. Backup shell history ---
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


# --- 7. Backup installed package lists ---
log_info "📦 Backing up package lists..."
mkdir -p "$BACKUP_DIR/package-lists" || log_error "Failed to create package-lists directory"

# APT packages
if command -v dpkg >/dev/null 2>&1; then
    log_info "Backing up APT package list..."
    if dpkg --get-selections > "$BACKUP_DIR/package-lists/dpkg-selections.list"; then
        log_success "Backed up APT package list."
    else
        log_warning "Failed to backup APT package list."
    fi
else
    log_info "dpkg not found, skipping APT package list backup."
fi

# PPA repositories list
if command -v apt-add-repository >/dev/null 2>&1; then
     log_info "Backing up PPA list..."
     # apt-add-repository --list prints to stderr, so redirecting stderr to stdout
    if apt-add-repository --list > "$BACKUP_DIR/package-lists/ppa-list.list" 2>&1; then
        log_success "Backed up PPA list."
    else
        log_warning "Failed to backup PPA list."
    fi
else
    log_info "apt-add-repository not found, skipping PPA list backup."
fi


# Snap packages
if command -v snap >/dev/null 2>&1; then
    log_info "Backing up Snap package list..."
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
     log_info "Backing up Flatpak package list..."
     if flatpak list > "$BACKUP_DIR/package-lists/flatpak-packages.list"; then
        log_success "Backed up Flatpak package list."
    else
        log_warning "Failed to backup Flatpak package list."
    fi
else
    log_info "flatpak not found, skipping Flatpak package list backup."
fi


# --- 8. Backup custom scripts from ~/bin and ~/.local/bin ---
log_info "📝 Backing up custom scripts from ~/bin and ~/.local/bin..."
mkdir -p "$BACKUP_DIR/custom-scripts/" || log_error "Failed to create custom-scripts directory"

if [ -d "$HOME/bin" ]; then
    run_rsync "$HOME/bin/" "$BACKUP_DIR/custom-scripts/bin/"
else
    log_info "$HOME/bin not found, skipping ~/bin backup."
fi

if [ -d "$HOME/.local/bin" ]; then
    run_rsync "$HOME/.local/bin/" "$BACKUP_DIR/custom-scripts/local_bin/"
else
    log_info "$HOME/.local/bin not found, skipping ~/.local/bin backup."
fi
log_success "Finished backing up custom scripts."

# --- 9. Backup GNOME settings (if applicable) ---
if command -v dconf >/dev/null 2>&1; then
    log_info "🖥️ Backing up GNOME settings using dconf..."
    mkdir -p "$BACKUP_DIR/gnome-settings" || log_error "Failed to create gnome-settings directory"
    if dconf dump / > "$BACKUP_DIR/gnome-settings/dconf-settings.ini"; then
        log_success "GNOME settings backed up."
    else
        log_warning "Failed to backup GNOME settings."
    fi
else
    log_info "dconf not found, skipping GNOME settings backup."
fi

# --- 10. Backup UFW firewall rules (Requires sudo) ---
if command -v ufw >/dev/null 2>&1; then
    log_info "🔥 Backing up UFW firewall rules (requires sudo)..."
    mkdir -p "$BACKUP_DIR/ufw/" || log_error "Failed to create ufw directory"
    if sudo -v >/dev/null 2>&1; then # Check if user can sudo
        if sudo ufw status verbose > "$BACKUP_DIR/ufw/ufw-status-verbose.txt" 2>&1 && \
           sudo ufw status numbered > "$BACKUP_DIR/ufw/ufw-status-numbered.txt" 2>&1 && \
           sudo ufw export > "$BACKUP_DIR/ufw/ufw.rules"; then # ufw export is the key file for restoring
             log_success "UFW rules and status backed up."
        else
             log_warning "Failed to backup UFW rules. Check sudo permissions or UFW status."
        fi
    else
        log_warning "Sudo access required but not available. Cannot backup UFW rules."
    fi
else
    log_info "ufw not found, skipping UFW backup."
fi


# --- Archiving ---
if [ "$ARCHIVE" = true ]; then
    log_info "📦 Creating archive..."

    # Trap to clean up temporary directory on exit (success or failure)
    # Make sure this trap is set *after* the temp dir is created
    cleanup_temp_dir() {
        local exit_status=$? # Capture the exit status before cleaning up
        log_info "Cleaning up temporary directory ${BACKUP_ROOT}..."
        if [ -d "$BACKUP_ROOT" ]; then
             # Use '|| true' to prevent the trap itself from failing if rm fails
            rm -rf "$BACKUP_ROOT" || true
            log_info "Temporary directory cleaned up."
        fi
        # Re-exit with the original exit status
        exit "$exit_status"
    }
    # Trap on EXIT (script finished) or ERR (non-zero exit status)
    trap cleanup_temp_dir EXIT
    # trap cleanup_temp_dir ERR # set -e combined with the EXIT trap is usually sufficient

    ARCHIVE_FILE="$BACKUP_DEST_DIR/$FINAL_BACKUP_NAME.tar.${ARCHIVE_FORMAT}"
    local tar_options=""

    case "$ARCHIVE_FORMAT" in
        gz)
            tar_options="czf"
            check_command "gzip"
            ;;
        xz)
            tar_options="cJf"
            check_command "xz"
            ;;
        *)
            log_error "Invalid ARCHIVE_FORMAT '$ARCHIVE_FORMAT' specified. Use 'gz' or 'xz'."
            ;;
    esac

    log_info "Archiving content from ${BACKUP_DIR} to $ARCHIVE_FILE..."
    # tar command: create archive, using compression options ($tar_options), output to file ($ARCHIVE_FILE)
    # change directory (-C) to the temporary root ($BACKUP_ROOT) and archive the subdirectory (basename $BACKUP_DIR)
    if tar "$tar_options" "$ARCHIVE_FILE" -C "$BACKUP_ROOT" "$(basename "$BACKUP_DIR")"; then
        log_success "Archive created successfully at $ARCHIVE_FILE."
        # Temp directory will be cleaned up by the trap on exit
    else
        # set -e will cause the script to exit here, triggering the trap
        log_error "Failed to create archive. Backup contents left in temporary directory: $BACKUP_DIR (will be cleaned up by trap)."
        # The trap will execute next.
    fi
else
    # No archiving, backup is in the final directory
    log_success "Backup completed successfully at $BACKUP_DIR."
fi

# The trap function handles the final exit and cleanup
# log_info "✨ Backup process finished." # This line won't be reached if trap exits

# ==============================================================================
# --- Restoration Notes ---
# ==============================================================================
# Restoration is a manual process.
#
# 1. Extract the archive (if created):
#    For .tar.xz: tar xvf /path/to/your/ubuntu-config-backup-YYYYMMDD_HHMMSS.tar.xz -C /tmp/restore_$$
#    For .tar.gz: tar xvf /path/to/your/ubuntu-config-backup-YYYYMMDD_HHMMSS.tar.gz -C /tmp/restore_$$
#    Replace /path/to/your/ with the actual path. This extracts contents to a temporary directory.
#    Inside /tmp/restore_$$ you'll find the backup directory (e.g., ubuntu-config-backup-YYYYMMDD_HHMMSS).
#
# 2. Restore items manually:
#    - Home config (rsync/copy): Copy files/directories back to your home directory using 'cp' or 'rsync', e.g.,
#      cp -a /tmp/restore_$$/ubuntu-config-backup-YYYYMMDD_HHMMSS/home-config-copy/.gitconfig ~/
#      rsync -avh /tmp/restore_$$/ubuntu-config-backup-YYYYMMDD_HHMMSS/home-config-rsync/.config/myapp/ ~/.config/myapp/
#      **Be cautious** when overwriting existing files, especially for directories like .config. Consider merging or backing up current configs first.
#    - Cron jobs: Use 'crontab /tmp/restore_$$/.../cronjobs/crontab.bak'. This *replaces* your current user cron.
#    - System cron jobs: Manually copy files from /tmp/restore_$$/.../system-cron/ to /etc/cron* (requires sudo).
#    - System config files: Manually copy files from /tmp/restore_$$/.../system-config/ to their original locations (e.g., /etc/fstab). **EXTREME CAUTION REQUIRED.** Incorrect system files can prevent your system from booting. Always back up existing files before replacing them. (Requires sudo).
#    - Shell history: Manually copy the backup files from /tmp/restore_$$/.../shell-history/ to replace/merge with your current history files (e.g., ~/.bash_history, ~/.zsh_history).
#    - Package lists:
#      - APT: Use 'sudo dpkg --set-selections < /tmp/restore_$$/.../package-lists/dpkg-selections.list'
#             Then 'sudo apt-get dselect-upgrade' or 'sudo apt upgrade' to install/remove packages.
#      - PPA: Manually review /tmp/restore_$$/.../package-lists/ppa-list.list and add them using 'sudo add-apt-repository <ppa_string>'.
#      - Snap/Flatpak: Manually review the lists and install using 'snap install <package>' or 'flatpak install <remote> <package>'.
#    - Custom scripts: Copy contents of /tmp/restore_$$/.../custom-scripts/bin/ to ~/bin/ and /tmp/restore_$$/.../custom-scripts/local_bin/ to ~/.local/bin/.
#    - GNOME settings (dconf): Use 'dconf load / < /tmp/restore_$$/.../gnome-settings/dconf-settings.ini'. **This will overwrite your current dconf settings.**
#    - UFW rules: The file /tmp/restore_$$/.../ufw/ufw.rules is the primary backup. You can try 'sudo ufw import /tmp/restore_$$/.../ufw/ufw.rules'. **Use with extreme caution** as incorrect rules can block access. It's often safer to review the file and manually re-add rules using 'sudo ufw allow/deny ...'.
#
# 3. Clean up the temporary restore directory: rm -rf /tmp/restore_$$
