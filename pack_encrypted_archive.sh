#!/usr/bin/env bash
set -euo pipefail

APP_NAME="nfs"
APP_USER="nfs"
APP_DIR="/opt/nfs"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
PORT="${PORT:-8082}"
BIND_HOST="${BIND_HOST:-0.0.0.0}"
ARCHIVE_NAME="${1:-nfs-project.tar.gz.enc}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${ARCHIVE_NAME}" = /* ]]; then
  ARCHIVE_PATH="${ARCHIVE_NAME}"
else
  ARCHIVE_PATH="${ROOT_DIR}/${ARCHIVE_NAME}"
fi

if ! command -v tar >/dev/null 2>&1; then
  echo "tar is required"
  exit 1
fi

if ! command -v gzip >/dev/null 2>&1; then
  echo "gzip is required"
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl is required"
  exit 1
fi

cd "${ROOT_DIR}"

install_project() {
  local source_dir="$1"

  echo "[install 1/6] Installing dependencies"
  apt-get update
  apt-get install -y ca-certificates curl git rsync build-essential golang-go nodejs npm

  echo "[install 2/6] Creating service user and app directory"
  if ! id -u "${APP_USER}" >/dev/null 2>&1; then
    useradd --system --home "${APP_DIR}" --shell /usr/sbin/nologin "${APP_USER}"
  fi
  mkdir -p "${APP_DIR}"

  if systemctl is-active --quiet "${APP_NAME}"; then
    systemctl stop "${APP_NAME}"
  fi

  echo "[install 3/6] Copying project files"
  rsync -a --delete \
    --exclude node_modules \
    --exclude .git \
    --exclude auth_config.json \
    --exclude server.crt \
    --exclude server.key \
    --exclude nfs \
    --exclude '*.tar.gz.enc' \
    "${source_dir}/" "${APP_DIR}/"

  cd "${APP_DIR}"

  echo "[install 4/6] Building frontend and backend"
  npm install
  npm run build
  go mod download
  go build -trimpath -ldflags "-s -w" -o nfs .
  chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}"
  chmod 750 "${APP_DIR}"
  chmod 750 "${APP_DIR}/nfs"

  echo "[install 5/6] Installing systemd service"
  cat > "${SERVICE_FILE}" <<SERVICE
[Unit]
Description=Need for Speed Underground
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
Environment=PORT=${PORT}
Environment=BIND_HOST=${BIND_HOST}
ExecStart=${APP_DIR}/nfs
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${APP_DIR}

[Install]
WantedBy=multi-user.target
SERVICE

  systemctl daemon-reload
  systemctl enable "${APP_NAME}"
  systemctl restart "${APP_NAME}"

  echo "[install 6/6] Service started"
  echo
  echo "Open the QR from logs:"
  echo "  sudo journalctl -u ${APP_NAME} -n 120 --no-pager"
  echo
  echo "URL: https://<server-ip>:${PORT}/<current-otp>"
  echo "Unauthenticated / and /static/* return empty 404."
}

if [[ -f "${ARCHIVE_PATH}" ]]; then
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Archive found: ${ARCHIVE_PATH}"
    echo "Run as root to install it: sudo bash $0 ${ARCHIVE_PATH}"
    exit 1
  fi
  echo "Archive found: ${ARCHIVE_PATH}"
  echo "Switching to install mode"

  apt-get update
  apt-get install -y ca-certificates tar gzip openssl

  WORK_DIR="$(mktemp -d /tmp/nfs-install.XXXXXX)"
  cleanup_install() {
    rm -rf "${WORK_DIR}"
  }
  trap cleanup_install EXIT

  read -rsp "Archive password: " ARCHIVE_PASSWORD
  echo

  openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -in "${ARCHIVE_PATH}" -pass "pass:${ARCHIVE_PASSWORD}" | tar -xzf - -C "${WORK_DIR}"
  install_project "${WORK_DIR}"
  exit 0
fi

TEMP_ARCHIVE="$(mktemp "${TMPDIR:-/tmp}/nfs-project.XXXXXX.tar.gz.enc")"
cleanup() {
  rm -f "${TEMP_ARCHIVE}"
}
trap cleanup EXIT

ARCHIVE_PASSWORD="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 30)"

if [[ "${#ARCHIVE_PASSWORD}" -ne 30 ]]; then
  echo "Failed to generate a 30-character password"
  exit 1
fi

tar \
  --exclude='./node_modules' \
  --exclude='./.git' \
  --exclude='./auth_config.json' \
  --exclude='./server.crt' \
  --exclude='./server.key' \
  --exclude='./nfs' \
  --exclude='./nfs.service' \
  --exclude='./install_from_archive.sh' \
  --exclude='./install_ubuntu_service.sh' \
  --exclude='./uninstall_nfs.sh' \
  --exclude='./*.tar.gz.enc' \
  --exclude='./*.7z' \
  --exclude='./*.log' \
  --exclude='./dist' \
  -czf - . | openssl enc -aes-256-cbc -salt -pbkdf2 -iter 200000 -out "${TEMP_ARCHIVE}" -pass "pass:${ARCHIVE_PASSWORD}"

mv "${TEMP_ARCHIVE}" "${ARCHIVE_PATH}"
trap - EXIT

echo "Created encrypted archive: ${ARCHIVE_PATH}"
echo "Archive password: ${ARCHIVE_PASSWORD}"
echo "Save this password now. It is not stored anywhere."