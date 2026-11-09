#!/bin/bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export TUNNEL_METRICS="127.0.0.1:0"

RESET=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
CYAN=$'\033[36m'
WHITE=$'\033[37m'
BRIGHT_BLUE=$'\033[94m'
BRIGHT_CYAN=$'\033[96m'
BRIGHT_WHITE=$'\033[97m'
BRIGHT_GREEN=$'\033[92m'
BRIGHT_RED=$'\033[91m'
BRIGHT_YELLOW=$'\033[93m'
BRIGHT_MAGENTA=$'\033[95m'

APP_VERSION="3.1"
LOG_DIR="${HOME}/.zappy-mods"
LOG_FILE="${LOG_DIR}/installer.log"
VPS_DIR="${LOG_DIR}/vps"
VPS_ENV="${VPS_DIR}/.vps_env"
CF_PID_FILE="${LOG_DIR}/cloudflared.pid"
CF_LOG_FILE="${LOG_DIR}/cloudflared.log"
CF_TOKEN_FILE="${LOG_DIR}/cloudflared-token"

mkdir -p "$LOG_DIR" "$VPS_DIR"
touch "$LOG_FILE"

if [ "${EUID:-$(id -u 2>/dev/null || echo 1)}" -eq 0 ]; then
    SUDO_CMD=()
elif command -v sudo >/dev/null 2>&1; then
    SUDO_CMD=(sudo -E)
else
    SUDO_CMD=()
fi

run_priv() {
    if [ "${#SUDO_CMD[@]}" -gt 0 ]; then
        "${SUDO_CMD[@]}" "$@"
    else
        "$@"
    fi
}

ensure_localhost_hosts() {
    local hosts_file="/etc/hosts"
    if [ -f "$hosts_file" ] && ! grep -qE '^[[:space:]]*127\.0\.0\.1[[:space:]]+localhost([[:space:]]|$)' "$hosts_file"; then
        run_priv sh -c "echo '127.0.0.1 localhost' >> '$hosts_file'" 2>/dev/null || true
    fi
    if [ -f "$hosts_file" ] && ! grep -qE '^[[:space:]]*::1[[:space:]]+localhost([[:space:]]|$)' "$hosts_file"; then
        run_priv sh -c "echo '::1 localhost' >> '$hosts_file'" 2>/dev/null || true
    fi
}

line() {
    echo -e "  ${BRIGHT_BLUE}────────────────────────────────────────────────────────────${RESET}"
}

human_gb() {
    awk -v mb="${1:-0}" 'BEGIN {
        if (mb >= 1024) printf "%.1f GB", mb/1024;
        else printf "%d MB", mb;
    }'
}

usage_bar() {
    local percent="${1:-0}" width=12 filled empty i
    [[ "$percent" =~ ^[0-9]+$ ]] || percent=0
    (( percent < 0 )) && percent=0
    (( percent > 100 )) && percent=100
    filled=$(( percent * width / 100 ))
    empty=$(( width - filled ))
    printf '%s' "${BRIGHT_CYAN}"
    for ((i=0; i<filled; i++)); do printf '█'; done
    printf '%s' "${DIM}"
    for ((i=0; i<empty; i++)); do printf '░'; done
    printf '%s' "${RESET}"
}

get_ram_stats() {
    local total=0 used=0 percent=0
    if command -v free >/dev/null 2>&1; then
        read -r total used < <(free -m | awk '/^Mem:/ {print $2, $3}')
    fi
    total="${total:-0}"; used="${used:-0}"
    (( total > 0 )) && percent=$(( used * 100 / total ))
    printf '%s|%s|%s' "$used" "$total" "$percent"
}

get_disk_stats() {
    local used=0 total=0 percent=0
    read -r used total percent < <(
        df -P / 2>/dev/null | awk 'NR==2 { gsub(/%/, "", $5); printf "%s %s %s\n", $3, $2, $5 }'
    )
    printf '%s|%s|%s' "${used:-0}" "${total:-0}" "${percent:-0}"
}

get_cpu_percent() {
    local load cores percent
    load="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)"
    cores="$(nproc 2>/dev/null || echo 1)"
    percent="$(awk -v load="$load" -v cores="$cores" 'BEGIN {
        if (cores < 1) cores=1; p=(load/cores)*100;
        if (p > 100) p=100; if (p < 0) p=0; printf "%d", p
    }')"
    printf '%s' "${percent:-0}"
}

get_uptime_short() {
    awk '{
        s=int($1); d=int(s/86400); s%=86400;
        h=int(s/3600); s%=3600; m=int(s/60);
        if (d>0) printf "%dd %dh", d, h;
        else if (h>0) printf "%dh %dm", h, m;
        else printf "%dm", m;
    }' /proc/uptime 2>/dev/null || printf '%s' "unknown"
}

resource_status_color() {
    local percent="${1:-0}"
    if (( percent >= 90 )); then printf '%s' "$BRIGHT_RED"
    elif (( percent >= 75 )); then printf '%s' "$BRIGHT_YELLOW"
    else printf '%s' "$BRIGHT_GREEN"; fi
}

pause_screen() {
    echo
    read -r -p "  Press ENTER to continue..." _ || true
}

status_ok()   { echo -e "  ${GREEN}OK${RESET} $1"; }
status_warn() { echo -e "  ${YELLOW}!${RESET} $1"; }
status_fail() { echo -e "  ${RED}FAIL${RESET} $1"; }

run_silent() {
    local label="$1"; shift
    local tmp="${LOG_DIR}/task_$$.log" pid spin='|/-\' i=0
    echo -ne "  ${CYAN}${label}${RESET} ${DIM}Working ${RESET}"
    "$@" >"$tmp" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        printf '\b%s' "${spin:i++%4:1}"
        sleep 0.18
    done
    if wait "$pid"; then
        printf '\b'; echo -e "${GREEN}OK${RESET}"
        cat "$tmp" >> "$LOG_FILE" 2>/dev/null || true
        rm -f "$tmp"; return 0
    else
        printf '\b'; echo -e "${RED}FAIL${RESET}"
        { echo; echo "[FAILED] $label"; cat "$tmp" 2>/dev/null || true; } >> "$LOG_FILE"
        rm -f "$tmp"
        echo -e "  ${RED}Failed:${RESET} ${label}"
        echo -e "  ${DIM}Log: ${LOG_FILE}${RESET}"
        return 1
    fi
}

