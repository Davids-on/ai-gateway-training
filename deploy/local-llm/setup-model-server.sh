#!/usr/bin/env bash
# =============================================================================
# setup-model-server.sh – complete setup of a DEDICATED model server VM
#                         (Ollama on CPU behind Caddy with a static API key)
#                         shared by all participants in part 2, module G.
#
# Standalone: this one file is enough. docker-compose.yml and Caddyfile are
# embedded below; when the script runs from a repository checkout
# (deploy/local-llm/ next to it), the files from the repository are used instead.
#
# What the script does (matches docs/model-server.md, sections 2–5):
#   1. pre-flight: OS, CPU (AVX2), RAM, free disk, port 11434
#   2. system update, base packages, time zone
#   3. Docker Engine + Compose from the official repository (GPG fingerprint check)
#   4. adds the user to the docker group
#   5. /opt/local-llm: docker-compose.yml, Caddyfile, .env (API key generated,
#      an existing key is kept unless --new-key)
#   6. validates the configuration, pulls the images, starts the stack
#   7. pulls the model, warms it up (loads into RAM), verifies 401 / 200 / chat
#   8. optional: restricts port 11434 to the gateway network (DOCKER-USER chain,
#      persisted by a systemd unit) – only with --allow-cidr or a "yes" at the prompt
#
# Configuration – three ways, highest priority first:
#   a) command-line options (below)
#   b) interactive prompts (Enter keeps the offered value; skipped with --yes
#      or without a terminal)
#   c) values already in /opt/local-llm/.env (re-run keeps your previous choice)
#   d) the "Settings" block below – edit it before running the script
#
# Usage (on the model server VM, as a regular user with sudo):
#   sudo ./setup-model-server.sh                      # asks for the values
#   sudo ./setup-model-server.sh --yes                # no questions, defaults/.env
#   sudo ./setup-model-server.sh --model qwen3:8b --parallel 2 --yes
#   sudo ./setup-model-server.sh --allow-cidr 192.0.2.0/24 --yes
#   sudo ./setup-model-server.sh --new-key --yes      # rotate the API key (after training)
#   sudo ./setup-model-server.sh --show-key           # print the API key at the end
#
# Options:
#   --model TAG          Ollama model tag                      (default: see Settings)
#   --parallel N         OLLAMA_NUM_PARALLEL (parallel slots)
#   --context N          OLLAMA_CONTEXT_LENGTH (tokens per slot)
#   --keep-alive DUR     OLLAMA_KEEP_ALIVE (e.g. 24h)
#   --allow-cidr LIST    comma-separated networks allowed to reach port 11434
#                        ("none" = do not touch the firewall)
#   --new-key            generate a new LOCAL_LLM_API_KEY (gateways must be updated)
#   --show-key           print the API key in the summary (default: hidden)
#   --skip-upgrade       skip apt upgrade
#   --no-model           do not pull/warm up the model (only the stack)
#   --user NAME          regular user for the docker group / file owner
#   -y, --yes            non-interactive, no prompts
#   -h, --help           this help
#
# The script is idempotent – it can be re-run (e.g. to change the model or the
# number of slots). Secrets never appear on screen or in the log unless --show-key.
# =============================================================================
set -Eeuo pipefail

# --- Settings (edit here) ---------------------------------------------------
LLM_DIR=/opt/local-llm
MODEL=qwen3:4b-instruct          # docs/model-server.md, section 2.2
NUM_PARALLEL=4                   # 8 vCPU / 16 GB; reference lab (2 vCPU) uses 2
CONTEXT_LENGTH=8192
KEEP_ALIVE=24h
ALLOW_CIDR=none                  # e.g. 192.0.2.0/24 or "192.0.2.0/24,198.51.100.0/24"
TZ_NAME=Europe/Prague
LLM_PORT=11434                   # published by Caddy (fixed in docker-compose.yml)
MIN_FREE_GB=20                   # images ~3.5 GB + model(s) + headroom
DOCKER_GPG_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88  # docs.docker.com/engine/install/ubuntu/
BASE_PACKAGES=(ca-certificates curl gnupg jq openssl iproute2 iptables tzdata)
LOG=/var/log/local-llm-setup.log
FW_SCRIPT=/usr/local/sbin/local-llm-firewall.sh
FW_UNIT=/etc/systemd/system/local-llm-firewall.service

