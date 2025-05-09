#!/bin/bash

# ==============================================================================
# Linux User and Configuration Backup Script
# ==============================================================================
# This script backs up essential user configurations, dotfiles, package lists,
# and selected system configuration files on a Linux system.
# It is NOT a full system backup and does NOT include user data like Documents,
# Pictures, Videos, etc.
#
# This script attempts to be distribution-agnostic by checking for common
# tools and file locations. Not all items will exist on every system.
#
# Restoration is a MANUAL process and depends on the item being restored
# and the target distribution's package manager and file structure.
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
ARCHIVE_NAME="linux-config-backup" # Base name for the archive file/directory

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
    ".kshrc"                # Ksh configuration
    ".tcshrc"               # Tcsh configuration
    ".cshrc"                # Csh configuration
    ".config/fish"          # Fish shell configuration directory

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
    
    # Browser profiles (paths can vary slightly)
    ".mozilla/firefox"      # Firefox profiles (apply EXCLUDE_PATTERNS) - considers all profiles
    ".config/google-chrome" # Chrome profiles (can be large, relies on excludes)
    ".config/chromium"      # Chromium profiles
    ".config/vivaldi"       # Vivaldi browser
    ".config/BraveSoftware/Brave-Browser" # Brave browser
    ".config/microsoft-edge" # Edge browser

    # Email clients
    ".thunderbird"          # Thunderbird profiles (apply EXCLUDE_PATTERNS)
    ".config/evolution"     # Evolution mail client
    ".config/kmail2"        # KDE KMail
    ".config/akonadi"       # KDE Akonadi

    # Password managers
    ".config/keepassxc"     # KeePassXC
    ".password-store"       # Pass password manager

    # Chat and messaging
    ".config/Signal"        # Signal Desktop
    ".config/Element"       # Element/Matrix client
    ".config/discord"       # Discord configuration (not cache)
    ".config/telegram-desktop" # Telegram Desktop
    ".config/skypeforlinux" # Skype for Linux

    # Media applications
    ".config/vlc"           # VLC media player
    ".config/mpv"           # MPV media player
    ".ncmpcpp"              # Music player configuration
    ".config/spotify"       # Spotify (config only, not cache)
    ".config/audacious"     # Audacious media player
    ".config/smplayer"      # SMPlayer

    # System tools / DE related (paths can vary)
    ".config/htop"          # Process viewer configuration
    ".config/dconf"         # GNOME configuration database
    ".config/pulse"         # PulseAudio configuration
    ".config/pipewire"      # PipeWire configuration
    ".gnome"                # GNOME specific user settings
    ".config/systemd/user"  # User systemd services
    ".config/plasma-workspace" # KDE Plasma workspace config
    ".config/kde*"          # Other KDE config files/dirs
    ".config/xfce4"         # XFCE4 config
    ".config/lxqt"          # LXQt config
    ".config/lxde-qt"       # LXDE-Qt config
    ".config/openbox"       # Openbox config
    ".config/picom"         # Picom compositor config
    ".config/dunst"         # Dunst notification daemon config
    ".config/rofi"          # Rofi dmenu replacement config
    ".config/polybar"       # Polybar status bar config
    ".config/tint2"         # Tint2 panel config
    ".config/caja"          # Caja file manager (MATE)
    ".config/nemo"          # Nemo file manager (Cinnamon)
    ".config/thunar"        # Thunar file manager (XFCE)
    ".config/pcmanfm"       # PCManFM file manager (LXDE/LXQt)
    ".config/dolphinrc"     # Dolphin file manager (KDE)
    ".config/kdeglobals"    # KDE global settings
    ".config/kglobalshortcutsrc" # KDE global shortcuts
    ".config/kwinrc"        # KWin window manager config
    ".config/konsole"       # Konsole terminal (KDE)
    ".config/gnome-terminal" # GNOME Terminal
    ".config/xfce4/terminal" # XFCE Terminal

    # Virtual machines and containers
    ".vagrant.d"            # Vagrant configuration (not boxes)
    ".docker"               # Docker configuration (not images)
    ".VirtualBox"           # VirtualBox configuration (not VMs)
    ".config/libvirt"       # Libvirt configuration
    ".local/share/containers" # Podman/Buildah user config

    # Other applications
    ".config/sublime-text"  # Sublime Text editor
    ".config/inkscape"      # Inkscape
    ".config/GIMP"          # GIMP
    ".config/libreoffice"   # LibreOffice
    ".config/nextcloud"     # Nextcloud client
    ".config/remmina"       # Remote desktop client
    ".timewarrior"          # Time tracking
    ".taskwarrior"          # Task management
    ".config/ calibre"      # Calibre ebook management (config dir has space)
    ".config/syncthing"     # Syncthing client config
    ".config/kdeconnect"    # KDE Connect config
    ".config/filezilla"     # FileZilla client config
    ".config/gthumb"        # gThumb image viewer
    ".config/geany"         # Geany editor
    ".config/Mousepad"      # Mousepad editor (XFCE)
    ".config/pluma"         # Pluma editor (MATE)
    ".config/xed"           # Xed editor (Cinnamon)
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
    ".bash_history" # Included here for direct copy as a single file backup
    ".zsh_history"  # Included here for direct copy
    ".ksh_history"  # Included here for direct copy
    ".lesshst"      # Less history
    ".mysql_history"# MySQL client history
    ".psql_history" # PSQL history

    # Display configurations (can vary)
    ".Xresources"
    ".Xdefaults"
    ".xinitrc"
    ".xsessionrc"
    ".xprofile"
    ".Xmodmap"
    ".gtkrc-2.0"
    ".gtkrc-3.0"
    ".fonts.conf" # User font config file
    ".config/gtk-3.0/settings.ini"
    ".config/gtk-4.0/settings.ini"
    ".config/mimeapps.list"
    ".config/user-dirs.dirs"
    ".config/user-dirs.locale"
    ".ICEauthority" # Session authority (be cautious)
    ".dmrc"         # Display manager config file

    # Shell dotfiles
    ".curlrc"
    ".wgetrc"
    ".gemrc"
    ".pylintrc"
    ".condarc"
    ".npmrc"
    ".yarnrc"
    ".psqlrc"
    ".my.cnf" # MySQL client config
    ".irbrc"
    ".jshintrc"
    ".eslintrc"
    ".stylelintrc"
    ".selected_editor" # Often a symlink
    ".cvsrc"        # CVS config
    ".subversion"   # Subversion config dir

    # Application-specific files (examples, add more as needed)
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
    ".config/okularrc"      # Okular PDF viewer
    ".config/spectaclerc"   # Spectacle screenshot tool
    ".config/kcalcrc"       # KCalc calculator
    ".config/klipperrc"     # Klipper clipboard tool
    ".config/plasma-org.kde.plasma.desktop-appletsrc" # Plasma panel config
    ".config/plasmarc"      # Plasma config
    ".config/krunnerrc"     # KRunner config
    ".config/kactivitymanagerdrc" # Activity manager config
    ".config/katesettingsrc" # Kate editor settings
    ".config/katerc"        # Kate editor config
    ".config/gwenviewrc"    # Gwenview image viewer

    # Window Manager configurations (paths can vary)
    ".config/i3/config"
    ".config/sway/config"
    ".config/bspwm/bspwmrc"
    ".config/awesome/rc.lua"
    ".config/qtile/config.py"
    ".config/hypr/hyprland.conf"
    ".xmonad/xmonad.hs"     # XMonad config (Haskell)
    ".config/polybar/config"
    ".config/tint2/tint2rc" # Tint2 config file
    ".config/openbox/rc.xml" # Openbox config file
    ".config/xfce4/xfconf/xfce-perchannel-xml" # XFCE config (xml files in subdirs)
    ".config/lxqt/lxqt.conf"# LXQt main config
    ".config/lxde-qt/lxqt/lxqt.conf" # LXDE-Qt main config

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
    ".config/Code/User/settings.json" # VS Code user settings
    ".config/sublime-text-3/Packages/User/Preferences.sublime-settings" # Sublime Text settings
    ".config/Atom/config.cson" # Atom editor config

    # Network configurations
    ".netrc"
    ".wgetrc"
    ".ssh/config"
    ".config/remmina/remmina.pref"
    ".config/NetworkManager/system-connections" # User-saved NM connections

    # Email, chat, and calendar
    ".muttrc"
    ".config/neomutt/neomuttrc"
    ".offlineimaprc"
    ".msmtprc"
    ".config/khal/config"
    ".config/vdirsyncer/config"

    # System info/management
    ".fehbg"        # Feh background setter script
    ".xscreensaver" # XScreenSaver config file
    ".Xauthority"   # X authority file (be cautious)
    ".config/fontconfig/fonts.conf" # User font config directory/file (often a symlink)
    ".config/autostart-scripts" # Custom startup scripts directory
    ".config/systemd/user" # User systemd units (directory)
)