header() {
    clear 2>/dev/null || printf '\033c'
    echo
    echo -e "  ${BRIGHT_CYAN}${BOLD}╭────────────────────────────────────────────────────────────╮${RESET}"
    echo -e "  ${BRIGHT_CYAN}${BOLD}│${RESET}  ${BRIGHT_MAGENTA}${BOLD}ZAPPY MODS${RESET}  ${DIM}•${RESET}  ${BRIGHT_WHITE}SERVER INSTALLER${RESET}  ${DIM}v${APP_VERSION}${RESET}      ${BRIGHT_CYAN}${BOLD}│${RESET}"
    echo -e "  ${BRIGHT_CYAN}${BOLD}╰────────────────────────────────────────────────────────────╯${RESET}"
    echo
}

section_title() {
    echo -e "  ${BRIGHT_BLUE}${BOLD}┌─${RESET} ${BRIGHT_WHITE}${BOLD}$1${RESET}"
    echo -e "  ${BRIGHT_BLUE}${BOLD}└────────────────────────────────────────────────────────────${RESET}"
    echo
}

load_vps_env() {
    [ -f "$VPS_ENV" ] && source "$VPS_ENV"
    RAM_GB="${RAM_GB:-4}"; CPU_CORES="${CPU_CORES:-2}"; DISK_GB="${DISK_GB:-20}"
    USER_NAME="${USER_NAME:-ubuntu}"; USER_PASS="${USER_PASS:-1234}"
    TCP_HOST_PORT="${TCP_HOST_PORT:-2222}"; TCP_GUEST_PORT="${TCP_GUEST_PORT:-22}"
    VPS_MODE="${VPS_MODE:-virtualization}"
}

save_vps_env() {
    cat > "$VPS_ENV" <<EOF
RAM_GB=${RAM_GB}
CPU_CORES=${CPU_CORES}
DISK_GB=${DISK_GB}
USER_NAME=${USER_NAME}
USER_PASS=${USER_PASS}
TCP_HOST_PORT=${TCP_HOST_PORT}
TCP_GUEST_PORT=${TCP_GUEST_PORT}
VPS_MODE=${VPS_MODE}
EOF
}

detect_virt_type() {
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        systemd-detect-virt 2>/dev/null || true
    else printf '%s' "unknown"; fi
}

