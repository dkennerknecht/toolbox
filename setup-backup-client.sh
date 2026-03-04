#!/usr/bin/env bash
set -euo pipefail

REPO_FILE="/etc/apt/sources.list.d/pbs-client.list"
KEYRING="/usr/share/keyrings/proxmox-archive-keyring.gpg"
KEY_URL_BASE="https://enterprise.proxmox.com/debian"
CONFIG_DIR="${HOME}/.config/proxmox-backup"
CLIENT_CONF="${CONFIG_DIR}/client.conf"
EXAMPLE_BACKUP_SCRIPT="/usr/local/bin/pbs-backup-root"

SUPPORTED_SUITES=("bookworm" "bullseye" "trixie")
REPO_SUITE=""
CLIENT_PACKAGE=""
DISTRO=""
CODENAME=""
ARCH=""
OVERRIDE_SUITE=""
OVERRIDE_CLIENT_PACKAGE=""

log()  { echo "[$(date +'%F %T')] $*"; }
warn() { echo "[$(date +'%F %T')] WARN: $*" >&2; }
die()  { echo "[$(date +'%F %T')] ERROR: $*" >&2; exit 1; }

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run as root (use sudo)."
}

have() {
  command -v "$1" >/dev/null 2>&1
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local answer=""
  read -r -p "${prompt} [${default}]: " answer
  answer="${answer:-$default}"
  [[ "${answer}" =~ ^[Yy]$ ]]
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --suite)
        OVERRIDE_SUITE="${2:-}"
        [[ -n "${OVERRIDE_SUITE}" ]] || die "--suite requires a value."
        shift 2
        ;;
      --client-package)
        OVERRIDE_CLIENT_PACKAGE="${2:-}"
        [[ -n "${OVERRIDE_CLIENT_PACKAGE}" ]] || die "--client-package requires a value."
        shift 2
        ;;
      -h|--help)
        cat <<'EOF'
Usage:
  sudo bash setup-backup-client.sh [options]

Options:
  --suite <name>           Override PBS APT suite (bookworm|bullseye|trixie)
  --client-package <name>  Override package (proxmox-backup-client or proxmox-backup-client-static)
  -h, --help               Show this help
EOF
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

detect_os() {
  log "Detecting OS..."

  [[ -f /etc/os-release ]] || die "Cannot detect OS (/etc/os-release missing)."
  # shellcheck disable=SC1091
  . /etc/os-release

  DISTRO="${ID:-unknown}"
  CODENAME="${VERSION_CODENAME:-}"
  ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"

  if [[ -z "${CODENAME}" ]] && have lsb_release; then
    CODENAME="$(lsb_release -cs 2>/dev/null || true)"
  fi

  [[ -n "${CODENAME}" ]] || die "Could not determine distro codename."
  [[ "${ARCH}" == "amd64" || "${ARCH}" == "x86_64" ]] || die "Unsupported architecture '${ARCH}'. Proxmox PBS client repository currently publishes amd64 packages only."

  log "Detected: ${DISTRO} ${CODENAME} (${ARCH})"

  REPO_SUITE="${OVERRIDE_SUITE:-${PBS_REPO_SUITE:-${CODENAME}}}"
  if [[ "${REPO_SUITE}" != "${CODENAME}" ]]; then
    if [[ -n "${OVERRIDE_SUITE}" ]]; then
      warn "Using override suite '${REPO_SUITE}' from --suite (detected codename: '${CODENAME}')."
    else
      warn "Using override suite '${REPO_SUITE}' from PBS_REPO_SUITE (detected codename: '${CODENAME}')."
    fi
  fi

  local supported=0
  local name
  for name in "${SUPPORTED_SUITES[@]}"; do
    if [[ "${name}" == "${REPO_SUITE}" ]]; then
      supported=1
      break
    fi
  done

  if [[ "${supported}" -eq 0 ]]; then
    die "Unsupported PBS APT suite '${REPO_SUITE}' (detected '${CODENAME}'). Supported suites: ${SUPPORTED_SUITES[*]}. For unsupported hosts (for example Ubuntu noble), explicitly set PBS_REPO_SUITE=trixie. Remove ${REPO_FILE} if it contains an invalid suite."
  fi

  if [[ -n "${OVERRIDE_CLIENT_PACKAGE}" ]]; then
    CLIENT_PACKAGE="${OVERRIDE_CLIENT_PACKAGE}"
  elif [[ -n "${PBS_CLIENT_PACKAGE:-}" ]]; then
    CLIENT_PACKAGE="${PBS_CLIENT_PACKAGE}"
  elif [[ "${DISTRO}" == "debian" && "${REPO_SUITE}" == "${CODENAME}" ]]; then
    CLIENT_PACKAGE="proxmox-backup-client"
  else
    # Cross-distro/suite installs are more robust with static linking.
    CLIENT_PACKAGE="proxmox-backup-client-static"
  fi

  log "Selected client package: ${CLIENT_PACKAGE}"
}

install_requirements() {
  have apt-get || die "This script currently supports apt-based systems only."

  log "Installing required packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y curl ca-certificates gnupg
}