# List of patterns to EXCLUDE from the USER_CONFIG_RSYNC_ITEMS directories using rsync's --exclude.
# These help avoid large data/cache/temp files within potentially included config directories.
# Patterns are relative to the source directory being rsynced (e.g., if backing up .config,
# an exclude like "*/cache/*" will match .config/app/cache).
EXCLUDE_PATTERNS=(
    # General cache and temporary files (expanded)
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
    "*/.temp/*"             # Temp directory pattern
    "*/.trash/*"            # Trash directory pattern
    "*/thumbnails/*"        # Thumbnail caches
    "*/gvfs-metadata/*"     # GVFS metadata
    "*/recently-used.xbel"  # Recently used files list

    # Browser data (expanded)
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
    "*/Local Storage/*"     # Local storage data
    "*/Session Storage/*"   # Session storage data
    "*/Sync Data/*"         # Browser sync data (can be large)
    "*/Downloads/*"         # Browser download history (list of files, not the files themselves)
    "*/safebrowsing/*"      # Safe browsing data
    "*/Code Cache/*"        # Browser code cache
    "*/User Data/*/Cache/*" # Chrome/Edge user data cache
    "*/User Data/*/Service Worker/*" # Chrome/Edge service worker
    "*/User Data/*/Default/Cache/*" # Default profile cache
    "*/User Data/*/Default/Service Worker/*" # Default profile service worker
    "*/Profiles/*/Cache/*"  # Brave/Vivaldi profile cache
    "*/Profiles/*/Service Worker/*" # Brave/Vivaldi profile service worker
    "*/crashes/*"           # Browser crash reports

    # Application-specific caches (expanded)
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
    "*/Teams/Cache/*"       # Microsoft Teams cache
    "*/Teams/Code Cache/*"  # Microsoft Teams code cache
    "*/Skype/Cache/*"       # Skype cache
    "*/signal-desktop/Cache/*" # Signal cache
    "*/Postman/Cache/*"     # Postman cache
    "*/JetBrains/*/caches/*" # JetBrains IDEs caches
    "*/JetBrains/*/log/*"   # JetBrains IDEs logs
    "*/JetBrains/*/system/*" # JetBrains IDEs system files (large)
    "*/JetBrains/*/tmp/*"   # JetBrains IDEs temp files
    "*/calibre/cache/*"     # Calibre cache
    "*/syncthing/index/*"   # Syncthing index

    # Development tools and libraries (expanded)
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
    "*/zig-cache/*"         # Zig build cache
    "*/go-build/*"          # Go build cache (alternative)
    "*/__pycache__/*"       # Python bytecode cache
    "*/.mypy_cache/*"       # Mypy cache
    "*/.metals/*"           # Metals (Scala language server) cache
    "*/.bloop/*"            # Bloop (Scala build server) cache
    "*/.sbt/*"              # SBT cache/libraries
    "*/.stack/*"            # Haskell Stack build directory
    "*/.cabal/*"            # Haskell Cabal packages
    "*/.gradle/caches/*"    # Gradle caches
    "*/.m2/repository/*"    # Maven repository
    "*/.cache-sccache/*"    # Sccache cache
    "*/zig-out/*"           # Zig build output

    # Container and VM data (expanded)
    "*/.var/*"              # Flatpak data (usually large)
    "*/.local/share/flatpak/*" # Flatpak data (redundant if .var is excluded, but safer)
    "*/.local/share/containers/*" # Podman/Buildah data (might include large images/volumes)
    "*/.local/share/libvirt/*" # libvirt data (might include large VM images)
    "*/docker/overlay2/*"   # Docker overlays
    "*/docker/image/*"      # Docker images
    "*/docker/volumes/*"    # Docker volumes
    "*/VirtualBox VMs/*"    # VirtualBox VMs
    "*/VMs/*"               # Generic VMs directory
    "*/lxc/*"               # LXC containers
    "*/.vagrant.d/boxes/*"  # Vagrant boxes
    "*/.minikube/*"         # Minikube data
    "*/.kube/cache/*"       # Kubectl/Kubernetes cache
    "*/.kube/http-cache/*"  # Kubectl http cache
    "*/.crc/*"              # CodeReady Containers (OpenShift) data

    # Gaming and large application data (expanded)
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
    "*/Bottles/*"           # Bottles (Wine prefix manager)
    "*/.local/share/Steam/*" # Steam data (alternative)
    "*/.local/share/PrismLauncher/*" # Prism Launcher data
    "*/.minecraft/*"        # Minecraft data
    "*/.var/app/*/data/minecraft/*" # Flatpak Minecraft data

    # XDG directories and system data (expanded)
    "*/.local/share/Trash/*" # Trash
    "*/.local/share/icc/*"   # Color profiles
    "*/.local/share/gvfs-metadata/*" # GVFS metadata
    "*/.local/share/webkitgtk/*" # Webkit cache
    "*/.local/state/*"      # XDG State directory (often cache/runtime data)
    "*/.local/share/recently-used.xbel" # Recently used files
    "*/.local/share/thumbnails/*" # Thumbnails
    "*/.local/share/tracker/*" # GNOME tracker
    "*/.local/share/baloo/*" # KDE file indexer
    "*/.local/share/akonadi/*" # KDE PIM storage
    "*/.local/share/zeitgeist/*" # Activity logger
    "*/.local/share/telepathy/*" # IM framework
    "*/.pki/nssdb/*"        # NSS database (can be regenerated)
    "*/.esd_auth"           # ESD authentication
    "*/.goutputstream*"     # GNOME temporary files
    "*/dconf/user"          # Dconf user database (binary, backup with dconf dump)
    "*/gvfs/*"              # GVFS mount points
    "*/run/user/*"          # User runtime directory (temporary files)

    # Media cache/data (often large) (expanded)
    "*/Spotify/Data/*"      # Spotify data
    "*/spotify/Storage/*"   # Spotify storage
    "*/Podcasts/*"          # Podcast downloads
    "*/Music/iTunes/*"      # iTunes library
    "*/Pictures/Photos Library.photoslibrary/*" # Photos library
    "*/Videos/*"            # Video files
    "*/Downloads/*"         # Downloaded files
    "*/.local/share/Trash/*" # Trash (redundant, but belt-and-suspenders)
    "*/.recently-used*"     # Recently used files list

    # Miscellaneous large or unnecessary data (expanded)
    "*.localstorage"        # Local storage files
    "*/Dropbox/*"           # Dropbox files (often synced elsewhere)
    "*/OneDrive/*"          # OneDrive files (often synced elsewhere)
    "*/Google Drive/*"      # Google Drive files (often synced elsewhere)
    "*/Next Cloud/*"        # NextCloud files (often synced elsewhere)
    "*/iCloud/*"            # iCloud files (often synced elsewhere)
    "*/snap/*/current/*"    # Snap package data (user-specific)
    "*/snap/*/common/*"     # Snap common data (user-specific)
    "*/flatpak/app/*/cache/*" # Flatpak app cache
    "*/flatpak/app/*/files/*" # Flatpak app files (large)
    "*/flatpak/app/*/state/*" # Flatpak app state
    "*/flatpak/app/*/data/Steam/*" # Flatpak Steam data
    "*/flatpak/runtime/*"   # Flatpak runtimes (large)
    "*/.steam/*"            # Steam data (alternative)
    "*/.var/app/*/data/Steam/*" # Flatpak Steam data (redundant)
    "*/timeshift/*"         # Timeshift backups (should not be in home anyway)
)

