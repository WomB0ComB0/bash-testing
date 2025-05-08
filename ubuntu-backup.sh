#!/bin/bash

# ==============================================================================
# Ubuntu User and Configuration Backup Script
# ==============================================================================
# This script backs up essential user configurations, dotfiles, package lists,
# and selected system configuration files on an Ubuntu system.
# It is NOT a full system backup and does NOT include user data like Documents,
# Pictures, Videos, etc.
#
# Restoration is a MANUAL process and depends on the item being restored.
#
# ==============================================================================
# --- Configuration ---
# ==============================================================================

# Backup location: Where the final archive or directory will be placed.
# Defaults to the user's home directory.
# IMPORTANT: Run this script as your normal user, NOT with 'sudo ./script.sh'.
# The script uses 'sudo' internally for files requiring root permissions.
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
    # Shell configuration
    ".bashrc"
    ".profile"
    ".zshrc"
    ".bash_profile"
    ".bash_aliases"
    ".bash_history"
    ".zsh_history"
    ".zsh"                  # Zsh configuration directory
    ".oh-my-zsh"            # Oh My Zsh configuration
    ".inputrc"              # Readline configuration

    # Terminal customization
    ".dircolors"
    ".selected_editor"
    ".screenrc"
    ".tmux.conf"
    ".terminfo"

    # Config directories
    ".config"               # Generic config directory (apply EXCLUDE_PATTERNS)
    ".local/bin"            # User-installed executables
    ".local/share/applications" # Custom .desktop files
    ".config/autostart"     # Startup applications
    
    # Appearance and theming
    ".themes"               # User-installed themes (can be large, relies on excludes)
    ".icons"                # User-installed icons (can be large, relies on excludes)
    ".fonts"                # User-installed fonts
    ".local/share/fonts"    # Alternative font location
    
    # Security and credentials
    ".ssh"                  # SSH configs and keys (sensitive!)
    ".gnupg"                # GPG keys (sensitive!)
    ".local/share/keyrings" # GNOME Keyring
    ".pki"                  # Personal Key Infrastructure
    ".authinfo"             # Authentication info
    ".netrc"                # Network authentication info

    # Development tools
    ".vimrc"
    ".vim"
    ".emacs"
    ".emacs.d"
    ".gitconfig"
    ".gitignore_global"
    ".npmrc"
    ".cargo"                # Rust cargo configuration
    ".rustup"               # Rust toolchain configuration (consider excluding large files)
    ".m2"                   # Maven configuration and repository
    ".gradle"               # Gradle configuration
    ".jupyter"              # Jupyter notebooks configuration
    ".ipython"              # IPython configuration
    ".vscode"               # VS Code config (relies on excludes for extensions/storage)
    ".atom"                 # Atom editor config
    ".config/nvim"          # Neovim config
    
    # Browser profiles
    ".mozilla/firefox"      # Firefox profiles (apply EXCLUDE_PATTERNS) - considers all profiles
    ".config/google-chrome" # Chrome profiles (can be large, relies on excludes)
    ".config/chromium"      # Chromium profiles
    ".config/vivaldi"       # Vivaldi browser
    
    # Email clients
    ".thunderbird"          # Thunderbird profiles (apply EXCLUDE_PATTERNS)
    ".config/evolution"     # Evolution mail client

    # Password managers
    ".config/keepassxc"     # KeePassXC
    ".password-store"       # Pass password manager

    # Chat and messaging
    ".config/Signal"        # Signal Desktop
    ".config/Element"       # Element/Matrix client
    ".config/discord"       # Discord configuration (not cache)
    ".config/telegram-desktop" # Telegram Desktop

    # Media applications
    ".config/vlc"           # VLC media player
    ".config/mpv"           # MPV media player
    ".ncmpcpp"              # Music player configuration
    ".config/spotify"       # Spotify (config only, not cache)

    # System tools
    ".config/htop"          # Process viewer configuration
    ".config/dconf"         # GNOME configuration database
    ".config/pulse"         # PulseAudio configuration
    ".gnome"                # GNOME specific user settings
    ".config/systemd/user"  # User systemd services

    # Virtual machines and containers
    ".vagrant.d"            # Vagrant configuration (not boxes)
    ".docker"               # Docker configuration (not images)
    ".VirtualBox"           # VirtualBox configuration (not VMs)
    ".config/libvirt"       # Libvirt configuration
    
    # Other applications
    ".config/sublime-text"  # Sublime Text editor
    ".config/inkscape"      # Inkscape
    ".config/GIMP"          # GIMP
    ".config/libreoffice"   # LibreOffice
    ".config/nextcloud"     # Nextcloud client
    ".config/remmina"       # Remote desktop client
    ".timewarrior"          # Time tracking
    ".taskwarrior"          # Task management
)

