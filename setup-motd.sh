#!/usr/bin/env bash
# setup-motd.sh - fast, colored MOTD for Debian/Raspberry Pi
# Usage:
#   sudo ./setup-motd.sh --install
#   ./setup-motd.sh

set -euo pipefail

SELF_NAME="motd-pi"
MOTD_BIN="/usr/local/sbin/${SELF_NAME}"
MOTD_HOOK="/etc/update-motd.d/99-${SELF_NAME}"

CACHE_DIR="/var/cache/${SELF_NAME}"
CACHE_FILE="${CACHE_DIR}/updates.cache"

SYSTEMD_SERVICE="/etc/systemd/system/${SELF_NAME}-updates.service"
SYSTEMD_TIMER="/etc/systemd/system/${SELF_NAME}-updates.timer"

RST=""
BLD=""
DIM=""
RED=""
GRN=""
YEL=""
BLU=""
MAG=""
CYN=""
WHT=""

init_colors() {
  if command -v tput >/dev/null 2>&1 && [[ -n "${TERM:-}" ]] && tput sgr0 >/dev/null 2>&1 && tput setaf 1 >/dev/null 2>&1; then
    RST="$(tput sgr0)"
    BLD="$(tput bold)"
    DIM="$(tput dim 2>/dev/null || true)"
    RED="$(tput setaf 1)"
    GRN="$(tput setaf 2)"
    YEL="$(tput setaf 3)"
    BLU="$(tput setaf 4)"
    MAG="$(tput setaf 5)"
    CYN="$(tput setaf 6)"
    WHT="$(tput setaf 7)"
    return 0
  fi

  RST=$'\033[0m'
  BLD=$'\033[1m'
  DIM=$'\033[2m'
  RED=$'\033[31m'
  GRN=$'\033[32m'
  YEL=$'\033[33m'
  BLU=$'\033[34m'
  MAG=$'\033[35m'
  CYN=$'\033[36m'
  WHT=$'\033[37m'
}

init_colors

have() { command -v "$1" >/dev/null 2>&1; }

msg_info() { printf "%s[INFO]%s %s\n" "${BLD}${BLU}" "${RST}" "$*"; }
msg_ok() { printf "%s[ OK ]%s %s\n" "${BLD}${GRN}" "${RST}" "$*"; }
msg_warn() { printf "%s[WARN]%s %s\n" "${BLD}${YEL}" "${RST}" "$*"; }
msg_err() { printf "%s[ERR ]%s %s\n" "${BLD}${RED}" "${RST}" "$*" >&2; }

hr() { printf "%s\n" "${DIM}----------------------------------------------------------------------------${RST}"; }

pill() {
  local text="$1"
  local color="$2"
  printf "%s[%s]%s" "${BLD}${color}" "${text}" "${RST}"
}

kv() {
  local key="$1"
  local value="$2"
  local key_color="${3:-$CYN}"
  printf "  %s%-14s%s %s\n" "${BLD}${key_color}" "${key}:" "${RST}" "${value}"
}

get_hostname() { hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "host"; }

is_rpi() {
  if [[ -r /proc/device-tree/model ]] && tr -d '\0' </proc/device-tree/model | grep -qi "raspberry pi"; then
    return 0
  fi
  if [[ -r /proc/cpuinfo ]] && grep -qi "Raspberry Pi" /proc/cpuinfo; then
    return 0
  fi
  return 1
}

is_intel() {
  local arch
  arch="$(uname -m 2>/dev/null || echo "")"
  [[ "${arch}" == "x86_64" || "${arch}" == "i386" || "${arch}" == "i686" ]]
}

get_os() {
  # shellcheck disable=SC1091
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    echo "${PRETTY_NAME:-Linux}"
  else
    echo "Linux"
  fi
}

get_os_id() {
  # shellcheck disable=SC1091
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    echo "${ID:-unknown}"
  else
    echo "unknown"
  fi
}

get_kernel() { uname -r; }
get_load() { awk '{printf "%s %s %s", $1,$2,$3}' /proc/loadavg 2>/dev/null || echo "n/a"; }
get_uptime() { uptime -p 2>/dev/null || echo "n/a"; }

get_last_boot() {
  if have who; then
    who -b 2>/dev/null | awk '{print $3" "$4}' || echo "n/a"
  else
    echo "n/a"
  fi
}

get_cpu_model() {
  awk -F: '/Model|model name/ {gsub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null || echo "n/a"
}