# --- Internal state ---------------------------------------------------------
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TARGET_USER=${SUDO_USER:-}
SKIP_UPGRADE=0; NO_MODEL=0; NEW_KEY=0; SHOW_KEY=0; ASSUME_YES=0
declare -A GIVEN=()   # settings given on the command line (not asked again)

# --- Helpers ----------------------------------------------------------------
c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'; c_hd=$'\e[1;36m'; c_0=$'\e[0m'
step() { printf '\n%s==> %s%s\n' "$c_hd" "$*" "$c_0"; }
ok()   { printf '%s  [OK]%s %s\n' "$c_ok" "$c_0" "$*"; }
warn() { printf '%s  [WARN]%s %s\n' "$c_warn" "$c_0" "$*"; WARNINGS+=("$*"); }
die()  { printf '%s  [ERROR]%s %s\n' "$c_err" "$c_0" "$*" >&2; exit 1; }
WARNINGS=()
trap 'printf "%s  [ERROR]%s Script failed at line %s: %s\n" "$c_err" "$c_0" "$LINENO" "$BASH_COMMAND" >&2' ERR

usage() { sed -n '3,/^# =====/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0; }

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

valid_int()  { [[ $1 =~ ^[1-9][0-9]*$ ]]; }
valid_dur()  { [[ $1 =~ ^(-1|[0-9]+[smh]?)$ ]] || [[ $1 =~ ^([0-9]+h)?([0-9]+m)?([0-9]+s)?$ && -n $1 ]]; }
valid_tag()  { [[ $1 =~ ^[a-z0-9][a-z0-9._/-]*(:[A-Za-z0-9._-]+)?$ ]]; }
valid_cidr() {
  [[ $1 == none ]] && return 0
  local c IFS=,
  for c in $1; do
    [[ $c =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(/([0-9]{1,2}))?$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1:4}"; do (( 10#$o <= 255 )) || return 1; done
    [[ -z ${BASH_REMATCH[6]} ]] || (( 10#${BASH_REMATCH[6]} <= 32 )) || return 1
  done
}

set_opt() {  # set_opt VAR value validator
  "$3" "$2" || die "Invalid value for ${1,,}: '$2'"
  printf -v "$1" '%s' "$2"; GIVEN[$1]=1
}

# --- Arguments --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case $1 in
    --model)        set_opt MODEL          "${2:?--model requires a value}"      valid_tag;  shift ;;
    --parallel)     set_opt NUM_PARALLEL   "${2:?--parallel requires a value}"   valid_int;  shift ;;
    --context)      set_opt CONTEXT_LENGTH "${2:?--context requires a value}"    valid_int;  shift ;;
    --keep-alive)   set_opt KEEP_ALIVE     "${2:?--keep-alive requires a value}" valid_dur;  shift ;;
    --allow-cidr)   set_opt ALLOW_CIDR     "${2:?--allow-cidr requires a value}" valid_cidr; shift ;;
    --new-key)      NEW_KEY=1 ;;
    --show-key)     SHOW_KEY=1 ;;
    --skip-upgrade) SKIP_UPGRADE=1 ;;
    --no-model)     NO_MODEL=1 ;;
    --user)         TARGET_USER=${2:?--user requires a user name}; shift ;;
    -y|--yes)       ASSUME_YES=1 ;;
    -h|--help)      usage ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || die "Run with sudo:  sudo $0"
[[ -n $TARGET_USER && $TARGET_USER != root ]] \
  || die "Cannot determine the regular user. Run as 'sudo $0' (not from a root shell) or use --user NAME."
