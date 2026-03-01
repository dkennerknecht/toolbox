#!/usr/bin/env bash
set -euo pipefail

DRY_RUN=0
AUTO_DETECT=1
INTERACTIVE=-1

SSH_MODE="auto"
NGINX_MODE="auto"
APACHE_MODE="auto"
WORDPRESS_MODE="auto"
NEXTCLOUD_MODE="auto"

BANTIME="1h"
FINDTIME="10m"
MAXRETRY=5
RECIDIVE_BANTIME="1w"
RECIDIVE_FINDTIME="1d"
RECIDIVE_MAXRETRY=5
IGNORE_IPS="127.0.0.1/8 ::1"

JAIL_FILE="/etc/fail2ban/jail.d/10-toolbox-hardening.local"
WORDPRESS_FILTER_FILE="/etc/fail2ban/filter.d/toolbox-wordpress.conf"
NEXTCLOUD_FILTER_FILE="/etc/fail2ban/filter.d/toolbox-nextcloud.conf"
FAIL2BAN_LOG="/var/log/fail2ban.log"

log()  { echo "[$(date +'%F %T')] $*"; }
warn() { echo "[$(date +'%F %T')] WARN: $*" >&2; }
die()  { echo "[$(date +'%F %T')] ERROR: $*" >&2; exit 1; }

run_or_echo() {
  [[ $# -gt 0 ]] || return 0
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

need_root() {
  [[ "$EUID" -eq 0 ]] || die "Run as root (use sudo)."
}

have() {
  command -v "$1" >/dev/null 2>&1
}

detect_pkg_mgr() {
  if have apt-get; then echo "apt"
  elif have dnf; then echo "dnf"
  elif have yum; then echo "yum"
  elif have pacman; then echo "pacman"
  elif have apk; then echo "apk"
  elif have zypper; then echo "zypper"
  else echo ""
  fi
}

install_fail2ban() {
  local mgr
  mgr="$(detect_pkg_mgr)"
  [[ -n "$mgr" ]] || die "No supported package manager found (apt/dnf/yum/pacman/apk/zypper)."

  log "Installing fail2ban using package manager: $mgr"

  case "$mgr" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      run_or_echo apt-get update -y
      run_or_echo apt-get install -y fail2ban
      ;;
    dnf)
      run_or_echo dnf install -y fail2ban
      ;;
    yum)
      run_or_echo yum install -y fail2ban
      ;;
    pacman)
      run_or_echo pacman -Sy --noconfirm fail2ban
      ;;
    apk)
      run_or_echo apk add --no-cache fail2ban
      ;;
    zypper)
      run_or_echo zypper --non-interactive install fail2ban
      ;;
  esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --interactive)
        INTERACTIVE=1
        shift
        ;;
      --non-interactive)
        INTERACTIVE=0
        shift
        ;;
      --auto)
        AUTO_DETECT=1
        shift
        ;;
      --no-auto)
        AUTO_DETECT=0
        shift
        ;;
      --ssh)
        SSH_MODE="on"
        shift
        ;;
      --no-ssh)
        SSH_MODE="off"
        shift
        ;;
      --nginx)
        NGINX_MODE="on"
        shift
        ;;
      --no-nginx)
        NGINX_MODE="off"
        shift
        ;;
      --apache)
        APACHE_MODE="on"
        shift
        ;;
      --no-apache)
        APACHE_MODE="off"
        shift
        ;;
      --wordpress)
        WORDPRESS_MODE="on"
        shift
        ;;
      --no-wordpress)
        WORDPRESS_MODE="off"
        shift
        ;;
      --nextcloud)
        NEXTCLOUD_MODE="on"
        shift
        ;;
      --no-nextcloud)
        NEXTCLOUD_MODE="off"
        shift
        ;;
      --bantime)
        BANTIME="${2:-}"
        [[ -n "$BANTIME" ]] || die "--bantime requires a value (example: 1h)"
        shift 2
        ;;
      --findtime)
        FINDTIME="${2:-}"
        [[ -n "$FINDTIME" ]] || die "--findtime requires a value (example: 10m)"
        shift 2
        ;;
      --maxretry)
        MAXRETRY="${2:-}"
        [[ "$MAXRETRY" =~ ^[0-9]+$ ]] || die "--maxretry must be an integer"
        shift 2
        ;;
      --ignore-ip)
        IGNORE_IPS="${2:-}"
        [[ -n "$IGNORE_IPS" ]] || die "--ignore-ip requires a value"
        IGNORE_IPS="${IGNORE_IPS//,/ }"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -h|--help)
        cat <<'EOF'
