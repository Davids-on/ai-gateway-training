#!/usr/bin/env bash
# =============================================================================
# prepare.sh – full server preparation for the AI stack (LiteLLM + Open WebUI)
#              WITHOUT starting the stack itself.
#
# What the script does (matches sections 4–6 of the guide docs/navod.md):
#   1. checks the OS, free disk space and ports
#   2. system update (apt upgrade), base packages, time zone, port check
#      (works on a minimized Ubuntu Server install – every command the script
#      needs beyond the "required"/"important" packages is installed first)
#   3. Docker Engine + Compose from the official repository (GPG fingerprint check)
#   4. adds the user to the docker group
#   5. /opt/ai-stack: docker-compose.yml, config.yaml, .env.example
#   6. .env with generated secrets (existing values are NEVER overwritten)
#   7. validates compose and pulls ALL images (docker compose pull + alpine)
#
# What the script does NOT do: start the stack containers (docker compose up),
# create the Open WebUI virtual key (LiteLLM must be running for that), reboot
# the server, or upgrade an already installed Docker (that would restart all
# running containers).
#
# Usage (on the server, as a regular user with sudo, from the deploy/ directory):
#   sudo ./prepare.sh                 # everything, asks for the OpenRouter API key
#   sudo ./prepare.sh --skip-upgrade  # skip apt upgrade (saves time/bandwidth)
#   sudo ./prepare.sh --no-extras     # skip the optional troubleshooting tools
#   sudo ./prepare.sh --help
#
# The script is idempotent – it can be re-run (e.g. after an interrupted download).
# =============================================================================
set -Eeuo pipefail

# --- Settings ---------------------------------------------------------------
STACK_DIR=/opt/ai-stack
TZ_NAME=Europe/Prague
# Docker GPG key fingerprint as published at https://docs.docker.com/engine/install/ubuntu/
DOCKER_GPG_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
# Images outside compose that the guide uses (backup/restore, section 8.4)
EXTRA_IMAGES=(alpine:3.24.3)
MIN_FREE_GB=15
# Packages the script and the guide need (missing on a minimized install):
#   curl, ca-certificates – Docker GPG key, API tests;  gnupg – key fingerprint check
#   jq – JSON output;  openssl – secrets;  iproute2 – ss/ip;  tzdata – time zones
BASE_PACKAGES=(ca-certificates curl gnupg jq openssl iproute2 tzdata)
# Optional troubleshooting tools for the training (--no-extras skips them):
#   ping, dig/nslookup, less, nano, git (clone the training repository)
EXTRA_PACKAGES=(iputils-ping bind9-dnsutils less nano git)
LOG=/var/log/ai-stack-prepare.log

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SKIP_UPGRADE=0
INSTALL_EXTRAS=1
TARGET_USER=${SUDO_USER:-}

# --- Helpers ----------------------------------------------------------------
c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'; c_hd=$'\e[1;36m'; c_0=$'\e[0m'
step() { printf '\n%s==> %s%s\n' "$c_hd" "$*" "$c_0"; }
ok()   { printf '%s  [OK]%s %s\n' "$c_ok" "$c_0" "$*"; }
warn() { printf '%s  [WARN]%s %s\n' "$c_warn" "$c_0" "$*"; WARNINGS+=("$*"); }
die()  { printf '%s  [ERROR]%s %s\n' "$c_err" "$c_0" "$*" >&2; exit 1; }
WARNINGS=()

trap 'printf "%s  [ERROR]%s Script failed at line %s: %s\n" "$c_err" "$c_0" "$LINENO" "$BASH_COMMAND" >&2' ERR

usage() {
  sed -n '3,/^# =====/p' "$0" | sed '$d; s/^# \{0,1\}//'
  exit 0
}

APT=(apt-get -y -q -o DPkg::Lock::Timeout=600
     -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
export DEBIAN_FRONTEND=noninteractive

is_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

retry() {  # retry <attempts> <command…>
  local n=$1; shift
  for ((i = 1; i <= n; i++)); do
    "$@" && return 0
    warn "Attempt $i/$n failed: $*"; sleep $((i * 10))
  done
  return 1
}

# --- Arguments --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-upgrade) SKIP_UPGRADE=1 ;;
    --no-extras) INSTALL_EXTRAS=0 ;;
    --user) TARGET_USER=${2:?--user requires a user name}; shift ;;
    -h|--help) usage ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || die "Run with sudo:  sudo $0"