id "$TARGET_USER" >/dev/null 2>&1 || die "User $TARGET_USER does not exist."

HAVE_TTY=0
if (( ! ASSUME_YES )) && [[ -r /dev/tty ]] && { : < /dev/tty; } 2>/dev/null; then HAVE_TTY=1; fi

# --- Values from an existing .env (re-run keeps the previous choice) --------
ENV_FILE=$LLM_DIR/.env
env_has()   { [[ -f $ENV_FILE ]] && grep -q "^$1=" "$ENV_FILE"; }
env_value() { [[ -f $ENV_FILE ]] && sed -n "s/^$1=//p" "$ENV_FILE" | head -1; }
from_env() {  # from_env VAR ENV_KEY – take the .env value unless given on the command line
  local v
  [[ -n ${GIVEN[$1]:-} ]] && return 0
  v=$(env_value "$2" || true)
  [[ -n $v ]] && printf -v "$1" '%s' "$v"
  return 0
}
from_env MODEL          LOCAL_LLM_MODEL
from_env NUM_PARALLEL   OLLAMA_NUM_PARALLEL
from_env CONTEXT_LENGTH OLLAMA_CONTEXT_LENGTH
from_env KEEP_ALIVE     OLLAMA_KEEP_ALIVE
from_env ALLOW_CIDR     LOCAL_LLM_ALLOW_CIDR

# --- Interactive prompts (only what was not given on the command line) -----
ask() {  # ask VAR "question" validator
  local var=$1 q=$2 check=$3 ans
  [[ -n ${GIVEN[$var]:-} ]] && return 0
  (( HAVE_TTY )) || return 0
  while true; do
    IFS= read -rp "  $q [${!var}]: " ans < /dev/tty || ans=
    [[ -z $ans ]] && return 0
    if "$check" "$ans"; then printf -v "$var" '%s' "$ans"; return 0; fi
    printf '  Invalid value, try again.\n'
  done
}
if (( HAVE_TTY )); then
  printf '\n%sModel server configuration%s (Enter = keep the value in brackets)\n' "$c_hd" "$c_0"
  ask MODEL          "Ollama model tag"                                  valid_tag
  ask NUM_PARALLEL   "Parallel requests (OLLAMA_NUM_PARALLEL)"           valid_int
  ask CONTEXT_LENGTH "Context length per request in tokens"              valid_int
  ask KEEP_ALIVE     "Keep model in RAM after last request"              valid_dur
  ask ALLOW_CIDR     "Networks allowed to port $LLM_PORT (CIDR list, 'none' = no firewall change)" valid_cidr
fi

# Mirror all output to a log file (the API key is never printed unless --show-key)
touch "$LOG" && chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1
echo "=== $(date -Is) setup-model-server.sh, user: $TARGET_USER ==="
printf '  model=%s parallel=%s context=%s keep_alive=%s allow_cidr=%s dir=%s\n' \
  "$MODEL" "$NUM_PARALLEL" "$CONTEXT_LENGTH" "$KEEP_ALIVE" "$ALLOW_CIDR" "$LLM_DIR"

# =============================================================================
step "1/8 Pre-flight checks"
# =============================================================================
. /etc/os-release
if [[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 24.04 ]]; then ok "$PRETTY_NAME"
else warn "The script is tested on Ubuntu 24.04, this is: ${PRETTY_NAME:-unknown OS}"; fi

ok "CPU: $(nproc) vCPU, $(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo)"
if grep -q -m1 -w avx2 /proc/cpuinfo; then
  ok "AVX2 available$(grep -q -m1 -w avx512f /proc/cpuinfo && echo ', AVX-512 available')"
else
  warn "CPU has no AVX2 – inference will be very slow. Set the VM CPU model to host/host-passthrough (docs/model-server.md, 2.1)."
fi

mem_gb=$(awk '/MemTotal/{printf "%.0f", $2/1048576}' /proc/meminfo)
if (( mem_gb < 8 )); then
  warn "RAM: ${mem_gb} GB – too little for $MODEL with $NUM_PARALLEL slots (recommended 16 GB)"