# List of system configuration files and directories to back up.
# These REQUIRE sudo privileges. Select carefully.
# The script will check if these paths exist and skip if not.
# Add paths line by line, separated by spaces or newlines.
SYSTEM_CONFIG_ITEMS=(
    # System identification
    "/etc/fstab"             # Filesystem table
    "/etc/crypttab"          # Encrypted filesystems (can be sensitive)
    "/etc/mtab"              # Mounted filesystems (usually a symlink)
    "/etc/hosts"             # Host name resolution
    "/etc/hostname"          # System hostname
    "/etc/machine-id"        # Machine identifier
    "/etc/os-release"        # OS information (standard)
    "/etc/lsb-release"       # Distribution information (Debian/Ubuntu specific, but harmless)
    "/etc/redhat-release"    # RHEL/CentOS/Fedora release info
    "/etc/debian_version"    # Debian version info
    "/etc/arch-release"      # Arch Linux release info
    "/etc/SuSE-release"      # openSUSE release info

    # Network configuration
    "/etc/resolv.conf"       # DNS resolver configuration (often dynamic)
    "/etc/netplan"           # Netplan network configuration (Ubuntu)
    "/etc/network/interfaces" # Classical network configuration (Debian/Ubuntu)
    "/etc/network/interfaces.d" # Network interface configurations (Debian/Ubuntu)
    "/etc/NetworkManager/system-connections" # NetworkManager connections (common)
    "/etc/NetworkManager/conf.d" # NetworkManager configuration (common)
    "/etc/netctl"            # Arch Linux network manager
    "/etc/systemd/network"   # systemd network configuration (common)
    "/etc/sysconfig/network-scripts" # Red Hat/CentOS network config
    "/etc/sysconfig/network" # RHEL network config
    "/etc/hosts.allow"       # TCP wrappers allow rules
    "/etc/hosts.deny"        # TCP wrappers deny rules
    "/etc/nftables.conf"     # nftables firewall configuration
    "/etc/iptables"          # iptables firewall rules (directory might contain files)
    "/etc/iptables.rules"    # iptables rules file
    "/etc/iptables/rules.v4" # iptables v4 rules file
    "/etc/iptables/rules.v6" # iptables v6 rules file
    "/etc/firewalld"         # firewalld configuration (RHEL/Fedora/etc.)
    "/etc/sysconfig/iptables" # RHEL iptables config
    "/etc/ufw"               # UFW firewall configuration (Ubuntu/Debian)
    "/etc/dhcp"              # DHCP client/server configuration
    "/etc/wpa_supplicant"    # Wi-Fi configuration (common)
    "/etc/iproute2"          # IP routing configuration (common)
    "/etc/connman"           # ConnMan network manager
    "/etc/ppp"               # PPP configuration

    # System environment and settings
    "/etc/environment"       # System-wide environment variables
    "/etc/profile.d"         # Shell initialization scripts (common)
    "/etc/profile"           # System-wide profile
    "/etc/bash.bashrc"       # System-wide bashrc (Debian/Ubuntu/etc.)
    "/etc/bashrc"            # System-wide bashrc (RHEL/Fedora/etc.)
    "/etc/zsh"               # System-wide zsh configuration
    "/etc/ksh.kshrc"         # System-wide ksh config
    "/etc/csh.cshrc"         # System-wide csh config
    "/etc/login.defs"        # Shadow password suite configuration
    "/etc/inputrc"           # Readline configuration
    "/etc/locale.conf"       # System locale settings (systemd)
    "/etc/locale.gen"        # Locale generation configuration
    "/etc/default"           # Default settings for services (Debian/Ubuntu)
    "/etc/sysconfig"         # Configuration files (RHEL/Fedora/etc.)
    "/etc/sysctl.conf"       # Kernel parameters configuration
    "/etc/sysctl.d"          # Additional kernel parameters
    "/etc/security"          # PAM security settings (directory)
    "/etc/security/limits.conf" # Resource limits
    "/etc/security/limits.d" # Additional resource limits
    "/etc/modules"           # Kernel modules to load at boot (older)
    "/etc/modules-load.d"    # Additional kernel modules (systemd)
    "/etc/modprobe.d"        # Module blacklisting/options
    "/etc/vconsole.conf"     # Virtual console configuration (systemd)
    "/etc/systemd/system.conf" # systemd system configuration
    "/etc/systemd/user.conf" # systemd user configuration
    "/etc/systemd/journald.conf" # journald logging configuration
    "/etc/systemd/logind.conf" # logind session management configuration
    "/etc/systemd/resolved.conf" # systemd-resolved DNS resolver
    "/etc/systemd/timesyncd.conf" # systemd time sync daemon
    "/etc/systemd/system"    # systemd system unit files (directory)
    "/etc/systemd/user"      # systemd user unit files (directory)
    "/etc/tmpfiles.d"        # Temporary files configuration (systemd)
    "/etc/binfmt.d"          # Binary format support (systemd)
    "/etc/conf.d"            # Configuration files (Gentoo/Arch OpenRC)
    "/etc/rc.conf"           # Main init config (Arch OpenRC)
    "/etc/conf.d/net"        # OpenRC network config
    "/etc/local.d"           # Custom OpenRC scripts
    "/etc/rc.local"          # Startup script (if it exists)
    "/etc/init.d"            # Init scripts (SysV style / OpenRC)
    "/etc/inittab"           # Init configuration (SysV style)
    "/etc/lilo.conf"         # LILO bootloader config
    "/etc/kernel/cmdline"    # Kernel command line (systemd-boot)
    "/etc/kernel/efi-stub"   # EFI stub config (systemd-boot)
    "/etc/kernels"           # Kernel configurations (Gentoo)
    "/etc/motd"              # Message of the day (often dynamic)
    "/etc/issue"             # Pre-login message
    "/etc/issue.net"         # Pre-login message for network users
    "/etc/subuid"            # Subordinate UIDs
    "/etc/subgid"            # Subordinate GIDs

    # Package management
    "/etc/apt/sources.list"  # APT package sources (Debian/Ubuntu)
    "/etc/apt/sources.list.d" # Additional APT sources
    "/etc/apt/preferences"   # APT preferences
    "/etc/apt/preferences.d" # Additional APT preferences
    "/etc/apt/apt.conf"      # APT configuration
    "/etc/apt/apt.conf.d"    # Additional APT configuration
    "/etc/pacman.conf"       # Pacman package manager configuration (Arch)
    "/etc/pacman.d"          # Pacman additional configuration (directory)
    "/etc/yum.conf"          # Yum package manager (RHEL/CentOS)
    "/etc/yum.repos.d"       # Yum repositories
    "/etc/dnf/dnf.conf"      # DNF package manager (Fedora/RHEL)
    "/etc/dnf/modules.d"     # DNF modules configuration
    "/etc/zypp"              # Zypper package manager (openSUSE - directory)
    "/etc/portage"           # Portage package manager (Gentoo - directory)
    "/etc/flatpak"           # Flatpak configuration (system-wide)
    "/etc/package-manager"   # Placeholder for other package manager paths

    # Authentication and security
    "/etc/sudoers"           # VERY SENSITIVE! Sudo configuration
    "/etc/sudoers.d"         # Additional sudo rules
    "/etc/pam.d"             # PAM authentication configuration (directory)
    # "/etc/shadow"            # VERY SENSITIVE! Encrypted passwords (requires special handling - SKIPPING)
    # "/etc/gshadow"           # VERY SENSITIVE! Group passwords (requires special handling - SKIPPING)
    "/etc/group"             # Group definitions
    "/etc/passwd"            # User account information
    "/etc/subuid"            # Subordinate UIDs for unprivileged containers (Redhat/Fedora/etc.)
    "/etc/subgid"            # Subordinate GIDs for unprivileged containers (Redhat/Fedora/etc.)
    "/etc/ssh/sshd_config"   # SSH server configuration
    "/etc/ssh/ssh_config"    # SSH client configuration
    "/etc/ssh/moduli"        # SSH moduli file
    "/etc/ssl/certs"         # SSL certificates (common)
    "/etc/ssl/private"       # VERY SENSITIVE! SSL private keys
    "/etc/ca-certificates"   # CA certificates configuration (directory)
    "/etc/pki/tls/certs"     # RHEL/Fedora SSL certificates
    "/etc/pki/tls/private"   # RHEL/Fedora SSL private keys
    "/etc/pki/ca-trust"      # RHEL/Fedora CA trust
    "/etc/pki"               # Public Key Infrastructure (directory)
    "/etc/krb5.conf"         # Kerberos configuration (common)
    "/etc/krb5.conf.d"       # Kerberos configuration snippets
    "/etc/fail2ban"          # Fail2ban configuration (directory)
    "/etc/apparmor"          # AppArmor configuration (directory, Debian/Ubuntu)
    "/etc/apparmor.d"        # AppArmor profiles (directory, Debian/Ubuntu)
    "/etc/selinux"           # SELinux configuration (directory, RHEL/Fedora/etc.)
    "/etc/audit"             # Audit daemon configuration (directory)
    "/etc/opendoas/doas.conf"# OpenDoas configuration (alternative to sudo)
    "/etc/security/access.conf" # Access control list

    # Boot and system startup
    "/etc/default/grub"      # GRUB bootloader configuration (common)
    "/etc/grub.d"            # GRUB bootloader scripts (common)
    "/boot/grub/grub.cfg"    # GRUB configuration file (generated)
    "/boot/grub2/grub.cfg"   # GRUB2 configuration file (generated)
    "/boot/efi"              # EFI boot files (use with caution, often large)
    "/etc/systemd/system"    # systemd system unit files (redundant with above, but useful)
    "/etc/rc.d"              # Init scripts (RHEL/Fedora SysVinit)
    "/etc/init.d"            # Init scripts (Debian/Ubuntu SysVinit)
    "/etc/inittab"           # Init configuration (SysVinit)
    "/etc/dracut.conf"       # Initramfs generation (RHEL/Fedora)
    "/etc/dracut.conf.d"     # Additional initramfs configuration (RHEL/Fedora)
    "/etc/mkinitcpio.conf"   # Initramfs generation (Arch)
    "/etc/default/useradd"   # Default settings for new users (Debian/Ubuntu)
    "/etc/login.defs"        # Default settings for new users (RHEL/Fedora/etc.)
    "/etc/grub.conf"         # Older GRUB config location (RHEL)

    # Display managers and desktop environments (paths can vary)
    "/etc/lightdm"           # LightDM display manager config (directory)
    "/etc/gdm3"              # GDM3 display manager config (directory)
    "/etc/gdm"               # GDM display manager config (directory, older/alternative)
    "/etc/sddm.conf"         # SDDM display manager config (file)
    "/etc/sddm.conf.d"       # Additional SDDM configuration (directory)
    "/etc/X11/xorg.conf"     # X.org server config (if present)
    "/etc/X11/xorg.conf.d"   # X.org server config snippets (directory)
    "/etc/X11/xinit"         # X initialization (directory)
    "/etc/xdg"               # XDG base directory specification (directory)
    "/etc/skel"              # Skeleton directory for new users

    # File systems and storage
    "/etc/mdadm.conf"        # Software RAID configuration
    "/etc/mdadm/mdadm.conf"  # Alternative RAID config location
    "/etc/lvm"               # Logical Volume Manager configuration (directory)
    "/etc/multipath"         # Multipath device configuration (directory)
    "/etc/autofs"            # Automounter configuration (directory)
    "/etc/exports"           # NFS exports
    "/etc/samba/smb.conf"    # Samba configuration
    "/etc/updatedb.conf"     # updatedb configuration for locate
    "/etc/udisks2"           # Disk management configuration (directory)
    "/etc/systemd/journald.conf.d" # Journald configuration snippets

    # Services and daemons (paths can vary)
    "/etc/cron.d"            # Cron job directories
    "/etc/cron.daily"        # Daily cron jobs
    "/etc/cron.hourly"       # Hourly cron jobs
    "/etc/cron.monthly"      # Monthly cron jobs
    "/etc/cron.weekly"       # Weekly cron jobs
    "/etc/crontab"           # System crontab
    "/etc/anacrontab"        # Anacron configuration
    "/var/spool/cron"        # User crontabs (Needs sudo to read other users')
    "/etc/cups"              # CUPS printing system (directory)
    "/etc/ntp.conf"          # NTP configuration
    "/etc/chrony"            # Chrony time service (directory)
    "/etc/mysql"             # MySQL/MariaDB configuration (directory)
    "/etc/my.cnf"            # MySQL/MariaDB configuration (file)
    "/etc/my.cnf.d"          # MySQL/MariaDB configuration snippets
    "/etc/postgresql"        # PostgreSQL configuration (directory)
    "/etc/nginx"             # Nginx web server (directory)
    "/etc/apache2"           # Apache web server (Debian/Ubuntu - directory)
    "/etc/httpd"             # Apache web server (RHEL/CentOS - directory)
    "/etc/php"               # PHP configuration (directory)
    "/etc/postfix"           # Postfix mail server (directory)
    "/etc/dovecot"           # Dovecot mail server (directory)
    "/etc/openvpn"           # OpenVPN configuration (directory)
    "/etc/wireguard"         # WireGuard VPN (directory)
    "/etc/squid"             # Squid proxy (directory)
    "/etc/bind"              # BIND DNS server (directory)
    "/etc/named"             # BIND DNS (alternative location - directory)
    "/etc/nsd"               # NSD DNS server (directory)
    "/etc/dnsmasq.conf"      # Dnsmasq DNS/DHCP (file)
    "/etc/dnsmasq.d"         # Dnsmasq additional configuration (directory)
    "/etc/docker"            # Docker configuration (directory)
    "/etc/containerd"        # containerd configuration (directory)
    "/etc/cni"               # Container Network Interface (directory)
    "/etc/libvirt"           # Libvirt virtualization (directory)
    "/etc/qemu"              # QEMU virtualization (directory)
    "/etc/haproxy"           # HAProxy load balancer (directory)
    "/etc/redis"             # Redis database (directory)
    "/etc/mongodb"           # MongoDB database (directory)
    "/etc/memcached.conf"    # Memcached configuration (file)
    "/etc/pulse"             # PulseAudio sound server (directory)
    "/etc/pipewire"          # PipeWire sound server (directory)
    "/etc/bluetooth"         # Bluetooth configuration (directory)
    "/etc/rsyslog.conf"      # Rsyslog configuration (file)
    "/etc/rsyslog.d"         # Additional rsyslog configuration (directory)
    "/etc/syslog-ng"         # Syslog-ng configuration (directory)
    "/etc/logrotate.conf"    # Log rotation configuration (file)
    "/etc/logrotate.d"       # Additional log rotation configurations (directory)
    "/etc/snmp"              # SNMP configuration (directory)
    "/etc/zfs"               # ZFS configuration (directory)
    "/etc/udisks2"           # UDisks2 configuration (directory)
    "/etc/dbus-1/system.d"   # D-Bus system services
    "/etc/avahi"             # Avahi configuration (directory)
    "/etc/cups"              # CUPS printing system (directory)
    "/etc/polkit-1"          # PolicyKit configuration (directory)
    "/etc/dconf"             # Dconf system configuration (directory)
    "/etc/gconf"             # Gconf system configuration (directory, older)
    "/etc/sane.d"            # Scanner configuration (directory)

    # Hardware and peripherals
    "/etc/X11/xorg.conf.d"   # X.org configuration snippets (redundant with above)
    "/etc/udev/rules.d"      # udev rules (directory)
    "/etc/acpi"              # ACPI power management (directory)
    "/etc/sensors.d"         # Hardware sensors configuration (directory)
    "/etc/alsa"              # ALSA sound configuration (directory)
    "/etc/console-setup"     # Console setup (directory, Debian/Ubuntu)
    "/etc/conf.d/keymaps"    # Console keymap (OpenRC)
    "/etc/vconsole.conf"     # Console keymap (systemd)
    "/etc/default/console-setup" # Console setup defaults

    # Miscellaneous important configs
    "/etc/kernel"            # Kernel related configurations (directory)
    "/etc/fonts"             # Font configuration (directory)
    "/etc/alternatives"      # System alternatives (directory, Debian/Ubuntu)
    "/etc/mailcap"           # MIME type handlers
    "/etc/mime.types"        # MIME type definitions
    "/etc/shells"            # Valid login shells
    "/etc/timezone"          # System timezone (file)
    "/etc/localtime"         # Timezone symlink
    "/etc/default/locale"    # Default locale settings
    "/etc/adjtime"           # Hardware clock settings
    "/etc/release"           # Generic release file (can vary)
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
    # Use mktemp with a more generic prefix
    BACKUP_ROOT=$(mktemp -d -t "linux-backup-XXXXXXXXXX")
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
    # Add --no-perms, --no-owner, --no-group if backing up user files
    # System files (handled by sudo below) should preserve perms/owner
    if [[ "$src" == "$HOME"* ]]; then
         rsync_cmd+=(--no-perms --no-owner --no-group)
    fi
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
        return 1 # Indicate failure, but don't exit due to set -e in this case
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

    # Use cp -a for archive mode (preserves permissions, timestamps, etc.) for system files (run via sudo)
    # Use simple cp -r or cp for user files (run as user) to avoid permission issues
    if [[ "$src" == "$HOME"* ]]; then
        if [ -d "$src" ]; then
           if cp -r "$src" "$dest"; then # Use -r for directories
               log_success "Backed up '$item_name'."
           else
               log_warning "cp failed for '$item_name'. Continuing with other backups."
               return 1 # Indicate failure
           fi
        else
            if cp "$src" "$dest"; then # Use plain cp for files
                 log_success "Backed up '$item_name'."
            else
                 log_warning "cp failed for '$item_name'. Continuing with other backups."
                 return 1 # Indicate failure
            fi
        fi
    else # System files run via sudo
         if sudo cp -a "$src" "$dest"; then # Use cp -a for system files to preserve perms/owner/timestamps
             log_success "Backed up system config: '$item_name'."
         else
             log_warning "Failed to backup system config: '$item_name' (sudo cp failed)."
             return 1 # Indicate failure
         fi
    fi
}


