#!/usr/bin/env bash
#=============================================================================
# Linux Network Security & Firewall Configuration Script
#
# Portable across major Linux families:
#   - Debian / Ubuntu / Raspberry Pi OS   (apt, ufw, ssh.service, auth.log)
#   - RHEL / Fedora / Rocky / Alma        (dnf, firewalld, sshd.service, secure)
#   - Arch / Manjaro / EndeavourOS        (pacman, ufw or nftables, sshd.service)
#   - openSUSE / SLES                     (zypper, firewalld, sshd.service)
#   - Alpine                              (apk, nftables, OpenRC)
#
# Version: 2.2
#
# Improvements over 2.0:
#   - Concurrency-safe (flock)
#   - SSH lock-out prevention (allow SSH before any reset)
#   - sshd_config validated; refuses to disable PasswordAuth without a key
#   - --dry-run preview, --restore-ssh rollback, --add-wg-client peering
#   - fail2ban wired in (cross-distro), backup rotation, ANSI-stripped log
#   - Extended audit: SUID binaries, pending updates, weak file modes
#
# New in 2.2 — physical / workstation layer (laptops, portable machines):
#   - USBGuard default-deny, seeded from a snapshot of currently-attached
#     devices, with a hard refusal to lock out a USB keyboard in active use
#   - Bluetooth off + transport blacklist derived from the running kernel
#   - MAC randomisation across NetworkManager / iwd / systemd-networkd
#   - modprobe blacklist for DMA-capable buses and rarely-used network
#     protocols / filesystems, skipping anything actually in use
#   - Kernel cmdline hardening: IOMMU, early-PCI-DMA off, lockdown, allocator
#     hardening — parameters chosen per architecture and firmware type
#   - Evil-maid posture: idle lock, lid lock, Ctrl-Alt-Del masked, console
#     timeout, Secure Boot / TPM / LUKS reporting
#   - --physical-audit: one-shot report of the whole physical attack surface
#
# Nothing in 2.2 assumes particular hardware or a particular OS layout. Every
# module detects first and degrades to advice when a facility is absent:
#   arch      x86 / ARM / RISC-V / other  — IOMMU and vsyscall params differ,
#                                           and are omitted where meaningless
#   firmware  UEFI / BIOS / device-tree   — Secure Boot and efi= params are
#                                           UEFI-only; SBCs get fuse guidance
#   boot      limine / GRUB / UKI / systemd-boot / rEFInd / syslinux-extlinux
#   init      systemd / OpenRC / other    — logind config is systemd-only
#   network   NetworkManager / iwd / systemd-networkd / wpa_supplicant
#   session   any of 11 screen lockers, detected not assumed
#   machine   DMI or device-tree identity; VMs and desktops are told which
#             parts of the physical layer do not apply to them
#
# The 2.2 modules are OFF by default and excluded from --install-all. Enable
# them with --workstation or the individual flags: default-deny USB and kernel
# cmdline edits can render the wrong host unusable if applied blind.
#=============================================================================

set -Euo pipefail

# --- Defaults (override via env or /etc/linux-security-setup.conf) ---------

SSH_PORT="${SSH_PORT:-22}"
ALLOWED_SSH_IPS="${ALLOWED_SSH_IPS:-}"
ENABLE_VPN="${ENABLE_VPN:-false}"
VPN_PORT="${VPN_PORT:-51820}"
ENABLE_INTRUSION_DETECTION="${ENABLE_INTRUSION_DETECTION:-true}"
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-true}"
LOCAL_NETWORK="${LOCAL_NETWORK:-192.168.1.0/24}"
ENABLE_CERTIFICATES="${ENABLE_CERTIFICATES:-false}"
DOMAIN_NAME="${DOMAIN_NAME:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-root@localhost}"
FIREWALL_BACKEND="${FIREWALL_BACKEND:-auto}"     # auto|ufw|firewalld|nftables
DRY_RUN="${DRY_RUN:-false}"
SSH_BACKUP_KEEP="${SSH_BACKUP_KEEP:-5}"

# Hardening toggles (copied from a real Pi5/Pi4 deployment)
ENABLE_SYSCTL_HARDENING="${ENABLE_SYSCTL_HARDENING:-true}"
ENABLE_AUTO_UPDATES="${ENABLE_AUTO_UPDATES:-true}"
ENABLE_LYNIS="${ENABLE_LYNIS:-true}"
ENABLE_CHKROOTKIT="${ENABLE_CHKROOTKIT:-true}"
ENABLE_SSH_BANNER="${ENABLE_SSH_BANNER:-true}"
ENABLE_MAC="${ENABLE_MAC:-true}"                  # AppArmor or SELinux enforcement
ENABLE_LOGWATCH="${ENABLE_LOGWATCH:-false}"
ENABLE_CROWDSEC="${ENABLE_CROWDSEC:-false}"       # opt-in: adds external repo
DISABLE_SERVICES="${DISABLE_SERVICES:-}"          # CSV of unit names to mask/stop

# --- Physical / workstation layer (2.2) ------------------------------------
# All default false. These target a portable machine an attacker can touch:
# malicious USB peripherals, BadUSB, removable storage, DMA over an external
# bus, unauthorised network attachment, and unattended/evil-maid access.
# --install-all does NOT run these; use --workstation or the single flags.

ENABLE_USBGUARD="${ENABLE_USBGUARD:-false}"           # default-deny USB
ENABLE_BLUETOOTH_OFF="${ENABLE_BLUETOOTH_OFF:-false}" # stop+mask+blacklist BT
ENABLE_WIFI_PRIVACY="${ENABLE_WIFI_PRIVACY:-false}"   # NM MAC randomisation
ENABLE_MODULE_BLACKLIST="${ENABLE_MODULE_BLACKLIST:-false}"
ENABLE_KERNEL_CMDLINE="${ENABLE_KERNEL_CMDLINE:-false}" # edits the bootloader
ENABLE_IDLE_LOCK="${ENABLE_IDLE_LOCK:-false}"         # logind idle/lid lock

# USBGuard tuning.
# USBGUARD_ALLOW_HID=true keeps *any* keyboard/mouse working after lockdown.
# It is the safe default because a bricked input path on a headless or
# USB-keyboard host means a rescue disk; it also weakens the policy against
# BadUSB, which impersonates exactly that device class. Set it to false only
# on a machine whose keyboard is not on the USB bus — an i8042/PS-2 laptop
# keyboard and an I2C touchpad both qualify, and --physical-audit tells you.
USBGUARD_ALLOW_HID="${USBGUARD_ALLOW_HID:-true}"
USBGUARD_BLOCK_STORAGE="${USBGUARD_BLOCK_STORAGE:-false}" # also blacklist usb-storage

# Kernel cmdline tuning (only consulted when ENABLE_KERNEL_CMDLINE=true).
# lockdown=integrity blocks hibernation (suspend-to-disk) and /dev/mem writes.
# Left at "none" because a laptop with resume=/resume_offset= on its current
# cmdline is using hibernation; setup_kernel_cmdline refuses the combination.
LOCKDOWN_MODE="${LOCKDOWN_MODE:-none}"            # none|integrity|confidentiality
KERNEL_CMDLINE_EXTRA="${KERNEL_CMDLINE_EXTRA:-}"  # appended verbatim

# Idle lock tuning.
IDLE_LOCK_SECS="${IDLE_LOCK_SECS:-300}"           # logind IdleActionSec
CONSOLE_TIMEOUT_SECS="${CONSOLE_TIMEOUT_SECS:-600}" # shell TMOUT on tty

# Application ports allowed from $LOCAL_NETWORK. Format: "PORT/PROTO:Name".
# Empty by default — bash arrays don't cross env vars, so override via the
# config file ($CONFIG_FILE, default /etc/linux-security-setup.conf):
#   APP_PORTS=("8096/tcp:Jellyfin" "3000/tcp:Grafana")
APP_PORTS=()

# Optional config file override
CONFIG_FILE="${CONFIG_FILE:-/etc/linux-security-setup.conf}"
# shellcheck source=/dev/null
[ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"

# --- Paths -----------------------------------------------------------------

LOG_FILE="/var/log/linux-security-setup.log"
# Use /run (always tmpfs-mounted on modern Linux) rather than /var/lock, which is
# a dangling symlink to /run/lock on minimal containers.
LOCK_FILE="${LOCK_FILE:-/run/linux-security-setup.lock}"
SCRIPT_NAME="$(basename "$0")"

# --- Output ----------------------------------------------------------------

# Strip ANSI codes when writing to the log; keep them on terminal.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; DIM=$'\033[2m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; DIM=''; NC=''
fi

_log() {  # _log LEVEL MSG  (writes plain text to log file, colored to stdout/stderr)
    local level="$1" msg="$2" color="" stream="${3:-1}"
    case "$level" in
        INFO)  color="$GREEN" ;;
        WARN)  color="$YELLOW" ;;
        ERROR) color="$RED" ;;
        OK)    color="$GREEN" ;;
        SECT)  color="$BLUE" ;;
        DRY)   color="$DIM" ;;
    esac
    if [ "$stream" = "2" ]; then
        printf '%s[%s]%s %s\n' "$color" "$level" "$NC" "$msg" >&2
    else
        printf '%s[%s]%s %s\n' "$color" "$level" "$NC" "$msg"
    fi
    # Plain-text mirror to log file
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg" >> "$LOG_FILE"
}

print_status()  { _log INFO  "$1"; }
print_ok()      { _log OK    "$1"; }
print_warning() { _log WARN  "$1"; }
# print_dry uses stderr so it survives '>/dev/null' redirects on callers.
print_dry()     { _log DRY   "would run: $1" 2; }
print_error()   { _log ERROR "$1" 2; exit 1; }
print_section() {
    printf '\n%s=== %s ===%s\n\n' "$BLUE" "$1" "$NC"
    printf '\n=== %s ===\n\n' "$1" >> "$LOG_FILE"
}

# --- Trap, lock, dry-run ---------------------------------------------------

exec 3>&2   # preserve original stderr so trap output isn't hidden behind redirects

on_error() {
    local exit_code=$? line="$1" cmd="${2:-}"
    printf '%s[ERROR]%s Failed at %s:%s (exit=%s): %s\n' \
        "$RED" "$NC" "$SCRIPT_NAME" "$line" "$exit_code" "$cmd" >&3
    printf '%s [ERROR] Failed at %s:%s (exit=%s): %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$SCRIPT_NAME" "$line" "$exit_code" "$cmd" >> "$LOG_FILE"
    exit "$exit_code"
}
trap 'on_error $LINENO "$BASH_COMMAND"' ERR

check_root() { [ "$(id -u)" -eq 0 ] || print_error "Run as root (or with sudo)."; }

acquire_lock() {
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        print_error "Another instance is running (lock: $LOCK_FILE)."
    fi
}

# run CMD ARGS...  — respects DRY_RUN
run() {
    if [ "$DRY_RUN" = true ]; then
        print_dry "$*"
        return 0
    fi
    "$@"
}

# Stream rewrite under dry-run (e.g. heredoc -> file). Usage: write_to PATH
write_to() {
    local path="$1"
    if [ "$DRY_RUN" = true ]; then
        print_dry "write to $path:"
        sed 's/^/    | /' >&2
        return 0
    fi
    cat > "$path"
}

# --- Helpers ---------------------------------------------------------------

csv_to_array() {  # csv_to_array "1.2.3.4,5.6.7.8" -> stdout one per line
    local IFS=','; local s="$1"
    read -ra _arr <<< "$s"
    local x
    for x in "${_arr[@]}"; do
        x="${x#"${x%%[![:space:]]*}"}"  # ltrim
        x="${x%"${x##*[![:space:]]}"}"  # rtrim
        [ -n "$x" ] && printf '%s\n' "$x"
    done
}

require_cmds() {
    local missing=()
    for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
    if [ "${#missing[@]}" -gt 0 ]; then
        print_warning "Missing commands: ${missing[*]} (will attempt install where possible)"
        return 1
    fi
}

# --- Distro detection ------------------------------------------------------

DISTRO_ID=""; DISTRO_LIKE=""; PKG_FAMILY=""; INIT_SYSTEM=""
SSH_SERVICE=""; AUTH_LOG=""; DEFAULT_IFACE=""
CRON_WEEKLY=""; CRON_DAILY=""

detect_distro() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DISTRO_ID="${ID:-}"
        DISTRO_LIKE="${ID_LIKE:-}"
    fi

    case "$DISTRO_ID" in
        debian|ubuntu|raspbian|linuxmint|pop|elementary) PKG_FAMILY="debian" ;;
        fedora|rhel|centos|rocky|almalinux|amzn|ol)      PKG_FAMILY="rhel" ;;
        arch|manjaro|endeavouros|garuda|cachyos)         PKG_FAMILY="arch" ;;
        alpine)                                          PKG_FAMILY="alpine" ;;
        opensuse*|sles|sled)                             PKG_FAMILY="suse" ;;
        *)
            case " $DISTRO_LIKE " in
                *debian*)                  PKG_FAMILY="debian" ;;
                *fedora*|*rhel*|*centos*)  PKG_FAMILY="rhel" ;;
                *arch*)                    PKG_FAMILY="arch" ;;
                *suse*)                    PKG_FAMILY="suse" ;;
                *) print_error "Unsupported distro: ID=$DISTRO_ID ID_LIKE=$DISTRO_LIKE" ;;
            esac
            ;;
    esac

    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
    else
        INIT_SYSTEM="unknown"
    fi

    case "$PKG_FAMILY" in
        debian) SSH_SERVICE="ssh" ;;
        *)      SSH_SERVICE="sshd" ;;
    esac

    for candidate in /var/log/auth.log /var/log/secure; do
        [ -f "$candidate" ] && AUTH_LOG="$candidate" && break
    done

    DEFAULT_IFACE="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"

    # Cron path: Debian/RHEL/SUSE/Arch use /etc/cron.{daily,weekly}; Alpine's
    # busybox crond uses /etc/periodic/{daily,weekly}.
    if   [ -d /etc/cron.weekly ];     then CRON_WEEKLY=/etc/cron.weekly;     CRON_DAILY=/etc/cron.daily
    elif [ -d /etc/periodic/weekly ]; then CRON_WEEKLY=/etc/periodic/weekly; CRON_DAILY=/etc/periodic/daily
    else
        # No cron dir found yet — install one. cronie/cron is the cross-distro default.
        case "$PKG_FAMILY" in
            arch|rhel|suse) CRON_WEEKLY=/etc/cron.weekly;     CRON_DAILY=/etc/cron.daily ;;
            alpine)         CRON_WEEKLY=/etc/periodic/weekly; CRON_DAILY=/etc/periodic/daily ;;
            *)              CRON_WEEKLY=/etc/cron.weekly;     CRON_DAILY=/etc/cron.daily ;;
        esac
    fi

    print_status "Detected: $DISTRO_ID (family=$PKG_FAMILY, init=$INIT_SYSTEM)"
    print_status "SSH service: $SSH_SERVICE | auth log: ${AUTH_LOG:-journalctl} | iface: ${DEFAULT_IFACE:-unknown}"
    print_status "Cron dirs: weekly=$CRON_WEEKLY daily=$CRON_DAILY"
}

