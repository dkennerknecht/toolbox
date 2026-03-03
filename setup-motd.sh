#!/usr/bin/env bash
# motd-pi.sh — schnelle, farbige MOTD (keine apt-Calls beim Login)
# Install:
#   sudo ./motd-pi.sh --install
# Test:
#   ./motd-pi.sh

set -euo pipefail

SELF_NAME="motd-pi"
MOTD_BIN="/usr/local/sbin/${SELF_NAME}"
MOTD_HOOK="/etc/update-motd.d/99-${SELF_NAME}"

CACHE_DIR="/var/cache/${SELF_NAME}"
CACHE_FILE="${CACHE_DIR}/updates.cache"

SYSTEMD_SERVICE="/etc/systemd/system/${SELF_NAME}-updates.service"
SYSTEMD_TIMER="/etc/systemd/system/${SELF_NAME}-updates.timer"

# ---- colors ----
if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
  RST="$(tput sgr0)"
  BLD="$(tput bold)"
  DIM="$(tput dim)"
  RED="$(tput setaf 1)"
  GRN="$(tput setaf 2)"
  YEL="$(tput setaf 3)"
  BLU="$(tput setaf 4)"
  MAG="$(tput setaf 5)"
  CYN="$(tput setaf 6)"
  WHT="$(tput setaf 7)"
else
  RST="" BLD="" DIM="" RED="" GRN="" YEL="" BLU="" MAG="" CYN="" WHT=""
fi

have(){ command -v "$1" >/dev/null 2>&1; }

# ---- helpers ----
hr(){ printf "%s\n" "${DIM}────────────────────────────────────────────────────────────────────────────${RST}"; }
pill(){ # pill <text> <color>
  local t="$1" c="$2"
  printf "%s%s[%s]%s" "${BLD}${c}" "" "${t}" "${RST}"
}
kv(){ # kv <key> <value> <keyColor>
  local k="$1" v="$2" kc="${3:-$CYN}"
  printf "  %s%s%-14s%s %s\n" "${BLD}${kc}" "" "${k}:" "${RST}" "${v}"
}

# ---- detection ----
get_hostname(){ hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "host"; }

is_rpi(){
  # best-effort detection
  if [[ -r /proc/device-tree/model ]] && tr -d '\0' </proc/device-tree/model | grep -qi "raspberry pi"; then
    return 0
  fi
  if [[ -r /proc/cpuinfo ]] && grep -qi "Raspberry Pi" /proc/cpuinfo; then
    return 0
  fi
  return 1
}

is_intel(){
  local arch
  arch="$(uname -m 2>/dev/null || echo "")"
  [[ "$arch" == "x86_64" || "$arch" == "i386" || "$arch" == "i686" ]]
}

get_os(){
  # shellcheck disable=SC1091
  if [[ -r /etc/os-release ]]; then . /etc/os-release; echo "${PRETTY_NAME:-Linux}"; else echo "Linux"; fi
}
get_os_id(){
  # shellcheck disable=SC1091
  if [[ -r /etc/os-release ]]; then . /etc/os-release; echo "${ID:-unknown}"; else echo "unknown"; fi
}