# --- Main Backup Logic ---

log_info "🚀 Starting Linux configuration backup process."
log_info "Backup destination: ${BACKUP_DEST_DIR}"
log_info "Backup content path: ${BACKUP_DIR}"

# Check for essential commands
check_command "rsync"
check_command "crontab"
check_command "tar" # Needed for archiving
# dpkg, snap, flatpak, etc. are checked conditionally later

# --- 1. Backup specified user configuration items (using rsync) ---
log_info "📁 Backing up specified user configuration items with rsync..."
mkdir -p "$BACKUP_DIR/home-config-rsync/" || log_error "Failed to create directory for rsync user configs"
for item in "${USER_CONFIG_RSYNC_ITEMS[@]}"; do
    # Ensure source path exists and is within home directory
    if [ -e "$HOME/$item" ]; then
        # run_rsync function already handles the --no-perms/owner/group if source is in $HOME
        run_rsync "$HOME/$item" "$BACKUP_DIR/home-config-rsync/" "${EXCLUDE_PATTERNS[@]}" || true # Use || true to continue on failure
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
        # run_copy function already handles files/dirs appropriately
        run_copy "$HOME/$item" "$BACKUP_DIR/home-config-copy/$(basename "$HOME/$item")" || true # Use || true to continue on failure
    else
        log_info "$HOME/$item not found, skipping."
    fi