# --- Package manager abstraction ------------------------------------------

pkg_update() {
    case "$PKG_FAMILY" in
        debian) run env DEBIAN_FRONTEND=noninteractive apt-get update -qq ;;
        rhel)   run sh -c 'dnf -y makecache 2>/dev/null || yum -y makecache' ;;
        arch)   run pacman -Sy --noconfirm ;;
        alpine) run apk update ;;
        suse)   run zypper --non-interactive refresh ;;
    esac
}

pkg_install() {
    [ "$#" -eq 0 ] && return 0
    case "$PKG_FAMILY" in
        debian) run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" ;;
        rhel)   run sh -c "dnf install -y $* 2>/dev/null || yum install -y $*" ;;
        arch)   run pacman -Sy --noconfirm --needed "$@" ;;
        alpine) run apk add --no-cache "$@" ;;
        suse)   run zypper --non-interactive install --no-recommends "$@" ;;
    esac
}

pkg_has() { command -v "$1" >/dev/null 2>&1; }

pkg_name_for() {
    local generic="$1"
    case "$generic:$PKG_FAMILY" in
        wireguard:debian)   echo "wireguard wireguard-tools" ;;
        wireguard:*)        echo "wireguard-tools" ;;
        certbot:*)          echo "certbot" ;;
        rkhunter:*)         echo "rkhunter" ;;
        psad:debian)        echo "psad" ;;
        psad:*)             echo "" ;;
        fail2ban:*)         echo "fail2ban" ;;
        netmon:alpine)      echo "iftop vnstat" ;;
        netmon:*)           echo "nethogs iftop vnstat" ;;
        qrencode:*)         echo "qrencode" ;;
        *)                  echo "$generic" ;;
    esac
}

# --- Service abstraction ---------------------------------------------------

svc_enable_now() {
    local svc="$1"
    case "$INIT_SYSTEM" in
        systemd) run systemctl enable --now "$svc" ;;
        openrc)  run rc-update add "$svc" default && run rc-service "$svc" start ;;
        *)       print_warning "Cannot manage service $svc (init=$INIT_SYSTEM)" ;;
    esac
}

svc_restart() {
    case "$INIT_SYSTEM" in
        systemd) run systemctl restart "$1" ;;
        openrc)  run rc-service "$1" restart ;;
    esac
}

# --- Firewall selection ----------------------------------------------------

FIREWALL=""

select_firewall() {
    if [ "$FIREWALL_BACKEND" != "auto" ]; then
        FIREWALL="$FIREWALL_BACKEND"
    else
        case "$PKG_FAMILY" in
            debian|arch) FIREWALL="ufw" ;;
            rhel|suse)   FIREWALL="firewalld" ;;
            alpine)      FIREWALL="nftables" ;;
            *)           FIREWALL="nftables" ;;
        esac
    fi
    print_status "Firewall backend: $FIREWALL"
}

# --- UFW -------------------------------------------------------------------

setup_ufw() {
    pkg_has ufw || { pkg_update; pkg_install ufw; }

    # LOCK-OUT PREVENTION: allow SSH *first*, then reset, then re-apply rules.
    print_status "Pre-staging SSH allow before reset..."
    run ufw allow "$SSH_PORT"/tcp >/dev/null

    print_status "Resetting UFW..."
    run ufw --force reset >/dev/null

    run ufw default deny incoming
    run ufw default allow outgoing

    if [ -n "$ALLOWED_SSH_IPS" ]; then
        while IFS= read -r ip; do
            run ufw allow from "$ip" to any port "$SSH_PORT" proto tcp comment "SSH from $ip"
        done < <(csv_to_array "$ALLOWED_SSH_IPS")
    else
        run ufw allow "$SSH_PORT"/tcp comment "SSH"
        print_warning "SSH open to anywhere. Set ALLOWED_SSH_IPS to restrict."
    fi

    run ufw allow from "$LOCAL_NETWORK" comment "LAN"

    for entry in "${APP_PORTS[@]}"; do
        local portproto="${entry%%:*}" name="${entry##*:}"
        local port="${portproto%/*}" proto="${portproto#*/}"
        run ufw allow from "$LOCAL_NETWORK" to any port "$port" proto "$proto" comment "$name"
        print_status "LAN -> $name ($port/$proto)"
    done

    [ "$ENABLE_VPN" = true ] && run ufw allow "$VPN_PORT"/udp comment "WireGuard"

    run ufw limit "$SSH_PORT"/tcp >/dev/null || true
    run ufw --force enable
    if [ "$DRY_RUN" != true ] && pkg_has ufw; then
        ufw status verbose | tee -a "$LOG_FILE" || true
    fi
}

# --- firewalld -------------------------------------------------------------

setup_firewalld() {
    pkg_has firewall-cmd || { pkg_update; pkg_install firewalld; }
    svc_enable_now firewalld

    local zone="public"
    print_status "Configuring firewalld zone=$zone"

    run firewall-cmd --permanent --zone=trusted --add-source="$LOCAL_NETWORK" >/dev/null

    if [ -n "$ALLOWED_SSH_IPS" ]; then
        run firewall-cmd --permanent --zone="$zone" --remove-service=ssh >/dev/null 2>&1 || true
        while IFS= read -r ip; do
            run firewall-cmd --permanent --zone="$zone" \
                --add-rich-rule="rule family=ipv4 source address=$ip port port=$SSH_PORT protocol=tcp accept" >/dev/null
        done < <(csv_to_array "$ALLOWED_SSH_IPS")
    else
        run firewall-cmd --permanent --zone="$zone" --add-port="$SSH_PORT/tcp" >/dev/null
        print_warning "SSH open to anywhere. Set ALLOWED_SSH_IPS to restrict."
    fi

    for entry in "${APP_PORTS[@]}"; do
        local portproto="${entry%%:*}"
        run firewall-cmd --permanent --zone=trusted --add-port="$portproto" >/dev/null
    done

    [ "$ENABLE_VPN" = true ] && run firewall-cmd --permanent --zone="$zone" --add-port="$VPN_PORT/udp" >/dev/null

    run firewall-cmd --reload
    if [ "$DRY_RUN" != true ] && pkg_has firewall-cmd; then
        firewall-cmd --list-all | tee -a "$LOG_FILE" || true
    fi
}

# --- nftables --------------------------------------------------------------

setup_nftables() {
    pkg_has nft || { pkg_update; pkg_install nftables; }

    local conf="/etc/nftables.conf"
    print_status "Writing nftables ruleset to $conf"

    {
        echo "#!/usr/sbin/nft -f"
        echo "flush ruleset"
        echo "table inet filter {"
        echo "  chain input {"
        echo "    type filter hook input priority filter; policy drop;"
        echo "    iif lo accept"
        echo "    ct state established,related accept"
        echo "    ct state invalid drop"
        echo "    ip saddr $LOCAL_NETWORK accept comment \"LAN\""
        if [ -n "$ALLOWED_SSH_IPS" ]; then
            while IFS= read -r ip; do
                echo "    ip saddr $ip tcp dport $SSH_PORT accept comment \"SSH from $ip\""
            done < <(csv_to_array "$ALLOWED_SSH_IPS")
        else
            echo "    tcp dport $SSH_PORT ct state new limit rate 4/minute accept comment \"SSH rate-limited (v4+v6)\""
        fi
        [ "$ENABLE_VPN" = true ] && echo "    udp dport $VPN_PORT accept comment \"WireGuard\""
        echo "    icmp type echo-request limit rate 1/second accept"
        echo "    icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-advert, nd-router-solicit } accept"
        echo "    icmpv6 type echo-request limit rate 1/second accept"
        echo "  }"
        echo "  chain forward { type filter hook forward priority filter; policy drop; }"
        echo "  chain output  { type filter hook output  priority filter; policy accept; }"
        echo "}"
    } | write_to "$conf"

    run nft -f "$conf"
    svc_enable_now nftables 2>/dev/null || true
    if [ "$DRY_RUN" != true ] && pkg_has nft; then
        nft list ruleset | tee -a "$LOG_FILE" || true
    fi
}

setup_firewall() {
    print_section "FIREWALL ($FIREWALL)"
    case "$FIREWALL" in
        ufw)       setup_ufw ;;
        firewalld) setup_firewalld ;;
        nftables)  setup_nftables ;;
        *)         print_error "Unknown firewall backend: $FIREWALL" ;;
    esac
}

# --- SSH hardening ---------------------------------------------------------

ssh_has_authorized_keys() {
    # Look for any non-root user with authorized_keys present and non-empty.
    local found=0
    while IFS=: read -r _user _ uid _ _ home _shell; do
        [ "$uid" -ge 1000 ] || continue
        [ -d "$home" ] || continue
        [ -s "$home/.ssh/authorized_keys" ] && found=1 && break
    done < /etc/passwd
    [ -s /root/.ssh/authorized_keys ] && found=1
    return $((1 - found))
}

rotate_ssh_backups() {
    local cfg="/etc/ssh/sshd_config"
    # Enumerate backups via nullglob so the pipeline never sees a literal '*'.
    # The previous form (ls | tail) failed under pipefail on fresh systems
    # where no backup files existed yet, triggering the ERR trap inside the
    # process-substitution subshell.
    local -a all=()
    local _restore_nullglob=0
    shopt -q nullglob || _restore_nullglob=1
    shopt -s nullglob
    all=( "${cfg}".backup.* )
    [ "$_restore_nullglob" = 1 ] && shopt -u nullglob

    [ "${#all[@]}" -gt "$SSH_BACKUP_KEEP" ] || return 0

    # Sort by mtime (newest first) and delete everything beyond SSH_BACKUP_KEEP.
    local -a sorted=()
    mapfile -t sorted < <(ls -1t -- "${all[@]}")
    local i
    for ((i = SSH_BACKUP_KEEP; i < ${#sorted[@]}; i++)); do
        run rm -f -- "${sorted[$i]}"
    done
}

harden_ssh() {
    print_section "SSH HARDENING"

    local cfg="/etc/ssh/sshd_config"
    if [ ! -f "$cfg" ]; then
        if [ "$DRY_RUN" = true ]; then
            print_dry "harden $cfg (not present in this environment — install openssh-server first)"
            return 0
        fi
        print_error "$cfg not found (install openssh-server)"
    fi

    local backup
    backup="$cfg.backup.$(date +%Y%m%d_%H%M%S)"
    run cp "$cfg" "$backup"
    print_status "Backed up sshd_config to $backup"
    rotate_ssh_backups

    # Idempotent: only edit if value differs (avoids needless restarts).
    set_ssh_option() {
        local key="$1" val="$2" current
        current=$(grep -iE "^[[:space:]]*${key}[[:space:]]" "$cfg" | awk '{print $2}' | head -1 || true)
        if [ "$current" = "$val" ]; then return 0; fi
        if [ "$DRY_RUN" = true ]; then
            print_dry "set $key=$val (current: ${current:-unset})"
            return 0
        fi
        if grep -qE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]" "$cfg"; then
            sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]].*|${key} ${val}|" "$cfg"
        else
            printf '%s %s\n' "$key" "$val" >> "$cfg"
        fi
    }

    # Default to keeping PasswordAuthentication=yes UNLESS we can prove keys exist.
    local password_auth="yes"
    if ssh_has_authorized_keys; then
        password_auth="no"
        print_status "Authorized keys found — disabling password auth"
    else
        print_warning "No authorized_keys detected — leaving PasswordAuthentication=yes"
        print_warning "Add a key (ssh-copy-id), then re-run with --ssh to lock down."
    fi

    set_ssh_option PermitRootLogin             "no"
    set_ssh_option PasswordAuthentication      "$password_auth"
    set_ssh_option PubkeyAuthentication        "yes"
    set_ssh_option PermitEmptyPasswords        "no"
    set_ssh_option X11Forwarding               "no"
    set_ssh_option MaxAuthTries                "3"
    set_ssh_option ClientAliveInterval         "300"
    set_ssh_option ClientAliveCountMax         "2"
    set_ssh_option LoginGraceTime              "30"
    set_ssh_option LogLevel                    "VERBOSE"
    set_ssh_option ChallengeResponseAuthentication "no"
    set_ssh_option KerberosAuthentication      "no"
    set_ssh_option GSSAPIAuthentication        "no"
    set_ssh_option UsePAM                      "yes"

    if [ "$ENABLE_SSH_BANNER" = true ]; then
        cat <<'EOF' | write_to /etc/issue.net
########################################################################
#                       AUTHORIZED ACCESS ONLY                         #
#  Unauthorized access to this system is prohibited and will be        #
#  prosecuted. All connections are monitored and logged.               #
########################################################################
EOF
        set_ssh_option Banner /etc/issue.net
    fi

    if [ "$DRY_RUN" = true ]; then
        print_dry "validate sshd_config and restart $SSH_SERVICE"
        return 0
    fi

    # openssh's privsep chroot. Normally created by the sshd systemd unit's
    # RuntimeDirectory= directive on first start, but doesn't exist on a
    # freshly-installed openssh-server that's never run.
    run mkdir -p /run/sshd

    if sshd -t -f "$cfg"; then
        svc_restart "$SSH_SERVICE"
        print_ok "Restarted $SSH_SERVICE"
    else
        cp "$backup" "$cfg"
        print_warning "sshd_config validation failed; restored backup ($backup)"
        return 1
    fi

    print_warning "Test SSH login in a NEW session before closing this one."
}

restore_ssh() {
    print_section "RESTORE SSH CONFIG"
    local cfg="/etc/ssh/sshd_config"
    local latest
    latest=$(ls -1t "${cfg}".backup.* 2>/dev/null | head -1 || true)
    [ -n "$latest" ] || print_error "No backups found for $cfg"
    print_status "Restoring from $latest"
    run cp "$latest" "$cfg"
    if sshd -t -f "$cfg" 2>/dev/null; then
        svc_restart "$SSH_SERVICE"
        print_ok "Restored and restarted $SSH_SERVICE"
    else
        print_error "Restored config failed validation — manual review required"
    fi
}

# --- fail2ban --------------------------------------------------------------