detect_virtualization() {
    local virt_type; virt_type="$(detect_virt_type)"
    if [ "$virt_type" = "kvm" ] && [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        echo "available"
    else echo "unavailable"; fi
}

kvm_detection_message() {
    local virt_type; virt_type="$(detect_virt_type)"
    if [ "$virt_type" = "kvm" ] && [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        echo -e "  ${BRIGHT_GREEN}${BOLD}◉ KVM VIRTUALISATION AVAILABLE${RESET}"
        echo -e "  ${DIM}systemd-detect-virt:${RESET} ${GREEN}${virt_type}${RESET}"
        echo -e "  ${DIM}/dev/kvm:${RESET} ${GREEN}ready${RESET}"
        return 0
    fi
    echo -e "  ${BRIGHT_YELLOW}${BOLD}◉ KVM VIRTUALISATION UNAVAILABLE${RESET}"
    echo -e "  ${DIM}systemd-detect-virt:${RESET} ${YELLOW}${virt_type:-unknown}${RESET}"
    if [ -e /dev/kvm ]; then
        echo -e "  ${DIM}/dev/kvm:${RESET} ${YELLOW}not usable for this mode${RESET}"
    else
        echo -e "  ${DIM}/dev/kvm:${RESET} ${YELLOW}not available${RESET}"
    fi
    return 1
}

port_in_use() {
    local port="$1"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then return 0; fi
    if command -v ss >/dev/null 2>&1; then
        ss -ltnH 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {found=1} END {exit !found}'
        return $?
    fi
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; return $?
    fi
    if command -v fuser >/dev/null 2>&1; then
        fuser -s "${port}/tcp" 2>/dev/null; return $?
    fi
    return 1
}

find_free_host_port() {
    local port="$1"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then port=2222; fi
    while [ "$port" -le 65535 ]; do
        if ! port_in_use "$port"; then printf '%s' "$port"; return 0; fi
        port=$((port + 1))
    done
    return 1
}

vps_image_in_use() {
    local image="$1"
    if command -v fuser >/dev/null 2>&1 && fuser -s "$image" 2>/dev/null; then return 0; fi
    if command -v lsof >/dev/null 2>&1 && lsof "$image" >/dev/null 2>&1; then return 0; fi
    return 1
}

install_vps_dependencies() {
    run_silent "Updating package index" run_priv apt-get update || return 1
    run_silent "Installing VPS packages" run_priv apt-get install -y \
        qemu-system-x86 qemu-utils wget cloud-image-utils curl lsof ca-certificates || return 1
}

download_vps_image() {
    VPS_IMAGE="${VPS_DIR}/ubuntu22.qcow2"
    if [ -f "$VPS_IMAGE" ]; then
        status_ok "Ubuntu 22.04 image cache found"
    else
        run_silent "Downloading Ubuntu 22.04 image" run_priv wget -q \
            "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img" \
            -O "$VPS_IMAGE" || return 1
    fi
    run_silent "Expanding VPS disk" run_priv qemu-img resize "$VPS_IMAGE" "${DISK_GB}G" || return 1
    run_priv chmod 666 "$VPS_IMAGE" 2>/dev/null || true
}

create_cloud_init() {
    local user_data="$VPS_DIR/user-data" meta_data="$VPS_DIR/meta-data" seed="$VPS_DIR/seed.img"
    cat > "$user_data" <<EOF
#cloud-config
hostname: zappy-vps
manage_etc_hosts: true
ssh_pwauth: true
ssh_deletekeys: false
users:
  - default
  - name: ${USER_NAME}
    groups: [sudo, docker]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
chpasswd:
  list: |
    ${USER_NAME}:${USER_PASS}
  expire: false
package_update: true
package_upgrade: false
packages:
  - sudo
  - systemd
  - dbus
  - curl
  - wget
  - git
  - unzip
  - htop
  - lsof
  - ca-certificates
  - docker.io
  - containerd
runcmd:
  - [bash, -lc, "systemctl enable containerd.service docker.service"]
  - [bash, -lc, "systemctl start containerd.service docker.service"]
  - [bash, -lc, "usermod -aG docker '${USER_NAME}'"]
EOF
    cat > "$meta_data" <<EOF
instance-id: zappy-mods-vps
local-hostname: zappy-vps
EOF
    run_silent "Generating cloud-init disk" cloud-localds "$seed" "$user_data" "$meta_data"
}

start_vps() {
    load_vps_env
    local image="$VPS_DIR/ubuntu22.qcow2" seed="$VPS_DIR/seed.img"
    if [ ! -f "$image" ] || [ ! -f "$seed" ]; then
        status_fail "VPS files are missing. Create the VPS first."
        sleep 1; return 0
    fi
    if vps_image_in_use "$image"; then
        header; section_title "START VPS"
        echo -e "  ${BRIGHT_YELLOW}${BOLD}◉ VPS ALREADY RUNNING${RESET}"; echo
        echo -e "  ${DIM}SSH:${RESET} ${CYAN}localhost:${TCP_HOST_PORT} -> VM:${TCP_GUEST_PORT}${RESET}"; echo
        read -r _ || true; return 0
    fi
    local original_host_port="$TCP_HOST_PORT" free_host_port
    free_host_port="$(find_free_host_port "$TCP_HOST_PORT")" || {
        status_fail "No free TCP port is available for SSH forwarding."
        read -r _ || true; return 0
    }
    if [ "$free_host_port" != "$TCP_HOST_PORT" ]; then
        TCP_HOST_PORT="$free_host_port"; save_vps_env
    fi
    header; section_title "START VPS"
    if [ "$free_host_port" != "$original_host_port" ]; then
        status_warn "Host port ${original_host_port} is already in use; using ${TCP_HOST_PORT} instead."; echo
    fi
    local accel_args=() cpu_args=()
    if [ "$VPS_MODE" = "virtualization" ]; then
        if ! kvm_detection_message; then
            status_warn "Real KVM is not available for this VPS."
            read -r _ || true; return 0
        fi
        accel_args=(-enable-kvm); cpu_args=(-cpu host)
    else
        accel_args=(-accel tcg,thread=multi); cpu_args=(-cpu max)
    fi
    echo -e "  ${DIM}RAM${RESET} ${CYAN}${RAM_GB} GB${RESET}  ${DIM}CPU${RESET} ${CYAN}${CPU_CORES}${RESET}  ${DIM}SSH${RESET} ${CYAN}localhost:${TCP_HOST_PORT}${RESET}"
    echo -e "  ${YELLOW}Starting VPS. Press Ctrl+C to stop.${RESET}"; echo
    set +e
    run_priv qemu-system-x86_64 "${accel_args[@]}" "${cpu_args[@]}" \
        -m "${RAM_GB}G" -smp "$CPU_CORES" \
        -drive "file=${image},format=qcow2,if=virtio" \
        -drive "file=${seed},format=raw,if=virtio" \
        -boot order=c -nographic \
        -netdev "user,id=net0,hostfwd=tcp::${TCP_HOST_PORT}-:${TCP_GUEST_PORT}" \
        -device virtio-net-pci,netdev=net0
    local qemu_rc=$?
    set -e
    if [ "$qemu_rc" -eq 0 ] || [ "$qemu_rc" -eq 130 ] || [ "$qemu_rc" -eq 143 ]; then
        status_ok "VPS stopped"
    else
        status_fail "QEMU exited with code ${qemu_rc}"
    fi
    read -r _ || true; return 0
}

create_vps() {
    header; section_title "CREATE VPS"; load_vps_env
    read -r -p "  RAM in GB [${RAM_GB}]: " value || true; RAM_GB="${value:-$RAM_GB}"
    read -r -p "  CPU cores [${CPU_CORES}]: " value || true; CPU_CORES="${value:-$CPU_CORES}"
    read -r -p "  Disk in GB [${DISK_GB}]: " value || true; DISK_GB="${value:-$DISK_GB}"
    read -r -p "  Username [${USER_NAME}]: " value || true; USER_NAME="${value:-$USER_NAME}"
    read -r -s -p "  Password [hidden]: " value || true; echo; USER_PASS="${value:-$USER_PASS}"
    read -r -p "  Host SSH port [${TCP_HOST_PORT}]: " value || true; TCP_HOST_PORT="${value:-$TCP_HOST_PORT}"
    save_vps_env; echo
    install_vps_dependencies || { pause_screen; return 1; }
    download_vps_image || { pause_screen; return 1; }
    create_cloud_init || { pause_screen; return 1; }
    status_ok "VPS created successfully"; start_vps
}

vps_virtualization() {
    header; section_title ".VPS • WITH VIRTUALISATION"
    VPS_MODE="virtualization"; load_vps_env; VPS_MODE="virtualization"
    if ! kvm_detection_message; then
        status_warn "Option 01 requires real KVM."
        read -r _ || true; return 0
    fi
    save_vps_env; create_vps || return 1
}

vps_no_virtualization() {
    header; section_title ".VPS • WITHOUT VIRTUALISATION"
    VPS_MODE="no_virtualization"; load_vps_env; VPS_MODE="no_virtualization"; save_vps_env
    create_vps || return 1
}

configure_network() {
    header; section_title "VPS NETWORK"; load_vps_env
    echo -e "  ${DIM}Current:${RESET} ${CYAN}localhost:${TCP_HOST_PORT} -> VM:${TCP_GUEST_PORT}${RESET}"; echo
    read -r -p "  New host SSH port [${TCP_HOST_PORT}]: " value || true
    TCP_HOST_PORT="${value:-$TCP_HOST_PORT}"; save_vps_env
    status_ok "SSH forwarding port saved: ${TCP_HOST_PORT}"; pause_screen
}

clean_vps() {
    header; section_title "CLEAN VPS"
    echo -e "  ${YELLOW}This removes the saved VPS disk, cloud-init and configuration.${RESET}"; echo
    read -r -p "  Continue? [y/N]: " answer || true
    [[ "$answer" =~ ^[Yy]$ ]] || return 0
    run_silent "Removing VPS files" rm -rf "$VPS_DIR" || { mkdir -p "$VPS_DIR"; pause_screen; return 1; }
    mkdir -p "$VPS_DIR"; rm -f "$VPS_ENV" 2>/dev/null || true
    status_ok "VPS workspace cleaned"; pause_screen
}

vps_menu() {
    while true; do
        header; section_title ".VPS"
        echo -e "  ${BRIGHT_CYAN}${BOLD}01${RESET}  ${WHITE}VPS with Virtualisation${RESET}"
        echo -e "  ${BRIGHT_CYAN}${BOLD}02${RESET}  ${WHITE}VPS without Virtualisation${RESET}"
        echo -e "  ${BRIGHT_CYAN}${BOLD}03${RESET}  ${WHITE}Start Existing VPS${RESET}"
        echo -e "  ${BRIGHT_CYAN}${BOLD}04${RESET}  ${WHITE}Network Settings${RESET}"
        echo -e "  ${BRIGHT_CYAN}${BOLD}05${RESET}  ${WHITE}Clean VPS${RESET}"
        echo -e "  ${BRIGHT_CYAN}${BOLD}00${RESET}  ${WHITE}Back${RESET}"; echo
        read -r -p "  Select option [00-05]: " choice || true
        case "$choice" in
            1|01) vps_virtualization || true ;;
            2|02) vps_no_virtualization || true ;;
            3|03) start_vps || true ;;
            4|04) configure_network || true ;;
            5|05) clean_vps || true ;;
            0|00) return 0 ;;
            *) status_fail "Invalid option"; sleep 1 ;;
        esac
    done
}