[[ -n $TARGET_USER && $TARGET_USER != root ]] \
  || die "Cannot determine the regular user. Run as 'sudo $0' (not from a root shell) or use --user NAME."
id "$TARGET_USER" >/dev/null 2>&1 || die "User $TARGET_USER does not exist."
for f in docker-compose.yml config.yaml .env.example; do
  [[ -f $SCRIPT_DIR/$f ]] || die "Missing $SCRIPT_DIR/$f – run the script from the repository's deploy/ directory."
done

# Mirror all output to a log file (the API key is never printed, read -s hides it)
touch "$LOG" && chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1
echo "=== $(date -Is) prepare.sh, user: $TARGET_USER ==="

# =============================================================================
step "0/7 Pre-flight checks"
# =============================================================================
. /etc/os-release
if [[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 24.04 ]]; then
  ok "$PRETTY_NAME"
else
  warn "The script is tested on Ubuntu 24.04, this is: ${PRETTY_NAME:-unknown OS}"
fi

free_gb=$(df -BG --output=avail /var | tail -1 | tr -dc '0-9')
if (( free_gb < MIN_FREE_GB )); then
  die "Only ${free_gb} GB free on /var, at least ${MIN_FREE_GB} GB required (images take ~9 GB)."
fi
ok "Free space on /var: ${free_gb} GB"

mem_gb=$(awk '/MemTotal/{printf "%.1f", $2/1048576}' /proc/meminfo)
ok "RAM: ${mem_gb} GB (recommended 8 GB, minimum ~4 GB + swap)"

# =============================================================================
step "1/7 System update, packages, time zone, ports"
# =============================================================================
retry 3 "${APT[@]}" update
if (( SKIP_UPGRADE )); then
  warn "apt upgrade skipped (--skip-upgrade)"