setup_fail2ban() {
    print_section "FAIL2BAN"
    [ "$ENABLE_FAIL2BAN" = true ] || { print_status "fail2ban disabled"; return 0; }

    pkg_install "$(pkg_name_for fail2ban)" || { print_warning "fail2ban not available"; return 0; }

    local jail=/etc/fail2ban/jail.local
    local logpath
    if [ -n "$AUTH_LOG" ]; then
        logpath="$AUTH_LOG"
    else
        logpath="%(sshd_log)s"
    fi

    {
        cat <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = auto
destemail = $ADMIN_EMAIL
ignoreip = 127.0.0.1/8 ::1 $LOCAL_NETWORK

[sshd]
enabled  = true
port     = $SSH_PORT
logpath  = $logpath
EOF
    } | write_to "$jail"

    svc_enable_now fail2ban
    print_ok "fail2ban active (jail: sshd)"
}

# --- WireGuard VPN ---------------------------------------------------------

setup_wireguard_vpn() {
    print_section "WIREGUARD VPN"
    [ "$ENABLE_VPN" = true ] || { print_status "VPN disabled"; return 0; }

    # shellcheck disable=SC2046
    pkg_install $(pkg_name_for wireguard) $(pkg_name_for qrencode)

    local wgdir=/etc/wireguard
    run install -d -m 700 "$wgdir"

    umask 077
    if [ ! -f "$wgdir/server_private.key" ]; then
        run sh -c "wg genkey | tee $wgdir/server_private.key | wg pubkey > $wgdir/server_public.key"
    fi

    local srv_priv srv_pub srv_ip iface
    srv_priv=$(cat "$wgdir/server_private.key" 2>/dev/null || echo "<SERVER_PRIV_KEY>")
    srv_pub=$(cat "$wgdir/server_public.key" 2>/dev/null || echo "<SERVER_PUB_KEY>")
    srv_ip=$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || echo "SERVER_PUBLIC_IP")
    iface="${DEFAULT_IFACE:-eth0}"

    # Create initial server config if missing; preserve existing peers otherwise.
    if [ ! -f "$wgdir/wg0.conf" ]; then
        cat <<EOF | write_to "$wgdir/wg0.conf"
[Interface]
Address = 10.8.0.1/24
ListenPort = $VPN_PORT
PrivateKey = $srv_priv
PostUp   = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $iface -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $iface -j MASQUERADE
EOF
    fi

    echo "net.ipv4.ip_forward=1" | write_to /etc/sysctl.d/99-wireguard.conf
    run sysctl -p /etc/sysctl.d/99-wireguard.conf >/dev/null

    add_wg_client "${1:-client1}"

    svc_enable_now "wg-quick@wg0"
    print_ok "WireGuard up on $VPN_PORT/udp"
}

# add_wg_client NAME — generates a new peer keypair and appends to wg0.conf
add_wg_client() {
    local name="${1:-client$(date +%s)}"
    local wgdir=/etc/wireguard
    local clidir="$wgdir/clients"
    run install -d -m 700 "$clidir"

    [ -f "$wgdir/wg0.conf" ] || print_error "Run --vpn first (no server config)"

    # Pick next .2..254 address from /24
    local next=2
    while grep -q "10.8.0.${next}/32" "$wgdir/wg0.conf" 2>/dev/null; do
        next=$((next + 1))
    done
    [ "$next" -le 254 ] || print_error "Address pool exhausted"

    umask 077
    local priv pub srv_pub srv_ip
    priv=$(wg genkey 2>/dev/null || echo "<CLIENT_PRIV>")
    pub=$(echo "$priv" | wg pubkey 2>/dev/null || echo "<CLIENT_PUB>")
    srv_pub=$(cat "$wgdir/server_public.key" 2>/dev/null || echo "<SERVER_PUB>")
    srv_ip=$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || echo "SERVER_PUBLIC_IP")

    cat <<EOF | write_to "$clidir/${name}.conf"
[Interface]
Address = 10.8.0.${next}/24
PrivateKey = $priv
DNS = 1.1.1.1

[Peer]
PublicKey = $srv_pub
Endpoint = $srv_ip:$VPN_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

    cat <<EOF >> "$wgdir/wg0.conf"

# $name
[Peer]
PublicKey = $pub
AllowedIPs = 10.8.0.${next}/32
EOF

    print_ok "Added client '$name' as 10.8.0.${next}"
    if pkg_has qrencode && [ "$DRY_RUN" != true ]; then
        qrencode -t ansiutf8 < "$clidir/${name}.conf"
    fi
    print_status "Config: $clidir/${name}.conf"

    # Hot-reload if interface is up
    if [ "$DRY_RUN" != true ] && ip link show wg0 >/dev/null 2>&1; then
        wg syncconf wg0 <(wg-quick strip wg0) 2>/dev/null || svc_restart "wg-quick@wg0"
    fi
}

# --- Intrusion detection ---------------------------------------------------

setup_intrusion_detection() {
    print_section "INTRUSION DETECTION"
    [ "$ENABLE_INTRUSION_DETECTION" = true ] || { print_status "IDS disabled"; return 0; }

    local psad_pkg
    psad_pkg="$(pkg_name_for psad)"
    if [ -n "$psad_pkg" ]; then
        pkg_install "$psad_pkg"
        if [ -f /etc/psad/psad.conf ]; then
            run sed -i "s|^EMAIL_ADDRESSES.*|EMAIL_ADDRESSES     $ADMIN_EMAIL;|" /etc/psad/psad.conf
            run sed -i "s|^HOSTNAME.*|HOSTNAME               $(hostname);|" /etc/psad/psad.conf
            run sed -i 's|^ENABLE_AUTO_IDS .*|ENABLE_AUTO_IDS         Y;|' /etc/psad/psad.conf
            run sed -i 's|^ENABLE_AUTO_IDS_EMAILS.*|ENABLE_AUTO_IDS_EMAILS  Y;|' /etc/psad/psad.conf
            run psad --sig-update >/dev/null 2>&1 || true
            svc_enable_now psad || true
        fi
    else
        print_warning "psad not packaged for $PKG_FAMILY — skipping (fail2ban + firewall rate limits cover most of it)"
    fi

    pkg_install rkhunter || print_warning "rkhunter install failed"
    if pkg_has rkhunter && [ -n "$CRON_DAILY" ]; then
        run rkhunter --update --nocolors >/dev/null 2>&1 || true
        run rkhunter --propupd --nocolors >/dev/null 2>&1 || true
        run install -d "$CRON_DAILY"
        cat <<'EOF' | write_to "$CRON_DAILY/rkhunter-scan"
#!/bin/sh
command -v rkhunter >/dev/null 2>&1 || exit 0
rkhunter --cronjob --update --quiet
EOF
        run chmod +x "$CRON_DAILY/rkhunter-scan"
    fi
}

# --- Let's Encrypt ---------------------------------------------------------

setup_letsencrypt() {
    print_section "LET'S ENCRYPT"
    [ "$ENABLE_CERTIFICATES" = true ] || { print_status "Certs disabled"; return 0; }
    [ -n "$DOMAIN_NAME" ] || { print_warning "DOMAIN_NAME not set"; return 1; }

    pkg_install "$(pkg_name_for certbot)"
    run certbot certonly --standalone -d "$DOMAIN_NAME" \
        --non-interactive --agree-tos --email "$ADMIN_EMAIL"

    if [ "$INIT_SYSTEM" = systemd ]; then
        run sh -c 'systemctl enable --now certbot.timer 2>/dev/null \
            || systemctl enable --now certbot-renew.timer 2>/dev/null \
            || true'
    fi
}

# --- Security audit (extended) --------------------------------------------

pending_updates() {
    case "$PKG_FAMILY" in
        debian) apt-get -s upgrade 2>/dev/null | awk '/^Inst /' | wc -l ;;
        rhel)   { dnf check-update -q 2>/dev/null || yum check-update -q 2>/dev/null; } | grep -c '^[a-zA-Z0-9]' ;;
        arch)   checkupdates 2>/dev/null | wc -l ;;
        alpine) apk version 2>/dev/null | grep -c '<' ;;
        suse)   zypper -q list-updates 2>/dev/null | grep -c '^v ' ;;
    esac
}

run_security_audit() {
    print_section "SECURITY AUDIT"
    local report
    report="/var/log/security-audit-$(date +%Y%m%d_%H%M%S).txt"

    {
        echo "Security Audit Report - $(date)"
        echo "Host: $(hostname)  Distro: $DISTRO_ID  Family: $PKG_FAMILY  Kernel: $(uname -r)"
        echo "========================================"

        echo; echo "[Users with empty passwords]"
        awk -F: '($2 == "") {print $1}' /etc/shadow 2>/dev/null

        echo; echo "[Users with UID 0]"
        awk -F: '($3 == 0) {print $1}' /etc/passwd

        echo; echo "[Users with login shells]"
        awk -F: '$7 !~ /(nologin|false|sync|halt|shutdown)$/ && $3 >= 1000 {print $1" "$7}' /etc/passwd

        echo; echo "[Pending package updates]"
        echo "Count: $(pending_updates 2>/dev/null || echo unknown)"

        echo; echo "[Listening ports]"
        ss -tulpnH 2>/dev/null || ss -tulpn

        echo; echo "[SUID binaries outside standard paths]"
        find / -xdev -perm -4000 -type f \
            -not -path '/usr/bin/*' -not -path '/usr/sbin/*' \
            -not -path '/usr/lib/*' -not -path '/bin/*' -not -path '/sbin/*' \
            2>/dev/null | head -30

        echo; echo "[World-writable files in system dirs (top 20)]"
        find / -xdev -type f -perm -0002 \
            -not -path '/proc/*' -not -path '/sys/*' -not -path '/run/*' -not -path '/tmp/*' \
            2>/dev/null | head -20

        echo; echo "[Sensitive file modes]"
        for f in /etc/shadow /etc/gshadow /etc/passwd /etc/ssh/sshd_config; do
            [ -e "$f" ] && stat -c '%a %U:%G %n' "$f"
        done

        echo; echo "[Recent failed logins]"
        if [ -n "$AUTH_LOG" ]; then
            grep -i "failed password" "$AUTH_LOG" 2>/dev/null | tail -10
        elif command -v journalctl >/dev/null; then
            journalctl -u "$SSH_SERVICE" --no-pager 2>/dev/null | grep -i "failed password" | tail -10
        fi

        echo; echo "[Recent sudo usage]"
        if [ -n "$AUTH_LOG" ]; then
            grep "sudo:" "$AUTH_LOG" 2>/dev/null | tail -10
        elif command -v journalctl >/dev/null; then
            journalctl _COMM=sudo --no-pager 2>/dev/null | tail -10
        fi

        echo; echo "[Firewall state]"
        case "$FIREWALL" in
            ufw)       ufw status verbose 2>/dev/null ;;
            firewalld) firewall-cmd --list-all 2>/dev/null ;;
            nftables)  nft list ruleset 2>/dev/null | head -50 ;;
        esac
    } > "$report" 2>&1 || true   # audit is best-effort; missing tools must not abort the script

    print_ok "Audit report: $report"
    awk '/\[Users with empty passwords\]/,/\[Pending package updates\]/' "$report" 2>/dev/null || true
}

# --- Network monitoring ----------------------------------------------------

setup_network_monitoring() {
    print_section "NETWORK MONITORING"
    # shellcheck disable=SC2046
    pkg_install $(pkg_name_for netmon)
    if pkg_has vnstat; then
        svc_enable_now vnstat 2>/dev/null || true
        # vnstat ≥ 2.0 auto-creates per-interface databases via the daemon;
        # the `-u` flag was removed. Only run it on legacy 1.x.
        if vnstat --version 2>/dev/null | grep -qE '^vnStat 1\.'; then
            for i in $(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$'); do
                run vnstat -u -i "$i" >/dev/null 2>&1 || true
            done
        fi
    fi
}

# --- Sysctl hardening ------------------------------------------------------

setup_sysctl_hardening() {
    print_section "SYSCTL HARDENING"
    [ "$ENABLE_SYSCTL_HARDENING" = true ] || { print_status "Sysctl hardening disabled"; return 0; }

    cat <<'EOF' | write_to /etc/sysctl.d/99-security-hardening.conf
# Network — IPv4
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
# NOTE: ip_forward intentionally not set here; WireGuard's drop-in (99-wireguard.conf)
# enables it when needed and is loaded after this file.

# Network — IPv6
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Kernel
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
kernel.sysrq = 0
kernel.core_uses_pid = 1

# Filesystem
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
EOF

    run sysctl --system >/dev/null
    print_ok "Sysctl hardening applied"
}

# --- Automatic security updates -------------------------------------------

setup_auto_updates() {
    print_section "AUTOMATIC SECURITY UPDATES"
    [ "$ENABLE_AUTO_UPDATES" = true ] || { print_status "Auto-updates disabled"; return 0; }

    case "$PKG_FAMILY" in
        debian)
            pkg_install unattended-upgrades apt-listchanges
            cat <<'EOF' | write_to /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
            # Security-only by default (uncomment updates origin to widen scope).
            cat <<'EOF' | write_to /etc/apt/apt.conf.d/51auto-upgrades-security
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
            print_ok "unattended-upgrades configured (security only)"
            ;;
        rhel)
            pkg_install dnf-automatic
            run sed -i 's|^upgrade_type.*|upgrade_type = security|' /etc/dnf/automatic.conf
            run sed -i 's|^apply_updates.*|apply_updates = yes|'   /etc/dnf/automatic.conf
            svc_enable_now dnf-automatic.timer
            print_ok "dnf-automatic enabled (security only)"
            ;;
        suse)
            # zypper-automatic ships a systemd timer on modern openSUSE.
            if pkg_install zypper-automatic 2>/dev/null; then
                [ "$INIT_SYSTEM" = systemd ] && svc_enable_now zypper-automatic.timer 2>/dev/null || true
                print_ok "zypper-automatic enabled"
            else
                # Fallback: cron job that pulls patches but does not reboot.
                [ -n "$CRON_DAILY" ] && run install -d "$CRON_DAILY"
                [ -n "$CRON_DAILY" ] && cat <<'EOF' | write_to "$CRON_DAILY/security-updates"
#!/bin/sh
# Apply patches (security and recommended) without rebooting.
command -v zypper >/dev/null 2>&1 || exit 0
zypper --non-interactive patch --auto-agree-with-licenses --skip-interactive
EOF
                [ -n "$CRON_DAILY" ] && run chmod +x "$CRON_DAILY/security-updates"
                print_ok "openSUSE: cron-based zypper patch installed at $CRON_DAILY/security-updates"
            fi
            ;;
        arch)
            # Arch has no separate security channel — patches ship continuously.
            # Provide a download-and-stage cron that does NOT auto-install, so
            # the operator can review breakage before pulling the trigger.
            [ -n "$CRON_DAILY" ] || { print_warning "no daily cron dir; skipping"; return 0; }
            run install -d "$CRON_DAILY"
            cat <<'EOF' | write_to "$CRON_DAILY/security-updates"
