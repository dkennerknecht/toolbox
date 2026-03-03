#!/usr/bin/env bash
set -euo pipefail

# Shared Oh-My-Zsh installation for multiple users (ONE install in /opt, per-user dotfiles)
#
# - Installs packages: zsh, vim, git, curl, ca-certificates, fzf
# - Installs Oh-My-Zsh ONCE to /opt/ohmyzsh
# - Installs plugins ONCE to /opt/ohmyzsh/custom/plugins
# - Users only get their own ~/.zshrc (no per-user OMZ install)
# - Root gets autoupdate vars in .zshrc, normal users do not
# - Updates are done centrally as root via /etc/cron.daily script, effective every 30 days (silent)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/<YOU>/<REPO>/main/install.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/<YOU>/<REPO>/main/install.sh | sudo bash -s -- --all-users
#   curl -fsSL https://raw.githubusercontent.com/<YOU>/<REPO>/main/install.sh | sudo bash -s -- --users "alice,bob"
#   curl -fsSL https://raw.githubusercontent.com/<YOU>/<REPO>/main/install.sh | sudo bash -s -- --no-chsh
#   curl -fsSL https://raw.githubusercontent.com/<YOU>/<REPO>/main/install.sh | sudo bash -s -- --dry-run

MODE="default"
USERS_CSV=""
CHSH_ENABLE=1
DRY_RUN=0

INSTALL_DIR="/opt/ohmyzsh"
CUSTOM_DIR="${INSTALL_DIR}/custom"
PLUGINS_DIR="${CUSTOM_DIR}/plugins"

LOCK_DIR="/run/lock/omz-shared-install.lock.d"

CRON_FILE="/etc/cron.daily/ohmyzsh-shared-update"
CRON_STATE="/var/lib/ohmyzsh-shared-update.last"

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
  [[ "${EUID}" -eq 0 ]] || die "Run as root (use sudo)."
}

have() { command -v "$1" >/dev/null 2>&1; }

acquire_lock() {
  local lock_parent
  lock_parent="$(dirname "$LOCK_DIR")"

  [[ -L "$lock_parent" ]] && die "Refusing unsafe lock parent symlink: $lock_parent"
  if [[ ! -d "$lock_parent" ]]; then
    install -d -m 0755 -o root -g root "$lock_parent" || die "Cannot create lock parent: $lock_parent"
  fi

  if mkdir "$LOCK_DIR" 2>/dev/null; then
    trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
  else
    die "Another install is running (lock dir: $LOCK_DIR)."
  fi
  log "Lock acquired: $LOCK_DIR"
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

install_packages() {
  local mgr
  mgr="$(detect_pkg_mgr)"
  [[ -n "$mgr" ]] || die "No supported package manager found (apt/dnf/yum/pacman/apk/zypper). Install deps manually."

  log "Using package manager: $mgr"

  case "$mgr" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      run_or_echo apt-get update -y
      run_or_echo apt-get install -y zsh vim git curl ca-certificates fzf
      ;;
    dnf)
      run_or_echo dnf install -y zsh vim git curl ca-certificates fzf
      ;;
    yum)
      run_or_echo yum install -y zsh vim git curl ca-certificates fzf
      ;;
    pacman)
      run_or_echo pacman -Sy --noconfirm zsh vim git curl ca-certificates fzf
      ;;
    apk)
      run_or_echo apk add --no-cache zsh vim git curl ca-certificates fzf
      ;;
    zypper)
      run_or_echo zypper --non-interactive install zsh vim git curl ca-certificates fzf
      ;;
  esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --users)
        MODE="users"
        USERS_CSV="${2:-}"
        [[ -n "$USERS_CSV" ]] || die "--users requires a comma-separated list"
        shift 2
        ;;
      --all-users)
        MODE="all"
        shift
        ;;
      --no-chsh)
        CHSH_ENABLE=0
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -h|--help)
        cat <<'EOF'
Usage:
  sudo bash install.sh [--users "alice,bob"] [--all-users] [--no-chsh] [--dry-run]