Usage:
  sudo bash setup-fail2ban.sh [options]

Options:
  --interactive             Start interactive wizard (prompts for all major settings)
  --non-interactive         Disable interactive wizard
  --auto / --no-auto         Enable or disable automatic service detection (default: --auto)
  --ssh / --no-ssh           Force-enable or disable SSH hardening
  --nginx / --no-nginx       Force-enable or disable Nginx hardening jails
  --apache / --no-apache     Force-enable or disable Apache hardening jails
  --wordpress / --no-wordpress
                             Force-enable or disable WordPress brute-force jail
  --nextcloud / --no-nextcloud
                             Force-enable or disable Nextcloud login jail
  --bantime <time>           Default ban time (default: 1h)
  --findtime <time>          Default find window (default: 10m)
  --maxretry <n>             Default retry count before ban (default: 5)
  --ignore-ip <list>         Space- or comma-separated IP/CIDR allowlist
  --dry-run                  Only print actions, do not change files/services
  -h, --help                 Show this help

Examples:
  sudo bash setup-fail2ban.sh --interactive
  sudo bash setup-fail2ban.sh
  sudo bash setup-fail2ban.sh --nginx --wordpress
  sudo bash setup-fail2ban.sh --no-auto --ssh --apache
EOF
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

stdin_is_tty() {
  [[ -t 0 && -t 1 ]]
}

prompt_yes_no() {
  local label="$1"
  local default="$2"
  local var_name="$3"
  local input prompt_hint default_word

  if [[ "$default" -eq 1 ]]; then
    prompt_hint="Y/n"
    default_word="yes"
  else
    prompt_hint="y/N"
    default_word="no"
  fi

  while true; do
    printf '%s [%s]: ' "$label" "$prompt_hint"
    IFS= read -r input || die "Input aborted."
    input="$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')"
    [[ -z "$input" ]] && input="$default_word"

    case "$input" in
      y|yes|1|true)
        printf -v "$var_name" '%s' "1"
        return 0
        ;;
      n|no|0|false)
        printf -v "$var_name" '%s' "0"
        return 0
        ;;
      *)
        echo "Please answer yes or no."
        ;;
    esac
  done
}

prompt_mode() {
  local label="$1"
  local var_name="$2"
  local detected="$3"
  local current input detected_hint

  current="${!var_name}"
  if [[ "$detected" -eq 1 ]]; then
    detected_hint="detected"
  else
    detected_hint="not detected"
  fi

  while true; do
    printf '%s [auto/on/off] (default: %s, %s): ' "$label" "$current" "$detected_hint"
    IFS= read -r input || die "Input aborted."
    input="$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')"
    [[ -z "$input" ]] && input="$current"

    case "$input" in
      auto|on|off)
        printf -v "$var_name" '%s' "$input"
        return 0
        ;;
      *)
        echo "Please enter auto, on, or off."
        ;;
    esac
  done
}

prompt_string() {
  local label="$1"
  local var_name="$2"
  local current input

  current="${!var_name}"
  printf '%s (default: %s): ' "$label" "$current"
  IFS= read -r input || die "Input aborted."
  [[ -z "$input" ]] && input="$current"
  printf -v "$var_name" '%s' "$input"
}

prompt_integer() {
  local label="$1"
  local var_name="$2"
  local current input

  current="${!var_name}"
  while true; do
    printf '%s (default: %s): ' "$label" "$current"
    IFS= read -r input || die "Input aborted."
    [[ -z "$input" ]] && input="$current"
    if [[ "$input" =~ ^[0-9]+$ ]]; then
      printf -v "$var_name" '%s' "$input"
      return 0
    fi
    echo "Please enter an integer."
  done
}