#!/bin/sh
# Arch rolling-release: download pending packages so 'pacman -Syu' is fast,
# but DO NOT auto-install (Arch updates can require manual intervention,
# e.g. mirror changes, pacnew files). Review and apply manually.
command -v pacman >/dev/null 2>&1 || exit 0
pacman -Syuw --noconfirm >/var/log/pacman-prefetch.log 2>&1
EOF
            run chmod +x "$CRON_DAILY/security-updates"
            print_ok "Arch: daily package pre-fetch installed at $CRON_DAILY/security-updates"
            print_warning "Arch: review pending updates with 'pacman -Qu' and apply manually"
            ;;
        alpine)
            [ -n "$CRON_DAILY" ] || { print_warning "no daily cron dir; skipping"; return 0; }
            run install -d "$CRON_DAILY"
            cat <<'EOF' | write_to "$CRON_DAILY/security-updates"
#!/bin/sh
# Alpine: refresh index and apply available upgrades.
command -v apk >/dev/null 2>&1 || exit 0
apk update -q
apk upgrade --available --no-cache >/var/log/apk-upgrade.log 2>&1
EOF
            run chmod +x "$CRON_DAILY/security-updates"
            print_ok "Alpine: daily 'apk upgrade' installed at $CRON_DAILY/security-updates"
            ;;
    esac
}

# --- lynis weekly audit ---------------------------------------------------

setup_lynis() {
    print_section "LYNIS"
    [ "$ENABLE_LYNIS" = true ] || { print_status "lynis disabled"; return 0; }

    pkg_install lynis || { print_warning "lynis not available"; return 0; }
    [ -n "$CRON_WEEKLY" ] || { print_warning "no weekly cron dir on this system; lynis installed but not scheduled"; return 0; }
    run install -d "$CRON_WEEKLY"
    cat <<'EOF' | write_to "$CRON_WEEKLY/lynis-audit"
#!/bin/sh
command -v lynis >/dev/null 2>&1 || exit 0
lynis audit system --quiet --cronjob > /var/log/lynis-weekly.log 2>&1
EOF
    run chmod +x "$CRON_WEEKLY/lynis-audit"
    print_ok "lynis weekly cron installed at $CRON_WEEKLY/lynis-audit"
}

# --- chkrootkit weekly ----------------------------------------------------

setup_chkrootkit() {
    print_section "CHKROOTKIT"
    [ "$ENABLE_CHKROOTKIT" = true ] || { print_status "chkrootkit disabled"; return 0; }

    pkg_install chkrootkit || { print_warning "chkrootkit not available"; return 0; }
    [ -n "$CRON_WEEKLY" ] || { print_warning "no weekly cron dir on this system; chkrootkit installed but not scheduled"; return 0; }
    run install -d "$CRON_WEEKLY"
    cat <<'EOF' | write_to "$CRON_WEEKLY/chkrootkit-scan"
#!/bin/sh
command -v chkrootkit >/dev/null 2>&1 || exit 0
chkrootkit -q > /var/log/chkrootkit-weekly.log 2>&1
EOF
    run chmod +x "$CRON_WEEKLY/chkrootkit-scan"
    print_ok "chkrootkit weekly cron installed at $CRON_WEEKLY/chkrootkit-scan"
}

# --- MAC: AppArmor enforce / SELinux check --------------------------------

setup_mac() {
    print_section "MANDATORY ACCESS CONTROL"
    [ "$ENABLE_MAC" = true ] || { print_status "MAC disabled"; return 0; }

    case "$PKG_FAMILY" in
        debian|suse)
            pkg_install apparmor apparmor-utils
            svc_enable_now apparmor 2>/dev/null || true
            ;;
        arch)
            # On Arch the utils ship inside the main 'apparmor' package; there is
            # no separate apparmor-utils. Audit-base is optional.
            pkg_install apparmor
            svc_enable_now apparmor 2>/dev/null || true
            ;;
    esac
    case "$PKG_FAMILY" in
        debian|arch|suse)
            if command -v aa-status >/dev/null 2>&1; then
                aa-status --enabled >/dev/null 2>&1 \
                    && print_ok "AppArmor is enabled" \
                    || print_warning "AppArmor not active (kernel cmdline may need 'lsm=...,apparmor' or 'apparmor=1 security=apparmor')"
            fi
            ;;
        rhel)
            if command -v getenforce >/dev/null 2>&1; then
                local mode
                mode=$(getenforce)
                if [ "$mode" = "Enforcing" ]; then
                    print_ok "SELinux is Enforcing"
                else
                    print_warning "SELinux is '$mode'. Set 'SELINUX=enforcing' in /etc/selinux/config and reboot."
                fi
            else
                print_warning "SELinux not installed (unusual on $PKG_FAMILY)"
            fi
            ;;
        alpine)
            print_warning "Alpine: no AppArmor/SELinux by default. Consider 'grsecurity' if available."
            ;;
    esac
}

# --- logwatch -------------------------------------------------------------

setup_logwatch() {
    print_section "LOGWATCH"
    [ "$ENABLE_LOGWATCH" = true ] || { print_status "logwatch disabled"; return 0; }
    pkg_install logwatch || print_warning "logwatch not available for $PKG_FAMILY"
    print_status "logwatch daily reports installed (sends to root by default; configure /etc/logwatch/conf/logwatch.conf for email)"
}

# --- CrowdSec (opt-in) ----------------------------------------------------

setup_crowdsec() {
    print_section "CROWDSEC"
    [ "$ENABLE_CROWDSEC" = true ] || { print_status "CrowdSec disabled (opt-in)"; return 0; }

    case "$PKG_FAMILY" in
        debian)
            # Official packagecloud repo — script reviewed before piping.
            if ! pkg_has cscli; then
                run sh -c 'curl -fsSL https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash'
                pkg_install crowdsec
            fi
            # Bouncer matches firewall backend
            case "$FIREWALL" in
                nftables|ufw) pkg_install crowdsec-firewall-bouncer-nftables ;;
                firewalld)    pkg_install crowdsec-firewall-bouncer-iptables ;;
            esac
            svc_enable_now crowdsec
            svc_enable_now crowdsec-firewall-bouncer 2>/dev/null || true
            ;;
        rhel)
            if ! pkg_has cscli; then
                run sh -c 'curl -fsSL https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.rpm.sh | bash'
                pkg_install crowdsec crowdsec-firewall-bouncer-iptables
            fi
            svc_enable_now crowdsec
            svc_enable_now crowdsec-firewall-bouncer 2>/dev/null || true
            ;;
        *)
            print_warning "CrowdSec install on $PKG_FAMILY: see https://docs.crowdsec.net (skipping)"
            return 1
            ;;
    esac
    print_ok "CrowdSec + firewall bouncer active"
}

#=============================================================================
# PHYSICAL / WORKSTATION LAYER (2.2)
#=============================================================================
# Everything above defends the network edge. Everything below assumes the
# attacker is standing at the keyboard: plugging in a peripheral, attaching a
# cable, or opening the lid while you are at lunch.

# --- Physical-layer helpers ------------------------------------------------

# The human whose desktop session this is — used for group membership and for
# pointing at user-level config we deliberately do not clobber.
primary_user() {
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
        printf '%s\n' "$SUDO_USER"
        return 0
    fi
    awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ {print $1; exit}' /etc/passwd
}

cpu_vendor() {
    # vendor_id only exists on x86. Fall back to the ARM/RISC-V spellings and
    # finally to the device-tree compatible string, so callers get *something*
    # on every platform rather than an empty answer that looks like "unknown
    # x86".
    local v
    v="$(awk -F': *' '/^vendor_id/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)"
    [ -n "$v" ] && { printf '%s\n' "$v"; return 0; }
    v="$(awk -F': *' '/^(CPU implementer|Model name|model name)/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)"
    [ -n "$v" ] && { printf '%s\n' "$v"; return 0; }
    tr -d '\0' < /proc/device-tree/compatible 2>/dev/null | head -c 64 || echo unknown
}

# x86 | arm | riscv | ppc | mips | other — decides which kernel params even exist.
arch_family() {
    case "$(uname -m)" in
        x86_64|i?86|amd64) echo x86 ;;
        aarch64|arm64|arm*) echo arm ;;
        riscv*)            echo riscv ;;
        ppc*|powerpc*)     echo ppc ;;
        mips*)             echo mips ;;
        *)                 echo other ;;
    esac
}

# uefi | bios | devicetree | unknown — Secure Boot and efi= params are
# meaningless outside UEFI, and DMI is meaningless outside x86 firmware.
platform_firmware() {
    [ -d /sys/firmware/efi ]         && { echo uefi;        return 0; }
    [ -d /proc/device-tree ]         && { echo devicetree;  return 0; }
    [ -r /sys/class/dmi/id/bios_vendor ] && { echo bios;    return 0; }
    echo unknown
}

# Human-readable machine identity from whichever source this platform has.
machine_model() {
    local m
    if [ -r /sys/class/dmi/id/product_name ]; then
        m="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) $(cat /sys/class/dmi/id/product_version 2>/dev/null)"
        m="$(printf '%s' "$m" | sed 's/^ *//;s/ *$//')"
        [ -n "$m" ] && { printf '%s\n' "$m"; return 0; }
    fi
    if [ -r /proc/device-tree/model ]; then
        tr -d '\0' < /proc/device-tree/model 2>/dev/null; echo
        return 0
    fi
    echo "unknown"
}

# laptop | desktop | server | vm | unknown — the physical layer matters most on
# something portable; on a VM most of it is not applicable at all.
chassis_type() {
    if systemd-detect-virt -q 2>/dev/null; then echo vm; return 0; fi
    local t
    t="$(cat /sys/class/dmi/id/chassis_type 2>/dev/null)"
    case "$t" in
        8|9|10|11|14|30|31|32) echo laptop ;;
        3|4|5|6|7|13|15|16)    echo desktop ;;
        17|22|23|28)           echo server ;;
        *) [ -d /sys/class/power_supply/BAT0 ] && echo laptop || echo unknown ;;
    esac
}

# networkmanager | iwd | systemd-networkd | wpa_supplicant | connman | none
net_manager() {
    if [ "$INIT_SYSTEM" = systemd ]; then
        systemctl is-active --quiet NetworkManager 2>/dev/null && { echo networkmanager; return 0; }
        systemctl is-active --quiet iwd            2>/dev/null && { echo iwd;            return 0; }
        systemctl is-active --quiet systemd-networkd 2>/dev/null && { echo systemd-networkd; return 0; }
        systemctl is-active --quiet connman        2>/dev/null && { echo connman;        return 0; }
    fi
    # Not running (or no systemd) — fall back to what is installed/configured.
    pkg_has nmcli   && { echo networkmanager; return 0; }
    [ -d /etc/iwd ] || pkg_has iwctl && { echo iwd; return 0; }
    [ -d /etc/systemd/network ] && { echo systemd-networkd; return 0; }
    pkg_has wpa_supplicant && { echo wpa_supplicant; return 0; }
    pkg_has connmanctl && { echo connman; return 0; }
    echo none
}

# True when this machine actually has a wireless NIC.
has_wireless() {
    local d
    for d in /sys/class/net/*/wireless /sys/class/net/*/phy80211; do
        [ -e "$d" ] && return 0
    done
    return 1
}

# First available screen locker, or empty. Desktop-agnostic on purpose: the
# right answer differs per compositor and we must not assume one.
session_locker() {
    local l
    for l in hyprlock swaylock waylock gtklock i3lock xsecurelock slock \
             xscreensaver-command light-locker-command physlock vlock; do
        pkg_has "$l" && { printf '%s\n' "$l"; return 0; }
    done
    return 1
}

# True when this script is running over SSH. Environment variables alone are
# unreliable — sudo's env_reset strips SSH_CONNECTION — so fall back to walking
# the process ancestry looking for sshd.
session_is_remote() {
    [ -n "${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-}" ] && return 0
    local pid=$$ ppid comm depth=0
    while [ "${pid:-0}" -gt 1 ] && [ "$depth" -lt 20 ]; do
        comm="$(cat "/proc/$pid/comm" 2>/dev/null)" || break
        case "$comm" in sshd*) return 0 ;; esac
        ppid="$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null)" || break
        [ -z "$ppid" ] && break
        pid="$ppid"; depth=$((depth + 1))
    done
    return 1
}

# Restarting the network stack drops every connection on the machine, which
# over SSH means disconnecting the very session running this script — the same
# lock-out the SSH module goes to lengths to avoid. Refuse when remote.
restart_net_stack() {
    local svc="$1"
    if session_is_remote; then
        print_warning "Remote session detected — NOT restarting $svc, it would disconnect you."
        print_warning "Apply from the console later with: systemctl restart $svc"
        return 0
    fi
    print_warning "Restarting $svc — network connections will drop for a few seconds"
    svc_restart "$svc" 2>/dev/null || true
}

# True when MOD exists for the running kernel (or is already loaded). Used to
# avoid writing blacklist entries for modules this platform never had.
module_exists() {
    lsmod 2>/dev/null | awk -v m="${1//-/_}" '$1==m {found=1} END{exit !found}' && return 0
    modinfo "$1" >/dev/null 2>&1
}

# enabled | disabled | unsupported | unknown
secure_boot_state() {
    if command -v mokutil >/dev/null 2>&1; then
        case "$(mokutil --sb-state 2>/dev/null)" in
            *enabled*)  echo enabled;  return 0 ;;
            *disabled*) echo disabled; return 0 ;;
        esac
    fi
    if command -v bootctl >/dev/null 2>&1; then
        case "$(bootctl status 2>/dev/null | grep -i 'secure boot')" in
            *enabled*)  echo enabled;  return 0 ;;
            *disabled*) echo disabled; return 0 ;;
        esac
    fi
    # EFI variable fallback: last byte of SecureBoot-<vendor-guid> is 1 when on.
    local var
    var="$(ls /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | head -1)"
    if [ -n "$var" ]; then
        case "$(od -An -t u1 "$var" 2>/dev/null | awk '{print $NF}')" in
            1) echo enabled;  return 0 ;;
            0) echo disabled; return 0 ;;
        esac
    fi
    [ -d /sys/firmware/efi ] || { echo unsupported; return 0; }
    echo unknown
}