install_pterodactyl() {
    header; section_title ".PTERODACTYL PANEL"
    echo -e "  ${WHITE}Pterodactyl Panel + Wings installer${RESET}"; echo
    read -r -p "  Continue? [y/N]: " answer || true
    [[ "$answer" =~ ^[Yy]$ ]] || return 0
    bash <(curl -fsSL https://pterodactyl-installer.se) 2>&1 | tee -a "$LOG_FILE"
    status_ok "Pterodactyl installer finished"; pause_screen
}

install_playit() {
    header; section_title ".TOOLS • PLAYIT"
    run_silent "Updating package index" run_priv apt-get update -y || { pause_screen; return 1; }
    run_silent "Installing Playit dependencies" run_priv apt-get install -y curl gnupg ca-certificates || { pause_screen; return 1; }
    local keyring="/etc/apt/trusted.gpg.d/playit.gpg" repo="/etc/apt/sources.list.d/playit-cloud.list"
    curl -fsSL --max-time 30 https://playit-cloud.github.io/ppa/key.gpg 2>>"$LOG_FILE" | run_priv gpg --dearmor --yes -o "$keyring" >>"$LOG_FILE" 2>&1 || { status_fail "Failed to add Playit GPG key"; pause_screen; return 1; }
    echo "deb [signed-by=${keyring}] https://playit-cloud.github.io/ppa/data ./" | run_priv tee "$repo" >/dev/null
    run_silent "Refreshing Playit repository" run_priv apt-get update -y || { pause_screen; return 1; }
    run_silent "Installing Playit" run_priv apt-get install -y playit || { pause_screen; return 1; }
    status_ok "Playit installed successfully"; pause_screen
}

install_cloudflared_binary() {
    local tmp_dir; tmp_dir="$(mktemp -d)"
    run_silent "Downloading cloudflared binary" curl -fsSL --max-time 120 \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" \
        -o "${tmp_dir}/cloudflared" || { rm -rf "$tmp_dir"; return 1; }
    run_silent "Installing cloudflared binary" run_priv install -m 0755 "${tmp_dir}/cloudflared" /usr/local/bin/cloudflared || { rm -rf "$tmp_dir"; return 1; }
    rm -rf "$tmp_dir"; return 0
}

install_cloudflared_deb() {
    local deb_file="/tmp/cloudflared-$$.deb"; rm -f "$deb_file"
    run_silent "Downloading cloudflared .deb" curl -fsSL --max-time 120 \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb" \
        -o "$deb_file" || { rm -f "$deb_file"; return 1; }
    if ! run_silent "Installing cloudflared .deb" run_priv dpkg -i "$deb_file"; then
        run_priv apt-get install -f -y >/dev/null 2>&1 || true
        if ! command -v cloudflared >/dev/null 2>&1; then rm -f "$deb_file"; return 1; fi
    fi
    rm -f "$deb_file"; return 0
}

install_cloudflared_apt() {
    run_silent "Adding Cloudflare GPG key directory" run_priv mkdir -p --mode=0755 /usr/share/keyrings || return 1
    curl -fsSL --max-time 30 https://pkg.cloudflare.com/cloudflare-public-v2.gpg \
        | run_priv tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null 2>>"$LOG_FILE" || return 1
    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' \
        | run_priv tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
    run_silent "Updating package index" run_priv apt-get update || return 1
    run_silent "Installing cloudflared via apt" run_priv apt-get install -y cloudflared || return 1
    return 0
}

install_cloudflared_any() {
    if command -v cloudflared >/dev/null 2>&1; then
        status_ok "cloudflared already installed"; return 0
    fi
    if install_cloudflared_apt; then status_ok "cloudflared installed via apt"; return 0; fi
    status_warn "APT method failed. Trying direct .deb from GitHub..."
    if install_cloudflared_deb; then status_ok "cloudflared installed via .deb"; return 0; fi
    status_warn "DEB method failed. Trying standalone binary..."
    if install_cloudflared_binary; then status_ok "cloudflared installed as standalone binary"; return 0; fi
    status_fail "Could not install cloudflared by any method"; return 1
}

cloudflared_systemd_available() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] \
        && [ "$(ps -p 1 -o comm= 2>/dev/null || true)" = "systemd" ]
}