run_interactive_wizard() {
  local ssh_detected="$1"
  local nginx_detected="$2"
  local apache_detected="$3"
  local wordpress_detected="$4"
  local nextcloud_detected="$5"
  local proceed=1

  echo
  echo "=== Fail2ban Interactive Setup ==="
  echo "Detected services: ssh=$ssh_detected nginx=$nginx_detected apache=$apache_detected wordpress=$wordpress_detected nextcloud=$nextcloud_detected"
  echo

  prompt_yes_no "Enable auto detection for 'auto' modes?" "$AUTO_DETECT" AUTO_DETECT
  prompt_mode "SSH hardening mode" SSH_MODE "$ssh_detected"
  prompt_mode "Nginx hardening mode" NGINX_MODE "$nginx_detected"
  prompt_mode "Apache hardening mode" APACHE_MODE "$apache_detected"
  prompt_mode "WordPress hardening mode" WORDPRESS_MODE "$wordpress_detected"
  prompt_mode "Nextcloud hardening mode" NEXTCLOUD_MODE "$nextcloud_detected"
  prompt_string "Default bantime (example: 1h, 12h, 1d)" BANTIME
  prompt_string "Default findtime (example: 10m, 30m, 1h)" FINDTIME
  prompt_integer "Default maxretry" MAXRETRY
  prompt_string "Ignore IPs (space- or comma-separated)" IGNORE_IPS
  IGNORE_IPS="${IGNORE_IPS//,/ }"
  prompt_yes_no "Run in dry-run mode?" "$DRY_RUN" DRY_RUN

  echo
  echo "Summary:"
  echo "  AUTO_DETECT=$AUTO_DETECT"
  echo "  SSH_MODE=$SSH_MODE"
  echo "  NGINX_MODE=$NGINX_MODE"
  echo "  APACHE_MODE=$APACHE_MODE"
  echo "  WORDPRESS_MODE=$WORDPRESS_MODE"
  echo "  NEXTCLOUD_MODE=$NEXTCLOUD_MODE"
  echo "  BANTIME=$BANTIME"
  echo "  FINDTIME=$FINDTIME"
  echo "  MAXRETRY=$MAXRETRY"
  echo "  IGNORE_IPS=$IGNORE_IPS"
  echo "  DRY_RUN=$DRY_RUN"
  echo

  prompt_yes_no "Apply this configuration now?" 1 proceed
  if [[ "$proceed" -ne 1 ]]; then
    log "Aborted by user."
    exit 0
  fi
}

service_active_or_enabled() {
  local svc
  if have systemctl; then
    for svc in "$@"; do
      if systemctl is-active --quiet "$svc" 2>/dev/null || systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        return 0
      fi
    done
  fi
  return 1
}

detect_ssh() {
  service_active_or_enabled ssh.service sshd.service ssh sshd || pgrep -x sshd >/dev/null 2>&1
}

detect_nginx() {
  service_active_or_enabled nginx.service nginx || pgrep -x nginx >/dev/null 2>&1
}

detect_apache() {
  service_active_or_enabled apache2.service httpd.service apache2 httpd || pgrep -x apache2 >/dev/null 2>&1 || pgrep -x httpd >/dev/null 2>&1
}

collect_existing_paths() {
  local seen="|"
  local p
  for p in "$@"; do
    [[ -f "$p" ]] || continue
    if [[ "$seen" != *"|$p|"* ]]; then
      printf '%s\n' "$p"
      seen+="$p|"
    fi
  done
}

