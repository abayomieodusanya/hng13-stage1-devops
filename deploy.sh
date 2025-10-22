#!/usr/bin/env bash
set -Eeuo pipefail

# ===== Logging =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"; mkdir -p "${LOG_DIR}"
TS="$(date +'%Y%m%d_%H%M%S')"
LOG_FILE="${LOG_DIR}/deploy_${TS}.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

# ===== Exit codes per stage =====
EC_INPUT=10; EC_GIT=20; EC_SSH=30; EC_REMOTE_PREP=40; EC_DEPLOY=50; EC_NGINX=60; EC_VALIDATE=70; EC_CLEANUP=80

log(){ printf '%s %s\n' "$(date +'%F %T')" "$*"; }
die(){ log "ERROR: $*"; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing command '$1'"; }

ask(){ local L="$1" V="$2" D="${3-}"; [ -n "$D" ] && printf "%s [%s]: " "$L" "$D" || printf "%s: " "$L"; IFS= read -r R || true; [ -z "$R" ] && [ -n "$D" ] && eval "$V=\$D" || eval "$V=\$R"; }
ask_secret(){ local L="$1" V="$2"; printf "%s (hidden): " "$L"; stty -echo; read R; stty echo; printf "\n"; eval "$V=\$R"; }

cleanup_local(){ [ -n "${TMP_CLONE_DIR-}" ] && [ -d "${TMP_CLONE_DIR}" ] && rm -rf "${TMP_CLONE_DIR}" || true; }
trap 'log "Unexpected error at line $LINENO. Log: ${LOG_FILE}"; cleanup_local' ERR INT TERM

# ===== Optional cleanup mode =====
if [ "${1-}" = "--cleanup" ]; then
  ask "SSH username" SSH_USER
  ask "Server IP/DNS" SSH_HOST
  ask "SSH private key path" SSH_KEY "${HOME}/.ssh/id_rsa"
  ask "App name to remove" APP_NAME "app"
  ask "Remote deploy directory" REMOTE_DIR "/opt/app"

  ssh -i "${SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${SSH_USER}@${SSH_HOST}" "echo ok" || die "SSH failed (EC ${EC_SSH})"
  ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=accept-new "${SSH_USER}@${SSH_HOST}" "set -Eeuo pipefail
    if command -v docker >/dev/null 2>&1; then
      docker ps -a --format '{{.Names}}' | grep -qx '${APP_NAME}' && docker rm -f '${APP_NAME}' || true
      if docker compose version >/dev/null 2>&1 || docker-compose --version >/dev/null 2>&1; then
        [ -f '${REMOTE_DIR}/docker-compose.yml' ] && (cd '${REMOTE_DIR}' && (docker compose down || docker-compose down || true))
      fi
      docker network ls --format '{{.Name}}' | grep -qx '${APP_NAME}_net' && docker network rm '${APP_NAME}_net' || true
      imgs=\$(docker image ls --format '{{.Repository}}:{{.Tag}}' | grep '^${APP_NAME}:' || true); [ -n \"\$imgs\" ] && docker rmi -f \$imgs || true
    fi
    sudo rm -f /etc/nginx/sites-enabled/${APP_NAME}.conf /etc/nginx/sites-available/${APP_NAME}.conf || true
    sudo nginx -t >/dev/null 2>&1 && sudo systemctl reload nginx || true
    sudo rm -rf '${REMOTE_DIR}' || true
  " || die "Cleanup failed (EC ${EC_CLEANUP})"

  log "Cleanup complete. Log: ${LOG_FILE}"; exit 0
fi

# ===== Pre-checks =====
need ssh; need scp; need git; need sed; need awk; need grep
RSYNC=""; command -v rsync >/dev/null 2>&1 && RSYNC="rsync"

# ===== 1) Gather inputs =====
log "Collecting inputs…"
ask "Git repository URL (https://... or git@...)" REPO_URL
[ -n "${REPO_URL}" ] || die "Repo URL required (EC ${EC_INPUT})"
ask_secret "GitHub Personal Access Token (PAT) — leave empty if repo is public" PAT
ask "Branch" BRANCH "main"
ask "SSH username" SSH_USER
ask "Server IP/DNS" SSH_HOST
ask "SSH private key path" SSH_KEY "${HOME}/.ssh/id_rsa"; [ -f "${SSH_KEY}" ] || die "SSH key not found (EC ${EC_INPUT})"
ask "App internal container port" APP_PORT "3000"; echo "${APP_PORT}" | grep -Eq '^[0-9]+$' || die "APP_PORT must be a number (EC ${EC_INPUT})"
ask "Remote directory on server" REMOTE_DIR "/opt/app"
ask "App name (container/nginx id)" APP_NAME "app"
ask "Domain for Nginx (or _)" SERVER_NAME "_"; [ -n "${SERVER_NAME}" ] || SERVER_NAME="_"

# ===== 2) SSH dry-run =====
log "Testing SSH…"
ssh -i "${SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${SSH_USER}@${SSH_HOST}" "echo ok" || die "SSH failed (EC ${EC_SSH})"

# ===== 3) Clone repo to a temp dir =====
log "Cloning/updating repo…"
TMP_CLONE_DIR="$(mktemp -d)"
REPO_BASENAME="$(basename "${REPO_URL%.git}")"
LOCAL_REPO_DIR="${TMP_CLONE_DIR}/${REPO_BASENAME}"

CLONE_URL="${REPO_URL}"
case "${REPO_URL}" in
  https://github.com/*) [ -n "${PAT}" ] && CLONE_URL="$(printf '%s' "${REPO_URL}" | sed -E "s#https://#https://${PAT}@#")" ;;
  git@*:* ) : ;; # SSH clone URL; PAT not used
  http*://* ) [ -n "${PAT}" ] && CLONE_URL="$(printf '%s' "${REPO_URL}" | sed -E "s#^(https?://)#\1${PAT}@#")" ;;
esac

if ! git clone --depth=1 -b "${BRANCH}" "${CLONE_URL}" "${LOCAL_REPO_DIR}"; then
  git clone "${CLONE_URL}" "${LOCAL_REPO_DIR}" || die "git clone failed (EC ${EC_GIT})"
  (cd "${LOCAL_REPO_DIR}" && git fetch origin "${BRANCH}" && git checkout "${BRANCH}" && git pull --ff-only) || die "git checkout/pull failed (EC ${EC_GIT})"
fi

# ===== 4) Check Docker artifacts =====
HAS_DF="false"; HAS_DC="false"
[ -f "${LOCAL_REPO_DIR}/Dockerfile" ] && HAS_DF="true"
[ -f "${LOCAL_REPO_DIR}/docker-compose.yml" ] && HAS_DC="true"
[ "${HAS_DF}" = "false" ] && [ "${HAS_DC}" = "false" ] && die "No Dockerfile or docker-compose.yml found (EC ${EC_GIT})"

# ===== 5) Prepare remote (Docker, Compose, Nginx) =====
log "Preparing remote environment…"
ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=accept-new "${SSH_USER}@${SSH_HOST}" "set -Eeuo pipefail
  sudo apt-get update -y
  sudo apt-get install -y ca-certificates curl gnupg lsb-release nginx >/dev/null
  sudo systemctl enable --now nginx
  if ! command -v docker >/dev/null 2>&1; then
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(. /etc/os-release && echo \$VERSION_CODENAME) stable\" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io >/dev/null
    sudo usermod -aG docker ${SSH_USER} || true
    sudo systemctl enable --now docker
  fi
  if ! docker compose version >/dev/null 2>&1; then
    command -v docker-compose >/dev/null 2>&1 || sudo apt-get install -y docker-compose >/dev/null 2>&1 || true
  fi
  sudo mkdir -p '${REMOTE_DIR}'
  sudo chown -R ${SSH_USER}:${SSH_USER} '${REMOTE_DIR}'
"

# ===== 6) Transfer code =====
log "Copying project to remote…"
if [ -n "${RSYNC}" ]; then
  rsync -az --delete -e "ssh -i ${SSH_KEY} -o StrictHostKeyChecking=accept-new" "${LOCAL_REPO_DIR}/" "${SSH_USER}@${SSH_HOST}:${REMOTE_DIR}/"
else
  scp -i "${SSH_KEY}" -o StrictHostKeyChecking=accept-new -r "${LOCAL_REPO_DIR}/." "${SSH_USER}@${SSH_HOST}:${REMOTE_DIR}/"
fi

# ===== 7) Build & run containers =====
log "Deploying containers…"
ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=accept-new "${SSH_USER}@${SSH_HOST}" "set -Eeuo pipefail
  cd '${REMOTE_DIR}'
  if docker ps -a --format '{{.Names}}' | grep -qx '${APP_NAME}'; then
    docker rm -f '${APP_NAME}' || true
  fi
  if [ -f docker-compose.yml ]; then
    if docker compose version >/dev/null 2>&1; then
      docker compose pull || true
      docker compose up -d --build
    else
      docker-compose pull || true
      docker-compose up -d --build
    fi
  else
    docker build -t '${APP_NAME}:latest' .
    docker network ls --format '{{.Name}}' | grep -qx '${APP_NAME}_net' || docker network create '${APP_NAME}_net'
    docker run -d --name '${APP_NAME}' --network '${APP_NAME}_net' -p 127.0.0.1:${APP_PORT}:${APP_PORT} '${APP_NAME}:latest'
  fi
  sleep 2
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
"

# ===== 8) Nginx reverse-proxy on port 80 =====
log "Configuring Nginx…"
ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=accept-new "${SSH_USER}@${SSH_HOST}" "set -Eeuo pipefail
  CONF=/etc/nginx/sites-available/${APP_NAME}.conf
  sudo bash -c \"cat > \$CONF\" <<EOF
server {
    listen 80;
    server_name ${SERVER_NAME};
    client_max_body_size 50m;
    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \\\$host;
        proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \\\$scheme;
        proxy_read_timeout 300;
    }
}
EOF
  sudo ln -sf \"\$CONF\" /etc/nginx/sites-enabled/${APP_NAME}.conf
  [ -f /etc/nginx/sites-enabled/default ] && sudo rm -f /etc/nginx/sites-enabled/default || true
  sudo nginx -t
  sudo systemctl reload nginx
"

# ===== 9) Validate =====
log "Validating…"
ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=accept-new "${SSH_USER}@${SSH_HOST}" "set -Eeuo pipefail
  systemctl is-active --quiet docker
  systemctl is-active --quiet nginx
  docker ps --format '{{.Names}}' | grep -qx '${APP_NAME}'
  curl -sSf http://127.0.0.1/ >/dev/null
  echo 'Validation OK'
"

log "SUCCESS. Visit: http://${SSH_HOST}/"
log "Log file: ${LOG_FILE}"
cleanup_local
