



Raspberry pi MOTD
Bau mir ein script  mit welchem ich eine anschauliche MOTD mit den aktuellen systemwerten stats sowie fällige updates und einem passenden Asci Hostnamen
gerne Farbig
mit einem jeweiligen os symobol in asci auch farbig


Nachgedacht für 16s
#!/usr/bin/env bash
# motd-pi.sh — farbige MOTD mit Stats + Updates + ASCII Hostname + OS-Logo
# Usage:
#   sudo ./motd-pi.sh --install
#   ./motd-pi.sh            # rendert MOTD auf stdout (für Tests)
set -euo pipefail

SELF_NAME="motd-pi"
MOTD_BIN="/usr/local/sbin/${SELF_NAME}"
MOTD_HOOK="/etc/update-motd.d/99-${SELF_NAME}"
CACHE_DIR="/var/cache/${SELF_NAME}"
CACHE_FILE="${CACHE_DIR}/updates.cache"
CACHE_TTL_SECONDS=3600

# ---------- colors ----------
if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
  C_RESET="$(tput sgr0)"
  C_BOLD="$(tput bold)"
  C_DIM="$(tput dim)"
  C_RED="$(tput setaf 1)"
  C_GRN="$(tput setaf 2)"
  C_YEL="$(tput setaf 3)"
  C_BLU="$(tput setaf 4)"
  C_MAG="$(tput setaf 5)"
  C_CYN="$(tput setaf 6)"
  C_WHT="$(tput setaf 7)"
else
  C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GRN="" C_YEL="" C_BLU="" C_MAG="" C_CYN="" C_WHT=""
fi