get_nginx_access_logs() {
  local file
  local -a candidates=("/var/log/nginx/access.log")
  shopt -s nullglob
  for file in /var/log/nginx/*access*.log; do
    candidates+=("$file")
  done
  shopt -u nullglob
  collect_existing_paths "${candidates[@]}"
}

get_nginx_error_logs() {
  local file
  local -a candidates=("/var/log/nginx/error.log")
  shopt -s nullglob
  for file in /var/log/nginx/*error*.log; do
    candidates+=("$file")
  done
  shopt -u nullglob
  collect_existing_paths "${candidates[@]}"
}

get_apache_access_logs() {
  local file
  local -a candidates=(
    "/var/log/apache2/access.log"
    "/var/log/httpd/access_log"
  )
  shopt -s nullglob
  for file in /var/log/apache2/*access*.log /var/log/httpd/*access*.log; do
    candidates+=("$file")
  done
  shopt -u nullglob
  collect_existing_paths "${candidates[@]}"
}

get_apache_error_logs() {
  local file
  local -a candidates=(
    "/var/log/apache2/error.log"
    "/var/log/httpd/error_log"
  )
  shopt -s nullglob
  for file in /var/log/apache2/*error*.log /var/log/httpd/*error*.log; do
    candidates+=("$file")
  done
  shopt -u nullglob
  collect_existing_paths "${candidates[@]}"
}

find_wordpress_sites() {
  local root file
  local -a roots=("/var/www" "/srv/www" "/usr/share/nginx/html")

  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r file; do
      printf '%s\n' "${file%/wp-login.php}"
    done < <(find "$root" -maxdepth 6 -type f -name wp-login.php 2>/dev/null)
  done | awk '!seen[$0]++'
}

find_nextcloud_configs() {
  local root file
  local -a roots=("/var/www" "/srv/www" "/var/lib")

  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r file; do
      printf '%s\n' "$file"
    done < <(find "$root" -maxdepth 8 -type f -path '*/nextcloud/config/config.php' 2>/dev/null)
  done | awk '!seen[$0]++'
}

find_nextcloud_logs() {
  local root file
  local -a candidates=(
    "/var/www/nextcloud/data/nextcloud.log"
    "/var/lib/nextcloud/data/nextcloud.log"
    "/var/log/nextcloud/nextcloud.log"
  )

  for root in /var/www /srv/www /var/lib; do
    [[ -d "$root" ]] || continue
    while IFS= read -r file; do
      candidates+=("$file")
    done < <(find "$root" -maxdepth 8 -type f -name nextcloud.log 2>/dev/null)
  done

  collect_existing_paths "${candidates[@]}"
}

format_logpath_value() {
  local first=1
  local p
  for p in "$@"; do
    [[ -n "$p" ]] || continue
    if [[ "$first" -eq 1 ]]; then
      printf '%s' "$p"
      first=0
    else
      printf '\n          %s' "$p"
    fi
  done
}

mode_enabled() {
  local mode="$1"
  local detected="$2"

  case "$mode" in
    on) return 0 ;;
    off) return 1 ;;
    auto)
      [[ "$AUTO_DETECT" -eq 1 && "$detected" -eq 1 ]]
      ;;
    *)
      return 1
      ;;
  esac
}

select_banaction() {
  local action
  for action in nftables-multiport firewallcmd-rich-rules iptables-multiport; do
    if [[ -f "/etc/fail2ban/action.d/${action}.conf" ]]; then
      echo "$action"
      return 0
    fi
  done
  echo "iptables-multiport"
}

write_managed_file() {
  local path="$1"
  local content="$2"
  local mode="${3:-0644}"
  local dir tmp

  dir="$(dirname "$path")"
  [[ -L "$dir" ]] && die "Refusing unsafe symlink directory: $dir"
  run_or_echo mkdir -p "$dir"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Would write managed file: $path"
    return 0
  fi

  [[ -L "$path" ]] && die "Refusing to overwrite symlink: $path"
  tmp="$(mktemp "${path}.tmp.XXXXXX")" || die "Cannot create temp file for $path"
  printf '%s\n' "$content" >"$tmp"
  chmod "$mode" "$tmp"
  mv -f -- "$tmp" "$path"
}

ensure_fail2ban_logfile() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY-RUN: touch '$FAIL2BAN_LOG'"
    return 0
  fi
  touch "$FAIL2BAN_LOG"
}