Default: installs for invoking user (SUDO_USER if available, else root).
--users: install for a comma-separated list of users
--all-users: install for root + all "real" users (UID >= 1000)
--no-chsh: do not change default shell
--dry-run: only print actions
EOF
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

get_user_home() {
  local u="$1"
  getent passwd "$u" | awk -F: '{print $6}'
}

get_user_shell() {
  local u="$1"
  getent passwd "$u" | awk -F: '{print $7}'
}

list_target_users() {
  local users=()

  case "$MODE" in
    default)
      if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        users+=("${SUDO_USER}")
      else
        users+=("root")
      fi
      ;;
    users)
      IFS=',' read -r -a users <<<"$USERS_CSV"
      ;;
    all)
      # include root explicitly
      users+=("root")
      # include all "real" users (UID >= 1000)
      while IFS=: read -r name _ uid _ _ home shell; do
        if [[ "$uid" -ge 1000 ]] && [[ "$shell" != */nologin ]] && [[ "$shell" != */false ]] && [[ -d "$home" ]]; then
          users+=("$name")
        fi
      done < <(getent passwd)
      ;;
    *)
      die "Invalid MODE=$MODE"
      ;;
  esac

  # trim whitespace + de-duplicate
  local cleaned=()
  local seen="|"
  for u in "${users[@]}"; do
    u="${u//[[:space:]]/}"
    [[ -z "$u" ]] && continue
    if [[ "$seen" != *"|$u|"* ]]; then
      cleaned+=("$u")
      seen+="$u|"
    fi
  done

  printf '%s\n' "${cleaned[@]}"
}

backup_path() {
  local p="$1"
  local ts
  ts="$(date +%s)"
  echo "${p}.bak.${ts}"
}