get_cpu_temp() {
  if have vcgencmd; then
    vcgencmd measure_temp 2>/dev/null | sed -E "s/^temp=([0-9.]+)'C$/\1C/" || true
    return 0
  fi
  if [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
    awk '{printf "%.1fC", $1/1000}' /sys/class/thermal/thermal_zone0/temp
    return 0
  fi
  echo "n/a"
}

get_mem() {
  awk '
    /^MemTotal/ {t=$2}
    /^MemAvailable/ {a=$2}
    END {
      if (t>0) {
        used=(t-a)/1024
        total=t/1024
        printf "%.0fMiB / %.0fMiB", used, total
      } else print "n/a"
    }' /proc/meminfo 2>/dev/null || echo "n/a"
}

get_disk_root() { df -h / 2>/dev/null | awk 'NR==2{printf "%s used of %s (%s)", $3,$2,$5}' || echo "n/a"; }

get_ip_addrs() {
  if have ip; then
    ip -o -4 addr show scope global 2>/dev/null | awk '{print $2": "$4}' | paste -sd ", " - || echo "n/a"
  else
    hostname -I 2>/dev/null | awk '{$1=$1;print}' || echo "n/a"
  fi
}

get_gw() {
  if have ip; then
    ip route show default 2>/dev/null | awk '{print $3}' | head -n1 || true
  fi
}

read_updates_cache() {
  if [[ -r "${CACHE_FILE}" ]]; then
    awk 'NR==1{print $2" "$3}' "${CACHE_FILE}" 2>/dev/null
  else
    echo "n/a n/a"
  fi
}

write_updates_cache() {
  local now total sec

  now="$(date +%s)"
  if have apt-get; then
    total="$(apt-get -s upgrade 2>/dev/null | awk '/^Inst /{c++} END{print c+0}')"
    sec="$(apt-get -s upgrade 2>/dev/null | awk 'BEGIN{s=0} /^Inst /{if (tolower($0) ~ /security/) s++} END{print s+0}')"
  else
    total="n/a"
    sec="n/a"
  fi

  mkdir -p "${CACHE_DIR}" 2>/dev/null || true
  printf "%s %s %s\n" "${now}" "${total}" "${sec}" >"${CACHE_FILE}" 2>/dev/null || true
  chmod 0644 "${CACHE_FILE}" 2>/dev/null || true
}

print_logo_ascii() {
  local osid
  osid="$(get_os_id)"

  if is_rpi; then
    cat <<'LOGO'
        .~~.   .~~.
       '. \ ' ' / .'
        .~ .~~~..~.
       : .~.'~'.~. :
      ~ (   ) (   ) ~
     ( : '~'.~.'~' : )
      ~ .~ (   ) ~. ~
       (  : '~' :  )
        '~ .~~~. ~'
            '~'
LOGO
    return 0
  fi

  if [[ "${osid}" == "debian" ]] && is_intel; then
    cat <<'LOGO'
       ____       _     _
      |  _ \  ___| |__ (_) __ _ _ __
      | | | |/ _ \ '_ \| |/ _` | '_ \
      | |_| |  __/ |_) | | (_| | | | |
      |____/ \___|_.__/|_|\__,_|_| |_|
LOGO
    return 0
  fi

  cat <<'LOGO'
   _     _             _
  | |   (_)           | |
  | |    _ _ __  _   _| |_
  | |   | | '_ \| | | | __|
  | |___| | | | | |_| | |_
  |_____|_|_| |_|\__,_|\__|
LOGO
}

logo_color() {
  local osid
  osid="$(get_os_id)"

  if is_rpi; then
    printf "%s%s" "${BLD}" "${RED}"
    return 0
  fi

  if [[ "${osid}" == "debian" ]] && is_intel; then
    printf "%s%s" "${BLD}" "${RED}"
    return 0
  fi

  printf "%s%s" "${BLD}" "${BLU}"
}

print_header() {
  local host logo_tmp host_tmp logo_w logo_col host_col

  host="$(get_hostname)"
  logo_tmp="$(mktemp)"
  host_tmp="$(mktemp)"

  print_logo_ascii >"${logo_tmp}"
  if have figlet; then
    figlet -f slant "${host}" 2>/dev/null || figlet "${host}" 2>/dev/null || printf "%s\n" "${host}"
  else
    printf "+-%s-+\n" "$(printf '%*s' "${#host}" | tr ' ' '-')"
    printf "| %s |\n" "${host}"
    printf "+-%s-+\n" "$(printf '%*s' "${#host}" | tr ' ' '-')"
  fi >"${host_tmp}"

  logo_w="$(awk '{ if (length > w) w=length } END { print w+0 }' "${logo_tmp}")"
  logo_col="$(logo_color)"
  host_col="${BLD}${MAG}"

  paste -d $'\t' \
    <(awk -v w="${logo_w}" -v c="${logo_col}" -v r="${RST}" '{ printf "%s%-*s%s\n", c, w, $0, r }' "${logo_tmp}") \
    <(awk -v c="${host_col}" -v r="${RST}" '{ print c $0 r }' "${host_tmp}") \
    | sed $'s/\t/    /'

  rm -f "${logo_tmp}" "${host_tmp}"
}

render_motd() {
  local os kernel cpu temp uptime load mem disk ips gw lastboot
  local up_total up_sec

  os="$(get_os)"
  kernel="$(get_kernel)"
  cpu="$(get_cpu_model)"
  temp="$(get_cpu_temp)"
  uptime="$(get_uptime)"
  lastboot="$(get_last_boot)"
  load="$(get_load)"
  mem="$(get_mem)"
  disk="$(get_disk_root)"
  ips="$(get_ip_addrs)"
  gw="$(get_gw || true)"

  read -r up_total up_sec < <(read_updates_cache)

  print_header

  hr
  kv "OS" "${WHT}${os}${RST}" "${BLU}"
  kv "Kernel" "${WHT}${kernel}${RST}" "${BLU}"
  kv "CPU" "${WHT}${cpu}${RST}" "${BLU}"

  local temp_col temp_int
  temp_col="${GRN}"
  if [[ "${temp}" =~ ^([0-9]+) ]]; then
    temp_int="${BASH_REMATCH[1]}"
    if (( temp_int >= 70 )); then
      temp_col="${RED}"
    elif (( temp_int >= 55 )); then
      temp_col="${YEL}"
    fi
  else
    temp_col="${DIM}"
  fi
  kv "CPU Temp" "${BLD}${temp_col}${temp}${RST}" "${BLU}"

  kv "Uptime" "${WHT}${uptime}${RST} ${DIM}(boot: ${lastboot})${RST}" "${BLU}"
  kv "Load" "${WHT}${load}${RST}" "${BLU}"
  kv "Memory" "${WHT}${mem}${RST}" "${BLU}"
  kv "Disk /" "${WHT}${disk}${RST}" "${BLU}"
  kv "IP" "${WHT}${ips}${RST}" "${BLU}"
  [[ -n "${gw:-}" ]] && kv "Gateway" "${WHT}${gw}${RST}" "${BLU}"

  hr

  if [[ "${up_total}" == "n/a" ]]; then
    kv "Updates" "${DIM}n/a (cache fehlt - install ausfuehren)${RST}" "${MAG}"
  elif [[ "${up_total}" =~ ^[0-9]+$ ]] && (( up_total == 0 )); then
    kv "Updates" "$(pill "0" "${GRN}") ${GRN}${BLD}System aktuell${RST}" "${MAG}"
  else
    local sec_txt
    sec_txt=""
    if [[ "${up_sec}" =~ ^[0-9]+$ ]] && (( up_sec > 0 )); then
      sec_txt=" $(pill "${up_sec} security" "${RED}")"
    fi
    kv "Updates" "$(pill "${up_total}" "${YEL}")${sec_txt} ${DIM}(aus Cache)${RST}" "${MAG}"
    printf "  %sRun:%s %ssudo apt update && sudo apt upgrade%s\n" "${DIM}" "${RST}" "${BLD}" "${RST}"
  fi

  hr
  printf "  %sCache refresh:%s systemctl start %s-updates.service\n\n" "${DIM}" "${RST}" "${SELF_NAME}"
}

install_motd() {
  if [[ $EUID -ne 0 ]]; then
    msg_err "Run as root: sudo $0 --install"
    exit 1
  fi

  if have apt-get; then
    msg_info "Installing optional deps: figlet util-linux"
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y figlet util-linux >/dev/null 2>&1 || true
  fi

  install -m 0755 "$0" "${MOTD_BIN}"

  mkdir -p /etc/update-motd.d
  cat >"${MOTD_HOOK}" <<HOOK
#!/usr/bin/env bash
exec ${MOTD_BIN}
HOOK
  chmod 0755 "${MOTD_HOOK}"

  cat >"${SYSTEMD_SERVICE}" <<SERVICE
[Unit]
Description=Refresh ${SELF_NAME} update cache
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=${MOTD_BIN} --refresh-cache
SERVICE

  cat >"${SYSTEMD_TIMER}" <<TIMER
[Unit]
Description=Run ${SELF_NAME} update cache refresh hourly

[Timer]
OnBootSec=2min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
TIMER

  systemctl daemon-reload
  systemctl enable --now "${SELF_NAME}-updates.timer" >/dev/null 2>&1 || true

  mkdir -p "${CACHE_DIR}" || true
  chmod 0755 "${CACHE_DIR}" || true
  "${MOTD_BIN}" --refresh-cache >/dev/null 2>&1 || true

  if [[ -f /etc/motd && ! -f /etc/motd.${SELF_NAME}.bak ]]; then
    cp -a /etc/motd "/etc/motd.${SELF_NAME}.bak"
    : >/etc/motd
  fi

  for f in /etc/update-motd.d/10-uname /etc/update-motd.d/50-motd-news /etc/update-motd.d/80-livepatch; do
    [[ -e "$f" ]] && chmod -x "$f" || true
  done

  msg_ok "Installed."
  msg_info "Hook : ${MOTD_HOOK}"
  msg_info "Bin  : ${MOTD_BIN}"
  msg_info "Timer: ${SELF_NAME}-updates.timer (hourly)"
  msg_warn "Test : ssh localhost (oder neue Shell)"
}

case "${1:-}" in
  --install)
    install_motd
    ;;
  --refresh-cache)
    write_updates_cache
    ;;
  *)
    render_motd
    ;;
esac