hr() { printf "%s\n" "${C_DIM}────────────────────────────────────────────────────────────────────────────${C_RESET}"; }
kv() { # key value
  local k="$1" v="$2" col="${3:-$C_CYN}"
  printf "  %s%-16s%s %s\n" "${col}" "${k}:" "${C_RESET}" "${v}"
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---------- system helpers ----------
get_hostname() { hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "raspberrypi"; }

get_os_id() {
  # shellcheck disable=SC1091
  if [[ -r /etc/os-release ]]; then . /etc/os-release; echo "${ID:-unknown}"; else echo "unknown"; fi
}
get_os_pretty() {
  # shellcheck disable=SC1091
  if [[ -r /etc/os-release ]]; then . /etc/os-release; echo "${PRETTY_NAME:-Linux}"; else echo "Linux"; fi
}
get_kernel() { uname -r; }
get_uptime_pretty() { uptime -p 2>/dev/null || echo "n/a"; }
get_load() { awk '{printf "%s %s %s", $1,$2,$3}' /proc/loadavg 2>/dev/null || echo "n/a"; }

get_cpu_temp() {
  if have vcgencmd; then
    vcgencmd measure_temp 2>/dev/null | sed -E "s/^temp=([0-9.]+)'C$/\1°C/" || true
    return 0
  fi
  if [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
    awk '{printf "%.1f°C", $1/1000}' /sys/class/thermal/thermal_zone0/temp
    return 0
  fi
  echo "n/a"
}

get_cpu_model() {
  awk -F: '/Model|model name/ {gsub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null || echo "n/a"
}

get_mem() {
  # Mem: used/total in MiB
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

get_disk_root() {
  df -h / 2>/dev/null | awk 'NR==2{printf "%s used of %s (%s)", $3,$2,$5}' || echo "n/a"
}

get_ip_addrs() {
  if have ip; then
    ip -o -4 addr show scope global 2>/dev/null | awk '{print $2": "$4}' | paste -sd ", " - || echo "n/a"
  else
    hostname -I 2>/dev/null | awk '{$1=$1;print}' || echo "n/a"
  fi
}

get_default_route() {
  if have ip; then
    ip route show default 2>/dev/null | awk '{print $3}' | head -n1 || true
  fi
}

get_last_boot() {
  if have who; then
    who -b 2>/dev/null | awk '{print $3" "$4}' || echo "n/a"
  else
    echo "n/a"
  fi
}

# ---------- update counting (cached) ----------
count_updates_uncached() {
  # returns: "<total> <security_or_na>"
  local total=0 sec="n/a"

  if have apt-get; then
    # no "apt-get update" here; that would slow logins. This counts against current lists.
    total="$(apt-get -s upgrade 2>/dev/null | awk '/^Inst /{c++} END{print c+0}')"

    # security count: only if origin info is present in simulation output (often it isn't reliably).
    # best-effort: count packages where the line mentions "Debian-Security" or "security" or "raspi" security pockets.
    sec="$(apt-get -s upgrade 2>/dev/null | awk '
      /^Inst /{
        line=$0
        if (tolower(line) ~ /security/) s++
      }
      END{print (s+0)}')"
  fi

  printf "%s %s\n" "${total}" "${sec}"
}

read_updates_cached() {
  mkdir -p "${CACHE_DIR}" 2>/dev/null || true

  local now ts total sec
  now="$(date +%s)"
  if [[ -r "${CACHE_FILE}" ]]; then
    ts="$(awk 'NR==1{print $1}' "${CACHE_FILE}" 2>/dev/null || echo 0)"
    if [[ "${ts}" =~ ^[0-9]+$ ]] && (( now - ts < CACHE_TTL_SECONDS )); then
      total="$(awk 'NR==1{print $2}' "${CACHE_FILE}" 2>/dev/null || echo 0)"
      sec="$(awk 'NR==1{print $3}' "${CACHE_FILE}" 2>/dev/null || echo n/a)"
      printf "%s %s\n" "${total}" "${sec}"
      return 0
    fi
  fi

  # lock to avoid multiple logins hammering apt simulation
  local lock="${CACHE_FILE}.lock"
  if have flock; then
    flock -w 2 "${lock}" bash -c '
      set -euo pipefail
      now="$(date +%s)"
      if [[ -r "'"${CACHE_FILE}"'" ]]; then
        ts="$(awk "NR==1{print \$1}" "'"${CACHE_FILE}"'" 2>/dev/null || echo 0)"
        if [[ "$ts" =~ ^[0-9]+$ ]] && (( now - ts < '"${CACHE_TTL_SECONDS}"' )); then
          exit 0
        fi
      fi
      read -r total sec < <("'"${MOTD_BIN}"'" --_count_updates_uncached)
      printf "%s %s %s\n" "$now" "$total" "$sec" > "'"${CACHE_FILE}"'"
    ' || true
  else
    read -r total sec < <(count_updates_uncached)
    printf "%s %s %s\n" "${now}" "${total}" "${sec}" > "${CACHE_FILE}" 2>/dev/null || true
  fi

  total="$(awk 'NR==1{print $2}' "${CACHE_FILE}" 2>/dev/null || echo 0)"
  sec="$(awk 'NR==1{print $3}' "${CACHE_FILE}" 2>/dev/null || echo n/a)"
  printf "%s %s\n" "${total}" "${sec}"
}

# ---------- ASCII art ----------
print_hostname_ascii() {
  local h; h="$(get_hostname)"

  if have figlet; then
    printf "%s" "${C_BOLD}${C_MAG}"
    figlet -f slant "${h}" 2>/dev/null || figlet "${h}" 2>/dev/null || printf "%s\n" "${h}"
    printf "%s" "${C_RESET}"
    return 0
  fi

  # fallback (simple box)
  printf "%s%s+-%s-+%s\n" "${C_BOLD}${C_MAG}" "${C_DIM}" "$(printf '%*s' "${#h}" | tr ' ' '-')" "${C_RESET}"
  printf "%s%s| %s |%s\n" "${C_BOLD}${C_MAG}" "${C_DIM}" "${h}" "${C_RESET}"
  printf "%s%s+-%s-+%s\n" "${C_BOLD}${C_MAG}" "${C_DIM}" "$(printf '%*s' "${#h}" | tr ' ' '-')" "${C_RESET}"
}

print_os_logo() {
  local id; id="$(get_os_id)"

  case "${id}" in
    raspbian|debian)
      printf "%s" "${C_RED}${C_BOLD}"
      cat <<'EOF'
       __  __
      / / / /__  ____ ___  ____  ____ _
     / /_/ / _ \/ __ `__ \/ __ \/ __ `/
    / __  /  __/ / / / / / /_/ / /_/ /
   /_/ /_/\___/_/ /_/ /_/ .___/\__,_/
                        /_/
EOF
      printf "%s" "${C_RESET}"
      ;;
    ubuntu)
      printf "%s" "${C_YEL}${C_BOLD}"
      cat <<'EOF'
        _     _ _
       | |   (_) |
  _   _| |__  _| |_ _   _
 | | | | '_ \| | __| | | |
 | |_| | |_) | | |_| |_| |
  \__,_|_.__/|_|\__|\__,_|
EOF
      printf "%s" "${C_RESET}"
      ;;
    arch)
      printf "%s" "${C_CYN}${C_BOLD}"
      cat <<'EOF'
       /\
      /  \   _ __ ___| |__
     / /\ \ | '__/ __| '_ \
    / ____ \| | | (__| | | |
   /_/    \_\_|  \___|_| |_|
EOF
      printf "%s" "${C_RESET}"
      ;;
    *)
      printf "%s" "${C_BLU}${C_BOLD}"
      cat <<'EOF'
   _     _
  | |   (_)
  | |    _ _ __  _   ___  __
  | |   | | '_ \| | | \ \/ /
  | |___| | | | | |_| |>  <
  |_____|_|_| |_|\__,_/_/\_\
EOF
      printf "%s" "${C_RESET}"
      ;;
  esac
}

# ---------- render ----------
render_motd() {
  local os pretty kernel uptime load temp mem disk ips gw lastboot
  pretty="$(get_os_pretty)"
  kernel="$(get_kernel)"
  uptime="$(get_uptime_pretty)"
  load="$(get_load)"
  temp="$(get_cpu_temp)"
  mem="$(get_mem)"
  disk="$(get_disk_root)"
  ips="$(get_ip_addrs)"
  gw="$(get_default_route || true)"
  lastboot="$(get_last_boot)"

  local up_total up_sec
  read -r up_total up_sec < <(read_updates_cached)

  clear 2>/dev/null || true

  # header: hostname ascii + os logo side-by-side (simple: print sequential)
  print_hostname_ascii
  print_os_logo

  hr
  kv "OS" "${pretty}" "${C_BLU}"
  kv "Kernel" "${kernel}" "${C_BLU}"
  kv "CPU" "$(get_cpu_model)" "${C_BLU}"
  kv "CPU Temp" "${temp}" "${C_BLU}"
  kv "Uptime" "${uptime} (boot: ${lastboot})" "${C_BLU}"
  kv "Load" "${load}" "${C_BLU}"
  kv "Memory" "${mem}" "${C_BLU}"
  kv "Disk /" "${disk}" "${C_BLU}"
  kv "IP" "${ips}" "${C_BLU}"
  [[ -n "${gw:-}" ]] && kv "Gateway" "${gw}" "${C_BLU}"

  hr
  # updates line
  if [[ "${up_total}" =~ ^[0-9]+$ ]]; then
    if (( up_total == 0 )); then
      kv "Updates" "${C_GRN}${C_BOLD}0${C_RESET} (System aktuell)"
    else
      # security is best-effort; show if >0
      if [[ "${up_sec}" =~ ^[0-9]+$ ]] && (( up_sec > 0 )); then
        kv "Updates" "${C_YEL}${C_BOLD}${up_total}${C_RESET} (${C_RED}${C_BOLD}${up_sec} security${C_RESET}, cache ${CACHE_TTL_SECONDS}s)"
      else
        kv "Updates" "${C_YEL}${C_BOLD}${up_total}${C_RESET} (cache ${CACHE_TTL_SECONDS}s)"
      fi
      printf "  %sRun:%s %ssudo apt update && sudo apt upgrade%s\n" "${C_DIM}" "${C_RESET}" "${C_BOLD}" "${C_RESET}"
    fi
  else
    kv "Updates" "n/a"
  fi

  hr
  printf "%s\n" "${C_DIM}Tip:${C_RESET} Cache löschen: sudo rm -f ${CACHE_FILE}  (falls du sofort neu zählen willst)"
  printf "%s\n\n" "${C_RESET}"
}

# ---------- install ----------
install_motd() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo $0 --install" >&2
    exit 1
  fi

  # deps (optional)
  if have apt-get; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y figlet util-linux >/dev/null 2>&1 || true  # util-linux provides flock
  fi

  install -m 0755 "$0" "${MOTD_BIN}"

  # enable update-motd if present; Debian/RPi: /etc/update-motd.d is standard.
  if [[ ! -d /etc/update-motd.d ]]; then
    mkdir -p /etc/update-motd.d
  fi

  # deactivate common noisy motd parts (optional, but usually desired)
  for f in /etc/update-motd.d/10-uname /etc/update-motd.d/50-motd-news /etc/update-motd.d/80-livepatch; do
    [[ -e "$f" ]] && chmod -x "$f" || true
  done

  cat > "${MOTD_HOOK}" <<EOF
#!/usr/bin/env bash
exec ${MOTD_BIN}
EOF
  chmod 0755 "${MOTD_HOOK}"

  mkdir -p "${CACHE_DIR}" || true
  chmod 0755 "${CACHE_DIR}" || true

  echo "OK: Installed."
  echo "  Hook: ${MOTD_HOOK}"
  echo "  Bin : ${MOTD_BIN}"
  echo "Test: ssh localhost  (oder neue Shell öffnen)"
}

