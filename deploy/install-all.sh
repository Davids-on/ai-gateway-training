#!/usr/bin/env bash
# =============================================================================
# install-all.sh – one-shot installation of the COMPLETE AI stack in its final
#                  state (stage 5-local-model), ready to play with:
#                  LiteLLM + PostgreSQL + Open WebUI + Caddy HTTPS + guardrails
#
# Meant for participants who want a working stack without going through the
# guide step by step (docs/rychla-instalace.md). It reuses prepare.sh and then
# automates what the guide does by hand:
#   1. prepare.sh: system update, Docker, /opt/ai-stack, .env with generated
#      secrets, asks for the API keys (OpenRouter required, Anthropic and
#      PromptGuard optional), pulls all images
#   2. optional: address and key of the shared local model server (module G)
#   3. installs the FINAL configuration (deploy/stages/5-local-model):
#      docker-compose.yml, config.yaml, Caddyfile – a differing existing file is
#      backed up as *.bak-<timestamp>
#   4. starts PostgreSQL + LiteLLM and creates the virtual keys:
#        open-webui  – used by Open WebUI (stored as OPENWEBUI_LITELLM_KEY)
#        client      – for your own clients: curl, Claude Code, Codex, SDKs
#                      (stored as CLIENT_LITELLM_KEY)
#      both allowed to use all models of the final stage
#   5. starts the whole stack (incl. Caddy HTTPS) and waits until it is healthy
#   6. creates the Open WebUI admin account (only if no account exists yet –
#      otherwise anybody reaching port 3000 first would become admin);
#      credentials are stored in .env (WEBUI_ADMIN_EMAIL, WEBUI_ADMIN_PASSWORD)
#   7. installs the Open WebUI filter "Gateway Notice Filter" (module E),
#      enables it globally and sets the Czech texts
#   8. exports Caddy's root certificate (needed on your workstation for HTTPS)
#   9. smoke tests: LiteLLM, Open WebUI, HTTPS via Caddy
#
# Secrets are never printed – they stay in /opt/ai-stack/.env (mode 600).
# The script is idempotent: re-running it keeps existing secrets, keys and
# accounts and only fixes what is missing.
#
# Usage (on the server, from the deploy/ directory of the training repository
# cloned to ~/ai-gateway-training):
#   sudo ./install-all.sh
#   sudo ./install-all.sh --skip-upgrade            # skip apt upgrade
#   sudo ./install-all.sh --admin-email me@example.com
#   sudo ./install-all.sh --help
#
# Options --skip-upgrade, --no-extras and --user are passed to prepare.sh.
# =============================================================================
set -Eeuo pipefail

STACK_DIR=${STACK_DIR:-/opt/ai-stack}
ENV_FILE=$STACK_DIR/.env
FINAL_STAGE=stages/5-local-model
STAGE_FILES=(docker-compose.yml config.yaml Caddyfile)
# Models of the final stage (config.yaml) – allowed on both virtual keys
MODELS='["nemotron-3-ultra","claude-opus-5-5","claude-sonnet-5-5","claude-haiku-5-5","qwen-local"]'
LITELLM=http://localhost:4000
WEBUI=http://localhost:3000
FILTER_ID=gateway_notice_filter
FILTER_NAME="Gateway Notice Filter"
FILTER_BLOCK_MESSAGE="Zpráva obsahuje rodné číslo. Osobní údaje do AI neposílejte – odstraňte je a zkuste to znovu."
FILTER_DISCLAIMER="_Odpověď vygenerovala AI. Před použitím ji ověřte._"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TARGET_USER=${SUDO_USER:-}
ADMIN_EMAIL=
PREPARE_ARGS=()

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

env_has()   { grep -q "^$1=" "$ENV_FILE"; }
env_value() { sed -n "s/^$1=//p" "$ENV_FILE" | head -1; }
env_set() {  # set a value (replace/append the line); the value goes via ENVIRON, not argv
  local tmp
  tmp=$(mktemp "$ENV_FILE.XXXXXX")
  V="$2" awk -v k="$1" '
    index($0, k "=") == 1 { if (!done) print k "=" ENVIRON["V"]; done = 1; next }
    { print }
    END { if (!done) print k "=" ENVIRON["V"] }
  ' "$ENV_FILE" > "$tmp"
  cat "$tmp" > "$ENV_FILE"; rm -f "$tmp"
  chmod 600 "$ENV_FILE"
}