done
log_success "Finished backing up copy user configuration items."


# --- 3. Backup user-level cron jobs ---
log_info "🕒 Backing up user cron jobs..."
mkdir -p "$BACKUP_DIR/cronjobs" || log_error "Failed to create cronjobs directory"
# crontab -l reads the current *user's* crontab, doesn't need sudo if run as the user
if command -v crontab >/dev/null 2>&1; then
    if crontab -l > "$BACKUP_DIR/cronjobs/crontab.bak" 2>/dev/null; then
        log_success "User cron jobs backed up."
    else
        log_info "No user cron jobs found or error accessing them (output to /dev/null)."
        # Create an empty file to indicate this section was attempted
        touch "$BACKUP_DIR/cronjobs/crontab.bak.empty"
    fi
else
    log_info "crontab command not found, skipping user cron backup."
fi


# --- 4. Backup system-wide cron jobs (Requires sudo) ---
log_info "🛡️ Backing up system-wide cron jobs (requires sudo)..."
mkdir -p "$BACKUP_DIR/system-cron/" || log_error "Failed to create system-cron directory"
# Check for sudo access first
if sudo -v >/dev/null 2>&1; then
     log_info "Sudo access confirmed for system cron backup."
     # Using '|| true' to allow script to continue if sudo rsync fails
     if sudo rsync -avh /etc/cron* "$BACKUP_DIR/system-cron/"; then
          log_success "System-wide cron jobs backed up."
     else
          log_warning "sudo rsync failed for system cron jobs. Check permissions or sudo setup."
          true # Ensure the if block returns true
     fi