# ---------- main ----------
case "${1:-}" in
  --install) install_motd ;;
  --_count_updates_uncached) count_updates_uncached ;;
  *) render_motd ;;
esac
Installation (idempotent):

curl -fsSL -o motd-pi.sh https://example.invalid/motd-pi.sh  # (oder Datei lokal speichern)
chmod +x motd-pi.sh
sudo ./motd-pi.sh --install
Wenn du willst, bau ich dir noch Service-Status (docker, nginx, influx, …) und Warnungen rein (z.B. Root-FS > 85%, Temp > 70°C, Swap in use).


    ____                   __                         ____  _       ______
   / __ \____ __________  / /_  ___  ____________  __/ __ \(_)     / ____/
  / /_/ / __ / ___/ __ \/ __ \/ _ \/ ___/ ___/ / / / /_/ / /_____/___ \
 / _, _/ /_/ (__  ) /_/ / /_/ /  __/ /  / /  / /_/ / ____/ /_____/___/ /
/_/ |_|\__,_/____/ .___/_.___/\___/_/  /_/   \__, /_/   /_/     /_____/
                /_/                         /____/
       __  __
      / / / /__  ____ ___  ____  ____ _
     / /_/ / _ \/ __ __ \/ __ \/ __ /
    / __  /  __/ / / / / / /_/ / /_/ /
   /_/ /_/\___/_/ /_/ /_/ .___/\__,_/
                        /_/