clone_or_repair_root() {
  local repo="$1" dest="$2"

  if [[ -d "$dest" && ! -d "$dest/.git" ]]; then
    local bak
    bak="$(backup_path "$dest")"
    warn "Path exists but is not a git repo: $dest -> moving to $bak"
    run_or_echo mv -- "$dest" "$bak"
  fi

  if [[ -d "$dest/.git" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "DRY-RUN: git -C '$dest' fetch --prune"
      echo "DRY-RUN: git -C '$dest' pull --ff-only"
    else
      if ! git -C "$dest" fetch --prune >/dev/null 2>&1; then
        warn "git fetch failed for $dest -> re-clone"
        local bak
        bak="$(backup_path "$dest")"
        mv "$dest" "$bak"
        git clone --depth=1 "$repo" "$dest" >/dev/null
      else
        if ! git -C "$dest" pull --ff-only >/dev/null 2>&1; then
          warn "git pull failed for $dest -> re-clone"
          local bak
          bak="$(backup_path "$dest")"
          mv "$dest" "$bak"
          git clone --depth=1 "$repo" "$dest" >/dev/null
        fi
      fi
    fi
  else
    run_or_echo git clone --depth=1 --quiet "$repo" "$dest"
  fi
}

ensure_shared_omz() {
  log "Ensuring shared Oh-My-Zsh in: $INSTALL_DIR"
  run_or_echo mkdir -p "$INSTALL_DIR"

  # if exists and not a git repo but not empty -> move aside
  if [[ -d "$INSTALL_DIR" && ! -d "$INSTALL_DIR/.git" ]]; then
    if [[ "$(ls -A "$INSTALL_DIR" 2>/dev/null | wc -l | tr -d ' ')" -gt 0 ]]; then
      local bak
      bak="$(backup_path "$INSTALL_DIR")"
      warn "Shared install dir is not a git repo: $INSTALL_DIR -> moving to $bak"
      run_or_echo mv -- "$INSTALL_DIR" "$bak"
      run_or_echo mkdir -p "$INSTALL_DIR"
    fi
  fi

  clone_or_repair_root "https://github.com/ohmyzsh/ohmyzsh" "$INSTALL_DIR"

  [[ "$DRY_RUN" -eq 1 ]] || {
    chown -R root:root "$INSTALL_DIR"
    chmod -R a+rX "$INSTALL_DIR"
  }

  run_or_echo mkdir -p "$PLUGINS_DIR"
  [[ "$DRY_RUN" -eq 1 ]] || {
    chown -R root:root "$CUSTOM_DIR"
    chmod -R a+rX "$CUSTOM_DIR"
  }
}

ensure_shared_plugins() {
  log "Ensuring shared plugins in: $PLUGINS_DIR"

  clone_or_repair_root "https://github.com/zsh-users/zsh-autosuggestions" \
    "$PLUGINS_DIR/zsh-autosuggestions"

  clone_or_repair_root "https://github.com/marlonrichert/zsh-autocomplete" \
    "$PLUGINS_DIR/zsh-autocomplete"

  clone_or_repair_root "https://github.com/zsh-users/zsh-completions" \
    "$PLUGINS_DIR/zsh-completions"

  clone_or_repair_root "https://github.com/agkozak/zsh-z" \
    "$PLUGINS_DIR/zsh-z"

  clone_or_repair_root "https://github.com/mrjohannchang/fz.sh" \
    "$PLUGINS_DIR/fz.sh"

  clone_or_repair_root "https://github.com/z-shell/F-Sy-H" \
    "$PLUGINS_DIR/F-Sy-H"

  # Clone as requested, but we do NOT enable this plugin for normal users in a shared read-only setup.
  clone_or_repair_root "https://github.com/tamcore/autoupdate-oh-my-zsh-plugins" \
    "$PLUGINS_DIR/autoupdate-oh-my-zsh-plugins"

  # keep a shim link (not enabled by default)
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY-RUN: ln -sfn '$PLUGINS_DIR/autoupdate-oh-my-zsh-plugins' '$PLUGINS_DIR/autoupdate'"
  else
    ln -sfn "$PLUGINS_DIR/autoupdate-oh-my-zsh-plugins" "$PLUGINS_DIR/autoupdate"
    chown -h root:root "$PLUGINS_DIR/autoupdate"
  fi

  [[ "$DRY_RUN" -eq 1 ]] || {
    chown -R root:root "$PLUGINS_DIR"
    chmod -R a+rX "$PLUGINS_DIR"
  }
}

write_user_zshrc() {
  local user="$1" home="$2"
  local zshrc="$home/.zshrc"
  local backup group tmp

  [[ -n "$home" && -d "$home" ]] || { warn "Skip $user: no home directory"; return 0; }
  if [[ -L "$zshrc" ]]; then
    warn "Skip $user: refusing to overwrite symlink $zshrc"
    return 0
  fi

  if [[ -f "$zshrc" ]]; then
    backup="$home/.zshrc.bak.$(date +%s)"
    log "Patching existing $zshrc for $user (backup: $backup)"
    run_or_echo cp -a -- "$zshrc" "$backup"
  else
    log "Creating $zshrc for $user"
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY-RUN: write managed zshrc to '$zshrc' (atomic replace)"
    return 0
  fi

  tmp="$(mktemp "$home/.zshrc.tmp.XXXXXX")" || die "Cannot create temp file in $home"

  if [[ "$user" == "root" ]]; then
    cat >"$tmp" <<'EOF'
# ~/.zshrc managed by shared-ohmyzsh install.sh
export ZSH="/opt/ohmyzsh"
export ZSH_CUSTOM="/opt/ohmyzsh/custom"

ZSH_THEME="gnzh"

# autoupdate-oh-my-zsh-plugins (root only)
export UPDATE_ZSH_DAYS=30
ZSH_CUSTOM_AUTOUPDATE_QUIET=true

# zsh-completions: must be in fpath before compinit (OMZ runs compinit)
fpath+=("$ZSH_CUSTOM/plugins/zsh-completions/src")

plugins=(
  git
  zsh-completions
  zsh-autocomplete
  zsh-autosuggestions
  zsh-z
  fz.sh
  F-Sy-H
)

source "$ZSH/oh-my-zsh.sh"

ZSH_AUTOSUGGEST_STRATEGY=(history completion)
EOF
  else
    cat >"$tmp" <<'EOF'
# ~/.zshrc managed by shared-ohmyzsh install.sh
export ZSH="/opt/ohmyzsh"
export ZSH_CUSTOM="/opt/ohmyzsh/custom"

ZSH_THEME="gnzh"

# zsh-completions: must be in fpath before compinit (OMZ runs compinit)
fpath+=("$ZSH_CUSTOM/plugins/zsh-completions/src")

plugins=(
  git
  zsh-completions
  zsh-autocomplete
  zsh-autosuggestions
  zsh-z
  fz.sh
  F-Sy-H
)

source "$ZSH/oh-my-zsh.sh"

ZSH_AUTOSUGGEST_STRATEGY=(history completion)
EOF
  fi

  group="$(id -gn "$user" 2>/dev/null || echo "$user")"
  chown "$user:$group" "$tmp" || true
  chmod 0644 "$tmp"
  mv -f -- "$tmp" "$zshrc"
}

set_default_shell() {
  local user="$1"
  local zsh_path
  zsh_path="$(command -v zsh || true)"
  [[ -n "$zsh_path" ]] || die "zsh not found after install."

  if ! grep -Fxq "$zsh_path" /etc/shells; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "DRY-RUN: append '$zsh_path' to /etc/shells"
    else
      printf '%s\n' "$zsh_path" >> /etc/shells
    fi
  fi

  local current_shell
  current_shell="$(get_user_shell "$user" || echo "")"
  if [[ "$current_shell" == "$zsh_path" ]]; then
    log "Shell already set to zsh for $user"
    return 0
  fi

  log "Setting default shell to zsh for $user ($current_shell -> $zsh_path)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY-RUN: chsh -s '$zsh_path' '$user'"
  else
    chsh -s "$zsh_path" "$user" || warn "chsh failed for $user (maybe restricted)."
  fi
}

install_cron_updater() {
  log "Installing root updater cron (every 30 days, silent): $CRON_FILE"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY-RUN: write $CRON_FILE and state file $CRON_STATE"
    return 0
  fi

  mkdir -p "$(dirname "$CRON_STATE")"

  cat >"$CRON_FILE" <<EOF
#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="$CRON_STATE"
DAYS=30

now=\$(date +%s)
last=0
if [[ -f "\$STATE_FILE" ]]; then
  last=\$(cat "\$STATE_FILE" 2>/dev/null || echo 0)
fi

if ! [[ "\$last" =~ ^[0-9]+$ ]]; then
  last=0
fi

if (( now - last < DAYS*24*3600 )); then
  exit 0
fi

# update shared OMZ + plugins (silent)
cd "$INSTALL_DIR" && git fetch --prune >/dev/null 2>&1 && git pull --ff-only >/dev/null 2>&1 || true

for d in "$PLUGINS_DIR"/*; do
  [[ -d "\$d/.git" ]] || continue
  (cd "\$d" && git fetch --prune >/dev/null 2>&1 && git pull --ff-only >/dev/null 2>&1) || true
done

date +%s > "\$STATE_FILE"
exit 0
EOF

  chmod 0755 "$CRON_FILE"
}

main() {
  need_root
  acquire_lock
  parse_args "$@"

  install_packages
  ensure_shared_omz
  ensure_shared_plugins
  install_cron_updater

  mapfile -t users < <(list_target_users)
  [[ "${#users[@]}" -gt 0 ]] || die "No users selected."

  log "Target users: ${users[*]}"
  for u in "${users[@]}"; do
    if getent passwd "$u" >/dev/null; then
      home="$(get_user_home "$u" || true)"
      write_user_zshrc "$u" "$home"
      if [[ "$CHSH_ENABLE" -eq 1 ]]; then
        set_default_shell "$u"
      else
        log "Skipping chsh for $u (--no-chsh)"
      fi
    else
      warn "User not found: $u"
    fi
  done

  log "Done. Users should re-login (or start a new shell) to use zsh."
  log "Shared install: $INSTALL_DIR"
  log "Plugins:        $PLUGINS_DIR"
  log "Updater cron:   $CRON_FILE (effective every 30 days)"
}

main "$@"