# True when a USB device currently exposes a HID (class 03) interface — i.e. a
# keyboard or mouse that a default-deny policy would cut off. Laptop keyboards
# on i8042/PS-2 and I2C touchpads are NOT on the USB bus and do not match.
usb_hid_present() {
    local f
    for f in /sys/bus/usb/devices/*/bInterfaceClass; do
        [ -r "$f" ] || continue
        [ "$(cat "$f" 2>/dev/null)" = "03" ] && return 0
    done
    return 1
}

# limine | grub | uki | systemd-boot | refind | extlinux | unknown
# Ordered most-specific first: a machine can have both /etc/default/grub left
# over from a previous bootloader and a live systemd-boot ESP.
detect_bootloader() {
    if   [ -f /etc/default/limine ];  then echo limine
    elif [ -f /etc/default/grub ];    then echo grub
    elif [ -f /etc/kernel/cmdline ];  then echo uki
    elif [ -d /boot/loader/entries ] || [ -d /efi/loader/entries ]; then echo systemd-boot
    elif [ -f /boot/EFI/refind/refind.conf ] || [ -f /boot/refind_linux.conf ]; then echo refind
    elif [ -f /boot/extlinux/extlinux.conf ] || [ -f /boot/syslinux/syslinux.conf ] \
      || [ -f /boot/extlinux.conf ]; then echo extlinux
    else echo unknown
    fi
}

backup_file() {  # backup_file PATH -> stdout backup path
    local src="$1" dst
    dst="${src}.bak.$(date +%Y%m%d_%H%M%S)"
    [ -f "$src" ] || return 0
    run cp -a "$src" "$dst"
    printf '%s\n' "$dst"
}

# --- USBGuard: default-deny USB -------------------------------------------

usbguard_write_daemon_conf() {
    cat <<'EOF' | write_to /etc/usbguard/usbguard-daemon.conf
# Managed by linux-security-setup. Default-deny USB.
RuleFile=/etc/usbguard/rules.conf
RuleFolder=/etc/usbguard/rules.d/

# Anything without a matching rule is blocked. This is the whole point.
ImplicitPolicyTarget=block

# Devices already attached when the daemon starts are evaluated against the
# policy rather than blanket-authorised, so a device planted while the daemon
# was stopped does not get grandfathered in.
PresentDevicePolicy=apply-policy
PresentControllerPolicy=keep
InsertedDevicePolicy=apply-policy

# Do not reset controller authorisation state on shutdown: on a stop/restart
# that would briefly re-authorise everything.
RestoreControllerDeviceState=false

DeviceManagerBackend=uevent

# Rules are matched by device identity, not by which port it was plugged into,
# so an approved device keeps working in any port.
DeviceRulesWithPort=false

IPCAllowedUsers=root
IPCAllowedGroups=usbguard
IPCAccessControlFiles=/etc/usbguard/IPCAccessControl.d/

AuditFilePath=/var/log/usbguard/usbguard-audit.log
EOF
    run chmod 600 /etc/usbguard/usbguard-daemon.conf
}

# Regenerate rules.conf from what is attached right now. Shared by
# setup_usbguard and the standalone --usbguard-snapshot re-baseline.
usbguard_snapshot() {
    pkg_has usbguard || { print_warning "usbguard not installed — run --usbguard first"; return 1; }

    local tmp
    tmp="$(mktemp)"
    # -P: no port pinning. Older builds lack the flag; fall back to bare form.
    if ! usbguard generate-policy -P >"$tmp" 2>/dev/null; then
        usbguard generate-policy >"$tmp" 2>/dev/null || true
    fi

    # A policy that failed to enumerate is an empty file. Installing that with
    # ImplicitPolicyTarget=block bricks every USB port including the root hubs,
    # so refuse rather than "succeed".
    if ! grep -q '^allow' "$tmp"; then
        rm -f "$tmp"
        print_warning "generate-policy produced no allow rules — refusing to install an empty default-deny policy"
        return 1
    fi

    if [ "$USBGUARD_ALLOW_HID" = true ]; then
        cat >>"$tmp" <<'EOF'

# Keep any keyboard/mouse usable. This is a deliberate weakening: BadUSB
# impersonates precisely this class. Drop it (USBGUARD_ALLOW_HID=false) once
# you have confirmed your keyboard is not on the USB bus.
allow with-interface equals { 03:*:* }
EOF
    fi

    if [ "$USBGUARD_BLOCK_STORAGE" = true ]; then
        cat >>"$tmp" <<'EOF'

# Reject mass storage outright, ahead of any allow rule above.
reject with-interface one-of { 08:*:* }
EOF
    fi

    run mkdir -p /etc/usbguard/rules.d /var/log/usbguard
    if [ "$DRY_RUN" = true ]; then
        print_dry "install $(grep -c . "$tmp") policy lines to /etc/usbguard/rules.conf"
        sed 's/^/    | /' "$tmp" >&2
    else
        install -m 600 -o root -g root "$tmp" /etc/usbguard/rules.conf
    fi
    rm -f "$tmp"

    print_ok "USB policy written: $(grep -c '^allow' /etc/usbguard/rules.conf 2>/dev/null || echo 0) device(s) allowed"
}

setup_usbguard() {
    print_section "USBGUARD (DEFAULT-DENY USB)"
    [ "$ENABLE_USBGUARD" = true ] || { print_status "USBGuard disabled (ENABLE_USBGUARD=false)"; return 0; }

    case "$PKG_FAMILY" in
        alpine) print_warning "usbguard is not packaged for Alpine — skipping"; return 1 ;;
    esac

    pkg_has usbguard || pkg_install usbguard
    pkg_has usbguard || { print_warning "usbguard install failed — skipping"; return 1; }

    # Lock-out prevention, mirroring the SSH module's philosophy: never cut the
    # channel you are currently using.
    if usb_hid_present && [ "$USBGUARD_ALLOW_HID" != true ]; then
        print_warning "A USB keyboard/mouse is attached and USBGUARD_ALLOW_HID=false."
        print_warning "It is captured in the snapshot below, but a *different* USB keyboard"
        print_warning "(rescue, replacement) would be blocked. Keep a PS/2 or built-in keyboard reachable."
    fi

    usbguard_snapshot || { print_warning "Snapshot failed — daemon NOT enabled, USB left untouched"; return 1; }
    usbguard_write_daemon_conf

    # Let the desktop user run `usbguard list-devices` / `allow-device` without
    # sudo, otherwise approving a new stick means a root shell every time.
    local u; u="$(primary_user)"
    if [ -n "$u" ]; then
        getent group usbguard >/dev/null 2>&1 || run groupadd -r usbguard
        run gpasswd -a "$u" usbguard >/dev/null 2>&1 || true
        print_status "User '$u' added to group 'usbguard' (re-login to take effect)"
    fi

    svc_enable_now usbguard
    print_ok "USBGuard active — unknown USB devices are blocked"
    print_status "Approve a new device: usbguard list-devices; usbguard allow-device <id>"
    print_status "Make it permanent:   usbguard allow-device <id> -p"
    print_status "Re-baseline all:     $SCRIPT_NAME --usbguard-snapshot"
}

# --- Bluetooth off ---------------------------------------------------------

setup_bluetooth_policy() {
    print_section "BLUETOOTH DISABLE"
    [ "$ENABLE_BLUETOOTH_OFF" = true ] || { print_status "Bluetooth policy disabled"; return 0; }

    # Service name is bluetooth(.service) on systemd distros and openrc alike,
    # but the init verbs differ; anything else gets told what to do by hand.
    case "$INIT_SYSTEM" in
        systemd)
            run systemctl disable --now bluetooth.service 2>/dev/null || true
            run systemctl mask bluetooth.service          2>/dev/null || true
            ;;
        openrc)
            run rc-service bluetooth stop        2>/dev/null || true
            run rc-update del bluetooth default  2>/dev/null || true
            ;;
        *)
            print_warning "init=$INIT_SYSTEM — stop the bluetooth daemon yourself; the blacklist below still applies"
            ;;
    esac

    # rfkill alone does not survive a reboot on every distro; the modprobe
    # blacklist is what actually keeps the radio from coming back.
    pkg_has rfkill && run rfkill block bluetooth 2>/dev/null || true

    # Enumerate this kernel's Bluetooth transport drivers instead of hardcoding
    # a vendor list. btrtl/btintel/btbcm/btmtk are Realtek/Intel/Broadcom/
    # MediaTek specific — naming them assumes your radio. Reading the module
    # directory covers whatever silicon this machine actually has, and keeps
    # working on kernels that add new ones.
    local moddir vendor_mods=""
    moddir="/lib/modules/$(uname -r)/kernel/drivers/bluetooth"
    if [ -d "$moddir" ]; then
        vendor_mods="$(find "$moddir" -name '*.ko*' -printf '%f\n' 2>/dev/null \
                       | sed 's/\.ko.*$//' | sort -u)"
    fi

    {
        cat <<'EOF'
# Managed by linux-security-setup.
# Core stack first: blacklisting only a transport (btusb) still leaves the
# stack loadable through any other transport this kernel supports.
blacklist bluetooth
blacklist bnep
blacklist rfcomm
blacklist hidp
install bluetooth /bin/true
EOF
        if [ -n "$vendor_mods" ]; then
            echo "# Transport drivers found for kernel $(uname -r):"
            printf 'blacklist %s\n' $vendor_mods
        else
            # No module dir (monolithic kernel, or modules stripped). Cover the
            # near-universal USB transport so a plugged-in dongle stays dead.
            echo "# No module directory found — covering the generic USB transport only."
            echo "blacklist btusb"
        fi
        echo "install btusb /bin/true"
    } | write_to /etc/modprobe.d/99-bluetooth-disable.conf

    if [ -z "$(ls -A /sys/class/bluetooth 2>/dev/null)" ]; then
        print_status "No Bluetooth controller present — blacklist still written so a future dongle stays dead"
    fi

    print_ok "Bluetooth stopped, masked and blacklisted$([ -n "$vendor_mods" ] && echo " ($(printf '%s\n' $vendor_mods | wc -l) transport drivers)")"
    print_status "Reverse with: rm /etc/modprobe.d/99-bluetooth-disable.conf${INIT_SYSTEM:+ && systemctl unmask bluetooth}"
}

# --- Wi-Fi privacy / MAC randomisation ------------------------------------

setup_wifi_privacy() {
    print_section "WI-FI PRIVACY"
    [ "$ENABLE_WIFI_PRIVACY" = true ] || { print_status "Wi-Fi privacy disabled"; return 0; }

    if ! has_wireless; then
        print_status "No wireless interface on this machine — configuring wired MAC policy only"
    fi

    local nm; nm="$(net_manager)"
    print_status "Network stack: $nm"

    case "$nm" in
        networkmanager)
            run mkdir -p /etc/NetworkManager/conf.d
            cat <<'EOF' | write_to /etc/NetworkManager/conf.d/99-mac-randomization.conf
# Managed by linux-security-setup.
[device-mac-randomization]
# Randomise the MAC used while scanning, so you are not broadcasting a stable
# identifier to every AP in range before you ever associate.
wifi.scan-rand-mac-address=yes

[connection-mac-randomization]
# "stable" derives a per-SSID MAC that stays constant for that network: you
# stay unlinkable across networks without breaking captive portals, DHCP
# reservations or MAC-based access control on networks you actually use.
# Use "random" instead for a fresh MAC on every association.
wifi.cloned-mac-address=stable
ethernet.cloned-mac-address=stable

[connection]
# Rotate the stable-id per boot so a single network cannot track you long-term.
connection.stable-id=${CONNECTION}/${BOOT}
EOF
            restart_net_stack NetworkManager
            print_ok "NetworkManager MAC randomisation configured (scan: random, per-connection: stable)"
            ;;

        iwd)
            run mkdir -p /etc/iwd
            # iwd has no drop-in directory, so this is the whole main.conf.
            # Written only when absent to avoid clobbering existing settings.
            if [ -f /etc/iwd/main.conf ] && grep -q AddressRandomization /etc/iwd/main.conf 2>/dev/null; then
                print_status "/etc/iwd/main.conf already sets AddressRandomization — leaving it alone"
            else
                cat <<'EOF' | write_to /etc/iwd/main.conf
# Managed by linux-security-setup.
[General]
# Per-network MAC, equivalent to NetworkManager's "stable" policy.
AddressRandomization=network
AddressRandomizationRange=full

[Scan]
# Randomise the address used for probe requests while scanning.
DisablePeriodicScan=false
EOF
            fi
            restart_net_stack iwd
            print_ok "iwd MAC randomisation configured (per-network)"
            ;;

        systemd-networkd)
            run mkdir -p /etc/systemd/network
            cat <<'EOF' | write_to /etc/systemd/network/99-mac-randomization.link
# Managed by linux-security-setup.
[Match]
Type=wlan

[Link]
# "random" gives a fresh MAC each time the link comes up. systemd-networkd
# has no per-SSID equivalent of NetworkManager's "stable", so this is the
# closest available policy.
MACAddressPolicy=random
EOF
            print_ok "systemd-networkd .link written (wlan: random MAC on link-up)"
            print_warning "Takes effect on next boot or: udevadm trigger --action=add --subsystem-match=net"
            ;;

        wpa_supplicant)
            local wc=/etc/wpa_supplicant/wpa_supplicant.conf
            [ -f "$wc" ] || wc=/etc/wpa_supplicant.conf
            print_warning "wpa_supplicant has no drop-in config. Add to $wc by hand:"
            print_warning "  mac_addr=1            # per-ESS random MAC when associating"
            print_warning "  preassoc_mac_addr=1   # random MAC while scanning"
            return 1
            ;;

        connman)
            print_warning "ConnMan does not implement MAC randomisation. Switch to iwd or"
            print_warning "NetworkManager, or randomise via a networkd .link / udev rule."
            return 1
            ;;

        *)
            print_warning "No recognised network stack — set MAC randomisation in whatever manages your links"
            return 1
            ;;
    esac

    local iface="${DEFAULT_IFACE:-}"
    if [ -z "$iface" ]; then
        local n
        for n in /sys/class/net/*; do
            [ -e "$n" ] || continue
            [ "$(basename "$n")" = lo ] && continue
            iface="$(basename "$n")"; break
        done
    fi
    print_status "Verify: ip link show ${iface:-<iface>}"
}

# --- Module blacklist: DMA-capable buses and unused protocols --------------

setup_module_blacklist() {
    print_section "KERNEL MODULE BLACKLIST"
    [ "$ENABLE_MODULE_BLACKLIST" = true ] || { print_status "Module blacklist disabled"; return 0; }

    # Filesystems are only safe to blacklist if nothing is using them. Root on
    # gfs2, or /boot on hfsplus (Apple hardware), would become unbootable.
    local fs_candidates="cramfs freevxfs jffs2 hfs hfsplus gfs2 ksmbd"
    local fs_block="" fs_skip="" fs
    for fs in $fs_candidates; do
        if findmnt -rno FSTYPE 2>/dev/null | grep -qx "$fs" \
        || grep -qw "$fs" /etc/fstab 2>/dev/null; then
            fs_skip="$fs_skip $fs"
        else
            fs_block="$fs_block $fs"
        fi
    done
    [ -n "$fs_skip" ] && print_warning "In use — NOT blacklisting:$fs_skip"

    # Thunderbolt is the one entry that can cost you real functionality: it is
    # also the dock, the external GPU and often the charger. Blacklisting it on
    # a machine that has a controller is a decision, not a default.
    local tb_present=false
    [ -d /sys/bus/thunderbolt ] && [ -n "$(ls -A /sys/bus/thunderbolt/devices 2>/dev/null)" ] && tb_present=true

    {
        cat <<'EOF'
# Managed by linux-security-setup.

# --- Buses with direct memory access ------------------------------------
# FireWire lets an attached device read and write RAM without the CPU's
# involvement, which is how classic DMA key-extraction works. Effectively no
# modern machine needs it, so it is blacklisted unconditionally.
blacklist firewire-core
blacklist firewire-ohci
blacklist firewire-sbp2
blacklist ohci1394
blacklist sbp2
install firewire-core /bin/true
EOF

        if [ "$tb_present" = true ] && [ "${BLACKLIST_THUNDERBOLT:-false}" != true ]; then
            cat <<'EOF'

# Thunderbolt controller detected and left ENABLED: blacklisting it here would
# also kill docks, external displays and (on many laptops) charging. Set
# BLACKLIST_THUNDERBOLT=true to refuse the driver anyway; otherwise rely on the
# controller's own security level (see --physical-audit).
EOF
        else
            cat <<'EOF'

# No Thunderbolt controller in use — refuse the driver so a future device
# cannot bring up a DMA-capable link.
blacklist thunderbolt
install thunderbolt /bin/true
EOF
        fi

        cat <<'EOF'

# --- Rarely-used network protocols --------------------------------------
# Each is reachable attack surface in the kernel that almost no machine uses.
# Architecture-independent: these are protocol implementations, not drivers.
blacklist dccp
blacklist sctp
blacklist rds
blacklist tipc
blacklist n-hdlc
blacklist ax25
blacklist netrom
blacklist x25
blacklist rose
blacklist decnet
blacklist econet
blacklist af_802154
blacklist ipx
blacklist appletalk
blacklist psnap
blacklist p8023
blacklist p8022
blacklist can
blacklist atm
EOF

        if [ -n "$fs_block" ]; then
            cat <<'EOF'

# --- Rarely-used filesystems --------------------------------------------
# A malicious USB stick formatted with an obscure fs gets parsed by kernel code
# that sees very little scrutiny. squashfs and udf are deliberately NOT listed:
# AppImage/snap need squashfs, optical media needs udf. Anything currently
# mounted or named in fstab has been excluded automatically.
EOF
            printf 'blacklist %s\n' $fs_block
        fi
    } | write_to /etc/modprobe.d/99-hardening-blacklist.conf

    if [ "$tb_present" = true ]; then
        local tbsec
        tbsec="$(cat /sys/bus/thunderbolt/devices/domain0/security 2>/dev/null || echo unknown)"
        print_warning "Thunderbolt controller present (security level: $tbsec)."
        print_warning "Levels 'none'/'dponly' allow DMA from any attached device — set 'secure' or 'user' in firmware."
    fi

    if [ "$USBGUARD_BLOCK_STORAGE" = true ]; then
        cat <<'EOF' | write_to /etc/modprobe.d/99-usb-storage-disable.conf
# Managed by linux-security-setup. USBGUARD_BLOCK_STORAGE=true.
blacklist usb-storage
install usb-storage /bin/true
EOF
        print_ok "usb-storage blacklisted (no USB mass storage at all)"
    fi

    print_ok "Module blacklist written"
    print_warning "Modules already loaded stay loaded until reboot. Check with: lsmod | grep -E 'firewire|thunderbolt'"
}

# --- Kernel cmdline hardening (bootloader-aware) --------------------------

setup_kernel_cmdline() {
    print_section "KERNEL CMDLINE HARDENING"
    [ "$ENABLE_KERNEL_CMDLINE" = true ] || { print_status "Kernel cmdline hardening disabled (ENABLE_KERNEL_CMDLINE=false)"; return 0; }

    local params="" arch fw
    arch="$(arch_family)"
    fw="$(platform_firmware)"
    print_status "Arch: $arch ($(uname -m))  Firmware: $fw"

    # --- Architecture-independent hardening --------------------------------
    # These are core-kernel options present on every architecture Linux runs
    # on. init_on_alloc/init_on_free zero memory on both ends, which kills most
    # use-after-free info leaks at a small performance cost.
    params+=" slab_nomerge init_on_alloc=1 init_on_free=1 page_alloc.shuffle=1"
    params+=" randomize_kstack_offset=on debugfs=off"

    # --- IOMMU: the actual mitigation for DMA attacks ----------------------
    # Makes the memory controller enforce which RAM a device may touch. The
    # option names are per-architecture; passing intel_iommu=on to an ARM
    # kernel is silently ignored at best and confusing at worst.
    case "$arch" in
        x86)
            case "$(cpu_vendor)" in
                GenuineIntel) params+=" intel_iommu=on" ;;
                AuthenticAMD) params+=" amd_iommu=on" ;;
                # Unknown/virtualised x86: pass both, the irrelevant one is ignored.
                *)            params+=" intel_iommu=on amd_iommu=on" ;;
            esac
            params+=" iommu.passthrough=0 iommu.strict=1"
            # x86-only: the legacy vsyscall page is a fixed-address ROP target.
            params+=" vsyscall=none"
            ;;
        arm|riscv)
            # SMMU/IOMMU is described by firmware and enabled by default where
            # present; only the generic knobs apply.
            params+=" iommu.passthrough=0 iommu.strict=1"
            ;;
        *)
            print_status "No IOMMU parameters known for arch '$arch' — skipping"
            ;;
    esac

    # Shuts the PCI DMA window before the kernel's own IOMMU setup runs,
    # closing the pre-boot gap. UEFI-only by construction.
    if [ "$fw" = uefi ]; then
        params+=" efi=disable_early_pci_dma"
    else
        print_status "Firmware is '$fw', not UEFI — skipping efi=disable_early_pci_dma"
    fi

    if [ "$LOCKDOWN_MODE" != none ]; then
        # lockdown=integrity severs the paths a root user would use to write to
        # the running kernel — and hibernation is one of them, because the
        # resume image is unverified kernel memory.
        if grep -qE '(^| )resume=' /proc/cmdline 2>/dev/null; then
            print_warning "Current cmdline has resume= (hibernation in use)."
            print_warning "lockdown=$LOCKDOWN_MODE disables suspend-to-disk. Skipping lockdown."
            print_warning "To take it anyway: remove resume=/resume_offset= first, then re-run."
        else
            params+=" lockdown=$LOCKDOWN_MODE"
        fi
    fi

    # Enforcing module signatures without Secure Boot is theatre — the
    # bootloader and kernel are themselves unverified.
    case "$(secure_boot_state)" in
        enabled) params+=" module.sig_enforce=1" ;;
        unsupported) print_status "Non-UEFI platform — Secure Boot and module.sig_enforce not applicable" ;;
        *)       print_status "Secure Boot not enabled — skipping module.sig_enforce=1" ;;
    esac

    [ -n "$KERNEL_CMDLINE_EXTRA" ] && params+=" $KERNEL_CMDLINE_EXTRA"
    params="${params# }"

    local loader; loader="$(detect_bootloader)"
    print_status "Bootloader: $loader"
    print_status "Params: $params"

    case "$loader" in
        limine)
            local cfg=/etc/default/limine
            if grep -qF 'linux-security-setup' "$cfg" 2>/dev/null; then
                print_status "limine already carries a managed cmdline line — leaving it alone"
            else
                print_status "Backup: $(backup_file "$cfg")"
                if [ "$DRY_RUN" = true ]; then
                    print_dry "append to $cfg: KERNEL_CMDLINE[default]+=\" $params\""
                else
                    {
                        echo ""
                        echo "# linux-security-setup: physical/DMA hardening"
                        echo "KERNEL_CMDLINE[default]+=\" $params\""
                    } >> "$cfg"
                fi
            fi
            local regen=""
            for c in limine-update limine-mkinitcpio limine-entry-tool; do
                pkg_has "$c" && { regen="$c"; break; }
            done
            if [ -n "$regen" ]; then
                run "$regen"
                print_ok "Bootloader entries regenerated with $regen"
            else
                print_warning "No limine regeneration tool found — run your limine update hook manually"
            fi
            ;;
        grub)
            local cfg=/etc/default/grub
            if grep -qF "$params" "$cfg" 2>/dev/null; then
                print_status "grub cmdline already contains these params"
            else
                print_status "Backup: $(backup_file "$cfg")"
                if [ "$DRY_RUN" = true ]; then
                    print_dry "append \"$params\" to GRUB_CMDLINE_LINUX_DEFAULT in $cfg"
                else
                    if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$cfg"; then
                        sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\1 $params\"|" "$cfg"
                    else
                        echo "GRUB_CMDLINE_LINUX_DEFAULT=\"$params\"" >> "$cfg"
                    fi
                fi
            fi
            local out=/boot/grub/grub.cfg
            [ -d /boot/grub2 ] && out=/boot/grub2/grub.cfg
            if   pkg_has grub-mkconfig;  then run grub-mkconfig  -o "$out"
            elif pkg_has grub2-mkconfig; then run grub2-mkconfig -o "$out"
            else print_warning "No grub-mkconfig — regenerate $out manually"
            fi
            print_ok "GRUB updated"
            ;;
        uki)
            local cfg=/etc/kernel/cmdline
            print_status "Backup: $(backup_file "$cfg")"
            if [ "$DRY_RUN" = true ]; then
                print_dry "append \"$params\" to $cfg"
            else
                printf '%s' " $params" >> "$cfg"
            fi
            if   pkg_has mkinitcpio;      then run mkinitcpio -P
            elif pkg_has dracut;          then run dracut --force --regenerate-all
            elif pkg_has kernel-install;  then print_warning "Re-run kernel-install for each installed kernel"
            fi
            print_ok "UKI cmdline updated"
            ;;
        systemd-boot)
            # Entries are per-kernel files with an options= line; there is no
            # single source of truth to edit safely, and many distros
            # regenerate them. Tell the user exactly what to add and where.
            print_warning "systemd-boot with per-entry files and no /etc/kernel/cmdline."
            print_warning "Append to the options= line of each entry in /boot/loader/entries/:"
            print_warning "  $params"
            print_status  "If your distro generates entries (kernel-install), put the params in"
            print_status  "/etc/kernel/cmdline instead and re-run this command."
            return 1
            ;;
        refind)
            print_warning "rEFInd manages its own cmdline. Add to 'options' in"
            print_warning "/boot/EFI/refind/refind.conf (or your refind_linux.conf):"
            print_warning "  $params"
            return 1
            ;;
        extlinux)
            local cfg
            for cfg in /boot/extlinux/extlinux.conf /boot/syslinux/syslinux.conf \
                       /boot/extlinux.conf; do
                [ -f "$cfg" ] && break
            done
            print_warning "syslinux/extlinux detected. Append to the APPEND line in $cfg:"
            print_warning "  $params"
            print_status  "(Not edited automatically: APPEND lines are per-label and distro-specific.)"
            return 1
            ;;
        *)
            print_warning "Unrecognised bootloader — add these params by hand:"
            print_warning "  $params"
            print_status  "Current cmdline for reference: $(cat /proc/cmdline)"
            return 1
            ;;
    esac

    print_warning "REBOOT REQUIRED. If the machine fails to boot, edit the entry at the"
    print_warning "boot menu and drop the added params, then restore the .bak file."
    print_status  "After reboot verify: ls /sys/class/iommu/ && cat /sys/kernel/security/lockdown"
}

# --- Unattended access / evil-maid posture --------------------------------

setup_idle_lock() {
    print_section "IDLE LOCK / UNATTENDED ACCESS"
    [ "$ENABLE_IDLE_LOCK" = true ] || { print_status "Idle lock disabled"; return 0; }

    if [ "$INIT_SYSTEM" = systemd ]; then
        run mkdir -p /etc/systemd/logind.conf.d
        cat <<EOF | write_to /etc/systemd/logind.conf.d/99-physical-security.conf
# Managed by linux-security-setup.
[Login]
IdleAction=lock
IdleActionSec=${IDLE_LOCK_SECS}
HandleLidSwitch=suspend
HandleLidSwitchExternalPower=suspend
HandleLidSwitchDocked=ignore
EOF
        # Stops anyone at the console from rebooting the box into a rescue
        # target with three keys.
        run systemctl mask ctrl-alt-del.target 2>/dev/null || true

        # NEVER restart systemd-logind. It tears down every session it manages,
        # so the display manager loses its seat and relaunches the greeter —
        # the user's whole desktop dies mid-run. From the seat that is
        # indistinguishable from the machine rebooting. Reload re-reads the
        # drop-in without touching a single session.
        if [ "$(systemctl show systemd-logind -p CanReload --value 2>/dev/null)" = yes ]; then
            run systemctl reload systemd-logind 2>/dev/null \
                || print_warning "logind reload failed — settings apply at next boot"
        else
            print_warning "This systemd's logind cannot reload — settings apply at next boot."
            print_warning "Deliberately NOT restarting it: that would kill your desktop session."
        fi
        print_ok "logind: idle lock after ${IDLE_LOCK_SECS}s, lid closes to suspend, Ctrl-Alt-Del masked"
    else
        # No logind: seat/idle policy lives in the display manager or the
        # compositor instead, and Ctrl-Alt-Del is an inittab entry.
        print_warning "init=$INIT_SYSTEM has no logind — idle/lid policy must come from your session"
        if [ -f /etc/inittab ] && grep -q '^ca:' /etc/inittab 2>/dev/null; then
            print_status "Disable Ctrl-Alt-Del: comment out the 'ca::ctrlaltdel:' line in /etc/inittab"
        fi
    fi

    # Text consoles are not covered by the graphical locker at all.
    # Covers VTs, serial consoles on every arch (ttyS x86, ttyAMA ARM, ttySIF
    # RISC-V), USB serial adapters and hypervisor consoles. SSH sessions are
    # deliberately excluded — that is sshd's ClientAlive* job, handled by
    # harden_ssh, and a readonly TMOUT there breaks long-running remote work.
    cat <<EOF | write_to /etc/profile.d/99-console-timeout.sh
# Managed by linux-security-setup. Logs out idle local console shells.
case "\$(tty 2>/dev/null)" in
    /dev/tty[0-9]*|/dev/ttyS*|/dev/ttyAMA*|/dev/ttySIF*|/dev/ttymxc*|/dev/ttyUSB*|/dev/hvc*|/dev/console)
        TMOUT=${CONSOLE_TIMEOUT_SECS}
        readonly TMOUT
        export TMOUT
        ;;
esac
EOF
    run chmod 644 /etc/profile.d/99-console-timeout.sh

    cat <<'EOF' | write_to /etc/sysctl.d/99-physical-hardening.conf
# Managed by linux-security-setup.
# SysRq is a console-local backdoor: it can dump memory, kill the locker, or
# remount filesystems regardless of who is logged in.
kernel.sysrq = 0
# Hide kernel pointers and the ring buffer from unprivileged local users.
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
# Only a process's own children may be ptraced, so a compromised app cannot
# read secrets out of your browser or agent.
kernel.yama.ptrace_scope = 2
EOF
    run sysctl --system >/dev/null 2>&1 || true

    # The locker is per-compositor and lives in the user's own config, which
    # distro tooling (Omarchy, GNOME, KDE, …) often owns and regenerates.
    # Detect and report rather than overwrite: clobbering it breaks upgrades
    # and can leave the machine with no working locker at all.
    local u locker; u="$(primary_user)"
    if locker="$(session_locker)"; then
        print_status "Screen locker found: $locker (user '$u')"
        case "$locker" in
            hyprlock)    print_status "  Confirm hypridle is running and locks before suspend (~/.config/hypr/hypridle.conf)" ;;
            swaylock)    print_status "  Confirm swayidle is running with a 'before-sleep swaylock' clause" ;;
            waylock|gtklock) print_status "  Confirm your idle daemon invokes $locker before suspend" ;;
            i3lock|xsecurelock|slock) print_status "  Confirm xss-lock or xautolock invokes $locker before suspend" ;;
            xscreensaver-command) print_status "  Confirm the xscreensaver daemon autostarts for '$u'" ;;
            physlock|vlock) print_status "  Console-only locker — a graphical session still needs its own" ;;
        esac
    else
        print_warning "No screen locker found. IdleAction=lock has nothing to call —"
        print_warning "install one for your session (hyprlock/swaylock/i3lock/xsecurelock/...)"
    fi
    [ "$(chassis_type)" = vm ] && print_status "Running in a VM — lid/idle policy is largely moot here"

    print_ok "Unattended-access controls applied"
}

# --- Physical attack-surface audit ----------------------------------------

run_physical_audit() {
    print_section "PHYSICAL SECURITY AUDIT"
    local report
    report="/var/log/physical-audit-$(date +%Y%m%d_%H%M%S).txt"

    {
        echo "Physical Security Audit - $(date)"
        echo "Host: $(hostname)  Kernel: $(uname -r)  Arch: $(uname -m) ($(arch_family))"
        echo "Machine: $(machine_model)"
        echo "Chassis: $(chassis_type)   Firmware type: $(platform_firmware)"
        if [ -r /sys/class/dmi/id/bios_version ]; then
            echo "Firmware: $(cat /sys/class/dmi/id/bios_version 2>/dev/null) ($(cat /sys/class/dmi/id/bios_date 2>/dev/null))"
        fi
        echo "Distro: ${DISTRO_ID:-unknown} (family=${PKG_FAMILY:-unknown}, init=${INIT_SYSTEM:-unknown})"
        echo "========================================"

        echo; echo "[Boot chain]"
        echo "Bootloader: $(detect_bootloader)"
        echo "Secure Boot: $(secure_boot_state)"
        if [ -e /dev/tpm0 ] || [ -e /dev/tpmrm0 ]; then
            echo "TPM: present ($(echo /dev/tpm* | tr ' ' '\n' | tr '\n' ' '))"
            echo "TPM major version: $(cat /sys/class/tpm/tpm0/tpm_version_major 2>/dev/null || echo unknown)"
        else
            echo "TPM: ABSENT — no hardware root of trust for measured boot"
        fi
        echo "Kernel cmdline: $(cat /proc/cmdline)"

        echo; echo "[DMA protection]"
        if [ -n "$(ls -A /sys/class/iommu/ 2>/dev/null)" ]; then
            echo "IOMMU: ACTIVE ($(ls /sys/class/iommu/ 2>/dev/null | tr '\n' ' '))"
        else
            case "$(arch_family)" in
                x86)  echo "IOMMU: INACTIVE — no DMA remapping. Add intel_iommu=on / amd_iommu=on." ;;
                arm|riscv) echo "IOMMU/SMMU: INACTIVE — check that firmware describes an SMMU and it is enabled." ;;
                *)    echo "IOMMU: INACTIVE (no known parameter for $(arch_family))" ;;
            esac
        fi
        echo "Kernel lockdown: $(cat /sys/kernel/security/lockdown 2>/dev/null || echo 'not compiled in')"
        echo "FireWire: $(lsmod 2>/dev/null | grep -cE '^(firewire|ohci1394)' || true) module(s) loaded; \
bus $([ -d /sys/bus/firewire ] && echo present || echo absent)"
        if [ -d /sys/bus/thunderbolt ]; then
            echo "Thunderbolt: $(ls /sys/bus/thunderbolt/devices 2>/dev/null | wc -l) device node(s)"
            for dom in /sys/bus/thunderbolt/devices/domain*; do
                [ -e "$dom/security" ] || continue
                echo "  $(basename "$dom") security level: $(cat "$dom/security" 2>/dev/null)"
            done
        else
            echo "Thunderbolt: no controller (nothing to secure)"
        fi

        echo; echo "[Disk encryption]"
        if lsblk -o NAME,FSTYPE 2>/dev/null | grep -qi crypto_LUKS; then
            lsblk -o NAME,FSTYPE,SIZE,MOUNTPOINT 2>/dev/null | grep -iE 'crypto_LUKS|crypt'
            for d in $(lsblk -rno NAME,FSTYPE 2>/dev/null | awk '$2=="crypto_LUKS"{print $1}'); do
                echo "-- /dev/$d --"
                cryptsetup luksDump "/dev/$d" 2>/dev/null | grep -iE 'version|cipher|hash|PBKDF|Memory|Iterations' | head -12
            done
        else
            echo "LUKS: NONE FOUND — an attacker with the drive reads everything."
        fi
        echo "Swap: $(swapon --show=NAME,TYPE --noheadings 2>/dev/null | tr '\n' ' ' || echo none)"

        echo; echo "[USB]"
        if pkg_has usbguard; then
            echo "USBGuard: installed, service $(systemctl is-active usbguard 2>/dev/null || echo n/a)"
            echo "Policy rules: $(grep -c '^allow' /etc/usbguard/rules.conf 2>/dev/null || echo 0) allow"
            usbguard list-devices 2>/dev/null | head -20
        else
            echo "USBGuard: NOT INSTALLED — any USB device is trusted on insert."
        fi
        echo "-- attached --"
        if pkg_has lsusb; then
            lsusb 2>/dev/null
        else
            # usbutils is not installed everywhere; sysfs always is.
            for d in /sys/bus/usb/devices/*/idVendor; do
                [ -r "$d" ] || continue
                b="$(dirname "$d")"
                echo "$(cat "$b/idVendor"):$(cat "$b/idProduct" 2>/dev/null) $(cat "$b/manufacturer" 2>/dev/null) $(cat "$b/product" 2>/dev/null)"
            done
        fi
        echo "-- USB HID on the bus (would be cut by default-deny) --"
        if usb_hid_present; then
            echo "YES — a USB keyboard/mouse is attached; keep USBGUARD_ALLOW_HID=true"
        else
            echo "NO — input is off-USB (i8042/I2C/serial); USBGUARD_ALLOW_HID=false is safe"
        fi

        echo; echo "[Radios]"
        if pkg_has rfkill; then
            rfkill list 2>/dev/null
        elif [ -d /sys/class/rfkill ]; then
            for r in /sys/class/rfkill/rfkill*; do
                [ -r "$r/name" ] || continue
                echo "$(cat "$r/name"): type=$(cat "$r/type" 2>/dev/null) soft=$(cat "$r/soft" 2>/dev/null) hard=$(cat "$r/hard" 2>/dev/null)"
            done
        else
            echo "No rfkill interface"
        fi
        echo "Bluetooth controllers: $(ls /sys/class/bluetooth 2>/dev/null | wc -l)"
        if [ "$INIT_SYSTEM" = systemd ]; then
            echo "bluetooth.service: $(systemctl is-enabled bluetooth 2>/dev/null || echo n/a) / $(systemctl is-active bluetooth 2>/dev/null || echo n/a)"
        fi
        echo "Wireless interfaces: $(has_wireless && echo present || echo none)"

        echo; echo "[Network stack / MAC privacy]"
        echo "Manager: $(net_manager)"
        case "$(net_manager)" in
            networkmanager)   grep -rh 'mac-address\|stable-id' /etc/NetworkManager/conf.d/ 2>/dev/null || echo "No MAC randomisation drop-in found" ;;
            iwd)              grep -h 'AddressRandomization' /etc/iwd/main.conf 2>/dev/null || echo "No AddressRandomization in /etc/iwd/main.conf" ;;
            systemd-networkd) grep -rh 'MACAddressPolicy' /etc/systemd/network/ 2>/dev/null || echo "No MACAddressPolicy in /etc/systemd/network/" ;;
            wpa_supplicant)   grep -rh 'mac_addr' /etc/wpa_supplicant* 2>/dev/null || echo "No mac_addr= in wpa_supplicant config" ;;
            *)                echo "No recognised manager — MAC policy unknown" ;;
        esac

        echo; echo "[Unattended access]"
        if [ "$INIT_SYSTEM" = systemd ]; then
            echo "logind IdleAction: $(grep -rh '^IdleAction' /etc/systemd/logind.conf.d/ /etc/systemd/logind.conf 2>/dev/null | tail -1 || echo 'default (ignore)')"
            echo "ctrl-alt-del.target: $(systemctl is-enabled ctrl-alt-del.target 2>/dev/null || echo masked/absent)"
        else
            echo "init=$INIT_SYSTEM — no logind; idle policy comes from the session/DM"
            [ -f /etc/inittab ] && echo "inittab ctrlaltdel: $(grep '^ca:' /etc/inittab 2>/dev/null || echo 'not set')"
        fi
        echo "Screen locker: $(session_locker || echo 'NONE INSTALLED')"
        echo "kernel.sysrq: $(sysctl -n kernel.sysrq 2>/dev/null || echo unknown)"
        echo "ptrace_scope: $(sysctl -n kernel.yama.ptrace_scope 2>/dev/null || echo 'yama absent')"
        echo "-- autologin config (each one is a bypass of the login prompt) --"
        grep -rl 'autologin\|AutomaticLogin' \
            /etc/systemd/system/getty*.service.d/ /etc/gdm* /etc/sddm.conf* \
            /etc/lightdm/ /etc/greetd/ /etc/inittab 2>/dev/null || echo "none found"

        echo; echo "[Firmware / setup passwords]"
        case "$(platform_firmware)" in
            uefi|bios)
                echo "Not readable from the OS by design. Verify in firmware setup at boot:"
                echo "  - Supervisor/admin password set?  (blocks firmware setting changes)"
                echo "  - Power-on password set?          (blocks booting the machine)"
                echo "  - Drive/HDD password set?         (binds the drive to this machine)"
                echo "  - Boot order locked, USB/network boot disabled?"
                echo "  - Secure Boot enabled?            (currently: $(secure_boot_state))"
                ;;
            devicetree)
                echo "Device-tree platform (SBC/embedded). There is usually no firmware setup"
                echo "menu; the equivalent controls are secure-boot fuses and a locked"
                echo "U-Boot environment. Verify per your board's documentation."
                ;;
            *)
                echo "Firmware type unknown — cannot advise on setup passwords"
                ;;
        esac
    } > "$report" 2>&1 || true   # audit is best-effort; a missing tool must not abort

    # Only claim a report exists if one actually landed — a failed redirect
    # (no /var/log write access) must not be reported as success.
    if [ -s "$report" ]; then
        chmod 600 "$report" 2>/dev/null || true
        print_ok "Physical audit report: $report"
    else
        print_warning "Could not write $report — showing findings inline only"
    fi

    # Surface the findings that actually change what you should do next.
    print_status "--- headline findings ---"
    [ "$(secure_boot_state)" != enabled ] && print_warning "Secure Boot is $(secure_boot_state)"
    [ -z "$(ls -A /sys/class/iommu/ 2>/dev/null)" ] && print_warning "IOMMU inactive — no DMA protection"
    grep -q 'none' /sys/kernel/security/lockdown 2>/dev/null && print_warning "Kernel lockdown: none"
    pkg_has usbguard || print_warning "USBGuard not installed — USB is trust-on-insert"
    lsblk -o FSTYPE 2>/dev/null | grep -qi crypto_LUKS || print_warning "No LUKS volume detected"
}