else
    log_warning "Sudo access required but not available. Cannot backup system cron jobs."
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
            # run_copy function handles the sudo cp -a call for system files
            if run_copy "$item" "$BACKUP_DIR/system-config/$(basename "$item")"; then
                 backed_up_system_config=true
            else
                 # run_copy already logged the warning
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
# This section is already quite general
log_info "📜 Backing up shell history..."
mkdir -p "$BACKUP_DIR/shell-history" || log_error "Failed to create shell-history directory"

declare -A history_files
history_files["bash"]="$HOME/.bash_history"
history_files["zsh"]="$HOME/.zsh_history"
history_files["fish"]="$HOME/.local/share/fish/fish_history" # Fish keeps history here by default
history_files["ksh"]="$HOME/.ksh_history"
history_files["tcsh"]="$HOME/.history" # Can vary, common location
history_files["csh"]="$HOME/.history"  # Can vary, common location

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

# Detect and backup using the appropriate package manager
if command -v dpkg >/dev/null 2>&1; then
    log_info "Backing up APT package list..."
    if sudo dpkg --get-selections > "$BACKUP_DIR/package-lists/dpkg-selections.list" || true; then
        log_success "Backed up APT package list (dpkg-selections)."
    else
        log_warning "Failed to backup APT package list (dpkg-selections). Requires sudo."
    fi
    # Attempt PPA list on Debian/Ubuntu if apt-add-repository exists
    if command -v apt-add-repository >/dev/null 2>&1; then
        log_info "Backing up PPA list..."
        if sudo apt-add-repository --list > "$BACKUP_DIR/package-lists/ppa-list.list" 2>&1 || true; then
            log_success "Backed up PPA list."
        else
            log_warning "Failed to backup PPA list. Requires sudo."
        fi
    fi

