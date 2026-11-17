#!/usr/bin/env bash
# =============================================================================
# set-env.sh – set one variable in the AI stack's .env without ever printing it
#
# Usage (in /opt/ai-stack, where the script is installed next to .env):
#   ./set-env.sh NAME               ask for the value (hidden input) – API keys
#   command | ./set-env.sh NAME     value = first line of stdin – generated keys
#   ./set-env.sh NAME VALUE         non-secret value (ends up in shell history!)
#
# The line NAME=... is replaced if it exists (duplicates are removed),
# otherwise it is appended. .env keeps mode 600. The value never appears on
# the screen, in the shell history (hidden prompt / stdin) or in the process
# list (it is passed to awk via the environment, not as an argument).
# The file can be overridden for testing:  ENV_FILE=/tmp/test.env ./set-env.sh X
# =============================================================================
set -Eeuo pipefail

ENV_FILE=${ENV_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.env}

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

NAME=${1:-}
[[ $NAME =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "Usage: $0 NAME [VALUE]   (NAME in upper case, e.g. ANTHROPIC_API_KEY)"

SECRET=1
if [[ $# -ge 2 ]]; then
  VALUE=$2; SECRET=0
elif [[ ! -t 0 ]]; then
  IFS= read -r VALUE || true          # from a pipe, e.g.  jq -r .key | ./set-env.sh X
else
  IFS= read -rsp "$NAME (input is hidden, Enter = done): " VALUE; echo
fi

[[ -n $VALUE ]] || die "Empty value – nothing changed."
# Arrow keys, Home etc. pressed while pasting leave invisible escape sequences;
# Windows clipboards add \r. LiteLLM later rejects such keys in HTTP headers.
if LC_ALL=C grep -q '[[:cntrl:]]' <<<"$VALUE"; then
  die "The value contains control characters (arrow keys? Windows line ending?) – nothing changed, try again."
fi
[[ $VALUE == *" "* ]] && printf '[WARN] The value contains a space – is that intended?\n' >&2

umask 077
touch "$ENV_FILE"
tmp=$(mktemp "$ENV_FILE.XXXXXX")
trap 'rm -f "$tmp"' EXIT
V=$VALUE awk -v k="$NAME" '
  index($0, k "=") == 1 { if (!done) print k "=" ENVIRON["V"]; done = 1; next }
  { print }
  END { if (!done) print k "=" ENVIRON["V"] }
' "$ENV_FILE" > "$tmp"
cat "$tmp" > "$ENV_FILE"              # keep the original file, owner and mode
chmod 600 "$ENV_FILE"

if (( SECRET )); then
  printf '[OK] %s saved: length %d, starts with "%s…"\n' "$NAME" "${#VALUE}" "${VALUE:0:7}"
else
  printf '[OK] %s=%s\n' "$NAME" "$VALUE"
fi