# --- Workstation preset ----------------------------------------------------

setup_workstation() {
    print_section "WORKSTATION / PHYSICAL HARDENING"
    print_status "Enabling the physical layer. Bootloader edits stay opt-in (--kernel-cmdline)."

    ENABLE_USBGUARD=true
    ENABLE_BLUETOOTH_OFF=true
    ENABLE_WIFI_PRIVACY=true
    ENABLE_MODULE_BLACKLIST=true
    ENABLE_IDLE_LOCK=true

    setup_usbguard         || print_warning "USBGuard step incomplete — continuing"
    setup_bluetooth_policy || print_warning "Bluetooth step incomplete — continuing"
    setup_wifi_privacy     || print_warning "Wi-Fi privacy step incomplete — continuing"
    setup_module_blacklist || print_warning "Module blacklist incomplete — continuing"
    setup_idle_lock        || print_warning "Idle lock step incomplete — continuing"

    # Deliberately last and deliberately separate: this is the only step that
    # can stop the machine from booting.
    if [ "$ENABLE_KERNEL_CMDLINE" = true ]; then
        setup_kernel_cmdline || print_warning "Kernel cmdline step incomplete"
    else
        print_status "Kernel cmdline untouched. Review, then: $SCRIPT_NAME --kernel-cmdline"
    fi

    run_physical_audit
}