cloudflared_running() {
    if [ -f "$CF_PID_FILE" ]; then
        local pid; pid="$(cat "$CF_PID_FILE" 2>/dev/null || true)"
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then return 0; fi
    fi
    pgrep -f 'cloudflared.*tunnel.*run' >/dev/null 2>&1 && return 0
    return 1
}

stop_cloudflared_manual() {
    if [ -f "$CF_PID_FILE" ]; then
        local pid; pid="$(cat "$CF_PID_FILE" 2>/dev/null || true)"
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true; sleep 1
        fi
        rm -f "$CF_PID_FILE"
    fi
    pkill -f 'cloudflared.*tunnel.*run' 2>/dev/null || true
}

start_cloudflared_manual() {
    local token="$1"
    ensure_localhost_hosts
    if cloudflared_running; then
        status_ok "cloudflared tunnel already running"; return 0
    fi
    local metrics_addr="127.0.0.1:0"
    local attempt token_env=()
    for attempt in 1 2 3; do
        case "$attempt" in
            1) token_env=(--metrics "$metrics_addr") ;;
            2) token_env=(--metrics "0.0.0.0:0" --protocol http2) ;;
            3) token_env=(--metrics "" --protocol http2 --no-autoupdate) ;;
        esac
        : > "$CF_LOG_FILE" 2>/dev/null || true
        nohup cloudflared tunnel run --token "$token" "${token_env[@]}" \
            >>"$CF_LOG_FILE" 2>&1 </dev/null &
        local pid=$!
        echo "$pid" > "$CF_PID_FILE"
        sleep 3
        if kill -0 "$pid" 2>/dev/null && ! grep -q "Error opening metrics server listener" "$CF_LOG_FILE" 2>/dev/null; then
            status_ok "cloudflared tunnel running (PID ${pid})"
            echo -e "  ${DIM}Log:${RESET} ${CYAN}${CF_LOG_FILE}${RESET}"
            return 0
        fi
        if kill -0 "$pid" 2>/dev/null; then
            status_ok "cloudflared tunnel running (PID ${pid}, metrics warning ignored)"
            echo -e "  ${DIM}Log:${RESET} ${CYAN}${CF_LOG_FILE}${RESET}"
            return 0
        fi
        kill "$pid" 2>/dev/null || true
        sleep 1
    done
    status_fail "cloudflared tunnel failed to start"
    echo -e "  ${DIM}Check:${RESET} ${CYAN}${CF_LOG_FILE}${RESET}"
    tail -n 10 "$CF_LOG_FILE" 2>/dev/null | sed 's/^/  /' || true
    return 1
}