write_wordpress_filter() {
  local content
  content='[Definition]
# Matches brute-force attempts against wp-login.php and xmlrpc.php from common access logs.
failregex = ^<HOST>\s+\S+\s+\S+\s+\[[^]]+\]\s+"POST\s+/wp-login\.php(?:\?[^"]*)?\s+HTTP/\d\.\d"\s+200\s+\d+.*$
            ^<HOST>\s+\S+\s+\S+\s+\[[^]]+\]\s+"POST\s+/xmlrpc\.php(?:\?[^"]*)?\s+HTTP/\d\.\d"\s+(200|401|403|405)\s+\d+.*$
ignoreregex =
'
  write_managed_file "$WORDPRESS_FILTER_FILE" "$content" 0644
}

write_nextcloud_filter() {
  local content
  content='[Definition]
# Matches failed login events in Nextcloud JSON logs.
failregex = ^.*"remoteAddr":"<HOST>".*"message":"Login failed:.*$
            ^.*"remoteAddr":"<HOST>".*"message":"Trusted domain error\..*$
ignoreregex =
'
  write_managed_file "$NEXTCLOUD_FILTER_FILE" "$content" 0644
}

build_jail_file() {
  local banaction="$1"
  local ssh_enabled="$2"
  local nginx_http_auth_enabled="$3"
  local nginx_botsearch_enabled="$4"
  local apache_auth_enabled="$5"
  local apache_badbots_enabled="$6"
  local wordpress_enabled="$7"
  local nextcloud_enabled="$8"
  local nginx_error_logpath="$9"
  local nginx_access_logpath="${10}"
  local apache_error_logpath="${11}"
  local apache_access_logpath="${12}"
  local web_access_logpath="${13}"
  local nextcloud_logpath="${14}"
  local content

  content=$(cat <<EOF
# Managed by setup-fail2ban.sh
# Manual changes can be overwritten on next run.

[DEFAULT]
bantime = ${BANTIME}
findtime = ${FINDTIME}
maxretry = ${MAXRETRY}
ignoreip = ${IGNORE_IPS}
backend = auto
banaction = ${banaction}
usedns = warn

[recidive]
enabled = true
logpath = ${FAIL2BAN_LOG}
bantime = ${RECIDIVE_BANTIME}
findtime = ${RECIDIVE_FINDTIME}
maxretry = ${RECIDIVE_MAXRETRY}
EOF
)

  if [[ "$ssh_enabled" -eq 1 ]]; then
    content+=$'\n'
    content+=$(cat <<'EOF'
[sshd]
enabled = true
maxretry = 5
EOF
)
  fi

  if [[ "$nginx_http_auth_enabled" -eq 1 ]]; then
    content+=$'\n'
    content+=$(cat <<EOF
[nginx-http-auth]
enabled = true
logpath = ${nginx_error_logpath}
EOF
)
  fi

  if [[ "$nginx_botsearch_enabled" -eq 1 ]]; then
    content+=$'\n'
    content+=$(cat <<EOF
[nginx-botsearch]
enabled = true
logpath = ${nginx_access_logpath}
maxretry = 2
findtime = 10m
bantime = 12h
EOF
)
  fi

  if [[ "$apache_auth_enabled" -eq 1 ]]; then
    content+=$'\n'
    content+=$(cat <<EOF
[apache-auth]
enabled = true
logpath = ${apache_error_logpath}
EOF
)
  fi

  if [[ "$apache_badbots_enabled" -eq 1 ]]; then
    content+=$'\n'
    content+=$(cat <<EOF
[apache-badbots]
enabled = true
logpath = ${apache_access_logpath}
maxretry = 2
findtime = 10m
bantime = 24h
EOF
)
  fi

  if [[ "$wordpress_enabled" -eq 1 ]]; then
    content+=$'\n'
    content+=$(cat <<EOF
[toolbox-wordpress]
enabled = true
filter = toolbox-wordpress
port = http,https
logpath = ${web_access_logpath}
maxretry = 6
findtime = 10m
bantime = 12h
EOF
)
  fi

  if [[ "$nextcloud_enabled" -eq 1 ]]; then
    content+=$'\n'
    content+=$(cat <<EOF
[toolbox-nextcloud]
enabled = true
filter = toolbox-nextcloud
port = http,https
logpath = ${nextcloud_logpath}
maxretry = 5
findtime = 15m
bantime = 12h
EOF
)
  fi

  printf '%s\n' "$content"
}

