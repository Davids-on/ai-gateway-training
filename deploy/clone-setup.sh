#!/usr/bin/env bash
# =============================================================================
# clone-setup.sh – give a VM cloned from the prepared template its own identity
#
# Run it on EVERY clone after prepare.sh has run on the template and the VM was
# cloned (the hypervisor already gave the clone a new MAC and IP address).
#
# What the script does:
#   1. hostname: sets a unique hostname (default: <template name>-<last IP octet>)
#      and updates /etc/hosts (old hostname and old template IP)
#   2. machine-id: generates a new one (systemd, journald, DHCP client ID)
#   3. SSH host keys: generates new ones (every clone has its own identity)
#   4. /opt/ai-stack/.env: generates NEW secrets (master/salt key, passwords)
#      – only if the stack has never been started on this VM (no ai-stack
#      containers or volumes); API keys that are already filled in are kept
#   5. /opt/ai-stack/.env: sets SERVER_IP and WEBUI_URL to the current IP
#   6. checks /etc for leftovers of the template IP and hostname
#
# Steps 1–4 run only once per clone (marker file below). Re-running the script
# only re-syncs SERVER_IP/WEBUI_URL with the current IP – useful when DHCP
# assigns a different address after the reboot (new machine-id = new DHCP
# client ID).
#
# What the script does NOT do: change the network configuration (netplan),
# fill in API keys (use /opt/ai-stack/set-env.sh), start the stack.
#
# Download and run on the clone:
#   curl -fsSLO https://raw.githubusercontent.com/Davids-on/ai-gateway-training/main/deploy/clone-setup.sh
#   chmod +x clone-setup.sh && sudo ./clone-setup.sh --reboot
#
# Usage:
#   sudo ./clone-setup.sh                      # hostname <template>-<octet>
#   sudo ./clone-setup.sh --hostname ai-lab-07 # explicit hostname
#   sudo ./clone-setup.sh --prefix ai-lab      # hostname ai-lab-<octet>
#   sudo ./clone-setup.sh --keep-hostname      # do not touch the hostname
#   sudo ./clone-setup.sh --reboot             # reboot at the end
#   sudo ./clone-setup.sh --force              # run steps 1-4 again
#   sudo ./clone-setup.sh --help
#
# Non-interactive – can be run on all clones in a loop from the workstation:
#   for h in 192.0.2.11 192.0.2.12; do
#     scp clone-setup.sh "labadmin@$h:" &&
#     ssh "labadmin@$h" 'sudo -n ./clone-setup.sh --reboot'
#   done
# =============================================================================
set -Eeuo pipefail

STACK_DIR=${STACK_DIR:-/opt/ai-stack}
ENV_FILE=$STACK_DIR/.env
MARKER=/var/lib/ai-stack/clone-setup.done
LOG=/var/log/ai-stack-clone-setup.log
PROJECT=ai-stack           # compose project name (name: in docker-compose.yml)

NEW_HOSTNAME=
PREFIX=
KEEP_HOSTNAME=0
DO_REBOOT=0
FORCE=0

# --- Helpers ----------------------------------------------------------------
c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'; c_hd=$'\e[1;36m'; c_0=$'\e[0m'
step() { printf '\n%s==> %s%s\n' "$c_hd" "$*" "$c_0"; }
ok()   { printf '%s  [OK]%s %s\n' "$c_ok" "$c_0" "$*"; }
warn() { printf '%s  [WARN]%s %s\n' "$c_warn" "$c_0" "$*"; WARNINGS+=("$*"); }
die()  { printf '%s  [ERROR]%s %s\n' "$c_err" "$c_0" "$*" >&2; exit 1; }
WARNINGS=()
trap 'printf "%s  [ERROR]%s Script failed at line %s: %s\n" "$c_err" "$c_0" "$LINENO" "$BASH_COMMAND" >&2' ERR

usage() { sed -n '3,/^# =====/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0; }

env_has()   { grep -q "^$1=" "$ENV_FILE"; }
env_value() { sed -n "s/^$1=//p" "$ENV_FILE" | head -1; }
env_set() {  # replace/append NAME=VALUE; the value goes via ENVIRON, never argv
  local tmp; tmp=$(mktemp "$ENV_FILE.XXXXXX")
  V="$2" awk -v k="$1" '
    index($0, k "=") == 1 { if (!done) print k "=" ENVIRON["V"]; done = 1; next }
    { print }
    END { if (!done) print k "=" ENVIRON["V"] }
  ' "$ENV_FILE" > "$tmp"
  cat "$tmp" > "$ENV_FILE"; rm -f "$tmp"     # keep owner and mode of .env
}

# --- Arguments --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case $1 in
    --hostname) NEW_HOSTNAME=${2:?--hostname requires a name}; shift ;;
    --prefix) PREFIX=${2:?--prefix requires a prefix}; shift ;;
    --keep-hostname) KEEP_HOSTNAME=1 ;;
    --reboot) DO_REBOOT=1 ;;
    --force) FORCE=1 ;;
    -h|--help) usage ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || die "Run with sudo:  sudo $0"