install_cloudflare_tunnel() {
    header; section_title ".TOOLS • CLOUDFLARE TUNNEL"
    echo -e "  ${WHITE}Cloudflare Tunnel installer${RESET}"; echo

    install_cloudflared_any || { pause_screen; return 1; }
    ensure_localhost_hosts

    echo
    echo -e "  ${BRIGHT_WHITE}${BOLD}Cloudflare Tunnel Token${RESET}"
    echo -e "  ${DIM}Paste your Cloudflare tunnel token or the full install command.${RESET}"
    echo

    local tunnel_token token_input
    read -r -p "  Token or full install command: " token_input || true
    echo
    token_input="${token_input#"${token_input%%[![:space:]]*}"}"
    token_input="${token_input%"${token_input##*[![:space:]]}"}"
    token_input="${token_input%$'\r'}"

    if [[ "$token_input" =~ ^(sudo[[:space:]]+)?cloudflared[[:space:]]+service[[:space:]]+install[[:space:]]+(.+)$ ]]; then
        tunnel_token="${BASH_REMATCH[2]}"
    else
        tunnel_token="$token_input"
    fi
    case "$tunnel_token" in
        \"*\") tunnel_token="${tunnel_token:1:${#tunnel_token}-2}" ;;
        '*') tunnel_token="${tunnel_token:1:${#tunnel_token}-2}" ;;
    esac
    tunnel_token="${tunnel_token%$'\r'}"
    tunnel_token="${tunnel_token#"${tunnel_token%%[![:space:]]*}"}"
    tunnel_token="${tunnel_token%"${tunnel_token##*[![:space:]]}"}"

    if [ -z "$tunnel_token" ]; then
        status_fail "Cloudflare tunnel token cannot be empty"
        pause_screen; return 1
    fi

    status_ok "Cloudflare tunnel token received"
    echo

    local cf_service_ok=0
    if cloudflared_systemd_available; then
        local cf_error="${LOG_DIR}/cloudflared-install-$$.err"
        rm -f "$cf_error"
        if run_priv cloudflared service install "$tunnel_token" >/dev/null 2>"$cf_error"; then
            cf_service_ok=1
            status_ok "Cloudflare Tunnel systemd service installed"
        else
            [ -s "$cf_error" ] && { echo -e "  ${BRIGHT_YELLOW}cloudflared:${RESET}"; sed 's/^[[:space:]]*/  /' "$cf_error" | tail -n 6; }
            rm -f "$cf_error"
        fi
    else
        status_warn "systemd is not running (container). Using manual background mode."
    fi

    if [ "$cf_service_ok" -eq 0 ]; then
        echo -e "  ${DIM}Starting cloudflared manually...${RESET}"
        if ! start_cloudflared_manual "$tunnel_token"; then
            pause_screen; return 1
        fi
    fi

    printf '%s\n' "$tunnel_token" > "$CF_TOKEN_FILE"
    chmod 600 "$CF_TOKEN_FILE"

    echo
    echo -e "  ${BRIGHT_GREEN}${BOLD}Tunnel is live. Add these in Cloudflare Dashboard:${RESET}"
    echo -e "  ${DIM}Panel Route:${RESET}  Type: https  URL: localhost:8443  TLS: on"
    echo -e "  ${DIM}Wings Route:${RESET}  Type: https  URL: localhost       TLS: on"
    echo -e "  ${DIM}Panel Settings:${RESET} encryption: n  assume SSL: y  HTTPS request: n"
    echo
    status_ok "Cloudflare Tunnel setup complete"
    pause_screen
}

cloudflared_control_menu() {
    while true; do
        header; section_title ".TOOLS • CLOUDFLARED CONTROL"
        local state="STOPPED" state_color="$BRIGHT_RED"
        if cloudflared_running; then state="RUNNING"; state_color="$BRIGHT_GREEN"; fi
        echo -e "  ${DIM}Status:${RESET} ${state_color}${BOLD}${state}${RESET}"; echo
        echo -e "  ${CYAN}01${RESET}  ${WHITE}Start Tunnel${RESET}"
        echo -e "  ${CYAN}02${RESET}  ${WHITE}Stop Tunnel${RESET}"
        echo -e "  ${CYAN}03${RESET}  ${WHITE}Restart Tunnel${RESET}"
        echo -e "  ${CYAN}04${RESET}  ${WHITE}View Tunnel Log${RESET}"
        echo -e "  ${CYAN}00${RESET}  ${WHITE}Back${RESET}"; echo
        read -r -p "  Select › " choice || true
        case "$choice" in
            1|01)
                if [ ! -f "$CF_TOKEN_FILE" ]; then status_fail "No token saved."; pause_screen; continue; fi
                start_cloudflared_manual "$(cat "$CF_TOKEN_FILE")" || true; pause_screen ;;
            2|02) stop_cloudflared_manual; status_ok "cloudflared stopped"; pause_screen ;;
            3|03)
                if [ ! -f "$CF_TOKEN_FILE" ]; then status_fail "No token saved."; pause_screen; continue; fi
                stop_cloudflared_manual; sleep 1
                start_cloudflared_manual "$(cat "$CF_TOKEN_FILE")" || true; pause_screen ;;
            4|04)
                header; section_title "CLOUDFLARED LOG"
                tail -n 60 "$CF_LOG_FILE" 2>/dev/null || true; pause_screen ;;
            0|00) return 0 ;;
            *) status_fail "Invalid selection"; sleep 1 ;;
        esac
    done
}

install_pufferpanel_deps() {
    run_silent "Installing PufferPanel dependencies" run_priv apt-get install -y curl gnupg ca-certificates || true
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=("curl")
    command -v gpg  >/dev/null 2>&1 || missing+=("gnupg")
    if [ "${#missing[@]}" -gt 0 ]; then
        status_fail "Required tools missing: ${missing[*]}"; return 1
    fi
    return 0
}

install_pufferpanel() {
    header; section_title ".TOOLS • PUFFERPANEL"
    echo -e "  ${WHITE}PufferPanel installer (web port 8081)${RESET}"; echo
    read -r -p "  Install Cloudflare Tunnel first? [y/N]: " cf_answer || true; echo
    if [[ "$cf_answer" =~ ^[Yy]$ ]]; then
        install_cloudflare_tunnel || {
            status_fail "Cloudflare Tunnel failed. PufferPanel cancelled."
            pause_screen; return 0
        }; echo
    fi

    run_silent "Updating package index" run_priv apt-get update || { pause_screen; return 1; }
    install_pufferpanel_deps || { pause_screen; return 1; }
    run_silent "Creating PufferPanel keyring directory" run_priv mkdir -p /etc/apt/keyrings || { pause_screen; return 1; }

    local puffer_key="/etc/apt/keyrings/pufferpanel.gpg" puffer_repo="/etc/apt/sources.list.d/pufferpanel.sources"
    curl -fsSL --max-time 30 https://packagecloud.io/pufferpanel/pufferpanel/gpgkey \
        | run_priv gpg --dearmor --yes \
            | run_priv tee "$puffer_key" >/dev/null 2>>"$LOG_FILE" || {
        status_fail "Failed to add PufferPanel GPG key"; pause_screen; return 1
    }
    cat <<'EOF' | run_priv tee "$puffer_repo" >/dev/null
X-Repolib-Name: PufferPanel
Types: deb
URIs: https://packagecloud.io/pufferpanel/pufferpanel/any/
Suites: any
Components: main
Signed-By: /etc/apt/keyrings/pufferpanel.gpg
EOF
    run_silent "Refreshing PufferPanel repository" run_priv apt-get update || { pause_screen; return 1; }
    run_silent "Installing PufferPanel" run_priv apt-get install -y pufferpanel || { pause_screen; return 1; }

    local puffer_config="/etc/pufferpanel/config.json"
    if run_priv test -f "$puffer_config"; then
        run_priv sed -i 's/"host"[[:space:]]*:[[:space:]]*"0\.0\.0\.0:8080"/"host": "0.0.0.0:8081"/' "$puffer_config" \
            && status_ok "PufferPanel web port set to 8081"
    fi

    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] \
        && [ "$(ps -p 1 -o comm= 2>/dev/null || true)" = "systemd" ]; then
        run_silent "Reloading systemd" run_priv systemctl daemon-reload || true
        run_silent "Enabling PufferPanel" run_priv systemctl enable pufferpanel || true
        run_silent "Starting PufferPanel" run_priv systemctl restart pufferpanel || true
        status_ok "PufferPanel service is running"
    else
        status_warn "systemd unavailable; using runService mode"
        local puffer_pid_file="/run/pufferpanel.pid" puffer_log="/var/log/pufferpanel.log" puffer_bin=""
        for c in /usr/sbin/pufferpanel /usr/bin/pufferpanel /usr/local/bin/pufferpanel; do
            [ -x "$c" ] && { puffer_bin="$c"; break; }
        done
        if [ -z "$puffer_bin" ]; then status_fail "PufferPanel binary not found"; pause_screen; return 1; fi
        run_priv bash -c "nohup '${puffer_bin}' runService >>'${puffer_log}' 2>&1 </dev/null & echo \$! >'${puffer_pid_file}'"
        sleep 2
        local puffer_pid; puffer_pid="$(run_priv cat "$puffer_pid_file" 2>/dev/null || true)"
        if [[ "$puffer_pid" =~ ^[0-9]+$ ]] && kill -0 "$puffer_pid" 2>/dev/null; then
            status_ok "PufferPanel started (PID ${puffer_pid})"
        else
            status_fail "PufferPanel failed to start"; pause_screen; return 1
        fi
    fi

    echo
    echo -e "  ${BRIGHT_WHITE}${BOLD}Create PufferPanel admin user${RESET}"
    echo
    local puffer_cmd=""
    for c in pufferpanel /usr/sbin/pufferpanel /usr/bin/pufferpanel /usr/local/bin/pufferpanel; do
        command -v "$c" >/dev/null 2>&1 && { puffer_cmd="$c"; break; }
        [ -x "$c" ] && { puffer_cmd="$c"; break; }
    done
    if [ -z "$puffer_cmd" ]; then status_fail "pufferpanel command not found"; pause_screen; return 1; fi
    if run_priv "$puffer_cmd" user add; then
        status_ok "PufferPanel user created"
    else
        status_warn "User creation cancelled. Retry: pufferpanel user add"
    fi
    status_ok "PufferPanel installation completed"
    echo -e "  ${DIM}Panel:${RESET} ${CYAN}http://YOUR_SERVER_IP:8081${RESET}"
    pause_screen
}