elif command -v pacman >/dev/null 2>&1; then
    log_info "Backing up Pacman package list..."
    # -Qq: quiet, only list packages; -e: explicitly installed; -n: native
    if pacman -Qqen > "$BACKUP_DIR/package-lists/pacman-explicit-native.list" || true; then
        log_success "Backed up Pacman explicit native package list."
    else
        log_warning "Failed to backup Pacman explicit native package list."
    fi
    # -Qqd: packages installed as dependencies
    if pacman -Qqd > "$BACKUP_DIR/package-lists/pacman-dependencies.list" || true; then
        log_success "Backed up Pacman dependency package list."
    else
        log_warning "Failed to backup Pacman dependency package list."
    fi

elif command -v dnf >/dev/null 2>&1; then
    log_info "Backing up DNF package list..."
    if dnf list installed --quiet > "$BACKUP_DIR/package-lists/dnf-installed.list" || true; then
        log_success "Backed up DNF installed package list."
    else
        log_warning "Failed to backup DNF installed package list."
    fi

elif command -v yum >/dev/null 2>&1; then
    log_info "Backing up YUM package list..."
     if yum list installed --quiet > "$BACKUP_DIR/package-lists/yum-installed.list" || true; then
        log_success "Backed up YUM installed package list."
    else
        log_warning "Failed to backup YUM installed package list."
    fi

elif command -v zypper >/dev/null 2>&1; then
     log_info "Backing up Zypper package list..."
     # se: search, -i: installed only, -s: showrepo (optional, adds repo info)
     if zypper se --installed-only > "$BACKUP_DIR/package-lists/zypper-installed.list" || true; then
         log_success "Backed up Zypper installed package list."
     else
         log_warning "Failed to backup Zypper installed package list."
     fi

else
    log_warning "No supported package manager found (dpkg, pacman, dnf, yum, zypper), skipping package list backup."
    touch "$BACKUP_DIR/package-lists/package-lists.bak.skipped"
fi

# Snap packages (checked regardless of main package manager)
if command -v snap >/dev/null 2>&1; then
    log_info "Backing up Snap package list..."
    if snap list > "$BACKUP_DIR/package-lists/snap-packages.list" || true; then
        log_success "Backed up Snap package list."
    else
        log_warning "Failed to backup Snap package list."
    fi
fi

# Flatpak packages (checked regardless of main package manager)
if command -v flatpak >/dev/null 2>&1; then
     log_info "Backing up Flatpak package list..."
     if flatpak list > "$BACKUP_DIR/package-lists/flatpak-packages.list" || true; then
        log_success "Backed up Flatpak package list."
    else
        log_warning "Failed to backup Flatpak package list."
    fi
fi