# ---- stats ----
get_kernel(){ uname -r; }
get_load(){ awk '{printf "%s %s %s", $1,$2,$3}' /proc/loadavg 2>/dev/null || echo "n/a"; }
get_uptime(){ uptime -p 2>/dev/null || echo "n/a"; }
get_last_boot(){
  if have who; then who -b 2>/dev/null | awk '{print $3" "$4}' || echo "n/a"; else echo "n/a"; fi
}
get_cpu_model(){ awk -F: '/Model|model name/ {gsub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null || echo "n/a"; }
get_cpu_temp(){
  if have vcgencmd; then vcgencmd measure_temp 2>/dev/null | sed -E "s/^temp=([0-9.]+)'C$/\1°C/" || true; return 0; fi
  if [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then awk '{printf "%.1f°C", $1/1000}' /sys/class/thermal/thermal_zone0/temp; return 0; fi
  echo "n/a"
}
get_mem(){
  awk '
    /^MemTotal/ {t=$2}
    /^MemAvailable/ {a=$2}
    END {
      if (t>0) {
        used=(t-a)/1024; total=t/1024;
        printf "%.0fMiB / %.0fMiB", used, total
      } else print "n/a"
    }' /proc/meminfo 2>/dev/null
}
get_disk_root(){ df -h / 2>/dev/null | awk 'NR==2{printf "%s used of %s (%s)", $3,$2,$5}' || echo "n/a"; }
get_ip_addrs(){
  if have ip; then
    ip -o -4 addr show scope global 2>/dev/null | awk '{print $2": "$4}' | paste -sd ", " - || echo "n/a"
  else
    hostname -I 2>/dev/null | awk '{$1=$1;print}' || echo "n/a"
  fi
}
get_gw(){
  if have ip; then ip route show default 2>/dev/null | awk '{print $3}' | head -n1 || true; fi
}

# ---- updates cache ----
read_updates_cache(){
  # Format: <epoch> <total> <security>
  if [[ -r "${CACHE_FILE}" ]]; then
    awk 'NR==1{print $2" "$3}' "${CACHE_FILE}" 2>/dev/null
  else
    echo "n/a n/a"
  fi
}
write_updates_cache(){
  # Runs offline-ish: NO apt update, only counts based on current lists.
  # total: count "Inst" from simulation
  # security: best-effort grep on "security"
  local now total sec
  now="$(date +%s)"
  if have apt-get; then
    total="$(apt-get -s upgrade 2>/dev/null | awk '/^Inst /{c++} END{print c+0}')"
    sec="$(apt-get -s upgrade 2>/dev/null | awk 'BEGIN{s=0} /^Inst /{if (tolower($0) ~ /security/) s++} END{print s+0}')"
  else
    total="n/a"; sec="n/a"
  fi
  mkdir -p "${CACHE_DIR}" 2>/dev/null || true
  printf "%s %s %s\n" "${now}" "${total}" "${sec}" > "${CACHE_FILE}" 2>/dev/null || true
  chmod 0644 "${CACHE_FILE}" 2>/dev/null || true
}

# ---- ASCII: hostname + logo ----
print_hostname_ascii(){
  local h; h="$(get_hostname)"
  if have figlet; then
    printf "%s%s" "${BLD}${MAG}" ""
    figlet -f slant "${h}" 2>/dev/null || figlet "${h}" 2>/dev/null || printf "%s\n" "${h}"
    printf "%s" "${RST}"
  else
    printf "%s%s%s\n" "${BLD}${MAG}" "${h}" "${RST}"
  fi
}

print_logo(){
  local osid; osid="$(get_os_id)"

  # RPi: always berry
  if is_rpi; then
    printf "%s" "${BLD}${RED}"
    cat <<'EOF'
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
EOF
    printf "%s" "${RST}"
    return 0
  fi

  # Debian on Intel: Debian swirl (ASCII)
  if [[ "${osid}" == "debian" ]] && is_intel; then
    printf "%s" "${BLD}${RED}"
    cat <<'EOF'
       ____       _     _
      |  _ \  ___| |__ (_) __ _ _ __
      | | | |/ _ \ '_ \| |/ _` | '_ \
      | |_| |  __/ |_) | | (_| | | | |
      |____/ \___|_.__/|_|\__,_|_| |_|
EOF
    printf "%s" "${RST}"
    return 0
  fi

  # fallback generic penguin-ish
  printf "%s" "${BLD}${BLU}"
  cat <<'EOF'
   _     _             _
  | |   (_)           | |
  | |    _ _ __  _   _| |_
  | |   | | '_ \| | | | __|
  | |___| | | | | |_| | |_
  |_____|_|_| |_|\__,_|\__|
EOF
  printf "%s" "${RST}"
}

# ---- render ----
render_motd(){
  local os kernel cpu temp up load mem disk ip gw lastboot
  os="$(get_os)"
  kernel="$(get_kernel)"
  cpu="$(get_cpu_model)"
  temp="$(get_cpu_temp)"
  up="$(get_uptime)"
  lastboot="$(get_last_boot)"
  load="$(get_load)"
  mem="$(get_mem)"
  disk="$(get_disk_root)"
  ip="$(get_ip_addrs)"
  gw="$(get_gw || true)"

  local u_total u_sec
  read -r u_total u_sec < <(read_updates_cache)

  # header
  print_hostname_ascii
  print_logo

  hr

  kv "OS"      "${WHT}${os}${RST}"          "${BLU}"
  kv "Kernel"  "${WHT}${kernel}${RST}"      "${BLU}"
  kv "CPU"     "${WHT}${cpu}${RST}"         "${BLU}"

  # temp coloring
  local temp_col="${GRN}"
  if [[ "${temp}" =~ ^([0-9]+)\.?.*°C$ ]]; then
    t="${BASH_REMATCH[1]}"
    if (( t >= 70 )); then temp_col="${RED}"; elif (( t >= 55 )); then temp_col="${YEL}"; fi
  fi
  kv "CPU Temp" "${BLD}${temp_col}${temp}${RST}" "${BLU}"

  kv "Uptime"  "${WHT}${up}${RST} ${DIM}(boot: ${lastboot})${RST}" "${BLU}"
  kv "Load"    "${WHT}${load}${RST}"            "${BLU}"
  kv "Memory"  "${WHT}${mem}${RST}"             "${BLU}"
  kv "Disk /"  "${WHT}${disk}${RST}"            "${BLU}"
  kv "IP"      "${WHT}${ip}${RST}"              "${BLU}"
  [[ -n "${gw:-}" ]] && kv "Gateway" "${WHT}${gw}${RST}" "${BLU}"

  hr

  # updates line (login must be fast -> cache only)
  if [[ "${u_total}" == "n/a" ]]; then
    kv "Updates" "${DIM}n/a (Cache fehlt – Timer installiert?)${RST}" "${MAG}"
  else
    if [[ "${u_total}" =~ ^[0-9]+$ ]] && (( u_total == 0 )); then
      kv "Updates" "$(pill "0" "${GRN}") ${GRN}${BLD}System aktuell${RST}" "${MAG}"
    else
      local sec_txt=""
      if [[ "${u_sec}" =~ ^[0-9]+$ ]] && (( u_sec > 0 )); then
        sec_txt=" $(pill "${u_sec} security" "${RED}")"
      fi
      kv "Updates" "$(pill "${u_total}" "${YEL}")${sec_txt} ${DIM}(aus Cache)${RST}" "${MAG}"
      printf "  %s%s%s\n" "${DIM}" "Run: " "${RST}${BLD}sudo apt update && sudo apt upgrade${RST}"
    fi
  fi

  hr
  printf "  %s%s%s\n" "${DIM}" "Cache refresh:" "${RST} systemctl start ${SELF_NAME}-updates.service"
  printf "\n"
}

# ---- install ----
install_motd(){
  if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo $0 --install" >&2
    exit 1
  fi

  # optional deps (figlet + flock)
  if have apt-get; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y figlet util-linux >/dev/null 2>&1 || true
  fi

  install -m 0755 "$0" "${MOTD_BIN}"
  mkdir -p /etc/update-motd.d
  cat > "${MOTD_HOOK}" <<EOF
#!/usr/bin/env bash
exec ${MOTD_BIN}
EOF
  chmod 0755 "${MOTD_HOOK}"

  # systemd service + timer to refresh update cache (NOT during login)
  cat > "${SYSTEMD_SERVICE}" <<EOF
[Unit]
Description=Refresh ${SELF_NAME} update cache
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=${MOTD_BIN} --refresh-cache
EOF

  cat > "${SYSTEMD_TIMER}" <<EOF
[Unit]
Description=Run ${SELF_NAME} update cache refresh hourly

[Timer]
OnBootSec=2min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${SELF_NAME}-updates.timer" >/dev/null 2>&1 || true

  # create initial cache immediately
  "${MOTD_BIN}" --refresh-cache >/dev/null 2>&1 || true

  # OPTIONAL but strongly recommended: disable the default /etc/motd text spam
  # This is what prints the long Debian warranty text.
  if [[ -f /etc/motd && ! -f /etc/motd.${SELF_NAME}.bak ]]; then
    cp -a /etc/motd "/etc/motd.${SELF_NAME}.bak"
    : > /etc/motd
  fi

  # disable other noisy dynamic parts if present
  for f in /etc/update-motd.d/10-uname /etc/update-motd.d/50-motd-news /etc/update-motd.d/80-livepatch; do
    [[ -e "$f" ]] && chmod -x "$f" || true
  done

  echo "OK installed:"
  echo "  Hook : ${MOTD_HOOK}"
  echo "  Bin  : ${MOTD_BIN}"
  echo "  Timer: ${SELF_NAME}-updates.timer (hourly)"
  echo "  Note : /etc/motd was emptied (backup: /etc/motd.${SELF_NAME}.bak)"
}

# ---- main ----
case "${1:-}" in
  --install) install_motd ;;
  --refresh-cache) write_updates_cache ;;
  *) render_motd ;;
esac