────────────────────────────────────────────────────────────────────────────
  OS:              Debian GNU/Linux 13 (trixie)
  Kernel:          6.12.47+rpt-rpi-2712
  CPU:             Raspberry Pi 5 Model B Rev 1.1
  CPU Temp:        29.0°C
  Uptime:          up 1 hour, 42 minutes (boot: Dec 4)
  Load:            0.11 0.03 0.01
  Memory:          396MiB / 8063MiB
  Disk /:          4.1G used of 117G (4%)
  IP:              eth0: 192.168.1.107/24
  Gateway:         192.168.1.1
────────────────────────────────────────────────────────────────────────────
  Updates:         47 (4 security, cache 3600s)
  Run: sudo apt update && sudo apt upgrade
────────────────────────────────────────────────────────────────────────────
Tip: Cache löschen: sudo rm -f /var/cache/motd-pi/updates.cache  (falls du sofort neu zählen willst)



The programs included with the Debian GNU/Linux system are free software;
the exact distribution terms for each program are described in the
individual files in /usr/share/doc/*/copyright.

Debian GNU/Linux comes with ABSOLUTELY NO WARRANTY, to the extent
permitted by applicable law.
Last login: Tue Mar  3 14:55:02 2026 from 192.168.1.186


#########
Es dauert zu lange die motd zu generrieren
ich wünsche mir mehr farbe damit es leichter zu lesen und erkennen ist.
WEnn es sich um ein RPi handelt will ich das Logo mit der beere
wenn es sich um ein debian auf einem intel handelt will ich das debian logo


Nachgedacht für 13s
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