prepare_repo_file_for_bootstrap() {
  local desired_line backup_file
  desired_line="deb [signed-by=${KEYRING}] http://download.proxmox.com/debian/pbs-client ${REPO_SUITE} main"

  [[ -f "${REPO_FILE}" ]] || return 0

  if grep -qxF "${desired_line}" "${REPO_FILE}"; then
    return 0
  fi

  backup_file="${REPO_FILE}.bak.$(date +%s)"
  warn "Existing ${REPO_FILE} does not match target suite '${REPO_SUITE}'."
  warn "Temporarily disabling old file to avoid apt update failures: ${backup_file}"
  mv "${REPO_FILE}" "${backup_file}"
}

install_keyring() {
  if [[ -f "${KEYRING}" ]]; then
    log "Proxmox keyring already present at ${KEYRING}"
    return
  fi

  local key_url tmp_key
  key_url="${KEY_URL_BASE}/proxmox-release-${REPO_SUITE}.gpg"
  tmp_key="$(mktemp)"

  log "Installing Proxmox keyring from ${key_url}"
  if ! curl -fsSL "${key_url}" -o "${tmp_key}"; then
    rm -f "${tmp_key}"
    die "Failed to download keyring for suite '${REPO_SUITE}'."
  fi

  install -D -m 0644 "${tmp_key}" "${KEYRING}"
  rm -f "${tmp_key}"
}

configure_repo() {
  local repo_line
  repo_line="deb [signed-by=${KEYRING}] http://download.proxmox.com/debian/pbs-client ${REPO_SUITE} main"

  log "Configuring repository..."
  if [[ -f "${REPO_FILE}" ]] && grep -qxF "${repo_line}" "${REPO_FILE}"; then
    log "Repository file already configured."
  else
    printf '%s\n' "${repo_line}" > "${REPO_FILE}"
    log "Wrote ${REPO_FILE}"
  fi
}

install_client() {
  log "Updating package lists..."
  apt-get update

  log "Installing ${CLIENT_PACKAGE}..."
  if apt-get install -y "${CLIENT_PACKAGE}"; then
    return 0
  fi

  if [[ "${CLIENT_PACKAGE}" == "proxmox-backup-client" ]]; then
    warn "Failed to install proxmox-backup-client; retrying with proxmox-backup-client-static."
    apt-get install -y proxmox-backup-client-static
  else
    die "Failed to install ${CLIENT_PACKAGE}."
  fi
}

configure_repository() {
  local pbs_host pbs_datastore pbs_user repo pbs_pass

  echo
  read -r -p "PBS Server (hostname or IP): " pbs_host
  read -r -p "Datastore: " pbs_datastore
  read -r -p "User (example root@pam): " pbs_user

  [[ -n "${pbs_host}" ]] || die "PBS host is required."
  [[ -n "${pbs_datastore}" ]] || die "Datastore is required."
  [[ -n "${pbs_user}" ]] || die "PBS user is required."

  repo="${pbs_user}@${pbs_host}:${pbs_datastore}"

  echo
  echo "Repository will be:"
  echo "${repo}"
  echo

  install -d -m 0700 "${CONFIG_DIR}"
  umask 077
  cat > "${CLIENT_CONF}" <<EOF
repository: ${repo}
EOF
  chmod 0600 "${CLIENT_CONF}"

  read -r -s -p "PBS Password: " pbs_pass
  echo
  [[ -n "${pbs_pass}" ]] || die "Password cannot be empty."

  export PBS_PASSWORD="${pbs_pass}"

  echo
  log "Testing connection..."
  if proxmox-backup-client list --repository "${repo}"; then
    echo
    log "Connection successful."
  else
    echo
    warn "Connection failed. Check credentials or server."
  fi

  unset PBS_PASSWORD
  pbs_pass=""

  echo
  if prompt_yes_no "Create example backup command script?" "N"; then
    {
      echo "#!/usr/bin/env bash"
      echo "set -euo pipefail"
      printf 'REPO=%q\n' "${repo}"
      cat <<'EOF'
if [[ -z "${PBS_PASSWORD:-}" ]]; then
  read -r -s -p "PBS Password: " PBS_PASSWORD
  echo
  export PBS_PASSWORD
fi

exec proxmox-backup-client backup \
  root.pxar:/ \
  etc.pxar:/etc \
  --repository "${REPO}"
EOF
    } > "${EXAMPLE_BACKUP_SCRIPT}"

    chmod 0700 "${EXAMPLE_BACKUP_SCRIPT}"

    echo
    log "Example backup script created:"
    echo "${EXAMPLE_BACKUP_SCRIPT}"
  fi
}

main() {
  parse_args "$@"
  need_root
  detect_os
  prepare_repo_file_for_bootstrap
  install_requirements
  install_keyring
  configure_repo
  install_client

  echo
  log "Client installed successfully."
  echo

  if [[ -t 0 && -t 1 ]]; then
    if prompt_yes_no "Do you want to configure a PBS repository now?" "N"; then
      configure_repository
    fi
  else
    warn "Non-interactive session detected. Skipping repository setup prompts."
  fi

  echo
  log "Setup complete."
}

main "$@"