else
  ok "RAM: ${mem_gb} GB (recommended 16 GB for 4 slots)"
fi

mkdir -p /var/lib/docker 2>/dev/null || true
free_gb=$(df -BG --output=avail /var/lib/docker | tail -1 | tr -dc '0-9')
(( free_gb >= MIN_FREE_GB )) || die "Only ${free_gb} GB free for /var/lib/docker, at least ${MIN_FREE_GB} GB required."
ok "Free space for /var/lib/docker: ${free_gb} GB"

# =============================================================================
step "2/8 System update, packages, time zone"
# =============================================================================
retry 3 "${APT[@]}" update
if (( SKIP_UPGRADE )); then
  warn "apt upgrade skipped (--skip-upgrade)"
else
  # Hold an already installed Docker – upgrading it restarts every container.
  held=()
  for pkg in docker-ce docker-ce-cli docker-ce-rootless-extras containerd.io \
             docker-buildx-plugin docker-compose-plugin; do
    if is_installed "$pkg" && ! apt-mark showhold | grep -qx "$pkg"; then held+=("$pkg"); fi
  done
  (( ${#held[@]} )) && apt-mark hold "${held[@]}" >/dev/null
  if ! "${APT[@]}" upgrade; then
    (( ${#held[@]} )) && apt-mark unhold "${held[@]}" >/dev/null
    die "apt upgrade failed"
  fi
  if (( ${#held[@]} )); then apt-mark unhold "${held[@]}" >/dev/null; fi
  ok "System updated"
fi
"${APT[@]}" install --no-upgrade "${BASE_PACKAGES[@]}"
ok "Base packages: ${BASE_PACKAGES[*]}"
timedatectl set-timezone "$TZ_NAME"
ok "Time zone: $(timedatectl show -p Timezone --value)"

if ss -Htln "sport = :$LLM_PORT" | grep -q .; then
  if command -v docker >/dev/null && docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^local-llm-'; then
    ok "Port $LLM_PORT is used by the running local-llm stack"
  else
    die "Port $LLM_PORT is in use by something else: $(ss -Htlnp "sport = :$LLM_PORT" | head -1)"
  fi
else
  ok "Port $LLM_PORT is free"
fi

# =============================================================================
step "3/8 Docker Engine and Docker Compose (official repository)"
# =============================================================================
conflicts=()
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  is_installed "$pkg" && conflicts+=("$pkg")
done
if (( ${#conflicts[@]} )); then
  warn "Removing conflicting packages: ${conflicts[*]}"
  "${APT[@]}" remove "${conflicts[@]}"
fi
if command -v snap >/dev/null && snap list docker >/dev/null 2>&1; then
  warn "Removing snap docker"; snap remove docker
fi

install -m 0755 -d /etc/apt/keyrings
tmpkey=$(mktemp)
retry 3 curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$tmpkey"
fpr=$(gpg --show-keys --with-colons "$tmpkey" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')
[[ $fpr == "$DOCKER_GPG_FPR" ]] || { rm -f "$tmpkey"; die "Docker GPG key fingerprint mismatch: $fpr"; }
install -m 0644 "$tmpkey" /etc/apt/keyrings/docker.asc; rm -f "$tmpkey"
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
"${APT[@]}" install --no-upgrade docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now containerd docker >/dev/null
ok "$(docker version --format 'Docker Client {{.Client.Version}} / Server {{.Server.Version}}')"
ok "$(docker compose version)"

# =============================================================================
step "4/8 Add user $TARGET_USER to the docker group"
# =============================================================================
if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx docker; then
  ok "$TARGET_USER is already in the docker group"
else
  usermod -aG docker "$TARGET_USER"
  ok "$TARGET_USER added to the docker group (takes effect after a new login)"
fi

# =============================================================================
step "5/8 Working directory $LLM_DIR and .env"
# =============================================================================
# Embedded copies of deploy/local-llm/{docker-compose.yml,Caddyfile}.
# KEEP IN SYNC with the repository files.
embedded_compose() { cat <<'EOF_COMPOSE'
# Local LLM server: Ollama (CPU) behind Caddy with a static API key
# Location on the model server: /opt/local-llm/docker-compose.yml
# Secrets are loaded from /opt/local-llm/.env (template: .env.example).
#
#   AI gateway (LiteLLM) --HTTP :11434 + "Authorization: Bearer <key>"--> caddy --> ollama:11434
#
# In the training lab this runs on a dedicated VM shared by all participants.
# In the reference lab it runs next to /opt/ai-stack on the same VM, as a
# separate compose project (own network, own volumes) – as if it were another VM.

name: local-llm

x-logging: &default-logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"

services:
  ollama:
    # Pinned version – never "latest". https://github.com/ollama/ollama/releases
    image: ollama/ollama:0.40.13
    restart: unless-stopped
    environment:
      # Keep the model in RAM between requests (loading takes seconds to minutes on CPU).
      OLLAMA_KEEP_ALIVE: ${OLLAMA_KEEP_ALIVE:-24h}
      # Requests processed at the same time per model. Every slot reserves its
      # own KV cache (RAM = NUM_PARALLEL x CONTEXT_LENGTH); further requests queue.
      OLLAMA_NUM_PARALLEL: ${OLLAMA_NUM_PARALLEL:-2}
      # Requests waiting in the queue before Ollama answers 503 (server busy).
      OLLAMA_MAX_QUEUE: ${OLLAMA_MAX_QUEUE:-128}
      # Only one model in memory at a time (CPU server, limited RAM).
      OLLAMA_MAX_LOADED_MODELS: "1"
      # Default context window (tokens) for every request without num_ctx.
      OLLAMA_CONTEXT_LENGTH: ${OLLAMA_CONTEXT_LENGTH:-8192}
      # Disable Ollama's cloud models (":cloud" tags run on ollama.com) –
      # everything this server answers must be computed locally.
      OLLAMA_NO_CLOUD: "1"
    volumes:
      # Downloaded model weights (GBs) – keep on a fast disk.
      - ollama-models:/root/.ollama
    # No "ports:" – Ollama has no authentication of its own, so it is reachable
    # only through caddy (internal network llm-net).
    healthcheck:
      test: ["CMD", "ollama", "list"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    networks: [llm-net]
    logging: *default-logging

  caddy:
    # Same pinned version as in /opt/ai-stack.
    image: caddy:2.11.7
    restart: unless-stopped
    environment:
      LOCAL_LLM_API_KEY: ${LOCAL_LLM_API_KEY:?missing in .env}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
    ports:
      # The only published port. Restrict it to the gateway VMs (firewall /
      # network ACL) – see docs/local-llm-server.md.
      - "11434:11434"
    depends_on:
      ollama:
        condition: service_healthy
    networks: [llm-net]
    logging: *default-logging

volumes:
  ollama-models:

networks:
  llm-net:
EOF_COMPOSE
}
embedded_caddyfile() { cat <<'EOF_CADDY'
# Caddy – API key check in front of Ollama (/opt/local-llm/Caddyfile)
# Docs: https://caddyserver.com/docs/caddyfile
#
# Ollama itself has no authentication. Caddy lets a request through only when
# it carries "Authorization: Bearer <LOCAL_LLM_API_KEY>"; everything else gets
# 401. LiteLLM sends exactly this header when the model has "api_key" set.
#
# Plain HTTP inside the lab network: the key travels unencrypted between the
# gateway and this server. For production use TLS (see docs/local-llm-server.md).
#
# LOCAL_LLM_API_KEY is passed in by docker-compose.yml from .env.

{
	# HTTP only, no certificates, no admin API.
	auto_https off
	admin off
}

:11434 {
	@unauthorized not header Authorization "Bearer {$LOCAL_LLM_API_KEY}"
	respond @unauthorized `{"error":"unauthorized"}` 401

	reverse_proxy ollama:11434 {
		# Stream tokens to the gateway immediately, no buffering.
		flush_interval -1
	}
}
EOF_CADDY
}

install -d -o "$TARGET_USER" -g "$TARGET_USER" -m 750 "$LLM_DIR"
install_config() {  # install_config <name> <embedded-function>
  local name=$1 src tmp dst=$LLM_DIR/$1
  tmp=$(mktemp)
  if [[ -f $SCRIPT_DIR/$name && -f $SCRIPT_DIR/docker-compose.yml && -f $SCRIPT_DIR/Caddyfile ]]; then
    cp "$SCRIPT_DIR/$name" "$tmp"; src="repository ($SCRIPT_DIR)"
  else
    "$2" > "$tmp"; src="embedded copy"
  fi
  if [[ -f $dst ]] && cmp -s "$tmp" "$dst"; then
    ok "$name is up to date ($src)"; rm -f "$tmp"; return
  fi
  if [[ -f $dst ]]; then
    local bak; bak=$dst.bak-$(date +%Y%m%d-%H%M%S)
    cp -p "$dst" "$bak"; warn "$name differed – previous version backed up to $bak"
  fi
  install -o "$TARGET_USER" -g "$TARGET_USER" -m 640 "$tmp" "$dst"; rm -f "$tmp"
  ok "$name installed ($src)"
}
install_config docker-compose.yml embedded_compose
install_config Caddyfile          embedded_caddyfile

umask 077
[[ -f $ENV_FILE ]] || printf '# Model server – secrets and settings. Generated by setup-model-server.sh on %s. NEVER commit!\n' "$(date -I)" > "$ENV_FILE"
env_set() {  # replace/append a line; the value goes via ENVIRON, not argv
  if env_has "$1"; then
    V="$2" awk -v k="$1" 'index($0, k "=") == 1 {print k "=" ENVIRON["V"]; next} {print}' \
      "$ENV_FILE" > "$ENV_FILE.tmp" && cat "$ENV_FILE.tmp" > "$ENV_FILE" && rm -f "$ENV_FILE.tmp"
  else
    printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"
  fi
}
KEY_CHANGED=0
if (( NEW_KEY )) || [[ -z $(env_value LOCAL_LLM_API_KEY) ]]; then
  env_has LOCAL_LLM_API_KEY && KEY_CHANGED=1
  env_set LOCAL_LLM_API_KEY "sk-local-$(openssl rand -hex 24)"
  if (( KEY_CHANGED )); then warn "LOCAL_LLM_API_KEY rotated – update LOCAL_LLM_API_KEY on every gateway"
  else ok "LOCAL_LLM_API_KEY generated"; fi
else
  ok "LOCAL_LLM_API_KEY already exists – keeping it"
fi
env_set OLLAMA_NUM_PARALLEL   "$NUM_PARALLEL"
env_set OLLAMA_CONTEXT_LENGTH "$CONTEXT_LENGTH"
env_set OLLAMA_KEEP_ALIVE     "$KEEP_ALIVE"
# Not used by compose – remembered for re-runs of this script.
env_set LOCAL_LLM_MODEL       "$MODEL"
env_set LOCAL_LLM_ALLOW_CIDR  "$ALLOW_CIDR"
chown "$TARGET_USER:$TARGET_USER" "$ENV_FILE"; chmod 600 "$ENV_FILE"
ok ".env: $(stat -c '%A %U:%G' "$ENV_FILE"), variables: $(grep -v '^#' "$ENV_FILE" | cut -d= -f1 | grep . | tr '\n' ' ')"

# =============================================================================
step "6/8 Validate, pull images, start the stack"
# =============================================================================
cd "$LLM_DIR"
docker compose config --quiet
ok "docker-compose.yml is valid"
retry 3 docker compose pull -q
mapfile -t IMAGES < <(docker compose config --images)
ok "Images: ${IMAGES[*]}"
caddy_image=$(printf '%s\n' "${IMAGES[@]}" | grep -m1 '^caddy:')
if out=$(docker run --rm -e LOCAL_LLM_API_KEY=x -v "$LLM_DIR/Caddyfile:/etc/caddy/Caddyfile:ro" \
           "$caddy_image" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1); then
  ok "Caddyfile is valid ($caddy_image)"
else
  die "Caddyfile is not valid: $(tail -1 <<<"$out")"
fi
# Recreates only containers whose configuration changed (e.g. new key, slots).
docker compose up -d --wait --wait-timeout 180
docker compose ps --format '  {{.Service}}: {{.Status}}'
ok "Stack is running"

# =============================================================================
step "7/8 Model $MODEL: pull, warm-up, verification"
# =============================================================================
KEY=$(env_value LOCAL_LLM_API_KEY)
BASE=http://127.0.0.1:$LLM_PORT
# The key goes to curl through a config file on stdin, not on the command line.
auth_curl() { printf 'header = "Authorization: Bearer %s"\n' "$KEY" | curl -K - "$@"; }

code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/tags")
[[ $code == 401 ]] && ok "Without the key: HTTP 401" || die "Without the key expected 401, got $code"
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer wrong' "$BASE/api/tags")
[[ $code == 401 ]] && ok "Wrong key: HTTP 401" || die "Wrong key expected 401, got $code"
auth_curl -sf "$BASE/api/tags" >/dev/null && ok "With the key: HTTP 200" || die "With the key the API does not answer"

if (( NO_MODEL )); then
  warn "Model pull and warm-up skipped (--no-model)"
else
  if docker compose exec -T ollama ollama list | awk 'NR>1{print $1}' | grep -qx "$MODEL"; then
    ok "$MODEL is already downloaded"
  else
    echo "  Downloading $MODEL (GBs, may take minutes)…"
    retry 3 docker compose exec -T ollama ollama pull "$MODEL" 2>&1 | tr '\r' '\n' | grep -v '^pulling .*%' || true
    docker compose exec -T ollama ollama list | awk 'NR>1{print $1}' | grep -qx "$MODEL" \
      || die "Model $MODEL was not downloaded (check the tag at https://ollama.com/library)"
    ok "$MODEL downloaded"
  fi
  docker compose exec -T ollama ollama list | sed 's/^/      /'

  echo "  Warm-up: first request loads the model into RAM (tens of seconds on CPU)…"
  req=$(jq -nc --arg m "$MODEL" '{model:$m, stream:false, think:false, options:{num_predict:30},
        messages:[{role:"user", content:"Jaké je hlavní město Česka? Odpověz jednou větou."}]}')
  if resp=$(auth_curl -sf -m 600 "$BASE/api/chat" -d "$req"); then
    ok "Answer: $(jq -r '.message.content' <<<"$resp" | tr '\n' ' ' | cut -c1-120)"
    ok "$(jq -r '"load \(.load_duration/1e9|round) s, total \(.total_duration/1e9*10|round/10) s, \(.eval_count/(.eval_duration/1e9)*10|round/10) tokens/s"' <<<"$resp")"
  else
    die "Chat request failed – see: docker compose logs ollama"
  fi
  docker compose exec -T ollama ollama ps | sed 's/^/      /'
  slots=$(docker compose logs ollama 2>/dev/null | grep -o 'n_slots = [0-9]*' | tail -1 | tr -dc '0-9' || true)
  if [[ -z $slots ]]; then
    warn "Could not read n_slots from the Ollama log"
  elif (( slots < NUM_PARALLEL )); then
    warn "Model runs with n_slots = $slots (< $NUM_PARALLEL) – it cannot process requests in parallel (docs/model-server.md, 2.2)"
  else
    ok "Parallel slots: n_slots = $slots"
  fi
fi

# =============================================================================
step "8/8 Network restriction of port $LLM_PORT (DOCKER-USER)"
# =============================================================================
# Docker bypasses ufw – published ports are filtered in the DOCKER-USER chain.
# Rules are tagged "local-llm" and re-applied by a systemd unit after Docker starts.
if [[ $ALLOW_CIDR == none ]]; then
  if [[ -f $FW_UNIT ]]; then
    warn "allow_cidr=none but $FW_UNIT exists – firewall left unchanged (disable: systemctl disable --now local-llm-firewall)"
  else
    warn "Port $LLM_PORT is reachable from any network that can reach this VM – only the API key protects it"
  fi
else
  apply_fw=1
  if (( HAVE_TTY )) && [[ -z ${GIVEN[ALLOW_CIDR]:-} ]]; then
    read -rp "  Restrict port $LLM_PORT to $ALLOW_CIDR now? Everything else is dropped. [y/N]: " a < /dev/tty || a=
    [[ $a =~ ^[YyAa]$ ]] || apply_fw=0
  fi
  if (( apply_fw )); then
    cat > "$FW_SCRIPT" <<EOF
#!/usr/bin/env bash
# Generated by setup-model-server.sh – allow port $LLM_PORT only from: $ALLOW_CIDR
set -euo pipefail
PORT=$LLM_PORT
ALLOW="$ALLOW_CIDR"
for ipt in iptables ip6tables; do
  \$ipt -n -L DOCKER-USER >/dev/null 2>&1 || continue
  # remove previous local-llm rules
  while rule=\$(\$ipt -S DOCKER-USER | grep -m1 -- '--comment local-llm'); do
    eval "\$ipt \${rule/-A /-D }"
  done
  \$ipt -I DOCKER-USER -p tcp -m conntrack --ctorigdstport "\$PORT" --ctdir ORIGINAL \\
    -m comment --comment local-llm -j DROP
  [[ \$ipt == iptables ]] || continue   # IPv6: drop only
  for c in \${ALLOW//,/ }; do
    \$ipt -I DOCKER-USER -p tcp -m conntrack --ctorigdstport "\$PORT" --ctdir ORIGINAL \\
      -s "\$c" -m comment --comment local-llm -j ACCEPT
  done
done
EOF
    chmod 750 "$FW_SCRIPT"
    cat > "$FW_UNIT" <<EOF
[Unit]
Description=Restrict local-llm port $LLM_PORT to the gateway networks (DOCKER-USER)
After=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$FW_SCRIPT

[Install]
WantedBy=docker.service
EOF
    systemctl daemon-reload
    systemctl enable local-llm-firewall.service >/dev/null 2>&1
    systemctl restart local-llm-firewall.service
    ok "Port $LLM_PORT allowed only from: $ALLOW_CIDR (persisted: $FW_UNIT)"
    iptables -S DOCKER-USER | grep local-llm | sed 's/^/      /'
  else
    warn "Firewall not changed (answered no)"
  fi
fi

# =============================================================================
step "Done – summary"
# =============================================================================
[[ -f /var/run/reboot-required ]] && warn "The system requires a reboot (kernel/libraries): sudo systemctl reboot"
if (( ${#WARNINGS[@]} )); then
  printf '\n%sWarnings:%s\n' "$c_warn" "$c_0"; printf '  - %s\n' "${WARNINGS[@]}"
fi
server_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="src") {print $(i+1); exit}}')
if (( SHOW_KEY )); then key_line=$KEY
else key_line="(hidden – show: sudo grep LOCAL_LLM_API_KEY $ENV_FILE)"; fi
cat <<EOF

Model server is ready. Hand out to the participants (docs/model-server.md, 5.1):

  LOCAL_LLM_API_BASE=http://${server_ip:-<IP>}:$LLM_PORT
  LOCAL_LLM_API_KEY=$key_line
  model in config.yaml: ollama_chat/$MODEL

Useful commands (cd $LLM_DIR):
  docker compose exec ollama ollama ps                               # model in RAM
  docker compose logs -f --since 1m ollama | grep -E 'POST|n_slots'  # requests
  # rotate the key after the training:
  sudo $0 --new-key --yes

Log of this run: $LOG
EOF