# RPM packages (fallback for RPM-based systems if dnf/yum/zypper commands fail or aren't preferred)
if command -v rpm >/dev/null 2>&1; then
     # Only run this if no other package manager list was successfully backed up
     if [ ! -f "$BACKUP_DIR/package-lists/dpkg-selections.list" ] && \
        [ ! -f "$BACKUP_DIR/package-lists/pacman-explicit-native.list" ] && \
        [ ! -f "$BACKUP_DIR/package-lists/dnf-installed.list" ] && \
        [ ! -f "$BACKUP_DIR/package-lists/yum-installed.list" ] && \
        [ ! -f "$BACKUP_DIR/package-lists/zypper-installed.list" ]; then
         log_info "Backing up RPM package list (fallback)..."
         if rpm -qa > "$BACKUP_DIR/package-lists/rpm-qa.list" || true; then
            log_success "Backed up RPM package list."
         else
            log_warning "Failed to backup RPM package list."
         fi
     fi
fi

log_success "Finished backing up package lists."

# --- 8. Backup custom scripts from ~/bin and ~/.local/bin ---
log_info "📝 Backing up custom scripts from ~/bin and ~/.local/bin..."
mkdir -p "$BACKUP_DIR/custom-scripts/" || log_error "Failed to create custom-scripts directory"

if [ -d "$HOME/bin" ]; then
    # run_rsync handles the --no-perms/owner/group
    run_rsync "$HOME/bin/" "$BACKUP_DIR/custom-scripts/bin/" || true # Use || true to continue on failure
else
    log_info "$HOME/bin not found, skipping ~/bin backup."
fi

if [ -d "$HOME/.local/bin" ]; then
    # run_rsync handles the --no-perms/owner/group
    run_rsync "$HOME/.local/bin/" "$BACKUP_DIR/custom-scripts/local_bin/" || true # Use || true to continue on failure
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
    if dconf dump / > "$BACKUP_DIR/gnome-settings/dconf-settings.ini" || true; then
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
    tar_options=""

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
path_to_open=""
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
        # Give xdg-open a moment to start before the script exits, especially if not archiving
        if [ "$ARCHIVE" != true ]; then
             sleep 1
        fi
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
# Restoration is a manual process and is distribution-dependent.
#
# 1. Extract the archive (if created):
#    For .tar.xz: tar xvf /path/to/your/linux-config-backup-YYYYMMDD_HHMMSS.tar.xz -C /tmp/restore_$$
#    For .tar.gz: tar xvf /path/to/your/linux-config-backup-YYYYMMSS.tar.gz -C /tmp/restore_$$
#    Replace /path/to/your/ with the actual path. This extracts contents to a temporary directory.
#    Inside /tmp/restore_$$ you'll find the backup directory (e.g., linux-config-backup-YYYYMMDD_HHMMSS).
#
# 2. Restore items manually:
#    - Home config (rsync/copy): Copy files/directories back to your home directory using 'cp' or 'rsync', e.g.,
#      cp -a /tmp/restore_$$/linux-config-backup-YYYYMMDD_HHMMSS/home-config-copy/.gitconfig ~/
#      rsync -avh /tmp/restore_$$/linux-config-backup-YYYYMMSS/home-config-rsync/.config/myapp/ ~/.config/myapp/
#      **Be cautious** when overwriting existing files, especially for directories like .config. Consider merging or backing up current configs first.
#      NOTE: User files were backed up without preserving ownership/permissions. Restore them as your user.
#    - Cron jobs: Use 'crontab /tmp/restore_$$/.../cronjobs/crontab.bak'. This *replaces* your current user cron.
#    - System cron jobs: Manually copy files from /tmp/restore_$$/.../system-cron/ to /etc/cron* etc. (requires sudo).
#    - System config files: Manually copy files/directories from /tmp/restore_$$/.../system-config/ to their original locations (e.g., /etc/fstab, /etc/apache2/). **EXTREME CAUTION REQUIRED.** Incorrect system files can prevent your system from booting. Always back up existing files before replacing them. (Requires sudo).
#    - Shell history: Manually copy the backup files from /tmp/restore_$$/.../shell-history/ to replace/merge with your current history files (e.g., ~/.bash_history, ~/.zsh_history).
#    - Package lists:
#      - **Distribution specific!** Review the files in the 'package-lists' directory.
#      - For Debian/Ubuntu (dpkg-selections.list): Use 'sudo dpkg --set-selections < /path/to/dpkg-selections.list' then 'sudo apt-get dselect-upgrade' or 'sudo apt upgrade'. PPAs (ppa-list.list) need to be added manually using 'sudo add-apt-repository'.
#      - For Arch Linux (pacman-explicit-native.list): Use 'sudo pacman -S --needed - < /path/to/pacman-explicit-native.list'.
#      - For Fedora/RHEL (dnf-installed.list) or CentOS/older RHEL (yum-installed.list): Manually review the list or look into converting it for package installation on the new system. `rpm -qa` is a raw list.
#      - For openSUSE (zypper-installed.list): Manually review or look into converting for installation.
#      - Snap/Flatpak: Manually review the lists and install using 'snap install <package>' or 'flatpak install <remote> <package>'.
#    - Custom scripts: Copy contents of /tmp/restore_$$/.../custom-scripts/bin/ to ~/bin/ and /tmp/restore_$$/.../custom-scripts/local_bin/ to ~/.local/bin/.
#    - GNOME settings (dconf): Use 'dconf load / < /tmp/restore_$$/.../gnome-settings/dconf-settings.ini'. **This will overwrite your current dconf settings.**
#    - UFW rules: The file /tmp/restore_$$/.../ufw/ufw.rules is the primary backup. You can try 'sudo ufw import /tmp/restore_$$/.../ufw/ufw.rules'. **Use with extreme caution** as incorrect rules can block access. It's often safer to review the file and manually re-add rules using 'sudo ufw allow/deny ...'.
#    - Other specific configs: Review the contents of `home-config-copy`, `home-config-rsync`, `system-config`, `custom-scripts`, `gnome-settings`, `ufw`. Restore specific files manually as needed, paying attention to permissions (user files as your user, system files with sudo).
#
# 3. Clean up the temporary restore directory: rm -rf /tmp/restore_$$*