delete_cloudflare_tunnel() {
    header; section_title ".TOOLS • DELETE CLOUDFLARE TUNNEL"
    if command -v cloudflared >/dev/null 2>&1; then
        run_priv cloudflared service uninstall >>"$LOG_FILE" 2>&1 || true
    fi
    stop_cloudflared_manual
    rm -f "$CF_TOKEN_FILE"
    status_ok "Local cloudflared state cleared"
    pause_screen
}

tools_menu() {
    while true; do
        header; section_title ".TOOLS"
        echo -e "  ${CYAN}01${RESET}  ${WHITE}Playit${RESET}"
        echo -e "  ${CYAN}02${RESET}  ${WHITE}Cloudflare Tunnel${RESET}"
        echo -e "  ${CYAN}03${RESET}  ${WHITE}PufferPanel${RESET}"
        echo -e "  ${CYAN}04${RESET}  ${WHITE}Cloudflared Control${RESET}"
        echo -e "  ${CYAN}00${RESET}  ${WHITE}Back${RESET}"; echo
        read -r -p "  Select › " choice || true
        case "$choice" in
            1|01) install_playit || true ;;
            2|02)
                while true; do
                    header; section_title ".TOOLS • CLOUDFLARE TUNNEL"
                    echo -e "  ${CYAN}01${RESET}  ${WHITE}Install Tunnel${RESET}"
                    echo -e "  ${CYAN}02${RESET}  ${WHITE}Delete Tunnel${RESET}"
                    echo -e "  ${CYAN}00${RESET}  ${WHITE}Back${RESET}"; echo
                    read -r -p "  Select › " tc || true
                    case "$tc" in
                        1|01) install_cloudflare_tunnel || true ;;
                        2|02) delete_cloudflare_tunnel || true ;;
                        0|00) break ;;
                        *) status_fail "Invalid"; sleep 1 ;;
                    esac
                done ;;
            3|03) install_pufferpanel || true ;;
            4|04) cloudflared_control_menu || true ;;
            0|00) return 0 ;;
            *) status_fail "Invalid selection"; sleep 1 ;;
        esac
    done
}

install_chunkdash() {
    header; section_title ".DASHBOARDS • CHUNKDASH"
    local dir="${HOME}/Hosting-panel"
    if [ -d "$dir" ]; then
        read -r -p "  Reinstall? [y/N]: " answer || true
        [[ "$answer" =~ ^[Yy]$ ]] && run_silent "Removing existing" rm -rf "$dir" || { pause_screen; return 0; }
    fi
    run_silent "Downloading ChunkDash" git clone https://github.com/deadlauncherg/Hosting-panel.git "$dir" || { pause_screen; return 1; }
    cd "$dir"
    local nvm_dir="${HOME}/.nvm"
    if [ ! -s "${nvm_dir}/nvm.sh" ]; then
        run_silent "Installing NVM" bash -c 'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash' || { pause_screen; return 1; }
    fi
    export NVM_DIR="$nvm_dir"
    [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
    run_silent "Installing Node.js 18" nvm install 18 || { pause_screen; return 1; }
    run_silent "Selecting Node.js 18" nvm use 18 || { pause_screen; return 1; }
    run_silent "Installing packages" npm install || { pause_screen; return 1; }
    status_ok "ChunkDash installed"; echo -e "  ${DIM}Edit:${RESET} ${CYAN}${dir}/settings.json${RESET}"
    pause_screen
}

dashboards_menu() {
    while true; do
        header; section_title ".DASHBOARDS"
        echo -e "  ${CYAN}01${RESET}  ${WHITE}ChunkDash • Feastic Theme${RESET}"
        echo -e "  ${CYAN}02${RESET}  ${DIM}Coming Soon${RESET}"
        echo -e "  ${CYAN}03${RESET}  ${DIM}Coming Soon${RESET}"
        echo -e "  ${CYAN}00${RESET}  ${WHITE}Back${RESET}"; echo
        read -r -p "  Select › " choice || true
        case "$choice" in
            1) install_chunkdash || true ;;
            2|3) status_warn "Coming soon"; sleep 1 ;;
            0|00) return 0 ;;
            *) status_fail "Invalid"; sleep 1 ;;
        esac
    done
}

