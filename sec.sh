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
# Version: 2.1
#
# Improvements over 2.0:
#   - Concurrency-safe (flock)
#   - SSH lock-out prevention (allow SSH before any reset)
#   - sshd_config validated; refuses to disable PasswordAuth without a key
#   - --dry-run preview, --restore-ssh rollback, --add-wg-client peering
#   - fail2ban wired in (cross-distro), backup rotation, ANSI-stripped log
#   - Extended audit: SUID binaries, pending updates, weak file modes
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
19) Install ALL
20) Show firewall status
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

Examples:
  sudo $SCRIPT_NAME --install-all
  sudo ALLOWED_SSH_IPS=10.0.0.5 $SCRIPT_NAME --firewall
  sudo $SCRIPT_NAME --dry-run --install-all
  sudo $SCRIPT_NAME --add-wg-client phone
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
    --help|-h)          usage ;;
    "")                 main_menu ;;
    *)                  usage; exit 2 ;;
esac
