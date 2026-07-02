#!/usr/bin/env bash
# Tear down the GitOps side (Applications, OpenShift GitOps operator, RBAC)
# and then delegate to the top-level uninstall.sh for the RHOAI stack.
#
# Best-effort: continues on failure so a partial state gets cleaned up.

set -Euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() { echo "[gitops-uninstall] $*"; }

oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }

log "=== strip finalizers from Argo CD Applications ==="
# Without this, kube deletes hang waiting for the app controller to reconcile.
for app in $(oc -n openshift-gitops get applications.argoproj.io -o name 2>/dev/null); do
  oc -n openshift-gitops patch "$app" --type=json \
    -p '[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
done

log "=== delete all Argo CD Applications ==="
oc -n openshift-gitops delete applications.argoproj.io --all --wait=false --ignore-not-found || true

log "=== delegating to top-level uninstall.sh (RHOAI stack + samples) ==="
"${REPO_ROOT}/uninstall.sh" || true

log "=== OpenShift GitOps operator + instance ==="
# ArgoCD CR is namespace-scoped; delete it first so the operator uninstall is clean.
oc -n openshift-gitops delete argocd openshift-gitops --ignore-not-found --wait=false || true
oc -n openshift-operators delete subscription openshift-gitops-operator --ignore-not-found || true
oc get csv -n openshift-operators -o name 2>/dev/null \
  | grep -i openshift-gitops \
  | xargs -r -I{} oc -n openshift-operators delete {} --ignore-not-found || true
oc delete clusterrolebinding openshift-gitops-cluster-admin --ignore-not-found || true
oc delete ns openshift-gitops --wait=false --ignore-not-found || true

log ""
log "GitOps uninstall dispatched. Namespace deletion is async; give the cluster a few minutes."
log "Check with: oc get ns | grep -E 'openshift-gitops|redhat-ods|istio-system|knative-serving|openshift-serverless'"