# List of specific user configuration FILES or SMALL DIRECTORIES to copy directly.
# These items will be copied using 'cp -a'. No excludes are applied here.
# Useful for individual dotfiles or small directories that don't need rsync logic.
# Add paths line by line, separated by spaces or newlines.
USER_CONFIG_COPY_ITEMS=(
    # Git configuration
    ".gitconfig"
    ".gitignore_global"
    ".git-credentials"
    ".gitattributes"
    
    # Editor configurations
    ".vimrc"
    ".ideavimrc"
    ".nanorc"
    ".editorconfig"
    
    # Terminal configurations
    ".tmux.conf"
    ".screenrc"
    ".inputrc"
    ".hushlogin"
    
    # Display configurations
    ".Xresources"
    ".Xdefaults"
    ".xinitrc"
    ".xsessionrc"
    ".xprofile"
    ".Xmodmap"
    
    # GUI configurations
    ".gtkrc-2.0"
    ".gtkrc-3.0"
    ".config/gtk-3.0/settings.ini"
    ".config/gtk-4.0/settings.ini"
    ".config/mimeapps.list"
    ".config/user-dirs.dirs"
    ".config/user-dirs.locale"
    
    # Shell dotfiles
    ".curlrc"
    ".wgetrc"
    ".gemrc"
    ".pylintrc"
    ".condarc"
    ".npmrc"
    ".yarnrc"
    ".psqlrc"
    ".my.cnf"
    ".irbrc"
    ".jshintrc"
    ".eslintrc"
    ".stylelintrc"
    
    # Application-specific files
    ".config/htop/htoprc"
    ".config/neofetch/config.conf"
    ".config/bat/config"
    ".config/ranger/rc.conf"
    ".config/alacritty/alacritty.yml"
    ".config/kitty/kitty.conf"
    ".config/picom/picom.conf"
    ".config/dunst/dunstrc"
    ".config/rofi/config.rasi"
    ".config/redshift.conf"
    ".config/starship.toml"
    ".config/zathura/zathurarc"
    ".config/mpd/mpd.conf"
    ".config/ncmpcpp/config"
    
    # Window Manager configurations
    ".config/i3/config"
    ".config/sway/config"
    ".config/bspwm/bspwmrc"
    ".config/awesome/rc.lua"
    ".config/qtile/config.py"
    ".config/hypr/hyprland.conf"
    ".xmonad/xmonad.hs"
    ".config/polybar/config"
    
    # Development-specific files
    ".prettierrc"
    ".clang-format"
    ".rustfmt.toml"
    ".clippy.toml"
    ".pylintrc"
    ".black"
    ".scalafmt.conf"
    ".config/nvim/init.vim"
    ".config/nvim/init.lua"
    ".config/Code/User/settings.json"
    ".config/sublime-text-3/Packages/User/Preferences.sublime-settings"
    
    # Network configurations
    ".netrc"
    ".wgetrc"
    ".ssh/config"
    ".config/remmina/remmina.pref"
    
    # Email, chat, and calendar
    ".muttrc"
    ".config/neomutt/neomuttrc"
    ".offlineimaprc"
    ".msmtprc"
    ".config/khal/config"
    ".config/vdirsyncer/config"
    
    # System info/management
    ".fehbg"
    ".xscreensaver"
    ".Xauthority"
    ".config/fontconfig/fonts.conf"
)


