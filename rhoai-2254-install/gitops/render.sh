#!/usr/bin/env bash
# render.sh — bake REPO_URL and TARGET_REVISION into the checked-in
# apps/*.yaml Application manifests. Kustomize builds those files directly
# from git, so `envsubst` at bootstrap-time cannot substitute them — they
# must be committed with real values.
#
# Idempotent: replaces `${REPO_URL}` / `${TARGET_REVISION}` placeholders OR
# any previously-rendered values back with the current .env values.
#
# Usage:
#   cp gitops/.env.example gitops/.env
#   $EDITOR gitops/.env                       # set REPO_URL, TARGET_REVISION
#   ./gitops/render.sh
#   git add gitops/apps && git commit -m "render apps for <fork>"
#   git push
#   ./gitops/bootstrap.sh

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/.env"
fi

: "${TARGET_REVISION:=main}"

if [[ -z "${REPO_URL:-}" ]]; then
  echo "ERROR: REPO_URL is required (env var or in gitops/.env)" >&2
  echo "  example: REPO_URL=https://github.com/yourorg/rhoai-migrations.git" >&2
  exit 1
fi

log() { echo "[render] $*"; }

# Match either the literal placeholder ${REPO_URL} OR any previously-rendered
# https://... value on a `repoURL:` line, so re-runs pick up a changed .env.
render_file() {
  local f="$1" tmp
  tmp=$(mktemp)
  awk -v repo="${REPO_URL}" -v rev="${TARGET_REVISION}" '
    /repoURL:/     { sub(/repoURL: .*/, "repoURL: " repo);         print; next }
    /targetRevision:/ { sub(/targetRevision: .*/, "targetRevision: " rev); print; next }
    { print }
  ' "$f" > "$tmp" && mv "$tmp" "$f"
}

count=0
for f in "${SCRIPT_DIR}/apps/"*.yaml; do
  render_file "$f"
  count=$((count+1))
done

log "rendered ${count} files in gitops/apps/ with:"
log "  repoURL:        ${REPO_URL}"
log "  targetRevision: ${TARGET_REVISION}"
log ""
log "next:"
log "  git add ${SCRIPT_DIR#$(pwd)/}/apps && git commit -m 'render apps' && git push"
log "  ./gitops/bootstrap.sh"