main_menu() {
    while true; do
        header
        local host_arch virt_type kvm_status kvm_label kvm_color
        local ram_stats ram_used ram_total ram_percent
        local disk_stats disk_used disk_total disk_percent
        local cpu_percent cpu_color uptime_short

        host_arch="$(uname -m 2>/dev/null || echo unknown)"
        virt_type="$(detect_virt_type)"
        kvm_status="$(detect_virtualization)"
        if [ "$kvm_status" = "available" ]; then
            kvm_label="AVAILABLE"; kvm_color="$BRIGHT_GREEN"
        else
            kvm_label="UNAVAILABLE"; kvm_color="$BRIGHT_YELLOW"
        fi
        ram_stats="$(get_ram_stats)"; IFS='|' read -r ram_used ram_total ram_percent <<< "$ram_stats"
        disk_stats="$(get_disk_stats)"; IFS='|' read -r disk_used disk_total disk_percent <<< "$disk_stats"
        cpu_percent="$(get_cpu_percent)"
        cpu_color="$(resource_status_color "$cpu_percent")"
        uptime_short="$(get_uptime_short)"

        echo -e "  ${BRIGHT_GREEN}${BOLD}◉ ONLINE${RESET}  ${DIM}HOST${RESET} ${WHITE}${host_arch}${RESET}  ${DIM}VIRT${RESET} ${WHITE}${virt_type}${RESET}  ${DIM}KVM${RESET} ${kvm_color}${BOLD}${kvm_label}${RESET}"; echo
        echo -e "  ${BRIGHT_BLUE}${BOLD}╭──────────────────── LIVE SYSTEM ────────────────────╮${RESET}"
        echo -e "  ${BRIGHT_BLUE}${BOLD}│${RESET}  ${BRIGHT_WHITE}${BOLD}RAM${RESET}   ${DIM}$(human_gb "$ram_used") / $(human_gb "$ram_total")${RESET}  ${cpu_color}${BOLD}${ram_percent}%${RESET}  $(usage_bar "$ram_percent") ${BRIGHT_BLUE}${BOLD}│${RESET}"
        echo -e "  ${BRIGHT_BLUE}${BOLD}│${RESET}  ${BRIGHT_WHITE}${BOLD}DISK${RESET}  ${DIM}$(human_gb "$((disk_used / 1024))") / $(human_gb "$((disk_total / 1024))")${RESET}  $(resource_status_color "$disk_percent")${BOLD}${disk_percent}%${RESET}  $(usage_bar "$disk_percent") ${BRIGHT_BLUE}${BOLD}│${RESET}"
        echo -e "  ${BRIGHT_BLUE}${BOLD}│${RESET}  ${BRIGHT_WHITE}${BOLD}CPU${RESET}   ${DIM}load usage${RESET}  ${cpu_color}${BOLD}${cpu_percent}%${RESET}  $(usage_bar "$cpu_percent")   ${DIM}UP ${uptime_short}${RESET} ${BRIGHT_BLUE}${BOLD}│${RESET}"
        echo -e "  ${BRIGHT_BLUE}${BOLD}╰────────────────────────────────────────────────────────────╯${RESET}"; echo

        line
        echo -e "  ${BRIGHT_WHITE}${BOLD}MAIN MENU${RESET}"; echo
        echo -e "  ${BRIGHT_CYAN}${BOLD}01${RESET}  ${BRIGHT_WHITE}${BOLD}.VPS${RESET}"
        echo -e "  ${BRIGHT_MAGENTA}${BOLD}02${RESET}  ${BRIGHT_WHITE}${BOLD}.PTERODACTYL${RESET}"
        echo -e "  ${BRIGHT_YELLOW}${BOLD}03${RESET}  ${BRIGHT_WHITE}${BOLD}.TOOLS${RESET}"
        echo -e "  ${BRIGHT_BLUE}${BOLD}04${RESET}  ${BRIGHT_WHITE}${BOLD}.DASHBOARDS${RESET}"
        echo -e "  ${BRIGHT_GREEN}${BOLD}05${RESET}  ${BRIGHT_WHITE}${BOLD}LOGS${RESET}"
        echo -e "  ${DIM}${BOLD}00${RESET}  ${BRIGHT_WHITE}${BOLD}EXIT${RESET}"; echo

        line
        echo -e "  ${DIM}ZAPPY MODS${RESET} ${BRIGHT_CYAN}›${RESET}"
        printf -v MAIN_MENU_PROMPT "  %s%sSelect [00-05] › %s" "$BRIGHT_CYAN" "$BOLD" "$RESET"
        read -r -p "$MAIN_MENU_PROMPT" choice || true

        case "$choice" in
            1|01) vps_menu || true ;;
            2|02) install_pterodactyl || true ;;
            3|03) tools_menu || true ;;
            4|04) dashboards_menu || true ;;
            5|05)
                header; section_title "INSTALLER LOG"
                tail -n 60 "$LOG_FILE" 2>/dev/null || true
                pause_screen ;;
            0|00)
                clear 2>/dev/null || printf '\033c'
                echo -e "  ${BRIGHT_CYAN}${BOLD}ZAPPY MODS${RESET} ${DIM}closed.${RESET}"; echo
                exit 0 ;;
            *) status_fail "Invalid option"; sleep 1 ;;
        esac
    done
}

ensure_localhost_hosts
trap 'echo; status_fail "Unexpected error. See: $LOG_FILE"; pause_screen' ERR
main_menu