else
  # Temporarily hold an already installed Docker – upgrading it restarts the
  # daemon and every running container. Docker is upgraded deliberately, outside this script.
  held=()
  for pkg in docker-ce docker-ce-cli docker-ce-rootless-extras containerd.io \
             docker-buildx-plugin docker-compose-plugin; do
    if is_installed "$pkg" && ! apt-mark showhold | grep -qx "$pkg"; then held+=("$pkg"); fi
  done
  if (( ${#held[@]} )); then
    apt-mark hold "${held[@]}" >/dev/null
    ok "Docker packages temporarily held: ${held[*]}"
  fi
  if ! "${APT[@]}" upgrade; then
    (( ${#held[@]} )) && apt-mark unhold "${held[@]}" >/dev/null
    die "apt upgrade failed"
  fi
  if (( ${#held[@]} )); then apt-mark unhold "${held[@]}" >/dev/null; fi
  ok "System updated"
fi

# --no-upgrade: install only what is missing, never upgrade as a side effect
"${APT[@]}" install --no-upgrade "${BASE_PACKAGES[@]}"
ok "Base packages: ${BASE_PACKAGES[*]}"
if (( INSTALL_EXTRAS )); then
  "${APT[@]}" install --no-upgrade "${EXTRA_PACKAGES[@]}"
  ok "Troubleshooting tools: ${EXTRA_PACKAGES[*]}"
else
  warn "Troubleshooting tools skipped (--no-extras)"
fi

timedatectl set-timezone "$TZ_NAME"
ok "Time zone: $(timedatectl show -p Timezone --value)"

# Port check (needs ss from iproute2, installed above)
for p in 3000 4000; do
  if ss -Htln "sport = :$p" | grep -q .; then
    # The port may be held by an already running ai-stack – that is fine
    if command -v docker >/dev/null && docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^ai-stack-'; then
      ok "Port $p is used by the running ai-stack"
    else
      warn "Port $p is in use – the stack would fail to start on it: $(ss -Htlnp "sport = :$p" | head -1)"
    fi
  else
    ok "Port $p is free"
  fi
done


# =============================================================================
step "2/7 Docker Engine and Docker Compose (official repository)"
# =============================================================================
# Conflicting packages (Ubuntu docker.io, podman-docker, …) – only if installed
conflicts=()
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  is_installed "$pkg" && conflicts+=("$pkg")
done
if (( ${#conflicts[@]} )); then
  warn "Removing conflicting packages: ${conflicts[*]}"
  "${APT[@]}" remove "${conflicts[@]}"
fi
if command -v snap >/dev/null && snap list docker >/dev/null 2>&1; then
  warn "Removing snap docker"
  snap remove docker
fi

install -m 0755 -d /etc/apt/keyrings
tmpkey=$(mktemp)
retry 3 curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$tmpkey"
fpr=$(gpg --show-keys --with-colons "$tmpkey" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')
[[ $fpr == "$DOCKER_GPG_FPR" ]] || { rm -f "$tmpkey"; die "Docker GPG key fingerprint mismatch: $fpr"; }
install -m 0644 "$tmpkey" /etc/apt/keyrings/docker.asc
rm -f "$tmpkey"
ok "Docker GPG key verified ($DOCKER_GPG_FPR)"

cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
retry 3 "${APT[@]}" update

# --no-upgrade: do NOT upgrade an already installed Docker. Upgrading docker-ce
# restarts the daemon and all running containers – that must be a deliberate step.
"${APT[@]}" install --no-upgrade docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now containerd docker >/dev/null
ok "$(docker version --format 'Docker Client {{.Client.Version}} / Server {{.Server.Version}}')"
ok "$(docker compose version)"

# =============================================================================
step "3/7 Add user $TARGET_USER to the docker group"
# =============================================================================
if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx docker; then
  ok "$TARGET_USER is already in the docker group"
else
  usermod -aG docker "$TARGET_USER"
  ok "$TARGET_USER added to the docker group (takes effect after a new login)"
fi

# =============================================================================
step "4/7 Working directory $STACK_DIR"
# =============================================================================
install -d -o "$TARGET_USER" -g "$TARGET_USER" -m 750 "$STACK_DIR"
for f in docker-compose.yml config.yaml .env.example; do
  dst=$STACK_DIR/$f
  if [[ -f $dst ]] && cmp -s "$SCRIPT_DIR/$f" "$dst"; then
    ok "$f is up to date"
    continue
  fi
  if [[ -f $dst ]]; then
    bak=$dst.bak-$(date +%Y%m%d-%H%M%S)
    cp -p "$dst" "$bak"
    warn "$f differed from the repository – previous version backed up to $bak"
  fi
  install -o "$TARGET_USER" -g "$TARGET_USER" -m 640 "$SCRIPT_DIR/$f" "$dst"
  ok "$f installed"
done

# =============================================================================
step "5/7 Secrets in $STACK_DIR/.env"
# =============================================================================
ENV_FILE=$STACK_DIR/.env
umask 077
if [[ ! -f $ENV_FILE ]]; then
  printf '# AI stack – secrets. Generated by prepare.sh on %s. NEVER commit!\n' "$(date -I)" > "$ENV_FILE"
fi
chown "$TARGET_USER:$TARGET_USER" "$ENV_FILE"
chmod 600 "$ENV_FILE"

env_has()   { grep -q "^$1=" "$ENV_FILE"; }
env_value() { sed -n "s/^$1=//p" "$ENV_FILE" | head -1; }
env_add() {  # add a variable only if it is not in .env yet
  if env_has "$1"; then ok "$1 already exists – keeping it"; else
    printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"; ok "$1 generated"; fi
}
env_set() {  # set a value (replace/append the line); the value goes via ENVIRON, not argv
  if env_has "$1"; then
    V="$2" awk -v k="$1" 'index($0, k "=") == 1 {print k "=" ENVIRON["V"]; next} {print}' \
      "$ENV_FILE" > "$ENV_FILE.tmp" && cat "$ENV_FILE.tmp" > "$ENV_FILE" && rm -f "$ENV_FILE.tmp"
  else
    printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"
  fi
}

# --- OpenRouter API key: ask if missing and running in a terminal -----------
if [[ -n $(env_value OPENROUTER_API_KEY) ]]; then
  ok "OPENROUTER_API_KEY is already set – keeping it"
elif [[ -r /dev/tty ]] && { : < /dev/tty; } 2>/dev/null; then
  printf '\n  Paste the OpenRouter API key (sk-or-v1-…) and press Enter.\n'
  printf '  The key is not displayed. Empty Enter = fill it in later.\n'
  IFS= read -rsp "  OpenRouter API key: " K < /dev/tty; echo
  if [[ -z $K ]]; then
    env_has OPENROUTER_API_KEY || printf 'OPENROUTER_API_KEY=\n' >> "$ENV_FILE"
    warn "OPENROUTER_API_KEY left empty – set it before starting the stack (guide section 6.1)"
  elif LC_ALL=C grep -q '[[:cntrl:][:space:]]' <<<"$K"; then
    env_has OPENROUTER_API_KEY || printf 'OPENROUTER_API_KEY=\n' >> "$ENV_FILE"
    warn "The key contains control characters or spaces (arrow keys, Home…?) – NOT saved, set it manually"
  else
    [[ $K == sk-or-v1-* && ${#K} -eq 73 ]] \
      || warn "The key does not have the expected format (sk-or-v1-…, 73 characters) – please check it"
    env_set OPENROUTER_API_KEY "$K"
    ok "OPENROUTER_API_KEY saved (length ${#K}, prefix ${K:0:9})"
  fi
  unset K
else
  env_has OPENROUTER_API_KEY || printf 'OPENROUTER_API_KEY=\n' >> "$ENV_FILE"
  warn "No terminal – set OPENROUTER_API_KEY manually (guide section 6.1)"
fi

# --- Generated secrets (existing values are never overwritten) --------------
env_add LITELLM_MASTER_KEY "sk-$(openssl rand -hex 32)"
env_add LITELLM_SALT_KEY   "sk-$(openssl rand -hex 32)"
env_add UI_USERNAME        admin
env_add UI_PASSWORD        "$(openssl rand -base64 18 | tr -d '/+=')"
env_add POSTGRES_PASSWORD  "$(openssl rand -hex 24)"
env_add WEBUI_SECRET_KEY   "$(openssl rand -hex 32)"
server_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="src") {print $(i+1); exit}}')
env_add WEBUI_URL          "http://${server_ip:-localhost}:3000"
# The virtual key can only be created once LiteLLM runs (guide section 7.1) – keep it
# empty for now so Open WebUI cannot accidentally start without it (compose refuses).
if ! env_has OPENWEBUI_LITELLM_KEY; then
  printf 'OPENWEBUI_LITELLM_KEY=\n' >> "$ENV_FILE"
  ok "OPENWEBUI_LITELLM_KEY prepared empty (to be filled in after LiteLLM starts)"
elif [[ -n $(env_value OPENWEBUI_LITELLM_KEY) ]]; then
  ok "OPENWEBUI_LITELLM_KEY is already set – keeping it"
else
  ok "OPENWEBUI_LITELLM_KEY is still empty (to be filled in after LiteLLM starts)"
fi
chown "$TARGET_USER:$TARGET_USER" "$ENV_FILE"; chmod 600 "$ENV_FILE"
LC_ALL=C grep -q '[[:cntrl:]]' "$ENV_FILE" && warn ".env contains control characters – please check it"
ok ".env: $(stat -c '%A %U:%G' "$ENV_FILE"), variables: $(cut -d= -f1 "$ENV_FILE" | grep -v '^#' | grep . | tr '\n' ' ')"

# =============================================================================
step "6/7 Validate compose and pull images"
# =============================================================================
cd "$STACK_DIR"
# Empty keys are replaced by a dummy value for validation/pull only (in this
# command's environment, .env is not changed). Otherwise compose refuses the file.
compose() {
  OPENROUTER_API_KEY=x OPENWEBUI_LITELLM_KEY=x docker compose "$@"
}
compose config --quiet
ok "docker-compose.yml is valid"

mapfile -t IMAGES < <(compose config --images)
printf '  Pulling: %s\n' "${IMAGES[@]}" "${EXTRA_IMAGES[@]}"
retry 3 compose pull
for img in "${EXTRA_IMAGES[@]}"; do retry 3 docker pull -q "$img"; done
for img in "${IMAGES[@]}" "${EXTRA_IMAGES[@]}"; do
  docker image inspect "$img" >/dev/null || die "Image $img is missing even after pull"
done
ok "All images are available locally:"
docker image ls --format '      {{.Repository}}:{{.Tag}}  {{.Size}}' \
  | grep -E "$(printf '%s|' "${IMAGES[@]}" "${EXTRA_IMAGES[@]}" | sed 's/|$//; s/\./\\./g')"

# =============================================================================
step "7/7 Verify Docker"
# =============================================================================
[[ $(docker run --rm "${EXTRA_IMAGES[0]}" echo DOCKER_OK) == DOCKER_OK ]] && ok "Test container ran successfully (docker run)"
ok "$(docker info --format 'Storage: {{.Driver}}  Cgroup: {{.CgroupDriver}} v{{.CgroupVersion}}')"
STACK_RUNNING=0
if docker ps --format '{{.Names}}' | grep -q '^ai-stack-'; then
  STACK_RUNNING=1
  warn "ai-stack is already running – the script did not touch it (new images are used only after 'docker compose up -d')"
fi

# =============================================================================
step "Done – summary"
# =============================================================================
if [[ -f /var/run/reboot-required ]]; then
  warn "The system requires a reboot (kernel/libraries): sudo systemctl reboot"
fi
if (( ${#WARNINGS[@]} )); then
  printf '\n%sWarnings:%s\n' "$c_warn" "$c_0"; printf '  - %s\n' "${WARNINGS[@]}"
fi

if (( STACK_RUNNING )); then
  printf '\nPreparation complete. The stack is already running – no further steps needed.\n'
  printf 'Log of this run: %s\n' "$LOG"
  exit 0
fi

cat <<EOF

Preparation complete. The stack is NOT running yet. Next steps (guide sections 6.5 and 7):

  0) Log out and log in again (docker group), or reboot the server.
  1) If OPENROUTER_API_KEY is missing in .env, set it (guide section 6.1).
  2) Start the DB and LiteLLM (OPENWEBUI_LITELLM_KEY is still empty, hence a dummy value):
       cd $STACK_DIR
       OPENWEBUI_LITELLM_KEY=pending docker compose up -d postgres litellm
  3) Create the Open WebUI virtual key (guide section 7.1) and put its value into
     the EXISTING line OPENWEBUI_LITELLM_KEY= in .env (do not add a second line;
     WEBUI_SECRET_KEY and WEBUI_URL have already been generated by this script).
  4) Start the whole stack:  docker compose up -d

Note: on first start Open WebUI still downloads an embedding model from Hugging
Face (~90 MB). Everything else is already downloaded. Log of this run: $LOG
EOF