# --- Disable unused services ----------------------------------------------

disable_unused_services() {
    print_section "DISABLE UNUSED SERVICES"
    [ -n "$DISABLE_SERVICES" ] || { print_status "DISABLE_SERVICES empty — nothing to disable"; return 0; }

    while IFS= read -r svc; do
        case "$INIT_SYSTEM" in
            systemd)
                if systemctl list-unit-files "$svc"* 2>/dev/null | grep -q "$svc"; then
                    run systemctl disable --now "$svc" 2>/dev/null || true
                    run systemctl mask "$svc" 2>/dev/null || true
                    print_ok "Disabled+masked: $svc"
                else
                    print_status "Skip $svc (no such unit)"
                fi
                ;;
            openrc)
                rc-service "$svc" stop 2>/dev/null || true
                rc-update del "$svc" default 2>/dev/null || true
                print_ok "Disabled: $svc"
                ;;
        esac
    done < <(csv_to_array "$DISABLE_SERVICES")
}

# --- Top-level orchestration -----------------------------------------------

install_all() {
    print_section "INSTALL ALL"
    setup_sysctl_hardening
    setup_firewall
    harden_ssh || print_warning "SSH hardening did not complete — continuing with remaining steps"
    setup_fail2ban
    setup_crowdsec
    setup_intrusion_detection
    setup_lynis
    setup_chkrootkit
    setup_mac
    setup_auto_updates
    setup_logwatch
    setup_network_monitoring
    disable_unused_services
    [ "$ENABLE_VPN" = true ]          && setup_wireguard_vpn
    [ "$ENABLE_CERTIFICATES" = true ] && setup_letsencrypt

    # The 2.2 physical modules run only when explicitly enabled. --install-all
    # is used on servers you are SSH'd into, where default-deny USB and
    # bootloader edits are at best pointless and at worst a trip to the DC.
    if [ "$ENABLE_USBGUARD" = true ] || [ "$ENABLE_BLUETOOTH_OFF" = true ] \
    || [ "$ENABLE_WIFI_PRIVACY" = true ] || [ "$ENABLE_MODULE_BLACKLIST" = true ] \
    || [ "$ENABLE_IDLE_LOCK" = true ]; then
        setup_usbguard         || print_warning "USBGuard step incomplete — continuing"
        setup_bluetooth_policy || print_warning "Bluetooth step incomplete — continuing"
        setup_wifi_privacy     || print_warning "Wi-Fi privacy step incomplete — continuing"
        setup_module_blacklist || print_warning "Module blacklist incomplete — continuing"
        setup_idle_lock        || print_warning "Idle lock step incomplete — continuing"
    else
        print_status "Physical layer skipped. On a laptop run: $SCRIPT_NAME --workstation"
    fi
    [ "$ENABLE_KERNEL_CMDLINE" = true ] && { setup_kernel_cmdline || print_warning "Kernel cmdline step incomplete"; }

    run_security_audit
    print_ok "All requested components configured"
}