# Header file for curl, so that keys never appear in the process list (argv)
auth_header() {  # auth_header VALUE -> path of a temporary 600 file
  local f
  f=$(mktemp); chmod 600 "$f"
  printf 'Authorization: Bearer %s\n' "$1" > "$f"
  TMPFILES+=("$f"); printf '%s' "$f"
}
TMPFILES=()
cleanup() { (( ${#TMPFILES[@]} )) && rm -f "${TMPFILES[@]}"; return 0; }
trap cleanup EXIT

compose() { (cd "$STACK_DIR" && docker compose "$@"); }

# --- Arguments --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-upgrade|--no-extras) PREPARE_ARGS+=("$1") ;;
    --user) TARGET_USER=${2:?--user requires a user name}; PREPARE_ARGS+=("$1" "$2"); shift ;;
    --admin-email) ADMIN_EMAIL=${2:?--admin-email requires an e-mail}; shift ;;
    -h|--help) usage ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || die "Run with sudo:  sudo $0"
[[ -n $TARGET_USER && $TARGET_USER != root ]] \
  || die "Cannot determine the regular user. Run as 'sudo $0' (not from a root shell) or use --user NAME."
[[ -x $SCRIPT_DIR/prepare.sh ]] || die "Missing $SCRIPT_DIR/prepare.sh – run the script from the repository's deploy/ directory."
for f in "${STAGE_FILES[@]}"; do
  [[ -f $SCRIPT_DIR/$FINAL_STAGE/$f ]] || die "Missing $SCRIPT_DIR/$FINAL_STAGE/$f"
done
[[ -f $SCRIPT_DIR/openwebui/$FILTER_ID.py ]] || die "Missing $SCRIPT_DIR/openwebui/$FILTER_ID.py"
if [[ $SCRIPT_DIR != "$(getent passwd "$TARGET_USER" | cut -d: -f6)/ai-gateway-training/deploy" ]]; then
  warn "The repository is not in ~$TARGET_USER/ai-gateway-training – use-stage.sh will need STAGES_DIR=$SCRIPT_DIR/stages"
fi

HAVE_TTY=0
if [[ -r /dev/tty ]] && { : < /dev/tty; } 2>/dev/null; then HAVE_TTY=1; fi

# =============================================================================
step "1/9 Server preparation (prepare.sh)"
# =============================================================================
"$SCRIPT_DIR/prepare.sh" "${PREPARE_ARGS[@]}"
[[ -f $ENV_FILE ]] || die "prepare.sh did not create $ENV_FILE"
command -v docker >/dev/null || die "Docker is not installed – see the prepare.sh output above"
[[ -n $(env_value OPENROUTER_API_KEY) ]] \
  || die "OPENROUTER_API_KEY is empty. Set it:  cd $STACK_DIR && ./set-env.sh OPENROUTER_API_KEY  and run this script again."
ok "prepare.sh finished, OPENROUTER_API_KEY is set"

# =============================================================================
step "2/9 Local model server (optional, module G)"
# =============================================================================
if [[ -n $(env_value LOCAL_LLM_API_BASE) ]]; then
  ok "LOCAL_LLM_API_BASE is already set – keeping it"
elif (( HAVE_TTY )); then
  printf '\n  Address of the shared model server from the instructor, e.g. http://192.0.2.20:11434\n'
  printf '  (without /v1). Empty Enter = skip, the model qwen-local will then not work.\n'
  IFS= read -rp "  LOCAL_LLM_API_BASE: " base < /dev/tty
  if [[ -z $base ]]; then
    warn "Local model skipped (set later: ./set-env.sh LOCAL_LLM_API_BASE <url>, ./set-env.sh LOCAL_LLM_API_KEY, docker compose up -d)"
  elif [[ ! $base =~ ^https?://[^[:space:]]+$ ]]; then
    warn "LOCAL_LLM_API_BASE '$base' is not a http(s) URL – NOT saved"
  else
    env_set LOCAL_LLM_API_BASE "${base%/}"
    ok "LOCAL_LLM_API_BASE=${base%/}"
    IFS= read -rsp "  LOCAL_LLM_API_KEY (hidden, from the instructor): " lkey < /dev/tty; echo
    if [[ -n $lkey ]] && ! LC_ALL=C grep -q '[[:cntrl:][:space:]]' <<<"$lkey"; then
      env_set LOCAL_LLM_API_KEY "$lkey"
      ok "LOCAL_LLM_API_KEY saved (length ${#lkey})"
    else
      warn "LOCAL_LLM_API_KEY empty or invalid – NOT saved (./set-env.sh LOCAL_LLM_API_KEY)"
    fi
    unset lkey
  fi
else
  warn "No terminal – local model skipped (LOCAL_LLM_API_BASE / LOCAL_LLM_API_KEY empty)"
fi

# =============================================================================
step "3/9 Final configuration (stage 5-local-model)"
# =============================================================================
ts=$(date +%Y%m%d-%H%M%S)
for f in "${STAGE_FILES[@]}"; do
  src=$SCRIPT_DIR/$FINAL_STAGE/$f dst=$STACK_DIR/$f
  if [[ -f $dst ]] && cmp -s "$src" "$dst"; then
    ok "$f is already at the final stage"
    continue
  fi
  if [[ -f $dst ]]; then
    cp -p "$dst" "$dst.bak-$ts"
    ok "$f backed up to $f.bak-$ts"
  fi
  install -o "$TARGET_USER" -g "$TARGET_USER" -m 640 "$src" "$dst"
  ok "$f installed (stage 5-local-model)"
done

# =============================================================================
step "4/9 Start PostgreSQL + LiteLLM, create virtual keys"
# =============================================================================
# Open WebUI is not started yet, so its key may still be empty – compose would
# refuse an empty value, hence the placeholder for this command only.
OPENWEBUI_LITELLM_KEY=${OPENWEBUI_LITELLM_KEY:-pending} \
  compose up -d --wait --wait-timeout 300 postgres litellm \
  || die "LiteLLM did not become healthy:  cd $STACK_DIR && docker compose logs --tail 50 litellm"
ok "PostgreSQL and LiteLLM are healthy"

MASTER_HDR=$(auth_header "$(env_value LITELLM_MASTER_KEY)")

# ensure_key ENV_VAR ALIAS – create the virtual key if the variable is empty,
# otherwise make sure it exists in LiteLLM and allows all models
ensure_key() {
  local var=$1 alias=$2 key resp
  key=$(env_value "$var")
  if [[ -n $key ]]; then
    resp=$(jq -n --arg k "$key" --argjson m "$MODELS" '{key: $k, models: $m}' \
      | curl -s "$LITELLM/key/update" -H @"$MASTER_HDR" -H "Content-Type: application/json" -d @-)
    if jq -e '.key_alias' >/dev/null 2>&1 <<<"$resp"; then
      ok "$var exists (alias $(jq -r .key_alias <<<"$resp")), models updated"
      return
    fi
    warn "$var in .env is unknown to LiteLLM – creating a new key"
  fi
  resp=$(jq -n --arg a "$alias" --argjson m "$MODELS" \
           '{key_alias: $a, models: $m, metadata: {service: $a, created_by: "install-all.sh"}}' \
    | curl -s "$LITELLM/key/generate" -H @"$MASTER_HDR" -H "Content-Type: application/json" -d @-)
  key=$(jq -r '.key // empty' <<<"$resp")
  [[ $key == sk-* ]] || die "Creating the virtual key $alias failed: $(jq -c '.error // .' <<<"$resp" | cut -c1-300)"
  env_set "$var" "$key"
  ok "$var created (alias $alias, prefix ${key:0:5}…)"
}
ensure_key OPENWEBUI_LITELLM_KEY open-webui
ensure_key CLIENT_LITELLM_KEY client
chown "$TARGET_USER:$TARGET_USER" "$ENV_FILE"

# =============================================================================
step "5/9 Start the whole stack"
# =============================================================================
compose up -d --wait --wait-timeout 600 \
  || die "The stack did not become healthy:  cd $STACK_DIR && docker compose ps && docker compose logs --tail 50"
compose ps --format '  {{.Service}}  {{.Status}}'
ok "All services are running"

# =============================================================================
step "6/9 Open WebUI admin account"
# =============================================================================
WEBUI_TOKEN=
onboarding=$(curl -s "$WEBUI/api/config" | jq -r '.onboarding // false')
if [[ $onboarding == true ]]; then
  if [[ -z $ADMIN_EMAIL ]]; then
    ADMIN_EMAIL=$(env_value WEBUI_ADMIN_EMAIL)
    ADMIN_EMAIL=${ADMIN_EMAIL:-admin@example.com}
  fi
  admin_pw=$(env_value WEBUI_ADMIN_PASSWORD)
  [[ -n $admin_pw ]] || admin_pw=$(openssl rand -base64 18 | tr -d '/+=')
  env_set WEBUI_ADMIN_EMAIL "$ADMIN_EMAIL"
  env_set WEBUI_ADMIN_PASSWORD "$admin_pw"
  resp=$(jq -n --arg e "$ADMIN_EMAIL" --arg p "$admin_pw" '{name: "Admin", email: $e, password: $p}' \
    | curl -s "$WEBUI/api/v1/auths/signup" -H "Content-Type: application/json" -d @-)
  WEBUI_TOKEN=$(jq -r '.token // empty' <<<"$resp")
  [[ -n $WEBUI_TOKEN && $(jq -r '.role // empty' <<<"$resp") == admin ]] \
    || die "Creating the Open WebUI admin failed: $(jq -c '.detail // .' <<<"$resp" | cut -c1-300)"
  ok "Admin account created: $ADMIN_EMAIL (password in .env: WEBUI_ADMIN_PASSWORD)"
  unset admin_pw
else
  ok "Open WebUI already has an admin account – not touching it"
  # Log in with the credentials this script stored earlier (needed for the filter)
  if [[ -n $(env_value WEBUI_ADMIN_EMAIL) && -n $(env_value WEBUI_ADMIN_PASSWORD) ]]; then
    resp=$(jq -n --arg e "$(env_value WEBUI_ADMIN_EMAIL)" --arg p "$(env_value WEBUI_ADMIN_PASSWORD)" \
             '{email: $e, password: $p}' \
      | curl -s "$WEBUI/api/v1/auths/signin" -H "Content-Type: application/json" -d @-)
    WEBUI_TOKEN=$(jq -r '.token // empty' <<<"$resp")
  fi
  [[ -n $WEBUI_TOKEN ]] || warn "Cannot log in to Open WebUI as admin (account created manually?) – the filter is installed by hand (part 2, section 6.6)"
fi
chown "$TARGET_USER:$TARGET_USER" "$ENV_FILE"

# =============================================================================
step "7/9 Open WebUI filter \"$FILTER_NAME\""
# =============================================================================
if [[ -n $WEBUI_TOKEN ]]; then
  WEBUI_HDR=$(auth_header "$WEBUI_TOKEN")
  owui() {  # owui METHOD PATH [curl args…]
    local m=$1 p=$2; shift 2
    curl -s -X "$m" "$WEBUI/api/v1/functions$p" -H @"$WEBUI_HDR" -H "Content-Type: application/json" "$@"
  }
  fn=$(owui GET "/id/$FILTER_ID")
  if ! jq -e '.id' >/dev/null 2>&1 <<<"$fn"; then
    fn=$(jq -n --arg id "$FILTER_ID" --arg n "$FILTER_NAME" \
              --rawfile c "$SCRIPT_DIR/openwebui/$FILTER_ID.py" \
              '{id: $id, name: $n, content: $c,
                meta: {description: "Blocks Czech birth numbers and appends an AI disclaimer (part 2, module E)"}}' \
      | owui POST /create -d @-)
    jq -e '.id' >/dev/null 2>&1 <<<"$fn" || die "Creating the filter failed: $(jq -c '.detail // .' <<<"$fn" | cut -c1-300)"
    ok "Filter created"
    fn=$(owui GET "/id/$FILTER_ID")
  else
    ok "Filter already exists – keeping its code"
  fi
  # toggle endpoints flip the state – call them only when needed
  [[ $(jq -r .is_active <<<"$fn") == true ]] || owui POST "/id/$FILTER_ID/toggle" >/dev/null
  [[ $(jq -r .is_global <<<"$fn") == true ]] || owui POST "/id/$FILTER_ID/toggle/global" >/dev/null
  fn=$(owui GET "/id/$FILTER_ID")
  if [[ $(jq -r '"\(.is_active) \(.is_global)"' <<<"$fn") == "true true" ]]; then
    ok "Filter is enabled and global"
  else
    warn "Filter state: $(jq -c '{is_active, is_global}' <<<"$fn") – enable it in Admin Panel → Functions"
  fi
  resp=$(jq -n --arg b "$FILTER_BLOCK_MESSAGE" --arg d "$FILTER_DISCLAIMER" \
           '{block_message: $b, disclaimer: $d}' \
    | owui POST "/id/$FILTER_ID/valves/update" -d @-)
  if jq -e '.block_message' >/dev/null 2>&1 <<<"$resp"; then
    ok "Filter texts set to Czech (Valves)"
  else
    warn "Setting the filter texts failed – set them in Admin Panel → Functions → Valves"
  fi
else
  warn "Filter skipped (no admin login)"
fi

# =============================================================================
step "8/9 Caddy root certificate"
# =============================================================================
CA_FILE=$STACK_DIR/caddy-root.crt
for i in {1..15}; do
  compose cp caddy:/data/caddy/pki/authorities/local/root.crt - 2>/dev/null | tar -xO > "$CA_FILE.tmp" 2>/dev/null || true
  [[ -s $CA_FILE.tmp ]] && break
  sleep 2
done
if [[ -s $CA_FILE.tmp ]] && openssl x509 -in "$CA_FILE.tmp" -noout 2>/dev/null; then
  mv "$CA_FILE.tmp" "$CA_FILE"
  chown "$TARGET_USER:$TARGET_USER" "$CA_FILE"; chmod 644 "$CA_FILE"
  CA_FPR=$(openssl x509 -in "$CA_FILE" -noout -fingerprint -sha256 | cut -d= -f2)
  ok "Root certificate exported: $CA_FILE"
  ok "SHA-256 fingerprint: $CA_FPR"
else
  rm -f "$CA_FILE.tmp"; CA_FPR=
  warn "Cannot export Caddy's root certificate yet – try later (part 2, section 7.5)"
fi

# =============================================================================
step "9/9 Smoke tests"
# =============================================================================
SERVER_IP=$(env_value SERVER_IP)
CLIENT_HDR=$(auth_header "$(env_value CLIENT_LITELLM_KEY)")
models=$(curl -s "$LITELLM/v1/models" -H @"$CLIENT_HDR" | jq -c '[.data[].id]' 2>/dev/null || true)
[[ -n $models ]] && ok "LiteLLM models for the client key: $models" || warn "LiteLLM /v1/models did not answer"

# One real request on the free OpenRouter model (it may be rate-limited –
# then LiteLLM falls back to Claude Haiku, if the Anthropic key is set)
answer=$(jq -n '{model: "nemotron-3-ultra", max_tokens: 50,
                 messages: [{role: "user", content: "Reply with exactly one word: OK"}]}' \
  | curl -s --max-time 120 "$LITELLM/v1/chat/completions" -H @"$CLIENT_HDR" \
         -H "Content-Type: application/json" -d @- \
  | jq -r '.choices[0].message.content // ("ERROR: " + (.error.message // "no answer"))' 2>/dev/null || true)
if [[ -n $answer && $answer != ERROR:* ]]; then
  ok "Test request answered: $(tr '\n' ' ' <<<"$answer" | cut -c1-60)"
else
  warn "Test request failed: $(cut -c1-200 <<<"${answer:-no answer}") – check the OpenRouter key; the free tier is sometimes rate-limited, try again later"
fi

[[ $(curl -s "$WEBUI/health" | jq -r .status 2>/dev/null) == true ]] \
  && ok "Open WebUI /health OK" || warn "Open WebUI /health failed"

if [[ -s $CA_FILE && -n $SERVER_IP ]]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CA_FILE" "https://$SERVER_IP/health" || true)
  [[ $code == 200 ]] && ok "HTTPS Open WebUI: https://$SERVER_IP (200)" || warn "HTTPS https://$SERVER_IP/health returned $code"
  code=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CA_FILE" "https://$SERVER_IP:8443/health/liveliness" || true)
  [[ $code == 200 ]] && ok "HTTPS LiteLLM: https://$SERVER_IP:8443 (200)" || warn "HTTPS https://$SERVER_IP:8443 returned $code"
fi

for v in ANTHROPIC_API_KEY PROMPTGUARD_API_KEY LOCAL_LLM_API_KEY; do
  [[ -n $(env_value "$v") ]] || warn "$v is empty – the related feature will not work (see docs/rychla-instalace.md)"
done

# =============================================================================
step "Done"
# =============================================================================
if (( ${#WARNINGS[@]} )); then
  printf '\n%sWarnings:%s\n' "$c_warn" "$c_0"; printf '  - %s\n' "${WARNINGS[@]}"
fi
cat <<EOF

The AI stack is running in its final state.

  Open WebUI (chat):     http://$SERVER_IP:3000      https://$SERVER_IP
  LiteLLM Admin UI:      http://$SERVER_IP:4000/ui   https://$SERVER_IP:8443/ui
  LiteLLM API (clients): https://$SERVER_IP:8443     (OpenAI format: + /v1)
  Root certificate:      $CA_FILE
                         SHA-256 ${CA_FPR:-(not exported yet)}

Logins and keys are stored ONLY in $ENV_FILE. Show them (on the server):
  sudo grep -E '^(WEBUI_ADMIN_|UI_USERNAME|UI_PASSWORD|CLIENT_LITELLM_KEY)' $ENV_FILE

  WEBUI_ADMIN_EMAIL / WEBUI_ADMIN_PASSWORD  – Open WebUI admin
  UI_USERNAME / UI_PASSWORD                 – LiteLLM Admin UI
  CLIENT_LITELLM_KEY                        – virtual key for curl, Claude Code, Codex, SDKs
  LITELLM_MASTER_KEY                        – administration only, never put it into clients

Note: log out and in again before using docker without sudo (docker group).
What to do next: docs/rychla-instalace.md
EOF