enable_fail2ban_service() {
  if have systemctl; then
    if ! run_or_echo systemctl enable --now fail2ban; then
      run_or_echo systemctl enable --now fail2ban.service || warn "Could not enable/start fail2ban via systemd."
    fi
  elif have rc-update && have rc-service; then
    run_or_echo rc-update add fail2ban default
    run_or_echo rc-service fail2ban restart
  elif have service; then
    run_or_echo service fail2ban restart
  else
    warn "No known init system command found to restart fail2ban automatically."
  fi
}

validate_and_reload_fail2ban() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY-RUN: fail2ban-client -t"
    return 0
  fi

  have fail2ban-client || die "fail2ban-client not found after installation."
  fail2ban-client -t >/dev/null
  enable_fail2ban_service
}

main() {
  local arg_count="$#"
  local ssh_detected=0 nginx_detected=0 apache_detected=0 wordpress_detected=0 nextcloud_detected=0
  local ssh_enabled=0 nginx_enabled=0 apache_enabled=0 wordpress_enabled=0 nextcloud_enabled=0
  local nginx_http_auth_enabled=0 nginx_botsearch_enabled=0
  local apache_auth_enabled=0 apache_badbots_enabled=0
  local banaction
  local jail_content
  local nginx_access_logpath="" nginx_error_logpath="" apache_access_logpath="" apache_error_logpath=""
  local web_access_logpath="" nextcloud_logpath=""
  local -a wordpress_sites=()
  local -a nextcloud_configs=()
  local -a nginx_access_logs=()
  local -a nginx_error_logs=()
  local -a apache_access_logs=()
  local -a apache_error_logs=()
  local -a web_access_logs=()
  local -a nextcloud_logs=()

  parse_args "$@"
  if [[ "$INTERACTIVE" -eq -1 ]]; then
    if [[ "$arg_count" -eq 0 ]] && stdin_is_tty; then
      INTERACTIVE=1
    else
      INTERACTIVE=0
    fi
  fi

  if [[ "$INTERACTIVE" -eq 1 ]] && ! stdin_is_tty; then
    die "Interactive mode requested but no interactive TTY is available."
  fi

  need_root

  detect_ssh && ssh_detected=1 || true
  detect_nginx && nginx_detected=1 || true
  detect_apache && apache_detected=1 || true

  mapfile -t wordpress_sites < <(find_wordpress_sites)
  [[ "${#wordpress_sites[@]}" -gt 0 ]] && wordpress_detected=1 || true

  mapfile -t nextcloud_configs < <(find_nextcloud_configs)
  mapfile -t nextcloud_logs < <(find_nextcloud_logs)
  if [[ "${#nextcloud_configs[@]}" -gt 0 || "${#nextcloud_logs[@]}" -gt 0 ]]; then
    nextcloud_detected=1
  fi

  mapfile -t nginx_access_logs < <(get_nginx_access_logs)
  mapfile -t nginx_error_logs < <(get_nginx_error_logs)
  mapfile -t apache_access_logs < <(get_apache_access_logs)
  mapfile -t apache_error_logs < <(get_apache_error_logs)
  mapfile -t web_access_logs < <(collect_existing_paths "${nginx_access_logs[@]}" "${apache_access_logs[@]}")

  if [[ "$INTERACTIVE" -eq 1 ]]; then
    run_interactive_wizard "$ssh_detected" "$nginx_detected" "$apache_detected" "$wordpress_detected" "$nextcloud_detected"
  fi

  install_fail2ban

  nginx_access_logpath="$(format_logpath_value "${nginx_access_logs[@]}")"
  nginx_error_logpath="$(format_logpath_value "${nginx_error_logs[@]}")"
  apache_access_logpath="$(format_logpath_value "${apache_access_logs[@]}")"
  apache_error_logpath="$(format_logpath_value "${apache_error_logs[@]}")"
  web_access_logpath="$(format_logpath_value "${web_access_logs[@]}")"
  nextcloud_logpath="$(format_logpath_value "${nextcloud_logs[@]}")"

  mode_enabled "$SSH_MODE" "$ssh_detected" && ssh_enabled=1 || true
  mode_enabled "$NGINX_MODE" "$nginx_detected" && nginx_enabled=1 || true
  mode_enabled "$APACHE_MODE" "$apache_detected" && apache_enabled=1 || true
  mode_enabled "$WORDPRESS_MODE" "$wordpress_detected" && wordpress_enabled=1 || true
  mode_enabled "$NEXTCLOUD_MODE" "$nextcloud_detected" && nextcloud_enabled=1 || true

  if [[ "$nginx_enabled" -eq 1 ]]; then
    if [[ -n "$nginx_error_logpath" ]]; then
      nginx_http_auth_enabled=1
    else
      warn "Nginx detected but no error log found; nginx-http-auth jail will be skipped."
    fi

    if [[ -n "$nginx_access_logpath" ]]; then
      nginx_botsearch_enabled=1
    else
      warn "Nginx detected but no access log found; nginx-botsearch jail will be skipped."
    fi

    if [[ "$nginx_http_auth_enabled" -eq 0 && "$nginx_botsearch_enabled" -eq 0 ]]; then
      warn "No usable Nginx log files found; disabling Nginx hardening."
      nginx_enabled=0
    fi
  fi

  if [[ "$apache_enabled" -eq 1 ]]; then
    if [[ -n "$apache_error_logpath" ]]; then
      apache_auth_enabled=1
    else
      warn "Apache detected but no error log found; apache-auth jail will be skipped."
    fi

    if [[ -n "$apache_access_logpath" ]]; then
      apache_badbots_enabled=1
    else
      warn "Apache detected but no access log found; apache-badbots jail will be skipped."
    fi

    if [[ "$apache_auth_enabled" -eq 0 && "$apache_badbots_enabled" -eq 0 ]]; then
      warn "No usable Apache log files found; disabling Apache hardening."
      apache_enabled=0
    fi
  fi

  if [[ "$wordpress_enabled" -eq 1 ]]; then
    if [[ -z "$web_access_logpath" ]]; then
      warn "WordPress enabled but no web access logs found; disabling WordPress jail."
      wordpress_enabled=0
    fi
  fi

  if [[ "$nextcloud_enabled" -eq 1 ]]; then
    if [[ -z "$nextcloud_logpath" ]]; then
      warn "Nextcloud enabled but no nextcloud.log found; disabling Nextcloud jail."
      nextcloud_enabled=0
    fi
  fi

  banaction="$(select_banaction)"
  ensure_fail2ban_logfile

  if [[ "$wordpress_enabled" -eq 1 ]]; then
    write_wordpress_filter
  fi
  if [[ "$nextcloud_enabled" -eq 1 ]]; then
    write_nextcloud_filter
  fi

  jail_content="$(
    build_jail_file \
      "$banaction" \
      "$ssh_enabled" \
      "$nginx_http_auth_enabled" \
      "$nginx_botsearch_enabled" \
      "$apache_auth_enabled" \
      "$apache_badbots_enabled" \
      "$wordpress_enabled" \
      "$nextcloud_enabled" \
      "$nginx_error_logpath" \
      "$nginx_access_logpath" \
      "$apache_error_logpath" \
      "$apache_access_logpath" \
      "$web_access_logpath" \
      "$nextcloud_logpath"
  )"

  write_managed_file "$JAIL_FILE" "$jail_content" 0644
  validate_and_reload_fail2ban

  log "Fail2ban setup completed."
  log "Managed jail file: $JAIL_FILE"
  log "banaction selected: $banaction"
  log "Auto-detect: $AUTO_DETECT"
  log "Detected services -> ssh:$ssh_detected nginx:$nginx_detected apache:$apache_detected wordpress:$wordpress_detected nextcloud:$nextcloud_detected"
  log "Enabled jails -> ssh:$ssh_enabled recidive:1 nginx-http-auth:$nginx_http_auth_enabled nginx-botsearch:$nginx_botsearch_enabled apache-auth:$apache_auth_enabled apache-badbots:$apache_badbots_enabled wordpress:$wordpress_enabled nextcloud:$nextcloud_enabled"
}

main "$@"