# List of patterns to EXCLUDE from the USER_CONFIG_RSYNC_ITEMS directories using rsync's --exclude.
# These help avoid large data/cache/temp files within potentially included config directories.
# Patterns are relative to the source directory being rsynced (e.g., if backing up .config,
# an exclude like "*/cache/*" will match .config/app/cache).
EXCLUDE_PATTERNS=(
    # General cache and temporary files
    "*/.cache/*"            # Exclude all cache directories
    "*/cache/*"             # Exclude other cache directories (e.g., inside .config)
    "*.log"                 # Exclude log files
    "*.tmp"                 # Temporary files
    "*.temp"                # Alternative temp extension
    "*/tmp/*"               # Exclude temporary directories
    "*/temp/*"              # Alternative temp directory name
    "*/Trash/*"             # Exclude trash directories
    "*/Recycle.Bin/*"       # Windows-style trash
    "*~"                    # Backup files created by editors
    "*.bak"                 # Backup files
    "*.swp"                 # Vim swap files
    "*.swo"                 # Vim swap files
    "*.swn"                 # Vim swap files
    "*.pyc"                 # Python compiled files
    "__pycache__"           # Python cache directories
    "*.o"                   # Object files
    "*.so"                  # Shared libraries
    "*.dll"                 # Windows libraries
    "*.dylib"               # macOS libraries
    "*.a"                   # Static libraries
    
    # Browser data
    "*/CacheStorage/*"      # Browser cache storage
    "*/Service Worker/*"    # Service worker caches
    "*/webappsstore.sqlite" # Web storage
    "*/cookies.sqlite"      # Cookies database
    "*/favicons.sqlite"     # Favicons database
    "*/places.sqlite"       # Firefox history
    "*/sessionstore*"       # Session data
    "*/minidumps/*"         # Crash reports
    "*/GPUCache/*"          # GPU cache
    "*/ShaderCache/*"       # Shader cache
    "*/Storage/*"           # Web storage
    "*/IndexedDB/*"         # IndexedDB data
    
    # Application-specific caches
    "*/Code/User/globalStorage/*" # VS Code large storage
    "*/Code/User/workspaceStorage/*" # VS Code large storage
    "*/slack/Cache/*"       # Slack cache
    "*/discord/Cache/*"     # Discord cache
    "*/zoom/data/*"         # Zoom data (can be large)
    "*/electron/Cache/*"    # Electron app caches
    "*/Code/Cache/*"        # VS Code cache
    "*/Code/CachedData/*"   # VS Code cached data
    "*/VSCode/Cache/*"      # VS Code cache (alternative location)
    "*/Electron/Cache/*"    # Generic Electron cache
    "*/Chromium/Default/Cache/*" # Chromium cache
    "*/Google/Chrome/Default/Cache/*" # Chrome cache
    "*/Firefox/Profiles/*/cache*" # Firefox cache
    "*/mozilla/firefox/*/cache*" # Firefox cache
    "*/Thunderbird/Profiles/*/cache*" # Thunderbird cache
    "*/ImagingTools/*"      # Image editing temp files
    "*/saved application state/*" # Saved application states
    "*/Application Support/*/Cache/*" # macOS-style cache location
    "*/spotify/Data/*"      # Spotify cached data
    "*/spotify/Storage/*"   # Spotify storage
    "*/Podcasts/*"          # Podcast downloads
    "*/Music/iTunes/*"      # iTunes library
    "*/Pictures/Photos Library.photoslibrary/*" # Photos library
    "*/Videos/*"            # Video files
    "*/Downloads/*"         # Downloaded files
    
    # Development tools and libraries
    "*/npm/*"               # Node.js package cache/installs in home
    "*/yarn/*"              # Yarn package cache
    "*/go/*"                # Go build cache
    "*/pip/*"               # Python pip cache
    "*/gradle/*"            # Gradle cache
    "*/composer/cache/*"    # PHP Composer cache
    "*/m2/repository/*"     # Maven repository
    "*/cargo/registry/*"    # Rust Cargo registry
    "*/node_modules/*"      # Node.js dependencies
    "*/vendor/*"            # Common directory for dependencies
    "*/.vscode/extensions/*" # VS Code extensions (can be reinstalled)
    "*/gems/*"              # Ruby gems
    "*/bower_components/*"  # Bower components
    "*/target/*"            # Common build target directory
    "*/build/*"             # Common build directory
    "*/dist/*"              # Common distribution directory
    "*/.venv/*"             # Python virtual environments
    "*/env/*"               # Another common venv name
    "*/virtualenv/*"        # Another virtual env name
    "*/.tox/*"              # Python tox environments
    "*/.eggs/*"             # Python eggs
    "*/site-packages/*"     # Python site packages
    "*/wheelhouse/*"        # Python wheels
    "*/.pytest_cache/*"     # Pytest cache
    "*/.ipynb_checkpoints/*" # Jupyter notebook checkpoints
    "*/.terraform/*"        # Terraform cache
    "*/.terragrunt-cache/*" # Terragrunt cache
    
    # Container and VM data
    "*/.var/*"              # Flatpak data (usually large)
    "*/.local/share/flatpak/*" # Flatpak data (redundant if .var is excluded, but safer)
    "*/.local/share/containers/*" # Podman/Buildah data
    "*/.local/share/libvirt/*" # libvirt data
    "*/docker/overlay2/*"   # Docker overlays
    "*/docker/image/*"      # Docker images
    "*/docker/volumes/*"    # Docker volumes
    "*/VirtualBox VMs/*"    # VirtualBox VMs
    "*/VMs/*"               # Generic VMs directory
    "*/lxc/*"               # LXC containers
    "*/.vagrant.d/boxes/*"  # Vagrant boxes
    
    # Gaming and large application data
    "*/Steam/*"             # Steam data
    "*/lutris/runners/*"    # Lutris runners/games
    "*/Games/*"             # General Games directories
    "*/GOG Games/*"         # GOG games
    "*/Epic Games/*"        # Epic Games
    "*/Origin/*"            # EA Origin
    "*/Ubisoft/*"           # Ubisoft games
    "*/BattleNet/*"         # Battle.net
    "*/Wine/*"              # Wine prefix
    "*/PlayOnLinux/*"       # PlayOnLinux
    "*/Proton/*"            # Proton for Steam
    
    # XDG directories and system data
    "*/.local/share/Trash/*" # Trash
    "*/.local/share/icc/*"   # Color profiles
    "*/.local/share/gvfs-metadata/*" # GVFS metadata
    "*/.local/share/webkitgtk/*" # Webkit cache
    "*/.local/state/*"      # XDG State directory
    "*/.local/share/recently-used.xbel" # Recently used files
    "*/.local/share/thumbnails/*" # Thumbnails
    "*/.local/share/tracker/*" # GNOME tracker
    "*/.local/share/baloo/*" # KDE file indexer
    "*/.local/share/akonadi/*" # KDE PIM storage
    "*/.local/share/zeitgeist/*" # Activity logger
    "*/.local/share/telepathy/*" # IM framework
    "*/.pki/nssdb/*"        # NSS database (can be regenerated)
    "*/.esd_auth"           # ESD authentication
    
    # Media cache/data (often large)
    "*/Spotify/Data/*"      # Spotify data
    "*/spotify/Storage/*"   # Spotify storage
    "*/Podcasts/*"          # Podcast downloads
    "*/Music/iTunes/*"      # iTunes library
    "*/Pictures/Photos Library.photoslibrary/*" # Photos library
    "*/Videos/*"            # Video files
    "*/Downloads/*"         # Downloaded files
    
    # Miscellaneous large or unnecessary data
    "*.localstorage"        # Local storage files
    "*/Dropbox/*"           # Dropbox files (often synced elsewhere)
    "*/OneDrive/*"          # OneDrive files (often synced elsewhere)
    "*/Google Drive/*"      # Google Drive files (often synced elsewhere)
    "*/Next Cloud/*"        # NextCloud files (often synced elsewhere)
    "*/iCloud/*"            # iCloud files (often synced elsewhere)
    "*/snap/*/current/*"    # Snap package data
    "*/snap/*/common/*"     # Snap common data
)

