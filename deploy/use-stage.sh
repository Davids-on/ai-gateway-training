#!/usr/bin/env bash
# =============================================================================
# use-stage.sh – switch /opt/ai-stack to a configuration stage of the training
#
# Usage (in /opt/ai-stack):
#   ./use-stage.sh --diff 2-models    only show what would change
#   ./use-stage.sh 2-models           show the changes, back up, copy the files
#
# Stages (deploy/stages/README.md):
#   1-base  2-models  3-guardrails  4-https  5-local-model
#
# The script only copies files (docker-compose.yml, config.yaml, Caddyfile) –
# applying them (docker compose up -d ...) is a separate, deliberate step that
# the guide describes for every module. Previous versions are kept as
# *.bak-<timestamp>. .env is never touched.
#
# Where the stages are: the training repository cloned to ~/ai-gateway-training,
# override with  STAGES_DIR=/path/to/deploy/stages ./use-stage.sh ...
# =============================================================================
set -Eeuo pipefail

STAGES_DIR=${STAGES_DIR:-$HOME/ai-gateway-training/deploy/stages}
STACK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

DIFF_ONLY=0
[[ ${1:-} == --diff ]] && { DIFF_ONLY=1; shift; }
STAGE=${1:-}
[[ -n $STAGE ]] || die "Usage: $0 [--diff] STAGE   (stages: $(ls "$STAGES_DIR" 2>/dev/null | grep -E '^[0-9]-' | tr '\n' ' '))"
SRC=$STAGES_DIR/$STAGE
[[ -d $SRC ]] || die "Stage $SRC not found. Is the repository cloned to ~/ai-gateway-training (or STAGES_DIR set)?"

changed=()
for f in docker-compose.yml config.yaml Caddyfile; do
  [[ -f $SRC/$f ]] || continue
  if [[ -f $STACK_DIR/$f ]] && cmp -s "$SRC/$f" "$STACK_DIR/$f"; then
    printf '[OK] %s is already at stage %s\n' "$f" "$STAGE"
    continue
  fi
  changed+=("$f")
  printf '\n===== %s =====\n' "$f"
  if [[ -f $STACK_DIR/$f ]]; then
    diff -u --label "current/$f" --label "$STAGE/$f" "$STACK_DIR/$f" "$SRC/$f" || true
  else
    printf '(new file)\n'
  fi
done

(( ${#changed[@]} )) || { printf '\nNothing to do.\n'; exit 0; }
(( DIFF_ONLY )) && { printf '\n--diff: nothing was copied.\n'; exit 0; }

ts=$(date +%Y%m%d-%H%M%S)
echo
for f in "${changed[@]}"; do
  if [[ -f $STACK_DIR/$f ]]; then
    cp -p "$STACK_DIR/$f" "$STACK_DIR/$f.bak-$ts"
    printf '[OK] backup: %s.bak-%s\n' "$f" "$ts"
  fi
  install -m 640 "$SRC/$f" "$STACK_DIR/$f"
  printf '[OK] %s -> stage %s\n' "$f" "$STAGE"
done
printf '\nFiles copied. Apply them as described in the guide (docker compose ...).\n'