[[ -f $ENV_FILE ]] || die "$ENV_FILE not found – run prepare.sh first (on the template or here)."
command -v openssl >/dev/null || die "openssl is missing – run prepare.sh first."

touch "$LOG" && chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1
echo "=== $(date -Is) clone-setup.sh ==="

FIRST_RUN=1
if [[ -f $MARKER ]] && (( ! FORCE )); then
  FIRST_RUN=0
fi

# Current IP = source address of the default route
cur_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="src") {print $(i+1); exit}}')
[[ -n $cur_ip ]] || die "Cannot detect the current IP address (no default route?)"
old_ip=$(env_value SERVER_IP)
old_hostname=$(hostnamectl --static 2>/dev/null || hostname)
ok "Current IP: $cur_ip   template IP (SERVER_IP in .env): ${old_ip:-<empty>}   hostname: $old_hostname"

if (( FIRST_RUN )); then
# =============================================================================
step "1/6 Hostname"
# =============================================================================
if (( KEEP_HOSTNAME )); then
  ok "--keep-hostname – keeping $old_hostname"
  new_hostname=$old_hostname
else
  if [[ -z $NEW_HOSTNAME ]]; then
    # <prefix>-<last octet>; default prefix = current name without a trailing -NN
    [[ -n $PREFIX ]] || PREFIX=$(sed -E 's/-[0-9]+$//' <<<"$old_hostname")
    NEW_HOSTNAME="$PREFIX-${cur_ip##*.}"
  fi
  [[ $NEW_HOSTNAME =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] \
    || die "Invalid hostname: $NEW_HOSTNAME (letters, digits, '-', max 63 characters)"
  new_hostname=$NEW_HOSTNAME
  hostnamectl set-hostname "$new_hostname"
  ok "Hostname: $old_hostname -> $new_hostname"
fi

# /etc/hosts: Ubuntu keeps "127.0.1.1 <hostname>"; replace the old name and the
# old template IP (if someone added it there)
cp -p /etc/hosts "/etc/hosts.bak-$(date +%Y%m%d-%H%M%S)"
if [[ $new_hostname != "$old_hostname" ]]; then
  sed -i -E "s/(^|[[:space:]])${old_hostname//./\\.}([[:space:]]|\$)/\1${new_hostname}\2/g" /etc/hosts
fi
if [[ -n $old_ip && $old_ip != "$cur_ip" && $old_ip != localhost ]]; then
  sed -i -E "s/^${old_ip//./\\.}([[:space:]])/${cur_ip}\1/" /etc/hosts
fi
if ! grep -qE "^127\.0\.1\.1[[:space:]].*\b${new_hostname}\b" /etc/hosts; then
  if grep -q '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1 ${new_hostname}/" /etc/hosts
  else
    printf '127.0.1.1 %s\n' "$new_hostname" >> /etc/hosts
  fi
fi
ok "/etc/hosts: $(grep '^127\.0\.1\.1' /etc/hosts)"

# cloud-init would set the hostname back to the template's on the next boot
if [[ -d /etc/cloud/cloud.cfg.d ]]; then
  printf '# clone-setup.sh: keep the hostname set on the clone\npreserve_hostname: true\n' \
    > /etc/cloud/cloud.cfg.d/99-ai-stack-clone.cfg
  ok "cloud-init: preserve_hostname: true"
fi

# =============================================================================
step "2/6 machine-id"
# =============================================================================
old_mid=$(cat /etc/machine-id 2>/dev/null || true)
rm -f /etc/machine-id
[[ -e /var/lib/dbus/machine-id && ! -L /var/lib/dbus/machine-id ]] && rm -f /var/lib/dbus/machine-id
systemd-machine-id-setup >/dev/null
[[ -e /var/lib/dbus/machine-id ]] || ln -s /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true
new_mid=$(cat /etc/machine-id)
[[ $new_mid != "$old_mid" ]] || die "machine-id did not change"
ok "machine-id: ${old_mid:0:8}… -> ${new_mid:0:8}… (fully applied after reboot)"
if grep -rqsE 'dhcp4:[[:space:]]*(true|yes)' /etc/netplan/ \
   && ! grep -rqsE 'dhcp-identifier:[[:space:]]*mac' /etc/netplan/; then
  warn "Network uses DHCP with a machine-id based client ID – the IP may change after reboot. Run this script again afterwards (it only re-syncs SERVER_IP/WEBUI_URL)."
fi

# =============================================================================
step "3/6 SSH host keys"
# =============================================================================
old_fp=$(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | awk '{print $2}' || true)
rm -f /etc/ssh/ssh_host_*key /etc/ssh/ssh_host_*key.pub
ssh-keygen -A >/dev/null
new_fp=$(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}')
# Reload, not restart: existing SSH sessions (including this one) keep running
if systemctl is-active -q ssh.service 2>/dev/null; then
  systemctl reload ssh.service
elif systemctl is-active -q ssh.socket 2>/dev/null; then
  :   # socket activation: the next connection starts sshd with the new keys
else
  warn "sshd is not running – the new keys are used once it starts"
fi
ok "SSH host key ed25519: ${old_fp:-<none>} -> $new_fp"
ok "On your workstation remove the old entry:  ssh-keygen -R $cur_ip"

# =============================================================================
step "4/6 New secrets in $ENV_FILE"
# =============================================================================
stack_used=0
if command -v docker >/dev/null; then
  if docker ps -a --format '{{.Names}}' | grep -q "^$PROJECT-" \
     || docker volume ls -q | grep -q "^${PROJECT}_"; then
    stack_used=1
  fi
fi
if (( stack_used )); then
  warn "The stack has already been started on this VM (containers/volumes $PROJECT exist) – secrets NOT changed (the salt key and DB password must match the data). If you want a clean stack, remove it first: cd $STACK_DIR && docker compose down -v"
else
  cp -p "$ENV_FILE" "$ENV_FILE.bak-$(date +%Y%m%d-%H%M%S)"
  env_set LITELLM_MASTER_KEY "sk-$(openssl rand -hex 32)"
  env_set LITELLM_SALT_KEY   "sk-$(openssl rand -hex 32)"
  env_set UI_PASSWORD        "$(openssl rand -base64 18 | tr -d '/+=')"
  env_set POSTGRES_PASSWORD  "$(openssl rand -hex 24)"
  env_set WEBUI_SECRET_KEY   "$(openssl rand -hex 32)"
  env_has OPENWEBUI_LITELLM_KEY && env_set OPENWEBUI_LITELLM_KEY ""
  ok "Generated: LITELLM_MASTER_KEY LITELLM_SALT_KEY UI_PASSWORD POSTGRES_PASSWORD WEBUI_SECRET_KEY"
  ok "Backup of the template .env: $ENV_FILE.bak-* (contains the template secrets – delete it once you are done)"
fi

mkdir -p "$(dirname "$MARKER")"
printf 'done %s hostname=%s ip=%s\n' "$(date -Is)" "$new_hostname" "$cur_ip" > "$MARKER"
else
  step "Steps 1–4 already done on this clone ($(cat "$MARKER")) – only syncing the IP (--force repeats them)"
fi

# =============================================================================
step "5/6 SERVER_IP and WEBUI_URL"
# =============================================================================
if [[ $(env_value SERVER_IP) == "$cur_ip" && $(env_value WEBUI_URL) == "http://$cur_ip:3000" ]]; then
  ok "Already set to $cur_ip"
else
  env_set SERVER_IP "$cur_ip"
  env_set WEBUI_URL "http://$cur_ip:3000"
  ok "SERVER_IP=$cur_ip  WEBUI_URL=http://$cur_ip:3000"
  if command -v docker >/dev/null && docker volume ls -q | grep -q "^${PROJECT}_caddy-data$"; then
    warn "Caddy has already issued certificates – restart it (docker compose up -d caddy) and re-import the root CA on clients if needed"
  fi
  if command -v docker >/dev/null && docker volume ls -q | grep -q "^${PROJECT}_open-webui-data$"; then
    warn "Open WebUI already stores WEBUI_URL in its DB – change it in Admin Panel > Settings > General as well"
  fi
fi
chmod 600 "$ENV_FILE"
LC_ALL=C grep -q '[[:cntrl:]]' "$ENV_FILE" && warn ".env contains control characters – please check it"

# =============================================================================
step "6/6 Leftovers of the template in /etc"
# =============================================================================
if [[ -n $old_ip && $old_ip != "$cur_ip" && $old_ip != localhost ]]; then
  if hits=$(grep -rlsF --exclude='*.bak-*' "$old_ip" /etc 2>/dev/null) && [[ -n $hits ]]; then
    warn "Template IP $old_ip still found in: $(tr '\n' ' ' <<<"$hits")"
  else
    ok "Template IP $old_ip not found in /etc"
  fi
fi
if [[ ${new_hostname:-} && ${new_hostname:-} != "$old_hostname" ]]; then
  if hits=$(grep -rlswF --exclude='*.bak-*' "$old_hostname" /etc 2>/dev/null) && [[ -n $hits ]]; then
    warn "Template hostname $old_hostname still found in: $(tr '\n' ' ' <<<"$hits")"
  else
    ok "Template hostname $old_hostname not found in /etc"
  fi
fi

# --- API keys -----------------------------------------------------------------
for k in OPENROUTER_API_KEY ANTHROPIC_API_KEY PROMPTGUARD_API_KEY; do
  [[ -n $(env_value "$k") ]] || warn "$k is empty – fill it in:  cd $STACK_DIR && ./set-env.sh $k"
done

# =============================================================================
step "Done – summary"
# =============================================================================
if (( ${#WARNINGS[@]} )); then
  printf '\n%sWarnings:%s\n' "$c_warn" "$c_0"; printf '  - %s\n' "${WARNINGS[@]}"
fi
echo "Log of this run: $LOG"
if (( DO_REBOOT )); then
  echo "Rebooting in 5 seconds…"
  # Detached, so an SSH loop gets the output and a clean exit code first
  systemd-run --on-active=5 --unit=clone-setup-reboot systemctl reboot >/dev/null
elif (( FIRST_RUN )); then
  echo "Reboot the VM now (new machine-id, hostname everywhere):  sudo systemctl reboot"
fi