main_menu() {
    clear
    cat <<EOF
==========================================
Linux Security Setup ($DISTRO_ID / $PKG_FAMILY)
Firewall: $FIREWALL${DRY_RUN:+ (DRY-RUN)}
==========================================

 1) Configure firewall ($FIREWALL)
 2) Harden SSH (+ banner)
 3) Restore SSH from backup
 4) Setup fail2ban
 5) Setup CrowdSec + bouncer
 6) Sysctl hardening
 7) Automatic security updates
 8) lynis weekly audit
 9) chkrootkit weekly scan
10) AppArmor / SELinux check
11) Disable unused services (\$DISABLE_SERVICES)
12) Setup logwatch
13) Setup WireGuard VPN
14) Add WireGuard client
15) Setup intrusion detection (psad/rkhunter)
16) Setup Let's Encrypt
17) Run security audit
18) Setup network monitoring
19) Install ALL (network layer)
20) Show firewall status
--- physical / workstation (2.2) ---
21) Workstation preset (USBGuard + BT off + MAC rand + blacklist + idle lock)
22) USBGuard default-deny USB
23) Re-baseline USBGuard from attached devices
24) Disable Bluetooth (mask + blacklist)
25) Wi-Fi MAC randomization
26) Kernel module blacklist (FireWire/Thunderbolt/rare protocols)
27) Kernel cmdline hardening (IOMMU/lockdown) -- EDITS BOOTLOADER
28) Idle lock / unattended-access controls
29) Physical security audit
 0) Exit
EOF
    read -rp "Select option: " choice
    case "$choice" in
        1)  setup_firewall ;;
        2)  harden_ssh ;;
        3)  restore_ssh ;;
        4)  setup_fail2ban ;;
        5)  ENABLE_CROWDSEC=true setup_crowdsec ;;
        6)  setup_sysctl_hardening ;;
        7)  setup_auto_updates ;;
        8)  setup_lynis ;;
        9)  setup_chkrootkit ;;
        10) setup_mac ;;
        11) disable_unused_services ;;
        12) ENABLE_LOGWATCH=true setup_logwatch ;;
        13) setup_wireguard_vpn ;;
        14) read -rp "Client name: " n; add_wg_client "${n:-client$(date +%s)}" ;;
        15) setup_intrusion_detection ;;
        16) setup_letsencrypt ;;
        17) run_security_audit ;;
        18) setup_network_monitoring ;;
        19) install_all ;;
        20) case "$FIREWALL" in
              ufw)       pkg_has ufw          && ufw status verbose      || print_warning "ufw not installed" ;;
              firewalld) pkg_has firewall-cmd && firewall-cmd --list-all || print_warning "firewalld not installed" ;;
              nftables)  pkg_has nft          && nft list ruleset        || print_warning "nft not installed" ;;
            esac ;;
        # As in the CLI dispatch: a declined module must not trip the ERR trap
        # and drop the user out of the menu.
        21) setup_workstation                                   || print_warning "Finished with warnings" ;;
        22) ENABLE_USBGUARD=true        setup_usbguard          || print_warning "USBGuard not configured" ;;
        23) usbguard_snapshot                                   || print_warning "USB policy not re-baselined" ;;
        24) ENABLE_BLUETOOTH_OFF=true   setup_bluetooth_policy  || print_warning "Bluetooth not fully disabled" ;;
        25) ENABLE_WIFI_PRIVACY=true    setup_wifi_privacy      || print_warning "Wi-Fi privacy not configured" ;;
        26) ENABLE_MODULE_BLACKLIST=true setup_module_blacklist || print_warning "Module blacklist not written" ;;
        27) ENABLE_KERNEL_CMDLINE=true  setup_kernel_cmdline    || print_warning "Kernel cmdline unchanged" ;;
        28) ENABLE_IDLE_LOCK=true       setup_idle_lock         || print_warning "Idle lock not configured" ;;
        29) run_physical_audit                                  || print_warning "Audit finished with warnings" ;;
        0) exit 0 ;;
        *) print_warning "Invalid option" ;;
    esac
    echo; read -rp "Press Enter to continue..." _
    main_menu
}

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS] [COMMAND]

Commands:
  --install-all              Run the full hardening sequence + audit
  --firewall                 Configure firewall only
  --ssh                      Harden SSH only (banner + key-aware lockdown)
  --restore-ssh              Restore sshd_config from most recent backup
  --fail2ban                 Install/configure fail2ban
  --crowdsec                 Install CrowdSec + firewall bouncer (opt-in)
  --sysctl                   Apply kernel/network sysctl hardening
  --auto-updates             Configure automatic security updates
  --lynis                    Install lynis + weekly cron audit
  --chkrootkit               Install chkrootkit + weekly cron scan
  --mac                      Enforce AppArmor / verify SELinux
  --disable-services         Disable+mask units listed in DISABLE_SERVICES
  --logwatch                 Install logwatch daily reports
  --vpn                      Setup WireGuard server (ENABLE_VPN=true implied)
  --add-wg-client NAME       Add a new WireGuard peer named NAME
  --audit                    Run security audit
  --help, -h                 This message

Physical / workstation layer (2.2) — for machines an attacker can touch:
  --workstation              Preset: USBGuard + Bluetooth off + MAC randomization
                             + module blacklist + idle lock, then physical audit.
                             Does NOT touch the bootloader.
  --usbguard                 Default-deny USB, seeded from attached devices
  --usbguard-snapshot        Re-baseline the USB policy from what is attached now
  --bluetooth-off            Stop, mask and blacklist the Bluetooth stack
  --wifi-privacy             MAC randomization via whichever network stack is
                             in use (NetworkManager / iwd / systemd-networkd)
  --module-blacklist         Blacklist FireWire/Thunderbolt + rare protocols/fs
                             (skips anything this machine is actually using)
  --kernel-cmdline           IOMMU, efi=disable_early_pci_dma, allocator
                             hardening, optional lockdown. EDITS THE BOOTLOADER
                             and requires a reboot — run --dry-run first.
  --idle-lock                logind idle/lid lock, Ctrl-Alt-Del mask, tty TMOUT
  --physical-audit           Report Secure Boot, TPM, LUKS, IOMMU, lockdown,
                             USB policy, radios and unattended-access posture

Flags (can combine with any command):
  --dry-run                  Print actions without executing them

Environment overrides:
  SSH_PORT, ALLOWED_SSH_IPS, LOCAL_NETWORK, ADMIN_EMAIL
  ENABLE_VPN, VPN_PORT
  ENABLE_INTRUSION_DETECTION, ENABLE_FAIL2BAN, ENABLE_CROWDSEC
  ENABLE_SYSCTL_HARDENING, ENABLE_AUTO_UPDATES
  ENABLE_LYNIS, ENABLE_CHKROOTKIT, ENABLE_MAC
  ENABLE_SSH_BANNER, ENABLE_LOGWATCH
  ENABLE_CERTIFICATES, DOMAIN_NAME
  FIREWALL_BACKEND (auto|ufw|firewalld|nftables)
  DISABLE_SERVICES (CSV: bluetooth,exim4,NetworkManager,...)
  SSH_BACKUP_KEEP (default 5)
  CONFIG_FILE (default /etc/linux-security-setup.conf)

  Physical layer (all default false):
  ENABLE_USBGUARD, ENABLE_BLUETOOTH_OFF, ENABLE_WIFI_PRIVACY
  ENABLE_MODULE_BLACKLIST, ENABLE_KERNEL_CMDLINE, ENABLE_IDLE_LOCK
  USBGUARD_ALLOW_HID (default true — set false only if your keyboard is
                      NOT on the USB bus; --physical-audit tells you)
  USBGUARD_BLOCK_STORAGE (default false — reject all USB mass storage)
  BLACKLIST_THUNDERBOLT (default false — only honoured when a controller
                      exists; without one the driver is refused anyway)
  LOCKDOWN_MODE (none|integrity|confidentiality; integrity breaks hibernation)
  KERNEL_CMDLINE_EXTRA, IDLE_LOCK_SECS (300), CONSOLE_TIMEOUT_SECS (600)

Examples:
  sudo $SCRIPT_NAME --install-all
  sudo ALLOWED_SSH_IPS=10.0.0.5 $SCRIPT_NAME --firewall
  sudo $SCRIPT_NAME --dry-run --install-all
  sudo $SCRIPT_NAME --add-wg-client phone

  # Laptop: see the current physical posture before changing anything
  sudo $SCRIPT_NAME --physical-audit

  # Laptop: preview, then apply the physical layer
  sudo $SCRIPT_NAME --dry-run --workstation
  sudo $SCRIPT_NAME --workstation

  # USB lockdown on a laptop whose keyboard is i8042/PS-2, not USB
  sudo USBGUARD_ALLOW_HID=false $SCRIPT_NAME --usbguard

  # Bootloader edit — always preview first, and keep the .bak it prints
  sudo $SCRIPT_NAME --dry-run --kernel-cmdline
EOF
}

# --- Entry point -----------------------------------------------------------

# Parse flags first (allow --dry-run anywhere)
ARGS=()
for a in "$@"; do
    case "$a" in
        --dry-run) DRY_RUN=true ;;
        *)         ARGS+=("$a") ;;
    esac
done
set -- "${ARGS[@]:-}"

# --help shouldn't require root
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage; exit 0
fi

check_root
# Best-effort: tolerate weird container states (e.g. /var/lock as dangling symlink).
mkdir -p "$(dirname "$LOG_FILE")"  2>/dev/null || true
mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
acquire_lock
detect_distro
select_firewall

[ "$DRY_RUN" = true ] && print_warning "DRY-RUN: state-changing commands will be printed, not executed"

case "${1:-}" in
    --install-all)      install_all ;;
    --firewall)         setup_firewall ;;
    --ssh)              harden_ssh ;;
    --restore-ssh)      restore_ssh ;;
    --fail2ban)         setup_fail2ban ;;
    --crowdsec)         ENABLE_CROWDSEC=true setup_crowdsec ;;
    --sysctl)           setup_sysctl_hardening ;;
    --auto-updates)     setup_auto_updates ;;
    --lynis)            setup_lynis ;;
    --chkrootkit)       setup_chkrootkit ;;
    --mac)              setup_mac ;;
    --disable-services) disable_unused_services ;;
    --logwatch)         ENABLE_LOGWATCH=true setup_logwatch ;;
    --vpn)              ENABLE_VPN=true; setup_wireguard_vpn ;;
    --add-wg-client)    add_wg_client "${2:-}" ;;
    --audit)            run_security_audit ;;
    # The physical modules return non-zero when they decline to act (package
    # missing, unknown bootloader, empty USB policy). That is a refusal, not a
    # crash — swallow it here so the ERR trap does not turn a safe bail-out
    # into a red [ERROR] and a non-zero exit.
    --workstation)      setup_workstation       || print_warning "Workstation preset finished with warnings" ;;
    --usbguard)         ENABLE_USBGUARD=true;         setup_usbguard         || print_warning "USBGuard not configured" ;;
    --usbguard-snapshot) usbguard_snapshot            || print_warning "USB policy not re-baselined" ;;
    --bluetooth-off)    ENABLE_BLUETOOTH_OFF=true;    setup_bluetooth_policy || print_warning "Bluetooth not fully disabled" ;;
    --wifi-privacy)     ENABLE_WIFI_PRIVACY=true;     setup_wifi_privacy     || print_warning "Wi-Fi privacy not configured" ;;
    --module-blacklist) ENABLE_MODULE_BLACKLIST=true; setup_module_blacklist || print_warning "Module blacklist not written" ;;
    --kernel-cmdline)   ENABLE_KERNEL_CMDLINE=true;   setup_kernel_cmdline   || print_warning "Kernel cmdline unchanged" ;;
    --idle-lock)        ENABLE_IDLE_LOCK=true;        setup_idle_lock        || print_warning "Idle lock not configured" ;;
    --physical-audit)   run_physical_audit      || print_warning "Physical audit finished with warnings" ;;
    --help|-h)          usage ;;
    "")                 main_menu ;;
    *)                  usage; exit 2 ;;
esac
