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
NET_CACHE_FILE="${CACHE_DIR}/network.cache"

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

get_mem_template() {
  awk '
    /^MemFree:/ {f=$2}
    /^MemTotal:/ {t=$2}
    END {
      if (t>0) {
        printf "%s kB (Free) / %s kB (Total)", f+0, t+0
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

get_lan_ip() {
  local lan
  lan=""
  if have ip; then
    lan="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
  fi
  if [[ -z "${lan}" ]]; then
    lan="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  [[ -n "${lan}" ]] || lan="n/a"
  printf "%s\n" "${lan}"
}

get_wan_ip_live() {
  local wan
  wan="n/a"

  if have curl; then
    wan="$(curl -4fsS --max-time 2 https://api.ipify.org 2>/dev/null || echo "n/a")"
  elif have wget; then
    wan="$(wget -4qO- --timeout=2 https://api.ipify.org 2>/dev/null || echo "n/a")"
  fi

  if [[ ! "${wan}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    wan="n/a"
  fi
  printf "%s\n" "${wan}"
}

get_uptime_template() {
  local total d h m s
  if [[ -r /proc/uptime ]]; then
    total="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "")"
    if [[ "${total}" =~ ^[0-9]+$ ]]; then
      d=$(( total / 86400 ))
      h=$(( (total % 86400) / 3600 ))
      m=$(( (total % 3600) / 60 ))
      s=$(( total % 60 ))
      printf "%s days, %02dh%02dm%02ds\n" "${d}" "${h}" "${m}" "${s}"
      return 0
    fi
  fi
  get_uptime
}

get_load_template() {
  awk '{printf "%s, %s, %s (1, 5, 15 min)", $1, $2, $3}' /proc/loadavg 2>/dev/null || echo "n/a"
}

get_process_count() {
  local count
  if ! have ps; then
    echo "n/a"
    return 0
  fi

  count="$(ps -e -o pid= 2>/dev/null | awk 'END{print NR+0}' 2>/dev/null || true)"
  if [[ "${count}" =~ ^[0-9]+$ ]]; then
    printf "%s\n" "${count}"
  else
    echo "n/a"
  fi
}

dots_label() {
  local label="$1"
  local width=19
  local dots
  dots=$(( width - ${#label} ))
  if (( dots < 2 )); then
    dots=2
  fi
  printf "%s" "${label}"
  printf "%*s" "${dots}" "" | tr ' ' '.'
}

template_row() {
  local label="$1"
  local value="$2"
  printf "%s%s%s: %s%s%s\n" "${CYN}" "$(dots_label "${label}")" "${RST}" "${WHT}" "${value}" "${RST}"
}

read_updates_cache() {
  if [[ -r "${CACHE_FILE}" ]]; then
    awk 'NR==1{print $2" "$3}' "${CACHE_FILE}" 2>/dev/null
  else
    echo "n/a n/a"
  fi
}

read_network_cache() {
  if [[ -r "${NET_CACHE_FILE}" ]]; then
    awk -F'|' 'NR==1{print $2" "$3}' "${NET_CACHE_FILE}" 2>/dev/null
  else
    echo "n/a n/a"
  fi
}

write_network_cache() {
  local now lan wan

  now="$(date +%s)"
  lan="$(get_lan_ip)"
  wan="$(get_wan_ip_live)"

  [[ -n "${lan}" ]] || lan="n/a"
  [[ -n "${wan}" ]] || wan="n/a"

  if mkdir -p "${CACHE_DIR}" 2>/dev/null; then
    printf "%s|%s|%s\n" "${now}" "${lan}" "${wan}" >"${NET_CACHE_FILE}" 2>/dev/null || true
    chmod 0644 "${NET_CACHE_FILE}" 2>/dev/null || true
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

  if mkdir -p "${CACHE_DIR}" 2>/dev/null; then
    printf "%s %s %s\n" "${now}" "${total}" "${sec}" >"${CACHE_FILE}" 2>/dev/null || true
    chmod 0644 "${CACHE_FILE}" 2>/dev/null || true
  fi
  write_network_cache
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

repeat_char() {
  local char="$1"
  local count="$2"
  local out
  if (( count <= 0 )); then
    printf ""
    return 0
  fi
  printf -v out "%*s" "${count}" ""
  out="${out// /${char}}"
  printf "%s" "${out}"
}

fit_cell() {
  local text="$1"
  local width="$2"
  if (( ${#text} > width )); then
    text="${text:0:width-1}~"
  fi
  printf "%-*s" "${width}" "${text}"
}

box_top_2col() {
  local w1="$1" w2="$2"
  printf "%s┏%s┯%s┓%s\n" "${BLD}${WHT}" "$(repeat_char "━" "${w1}")" "$(repeat_char "━" "${w2}")" "${RST}"
}

box_sep_2col() {
  local w1="$1" w2="$2"
  printf "%s┣%s┿%s┫%s\n" "${BLD}${WHT}" "$(repeat_char "━" "${w1}")" "$(repeat_char "━" "${w2}")" "${RST}"
}

box_bottom_2col() {
  local w1="$1" w2="$2"
  printf "%s┗%s┷%s┛%s\n" "${BLD}${WHT}" "$(repeat_char "━" "${w1}")" "$(repeat_char "━" "${w2}")" "${RST}"
}

box_row_2col() {
  local w1="$1" w2="$2" c1="$3" c2="$4"
  local s1="${5:-${BLD}${WHT}}" s2="${6:-${BLD}${WHT}}"
  local p1 p2 bc
  p1="$(fit_cell "${c1}" "${w1}")"
  p2="$(fit_cell "${c2}" "${w2}")"
  bc="${BLD}${WHT}"
  printf "%s┃%s%s%s%s│%s%s%s%s┃%s\n" "${bc}" "${s1}" "${p1}" "${RST}" "${bc}" "${s2}" "${p2}" "${RST}" "${bc}" "${RST}"
}

box_top_full() { local w="$1"; printf "%s┏%s┓%s\n" "${BLD}${WHT}" "$(repeat_char "━" "${w}")" "${RST}"; }
box_sep_full() { local w="$1"; printf "%s┣%s┫%s\n" "${BLD}${WHT}" "$(repeat_char "━" "${w}")" "${RST}"; }
box_bottom_full() { local w="$1"; printf "%s┗%s┛%s\n" "${BLD}${WHT}" "$(repeat_char "━" "${w}")" "${RST}"; }
box_row_full() {
  local w="$1" c="$2" s="${3:-${BLD}${WHT}}" p bc
  p="$(fit_cell "${c}" "${w}")"
  bc="${BLD}${WHT}"
  printf "%s┃%s%s%s%s┃%s\n" "${bc}" "${s}" "${p}" "${RST}" "${bc}" "${RST}"
}

bar_from_percent() {
  local pct="$1" width="$2" full_char="${3:-|}" empty_char="${4:--}"
  local full_count empty_count
  if [[ ! "${pct}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    pct="0"
  fi
  full_count="$(awk -v p="${pct}" -v w="${width}" 'BEGIN{n=int((p*w)/100+0.5); if(n<0)n=0; if(n>w)n=w; print n}')"
  empty_count=$(( width - full_count ))
  printf "%s%s" "$(repeat_char "${full_char}" "${full_count}")" "$(repeat_char "${empty_char}" "${empty_count}")"
}

get_device_name() {
  if [[ -r /proc/device-tree/model ]]; then
    tr -d '\0' </proc/device-tree/model
    return 0
  fi
  if [[ -r /sys/devices/virtual/dmi/id/product_name ]]; then
    sed -n '1p' /sys/devices/virtual/dmi/id/product_name 2>/dev/null
    return 0
  fi
  echo "$(uname -m 2>/dev/null || echo "n/a")"
}

get_vcpu_count() {
  if have nproc; then
    nproc 2>/dev/null || echo "n/a"
    return 0
  fi
  if [[ -r /proc/cpuinfo ]]; then
    awk -F: '/^processor/{c++} END{print c+0}' /proc/cpuinfo 2>/dev/null
    return 0
  fi
  echo "n/a"
}

get_process_split() {
  if ! have ps; then
    echo "n/a"
    return 0
  fi
  ps -eo user= 2>/dev/null | awk '
    {u[$1]++; t++}
    END{
      root=u["root"]+0
      user=t-root
      if (t>0) {
        printf "%d (root) %d (user) %d (total)", root, user, t
      } else {
        print "n/a"
      }
    }'
}

get_mem_free_total_mb() {
  awk '
    /^MemFree:/ {f=$2}
    /^MemTotal:/ {t=$2}
    END{
      if (t>0) printf "%d MB (Free) / %d MB (Total)", int(f/1024), int(t/1024)
      else print "n/a"
    }' /proc/meminfo 2>/dev/null || echo "n/a"
}

get_mem_used_total_mb() {
  awk '
    /^MemTotal:/ {t=$2}
    /^MemAvailable:/ {a=$2}
    END{
      if (t>0) {
        used=t-a
        printf "%d %d", int(used/1024), int(t/1024)
      } else print "0 0"
    }' /proc/meminfo 2>/dev/null || echo "0 0"
}

get_swap_used_total_mb() {
  awk '
    /^SwapTotal:/ {t=$2}
    /^SwapFree:/ {f=$2}
    END{
      if (t>0) {
        used=t-f
        printf "%d %d", int(used/1024), int(t/1024)
      } else print "0 0"
    }' /proc/meminfo 2>/dev/null || echo "0 0"
}

get_disk_entries() {
  df -hP 2>/dev/null | awk '
    NR>1 && $1 !~ /^(tmpfs|devtmpfs)$/ {
      gsub(/%/,"",$5)
      printf "%s|%s|%s\n", $6, $5, $2
    }' | head -n 5 || true
}

get_cpu_usage_samples() {
  if [[ ! -r /proc/stat ]]; then
    echo "1 0.0"
    return 0
  fi

  local s1 s2
  s1="$(mktemp)"
  s2="$(mktemp)"
  awk '/^cpu[0-9]+ /{tot=0; for(i=2;i<=NF;i++) tot+=$i; idle=$5+$6; print $1,tot,idle}' /proc/stat >"${s1}"
  sleep 0.12
  awk '/^cpu[0-9]+ /{tot=0; for(i=2;i<=NF;i++) tot+=$i; idle=$5+$6; print $1,tot,idle}' /proc/stat >"${s2}"
  awk '
    FNR==NR {t[$1]=$2; i[$1]=$3; next}
    ($1 in t) {
      dt=$2-t[$1]
      di=$3-i[$1]
      u=(dt>0)?((dt-di)*100/dt):0
      cpu=$1
      sub(/^cpu/,"",cpu)
      printf "%d %.1f\n", cpu+1, u
    }' "${s1}" "${s2}" | head -n 4
  rm -f "${s1}" "${s2}"
}

get_lan_lines() {
  if have ip; then
    ip -o -4 addr show scope global 2>/dev/null | awk '{print $2": "$4}' | head -n 3 || true
    return 0
  fi
  echo "n/a"
}

service_prio() {
  case "$1" in
    failed) echo 0 ;;
    activating|deactivating) echo 1 ;;
    active) echo 2 ;;
    *) echo 9 ;;
  esac
}

get_service_entries() {
  local only_running=0
  local tmpfile unitsfile unit act disp p

  if [[ "${1:-}" == "--only-running" ]]; then
    only_running=1
  fi

  if have systemctl; then
    tmpfile="$(mktemp)"
    unitsfile="$(mktemp)"

    if ! systemctl list-unit-files --type=service --state=enabled --no-pager --no-legend >"${unitsfile}" 2>/dev/null; then
      rm -f "${tmpfile}" "${unitsfile}"
      echo "n/a|n/a"
      return 0
    fi

    while IFS= read -r unit; do
      [[ -n "${unit}" ]] || continue
      act="$(systemctl is-active "${unit}" 2>/dev/null || true)"

      [[ "${act}" == "inactive" || "${act}" == "dead" ]] && continue

      disp="${act}"
      [[ "${act}" == "active" ]] && disp="running"
      [[ ${only_running} -eq 1 && "${disp}" != "running" ]] && continue

      p="$(service_prio "${act}")"
      printf "%s|%s|%s\n" "${p}" "${unit}" "${disp}" >>"${tmpfile}"
    done < <(awk '{print $1}' "${unitsfile}" 2>/dev/null)

    if [[ -s "${tmpfile}" ]]; then
      sort -t '|' -k1,1n -k2,2 "${tmpfile}" | awk -F'|' '{print $2 "|" $3}' || true
    else
      echo "n/a|n/a"
    fi

    rm -f "${tmpfile}" "${unitsfile}"
    return 0
  fi

  if have service; then
    service --status-all 2>/dev/null | awk '
      {
        st=$2
        gsub(/\[/,"",st)
        gsub(/\]/,"",st)
        unit=$4
        if (st=="+") status="running"; else if (st=="-") status="stopped"; else status="unknown"
        if (unit != "") print unit ".service|" status
      }' || true
    return 0
  fi
  echo "n/a|n/a"
}

print_heading_figlet() {
  local host
  host="$(get_hostname)"
  if have figlet; then
    printf "%s%s" "${BLD}${GRN}" ""
    figlet -w 200 "${host}" 2>/dev/null || figlet -w 200 -f slant "${host}" 2>/dev/null || printf "%s\n" "${host}"
    printf "%s" "${RST}"
  else
    printf "%s%s%s\n" "${BLD}${GRN}" "${host}" "${RST}"
  fi
}

build_general_panel() {
  local c1=11 c2=36
  local now device distro kernel uptime load mem proc

  now="$(LC_TIME=C date '+%d %B %Y, %I:%M:%S %p' 2>/dev/null || date)"
  device="$(get_device_name)"
  distro="$(get_os)"
  kernel="Linux $(get_kernel)"
  uptime="$(get_uptime_template)"
  load="$(get_load_template)"
  mem="$(get_mem_free_total_mb)"
  proc="$(get_process_split)"

  box_top_2col "${c1}" "${c2}"
  box_row_2col "${c1}" "${c2}" " General:" "${now}" "${BLD}${YEL}" "${BLD}${CYN}"
  box_sep_2col "${c1}" "${c2}"
  box_row_2col "${c1}" "${c2}" " Device" "${device}" "${BLD}${CYN}" "${WHT}"
  box_row_2col "${c1}" "${c2}" " Distro" "${distro}" "${BLD}${CYN}" "${WHT}"
  box_row_2col "${c1}" "${c2}" " Kernel" "${kernel}" "${BLD}${CYN}" "${WHT}"
  box_row_2col "${c1}" "${c2}" " Uptime" "${uptime}" "${BLD}${CYN}" "${WHT}"
  box_row_2col "${c1}" "${c2}" "" ""
  box_row_2col "${c1}" "${c2}" " Load" "${load}" "${BLD}${CYN}" "${WHT}"
  box_row_2col "${c1}" "${c2}" " Memory" "${mem}" "${BLD}${CYN}" "${WHT}"
  box_row_2col "${c1}" "${c2}" " Processes" "${proc}" "${BLD}${CYN}" "${WHT}"
  box_bottom_2col "${c1}" "${c2}"
}

build_cpu_panel() {
  local c1=6 c2=41 fw=48
  local model vcpu load model_line2 usage_tmp

  model="$(get_cpu_model)"
  vcpu="$(get_vcpu_count)"
  load="$(get_load_template)"
  model_line2="(${vcpu} vCPU)"
  usage_tmp="$(mktemp)"
  get_cpu_usage_samples >"${usage_tmp}"

  box_top_2col "${c1}" "${c2}"
  box_row_2col "${c1}" "${c2}" " CPU:" "${model}" "${BLD}${YEL}" "${WHT}"
  box_row_2col "${c1}" "${c2}" "" "${model_line2}" "${WHT}" "${WHT}"
  box_sep_full "${fw}"
  box_row_full "${fw}" " Load ${load}" "${BLD}${CYN}"
  box_sep_full "${fw}"

  local idx pct bar
  while read -r idx pct; do
    [[ -n "${idx:-}" ]] || continue
    bar="$(bar_from_percent "${pct}" 30 "|" "-")"
    box_row_full "${fw}" " CPU ${idx} [${bar}] $(printf '%5.1f' "${pct}")%" "${GRN}"
  done < "${usage_tmp}"

  # keep panel height stable
  local lines
  lines="$(wc -l < "${usage_tmp}" | awk '{print $1}')"
  while (( lines < 4 )); do
    box_row_full "${fw}" "" "${WHT}"
    lines=$(( lines + 1 ))
  done

  box_row_full "${fw}" "" "${WHT}"
  box_bottom_full "${fw}"
  rm -f "${usage_tmp}"
}

build_disk_panel() {
  local fw=48
  local count=0 body_rows=0 mount pct size bar

  box_top_full "${fw}"
  box_row_full "${fw}" " Disk usage:" "${BLD}${YEL}"
  box_sep_full "${fw}"

  while IFS='|' read -r mount pct size; do
    [[ -n "${mount:-}" ]] || continue
    bar="$(bar_from_percent "${pct}" 42 "=" "-")"
    box_row_full "${fw}" " ${mount} ${pct}% used out of ${size}" "${WHT}"
    box_row_full "${fw}" " [${bar}]" "${BLD}${YEL}"
    count=$(( count + 1 ))
    body_rows=$(( body_rows + 2 ))
  done < <(get_disk_entries)

  while (( body_rows < 12 )); do
    box_row_full "${fw}" "" "${WHT}"
    body_rows=$(( body_rows + 1 ))
  done

  box_bottom_full "${fw}"
}

build_memory_panel() {
  local fw=48
  local free_total mem_used mem_total swap_used swap_total mem_pct swap_pct mem_bar swap_bar

  free_total="$(get_mem_free_total_mb)"
  read -r mem_used mem_total < <(get_mem_used_total_mb)
  read -r swap_used swap_total < <(get_swap_used_total_mb)

  mem_pct=0
  swap_pct=0
  if [[ "${mem_total}" =~ ^[0-9]+$ ]] && (( mem_total > 0 )); then
    mem_pct="$(awk -v u="${mem_used}" -v t="${mem_total}" 'BEGIN{print (u*100)/t}')"
  fi
  if [[ "${swap_total}" =~ ^[0-9]+$ ]] && (( swap_total > 0 )); then
    swap_pct="$(awk -v u="${swap_used}" -v t="${swap_total}" 'BEGIN{print (u*100)/t}')"
  fi

  mem_bar="$(bar_from_percent "${mem_pct}" 25 "|" "-")"
  swap_bar="$(bar_from_percent "${swap_pct}" 25 "|" "-")"

  box_top_full "${fw}"
  box_row_full "${fw}" " Memory: ${free_total}" "${BLD}${YEL}"
  box_sep_full "${fw}"
  box_row_full "${fw}" " Memory [${mem_bar}] ${mem_used}/${mem_total}MB" "${GRN}"
  box_row_full "${fw}" " Swap   [${swap_bar}] ${swap_used}/${swap_total}MB" "${MAG}"
  box_row_full "${fw}" "" "${WHT}"
  box_bottom_full "${fw}"
}

build_network_panel() {
  local c1=26 c2=21
  local lan_tmp wan lan1 lan2 lan3

  lan_tmp="$(mktemp)"
  get_lan_lines >"${lan_tmp}"
  read -r _ wan < <(read_network_cache)
  [[ -n "${wan:-}" ]] || wan="n/a"

  lan1="$(sed -n '1p' "${lan_tmp}")"
  lan2="$(sed -n '2p' "${lan_tmp}")"
  lan3="$(sed -n '3p' "${lan_tmp}")"
  [[ -n "${lan1}" ]] || lan1="n/a"
  [[ -n "${lan2}" ]] || lan2=""
  [[ -n "${lan3}" ]] || lan3=""

  box_top_2col "${c1}" "${c2}"
  box_row_2col "${c1}" "${c2}" " Network:" "" "${BLD}${YEL}" "${WHT}"
  box_sep_2col "${c1}" "${c2}"
  box_row_2col "${c1}" "${c2}" " LAN:" " WAN:" "${BLD}${CYN}" "${BLD}${CYN}"
  box_sep_2col "${c1}" "${c2}"
  box_row_2col "${c1}" "${c2}" " ${lan1}" " ${wan}" "${WHT}" "${WHT}"
  box_row_2col "${c1}" "${c2}" " ${lan2}" "" "${WHT}" "${WHT}"
  box_row_2col "${c1}" "${c2}" " ${lan3}" "" "${WHT}" "${WHT}"
  box_bottom_2col "${c1}" "${c2}"
  rm -f "${lan_tmp}"
}

build_services_panel() {
  local entries_file="$1"
  local target_rows="${2:-9}"
  local c1=38 c2=9 count=0 unit state status_style

  box_top_2col "${c1}" "${c2}"
  box_row_2col "${c1}" "${c2}" " Services:" "" "${BLD}${YEL}" "${WHT}"
  box_sep_2col "${c1}" "${c2}"
  box_row_2col "${c1}" "${c2}" " UNIT" " STATUS" "${BLD}${CYN}" "${BLD}${CYN}"
  box_sep_2col "${c1}" "${c2}"

  while IFS='|' read -r unit state; do
    [[ -n "${unit:-}" ]] || continue
    status_style="${WHT}"
    case "${state}" in
      running) status_style="${BLD}${GRN}" ;;
      failed) status_style="${BLD}${RED}" ;;
      activating|deactivating) status_style="${BLD}${YEL}" ;;
      stopped|inactive|dead) status_style="${BLD}${YEL}" ;;
      *) status_style="${BLD}${MAG}" ;;
    esac
    box_row_2col "${c1}" "${c2}" " ${unit}" " ${state}" "${WHT}" "${status_style}"
    count=$(( count + 1 ))
  done < "${entries_file}"

  while (( count < target_rows )); do
    box_row_2col "${c1}" "${c2}" "" ""
    count=$(( count + 1 ))
  done

  box_bottom_2col "${c1}" "${c2}"
}

paste_panels() {
  local left="$1" right="$2"
  paste -d $'\t' "${left}" "${right}" | sed $'s/\t/ /'
}

render_motd() {
  local top_l top_r mid_l mid_r bot_l bot_r svc_all svc_left svc_right
  local svc_count svc_rows

  top_l="$(mktemp)"
  top_r="$(mktemp)"
  mid_l="$(mktemp)"
  mid_r="$(mktemp)"
  bot_l="$(mktemp)"
  bot_r="$(mktemp)"
  svc_all="$(mktemp)"
  svc_left="$(mktemp)"
  svc_right="$(mktemp)"

  print_heading_figlet

  if ! build_general_panel >"${top_l}"; then
    box_top_full 48 >"${top_l}"
    box_row_full 48 " General panel unavailable" >>"${top_l}"
    box_bottom_full 48 >>"${top_l}"
  fi
  if ! build_cpu_panel >"${top_r}"; then
    box_top_full 48 >"${top_r}"
    box_row_full 48 " CPU panel unavailable" >>"${top_r}"
    box_bottom_full 48 >>"${top_r}"
  fi
  paste_panels "${top_l}" "${top_r}"

  if ! build_disk_panel >"${mid_l}"; then
    box_top_full 48 >"${mid_l}"
    box_row_full 48 " Disk usage unavailable" >>"${mid_l}"
    box_bottom_full 48 >>"${mid_l}"
  fi
  if ! {
    build_memory_panel
    build_network_panel
  } >"${mid_r}"; then
    box_top_full 48 >"${mid_r}"
    box_row_full 48 " Memory/Network unavailable" >>"${mid_r}"
    box_bottom_full 48 >>"${mid_r}"
  fi
  paste_panels "${mid_l}" "${mid_r}"

  if ! get_service_entries >"${svc_all}"; then
    echo "n/a|n/a" >"${svc_all}"
  fi
  svc_count="$(awk 'NF>0{c++} END{print c+0}' "${svc_all}")"
  if (( svc_count < 1 )); then
    svc_count=1
  fi
  svc_rows=$(( (svc_count + 1) / 2 ))
  if (( svc_rows < 9 )); then
    svc_rows=9
  fi

  sed -n "1,${svc_rows}p" "${svc_all}" >"${svc_left}"
  sed -n "$((svc_rows + 1)),$((svc_rows * 2))p" "${svc_all}" >"${svc_right}"
  if ! build_services_panel "${svc_left}" "${svc_rows}" >"${bot_l}"; then
    box_top_full 48 >"${bot_l}"
    box_row_full 48 " Services panel unavailable" >>"${bot_l}"
    box_bottom_full 48 >>"${bot_l}"
  fi
  if ! build_services_panel "${svc_right}" "${svc_rows}" >"${bot_r}"; then
    box_top_full 48 >"${bot_r}"
    box_row_full 48 " Services panel unavailable" >>"${bot_r}"
    box_bottom_full 48 >>"${bot_r}"
  fi
  paste_panels "${bot_l}" "${bot_r}"

  printf "\n"
  rm -f "${top_l}" "${top_r}" "${mid_l}" "${mid_r}" "${bot_l}" "${bot_r}" "${svc_all}" "${svc_left}" "${svc_right}"
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