# List of system configuration files and directories to back up.
# These REQUIRE sudo privileges. Select carefully.
# Add paths line by line, separated by spaces or newlines.
SYSTEM_CONFIG_ITEMS=(
    # System identification
    "/etc/fstab"             # Filesystem table
    "/etc/hosts"             # Host name resolution
    "/etc/hostname"          # System hostname
    "/etc/machine-id"        # Machine identifier
    "/etc/os-release"        # OS information
    "/etc/lsb-release"       # Distribution information

    # Network configuration
    "/etc/resolv.conf"       # DNS resolver configuration
    "/etc/netplan"           # Netplan network configuration
    "/etc/network/interfaces" # Classical network configuration
    "/etc/network/interfaces.d" # Network interface configurations
    "/etc/NetworkManager/system-connections" # NetworkManager connections
    "/etc/NetworkManager/conf.d" # NetworkManager configuration
    "/etc/netctl"            # Arch Linux network manager
    "/etc/systemd/network"   # systemd network configuration
    "/etc/hosts.allow"       # TCP wrappers allow rules
    "/etc/hosts.deny"        # TCP wrappers deny rules
    "/etc/nftables.conf"     # nftables firewall configuration
    "/etc/iptables"          # iptables firewall rules
    "/etc/ufw"               # UFW firewall configuration
    "/etc/dhcp"              # DHCP client/server configuration
    "/etc/wpa_supplicant"    # Wi-Fi configuration
    "/etc/iproute2"          # IP routing configuration
    "/etc/sysconfig/network-scripts" # Red Hat/CentOS network config

    # System environment and settings
    "/etc/environment"       # System-wide environment variables
    "/etc/profile.d"         # Shell initialization scripts
    "/etc/profile"           # System-wide profile
    "/etc/bash.bashrc"       # System-wide bashrc
    "/etc/zsh"               # System-wide zsh configuration
    "/etc/inputrc"           # Readline configuration
    "/etc/locale.conf"       # System locale settings
    "/etc/locale.gen"        # Locale generation configuration
    "/etc/default"           # Default settings for services
    "/etc/sysctl.conf"       # Kernel parameters configuration
    "/etc/sysctl.d"          # Additional kernel parameters
    "/etc/security"          # PAM security settings
    "/etc/security/limits.conf" # Resource limits
    "/etc/security/limits.d" # Additional resource limits
    "/etc/modules"           # Kernel modules to load at boot
    "/etc/modules-load.d"    # Additional kernel modules
    "/etc/modprobe.d"        # Module blacklisting/options
    "/etc/vconsole.conf"     # Virtual console configuration
    "/etc/systemd/system.conf" # systemd system configuration
    "/etc/systemd/user.conf" # systemd user configuration
    "/etc/systemd/journald.conf" # journald logging configuration
    "/etc/systemd/logind.conf" # logind session management configuration
    "/etc/systemd/resolved.conf" # systemd-resolved DNS resolver
    "/etc/systemd/timesyncd.conf" # systemd time sync daemon
    "/etc/systemd/system"    # systemd system unit files
    "/etc/tmpfiles.d"        # Temporary files configuration
    "/etc/rc.local"          # Startup script (if it exists)
    "/etc/motd"              # Message of the day
    "/etc/issue"             # Pre-login message
    "/etc/issue.net"         # Pre-login message for network users

    # Package management
    "/etc/apt/sources.list"  # APT package sources (Debian/Ubuntu)
    "/etc/apt/sources.list.d" # Additional APT sources
    "/etc/apt/preferences"   # APT preferences
    "/etc/apt/preferences.d" # Additional APT preferences
    "/etc/apt/apt.conf"      # APT configuration
    "/etc/apt/apt.conf.d"    # Additional APT configuration
    "/etc/pacman.conf"       # Pacman package manager configuration (Arch)
    "/etc/pacman.d"          # Pacman additional configuration
    "/etc/yum.conf"          # Yum package manager (RHEL/CentOS)
    "/etc/yum.repos.d"       # Yum repositories
    "/etc/dnf/dnf.conf"      # DNF package manager (Fedora)
    "/etc/dnf/modules.d"     # DNF modules configuration
    "/etc/zypp"              # Zypper package manager (openSUSE)
    "/etc/flatpak"           # Flatpak configuration

    # Authentication and security
    "/etc/sudoers"           # VERY SENSITIVE! Sudo configuration
    "/etc/sudoers.d"         # Additional sudo rules
    "/etc/pam.d"             # PAM authentication configuration
    "/etc/login.defs"        # Shadow password suite configuration
    # "/etc/shadow"            # VERY SENSITIVE! Encrypted passwords (requires special handling - SKIPPING)
    # "/etc/gshadow"           # VERY SENSITIVE! Group passwords (requires special handling - SKIPPING)
    "/etc/group"             # Group definitions
    "/etc/passwd"            # User account information
    "/etc/ssh/sshd_config"   # SSH server configuration
    "/etc/ssh/ssh_config"    # SSH client configuration
    "/etc/ssl/certs"         # SSL certificates
    "/etc/ssl/private"       # VERY SENSITIVE! SSL private keys
    "/etc/ca-certificates"   # CA certificates configuration
    "/etc/krb5.conf"         # Kerberos configuration
    "/etc/fail2ban"          # Fail2ban configuration
    "/etc/apparmor"          # AppArmor configuration
    "/etc/apparmor.d"        # AppArmor profiles
    "/etc/selinux"           # SELinux configuration
    "/etc/openssl"           # OpenSSL configuration
    "/etc/pki"               # Public Key Infrastructure

    # Boot and system startup
    "/etc/default/grub"      # GRUB bootloader configuration
    "/etc/grub.d"            # GRUB bootloader scripts
    "/boot/grub/grub.cfg"    # GRUB configuration file (generated)
    "/boot/grub2/grub.cfg"   # GRUB2 configuration file (generated)
    "/boot/efi"              # EFI boot files (use with caution)
    "/etc/systemd/system"    # systemd service units
    "/etc/rc.d"              # Init scripts (non-systemd systems)
    "/etc/init.d"            # Init scripts (SysV style)
    "/etc/inittab"           # Init configuration (SysV style)
    "/etc/dracut.conf"       # Initramfs generation
    "/etc/dracut.conf.d"     # Additional initramfs configuration
    "/etc/mkinitcpio.conf"   # Initramfs generation (Arch)
    "/etc/default/useradd"   # Default settings for new users

    # Display managers and desktop environments
    "/etc/lightdm"           # LightDM display manager config
    "/etc/gdm3"              # GDM3 display manager config
    "/etc/gdm"               # GDM display manager config
    "/etc/sddm.conf"         # SDDM display manager config
    "/etc/sddm.conf.d"       # Additional SDDM configuration
    "/etc/X11/xorg.conf"     # X.org server config (if present)
    "/etc/X11/xorg.conf.d"   # X.org server config snippets
    "/etc/X11/xinit"         # X initialization
    "/etc/xdg"               # XDG base directory specification

    # File systems and storage
    "/etc/crypttab"          # Encrypted filesystems
    "/etc/mdadm.conf"        # Software RAID configuration
    "/etc/mdadm/mdadm.conf"  # Alternative RAID config location
    "/etc/lvm"               # Logical Volume Manager configuration
    "/etc/multipath"         # Multipath device configuration
    "/etc/mtab"              # Mounted filesystems (usually a symlink)
    "/etc/autofs"            # Automounter configuration
    "/etc/exports"           # NFS exports
    "/etc/samba/smb.conf"    # Samba configuration
    "/etc/updatedb.conf"     # updatedb configuration for locate

    # Services and daemons
    "/etc/cron.d"            # Cron job directories
    "/etc/cron.daily"        # Daily cron jobs
    "/etc/cron.hourly"       # Hourly cron jobs
    "/etc/cron.monthly"      # Monthly cron jobs
    "/etc/cron.weekly"       # Weekly cron jobs
    "/etc/crontab"           # System crontab
    "/etc/cups"              # CUPS printing system
    "/etc/ntp.conf"          # NTP configuration
    "/etc/chrony"            # Chrony time service
    "/etc/mysql"             # MySQL/MariaDB configuration
    "/etc/postgresql"        # PostgreSQL configuration
    "/etc/nginx"             # Nginx web server
    "/etc/apache2"           # Apache web server (Debian/Ubuntu)
    "/etc/httpd"             # Apache web server (RHEL/CentOS)
    "/etc/php"               # PHP configuration
    "/etc/postfix"           # Postfix mail server
    "/etc/dovecot"           # Dovecot mail server
    "/etc/openvpn"           # OpenVPN configuration
    "/etc/wireguard"         # WireGuard VPN
    "/etc/squid"             # Squid proxy
    "/etc/bind"              # BIND DNS server
    "/etc/named"             # BIND DNS (alternative location)
    "/etc/nsd"               # NSD DNS server
    "/etc/dnsmasq.conf"      # Dnsmasq DNS/DHCP
    "/etc/dnsmasq.d"         # Dnsmasq additional configuration
    "/etc/docker"            # Docker configuration
    "/etc/libvirt"           # Libvirt virtualization
    "/etc/qemu"              # QEMU virtualization
    "/etc/default/docker"    # Docker defaults
    "/etc/containerd"        # containerd configuration
    "/etc/cni"               # Container Network Interface
    "/etc/haproxy"           # HAProxy load balancer
    "/etc/redis"           # Redis database
    "/etc/mongodb"           # MongoDB database
    "/etc/memcached.conf"    # Memcached configuration
    "/etc/pulse"             # PulseAudio sound server
    "/etc/bluetooth"         # Bluetooth configuration
    "/etc/rsyslog.conf"      # Rsyslog configuration
    "/etc/rsyslog.d"         # Additional rsyslog configuration
    "/etc/logrotate.conf"    # Log rotation configuration
    "/etc/logrotate.d"       # Additional log rotation configurations
    "/etc/audit"             # Audit daemon configuration
    
    # Hardware and peripherals
    "/etc/X11/xorg.conf.d"   # X.org configuration snippets
    "/etc/udev/rules.d"      # udev rules
    "/etc/udisks2"           # Disk management
    "/etc/acpi"              # ACPI power management
    "/etc/sensors.d"         # Hardware sensors configuration
    "/etc/sane.d"            # Scanner configuration
    "/etc/cups"              # Printing system
    "/etc/pulse"             # PulseAudio sound server
    "/etc/alsa"              # ALSA sound configuration
    "/etc/bluetooth"         # Bluetooth configuration
    "/etc/modules-load.d"    # Kernel modules to load
    "/etc/modprobe.d"        # Module options and blacklisting
    "/etc/console-setup"     # Console setup

    # Miscellaneous important configs
    "/etc/kernel"            # Kernel related configurations
    "/etc/fonts"             # Font configuration
    "/etc/dconf"             # GNOME configuration database
    "/etc/alternatives"      # System alternatives
    "/etc/mailcap"           # MIME type handlers
    "/etc/mime.types"        # MIME type definitions
    "/etc/shells"            # Valid login shells
    "/etc/timezone"          # System timezone
    "/etc/localtime"         # Timezone symlink
    "/var/spool/cron"        # User crontabs (Needs sudo to read other users' crontabs, though crontab -l gets current user)
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

# Determine the root directory where backup content is built.
# If archiving, this is a temporary directory. If not, it's the final destination.
if [ "$ARCHIVE" = true ]; then
    # Create a temporary directory for building the archive content
    # Using a temporary directory ensures partial backups don't clutter things if archiving fails
    BACKUP_ROOT=$(mktemp -d -t "${ARCHIVE_NAME}-XXXXXXXXXX")
    log_info "Building backup content in temporary directory: ${BACKUP_ROOT}"
    # The actual backup directory *within* the temp root
    BACKUP_DIR="$BACKUP_ROOT/$FINAL_BACKUP_NAME"

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

else
    # Create the final backup directory directly in the destination
    BACKUP_DIR="$BACKUP_DEST_DIR/$FINAL_BACKUP_NAME"
fi

# Ensure the final backup directory structure exists within the root
mkdir -p "$BACKUP_DIR"

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
    rsync_cmd+=(--no-perms --no-owner --no-group) # Don't preserve root permissions/owner for user files
    rsync_cmd+=("$src" "$dest")

    # Add --progress only if not archiving and output is interactive
    # if [ "$ARCHIVE" != true ] && [ -t 1 ]; then
    #    rsync_cmd+=(--progress) # Uncomment if you want progress bars
    # fi

    # Run the command and check exit status
    # Using '|| true' prevents set -e from exiting on rsync failure, allowing other backups to continue
    if "${rsync_cmd[@]}"; then
        log_success "Backed up '$item_name'."
    else
        log_warning "rsync failed for '$item_name'. Continuing with other backups."
        # Optionally uncomment the line below to stop the script on any rsync failure
        # log_error "rsync failed for '$item_name'."
        true # Ensure the if block returns true so set -e doesn't trigger
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
    # But remove 'p' (perms), 'o' (owner), 'g' (group) if backing up user files as user,
    # so root-owned files in $HOME don't fail. cp -a doesn't have granular flags like rsync.
    # Let's just use simple cp -r if it's a directory, or cp if it's a file, for robustness.
    if [ -d "$src" ]; then
       if cp -r "$src" "$dest"; then # Use -r for directories
           log_success "Backed up '$item_name'."
       else
           log_warning "cp failed for '$item_name'. Continuing with other backups."
           true # Ensure the if block returns true
       fi
    else
        if cp "$src" "$dest"; then # Use plain cp for files
             log_success "Backed up '$item_name'."
        else
             log_warning "cp failed for '$item_name'. Continuing with other backups."
             true # Ensure the if block returns true
        fi
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
        # Added --no-perms, --no-owner, --no-group to rsync for user files
        # This prevents errors if some dotfiles/dirs in $HOME are unexpectedly owned by root or have special permissions
        run_rsync "$HOME/$item" "$BACKUP_DIR/home-config-rsync/" "${EXCLUDE_PATTERNS[@]}" --no-perms --no-owner --no-group
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
        # Modified run_copy to handle files/dirs appropriately
        run_copy "$HOME/$item" "$BACKUP_DIR/home-config-copy/$(basename "$HOME/$item")"
    else
        log_info "$HOME/$item not found, skipping."
    fi
done
log_success "Finished backing up copy user configuration items."


# --- 3. Backup user-level cron jobs ---
log_info "🕒 Backing up user cron jobs..."
mkdir -p "$BACKUP_DIR/cronjobs" || log_error "Failed to create cronjobs directory"
# crontab -l reads the current *user's* crontab, doesn't need sudo if run as the user
if crontab -l > "$BACKUP_DIR/cronjobs/crontab.bak" 2>/dev/null; then
    log_success "User cron jobs backed up."
else
    log_info "No user cron jobs found or error accessing them (output to /dev/null)."
    # Create an empty file to indicate this section was attempted
    touch "$BACKUP_DIR/cronjobs/crontab.bak.empty"
fi

# --- 4. Backup system-wide cron jobs (Requires sudo) ---
log_info "🛡️ Backing up system-wide cron jobs (requires sudo)..."
mkdir -p "$BACKUP_DIR/system-cron/" || log_error "Failed to create system-cron directory"
# Check if sudo works without password for this command (optional but nice)
if sudo -n true 2>/dev/null; then
    log_info "Passwordless sudo detected, proceeding with system cron backup."
    # Using '|| true' to allow script to continue if sudo fails for this command
    if sudo rsync -avh /etc/cron* "$BACKUP_DIR/system-cron/"; then
         log_success "System-wide cron jobs backed up."
    else
         log_warning "sudo rsync failed for system cron jobs. Check permissions or sudo setup."
         true # Ensure the if block returns true
    fi
elif sudo true 2>/dev/null; then
    # Sudo requires password, let it prompt or inform user
    log_info "Sudo password may be required for system cron backup."
    # Using '|| true' to allow script to continue if sudo fails for this command
     if sudo rsync -avh /etc/cron* "$BACKUP_DIR/system-cron/"; then
         log_success "System-wide cron jobs backed up."
    else
         log_warning "sudo rsync failed for system cron jobs after prompt. Check permissions or password."
         true # Ensure the if block returns true
    fi
else
    log_warning "sudo command not available or user not in sudoers file. Cannot backup system cron jobs."
fi


# --- 5. Backup selected system configuration files (Requires sudo) ---
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
            # Using '|| true' to allow script to continue if sudo rsync fails for an item
            # Preserve root permissions/owner for system files
            if sudo rsync -avh "$item" "$BACKUP_DIR/system-config/$(basename "$item")"; then
                 log_success "Backed up system config: '$item'."
                 backed_up_system_config=true
            else
                 log_warning "Failed to backup system config: '$item' (sudo rsync failed)."
                 true # Ensure the if block returns true
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
        # Using '|| true' to allow script to continue if cp fails
        if cp "$hist_path" "$BACKUP_DIR/shell-history/${shell}_history.bak"; then
            log_success "Backed up ${shell} history."
            backed_up_history=true
        else
            log_warning "Failed to backup ${shell} history ($hist_path)."
            true # Ensure the if block returns true
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

# APT packages (Requires sudo to get complete list reliably)
if command -v dpkg >/dev/null 2>&1; then
    log_info "Backing up APT package list..."
    # Using '|| true' to allow script to continue if command fails
    if sudo dpkg --get-selections > "$BACKUP_DIR/package-lists/dpkg-selections.list"; then
        log_success "Backed up APT package list."
    else
        log_warning "Failed to backup APT package list (requires sudo)."
        true # Ensure the if block returns true
    fi
else
    log_info "dpkg not found, skipping APT package list backup."
fi

# PPA repositories list (Requires sudo)
if command -v apt-add-repository >/dev/null 2>&1; then
     log_info "Backing up PPA list..."
     # apt-add-repository --list prints to stderr, so redirecting stderr to stdout
     # Using '|| true' to allow script to continue if command fails
    if sudo apt-add-repository --list > "$BACKUP_DIR/package-lists/ppa-list.list" 2>&1; then
        log_success "Backed up PPA list."
    else
        log_warning "Failed to backup PPA list (requires sudo)."
        true # Ensure the if block returns true
    fi
else
    log_info "apt-add-repository not found, skipping PPA list backup."
fi


# Snap packages
if command -v snap >/dev/null 2>&1; then
    log_info "Backing up Snap package list..."
    # Using '|| true' to allow script to continue if command fails
    if snap list > "$BACKUP_DIR/package-lists/snap-packages.list"; then
        log_success "Backed up Snap package list."
    else
        log_warning "Failed to backup Snap package list."
        true # Ensure the if block returns true
    fi
else
    log_info "snap not found, skipping Snap package list backup."
fi

# Flatpak packages
if command -v flatpak >/dev/null 2>&1; then
     log_info "Backing up Flatpak package list..."
     # Using '|| true' to allow script to continue if command fails
     if flatpak list > "$BACKUP_DIR/package-lists/flatpak-packages.list"; then
        log_success "Backed up Flatpak package list."
    else
        log_warning "Failed to backup Flatpak package list."
        true # Ensure the if block returns true
    fi
else
    log_info "flatpak not found, skipping Flatpak package list backup."
fi


# --- 8. Backup custom scripts from ~/bin and ~/.local/bin ---
log_info "📝 Backing up custom scripts from ~/bin and ~/.local/bin..."
mkdir -p "$BACKUP_DIR/custom-scripts/" || log_error "Failed to create custom-scripts directory"

if [ -d "$HOME/bin" ]; then
    run_rsync "$HOME/bin/" "$BACKUP_DIR/custom-scripts/bin/" --no-perms --no-owner --no-group
else
    log_info "$HOME/bin not found, skipping ~/bin backup."
fi

if [ -d "$HOME/.local/bin" ]; then
    run_rsync "$HOME/.local/bin/" "$BACKUP_DIR/custom-scripts/local_bin/" --no-perms --no-owner --no-group
else
    log_info "$HOME/.local/bin not found, skipping ~/.local/bin backup."
fi
log_success "Finished backing up custom scripts."

# --- 9. Backup GNOME settings (if applicable) ---
# dconf dump should be run as the user, not root
if command -v dconf >/dev/null 2>&1; then
    log_info "🖥️ Backing up GNOME settings using dconf..."
    mkdir -p "$BACKUP_DIR/gnome-settings" || log_error "Failed to create gnome-settings directory"
    # Using '|| true' to allow script to continue if command fails
    if dconf dump / > "$BACKUP_DIR/gnome-settings/dconf-settings.ini"; then
        log_success "GNOME settings backed up."
    else
        log_warning "Failed to backup GNOME settings."
        true # Ensure the if block returns true
    fi
else
    log_info "dconf not found, skipping GNOME settings backup."
fi

# --- 10. Backup UFW firewall rules (Requires sudo) ---
if command -v ufw >/dev/null 2>&1; then
    log_info "🔥 Backing up UFW firewall rules (requires sudo)..."
    mkdir -p "$BACKUP_DIR/ufw/" || log_error "Failed to create ufw directory"
    if sudo -v >/dev/null 2>&1; then # Check if user can sudo
        # Using '|| true' to allow script to continue if any ufw command fails
        # Note: ufw export writes to stdout, need to redirect it
        if sudo ufw status verbose > "$BACKUP_DIR/ufw/ufw-status-verbose.txt" 2>&1 && \
           sudo ufw status numbered > "$BACKUP_DIR/ufw/ufw-status-numbered.txt" 2>&1 && \
           sudo ufw export > "$BACKUP_DIR/ufw/ufw.rules"; then # ufw export is the key file for restoring
             log_success "UFW rules and status backed up."
        else
             log_warning "Failed to backup UFW rules. Check sudo permissions or UFW status."
             true # Ensure the if block returns true
        fi
    else
        log_warning "Sudo access required but not available. Cannot backup UFW rules."
    fi
else
    log_info "ufw not found, skipping UFW backup."
fi


# --- Archiving ---
# Moved trap creation earlier, right after temp dir creation
if [ "$ARCHIVE" = true ]; then
    log_info "📦 Creating archive..."

    ARCHIVE_FILE="$BACKUP_DEST_DIR/$FINAL_BACKUP_NAME.tar.${ARCHIVE_FORMAT}"
    tar_options="" # Removed 'local'

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
            # This should be caught by set -e due to log_error
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

# --- Post-Backup Actions: Open Directory ---

# Determine the final location to open based on whether archiving was done
path_to_open="" # Removed 'local'
if [ "$ARCHIVE" = true ]; then
    # If archived, the archive file is in BACKUP_DEST_DIR. Open that directory.
    path_to_open="$BACKUP_DEST_DIR"
    log_info "Backup archive created at ${ARCHIVE_FILE}." # Added this log here as it's the final outcome log
else
    # If not archived, the backup directory is in BACKUP_DEST_DIR. Open that directory.
    path_to_open="$BACKUP_DIR"
    # log_success "Backup completed successfully at $BACKUP_DIR." # This log was already above
fi

log_info "Attempting to open the backup location: '$path_to_open'..."
# Check if xdg-open exists and if we are in a graphical session
if command -v xdg-open >/dev/null 2>&1; then
    # Check for X11 DISPLAY or Wayland WAYLAND_DISPLAY
    if [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; then
        log_info "Opening directory '$path_to_open' with xdg-open..."
        # Use nohup and run in background (&) to detach from the script's terminal
        # Redirect output to /dev/null
        # Note: We explicitly do *NOT* use sudo xdg-open as it's incorrect for GUI apps
        nohup xdg-open "$path_to_open" > /dev/null 2>&1 &
        log_success "xdg-open command issued. The file manager window should appear shortly."
    else
        log_warning "Not in a graphical environment (DISPLAY and WAYLAND_DISPLAY are not set), skipping xdg-open."
    fi
else
    log_warning "xdg-open command not found. Cannot open the backup directory automatically."
fi

log_info "✨ Backup process finished." # This line is now reachable after xdg-open attempts


# ==============================================================================
# --- Restoration Notes ---
# ==============================================================================
# Restoration is a manual process.
#
# 1. Extract the archive (if created):
#    For .tar.xz: tar xvf /path/to/your/ubuntu-config-backup-YYYYMMDD_HHMMSS.tar.xz -C /tmp/restore_$$
#    For .tar.gz: tar xvf /path/to/your/ubuntu-config-backup-YYYYMMSS.tar.gz -C /tmp/restore_$$
#    Replace /path/to/your/ with the actual path. This extracts contents to a temporary directory.
#    Inside /tmp/restore_$$ you'll find the backup directory (e.g., ubuntu-config-backup-YYYYMMSS).
#
# 2. Restore items manually:
#    - Home config (rsync/copy): Copy files/directories back to your home directory using 'cp' or 'rsync', e.g.,
#      cp -a /tmp/restore_$$/ubuntu-config-backup-YYYYMMDD_HHMMSS/home-config-copy/.gitconfig ~/
#      rsync -avh /tmp/restore_$$/ubuntu-config-backup-YYYYMMDD_HHMMSS/home-config-rsync/.config/myapp/ ~/.config/myapp/
#      **Be cautious** when overwriting existing files, especially for directories like .config. Consider merging or backing up current configs first.
#      NOTE: User files were backed up without preserving ownership/permissions. Restore them as your user.
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
